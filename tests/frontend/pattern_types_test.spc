// Pattern types (`u32 is 1..`, `Option<T> is Some(_)`): their checks, the conversions into them that
// the checker decides or the prover proves, `as?`, payload reads, niches, and the bounds checks the
// prover removes from their facts and from contracts.
import tests::harness as h;
import tests::cli_harness as cli;

@test
fn pattern_types_are_checked() {
    h::expect_err_msg(
        "a base that is no integer or enum",
        "fn f(x: f32 is 1..) {}\nfn main() i32 { return 0; }\n",
        "the base of a pattern type is a built-in integer or an enum, not 'f32'",
    );
    h::expect_err_msg(
        "a pattern type over a pattern type",
        "type P = u32 is 1..;\nfn f(x: P is 2..) {}\nfn main() i32 { return 0; }\n",
        "the base of a pattern type is not a pattern type: 'u32 is 1..'",
    );
    h::expect_err_msg(
        "a range over every value",
        "fn f(x: u32 is 0..) {}\nfn main() i32 { return 0; }\n",
        "this pattern matches every value of 'u32': write 'u32'",
    );
    h::expect_err_msg(
        "an empty range",
        "fn f(x: u32 is 5..5) {}\nfn main() i32 { return 0; }\n",
        "this pattern type has no value",
    );
    h::expect_err_msg(
        "a variant pattern over an integer",
        "fn f(x: u32 is Some(_)) {}\nfn main() i32 { return 0; }\n",
        "a pattern type of 'u32' takes a range",
    );
    h::expect_err_msg(
        "a name that is no variant of the enum",
        "fn f(x: Option<u32> is Ok(_)) {}\nfn main() i32 { return 0; }\n",
        "a pattern type of 'Option<u32>' takes one of its variants",
    );
    h::expect_err_msg(
        "a struct pattern for a tuple variant",
        "fn f(x: Option<u32> is Some { .. }) {}\nfn main() i32 { return 0; }\n",
        "this pattern does not match the shape of variant 'Some'",
    );
    h::expect_err_msg(
        "a base that holds a reference",
        "fn f(x: Option<&u32> is Some(_)) {}\nfn main() i32 { return 0; }\n",
        "the base of a pattern type holds no reference: 'Option<&u32>'",
    );
    h::expect_err_msg(
        "a checked cast into a plain type",
        "fn main() i32 { let x = 3 as? u32; return 0; }\n",
        "'as?' converts into a pattern type, not 'u32'",
    );
    h::expect_err_msg(
        "a constant outside the range",
        "fn main() i32 { let z: u32 is 1..=9 = 10; return z as i32; }\n",
        "this value does not match 'u32 is 1..=9'",
    );
    h::expect_err_msg(
        "a constant's value outside the range",
        "const fn g(x: u32) u32 { return x; }\nconst C: u32 is 1.. = g(0);\nfn main() i32 { return C as i32; }\n",
        "this value does not match 'u32 is 1..'",
    );
    h::expect_err_msg(
        "a variant written in place that is the other one",
        "fn main() i32 { let o: Option<u32> is Some(_) = None; return 0; }\n",
        "this value does not match 'Option<u32> is Some(..)'",
    );
    h::expect_err_msg(
        "a payload member the variant does not have",
        "fn f(c: Option<u32> is Some(_)) u32 { return c.1; }\nfn main() i32 { return 0; }\n",
        "'Option<u32> is Some(..)' has no payload member '1'",
    );
    assert(h::parse_has_error("fn main() i32 { let x = 3 as u32 is 1..; return 0; }\n"), "a cast into a pattern type");
    assert(!h::parse_has_error("fn f() u32 is 1.. requires true { return 1; }\n"), "a range ends before a clause");
}

// A conversion the checker cannot decide is the prover's: each one it cannot prove is an error, with
// an input that breaks it.
@test
fn unproved_conversions_are_errors() {
    let mut b = cli::Batch::new("", "");
    b.add(
        "a value no path condition bounds",
        "fn pos(x: u32 is 1..) u32 { return x; }\nfn f(n: u32) u32 { return pos(n); }\nfn main() i32 { return f(1) as i32; }\n",
        "for example: n = 0",
    );
    b.add(
        "an increment that may wrap",
        "fn f(x: u32 is 1..) u32 { let mut y: u32 is 1.. = x; y += 1; return y; }\nfn main() i32 { return f(1) as i32; }\n",
        "cannot prove that this value matches its pattern type",
    );
    b.add(
        "a result outside the range",
        "fn f(x: u32 is 1..) u32 is 1.. { return x - 1; }\nfn main() i32 { return f(2) as i32; }\n",
        "for example: x = 1",
    );
    b.add(
        "a variant no test shows",
        "fn f(o: Option<u32>) u32 { let s: Option<u32> is Some(_) = o; return s.0; }\nfn main() i32 { return f(Some(1)) as i32; }\n",
        "cannot prove that this value matches its pattern type",
    );
    b.add(
        "a field of a pattern type",
        "struct Q { d: i32 is 1.. }\nfn mk(d: i32) Q { return Q { d: d }; }\nfn main() i32 { return mk(2).d; }\n",
        "for example: d = 0",
    );
    h::expect_build_errs(b);
}

fn pattern_runs(b: &mut h::ExitBatch) {
    b.add(
        "conversions the path conditions, the parameters and a switch arm prove",
        M"(fn pos(x: u32 is 1..) u32 {
    return x;
}
fn half(x: u32 is 2..=100) u32 is 1..=50 {
    return x / 2;
}
fn from_param(x: u32 is 1..) u32 {
    let y: u32 is 1.. = x - 0;
    return pos(y);
}
fn on_path(n: u32) u32 {
    if n > 3 {
        return pos(n);
    }
    return switch n {
        1..=3 => pos(n),
        _ => 0,
    };
}
fn bump(x: u32 is 1..=9) u32 is 1..=10 {
    let mut y: u32 is 1..=10 = x;
    if y < 10 {
        y += 1;
    }
    return y;
}
fn main() i32 {
    return (from_param(2) + on_path(5) + on_path(2) + on_path(0) + half(7) + bump(9)) as i32;
}
)",
        22,
    );
    b.add(
        "variants: a test on the path, payload reads, a struct variant",
        M"(enum Shape {
    Circle(i32),
    Rect { w: i32, h: i32 },
    Unit,
}
fn radius(c: Shape is Circle(..)) i32 {
    return c.0;
}
fn area(r: &Shape is Rect { .. }) i32 {
    return r.w * r.h;
}
fn size(s: Shape) i32 {
    if let Circle(_) = s {
        let c: Shape is Circle(..) = s;
        return radius(c);
    }
    return switch s {
        Rect { .. } => {
            let r: Shape is Rect { .. } = s;
            area(&r)
        },
        _ => 0,
    };
}
fn first(o: Option<u32> is Some(_)) u32 {
    return o.0;
}
fn main() i32 {
    let some: Option<u32> is Some(_) = Some(9);
    return size(Circle(4)) + size(Shape::Rect { w: 2, h: 3 }) + size(Unit) + first(some) as i32;
}
)",
        19,
    );
    b.add(
        "as? and the niches of integer ranges",
        M"(fn as_small(x: u32) u32 {
    if let Some(s) = x as? u32 is 1..=9 {
        return s;
    }
    return 100;
}
fn main() i32 {
    // 0 is free in `1..`, 255 in `0..=254`, -1 in `i8 is 0..`: each is `None`, and every value of the
    // range a `Some`.
    let a: [Option<u8 is 0..=254>; 3] = [Some(254), None, Some(0)];
    let s: Option<i8 is 0..> = 0 as? i8 is 0..;
    let n: Option<i8 is 0..> = -3 as? i8 is 0..;
    let mut r: i32 = 0;
    if sizeof(Option<u32 is 1..>) == 4 && sizeof(Option<u8 is 0..=254>) == 1 && sizeof(Option<i8 is 0..>) == 1 {
        r += 1;
    }
    if a[0].unwrap() == 254 && a[1].is_none() && a[2].unwrap() == 0 {
        r += 2;
    }
    if s.unwrap() == 0 && n.is_none() {
        r += 4;
    }
    return r + as_small(5) as i32 + as_small(0) as i32;
}
)",
        112,
    );
    b.add(
        "an index below a const parameter, a constant and a compound assignment",
        M"(fn get<const N: usize>(a: [u32; N], i: usize is 0..N) u32 {
    return a[i];
}
const ONE: Option<u32 is 1..> = Some(1);
const NONE: Option<i8 is 0..> = None;
fn main() i32 {
    let mut x: u32 is 1.. = 3;
    if x < 50 {
        x += 2;
    }
    return (get([1u32, 2, 3, 4], 2) + ONE.unwrap() + x) as i32 + NONE.is_none() as i32;
}
)",
        10,
    );
}

// Pattern types as type arguments, a const parameter bound folded per instance; the niches of variant
// patterns; the variant facts of an enum with explicit discriminants.
fn pattern_arguments(b: &mut h::ExitBatch) {
    b.add(
        "a const parameter bound in type arguments, fields and as?",
        M"(struct Idx<const N: usize> {
    i: usize is 0..N,
}
fn pick<const N: usize>(a: [u32; N], v: Vector<usize is 0..N>) u32 {
    let mut s: u32 = 0;
    for k in 0..v.len() {
        s += a[v[k]];
    }
    return s;
}
fn find<const N: usize>(a: [u32; N], x: u32) Option<usize is 0..N> {
    for i in 0..N {
        if a[i] == x {
            return i as? usize is 0..N;
        }
    }
    return None;
}
fn at<const N: usize>(a: [u32; N], ix: Idx<N>) u32 {
    return a[ix.i];
}
fn main() i32 {
    let a = [5u32, 6, 7, 8];
    let mut v = Vector::<usize is 0..4>::new();
    v.push(1);
    v.push(3);
    // `0..4` and `0..8` are two instances: each frees the value past its range.
    let f = find(a, 7);
    let g = find([1u32, 2, 3, 4, 5, 6, 7, 8], 9);
    let mut r: u32 = pick(a, v);
    if sizeof(Option<usize is 0..4>) == sizeof(usize) && f.unwrap() == 2 && g.is_none() {
        r += 100;
    }
    return (r + at(a, Idx::<4> { i: 3 })) as i32;
}
)",
        122,
    );
    b.add(
        "the niches of variant patterns: a tag, a value, a niche enum's word",
        M"(enum Shape {
    Circle(i32),
    Rect { w: i32, h: i32 },
}
enum Code {
    Low = -3,
    Mid = 10,
}
enum One {
    Only(u8),
}
fn area(o: Option<Shape is Rect { .. }>) i32 {
    if let Some(r) = o {
        return r.w * r.h;
    }
    return -1;
}
fn main() i32 {
    let a: Option<Shape is Rect { .. }> = Some(Shape::Rect { w: 2, h: 3 });
    let n: Option<Shape is Rect { .. }> = None;
    let c: [Option<Code is Code::Mid>; 2] = [Some(Code::Mid), None];
    let x: Option<u32 is 1..> is Some(_) = Some(7);
    let nest: [Option<Option<u32 is 1..> is Some(_)>; 2] = [Some(x), None];
    let nn: Option<Option<u32 is 1..> is None> = Some(Option::<u32 is 1..>::None);
    let o: [Option<One is Only(_)>; 2] = [Some(One::Only(4)), None];
    let mut r: i32 = 0;
    if sizeof(Option<Shape is Rect { .. }>) == sizeof(Shape) && sizeof(Option<Code is Code::Mid>) == sizeof(Code) {
        r += 1;
    }
    if sizeof(Option<Option<u32 is 1..> is Some(_)>) == 4 && sizeof(Option<Option<u32 is 1..> is None>) == 4 && sizeof(Option<One is Only(_)>) == sizeof(One) {
        r += 2;
    }
    if area(a) == 6 && area(n) == -1 && c[0].is_some() && c[1].is_none() {
        r += 4;
    }
    // One `Option` of each pattern of one enum: each keeps its own `none`.
    if nest[0].is_some() && nest[1].is_none() && nn.is_some() && o[0].is_some() && o[1].is_none() {
        r += 8;
    }
    if let Some(Some(p)) = nest[0] {
        r += p as i32;
    }
    return r;
}
)",
        22,
    );
    b.add(
        "constants with variant niches: the payload's tag, the inner niche enum's word",
        M"(enum Shape {
    Circle(i32),
    Rect { w: i32, h: i32 },
}
const NONE_RECT: Option<Shape is Rect { .. }> = None;
const SOME_RECT: Option<Shape is Rect { .. }> = Some(Shape::Rect { w: 5, h: 6 });
const NESTED: Option<Option<u32 is 1..> is None> = Some(None);
const TABLE: [Option<Shape is Shape::Circle(..)>; 2] = [Some(Shape::Circle(9)), None];
fn main() i32 {
    let mut r = 0;
    if NONE_RECT.is_none() && NESTED.is_some() && TABLE[1].is_none() {
        r += 1;
    }
    if let Some(s) = SOME_RECT {
        r += s.w * s.h;
    }
    if let Some(c) = TABLE[0] {
        r += c.0;
    }
    return r;
}
)",
        40,
    );
    b.add(
        "the variant of an enum with explicit discriminants: its tag, not its index",
        M"(enum Code {
    Low = 1,
    Mid = 0,
    High = -3,
}
fn low(c: Code is Code::Low) i32
    ensures |r| r == 1
{
    return switch c {
        Low => 1,
        Mid => 2,
        High => 3,
    };
}
fn main() i32 {
    return low(Code::Low);
}
)",
        1,
    );
}

@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    pattern_runs(&mut b);
    pattern_arguments(&mut b);
    b.run();
}

// Without proofs (`-fno-prove`) a conversion the checker cannot decide is a run-time check, so a
// niche never holds a value outside its range.
@test
fn unproved_builds_check_conversions() {
    let src = "fn pos(x: u32 is 1..) u32 { return x; }\nfn main(argv: Vector<str>) i32 { return pos(argv.len() as u32 - 1) as i32; }\n";
    let plain = h::diff_build(src, ["-fno-prove"]);
    assert(plain.built, "a build without proofs accepts the conversion");
    assert_eq(h::diff_run(&plain, "x").exit, 1);
    let r = h::diff_run(&plain, "");
    assert(r.exit != 0 && r.err.contains("assertion failed: `argv.len() as u32 - 1`"), "the conversion's check traps");
}

// The prover's facts remove the bounds checks a pattern type or a `requires` proves; a plain index
// keeps its check. The in-process C emission runs no proofs: a project build emits the C.
@test
fn proved_facts_remove_bounds_checks() {
    let cb = h::diff_build(
        M"(@noinline
fn get<const N: usize>(a: &[u32; N], i: usize is 0..N) u32 {
    return a[i];
}
@noinline
fn next(a: &[u32; 4], i: usize) u32
    requires i < 3
{
    return a[i + 1];
}
@noinline
fn plain(a: &[u32; 4], i: usize) u32 {
    return a[i];
}
fn main(argv: Vector<str>) i32 {
    let a = [1u32, 2, 3, 4];
    return (get(&a, 1) + next(&a, 1) + plain(&a, argv.len())) as i32;
}
)",
        ["--emit-c"],
    );
    assert(cb.built, "the program builds");
    let mut c = cli::read_text(format("{}/build/debug/raw/main.c", cb.proj.dir()).as_str());
    c.push_str(cli::read_text(format("{}/build/debug/raw/main__inst.c", cb.proj.dir()).as_str()).as_str());
    assert(
        !h::c_fn(&c, "uint32_t get__4(uint32_t (*a)[4], size_t i) {").contains("__sc_bounds"),
        "an index of type 'usize is 0..N'",
    );
    assert(
        !h::c_fn(&c, "uint32_t next(uint32_t (*a)[4], size_t i) {").contains("__sc_bounds"),
        "an index the requires bounds",
    );
    assert(
        h::c_fn(&c, "uint32_t plain(uint32_t (*a)[4], size_t i) {").contains("__sc_bounds"),
        "an index without a fact",
    );
}
