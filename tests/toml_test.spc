// build.toml parser tests: value kinds, sections, arrays/inline tables, and error rejection.
import build_system::toml as toml;
import build_system::manifest as manifest;
import utils::errors as diag;

fn parse_ok(src: str) Vector<toml::TomlItem> {
    let items = toml::parse(src, "test.toml");
    assert(!items.is_none());
    return items.unwrap();
}

fn find(items: &Vector<toml::TomlItem>, sec: str, key: str) i64 {
    for i in 0..items.len() {
        if items.at(i).section.as_str() == sec && items.at(i).key.as_str() == key {
            return i as i64;
        }
    }
    return -1;
}

@test
fn toml_scalars() {
    let items = parse_ok("bin = \"app\" # comment\njobs = 8\nneg = -3\nflag = true\noff = false\n");
    assert_eq(items.len(), 5 as usize);
    let b = find(&items, "", "bin");
    assert(b >= 0);
    assert(items.at(b as usize).val.kind == toml::TV_STR);
    assert(items.at(b as usize).val.s.as_str() == "app");
    let j = find(&items, "", "jobs");
    assert(items.at(j as usize).val.kind == toml::TV_INT);
    assert_eq(items.at(j as usize).val.i, 8 as i64);
    let n = find(&items, "", "neg");
    assert_eq(items.at(n as usize).val.i, (-3) as i64);
    let f = find(&items, "", "flag");
    assert(items.at(f as usize).val.kind == toml::TV_BOOL);
    assert(items.at(f as usize).val.b);
    let o = find(&items, "", "off");
    assert(!items.at(o as usize).val.b);
}

@test
fn toml_sections_arrays_tables() {
    let items = parse_ok(
        "[profile.release]\ncflags = [\n    \"-O3\",\n    \"-DNDEBUG\",\n]\nstrip = true\n[command.test]\nenv = { SUPERC = \"./super-c\", CC = \"cc\" }\nrun = [\"a\", \"b\"]\n",
    );
    let c = find(&items, "profile.release", "cflags");
    assert(c >= 0);
    assert(items.at(c as usize).val.kind == toml::TV_ARR);
    assert_eq(items.at(c as usize).val.arr.len(), 2 as usize);
    assert(items.at(c as usize).val.arr.at(1).as_str() == "-DNDEBUG");
    let e = find(&items, "command.test", "env");
    assert(e >= 0);
    assert(items.at(e as usize).val.kind == toml::TV_TBL);
    assert_eq(items.at(e as usize).val.tbl.len(), 2 as usize);
    assert(items.at(e as usize).val.tbl.at(0).k.as_str() == "SUPERC");
    assert(items.at(e as usize).val.tbl.at(0).v.as_str() == "./super-c");
}

@test
fn toml_string_escapes() {
    let items = parse_ok("s = \"a\\n\\t\\\"b\\\\\"\n");
    let s = find(&items, "", "s");
    assert(items.at(s as usize).val.s.as_str() == "a\n\t\"b\\");
}

@test
fn toml_rejects_malformed() {
    // Missing '='.
    assert(toml::parse("bin \"app\"\n", "t").is_none());
    // Unterminated string.
    assert(toml::parse("bin = \"app\n", "t").is_none());
    // Malformed section.
    assert(toml::parse("[oops\nbin = \"a\"\n", "t").is_none());
    // Non-string array.
    assert(toml::parse("a = [1, 2]\n", "t").is_none());
    // Trailing junk.
    assert(toml::parse("a = \"x\" b = \"y\"\n", "t").is_none());
}

fn toml_err(label: str, src: str, want: str) {
    let mut errs = diag::Errors::new();
    let r = toml::parse_into(src, &mut errs);
    assert(r.is_none(), label);
    assert(errs.errors.len() >= 1, label);
    assert_eq(errs.errors.at(0).msg.as_str(), want);
}

fn manifest_err(label: str, src: str, want: str) {
    let (m, errs) = manifest::parse_check(src, "");
    assert(m.is_none(), label);
    assert(errs.errors.len() >= 1, label);
    assert_eq(errs.errors.at(0).msg.as_str(), want);
}

@test
fn toml_error_messages() {
    toml_err("integer array", "a = [1, 2]\n", "arrays may only contain strings");
    toml_err("sign without digits", "a = -x\n", "expected digits");
    toml_err("missing key", "= 1\n", "expected key");
    toml_err("missing inline key", "a = { = 1 }\n", "expected key in inline table");
    toml_err("missing value", "a = \n", "expected value");
    toml_err("inline integer", "a = { b = 1 }\n", "inline tables may only contain string values");
    toml_err("open section", "[abc\n", "malformed section header");
    toml_err("trailing token", "a = 1 b\n", "unexpected trailing characters");
    toml_err("bad escape", "a = \"\\q\"\n", "unknown escape in string");
    toml_err("open string", "a = \"abc\n", "unterminated string");
}

@test
fn manifest_validation_messages() {
    manifest_err(
        "const-eval-memory",
        "bin = \"a\"\nroot = \"m.spc\"\nconst-eval-memory = \"x\"\n",
        "'const-eval-memory' expects a non-negative integer (bytes)",
    );
    manifest_err(
        "const-eval-steps",
        "bin = \"a\"\nroot = \"m.spc\"\nconst-eval-steps = \"x\"\n",
        "'const-eval-steps' expects a non-negative integer",
    );
    manifest_err(
        "command env",
        "bin = \"a\"\nroot = \"m.spc\"\n[command.x]\nenv = 5\n",
        "'env' expects an inline table of strings",
    );
    manifest_err("jobs", "bin = \"a\"\nroot = \"m.spc\"\njobs = \"x\"\n", "'jobs' expects a non-negative integer");
    manifest_err("bin string", "bin = 5\nroot = \"m.spc\"\n", "'bin' expects a string");
    manifest_err(
        "cflags array",
        "bin = \"a\"\nroot = \"m.spc\"\ncflags = \"x\"\n",
        "'cflags' expects an array of strings",
    );
    manifest_err(
        "strip bool",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.dev]\nstrip = 1\n",
        "'strip' expects true or false",
    );
    manifest_err(
        "absolute test-dir",
        "bin = \"a\"\nroot = \"m.spc\"\ntest-dir = \"/abs\"\n",
        "'test-dir' must be a plain workspace-relative directory, got '/abs'",
    );
    manifest_err(
        "parent bench-dir",
        "bin = \"a\"\nroot = \"m.spc\"\nbench-dir = \"../b\"\n",
        "'bench-dir' must be a plain workspace-relative directory, got '../b'",
    );
    manifest_err(
        "bin collision",
        "bin = \"app\"\nroot = \"m.spc\"\n[bin.app]\nroot = \"x.spc\"\n",
        "[bin.app] collides with the manifest's primary 'bin'",
    );
    manifest_err(
        "bin without root",
        "bin = \"app\"\nroot = \"m.spc\"\n[bin.tool]\nroot = \"\"\n",
        "[bin.tool] needs a 'root'",
    );
    manifest_err(
        "lib without name",
        "[lib]\nroot = \"l.spc\"\n",
        "[lib] needs a 'name' when the manifest declares no 'bin'",
    );
    manifest_err(
        "undefined default profile",
        "bin = \"a\"\nroot = \"m.spc\"\ndefault-profile = \"nope\"\n",
        "default-profile 'nope' is not defined",
    );
    manifest_err("missing bin", "root = \"m.spc\"\n", "missing required key 'bin' (or a [lib] section)");
    manifest_err("missing root", "bin = \"a\"\n", "missing required key 'root'");
    manifest_err(
        "unknown bin key",
        "bin = \"app\"\nroot = \"m.spc\"\n[bin.t]\nroot = \"x.spc\"\nfoo = 1\n",
        "unknown [bin.t] key 'foo'",
    );
    manifest_err("unknown lib key", "[lib]\nname = \"l\"\nroot = \"x.spc\"\nfoo = 1\n", "unknown [lib] key 'foo'");
    manifest_err(
        "unknown command key",
        "bin = \"a\"\nroot = \"m.spc\"\n[command.x]\nfoo = 1\n",
        "unknown command key 'foo'",
    );
    manifest_err(
        "unknown library type",
        "[lib]\nname = \"l\"\nroot = \"x.spc\"\ntype = [\"dyn\"]\n",
        "unknown library type 'dyn' (static | shared)",
    );
    manifest_err("unknown section", "bin = \"a\"\nroot = \"m.spc\"\n[foo]\nx = 1\n", "unknown section 'foo'");
    manifest_err("unknown key", "bin = \"a\"\nroot = \"m.spc\"\nvendor-dir = \"v\"\n", "unknown key 'vendor-dir'");
}
