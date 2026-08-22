// The typed-facts boundary: every semantic decision the type checker
// records for a body -- node types, resolutions, call targets, generic arguments, operator methods,
// coercion/dereference sequences, dynamic conversions, wide literals, captures, attributes and
// lifetime declarations -- behind ONE read-only interface. Core IR lowering and every later new
// consumer reads these accessors, never the Ast side tables directly, so the tables can move off
// `Ast` without touching consumers. Nothing here mutates.
//
// The freeze contract (enforced by the driver's SC_FACTS_CHECK mode after borrow checking AND after
// codegen): at type-check completion every semantic DECISION table is final -- nodes, children,
// resolutions, per-node types, coercions, mono/method-instance demands, method_refs, dyn/deref
// selections, wide literals, attributes, lifetime declarations, call_info, op_method. Every later
// stage (borrow checking, Core IR lowering, instance planning, const-eval fold discharge, emission)
// reads this data frozen. The ONE sanctioned mutation is interning: `type_pool`, `instances`, and
// `const_lins` (with their index tables) grow append-only whenever a later stage interns a
// substituted or replayed type, and an interned entry is never removed or renumbered -- growth
// changes no existing answer.
import ast::ast as *;

/// Read-only view of one module's typed AST. Holds a raw pointer because consumers thread it through
/// stages that also hold the package; the Ast must outlive the view (it always does: views are built
/// per pass over a loaded package).
pub struct TypedFacts {
    pub ast: *const Ast,
}

extend TypedFacts {
    pub const fn of(a: *const Ast) TypedFacts {
        return TypedFacts { ast: a };
    }

    const fn a(self: &Self) &Ast {
        return unsafe &*self.ast;
    }

    /// The node itself (syntax structure stays readable through the boundary).
    pub const fn node(self: &Self, n: NodeId) &Node {
        return self.a().at_const(n);
    }

    pub const fn list(self: &Self, l: NodeList) *const NodeId {
        return self.a().list(l);
    }

    /// The checked type of expression/decl node `n`.
    pub const fn node_type(self: &Self, n: NodeId) TypeId {
        return self.a().type_of(n);
    }

    pub const fn ty(self: &Self, t: TypeId) &Ty {
        return self.a().type_at(t);
    }

    pub const fn instance(self: &Self, i: u32) &TyInstance {
        return self.a().instance(i);
    }

    /// The resolved declaration a reference names (module-qualified).
    pub const fn res(self: &Self, n: NodeId) DefId {
        return self.a().resolution_def(n);
    }

    /// The type args recorded for `n` (turbofish/inference), or null.
    pub const fn type_args(self: &Self, n: NodeId) *const MonoUse {
        return self.a().type_args(n);
    }

    /// The call target + ABI data the type checker selected at call node `n`
    /// ((fmod << 40 | fdecl << 8 | skip) -- the record borrowck replays), or None.
    pub const fn call_info(self: &Self, n: NodeId) Option<u64> {
        return switch self.a().call_info.get(&n) {
            Some(v) => Option::<u64>::Some(*v),
            None => Option::<u64>::None,
        };
    }

    /// The operator method selected at operator node `n` ((module << 32 | node)), or None.
    pub const fn op_method(self: &Self, n: NodeId) Option<u64> {
        return switch self.a().op_method.get(&n) {
            Some(v) => Option::<u64>::Some(*v),
            None => Option::<u64>::None,
        };
    }

    /// The concrete generic arguments recorded at use site `n`, or null.
    pub const fn generic_args(self: &Self, n: NodeId) *const MonoUse {
        return self.a().type_args(n);
    }

    /// The conversion recorded at `n` (`target::from(expr)` or a builtin widening), or null.
    pub const fn coercion(self: &Self, n: NodeId) *const CoerceUse {
        return self.a().coerce_of(n);
    }

    /// The auto-dereference chain recorded at `n` (receiver adjustments, in order), or null.
    pub const fn derefs(self: &Self, n: NodeId) *const DerefUse {
        return self.a().deref_use_at(n);
    }

    /// The dynamic-interface erasure recorded at `n`, or null.
    pub const fn dyn_conv(self: &Self, n: NodeId) *const DynUse {
        return self.a().dyn_use_at(n);
    }

    /// The wide-literal record for `n` (limbs already two's-complemented/masked), or null.
    pub const fn wide_lit(self: &Self, n: NodeId) *const WideLit {
        let i = self.a().wide_lit_of(n);
        if i < 0 {
            return null;
        }
        return self.a().wide_lits.at(i as usize);
    }

    /// The receiver type a method reference was resolved on: the checked type of the receiver
    /// expression `recv` (method selection itself is in `call_info`/`res`).
    pub const fn receiver_type(self: &Self, recv: NodeId) TypeId {
        return self.a().type_of(recv);
    }

    /// A closure's captures: the binding list the type checker recorded on the closure node, with
    /// `mut_caps` naming the captures taken as implicit `&mut`.
    pub const fn captures(self: &Self, closure: NodeId) NodeList {
        return self.node(closure).as_data.closure.captures;
    }

    pub const fn mut_captures(self: &Self, closure: NodeId) u32 {
        return self.node(closure).as_data.closure.mut_caps;
    }

    /// First attribute of `kind` on declaration `n`, or null (the Attr side table is owner-keyed).
    pub const fn attr_of(self: &Self, n: NodeId, kind: u8) *const Attr {
        for i in 0..self.a().attrs.len() {
            if self.a().attrs.at(i).owner == n && self.a().attrs.at(i).kind == kind {
                return self.a().attrs.at(i);
            }
        }
        return null;
    }

    /// The lifetime declarations attached to declaration `owner` (empty when none).
    pub const fn lifetimes(self: &Self, owner: NodeId) NodeList {
        return self.a().lifetimes_of(owner);
    }
}

/// Type-check completion watermarks for one module: the length of every semantic table when the
/// checker finished. SC_FACTS_CHECK compares these after later stages -- borrow checking must change
/// nothing; codegen/propagation changes must stay inside the documented allowlist above.
pub struct FactsWatermark {
    pub nodes: usize,
    pub children: usize,
    pub resolutions: usize,
    pub types: usize,
    pub type_pool: usize,
    pub instances: usize,
    pub mono: usize,
    pub method_insts: usize,
    pub method_refs: usize,
    pub coerces: usize,
    pub coerce_map: usize,
    pub dyn_uses: usize,
    pub deref_uses: usize,
    pub wide_lits: usize,
    pub const_lins: usize,
    pub attrs: usize,
    pub metas: usize,
    pub lifetime_decls: usize,
    pub call_infos: usize,
    pub op_methods: usize,
}

/// Snapshot module `a`'s semantic-table lengths.
pub const fn watermark(a: &Ast) FactsWatermark {
    return FactsWatermark {
        nodes: a.nodes.len(),
        children: a.children.len(),
        resolutions: a.resolutions.len(),
        types: a.types.len(),
        type_pool: a.type_pool.len(),
        instances: a.instances.len(),
        mono: a.mono.len(),
        method_insts: a.method_insts.len(),
        method_refs: a.method_refs.len(),
        coerces: a.coerces.len(),
        coerce_map: a.coerce_at.len(),
        dyn_uses: a.dyn_uses.len(),
        deref_uses: a.deref_uses.len(),
        wide_lits: a.wide_lits.len(),
        const_lins: a.const_lins.len(),
        attrs: a.attrs.len(),
        metas: a.metas.len(),
        lifetime_decls: a.lifetime_decls.len(),
        call_infos: a.call_info.len(),
        op_methods: a.op_method.len(),
    };
}

// Report one changed table to stderr; returns 1 so callers can count differences.
@c.cold
fn wm_diff(mid: u32, what: str, was: usize, now: usize) u32 {
    eprint("facts-check: module ");
    let mut s = String::new();
    s.push_u64(mid);
    s.push_str(": ");
    s.push_str(what);
    s.push_str(" ");
    s.push_u64(was as u64);
    s.push_str(" -> ");
    s.push_u64(now as u64);
    s.eprintln();
    return 1;
}

/// Compare a stored watermark against module `a`'s current tables; report every difference through
/// stderr prefixed with `facts-check:`. Returns the number of changed tables. One strict set applies
/// after EVERY later stage -- borrow checking, lowering, planning, and codegen all read frozen
/// semantic data; only the intern pools (see the module header) may grow.
@c.cold
pub fn watermark_check(a: &Ast, w: &FactsWatermark, mid: u32) u32 {
    let mut d: u32 = 0;
    if a.nodes.len() != w.nodes {
        d += wm_diff(mid, "nodes", w.nodes, a.nodes.len());
    }
    if a.children.len() != w.children {
        d += wm_diff(mid, "children", w.children, a.children.len());
    }
    if a.resolutions.len() != w.resolutions {
        d += wm_diff(mid, "resolutions", w.resolutions, a.resolutions.len());
    }
    if a.types.len() != w.types {
        d += wm_diff(mid, "types", w.types, a.types.len());
    }
    if a.coerces.len() != w.coerces {
        d += wm_diff(mid, "coerces", w.coerces, a.coerces.len());
    }
    if a.coerce_at.len() != w.coerce_map {
        d += wm_diff(mid, "coerce_at", w.coerce_map, a.coerce_at.len());
    }
    if a.mono.len() != w.mono {
        d += wm_diff(mid, "mono", w.mono, a.mono.len());
    }
    if a.method_insts.len() != w.method_insts {
        d += wm_diff(mid, "method_insts", w.method_insts, a.method_insts.len());
    }
    if a.method_refs.len() != w.method_refs {
        d += wm_diff(mid, "method_refs", w.method_refs, a.method_refs.len());
    }
    if a.dyn_uses.len() != w.dyn_uses {
        d += wm_diff(mid, "dyn_uses", w.dyn_uses, a.dyn_uses.len());
    }
    if a.deref_uses.len() != w.deref_uses {
        d += wm_diff(mid, "deref_uses", w.deref_uses, a.deref_uses.len());
    }
    if a.wide_lits.len() != w.wide_lits {
        d += wm_diff(mid, "wide_lits", w.wide_lits, a.wide_lits.len());
    }
    if a.attrs.len() != w.attrs {
        d += wm_diff(mid, "attrs", w.attrs, a.attrs.len());
    }
    if a.metas.len() != w.metas {
        d += wm_diff(mid, "metas", w.metas, a.metas.len());
    }
    if a.lifetime_decls.len() != w.lifetime_decls {
        d += wm_diff(mid, "lifetime_decls", w.lifetime_decls, a.lifetime_decls.len());
    }
    if a.call_info.len() != w.call_infos {
        d += wm_diff(mid, "call_info", w.call_infos, a.call_info.len());
    }
    if a.op_method.len() != w.op_methods {
        d += wm_diff(mid, "op_method", w.op_methods, a.op_method.len());
    }
    return d;
}
