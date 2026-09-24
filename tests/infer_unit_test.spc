// Direct tests of the inference solver core (src/typechecker/infer.spc): binding, rollback
// restoration, const conflicts, nested sessions, and order-independent session resolution.
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
const fn test_conv(_a: *mut Ast, from: TypeId, to: TypeId) bool {
    if from == to {
        return true;
    }
    return from == Ast::builtin(BuiltinType::BT_I32) && to == Ast::builtin(BuiltinType::BT_I64);
}

@test
fn var_binds_and_resolves(fx: &mut Fx) {
    let v = fx.sv.var_new();
    assert_eq(fx.sv.resolve(inf::it_var(v)), inf::it_var(v));
    fx.sv.bind(v, Ast::builtin(BuiltinType::BT_I32));
    assert_eq(fx.sv.resolve(inf::it_var(v)), inf::it_pub(Ast::builtin(BuiltinType::BT_I32)));
}

@test
fn rollback_restores_every_cell(fx: &mut Fx) {
    let i32t = Ast::builtin(BuiltinType::BT_I32);
    let i64t = Ast::builtin(BuiltinType::BT_I64);
    // Pre-snapshot state: a bound type slot and an unbound const slot.
    fx.sv.session_begin();
    let t = fx.sv.map_param(DefId { module: 0, node: 5 }, false);
    let c = fx.sv.map_param(DefId { module: 0, node: 6 }, true);
    fx.sv.s_explicit(t, i32t);
    let snap = fx.sv.snapshot();
    // Speculative work: a new bound variable, a const binding and a conflicting one, a bound.
    let v = fx.sv.var_new();
    fx.sv.bind(v, i64t);
    fx.sv.s_cval(c, 2);
    fx.sv.s_cval(c, 3);
    fx.sv.s_lb(t, i64t, 1);
    assert_eq(fx.sv.cconflicts.len(), 1);
    fx.sv.rollback(&snap);
    let after = fx.sv.snapshot();
    assert_eq(after.log, snap.log);
    assert_eq(after.nvars, snap.nvars);
    assert_eq(after.ncvars, snap.ncvars);
    assert_eq(after.nbounds, snap.nbounds);
    assert_eq(after.nconflicts, snap.nconflicts);
    // The pre-snapshot binding survives; the const binding made after the snapshot does not.
    assert_eq(fx.sv.s_resolve(t, test_conv), i32t);
    assert_eq(fx.sv.s_resolve(c, test_conv), TYPE_NONE);
}

@test
fn nested_session_keeps_the_outer_one(fx: &mut Fx) {
    let i32t = Ast::builtin(BuiltinType::BT_I32);
    let i64t = Ast::builtin(BuiltinType::BT_I64);
    let boolt = Ast::builtin(BuiltinType::BT_BOOL);
    fx.sv.session_begin();
    let t = fx.sv.map_param(DefId { module: 0, node: 5 }, false);
    let u = fx.sv.map_param(DefId { module: 0, node: 6 }, false);
    fx.sv.s_lb(u, i64t, 1);
    // A call checked inside the outer call (a postponed closure body) runs its own session.
    let outer = fx.sv.session_open();
    fx.sv.session_begin();
    let a = fx.sv.map_param(DefId { module: 0, node: 7 }, false);
    assert_eq(a, 0);
    assert_eq(fx.sv.slot_of(DefId { module: 0, node: 5 }), -1);
    fx.sv.s_lb(a, boolt, 2);
    fx.sv.s_lb(a, i32t, 3);
    assert_eq(fx.sv.s_resolve(a, test_conv), TYPE_NONE);
    assert_eq(fx.sv.type_conflicts.len(), 1);
    fx.sv.session_close(&outer);
    // The outer slots, evidence and conflict state are back.
    assert_eq(fx.sv.slot_of(DefId { module: 0, node: 6 }), 1);
    assert_eq(fx.sv.type_conflicts.len(), 0);
    assert_eq(fx.sv.s_resolve(u, test_conv), i64t);
    fx.sv.s_explicit(t, i32t);
    assert_eq(fx.sv.s_resolve(t, test_conv), i32t);
}

@test
fn const_conflicts_are_recorded(fx: &mut Fx) {
    let two = fx.c.ast.const_value(2);
    let three = fx.c.ast.const_value(3);
    let c = fx.sv.cvar_new();
    assert(fx.sv.cbind(c, two), "first const value binds");
    assert(!fx.sv.cbind(c, three), "a later disagreeing value is a conflict");
    assert_eq(fx.sv.cconflicts.len(), 1);
    assert_eq(fx.sv.cconflicts[0].old, two);
    assert_eq(fx.sv.cconflicts[0].later, three);
    assert(fx.sv.cbind(c, two), "the equal value still binds");
}

@test
fn session_join_is_order_independent(fx: &mut Fx) {
    let i32t = Ast::builtin(BuiltinType::BT_I32);
    let i64t = Ast::builtin(BuiltinType::BT_I64);
    let d = DefId { module: 0, node: 5 };
    // Order 1: i32 evidence then i64.
    fx.sv.session_begin();
    let s1 = fx.sv.map_param(d, false);
    fx.sv.s_lb(s1, i32t, 1);
    fx.sv.s_lb(s1, i64t, 2);
    let r1 = fx.sv.s_resolve(s1, test_conv);
    // Order 2: i64 evidence then i32.
    fx.sv.session_begin();
    let s2 = fx.sv.map_param(d, false);
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
    let s1 = fx.sv.map_param(d, false);
    fx.sv.s_explicit(s1, i64t);
    fx.sv.s_lb(s1, i32t, 1);
    assert_eq(fx.sv.s_resolve(s1, test_conv), i64t);
    // Incomparable evidence has no source-order fallback.
    fx.sv.session_begin();
    let s2 = fx.sv.map_param(d, false);
    fx.sv.s_lb(s2, boolt, 1);
    fx.sv.s_lb(s2, i32t, 2);
    assert_eq(fx.sv.s_resolve(s2, test_conv), TYPE_NONE);
    assert_eq(fx.sv.type_conflicts.len(), 1);
}
