// Layout-service cases: C data-model sizes, alignments, field offsets, and enum
// shapes computed from the target record -- including the 4-byte-pointer target -- with results read
// off probe-function parameter types.
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import ir::interp as iri;
import ir::layout as lay;

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

fn typed_package(src: str) loader::Package {
    let mut p = loader::package_from_source(
        src.ptr() as *const char,
        src.len(),
        "std".ptr() as *const char,
        unsafe shim::sc_host_platform(),
    );
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
    p.cir = null;
    return p;
}

// The type of probe function `name`'s single parameter (the snippet is the last module).
fn probe_ty(p: &loader::Package, name: str, m_out: &mut ModuleId) TypeId {
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
        if src.slice(sp.start as usize, sp.end as usize) != name {
            continue;
        }
        let ps = a.at_const(nid).as_data.function.params;
        assert(ps.len == 1, "one probe parameter");
        *m_out = u as ModuleId;
        return a.type_of(unsafe a.list(ps)[0]);
    }
    assert(false, "probe found");
    return TYPE_NONE;
}

// The field decl named `fname` on the struct behind `(m, t)`.
fn field_decl(p: &loader::Package, m: ModuleId, t: TypeId, fname: str) NodeId {
    let a = unsafe &*p.module_ast_const(m);
    let y = *a.type_at(t);
    let mut dm = y.module;
    let mut dn = y.as_data.decl;
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *a.instance(y.as_data.inst);
        dm = it.module;
        dn = it.decl;
    }
    let da = unsafe &*p.module_ast_const(dm);
    let src = p.modules.at(dm as usize).source.as_str();
    let ms = da.at_const(dn).as_data.aggregate.members;
    for i in 0..ms.len {
        let fid = unsafe da.list(ms)[i as usize];
        if da.at_const(fid).kind != NodeKind::NODE_FIELD {
            continue;
        }
        let sp = da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text;
        if src.slice(sp.start as usize, sp.end as usize) == fname {
            return fid;
        }
    }
    return NODE_NONE;
}

const PROBES: str = "struct S { pub a: i32, pub b: i64, pub c: u8 }\nstruct Nested { pub s: S, pub t: u16 }\nunion U { pub x: i64, pub y: [u8; 3] }\nenum Plain { A, B, C }\nenum Pay { N, W(i64, i32) }\nstruct Gen<T> { pub v: T, pub k: u8 }\nfn p_s(x: S) { let _ = x; }\nfn p_n(x: Nested) { let _ = x; }\nfn p_u(x: U) { let _ = x; }\nfn p_plain(x: Plain) { let _ = x; }\nfn p_pay(x: Pay) { let _ = x; }\nfn p_gen(x: Gen<i64>) { let _ = x; }\nfn p_arr(x: [i32; 3]) { let _ = x; }\nfn p_iz(x: isize) { let _ = x; }\nfn p_ref(x: &i64) { let _ = x; }\nfn main() i32 { return 0; }";

@test
fn c_data_model_sizes() {
    let p = typed_package(PROBES);
    let mut svc = lay::Svc::new(&p);
    let mut m: ModuleId = 0;
    // S: i32 @0, i64 @8, u8 @16 -> 24/8
    let ts = probe_ty(&p, "p_s", &mut m);
    let l = svc.layout(m, ts);
    assert(l.ok && l.size == 24 && l.align == 8, "struct pads to the C rules");
    // Nested: S @0 (24/8), u16 @24 -> 32/8
    let tn = probe_ty(&p, "p_n", &mut m);
    let ln = svc.layout(m, tn);
    assert(ln.ok && ln.size == 32 && ln.align == 8, "nested aggregate accumulates");
    // U: max(8, 3) -> 8/8
    let tu = probe_ty(&p, "p_u", &mut m);
    let lu = svc.layout(m, tu);
    assert(lu.ok && lu.size == 8 && lu.align == 8, "union takes the widest member");
    // [i32; 3] -> 12/4
    let ta = probe_ty(&p, "p_arr", &mut m);
    let la = svc.layout(m, ta);
    assert(la.ok && la.size == 12 && la.align == 4, "array multiplies the element");
    // &i64 -> pointer-sized
    let tr = probe_ty(&p, "p_ref", &mut m);
    let lr = svc.layout(m, tr);
    assert(lr.ok && lr.size == 8 && lr.align == 8, "reference is a pointer");
}

@test
fn field_offsets() {
    let p = typed_package(PROBES);
    let mut svc = lay::Svc::new(&p);
    let mut m: ModuleId = 0;
    let ts = probe_ty(&p, "p_s", &mut m);
    assert(svc.field_offset(m, ts, field_decl(&p, m, ts, "a")) == 0, "first field at zero");
    assert(svc.field_offset(m, ts, field_decl(&p, m, ts, "b")) == 8, "aligned to eight");
    assert(svc.field_offset(m, ts, field_decl(&p, m, ts, "c")) == 16, "tail after the wide field");
    let tn = probe_ty(&p, "p_n", &mut m);
    assert(svc.field_offset(m, tn, field_decl(&p, m, tn, "t")) == 24, "after the nested struct");
    let tu = probe_ty(&p, "p_u", &mut m);
    assert(svc.field_offset(m, tu, field_decl(&p, m, tu, "y")) == 0, "union members at zero");
    // Gen<i64>: v @0 (8), k @8
    let tg = probe_ty(&p, "p_gen", &mut m);
    let lg = svc.layout(m, tg);
    assert(lg.ok && lg.size == 16 && lg.align == 8, "instance substitutes the argument");
    assert(svc.field_offset(m, tg, field_decl(&p, m, tg, "k")) == 8, "offset under substitution");
}

@test
fn enum_shapes() {
    let p = typed_package(PROBES);
    let mut svc = lay::Svc::new(&p);
    let mut m: ModuleId = 0;
    let tp = probe_ty(&p, "p_plain", &mut m);
    let lp = svc.layout(m, tp);
    assert(lp.ok && lp.size == 4 && lp.align == 4, "payload-less enum is a bare C enum");
    // Pay: tag u32 @0, payload union {i64, i32} at 8 -> 24/8 with the variant struct padded
    let ty = probe_ty(&p, "p_pay", &mut m);
    let el = svc.enum_layout(m, ty);
    assert(el.ok && el.payload_off == 8, "payload after the aligned tag");
    let ll = svc.layout(m, ty);
    assert(ll.ok && ll.size == 24 && ll.align == 8, "tagged union size");
    assert(ll.size == el.size && ll.align == el.align, "both views agree");
}

@test
fn four_byte_pointer_target() {
    let mut p = typed_package(PROBES);
    p.arch = 2;
    let mut svc = lay::Svc::new(&p);
    let mut m: ModuleId = 0;
    let tz = probe_ty(&p, "p_iz", &mut m);
    let lz = svc.layout(m, tz);
    assert(lz.ok && lz.size == 4 && lz.align == 4, "isize follows the target pointer");
    let tr = probe_ty(&p, "p_ref", &mut m);
    let lr = svc.layout(m, tr);
    assert(lr.ok && lr.size == 4 && lr.align == 4, "references follow the target pointer");
    assert(lay::target_for(2).ptr == 4 && lay::target_for(0).ptr == 8, "target records");
}
