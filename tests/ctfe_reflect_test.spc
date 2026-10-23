// Const-evaluation and compile-time reflection paths not covered elsewhere: typed signed const
// arithmetic and its overflow trap, enum variant counting through type_info, and the tuple-field
// binder (whose field names come from the tuple type_info).
import tests::harness as h;
import ir::interp as iri;
import ir::lower as irl;
import module::loader as loader;
import driver_shim as shim;
import ast::ast as *;

// The engine's hash-keyed caches with one hash forced on two keys: each key keeps its own entry.
@test
fn a_shared_hash_never_answers_another_index_list() {
    let mut e = iri::interp_new(null);
    let mut a = Vector::<irl::LSub>::new();
    a.push(irl::LSub { pm: 1, pnode: 2, am: 3, at: 4 });
    let mut b = Vector::<irl::LSub>::new();
    b.push(irl::LSub { pm: 1, pnode: 2, am: 3, at: 5 });
    let ra = e.lane_row(7, 0, 10, &a);
    assert(e.lane_row(7, 0, 10, &a) == ra, "the same key finds its row");
    let rb = e.lane_row(7, 0, 10, &b);
    assert(rb != ra, "another substitution under the same hash is a miss");
    assert(e.lane_row(7, 0, 11, &b) != rb, "another node under the same hash is a miss");
    let rb2 = e.lane_row(7, 0, 10, &b);
    assert(rb2 != ra, "a key never answers with another key's row");
}

@test
fn a_shared_hash_never_answers_another_body() {
    let mut e = iri::interp_new(null);
    let mut a = Vector::<iri::ISub>::new();
    a.push(iri::ISub { pmod: 1, pnode: 2, am: 3, at: 4 });
    let mut b = Vector::<iri::ISub>::new();
    b.push(iri::ISub { pmod: 1, pnode: 2, am: 3, at: 5 });
    let none = Vector::<iri::ISub>::new();
    let sa = e.body_add(9, 0, 5, &a, 0);
    assert(e.body_find(9, 0, 5, &a) == sa, "the same key finds its body");
    assert(e.body_find(9, 0, 5, &b) < 0, "other bindings under the same hash are a miss");
    assert(e.body_find(9, 0, 6, &a) < 0, "another function under the same hash is a miss");
    assert(e.body_find(9, 0, 5, &none) < 0, "the binding-free body under the same hash is a miss");
    let sn = e.body_add(9, 0, 5, &none, 0);
    assert(e.body_find(9, 0, 5, &none) == sn, "the new key takes the hash over");
    assert(e.body_find(9, 0, 5, &a) < 0, "and the old key misses, never finds the new body");
}

// After a pass, the callee cache keeps what it had before the mark and, past the mark, only a body
// lowered from a body arena: a keep view slot and a box lowered from module-arena syntax are found
// again by a later miss.
@test
fn release_pass_keeps_only_bodies_a_later_miss_cannot_lower() {
    let p = loader::package_from_source("fn main() i32 {\n    return 0;\n}\n", "std", unsafe shim::sc_host_platform());
    let pk = (&p) as *const loader::Package;
    let mut e = iri::interp_new(null);
    let none = Vector::<iri::ISub>::new();
    e.bodies.push(Box::new(irl::Lowerer::new(pk, 0, 11)));
    let s0 = e.body_add(1, 0, 11, &none, 0);
    let mark = e.body_mark();
    let _ = e.body_add(2, 0, 12, &none, 1u64 << 63); // a slot of the keep view
    e.bodies.push(Box::new(irl::Lowerer::new(pk, 0, 13)));
    let _ = e.body_add(3, 0, 13, &none, 1);
    e.bodies.push(Box::new(irl::Lowerer::new(pk, 0, NODE_BODY | 14)));
    let _ = e.body_add(4, 0, NODE_BODY | 14, &none, 2);
    e.release_pass(mark);
    assert(e.body_find(1, 0, 11, &none) == s0, "a slot before the mark stays");
    assert(e.body_find(2, 0, 12, &none) < 0, "a keep view slot is released");
    assert(e.body_find(3, 0, 13, &none) < 0, "a box lowered from module-arena syntax is released");
    let sk = e.body_find(4, 0, NODE_BODY | 14, &none);
    assert(sk == 1, "a box lowered from a body arena stays, moved down");
    assert_eq(e.bodies.len(), 2usize);
    assert_eq(e.bodies.at(e.body_slot[sk as usize] as usize).get().body.owner.node, NODE_BODY | 14);
}

@test
fn const_overflow_is_rejected() {
    // A signed const addition that overflows its type is undefined behavior and the build refuses it.
    h::expect_build_err(
        "const overflow fails the build",
        "const A: i32 = i32::MAX + 1i32;\nfn main() i32 { return A; }\n",
        "overflow",
    );
}

// A fields binder whose subject type parameter is a type without fields (a builtin, a pointer, an
// array) has zero copies, as over an enum: the instance emits.
fn field_binder_over_a_type_without_fields_has_no_copies(b: &mut h::ExitBatch) {
    b.add(
        "fields over u32, a pointer and an array",
        M"(fn count<T>(v: &T) i32 {
    let mut n: i32 = 0;
    inline for f in fields(v) {
        n += f.size as i32;
    }
    return n;
}
struct P {
    pub a: u32,
    pub b: u64,
}
fn main(args: Vector<str>) i32 {
    let k: u32 = args.len() as u32;
    let p = &k as *const u32;
    let arr: [u8; 3] = [1, 2, 3];
    let q = P { a: k, b: 2 };
    return count(&k) + count(&p) + count(&arr) + count(&q);
}
)",
        12,
    );
}

fn tuple_field_binder_names_each_element(b: &mut h::ExitBatch) {
    // fields(&tuple) binds each element; the element names come from the tuple's type_info ("_0", "_1",
    // .., std/reflect.spc).
    b.add(
        "each element is bound under its position's name",
        "fn main() i32 {\n    let t = (10, true, 'x');\n    let mut s = String::new();\n    inline for f in fields(&t) { s.push_str(f.name); }\n    return if s.as_str() == \"_0_1_2\" { 0; } else { 1; };\n}\n",
        0,
    );
}

// `n` constants in one dependency cycle of items, each reading the one before through two
// functions (C0 = 1, Ci = C(i-1) + 1), declared in increasing order or in decreasing order.
fn hidden_chain(n: i32, down: bool) String {
    let mut s = String::from_str("const fn table(j: u64) u64 {\n    return switch j {\n");
    for i in 0..n {
        s.push_str(format("        {} => C{},\n", i, i).as_str());
    }
    s.push_str("        _ => 0,\n    };\n}\n");
    s.push_str("const fn h(i: u64) u64 {\n    if i == 0 {\n        return 1;\n    }\n    return table(i - 1) + 1;\n}\n");
    for k in 0..n {
        let i = if down {
            n - 1 - k;
        } else {
            k;
        };
        s.push_str(format("const C{}: u64 = h({});\n", i, i).as_str());
    }
    s.push_str(format("fn main() i32 {{ return (C{} % 256) as i32; }}\n", n - 1).as_str());
    return s;
}

fn a_deep_hidden_constant_chain_folds_in_either_order(b: &mut h::ExitBatch) {
    // The constants reach each other through function bodies, so they nest: 100 levels fold
    // whichever constant evaluates first.
    let up = hidden_chain(100, false);
    b.add("a 100-deep chain declared upward", up.as_str(), 100);
    let down = hidden_chain(100, true);
    b.add("a 100-deep chain declared downward", down.as_str(), 100);
}

// A generic function's index list folds when its instance `rot::<k>` first lowers: `A` lowers it
// under 46 interpreted calls, `B` shallow, and the list itself needs k + 1. `with_b` 0: no `B`,
// 1: `A` first, 2: `B` first.
fn deep_lowering_fold(k: i32, with_b: i32) String {
    let mut s = String::from_str(
        M"(import std::simd;
const fn down(n: usize) usize {
    if n == 0 { return 0; }
    return down(n - 1);
}
fn rot<const K: usize>(v: Simd<i32, 4>) Simd<i32, 4> {
    return simd::swizzle(v, [down(K) + 3, 1, 2, 0]);
}
fn nest(n: usize, v: Simd<i32, 4>) i32 {
    if n == 0 { return rot::<30>(v)[0]; }
    return nest(n - 1, v);
}
)",
    );
    let a = "const A: i32 = nest(45, simd::iota::<i32, 4>());\n";
    let b = "const B: i32 = rot::<30>(simd::iota::<i32, 4>())[0];\n";
    if with_b == 0 {
        s.push_str(a);
        s.push_str("fn main() i32 { return A; }\n");
    } else if with_b == 1 {
        s.push_str(a);
        s.push_str(b);
        s.push_str("fn main() i32 { return A + B; }\n");
    } else {
        s.push_str(b);
        s.push_str(a);
        s.push_str("fn main() i32 { return A + B; }\n");
    }
    return s.replace("rot::<30>", format("rot::<{}>", k).as_str());
}

fn a_lowering_fold_deep_in_a_call_stack_folds_in_either_order(b: &mut h::ExitBatch) {
    // The fold has its own call depth: 31 calls fit whatever lowers the instance first.
    let alone = deep_lowering_fold(30, 0);
    b.add("the deep constant alone", alone.as_str(), 3);
    let af = deep_lowering_fold(30, 1);
    b.add("the deep constant first", af.as_str(), 6);
    let bf = deep_lowering_fold(30, 2);
    b.add("the shallow constant first", bf.as_str(), 6);
}

@test
fn a_lowering_fold_past_the_call_limit_fails_in_either_order() {
    // 61 calls exceed the limit itself: `A` fails the same way in both orders.
    let why = "constant 'A' cannot be evaluated at compile time: the index list cannot be evaluated: it traps";
    let af = deep_lowering_fold(60, 1);
    h::expect_err_msg("the deep constant first", af.as_str(), why);
    // `B` traps first there: the build reports `A` after it.
    let bf = deep_lowering_fold(60, 2);
    h::expect_build_err("the shallow constant first", bf.as_str(), why);
}

@test
fn a_constant_reports_its_own_trap_after_a_failed_lowering_fold() {
    // Lowering `pick` folds the build condition, which traps; the constant then traps in `pick`
    // and reports that trap, not the fold's.
    h::expect_build_err(
        "the constant's own trap",
        M"(const ONE: u64 = 1;
const ZERO: u64 = 0;
const fn pick() u64 {
    if PROFILE == "debug" && ONE / ZERO == 0 { return 1; }
    return 2;
}
const X: u64 = pick();
fn main() i32 { return X as i32; }
)",
        "constant 'X' cannot be evaluated at compile time: division by zero (call stack: pick;",
    );
}

fn a_payload_bound_through_a_reference_aliases_the_value(b: &mut h::ExitBatch) {
    // `switch self` on `self: &mut Self` binds the payload of the caller's value, not of a copy:
    // the pushes reach `e`, and the returned reference does not point into the callee's frame.
    b.add(
        "a payload reference writes through",
        M"(enum E { A(i64), B(Vector<i64>) }
extend E {
    fn vec_mut(self: &mut Self) &mut Vector<i64> {
        return switch self { B(v) => v, _ => panic("not B") };
    }
}
fn fill() i64 {
    let mut e = E::B(Vector::<i64>::new());
    let v = e.vec_mut();
    v.push(3);
    v.push(4);
    let w = e.vec_mut();
    return w.len() as i64 + w[1];
}
const F: i64 = fill();
fn main() i32 { return (F + fill()) as i32; }
)",
        12,
    );
}

fn const_fn_memo_keeps_float_arguments_apart(b: &mut h::ExitBatch) {
    // Two calls whose float arguments share an integer part each fold to their own result.
    b.add(
        "float arguments memo apart",
        "const fn twice(x: f64) f64 { return x * 2.0; }\nconst A: f64 = twice(1.25);\nconst B: f64 = twice(1.75);\nfn main() i32 {\n    if A != 2.5 { return 1; }\n    if B != 3.5 { return 2; }\n    return 0;\n}\n",
        0,
    );
}

fn const_fn_repeat_array_fills_every_element(b: &mut h::ExitBatch) {
    // `[v; N]` in a const fn builds N copies of v, not one copy followed by zeros.
    b.add(
        "repeat array folds whole",
        "const fn mk(v: i32) [i32; 3] { return [v; 3]; }\nconst R: [i32; 3] = mk(7);\nfn main() i32 { return R[0] + R[1] + R[2] - 21; }\n",
        0,
    );
}

fn const_fn_memcmp_reads_an_inline_string_buffer(b: &mut h::ExitBatch) {
    // A short String keeps its bytes in an inline array inside the struct, not in a heap block:
    // `memcmp` over it folds like over heap bytes (the lexer's keyword match does exactly this).
    b.add(
        "memcmp over an inline buffer",
        "import string as cstring;\nconst fn same(a: str, b: str) bool { let s = String::from_str(a); return s.len() == b.len() && unsafe cstring::memcmp(s.as_str().ptr(), b.ptr(), b.len()) == 0; }\nstatic_assert(same(\"@bench()\", \"@bench()\"), \"equal bytes\");\nstatic_assert(!same(\"@bench()\", \"@bench]\"), \"a differing byte\");\nfn main() i32 { return 0; }\n",
        0,
    );
}

fn runtime_call_of_a_const_fn_that_cannot_fold(b: &mut h::ExitBatch) {
    // A value of a type with a user `Free` never folds; outside a constant context the call of a
    // `const fn` that builds one runs at run time.
    b.add(
        "a const fn over a const fn that cannot fold",
        "struct P { pub n: i32 }\nextend P as Free { fn free(self: &mut Self) {} }\nextend P { pub const fn new() P { return P { n: 0 }; } }\nconst fn make(x: i32) i32 { let p = P::new(); return p.n + x; }\nfn main() i32 { assert(make(1) == 1, \"one\"); return make(0); }\n",
        0,
    );
}

// `n` scalar constants, each derived from the one before (C0 = 1, Ci = C(i-1) % 7 + 1), then `tail`.
fn const_chain(n: i32, tail: str) String {
    let mut s = String::from_str("const C0: i32 = 1;\n");
    for i in 1..n {
        s.push_str(format("const C{}: i32 = C{} % 7 + 1;\n", i, i - 1).as_str());
    }
    s.push_str(tail);
    return s;
}

fn deep_constant_chain_evaluates_without_nesting(b: &mut h::ExitBatch) {
    // Each constant reads the previous one: evaluating the last must not nest 20000 evaluations
    // on the native stack. C19999 = 19999 % 7 + 1 = 1.
    let src = const_chain(20000, "static_assert(C19999 == 1);\nfn main() i32 { return C19999; }\n");
    b.add("a 20000-constant chain folds", src.as_str(), 1);
}

fn deep_aggregate_constant_chain_evaluates_without_nesting(b: &mut h::ExitBatch) {
    // Aggregate values are never memoized: a 300-deep chain of them still evaluates dependency first.
    let mut s = String::from_str("struct P { pub x: i32, pub y: i32 }\nconst P0: P = P { x: 1, y: 2 };\n");
    for i in 1..300 {
        s.push_str(format("const P{}: P = P {{ x: P{}.y % 7 + 1, y: P{}.x }};\n", i, i - 1, i - 1).as_str());
    }
    s.push_str("fn main() i32 { return P299.x * 10 + P299.y; }\n");
    b.add("a 300-aggregate chain folds", s.as_str(), 53);
}

// A constant of a generic aggregate keeps every instance argument, up to the language's limit of
// eight: struct and enum constants, arrays of them and a `const fn` result all emit as static data.
fn constants_keep_every_instance_argument(b: &mut h::ExitBatch) {
    b.add(
        "five and eight instance arguments",
        M"(struct S5<A, B, C, D, E> { pub a: A, pub b: B, pub c: C, pub d: D, pub e: E }
enum E5<A, B, C, D, E> { V(A, B, C, D, E), W }
struct S8<A, B, C, D, E, F, G, H> { pub a: A, pub b: B, pub c: C, pub d: D, pub e: E, pub f: F, pub g: G, pub h: H }
const K: S5<i32, u8, i16, i64, u16> = S5 { a: 1, b: 2, c: 3, d: 4, e: 5 };
const KE: E5<i32, u8, i16, i64, u16> = E5::V(1, 2, 3, 4, 5);
const KS: [S5<i32, u8, i16, i64, u16>; 2] = [S5 { a: 1, b: 2, c: 3, d: 4, e: 5 }, S5 { a: 1, b: 2, c: 3, d: 4, e: 6 }];
const K8: S8<u8, u16, u32, u64, i8, i16, i32, i64> = S8 { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 };
const fn mk() S5<i32, u8, i16, i64, u16> { return S5 { a: 10, b: 2, c: 3, d: 4, e: 5 }; }
const K2: i32 = mk().a;
fn main() i32 {
    let e = switch KE { V(a, b, c, d, x) => a + b as i32 + c as i32 + d as i32 + x as i32, W => 0 };
    return K.a + K.e as i32 + e + KS[1].e as i32 + K2 + K8.h as i32 + K8.a as i32 - 46;
}
)",
        0,
    );
}

// A constant calls a static method of a generic type whose result is not `Self`: the parameters bind
// from the path, not from the result.
fn a_constant_binds_a_static_method_from_its_path(b: &mut h::ExitBatch) {
    b.add(
        "a static method returning Option<W<K>>",
        M"(struct W<const K: usize> {
    pub x: u64,
}
extend<const K: usize> W<K> {
    pub fn fb(b: u64) Option<W<K>> {
        if b > K as u64 {
            return Option::<W<K>>::None;
        }
        return Option::<W<K>>::Some(W::<K> { x: b });
    }
}
static_assert(W::<4>::fb(5).is_none() && W::<4>::fb(3).is_some(), "K binds to 4");
fn main() i32 {
    return 0;
}
)",
        0,
    );
}

// A repeat literal constant fills every element (`[v; N]` holds the value and the count).
fn a_repeat_constant_fills_every_element(b: &mut h::ExitBatch) {
    b.add(
        "repeat constants",
        "const Y: [f32; 4] = [2.0; 4];\nconst Z: [u64; 3] = [18446744073709551615; 3];\nfn main() i32 {\n    if Y[3] != 2.0 || Y[1] != 2.0 || Z[2] != 18446744073709551615 {\n        return 1;\n    }\n    return 0;\n}\n",
        0,
    );
}

// A scalar's bytes through `*const u8` are not slots of their own: the evaluator neither reports the
// copy as out of bounds nor reads a neighboring local as the next byte.
fn byte_view_of_a_scalar_copies_its_bytes(b: &mut h::ExitBatch) {
    b.add(
        "a u64's bytes appended to a String",
        M"(fn put(s: &mut String, v: u64) {
    let w: u64 = 9;
    s.push_str(unsafe str::from_raw((&v) as *const u64 as *const u8, 8));
    s.push_byte(w as u8);
}
fn main() i32 {
    let mut s = String::new();
    put(&mut s, 0x0102);
    return s.len() as i32 + s.as_str().byte_at(1) as i32 * 10;
}
)",
        19,
    );
}

@test
fn byte_view_of_a_scalar_does_not_fold() {
    // Folding would read the next local (`w`) as byte 1; the evaluator refuses instead.
    h::expect_build_err(
        "a byte view of a scalar has no compile-time value",
        "const fn second(v: u64) u8 {\n    let w: u64 = 9;\n    let p = (&v) as *const u64 as *const u8;\n    return unsafe *(p + 1) + (w as u8) * 0;\n}\nconst A: u8 = second(0x0102);\nfn main() i32 { return A as i32; }\n",
        "cannot be evaluated at compile time",
    );
}

@test
fn reflection_bound_of_a_default_reaches_its_conformances() {
    // The default calls a fields loop declared after it (one dependency cycle with the interface): the
    // loop's bound still reaches every conformance that inherits the default.
    h::expect_build_err(
        "a field without the bound",
        M"(interface Sz {
    fn sz(self: &Self) i32 {
        return sum_fields(self);
    }
}
fn sum_fields<T>(v: &T) i32 {
    let mut n: i32 = 0;
    inline for f in fields(v) {
        n += one(&f.value);
    }
    return n;
}
fn one<V: Sz>(v: &V) i32 {
    return v.sz();
}
extend i32 as Sz {
    fn sz(self: &i32) i32 {
        return 1;
    }
}
@derive(Sz)
struct S {
    pub a: i32,
    pub w: u32,
}
fn main() i32 {
    let s = S { a: 1, w: 7 };
    return s.sz();
}
)",
        "does not satisfy a bound required by the interface's default method 'sz'",
    );
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`):
// a group builds once where each case built alone.
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    tuple_field_binder_names_each_element(&mut b);
    field_binder_over_a_type_without_fields_has_no_copies(&mut b);
    const_fn_memo_keeps_float_arguments_apart(&mut b);
    const_fn_repeat_array_fills_every_element(&mut b);
    const_fn_memcmp_reads_an_inline_string_buffer(&mut b);
    runtime_call_of_a_const_fn_that_cannot_fold(&mut b);
    deep_constant_chain_evaluates_without_nesting(&mut b);
    deep_aggregate_constant_chain_evaluates_without_nesting(&mut b);
    constants_keep_every_instance_argument(&mut b);
    a_constant_binds_a_static_method_from_its_path(&mut b);
    a_repeat_constant_fills_every_element(&mut b);
    a_deep_hidden_constant_chain_folds_in_either_order(&mut b);
    a_lowering_fold_deep_in_a_call_stack_folds_in_either_order(&mut b);
    a_payload_bound_through_a_reference_aliases_the_value(&mut b);
    byte_view_of_a_scalar_copies_its_bytes(&mut b);
    b.run();
}
