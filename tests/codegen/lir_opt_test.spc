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
    return optimized_with(text, fm, fma, 0);
}

// `optimized_fm` with `vector` vectors interleaved (`lu::Budgets`): straight-line values pack too.
fn optimized_with(text: str, fm: u8, fma: bool, vector: u32) (Package, Package) {
    return optimized_loops(
        text,
        fm,
        fma,
        lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: vector, fin: 0 },
    );
}

// `optimized_fm` with the loop transforms' budgets `bu`.
fn optimized_loops(text: str, fm: u8, fma: bool, bu: lu::Budgets) (Package, Package) {
    return optimized_cfg(text, fm, fma, il::SPEED, bu);
}

fn optimized_cfg(text: str, fm: u8, fma: bool, inl: il::Budget, bu: lu::Budgets) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.fmath = fm;
    after.fma = fma;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut after, &none, lopt::Config { inline: inl, loops: bu });
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

// The block of body text `t` that byte `at` is in: from its label to the next label.
fn block_at(t: str, at: usize) str {
    let mut from = at;
    // Each step goes back one byte.
    while from > 0 && !(t.byte_at(from - 1) == b'\n' && t.byte_at(from) == b'b') {
        from -= 1;
    }
    let n = t.slice(at, t.len()).find("\nb");
    let to = if n >= 0 {
        at + n as usize;
    } else {
        t.len();
    };
    return t.slice(from, to);
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

// Tail recursion elimination (`Package.tail`): a call of the body's own function whose result its block
// returns becomes a jump back to the body's start; not when a slot's address escapes to another call,
// since each call had a frame of its own.
@test
fn a_call_of_itself_returned_at_once_is_a_loop() {
    let text = M"(lir ptr 8
sym @keep fn global noinline
sym @sum fn global
sym @esc fn global
fn @keep
  sig (ptr) -> void
b0(v0: ptr):
  ret
fn @sum
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v0, v2
  br v3, b1, b2
b1:
  ret v1
b2:
  v4 = iconst.i64 1
  v5 = sub.i64 v0, v4
  v6 = add.i64 v1, v0
  v7 = call.i64 @sum(v5, v6) : (i64, i64) -> i64
  ret v7
fn @esc
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  ret v0
b2:
  v3 = slotaddr s0
  store v0, v3 align 3
  call @keep(v3) : (ptr) -> void
  v4 = iconst.i64 1
  v5 = sub.i64 v0, v4
  v6 = call.i64 @esc(v5) : (i64) -> i64
  ret v6
)";
    let mut err = String::new();
    let before = lparse::parse(text, &mut err).unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.tail = true;
    let none = Vector::<bool>::new();
    lopt::optimize(
        &mut after,
        &none,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 },
        },
    );
    let s = text_of(&after, "sum");
    assert(!s.contains("call"), s.as_str());
    let e = text_of(&after, "esc");
    assert(e.contains("call.i64 @esc"), e.as_str());
    let x: []u64 = [1000, 7];
    same_result(&before, &after, "sum", x, 500507);
    let y: []u64 = [5];
    same_result(&before, &after, "esc", y, 0);
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
  v1 = iconst.i64 5
  store v1, v0 align 3
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
    same_result(&b, &a, "escaped", x, 5);
    let one: []u64 = [9, 1];
    same_result(&b, &a, "twice", one, 9);
    let zero: []u64 = [9, 0];
    same_result(&b, &a, "twice", zero, 4);
}

// A copy of the bytes another copy wrote, no write since, copies from that copy's source (written later,
// so not one slot with the copy's); the first copy then goes, its slot read by nothing else. Not after a store into the source, nor from a move whose
// source and destination overlap (its source holds other bytes after it).
@test
fn a_copy_of_a_copy_reads_the_first_source() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sum fn global noinline
sym @chain fn global
sym @stored fn global
sym @shifted fn global
fn @sum
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  v3 = iconst.i64 1000
  v4 = mul.i64 v2, v3
  v5 = add.i64 v1, v4
  ret v5
fn @chain
  sig (i64, i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
  slot s2 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 16
  store v0, v2 align 3
  store v1, v2+8 align 3
  memcpy.overlap v3, v2, v5
  memcpy.overlap v4, v3, v5
  v6 = iconst.i64 0
  store v6, v2 align 3
  v7 = call.i64 @sum(v4) : (ptr) -> i64
  v8 = call.i64 @sum(v2) : (ptr) -> i64
  v9 = add.i64 v7, v8
  ret v9
fn @stored
  sig (i64, i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
  slot s2 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 16
  store v0, v2 align 3
  store v1, v2+8 align 3
  memcpy v3, v2, v5
  store v1, v2 align 3
  memcpy v4, v3, v5
  v6 = call.i64 @sum(v4) : (ptr) -> i64
  v7 = call.i64 @sum(v2) : (ptr) -> i64
  v8 = add.i64 v6, v7
  ret v8
fn @shifted
  sig (i64, i64) -> i64
  slot s0 size 24 align 3
  slot s1 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 16
  store v0, v2 align 3
  store v1, v2+8 align 3
  store v1, v2+16 align 3
  v5 = ptradd v2+8
  memcpy.overlap v5, v2, v4
  memcpy.overlap v3, v5, v4
  v6 = call.i64 @sum(v3) : (ptr) -> i64
  ret v6
)",
    );
    let c = text_of(&a, "chain");
    let at = c.as_str().find("memcpy");
    assert(at >= 0 && c.as_str().slice(at as usize + 1, c.len()).find("memcpy") < 0, c.as_str());
    let x: []u64 = [7, 9];
    same_result(&b, &a, "chain", x, 9007 + 9000);
    same_result(&b, &a, "stored", x, 9007 + 9009);
    same_result(&b, &a, "shifted", x, 9007);
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
        &sealed,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 },
        },
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

// Loads of an exclusive reference's fields leave a loop that stores only another field through the
// parameter itself (`self.len += 1`, a `Vector` push): `cap` and `data` move out; `len`, which the loop
// also stores, stays in a register across it and is stored back after it (`promote_places`), and so
// does a field the loop stores what it loaded to (`stuck`).
@test
fn loads_of_fields_the_loop_does_not_store_leave_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @count fn global noinline
sym @stuck fn global noinline
sym @drive fn global
fn @count
  sig (ptr) -> i64
  ref p0 24 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1)
b1(v3: i64):
  v4 = load.i64 v0+16 align 3
  v5 = icmp.ult v3, v4
  br v5, b2, b3
b2:
  v6 = load.ptr v0 align 3
  v7 = ptradd v6, v3 * 8
  store v3, v7 align 3
  v8 = load.i64 v0+8 align 3
  v9 = add.i64 v8, v2
  store v9, v0+8 align 3
  v10 = add.i64 v3, v2
  jmp b1(v10)
b3:
  v11 = load.i64 v0+8 align 3
  ret v11
fn @stuck
  sig (ptr) -> i64
  ref p0 24 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1)
b1(v3: i64):
  v4 = load.i64 v0+16 align 3
  v5 = icmp.ult v3, v4
  br v5, b2, b3
b2:
  v6 = load.ptr v0 align 3
  v7 = ptradd v6, v3 * 8
  store v3, v7 align 3
  store v4, v0+16 align 3
  v8 = add.i64 v3, v2
  jmp b1(v8)
b3:
  ret v3
fn @drive
  sig () -> i64
  slot s0 size 24 align 3
  slot s1 size 64 align 3
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i64 0
  v3 = iconst.i64 5
  store v1, v0 align 3
  store v2, v0+8 align 3
  store v3, v0+16 align 3
  v4 = call.i64 @count(v0) : (ptr) -> i64
  v5 = call.i64 @stuck(v0) : (ptr) -> i64
  v6 = load.i64 v1+32 align 3
  v7 = add.i64 v4, v5
  v8 = add.i64 v7, v6
  ret v8
)",
    );
    let c = text_of(&a, "count");
    let head = c.as_str().find("b1(");
    let cap = c.as_str().find("load.i64 v0+16");
    let data = c.as_str().find("load.ptr v0");
    assert(cap >= 0 && cap < head && data >= 0 && data < head, c.as_str());
    let len = c.as_str().find("load.i64 v0+8");
    assert(len >= 0 && len < head && c.as_str().find(", v0+8 align") > head, c.as_str());
    let s = text_of(&a, "stuck");
    let sl = s.as_str().find("load.i64 v0+16");
    assert(sl >= 0 && sl < s.as_str().find("b1("), s.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 14);
}

// Inside `i < 1000`, the bound decides: `i % 4096` is `i`, `i / 2000` is 0, `i >> 10` is 0, `i & 1023` is
// `i`, `i < 5000` holds; `i % 500` stays (its one magic product).
@test
fn a_bound_the_loop_test_sets_folds_remainders_shifts_and_masks() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig () -> i64
b0:
  v0 = iconst.i64 0
  v1 = iconst.i64 1
  v2 = iconst.i64 1000
  v3 = iconst.i64 4096
  v4 = iconst.i64 2000
  v5 = iconst.i64 10
  v6 = iconst.i64 1023
  v7 = iconst.i64 5000
  v8 = iconst.i64 500
  jmp b1(v0, v0)
b1(v9: i64, v10: i64):
  v11 = icmp.ult v9, v2
  br v11, b2, b3
b2:
  v12 = urem.i64 v9, v3
  v13 = udiv.i64 v9, v4
  v14 = lshr.i64 v9, v5
  v15 = and.i64 v9, v6
  v16 = icmp.ult v9, v7
  v17 = zext.i64 v16
  v18 = urem.i64 v9, v8
  v19 = add.i64 v12, v13
  v20 = add.i64 v19, v14
  v21 = add.i64 v20, v15
  v22 = add.i64 v21, v17
  v23 = add.i64 v22, v18
  v24 = add.i64 v10, v23
  v25 = add.i64 v9, v1
  jmp b1(v25, v24)
b3:
  ret v10
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "mulhu") == 1 && count_of(&t, "udiv") == 0 && count_of(&t, "icmp.ult") <= 1, t.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "f", none, 1249500);
}

// A store that a later store to the same bytes overwrites, with no read between, goes (`@rng`: one
// store of the state stays); a load between (`@peek`) or a copy that reads the place (`@copy`, which
// becomes a load and a store) keeps it.
@test
fn a_store_a_later_store_overwrites_goes() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @rng fn global noinline
sym @peek fn global noinline
sym @copy fn global noinline
sym @drive fn global
fn @rng
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 13
  v2 = iconst.i64 7
  v3 = load.i64 v0 align 3
  v4 = shl.i64 v3, v1
  v5 = xor.i64 v3, v4
  store v5, v0 align 3
  v6 = lshr.i64 v5, v2
  v7 = xor.i64 v5, v6
  store v7, v0 align 3
  ret v7
fn @peek
  sig (ptr, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 5
  v3 = iconst.i64 9
  store v2, v0 align 3
  v4 = load.i64 v1 align 3
  store v3, v0 align 3
  ret v4
fn @copy
  sig (ptr, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 5
  v3 = iconst.i64 9
  v4 = iconst.i64 8
  store v2, v0 align 3
  memcpy v1, v0, v4
  store v3, v0 align 3
  v5 = load.i64 v1 align 3
  ret v5
fn @drive
  sig () -> i64
  slot s0 size 8 align 3
  slot s1 size 8 align 3
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i64 3
  store v2, v0 align 3
  v3 = call.i64 @rng(v0) : (ptr) -> i64
  v4 = call.i64 @peek(v0, v0) : (ptr, ptr) -> i64
  v5 = call.i64 @copy(v0, v1) : (ptr, ptr) -> i64
  v6 = load.i64 v0 align 3
  v7 = add.i64 v3, v4
  v8 = add.i64 v7, v5
  v9 = add.i64 v8, v6
  ret v9
)",
    );
    let r = text_of(&a, "rng");
    assert(count_of(&r, "store") == 1, r.as_str());
    let p = text_of(&a, "peek");
    assert(count_of(&p, "store") == 2, p.as_str());
    let c = text_of(&a, "copy");
    assert(count_of(&c, "store v2") == 1, c.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 24790);
}

// Type tags (`-fstrict-aliasing`): a tagged load leaves a loop whose only writes have another tag, and
// reads the value a store with its tag wrote across a store of another tag; an untagged store keeps both
// loads where they are.
@test
fn a_tagged_load_passes_stores_of_another_type() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @fill fn global noinline
sym @fwd fn global noinline
sym @fwd_any fn global noinline
sym @drive fn global
fn @fill
  sig (ptr) -> i64
  ref p0 16
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = fconst.f64 0x4000000000000000
  jmp b1(v1)
b1(v4: i64):
  v5 = load.i64 v0+8 align 3 tbaa 4
  v6 = icmp.ult v4, v5
  br v6, b2, b3
b2:
  v7 = load.ptr v0 align 3 tbaa 8
  v8 = ptradd v7, v4 * 8
  store v3, v8 align 3 tbaa 7
  v9 = add.i64 v4, v2
  jmp b1(v9)
b3:
  ret v4
fn @fwd
  sig (ptr, ptr, i64) -> i64
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = fconst.f64 0x3ff0000000000000
  store v2, v0 align 3 tbaa 4
  store v3, v1 align 3 tbaa 7
  v4 = load.i64 v0 align 3 tbaa 4
  ret v4
fn @fwd_any
  sig (ptr, ptr, i64) -> i64
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = fconst.f64 0x3ff0000000000000
  store v2, v0 align 3 tbaa 4
  store v3, v1 align 3
  v4 = load.i64 v0 align 3 tbaa 4
  ret v4
fn @drive
  sig () -> i64
  slot s0 size 16 align 3
  slot s1 size 32 align 3
  slot s2 size 8 align 3
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = slotaddr s2
  v3 = iconst.i64 4
  store v1, v0 align 3
  store v3, v0+8 align 3
  v4 = call.i64 @fill(v0) : (ptr) -> i64
  v5 = iconst.i64 7
  v6 = call.i64 @fwd(v2, v1, v5) : (ptr, ptr, i64) -> i64
  v7 = call.i64 @fwd_any(v2, v1, v5) : (ptr, ptr, i64) -> i64
  v8 = load.i64 v1+24 align 3
  v9 = add.i64 v4, v6
  v10 = add.i64 v9, v7
  v11 = add.i64 v10, v8
  ret v11
)",
    );
    let f = text_of(&a, "fill");
    let at = f.as_str().find("load.i64 v0+8");
    assert(at >= 0 && at < f.as_str().find("b1("), f.as_str());
    assert(f.as_str().find("load.ptr") < f.as_str().find("b1("), f.as_str());
    assert(!text_of(&a, "fwd").contains("load"), text_of(&a, "fwd").as_str());
    assert(text_of(&a, "fwd_any").contains("load"), text_of(&a, "fwd_any").as_str());
    // 4 iterations, 7 twice, and the bits of 2.0 in the last element.
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 4 + 14 + 0x4000000000000000);
}

// A slot's address that a branch picks against null becomes a select (`diamond`) passed to a call: the
// call reads the slot, so the store into it stays.
@test
fn a_slot_a_select_passes_to_a_call_keeps_its_stores() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @read fn global noinline
sym @pick fn global
fn @read
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.ptr 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  v3 = iconst.i64 0
  ret v3
b2:
  v4 = load.i64 v0 align 3
  ret v4
fn @pick
  sig (i64, i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.ptr 0
  v4 = iconst.i64 0
  store v1, v2 align 3
  v5 = icmp.sge v0, v4
  br v5, b1, b2
b1:
  jmp b3(v2)
b2:
  jmp b3(v3)
b3(v6: ptr):
  v7 = call.i64 @read(v6) : (ptr) -> i64
  ret v7
)",
    );
    let p = text_of(&a, "pick");
    assert(p.contains("select.ptr") && p.contains("store"), p.as_str());
    let yes: []u64 = [1, 42];
    same_result(&b, &a, "pick", yes, 42);
    let no: []u64 = [0xFFFFFFFFFFFFFFFF, 42];
    same_result(&b, &a, "pick", no, 0);
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

// A branch whose sides reach one block through empty blocks becomes a select; a loop over the lesser of
// two lengths drops its counter's checks against each (`i <u min(a, b)` decides `i <u a`, `i >=u b`), not
// against the greater one; a side with an instruction that may trap stays a branch.
@test
fn a_minimum_becomes_a_select_whose_bound_decides_checks() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sum fn global
sym @big fn global
sym @arm fn global
fn @sum
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ult v0, v1
  br v4, b1, b2
b1:
  jmp b3(v0)
b2:
  jmp b3(v1)
b3(v5: i64):
  jmp b4(v2, v2)
b4(v6: i64, v7: i64):
  v8 = icmp.ult v6, v5
  br v8, b5, b9
b5:
  v9 = icmp.ult v6, v0
  br v9, b6, b8
b6:
  v10 = icmp.uge v6, v1
  br v10, b8, b7
b7:
  v11 = add.i64 v7, v6
  v12 = add.i64 v6, v3
  jmp b4(v12, v11)
b8: cold
  panic "index out of bounds"
b9:
  ret v7
fn @big
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ult v0, v1
  br v4, b1, b2
b1:
  jmp b3(v1)
b2:
  jmp b3(v0)
b3(v5: i64):
  jmp b4(v2, v2)
b4(v6: i64, v7: i64):
  v8 = icmp.ult v6, v5
  br v8, b5, b8
b5:
  v9 = icmp.ult v6, v0
  br v9, b6, b7
b6:
  v10 = add.i64 v7, v6
  v11 = add.i64 v6, v3
  jmp b4(v11, v10)
b7: cold
  panic "index out of bounds"
b8:
  ret v7
fn @arm
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = icmp.ult v0, v1
  br v3, b1, b2
b1:
  v4 = udiv.i64 v0, v1
  jmp b3(v4)
b2:
  jmp b3(v1)
b3(v5: i64):
  ret v5
)",
    );
    let s = text_of(&a, "sum");
    assert(s.contains("select.i64") && !s.contains("panic") && count_of(&s, "icmp") == 2, s.as_str());
    let short_first: []u64 = [3, 5];
    same_result(&b, &a, "sum", short_first, 3);
    let short_second: []u64 = [5, 3];
    same_result(&b, &a, "sum", short_second, 3);
    let g = text_of(&a, "big");
    assert(g.contains("select.i64") && g.contains("panic") && count_of(&g, "icmp") == 3, g.as_str());
    let equal: []u64 = [4, 4];
    same_result(&b, &a, "big", equal, 6);
    let r = text_of(&a, "arm");
    assert(!r.contains("select") && r.contains("br "), r.as_str());
    let greater: []u64 = [9, 7];
    same_result(&b, &a, "arm", greater, 7);
    let lesser: []u64 = [2, 7];
    same_result(&b, &a, "arm", lesser, 0);
}

// Jump threading: a `&&` join whose flag an edge fixes is passed by that edge, and a jump into it becomes
// a branch on its argument; an `Option` tag a side fixes skips its test (a small join of pure
// instructions its switch alone reads), while the side whose target reads the join's values keeps it.
@test
fn an_edge_that_decides_a_join_passes_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @both fn global
sym @tag fn global
fn @both
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ne v0, v2
  br v3, b1, b2(v3)
b1:
  v4 = icmp.ne v1, v2
  jmp b2(v4)
b2(v5: i8):
  br v5, b3, b4
b3:
  ret v0
b4:
  ret v1
fn @tag
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 10
  v2 = iconst.i8 0
  v3 = iconst.i8 1
  v4 = icmp.ult v0, v1
  br v4, b1, b2
b1:
  v5 = add.i64 v0, v1
  jmp b3(v3, v5)
b2:
  jmp b3(v2, v0)
b3(v6: i8, v7: i64):
  v8 = zext.i32 v6
  switch v8 [0 -> b4] else b5
b4:
  ret v1
b5:
  ret v7
)",
    );
    let t = text_of(&a, "both");
    assert(!t.contains(": i8)") && count_of(&t, "br ") == 2, t.as_str());
    let x: []u64 = [1, 2];
    same_result(&b, &a, "both", x, 1);
    let y: []u64 = [0, 2];
    same_result(&b, &a, "both", y, 2);
    let z: []u64 = [3, 0];
    same_result(&b, &a, "both", z, 0);
    let g = text_of(&a, "tag");
    assert(!g.contains("switch"), g.as_str());
    let some: []u64 = [3];
    same_result(&b, &a, "tag", some, 13);
    let none: []u64 = [12];
    same_result(&b, &a, "tag", none, 10);
}

// If-conversion takes sides of up to SPEC_MAX instructions that cannot fault (a load inside a reference
// parameter's bytes), and a join's parameter every edge passes one value for is that value; a load a
// diamond between two of them leaves unwritten is the first one's value, and a store of the value its
// place holds goes.
@test
fn speculated_sides_and_unwritten_memory_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @len fn global noinline
sym @twice fn global noinline
sym @self_copy fn global noinline
sym @drive fn global
fn @len
  sig (ptr) -> i64
  ref p0 24 noalias
b0(v0: ptr):
  v1 = iconst.i8 -128
  v2 = iconst.i8 0
  v3 = load.i8 v0+23 align 0
  v4 = and.i8 v3, v1
  v5 = icmp.ne v4, v2
  br v5, b1, b2
b1:
  v6 = load.i64 v0+8 align 3
  jmp b3(v6, v0)
b2:
  v7 = zext.i64 v3
  jmp b3(v7, v0)
b3(v8: i64, v9: ptr):
  v10 = load.i8 v9+23 align 0
  v11 = zext.i64 v10
  v12 = add.i64 v8, v11
  ret v12
fn @twice
  sig (ptr, i64, i64) -> i64
  ref p0 8
b0(v0: ptr, v1: i64, v2: i64):
  v3 = load.i64 v0 align 3
  v4 = iconst.i64 0
  v5 = icmp.ne v2, v4
  br v5, b1, b2
b1:
  v6 = udiv.i64 v1, v2
  jmp b3(v6)
b2:
  jmp b3(v1)
b3(v7: i64):
  v8 = load.i64 v0 align 3
  v9 = add.i64 v7, v8
  v10 = add.i64 v9, v3
  ret v10
fn @self_copy
  sig (ptr) -> i64
  ref p0 16
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  store v1, v0 align 3
  store v2, v0+8 align 3
  v3 = add.i64 v1, v2
  ret v3
fn @drive
  sig (i64, i64, i64) -> i64
  slot s0 size 24 align 3
b0(v0: i64, v1: i64, v2: i64):
  v3 = slotaddr s0
  v4 = iconst.i64 7
  store v4, v3 align 3
  store v4, v3+8 align 3
  v5 = trunc.i8 v0
  store v5, v3+23 align 0
  v6 = call.i64 @len(v3) : (ptr) -> i64
  v7 = call.i64 @twice(v3, v1, v2) : (ptr, i64, i64) -> i64
  v8 = call.i64 @self_copy(v3) : (ptr) -> i64
  v9 = load.i64 v3 align 3
  v10 = add.i64 v6, v7
  v11 = add.i64 v10, v8
  v12 = add.i64 v11, v9
  ret v12
)",
    );
    let l = text_of(&a, "len");
    assert(!l.contains("br ") && l.contains("select.i64") && count_of(&l, "load.i8") == 1, l.as_str());
    let w = text_of(&a, "twice");
    assert(w.contains("udiv") && count_of(&w, "load.i64") == 1, w.as_str());
    assert(!text_of(&a, "self_copy").contains("store"), text_of(&a, "self_copy").as_str());
    // An inline length 5 (5 + 5), 10 / 2 (5 + 7 + 7), 7 + 7, and the slot's first word 7.
    let inline: []u64 = [5, 10, 2];
    same_result(&b, &a, "drive", inline, 10 + 19 + 14 + 7);
    // A heap length 7 with the tag byte 0x80 (7 + 128), and no division by 0 (10 + 7 + 7).
    let heap: []u64 = [0x80, 10, 0];
    same_result(&b, &a, "drive", heap, 135 + 24 + 14 + 7);
}

// Arithmetic rewrites: a product, quotient or remainder by a power of two is a shift or a mask; a quotient
// or remainder by another constant is a high product (`mulhu`, with the fix-up of a multiplier wider
// than the type for 7); a flag picked as 1 or 0 is the flag, as 0 or 1 or negated the opposite
// comparison; an ordering a `cmp` gives, compared with 0, is the comparison; a pointer turned into an
// integer and back is the pointer.
@test
fn constants_turn_arithmetic_into_cheaper_forms() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @p2 fn global
sym @digits fn global
sym @flags fn global
sym @lt fn global
sym @round fn global
fn @p2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 8
  v2 = mul.i64 v0, v1
  v3 = udiv.i64 v0, v1
  v4 = urem.i64 v0, v1
  v5 = add.i64 v2, v3
  v6 = add.i64 v5, v4
  ret v6
fn @digits
  sig (i64, i32, i8) -> i64
b0(v0: i64, v1: i32, v2: i8):
  v3 = iconst.i64 10
  v4 = iconst.i32 1000
  v5 = iconst.i8 7
  v6 = iconst.i64 7
  v7 = udiv.i64 v0, v3
  v8 = urem.i32 v1, v4
  v9 = urem.i8 v2, v5
  v10 = udiv.i64 v0, v6
  v11 = zext.i64 v8
  v12 = zext.i64 v9
  v13 = add.i64 v7, v11
  v14 = add.i64 v13, v12
  v15 = add.i64 v14, v10
  ret v15
fn @flags
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i8 1
  v3 = iconst.i8 0
  v4 = icmp.ult v0, v1
  v5 = select.i8 v4, v2, v3
  v6 = select.i8 v4, v3, v2
  v7 = xor.i8 v4, v2
  v8 = zext.i64 v5
  v9 = zext.i64 v6
  v10 = zext.i64 v7
  v11 = add.i64 v8, v9
  v12 = add.i64 v11, v10
  ret v12
fn @lt
  sig (i64, i64) -> i8
b0(v0: i64, v1: i64):
  v2 = iconst.i32 -1
  v3 = iconst.i32 1
  v4 = iconst.i32 0
  v5 = icmp.ult v0, v1
  v6 = icmp.ugt v0, v1
  v7 = select.i32 v6, v3, v4
  v8 = select.i32 v5, v2, v7
  v9 = icmp.slt v8, v4
  ret v9
fn @round
  sig (ptr) -> ptr
b0(v0: ptr):
  v1 = ptrtoint.i64 v0
  v2 = inttoptr.ptr v1
  ret v2
)",
    );
    let p = text_of(&a, "p2");
    assert(!p.contains("mul.") && !p.contains("udiv") && !p.contains("urem"), p.as_str());
    let x: []u64 = [100];
    same_result(&b, &a, "p2", x, 816);
    let d = text_of(&a, "digits");
    assert(!d.contains("udiv") && !d.contains("urem") && d.contains("mulhu"), d.as_str());
    let small: []u64 = [12345, 123456, 200];
    same_result(&b, &a, "digits", small, 1234 + 456 + 4 + 1763);
    let top: []u64 = [0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF, 0xFF];
    same_result(&b, &a, "digits", top, 1844674407370955161 + 295 + 3 + 2635249153387078802);
    let f = text_of(&a, "flags");
    assert(!f.contains("select") && !f.contains("xor"), f.as_str());
    let below: []u64 = [1, 2];
    same_result(&b, &a, "flags", below, 1);
    let above: []u64 = [2, 1];
    same_result(&b, &a, "flags", above, 2);
    let o = text_of(&a, "lt");
    assert(!o.contains("select"), o.as_str());
    same_result(&b, &a, "lt", below, 1);
    same_result(&b, &a, "lt", above, 0);
    let equal: []u64 = [2, 2];
    same_result(&b, &a, "lt", equal, 0);
    assert(!text_of(&a, "round").contains("inttoptr"), text_of(&a, "round").as_str());
}

// A branch whose sides join a block other edges enter too becomes a select on its own edge; a loop
// header's constant leaves the loop.
@test
fn a_diamond_joins_a_shared_block_and_a_header_constant_leaves() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @three fn global
sym @cnt fn global
fn @three
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 100
  v4 = icmp.eq v1, v2
  br v4, b4(v3), b1
b1:
  v5 = icmp.ult v0, v1
  br v5, b2, b3
b2:
  jmp b4(v0)
b3:
  jmp b4(v1)
b4(v6: i64):
  ret v6
fn @cnt
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  jmp b1(v1, v1)
b1(v2: i64, v3: i64):
  v4 = iconst.i64 3
  v5 = icmp.ult v2, v0
  br v5, b2, b3
b2:
  v6 = add.i64 v3, v4
  v7 = iconst.i64 1
  v8 = add.i64 v2, v7
  jmp b1(v8, v6)
b3:
  ret v3
)",
    );
    let t = text_of(&a, "three");
    assert(t.contains("select.i64"), t.as_str());
    let zero: []u64 = [5, 0];
    same_result(&b, &a, "three", zero, 100);
    let lesser: []u64 = [2, 7];
    same_result(&b, &a, "three", lesser, 2);
    let greater: []u64 = [9, 7];
    same_result(&b, &a, "three", greater, 7);
    let c = text_of(&a, "cnt");
    let k = c.as_str().find("iconst.i64 3");
    assert(k >= 0 && k < c.as_str().find("b1("), c.as_str());
    let four: []u64 = [4];
    same_result(&b, &a, "cnt", four, 12);
}

// The inliner keeps the caller's reference parameters' bytes and exclusivity.
@test
fn an_inlining_caller_keeps_its_references() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @callee fn global
sym @caller fn global
fn @callee
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = add.i64 v0, v1
  ret v2
fn @caller
  sig (ptr) -> i64
  ref p0 8 noalias
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = call.i64 @callee(v1) : (i64) -> i64
  ret v2
)",
    );
    let t = text_of(&a, "caller");
    assert(t.contains("ref p0 8 noalias") && !t.contains("call"), t.as_str());
    let _ = b;
}

// An inlined call's exclusive view keeps its exclusivity in its copy (`Body.scopes`): a load the copy
// makes through another pointer leaves the caller's loop past the copy's stores through the view, whose
// element pointer the loop does not change; when the loop makes a new view each iteration, the load stays.
// (A call needs a location for its copy to have a site.)
@test
fn an_inlined_exclusive_view_stays_exclusive_in_its_copy() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "view.spc"
sym @bump fn global
sym @same fn global noinline
sym @moving fn global noinline
sym @top fn global
fn @bump
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, ptr) -> void
  ref p0 0 inner noalias
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v1 align 3
  v4 = load.i64 v2 align 3
  v5 = add.i64 v4, v3
  store v5, v2 align 3
  ret
fn @same
  file f0
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (ptr, ptr, i64) -> void
  ref p1 8
  slot s0 size 16 align 3
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = slotaddr s0
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  store v0, v3 align 3
  store v5, v3+8 align 3
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  call @bump(v3, v1) : (l0, ptr) -> void !7:5
  v8 = add.i64 v6, v5
  jmp b1(v8)
b3:
  ret
fn @moving
  file f0
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (ptr, ptr, i64) -> void
  ref p1 8
  slot s0 size 16 align 3
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = slotaddr s0
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v0, v6 * 8
  store v8, v3 align 3
  store v5, v3+8 align 3
  call @bump(v3, v1) : (l0, ptr) -> void !9:5
  v9 = add.i64 v6, v5
  jmp b1(v9)
b3:
  ret
fn @top
  sig (i64) -> i64
  slot s0 size 32 align 3
  slot s1 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 3
  store v3, v1 align 3
  store v3, v1+8 align 3
  store v3, v1+16 align 3
  store v3, v1+24 align 3
  store v0, v2 align 3
  call @same(v1, v2, v4) : (ptr, ptr, i64) -> void
  call @moving(v1, v2, v4) : (ptr, ptr, i64) -> void
  v5 = load.i64 v1 align 3
  v6 = load.i64 v1+8 align 3
  v7 = load.i64 v1+16 align 3
  v8 = add.i64 v5, v6
  v9 = add.i64 v8, v7
  ret v9
)",
    );
    let s = text_of(&a, "same");
    let at = s.as_str().find("load.i64 v1");
    assert(!s.contains("call") && s.contains("scope") && at >= 0 && at < s.as_str().find("b1("), s.as_str());
    let m = text_of(&a, "moving");
    let mt = m.as_str().find("load.i64 v1");
    assert(!m.contains("call") && mt > m.as_str().find("b1("), m.as_str());
    // Element 0: 3 x 5 from `same`, then 5 from `moving`; elements 1 and 2: 5 each.
    let x: []u64 = [5];
    same_result(&b, &a, "top", x, 20 + 5 + 5);
}

// A function's memory effects come from its body (`Sym.fx`, a fixed point over the calls; a block that
// ends the program counts for nothing): a load passes a call of one that writes no memory, two calls of
// one that touches none with the same arguments are one, and two of one that reads memory are one only
// when nothing was written between them.
@test
fn calls_take_the_memory_effects_of_their_bodies() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sq fn global noinline
sym @peek fn global noinline
sym @poke fn global noinline
sym @checked fn global noinline
sym @fwd fn global
sym @cse fn global
sym @reread fn global
fn @sq
  sig (i64) -> i64
b0(v0: i64):
  v1 = mul.i64 v0, v0
  ret v1
fn @peek
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  ret v1
fn @poke
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i64 9
  store v1, v0 align 3
  ret
fn @checked
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 100
  v2 = icmp.ult v0, v1
  br v2, b1, b2
b1:
  v3 = call.i64 @sq(v0) : (i64) -> i64
  ret v3
b2: cold
  panic "too big"
fn @fwd
  sig (ptr) -> i64
  ref p0 8
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = call.i64 @peek(v0) : (ptr) -> i64
  v3 = call.i64 @checked(v1) : (i64) -> i64
  v4 = load.i64 v0 align 3
  v5 = add.i64 v2, v3
  v6 = add.i64 v5, v4
  ret v6
fn @cse
  sig (i64) -> i64
b0(v0: i64):
  v1 = call.i64 @sq(v0) : (i64) -> i64
  v2 = call.i64 @sq(v0) : (i64) -> i64
  v3 = add.i64 v1, v2
  ret v3
fn @reread
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = call.i64 @peek(v0) : (ptr) -> i64
  v2 = call.i64 @peek(v0) : (ptr) -> i64
  call @poke(v0) : (ptr) -> void
  v3 = call.i64 @peek(v0) : (ptr) -> i64
  v4 = add.i64 v1, v2
  v5 = add.i64 v4, v3
  ret v5
)",
    );
    let f = text_of(&a, "fwd");
    assert(count_of(&f, "load.i64") == 1, f.as_str());
    let c = text_of(&a, "cse");
    assert(count_of(&c, "call") == 1, c.as_str());
    let r = text_of(&a, "reread");
    assert(count_of(&r, "@peek") == 2 && r.contains("@poke"), r.as_str());
    let _ = b;
}

// A value's bits read as another type and back are the value.
@test
fn a_bitcast_round_trip_is_the_value() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (f64) -> f64
b0(v0: f64):
  v1 = bitcast.i64 v0
  v2 = bitcast.f64 v1
  ret v2
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("bitcast"), t.as_str());
    let x: []u64 = [0x4009_21FB_5444_2D18];
    same_result(&b, &a, "f", x, 0x4009_21FB_5444_2D18);
}

// A loop that a branch enters gets a preheader before the walk, which hoists into it a load the loop
// does not write: here a field of the aggregate the caller passes, read through a constant offset.
@test
fn a_load_leaves_a_loop_a_branch_enters() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (l0, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ne v1, v2
  br v4, b1(v2, v2), b2(v2)
b1(v5: i64, v6: i64):
  v7 = ptradd v0+8
  v8 = load.i64 v7 align 3
  v9 = add.i64 v6, v8
  v10 = add.i64 v5, v3
  v11 = icmp.ult v10, v1
  br v11, b1(v10, v9), b2(v9)
b2(v12: i64):
  ret v12
fn @top
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (i64) -> i64
  slot s0 size 24 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 5
  store v2, v1+8 align 3
  v3 = call.i64 @f(v1, v0) : (l0, i64) -> i64
  ret v3
)",
    );
    let t = text_of(&a, "f");
    // The load sits in a block of no parameters: the preheader, not the loop.
    let mut label = "";
    let mut ok = false;
    for line in t.as_str().split("\n") {
        if line.starts_with("b") {
            label = line;
        } else if line.contains("load.i64") {
            ok = !label.contains("(");
        }
    }
    assert(ok, t.as_str());
    let x: []u64 = [4];
    same_result(&b, &a, "top", x, 20);
}

// A copy of 8 bytes is a load and a store; the load reads the copy's source slot, so the store that
// fills that slot stays.
@test
fn a_small_copy_is_a_load_and_a_store() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @g fn global noinline
sym @f fn global
fn @g
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  ret v1
fn @f
  sig (i64) -> i64
  slot s0 size 8 align 3
  slot s1 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  store v0, v1 align 3
  v3 = iconst.i64 8
  memcpy v2, v1, v3
  v4 = call.i64 @g(v2) : (ptr) -> i64
  ret v4
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("memcpy") && t.contains("store v0"), t.as_str());
    let x: []u64 = [42];
    same_result(&b, &a, "f", x, 42);
}

// A slot whose address only addresses loads, stores, copies and fills (an index included) is private:
// no other pointer reaches it, so a store into it leaves the loads of other memory as they were.
@test
fn a_store_to_a_private_slot_keeps_other_loads() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, i64) -> i64
  slot s0 size 64 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = load.i64 v0 align 3
  v4 = ptradd v2, v1 * 8
  store v3, v4 align 3
  v5 = load.i64 v0 align 3
  v6 = load.i64 v4 align 3
  v7 = add.i64 v5, v6
  ret v7
fn @top
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = iconst.i64 3
  v3 = call.i64 @f(v1, v2) : (ptr, i64) -> i64
  ret v3
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "load.i64 v0") == 1, t.as_str());
    let x: []u64 = [21];
    same_result(&b, &a, "top", x, 42);
}

// Four stores to consecutive addresses of sums of loads from consecutive addresses become one vector
// store of one vector sum of two vector loads (`lir::slp`).
@test
fn consecutive_stores_of_sums_become_vectors() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, ptr) -> i32
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v1 align 2
  v3 = load.i32 v1+4 align 2
  v4 = load.i32 v1+8 align 2
  v5 = load.i32 v1+12 align 2
  v6 = load.i32 v1+16 align 2
  v7 = load.i32 v1+20 align 2
  v8 = load.i32 v1+24 align 2
  v9 = load.i32 v1+28 align 2
  v10 = add.i32 v2, v6
  v11 = add.i32 v3, v7
  v12 = add.i32 v4, v8
  v13 = add.i32 v5, v9
  store v10, v0 align 2
  store v11, v0+4 align 2
  store v12, v0+8 align 2
  store v13, v0+12 align 2
  v14 = load.i32 v0+8 align 2
  ret v14
fn @top
  sig (i32) -> i32
  slot s0 size 32 align 4
  slot s1 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i32 1
  v4 = add.i32 v0, v3
  store v0, v1+8 align 2
  store v4, v1+24 align 2
  v5 = call.i32 @f(v2, v1) : (ptr, ptr) -> i32
  ret v5
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "add.v4i32") == 1 && count_of(&t, "load.v4i32") == 2 && count_of(&t, "store ") == 1, t.as_str());
    let x: []u64 = [20];
    same_result(&b, &a, "top", x, 41);
}

// A loop's carried values whose start values are loads from consecutive addresses stay one vector across
// the back edge; the stores after the loop become one.
@test
fn a_loops_carried_values_pack_into_a_vector() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, ptr, i32) -> void
b0(v0: ptr, v1: ptr, v2: i32):
  v3 = load.i32 v0 align 2
  v4 = load.i32 v0+4 align 2
  v5 = load.i32 v0+8 align 2
  v6 = load.i32 v0+12 align 2
  v7 = load.i32 v1 align 2
  v8 = load.i32 v1+4 align 2
  v9 = load.i32 v1+8 align 2
  v10 = load.i32 v1+12 align 2
  v11 = iconst.i32 0
  v12 = iconst.i32 1
  jmp b1(v3, v4, v5, v6, v11)
b1(v13: i32, v14: i32, v15: i32, v16: i32, v17: i32):
  v18 = add.i32 v13, v7
  v19 = add.i32 v14, v8
  v20 = add.i32 v15, v9
  v21 = add.i32 v16, v10
  v22 = add.i32 v17, v12
  v23 = icmp.slt v22, v2
  br v23, b1(v18, v19, v20, v21, v22), b2
b2:
  store v18, v0 align 2
  store v19, v0+4 align 2
  store v20, v0+8 align 2
  store v21, v0+12 align 2
  ret
fn @top
  sig (i32) -> i32
  slot s0 size 16 align 4
  slot s1 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i32 3
  store v0, v1+4 align 2
  store v0, v2+4 align 2
  call @f(v1, v2, v3) : (ptr, ptr, i32) -> void
  v4 = load.i32 v1+4 align 2
  ret v4
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "add.v4i32") == 1 && count_of(&t, ": v4i32") == 1 && count_of(&t, "store ") == 1, t.as_str());
    let x: []u64 = [10];
    same_result(&b, &a, "top", x, 40);
}

// Two sums of unrelated values stored side by side stay scalar: gathering their operands costs more than
// the one addition and store the vectors save.
@test
fn a_pack_that_gathers_its_operands_stays_scalar() {
    let (_, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr, i64, i64, i64, i64) -> void
b0(v0: ptr, v1: i64, v2: i64, v3: i64, v4: i64):
  v5 = add.i64 v1, v2
  v6 = add.i64 v3, v4
  store v5, v0 align 3
  store v6, v0+8 align 3
  ret
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(!t.contains("v2i64") && count_of(&t, "store ") == 2, t.as_str());
}

// A comparison with its constant first reads with the constant second (unsigned `0 < x` is `x != 0`); a
// shift left and right by one constant (either order) is a mask.
@test
fn compares_put_constants_second_and_shift_pairs_mask() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ult v2, v0
  v4 = iconst.i64 8
  v5 = shl.i64 v1, v4
  v6 = lshr.i64 v5, v4
  v7 = lshr.i64 v1, v4
  v8 = shl.i64 v7, v4
  v9 = add.i64 v6, v8
  v10 = select.i64 v3, v9, v2
  ret v10
)",
    );
    let t = text_of(&a, "f");
    assert(
        t.contains("icmp.ne v0,") && !t.contains("shl") && !t.contains("lshr") && count_of(&t, "and.i64 v1") == 2,
        t.as_str(),
    );
    let x: []u64 = [1, 0x0102030405060708];
    same_result(&b, &a, "f", x, 73190125542837768);
    let z: []u64 = [0, 0x0102030405060708];
    same_result(&b, &a, "f", z, 0);
}

// A slot's address at a constant index is a field's (`lir::promote`): the loop carries the field as a
// value, and the slot goes.
@test
fn a_slot_at_a_constant_index_becomes_a_value() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i32) -> i32
  slot s0 size 16 align 2
b0(v0: i32):
  v1 = slotaddr s0
  v2 = iconst.i64 3
  v3 = ptradd v1, v2 * 4
  v4 = iconst.i32 0
  v5 = iconst.i32 1
  store v4, v3 align 2
  jmp b1(v4)
b1(v6: i32):
  v7 = load.i32 v3 align 2
  v8 = add.i32 v7, v0
  store v8, v3 align 2
  v9 = add.i32 v6, v5
  v10 = icmp.slt v9, v0
  br v10, b1(v9), b2
b2:
  v11 = load.i32 v3 align 2
  ret v11
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("slot") && !t.contains("load"), t.as_str());
    let x: []u64 = [5];
    same_result(&b, &a, "f", x, 25);
}

// A loop whose only writes go to a private slot leaves the loads of other memory unchanged: they leave
// the loop.
@test
fn a_loop_writing_a_private_slot_hoists_other_loads() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, i64) -> i64
  ref p0 8
  slot s0 size 64 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 7
  jmp b1(v3)
b1(v6: i64):
  v7 = load.i64 v0 align 3
  v8 = and.i64 v6, v5
  v9 = ptradd v2, v8 * 8
  store v7, v9 align 3
  v10 = add.i64 v6, v4
  v11 = icmp.slt v10, v1
  br v11, b1(v10), b2
b2:
  v12 = load.i64 v2 align 3
  ret v12
fn @top
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = iconst.i64 3
  v3 = call.i64 @f(v1, v2) : (ptr, i64) -> i64
  ret v3
)",
    );
    let t = text_of(&a, "f");
    let at = t.as_str().find("load.i64 v0");
    let loop_at = t.as_str().find("b1(");
    assert(at >= 0 && loop_at >= 0 && at < loop_at, t.as_str());
    let x: []u64 = [42];
    same_result(&b, &a, "top", x, 42);
}

// A loop that writes a private slot keeps that slot's loads: a counter kept in it counts.
@test
fn a_loop_writing_a_private_slot_keeps_its_loads() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, i64) -> i64
  slot s0 size 32 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i8 32
  store v3, v2+16 align 3
  jmp b1
b1:
  v6 = load.i64 v2+16 align 3
  v7 = icmp.ult v6, v1
  br v7, b2, b4
b2:
  v8 = ptradd v0, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v5
  br v10, b3, b4
b3:
  v11 = load.i64 v2+16 align 3
  v12 = add.i64 v11, v4
  store v12, v2+16 align 3
  jmp b1
b4:
  v13 = load.i64 v2+16 align 3
  ret v13
fn @top
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = iconst.i64 8
  v3 = call.i64 @f(v1, v2) : (ptr, i64) -> i64
  ret v3
)",
    );
    let x: []u64 = [0x2020202041202020];
    same_result(&b, &a, "top", x, 3);
}

// A parser's position kept in a structure on the caller's frame, advanced by an inlined loop with an
// inner loop, at -O3's budgets: the loops keep reading it.
@test
fn an_inlined_scanner_keeps_its_position() {
    let (b, a) = optimized_cfg(
        M"(lir ptr 8
file f0 "scan.spc"
sym @skip fn global
sym @run fn global noinline
sym @top fn global
fn @skip
  sig (ptr, i8) -> void
  ref p0 32 noalias
b0(v0: ptr, v1: i8):
  v2 = iconst.i8 32
  v3 = iconst.i8 9
  v4 = iconst.i8 13
  v5 = iconst.i8 10
  v6 = iconst.i8 35
  v7 = iconst.i64 1
  v8 = load.ptr v0 align 3 tbaa 8
  jmp b1
b1:
  v9 = load.i64 v0+8 align 3 tbaa 4
  v10 = load.i64 v0+16 align 3 tbaa 4
  v11 = icmp.ult v10, v9
  br v11, b2, b7
b2:
  v12 = ptradd v8, v10 * 1
  v13 = load.i8 v12 align 0
  v14 = icmp.eq v13, v2
  br v14, b13, b3
b3:
  v15 = icmp.eq v13, v3
  br v15, b13, b4
b4:
  v16 = icmp.eq v13, v4
  br v16, b13, b5
b5:
  v17 = icmp.eq v13, v5
  br v17, b12, b6
b6:
  v18 = icmp.eq v13, v6
  br v18, b14, b7
b7:
  ret
b8:
  v19 = load.i64 v0+8 align 3 tbaa 4
  v20 = load.i64 v0+16 align 3 tbaa 4
  v21 = icmp.ult v20, v19
  br v21, b9, b10(v21)
b9:
  v22 = ptradd v8, v20 * 1
  v23 = load.i8 v22 align 0
  v24 = icmp.ne v23, v5
  jmp b10(v24)
b10(v25: i8):
  br v25, b11, b1
b11:
  v26 = add.i64 v20, v7
  store v26, v0+16 align 3 tbaa 4
  jmp b8
b12:
  v27 = add.i64 v10, v7
  store v27, v0+16 align 3 tbaa 4
  jmp b1
b13:
  v28 = add.i64 v10, v7
  store v28, v0+16 align 3 tbaa 4
  jmp b1
b14:
  jmp b8
fn @run
  file f0
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i8) -> i64
  slot s0 size 32 align 3
  slot s1 size 32 align 3
b0(v0: ptr, v1: i8):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 16
  v5 = iconst.i64 0
  v6 = iconst.i32 0
  v7 = iconst.i64 32
  memcpy.overlap v3, v0, v4
  store v5, v3+16 align 3
  store v6, v3+24 align 2
  memcpy.overlap v2, v3, v7
  call @skip(v2, v1) : (ptr, i8) -> void !40:5
  v8 = load.i32 v2+24 align 2 tbaa 3
  v9 = zext.i64 v8
  v10 = load.i64 v2+16 align 3 tbaa 4
  v11 = add.i64 v10, v9
  ret v11
fn @top
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  store v0, v2 align 3
  store v2, v1 align 3
  v3 = iconst.i64 8
  store v3, v1+8 align 3
  v4 = iconst.i8 1
  v5 = call.i64 @run(v1, v4) : (l0, i8) -> i64
  ret v5
)",
        0,
        false,
        il::FAST,
        lu::Budgets { peel: 300, partial: 0, version: 200, unswitch: 50, rotate: 8, vector: 4, fin: 0 },
    );
    let x: []u64 = [0x2020202041202020];
    same_result(&b, &a, "top", x, 3);
}

// A call that writes only through its arguments (`FX_ARG`) writes nothing of its caller's when the
// caller passes its own slot: the caller reads only, so its two calls with one argument give one value. A
// caller that passes its parameter writes through it: its two calls stay.
@test
fn writes_through_arguments_stay_in_the_callers_frame() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @set fn global noinline
sym @get fn global noinline
sym @bump fn global noinline
sym @f fn global
sym @g fn global
fn @set
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  store v1, v0 align 3
  ret
fn @get
  sig (ptr) -> i64
  slot s0 size 8 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = load.i64 v0 align 3
  call @set(v1, v2) : (ptr, i64) -> void
  v3 = load.i64 v1 align 3
  ret v3
fn @bump
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  call @set(v0, v3) : (ptr, i64) -> void
  ret v3
fn @f
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @get(v1) : (ptr) -> i64
  v3 = call.i64 @get(v1) : (ptr) -> i64
  v4 = add.i64 v2, v3
  ret v4
fn @g
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @bump(v1) : (ptr) -> i64
  v3 = call.i64 @bump(v1) : (ptr) -> i64
  v4 = add.i64 v2, v3
  ret v4
)",
    );
    let tf = text_of(&a, "f");
    let tg = text_of(&a, "g");
    assert(count_of(&tf, "call.i64 @get") == 1, tf.as_str());
    assert(count_of(&tg, "call.i64 @bump") == 2, tg.as_str());
    let x: []u64 = [20];
    same_result(&b, &a, "f", x, 40);
    same_result(&b, &a, "g", x, 43);
}

// A call of a function that only reads, first in its loop's header with arguments from outside the loop,
// which writes no memory, leaves the loop: the preheader runs it once.
@test
fn a_reading_call_leaves_a_loop_that_writes_nothing() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @rd fn global noinline
sym @f fn global noinline
sym @top fn global
fn @rd
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  ret v1
fn @f
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = call.i64 @rd(v0) : (ptr) -> i64
  v7 = add.i64 v5, v6
  v8 = add.i64 v4, v3
  v9 = icmp.slt v8, v1
  br v9, b1(v8, v7), b2
b2:
  ret v7
fn @top
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = iconst.i64 5
  v3 = call.i64 @f(v1, v2) : (ptr, i64) -> i64
  ret v3
)",
    );
    let t = text_of(&a, "f");
    let at = t.as_str().find("call.i64 @rd");
    let loop_at = t.as_str().find("b1(");
    assert(at >= 0 && loop_at >= 0 && at < loop_at, t.as_str());
    let x: []u64 = [7];
    same_result(&b, &a, "top", x, 35);
}

// A branch a constant decides leaves one edge into the join: its argument, defined in a block that does
// not dominate the join, is not final when the walk enters the join (here a load the copy before it
// forwards, which leaves the copy's store dead), so the join's parameter keeps its edges.
@test
fn a_join_keeps_an_argument_its_block_does_not_dominate() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @mk fn global noinline
sym @f fn global
fn @mk
  layout l0 size 16 align 3 [0 i8, 8 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  v2 = iconst.i8 0
  store v2, v1 align 0
  store v0, v1+8 align 3
  ret
fn @f
  layout l0 size 16 align 3 [0 i8, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
  slot s2 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 16
  v5 = iconst.i64 8
  v6 = iconst.i64 0
  call @mk(v0, v1) : (i64) -> l0
  memcpy.overlap v2, v1, v4
  v7 = ptradd v2+8
  memcpy.overlap v3, v7, v5
  v8 = icmp.eq v5, v6
  br v8, b2(v6), b1
b1:
  v9 = load.i64 v3 align 3
  jmp b2(v9)
b2(v10: i64):
  ret v10
)",
    );
    let x: []u64 = [42];
    same_result(&b, &a, "f", x, 42);
}

// A loop's carried values pack into a vector whose start values are unrelated: they gather through
// memory at the end of the block that enters the loop, and the gather's stores stay.
@test
fn a_gather_at_a_blocks_end_keeps_its_stores() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, i32, i32) -> void
b0(v0: ptr, v1: i32, v2: i32):
  v3 = iconst.i32 1
  v4 = add.i32 v1, v3
  v5 = mul.i32 v1, v1
  v6 = sub.i32 v1, v3
  v7 = iconst.i32 0
  jmp b1(v1, v4, v5, v6, v7)
b1(v8: i32, v9: i32, v10: i32, v11: i32, v12: i32):
  v13 = add.i32 v8, v2
  v14 = add.i32 v9, v2
  v15 = add.i32 v10, v2
  v16 = add.i32 v11, v2
  v17 = add.i32 v12, v3
  v18 = icmp.slt v17, v2
  br v18, b1(v13, v14, v15, v16, v17), b2
b2:
  store v13, v0 align 2
  store v14, v0+4 align 2
  store v15, v0+8 align 2
  store v16, v0+12 align 2
  ret
fn @top
  sig (i32) -> i32
  slot s0 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = iconst.i32 4
  call @f(v1, v0, v2) : (ptr, i32, i32) -> void
  v3 = load.i32 v1+8 align 2
  v4 = load.i32 v1+12 align 2
  v5 = add.i32 v3, v4
  ret v5
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(t.contains("add.v4i32"), t.as_str());
    let x: []u64 = [3];
    same_result(&b, &a, "top", x, 43);
}

// A choice between the sides of an equality on them is one side: `x != y ? x : y` is `x`.
@test
fn a_select_of_an_equalitys_sides_is_one_side() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = icmp.ne v0, v1
  v3 = select.i64 v2, v0, v1
  v4 = icmp.eq v0, v1
  v5 = select.i64 v4, v0, v1
  v6 = add.i64 v3, v5
  ret v6
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("select"), t.as_str());
    let x: []u64 = [5, 7];
    same_result(&b, &a, "f", x, 12);
}

// A probe loop that stops on a match or an empty slot (its control byte 0), then a merge that tests that
// byte for `None`: every edge into the merge settles the test (the loop runs only with a byte the branch
// into it found nonzero; the other edges leave on a byte found 0), so the test goes. Without the branch
// into the loop (`open`) the loop's byte is unknown and the test stays.
@test
fn an_option_test_the_branches_into_its_block_settle_goes() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @find fn global
sym @open fn global
fn @find
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i8 0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 3
  v6 = trunc.i8 v0
  v7 = icmp.ne v6, v2
  br v7, b1(v3, v6), b3(v6, v3)
b1(v8: i64, v9: i8):
  v10 = mul.i64 v8, v5
  v11 = icmp.eq v10, v1
  br v11, b3(v9, v8), b2
b2:
  v12 = add.i64 v8, v4
  v13 = sub.i64 v0, v12
  v14 = trunc.i8 v13
  v15 = icmp.ne v14, v2
  br v15, b1(v12, v14), b3(v14, v12)
b3(v16: i8, v17: i64):
  v18 = icmp.eq v16, v2
  br v18, b4, b5
b4:
  v19 = iconst.i64 -1
  ret v19
b5:
  ret v17
fn @open
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i8 0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 3
  v6 = trunc.i8 v0
  v7 = iconst.i64 7
  jmp b1(v3, v6)
b1(v8: i64, v9: i8):
  v10 = mul.i64 v8, v5
  v11 = icmp.eq v10, v1
  br v11, b3(v9, v8), b2
b2:
  v12 = add.i64 v8, v4
  v13 = sub.i64 v0, v12
  v14 = trunc.i8 v13
  v15 = icmp.ne v14, v2
  br v15, b1(v12, v14), b3(v14, v12)
b3(v16: i8, v17: i64):
  v18 = icmp.eq v16, v2
  br v18, b4, b5
b4:
  v19 = iconst.i64 -1
  ret v19
b5:
  ret v17
)",
    );
    let t = text_of(&a, "find");
    assert(count_of(&t, "icmp.eq") == 1, t.as_str());
    let o = text_of(&a, "open");
    assert(count_of(&o, "icmp.eq") >= 2, o.as_str());
    // (n, key, want): the slot whose key (3 times its index) matches, or -1 past the n used slots.
    let cases: []u64 = [
        10,
        9,
        3,
        10,
        10,
        (-1i64) as u64,
        0,
        0,
        (-1i64) as u64,
        10,
        27,
        9,
        10,
        30,
        (-1i64) as u64,
        300,
        9,
        3,
    ];
    for k in 0..cases.len() / 3 {
        let x: []u64 = [cases[3 * k], cases[3 * k + 1]];
        same_result(&b, &a, "find", x, cases[3 * k + 2]);
    }
    // `open` probes its first slot on any byte: a match there with the byte 0 is still `None`.
    let y: []u64 = [0, 0];
    same_result(&b, &a, "open", y, (-1i64) as u64);
    let z: []u64 = [10, 9];
    same_result(&b, &a, "open", z, 3);
}

// A load at the start of a loop's header, before anything that may leave or trap, runs on every entry
// into the loop: it leaves the loop though its address may fault (a view's element), when the loop's
// stores keep apart from it (the exclusive view's elements).
@test
fn a_load_each_iteration_starts_with_leaves_its_loop() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, l0) -> i64
  ref p0 0 inner noalias
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 0
  v3 = iconst.i64 3
  v4 = iconst.i64 1
  v5 = load.i64 v0+8 align 3 tbaa 4
  v6 = load.ptr v0 align 3 tbaa 8
  v7 = load.ptr v1 align 3 tbaa 8
  v8 = icmp.ne v5, v2
  br v8, b1(v2, v2), b2(v2)
b1(v9: i64, v10: i64):
  v11 = load.i64 v7 align 3 tbaa 4
  v12 = ptradd v6, v9 * 8
  v13 = load.i64 v12 align 3 tbaa 4
  v14 = mul.i64 v13, v3
  store v14, v12 align 3 tbaa 4
  v15 = add.i64 v10, v11
  v16 = add.i64 v9, v4
  v17 = icmp.ult v16, v5
  br v17, b1(v16, v15), b2(v15)
b2(v18: i64):
  ret v18
)",
    );
    let t = text_of(&a, "f");
    let at = t.as_str().find("b1(");
    let end = t.as_str().find("\nb2(");
    assert(at >= 0 && end > at && !t.as_str().slice(at as usize, end as usize).contains("load.i64 v7"), t.as_str());
    let _ = b;
}

// Folds of comparisons and addresses: an unsigned order against 0 is a constant; a select of 1 or 0 on a
// comparison is the comparison widened; a widened comparison against 0 is the opposite comparison; on
// the edge where `x == y` holds, `y - x` is 0; a constant offset or a constant added to an index joins
// the access's offset; the bytes of a word loaded one by one are one load; two stores of constants side
// by side are one; a call of a forwarder on a failure path is the call it forwards to; a select of a
// constant 0 or 1 or another flag on a flag is one operation on the flags; a narrower load of a stored
// integer is its bytes shifted down.
@test
fn comparisons_addresses_and_neighbouring_accesses_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @order0 fn global
sym @widen fn global
sym @negated fn global
sym @room fn global
sym @field fn global
sym @next fn global
sym @word fn global
sym @zeros fn global
sym @fwd fn global
sym @sink fn global
sym @guard fn global
sym @iszero fn global
sym @flagsel fn global
sym @narrow fn global
fn @order0
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.ult v0, v1
  v3 = icmp.uge v0, v1
  v4 = zext.i64 v2
  v5 = zext.i64 v3
  v6 = add.i64 v4, v5
  ret v6
fn @widen
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = icmp.ult v0, v1
  v5 = select.i64 v4, v2, v3
  ret v5
fn @negated
  sig (i64, i64) -> i8
b0(v0: i64, v1: i64):
  v2 = iconst.i32 0
  v3 = icmp.ult v0, v1
  v4 = zext.i32 v3
  v5 = icmp.eq v4, v2
  ret v5
fn @room
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 7
  v4 = icmp.eq v0, v1
  br v4, b1, b3
b1:
  v5 = sub.i64 v1, v0
  v6 = icmp.uge v5, v2
  br v6, b3, b2
b2:
  ret v3
b3:
  ret v2
fn @field
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = ptradd v0+8
  v2 = load.i64 v1 align 3
  ret v2
fn @next
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  v4 = ptradd v0, v3 * 8
  v5 = load.i64 v4 align 3
  ret v5
fn @word
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 8
  v2 = iconst.i64 16
  v3 = iconst.i64 24
  v4 = iconst.i64 32
  v5 = iconst.i64 40
  v6 = iconst.i64 48
  v7 = iconst.i64 56
  v8 = load.i8 v0 align 0
  v9 = load.i8 v0+1 align 0
  v10 = load.i8 v0+2 align 0
  v11 = load.i8 v0+3 align 0
  v12 = load.i8 v0+4 align 0
  v13 = load.i8 v0+5 align 0
  v14 = load.i8 v0+6 align 0
  v15 = load.i8 v0+7 align 0
  v16 = zext.i64 v8
  v17 = zext.i64 v9
  v18 = zext.i64 v10
  v19 = zext.i64 v11
  v20 = zext.i64 v12
  v21 = zext.i64 v13
  v22 = zext.i64 v14
  v23 = zext.i64 v15
  v24 = shl.i64 v17, v1
  v25 = shl.i64 v18, v2
  v26 = shl.i64 v19, v3
  v27 = shl.i64 v20, v4
  v28 = shl.i64 v21, v5
  v29 = shl.i64 v22, v6
  v30 = shl.i64 v23, v7
  v31 = or.i64 v16, v24
  v32 = or.i64 v31, v25
  v33 = or.i64 v32, v26
  v34 = or.i64 v33, v27
  v35 = or.i64 v34, v28
  v36 = or.i64 v35, v29
  v37 = or.i64 v36, v30
  ret v37
fn @zeros
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i32 0
  v2 = iconst.i32 -1
  store v2, v0 align 2
  store v1, v0+4 align 2
  ret
fn @fwd
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> void
b0(v0: ptr):
  v1 = load.ptr v0 align 3
  v2 = load.i64 v0+8 align 3
  call @sink(v1, v2) : (ptr, i64) -> void
  unreachable
fn @sink
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  ret
fn @guard
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (i64, ptr) -> i64
  slot s0 size 16 align 3
b0(v0: i64, v1: ptr):
  v2 = iconst.i64 9
  v3 = icmp.ult v0, v2
  br v3, b2, b1
b1: cold
  v4 = slotaddr s0
  store v1, v4 align 3
  store v0, v4+8 align 3
  call @fwd(v4) : (l0) -> void
  unreachable
b2:
  ret v0
fn @iszero
  sig (ptr) -> i8
  ref p0 16
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = load.i64 v0 align 3
  v3 = icmp.ne v2, v1
  br v3, b2, b1
b1:
  v4 = load.i64 v0+8 align 3
  v5 = icmp.eq v4, v1
  jmp b3(v5)
b2:
  v6 = iconst.i8 0
  jmp b3(v6)
b3(v7: i8):
  ret v7
fn @flagsel
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i8 0
  v4 = iconst.i8 1
  v5 = icmp.ne v0, v2
  v6 = icmp.eq v1, v2
  v7 = select.i8 v5, v3, v6
  v8 = select.i8 v5, v4, v6
  v9 = select.i8 v5, v6, v3
  v10 = select.i8 v5, v6, v4
  v11 = zext.i64 v7
  v12 = zext.i64 v8
  v13 = zext.i64 v9
  v14 = zext.i64 v10
  v15 = iconst.i64 1
  v16 = iconst.i64 2
  v17 = iconst.i64 3
  v18 = shl.i64 v12, v15
  v19 = shl.i64 v13, v16
  v20 = shl.i64 v14, v17
  v21 = or.i64 v11, v18
  v22 = or.i64 v21, v19
  v23 = or.i64 v22, v20
  ret v23
fn @narrow
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = load.i32 v1+4 align 2 tbaa 3
  v3 = load.i16 v1+1 align 0
  v4 = zext.i64 v2
  v5 = zext.i64 v3
  v6 = add.i64 v4, v5
  ret v6
)",
    );
    let iz = text_of(&a, "iszero");
    assert(!iz.contains("select") && !iz.contains("br "), iz.as_str());
    let nw = text_of(&a, "narrow");
    assert(!nw.contains("load") && !nw.contains("slot"), nw.as_str());
    let word: []u64 = [0x1122334455667788];
    same_result(&b, &a, "narrow", word, 0x11223344 + 0x6677);
    let fs = text_of(&a, "flagsel");
    assert(!fs.contains("select"), fs.as_str());
    // Bits: `c ? 0 : f`, `c ? 1 : f`, `c ? f : 0`, `c ? f : 1`, with c = v0 != 0 and f = v1 == 0.
    let c0f0: []u64 = [0, 1];
    same_result(&b, &a, "flagsel", c0f0, 8);
    let c0f1: []u64 = [0, 0];
    same_result(&b, &a, "flagsel", c0f1, 1 | 2 | 8);
    let c1f0: []u64 = [5, 1];
    same_result(&b, &a, "flagsel", c1f0, 2);
    let c1f1: []u64 = [5, 0];
    same_result(&b, &a, "flagsel", c1f1, 2 | 4 | 8);
    let o = text_of(&a, "order0");
    assert(!o.contains("icmp"), o.as_str());
    let x: []u64 = [5];
    same_result(&b, &a, "order0", x, 1);
    let w = text_of(&a, "widen");
    assert(!w.contains("select") && w.contains("zext"), w.as_str());
    let lo: []u64 = [1, 2];
    let hi: []u64 = [2, 1];
    same_result(&b, &a, "widen", lo, 1);
    same_result(&b, &a, "widen", hi, 0);
    let n = text_of(&a, "negated");
    assert(!n.contains("zext") && n.contains("icmp.uge"), n.as_str());
    same_result(&b, &a, "negated", lo, 0);
    same_result(&b, &a, "negated", hi, 1);
    let r = text_of(&a, "room");
    assert(!r.contains("sub."), r.as_str());
    same_result(&b, &a, "room", lo, 1);
    let eq: []u64 = [3, 3];
    same_result(&b, &a, "room", eq, 7);
    let f = text_of(&a, "field");
    assert(!f.contains("ptradd") && f.contains("load.i64 v0+8"), f.as_str());
    let nx = text_of(&a, "next");
    assert(!nx.contains("add.") && nx.contains("+8"), nx.as_str());
    let wd = text_of(&a, "word");
    assert(!wd.contains("load.i8") && !wd.contains("or.") && wd.contains("load.i64 v0"), wd.as_str());
    let z = text_of(&a, "zeros");
    assert(z.contains("store") && !z.contains("v0+4"), z.as_str());
    let g = text_of(&a, "guard");
    assert(g.contains("call @sink") && !g.contains("call @fwd"), g.as_str());
    let small: []u64 = [4, 0];
    same_result(&b, &a, "guard", small, 4);
}

// A loop that reads and writes a place through an exclusive pointer from outside it, and touches no other
// byte of it, keeps the place in a register: one load before the loop, one store after it, each loop of
// a body its own place; not when the loop also writes through a pointer that may be the same.
@test
fn a_loop_keeps_an_exclusive_place_in_a_register() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @mix fn global noinline
sym @mixany fn global noinline
sym @twice fn global noinline
sym @top fn global
fn @mix
  sig (ptr, ptr, i64) -> void
  ref p0 8 noalias
  ref p1 24
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 31
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 8
  v9 = load.i64 v8 align 3
  v10 = load.i64 v0 align 3
  v11 = mul.i64 v10, v5
  v12 = add.i64 v11, v9
  store v12, v0 align 3
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @mixany
  sig (ptr, ptr, i64) -> void
  ref p0 8
  ref p1 24
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 31
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 8
  v9 = load.i64 v8 align 3
  v10 = load.i64 v0 align 3
  v11 = mul.i64 v10, v5
  v12 = add.i64 v11, v9
  store v12, v0 align 3
  store v12, v8 align 3
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @twice
  sig (ptr, i64) -> void
  ref p0 16 noalias
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2)
b1(v4: i64):
  v5 = icmp.ult v4, v1
  br v5, b2, b3(v2)
b2:
  v6 = load.i64 v0 align 3
  v7 = add.i64 v6, v4
  store v7, v0 align 3
  v8 = add.i64 v4, v3
  jmp b1(v8)
b3(v9: i64):
  v10 = icmp.ult v9, v1
  br v10, b4, b5
b4:
  v11 = load.i64 v0+8 align 3
  v12 = load.i64 v0 align 3
  v13 = add.i64 v11, v12
  store v13, v0+8 align 3
  v14 = add.i64 v9, v3
  jmp b3(v14)
b5:
  ret
fn @top
  sig (i64) -> i64
  slot s0 size 8 align 3
  slot s1 size 24 align 3
  slot s2 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 2
  v4 = iconst.i64 3
  v5 = iconst.i64 5
  v6 = iconst.i64 3
  store v0, v1 align 3
  store v3, v2 align 3
  store v4, v2+8 align 3
  store v5, v2+16 align 3
  call @mix(v1, v2, v6) : (ptr, ptr, i64) -> void
  call @mixany(v1, v2, v6) : (ptr, ptr, i64) -> void
  v7 = load.i64 v1 align 3
  v8 = load.i64 v2+16 align 3
  v9 = add.i64 v7, v8
  v10 = slotaddr s2
  store v0, v10 align 3
  store v0, v10+8 align 3
  call @twice(v10, v6) : (ptr, i64) -> void
  v11 = load.i64 v10+8 align 3
  v12 = add.i64 v9, v11
  ret v12
)",
    );
    // The loop's body: the block of the multiplication.
    let m = text_of(&a, "mix");
    let mul = m.as_str().find("mul.i64");
    assert(mul >= 0 && m.as_str().find("load.i64 v0") >= 0, m.as_str());
    let body = block_at(m.as_str(), mul as usize);
    assert(!body.contains(", v0 ") && !body.contains("load.i64 v0"), m.as_str());
    let n = text_of(&a, "mixany");
    let nmul = n.as_str().find("mul.i64");
    assert(nmul >= 0 && block_at(n.as_str(), nmul as usize).contains("load.i64 v0"), n.as_str());
    // mix: x = ((x * 31 + 2) * 31 + 3) * 31 + 5; mixany: the same again, each element set to the running
    // value, the last of which it returns beside x.
    let x: []u64 = [1];
    let m1 = ((1u64 * 31 + 2) * 31 + 3) * 31 + 5;
    let e0 = m1 * 31 + 2;
    let e1 = e0 * 31 + 3;
    let e2 = e1 * 31 + 5;
    // twice: x + 0 + 1 + 2 into the first field, then the second field adds it three times.
    let w = text_of(&a, "twice");
    assert(!w.contains("slot"), w.as_str());
    same_result(&b, &a, "top", x, e2 + e2 + 1 + 3 * 4);
}
