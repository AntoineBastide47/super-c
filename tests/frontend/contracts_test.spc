// Contracts: `requires`, `ensures`, `decreases` and loop `invariant` clauses, their checks, the
// prover that runs in every build, and the flags that keep the checks at run time
// (`-fcontract-checks`) or skip the proofs (`-fno-prove`).
import tests::harness as h;
import tests::cli_harness as cli;

@test
fn clauses_are_checked_like_conditions() {
    h::expect_err_msg(
        "a requires condition of another type",
        "fn f(x: u32) requires x {}\nfn main() i32 { f(1); return 0; }\n",
        "requires condition must be 'bool', found 'u32'",
    );
    h::expect_err_msg(
        "an ensures binder without a result",
        "fn f(x: u32) ensures |r| r > x {}\nfn main() i32 { f(1); return 0; }\n",
        "an 'ensures' binder names the result, and this function has no single result",
    );
    h::expect_err_msg(
        "an ensures binder of several results",
        "fn f(x: u32) (u32, u32) ensures |r| true { return x, x; }\nfn main() i32 { let (a, _) = f(1); return a as i32; }\n",
        "an 'ensures' binder names the result, and this function has no single result",
    );
    h::expect_err_msg(
        "a decreases measure of another type",
        "fn f(x: u32) u32 decreases x > 0 { return x; }\nfn main() i32 { return f(1) as i32; }\n",
        "a 'decreases' measure must be an integer, found 'bool'",
    );
    h::expect_err_msg(
        "an invariant of a loop over a slice",
        "fn f(xs: []u32) u32 {\n    let mut t: u32 = 0;\n    for x in xs invariant t >= 0 { t = x; }\n    return t;\n}\nfn main() i32 { return 0; }\n",
        "a loop's 'invariant' or 'decreases' needs a 'while', a 'loop' or a 'for' over a range written in place",
    );
    h::expect_err_msg(
        "a measure on an interface's method without a body",
        "interface I { fn g(self: &Self, n: u32) u32 decreases n; }\nfn main() i32 { return 0; }\n",
        "a 'decreases' measure needs a body: this method has none",
    );
    h::expect_err_msg(
        "an unknown name in a requires condition",
        "fn f(x: u32) requires y > 0 {}\nfn main() i32 { f(1); return 0; }\n",
        "cannot find value 'y'",
    );
    assert(h::parse_has_error("fn f(x: u32) requires x > 0;\n"), "a contract without a body");
    assert(
        h::parse_has_error("extern \"C\" {\n    fn g(x: u32) requires x > 0;\n}\n"),
        "a contract on an extern function",
    );
    assert(
        !h::parse_has_error("interface I {\n    fn g(self: &Self, x: u32) u32 requires x > 0 ensures |r| r < x;\n}\n"),
        "a contract on an interface's method",
    );
}

// The obligations the prover cannot prove, each reported where the claim fails.
@test
fn unproved_contracts_are_errors() {
    let mut b = cli::Batch::new("", "");
    b.add(
        "an ensures the result breaks",
        "fn f(x: u32) u32 ensures |r| r > x { return x; }\nfn main() i32 { return f(1) as i32; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "an operation of a function with contracts that may overflow",
        "fn f(a: u32, b: u32) u32 ensures |r| r >= a { return a + b; }\nfn main() i32 { return f(1, 2) as i32; }\n",
        "cannot prove that this operation does not overflow",
    );
    b.add(
        "a product of a call's unknown result",
        "fn fact(n: u32) u32 requires n <= 10 decreases n {\n    if n == 0 { return 1; }\n    return n * fact(n - 1);\n}\nfn main() i32 { return fact(3) as i32; }\n",
        "cannot prove that this operation does not overflow",
    );
    b.add(
        "an invariant false when the loop starts",
        "fn f(n: u32) u32 {\n    let mut k: u32 = 0;\n    while k < n invariant k == 1 { k += 1; }\n    return k;\n}\nfn main() i32 { return f(3) as i32; }\n",
        "cannot prove that this 'invariant' holds when the loop starts",
    );
    b.add(
        "an invariant that holds at the start only",
        "fn f(n: u32) u32 requires n < 100 {\n    let mut k: u32 = 0;\n    while k < n invariant k == 0 { k += 1; }\n    return k;\n}\nfn main() i32 { return f(3) as i32; }\n",
        "cannot prove that this 'invariant' holds after an iteration",
    );
    b.add(
        "a call that breaks the callee's requires",
        "fn inc(x: u32) u32 requires x < 100 { return x + 1; }\nfn main() i32 { return inc(200) as i32; }\n",
        "cannot prove the 'requires' of 'inc' at this call",
    );
    b.add(
        "a closure's call that breaks the callee's requires",
        "fn inc(x: u32) u32 requires x < 100 { return x + 1; }\nfn main() i32 {\n    let c = || inc(500);\n    return c() as i32;\n}\n",
        "cannot prove the 'requires' of 'inc' at this call",
    );
    b.add(
        "a measure that does not decrease",
        "fn spin(n: u32) u32 decreases n { return spin(n); }\nfn main() i32 { return spin(1) as i32; }\n",
        "cannot prove that the 'decreases' measure decreases at this call",
    );
    b.add(
        "a contract that prints",
        "fn noisy() bool { println(\"x\"); return true; }\nfn f(x: u32) u32 requires noisy() { return x; }\nfn main() i32 { return 0; }\n",
        "a contract must only compute its condition",
    );
    b.add(
        "a function with requires as a value",
        "fn inc(x: u32) u32 requires x < 100 { return x + 1; }\nfn main() i32 {\n    let g = inc;\n    return g(1) as i32;\n}\n",
        "a function with a 'requires' clause cannot be used as a value",
    );
    b.add(
        "a field a method call changes",
        "struct P { v: u32 }\nextend P {\n    fn bump(self: &mut P) requires self.v < 10 { self.v += 1; }\n}\nfn f() u32 ensures |r| r == 1 {\n    let mut p = P { v: 1 };\n    p.bump();\n    return p.v;\n}\nfn main() i32 { return f() as i32; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a loop measure that grows",
        "fn f(n: u32) u32 {\n    let mut k = n;\n    while k < 100 decreases k { k += 1; }\n    return k;\n}\nfn main() i32 { return f(1) as i32; }\n",
        "cannot prove that this 'decreases' measure decreases in each iteration",
    );
    b.add(
        "a loop without a measure in a function with one",
        "fn f(n: u32) u32 decreases n {\n    let mut j: u32 = 0;\n    while j < 10 { j += 1; }\n    return j;\n}\nfn main() i32 { return f(1) as i32; }\n",
        "this loop needs a 'decreases' measure: its function has one",
    );
    b.add(
        "a mutual recursion through a function without a measure",
        "fn ping(n: u32) u32 decreases n { return pong(n); }\nfn pong(n: u32) u32 {\n    if n == 0 { return 0; }\n    return ping(n - 1);\n}\nfn main() i32 { return ping(2) as i32; }\n",
        "'pong' calls back into this function and has no 'decreases' measure",
    );
    b.add(
        "a mutual recursion whose measure stays",
        "fn even(n: u32) bool decreases n {\n    if n == 0 { return true; }\n    return odd(n);\n}\nfn odd(n: u32) bool decreases n {\n    if n == 0 { return false; }\n    return even(n - 1);\n}\nfn main() i32 { return even(2) as i32; }\n",
        "cannot prove that the 'decreases' measure decreases at this call of 'odd'",
    );
    b.add(
        "a counterexample over small domains",
        "fn f(x: u8, y: u8) bool ensures |r| r { return (x ^ y) != 3; }\nfn main() i32 { return f(1, 1) as i32; }\n",
        "for example: x = 0, y = 3",
    );
    b.add(
        "a counterexample of an overflow",
        "fn f(a: u32, b: u32) u32 ensures |r| r >= a { return a + b; }\nfn main() i32 { return f(1, 2) as i32; }\n",
        "for example: a = 4294967295, b = 4294967295",
    );
    b.add(
        "a conformance's requires stronger than its interface's",
        "interface C {\n    fn get(self: &Self, k: u32) u32 requires k < 10 ensures |r| r <= k;\n}\nstruct A {}\nextend A as C {\n    fn get(self: &Self, k: u32) u32 requires k < 5 { return k; }\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'requires' from the interface's 'requires'",
    );
    b.add(
        "a conformance's result weaker than its interface's",
        "interface C {\n    fn get(self: &Self, k: u32) u32 requires k < 10 ensures |r| r <= k;\n}\nstruct A {}\nextend A as C {\n    fn get(self: &Self, k: u32) u32 { return k + 1; }\n}\nfn main() i32 { return 0; }\n",
        "cannot prove the interface's 'ensures' at this return",
    );
    b.add(
        "a call through dyn that breaks the interface's requires",
        "interface C {\n    fn get(self: &Self, k: u32) u32 requires k < 10 ensures |r| r <= k;\n}\nstruct A {}\nextend A as C {\n    fn get(self: &Self, k: u32) u32 { return k; }\n}\nfn f(x: &dyn C) u32 { return x.get(20); }\nfn main() i32 { return f(&A {}) as i32; }\n",
        "cannot prove the 'requires' of 'get' at this call",
    );
    h::expect_build_errs(b);
}

fn proved_contracts(b: &mut h::ExitBatch) {
    b.add(
        "a sum modulo a bound",
        M"(fn add_mod(a: u32, b: u32, m: u32) u32
    requires m > 0, m <= 1000, a < m, b < m
    ensures |r| r < m
{
    let s = a + b;
    return if s >= m { s - m } else { s };
}
fn main() i32 {
    return add_mod(3, 4, 5) as i32;
}
)",
        2,
    );
    b.add(
        "a counting loop and its invariants",
        M"(fn count(n: u32) u32
    ensures |r| r == n
{
    let mut acc: u32 = 0;
    for i in 0..n
        invariant i <= n
        invariant acc == i
    {
        acc += 1;
    }
    return acc;
}
fn main() i32 {
    return count(7) as i32;
}
)",
        7,
    );
    b.add(
        "a callee's ensures and a slice's length",
        M"(fn inc(x: u32) u32
    requires x < 100
    ensures |r| r == x + 1
{
    return x + 1;
}
fn twice(x: u32) u32
    requires x < 50
    ensures |r| r == x + 2
{
    return inc(inc(x));
}
fn get(xs: []u32, i: usize) u32
    requires i < xs.len()
{
    return xs[i];
}
fn first(xs: []u32) u32
    requires xs.len() > 0
{
    return get(xs, 0);
}
fn main() i32 {
    let xs: [u32; 3] = [4, 5, 6];
    let mut t: u32 = 0;
    for i in 0..10u32 {
        t = inc(i);
    }
    return (twice(3) + t + xs[0]) as i32;
}
)",
        19,
    );
    b.add(
        "a recursion with a measure and a casted difference",
        M"(fn down(n: u64) u64
    ensures |r| r == 0
    decreases n
{
    if n == 0 {
        return 0;
    }
    return down(n - 1);
}
fn gap(a: i32, b: i32) u32
    ensures |r| a == b || r > 0
{
    if a > b {
        return (a as i64 - b as i64) as u32;
    }
    return (b as i64 - a as i64) as u32;
}
fn main() i32 {
    return (down(100000) + gap(2, 9) as u64) as i32;
}
)",
        7,
    );
    b.add(
        "fields, a method through a mutable reference, arrays and their views",
        M"(struct P {
    v: u32,
    w: u32,
}
extend P {
    fn bump(self: &mut P)
        requires self.v < 10
    {
        self.v += 1;
    }
}
fn first(xs: []u32) u32
    requires xs.len() > 0
{
    return xs[0];
}
fn pick(a: [u32; 4], i: usize) u32
    requires i < 4
{
    return a[i];
}
fn field_sum(p: P) u32
    requires p.v < 100
    requires p.w < 100
    ensures |r| r < 200
{
    return p.v + p.w;
}
fn set_field() u32
    ensures |r| r == 3
{
    let mut p = P { v: 1, w: 2 };
    p.v = 3;
    return p.v;
}
fn main() i32 {
    let mut p = P { v: 1, w: 2 };
    p.bump();
    let xs: [u32; 3] = [4, 5, 6];
    return (first(xs) + pick([1, 2, 3, 4], 2) + field_sum(P { v: 1, w: 2 }) + set_field() + p.v) as i32;
}
)",
        15,
    );
    b.add(
        "bit operations over small domains, proved by enumeration",
        M"(fn low_nibble(x: u8) u8
    ensures |r| r < 16
{
    return x & 15;
}
fn parity(x: u8) bool
    ensures |r| r == ((x & 1) == 1)
{
    return x % 2 == 1;
}
fn rot(x: u8) u8
    ensures |r| r >> 1 == (x & 127)
{
    return x << 1 | x >> 7;
}
fn main() i32 {
    return (low_nibble(0x3c) as u32 + parity(3) as u32 + rot(1) as u32) as i32;
}
)",
        15,
    );
    b.add(
        "loop measures and a mutual recursion",
        M"(fn even(n: u32) bool
    decreases n
{
    if n == 0 {
        return true;
    }
    return odd(n - 1);
}
fn odd(n: u32) bool
    decreases n
{
    if n == 0 {
        return false;
    }
    return even(n - 1);
}
fn down(n: u32) u32
    decreases n
{
    let mut k = n;
    while k > 0
        decreases k
    {
        k -= 1;
    }
    for i in 0..n {
        k += 0;
    }
    return k;
}
fn main() i32 {
    return even(4) as i32 * 10 + down(5) as i32;
}
)",
        10,
    );
    b.add(
        "interface contracts through generic and dyn calls, and conformances that refine them",
        M"(interface Counter {
    fn get(self: &Self, k: u32) u32
        requires k < 10
        ensures |r| r <= k;
}
struct A {
    v: u32,
}
extend A as Counter {
    fn get(self: &Self, k: u32) u32 {
        return k;
    }
}
struct B {
    v: u32,
}
extend B as Counter {
    fn get(self: &Self, k: u32) u32
        requires k < 20
        ensures |r| r == 0
    {
        return 0;
    }
}
fn via_generic<T: Counter>(x: &T) u32
    ensures |r| r <= 3
{
    return x.get(3);
}
fn via_dyn(x: &dyn Counter) u32
    ensures |r| r <= 5
{
    return x.get(5);
}
fn main() i32 {
    let a = A { v: 0 };
    let b = B { v: 0 };
    return (via_generic(&a) + via_dyn(&a) + via_generic(&b) + via_dyn(&b)) as i32;
}
)",
        8,
    );
}

@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    proved_contracts(&mut b);
    b.run();
}

// A build checks no contract at run time unless `-fcontract-checks` asks: with the proofs skipped,
// a false `ensures` returns its value in one build and traps in the other.
@test
fn contract_checks_run_on_request() {
    let src = "fn f(x: u32) u32 ensures |r| r > x { return x; }\nfn main() i32 { return f(3) as i32; }\n";
    let plain = h::diff_build(src, ["-fno-prove"]);
    assert(plain.built, "a build without proofs accepts a false contract");
    assert_eq(h::diff_run(&plain, "").exit, 3);
    let checked = h::diff_build(src, ["-fno-prove", "-fcontract-checks"]);
    assert(checked.built, "a build with checks accepts it too");
    let r = h::diff_run(&checked, "");
    assert(r.exit != 0 && r.err.contains("assertion failed: `ensures |r| r > x`"), "the ensures check traps");
}

// The proof record of a build tree: a later build takes the proofs of each unchanged module from it,
// an edit of a module proves it and its importers again, and a failed proof is never recorded.
@test
fn proofs_are_recorded_per_module() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/lib.spc", "pub fn inc(x: u32) u32 requires x < 100 ensures |r| r == x + 1 { return x + 1; }\n");
    p.mkfile(
        "src/main.spc",
        "import lib;\nfn twice(x: u32) u32 requires x < 50 ensures |r| r == x + 2 { return lib::inc(lib::inc(x)); }\nfn main() i32 { return twice(3) as i32; }\n",
    );
    let root = p.dir();
    let first = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build");
    assert(first.ok() && first.out_has(", 0 from the proof record"), "the first build proves every module");
    // An unchanged build is skipped whole; a comment changes the root module only.
    p.mkfile(
        "src/main.spc",
        "import lib;\n// twice\nfn twice(x: u32) u32 requires x < 50 ensures |r| r == x + 2 { return lib::inc(lib::inc(x)); }\nfn main() i32 { return twice(3) as i32; }\n",
    );
    let again = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build");
    assert(again.ok() && again.out_has("prove: 1 to prove"), "the other modules take their proofs from the record");
    p.mkfile(
        "src/lib.spc",
        "pub fn inc(x: u32) u32 requires x < 100 ensures |r| r == x + 1 || x == 7 { return x + 1; }\n",
    );
    let edited = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build");
    assert(edited.exit != 0 && edited.out_has("prove: 2 to prove"), "the edited module and its importer prove again");
    assert(edited.out_has("cannot prove this 'ensures' clause"), "the importer's proof fails on the weaker ensures");
    let still = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build");
    assert(still.exit != 0 && still.out_has("prove: 1 to prove"), "only the module whose proof failed proves again");
    assert(still.out_has("cannot prove this 'ensures' clause"), "a failed proof is not recorded");
}

// The proofs run on several workers and report as one: the same diagnostics, in the same order.
@test
fn parallel_proofs_report_like_one() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "fn a(x: u32) u32 ensures |r| r > x { return x; }\nfn b(x: u32) u32 requires x < 9 { return x; }\nfn c(x: u8) bool ensures |r| r { return x != 4; }\nfn main() i32 { return (a(1) + b(20) + c(2) as u32) as i32; }\n",
    );
    let root = p.dir();
    let one = cli::superc_in(root, "build --jobs=1");
    let many = cli::superc_in(root, "build --jobs=4");
    assert(one.exit != 0 && one.out_has("for example: x = 4"), "the serial build reports the failed proofs");
    assert(many.exit != 0 && one.text() == many.text(), "the parallel build reports the same text");
}
