// The checked prelude image (`driver::prelude_image`): a build that loads it publishes what a build that
// checks the prelude publishes, and a std edit makes the next build check the prelude again. Also the
// interface-default bound a conformance in another module must meet.
import stdlib;
import tests::cli_harness as cli;
import driver::util as du;

// Copy the files and directories under `src` to `dst`.
fn copy_tree(src: str, dst: str) {
    du::mkdir_p(dst);
    let names = du::list_dir(src, false).unwrap();
    for i in 0..names.len() {
        let mut s = String::new();
        s.format_into("{}/{}", src, names.at(i).as_str());
        let mut d = String::new();
        d.format_into("{}/{}", dst, names.at(i).as_str());
        if du::is_dir(s.as_str()) {
            copy_tree(s.as_str(), d.as_str());
        } else {
            assert(du::copy_file(s.as_str(), d.as_str()), "the file copies");
        }
    }
}

// Build `main.spc` under `root` into `o<tag>/app` with the copied std tree and the test's own cache;
// the type table goes to `tt<tag>.txt`. The table.
fn build(root: str, tag: str) String {
    let mut env = String::new();
    env.format_into("{}/cache SC_STD_DIR={}/sc/std SC_TYPE_TABLE={}/tt{}.txt", root, root, root, tag);
    let mut args = String::new();
    args.format_into("build main.spc -o {}/o{}/app --out-dir={}/o{}", root, tag, root, tag);
    let r = cli::superc_env_in(root, "SC_CACHE_DIR", env.as_str(), args.as_str());
    assert(r.ok(), "the build succeeds");
    let mut tp = String::new();
    tp.format_into("{}/tt{}.txt", root, tag);
    return cli::read_text(tp.as_str());
}

// The exit code of the program build `tag` made.
fn run(root: str, tag: str) i32 {
    let mut exe = String::new();
    exe.format_into("{}/o{}/app{}", root, tag, unsafe str::from_cstr(cli::binext()));
    return cli::exe_env_in(exe.as_str(), root, "SC_NONE", "1", "").exit;
}

@test
fn prelude_image_matches_a_checked_prelude_and_follows_std_edits() {
    let p = cli::proj_new();
    let root = p.dir();
    let std_dir = stdlib::get_env("SC_STD_DIR").unwrap();
    let mut sc = String::new();
    sc.format_into("{}/sc", root);
    let mut d = String::new();
    d.format_into("{}/std", sc.as_str());
    copy_tree(std_dir.as_str(), d.as_str());
    d.clear();
    d.format_into("{}/ffi", sc.as_str());
    let mut ffi = String::new();
    ffi.format_into("{}/../ffi", std_dir.as_str());
    copy_tree(ffi.as_str(), d.as_str());
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let _ = build(root, "0");
    // A new std file: the prelude is checked again (the old image has no `zz_answer`).
    p.mkfile("sc/std/zz_answer.spc", "pub fn zz_answer() i32 {\n    return 42;\n}\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return zz_answer();\n}\n");
    let cold = build(root, "1");
    let warm = build(root, "2");
    assert(cold.equals(&warm), "the image publishes the table a checked prelude does");
    assert(run(root, "2") == 42, "the program runs");
    // A changed std file: the prelude is checked again (the old image would answer 42).
    p.mkfile("sc/std/zz_answer.spc", "pub fn zz_answer() i32 {\n    return 43;\n}\n");
    let _ = build(root, "3");
    assert(run(root, "3") == 43, "the edit reaches the program");
    // A prelude file that imports a binding: a project file or a root file of that module path would
    // get the std module, so the build names the clash.
    p.mkfile("sc/ffi/zz_bind.spc", "pub fn zz_one() i32 {\n    return 1;\n}\n");
    p.mkfile("sc/std/zz_user.spc", "import zz_bind;\n\npub fn zz_two() i32 {\n    return zz_bind::zz_one() + 1;\n}\n");
    p.mkfile("zz_bind.spc", "pub fn zz_one() i32 {\n    return 5;\n}\n");
    p.mkfile("main.spc", "import zz_bind;\n\nfn main() i32 {\n    return zz_bind::zz_one();\n}\n");
    let mut env = String::new();
    env.format_into("{}/cache SC_STD_DIR={}/sc/std", root, root);
    let r = cli::superc_env_in(root, "SC_CACHE_DIR", env.as_str(), "build main.spc");
    assert(!r.ok() && r.out_has("names module 'zz_bind', which the std prelude loads from"), "a project file clashes");
    let r2 = cli::superc_env_in(root, "SC_CACHE_DIR", env.as_str(), "build zz_bind.spc");
    assert(!r2.ok() && r2.out_has("the root file 'zz_bind.spc' names module 'zz_bind'"), "a root file clashes");
}

// A conformance in another module whose bounds the receiver does not meet gives no method, not even
// the interface default it would inherit.
@test
fn default_method_needs_its_conformance_bounds() {
    let p = cli::proj_new();
    p.mkfile(
        "lib/tag.spc",
        "pub interface Tag {\n    fn tag(self: &Self) i32 {\n        return 5;\n    }\n}\n\nextend<T: Tag> Vector<T> as Tag {\n    fn tag(self: &Vector<T>) i32 {\n        return 7 + self.at(0).tag();\n    }\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import lib::tag as *;\n\nstruct S {\n    pub w: u32,\n}\n\nfn main() i32 {\n    let mut v = Vector::<S>::new();\n    v.push(S { w: 1 });\n    return v.tag();\n}\n",
    );
    let r = cli::superc_in(p.dir(), "build main.spc");
    assert(
        !r.ok() && r.out_has("cannot call 'Vector<S, Global>::tag': unsatisfied interface bounds"),
        "the bound fails",
    );
}
