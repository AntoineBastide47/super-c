// The Core IR inliner over generic code: in vector code, a call of an interface method through a type
// parameter inlines in each instance (the instance's bound variant; in scalar code, a call whose result
// the instance fixes) and in a concrete caller the generic callee inlines into, a callee reading module constants inlines, its `switch` on a
// const-generic parameter keeping the one arm its binding takes; and a callee whose count is the
// caller's own const-generic parameter inlines into the caller's shared body. A parameter reads its
// argument in place unless the callee can reach the argument's storage, and the emitter folds
// single-use values into indexes, call arguments and check operands. Each program runs the same
// without inlining.
import tests::harness as h;

// `src` runs the same with and without inlining (`h::expect_same_output`), and the inlined build exits
// with `code` (`h::expect_exit`): one build of each.
fn expect_inlined(label: str, src: str, code: i32) {
    let a = h::diff_build(src, ["SC_INLINE=0"]);
    let b = h::diff_build(src, []);
    if !a.built || !b.built {
        eprintln("{}: {}{}", label, a.diag.as_str(), b.diag.as_str());
    }
    assert(a.built, label);
    assert(b.built, label);
    let d = h::same_runs(&a, &b, [""]);
    if d.len() != 0 {
        eprintln("{}: inlined and called: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
    let r = h::diff_run(&b, "");
    if r.exit != code {
        eprintln("{}: exit {}, expected {}", label, r.exit, code);
    }
    assert(r.exit == code, label);
}

const BOUND: str = M"(interface Scale {
    fn k() i32;
}
struct A {}
struct B {}
extend A as Scale {
    fn k() i32 {
        return 3;
    }
}
extend B as Scale {
    fn k() i32 {
        return 5;
    }
}
@noinline
fn times<T: Scale>(x: i32x4) i32x4 {
    return x * i32x4::splat(T::k());
}
fn main(args: Vector<str>) i32 {
    let n = i32x4::splat(args.len() as i32);
    return (times::<A>(n) + times::<B>(n)).get(2) - 8;
}
)";

@test
fn an_interface_method_through_a_type_parameter_inlines_per_instance() {
    h::expect_c_absent("each instance of `times` computes its factor in place", BOUND, "A__k()");
    h::expect_c_absent("and so does the other one", BOUND, "B__k()");
    expect_inlined("bound variants", BOUND, 0);
}

// A concrete function that inlines a generic callee: the callee's interface call through its type
// parameter binds to the conformance and inlines too.
const CONCRETE: str = M"(interface Scale {
    fn k() i32;
}
struct A {}
extend A as Scale {
    fn k() i32 {
        return 3;
    }
}
fn times<T: Scale>(x: i32x4) i32x4 {
    return x * i32x4::splat(T::k());
}
@noinline
fn f(x: i32x4) i32x4 {
    return times::<A>(x) + i32x4::splat(1);
}
fn main(args: Vector<str>) i32 {
    return f(i32x4::splat(args.len() as i32)).get(3) - 4;
}
)";

@test
fn a_concrete_caller_inlines_the_interface_calls_of_its_splices() {
    h::expect_c_absent("the conformance method is not called", CONCRETE, "A__k()");
    expect_inlined("bound calls in a concrete body", CONCRETE, 0);
}

const SWITCH: str = M"(enum K {
    A,
    B,
    C,
}
const TA: [f32; 3] = [1.0, 2.0, 3.0];
const TB: [f32; 2] = [4.0, 5.0];
fn pick<const P: K>(x: f32x4) f32x4 {
    return switch P {
        A => x * f32x4::splat(TA[0]) + f32x4::splat(TA[1]) * x * x + f32x4::splat(TA[2]),
        B => x * f32x4::splat(TB[0]) + f32x4::splat(TB[1]),
        C => x - f32x4::splat(1.0),
    };
}
@noinline
fn f(x: f32x4) f32x4 {
    return pick::<K::B>(x) + f32x4::splat(1.0);
}
fn main() i32 {
    return f(f32x4::splat(2.0)).get(1) as i32;
}
)";

@test
fn a_switch_on_a_const_parameter_inlines_its_one_arm() {
    // `TA` is read only by the arm the binding does not take.
    h::expect_c_absent("the other arms are gone", SWITCH, "TA[");
    h::expect_c("the taken arm reads its constant", SWITCH, "TB[");
    expect_inlined("switch folding", SWITCH, 14);
}

// A switch on a literal spelled in hex (`0x41`, whose `Constant.val` holds only a decimal spelling)
// takes the arm of its value in a splice and in a bound variant: the switch keeps reading its temp.
const HEX_SPLICE: str = M"(fn code(x: i32) i32 {
    let s: i32 = switch 0x41u8 {
        65 => 1,
        66 => 2,
        _ => 0,
    };
    return s + x;
}
fn main(args: Vector<str>) i32 {
    return code(args.len() as i32) - 2;
}
)";

const HEX_BOUND: str = M"(interface Scale {
    fn k() i32;
}
struct A {}
extend A as Scale {
    fn k() i32 {
        return 3;
    }
}
@noinline
fn times<T: Scale>(x: i32x4) i32x4 {
    let s: i32 = switch 0x41u8 {
        65 => 1,
        66 => 2,
        _ => 0,
    };
    return x * i32x4::splat(T::k() + s);
}
fn main(args: Vector<str>) i32 {
    return times::<A>(i32x4::splat(args.len() as i32)).get(2) - 4;
}
)";

@test
fn a_switch_on_a_hex_literal_takes_its_value_arm() {
    expect_inlined("hex scrutinee in a splice", HEX_SPLICE, 0);
    expect_inlined("hex scrutinee in a bound variant", HEX_BOUND, 0);
}

const COUNT: str = M"(fn twice<const M: usize>() usize {
    return M * 2;
}
@noinline
fn outer<const N: usize>() usize {
    return twice::<N>() + 1;
}
fn main() i32 {
    return (outer::<3>() + outer::<5>()) as i32;
}
)";

@test
fn a_callee_counted_by_the_callers_parameter_inlines_into_the_shared_body() {
    h::expect_c_absent("no instance of `twice` is called", COUNT, "twice__");
    expect_inlined("symbolic counts", COUNT, 18);
}

// A slice at an offset of a vector of a type only pointers name in the unit: the pointer arithmetic
// needs the element's definition (an inlined `len` once supplied it by accident).
const OFFSET: str = M"(struct S {
    pub v: i32,
}
@noinline
fn total(p: *const S, n: usize) i32 {
    let mut t: i32 = 0;
    for i in 0..n {
        t += unsafe (*(p + i)).v;
    }
    return t;
}
@noinline
fn sum_tail<F: fn(&mut Vector<S>)>(fill: F) i32 {
    let mut v = Vector::<S>::new();
    fill(&mut v);
    let n = v.len();
    let view = v[1..n];
    return total(view.ptr, view.len());
}
fn main() i32 {
    return sum_tail(|v: &mut Vector<S>| {
        v.push(S { v: 1 });
        v.push(S { v: 2 });
        v.push(S { v: 4 });
    });
}
)";

fn a_slice_offset_names_the_element_definition(b: &mut h::ExitBatch) {
    b.add("a slice at an offset", OFFSET, 6);
}

// Scalar code binds per instance the interface calls whose result the instance fixes: `G::len()` of a
// generic conformance is the instance's constant (`V<3>`: 3, the loop's trip count), through a plain
// interface and through a generic one (`Gen<T>`, the conformance with the bound's arguments); `at`, which
// reads its argument, stays a call there.
const SCALAR_BOUND: str = M"(interface Sized: Copy {
    fn len() usize;
    fn at(self: &Self, i: usize) f32;
}
interface Gen<T>: Copy {
    fn glen() usize;
    fn get(self: &Self, i: usize) T;
}
struct V<const N: usize> {
    pub e: [f32; N],
}
extend<const N: usize> V<N> as Sized {
    pub fn len() usize {
        return N;
    }
    pub fn at(self: &V<N>, i: usize) f32 {
        return unsafe self.e[i];
    }
}
extend<const N: usize> V<N> as Gen<f32> {
    pub fn glen() usize {
        return N;
    }
    pub fn get(self: &V<N>, i: usize) f32 {
        return unsafe self.e[i];
    }
}
@noinline
fn sum<G: Sized>(v: G) f32 {
    let mut s: f32 = 0.0;
    for i in 0..G::len() {
        s += v.at(i);
    }
    return s;
}
@noinline
fn gsum<T: Copy, G: Gen<T>>(v: G, f: fn(T) f32) f32 {
    let mut s: f32 = 0.0;
    for i in 0..G::glen() {
        s += f(v.get(i));
    }
    return s;
}
fn id(x: f32) f32 {
    return x;
}
fn main() i32 {
    let v = V::<3> { e: [1.0, 2.0, 3.0] };
    return (sum(v) + gsum(v, id)) as i32 - 12;
}
)";

@test
fn scalar_instances_bind_their_interface_calls() {
    h::expect_c_absent("`G::len()` is a constant of the instance", SCALAR_BOUND, "__len()");
    h::expect_c("`at` stays a call", SCALAR_BOUND, "__at(");
    h::expect_c_absent("through a generic interface too", SCALAR_BOUND, "__glen()");
    h::expect_exit("bound calls in scalar instances", SCALAR_BOUND, 0);
    h::expect_same_output("inlined and called", SCALAR_BOUND, ["SC_INLINE=0"], []);
}

// Scalar code keeps the narrower reach: a callee reading a module constant stays a call there.
const SCALAR: str = M"(const T: [i32; 2] = [3, 4];
fn second() i32 {
    return T[1];
}
@noinline
fn g(x: i32) i32 {
    return x + second();
}
fn main() i32 {
    return g(1) - 5;
}
)";

@test
fn scalar_code_keeps_a_constant_reader_a_call() {
    h::expect_c("the call stays", SCALAR, "second()");
    h::expect_exit("scalar reach", SCALAR, 0);
}

// A caller that holds a vector takes a larger splice budget: 16 calls of a callee of about 90
// statements, past the budget of another caller, all inline.
const BUDGET: str = M"(fn step(x: f32x4) f32x4 {
    let mut v = x;
    v = v * x + f32x4::splat(1.0);
    v = v * x + f32x4::splat(2.0);
    v = v * x + f32x4::splat(3.0);
    v = v * x + f32x4::splat(4.0);
    v = v * x + f32x4::splat(5.0);
    v = v * x + f32x4::splat(6.0);
    v = v * x + f32x4::splat(7.0);
    v = v * x + f32x4::splat(8.0);
    v = v * x + f32x4::splat(9.0);
    v = v * x + f32x4::splat(10.0);
    v = v * x + f32x4::splat(11.0);
    v = v * x + f32x4::splat(12.0);
    v = v * x + f32x4::splat(13.0);
    v = v * x + f32x4::splat(14.0);
    v = v * x + f32x4::splat(15.0);
    v = v * x + f32x4::splat(16.0);
    v = v * x + f32x4::splat(17.0);
    v = v * x + f32x4::splat(18.0);
    v = v * x + f32x4::splat(19.0);
    v = v * x + f32x4::splat(20.0);
    v = v * x + f32x4::splat(21.0);
    v = v * x + f32x4::splat(22.0);
    v = v * x + f32x4::splat(23.0);
    v = v * x + f32x4::splat(24.0);
    v = v * x + f32x4::splat(25.0);
    v = v * x + f32x4::splat(26.0);
    v = v * x + f32x4::splat(27.0);
    v = v * x + f32x4::splat(28.0);
    return v;
}
@noinline
fn many(x: f32x4) f32x4 {
    let mut y = x;
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    y = step(y);
    return y;
}
fn main(args: Vector<str>) i32 {
    return (many(f32x4::splat(args.len() as f32 * 0.001)).get(0) > 0.0) as i32 - 1;
}
)";

@test
fn a_vector_caller_takes_a_larger_budget() {
    h::expect_c_absent("no call of `step` remains", BUDGET, "step(y)");
    h::expect_exit("a vector budget", BUDGET, 0);
}

// A parameter the callee never writes reads its argument in place: an autoref receiver reads the
// caller's place (`(*self).x` is `p.x`), a constant argument is the constant. The emitter folds a
// single-use scalar into an index, a call argument after the receiver and a check's operand.
const IN_PLACE: str = M"(struct P {
    pub x: i32,
    pub y: i32,
}
extend P {
    fn sum(self: &P) i32 {
        return self.x + self.y;
    }
    fn bump(self: &mut P, d: i32) {
        self.x = self.x + d;
    }
}
@noinline
fn take(a: i32, b: i32) i32 {
    return a - b;
}
fn main(args: Vector<str>) i32 {
    let n = args.len() as i32;
    let mut p = P { x: n, y: n + 1 };
    p.bump(7);
    let v = [1, 2, 3, 4];
    let i = args.len() - 1;
    let w = unsafe v[i + 1];
    let mut q = Vector::<i32>::new();
    q.push(n);
    q.push(n);
    let k = args.len() - 1;
    let qs: []i32 = q[0..q.len()];
    return take(p.sum(), w * 3) + qs[k + 1] - 5;
}
)";

fn expect_user_c(label: str, src: str, needle: str, present: bool) {
    let c = h::compile_c_user(src);
    assert(c.ok(), label);
    assert(c.code_has(needle) == present, label);
}

@test
fn arguments_read_in_place() {
    expect_user_c("the receiver is the caller's place", IN_PLACE, "__sc_add_i32(p.x, p.y)", true);
    expect_user_c("no reference to it is taken", IN_PLACE, "&p;", false);
    expect_user_c("the constant argument is spelled at its read", IN_PLACE, "__sc_add_i32(p.x, 7LL)", true);
    // `i`, an immutable local read once, folds into the index too.
    expect_user_c("an index folds", IN_PLACE, "v[__sc_add_usize(__sc_sub_usize(", true);
    expect_user_c("a call argument folds", IN_PLACE, "__sc_mul_i32(w, 3LL))", true);
    // A view's element check is its `index` method's guard, over the index computed once in place.
    expect_user_c("a check operand folds", IN_PLACE, "= __sc_add_usize(k, 1ULL);", true);
    expect_inlined("in-place arguments", IN_PLACE, 0);
}

// Arguments whose storage the callee can reach keep their copy: each case checks the value the
// call read, whatever the callee then writes.
const ALIASED: str = M"(static mut G: i32 = 3;
static mut K: i32 = 0;
static mut STASH: *mut i32 = null;
struct P {
    pub x: i32,
    pub y: i32,
}
struct H {
    pub v: P,
}
struct W {
    pub v: i32,
}
extend W {
    @noinline
    fn stash(self: &mut W) {
        unsafe STASH = &mut self.v;
    }
}
@noinline
fn poke() {
    unsafe *STASH = 99;
}
fn read_after(a: W) i32 {
    poke();
    return a.v;
}
extend P {
    fn reset_add(self: &mut P, d: i32) {
        self.x = 0;
        self.x = self.x + d;
    }
    fn swap_then_read(self: &mut P, slot: *mut *mut H, other: *mut H) i32 {
        unsafe *slot = other;
        return self.x;
    }
}
fn store_then_read(a: i32, q: *mut i32) i32 {
    unsafe *q = 100;
    return a;
}
fn deref_then_read(a: P, q: *mut P) i32 {
    unsafe (*q).x = 50;
    return a.x;
}
fn set_global(a: i32) i32 {
    unsafe G = 7;
    return a;
}
@noinline
fn bump_global() {
    unsafe G = unsafe G + 10;
}
fn call_then_read(a: i32) i32 {
    bump_global();
    return a;
}
fn bump0(a: [i32; 4]) i32 {
    let mut b = a;
    b[0] = 9;
    return b[0] + a[0];
}
@noinline
fn opaque(v: i32) i32 {
    return v + unsafe K;
}
fn main() i32 {
    let mut fails = 0;
    let mut p = P { x: opaque(4), y: opaque(5) };
    p.reset_add(p.x);
    if p.x != 4 {
        fails += 1;
    }
    let mut x = opaque(1);
    if store_then_read(x, &mut x) != 1 || x != 100 {
        fails += 2;
    }
    let mut s = P { x: opaque(8), y: 0 };
    let sp = &mut s as *mut P;
    if deref_then_read(unsafe *sp, sp) != 8 || s.x != 50 {
        fails += 4;
    }
    if set_global(unsafe G) != 3 {
        fails += 8;
    }
    if call_then_read(unsafe G) != 7 {
        fails += 16;
    }
    let arr = [opaque(1), 2, 3, 4];
    if bump0(arr) != 10 || arr[0] != 1 {
        fails += 32;
    }
    let mut h1 = H { v: P { x: opaque(11), y: 0 } };
    let mut h2 = H { v: P { x: opaque(22), y: 0 } };
    let mut hp = &mut h1 as *mut H;
    let other = &mut h2 as *mut H;
    if unsafe (*hp).v.swap_then_read(&mut hp, other) != 11 {
        fails += 64;
    }
    let mut w = W { v: opaque(5) };
    w.stash();
    if read_after(w) != 5 || w.v != 99 {
        fails += 128;
    }
    // A caller that holds a vector inlines the callees that touch statics.
    let vv = i32x4::splat(opaque(1));
    return fails + vv.get(0) - 1;
}
)";

@test
fn aliased_arguments_keep_their_copy() {
    expect_user_c("a static argument the callee writes keeps its copy", ALIASED, "G;", true);
    expect_inlined("aliased arguments", ALIASED, 0);
}

// A folded definition reads its operands where it is spelled: a write between its definition and
// its read to an input of a definition folded into it keeps it declared (the inlined loop below
// would otherwise compute `b % b`).
const FOLD_INPUTS: str = M"(fn gcd(a0: u64, b0: u64) u64 {
    let mut a = a0;
    let mut b = b0;
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    return a;
}
fn main(args: Vector<str>) i32 {
    let x = args.len() as u64 * 12;
    let y = args.len() as u64 * 18;
    return gcd(x, y) as i32 - 6;
}
)";

@test
fn a_fold_keeps_the_inputs_of_its_links() {
    expect_inlined("gcd", FOLD_INPUTS, 0);
}

// C leaves a call unordered with the other operand of an operator: a call result read beside a
// value the call can change keeps its temporary.
const CALL_ORDER: str = M"(@noinline
fn bump(p: &mut i32) i32 {
    *p = *p + 1;
    return 10;
}
fn main(args: Vector<str>) i32 {
    let mut v = args.len() as i32;
    let r = &mut v;
    let x = bump(r) + *r;
    return x - 12;
}
)";

fn a_call_beside_what_it_writes_keeps_its_result(b: &mut h::ExitBatch) {
    expect_user_c("the call is not spelled beside the read", CALL_ORDER, "(bump(r), ", false);
    b.add("call order", CALL_ORDER, 0);
}

// C evaluates the operands of an operation and the slots of a multi-return carrier in no fixed
// order: of two operations that can panic, the first in source order reports, whatever the C
// compiler chooses.
const PANIC_OPERANDS: str = M"(fn main(args: Vector<str>) i32 {
    let n = args.len() as i32;
    let a = n * 2147483647;
    let z = n - 1;
    return (a * 2) + (n / z);
}
)";

const PANIC_SLOTS: str = M"(@noinline
fn pair(n: i32, z: i32) (i32, i32) {
    let a = n * 2147483647;
    return a * 2, n / z;
}
fn main(args: Vector<str>) i32 {
    let n = args.len() as i32;
    let (x, y) = pair(n, n - 1);
    return x + y;
}
)";

fn the_first_panic_in_source_order_reports(b: &mut h::ExitBatch) {
    expect_user_c("the product is no operand beside the quotient", PANIC_OPERANDS, "__sc_mul_i32(a, 2LL), ", false);
    b.add_trap("operands", PANIC_OPERANDS, "attempt to multiply with overflow");
    expect_user_c("the product is no slot beside the quotient", PANIC_SLOTS, "._0 = __sc_mul_i32(", false);
    b.add_trap("carrier slots", PANIC_SLOTS, "attempt to multiply with overflow");
}

// The exit-code cases of the provider functions above, one program per group (`h::ExitBatch`):
// a group builds once where each case built alone.
@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    a_slice_offset_names_the_element_definition(&mut b);
    a_call_beside_what_it_writes_keeps_its_result(&mut b);
    the_first_panic_in_source_order_reports(&mut b);
    b.run();
}
