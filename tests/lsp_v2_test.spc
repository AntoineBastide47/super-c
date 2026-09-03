// LSP v2 integration: lifecycle gating, request validation, cancellation, context-aware completion
// (attributes, attribute arguments, lexical scope, member privacy, labels, imports), rename safety
// (prepareRename, conflicts, interface relations), and the navigation features: all driven as
// framed JSON-RPC sessions against a `super-c lsp` subprocess, plus the parser's attribute
// inventory as the completion source of truth.
import tests::cli_harness as cli;
import module::loader as loader;
import lsp::json as json;
import ast::parser as par;

fn frame(out: &mut String, body: &String) {
    out.format_into("Content-Length: {}\r\n\r\n", body.len());
    out.push_string(body);
}

fn lsp_run(root: str) i32 {
    let mut cmd = String::new();
    cmd.push_str("\"");
    cmd.push_str(cli::superc_path());
    cmd.push_str("\" lsp");
    let mut inp = String::from_str(root);
    inp.push_str("/session.bin");
    let mut outp = String::from_str(root);
    outp.push_str("/out.txt");
    let mut errp = String::from_str(root);
    errp.push_str("/err.txt");
    return cli::run_io(cmd.cstr(), inp.cstr(), outp.cstr(), errp.cstr());
}

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

fn push_init(ses: &mut String, root: str) {
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str(
        "\",\"capabilities\":{\"textDocument\":{\"documentSymbol\":{\"hierarchicalDocumentSymbolSupport\":true}}}}}",
    );
    frame(ses, &b);
}

fn push_open(ses: &mut String, root: str, rel: str, src: str) {
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_byte(b'/');
    b.push_str(rel);
    b.push_str("\",\"languageId\":\"super-c\",\"version\":1,\"text\":");
    json::dump_escaped(src, &mut b);
    b.push_str("}}}");
    frame(ses, &b);
}

fn push_completion(ses: &mut String, root: str, rel: str, id: i64, line: i64, ch: i64) {
    let mut b = String::new();
    b.format_into("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"textDocument/completion\",\"params\":{{", id);
    b.push_str("\"textDocument\":{\"uri\":\"file://");
    b.push_str(root);
    b.push_byte(b'/');
    b.push_str(rel);
    b.format_into("\"}},\"position\":{{\"line\":{},\"character\":{}}}}}}}", line, ch);
    frame(ses, &b);
}

fn push_req_at(ses: &mut String, root: str, rel: str, id: i64, method: str, line: i64, ch: i64) {
    let mut b = String::new();
    b.format_into("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"", id);
    b.push_str(method);
    b.push_str("\",\"params\":{\"textDocument\":{\"uri\":\"file://");
    b.push_str(root);
    b.push_byte(b'/');
    b.push_str(rel);
    b.format_into("\"}},\"position\":{{\"line\":{},\"character\":{}}}}}}}", line, ch);
    frame(ses, &b);
}

fn push_shutdown_exit(ses: &mut String, id: i64) {
    let mut b = String::new();
    b.format_into("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"shutdown\",\"params\":null}}", id);
    frame(ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    frame(ses, &b);
}

fn read_out(root: str) String {
    let mut op = String::from_str(root);
    op.push_str("/out.txt");
    return loader::read_file(op.as_str()).unwrap();
}

// Lifecycle, validation, cancellation.

const MAIN_OK: str = "fn main() i32 {\n    return 0;\n}\n";

@test
fn lsp_lifecycle_and_cancellation() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", MAIN_OK);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    let mut b = String::new();
    // A request before initialize: -32002.
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/hover\",\"params\":{}}");
    frame(&mut ses, &b);
    push_init(&mut ses, root);
    // A second initialize: rejected.
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"initialize\",\"params\":{}}");
    frame(&mut ses, &b);
    // A bad jsonrpc version: rejected.
    b.clear();
    b.push_str("{\"jsonrpc\":\"1.0\",\"id\":12,\"method\":\"textDocument/hover\",\"params\":{}}");
    frame(&mut ses, &b);
    // An invalid id type: rejected without a crash.
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":[1],\"method\":\"textDocument/hover\",\"params\":{}}");
    frame(&mut ses, &b);
    // Cancel id 13, then send request 13: RequestCancelled, no work.
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":13}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/hover\",\"params\":{}}");
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 14);
    p.mkfile("session.bin", ses.as_str());

    let rc = lsp_run(root);
    assert_eq(rc, 0);
    let out = read_out(root);
    let o = out.as_str();
    // Not initialized.
    assert(o.contains("-32002"));
    // Repeated initialize.
    assert(o.contains("already accepted"));
    // Bad jsonrpc.
    assert(o.contains("\"id\":12") && o.contains("-32600"));
    // Canceled before dispatch.
    assert(o.contains("-32800"));
    assert(o.contains("\"positionEncoding\":\"utf-16\""));
    assert(o.contains("signatureHelpProvider"));
}

// Completion: attributes and attribute arguments.

@test
fn lsp_completion_attributes() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "@\nfn main() i32 {\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", src);
    // Right after '@'.
    push_completion(&mut ses, root, "src/main.spc", 2, 0, 1);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // The parser's whole inventory is served: c-namespace, tests, derive, platform, formatter.
    assert(o.contains("{\"label\":\"c.cold\""));
    assert(o.contains("{\"label\":\"c.always_inline\""));
    assert(o.contains("{\"label\":\"c.export\""));
    assert(o.contains("{\"label\":\"test\""));
    assert(o.contains("{\"label\":\"test_init\""));
    assert(o.contains("{\"label\":\"derive\""));
    assert(o.contains("{\"label\":\"platform\""));
    assert(o.contains("{\"label\":\"reflect\""));
    assert(o.contains("{\"label\":\"emit_macro\""));
    assert(o.contains("{\"label\":\"no_const\""));
    assert(o.contains("{\"label\":\"fmt.skip\""));
    assert(o.contains("{\"label\":\"bench\""));
}

@test
fn lsp_completion_attribute_args() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "@platform(mac)\nfn main() i32 {\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", src);
    // Inside @platform(...)
    push_completion(&mut ses, root, "src/main.spc", 2, 0, 13);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    assert(o.contains("{\"label\":\"macos\""));
    assert(o.contains("{\"label\":\"linux\""));
    assert(o.contains("{\"label\":\"windows\""));
    assert(o.contains("{\"label\":\"wasm\""));
}

@test
fn lsp_completion_derive_args() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "@derive(Clo)\nstruct P {\n    pub x: i32,\n}\n\nfn main() i32 {\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", src);
    // Inside @derive(...)
    push_completion(&mut ses, root, "src/main.spc", 2, 0, 11);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // Prelude interfaces are the derive vocabulary.
    assert(o.contains("{\"label\":\"Clone\""));
    assert(o.contains("{\"label\":\"Format\""));
    assert(o.contains("{\"label\":\"Hash\""));
}

@test
fn lsp_completion_derive_visibility() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "import util;\n\n@derive(Vis)\nstruct P {\n    pub x: i32,\n}\n\nfn main() i32 {\n    util::touch();\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    // Util imports hidden, so hidden is IN the package; main itself never imports it.
    p.mkfile(
        "src/util.spc",
        "import hidden;\n\npub interface VisibleIface {\n    fn probe(self: &Self) i32;\n}\n\npub fn touch() {\n    hidden::unused();\n}\n",
    );
    p.mkfile(
        "src/hidden.spc",
        "pub interface HiddenIface {\n    fn probe2(self: &Self) i32;\n}\n\npub fn unused() {}\n",
    );
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", src);
    // Inside @derive(...)
    push_completion(&mut ses, root, "src/main.spc", 2, 2, 11);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // The imported module's public interface is offered; a package module the current module never
    // imports is not: an unqualified @derive of it would not resolve.
    assert(o.contains("{\"label\":\"VisibleIface\""));
    assert(!o.contains("HiddenIface"));
    assert(o.contains("{\"label\":\"Clone\""));
}

// Completion: lexical scope, member privacy, labels, imports.

const SCOPE_SRC: str = "fn first() i32 {\n    let alpha = 1;\n    return alpha;\n}\n\nfn second() i32 {\n    let beta = 2;\n    return beta;\n}\n\nfn third(o: Option<i32>) i32 {\n    switch o {\n        Some(inner) => {\n            return inner;\n        },\n        None => {},\n    };\n    return 0;\n}\n";

@test
fn lsp_completion_lexical_scope() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/lib.spc\"\n");
    p.mkfile("src/lib.spc", SCOPE_SRC);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/lib.spc", SCOPE_SRC);
    // Inside second().
    push_completion(&mut ses, root, "src/lib.spc", 2, 7, 4);
    // In third(), after the switch.
    push_completion(&mut ses, root, "src/lib.spc", 3, 16, 4);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // In scope at the cursor.
    assert(o.contains("{\"label\":\"beta\""));
    // A sibling function's local never leaks.
    assert(!o.contains("{\"label\":\"alpha\""));
    // A closed match-arm binder never leaks.
    assert(!o.contains("{\"label\":\"inner\""));
    // The enclosing function's parameter is offered.
    assert(o.contains("{\"label\":\"o\""));
}

const UTIL_SRC: str = "pub struct Box2 {\n    pub w: i32,\n    h: i32,\n}\n\npub fn make() Box2 {\n    return Box2 { w: 1, h: 2 };\n}\n";
const PRIV_MAIN: str = "import util;\n\nfn main() i32 {\n    let b = util::make();\n    let x = b.\n    return 0;\n}\n";

@test
fn lsp_completion_member_privacy() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PRIV_MAIN);
    p.mkfile("src/util.spc", UTIL_SRC);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", PRIV_MAIN);
    // After `b.`.
    push_completion(&mut ses, root, "src/main.spc", 2, 4, 14);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // Public field offered cross-module.
    assert(o.contains("{\"label\":\"w\""));
    // Private field never offered outside its module.
    assert(!o.contains("{\"label\":\"h\""));
}

const LABEL_SRC: str = "fn main() i32 {\n    'outer: while true {\n        break 'outer;\n    }\n    return 0;\n}\n";

@test
fn lsp_completion_labels() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", LABEL_SRC);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", LABEL_SRC);
    // Right after the label quote.
    push_completion(&mut ses, root, "src/main.spc", 2, 2, 15);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    assert(out.as_str().contains("{\"label\":\"outer\""));
}

@test
fn lsp_completion_import_paths() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "import \nfn main() i32 {\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", src);
    // After `import `.
    push_completion(&mut ses, root, "src/main.spc", 2, 0, 7);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    // Module items offered.
    assert(out.as_str().contains("\"kind\":9"));
}

// Rename: prepare, conflicts, interface relations.

const RENAME_SRC: str = "fn foo() i32 {\n    return 1;\n}\n\nfn bar() i32 {\n    return foo();\n}\n\nfn main() i32 {\n    return bar() - 1;\n}\n";

@test
fn lsp_rename_conflicts_and_prepare() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", RENAME_SRC);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", RENAME_SRC);
    push_req_at(&mut ses, root, "src/main.spc", 2, "textDocument/prepareRename", 0, 4);
    // Renaming foo to bar collides with the existing bar.
    let mut b = String::new();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"bar\"}}");
    frame(&mut ses, &b);
    // Renaming foo to baz is clean: the declaration and the call site both edit.
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"baz\"}}");
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    assert(o.contains("\"placeholder\":\"foo\""));
    // The conflicting rename rejected.
    assert(o.contains("already exists"));
    // Declaration + call site.
    assert(count(o, "\"newText\":\"baz\"") >= 2);
}

const IFACE_SRC: str = "interface Greet {\n    fn hi(self: &Self) i32;\n}\n\nstruct S {\n    pub x: i32,\n}\n\nextend S as Greet {\n    pub fn hi(self: &Self) i32 {\n        return self.x;\n    }\n}\n\nfn main() i32 {\n    let s = S { x: 1 };\n    return s.hi() - 1;\n}\n";

@test
fn lsp_rename_interface_relations() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", IFACE_SRC);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", IFACE_SRC);
    // Rename at the INTERFACE's method declaration: the conformer and the call rename with it.
    let mut b = String::new();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"position\":{\"line\":1,\"character\":8},\"newName\":\"yo\"}}");
    frame(&mut ses, &b);
    // Implementation navigation from the interface name.
    push_req_at(&mut ses, root, "src/main.spc", 3, "textDocument/implementation", 0, 11);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // Interface decl + conformer + call site.
    assert(count(o, "\"newText\":\"yo\"") >= 3);
    assert(o.contains("\"id\":3") && !o.contains("\"error\""));
}

// Navigation smoke: symbols, signature help, folding, selection, highlights, hints.

const NAV_SRC: str = "struct Point {\n    pub x: i32,\n    pub y: i32,\n}\n\nfn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n\nfn main() i32 {\n    let p = Point { x: 1, y: 2 };\n    let s = add(p.x, p.y);\n    return s - 3;\n}\n";

@test
fn lsp_navigation_features() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", NAV_SRC);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init(&mut ses, root);
    push_open(&mut ses, root, "src/main.spc", NAV_SRC);
    let mut b = String::new();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Poi\"}}");
    frame(&mut ses, &b);
    push_req_at(&mut ses, root, "src/main.spc", 4, "textDocument/signatureHelp", 11, 17);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"}}}");
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/selectionRange\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str("/src/main.spc\"},\"positions\":[{\"line\":11,\"character\":17}]}}");
    frame(&mut ses, &b);
    push_req_at(&mut ses, root, "src/main.spc", 7, "textDocument/documentHighlight", 10, 8);
    push_req_at(&mut ses, root, "src/main.spc", 8, "textDocument/typeDefinition", 10, 8);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str(
        "/src/main.spc\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":13,\"character\":0}}}}",
    );
    frame(&mut ses, &b);
    b.clear();
    b.push_str(
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/semanticTokens/range\",\"params\":{\"textDocument\":{\"uri\":\"file://",
    );
    b.push_str(root);
    b.push_str(
        "/src/main.spc\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":4,\"character\":0}}}}",
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 20);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    assert(!o.contains("\"error\""));
    // Document + workspace symbols.
    assert(o.contains("\"name\":\"Point\""));
    assert(o.contains("\"name\":\"add\""));
    // Signature help label.
    assert(o.contains("fn add(a: i32, b: i32) i32"));
    // Folding.
    assert(o.contains("\"startLine\""));
    // Selection range chain.
    assert(o.contains("\"parent\""));
    // Inlay type hint for `let p`.
    assert(o.contains(": Point"));
    // The range token request answered.
    assert(count(o, "\"data\":[") == 1);
}

// The attribute inventory is real: every listed spelling must classify in the parser.

@test
fn attribute_inventory_is_complete() {
    let mut names = Vector::<String>::new();
    par::known_attributes(&mut names);
    assert(names.len() >= 24);
    let want = "c.cold c.always_inline c.export c.import c.align test test_init test_free derive reflect platform arch fmt.skip emit_macro bench blocking no_const c.source c.link";
    let mut it = want.split(" ");
    loop {
        let w = it.next();
        if w.is_none() {
            break;
        }
        let nm = w.unwrap();
        let mut found = false;
        for i in 0..names.len() {
            if names.at(i).as_str() == nm {
                found = true;
            }
        }
        assert(found, "attribute missing from the inventory");
    }
    let mut plats = Vector::<String>::new();
    par::platform_arg_names(&mut plats);
    assert_eq(plats.len(), 4);
    let mut archs = Vector::<String>::new();
    par::arch_arg_names(&mut archs);
    assert_eq(archs.len(), 3);
}

// Gap coverage: incremental sync, pull diagnostics, delta tokens, code actions, hierarchies, limits.

// initialize with a caller-chosen capabilities object and initializationOptions ("" = none).
fn push_init_caps(ses: &mut String, root: str, caps: str, opts: str) {
    let mut b = String::from_str(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://",
    );
    b.push_str(root);
    b.push_str("\",\"capabilities\":");
    b.push_str(caps);
    if opts.len() != 0 {
        b.push_str(",\"initializationOptions\":");
        b.push_str(opts);
    }
    b.push_str("}}");
    frame(ses, &b);
}

// The single framed response BODY containing `marker`: from the marker's message start (the byte
// after the framing header's blank line) to the next `Content-Length:` header or end of output.
fn response_of<'a>(out: str<'a>, marker: str) str<'a> {
    let hdr = "Content-Length:";
    let mut i: usize = 0;
    while i + marker.len() <= out.len() {
        if out.slice(i, i + marker.len()) == marker {
            let mut s = i;
            while s > 3 && out.slice(s - 4, s) != "\r\n\r\n" {
                s -= 1;
            }
            let mut e = i;
            while e + hdr.len() <= out.len() && out.slice(e, e + hdr.len()) != hdr {
                e += 1;
            }
            if e + hdr.len() > out.len() {
                e = out.len();
            }
            return out.slice(s, e);
        }
        i += 1;
    }
    return "";
}

// The value of the FIRST `"resultId":"..."` in `hay` after `from` ("" when absent).
fn result_id_in<'a>(hay: str<'a>) str<'a> {
    let key = "\"resultId\":\"";
    let mut i: usize = 0;
    while i + key.len() <= hay.len() {
        if hay.slice(i, i + key.len()) == key {
            let s = i + key.len();
            let mut e = s;
            while e < hay.len() && hay[e] != b'"' {
                e += 1;
            }
            return hay.slice(s, e);
        }
        i += 1;
    }
    return "";
}

fn push_did_change_ranged(ses: &mut String, root: str, rel: str, version: i64, changes: str) {
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/{}\",\"version\":{}}},\"contentChanges\":{}}}}}",
        root,
        rel,
        version,
        changes,
    );
    frame(ses, &b);
}

fn push_formatting(ses: &mut String, root: str, rel: str, id: i64) {
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"textDocument/formatting\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/{}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}}}",
        id,
        root,
        rel,
    );
    frame(ses, &b);
}

@test
fn lsp_incremental_sync() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "fn main() i32 {\n    let s = \"\xF0\x9D\x9B\xBC\"; let t = 1;\n    return t;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    let mut ses = String::new();
    push_init_caps(&mut ses, root, "{}", "");
    push_open(&mut ses, root, "src/main.spc", src);
    // Two in-order ranged edits; the second's coordinates assume the first is applied. The astral
    // scalar before `t = 1` occupies TWO UTF-16 units, so `1` sits at character 26.
    push_did_change_ranged(
        &mut ses,
        root,
        "src/main.spc",
        2,
        "[{\"range\":{\"start\":{\"line\":1,\"character\":26},\"end\":{\"line\":1,\"character\":27}},\"text\":\"9\"},{\"range\":{\"start\":{\"line\":2,\"character\":4},\"end\":{\"line\":2,\"character\":4}},\"text\":\"let u = t;\\n    \"}]",
    );
    // An invalid range: the whole notification must be dropped (buffer keeps the edits above).
    push_did_change_ranged(
        &mut ses,
        root,
        "src/main.spc",
        3,
        "[{\"range\":{\"start\":{\"line\":99,\"character\":0},\"end\":{\"line\":99,\"character\":1}},\"text\":\"BAD\"}]",
    );
    push_formatting(&mut ses, root, "src/main.spc", 7);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());

    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    let fmt_resp = response_of(o, "\"id\":7");
    // Edit past the astral char landed on the right byte.
    assert(fmt_resp.contains("t = 9"));
    // Second edit applied on the post-edit coordinates.
    assert(fmt_resp.contains("let u = t;"));
    // The invalid-range notification was dropped whole.
    assert(!o.contains("BAD"));
}

@test
fn lsp_incremental_matches_full_sync() {
    // The same logical edit through ranged changes and through one full-text change must leave
    // identical analysis results (the parity precondition for advertising sync kind 2).
    let src = "fn main() i32 {\n    let t = 1;\n    return t;\n}\n";
    let edited = "fn main() i32 {\n    let t = 2;\n    return t;\n}\n";
    let mut outs = Vector::<String>::new();
    for mode in 0..2 {
        let p = cli::proj_new();
        p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
        p.mkfile("src/main.spc", src);
        let root = str::from_cstr(p.rootp());
        let mut ses = String::new();
        push_init_caps(&mut ses, root, "{}", "");
        push_open(&mut ses, root, "src/main.spc", src);
        if mode == 0 {
            push_did_change_ranged(
                &mut ses,
                root,
                "src/main.spc",
                2,
                "[{\"range\":{\"start\":{\"line\":1,\"character\":12},\"end\":{\"line\":1,\"character\":13}},\"text\":\"2\"}]",
            );
        } else {
            let mut chg = String::from_str("[{\"text\":");
            json::dump_escaped(edited, &mut chg);
            chg.push_str("}]");
            push_did_change_ranged(&mut ses, root, "src/main.spc", 2, chg.as_str());
        }
        push_formatting(&mut ses, root, "src/main.spc", 7);
        push_shutdown_exit(&mut ses, 9);
        p.mkfile("session.bin", ses.as_str());
        assert_eq(lsp_run(root), 0);
        let out = read_out(root);
        outs.push(String::from_str(response_of(out.as_str(), "\"id\":7")));
    }
    assert(outs.at(0).len() != 0);
    assert(outs.at(0).as_str() == outs.at(1).as_str());
}

@test
fn lsp_pull_diagnostics() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "fn main() i32 {\n    return q;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());
    let caps = "{\"textDocument\":{\"diagnostic\":{}}}";

    let mut ses = String::new();
    push_init_caps(&mut ses, root, caps, "");
    push_open(&mut ses, root, "src/main.spc", src);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/diagnostic\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    // Advertised because the client declared support.
    assert(o.contains("\"diagnosticProvider\""));
    let resp = response_of(o, "\"id\":3");
    assert(resp.contains("\"kind\":\"full\""));
    assert(resp.contains("cannot find"));
    let rid = result_id_in(resp);
    assert(rid.len() != 0);

    // A fresh server over identical content derives the SAME resultId (content-hashed), so passing
    // it back yields `unchanged` with no items.
    let mut ses2 = String::new();
    push_init_caps(&mut ses2, root, caps, "");
    push_open(&mut ses2, root, "src/main.spc", src);
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/diagnostic\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"previousResultId\":\"{}\"}}}}",
        root,
        rid,
    );
    frame(&mut ses2, &b);
    push_shutdown_exit(&mut ses2, 9);
    p.mkfile("session.bin", ses2.as_str());
    assert_eq(lsp_run(root), 0);
    let out2 = read_out(root);
    let resp2 = response_of(out2.as_str(), "\"id\":3");
    assert(resp2.contains("\"kind\":\"unchanged\""));
    assert(!resp2.contains("\"items\""));
}

@test
fn lsp_delta_semantic_tokens() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "fn main() i32 {\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());
    let caps = "{\"textDocument\":{\"semanticTokens\":{\"requests\":{\"full\":{\"delta\":true}}}}}";
    let ins = "fn extra() i32 {\\n    return 1;\\n}\\n";

    // Session A: full (resultId 1), append a fn, delta against resultId 1.
    let mut ses = String::new();
    push_init_caps(&mut ses, root, caps, "");
    push_open(&mut ses, root, "src/main.spc", src);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/semanticTokens/full\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    let mut chg = String::from_str(
        "[{\"range\":{\"start\":{\"line\":3,\"character\":0},\"end\":{\"line\":3,\"character\":0}},\"text\":\"",
    );
    chg.push_str(ins);
    chg.push_str("\"}]");
    push_did_change_ranged(&mut ses, root, "src/main.spc", 2, chg.as_str());
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/semanticTokens/full/delta\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"previousResultId\":\"1\"}}}}",
        root,
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out_a = read_out(root);

    // Session B: the same edit, then a fresh FULL request (the ground truth for reconstruction).
    let mut ses2 = String::new();
    push_init_caps(&mut ses2, root, caps, "");
    push_open(&mut ses2, root, "src/main.spc", src);
    push_did_change_ranged(&mut ses2, root, "src/main.spc", 2, chg.as_str());
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/semanticTokens/full\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}}}}}}",
        root,
    );
    frame(&mut ses2, &b);
    push_shutdown_exit(&mut ses2, 9);
    p.mkfile("session.bin", ses2.as_str());
    assert_eq(lsp_run(root), 0);
    let out_b = read_out(root);

    // Reconstruct: base data (A id 3) + splice edits (A id 4) == post-edit full data (B id 5).
    let base = json::parse(response_of(out_a.as_str(), "\"id\":3")).unwrap();
    let delta = json::parse(response_of(out_a.as_str(), "\"id\":4")).unwrap();
    let full2 = json::parse(response_of(out_b.as_str(), "\"id\":5")).unwrap();
    let bd = base.at_key("result").at_key("data");
    let fd = full2.at_key("result").at_key("data");
    let edits = delta.at_key("result").at_key("edits");
    assert(edits.is_array() && edits.size() == 1);
    let ed = edits.at(0);
    let start = ed.value_i64("start", -1);
    let delc = ed.value_i64("deleteCount", -1);
    assert(start >= 0 && delc >= 0);
    let mut rec = Vector::<i64>::new();
    for i in 0..start {
        rec.push(bd.at(i as usize).get_i64());
    }
    let nd = ed.at_key("data");
    for i in 0..nd.size() {
        rec.push(nd.at(i).get_i64());
    }
    let mut i = start as usize + delc as usize;
    while i < bd.size() {
        rec.push(bd.at(i).get_i64());
        i += 1;
    }
    assert_eq(rec.len(), fd.size());
    for i in 0..rec.len() {
        assert_eq(*rec.at(i), fd.at(i).get_i64());
    }
}

@test
fn lsp_code_actions_eager_and_fixall() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "fn main() i32 {\n    let unused_one = 1;\n    let unused_two = 2;\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());
    let caps = "{\"textDocument\":{\"codeAction\":{\"codeActionLiteralSupport\":{\"codeActionKind\":{\"valueSet\":[]}}}}}";

    let mut ses = String::new();
    push_init_caps(&mut ses, root, caps, "");
    push_open(&mut ses, root, "src/main.spc", src);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":5,\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    // context.only = source.fixAll: quickfixes filtered out.
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":5,\"character\":0}}}},\"context\":{{\"diagnostics\":[],\"only\":[\"source.fixAll\"]}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    let r3 = response_of(o, "\"id\":3");
    // Two unused imports: each gets an eager quickfix (no client resolveSupport), plus one fix-all.
    assert(count(r3, "\"kind\":\"quickfix\"") >= 2);
    assert(r3.contains("\"kind\":\"source.fixAll\""));
    assert(r3.contains("\"edit\""));
    let r4 = response_of(o, "\"id\":4");
    assert(!r4.contains("\"kind\":\"quickfix\""));
    assert(r4.contains("\"kind\":\"source.fixAll\""));
}

@test
fn lsp_code_action_resolve_and_stale() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "fn main() i32 {\n    let unused = 1;\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());
    let caps = "{\"textDocument\":{\"codeAction\":{\"codeActionLiteralSupport\":{\"codeActionKind\":{\"valueSet\":[]}},\"resolveSupport\":{\"properties\":[\"edit\"]}}}}";

    let mut ses = String::new();
    push_init_caps(&mut ses, root, caps, "");
    // Revision 1.
    push_open(&mut ses, root, "src/main.spc", src);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":4,\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    // Resolve the fix-all lazily (data constructed as the server does: uri + revision + fixall).
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"codeAction/resolve\",\"params\":{{\"title\":\"Fix all\",\"kind\":\"source.fixAll\",\"data\":{{\"uri\":\"file://{}/src/main.spc\",\"rev\":1,\"fixall\":true}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    // A stale revision: rejected.
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"codeAction/resolve\",\"params\":{{\"title\":\"Fix all\",\"kind\":\"source.fixAll\",\"data\":{{\"uri\":\"file://{}/src/main.spc\",\"rev\":0,\"fixall\":true}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    let r3 = response_of(o, "\"id\":3");
    // Lazy: data attached ...
    assert(r3.contains("\"data\""));
    // ... and no eager edit.
    assert(!r3.contains("\"edit\""));
    let r4 = response_of(o, "\"id\":4");
    // Resolve built it.
    assert(r4.contains("\"edit\""));
    let r5 = response_of(o, "\"id\":5");
    // Stale revision rejected.
    assert(r5.contains("-32803"));
}

@test
fn lsp_semantic_code_actions() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/util.spc", "pub fn helper() i32 {\n    return 1;\n}\n");
    // main: a conformance with a missing method (a TYPECHECK error; names all resolve).
    let src = "interface I {\n    fn m(self: &Self) i32;\n}\n\nstruct S {\n    pub x: i32,\n}\n\nextend S as I {\n}\n\nfn main() i32 {\n    return 0;\n}\n";
    p.mkfile("src/main.spc", src);
    // other: an unresolved call whose target lives in an unimported workspace module.
    let other = "pub fn go() i32 {\n    return helper();\n}\n";
    p.mkfile("src/other.spc", other);
    let root = str::from_cstr(p.rootp());
    let caps = "{\"textDocument\":{\"codeAction\":{\"codeActionLiteralSupport\":{\"codeActionKind\":{\"valueSet\":[]}}}}}";

    let mut ses = String::new();
    push_init_caps(&mut ses, root, caps, "");
    push_open(&mut ses, root, "src/main.spc", src);
    push_open(&mut ses, root, "src/other.spc", other);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":99,\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/codeAction\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/other.spc\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":99,\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    let r3 = response_of(o, "\"id\":3");
    // Missing interface method stub.
    assert(r3.contains("Implement 'm'"));
    assert(r3.contains("fn m(self: &Self) i32 {"));
    assert(r3.contains("panic("));
    let r4 = response_of(o, "\"id\":4");
    // Missing import offered from the workspace modules.
    assert(r4.contains("Import util"));
    assert(r4.contains("import util;\\n"));
}

@test
fn lsp_call_and_type_hierarchy() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "interface I {\n    fn m(self: &Self) i32;\n}\n\nstruct S {\n    pub x: i32,\n}\n\nextend S as I {\n    fn m(self: &Self) i32 {\n        return self.x;\n    }\n}\n\nfn leaf() i32 {\n    return 1;\n}\n\nfn caller() i32 {\n    return leaf() + leaf();\n}\n\nfn main() i32 {\n    return caller();\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    // Byte offsets of the declaration names (the hierarchy item's `data.off`).
    let sfind = String::from_str(src);
    let leaf_off = sfind.find("leaf");
    let caller_off = sfind.find("caller");
    let s_off = sfind.find("struct S") + 7;
    let i_off = sfind.find("interface I") + 10;

    let mut ses = String::new();
    push_init_caps(&mut ses, root, "{}", "");
    push_open(&mut ses, root, "src/main.spc", src);
    // Prepare on `leaf`'s declaration (line 14, character 3 -> inside the name).
    push_req_at(&mut ses, root, "src/main.spc", 3, "textDocument/prepareCallHierarchy", 14, 4);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"callHierarchy/incomingCalls\",\"params\":{{\"item\":{{\"data\":{{\"uri\":\"file://{}/src/main.spc\",\"off\":{}}}}}}}}}",
        root,
        leaf_off,
    );
    frame(&mut ses, &b);
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"callHierarchy/outgoingCalls\",\"params\":{{\"item\":{{\"data\":{{\"uri\":\"file://{}/src/main.spc\",\"off\":{}}}}}}}}}",
        root,
        caller_off,
    );
    frame(&mut ses, &b);
    // Type hierarchy: prepare on S, supertypes of S, subtypes of I.
    push_req_at(&mut ses, root, "src/main.spc", 6, "textDocument/prepareTypeHierarchy", 4, 7);
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"typeHierarchy/supertypes\",\"params\":{{\"item\":{{\"data\":{{\"uri\":\"file://{}/src/main.spc\",\"off\":{}}}}}}}}}",
        root,
        s_off,
    );
    frame(&mut ses, &b);
    b.clear();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"typeHierarchy/subtypes\",\"params\":{{\"item\":{{\"data\":{{\"uri\":\"file://{}/src/main.spc\",\"off\":{}}}}}}}}}",
        root,
        i_off,
    );
    frame(&mut ses, &b);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    let r3 = response_of(o, "\"id\":3");
    assert(r3.contains("\"name\":\"leaf\""));
    let r4 = response_of(o, "\"id\":4");
    assert(r4.contains("\"from\"") && r4.contains("\"name\":\"caller\""));
    // Both leaf() calls group under ONE caller entry.
    assert(count(r4, "\"fromRanges\"") == 1);
    let r5 = response_of(o, "\"id\":5");
    assert(r5.contains("\"to\"") && r5.contains("\"name\":\"leaf\""));
    let r6 = response_of(o, "\"id\":6");
    assert(r6.contains("\"name\":\"S\""));
    let r7 = response_of(o, "\"id\":7");
    // S's supertypes: the conformed interface.
    assert(r7.contains("\"name\":\"I\""));
    let r8 = response_of(o, "\"id\":8");
    // I's subtypes: the conformer.
    assert(r8.contains("\"name\":\"S\""));
}

@test
fn lsp_limits_and_eviction() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    let src = "fn foo() i32 {\n    return 1;\n}\n\nfn main() i32 {\n    return foo() + foo() + foo();\n}\n";
    p.mkfile("src/main.spc", src);
    let root = str::from_cstr(p.rootp());

    // MaxResults=1 bounds the reference batch; budgetMb=1 forces eviction of unpinned packages
    // after every round: later requests must still answer (the root rebuilds on demand).
    let mut ses = String::new();
    push_init_caps(&mut ses, root, "{}", "{\"maxResults\":1,\"budgetMb\":1}");
    push_open(&mut ses, root, "src/main.spc", src);
    let mut b = String::new();
    b.format_into(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/references\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{}/src/main.spc\"}},\"position\":{{\"line\":0,\"character\":4}},\"context\":{{\"includeDeclaration\":false}}}}}}",
        root,
    );
    frame(&mut ses, &b);
    push_req_at(&mut ses, root, "src/main.spc", 4, "textDocument/hover", 0, 4);
    push_shutdown_exit(&mut ses, 9);
    p.mkfile("session.bin", ses.as_str());
    assert_eq(lsp_run(root), 0);
    let out = read_out(root);
    let o = out.as_str();
    let r3 = response_of(o, "\"id\":3");
    // Three call sites, capped to maxResults=1.
    assert_eq(count(r3, "\"uri\""), 1);
    let r4 = response_of(o, "\"id\":4");
    // The budget-evicted package rebuilt and answered.
    assert(r4.contains("foo"));
}
