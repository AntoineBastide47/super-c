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
    let (m, errs) = manifest::parse_check(src, "", false);
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
        "opt-level",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.dev]\nopt-level = 4\n",
        "'opt-level' expects 0, 1, 2, 3, \"s\" or \"z\"",
    );
    manifest_err(
        "link-args array",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.dev]\nlink-args = \"-S\"\n",
        "'link-args' expects an array of strings",
    );
    manifest_err(
        "lto mode",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.dev]\nlto = \"fat\"\n",
        "'lto' expects \"none\", \"full\", \"auto\" or \"thin\"",
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

// `lto` names the link-time optimization mode of a profile; a built-in profile keeps its own default
// (automatic LTO for `release`), and a profile without the key leaves the flag arrays in charge.
@test
fn manifest_profile_lto_mode() {
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.fast]\ncflags = [\"-O2\"]\nlto = \"full\"\n[profile.plain]\ncflags = [\"-O1\"]\n",
        "",
        false,
    );
    assert_eq(errs.errors.len(), 0);
    let mm = m.unwrap();
    assert_eq(mm.profiles.at(mm.profile_index("fast") as usize).lto, manifest::LTO_FULL);
    assert_eq(mm.profiles.at(mm.profile_index("plain") as usize).lto, manifest::LTO_FLAGS);
    assert_eq(mm.profiles.at(mm.profile_index("release") as usize).lto, manifest::LTO_AUTO);
    assert_eq(mm.profiles.at(mm.profile_index("dev") as usize).lto, manifest::LTO_FLAGS);
    assert_eq(manifest::lto_parse("thin"), manifest::LTO_THIN);
    // A section naming a built-in overrides only the keys it sets: `release` keeps its flags and strip.
    let (m2, errs2) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.release]\nlto = \"thin\"\n[profile.dev]\ncflags = [\"-O1\"]\n",
        "",
        false,
    );
    assert_eq(errs2.errors.len(), 0);
    let mm2 = m2.unwrap();
    let rel = mm2.profiles.at(mm2.profile_index("release") as usize);
    assert_eq(rel.lto, manifest::LTO_THIN);
    assert(rel.strip && rel.cflags.len() > 1 && rel.link_args.len() == 1, "release keeps its built-in flags and strip");
    let dev = mm2.profiles.at(mm2.profile_index("dev") as usize);
    assert(dev.cflags.len() == 1 && dev.ldflags.len() == 2, "dev's cflags are replaced, its ldflags kept");
    assert_eq(manifest::lto_parse("x"), -1);
    assert_eq(manifest::lto_flag(manifest::LTO_AUTO), "-flto=auto");
    assert_eq(manifest::lto_flag(manifest::LTO_NONE), "");
}

// `opt-level` takes Cargo's values and `link-args` the linker's own arguments; the built-in profiles
// carry their levels in the key, so a section can change just the level.
@test
fn manifest_profile_opt_level_and_link_args() {
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.release]\nopt-level = 2\nlink-args = [\"-dead_strip\", \"-S\"]\n[profile.small]\nopt-level = \"z\"\n[profile.two]\nopt-level = \"2\"\n",
        "",
        false,
    );
    assert_eq(errs.errors.len(), 0);
    let mm = m.unwrap();
    let rel = mm.profiles.at(mm.profile_index("release") as usize);
    assert_eq(rel.opt, 2);
    assert(
        rel.link_args.len() == 2 && rel.link_args.at(0).as_str() == "-dead_strip",
        "link-args replace the built-in list",
    );
    assert(rel.strip && rel.cflags.len() > 1, "the rest of release stays");
    assert_eq(mm.profiles.at(mm.profile_index("small") as usize).opt, manifest::OPT_Z);
    assert_eq(mm.profiles.at(mm.profile_index("two") as usize).opt, 2);
    assert_eq(mm.profiles.at(mm.profile_index("dev") as usize).opt, 1);
    assert_eq(mm.profiles.at(mm.profile_index("debug") as usize).opt, 0);
    assert_eq(manifest::opt_flag(manifest::OPT_S), "-Os");
    assert_eq(manifest::opt_flag(manifest::OPT_FLAGS), "");
}

// A --bootstrap-tags build reads a manifest written for a newer compiler: sections and keys outside
// the schema are skipped, everything else is still validated.
@test
fn manifest_bootstrap_skips_unknown() {
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\nvendor-dir = \"v\"\n[foo]\nx = 1\n[profile.dev]\nnew-key = 1\n",
        "",
        true,
    );
    assert(!m.is_none());
    assert_eq(errs.errors.len(), 0);
    let (m2, errs2) = manifest::parse_check("bin = 1\nroot = \"m.spc\"\n", "", true);
    assert(m2.is_none());
    assert_eq(errs2.errors.at(0).msg.as_str(), "'bin' expects a string");
}
