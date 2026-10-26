// The LIR optimizer (`lir::opt`) and inliner (`lir::inline`): after `optimize` each body still verifies,
// the evaluator gives the same results, and each transform happens where it is sound and only there.
import lir::ir as *;
import lir::verify as verify;
import lir::print as lprint;
import lir::parse as lparse;
import lir::eval as leval;
import lir::opt as lopt;

// Package text `text` read, then optimized: each body verifies before and after.
fn optimized(text: str) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    let none = Vector::<bool>::new();
    lopt::optimize(&mut after, 1, &none, &none);
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
    let none = Vector::<bool>::new();
    lopt::optimize(&mut p, 1, &sealed, &none);
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
