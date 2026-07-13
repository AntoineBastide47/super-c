// build.toml parser tests: value kinds, sections, arrays/inline tables, and error rejection.
import build_system::toml as toml;

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
    let mut items = parse_ok("bin = \"app\" # comment\njobs = 8\nneg = -3\nflag = true\noff = false\n");
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
    let mut items = parse_ok(
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
    let mut items = parse_ok("s = \"a\\n\\t\\\"b\\\\\"\n");
    let s = find(&items, "", "s");
    assert(items.at(s as usize).val.s.as_str() == "a\n\t\"b\\");
}

@test
fn toml_rejects_malformed() {
    assert(toml::parse("bin \"app\"\n", "t").is_none()); // missing '='
    assert(toml::parse("bin = \"app\n", "t").is_none()); // unterminated string
    assert(toml::parse("[oops\nbin = \"a\"\n", "t").is_none()); // malformed section
    assert(toml::parse("a = [1, 2]\n", "t").is_none()); // non-string array
    assert(toml::parse("a = \"x\" b = \"y\"\n", "t").is_none()); // trailing junk
}
