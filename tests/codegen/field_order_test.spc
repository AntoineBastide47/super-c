// Field order: the compiler lays a struct's or a tuple's fields, and an enum variant's payload, out
// by alignment, largest first, keeping the declared order for `@ordered` structs, a leading run of
// `@ordered` fields, `@packed` structs, unions, the structs an extern or `@export` signature reaches,
// and those an `extern "C"` call reaches through an untyped pointer argument or a C variadic. The native and the C backends place every field where the layout service says
// (`std::reflect`'s `f.offset`), so a program prints the same layouts through both.
import tests::harness as h;
import tests::cli_harness as cli;

const LAYOUTS: str = M"(struct Mixed {
    pub a: u8,
    pub b: u64,
    pub c: u16,
    pub d: u32,
}

struct Gen<T> {
    pub a: u8,
    pub t: T,
    pub b: u16,
}

struct Tup(u8, u64, u8);

@ordered
struct Kept {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

struct Prefix {
    @ordered
    pub a: u8,
    @ordered
    pub b: u16,
    pub c: u64,
    pub d: u8,
}

@packed
struct Packed {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

union Un {
    pub a: u8,
    pub b: u64,
}

struct Empty {}

struct WithZst {
    pub a: u8,
    pub z: Empty,
    pub b: u64,
}

struct ForC {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

struct ByExport {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

extern "C" {
    fn fo_never_called(p: *const ForC);
}

@export("fo_exported")
fn fo_exported(p: *const ByExport) i32 {
    return unsafe (*p).a;
}

struct ViaVoid {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

struct ViaVariadic {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

struct Nested {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

struct HoldsNested {
    pub t: u8,
    pub n: Nested,
}

extern "C" {
    @import("memset")
    fn fo_set(p: *mut void, c: i32, n: usize) *mut void;
    @import("snprintf")
    fn fo_print(buf: *mut char, n: usize, fmt: *const char, ...) i32;
}

enum En {
    V(u8, u64, u16),
    W { x: u8, y: u32 },
}

fn addr<T>(r: &T) usize {
    return r as *const T as usize;
}

// Each field's offset from the layout service and from its real address; false when they differ.
fn show<T>(name: str, v: &T) bool {
    let mut ok = true;
    let mut s = format("{} {}", name, sizeof(T));
    inline for f in fields(v) {
        let real = addr(&f.value) - addr(v);
        s.push_str(format(" {}={}", f.name, f.offset).as_str());
        // A zero-sized field has no storage, so no address to compare.
        ok = ok && (f.size == 0 || real == f.offset);
    }
    println("{}", s.as_str());
    return ok;
}

// Each payload member's offset from the enum's start.
fn show_en(e: &En) {
    let mut s = format("En {}", sizeof(En));
    inline for v in variants(e) {
        if v.is_active {
            inline for p in payloads(v) {
                s.push_str(format(" {}={}", p.name, addr(&p.value) - addr(e)).as_str());
            }
        }
    }
    println("{}", s.as_str());
}

fn main() i32 {
    let mut ok = show("Mixed", &Mixed { a: 1, b: 2, c: 3, d: 4 });
    ok = show("Gen<u64>", &Gen::<u64> { a: 1, t: 2, b: 3 }) && ok;
    ok = show("Gen<u8>", &Gen::<u8> { a: 1, t: 2, b: 3 }) && ok;
    let t = Tup(1, 2, 3);
    ok = show("Tup", &t) && ok;
    let at: (u8, u64, u16) = (1, 2, 3);
    ok = show("(u8, u64, u16)", &at) && ok;
    ok = show("Kept", &Kept { a: 1, b: 2, c: 3 }) && ok;
    ok = show("Prefix", &Prefix { a: 1, b: 2, c: 3, d: 4 }) && ok;
    ok = show("Packed", &Packed { a: 1, b: 2, c: 3 }) && ok;
    println("Un {}", sizeof(Un));
    ok = show("WithZst", &WithZst { a: 1, z: Empty {}, b: 2 }) && ok;
    ok = show("ForC", &ForC { a: 1, b: 2, c: 3 }) && ok;
    let x = ByExport { a: 1, b: 2, c: 3 };
    ok = show("ByExport", &x) && ok;
    // C reads these through untyped pointers: none of the calls changes a byte.
    let mut vv = ViaVoid { a: 1, b: 2, c: 3 };
    let _ = unsafe fo_set(&mut vv, 0, 0);
    ok = show("ViaVoid", &vv) && ok;
    let mut va = ViaVariadic { a: 1, b: 2, c: 3 };
    let _ = unsafe fo_print(null, 0, "%p".ptr() as *const char, &mut va);
    ok = show("ViaVariadic", &va) && ok;
    let mut hn = HoldsNested { t: 1, n: Nested { a: 2, b: 3, c: 4 } };
    let _ = unsafe fo_set((&mut hn as *mut HoldsNested) as *mut void, 0, 0);
    ok = show("HoldsNested", &hn) && ok;
    ok = show("Nested", &hn.n) && ok;
    let v = En::V(1, 2, 3);
    show_en(&v);
    let w = En::W { x: 1, y: 2 };
    show_en(&w);
    if !ok {
        return 1;
    }
    return fo_exported(&x) - 1;
}
)";

const EXPECTED: str = M"(Mixed 16 a=14 b=0 c=12 d=8
Gen<u64> 16 a=10 t=0 b=8
Gen<u8> 4 a=2 t=3 b=0
Tup 16 _0=8 _1=0 _2=9
(u8, u64, u16) 16 _0=10 _1=0 _2=8
Kept 24 a=0 b=8 c=16
Prefix 24 a=0 b=2 c=8 d=16
Packed 10 a=0 b=1 c=9
Un 8
WithZst 16 a=8 z=9 b=0
ForC 24 a=0 b=8 c=16
ByExport 24 a=0 b=8 c=16
ViaVoid 24 a=0 b=8 c=16
ViaVariadic 24 a=0 b=8 c=16
HoldsNested 32 t=0 n=8
Nested 24 a=0 b=8 c=16
En 24 _0=18 _1=8 _2=16
En 24 x=12 y=8
)";

// The layouts above through both backends: each field where the layout service places it, and the same
// text from the native and the C build.
@test
fn fields_take_their_layout_order_in_both_backends() {
    let n = h::compile_and_run(LAYOUTS);
    assert(n.built, "the program builds natively");
    let nout = unsafe str::from_cstr(n.out);
    assert_eq(n.exit, 0);
    assert_eq(nout, EXPECTED);
    if !cli::has_cc() {
        return; // the C build needs a C compiler
    }
    let c = h::compile_and_run_c(LAYOUTS);
    assert(c.built, "the program builds through C");
    assert_eq(c.exit, 0);
    assert_eq(unsafe str::from_cstr(c.out), EXPECTED);
}

// `@ordered` is a struct's or a prefix of its fields', where the order is not kept already.
@test
fn ordered_tags_are_checked() {
    h::expect_err_msg(
        "a gap in the prefix",
        "struct S {\n    a: u8,\n    @ordered\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "field 'b' is '@ordered', but field 'a' before it is not: ordered fields are a prefix of the struct",
    );
    h::expect_err_msg(
        "a field of an ordered struct",
        "@ordered\nstruct S {\n    @ordered\n    a: u8,\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "'@ordered' on a field of an '@ordered' struct, whose fields keep their declared order already",
    );
    h::expect_err_msg(
        "a union",
        "@ordered\nunion U {\n    a: u8,\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "'@ordered' on a union, whose fields keep their declared order already",
    );
    h::expect_err_msg(
        "a field of a packed struct",
        "@packed\nstruct S {\n    @ordered\n    a: u8,\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "'@ordered' on a field of a '@packed' struct, whose fields keep their declared order already",
    );
    h::expect_err_msg(
        "a function",
        "@ordered\nfn f() {}\nfn main() i32 { return 0; }\n",
        "may only be applied to a struct or a field",
    );
}

// A struct C reads through an untyped pointer keeps its declared order, which must not change a layout the
// typecheck already evaluated: here the order changes the size `static_assert` read.
@test
fn a_c_read_after_a_compile_time_layout_is_an_error() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(struct G {
    pub a: u8,
    pub b: u64,
    pub c: u8,
}

static_assert(sizeof(G) == 16, "reordered");

extern "C" {
    @import("memset")
    fn fo_set(p: *mut void, c: i32, n: usize) *mut void;
}

fn main() i32 {
    let mut g = G { a: 1, b: 2, c: 3 };
    let _ = unsafe fo_set(&mut g, 0, 0);
    return g.a as i32 - 1;
}
)",
    );
    let r = cli::superc_in(p.dir(), "build main.spc -o bin");
    assert(r.exit != 0, "the build fails");
    assert(
        r.out_has(
            "'G' reaches C through an untyped pointer argument, so its fields keep their declared order, but a compile-time evaluation already used its reordered layout: tag it '@ordered'",
        ),
        "the error names the struct and the fix",
    );
}
