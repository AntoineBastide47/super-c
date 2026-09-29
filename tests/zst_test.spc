// Zero-sized-type elision: semantic size/alignment/offsets are unchanged while the
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

// An over-aligned zero-sized field (an empty struct with a larger @c.align than its non-ZST sibling)
// is elided, but its alignment still shapes the enclosing struct: the emitter plans the padding so
// the C layout matches the semantic one. Covers the ZST over-alignment padding planner.
@test
fn over_aligned_zst_field_pads_the_layout() {
    h::expect_exit(
        "over-aligned elided field keeps the sibling's value",
        "@c.align(16)\nstruct Marker {}\nstruct Holder { pub m: Marker, pub b: i32 }\nfn main() i32 {\n    let h = Holder { m: Marker {}, b: 9 };\n    return h.b - 9;\n}\n",
        0,
    );
}

// An Array of a zero-sized element is itself zero-sized: its `[T; N]` member is read under the
// instance's bindings, so no C definition over an incomplete element type is emitted.
@test
fn zst_element_array_elides() {
    h::expect_exit(
        "Array<Z, 3> of an empty struct",
        "@derive(Default)\nstruct Z {}\nfn main() i32 {\n    let a = Array::<Z, 3>::new();\n    if a.len() != 3 { return 1; }\n    let mut n = 0;\n    for _z in a.iter() {\n        n += 1;\n    }\n    if n != 3 { return 2; }\n    if sizeof(Array<Z, 3>) != 0 { return 3; }\n    return 0;\n}\n",
        0,
    );
}

// A generic body names `Array<T, N>` and `[T; N]` through its own parameters; with T zero-sized
// and over-aligned, it must classify, size and align them as the concrete caller does.
@test
fn zst_nested_generic_agrees_with_concrete() {
    h::expect_exit(
        "generic body and concrete caller agree on Array<T, N> with T zero-sized",
        "@derive(Default)\n@c.align(16)\nstruct M {}\nstruct Hold<T, const N: usize> { pub a: Array<T, N>, pub raw: [T; N], pub b: i32 }\nfn gsize<T, const N: usize>() usize {\n    return sizeof(Hold<T, N>) * 100 + alignof(Array<T, N>);\n}\nfn pass<T, const N: usize>(h: Hold<T, N>) Hold<T, N> {\n    return h;\n}\nfn make<T: Default, const N: usize>(raw: [T; N]) Hold<T, N> {\n    return Hold::<T, N> { a: Array::<T, N>::new(), raw: raw, b: 9 };\n}\nfn main() i32 {\n    let h = pass::<M, 2>(make::<M, 2>([M {}, M {}]));\n    if h.b != 9 { return 1; }\n    if gsize::<M, 2>() != 1616 { return 2; }\n    if sizeof(Hold<M, 2>) != 16 { return 3; }\n    return 0;\n}\n",
        0,
    );
}

// A constant that addresses a zero-sized object (a constant, a field, an element, an array a slice
// views, a temporary) holds the aligned sentinel, like a reference at run time: the object has no C
// storage. Every such address is equal.
@test
fn zst_constant_references() {
    const SRC: str = M"(struct Z {}
@c.align(8)
struct Z8 {}
struct H<'a> { pub z: &'a Z, pub n: i32, pub zs: [Z; 2] }
const ZC: Z = Z {};
const Z8C: Z8 = Z8 {};
const RZ: &Z = &ZC;
const RR: &&Z = &RZ;
const R8: &Z8 = &Z8C;
static mut RS: &Z = &ZC;
const HH: H<'static> = H { z: &ZC, n: 3, zs: [Z {}, Z {}] };
const RH: &H<'static> = &HH;
const ZA: [Z; 3] = [Z {}, Z {}, Z {}];
const ZS: []Z = ZA;
const E1: &Z = &ZA[1];
const OR: Option<&Z> = Option::Some(&ZC);
const CZ: &[Z; 2] = &[Z {}, Z {}];
const HZ: &[Z; 2] = &HH.zs;
fn get() &'static Z { return RZ; }
fn main() i32 {
    let a = get() as *const Z as usize;
    let mut bad = 0;
    if unsafe RS as *const Z as usize != a || RH.z as *const Z as usize != a || *RR as *const Z as usize != a { bad += 1; }
    if E1 as *const Z as usize != a || CZ as *const [Z; 2] as usize != a || HZ as *const [Z; 2] as usize != a { bad += 2; }
    if R8 as *const Z8 as usize % 8 != 0 { bad += 4; }
    if let Some(r) = OR { if r as *const Z as usize != a { bad += 8; } }
    if HH.n != 3 || ZS.len() != 3 { bad += 16; }
    return bad;
}
)";
    h::expect_exit("constants addressing zero-sized objects", SRC, 0);
    h::expect_c("a field addressing a zero-sized constant", SRC, "H HH = { .z = (void *)&__sc_zst_1, .n = 3 };");
    h::expect_c("a slice of a zero-sized array", SRC, "Slice__Z ZS = { .ptr = (void *)&__sc_zst_1, .len = 3 };");
    h::expect_c("an aligned zero-sized constant", SRC, "const Z8 *R8 = (void *)&__sc_zst_8;");
}

// A zero-length array is zero-sized like any ZST: no local, member or parameter of it is declared
// (ISO C has no zero-length array), a pointer to one is a bare data pointer whose arithmetic moves
// nothing, and a subscript of one (never executed: the bounds check fails first) addresses the
// element type at the sentinel. A zero-length member keeps its alignment in the enclosing struct.
const ZERO_LEN: str = M"(struct S { pub a: [u32; 0], pub b: u8 }
struct W<const N: usize> { pub d: [u32; N] }
struct Z { pub w: W<0>, pub x: u8 }
static_assert(sizeof(S) == 4 && alignof(S) == 4);
static_assert(sizeof(W<0>) == 0 && alignof(W<0>) == 4);
static_assert(sizeof(Z) == 4);
static_assert(sizeof(Array<u64, 0>) == 0);
const NONE: [i32; 0] = [];
fn pick(_: [i32; 0], a: i32) i32 { return a; }
fn mk() [i32; 0] { return []; }
fn sum<const N: usize>(a: [i32; N]) i32 { let mut s = 0; for x in a { s += x; } return s; }
fn main() i32 {
    let s = S { a: [], b: 1 };
    let z = Z { w: W::<0> { d: [] }, x: 2 };
    let mut a = Array::<u64, 0>::new();
    a.reverse();
    let m = a.map(|x: &u64| *x + 1);
    let f: fn([i32; 0], i32) i32 = pick;
    let e: [i32; 0] = [];
    let r = mk();
    let v: []i32 = r;
    let mut t = 0;
    for x in e { t += x; }
    let mut sb = S { a: [], b: 3 };
    sb.a = [];
    let ps: *const [u32; 0] = &sb.a;
    let pz = unsafe (ps + 3);
    let mut rows: [[i32; 0]; 3] = [[], [], []];
    let pr: *mut [i32; 0] = &mut rows[1];
    let d = (unsafe (pr + 1) as usize) - (pr as usize);
    if s.b != 1 || z.x != 2 || m.len() != 0 || f(e, 4) != 4 || v.len() != 0 || t != 0 { return 1; }
    if sum(e) + sum(NONE) != 0 || sum([1, 2]) != 3 || sb.b != 3 || pz != ps || d != 0 { return 2; }
    return 0;
}
)";

@test
fn zero_length_arrays_are_zero_sized() {
    h::expect_exit("zero-length arrays", ZERO_LEN, 0);
    h::expect_c_absent("no zero-length local", ZERO_LEN, "int32_t e[0]");
    h::expect_c_absent("no zero-length member", ZERO_LEN, "uint32_t a[0]");
    h::expect_c("a pointer to a zero-length array is a data pointer", ZERO_LEN, "const void *ps = ");
}
