// A function or closure with results must not reach the end of its body: the caller would read results
// nothing wrote. A path ends without a value only through a statement that does not complete: a
// `return`, a call of a `!` or `@noreturn` function, a `loop` no `break` leaves, or an `if`, `switch`
// or block whose every way out is one of these. Named results return through a bare `return`.
import tests::harness as h;

const END: str = "can reach the end of its body without returning a value";

fn every_path_returns(b: &mut h::ExitBatch) {
    b.add(
        "each ending of a body that cannot complete",
        M"(extern "C" {
    @noreturn fn exit(code: i32) void;
}
fn both(x: i64) i64 {
    if x > 0 {
        return 1;
    } else if x < 0 {
        return -1;
    } else {
        return 0;
    }
}
fn arms(x: i64) i64 {
    switch x {
        0 => {
            return 10;
        },
        1 => {
            return 11;
        },
        _ => panic("no value"),
    };
}
fn spin(x: i64) i64 {
    let mut i = x;
    loop {
        if i > 3 {
            return i;
        }
        i += 1;
    }
}
fn guarded(x: i64) i64 {
    unsafe {
        if x >= 0 {
            return x;
        }
        exit(3);
    }
}
fn named(x: i64) (r: i64) {
    r = x + 1;
    return;
}
fn pair(x: i64) (a: i64, b: i64) {
    a = x;
    b = x + 1;
    return;
}
fn main() i32 {
    let c = fn(x: i64) i64 {
        if x != 0 {
            return x;
        }
        panic("zero");
    };
    let (p, q) = pair(1);
    return (both(0) + arms(1) - 11 + spin(0) - 4 + guarded(2) - 2 + named(1) - 2 + c(5) - 5 + p + q - 3) as i32;
}
)",
        0,
    );
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`).
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    every_path_returns(&mut b);
    b.run();
}

@test
fn a_reachable_end_is_an_error() {
    h::expect_err_msg(
        "an if without else",
        "fn f(x: i64) i64 {\n    if x > 0 {\n        return 1;\n    }\n}\nfn main() i32 { return f(1) as i32; }\n",
        END,
    );
    h::expect_err_msg(
        "an empty body",
        "fn f() i32 {}\nfn main() i32 { return f(); }\n",
        "function 'f' can reach the end",
    );
    h::expect_err_msg(
        "a while loop may run no iteration",
        "fn f(x: i64) i64 {\n    while x > 0 {\n        return 1;\n    }\n}\nfn main() i32 { return f(1) as i32; }\n",
        END,
    );
    h::expect_err_msg(
        "a loop a break leaves",
        "fn f(x: i64) i64 {\n    loop {\n        if x > 0 {\n            break;\n        }\n        return 2;\n    }\n}\nfn main() i32 { return f(1) as i32; }\n",
        END,
    );
    h::expect_err_msg(
        "one switch arm completes",
        "fn f(x: i64) i64 {\n    switch x {\n        0 => {\n            return 1;\n        },\n        _ => {},\n    };\n}\nfn main() i32 { return f(1) as i32; }\n",
        END,
    );
    h::expect_err_msg(
        "a call of a function that returns",
        "fn g() {}\nfn f() i64 {\n    g();\n}\nfn main() i32 { return f() as i32; }\n",
        END,
    );
    h::expect_err_msg(
        "a method",
        "struct S {}\nextend S {\n    fn m(self: &S) bool {\n        let _ = self;\n    }\n}\nfn main() i32 { return 0; }\n",
        "function 'm' can reach the end",
    );
    h::expect_err_msg("several results", "fn f() (i32, i32) {\n}\nfn main() i32 { return 0; }\n", END);
    h::expect_err_msg(
        "a closure",
        "fn main() i32 {\n    let c = fn(x: i64) i64 {\n        if x > 0 {\n            return 1;\n        }\n    };\n    return c(1) as i32;\n}\n",
        "this closure can reach the end of its body without returning a value",
    );
    h::expect_ok(
        "a void function may end",
        "fn f(x: i64) {\n    if x > 0 {\n        return;\n    }\n}\nfn main() i32 { f(1); return 0; }\n",
    );
}
