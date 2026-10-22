// std::platform::process: arguments reach a child byte for byte without a shell, redirects and the
// working directory and environment apply to the child only, exit codes and signals come back, any of
// several children is waited for once, and the queries about the running process answer. POSIX tests run
// `sh`, `printf` and `cat`; the Windows ones run `cmd`.

import std::platform::fs;
import std::platform::path;
import std::platform::process;
import tests::platform_harness as ph;

struct Fx {
    pub s: ph::Scratch,
}

@test_init
fn setup() Fx {
    return Fx { s: ph::scratch() };
}

// Run `argv` with standard output (and error) into `out`: its status.
@platform(macos | linux | windows)
fn run_to(argv: []str, out: str) process::ExitStatus {
    let mut cmd = process::Command::new(argv);
    cmd.stdout = process::Redirect::Path(out);
    cmd.stderr = process::Redirect::Stdout;
    let mut c = process::spawn(cmd).unwrap();
    return c.wait().unwrap();
}

@platform(macos | linux)
@test
fn arguments_reach_the_child_byte_for_byte(fx: &mut Fx) {
    let out = fx.s.at("out");
    let argv: [str; 9] = ["printf", "[%s]", "a b", "\"q\" 'r'", "$HOME", "\xC3\xA9", "", "back\\slash", "*"];
    assert(run_to(argv, out.as_str()) == process::ExitStatus::Code(0));
    assert(ph::read_text(out.as_str()).eq_str("[a b][\"q\" 'r'][$HOME][\xC3\xA9][][back\\slash][*]"));
}

@platform(macos | linux)
@test
fn redirects_cwd_and_environment_apply_to_the_child(fx: &mut Fx) {
    let out = fx.s.at("out");
    let input = fx.s.at("in");
    ph::write_text(input.as_str(), "from stdin\n");
    let argv: [str; 3] = ["/bin/sh", "-c", "pwd; echo \"$SC_PLAT_X\"; cat; echo err >&2; exit 4"];
    let env: [str; 2] = ["SC_PLAT_X=one two", "PATH=/usr/bin:/bin"];
    let mut cmd = process::Command::new(argv);
    cmd.env = Option::<Slice<str>>::Some(env);
    cmd.cwd = Option::<str>::Some(fx.s.dir.as_str());
    cmd.stdin = process::Redirect::Path(input.as_str());
    cmd.stdout = process::Redirect::Path(out.as_str());
    cmd.stderr = process::Redirect::Stdout;
    let mut c = process::spawn(cmd).unwrap();
    assert(c.wait().unwrap() == process::ExitStatus::Code(4));
    // A second wait returns the recorded status.
    assert(c.wait().unwrap() == process::ExitStatus::Code(4));
    let mut want = fs::realpath(fx.s.dir.as_str()).unwrap();
    want.push_str("\none two\nfrom stdin\nerr\n");
    assert(ph::read_text(out.as_str()).equals(&want));
    // The parent's environment is untouched, and its own output file starts empty each time.
    assert(std::platform::env::get("SC_PLAT_X").unwrap().is_none());
    let quiet: [str; 3] = ["/bin/sh", "-c", "exit 0"];
    assert(run_to(quiet, out.as_str()) == process::ExitStatus::Code(0));
    assert_eq(fs::stat(out.as_str()).unwrap().size, 0);
}

@platform(macos | linux)
@test
fn exit_codes_and_signals_come_back(fx: &mut Fx) {
    let out = fx.s.at("out");
    let seven: [str; 3] = ["sh", "-c", "exit 7"];
    assert(run_to(seven, out.as_str()) == process::ExitStatus::Code(7));
    let slow: [str; 2] = ["sleep", "30"];
    let mut c = process::spawn(process::Command::new(slow)).unwrap();
    assert(c.try_wait().unwrap().is_none());
    assert(process::is_alive(c.id()).unwrap());
    c.kill().unwrap();
    assert(c.wait().unwrap() == process::ExitStatus::Signal(9));
    assert(!process::is_alive(c.id()).unwrap());
    c.kill().unwrap(); // reaped: no effect
}

@platform(macos | linux)
@test
fn wait_any_returns_each_child_once() {
    let a: [str; 3] = ["sh", "-c", "exit 1"];
    let b: [str; 3] = ["sh", "-c", "exit 2"];
    let c: [str; 3] = ["sh", "-c", "exit 3"];
    let mut kids: [process::Child; 3] = [
        process::spawn(process::Command::new(a)).unwrap(),
        process::spawn(process::Command::new(b)).unwrap(),
        process::spawn(process::Command::new(c)).unwrap(),
    ];
    let mut seen: [bool; 3] = [false; 3];
    for _ in 0..3 {
        let (i, st) = process::wait_any(kids).unwrap();
        assert(!unsafe seen[i]);
        unsafe seen[i] = true;
        assert(st == process::ExitStatus::Code(i as i32 + 1));
    }
    assert(process::wait_any(kids).unwrap_err().kind == IoErrorKind::InvalidInput);
    assert(process::try_wait_any(kids).unwrap().is_none());
    // try_wait_any finds an ended child without reaping others.
    let fast: [str; 3] = ["sh", "-c", "exit 5"];
    let slow: [str; 2] = ["sleep", "30"];
    let mut two: [process::Child; 2] = [
        process::spawn(process::Command::new(slow)).unwrap(),
        process::spawn(process::Command::new(fast)).unwrap(),
    ];
    assert(two[1].wait().unwrap() == process::ExitStatus::Code(5));
    assert(process::try_wait_any(two).unwrap().is_none());
    two[0].kill().unwrap();
    assert(process::wait_any(two).unwrap().0 == 0);
}

@platform(windows)
@test
fn windows_children_report_exit_codes_and_output(fx: &mut Fx) {
    let out = fx.s.at("out");
    let seven: [str; 3] = ["cmd", "/c", "exit 7"];
    assert(run_to(seven, out.as_str()) == process::ExitStatus::Code(7));
    let echo: [str; 3] = ["cmd", "/c", "echo hi"];
    assert(run_to(echo, out.as_str()) == process::ExitStatus::Code(0));
    assert(ph::read_text(out.as_str()).eq_str("hi\r\n"));
    let slow: [str; 3] = ["cmd", "/c", "ping -n 30 127.0.0.1 >NUL"];
    let mut kids: [process::Child; 1] = [process::spawn(process::Command::new(slow)).unwrap()];
    assert(process::try_wait_any(kids).unwrap().is_none());
    kids[0].kill().unwrap();
    assert(process::wait_any(kids).unwrap().1 == process::ExitStatus::Code(137));
}

@platform(!wasm)
@test
fn bad_commands_are_rejected() {
    let none: [str; 0] = [];
    assert(process::spawn(process::Command::new(none)).unwrap_err().kind == IoErrorKind::InvalidInput);
    let missing: [str; 1] = ["sc-platform-no-such-program"];
    let e = process::spawn(process::Command::new(missing)).unwrap_err();
    assert(e.kind == IoErrorKind::NotFound);
    assert(e.op == IoOp::Spawn);
    let nul: [str; 2] = ["sh", "a\x00b"];
    assert(process::spawn(process::Command::new(nul)).unwrap_err().kind == IoErrorKind::InvalidInput);
    let mut bad = process::Command::new(missing);
    bad.stdout = process::Redirect::Stdout;
    assert(process::spawn(bad).unwrap_err().kind == IoErrorKind::InvalidInput);
}

@platform(macos | linux)
@test
fn a_pipe_carries_a_child_output_to_its_end(fx: &mut Fx) {
    let input = fx.s.at("in");
    ph::write_text(input.as_str(), "through the pipe");
    let (mut r, w) = process::pipe().unwrap();
    let argv: [str; 1] = ["cat"];
    let mut cmd = process::Command::new(argv);
    cmd.stdin = process::Redirect::Path(input.as_str());
    cmd.stdout = process::Redirect::Handle(&w);
    let mut c = process::spawn(cmd).unwrap();
    assert(w.close().is_ok()); // the child holds the only write end now
    let mut got = String::new();
    let mut buf: [u8; 5] = [0; 5];
    // Short reads until the end of the stream.
    loop {
        let n = r.read(buf).unwrap();
        if n == 0 {
            break;
        }
        assert(n <= 5);
        got.push_bytes(unsafe buf[0..n]);
    }
    assert(got.eq_str("through the pipe"));
    assert(c.wait().unwrap() == process::ExitStatus::Code(0));
}

@platform(!wasm)
@test
fn the_running_process_answers_its_queries(fx: &mut Fx) {
    let me = process::pid().unwrap();
    assert(me > 0);
    assert(process::is_alive(me).unwrap());
    assert(process::is_alive(0).unwrap_err().kind == IoErrorKind::InvalidInput);
    let exe = process::exe_path().unwrap();
    assert(path::is_absolute(exe.as_str()));
    assert(fs::stat(exe.as_str()).unwrap().kind == fs::FileKind::File);
    let cwd = process::current_dir().unwrap();
    process::set_current_dir(fx.s.dir.as_str()).unwrap();
    let here = process::current_dir().unwrap();
    let real = fs::realpath(fx.s.dir.as_str()).unwrap();
    assert(here.equals(&real));
    process::set_current_dir(cwd.as_str()).unwrap();
    assert(process::set_current_dir(fx.s.at("missing").as_str()).unwrap_err().kind == IoErrorKind::NotFound);
    assert(process::peak_rss().unwrap() > 0);
    process::raise_open_file_limit(64).unwrap();
    if PLATFORM == Platform::Windows {
        assert(!exe.contains_byte(b'\\'));
        assert(!here.contains_byte(b'\\'));
    }
}
