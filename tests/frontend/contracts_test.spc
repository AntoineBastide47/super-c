// Contracts: `requires`, `ensures`, `decreases` and loop `invariant` clauses, their checks, the
// prover that runs in every build, `@prove_exhaustive` (a proof by evaluation of every input), ghost
// code (`spec fn`, `lemma`, `assert .. by`, `int` and `nat`), and the flags that keep the checks at run
// time (`-fcontract-checks`) or skip the proofs (`-fno-prove`).
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
    h::expect_err_msg(
        "a proof by evaluation of a struct",
        "@prove_exhaustive\nstruct S {\n    x: u8,\n}\nfn main() i32 { return 0; }\n",
        "'@prove_exhaustive' may only be applied to a function with a body",
    );
    assert(h::parse_has_error("fn f(x: u32) requires x > 0;\n"), "a contract without a body");
    assert(
        !h::parse_has_error("extern \"C\" {\n    @trusted\n    fn g(x: u32) requires x > 0;\n}\n"),
        "a contract on an extern function",
    );
    assert(
        !h::parse_has_error("interface I {\n    fn g(self: &Self, x: u32) u32 requires x > 0 ensures |r| r < x;\n}\n"),
        "a contract on an interface's method",
    );
}

// Ghost code: only it names `int` and `nat` or calls a spec function, a lemma call is a statement, and
// an `assert .. by` block cannot leave.
@test
fn ghost_code_is_checked() {
    assert(h::parse_has_error("lemma l(x: u32) u32 {}\n"), "a lemma with a return type");
    assert(
        !h::parse_has_error("spec fn s(x: nat) int { return x; }\nlemma l(x: nat) ensures s(x) >= 0 {}\n"),
        "a spec function and a lemma",
    );
    h::expect_err_msg(
        "an int parameter of a function",
        "fn f(x: int) {}\nfn main() i32 { return 0; }\n",
        "'int' is a specification type: only ghost code can name it",
    );
    h::expect_err_msg(
        "a nat local of a function",
        "fn main() i32 {\n    let x: nat = 1;\n    return 0;\n}\n",
        "'nat' is a specification type: only ghost code can name it",
    );
    h::expect_err_msg(
        "a spec function called by a function",
        "spec fn s(x: u32) u32 { return x; }\nfn main() i32 { return s(1) as i32; }\n",
        "a spec function can only be called from ghost code",
    );
    h::expect_err_msg(
        "a lemma call as a value",
        "lemma l() {}\nfn main() i32 {\n    let x = l();\n    return 0;\n}\n",
        "a lemma call is a statement of its own: it has no value",
    );
    h::expect_err_msg(
        "a return in an assert-by block",
        "fn main() i32 {\n    assert true by { return 1; };\n    return 0;\n}\n",
        "an 'assert .. by' block cannot return: ghost code never runs",
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
        "a trusted extern function's requires at a call",
        "extern \"C\" {\n    @trusted\n    fn labs(x: i64) i64 requires x > 0 ensures |r| r == x;\n}\nfn f(a: i64) i64 { return unsafe labs(a); }\nfn main() i32 { return f(1) as i32 - 1; }\n",
        "cannot prove the 'requires' of 'labs' at this call",
    );
    b.add(
        "a shared borrow of a cell's holder",
        "import std::mem::cell;\nstruct S { pub c: cell::Cell<u32> }\nfn bump(s: &S) {\n    s.c.set(s.c.get() + 1);\n}\nfn f() u32 ensures |r| r == 1 {\n    let s = S { c: cell::Cell::<u32>::new(1) };\n    bump(&s);\n    return s.c.get();\n}\nfn main() i32 { return f() as i32; }\n",
        "cannot prove this 'ensures' clause",
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
        "for example: a = 4294967295, b = 1",
    );
    // The arithmetic's model is a candidate: no end of `x`'s range, 0 or 1 breaks the clause.
    b.add(
        "a counterexample from the arithmetic's model",
        "fn f(x: u64) u64 requires x > 1000 ensures |r| r != 5000 { return x; }\nfn main() i32 { return (f(2000) - 2000) as i32; }\n",
        "for example: x = 5000",
    );
    // `x <= y` gives no model where the remainders must agree: the combination merges nothing.
    b.add(
        "operands the rows do not make equal",
        "fn f(x: u64, y: u64) bool requires x <= y ensures |r| r { return x % 7 == y % 7; }\nfn main() i32 { return f(9, 9) as i32 - 1; }\n",
        "cannot prove this 'ensures' clause",
    );
    // `k < 4` leaves `k` negative: a function with contracts proves each check of its body.
    b.add(
        "a signed index the requires leave negative",
        "fn at(a: [u32; 4], k: i32) u32 requires k < 4 { return a[k]; }\nfn main() i32 { return at([1, 2, 3, 4], 3) as i32 - 4; }\n",
        "for example: k = -1",
    );
    // `u128::MAX + 1` overflows: the counterexample is a 128-bit value.
    b.add(
        "a wide integer's overflow",
        "fn f(a: u128, b: u128) u128 ensures |r| r >= a { return a + b; }\nfn main() i32 { return f(1, 2) as i32 - 3; }\n",
        "for example: a = 340282366920938463463374607431768211455, b = 1",
    );
    // `k < 4` leaves `k` free: no product rows, and `999 * 3` breaks the clause.
    b.add(
        "a product of an operand the requires leave free",
        "fn f(a: u64, k: u64) u64 requires a < 1000, k < 4 ensures |r| r < 2000 { return a * k; }\nfn main() i32 { return f(1, 1) as i32 - 1; }\n",
        "cannot prove this 'ensures' clause",
    );
    // A truncated remainder takes the dividend's sign: `-5 % 13` is -5, `21 % 13` is 8.
    b.add(
        "remainders across zero",
        "fn f(x: i64, y: i64) bool requires x > -1000, x < 1000, y == x + 26 ensures |r| r { return x % 13 == y % 13; }\nfn main() i32 { return f(1, 27) as i32 - 1; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a wide remainder's counterexample",
        "fn f(a: u128) u128 ensures |r| r < 8 { return a % 16; }\nfn main() i32 { return f(3) as i32 - 3; }\n",
        "for example: a = 8",
    );
    b.add(
        "a call over different arguments",
        "const fn h(x: u32) u32 { return x / 2; }\nfn f(a: u32, b: u32) bool requires b < 100, a == b + 1 ensures |r| r { return h(a) == h(b); }\nfn main() i32 { return f(3, 2) as i32 - 1; }\n",
        "cannot prove this 'ensures' clause",
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
    b.add(
        "a bit operation's counterexample from the bits' model",
        "fn f(x: u32, y: u32) u32 ensures |r| r == x { return x ^ y; }\nfn main() i32 { return f(1, 0) as i32 - 1; }\n",
        "for example: x = 0, y = 1",
    );
    b.add(
        "a wrapping sum past the maximum",
        "fn f(x: u32) u32 ensures |r| r > x { return x.wrapping_add(1); }\nfn main() i32 { return f(1) as i32 - 2; }\n",
        "for example: x = 4294967295",
    );
    b.add(
        "a rotation the other rotation does not undo",
        "fn f(x: u32, n: u32) u32 ensures |r| r == x { return x.rotate_left(n).rotate_left(n); }\nfn main() i32 { return f(1, 0) as i32 - 1; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "an index past a view's length in a function with contracts",
        "fn f(v: []u8) u8 requires v.len() == 1 { return v[5]; }\nfn main() i32 { return 0; }\n",
        "cannot prove that this index is in bounds",
    );
    b.add(
        "a loop that lends a local to a call keeps none of its values",
        "fn put(v: &mut Vector<u8>)\n    requires v.len() < 100\n    ensures v.len() == old(v.len()) + 1\n{\n    v.push(1);\n}\nfn f() usize\n    ensures |r| r == 0\n{\n    let mut v = Vector::<u8>::new();\n    for i in 0usize..3\n        invariant i <= 3\n    {\n        if v.len() < 50 {\n            put(&mut v);\n        }\n    }\n    return v.len();\n}\nfn main() i32 {\n    return f() as i32;\n}\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a member lent to a call holds the callee's value",
        "import std::spec::seq as *;\nstruct P {\n    v: Vector<u8>,\n}\nfn put(v: &mut Vector<u8>) requires v.len() < 100 ensures v.view() == old(v.view()).push(1) {\n    v.push(1);\n}\nfn f() usize ensures |r| r == 0 {\n    let mut q = P { v: Vector::<u8>::new() };\n    put(&mut q.v);\n    return q.v.len();\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "an instance at a deep trigger that does not give the claim",
        "@trusted\nspec fn f(x: int) int;\n@trusted\nspec fn g(x: int) int;\nlemma deep(a: int) requires forall k in 0 as int..10 { f(g(k) + 1) >= 3 } requires 0 <= a && a < 10 ensures f(g(a) + 1) >= 4 {}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a product's monotonicity without the factor's sign",
        "lemma mono(a: int, b: int, c: int) requires a <= c ensures a * b <= c * b {}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "an insertion past a vector's end in a function with contracts",
        "fn f(v: &mut Vector<u8>) requires v.len() == 1 {\n    v.insert(3, 0);\n}\nfn main() i32 { return 0; }\n",
        "cannot prove that this index is in bounds",
    );
    b.add(
        "a write through a reborrow of the parameter whose view the ensures reads",
        "import std::spec::seq as *;\nfn f(a: []mut u8) requires a.len() == 3 ensures a.view()[1] == 5 {\n    a[1] = 5;\n    let s = &mut a[0..3];\n    s[1] = 0;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a range past a view's length in a function with contracts",
        "fn f(v: []u8) u8 requires v.len() == 4 { let s = &v[1..9]; return s[0]; }\nfn main() i32 { return 0; }\n",
        "cannot prove that this index is in bounds",
    );
    b.add(
        "a method that breaks its struct's invariant",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nextend C {\n    fn bump(self: &mut C) {\n        self.n += 1;\n    }\n}\nfn main() i32 { return 0; }\n",
        "cannot prove the invariant of 'C' at this return",
    );
    b.add(
        "a literal that breaks its struct's invariant",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nfn make() C {\n    return C { n: 5, max: 3 };\n}\nfn main() i32 { return make().n as i32; }\n",
        "cannot prove the invariant of 'C' at this return",
    );
    b.add(
        "a call that receives a value whose invariant is broken",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nfn look(c: &C) {}\nfn f(c: &mut C) {\n    c.n = c.max + 1;\n    look(c);\n    c.n = 0;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove the invariant of 'C' at this call",
    );
    b.add(
        "an operation that may panic while an invariant is broken",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nfn f(c: &mut C, d: u32) u32 {\n    c.n = c.max + 1;\n    let q = 10 / d;\n    c.n = 0;\n    return q;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove the invariant of 'C' where this operation may panic",
    );
    b.add(
        "an index past an owned block",
        "import std::spec::seq as *;\nstruct B {\n    @owned\n    p: *mut u32,\n    cap: usize,\n}\nfn f(b: &mut B) requires block(b.p).len() >= 2 {\n    unsafe b.p[2] = 1;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove that this index is inside the block of the '@owned' field",
    );
    b.add(
        "a write through a copy of an owned field",
        "import std::spec::seq as *;\nstruct B {\n    @owned\n    p: *mut u32,\n    cap: usize,\n}\nfn f(b: &mut B, x: u32) requires block(b.p).len() >= 1 ensures block(b.p)[0] == x {\n    unsafe b.p[0] = x;\n    let q = b.p;\n    unsafe q[0] = 0;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "another pointer stored in an owned field",
        "import std::spec::seq as *;\nstruct B {\n    @owned\n    p: *mut u32,\n    cap: usize,\n}\nfn f(b: &mut B, q: *mut u32) requires block(b.p).len() >= 1 ensures block(b.p).len() >= 1 {\n    b.p = q;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a new element of a reallocated block",
        "import std::spec::seq as *;\nstruct B {\n    @owned\n    p: *mut u32,\n    cap: usize,\n}\nfn f(b: &mut B, x: u32) requires block(b.p).len() == b.cap as nat && b.cap > 0 && b.cap < 1000 ensures block(b.p)[old(b.cap) as int] == x {\n    unsafe b.p[0] = x;\n    let mut g = Global {};\n    b.p = unsafe g.realloc(b.p, b.cap * 4, b.cap * 8, 4) as *mut u32;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a call where the callee's 'panics if' may hold",
        "fn at(xs: []u32, i: usize) u32\n    panics if i >= xs.len()\n{\n    if i >= xs.len() {\n        panic(\"at: out of bounds\");\n    }\n    return xs[i];\n}\nfn bad(xs: []u32) u32\n    requires xs.len() > 2\n{\n    return at(xs, 5);\n}\nfn main() i32 { return 0; }\n",
        "cannot prove that 'at' does not panic at this call",
    );
    b.add(
        "a panic where the 'panics if' is false",
        "fn f(x: u32) u32\n    panics if x > 10\n{\n    if x > 5 {\n        panic(\"no\");\n    }\n    return x;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove that this panic is unreachable",
    );
    b.add(
        "an overflow where the 'panics if' is false",
        "fn h(x: u8) u8\n    panics if x == 255\n{\n    return x + 2;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove that this operation does not overflow",
    );
    b.add(
        "a conformance that may panic where its interface does not",
        "interface C {\n    fn get(self: &Self, k: u32) u32 panics if k > 9;\n}\nstruct A {}\nextend A as C {\n    fn get(self: &Self, k: u32) u32\n        panics if k > 5\n    {\n        if k > 5 {\n            panic(\"big\");\n        }\n        return k;\n    }\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'panics if' from the interface's 'panics if'",
    );
    b.add(
        "an invariant broken where an operation may panic under the 'panics if'",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nextend C {\n    fn reset(self: &mut C, k: u32)\n        panics if k == 0\n    {\n        self.n = 1;\n        self.max = 0;\n        let q = 10 / k;\n        self.n = q - q;\n    }\n}\nfn main() i32 { return 0; }\n",
        "cannot prove the invariant of 'C' where this operation may panic",
    );
    b.add(
        "an invariant the check at a call could not prove is not assumed after it",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\n\nfn other()\n    ensures true\n{\n    let _x = 1;\n}\n\nfn bad() u32\n    ensures |r| r == 1\n{\n    let mut c = C { n: 0, max: 5 };\n    c.n = 100;\n    other();\n    c.n = 0;\n    return 2;\n}\n\nfn main() i32 {\n    return bad() as i32 - 2;\n}\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a receiver whose borrow a returned reference keeps",
        "struct P {\n    x: u32,\n    v: Vector<u32>,\n}\nextend P {\n    fn xr(self: &mut P) &mut u32 {\n        return &mut self.x;\n    }\n}\nfn other() {\n    print(\"\");\n}\nfn lent() u32 ensures |r| r == 1 {\n    let mut p = P { x: 1, v: Vector::<u32>::new() };\n    let r = p.xr();\n    *r = 7;\n    other();\n    return p.x;\n}\nfn main() i32 { return 0; }\n",
        "cannot prove this 'ensures' clause",
    );
    b.add(
        "a write through an alias of a raw pointer",
        "fn f(p: *mut u32, q: *mut u32) ensures true {\n    unsafe {\n        p[0] = 1;\n        q[0] = 2;\n        assert(p[0] == 1);\n    }\n}\nfn main() i32 { return 0; }\n",
        "cannot prove that this check holds",
    );
    h::expect_build_errs(b);
}

// Ghost code never runs: each of its checks is an obligation, it must end, and it assumes only the
// `ensures` of a callee that ends.
@test
fn unproved_ghost_code_is_an_error() {
    let mut b = cli::Batch::new("", "fn main() i32 {\n    return 0;\n}\n");
    b.add("a false lemma", "lemma l(x: u32) ensures x > 5 {}\n", "cannot prove this 'ensures' clause");
    b.add(
        "a lemma that calls itself without a measure",
        "lemma l(x: u32) ensures false { l(x); }\n",
        "this call recurses: a spec function or a lemma that does needs a 'decreases' measure",
    );
    b.add(
        "a lemma with a loop without a measure",
        "lemma l(x: u32) {\n    let mut k: u32 = 0;\n    while k < x { k += 1; }\n}\n",
        "this loop needs a 'decreases' measure: ghost code must end",
    );
    b.add(
        "a spec function with a loop",
        "spec fn s(x: u32) u32 {\n    let mut k: u32 = 0;\n    while k < x decreases x - k { k += 1; }\n    return k;\n}\n",
        "a spec function cannot loop: state it by recursion",
    );
    b.add(
        "ghost code that writes a variable",
        "fn f(x: u32) u32 {\n    let mut y = x;\n    assert true by { y = 0; };\n    return y;\n}\n",
        "ghost code must only compute its condition",
    );
    b.add(
        "an index of ghost code that may be out of bounds",
        "lemma l(a: [u32; 2], i: usize) {\n    let x = a[i];\n}\n",
        "cannot prove that this check of ghost code holds",
    );
    b.add(
        "a false assert-by",
        "fn f(x: u32) u32 {\n    assert x > 5 by {};\n    return x;\n}\n",
        "cannot prove this 'assert'",
    );
    b.add("a panic in ghost code", "lemma l() { panic(\"no\"); }\n", "cannot prove that ghost code does not panic here");
    b.add(
        "a nat below 0",
        "spec fn d(n: nat) nat { return n - 1; }\n",
        "cannot prove that this operation does not overflow",
    );
    b.add(
        "a value below 0 as a nat",
        "lemma l(x: i32) ensures x as nat >= 0 {}\n",
        "cannot prove that this value is at least 0",
    );
    b.add(
        "the ensures of a callee that may not end",
        "const fn lie() bool ensures |r| false {\n    while true {}\n    return true;\n}\nlemma l() ensures false { let _ = lie(); }\n",
        "cannot prove this 'ensures' clause",
    );
    h::expect_build_errs(b);
}

// `==>`, the quantifiers, `old`, ghost variables and `@trusted` are ghost code, each in its place.
@test
fn spec_syntax_is_checked() {
    h::expect_err_msg(
        "an implication a build runs",
        "fn f(x: u32) bool { return x > 1 ==> x > 0; }\nfn main() i32 { return 0; }\n",
        "'==>' is valid only in ghost code",
    );
    h::expect_err_msg(
        "a quantifier a build runs",
        "fn f(x: u32) bool { return forall i in 0..x { i < x }; }\nfn main() i32 { return 0; }\n",
        "'forall' is valid only in ghost code",
    );
    h::expect_err_msg(
        "a quantifier over a collection",
        "fn f(xs: []u32) bool requires exists x in xs { x > 0 } { return true; }\nfn main() i32 { return 0; }\n",
        "'exists' ranges over 'a..b' or 'a..=b', a range with both ends",
    );
    h::expect_err_msg(
        "a struct invariant that reads no value",
        "struct S\n    invariant true\n{\n    n: u32,\n}\nfn main() i32 { return 0; }\n",
        "a struct's invariant states a fact of its value: it reads 'self'",
    );
    h::expect_err_msg(
        "a union with an invariant",
        "union U\n    invariant self.a > 0\n{\n    a: u32,\n    b: i32,\n}\nfn main() i32 { return 0; }\n",
        "a union has no invariant",
    );
    h::expect_err_msg(
        "an invariant over a public field",
        "struct S\n    invariant self.a < 10\n{\n    pub a: u32,\n}\nfn main() i32 { return 0; }\n",
        "an invariant reads only fields private to its file: code in another file can write 'a'",
    );
    h::expect_err_msg(
        "an invariant over a field a shared reference may change",
        "struct S<T>\n    invariant self.x == self.x\n{\n    x: T,\n}\nfn main() i32 { return 0; }\n",
        "an invariant cannot read 'x': a shared reference can change it (it may hold an 'UnsafeCell')",
    );
    h::expect_err_msg(
        "a spec function with a panics clause",
        "spec fn g(x: int) int panics if x < 0 { return x; }\nfn main() i32 { return 0; }\n",
        "ghost code never panics: a spec function or a lemma has no 'panics if'",
    );
    h::expect_err_msg(
        "old in a panics clause",
        "fn f(x: u32) u32 panics if old(x) > 3 { return x; }\nfn main() i32 { return 0; }\n",
        "'old' is valid only in a function's 'ensures', its loops' 'invariant's and its ghost code",
    );
    h::expect_err_msg(
        "old in a requires",
        "fn f(x: u32) requires old(x) > 0 {}\nfn main() i32 { return 0; }\n",
        "'old' is valid only in a function's 'ensures', its loops' 'invariant's and its ghost code",
    );
    h::expect_err_msg(
        "old in a lemma",
        "lemma l(a: int) ensures old(a) == a {}\nfn main() i32 { return 0; }\n",
        "'old' is valid only in a function's 'ensures', its loops' 'invariant's and its ghost code",
    );
    h::expect_err_msg(
        "a ghost variable read by code a build runs",
        "fn f() u32 {\n    ghost let g: u32 = 1;\n    return g;\n}\nfn main() i32 { return 0; }\n",
        "'g' is a ghost variable: only ghost code can read or write it",
    );
    h::expect_err_msg(
        "a ghost assignment to a variable a build runs",
        "fn f() u32 {\n    let mut z: u32 = 0;\n    ghost z = 1;\n    return z;\n}\nfn main() i32 { return 0; }\n",
        "a 'ghost' assignment writes only a ghost variable ('ghost let')",
    );
    h::expect_err_msg(
        "a ghost variable that owns memory",
        "fn f(v: Vector<u32>) {\n    ghost let w = v;\n}\nfn main() i32 { return 0; }\n",
        "a ghost variable's type must be 'Copy': 'Vector<u32, Global>' is not",
    );
    h::expect_err_msg(
        "a spec function without a body or @trusted",
        "spec fn s(a: int) int;\nfn main() i32 { return 0; }\n",
        "a spec function or a lemma without a body must be '@trusted': no proof checks its contracts",
    );
    h::expect_err_msg(
        "an extern function's contract without @trusted",
        "extern \"C\" {\n    fn g(x: u32) u32 requires x > 0;\n}\nfn main() i32 { return 0; }\n",
        "an extern function with contracts must be '@trusted': no proof checks them",
    );
    h::expect_err_msg(
        "@trusted on a function with a body",
        "@trusted\nfn t(a: u32) u32 { return a; }\nfn main() i32 { return 0; }\n",
        "'@trusted' marks a spec function or a lemma without a body",
    );
}

// What the quantifiers, `old`, ghost variables, `Seq` and `view()` do not give is an error.
@test
fn unproved_spec_syntax_is_an_error() {
    let mut b = cli::Batch::new("import std::spec::seq as *;\n", "fn main() i32 {\n    return 0;\n}\n");
    b.add_at(
        "a forall over fewer indexes than the read",
        "fn f(xs: []u32, i: usize) u32\n    requires i < xs.len()\n    requires forall k in 0..i { xs[k] > 0 }\n    ensures |r| r > 0\n{\n    return xs[i];\n}\n",
        "cannot prove this 'ensures' clause",
        "5:17",
    );
    b.add_at(
        "an exists no index gives",
        "fn f(xs: []u32) bool\n    requires xs.len() > 0\n    ensures |r| exists k in 0..xs.len() { xs[k] == 7 }\n{\n    return true;\n}\n",
        "cannot prove this 'ensures' clause",
        "4:17",
    );
    b.add_at(
        "an invariant forall the loop breaks",
        "fn f(xs: []mut u32) {\n    for i in 0..xs.len()\n        invariant forall k in 0..i { xs.view()[k as int] == 0 }\n    {\n        xs[i] = 1;\n    }\n}\n",
        "cannot prove that this 'invariant' holds after an iteration",
        "4:19",
    );
    b.add_at(
        "an old value the body does not keep",
        "fn bump(x: &mut u32)\n    requires *x < 100\n    ensures *x == old(*x) + 1\n{\n    *x += 2;\n}\n",
        "cannot prove this 'ensures' clause",
        "4:13",
    );
    b.add_at(
        "a push that keeps the view",
        "fn f(v: &mut Vector<u32>, x: u32)\n    ensures v.view() == old(v.view())\n{\n    v.push(x);\n}\n",
        "cannot prove this 'ensures' clause",
        "3:13",
    );
    b.add_at(
        "a pop that keeps the length",
        "fn f(v: &mut Vector<u32>)\n    ensures v.view().len() == old(v.view()).len()\n{\n    let _ = v.pop();\n}\n",
        "cannot prove this 'ensures' clause",
        "3:13",
    );
    b.add_at(
        "two sequences of one length",
        "fn f(s: Seq<u32>, t: Seq<u32>) bool\n    requires s.len() == t.len()\n    ensures |r| s == t\n{\n    return true;\n}\n",
        "cannot prove this 'ensures' clause",
        "4:17",
    );
    b.add_at(
        "a two-byte character as one byte",
        "fn f(s: &mut String)\n    ensures s.view().len() == old(s.view()).len() + 1\n{\n    s.push('\u{e9}');\n}\n",
        "cannot prove this 'ensures' clause",
        "3:13",
    );
    b.add_at(
        "more than a trusted function's ensures",
        "@trusted\nspec fn ax(x: int) int\n    ensures |r| r > x;\nfn f(x: u32) bool\n    ensures |r| ax(x as int) > x as int + 1\n{\n    return true;\n}\n",
        "cannot prove this 'ensures' clause",
        "6:17",
    );
    b.add_at(
        "another element of a generic spec function's result",
        "fn f(s: Seq<u32>) bool\n    requires s.len() == 3\n    ensures |r| s.skip(1)[0] == s[0]\n{\n    return true;\n}\n",
        "cannot prove this 'ensures' clause",
        "4:17",
    );
    b.add_at(
        "another value of a generic spec function",
        "spec fn idf<U>(x: U) U {\n    return x;\n}\nfn f() bool\n    ensures |r| idf::<u32>(3) == 4\n{\n    return true;\n}\n",
        "cannot prove this 'ensures' clause",
        "6:17",
    );
    b.add_at(
        "a program's function named like a vector's constructor",
        "fn new(x: u32) Vector<u32> {\n    let mut v = Vector::<u32>::new();\n    v.push(x);\n    return v;\n}\nfn f() bool\n    ensures |r| r\n{\n    let v = new(3);\n    return v.len() == 0;\n}\n",
        "cannot prove this 'ensures' clause",
        "8:17",
    );
    h::expect_build_errs(b);
}

fn proved_contracts(b: &mut h::ExitBatch) {
    // A clause's `const fn` call through a `&mut` parameter (`c.get()`) reads the caller's value at the
    // call; a call that only reads leaves the parameter's target as it was (`old(c.get())`).
    b.add(
        "a const fn of a mutable parameter in clauses",
        M"(struct C { n: u32 }
extend C {
    const fn get(self: &C) u32 ensures |r| r == self.n { return self.n; }
    fn need(self: &mut C) requires self.n < u32::MAX { self.n += 1; }
}
fn f(c: &mut C)
    requires c.get() < u32::MAX
    ensures old(c.get()) < u32::MAX
{
    c.need();
}
fn g(c: &mut C) u32 requires c.get() < u32::MAX {
    return 1;
}
fn main() i32 {
    let mut c = C { n: 0 };
    let mut d = C { n: 5 };
    let k = g(&mut d);
    f(&mut c);
    return (c.n + k) as i32;
}
)",
        2,
    );
    // A trusted extern function's `ensures` holds at its calls; a `@noreturn` one ends the path.
    b.add(
        "trusted extern contracts",
        M"(extern "C" {
    @trusted
    fn llabs(x: i64) i64 requires x > -1000, x < 1000 ensures |r| r >= 0 && r < 1000;
    @noreturn
    fn abort() void;
}
fn small(a: i64) u8 requires a > -1000, a < 1000 ensures |r| r < 250 {
    let k = unsafe llabs(a);
    if k >= 250 {
        unsafe abort();
    }
    return k as u8;
}
fn main() i32 {
    return small(-7);
}
)",
        7,
    );
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

// `@prove_exhaustive`: each function's runs over all its inputs hold, so the build proves it and runs.
fn exhaustive_proofs(b: &mut h::ExitBatch) {
    b.add(
        "a table and its inverse, proved as a lemma with an empty body",
        M"(const S: [u8; 4] = [2, 0, 3, 1];
const INV: [u8; 4] = [1, 3, 0, 2];
@prove_exhaustive
fn inverse(x: u8)
    requires x < 4
    ensures INV[S[x as usize] as usize] == x
{}
fn main() i32 {
    return S[INV[2] as usize];
}
)",
        2,
    );
    b.add(
        "an enum's variants, a bool, and a method that takes its enum by reference",
        M"(enum Color {
    Red,
    Green = 5,
    Blue,
}
extend Color {
    @prove_exhaustive
    fn code(self: &Self) u8
        ensures |r| r < 3
    {
        return switch *self {
            Color::Red => 0,
            Color::Green => 1,
            Color::Blue => 2,
        };
    }
}
@prove_exhaustive
fn choose(c: Color, b: bool) u8
    ensures |r| r != 7
{
    if b && c == Color::Blue {
        return 6;
    }
    return c.code();
}
fn main() i32 {
    return choose(Color::Blue, false) + Color::Green.code();
}
)",
        3,
    );
    b.add(
        "a usize narrowed by its requires, and inputs its requires excludes",
        M"(const T: [u8; 300] = [3; 300];
@prove_exhaustive
fn look(i: usize) u8
    requires i < 300
    ensures |r| r < 7
{
    return T[i];
}
@prove_exhaustive
fn share(x: u8) u8
    requires x != 0
    ensures |r| r <= 100
{
    return 100 / x;
}
fn main() i32 {
    return look(299) + share(7);
}
)",
        17,
    );
    b.add(
        "a loop invariant, a callee's requires and a function without contracts",
        M"(fn half(x: u8) u8
    requires x % 2 == 0
{
    return x / 2;
}
@prove_exhaustive
fn twice_half(x: u8) u8
    requires x < 100
{
    return half(x * 2);
}
@prove_exhaustive
fn tri(n: u8) u32
    ensures |r| r <= 32385
{
    let mut s: u32 = 0;
    let mut i: u8 = 0;
    while i < n
        invariant s <= 32385
    {
        s += i;
        i += 1;
    }
    return s;
}
@prove_exhaustive
fn mix(a: u8, b: bool) u8 {
    return if b { a / 2 } else { a ^ 0x5A };
}
@prove_exhaustive
fn three() u8
    ensures |r| r == 3
{
    return 3;
}
fn main() i32 {
    return (twice_half(3) as u32 + tri(4) + mix(10, true) as u32 + three() as u32) as i32;
}
)",
        17,
    );
    b.add(
        "a cycle with a measure through a function each of whose runs ended",
        M"(fn even(n: u8) bool
    requires n < 40
    decreases n
{
    if n == 0 {
        return true;
    }
    return odd(n - 1);
}
@prove_exhaustive
fn odd(n: u8) bool
    requires n < 40
{
    if n == 0 {
        return false;
    }
    return even(n - 1);
}
fn main() i32 {
    return even(4) as i32 + odd(3) as i32 * 2;
}
)",
        3,
    );
    b.add(
        "an enum's conformance that refines its interface",
        M"(interface Area {
    fn area(self: &Self, k: u8) u8
        requires k < 10
        ensures |r| r < 100;
}
enum Kind {
    A,
    B,
}
extend Kind as Area {
    @prove_exhaustive
    fn area(self: &Self, k: u8) u8
        requires k < 12
        ensures |r| r < 133
    {
        return k * 11;
    }
}
fn main() i32 {
    return Kind::B.area(2);
}
)",
        22,
    );
}

// Proofs the theory solvers make together: congruence over equal operands (a `const fn` call, a
// division, an array read, one at an index narrower than `usize` or under a bit operation), equalities
// the arithmetic implies (`x <= y, y <= x`), a product bounded by its operands' ranges, and an integer
// equality with no solution (`x == 2 * y` against an odd value).
fn theory_proofs(b: &mut h::ExitBatch) {
    b.add(
        "reads at narrow indexes and bit operations over reads",
        M"(fn read32(a: [u32; 4], i: u32, j: u32) u32
    requires i == j, i < 4
    ensures |r| r == a[j]
{
    return a[i];
}
fn read_signed(a: [u32; 4], i: i32, j: i32) u32
    requires i == j, i >= 0, i < 4
    ensures |r| r == a[j]
{
    return a[i];
}
fn low_bits(a: [u32; 4], i: usize, j: usize) bool
    requires i == j, i < 4
    ensures |r| r
{
    return (a[i] & 1) == (a[j] & 1);
}
fn main() i32 {
    let a: [u32; 4] = [1, 2, 3, 4];
    return (read32(a, 2, 2) + read_signed(a, 1, 1)) as i32 + low_bits(a, 3, 3) as i32;
}
)",
        6,
    );
    b.add(
        "congruence and implied equalities",
        M"(const fn half(x: u32) u32 {
    return x / 2 + 1;
}
fn calls(a: u32, b: u32) bool
    requires a == b
    ensures |r| r
{
    return half(a) == half(b);
}
fn thirds(x: u64, y: u64) u64
    requires x == y
    ensures |r| r == y / 3
{
    return x / 3;
}
fn read(a: [u32; 4], i: usize, j: usize) u32
    requires i == j, i < 4
    ensures |r| r == a[j]
{
    return a[i];
}
fn sevens(x: u64, y: u64) bool
    requires x <= y, y <= x
    ensures |r| r
{
    return x % 7 == y % 7;
}
// The remainders' facts leave rational points with no integer one (`r_x - r_y` a multiple of 7 that is
// not 0, between -6 and 6): Gomory cuts end them, where splits of one atom do not.
fn shift7(x: u64, y: u64) bool
    requires x < 1000, y == x + 7
    ensures |r| r
{
    return x % 7 == y % 7;
}
fn shift13(x: i64, y: i64) bool
    requires x > -1000, x < -100, y == x + 26
    ensures |r| r
{
    return x % 13 == y % 13;
}
fn main() i32 {
    let r = read([1, 2, 3, 4], 2, 2);
    return calls(3, 3) as i32 + (thirds(9, 9) == 3) as i32 + r as i32 + sevens(8, 8) as i32 + shift7(3, 10) as i32 + shift13(-500, -474) as i32;
}
)",
        8,
    );
    b.add(
        "products and integer equalities",
        M"(fn area(w: u16, h: u16) u64
    ensures |r| r <= 4294836225
{
    return (w as u64) * (h as u64);
}
fn odd_off(x: u32, y: u32, z: u32) bool
    requires y < 1000, z < 1000, x == 2 * y
    ensures |r| r
{
    return x != 2 * z + 1;
}
fn main() i32 {
    return (area(3, 4) - 12) as i32 + odd_off(4, 2, 7) as i32;
}
)",
        1,
    );
    // `u128` and `i128` (`UInt<128>`, `Int<128>`) are integers to the prover: their comparisons,
    // `+`, `-`, `*`, implicit conversions and literals past 64 bits.
    b.add(
        "wide integers",
        M"(fn sum(a: u128, b: u128) u128
    requires a < 1000, b < 1000
    ensures |r| r < 2000
    ensures |r| r >= a
{
    return a + b;
}
fn above(a: u128) u128
    requires a > 18446744073709551615, a < 100000000000000000000
    ensures |r| r > 18446744073709551616
{
    return a + 1;
}
fn neg(a: i128, b: i128) i128
    requires a < 0, b < 0, a > -100, b > -100
    ensures |r| r > -200
    ensures |r| r < a
{
    return a + b;
}
fn scale(a: u128) bool
    requires a < 1000
    ensures |r| r
{
    return a * 3 - a == a * 2 && a != a + 1;
}
fn main() i32 {
    let x: u128 = 18446744073709551616;
    return (sum(1, 2) - 3) as i32 + (above(x) > x) as i32 + (neg(-1, -2) + 3) as i32 + scale(7) as i32;
}
)",
        2,
    );
    // Division and remainder (by a constant: the quotient's bounds), bit operations and shifts of
    // wide integers.
    b.add(
        "wide division, bit operations and shifts",
        M"(fn half(a: u128) u128
    requires a < 1000
    ensures |r| r < 500
{
    return a / 2;
}
fn low(a: u128) u128
    ensures |r| r < 16
{
    return a % 16;
}
fn mask(a: u128) u128
    ensures |r| r <= 255
{
    return a & 255;
}
fn same(a: u128, b: u128) bool
    requires a == b
    ensures |r| r
{
    return (a ^ 5) == (b ^ 5) && (a << 3) == (b << 3) && (a >> 2) == (b >> 2) && ~a == ~b;
}
fn sdiv(a: i128) i128
    requires a > -1000, a < 1000
    ensures |r| r > -500
    ensures |r| r < 500
{
    return a / 2;
}
fn main() i32 {
    return (half(10) + low(17) + mask(300) - 50) as i32 + same(9, 9) as i32 + sdiv(-7) as i32 + 4;
}
)",
        2,
    );
    // `k == 3` makes `a * k` the linear `3 * a`, on built-in and wide integers.
    b.add(
        "a product by an operand the requires fix",
        M"(fn scale(a: u128, k: u128) bool
    requires a < 1000, k == 3
    ensures |r| r
{
    return a * k - a == a * 2;
}
fn sc64(a: u64, k: u64) u64
    requires a < 1000, k == 3
    ensures |r| r < 3000
{
    return a * k;
}
fn neg(a: i32, k: i32) i32
    requires a > -100, a < 100, k == -2
    ensures |r| r > -200
{
    return k * a;
}
fn main() i32 {
    return scale(7, 3) as i32 + (sc64(5, 3) - 15) as i32 + neg(3, -2) + 6;
}
)",
        1,
    );
    b.add(
        "integers wider than 128 bits",
        M"(type U256 = UInt<256>;
type I512 = Int<512>;
fn add256(a: U256, b: U256) U256
    requires a < 1000, b < 1000
    ensures |r| r < 2000
{
    return a + b;
}
fn big(a: U256) U256
    requires a > 340282366920938463463374607431768211455, a < 340282366920938463463374607431768211457000
    ensures |r| r > 340282366920938463463374607431768211456
{
    return a + 1;
}
fn neg512(a: I512) I512
    requires a < 0, a > -1000
    ensures |r| r < 1
{
    return a * 2 + 1;
}
fn shr256(a: U256) U256
    requires a < 1024
    ensures |r| r < 64
{
    return a >> 4;
}
fn main() i32 {
    let x: U256 = 340282366920938463463374607431768211456;
    return (add256(1, 2) - 3) as i32 + (big(x) > x) as i32 + (neg512(-1) + 1) as i32 + shr256(100) as i32 - 3;
}
)",
        4,
    );
}

// Goals the arithmetic reads only as atoms, refuted by the bits of their terms (a SAT refutation).
fn bit_proofs(b: &mut h::ExitBatch) {
    b.add(
        "bit operations and shifts, proved by their bits",
        M"(fn xor_back(x: u32, y: u32) u32
    ensures |r| r == x
{
    return x ^ y ^ y;
}
fn mask_le(x: u32) u32
    ensures |r| r <= x
{
    return x & 0xF0F0;
}
fn low_clear(x: u32) u32
    requires x > 0
    ensures |r| r < x
{
    return x & (x - 1);
}
fn even(x: u32) bool
    ensures |r| r == (x % 2 == 0)
{
    return (x & 1) == 0;
}
fn split_join(x: u64) u64
    ensures |r| r == x
{
    let h = x >> 32;
    let l = x & 0xFFFFFFFF;
    return h << 32 | l;
}
fn main() i32 {
    return (xor_back(5, 9) + mask_le(0x34) + low_clear(12) + even(4) as u32) as i32 + (split_join(7) - 7) as i32;
}
)",
        62,
    );
    b.add(
        "wrapping and rotating operations",
        M"(fn wrap_back(x: u32, y: u32) u32
    ensures |r| r == x
{
    return x.wrapping_add(y).wrapping_sub(y);
}
fn rot_back(x: u32, n: u32) u32
    ensures |r| r == x
{
    return x.rotate_left(n).rotate_right(n);
}
fn quarter(a: u32, b: u32, d: u32) u32
    ensures |r| (r.rotate_right(16) ^ a.wrapping_add(b)) == d
{
    return (d ^ a.wrapping_add(b)).rotate_left(16);
}
fn odd_times(x: u32) u32
    ensures |r| (r & 1) == (x & 1)
{
    return x.wrapping_mul(3);
}
fn signed_rot(x: i32) i32
    ensures |r| r.rotate_right(3) == x
{
    return x.rotate_left(3);
}
fn negated(x: i64) i64
    ensures |r| r.wrapping_add(x) == 0
{
    return x.wrapping_neg();
}
fn main() i32 {
    let q = quarter(1, 2, 3);
    return (wrap_back(7, 4294967295) + rot_back(2, 33) + odd_times(5) % 2 + (q >> 16 ^ 3)) as i32 + signed_rot(-2) + negated(5) as i32 + 5;
}
)",
        4,
    );
}

@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    proved_contracts(&mut b);
    exhaustive_proofs(&mut b);
    theory_proofs(&mut b);
    bit_proofs(&mut b);
    ghost_proofs(&mut b);
    b.run();
}

@test
fn exit_cases_02() {
    let mut b = h::ExitBatch::new();
    invariant_proofs(&mut b);
    b.run();
}

// A struct's invariant, which its own file's code keeps, and the blocks of `@owned` fields: an allocation,
// a `realloc` that keeps the elements, null, a generic element type.
fn invariant_proofs(b: &mut h::ExitBatch) {
    b.add(
        "functions that may panic where their 'panics if' holds, called where it does not",
        "fn at(xs: []u32, i: usize) u32\n    panics if i >= xs.len()\n{\n    if i >= xs.len() {\n        panic(\"at: out of bounds\");\n    }\n    return xs[i];\n}\n\nfn inc(x: u8) u8\n    panics if x == 255\n    ensures |r| r as int == x as int + 1\n{\n    return x + 1;\n}\n\nfn user(xs: []u32) u32\n    requires xs.len() > 2\n{\n    return at(xs, 1) / 2 + inc(3) as u32;\n}\n\ninterface C {\n    fn get(self: &Self, k: u32) u32 panics if k > 9;\n}\n\nstruct A {}\n\nextend A as C {\n    fn get(self: &Self, k: u32) u32\n        panics if k > 20\n    {\n        if k > 20 {\n            panic(\"big\");\n        }\n        return k;\n    }\n}\n\nfn main() i32 {\n    let mut v = Vector::<u32>::new();\n    v.push(1);\n    v.push(2);\n    v.push(3);\n    let a = A {};\n    return user(v.as_slice()) as i32 + a.get(1) as i32 - 6;\n}\n",
        0,
    );
    b.add(
        "an invariant broken after the only operation that may panic",
        "struct C\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nextend C {\n    fn reset(self: &mut C, k: u32)\n        panics if k == 0\n    {\n        let q = 10 / k;\n        self.n = 1;\n        self.max = 0;\n        self.n = q - q;\n    }\n}\nfn main() i32 {\n    let mut c = C { n: 0, max: 3 };\n    c.reset(2);\n    return c.n as i32;\n}\n",
        0,
    );
    b.add(
        "a box with an invariant over its block: zero-sized values, a destructor, shared parameters",
        "import std::spec::seq as *;\n\nstruct Bx<T, A = Global>\n    invariant sizeof(T) == 0 || block(self.ptr).len() == 1\n{\n    @owned\n    ptr: *mut T,\n    alloc: A,\n}\n\nextend<T, A: Allocator> Bx<T, A> {\n    fn new_in(alloc: A, value: T) Bx<T, A> {\n        let mut a = alloc;\n        let p = if sizeof(T) == 0 {\n            dangling::<T>()\n        } else {\n            (unsafe a.alloc(sizeof(T), alignof(T))) as *mut T\n        };\n        unsafe p[0] = value;\n        return Bx::<T, A> { ptr: p, alloc: a };\n    }\n\n    fn get(self: &Bx<T, A>) &T {\n        return unsafe &self.ptr[0];\n    }\n\n    fn set(self: &mut Bx<T, A>, value: T) {\n        unsafe self.ptr[0].free();\n        unsafe self.ptr[0] = value;\n    }\n}\n\nextend<T, A: Allocator> Bx<T, A> as Free {\n    fn free(self: &mut Bx<T, A>) {\n        self.ptr.free();\n        if sizeof(T) != 0 {\n            unsafe self.alloc.dealloc(self.ptr, sizeof(T), alignof(T));\n        }\n    }\n}\n\nextend<T: Eq, A: Allocator> Bx<T, A> as Eq {\n    fn eq(self: &Bx<T, A>, other: &Bx<T, A>) bool {\n        let a = self.get();\n        let b = other.get();\n        return *a == *b;\n    }\n}\n\nstruct E {}\n\nfn main() i32 {\n    let mut b = Bx::<u32, Global>::new_in(Global {}, 3);\n    b.set(4);\n    let c = Bx::<u32, Global>::new_in(Global {}, 4);\n    let _z = Bx::<E, Global>::new_in(Global {}, E {});\n    if !(b == c) {\n        return 1;\n    }\n    return *b.get() as i32 - 4;\n}\n",
        0,
    );
    b.add(
        "a write through a copy of an owned field keeps the block's length",
        "import std::spec::seq as *;\n\nstruct B\n    invariant block(self.p).len() == 4\n{\n    @owned\n    p: *mut u32,\n}\n\nextend B {\n    fn poke(self: &mut B) u32 {\n        let q = self.p;\n        unsafe q[1] = 5;\n        return unsafe self.p[3];\n    }\n}\n\nfn main() i32 {\n    return 0;\n}\n",
        0,
    );
    b.add(
        "a receiver lent to a call that keeps no borrow keeps its facts past later calls",
        "struct P {\n    x: u32,\n    v: Vector<u32>,\n}\nextend P {\n    fn bump(self: &mut P) requires self.x < 10 ensures self.x == old(self.x) + 1 {\n        self.x += 1;\n    }\n}\nfn other() {\n    print(\"\");\n}\nfn kept() u32 ensures |r| r == 2 {\n    let mut p = P { x: 1, v: Vector::<u32>::new() };\n    p.bump();\n    other();\n    return p.x;\n}\nfn main() i32 {\n    return kept() as i32 - 2;\n}\n",
        0,
    );
    b.add(
        "struct invariants and owned blocks",
        M"(import std::spec::seq as *;

pub struct Counter
    invariant self.n <= self.max
{
    n: u32,
    max: u32,
}

extend Counter {
    pub fn new(max: u32) Counter {
        return Counter { n: 0, max: max };
    }

    pub fn bump(self: &mut Counter) {
        if self.n < self.max {
            self.n += 1;
        }
    }

    pub const fn get(self: &Counter) u32 {
        return self.n;
    }

    pub fn reset(self: &mut Counter, m: u32) {
        self.max = m;
        self.n = 0;
    }
}

fn within(c: &Counter)
    ensures c.n <= c.max
{}

spec fn small(c: &Counter) bool {
    return c.n <= 100;
}

lemma same(c: &Counter)
    requires small(c)
    ensures small(c)
{}

pub struct Buf {
    @owned
    p: *mut u32,
    cap: usize,
}

extend Buf {
    pub fn make(n: usize) Buf
        requires n > 0 && n < 1000
        ensures |r| block(r.p).len() == n as nat && r.cap == n
    {
        let mut g = Global {};
        let p = unsafe g.alloc(n * 4, 4) as *mut u32;
        return Buf { p: p, cap: n };
    }

    pub fn grow(self: &mut Buf, x: u32)
        requires block(self.p).len() == self.cap as nat && self.cap > 0 && self.cap < 1000
        ensures block(self.p).len() == old(self.cap) as nat * 2 && self.cap == old(self.cap) * 2
        ensures block(self.p)[0] == x
    {
        unsafe self.p[0] = x;
        let mut g = Global {};
        let np = unsafe g.realloc(self.p, self.cap * 4, self.cap * 8, 4) as *mut u32;
        self.p = np;
        self.cap = self.cap * 2;
    }

    pub const fn first(self: &Buf) u32
        requires block(self.p).len() >= 1
        ensures |r| r == block(self.p)[0]
    {
        return unsafe self.p[0];
    }

    pub fn set0(self: &mut Buf, x: u32)
        requires block(self.p).len() >= 1
        ensures block(self.p)[0] == x && block(self.p).len() == old(block(self.p).len()) && self.cap == old(self.cap)
    {
        unsafe self.p[0] = x;
    }

    pub fn release(self: &mut Buf)
        requires self.cap < 1000
        ensures block(self.p).len() == 0
    {
        let mut g = Global {};
        unsafe g.dealloc(self.p, self.cap * 4, 4);
        self.p = null;
        self.cap = 0;
    }
}

pub struct Many<T> {
    @owned
    p: *mut T,
    cap: usize,
}

extend<T> Many<T> {
    pub fn make(n: usize) Many<T>
        requires n > 0 && n < 1000 && sizeof(T) < 1000
        ensures |r| block(r.p).len() == n as nat && r.cap == n
    {
        let mut g = Global {};
        let p = unsafe g.alloc(n * sizeof(T), alignof(T)) as *mut T;
        return Many::<T> { p: p, cap: n };
    }

    pub fn release(self: &mut Many<T>)
        requires self.cap < 1000 && sizeof(T) < 1000
    {
        let mut g = Global {};
        unsafe g.dealloc(self.p, self.cap * sizeof(T), alignof(T));
        self.p = null;
        self.cap = 0;
    }
}

fn main() i32 {
    let mut c = Counter::new(3);
    c.bump();
    c.bump();
    within(&c);
    let mut m = Many::<u64>::make(3);
    m.release();
    let mut b = Buf::make(2);
    b.grow(7);
    b.release();
    let mut d = Buf::make(1);
    d.set0(5);
    let v = unsafe d.p[0];
    d.release();
    return (c.get() + v) as i32 - 7;
}
)",
        0,
    );
}

@test
fn exit_cases_01() {
    let mut b = h::ExitBatch::new();
    spec_syntax_proofs(&mut b);
    seq_proofs(&mut b);
    view_proofs(&mut b);
    container_proofs(&mut b);
    nonlinear_proofs(&mut b);
    trigger_proofs(&mut b);
    b.run();
}

// The instances of quantifiers: at a match of a trigger deep in the body; where the formulas hold more
// integer terms than the wide stage takes, at those the model puts in range (`model`), and at the
// matches of a user's trigger the body's value does not hold (`user`).
fn trigger_proofs(b: &mut h::ExitBatch) {
    b.add(
        "quantifier instances at triggers and at the model's terms",
        M"(import std::spec::quant as *;
@trusted
spec fn f(x: int) int;
@trusted
spec fn g(x: int) int;
@trusted
spec fn h(x: int) int;
@trusted
spec fn u(x: int) int;
lemma deep(a: int)
    requires forall k in 0 as int..10 { f(g(k) + 1) >= 3 }
    requires 0 <= a && a < 10
    ensures f(g(a) + 1) >= 3
{}
lemma model(p0: int, p1: int, p2: int, p3: int, p4: int, p5: int, p6: int, p7: int, p8: int, p9: int, p10: int, p11: int, p12: int, p13: int, p14: int, p15: int, p16: int, p17: int, p18: int, p19: int, p20: int, p21: int, p22: int, p23: int, p24: int, p25: int, p26: int, p27: int, p28: int, p29: int, p30: int, p31: int, p32: int, p33: int, p34: int, p35: int, p36: int, p37: int, p38: int, p39: int, a: int, b: int, c: int)
    requires 0 <= c && c < 100 && a <= c && c < b
    requires forall k in 0 as int..100 { k < a || k >= b }
    requires p0 >= 200
    requires p1 >= 201
    requires p2 >= 202
    requires p3 >= 203
    requires p4 >= 204
    requires p5 >= 205
    requires p6 >= 206
    requires p7 >= 207
    requires p8 >= 208
    requires p9 >= 209
    requires p10 >= 210
    requires p11 >= 211
    requires p12 >= 212
    requires p13 >= 213
    requires p14 >= 214
    requires p15 >= 215
    requires p16 >= 216
    requires p17 >= 217
    requires p18 >= 218
    requires p19 >= 219
    requires p20 >= 220
    requires p21 >= 221
    requires p22 >= 222
    requires p23 >= 223
    requires p24 >= 224
    requires p25 >= 225
    requires p26 >= 226
    requires p27 >= 227
    requires p28 >= 228
    requires p29 >= 229
    requires p30 >= 230
    requires p31 >= 231
    requires p32 >= 232
    requires p33 >= 233
    requires p34 >= 234
    requires p35 >= 235
    requires p36 >= 236
    requires p37 >= 237
    requires p38 >= 238
    requires p39 >= 239
    ensures h(p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10 + p11 + p12 + p13 + p14 + p15 + p16 + p17 + p18 + p19 + p20 + p21 + p22 + p23 + p24 + p25 + p26 + p27 + p28 + p29 + p30 + p31 + p32 + p33 + p34 + p35 + p36 + p37 + p38 + p39) == 7
{}
lemma user(p0: int, p1: int, p2: int, p3: int, p4: int, p5: int, p6: int, p7: int, p8: int, p9: int, p10: int, p11: int, p12: int, p13: int, p14: int, p15: int, p16: int, p17: int, p18: int, p19: int, p20: int, p21: int, p22: int, p23: int, p24: int, p25: int, p26: int, p27: int, p28: int, p29: int, p30: int, p31: int, p32: int, p33: int, p34: int, p35: int, p36: int, p37: int, p38: int, p39: int, a: int, b: int, c: int, d: int)
    requires u(c * d) == 1
    requires forall k in 0 as int..100 { (k < a || k >= b) && trigger(u(k)) * 0 == 0 }
    requires p0 >= 200
    requires p1 >= 201
    requires p2 >= 202
    requires p3 >= 203
    requires p4 >= 204
    requires p5 >= 205
    requires p6 >= 206
    requires p7 >= 207
    requires p8 >= 208
    requires p9 >= 209
    requires p10 >= 210
    requires p11 >= 211
    requires p12 >= 212
    requires p13 >= 213
    requires p14 >= 214
    requires p15 >= 215
    requires p16 >= 216
    requires p17 >= 217
    requires p18 >= 218
    requires p19 >= 219
    requires p20 >= 220
    requires p21 >= 221
    requires p22 >= 222
    requires p23 >= 223
    requires p24 >= 224
    requires p25 >= 225
    requires p26 >= 226
    requires p27 >= 227
    requires p28 >= 228
    requires p29 >= 229
    requires p30 >= 230
    requires p31 >= 231
    requires p32 >= 232
    requires p33 >= 233
    requires p34 >= 234
    requires p35 >= 235
    requires p36 >= 236
    requires p37 >= 237
    requires p38 >= 238
    requires p39 >= 239
    ensures c * d < 0 || c * d >= 100 || c * d < a || c * d >= b || h(p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10 + p11 + p12 + p13 + p14 + p15 + p16 + p17 + p18 + p19 + p20 + p21 + p22 + p23 + p24 + p25 + p26 + p27 + p28 + p29 + p30 + p31 + p32 + p33 + p34 + p35 + p36 + p37 + p38 + p39) == 7
{}
fn main() i32 {
    return 0;
}
)",
        0,
    );
}

// Products of unknowns over `int`: monotonicity, a product of two bounds, signs, a square.
fn nonlinear_proofs(b: &mut h::ExitBatch) {
    b.add(
        "products of unknowns",
        M"(lemma mono(a: int, b: int, c: int)
    requires 0 <= b && a <= c
    ensures a * b <= c * b
{}
lemma mono2(a: int, b: int, c: int, d: int)
    requires 0 <= a && a <= c && 0 <= b && b <= d
    ensures a * b <= c * d
{}
lemma box(a: int, b: int)
    requires 0 <= a && a <= 10 && 0 <= b && b <= 20
    ensures a * b <= 200
{}
lemma sign(a: int, b: int)
    requires 1 <= a && 1 <= b
    ensures a * b >= 1
{}
lemma sq(a: int)
    requires 3 <= a
    ensures a * a >= 9
{}
fn main() i32 { return 0; }
)",
        0,
    );
}

// Containers held in members: a callee's contract through `&mut q.v`, a method of `p.v` behind `&mut p`;
// and the methods that change a vector or a string, each by its effect on the view.
fn container_proofs(b: &mut h::ExitBatch) {
    b.add(
        "containers held in members",
        M"(import std::spec::seq as *;
struct P {
    x: u32,
    v: Vector<u8>,
}
fn put(v: &mut Vector<u8>)
    requires v.len() < 100
    ensures v.view() == old(v.view()).push(1)
{
    v.push(1);
}
fn c(p: &mut P)
    requires p.v.len() < 100
    ensures p.v.view() == old(p.v.view()).push(1) && p.x == old(p.x)
{
    put(&mut p.v);
}
fn d() u32
    ensures |r| r == 2
{
    let mut q = P { x: 2, v: Vector::<u8>::new() };
    put(&mut q.v);
    assert q.v.view().len() == 1 by {};
    return q.x;
}
fn e(p: &mut P) u8
    requires p.v.len() == 0
    ensures |r| r == 6 && p.x == old(p.x)
{
    p.v.push(5);
    p.v.push(6);
    return p.v[1];
}
fn main() i32 {
    let mut p = P { x: 1, v: Vector::<u8>::new() };
    c(&mut p);
    let mut q = P { x: 0, v: Vector::<u8>::new() };
    return (p.x + d() + e(&mut q) as u32) as i32;
}
)",
        9,
    );
    b.add(
        "the methods that change a vector or a string",
        M"(import std::spec::seq as *;
fn t_set() u8
    ensures |r| r == 9
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    v.push(2);
    v.set(1, 9);
    return v[1];
}
fn t_trunc() usize
    ensures |r| r == 1
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    v.push(2);
    v.truncate(1);
    v.truncate(5);
    return v.len();
}
fn t_insert() u8
    ensures |r| r == 7
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    v.push(2);
    v.insert(1, 7);
    assert v.len() == 3 by {};
    return v[1];
}
fn t_remove() u8
    ensures |r| r == 2
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    v.push(2);
    let _ = v.remove(0);
    let _ = v.remove(5);
    assert v.len() == 1 by {};
    return v[0];
}
fn t_swap() u8
    ensures |r| r == 2
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    v.push(2);
    v.swap(0, 1);
    return v[0];
}
fn t_extend() usize
    ensures |r| r == 4
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    let mut w = Vector::<u8>::new();
    w.push(2);
    w.push(3);
    v.extend_copy(&w);
    v.extend_from_slice(&w[0..1]);
    v.reserve(10);
    return v.len();
}
fn t_same() usize
    ensures |r| r == 2
{
    let mut v = Vector::<u8>::new();
    v.push(3);
    v.push(1);
    v.sort();
    v.reverse();
    v.dedup();
    return v.len() + (2 - v.len());
}
fn t_str() u8
    ensures |r| r == 66
{
    let mut s = String::new();
    s.push_byte(65);
    s.push_byte(66);
    s.insert_byte(0, 64);
    s.set_byte(0, 1);
    let x = s.pop_byte();
    let y = s.remove_byte(0);
    assert y == 1 && s.len() == 1 by {};
    s.truncate(0);
    assert s.len() == 0 by {};
    return x;
}
fn t_resize() usize
    ensures |r| r == 4
{
    let mut v = Vector::<u8>::new();
    v.push(5);
    v.resize_default(4);
    let _ = v.swap_remove(9);
    return v.len();
}
fn main() i32 {
    return (t_set() as usize + t_trunc() + t_insert() as usize + t_remove() as usize + t_swap() as usize + t_extend() + t_same() + t_str() as usize + t_resize()) as i32;
}
)",
        97,
    );
}

// Views and the values a proof keeps: an `old` value that is not `Copy`, a range of a view or a vector, a `[]mut` parameter a call or a
// loop's writes through another cannot reach, a `[]mut` read as `[]T`, a drop beside a written view, a
// choice of equal booleans, a named constant's value.
fn view_proofs(b: &mut h::ExitBatch) {
    b.add(
        "ranges of a view and of a vector",
        M"(import std::spec::seq as *;
fn mid(v: []u8) u8
    requires v.len() == 4
    ensures |r| r == v.view()[1]
{
    let s = &v[1..4];
    return s[0];
}
fn tail_sum(v: &Vector<u8>) u32
    requires v.len() == 3
{
    let s = &v[1..=2];
    return s[0] as u32 + s[1] as u32;
}
fn main() i32 {
    let a: [u8; 4] = [1, 5, 2, 3];
    let mut v = Vector::<u8>::new();
    v.push(1);
    v.push(2);
    v.push(4);
    if v.len() != 3 {
        return 1;
    }
    return mid(&a[0..4]) as i32 + tail_sum(&v) as i32;
}
)",
        11,
    );
    b.add(
        "a named constant and a choice of equal booleans",
        M"(import std::spec::seq as *;
spec fn h(c: bool, a: Seq<u8>, n: int) Seq<u8>
    decreases n
{
    return if n <= 0 || n > a.len() { a } else { h(c, a, n - 1).push(a[n - 1]) };
}
lemma same_choice(c1: bool, c2: bool, a: Seq<u8>)
    requires c1 == c2
    ensures h(c1, a, 3) == h(c2, a, 3)
{}
const N: usize = 4;
fn at_most_four(k: usize) usize
    requires k <= 4
{
    return k;
}
fn total() usize {
    let mut s = 0usize;
    for k in 2..N + 1 {
        s += at_most_four(k);
    }
    return s;
}
fn main() i32 {
    return total() as i32;
}
)",
        9,
    );
    b.add(
        "old values that are not Copy",
        M"(import std::spec::seq as *;
struct P {
    x: u32,
    v: Vector<u8>,
}
fn c(p: &mut P)
    requires p.x < 100
    ensures p.x == old(*p).x + 1 && p.v.view() == old(*p).v.view()
{
    p.x += 1;
}
fn d(v: &mut Vector<u8>)
    requires v.len() < 100
    ensures v.view() == old(*v).view().push(3)
{
    v.push(3);
}
fn main() i32 {
    let mut p = P { x: 1, v: Vector::<u8>::new() };
    c(&mut p);
    let mut v = Vector::<u8>::new();
    d(&mut v);
    return (p.x as usize + v.len()) as i32;
}
)",
        3,
    );
    b.add(
        "a view a loop's writes through another parameter keep",
        M"(import std::spec::seq as *;
fn clear(a: []mut u8, b: []mut u8)
    requires a.len() == 3 && b.len() == 3
    ensures a.view()[2] == 0 && b.view()[1] == 5
{
    b[1] = 5;
    for i in 0usize..3
        invariant a.len() == 3 && b.len() == 3 && b.view()[1] == 5
        invariant i > 2 ==> a.view()[2] == 0
    {
        let mut v = Vector::<u8>::new();
        v.push(0);
        a[i] = v[0];
    }
}
fn main() i32 {
    let mut x: [u8; 3] = [1, 1, 1];
    let mut y: [u8; 3] = [0, 0, 0];
    clear(&mut x[0..3], &mut y[0..3]);
    return (x[0] + x[1] + x[2] + y[1]) as i32;
}
)",
        5,
    );
    b.add(
        "views a call or a drop cannot change",
        M"(import std::spec::seq as *;
fn set0(b: []mut u8)
    requires b.len() == 2
    ensures b.len() == 2 && b.view()[0] == 7
{
    b[0] = 7;
}
fn both(a: []mut u8, b: []mut u8)
    requires a.len() == 2 && b.len() == 2
    ensures a.view()[0] == 7 && b.view()[0] == 7
{
    set0(a);
    set0(b);
}
fn first(x: []u8) u8
    requires x.len() == 2
    ensures |r| r == x.view()[0]
{
    return x[0];
}
fn shared(a: []mut u8) u8
    requires a.len() == 2
    ensures |r| r == 9
{
    a[0] = 9;
    return first(a);
}
fn kept(a: []mut u8) u32
    requires a.len() == 2
    ensures |r| r == 3
{
    let mut v = Vector::<u8>::new();
    v.push(1);
    a[1] = 3;
    return a[1] as u32;
}
fn main() i32 {
    let mut x: [u8; 2] = [0, 0];
    let mut y: [u8; 2] = [0, 0];
    both(&mut x[0..2], &mut y[0..2]);
    let s = shared(&mut y[0..2]);
    return (x[0] + y[0] + s) as i32 + kept(&mut x[0..2]) as i32;
}
)",
        28,
    );
}

// `==>`, `forall` and `exists` (their instances, a witness, a nested one, a loop invariant), `old`
// through `&mut`, a ghost variable, and a signed index whose bounds check stays.
fn spec_syntax_proofs(b: &mut h::ExitBatch) {
    b.add(
        "quantifiers and implications",
        M"(fn get(xs: []u32, i: usize) u32
    requires i < xs.len()
    requires forall k in 0..xs.len() { xs[k] > 0 }
    ensures |r| r > 0
{
    return xs[i];
}
fn find(xs: []u32, v: u32) usize
    requires exists k in 0..xs.len() { xs[k] == v }
    ensures |r| r < xs.len() && xs[r] == v
{
    for i in 0..xs.len()
        invariant forall k in 0..i { xs[k] != v }
    {
        if xs[i] == v {
            return i;
        }
    }
    // No index is left: the loop's invariant and the requires exclude this end.
    return 0;
}
fn first_pos(xs: []u32) u32
    requires xs.len() > 0
    requires forall k in 0..xs.len() { xs[k] > 0 }
    ensures |r| exists k in 0..xs.len() { xs[k] == r }
{
    return xs[0];
}
fn zero(a: [u32; 4]) [u32; 4]
    ensures |r| forall k in 0..4 { r[k] == 0 }
{
    let mut r = a;
    for i in 0..4
        invariant forall k in 0..i { r[k] == 0 }
    {
        r[i] = 0;
    }
    return r;
}
fn imp(x: u32, y: u32) u32
    requires x > 10 ==> y > 5
    requires x > 10
    ensures |r| r > 5
{
    return y;
}
fn sorted3(xs: []u32) bool
    requires forall i in 0..xs.len() { forall j in 0..i { xs[j] <= xs[i] } }
    requires xs.len() >= 3
    ensures |r| r
{
    return xs[0] <= xs[2];
}
fn main() i32 {
    let a: [u32; 3] = [4, 5, 6];
    let z = zero([1, 2, 3, 4]);
    return (get(a, 1) + find(a, 6) as u32 + first_pos(a) + z[2] + imp(11, 6)) as i32 + sorted3(a) as i32;
}
)",
        18,
    );
    b.add(
        "old values through mutable references and a ghost counter",
        M"(struct Acc {
    n: u32,
}
extend Acc {
    fn add(self: &mut Acc, k: u32)
        requires self.n < 1000 && k < 1000
        ensures self.n == old(self.n) + k
    {
        self.n += k;
    }
}
fn bump(x: &mut u32)
    requires *x < 100
    ensures *x == old(*x) + 1
{
    *x += 1;
}
fn twice(x: &mut u32)
    requires *x < 50
    ensures *x == old(*x) + 2
{
    bump(x);
    bump(x);
}
fn count(xs: []u32) usize
    ensures |r| r == xs.len()
{
    ghost let mut seen: int = 0;
    let mut n: usize = 0;
    for i in 0..xs.len()
        invariant n == i
        invariant seen == i as int
    {
        n += 1;
        ghost seen = seen + 1;
    }
    return n;
}
fn main() i32 {
    let mut x: u32 = 5;
    twice(&mut x);
    let mut a = Acc { n: 1 };
    a.add(3);
    let v: [u32; 3] = [1, 2, 3];
    return (x + a.n) as i32 + count(v) as i32;
}
)",
        14,
    );
}

// std::spec::seq: `Seq` operations, the views of vectors, strings, slices and arrays and the methods
// that change them, extensionality, trusted and generic spec functions, and a spec function's reference.
fn seq_proofs(b: &mut h::ExitBatch) {
    b.add(
        "the views of vectors and arrays and the sequence operations",
        M"(import std::spec::seq as *;
fn add(v: &mut Vector<u32>, x: u32)
    ensures v.view() == old(v.view()).push(x)
    ensures v.len() as int == old(v.len()) as int + 1
{
    v.push(x);
}
fn set0(v: &mut Vector<u32>)
    requires v.len() > 0
    ensures v.view()[0] == 7
    ensures v.view().len() == old(v.view()).len()
{
    v[0] = 7;
}
fn shrink(v: &mut Vector<u32>)
    requires v.len() > 0
    ensures v.view() == old(v.view()).subrange(0, old(v.view()).len() - 1)
{
    let _ = v.pop();
}
fn build() Vector<u32>
    ensures |r| r.view() == Seq::<u32>::empty().push(1).push(2)
{
    let mut v = Vector::<u32>::new();
    v.push(1);
    v.push(2);
    return v;
}
fn third(v: &Vector<u32>) u32
    requires v.len() > 2
    ensures |r| r == v.view()[2]
{
    return v[2];
}
spec fn sum(s: Seq<u32>, n: nat) int
    requires n <= s.len()
    decreases n
{
    return if n == 0 {
        0
    } else {
        sum(s, n - 1) + s[n - 1] as int
    };
}
fn total(xs: []u32) u64
    requires xs.len() <= 1000
    ensures |r| r as int == sum(xs.view(), xs.len() as nat)
{
    let mut acc: u64 = 0;
    for i in 0..xs.len()
        invariant acc as int == sum(xs.view(), i as nat)
        invariant acc <= i as u64 * 4294967295
    {
        acc += xs[i];
    }
    return acc;
}
fn split(xs: []u32) bool
    requires xs.len() >= 2
    ensures |r| xs.view().subrange(0, 1).concat(xs.view().subrange(1, xs.view().len())) == xs.view()
    ensures |r| xs.view().take(1).len() == 1 && xs.view().skip(1)[0] == xs[1]
{
    return true;
}
fn main() i32 {
    let mut v = build();
    add(&mut v, 3);
    set0(&mut v);
    let t = third(&v);
    shrink(&mut v);
    let a: [u32; 3] = [1, 2, 3];
    let s: [u32; 2] = [4, 5];
    return (v[0] + v[1] + t) as i32 + total(a) as i32 + split(s) as i32;
}
)",
        19,
    );
    b.add(
        "the views of strings and mutable slices, ghost sequences and spec functions",
        M"(import std::spec::seq as *;
fn greet(s: &mut String)
    ensures s.view() == old(s.view()).concat("hi".view())
{
    s.push_str("hi");
}
fn put(s: &mut String)
    ensures s.view().len() == old(s.view()).len() + 3
{
    s.push('A');
    s.push('\u{e9}');
}
fn fill(xs: []mut u32)
    ensures forall k in 0..xs.len() { xs.view()[k as int] == 0 }
{
    for i in 0..xs.len()
        invariant forall k in 0..i { xs.view()[k as int] == 0 }
    {
        xs[i] = 0;
    }
}
@trusted
spec fn grows(x: int) int
    requires x >= 0
    ensures |r| r >= x;
lemma grows_pos(x: int)
    requires x >= 1
    ensures grows(x) >= 1
{
}
spec fn head(s: &Seq<u32>) &u32
    requires s.len() > 0
{
    return &s[0];
}
spec fn same<U>(x: U) U {
    return x;
}
fn first(xs: []u32) u32
    requires xs.len() > 0
    ensures |r| same(xs.view()) == xs.view() && same::<u32>(r) == xs[0]
{
    ghost let s: Seq<u32> = xs.view();
    assert *head(&s) == xs[0] by {};
    grows_pos(xs.len() as int);
    return xs[0];
}
fn main() i32 {
    let mut s = String::new();
    greet(&mut s);
    put(&mut s);
    let mut a: [u32; 3] = [1, 2, 3];
    fill(&mut a[0..3]);
    let b: [u32; 2] = [9, 8];
    return s.len() as i32 + a[1] as i32 + first(b) as i32;
}
)",
        14,
    );
}

// Ghost code no build runs: spec functions and their definitions, lemmas by induction, `assert .. by`,
// `int` and `nat`, and std::spec.
fn ghost_proofs(b: &mut h::ExitBatch) {
    b.add(
        "a spec function, a lemma by induction and a loop invariant over int",
        M"(spec fn sum_spec(xs: []u32, n: usize) int
    requires n <= xs.len()
    decreases n
{
    return if n == 0 {
        0
    } else {
        sum_spec(xs, n - 1) + xs[n - 1] as int
    };
}
lemma sum_bound(xs: []u32, n: usize)
    requires n <= xs.len()
    ensures sum_spec(xs, n) <= n as int * 4294967295
    decreases n
{
    if n > 0 {
        sum_bound(xs, n - 1);
    }
}
fn sum(xs: []u32) u64
    requires xs.len() <= 1000
    ensures |r| r as int == sum_spec(xs, xs.len())
{
    let mut acc: u64 = 0;
    for i in 0..xs.len()
        invariant acc as int == sum_spec(xs, i)
    {
        sum_bound(xs, i + 1);
        acc += xs[i];
    }
    return acc;
}
fn main() i32 {
    let v: [u32; 3] = [4, 5, 6];
    return sum(v) as i32;
}
)",
        15,
    );
    b.add(
        "assert by, calls over constants and nat",
        M"(spec fn pow2(n: nat) nat
    decreases n
{
    return if n == 0 {
        1
    } else {
        2 * pow2(n - 1)
    };
}
spec fn pred(n: nat) nat
    requires n > 0
{
    return n - 1;
}
lemma pred_less(n: nat)
    requires n > 0
    ensures pred(n) < n
{
}
fn halve(x: u32) u32
    ensures |r| r as int * 2 <= x as int
{
    assert pow2(5) == 32 by {};
    pred_less(x as nat + 1);
    return x / 2;
}
fn main() i32 {
    return halve(9) as i32;
}
)",
        4,
    );
    b.add(
        "std::spec from a function",
        M"(import std::spec::arith as *;
fn mulmod(a: u32, b: u32, m: u32) u32
    requires m > 0
    ensures |r| r as int == a as int * (b as int) % (m as int)
{
    mod_mul(a as int, b as int, m as int);
    return (a as u64 * b as u64 % m as u64) as u32;
}
fn shifted(x: u32) u64
    ensures |r| r as int == x as int * pow2(8)
{
    return x as u64 << 8;
}
fn main() i32 {
    return mulmod(3, 5, 7) as i32 + (shifted(1) >> 4) as i32;
}
)",
        17,
    );
}

// `@prove_exhaustive`: the first input whose run fails, reported where it fails, and the functions
// whose inputs cannot run.
@test
fn exhaustive_failures_are_reported() {
    let mut b = cli::Batch::new("", "fn main() i32 {\n    return 0;\n}\n");
    b.add_at(
        "an ensures over a table",
        "const S: [u8; 4] = [2, 0, 3, 1];\n@prove_exhaustive\nfn inv(x: u8) requires x < 4 ensures S[S[x as usize] as usize] == x {}\n",
        "this 'ensures' clause does not hold",
        "3:38",
    );
    b.add_at(
        "a loop invariant",
        "@prove_exhaustive\nfn sum(n: u8) u32 {\n    let mut s: u32 = 0;\n    let mut i: u8 = 0;\n    while i < n invariant s <= 1000 {\n        s += i;\n        i += 1;\n    }\n    return s;\n}\n",
        "this 'invariant' does not hold",
        "5:27",
    );
    b.add_at(
        "a callee's requires",
        "fn half(x: u8) u8 requires x % 2 == 0 { return x / 2; }\n@prove_exhaustive\nfn calls(x: u8) u8 { return half(x); }\n",
        "the 'requires' of 'half' does not hold at this call",
        "3:29",
    );
    b.add_at(
        "an overflow",
        "@prove_exhaustive\nfn add1(x: u8) u8 { return x + 1; }\n",
        "undefined behavior for some arguments: arithmetic overflow",
        "2:28",
    );
    b.add_at(
        "an overflow in a callee",
        "fn inner(x: u8) u8 { return x * 2; }\n@prove_exhaustive\nfn outer(x: u8) u8 { return inner(x); }\n",
        "undefined behavior for some arguments: arithmetic overflow (in inner)",
        "3:29",
    );
    b.add_at(
        "an index past the end",
        "@prove_exhaustive\nfn idx(i: u8) u8 {\n    let t: [u8; 10] = [0; 10];\n    return t[i as usize];\n}\n",
        "undefined behavior for some arguments: index out of bounds",
        "4:12",
    );
    b.add_at(
        "a division by zero",
        "@prove_exhaustive\nfn dv(x: u8, y: u8) u8 requires x < 4 { return x / y; }\n",
        "undefined behavior for some arguments: division by zero",
        "2:48",
    );
    b.add_at(
        "a panic",
        "@prove_exhaustive\nfn pan(x: u8) u8 {\n    if x == 77 {\n        panic(\"no\");\n    }\n    return x;\n}\n",
        "this statement panics for some arguments: no\n",
        "4:9",
    );
    b.add_at(
        "an assertion",
        "@prove_exhaustive\nfn asrt(x: i8) i8 {\n    assert(x != -3, \"x\");\n    return x;\n}\n",
        "this assertion fails",
        "3:12",
    );
    b.add_at(
        "a callee's ensures",
        "fn g(x: u8) u8 ensures |r| r < 200 { return x; }\n@prove_exhaustive\nfn h(x: u8) u8 { return g(x); }\n",
        "the 'ensures' of 'g' does not hold in this call",
        "3:25",
    );
    b.add_at(
        "a run that does not end",
        "@prove_exhaustive\nfn spin(x: u8) u8 {\n    let mut y = x;\n    while y != 3 {\n        y = y;\n    }\n    return y;\n}\n",
        "cannot prove that this function ends: its evaluation takes more than 262144 steps",
        "2:4",
    );
    b.add_at(
        "a generic function",
        "@prove_exhaustive\nfn gen<T>(x: T) T { return x; }\n",
        "'@prove_exhaustive' cannot evaluate a generic function",
        "2:4",
    );
    b.add_at(
        "a measure",
        "@prove_exhaustive\nfn dec(x: u8) u8 decreases x { return x; }\n",
        "a '@prove_exhaustive' function takes no 'decreases' measure",
        "2:28",
    );
    b.add_at(
        "a parameter without a small set of values",
        "@prove_exhaustive\nfn strp(s: str) usize { return s.len(); }\n",
        "'@prove_exhaustive' cannot enumerate the values of parameter 's'",
        "2:9",
    );
    b.add_at(
        "too many inputs",
        "@prove_exhaustive\nfn two(x: u16, y: u8) u16 { return x + y; }\n",
        "'x' takes 65536 values, 'y' takes 256 values",
        "2:4",
    );
    b.add_at(
        "a call the evaluator cannot run",
        "import stdlib;\n@prove_exhaustive\nfn env(x: u8) u8 {\n    let p = stdlib::getenv(\"HOME\");\n    return x + (p == null) as u8;\n}\n",
        "'@prove_exhaustive' cannot evaluate this at compile time",
        "4:13",
    );
    b.add_at(
        "a contract that calls a function that is not a const fn",
        "fn big(x: u8) bool { return x > 3; }\n@prove_exhaustive\nfn f(x: u8) u8 requires big(x) { return x; }\n",
        "a contract must only compute its condition",
        "3:25",
    );
    b.add_at(
        "a function with a requires used as a value",
        "fn half(x: u8) u8 requires x % 2 == 0 { return x / 2; }\n@prove_exhaustive\nfn v(x: u8) u8 {\n    let f = half;\n    return x;\n}\n",
        "a function with a 'requires' clause cannot be used as a value",
        "4:13",
    );
    b.add_at(
        "an enum's conformance weaker than its interface",
        "interface Area {\n    fn area(self: &Self, k: u8) u8 requires k < 10 ensures |r| r < 100;\n}\nenum Kind {\n    A,\n}\nextend Kind as Area {\n    @prove_exhaustive\n    fn area(self: &Self, k: u8) u8 requires k < 12 ensures |r| r < 133 { return k * 12; }\n}\n",
        "cannot prove the interface's 'ensures' at this return",
        "9:74",
    );
    h::expect_build_errs(b);
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
    // A `panics if` states where the function may panic: no check runs it.
    let pan = h::diff_build(
        "fn f(x: u32) u32 panics if x > 3 { return x; }\nfn main() i32 { return f(5) as i32; }\n",
        ["-fno-prove", "-fcontract-checks"],
    );
    assert(pan.built, "a panics clause builds with checks");
    assert_eq(h::diff_run(&pan, "").exit, 5);
    // A clause that names a spec function or converts into `int` has no run-time check.
    let spec = h::diff_build(
        "spec fn s(x: u32) u32 { return x; }\nfn f(x: u32) u32 requires x as int < 10, s(x) < 10 { return x; }\nfn main() i32 { return f(3) as i32; }\n",
        ["-fcontract-checks"],
    );
    assert(!spec.built && spec.diag.contains("this contract converts into 'int' or 'nat'"), "a conversion into int");
    assert(spec.diag.contains("this contract calls a spec function"), "a spec function's call");
    // Quantifiers and `old` run as loops and saved values; a sequence's equality has no run-time check.
    let q = h::diff_build(
        M"(fn get(xs: []u32, i: usize) u32
    requires i < xs.len()
    requires forall k in 0..xs.len() { xs[k] > 0 }
    requires exists k in 0..=i { xs[k] == 1 }
{
    return xs[i];
}
fn bump(x: &mut u32)
    requires *x < 100
    ensures *x == old(*x) + 1
{
    *x += 2;
}
fn main(args: Vector<str>) i32 {
    let a: [u32; 3] = [1, 2, 3];
    let b: [u32; 3] = [5, 0, 3];
    let mut x: u32 = 5;
    if args.len() > 2 {
        return get(b, 2) as i32;
    }
    if args.len() > 1 {
        bump(&mut x);
    }
    return get(a, 2) as i32 + x as i32;
}
)",
        ["-fno-prove", "-fcontract-checks"],
    );
    assert(q.built, "quantifiers and old build with checks");
    assert_eq(h::diff_run(&q, "").exit, 8);
    let qr = h::diff_run(&q, "x y");
    assert(
        qr.exit != 0 && qr.err.contains("assertion failed: `requires forall k in 0..xs.len() { xs[k] > 0 }`"),
        "the forall check traps",
    );
    let orun = h::diff_run(&q, "x");
    assert(orun.exit != 0 && orun.err.contains("assertion failed: `ensures *x == old(*x) + 1`"), "the old check traps");
    let seq = h::diff_build(
        "import std::spec::seq as *;\nfn f(v: &mut Vector<u32>, x: u32) ensures v.view() == old(v.view()).push(x) { v.push(x); }\nfn main() i32 { return 0; }\n",
        ["-fcontract-checks"],
    );
    assert(
        !seq.built && seq.diag.contains("this contract compares values of a type without 'eq'"),
        "a sequence's equality",
    );
    // A clause the checks run copies its `old` value at the entry: only a `Copy` one.
    let whole = h::diff_build(
        "struct P {\n    x: u32,\n    v: Vector<u8>,\n}\nfn c(p: &mut P) requires p.x < 100 ensures p.x == old(*p).x + 1 { p.x += 1; }\nfn main() i32 { return 0; }\n",
        ["-fcontract-checks"],
    );
    assert(
        !whole.built && whole.diag.contains(
            "'old' in a clause '-fcontract-checks' runs copies its value: 'P' is not 'Copy'",
        ),
        "an old value that is not Copy in a run clause",
    );
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

// A struct's invariant is a fact of each of its values in another module: a proof there uses it.
@test
fn invariants_hold_in_other_modules() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/counter.spc",
        "pub struct Counter\n    invariant self.n <= self.max\n{\n    n: u32,\n    max: u32,\n}\nextend Counter {\n    pub fn new(max: u32) Counter {\n        return Counter { n: 0, max: max };\n    }\n    pub spec fn count(self: &Counter) u32 {\n        return self.n;\n    }\n    pub spec fn limit(self: &Counter) u32 {\n        return self.max;\n    }\n}\n",
    );
    p.mkfile(
        "src/main.spc",
        "import counter as *;\nfn check(c: &Counter) ensures c.count() <= c.limit() {}\nfn wrong(c: &Counter) ensures c.count() < c.limit() {}\nfn main() i32 {\n    let c = Counter::new(3);\n    check(&c);\n    wrong(&c);\n    return 0;\n}\n",
    );
    let r = cli::superc_in(p.dir(), "build");
    assert(r.exit != 0 && r.out_has("main.spc:3:"), "the false ensures is reported");
    assert(!r.out_has("main.spc:2:"), "the invariant proves the true one");
}

// The diagnostics of a build's output: its error, location and note lines.
fn diags(out: str) String {
    let mut s = String::new();
    for line in out.lines() {
        if line.starts_with("error") || line.starts_with("-->") || line.trim_start().starts_with("= note") {
            s.push_str(line);
            s.push_str("\n");
        }
    }
    return s;
}

// The proofs run on several workers and report as one: the same diagnostics, in the same order.
@test
fn parallel_proofs_report_like_one() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        cli::par_sized(
            "fn a(x: u32) u32 ensures |r| r > x { return x; }\nfn b(x: u32) u32 requires x < 9 { return x; }\nfn c(x: u8) bool ensures |r| r { return x != 4; }\nfn main() i32 { return (a(1) + b(20) + c(2) as u32) as i32; }\n",
        ).as_str(),
    );
    let root = p.dir();
    let one = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build --jobs=1");
    let many = cli::superc_env_in(root, "SC_CEMIT_STATS", format("1 {}", cli::NO_JOBSERVER).as_str(), "build --jobs=4");
    assert(one.exit != 0 && one.out_has("for example: x = 4"), "the serial build reports the failed proofs");
    assert(one.out_has(", 1 workers\n") && many.out_has(", 4 workers\n"), "the builds prove on one worker and on four");
    assert(many.exit != 0 && diags(one.text()) == diags(many.text()), "the parallel build reports the same text");
}

// `@prove_exhaustive` names the first failed input by its arguments, in parameter order, and reports
// the same on one worker as on four, whose parts of the inputs run in parallel.
@test
fn exhaustive_proofs_report_like_one() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        cli::par_sized(
            M"(enum Color {
    Red,
    Blue,
}
extend Color {
    @prove_exhaustive
    fn code(self: &Self) u8
        ensures |r| r < 1
    {
        return *self as u8;
    }
}
@prove_exhaustive
fn choose(c: Color, b: bool) u8
    ensures |r| r != 7
{
    return if b && c == Color::Blue { 7 } else { 1 };
}
@prove_exhaustive
fn sum2(a: u8, b: u8) bool
    ensures |r| r
{
    return a as u32 + 2 * b as u32 <= 300;
}
const T: [u8; 299] = [1; 299];
@prove_exhaustive
fn look(i: usize) u8
    requires i < 300
{
    return T[i];
}
@prove_exhaustive
fn neg(x: i8) i8 {
    assert(x != -3, "x");
    return x;
}
@prove_exhaustive
fn spin(x: u8) u8 {
    let mut y = x;
    while y != 200 {
        y = y;
    }
    return y;
}
fn main() i32 {
    return 0;
}
)",
        ).as_str(),
    );
    let root = p.dir();
    let one = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build --jobs=1");
    let many = cli::superc_env_in(root, "SC_CEMIT_STATS", format("1 {}", cli::NO_JOBSERVER).as_str(), "build --jobs=4");
    assert(one.out_has("= note: for example: self = Color::Blue\n"), "an enum by reference names its variant");
    assert(one.out_has("= note: for example: c = Color::Blue, b = true\n"), "an enum and a bool");
    assert(one.out_has("= note: for example: a = 0, b = 151\n"), "the first parameter varies slowest");
    assert(one.out_has("= note: for example: i = 299\n"), "a usize runs over the range its requires gives");
    assert(one.out_has("= note: for example: x = -3\n"), "a signed value");
    assert(one.out_has("= note: for example: x = 0\n"), "the first run that does not end");
    assert(!one.out_has("unused function"), "a function proved by evaluation is used");
    assert(one.out_has(", 1 workers\n") && many.out_has(", 4 workers\n"), "the builds prove on one worker and on four");
    assert(many.exit != 0 && diags(one.text()) == diags(many.text()), "the parallel build reports the same text");
}
