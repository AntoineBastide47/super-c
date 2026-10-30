// std::platform on WASI: one program built with `--target=wasm` and run under wasmtime checks that every
// facility WASI lacks returns Unsupported (never a silent success) and that what WASI has works: entropy
// from `random_get`, files with short reads and their end, NotFound, the environment, the clocks and
// thread-local keys. The test needs a wasi-sdk in WASI_SDK_PATH and wasmtime on the PATH, as the wasm lane
// sets them; without the SDK it returns early.

import std::platform::env;
import std::platform::fs;
import std::platform::process;
import tests::platform::platform_harness as ph;

const PROGRAM: str = M"(
import std::platform::clock;
import std::platform::cpu;
import std::platform::dylib;
import std::platform::entropy;
import std::platform::env;
import std::platform::fs;
import std::platform::process;
import std::platform::signal;
import std::platform::socket;
import std::platform::thread;
import std::platform::vm;
import std::net;

fn check(name: str, ok: bool) {
    if !ok {
        println("FAIL {}", name);
    }
}

fn unsupported<T>(name: str, r: Result<T, IoError>) {
    if r.is_ok() {
        println("FAIL {}: succeeded", name);
        return;
    }
    let e = r.unwrap_err();
    if e.kind != IoErrorKind::Unsupported {
        println("FAIL {}: {}", name, e.kind);
    }
}

fn bytes_of(s: str) []u8 {
    return unsafe Slice::<u8> { ptr: s.ptr(), len: s.len() };
}

fn worker(a: *mut void) *mut void {
    return a;
}

fn main() i32 {
    let mut a: [u8; 32] = [0; 32];
    let mut b: [u8; 32] = [0; 32];
    check("entropy a", entropy::fill(a).is_ok());
    check("entropy b", entropy::fill(b).is_ok());
    let va: []u8 = a;
    let vb: []u8 = b;
    let mut same = true;
    for i in 0..32usize {
        same = same && va[i] == vb[i];
    }
    check("entropy differs", !same);
    check("clock", clock::monotonic_ns() > 0 && clock::wall_ns() > 1600000000 * 1000000000);
    check("cpu", cpu::count().unwrap() == 1);
    check("page", vm::page_size().unwrap() == 65536);
    let mut k = thread::TlsKey::new().unwrap();
    check("tls", k.set(null).is_ok() && k.get() == null);
    check("env set", unsafe env::set("SC_WASI_X", "1").is_ok());
    check("env get", env::get("SC_WASI_X").unwrap().unwrap().eq_str("1"));
    check("env unset", unsafe env::unset("SC_WASI_X").is_ok() && env::get("SC_WASI_X").unwrap().is_none());

    check("mkdir", fs::mkdir_all("d/e").is_ok());
    check("publish", fs::publish("d/e/f", bytes_of("0123456789")).unwrap());
    check("publish same", !fs::publish("d/e/f", bytes_of("0123456789")).unwrap());
    let mut f = fs::open("d/e/f", fs::OpenOptions { read: true }).unwrap();
    let mut four: [u8; 4] = [0; 4];
    check("read 4", f.read(four).unwrap() == 4);
    check("read 4 again", f.read(four).unwrap() == 4);
    check("read short", f.read(four).unwrap() == 2);
    check("read end", f.read(four).unwrap() == 0);
    let m = fs::stat("d/e/f").unwrap();
    check("stat", m.kind == fs::FileKind::File && m.size == 10 && m.created_ns.is_none());
    check("missing", fs::open("nope", fs::OpenOptions { read: true }).unwrap_err().kind == IoErrorKind::NotFound);
    check("symlink", fs::symlink("f", "d/e/l").is_ok() && fs::readlink("d/e/l").unwrap().eq_str("f"));
    check("touch", fs::set_times("d/e/f", fs::FileTime::Now, fs::FileTime::Now).is_ok());
    let mut n = 0;
    let mut d = fs::read_dir("d/e").unwrap();
    while let Some(r) = d.next() {
        check("entry", r.is_ok());
        n += 1;
    }
    check("listing", n == 2);

    unsupported("set_permissions", fs::set_permissions("d/e/f", 0o644));
    unsupported("lock", f.lock_exclusive(0));
    unsupported("unlock", f.unlock());
    unsupported("reserve", vm::reserve(65536));
    unsupported("thread", unsafe thread::spawn(worker, null));
    let argv: [str; 1] = ["true"];
    unsupported("spawn", process::spawn(process::Command::new(argv)));
    unsupported("pipe", process::pipe());
    unsupported("pid", process::pid());
    unsupported("is_alive", process::is_alive(1));
    unsupported("exe_path", process::exe_path());
    unsupported("peak_rss", process::peak_rss());
    unsupported("open files", process::raise_open_file_limit(64));
    unsupported("signal ignore", signal::ignore(signal::Signal::Pipe));
    unsupported("signal handler", unsafe signal::set_handler(signal::Signal::User1, check_signal));
    unsupported("dylib", unsafe dylib::open("libc.so"));
    unsupported("tcp listen", socket::tcp_listen("127.0.0.1", 0, 1));
    unsupported("tcp connect", socket::tcp_connect("127.0.0.1", 1));
    unsupported("udp", socket::udp_bind("127.0.0.1", 0));
    unsupported("poller", socket::Poller::new());
    unsupported("net", net::TcpListener::bind("127.0.0.1", 0));
    check("remove", fs::remove_all("d").is_ok());
    println("done");
    return 0;
}

fn check_signal(_s: i32) {}
)";

@platform(macos | linux)
@test
fn unsupported_facilities_report_unsupported_on_wasi() {
    let sdk = env::get("WASI_SDK_PATH").unwrap();
    if sdk.is_none() || sdk.unwrap().len() == 0 {
        return;
    }
    let s = ph::scratch();
    ph::write_text(s.at("main.spc").as_str(), PROGRAM);
    ph::write_text(s.at("build.toml").as_str(), "bin = \"prog\"\nroot = \"main.spc\"\n");
    let named = env::get("SUPERC").unwrap().unwrap_or(String::from_str("./super-c"));
    let superc = fs::realpath(&named).unwrap();
    let mut transpiler = String::from_str("--transpiler=");
    transpiler.push_string(&superc);
    let log = s.at("build.log");
    let mut argv = Vector::<str>::new();
    argv.push(&superc);
    argv.push("build");
    argv.push("--target=wasm");
    // On the wasm lane SUPERC is the wasm compiler's wrapper: the build engine runs natively and hands
    // the transpile step to it, as the differential harness does.
    if superc.contains("wasm") {
        argv.push(&transpiler);
    }
    argv.push("-o");
    argv.push("prog");
    let mut build = process::Command::new(argv[0..argv.len()]);
    build.cwd = Some(s.dir.as_str());
    build.stdout = process::Redirect::Path(log.as_str());
    build.stderr = process::Redirect::Stdout;
    let mut builder = process::spawn(build).unwrap();
    let built = builder.wait().unwrap();
    if built != process::ExitStatus::Code(0) {
        eprintln("{}", ph::read_text(&log).as_str());
    }
    assert(built == process::ExitStatus::Code(0));
    let out = s.at("run.out");
    let run_argv: [str; 4] = ["wasmtime", "run", "--dir=.", "prog"];
    let mut run = process::Command::new(run_argv);
    run.cwd = Some(s.dir.as_str());
    run.stdout = process::Redirect::Path(out.as_str());
    run.stderr = process::Redirect::Stdout;
    let mut runner = process::spawn(run).unwrap();
    let ran = runner.wait().unwrap();
    let text = ph::read_text(&out);
    if ran != process::ExitStatus::Code(0) || !text.eq_str("done\n") {
        eprintln("{}", text.as_str());
    }
    assert(ran == process::ExitStatus::Code(0));
    assert(text.eq_str("done\n"));
}
