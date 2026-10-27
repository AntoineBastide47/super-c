// The LIR optimizer (`lir::opt`) and inliner (`lir::inline`): after `optimize` each body still verifies,
// the evaluator gives the same results, and each transform happens where it is sound and only there.
import lir::ir as *;
import lir::verify as verify;
import lir::print as lprint;
import lir::parse as lparse;
import lir::eval as leval;
import lir::opt as lopt;
import lir::inline as il;
import lir::loops as lu;

// Package text `text` read, then optimized: each body verifies before and after.
fn optimized(text: str) (Package, Package) {
    return optimized_fm(text, 0, false);
}

// `optimized` with the float rewrites `fm` (`FM_*`) allowed, and a fused multiply-add when `fma`.
fn optimized_fm(text: str, fm: u8, fma: bool) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.fmath = fm;
    after.fma = fma;
    let none = Vector::<bool>::new();
    lopt::optimize(
        &mut after,
        1,
        &none,
        lopt::Config { inline: il::SPEED, loops: lu::Budgets { peel: 0, version: 0, unswitch: 0 } },
    );
    let mut v = verify::Verifier::new();
    for i in 0..after.syms.len() {
        let s = after.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            let b = &after.bodies[s.def as usize];
            assert(
                v.check(&after, after.spell(s.name), b) && v.check_calls(&after, after.spell(s.name), b),
                v.err.as_str(),
            );
        }
    }
    return before, after;
}

// The text of function `name` of `p`.
fn text_of(p: &Package, name: str) String {
    let mut all = String::new();
    lprint::print_package(p, &mut all);
    let head = format("fn @{}\n", name);
    let at = all.as_str().find(head.as_str());
    assert(at >= 0, head.as_str());
    let rest = all.as_str().slice(at as usize + head.len(), all.len());
    let mut end = rest.len();
    let f = rest.find("\nfn @");
    if f >= 0 {
        end = f as usize + 1;
    }
    let d = rest.find("\ndata @");
    if d >= 0 && d as usize + 1 < end {
        end = d as usize + 1;
    }
    return String::from_str(rest.slice(0, end));
}

// Function `name` of `before` and of `after` on arguments `args` end alike, with value `want`.
fn same_result(before: &Package, after: &Package, name: str, args: []u64, want: u64) {
    let mut e = leval::Eval::new(before);
    let o = e.run(before.find_symbol(name), args);
    let mut e2 = leval::Eval::new(after);
    let o2 = e2.run(after.find_symbol(name), args);
    assert_eq(o.kind, leval::EV_OK);
    assert_eq(o2.kind, leval::EV_OK);
    assert_eq(o.value, want);
    assert_eq(o2.value, want);
}

// A load of a slot whose address does not escape reads the value of the one store that writes its bytes
// and dominates it, across a call; not when the address escapes, nor when another store writes them.
@test
fn a_load_after_the_only_store_of_a_private_slot_reads_the_stored_value() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @opaque fn global noinline
sym @leak fn global noinline
sym @kept fn global
sym @escaped fn global
sym @twice fn global
fn @opaque
  sig () -> void
b0:
  ret
fn @leak
  sig (ptr) -> void
b0(v0: ptr):
  ret
fn @kept
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  call @opaque() : () -> void
  v2 = load.i64 v1 align 3
  ret v2
fn @escaped
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  call @leak(v1) : (ptr) -> void
  v2 = load.i64 v1 align 3
  ret v2
fn @twice
  sig (i64, i8) -> i64
  slot s0 size 8 align 3
b0(v0: i64, v1: i8):
  v2 = slotaddr s0
  v3 = iconst.i64 4
  store v3, v2 align 3
  br v1, b1, b2
b1:
  store v0, v2 align 3
  jmp b2
b2:
  v4 = load.i64 v2 align 3
  ret v4
)",
    );
    assert(!text_of(&a, "kept").contains("load"), "the stored value replaces the load");
    assert(text_of(&a, "escaped").contains("load"), "a call that takes the address may write the slot");
    assert(!text_of(&a, "twice").contains("load"), "two stores reach the load: the merge block takes the value");
    let x: []u64 = [7];
    same_result(&b, &a, "kept", x, 7);
    same_result(&b, &a, "escaped", x, 7);
    let one: []u64 = [9, 1];
    same_result(&b, &a, "twice", one, 9);
    let zero: []u64 = [9, 0];
    same_result(&b, &a, "twice", zero, 4);
}

// A load of an aggregate argument (a copy the callee owns) that nothing writes leaves the loop, though
// the loop stores through another pointer.
@test
fn a_load_of_an_unwritten_aggregate_argument_leaves_its_loop() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sum fn global noinline
sym @main fn global
fn @sum
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = load.i64 v0+8 align 3
  v7 = icmp.ult v4, v6
  br v7, b2, b3
b2:
  store v4, v1 align 3
  v8 = add.i64 v5, v4
  v9 = add.i64 v4, v3
  jmp b1(v9, v8)
b3:
  ret v5
fn @main
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig () -> i64
  slot s0 size 16 align 3
  slot s1 size 8 align 3
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i64 5
  store v2, v0+8 align 3
  v3 = call.i64 @sum(v0, v1) : (l0, ptr) -> i64
  ret v3
)",
    );
    let t = text_of(&a, "sum");
    let ld = t.as_str().find("load");
    let loop_head = t.as_str().find("b1(");
    assert(ld >= 0 && loop_head >= 0 && ld < loop_head, t.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "main", none, 10);
}

// A small callee inlines into its caller; a `noinline` one stays a call.
@test
fn a_small_callee_inlines_and_a_noinline_one_stays_a_call() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @double fn global
sym @keep fn global noinline
sym @caller fn global
fn @double
  sig (i64) -> i64
b0(v0: i64):
  v1 = add.i64 v0, v0
  ret v1
fn @keep
  sig (i64) -> i64
b0(v0: i64):
  v1 = add.i64 v0, v0
  ret v1
fn @caller
  sig (i64) -> i64
b0(v0: i64):
  v1 = call.i64 @double(v0) : (i64) -> i64
  v2 = call.i64 @keep(v1) : (i64) -> i64
  ret v2
)",
    );
    let t = text_of(&a, "caller");
    assert(!t.contains("@double") && t.contains("@keep("), t.as_str());
    let x: []u64 = [3];
    same_result(&b, &a, "caller", x, 12);
}

// The address of a thread-local variable is never one value across a call: the thread may change there
// (a coroutine parks on one thread and resumes on another).
@test
fn a_thread_local_address_is_taken_again_after_a_call() {
    let (_b, a) = optimized(
        M"(lir ptr 8
sym @park fn global noinline
sym @t tls global
sym @both fn global
fn @park
  sig () -> void
b0:
  ret
fn @both
  sig () -> i64
b0:
  v0 = symaddr @t
  v1 = load.i64 v0 align 3
  call @park() : () -> void
  v2 = symaddr @t
  v3 = load.i64 v2 align 3
  v4 = add.i64 v1, v3
  ret v4
data @t size 8 align 3
)",
    );
    let t = text_of(&a, "both");
    let first = t.as_str().find("symaddr @t");
    assert(first >= 0 && t.as_str().slice(first as usize + 1, t.len()).contains("symaddr @t"), t.as_str());
}

// A copy of no byte goes, and checked arithmetic on constants folds with its branch.
@test
fn an_empty_copy_goes_and_checked_constants_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @fold fn global
fn @fold
  sig (ptr, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 0
  memcpy v0, v1, v2
  v3 = iconst.i64 1
  v4 = iconst.i64 2
  v5, v6 = addo.s.i64 v3, v4
  br v6, b1, b2
b1:
  panic "attempt to add with overflow"
b2:
  ret v5
)",
    );
    let t = text_of(&a, "fold");
    assert(
        !t.contains("memcpy") && !t.contains("addo") && !t.contains("panic") && t.contains("iconst.i64 3"),
        t.as_str(),
    );
    let p: []u64 = [0, 0];
    same_result(&b, &a, "fold", p, 3);
}

// A body of a unit with its own module-level assembly inlines into the bodies of its unit only: that
// assembly may give the symbols it calls what a reference from another object cannot carry (a wasm
// import module).
@test
fn a_body_of_a_unit_with_assembly_stays_in_its_unit() {
    let mut err = String::new();
    let mut p = lparse::parse(
        M"(lir ptr 8
sym @ext fn global
sym @leaf fn global
sym @same fn global
sym @other fn global
fn @leaf
  sig (i32) -> void
b0(v0: i32):
  call @ext(v0) : (i32) -> void
  ret
fn @same
  sig (i32) -> void
b0(v0: i32):
  call @leaf(v0) : (i32) -> void
  ret
fn @other
  sig (i32) -> void
b0(v0: i32):
  call @leaf(v0) : (i32) -> void
  ret
)",
        &mut err,
    ).unwrap();
    // `leaf` and `same` in unit 1, which has assembly; `other` in unit 0.
    let units: [(str, u32); 3] = [("leaf", 1), ("same", 1), ("other", 0)];
    for (name, u) in units {
        let k = p.find_symbol(name);
        p.syms.index_mut(k as usize).unit = u;
    }
    let mut sealed = Vector::<bool>::new();
    sealed.push(false);
    sealed.push(true);
    lopt::optimize(
        &mut p,
        1,
        &sealed,
        lopt::Config { inline: il::SPEED, loops: lu::Budgets { peel: 0, version: 0, unswitch: 0 } },
    );
    assert(!text_of(&p, "same").contains("@leaf"), "a body of the same unit inlines it");
    assert(text_of(&p, "other").contains("call @leaf"), "a body of another unit calls it");
}

// A private slot becomes values (`lir::promote`): a loop's counter kept in a slot becomes a parameter of
// the loop header; a structure copied into a slot and read back field by field becomes the source's
// loads; a slot whose address a call takes stays in memory; a slot read on a path no store reaches
// reads the zero of its type there.
@test
fn private_slots_become_values() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @leak fn global noinline
sym @count fn global
sym @copied fn global
sym @escaped fn global
sym @maybe fn global
fn @leak
  sig (ptr) -> void
b0(v0: ptr):
  ret
fn @count
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  store v2, v1 align 3
  jmp b1
b1:
  v3 = load.i64 v1 align 3
  v4 = icmp.ult v3, v0
  br v4, b2, b3
b2:
  v5 = iconst.i64 1
  v6 = add.i64 v3, v5
  store v6, v1 align 3
  jmp b1
b3:
  v7 = load.i64 v1 align 3
  ret v7
fn @copied
  sig (ptr) -> i64
  slot s0 size 16 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 16
  memcpy v1, v0, v2
  v3 = load.i64 v1 align 3
  v4 = load.i64 v1+8 align 3
  v5 = add.i64 v3, v4
  ret v5
fn @escaped
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  call @leak(v1) : (ptr) -> void
  v2 = load.i64 v1 align 3
  ret v2
fn @maybe
  sig (i8, i64) -> i64
  slot s0 size 8 align 3
b0(v0: i8, v1: i64):
  v2 = slotaddr s0
  br v0, b1, b2
b1:
  store v1, v2 align 3
  jmp b2
b2:
  v3 = load.i64 v2 align 3
  ret v3
)",
    );
    assert(!text_of(&a, "count").contains("load"), "the counter is a parameter of the loop header");
    assert(!text_of(&a, "count").contains("store"), "the counter has no store left");
    let c = text_of(&a, "copied");
    assert(!c.contains("memcpy") && !c.contains("v1+8"), "the copy becomes the source's loads");
    assert(text_of(&a, "escaped").contains("store"), "a call takes the address: the slot stays");
    assert(!text_of(&a, "maybe").contains("load"), "a path no store reaches reads zero");
    let x: []u64 = [5];
    same_result(&b, &a, "count", x, 5);
    let y: []u64 = [7];
    same_result(&b, &a, "escaped", y, 7);
    let one: []u64 = [1, 9];
    same_result(&b, &a, "maybe", one, 9);
}

// A copy between two slots of its size merges them (`lir::promote`): the source's last use is the copy
// and the destination's first, the copy in no cycle. Not when the source is read after the copy.
@test
fn a_copy_between_slots_merges_them() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @take fn global noinline
sym @merged fn global
sym @read_after fn global
fn @take
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  v3 = add.i64 v1, v2
  ret v3
fn @merged
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 16
  store v0, v1 align 3
  store v0, v1+8 align 3
  memcpy v2, v1, v3
  v4 = call.i64 @take(v2) : (l0) -> i64
  ret v4
fn @read_after
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 16
  store v0, v1 align 3
  store v0, v1+8 align 3
  memcpy v2, v1, v3
  v4 = call.i64 @take(v2) : (l0) -> i64
  v5 = call.i64 @take(v1) : (l0) -> i64
  v6 = add.i64 v4, v5
  ret v6
)",
    );
    let m = text_of(&a, "merged");
    assert(!m.contains("memcpy") && !m.contains("slot s1"), "the two slots are one");
    assert(text_of(&a, "read_after").contains("memcpy"), "the source is read after the copy");
    let x: []u64 = [3];
    same_result(&b, &a, "merged", x, 6);
    same_result(&b, &a, "read_after", x, 12);
}

// Accesses of one offset whose types have one size and convert share a field (`lir::promote`): a
// pointer read as the integer of its size, 4 bytes under a 4-byte data model, and an integer read as a
// float.
@test
fn fields_of_convertible_types_promote() {
    let (b, a) = optimized(
        M"(lir ptr 4
sym @narrow fn global
sym @bits fn global
fn @narrow
  sig (i32) -> i32
  slot s0 size 4 align 2
b0(v0: i32):
  v1 = slotaddr s0
  v2 = inttoptr.ptr v0
  store v2, v1 align 2
  v3 = load.i32 v1 align 2
  ret v3
fn @bits
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = load.f64 v1 align 3
  v3 = bitcast.i64 v2
  ret v3
)",
    );
    let n = text_of(&a, "narrow");
    assert(!n.contains("load") && !n.contains("store"), "the pointer field is a value");
    assert(!text_of(&a, "bits").contains("load"), "the integer field is read as a float");
    let x: []u64 = [77];
    same_result(&b, &a, "narrow", x, 77);
    same_result(&b, &a, "bits", x, 77);
}

// A copy out of the memory a call writes its aggregate result into merges that memory with the copy's
// destination, which another call reads: the result goes straight to the second call.
@test
fn an_aggregate_result_copied_into_an_argument_merges() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @mk fn global noinline
sym @take fn global noinline
sym @fwd fn global
fn @mk
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  store v0, v1 align 3
  store v0, v1+8 align 3
  ret
fn @take
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  v3 = add.i64 v1, v2
  ret v3
fn @fwd
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 16
  call @mk(v0, v1) : (i64) -> l0
  memcpy v2, v1, v3
  v4 = call.i64 @take(v2) : (l0) -> i64
  ret v4
)",
    );
    let f = text_of(&a, "fwd");
    assert(!f.contains("memcpy") && !f.contains("slot s1"), "one slot holds the result and the argument");
    let x: []u64 = [4];
    same_result(&b, &a, "fwd", x, 8);
}

// The float rewrites `-ffast-math` allows: `x * 1` and `x + 0` go, a division by a constant becomes a
// product by its reciprocal, two constants of an addition chain fold, and a product added becomes one
// fused multiply-add, but for a loop's accumulator, and so does a product less a constant or a constant
// less a product by a constant; none happens without its flag. The values are exact, so the results agree.
@test
fn fast_math_rewrites_float_arithmetic_only_when_allowed() {
    let src = M"(lir ptr 8
sym @f fn global
sym @h fn global
sym @g fn global
sym @acc fn global
sym @sub fn global
fn @f
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x3ff0000000000000
  v2 = fconst.f64 0x0
  v3 = fconst.f64 0x4010000000000000
  v4 = fmul.f64 v0, v1
  v5 = fadd.f64 v4, v2
  v6 = fdiv.f64 v5, v3
  ret v6
fn @h
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x3ff0000000000000
  v2 = fadd.f64 v0, v1
  v3 = fadd.f64 v2, v1
  ret v3
fn @g
  sig (f64, f64, f64) -> f64
b0(v0: f64, v1: f64, v2: f64):
  v3 = fmul.f64 v0, v1
  v4 = fadd.f64 v3, v2
  ret v4
fn @acc
  sig (f64, i64) -> f64
b0(v0: f64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = fconst.f64 0x0
  jmp b1(v2, v4)
b1(v5: i64, v6: f64):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = sitofp.f64 v5
  v9 = fmul.f64 v8, v0
  v10 = fadd.f64 v9, v6
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b3:
  ret v6
fn @sub
  sig (f64, f64) -> f64
b0(v0: f64, v1: f64):
  v2 = fconst.f64 0x3fe8000000000000
  v3 = fconst.f64 0x4000000000000000
  v4 = fmul.f64 v0, v1
  v5 = fsub.f64 v4, v2
  v6 = fmul.f64 v3, v0
  v7 = fsub.f64 v1, v6
  v8 = fadd.f64 v5, v7
  ret v8
)";
    let all = FM_ASSOC | FM_RECIP | FM_FINITE | FM_NSZ | FM_CONTRACT;
    let (b, a) = optimized_fm(src, all, true);
    let f = text_of(&a, "f");
    assert(
        !f.contains("fdiv") && !f.contains("fadd") && f.contains("fmul.f64 v0, v1") && f.contains("0x3fd0000000000000"),
        f.as_str(),
    );
    let h = text_of(&a, "h");
    assert(h.contains("0x4000000000000000") && count_of(&h, "fadd") == 1, h.as_str());
    let g = text_of(&a, "g");
    assert(g.contains("fma.f64") && !g.contains("fadd"), g.as_str());
    let acc = text_of(&a, "acc");
    assert(!acc.contains("fma") && acc.contains("fmul") && acc.contains("fadd"), acc.as_str());
    // 2 * (0 + 1 + 2) = 6.
    let two3: []u64 = [0x4000000000000000, 3];
    same_result(&b, &a, "acc", two3, 0x4018000000000000);
    let sb = text_of(&a, "sub");
    assert(!sb.contains("fsub") && sb.contains("0xbfe8000000000000") && sb.contains("0xc000000000000000"), sb.as_str());
    // (2 * 3 - 0.75) + (3 - 2 * 2) = 4.25.
    let two_three: []u64 = [0x4000000000000000, 0x4008000000000000];
    same_result(&b, &a, "sub", two_three, 0x4011000000000000);
    let eight: []u64 = [0x4020000000000000];
    // 8 / 4 = 2; 8 + 1 + 1 = 10.
    same_result(&b, &a, "f", eight, 0x4000000000000000);
    same_result(&b, &a, "h", eight, 0x4024000000000000);
    // 2 * 3 + 4 = 10.
    let abc: []u64 = [0x4000000000000000, 0x4008000000000000, 0x4010000000000000];
    same_result(&b, &a, "g", abc, 0x4024000000000000);
    let (_, plain) = optimized_fm(src, 0, true);
    assert(text_of(&plain, "f").contains("fdiv") && text_of(&plain, "g").contains("fadd"), "no flag, no rewrite");
    let (_, nofma) = optimized_fm(src, all, false);
    assert(!text_of(&nofma, "g").contains("fma"), "no fused multiply-add on the processor");
}

// The times `text` holds `pat`.
fn count_of(text: &String, pat: str) u32 {
    let mut n: u32 = 0;
    let mut rest = text.as_str();
    let mut at = rest.find(pat);
    // Each step moves past one match.
    while at >= 0 {
        n += 1;
        rest = rest.slice(at as usize + pat.len(), rest.len());
        at = rest.find(pat);
    }
    return n;
}

// A load of an exclusive reference parameter's referent (`ref p0 16 noalias`, a `&mut`) leaves a loop
// whose stores go through other pointers; not when the parameter escapes into a call, nor when it is a
// shared reference, which another pointer may reach.
@test
fn a_load_of_an_exclusive_reference_leaves_a_loop_that_writes_elsewhere() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sink fn global noinline
sym @fill fn global noinline
sym @leaky fn global noinline
sym @shared fn global noinline
sym @drive fn global
fn @sink
  sig (ptr) -> void
b0(v0: ptr):
  ret
fn @fill
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = load.i64 v0+8 align 3
  v6 = icmp.ult v3, v5
  br v6, b2, b3
b2:
  v7 = load.ptr v0 align 3
  v8 = ptradd v7, v3 * 8
  store v5, v8 align 3
  v9 = add.i64 v4, v5
  v10 = add.i64 v3, v2
  jmp b1(v10, v9)
b3:
  ret v4
fn @leaky
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  call @sink(v0) : (ptr) -> void
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = load.i64 v0+8 align 3
  v6 = icmp.ult v3, v5
  br v6, b2, b3
b2:
  v7 = load.ptr v0 align 3
  v8 = ptradd v7, v3 * 8
  store v5, v8 align 3
  v9 = add.i64 v4, v5
  v10 = add.i64 v3, v2
  jmp b1(v10, v9)
b3:
  ret v4
fn @shared
  sig (ptr) -> i64
  ref p0 16
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = load.i64 v0+8 align 3
  v6 = icmp.ult v3, v5
  br v6, b2, b3
b2:
  v7 = load.ptr v0 align 3
  v8 = ptradd v7, v3 * 8
  store v5, v8 align 3
  v9 = add.i64 v4, v5
  v10 = add.i64 v3, v2
  jmp b1(v10, v9)
b3:
  ret v4
fn @drive
  sig () -> i64
  slot s0 size 16 align 3
  slot s1 size 32 align 3
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i64 4
  store v1, v0 align 3
  store v2, v0+8 align 3
  v3 = call.i64 @fill(v0) : (ptr) -> i64
  v4 = call.i64 @leaky(v0) : (ptr) -> i64
  v5 = call.i64 @shared(v0) : (ptr) -> i64
  v6 = add.i64 v3, v4
  v7 = add.i64 v6, v5
  ret v7
)",
    );
    let f = text_of(&a, "fill");
    let at = f.as_str().find("load.i64 v0+8");
    assert(at >= 0 && at < f.as_str().find("b1("), f.as_str());
    let l = text_of(&a, "leaky");
    assert(l.as_str().find("load.i64 v0+8") > l.as_str().find("b1("), l.as_str());
    let s = text_of(&a, "shared");
    assert(s.as_str().find("load.i64 v0+8") > s.as_str().find("b1("), s.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 48);
}

// A branch on a condition a dominating branch decided jumps: the edge into its block fixed the value.
@test
fn a_branch_a_dominating_branch_decided_jumps() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @k fn global
fn @k
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = icmp.ult v0, v1
  br v2, b1, b2
b1:
  ret v0
b2:
  br v2, b3, b4
b3:
  ret v1
b4:
  v3 = add.i64 v0, v1
  ret v3
)",
    );
    let t = text_of(&a, "k");
    let first = t.as_str().find("br ");
    assert(
        first >= 0 && t.as_str().slice(first as usize + 3, t.len()).find("br ") < 0 && !t.contains("ret v1"),
        t.as_str(),
    );
    let lo: []u64 = [1, 3];
    same_result(&b, &a, "k", lo, 1);
    let hi: []u64 = [5, 3];
    same_result(&b, &a, "k", hi, 8);
}
