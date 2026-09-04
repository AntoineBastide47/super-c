// `super-c fmt` end to end: --check exit codes and path reporting, in-place rewrite of an unformatted
// file, idempotence of an already-formatted file, directory recursion, stdin, and the parse-failure
// path. Drives the built compiler as a subprocess over on-disk projects.
import tests::cli_harness as cli;
import module::loader as loader;

const UGLY: str = "fn  main( )i32{return   0;}\n";
const CLEAN: str = "fn main() i32 {\n    return 0;\n}\n";

fn read(root: str, rel: str) String {
    let mut p = String::from_str(root);
    p.push_byte(b'/');
    p.push_str(rel);
    return loader::read_file(p.as_str()).unwrap();
}

@test
fn fmt_check_reports_unformatted() {
    let p = cli::proj_new();
    p.mkfile("a.spc", UGLY);
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt --check \"");
    args.push_str(root);
    args.push_str("/a.spc\"");
    let r = p.run_raw(args.as_str());
    // --check writes nothing, prints the offending path, and exits 1.
    assert_eq(r.exit, 1);
    assert(r.out_has("a.spc"), "the unformatted path is named");
    // The file is untouched by --check.
    assert(read(root, "a.spc").as_str() == UGLY, "check does not rewrite");
}

@test
fn fmt_check_accepts_canonical() {
    let p = cli::proj_new();
    p.mkfile("a.spc", CLEAN);
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt --check \"");
    args.push_str(root);
    args.push_str("/a.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.ok(), "a canonical file passes --check");
}

@test
fn fmt_rewrites_in_place() {
    let p = cli::proj_new();
    p.mkfile("a.spc", UGLY);
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt \"");
    args.push_str(root);
    args.push_str("/a.spc\"");
    let r = p.run_raw(args.as_str());
    assert(r.ok(), "fmt rewrites and exits 0");
    // The rewrite is canonical, and a second --check now passes.
    assert(read(root, "a.spc").as_str() == CLEAN, "the file is now canonical");
    let mut cargs = String::from_str("fmt --check \"");
    cargs.push_str(root);
    cargs.push_str("/a.spc\"");
    assert(p.run_raw(cargs.as_str()).ok(), "the rewritten file is stable");
}

@test
fn fmt_recurses_a_directory() {
    let p = cli::proj_new();
    p.mkfile("src/a.spc", UGLY);
    p.mkfile("src/sub/b.spc", UGLY);
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt \"");
    args.push_str(root);
    args.push_str("/src\"");
    assert(p.run_raw(args.as_str()).ok(), "fmt on a directory succeeds");
    assert(read(root, "src/a.spc").as_str() == CLEAN, "top-level file formatted");
    assert(read(root, "src/sub/b.spc").as_str() == CLEAN, "nested file formatted");
}

@test
fn fmt_stdin_to_stdout() {
    let p = cli::proj_new();
    p.mkfile("in.spc", UGLY);
    let root = str::from_cstr(p.rootp());
    let mut inp = String::from_str(root);
    inp.push_str("/in.spc");
    let mut outp = String::from_str(root);
    outp.push_str("/out.txt");
    let mut cmd = String::from_str("\"");
    cmd.push_str(cli::superc_path());
    cmd.push_str("\" fmt -");
    let rc = cli::run_io(cmd.cstr(), inp.cstr(), outp.cstr(), null);
    assert_eq(rc, 0);
    // `-` reads stdin and writes the canonical form to stdout.
    assert(read(root, "out.txt").as_str() == CLEAN, "stdin formats to stdout");
}

@test
fn fmt_missing_file_errors() {
    let p = cli::proj_new();
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt \"");
    args.push_str(root);
    args.push_str("/nope.spc\"");
    let r = p.run_raw(args.as_str());
    assert_eq(r.exit, 1);
    assert(r.out_has("cannot read"), "a missing path is reported");
}

@test
fn fmt_unparseable_file_is_not_rewritten() {
    let p = cli::proj_new();
    let BAD: str = "fn main( { return }\n";
    p.mkfile("bad.spc", BAD);
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt \"");
    args.push_str(root);
    args.push_str("/bad.spc\"");
    let r = p.run_raw(args.as_str());
    // A file the compiler cannot parse: diagnostics, exit 1, and the bytes are left as they were.
    assert_eq(r.exit, 1);
    assert(read(root, "bad.spc").as_str() == BAD, "an unparseable file is never rewritten");
}

@test
fn fmt_check_a_feature_dense_file() {
    // The language demo exercises most language constructs; formatting it drives a broad swath of the
    // document formatter's node handlers and break/wrap decisions in one pass. It is kept canonical.
    let p = cli::proj_new();
    assert(p.copyfile("demo.spc", "examples/language_demo.spc"), "the demo is present");
    let root = str::from_cstr(p.rootp());
    let mut args = String::from_str("fmt --check \"");
    args.push_str(root);
    args.push_str("/demo.spc\"");
    // Canonical input passes --check; the value is the formatter breadth it exercises.
    assert(p.run_raw(args.as_str()).ok(), "the feature-dense file is already canonical");
}
