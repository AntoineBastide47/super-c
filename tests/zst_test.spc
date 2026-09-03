// Zero-sized-type elision (Phase 10.5): semantic size/alignment/offsets are unchanged while the
// generated C carries NO storage for a ZST: no empty struct definition, no member, no local, no
// parameter, no element bytes. These are end-to-end build+run oracles: each program checks the
// SEMANTIC contract (sizes, drop counts, lengths, reference validity) that elision must preserve,
// and the strict-C11 gates elsewhere prove the representation side. Every required ZST effect:
// construction, moves, drops: must run exactly once per logical value.
import tests::harness as h;

@test
fn zst_sizes_and_layout() {
    h::expect_exit(
        "zst sizes",
        "struct Z {}\nstruct P { pub a: u64, pub z: Z, pub b: u32 }\nstruct Only { pub z: Z }\nfn main() i32 {\n    if sizeof(Z) != 0 { return 1; }\n    if alignof(Z) != 1 { return 2; }\n    if sizeof(P) != 16 { return 3; }\n    if sizeof(Only) != 0 { return 4; }\n    if sizeof(Vector<u64>) != 3 * sizeof(usize) { return 5; }\n    if sizeof(Box<u64>) != sizeof(usize) { return 6; }\n    let p = P { a: 7, z: Z {}, b: 9 };\n    if p.a != 7 || p.b != 9 { return 7; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_vector_lifecycle() {
    h::expect_exit(
        "vector of ZST",
        "static mut FREED: i64 = 0;\nstruct Z {}\nextend Z as Free { fn free(self: &mut Z) { unsafe { FREED = FREED + 1; } } }\nfn main() i32 {\n    {\n        let mut v = Vector::<Z>::new();\n        v.push(Z {});\n        v.push(Z {});\n        v.push(Z {});\n        if v.len() != 3 { return 1; }\n        let got = switch v.pop() { Some(z) => { 1; }, None => { 0; }, };\n        if got != 1 { return 2; }\n        if v.len() != 2 { return 3; }\n    }\n    if unsafe FREED != 3 { return 4; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_vector_iteration_counts() {
    h::expect_exit(
        "ZST iteration is length-driven",
        "struct U {}\nfn main() i32 {\n    let mut v = Vector::<U>::new();\n    let mut i = 0;\n    while i < 100 {\n        v.push(U {});\n        i += 1;\n    }\n    let mut c = 0;\n    for _u in v.iter() {\n        c += 1;\n    }\n    if c != 100 { return 1; }\n    let _r = v.at(50);\n    v.free();\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_box_and_map_and_set() {
    h::expect_exit(
        "Box/Map/Set with ZSTs",
        "static mut FREED: i64 = 0;\n@derive(Hash, Eq)\nstruct Z {}\nextend Z as Free { fn free(self: &mut Z) { unsafe { FREED = FREED + 1; } } }\nfn main() i32 {\n    {\n        let b = Box::<Z>::new(Z {});\n        let _ = b.get();\n    }\n    if unsafe FREED != 1 { return 1; }\n    let mut m = Map::<u32, Z>::new();\n    m.insert(1, Z {});\n    m.insert(2, Z {});\n    if m.len() != 2 { return 2; }\n    let k: u32 = 1;\n    let got = switch m.get(&k) { Some(z) => { 1; }, None => { 0; }, };\n    if got != 1 { return 3; }\n    m.free();\n    if unsafe FREED != 3 { return 4; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_arrays_construct_and_iterate() {
    // NOTE: [T; N] locals with Free elements refuse emission for MATERIAL elements too (a
    // pre-existing drop gap): ZST arrays keep parity, so this covers trivially-droppable ones.
    h::expect_exit(
        "[ZST; N] constructs and iterates by count",
        "struct Z {}\nfn main() i32 {\n    let a: [Z; 4] = [Z {}, Z {}, Z {}, Z {}];\n    let mut c = 0;\n    for _z in a {\n        c += 1;\n    }\n    if c != 4 { return 1; }\n    let r = &a;\n    let _ = r;\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_references_and_pointer_rules() {
    h::expect_exit(
        "ZST refs are non-null; pointer +- n is identity",
        "struct Z {}\nextend Z { fn ping(self: &Z) i32 { return 42; } }\nfn main() i32 {\n    let z = Z {};\n    let r = &z;\n    if r.ping() != 42 { return 1; }\n    let p = (&z) as *const Z;\n    if p == null { return 2; }\n    unsafe {\n        if p + 3 != p { return 3; }\n    }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_in_tuples_and_generics() {
    h::expect_exit(
        "tuples and dual instantiation",
        "struct Z {}\nstruct H<T> { pub v: T, pub tag: u32 }\nfn pair() (Z, i32) {\n    return Z {}, 9;\n}\nfn main() i32 {\n    let (z0, n0) = pair();\n    let _ = &z0;\n    if n0 != 9 { return 1; }\n    let t = (Z {}, 7);\n    if t.1 != 7 { return 6; }\n    let hz = H::<Z> { v: Z {}, tag: 5 };\n    let hu = H::<u64> { v: 8, tag: 6 };\n    if sizeof(H<Z>) != 4 { return 2; }\n    if sizeof(H<u64>) != 16 { return 3; }\n    if hz.tag + hu.tag != 11 { return 4; }\n    if hu.v != 8 { return 5; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_enum_payloads() {
    h::expect_exit(
        "enum with ZST payload variants",
        "struct Z {}\nenum E {\n    A(Z),\n    B(u32),\n}\nfn pick(e: &E) i32 {\n    return switch e {\n        A(z) => 1,\n        B(x) => *x as i32,\n    };\n}\nfn main() i32 {\n    let a = E::A(Z {});\n    let b = E::B(7);\n    if pick(&a) != 1 { return 1; }\n    if pick(&b) != 7 { return 2; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_consts_and_dangling() {
    h::expect_exit(
        "ZST consts and core::dangling",
        "struct Z {}\nconst CZ: Z = Z {};\nfn main() i32 {\n    let z = CZ;\n    let _ = &z;\n    let p = dangling::<u64>();\n    if p == null { return 1; }\n    if (p as usize) % alignof(u64) != 0 { return 2; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn zst_ffi_by_value_rejected() {
    h::expect_err_msg(
        "extern C cannot take a ZST by value",
        "struct Z {}\nextern \"C\" {\n    fn takes_zst(z: Z) void;\n}\nfn main() i32 {\n    return 0;\n}\n",
        "zero-sized",
    );
}
