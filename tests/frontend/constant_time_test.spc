// Constant-time code: `std::crypto::secret::Secret<T>`, whose operations are the only ones on a secret,
// and `@constant_time`, whose function the build checks on the code it generates (`lir::ct`): no branch,
// memory address or variable-time operation depends on a secret, and no C function receives one.
import tests::harness as h;
import tests::cli_harness as cli;

const SECRET: str = "import std::crypto::secret as *;\n";

// The type checker rejects every way to branch on, index with, divide or compare a secret, and to read
// it but by `declassify`; `@constant_time` takes a function with a body that runs.
@test
fn secrets_have_no_variable_time_operators() {
    let mut b = cli::Batch::new(SECRET, "fn main() i32 {\n    return 0;\n}\n");
    b.add(
        "a branch on a secret",
        "fn f(s: Secret<bool>) u32 {\n    if s {\n        return 1;\n    }\n    return 0;\n}\n",
        "if condition must be 'bool', found 'Secret<bool>'",
    );
    b.add(
        "an index by a secret",
        "fn f(xs: []u32, i: Secret<usize>) u32 {\n    return xs[i];\n}\n",
        "expected 'usize', found 'Secret<usize>'",
    );
    b.add(
        "a division of secrets",
        "fn f(a: Secret<u32>, b: Secret<u32>) Secret<u32> {\n    return a / b;\n}\n",
        "'Secret<u32>' has no 'div' method for this operator",
    );
    b.add(
        "an equality of secrets",
        "fn f(a: Secret<u32>, b: Secret<u32>) bool {\n    return a == b;\n}\n",
        "'Secret<u32>' has no 'eq' method for this operator (implement Eq): its 'eq' does not return 'bool'",
    );
    b.add(
        "an order of secrets",
        "fn f(a: Secret<u32>, b: Secret<u32>) bool {\n    return a < b;\n}\n",
        "'Secret<u32>' has no 'cmp' method for this operator (implement Ord)",
    );
    b.add("a read of the field", "fn f(a: Secret<u32>) u32 {\n    return a.v;\n}\n", "field 'v' is private");
    b.add(
        "a cast out of a secret",
        "fn f(a: Secret<u32>) u32 {\n    return a as u32;\n}\n",
        "invalid cast from 'Secret<u32>' to 'u32'",
    );
    b.add_at(
        "an attribute on a struct",
        "@constant_time\nstruct S {}\n",
        "'@constant_time' may only be applied to a function with a body, not a spec function or a lemma",
        "3:1",
    );
    b.add_at(
        "an attribute on a spec function",
        "@constant_time\nspec fn g(x: int) int {\n    return x;\n}\n",
        "'@constant_time' may only be applied to a function with a body, not a spec function or a lemma",
        "3:1",
    );
    h::expect_build_errs(b);
}

// Rejected by the check: a C function that takes a `Secret` may read it with any operation, so no function
// calls it or takes its address, a constant-time one (checked though nothing calls it) or not.
@test
fn secrets_reach_no_c_function() {
    let leak = "a call or the address of a C function that takes a 'Secret'";
    let mut b = cli::Batch::new(SECRET, "");
    let ext = "extern \"C\" {\n    fn leak(s: Secret<u32>) u32;\n}\n";
    b.add_at(
        "a call in constant-time code",
        format(
            "{}@constant_time\nfn f(a: Secret<u32>) u32 {{\n    return unsafe leak(a);\n}}\nfn main() i32 {{\n    return f(Secret::new(1)) as i32;\n}}\n",
            ext,
        ).as_str(),
        leak,
        "7:19",
    );
    b.add_at(
        "a call outside it",
        format("{}fn main() i32 {{\n    return unsafe leak(Secret::new(1)) as i32;\n}}\n", ext).as_str(),
        leak,
        "6:19",
    );
    b.add_at(
        "its address",
        format("{}fn main() i32 {{\n    let g = unsafe leak;\n    return unsafe g(Secret::new(1)) as i32;\n}}\n", ext).as_str(),
        leak,
        "7:21",
    );
    b.add_at(
        "a constant-time function nothing calls",
        format(
            "{}@constant_time\nfn f(a: Secret<u32>) u32 {{\n    return unsafe leak(a);\n}}\nfn main() i32 {{\n    return 0;\n}}\n",
            ext,
        ).as_str(),
        leak,
        "7:19",
    );
    h::expect_build_errs(b);
}

@test
fn exit_cases_01() {
    let mut b = h::ExitBatch::new();
    secret_operations(&mut b);
    b.run();
}

// Each operation of `Secret` against the integer it models, at each width, and the constant-time
// kernels against their plain versions: a quarter round, a conditional swap, a table read at a secret
// index, a comparison of byte strings, a loop over secret bytes (vectorized in release), and secrets
// through a closure, a `dyn` call, a `Vector` and a helper that is not constant-time.
fn secret_operations(b: &mut h::ExitBatch) {
    b.add("operations against their integers", OPERATIONS, 0);
    b.add("kernels against their plain versions", KERNELS, 0);
}

const OPERATIONS: str = M"(import std::crypto::secret as *;
fn check32(x: u32, y: u32, n: u32) bool {
    let a = Secret::<u32>::new(x);
    let c = Secret::<u32>::new(y);
    return (a + c).declassify() == x.wrapping_add(y) && (a - c).declassify() == x.wrapping_sub(y) && (a * c).declassify() == x.wrapping_mul(y) && (-a).declassify() == 0u32.wrapping_sub(x) && (a & c).declassify() == (x & y) && (a | c).declassify() == (x | y) && (a ^ c).declassify() == (x ^ y) && (~a).declassify() == ~x && (a << n as usize).declassify() == (x << n) && (a >> n as usize).declassify() == (x >> n) && a.rotate_left(n).declassify() == x.rotate_left(n) && a.rotate_right(n).declassify() == x.rotate_right(n) && a.eq(c).declassify() == (x == y) && a.ne(c).declassify() == (x != y) && a.lt(c).declassify() == (x < y) && a.le(c).declassify() == (x <= y) && a.gt(c).declassify() == (x > y) && a.ge(c).declassify() == (x >= y) && Secret::pick(a.lt(c), a, c).declassify() == x.min(y) && a.cast::<u8>().declassify() == x as u8 && a.cast::<u64>().declassify() == x as u64;
}
fn check64(x: u64, y: u64) bool {
    let a = Secret::<u64>::new(x);
    let c = Secret::<u64>::new(y);
    return a.lt(c).declassify() == (x < y) && a.ge(c).declassify() == (x >= y) && a.eq(c).declassify() == (x == y) && (a * c).declassify() == x.wrapping_mul(y) && a.rotate_left(13).declassify() == x.rotate_left(13);
}
fn check8(x: u8, y: u8) bool {
    let a = Secret::<u8>::new(x);
    let c = Secret::<u8>::new(y);
    return (a + c).declassify() == x.wrapping_add(y) && (~a).declassify() == ~x && a.lt(c).declassify() == (x < y) && a.rotate_left(3).declassify() == x.rotate_left(3);
}
fn checkb(x: bool, y: bool) bool {
    let a = Secret::<bool>::new(x);
    let c = Secret::<bool>::new(y);
    return (a & c).declassify() == (x && y) && (a | c).declassify() == (x || y) && (a ^ c).declassify() == (x != y) && (~a).declassify() == !x && a.eq(c).declassify() == (x == y) && Secret::pick(a, c, ~c).declassify() == (if x { y } else { !y });
}
fn main() i32 {
    let xs: [u32; 6] = [0, 1, 7, 0x80000000, 0xFFFFFFFF, 0x12345678];
    let ns: [u32; 3] = [0, 5, 31];
    for i in 0..6 {
        for j in 0..6 {
            if !check32(xs[i], xs[j], ns[(i + j) % 3]) {
                return 1;
            }
        }
    }
    let ws: [u64; 5] = [0, 1, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF];
    for i in 0..5 {
        for j in 0..5 {
            if !check64(ws[i], ws[j]) {
                return 2;
            }
        }
    }
    if !check8(200, 100) || !check8(0, 255) || !check8(255, 255) {
        return 3;
    }
    for i in 0..4 {
        if !checkb(i % 2 == 1, i / 2 == 1) {
            return 4;
        }
    }
    let k: [Secret<u16>; 2] = [Secret::new(300), Secret::new(7)];
    return if (k[0] + k[1]).declassify() == 307 { 0 } else { 5 };
}
)";

const KERNELS: str = M"(import std::crypto::secret as *;
@constant_time
fn quarter(s: &mut [Secret<u32>; 4]) {
    s[0] = s[0] + s[1];
    s[3] = (s[3] ^ s[0]).rotate_left(16);
    s[2] = s[2] + s[3];
    s[1] = (s[1] ^ s[2]).rotate_left(12);
    s[0] = s[0] + s[1];
    s[3] = (s[3] ^ s[0]).rotate_left(8);
    s[2] = s[2] + s[3];
    s[1] = (s[1] ^ s[2]).rotate_left(7);
}
fn quarter_plain(s: &mut [u32; 4]) {
    s[0] = s[0].wrapping_add(s[1]);
    s[3] = (s[3] ^ s[0]).rotate_left(16);
    s[2] = s[2].wrapping_add(s[3]);
    s[1] = (s[1] ^ s[2]).rotate_left(12);
    s[0] = s[0].wrapping_add(s[1]);
    s[3] = (s[3] ^ s[0]).rotate_left(8);
    s[2] = s[2].wrapping_add(s[3]);
    s[1] = (s[1] ^ s[2]).rotate_left(7);
}
@constant_time
fn cswap(c: Secret<bool>, a: &mut [Secret<u64>; 3], b: &mut [Secret<u64>; 3]) {
    for i in 0..3 {
        let x = Secret::pick(c, b[i], a[i]);
        let y = Secret::pick(c, a[i], b[i]);
        a[i] = x;
        b[i] = y;
    }
}
@constant_time
fn lookup(t: &[u8; 8], i: Secret<usize>) Secret<u8> {
    let mut r = Secret::<u8>::new(0);
    for k in 0..8usize {
        r = Secret::pick(i.eq(Secret::new(k)), Secret::new(t[k]), r);
    }
    return r;
}
@constant_time
fn same(a: []Secret<u8>, b: []Secret<u8>) bool {
    if a.len() != b.len() {
        return false;
    }
    let mut d = Secret::<u8>::new(0);
    for i in 0..a.len() {
        d = d | (a[i] ^ b[i]);
    }
    return d.eq(Secret::new(0)).declassify();
}
@constant_time
fn xor_into(d: []mut Secret<u8>, k: []Secret<u8>) {
    for i in 0..d.len() {
        d[i] = d[i] ^ k[i];
    }
}
interface Mixer {
    fn mix(self: &Self, a: Secret<u32>) Secret<u32>;
}
struct Key {
    k: Secret<u32>,
}
extend Key as Mixer {
    fn mix(self: &Key, a: Secret<u32>) Secret<u32> {
        return a ^ self.k;
    }
}
fn twice(a: Secret<u32>) Secret<u32> {
    return a + a;
}
@constant_time
fn mixed(m: &dyn Mixer, a: Secret<u32>, ks: []Secret<u8>) Secret<u32> {
    let g = |x: Secret<u32>| twice(x) + a;
    let mut v = Vector::<Secret<u8>>::new();
    for i in 0..ks.len() {
        v.push(ks[i]);
    }
    let mut x = Secret::<u8>::new(0);
    for i in 0..v.len() {
        x = x ^ v[i];
    }
    return g(m.mix(a)) + x.cast::<u32>();
}
fn main() i32 {
    let mut s: [Secret<u32>; 4] = [Secret::new(0x11111111), Secret::new(0x01020304), Secret::new(0x9b8d6f43), Secret::new(0x01234567)];
    let mut p: [u32; 4] = [0x11111111, 0x01020304, 0x9b8d6f43, 0x01234567];
    quarter(&mut s);
    quarter_plain(&mut p);
    for i in 0..4 {
        if s[i].declassify() != p[i] {
            return 1;
        }
    }
    if p[0] != 0xea2a92f4 || p[3] != 0x5881c4bb {
        return 2;
    }
    let mut a: [Secret<u64>; 3] = [Secret::new(1), Secret::new(2), Secret::new(3)];
    let mut b: [Secret<u64>; 3] = [Secret::new(4), Secret::new(5), Secret::new(6)];
    cswap(Secret::new(false), &mut a, &mut b);
    if a[0].declassify() != 1 || b[2].declassify() != 6 {
        return 3;
    }
    cswap(Secret::new(true), &mut a, &mut b);
    if a[0].declassify() != 4 || a[2].declassify() != 6 || b[1].declassify() != 2 {
        return 4;
    }
    let t: [u8; 8] = [9, 8, 7, 6, 5, 4, 3, 2];
    for i in 0..8usize {
        if lookup(&t, Secret::new(i)).declassify() != t[i] {
            return 5;
        }
    }
    let m: [Secret<u8>; 3] = [Secret::new(1), Secret::new(2), Secret::new(3)];
    let n: [Secret<u8>; 3] = [Secret::new(1), Secret::new(2), Secret::new(4)];
    if !same(m, m) || same(m, n) || same(m, n[0..2]) {
        return 6;
    }
    let mut d: [Secret<u8>; 64] = [Secret::new(0x5a); 64];
    let k: [Secret<u8>; 64] = [Secret::new(0x0f); 64];
    d[3] = Secret::new(1);
    xor_into(&mut d[0..], k[0..]);
    if d[0].declassify() != 0x55 || d[3].declassify() != 0x0e || d[63].declassify() != 0x55 {
        return 7;
    }
    let key = Key { k: Secret::new(6) };
    let ks: [Secret<u8>; 3] = [Secret::new(1), Secret::new(2), Secret::new(4)];
    if mixed(&key, Secret::new(3), ks).declassify() != 20 {
        return 8;
    }
    return 0;
}
)";

// The optimized build passes the check and computes what the debug build does.
@test
fn constant_time_holds_in_release() {
    let mut src = String::from_str(KERNELS);
    let at = src.as_str().find("    return 0;\n}\n");
    assert(at > 0, "the kernels' last return");
    let mut p = String::from_str(src.as_str().slice(0, at as usize));
    p.push_str(
        "    println(\"{} {}\", s[1].declassify(), lookup(&t, Secret::new(5)).declassify());\n    return 0;\n}\n",
    );
    src = p;
    h::expect_same_output("the kernels", &src, ["--profile=debug"], ["--profile=release"]);
}

// `--emit-c` takes the constant-time functions as the native backend compiled them after the check: the
// tree's object (`__sc_ct.o`, a unit) defines them, its C declares them alone, and the C compiler builds a
// program that computes what the native one does.
@test
fn the_c_tree_takes_the_checked_code() {
    let p = cli::proj_new();
    p.mkfile("main.spc", KERNELS);
    let r = p.compile("main.spc");
    assert(r.ok(), "the C tree is written");
    assert(p.gen_has("__units", "__sc_ct.o"), "the object is a unit");
    let decl = "void main__quarter(secret__Secret__u32__a4 *restrict s)";
    assert(p.gen_has("main.c", format("{};", decl).as_str()), "the C declares the function");
    assert(!p.gen_has("main.c", format("{} {{", decl).as_str()), "the C does not define it");
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    assert(p.cc_build("").ok(), "the C tree builds");
    assert(p.run_bin_env("").ok(), "the program computes what the native one does");
}
