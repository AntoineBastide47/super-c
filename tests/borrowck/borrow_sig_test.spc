// Signature ties of call results: elision ties a result to its single borrowing input only through the
// result's elided lifetime positions. A result without one (an owned `dyn`, a struct holding one) holds only
// `'static` borrows, which the callee's own return check enforces.
import tests::harness as h;

@test
fn an_owned_dyn_result_is_not_tied_to_its_input() {
    let c = h::compile(
        "interface I {\n    fn f(self: &Self) i32;\n}\n\nstruct A {\n    pub n: i32,\n}\n\nextend A as I {\n    pub fn f(self: &Self) i32 {\n        return self.n;\n    }\n}\n\nfn mk(p: str) Box<dyn I> {\n    return Box::<A>::new(A { n: p.len() as i32 });\n}\n\nfn wrap() Box<dyn I> {\n    let name = String::from_str(\"x\");\n    let b = mk(name.as_str());\n    return b;\n}\n\nfn main() i32 {\n    return wrap().f() - 1;\n}\n",
        h::STAGE_TYPECHECK,
    );
    assert(c.ok(), "the result outlives the string it was made from");
}

@test
fn a_struct_holding_an_owned_dyn_is_not_tied_to_its_input() {
    let c = h::compile(
        "interface I {\n    fn f(self: &Self) i32;\n}\n\nstruct S {\n    pub b: Option<Box<dyn I>>,\n    pub n: i32,\n}\n\nfn make(p: str) S {\n    return S { b: Option::<Box<dyn I>>::None, n: p.len() as i32 };\n}\n\nfn keep() S {\n    let name = String::from_str(\"x\");\n    let s = make(name.as_str());\n    return s;\n}\n\nfn main() i32 {\n    return keep().n - 1;\n}\n",
        h::STAGE_TYPECHECK,
    );
    assert(c.ok(), "the struct outlives the string it was made from");
}

@test
fn a_returned_owned_dyn_cannot_capture_a_borrow() {
    let c = h::compile(
        "fn mk(x: &i32) Box<dyn fn() i32> {\n    return Box::new(|| *x);\n}\n\nfn main() i32 {\n    let v = 3;\n    let f = mk(&v);\n    return f() - 3;\n}\n",
        h::STAGE_TYPECHECK,
    );
    assert(!c.ok(), "the callee rejects the borrowing closure");
    let s = h::compile(
        "struct S {\n    pub b: Box<dyn fn() i32>,\n}\n\nfn mk(x: &i32) S {\n    return S { b: Box::new(|| *x) };\n}\n\nfn main() i32 {\n    let v = 3;\n    let s = mk(&v);\n    return (s.b)() - 3;\n}\n",
        h::STAGE_TYPECHECK,
    );
    assert(!s.ok(), "a field of an owned dyn takes only 'static borrows");
}
