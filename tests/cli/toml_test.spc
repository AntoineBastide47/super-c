// build.toml parser tests: value kinds, sections, arrays/inline tables, and error rejection.
import build_system::toml as toml;
import build_system::manifest as manifest;
import utils::errors as diag;

fn parse_ok(src: str) Vector<toml::TomlItem> {
    let mut errs = diag::Errors::new();
    let items = toml::parse_into(src, &mut errs);
    assert(!items.is_none());
    return items.unwrap();
}

const fn find(items: &Vector<toml::TomlItem>, sec: str, key: str) i64 {
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
        "[profile.release]\nldflags = [\n    \"-L/opt\",\n    \"-lz\",\n]\nstrip = true\n[command.test]\nenv = { SUPERC = \"./super-c\", CC = \"cc\" }\nrun = [\"a\", \"b\"]\n",
    );
    let c = find(&items, "profile.release", "ldflags");
    assert(c >= 0);
    assert(items.at(c as usize).val.kind == toml::TV_ARR);
    assert_eq(items.at(c as usize).val.arr.len(), 2 as usize);
    assert(items.at(c as usize).val.arr.at(1).as_str() == "-lz");
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
    toml_err("missing '='", "bin \"app\"\n", "expected '=' after key");
    toml_err("missing key", "= 1\n", "expected key");
    toml_err("missing inline key", "a = { = 1 }\n", "expected key in inline table");
    toml_err("missing value", "a = \n", "expected value");
    toml_err("inline integer", "a = { b = 1 }\n", "inline tables may only contain string values");
    toml_err("open section", "[abc\n", "malformed section header");
    toml_err("trailing token", "a = 1 b\n", "unexpected trailing characters");
    toml_err("bad escape", "a = \"\\q\"\n", "unknown escape in string");
    toml_err("open string", "a = \"abc\n", "unterminated string");
    toml_err("integer overflow", "jobs = 99999999999999999999\n", "integer out of range");
    toml_err("integer above i64", "jobs = 9223372036854775808\n", "integer out of range");
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
    manifest_err(
        "jobs above u32",
        "bin = \"a\"\nroot = \"m.spc\"\njobs = 4294967296\n",
        "'jobs' expects a non-negative integer",
    );
    manifest_err("bin string", "bin = 5\nroot = \"m.spc\"\n", "'bin' expects a string");
    manifest_err(
        "ldflags array",
        "bin = \"a\"\nroot = \"m.spc\"\nldflags = \"x\"\n",
        "'ldflags' expects an array of strings",
    );
    // The C compile's keys are gone with it.
    manifest_err("cflags", "bin = \"a\"\nroot = \"m.spc\"\ncflags = [\"-O2\"]\n", "unknown key 'cflags'");
    manifest_err(
        "profile cflags",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\ncflags = [\"-O2\"]\n",
        "unknown profile key 'cflags'",
    );
    manifest_err(
        "strip bool",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\nstrip = 1\n",
        "'strip' expects true or false",
    );
    manifest_err(
        "opt-level",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\nopt-level = 4\n",
        "'opt-level' expects 0, 1, 2, 3, \"s\" or \"z\"",
    );
    manifest_err(
        "overflow-checks bool",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\noverflow-checks = 1\n",
        "'overflow-checks' expects true or false",
    );
    manifest_err(
        "link-args array",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\nlink-args = \"-S\"\n",
        "'link-args' expects an array of strings",
    );
    manifest_err(
        "debug bool",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\ndebug = 1\n",
        "'debug' expects true or false",
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
    // Every subcommand main dispatches is reserved, including `vendor` and `bindgen`.
    manifest_err(
        "vendor is built in",
        "bin = \"a\"\nroot = \"m.spc\"\n[command.vendor]\nrun = [\"x\"]\n",
        "'vendor' is a built-in subcommand and cannot be overridden; pick another command name",
    );
    manifest_err(
        "bindgen is built in",
        "bin = \"a\"\nroot = \"m.spc\"\n[command.bindgen]\nrun = [\"x\"]\n",
        "'bindgen' is a built-in subcommand and cannot be overridden; pick another command name",
    );
    manifest_err("unknown key", "bin = \"a\"\nroot = \"m.spc\"\nvendor-dir = \"v\"\n", "unknown key 'vendor-dir'");
}

// `debug` puts debug information in the objects: the built-in `debug` and `bench` profiles have it, and a
// section naming a built-in overrides only the keys it sets.
@test
fn manifest_profile_debug_info() {
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.release]\ndebug = true\n[profile.plain]\nopt-level = 1\n",
        "",
        false,
    );
    assert_eq(errs.errors.len(), 0);
    let mm = m.unwrap();
    let rel = mm.profiles.at(mm.profile_index("release") as usize);
    assert(rel.debug && rel.strip && rel.opt == 3, "release keeps its level and strip");
    assert(!mm.profiles.at(mm.profile_index("plain") as usize).debug, "a new profile has none");
    assert(mm.profiles.at(mm.profile_index("debug") as usize).debug, "debug");
    assert(mm.profiles.at(mm.profile_index("bench") as usize).debug, "bench");
    assert(!mm.profiles.at(mm.profile_index("test") as usize).debug, "test");
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
    assert(rel.strip, "the rest of release stays");
    assert_eq(mm.profiles.at(mm.profile_index("small") as usize).opt, manifest::OPT_Z);
    assert_eq(mm.profiles.at(mm.profile_index("two") as usize).opt, 2);
    assert_eq(mm.profiles.at(mm.profile_index("debug") as usize).opt, 0);
}

// Signed overflow traps at opt-level 0 and 1 and wraps at 2 and above; `overflow-checks` overrides the
// level, and a built-in profile keeps its behavior when a section changes another key.
@test
fn manifest_profile_overflow_checks() {
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.release]\noverflow-checks = true\n[profile.fast]\nopt-level = \"s\"\n[profile.plain]\nstrip = true\n[profile.debug]\nstrip = true\n[profile.lax]\nopt-level = 0\noverflow-checks = false\n",
        "",
        false,
    );
    assert_eq(errs.errors.len(), 0);
    let mm = m.unwrap();
    let wraps: [str; 3] = ["fast", "bench", "lax"];
    for name in wraps {
        assert(mm.profiles.at(mm.profile_index(name) as usize).arith_wraps(), name);
    }
    let checks: [str; 4] = ["release", "plain", "debug", "test"];
    for name in checks {
        assert(!mm.profiles.at(mm.profile_index(name) as usize).arith_wraps(), name);
    }
}

// The code-generation flags: each level's defaults (`cg_effective`), a profile's keys and the command
// line's `-f` and `-fno-` flags over them, the last one winning, and `-O` over every profile's level.
@test
fn code_generation_flags_follow_the_level_then_the_profile_then_the_command_line() {
    let fp = manifest::CG_OMIT_FRAME_POINTER;
    let inl = manifest::CG_INLINE;
    let fun = manifest::CG_INLINE_FUNCTIONS;
    let unr = manifest::CG_UNROLL;
    let vers = manifest::CG_UNSWITCH | manifest::CG_VERSION_LOOPS;
    let vec = manifest::CG_VECTORIZE;
    let sa = manifest::CG_STRICT_ALIASING;
    assert_eq(manifest::cg_effective(0, 0, 0), 0u64);
    assert_eq(manifest::cg_effective(1, 0, 0), fp | inl);
    assert_eq(manifest::cg_effective(2, 0, 0), fp | inl | fun | unr | vec | sa);
    assert_eq(manifest::cg_effective(3, 0, 0), fp | inl | fun | unr | vers | vec | sa);
    assert_eq(manifest::cg_effective(manifest::OPT_S, 0, 0), fp | inl | fun | vec | sa);
    assert_eq(manifest::cg_effective(manifest::OPT_Z, 0, 0), fp | inl | sa);
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.release]\nomit-frame-pointer = false\nunroll-loops = false\n[profile.small]\nopt-level = \"s\"\nunroll-loops = true\n",
        "",
        false,
    );
    assert_eq(errs.errors.len(), 0);
    let mut mm = m.unwrap();
    let rel = mm.profiles.at(mm.profile_index("release") as usize);
    assert_eq(manifest::cg_effective(rel.opt, rel.cg_on, rel.cg_off), inl | fun | vers | vec | sa);
    let sm = mm.profiles.at(mm.profile_index("small") as usize);
    assert_eq(manifest::cg_effective(sm.opt, sm.cg_on, sm.cg_off), fp | inl | fun | unr | vec | sa);
    let mut on: u64 = 0;
    let mut off: u64 = 0;
    assert(manifest::cg_flag("-fomit-frame-pointer", &mut on, &mut off), "-f");
    assert(manifest::cg_flag("-fno-inline", &mut on, &mut off), "-fno-");
    assert(manifest::cg_flag("-fno-omit-frame-pointer", &mut on, &mut off), "the last wins");
    assert(!manifest::cg_flag("-fno-such-flag", &mut on, &mut off), "an unknown flag");
    assert(!manifest::cg_flag("-O2", &mut on, &mut off), "a level is no flag");
    assert_eq(on, 0u64);
    assert_eq(off, fp | inl);
    // A flag whose bit is its `no` form: `-fno-plt` sets it, `-fplt` clears it.
    let mut pon: u64 = 0;
    let mut poff: u64 = 0;
    assert(manifest::cg_flag("-fno-plt", &mut pon, &mut poff), "-fno-plt");
    assert_eq(pon, manifest::CG_NO_PLT);
    let mut pspelled = String::new();
    manifest::cg_spell(manifest::OPT_NONE, pon, poff, &mut pspelled);
    assert(pspelled.as_str() == " -fno-plt", pspelled.as_str());
    assert(manifest::cg_flag("-fplt", &mut pon, &mut poff), "-fplt");
    assert_eq(pon, 0u64);
    assert_eq(manifest::opt_flag("-O3"), 3);
    assert_eq(manifest::opt_flag("-Oz"), manifest::OPT_Z);
    assert_eq(manifest::opt_flag("-O4"), manifest::OPT_NONE);
    mm.override_profiles(1, manifest::CG_UNROLL, manifest::CG_INLINE);
    let rel2 = mm.profiles.at(mm.profile_index("release") as usize);
    assert_eq(manifest::cg_effective(rel2.opt, rel2.cg_on, rel2.cg_off), unr);
    let mut spelled = String::new();
    manifest::cg_spell(rel2.opt, rel2.cg_on, rel2.cg_off, &mut spelled);
    assert(spelled.as_str() == " -O1 -fno-omit-frame-pointer -fno-inline -funroll-loops", spelled.as_str());
    manifest_err(
        "codegen flag bool",
        "bin = \"a\"\nroot = \"m.spc\"\n[profile.debug]\ninline = 1\n",
        "'inline' expects true or false",
    );
}

// A --bootstrap-tags build reads a manifest written for a newer compiler: sections and keys outside
// the schema are skipped, everything else is still validated.
@test
fn manifest_bootstrap_skips_unknown() {
    let (m, errs) = manifest::parse_check(
        "bin = \"a\"\nroot = \"m.spc\"\nvendor-dir = \"v\"\n[foo]\nx = 1\n[profile.debug]\nnew-key = 1\n",
        "",
        true,
    );
    assert(!m.is_none());
    assert_eq(errs.errors.len(), 0);
    let (m2, errs2) = manifest::parse_check("bin = 1\nroot = \"m.spc\"\n", "", true);
    assert(m2.is_none());
    assert_eq(errs2.errors.at(0).msg.as_str(), "'bin' expects a string");
}
