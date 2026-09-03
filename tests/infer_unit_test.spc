// Direct tests of the inference solver core (src/typechecker/infer.spc): structural unification,
// existing-binding conflicts, local compound decomposition, occurs checks, rollback restoration,
// and order-independent session resolution.
import tests::harness as h;
import ast::ast as *;
import typechecker::infer as inf;

// The compiled AST is boxed: the solver stores `&mut c.ast` as a raw pointer, and the fixture
// value moves from setup into the runner's frame, so the pointee must not live inline in Fx.
struct Fx {
    pub c: Box<h::CompiledAst>,
    pub sv: inf::Solver,
}

extend Fx as Free {
    pub fn free(self: &mut Fx) {
        self.sv.free();
        self.c.free();
    }
}

@test_init
fn setup() Fx {
    let c = Box::new(h::compile_ast("fn main() i32 { return 0; }\n", h::STAGE_TYPECHECK));
    let mut fx = Fx { c: c, sv: inf::Solver::new() };
    fx.sv.ast = &mut fx.c.ast;
    return fx;
}

// The test conversion oracle: identity, plus i32 -> i64 widening.
fn test_conv(_a: *mut Ast, from: TypeId, to: TypeId) bool {
    if from == to {
        return true;
    }
    return from == Ast::builtin(BuiltinType::BT_I32) && to == Ast::builtin(BuiltinType::BT_I64);
}

@test
fn published_identity(fx: &mut Fx) {
    let i32t = inf::it_pub(Ast::builtin(BuiltinType::BT_I32));
    let i64t = inf::it_pub(Ast::builtin(BuiltinType::BT_I64));
    assert(fx.sv.unify(i32t, i32t), "same published type unifies");
    assert(!fx.sv.unify(i32t, i64t), "different published types do not unify");
}

@test
fn var_binds_and_resolves(fx: &mut Fx) {
    let v = fx.sv.var_new(inf::VK_GENERAL, 0);
    let i32t = inf::it_pub(Ast::builtin(BuiltinType::BT_I32));
    assert(fx.sv.unify(inf::it_var(v), i32t), "unbound var binds");
    assert_eq(fx.sv.resolve(inf::it_var(v)), i32t);
}

@test
fn union_then_bind_flows(fx: &mut Fx) {
    let a = fx.sv.var_new(inf::VK_GENERAL, 0);
    let b = fx.sv.var_new(inf::VK_GENERAL, 0);
    assert(fx.sv.union_vars(a, b), "two unbound vars join");
    let i64t = inf::it_pub(Ast::builtin(BuiltinType::BT_I64));
    assert(fx.sv.unify(inf::it_var(a), i64t), "binding one root binds the class");
    assert_eq(fx.sv.resolve(inf::it_var(b)), i64t);
}

@test
fn existing_binding_must_unify(fx: &mut Fx) {
    let v = fx.sv.var_new(inf::VK_GENERAL, 0);
    let i32t = inf::it_pub(Ast::builtin(BuiltinType::BT_I32));
    let i64t = inf::it_pub(Ast::builtin(BuiltinType::BT_I64));
    assert(fx.sv.unify(inf::it_var(v), i32t), "first use binds");
    assert(!fx.sv.unify(inf::it_var(v), i64t), "a later conflicting use is a conflict");
    assert(fx.sv.unify(inf::it_var(v), i32t), "the equal use still unifies");
}

@test
fn local_compound_decomposes(fx: &mut Fx) {
    let i32t = Ast::builtin(BuiltinType::BT_I32);
    let pptr = fx.c.ast.intern_type(
        Ty {
            kind: TypeKind::TYPE_POINTER,
            qualifier: TypeQualifier::TYPE_QUAL_CONST as u8,
            as_data: TyAs { elem: i32t },
        },
    );
    let v = fx.sv.var_new(inf::VK_GENERAL, 0);
    let lp = fx.sv.local_elem(TypeKind::TYPE_POINTER, TypeQualifier::TYPE_QUAL_CONST as u8, inf::it_var(v));
    assert(fx.sv.unify(lp, inf::it_pub(pptr)), "local pointer unifies with published pointer");
    assert_eq(fx.sv.resolve(inf::it_var(v)), inf::it_pub(i32t));
    // A mutable published pointer does not match the const local.
    let mptr = fx.c.ast.intern_type(
        Ty { kind: TypeKind::TYPE_POINTER, qualifier: TypeQualifier::TYPE_QUAL_MUT as u8, as_data: TyAs { elem: i32t } },
    );
    let w = fx.sv.var_new(inf::VK_GENERAL, 0);
    let lw = fx.sv.local_elem(TypeKind::TYPE_POINTER, TypeQualifier::TYPE_QUAL_CONST as u8, inf::it_var(w));
    assert(!fx.sv.unify(lw, inf::it_pub(mptr)), "qualifier mismatch fails");
}

@test
fn local_instances_decompose(fx: &mut Fx) {
    let va = fx.sv.var_new(inf::VK_GENERAL, 0);
    let vb = fx.sv.var_new(inf::VK_GENERAL, 0);
    let i32t = inf::it_pub(Ast::builtin(BuiltinType::BT_I32));
    let args1: [u32; 2] = [inf::it_var(va), i32t];
    let args2: [u32; 2] = [i32t, inf::it_var(vb)];
    let l1 = fx.sv.local_inst(0, 7, &args1[0], 2);
    let l2 = fx.sv.local_inst(0, 7, &args2[0], 2);
    assert(fx.sv.unify(l1, l2), "same-decl local instances decompose");
    assert_eq(fx.sv.resolve(inf::it_var(va)), i32t);
    assert_eq(fx.sv.resolve(inf::it_var(vb)), i32t);
    let l3 = fx.sv.local_inst(0, 9, &args1[0], 2);
    assert(!fx.sv.unify(l1, l3), "different decls do not decompose");
}

@test
fn occurs_check_refuses_cycle(fx: &mut Fx) {
    let v = fx.sv.var_new(inf::VK_GENERAL, 0);
    let lp = fx.sv.local_elem(TypeKind::TYPE_POINTER, TypeQualifier::TYPE_QUAL_CONST as u8, inf::it_var(v));
    assert(!fx.sv.unify(inf::it_var(v), lp), "a var cannot bind to a term containing itself");
}

@test
fn rollback_restores_every_cell(fx: &mut Fx) {
    // Pre-snapshot state: two joined vars and one binding.
    let a = fx.sv.var_new(inf::VK_GENERAL, 0);
    let b = fx.sv.var_new(inf::VK_GENERAL, 0);
    let _ = fx.sv.union_vars(a, b);
    let i32t = inf::it_pub(Ast::builtin(BuiltinType::BT_I32));
    let before = fx.sv.state_hash();
    let snap = fx.sv.snapshot();
    // Speculative work: new vars, a union across the snapshot boundary, binds, a local, const work.
    let c = fx.sv.var_new(inf::VK_GENERAL, 0);
    let d = fx.sv.var_new(inf::VK_GENERAL, 0);
    let _ = fx.sv.union_vars(c, a);
    let _ = fx.sv.unify(inf::it_var(d), i32t);
    let _ = fx.sv.unify(inf::it_var(b), i32t);
    let lv = fx.sv.local_elem(TypeKind::TYPE_SLICE, 0, inf::it_var(c));
    let cv = fx.sv.cvar_new(0);
    let _ = fx.sv.cbind(cv, 41, 0);
    let _ = lv;
    assert(before != fx.sv.state_hash(), "speculative work changed the state");
    fx.sv.rollback(&snap);
    assert_eq(fx.sv.state_hash(), before);
    // The pre-snapshot class must still work after rollback.
    let i64t = inf::it_pub(Ast::builtin(BuiltinType::BT_I64));
    assert(fx.sv.unify(inf::it_var(a), i64t), "pre-snapshot class binds after rollback");
    assert_eq(fx.sv.resolve(inf::it_var(b)), i64t);
}

@test
fn const_conflicts_are_recorded(fx: &mut Fx) {
    let two = fx.c.ast.const_value(2);
    let three = fx.c.ast.const_value(3);
    let c = fx.sv.cvar_new(0);
    assert(fx.sv.cbind(c, two, 10), "first const value binds");
    assert(!fx.sv.cbind(c, three, 11), "a later disagreeing value is a conflict");
    assert_eq(fx.sv.cconflicts.len(), 1);
    assert_eq(fx.sv.cconflicts[0].old, two);
    assert_eq(fx.sv.cconflicts[0].later, three);
    assert(fx.sv.cbind(c, two, 12), "the equal value still binds");
}

@test
fn session_join_is_order_independent(fx: &mut Fx) {
    let i32t = Ast::builtin(BuiltinType::BT_I32);
    let i64t = Ast::builtin(BuiltinType::BT_I64);
    let d = DefId { module: 0, node: 5 };
    // Order 1: i32 evidence then i64.
    fx.sv.session_begin();
    let s1 = fx.sv.map_param(d, false, 0);
    fx.sv.s_lb(s1, i32t, 1);
    fx.sv.s_lb(s1, i64t, 2);
    let r1 = fx.sv.s_resolve(s1, test_conv);
    // Order 2: i64 evidence then i32.
    fx.sv.session_begin();
    let s2 = fx.sv.map_param(d, false, 0);
    fx.sv.s_lb(s2, i64t, 1);
    fx.sv.s_lb(s2, i32t, 2);
    let r2 = fx.sv.s_resolve(s2, test_conv);
    assert_eq(r1, i64t);
    assert_eq(r2, i64t);
}

@test
fn session_explicit_wins_and_conflict_stays_unresolved(fx: &mut Fx) {
    let i32t = Ast::builtin(BuiltinType::BT_I32);
    let i64t = Ast::builtin(BuiltinType::BT_I64);
    let boolt = Ast::builtin(BuiltinType::BT_BOOL);
    let d = DefId { module: 0, node: 5 };
    // Explicit binding beats later directional evidence.
    fx.sv.session_begin();
    let s1 = fx.sv.map_param(d, false, 0);
    fx.sv.s_explicit(s1, i64t);
    fx.sv.s_lb(s1, i32t, 1);
    assert_eq(fx.sv.s_resolve(s1, test_conv), i64t);
    // Incomparable evidence has no source-order fallback.
    fx.sv.session_begin();
    let s2 = fx.sv.map_param(d, false, 0);
    fx.sv.s_lb(s2, boolt, 1);
    fx.sv.s_lb(s2, i32t, 2);
    assert_eq(fx.sv.s_resolve(s2, test_conv), TYPE_NONE);
    assert_eq(fx.sv.type_conflicts.len(), 1);
}
