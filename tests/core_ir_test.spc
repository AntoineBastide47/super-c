// Core IR expected-output tests: focused snippets lower to verified bodies whose
// deterministic print form is asserted structurally, plus direct coverage of the typed-facts
// boundary accessors. These are compiler-structure tests, not generated-program substitutes.
import driver_shim as shim;
import driver::emit as demit;
import module::loader as loader;
import ast::ast as *;
import ast::facts as facts;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import ir::interp as iri;
import ir::lower as irl;
import ir::print as irp;
import ir::verify as irv;
import tests::harness as h;

fn t_resolve(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut r = res::Resolver::new(unsafe &mut *((&mut m.ast) as *mut Ast), str::from_raw(src as *const u8, len), pkg);
    r.resolve();
    let had = r.has_errors();
    if had {
        r.log_errors();
    }
    return !had;
}

fn t_typecheck(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.check();
    let had = t.has_errors();
    if had {
        t.log_errors();
    }
    return !had;
}

// Borrow-check one module of the fully typed package (its own stage, like the driver: the Core IR
// path reads callee facts that can live in any module).
fn t_borrowck(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.borrowck_solo();
    let had = t.has_errors();
    if had {
        t.log_errors();
    }
    return !had;
}

// Resolve + typecheck `src` against the std prelude; asserts the snippet is error-free.
fn typed_package(src: str) loader::Package {
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    assert(p.ok, "snippet parses");
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;
    let n = p.modules.len();
    let mut ok = true;
    for i in 0..n {
        ok = t_resolve(&mut p, i) && ok;
    }
    assert(ok, "snippet resolves");
    for i in 0..n {
        ok = t_typecheck(&mut p, i) && ok;
    }
    assert(ok, "snippet typechecks");
    demit::publish_checkpoint(&mut p, null);
    for i in 0..n {
        ok = t_borrowck(&mut p, i) && ok;
    }
    assert(ok, "snippet borrow-checks");
    p.cir = null;
    return p;
}

// The user module's top-level function named `name` (the snippet is always the last module).
fn find_fn(p: &loader::Package, name: str) NodeId {
    let u = p.modules.len() - 1;
    let a = unsafe &*p.module_ast_const(u as ModuleId);
    let src = p.modules.at(u).source.as_str();
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let nid = unsafe a.list(items)[i as usize];
        if a.at_const(nid).kind != NodeKind::NODE_FUNCTION {
            continue;
        }
        let sp = a.at_const(a.at_const(nid).as_data.function.name).as_data.name.text;
        if src.slice(sp.start as usize, sp.end as usize) == name {
            return nid;
        }
    }
    return NODE_NONE;
}

// Lower + verify `name`, returning the deterministic print form.
fn lowered(p: &loader::Package, name: str) String {
    let node = find_fn(p, name);
    assert(node != NODE_NONE, "function found");
    let u = (p.modules.len() - 1) as ModuleId;
    let mut lw = irl::Lowerer::new(p, u, node);
    let ok = lw.lower_fn(node);
    assert(ok, "body lowers");
    let tp = unsafe (&*p.module_ast_const(u)).type_bound();
    assert(irv::verify(&lw.body, tp, p).len() == 0, "body verifies");
    return irp::print_body(&lw.body);
}

fn has(s: &String, needle: str) bool {
    return s.contains(needle);
}

@test
fn arithmetic_and_return() {
    let p = typed_package(
        "fn f(a: i32, b: i32) i32 { return a + (b * 2); }\nfn main() i32 { let _ = f(1, 2); return 0; }",
    );
    let out = lowered(&p, "f");
    assert(has(&out, "bin"), "explicit binary operations");
    assert(has(&out, "return"), "return terminator");
    assert(has(&out, "_0 = "), "the return slot is local 0");
}

@test
fn if_else_value_and_short_circuit() {
    let p = typed_package(
        "fn g(a: i32) i32 { let v = if a > 1 && a < 10 { a; } else { 0; }; return v; }\nfn main() i32 { let _ = g(3); return 0; }",
    );
    let out = lowered(&p, "g");
    assert(has(&out, "switch("), "conditions lower to switches");
    assert(has(&out, "goto bb"), "join edges are explicit gotos");
}

@test
fn loops_break_continue() {
    let p = typed_package(
        "fn h() i32 { let mut s = 0; for i in 0..10 { if i == 3 { continue; } if i == 7 { break; } s += i; } return s; }\nfn main() i32 { let _ = h(); return 0; }",
    );
    let out = lowered(&p, "h");
    assert(has(&out, "switch("), "loop condition switch");
    assert(has(&out, "goto bb"), "back edge");
}

@test
fn calls_are_terminators() {
    let p = typed_package(
        "fn callee(x: i32) i32 { return x; }\nfn caller() i32 { return callee(4); }\nfn main() i32 { let _ = caller(); return 0; }",
    );
    let out = lowered(&p, "caller");
    assert(has(&out, "call m"), "resolved call terminator");
    assert(has(&out, ") -> bb"), "normal successor");
}

@test
fn match_variants_and_or_patterns() {
    let p = typed_package(
        "enum E { A, B(i32), C }\nfn m(e: E) i32 { return switch e { A | C => 0, B(x) => x, }; }\nfn main() i32 { let _ = m(E::A); return 0; }",
    );
    let out = lowered(&p, "m");
    assert(has(&out, "discr "), "variant tests read the discriminant");
    assert(has(&out, "unreachable"), "exhaustive fallthrough is unreachable");
}

@test
fn aggregates_and_field_places() {
    let p = typed_package(
        "struct Pt { pub x: i32, pub y: i32 }\nfn mk() i32 { let p = Pt { x: 1, y: 2 }; return p.x; }\nfn main() i32 { let _ = mk(); return 0; }",
    );
    let out = lowered(&p, "mk");
    assert(has(&out, "agg0"), "struct aggregate construction");
    assert(has(&out, ".f"), "field projection place");
}

@test
fn defer_runs_before_return() {
    let p = typed_package(
        "fn effect(x: i32) i32 { return x; }\nfn d() i32 { defer { let _ = effect(1); } return effect(2); }\nfn main() i32 { let _ = d(); return 0; }",
    );
    let out = lowered(&p, "d");
    assert(has(&out, "call m"), "deferred call emitted");
    // The deferred effect(1) call lands between the return-slot assignment and the return.
    assert(has(&out, "return"), "return present");
}

@test
fn typed_facts_boundary() {
    let src = "@platform(windows)\nfn plat() i32 { return 1; }\n@platform(!windows)\nfn plat() i32 { return 1; }\nfn take<'a>(r: &'a i32) &'a i32 { return r; }\nfn idg<T>(x: T) T { return x; }\nfn main() i32 {\n    let v = Vector::<i32>::new();\n    let n = v.len();\n    let mut c = 0;\n    let mut bump = || { c += 1; };\n    bump();\n    let x = 5;\n    let r = take(&x);\n    let _ = *r + n as i32 + plat() + idg::<i32>(2);\n    return 0;\n}";
    let p = typed_package(src);
    let u = (p.modules.len() - 1) as ModuleId;
    let f = facts::TypedFacts::of(p.module_ast_const(u));
    let a = unsafe &*p.module_ast_const(u);
    // Instance + node types: the Vector::<i32> value is an interned instance type.
    let mut saw_inst = false;
    let mut closure = NODE_NONE;
    for n in 0..a.nnodes() {
        let nid = a.nth_id(n);
        let k = a.at_const(nid).kind;
        if k == NodeKind::NODE_CLOSURE {
            closure = nid;
        }
        let t = f.node_type(nid);
        if t != TYPE_NONE && f.ty(t).kind == TypeKind::TYPE_INSTANCE {
            let it = f.instance(f.ty(t).as_data.inst);
            if it.decl != NODE_NONE {
                saw_inst = true;
            }
        }
    }
    assert(saw_inst, "instance accessor reaches the interned instance");
    assert(closure != NODE_NONE, "closure found");
    assert(f.node(closure).as_data.closure.mut_caps != 0, "mutated capture recorded in the mask");
    assert(f.captures(closure).len != 0, "capture list recorded");
    // Generic args recorded at the specialized use site.
    let mut saw_args = false;
    for n in 0..a.nnodes() {
        if f.type_args(a.nth_id(n)) != null {
            saw_args = true;
        }
    }
    assert(saw_args, "generic arguments recorded at a use site");
}

@test
fn question_lowers_explicitly() {
    let p = typed_package(
        "fn g(o: Option<i32>) Option<i32> { let v = o?; return Option::<i32>::Some(v + 1); }\nfn main() i32 { let _ = g(Option::<i32>::Some(1)); return 0; }",
    );
    let out = lowered(&p, "g");
    assert(has(&out, "discr "), "the carrier discriminant is read");
    assert(has(&out, ".variant"), "the payload is a downcast projection");
    assert(has(&out, "agg3"), "the error path rewraps through variant construction");
    assert(has(&out, "return"), "the error path returns");
}

@test
fn iterator_for_lowers_to_next_calls() {
    let p = typed_package(
        "fn f(v: &Vector<i32>) i32 { let mut s = 0; for x in v.iter() { s += *x; } return s; }\nfn main() i32 { let v = Vector::<i32>::new(); let _ = f(&v); return 0; }",
    );
    let out = lowered(&p, "f");
    assert(has(&out, "call m"), "the selected next runs as a call terminator");
    assert(has(&out, "discr "), "one discriminant read per iteration");
    assert(has(&out, ".variant"), "the element loads through a downcast");
}

// A feature-dense body drives the printer across its rvalue and terminator variants: references,
// casts, an aggregate literal, a repeat array, a length read, an enum discriminant switch, a dyn
// coercion, and a closure. The exact text is not pinned (that is other tests' job); this asserts the
// printer emits a marker for each construct so every print branch runs.
@test
fn printer_covers_rvalue_variants() {
    let p = typed_package(
        M"(interface Shape2 { fn area(self: &Self) i32; }
struct Sq { pub s: i32 }
extend Sq as Shape2 { fn area(self: &Sq) i32 { return self.s * self.s; } }
enum E { A, B, C }
fn pick(e: E) i32 {
    return switch e {
        A => 1,
        B => 2,
        C => 3,
    };
}
fn dense(n: i32) i32 {
    let sq = Sq { s: n };
    let r = &sq;
    let d: &dyn Shape2 = &sq;
    let a: [i32; 3] = [n; 3];
    let sl: []i32 = a[0..3];
    let mut acc = sl.len() as i32;
    acc = acc + r.s + d.area() + pick(E::B) + (n as i64 as i32);
    let f = |x: i32| x + acc;
    return f(1);
}
fn main() i32 { let _ = dense(2); let _ = pick(E::A); return 0; })",
    );
    let out = lowered(&p, "dense");
    assert(has(&out, "body"), "the body header prints");
    assert(has(&out, "cast "), "a cast rvalue prints");
    assert(has(&out, "agg"), "an aggregate rvalue prints");
    assert(has(&out, "repeat("), "a repeat rvalue prints");
    assert(has(&out, "len "), "a length rvalue prints");
    assert(has(&out, "dyn "), "a dyn coercion prints");
    assert(has(&out, "closure n"), "a closure rvalue prints");
    // The discriminant read and switch terminator live in `pick`.
    let po = lowered(&p, "pick");
    assert(has(&po, "discr ") || has(&po, "switch("), "a discriminant/switch prints");
}

// Build and run `src` with the leak tracker armed; a leak or a double free exits nonzero.
fn run_leak_checked(label: str, src: str, code: i32) {
    let r = h::compile_and_run_env(src, "SC_LEAK_CHECK=fatal");
    assert(r.built, label);
    assert_eq(r.exit, code);
}

@test
fn question_error_path_frees_owned_locals() {
    // The error path of `?` returns through the storage deaths, so the owning local and the
    // by-value argument are freed there as on every other exit.
    run_leak_checked(
        "question error path frees",
        "fn half(n: i32) Result<i32, i32> { if n % 2 == 0 { return Result::<i32, i32>::Ok(n / 2); } return Result::<i32, i32>::Err(n); }\nfn f(n: i32, arg: String) Result<i32, i32> { let s = String::from_str(\"0123456789012345678901234567890123456789\"); let v = half(n)?; return Result::<i32, i32>::Ok(v + s.len() as i32 + arg.len() as i32); }\nfn main() i32 { let a = f(3, String::from_str(\"abcdefghijklmnopqrstuvwxyz0123456789\")); let b = f(4, String::from_str(\"abcdefghijklmnopqrstuvwxyz0123456789\")); let mut r = 0; switch a { Ok(_) => { r = 1; }, Err(e) => { r = e - 3; } }; switch b { Ok(v) => { r = r + v - 78; }, Err(_) => { r = 1; } }; return r; }\n",
        0,
    );
}

@test
fn closure_frees_by_value_params() {
    // An expression-bodied closure holds an inferred return slot ahead of its parameters: the
    // parameter's storage death must name the parameter, not the return slot.
    run_leak_checked(
        "closure parameter freed",
        "fn apply<F: fn(String) usize>(f: F) usize { return f(String::from_str(\"0123456789012345678901234567890123456789\")); }\nfn main() i32 { let f = |s: String| s.len(); let n = f(String::from_str(\"0123456789012345678901234567890123456789\")); let m = apply(|s: String| s.len()); return (n + m) as i32 - 80; }\n",
        0,
    );
}

@test
fn temporary_receivers_and_places_are_freed() {
    // A value that lowers into a temporary (a `format` result, an `if` or `switch` value, a struct
    // literal) and is then used as a method receiver or a place owns that value: it is freed once.
    run_leak_checked(
        "temporary receivers freed",
        "struct P { pub s: String }\nextend P { fn eat(self: P) usize { return self.s.len(); } }\nfn mk() String { return String::from_str(\"0123456789012345678901234567890123456789\"); }\nfn main() i32 { let mut t: usize = 0; let mut s = String::new(); for i in 0..2 { t += format(\"0123456789012345678901234567890123456789{}\", i).len(); s.push_str(format(\"0123456789012345678901234567890123456789{}\", i).as_str()); t += (if i > 0 { mk(); } else { mk(); }).len(); t += (switch i { 0 => mk(), _ => mk() }).len(); t += (if i > 0 { P { s: mk() }; } else { P { s: mk() }; }).s.len(); t += (if i > 0 { P { s: mk() }; } else { P { s: mk() }; }).eat(); let r = &P { s: mk() }; t += r.s.len(); } return (t + s.len()) as i32 - 564; }\n",
        0,
    );
}

@test
fn deeply_nested_owner_frees() {
    // A String twenty plain structs deep is freed with its outermost owner.
    let mut src = String::from_str("struct S0 { pub s: String }\n");
    for i in 1..20 {
        src.push_str("struct S");
        src.push_u64(i as u64);
        src.push_str(" { pub x: S");
        src.push_u64(i as u64 - 1);
        src.push_str(" }\n");
    }
    src.push_str("fn main() i32 { let v = ");
    for i in 0..19 {
        src.push_str("S");
        src.push_u64(19 - i as u64);
        src.push_str(" { x: ");
    }
    src.push_str("S0 { s: String::from_str(\"0123456789012345678901234567890123456789\") }");
    for _i in 0..19 {
        src.push_str(" }");
    }
    src.push_str("; return v.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.s.len() as i32 - 40; }\n");
    run_leak_checked("nested owner freed", src.as_str(), 0);
}

@test
fn wide_shared_member_type_compiles() {
    // Each level holds two members of the level below, so a walk over member types that judges a
    // shared type again at each use takes 2^29 steps; one judgement per type keeps it linear.
    let mut src = String::from_str("struct L0 {}\n");
    for i in 1..30 {
        src.push_str("struct L");
        src.push_u64(i as u64);
        src.push_str(" { pub a: L");
        src.push_u64(i as u64 - 1);
        src.push_str(", pub b: L");
        src.push_u64(i as u64 - 1);
        src.push_str(" }\n");
    }
    src.push_str("struct Top { pub w: L29, pub s: String }\n");
    src.push_str("fn main() i32 { let o = Option::<Top>::None; return if o.is_none() { 0; } else { 1; }; }\n");
    run_leak_checked("wide shared member type", src.as_str(), 0);
}

@test
fn long_else_if_chains_compile() {
    // 1000-arm `else if` chains render flat, inside and outside a loop: arms that fall through read
    // `} else if (..) {`, and arms that return continue the chain unwrapped even when each test
    // needs statements first (the inlined call).
    let mut src = String::from_str(
        "fn g(x: i32) i32 { return x * 3; }\nfn fall(x: i32) i32 {\n    let mut y = -1;\n    if x == 0 { y = 0; }",
    );
    for i in 1..1000 {
        src.push_str(" else if x == ");
        src.push_u64(i as u64);
        src.push_str(" { y = ");
        src.push_u64((i * 2) as u64);
        src.push_str("; }");
    }
    src.push_str("\n    return y;\n}\nfn ret(x: i32) i32 {\n    if g(x) == 0 { return 0; }");
    for i in 1..1000 {
        src.push_str(" else if g(x) == ");
        src.push_u64((i * 3) as u64);
        src.push_str(" { return ");
        src.push_u64(i as u64);
        src.push_str("; }");
    }
    src.push_str(
        "\n    return -1;\n}\nfn inloop(n: i32) i32 {\n    let mut s = 0;\n    for x in 0..n {\n        if x == 0 { s += 1; }",
    );
    for i in 1..1000 {
        src.push_str(" else if x == ");
        src.push_u64(i as u64);
        src.push_str(" { s += 1; if s > 5000 { break; } }");
    }
    src.push_str(" else { s += 2; }\n    }\n    return s;\n}\n");
    src.push_str(
        "fn main() i32 {\n    if fall(999) != 1998 || fall(1000) != -1 { return 1; }\n    if ret(999) != 999 || ret(1000) != -1 { return 2; }\n    return inloop(1002) - 1004;\n}\n",
    );
    let r = h::compile_and_run(src.as_str());
    assert(r.built, "the 1000-arm chains build");
    assert_eq(r.exit, 0);
}

@test
fn long_sum_compiles() {
    // A 300-term sum folds into chains of bounded length, so the C renders within its nesting limit.
    let mut src = String::from_str("fn f(x: i32) i32 { return x");
    for _i in 1..300 {
        src.push_str(" + x");
    }
    src.push_str("; }\nfn main() i32 { return f(1) - 300; }\n");
    let r = h::compile_and_run(src.as_str());
    assert(r.built, "the 300-term sum builds");
    assert_eq(r.exit, 0);
}

@test
fn comparison_operands_are_read_not_moved() {
    // `==` and `assert_eq` read owned operands: a compared binding stays usable and is freed by
    // its owner, and a temporary operand is freed by its scope. An aggregate call result compared
    // by `assert_eq` stays a named temporary (the comparison takes its address).
    run_leak_checked(
        "comparison operands freed",
        "struct P { pub x: i32 }\nextend P as Eq { pub fn eq(self: &P, o: &P) bool { return self.x == o.x; } }\n@c.noinline\nfn mp(x: i32) P { return P { x: x }; }\nfn mk() String { return String::from_str(\"0123456789012345678901234567890123456789\"); }\nfn main() i32 { assert_eq(mp(1), mp(1)); let a = mk(); let b = mk(); let e1 = a == b; let e2 = mk() == mk(); let e3 = format(\"{}0123456789012345678901234567890123456789\", 1) != mk(); assert_eq(mk(), mk()); assert(mk() == b); let c = a; return if e1 && e2 && e3 && c.len() == 40 { 0; } else { 1; }; }\n",
        0,
    );
}

@test
fn compound_bit_assignments_evaluate() {
    // `|=`, `^=`, `<<=` and `>>=` apply their base operator at compile time and at run time.
    run_leak_checked(
        "compound bit assignments",
        "const fn mix(x: u32) u32 { let mut v = x; v |= 8; v ^= 3; v <<= 2; v >>= 1; return v; }\nconst K: u32 = mix(1);\nstatic_assert(K == 20, \"compound bit ops fold\");\nfn main() i32 { let mut v: u32 = 1; v |= 8; v ^= 3; v <<= 2; v >>= 1; return (K + v) as i32 - 40; }\n",
        0,
    );
}

@test
fn inclusive_range_ends_at_type_max() {
    // An inclusive end at the element type's maximum ends the loop: the increment past the
    // last element never runs (it would wrap for unsigned types and trap for signed ones). A
    // wrapped counter leaves through the break with a wrong count instead of looping forever.
    run_leak_checked(
        "inclusive range at the type maximum",
        "fn main() i32 { let mut n = 0; let lo: u8 = 250; let hi: u8 = 255; for i in lo..=hi { n += 1; if i < lo { break; } } let a: i8 = 125; let b: i8 = 127; let r = a..=b; for j in r { n += 1; let _ = j; } let e: i8 = 3; let x = 0i8..e; for k in x { n += 1; let _ = k; } return n - 12; }\n",
        0,
    );
}

@test
fn inlined_repeat_keeps_its_count() {
    // The inliner rebases the repeat count operand with the callee's operands: a stale count
    // reads a caller operand (here the constant 2) and fills too few elements.
    run_leak_checked(
        "inlined repeat count",
        "pub fn fill(v: i32) [i32; 3] { return [v; 3]; }\nfn main() i32 { let x: i32 = 1; let y: i32 = 2; let a = fill(7); return a[0] + a[1] + a[2] + x + y - 24; }\n",
        0,
    );
}

@test
fn large_alignment_layout_is_stable() {
    // A cached layout answer equals the first one for an alignment of 256 or more.
    run_leak_checked(
        "large alignment layout",
        "@c.align(512)\nstruct Big { pub x: u8 }\nconst A: usize = sizeof(Big);\nconst B: usize = sizeof(Big);\nconst C: usize = alignof(Big);\nfn main() i32 { return (A + B + C) as i32 - 1536; }\n",
        0,
    );
}
