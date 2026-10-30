// The checked prelude image (`driver::prelude_image`): a build that loads it publishes what a build that
// checks the prelude publishes, and a std edit makes the next build check the prelude again. Also the
// interface-default bound a conformance in another module must meet.
import tests::cli_harness as cli;
import driver::util as du;
import driver::prelude_image as pimg;
import module::loader as loader;
import driver_shim as shim;
import build_system::objcache as ocache;
import time;
import utils::persist as per;

// Copy the files and directories under `src` to `dst`.
fn copy_tree(src: str, dst: str) {
    du::mkdir_p(dst);
    let names = du::list_dir(src, false).unwrap();
    for i in 0..names.len() {
        let mut s = String::new();
        s.format_into("{}/{}", src, names.at(i).as_str());
        let mut d = String::new();
        d.format_into("{}/{}", dst, names.at(i).as_str());
        if du::is_dir(&s) {
            copy_tree(&s, &d);
        } else {
            assert(du::copy_file(&s, &d), "the file copies");
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
    let r = cli::superc_env_in(root, "SC_CACHE_DIR", &env, &args);
    assert(r.ok(), "the build succeeds");
    let mut tp = String::new();
    tp.format_into("{}/tt{}.txt", root, tag);
    return cli::read_text(&tp);
}

// The exit code of the program build `tag` made.
fn run(root: str, tag: str) i32 {
    let mut exe = String::new();
    exe.format_into("{}/o{}/app{}", root, tag, unsafe str::from_cstr(cli::binext()));
    return cli::exe_env_in(&exe, root, "SC_NONE", "1", "").exit;
}

@test
fn prelude_image_matches_a_checked_prelude_and_follows_std_edits() {
    let p = cli::proj_new();
    let root = p.dir();
    cli::copy_std(root);
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
    let r = cli::superc_env_in(root, "SC_CACHE_DIR", &env, "build main.spc");
    assert(!r.ok() && r.out_has("names module 'zz_bind', which the std prelude loads from"), "a project file clashes");
    let r2 = cli::superc_env_in(root, "SC_CACHE_DIR", &env, "build zz_bind.spc");
    assert(!r2.ok() && r2.out_has("the root file 'zz_bind.spc' names module 'zz_bind'"), "a root file clashes");
}

// Copy std and ffi below `root`; the std copy's path.
fn copy_std_ffi(root: str) String {
    let std_dir = stdlib::get_env("SC_STD_DIR").unwrap();
    let sd = format("{}/std", root);
    copy_tree(&std_dir, &sd);
    let fd = format("{}/ffi", root);
    let ffi = format("{}/../ffi", std_dir.as_str());
    copy_tree(&ffi, &fd);
    return sd;
}

// The prelude of std copy `sd` below `root`, loaded.
fn load_prelude(root: str, sd: str) loader::Package {
    let host = unsafe shim::sc_host_platform();
    let q = loader::package_load_prelude(root, "", sd, host, Vector::<String>::new(), Vector::<String>::new());
    assert(q.ok && q.modules.len() != 0, "the prelude loads");
    return q;
}

// The image records the std text the prelude check read: a std file edited after the load (during the
// check) makes a reader reject the image, and an unchanged tree reads it.
@test
fn prelude_image_records_the_std_text_it_checked() {
    let p = cli::proj_new();
    let root = p.dir();
    let sd = copy_std_ffi(root);
    let cache = format("{}/cache", root);
    let q = load_prelude(root, &sd);
    let img = String::from_str("image");
    pimg::write(&cache, 1, 2, &q, &sd, pimg::dir_id(&sd), &img);
    let mut at: usize = 0;
    assert(pimg::read(&cache, 1, 2, &mut at).is_some(), "an unchanged std tree reads the image");
    let mut f = String::new();
    f.format_into("{}/option.spc", sd.as_str());
    let mut text = cli::read_text(&f);
    text.push_str("\n");
    p.mkfile("std/option.spc", &text);
    pimg::write(&cache, 1, 2, &q, &sd, pimg::dir_id(&sd), &img);
    assert(pimg::read(&cache, 1, 2, &mut at).is_none(), "a std file edited after the load rejects the image");
}

// The files in directory `dir`.
fn file_count(dir: str) usize {
    return du::list_dir(dir, false).unwrap().len();
}

// `super-c clean` runs the cache sweep, which deletes the prelude images no build reads again: one of an
// older format, one under a name no image has, one whose std files changed, and one whose compiler is no
// longer at the path it recorded. The live images stay while used within a day, and the five most
// recently used ones stay whatever their idle time.
@test
fn sweep_deletes_stale_prelude_images() {
    let p = cli::proj_new();
    let root = p.dir();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    let sd = copy_std_ffi(root);
    let cache = format("{}/cache", root);
    let croot = format("{}/app", cache.as_str());
    let me = du::compiler_id();
    let img = String::from_str("image");
    let q = load_prelude(root, &sd);
    pimg::write(&croot, 3, me, &q, &sd, pimg::dir_id(&sd), &img);
    let f = format("{}/option.spc", sd.as_str());
    let mut text = cli::read_text(&f);
    text.push_str("\n");
    p.mkfile("std/option.spc", &text);
    let q2 = load_prelude(root, &sd);
    pimg::write(&croot, 1, me, &q2, &sd, pimg::dir_id(&sd), &img);
    pimg::write(&croot, 2, me ^ 1, &q2, &sd, pimg::dir_id(&sd), &img);
    let mut old = per::Writer::new();
    old.u64(2);
    old.u64(4);
    old.u64(me);
    old.u64(0);
    let mut oname = String::new();
    ocache::hex64(4, &mut oname);
    ocache::hex64(me, &mut oname);
    p.mkfile(format("cache/app/prelude/{}.img", oname.as_str()).as_str(), &old.buf);
    p.mkfile("cache/app/prelude/09bf53786c101f5a.img", "an image of an older layout");
    let dir = format("{}/prelude", croot.as_str());
    assert(file_count(&dir) == 5, "five images");
    assert(cli::superc_env_in(root, "SC_CACHE_DIR", &cache, "clean").ok(), "clean succeeds");
    assert(file_count(&dir) == 1, "clean deletes the stale images");
    let mut at: usize = 0;
    assert(pimg::read(&croot, 1, me, &mut at).is_some(), "the live image stays");
    for k in 10..16u64 {
        pimg::write(&croot, k, me, &q2, &sd, pimg::dir_id(&sd), &img);
    }
    pimg::sweep(&croot, time::now());
    assert(file_count(&dir) == 7, "the images used within a day stay");
    pimg::sweep(&croot, time::now() + 2 * 86400);
    assert(file_count(&dir) == 5, "the five most recently used idle images stay");
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
