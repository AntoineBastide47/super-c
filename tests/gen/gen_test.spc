// The seeded program generator (tests/gen): a fixed seed list per model, a planted defect the scalar
// model must find and reduce, and the long randomized run (`super-c command gen`).
import tests::gen::driver as gen;
import tests::gen::scalar as scalar;
import tests::gen::loops as loops;
import tests::gen::vector as vector;
import tests::gen::math as math;
import tests::cli_harness as cli;
import driver::util as dutil;
import stdlib;

fn expect_seeds<M: gen::Model + Clone>(m: &mut M, seeds: []u64) {
    for seed in seeds {
        let r = gen::run_seed(m, seed);
        if r.len() != 0 {
            eprintln("{}", r.as_str());
        }
        assert(r.len() == 0, "a fixed generator seed fails");
    }
}

@test
fn gen_scalar_seeds() {
    let mut m = scalar::scalar_model(6, 3);
    expect_seeds(&mut m, [1, 2, 3]);
}

@test
fn gen_loop_seeds() {
    let mut m = loops::loop_model(6);
    expect_seeds(&mut m, [1, 2, 3]);
}

@test
fn gen_vector_seeds() {
    let mut m = vector::vector_model(8);
    expect_seeds(&mut m, [1, 2, 3]);
}

// One seed per test: each compiles every math kernel (on x86 unoptimized, with the sanitizer).
@test(timeout = 300)
fn gen_math_seed_1() {
    let mut m = math::math_model(6);
    expect_seeds(&mut m, [1]);
}

@test(timeout = 300)
fn gen_math_seed_2() {
    let mut m = math::math_model(6);
    expect_seeds(&mut m, [2]);
}

@test(timeout = 300)
fn gen_math_seed_3() {
    let mut m = math::math_model(6);
    expect_seeds(&mut m, [3]);
}

// The runtime's overflow checks compiled out (SC_ARITH_WRAP under the checking `debug` profile): the
// constants still trap, the run time wraps. The generator finds it, names the seed and reduces the
// program to the one overflowing case.
@test
fn gen_finds_planted_defect() {
    let _c = cli::set_env("SC_NATIVE", "0"); // the planted defect is a C flag: the C backend's
    let mut m = scalar::scalar_model(4, 2);
    let mut plant = String::from_str("--cstd=");
    plant.push_str(unsafe str::from_cstr(cli::cstd()));
    plant.push_str(" -DSC_ARITH_WRAP");
    m.opts.push(plant);
    let r = gen::run_seed(&mut m, 14); // seed 14 draws an overflowing case (6 reduction checks)
    eprintln("{}", r.as_str());
    assert(r.contains("model 'scalar' seed 14 fails oracle 0"), "the seed and the oracle are named");
    assert(r.contains("const:    trap: arithmetic overflow"), "the constant traps");
    assert(r.contains("run time: value"), "the run time wraps");
    assert(r.contains("const PARITY_C0:"), "the reduced program keeps one case");
    assert(!r.contains("PARITY_C1"), "the reduced program drops the other cases");
    assert_eq(m.roots.len(), 1);
    let t = r.as_str();
    let ex = t.slice(t.find("const PARITY_C0:") as usize, t.len());
    assert(count_leaves(ex.slice(0, ex.find("\n") as usize)) <= 2, "the reduced expression is at most one operator");
}

// The `opq::<` inputs of a generated expression.
const fn count_leaves(text: str) usize {
    let mut n: usize = 0;
    let mut rest = text;
    loop {
        let k = rest.find("opq::<");
        if k < 0 {
            return n;
        }
        n += 1;
        rest = rest.slice(k as usize + 6, rest.len());
    }
}

fn env_u64(name: str, dflt: u64) u64 {
    let v = stdlib::getenv(name);
    if v == null || unsafe *v == 0 as char {
        return dflt;
    }
    let p = unsafe str::from_cstr(v).parse_u64();
    assert(p.is_some(), "a generator variable is not a number");
    return p.unwrap();
}

// The long randomized run: SC_GEN_RUNS seeds from SC_GEN_SEED (default: the clock) for the model
// SC_GEN_MODEL names (default: every model). Without SC_GEN_RUNS it does nothing, so the normal suite
// skips it; `super-c command gen` sets it.
@test
fn gen_random_run() {
    let runs = env_u64("SC_GEN_RUNS", 0);
    if runs == 0 {
        return;
    }
    let base = env_u64("SC_GEN_SEED", dutil::ticks_ms() as u64);
    let only = stdlib::getenv("SC_GEN_MODEL");
    let model = if only == null {
        "";
    } else {
        unsafe str::from_cstr(only);
    };
    eprintln("gen: {} runs from seed {}", runs, base);
    let mut failures: u64 = 0;
    let mut sm = scalar::scalar_model(6, 3);
    let mut lm = loops::loop_model(6);
    let mut vm = vector::vector_model(8);
    let mut mm = math::math_model(6);
    for i in 0..runs {
        let seed = base + i;
        if model.len() == 0 || model == "scalar" {
            let r = gen::run_seed(&mut sm, seed);
            if r.len() != 0 {
                eprintln("{}", r.as_str());
                failures += 1;
            }
        }
        if model.len() == 0 || model == "loops" {
            let r = gen::run_seed(&mut lm, seed);
            if r.len() != 0 {
                eprintln("{}", r.as_str());
                failures += 1;
            }
        }
        if model.len() == 0 || model == "vector" {
            let r = gen::run_seed(&mut vm, seed);
            if r.len() != 0 {
                eprintln("{}", r.as_str());
                failures += 1;
            }
        }
        if model.len() == 0 || model == "math" {
            let r = gen::run_seed(&mut mm, seed);
            if r.len() != 0 {
                eprintln("{}", r.as_str());
                failures += 1;
            }
        }
    }
    assert_eq(failures, 0);
}
