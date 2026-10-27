// A `Box` is never null, as in Rust: `zeroed` cannot build a value that holds one (a build error for a
// concrete type, a panic for a generic one), a struct literal cannot leave one out, and an explicit
// `free` through a reference is an error (the owner would free the box again). A destructor frees its
// own parts, and the values the std seeds build (`Array`, derived `Clone` and `Default`) hold real boxes.
import tests::harness as h;

@test
fn zeroed_cannot_build_a_box() {
    h::expect_build_err(
        "a concrete zeroed Box",
        "fn main() i32 { let z = unsafe zeroed::<Box<i32>>(); return 0; }\n",
        "'zeroed' cannot build a value that holds a Box",
    );
    h::expect_build_err(
        "a struct that holds a Box",
        "struct S { pub n: i32, pub b: Option<Box<i32>> }\nfn main() i32 { let z = unsafe zeroed::<S>(); return z.n; }\n",
        "'zeroed' cannot build a value that holds a Box",
    );
    h::expect_trap(
        "a generic zeroed Box",
        "fn seed<T>() T { return unsafe zeroed::<T>(); }\nfn main() i32 { let b = seed::<Box<i32>>(); return *b.get(); }\n",
        "zeroed: a value that holds a Box has no all-zero form",
    );
    h::expect_build_err(
        "an omitted Box field",
        "struct S { pub n: i32, pub b: Box<i32> }\nfn main() i32 { let s = S { n: 1 }; return s.n; }\n",
        "missing field 'b'",
    );
}

@test
fn free_through_a_reference_is_an_error() {
    h::expect_build_err(
        "a parameter",
        "fn f(b: &mut Box<i32>) { b.free(); }\nfn main() i32 { let mut b = Box::<i32>::new(1); f(&mut b); return 0; }\n",
        "cannot free a value that holds a Box through a reference",
    );
    h::expect_build_err(
        "a field through self",
        "struct S { pub b: Box<i32> }\nextend S { fn drop_b(self: &mut S) { self.b.free(); } }\nfn main() i32 { let mut s = S { b: Box::<i32>::new(1) }; s.drop_b(); return 0; }\n",
        "cannot free a value that holds a Box through a reference",
    );
}

@test
fn boxes_free_once() {
    // A destructor frees its own box, an assignment frees the replaced one, and the std seeds
    // (`Array::filled`, derived `Clone` and `Default`) hold real boxes.
    h::expect_exit(
        "boxes free once",
        "struct S { pub b: Box<i32> }\nextend S as Free { fn free(self: &mut S) { self.b.free(); } }\n@derive(Clone, Default)\nstruct D { pub b: Box<i32>, pub n: i32 }\nfn main() i32 {\n    let s = S { b: Box::<i32>::new(3) };\n    let mut o = Option::<Box<i32>>::Some(Box::<i32>::new(4));\n    if let Some(b) = &o { if *b.get() != 4 { return 1; } }\n    o = Option::<Box<i32>>::None;\n    let five = Box::<i32>::new(5);\n    let a = Array::<Box<i32>, 3>::filled(&five);\n    let d = D { b: Box::<i32>::new(6), n: 1 };\n    let c = d.clone();\n    let z = D::default();\n    return *s.b.get() + *a.at(2).get() + *c.b.get() + *z.b.get() - 14 + o.is_some() as i32 + c.n - 1;\n}\n",
        0,
    );
}
