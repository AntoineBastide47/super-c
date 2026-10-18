// The Core IR inliner over generic code: in vector code, a call of an interface method through a type
// parameter inlines in each instance (the instance's bound variant; in scalar code, a call whose result
// the instance fixes) and in a concrete caller the generic callee inlines into, a callee reading module constants inlines, its `switch` on a
// const-generic parameter keeping the one arm its binding takes; and a callee whose count is the
// caller's own const-generic parameter inlines into the caller's shared body. Each program runs the
// same without inlining.
import tests::harness as h;

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
@c.noinline
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
    h::expect_exit("bound variants", BOUND, 0);
    h::expect_same_output("inlined and called", BOUND, ["SC_INLINE=0"], []);
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
@c.noinline
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
    h::expect_exit("bound calls in a concrete body", CONCRETE, 0);
    h::expect_same_output("inlined and called", CONCRETE, ["SC_INLINE=0"], []);
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
@c.noinline
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
    h::expect_exit("switch folding", SWITCH, 14);
    h::expect_same_output("inlined and called", SWITCH, ["SC_INLINE=0"], []);
}

const COUNT: str = M"(fn twice<const M: usize>() usize {
    return M * 2;
}
@c.noinline
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
    h::expect_exit("symbolic counts", COUNT, 18);
    h::expect_same_output("inlined and called", COUNT, ["SC_INLINE=0"], []);
}

// A slice at an offset of a vector of a type only pointers name in the unit: the pointer arithmetic
// needs the element's definition (an inlined `len` once supplied it by accident).
const OFFSET: str = M"(struct S {
    pub v: i32,
}
@c.noinline
fn total(p: *const S, n: usize) i32 {
    let mut t: i32 = 0;
    for i in 0..n {
        t += unsafe (*(p + i)).v;
    }
    return t;
}
@c.noinline
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

@test
fn a_slice_offset_names_the_element_definition() {
    h::expect_exit("a slice at an offset", OFFSET, 6);
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
@c.noinline
fn sum<G: Sized>(v: G) f32 {
    let mut s: f32 = 0.0;
    for i in 0..G::len() {
        s += v.at(i);
    }
    return s;
}
@c.noinline
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
@c.noinline
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
@c.noinline
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
