// The typed-facts boundary: every semantic decision the type checker records for a body -- node
// types, resolutions, call targets, bound-call conformances, generic arguments, operator methods,
// coercion/dereference sequences, dynamic conversions, wide literals and captures -- behind ONE
// read-only interface. Core IR lowering and every later new
// consumer reads these accessors, never the Ast side tables directly, so the tables can move off
// `Ast` without touching consumers. Nothing here mutates.
//
// The freeze contract (enforced by the driver's SC_FACTS_CHECK mode after borrow checking AND after
// codegen): at type-check completion every semantic DECISION table is final -- nodes, children,
// resolutions, per-node types, coercions, bound calls, mono/method-instance demands, method_refs,
// dyn/deref selections, wide literals, attributes, lifetime declarations, call_info, op_method,
// pattern values. Every later stage (borrow checking, Core IR lowering, instance planning, const-eval
// fold discharge, emission) reads this data frozen. The ONE sanctioned mutation is interning: the type
// pools (the module's `pool` and the package table `gt`, with their instances, const-expression
// forms and index tables) grow append-only whenever a later stage interns a substituted or replayed
// type, and an interned entry is never removed or renumbered -- growth changes no existing answer.
import ast::ast as *;

/// Read-only view of one module's typed AST. Holds a raw pointer because consumers thread it through
/// stages that also hold the package; the Ast must outlive the view (it always does: views are built
/// per pass over a loaded package).
pub struct TypedFacts {
    pub ast: *const Ast,
    /// The reader cannot see this item's checked state (`graph::items::visible`): every TYPED
    /// accessor answers as an unchecked item would (syntax accessors stay live), whatever a
    /// worker has done with it, so every schedule reads the same facts.
    pub unchecked_view: bool,
}

extend TypedFacts {
    pub const fn of(a: *const Ast) TypedFacts {
        return TypedFacts { ast: a, unchecked_view: false };
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
        if self.unchecked_view {
            return TYPE_NONE;
        }
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
        return self.a().resolution_def(n); // resolution is resolve-final: live in every view
    }

    /// The type args recorded for `n` (turbofish/inference), or null.
    pub const fn type_args(self: &Self, n: NodeId) *const MonoUse {
        if self.unchecked_view {
            return null;
        }
        return self.a().type_args(n);
    }

    /// The call target + ABI data the type checker selected at call node `n`
    /// ((fmod << 40 | fdecl << 8 | skip) -- the record borrowck replays), or None.
    pub const fn call_info(self: &Self, n: NodeId) Option<u64> {
        if self.unchecked_view {
            return Option::<u64>::None;
        }
        return switch self.a().call_info.get(&n) {
            Some(v) => Option::<u64>::Some(*v),
            None => Option::<u64>::None,
        };
    }

    /// The operator method selected at operator node `n` ((module << 32 | node)), or None.
    pub const fn op_method(self: &Self, n: NodeId) Option<u64> {
        if self.unchecked_view {
            return Option::<u64>::None;
        }
        return switch self.a().op_method.get(&n) {
            Some(v) => Option::<u64>::Some(*v),
            None => Option::<u64>::None,
        };
    }

    /// The value of integer constant pattern `n` (a literal-pattern value or a range bound) in the
    /// matched type, as two's complement bits, or None.
    pub const fn pat_value(self: &Self, n: NodeId) Option<u64> {
        if self.unchecked_view {
            return Option::<u64>::None;
        }
        return switch self.a().pat_vals.get(&n) {
            Some(v) => Option::<u64>::Some(*v),
            None => Option::<u64>::None,
        };
    }

    /// The conversion recorded at `n` (`target::from(expr)` or a builtin widening), or null.
    pub const fn coercion(self: &Self, n: NodeId) *const CoerceUse {
        if self.unchecked_view {
            return null;
        }
        return self.a().coerce_of(n);
    }

    /// The `dyn I<args>` naming the conformance bound call `n` dispatches to, or TYPE_NONE.
    pub const fn bound_call(self: &Self, n: NodeId) TypeId {
        if self.unchecked_view {
            return TYPE_NONE;
        }
        return self.a().bound_call_of(n);
    }

    /// The auto-dereference chain recorded at `n` (receiver adjustments, in order), or null.
    pub const fn derefs(self: &Self, n: NodeId) *const DerefUse {
        if self.unchecked_view {
            return null;
        }
        return self.a().deref_use_at(n);
    }

    /// The dynamic-interface erasure recorded at `n`, or null.
    pub const fn dyn_conv(self: &Self, n: NodeId) *const DynUse {
        if self.unchecked_view {
            return null;
        }
        return self.a().dyn_use_at(n);
    }

    /// The wide-literal record for `n` (limbs already two's-complemented/masked), or null.
    pub const fn wide_lit(self: &Self, n: NodeId) *const WideLit {
        if self.unchecked_view {
            return null;
        }
        let i = self.a().wide_lit_of(n);
        if i < 0 {
            return null;
        }
        return self.a().wide_lits.at(i as usize);
    }

    /// A closure's captures: the binding list the type checker recorded on the closure node (its
    /// `mut_caps` mask names the captures taken as implicit `&mut`).
    pub const fn captures(self: &Self, closure: NodeId) NodeList {
        return self.node(closure).as_data.closure.captures;
    }
}

/// Type-check completion watermarks for one module: the length of every semantic table when the
/// checker finished. SC_FACTS_CHECK compares these after later stages -- borrow checking must change
/// nothing; codegen/propagation changes must stay inside the documented allowlist above.
pub struct FactsWatermark {
    pub n: [usize; WM_N],
}

const WM_N: usize = 22;
// The first WM_BODY entries are module tables; the next four are body-arena tables, checked only
// while the arena is live (the driver releases it after the constant flush; see
// `Ast::release_bodies`).
const WM_BODY: usize = 4;
const WM_NAMES: [str<'static>; WM_N] = [
    "nodes",
    "children",
    "resolutions",
    "types",
    "body nodes",
    "body children",
    "body resolutions",
    "body types",
    "coerces",
    "coerce_at",
    "bound_calls",
    "mono",
    "method_refs",
    "dyn_uses",
    "deref_uses",
    "wide_lits",
    "attrs",
    "metas",
    "lifetime_decls",
    "call_info",
    "op_method",
    "pat_vals",
];

/// Snapshot module `a`'s semantic-table lengths, in WM_NAMES order.
pub const fn watermark(a: &Ast) FactsWatermark {
    return FactsWatermark {
        n: [
            a.nodes.len(),
            a.children.len(),
            a.resolutions.len(),
            a.types.len(),
            a.b.nodes.len(),
            a.b.children.len(),
            a.b.resolutions.len(),
            a.b.types.len(),
            a.coerces.len(),
            a.coerce_at.len(),
            a.bound_calls.len(),
            a.mono.len(),
            a.method_refs.len(),
            a.dyn_uses.len(),
            a.deref_uses.len(),
            a.wide_lits.len(),
            a.attrs.len(),
            a.metas.len(),
            a.lifetime_decls.len(),
            a.call_info.len(),
            a.op_method.len(),
            a.pat_vals.len(),
        ],
    };
}

/// Compare a stored watermark against module `a`'s current tables; report every difference through
/// stderr prefixed with `facts-check:`. Returns the number of changed tables. One strict set applies
/// after EVERY later stage -- borrow checking, lowering, planning, and codegen all read frozen
/// semantic data; only the intern pools (see the module header) may grow.
@c.cold
pub fn watermark_check(a: &Ast, w: &FactsWatermark, mid: u32) u32 {
    let now = watermark(a);
    let live_body = a.b.nodes.len() != 0;
    let mut d: u32 = 0;
    for k in 0..WM_N {
        let was = unsafe w.n[k];
        let cur = unsafe now.n[k];
        if was == cur || !live_body && k >= WM_BODY && k < 2 * WM_BODY {
            continue;
        }
        let mut s = String::from_str("facts-check: module ");
        s.push_u64(mid);
        s.push_str(": ");
        s.push_str(unsafe WM_NAMES[k]);
        s.push_str(" ");
        s.push_u64(was as u64);
        s.push_str(" -> ");
        s.push_u64(cur as u64);
        s.eprintln();
        d += 1;
    }
    return d;
}
