// The LIR evaluator against CTFE on the suite's own tests: `super-c test` under `SC_LIR` and
// `SC_LIR_EVAL` emits the tests a filter selects, runs each under CTFE and under the evaluator, and
// fails when the two end differently. The math tests' LIR also reads back from its text form.
import tests::cli_harness as cli;
import lir::ir as *;
import lir::verify as verify;
import lir::print as lprint;
import lir::parse as lparse;

// The evaluator check over the tests whose name holds `filter`, built in scratch project `p` (the LIR
// text into `<p>/pkg.lir` when `text`). Its tally: the tests, those compared with CTFE, those that
// disagree, those CTFE does not finish checked against their expectation, those that fail it, those
// that call FFI and those past a budget.
fn eval_check(p: &cli::Proj, filter: str, text: bool) Vector<u64> {
    let mut env = String::from_str("SC_LIR=1 SC_LIR_EVAL=1 SC_LIR_STATS=1");
    if text {
        env.format_into(" SC_LIR_TEXT={}/pkg.lir", p.dir());
    }
    let mut cmd = format("\"{}\" test --quiet --filter={} --out-dir={}/out", cli::superc_path(), filter, p.dir());
    let mut log = format("{}/log", p.dir());
    let rc = cli::run_with(cmd.cstr(), null, log.cstr(), null, env.as_str());
    let out = cli::read_text(log.as_str());
    assert(rc == 0, out.as_str());
    // The tally line: `lir: ctfe: <n> tests: ..` (a test's own line names it after the prefix).
    let mut line: str = "";
    for l in out.as_str().lines() {
        if l.starts_with("lir: ctfe: ") && l.len() > 11 && l.byte_at(11) >= b'0' && l.byte_at(11) <= b'9' {
            line = l;
        }
    }
    assert(line.len() != 0, out.as_str());
    let mut nums = Vector::<u64>::new();
    let mut cur: u64 = 0;
    let mut digits = false;
    for i in 0..line.len() {
        let c = line.byte_at(i);
        if c >= b'0' && c <= b'9' {
            cur = cur * 10 + (c - b'0') as u64;
            digits = true;
        } else if digits {
            nums.push(cur);
            cur = 0;
            digits = false;
        }
    }
    assert(nums.len() == 7, line);
    assert(nums[2] == 0 && nums[4] == 0, line);
    // At least three quarters of the tests run under the evaluator: compared with CTFE, or checked
    // against their expectation.
    assert(nums[1] != 0 && (nums[1] + nums[3]) * 4 >= 3 * nums[0], line);
    return nums;
}

@test(timeout = 300)
fn the_evaluator_agrees_with_ctfe_on_the_math_tests() {
    // The wasm guest starts no process.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    let _ = eval_check(&p, "tests::math::", true);
    // The build's LIR: it parses, each body verifies and takes its callees' signatures, and it prints
    // back to the same text.
    let text = cli::read_text(format("{}/pkg.lir", p.dir()).as_str());
    let mut err = String::new();
    let q = lparse::parse(text.as_str(), &mut err);
    assert(q.is_some(), err.as_str());
    let pk = q.unwrap();
    let mut v = verify::Verifier::new();
    for i in 0..pk.syms.len() {
        let s = pk.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            let b = &pk.bodies[s.def as usize];
            assert(v.check(&pk, pk.spell(s.name), b) && v.check_calls(&pk, pk.spell(s.name), b), v.err.as_str());
        }
    }
    let mut t2 = String::new();
    lprint::print_package(&pk, &mut t2);
    assert(t2.as_str() == text.as_str(), "print, parse and print give the same text");
}

@test(timeout = 300)
fn the_evaluator_agrees_with_ctfe_on_the_std_tests() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    let _ = eval_check(&p, "tests::stdlib::", false);
}
