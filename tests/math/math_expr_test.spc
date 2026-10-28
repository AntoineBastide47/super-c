// std::math::expr: `assign` and `sum` give each element its expression's value, for floats and integers,
// with views of other lengths a panic where the expression is built and where it is assigned; and an
// assignment compiles to one vectorized loop with no overlap test.
import std::math::expr as *;
import tests::harness as h;
import tests::cli_harness as cli;

@test
fn assign_writes_each_element_once() {
    let mut a = Vector::<f64>::new();
    let mut b = Vector::<f64>::new();
    let mut y = Vector::<f64>::new();
    for i in 0usize..37 {
        a.push(i as f64 * 0.5);
        b.push(3.0 - i as f64);
        y.push(-1.0);
    }
    assign(y.index_range_mut(0..37), 2.0 * ex(a[0..37]) + ex(a[0..37]) * ex(b[0..37]) - ex(b[0..37]) * 0.25);
    for i in 0usize..37 {
        assert(y[i] == 2.0 * a[i] + a[i] * b[i] - b[i] * 0.25);
    }
    // An integer expression.
    let mut z = Vector::<i64>::new();
    for i in 0i64..9 {
        z.push(i);
    }
    let mut w = z.clone();
    assign(w.index_range_mut(0..9), ex(z[0..9]) * ex(z[0..9]) - ex(z[0..9]));
    for i in 0usize..9 {
        assert(w[i] == (i * i - i) as i64);
    }
}

@test
fn sum_adds_left_to_right() {
    let mut a = Vector::<f32>::new();
    for i in 0usize..100 {
        a.push(1.0 / (i as f32 + 1.0));
    }
    let mut s: f32 = 0.0;
    for i in 0usize..100 {
        s = s + a[i] * a[i];
    }
    assert(sum(ex(a[0..100]) * ex(a[0..100])) == s);
    let e: []i32 = [];
    assert(sum(ex(e)) == 0);
}

@test
fn a_length_mismatch_panics() {
    h::expect_run(
        "an expression of different lengths",
        "import std::math::expr as *;\nfn main() i32 {\n    let a: []i32 = [1, 2, 3];\n    let b: []i32 = [1, 2];\n    return sum(ex(a) + ex(b));\n}\n",
        "",
        "expr: the lengths differ",
    );
    h::expect_run(
        "an assignment of different lengths",
        "import std::math::expr as *;\nfn main() i32 {\n    let a: []i32 = [1, 2, 3];\n    let mut v = Vector::<i32>::new();\n    v.push(0);\n    assign(v.index_range_mut(0..1), ex(a));\n    return v[0];\n}\n",
        "",
        "expr::assign: the lengths differ",
    );
}

// The assignment's loop reads the views through no bounds check and needs no overlap test: the
// destination is a `[]mut`, which reaches no storage the expression's views reach.
@test
fn an_assignment_is_one_vector_loop() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::math::expr as *;\n\n@noinline\nfn axpby(y: []mut f64, a: []f64, b: []f64) {\n    assign(y, 2.0 * ex(a) + ex(b));\n}\n\nfn main() i32 {\n    let a: []f64 = [1.0, 2.0];\n    let mut v = Vector::<f64>::new();\n    v.push(0.0);\n    v.push(0.0);\n    axpby(v.index_range_mut(0..2), a, a);\n    return (v[1] - 6.0) as i32;\n}\n",
    );
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "assign", "build -O2 main.spc -o app");
    if !r.ok() || !r.out_has("v2f64") || r.out_has("icmp.ule") || r.out_has("panic_parts") {
        r.show();
    }
    assert(
        r.ok() && r.out_has("v2f64") && !r.out_has("icmp.ule") && !r.out_has("panic_parts"),
        "one vector loop, no overlap test",
    );
}
