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
import tests::harness as h;
import tests::cli_harness as cli;
import target::table as tgt;
import std::cpu;
import std::cpu::detect as detect;

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
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: vector,
            interleave: vector,
            fin: 0,
        },
    );
}

// `optimized_fm` with the loop transforms' budgets `bu`.
fn optimized_loops(text: str, fm: u8, fma: bool, bu: lu::Budgets) (Package, Package) {
    return optimized_cfg(text, fm, fma, il::SPEED, bu);
}

fn optimized_cfg(text: str, fm: u8, fma: bool, inl: il::Budget, bu: lu::Budgets) (Package, Package) {
    return optimized_split(text, fm, fma, inl, bu, false, false);
}

// `optimized_cfg` with each 128-bit integer split into its two words when `pairs` (`Package.pairs`), the
// switches lowered to compares and branches when `switches` (`Package.switch_tree`).
fn optimized_split(text: str, fm: u8, fma: bool, inl: il::Budget, bu: lu::Budgets, pairs: bool, switches: bool) (
    Package,
    Package
) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.fmath = fm;
    after.fma = fma;
    after.pairs = pairs;
    after.switch_tree = switches;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut after, &none, lopt::Config { inline: inl, loops: bu });
    verified(&after);
    return (before, after);
}

// Each function of `p` verifies.
fn verified(p: &Package) {
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            let b = &p.bodies[s.def as usize];
            assert(v.check(p, p.spell(s.name), b) && v.check_calls(p, p.spell(s.name), b), v.err.as_str());
        }
    }
}

// `optimized` for a target that passes aggregates of up to `copy` bytes by value (`Package.arg_copy`; at
// most 16 in registers) and returns those of up to `ret` bytes in registers (`Package.ret_regs`).
fn optimized_copy(text: str, copy: u32, ret: u32) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.arg_copy = copy;
    after.ret_regs = ret;
    let none = Vector::<bool>::new();
    lopt::optimize(
        &mut after,
        &none,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 0,
                interleave: 0,
                fin: 0,
            },
        },
    );
    verified(&after);
    return (before, after);
}

// The text of function `name` of `p`.
fn text_of(p: &Package, name: str) String {
    let mut all = String::new();
    lprint::print_package(p, &mut all);
    let head = format("fn @{}\n", name);
    let at = all.as_str().find(&head);
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
const fn block_at(t: str, at: usize) str {
    let mut from = at;
    // Each step goes back one byte.
    while from > 0 && !(t.byte_at(from - 1) == b'\n' && t.byte_at(from) == b'b') {
        from -= 1;
    }
    let n = t.slice(at, t.len()).find("\nb");
    let to = if n >= 0 {
        at + n as usize
    } else {
        t.len()
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

// A private function whose calls from its module's own functions all pass one constant gets a copy
// without that parameter (`lir::opt`'s `specialize`): `mode`'s copy only multiplies, `scaled`'s copy keeps
// calling itself without the scale it passes on, and the instance of `seven`, whose call passes another
// constant, keeps calling `mode` itself.
const CONST_ARGS: str = M"(static mut SINK: usize = 0;

@noinline
fn opr<T>(x: T) T {
    unsafe SINK += 1;
    return x;
}

@noinline
fn mode(x: u32, m: u32) u32 {
    if m == 3 {
        return x * 5;
    }
    return x / m + x % m;
}

@noinline
fn scaled(n: u32, k: u32) u32 {
    if n == 0 {
        return 0;
    }
    return k + scaled(n - 1, k);
}

@noinline
fn seven<T>(x: u32) u32 {
    return mode(x, 7);
}

fn main() i32 {
    let a = mode(opr::<u32>(10), 3) + mode(opr::<u32>(11), 3);
    let b = scaled(opr::<u32>(4), 6);
    let c = seven::<u8>(opr::<u32>(20));
    println("{} {} {}", a, b, c);
    return 0;
}
)";

// Assert that `src` gives the same output built for debug and for release, and return the release
// build's `SC_LIR_PRINT=name` output: one release build serves both. The vector lane builds every
// differential program for wasm32, so there the text comes from a host build of its own.
fn same_and_printed(label: str, src: str, name: str) String {
    let print = format("SC_LIR_PRINT={}", name);
    let a = h::diff_build(src, ["--profile=debug"]);
    let b = h::diff_build(src, ["--profile=release", print.as_str()]);
    if !a.built || !b.built {
        eprintln("{}: {}{}", label, a.diag.as_str(), b.diag.as_str());
    }
    assert(a.built && b.built, label);
    let d = h::same_runs(&a, &b, [""]);
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
    if !h::simd_lane() {
        return String::from_str(&b.diag);
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", name, "build --profile=release main.spc -o app");
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), label);
    return String::from_str(r.text());
}

// The text of function `name` in `SC_LIR_PRINT` output `out`: to the next function.
fn printed<'a>(out: str<'a>, name: str) str<'a> {
    let head = format("fn @{}\n", name);
    let at = out.find(&head);
    if at < 0 {
        return "";
    }
    let rest = out.slice(at as usize, out.len());
    let end = rest.slice(1, rest.len()).find("\nfn @");
    return if end < 0 {
        rest
    } else {
        rest.slice(0, end as usize + 1)
    };
}

@test
fn a_constant_every_call_passes_makes_a_copy_without_it() {
    h::expect_same_output("constant arguments", CONST_ARGS, ["--profile=debug"], ["--profile=release"]);
    let p = cli::proj_new();
    p.mkfile("main.spc", CONST_ARGS);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "mode", "build -O2 main.spc -o app");
    let m = printed(r.text(), "mode.cp2");
    let ok = r.ok() && m.contains("sig (i32) -> i32") && m.contains("mul.i32") && !m.contains("udiv") && printed(
        r.text(),
        "mode",
    ).contains("udiv");
    if !ok {
        r.show();
    }
    assert(ok, "the copy of mode multiplies; mode keeps its division for the instance's call");
    // A fresh project: the first build's cache would replay the unit, whose bodies then print nothing.
    let q = cli::proj_new();
    q.mkfile("main.spc", CONST_ARGS);
    let s = cli::superc_env_in(q.dir(), "SC_LIR_PRINT", "scaled", "build -O2 main.spc -o app");
    let c = printed(s.text(), "scaled.cp2");
    if !s.ok() || !c.contains("sig (i32) -> i32") {
        s.show();
    }
    assert(s.ok() && c.contains("sig (i32) -> i32"), "the recursion's copy takes the count alone");
}

// A `mut` by-value `[]mut T` parameter the body writes only through its elements (a store, a `&mut` of
// one) keeps its header as it came in (`inner noalias`), so the stores leave its length known; one the
// body assigns, or a closure of the body captures, does not.
const MUT_VIEW: str = M"(@noinline
fn hdr_elems(mut a: []mut i64) i64 {
    a[6] = 1;
    let r = &mut a[2];
    *r = 4;
    a[5] = 1;
    return 13;
}
@noinline
fn hdr_rebound(mut a: []mut i64, n: usize) i64 {
    a = a.index_range_mut(0..n);
    a[0] = 1;
    return 1;
}
@noinline
fn hdr_captured<'a>(mut a: []'a mut i64, short: []'a mut i64) i64 {
    a[3] = 1;
    let mut f = || {
        a = short;
    };
    f();
    a[0] = 1;
    return 1;
}
fn main(argv: Vector<str>) i32 {
    let mut v = Vector::<i64>::new();
    let mut w = Vector::<i64>::new();
    for k in 0..8 {
        v.push(k as i64);
        w.push(k as i64);
    }
    let n = hdr_elems(v.as_mut_slice()) + hdr_rebound(v.as_mut_slice(), argv.len());
    return (n + hdr_captured(v.as_mut_slice(), w.as_mut_slice())) as i32 - 15;
}
)";

@test
fn a_mut_view_parameter_the_body_does_not_rebind_keeps_its_header() {
    let p = cli::proj_new();
    p.mkfile("main.spc", MUT_VIEW);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "hdr_", "build -O2 main.spc -o app");
    let t = r.text();
    let ok = r.ok() && printed(t, "hdr_elems").contains("ref p0 8 inner noalias") && !printed(t, "hdr_rebound").contains(
        "ref p0 8 inner",
    ) && !printed(t, "hdr_captured").contains("ref p0 8 inner");
    if !ok {
        r.show();
    }
    assert(ok, "the element-only `mut` view keeps its header; the reassigned and the captured ones do not");
}

const VERSION_LEVELS: str = M"(@noinline
fn ver_one(a: []i32, n: usize) i32 {
    let mut s: i32 = 0;
    for i in 0..n {
        s = s.wrapping_mul(31).wrapping_add(a[i]);
    }
    return s;
}

@noinline
fn ver_sum(a: []i32, n: usize) i32 {
    let mut s: i32 = 0;
    for i in 0..n {
        s = s.wrapping_add(a[i]);
    }
    return s;
}

@noinline
fn ver_two(a: []i32, b: []i32, n: usize) i32 {
    let mut s: i32 = 0;
    for i in 0..n {
        s = s.wrapping_mul(31).wrapping_add(a[i]).wrapping_add(b[i]);
    }
    return s;
}

fn main() i32 {
    let mut v = Vector::<i32>::new();
    for k in 0..40usize {
        v.push(k as i32);
    }
    println("{} {} {}", ver_one(&v, 40), ver_sum(&v, 40), ver_two(&v, &v, 30));
    return 0;
}
)";

// Whether body text `t` has a bounds check (`icmp.uge`) in a block that is neither cold nor unlikely: one
// each iteration runs, not one only a versioned loop's checked copy or its last step runs.
const fn hot_check(t: str) bool {
    let mut rest = t;
    let mut cold = false;
    // Each step reads one line.
    while rest.len() != 0 {
        let n = rest.find("\n");
        let end = if n < 0 {
            rest.len()
        } else {
            n as usize
        };
        let line = rest.slice(0, end);
        if line.starts_with("b") {
            cold = line.contains("unlikely") || line.contains("cold");
        } else if !cold && line.contains("icmp.uge") {
            return true;
        }
        rest = rest.slice(
            if n < 0 {
                end
            } else {
                end + 1
            },
            rest.len(),
        );
    }
    return false;
}

// `-O2` versions a loop with one bounds check and keeps the checks of a loop with two (`version_checks`
// 1); `-O3` versions both: no check runs each iteration. The sums are recurrences, which no vectoriser
// takes with their checks before versioning does. A plain sum versions before it vectorizes: its vector
// loop compares no lane's index with the length.
@test
fn o2_versions_loops_with_one_check() {
    let levels: [str; 2] = ["-O2", "-O3"];
    for k in 0..2usize {
        // A fresh project each time: the first build's cache would replay the unit, whose bodies then
        // print nothing.
        let p = cli::proj_new();
        p.mkfile("main.spc", VERSION_LEVELS);
        let r = cli::superc_env_in(
            p.dir(),
            "SC_LIR_PRINT",
            "ver_",
            format("build {} main.spc -o app", levels[k]).as_str(),
        );
        let one = hot_check(printed(r.text(), "ver_one"));
        let two = hot_check(printed(r.text(), "ver_two"));
        let sum = printed(r.text(), "ver_sum");
        let clean = !hot_check(sum) && sum.contains("load.v") && !sum.contains("vcmp.uge");
        let ok = r.ok() && !one && two == (k == 0) && clean;
        if !ok {
            r.show();
        }
        assert(ok, levels[k]);
    }
}

// A copy loop goes, a `memcpy` in its place, whatever the numbers of its instructions: `mem_run` reads the
// other instructions' operands and the edges' arguments, not their other fields (with 4, 6 or 8 stores before
// it, an edge's or a constant's field equals the load's number). `@run` copies 5 bytes after `@c4`'s stores.
@test
fn copy_loops_go_whatever_their_numbers() {
    let (b, a) = optimized_loops(
        M"(lir ptr 4
sym @c4 fn global noinline
sym @c6 fn global noinline
sym @c8 fn global noinline
sym @run fn global
sym @buf data global
sym @src data global
sym @pad data global
fn @c4
  sig (ptr, ptr, i32, ptr) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i32, v3: ptr):
  store v2, v3+0 align 0
  store v2, v3+4 align 0
  store v2, v3+8 align 0
  store v2, v3+12 align 0
  v4 = iconst.i32 0
  v5 = iconst.i32 1
  jmp b1(v4)
b1(v6: i32):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = ptradd v0, v6 * 1
  store v9, v10 align 0
  v11 = add.i32 v6, v5
  jmp b1(v11)
b3:
  ret
fn @c6
  sig (ptr, ptr, i32, ptr) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i32, v3: ptr):
  store v2, v3+0 align 0
  store v2, v3+4 align 0
  store v2, v3+8 align 0
  store v2, v3+12 align 0
  store v2, v3+16 align 0
  store v2, v3+20 align 0
  v4 = iconst.i32 0
  v5 = iconst.i32 1
  jmp b1(v4)
b1(v6: i32):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = ptradd v0, v6 * 1
  store v9, v10 align 0
  v11 = add.i32 v6, v5
  jmp b1(v11)
b3:
  ret
fn @c8
  sig (ptr, ptr, i32, ptr) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i32, v3: ptr):
  store v2, v3+0 align 0
  store v2, v3+4 align 0
  store v2, v3+8 align 0
  store v2, v3+12 align 0
  store v2, v3+16 align 0
  store v2, v3+20 align 0
  store v2, v3+24 align 0
  store v2, v3+28 align 0
  v4 = iconst.i32 0
  v5 = iconst.i32 1
  jmp b1(v4)
b1(v6: i32):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = ptradd v0, v6 * 1
  store v9, v10 align 0
  v11 = add.i32 v6, v5
  jmp b1(v11)
b3:
  ret
fn @run
  sig (i32) -> i64
b0(v0: i32):
  v1 = symaddr @buf
  v2 = symaddr @src
  v3 = symaddr @pad
  call @c4(v1, v2, v0, v3) : (ptr, ptr, i32, ptr) -> void
  v4 = load.i64 v1 align 3
  ret v4
data @buf size 8 align 3 bytes aaaaaaaaaaaaaaaa
data @src size 8 align 3 bytes 0001020304050607
data @pad size 32 align 3 bytes 0000000000000000000000000000000000000000000000000000000000000000
)",
        0,
        false,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 512,
        },
    );
    for name in ["c4", "c6", "c8"] {
        let c = text_of(&a, name);
        assert(c.contains("memcpy") && !c.contains("load.i8"), c.as_str());
    }
    let five: []u64 = [5];
    same_result(&b, &a, "run", five, 0xAAAAAA0403020100u64);
}

// A loop that copies each 12-byte element as an 8-byte and a 4-byte pair goes, one `memcpy` of 12 bytes an
// element in its place (`mem_pairs`); one whose pairs leave 4 bytes of each element (a 16-byte step) stays.
@test
fn a_copy_loop_of_pairs_covering_its_element_goes() {
    let (b, a) = optimized_loops(
        M"(lir ptr 8
sym @pairs fn global noinline
sym @holes fn global noinline
sym @run fn global
fn @pairs
  sig (ptr, ptr, i64) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 12
  v8 = load.i64 v7 align 0
  v9 = load.i32 v7+8 align 0
  v10 = ptradd v0, v5 * 12
  store v8, v10 align 0
  store v9, v10+8 align 0
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
fn @holes
  sig (ptr, ptr, i64) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 16
  v8 = load.i64 v7 align 0
  v9 = load.i32 v7+8 align 0
  v10 = ptradd v0, v5 * 16
  store v8, v10 align 0
  store v9, v10+8 align 0
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
fn @run
  sig (i64) -> i64
  slot s0 size 64 align 3
  slot s1 size 64 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 72623859790382856
  v4 = iconst.i64 -1
  store v3, v1 align 3
  store v4, v1+8 align 3
  store v3, v1+16 align 3
  store v4, v1+24 align 3
  store v3, v1+32 align 3
  store v4, v1+40 align 3
  call @pairs(v2, v1, v0) : (ptr, ptr, i64) -> void
  v5 = load.i64 v2 align 3
  v6 = load.i64 v2+16 align 3
  v7 = xor.i64 v5, v6
  ret v7
)",
        0,
        false,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 512,
        },
    );
    let p = text_of(&a, "pairs");
    assert(p.contains("memcpy") && !p.contains("load.i32"), p.as_str());
    let h = text_of(&a, "holes");
    assert(!h.contains("memcpy") && h.contains("load.i32"), h.as_str());
    for n in 0..4u64 {
        let args: []u64 = [n];
        same_result(&b, &a, "run", args, run_of(&b, "run", args));
    }
}

// A parameter's range for the call (`range`: a pattern type, a proved `requires`) settles a compare and
// an overflow check of it, unsigned and signed; the same body without the range keeps both.
@test
fn parameter_ranges_settle_compares_and_overflow_checks() {
    let body = M"(  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 3
  v3, v4 = mulo.u.i32 v0, v2
  br v4, b3, b1
b1:
  v5 = iconst.i32 200
  v6 = icmp.ult v0, v5
  br v6, b2, b4
b2:
  v7 = iconst.i32 -10
  v8 = icmp.slt v1, v7
  v9 = zext.i32 v8
  v10 = add.i32 v3, v9
  ret v10
b3: cold
  panic "attempt to multiply with overflow"
b4:
  v11 = iconst.i32 7
  ret v11
)";
    let text = format(
        "lir ptr 8\nsym @ranged fn global noinline\nsym @plain fn global noinline\nsym @drive fn global\nfn @ranged\n  range p0 u 1 99\n  range p1 s -5 5\n{}fn @plain\n{}fn @drive\n  sig () -> i32\nb0:\n  v0 = iconst.i32 4\n  v1 = iconst.i32 -2\n  v2 = call.i32 @ranged(v0, v1) : (i32, i32) -> i32\n  v3 = call.i32 @plain(v0, v1) : (i32, i32) -> i32\n  v4 = add.i32 v2, v3\n  ret v4\n",
        body,
        body,
    );
    let (b, a) = optimized(&text);
    let r = text_of(&a, "ranged");
    assert(r.contains("range p0 u 1 99") && r.contains("range p1 s -5 5"), "the ranges print");
    assert(!r.contains("icmp") && !r.contains("mulo") && !r.contains("panic"), r.as_str());
    let p = text_of(&a, "plain");
    assert(p.contains("icmp.ult") && p.contains("mulo") && p.contains("icmp.slt"), p.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 24);
}

// A constant-time body (`ct`) is copied only into a constant-time caller, where the check sees the copy
// (`lir::ct`); a caller that is not keeps the call, whose body the check saw.
@test
fn a_constant_time_body_inlines_only_into_a_constant_time_caller() {
    let (_, a) = optimized(
        M"(lir ptr 8
sym @k fn global
sym @plain fn global
sym @both fn global
fn @k
  sig (i64) -> i64
  ct
b0(v0: i64):
  v1 = iconst.i64 3
  v2 = add.i64 v0, v1
  ret v2
fn @plain
  sig (i64) -> i64
b0(v0: i64):
  v1 = call.i64 @k(v0) : (i64) -> i64
  ret v1
fn @both
  sig (i64) -> i64
  ct
b0(v0: i64):
  v1 = call.i64 @k(v0) : (i64) -> i64
  ret v1
)",
    );
    let p = text_of(&a, "plain");
    assert(p.as_str().find("call.i64 @k(") >= 0, p.as_str());
    let b = text_of(&a, "both");
    assert(b.as_str().find("call") < 0 && b.as_str().find("add.i64") >= 0, b.as_str());
}

// A view's length is at most `isize::MAX` over its element's bytes (`ref p0 4 inner`), so it never passes
// `usize::MAX - 8`; a length of an element size unknown (`ref p1 0 inner`) may. The minimum of two values is
// at most each, and a select is at most the larger of its sides: `min(len0, len2) <= usize::MAX - 8`.
@test
fn view_lengths_and_minimums_settle_compares() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @lens fn global noinline
sym @drive fn global
fn @lens
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, l0, l0) -> i8
  ref p0 4 inner readonly
  ref p1 0 inner readonly
  ref p2 8 inner readonly
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.i64 v0+8 align 3
  v4 = load.i64 v1+8 align 3
  v5 = load.i64 v2+8 align 3
  v6 = iconst.i64 -9
  v7 = icmp.ugt v3, v6
  v8 = icmp.ugt v4, v6
  v9 = icmp.ult v3, v4
  v10 = select.i64 v9, v3, v4
  v11 = icmp.ule v10, v4
  v12 = icmp.ult v3, v5
  v13 = select.i64 v12, v3, v5
  v14 = icmp.ule v13, v6
  v15 = xor.i8 v7, v8
  v16 = and.i8 v15, v11
  v17 = and.i8 v16, v14
  ret v17
fn @drive
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig () -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i64 0
  v3 = iconst.i64 3
  v4 = iconst.i64 -1
  store v2, v0 align 3
  store v3, v0+8 align 3
  store v2, v1 align 3
  store v4, v1+8 align 3
  v5 = call.i8 @lens(v0, v1, v0) : (l0, l0, l0) -> i8
  v6 = call.i8 @lens(v0, v0, v0) : (l0, l0, l0) -> i8
  v7 = zext.i64 v5
  v8 = zext.i64 v6
  v9 = add.i64 v7, v7
  v10 = add.i64 v9, v8
  ret v10
)",
    );
    let l = text_of(&a, "lens");
    assert(count_of(&l, "icmp.ugt") == 1 && count_of(&l, "icmp.ule") == 0 && count_of(&l, "select") == 0, l.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 2);
}

// Two exit tests become one (`merge_exits`): the second's copy reads the values the walk gave its operands
// before it (the slot's load is the stored `n`), not the instructions they replaced: the store a later one
// overwrote goes, and the load would read the later value.
@test
fn merged_exit_tests_read_the_forwarded_values() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sink fn global noinline
sym @g fn global noinline
sym @drive fn global
fn @sink
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
  ret
fn @g
  sig (i64, i64, i64) -> i32
  slot s0 size 8 align 3
b0(v0: i64, v1: i64, v2: i64):
  v3 = slotaddr s0
  store v2, v3 align 3
  v4 = load.i64 v3 align 3
  v5 = iconst.i64 7
  store v5, v3 align 3
  call @sink(v3) : (ptr) -> void
  v6 = icmp.ugt v0, v1
  br v6, b2, b1
b1:
  v7 = icmp.ugt v1, v4
  br v7, b2, b3
b2:
  v8 = iconst.i32 1
  ret v8
b3:
  v9 = iconst.i32 0
  ret v9
fn @drive
  sig () -> i32
b0:
  v0 = iconst.i64 1
  v1 = iconst.i64 8
  v2 = iconst.i64 10
  v3 = call.i32 @g(v0, v1, v2) : (i64, i64, i64) -> i32
  ret v3
)",
    );
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 0);
}

const BUMP: str = M"(@noinline
fn bump(s: []mut u32, f: bool) {
    for k in 0..s.len() {
        if f {
            s[k] += 1;
        } else {
            s[k] -= 1;
        }
    }
}

fn main(args: Vector<str>) i32 {
    let mut v = Vector::<u32>::new();
    for k in 0..37u32 {
        v.push(k * 3 + 5);
    }
    bump(v.as_mut_slice(), true);
    bump(v.as_mut_slice(), args.len() == 0);
    bump(v.as_mut_slice(), true);
    let mut t: u32 = 0;
    for k in 0..37usize {
        t += v[k] * (k as u32 + 1);
    }
    println("{}", t);
    return 0;
}
)";

const TWO_PUSHES: str<'static> = M"(@noinline
fn two(x: u32) u32 {
    let mut v = Vector::<u32>::new();
    v.push(x);
    v.push(x + 1);
    return v[0] + v[1];
}
@noinline
fn two_more(v: &mut Vector<u32>, x: u32) {
    v.push(x);
}
fn main() i32 {
    let mut v = Vector::<u32>::new();
    for i in 0..100 {
        two_more(&mut v, i as u32);
    }
    println("{} {}", two(20), v[99]);
    return 0;
}
)";

// A vector's growth stays out of line where its capacity is unknown (`push` marks it unlikely: a rare
// block takes no copy bigger than its call), and inlines where the caller's values fold its branch: a
// vector known empty (`Run::job`'s second round over the copies' calls in warm blocks). Two pushes onto a
// new vector then keep nothing of it: no allocation, free, growth or bounds check, the sum of `x` and
// `x + 1`. A push onto a vector of unknown capacity calls the growth. Both profiles print the same.
@test
fn a_new_vectors_first_growth_inlines_and_its_buffer_goes() {
    let text = same_and_printed("two pushes", TWO_PUSHES, "two");
    let m = printed(&text, "two");
    let ok = m.len() != 0 && !m.contains("call") && !m.contains("load") && !m.contains("store") && !m.contains("slot");
    let g = printed(&text, "two_more");
    let out = g.contains("grow_for") && !g.contains("realloc");
    if !ok || !out {
        eprintln("{}", text.as_str());
    }
    assert(ok, "no allocation, growth, free or memory access");
    assert(out, "a push onto a vector of unknown capacity calls the growth");
}

// A loop whose branch on a parameter adds 1 on one side and subtracts 1 on the other adds the select of 1
// and -1 before it: one vector loop, no copy per side, though each side's load of the slice's address
// stays its own until the loop transforms run. Both profiles print the same sum.
@test
fn sides_that_add_and_subtract_one_merge() {
    let text = same_and_printed("merged sides", BUMP, "bump");
    let m = printed(&text, "bump");
    let ok = m.contains("select.i32") && m.contains("add.v4i32") && !m.contains("sub.v4i32");
    if !ok {
        eprintln("{}", text.as_str());
    }
    assert(ok, "one loop adds the select");
}

// A tail recursion over a slice whose every call passes one constant accumulator: its copy without it
// (`drop_params`, whose entry jumps to the old one) still copies the slice into a slot (`param_slots`), so
// its loop carries the slice in registers and stores nothing.
@test
fn a_tail_recursions_copy_carries_its_slice_in_registers() {
    let src = "@noinline\nfn slsum(s: []u32, acc: u32) u32 {\n    if s.len() == 0 {\n        return acc;\n    }\n    return slsum(s[1..s.len()], acc.wrapping_add(s[0]));\n}\n\nfn main(args: Vector<str>) i32 {\n    let v: [u32; 64] = [3; 64];\n    return slsum(v[0..args.len() * 10], 0) as i32;\n}\n";
    let p = cli::proj_new();
    p.mkfile("main.spc", src);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "slsum", "build -O2 main.spc -o app");
    let c = printed(r.text(), "slsum.cp2");
    let ok = r.ok() && c.contains("sig (l0) -> i32") && !c.contains("store");
    if !ok {
        r.show();
    }
    assert(ok, "the copy stores nothing");
}

// A callee past the inline budget (75 instructions against `FAST`'s 60) inlines when it is `@always_inline`
// (`Sym.always`) and stays a call otherwise.
const ALWAYS_INLINE: str = M"(@always_inline
fn mix(x: u64) u64 {
    let mut h = x;
    h = (h ^ (h >> 7)).wrapping_mul(0x9E3779B97F4A7C15);
    h = (h ^ (h >> 8)).wrapping_mul(0xC37D6E4ACEB75933);
    h = (h ^ (h >> 9)).wrapping_mul(0xE8C362DC1E24364F);
    h = (h ^ (h >> 10)).wrapping_mul(0xE09576D6D91136D);
    h = (h ^ (h >> 11)).wrapping_mul(0x334F4BFEBCFDF089);
    h = (h ^ (h >> 12)).wrapping_mul(0x589540900C6ACDA7);
    h = (h ^ (h >> 13)).wrapping_mul(0x7DDB35215BD7AAC3);
    h = (h ^ (h >> 14)).wrapping_mul(0xA32129B2AB4487E1);
    h = (h ^ (h >> 15)).wrapping_mul(0xC8671E43FAB164FD);
    h = (h ^ (h >> 16)).wrapping_mul(0xEDAD12D54A1E421B);
    h = (h ^ (h >> 17)).wrapping_mul(0x12F30766998B1F37);
    h = (h ^ (h >> 18)).wrapping_mul(0x3838FBF7E8F7FC55);
    h = (h ^ (h >> 19)).wrapping_mul(0x5D7EF0893864D971);
    h = (h ^ (h >> 20)).wrapping_mul(0x82C4E51A87D1B68F);
    h = (h ^ (h >> 21)).wrapping_mul(0xA80AD9ABD73E93AB);
    h = (h ^ (h >> 22)).wrapping_mul(0xCD50CE3D26AB70C9);
    h = (h ^ (h >> 23)).wrapping_mul(0xF296C2CE76184DE5);
    h = (h ^ (h >> 24)).wrapping_mul(0x17DCB75FC5852B03);
    h = (h ^ (h >> 25)).wrapping_mul(0x3D22ABF114F2081F);
    h = (h ^ (h >> 26)).wrapping_mul(0x6268A082645EE53D);
    h = (h ^ (h >> 27)).wrapping_mul(0x87AE9513B3CBC259);
    h = (h ^ (h >> 28)).wrapping_mul(0xACF489A503389F77);
    h = (h ^ (h >> 29)).wrapping_mul(0xD23A7E3652A57C93);
    h = (h ^ (h >> 30)).wrapping_mul(0xF78072C7A21259B1);
    h = (h ^ (h >> 31)).wrapping_mul(0x1CC66758F17F36CD);
    return h;
}

fn mix_plain(x: u64) u64 {
    let mut h = x;
    h = (h ^ (h >> 7)).wrapping_mul(0x9E3779B97F4A7C15);
    h = (h ^ (h >> 8)).wrapping_mul(0xC37D6E4ACEB75933);
    h = (h ^ (h >> 9)).wrapping_mul(0xE8C362DC1E24364F);
    h = (h ^ (h >> 10)).wrapping_mul(0xE09576D6D91136D);
    h = (h ^ (h >> 11)).wrapping_mul(0x334F4BFEBCFDF089);
    h = (h ^ (h >> 12)).wrapping_mul(0x589540900C6ACDA7);
    h = (h ^ (h >> 13)).wrapping_mul(0x7DDB35215BD7AAC3);
    h = (h ^ (h >> 14)).wrapping_mul(0xA32129B2AB4487E1);
    h = (h ^ (h >> 15)).wrapping_mul(0xC8671E43FAB164FD);
    h = (h ^ (h >> 16)).wrapping_mul(0xEDAD12D54A1E421B);
    h = (h ^ (h >> 17)).wrapping_mul(0x12F30766998B1F37);
    h = (h ^ (h >> 18)).wrapping_mul(0x3838FBF7E8F7FC55);
    h = (h ^ (h >> 19)).wrapping_mul(0x5D7EF0893864D971);
    h = (h ^ (h >> 20)).wrapping_mul(0x82C4E51A87D1B68F);
    h = (h ^ (h >> 21)).wrapping_mul(0xA80AD9ABD73E93AB);
    h = (h ^ (h >> 22)).wrapping_mul(0xCD50CE3D26AB70C9);
    h = (h ^ (h >> 23)).wrapping_mul(0xF296C2CE76184DE5);
    h = (h ^ (h >> 24)).wrapping_mul(0x17DCB75FC5852B03);
    h = (h ^ (h >> 25)).wrapping_mul(0x3D22ABF114F2081F);
    h = (h ^ (h >> 26)).wrapping_mul(0x6268A082645EE53D);
    h = (h ^ (h >> 27)).wrapping_mul(0x87AE9513B3CBC259);
    h = (h ^ (h >> 28)).wrapping_mul(0xACF489A503389F77);
    h = (h ^ (h >> 29)).wrapping_mul(0xD23A7E3652A57C93);
    h = (h ^ (h >> 30)).wrapping_mul(0xF78072C7A21259B1);
    h = (h ^ (h >> 31)).wrapping_mul(0x1CC66758F17F36CD);
    return h;
}

@noinline
fn forced_mix(x: u64) u64 {
    return mix(x) ^ mix(x + 1);
}

@noinline
fn plain_mix(x: u64) u64 {
    return mix_plain(x) ^ mix_plain(x + 1);
}

fn main(args: Vector<str>) i32 {
    let n = args.len() as u64;
    return ((forced_mix(n) ^ plain_mix(n)) & 1) as i32;
}
)";

@test
fn an_always_inline_callee_inlines_whatever_its_size() {
    let p = cli::proj_new();
    p.mkfile("main.spc", ALWAYS_INLINE);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "_mix", "build -O3 main.spc -o app");
    let forced = printed(r.text(), "forced_mix");
    let plain = printed(r.text(), "plain_mix");
    let ok = r.ok() && forced.len() != 0 && !forced.contains("call") && plain.contains("@mix_plain(");
    if !ok {
        r.show();
    }
    assert(ok, "the forced callee inlines, the other stays a call");
}

// A release build's vectorized loop interleaves the target's count of vector copies: its first vector
// loop's block loads 2 vectors per pass on wasm32 (each copy is module size) and arm64 Linux, 4 on x86-64
// Linux. The link may fail without the target's sysroot; the optimizer prints before it.
@test
fn vector_loops_interleave_the_targets_copies() {
    let cases: [(str, u32); 3] = [
        ("--target=wasm", 2),
        ("--target=linux --arch=aarch64", 2),
        ("--target=linux --arch=x86_64", 4),
    ];
    for k in 0..3usize {
        let (flags, want) = unsafe cases[k];
        let p = cli::proj_new();
        p.mkfile(
            "main.spc",
            "@noinline\nfn vsum(s: []u32) u32 {\n    let mut t: u32 = 0;\n    for i in 0..s.len() {\n        t += s[i];\n    }\n    return t;\n}\n\nfn main(args: Vector<str>) i32 {\n    let v: [u32; 3] = [1, 2, args.len() as u32];\n    return vsum(v[0..3]) as i32 - 4;\n}\n",
        );
        let r = cli::superc_env_in(
            p.dir(),
            "SC_LIR_PRINT",
            "vsum",
            format("build --profile=release {} main.spc -o app", flags).as_str(),
        );
        // The root module's names take its prefix when the build has another program module.
        let f0 = printed(r.text(), "vsum");
        let f = if f0.len() != 0 {
            f0
        } else {
            printed(r.text(), "main__vsum")
        };
        let at = f.find("load.v4i32");
        if at < 0 {
            r.show();
        }
        assert(at >= 0, flags);
        let rest = f.slice(at as usize, f.len());
        let block = rest.slice(0, rest.find("br ") as usize);
        let mut n: u32 = 0;
        for l in block.lines() {
            n += l.contains("load.v4i32") as u32;
        }
        assert_eq(n, want);
    }
}

// A wasm32 release build splits a 128-bit product into 64-bit words (`Package.pairs`: its high word one
// `mulhu.i64`, which wasmgen computes from 32-bit halves), lowers a switch of ranges to compares (the
// walk gives its cases arguments, which `br_table` cannot pass) and keeps a signed quotient by 4 (no
// one-instruction high product: the engine divides by a constant). The link may fail without the target's
// sysroot; the optimizer prints before it.
@test
fn wasm_splits_wide_products_lowers_ranges_and_keeps_quotients() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "@noinline\nfn wz_mh(a: u64, b: u64) u64 {\n    return ((a as u128 * b as u128) >> 64) as u64;\n}\n\n@noinline\nfn wz_cls(c: u8) u8 {\n    return switch c {\n        97..=122 => 1,\n        65..=90 => 1,\n        48..=57 => 2,\n        32 | 9 | 10 => 3,\n        _ => 0,\n    };\n}\n\n@noinline\nfn wz_q4(x: i32) i32 {\n    return x / 4;\n}\n\nfn main(args: Vector<str>) i32 {\n    let n = args.len() as u64;\n    return (wz_mh(n, n) + wz_cls(n as u8) as u64) as i32 + wz_q4(n as i32);\n}\n",
    );
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "wz_", "build --profile=release --target=wasm main.spc -o app");
    let names: [str; 3] = ["wz_mh", "wz_cls", "wz_q4"];
    for k in 0..3usize {
        let f0 = printed(r.text(), unsafe names[k]);
        let f = if f0.len() != 0 {
            f0
        } else {
            printed(r.text(), format("main__{}", unsafe names[k]).as_str())
        };
        let ok = if k == 0 {
            f.contains("mulhu.i64") && !f.contains("i128")
        } else if k == 1 {
            !f.contains("switch") && f.contains("icmp.ule")
        } else {
            f.contains("sdiv.i32")
        };
        if !ok {
            r.show();
        }
        assert(ok, unsafe names[k]);
    }
}

// Loops of C float functions: `max` and `min` reductions, `mul_add`, `floor` and `abs` per element. Built in
// release, the reductions keep a lane per extreme (`vop.max`, `vop.min`) and take the lanes into one by
// halves (lane swaps, `vop.swizzle`), `mul_add` is a fused multiply-add
// per lane (`vop.fma`), `floor` and `abs` lanes too; their results match the debug build's calls bit for
// bit, through NaNs and zeros of both signs at every position and length.
const FLOAT_CALLS: str = M"(@noinline
fn fl_top(s: []f32, m0: f32) f32 {
    let mut m = m0;
    for i in 0..s.len() {
        m = m.max(s[i]);
    }
    return m;
}

@noinline
fn fl_low(s: []f64) f64 {
    let mut m: f64 = 1.0e300;
    for i in 0..s.len() {
        m = s[i].min(m);
    }
    return m;
}

@noinline
fn fl_fused(s: []mut f64, a: f64, b: f64) {
    for i in 0..s.len() {
        s[i] = s[i].mul_add(a, b);
    }
}

@noinline
fn fl_round(s: []mut f32) {
    for i in 0..s.len() {
        s[i] = (s[i] * 0.3).floor().abs();
    }
}

fn main() i32 {
    let odd: [f32; 4] = [f32::NAN, -0.0, 0.0, -3.5];
    let mut h: u64 = 0;
    for n in 0..41usize {
        for k in 0..4usize {
            let mut a = Vector::<f32>::new();
            let mut d = Vector::<f64>::new();
            for i in 0..n {
                let v = if (i * 7 + k) % 5 == 0 {
                    odd[(i + k) % 4]
                } else {
                    ((i * 13 + k * 5) % 17) as f32 - 8.0
                };
                a.push(v);
                d.push(v as f64 * 0.75);
            }
            h = h.wrapping_mul(31) ^ fl_top(&a, odd[k]).to_bits() as u64;
            h = h.wrapping_mul(31) ^ fl_low(&d).to_bits();
            fl_fused(&mut d, 1.0 / 3.0, -0.0);
            fl_round(&mut a);
            for i in 0..n {
                h = h.wrapping_mul(31) ^ d[i].to_bits();
                h = h.wrapping_mul(31) ^ a[i].to_bits() as u64;
            }
        }
    }
    println("{}", h);
    return 0;
}
)";

@test
fn float_function_loops_vectorize_with_the_calls_results() {
    let base = h::diff_build(FLOAT_CALLS, ["--profile=debug"]);
    assert(base.built, base.diag.as_str());
    agrees("float function loops", &base, ["--profile=release"]);
    if cli::on_wasm() {
        return;
    }
    // x86-64 runs its packed forms at each level: SSE2's (the roundings stay calls), SSE4.1's ROUNDPS, AVX2's
    // and FMA3's. Not on the vector lane, which builds every program for wasm32.
    let x86 = tgt::isa(tgt::host_isa()).name == "x86_64" && !h::simd_lane();
    if x86 && detect::has_level(cpu::Level::V2) {
        agrees("float function loops, x86-64-v2", &base, ["--profile=release", "--target-cpu=x86-64-v2"]);
    }
    if x86 && detect::has_level(cpu::Level::V3) {
        agrees("float function loops, x86-64-v3", &base, ["--profile=release", "--target-cpu=x86-64-v3"]);
    }
    // The lanes of arm64 and of each x86-64 level (a cross build prints its bodies before its link).
    let a = float_calls_printed("--target=macos --arch=aarch64");
    // Each vector exit takes its lanes into one by lane swaps, then calls once.
    let top = String::from_str(printed(&a, "fl_top"));
    let ok = top.contains("lanes [2, 3, 0, 1]") && top.contains("lanes [1, 0, 3, 2]") && count_of(&top, "@fmaxf(") <= 3 && printed(
        &a,
        "fl_top",
    ).contains("vop.max.num") && printed(&a, "fl_low").contains("vop.min.num") && printed(&a, "fl_fused").contains(
        "vop.fma",
    ) && !printed(&a, "fl_fused").contains("call") && printed(&a, "fl_round").contains("vop.floor") && printed(
        &a,
        "fl_round",
    ).contains("vop.abs");
    let x1 = float_calls_printed("--target=linux --arch=x86_64 --target-cpu=x86-64");
    let x2 = float_calls_printed("--target=linux --arch=x86_64 --target-cpu=x86-64-v2");
    let x3 = float_calls_printed("--target=linux --arch=x86_64 --target-cpu=x86-64-v3");
    let ox = printed(&x1, "fl_top").contains("vop.max.num") && printed(&x1, "fl_low").contains("vop.min.num") && !printed(
        &x1,
        "fl_round",
    ).contains("vop.floor") && printed(&x2, "fl_round").contains("vop.floor") && printed(&x2, "fl_round").contains(
        "vop.abs",
    ) && !printed(&x2, "fl_fused").contains("vop.fma") && printed(&x3, "fl_fused").contains("vop.fma");
    if !ok || !ox {
        eprintln("{}\n{}\n{}\n{}", a.as_str(), x1.as_str(), x2.as_str(), x3.as_str());
    }
    assert(ok, "arm64: the reductions keep lanes; the fused multiply-adds, floors and absolute values are lanes");
    assert(ox, "x86-64: the same, the floors with SSE4.1 and the fused multiply-adds with FMA3 alone");
}

// Assert that FLOAT_CALLS built with `opts` gives the output of its build `base`.
fn agrees(label: str, base: &h::DiffBuild, opts: []str) {
    let b = h::diff_build(FLOAT_CALLS, opts);
    let d = if b.built {
        h::same_runs(base, &b, [""])
    } else {
        format("the program does not build:\n{}", b.diag.as_str())
    };
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
}

// What the release build of FLOAT_CALLS in a fresh project prints of its bodies `fl_*` (`SC_LIR_PRINT`),
// with target flags `flags`.
fn float_calls_printed(flags: str) String {
    let p = cli::proj_new();
    p.mkfile("main.spc", FLOAT_CALLS);
    let args = format("build -O2 {} main.spc -o app", flags);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "fl_", &args);
    return String::from_str(r.text());
}

// An `Option` built on each side of a join and taken apart after it (`o.map(f).unwrap_or(0)`): each jump into
// the join returns what the join would along it, its tag and payload folded (`Opt::ret_folded`), and the
// two returns are one select (`ret_diamond`).
@test
fn an_option_built_and_taken_apart_across_a_join_folds() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i64) -> i32
b0(v0: i64):
  v1 = iconst.i32 0
  v2 = iconst.i64 32
  v3 = trunc.i8 v0
  v4 = zext.i32 v3
  v5 = icmp.eq v4, v1
  br v5, b2, b1
b1:
  v6 = iconst.i64 1
  jmp b3(v6)
b2:
  v7 = lshr.i64 v0, v2
  v8 = trunc.i32 v7
  v9 = iconst.i32 1
  v10 = add.i32 v8, v9
  v11 = zext.i64 v10
  v12 = shl.i64 v11, v2
  jmp b3(v12)
b3(v13: i64):
  v14 = trunc.i8 v13
  v15 = zext.i32 v14
  v16 = lshr.i64 v13, v2
  v17 = trunc.i32 v16
  v18 = icmp.eq v15, v1
  v19 = select.i32 v18, v17, v1
  ret v19
)",
    );
    let t = text_of(&a, "f");
    assert(t.contains("select.i32") && !t.contains("b1") && !t.contains("shl"), t.as_str());
    let some: []u64 = [41u64 << 32];
    same_result(&b, &a, "f", some, 42);
    let none: []u64 = [41u64 << 32 | 1];
    same_result(&b, &a, "f", none, 0);
}

// The evaluator's binary16 conversions (`htof`, `ftoh`) agree with `std::float`'s limb code: every
// encoding widened, and each finite one's value, its midpoints to its neighbours and the floats next to
// those rounded, a NaN as a NaN.
@test
fn the_evaluator_converts_binary16_as_std_does() {
    for h in 0u32..65536 {
        let x = f16::from_raw(UInt::<16>::from_u64(h));
        let w = leval::half_to_f32_bits(h);
        if x.is_nan() {
            assert((w & 0x7FFFFFFF) > 0x7F800000, "a NaN widens to a NaN");
            continue;
        }
        assert_eq(w, f32_bits(x.to_f32()));
        if (h & 0x7C00) == 0x7C00 {
            continue;
        }
        let lo = x.to_f32();
        let hi = if (h & 0x7FFF) == 0x7BFF {
            65536.0f32
        } else {
            f16::from_raw(UInt::<16>::from_u64(h as u64 + 1)).to_f32()
        };
        let mid = (lo + hi) / 2.0;
        let probes: []f32 = [
            lo,
            mid,
            f32_from_bits(f32_bits(mid) - 1),
            f32_from_bits(f32_bits(mid) + 1),
            (lo + mid) / 2.0,
        ];
        for k in 0..probes.len() {
            let v = probes[k];
            assert_eq(leval::f32_bits_to_half(f32_bits(v)) as u64, f16::from_f32(v).to_raw().to_u64());
        }
    }
}

// A 128-bit integer splits into its two 64-bit words (`Package.pairs`): sums and differences carry
// between the words, products take the high half of the low words' product, shifts move bits within and
// across the words (amounts 0, 1, 63, 64, 65, 100 and 127), orders of both signs compare the high words
// first, and selects, a store, a load and a block parameter take the words; a call's argument and result
// stay whole. Each result is the one of the body before.
@test
fn an_i128_splits_into_its_words() {
    let (b, a) = optimized_split(
        M"(lir ptr 8
sym @wide fn global noinline
sym @mix fn global
fn @wide
  sig (i128) -> i128
b0(v0: i128):
  v1 = wconst.i128 0x9e3779b97f4a7c15, 0x123456789abcdef
  v2 = mul.i128 v0, v1
  ret v2
fn @mix
  sig (i64, i64, i64) -> i64
  slot s0 size 16 align 4
b0(v0: i64, v1: i64, v2: i64):
  v3 = sext.i128 v0
  v4 = zext.i128 v1
  v5 = add.i128 v3, v4
  v6 = sub.i128 v3, v4
  v7 = mul.i128 v5, v6
  v8 = iconst.i64 127
  v9 = and.i64 v2, v8
  v10 = zext.i128 v9
  v11 = shl.i128 v7, v10
  v12 = lshr.i128 v7, v10
  v13 = ashr.i128 v7, v10
  v14 = icmp.slt v11, v13
  v15 = icmp.ult v12, v5
  v16 = icmp.eq v6, v7
  v17 = select.i128 v14, v11, v12
  v18 = select.i128 v15, v17, v13
  v19 = neg.i128 v18
  v20 = not.i128 v19
  v21 = xor.i128 v20, v5
  v22 = slotaddr s0
  store v21, v22 align 4
  v23 = load.i128 v22 align 4
  v24 = call.i128 @wide(v23) : (i128) -> i128
  v25 = trunc.i64 v24
  v26 = wconst.i128 0x40, 0x0
  v27 = lshr.i128 v24, v26
  v28 = trunc.i64 v27
  v29 = xor.i64 v25, v28
  v30 = zext.i64 v16
  v31 = add.i64 v29, v30
  v32 = icmp.sge v21, v5
  v33 = zext.i64 v32
  v34 = add.i64 v31, v33
  jmp b1(v24, v34)
b1(v35: i128, v36: i64):
  v37 = trunc.i32 v35
  v38 = zext.i64 v37
  v39 = add.i64 v36, v38
  ret v39
)",
        0,
        false,
        il::SPEED,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
        true,
        false,
    );
    let t = text_of(&a, "mix");
    // Only the call's argument joins the words again (`hi << 64 | lo`).
    assert(
        t.as_str().find("mul.i128") < 0 && t.as_str().find("ashr.i128") < 0 && t.as_str().find("load.i128") < 0,
        t.as_str(),
    );
    assert(t.as_str().find("mulhu.i64") >= 0 && t.as_str().find("call.i128 @wide") >= 0, t.as_str());
    // (a, b, the shift amount) per run.
    let args: []u64 = [
        5,
        9,
        3,
        0xFFFFFFFFFFFFFFF9,
        0xFFFFFFFFFFFFFFFF,
        64,
        0x8000000000000000,
        1,
        127,
        123456789,
        987654321,
        0,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        65,
        0x7FFFFFFFFFFFFFFF,
        0x8000000000000000,
        100,
        0,
        0,
        63,
        0x0123456789ABCDEF,
        0xFEDCBA9876543210,
        1,
    ];
    for k in 0..args.len() / 3 {
        let x = args[3 * k..3 * k + 3];
        let mut e = leval::Eval::new(&b);
        let o = e.run(b.find_symbol("mix"), x);
        let mut e2 = leval::Eval::new(&a);
        let o2 = e2.run(a.find_symbol("mix"), x);
        assert_eq(o.kind, leval::EV_OK);
        assert_eq(o2.kind, leval::EV_OK);
        assert_eq(o2.value, o.value);
    }
}

// A truncated sum, difference, product or bitwise operation of extended values is that operation in the
// narrow type; a quotient is not, nor an operand extended from another type, nor a sum another
// instruction reads too (`sat`: the truncation is free, a narrow sum another instruction).
@test
fn a_truncated_operation_of_extensions_narrows() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
sym @sat fn global
fn @sat
  sig (i8, i8) -> i8
b0(v0: i8, v1: i8):
  v2 = iconst.i32 255
  v3 = iconst.i8 -1
  v4 = zext.i32 v0
  v5 = zext.i32 v1
  v6 = add.i32 v4, v5
  v7 = icmp.ugt v6, v2
  v8 = trunc.i8 v6
  v9 = select.i8 v7, v3, v8
  ret v9
fn @f
  sig (i32, i32, i16) -> i32
b0(v0: i32, v1: i32, v2: i16):
  v3 = zext.i64 v0
  v4 = sext.i64 v1
  v5 = mul.i64 v3, v4
  v6 = trunc.i32 v5
  v7 = udiv.i64 v3, v4
  v8 = trunc.i32 v7
  v9 = zext.i64 v2
  v10 = sub.i64 v3, v9
  v11 = trunc.i32 v10
  v12 = xor.i32 v6, v8
  v13 = add.i32 v12, v11
  ret v13
)",
    );
    let t = text_of(&a, "f");
    assert(t.as_str().find("mul.i32 v0, v1") >= 0 && t.as_str().find("mul.i64") < 0, t.as_str());
    assert(t.as_str().find("udiv.i64") >= 0 && t.as_str().find("sub.i64") >= 0, t.as_str());
    let args: []u64 = [0xFFFFFFF7, 0x80000003, 0xFFFE];
    let mut e = leval::Eval::new(&b);
    let o = e.run(b.find_symbol("f"), args);
    same_result(&b, &a, "f", args, o.value);
    let s = text_of(&a, "sat");
    assert(count_of(&s, "add.") == 1 && s.contains("trunc.i8"), s.as_str());
    let low: []u64 = [100, 55];
    same_result(&b, &a, "sat", low, 155);
    let high: []u64 = [200, 56];
    same_result(&b, &a, "sat", high, 255);
}

// Tail recursion elimination (`Package.tail`): a call of the body's own function whose result its block
// returns becomes a jump back to the body's start; not when a slot's address escapes to another call,
// since each call had a frame of its own.
@test
fn a_call_of_itself_returned_at_once_is_a_loop() {
    let text = M"(lir ptr 8
sym @kept_ptr data global
sym @keep fn global noinline
sym @sum fn global
sym @esc fn global
fn @keep
  sig (ptr) -> void
b0(v0: ptr):
  v1 = symaddr @kept_ptr
  store v0, v1 align 3
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
data @kept_ptr size 8 align 3
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
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 0,
                interleave: 0,
                fin: 0,
            },
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

// Accumulator recursion elimination: a call of the body's own function whose block returns an integer
// add, mul, and, or or xor of its result and another value becomes a jump back with an accumulator, the
// operation's identity first, and every other return combines the accumulator with its value. A result
// of another type than the last parameter (`ipow`), a bool toggled by xor (`even`), the identity of `and`
// (`band`) and a plain tail call beside an accumulating one (`mix`); calls of two operations (`two`) stay.
@test
fn a_call_of_itself_combined_with_a_value_is_a_loop_with_an_accumulator() {
    let text = M"(lir ptr 8
sym @fact fn global
sym @ipow fn global
sym @even fn global
sym @band fn global
sym @mix fn global
sym @two fn global
fn @fact
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  v3 = iconst.i64 1
  ret v3
b2:
  v4 = iconst.i64 1
  v5 = sub.i64 v0, v4
  v6 = call.i64 @fact(v5) : (i64) -> i64
  v7 = mul.i64 v0, v6
  ret v7
fn @ipow
  sig (i64, i32) -> i64
b0(v0: i64, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b1, b2
b1:
  v4 = iconst.i64 1
  ret v4
b2:
  v5 = iconst.i32 1
  v6 = sub.i32 v1, v5
  v7 = call.i64 @ipow(v0, v6) : (i64, i32) -> i64
  v8 = mul.i64 v7, v0
  ret v8
fn @even
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  v3 = iconst.i8 1
  ret v3
b2:
  v4 = iconst.i32 1
  v5 = sub.i32 v0, v4
  v6 = call.i8 @even(v5) : (i32) -> i8
  v7 = iconst.i8 1
  v8 = xor.i8 v6, v7
  ret v8
fn @band
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  v3 = iconst.i32 65535
  ret v3
b2:
  v4 = iconst.i32 61680
  v5 = or.i32 v0, v4
  v6 = iconst.i32 1
  v7 = sub.i32 v0, v6
  v8 = call.i32 @band(v7) : (i32) -> i32
  v9 = and.i32 v5, v8
  ret v9
fn @mix
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
  v6 = iconst.i64 3
  v7 = icmp.eq v1, v6
  br v7, b3, b4
b3:
  v8 = add.i64 v1, v4
  v9 = call.i64 @mix(v5, v8) : (i64, i64) -> i64
  ret v9
b4:
  v10 = iconst.i64 7
  v11 = mul.i64 v0, v10
  v12 = call.i64 @mix(v5, v1) : (i64, i64) -> i64
  v13 = add.i64 v11, v12
  ret v13
fn @two
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 2
  v2 = icmp.ult v0, v1
  br v2, b1, b2
b1:
  ret v0
b2:
  v3 = iconst.i64 1
  v4 = sub.i64 v0, v3
  v5 = and.i64 v0, v3
  v6 = icmp.eq v5, v3
  br v6, b3, b4
b3:
  v7 = call.i64 @two(v4) : (i64) -> i64
  v8 = add.i64 v7, v0
  ret v8
b4:
  v9 = call.i64 @two(v4) : (i64) -> i64
  v10 = mul.i64 v9, v1
  ret v10
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
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 0,
                interleave: 0,
                fin: 0,
            },
        },
    );
    let names: []str = ["fact", "ipow", "even", "band", "mix"];
    for k in 0..names.len() {
        let s = text_of(&after, names[k]);
        assert(!s.contains("call"), s.as_str());
    }
    let two = text_of(&after, "two");
    assert(two.contains("call.i64 @two"), two.as_str());
    let f: []u64 = [20];
    same_result(&before, &after, "fact", f, 2432902008176640000);
    let p: []u64 = [3, 40];
    same_result(&before, &after, "ipow", p, 12157665459056928801);
    let e: []u64 = [1001];
    same_result(&before, &after, "even", e, 0);
    let ev: []u64 = [1000];
    same_result(&before, &after, "even", ev, 1);
    let n: []u64 = [0];
    same_result(&before, &after, "band", n, 65535);
    let a: []u64 = [5];
    same_result(&before, &after, "band", a, 0xF0F0);
    let m: []u64 = [6, 1];
    same_result(&before, &after, "mix", m, 1 + 7 * (6 + 5 + 4 + 3 + 2 + 1));
    let m2: []u64 = [6, 3];
    same_result(&before, &after, "mix", m2, 4 + 7 * (5 + 4 + 3 + 2 + 1));
    let w: []u64 = [10];
    same_result(&before, &after, "two", w, 166);
}

// A choice between a flag and another flag on the first is their `and` or `or` (`&&`, `||` of flags), and
// two comparisons of one value with constants are one unsigned comparison of its distance to the lower
// bound: inside the range for an `and` (`lower`, a signed `sin`), outside for an `or` (`out`); an empty
// intersection is a constant (`none`).
@test
fn flag_choices_and_range_checks_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @lower fn global
sym @sin fn global
sym @out fn global
sym @none fn global
sym @both fn global
fn @lower
  sig (i8) -> i8
b0(v0: i8):
  v1 = iconst.i8 97
  v2 = iconst.i8 122
  v3 = icmp.uge v0, v1
  v4 = icmp.ule v0, v2
  v5 = select.i8 v3, v4, v3
  ret v5
fn @sin
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 -5
  v2 = iconst.i32 7
  v3 = icmp.sgt v0, v1
  v4 = icmp.slt v0, v2
  v5 = and.i8 v3, v4
  ret v5
fn @out
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 10
  v2 = iconst.i32 20
  v3 = icmp.ult v0, v1
  v4 = icmp.ugt v0, v2
  v5 = or.i8 v3, v4
  ret v5
fn @none
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 10
  v2 = iconst.i32 5
  v3 = icmp.ugt v0, v1
  v4 = icmp.ult v0, v2
  v5 = and.i8 v3, v4
  ret v5
fn @both
  sig (i32, i32) -> i8
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v0, v2
  v4 = icmp.eq v1, v2
  v5 = select.i8 v3, v3, v4
  ret v5
)",
    );
    let l = text_of(&a, "lower");
    assert(l.contains("sub.i8") && l.contains("icmp.ule") && !l.contains("select"), l.as_str());
    let s = text_of(&a, "sin");
    assert(s.contains("sub.i32") && s.contains("icmp.ule") && !s.contains("and."), s.as_str());
    let o = text_of(&a, "out");
    assert(o.contains("icmp.ugt") && !o.contains("or."), o.as_str());
    let n = text_of(&a, "none");
    assert(!n.contains("icmp"), n.as_str());
    let x = text_of(&a, "both");
    assert(x.contains("or.i8") && !x.contains("select"), x.as_str());
    let cs: []u64 = [0, 96, 97, 100, 122, 123, 255];
    let lw: []u64 = [0, 0, 1, 1, 1, 0, 0];
    for k in 0..cs.len() {
        let v: []u64 = [cs[k]];
        same_result(&b, &a, "lower", v, lw[k]);
    }
    let xs: []u64 = [0xFFFFFFFB, 0xFFFFFFFC, 0, 6, 7, 9, 10, 15, 20, 21, 0x80000000];
    let si: []u64 = [0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
    let ou: []u64 = [1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1];
    for k in 0..xs.len() {
        let v: []u64 = [xs[k]];
        same_result(&b, &a, "sin", v, si[k]);
        same_result(&b, &a, "out", v, ou[k]);
        same_result(&b, &a, "none", v, 0);
    }
    let p: []u64 = [3, 0];
    same_result(&b, &a, "both", p, 1);
    let q: []u64 = [3, 4];
    same_result(&b, &a, "both", q, 0);
}

// A remainder by the divisor of a dominating quotient is a product and a difference (`dm`); a signed
// remainder by 2^s compared with a constant is a mask of the low bits and the sign (`odd`, `neg`), or a
// constant when no remainder equals it (`never`); a bit count of a zero extension counts at the narrow
// type, and the truncations of its sums back to that type drop their extensions (`clz`, `ctz`).
@test
fn quotient_remainders_and_narrow_counts_simplify() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @dm fn global
sym @odd fn global
sym @neg fn global
sym @never fn global
sym @clz fn global
sym @ctz fn global
fn @dm
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b1, b2
b1: cold
  ret v2
b2:
  v4 = udiv.i32 v0, v1
  v5 = urem.i32 v0, v1
  v6 = add.i32 v4, v5
  ret v6
fn @odd
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 2
  v2 = srem.i32 v0, v1
  v3 = iconst.i32 1
  v4 = icmp.eq v2, v3
  ret v4
fn @neg
  sig (i64) -> i8
b0(v0: i64):
  v1 = iconst.i64 8
  v2 = srem.i64 v0, v1
  v3 = iconst.i64 -5
  v4 = icmp.ne v2, v3
  ret v4
fn @never
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 4
  v2 = srem.i32 v0, v1
  v3 = iconst.i32 4
  v4 = icmp.eq v2, v3
  ret v4
fn @clz
  sig (i32) -> i32
b0(v0: i32):
  v1 = zext.i64 v0
  v2 = clz.i64 v1
  v3 = trunc.i32 v2
  v4 = zext.i64 v3
  v5 = iconst.i64 32
  v6 = sub.i64 v4, v5
  v7 = trunc.i32 v6
  ret v7
fn @ctz
  sig (i16) -> i32
b0(v0: i16):
  v1 = zext.i64 v0
  v2 = iconst.i64 65536
  v3 = or.i64 v1, v2
  v4 = ctz.i64 v3
  v5 = trunc.i32 v4
  ret v5
)",
    );
    let d = text_of(&a, "dm");
    assert(d.contains("udiv") && !d.contains("urem"), d.as_str());
    let names: []str = ["odd", "neg"];
    for k in 0..names.len() {
        let s = text_of(&a, names[k]);
        assert(!s.contains("srem") && !s.contains("ashr") && !s.contains("lshr"), s.as_str());
    }
    let n = text_of(&a, "never");
    assert(!n.contains("srem") && !n.contains("icmp"), n.as_str());
    let c = text_of(&a, "clz");
    assert(c.contains("clz.i32") && !c.contains("i64"), c.as_str());
    let z = text_of(&a, "ctz");
    assert(z.contains("ctz.i16") && !z.contains("i64"), z.as_str());
    let x: []u64 = [100, 7];
    same_result(&b, &a, "dm", x, 16);
    let o: []u64 = [0xFFFFFFFF];
    same_result(&b, &a, "odd", o, 0);
    let p: []u64 = [7];
    same_result(&b, &a, "odd", p, 1);
    let q: []u64 = [0xFFFFFFFFFFFFFFFB];
    same_result(&b, &a, "neg", q, 0);
    let r: []u64 = [3];
    same_result(&b, &a, "neg", r, 1);
    let s: []u64 = [0x8000];
    same_result(&b, &a, "clz", s, 16);
    let u: []u64 = [0];
    same_result(&b, &a, "clz", u, 32);
    same_result(&b, &a, "ctz", u, 16);
    let v: []u64 = [0x40];
    same_result(&b, &a, "ctz", v, 6);
}

// A jump to a block that only returns returns itself: the value the edge passes (`arms`, whose calls then
// end their blocks), a value from before the block (`outer`), nothing (`none`).
@test
fn jumps_to_returns_return() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @arms fn global
sym @outer fn global
sym @none fn global
sym @g fn global noinline
fn @g
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 3
  v2 = mul.i32 v0, v1
  ret v2
fn @arms
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  switch v0 [0 -> b1, 1 -> b2] else b3(v1)
b1:
  v2 = call.i32 @g(v1) : (i32) -> i32
  jmp b3(v2)
b2:
  v3 = iconst.i32 5
  v4 = add.i32 v1, v3
  v5 = call.i32 @g(v4) : (i32) -> i32
  jmp b3(v5)
b3(v6: i32):
  ret v6
fn @outer
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v0, v2
  v4 = mul.i32 v1, v1
  br v3, b1, b2
b1:
  v5 = call.i32 @g(v0) : (i32) -> i32
  v6 = icmp.eq v5, v2
  br v6, b2, b3
b2:
  ret v4
b3:
  ret v5
fn @none
  sig (i32) -> void
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  v3 = call.i32 @g(v0) : (i32) -> i32
  jmp b2
b2:
  ret
)",
    );
    let s = text_of(&a, "arms");
    assert(!s.contains("jmp"), s.as_str());
    let x: []u64 = [0, 4];
    same_result(&b, &a, "arms", x, 12);
    let y: []u64 = [1, 4];
    same_result(&b, &a, "arms", y, 27);
    let z: []u64 = [7, 4];
    same_result(&b, &a, "arms", z, 4);
    let o: []u64 = [0, 6];
    same_result(&b, &a, "outer", o, 36);
    let q: []u64 = [2, 6];
    same_result(&b, &a, "outer", q, 36);
    let n = text_of(&a, "none");
    assert(!n.contains("jmp"), n.as_str());
}

// A branch whose two sides each return a value computed by a few speculable instructions returns the
// select of the two (`max`, `abs`, and a nested `clamp`); a side with a call stays a branch (`call`).
// A float division by a power of 2 whose reciprocal is normal is a product by that reciprocal (`x / 2.0`
// is `x * 0.5`, `x / 4.0f` is `x * 0.25f`, `x / 2^-1022` is `x * 2^1022`); by 3, whose reciprocal is
// inexact, or by 2^1023, whose reciprocal is subnormal, it stays a division.
@test
fn float_divisions_by_powers_of_two_are_products() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @half fn global
sym @quarter fn global
sym @tiny fn global
sym @third fn global
sym @huge fn global
fn @half
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x4000000000000000
  v2 = fdiv.f64 v0, v1
  ret v2
fn @quarter
  sig (f32) -> f32
b0(v0: f32):
  v1 = fconst.f32 0x40800000
  v2 = fdiv.f32 v0, v1
  ret v2
fn @tiny
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x0010000000000000
  v2 = fdiv.f64 v0, v1
  ret v2
fn @third
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x4008000000000000
  v2 = fdiv.f64 v0, v1
  ret v2
fn @huge
  sig (f64) -> f64
b0(v0: f64):
  v1 = fconst.f64 0x7fe0000000000000
  v2 = fdiv.f64 v0, v1
  ret v2
)",
    );
    let h = text_of(&a, "half");
    assert(h.contains("fmul.f64") && h.contains("0x3fe0000000000000") && !h.contains("fdiv"), h.as_str());
    let q = text_of(&a, "quarter");
    assert(q.contains("fmul.f32") && q.contains("0x3e800000"), q.as_str());
    let y = text_of(&a, "tiny");
    assert(y.contains("fmul.f64") && y.contains("0x7fd0000000000000"), y.as_str());
    let d = text_of(&a, "third");
    assert(d.contains("fdiv.f64"), d.as_str());
    let g = text_of(&a, "huge");
    assert(g.contains("fdiv.f64"), g.as_str());
    let _ = b;
}

// `a && b && c` of comparisons: the inner `&&` becomes an `and`, then the outer branch's sides both
// return (the false side the first comparison, which is false there), so it returns an `and` too.
@test
fn a_chain_of_ands_returns_one_value() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i32, i32, i32) -> i8
b0(v0: i32, v1: i32, v2: i32):
  v3 = iconst.i32 3
  v4 = iconst.i32 9
  v5 = iconst.i32 0
  v6 = icmp.eq v0, v3
  br v6, b1, b2(v6)
b1:
  v7 = icmp.ult v1, v4
  jmp b2(v7)
b2(v8: i8):
  br v8, b3, b4(v8)
b3:
  v9 = icmp.ne v2, v5
  jmp b4(v9)
b4(v10: i8):
  ret v10
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("br ") && count_of(&t, "and.i8") == 2, t.as_str());
    let x: []u64 = [3, 4, 1];
    same_result(&b, &a, "f", x, 1);
    let y: []u64 = [3, 9, 1];
    same_result(&b, &a, "f", y, 0);
    let z: []u64 = [2, 4, 1];
    same_result(&b, &a, "f", z, 0);
}

@test
fn return_diamonds_are_selects() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @max fn global
sym @abs fn global
sym @clamp fn global
sym @call fn global
sym @g fn global noinline
fn @g
  sig (i32) -> i32
b0(v0: i32):
  ret v0
fn @max
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = icmp.sgt v0, v1
  br v2, b2, b1
b1:
  ret v1
b2:
  ret v0
fn @abs
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.slt v0, v1
  br v2, b2, b1
b1:
  ret v0
b2:
  v3 = sub.i32 v1, v0
  ret v3
fn @clamp
  sig (i32, i32, i32) -> i32
b0(v0: i32, v1: i32, v2: i32):
  v3 = icmp.slt v0, v1
  br v3, b4, b1
b1:
  v4 = icmp.sgt v0, v2
  br v4, b3, b2
b2:
  ret v0
b3:
  ret v2
b4:
  ret v1
fn @call
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.slt v0, v1
  br v2, b2, b1
b1:
  ret v0
b2:
  v3 = call.i32 @g(v0) : (i32) -> i32
  ret v3
)",
    );
    let names: []str = ["max", "abs", "clamp"];
    for k in 0..names.len() {
        let s = text_of(&a, names[k]);
        assert(!s.contains("br ") && s.contains("select"), s.as_str());
    }
    let c = text_of(&a, "call");
    assert(c.contains("br "), c.as_str());
    let x: []u64 = [5, 0xFFFFFFFD];
    same_result(&b, &a, "max", x, 5);
    let y: []u64 = [0xFFFFFFF9];
    same_result(&b, &a, "abs", y, 7);
    let z: []u64 = [50, 10, 20];
    same_result(&b, &a, "clamp", z, 20);
    let w: []u64 = [0xFFFFFFFF, 10, 20];
    same_result(&b, &a, "clamp", w, 10);
    let v: []u64 = [15, 10, 20];
    same_result(&b, &a, "clamp", v, 15);
}

// An `or` of whole bytes of one value through shifts and byte masks is the value when each byte keeps its
// place (`keep`) and its byte reversal when each takes the mirrored one (`swap`); bytes loaded one by one
// into a big-endian word are one load reversed (`be`). A permutation of another order stays (`rot`).
@test
fn byte_permutations_are_byte_swaps() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @swap fn global
sym @keep fn global
sym @be fn global
sym @rot fn global
fn @swap
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 24
  v2 = iconst.i32 8
  v3 = iconst.i32 65280
  v4 = iconst.i32 16711680
  v5 = lshr.i32 v0, v1
  v6 = lshr.i32 v0, v2
  v7 = and.i32 v6, v3
  v8 = or.i32 v5, v7
  v9 = shl.i32 v0, v2
  v10 = and.i32 v9, v4
  v11 = or.i32 v8, v10
  v12 = shl.i32 v0, v1
  v13 = or.i32 v11, v12
  ret v13
fn @keep
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -71777214294589696
  v2 = iconst.i64 71777214294589695
  v3 = and.i64 v0, v1
  v4 = and.i64 v2, v0
  v5 = or.i64 v3, v4
  ret v5
fn @be
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i8 v0 align 0
  v2 = load.i8 v0+1 align 0
  v3 = load.i8 v0+2 align 0
  v4 = load.i8 v0+3 align 0
  v5 = zext.i32 v1
  v6 = zext.i32 v2
  v7 = zext.i32 v3
  v8 = zext.i32 v4
  v9 = iconst.i32 24
  v10 = iconst.i32 16
  v11 = iconst.i32 8
  v12 = shl.i32 v5, v9
  v13 = shl.i32 v6, v10
  v14 = shl.i32 v7, v11
  v15 = or.i32 v12, v13
  v16 = or.i32 v15, v14
  v17 = or.i32 v16, v8
  ret v17
fn @rot
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 8
  v2 = iconst.i32 24
  v3 = shl.i32 v0, v1
  v4 = lshr.i32 v0, v2
  v5 = or.i32 v3, v4
  ret v5
)",
    );
    let s = text_of(&a, "swap");
    assert(s.contains("bswap.i32 v0") && !s.contains("or."), s.as_str());
    let k = text_of(&a, "keep");
    assert(!k.contains("or.") && k.contains("ret v0"), k.as_str());
    let e = text_of(&a, "be");
    assert(e.contains("load.i32") && e.contains("bswap.i32") && !e.contains("load.i8"), e.as_str());
    let r = text_of(&a, "rot");
    assert(r.contains("or.") && !r.contains("bswap"), r.as_str());
    let x: []u64 = [0x12345678];
    same_result(&b, &a, "swap", x, 0x78563412);
    same_result(&b, &a, "rot", x, 0x34567812);
    let y: []u64 = [0x0123456789ABCDEF];
    same_result(&b, &a, "keep", y, 0x0123456789ABCDEF);
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

// A C library allocation writes no memory the program reads but `errno`: a load of a place stored before
// it reads the stored value, and the fresh block's stores touch no other place. A place moves to a new
// memory state only along its own type's tag (and the untagged accesses'): a pointer field read before
// two allocations, stored between them, then a store of another pointer field, reads the new pointer. A
// `_aligned_free` the package defines is any other call.
@test
fn an_allocation_writes_no_place_the_program_reads() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @malloc fn global
sym @abort fn global
sym @_aligned_free fn global noinline
sym @past fn global noinline
sym @pdrive fn global
sym @swap fn global noinline
sym @drive fn global
sym @wipe fn global
fn @_aligned_free
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i64 0
  store v1, v0 align 3 tbaa 4
  ret
fn @past
  sig (ptr, i64) -> i64
  ref p0 8 noalias
b0(v0: ptr, v1: i64):
  store v1, v0 align 3 tbaa 4
  v2 = iconst.i64 16
  v3 = call.ptr @malloc(v2) : (i64) -> ptr
  v4 = iconst.i64 9
  store v4, v3 align 3 tbaa 4
  v5 = load.i64 v0 align 3 tbaa 4
  v6 = load.i64 v3 align 3 tbaa 4
  v7 = add.i64 v5, v6
  ret v7
fn @pdrive
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = call.i64 @past(v1, v0) : (ptr, i64) -> i64
  ret v2
fn @swap
  sig (ptr) -> i64
  ref p0 32 noalias
b0(v0: ptr):
  v1 = iconst.i64 16
  v2 = load.ptr v0 align 3 tbaa 8
  v3 = load.ptr v0+8 align 3 tbaa 8
  v4 = load.ptr v0+16 align 3 tbaa 8
  v5 = load.i32 v0+28 align 2 tbaa 3
  v6 = call.ptr @malloc(v1) : (i64) -> ptr
  v7 = iconst.ptr 0
  v8 = icmp.eq v6, v7
  br v8, b1, b2
b1:
  call @abort() : () -> void
  unreachable
b2:
  store v6, v0 align 3 tbaa 8
  v9 = call.ptr @malloc(v1) : (i64) -> ptr
  v10 = icmp.eq v9, v7
  br v10, b3, b4
b3:
  call @abort() : () -> void
  unreachable
b4:
  store v9, v0+8 align 3 tbaa 8
  v11 = call.ptr @malloc(v1) : (i64) -> ptr
  v12 = icmp.eq v11, v7
  br v12, b5, b6
b5:
  call @abort() : () -> void
  unreachable
b6:
  store v11, v0+16 align 3 tbaa 8
  v13 = iconst.i8 0
  memset v11, v13, v1
  v14 = iconst.i32 16
  store v14, v0+28 align 2 tbaa 3
  v15 = iconst.i32 0
  store v15, v0+24 align 2 tbaa 3
  v16 = load.ptr v0 align 3 tbaa 8
  v17 = load.ptr v0+16 align 3 tbaa 8
  v18 = icmp.eq v16, v6
  v19 = icmp.eq v17, v11
  v20 = and.i8 v18, v19
  v21 = icmp.ne v16, v2
  v22 = and.i8 v20, v21
  v23 = zext.i64 v22
  ret v23
fn @drive
  sig () -> i64
  slot s0 size 32 align 3
b0:
  v0 = slotaddr s0
  v1 = iconst.i64 0
  store v1, v0 align 3
  store v1, v0+8 align 3
  store v1, v0+16 align 3
  store v1, v0+24 align 3
  v2 = call.i64 @swap(v0) : (ptr) -> i64
  ret v2
fn @wipe
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3 tbaa 4
  call @_aligned_free(v1) : (ptr) -> void
  v2 = load.i64 v1 align 3 tbaa 4
  ret v2
)",
    );
    let p = text_of(&a, "past");
    assert(!p.contains("load"), p.as_str());
    let x: []u64 = [7];
    same_result(&b, &a, "pdrive", x, 16);
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 1);
    same_result(&b, &a, "wipe", x, 0);
}

// A place moves to a new memory state only along its own type's tag and the untagged accesses': a map's
// rehash (as the wasm compiler's walk receives it) reads its key array's pointer after storing the new one
// between allocations and loads of an `i32` (tag 3, as `errno`'s and the map's sizes are), and the new
// entries go to the new arrays.
@test
fn a_rehash_reads_the_arrays_it_stored() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sc_lk_malloc fn global
sym @sc_lk_aligned_alloc fn global
sym @sc_lk_free fn global
sym @sc_lk_aligned_free fn global
sym @abort fn global
sym @MALLOC_ALIGN data global
sym @rehash fn global noinline
sym @drive fn global
fn @rehash
  sig (ptr, i32) -> void
  ref p0 32 noalias
  slot s0 size 8 align 3
  slot s1 size 8 align 3
b0(v0: ptr, v1: i32):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i32 8
  v5 = symaddr @MALLOC_ALIGN
  v6 = iconst.i32 0
  v7 = iconst.i32 1
  v8 = iconst.i8 0
  v9 = iconst.i8 1
  v10 = iconst.i64 0
  v11 = iconst.i64 32
  v12 = load.ptr v0 align 3 tbaa 8
  store v12, v2 align 3 tbaa 8
  v13 = load.ptr v0+8 align 3 tbaa 8
  v14 = load.ptr v0+16 align 3 tbaa 8
  v15 = load.i32 v0+28 align 2 tbaa 3
  v16 = mul.i32 v1, v4
  v17 = load.i32 v5 align 2 tbaa 3
  v18 = icmp.ugt v4, v17
  br v18, b2, b1
b1:
  v19 = call.ptr @sc_lk_malloc(v16) : (i32) -> ptr
  jmp b3(v19)
b2:
  v20 = call.ptr @sc_lk_aligned_alloc(v16, v4) : (i32, i32) -> ptr
  jmp b3(v20)
b3(v21: ptr):
  v22 = sext.i64 v6
  v23 = inttoptr.ptr v22
  v24 = icmp.eq v21, v23
  br v24, b4, b5
b4:
  call @abort() : () -> void
  unreachable
b5:
  store v21, v0 align 3 tbaa 8
  v25 = mul.i32 v1, v4
  v26 = load.i32 v5 align 2 tbaa 3
  v27 = icmp.ugt v4, v26
  br v27, b7, b6
b6:
  v28 = call.ptr @sc_lk_malloc(v25) : (i32) -> ptr
  jmp b8(v28)
b7:
  v29 = call.ptr @sc_lk_aligned_alloc(v25, v4) : (i32, i32) -> ptr
  jmp b8(v29)
b8(v30: ptr):
  v31 = sext.i64 v6
  v32 = inttoptr.ptr v31
  v33 = icmp.eq v30, v32
  br v33, b9, b10
b9:
  call @abort() : () -> void
  unreachable
b10:
  store v30, v0+8 align 3 tbaa 8
  v34 = load.i32 v5 align 2 tbaa 3
  v35 = icmp.ugt v7, v34
  br v35, b12, b11
b11:
  v36 = call.ptr @sc_lk_malloc(v1) : (i32) -> ptr
  jmp b13(v36)
b12:
  v37 = call.ptr @sc_lk_aligned_alloc(v1, v7) : (i32, i32) -> ptr
  jmp b13(v37)
b13(v38: ptr):
  v39 = sext.i64 v6
  v40 = inttoptr.ptr v39
  v41 = icmp.eq v38, v40
  br v41, b14, b15
b14:
  call @abort() : () -> void
  unreachable
b15:
  store v38, v0+16 align 3 tbaa 8
  v42 = load.ptr v0+16 align 3 tbaa 8
  memset v42, v8, v1
  store v1, v0+28 align 2 tbaa 3
  store v6, v0+24 align 2 tbaa 3
  jmp b16(v6)
b16(v43: i32):
  v44 = icmp.ult v43, v15
  br v44, b28, b17
b17:
  v45 = icmp.ugt v15, v6
  br v45, b18, b27
b18:
  v46 = load.ptr v2 align 3 tbaa 8
  v47 = load.i32 v5 align 2 tbaa 3
  v48 = icmp.ugt v4, v47
  br v48, b20, b19
b19:
  call @sc_lk_free(v46) : (ptr) -> void
  jmp b21
b20:
  call @sc_lk_aligned_free(v46) : (ptr) -> void
  jmp b21
b21:
  v49 = load.i32 v5 align 2 tbaa 3
  v50 = icmp.ugt v4, v49
  br v50, b23, b22
b22:
  call @sc_lk_free(v13) : (ptr) -> void
  jmp b24
b23:
  call @sc_lk_aligned_free(v13) : (ptr) -> void
  jmp b24
b24:
  v51 = load.i32 v5 align 2 tbaa 3
  v52 = icmp.ugt v7, v51
  br v52, b26, b25
b25:
  call @sc_lk_free(v14) : (ptr) -> void
  jmp b27
b26:
  call @sc_lk_aligned_free(v14) : (ptr) -> void
  jmp b27
b27:
  ret
b28:
  v53 = sext.i64 v43
  v54 = ptradd v14, v53 * 1
  v55 = load.i8 v54 align 0
  v56 = icmp.eq v55, v9
  br v56, b29, b36
b29:
  v57 = load.ptr v2 align 3 tbaa 8
  v58 = sext.i64 v43
  v59 = ptradd v57, v58 * 8
  store v10, v3 align 3
  jmp b30(v59, v3)
b30(v60: ptr, v61: ptr):
  v62 = iconst.i64 32
  v63 = iconst.i64 -7046029254386353131
  v64 = load.i64 v60 align 3 tbaa 4
  v65 = load.i64 v61 align 3 tbaa 4
  v66 = xor.i64 v65, v64
  v67 = lshr.i64 v66, v62
  v68 = xor.i64 v66, v67
  v69 = mul.i64 v68, v63
  store v69, v61 align 3 tbaa 4
  jmp b31
b31:
  v70 = load.i64 v3 align 3 tbaa 4
  v71 = lshr.i64 v70, v11
  v72 = load.i64 v3 align 3 tbaa 4
  v73 = xor.i64 v72, v71
  v74 = trunc.i32 v73
  v75 = load.i32 v0+28 align 2 tbaa 3
  v76 = sub.i32 v75, v7
  v77 = and.i32 v74, v76
  jmp b32(v77)
b32(v78: i32):
  v79 = load.ptr v0+16 align 3 tbaa 8
  v80 = sext.i64 v78
  v81 = ptradd v79, v80 * 1
  v82 = load.i8 v81 align 0
  v83 = icmp.ne v82, v8
  br v83, b33, b35
b33:
  v84 = load.ptr v0 align 3 tbaa 8
  v85 = sext.i64 v78
  v86 = ptradd v84, v85 * 8
  v87 = load.i64 v86 align 3 tbaa 4
  v88 = load.i64 v59 align 3 tbaa 4
  v89 = icmp.eq v87, v88
  br v89, b35, b34
b34:
  v90 = add.i32 v78, v7
  v91 = load.i32 v0+28 align 2 tbaa 3
  v92 = icmp.uge v90, v91
  br v92, b32(v6), b32(v90)
b35:
  v93 = load.ptr v2 align 3 tbaa 8
  v94 = sext.i64 v43
  v95 = ptradd v93, v94 * 8
  v96 = load.i64 v95 align 3 tbaa 4
  v97 = load.ptr v0 align 3 tbaa 8
  v98 = sext.i64 v78
  v99 = ptradd v97, v98 * 8
  store v96, v99 align 3 tbaa 4
  v100 = sext.i64 v43
  v101 = ptradd v13, v100 * 8
  v102 = load.i64 v101 align 3 tbaa 4
  v103 = load.ptr v0+8 align 3 tbaa 8
  v104 = sext.i64 v78
  v105 = ptradd v103, v104 * 8
  store v102, v105 align 3 tbaa 4
  v106 = load.ptr v0+16 align 3 tbaa 8
  v107 = sext.i64 v78
  v108 = ptradd v106, v107 * 1
  store v9, v108 align 0
  v109 = load.i32 v0+24 align 2 tbaa 3
  v110 = add.i32 v109, v7
  store v110, v0+24 align 2 tbaa 3
  jmp b36
b36:
  v111 = add.i32 v43, v7
  jmp b16(v111)
fn @drive
  sig () -> i64
  slot s0 size 32 align 3
b0:
  v0 = slotaddr s0
  v1 = iconst.i64 16
  v2 = iconst.i64 2
  v3 = call.ptr @sc_lk_malloc(v1) : (i64) -> ptr
  v4 = call.ptr @sc_lk_malloc(v1) : (i64) -> ptr
  v5 = call.ptr @sc_lk_malloc(v2) : (i64) -> ptr
  v6 = iconst.i64 5
  v7 = iconst.i64 9
  v8 = iconst.i64 50
  v9 = iconst.i64 90
  v10 = iconst.i8 1
  store v6, v3 align 3
  store v7, v3+8 align 3
  store v8, v4 align 3
  store v9, v4+8 align 3
  store v10, v5 align 0
  store v10, v5+1 align 0
  store v3, v0 align 3
  store v4, v0+8 align 3
  store v5, v0+16 align 3
  v11 = iconst.i32 2
  store v11, v0+24 align 2
  store v11, v0+28 align 2
  v12 = iconst.i32 8
  call @rehash(v0, v12) : (ptr, i32) -> void
  v13 = load.ptr v0 align 3
  v14 = load.ptr v0+8 align 3
  v15 = load.ptr v0+16 align 3
  v16 = iconst.i64 0
  v17 = iconst.i64 1
  v18 = iconst.i64 8
  jmp b1(v16, v16)
b1(v19: i64, v20: i64):
  v21 = icmp.ult v19, v18
  br v21, b2, b5
b2:
  v22 = ptradd v15, v19 * 1
  v23 = load.i8 v22 align 0
  v24 = icmp.ne v23, v10
  br v24, b4(v20), b3
b3:
  v25 = ptradd v13, v19 * 8
  v26 = load.i64 v25 align 3
  v27 = ptradd v14, v19 * 8
  v28 = load.i64 v27 align 3
  v29 = mul.i64 v26, v28
  v30 = add.i64 v20, v29
  jmp b4(v30)
b4(v31: i64):
  v32 = add.i64 v19, v17
  jmp b1(v32, v31)
b5:
  call @sc_lk_free(v13) : (ptr) -> void
  call @sc_lk_free(v14) : (ptr) -> void
  call @sc_lk_free(v15) : (ptr) -> void
  ret v20
data @MALLOC_ALIGN size 4 align 2 ro bytes 10000000
)",
    );
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 1060);
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

// The address of a thread-local variable is one value until a call that writes memory: the thread may
// change there (a coroutine parks on one thread and resumes on another). Two reads with no such call
// between share it, and a loop without one takes it once, before the loop.
@test
fn a_thread_local_address_is_taken_again_after_a_call() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @park fn global noinline
sym @parks data global
sym @t tls global
sym @both fn global
sym @twice fn global
sym @sum fn global
sym @sump fn global
fn @park
  sig () -> void
b0:
  v0 = symaddr @parks
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
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
fn @twice
  sig () -> i64
b0:
  v0 = symaddr @t
  v1 = load.i64 v0 align 3
  v2 = symaddr @t
  v3 = load.i64 v2 align 3
  v4 = add.i64 v1, v3
  ret v4
fn @sum
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2)
b1(v4: i64):
  v5 = icmp.ult v4, v1
  br v5, b2, b3
b2:
  v6 = ptradd v0, v4 * 8
  v7 = load.i64 v6 align 3
  v8 = symaddr @t
  v9 = load.i64 v8 align 3
  v10 = add.i64 v9, v7
  store v10, v8 align 3
  v11 = add.i64 v4, v3
  jmp b1(v11)
b3:
  ret
fn @sump
  sig (i64) -> void
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1)
b1(v3: i64):
  v4 = icmp.ult v3, v0
  br v4, b2, b3
b2:
  v5 = symaddr @t
  v6 = load.i64 v5 align 3
  v7 = add.i64 v6, v2
  store v7, v5 align 3
  call @park() : () -> void
  v8 = add.i64 v3, v2
  jmp b1(v8)
b3:
  ret
data @parks size 8 align 3
data @t size 8 align 3
)",
    );
    let t = text_of(&a, "both");
    assert(count_of(&t, "symaddr @t") == 2, t.as_str());
    let w = text_of(&a, "twice");
    assert(count_of(&w, "symaddr @t") == 1, w.as_str());
    // Before the loop: in the entry block, ahead of its first jump or branch.
    let s = text_of(&a, "sum");
    let head = s.find("\nb1");
    assert(count_of(&s, "symaddr @t") == 1 && s.find("symaddr @t") < head, s.as_str());
    // A loop that calls a function that writes memory takes the address in each iteration.
    let p = text_of(&a, "sump");
    let phead = p.find("\nb1");
    assert(p.find("symaddr @t") > phead, p.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "twice", none, 0);
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
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 0,
                interleave: 0,
                fin: 0,
            },
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
sym @leaked data global
sym @leak fn global noinline
sym @count fn global
sym @copied fn global
sym @escaped fn global
sym @maybe fn global
fn @leak
  sig (ptr) -> void
b0(v0: ptr):
  v1 = symaddr @leaked
  store v0, v1 align 3
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
data @leaked size 8 align 3
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

// A counted loop whose body may leave it (a search, the vectorizer's `vexit` shape) does not partially
// unroll: the unroller copies a body that jumps back. Each result is the one of the body before.
@test
fn a_search_loop_stays_one_loop_when_partial_unrolling_runs() {
    let (b, a) = optimized_loops(
        M"(lir ptr 8
sym @find fn global
fn @find
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2)
b1(v4: i64):
  v5 = icmp.ult v4, v0
  br v5, b2, b4(v0)
b2:
  v6 = mul.i64 v4, v4
  v7 = add.i64 v4, v3
  v8 = icmp.eq v6, v1
  br v8, b3, b1(v7)
b3:
  ret v4
b4(v9: i64):
  ret v9
)",
        0,
        false,
        lu::Budgets {
            peel: 0,
            partial: 16,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
    );
    let cases: [[u64; 3]; 5] = [[100, 49, 7], [100, 50, 100], [10, 81, 9], [5, 81, 5], [0, 0, 0]];
    for k in 0..5 {
        let x: []u64 = [cases[k][0], cases[k][1]];
        same_result(&b, &a, "find", x, cases[k][2]);
    }
}

// Whether an integer is a power of two, `x != 0 && (x & (x - 1)) == 0` in either order, is one unsigned
// comparison `(x ^ (x - 1)) >u x - 1`, and its negation `x == 0 || (x & (x - 1)) != 0` the opposite one
// (`pow2_test`); where the target counts bits in one instruction (`Package.popcnt`), `popcnt(x) == 1` and
// `!= 1`. Each result is the one of the body before.
@test
fn power_of_two_tests_compare_once() {
    let src = M"(lir ptr 8
sym @is fn global
sym @isnt fn global
fn @is
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 -1
  v3 = icmp.ne v0, v1
  v4 = add.i32 v0, v2
  v5 = and.i32 v0, v4
  v6 = icmp.eq v5, v1
  v7 = and.i8 v6, v3
  ret v7
fn @isnt
  sig (i64) -> i8
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = icmp.eq v0, v1
  v4 = sub.i64 v0, v2
  v5 = and.i64 v4, v0
  v6 = icmp.ne v5, v1
  v7 = or.i8 v3, v6
  ret v7
)";
    let (b, a) = optimized(src);
    let s = text_of(&a, "is");
    assert(s.contains("xor.i32") && s.contains("icmp.ugt") && !s.contains(" and."), s.as_str());
    let n = text_of(&a, "isnt");
    assert(n.contains("xor.i64") && n.contains("icmp.ule") && !n.contains(" or."), n.as_str());
    let xs: [u64; 8] = [0, 1, 2, 3, 64, 96, 0x80000000, 0xFFFFFFFF];
    for k in 0..8 {
        let x: []u64 = [xs[k]];
        let p = xs[k] != 0 && (xs[k] & xs[k] - 1) == 0;
        same_result(&b, &a, "is", x, p as u64);
        same_result(&b, &a, "isnt", x, (!p) as u64);
    }
    let mut err = String::new();
    let mut c = lparse::parse(src, &mut err).unwrap();
    c.popcnt = true;
    let none = Vector::<bool>::new();
    lopt::optimize(
        &mut c,
        &none,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 0,
                interleave: 0,
                fin: 0,
            },
        },
    );
    verified(&c);
    let cs = text_of(&c, "is");
    let cn = text_of(&c, "isnt");
    assert(cs.contains("popcnt.i32") && cs.contains("icmp.eq") && !cs.contains("xor"), cs.as_str());
    assert(cn.contains("popcnt.i64") && cn.contains("icmp.ne") && !cn.contains("xor"), cn.as_str());
    for k in 0..8 {
        let x: []u64 = [xs[k]];
        let p = xs[k] != 0 && (xs[k] & xs[k] - 1) == 0;
        same_result(&b, &c, "is", x, p as u64);
        same_result(&b, &c, "isnt", x, (!p) as u64);
    }
}

// A call's aggregate result in a slot only loads read, on a target that returns it in registers (16 bytes):
// each load of part of an 8-byte chunk with an integer field reads that chunk's one load right after the call
// (`res_chunk`), which the code generators take from the result's register. Before a return, a run of result stores and constant fills (a fill
// of 3 bytes too), past a load of the body's own slot, joins into one store per chunk (`ret_chunks`). A
// chunk's load after a call that ends its block goes at the block's end, and a parameter chunk's load in
// an entry block of a jump alone at the entry's start: the bodies verify.
@test
fn call_results_load_whole_chunks_and_fills_join() {
    let (b, a) = optimized_copy(
        M"(lir ptr 8
sym @dig fn global noinline
sym @both fn global
sym @last fn global
sym @jumps fn global
fn @last
  layout l0 size 8 align 2 [0 i8, 4 i32, 4 i8]
  sig (i8) -> i32
  slot s0 size 8 align 2
b0(v0: i8):
  v1 = slotaddr s0
  call @dig(v0, v1) : (i8) -> l0
  jmp b1
b1:
  v2 = load.i32 v1+4 align 2
  v3 = load.i8 v1 align 0
  v4 = zext.i32 v3
  v5 = add.i32 v2, v4
  ret v5
fn @jumps
  layout l0 size 8 align 2 [0 i32, 4 i32]
  sig (l0) -> i32
b0(v0: ptr):
  jmp b1
b1:
  v1 = load.i32 v0 align 2
  v2 = load.i32 v0+4 align 2
  v3 = sub.i32 v1, v2
  ret v3
fn @dig
  layout l0 size 8 align 2 [0 i8, 4 i32, 4 i8]
  sig (i8) -> l0
b0(v0: i8, v1: ptr):
  v2 = iconst.i8 9
  v3 = iconst.i8 48
  v4 = iconst.i8 1
  v5 = iconst.i8 0
  v6 = iconst.i64 3
  v7 = sub.i8 v0, v3
  v8 = icmp.ule v7, v2
  br v8, b2, b1
b1:
  store v4, v1 align 0
  store v0, v1+4 align 0
  v9 = ptradd v1+5
  memset v9, v5, v6
  ret
b2:
  v10 = zext.i32 v7
  store v5, v1 align 0
  store v10, v1+4 align 2
  ret
fn @both
  layout l0 size 8 align 2 [0 i8, 4 i32, 4 i8]
  sig (i8, i8) -> l0
  slot s0 size 8 align 2
  slot s1 size 8 align 2
b0(v0: i8, v1: i8, v2: ptr):
  v3 = slotaddr s0
  v4 = slotaddr s1
  v5 = iconst.i8 1
  v6 = iconst.i8 0
  v7 = iconst.i64 3
  v8 = iconst.i32 10
  call @dig(v0, v3) : (i8) -> l0
  v9 = load.i8 v3 align 0
  v10 = icmp.eq v9, v6
  br v10, b2, b1
b1:
  store v5, v2 align 0
  v11 = load.i8 v3+4 align 0
  store v11, v2+4 align 0
  v12 = ptradd v2+5
  memset v12, v6, v7
  ret
b2:
  v13 = load.i32 v3+4 align 2
  call @dig(v1, v4) : (i8) -> l0
  v14 = load.i8 v4 align 0
  v15 = icmp.eq v14, v6
  br v15, b4, b3
b3:
  store v5, v2 align 0
  v16 = load.i8 v4+4 align 0
  store v16, v2+4 align 0
  v17 = ptradd v2+5
  memset v17, v6, v7
  ret
b4:
  v18 = load.i32 v4+4 align 2
  v19 = mul.i32 v13, v8
  v20 = add.i32 v19, v18
  store v6, v2 align 0
  store v20, v2+4 align 2
  ret
)",
        16,
        16,
    );
    let d = text_of(&a, "dig");
    assert(!d.contains("memset") && !d.contains("load"), d.as_str());
    let s = text_of(&a, "both");
    assert(
        !s.contains("memset") && !s.contains("load.i8") && !s.contains("load.i32") && s.contains("load.i64"),
        s.as_str(),
    );
    // One store per return.
    let mut stores: u32 = 0;
    let mut at = s.as_str();
    for _ in 0..16 {
        let k = at.find("store ");
        if k < 0 {
            break;
        }
        stores += 1;
        at = at.slice(k as usize + 6, at.len());
    }
    assert_eq(stores, 3);
    let l = text_of(&a, "last");
    assert(l.contains("load.i64") && !l.contains("load.i32"), l.as_str());
    let x: []u64 = [0x35];
    same_result(&b, &a, "last", x, 5);
    let y: []u64 = [0x7A];
    same_result(&b, &a, "last", y, 123);
}

// Small aggregates by value whose fields share an 8-byte chunk, which a target that passes and returns them
// in registers (16 bytes) takes in one integer register: each field of a parameter comes from one load of its
// chunk, the result's stores before a return join into one store per chunk (a float's bits among them), and a
// 4-byte fill of zero is a store. A target that passes and returns them through memory (wasm32) keeps the
// fields' loads and stores; one that returns them through memory alone, the result's stores.
@test
fn aggregate_fields_in_one_chunk_load_and_store_whole() {
    let src = M"(lir ptr 8
sym @padd fn global noinline
sym @opt fn global noinline
sym @fi fn global noinline
sym @use fn global
fn @padd
  layout l0 size 8 align 2 [0 i32, 4 i32]
  sig (l0, l0) -> l0
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.i32 v0 align 2
  v4 = load.i32 v1 align 2
  v5 = add.i32 v3, v4
  v6 = load.i32 v0+4 align 2
  v7 = load.i32 v1+4 align 2
  v8 = sub.i32 v6, v7
  store v5, v2 align 2
  store v8, v2+4 align 2
  ret
fn @opt
  layout l0 size 8 align 2 [0 i8, 4 i32]
  sig (i32) -> l0
b0(v0: i32, v1: ptr):
  v2 = iconst.i32 5
  v3 = iconst.i8 1
  v4 = iconst.i8 0
  v5 = iconst.i64 4
  v6 = icmp.ugt v0, v2
  br v6, b2, b1
b1:
  store v4, v1 align 0
  v7 = ptradd v1+4
  memset v7, v4, v5
  ret
b2:
  store v3, v1 align 0
  store v0, v1+4 align 2
  ret
fn @fi
  layout l0 size 8 align 2 [0 f32, 4 i32]
  sig (l0) -> l0
b0(v0: ptr, v1: ptr):
  v2 = load.f32 v0 align 2
  v3 = load.i32 v0+4 align 2
  v4 = fadd.f32 v2, v2
  v5 = add.i32 v3, v3
  store v4, v1 align 2
  store v5, v1+4 align 2
  ret
fn @use
  layout l0 size 8 align 2 [0 i32, 4 i32]
  layout l1 size 8 align 2 [0 i8, 4 i32]
  sig (i64) -> i64
  slot s0 size 8 align 2
  slot s1 size 8 align 2
  slot s2 size 8 align 2
  slot s3 size 8 align 2
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = trunc.i32 v0
  v6 = iconst.i32 3
  v7 = add.i32 v5, v6
  store v5, v1 align 2
  store v7, v1+4 align 2
  store v7, v2 align 2
  store v5, v2+4 align 2
  call @padd(v1, v2, v3) : (l0, l0) -> l0
  call @opt(v5, v4) : (i32) -> l1
  v8 = load.i32 v3 align 2
  v9 = load.i32 v3+4 align 2
  v10 = load.i8 v4 align 0
  v11 = load.i32 v4+4 align 2
  v12 = iconst.i32 16
  v13 = mul.i32 v8, v12
  v14 = add.i32 v13, v9
  v15 = zext.i32 v10
  v16 = iconst.i32 1000
  v17 = mul.i32 v15, v16
  v18 = add.i32 v14, v17
  v19 = add.i32 v18, v11
  v20 = zext.i64 v19
  ret v20
)";
    let (b, a) = optimized_copy(src, 16, 16);
    let p = text_of(&a, "padd");
    assert(!p.contains("load.i32") && p.contains("load.i64") && p.contains("lshr.i64"), "each parameter is one load");
    assert(p.contains("or.i64") && p.find("store") == p.rfind("store"), "the result is one store");
    let o = text_of(&a, "opt");
    assert(
        !o.contains("memset") && !o.contains("store.i8") && o.contains("shl.i64"),
        "each path stores the result whole",
    );
    let f = text_of(&a, "fi");
    assert(f.contains("bitcast.i32") && f.contains("bitcast.f32"), "the float's bits join the chunk");
    let x: []u64 = [9];
    same_result(&b, &a, "use", x, 21 * 16 + 3 + 1000 + 9);
    let y: []u64 = [2];
    same_result(&b, &a, "use", y, 7 * 16 + 3);
    let (_, w) = optimized_copy(src, 0, 0);
    let wp = text_of(&w, "padd");
    assert(!wp.contains("load.i64") && !wp.contains("lshr") && !wp.contains("or.i64"), wp.as_str());
    same_result(&b, &w, "use", x, 21 * 16 + 3 + 1000 + 9);
    // Passed in registers but returned through memory: the parameters' chunks, the result's two stores.
    let (_, m) = optimized_copy(src, 16, 0);
    let mp = text_of(&m, "padd");
    assert(mp.contains("lshr") && !mp.contains("or.i64") && mp.find("store") != mp.rfind("store"), mp.as_str());
    same_result(&b, &m, "use", x, 21 * 16 + 3 + 1000 + 9);
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

// A copy of a call's aggregate result into an exclusive parameter's referent at an address made after the
// call keeps the call's slot: the call cannot take an address that does not exist yet, so the body still
// verifies (each use after its definition) and gives the same result.
@test
fn a_result_copied_to_an_address_made_after_the_call_keeps_its_slot() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @mk fn global noinline
sym @put fn global noinline
sym @drive fn global
fn @mk
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  store v0, v1 align 3
  store v0, v1+8 align 3
  ret
fn @put
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (ptr, i64) -> void
  ref p0 24 noalias
  slot s0 size 16 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 16
  call @mk(v1, v2) : (i64) -> l0
  v4 = ptradd v0+8
  memcpy v4, v2, v3
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 24 align 3
b0(v0: i64):
  v1 = slotaddr s0
  call @put(v1, v0) : (ptr, i64) -> void
  v2 = load.i64 v1+16 align 3
  ret v2
)",
    );
    let x: []u64 = [7];
    same_result(&b, &a, "drive", x, 7);
}

// The float rewrites `-ffast-math` allows: `x * 1` and `x + 0` go, a division by a constant becomes a
// product by its reciprocal, two constants of an addition chain fold, and a product added becomes one
// fused multiply-add, but for a loop's accumulator, and so does a product less a constant or a constant
// less a product by a constant; none happens without its flag (but the product by the reciprocal of 4,
// which is exact). The values are exact, so the results agree.
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
    assert(text_of(&plain, "f").contains("fadd") && text_of(&plain, "g").contains("fadd"), "no flag, no rewrite");
    let (_, nofma) = optimized_fm(src, all, false);
    assert(!text_of(&nofma, "g").contains("fma"), "no fused multiply-add on the processor");
}

// The times `text` holds `pat`.
const fn count_of(text: &String, pat: str) u32 {
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
// whose stores go through other pointers; not when the parameter escapes into a call (one that keeps the
// pointer), nor when it is a shared reference, which another pointer may reach.
@test
fn a_load_of_an_exclusive_reference_leaves_a_loop_that_writes_elsewhere() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sink fn global noinline
sym @fill fn global noinline
sym @leaky fn global noinline
sym @shared fn global noinline
sym @drive fn global
sym @kept data global
data @kept size 8 align 3
fn @sink
  sig (ptr) -> void
b0(v0: ptr):
  v1 = symaddr @kept
  store v0, v1 align 3
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

// A `static mut` a loop reads and writes stays in a register across it (`promote_places`): loaded before,
// stored back after only when the loop changed it (a loop that wrote nothing, as one that ran no
// iteration, writes nothing), when the loop's other accesses touch other objects or type tags (`tally`,
// `other`). A call, a fence, or a store through a pointer of the static's type tag keeps it in memory.
@test
fn a_static_a_loop_updates_stays_in_a_register() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @count data global
data @count size 4 align 2
sym @base data global
data @base size 4 align 2
sym @opaque fn global noinline
sym @tally fn global noinline
sym @other fn global noinline
sym @called fn global noinline
sym @fenced fn global noinline
sym @pointed fn global noinline
sym @drive fn global
fn @opaque
  sig () -> void
b0:
  v0 = symaddr @base
  v1 = iconst.i32 1
  store v1, v0 align 2
  ret
fn @tally
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = symaddr @count
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.slt v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 8
  v8 = load.i64 v7 align 3 tbaa 4
  v9 = trunc.i32 v8
  v10 = load.i32 v2 align 2 tbaa 3
  v11 = add.i32 v10, v9
  store v11, v2 align 2 tbaa 3
  v12 = add.i64 v5, v4
  jmp b1(v12)
b3:
  ret
fn @other
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = symaddr @count
  v3 = symaddr @base
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.slt v6, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v6 * 8
  v9 = load.i64 v8 align 3 tbaa 4
  v10 = trunc.i32 v9
  v11 = load.i32 v2 align 2 tbaa 3
  v12 = add.i32 v11, v10
  store v12, v2 align 2 tbaa 3
  v13 = load.i32 v3 align 2 tbaa 3
  v14 = add.i32 v13, v10
  store v14, v3 align 2 tbaa 3
  v15 = add.i64 v6, v5
  jmp b1(v15)
b3:
  ret
fn @called
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = symaddr @count
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.slt v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 8
  v8 = load.i64 v7 align 3 tbaa 4
  v9 = trunc.i32 v8
  v10 = load.i32 v2 align 2 tbaa 3
  v11 = add.i32 v10, v9
  store v11, v2 align 2 tbaa 3
  call @opaque() : () -> void
  v12 = add.i64 v5, v4
  jmp b1(v12)
b3:
  ret
fn @fenced
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = symaddr @count
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.slt v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 8
  v8 = load.i64 v7 align 3 tbaa 4
  v9 = trunc.i32 v8
  v10 = load.i32 v2 align 2 tbaa 3
  v11 = add.i32 v10, v9
  store v11, v2 align 2 tbaa 3
  fence seq_cst
  v12 = add.i64 v5, v4
  jmp b1(v12)
b3:
  ret
fn @pointed
  sig (ptr, i64, ptr) -> void
b0(v0: ptr, v1: i64, v2: ptr):
  v3 = symaddr @count
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.slt v6, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v6 * 8
  v9 = load.i64 v8 align 3 tbaa 4
  v10 = trunc.i32 v9
  v11 = load.i32 v3 align 2 tbaa 3
  v12 = add.i32 v11, v10
  store v12, v3 align 2 tbaa 3
  store v10, v2 align 2 tbaa 3
  v13 = add.i64 v6, v5
  jmp b1(v13)
b3:
  ret
fn @drive
  sig () -> i32
  slot s0 size 32 align 3
  slot s1 size 4 align 2
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i64 3
  v3 = iconst.i64 5
  v4 = iconst.i64 0
  store v2, v0 align 3
  store v3, v0+8 align 3
  store v2, v0+16 align 3
  store v3, v0+24 align 3
  call @tally(v0, v4) : (ptr, i64) -> void
  call @tally(v0, v2) : (ptr, i64) -> void
  call @other(v0, v2) : (ptr, i64) -> void
  call @called(v0, v2) : (ptr, i64) -> void
  call @fenced(v0, v2) : (ptr, i64) -> void
  call @pointed(v0, v2, v1) : (ptr, i64, ptr) -> void
  v5 = symaddr @count
  v6 = load.i32 v5 align 2
  v7 = load.i32 v1 align 2
  v8 = add.i32 v6, v7
  ret v8
)",
    );
    let kept: [str; 2] = ["tally", "other"];
    for name in kept {
        let t = text_of(&a, name);
        assert(!stored_in_loop(&t) && t.as_str().find("icmp.ne") >= 0, t.as_str());
    }
    let stay: [str; 3] = ["called", "fenced", "pointed"];
    for name in stay {
        let t = text_of(&a, name);
        assert(stored_in_loop(&t), t.as_str());
    }
    // tally 0, then 3 + 5 + 3; other, called, fenced and pointed the same each; pointed's slot 3.
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 58);
}

// A chain of additions whose leaves are all at hand regroups into a balanced tree (`reassociate`): the
// pairs of parameters add first, and the sum is the same. A partial sum used twice (`v9`) is a leaf, its own
// chain too short to regroup.
@test
fn a_chain_of_additions_regroups_into_a_tree() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sum8 fn global noinline
sym @drive fn global
fn @sum8
  sig (i64, i64, i64, i64, i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i64, v5: i64, v6: i64, v7: i64):
  v8 = add.i64 v0, v1
  v9 = add.i64 v8, v2
  v10 = add.i64 v9, v3
  v11 = add.i64 v10, v4
  v12 = add.i64 v11, v5
  v13 = add.i64 v12, v6
  v14 = add.i64 v13, v7
  v15 = mul.i64 v14, v9
  ret v15
fn @drive
  sig () -> i64
b0:
  v0 = iconst.i64 1
  v1 = iconst.i64 2
  v2 = iconst.i64 3
  v3 = iconst.i64 4
  v4 = iconst.i64 5
  v5 = iconst.i64 6
  v6 = iconst.i64 7
  v7 = iconst.i64 -9
  v8 = call.i64 @sum8(v0, v1, v2, v3, v4, v5, v6, v7) : (i64, i64, i64, i64, i64, i64, i64, i64) -> i64
  ret v8
)",
    );
    let t = text_of(&a, "sum8");
    assert(t.contains("add.i64 v7, v6") && t.contains("add.i64 v5, v4") && t.contains("add.i64 v8, v2"), t.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 114);
}

// An unsigned compare with a constant folds when the largest value of its other side settles it: a shift
// amount masked below 32 is below 32 (its overflow check goes), a bit count of a 32-bit value is at most 32,
// a value shifted right by 28 is below 16 (with the constant on the left too). A compare the bound does not settle
// stays: a bit count against 32 can be equal.
@test
fn compares_the_largest_value_settles_fold() {
    let text = M"(lir ptr 8
sym @shmask fn global
fn @shmask
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 31
  v3 = iconst.i32 32
  v4 = iconst.i32 16
  v5 = iconst.i32 0
  v6 = iconst.i32 28
  v7 = and.i32 v1, v2
  v8 = icmp.uge v7, v3
  br v8, b3, b1
b1:
  v9 = clz.i32 v0
  v10 = icmp.ugt v9, v3
  br v10, b3, b2
b2:
  v11 = lshr.i32 v0, v6
  v12 = icmp.ugt v4, v11
  v13 = icmp.uge v9, v3
  v14 = zext.i32 v13
  v15 = shl.i32 v0, v7
  v16 = add.i32 v15, v14
  br v12, b4(v16), b3
b3:
  ret v5
b4(v17: i32):
  ret v17
)";
    let (b, a) = optimized(text);
    let s = text_of(&a, "shmask");
    assert(!s.contains("icmp.ugt") && s.contains("icmp.uge") && !s.contains("select") && !s.contains("br "), s.as_str());
    same_result(&b, &a, "shmask", [3, 33], 6);
    same_result(&b, &a, "shmask", [0, 2], 1);
}

// A reference is never null (`nonnull`, through `ptrtoint`): a test of `select(c, 0, p)` against null, an
// `Option` of the reference, is the test of `c`, and the `Some` side reads `p` itself. Without the fact
// the select stays.
@test
fn a_null_test_of_a_selected_reference_tests_the_condition() {
    let text = M"(lir ptr 8
sym @last fn global noinline
sym @plain fn global noinline
sym @drive fn global
fn @last
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i32 0
  v3 = load.i64 v0+8 align 3
  v4 = load.ptr v0 align 3
  v5 = ptradd v4, v3 * 4-4 nonnull
  v6 = ptrtoint.i64 v5
  v7 = icmp.eq v3, v1
  v8 = select.i64 v7, v1, v6
  v9 = icmp.ne v8, v1
  br v9, b1, b2
b1:
  v10 = inttoptr.ptr v8
  v11 = load.i32 v10 align 2
  ret v11
b2:
  ret v2
fn @plain
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i32 0
  v3 = load.i64 v0+8 align 3
  v4 = load.ptr v0 align 3
  v5 = ptradd v4, v3 * 4-4
  v6 = ptrtoint.i64 v5
  v7 = icmp.eq v3, v1
  v8 = select.i64 v7, v1, v6
  v9 = icmp.ne v8, v1
  br v9, b1, b2
b1:
  v10 = inttoptr.ptr v8
  v11 = load.i32 v10 align 2
  ret v11
b2:
  ret v2
fn @drive
  sig () -> i32
  slot s0 size 16 align 3
  slot s1 size 8 align 2
b0:
  v0 = slotaddr s0
  v1 = slotaddr s1
  v2 = iconst.i32 5
  v3 = iconst.i32 7
  v4 = iconst.i64 2
  v5 = iconst.i64 0
  store v2, v1 align 2
  store v3, v1+4 align 2
  store v1, v0 align 3
  store v4, v0+8 align 3
  v6 = call.i32 @last(v0) : (ptr) -> i32
  v7 = call.i32 @plain(v0) : (ptr) -> i32
  store v5, v0+8 align 3
  v8 = call.i32 @last(v0) : (ptr) -> i32
  v9 = add.i32 v6, v7
  v10 = add.i32 v9, v8
  ret v10
)";
    let (b, a) = optimized(text);
    let l = text_of(&a, "last");
    assert(!l.contains("select"), l.as_str());
    let p = text_of(&a, "plain");
    assert(p.contains("select"), p.as_str());
    // A plain address equal to a reference's takes its place without the fact: its null test stays.
    let (_, a2) = optimized(
        M"(lir ptr 8
sym @twin fn global
fn @twin
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = ptradd v0, v1 * 4 nonnull
  v4 = ptrtoint.i64 v3
  v5 = ptradd v0, v1 * 4
  v6 = ptrtoint.i64 v5
  v7 = icmp.eq v6, v2
  v8 = zext.i64 v7
  v9 = add.i64 v4, v8
  ret v9
)",
    );
    let w = text_of(&a2, "twin");
    assert(w.contains("icmp.eq"), w.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 14);
}

// A thread-local variable a loop reads and writes stays in a register across it as a `static mut` does: a
// loop that calls nothing has no suspension point, so the address from before it stays the thread's.
@test
fn a_thread_local_a_loop_updates_stays_in_a_register() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @count tls global
sym @tally fn global noinline
sym @drive fn global
fn @tally
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = symaddr @count
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.slt v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 8
  v8 = load.i64 v7 align 3 tbaa 4
  v9 = trunc.i32 v8
  v10 = load.i32 v2 align 2 tbaa 3
  v11 = add.i32 v10, v9
  store v11, v2 align 2 tbaa 3
  v12 = add.i64 v5, v4
  jmp b1(v12)
b3:
  ret
fn @drive
  sig () -> i32
  slot s0 size 24 align 3
b0:
  v0 = slotaddr s0
  v1 = iconst.i64 3
  v2 = iconst.i64 5
  store v1, v0 align 3
  store v2, v0+8 align 3
  store v1, v0+16 align 3
  call @tally(v0, v1) : (ptr, i64) -> void
  call @tally(v0, v1) : (ptr, i64) -> void
  v3 = symaddr @count
  v4 = load.i32 v3 align 2
  ret v4
data @count size 4 align 2
)",
    );
    let t = text_of(&a, "tally");
    assert(!stored_in_loop(&t) && t.as_str().find("icmp.ne") >= 0, t.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 22);
}

// Whether body text `t` stores to `@count` in the block that loads its loop's elements (`load.i64`).
fn stored_in_loop(t: &String) bool {
    let s = t.as_str();
    let at = s.find(" = symaddr @count");
    assert(at >= 0, s);
    let mut from = at as usize;
    // Each step goes back one byte, to the value's name.
    while from > 0 && s.byte_at(from - 1) != b' ' {
        from -= 1;
    }
    let pat = format(", {} align", s.slice(from, at as usize));
    return block_at(s, s.find("load.i64") as usize).find(&pat) >= 0;
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

// A truncation keeps its operand's bound when the narrower type holds it: `trunc.i8 (x & 7) < 8` holds;
// `trunc.i8 (x & 496)` may be any multiple of 16, so its `< 200` stays.
@test
fn a_truncation_keeps_the_bound_its_type_holds() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i32) -> i64
b0(v0: i32):
  v1 = iconst.i32 7
  v2 = iconst.i8 8
  v3 = iconst.i32 496
  v4 = iconst.i8 200
  v5 = and.i32 v0, v1
  v6 = trunc.i8 v5
  v7 = icmp.ult v6, v2
  v8 = and.i32 v0, v3
  v9 = trunc.i8 v8
  v10 = icmp.ult v9, v4
  v11 = zext.i64 v7
  v12 = zext.i64 v10
  v13 = add.i64 v11, v12
  ret v13
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "icmp.ult") == 1, t.as_str());
    let small: []u64 = [0x2C];
    same_result(&b, &a, "f", small, 2);
    let big: []u64 = [0xF0];
    same_result(&b, &a, "f", big, 1);
}

// A branch bounds its operand from below too: past `x <=u 1`, `x - 1` is not 0, so its leading zeros are
// below the width and `clz(x - 1) >=u 32` fails (`@f`); past `0 <u x`, `ctz(x) <u 32` holds
// (`@h`). Past `x <=u 0` alone `x - 1` may be 0, so `@g`'s test stays. Past `x != 0`, `31 - clz(x)` clears
// bits of 31 alone: an `xor` (`@l`, whose 0 aborts); so does `-1 - x` of 64 bits, whose mask is every bit (`@n`).
@test
fn a_lower_bound_decides_tests_of_leading_and_trailing_zeros() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
sym @g fn global
sym @h fn global
sym @l fn global
sym @n fn global
sym @abort fn global
fn @f
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = iconst.i32 -1
  v3 = iconst.i32 32
  v4 = iconst.i32 99
  v5 = icmp.ule v0, v1
  br v5, b1, b2
b1:
  ret v1
b2:
  v6 = add.i32 v0, v2
  v7 = clz.i32 v6
  v8 = icmp.uge v7, v3
  br v8, b3, b4
b3:
  ret v4
b4:
  ret v7
fn @g
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 -1
  v3 = iconst.i32 32
  v4 = iconst.i32 99
  v5 = icmp.ule v0, v1
  br v5, b1, b2
b1:
  ret v1
b2:
  v6 = add.i32 v0, v2
  v7 = clz.i32 v6
  v8 = icmp.uge v7, v3
  br v8, b3, b4
b3:
  ret v4
b4:
  ret v7
fn @h
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 32
  v3 = iconst.i32 99
  v4 = icmp.ult v1, v0
  br v4, b1, b2
b1:
  v5 = ctz.i32 v0
  v6 = icmp.ult v5, v2
  br v6, b3, b2
b2:
  ret v3
b3:
  ret v5
fn @l
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 31
  v3 = icmp.ne v0, v1
  br v3, b1, b2
b1:
  v4 = clz.i32 v0
  v5 = sub.i32 v2, v4
  ret v5
b2:
  call @abort() : () -> void
  unreachable
fn @n
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -1
  v2 = sub.i64 v1, v0
  ret v2
)",
    );
    let l = text_of(&a, "l");
    let n = text_of(&a, "n");
    assert(!n.contains("sub"), n.as_str());
    assert(l.contains("xor.i32") && !l.contains("sub"), l.as_str());
    let f = text_of(&a, "f");
    let g = text_of(&a, "g");
    let h = text_of(&a, "h");
    assert(count_of(&f, "icmp") == 1 && !f.contains("99"), f.as_str());
    assert(count_of(&g, "icmp") == 2, g.as_str());
    assert(count_of(&h, "icmp") == 1, h.as_str());
    let xs: [u64; 6] = [0, 1, 2, 3, 0x80000000, 0xFFFFFFFF];
    let fw: [u64; 6] = [1, 1, 31, 30, 1, 0];
    let gw: [u64; 6] = [0, 99, 31, 30, 1, 0];
    let hw: [u64; 6] = [99, 0, 1, 0, 31, 0];
    let lw: [u64; 6] = [0, 0, 1, 1, 31, 31];
    for k in 0..6usize {
        let one: [u64; 1] = [xs[k]];
        same_result(&b, &a, "f", one[0..1], fw[k]);
        same_result(&b, &a, "g", one[0..1], gw[k]);
        same_result(&b, &a, "h", one[0..1], hw[k]);
        same_result(&b, &a, "n", one[0..1], ~xs[k]);
        // 0 calls `abort`.
        if k != 0 {
            same_result(&b, &a, "l", one[0..1], lw[k]);
        }
    }
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

// Lane operations of two constant vectors (a splat of a constant, a wide constant) are a wide constant,
// lane by lane and wrapping: a product, a difference, a sum, an `and`, an `or`.
@test
fn lane_operations_of_constants_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @lanes fn global noinline
fn @lanes
  sig () -> i64
  slot s0 size 16 align 4
b0:
  v0 = iconst.i32 -3
  v1 = splat.v4i32 v0
  v2 = wconst.v4i32 0x200000001, 0x7fffffff80000000
  v3 = mul.v4i32 v1, v2
  v4 = sub.v4i32 v3, v2
  v5 = add.v4i32 v4, v1
  v6 = and.v4i32 v5, v2
  v7 = or.v4i32 v6, v4
  v8 = slotaddr s0
  store v7, v8 align 4
  v9 = load.i64 v8 align 3
  v10 = load.i64 v8+8 align 3
  v11 = xor.i64 v9, v10
  ret v11
)",
    );
    let l = text_of(&a, "lanes");
    assert(!l.contains(".v4i32 v"), l.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "lanes", none, 0xFFFFFFFD7FFFFFFD);
}

// A body whose result pointer only a whole copy from one slot right before its return reads builds the
// result in place (`@build`: no copy and no slot, the loop's stores through the result pointer); not when
// it may unwind (`@may_panic`), nor when the result pointer has another use (`@peek`). Each slot is written
// in a loop, which the walk does not forward into the copy.
@test
fn a_result_built_in_a_slot_is_built_in_place() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @build fn global noinline
sym @may_panic fn global noinline
sym @peek fn global noinline
sym @drive fn global
fn @build
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> l0
  slot s0 size 16 align 3
b0(v0: i64, v1: ptr):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 2
  v6 = iconst.i64 16
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = ptradd v2, v7 * 8
  v10 = add.i64 v0, v7
  store v10, v9 align 3
  v11 = add.i64 v7, v4
  jmp b1(v11)
b3:
  memcpy v1, v2, v6
  ret
fn @may_panic
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> l0
  slot s0 size 16 align 3
b0(v0: i64, v1: ptr):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 2
  v6 = iconst.i64 16
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = ptradd v2, v7 * 8
  v10 = add.i64 v0, v7
  store v10, v9 align 3
  v11 = add.i64 v7, v4
  v12 = icmp.eq v10, v6
  br v12, b4, b1(v11)
b3:
  memcpy v1, v2, v6
  ret
b4:
  panic "sixteen"
fn @peek
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> l0
  slot s0 size 16 align 3
b0(v0: i64, v1: ptr):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 2
  v6 = iconst.i64 16
  v7 = load.i64 v1+8 align 3
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v5
  br v9, b2, b3
b2:
  v10 = ptradd v2, v8 * 8
  v11 = add.i64 v7, v8
  store v11, v10 align 3
  v12 = add.i64 v8, v4
  jmp b1(v12)
b3:
  memcpy v1, v2, v6
  ret
fn @drive
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  call @build(v0, v1) : (i64) -> l0
  v2 = load.i64 v1 align 3
  v3 = load.i64 v1+8 align 3
  call @may_panic(v0, v1) : (i64) -> l0
  v4 = load.i64 v1+8 align 3
  call @peek(v0, v1) : (i64) -> l0
  v5 = load.i64 v1+8 align 3
  v6 = add.i64 v2, v3
  v7 = add.i64 v6, v4
  v8 = add.i64 v7, v5
  ret v8
)",
    );
    let bt = text_of(&a, "build");
    assert(!bt.contains("memcpy") && !bt.contains("slotaddr"), bt.as_str());
    let mp = text_of(&a, "may_panic");
    assert(mp.contains("memcpy"), mp.as_str());
    let pk = text_of(&a, "peek");
    assert(pk.contains("memcpy"), pk.as_str());
    // build: 5, 6; may_panic: 5, 6; peek: the result's second word (6) plus 0, plus 1.
    let args: []u64 = [5];
    same_result(&b, &a, "drive", args, 5 + 6 + 6 + 7);
}

// A fill whose bytes the stores through its address after it all write, with no read between, goes
// (`@cover`, more stores than `overwrite` keeps); a byte no store writes (`@gap`) or a load between
// (`@read`) keeps it.
@test
fn a_fill_later_stores_overwrite_goes() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @cover fn global noinline
sym @gap fn global noinline
sym @read fn global noinline
sym @drive fn global
fn @cover
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i8 0
  v3 = iconst.i64 80
  memset v0, v2, v3
  store v1, v0+8 align 3
  store v1, v0+0 align 3
  store v1, v0+16 align 3
  store v1, v0+24 align 3
  store v1, v0+32 align 3
  store v1, v0+40 align 3
  store v1, v0+48 align 3
  store v1, v0+56 align 3
  store v1, v0+64 align 3
  store v1, v0+72 align 3
  ret
fn @gap
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i8 0
  v3 = iconst.i64 24
  memset v0, v2, v3
  store v1, v0 align 3
  v4 = trunc.i32 v1
  store v4, v0+8 align 3
  store v1, v0+16 align 3
  ret
fn @read
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i8 0
  v3 = iconst.i64 16
  memset v0, v2, v3
  store v1, v0 align 3
  v4 = load.i64 v0+8 align 3
  store v1, v0+8 align 3
  ret v4
fn @drive
  sig (i64) -> i64
  slot s0 size 80 align 3
b0(v0: i64):
  v1 = slotaddr s0
  call @cover(v1, v0) : (ptr, i64) -> void
  v2 = load.i64 v1+16 align 3
  v3 = iconst.i64 -1
  call @gap(v1, v3) : (ptr, i64) -> void
  v4 = load.i64 v1+8 align 3
  v5 = call.i64 @read(v1, v0) : (ptr, i64) -> i64
  v6 = add.i64 v2, v4
  v7 = add.i64 v6, v5
  ret v7
)",
    );
    assert(!text_of(&a, "cover").contains("memset"), text_of(&a, "cover").as_str());
    assert(text_of(&a, "gap").contains("memset"), text_of(&a, "gap").as_str());
    assert(text_of(&a, "read").contains("memset"), text_of(&a, "read").as_str());
    let args: []u64 = [5];
    same_result(&b, &a, "drive", args, 5 + 0xFFFFFFFF);
}

// A body's stores past the ones `overwrite` keeps go as they do alone after a body whose last fill has
// the index of one of them (`@fill`): the fill of an earlier body is not one of the later's.
@test
fn an_earlier_bodys_fill_keeps_no_store_of_a_later_one() {
    let keep = M"(fn @keep
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i8 0
  v3 = iconst.i64 16
  store v1, v0 align 3
  store v3, v0+8 align 3
  store v3, v0+16 align 3
  store v3, v0+24 align 3
  store v3, v0+32 align 3
  store v3, v0+40 align 3
  store v3, v0+48 align 3
  store v3, v0+56 align 3
  store v2, v0+64 align 0
  store v1, v0 align 3
  ret
)";
    let fill = M"(lir ptr 8
sym @fill fn global noinline
sym @keep fn global noinline
fn @fill
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i8 0
  v2 = iconst.i64 16
  memset v0, v1, v2
  ret
)";
    let (_, a) = optimized(format("{}{}", fill, keep).as_str());
    let (_, one) = optimized(format("lir ptr 8\nsym @keep fn global noinline\n{}", keep).as_str());
    assert(text_of(&a, "keep") == text_of(&one, "keep"), text_of(&a, "keep").as_str());
}

// A `bool` payload read only under its tag's test is 0 or 1 there alone: `Err(2)`'s payload byte is 2,
// so the read leaves its test without its bound where promotion reads it at the copy (`@copied`), where
// if-conversion moves it (`@moved`, whose slot a call takes) and where it leaves a loop (`@looped`), and
// `x ? 0 : f` stays a choice.
@test
fn a_payload_read_leaves_its_test_without_its_bound() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @peek fn global noinline
sym @copied fn global noinline
sym @moved fn global noinline
sym @looped fn global noinline
sym @drive fn global
fn @peek
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i8 0
  store v1, v0+8 align 0
  ret
fn @copied
  sig (ptr) -> i8
  slot s0 size 12 align 2
  slot s1 size 1 align 0
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 12
  memcpy v1, v0, v2
  v3 = load.i8 v1 align 0 range 1
  v4 = iconst.i8 0
  v5 = icmp.ne v3, v4
  v6 = slotaddr s1
  br v5, b2, b1
b1:
  v7 = load.i8 v1+4 align 0 bool
  store v7, v6 align 0
  jmp b3
b2:
  store v4, v6 align 0
  jmp b3
b3:
  v8 = load.i8 v6 align 0
  ret v8
fn @moved
  sig (ptr) -> i8
  slot s0 size 12 align 2
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 12
  memcpy v1, v0, v2
  call @peek(v1) : (ptr) -> void
  v3 = load.i8 v1 align 0 range 1
  v4 = iconst.i8 0
  v5 = icmp.ne v3, v4
  br v5, b2, b1
b1:
  v6 = load.i8 v1+4 align 0 bool
  jmp b3(v6)
b2:
  jmp b3(v4)
b3(v7: i8):
  ret v7
fn @looped
  sig (ptr, i64) -> i8
  slot s0 size 12 align 2
  slot s1 size 1 align 0
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 12
  memcpy v2, v0, v3
  call @peek(v2) : (ptr) -> void
  v4 = load.i8 v2 align 0 range 1
  v5 = iconst.i8 0
  v6 = icmp.ne v4, v5
  v7 = iconst.i64 0
  v8 = slotaddr s1
  jmp b1(v7, v5)
b1(v9: i64, v10: i8):
  v11 = icmp.ult v9, v1
  br v11, b2, b6
b2:
  br v6, b4, b3
b3:
  v12 = load.i8 v2+4 align 0 bool
  store v12, v8 align 0
  jmp b5
b4:
  store v5, v8 align 0
  jmp b5
b5:
  v13 = load.i8 v8 align 0
  v14 = or.i8 v10, v13
  v15 = iconst.i64 1
  v16 = add.i64 v9, v15
  jmp b1(v16, v14)
b6:
  ret v10
fn @drive
  sig () -> i8
  slot s0 size 12 align 2
b0:
  v0 = slotaddr s0
  v1 = iconst.i8 1
  store v1, v0 align 0
  v2 = iconst.i32 2
  store v2, v0+4 align 2
  v3 = call.i8 @copied(v0) : (ptr) -> i8
  v4 = call.i8 @moved(v0) : (ptr) -> i8
  v5 = iconst.i64 3
  v6 = call.i8 @looped(v0, v5) : (ptr, i64) -> i8
  v7 = or.i8 v3, v4
  v8 = or.i8 v7, v6
  ret v8
)",
    );
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 0);
}

// A store into an exclusive reference's referent that a later store overwrites goes across a call that
// cannot reach that memory (`@over`: one store stays); not when the call takes the reference (`@lent`,
// whose callee reads it), nor when the reference is a shared one, which the callee may reach (`@shared`),
// nor when the call may panic (`@risky`): a panic may unwind to code that reads the first value.
@test
fn a_store_a_later_store_overwrites_goes_across_a_call() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @tick fn global noinline
sym @peek fn global noinline
sym @over fn global noinline
sym @lent fn global noinline
sym @shared fn global noinline
sym @check fn global noinline
sym @risky fn global noinline
sym @drive fn global
sym @n data global
data @n size 8 align 3
fn @tick
  sig () -> void
b0:
  v0 = symaddr @n
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
  ret
fn @peek
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  ret v1
fn @over
  sig (ptr) -> void
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i64 5
  v2 = iconst.i64 9
  store v1, v0 align 3
  call @tick() : () -> void
  store v2, v0 align 3
  ret
fn @lent
  sig (ptr) -> i64
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i64 5
  v2 = iconst.i64 9
  store v1, v0 align 3
  v3 = call.i64 @peek(v0) : (ptr) -> i64
  store v2, v0 align 3
  ret v3
fn @shared
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i64 5
  v2 = iconst.i64 9
  store v1, v0 align 3
  call @tick() : () -> void
  store v2, v0 align 3
  ret
fn @check
  sig (i64) -> void
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1: cold
  panic "attempt to divide by zero"
b2:
  ret
fn @risky
  sig (ptr) -> void
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i64 5
  v2 = iconst.i64 9
  v3 = iconst.i64 1
  store v1, v0 align 3
  call @check(v3) : (i64) -> void
  store v2, v0 align 3
  ret
fn @drive
  sig () -> i64
  slot s0 size 8 align 3
b0:
  v0 = slotaddr s0
  call @over(v0) : (ptr) -> void
  v1 = call.i64 @lent(v0) : (ptr) -> i64
  call @shared(v0) : (ptr) -> void
  call @risky(v0) : (ptr) -> void
  v2 = load.i64 v0 align 3
  v3 = symaddr @n
  v4 = load.i64 v3 align 3
  v5 = mul.i64 v1, v2
  v6 = add.i64 v5, v4
  ret v6
)",
    );
    let o = text_of(&a, "over");
    assert(count_of(&o, "store") == 1, o.as_str());
    let l = text_of(&a, "lent");
    assert(count_of(&l, "store") == 2, l.as_str());
    let s = text_of(&a, "shared");
    assert(count_of(&s, "store") == 2, s.as_str());
    let k = text_of(&a, "risky");
    assert(count_of(&k, "store") == 2, k.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 47);
}

// A slot whose address goes to a call that neither writes through it nor keeps it (`@look`) holds the
// value of its one store after the call and after any other call: the load after them reads that value
// (`@lent`); not when the callee writes through it (`@poke`; `@deep`, through more address arithmetic than
// the effect inference follows) or keeps it (`@keep`).
@test
fn a_slot_a_call_only_reads_keeps_its_value() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @look fn global noinline
sym @poke fn global noinline
sym @deep fn global noinline
sym @keep fn global noinline
sym @lent fn global noinline
sym @poked fn global noinline
sym @deeply fn global noinline
sym @kept fn global noinline
sym @drive fn global
sym @at data global
data @at size 8 align 3
fn @deep
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = ptradd v0+0
  v2 = ptradd v1+0
  v3 = ptradd v2+0
  v4 = ptradd v3+0
  v5 = ptradd v4+0
  v6 = ptradd v5+0
  v7 = ptradd v6+0
  v8 = ptradd v7+0
  v9 = ptradd v8+0
  v10 = iconst.i64 50
  store v10, v9 align 3
  ret v10
fn @deeply
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @deep(v1) : (ptr) -> i64
  v3 = load.i64 v1 align 3
  v4 = add.i64 v3, v2
  ret v4
fn @look
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  ret v3
fn @poke
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 40
  store v1, v0 align 3
  ret v1
fn @keep
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = symaddr @at
  store v0, v1 align 3
  v2 = iconst.i64 1
  ret v2
fn @lent
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @look(v1) : (ptr) -> i64
  v3 = symaddr @at
  v4 = call.i64 @keep(v3) : (ptr) -> i64
  v5 = load.i64 v1 align 3
  v6 = add.i64 v5, v2
  ret v6
fn @poked
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @poke(v1) : (ptr) -> i64
  v3 = load.i64 v1 align 3
  v4 = add.i64 v3, v2
  ret v4
fn @kept
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @keep(v1) : (ptr) -> i64
  v3 = load.i64 v1 align 3
  v4 = add.i64 v3, v2
  ret v4
fn @drive
  sig (i64) -> i64
b0(v0: i64):
  v1 = call.i64 @lent(v0) : (i64) -> i64
  v2 = call.i64 @poked(v0) : (i64) -> i64
  v3 = call.i64 @kept(v0) : (i64) -> i64
  v4 = call.i64 @deeply(v0) : (i64) -> i64
  v5 = add.i64 v1, v2
  v6 = add.i64 v5, v3
  v7 = add.i64 v6, v4
  ret v7
)",
    );
    let l = text_of(&a, "lent");
    assert(count_of(&l, "load") == 0, l.as_str());
    let p = text_of(&a, "poked");
    assert(count_of(&p, "load") == 1, p.as_str());
    let d = text_of(&a, "deeply");
    assert(count_of(&d, "load") == 1, d.as_str());
    let k = text_of(&a, "kept");
    assert(count_of(&k, "load") == 1, k.as_str());
    let x: []u64 = [6];
    same_result(&b, &a, "drive", x, 200);
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

// A branch on a condition a dominating branch decided jumps: the edge into its block fixed the value (the
// one branch left may become a select of the two returns).
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
        (first < 0 || t.as_str().slice(first as usize + 3, t.len()).find("br ") < 0) && !t.contains("ret v1"),
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

// Function `name` of `before` and of `after` on arguments `args` both panic.
fn same_panic(before: &Package, after: &Package, name: str, args: []u64) {
    let mut e = leval::Eval::new(before);
    let o = e.run(before.find_symbol(name), args);
    let mut e2 = leval::Eval::new(after);
    let o2 = e2.run(after.find_symbol(name), args);
    assert(o.kind != leval::EV_OK, name);
    assert_eq(o2.kind, o.kind);
    assert(o.msg.as_str() == o2.msg.as_str(), o2.msg.as_str());
}

// An order fact `x <u y` holds for each value `y` is at most: `n` of a saturating `n - 1` (`sat`), the
// length a dominating branch keeps `n` at most (`guarded`), a length equal to the bound (`eqlen`); `w % n`
// is below an `n` of at least 1 (`rem`), and a value below another's lower bound is below it (`low`, and
// `eqk`, a length equal to a constant bounded from both sides). Not
// `n` of an `n - 2` below `n`'s lower bound (`wraps`), nor of a select of `n - 2` on `n >=u 1` (`unsat`),
// nor a shift whose bound reaches the lower bound (`high`): each of those checks fails and panics.
@test
fn order_facts_follow_the_values_a_bound_is_at_most() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sat fn global
sym @unsat fn global
sym @wraps fn global
sym @guarded fn global
sym @eqlen fn global
sym @rem fn global
sym @low fn global
sym @high fn global
sym @eqk fn global
fn @eqk
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 256
  v4 = iconst.i64 255
  v5 = icmp.ne v0, v3
  br v5, b3, b1
b1:
  v6 = and.i64 v1, v4
  v7 = icmp.ult v6, v0
  br v7, b2, b4
b2:
  ret v6
b3:
  ret v2
b4: cold
  panic "index out of bounds"
fn @sat
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = icmp.uge v0, v2
  v4 = sub.i64 v0, v2
  v5 = select.i64 v3, v4, v1
  jmp b1(v1, v1)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v5
  br v8, b2, b4
b2:
  v9 = icmp.ult v6, v0
  br v9, b3, b5
b3:
  v10 = add.i64 v7, v6
  v11 = add.i64 v6, v2
  jmp b1(v11, v10)
b4:
  ret v7
b5: cold
  panic "index out of bounds"
fn @unsat
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = icmp.uge v0, v2
  v5 = sub.i64 v0, v3
  v6 = select.i64 v4, v5, v1
  jmp b1(v1, v1)
b1(v7: i64, v8: i64):
  v9 = icmp.ult v7, v6
  br v9, b2, b4
b2:
  v10 = icmp.ult v7, v0
  br v10, b3, b5
b3:
  v11 = add.i64 v8, v7
  v12 = add.i64 v7, v2
  jmp b1(v12, v11)
b4:
  ret v8
b5: cold
  panic "index out of bounds"
fn @wraps
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = icmp.eq v0, v1
  br v4, b5, b1
b1:
  v5 = sub.i64 v0, v3
  jmp b2(v1, v1)
b2(v6: i64, v7: i64):
  v8 = icmp.ult v6, v5
  br v8, b3, b7
b3:
  v9 = icmp.ult v6, v0
  br v9, b4, b6
b4:
  v10 = add.i64 v7, v6
  v11 = add.i64 v6, v2
  jmp b2(v11, v10)
b5:
  ret v1
b6: cold
  panic "index out of bounds"
b7:
  ret v7
fn @guarded
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ugt v0, v1
  br v4, b6, b1
b1:
  jmp b2(v2, v2)
b2(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b3, b5
b3:
  v8 = icmp.ult v5, v1
  br v8, b4, b7
b4:
  v9 = add.i64 v6, v5
  v10 = add.i64 v5, v3
  jmp b2(v10, v9)
b5:
  ret v6
b6:
  ret v2
b7: cold
  panic "index out of bounds"
fn @eqlen
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ne v0, v1
  br v4, b6, b1
b1:
  jmp b2(v2, v2)
b2(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b3, b5
b3:
  v8 = icmp.uge v5, v1
  br v8, b7, b4
b4:
  v9 = add.i64 v6, v5
  v10 = add.i64 v5, v3
  jmp b2(v10, v9)
b5:
  ret v6
b6:
  ret v2
b7: cold
  panic "index out of bounds"
fn @rem
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v1, v2
  br v3, b3, b1
b1:
  v4 = urem.i64 v0, v1
  v5 = icmp.ult v4, v1
  br v5, b2, b4
b2:
  ret v4
b3:
  ret v2
b4: cold
  panic "index out of bounds"
fn @low
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 200
  v4 = iconst.i64 57
  v5 = icmp.ult v0, v3
  br v5, b3, b1
b1:
  v6 = lshr.i64 v1, v4
  v7 = icmp.ult v6, v0
  br v7, b2, b4
b2:
  ret v6
b3:
  ret v2
b4: cold
  panic "index out of bounds"
fn @high
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 200
  v4 = iconst.i64 56
  v5 = icmp.ult v0, v3
  br v5, b3, b1
b1:
  v6 = lshr.i64 v1, v4
  v7 = icmp.ult v6, v0
  br v7, b2, b4
b2:
  ret v6
b3:
  ret v2
b4: cold
  panic "index out of bounds"
)",
    );
    for name in ["sat", "guarded", "eqlen", "rem", "low", "eqk"] {
        let t = text_of(&a, name);
        assert(!t.contains("panic"), t.as_str());
    }
    for name in ["unsat", "wraps", "high"] {
        let t = text_of(&a, name);
        assert(t.contains("panic"), t.as_str());
    }
    let five: []u64 = [5];
    same_result(&b, &a, "sat", five, 6);
    let zero: []u64 = [0];
    same_result(&b, &a, "sat", zero, 0);
    same_result(&b, &a, "unsat", five, 3);
    let one: []u64 = [1];
    same_panic(&b, &a, "unsat", one);
    same_result(&b, &a, "wraps", five, 3);
    same_panic(&b, &a, "wraps", one);
    let fits: []u64 = [4, 10];
    same_result(&b, &a, "guarded", fits, 6);
    let over: []u64 = [10, 4];
    same_result(&b, &a, "guarded", over, 0);
    let equal: []u64 = [4, 4];
    same_result(&b, &a, "eqlen", equal, 6);
    let unequal: []u64 = [4, 5];
    same_result(&b, &a, "eqlen", unequal, 0);
    let r: []u64 = [17, 5];
    same_result(&b, &a, "rem", r, 2);
    let big: []u64 = [200, 0xFFFFFFFFFFFFFFFF];
    same_result(&b, &a, "low", big, 127);
    same_panic(&b, &a, "high", big);
    let small: []u64 = [199, 0xFFFFFFFFFFFFFFFF];
    same_result(&b, &a, "high", small, 0);
    let k: []u64 = [256, 0x1234];
    same_result(&b, &a, "eqk", k, 0x34);
}

// A binary search's midpoint `lo + ((hi - lo) >> 1)` is below `hi` where `lo <u hi` holds, and `hi`,
// whose back edges pass itself or the midpoint, stays at most its start, the length: the check of the
// midpoint goes (`param_bounds`, `mid_top`). Under `lo <=u hi` the midpoint may be `hi`: the check stays
// and fails for a key past every element.
@test
fn a_binary_search_midpoint_stays_below_the_length() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @bs fn global
sym @incl fn global
fn @bs
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v0)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v5
  br v6, b2, b4
b2:
  v7 = sub.i64 v5, v4
  v8 = lshr.i64 v7, v3
  v9 = add.i64 v4, v8
  v10 = icmp.ult v9, v0
  br v10, b3, b5
b3:
  v11 = icmp.ult v9, v1
  v12 = add.i64 v9, v3
  v13 = select.i64 v11, v12, v4
  v14 = select.i64 v11, v5, v9
  jmp b1(v13, v14)
b4:
  ret v4
b5: cold
  panic "index out of bounds"
fn @incl
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v0)
b1(v4: i64, v5: i64):
  v6 = icmp.ule v4, v5
  br v6, b2, b4
b2:
  v7 = sub.i64 v5, v4
  v8 = lshr.i64 v7, v3
  v9 = add.i64 v4, v8
  v10 = icmp.ult v9, v0
  br v10, b3, b5
b3:
  v11 = icmp.ult v9, v1
  v12 = add.i64 v9, v3
  v13 = select.i64 v11, v12, v4
  v14 = select.i64 v11, v5, v9
  jmp b1(v13, v14)
b4:
  ret v4
b5: cold
  panic "index out of bounds"
)",
    );
    let t = text_of(&a, "bs");
    assert(!t.contains("panic"), t.as_str());
    let i = text_of(&a, "incl");
    assert(i.contains("panic"), i.as_str());
    for n in [0u64, 1, 2, 7, 100] {
        for key in [0u64, 3, 1000] {
            let x: [u64; 2] = [n, key];
            same_result(&b, &a, "bs", x[0..2], key.min(n));
        }
    }
    let past: []u64 = [7, 1000];
    same_panic(&b, &a, "incl", past);
}

// A signed counter from 0 by steps of 1 under `i <s n` stays at least 0 (`param_bounds`), so `i <s n` is
// `i <u n`, and its sign extension stays below the extension of `n`, which a branch keeps at most the
// length: the check of `sext(i) <u len` goes. From -1 the extension of the first `i` is huge: it stays.
@test
fn a_signed_counter_from_zero_indexes_below_the_length() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @up fn global
sym @neg fn global
fn @up
  sig (i32, i64) -> i64
b0(v0: i32, v1: i64):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  v4 = iconst.i64 0
  v5 = icmp.slt v0, v2
  br v5, b6, b1
b1:
  v6 = sext.i64 v0
  v7 = icmp.ugt v6, v1
  br v7, b6, b2(v2, v4)
b2(v8: i32, v9: i64):
  v10 = icmp.slt v8, v0
  br v10, b3, b5
b3:
  v11 = sext.i64 v8
  v12 = icmp.ult v11, v1
  br v12, b4, b7
b4:
  v13 = add.i64 v9, v11
  v14 = add.i32 v8, v3
  jmp b2(v14, v13)
b5:
  ret v9
b6:
  ret v4
b7: cold
  panic "index out of bounds"
fn @neg
  sig (i32, i64) -> i64
b0(v0: i32, v1: i64):
  v2 = iconst.i32 -1
  v3 = iconst.i32 1
  v4 = iconst.i64 0
  v5 = icmp.slt v0, v2
  br v5, b6, b1
b1:
  v6 = sext.i64 v0
  v7 = icmp.ugt v6, v1
  br v7, b6, b2(v2, v4)
b2(v8: i32, v9: i64):
  v10 = icmp.slt v8, v0
  br v10, b3, b5
b3:
  v11 = sext.i64 v8
  v12 = icmp.ult v11, v1
  br v12, b4, b7
b4:
  v13 = add.i64 v9, v11
  v14 = add.i32 v8, v3
  jmp b2(v14, v13)
b5:
  ret v9
b6:
  ret v4
b7: cold
  panic "index out of bounds"
)",
    );
    let t = text_of(&a, "up");
    assert(!t.contains("panic"), t.as_str());
    let n = text_of(&a, "neg");
    assert(n.contains("panic"), n.as_str());
    let five: []u64 = [5, 10];
    same_result(&b, &a, "up", five, 10);
    let all: []u64 = [10, 10];
    same_result(&b, &a, "up", all, 45);
    let over: []u64 = [11, 10];
    same_result(&b, &a, "up", over, 0);
    let negative: []u64 = [0xFFFFFFFF, 10];
    same_result(&b, &a, "up", negative, 0);
    same_panic(&b, &a, "neg", five);
}

// A binary search's `(lo + hi) >> 1` under `lo <u hi` with `hi` from a length at most half the type's range
// stays at most `hi` (`param_bounds`) and below it (`half_sum`): its check goes. From a length of any
// value the sum may wrap and the check stays.
@test
fn a_midpoint_of_a_sum_that_cannot_wrap_stays_below_the_length() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @half fn global
sym @any fn global
fn @half
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = lshr.i64 v0, v2
  v4 = iconst.i64 0
  jmp b1(v4, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v6
  br v7, b2, b6
b2:
  v8 = add.i64 v5, v6
  v9 = lshr.i64 v8, v2
  v10 = icmp.ult v9, v3
  br v10, b3, b5
b3:
  v11 = icmp.ult v9, v1
  br v11, b4, b1(v5, v9)
b4:
  v12 = add.i64 v9, v2
  jmp b1(v12, v6)
b5: cold
  panic "index out of bounds"
b6:
  ret v5
fn @any
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = sub.i64 v0, v2
  v4 = iconst.i64 0
  jmp b1(v4, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v6
  br v7, b2, b6
b2:
  v8 = add.i64 v5, v6
  v9 = lshr.i64 v8, v2
  v10 = icmp.ult v9, v3
  br v10, b3, b5
b3:
  v11 = icmp.ult v9, v1
  br v11, b4, b1(v5, v9)
b4:
  v12 = add.i64 v9, v2
  jmp b1(v12, v6)
b5: cold
  panic "index out of bounds"
b6:
  ret v5
)",
    );
    let t = text_of(&a, "half");
    assert(!t.contains("panic"), t.as_str());
    let n = text_of(&a, "any");
    assert(n.contains("panic"), n.as_str());
    // (2 * len, key): the first index from 0 whose value is not below the key, each index its value.
    let mid: []u64 = [20, 7];
    same_result(&b, &a, "half", mid, 7);
    let past: []u64 = [20, 30];
    same_result(&b, &a, "half", past, 10);
    let wide: []u64 = [0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFF0];
    same_result(&b, &a, "half", wide, 0x7FFF_FFFF_FFFF_FFFF);
    let some: []u64 = [21, 7];
    same_result(&b, &a, "any", some, 7);
}

// `y | 1` is at least 1 (`lbound`), so its test against 0 before a division folds; `y & 1` may be 0 and
// keeps its test.
@test
fn a_value_or_a_nonzero_constant_is_no_zero_divisor() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @set fn global
sym @mask fn global
fn @set
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = or.i64 v1, v2
  v5 = icmp.eq v4, v3
  br v5, b1, b2
b1: cold
  panic "attempt to divide by zero"
b2:
  v6 = udiv.i64 v0, v4
  ret v6
fn @mask
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = and.i64 v1, v2
  v5 = icmp.eq v4, v3
  br v5, b1, b2
b1: cold
  panic "attempt to divide by zero"
b2:
  v6 = udiv.i64 v0, v4
  ret v6
)",
    );
    let t = text_of(&a, "set");
    assert(!t.contains("panic"), t.as_str());
    let m = text_of(&a, "mask");
    assert(m.contains("panic"), m.as_str());
    let even: []u64 = [12, 4];
    same_result(&b, &a, "set", even, 2);
    same_panic(&b, &a, "mask", even);
    let odd: []u64 = [12, 3];
    same_result(&b, &a, "mask", odd, 12);
}

// A header parameter whose every edge in passes a value the edge's test, or on a back edge the header's
// test, keeps below `len`, or a parameter the first is below (`i = j` after `j <u len`), stays below `len`
// (`edge_bound`), also through parameters of blocks with one edge in the walk has not forwarded yet (a
// rotated loop's first test and latch, `edge_value`): its check goes. The
// check of a sum the test does not bound (`j + k`, the test on `j`) stays, and so does one of a start of 5
// that a test of another value (`k <u len`) does not bound, and one that a second back edge passes past
// `len`.
@test
fn a_parameter_every_edge_keeps_below_a_bound_stays_below_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @trail fn global
sym @header fn global
sym @lead fn global
sym @five fn global
sym @jump fn global
sym @peeled fn global
fn @trail
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ult v1, v0
  br v3, b1(v2, v1, v2), b4(v2)
b1(v4: i64, v5: i64, v6: i64):
  v7 = icmp.uge v4, v0
  br v7, b3, b2
b2:
  v8 = add.i64 v6, v4
  v9 = add.i64 v5, v1
  v10 = icmp.ult v9, v0
  br v10, b1(v5, v9, v8), b4(v8)
b3: cold
  panic "index out of bounds"
b4(v11: i64):
  ret v11
fn @header
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ult v1, v0
  br v3, b1(v2, v1, v2), b4(v2)
b1(v4: i64, v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b4(v6)
b2:
  v8 = icmp.uge v4, v0
  br v8, b3, b5
b3: cold
  panic "index out of bounds"
b4(v9: i64):
  ret v9
b5:
  v10 = add.i64 v6, v4
  v11 = add.i64 v5, v1
  jmp b1(v5, v11, v10)
fn @lead
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ult v1, v0
  br v3, b1(v2, v1, v2), b4(v2)
b1(v4: i64, v5: i64, v6: i64):
  v7 = add.i64 v5, v1
  v8 = icmp.uge v7, v0
  br v8, b3, b2
b2:
  v9 = add.i64 v6, v4
  v10 = icmp.ult v5, v0
  br v10, b1(v5, v7, v9), b4(v9)
b3: cold
  panic "index out of bounds"
b4(v11: i64):
  ret v11
fn @five
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 5
  v3 = icmp.ult v1, v0
  br v3, b1(v2, v2), b4(v2)
b1(v4: i64, v5: i64):
  v6 = icmp.uge v4, v0
  br v6, b3, b2
b2:
  v7 = add.i64 v5, v4
  v8 = add.i64 v4, v1
  v9 = icmp.ult v8, v0
  br v9, b1(v8, v7), b4(v7)
b3: cold
  panic "index out of bounds"
b4(v10: i64):
  ret v10
fn @jump
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 4
  v4 = iconst.i64 100
  v5 = icmp.ult v1, v0
  br v5, b1(v2, v1, v2), b5(v2)
b1(v6: i64, v7: i64, v8: i64):
  v9 = icmp.ult v7, v0
  br v9, b2, b5(v8)
b2:
  v10 = icmp.uge v6, v0
  br v10, b3, b4
b3: cold
  panic "index out of bounds"
b4:
  v11 = add.i64 v8, v6
  v12 = add.i64 v7, v1
  v13 = icmp.ult v11, v3
  br v13, b1(v7, v12, v11), b6
b5(v14: i64):
  ret v14
b6:
  v15 = add.i64 v7, v4
  jmp b1(v15, v12, v11)
fn @peeled
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  jmp b1(v2, v2)
b1(v3: i64, v4: i64):
  v5 = add.i64 v3, v1
  v6 = icmp.ult v5, v0
  br v6, b2(v3, v5, v4), b6(v4)
b2(v7: i64, v8: i64, v9: i64):
  v10 = icmp.uge v7, v0
  br v10, b5, b3
b3:
  v11 = add.i64 v9, v7
  jmp b4(v8, v11)
b4(v12: i64, v13: i64):
  v14 = add.i64 v12, v1
  v15 = icmp.ult v14, v0
  br v15, b2(v12, v14, v13), b6(v13)
b5: cold
  panic "index out of bounds"
b6(v16: i64):
  ret v16
)",
    );
    for f in ["trail", "header", "peeled"] {
        let t = text_of(&a, f);
        assert(!t.contains("panic"), t.as_str());
    }
    for f in ["lead", "five", "jump"] {
        let t = text_of(&a, f);
        assert(t.contains("panic"), t.as_str());
    }
    // (len, step): the indexes 0, 3, 6.
    let three: []u64 = [9, 3];
    same_result(&b, &a, "trail", three, 3);
    let none: []u64 = [3, 3];
    same_result(&b, &a, "trail", none, 0);
    same_result(&b, &a, "header", three, 3);
    same_result(&b, &a, "header", none, 0);
    same_result(&b, &a, "peeled", three, 3);
    same_result(&b, &a, "peeled", none, 0);
    same_panic(&b, &a, "lead", three);
    let one: []u64 = [9, 1];
    same_result(&b, &a, "five", one, 31);
    let short: []u64 = [3, 1];
    same_panic(&b, &a, "five", short);
    same_result(&b, &a, "jump", three, 3);
    let far: []u64 = [20, 5];
    same_panic(&b, &a, "jump", far);
}

// A counter down by 1 under `0 <u i`, or whose every value in is nonzero (`i != 0` on each edge in), stays
// at most its start and at least 1 (`param_bounds`): `i - 1` is below a start `len`. From a value no edge
// proves nonzero (a start of 0 steps to the type's greatest value), or a start that is no length, the
// check stays. Under `i <u j` and `j <u 11`, `i` is at most 9 (`ubound`).
@test
fn a_counter_down_from_a_nonzero_start_stays_below_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @test fn global
sym @rotated fn global
sym @count fn global
sym @zero fn global
sym @wraps fn global
sym @strict fn global
sym @loose fn global
fn @test
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v0, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.ugt v3, v1
  br v5, b2, b5
b2:
  v6 = sub.i64 v3, v2
  v7 = icmp.ult v6, v0
  br v7, b3, b4
b3:
  v8 = add.i64 v4, v6
  jmp b1(v6, v8)
b4: cold
  panic "index out of bounds"
b5:
  ret v4
fn @rotated
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = icmp.ne v0, v1
  br v3, b1(v0, v1), b4(v1)
b1(v4: i64, v5: i64):
  v6 = sub.i64 v4, v2
  v7 = icmp.ult v6, v0
  br v7, b2, b3
b2:
  v8 = add.i64 v5, v6
  v9 = icmp.ne v6, v1
  br v9, b1(v6, v8), b4(v8)
b3: cold
  panic "index out of bounds"
b4(v10: i64):
  ret v10
fn @count
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v1, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.ugt v4, v2
  br v6, b2, b5
b2:
  v7 = sub.i64 v4, v3
  v8 = icmp.ult v7, v0
  br v8, b3, b4
b3:
  v9 = add.i64 v5, v7
  jmp b1(v7, v9)
b4: cold
  panic "index out of bounds"
b5:
  ret v5
fn @zero
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v1, v2)
b1(v4: i64, v5: i64):
  v6 = sub.i64 v4, v3
  v7 = icmp.ult v6, v0
  br v7, b2, b3
b2:
  v8 = add.i64 v5, v6
  v9 = icmp.ne v6, v2
  br v9, b1(v6, v8), b4(v8)
b3: cold
  panic "index out of bounds"
b4(v10: i64):
  ret v10
fn @wraps
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.eq v0, v2
  br v4, b6, b1
b1:
  v5 = sub.i64 v0, v3
  jmp b2(v5, v2)
b2(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b3, b4
b3:
  v9 = add.i64 v7, v6
  v10 = sub.i64 v6, v3
  v11 = icmp.ult v9, v1
  br v11, b2(v10, v9), b5(v9)
b4: cold
  panic "index out of bounds"
b5(v12: i64):
  ret v12
b6:
  ret v2
fn @strict
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 11
  v3 = iconst.i64 10
  v4 = icmp.ult v1, v2
  v5 = icmp.ult v0, v1
  v6 = and.i8 v4, v5
  br v6, b1, b3
b1:
  v7 = icmp.ult v0, v3
  br v7, b2, b4
b2:
  ret v0
b3:
  ret v3
b4: cold
  panic "index out of bounds"
fn @loose
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 12
  v3 = iconst.i64 10
  v4 = icmp.ult v1, v2
  v5 = icmp.ult v0, v1
  v6 = and.i8 v4, v5
  br v6, b1, b3
b1:
  v7 = icmp.ult v0, v3
  br v7, b2, b4
b2:
  ret v0
b3:
  ret v3
b4: cold
  panic "index out of bounds"
)",
    );
    for f in ["test", "rotated", "strict"] {
        let t = text_of(&a, f);
        assert(!t.contains("panic"), t.as_str());
    }
    for f in ["count", "zero", "wraps", "loose"] {
        let t = text_of(&a, f);
        assert(t.contains("panic"), t.as_str());
    }
    let five: []u64 = [5];
    same_result(&b, &a, "test", five, 10);
    same_result(&b, &a, "rotated", five, 10);
    let none: []u64 = [0];
    same_result(&b, &a, "test", none, 0);
    same_result(&b, &a, "rotated", none, 0);
    let within: []u64 = [5, 4];
    same_result(&b, &a, "count", within, 6);
    let past: []u64 = [5, 6];
    same_panic(&b, &a, "count", past);
    same_result(&b, &a, "zero", within, 6);
    let start: []u64 = [5, 0];
    same_panic(&b, &a, "zero", start);
    let three: []u64 = [3, 2];
    same_result(&b, &a, "wraps", three, 2);
    let below: []u64 = [3, 100];
    same_panic(&b, &a, "wraps", below);
    let top: []u64 = [9, 10];
    same_result(&b, &a, "strict", top, 9);
    let over: []u64 = [10, 11];
    same_panic(&b, &a, "loose", over);
    same_result(&b, &a, "loose", top, 9);
}

// A row's element `y * w + x` of rows `y <u h` and columns `x <u w` is below a `len` of at least `w * h`
// where that product wraps nowhere: of two 32-bit counts (`ubound`), or a checked product whose flag the
// entry tests (`product_le`). A product that may wrap keeps the check.
@test
fn a_row_element_stays_below_a_product_that_does_not_wrap() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @narrow fn global
sym @checked fn global
sym @wraps fn global
fn @narrow
  sig (i64, i32, i32) -> i64
b0(v0: i64, v1: i32, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = zext.i64 v1
  v6 = zext.i64 v2
  v7 = mul.i64 v5, v6
  v8 = icmp.ugt v7, v0
  br v8, b9, b1
b1:
  jmp b2(v3, v3)
b2(v9: i64, v10: i64):
  v11 = icmp.ult v9, v6
  br v11, b3, b8
b3:
  v12 = mul.i64 v9, v5
  jmp b4(v3, v10)
b4(v13: i64, v14: i64):
  v15 = icmp.ult v13, v5
  br v15, b5, b7
b5:
  v16 = add.i64 v12, v13
  v17 = icmp.ult v16, v0
  br v17, b6, b10
b6:
  v18 = add.i64 v14, v16
  v19 = add.i64 v13, v4
  jmp b4(v19, v18)
b7:
  v20 = add.i64 v9, v4
  jmp b2(v20, v14)
b8:
  ret v10
b9:
  ret v3
b10: cold
  panic "index out of bounds"
fn @checked
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5, v6 = mulo.u.i64 v1, v2
  v7 = icmp.ugt v5, v0
  v8 = or.i8 v6, v7
  br v8, b9, b1
b1:
  jmp b2(v3, v3)
b2(v9: i64, v10: i64):
  v11 = icmp.ult v9, v2
  br v11, b3, b8
b3:
  v12 = mul.i64 v1, v9
  jmp b4(v3, v10)
b4(v13: i64, v14: i64):
  v15 = icmp.ult v13, v1
  br v15, b5, b7
b5:
  v16 = add.i64 v13, v12
  v17 = icmp.ult v16, v0
  br v17, b6, b10
b6:
  v18 = add.i64 v14, v16
  v19 = add.i64 v13, v4
  jmp b4(v19, v18)
b7:
  v20 = add.i64 v9, v4
  jmp b2(v20, v14)
b8:
  ret v10
b9:
  ret v3
b10: cold
  panic "index out of bounds"
fn @wraps
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = mul.i64 v1, v2
  v6 = icmp.ugt v5, v0
  br v6, b9, b1
b1:
  jmp b2(v3, v3)
b2(v7: i64, v8: i64):
  v9 = icmp.ult v7, v2
  br v9, b3, b8
b3:
  v10 = mul.i64 v7, v1
  jmp b4(v3, v8)
b4(v11: i64, v12: i64):
  v13 = icmp.ult v11, v1
  br v13, b5, b7
b5:
  v14 = add.i64 v10, v11
  v15 = icmp.ult v14, v0
  br v15, b6, b10
b6:
  v16 = add.i64 v12, v14
  v17 = add.i64 v11, v4
  jmp b4(v17, v16)
b7:
  v18 = add.i64 v7, v4
  jmp b2(v18, v12)
b8:
  ret v8
b9:
  ret v3
b10: cold
  panic "index out of bounds"
)",
    );
    for f in ["narrow", "checked"] {
        let t = text_of(&a, f);
        assert(!t.contains("panic"), t.as_str());
    }
    let w = text_of(&a, "wraps");
    assert(w.contains("panic"), w.as_str());
    // (len, w, h): sum of the indexes 0 to w * h - 1.
    let fits: []u64 = [12, 4, 3];
    same_result(&b, &a, "narrow", fits, 66);
    same_result(&b, &a, "checked", fits, 66);
    same_result(&b, &a, "wraps", fits, 66);
    let over: []u64 = [11, 4, 3];
    same_result(&b, &a, "narrow", over, 0);
    same_result(&b, &a, "checked", over, 0);
    let wide: []u64 = [5, 0x8000000000000000, 2];
    same_result(&b, &a, "checked", wide, 0);
    same_panic(&b, &a, "wraps", wide);
}

// A counter from 1 by 1 under `i <u n` stays at least 1 (`param_bounds`), so `i - 1` is below `i`, below `n`
// (`at_most_of`); from a value `c`, `i - c` does not wrap. From 0 the first `i - 1` wraps: its check stays.
// Both comparisons of an `or` that fails fail (`cond_parts`).
@test
fn a_counter_less_its_start_stays_below_the_bound() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @prev fn global
sym @from fn global
sym @zero fn global
sym @orv fn global
fn @prev
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 0
  jmp b1(v1, v2)
b1(v3: i64, v4: i64):
  v5 = icmp.ult v3, v0
  br v5, b2, b4
b2:
  v6 = sub.i64 v3, v1
  v7 = icmp.ult v6, v0
  br v7, b3, b5
b3:
  v8 = add.i64 v4, v6
  v9 = add.i64 v3, v1
  jmp b1(v9, v8)
b4:
  ret v4
b5: cold
  panic "index out of bounds"
fn @from
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  jmp b1(v1, v3)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v0
  br v6, b2, b4
b2:
  v7 = sub.i64 v4, v1
  v8 = icmp.ult v7, v0
  br v8, b3, b5
b3:
  v9 = add.i64 v5, v7
  v10 = add.i64 v4, v2
  jmp b1(v10, v9)
b4:
  ret v5
b5: cold
  panic "index out of bounds"
fn @zero
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 0
  jmp b1(v2, v2)
b1(v3: i64, v4: i64):
  v5 = icmp.ult v3, v0
  br v5, b2, b4
b2:
  v6 = sub.i64 v3, v1
  v7 = icmp.ult v6, v0
  br v7, b3, b5
b3:
  v8 = add.i64 v4, v3
  v9 = add.i64 v3, v1
  jmp b1(v9, v8)
b4:
  ret v4
b5: cold
  panic "index out of bounds"
fn @orv
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = icmp.ne v1, v0
  v6 = icmp.ugt v0, v2
  v7 = or.i8 v5, v6
  br v7, b6, b1(v3, v3)
b1(v8: i64, v9: i64):
  v10 = icmp.ult v8, v0
  br v10, b2, b5
b2:
  v11 = icmp.ult v8, v1
  br v11, b3, b7
b3:
  v12 = icmp.ult v8, v2
  br v12, b4, b7
b4:
  v13 = add.i64 v9, v8
  v14 = add.i64 v8, v4
  jmp b1(v14, v13)
b5:
  ret v9
b6:
  ret v3
b7: cold
  panic "index out of bounds"
)",
    );
    for name in ["prev", "from", "orv"] {
        let t = text_of(&a, name);
        assert(!t.contains("panic"), t.as_str());
    }
    let z = text_of(&a, "zero");
    assert(z.contains("panic"), z.as_str());
    let five: []u64 = [5];
    same_result(&b, &a, "prev", five, 6);
    let fr: []u64 = [6, 2];
    same_result(&b, &a, "from", fr, 6);
    same_panic(&b, &a, "zero", five);
    let fits: []u64 = [4, 4, 9];
    same_result(&b, &a, "orv", fits, 6);
    let unequal: []u64 = [5, 4, 9];
    same_result(&b, &a, "orv", unequal, 0);
    let over: []u64 = [5, 5, 4];
    same_result(&b, &a, "orv", over, 0);
}

// Windows and chunks: a test `i + 3 <=u n` of a counter from 0 by 1, `n` at most `max - 1`, is `i <u n - 2`
// (`offset_test`), and its checked sum wraps nowhere (its flag 0); the window's length `(i + 3) - i` is 3
// (`cancel`, also from a start that is no constant, whose checked sum stays). A chunk `(k << 2) + 4` stays
// at most `n` where `k <u n >> 2` holds; `+ 5` does not. A checked sum of bounded operands is a plain one
// (`checked_range`). A sum
// `i + 1` stays below `n` where `i <u n - 1` and `n >=u 1` hold.
@test
fn window_and_chunk_ends_stay_within_the_length() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @win fn global
sym @ck fn global
sym @from fn global
fn @ck
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 255
  v2 = iconst.i64 1000
  v3 = and.i64 v0, v1
  v4, v5 = addo.u.i64 v3, v2
  br v5, b1, b2
b1:
  panic "attempt to add with overflow"
b2:
  ret v4
sym @chunk fn global
sym @over fn global
sym @next fn global
fn @from
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 3
  v4 = iconst.i64 1
  jmp b1(v1, v2)
b1(v5: i64, v6: i64):
  v7, v8 = addo.u.i64 v5, v3
  v9 = icmp.ule v7, v0
  br v9, b2, b4
b2:
  br v8, b5, b3
b3:
  v10 = sub.i64 v7, v5
  v11 = icmp.ule v10, v4
  br v11, b5, b6
b4:
  ret v6
b5: cold
  panic "index out of bounds"
b6:
  v12 = add.i64 v6, v5
  v13 = add.i64 v5, v4
  jmp b1(v13, v12)
fn @win
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 3
  v3 = iconst.i64 1
  v4 = iconst.i64 1000
  v5 = icmp.ugt v0, v4
  br v5, b5, b1
b1:
  jmp b2(v1, v1)
b2(v6: i64, v7: i64):
  v8, v9 = addo.u.i64 v6, v2
  v10 = icmp.ule v8, v0
  br v10, b3, b6
b3:
  br v9, b7, b4
b4:
  v11 = sub.i64 v8, v6
  v12 = icmp.ule v11, v3
  br v12, b7, b8
b5:
  ret v1
b6:
  ret v7
b7: cold
  panic "index out of bounds"
b8:
  v13 = add.i64 v7, v6
  v14 = add.i64 v6, v3
  jmp b2(v14, v13)
fn @chunk
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 2
  v3 = iconst.i64 4
  v4 = iconst.i64 1
  v5 = lshr.i64 v0, v2
  jmp b1(v1, v1)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v5
  br v8, b2, b4
b2:
  v9 = shl.i64 v6, v2
  v10 = add.i64 v9, v3
  v11 = icmp.ugt v10, v0
  br v11, b5, b3
b3:
  v12 = add.i64 v7, v10
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b4:
  ret v7
b5: cold
  panic "index out of bounds"
fn @over
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 2
  v3 = iconst.i64 5
  v4 = iconst.i64 1
  v5 = lshr.i64 v0, v2
  jmp b1(v1, v1)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v5
  br v8, b2, b4
b2:
  v9 = shl.i64 v6, v2
  v10 = add.i64 v9, v3
  v11 = icmp.ugt v10, v0
  br v11, b5, b3
b3:
  v12 = add.i64 v7, v10
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b4:
  ret v7
b5: cold
  panic "index out of bounds"
fn @next
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = icmp.eq v0, v1
  br v3, b5, b1
b1:
  v4 = sub.i64 v0, v2
  jmp b2(v1, v1)
b2(v5: i64, v6: i64):
  v7 = icmp.ult v5, v4
  br v7, b3, b6
b3:
  v8 = add.i64 v5, v2
  v9 = icmp.ult v8, v0
  br v9, b4, b7
b4:
  v10 = add.i64 v6, v8
  jmp b2(v8, v10)
b5:
  ret v1
b6:
  ret v6
b7: cold
  panic "index out of bounds"
)",
    );
    for name in ["win", "chunk", "next", "ck"] {
        let t = text_of(&a, name);
        assert(!t.contains("panic") && !t.contains("addo"), t.as_str());
    }
    let o = text_of(&a, "over");
    assert(o.contains("panic"), o.as_str());
    let f = text_of(&a, "from");
    assert(f.contains("addo") && !f.contains("sub.i64"), f.as_str());
    let big: []u64 = [0xFFFFFFFFFFFFFFFF];
    same_result(&b, &a, "ck", big, 1255);
    let fr: []u64 = [10, 4];
    same_result(&b, &a, "from", fr, 4 + 5 + 6 + 7);
    for n in [0u64, 1, 2, 3, 4, 9, 17] {
        let x: [u64; 1] = [n];
        let w = if n < 3 {
            0u64
        } else {
            (n - 3) * (n - 2) / 2
        };
        same_result(&b, &a, "win", x[0..1], w);
        let mut c: u64 = 0;
        for k in 0..n / 4 {
            c += 4 * k + 4;
        }
        same_result(&b, &a, "chunk", x[0..1], c);
        let nx = if n == 0 {
            0u64
        } else {
            n * (n - 1) / 2
        };
        same_result(&b, &a, "next", x[0..1], nx);
    }
    let eight: []u64 = [8];
    same_panic(&b, &a, "over", eight);
}

// Jump threading: a `&&` of comparisons stays a diamond, which becomes an `and` and a select (threading its
// sides apart would leave branches); an `Option` tag a side fixes skips its test (a small join of pure
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
    assert(!t.contains(": i8)") && count_of(&t, "br ") == 0 && t.contains("and.i8"), t.as_str());
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
// than the type for 7; of 32 bits, the 64-bit product shifted once); a flag picked as 1 or 0 is the flag, as 0 or 1 or negated the opposite
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
    assert(
        !d.contains("udiv") && !d.contains("urem") && count_of(&d, "mulhu") == 3 && d.contains("iconst.i64 38"),
        d.as_str(),
    );
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

// A quotient or remainder by a constant is a high product (`mulhu`; signed, `mulhs` by the multiplier of
// the divisor's magnitude, plus the dividend where that multiplier is negative) or, signed by a power of
// two, shifts: the division's result for every divisor and dividend of 8 bits, and of 16, 32 and 64 bits
// for the divisors next to each power of two, the extremes and others, on the dividends at the edges and
// next to the divisor's multiples there. By 0, and signed by -1, it stays a division.
@test
fn quotients_by_constants_give_the_division() {
    let ops: [str; 4] = ["sdiv", "srem", "udiv", "urem"];
    let mut src = String::from_str("lir ptr 8\n");
    let mut body = String::new();
    // Per function: the operation << 8 | the width, and the divisor sign-extended.
    let mut kind = Vector::<u32>::new();
    let mut divs = Vector::<i64>::new();
    for wi in 0..4u32 {
        let w = 8u32 << wi;
        let mut ds = Vector::<i64>::new();
        if w == 8 {
            for d in -128..128i64 {
                ds.push(d);
            }
        } else {
            // Next to each power of two (the multiplier's width and the correction change there); the powers
            // themselves at a few exponents.
            for k in 2..w - 1 {
                let p = 1i64 << k as i64;
                let near: [i64; 3] = [p - 1, p + 1, -p - 1];
                for q in 0..3usize {
                    ds.push(unsafe near[q]);
                }
            }
            let pw: [i64; 5] = [2, 4, 1i64 << (w / 2) as i64, 1i64 << (w - 2) as i64, -(1i64 << (w - 2) as i64)];
            for q in 0..5usize {
                ds.push(unsafe pw[q]);
            }
            let more: [i64; 7] = [3, 6, 7, 10, 100, 641, 1000];
            for q in 0..7usize {
                ds.push(unsafe more[q]);
                ds.push(-unsafe more[q]);
            }
            ds.push(wmin(w));
            ds.push(wmin(w) + 1);
            ds.push(wmax(w));
            ds.push(wmax(w) - 1);
        }
        for op in 0..4u32 {
            for q in 0..ds.len() {
                let d = ds[q];
                if d == 0 || op < 2 && d == -1 {
                    continue;
                }
                let n = kind.len();
                src.push_str(format("sym @d{} fn global\n", n).as_str());
                body.push_str(
                    format(
                        "fn @d{}\n  sig (i{}) -> i{}\nb0(v0: i{}):\n  v1 = iconst.i{} {}\n  v2 = {}.i{} v0, v1\n  ret v2\n",
                        n,
                        w,
                        w,
                        w,
                        w,
                        d,
                        unsafe ops[op as usize],
                        w,
                    ).as_str(),
                );
                kind.push(op << 8 | w);
                divs.push(d);
            }
        }
    }
    // The two that stay divisions.
    src.push_str("sym @zero fn global\nsym @minus fn global\n");
    body.push_str("fn @zero\n  sig (i32) -> i32\nb0(v0: i32):\n  v1 = iconst.i32 0\n  v2 = udiv.i32 v0, v1\n  ret v2\n");
    body.push_str(
        "fn @minus\n  sig (i64) -> i64\nb0(v0: i64):\n  v1 = iconst.i64 -1\n  v2 = sdiv.i64 v0, v1\n  ret v2\n",
    );
    src.push_str(&body);
    let (_, a) = optimized(&src);
    assert(text_of(&a, "zero").contains("udiv") && text_of(&a, "minus").contains("sdiv"), "0 and -1 stay");
    // Those two alone divide.
    let mut all = String::new();
    lprint::print_package(&a, &mut all);
    let n = count_of(&all, "div.") + count_of(&all, "rem.");
    assert(n == 2, all.as_str());
    let mut e = leval::Eval::new(&a);
    let mut xs = Vector::<i64>::new();
    let mut args: [u64; 1] = [0];
    for f in 0..kind.len() {
        let w = kind[f] & 0xFF;
        let op = kind[f] >> 8;
        let d = divs[f];
        let name = format("d{}", f);
        // The dividends: every one of 8 bits; else the edges, and those next to the multiples of the divisor
        // nearest them.
        xs.truncate(0);
        let lo = wmin(w);
        let hi = wmax(w);
        if w == 8 {
            for x in -128..128i64 {
                xs.push(x);
            }
        }
        let edges: [i64; 9] = [0, 1, 2, 3, -1, -2, lo, lo + 1, hi];
        for q in 0..pick(w == 8, 0usize, 9usize) {
            xs.push(unsafe edges[q]);
        }
        let ad = if d < 0 && d != lo {
            -d
        } else {
            d
        };
        if ad > 0 && w != 8 {
            let m = hi - hi % ad;
            let near: [i64; 5] = [m - 1, m, -m - 1, -m, -m + 1];
            for q in 0..5usize {
                xs.push(unsafe near[q]);
            }
            if m < hi {
                xs.push(m + 1);
            }
        }
        let mask = if w == 64 {
            ~0u64
        } else {
            (1u64 << w as u64) - 1
        };
        for q in 0..xs.len() {
            let x = xs[q];
            // The evaluator's values are their bits under the width.
            args[0] = x as u64 & mask;
            let o = e.run(a.find_symbol(&name), args);
            assert(o.kind == leval::EV_OK, o.msg.as_str());
            let want = divided(op, x, d, mask);
            if ((o.value ^ want) & mask) != 0 {
                eprint(
                    "{} {} by {} at {} bits: {} for {}\n",
                    unsafe ops[op as usize],
                    x,
                    d,
                    w,
                    o.value & mask,
                    want & mask,
                );
                assert(false, text_of(&a, &name).as_str());
            }
        }
    }
}

// Without a one-instruction high product (`Package.mul_high` off: wasm32, whose engines divide by a
// constant themselves) a scalar quotient or remainder by a constant stays a division, a signed one by a
// power of two too.
@test
fn quotients_by_constants_stay_without_a_high_product() {
    let src = M"(lir ptr 8
sym @q fn global
fn @q
  sig (i32, i64) -> i64
b0(v0: i32, v1: i64):
  v2 = iconst.i32 4
  v3 = sdiv.i32 v0, v2
  v4 = iconst.i64 7
  v5 = urem.i64 v1, v4
  v6 = sext.i64 v3
  v7 = add.i64 v5, v6
  ret v7
)";
    let mut err = String::new();
    let mut p = lparse::parse(src, &mut err).unwrap();
    p.mul_high = false;
    let none = Vector::<bool>::new();
    let bu = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 0,
        interleave: 0,
        fin: 0,
    };
    lopt::optimize(&mut p, &none, lopt::Config { inline: il::SPEED, loops: bu });
    let tq = text_of(&p, "q");
    assert(tq.contains("sdiv.i32") && tq.contains("urem.i64") && !tq.contains("mulh"), tq.as_str());
    let b = lparse::parse(src, &mut err).unwrap();
    let xs: [i64; 4] = [-9, 13, 1000003, -2147483648];
    for k in 0..4usize {
        let x = unsafe xs[k];
        let args: [u64; 2] = [x as u64 & 0xFFFFFFFF, x as u64];
        let want = (x as u64 % 7).wrapping_add(((x as i32 / 4) as i64) as u64);
        same_result(&b, &p, "q", args, want);
    }
}

// Operation `op` of `quotients_by_constants_give_the_division` (`sdiv`, `srem`, `udiv`, `urem`) of `x` by
// `d`, both sign-extended; unsigned, their bits under `mask`.
const fn divided(op: u32, x: i64, d: i64, mask: u64) u64 {
    if op == 0 {
        return (x / d) as u64;
    }
    if op == 1 {
        return (x % d) as u64;
    }
    let ux = x as u64 & mask;
    let ud = d as u64 & mask;
    return if op == 2 {
        ux / ud
    } else {
        ux % ud
    };
}

// The least value of `w` signed bits.
const fn wmin(w: u32) i64 {
    return i64::MIN >> (64 - w) as i64;
}

// The greatest value of `w` signed bits.
const fn wmax(w: u32) i64 {
    return i64::MAX >> (64 - w) as i64;
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

// A by-value view parameter the body does not rebind (`ref inner`) keeps its own words, the element
// pointer and the length, for the whole call: an inlined length getter (an exclusive `self`, whose copy
// reads the view through its entry parameter) after a store of an element of the length's type reads
// the length the first copy read, for an exclusive view and for a read-only one. The referent of a plain
// reference parameter has no such promise: its second load stays.
@test
fn a_view_parameter_keeps_its_length_across_element_stores() {
    let (_, a) = optimized(
        M"(lir ptr 8
file f0 "view.spc"
sym @len fn global
sym @put fn global
sym @get fn global
sym @plain fn global
fn @len
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3 tbaa 4
  ret v1
fn @put
  file f0
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i64) -> i64
  ref p0 8 inner noalias
b0(v0: ptr, v1: i64):
  v2 = call.i64 @len(v0) : (ptr) -> i64 !3:5
  v3 = load.ptr v0 align 3 tbaa 8
  store v1, v3 align 3 tbaa 4
  v4 = call.i64 @len(v0) : (ptr) -> i64 !4:5
  v5 = load.ptr v0 align 3 tbaa 8
  store v1, v5+8 align 3 tbaa 4
  v6 = add.i64 v2, v4
  ret v6
fn @get
  file f0
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, ptr) -> i64
  ref p0 8 inner readonly
b0(v0: ptr, v1: ptr):
  v2 = call.i64 @len(v0) : (ptr) -> i64 !7:5
  v3 = iconst.i64 7
  store v3, v1 align 3 tbaa 4
  v4 = call.i64 @len(v0) : (ptr) -> i64 !8:5
  v5 = add.i64 v2, v4
  ret v5
fn @plain
  file f0
  sig (ptr, ptr) -> i64
  ref p0 16
b0(v0: ptr, v1: ptr):
  v2 = call.i64 @len(v0) : (ptr) -> i64 !11:5
  v3 = iconst.i64 7
  store v3, v1 align 3 tbaa 4
  v4 = call.i64 @len(v0) : (ptr) -> i64 !12:5
  v5 = add.i64 v2, v4
  ret v5
)",
    );
    let names: []str = ["put", "get"];
    for k in 0..names.len() {
        let t = text_of(&a, names[k]);
        assert(!t.contains("call") && count_of(&t, "load.i64 v0+8") == 1, t.as_str());
    }
    let p = text_of(&a, "plain");
    assert(!p.contains("call") && count_of(&p, "load.i64 v0+8") == 2, p.as_str());
}

// An unsigned comparison of a value with one its form keeps at most it is decided: a slice's half
// (`len >> 1`, `len / 2`), its length rounded down (`len & -16`), a remainder, and a minimum with it are
// at most the length, so the range check `hi >u len` of `s[..hi]` folds. A strict order (`x >> 1 <u x`,
// false at 0) and a sum (`x + 1`, which wraps) stay.
@test
fn a_value_at_most_another_by_its_form_decides_their_order() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @forms fn global
sym @kept fn global
fn @forms
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = iconst.i64 -16
  v5 = lshr.i64 v0, v2
  v6 = icmp.ugt v5, v0
  v7 = udiv.i64 v0, v3
  v8 = icmp.ult v0, v7
  v9 = and.i64 v0, v4
  v10 = icmp.ule v9, v0
  v11 = urem.i64 v1, v3
  v12 = and.i64 v11, v0
  v13 = lshr.i64 v12, v2
  v14 = icmp.uge v0, v13
  v15 = icmp.ult v0, v1
  v16 = select.i64 v15, v0, v1
  v17 = icmp.ugt v16, v1
  v18 = zext.i64 v6
  v19 = zext.i64 v8
  v20 = zext.i64 v10
  v21 = zext.i64 v14
  v22 = zext.i64 v17
  v23 = add.i64 v18, v19
  v24 = shl.i64 v20, v2
  v25 = shl.i64 v21, v3
  v26 = add.i64 v23, v24
  v27 = add.i64 v26, v25
  v28 = add.i64 v27, v22
  ret v28
fn @kept
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = lshr.i64 v0, v1
  v3 = icmp.ult v2, v0
  v4 = add.i64 v0, v1
  v5 = icmp.ule v4, v0
  v6 = zext.i64 v3
  v7 = zext.i64 v5
  v8 = shl.i64 v7, v1
  v9 = add.i64 v6, v8
  ret v9
)",
    );
    let f = text_of(&a, "forms");
    assert(!f.contains("icmp"), f.as_str());
    let k = text_of(&a, "kept");
    assert(count_of(&k, "icmp") == 2, k.as_str());
    let xs: []u64 = [0, 1, 7, 0xFFFFFFFFFFFFFFFF];
    for q in 0..xs.len() {
        let x: []u64 = [xs[q], 5];
        same_result(&b, &a, "forms", x, 2 + 4);
    }
    let z: []u64 = [7];
    same_result(&b, &a, "kept", z, 1);
    let m: []u64 = [0xFFFFFFFFFFFFFFFF];
    same_result(&b, &a, "kept", m, 1 + 2);
}

// Where `i <u n` and `j <u n` hold, `abs_diff` (a select of the two differences its condition keeps
// from wrapping), `midpoint` (`(i & j) + ((i ^ j) >> 1)`) and `saturating_sub(1)` of them are below `n`:
// their tests fold (`max_parts`). The differences the wrong way round wrap, and their test stays.
@test
fn a_difference_or_midpoint_of_indices_below_a_length_is_below_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @parts fn global
sym @wrong fn global
sym @merged fn global
fn @parts
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = icmp.ult v0, v2
  br v6, b1, b6
b1:
  v7 = icmp.ult v1, v2
  br v7, b2, b6
b2:
  v8 = icmp.ult v0, v1
  v9 = sub.i64 v1, v0
  v10 = sub.i64 v0, v1
  v11 = select.i64 v8, v9, v10
  v12 = icmp.uge v11, v2
  br v12, b7, b3
b3:
  v13 = and.i64 v0, v1
  v14 = xor.i64 v0, v1
  v15 = lshr.i64 v14, v4
  v16 = add.i64 v13, v15
  v17 = icmp.uge v16, v2
  br v17, b7, b4
b4:
  v18 = icmp.ult v0, v4
  v19 = sub.i64 v0, v4
  v20 = select.i64 v18, v3, v19
  v21 = icmp.uge v20, v2
  br v21, b7, b5
b5:
  v22 = add.i64 v11, v16
  v23 = add.i64 v22, v20
  ret v23
b6:
  ret v3
b7: cold
  ret v5
fn @wrong
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 99
  v5 = icmp.ult v0, v2
  br v5, b1, b3
b1:
  v6 = icmp.ult v1, v2
  br v6, b2, b3
b2:
  v7 = icmp.ult v0, v1
  v8 = sub.i64 v0, v1
  v9 = sub.i64 v1, v0
  v10 = select.i64 v7, v8, v9
  v11 = icmp.uge v10, v2
  br v11, b4, b5
b3:
  ret v3
b4: cold
  ret v4
b5:
  ret v10
fn @merged
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 99
  v5 = icmp.ult v0, v1
  v6 = select.i64 v5, v1, v0
  v7 = icmp.ugt v2, v6
  br v7, b1, b2
b1:
  v8 = sub.i64 v1, v0
  v9 = sub.i64 v0, v1
  v10 = select.i64 v5, v8, v9
  v11 = icmp.uge v10, v2
  br v11, b3, b4
b2:
  ret v3
b3: cold
  ret v4
b4:
  ret v10
)",
    );
    // The three tests into `b7` go: no path returns 99. A maximum below `n` keeps both its values below
    // `n` (`i <u n && j <u n` merged into one test).
    let p = text_of(&a, "parts");
    assert(!p.contains("99"), p.as_str());
    let m = text_of(&a, "merged");
    assert(!m.contains("99"), m.as_str());
    let mx: []u64 = [7, 2, 8];
    same_result(&b, &a, "merged", mx, 5);
    let w = text_of(&a, "wrong");
    assert(w.contains("99"), w.as_str());
    let x: []u64 = [1, 3, 10];
    same_result(&b, &a, "parts", x, 2 + 2 + 0);
    let y: []u64 = [0, 0, 1];
    same_result(&b, &a, "parts", y, 0);
    let z: []u64 = [9, 2, 10];
    same_result(&b, &a, "parts", z, 7 + 5 + 8);
    same_result(&b, &a, "wrong", x, 99);
    let e: []u64 = [2, 2, 3];
    same_result(&b, &a, "wrong", e, 0);
}

// A value below `n >> 1` (or `n / 2`) is below `n - (n >> 1)`: the right half of `split_at(n / 2)` is no
// shorter than the left, so its test folds (`half_of`). The half rounded up, `(n + 1) >> 1`, can pass
// the rest, and its test stays.
@test
fn a_value_below_a_half_is_below_the_rest() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @halves fn global
sym @rounded fn global
fn @halves
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = iconst.i64 99
  v5 = iconst.i64 0
  v6 = lshr.i64 v0, v2
  v7 = sub.i64 v0, v6
  v8 = udiv.i64 v0, v3
  v9 = sub.i64 v0, v8
  v10 = icmp.ult v1, v6
  br v10, b1, b4
b1:
  v11 = icmp.uge v1, v7
  br v11, b3, b2
b2:
  v12 = icmp.ult v1, v9
  br v12, b5, b3
b3: cold
  ret v4
b4:
  ret v5
b5:
  ret v1
fn @rounded
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = add.i64 v0, v2
  v6 = lshr.i64 v5, v2
  v7 = sub.i64 v0, v6
  v8 = icmp.ult v1, v6
  br v8, b1, b3
b1:
  v9 = icmp.uge v1, v7
  br v9, b2, b4
b2: cold
  ret v3
b3:
  ret v4
b4:
  ret v1
)",
    );
    let h = text_of(&a, "halves");
    assert(!h.contains("99"), h.as_str());
    let r = text_of(&a, "rounded");
    assert(r.contains("99"), r.as_str());
    let x: []u64 = [9, 3];
    same_result(&b, &a, "halves", x, 3);
    let y: []u64 = [9, 4];
    same_result(&b, &a, "halves", y, 0);
    same_result(&b, &a, "rounded", y, 99);
    same_result(&b, &a, "rounded", x, 3);
}

// `(n - 1) - i <u n` where `i <u n >> 1` holds: `i` is at most `n - 1`, so neither difference wraps (the
// mirror of a swap loop's counter, `below_within`). `(n - 2) - i` wraps at `i = n - 1`, and its test
// stays.
@test
fn the_mirror_of_an_index_below_a_length_is_below_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @mirror fn global
sym @skewed fn global
fn @mirror
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = lshr.i64 v0, v2
  v6 = icmp.ult v1, v5
  br v6, b1, b3
b1:
  v7 = sub.i64 v0, v2
  v8 = sub.i64 v7, v1
  v9 = icmp.uge v8, v0
  br v9, b2, b4
b2: cold
  ret v3
b3:
  ret v4
b4:
  ret v8
fn @skewed
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 2
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = icmp.ult v1, v0
  br v5, b1, b3
b1:
  v6 = sub.i64 v0, v2
  v7 = sub.i64 v6, v1
  v8 = icmp.uge v7, v0
  br v8, b2, b4
b2: cold
  ret v3
b3:
  ret v4
b4:
  ret v7
)",
    );
    let m = text_of(&a, "mirror");
    assert(!m.contains("99"), m.as_str());
    let s = text_of(&a, "skewed");
    assert(s.contains("99"), s.as_str());
    let x: []u64 = [9, 3];
    same_result(&b, &a, "mirror", x, 5);
    same_result(&b, &a, "skewed", x, 4);
    let e: []u64 = [9, 8];
    same_result(&b, &a, "skewed", e, 99);
}

// Two counters `while i < j { .. i += 1; j -= 1 }`: every edge into the loop passes a `j` above an `i`, so
// `j` is nonzero, its step does not wrap, and it stays at most its start (`nonzero_on`): below the length
// the start is below, or the constant start's bound (`param_bounds`). Under `i <=u j` the step wraps at 0,
// and the test stays.
@test
fn a_counter_down_above_another_stays_at_most_its_start() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @rev fn global
sym @rev200 fn global
sym @rev_le fn global
fn @rev
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 99
  v5 = icmp.ult v2, v0
  br v5, b1, b5(v3)
b1:
  v6 = icmp.ult v1, v2
  br v6, b2(v1, v2), b5(v3)
b2(v7: i64, v8: i64):
  v9 = icmp.uge v8, v0
  br v9, b4, b3
b3:
  v10 = add.i64 v7, v3
  v11 = sub.i64 v8, v3
  v12 = icmp.ult v10, v11
  br v12, b2(v10, v11), b5(v11)
b4: cold
  ret v4
b5(v13: i64):
  ret v13
fn @rev200
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 99
  v4 = iconst.i64 200
  v5 = icmp.ugt v0, v4
  br v5, b1, b5(v2)
b1:
  v6 = icmp.ult v1, v4
  br v6, b2(v1, v4), b5(v2)
b2(v7: i64, v8: i64):
  v9 = icmp.uge v8, v0
  br v9, b4, b3
b3:
  v10 = add.i64 v7, v2
  v11 = sub.i64 v8, v2
  v12 = icmp.ult v10, v11
  br v12, b2(v10, v11), b5(v11)
b4: cold
  ret v3
b5(v13: i64):
  ret v13
fn @rev_le
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 99
  v5 = icmp.ult v2, v0
  br v5, b1, b5(v3)
b1:
  v6 = icmp.ule v1, v2
  br v6, b2(v1, v2), b5(v3)
b2(v7: i64, v8: i64):
  v9 = icmp.uge v8, v0
  br v9, b4, b3
b3:
  v10 = add.i64 v7, v3
  v11 = sub.i64 v8, v3
  v12 = icmp.ule v10, v11
  br v12, b2(v10, v11), b5(v11)
b4: cold
  ret v4
b5(v13: i64):
  ret v13
)",
    );
    let r = text_of(&a, "rev");
    assert(!r.contains("99"), r.as_str());
    let c = text_of(&a, "rev200");
    assert(!c.contains("99"), c.as_str());
    let l = text_of(&a, "rev_le");
    assert(l.contains("99"), l.as_str());
    let x: []u64 = [9, 2, 7];
    same_result(&b, &a, "rev", x, 4);
    let y: []u64 = [300, 190];
    same_result(&b, &a, "rev200", y, 195);
    let z: []u64 = [9, 0, 0];
    same_result(&b, &a, "rev_le", z, 99);
}

// Signed ranges (`srange`): a counter down from 89 while `i >s -11` keeps `i + 10` in [0, 99]; a counter
// up by 1 from `MIN + 1` while its next value is `<s MIN + 51` keeps `i - (MIN + 1)` in [0, 49]; the tests
// `x >=s 0` and `x <=s 10` keep `3 * x` at most 30. Their tests against 100, 100 and 31 fold; `i + 9`
// (down to -1) and `3 * x <u 30` stay.
@test
fn signed_ranges_of_counters_and_tests_bound_their_indexes() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @down fn global
sym @rot fn global
sym @tri fn global
sym @flag fn global
sym @both fn global
sym @either fn global
sym @upn fn global
sym @upn_any fn global
fn @down
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 89
  v2 = iconst.i64 -11
  v3 = iconst.i64 10
  v4 = iconst.i64 9
  v5 = iconst.i64 100
  v6 = iconst.i64 1
  v7 = iconst.i64 99
  jmp b1(v1, v0)
b1(v8: i64, v9: i64):
  v10 = icmp.sgt v8, v2
  br v10, b2, b6
b2:
  v11 = add.i64 v8, v3
  v12 = icmp.uge v11, v5
  br v12, b5, b3
b3:
  v13 = add.i64 v8, v4
  v14 = icmp.uge v13, v5
  br v14, b5, b4
b4:
  v15 = add.i64 v9, v11
  v16 = sub.i64 v8, v6
  jmp b1(v16, v15)
b5: cold
  ret v7
b6:
  ret v9
fn @rot
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -9223372036854775807
  v2 = iconst.i64 -9223372036854775757
  v3 = iconst.i64 100
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  jmp b1(v1, v0)
b1(v6: i64, v7: i64):
  v8 = sub.i64 v6, v1
  v9 = icmp.uge v8, v3
  br v9, b3, b2
b2:
  v10 = add.i64 v7, v8
  v11 = add.i64 v6, v4
  v12 = icmp.slt v11, v2
  br v12, b1(v11, v10), b4
b3: cold
  ret v5
b4:
  ret v10
fn @tri
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 10
  v3 = iconst.i64 3
  v4 = iconst.i64 31
  v5 = iconst.i64 30
  v6 = iconst.i64 99
  v7 = iconst.i64 77
  v8 = icmp.sge v0, v1
  br v8, b1, b5
b1:
  v9 = icmp.sle v0, v2
  br v9, b2, b5
b2:
  v10 = mul.i64 v0, v3
  v11 = icmp.uge v10, v4
  br v11, b4, b3
b3:
  v12 = icmp.uge v10, v5
  br v12, b6, b5
b4: cold
  ret v6
b5:
  ret v1
b6:
  ret v7
fn @flag
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 2
  v3 = iconst.i64 4
  v4 = iconst.i64 99
  v5 = icmp.eq v0, v1
  v6 = zext.i64 v5
  v7 = add.i64 v6, v2
  v8 = icmp.uge v7, v3
  br v8, b1, b2
b1: cold
  ret v4
b2:
  v9 = select.i64 v5, v2, v6
  v10 = icmp.uge v9, v3
  br v10, b1, b3
b3:
  v11 = add.i64 v7, v9
  ret v11
fn @both
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = sub.i64 v1, v3
  v7 = sub.i64 v2, v3
  jmp b1(v6, v7)
b1(v8: i64, v9: i64):
  v10 = icmp.sge v8, v4
  v11 = icmp.sge v9, v4
  v12 = and.i8 v10, v11
  br v12, b2, b6
b2:
  v13 = icmp.uge v8, v1
  br v13, b5, b3
b3:
  store v8, v0 align 3
  v14 = icmp.uge v9, v2
  br v14, b5, b4
b4:
  store v9, v0 align 3
  v15 = sub.i64 v8, v3
  v16 = sub.i64 v9, v3
  jmp b1(v15, v16)
b5: cold
  ret v5
b6:
  ret v4
fn @either
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = sub.i64 v1, v3
  v7 = sub.i64 v2, v3
  jmp b1(v6, v7)
b1(v8: i64, v9: i64):
  v10 = icmp.sge v8, v4
  v11 = icmp.sge v9, v4
  v12 = or.i8 v10, v11
  br v12, b2, b6
b2:
  v13 = icmp.uge v8, v1
  br v13, b5, b3
b3:
  store v8, v0 align 3
  v14 = icmp.uge v9, v2
  br v14, b5, b4
b4:
  store v9, v0 align 3
  v15 = sub.i64 v8, v3
  v16 = sub.i64 v9, v3
  jmp b1(v15, v16)
b5: cold
  ret v5
b6:
  ret v4
fn @upn
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 25
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = icmp.slt v0, v2
  br v6, b5, b1
b1:
  v7 = icmp.ule v1, v3
  br v7, b5, b2(v0, v2)
b2(v8: i64, v9: i64):
  v10 = icmp.sle v8, v3
  br v10, b3, b6(v9)
b3:
  v11 = icmp.uge v8, v1
  br v11, b4, b7
b4: cold
  ret v5
b5:
  ret v2
b6(v12: i64):
  ret v12
b7:
  v13 = add.i64 v9, v8
  v14 = add.i64 v8, v4
  jmp b2(v14, v13)
fn @upn_any
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 25
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = icmp.ule v1, v3
  br v6, b4, b1(v0, v2)
b1(v7: i64, v8: i64):
  v9 = icmp.sle v7, v3
  br v9, b2, b5(v8)
b2:
  v10 = icmp.uge v7, v1
  br v10, b3, b6
b3: cold
  ret v5
b4:
  ret v2
b5(v11: i64):
  ret v11
b6:
  v12 = add.i64 v8, v7
  v13 = add.i64 v7, v4
  jmp b1(v13, v12)
)",
    );
    // A counter up from `n >=s 0` while `i <=s 25` keeps its signed bound from below: below a length of at
    // least 26 (`upn`). From any `n` (`upn_any`) the test stays.
    let up = text_of(&a, "upn");
    assert(!up.contains("99"), up.as_str());
    let ua = text_of(&a, "upn_any");
    assert(ua.contains("99"), ua.as_str());
    let n24: []u64 = [24, 30];
    same_result(&b, &a, "upn", n24, 49);
    // Two counters down from `n - 1` and `m - 1` while both are at least 0 (`and`, or their minimum once
    // the optimizer selects it): both stay below their lengths. While either is (`either`), both tests stay.
    let bo = text_of(&a, "both");
    assert(!bo.contains("99"), bo.as_str());
    let ei = text_of(&a, "either");
    assert(count_of(&ei, "icmp.uge") == 2, ei.as_str());
    // A comparison is at most 1 (`ubound`): `flag + 2 <u 4` holds, and so does `select(c, 2, flag) <u 4`.
    let f = text_of(&a, "flag");
    assert(!f.contains("99"), f.as_str());
    let d = text_of(&a, "down");
    assert(count_of(&d, "icmp.uge") == 1, d.as_str());
    let r = text_of(&a, "rot");
    assert(!r.contains("99"), r.as_str());
    let t = text_of(&a, "tri");
    assert(!t.contains("99") && t.contains("77"), t.as_str());
    let z: []u64 = [0];
    same_result(&b, &a, "down", z, 99);
    same_result(&b, &a, "rot", z, 1225);
    let ten: []u64 = [10];
    same_result(&b, &a, "tri", ten, 77);
    let nine: []u64 = [9];
    same_result(&b, &a, "tri", nine, 0);
}

// Offsets that do not wrap (`offset_order`, `room`), inclusive and floor edge bounds (`edge_le`, `edge_floor`),
// counters by 2 (`signed_counter`, `param_bounds`), the count a scan leaves with (`join_out`, `join_in`) and a
// select of checked indexes (`arms_below`) fold their tests (the cold `ret 99`). Near misses keep theirs:
// `i + 1 >u len` under `i <=u len`, a sum of 129 within a room of 128, a step down by 3 past a floor of 2,
// `i + 2` of a counter by 2 below `len - 1`, a count compared with 127, a select with an unchecked index.
@test
fn offsets_steps_and_joins_bound_their_indexes() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @subs fn global
sym @room fn global
sym @room1 fn global
sym @rotle fn global
sym @down2 fn global
sym @down3 fn global
sym @sstep fn global
sym @sstep2 fn global
sym @scan fn global
sym @scan_n fn global
sym @pick3 fn global
sym @pick3_n fn global
sym @scan_h fn global
sym @diamond_join fn global
fn @subs
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 128
  v3 = iconst.i64 96
  v4 = iconst.i64 32
  v5 = iconst.i64 99
  v6 = iconst.i64 1
  v7 = iconst.i64 0
  v8 = icmp.uge v1, v2
  br v8, b1, b9
b1:
  v9 = icmp.ule v1, v0
  br v9, b2, b9
b2:
  v10 = sub.i64 v1, v3
  v11 = icmp.ugt v10, v0
  br v11, b8, b3
b3:
  v12 = sub.i64 v1, v2
  v13 = icmp.ugt v12, v10
  br v13, b8, b4
b4:
  v14 = sub.i64 v1, v4
  v15 = icmp.ugt v14, v1
  br v15, b8, b5
b5:
  v16 = add.i64 v1, v6
  v17 = icmp.ugt v16, v0
  br v17, b7, b6
b6:
  ret v12
b7:
  ret v6
b8: cold
  ret v5
b9:
  ret v7
fn @room
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 128
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = icmp.uge v0, v2
  br v5, b1, b5
b1:
  v6 = sub.i64 v0, v2
  v7 = icmp.ule v1, v6
  br v7, b2, b5
b2:
  v8, v9 = addo.u.i64 v1, v2
  br v9, b4, b3
b3:
  ret v8
b4: cold
  ret v3
b5:
  ret v4
fn @room1
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 128
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = iconst.i64 129
  v6 = icmp.uge v0, v2
  br v6, b1, b5
b1:
  v7 = sub.i64 v0, v2
  v8 = icmp.ule v1, v7
  br v8, b2, b5
b2:
  v9, v10 = addo.u.i64 v1, v5
  br v10, b4, b3
b3:
  ret v9
b4: cold
  ret v3
b5:
  ret v4
fn @rotle
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 128
  v2 = iconst.i64 32
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = icmp.uge v0, v1
  br v5, b1, b5(v4)
b1:
  v6 = sub.i64 v0, v1
  jmp b2(v4, v4)
b2(v7: i64, v8: i64):
  v9, v10 = addo.u.i64 v7, v2
  br v10, b6, b3
b3:
  v11 = icmp.ugt v9, v0
  br v11, b6, b4
b4:
  v12 = add.i64 v8, v9
  v13 = add.i64 v7, v1
  v14 = icmp.ule v13, v6
  br v14, b2(v13, v12), b5(v12)
b5(v15: i64):
  ret v15
b6: cold
  ret v3
fn @down2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 2
  v2 = iconst.i64 1
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = icmp.uge v0, v1
  br v5, b1(v0, v4), b4(v4)
b1(v6: i64, v7: i64):
  v8 = sub.i64 v6, v2
  v9 = icmp.uge v8, v0
  br v9, b5, b2
b2:
  v10 = sub.i64 v6, v1
  v11 = icmp.uge v10, v0
  br v11, b5, b3
b3:
  v12 = add.i64 v7, v10
  v13 = icmp.uge v10, v1
  br v13, b1(v10, v12), b4(v12)
b4(v14: i64):
  ret v14
b5: cold
  ret v3
fn @down3
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 2
  v2 = iconst.i64 3
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = icmp.uge v0, v1
  br v5, b1(v0, v4), b3(v4)
b1(v6: i64, v7: i64):
  v8 = sub.i64 v6, v2
  v9 = icmp.uge v8, v0
  br v9, b4, b2
b2:
  v10 = add.i64 v7, v6
  v11 = icmp.uge v8, v1
  br v11, b1(v8, v10), b3(v10)
b3(v12: i64):
  ret v12
b4: cold
  ret v3
fn @sstep
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
  ref p0 8 inner readonly
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = iconst.i64 2
  v5 = iconst.i64 99
  v6 = sub.i64 v1, v2
  v7 = icmp.sgt v6, v3
  br v7, b1(v3, v3), b4(v3)
b1(v8: i64, v9: i64):
  v10 = icmp.uge v8, v1
  br v10, b5, b2
b2:
  v11 = add.i64 v8, v2
  v12 = icmp.uge v11, v1
  br v12, b5, b3
b3:
  v13 = add.i64 v9, v11
  v14 = add.i64 v8, v4
  v15 = icmp.slt v14, v6
  br v15, b1(v14, v13), b4(v13)
b4(v16: i64):
  ret v16
b5: cold
  ret v5
fn @sstep2
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
  ref p0 8 inner readonly
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = iconst.i64 2
  v5 = iconst.i64 99
  v6 = sub.i64 v1, v2
  v7 = icmp.sgt v6, v3
  br v7, b1(v3, v3), b3(v3)
b1(v8: i64, v9: i64):
  v10 = add.i64 v8, v4
  v11 = icmp.uge v10, v1
  br v11, b4, b2
b2:
  v12 = add.i64 v9, v8
  v13 = icmp.slt v10, v6
  br v13, b1(v10, v12), b3(v12)
b3(v14: i64):
  ret v14
b4: cold
  ret v5
fn @scan
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 128
  v3 = iconst.i8 0
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  jmp b1(v1)
b1(v6: i64):
  v7 = ptradd v0, v6 * 1
  v8 = load.i8 v7 align 0
  v9 = icmp.eq v8, v3
  br v9, b3(v6), b2
b2:
  v10 = add.i64 v6, v4
  v11 = icmp.ult v10, v2
  br v11, b1(v10), b3(v10)
b3(v12: i64):
  v13 = icmp.ugt v12, v2
  br v13, b4, b5
b4: cold
  ret v5
b5:
  ret v12
fn @scan_n
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 128
  v3 = iconst.i8 0
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = iconst.i64 127
  jmp b1(v1)
b1(v7: i64):
  v8 = ptradd v0, v7 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v3
  br v10, b3(v7), b2
b2:
  v11 = add.i64 v7, v4
  v12 = icmp.ult v11, v2
  br v12, b1(v11), b3(v11)
b3(v13: i64):
  v14 = icmp.ugt v13, v6
  br v14, b4, b5
b4: cold
  ret v5
b5:
  ret v13
fn @pick3
  sig (i64, i64, i64, i64, i8, i8) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i8, v5: i8):
  v6 = iconst.i64 99
  v7 = iconst.i64 0
  v8 = icmp.ult v1, v0
  br v8, b1, b6
b1:
  v9 = icmp.ult v2, v0
  br v9, b2, b6
b2:
  v10 = icmp.ult v3, v0
  br v10, b3, b6
b3:
  v11 = select.i64 v5, v2, v3
  v12 = select.i64 v4, v1, v11
  v13 = icmp.uge v12, v0
  br v13, b4, b5
b4: cold
  ret v6
b5:
  ret v12
b6:
  ret v7
fn @pick3_n
  sig (i64, i64, i64, i64, i8, i8) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64, v4: i8, v5: i8):
  v6 = iconst.i64 99
  v7 = iconst.i64 0
  v8 = icmp.ult v1, v0
  br v8, b1, b5
b1:
  v9 = icmp.ult v2, v0
  br v9, b2, b5
b2:
  v10 = select.i64 v5, v2, v3
  v11 = select.i64 v4, v1, v10
  v12 = icmp.uge v11, v0
  br v12, b3, b4
b3: cold
  ret v6
b4:
  ret v11
b5:
  ret v7
fn @scan_h
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 128
  v3 = iconst.i8 0
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  jmp b1(v1)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b4(v6)
b2:
  v8 = ptradd v0, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v3
  br v10, b4(v6), b3
b3:
  v11 = add.i64 v6, v4
  jmp b1(v11)
b4(v12: i64):
  v13 = icmp.ugt v12, v2
  br v13, b5, b6
b5: cold
  ret v5
b6:
  ret v12
fn @diamond_join
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 10
  v4 = iconst.i64 5
  v5 = iconst.i64 7
  v6 = iconst.i64 20
  v7 = iconst.i64 99
  v8 = iconst.i64 0
  v9 = icmp.ult v0, v3
  br v9, b1, b3(v8)
b1:
  v10 = icmp.ult v1, v4
  br v10, b3(v2), b2
b2:
  v11 = and.i64 v1, v5
  jmp b3(v11)
b3(v12: i64):
  v13 = icmp.uge v12, v6
  br v13, b4, b5
b4: cold
  ret v7
b5:
  ret v12
)",
    );
    for name in ["subs", "room", "rotle", "down2", "sstep", "scan", "scan_h", "pick3"] {
        let t = text_of(&a, name);
        assert(!t.contains("99"), t.as_str());
    }
    // An if-conversion of a side that is the branch's own edge into the join (`diamond`) takes the join's
    // facts away: `v2` may be 100.
    for name in ["room1", "down3", "sstep2", "scan_n", "pick3_n", "diamond_join"] {
        let t = text_of(&a, name);
        assert(t.contains("99"), t.as_str());
    }
    let s: []u64 = [300, 200];
    same_result(&b, &a, "subs", s, 72);
    let dj: []u64 = [3, 2, 100];
    same_result(&b, &a, "diamond_join", dj, 99);
    let e: []u64 = [200, 200];
    same_result(&b, &a, "subs", e, 1);
    let r: []u64 = [200, 72];
    same_result(&b, &a, "room", r, 200);
    let l: []u64 = [300];
    same_result(&b, &a, "rotle", l, 32 + 160);
    let d: []u64 = [7];
    same_result(&b, &a, "down2", d, 5 + 3 + 1);
    let p: []u64 = [10, 1, 2, 3, 0, 0];
    same_result(&b, &a, "pick3", p, 3);
}

// An equality with a constant bounds the values the facts keep equal to its other side (`equal_const`):
// `i == j && i == 5` keeps `j - 5` below 1; an inequality moves a bound it meets by one (`not_bound`):
// `i != j`, `5 <= j <= 6` and `i == 5` keep `j - 6` below 1. With `j <= 7` (`neq_n`) the test stays.
@test
fn equalities_carry_constant_bounds_to_their_partners() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @eqp fn global
sym @neq fn global
sym @neq_n fn global
sym @notk fn global
fn @eqp
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 5
  v3 = iconst.i64 1
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = icmp.eq v0, v1
  br v6, b1, b4
b1:
  v7 = icmp.eq v0, v2
  br v7, b2, b4
b2:
  v8 = sub.i64 v1, v2
  v9 = icmp.uge v8, v3
  br v9, b3, b5
b3: cold
  ret v5
b4:
  ret v4
b5:
  ret v8
fn @neq
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 5
  v3 = iconst.i64 6
  v4 = iconst.i64 1
  v5 = iconst.i64 0
  v6 = iconst.i64 99
  v7 = icmp.ne v0, v1
  br v7, b1, b6
b1:
  v8 = icmp.uge v1, v2
  br v8, b2, b6
b2:
  v9 = icmp.ule v1, v3
  br v9, b3, b6
b3:
  v10 = icmp.eq v0, v2
  br v10, b4, b6
b4:
  v11 = sub.i64 v1, v3
  v12 = icmp.uge v11, v4
  br v12, b5, b7
b5: cold
  ret v6
b6:
  ret v5
b7:
  ret v11
fn @neq_n
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 5
  v3 = iconst.i64 6
  v4 = iconst.i64 1
  v5 = iconst.i64 0
  v6 = iconst.i64 99
  v7 = iconst.i64 7
  v8 = icmp.ne v0, v1
  br v8, b1, b6
b1:
  v9 = icmp.uge v1, v2
  br v9, b2, b6
b2:
  v10 = icmp.ule v1, v7
  br v10, b3, b6
b3:
  v11 = icmp.eq v0, v2
  br v11, b4, b6
b4:
  v12 = sub.i64 v1, v3
  v13 = icmp.uge v12, v4
  br v13, b5, b7
b5: cold
  ret v6
b6:
  ret v5
b7:
  ret v12
fn @notk
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 5
  v2 = iconst.i64 6
  v3 = iconst.i64 1
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = icmp.uge v0, v1
  br v6, b1, b5
b1:
  v7 = icmp.ule v0, v2
  br v7, b2, b5
b2:
  v8 = icmp.ne v0, v1
  br v8, b3, b5
b3:
  v9 = sub.i64 v0, v2
  v10 = icmp.uge v9, v3
  br v10, b4, b6
b4: cold
  ret v5
b5:
  ret v4
b6:
  ret v9
)",
    );
    let e = text_of(&a, "eqp");
    assert(!e.contains("99"), e.as_str());
    let n = text_of(&a, "neq");
    assert(!n.contains("99"), n.as_str());
    let k = text_of(&a, "notk");
    assert(!k.contains("99"), k.as_str());
    let m = text_of(&a, "neq_n");
    assert(m.contains("99"), m.as_str());
    let x: []u64 = [5, 5];
    same_result(&b, &a, "eqp", x, 0);
    let y: []u64 = [5, 6];
    same_result(&b, &a, "neq", y, 0);
    let z: []u64 = [5, 7];
    same_result(&b, &a, "neq_n", z, 99);
}

// Signed bounds across two values (`order_facts`): `i <s len - 2` with `i >= 0` keeps `len - 2` at least 1, so
// it does not wrap and `i + 2 <u len` folds (`dots`); `i + 3` (`dots_n`) stays. The value a counter down by 2
// from `len - 1` leaves with stays at most `len - 1` as a signed one (`join_arg`, `SHV_KEY`): at `i == 0` the
// tail's `a[i]` folds (`downtail`); from `len` (`downtail_n`) it stays.
@test
fn signed_bounds_cross_values_and_joins() {
    let (_b, a) = optimized(
        M"(lir ptr 8
sym @dots fn global
sym @dots_n fn global
sym @downtail fn global
sym @downtail_n fn global
sym @clamp fn global
sym @clamp_n fn global
fn @dots
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
  ref p0 1 inner readonly
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = iconst.i64 0
  v3 = iconst.i64 2
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = sub.i64 v1, v3
  jmp b1(v2, v2)
b1(v7: i64, v8: i64):
  v9 = icmp.slt v7, v6
  br v9, b2, b4
b2:
  v10 = add.i64 v7, v3
  v11 = icmp.uge v10, v1
  br v11, b5, b3
b3:
  v12 = add.i64 v8, v10
  v13 = add.i64 v7, v4
  jmp b1(v13, v12)
b4:
  ret v8
b5: cold
  ret v5
fn @dots_n
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
  ref p0 1 inner readonly
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = iconst.i64 0
  v3 = iconst.i64 2
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = iconst.i64 3
  v7 = sub.i64 v1, v3
  jmp b1(v2, v2)
b1(v8: i64, v9: i64):
  v10 = icmp.slt v8, v7
  br v10, b2, b4
b2:
  v11 = add.i64 v8, v6
  v12 = icmp.uge v11, v1
  br v12, b5, b3
b3:
  v13 = add.i64 v9, v11
  v14 = add.i64 v8, v4
  jmp b1(v14, v13)
b4:
  ret v9
b5: cold
  ret v5
fn @downtail
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
  ref p0 8 inner readonly
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 2
  v5 = iconst.i64 99
  v6 = sub.i64 v1, v3
  v7 = icmp.sgt v6, v2
  br v7, b1(v6, v2), b3(v6, v2)
b1(v8: i64, v9: i64):
  v10 = icmp.uge v8, v1
  br v10, b6, b2
b2:
  v11 = add.i64 v9, v8
  v12 = sub.i64 v8, v4
  v13 = icmp.sgt v12, v2
  br v13, b1(v12, v11), b3(v12, v11)
b3(v14: i64, v15: i64):
  v16 = icmp.sge v14, v2
  br v16, b4, b5
b4:
  v17 = icmp.uge v14, v1
  br v17, b6, b7
b5:
  ret v15
b6: cold
  ret v5
b7:
  v18 = add.i64 v15, v15
  ret v18
fn @downtail_n
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
  ref p0 8 inner readonly
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 2
  v5 = iconst.i64 99
  v6 = icmp.sgt v1, v2
  br v6, b1(v1, v2), b3(v1, v2)
b1(v7: i64, v8: i64):
  v9 = sub.i64 v7, v3
  v10 = icmp.uge v9, v1
  br v10, b6, b2
b2:
  v11 = add.i64 v8, v7
  v12 = sub.i64 v7, v4
  v13 = icmp.sgt v12, v2
  br v13, b1(v12, v11), b3(v12, v11)
b3(v14: i64, v15: i64):
  v16 = icmp.sge v14, v2
  br v16, b4, b5
b4:
  v17 = icmp.uge v14, v1
  br v17, b6, b7
b5:
  ret v15
b6: cold
  ret v5
b7:
  v18 = add.i64 v15, v15
  ret v18
fn @clamp
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i64) -> i64
  ref p0 8 inner readonly
b0(v0: ptr, v1: i64):
  v2 = load.i64 v0+8 align 3
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = icmp.eq v2, v3
  br v6, b3, b1
b1:
  v7 = icmp.sgt v1, v3
  v8 = select.i64 v7, v1, v3
  v9 = sub.i64 v2, v4
  v10 = icmp.slt v8, v9
  v11 = select.i64 v10, v8, v9
  v12 = icmp.uge v11, v2
  br v12, b2, b4
b2: cold
  ret v5
b3:
  ret v3
b4:
  ret v11
fn @clamp_n
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i64) -> i64
  ref p0 8 inner readonly
b0(v0: ptr, v1: i64):
  v2 = load.i64 v0+8 align 3
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 99
  v6 = icmp.sgt v1, v3
  v7 = select.i64 v6, v1, v3
  v8 = sub.i64 v2, v4
  v9 = icmp.slt v7, v8
  v10 = select.i64 v9, v7, v8
  v11 = icmp.uge v10, v2
  br v11, b1, b2
b1: cold
  ret v5
b2:
  ret v10
)",
    );
    for name in ["dots", "downtail", "clamp"] {
        let t = text_of(&a, name);
        assert(!t.contains("99"), t.as_str());
    }
    // `min(max(i, 0), len - 1)` is below a nonzero `len` (`srange` of the selects, `order_decided`); with `len`
    // possibly 0 (`clamp_n`) its test stays.
    for name in ["dots_n", "downtail_n", "clamp_n"] {
        let t = text_of(&a, name);
        assert(t.contains("99"), t.as_str());
    }
}

// Order facts that decide the checks of suffixes, prefixes, halves and masks (`order_decided`): `n - q == 0`
// and `q >u n` fail where `q <u n` (`suffix`); `i + 1 == 0` fails for a counter below `n` (`prefix`);
// `h & (n - 1) <u n` where `n != 0` (`mask`); `(n + 1) >> 1 <=u n` where `n + 1` does not wrap (`half`);
// `zext(a - 1) <u y` after `zext(a) <u y` and `a != 0` (`zext`); `n - w <=u n` where `w <=u n` (`tail`).
// Their near misses keep their tests: `q <=u n` (`suffix_le`), `h & n` (`mask_n`), `(n + 2) >> 1`
// (`half_2`), no `a != 0` (`zext_any`), no `w <=u n` (`tail_any`).
@test
fn order_facts_decide_suffix_prefix_half_and_mask_checks() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @suffix fn global
sym @prefix fn global
sym @mask fn global
sym @half fn global
sym @zext fn global
sym @tail fn global
sym @suffix_le fn global
sym @mask_n fn global
sym @half_2 fn global
sym @zext_any fn global
sym @tail_any fn global
sym @halfnz fn global
sym @halfnz_any fn global
sym @trunc fn global
sym @trunc_other fn global
fn @suffix
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 99
  v4 = icmp.ult v1, v0
  br v4, b1, b4
b1:
  v5 = sub.i64 v0, v1
  v6 = icmp.eq v5, v2
  br v6, b3, b2
b2:
  v7 = icmp.ugt v1, v0
  br v7, b3, b4
b3: cold
  ret v3
b4:
  ret v2
fn @prefix
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 99
  v4 = icmp.ne v0, v1
  br v4, b1(v1), b4(v1)
b1(v5: i64):
  v6 = add.i64 v5, v2
  v7 = icmp.eq v6, v1
  br v7, b3, b2
b2:
  v8 = icmp.ult v6, v0
  br v8, b1(v6), b4(v6)
b3: cold
  ret v3
b4(v9: i64):
  ret v9
fn @mask
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 99
  v5 = icmp.eq v0, v2
  br v5, b3, b1
b1:
  v6 = sub.i64 v0, v3
  v7 = and.i64 v1, v6
  v8 = icmp.uge v7, v0
  br v8, b2, b4(v7)
b2: cold
  ret v4
b3:
  ret v2
b4(v9: i64):
  ret v9
fn @half
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1000
  v2 = iconst.i64 1
  v3 = iconst.i64 99
  v4 = iconst.i64 0
  v5 = icmp.ult v0, v1
  br v5, b1, b3
b1:
  v6 = add.i64 v0, v2
  v7 = lshr.i64 v6, v2
  v8 = icmp.ugt v7, v0
  br v8, b2, b4(v7)
b2: cold
  ret v3
b3:
  ret v4
b4(v9: i64):
  ret v9
fn @zext
  sig (i32, i64) -> i64
b0(v0: i32, v1: i64):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  v4 = iconst.i64 98
  v5 = iconst.i64 99
  v6 = iconst.i64 0
  v7 = zext.i64 v0
  v8 = icmp.uge v7, v1
  br v8, b4, b1
b1:
  v9 = icmp.ne v0, v2
  br v9, b2, b6
b2:
  v10 = sub.i32 v0, v3
  v11 = zext.i64 v10
  v12 = icmp.uge v11, v1
  br v12, b5, b3
b3:
  ret v11
b4: cold
  ret v4
b5: cold
  ret v5
b6:
  ret v6
fn @tail
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 99
  v4 = icmp.ule v1, v0
  br v4, b1, b3
b1:
  v5 = sub.i64 v0, v1
  v6 = icmp.ugt v5, v0
  br v6, b2, b4(v5)
b2: cold
  ret v3
b3:
  ret v2
b4(v7: i64):
  ret v7
fn @suffix_le
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 99
  v4 = icmp.ule v1, v0
  br v4, b1, b3
b1:
  v5 = sub.i64 v0, v1
  v6 = icmp.eq v5, v2
  br v6, b2, b3
b2: cold
  ret v3
b3:
  ret v2
fn @mask_n
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 99
  v4 = icmp.eq v0, v2
  br v4, b3, b1
b1:
  v5 = and.i64 v1, v0
  v6 = icmp.uge v5, v0
  br v6, b2, b4(v5)
b2: cold
  ret v3
b3:
  ret v2
b4(v7: i64):
  ret v7
fn @half_2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1000
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = iconst.i64 99
  v5 = iconst.i64 0
  v6 = icmp.ult v0, v1
  br v6, b1, b3
b1:
  v7 = add.i64 v0, v3
  v8 = lshr.i64 v7, v2
  v9 = icmp.ugt v8, v0
  br v9, b2, b4(v8)
b2: cold
  ret v4
b3:
  ret v5
b4(v10: i64):
  ret v10
fn @zext_any
  sig (i32, i64) -> i64
b0(v0: i32, v1: i64):
  v2 = iconst.i32 1
  v3 = iconst.i64 98
  v4 = iconst.i64 99
  v5 = zext.i64 v0
  v6 = icmp.uge v5, v1
  br v6, b3, b1
b1:
  v7 = sub.i32 v0, v2
  v8 = zext.i64 v7
  v9 = icmp.uge v8, v1
  br v9, b4, b2
b2:
  ret v8
b3: cold
  ret v3
b4: cold
  ret v4
fn @tail_any
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 99
  v3 = sub.i64 v0, v1
  v4 = icmp.ugt v3, v0
  br v4, b1, b2(v3)
b1: cold
  ret v2
b2(v5: i64):
  ret v5
fn @halfnz
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 0
  v3 = iconst.i64 99
  v4 = lshr.i64 v0, v1
  v5 = icmp.eq v4, v2
  br v5, b3, b1
b1:
  v6 = sub.i64 v0, v1
  v7 = icmp.uge v6, v0
  br v7, b2, b4
b2: cold
  ret v3
b3:
  ret v2
b4:
  v8 = sub.i64 v4, v1
  v9 = icmp.uge v8, v0
  br v9, b2, b5
b5:
  v10 = add.i64 v6, v8
  ret v10
fn @halfnz_any
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 99
  v3 = sub.i64 v0, v1
  v4 = icmp.uge v3, v0
  br v4, b1, b2
b1: cold
  ret v2
b2:
  ret v3
fn @trunc
  sig (i64, i32) -> i64
b0(v0: i64, v1: i32):
  v2 = iconst.i64 0
  v3 = iconst.i64 99
  v4 = trunc.i32 v0
  v5 = icmp.ult v1, v4
  br v5, b1, b3
b1:
  v6 = zext.i64 v1
  v7 = icmp.uge v6, v0
  br v7, b2, b4
b2: cold
  ret v3
b3:
  ret v2
b4:
  ret v6
fn @trunc_other
  sig (i64, i32, i64) -> i64
b0(v0: i64, v1: i32, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 99
  v5 = trunc.i32 v0
  v6 = icmp.ult v1, v5
  br v6, b1, b3
b1:
  v7 = zext.i64 v1
  v8 = icmp.uge v7, v2
  br v8, b2, b4
b2: cold
  ret v4
b3:
  ret v3
b4:
  ret v7
)",
    );
    // `i / 2 != 0` makes `i` at least 1, and `(i >> 1) - 1` is below `i` (`halfnz`); `zext(i) <u len` where
    // `i <u trunc(len)` (`trunc`). Near misses: no `i / 2 != 0` (`halfnz_any`), another bound (`trunc_other`).
    for name in ["suffix", "prefix", "mask", "half", "zext", "tail", "halfnz", "trunc"] {
        let t = text_of(&a, name);
        assert(!t.contains("99"), t.as_str());
    }
    for name in ["suffix_le", "mask_n", "half_2", "zext_any", "tail_any", "halfnz_any", "trunc_other"] {
        let t = text_of(&a, name);
        assert(t.contains("99"), t.as_str());
    }
    let s: []u64 = [5, 2];
    same_result(&b, &a, "suffix", s, 0);
    let s63: []u64 = [6, 3];
    same_result(&b, &a, "mask", s63, 1);
    same_result(&b, &a, "tail", s, 3);
    let s5: []u64 = [5, 5];
    same_result(&b, &a, "suffix_le", s5, 99);
    same_result(&b, &a, "mask_n", s63, 2);
    let n: []u64 = [7];
    same_result(&b, &a, "prefix", n, 7);
    same_result(&b, &a, "half", n, 4);
    let z: []u64 = [0];
    same_result(&b, &a, "half_2", z, 99);
    let a39: []u64 = [3, 9];
    same_result(&b, &a, "zext", a39, 2);
    let a09: []u64 = [0, 9];
    same_result(&b, &a, "zext_any", a09, 99);
    let a25: []u64 = [2, 5];
    same_result(&b, &a, "tail_any", a25, 99);
    let h6: []u64 = [6];
    same_result(&b, &a, "halfnz", h6, 7);
    let t53: []u64 = [5, 3];
    same_result(&b, &a, "trunc", t53, 3);
}

// `i + 3 <u n` where `i <u n & -4` and `i` counts from 0 by 4: both are multiples of 4, so `i` is at most
// `(n & -4) - 4` and the test folds (`low_zeros`). A counter by 2, or a bound rounded to a multiple of 2,
// can pass `n`, and the test stays.
@test
fn a_stride_below_a_bound_of_its_multiple_stays_below_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @by4 fn global
sym @by2 fn global
sym @mask2 fn global
fn @by4
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -4
  v2 = iconst.i64 4
  v3 = iconst.i64 3
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = and.i64 v0, v1
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b4
b2:
  v9 = add.i64 v7, v3
  v10 = icmp.uge v9, v0
  br v10, b3, b5
b3: cold
  ret v5
b4:
  ret v7
b5:
  v11 = add.i64 v7, v2
  jmp b1(v11)
fn @by2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -4
  v2 = iconst.i64 2
  v3 = iconst.i64 3
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = and.i64 v0, v1
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b4
b2:
  v9 = add.i64 v7, v3
  v10 = icmp.uge v9, v0
  br v10, b3, b5
b3: cold
  ret v5
b4:
  ret v7
b5:
  v11 = add.i64 v7, v2
  jmp b1(v11)
fn @mask2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -2
  v2 = iconst.i64 4
  v3 = iconst.i64 3
  v4 = iconst.i64 0
  v5 = iconst.i64 99
  v6 = and.i64 v0, v1
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b4
b2:
  v9 = add.i64 v7, v3
  v10 = icmp.uge v9, v0
  br v10, b3, b5
b3: cold
  ret v5
b4:
  ret v7
b5:
  v11 = add.i64 v7, v2
  jmp b1(v11)
)",
    );
    let f = text_of(&a, "by4");
    assert(!f.contains("99"), f.as_str());
    let t = text_of(&a, "by2");
    assert(t.contains("99"), t.as_str());
    let m = text_of(&a, "mask2");
    assert(m.contains("99"), m.as_str());
    let n9: []u64 = [9];
    same_result(&b, &a, "by4", n9, 8);
    same_result(&b, &a, "by2", n9, 99);
    let n10: []u64 = [10];
    same_result(&b, &a, "mask2", n10, 99);
    same_result(&b, &a, "by4", n10, 8);
}

// A store of an inlined call's copy (`Body.scopes`) through its exclusive parameter writes no byte another
// pointer of the copy reaches, but a pointer of the caller outside the copy may reach any: a row's length
// loaded before the copy of `rows[k].clear()` is loaded again after it (`carry`), as row `i` may be row `k`.
@test
fn a_store_through_a_scope_root_kills_what_the_caller_loaded() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "rows.spc"
sym @row fn global noinline
sym @top fn global
fn @row
  file f0
  sig (ptr, i64, i64) -> i64
  ref p0 24 noalias
  owned p0 0
  scope @7:5 g0 v8
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = load.ptr v0 align 3 tbaa 8
  v5 = ptradd v4, v1 * 24 inbounds nonnull
  v6 = load.i64 v5+8 align 3 tbaa 4
  v7 = icmp.ult v3, v6
  br v7, b1, b2
b1:
  v8 = ptradd v4, v2 * 24 inbounds nonnull
  store v3, v8+8 align 3 tbaa 4 !7:5@7:5
  v9 = load.i64 v5+8 align 3 tbaa 4
  ret v9
b2:
  ret v3
fn @top
  sig (i64, i64) -> i64
  slot s0 size 24 align 3
  slot s1 size 48 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 5
  store v3, v2 align 3
  store v4, v3+8 align 3
  store v4, v3+32 align 3
  v5 = call.i64 @row(v2, v0, v1) : (ptr, i64, i64) -> i64
  ret v5
)",
    );
    let t = text_of(&a, "row");
    assert(count_of(&t, "load.i64") == 2, t.as_str());
    let same: []u64 = [1, 1];
    same_result(&b, &a, "top", same, 0);
    let other: []u64 = [0, 1];
    same_result(&b, &a, "top", other, 5);
}

// Past its copy, an inlined call's root is a pointer of the class it comes from: `&mut self.c` passed to
// a call after a copy of a call on it lets `self` escape, so a load of `self.c`'s field after the call
// reads what the call wrote, not the value loaded before it.
@test
fn a_root_past_its_copy_is_a_pointer_of_its_base() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "root.spc"
sym @bump fn global
sym @grow fn global noinline
sym @top fn global noinline
sym @drive fn global
fn @bump
  sig (ptr) -> void
  ref p0 8 noalias
b0(v0: ptr):
  v1 = load.i32 v0+4 align 2
  v2 = iconst.i32 1
  v3 = add.i32 v1, v2
  store v3, v0+4 align 2
  ret
fn @grow
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i32 9
  store v1, v0+4 align 2
  ret
fn @top
  file f0
  sig (ptr) -> i32
  ref p0 16 noalias
b0(v0: ptr):
  v1 = ptradd v0+8
  call @bump(v1) : (ptr) -> void !3:5
  v2 = load.i32 v0+12 align 2
  call @grow(v1) : (ptr) -> void !4:5
  v3 = load.i32 v0+12 align 2
  v4 = add.i32 v2, v3
  ret v4
fn @drive
  sig () -> i32
  slot s0 size 16 align 3
b0:
  v0 = slotaddr s0
  v1 = iconst.i64 0
  store v1, v0 align 3
  store v1, v0+8 align 3
  v2 = call.i32 @top(v0) : (ptr) -> i32
  ret v2
)",
    );
    let s = text_of(&a, "top");
    let g = s.as_str().find("call @grow");
    assert(
        s.contains("scope") && g >= 0 && s.as_str().slice(g as usize, s.len()).contains("load.i32 v0+12"),
        s.as_str(),
    );
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 1 + 9);
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

// The field-wise sum `o.x = a.x + b.x; o.y = a.y + b.y; ..` loads each lane between the stores: an
// exclusive referent's stores and read-only referents' loads touch different bytes (`Slp::apart`), so
// they pack as one vector store of a sum of two vector loads. Without the references' classes `o` may be
// `a` moved by a lane, and the stores and loads keep their order: `top2` passes such pointers.
@test
fn field_wise_sums_pack_across_the_loads_between_their_stores() {
    let body = M"(b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.i32 v1 align 2
  v4 = load.i32 v2 align 2
  v5 = add.i32 v3, v4
  store v5, v0 align 2
  v6 = load.i32 v1+4 align 2
  v7 = load.i32 v2+4 align 2
  v8 = add.i32 v6, v7
  store v8, v0+4 align 2
  v9 = load.i32 v1+8 align 2
  v10 = load.i32 v2+8 align 2
  v11 = add.i32 v9, v10
  store v11, v0+8 align 2
  v12 = load.i32 v1+12 align 2
  v13 = load.i32 v2+12 align 2
  v14 = add.i32 v12, v13
  store v14, v0+12 align 2
  ret
)";
    let tops = M"(fn @top
  sig (i32) -> i32
  slot s0 size 16 align 4
  slot s1 size 16 align 4
  slot s2 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i32 3
  v5 = add.i32 v0, v4
  store v0, v2 align 2
  store v5, v2+4 align 2
  store v0, v2+8 align 2
  store v5, v2+12 align 2
  store v5, v3 align 2
  store v5, v3+4 align 2
  store v0, v3+8 align 2
  store v0, v3+12 align 2
  call @f(v1, v2, v3) : (ptr, ptr, ptr) -> void
  v6 = load.i32 v1+4 align 2
  v7 = load.i32 v1+8 align 2
  v8 = add.i32 v6, v7
  ret v8
fn @top2
  sig (i32) -> i32
  slot s0 size 32 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = ptradd v1+4
  store v0, v1 align 2
  store v0, v1+4 align 2
  store v0, v1+8 align 2
  store v0, v1+12 align 2
  store v0, v1+16 align 2
  call @f(v2, v1, v1) : (ptr, ptr, ptr) -> void
  v3 = load.i32 v1+16 align 2
  ret v3
)";
    let head = "lir ptr 8\nsym @f fn global noinline\nsym @top fn global\nsym @top2 fn global\nfn @f\n  sig (ptr, ptr, ptr) -> void\n";
    let refs = format("{}  ref p0 16 noalias\n  ref p1 16 readonly\n  ref p2 16 readonly\n{}{}", head, body, tops);
    let (b, a) = optimized_with(&refs, 0, false, 4);
    let t = text_of(&a, "f");
    assert(count_of(&t, "add.v4i32") == 1 && count_of(&t, "load.v4i32") == 2 && count_of(&t, "store ") == 1, t.as_str());
    let x: []u64 = [20];
    same_result(&b, &a, "top", x, 86);
    // Each lane doubles the lane before it, which the store before wrote: 20 << 4.
    let plain = format("{}{}{}", head, body, tops);
    let (b2, a2) = optimized_with(&plain, 0, false, 4);
    let t2 = text_of(&a2, "f");
    assert(!t2.contains("v4i32"), t2.as_str());
    same_result(&b2, &a2, "top2", x, 320);
}

// Stores written from the highest address down pack as one group (`Slp::store_seeds` takes a group's
// stores in any order), and lanes that are a vector's in reverse order take that vector with its lanes
// moved (`PK_PERM`, a `swizzle` the backends do in registers): one vector store of a sum of a reversed
// vector load and a vector load.
@test
fn stores_in_any_order_and_reversed_lanes_pack() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, ptr, ptr) -> void
  ref p0 16 noalias
  ref p1 16 readonly
  ref p2 16 readonly
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.i32 v1 align 2
  v4 = load.i32 v2+12 align 2
  v5 = add.i32 v3, v4
  store v5, v0+12 align 2
  v6 = load.i32 v1+4 align 2
  v7 = load.i32 v2+8 align 2
  v8 = add.i32 v6, v7
  store v8, v0+8 align 2
  v9 = load.i32 v1+8 align 2
  v10 = load.i32 v2+4 align 2
  v11 = add.i32 v9, v10
  store v11, v0+4 align 2
  v12 = load.i32 v1+12 align 2
  v13 = load.i32 v2 align 2
  v14 = add.i32 v12, v13
  store v14, v0 align 2
  ret
fn @top
  sig (i32) -> i32
  slot s0 size 16 align 4
  slot s1 size 16 align 4
  slot s2 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i32 1
  v5 = iconst.i32 10
  v6 = iconst.i32 0
  v7 = iconst.i32 20
  v8 = iconst.i32 30
  v9 = add.i32 v0, v4
  v10 = add.i32 v9, v4
  v11 = add.i32 v10, v4
  store v0, v2 align 2
  store v9, v2+4 align 2
  store v10, v2+8 align 2
  store v11, v2+12 align 2
  store v6, v3 align 2
  store v5, v3+4 align 2
  store v7, v3+8 align 2
  store v8, v3+12 align 2
  call @f(v1, v2, v3) : (ptr, ptr, ptr) -> void
  v12 = load.i32 v1+4 align 2
  v13 = load.i32 v1+12 align 2
  v14 = load.i32 v1 align 2
  v15 = mul.i32 v14, v5
  v16 = add.i32 v12, v13
  v17 = add.i32 v16, v15
  ret v17
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "add.v4i32") == 1 && count_of(&t, "swizzle") == 1 && count_of(&t, "store ") == 1, t.as_str());
    // o = [x + 3, x + 12, x + 21, x + 30]: (x + 12) + (x + 30) + 10 * (x + 3).
    let x: []u64 = [5];
    same_result(&b, &a, "top", x, 132);
}

// A load of a stored lane's bytes between a group's stores reads that lane's new value and the next
// lane's old one: the stores do not move past it to the group's last (`Slp::group_last`), and stay
// scalar.
@test
fn a_load_between_a_groups_stores_keeps_them_in_place() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @g fn global noinline
sym @top fn global
fn @g
  sig (ptr, ptr) -> i64
  ref p0 16 noalias
  ref p1 16 readonly
b0(v0: ptr, v1: ptr):
  v2 = iconst.i32 1
  v3 = iconst.i32 2
  v4 = iconst.i32 3
  v5 = iconst.i32 4
  v6 = load.i32 v1+12 align 2
  v7 = add.i32 v6, v5
  store v7, v0+12 align 2
  v8 = load.i32 v1 align 2
  v9 = add.i32 v8, v2
  store v9, v0 align 2
  v10 = load.i64 v0 align 2
  v11 = load.i32 v1+8 align 2
  v12 = add.i32 v11, v4
  store v12, v0+8 align 2
  v13 = load.i32 v1+4 align 2
  v14 = add.i32 v13, v3
  store v14, v0+4 align 2
  ret v10
fn @top
  sig (i32) -> i64
  slot s0 size 16 align 4
  slot s1 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i32 0
  store v3, v1 align 2
  store v3, v1+4 align 2
  store v0, v2 align 2
  store v0, v2+4 align 2
  store v0, v2+8 align 2
  store v0, v2+12 align 2
  v4 = call.i64 @g(v1, v2) : (ptr, ptr) -> i64
  ret v4
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "g");
    assert(count_of(&t, "store ") == 4 && !t.contains("v4i32"), t.as_str());
    // The load reads lane 0 as x + 1 and lane 1 as 0.
    let x: []u64 = [6];
    same_result(&b, &a, "top", x, 7);
}

// A sum of terms past a multiple of the lanes packs the multiple: six loads, a vector of four reduced, the
// two others added to it (`Slp::red_seeds`, `rrest`); the same sum.
@test
fn a_sum_past_a_multiple_of_the_lanes_packs_the_multiple() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr) -> i32
  ref p0 24 readonly
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = load.i32 v0+4 align 2
  v3 = load.i32 v0+8 align 2
  v4 = load.i32 v0+12 align 2
  v5 = load.i32 v0+16 align 2
  v6 = load.i32 v0+20 align 2
  v7 = add.i32 v1, v2
  v8 = add.i32 v7, v3
  v9 = add.i32 v8, v4
  v10 = add.i32 v9, v5
  v11 = add.i32 v10, v6
  ret v11
fn @top
  sig (i32) -> i32
  slot s0 size 24 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = iconst.i32 10
  v3 = iconst.i32 200
  store v0, v1 align 2
  store v2, v1+4 align 2
  store v3, v1+8 align 2
  store v0, v1+12 align 2
  store v2, v1+16 align 2
  store v3, v1+20 align 2
  v4 = call.i32 @f(v1) : (ptr) -> i32
  ret v4
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(
        count_of(&t, "load.v4i32") == 1 && count_of(&t, "reduce_add") == 1 && count_of(&t, "= add.i32") == 2,
        t.as_str(),
    );
    // x = 3: 2 * (3 + 10 + 200).
    let x: []u64 = [3];
    same_result(&b, &a, "top", x, 426);
}

// Lanes another pack holds rotated, or its low half's lanes twice each, are that pack's vector moved in
// registers (`perm_lane`): a `shuffle` of the vector with itself from lane 1 (arm64 EXT, x86-64 PALIGNR:
// `lv::lane_slide`), an interleave of the vector with itself.
@test
fn rotated_and_doubled_lanes_move_in_registers() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, ptr, ptr, ptr) -> void
  ref p0 16 noalias
  ref p1 16 noalias
  ref p2 16 readonly
  ref p3 16 readonly
b0(v0: ptr, v1: ptr, v2: ptr, v3: ptr):
  v4 = load.i32 v2 align 2
  v5 = load.i32 v2+4 align 2
  v6 = load.i32 v2+8 align 2
  v7 = load.i32 v2+12 align 2
  v8 = load.i32 v3 align 2
  v9 = load.i32 v3+4 align 2
  v10 = load.i32 v3+8 align 2
  v11 = load.i32 v3+12 align 2
  v12 = add.i32 v4, v8
  v13 = add.i32 v5, v9
  v14 = add.i32 v6, v10
  v15 = add.i32 v7, v11
  store v12, v1 align 2
  store v13, v1+4 align 2
  store v14, v1+8 align 2
  store v15, v1+12 align 2
  v16 = xor.i32 v5, v12
  v17 = xor.i32 v6, v12
  v18 = xor.i32 v7, v13
  v19 = xor.i32 v4, v13
  store v16, v0 align 2
  store v17, v0+4 align 2
  store v18, v0+8 align 2
  store v19, v0+12 align 2
  ret
fn @top
  sig (i32) -> i32
  slot s0 size 16 align 4
  slot s1 size 16 align 4
  slot s2 size 16 align 4
  slot s3 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i32 1
  v6 = iconst.i32 6
  v7 = iconst.i32 40
  store v0, v3 align 2
  store v5, v3+4 align 2
  store v6, v3+8 align 2
  store v7, v3+12 align 2
  store v7, v4 align 2
  store v6, v4+4 align 2
  store v5, v4+8 align 2
  store v0, v4+12 align 2
  call @f(v1, v2, v3, v4) : (ptr, ptr, ptr, ptr) -> void
  v8 = load.i32 v1 align 2
  v9 = load.i32 v1+4 align 2
  v10 = load.i32 v1+8 align 2
  v11 = load.i32 v1+12 align 2
  v12 = add.i32 v8, v9
  v13 = add.i32 v12, v10
  v14 = add.i32 v13, v11
  ret v14
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(
        count_of(&t, "shuffle.v4i32") == 1 && count_of(&t, "vziplo") == 1 && count_of(&t, "xor.v4i32") == 1 && count_of(
            &t,
            "xor.i32",
        ) == 0,
        t.as_str(),
    );
    // x = 2: t = [42, 7, 7, 42]; o = [1 ^ 42, 6 ^ 42, 40 ^ 7, 2 ^ 7] = [43, 44, 47, 5].
    let x: []u64 = [2];
    same_result(&b, &a, "top", x, 139);
}

// Four values stored and summed with weights: the sum's packs hold them, and the store group, which the
// sum's reads alone kept scalar before it, then stores their vector (`Slp::plan` tries the stores again
// after the sums): one vector `xor`, one vector store, no scalar `xor`.
@test
fn values_a_sum_packs_are_stored_from_its_vector() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, ptr, ptr) -> i32
  ref p0 16 noalias
  ref p1 16 readonly
  ref p2 16 readonly
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = iconst.i32 3
  v4 = iconst.i32 5
  v5 = iconst.i32 7
  v6 = iconst.i32 11
  v7 = load.i32 v1 align 2
  v8 = load.i32 v2 align 2
  v9 = xor.i32 v7, v8
  v10 = load.i32 v1+4 align 2
  v11 = load.i32 v2+4 align 2
  v12 = xor.i32 v10, v11
  v13 = load.i32 v1+8 align 2
  v14 = load.i32 v2+8 align 2
  v15 = xor.i32 v13, v14
  v16 = load.i32 v1+12 align 2
  v17 = load.i32 v2+12 align 2
  v18 = xor.i32 v16, v17
  store v9, v0 align 2
  store v12, v0+4 align 2
  store v15, v0+8 align 2
  store v18, v0+12 align 2
  v19 = mul.i32 v9, v3
  v20 = mul.i32 v12, v4
  v21 = add.i32 v19, v20
  v22 = mul.i32 v15, v5
  v23 = add.i32 v21, v22
  v24 = mul.i32 v18, v6
  v25 = add.i32 v23, v24
  ret v25
fn @top
  sig (i32) -> i32
  slot s0 size 16 align 4
  slot s1 size 16 align 4
  slot s2 size 16 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i32 1
  v5 = iconst.i32 6
  store v0, v2 align 2
  store v4, v2+4 align 2
  store v0, v2+8 align 2
  store v4, v2+12 align 2
  store v5, v3 align 2
  store v5, v3+4 align 2
  store v4, v3+8 align 2
  store v0, v3+12 align 2
  v6 = call.i32 @f(v1, v2, v3) : (ptr, ptr, ptr) -> i32
  v7 = load.i32 v1+12 align 2
  v8 = add.i32 v6, v7
  ret v8
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "xor.v4i32") == 1 && count_of(&t, "xor.i32") == 0 && count_of(&t, "store ") == 1, t.as_str());
    // x = 2: lanes [4, 7, 3, 3]; 12 + 35 + 21 + 33 = 101, then lane 3.
    let x: []u64 = [2];
    same_result(&b, &a, "top", x, 104);
}

// Each seed's packs count by themselves (`Slp::pays`): four stores of products of parameters gather all
// their lanes, which costs more than they save, and stay scalar; the four stores of sums of loads beside
// them still pack. A lane another instruction reads too keeps its scalar and saves nothing.
@test
fn a_seed_that_gathers_does_not_keep_another_from_packing() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @f fn global noinline
sym @top fn global
fn @f
  sig (ptr, ptr, i32, i32, i32, i32, i32, i32, i32, i32) -> i32
  ref p0 32 noalias
  ref p1 32 readonly
b0(v0: ptr, v1: ptr, v2: i32, v3: i32, v4: i32, v5: i32, v6: i32, v7: i32, v8: i32, v9: i32):
  v10 = load.i32 v1 align 2
  v11 = load.i32 v1+4 align 2
  v12 = load.i32 v1+8 align 2
  v13 = load.i32 v1+12 align 2
  v14 = load.i32 v1+16 align 2
  v15 = load.i32 v1+20 align 2
  v16 = load.i32 v1+24 align 2
  v17 = load.i32 v1+28 align 2
  v18 = add.i32 v10, v14
  v19 = add.i32 v11, v15
  v20 = add.i32 v12, v16
  v21 = add.i32 v13, v17
  store v18, v0 align 2
  store v19, v0+4 align 2
  store v20, v0+8 align 2
  store v21, v0+12 align 2
  v22 = mul.i32 v2, v6
  v23 = mul.i32 v3, v7
  v24 = mul.i32 v4, v8
  v25 = mul.i32 v5, v9
  store v22, v0+16 align 2
  store v23, v0+20 align 2
  store v24, v0+24 align 2
  store v25, v0+28 align 2
  ret v22
fn @top
  sig (i32) -> i32
  slot s0 size 32 align 4
  slot s1 size 32 align 4
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i32 2
  store v0, v2 align 2
  store v0, v2+4 align 2
  store v0, v2+8 align 2
  store v0, v2+12 align 2
  store v3, v2+16 align 2
  store v3, v2+20 align 2
  store v3, v2+24 align 2
  store v3, v2+28 align 2
  v4 = call.i32 @f(v1, v2, v0, v0, v0, v0, v3, v3, v3, v3) : (ptr, ptr, i32, i32, i32, i32, i32, i32, i32, i32) -> i32
  v5 = load.i32 v1+4 align 2
  v6 = load.i32 v1+28 align 2
  v7 = add.i32 v5, v6
  v8 = add.i32 v7, v4
  ret v8
)",
        0,
        false,
        4,
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "add.v4i32") == 1 && count_of(&t, "mul.i32") == 4 && count_of(&t, "store ") == 5, t.as_str());
    let x: []u64 = [10];
    same_result(&b, &a, "top", x, 52);
}

// A callee whose packing makes vectors inlines as it was before the packing: the caller's slots become
// values, which the callee's vector accesses of them would prevent; the callee's own body keeps its vectors.
@test
fn a_packed_callee_inlines_unpacked() {
    let (b, a) = optimized_with(
        M"(lir ptr 8
sym @x2 fn global
sym @top fn global
fn @x2
  sig (ptr, ptr, ptr) -> void
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.i64 v1 align 3
  v4 = load.i64 v1+8 align 3
  v5 = load.i64 v2 align 3
  v6 = load.i64 v2+8 align 3
  v7 = xor.i64 v3, v5
  v8 = xor.i64 v4, v6
  store v7, v0 align 3
  store v8, v0+8 align 3
  ret
fn @top
  sig (i64, i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
  slot s2 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  store v0, v2 align 3
  store v1, v2+8 align 3
  store v1, v3 align 3
  store v0, v3+8 align 3
  call @x2(v4, v2, v3) : (ptr, ptr, ptr) -> void
  v5 = load.i64 v4 align 3
  v6 = load.i64 v4+8 align 3
  v7 = add.i64 v5, v6
  ret v7
)",
        0,
        false,
        4,
    );
    let f = text_of(&a, "x2");
    assert(count_of(&f, "xor.v2i64") == 1, f.as_str());
    let t = text_of(&a, "top");
    assert(count_of(&t, "slotaddr") == 0 && count_of(&t, "v2i64") == 0 && count_of(&t, "call") == 0, t.as_str());
    let x: []u64 = [0x0F0F, 0x3C3C];
    same_result(&b, &a, "top", x, 2 * (0x0F0F ^ 0x3C3C));
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
        lu::Budgets {
            peel: 300,
            partial: 0,
            version: 200,
            version_checks: u32::MAX,
            unswitch: 50,
            rotate: 8,
            vector: 4,
            interleave: 4,
            fin: 0,
        },
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

// A call of the C library's `fabsf` reads and writes no memory and comes back (`ir::pure_libm`): two calls
// of one value, a store between them, are one call.
@test
fn calls_of_exact_c_math_number_as_values() {
    let (_, a) = optimized(
        M"(lir ptr 8
sym @fabsf fn global
sym @f fn global noinline
fn @f
  sig (ptr, f32) -> f32
b0(v0: ptr, v1: f32):
  v2 = call.f32 @fabsf(v1) : (f32) -> f32
  store v2, v0 align 2
  v3 = call.f32 @fabsf(v1) : (f32) -> f32
  v4 = fadd.f32 v2, v3
  ret v4
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "call.f32 @fabsf") == 1, t.as_str());
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
sym @sunk data global
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
  v2 = symaddr @sunk
  store v1, v2 align 3
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
data @sunk size 8 align 3
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
    let body = block_at(&m, mul as usize);
    assert(!body.contains(", v0 ") && !body.contains("load.i64 v0"), m.as_str());
    let n = text_of(&a, "mixany");
    let nmul = n.as_str().find("mul.i64");
    assert(nmul >= 0 && block_at(&n, nmul as usize).contains("load.i64 v0"), n.as_str());
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

// A call whose callee keeps no pointer it is passed (`Sym.esc`: no store of it, no return, no pass to a
// call that keeps it) leaves an exclusive parameter's class in place: a load of the referent still leaves
// a later loop that writes elsewhere. The call writes the class: a load after it reads the referent
// again. A callee that passes the pointer on to one that keeps it lets it escape.
@test
fn a_call_that_keeps_no_pointer_leaves_the_exclusive_class() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @bump fn global noinline
sym @look fn global noinline
sym @stash fn global noinline
sym @keep fn global noinline
sym @after fn global noinline
sym @hoist fn global noinline
sym @leaky fn global noinline
sym @drive fn global
sym @kept data global
data @kept size 8 align 3
fn @bump
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
  ret
fn @look
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0+8 align 3
  ret v1
fn @stash
  sig (ptr) -> void
b0(v0: ptr):
  v1 = symaddr @kept
  store v0, v1 align 3
  ret
fn @keep
  sig (ptr) -> void
b0(v0: ptr):
  call @stash(v0) : (ptr) -> void
  ret
fn @after
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = iconst.i64 5
  store v1, v0 align 3
  call @bump(v0) : (ptr) -> void
  v2 = load.i64 v0 align 3
  ret v2
fn @hoist
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = call.i64 @look(v0) : (ptr) -> i64
  jmp b1(v1, v3)
b1(v4: i64, v5: i64):
  v6 = load.i64 v0+8 align 3
  v7 = icmp.ult v4, v6
  br v7, b2, b3
b2:
  v8 = load.ptr v0 align 3
  v9 = ptradd v8, v4 * 8
  store v6, v9 align 3
  v10 = add.i64 v5, v6
  v11 = add.i64 v4, v2
  jmp b1(v11, v10)
b3:
  ret v5
fn @leaky
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  call @keep(v0) : (ptr) -> void
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
  v3 = iconst.i64 7
  store v3, v0 align 3
  v4 = call.i64 @after(v0) : (ptr) -> i64
  store v1, v0 align 3
  store v2, v0+8 align 3
  v5 = call.i64 @hoist(v0) : (ptr) -> i64
  v6 = call.i64 @leaky(v0) : (ptr) -> i64
  v7 = add.i64 v4, v5
  v8 = add.i64 v7, v6
  ret v8
)",
    );
    let h = text_of(&a, "hoist");
    let at = h.as_str().find("load.i64 v0+8");
    assert(at >= 0 && at < h.as_str().find("b1("), h.as_str());
    let l = text_of(&a, "leaky");
    assert(l.as_str().find("load.i64 v0+8") > l.as_str().find("b1("), l.as_str());
    let f = text_of(&a, "after");
    assert(f.as_str().find("load.i64 v0") > f.as_str().find("call @bump"), f.as_str());
    let mut e = leval::Eval::new(&b);
    let o = e.run(b.find_symbol("drive"), []);
    let mut e2 = leval::Eval::new(&a);
    let o2 = e2.run(a.find_symbol("drive"), []);
    assert(o.kind == leval::EV_OK && o2.kind == leval::EV_OK && o.value == o2.value, o2.msg.as_str());
}

// A pointer passed as a variadic argument escapes (`Sym.esc`): the callee's accesses do not show what it
// does with it, here keep it. The exclusive parameter loses its class, so the load of its referent stays
// in the loop that writes through the kept pointer.
@test
fn a_variadic_argument_escapes() {
    let (_, a) = optimized(
        M"(lir ptr 8
sym @vkeep fn global noinline
sym @leaky fn global noinline
sym @kept data global
data @kept size 8 align 3
fn @vkeep
  sig (i32, ...) -> void
  slot s0 size 32 align 3
b0(v0: i32):
  v1 = slotaddr s0
  vastart v1
  v2 = vaarg.ptr v1
  vaend v1
  v3 = symaddr @kept
  store v2, v3 align 3
  ret
fn @leaky
  sig (ptr) -> i64
  ref p0 16 noalias
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i32 1
  call @vkeep(v3, v0) : (i32, ... ptr) -> void
  jmp b1(v1, v1)
b1(v4: i64, v5: i64):
  v6 = load.i64 v0+8 align 3
  v7 = icmp.ult v4, v6
  br v7, b2, b3
b2:
  v8 = symaddr @kept
  v9 = load.ptr v8 align 3
  store v4, v9+8 align 3
  v10 = add.i64 v5, v6
  v11 = add.i64 v4, v2
  jmp b1(v11, v10)
b3:
  ret v5
)",
    );
    let l = text_of(&a, "leaky");
    assert(l.as_str().find("load.i64 v0+8") > l.as_str().find("b1("), l.as_str());
}

// A call passed an offset into an exclusive referent reaches only the bytes its callee reaches through
// that parameter, moved by the offset (`Sym.span`; through the calls it makes too): a field it does not
// reach keeps its value across the call, which moves past the load (`field`, `relayed`), and the store
// before the call goes when the callee comes back. A callee that reaches back before its pointer
// (`behind`), or recurses at offsets that never settle (`cycle`), makes the field load again; a callee
// that may not come back keeps the store (`kept`), and so does one that reads the field (`peeks`).
@test
fn a_call_keeps_the_fields_its_callee_does_not_reach() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @bump fn global noinline
sym @back fn global noinline
sym @relay fn global noinline
sym @walk fn global noinline
sym @halt fn global noinline
sym @peek fn global noinline
sym @field fn global noinline
sym @behind fn global noinline
sym @relayed fn global noinline
sym @cycle fn global noinline
sym @kept fn global noinline
sym @peeks fn global noinline
sym @drive fn global
fn @bump
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 3
  v3 = add.i32 v1, v2
  store v3, v0 align 2
  ret
fn @back
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i32 v0-4 align 2
  v2 = iconst.i32 3
  v3 = add.i32 v1, v2
  store v3, v0-4 align 2
  ret
fn @relay
  sig (ptr) -> void
b0(v0: ptr):
  v1 = ptradd v0+4
  call @bump(v1) : (ptr) -> void
  ret
fn @walk
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b1, b2
b1:
  ret
b2:
  store v2, v0 align 2
  v4 = ptradd v0-4
  call @walk(v4) : (ptr) -> void
  ret
fn @halt
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b1, b2
b1:
  unreachable
b2:
  v4 = iconst.i32 3
  v5 = add.i32 v1, v4
  store v5, v0 align 2
  ret
fn @peek
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0-4 align 2
  ret v1
fn @field
  sig (ptr) -> i32
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i32 1
  v2 = load.i32 v0 align 2
  v3 = add.i32 v2, v1
  store v3, v0 align 2
  v4 = ptradd v0+4
  call @bump(v4) : (ptr) -> void
  v5 = load.i32 v0 align 2
  v6 = add.i32 v5, v1
  store v6, v0 align 2
  ret v6
fn @behind
  sig (ptr) -> i32
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i32 1
  v2 = load.i32 v0 align 2
  v3 = add.i32 v2, v1
  store v3, v0 align 2
  v4 = ptradd v0+4
  call @back(v4) : (ptr) -> void
  v5 = load.i32 v0 align 2
  v6 = add.i32 v5, v1
  store v6, v0 align 2
  ret v6
fn @relayed
  sig (ptr) -> i32
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i32 1
  v2 = load.i32 v0 align 2
  v3 = add.i32 v2, v1
  store v3, v0 align 2
  call @relay(v0) : (ptr) -> void
  v4 = load.i32 v0 align 2
  v5 = add.i32 v4, v1
  store v5, v0 align 2
  ret v5
fn @cycle
  sig (ptr) -> i32
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i32 1
  v2 = load.i32 v0 align 2
  v3 = add.i32 v2, v1
  store v3, v0 align 2
  v4 = ptradd v0+4
  call @walk(v4) : (ptr) -> void
  v5 = load.i32 v0 align 2
  v6 = add.i32 v5, v1
  store v6, v0 align 2
  ret v6
fn @kept
  sig (ptr) -> i32
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i32 1
  store v1, v0 align 2
  v2 = ptradd v0+4
  call @halt(v2) : (ptr) -> void
  v3 = load.i32 v0 align 2
  v4 = add.i32 v3, v1
  store v4, v0 align 2
  ret v4
fn @peeks
  sig (ptr) -> i32
  ref p0 8 noalias
b0(v0: ptr):
  v1 = iconst.i32 1
  store v1, v0 align 2
  v2 = ptradd v0+4
  v3 = call.i32 @peek(v2) : (ptr) -> i32
  v4 = load.i32 v0 align 2
  v5 = add.i32 v4, v3
  store v5, v0 align 2
  ret v5
fn @drive
  sig () -> i32
  slot s0 size 16 align 3
b0:
  v0 = slotaddr s0
  v1 = ptradd v0+8
  v2 = iconst.i32 0
  v3 = iconst.i32 5
  v4 = iconst.i32 7
  store v2, v0+4 align 2
  store v3, v0+8 align 2
  store v4, v0+12 align 2
  v5 = call.i32 @cycle(v1) : (ptr) -> i32
  store v4, v0+12 align 2
  v6 = call.i32 @field(v1) : (ptr) -> i32
  v7 = call.i32 @behind(v1) : (ptr) -> i32
  v8 = call.i32 @relayed(v1) : (ptr) -> i32
  v9 = call.i32 @kept(v1) : (ptr) -> i32
  v10 = call.i32 @peeks(v1) : (ptr) -> i32
  v11 = load.i32 v0+12 align 2
  v12 = add.i32 v5, v6
  v13 = add.i32 v12, v7
  v14 = add.i32 v13, v8
  v15 = add.i32 v14, v9
  v16 = add.i32 v15, v10
  v17 = add.i32 v16, v11
  ret v17
)",
    );
    let keeps: [str; 2] = ["field", "relayed"];
    for name in keeps {
        let t = text_of(&a, name);
        assert(count_of(&t, "load.i32") == 1 && count_of(&t, "store") == 1, t.as_str());
        assert(t.as_str().find("load.i32") > t.as_str().find("call @"), t.as_str());
    }
    let loads: [str; 2] = ["behind", "cycle"];
    for name in loads {
        let t = text_of(&a, name);
        assert(count_of(&t, "load.i32") == 2 && count_of(&t, "store") == 2, t.as_str());
    }
    let stores: [str; 2] = ["kept", "peeks"];
    for name in stores {
        let t = text_of(&a, name);
        assert(count_of(&t, "store") == 2, t.as_str());
    }
    // cycle 1 (walk clears both fields), field 3, behind 8, relayed 10, kept 2, peeks 2, the second field 16.
    let none: []u64 = [];
    same_result(&b, &a, "drive", none, 42);
}

// An inlined call's exclusive parameter rooted at an offset into the caller's (`Body.scopes`) escapes
// through a call argument in its copy, though the callee keeps no pointer (`Sym.esc`): the copy's loads
// fold onto the caller's parameter, and the call writes them. The buffer pointer and capacity of the
// inlined `push` stay in the loop past `grow`, which replaces them.
@test
fn an_inlined_scope_passed_to_a_call_that_keeps_no_pointer_escapes() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "grow.spc"
sym @grow fn global noinline
sym @push fn global
sym @fill fn global noinline
sym @top fn global
sym @small data global
sym @big data global
data @small size 8 align 3
data @big size 64 align 3
fn @grow
  sig (ptr) -> void
b0(v0: ptr):
  v1 = symaddr @big
  store v1, v0 align 3
  v2 = iconst.i64 8
  store v2, v0+16 align 3
  ret
fn @push
  sig (ptr, i64) -> void
  ref p0 24 noalias
b0(v0: ptr, v1: i64):
  v2 = load.i64 v0+8 align 3
  v3 = load.i64 v0+16 align 3
  v4 = icmp.eq v2, v3
  br v4, b1, b2
b1:
  call @grow(v0) : (ptr) -> void
  jmp b2
b2:
  v5 = load.ptr v0 align 3
  v6 = load.i64 v0+8 align 3
  v7 = ptradd v5, v6 * 8
  store v1, v7 align 3
  v8 = iconst.i64 1
  v9 = add.i64 v6, v8
  store v9, v0+8 align 3
  ret
fn @fill
  file f0
  sig (ptr, i64) -> i64
  ref p0 32 noalias
b0(v0: ptr, v1: i64):
  v2 = ptradd v0+8
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  call @push(v2, v5) : (ptr, i64) -> void !7:5
  v7 = add.i64 v5, v4
  jmp b1(v7)
b3:
  v8 = load.i64 v0+16 align 3
  ret v8
fn @top
  sig (i64) -> i64
  slot s0 size 32 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = symaddr @small
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  store v3, v1 align 3
  store v2, v1+8 align 3
  store v3, v1+16 align 3
  store v4, v1+24 align 3
  v5 = call.i64 @fill(v1, v0) : (ptr, i64) -> i64
  v6 = symaddr @big
  v7 = load.i64 v6+24 align 3
  v8 = add.i64 v5, v7
  ret v8
)",
    );
    let t = text_of(&a, "fill");
    assert(t.contains("scope") && !t.contains("call @push"), t.as_str());
    let x: [u64; 1] = [4];
    same_result(&b, &a, "top", x, 4 + 3);
}

// `x == 32 || x == 9 || x == 10 || x == 13` (the `||` diamonds made selects, not threaded apart, then an
// `or` of equalities): a range test and a shift of the set's mask.
@test
fn an_or_of_equalities_is_a_bit_test() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i8) -> i8
b0(v0: i8):
  v1 = iconst.i8 32
  v2 = iconst.i8 9
  v3 = iconst.i8 10
  v4 = iconst.i8 13
  v5 = icmp.eq v0, v1
  br v5, b2(v5), b1
b1:
  v6 = icmp.eq v0, v2
  jmp b2(v6)
b2(v7: i8):
  br v7, b4(v7), b3
b3:
  v8 = icmp.eq v0, v3
  jmp b4(v8)
b4(v9: i8):
  br v9, b6(v9), b5
b5:
  v10 = icmp.eq v0, v4
  jmp b6(v10)
b6(v11: i8):
  ret v11
)",
    );
    let t = text_of(&a, "f");
    assert(t.contains("lshr.i64") && !t.contains("br ") && !t.contains("icmp.eq"), t.as_str());
    let xs: [u64; 9] = [9, 10, 13, 32, 0, 8, 11, 41, 255];
    for i in 0..9 {
        let x: [u64; 1] = [xs[i]];
        same_result(&b, &a, "f", x, (i < 4) as u64);
    }
}

// A place the loop reaches on its first pass only after a check (`d[0] += a[k]` over an exclusive `Vector`
// `d`: `d.len() == 0` panics) stays in a register through a guard before the loop (`Opt::guarded`): the
// header's test on the entry values (an empty `a` reads nothing, not even through `d`'s null buffer), then the
// check, to its panic, then the place's load. The loop stores nothing and its sum vectorizes. Every path
// gives the original's result: an empty loop, the panic, the sums.
@test
fn a_checked_place_stays_in_a_register_through_a_guard() {
    let src = M"(lir ptr 8
sym @sum2 fn global
sym @drive fn global
fn @sum2
  sig (ptr, ptr) -> void
  ref p0 24 noalias
  ref p1 24 readonly
  owned p0 0
  owned p1 0
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = load.i64 v1+8 align 3 tbaa 4
  v5 = load.ptr v1 align 3 tbaa 8
  v6 = load.i64 v0+8 align 3 tbaa 4
  v7 = icmp.eq v6, v2
  v8 = load.ptr v0 align 3 tbaa 8
  jmp b1(v2)
b1(v9: i64):
  v10 = icmp.ult v9, v4
  br v10, b3, b2
b2:
  ret
b3:
  v11 = ptradd v5, v9 * 4
  v12 = load.i32 v11 align 2 tbaa 3
  br v7, b5, b4
b4:
  v13 = load.i32 v8 align 2 tbaa 3
  v14 = add.i32 v13, v12
  store v14, v8 align 2 tbaa 3
  v15 = add.i64 v9, v3
  jmp b1(v15)
b5: cold
  panic "index out of bounds"
fn @drive
  sig (i64, i64) -> i32
  slot s0 size 24 align 3
  slot s1 size 24 align 3
  slot s2 size 64 align 2
  slot s3 size 4 align 2
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = slotaddr s3
  v6 = iconst.i32 10
  store v6, v5 align 2
  v7 = iconst.i64 0
  v8 = iconst.i64 1
  v9 = iconst.i64 16
  jmp b1(v7)
b1(v10: i64):
  v11 = icmp.ult v10, v9
  br v11, b2, b3
b2:
  v12 = ptradd v4, v10 * 4
  v13 = trunc.i32 v10
  v14 = mul.i32 v13, v13
  store v14, v12 align 2
  v15 = add.i64 v10, v8
  jmp b1(v15)
b3:
  v16 = icmp.eq v1, v7
  v17 = iconst.ptr 0
  v18 = select.ptr v16, v17, v5
  store v18, v2 align 3
  store v1, v2+8 align 3
  store v4, v3 align 3
  store v0, v3+8 align 3
  call @sum2(v2, v3) : (ptr, ptr) -> void
  v19 = load.i32 v5 align 2
  ret v19
)";
    let bu = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 4,
        interleave: 4,
        fin: 0,
    };
    let (b, a) = optimized_loops(src, 0, false, bu);
    // (the length of `a`, the length of `d`): an empty `a` with an empty `d`, one with a non-empty `d`, a
    // non-empty `a` with an empty `d` (the panic), sums of 1, 4, 5, 13 and 16 squares.
    let cases: [(u64, u64); 8] = [(0, 0), (0, 1), (3, 0), (1, 1), (4, 1), (5, 1), (13, 1), (16, 1)];
    for k in 0..8usize {
        let (n, dl) = unsafe cases[k];
        let xs: [u64; 2] = [n, dl];
        let mut e = leval::Eval::new(&b);
        let o = e.run(b.find_symbol("drive"), xs);
        let mut e2 = leval::Eval::new(&a);
        let o2 = e2.run(a.find_symbol("drive"), xs);
        assert_eq(o2.kind, o.kind);
        let mut want: u64 = 10;
        for q in 0..n {
            want += q * q;
        }
        if n != 0 && dl == 0 {
            assert(o.kind != leval::EV_OK, "the panic");
        } else {
            assert_eq(o.kind, leval::EV_OK);
            assert_eq(o.value & 0xFFFFFFFF, want);
            assert_eq(o2.value & 0xFFFFFFFF, want);
        }
    }
    let ts = text_of(&a, "sum2");
    assert(ts.contains("add.v4i32") && count_of(&ts, "store") == 1, ts.as_str());
}

// Switches lowered (`Package.switch_tree`): a dense one whose edges pass constants to one block left a
// switch (the backends read a table), one of sparse ranges to range tests, one of three values whose edges
// pass constants to one block (one through a block that only jumps there) to a table in a register, and
// one of few sparse values left a switch. For a backend without tables (`Package.switch_tables`, wasm32's
// `br_table`) the dense one lowers too, as does one whose cases reach the block through blocks that only
// jump there (`classf`: no case passes an argument before the first walk merges those blocks); their two
// letter ranges, which differ in bit 5 alone, are one test of the value without it (`and.i8`).
@test
fn switches_become_range_tests_and_tables() {
    let src = M"(lir ptr 8
sym @class fn global
sym @classf fn global
sym @ranges fn global
sym @table fn global
sym @sparse fn global
fn @class
  sig (i8) -> i32
b0(v0: i8):
  v1 = iconst.i32 0
  v2 = iconst.i32 2
  v3 = iconst.i32 1
  v4 = iconst.i32 3
  switch v0 [48 -> b1(v2), 49 -> b1(v2), 50 -> b1(v2), 51 -> b1(v2), 52 -> b1(v2), 53 -> b1(v2), 54 -> b1(v2), 55 -> b1(v2), 56 -> b1(v2), 57 -> b1(v2), 65 -> b1(v3), 66 -> b1(v3), 67 -> b1(v3), 68 -> b1(v3), 69 -> b1(v3), 70 -> b1(v3), 71 -> b1(v3), 72 -> b1(v3), 73 -> b1(v3), 74 -> b1(v3), 75 -> b1(v3), 76 -> b1(v3), 77 -> b1(v3), 78 -> b1(v3), 79 -> b1(v3), 80 -> b1(v3), 81 -> b1(v3), 82 -> b1(v3), 83 -> b1(v3), 84 -> b1(v3), 85 -> b1(v3), 86 -> b1(v3), 87 -> b1(v3), 88 -> b1(v3), 89 -> b1(v3), 90 -> b1(v3), 97 -> b1(v3), 98 -> b1(v3), 99 -> b1(v3), 100 -> b1(v3), 101 -> b1(v3), 102 -> b1(v3), 103 -> b1(v3), 104 -> b1(v3), 105 -> b1(v3), 106 -> b1(v3), 107 -> b1(v3), 108 -> b1(v3), 109 -> b1(v3), 110 -> b1(v3), 111 -> b1(v3), 112 -> b1(v3), 113 -> b1(v3), 114 -> b1(v3), 115 -> b1(v3), 116 -> b1(v3), 117 -> b1(v3), 118 -> b1(v3), 119 -> b1(v3), 120 -> b1(v3), 121 -> b1(v3), 122 -> b1(v3), 9 -> b1(v4), 10 -> b1(v4), 32 -> b1(v4)] else b1(v1)
b1(v5: i32):
  ret v5
fn @classf
  sig (i8) -> i32
b0(v0: i8):
  v1 = iconst.i32 0
  v2 = iconst.i32 2
  v3 = iconst.i32 1
  v4 = iconst.i32 3
  switch v0 [48 -> b2, 49 -> b2, 50 -> b2, 51 -> b2, 52 -> b2, 53 -> b2, 54 -> b2, 55 -> b2, 56 -> b2, 57 -> b2, 65 -> b3, 66 -> b3, 67 -> b3, 68 -> b3, 69 -> b3, 70 -> b3, 71 -> b3, 72 -> b3, 73 -> b3, 74 -> b3, 75 -> b3, 76 -> b3, 77 -> b3, 78 -> b3, 79 -> b3, 80 -> b3, 81 -> b3, 82 -> b3, 83 -> b3, 84 -> b3, 85 -> b3, 86 -> b3, 87 -> b3, 88 -> b3, 89 -> b3, 90 -> b3, 97 -> b3, 98 -> b3, 99 -> b3, 100 -> b3, 101 -> b3, 102 -> b3, 103 -> b3, 104 -> b3, 105 -> b3, 106 -> b3, 107 -> b3, 108 -> b3, 109 -> b3, 110 -> b3, 111 -> b3, 112 -> b3, 113 -> b3, 114 -> b3, 115 -> b3, 116 -> b3, 117 -> b3, 118 -> b3, 119 -> b3, 120 -> b3, 121 -> b3, 122 -> b3, 9 -> b4, 10 -> b4, 32 -> b4] else b5
b1(v5: i32):
  ret v5
b2:
  jmp b1(v2)
b3:
  jmp b1(v3)
b4:
  jmp b1(v4)
b5:
  jmp b1(v1)
fn @ranges
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 2
  v3 = iconst.i32 1
  switch v0 [48 -> b1(v2), 49 -> b1(v2), 50 -> b1(v2), 51 -> b1(v2), 52 -> b1(v2), 53 -> b1(v2), 54 -> b1(v2), 55 -> b1(v2), 56 -> b1(v2), 57 -> b1(v2), 1000 -> b1(v3), 1001 -> b1(v3), 1002 -> b1(v3), 1003 -> b1(v3), 1004 -> b1(v3), 1005 -> b1(v3), 1006 -> b1(v3), 1007 -> b1(v3), 1008 -> b1(v3), 1009 -> b1(v3), 1010 -> b1(v3)] else b1(v1)
b1(v4: i32):
  ret v4
fn @table
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 7
  v3 = iconst.i32 33
  v4 = iconst.i32 10
  switch v0 [0 -> b1(v4), 1 -> b1(v3), 2 -> b2] else b3
b1(v5: i32):
  ret v5
b2:
  jmp b1(v2)
b3:
  jmp b1(v1)
fn @sparse
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 3
  v3 = iconst.i32 9
  v4 = iconst.i32 4
  switch v0 [1 -> b1(v2), 1000 -> b1(v3), 77777 -> b1(v4)] else b2
b1(v5: i32):
  ret v5
b2:
  v6 = iconst.i32 6
  v7 = mul.i32 v0, v6
  ret v7
)";
    let none = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 0,
        interleave: 0,
        fin: 0,
    };
    let (b, a) = optimized_split(src, 0, false, il::SPEED, none, false, true);
    let tc = text_of(&a, "class");
    assert(tc.contains("switch"), tc.as_str());
    let mut err = String::new();
    let mut w = lparse::parse(src, &mut err).unwrap();
    w.switch_tree = true;
    w.switch_tables = false;
    let no = Vector::<bool>::new();
    lopt::optimize(&mut w, &no, lopt::Config { inline: il::SPEED, loops: none });
    for name in ["class", "classf"] {
        let tw = text_of(&w, name);
        assert(!tw.contains("switch") && tw.contains("icmp.ule") && tw.contains("and.i8 v0"), tw.as_str());
    }
    for x in 0..256u64 {
        let c = x as u8;
        let want: u64 = if c >= 48 && c <= 57 {
            2
        } else if c >= 65 && c <= 90 || c >= 97 && c <= 122 {
            1
        } else if c == 9 || c == 10 || c == 32 {
            3
        } else {
            0
        };
        let xs: [u64; 1] = [x];
        same_result(&b, &a, "class", xs, want);
        same_result(&b, &w, "class", xs, want);
        same_result(&b, &w, "classf", xs, want);
    }
    let tr = text_of(&a, "ranges");
    assert(!tr.contains("switch") && tr.contains("icmp.ule"), tr.as_str());
    for x in 0..1100u64 {
        let want: u64 = if x >= 48 && x <= 57 {
            2
        } else if x >= 1000 && x <= 1010 {
            1
        } else {
            0
        };
        let xs: [u64; 1] = [x];
        same_result(&b, &a, "ranges", xs, want);
    }
    let tt = text_of(&a, "table");
    assert(!tt.contains("switch") && !tt.contains("br ") && tt.contains("select"), tt.as_str());
    let want: [u64; 5] = [10, 33, 7, 0, 0];
    for x in 0..5u64 {
        let xs: [u64; 1] = [x];
        same_result(&b, &a, "table", xs, want[x as usize]);
    }
    let big: [u64; 1] = [0xFFFFFFFF];
    same_result(&b, &a, "table", big, 0);
    let ts = text_of(&a, "sparse");
    assert(ts.contains("switch"), ts.as_str());
}

// `@associative_math` lets one function's float sums reassociate (`Body.fmath`): its loop's sum keeps a
// vector of partial sums (`reduce_add`) while the same loop without it adds in order; a function without
// it inlined into one with it would reassociate too, so it stays a call there. The results match the
// debug build's (the inputs are halves, exact in any order).
const ASSOC_FN: str = M"(@noinline
@associative_math
fn am_fast(s: []f32) f32 {
    let mut t: f32 = 0.0;
    for i in 0..s.len() {
        t += s[i];
    }
    return t;
}

@noinline
fn am_exact(s: []f32) f32 {
    let mut t: f32 = 0.0;
    for i in 0..s.len() {
        t += s[i];
    }
    return t;
}

fn am_inner(s: []f32) f32 {
    let mut t: f32 = 0.0;
    for i in 0..s.len() {
        t += s[i];
    }
    return t;
}

@noinline
@associative_math
fn am_outer(s: []f32) f32 {
    return am_inner(s) * 2.0;
}

fn main() i32 {
    let mut a: [f32; 64] = [0.0; 64];
    for i in 0..64 {
        a[i] = i as f32 * 0.5;
    }
    println("{} {} {} {}", am_fast(a[0..64]), am_exact(a[0..64]), am_outer(a[0..64]), am_inner(a[0..9]));
    return 0;
}
)";

@test
fn associative_math_reassociates_its_function_alone() {
    h::expect_same_output("associative math", ASSOC_FN, ["--profile=debug"], ["--profile=release"]);
    let p = cli::proj_new();
    p.mkfile("main.spc", ASSOC_FN);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "am_", "build -O2 main.spc -o app");
    let fast = printed(r.text(), "am_fast");
    let exact = printed(r.text(), "am_exact");
    let outer = printed(r.text(), "am_outer");
    let ok = r.ok() && fast.contains("reduce_add") && fast.contains("fmath 1") && !exact.contains("reduce_add") && !exact.contains(
        "fmath",
    ) && outer.contains("call") && !outer.contains("reduce_add");
    if !ok {
        r.show();
    }
    assert(ok, "the attributed function's sum reassociates; the others add in order");
    let q = cli::proj_new();
    q.mkfile("main.spc", "@associative_math\nstruct S {\n    x: f32,\n}\n\nfn main() i32 {\n    return 0;\n}\n");
    let e = cli::superc_in(q.dir(), "build main.spc -o app");
    assert(!e.ok() && e.text().contains("may only be applied to a function with a body"), e.text());
}

// Locals of scopes whose storage never overlaps share one slot of their size (`share_plan`): `seq`'s two
// scopes' locals, one slot; `both`'s locals live at once keep two. A store into a local that nothing reads
// before its scope ends goes (`dead_stores`: `x.n = 7`), one a call may read stays (`y.n = 9` before `sum`).
const SCOPE_SLOTS: str = M"(struct Big {
    a: [u64; 16],
    n: u64,
}

@noinline
fn fill(b: &mut Big, k: u64) {
    for i in 0..16 {
        b.a[i] = k + i as u64;
    }
}

@noinline
fn sum(b: &Big) u64 {
    let mut s = b.n;
    for i in 0..16 {
        s += b.a[i];
    }
    return s;
}

@noinline
fn sc_seq(k: u64) u64 {
    let mut t: u64 = 0;
    {
        let mut x = Big { a: [0; 16], n: 1 };
        fill(&mut x, k);
        t += sum(&x);
        x.n = 7;
    }
    {
        let mut y = Big { a: [0; 16], n: 2 };
        fill(&mut y, k + 1);
        y.n = 9;
        t += sum(&y);
    }
    return t;
}

@noinline
fn sc_both(k: u64) u64 {
    let mut x = Big { a: [0; 16], n: 1 };
    fill(&mut x, k);
    let mut y = Big { a: [0; 16], n: 2 };
    fill(&mut y, k + 1);
    return sum(&x) + sum(&y);
}

fn main() i32 {
    println("{} {}", sc_seq(3), sc_both(5));
    return 0;
}
)";

@test
fn scope_locals_share_slots_and_drop_dead_stores() {
    h::expect_same_output("scope slots", SCOPE_SLOTS, ["--profile=debug"], ["--profile=release"]);
    let p = cli::proj_new();
    p.mkfile("main.spc", SCOPE_SLOTS);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "sc_", "build -O2 main.spc -o app");
    let seq = printed(r.text(), "sc_seq");
    let both = printed(r.text(), "sc_both");
    let ok = r.ok() && seq.contains("slot s0 size 136") && !seq.contains("slot s1") && !seq.contains("iconst.i64 7") && seq.contains(
        "iconst.i64 9",
    ) && both.find("size 136") != String::from_str(both).rfind("size 136") as isize;
    if !ok {
        r.show();
    }
    assert(ok, "the scopes share a slot; the dead store goes, the read one stays; overlapping locals keep two");
}

// Addresses in bounds of one base (`inbounds`) compare as their offsets: `p + i * 4 <u p + n * 4` is
// `i <s n`, and two constant offsets decide the comparison. Without the flag, or through a step that may
// leave the object (`p + 8` not in bounds, then in bounds of that), the comparison stays.
@test
fn in_bounds_addresses_compare_as_their_offsets() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @cmp fn global
sym @plain fn global
sym @consts fn global
sym @mixed fn global
fn @cmp
  sig (ptr, i64, i64) -> i8
b0(v0: ptr, v1: i64, v2: i64):
  v3 = ptradd v0, v1 * 4 inbounds
  v4 = ptradd v0, v2 * 4 inbounds
  v5 = icmp.ult v3, v4
  ret v5
fn @plain
  sig (ptr, i64, i64) -> i8
b0(v0: ptr, v1: i64, v2: i64):
  v3 = ptradd v0, v1 * 4
  v4 = ptradd v0, v2 * 4
  v5 = icmp.ult v3, v4
  ret v5
fn @consts
  sig (ptr) -> i8
b0(v0: ptr):
  v1 = ptradd v0+8 inbounds
  v2 = ptradd v0+4 inbounds
  v3 = icmp.ugt v1, v2
  ret v3
fn @mixed
  sig (ptr) -> i8
b0(v0: ptr):
  v1 = ptradd v0+8
  v2 = ptradd v1+8 inbounds
  v3 = ptradd v0+4 inbounds
  v4 = icmp.ugt v2, v3
  ret v4
)",
    );
    let tc = text_of(&a, "cmp");
    assert(tc.contains("icmp.slt v1, v2") && !tc.contains("ptradd"), tc.as_str());
    let tp = text_of(&a, "plain");
    assert(tp.contains("icmp.ult") && tp.contains("ptradd"), tp.as_str());
    let tk = text_of(&a, "consts");
    assert(!tk.contains("icmp"), tk.as_str());
    let tm = text_of(&a, "mixed");
    assert(tm.contains("icmp.ugt"), tm.as_str());
    let xs: [u64; 3] = [4096, 3, 9];
    same_result(&b, &a, "cmp", xs, 1);
    same_result(&b, &a, "plain", xs, 1);
    let ys: [u64; 3] = [4096, 9, 3];
    same_result(&b, &a, "cmp", ys, 0);
    let p: [u64; 1] = [4096];
    same_result(&b, &a, "consts", p, 1);
    same_result(&b, &a, "mixed", p, 1);
}

// The language's addresses are in bounds of their bases (`inbounds`): two raw pointers one base's
// arithmetic makes compare as their indices.
const RAW_COMPARES: str = M"(@noinline
fn raw_before(p: *const u32, i: usize, n: usize) bool {
    return unsafe { (p + i) < (p + n) };
}

fn main() i32 {
    let a: [u32; 4] = [1, 2, 3, 4];
    println("{} {}", raw_before(&a[0], 1, 3), raw_before(&a[0], 3, 1));
    return 0;
}
)";

@test
fn raw_pointers_of_one_base_compare_as_their_indices() {
    h::expect_same_output("raw compares", RAW_COMPARES, ["--profile=debug"], ["--profile=release"]);
    let p = cli::proj_new();
    p.mkfile("main.spc", RAW_COMPARES);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "raw_before", "build -O2 main.spc -o app");
    let f = printed(r.text(), "raw_before");
    let ok = r.ok() && f.contains("icmp.slt") && !f.contains("ptradd");
    if !ok {
        r.show();
    }
    assert(ok, "the comparison of the addresses is one of the indices");
}

// Enum tags in memory: a payload-less enum's value and a payload enum's tag load with their greatest
// discriminant (`range`), an enum with a negative discriminant's without. Built in release, a comparison
// the bound decides folds and a switch over every variant reads a table with no range test; the results
// match the debug build's for every variant.
const ENUM_TAGS: str = M"(enum Color {
    Red,
    Green,
    Blue,
    Black,
}

enum Shape {
    Circle(f64),
    Rect(f64, f64),
    Dot,
}

enum Signed {
    Low = -1,
    Zero,
    One,
}

@noinline
fn tag_name(c: &Color) i32 {
    return switch *c {
        Color::Red => 10,
        Color::Green => 27,
        Color::Blue => 33,
        Color::Black => 41,
    };
}

@noinline
fn tag_small(c: &Color) bool {
    return (*c as i32) < 4;
}

@noinline
fn tag_area(s: &Shape) f64 {
    return switch *s {
        Shape::Circle(r) => r * r,
        Shape::Rect(a, b) => a * b,
        Shape::Dot => 0.0,
    };
}

@noinline
fn tag_signed(s: &Signed) i32 {
    return *s as i32 + 1;
}

fn main() i32 {
    let cs: [Color; 4] = [Color::Red, Color::Green, Color::Blue, Color::Black];
    for c in cs {
        print("{} {} ", tag_name(&c), tag_small(&c));
    }
    let ss: [Shape; 3] = [Shape::Circle(2.0), Shape::Rect(2.0, 3.0), Shape::Dot];
    for s in ss {
        print("{} ", tag_area(&s));
    }
    let gs: [Signed; 3] = [Signed::Low, Signed::Zero, Signed::One];
    for g in gs {
        print("{} ", tag_signed(&g));
    }
    println("");
    return 0;
}
)";

@test
fn enum_tags_load_with_their_greatest_discriminant() {
    h::expect_same_output("enum tags", ENUM_TAGS, ["--profile=debug"], ["--profile=release"]);
    let p = cli::proj_new();
    p.mkfile("main.spc", ENUM_TAGS);
    let r = cli::superc_env_in(p.dir(), "SC_LIR_PRINT", "tag_", "build -O2 main.spc -o app");
    let name = printed(r.text(), "tag_name");
    let small = printed(r.text(), "tag_small");
    let area = printed(r.text(), "tag_area");
    let signed = printed(r.text(), "tag_signed");
    let ok = r.ok() && name.contains("range 3") && !name.contains("icmp") && !small.contains("icmp") && area.contains(
        "range 2",
    ) && signed.contains("load") && !signed.contains("range");
    if !ok {
        r.show();
    }
    assert(ok, "the tags load bounded; the bound decides the comparisons and the table's range");
}

// A load of an enum's tag carries its greatest discriminant (`range`): a comparison that every value up to
// it answers alike folds (a signed one too, the bound clear of the sign bit), and a switch on it lowered
// to a table in a register spans to the bound, with no range test. The same code on a load without the
// bound keeps both.
@test
fn bounded_loads_decide_comparisons_and_switch_tables() {
    let (b, a) = optimized_split(
        M"(lir ptr 8
sym @cmp fn global noinline
sym @plain fn global noinline
sym @name fn global noinline
sym @plain_name fn global noinline
sym @drive fn global
sym @TAG data global
fn @cmp
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i8 v0 align 0 range 3
  v2 = zext.i32 v1
  v3 = iconst.i32 4
  v4 = icmp.slt v2, v3
  v5 = iconst.i8 7
  v6 = icmp.ne v1, v5
  v7 = and.i8 v4, v6
  v8 = zext.i32 v7
  ret v8
fn @plain
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i8 v0 align 0
  v2 = zext.i32 v1
  v3 = iconst.i32 4
  v4 = icmp.slt v2, v3
  v5 = iconst.i8 7
  v6 = icmp.ne v1, v5
  v7 = and.i8 v4, v6
  v8 = zext.i32 v7
  ret v8
fn @name
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i8 v0 align 0 range 3
  v2 = iconst.i32 10
  v3 = iconst.i32 27
  v4 = iconst.i32 33
  v5 = iconst.i32 41
  switch v1 [0 -> b1(v2), 1 -> b1(v3), 2 -> b1(v4)] else b1(v5)
b1(v6: i32):
  ret v6
fn @plain_name
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i8 v0 align 0
  v2 = iconst.i32 10
  v3 = iconst.i32 27
  v4 = iconst.i32 33
  v5 = iconst.i32 41
  switch v1 [0 -> b1(v2), 1 -> b1(v3), 2 -> b1(v4)] else b1(v5)
b1(v6: i32):
  ret v6
fn @drive
  sig (i8) -> i32
b0(v0: i8):
  v1 = symaddr @TAG
  store v0, v1 align 0
  v2 = call.i32 @name(v1) : (ptr) -> i32
  v3 = call.i32 @cmp(v1) : (ptr) -> i32
  v4 = call.i32 @plain(v1) : (ptr) -> i32
  v5 = call.i32 @plain_name(v1) : (ptr) -> i32
  v6 = iconst.i32 100
  v7 = mul.i32 v2, v6
  v8 = add.i32 v7, v3
  v9 = mul.i32 v8, v6
  v10 = add.i32 v9, v4
  v11 = mul.i32 v10, v6
  v12 = add.i32 v11, v5
  ret v12
data @TAG size 1 align 0
)",
        0,
        false,
        il::SPEED,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
        false,
        true,
    );
    let tc = text_of(&a, "cmp");
    assert(!tc.contains("icmp") && !tc.contains("load"), tc.as_str());
    let tp = text_of(&a, "plain");
    assert(tp.contains("icmp"), tp.as_str());
    let tn = text_of(&a, "name");
    assert(!tn.contains("icmp") && !tn.contains("select") && tn.contains("lshr"), tn.as_str());
    let tq = text_of(&a, "plain_name");
    assert(tq.contains("icmp") && tq.contains("select"), tq.as_str());
    let names: [u64; 4] = [10, 27, 33, 41];
    for x in 0..4u64 {
        let xs: [u64; 1] = [x];
        same_result(&b, &a, "drive", xs, ((names[x as usize] * 100 + 1) * 100 + 1) * 100 + names[x as usize]);
    }
}

// A sum or difference of a constant and another of a constant is one sum (`(x + 1) + 1` is `x + 2`).
@test
fn chained_constant_sums_combine() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = iconst.i32 3
  v3 = iconst.i32 5
  v4 = add.i32 v0, v1
  v5 = add.i32 v4, v1
  v6 = sub.i32 v5, v2
  v7 = add.i32 v6, v3
  ret v7
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "add.") + count_of(&t, "sub.") == 1 && t.contains("iconst.i32 4"), t.as_str());
    let x: []u64 = [10];
    same_result(&b, &a, "f", x, 14);
    let y: []u64 = [0xFFFFFFFE];
    same_result(&b, &a, "f", y, 2);
}

// A branch edge into a block that only returns its parameter returns from a block of its own, but one edge
// into that block stays.
@test
fn branch_edges_into_a_return_return_at_once() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @g fn global noinline
sym @f fn global
fn @g
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 9
  v2 = mul.i64 v0, v1
  ret v2
fn @f
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 10
  v2 = iconst.i64 20
  v3 = iconst.i64 5
  v4 = iconst.i64 7
  v5 = icmp.ult v0, v1
  br v5, b1(v3), b2
b1(v6: i64):
  ret v6
b2:
  v7 = call.i64 @g(v0) : (i64) -> i64
  v8 = icmp.ult v7, v2
  br v8, b1(v4), b3
b3:
  v9 = call.i64 @g(v7) : (i64) -> i64
  ret v9
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "ret ") == 3 && t.contains("ret v3") && t.contains("b1(v4)"), t.as_str());
    let x: []u64 = [3];
    same_result(&b, &a, "f", x, 5);
    let y: []u64 = [11];
    same_result(&b, &a, "f", y, 891);
    let z: []u64 = [1];
    same_result(&b, &a, "f", z, 5);
}

// An indirect call through a function's address is a direct call of it, which inlines; not when the call's
// signature differs from the function's (`other`).
@test
fn calls_through_a_known_address_are_direct() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @add1 fn global
sym @f fn global
sym @other fn global
fn @add1
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = add.i32 v0, v1
  ret v2
fn @f
  sig (i32) -> i32
b0(v0: i32):
  v1 = symaddr @add1
  v2 = call.ind.i32 v1(v0) : (i32) -> i32
  ret v2
fn @other
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @add1
  v2 = call.ind.i64 v1(v0) : (i64) -> i64
  ret v2
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("call"), t.as_str());
    let x: []u64 = [41];
    same_result(&b, &a, "f", x, 42);
    let o = text_of(&a, "other");
    assert(o.contains("call.ind"), o.as_str());
}

// A slot only constants of disjoint bytes are stored into, which only loads read, is read-only data of its
// own; not one two stores overlap in (`twice`), nor one whose address a call takes (`out`).
@test
fn constant_slots_become_read_only_data() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @keep fn global noinline
sym @lut fn global
sym @twice fn global
sym @out fn global
fn @keep
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  ret v1
fn @lut
  sig (i64) -> i32
  slot s0 size 16 align 2
b0(v0: i64):
  v1 = iconst.i64 4294967299
  v2 = iconst.i64 25769803778
  v3 = slotaddr s0
  v4 = iconst.i64 3
  v5 = and.i64 v0, v4
  store v1, v3 align 2
  store v2, v3+8 align 2
  v6 = ptradd v3, v5 * 4
  v7 = load.i32 v6 align 2
  ret v7
fn @twice
  sig (i64) -> i32
  slot s0 size 8 align 2
b0(v0: i64):
  v1 = iconst.i64 4294967299
  v2 = iconst.i32 7
  v3 = slotaddr s0
  v4 = iconst.i64 1
  v5 = and.i64 v0, v4
  store v1, v3 align 2
  store v2, v3+4 align 2
  v6 = ptradd v3, v5 * 4
  v7 = load.i32 v6 align 2
  ret v7
fn @out
  sig () -> i32
  slot s0 size 4 align 2
b0:
  v0 = iconst.i32 5
  v1 = slotaddr s0
  store v0, v1 align 2
  v2 = call.i32 @keep(v1) : (ptr) -> i32
  ret v2
)",
    );
    let t = text_of(&a, "lut");
    assert(t.contains("symaddr") && !t.contains("store") && !t.contains("slotaddr"), t.as_str());
    let want: [u64; 4] = [3, 1, 2, 6];
    for i in 0..4 {
        let x: []u64 = [i as u64 + 4];
        same_result(&b, &a, "lut", x, want[i]);
    }
    let w = text_of(&a, "twice");
    assert(w.contains("slotaddr") || !w.contains("symaddr"), w.as_str());
    let one: []u64 = [1];
    same_result(&b, &a, "twice", one, 7);
    let o = text_of(&a, "out");
    assert(!o.contains("symaddr @out"), o.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "out", none, 5);
}

// A branch between two blocks that compute the same values and jump alike is a jump to one (`twins`):
// the flag that chose between them is then dead. A block that differs in one constant stays.
@test
fn identical_branch_targets_merge() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
sym @g fn global
fn @f
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 1
  jmp b1(v0, v2, v1)
b1(v5: i64, v6: i64, v7: i8):
  v8 = icmp.eq v5, v2
  br v8, b5, b2
b2:
  br v7, b3, b4
b3:
  v9 = sub.i64 v5, v3
  v10 = add.i64 v6, v5
  v11 = xor.i8 v7, v4
  jmp b1(v9, v10, v11)
b4:
  v12 = sub.i64 v5, v3
  v13 = add.i64 v6, v5
  v14 = xor.i8 v7, v4
  jmp b1(v12, v13, v14)
b5:
  ret v6
fn @g
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 1
  jmp b1(v0, v2, v1)
b1(v5: i64, v6: i64, v7: i8):
  v8 = icmp.eq v5, v2
  br v8, b5, b2
b2:
  br v7, b3, b4
b3:
  v9 = sub.i64 v5, v3
  v10 = add.i64 v6, v5
  v11 = xor.i8 v7, v4
  jmp b1(v9, v10, v11)
b4:
  v12 = sub.i64 v5, v3
  v13 = add.i64 v6, v3
  v14 = add.i64 v13, v3
  v15 = xor.i8 v7, v4
  jmp b1(v12, v14, v15)
b5:
  ret v6
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("xor."), t.as_str());
    let u = text_of(&a, "g");
    assert(u.contains("xor."), u.as_str());
    let x: []u64 = [10, 0];
    same_result(&b, &a, "f", x, 55);
    let y: []u64 = [10, 1];
    same_result(&b, &a, "f", y, 55);
    let z: []u64 = [5, 1];
    same_result(&b, &a, "g", z, 5 + 2 + 3 + 2 + 1);
}

// A reference parameter (`ref`) is never null: its equality with 0 folds. A pointer parameter's stays.
@test
fn a_reference_parameter_is_not_null() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr, ptr) -> i8
  ref p0 4 readonly
b0(v0: ptr, v1: ptr):
  v2 = iconst.ptr 0
  v3 = icmp.eq v0, v2
  v4 = icmp.ne v2, v0
  v5 = icmp.eq v1, v2
  v6 = and.i8 v4, v5
  v7 = or.i8 v3, v6
  ret v7
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "icmp.") == 1 && t.contains("icmp.eq v1"), t.as_str());
    let x: []u64 = [16, 0];
    same_result(&b, &a, "f", x, 1);
    let y: []u64 = [16, 32];
    same_result(&b, &a, "f", y, 0);
}

// A `memcmp` of a small count whose result only an equality with 0 reads is a compare of loads (a 4-byte
// and a 1-byte one each for 5 bytes, one for 4); a count a branch into the block settles counts too, and a
// load of read-only bytes is their constant. A result an ordering reads is the order of the first pair of
// loads that differs (17 bytes: three pairs); an equality past 64 bytes keeps the call.
@test
fn small_memory_compares_expand() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @memcmp fn global
sym @s data global
sym @r data global
sym @w data global
sym @eq5 fn global
sym @starts fn global
sym @less fn global
sym @long fn global
sym @huge fn global
fn @eq5
  sig (i64) -> i8
b0(v0: i64):
  v1 = symaddr @s
  v2 = symaddr @w
  v3 = iconst.i64 5
  v4 = iconst.i32 0
  v5 = iconst.i8 0
  v6 = ptradd v2, v0 * 1
  v7 = icmp.ne v0, v3
  br v7, b2, b1
b1:
  v8 = call.i32 @memcmp(v6, v1, v0) : (ptr, ptr, i64) -> i32
  v9 = icmp.eq v8, v4
  ret v9
b2:
  ret v5
fn @starts
  sig (i64) -> i8
b0(v0: i64):
  v1 = symaddr @r
  v2 = symaddr @w
  v3 = iconst.i64 4
  v4 = iconst.i32 0
  v5 = ptradd v2, v0 * 1
  v6 = call.i32 @memcmp(v5, v1, v3) : (ptr, ptr, i64) -> i32
  v7 = icmp.ne v4, v6
  ret v7
fn @less
  sig (i64) -> i8
b0(v0: i64):
  v1 = symaddr @s
  v2 = symaddr @w
  v3 = iconst.i64 5
  v4 = iconst.i32 0
  v5 = ptradd v2, v0 * 1
  v6 = call.i32 @memcmp(v5, v1, v3) : (ptr, ptr, i64) -> i32
  v7 = icmp.slt v6, v4
  ret v7
fn @long
  sig (i64) -> i8
b0(v0: i64):
  v1 = symaddr @s
  v2 = symaddr @w
  v3 = iconst.i64 17
  v4 = iconst.i32 0
  v5 = ptradd v2, v0 * 1
  v6 = call.i32 @memcmp(v5, v1, v3) : (ptr, ptr, i64) -> i32
  v7 = icmp.sgt v6, v4
  ret v7
fn @huge
  sig (i64) -> i8
b0(v0: i64):
  v1 = symaddr @s
  v2 = symaddr @w
  v3 = iconst.i64 65
  v4 = iconst.i32 0
  v5 = ptradd v2, v0 * 1
  v6 = call.i32 @memcmp(v5, v1, v3) : (ptr, ptr, i64) -> i32
  v7 = icmp.eq v6, v4
  ret v7
data @s size 40 align 0 ro bytes 68656c6c6f68656c6c6f68656c6c6f68656c6c6f0000000000000000000000000000000000000000
data @r size 4 align 0 ro bytes 68747470
data @w size 64 align 0 bytes 68656c6c6f68656c6c6f68656c6c6f68656c6c6f68747470680000000000000000000000000000000000000000000000000000000000000000000000
)",
    );
    let e = text_of(&a, "eq5");
    assert(!e.contains("call") && count_of(&e, "load.i32") == 1 && count_of(&e, "load.i8") == 1, e.as_str());
    let s = text_of(&a, "starts");
    assert(!s.contains("call") && count_of(&s, "load.i32") == 1 && !s.contains("symaddr @r"), s.as_str());
    assert(!text_of(&a, "less").contains("call"), text_of(&a, "less").as_str());
    let g = text_of(&a, "long");
    assert(!g.contains("call") && count_of(&g, "load.i64") == 3, g.as_str());
    assert(text_of(&a, "huge").contains("call"), text_of(&a, "huge").as_str());
    let x: []u64 = [5];
    same_result(&b, &a, "eq5", x, 1);
    let y: []u64 = [4];
    same_result(&b, &a, "eq5", y, 0);
    let z: []u64 = [20];
    same_result(&b, &a, "starts", z, 0);
    let z2: []u64 = [19];
    same_result(&b, &a, "starts", z2, 1);
    // `w` from each offset against "hellohello...": equal, a lower first byte, a higher one, a higher later
    // byte; the 17-byte compare differs in its first, middle and last pairs.
    let offs: [u64; 8] = [0, 1, 2, 10, 15, 20, 24, 28];
    let less: [u64; 8] = [0, 1, 0, 0, 0, 0, 1, 1];
    let more: [u64; 8] = [0, 0, 1, 1, 1, 1, 0, 0];
    for q in 0..8 {
        let o: []u64 = [offs[q]];
        same_result(&b, &a, "less", o, less[q]);
        same_result(&b, &a, "long", o, more[q]);
    }
}

// An unused call of a function that writes no memory goes whatever body the optimizer ran before: the
// list of an instruction's values starts empty (`@kept`'s return reads its call `v1`, the number of
// `@dead`'s call).
@test
fn an_unused_pure_call_goes_after_any_body() {
    let (_b, a) = optimized(
        M"(lir ptr 8
sym @square fn global noinline
sym @kept fn global
sym @dead fn global
fn @square
  sig (i32) -> i32
b0(v0: i32):
  v1 = mul.i32 v0, v0
  ret v1
fn @kept
  sig (i32) -> i32
b0(v0: i32):
  v1 = call.i32 @square(v0) : (i32) -> i32
  ret v1
fn @dead
  sig (i32) -> i32
b0(v0: i32):
  v1 = call.i32 @square(v0) : (i32) -> i32
  v2 = iconst.i32 1
  v3 = add.i32 v0, v2
  ret v3
)",
    );
    let d = text_of(&a, "dead");
    assert(!d.contains("call"), d.as_str());
}

// A store of part of a constant's bytes keeps the others: one store set two 4-byte fields (a vector's
// length and capacity on a 32-bit target), a store sets one, a load of the other reads the constant's
// part, low or high. A call or a store of another type between the stores may write them: the load
// does not read the constant's part.
@test
fn a_partly_overwritten_constant_keeps_its_other_bytes() {
    let (_b, a) = optimized(
        M"(lir ptr 4
sym @low fn global
sym @high fn global
sym @called fn global
sym @tagged fn global
sym @opaque fn global
fn @low
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = iconst.i64 30064771077
  store v2, v0 align 3
  store v1, v0+4 align 2
  v3 = load.i32 v0 align 2
  ret v3
fn @high
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = iconst.i64 30064771077
  store v2, v0 align 3
  store v1, v0 align 2
  v3 = load.i32 v0+4 align 2
  ret v3
fn @called
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = iconst.i64 30064771077
  store v2, v0 align 3
  call @opaque() : () -> void
  store v1, v0+4 align 2
  v3 = load.i32 v0 align 2
  ret v3
fn @tagged
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = iconst.i64 30064771077
  store v2, v0 align 3
  v3 = iconst.i16 9
  store v3, v0 align 1 tbaa 2
  store v1, v0+4 align 2
  v4 = load.i32 v0 align 2
  ret v4
)",
    );
    let l = text_of(&a, "low");
    assert(!l.contains("load") && l.contains("iconst.i32 5"), l.as_str());
    let h = text_of(&a, "high");
    assert(!h.contains("load") && h.contains("iconst.i32 7"), h.as_str());
    assert(text_of(&a, "called").contains("load"), text_of(&a, "called").as_str());
    assert(!text_of(&a, "tagged").contains("iconst.i32 5"), text_of(&a, "tagged").as_str());
}

// An allocation only stores write through, a null test reads and one free takes on every path to a return
// goes with them, its test folding as for a block that exists; so does a `realloc` of null. One freed twice,
// or not on every path, or whose pointer a load reads, stays, and so does a `realloc` of a block that may
// exist, which frees that block.
@test
fn an_unread_allocation_goes() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @malloc fn global
sym @free fn global
sym @abort fn global
sym @boxed fn global
sym @twice fn global
sym @leaks fn global
sym @realloc fn global
sym @fresh fn global
sym @grows fn global
fn @boxed
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = iconst.ptr 0
  v3 = iconst.i64 4
  v4 = call.ptr @malloc(v3) : (i64) -> ptr
  v5 = icmp.eq v4, v2
  br v5, b1, b2
b1: unlikely
  call @abort() : () -> void
  unreachable
b2:
  store v0, v4 align 2
  v6 = add.i32 v0, v1
  call @free(v4) : (ptr) -> void
  ret v6
fn @twice
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i64 4
  v2 = call.ptr @malloc(v1) : (i64) -> ptr
  store v0, v2 align 2
  call @free(v2) : (ptr) -> void
  call @free(v2) : (ptr) -> void
  ret v0
fn @leaks
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i64 4
  v2 = iconst.i32 0
  v3 = call.ptr @malloc(v1) : (i64) -> ptr
  store v0, v3 align 2
  v4 = icmp.eq v0, v2
  br v4, b1, b2
b1:
  ret v0
b2:
  call @free(v3) : (ptr) -> void
  ret v0
fn @fresh
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.ptr 0
  v2 = iconst.i64 4
  v3 = call.ptr @realloc(v1, v2) : (ptr, i64) -> ptr
  store v0, v3 align 2
  call @free(v3) : (ptr) -> void
  ret v0
fn @grows
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = iconst.i64 8
  v3 = call.ptr @realloc(v0, v2) : (ptr, i64) -> ptr
  store v1, v3 align 2
  call @free(v3) : (ptr) -> void
  ret v1
)",
    );
    let t = text_of(&a, "boxed");
    assert(!t.contains("call") && !t.contains("store"), t.as_str());
    assert(text_of(&a, "twice").contains("@malloc"), text_of(&a, "twice").as_str());
    assert(text_of(&a, "leaks").contains("@malloc"), text_of(&a, "leaks").as_str());
    assert(!text_of(&a, "fresh").contains("call"), text_of(&a, "fresh").as_str());
    assert(text_of(&a, "grows").contains("@realloc"), text_of(&a, "grows").as_str());
    let x: []u64 = [41];
    same_result(&b, &a, "boxed", x, 42);
}

// A by-value aggregate parameter a loop writes (a tail recursion's) becomes a slot the entry copies it
// into, then values the loop carries: no load or store stays in the loop. One passed to a call stays.
@test
fn a_written_aggregate_parameter_becomes_values() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @fib fn global
sym @keep fn global noinline
sym @kept fn global
fn @fib
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (i32, l0) -> i64
b0(v0: i32, v1: ptr):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  v4 = icmp.eq v0, v2
  br v4, b2, b1(v0)
b1(v5: i32):
  v6 = sub.i32 v5, v3
  v7 = load.i64 v1 align 3
  v8 = load.i64 v1+8 align 3
  v9 = add.i64 v7, v8
  store v8, v1 align 3
  store v9, v1+8 align 3
  v10 = icmp.eq v6, v2
  br v10, b2, b1(v6)
b2:
  v11 = load.i64 v1 align 3
  ret v11
fn @keep
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  ret v1
fn @kept
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = iconst.i64 7
  store v1, v0 align 3
  v2 = call.i64 @keep(v0) : (ptr) -> i64
  ret v2
)",
    );
    let t = text_of(&a, "fib");
    assert(count_of(&t, "load.") == 2 && !t.contains("store") && !t.contains("slot"), t.as_str());
    assert(text_of(&a, "kept").contains("store"), text_of(&a, "kept").as_str());
}

// Stores of pieces of one value that cover 2, 4 or 8 of its bytes in order are one store of those bytes:
// bytes, halves in any store order, the high word of a 64-bit value; byte stores in the reverse order store
// the bytes reversed. A load between them keeps them apart, as does a run of 3 bytes.
@test
fn byte_stores_of_one_value_combine() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @le fn global
sym @be fn global
sym @apart fn global
sym @halves fn global
sym @high fn global
sym @be4 fn global
sym @three fn global
fn @le
  sig (ptr, i32) -> void
b0(v0: ptr, v1: i32):
  v2 = iconst.i32 8
  v3 = iconst.i32 16
  v4 = iconst.i32 24
  v5 = trunc.i8 v1
  store v5, v0 align 0
  v6 = lshr.i32 v1, v2
  v7 = trunc.i8 v6
  store v7, v0+1 align 0
  v8 = lshr.i32 v1, v3
  v9 = trunc.i8 v8
  store v9, v0+2 align 0
  v10 = lshr.i32 v1, v4
  v11 = trunc.i8 v10
  store v11, v0+3 align 0
  ret
fn @be
  sig (ptr, i16) -> void
b0(v0: ptr, v1: i16):
  v2 = iconst.i16 8
  v3 = lshr.i16 v1, v2
  v4 = trunc.i8 v3
  store v4, v0+4 align 0
  v5 = trunc.i8 v1
  store v5, v0+5 align 0
  ret
fn @halves
  sig (ptr, i32) -> void
b0(v0: ptr, v1: i32):
  v2 = iconst.i32 16
  v3 = lshr.i32 v1, v2
  v4 = trunc.i16 v3
  store v4, v0+2 align 0
  v5 = trunc.i16 v1
  store v5, v0 align 0
  ret
fn @high
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 32
  v3 = iconst.i64 40
  v4 = iconst.i64 48
  v5 = iconst.i64 56
  v6 = lshr.i64 v1, v2
  v7 = trunc.i8 v6
  store v7, v0+8 align 0
  v8 = lshr.i64 v1, v3
  v9 = trunc.i8 v8
  store v9, v0+9 align 0
  v10 = lshr.i64 v1, v4
  v11 = trunc.i8 v10
  store v11, v0+10 align 0
  v12 = lshr.i64 v1, v5
  v13 = trunc.i8 v12
  store v13, v0+11 align 0
  ret
fn @be4
  sig (ptr, i32) -> void
b0(v0: ptr, v1: i32):
  v2 = iconst.i32 8
  v3 = iconst.i32 16
  v4 = iconst.i32 24
  v5 = lshr.i32 v1, v4
  v6 = trunc.i8 v5
  store v6, v0 align 0
  v7 = lshr.i32 v1, v3
  v8 = trunc.i8 v7
  store v8, v0+1 align 0
  v9 = lshr.i32 v1, v2
  v10 = trunc.i8 v9
  store v10, v0+2 align 0
  v11 = trunc.i8 v1
  store v11, v0+3 align 0
  ret
fn @three
  sig (ptr, i32) -> void
b0(v0: ptr, v1: i32):
  v2 = iconst.i32 8
  v3 = iconst.i32 16
  v4 = trunc.i8 v1
  store v4, v0 align 0
  v5 = lshr.i32 v1, v2
  v6 = trunc.i8 v5
  store v6, v0+1 align 0
  v7 = lshr.i32 v1, v3
  v8 = trunc.i8 v7
  store v8, v0+2 align 0
  ret
fn @apart
  sig (ptr, i16) -> i8
b0(v0: ptr, v1: i16):
  v2 = iconst.i16 8
  v3 = trunc.i8 v1
  store v3, v0 align 0
  v4 = load.i8 v0+1 align 0
  v5 = lshr.i16 v1, v2
  v6 = trunc.i8 v5
  store v6, v0+1 align 0
  ret v4
)",
    );
    let l = text_of(&a, "le");
    assert(count_of(&l, "store ") == 1 && l.contains("store v1, v0 align 0"), l.as_str());
    let e = text_of(&a, "be");
    assert(count_of(&e, "store ") == 1 && e.contains("bswap.i16") && e.contains("v0+4"), e.as_str());
    let g = text_of(&a, "apart");
    assert(count_of(&g, "store ") == 2, g.as_str());
    let h = text_of(&a, "halves");
    assert(count_of(&h, "store ") == 1 && h.contains("store v1, v0 align 0"), h.as_str());
    let hi = text_of(&a, "high");
    assert(count_of(&hi, "store ") == 1 && hi.contains("trunc.i32") && hi.contains("v0+8"), hi.as_str());
    let e4 = text_of(&a, "be4");
    assert(count_of(&e4, "store ") == 1 && e4.contains("bswap.i32"), e4.as_str());
    let th = text_of(&a, "three");
    assert(count_of(&th, "store ") >= 2, th.as_str());
}

// A pointer load from read-only data at a relocation's place (a method of a conformance table) is that
// symbol's address, and the call through it is direct; a writable table's load stays.
@test
fn a_method_a_constant_table_holds_is_called_directly() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @area fn global noinline
sym @vtbl data global
sym @wtbl data global
sym @f fn global
sym @g fn global
fn @area
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 3
  v3 = mul.i32 v1, v2
  ret v3
fn @f
  sig (i32) -> i32
  slot s0 size 4 align 2
b0(v0: i32):
  v1 = slotaddr s0
  store v0, v1 align 2
  v2 = symaddr @vtbl
  v3 = load.ptr v2+8 align 3
  v4 = call.ind.i32 v3(v1) : (ptr) -> i32
  ret v4
fn @g
  sig (i32) -> i32
  slot s0 size 4 align 2
b0(v0: i32):
  v1 = slotaddr s0
  store v0, v1 align 2
  v2 = symaddr @wtbl
  v3 = load.ptr v2+8 align 3
  v4 = call.ind.i32 v3(v1) : (ptr) -> i32
  ret v4
data @vtbl size 16 align 3 ro bytes 00000000000000000000000000000000 reloc 8 @area
data @wtbl size 16 align 3 bytes 00000000000000000000000000000000 reloc 8 @area
)",
    );
    let f = text_of(&a, "f");
    assert(f.contains("call.i32 @area") && !f.contains("load.ptr"), f.as_str());
    let g = text_of(&a, "g");
    assert(g.contains("call.ind") && g.contains("load.ptr"), g.as_str());
    let x: []u64 = [7];
    same_result(&b, &a, "f", x, 21);
}

// A body waits for the functions of the read-only tables it names (`Calls`): a call through one that the
// walk makes direct (`fold_ptr`) inlines as a direct call does (`Run::direct_known`). `@f`'s call of `@area`
// through `@vtbl` is gone, the product in its place; `@g`'s, through the writable `@wtbl`, stays.
@test
fn a_method_a_constant_table_holds_inlines() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @area fn global
sym @vtbl data global
sym @wtbl data global
sym @f fn global
sym @g fn global
fn @area
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 3
  v3 = mul.i32 v1, v2
  ret v3
fn @f
  sig (i32) -> i32
  slot s0 size 4 align 2
b0(v0: i32):
  v1 = slotaddr s0
  store v0, v1 align 2
  v2 = symaddr @vtbl
  v3 = load.ptr v2+8 align 3
  v4 = call.ind.i32 v3(v1) : (ptr) -> i32
  ret v4
fn @g
  sig (i32) -> i32
  slot s0 size 4 align 2
b0(v0: i32):
  v1 = slotaddr s0
  store v0, v1 align 2
  v2 = symaddr @wtbl
  v3 = load.ptr v2+8 align 3
  v4 = call.ind.i32 v3(v1) : (ptr) -> i32
  ret v4
data @vtbl size 16 align 3 ro bytes 00000000000000000000000000000000 reloc 8 @area
data @wtbl size 16 align 3 bytes 00000000000000000000000000000000 reloc 8 @area
)",
    );
    let f = text_of(&a, "f");
    assert(!f.contains("call") && f.contains("mul.i32") && !f.contains("slotaddr"), f.as_str());
    let g = text_of(&a, "g");
    assert(g.contains("call.ind"), g.as_str());
    let x: []u64 = [7];
    same_result(&b, &a, "f", x, 21);
}

// A body waits for the functions whose address it takes (`Calls`): a call through one that an inlined
// callee's parameter brings becomes direct and inlines (`Run::direct_known`). `@f`'s call of `@add1` through
// `@apply` is gone, the sum in its place; `@apply`'s own call stays indirect.
@test
fn a_function_an_inlined_callee_calls_through_its_address_inlines() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @add1 fn global
sym @apply fn global
sym @f fn global
fn @add1
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = add.i32 v0, v1
  ret v2
fn @apply
  sig (ptr, i32) -> i32
b0(v0: ptr, v1: i32):
  v2 = call.ind.i32 v0(v1) : (i32) -> i32
  ret v2
fn @f
  sig (i32) -> i32
b0(v0: i32):
  v1 = symaddr @add1
  v2 = call.i32 @apply(v1, v0) : (ptr, i32) -> i32
  ret v2
)",
    );
    let f = text_of(&a, "f");
    assert(!f.contains("call") && f.contains("add.i32"), f.as_str());
    let g = text_of(&a, "apply");
    assert(g.contains("call.ind"), g.as_str());
    let x: []u64 = [41];
    same_result(&b, &a, "f", x, 42);
}

// A load of a slot that spans several writes (a tag byte and a payload word, one path filling the payload)
// is a load of each written place combined: the slot then holds values, and the bits each reader takes
// come from their writes.
@test
fn a_load_over_separate_writes_splits() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i32, i32) -> i32
  slot s0 size 8 align 2
b0(v0: i32, v1: i32):
  v2 = iconst.i64 32
  v3 = slotaddr s0
  v4 = iconst.i8 0
  v5 = iconst.i8 1
  v6 = iconst.i64 4
  v7 = iconst.i32 0
  v8 = add.i32 v0, v1
  v9 = icmp.ult v8, v0
  br v9, b2, b1
b1:
  store v4, v3 align 0
  store v8, v3+4 align 2
  jmp b3
b2:
  store v5, v3 align 0
  v10 = ptradd v3+4
  memset v10, v4, v6
  jmp b3
b3:
  v11 = load.i64 v3 align 0
  v12 = trunc.i8 v11
  v13 = zext.i32 v12
  v14 = icmp.eq v13, v7
  v15 = lshr.i64 v11, v2
  v16 = trunc.i32 v15
  v17 = select.i32 v14, v16, v7
  ret v17
)",
    );
    let f = text_of(&a, "f");
    assert(!f.contains("load") && !f.contains("store") && !f.contains("slot") && !f.contains("shl"), f.as_str());
    let x: []u64 = [3, 4];
    same_result(&b, &a, "f", x, 7);
    let y: []u64 = [0xFFFFFFFF, 2];
    same_result(&b, &a, "f", y, 0);
}

// The bits a truncation, a shift or a mask reads: an `or` operand of none of them goes; `x << c >> c` of an
// `x` whose top `c` bits are 0 is `x`; a mask that keeps every bit its operand may have goes; an `or` with
// a value of no possible bit is the other operand. A mask that drops a possible bit stays.
@test
fn bits_no_reader_takes_go() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @lo fn global
sym @hi fn global
sym @mask fn global
sym @kept fn global
fn @lo
  sig (i8, i32) -> i8
b0(v0: i8, v1: i32):
  v2 = iconst.i64 32
  v3 = zext.i64 v0
  v4 = zext.i64 v1
  v5 = shl.i64 v4, v2
  v6 = or.i64 v3, v5
  v7 = trunc.i8 v6
  ret v7
fn @hi
  sig (i8, i32) -> i32
b0(v0: i8, v1: i32):
  v2 = iconst.i64 32
  v3 = zext.i64 v0
  v4 = zext.i64 v1
  v5 = shl.i64 v4, v2
  v6 = xor.i64 v3, v5
  v7 = lshr.i64 v6, v2
  v8 = trunc.i32 v7
  ret v8
fn @mask
  sig (i16) -> i64
b0(v0: i16):
  v1 = iconst.i64 65535
  v2 = iconst.i64 0
  v3 = zext.i64 v0
  v4 = and.i64 v3, v1
  v5 = or.i64 v4, v2
  ret v5
fn @kept
  sig (i16) -> i64
b0(v0: i16):
  v1 = iconst.i64 255
  v2 = zext.i64 v0
  v3 = and.i64 v2, v1
  ret v3
)",
    );
    let l = text_of(&a, "lo");
    assert(!l.contains("or.") && !l.contains("shl"), l.as_str());
    let h = text_of(&a, "hi");
    assert(!h.contains("xor") && !h.contains("shl") && !h.contains("lshr"), h.as_str());
    let m = text_of(&a, "mask");
    assert(!m.contains("and") && !m.contains("or."), m.as_str());
    let k = text_of(&a, "kept");
    assert(k.contains("and"), k.as_str());
    let x: []u64 = [0xAB, 0x12345678];
    same_result(&b, &a, "lo", x, 0xAB);
    same_result(&b, &a, "hi", x, 0x12345678);
    let y: []u64 = [0xBEEF];
    same_result(&b, &a, "mask", y, 0xBEEF);
    same_result(&b, &a, "kept", y, 0xEF);
}

// A select whose arm is a select on a condition the outer one decides takes that arm's decided side: the
// same comparison, its opposite, its mirror (`b > a` for `a < b`), one it implies (`a < b` gives
// `a <= b`); a comparison of the other signedness decides nothing.
@test
fn selects_on_decided_conditions_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @opp fn global
sym @mir fn global
sym @weak fn global
sym @sign fn global
fn @opp
  sig (i32, i32, i32, i32) -> i32
b0(v0: i32, v1: i32, v2: i32, v3: i32):
  v4 = icmp.ult v0, v1
  v5 = select.i32 v4, v2, v3
  v6 = icmp.uge v0, v1
  v7 = select.i32 v6, v5, v2
  ret v7
fn @mir
  sig (i32, i32, i32, i32) -> i32
b0(v0: i32, v1: i32, v2: i32, v3: i32):
  v4 = icmp.slt v0, v1
  v5 = select.i32 v4, v2, v3
  v6 = icmp.sgt v1, v0
  v7 = select.i32 v6, v5, v3
  ret v7
fn @weak
  sig (i32, i32, i32, i32) -> i32
b0(v0: i32, v1: i32, v2: i32, v3: i32):
  v4 = icmp.sle v0, v1
  v5 = select.i32 v4, v2, v3
  v6 = icmp.slt v0, v1
  v7 = select.i32 v6, v5, v3
  ret v7
fn @sign
  sig (i32, i32, i32, i32) -> i32
b0(v0: i32, v1: i32, v2: i32, v3: i32):
  v4 = icmp.ult v0, v1
  v5 = select.i32 v4, v2, v3
  v6 = icmp.slt v0, v1
  v7 = select.i32 v6, v5, v3
  ret v7
)",
    );
    let o = text_of(&a, "opp");
    assert(count_of(&o, "select") == 1 && count_of(&o, "icmp") == 1, o.as_str());
    let m = text_of(&a, "mir");
    assert(count_of(&m, "select") == 1, m.as_str());
    let w = text_of(&a, "weak");
    assert(count_of(&w, "select") == 1 && w.contains("icmp.slt"), w.as_str());
    let s = text_of(&a, "sign");
    assert(count_of(&s, "select") == 2, s.as_str());
    let x: []u64 = [1, 2, 10, 20];
    let y: []u64 = [2, 1, 10, 20];
    let z: []u64 = [0xFFFFFFFF, 1, 10, 20];
    same_result(&b, &a, "opp", x, 10);
    same_result(&b, &a, "opp", y, 20);
    same_result(&b, &a, "mir", x, 10);
    same_result(&b, &a, "mir", y, 20);
    same_result(&b, &a, "weak", x, 10);
    same_result(&b, &a, "weak", y, 20);
    same_result(&b, &a, "sign", z, 20);
}

// A three-way comparison `(x > y) - (x < y)` compared with -1, 0 or 1 is one comparison of `x` and `y` (or
// a constant), signed or unsigned as its parts; a select of such values compared is a select of the
// comparisons. A byte swap or bit count of a constant is a constant.
@test
fn three_way_comparisons_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @neg fn global
sym @pos fn global
sym @never fn global
sym @pick fn global
sym @consts fn global
fn @neg
  sig (i32, i32) -> i8
b0(v0: i32, v1: i32):
  v2 = icmp.sgt v0, v1
  v3 = icmp.slt v0, v1
  v4 = zext.i32 v2
  v5 = zext.i32 v3
  v6 = sub.i32 v4, v5
  v7 = iconst.i32 -1
  v8 = icmp.eq v6, v7
  ret v8
fn @pos
  sig (i64, i64) -> i8
b0(v0: i64, v1: i64):
  v2 = icmp.ugt v0, v1
  v3 = icmp.ugt v1, v0
  v4 = zext.i32 v2
  v5 = zext.i32 v3
  v6 = sub.i32 v4, v5
  v7 = iconst.i32 0
  v8 = icmp.sge v6, v7
  ret v8
fn @never
  sig (i32, i32) -> i8
b0(v0: i32, v1: i32):
  v2 = icmp.sgt v0, v1
  v3 = icmp.slt v0, v1
  v4 = zext.i32 v2
  v5 = zext.i32 v3
  v6 = sub.i32 v4, v5
  v7 = iconst.i32 2
  v8 = icmp.sge v6, v7
  ret v8
fn @pick
  sig (i32, i32, i8) -> i8
b0(v0: i32, v1: i32, v2: i8):
  v3 = icmp.sgt v0, v1
  v4 = icmp.slt v0, v1
  v5 = zext.i32 v3
  v6 = zext.i32 v4
  v7 = sub.i32 v5, v6
  v8 = iconst.i32 5
  v9 = select.i32 v2, v7, v8
  v10 = iconst.i32 0
  v11 = icmp.sgt v9, v10
  ret v11
fn @consts
  sig () -> i32
b0:
  v0 = iconst.i32 287454020
  v1 = bswap.i32 v0
  v2 = popcnt.i32 v1
  v3 = add.i32 v1, v2
  ret v3
)",
    );
    let n = text_of(&a, "neg");
    assert(count_of(&n, "icmp") == 1 && n.contains("icmp.slt v0, v1") && !n.contains("sub"), n.as_str());
    let p = text_of(&a, "pos");
    assert(count_of(&p, "icmp") == 1 && p.contains("icmp.uge v0, v1"), p.as_str());
    let v = text_of(&a, "never");
    assert(!v.contains("icmp"), v.as_str());
    let k = text_of(&a, "pick");
    assert(count_of(&k, "icmp") == 1 && !k.contains("sub"), k.as_str());
    let c = text_of(&a, "consts");
    assert(!c.contains("bswap") && !c.contains("popcnt"), c.as_str());
    let args: [[u64; 2]; 3] = [[1, 2], [2, 2], [3, 0xFFFFFFFF]];
    for q in 0..3 {
        let x: []u64 = [args[q][0], args[q][1]];
        same_result(&b, &a, "neg", x, run_of(&b, "neg", x));
        same_result(&b, &a, "pos", x, run_of(&b, "pos", x));
        same_result(&b, &a, "never", x, 0);
        let y: []u64 = [args[q][0], args[q][1], 1];
        same_result(&b, &a, "pick", y, run_of(&b, "pick", y));
        let z: []u64 = [args[q][0], args[q][1], 0];
        same_result(&b, &a, "pick", z, 1);
    }
    let none: []u64 = [];
    same_result(&b, &a, "consts", none, 0x44332211 + 10);
}

// What function `name` of `p` returns for `args`.
fn run_of(p: &Package, name: str, args: []u64) u64 {
    let mut e = leval::Eval::new(p);
    let o = e.run(p.find_symbol(name), args);
    assert_eq(o.kind, leval::EV_OK);
    return o.value;
}

// A wide integer load over fields combines their bits (an integer and a float's), and the pieces of one
// value joined in place are that value; the walk forwards a wide store's bytes to narrower loads. A wide
// store over two fields keeps its slot, as does a field across a wide load's edge.
@test
fn wide_slot_accesses_promote() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @parts fn global
sym @mixed fn global
sym @across fn global
sym @inside fn global
sym @round fn global
fn @parts
  sig (i64) -> i32
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = load.i8 v1+1 align 0
  v3 = load.i32 v1+4 align 2
  v4 = zext.i32 v2
  v5 = add.i32 v3, v4
  ret v5
fn @mixed
  sig (f32, i32) -> i64
  slot s0 size 8 align 3
b0(v0: f32, v1: i32):
  v2 = slotaddr s0
  store v0, v2 align 2
  store v1, v2+4 align 2
  v3 = load.i64 v2 align 3
  ret v3
fn @across
  sig (i32, i64) -> i64
  slot s0 size 16 align 3
b0(v0: i32, v1: i64):
  v2 = slotaddr s0
  store v1, v2+4 align 0
  store v0, v2 align 2
  v3 = load.i64 v2 align 3
  ret v3
fn @inside
  sig (i32, i32) -> i64
  slot s0 size 16 align 3
b0(v0: i32, v1: i32):
  v2 = slotaddr s0
  store v0, v2 align 2
  store v1, v2+4 align 2
  v3 = load.i64 v2+2 align 0
  ret v3
fn @round
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = load.i8 v1+1 align 0
  v3 = load.i64 v1 align 3
  v4 = zext.i64 v2
  v5 = add.i64 v3, v4
  ret v5
)",
    );
    let p = text_of(&a, "parts");
    assert(!p.contains("slot") && !p.contains("load") && !p.contains("store"), p.as_str());
    let m = text_of(&a, "mixed");
    assert(!m.contains("slot") && m.contains("bitcast"), m.as_str());
    let c = text_of(&a, "across");
    assert(c.contains("slot"), c.as_str());
    let r = text_of(&a, "round");
    assert(!r.contains("slot") && !r.contains("or.") && !r.contains("shl"), r.as_str());
    let d = text_of(&a, "inside");
    assert(d.contains("slot"), d.as_str());
    let x: []u64 = [0x1122334455667788];
    same_result(&b, &a, "parts", x, 0x11223344 + 0x77);
    same_result(&b, &a, "round", x, 0x1122334455667788 + 0x77);
    let y: []u64 = [0x3F800000, 7];
    same_result(&b, &a, "mixed", y, 0x000000073F800000);
    let z: []u64 = [5, 0x0102030405060708];
    same_result(&b, &a, "across", z, 0x0506070800000005);
    let w: []u64 = [0x11223344, 0x55667788];
    same_result(&b, &a, "inside", w, run_of(&b, "inside", w));
}

// A sum compared below one of its addends (either order) is the unsigned addition's carry, and at or above
// it the carry's absence: the addition becomes `addo`, a select on the negated flag swaps its arms. A
// compare with a value that is not an addend stays.
@test
fn sums_below_an_addend_are_carries() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @carry fn global
sym @fits fn global
sym @other fn global
fn @carry
  sig (i32, i32) -> i8
b0(v0: i32, v1: i32):
  v2 = add.i32 v0, v1
  v3 = icmp.ugt v1, v2
  ret v3
fn @fits
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = add.i64 v0, v1
  v4 = icmp.uge v3, v0
  v5 = select.i64 v4, v3, v2
  ret v5
fn @other
  sig (i32, i32, i32) -> i8
b0(v0: i32, v1: i32, v2: i32):
  v3 = add.i32 v0, v1
  v4 = icmp.ult v3, v2
  ret v4
)",
    );
    let c = text_of(&a, "carry");
    assert(c.contains("addo.u.i32") && !c.contains("icmp"), c.as_str());
    let f = text_of(&a, "fits");
    assert(f.contains("addo.u.i64") && !f.contains("icmp"), f.as_str());
    let o = text_of(&a, "other");
    assert(!o.contains("addo") && o.contains("icmp"), o.as_str());
    let x: []u64 = [0xFFFFFFF0, 0x20];
    let y: []u64 = [5, 7];
    same_result(&b, &a, "carry", x, 1);
    same_result(&b, &a, "carry", y, 0);
    let p: []u64 = [0xFFFFFFFFFFFFFFF0, 0x20];
    same_result(&b, &a, "fits", p, 0);
    same_result(&b, &a, "fits", y, 12);
}

// The sign of `(x ^ s) & (y ^ s)` for `s = x + y`, and of `(x ^ y) & (x ^ s)` for `s = x - y`, is the
// signed overflow of `addo` and `subo`; a select by a sign of `~c` or `c` is a shift and an `xor`; a plain
// product beside the checked one on its operands is that one's value.
@test
fn signed_overflow_idioms_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sat fn global
sym @dif fn global
sym @prod fn global
fn @sat
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = iconst.i32 2147483647
  v4 = iconst.i32 -2147483648
  v5 = add.i32 v0, v1
  v6 = xor.i32 v0, v5
  v7 = xor.i32 v5, v1
  v8 = and.i32 v6, v7
  v9 = icmp.sge v8, v2
  v10 = icmp.slt v1, v2
  v11 = select.i32 v10, v4, v3
  v12 = select.i32 v9, v5, v11
  ret v12
fn @dif
  sig (i64, i64) -> i8
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = sub.i64 v0, v1
  v4 = xor.i64 v1, v0
  v5 = xor.i64 v0, v3
  v6 = and.i64 v4, v5
  v7 = icmp.slt v6, v2
  ret v7
fn @prod
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = mul.i64 v0, v1
  v4, v5 = mulo.u.i64 v0, v1
  v6 = select.i64 v5, v2, v3
  ret v6
)",
    );
    let s = text_of(&a, "sat");
    assert(
        s.contains("addo.s.i32") && s.contains("ashr") && !s.contains("icmp") && count_of(&s, "select") == 1,
        s.as_str(),
    );
    let d = text_of(&a, "dif");
    assert(d.contains("subo.s.i64") && !d.contains("icmp"), d.as_str());
    let p = text_of(&a, "prod");
    assert(count_of(&p, "mul") == 1, p.as_str());
    let sv: [[u64; 2]; 4] = [[3, 4], [0x7FFFFFFF, 1], [0x80000000, 0xFFFFFFFF], [0xFFFFFFFE, 1]];
    let sw: [u64; 4] = [7, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF];
    for q in 0..4 {
        let x: []u64 = [sv[q][0], sv[q][1]];
        same_result(&b, &a, "sat", x, sw[q]);
    }
    let dv: [[u64; 2]; 3] = [[5, 3], [0x8000000000000000, 1], [0x7FFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF]];
    let dw: [u64; 3] = [0, 1, 1];
    for q in 0..3 {
        let x: []u64 = [dv[q][0], dv[q][1]];
        same_result(&b, &a, "dif", x, dw[q]);
    }
    let m: []u64 = [6, 7];
    same_result(&b, &a, "prod", m, 42);
    let n: []u64 = [0x100000000, 0x100000000];
    same_result(&b, &a, "prod", n, 0);
}

// An `or` tree of shifts, masks and byte swaps that puts the bits of one value in reverse order is that
// value's `bitrev` (`u8` and `u32` `reverse_bits`); one that swaps nibbles only stays.
@test
fn bit_reversals_are_one_operation() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @r8 fn global
sym @r32 fn global
sym @nib fn global
fn @r8
  sig (i8) -> i8
b0(v0: i8):
  v1 = iconst.i8 4
  v2 = iconst.i8 2
  v3 = iconst.i8 1
  v4 = iconst.i8 51
  v5 = iconst.i8 85
  v6 = lshr.i8 v0, v1
  v7 = shl.i8 v0, v1
  v8 = or.i8 v6, v7
  v9 = lshr.i8 v8, v2
  v10 = and.i8 v9, v4
  v11 = and.i8 v8, v4
  v12 = shl.i8 v11, v2
  v13 = or.i8 v10, v12
  v14 = lshr.i8 v13, v3
  v15 = and.i8 v14, v5
  v16 = and.i8 v13, v5
  v17 = shl.i8 v16, v3
  v18 = or.i8 v15, v17
  ret v18
fn @r32
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 4
  v2 = iconst.i32 2
  v3 = iconst.i32 1
  v4 = iconst.i32 252645135
  v5 = iconst.i32 858993459
  v6 = iconst.i32 1431655765
  v7 = bswap.i32 v0
  v8 = lshr.i32 v7, v1
  v9 = and.i32 v8, v4
  v10 = and.i32 v7, v4
  v11 = shl.i32 v10, v1
  v12 = or.i32 v9, v11
  v13 = lshr.i32 v12, v2
  v14 = and.i32 v13, v5
  v15 = and.i32 v12, v5
  v16 = shl.i32 v15, v2
  v17 = or.i32 v14, v16
  v18 = lshr.i32 v17, v3
  v19 = and.i32 v18, v6
  v20 = and.i32 v17, v6
  v21 = shl.i32 v20, v3
  v22 = or.i32 v21, v19
  ret v22
fn @nib
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 4
  v2 = iconst.i32 252645135
  v3 = lshr.i32 v0, v1
  v4 = and.i32 v3, v2
  v5 = and.i32 v0, v2
  v6 = shl.i32 v5, v1
  v7 = or.i32 v4, v6
  ret v7
)",
    );
    let e = text_of(&a, "r8");
    assert(e.contains("bitrev.i8 v0") && !e.contains("or."), e.as_str());
    let f = text_of(&a, "r32");
    assert(f.contains("bitrev.i32 v0") && !f.contains("bswap"), f.as_str());
    let n = text_of(&a, "nib");
    assert(!n.contains("bitrev"), n.as_str());
    let x: []u64 = [0x01];
    same_result(&b, &a, "r8", x, 0x80);
    let y: []u64 = [0x12345678];
    same_result(&b, &a, "r32", y, 0x1E6A2C48);
}

// Differences that cancel a term: `(x - y) - x` and `x - (x + y)` are `-y` (a constant for a constant
// `y`), `x - (x - y)` is `y`; a product by -1 is a negation, and a sum with a negation a difference.
@test
fn differences_that_cancel_a_term_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
fn @f
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 5
  v3 = sub.i32 v0, v2
  v4 = sub.i32 v3, v0
  v5 = add.i32 v0, v1
  v6 = sub.i32 v0, v5
  v7 = sub.i32 v0, v1
  v8 = sub.i32 v0, v7
  v9 = iconst.i32 -1
  v10 = mul.i32 v8, v9
  v11 = add.i32 v4, v6
  v12 = add.i32 v11, v10
  v13 = add.i32 v12, v8
  ret v13
)",
    );
    let t = text_of(&a, "f");
    assert(!t.contains("mul") && count_of(&t, "sub") + count_of(&t, "add") <= 2, t.as_str());
    let xs: [u64; 3] = [0, 7, 0xFFFFFFF0];
    for p in 0..3 {
        for q in 0..3 {
            let args: []u64 = [xs[p], xs[q]];
            let want = 0xFFFFFFFBu64.wrapping_sub(xs[q]) & 0xFFFFFFFF;
            same_result(&b, &a, "f", args, want);
        }
    }
}

// Package text `text` read, then optimized for a target that copies each by-value aggregate argument of at
// most `arg_copy` bytes itself (`Package.arg_copy`): each body verifies after.
fn optimized_copying(text: str, arg_copy: u32) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.arg_copy = arg_copy;
    let none = Vector::<bool>::new();
    let bu = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 0,
        interleave: 0,
        fin: 0,
    };
    lopt::optimize(&mut after, &none, lopt::Config { inline: il::SPEED, loops: bu });
    let mut v = verify::Verifier::new();
    for i in 0..after.syms.len() {
        let s = after.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check(&after, after.spell(s.name), &after.bodies[s.def as usize]), v.err.as_str());
        }
    }
    return (before, after);
}

// A by-value aggregate argument that a copy into a slot wrote, with no write since, passes the copy's
// source in its place when the target copies such an argument itself (`Package.arg_copy`): `pick`'s copy
// goes. `wrote`'s source changes between the copy and the call, `big`'s aggregate is larger than the
// target copies, and with no `arg_copy` `pick`'s copy stays. The results are the same.
@test
fn copies_into_aggregate_arguments_pass_their_source() {
    let src = M"(lir ptr 8
sym @take fn global noinline
sym @take3 fn global noinline
sym @pick fn global noinline
sym @wrote fn global noinline
sym @big fn global noinline
sym @drive fn global
fn @take
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+8 align 3
  v3 = sub.i64 v1, v2
  ret v3
fn @take3
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+16 align 3
  v3 = sub.i64 v1, v2
  ret v3
fn @pick
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (ptr, i64) -> i64
  slot s0 size 16 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 16
  v4 = ptradd v0, v1 * 16
  memcpy.overlap v2, v4, v3
  v5 = call.i64 @take(v2) : (l0) -> i64
  ret v5
fn @wrote
  layout l0 size 16 align 3 [0 i64, 8 i64]
  sig (ptr, i64) -> i64
  slot s0 size 16 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 16
  v4 = ptradd v0, v1 * 16
  memcpy.overlap v2, v4, v3
  store v1, v4 align 3
  v5 = call.i64 @take(v2) : (l0) -> i64
  ret v5
fn @big
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> i64
  slot s0 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 24
  v4 = ptradd v0, v1 * 24
  memcpy.overlap v2, v4, v3
  v5 = call.i64 @take3(v2) : (l0) -> i64
  ret v5
fn @drive
  sig (i64) -> i64
  slot s0 size 48 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 100
  v3 = iconst.i64 7
  v4 = iconst.i64 1
  store v2, v1 align 3
  store v3, v1+8 align 3
  store v0, v1+16 align 3
  store v4, v1+24 align 3
  store v3, v1+32 align 3
  store v2, v1+40 align 3
  v5 = call.i64 @pick(v1, v4) : (ptr, i64) -> i64
  v6 = call.i64 @wrote(v1, v4) : (ptr, i64) -> i64
  v7 = call.i64 @big(v1, v4) : (ptr, i64) -> i64
  v8 = iconst.i64 1000
  v9 = mul.i64 v6, v8
  v10 = add.i64 v5, v9
  v11 = mul.i64 v7, v8
  v12 = mul.i64 v11, v8
  v13 = add.i64 v10, v12
  ret v13
)";
    let (b, a) = optimized_copying(src, 16);
    let pick = text_of(&a, "pick");
    assert(pick.as_str().find("memcpy") < 0 && pick.as_str().find("slotaddr") < 0, pick.as_str());
    assert(text_of(&a, "wrote").as_str().find("memcpy") >= 0, "a write to the source keeps the copy");
    assert(text_of(&a, "big").as_str().find("memcpy") >= 0, "a larger aggregate keeps its copy");
    // pick: 5 - 1; wrote: 5 - 1, the copy's bytes from before the store, which then writes 1 over the 5;
    // big: 1 - 100.
    let args: [u64; 1] = [5];
    same_result(&b, &a, "drive", args[0..1], (4 + 4 * 1000 - 99 * 1000000i64) as u64);
    let (_, n) = optimized_copying(src, 0);
    assert(text_of(&n, "pick").as_str().find("memcpy") >= 0, "with no arg_copy the copy stays");
}

// A by-value aggregate argument larger than the target copies passes the source of the copy into it when
// the callee neither writes nor keeps its parameter nor compares its address, and nothing writes the source
// during the call: a read-only reference's referent (`ronly`) or an exclusive one no other argument
// reaches (`excl`). The copy stays when the callee compares its parameter's address (`cmpd`), writes its
// parameter (`wrt`), or the source is a shared reference's (`shr`). The results are the same.
@test
fn copies_into_large_aggregate_arguments_pass_a_kept_source() {
    let src = M"(lir ptr 8
sym @take fn global noinline
sym @same fn global noinline
sym @bump fn global noinline
sym @ronly fn global noinline
sym @excl fn global noinline
sym @cmpd fn global noinline
sym @wrt fn global noinline
sym @shr fn global noinline
sym @drive fn global
fn @take
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = load.i64 v0+16 align 3
  v3 = sub.i64 v1, v2
  ret v3
fn @same
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (l0, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = icmp.eq v0, v1
  v3 = zext.i64 v2
  ret v3
fn @bump
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
  v4 = load.i64 v0+16 align 3
  v5 = sub.i64 v3, v4
  ret v5
fn @ronly
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr) -> i64
  ref p0 24 readonly
  slot s0 size 24 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 24
  memcpy.overlap v1, v0, v2
  v3 = call.i64 @take(v1) : (l0) -> i64
  ret v3
fn @excl
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr) -> i64
  ref p0 24 noalias
  slot s0 size 24 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 24
  memcpy.overlap v1, v0, v2
  v3 = call.i64 @take(v1) : (l0) -> i64
  ret v3
fn @cmpd
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr) -> i64
  ref p0 24 readonly
  slot s0 size 24 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 24
  memcpy.overlap v1, v0, v2
  v3 = call.i64 @same(v1, v0) : (l0, ptr) -> i64
  ret v3
fn @wrt
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr) -> i64
  ref p0 24 readonly
  slot s0 size 24 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 24
  memcpy.overlap v1, v0, v2
  v3 = call.i64 @bump(v1) : (l0) -> i64
  ret v3
fn @shr
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr) -> i64
  slot s0 size 24 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 24
  memcpy.overlap v1, v0, v2
  v3 = call.i64 @take(v1) : (l0) -> i64
  ret v3
fn @drive
  sig (i64) -> i64
  slot s0 size 24 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 2
  store v0, v1 align 3
  store v0, v1+8 align 3
  store v2, v1+16 align 3
  v3 = call.i64 @ronly(v1) : (ptr) -> i64
  v4 = call.i64 @excl(v1) : (ptr) -> i64
  v5 = call.i64 @cmpd(v1) : (ptr) -> i64
  v6 = call.i64 @wrt(v1) : (ptr) -> i64
  v7 = call.i64 @shr(v1) : (ptr) -> i64
  v8 = load.i64 v1 align 3
  v9 = add.i64 v3, v4
  v10 = add.i64 v9, v5
  v11 = add.i64 v10, v6
  v12 = add.i64 v11, v7
  v13 = add.i64 v12, v8
  ret v13
)";
    let (b, a) = optimized_copying(src, 16);
    for name in ["ronly", "excl"] {
        let t = text_of(&a, name);
        assert(t.as_str().find("memcpy") < 0 && t.as_str().find("slotaddr") < 0, t.as_str());
    }
    for name in ["cmpd", "wrt", "shr"] {
        let t = text_of(&a, name);
        assert(t.as_str().find("memcpy") >= 0, t.as_str());
    }
    // ronly, excl, shr: 9 - 2 each; cmpd: 0 (a copy); wrt: 10 - 2 (its copy written); the source's 9.
    let args: [u64; 1] = [9];
    same_result(&b, &a, "drive", args[0..1], 7 + 7 + 0 + 8 + 7 + 9);
}

// A call's aggregate result that a copy moves from its slot into an exclusive reference's referent, right
// after the call, through another slot too (`hop`), goes there at once: the call writes that referent and
// the copies go (`into`, `hop`). They stay when the referent is a shared reference's (`shr`), when another
// argument reaches it (`lent`), when the callee keeps its result's address (`kept`), and when it may panic
// (`risky`): a panic may unwind to code that reads the referent the callee left half written.
@test
fn a_call_result_copied_into_an_exclusive_referent_goes_there_at_once() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @mk fn global noinline
sym @mk2 fn global noinline
sym @mkk fn global noinline
sym @into fn global noinline
sym @hop fn global noinline
sym @shr fn global noinline
sym @lent fn global noinline
sym @kept fn global noinline
sym @mkp fn global noinline
sym @risky fn global noinline
sym @drive fn global
sym @at data global
data @at size 8 align 3
fn @mk
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  v2 = iconst.i64 1
  v3 = add.i64 v0, v2
  store v0, v1 align 3
  store v3, v1+8 align 3
  store v0, v1+16 align 3
  ret
fn @mk2
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (i64, ptr) -> l0
b0(v0: i64, v1: ptr, v2: ptr):
  v3 = load.i64 v1 align 3
  v4 = add.i64 v0, v3
  store v4, v2 align 3
  store v4, v2+8 align 3
  store v4, v2+16 align 3
  ret
fn @mkk
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  v2 = symaddr @at
  store v1, v2 align 3
  store v0, v1 align 3
  store v0, v1+8 align 3
  store v0, v1+16 align 3
  ret
fn @into
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> void
  ref p0 24 noalias
  slot s0 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 24
  call @mk(v1, v2) : (i64) -> l0
  memcpy.overlap v0, v2, v3
  ret
fn @hop
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> void
  ref p0 24 noalias
  slot s0 size 24 align 3
  slot s1 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 24
  call @mk(v1, v2) : (i64) -> l0
  memcpy v3, v2, v4
  memcpy.overlap v0, v3, v4
  ret
fn @shr
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> void
  slot s0 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 24
  call @mk(v1, v2) : (i64) -> l0
  memcpy.overlap v0, v2, v3
  ret
fn @lent
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> void
  ref p0 24 noalias
  slot s0 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 24
  call @mk2(v1, v0, v2) : (i64, ptr) -> l0
  memcpy.overlap v0, v2, v3
  ret
fn @kept
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> void
  ref p0 24 noalias
  slot s0 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 24
  call @mkk(v1, v2) : (i64) -> l0
  memcpy.overlap v0, v2, v3
  ret
fn @mkp
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  v2 = iconst.i64 0
  v3 = icmp.eq v0, v2
  br v3, b1, b2
b1: cold
  panic "attempt to divide by zero"
b2:
  store v0, v1 align 3
  store v0, v1+8 align 3
  store v0, v1+16 align 3
  ret
fn @risky
  layout l0 size 24 align 3 [0 i64, 8 i64, 16 i64]
  sig (ptr, i64) -> void
  ref p0 24 noalias
  slot s0 size 24 align 3
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 24
  call @mkp(v1, v2) : (i64) -> l0
  memcpy.overlap v0, v2, v3
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 24 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 3
  store v2, v1 align 3
  call @risky(v1, v0) : (ptr, i64) -> void
  call @into(v1, v0) : (ptr, i64) -> void
  v3 = load.i64 v1+8 align 3
  call @hop(v1, v3) : (ptr, i64) -> void
  v4 = load.i64 v1+8 align 3
  call @shr(v1, v4) : (ptr, i64) -> void
  call @lent(v1, v0) : (ptr, i64) -> void
  v5 = load.i64 v1+16 align 3
  call @kept(v1, v5) : (ptr, i64) -> void
  v6 = load.i64 v1 align 3
  v7 = load.i64 v1+8 align 3
  v8 = add.i64 v6, v7
  ret v8
)",
    );
    for name in ["into", "hop"] {
        let t = text_of(&a, name);
        assert(t.as_str().find("memcpy") < 0 && t.as_str().find("slotaddr") < 0, t.as_str());
    }
    for name in ["shr", "lent", "kept", "risky"] {
        let t = text_of(&a, name);
        assert(t.as_str().find("memcpy") >= 0, t.as_str());
    }
    // into(5): 5, 6, 5; hop(6): 6, 7, 6; shr(7): 7, 8, 7; lent(5): 12 each; kept(12): 12 each.
    let args: [u64; 1] = [5];
    same_result(&b, &a, "drive", args[0..1], 24);
}

// A loop's counter step tested against 0 after other work moves right before the test, where the backends
// test the flags it sets (`step_next`): `pow`'s `sub` follows the `mul`. `upto`'s step compared with the
// bound moves so too (its old value's reads end before it). `kept`'s product reads the step, which stays.
@test
fn a_counter_step_moves_to_its_comparison() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @pow fn global
sym @upto fn global
sym @kept fn global
fn @pow
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = icmp.eq v1, v3
  br v4, b2(v2), b1(v1, v2)
b1(v5: i64, v6: i64):
  v7 = sub.i64 v5, v2
  v8 = mul.i64 v6, v0
  v9 = icmp.ne v7, v3
  br v9, b1(v7, v8), b2(v8)
b2(v10: i64):
  ret v10
fn @upto
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.eq v1, v2
  br v4, b2(v2), b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = add.i64 v5, v3
  v8 = ptradd v0, v5 * 8
  v9 = load.i64 v8 align 3
  v10 = add.i64 v6, v9
  v11 = icmp.ult v7, v1
  br v11, b1(v7, v10), b2(v10)
b2(v12: i64):
  ret v12
fn @kept
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  v4 = icmp.eq v1, v3
  br v4, b2(v2), b1(v1, v2)
b1(v5: i64, v6: i64):
  v7 = sub.i64 v5, v2
  v8 = mul.i64 v6, v7
  v9 = icmp.ne v7, v3
  br v9, b1(v7, v8), b2(v8)
b2(v10: i64):
  ret v10
)",
    );
    let tp = text_of(&a, "pow");
    let tk = text_of(&a, "kept");
    let sp = tp.as_str().find("sub.i64");
    let mp = tp.as_str().find("mul.i64");
    assert(sp >= 0 && mp >= 0 && mp < sp, tp.as_str());
    let tu = text_of(&a, "upto");
    let su = tu.as_str().find("add.i64 v5");
    let lu = tu.as_str().find("load.i64");
    assert(su >= 0 && lu >= 0 && lu < su, tu.as_str());
    let sk = tk.as_str().find("sub.i64");
    let mk = tk.as_str().find("mul.i64");
    assert(sk >= 0 && mk >= 0 && sk < mk, tk.as_str());
    let p0: [u64; 2] = [3, 0];
    let p5: [u64; 2] = [3, 5];
    same_result(&b, &a, "pow", p0[0..2], 1);
    same_result(&b, &a, "pow", p5[0..2], 243);
    let k3: [u64; 2] = [0, 3];
    same_result(&b, &a, "kept", k3[0..2], 0);
}

// A subtraction floored at 0 (`n - a` when `a <u n`, else 0) whose `a` is at most `n` on every edge into
// its block (0, or `n` masked) is the subtraction alone (`floor_sub`): `rem` takes it either way round the
// select. `open`'s `a` comes from the caller, which may pass more than `n`: the select stays.
@test
fn subtractions_floored_at_zero_drop_a_select_a_bound_settles() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @rem fn global
sym @open fn global
fn @rem
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 -16
  v3 = and.i64 v0, v2
  v4 = iconst.i64 0
  v5 = icmp.ne v1, v4
  br v5, b1(v3), b1(v4)
b1(v6: i64):
  v7 = sub.i64 v0, v6
  v8 = icmp.ult v6, v0
  v9 = select.i64 v8, v7, v4
  v10 = icmp.uge v6, v0
  v11 = select.i64 v10, v4, v7
  v12 = add.i64 v9, v11
  ret v12
fn @open
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = sub.i64 v0, v1
  v4 = icmp.ult v1, v0
  v5 = select.i64 v4, v3, v2
  ret v5
)",
    );
    let tr = text_of(&a, "rem");
    let to = text_of(&a, "open");
    assert(!tr.contains("icmp.ult") && !tr.contains("icmp.uge"), tr.as_str());
    assert(to.contains("select"), to.as_str());
    let r1: [u64; 2] = [37, 1];
    let r0: [u64; 2] = [37, 0];
    let o1: [u64; 2] = [5, 9];
    let o2: [u64; 2] = [9, 5];
    same_result(&b, &a, "rem", r1[0..2], 10);
    same_result(&b, &a, "rem", r0[0..2], 74);
    same_result(&b, &a, "open", o1[0..2], 0);
    same_result(&b, &a, "open", o2[0..2], 4);
}

// A comparison of an extended value with a constant its narrow type holds compares the narrow value
// (`narrow_cmp`): equalities and unsigned orders of a zero extension, signed orders of a sign extension,
// two values extended alike. `kept` keeps its extensions: a signed order of a zero extension, a constant
// past the narrow type.
@test
fn comparisons_of_extended_values_compare_them_narrow() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @narrow fn global
sym @kept fn global
fn @narrow
  sig (i8, i8, i16) -> i32
b0(v0: i8, v1: i8, v2: i16):
  v3 = zext.i32 v0
  v4 = iconst.i32 200
  v5 = icmp.ugt v3, v4
  v6 = sext.i32 v2
  v7 = iconst.i32 -5
  v8 = icmp.slt v6, v7
  v9 = zext.i32 v1
  v10 = icmp.eq v3, v9
  v11 = zext.i32 v5
  v12 = zext.i32 v8
  v13 = zext.i32 v10
  v14 = iconst.i32 2
  v15 = mul.i32 v12, v14
  v16 = iconst.i32 4
  v17 = mul.i32 v13, v16
  v18 = add.i32 v11, v15
  v19 = add.i32 v18, v17
  ret v19
fn @kept
  sig (i8) -> i32
b0(v0: i8):
  v1 = zext.i32 v0
  v2 = iconst.i32 -5
  v3 = icmp.slt v1, v2
  v4 = iconst.i32 300
  v5 = icmp.ult v1, v4
  v6 = zext.i32 v3
  v7 = zext.i32 v5
  v8 = add.i32 v6, v7
  ret v8
)",
    );
    let tn = text_of(&a, "narrow");
    assert(tn.contains("iconst.i8") && tn.contains("iconst.i16"), tn.as_str());
    let tk = text_of(&a, "kept");
    assert(!tk.contains("iconst.i8"), tk.as_str());
    let c1: [u64; 3] = [201, 201, 0xFFF0];
    let c2: [u64; 3] = [7, 9, 3];
    let c3: [u64; 3] = [255, 3, 0xFFFB];
    same_result(&b, &a, "narrow", c1[0..3], 7);
    same_result(&b, &a, "narrow", c2[0..3], 0);
    same_result(&b, &a, "narrow", c3[0..3], 1);
    let k1: [u64; 1] = [255];
    same_result(&b, &a, "kept", k1[0..1], 1);
}

// A parameter compared with a constant takes each edge's comparison result instead (`param_cmp`), and
// the comparison reads that result: a jump whose target only returns returns the right arm
// (`ret_folded`, which reads the target's instructions as they stand).
@test
fn a_compared_parameter_returns_through_its_edges() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @calls data global
sym @tag fn global
sym @g fn global noinline
fn @g
  sig () -> void
b0:
  v0 = symaddr @calls
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
  ret
fn @tag
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i8 0
  v2 = iconst.i8 1
  v3 = iconst.i32 0
  v4 = iconst.i32 4
  v5 = icmp.ne v0, v3
  br v5, b2, b1
b1:
  call @g() : () -> void
  jmp b3(v1)
b2:
  call @g() : () -> void
  jmp b3(v2)
b3(v6: i8):
  v7 = icmp.eq v6, v1
  v8 = select.i32 v7, v3, v4
  ret v8
data @calls size 8 align 3
)",
    );
    let tt = text_of(&a, "tag");
    assert(!tt.contains("select"), tt.as_str());
    let c1: [u64; 1] = [1];
    let c0: [u64; 1] = [0];
    same_result(&b, &a, "tag", c1[0..1], 4);
    same_result(&b, &a, "tag", c0[0..1], 0);
}

// A dense switch that passes one block a function's address per case reads it from a read-only table
// (`symbol_tables`): the default's address fills a hole, values past the table take the default's edge.
@test
fn a_switch_of_function_addresses_reads_a_table() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f0 fn global noinline
sym @f1 fn global noinline
sym @f2 fn global noinline
sym @pick fn global
sym @run fn global
fn @f0
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = add.i32 v0, v1
  ret v2
fn @f1
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 3
  v2 = mul.i32 v0, v1
  ret v2
fn @f2
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 7
  v2 = xor.i32 v0, v1
  ret v2
fn @pick
  sig (i32) -> ptr
b0(v0: i32):
  switch v0 [2 -> b1, 3 -> b2, 4 -> b3, 6 -> b2] else b4
b1:
  v1 = symaddr @f0
  jmp b5(v1)
b2:
  v2 = symaddr @f1
  jmp b5(v2)
b3:
  v3 = symaddr @f2
  jmp b5(v3)
b4:
  v4 = symaddr @f2
  jmp b5(v4)
b5(v5: ptr):
  ret v5
fn @run
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = call.ptr @pick(v0) : (i32) -> ptr
  v3 = call.ind.i32 v2(v1) : (i32) -> i32
  ret v3
)",
    );
    let tp = text_of(&a, "pick");
    assert(!tp.contains("switch") && tp.contains("load.ptr"), tp.as_str());
    let want: [u64; 10] = [13, 13, 11, 30, 13, 13, 30, 13, 13, 13];
    for x in 0..10u64 {
        let args: [u64; 2] = [x, 10];
        same_result(&b, &a, "run", args[0..2], want[x as usize]);
    }
}

// Branches that share one edge record into a block whose parameter a comparison with a constant reads:
// `param_cmp` passes the comparison's result along that edge once, not once per branch.
@test
fn a_shared_edge_passes_a_compared_parameter_once() {
    let text = M"(lir ptr 8
sym @g fn global noinline
sym @f fn global
fn @g
  sig () -> void
b0:
  ret
fn @f
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = iconst.i8 0
  v4 = iconst.i8 1
  v5 = iconst.i32 5
  v6 = iconst.i32 6
  v7 = icmp.eq v0, v2
  br v7, b1, b2
b1:
  call @g() : () -> void
  v8 = icmp.eq v1, v5
  br v8, b5(v4), b3
b2:
  call @g() : () -> void
  v9 = icmp.eq v1, v6
  br v9, b5(v4), b4
b3:
  jmp b5(v3)
b4:
  v10 = iconst.i32 40
  ret v10
b5(v11: i8):
  v12 = icmp.eq v11, v3
  br v12, b6, b7
b6:
  v13 = iconst.i32 10
  ret v13
b7:
  v14 = iconst.i32 20
  ret v14
)";
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    for k in 0..after.bodies.len() {
        share_edges(after.bodies.index_mut(k));
    }
    let none = Vector::<bool>::new();
    lopt::optimize(
        &mut after,
        &none,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 0,
                interleave: 0,
                fin: 0,
            },
        },
    );
    let c05: [u64; 2] = [0, 5];
    let c06: [u64; 2] = [1, 6];
    let c07: [u64; 2] = [0, 7];
    let c17: [u64; 2] = [1, 7];
    same_result(&before, &after, "f", c05[0..2], 20);
    same_result(&before, &after, "f", c06[0..2], 20);
    same_result(&before, &after, "f", c07[0..2], 10);
    same_result(&before, &after, "f", c17[0..2], 40);
}

// Each branch edge of `b` equal to an earlier one (target and arguments) becomes that edge.
fn share_edges(b: &mut Body) {
    let mut seen = Vector::<u32>::new();
    for k in 0..b.blocks.len() {
        let bk = b.blocks[k];
        if bk.len == 0 {
            continue;
        }
        let at = (bk.start + bk.len - 1) as usize;
        let mut t = b.insts[at];
        if t.op == O_JMP {
            t.a = shared_edge(b, &mut seen, t.a);
        } else if t.op == O_BR {
            t.b = shared_edge(b, &mut seen, t.b);
            t.c = shared_edge(b, &mut seen, t.c);
        }
        b.insts[at] = t;
    }
}

// The edge of `seen` equal to edge `e` of `b`, else `e`, which `seen` takes.
fn shared_edge(b: &Body, seen: &mut Vector<u32>, e: u32) u32 {
    for j in 0..seen.len() {
        let s = seen[j];
        let mut same = b.edge_target(s) == b.edge_target(e) && b.edge_nargs(s) == b.edge_nargs(e);
        for q in 0..b.edge_nargs(e) {
            same = same && b.edge_arg(s, q) == b.edge_arg(e, q);
        }
        if same {
            return s;
        }
    }
    seen.push(e);
    return e;
}

// A load of a read-only referent (`ref ... readonly`) after a call reads the value the load before it
// read: no write of the body, a call's included, touches the referent.
@test
fn a_read_only_referent_keeps_its_value_across_a_call() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @opq fn global noinline
sym @f fn global noinline
sym @g fn global
sym @d data global
sym @w data global
fn @opq
  sig () -> void
b0:
  v0 = symaddr @w
  v1 = load.i32 v0 align 2
  v2 = iconst.i32 1
  v3 = add.i32 v1, v2
  store v3, v0 align 2
  ret
fn @f
  sig (ptr) -> i32
  ref p0 4 readonly
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  call @opq() : () -> void
  v2 = load.i32 v0 align 2
  v3 = add.i32 v1, v2
  ret v3
fn @g
  sig () -> i32
b0:
  v0 = symaddr @d
  v1 = call.i32 @f(v0) : (ptr) -> i32
  ret v1
data @d size 4 align 2 bytes 15000000
data @w size 4 align 2
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "load.") == 1, t.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "g", none, 42);
}

// The place a loop keeps in a register (`promote_places`) is kept before the loop transforms: the final
// value of the loop's sum through an exclusive referent leaves no loop (`*d += n * *a`).
@test
fn an_exclusive_referent_sums_without_a_loop() {
    let (b, a) = optimized_loops(
        M"(lir ptr 8
sym @acc fn global noinline
sym @run fn global
sym @d data global
sym @x data global
fn @acc
  sig (ptr, ptr, i32) -> void
  ref p0 4 noalias
  ref p1 4 readonly
b0(v0: ptr, v1: ptr, v2: i32):
  v3 = iconst.i32 0
  v4 = iconst.i32 1
  v5 = icmp.ne v2, v3
  br v5, b1(v3), b2
b1(v6: i32):
  v7 = load.i32 v0 align 2
  v8 = load.i32 v1 align 2
  v9 = add.i32 v7, v8
  store v9, v0 align 2
  v10 = add.i32 v6, v4
  v11 = icmp.ult v10, v2
  br v11, b1(v10), b2
b2:
  ret
fn @run
  sig (i32) -> i32
b0(v0: i32):
  v1 = symaddr @d
  v2 = symaddr @x
  call @acc(v1, v2, v0) : (ptr, ptr, i32) -> void
  v3 = load.i32 v1 align 2
  ret v3
data @d size 4 align 2 bytes 05000000
data @x size 4 align 2 bytes 07000000
)",
        0,
        false,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 512,
        },
    );
    let t = text_of(&a, "acc");
    assert(count_of(&t, "load.") == 2 && count_of(&t, "store ") == 1 && t.contains("mul.i32"), t.as_str());
    for n in 0..6u64 {
        let args: []u64 = [n];
        same_result(&b, &a, "run", args, 5 + 7 * n);
    }
}

// A loop exit whose arguments the back edge passes too keeps them on the branch: `split_exits` gives it no
// block of its own, and the back edge's moves before the branch serve it.
@test
fn exits_that_share_the_back_edge_keep_their_arguments() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @gcd fn global
fn @gcd
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = icmp.eq v1, v2
  br v3, b2(v0), b1(v0, v1)
b1(v4: i32, v5: i32):
  v6 = urem.i32 v4, v5
  v7 = icmp.eq v6, v2
  br v7, b2(v5), b1(v5, v6)
b2(v8: i32):
  ret v8
)",
    );
    let g = text_of(&a, "gcd");
    assert(g.contains("br v7, b2(v5), b1(v5, v6)"), g.as_str());
    for (x, y, r) in [(12u64, 18u64, 6u64), (7, 0, 7), (0, 5, 5), (35, 14, 7)] {
        let args: []u64 = [x, y];
        same_result(&b, &a, "gcd", args, r);
    }
}

// A comparison the branches decide is a constant where they decide it: `@eq3` (three fields compared, each
// load after the test before it) returns its first test on that test's false edge and passes its second
// along the second's false edge: both 0 (`iconst.i8 0`); `@ret1` has the return alone, `@edge1` the edges
// alone (both false ones into one block). The results stay.
@test
fn decided_comparisons_are_constants() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @eq3 fn global noinline
sym @ret1 fn global noinline
sym @edge1 fn global noinline
sym @same fn global
sym @differ fn global
sym @x data global
sym @y data global
fn @eq3
  sig (ptr, ptr) -> i8
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0 align 2
  v3 = load.i32 v1 align 2
  v4 = icmp.eq v2, v3
  br v4, b1, b4
b1:
  v5 = load.i32 v0+4 align 2
  v6 = load.i32 v1+4 align 2
  v7 = icmp.eq v5, v6
  br v7, b2, b3(v7)
b2:
  v8 = load.i32 v0+8 align 2
  v9 = load.i32 v1+8 align 2
  v10 = icmp.eq v8, v9
  ret v10
b3(v11: i8):
  ret v11
b4:
  ret v4
fn @ret1
  sig (ptr, ptr) -> i8
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0 align 2
  v3 = load.i32 v1 align 2
  v4 = icmp.eq v2, v3
  br v4, b1, b2
b1:
  v5 = load.i32 v0+4 align 2
  v6 = load.i32 v1+4 align 2
  v7 = icmp.eq v5, v6
  ret v7
b2:
  ret v4
fn @edge1
  sig (ptr, ptr) -> i8
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0 align 2
  v3 = load.i32 v1 align 2
  v4 = icmp.eq v2, v3
  br v4, b1, b3(v4)
b1:
  v5 = load.i32 v0+4 align 2
  v6 = load.i32 v1+4 align 2
  v7 = icmp.eq v5, v6
  br v7, b2, b3(v7)
b2:
  v8 = load.i32 v0+8 align 2
  v9 = load.i32 v1+8 align 2
  v10 = icmp.eq v8, v9
  ret v10
b3(v11: i8):
  ret v11
fn @same
  sig () -> i64
b0:
  v0 = symaddr @x
  v1 = call.i8 @eq3(v0, v0) : (ptr, ptr) -> i8
  v2 = zext.i64 v1
  ret v2
fn @differ
  sig () -> i64
b0:
  v0 = symaddr @x
  v1 = symaddr @y
  v2 = call.i8 @eq3(v0, v1) : (ptr, ptr) -> i8
  v3 = zext.i64 v2
  ret v3
data @x size 12 align 2 bytes 010000000200000003000000
data @y size 12 align 2 bytes 010000000500000003000000
)",
    );
    for name in ["eq3", "ret1", "edge1"] {
        let e = text_of(&a, name);
        assert(e.contains("iconst.i8 0"), e.as_str());
    }
    let none: []u64 = [];
    same_result(&b, &a, "same", none, 1);
    same_result(&b, &a, "differ", none, 0);
}

// Outside loops, an operation of truncations from one wider type (or constants) is the truncation of the
// wide operation: `@sum2`'s `add.i32` of two truncated `i64`s an `add.i64`, `@pick`'s `select.i32` of one and
// a constant a `select.i64`. `@narrow`'s `select.i8` and the `add.i32` in `@loop`'s loop stay. The results
// stay.
@test
fn operations_of_truncations_outside_loops_are_wide() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sum2 fn global noinline
sym @pick fn global noinline
sym @narrow fn global noinline
sym @loop fn global noinline
sym @run fn global
sym @arr data global
fn @sum2
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = trunc.i32 v0
  v3 = trunc.i32 v1
  v4 = add.i32 v2, v3
  v5 = zext.i64 v4
  v6 = xor.i64 v5, v0
  ret v6
fn @pick
  sig (i8, i64) -> i32
b0(v0: i8, v1: i64):
  v2 = trunc.i32 v1
  v3 = iconst.i32 -7
  v4 = select.i32 v0, v2, v3
  ret v4
fn @narrow
  sig (i8, i32) -> i8
b0(v0: i8, v1: i32):
  v2 = trunc.i8 v1
  v3 = iconst.i8 3
  v4 = select.i8 v0, v2, v3
  ret v4
fn @loop
  sig (i64, ptr) -> i32
b0(v0: i64, v1: ptr):
  v2 = iconst.i64 0
  v3 = iconst.i32 0
  jmp b1(v2, v3)
b1(v4: i64, v5: i32): novec
  v6 = icmp.ult v4, v0
  br v6, b2, b3
b2:
  v7 = trunc.i32 v4
  v8 = ptradd v1, v4 * 8
  v9 = load.i64 v8 align 3
  v10 = trunc.i32 v9
  v11 = add.i32 v7, v10
  v12 = add.i32 v5, v11
  v13 = iconst.i64 1
  v14 = add.i64 v4, v13
  jmp b1(v14, v12)
b3:
  ret v5
fn @run
  sig () -> i64
b0:
  v0 = iconst.i64 4294967301
  v1 = iconst.i64 8589934599
  v2 = iconst.i64 12884901897
  v3 = iconst.i8 1
  v4 = iconst.i8 0
  v5 = iconst.i32 511
  v6 = iconst.i64 4
  v7 = symaddr @arr
  v8 = call.i64 @sum2(v0, v1) : (i64, i64) -> i64
  v9 = call.i32 @pick(v3, v2) : (i8, i64) -> i32
  v10 = call.i32 @pick(v4, v2) : (i8, i64) -> i32
  v11 = call.i8 @narrow(v3, v5) : (i8, i32) -> i8
  v12 = call.i32 @loop(v6, v7) : (i64, ptr) -> i32
  v13 = zext.i64 v9
  v14 = zext.i64 v10
  v15 = zext.i64 v11
  v16 = zext.i64 v12
  v17 = add.i64 v8, v13
  v18 = add.i64 v17, v14
  v19 = add.i64 v18, v15
  v20 = add.i64 v19, v16
  ret v20
data @arr size 32 align 3 bytes 0100000000000000020000000000000003000000000000000400000000000000
)",
    );
    let s = text_of(&a, "sum2");
    let p = text_of(&a, "pick");
    let n = text_of(&a, "narrow");
    let l = text_of(&a, "loop");
    assert(s.contains("add.i64") && !s.contains("add.i32"), s.as_str());
    assert(p.contains("select.i64"), p.as_str());
    assert(n.contains("select.i8"), n.as_str());
    assert(l.find("add.i32") != l.rfind("add.i32"), l.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "run", none, 8589934874);
}

// A count read only where its operand is not 0 is `.nz`: `@guard`'s `clz`, the arm for `x != 0` of a
// select on `x == 0`; `@above`'s `ctz` of `x - 1` after `x >u 1` (a store keeps the branch); `@plain`'s
// (no test) stays, and so does `@bit`'s narrowed `ctz` of `x | 2^32` (`x` may be 0); `@wide`'s count of a
// zero extension narrows marked. The results stay.
@test
fn counts_of_operands_above_zero_are_marked() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @guard fn global noinline
sym @above fn global noinline
sym @plain fn global noinline
sym @top fn global noinline
sym @bit fn global noinline
sym @wide fn global noinline
sym @run fn global
sym @cell data global
fn @guard
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  br v2, b2, b1
b1:
  v3 = clz.i32 v0
  ret v3
b2:
  v4 = iconst.i32 99
  ret v4
fn @above
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = icmp.ule v0, v1
  br v2, b2, b1
b1:
  v3 = sub.i64 v0, v1
  v4 = ctz.i64 v3
  ret v4
b2:
  v5 = iconst.i64 77
  v6 = symaddr @cell
  store v5, v6 align 3
  ret v5
fn @plain
  sig (i32) -> i32
b0(v0: i32):
  v1 = clz.i32 v0
  ret v1
fn @wide
  sig (i32) -> i64
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  br v2, b2, b1
b1:
  v3 = zext.i64 v0
  v4 = clz.i64 v3
  ret v4
b2: unlikely
  v5 = call.i32 @plain(v0) : (i32) -> i32
  unreachable
fn @bit
  sig (i32) -> i64
b0(v0: i32):
  v1 = zext.i64 v0
  v2 = iconst.i64 4294967296
  v3 = or.i64 v1, v2
  v4 = ctz.nz.i64 v3
  ret v4
fn @top
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 31
  v3 = icmp.eq v0, v1
  br v3, b2, b1
b1:
  v4 = clz.i32 v0
  v5 = xor.i32 v4, v2
  ret v5
b2: unlikely
  v6 = call.i32 @plain(v0) : (i32) -> i32
  unreachable
fn @run
  sig () -> i64
b0:
  v0 = iconst.i32 0
  v1 = iconst.i32 4096
  v2 = iconst.i64 1
  v3 = iconst.i64 9
  v4 = call.i32 @guard(v0) : (i32) -> i32
  v5 = call.i32 @guard(v1) : (i32) -> i32
  v6 = call.i64 @above(v2) : (i64) -> i64
  v7 = call.i64 @above(v3) : (i64) -> i64
  v8 = call.i32 @plain(v0) : (i32) -> i32
  v9 = iconst.i64 1000
  v10 = zext.i64 v4
  v11 = mul.i64 v10, v9
  v12 = zext.i64 v5
  v13 = add.i64 v11, v12
  v14 = mul.i64 v13, v9
  v15 = add.i64 v14, v6
  v16 = mul.i64 v15, v9
  v17 = add.i64 v16, v7
  v18 = mul.i64 v17, v9
  v19 = zext.i64 v8
  v20 = add.i64 v18, v19
  ret v20
data @cell size 8 align 3 bytes 0000000000000000
)",
    );
    let g = text_of(&a, "guard");
    let o = text_of(&a, "above");
    let p = text_of(&a, "plain");
    assert(g.contains("clz.nz.i32"), g.as_str());
    assert(o.contains("ctz.nz.i64"), o.as_str());
    assert(!p.contains(".nz"), p.as_str());
    let q = text_of(&a, "top");
    assert(q.contains("clz.nz.i32"), q.as_str());
    let w = text_of(&a, "wide");
    assert(w.contains("clz.nz.i32"), w.as_str());
    let n = text_of(&a, "bit");
    assert(n.contains("ctz.i32") && !n.contains(".nz"), n.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "run", none, 99019077003032);
}

// A select of two loads alike that only it reads, with no write between, is one load of the selected
// address: `@pick` loads once; `@kept` (a store between) and `@both` (a load read again) keep two. The
// results stay.
@test
fn selects_of_loads_load_the_selected_address() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @pick fn global noinline
sym @kept fn global noinline
sym @both fn global noinline
sym @run fn global
sym @x data global
sym @y data global
fn @pick
  sig (i8, ptr, ptr) -> i32
b0(v0: i8, v1: ptr, v2: ptr):
  v3 = load.i32 v1+4 align 2
  v4 = load.i32 v2+4 align 2
  v5 = select.i32 v0, v3, v4
  ret v5
fn @kept
  sig (i8, ptr, ptr) -> i32
b0(v0: i8, v1: ptr, v2: ptr):
  v3 = load.i32 v1+4 align 2
  v4 = iconst.i32 9
  store v4, v1 align 2
  v5 = load.i32 v2+4 align 2
  v6 = select.i32 v0, v3, v5
  ret v6
fn @both
  sig (i8, ptr, ptr) -> i32
b0(v0: i8, v1: ptr, v2: ptr):
  v3 = load.i32 v1+4 align 2
  v4 = load.i32 v2+4 align 2
  v5 = select.i32 v0, v3, v4
  v6 = add.i32 v5, v3
  ret v6
fn @run
  sig () -> i64
b0:
  v0 = symaddr @x
  v1 = symaddr @y
  v2 = iconst.i8 1
  v3 = iconst.i8 0
  v4 = call.i32 @pick(v2, v0, v1) : (i8, ptr, ptr) -> i32
  v5 = call.i32 @pick(v3, v0, v1) : (i8, ptr, ptr) -> i32
  v6 = call.i32 @kept(v3, v0, v1) : (i8, ptr, ptr) -> i32
  v7 = call.i32 @both(v3, v0, v1) : (i8, ptr, ptr) -> i32
  v8 = iconst.i32 1000
  v9 = mul.i32 v4, v8
  v10 = add.i32 v9, v5
  v11 = mul.i32 v10, v8
  v12 = add.i32 v11, v6
  v13 = mul.i32 v12, v8
  v14 = add.i32 v13, v7
  v15 = zext.i64 v14
  ret v15
data @x size 8 align 2 bytes 0000000003000000
data @y size 8 align 2 bytes 0000000005000000
)",
    );
    let p = text_of(&a, "pick");
    let k = text_of(&a, "kept");
    let o = text_of(&a, "both");
    assert(p.find("load") == p.rfind("load"), p.as_str());
    assert(k.find("load") != k.rfind("load"), k.as_str());
    assert(o.find("load") != o.rfind("load"), o.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "run", none, 3005005008);
}

// A rewrite along one edge of a branch leaves the terminators that share the edge as they were: the jumps
// through `@thread`'s empty `b3` share its edge into `b4`, the true path's too, so the branch's comparison
// becomes 0 along its false edge alone, and `@thread` still returns 1 where it holds.
@test
fn edge_rewrites_keep_shared_edges() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @thread fn global noinline
sym @one fn global
sym @two fn global
sym @x data global
fn @thread
  sig (i32, ptr) -> i32
b0(v0: i32, v1: ptr):
  v2 = iconst.i32 1
  v3 = icmp.eq v0, v2
  br v3, b1, b2
b1:
  store v0, v1 align 2
  jmp b3
b2:
  jmp b3
b3:
  jmp b4(v3)
b4(v4: i8):
  v5 = zext.i32 v4
  ret v5
fn @one
  sig () -> i64
b0:
  v0 = symaddr @x
  v1 = iconst.i32 1
  v2 = call.i32 @thread(v1, v0) : (i32, ptr) -> i32
  v3 = zext.i64 v2
  ret v3
fn @two
  sig () -> i64
b0:
  v0 = symaddr @x
  v1 = iconst.i32 2
  v2 = call.i32 @thread(v1, v0) : (i32, ptr) -> i32
  v3 = zext.i64 v2
  ret v3
data @x size 4 align 2 bytes 00000000
)",
    );
    let none: []u64 = [];
    same_result(&b, &a, "one", none, 1);
    same_result(&b, &a, "two", none, 0);
}

// A counted loop whose one effect writes the element after the last one goes, a `memset` or `memcpy` in its
// place (`final_values`' `mem_run`): a fill of 4-byte elements of one repeated byte, its test at its end
// (the store runs once more than the back edge), a copy from a read-only source to an exclusive destination,
// its test in the header (the store in the latch runs as often as the back edge). A fill whose bytes differ
// stays a loop.
@test
fn fill_and_copy_loops_become_calls() {
    let (b, a) = optimized_loops(
        M"(lir ptr 8
sym @fill fn global noinline
sym @mixed fn global noinline
sym @copy fn global noinline
sym @run fn global
sym @runm fn global
sym @runc fn global
sym @buf data global
sym @src data global
fn @fill
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ne v1, v2
  br v3, b1(v2), b2
b1(v4: i64):
  v5 = ptradd v0, v4 * 4
  v6 = iconst.i32 16843009
  store v6, v5 align 2
  v7 = iconst.i64 1
  v8 = add.i64 v4, v7
  v9 = icmp.ult v8, v1
  br v9, b1(v8), b2
b2:
  ret
fn @mixed
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.ne v1, v2
  br v3, b1(v2), b2
b1(v4: i64):
  v5 = ptradd v0, v4 * 4
  v6 = iconst.i32 258
  store v6, v5 align 2
  v7 = iconst.i64 1
  v8 = add.i64 v4, v7
  v9 = icmp.ult v8, v1
  br v9, b1(v8), b2
b2:
  ret
fn @copy
  sig (ptr, ptr, i64) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 2
  v8 = load.i16 v7 align 1
  v9 = ptradd v0, v5 * 2
  store v8, v9 align 1
  v10 = add.i64 v5, v4
  jmp b1(v10)
b3:
  ret
fn @run
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @buf
  call @fill(v1, v0) : (ptr, i64) -> void
  v2 = iconst.i64 1
  v3 = sub.i64 v0, v2
  v4 = ptradd v1, v3 * 4
  v5 = load.i32 v4 align 2
  v6 = ptradd v1, v0 * 4
  v7 = load.i32 v6 align 2
  v8 = zext.i64 v5
  v9 = zext.i64 v7
  v10 = add.i64 v8, v9
  ret v10
fn @runm
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @buf
  call @mixed(v1, v0) : (ptr, i64) -> void
  v2 = ptradd v1, v0 * 4
  v3 = load.i64 v1 align 3
  v4 = load.i32 v2 align 2
  v5 = zext.i64 v4
  v6 = add.i64 v3, v5
  ret v6
fn @runc
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @buf
  v2 = symaddr @src
  call @copy(v1, v2, v0) : (ptr, ptr, i64) -> void
  v3 = load.i64 v1 align 3
  v4 = ptradd v1, v0 * 2
  v5 = load.i16 v4 align 1
  v6 = zext.i64 v5
  v7 = add.i64 v3, v6
  ret v7
data @buf size 64 align 3 bytes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
data @src size 64 align 3 bytes 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
)",
        0,
        false,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 512,
        },
    );
    let f = text_of(&a, "fill");
    assert(f.contains("memset") && !f.contains("store"), f.as_str());
    let m = text_of(&a, "mixed");
    assert(!m.contains("memset") && m.contains("store"), m.as_str());
    let c = text_of(&a, "copy");
    assert(c.contains("memcpy") && !c.contains("store"), c.as_str());
    for n in 1..16u64 {
        let args: []u64 = [n];
        same_result(&b, &a, "run", args, 0x01010101u64 + 0xAAAAAAAAu64);
    }
    let zero: []u64 = [0];
    same_result(&b, &a, "runm", zero, 0xAAAAAAAAAAAAAAAAu64 + 0xAAAAAAAAu64);
    let three: []u64 = [3];
    same_result(&b, &a, "runm", three, 0x0000010200000102u64 + 0xAAAAAAAAu64);
    same_result(&b, &a, "runc", zero, 0xAAAAAAAAAAAAAAAAu64 + 0xAAAAu64);
    let five: []u64 = [5];
    same_result(&b, &a, "runc", five, 0x0706050403020100u64 + 0xAAAAu64);
    let two: []u64 = [2];
    same_result(&b, &a, "runc", two, 0xAAAAAAAA03020100u64 + 0xAAAAu64);
}

// A call whose result nothing reads goes when its function writes no memory and comes back (no `FX_WRITE`,
// `FX_ARG` or `FX_STALL`): not when the function may panic, loops, or calls itself.
@test
fn unused_calls_without_effects_go() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sq fn global noinline
sym @chk fn global noinline
sym @spin fn global noinline
sym @rec fn global noinline
sym @f fn global
fn @sq
  sig (i32) -> i32
b0(v0: i32):
  v1 = mul.i32 v0, v0
  ret v1
fn @chk
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 100
  v2 = icmp.ult v0, v1
  br v2, b1, b2
b1:
  ret v0
b2: cold
  panic "too large"
fn @spin
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  jmp b1(v0)
b1(v2: i32):
  v3 = icmp.eq v2, v1
  br v3, b2, b1(v2)
b2:
  ret v2
fn @rec
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = icmp.eq v0, v1
  br v2, b1, b2
b1:
  ret v0
b2:
  v3 = call.i32 @rec(v0) : (i32) -> i32
  ret v3
fn @f
  sig (i32) -> i32
b0(v0: i32):
  v1 = call.i32 @sq(v0) : (i32) -> i32
  v2 = call.i32 @chk(v0) : (i32) -> i32
  v3 = call.i32 @spin(v0) : (i32) -> i32
  v4 = call.i32 @rec(v0) : (i32) -> i32
  v5 = iconst.i32 1
  v6 = add.i32 v0, v5
  ret v6
)",
    );
    let f = text_of(&a, "f");
    assert(!f.contains("@sq") && f.contains("@chk") && f.contains("@spin") && f.contains("@rec"), f.as_str());
    let zero: []u64 = [0];
    same_result(&b, &a, "f", zero, 1);
}

// A call in a loop's body (not its header) of a function that writes no memory and comes back moves before
// the loop, though the body may not run (`hoist_call`); one of a function that may panic stays.
@test
fn calls_that_come_back_leave_loop_bodies() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @sq fn global noinline
sym @chk fn global noinline
sym @sum fn global
sym @sumc fn global
fn @sq
  sig (i32) -> i32
b0(v0: i32):
  v1 = mul.i32 v0, v0
  ret v1
fn @chk
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 100
  v2 = icmp.ult v0, v1
  br v2, b1, b2
b1:
  ret v0
b2: cold
  panic "too large"
fn @sum
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  jmp b1(v2, v2)
b1(v4: i32, v5: i32):
  v6 = icmp.ult v4, v0
  br v6, b2, b3
b2:
  v7 = call.i32 @sq(v1) : (i32) -> i32
  v8 = add.i32 v5, v7
  v9 = add.i32 v4, v3
  jmp b1(v9, v8)
b3:
  ret v5
fn @sumc
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  jmp b1(v2, v2)
b1(v4: i32, v5: i32):
  v6 = icmp.ult v4, v0
  br v6, b2, b3
b2:
  v7 = call.i32 @chk(v1) : (i32) -> i32
  v8 = add.i32 v5, v7
  v9 = add.i32 v4, v3
  jmp b1(v9, v8)
b3:
  ret v5
)",
    );
    // The call before the loop's header: the first block holds it.
    let s = text_of(&a, "sum");
    let first = s.find("b1");
    assert(s.find("call.i32 @sq") < first, s.as_str());
    let c = text_of(&a, "sumc");
    let cfirst = c.find("b1");
    assert(c.find("call.i32 @chk") > cfirst && c.find("call.i32 @chk") != usize::MAX, c.as_str());
    for (n, k) in [(0u64, 3u64), (4, 3), (7, 9)] {
        let args: []u64 = [n, k];
        same_result(&b, &a, "sum", args, n * k * k);
        same_result(&b, &a, "sumc", args, n * k);
    }
}

// A callee over the inline budget inlines at a call whose constant argument selects a small part of it
// (`folds_small`): a switch on that parameter reaches one arm. A call with a variable argument stays.
@test
fn constant_arguments_that_shrink_a_callee_inline() {
    let mut src = String::from_str(
        M"(lir ptr 8
sym @pick fn global
sym @one fn global
sym @any fn global
fn @pick
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = iconst.i32 3
  v3 = iconst.i32 1
  switch v1 [0 -> b1, 1 -> b2] else b3
b1:
  ret v0
b2:
  v4 = mul.i32 v0, v2
  v5 = add.i32 v4, v3
  ret v5
b3:
  v6 = add.i32 v0, v3)",
    );
    // A long default arm puts the body past the budget's 40 instructions.
    for k in 0..48u32 {
        src.push_str(format("\n  v{} = mul.i32 v{}, v{}", 7 + k, 6 + k, 6 + k).as_str());
    }
    src.push_str(
        M"(
  ret v54
fn @one
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 1
  v2 = call.i32 @pick(v0, v1) : (i32, i32) -> i32
  ret v2
fn @any
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = call.i32 @pick(v0, v1) : (i32, i32) -> i32
  ret v2
)",
    );
    let (b, a) = optimized(&src);
    let o = text_of(&a, "one");
    assert(!o.contains("call"), o.as_str());
    let y = text_of(&a, "any");
    assert(y.contains("call.i32 @pick"), y.as_str());
    let x: []u64 = [5];
    same_result(&b, &a, "one", x, 16);
    let xy: []u64 = [5, 1];
    same_result(&b, &a, "any", xy, 16);
}

// A loop's test `i + 1 <u n` of a counter from 0 by 1 becomes `i <u n - min(n, 1)` (`offset_test`), the
// difference before the loop; the step that only the back edge reads leaves the header (`sink_heads`).
// Not from a start that is no constant: the sum might wrap there.
@test
fn tests_of_a_counter_plus_a_constant_become_counted() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @pairs fn global
sym @from fn global
fn @pairs
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = add.i64 v3, v2
  v6 = icmp.ult v5, v0
  br v6, b2, b3
b2:
  v7 = add.i64 v4, v3
  jmp b1(v5, v7)
b3:
  ret v4
fn @from
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v1, v2)
b1(v4: i64, v5: i64):
  v6 = add.i64 v4, v3
  v7 = icmp.ult v6, v0
  br v7, b2, b3
b2:
  v8 = add.i64 v5, v4
  jmp b1(v6, v8)
b3:
  ret v5
)",
    );
    let p = text_of(&a, "pairs");
    assert(p.contains("select.i64") && count_of(&p, "icmp.ult v") == 1, p.as_str());
    let f = text_of(&a, "from");
    assert(!f.contains("select"), f.as_str());
    for n in [0u64, 1, 2, 3, 10] {
        let x: [u64; 1] = [n];
        let want = if n < 2 {
            0u64
        } else {
            (n - 1) * (n - 2) / 2
        };
        same_result(&b, &a, "pairs", x[0..1], want);
    }
    let w: [u64; 2] = [5, 0xFFFFFFFFFFFFFFFF];
    same_result(&b, &a, "from", w[0..2], 5);
}

// A loop that leaves where `i + 3 <u n` holds runs while it fails: its counter steps past the wrap of
// `i + 3`, where `i <u n - min(n, 3)` would answer otherwise, so the test stays (`offset_test`).
@test
fn a_test_that_leaves_where_it_holds_stays() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @inv fn global
fn @inv
  sig (i16) -> i64
b0(v0: i16):
  v1 = iconst.i16 -5536
  v2 = iconst.i16 3
  v3 = iconst.i16 1
  v4 = iconst.i64 0
  jmp b1(v1, v4)
b1(v5: i16, v6: i64):
  v7 = add.i16 v5, v2
  v8 = icmp.ult v7, v0
  br v8, b3, b2
b2:
  v9 = zext.i64 v5
  v10 = add.i64 v6, v9
  v11 = add.i16 v5, v3
  jmp b1(v11, v10)
b3:
  ret v6
)",
    );
    let p = text_of(&a, "inv");
    assert(!p.contains("select"), p.as_str());
    // The sum of 60000 to 65532: at 65533 `v7` wraps to 0, below 7.
    let x: [u64; 1] = [7];
    same_result(&b, &a, "inv", x[0..1], 347284278);
}

// A test `i + 3 <u n` of a counter from 0 by 2 becomes `i <u n - min(n, 3)` (`offset_test`) where a branch
// before the loop bounds `n` by `max - 1`: each sum stays below `n + 2`. Not without that bound, nor with it
// for a step by 4, whose sums may wrap past `max - 3`.
@test
fn tests_of_a_counter_by_a_wider_step_become_counted_under_a_bound() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @step2 fn global
sym @open2 fn global
sym @step4 fn global
fn @step2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 3
  v3 = iconst.i64 2
  v4 = iconst.i64 -2
  v5 = icmp.ule v0, v4
  br v5, b1, b5
b1:
  jmp b2(v1, v1)
b2(v6: i64, v7: i64):
  v8 = add.i64 v6, v2
  v9 = icmp.ult v8, v0
  br v9, b3, b4
b3:
  v10 = add.i64 v7, v6
  v11 = add.i64 v6, v3
  jmp b2(v11, v10)
b4:
  ret v7
b5:
  ret v1
fn @open2
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 3
  v3 = iconst.i64 2
  jmp b1(v1, v1)
b1(v4: i64, v5: i64):
  v6 = add.i64 v4, v2
  v7 = icmp.ult v6, v0
  br v7, b2, b3
b2:
  v8 = add.i64 v5, v4
  v9 = add.i64 v4, v3
  jmp b1(v9, v8)
b3:
  ret v5
fn @step4
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 3
  v3 = iconst.i64 4
  v4 = iconst.i64 -2
  v5 = icmp.ule v0, v4
  br v5, b1, b5
b1:
  jmp b2(v1, v1)
b2(v6: i64, v7: i64):
  v8 = add.i64 v6, v2
  v9 = icmp.ult v8, v0
  br v9, b3, b4
b3:
  v10 = add.i64 v7, v6
  v11 = add.i64 v6, v3
  jmp b2(v11, v10)
b4:
  ret v7
b5:
  ret v1
)",
    );
    let s2 = text_of(&a, "step2");
    assert(s2.contains("select.i64"), s2.as_str());
    let o2 = text_of(&a, "open2");
    assert(!o2.contains("select"), o2.as_str());
    let s4 = text_of(&a, "step4");
    assert(!s4.contains("select"), s4.as_str());
    for n in [0u64, 1, 2, 3, 4, 5, 6, 9, 10, 11] {
        let x: [u64; 1] = [n];
        let mut w2: u64 = 0;
        let mut i: u64 = 0;
        while i + 3 < n {
            w2 += i;
            i += 2;
        }
        let mut w4: u64 = 0;
        i = 0;
        while i + 3 < n {
            w4 += i;
            i += 4;
        }
        same_result(&b, &a, "step2", x[0..1], w2);
        same_result(&b, &a, "open2", x[0..1], w2);
        same_result(&b, &a, "step4", x[0..1], w4);
    }
}

// Block parameters that pass one another around a loop and its join, every other value they take one
// constant (a flag only a constant sets), are that constant (`param_cycles`): its test folds. A cycle that
// also takes another value stays.
@test
fn parameter_cycles_of_one_value_fold() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @flag fn global
sym @mixed fn global
fn @flag
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i8 0
  jmp b1(v1, v1, v3)
b1(v4: i64, v5: i64, v6: i8):
  v7 = icmp.ult v4, v0
  br v7, b2, b5
b2:
  v8 = and.i64 v4, v2
  v9 = icmp.ne v8, v1
  br v9, b3, b4(v6)
b3:
  jmp b4(v3)
b4(v10: i8):
  v11 = zext.i64 v10
  v12 = add.i64 v5, v4
  v13 = add.i64 v12, v11
  v14 = add.i64 v4, v2
  jmp b1(v14, v13, v10)
b5:
  ret v5
fn @mixed
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 0
  jmp b1(v2, v2, v1)
b1(v5: i64, v6: i64, v7: i8):
  v8 = icmp.ult v5, v0
  br v8, b2, b5
b2:
  v9 = icmp.ne v7, v4
  br v9, b3, b4(v7)
b3:
  v10 = add.i64 v6, v3
  jmp b4(v4)
b4(v11: i8):
  v12 = add.i64 v6, v5
  v13 = select.i64 v9, v10, v12
  v14 = add.i64 v5, v3
  jmp b1(v14, v13, v11)
b5:
  ret v6
)",
    );
    let f = text_of(&a, "flag");
    assert(!f.contains("i8"), f.as_str());
    let m = text_of(&a, "mixed");
    assert(m.contains("icmp.ne"), m.as_str());
    let x: [u64; 1] = [5];
    same_result(&b, &a, "flag", x[0..1], 10);
    let y: [u64; 2] = [5, 1];
    same_result(&b, &a, "mixed", y[0..2], 11);
}

// Cheap arithmetic can run on both sides of a select. Division, square root and long multiply chains
// stay conditional, both at returns and at a join.
@test
fn costly_float_arms_keep_their_branch() {
    let arms: []str = [
        "  v3 = fadd.f64 v1, v2\n",
        "  v3 = fdiv.f64 v1, v2\n",
        "  v3 = fsqrt.f64 v1\n",
        "  v3 = fmul.f64 v1, v2\n  v4 = fmul.f64 v3, v2\n  v5 = fmul.f64 v4, v2\n",
    ];
    for join in 0..2 {
        for i in 0..arms.len() {
            let mut src = String::from_str(
                "lir ptr 8\nsym @f fn global\nfn @f\n  sig (i8, f64, f64) -> f64\nb0(v0: i8, v1: f64, v2: f64):\n  br v0, b1, b2\nb1:\n",
            );
            src.push_str(arms[i]);
            let result = if i == 3 {
                5
            } else {
                3
            };
            if join == 0 {
                src.format_into("  ret v{}\nb2:\n  ret v2\n", result);
            } else {
                src.format_into(
                    "  jmp b3(v{})\nb2:\n  jmp b3(v2)\nb3(v{}: f64):\n  ret v{}\n",
                    result,
                    result + 1,
                    result + 1,
                );
            }
            let (_, after) = optimized(&src);
            let text = text_of(&after, "f");
            assert_eq(text.contains("br "), i != 0);
            assert_eq(text.contains("select.f64"), i == 0);
        }
    }
}

// A stepping iterator's loop: a flag only the first iteration sees set, an `Option` slot its `next`
// writes as a tag byte (`None`) or as its tag widened to a word over that byte (`Some`). The word's
// store spans the tag's field, so the slot becomes values (`lir::promote`); the jump that only passes
// them on and the test of the tag thread away (`Opt::thread`): no slot access and no tag test is left.
// In `wide`, a word load reads bytes only the word's store writes: its slot keeps its memory.
@test
fn a_tag_stored_as_a_word_over_its_byte_promotes_and_threads() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @steps fn global
sym @wide fn global
fn @steps
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = iconst.i8 0
  v2 = iconst.i64 0
  v3 = slotaddr s0
  v4 = iconst.i64 1
  v5 = iconst.i64 3
  v6 = iconst.i8 1
  jmp b1(v2, v2, v6)
b1(v7: i64, v8: i64, v9: i8):
  v10 = xor.i8 v9, v6
  br v10, b2, b6(v8)
b2:
  v11 = icmp.ult v8, v0
  br v11, b3, b5(v8)
b3:
  v12 = sub.i64 v0, v8
  v13 = icmp.uge v12, v5
  br v13, b4, b5(v0)
b4:
  v14 = add.i64 v8, v5
  jmp b6(v14)
b5(v15: i64):
  store v6, v3 align 0
  store v2, v3+8 align 0
  jmp b9(v15, v9)
b6(v16: i64):
  v17 = icmp.ult v16, v0
  br v17, b7, b8(v6, v2, v16)
b7:
  v18 = add.i64 v16, v4
  jmp b8(v1, v16, v18)
b8(v19: i8, v20: i64, v21: i64):
  v22 = zext.i64 v19
  store v22, v3 align 0
  store v20, v3+8 align 0
  jmp b9(v21, v1)
b9(v23: i64, v24: i8):
  v25 = load.i8 v3 align 0
  v26 = icmp.eq v25, v1
  br v26, b11, b10
b10:
  ret v7
b11:
  v27 = load.i64 v3+8 align 3
  v28 = add.i64 v7, v27
  jmp b1(v28, v23, v24)
fn @wide
  sig (i64, i8) -> i64
  slot s0 size 8 align 3
b0(v0: i64, v1: i8):
  v2 = slotaddr s0
  v3 = iconst.i8 1
  br v1, b1, b2
b1:
  store v3, v2 align 0
  jmp b3
b2:
  store v0, v2 align 3
  jmp b3
b3:
  v4 = load.i8 v2 align 0
  v5 = load.i64 v2 align 3
  v6 = zext.i64 v4
  v7 = add.i64 v5, v6
  ret v7
)",
    );
    let s = text_of(&a, "steps");
    assert(!s.contains("load") && !s.contains("store"), s.as_str());
    assert(!s.contains("icmp.eq"), s.as_str());
    let cases: [u64; 4] = [0, 1, 5, 10];
    let want: [u64; 4] = [0, 0, 4, 12];
    for c in 0..4 {
        let x: [u64; 1] = [cases[c]];
        same_result(&b, &a, "steps", x[0..1], want[c]);
    }
    let y: [u64; 2] = [0x123456789, 0];
    same_result(&b, &a, "wide", y[0..2], 0x123456789 + 0x89);
}

// The same loop once its slot is values: a block that only jumps on with the values it takes (the
// join of a branch whose sides differ in three of them, too many selects) is threaded through; then
// every edge into the tag's test passes a constant tag, the test threads along each, though blocks
// below its `Some` side read its other parameters (`Opt::apart`: one block only that side enters
// dominates them). No tag test is left.
@test
fn jumps_that_pass_parameters_on_thread() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @steps fn global
fn @steps
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i8 0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 3
  v5 = iconst.i8 1
  jmp b1(v2, v2, v5)
b1(v6: i64, v7: i64, v8: i8):
  v9 = xor.i8 v8, v5
  br v9, b2, b6(v7)
b2:
  v10 = icmp.ult v7, v0
  br v10, b3, b5(v7)
b3:
  v11 = sub.i64 v0, v7
  v12 = icmp.uge v11, v4
  br v12, b4, b5(v0)
b4:
  v13 = add.i64 v7, v4
  jmp b6(v13)
b5(v14: i64):
  jmp b9(v14, v8, v5, v2)
b6(v15: i64):
  v16 = icmp.ult v15, v0
  br v16, b7, b8(v5, v2, v15)
b7:
  v17 = add.i64 v15, v3
  jmp b8(v1, v15, v17)
b8(v18: i8, v19: i64, v20: i64):
  jmp b9(v20, v1, v18, v19)
b9(v21: i64, v22: i8, v23: i8, v24: i64):
  v25 = icmp.eq v23, v1
  br v25, b11, b10
b10:
  ret v6
b11:
  v26 = icmp.ult v24, v0
  br v26, b12, b10
b12:
  v27 = add.i64 v6, v24
  jmp b1(v27, v21, v22)
)",
    );
    let s = text_of(&a, "steps");
    assert(!s.contains("icmp.eq"), s.as_str());
    let cases: [u64; 4] = [0, 1, 5, 10];
    let want: [u64; 4] = [0, 0, 4, 12];
    for c in 0..4 {
        let x: [u64; 1] = [cases[c]];
        same_result(&b, &a, "steps", x[0..1], want[c]);
    }
}

// A branch on a parameter every edge into its block passes as a constant threads along each edge,
// though two blocks below its taken side read the block's other parameters: the block only that side
// enters dominates both (`Opt::apart`, the readers' nearest common dominator). No block is left that
// branches on the parameter alone.
@test
fn a_branch_threads_past_readers_its_side_dominates() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @found fn global
fn @found
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i8 0
  v2 = iconst.i8 1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 3
  jmp b1(v3, v3, v2)
b1(v6: i64, v7: i64, v8: i8):
  v9 = xor.i8 v8, v2
  br v9, b2, b5(v7)
b2:
  v10 = icmp.ult v7, v0
  br v10, b3, b7(v7, v8, v1, v3)
b3:
  v11 = sub.i64 v0, v7
  v12 = icmp.uge v11, v5
  br v12, b4, b7(v0, v8, v1, v3)
b4:
  v13 = add.i64 v7, v5
  jmp b5(v13)
b5(v14: i64):
  v15 = icmp.ult v14, v0
  br v15, b6, b7(v14, v1, v1, v3)
b6:
  v16 = add.i64 v14, v4
  jmp b7(v16, v1, v2, v14)
b7(v17: i64, v18: i8, v19: i8, v20: i64):
  br v19, b9, b8
b8:
  ret v6
b9:
  v21 = icmp.uge v20, v0
  br v21, b11, b10
b10:
  v22 = add.i64 v6, v20
  jmp b1(v22, v17, v18)
b11:
  ret v3
)",
    );
    let s = text_of(&a, "found");
    assert(!s.contains("i8, v"), s.as_str());
    let cases: [u64; 4] = [0, 1, 5, 10];
    let want: [u64; 4] = [0, 0, 4, 12];
    for c in 0..4 {
        let x: [u64; 1] = [cases[c]];
        same_result(&b, &a, "found", x[0..1], want[c]);
    }
}

// Inserts of one scalar into every lane of a vector, in any order, are its splat; inserts that leave a lane
// of the vector inserted into are not.
@test
fn inserts_of_one_scalar_into_every_lane_are_a_splat() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @every fn global
sym @three fn global
fn @every
  sig (i32) -> i32
b0(v0: i32):
  v1 = wconst.v4i32 0x700000007, 0x700000007
  v2 = vinsert.2.v4i32 v1, v0
  v3 = vinsert.0.v4i32 v2, v0
  v4 = vinsert.3.v4i32 v3, v0
  v5 = vinsert.1.v4i32 v4, v0
  v6 = vop.reduce_add.i32 (v5)
  ret v6
fn @three
  sig (i32) -> i32
b0(v0: i32):
  v1 = wconst.v4i32 0x700000007, 0x700000007
  v2 = vinsert.0.v4i32 v1, v0
  v3 = vinsert.1.v4i32 v2, v0
  v4 = vinsert.2.v4i32 v3, v0
  v5 = vop.reduce_add.i32 (v4)
  ret v5
)",
    );
    let e = text_of(&a, "every");
    assert(e.contains("splat.v4i32 v0") && !e.contains("vinsert"), e.as_str());
    let t = text_of(&a, "three");
    assert(!t.contains("splat"), t.as_str());
    let x: [u64; 1] = [5];
    same_result(&b, &a, "every", x[0..1], 20);
    same_result(&b, &a, "three", x[0..1], 22);
}

// A sum of four adjacent loads packs into a vector and its lane sum (`reduce_add`) where a halving step of
// the lane sum costs nothing past the addition it replaces (`Package.vec_reduce` 0), not where it costs 4
// (wasm32's shuffle through a local). The result stays.
@test
fn lane_sums_pack_where_they_are_cheap() {
    let text = M"(lir ptr 8
sym @sum4 fn global noinline
sym @drive fn global
sym @arr data global
fn @sum4
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = load.i32 v0+4 align 2
  v3 = load.i32 v0+8 align 2
  v4 = load.i32 v0+12 align 2
  v5 = add.i32 v1, v2
  v6 = add.i32 v5, v3
  v7 = add.i32 v6, v4
  ret v7
fn @drive
  sig () -> i32
b0:
  v0 = symaddr @arr
  v1 = call.i32 @sum4(v0) : (ptr) -> i32
  ret v1
data @arr size 16 align 2 bytes 07000000fdffffffa0860100ffffff7f
)";
    let mut err = String::new();
    let b = lparse::parse(text, &mut err).unwrap();
    let none = Vector::<bool>::new();
    let steps: [u8; 2] = [0, 4];
    for k in 0..2usize {
        let mut a = lparse::parse(text, &mut err).unwrap();
        a.vec_reduce = steps[k];
        lopt::optimize(
            &mut a,
            &none,
            lopt::Config {
                inline: il::SPEED,
                loops: lu::Budgets {
                    peel: 0,
                    partial: 0,
                    version: 0,
                    version_checks: u32::MAX,
                    unswitch: 0,
                    rotate: 0,
                    vector: 4,
                    interleave: 4,
                    fin: 0,
                },
            },
        );
        let t = text_of(&a, "sum4");
        assert(t.contains("reduce_add") == (k == 0), t.as_str());
        let none_args: []u64 = [];
        same_result(&b, &a, "drive", none_args, 2147583651);
    }
}

// The element-wise sum of two aggregates of four `f32`s into a third: where the calling convention passes
// such an aggregate one element per register (`Package.hfa_regs`, AAPCS64), its loads and the result's
// stores stay scalars, which the native backend takes from and returns in those registers; elsewhere they
// pack into vectors (`lir::slp`).
@test
fn float_aggregates_in_registers_do_not_pack() {
    let text = M"(lir ptr 8
sym @add4 fn global noinline
sym @drive fn global
fn @add4
  layout l0 size 16 align 2 [0 f32, 4 f32, 8 f32, 12 f32]
  sig (l0, l0) -> l0
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.f32 v0 align 2
  v4 = load.f32 v0+4 align 2
  v5 = load.f32 v0+8 align 2
  v6 = load.f32 v0+12 align 2
  v7 = load.f32 v1 align 2
  v8 = load.f32 v1+4 align 2
  v9 = load.f32 v1+8 align 2
  v10 = load.f32 v1+12 align 2
  v11 = fadd.f32 v3, v7
  v12 = fadd.f32 v4, v8
  v13 = fadd.f32 v5, v9
  v14 = fadd.f32 v6, v10
  store v11, v2 align 2
  store v12, v2+4 align 2
  store v13, v2+8 align 2
  store v14, v2+12 align 2
  ret
fn @drive
  layout l0 size 16 align 2 [0 f32, 4 f32, 8 f32, 12 f32]
  sig (i32) -> i32
  slot s0 size 16 align 2
  slot s1 size 16 align 2
  slot s2 size 16 align 2
b0(v0: i32):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = sitofp.f32 v0
  v5 = fconst.f32 0x3fc00000
  store v4, v1 align 2
  store v5, v1+4 align 2
  store v4, v1+8 align 2
  store v5, v1+12 align 2
  store v5, v2 align 2
  store v5, v2+4 align 2
  store v4, v2+8 align 2
  store v4, v2+12 align 2
  call @add4(v1, v2, v3) : (l0, l0) -> l0
  v6 = load.f32 v3+8 align 2
  v7 = fptosi.i32 v6
  ret v7
)";
    let mut err = String::new();
    let b = lparse::parse(text, &mut err).unwrap();
    let none = Vector::<bool>::new();
    let packs: []bool = [false, true];
    for k in 0..2usize {
        let mut a = lparse::parse(text, &mut err).unwrap();
        a.hfa_regs = packs[k];
        lopt::optimize(
            &mut a,
            &none,
            lopt::Config {
                inline: il::SPEED,
                loops: lu::Budgets {
                    peel: 0,
                    partial: 0,
                    version: 0,
                    version_checks: u32::MAX,
                    unswitch: 0,
                    rotate: 0,
                    vector: 4,
                    interleave: 4,
                    fin: 0,
                },
            },
        );
        let t = text_of(&a, "add4");
        assert(t.contains("v4f32") != packs[k], t.as_str());
        let x: []u64 = [7];
        same_result(&b, &a, "drive", x, 14);
    }
}

// A slot of constant stores that a direct call takes as an aggregate its callee only loads from goes to
// read-only data, the address in it a relocation, the stores and the values only they read gone: `@site`'s
// two string-like pairs (one stored whole as `or` of the address's zero extension and the length above
// it, one field by field) become data. `@poke` writes its parameter, so `@other`'s pair stays a slot.
// Both give the results they gave.
@test
fn constant_aggregate_arguments_a_callee_only_reads_go_to_data() {
    let text = M"(lir ptr 4
sym @msg data global
sym @take fn global noinline
sym @poke fn global noinline
sym @site fn global
sym @other fn global
data @msg size 4 align 0 ro bytes 68692100
fn @take
  layout l0 size 8 align 2 [0 ptr, 4 i32]
  sig (l0, l0) -> i32
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0+4 align 2
  v3 = load.ptr v1 align 2
  v4 = load.i8 v3+1 align 0
  v5 = zext.i32 v4
  v6 = add.i32 v2, v5
  v7 = load.i32 v1+4 align 2
  v8 = add.i32 v6, v7
  ret v8
fn @poke
  layout l0 size 8 align 2 [0 ptr, 4 i32]
  sig (l0) -> i32
b0(v0: ptr):
  v1 = iconst.i32 9
  store v1, v0+4 align 2
  v2 = load.i32 v0+4 align 2
  ret v2
fn @site
  layout l0 size 8 align 2 [0 ptr, 4 i32]
  sig () -> i32
  slot s0 size 8 align 2
  slot s1 size 8 align 2
b0:
  v0 = slotaddr s0
  v1 = symaddr @msg
  v2 = ptrtoint.i32 v1
  v3 = zext.i64 v2
  v4 = iconst.i64 12884901888
  v5 = or.i64 v3, v4
  store v5, v0 align 2
  v6 = slotaddr s1
  store v1, v6 align 2
  v7 = iconst.i32 5
  store v7, v6+4 align 2
  v8 = call.i32 @take(v0, v6) : (l0, l0) -> i32
  ret v8
fn @other
  layout l0 size 8 align 2 [0 ptr, 4 i32]
  sig () -> i32
  slot s0 size 8 align 2
b0:
  v0 = slotaddr s0
  v1 = symaddr @msg
  store v1, v0 align 2
  v2 = iconst.i32 3
  store v2, v0+4 align 2
  v3 = call.i32 @poke(v0) : (l0) -> i32
  ret v3
)";
    let (b, a) = optimized(text);
    let s = text_of(&a, "site");
    assert(
        !s.contains("slotaddr") && !s.contains("or.i64") && !s.contains("ptrtoint") && s.contains("@site.const0") && s.contains(
            "@site.const1",
        ),
        s.as_str(),
    );
    let o = text_of(&a, "other");
    assert(o.contains("slotaddr"), o.as_str());
    let none: []u64 = [];
    same_result(&b, &a, "other", none, 9);
    // With 8-byte pointers (which the evaluator keeps whole) `@site` gives the sum it gave.
    let wide = M"(lir ptr 8
sym @msg data global
sym @take fn global noinline
sym @site fn global
data @msg size 4 align 0 ro bytes 68692100
fn @take
  layout l0 size 16 align 3 [0 ptr, 8 i32]
  sig (l0, l0) -> i32
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0+8 align 3
  v3 = load.ptr v1 align 3
  v4 = load.i8 v3+1 align 0
  v5 = zext.i32 v4
  v6 = add.i32 v2, v5
  v7 = load.i32 v1+8 align 3
  v8 = add.i32 v6, v7
  ret v8
fn @site
  layout l0 size 16 align 3 [0 ptr, 8 i32]
  sig () -> i32
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0:
  v0 = slotaddr s0
  v1 = symaddr @msg
  store v1, v0 align 3
  v2 = iconst.i32 3
  store v2, v0+8 align 3
  v3 = slotaddr s1
  store v1, v3 align 3
  v4 = iconst.i32 5
  store v4, v3+8 align 3
  v5 = call.i32 @take(v0, v3) : (l0, l0) -> i32
  ret v5
)";
    let (wb, wa) = optimized(wide);
    let ws = text_of(&wa, "site");
    assert(!ws.contains("slotaddr"), ws.as_str());
    same_result(&wb, &wa, "site", none, 3 + 0x69 + 5);
}

// A call cannot reach a slot whose address has not escaped on any path before it (`Opt::slot_escapes`):
// `@f`'s field load after `@ext` takes the stored value, though `@take` lets the slot escape later; `@g`
// passes the slot to `@take` first, so its load after `@ext` stays, and so does `@h`'s in a loop whose
// earlier iteration passed it.
@test
fn a_call_before_a_slots_escape_keeps_its_fields() {
    let (_b, a) = optimized(
        M"(lir ptr 8
sym @ext fn global
sym @take fn global
sym @f fn global
sym @g fn global
sym @h fn global
fn @f
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  v2 = call.i64 @ext() : () -> i64
  v3 = load.i64 v1 align 3
  v4 = add.i64 v3, v2
  store v4, v1+8 align 3
  call @take(v1) : (ptr) -> void
  v5 = load.i64 v1+8 align 3
  ret v5
fn @g
  sig (i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  call @take(v1) : (ptr) -> void
  v2 = call.i64 @ext() : () -> i64
  v3 = load.i64 v1 align 3
  v4 = add.i64 v3, v2
  ret v4
fn @h
  sig (i64) -> i64
  slot s0 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1 align 3
  jmp b1(v0)
b1(v2: i64):
  store v2, v1 align 3
  v3 = call.i64 @ext() : () -> i64
  v4 = load.i64 v1 align 3
  call @take(v1) : (ptr) -> void
  v5 = add.i64 v2, v4
  v6 = icmp.ult v5, v3
  br v6, b1(v5), b2
b2:
  ret v5
)",
    );
    let f = text_of(&a, "f");
    let g = text_of(&a, "g");
    let h = text_of(&a, "h");
    assert(h.as_str().find("load.i64") > h.as_str().find("call.i64 @ext"), h.as_str());
    // `@f`: its one load is the one after `@take`; `@g`: a load after `@ext`.
    assert(f.as_str().find("load.i64") > f.as_str().find("call @take"), f.as_str());
    assert(g.as_str().find("load.i64") > g.as_str().find("call.i64 @ext"), g.as_str());
}

// `optimized` for a target of `vector`-byte vectors that chains conditional comparisons when `ccmp` and
// pairs no accesses.
fn optimized_target(text: str, vector: u32, ccmp: bool) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.vector = vector;
    after.ccmp = ccmp;
    after.apairs = false;
    let none = Vector::<bool>::new();
    // Straight-line values pack where vectors interleave (`lir::slp`).
    let nv: u32 = if vector != 0 {
        2
    } else {
        0
    };
    lopt::optimize(
        &mut after,
        &none,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: nv,
                interleave: nv,
                fin: 0,
            },
        },
    );
    verified(&after);
    return (before, after);
}

const WIDE_EQ: str = M"(lir ptr 8
sym @memcmp fn global
sym @s data global
sym @w data global
sym @eq40 fn global
sym @chain fn global
fn @eq40
  sig (i64) -> i8
b0(v0: i64):
  v1 = symaddr @s
  v2 = symaddr @w
  v3 = iconst.i64 40
  v4 = iconst.i32 0
  v5 = ptradd v2, v0 * 1
  v6 = call.i32 @memcmp(v5, v1, v3) : (ptr, ptr, i64) -> i32
  v7 = icmp.eq v6, v4
  ret v7
fn @chain
  sig (i64, i64, i64) -> i8
b0(v0: i64, v1: i64, v2: i64):
  v3 = symaddr @s
  v4 = symaddr @w
  v5 = iconst.i64 40
  v6 = iconst.i32 0
  v7 = iconst.i8 0
  v8 = icmp.eq v0, v5
  br v8, b1, b4
b1:
  v9 = icmp.eq v1, v5
  br v9, b2, b4
b2:
  v10 = icmp.eq v0, v1
  br v10, b3, b4
b3:
  v11 = ptradd v4, v2 * 1
  v12 = call.i32 @memcmp(v11, v3, v0) : (ptr, ptr, i64) -> i32
  v13 = icmp.eq v12, v6
  ret v13
b4:
  ret v7
data @s size 64 align 0 ro bytes 68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f000000000000000000000000000000000000000000000000
data @w size 80 align 0 bytes 68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f68656c6c6f00000000000000000000000000000000000000000000000000000000000000000000000000000000
)";

// An equality `memcmp` of up to 64 bytes expands: in 8-byte pairs, or where the target computes 16-byte
// vectors and chains no conditional comparisons, in 16-byte pairs (the last overlapping), its read-only
// side constants; a count the branches up the chain of blocks into the call settle (each length tested
// against 40, then against each other, which folds) counts too. A `memcmp` the package defines (wasm32's C
// library) expands as the C library's does.
@test
fn equalities_of_up_to_64_bytes_expand() {
    let (b, a) = optimized_target(WIDE_EQ, 0, true);
    let e = text_of(&a, "eq40");
    assert(!e.contains("call") && count_of(&e, "load.i64") == 5, e.as_str());
    let c = text_of(&a, "chain");
    assert(!c.contains("call") && !c.contains("icmp.eq v0, v1"), c.as_str());
    let (_vb, va) = optimized_target(WIDE_EQ, 16, false);
    let v = text_of(&va, "eq40");
    assert(
        !v.contains("call") && count_of(&v, "load.v16i8") == 3 && count_of(&v, "wconst.v16i8") == 3 && v.contains(
            "reduce_or",
        ),
        v.as_str(),
    );
    let (_db, da) = optimized_target(
        M"(lir ptr 8
sym @memcmp fn global
sym @five fn global
fn @memcmp
  sig (ptr, ptr, i64) -> i32
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i32 1
  ret v3
fn @five
  sig (ptr, ptr) -> i8
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 5
  v3 = iconst.i32 0
  v4 = call.i32 @memcmp(v0, v1, v2) : (ptr, ptr, i64) -> i32
  v5 = icmp.eq v4, v3
  ret v5
)",
        0,
        true,
    );
    let f = text_of(&da, "five");
    assert(!f.contains("call"), f.as_str());
    for q in 0..2u64 {
        let o: []u64 = [q];
        same_result(&b, &a, "eq40", o, 1 - q);
        same_result(&b, &va, "eq40", o, 1 - q);
        let ch: []u64 = [40, 40, q];
        same_result(&b, &a, "chain", ch, 1 - q);
    }
}

// Two sides of a branch that copy one aggregate or another into one place and return: one copy of the
// select of the two sources. Same instructions with three differences keep the branch.
@test
fn a_choice_of_two_aggregates_copies_once() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @pick fn global
fn @pick
  sig (i8, ptr, ptr, ptr) -> i64
b0(v0: i8, v1: ptr, v2: ptr, v3: ptr):
  v4 = iconst.i64 16
  br v0, b1, b2
b1:
  memcpy v1, v2, v4
  v5 = load.i64 v1 align 3
  ret v5
b2:
  memcpy v1, v3, v4
  v6 = load.i64 v1 align 3
  ret v6
)",
    );
    let p = text_of(&a, "pick");
    assert(count_of(&p, "memcpy") == 1 && p.contains("select.ptr") && !p.contains("br "), p.as_str());
    let _ = b;
}

// A call's aggregate result copied into the body's own aggregate result: the call writes the body's
// result (the caller passes memory no other pointer of the call reaches, an `sret`), the copy goes.
@test
fn a_result_passed_on_is_written_in_place() {
    let (_b, a) = optimized(
        M"(lir ptr 8
sym @make fn global noinline
sym @fwd fn global
fn @make
  layout l0 size 32 align 3 [0 i64, 8 i64, 16 i64, 24 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  store v0, v1 align 3
  store v0, v1+24 align 3
  ret
fn @fwd
  layout l0 size 32 align 3 [0 i64, 8 i64, 16 i64, 24 i64]
  sig (i64) -> l0
  slot s0 size 32 align 3
b0(v0: i64, v1: ptr):
  v2 = slotaddr s0
  v3 = iconst.i64 32
  call @make(v0, v2) : (i64) -> l0
  memcpy.overlap v1, v2, v3
  ret
)",
    );
    let f = text_of(&a, "fwd");
    assert(!f.contains("memcpy") && f.contains("call @make(v0, v1)"), f.as_str());
}

// Stores of a value and of that value plus 1 to 7 at consecutive places pack as vector sums of the value
// in every lane and the constants (the value's lane adds 0), on a target of 16-byte vectors; on a target
// that pairs scalar stores (`Package.apairs`) the scalar stores stay, which take as few instructions.
@test
fn a_value_and_its_neighbours_pack_with_an_identity_lane() {
    let text = M"(lir ptr 8
sym @mk fn global
fn @mk
  sig (i64, ptr) -> void
b0(v0: i64, v1: ptr):
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = iconst.i64 3
  v5 = iconst.i64 4
  v6 = iconst.i64 5
  v7 = iconst.i64 6
  v8 = iconst.i64 7
  v9 = add.i64 v0, v2
  v10 = add.i64 v0, v3
  v11 = add.i64 v0, v4
  v12 = add.i64 v0, v5
  v13 = add.i64 v0, v6
  v14 = add.i64 v0, v7
  v15 = add.i64 v0, v8
  store v0, v1 align 3
  store v9, v1+8 align 3
  store v10, v1+16 align 3
  store v11, v1+24 align 3
  store v12, v1+32 align 3
  store v13, v1+40 align 3
  store v14, v1+48 align 3
  store v15, v1+56 align 3
  ret
)";
    let (b, a) = optimized_target(text, 16, false);
    let m = text_of(&a, "mk");
    assert(count_of(&m, "add.v2i64") == 4 && count_of(&m, "store") == 4, m.as_str());
    let mut err = String::new();
    let mut p = lparse::parse(text, &mut err).unwrap();
    p.vector = 16;
    p.apairs = true;
    let none = Vector::<bool>::new();
    lopt::optimize(
        &mut p,
        &none,
        lopt::Config {
            inline: il::SPEED,
            loops: lu::Budgets {
                peel: 0,
                partial: 0,
                version: 0,
                version_checks: u32::MAX,
                unswitch: 0,
                rotate: 0,
                vector: 2,
                interleave: 2,
                fin: 0,
            },
        },
    );
    let q = text_of(&p, "mk");
    assert(!q.contains("v2i64"), q.as_str());
    let _ = b;
}

// A by-value aggregate argument that the call reads from its copy's source (the callee writes and keeps
// no parameter; x86-64 passes it in memory, which the backend copies): the copy into a slot nothing else
// reads goes, also when the walk that passed the source changed nothing else in the body.
@test
fn a_copy_an_argument_no_longer_reads_goes() {
    let (_b, a) = optimized_copy(
        M"(lir ptr 8
sym @mkb fn global used noinline
sym @bump fn global used noinline
sym @relay fn global used noinline
fn @mkb
  layout l0 size 64 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64, 40 i64, 48 i64, 56 i64]
  sig (i64) -> l0
b0(v0: i64, v1: ptr):
  store v0, v1 align 3
  store v0, v1+56 align 3
  ret
fn @bump
  layout l0 size 64 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64, 40 i64, 48 i64, 56 i64]
  sig (l0) -> l0
b0(v0: ptr, v1: ptr):
  v2 = load.v2i64 v0 align 0
  v3 = load.v2i64 v0+16 align 0
  v4 = load.v2i64 v0+32 align 0
  v5 = load.v2i64 v0+48 align 0
  v6 = wconst.v2i64 0x1, 0x0
  v7 = add.v2i64 v2, v6
  store v7, v1 align 0
  store v3, v1+16 align 0
  store v4, v1+32 align 0
  store v5, v1+48 align 0
  ret
fn @relay
  layout l0 size 64 align 3 [0 i64, 8 i64, 16 i64, 24 i64, 32 i64, 40 i64, 48 i64, 56 i64]
  sig (i64) -> i64
  slot s0 size 64 align 3
  slot s1 size 64 align 3
  slot s2 size 64 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 64
  call @mkb(v0, v1) : (i64) -> l0
  memcpy.overlap v3, v1, v4
  call @bump(v3, v2) : (l0) -> l0
  v5 = load.i64 v2 align 3
  v6 = load.i64 v2+56 align 3
  v7 = add.i64 v5, v6
  ret v7
)",
        0xFFFFFFFF,
        16,
    );
    let r = text_of(&a, "relay");
    assert(!r.contains("memcpy") && r.contains("call @bump(v1"), r.as_str());
}

// Seventy-two owned buffers before the three the loops reach; pushes through `&mut self.work`, whose growth
// stays a cold call, at several sites before the loops (copies that share one root) and, through an
// inlined helper, in them; a load of the read vector's first element in the loop.
const MARKS: str<'static> = M"(struct Q {
    a: Vector<u32>,
    b: Vector<u32>,
    c: Vector<u32>,
    d: Vector<u32>,
}

struct S {
    q0: Q,
    q1: Q,
    q2: Q,
    q3: Q,
    q4: Q,
    q5: Q,
    q6: Q,
    q7: Q,
    q8: Q,
    q9: Q,
    q10: Q,
    q11: Q,
    q12: Q,
    q13: Q,
    q14: Q,
    q15: Q,
    q16: Q,
    q17: Q,
    live: Vector<bool>,
    work: Vector<u32>,
    uses: Vector<u32>,
}

extend S {
    fn mark(self: &mut Self, x: u32) {
        if !self.live[x as usize] {
            self.live[x as usize] = true;
            self.work.push(x);
        }
    }

    @noinline
    fn mark_all(self: &mut Self, first: u32) {
        self.work.truncate(0);
        self.work.reserve(4);
        self.work.push(first);
        for u in 0..self.uses.len() {
            self.mark((self.uses[u] + self.uses[0]) % 31);
        }
        self.work.truncate(self.work.len() - 1);
    }

    @noinline
    fn mark_rest(self: &mut Self, first: u32) {
        self.work.push(first);
        for u in 0..self.uses.len() {
            self.mark(self.uses[u]);
        }
    }
}

fn main() i32 {
    let mut s = S {
        q0: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q1: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q2: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q3: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q4: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q5: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q6: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q7: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q8: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q9: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q10: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q11: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q12: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q13: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q14: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q15: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q16: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        q17: Q { a: Vector::<u32>::new(), b: Vector::<u32>::new(), c: Vector::<u32>::new(), d: Vector::<u32>::new() },
        live: Vector::<bool>::new(),
        work: Vector::<u32>::new(),
        uses: Vector::<u32>::new(),
    };
    for k in 0..40u32 {
        s.live.push(false);
        s.uses.push(k * 7 % 31);
    }
    s.mark_all(3);
    s.mark_rest(5);
    println("{} {}", s.work.len(), s.work[s.work.len() - 1]);
    return 0;
}
)";

// The loads of the first loop of printed body `m`: the blocks from the latest one a branch goes back to
// through that branch's block, in the text's order.
fn loop_loads(m: str) u32 {
    let mut labels = Vector::<str>::new();
    let mut loads = Vector::<u32>::new();
    for l in m.lines() {
        if l.starts_with("b") {
            let mut e: usize = 1;
            while e < l.len() && l.byte_at(e) >= b'0' && l.byte_at(e) <= b'9' {
                e += 1;
            }
            labels.push(l.slice(0, e));
            loads.push(0);
            continue;
        }
        if labels.len() == 0 {
            continue;
        }
        let k = loads.len() - 1;
        if l.contains("= load") {
            loads[k] += 1;
        }
        if l.contains(" br ") || l.contains(" jmp ") {
            // The header is the latest block before the branch it names: an exit may come earlier.
            for d in 0..k + 1 {
                let x = k - d;
                let (open, comma, gap) = (
                    format(" {}(", labels[x]),
                    format(" {},", labels[x]),
                    format(" {} ", labels[x])
                );
                if l.contains(&open) || l.contains(&comma) || l.contains(&gap) {
                    let mut n: u32 = 0;
                    for y in x..k + 1 {
                        n += loads[y];
                    }
                    return n;
                }
            }
        }
    }
    return 0;
}

// The loops load the vector the push writes, its length and capacity, and the elements they read; the
// read vectors' buffers, lengths and first element leave them: whatever the referent's owned buffers
// before them, past the growth's cold call (its span reaches only that vector's fields), past copies whose
// shared root a call outside them takes. Both profiles print the same.
@test
fn loop_loads_of_other_fields_leave_past_a_push() {
    let text = same_and_printed("marks", MARKS, "mark_");
    let all = loop_loads(printed(&text, "S__mark_all"));
    let rest = loop_loads(printed(&text, "S__mark_rest"));
    let ok = all != 0 && all <= 6 && rest != 0 && rest <= 6;
    if !ok {
        eprintln("{}", text.as_str());
        eprint("loop loads: {} {}\n", all, rest);
    }
    assert(ok, "only the pushed vector's fields and the read elements load in the loops");
}

// A load of read-only data reads one value in every memory state: an untagged byte store through a
// parameter between two loads of one table entry leaves one load.
@test
fn a_read_only_table_load_holds_across_stores() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @tab data global
sym @f fn global
fn @f
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = symaddr @tab
  v3 = ptradd v2, v1 * 1
  v4 = load.i8 v3 align 0
  v5 = iconst.i8 7
  store v5, v0 align 0
  v6 = load.i8 v3 align 0
  v7 = add.i8 v4, v6
  v8 = zext.i32 v7
  ret v8
data @tab size 8 align 0 ro bytes 0102030405060708
)",
    );
    let before = text_of(&b, "f");
    let after = text_of(&a, "f");
    assert(count_of(&before, "= load") == 2, before.as_str());
    assert(count_of(&after, "= load") == 1, after.as_str());
}

// A slot that only a copy of a by-value aggregate argument writes reads that argument: its loads read the
// argument's bytes, across stores to other memory; a call takes the argument in its place when the target
// copies the aggregate, and the copy and the slot go. Passed by address, the copy stays for the call.
const PRIVATE_COPY: str = M"(lir ptr 8
sym @g fn global noinline
sym @f fn global
fn @g
  layout l0 size 16 align 2 [0 i32, 4 i32, 8 i32, 12 i16, 14 i8, 15 i8]
  sig (l0) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  ret v1
fn @f
  layout l0 size 16 align 2 [0 i32, 4 i32, 8 i32, 12 i16, 14 i8, 15 i8]
  sig (ptr, l0) -> i32
  slot s0 size 16 align 2
b0(v0: ptr, v1: ptr):
  v2 = slotaddr s0
  v3 = iconst.i64 16
  memcpy.overlap v2, v1, v3
  v4 = load.i32 v2+4 align 2
  store v4, v0 align 2
  v5 = load.i32 v2+8 align 2
  store v5, v0+4 align 2
  v6 = call.i32 @g(v2) : (l0) -> i32
  v7 = add.i32 v4, v6
  ret v7
)";

@test
fn a_private_copy_of_an_argument_reads_and_passes_the_argument() {
    let (_, a) = optimized_copy(PRIVATE_COPY, 16, 16);
    let r = text_of(&a, "f");
    assert(!r.contains("memcpy") && !r.contains("slot") && r.contains("@g(v1)"), r.as_str());
    let (_, m) = optimized_copy(PRIVATE_COPY, 0, 16);
    let q = text_of(&m, "f");
    assert(q.contains("memcpy") && q.contains("load.i32 v1+4") && q.contains("load.i32 v1+8"), q.as_str());
}

// A load of a slot whose every store of its bytes stores one value, one of them before it on every path,
// reads that value, across calls that read the slot and write other memory: the slot the calls read stays,
// its loads go.
@test
fn stores_of_one_value_give_a_load_that_value() {
    let (_, a) = optimized(
        M"(lir ptr 8
sym @g fn global noinline
sym @f fn global
fn @g
  sig (ptr, ptr) -> i32
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0 align 2
  store v2, v1 align 2
  ret v2
fn @f
  sig (i32, ptr) -> i32
  slot s0 size 4 align 2
b0(v0: i32, v1: ptr):
  v2 = slotaddr s0
  store v0, v2 align 2
  v3 = call.i32 @g(v2, v1) : (ptr, ptr) -> i32
  v4 = load.i32 v2 align 2
  store v0, v2 align 2
  v5 = call.i32 @g(v2, v1) : (ptr, ptr) -> i32
  v6 = load.i32 v2 align 2
  v7 = add.i32 v4, v6
  v8 = add.i32 v7, v3
  v9 = add.i32 v8, v5
  ret v9
)",
    );
    let r = text_of(&a, "f");
    assert(r.contains("call.i32 @g") && !r.contains("= load"), r.as_str());
}

const TRUNCATE: str<'static> = M"(@noinline
fn clear_all(v: &mut Vector<u32>) {
    v.truncate(0);
}

fn main() i32 {
    let mut v = Vector::<u32>::new();
    for k in 0..5u32 {
        v.push(k);
    }
    v.truncate(9);
    let before = v.len();
    v.truncate(2);
    let mid = v.len();
    clear_all(&mut v);
    println("{} {} {}", before, mid, v.len());
    return 0;
}
)";

// A truncation to 0 of a vector of elements without a drop is one store of its length: no load, no branch.
// Both profiles print the same lengths.
@test
fn a_truncation_to_zero_is_one_store() {
    let text = same_and_printed("truncate", TRUNCATE, "clear_all");
    let m = printed(&text, "clear_all");
    let ok = m.contains("store") && !m.contains("= load") && !m.contains(" br ");
    if !ok {
        eprintln("{}", text.as_str());
    }
    assert(ok, "one store");
}

// A chain of branches to one block, each block between them one `==` test of one value, is one branch on
// their `or` (`common_true`), which the bit test of the constants' mask then decides: at most one `br`, a
// shift, no `icmp.eq`. The value is the same for each input.
@test
fn an_or_chain_of_equalities_is_one_bit_test() {
    let (before, after) = optimized(
        M"(lir ptr 8
sym @chain fn global
fn @chain
  sig (i8) -> i32
b0(v0: i8):
  v1 = iconst.i8 12
  v2 = icmp.eq v0, v1
  br v2, b4, b1
b1:
  v3 = iconst.i8 13
  v4 = icmp.eq v0, v3
  br v4, b4, b2
b2:
  v5 = iconst.i8 14
  v6 = icmp.eq v0, v5
  br v6, b4, b3
b3:
  v7 = iconst.i8 21
  v8 = icmp.eq v0, v7
  br v8, b4, b5
b4:
  v9 = iconst.i32 7
  ret v9
b5:
  v10 = iconst.i32 0
  ret v10
)",
    );
    let t = text_of(&after, "chain");
    assert(count_of(&t, " br ") <= 1 && t.as_str().contains("lshr") && !t.as_str().contains("icmp.eq"), t.as_str());
    for x in 0..70u64 {
        let want: u64 = if x == 12 || x == 13 || x == 14 || x == 21 {
            7
        } else {
            0
        };
        same_result(&before, &after, "chain", [x], want);
    }
}

// A pointer's constant index, an index plus a constant, and an index times a constant whose product with
// the scale does not fit 64 bits fold without overflow (`simplify`): each address is the same modulo 2^64.
@test
fn huge_index_constants_fold_without_overflow() {
    let (before, after) = optimized(
        M"(lir ptr 8
sym @at_const fn global
sym @at_sum fn global
sym @at_product fn global
fn @at_const
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 4611686018427387905
  v2 = ptradd v0, v1 * 4
  v3 = ptrtoint.i64 v2
  ret v3
fn @at_sum
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 4611686018427387905
  v3 = add.i64 v1, v2
  v4 = ptradd v0, v3 * 4
  v5 = ptrtoint.i64 v4
  ret v5
fn @at_product
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 9223372036854775807
  v3 = mul.i64 v1, v2
  v4 = ptradd v0, v3 * 4
  v5 = ptrtoint.i64 v4
  ret v5
)",
    );
    same_result(&before, &after, "at_const", [1000], 1004);
    same_result(&before, &after, "at_sum", [1000, 3], 1016);
    same_result(&before, &after, "at_product", [1000, 3], 988);
}

// A copy of 8 bytes into a slot whose fields are two `i32`, and out of it, waits for the promotion, which
// makes it loads and stores of the fields in their type: no `i64` that packs both, no shift that unpacks
// them.
@test
fn a_copy_through_a_slot_moves_its_fields() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @update fn global noinline
sym @drive fn global
fn @update
  sig (ptr, ptr) -> void
  slot s0 size 8 align 2
b0(v0: ptr, v1: ptr):
  v2 = slotaddr s0
  v3 = iconst.i64 8
  memcpy v2, v1, v3
  v4 = load.i32 v2 align 2
  v5 = load.i32 v2+4 align 2
  v6 = add.i32 v4, v5
  store v6, v2+4 align 2
  memcpy v0, v2, v3
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 8 align 3
  slot s1 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  store v0, v1 align 3
  call @update(v2, v1) : (ptr, ptr) -> void
  v3 = load.i64 v2 align 3
  ret v3
)",
    );
    let u = text_of(&a, "update");
    assert(!u.contains("i64") && !u.contains("lshr") && !u.contains("slot") && u.contains("load.i32 v1+4"), u.as_str());
    let xs: [u64; 3] = [0x0000000500000007, 0xFFFFFFFF00000001, 0x7FFFFFFF7FFFFFFF];
    for k in 0..3usize {
        let x = unsafe xs[k];
        let lo = x as u32;
        let hi = lo.wrapping_add((x >> 32) as u32);
        let args: []u64 = [x];
        same_result(&b, &a, "drive", args, lo as u64 | hi as u64 << 32);
    }
}

// A copy into the bytes an inlined call's exclusive parameter points to (a root of the call's scope, an
// offset into the caller's parameter) changes them for a read after the call through the caller's
// parameter, of another call's scope, as for one in the copy that the optimizer folded onto that address:
// the read loads again (`Opt::write_bits`, the roots' base class).
@test
fn a_write_through_an_inlined_calls_parameter_reaches_the_reads_after_it() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "t.spc"
sym @fill fn global noinline
sym @f fn global noinline
sym @top fn global
fn @fill
  sig (ptr) -> void
b0(v0: ptr):
  v1 = iconst.i64 7
  store v1, v0+8 align 3
  ret
fn @f
  file f0
  sig (ptr) -> i64
  ref p0 40 noalias
  owned p0 16
  scope @20:3 g0 v4
  scope @40:3 g0 v0
  slot s0 size 24 align 3
b0(v0: ptr):
  v1 = slotaddr s0
  v2 = iconst.i64 24
  v3 = iconst.i64 0
  store v3, v1 align 3
  store v3, v1+8 align 3
  store v3, v1+16 align 3
  call @fill(v1) : (ptr) -> void
  v4 = ptradd v0+16 inbounds nonnull !20:9
  v5 = load.i64 v0+24 align 0 !10:5@20:3
  memcpy.overlap v4, v1, v2 !11:5@20:3
  v6 = load.i64 v0+24 align 3 tbaa 4 !30:5@40:3
  v7 = icmp.eq v6, v3
  br v7, b1, b2
b1:
  ret v5
b2:
  v8 = add.i64 v6, v5
  ret v8
fn @top
  sig (i64) -> i64
  slot s0 size 40 align 3
b0(v0: i64):
  v1 = slotaddr s0
  store v0, v1+24 align 3
  v2 = call.i64 @f(v1) : (ptr) -> i64
  ret v2
)",
    );
    let t = text_of(&a, "f");
    assert(count_of(&t, "load.i64 v0+24") == 2, t.as_str());
    // x = 3: the copy writes 7 over it; 7 + 3.
    let x: []u64 = [3];
    same_result(&b, &a, "top", x, 10);
}

// In a loop, an inlined call's read of its exclusive parameter's bytes that the optimizer folded onto the
// caller's parameter (root `v0+16`, read `v0+24`) is a read through the root: the copy's store through
// the root changes it, and the loop does not read it once before (`Opt::acc`, `sroot`).
@test
fn a_folded_read_of_an_inlined_calls_parameter_sees_its_stores() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "t.spc"
sym @g fn global noinline
sym @top fn global
fn @g
  file f0
  sig (ptr, i64) -> i64
  ref p0 40 noalias
  scope @20:3 g0 v4
  slot s0 size 8 align 3
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = ptradd v0+16 inbounds nonnull !20:9
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = load.i64 v0+24 align 3 tbaa 4 !10:5@20:3
  v8 = add.i64 v7, v3 !10:5@20:3
  store v8, v4+8 align 3 tbaa 4 !11:5@20:3
  v9 = add.i64 v5, v3
  jmp b1(v9)
b3:
  v10 = load.i64 v0+24 align 3 tbaa 4
  ret v10
fn @top
  sig (i64) -> i64
  slot s0 size 40 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 5
  store v2, v1+24 align 3
  v3 = call.i64 @g(v1, v0) : (ptr, i64) -> i64
  ret v3
)",
    );
    let _ = text_of(&a, "g");
    // n = 4: 5 + 4.
    let x: []u64 = [4];
    same_result(&b, &a, "top", x, 9);
}

// In a loop, a call in an inlined call's copy whose argument is at an offset from the base its scope's root
// is at (`v0+24`, root `v0+16`) writes the scope's class, as the copy's folded read of those bytes is of it:
// the read stays in the loop (`Opt::block_writes` takes the argument's class as `Opt::acc` does).
@test
fn a_call_on_an_inlined_calls_folded_bytes_keeps_their_read_in_the_loop() {
    let (b, a) = optimized(
        M"(lir ptr 8
file f0 "t.spc"
sym @bump fn global noinline
sym @g fn global noinline
sym @top fn global
fn @bump
  sig (ptr) -> void
b0(v0: ptr):
  v1 = load.i64 v0 align 3
  v2 = iconst.i64 1
  v3 = add.i64 v1, v2
  store v3, v0 align 3
  ret
fn @g
  file f0
  sig (ptr, i64) -> i64
  ref p0 40 noalias
  scope @20:3 g0 v4
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = ptradd v0+16 inbounds nonnull !20:9
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = load.i64 v0+24 align 3 tbaa 4 !10:5@20:3
  v9 = add.i64 v6, v8 !10:5@20:3
  v10 = ptradd v0+24 inbounds nonnull !11:5@20:3
  call @bump(v10) : (ptr) -> void !11:5@20:3
  v11 = add.i64 v5, v3
  jmp b1(v11, v9)
b3:
  ret v6
fn @top
  sig (i64) -> i64
  slot s0 size 40 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 5
  store v2, v1+24 align 3
  v3 = call.i64 @g(v1, v0) : (ptr, i64) -> i64
  ret v3
)",
    );
    let _ = text_of(&a, "g");
    // n = 3: 5 + 6 + 7.
    let x: []u64 = [3];
    same_result(&b, &a, "top", x, 18);
}

// A chain `c == a || c == b || c == d` whose edges pass the tests' values into a join merges into one branch
// on their `or` (`common_true`); the merged branch's false edge enters the join from a block the walk's
// predecessor list does not hold, so the join's parameter is not taken as the one value the listed edges
// pass (`same_args`): codes outside both chains stay false.
@test
fn a_merged_chain_leaves_its_join_its_false_edge() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @f fn global
sym @core__SIMD_REDUCE_AND data global
sym @core__SIMD_REDUCE_OR data global
sym @core__SIMD_REDUCE_XOR data global
sym @core__SIMD_REDUCE_ADD data global
sym @core__SIMD_REDUCE_MIN data global
sym @core__SIMD_REDUCE_MAX data global
data @core__SIMD_REDUCE_AND size 1 align 0 ro bytes 4d
data @core__SIMD_REDUCE_OR size 1 align 0 ro bytes 4e
data @core__SIMD_REDUCE_XOR size 1 align 0 ro bytes 4f
data @core__SIMD_REDUCE_ADD size 1 align 0 ro bytes 3f
data @core__SIMD_REDUCE_MIN size 1 align 0 ro bytes 47
data @core__SIMD_REDUCE_MAX size 1 align 0 ro bytes 48
fn @f
  sig (i8, i8, i8, i8, i8, i32, i8, i32, i32) -> i8
b0(v0: i8, v1: i8, v2: i8, v3: i8, v4: i8, v5: i32, v6: i8, v7: i32, v8: i32):
  v9 = iconst.i32 0
  v10 = iconst.i32 8
  v11 = iconst.i32 16
  v12 = iconst.i8 1
  v13 = symaddr @core__SIMD_REDUCE_OR
  v14 = symaddr @core__SIMD_REDUCE_XOR
  v15 = symaddr @core__SIMD_REDUCE_ADD
  v16 = symaddr @core__SIMD_REDUCE_MIN
  v17 = symaddr @core__SIMD_REDUCE_MAX
  v18 = iconst.i32 2
  v19 = iconst.i8 0
  v20 = symaddr @core__SIMD_REDUCE_AND
  v21 = or.i8 v3, v3
  v22 = or.i8 v4, v4
  br v22, b1, b3(v22)
b1:
  v23 = or.i32 v5, v5
  v24 = icmp.eq v23, v10
  br v24, b3(v24), b2
b2:
  v25 = or.i32 v5, v5
  v26 = icmp.eq v25, v11
  jmp b3(v26)
b3(v27: i8):
  v28 = xor.i8 v27, v12
  br v28, b5(v28), b4
b4:
  v29 = or.i8 v6, v6
  jmp b5(v29)
b5(v30: i8):
  br v30, b7(v30), b6
b6:
  v31 = or.i32 v7, v7
  v32 = or.i32 v8, v8
  v33 = icmp.ne v31, v32
  jmp b7(v33)
b7(v34: i8):
  br v34, b23, b8
b8:
  v35 = or.i32 v8, v8
  v36 = or.i32 v5, v5
  v37 = icmp.eq v35, v9
  br v37, b24, b25
b9:
  v38 = load.i8 v13 align 0
  v39 = icmp.eq v0, v38
  jmp b10(v39)
b10(v40: i8):
  br v40, b12(v40), b11
b11:
  v41 = load.i8 v14 align 0
  v42 = icmp.eq v0, v41
  jmp b12(v42)
b12(v43: i8):
  br v43, b22(v43), b13
b13:
  v44 = load.i8 v15 align 0
  v45 = icmp.eq v0, v44
  br v45, b15(v45), b14
b14:
  v46 = load.i8 v16 align 0
  v47 = icmp.eq v0, v46
  jmp b15(v47)
b15(v48: i8):
  br v48, b17(v48), b16
b16:
  v49 = load.i8 v17 align 0
  v50 = icmp.eq v0, v49
  jmp b17(v50)
b17(v51: i8):
  br v51, b18, b22(v51)
b18:
  v52 = icmp.eq v35, v10
  br v52, b19, b21(v52)
b19:
  v53 = load.i8 v15 align 0
  v54 = icmp.ne v0, v53
  br v54, b21(v54), b20
b20:
  v55 = icmp.ne v59, v18
  jmp b21(v55)
b21(v56: i8):
  v57 = xor.i8 v56, v12
  jmp b22(v57)
b22(v58: i8):
  ret v58
b23:
  ret v19
b24: cold
  panic "attempt to divide by zero"
b25:
  v59 = udiv.i32 v36, v35
  v60 = load.i8 v20 align 0
  v61 = icmp.eq v0, v60
  br v61, b10(v61), b9)",
    );
    for c in [0u64, 62, 63, 64, 70, 71, 72, 73, 76, 77, 78, 79, 80] {
        let want: u64 = if c == 63 || c == 71 || c == 72 || c == 77 || c == 78 || c == 79 {
            1
        } else {
            0
        };
        same_result(&b, &a, "f", [c, 17, 1, 1, 1, 16, 0, 2, 2], want);
    }
}
