// Lowering and emission paths reached only by specific program shapes: a range bound to a value then
// iterated, a loop inside a cancellable launched task (the compiled cancellation safepoint), and a
// --test build with a global fixture (the test global-env emitter). Each builds through the compiler.
import tests::cli_harness as cli;

@test
fn for_over_a_range_value() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    // The iterable is a range stored in a binding, not a literal `a..b` in the loop header: this takes
    // the range-value lowering rather than the fast literal-range path.
    p.mkfile(
        "src/main.spc",
        "fn main() i32 {\n    let r = 0..10;\n    let mut s = 0;\n    for i in r {\n        s += i;\n    }\n    return s - 45;\n}\n",
    );
    let r = cli::superc_env_in(str::from_cstr(p.rootp()), "SC_NO_EMIT_CACHE", "1", "run");
    assert_eq(r.exit, 0);
}

@test
fn loop_in_a_cancellable_task_gets_a_safepoint() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "import std::parallel::runtime as rt;\nimport std::parallel::sync as sync;\nimport std::parallel::channel as chan;\nimport std::parallel::time as time;\nfn main() i32 {\n    rt::set_worker_count(2);\n    let kch = chan::Channel::<rt::TaskKey>::bounded(1);\n    let ktx = kch.sender();\n    let krx = kch.receiver();\n    let wg = sync::WaitGroup::new();\n    wg.add(1);\n    let w = wg.clone();\n    launch || {\n        defer w.done();\n        let _ = ktx.send(rt::current_key());\n        let mut s: i64 = 0;\n        for i in 0..1000000000 {\n            s += i;\n        }\n        let _ = s;\n    };\n    let key = krx.recv().unwrap();\n    time::sleep(time::Duration::from_millis(5));\n    let _ = rt::request_cancel(key, rt::CR_USER);\n    wg.wait();\n    rt::shutdown();\n    return 0;\n}\n",
    );
    // Build only: the point is that the cancellable loop lowers its safepoint without error.
    let r = cli::superc_env_in(str::from_cstr(p.rootp()), "SC_NO_EMIT_CACHE", "1", "build");
    assert(r.ok(), "the cancellable-loop program builds");
}

@test
fn test_build_with_a_global_fixture() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "struct GEnv { pub n: i32 }\nstruct Fx { pub v: i32 }\n@test_init(global)\nfn genv() GEnv { return GEnv { n: 5 }; }\n@test_init\nfn fx() Fx { return Fx { v: 1 }; }\n@test\nfn uses_both(fx: &mut Fx, env: &GEnv) { assert_eq(fx.v + env.n, 6); }\nfn main() i32 { return 0; }\n",
    );
    // A --test build emits the test global-env setup/teardown wrapper.
    let child = p.compile_flags("--test --quiet", "main.spc");
    assert_eq(child.exit, 0);
    assert(child.out_has("1 passed"), "the global-fixture test runs and passes");
}
