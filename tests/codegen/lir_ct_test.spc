// The constant-time check on LIR text (`lir::ct`): which values are secret, which instructions break a
// rule, and the removal of the secret marks.
import lir::ir as *;
import lir::parse as lparse;
import lir::print as lprint;
import lir::verify as verify;
import lir::ct as lct;

// One body: for each rule an instruction that breaks it, and beside it one that would were its operand
// not secret (a declassified value, a public load).
const BODY: str = M"(lir ptr 8
sym @f fn global
sym @g fn global
sym @plain fn global sec
sym @other fn global
fn @f
  sig (i64, ptr, f64) -> i64
  ct
b0(v0: i64, v1: ptr, v2: f64):
  v3 = secret.i64 v0
  v4 = public.i64 v3
  v5 = iconst.i64 1
  v6 = add.i64 v3, v5
  v7 = icmp.ult v6, v5
  v8 = select.i64 v7, v6, v5
  v9 = select.f64 v7, v2, v2
  v10 = ptradd v1, v6 * 8
  v11 = load.i64 v10 align 3
  v12 = load.i64 v1 align 3
  v13 = udiv.i64 v12, v6
  v14 = udiv.i64 v12, v4
  v15 = sitofp.f64 v6
  v16 = sitofp.f64 v4
  call @plain(v4) : (i64) -> void
  call @other(v6) : (i64) -> void
  call @other(v4) : (i64) -> void
  v17 = icmp.ult v4, v5
  br v17, b1(v8), b2(v4)
b1(v18: i64):
  v19 = ptradd v1, v18 * 8
  store v5, v19 align 3
  v20 = icmp.ne v18, v5
  br v20, b2(v5), b3
b2(v21: i64):
  v22 = ptradd v1, v21 * 8
  store v5, v22 align 3
  ret v21
b3:
  ret v6
fn @g
  sig (i64) -> i64
b0(v0: i64):
  v1 = secret.i64 v0
  v2 = symaddr @plain
  call @other(v0) : (i64) -> void
  ret v0
)";

fn parsed(text: str) Package {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let p = q.unwrap();
    let mut v = verify::Verifier::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check(&p, p.spell(s.name), &p.bodies[s.def as usize]), v.err.as_str());
        }
    }
    return p;
}

// The rules each instruction of `@f` breaks: a secret select of a float, a load and a store at secret
// addresses (the store's through `b1`'s parameter, which `b0` passes secret), a division and a conversion
// of a secret, a call of a C function that takes a `Secret`, a secret passed to a function, a branch on a
// secret, a secret returned; none for their public twins, an integer select, a public argument, the store
// through `b2`'s parameter, which both edges pass public.
@test
fn each_rule_has_its_instruction() {
    let p = parsed(BODY);
    let k = p.syms[p.find_symbol("f") as usize].def;
    let mut c = lct::Check::new();
    let mut found = Vector::<u64>::new();
    c.violations(&p, k, &mut found);
    let b = &p.bodies[k as usize];
    let mut got = String::new();
    for q in 0..found.len() {
        let t = b.insts[(found[q] >> 8) as usize];
        got.format_into("{}:{} ", OPS[t.op as usize].name, found[q] & 0xFF);
    }
    let want = format(
        "select:{} load:{} udiv:{} sitofp:{} call:{} call:{} store:{} br:{} ret:{} ",
        lct::R_SELECT,
        lct::R_ADDR,
        lct::R_DIV,
        lct::R_FLOAT,
        lct::R_CALL_SEC,
        lct::R_CALL,
        lct::R_ADDR,
        lct::R_BRANCH,
        lct::R_RET,
    );
    assert_eq(got.as_str(), want.as_str());
}

// A body that is not constant-time breaks a rule where it reads a secret and where it names a C function
// that takes a `Secret` (its address too); its other instructions, a public call and return, break none.
@test
fn a_body_that_is_not_constant_time_reads_no_secret() {
    let p = parsed(BODY);
    let k = p.syms[p.find_symbol("g") as usize].def;
    let mut c = lct::Check::new();
    let mut found = Vector::<u64>::new();
    c.violations(&p, k, &mut found);
    let b = &p.bodies[k as usize];
    let mut got = String::new();
    for q in 0..found.len() {
        got.format_into("{}:{} ", OPS[b.insts[(found[q] >> 8) as usize].op as usize].name, found[q] & 0xFF);
    }
    assert_eq(got.as_str(), format("secret:{} symaddr:{} ", lct::R_OUTSIDE, lct::R_CALL_SEC).as_str());
}

// The marks go: each use of a mark reads its operand, and no mark is left.
@test
fn marks_go_from_every_body() {
    let mut p = parsed(BODY);
    let k = p.syms[p.find_symbol("f") as usize].def;
    let mut c = lct::Check::new();
    for q in 0..p.bodies.len() {
        c.strip(p.bodies.index_mut(q));
    }
    let mut text = String::new();
    lprint::print_package(&p, &mut text);
    let t = text.as_str();
    assert(t.find("secret") < 0 && t.find("public") < 0, t);
    assert(t.find("add.i64 v0, v5") >= 0, t);
    assert(t.find("udiv.i64 v12, v0") >= 0, t);
    assert(t.find("call @plain(v0)") >= 0, t);
    let mut v = verify::Verifier::new();
    assert(v.check(&p, "f", &p.bodies[k as usize]), v.err.as_str());
}

// The text form keeps the marks and the flags: `secret`, `public`, a body's `ct`, a symbol's `sec`.
@test
fn marks_and_flags_read_back() {
    let p = parsed(BODY);
    let mut t1 = String::new();
    lprint::print_package(&p, &mut t1);
    let q = parsed(&t1);
    let mut t2 = String::new();
    lprint::print_package(&q, &mut t2);
    assert_eq(t1.as_str(), t2.as_str());
    let s = t1.as_str();
    assert(s.find("v3 = secret.i64 v0") >= 0 && s.find("v4 = public.i64 v3") >= 0, s);
    assert(s.find("sym @plain fn global sec") >= 0, s);
    assert(s.find("\n  ct\n") >= 0, s);
    let f = q.syms[q.find_symbol("f") as usize];
    assert(q.bodies[f.def as usize].ct, "the body's flag");
}

// Secrets into hardware instructions, vector operations and bodies: `@k` reads a secret vector and word;
// each instruction's rule depends on the target's list of data-independent instructions
// (`target::table::Isa::const_time`) and on the operation.
const HW: str = M"(lir ptr 8
sym @k fn global
sym @help fn global
sym @deep fn global
sym @vaeseq_u8 fn global
sym @vsha1h_u32 fn global
sym @_mm_aesenc_si128 fn global
sym @_mm_sha256rnds2_epu32 fn global
sym @_mm_sha256msg1_epu32 fn global
fn @k
  sig (ptr, i64) -> i64
  ct
b0(v0: ptr, v1: i64):
  v2 = load.v4i32 v0 align 4
  v3 = secret.v4i32 v2
  v4 = secret.i64 v1
  v5 = vop.wrapping_add.v4i32 (v3, v2)
  v6 = xor.v4i32 v5, v3
  v7 = vop.wrapping_shl.v4i32 (v6, v2)
  v8 = vop.wrapping_shl.v4i32 (v6, v3)
  v9 = vop.min.v4i32 (v6, v2)
  v10 = vop.swizzle.v4i32 (v7) lanes [3, 2, 1, 0]
  v11 = vop.reduce_add.i32 (v10)
  v12 = call.v4i32 @vaeseq_u8(v10, v2) : (v4i32, v4i32) -> v4i32
  v13 = call.i32 @vsha1h_u32(v11) : (i32) -> i32
  v14 = call.v4i32 @_mm_aesenc_si128(v10, v2) : (v4i32, v4i32) -> v4i32
  v15 = call.v4i32 @_mm_sha256rnds2_epu32(v10, v2, v2) : (v4i32, v4i32, v4i32) -> v4i32
  v16 = call.v4i32 @_mm_sha256msg1_epu32(v10, v2) : (v4i32, v4i32) -> v4i32
  v17 = call.i64 @help(v4) : (i64) -> i64
  v18 = public.i64 v17
  ret v18
fn @help
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = call.i64 @deep(v0, v1) : (i64, i64) -> i64
  v3 = icmp.eq v0, v1
  br v3, b1, b2
b1:
  ret v0
b2:
  ret v2
fn @deep
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = udiv.i64 v1, v0
  v3 = udiv.i64 v0, v0
  ret v2
)";

// The rules each body of `HW` breaks with the instruction set `isa`: `op:rule ` per violation.
fn hw_rules(isa: str<'static>) String {
    let mut p = parsed(HW);
    p.isa = isa;
    let mut c = lct::Check::new();
    c.masks(&p);
    let mut got = String::new();
    let names: [str; 3] = ["k", "help", "deep"];
    for nm in names {
        let k = p.syms[p.find_symbol(nm) as usize].def;
        let mut found = Vector::<u64>::new();
        c.violations(&p, k, &mut found);
        got.format_into("{}:", nm);
        for q in 0..found.len() {
            got.format_into(
                " {}:{}",
                OPS[p.bodies[k as usize].insts[(found[q] >> 8) as usize].op as usize].name,
                found[q] & 0xFF,
            );
        }
        got.push_str("\n");
    }
    return got;
}

// A secret goes to a wrapping add, a bitwise operation, a shift by a public count and a fixed swizzle, not
// to a shift by a secret count, a minimum or a reduction; to an intrinsic whose instructions the
// target lists (arm64's AESE; x86-64's AESENC, and SHA256RNDS2 with its register copies), not to another
// (SHA1H's FMOV, SHA256MSG1) or to another target's; and to a body, which is then checked with that
// parameter secret, as are the bodies it passes it to: `@help` branches on it but returns it, and `@deep`
// divides by it (the division of its public parameter alone passes).
@test
fn secrets_reach_listed_instructions_plain_vector_operations_and_bodies() {
    let tail = format("help: br:{}\ndeep: udiv:{} udiv:{}\n", lct::R_BRANCH, lct::R_DIV, lct::R_DIV);
    let vops = format("k: vop:{} vop:{} vop:{}", lct::R_VOP, lct::R_VOP, lct::R_VOP);
    let a64 = format(
        "{} call:{} call:{} call:{} call:{}\n{}",
        vops,
        lct::R_CALL,
        lct::R_CALL,
        lct::R_CALL,
        lct::R_CALL,
        tail,
    );
    assert_eq(hw_rules("aarch64").as_str(), a64.as_str());
    let x64 = format("{} call:{} call:{} call:{}\n{}", vops, lct::R_CALL, lct::R_CALL, lct::R_CALL, tail);
    assert_eq(hw_rules("x86_64").as_str(), x64.as_str());
}
