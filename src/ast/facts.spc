// The typed-facts boundary: every semantic decision the type checker
// records for a body -- node types, resolutions, call targets, generic arguments, operator methods,
// coercion/dereference sequences, dynamic conversions, wide literals, captures, attributes and
// lifetime declarations -- behind ONE read-only interface. Core IR lowering and every later new
// consumer reads these accessors, never the Ast side tables directly, so the tables can move off
// `Ast` without touching consumers. Nothing here mutates.
//
// Permitted post-typecheck mutations of the underlying tables (each removed by a later phase; the
// driver's SC_FACTS_CHECK mode enforces this list):
//   1. Borrow checking interns types while replaying call/peel decisions, growing `type_pool`,
//      `instances`, and `const_lins` ONLY -- it makes no new semantic decision (removed by
//      the borrow checker reads frozen Core IR instead of re-walking the typed AST).
//   2. Instance propagation and codegen owner-swap emission append to `type_pool`/`type_index`,
//      `instances`, `method_insts`, `mono`, `const_lins`, `nodes`/`children`, `resolutions`, and
//      the per-node `types` array, and codegen truncates `instances` during owner-swap (removed by
//      instance collection, the streaming backend, and the immutable-syntax switch land).
//   3. Codegen temporarily removes and restores `coerce_at` entries around operator lowering
//      (removed with the streaming backend).
//   4. Deferred const-eval folds intern types while discharging package-level obligations
//      (removed with the IR const evaluator).
// Everything else -- resolutions of existing nodes, coercions, deref/dyn selections, call_info,
// op_method, method_refs, wide literals, attributes, lifetime declarations -- is frozen at
// type-check completion in EVERY mode.
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
pub fn watermark(a: &Ast) FactsWatermark {
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

/// watermark_check modes: which documented allowlist applies.
pub const FACTS_AFTER_BORROWCK: u8 = 0; // allowlist item 1 only (type_pool/instances growth)
pub const FACTS_AFTER_CODEGEN: u8 = 1; // allowlist items 1-4 (arena + syntax appends, coercion churn)

/// Compare a stored watermark against module `a`'s current tables; report every difference through
/// stderr prefixed with `facts-check:`. Returns the number of changed tables OUTSIDE the mode's
/// documented allowlist (see the module header).
@c.cold
pub fn watermark_check(a: &Ast, w: &FactsWatermark, mid: u32, mode: u8) u32 {
    let mut d: u32 = 0;
    if mode == FACTS_AFTER_BORROWCK {
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
        if a.mono.len() != w.mono {
            d += wm_diff(mid, "mono", w.mono, a.mono.len());
        }
        if a.method_insts.len() != w.method_insts {
            d += wm_diff(mid, "method_insts", w.method_insts, a.method_insts.len());
        }
        if a.coerces.len() != w.coerces {
            d += wm_diff(mid, "coerces", w.coerces, a.coerces.len());
        }
        if a.coerce_at.len() != w.coerce_map {
            d += wm_diff(mid, "coerce_at", w.coerce_map, a.coerce_at.len());
        }
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
