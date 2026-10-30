// Tests of the C preprocessor `bindgen::cpp`: the C11 6.10.3.5 examples, each directive and operator, error
// paths, and an oracle run against the host's clang (`host_clang`) on synthetic and system headers.
import bindgen::cpp as *;
import tests::cli_harness as cli;
import unistd;

fn memory_file(path: str, text: str) VFile {
    return VFile { path: String::from_str(path), text: String::from_str(text) };
}

fn make_config(files: Vector<VFile>, predefs: str) PpConfig {
    return PpConfig {
        quote_dirs: Vector::<String>::new(),
        dirs: Vector::<String>::new(),
        sys_dirs: Vector::<String>::new(),
        frameworks: Vector::<String>::new(),
        files: files,
        predefs: String::from_str(predefs),
        cmdline: String::new(),
        has: Vector::<String>::new(),
    };
}

fn one(text: str, predefs: str) Pp {
    let mut files = Vector::<VFile>::new();
    files.push(memory_file("main.c", text));
    return Pp::new(make_config(files, predefs));
}

const fn tok_class(c: u8) u32 {
    if c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' || c == b'$' || c >= 0x80 {
        return 1;
    }
    if c >= b'0' && c <= b'9' {
        return 2;
    }
    return 0;
}

// The tokens of preprocessed text: line markers dropped, whitespace ignored. Written apart from the module
// under test so that a shared fault cannot hide.
fn tokens_of(text: str) Vector<String> {
    return tokens_with(text, false);
}

// `tokens_of`, optionally without the `#pragma` lines.
fn tokens_with(text: str, drop_pragmas: bool) Vector<String> {
    let mut scan = scan_with(text, drop_pragmas);
    return replace(&mut scan.tokens, Vector::<String>::new());
}

// The tokens of preprocessed text and, for each, the file of the last line marker before it. The markers of
// `<built-in>` and `<command line>` name no source file and do not count.
struct Scan {
    pub tokens: Vector<String>,
    pub origins: Vector<String>,
    pub lines: Vector<u32>, // the line each token is printed on, counted from the last marker
}

fn scan_with(text: str, drop_pragmas: bool) Scan {
    let mut out = Vector::<String>::new();
    let mut origins = Vector::<String>::new();
    let mut origin = String::new();
    let mut lines = Vector::<u32>::new();
    let mut line: u32 = 1;
    let n = text.len();
    let mut i: usize = 0;
    let mut bol = true;
    while i < n {
        let c = text.byte_at(i);
        if c == b'\n' {
            line += 1;
            bol = true;
            i += 1;
            continue;
        }
        if c == b' ' || c == b'\t' || c == b'\r' {
            i += 1;
            continue;
        }
        if bol && c == b'#' && i + 1 < n && (text.byte_at(i + 1) == b' ' || text.byte_at(i + 1) == b'\t') {
            let mut j = i + 1;
            while j < n && text.byte_at(j) == b' ' {
                j += 1;
            }
            if j < n && text.byte_at(j) >= b'0' && text.byte_at(j) <= b'9' {
                let mut number: u32 = 0;
                while text.byte_at(j) >= b'0' && text.byte_at(j) <= b'9' {
                    number = number * 10 + (text.byte_at(j) - b'0') as u32;
                    j += 1;
                }
                line = number; // the line after the marker's (gcc's first marker is `# 0`)
                let mut q = j;
                while q < n && text.byte_at(q) != b'"' && text.byte_at(q) != b'\n' {
                    q += 1;
                }
                let mut e = q + 1;
                while e < n && text.byte_at(e) != b'"' && text.byte_at(e) != b'\n' {
                    e += 1;
                }
                if q < n && text.byte_at(q) == b'"' && text.byte_at(q + 1) != b'<' {
                    origin = String::from_str(text.slice(q + 1, e));
                }
                while i < n && text.byte_at(i) != b'\n' {
                    i += 1;
                }
                i += 1; // the marker's newline: `line` already numbers the next line
                continue;
            }
        }
        if drop_pragmas && bol && c == b'#' && text.slice(i + 1, n).trim_start().starts_with("pragma") {
            while i < n && text.byte_at(i) != b'\n' {
                i += 1;
            }
            continue;
        }
        bol = false;
        let start = i;
        let cls = tok_class(c);
        if cls == 1 {
            while i < n && tok_class(text.byte_at(i)) != 0 {
                i += 1;
            }
            if i < n && (text.byte_at(i) == b'"' || text.byte_at(i) == b'\'') && i - start <= 2 {
                let d = text.byte_at(start);
                if d == b'L' || d == b'u' || d == b'U' {
                    i = skip_quoted(text, i);
                }
            }
        } else if cls == 2 || c == b'.' && i + 1 < n && tok_class(text.byte_at(i + 1)) == 2 {
            i += 1;
            while i < n {
                let d = text.byte_at(i);
                let e = text.byte_at(i - 1);
                if tok_class(d) != 0 || d == b'.' {
                    i += 1;
                } else if (d == b'+' || d == b'-') && (e == b'e' || e == b'E' || e == b'p' || e == b'P') {
                    i += 1;
                } else {
                    break;
                }
            }
        } else if c == b'"' || c == b'\'' {
            i = skip_quoted(text, i);
        } else {
            let three = text.slice(
                i,
                if i + 3 <= n {
                    i + 3
                } else {
                    n
                },
            );
            if three == "..." || three == "<<=" || three == ">>=" {
                i += 3;
            } else {
                let two = text.slice(
                    i,
                    if i + 2 <= n {
                        i + 2
                    } else {
                        n
                    },
                );
                let pairs: []str = [
                    "->",
                    "++",
                    "--",
                    "<<",
                    ">>",
                    "<=",
                    ">=",
                    "==",
                    "!=",
                    "&&",
                    "||",
                    "*=",
                    "/=",
                    "%=",
                    "+=",
                    "-=",
                    "&=",
                    "^=",
                    "|=",
                    "##",
                ];
                let mut hit = false;
                for k in 0..pairs.len() {
                    if two == pairs[k] {
                        hit = true;
                    }
                }
                i += if hit {
                    2
                } else {
                    1
                };
            }
        }
        out.push(String::from_str(text.slice(start, i)));
        origins.push(origin.clone());
        lines.push(line);
    }
    return Scan { tokens: out, origins: origins, lines: lines };
}

const fn skip_quoted(text: str, at: usize) usize {
    let q = text.byte_at(at);
    let mut i = at + 1;
    while i < text.len() && text.byte_at(i) != q {
        if text.byte_at(i) == b'\\' {
            i += 1;
        }
        i += 1;
    }
    return i + 1;
}

fn joined(v: &Vector<String>) String {
    let mut s = String::new();
    for i in 0..v.len() {
        if i > 0 {
            s.push_byte(b' ');
        }
        s.push_string(&v[i]);
    }
    return s;
}

fn norm(text: str) String {
    let t = tokens_of(text);
    return joined(&t);
}

// Preprocess `text` as main.c and return the output tokens joined by single spaces; panics on failure.
fn run(text: str, predefs: str) String {
    let mut pp = one(text, predefs);
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the text preprocesses");
    let toks = tokens_of(&out);
    return joined(&toks);
}

fn expect(text: str, want: str) {
    let got = run(text, "");
    assert_eq(got.as_str(), want);
}

// ---- Host compiler oracle ----------------------------------------------------------------------------------

const HAS_NAMES: []str = [
    "__has_feature",
    "__has_extension",
    "__has_attribute",
    "__has_c_attribute",
    "__has_builtin",
    "__has_declspec_attribute",
    "__has_include",
    "__has_include_next",
    "__has_warning",
    "__is_identifier",
    "__building_module",
    "__FILE_NAME__",
    "__is_target_arch",
    "__is_target_vendor",
    "__is_target_os",
    "__is_target_environment",
    "__is_target_variant_os",
    "__is_target_variant_environment",
];

struct Host {
    pub cc: String, // the oracle compiler, empty when the host has no clang
    pub dirs: Vector<String>,
    pub frameworks: Vector<String>,
    pub predefs: String,
}

extend Host {
    // The host compiler's system search list as flags, for a run with `-nostdinc`.
    fn search_flags(self: &Self, out: &mut String) {
        for i in 0..self.dirs.len() {
            out.format_into(" -isystem {}", self.dirs[i].as_str());
        }
        for i in 0..self.frameworks.len() {
            out.format_into(" -iframework {}", self.frameworks[i].as_str());
        }
    }
}

fn cc_command(cc: str, tail: str) String {
    return format("{} {}", cc, tail);
}

// Run the host C compiler with `tail`; stdout goes to `out`, stderr to `err`. The exit code.
fn cc_run(cc: str, tail: str, out: str, err: str) i32 {
    let mut cmd = cc_command(cc, tail);
    let mut o = String::from_str(out);
    let mut e = String::from_str(err);
    return cli::run_with(cmd.cstr(), null, o.cstr(), e.cstr(), "");
}

// The oracle, in the comparison job only (`cli::has_cc`): a clang for the build's C environment (mingw on
// Windows), its C compiler when it is one, else `clang`, whose preprocessor bindgen's follows. gcc spells
// some output differently (`x ##y` and `#x` in a macro dump, a UCN for an extended character, `__LINE__`
// in a call over several lines). Empty when there is none.
fn host_clang(p: &cli::Proj) String {
    if !cli::has_cc() {
        return String::new();
    }
    p.mkfile("which.c", "#if defined(__clang__) && (!defined(_WIN32) || defined(__MINGW32__))\n1\n#endif\n");
    let cands = [unsafe str::from_cstr(cli::cc_name()), "clang"];
    for c in cands {
        let out = format("{}/which.out", p.dir());
        let rc = cc_run(
            c,
            format("-E -P -x c {}/which.c", p.dir()).as_str(),
            &out,
            format("{}/which.err", p.dir()).as_str(),
        );
        if rc == 0 && cli::read_text(&out).as_str().trim() == "1" {
            return String::from_str(c);
        }
    }
    return String::new();
}

// The host compiler's include search list and predefined macros; `cc` empty (and nothing else read) when
// the host has no clang.
fn host_info(p: &cli::Proj) Host {
    let cc = host_clang(p);
    if cc.len() == 0 {
        println("skipped: no clang to compare with");
        return Host {
            cc: cc,
            dirs: Vector::<String>::new(),
            frameworks: Vector::<String>::new(),
            predefs: String::new(),
        };
    }
    p.mkfile("empty.c", "");
    let dir = p.dir();
    let rc = cc_run(
        &cc,
        format("-E -v -x c {}/empty.c", dir).as_str(),
        format("{}/v.out", dir).as_str(),
        format("{}/v.err", dir).as_str(),
    );
    assert_eq(rc, 0);
    let v = cli::read_text(format("{}/v.err", dir).as_str());
    let mut dirs = Vector::<String>::new();
    let mut frameworks = Vector::<String>::new();
    let mut inside = false;
    for line in v.as_str().lines() {
        if line.starts_with("#include <...>") {
            inside = true;
        } else if line.starts_with("End of search list") {
            inside = false;
        } else if inside && line.ends_with(" (framework directory)") {
            let d = line.trim();
            frameworks.push(String::from_str(d.slice(0, d.len() - 22)));
        } else if inside {
            dirs.push(String::from_str(line.trim()));
        }
    }
    let rc2 = cc_run(
        &cc,
        format("-E -dM -x c {}/empty.c", dir).as_str(),
        format("{}/d.out", dir).as_str(),
        format("{}/d.err", dir).as_str(),
    );
    assert_eq(rc2, 0);
    return Host {
        cc: cc,
        dirs: dirs,
        frameworks: frameworks,
        predefs: cli::read_text(format("{}/d.out", dir).as_str()),
    };
}

struct Run {
    pub ok: bool,
    pub tokens: Vector<String>,
    pub origins: Vector<String>,
    pub lines: Vector<u32>,
    pub queried: Vector<String>,
    pub dump: String,
    pub err: String,
}

// Our preprocessor over `src` (a file `main.c`) with the host's search list and predefined macros. `extra`
// is more predefs text; `has` the true answers of the `__has_` operators.
// `name` under `dir`; just `name` when `dir` is empty, a path relative to the working directory.
fn under(dir: str, name: str) String {
    if dir.len() == 0 {
        return String::from_str(name);
    }
    return format("{}/{}", dir, name);
}

fn run_host(host: &Host, dir: str, extra: str, has: &Vector<String>) Run {
    let mut config = make_config(Vector::<VFile>::new(), "");
    config.dirs.push(under(dir, "inc"));
    config.dirs.push(under(dir, "inc2"));
    for i in 0..host.dirs.len() {
        config.sys_dirs.push(host.dirs[i].clone());
    }
    for i in 0..host.frameworks.len() {
        config.frameworks.push(host.frameworks[i].clone());
    }
    config.predefs.push_str(&host.predefs);
    config.predefs.push_str(extra);
    for i in 0..has.len() {
        config.has.push(has[i].clone());
    }
    let mut pp = Pp::new(config);
    let mut out = String::new();
    let ok = pp.preprocess(under(dir, "main.c").as_str(), &mut out);
    let mut scan = scan_with(&out, true);
    return Run {
        ok: ok,
        tokens: replace(&mut scan.tokens, Vector::<String>::new()),
        origins: replace(&mut scan.origins, Vector::<String>::new()),
        lines: replace(&mut scan.lines, Vector::<u32>::new()),
        queried: pp.queried.clone(),
        dump: dump_of(&pp),
        err: pp.err.clone(),
    };
}

fn dump_of(pp: &Pp) String {
    let mut d = String::new();
    pp.dump_macros(&mut d);
    return d;
}

// The `#define` lines of a macro dump, sorted.
fn sorted_lines(text: str) Vector<String> {
    let mut v = Vector::<String>::new();
    for line in text.lines() {
        v.push(String::from_str(line.trim_end()));
    }
    v.sort();
    return v;
}

fn key_macro(key: str) String {
    let colon = key.find_byte(b':') as usize;
    let kind = key.slice(0, colon);
    let arg = key.slice(colon + 1, key.len());
    if kind.starts_with("target_") {
        return format("__is_{}({})", kind, arg);
    }
    return format("__has_{}({})", kind, arg);
}

// Ask the host which of `keys` hold; the true ones join `has`.
fn probe_keys(p: &cli::Proj, host: &Host, keys: &Vector<String>, has: &mut Vector<String>) {
    let mut src = String::new();
    for i in 0..keys.len() {
        let m = key_macro(&keys[i]);
        src.format_into("#if {}\nK{} 1\n#else\nK{} 0\n#endif\n", m.as_str(), i, i);
    }
    p.mkfile("probe.c", &src);
    let dir = p.dir();
    let rc = cc_run(
        &host.cc,
        format("-E -w -x c {}/probe.c", dir).as_str(),
        format("{}/probe.out", dir).as_str(),
        format("{}/probe.err", dir).as_str(),
    );
    assert_eq(rc, 0);
    let out = cli::read_text(format("{}/probe.out", dir).as_str());
    let toks = tokens_of(&out);
    let mut i: usize = 0;
    while i + 1 < toks.len() {
        if toks[i].as_str().starts_with("K") && toks[i + 1].as_str() == "1" {
            let k = toks[i].as_str().slice(1, toks[i].len()).parse_usize().unwrap();
            has.push(keys[k].clone());
        }
        i += 2;
    }
}

// Predefs that remove the `__has_` operators the host compiler lacks.
fn undef_missing(p: &cli::Proj, host: &Host) String {
    let mut src = String::new();
    for i in 0..HAS_NAMES.len() {
        src.format_into("#ifdef {}\nD{} 1\n#else\nD{} 0\n#endif\n", HAS_NAMES[i], i, i);
    }
    p.mkfile("defd.c", &src);
    let dir = p.dir();
    let rc = cc_run(
        &host.cc,
        format("-E -w -x c {}/defd.c", dir).as_str(),
        format("{}/defd.out", dir).as_str(),
        format("{}/defd.err", dir).as_str(),
    );
    assert_eq(rc, 0);
    let toks = tokens_of(cli::read_text(format("{}/defd.out", dir).as_str()).as_str());
    let mut undefs = String::new();
    let mut i: usize = 0;
    while i + 1 < toks.len() {
        if toks[i + 1].as_str() == "0" {
            let k = toks[i].as_str().slice(1, toks[i].len()).parse_usize().unwrap();
            undefs.format_into("#undef {}\n", HAS_NAMES[k]);
        }
        i += 2;
    }
    return undefs;
}

// Run both preprocessors on the file `main.c` holding `src`, and require equal token streams. `#pragma`
// lines are left out on both sides: gcc and clang each consume a different set of them, and bindgen skips
// them; the pragma output has its own tests.
fn expect_host_equal(p: &cli::Proj, host: &Host, undefs: &String, label: str, src: str) {
    expect_host_equal_at(p, host, undefs, label, src, false);
}

// `relative`: work from the scratch directory with a main file named `main.c`, as `cc main.c` is run.
fn expect_host_equal_at(p: &cli::Proj, host: &Host, undefs: &String, label: str, src: str, relative: bool) {
    p.mkfile("main.c", src);
    let root = p.dir();
    let dir = if relative {
        ""
    } else {
        root
    };
    if relative {
        assert_eq(unsafe unistd::chdir(p.rootp()), 0);
    }
    let mut has = Vector::<String>::new();
    let mut known = Set::<String>::new();
    let mut r = run_host(host, dir, undefs.as_str(), &has);
    let mut settled = false;
    for _ in 0..32 {
        let mut fresh = Vector::<String>::new();
        for i in 0..r.queried.len() {
            if !known.contains(&r.queried[i]) {
                known.insert(r.queried[i].clone());
                fresh.push(r.queried[i].clone());
            }
        }
        if fresh.len() == 0 {
            settled = true;
            break;
        }
        probe_keys(p, host, &fresh, &mut has);
        r = run_host(host, dir, undefs.as_str(), &has);
    }
    assert(settled, "every key the run asks for has an answer");
    if !r.ok {
        eprintln("{}: {}", label, r.err.as_str());
    }
    assert(r.ok, "our preprocessor accepts the text");
    let mut args = format(
        "-E -w -nostdinc -I {} -I {} -x c {}",
        under(dir, "inc").as_str(),
        under(dir, "inc2").as_str(),
        under(dir, "main.c").as_str(),
    );
    host.search_flags(&mut args);
    let rc = cc_run(&host.cc, &args, format("{}/cc.out", root).as_str(), format("{}/cc.err", root).as_str());
    assert_eq(rc, 0);
    let cc_out = cli::read_text(format("{}/cc.out", root).as_str());
    let mut scan = scan_with(&cc_out, true);
    let want = replace(&mut scan.tokens, Vector::<String>::new());
    let n = if r.tokens.len() < want.len() {
        r.tokens.len()
    } else {
        want.len()
    };
    let mut at = n;
    for i in 0..n {
        if r.tokens[i] != want[i] {
            at = i;
            break;
        }
    }
    if at != n || r.tokens.len() != want.len() {
        let lo = if at > 12 {
            at - 12
        } else {
            0
        };
        let mut a = String::new();
        let mut b = String::new();
        let hi_a = if at + 12 < r.tokens.len() {
            at + 12
        } else {
            r.tokens.len()
        };
        let hi_b = if at + 12 < want.len() {
            at + 12
        } else {
            want.len()
        };
        for i in lo..hi_a {
            a.format_into("{} ", r.tokens[i].as_str());
        }
        for i in lo..hi_b {
            b.format_into("{} ", want[i].as_str());
        }
        eprintln(
            "{}: token {} of {} (cc has {})\n  ours: {}\n  cc:   {}",
            label,
            at,
            r.tokens.len(),
            want.len(),
            a.as_str(),
            b.as_str(),
        );
    }
    assert_eq(r.tokens.len(), want.len());
    assert_eq(at, n);
    let mut dm_args = format(
        "-E -dM -w -nostdinc -I {} -I {} -x c {}",
        under(dir, "inc").as_str(),
        under(dir, "inc2").as_str(),
        under(dir, "main.c").as_str(),
    );
    host.search_flags(&mut dm_args);
    assert_eq(cc_run(&host.cc, &dm_args, format("{}/cc.dm", root).as_str(), format("{}/cc.dmerr", root).as_str()), 0);
    let want_macros = sorted_lines(cli::read_text(format("{}/cc.dm", root).as_str()).as_str());
    let our_macros = sorted_lines(&r.dump);
    let mut m: usize = 0;
    while m < our_macros.len() && m < want_macros.len() && our_macros[m] == want_macros[m] {
        m += 1;
    }
    if m < our_macros.len() || m < want_macros.len() {
        let mut only_ours = String::new();
        let mut only_cc = String::new();
        for k in 0..our_macros.len() {
            if !want_macros.contains(&our_macros[k]) {
                only_ours.format_into("\n  ours only: {}", our_macros[k].as_str());
            }
        }
        for k in 0..want_macros.len() {
            if !our_macros.contains(&want_macros[k]) {
                only_cc.format_into("\n  cc only:   {}", want_macros[k].as_str());
            }
        }
        eprintln(
            "{}: macro dump differs ({} lines, cc has {}){}{}",
            label,
            our_macros.len(),
            want_macros.len(),
            only_ours.as_str(),
            only_cc.as_str(),
        );
    }
    assert_eq(our_macros.len(), want_macros.len());
    assert_eq(m, our_macros.len());
    for i in 0..n {
        if r.origins[i] != scan.origins[i] {
            eprintln(
                "{}: token {} '{}' comes from '{}' for us and '{}' for cc",
                label,
                i,
                r.tokens[i].as_str(),
                r.origins[i].as_str(),
                scan.origins[i].as_str(),
            );
        }
        assert_eq(r.origins[i].as_str(), scan.origins[i].as_str());
        if r.lines[i] != scan.lines[i] {
            eprintln(
                "{}: token {} '{}' is on line {} for us and {} for cc",
                label,
                i,
                r.tokens[i].as_str(),
                r.lines[i],
                scan.lines[i],
            );
        }
        assert_eq(r.lines[i], scan.lines[i]);
    }
    eprintln("{}: {} tokens, origins and lines equal, {} macros equal", label, n, our_macros.len());
}

// The names of `names` that the host's search list holds, by one `__has_include` run.
fn host_headers(p: &cli::Proj, host: &Host, names: []str) Vector<String> {
    let dir = p.dir();
    let mut src = String::new();
    for i in 0..names.len() {
        src.format_into("#if __has_include(<{}>)\nH{} 1\n#endif\n", names[i], i);
    }
    p.mkfile("probe_h.c", &src);
    let mut args = format("-E -w -nostdinc -x c {}/probe_h.c", dir);
    host.search_flags(&mut args);
    assert_eq(
        cc_run(&host.cc, &args, format("{}/probe_h.out", dir).as_str(), format("{}/probe_h.err", dir).as_str()),
        0,
    );
    let toks = tokens_of(cli::read_text(format("{}/probe_h.out", dir).as_str()).as_str());
    let mut found = Vector::<String>::new();
    for i in 0..toks.len() {
        if toks[i].as_str().starts_with("H") {
            found.push(String::from_str(names[toks[i].as_str().slice(1, toks[i].len()).parse_usize().unwrap()]));
        }
    }
    return found;
}

// The six headers the bindgen use cases name, and the portable ones that the host has besides.
@test(timeout = 120)
fn host_system_headers() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    let host = host_info(&p);
    if host.cc.len() == 0 {
        return;
    }
    let undefs = undef_missing(&p, &host);
    let core: []str = ["stdio.h", "stdlib.h", "string.h", "pthread.h", "signal.h", "unistd.h"];
    for i in 0..core.len() {
        let src = format("#include <{}>\n", core[i]);
        expect_host_equal(&p, &host, &undefs, core[i], &src);
    }
}

// Framework headers, an umbrella with subframeworks among them, where the host searches framework directories.
@test(timeout = 120)
fn host_framework_headers() {
    let p = cli::proj_new();
    let host = host_info(&p);
    if host.frameworks.len() == 0 {
        return;
    }
    let undefs = undef_missing(&p, &host);
    expect_host_equal(
        &p,
        &host,
        &undefs,
        "frameworks",
        "#include <CoreFoundation/CoreFoundation.h>\n#include <CoreServices/CoreServices.h>\n",
    );
}

@test(timeout = 300)
fn host_more_system_headers() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let p = cli::proj_new();
    let host = host_info(&p);
    if host.cc.len() == 0 {
        return;
    }
    let undefs = undef_missing(&p, &host);
    let more: []str = [
        "math.h",
        "ctype.h",
        "time.h",
        "errno.h",
        "fcntl.h",
        "dlfcn.h",
        "locale.h",
        "setjmp.h",
        "stdatomic.h",
        "stdint.h",
        "inttypes.h",
        "limits.h",
        "float.h",
        "stdarg.h",
        "stddef.h",
        "sys/types.h",
        "sys/stat.h",
        "sys/socket.h",
        "netinet/in.h",
        "arpa/inet.h",
        "netdb.h",
        "poll.h",
        "sys/mman.h",
        "sys/time.h",
        "dirent.h",
        "termios.h",
        "wchar.h",
        "wctype.h",
        "semaphore.h",
        "regex.h",
        "sys/select.h",
        "sys/wait.h",
        "sys/uio.h",
        "pwd.h",
        "grp.h",
        "assert.h",
        "complex.h",
        "fenv.h",
        "iso646.h",
        "stdbool.h",
        "tgmath.h",
        "sys/resource.h",
        "sys/ioctl.h",
        "sched.h",
        "spawn.h",
        "syslog.h",
        "ifaddrs.h",
        "net/if.h",
        "libgen.h",
        "fnmatch.h",
        "glob.h",
        "search.h",
        "strings.h",
        "utime.h",
        "sys/un.h",
        "sys/utsname.h",
        "sys/statvfs.h",
        "wordexp.h",
        "langinfo.h",
        "monetary.h",
        "nl_types.h",
        "iconv.h",
        "pthread_np.h",
        "stdnoreturn.h",
        "uchar.h",
        "threads.h",
    ];
    let x86: []str = ["xmmintrin.h", "emmintrin.h", "immintrin.h"];
    let arm: []str = ["arm_neon.h", "arm_acle.h"];
    let present = host_headers(&p, &host, more);
    assert(present.len() > 20, "the host has the common system headers");
    let mut src = String::new();
    for i in 0..present.len() {
        src.format_into("#include <{}>\n", present[i].as_str());
    }
    src.push_str("#if defined(__x86_64__)\n");
    let intel = host_headers(&p, &host, x86);
    for i in 0..intel.len() {
        src.format_into("#include <{}>\n", intel[i].as_str());
    }
    src.push_str("#elif defined(__aarch64__)\n");
    let neon = host_headers(&p, &host, arm);
    for i in 0..neon.len() {
        src.format_into("#include <{}>\n", neon[i].as_str());
    }
    src.push_str("#endif\n");
    expect_host_equal(&p, &host, &undefs, "system headers", &src);
}

fn lines(l: []str) String {
    let mut s = String::new();
    for i in 0..l.len() {
        s.push_str(l[i]);
        s.push_byte(b'\n');
    }
    return s;
}

// A synthetic source compared with the host clang's `-E`. The scratch directory holds the files the
// source includes.
fn oracle(label: str, src: &String) {
    let p = cli::proj_new();
    let host = host_info(&p);
    if host.cc.len() == 0 {
        return;
    }
    let undefs = undef_missing(&p, &host);
    p.mkfile("inc/a.h", "int inc_a;\n#include_next <a.h>\nint inc_a_after = __INCLUDE_LEVEL__;\n");
    p.mkfile("inc2/a.h", "int inc2_a = __INCLUDE_LEVEL__;\n");
    p.mkfile("inc/guarded.h", "#ifndef GUARDED_H\n#define GUARDED_H\nint guarded_body;\n#endif\n");
    p.mkfile("inc/once.h", "#pragma once\nint once_body;\n");
    p.mkfile("inc/twice.h", "int twice_body = TWICE_VALUE;\n");
    p.mkfile("local.h", "int local_h; const char *f = __FILE__;\n#include \"sub/rel.h\"\n");
    p.mkfile("sub/rel.h", "int rel_h;\n#include \"sibling.h\"\n");
    p.mkfile("sub/sibling.h", "int sibling_h;\n");
    expect_host_equal(&p, &host, &undefs, label, src.as_str());
}

@test(timeout = 60)
fn oracle_macros() {
    let src = lines(
        [
            "#define OBJ 1 + 2",
            "#define F(x) ((x) * OBJ)",
            "#define G(x, y) F(x) + F(y)",
            "#define EMPTY",
            "#define APPLY(m, a) m a",
            "#define SELF SELF + 1",
            "#define AA BB",
            "#define BB AA",
            "OBJ F(3) G(1, 2) SELF AA BB",
            "F EMPTY (4)",
            "APPLY(F, (5))",
            "F(F(F(1)))",
            "#define foo() bar",
            "foo() foo ( ) foo",
            "#define EXPAND(x) x",
            "EXPAND(F)(6)",
            "#define NIL(xxx) xxx",
            "#define G_0(arg) NIL(G_1)(arg)",
            "#define G_1(arg) NIL(arg)",
            "G_0(42)",
            "#define f(a) a*g",
            "#define g(a) f(a)",
            "f(2)(9)",
            "#define LPAREN (",
            "#define RPAREN )",
            "#define ID(x) x",
            "ID LPAREN 1 RPAREN",
            "#define M2(a, b) a b",
            "M2(F, (1))",
            "M2(,)",
            "M2((a, b), c)",
            "F(",
            "  7",
            ")",
            "#define TWO(a, b) a b",
            "TWO(1,",
            "2) int z; w",
            "TWO(",
            "3,",
            "4) 5 TWO(6, 7) 8",
            "#define LN(x) x __LINE__",
            "LN(",
            "a",
            ") LN(b) LN(",
            "c",
            "d) __LINE__",
            "#define BR(x) [x]",
            "BR(",
            "#define XX 1",
            "XX",
            "#if 1",
            "XX",
            "#else",
            "NO",
            "#endif",
            ")",
            "BR(",
            "#undef XX",
            "XX)",
            "#undef OBJ",
            "#define OBJ 9",
            "F(1)",
            "#define MIN(a, b) ((a) < (b) ? (a) : (b))",
            "MIN(MIN(1, 2), MIN(3, 4))",
            "#define X Y",
            "#define Y X",
            "X Y",
            "#define NEG -",
            "-NEG 1 +NEG+ NEG-",
        ],
    );
    oracle("macros", &src);
}

@test(timeout = 60)
fn oracle_stringify_paste() {
    let src = lines(
        [
            "#define STR(x) #x",
            "#define XSTR(x) STR(x)",
            "#define CAT(a, b) a ## b",
            "#define XCAT(a, b) CAT(a, b)",
            "#define V 42",
            "STR(  a   +   b  ) STR(\"q\\n\" 'c') XSTR(V) STR(V) CAT(x, y) XCAT(V, V) CAT(1, 2) CAT(a, ) CAT(, b)",
            "CAT(+, +) CAT(., 5) CAT(-, >) CAT(<, <=) CAT(L, 'a') CAT(L, \"s\")",
            "#define CAT3(a,b,c) a##b##c",
            "CAT3(1,2,3) CAT3(,,) CAT3(x,,z) CAT3(,y,) CAT3(a,b,)",
            "#define MKSTR(a) # a",
            "STR(/* c */ x /* d */ y)",
            "#define LINE_CAT(a) a ## __LINE__",
            "LINE_CAT(l)",
            "#define PRE(x) pre_ ## x ## _post",
            "PRE(mid) PRE() PRE(1)",
            "STR(a \"b\\\"c\" d)",
            "STR(@)",
            "XSTR(CAT(p, q))",
            "#define OBJCAT a ## b",
            "OBJCAT",
            "#define Z(a) a ## 1 ## a",
            "Z(k) Z()",
            "STR(a",
            "b) STR(a-",
            "-b) STR(  x",
            "  /* c */  y  )",
            "#define HASH #",
            "#define S2(x) HASH x",
            "S2(define) S2(include)",
            "x /* c",
            "*/ #define Y 4",
            "Y",
        ],
    );
    oracle("stringify_paste", &src);
}

@test(timeout = 60)
fn oracle_variadic() {
    let src = lines(
        [
            "#define V1(...) __VA_ARGS__",
            "#define V2(a, ...) a: __VA_ARGS__",
            "#define V3(fmt, ...) printf(fmt, ## __VA_ARGS__)",
            "#define V4(fmt, args...) printf(fmt, ## args)",
            "#define V5(x, ...) x __VA_OPT__(, __VA_ARGS__)",
            "V1() V1(1) V1(1, 2, 3) V1((1,2), 3)",
            "V2(a) V2(a, b) V2(a,b,c) V2(,)",
            "V3(\"x\") V3(\"x\", 1) V3(\"x\", 1, 2) V3(\"x\",)",
            "V4(\"y\") V4(\"y\", 1) V4(\"y\", 1, 2)",
            "V5(1) V5(1, 2) V5(1, 2, 3) V5(1,)",
            "#define VS(...) #__VA_OPT__(x __VA_ARGS__) end",
            "VS() VS(1, 2)",
            "#define VS(...) #__VA_OPT__(x __VA_ARGS__) end",
            "VS() VS(1, 2)",
            "#define SHOW(...) f(0, ## __VA_ARGS__)",
            "SHOW(1)",
            "#define LOG(fmt, ...) log(fmt __VA_OPT__(,) __VA_ARGS__)",
            "LOG(\"a\") LOG(\"a\", 1) LOG(\"a\", 1, 2)",
            "#define COUNT(...) CNT(__VA_ARGS__, 5, 4, 3, 2, 1, 0)",
            "#define CNT(a, b, c, d, e, n, ...) n",
            "COUNT(a) COUNT(a, b) COUNT(a, b, c)",
            "#define E(x, y, ...) x y __VA_ARGS__ end",
            "E(1, 2) E(1, 2, 3, 4)",
        ],
    );
    oracle("variadic", &src);
}

@test(timeout = 60)
fn oracle_conditionals() {
    let src = lines(
        [
            "#define ONE 1",
            "#define TWO 2",
            "#define EXPR (ONE + TWO * 3)",
            "#if EXPR == 7 && (ONE << 4) == 16 && -1 < 0",
            "t1",
            "#endif",
            "#if 0",
            "f1",
            "#elif 1",
            "t2",
            "#else",
            "f2",
            "#endif",
            "#if (2 + 3) * 4 == 20",
            "t3",
            "#endif",
            "#if 10 / 3 == 3 && 10 % 3 == 1 && -7 / 2 == -3 && -7 % 2 == -1",
            "t4",
            "#endif",
            "#if (-1 < 0u) == 0",
            "t5",
            "#endif",
            "#if -1 > 0u",
            "t6",
            "#endif",
            "#if 0xFFFFFFFFFFFFFFFF == -1",
            "t7",
            "#endif",
            "#if 18446744073709551615u / 2 == 9223372036854775807",
            "t8",
            "#endif",
            "#if (1 ? 2 : 3) == 2 && (0 ? 2 : 3) == 3 && (0 ? 1 : 0 ? 2 : 3) == 3",
            "t9",
            "#endif",
            "#if 1 || (1 / 0)",
            "t10",
            "#endif",
            "#if 0 && (1 / 0)",
            "f3",
            "#endif",
            "#if 'a' == 97 && '\\n' == 10 && '\\0' == 0 && '\\x41' == 65 && '\\101' == 65 && '\\\\' == 92",
            "t11",
            "#endif",
            "#if L'a' == 97 && u'b' == 98 && U'c' == 99",
            "t12",
            "#endif",
            "#if !defined(UNDEFINED_THING) && defined ONE && (!defined(TWO)) == 0",
            "t13",
            "#endif",
            "#if UNDEF_ID == 0 && UNDEF_ID + 1 == 1",
            "t14",
            "#endif",
            "#if 1 << 62 > 0 && (1u << 63) > 0",
            "t15",
            "#endif",
            "#if 5 > 3 > 1 == 0",
            "t16",
            "#endif",
            "#if ~0 == -1 && !0 == 1 && !5 == 0 && +3 == 3 && -(-3) == 3",
            "t17",
            "#endif",
            "#if (3 & 6) == 2 && (3 | 4) == 7 && (3 ^ 1) == 2",
            "t18",
            "#endif",
            "#if 0b101 == 5 && 0x1f == 31 && 017 == 15 && 10UL == 10 && 10ull == 10",
            "t19",
            "#endif",
            "#ifdef ONE",
            "t20",
            "#endif",
            "#ifndef NOPE",
            "t21",
            "#endif",
            "#if 0",
            "#else",
            "t22",
            "#endif",
            "#if 0",
            "#if 1",
            "f4",
            "#elif 1",
            "f5",
            "#else",
            "f6",
            "#endif",
            "#elif 0",
            "f7",
            "#else",
            "t23",
            "#endif",
            "#if 0",
            "#garbage directive here",
            "#unknown",
            "#endif",
            "#if 1 ? 2 : (1/0)",
            "t24",
            "#endif",
            "#if 3 > 2 ? 1 : 0",
            "t25",
            "#endif",
            "#if 2 + 3 == 5 || 0",
            "t26",
            "#endif",
            "#if (1, 2) == 2",
            "t27",
            "#endif",
            "#define D defined(ONE)",
            "#if 1 /* c */ + /* d */ 1 == 2 // e",
            "t28",
            "#endif",
            "#if 0x7fffffffffffffff + 0 > 0 && 0x7fffffffffffffffu + 1 > 0",
            "t29",
            "#endif",
            "#if 1 >> 70 == 0 && (1 << 3) >> 1 == 4",
            "t30",
            "#endif",
            "#if '\\377' < 0 || '\\377' > 0",
            "t31",
            "#endif",
            "#if 100000000000 * 100000000000 / 100000000000 == 100000000000",
            "t32",
            "#endif",
            "#if '\\e' == 27",
            "t33",
            "#endif",
        ],
    );
    oracle("conditionals", &src);
}

@test(timeout = 60)
fn oracle_includes() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    let src = lines(
        [
            "#include \"local.h\"",
            "#include <a.h>",
            "#include <guarded.h>",
            "#include <guarded.h>",
            "#include <once.h>",
            "#include <once.h>",
            "#define TWICE_VALUE 1",
            "#include <twice.h>",
            "#undef TWICE_VALUE",
            "#define TWICE_VALUE 2",
            "#include <twice.h>",
            "#define HDR <guarded.h>",
            "#define HAS_HDR <a.h>",
            "#if __has_include(HAS_HDR) && __has_include(HAS_HDR) + 0 == 1",
            "has_macro_header",
            "#endif",
            "#include HDR",
            "#define QHDR \"local.h\"",
            "#include QHDR",
            "#define STRH(x) #x",
            "#define XSTRH(x) STRH(x)",
            "#include XSTRH(sub/sibling.h)",
            "#if __has_include(<a.h>) && __has_include(\"local.h\") && !__has_include(<nonexistent_zz.h>)",
            "has_inc_ok",
            "#endif",
            "#ifdef __has_include",
            "defined_has_include",
            "#endif",
            "int level = __INCLUDE_LEVEL__;",
            "const char *file = __FILE__;",
            "#include <stdio.h>",
            "#if __has_include(<stdio.h>)",
            "has_stdio",
            "#endif",
            "#if defined(__has_attribute)",
            "#if __has_attribute(noreturn) && __has_attribute(__format__)",
            "attr_ok",
            "#endif",
            "#endif",
            "#if defined(__has_builtin)",
            "#if __has_builtin(__builtin_expect) && !__has_builtin(__not_a_builtin_zz)",
            "builtin_ok",
            "#endif",
            "#endif",
        ],
    );
    oracle("includes", &src);
}

@test(timeout = 60)
fn oracle_lines_pragmas() {
    let src = lines(
        [
            "#line 100",
            "__LINE__",
            "#line 200 \"foo.c\"",
            "__LINE__ __FILE__",
            "__COUNTER__ __COUNTER__ __COUNTER__",
            "#pragma omp parallel for",
            "_Pragma(\"pack(push, 1)\") int x; _Pragma(\"pack(pop)\")",
            "#define DO_PRAGMA(x) _Pragma(#x)",
            "DO_PRAGMA(message(\"hi\")) after",
            "#",
            "# /* null directive */",
            "#warning ignored warning",
            "#define LN __LINE__",
            "LN __LINE__",
            "#define PM 1",
            "_Pragma(\"push_macro(\\\"PM\\\")\")",
            "#undef PM",
            "#define PM 2",
            "PM",
            "_Pragma(\"pop_macro(\\\"PM\\\")\")",
            "PM",
            "#define FILEMAC __FILE__",
            "FILEMAC",
            "#define CNT __COUNTER__",
            "CNT CNT",
            "__DATE__ is not compared",
        ],
    );
    let cut = src.as_str().find("__DATE__") as usize;
    let trimmed = String::from_str(src.as_str().slice(0, cut));
    oracle("lines_pragmas", &trimmed);
}

@test(timeout = 60)
fn oracle_lexical() {
    let src = lines(
        [
            "a /* multi",
            "line */ b // trailing \\",
            "continued comment",
            "c\\",
            "d \"string \\",
            "continued\" 'x'",
            "#define LONG(a, \\",
            "  b) a + \\",
            "  b",
            "LONG(1,",
            " 2)",
            "1.5e+10 0x1p-3 .5f 1e+ 0xe+1 1..2 a+++b a---b a<<=b a>>=b x->y ...",
            "L\"wide\" u8\"utf\" u\"x\" U\"y\" L'c'",
            "a = b + + c - - d; e = f+ +g",
            "x/**/y x/* */+/* */+y",
            "%:define DG(x) %:x x%:%:1",
            "DG(a) <: :> <% %> a<::>b",
            "#define E(a) [a]",
            "E(/* c */) E( ) E(\t)",
            "\"//not a comment\" '/*' \"/*\"",
            "int $dollar = 1; \xc3\xa9t\xc3\xa9",
        ],
    );
    oracle("lexical", &src);
}

// ---- Exact behaviour ---------------------------------------------------------------------------------------

// A preprocessor over in-memory files given as path, text pairs.
fn preprocessor_of(pairs: []str, predefs: str) Pp {
    let mut files = Vector::<VFile>::new();
    let mut i: usize = 0;
    while i + 1 < pairs.len() {
        files.push(memory_file(pairs[i], pairs[i + 1]));
        i += 2;
    }
    return Pp::new(make_config(files, predefs));
}

// The exact output of `main.c` in `pairs`.
fn output(pairs: []str) String {
    let mut pp = preprocessor_of(pairs, "");
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the files preprocess");
    return out;
}

// The tokens of the output of the text, against the tokens of `want`.
fn expect_tokens(text: str, want: str) {
    let got = run(text, "");
    let w = tokens_of(want);
    assert_eq(got.as_str(), joined(&w).as_str());
}

@test
fn standard_example_3() {
    expect_tokens(
        "#define x 3\n#define f(a) f(x * (a))\n#undef x\n#define x 2\n#define g f\n#define z z[0]\n#define h g(~\n#define m(a) a(w)\n#define w 0,1\n#define t(a) a\n#define p() int\n#define q(x) x\n#define r(x,y) x ## y\n#define str(x) # x\nf(y+1) + f(f(z)) % t(t(g)(0) + t)(1);\ng(x+(3,4)-w) | h 5) & m\n(f)^m(m);\np() i[q()] = { q(1), r(2,3), r(4,), r(,5), r(,) };\nchar c[2][6] = { str(hello), str() };\n",
        "f(2 * (y+1)) + f(2 * (f(2 * (z[0])))) % f(2 * (0)) + t(1);\nf(2 * (2+(3,4)-0,1)) | f(2 * (~ 5)) & f(2 * (0,1))^m(0,1);\nint i[] = { 1, 23, 4, 5, };\nchar c[2][6] = { \"hello\", \"\" };\n",
    );
}

@test
fn standard_example_4() {
    let out = output(
        [
            "main.c",
            "#define str(s) # s\n#define xstr(s) str(s)\n#define debug(s, t) printf(\"x\" # s \"= %d, x\" # t \"= %s\", \\\n x ## s, x ## t)\n#define INCFILE(n) vers ## n\n#define glue(a, b) a ## b\n#define xglue(a, b) glue(a, b)\n#define HIGHLOW \"hello\"\n#define LOW LOW \", world\"\ndebug(1, 2);\nfputs(str(strncmp(\"abc\\0d\", \"abc\", '\\4') // this goes away\n == 0) str(: @\\n), s);\n#include xstr(INCFILE(2).h)\nglue(HIGH, LOW);\nxglue(HIGH, LOW)\n",
            "vers2.h",
            "included_vers2\n",
        ],
    );
    let want = "printf(\"x\" \"1\" \"= %d, x\" \"2\" \"= %s\", x1, x2);\nfputs(\"strncmp(\\\"abc\\\\0d\\\", \\\"abc\\\", '\\\\4') == 0\" \": @\\n\", s);\nincluded_vers2\n\"hello\";\n\"hello\" \", world\"\n";
    assert_eq(norm(&out).as_str(), norm(want).as_str());
}

@test
fn standard_example_5() {
    expect_tokens(
        "#define t(x,y,z) x ## y ## z\nint j[] = { t(1,2,3), t(,4,5), t(6,,7), t(8,9,),\n t(10,,), t(,11,), t(,,12), t(,,) };\n",
        "int j[] = { 123, 45, 67, 89, 10, 11, 12, };\n",
    );
}

@test
fn standard_example_7() {
    expect_tokens(
        "#define debug(...) fprintf(stderr, __VA_ARGS__)\n#define showlist(...) puts(#__VA_ARGS__)\n#define report(test, ...) ((test)?puts(#test): printf(__VA_ARGS__))\ndebug(\"Flag\");\ndebug(\"X = %d\\n\", x);\nshowlist(The first, second, and third items.);\nreport(x>y, \"x is %d but y is %d\", x, y);\n",
        "fprintf(stderr, \"Flag\");\nfprintf(stderr, \"X = %d\\n\", x);\nputs(\"The first, second, and third items.\");\n((x>y)?puts(\"x>y\"): printf(\"x is %d but y is %d\", x, y));\n",
    );
}

@test
fn line_markers_and_includes() {
    let out = output(["main.c", "a\n#include \"h.h\"\nb\n", "h.h", "x\n"]);
    assert_eq(out.as_str(), "# 1 \"main.c\" 1\na\n# 1 \"h.h\" 1\nx\n# 3 \"main.c\" 2\nb\n");
    let far = output(["main.c", "a\n\n\n\n\n\n\n\n\n\n\nb\n"]);
    assert_eq(far.as_str(), "# 1 \"main.c\" 1\na\n# 12 \"main.c\"\nb\n");
    let near = output(["main.c", "a\n\n\nb\n"]);
    assert_eq(near.as_str(), "# 1 \"main.c\" 1\na\n\n\nb\n");
    let line = output(["main.c", "#line 50 \"q.c\"\nz __LINE__ __FILE__\n"]);
    assert_eq(line.as_str(), "# 1 \"main.c\" 1\n# 50 \"q.c\"\nz 50 \"q.c\"\n");
    let gnu = output(["main.c", "# 7 \"w.c\" 1\nz __LINE__\n"]);
    assert_eq(gnu.as_str(), "# 1 \"main.c\" 1\n# 7 \"w.c\"\nz 7\n");
}

@test
fn pragmas() {
    let out = output(
        ["main.c", "a\n#pragma pack(push, 4)\nb _Pragma(\"x y\") c\n#pragma once\n#define P(x) _Pragma(#x) d\nP(w z)\n"],
    );
    assert_eq(
        out.as_str(),
        "# 1 \"main.c\" 1\na\n#pragma pack(push, 4)\nb\n# 3 \"main.c\"\n#pragma x y\n# 3 \"main.c\"\nc\n\n\n#pragma w z\n# 6 \"main.c\"\nd\n",
    );
}

@test
fn builtin_macros() {
    let text = "__LINE__ __FILE__ __BASE_FILE__ __INCLUDE_LEVEL__ __COUNTER__ __COUNTER__ __DATE__ __TIME__\n#include \"h.h\"\n";
    let a = output(["main.c", text, "h.h", "__INCLUDE_LEVEL__ __FILE__ __BASE_FILE__ __LINE__\n"]);
    let b = output(["main.c", text, "h.h", "__INCLUDE_LEVEL__ __FILE__ __BASE_FILE__ __LINE__\n"]);
    assert_eq(a.as_str(), b.as_str());
    assert_eq(norm(&a).as_str(), "1 \"main.c\" \"main.c\" 0 0 1 \"Jan  1 1970\" \"00:00:00\" 1 \"h.h\" \"main.c\" 1");
}

// clang's `__FLT_EVAL_METHOD__` is a built-in, which glibc tests with `#ifdef`.
@test
fn flt_eval_method_is_a_builtin() {
    expect_tokens("#ifdef __FLT_EVAL_METHOD__\nyes __FLT_EVAL_METHOD__\n#endif\n", "yes 0\n");
}

fn search_pp() Pp {
    let mut config = make_config(Vector::<VFile>::new(), "");
    config.quote_dirs.push(String::from_str("q"));
    config.dirs.push(String::from_str("d"));
    config.sys_dirs.push(String::from_str("s1"));
    config.sys_dirs.push(String::from_str("s2"));
    let files: []str = [
        "src/main.c",
        "#include \"own.h\"\n#include \"x.h\"\n#include <x.h>\n#include <y.h>\n#include \"inner/a.h\"\n#include <q_only.h>\n",
        "src/own.h",
        "SRC_OWN\n",
        "q/own.h",
        "Q_OWN\n",
        "q/x.h",
        "Q_X\n",
        "d/x.h",
        "D_X\n",
        "s1/x.h",
        "S1_X\n",
        "s1/y.h",
        "S1_Y\n#if __has_include_next(<y.h>)\nNEXT_Y\n#endif\n#include_next <y.h>\n",
        "s2/y.h",
        "S2_Y\n",
        "src/inner/a.h",
        "INNER_A\n#include \"b.h\"\n",
        "src/inner/b.h",
        "INNER_B\n",
        "q/q_only.h",
        "Q_ONLY\n",
    ];
    let mut i: usize = 0;
    while i + 1 < files.len() {
        config.files.push(memory_file(files[i], files[i + 1]));
        i += 2;
    }
    return Pp::new(config);
}

@test
fn include_search_order() {
    let mut pp = search_pp();
    let mut out = String::new();
    assert(!pp.preprocess("src/main.c", &mut out), "<q_only.h> is not in an angle directory");
    assert(pp.err.contains("'q_only.h' file not found"), "the message names the header");
    assert_eq(norm(&out).as_str(), "SRC_OWN Q_X D_X S1_Y NEXT_Y S2_Y INNER_A INNER_B");
}

// A framework directory serves `Name/Header.h` from `Name.framework/Headers`, then `PrivateHeaders`, after every
// plain directory. A header the search misses comes from a subframework of the includer's framework.
@test
fn framework_search() {
    let mut config = make_config(Vector::<VFile>::new(), "");
    config.sys_dirs.push(String::from_str("s"));
    config.frameworks.push(String::from_str("f"));
    let files: []str = [
        "main.c",
        "#include <Foo/foo.h>\n#include <Foo/priv.h>\n#include <Foo/plain.h>\n#if __has_include(<Foo/none.h>) || __has_include(<nodir.h>)\nBAD\n#endif\n",
        "f/Foo.framework/Headers/foo.h",
        "FOO\n#include <Bar/bar.h>\n",
        "f/Foo.framework/PrivateHeaders/priv.h",
        "PRIV\n",
        "f/Foo.framework/Headers/plain.h",
        "FRAMEWORK_PLAIN\n",
        "s/Foo/plain.h",
        "DIR_PLAIN\n",
        "f/Foo.framework/Frameworks/Bar.framework/Headers/bar.h",
        "SUB_BAR\n",
        "f/nodir.h",
        "NODIR\n",
    ];
    let mut i: usize = 0;
    while i + 1 < files.len() {
        config.files.push(memory_file(files[i], files[i + 1]));
        i += 2;
    }
    let mut pp = Pp::new(config);
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the framework headers resolve");
    assert_eq(norm(&out).as_str(), "FOO SUB_BAR PRIV DIR_PLAIN");
}

@test
fn include_next_and_once() {
    let out = output(
        [
            "main.c",
            "#include \"o.h\"\n#include \"o.h\"\n#include \"g.h\"\n#include \"g.h\"\n#import \"i.h\"\n#import \"i.h\"\n#include \"i.h\"\n",
            "o.h",
            "#pragma once\nONCE\n",
            "g.h",
            "#ifndef G_H\n#define G_H\nGUARD\n#endif\n",
            "i.h",
            "IMPORTED\n",
        ],
    );
    assert_eq(norm(&out).as_str(), "ONCE GUARD IMPORTED");
}

@test
fn guard_with_code_outside_is_not_a_guard() {
    let out = output(
        [
            "main.c",
            "#include \"g.h\"\n#undef G_H\n#include \"g.h\"\n#include \"h.h\"\n#include \"h.h\"\n",
            "g.h",
            "#ifndef G_H\n#define G_H\nGUARD\n#endif\n",
            "h.h",
            "#ifndef H_H\n#define H_H\nH1\n#else\nH2\n#endif\n",
        ],
    );
    assert_eq(norm(&out).as_str(), "GUARD GUARD H1 H2");
}

fn expect_failure(label: str, text: str, needle: str) {
    let mut pp = one(text, "");
    let mut out = String::new();
    let ok = pp.preprocess("main.c", &mut out);
    if ok || !pp.err.contains(needle) {
        eprintln("case '{}': ok={} err='{}' wanted '{}'", label, ok, pp.err.as_str(), needle);
    }
    assert(!ok, "the text must fail");
    assert(pp.err.contains(needle), "the message names the fault");
}

@test
fn error_paths() {
    expect_failure("error", "a\n#error boom here\n", "main.c:2: #error boom here");
    expect_failure("missing include", "#include \"nope.h\"\n", "'nope.h' file not found");
    expect_failure("endif", "#endif\n", "#endif without #if");
    expect_failure("else", "#else\n", "#else without #if");
    expect_failure("elif", "#elif 1\n", "#elif without #if");
    expect_failure("unterminated if", "#if 1\nx\n", "unterminated conditional");
    expect_failure("unterminated ifdef", "#ifdef A\n#if 1\n#endif\n", "unterminated conditional");
    expect_failure("else twice", "#if 1\n#else\n#else\n#endif\n", "#else after #else");
    expect_failure("elif after else", "#if 1\n#else\n#elif 1\n#endif\n", "#elif after #else");
    expect_failure("empty if", "#if\n#endif\n", "no expression");
    expect_failure("division", "#if 1 / 0\n#endif\n", "division by zero");
    expect_failure("modulo", "#if 1 % 0\n#endif\n", "division by zero");
    expect_failure("dangling operator", "#if 1 +\n#endif\n", "expected a value");
    expect_failure("open paren", "#if (1\n#endif\n", "expected ')'");
    expect_failure("extra token", "#if 1 2\n#endif\n", "unexpected token");
    expect_failure("float", "#if 1.5\n#endif\n", "floating");
    expect_failure("string", "#if \"s\"\n#endif\n", "string literal");
    expect_failure("suffix", "#if 1uu\n#endif\n", "invalid suffix");
    expect_failure("empty char", "#if ''\n#endif\n", "empty character");
    expect_failure("function call", "#if f(1)\n#endif\n", "unexpected token");
    expect_failure("defined", "#if defined\n#endif\n", "unterminated");
    expect_failure("defined number", "#if defined(1)\n#endif\n", "requires an identifier");
    expect_failure("defined paren", "#if defined(A\n#endif\n", "unterminated");
    expect_failure("ternary", "#if 1 ? 2\n#endif\n", "expected ':'");
    expect_failure("elif expression", "#if 0\n#elif 1 / 0\n#endif\n", "division by zero");
    expect_failure("define without name", "#define\n", "macro name missing");
    expect_failure("define number", "#define 1\n", "identifier");
    expect_failure("define defined", "#define defined 1\n", "'defined'");
    expect_failure("duplicate parameter", "#define f(a, a) 1\n", "duplicate");
    expect_failure("open parameter list", "#define f(a\n", "missing ')'");
    expect_failure("bad parameter", "#define f(1) 1\n", "parameter list");
    expect_failure("stringify non parameter", "#define f(a) #b\n", "not followed by a macro parameter");
    expect_failure("paste at start", "#define f(a) ## a\n", "either end");
    expect_failure("paste at end", "#define f(a) a ##\n", "either end");
    expect_failure("va_opt without paren", "#define f(...) __VA_OPT__ x\n", "__VA_OPT__");
    expect_failure("undef number", "#undef 1\n", "identifier");
    expect_failure("ifdef number", "#ifdef 1\n#endif\n", "identifier");
    expect_failure("include syntax", "#include\n", "FILENAME");
    expect_failure("include number", "#include 5\n", "FILENAME");
    expect_failure("include open", "#include <a.h\n", "FILENAME");
    expect_failure("bad directive", "#bogus\n", "invalid preprocessing directive");
    expect_failure("bad directive token", "#\"str\"\n", "invalid preprocessing directive");
    expect_failure("unterminated call", "#define f(a) a\nf(1\n", "unterminated");
    expect_failure("call at end", "#define f(a) a\nf(\n", "unterminated");
    expect_failure("too many", "#define f(a) a\nf(1, 2)\n", "too many arguments");
    expect_failure("too few", "#define g(a, b) a\ng(1)\n", "too few arguments");
    expect_failure("too few empty", "#define g(a, b) a\ng()\n", "too few arguments");
    expect_failure("arguments for none", "#define h() 1\nh(1)\n", "too many arguments");
    expect_failure("variadic too few", "#define v(a, b, ...) a\nv(1)\n", "too few arguments");
    expect_failure("comment", "x /* never closed\n", "unterminated /* comment");
    expect_failure("paste", "#define c(a, b) a##b\nc(+, -)\n", "pasting \"+\" and \"-\"");
    expect_failure("has_include open", "#if __has_include(\n#endif\n", "unterminated");
    expect_failure("has_include name", "#if __has_include(foo)\n#endif\n", "FILENAME");
    expect_failure("has_feature at end", "#if __has_feature\n#endif\n", "unterminated");
    expect_failure("has_feature no paren", "#if __has_feature x\n#endif\n", "'('");
    expect_failure("line", "#line abc\n", "#line");
    expect_failure("line name", "#line 5 foo\n", "filename");
    expect_failure("pragma op", "_Pragma(1)\n", "_Pragma");
    expect_failure("self include", "#include \"main.c\"\n", "nested too deeply");
}

@test
fn conditional_nesting_is_bounded() {
    let mut deep = String::new();
    for _ in 0..1030 {
        deep.push_str("#if 1\n");
    }
    expect_failure("deep conditionals", &deep, "nest too deeply");
    let mut ok = String::new();
    for _ in 0..100 {
        ok.push_str("#if 1\n");
    }
    ok.push_str("x\n");
    for _ in 0..100 {
        ok.push_str("#endif\n");
    }
    assert_eq(run(&ok, "").as_str(), "x");
}

@test
fn expression_and_argument_nesting_are_bounded() {
    let mut parens = String::from_str("#if ");
    for _ in 0..300 {
        parens.push_byte(b'(');
    }
    parens.push_byte(b'1');
    for _ in 0..300 {
        parens.push_byte(b')');
    }
    parens.push_str("\n#endif\n");
    expect_failure("deep parens", &parens, "nests too deeply");
    let mut args = String::from_str("#define f(a) a\n");
    for _ in 0..300 {
        args.push_str("f(");
    }
    args.push_str("x");
    for _ in 0..300 {
        args.push_byte(b')');
    }
    args.push_byte(b'\n');
    expect_failure("deep arguments", &args, "nest too deeply");
    let mut shallow = String::from_str("#define f(a) a\n");
    for _ in 0..100 {
        shallow.push_str("f(");
    }
    shallow.push_str("x");
    for _ in 0..100 {
        shallow.push_byte(b')');
    }
    shallow.push_byte(b'\n');
    assert_eq(run(&shallow, "").as_str(), "x");
}

@test(timeout = 60)
fn expansion_work_is_bounded() {
    let mut text = String::from_str("#define A0 x\n");
    for i in 1..30 {
        text.format_into("#define A{} A{} A{}\n", i, i - 1, i - 1);
    }
    text.push_str("A29\n");
    expect_failure("exponential", &text, "work limit");
}

@test
fn variadic_forms_clang_accepts() {
    expect_tokens(
        "#define SHOW(...) f(0, ## __VA_ARGS__)\n#define V6(...) a ## __VA_OPT__(b c) d\n#define V7(a, ...) __VA_OPT__(a ## a)\n#define V8(a, ...) a ## __VA_OPT__(x) ## a\n#define V9(x, ...) #x __VA_OPT__(# __VA_ARGS__)\nSHOW() SHOW(1) V6() V6(1) V7(z) V7(z, 1) V8(p) V8(p, 1) V9(q) V9(q, r s)\n",
        "f(0) f(0, 1) a d ab c d zz pp pxp \"q\" \"q\" \"r s\"",
    );
}

@test
fn dump_macros_format() {
    let mut pp = one(
        "#define A 1\n#define B(x, y) x ## y\n#define C(...) __VA_ARGS__\n#define D(a, rest...) #a rest\n#define E\n#define F(x) ( x )\n#undef A\n#define G 1  +   2 * 3\n#define H(x) x\n#undef H\n#define H(y, z) y\n#define I() __VA_OPT__\n#define J(a, ...) a __VA_OPT__(, __VA_ARGS__)\n",
        "#define P \"p\"\n",
    );
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the text preprocesses");
    let mut d = String::new();
    pp.dump_macros(&mut d);
    let want = "#define P \"p\"\n#define B(x,y) x ## y\n#define C(...) __VA_ARGS__\n#define D(a,rest...) #a rest\n#define E \n#define F(x) ( x )\n#define G 1 + 2 * 3\n#define H(y,z) y\n#define I() __VA_OPT__\n#define J(a,...) a __VA_OPT__(, __VA_ARGS__)\n";
    assert_eq(d.as_str(), want);
}

fn config_pp(text: str, predefs: str, cmdline: str, has: []str) Pp {
    let mut config = make_config(Vector::<VFile>::new(), predefs);
    config.cmdline = String::from_str(cmdline);
    config.files.push(memory_file("main.c", text));
    config.files.push(memory_file("here.h", "x\n"));
    for i in 0..has.len() {
        config.has.push(String::from_str(has[i]));
    }
    return Pp::new(config);
}

fn run_config(text: str, predefs: str, cmdline: str, has: []str) String {
    let mut pp = config_pp(text, predefs, cmdline, has);
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the text preprocesses");
    return norm(&out);
}

@test
fn has_operators_answer_from_the_table() {
    let text = "#if __has_feature(modules)\nf_modules\n#endif\n#if __has_feature(other)\nf_other\n#endif\n#if __has_extension(ext)\nextension\n#endif\n#if __has_attribute(__noreturn__) && __has_attribute(noreturn)\nattribute\n#endif\n#if __has_attribute(unknown)\nbad_attribute\n#endif\n#if __has_c_attribute(gnu::unused) && __has_c_attribute(__gnu__::__unused__)\nc_attribute\n#endif\n#if __has_builtin(__builtin_trap) && !__has_builtin(__trap)\nbuiltin\n#endif\n#if __has_declspec_attribute(dllimport)\ndeclspec\n#endif\n#ifdef __has_cpp_attribute\nbad_cpp\n#endif\n#if __has_warning(\"-Wall\")\nbad_warning\n#endif\n#if __building_module(m)\nbad_module\n#endif\n#if __is_target_os(macos) && __is_target_arch(arm64) && !__is_target_vendor(pc)\ntarget\n#endif\n#if __is_identifier(foo) && !__is_identifier(int) && !__is_identifier(_Bool)\nidentifier\n#endif\n#if __has_include(\"here.h\") && !__has_include(\"gone.h\") && !__has_include(<here.h>)\ninclude\n#endif\n#ifdef __has_feature\ndefined\n#endif\n";
    let got = run_config(
        text,
        "",
        "",
        [
            "feature:modules",
            "extension:ext",
            "attribute:noreturn",
            "c_attribute:gnu::unused",
            "builtin:__builtin_trap",
            "declspec_attribute:dllimport",
            "target_os:macos",
            "target_arch:arm64",
        ],
    );
    assert_eq(
        got.as_str(),
        "f_modules extension attribute c_attribute builtin declspec target identifier include defined",
    );
    let mut pp = config_pp(text, "", "", []);
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the text preprocesses");
    let asked = joined(&pp.queried);
    assert_eq(
        asked.as_str(),
        "feature:modules feature:other extension:ext attribute:noreturn attribute:unknown c_attribute:gnu::unused builtin:__builtin_trap builtin:__trap declspec_attribute:dllimport target_os:macos target_arch:arm64 target_vendor:pc",
    );
}

@test
fn predefs_and_command_line() {
    let got = run_config(
        "A B C D\n#ifdef GONE\nbad\n#endif\n#ifdef __CHAR_UNSIGNED__\nunsigned_char\n#endif\n#if '\\xff' > 0\nplain_char_unsigned\n#endif\n",
        "#define A 1\n#define B 2\n#define GONE\n#define __CHAR_UNSIGNED__ 1\n",
        "#define B 3\n#define C 4\n#undef GONE\n#define D A + B + C\n",
        [],
    );
    assert_eq(got.as_str(), "1 3 4 1 + 3 + 4 unsigned_char plain_char_unsigned");
    let signed = run_config("#if '\\xff' < 0\nplain_char_signed\n#endif\n", "", "", []);
    assert_eq(signed.as_str(), "plain_char_signed");
    // A wide character constant has `wchar_t`'s type: glibc's `__WCHAR_MIN` tests `L'\0' - 1 > 0`.
    let wide = "#if L'\\0' - 1 > 0\nwchar_unsigned\n#else\nwchar_signed\n#endif\n";
    let wu = run_config(wide, "#define __WCHAR_UNSIGNED__ 1\n", "", []);
    assert_eq(wu.as_str(), "wchar_unsigned");
    let ws = run_config(wide, "", "", []);
    assert_eq(ws.as_str(), "wchar_signed");
}

@test
fn crlf_and_splices() {
    let lf = run("#define A(x) x + \\\n  1\nA(2) // c \\\n  d\n/* a\n b */ z\n\"s\\\nt\"\n", "");
    let crlf = run("#define A(x) x + \\\r\n  1\r\nA(2) // c \\\r\n  d\r\n/* a\r\n b */ z\r\n\"s\\\r\nt\"\r\n", "");
    assert_eq(lf.as_str(), "2 + 1 z \"st\"");
    assert_eq(crlf.as_str(), lf.as_str());
    let bom = run("\u{feff}x y\n", "");
    assert_eq(bom.as_str(), "x y");
    let none = run("x y", "");
    assert_eq(none.as_str(), "x y");
}

@test
fn conditionals_elifdef_and_skipped_text() {
    expect(
        "#define A\n#if 0\n#elifdef A\nyes\n#elifdef B\nno\n#endif\n#ifdef B\n#elifndef A\nno2\n#elifndef B\nyes2\n#endif\n",
        "yes yes2",
    );
    expect("#if 0\n'unterminated char and \"string\n#error not reached\n#else\nkept\n#endif\n", "kept");
    expect("#if 1\nkept\n#else\n#if garbage (\nno\n#endif\n#endif\n", "kept");
}

@test
fn push_and_pop_macro() {
    expect(
        "#define M 1\n#pragma push_macro(\"M\")\n#undef M\n#define M 2\nM\n#pragma pop_macro(\"M\")\nM\n#pragma pop_macro(\"M\")\nM\n",
        "# pragma push_macro ( \"M\" ) 2 # pragma pop_macro ( \"M\" ) 1 # pragma pop_macro ( \"M\" ) 1",
    );
}

@test
fn unsigned_arithmetic_in_conditions() {
    expect(
        "#if -1 < 0u\nbad1\n#endif\n#if (0u - 1) > 0\nok1\n#endif\n#if 9223372036854775807 + 1 < 0\nok2\n#endif\n#if (1 ? -1 : 0u) > 0\nok3\n#endif\n#if -9223372036854775807 - 1 < 0 && (-9223372036854775807 - 1) / -1 == (-9223372036854775807 - 1)\nok4\n#endif\n#if (-9223372036854775807 - 1) % -1 == 0\nok5\n#endif\n#if 1 << -1 == 0 && -8 >> 1 == -4 && -8 >> 70 == -1 && 8 >> -1 == 16\nok6\n#endif\n#if 0xFFFFFFFFFFFFFFFFu >> 63 == 1 && 1u << 64 == 0\nok7\n#endif\n#if 'ab' == 24930 && L'\\x7fffffff' == 2147483647\nok8\n#endif\n#if u'\\xffff' > 0 && U'\\xffffffff' > 0 && '\\0' == 0 && '\\077' == 63\nok9\n#endif\n#if 18446744073709551615 > 0 && 0x8000000000000000 > 0\nok10\n#endif\n",
        "ok1 ok2 ok3 ok4 ok5 ok6 ok7 ok8 ok9 ok10",
    );
}

@test
fn computed_includes_and_line_numbers() {
    let out = output(
        [
            "main.c",
            "#define H \"h.h\"\n#define S(x) #x\n#include H\n#include S(t.h)\n\n\n__LINE__\n",
            "h.h",
            "h __LINE__ __FILE__\n",
            "t.h",
            "t\n",
        ],
    );
    assert(out.contains("h 1 \"h.h\""), "line and file inside the include");
    assert(out.contains("# 5 \"main.c\" 2\n"), "return marker after the second include");
    assert(out.contains("# 4 \"main.c\" 2\n"), "return marker after the first include");
    assert(out.contains("7\n"), "the line after blank lines");
}

@test
fn paste_of_two_hashes() {
    expect_tokens("#define HASH_HASH # ## #\n#define MKSTR(a) # a\nHASH_HASH MKSTR(HASH_HASH)\n", "## \"HASH_HASH\"\n");
}

@test
fn output_layout_details() {
    let comment = output(["main.c", "x /* c\n*/ #define Y 4\ny\n"]);
    assert_eq(comment.as_str(), "# 1 \"main.c\" 1\nx #define Y 4\n\ny\n");
    let hash = output(["main.c", "#define HASH #\n#define S2(x) HASH x\nS2(define)\n"]);
    assert_eq(hash.as_str(), "# 1 \"main.c\" 1\n\n\n # define\n");
}

@test
fn stringify_keeps_the_space_of_a_newline() {
    expect("#define STR(x) #x\nSTR(a\nb) STR(a-\n-b)\n", "\"a b\" \"a- -b\"");
}

@test
fn line_in_a_multi_line_call_is_the_closing_line() {
    expect("#define LN(x) x __LINE__\nLN(\na\n)\n", "a 4");
}

@test
fn pragma_operator_runs_the_directive_forms() {
    let out = output(
        [
            "main.c",
            "#include \"o.h\"\n#include \"o.h\"\n#define M 1\n_Pragma(\"push_macro(\\\"M\\\")\")\n#undef M\n#define M 2\nM\n_Pragma(\"pop_macro(\\\"M\\\")\")\nM\n",
            "o.h",
            "_Pragma(\"once\") ONCE\n",
        ],
    );
    assert_eq(norm(&out).as_str(), "ONCE # pragma push_macro ( \"M\" ) 2 # pragma pop_macro ( \"M\" ) 1");
}

@test
fn escape_e_and_stringified_va_opt() {
    expect("#if '\\e' == 27 && '\\E' == 27\nescape\n#endif\n", "escape");
    expect("#define VS(...) #__VA_OPT__(x __VA_ARGS__) end\nVS() VS(1, 2)\n", "\"\" end \"x 1, 2\" end");
}

@test
fn directives_inside_macro_arguments() {
    expect(
        "#define F(x) [x]\nF(\n#define X 1\nX)\nF(\n#if 0\nno\n#else\nyes\n#endif\n)\nF(\n#undef F\nz)\nF(1)\n",
        "[ 1 ] [ yes ] [ z ] F ( 1 )",
    );
    expect_failure("include in args", "#define F(x) x\nF(\n#include \"main.c\"\n)\n", "within macro arguments");
    expect_failure("unterminated in args", "#define F(x) x\nF(\n#if 1\n", "unterminated");
}

@test
fn dump_keeps_the_space_after_a_hash() {
    let mut pp = one("#define R(a) # a\n#define S(a) #a\n#define N __FILE_NAME__\nN\n", "");
    let mut out = String::new();
    assert(pp.preprocess("main.c", &mut out), "the text preprocesses");
    assert(out.contains("\"main.c\""), "the file name");
    let d = dump_of(&pp);
    assert_eq(d.as_str(), "#define R(a) # a\n#define S(a) #a\n#define N __FILE_NAME__\n");
}

@test
fn ternary_nesting_is_bounded() {
    let mut deep = String::from_str("#if ");
    for _ in 0..400000 {
        deep.push_str("1?");
    }
    deep.push_str("1\n#endif\n");
    expect_failure("deep ternary", &deep, "nests too deeply");
}

@test(timeout = 60)
fn oracle_relative_main_and_spellings() {
    let p = cli::proj_new();
    let host = host_info(&p);
    if host.cc.len() == 0 {
        return;
    }
    let undefs = undef_missing(&p, &host);
    p.mkfile("inc/a.h", "int inc_a;\n#include_next <a.h>\n");
    p.mkfile("inc2/a.h", "int inc2_a = __INCLUDE_LEVEL__;\n");
    p.mkfile("local.h", "int local_h; const char *f = __FILE__;\n#include \"sub/rel.h\"\n");
    p.mkfile("sub/rel.h", "int rel_h; const char *g = __FILE__;\n#include \"sibling.h\"\n");
    p.mkfile("sub/sibling.h", "int sibling_h; const char *h = __FILE__;\n");
    let src = lines(
        [
            "#include \"local.h\"",
            "#include \"./local.h\"",
            "#include \"sub/../local.h\"",
            "#include <a.h>",
            "const char *m = __FILE__;",
        ],
    );
    expect_host_equal_at(&p, &host, &undefs, "relative main", &src, true);
}

@test
fn pragma_in_macro_arguments_is_rejected() {
    expect_failure("pragma in args", "#define F(x) x\nF(\n#pragma omp x\n1)\n", "within macro arguments");
}

@test
fn digraphs() {
    let out = output(["main.c", "%:define H(x) %:x\nH(a<:1:>) <% %> %:%: <::>\n"]);
    assert_eq(out.as_str(), "# 1 \"main.c\" 1\n\n\"a<:1:>\" <% %> %:%: <: :>\n");
}

@test
fn va_opt_group_inherits_the_space() {
    expect_tokens("#define F(x, ...) #__VA_OPT__(x) __VA_OPT__(x)\nF(1,2)\n", "\"1\" 1");
    expect("#define S(x) #x\nS(\\)\n", "\"\"");
}

@test
fn va_opt_rejects_pastes_at_its_ends() {
    expect_failure("paste at start", "#define F(...) __VA_OPT__(## a)\n", "start of __VA_OPT__");
    expect_failure("paste at end", "#define F(...) __VA_OPT__(a ##)\n", "end of __VA_OPT__");
}
