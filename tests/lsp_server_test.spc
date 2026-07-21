// `super-c lsp` integration: drives the server as a subprocess over a framed JSON-RPC session file and
// asserts on the raw responses -- initialize capabilities, publishDiagnostics for a type error, the
// error clearing after a fixing didChange, and a clean shutdown/exit. Also covers the cross-module
// regression behind the server itself: a struct embedding loader::Package by value compiles (its
// builtin_decls array length is an enum-cast const evaluated pre-typecheck).
import tests::cli_harness as cli;
import stdio;
import stdlib;
import driver_shim as shim;
import module::loader as loader;
import lsp::json as json;

const MAIN_ERR: str = "fn main() i32 {\n    let x: i32 = \"hello\";\n    return x;\n}\n";
const MAIN_OK: str = "fn main() i32 {\n    let x: i32 = 42;\n    return x;\n}\n";

fn frame(out: &mut String, body: &String) {
    out.format_into("Content-Length: {}\r\n\r\n", body.len());
    out.push_string(body);
}

fn superc_path() str<'static> {
    let sc = stdlib::getenv("SUPERC");
    if sc == null || unsafe *sc == 0 as char {
        return "./super-c";
    }
    return str::from_cstr(sc);
}

// Count non-overlapping occurrences of `needle` in `hay`.
fn count(hay: str, needle: str) usize {
    let mut n: usize = 0;
    let mut i: usize = 0;
    while i + needle.len() <= hay.len() {
        if hay.slice(i, i + needle.len()) == needle {
            n += 1;
            i += needle.len();
        } else {
            i += 1;
        }
    }
    return n;
}

@test
fn lsp_diagnostics_lifecycle() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", MAIN_ERR);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(MAIN_ERR, &mut b);
    b.push_str("}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"version\":2},\"contentChanges\":[{\"text\":");
    json::dump_escaped(MAIN_OK, &mut b);
    b.push_str("}]}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":null}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(&mut ses, &b);
    p.mkfile("session.bin", ses.as_str());

    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> '");
    cmd.push_str(root);
    cmd.push_str("/err.txt'");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0); // exit after shutdown = success

    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    let out_opt = loader::read_file(op.as_str());
    assert(out_opt.is_some());
    let out = out_opt.unwrap();
    let o = out.as_str();
    assert(o.contains("\"hoverProvider\":true"));
    assert(o.contains("\"serverInfo\":{\"name\":\"super-c lsp\""));
    // the on-disk revision publishes the type error at `initialized` (whole-workspace round), the
    // identical opened revision once more; the fixed revision must not re-publish it
    assert_eq(count(o, "mismatched types: expected 'i32', found 'str'"), 2 as usize);
    assert(count(o, "textDocument/publishDiagnostics") >= 2);
    assert(o.contains("\"severity\":1"));
    assert(o.contains("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}"));
}

@test
fn lsp_unknown_method_and_bad_json() {
    let p = cli::proj_new();
    let root = str::from_cstr(p.rootp());
    let mut ses = String::new();
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/nonsense\",\"params\":{}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{not json");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":null}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(&mut ses, &b);
    p.mkfile("session.bin", ses.as_str());

    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0);

    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    let out = loader::read_file(op.as_str()).unwrap();
    let o = out.as_str();
    assert(o.contains("\"id\":7,\"error\":{\"code\":-32601"));
    assert(o.contains("-32700"));
}

const UTIL_SRC: str = "// A 2D point.\npub struct Point {\n    pub x: i32, // horizontal component\n    pub y: i32,\n}\n\nextend Point {\n    // The squared Euclidean norm.\n    pub fn norm2(self: &Point) i32 {\n        return self.x * self.x + self.y * self.y;\n    }\n}\n";
const MAIN_PT: str = "import util;\n\nfn main() i32 {\n    let p = util::Point { x: 3, y: 4 };\n    let n = p.norm2();\n    return n - 25;\n}\n";

@test
fn lsp_positional_features() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/util.spc", UTIL_SRC);
    p.mkfile("src/main.spc", MAIN_PT);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(MAIN_PT, &mut b);
    b.push_str("}}}");
    frame(&mut ses, &b);
    // hover on `p` receiver (line 4 "let n = p.norm2()" -> char 12)
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":4,\"character\":12}}}");
    frame(&mut ses, &b);
    // definition of norm2 (line 4, char 15) -> util.spc method name
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":4,\"character\":15}}}");
    frame(&mut ses, &b);
    // hover on the `x` field initializer: the field's trailing same-line comment is its doc
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":3,\"character\":26}}}");
    frame(&mut ses, &b);
    // hover on norm2's `self` parameter (util.spc is in the package without being open): the fn
    // docs must NOT leak onto it
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/util.spc\"},\"position\":{\"line\":8,\"character\":20}}}");
    frame(&mut ses, &b);
    // hover on norm2 itself: the doc comment above the method must travel into the hover
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":4,\"character\":15}}}");
    frame(&mut ses, &b);
    // rename Point (line 3, char 19) -> Pt: edits must be the bare name, never the util:: prefix
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":3,\"character\":19},\"newName\":\"Pt\"}}");
    frame(&mut ses, &b);
    // renaming to a keyword must fail
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":3,\"character\":19},\"newName\":\"while\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"shutdown\",\"params\":null}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(&mut ses, &b);
    p.mkfile("session.bin", ses.as_str());

    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0);

    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    let out = loader::read_file(op.as_str()).unwrap();
    let o = out.as_str();
    assert(o.contains("```super-c\\nPoint\\n```")); // hover: the receiver's rendered type
    // the doc appears in norm2's hover (id 20) and ONLY there -- the param hover (id 21) must not
    // inherit it
    assert_eq(count(o, "The squared Euclidean norm."), 1 as usize);
    assert(o.contains("horizontal component")); // the field's trailing comment travels into hover
    assert(o.contains("/src/util.spc\",\"range\":{\"start\":{\"line\":8,\"character\":11}")); // norm2 def site
    // the rename touches both files with the bare name span (line 3 char 18..23 in main)
    assert(
        o.contains(
            "\"range\":{\"start\":{\"line\":3,\"character\":18},\"end\":{\"line\":3,\"character\":23}},\"newText\":\"Pt\"",
        ),
    );
    assert(o.contains("/src/util.spc\":[{\"range\""));
    assert(o.contains("\"id\":5,\"error\":{\"code\":-32803"));
}

// Member completion after `.` runs a probe build (the buffer no longer parses mid-edit); formatting
// returns no edits for an already-canonical file; semantic tokens deliver a data array.
const MAIN_DOT: str = "import util;\n\nfn main() i32 {\n    let p = util::Point { x: 3, y: 4 };\n    p.\n    let n = 1;\n    return n;\n}\n";

@test
fn lsp_completion_formatting_tokens() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/util.spc", UTIL_SRC);
    p.mkfile("src/main.spc", MAIN_PT);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(MAIN_PT, &mut b);
    b.push_str("}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"options\":{\"tabSize\":4,\"insertSpaces\":true}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"}}}");
    frame(&mut ses, &b);
    // break the buffer with a dangling `p.` and complete after the dot (line 4, char 6)
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"version\":2},\"contentChanges\":[{\"text\":");
    json::dump_escaped(MAIN_DOT, &mut b);
    b.push_str("}]}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":4,\"character\":6}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"shutdown\",\"params\":null}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(&mut ses, &b);
    p.mkfile("session.bin", ses.as_str());

    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0);

    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    let out = loader::read_file(op.as_str()).unwrap();
    let o = out.as_str();
    assert(o.contains("\"id\":2,\"result\":[]")); // canonical file: no formatting edits
    assert(o.contains("\"id\":3,\"result\":{\"data\":[")); // semantic tokens delivered
    assert(o.contains("{\"label\":\"norm2\",\"kind\":2")); // probe-built member completion
    assert(o.contains("{\"label\":\"x\",\"kind\":5"));
}

// Lint warnings with LintFix payloads surface as quickfix code actions (errors never do).
const MAIN_UNUSED: str = "fn main() i32 {\n    let unused = 1;\n    return 0;\n}\n";

@test
fn lsp_code_actions() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", MAIN_UNUSED);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(MAIN_UNUSED, &mut b);
    b.push_str("}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str(
        "/src/main.spc\"},\"range\":{\"start\":{\"line\":1,\"character\":8},\"end\":{\"line\":1,\"character\":14}},\"context\":{\"diagnostics\":[]}}}",
    );
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\",\"params\":null}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(&mut ses, &b);
    p.mkfile("session.bin", ses.as_str());

    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0);

    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    let out = loader::read_file(op.as_str()).unwrap();
    let o = out.as_str();
    assert(o.contains("\"title\":\"Prefix with '_'\",\"kind\":\"quickfix\""));
    assert(o.contains("\"message\":\"unused variable 'unused'\""));
    // the edit inserts '_' at the binding start (an empty range at line 1, char 8)
    assert(
        o.contains(
            "{\"range\":{\"start\":{\"line\":1,\"character\":8},\"end\":{\"line\":1,\"character\":8}},\"newText\":\"_\"}",
        ),
    );
}

// Regression: completion on a mid-edit buffer whose probe build contains switch-arm PATTERN nodes
// (Some/None) once read a pattern node's bytes as a name Span (untagged NodeAs union) -- a negative
// length that made the server malloc 16 EB and abort. The probe splice lands at the broken cast's
// end, exactly the crashing session.
const MAIN_SWITCH: str = "fn pick(v: i64) i64 {\n    let r = (switch v > 0 {\n        true => v,\n        false => -1,\n    });\n    let w = r as i6\n    return w;\n}\n\nfn main() i64 {\n    return pick(1) - 1;\n}\n";

@test
fn lsp_completion_survives_pattern_nodes() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", MAIN_SWITCH);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(MAIN_SWITCH, &mut b);
    b.push_str("}}}");
    frame(&mut ses, &b);
    // completion at the end of the dangling `r as i6` (line 5, char 19): general path via probe
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":5,\"character\":19}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\",\"params\":null}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(&mut ses, &b);
    p.mkfile("session.bin", ses.as_str());

    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0); // the server must not crash

    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    let out = loader::read_file(op.as_str()).unwrap();
    let o = out.as_str();
    assert(o.contains("{\"label\":\"r\"")); // locals still complete through the probe build
    assert(o.contains("{\"label\":\"i64\"")); // builtin type names present
}

// Rename is workspace-relative: a definition outside the workspace (the installed std next to the
// binary) refuses; a workspace that contains its own std -- this repo -- may rename std symbols.
const MAIN_VEC: str = "fn main() i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    return v.len() as i32 - 1;\n}\n";

fn rename_session(root: str, doc_uri_prefix: str, ses: &mut String) {
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\"}}");
    frame(ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(doc_uri_prefix);
    b.push_str("/src/main.spc\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(MAIN_VEC, &mut b);
    b.push_str("}}}");
    frame(ses, &b);
    // rename Vector::push at its call site (line 2, char 7) -> "shove"
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(doc_uri_prefix);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":2,\"character\":7},\"newName\":\"shove\"}}");
    frame(ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\",\"params\":null}");
    frame(ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(ses, &b);
}

fn run_lsp_session(root: str, ses: &String) String {
    let mut sp = String::from_str(root);
    sp.push_str("/session.bin");
    let f = stdio::fopen(sp.as_str(), "wb");
    unsafe stdio::fwrite(ses.as_str().ptr(), 1, ses.len(), f);
    unsafe stdio::fclose(f);
    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0);
    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    return loader::read_file(op.as_str()).unwrap();
}

@test
fn lsp_rename_workspace_relative() {
    // outside: a temp workspace does not contain the installed std -> refused
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", MAIN_VEC);
    let root = str::from_cstr(p.rootp());
    let mut ses = String::new();
    rename_session(root, root, &mut ses);
    let out = run_lsp_session(root, &ses);
    assert(out.as_str().contains("cannot rename: the definition is outside the workspace"));

    // inside: this repo's workspace contains std/ -- renaming Vector::push answers with edits that
    // reach std/vector.spc (nothing is written: rename only RETURNS a WorkspaceEdit)
    let mut rb = Array::<char, 4096>::new();
    let mut dot = String::from_str(".");
    assert(unsafe shim::sc_realpath(dot.cstr(), &mut rb[0]) != null);
    let repo = str::from_cstr(&rb[0]);
    let p2 = cli::proj_new(); // scratch dir for the session/out files only
    let root2 = str::from_cstr(p2.rootp());
    let mut ses2 = String::new();
    rename_session(repo, repo, &mut ses2);
    let mut sp = String::from_str(root2);
    sp.push_str("/session.bin");
    let f = stdio::fopen(sp.as_str(), "wb");
    unsafe stdio::fwrite(ses2.as_str().ptr(), 1, ses2.len(), f);
    unsafe stdio::fclose(f);
    let mut cmd = String::new();
    cmd.push_str(superc_path());
    cmd.push_str(" lsp < '");
    cmd.push_str(root2);
    cmd.push_str("/session.bin' > '");
    cmd.push_str(root2);
    cmd.push_str("/out.txt' 2> /dev/null");
    let rc = cli::run_shell(cmd.cstr());
    assert_eq(rc, 0);
    let mut op = String::from_str(root2);
    op.push_str("/out.txt");
    let out2 = loader::read_file(op.as_str()).unwrap();
    assert(out2.as_str().contains("std/vector.spc"));
    assert(out2.as_str().contains("\"newText\":\"shove\""));
    assert(!out2.as_str().contains("cannot rename"));
}

// The compiler regression the server depends on: embedding loader::Package by value from another
// module demands its `[NodeId; BT_COUNT_N]` field's length (an enum-cast const) before the loader
// module is typechecked. Compile a two-module project with the same shape end-to-end.
@test
fn cross_module_enum_cast_array_len() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.spc",
        r#"pub enum Kind {
    A,
    B,
    C,
    COUNT,
}

pub const N: usize = Kind::COUNT as usize;

pub struct Table {
    pub slots: [u32; N],
}
"#,
    );
    p.mkfile(
        "main.spc",
        r#"import lib;

struct Holder {
    pub t: lib::Table,
}

fn main() i32 {
    let h = Holder { t: lib::Table { slots: [1u32, 2u32, 3u32] } };
    return (h.t.slots[2] - 3) as i32;
}
"#,
    );
    let r = p.compile("main.spc");
    assert_eq(r.exit, 0);
    let b = p.cc_build("");
    assert_eq(b.exit, 0);
    assert_eq(p.run_bin(), 0);
}
