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
