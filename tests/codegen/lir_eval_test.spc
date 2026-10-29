// The LIR evaluator against CTFE on the suite's own tests: `super-c test` under `SC_LIR` and
// `SC_LIR_EVAL` emits the tests a filter selects, runs each under CTFE and under the evaluator, and
// fails when the two end differently. The math tests' LIR also reads back from its text form.
import tests::cli_harness as cli;
import lir::ir as *;
import lir::verify as verify;
import lir::print as lprint;
import lir::parse as lparse;

// The evaluator check over the tests whose name holds `filter`, built in scratch project `p` (the LIR
// text into `<p>/pkg.lir` when `text`; optimized, `lir::opt`, when `opt`). Its tally: the tests, those compared with CTFE, those that
// disagree, those CTFE does not finish checked against their expectation, those that fail it, those
// that call FFI and those past a budget.
fn eval_check(p: &cli::Proj, filter: str, text: bool, opt: bool) Vector<u64> {
    let mut env = String::from_str("SC_LIR=1 SC_LIR_EVAL=1 SC_LIR_STATS=1");
    env.push_str(
        if opt {
            " SC_LIR_OPT=1";
        } else {
            " SC_LIR_OPT=0";
        },
    );
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
    read_back(&p, false);
}

// The math tests' check (`eval_check`), optimized or not; then the build's LIR text parses, each body
// verifies and takes its callees' signatures, and it prints back to the same text.
fn read_back(p: &cli::Proj, opt: bool) {
    let _ = eval_check(p, "tests::math::", true, opt);
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
    let _ = eval_check(&p, "tests::stdlib::", false, false);
}

// The optimizer (`lir::opt`, the inliner first) keeps the evaluator's results: the optimized LIR of the
// math tests agrees with CTFE and reads back from its text (inlined call sites, `noinline`).
@test(timeout = 300)
fn the_optimized_lir_agrees_with_ctfe_on_the_math_tests() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    read_back(&p, true);
}

// A closure a generic function takes is called directly: its type names its body, so the call needs no
// function pointer, and the optimizer may inline it; a capturing closure takes its environment first.
@test(timeout = 300)
fn a_closure_a_generic_function_takes_is_called_directly() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(fn apply<F: fn(i64) i64>(f: F, x: i64) i64 {
    return f(x);
}

fn main() i32 {
    let k: i64 = 3;
    let r = apply(|x: i64| x + k, 4) + apply(|x: i64| x * 2, 5);
    return (r - 17) as i32;
}
)",
    );
    let env = format("SC_LIR=1 SC_LIR_OPT=0 SC_NO_TU_CACHE=1 SC_NO_EMIT_CACHE=1 SC_LIR_TEXT={}/pkg.lir", p.dir());
    let r = p.compile_flags_env("", "main.spc", env.as_str());
    assert(r.ok(), "the program builds and returns 0");
    let text = cli::read_text(format("{}/pkg.lir", p.dir()).as_str());
    assert(!text.contains("callind") && text.contains("closure_b"), text.as_str());
}

// The lowering marks a parameter's referent read-only (`readonly`) for a `&T` of a struct whose members
// hold no `UnsafeCell` and for a `str` (`inner readonly`, its bytes); not for a `&T` whose `T` holds a
// cell, which changes through the shared reference.
@test(timeout = 300)
fn shared_references_to_frozen_structs_and_strs_are_read_only() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::mem::cell;

struct Pair {
    pub a: u64,
    pub b: [u32; 4],
}

struct Counter {
    pub n: cell::Cell<u32>,
}

@noinline
fn pair_sum(p: &Pair) u64 {
    return p.a + p.b[1] as u64;
}

@noinline
fn text_len(s: str) usize {
    return s.len();
}

@noinline
fn counted(c: &Counter) u32 {
    c.n.set(c.n.get() + 1);
    return c.n.get();
}

fn main() i32 {
    let p = Pair { a: 2, b: [0, 3, 0, 0] };
    let c = Counter { n: cell::Cell::<u32>::new(4) };
    return (pair_sum(&p) as u32 + text_len("ab") as u32 + counted(&c) - 12) as i32;
}
)",
    );
    let env = format("SC_LIR=1 SC_LIR_OPT=0 SC_NO_TU_CACHE=1 SC_NO_EMIT_CACHE=1 SC_LIR_TEXT={}/pkg.lir", p.dir());
    let r = p.compile_flags_env("", "main.spc", env.as_str());
    assert(r.ok(), "the program builds and returns 0");
    let text = cli::read_text(format("{}/pkg.lir", p.dir()).as_str());
    assert(head_of(&text, "main__pair_sum").contains("ref p0 24 readonly"), text.as_str());
    assert(head_of(&text, "main__text_len").contains("ref p0 0 inner readonly"), text.as_str());
    assert(!head_of(&text, "main__counted").contains("readonly"), text.as_str());
}

// The lines of function `name` in LIR text `text` before its entry block.
fn head_of(text: &String, name: str) String {
    let t = text.as_str();
    let h = format("fn @{}\n", name);
    let at = t.find(h.as_str());
    assert(at >= 0, h.as_str());
    let rest = t.slice(at as usize, t.len());
    let end = rest.find("\nb0(");
    assert(end >= 0, rest);
    return String::from_str(rest.slice(0, end as usize));
}

// The lowering lists a reference parameter's `@owned` pointer fields (`owned p<k> <offset>`), those of
// the structs its referent holds by value too; for a `&T`, only those whose buffer holds no cell.
@test(timeout = 300)
fn owned_fields_of_reference_parameters_are_listed() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::mem::cell;

struct Inner {
    @owned pub p: *mut u64,
    pub n: usize,
}

struct Outer {
    pub tag: u64,
    pub i: Inner,
    @owned pub q: *const u32,
}

struct Cells {
    @owned pub c: *mut cell::Cell<u32>,
}

@noinline
fn take(o: &mut Outer) u64 {
    return o.tag;
}

@noinline
fn look(o: &Outer) u64 {
    return o.tag + o.i.n as u64;
}

@noinline
fn cells(c: &Cells) u32 {
    return unsafe (*c.c).get();
}

fn main() i32 {
    let mut x: u64 = 1;
    let y: u32 = 2;
    let mut o = Outer { tag: 3, i: Inner { p: &mut x, n: 0 }, q: &y };
    let z = cell::Cell::<u32>::new(4);
    let c = Cells { c: (&z as *const cell::Cell<u32>) as *mut cell::Cell<u32> };
    return (take(&mut o) + look(&o) + cells(&c) as u64 - 10) as i32;
}
)",
    );
    let env = format("SC_LIR=1 SC_LIR_OPT=0 SC_NO_TU_CACHE=1 SC_NO_EMIT_CACHE=1 SC_LIR_TEXT={}/pkg.lir", p.dir());
    let r = p.compile_flags_env("", "main.spc", env.as_str());
    assert(r.ok(), "the program builds and returns 0");
    let text = cli::read_text(format("{}/pkg.lir", p.dir()).as_str());
    let take = head_of(&text, "main__take");
    let look = head_of(&text, "main__look");
    assert(lines_with(take.as_str(), "owned p0 ") == 2 && take.contains("noalias"), text.as_str());
    assert(lines_with(look.as_str(), "owned p0 ") == 2 && look.contains("readonly"), text.as_str());
    assert(!head_of(&text, "main__cells").contains("owned"), text.as_str());
}

// The lines of `text` that hold `pat`.
fn lines_with(text: str, pat: str) u32 {
    let mut n: u32 = 0;
    for l in text.lines() {
        n += l.contains(pat) as u32;
    }
    return n;
}
