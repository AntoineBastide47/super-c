import string as cstring;
import stdlib;
import math;
import lexer::token as tok;
import lexer::token_type as *;
import ast::ast as *;
import module::loader as loader;
import utils::errors as diag;

// Compile-time constant evaluation (always on), in two layers: a memoized scalar folder over TYPED
// expression nodes, and a layout engine under the 64-bit C data model. Both are PARTIAL by design:
// anything unfoldable reports "not const" (CONST_NONE / CV_NIL) and stays a runtime construct.
// The interpreter runs under step/memory/depth budgets against an abstract object heap (the CeObj
// store, pooled across top-level folds); failures classify into trap kinds -- "cannot evaluate"
// stays silent, while proven UB and failed `const fn` folds are recorded (fold_errs) for codegen to
// surface as errors. static_asserts and consts undecidable in module order are deferred and flushed
// once every module is typed (all_typed).

pub const CE_MAX_DEPTH: i32 = 32;
pub const CE_DEFAULT_STEPS: u32 = 2097152u32; // 1<<21
pub const CE_DEFAULT_SLOTS: u64 = 4194304u64; // 1<<22
pub const CE_MAX_FRAMES: u32 = 48;
pub const CE_MAX_LOCALS: u32 = 96;
pub const CE_MAX_DEFERS: u8 = 24;
pub const CE_MAX_OBJS: u32 = 65536u32; // 1<<16
pub const CE_CALLS_MAX: usize = 65536; // 1<<16

// ConstKind (public) / CvKind (interpreter)
pub const CONST_NONE: u8 = 0;
pub const CONST_INT: u8 = 1;
pub const CONST_BOOL: u8 = 2;
pub const CONST_FLOAT: u8 = 3;
pub const CONST_EVALUATING: u8 = 4; // in-flight memo sentinel (cycle detection); never escapes eval
pub const CONST_AGG_OK: u8 = 5; // memo-only: evaluates successfully to a non-scalar. A positive fact
// (so the positive-only memo rule holds); eval() reports it as CONST_NONE without re-interpreting,
// which keeps codegen's repeated fold probes of aggregate-producing calls O(1).

pub const CV_NIL_K: u8 = 0;
pub const CV_INT: u8 = 1;
pub const CV_BOOL: u8 = 2;
pub const CV_FLOAT: u8 = 3;
pub const CV_PTR: u8 = 4;
pub const CV_AGG: u8 = 5;
pub const CV_FN: u8 = 6;

// Trap kinds partition into "cannot evaluate" (BUDGET_*/CYCLE/TOO_LARGE/UNSUPPORTED), "definite
// outcome if this code runs" (PANIC, UB_*); UB kinds stay contiguous so ce_trap_is_ub is a range check.
pub const CE_TRAP_NONE: u8 = 0;
pub const CE_TRAP_BUDGET_STEPS: u8 = 1;
pub const CE_TRAP_BUDGET_MEMORY: u8 = 2;
pub const CE_TRAP_BUDGET_DEPTH: u8 = 3;
pub const CE_TRAP_CYCLE: u8 = 4;
pub const CE_TRAP_TOO_LARGE: u8 = 5;
pub const CE_TRAP_UNSUPPORTED: u8 = 6;
pub const CE_TRAP_PANIC: u8 = 7;
pub const CE_TRAP_UB_DIV_ZERO: u8 = 8;
pub const CE_TRAP_UB_OVERFLOW: u8 = 9;
pub const CE_TRAP_UB_SHIFT: u8 = 10;
pub const CE_TRAP_UB_NULL_DEREF: u8 = 11;
pub const CE_TRAP_UB_USE_AFTER_FREE: u8 = 12;
pub const CE_TRAP_UB_DOUBLE_FREE: u8 = 13;
pub const CE_TRAP_UB_OOB: u8 = 14;

pub const fn ce_trap_is_ub(k: u8) bool {
    return k >= CE_TRAP_UB_DIV_ZERO;
}

// Effect-summary verdicts: NO = evaluation is certain to fail (a hard disqualifier on the
// unconditionally-executed spine); MAYBE = unknown (dispatch, conditionals, fn values); YES =
// everything reachable on the spine is evaluable. Consumers only distinguish NO vs not-NO, so
// gray (ONSTACK) edges in recursive scans are neutral and full SCC machinery is unnecessary.
pub const FX_UNKNOWN: u8 = 0;
pub const FX_YES: u8 = 1;
pub const FX_MAYBE: u8 = 2;
pub const FX_NO: u8 = 3;
pub const FX_ONSTACK: u8 = 4;

const fn fx_meet(a: u8, b: u8) u8 {
    if a == FX_NO || b == FX_NO {
        return FX_NO;
    }
    if a == FX_MAYBE || b == FX_MAYBE {
        return FX_MAYBE;
    }
    return FX_YES;
}

// statement outcomes
pub enum Flow {
    Ok,
    Return,
    Break,
    Continue,
    Bail,
}

pub const I64_MIN: i64 = 0x8000000000000000u64 as i64;
pub const I64_MAX: i64 = 0x7FFFFFFFFFFFFFFFu64 as i64;
pub const U64_MAX: u64 = 0xFFFFFFFFFFFFFFFFu64;
pub const F64_MAX: f64 = 1.7976931348623157e308;

// --- value types --------------------------------------------------------------------------------

pub union ConstValueAs {
    pub i: i64,
    pub f: f64,
}
pub struct ConstValue {
    pub kind: u8,
    pub ty: TypeId,
    pub as_data: ConstValueAs,
}

pub struct CvPtr {
    pub obj: u32,
    pub off: u32,
}
pub struct CvFn {
    pub m: ModuleId,
    pub fn_id: NodeId,
}
pub union CeValAs {
    pub i: i64,
    pub f: f64,
    pub p: CvPtr,
    pub fnv: CvFn,
}
pub struct CeVal {
    pub kind: u8,
    pub tm: ModuleId,
    pub ty: TypeId,
    pub as_data: CeValAs,
}

const fn cv_nil() CeVal {
    return CeVal { kind: CV_NIL_K };
}
const fn ce_none() ConstValue {
    return ConstValue { kind: CONST_NONE };
}

pub struct CePending {
    pub m: ModuleId,
    pub cond: NodeId,
}

// Fixed-buffer wrappers: a struct field zero-inits its array (Super-C has no `[v; N]` repeat-init).
pub type Buf64 = Array<char, 64>;
pub type Buf24 = Array<char, 24>;
pub type Buf512 = Array<char, 512>;
pub type Buf4096 = Array<u8, 4096>;
pub type Buf32 = Array<u8, 32>;

// --- layout engine structs ----------------------------------------------------------------------

pub struct LayoutEnv {
    pub parent: *const LayoutEnv,
    pub pmod: ModuleId,
    pub params: *const NodeId,
    pub argm: ModuleId,
    pub args: [TypeId; 8],
    pub n: u8,
}

pub struct LayoutAcc {
    pub size: u64,
    pub align: u64,
    pub packed: bool,
    pub is_union: bool,
}

// --- object store -------------------------------------------------------------------------------

pub struct CeObj {
    pub slots: Vector<CeVal>,
    pub dead: u8,
    pub is_enum: u8,
    pub heap: u8,
    pub uactive: i32, // union: the member the value was written through; -1 for a struct/enum
    pub dm: ModuleId,
    pub dn: NodeId,
    pub nargs: u8,
    pub am: [ModuleId; 4],
    pub at: [TypeId; 4],
    pub bytes: u64, // heap: allocated byte size
    pub em: ModuleId, // heap: element type module
    pub et: TypeId, // heap: element type; TYPE_NONE until the first cast to *mut T
    pub esz: u64, // heap: sizeof(element)
}

extend CeObj as Free {
    pub fn free(self: &mut Self) {
        self.slots.free();
    }
}

// The receiver identity a method dispatches on: an aggregate decl + concrete args, or a builtin.
pub struct CeRecv {
    pub dm: ModuleId,
    pub dn: NodeId, // NODE_NONE => builtin receiver
    pub b: BuiltinType,
    pub n: u8,
    pub am: [ModuleId; 4],
    pub at: [TypeId; 4],
}

const fn ce_recv_zero() CeRecv {
    return CeRecv { dn: NODE_NONE, b: BuiltinType::BT_COUNT };
}

// --- frame --------------------------------------------------------------------------------------

pub struct CeLocal {
    pub decl: NodeId,
    pub slot: u32,
}

pub struct CeFrame {
    pub env: u32,
    pub locals: [CeLocal; 96],
    pub n: u32,
    pub rets: [CeVal; 8],
    pub nrets: u8,
    pub returned: u8,
    pub early: u8,
    pub pmod: ModuleId,
    pub params_g: [NodeId; 8],
    pub am: [ModuleId; 8],
    pub at: [TypeId; 8],
    pub ng: u8,
    pub defers: [NodeId; 24],
    pub ndefers: u8,
}

const fn ce_frame_zero() CeFrame {
    return CeFrame { env: 0 };
}

// --- call memoization ---------------------------------------------------------------------------

pub struct CeCallKey {
    pub m: ModuleId,
    pub fn_id: NodeId,
    pub nargs: u8,
    pub kinds: [u8; 8],
    pub bits: [i64; 8],
}

extend CeCallKey as Hash {
    pub fn hash(self: &Self) u64 {
        let mut h: u64 = 1469598103934665603u64;
        h = (h ^ self.m as u64) * 1099511628211u64;
        h = (h ^ self.fn_id as u64) * 1099511628211u64;
        h = (h ^ self.nargs as u64) * 1099511628211u64;
        for i in 0..8 {
            h = (h ^ (unsafe self.kinds[i]) as u64) * 1099511628211u64;
            h = (h ^ (unsafe self.bits[i]) as u64) * 1099511628211u64;
        }
        return h;
    }
}

extend CeCallKey as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        if self.m != other.m || self.fn_id != other.fn_id || self.nargs != other.nargs {
            return false;
        }
        for i in 0..8 {
            if unsafe self.kinds[i] != unsafe other.kinds[i] || unsafe self.bits[i] != unsafe other.bits[i] {
                return false;
            }
        }
        return true;
    }
}

pub struct CeCallHit {
    pub nrets: u8,
    pub rets: [CeVal; 8],
}

pub struct UFree {
    pub m: ModuleId,
    pub n: NodeId,
    pub user: bool,
}

// Why a function's effect verdict is FX_NO: the first disqualifying site found on its spine.
pub struct FxNo<'a> {
    pub m: ModuleId,
    pub fn_id: NodeId,
    pub site: NodeId,
    pub why: str<'a>,
}

// A fold failure codegen must surface as an error: proven UB, or any failed `const fn` fold.
// detail is rendered eagerly — trap state is reused by later evals.
pub struct CeFoldErr {
    pub m: ModuleId,
    pub id: NodeId,
    pub kind: u8,
    pub constfn: bool, // the failure happened at or below a `const fn` frame
    pub detail: Buf512,
}

pub struct ConstEval<'a> {
    pub pkg: *mut loader::Package,
    pub vals: Vector<Vector<ConstValue>>, // [module][node] memo tables
    pub nmods: usize,
    pub depth: u32,
    pub nframes: u32,
    pub steps: u32,
    pub max_steps: u32,
    pub max_slots: u64,
    pub objs: Vector<CeObj>,
    // Live-object cursor: reset rewinds this instead of freeing -- retained CeObjs (and their slot
    // vectors' capacity) are reused by the next fold, so the abstract heap stops churning malloc.
    pub objs_live: usize,
    pub live_slots: u64,
    pub trap: str<'a>,
    pub trap_kind: u8,
    pub trap_steps: u32,
    pub trap_nframes: u8,
    pub trap_stack: [CvFn; 48], // fstack snapshot at first trap (CE_MAX_FRAMES entries)
    pub fstack: [CvFn; 48], // live CTFE call stack, indexed by nframes
    pub dbuf: Buf512, // trap-detail render buffer (ce_trap_detail)
    pub record_folds: bool, // armed during codegen emission: failed folds with promotable traps are recorded
    pub record_pause: u32, // >0 while codegen emits a short-circuit-guarded subexpression (&&/|| RHS)
    pub trap_in_constfn: bool, // a failed evaluation involved a `const fn` frame: always promotable
    pub all_typed: bool, // every module is typechecked: silent failures are no longer module-order artifacts
    pub invoke_ran: bool, // the innermost invoke bound its arguments and began executing the body
    pub fold_errs: Vector<CeFoldErr>,
    pub pending: Vector<CePending>,
    pub pending_consts: Vector<CePending>, // const decls undecidable in module order (cond = NODE_CONST)
    pub calls: Map<CeCallKey, CeCallHit>,
    pub ufree: Vector<UFree>,
    pub fx: Vector<Vector<u8>>, // [module][fn node] effect verdicts (FX_*)
    pub fxd: Vector<Vector<u8>>, // deep (all-paths) verdicts: FX_YES = every path provably evaluates (const-suggestion lint)
    pub fx_no: Vector<FxNo<'a>>,
    pub fx_depth: u32,
    pub statics: Vector<StaticObj>, // materialized const object graphs (grouped per root)
    pub ti_nfields: i64, // field/variant counts of the LAST ce_type_info_of build (type_info_count)
    pub ti_nvars: i64,
    pub ce_projs: Vector<CeProj>, // active fields-loop iterations, innermost last
    pub sref: Vector<Vector<i64>>, // [module][node] eval_static memo: 0 unattempted, -1 failed, else root+1
}

// --- small result structs (replace C out-params) ------------------------------------------------

pub struct Layout {
    pub ok: bool,
    pub size: u64,
    pub align: u64,
}
pub struct RType {
    pub ok: bool,
    pub m: ModuleId,
    pub t: TypeId,
}
pub struct RecvRes {
    pub ok: bool,
    pub r: CeRecv,
}
pub struct ValRes {
    pub ok: bool,
    pub v: CeVal,
}
pub struct ObjRes {
    pub ok: bool,
    pub obj: u32,
}
pub struct Rets {
    pub ok: bool,
    pub n: u8,
    pub vals: [CeVal; 8],
}
pub struct FieldIdx {
    pub idx: i32,
    pub field: NodeId,
}
pub struct VarPos {
    pub pos: i32,
    pub enum_decl: NodeId,
}
pub struct OvfRes {
    pub ovf: bool,
    pub v: i64,
}

// --- scalar helpers (no ce state) ---------------------------------------------------------------

const fn bt_signed(b: BuiltinType) bool {
    return b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
}
const fn bt_unsigned(b: BuiltinType) bool {
    return b == BuiltinType::BT_U8 || b == BuiltinType::BT_U16 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_USIZE || b == BuiltinType::BT_CHAR;
}
const fn bt_bits(b: BuiltinType) i32 {
    if b == BuiltinType::BT_BOOL || b == BuiltinType::BT_CHAR || b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 {
        return 8;
    }
    if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 {
        return 16;
    }
    if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 {
        return 32;
    }
    return 64;
}

const fn wrap_to(b: BuiltinType, v: i64) i64 {
    let bits = bt_bits(b);
    if bits == 64 {
        return v;
    }
    let mask = (1u64 << bits as u64) - 1u64;
    let mut u = v as u64 & mask;
    if bt_signed(b) && u >> (bits - 1) as u64 != 0 {
        u = u | ~mask;
    }
    return u as i64;
}

const fn fits(b: BuiltinType, v: i64) bool {
    return wrap_to(b, v) == v;
}

const fn ce_isfinite(x: f64) bool {
    return unsafe math::fabs(x) <= F64_MAX;
}

// non-trapping (u64-wrapping) checked signed arithmetic; ovf=true means the result overflows i64
const fn add_ovf(a: i64, b: i64) OvfRes {
    let s = (a as u64 + b as u64) as i64;
    return OvfRes { ovf: ((a ^ s) & (b ^ s)) < 0, v: s };
}
const fn sub_ovf(a: i64, b: i64) OvfRes {
    let d = (a as u64 - b as u64) as i64;
    return OvfRes { ovf: ((a ^ b) & (a ^ d)) < 0, v: d };
}
const fn mul_ovf(a: i64, b: i64) OvfRes {
    let p = (a as u64 * b as u64) as i64;
    let mut ovf = false;
    if a > 0 {
        if b > 0 {
            ovf = a > I64_MAX / b;
        } else {
            ovf = b < I64_MIN / a;
        }
    } else if a < 0 {
        if b > 0 {
            ovf = a < I64_MIN / b;
        } else {
            ovf = a != 0 && b < I64_MAX / a;
        }
    }
    return OvfRes { ovf: ovf, v: p };
}

// --- ConstEval methods --------------------------------------------------------------------------

extend ConstEval {
    /// 0 for either budget selects the default; max_mem_bytes is converted to CeVal slots.
    pub fn new<'a>(pkg: *mut loader::Package, max_steps: u32, max_mem_bytes: u64) ConstEval<'a> {
        let count = unsafe pkg.modules.len();
        let mut ce = ConstEval {
            pkg: pkg,
            vals: Vector::<Vector<ConstValue>>::new(),
            nmods: count,
            depth: 0,
            nframes: 0,
            steps: 0,
            max_steps: if_default_steps(max_steps),
            max_slots: if_default_slots(max_mem_bytes),
            objs: Vector::<CeObj>::new(),
            objs_live: 0,
            live_slots: 0,
            trap: "",
            record_folds: false,
            record_pause: 0,
            trap_in_constfn: false,
            all_typed: false,
            invoke_ran: false,
            fold_errs: Vector::<CeFoldErr>::new(),
            pending: Vector::<CePending>::new(),
            pending_consts: Vector::<CePending>::new(),
            calls: Map::<CeCallKey, CeCallHit>::new(),
            ufree: Vector::<UFree>::new(),
            fx: Vector::<Vector<u8>>::new(),
            fxd: Vector::<Vector<u8>>::new(),
            fx_no: Vector::<FxNo>::new(),
            fx_depth: 0,
            statics: Vector::<StaticObj>::new(),
            sref: Vector::<Vector<i64>>::new(),
        };
        for _ in 0..count {
            ce.vals.push(Vector::<ConstValue>::new());
            ce.fx.push(Vector::<u8>::new());
            ce.fxd.push(Vector::<u8>::new());
            ce.sref.push(Vector::<i64>::new());
        }
        return ce;
    }

    // ---- ast / source access (raw pointers; deref under unsafe, mirroring the C const-view) ----

    const fn ast_ptr(self: &Self, m: ModuleId) *const Ast {
        // While a stage holds module `m`'s Ast (moved out of the slot), read the in-flight Ast it points at.
        let ov = self.pkg.override_at(m);
        if ov != 0 {
            return ov as *const Ast;
        }
        return unsafe &self.pkg.modules[m as usize].ast;
    }
    const fn mut_ast_ptr(self: &Self, m: ModuleId) *mut Ast {
        let ov = self.pkg.override_at(m);
        if ov != 0 {
            return ov as *mut Ast;
        }
        return unsafe &mut self.pkg.modules[m as usize].ast;
    }
    const fn has_ast(self: &Self, m: ModuleId) bool {
        if m as usize >= self.nmods {
            return false;
        }
        return unsafe self.pkg.modules[m as usize].has_ast;
    }
    const fn ce_src(self: &Self, m: ModuleId) str {
        return unsafe self.pkg.modules[m as usize].source.as_str();
    }
    const fn is_prelude(self: &Self, m: ModuleId) bool {
        return unsafe self.pkg.modules[m as usize].prelude;
    }

    // ast_type, safe on a module the checker hasn't reached (types table may not cover id yet).
    const fn ce_type(self: &Self, m: ModuleId, id: NodeId) TypeId {
        let a = self.ast_ptr(m);
        if unsafe a.types.len() > id as usize {
            return a.type_of(id);
        }
        return TYPE_NONE;
    }

    @c.cold
    fn ce_trap(self: &mut Self, kind: u8, msg: str) {
        if self.trap.len() == 0 {
            self.trap = msg;
            self.trap_kind = kind;
            self.trap_steps = self.steps;
            let mut n = self.nframes;
            if n > CE_MAX_FRAMES {
                n = CE_MAX_FRAMES;
            }
            self.trap_nframes = n as u8;
            for i in 0..n {
                unsafe self.trap_stack[i as usize] = unsafe self.fstack[i as usize];
            }
        }
    }
    // Speculative-probe guard: an evaluation that does not imply runtime execution must not leave a
    // trap behind. First-write-wins makes discard O(1): the probe can only have written if empty before.
    const fn trap_mark(self: &Self) bool {
        return self.trap.len() != 0;
    }
    const fn trap_discard(self: &mut Self, was: bool) {
        if !was && self.trap.len() != 0 {
            self.trap = "";
            self.trap_kind = CE_TRAP_NONE;
            self.trap_nframes = 0;
            self.trap_in_constfn = false;
        }
    }

    fn ce_tick(self: &mut Self) bool {
        self.steps = self.steps + 1;
        if self.steps > self.max_steps {
            self.ce_trap(CE_TRAP_BUDGET_STEPS, "const-eval step budget exceeded");
            return false;
        }
        return true;
    }

    // ---- memo ----
    const fn slot_get(self: &Self, m: ModuleId, id: NodeId) ConstValue {
        if m as usize >= self.vals.len() {
            return ce_none();
        }
        let inner = self.vals.at(m as usize);
        if id as usize >= inner.len() {
            return ce_none();
        }
        return inner[id as usize];
    }
    fn slot_set(self: &mut Self, m: ModuleId, id: NodeId, v: ConstValue) {
        if m as usize >= self.vals.len() {
            return;
        }
        let inner = &mut self.vals[m as usize];
        while inner.len() <= id as usize {
            inner.push(ce_none());
        }
        inner.set(id as usize, v);
    }

    // ---- spans ----
    const fn ce_spans_eq(self: &Self, ma: ModuleId, a: tok::Span, mb: ModuleId, b: tok::Span) bool {
        let la = a.end - a.start;
        if la != b.end - b.start {
            return false;
        }
        return unsafe cstring::memcmp(
            self.ce_src(ma).ptr() + a.start as usize,
            self.ce_src(mb).ptr() + b.start as usize,
            la as usize,
        ) == 0;
    }
    const fn ce_span_is(self: &Self, m: ModuleId, s: tok::Span, lit: str) bool {
        let n = lit.len();
        if (s.end - s.start) as usize != n {
            return false;
        }
        return unsafe cstring::memcmp(self.ce_src(m).ptr() + s.start as usize, lit.ptr(), n) == 0;
    }
    const fn name_text(self: &Self, m: ModuleId, name_node: NodeId) tok::Span {
        let a = self.ast_ptr(m);
        return a.at_const(name_node).as_data.name.text;
    }
}

const fn if_default_steps(s: u32) u32 {
    if s != 0 {
        return s;
    }
    return CE_DEFAULT_STEPS;
}
const fn if_default_slots(b: u64) u64 {
    if b != 0 {
        let s = b / sizeof(CeVal) as u64;
        if s != 0 {
            return s;
        }
        return 1;
    }
    return CE_DEFAULT_SLOTS;
}

const fn type_builtin(a: *const Ast, t: TypeId) BuiltinType {
    if t == TYPE_NONE {
        return BuiltinType::BT_COUNT;
    }
    let y = a.type_at(t);
    if y.kind == TypeKind::TYPE_BUILTIN {
        return y.as_data.builtin;
    }
    return BuiltinType::BT_COUNT;
}

const fn round_up(v: u64, a: u64) u64 {
    if a != 0 {
        return (v + a - 1) / a * a;
    }
    return v;
}

const fn hexval(ch: u8) i32 {
    if ch >= b'0' && ch <= b'9' {
        return ch - b'0';
    }
    if ch >= b'a' && ch <= b'f' {
        return ch - b'a' + 10u8;
    }
    if ch >= b'A' && ch <= b'F' {
        return ch - b'A' + 10u8;
    }
    return -1;
}

// --- literal parsing + layout engine ------------------------------------------------------------

extend ConstEval {
    fn eval_int_literal(self: &Self, m: ModuleId, id: NodeId) ConstValue {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = a.at_const(id).as_data.literal.raw;
        let mut endd = sp.end;
        ast_numeric_suffix(src, sp.start, sp.end, &mut endd);
        let mut v: u64 = 0;
        let mut i = sp.start;
        let mut base: u64 = 10;
        if sp.end - sp.start > 2 && src[i as usize] == b'0' {
            let r = src[(i + 1) as usize];
            if r == b'x' || r == b'X' {
                base = 16;
                i = i + 2;
            } else if r == b'b' || r == b'B' {
                base = 2;
                i = i + 2;
            } else if r == b'o' || r == b'O' {
                base = 8;
                i = i + 2;
            }
        }
        while i < endd {
            let ch = src[i as usize];
            if ch == b'_' {
                i = i + 1;
                continue;
            }
            let d = hexval(ch);
            if d < 0 || d as u64 >= base {
                return ce_none();
            }
            if v > (U64_MAX - d as u64) / base {
                return ce_none();
            }
            v = v * base + d as u64;
            i = i + 1;
        }
        let b = type_builtin(a, self.ce_type(m, id));
        let sv = v as i64;
        if b != BuiltinType::BT_COUNT && !fits(b, sv) {
            return ce_none();
        }
        return ConstValue { kind: CONST_INT, ty: self.ce_type(m, id), as_data: ConstValueAs { i: sv } };
    }

    fn eval_char_literal(self: &Self, m: ModuleId, id: NodeId) ConstValue {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = a.at_const(id).as_data.literal.raw;
        let mut i = sp.start + 1;
        if src[sp.start as usize] == b'b' {
            i = i + 1;
        }
        if i >= sp.end {
            return ce_none();
        }
        let mut v: i64 = 0;
        if src[i as usize] != b'\\' {
            v = src[i as usize];
        } else {
            let e = src[(i + 1) as usize];
            switch e {
                'n' => {
                    v = 10;
                },
                't' => {
                    v = 9;
                },
                'r' => {
                    v = 13;
                },
                '0' => {
                    v = 0;
                },
                '\\' => {
                    v = 92;
                },
                '\'' => {
                    v = 39;
                },
                '"' => {
                    v = 34;
                },
                'x' => {
                    v = 0;
                    let mut k = i + 2;
                    while k < sp.end - 1 {
                        let d = hexval(src[k as usize]);
                        if d < 0 {
                            return ce_none();
                        }
                        v = v * 16 + d as i64;
                        k = k + 1;
                    }
                },
                _ => {
                    return ce_none();
                },
            };
        }
        return ConstValue { kind: CONST_INT, ty: self.ce_type(m, id), as_data: ConstValueAs { i: v } };
    }

    fn eval_float_literal(self: &Self, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = a.at_const(id).as_data.literal.raw;
        let mut buf = Buf64 {};
        let mut k: usize = 0;
        let mut i = sp.start;
        while i < sp.end && k + 1 < 64 {
            if src[i as usize] != b'_' {
                buf[k] = src[i as usize] as char;
                k = k + 1;
            }
            i = i + 1;
        }
        buf[k] = 0 as char;
        let mut v = unsafe stdlib::strtod(&buf[0], null);
        let b = type_builtin(a, self.ce_type(m, id));
        if b == BuiltinType::BT_F32 {
            v = v as f32;
        } else if b != BuiltinType::BT_F64 && b != BuiltinType::BT_COUNT {
            return cv_nil();
        }
        return CeVal { kind: CV_FLOAT, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { f: v } };
    }

    // ---- layout engine ----
    fn ce_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) *const Attr {
        let a = self.ast_ptr(m);
        for i in 0..unsafe a.attrs.len() {
            let at = unsafe a.attrs.at(i);
            if at.owner == owner && at.kind == kind as u8 {
                return at;
            }
        }
        return null;
    }

    /// Whether `t` mentions a '@no_const' declaration anywhere (through pointers, references,
    /// slices, arrays and instance arguments). Such a value can never exist at compile time, so any
    /// expression it types disqualifies const evaluation.
    fn ce_ty_no_const(self: &Self, m: ModuleId, t: TypeId, depth: u32) bool {
        if t == TYPE_NONE || depth > 16 {
            return false;
        }
        let y = *self.ast_ptr(m).type_at(t);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.ce_ty_no_const(m, y.as_data.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.ce_attr(y.module, y.as_data.decl, AttrKind::ATTR_NO_CONST) != null;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_ptr(m).instance(y.as_data.inst);
            if self.ce_attr(it.module, it.decl, AttrKind::ATTR_NO_CONST) != null {
                return true;
            }
            for i in 0..it.n {
                if self.ce_ty_no_const(m, unsafe it.args[i as usize], depth + 1) {
                    return true;
                }
            }
        }
        return false;
    }

    // Accumulate one field into `acc`; false = unfoldable.
    fn acc_field(self: &mut Self, acc: *mut LayoutAcc, m: ModuleId, ft: TypeId, env: *const LayoutEnv, depth: i32) bool {
        let fl = self.layout_of(m, ft, env, depth);
        if !fl.ok {
            return false;
        }
        let mut fa = fl.align;
        if unsafe acc.packed {
            fa = 1;
        }
        if unsafe acc.is_union {
            if fl.size > unsafe acc.size {
                unsafe acc.size = fl.size;
            }
        } else {
            unsafe acc.size = round_up(unsafe acc.size, fa) + fl.size;
        }
        if fa > unsafe acc.align {
            unsafe acc.align = fa;
        }
        return true;
    }

    fn aggregate_layout(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, depth: i32) Layout {
        let a = self.ast_ptr(dm);
        let dkind = a.at_const(dn).kind;
        if dkind == NodeKind::NODE_ENUM {
            let ms = a.at_const(dn).as_data.aggregate.members;
            let mut payload = false;
            for i in 0..ms.len {
                let mid = unsafe a.list(ms)[i as usize];
                if a.at_const(mid).as_data.variant.payload.len > 0 {
                    payload = true;
                }
            }
            if !payload {
                return Layout { ok: true, size: 4, align: 4 };
            }
            let mut un = LayoutAcc { is_union: true };
            for i in 0..ms.len {
                let mid = unsafe a.list(ms)[i as usize];
                let pl = a.at_const(mid).as_data.variant.payload;
                if pl.len == 0 {
                    continue;
                }
                let struct_payload = a.at_const(mid).as_data.variant.struct_payload;
                let mut vs = LayoutAcc {};
                for k in 0..pl.len {
                    let pid = unsafe a.list(pl)[k as usize];
                    let mut tn = pid;
                    if struct_payload {
                        tn = a.at_const(pid).as_data.field.ty;
                    }
                    if !self.acc_field(&mut vs, dm, self.ce_type(dm, tn), env, depth) {
                        return Layout { ok: false };
                    }
                }
                vs.size = round_up(vs.size, vs.align);
                if vs.size > un.size {
                    un.size = vs.size;
                }
                if vs.align > un.align {
                    un.align = vs.align;
                }
            }
            let ssize = round_up(4, un.align) + un.size;
            let mut salign: u64 = 4;
            if un.align > salign {
                salign = un.align;
            }
            return Layout { ok: true, size: round_up(ssize, salign), align: salign };
        }
        if dkind != NodeKind::NODE_STRUCT {
            return Layout { ok: false };
        }
        let is_union = a.at_const(dn).as_data.aggregate.is_union;
        let is_tuple = a.at_const(dn).as_data.aggregate.is_tuple;
        let mut acc = LayoutAcc { is_union: is_union };
        acc.packed = self.ce_attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let fs = a.at_const(dn).as_data.aggregate.members;
        for i in 0..fs.len {
            let fid = unsafe a.list(fs)[i as usize];
            let fkind = a.at_const(fid).kind;
            if !is_tuple && fkind != NodeKind::NODE_FIELD {
                continue;
            }
            let mut ftn = fid;
            if !is_tuple {
                ftn = a.at_const(fid).as_data.field.ty;
            }
            let ft = self.ce_type(dm, ftn);
            if ft == TYPE_NONE {
                return Layout { ok: false };
            }
            if !self.acc_field(&mut acc, dm, ft, env, depth) {
                return Layout { ok: false };
            }
        }
        let al = self.ce_attr(dm, dn, AttrKind::ATTR_ALIGN);
        if al != null && unsafe al.arg != 0 {
            if (unsafe al.arg) as u64 > acc.align {
                acc.align = unsafe al.arg;
            }
        }
        if acc.align == 0 {
            acc.align = 1;
        }
        return Layout { ok: true, size: round_up(acc.size, acc.align), align: acc.align };
    }

    fn layout_of(self: &mut Self, m: ModuleId, t: TypeId, env: *const LayoutEnv, depth: i32) Layout {
        if depth > CE_MAX_DEPTH || t == TYPE_NONE {
            return Layout { ok: false };
        }
        if !self.has_ast(m) {
            return Layout { ok: false };
        }
        let a = self.ast_ptr(m);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL || b == BuiltinType::BT_CHAR || b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 {
                return Layout { ok: true, size: 1, align: 1 };
            }
            if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 {
                return Layout { ok: true, size: 2, align: 2 };
            }
            if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_F32 {
                return Layout { ok: true, size: 4, align: 4 };
            }
            if b == BuiltinType::BT_ISIZE || b == BuiltinType::BT_USIZE {
                let w = self.ptr_width();
                return Layout { ok: true, size: w, align: w };
            }
            if b == BuiltinType::BT_I64 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_F64 {
                return Layout { ok: true, size: 8, align: 8 };
            }
            if b == BuiltinType::BT_C32 {
                return Layout { ok: true, size: 8, align: 4 };
            }
            if b == BuiltinType::BT_C64 {
                return Layout { ok: true, size: 16, align: 8 };
            }
            return Layout { ok: false };
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_FUNCTION {
            let w = self.ptr_width();
            return Layout { ok: true, size: w, align: w };
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len == 0 {
                return Layout { ok: false };
            }
            let el = self.layout_of(m, y.as_data.arr.elem, env, depth + 1);
            if !el.ok {
                return Layout { ok: false };
            }
            return Layout { ok: true, size: el.size * y.as_data.arr.len as u64, align: el.align };
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut e = env;
            while e != null {
                for i in 0..unsafe e.n {
                    if unsafe e.pmod == y.module && unsafe e.params[i as usize] == y.as_data.decl {
                        return self.layout_of(unsafe e.argm, unsafe e.args[i as usize], unsafe e.parent, depth + 1);
                    }
                }
                e = unsafe e.parent;
            }
            return Layout { ok: false };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.aggregate_layout(y.module, y.as_data.decl, null, depth + 1);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            if !self.has_ast(it.module) {
                return Layout { ok: false };
            }
            let da = self.ast_ptr(it.module);
            let gens = da.at_const(it.decl).as_data.aggregate.generics;
            let mut frame = LayoutEnv { parent: env, pmod: it.module, params: da.list(gens), argm: m, n: 0 };
            let mut i: u32 = 0;
            while i < gens.len && i as u8 < it.n && frame.n < 8 {
                unsafe frame.args[frame.n as usize] = unsafe it.args[i as usize];
                frame.n = frame.n + 1;
                i = i + 1;
            }
            return self.aggregate_layout(it.module, it.decl, &frame, depth + 1);
        }
        return Layout { ok: false };
    }

    /// Size/align of (m,t) under the 64-bit C data model; not-ok = not layoutable (opaque, unbound
    /// generic, zero-length array).
    pub fn layout(self: &mut Self, m: ModuleId, t: TypeId) Layout {
        return self.layout_of(m, t, null, 0);
    }

    // ---- type utilities ----

    // Resolve (m,t) through the frame's substitution while it names a generic param (one hop resolves).
    fn ce_rtype(self: &Self, f: *mut CeFrame, m0: ModuleId, t0: TypeId) RType {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..8 {
            if t == TYPE_NONE {
                return RType { ok: false };
            }
            let y = self.ast_ptr(m).type_at(t);
            if y.kind != TypeKind::TYPE_GENERIC {
                return RType { ok: true, m: m, t: t };
            }
            if f == null {
                return RType { ok: false };
            }
            let ymod = y.module;
            let ydecl = y.as_data.decl;
            let mut found = false;
            for i in 0..unsafe f.ng {
                if unsafe f.pmod == ymod && unsafe f.params_g[i as usize] == ydecl {
                    m = unsafe f.am[i as usize];
                    t = unsafe f.at[i as usize];
                    found = true;
                    break;
                }
            }
            if !found {
                return RType { ok: false };
            }
        }
        return RType { ok: false };
    }

    fn ce_builtin_of(self: &Self, f: *mut CeFrame, m: ModuleId, t: TypeId) BuiltinType {
        let r = self.ce_rtype(f, m, t);
        if !r.ok {
            return BuiltinType::BT_COUNT;
        }
        return type_builtin(self.ast_ptr(r.m), r.t);
    }

    /// Pointer width of the TARGET, not the host: wasm32 addresses memory with 4 bytes, so every
    /// pointer, reference, function value and `usize`/`isize` is half the size it is elsewhere. The
    /// layout model feeds both compile-time `sizeof` and the emitted `_Static_assert`s, so a host-shaped
    /// answer here makes the generated C reject itself.
    const fn ptr_width(self: &Self) u64 {
        if self.pkg != null && unsafe self.pkg.arch == 2 {
            return 4; // wasm32
        }
        return 8;
    }

    fn ce_layout_f(self: &mut Self, f: *mut CeFrame, m: ModuleId, t: TypeId) Layout {
        if f == null {
            return self.layout_of(m, t, null, 0);
        }
        let mut envs: [LayoutEnv; 8] = [
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
            LayoutEnv { pmod: 0 },
        ];
        let mut parent: *const LayoutEnv = null;
        for i in 0..unsafe f.ng {
            unsafe envs[i as usize] = LayoutEnv {
                parent: parent,
                pmod: unsafe f.pmod,
                params: unsafe &f.params_g[i as usize],
                argm: unsafe f.am[i as usize],
                n: 1,
            };
            unsafe envs[i as usize].args[0] = unsafe f.at[i as usize];
            parent = &unsafe envs[i as usize];
        }
        return self.layout_of(m, t, parent, 0);
    }

    // Structural cross-pool type equality.
    fn ce_teq(self: &Self, ma: ModuleId, ta: TypeId, mb: ModuleId, tb: TypeId) bool {
        if ta == TYPE_NONE || tb == TYPE_NONE {
            return false;
        }
        let aa = self.ast_ptr(ma);
        let ab = self.ast_ptr(mb);
        let a = *aa.type_at(ta);
        let b = *ab.type_at(tb);
        if a.kind != b.kind {
            return false;
        }
        if a.kind == TypeKind::TYPE_BUILTIN {
            return a.as_data.builtin == b.as_data.builtin;
        }
        if a.kind == TypeKind::TYPE_CONST {
            return a.as_data.value == b.as_data.value;
        }
        if a.kind == TypeKind::TYPE_POINTER || a.kind == TypeKind::TYPE_REFERENCE {
            return a.qualifier == b.qualifier && self.ce_teq(ma, a.as_data.elem, mb, b.as_data.elem);
        }
        if a.kind == TypeKind::TYPE_ARRAY {
            return a.as_data.arr.len == b.as_data.arr.len && self.ce_teq(ma, a.as_data.arr.elem, mb, b.as_data.arr.elem);
        }
        if a.kind == TypeKind::TYPE_STRUCT || a.kind == TypeKind::TYPE_ENUM || a.kind == TypeKind::TYPE_GENERIC || a.kind == TypeKind::TYPE_OPAQUE {
            return a.module == b.module && a.as_data.decl == b.as_data.decl;
        }
        if a.kind == TypeKind::TYPE_INSTANCE {
            let ia = *aa.instance(a.as_data.inst);
            let ib = *ab.instance(b.as_data.inst);
            if ia.module != ib.module || ia.decl != ib.decl || ia.n != ib.n {
                return false;
            }
            for i in 0..ia.n {
                if !self.ce_teq(ma, unsafe ia.args[i as usize], mb, unsafe ib.args[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    fn ce_strip_refptr(self: &Self, f: *mut CeFrame, m0: ModuleId, t0: TypeId) RType {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..8 {
            let r = self.ce_rtype(f, m, t);
            if !r.ok {
                return RType { ok: false };
            }
            m = r.m;
            t = r.t;
            let y = self.ast_ptr(m).type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
                return RType { ok: true, m: m, t: t };
            }
            t = y.as_data.elem;
        }
        return RType { ok: false };
    }

    // Deep substitution through the frame, re-interning into m's pool. TYPE_NONE = an unbound generic.
    fn ce_subst_deep(self: &mut Self, f: *mut CeFrame, m: ModuleId, t: TypeId, depth: i32) TypeId {
        if t == TYPE_NONE || depth > CE_MAX_DEPTH {
            return TYPE_NONE;
        }
        let am = self.mut_ast_ptr(m);
        let y = *am.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            if f == null {
                return TYPE_NONE;
            }
            for i in 0..unsafe f.ng {
                if unsafe f.pmod == y.module && unsafe f.params_g[i as usize] == y.as_data.decl {
                    let fam = unsafe f.am[i as usize];
                    let fat = unsafe f.at[i as usize];
                    if fam == m {
                        return fat;
                    }
                    return am.reintern(unsafe &*self.ast_ptr(fam), fat);
                }
            }
            return TYPE_NONE;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.ce_subst_deep(f, m, y.as_data.elem, depth + 1);
            if e == TYPE_NONE {
                return TYPE_NONE;
            }
            if e == y.as_data.elem {
                return t;
            }
            let mut ny = y;
            if y.kind == TypeKind::TYPE_ARRAY {
                ny.as_data.arr = TyArr { elem: e, len: y.as_data.arr.len };
            } else {
                ny.as_data.elem = e;
            }
            return self.mut_ast_ptr(m).intern_type(ny);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *am.instance(y.as_data.inst);
            let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
            let mut changed = false;
            for i in 0..it.n {
                unsafe na[i as usize] = self.ce_subst_deep(f, m, unsafe it.args[i as usize], depth + 1);
                if unsafe na[i as usize] == TYPE_NONE {
                    return TYPE_NONE;
                }
                if unsafe na[i as usize] != unsafe it.args[i as usize] {
                    changed = true;
                }
            }
            if !changed {
                return t;
            }
            return self.mut_ast_ptr(m).intern_instance(it.module, it.decl, &na[0], it.n);
        }
        return t;
    }

    // While the parallel borrow-check stage keeps every pool frozen, interning is only safe into the
    // worker's own module: every other pool has its own worker appending to it. Bail deterministically
    // (callers treat it as an unevaluable type) and flag it; the driver redoes the module serially, so
    // the bail can never surface as a diagnostic.
    fn ce_recv_of(self: &mut Self, f: *mut CeFrame, m0: ModuleId, t0: TypeId) RecvRes {
        let mut out = ce_recv_zero();
        let r = self.ce_rtype(f, m0, t0);
        if !r.ok {
            return RecvRes { ok: false, r: out };
        }
        let m = r.m;
        let y = *self.ast_ptr(m).type_at(r.t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            out.dn = NODE_NONE;
            out.b = y.as_data.builtin;
            return RecvRes { ok: true, r: out };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            out.dm = y.module;
            out.dn = y.as_data.decl;
            return RecvRes { ok: true, r: out };
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_ptr(m).instance(y.as_data.inst);
            out.dm = it.module;
            out.dn = it.decl;
            out.n = it.n;
            for i in 0..it.n {
                unsafe out.am[i as usize] = m;
                unsafe out.at[i as usize] = self.ce_subst_deep(f, m, unsafe it.args[i as usize], 0);
                if unsafe out.at[i as usize] == TYPE_NONE || !unsafe self.ast_ptr(m).type_concrete(out.at[i as usize]) {
                    return RecvRes { ok: false, r: out };
                }
            }
            return RecvRes { ok: true, r: out };
        }
        return RecvRes { ok: false, r: out };
    }

    // ---- decl lookups ----

    fn ce_field_count(self: &Self, dm: ModuleId, dn: NodeId) u32 {
        let a = self.ast_ptr(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        let mut n: u32 = 0;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            if a.at_const(mid).kind == NodeKind::NODE_FIELD {
                n = n + 1;
            }
        }
        return n;
    }

    fn ce_field_index(self: &Self, dm: ModuleId, dn: NodeId, nm: ModuleId, name: tok::Span) FieldIdx {
        let a = self.ast_ptr(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        let mut idx: i32 = 0;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            if a.at_const(fid).kind == NodeKind::NODE_FIELD {
                let fname = self.name_text(dm, a.at_const(fid).as_data.field.name);
                if self.ce_spans_eq(dm, fname, nm, name) {
                    return FieldIdx { idx: idx, field: fid };
                }
                idx = idx + 1;
            }
        }
        return FieldIdx { idx: -1, field: NODE_NONE };
    }

    fn ce_enum_tagged(self: &Self, dm: ModuleId, dn: NodeId) bool {
        let a = self.ast_ptr(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            if a.at_const(mid).as_data.variant.payload.len > 0 {
                return true;
            }
        }
        return false;
    }

    fn ce_variant_pos(self: &Self, vm: ModuleId, vd: NodeId) VarPos {
        let a = self.ast_ptr(vm);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = a.at_const(iid).as_data.aggregate.members;
                for k in 0..ms.len {
                    let mid = unsafe a.list(ms)[k as usize];
                    if mid == vd {
                        return VarPos { pos: k as i32, enum_decl: iid };
                    }
                }
            }
        }
        return VarPos { pos: -1, enum_decl: NODE_NONE };
    }

    fn ce_variant_named(self: &Self, dm: ModuleId, dn: NodeId, lit: str) i32 {
        let a = self.ast_ptr(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            let vname = self.name_text(dm, a.at_const(mid).as_data.variant.name);
            if self.ce_span_is(dm, vname, lit) {
                return i as i32;
            }
        }
        return -1;
    }

    // The TypeId of nominal decl (dm,dn) in its OWN pool; TYPE_NONE if absent.
    fn ce_pool_find_type(self: &Self, dm: ModuleId, dn: NodeId) TypeId {
        let a = self.ast_ptr(dm);
        let mut t: TypeId = 1;
        while t as usize < unsafe a.type_pool.len() {
            let y = a.type_at(t);
            if (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM) && y.module == dm && y.as_data.decl == dn {
                return t;
            }
            t = t + 1;
        }
        return TYPE_NONE;
    }

    // Item containing method (fm,fn): 0 = free fn, 1 = extnode, 2 = interface. out = the item node.
    fn ce_container_of(self: &Self, fm: ModuleId, fnode: NodeId, out: *mut NodeId) i32 {
        let a = self.ast_ptr(fm);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            let ik = a.at_const(iid).kind;
            let mut ms = NodeList { start: 0, len: 0 };
            let mut is_ext = false;
            if ik == NodeKind::NODE_EXTEND {
                ms = a.at_const(iid).as_data.extend_def.items;
                is_ext = true;
            } else if ik == NodeKind::NODE_INTERFACE {
                ms = a.at_const(iid).as_data.interface_def.items;
            } else {
                continue;
            }
            for k in 0..ms.len {
                let mid = unsafe a.list(ms)[k as usize];
                if mid == fnode {
                    if out != null {
                        unsafe *out = iid;
                    }
                    if is_ext {
                        return 1;
                    }
                    return 2;
                }
            }
        }
        return 0;
    }

    // Find method name/lit on receiver r: scan extends in the decl's module, then scope, then (builtins) all.
    fn ce_find_method(
        self: &Self,
        r: CeRecv,
        scope: ModuleId,
        nm: ModuleId,
        name: tok::Span,
        lit: str,
        extend_out: *mut NodeId,
    ) DefId {
        let mut first = scope;
        if r.dn != NODE_NONE {
            first = r.dm;
        }
        for s in 0..self.nmods + 2 {
            let mut mm: ModuleId = 0;
            if s == 0 {
                mm = first;
            } else if s == 1 {
                mm = scope;
            } else if r.dn == NODE_NONE {
                mm = (s - 2) as ModuleId;
            } else {
                break;
            }
            if s == 1 && mm == first {
                continue;
            }
            if !self.has_ast(mm) {
                continue;
            }
            let a = self.ast_ptr(mm);
            if unsafe a.nodes.len() == 0 {
                continue;
            }
            let items = unsafe a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe a.list(items)[i as usize];
                let target = a.at_const(iid).as_data.extend_def.target_type;
                if a.at_const(iid).kind == NodeKind::NODE_EXTEND && target != NODE_NONE {
                    let mut match_recv = false;
                    if r.dn != NODE_NONE {
                        let tg = a.resolution_def(target);
                        match_recv = tg.module == r.dm && tg.node == r.dn;
                    } else {
                        let tt = self.ce_type(mm, target);
                        if tt != TYPE_NONE {
                            let ty = self.ast_ptr(mm).type_at(tt);
                            match_recv = ty.kind == TypeKind::TYPE_BUILTIN && ty.as_data.builtin == r.b;
                        }
                    }
                    if match_recv {
                        let ms = a.at_const(iid).as_data.extend_def.items;
                        for k in 0..ms.len {
                            let mid = unsafe a.list(ms)[k as usize];
                            if a.at_const(mid).kind == NodeKind::NODE_FUNCTION {
                                let mname = self.name_text(mm, a.at_const(mid).as_data.function.name);
                                let mut hit = false;
                                if lit.len() != 0 {
                                    hit = self.ce_span_is(mm, mname, lit);
                                } else {
                                    hit = self.ce_spans_eq(mm, mname, nm, name);
                                }
                                if hit {
                                    if extend_out != null {
                                        unsafe *extend_out = iid;
                                    }
                                    return DefId { module: mm, node: mid };
                                }
                            }
                        }
                    }
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // Does aggregate (dm,dn) conform to Free through a NON-prelude extnode? (Cached.)
    fn ce_user_free(self: &mut Self, dm: ModuleId, dn: NodeId) bool {
        for i in 0..self.ufree.len() {
            let u = self.ufree.at(i);
            if u.m == dm && u.n == dn {
                return u.user;
            }
        }
        let mut user = false;
        let mut mm: usize = 0;
        while mm < self.nmods && !user {
            if !self.is_prelude(mm as ModuleId) && self.has_ast(mm as ModuleId) {
                let a = self.ast_ptr(mm as ModuleId);
                if unsafe a.nodes.len() != 0 {
                    let items = unsafe a.at_const(a.root).as_data.program.items;
                    let mut ii: u32 = 0;
                    while ii < items.len && !user {
                        let iid = unsafe a.list(items)[ii as usize];
                        let target = a.at_const(iid).as_data.extend_def.target_type;
                        if a.at_const(iid).kind == NodeKind::NODE_EXTEND && target != NODE_NONE {
                            let tg = a.resolution_def(target);
                            if tg.module == dm && tg.node == dn {
                                let ms = a.at_const(iid).as_data.extend_def.items;
                                for k in 0..ms.len {
                                    let mid = unsafe a.list(ms)[k as usize];
                                    if a.at_const(mid).kind == NodeKind::NODE_FUNCTION {
                                        let mname = self.name_text(
                                            mm as ModuleId,
                                            a.at_const(mid).as_data.function.name,
                                        );
                                        if self.ce_span_is(mm as ModuleId, mname, "free") {
                                            user = true;
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        ii = ii + 1;
                    }
                }
            }
            mm = mm + 1;
        }
        self.ufree.push(UFree { m: dm, n: dn, user: user });
        return user;
    }

    // The discriminant of payload-less enum variant (vm,vd): explicit `= <int>` else previous+1.
    fn variant_value(self: &mut Self, vm: ModuleId, vd: NodeId) ConstValue {
        let a = self.ast_ptr(vm);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = a.at_const(iid).as_data.aggregate.members;
                let mut next: i64 = 0;
                for k in 0..ms.len {
                    let mid = unsafe a.list(ms)[k as usize];
                    if a.at_const(mid).as_data.variant.payload.len > 0 {
                        return ce_none();
                    }
                    let vval = a.at_const(mid).as_data.variant.value;
                    if vval != NODE_NONE {
                        let e = self.eval(vm, vval);
                        if e.kind != CONST_INT {
                            return ce_none();
                        }
                        next = e.as_data.i;
                    }
                    if mid == vd {
                        return ConstValue { kind: CONST_INT, ty: TYPE_NONE, as_data: ConstValueAs { i: next } };
                    }
                    next = next + 1;
                }
            }
        }
        return ce_none();
    }

    // ---- object store ----
    const fn ce_objs_reset(self: &mut Self) {
        self.objs_live = 0;
        self.live_slots = 0;
    }

    // Object ids are 1-based; 0 is the abstract null pointer, and ids past objs_live are stale.
    const fn obj_ptr(self: &Self, id: u32) *mut CeObj {
        if id == 0 || id as usize > self.objs_live {
            return null;
        }
        return unsafe (self.objs.as_ptr() as *mut CeObj + (id - 1) as usize);
    }

    fn ce_obj_new(self: &mut Self, len: u32) u32 {
        if self.objs_live as u32 >= CE_MAX_OBJS || self.live_slots + len as u64 > self.max_slots {
            self.ce_trap(CE_TRAP_BUDGET_MEMORY, "const-eval memory budget exceeded");
            return 0;
        }
        if self.objs_live < self.objs.len() {
            // reuse a retained object: refit its slot vector, zero the metadata push{} would zero
            let o = unsafe (self.objs.as_ptr() as *mut CeObj + self.objs_live);
            unsafe o.slots.clear();
            if len != 0 {
                unsafe o.slots.reserve(len as usize);
                for _ in 0..len {
                    unsafe o.slots.push(cv_nil());
                }
            }
            unsafe o.dead = 0;
            unsafe o.is_enum = 0;
            unsafe o.heap = 0;
            unsafe o.uactive = -1;
            unsafe o.dm = 0;
            unsafe o.dn = NODE_NONE;
            unsafe o.nargs = 0;
            unsafe o.bytes = 0;
            unsafe o.em = 0;
            unsafe o.et = TYPE_NONE;
            unsafe o.esz = 0;
        } else {
            let mut slots = Vector::<CeVal>::new();
            if len != 0 {
                slots.reserve(len as usize);
                for _ in 0..len {
                    slots.push(cv_nil());
                }
            }
            self.objs.push(CeObj { slots: slots, uactive: -1 });
        }
        self.objs_live = self.objs_live + 1;
        self.live_slots = self.live_slots + len as u64;
        return self.objs_live as u32;
    }

    fn ce_obj_resize(self: &mut Self, id: u32, len: u32) bool {
        let cur = (unsafe self.obj_ptr(id).slots.len()) as u32;
        if len > cur && self.live_slots + (len - cur) as u64 > self.max_slots {
            self.ce_trap(CE_TRAP_BUDGET_MEMORY, "const-eval memory budget exceeded");
            return false;
        }
        let o = self.obj_ptr(id);
        if len > cur {
            let mut i = cur;
            while i < len {
                unsafe o.slots.push(cv_nil());
                i = i + 1;
            }
            self.live_slots = self.live_slots + (len - cur) as u64;
        } else if len < cur {
            unsafe o.slots.truncate(len as usize);
        }
        return true;
    }

    // ---- frames and values ----
    fn ce_bind_slot(self: &mut Self, f: *mut CeFrame, decl: NodeId) *mut CeVal {
        let i = ce_local_find(f, decl);
        let envid = unsafe f.env;
        if self.obj_ptr(envid) == null {
            return null;
        }
        if i >= 0 {
            let slotidx = unsafe f.locals[i as usize].slot;
            let o = self.obj_ptr(envid);
            return unsafe (o.slots.as_ptr() as *mut CeVal + slotidx as usize);
        }
        if unsafe f.n >= CE_MAX_LOCALS {
            return null;
        }
        let curlen = (unsafe self.obj_ptr(envid).slots.len()) as u32;
        if !self.ce_obj_resize(envid, curlen + 1) {
            return null;
        }
        let n = unsafe f.n;
        unsafe f.locals[n as usize].decl = decl;
        unsafe f.locals[n as usize].slot = curlen;
        unsafe f.n = n + 1;
        let o = self.obj_ptr(envid);
        return unsafe (o.slots.as_ptr() as *mut CeVal + curlen as usize);
    }

    fn ce_bind(self: &mut Self, f: *mut CeFrame, decl: NodeId, v: CeVal) bool {
        let s = self.ce_bind_slot(f, decl);
        if s == null {
            return false;
        }
        let cv = self.ce_clone(v, 0);
        unsafe *s = cv;
        return v.kind == CV_NIL_K || unsafe s.kind != CV_NIL_K;
    }

    // Deep copy: aggregates get fresh objects (pointer members stay shared); scalars copy by value.
    fn ce_clone(self: &mut Self, v: CeVal, depth: i32) CeVal {
        if v.kind != CV_AGG || depth > CE_MAX_DEPTH {
            if v.kind == CV_AGG && depth > CE_MAX_DEPTH {
                return cv_nil();
            }
            return v;
        }
        let srcp = self.obj_ptr(v.as_data.p.obj);
        if srcp == null || unsafe srcp.dead != 0 {
            return cv_nil();
        }
        let srclen = (unsafe srcp.slots.len()) as u32;
        let id = self.ce_obj_new(srclen);
        if id == 0 {
            return cv_nil();
        }
        let src = self.obj_ptr(v.as_data.p.obj);
        let dst = self.obj_ptr(id);
        unsafe {
            dst.dead = src.dead;
            dst.is_enum = src.is_enum;
            dst.uactive = src.uactive; // a copied union still holds the member it was written through
            dst.heap = src.heap;
            dst.dm = src.dm;
            dst.dn = src.dn;
            dst.nargs = src.nargs;
            dst.bytes = src.bytes;
            dst.em = src.em;
            dst.et = src.et;
            dst.esz = src.esz;
            for j in 0..4 {
                dst.am[j] = src.am[j];
                dst.at[j] = src.at[j];
            }
        }
        for i in 0..srclen {
            let sv = unsafe self.obj_ptr(v.as_data.p.obj).slots[i as usize];
            let cloned = self.ce_clone(sv, depth + 1);
            if sv.kind != CV_NIL_K && cloned.kind == CV_NIL_K {
                return cv_nil();
            }
            unsafe self.obj_ptr(id).slots.set(i as usize, cloned);
        }
        let mut out = v;
        out.as_data.p.obj = id;
        return out;
    }

    fn ce_loadp(self: &mut Self, p: CeVal) ValRes {
        if p.kind != CV_PTR {
            return ValRes { ok: false };
        }
        if p.as_data.p.obj == 0 {
            self.ce_trap(CE_TRAP_UB_NULL_DEREF, "null dereference");
            return ValRes { ok: false };
        }
        let o = self.obj_ptr(p.as_data.p.obj);
        if o == null {
            return ValRes { ok: false };
        }
        if unsafe o.dead != 0 {
            self.ce_trap(CE_TRAP_UB_USE_AFTER_FREE, "use after free");
            return ValRes { ok: false };
        }
        if p.as_data.p.off as usize >= unsafe o.slots.len() {
            self.ce_trap(CE_TRAP_UB_OOB, "out-of-bounds access");
            return ValRes { ok: false };
        }
        let out = unsafe o.slots[p.as_data.p.off as usize];
        return ValRes { ok: out.kind != CV_NIL_K, v: out };
    }

    fn ce_storep(self: &mut Self, p: CeVal, v: CeVal) bool {
        if p.kind != CV_PTR || v.kind == CV_NIL_K {
            return false;
        }
        if p.as_data.p.obj == 0 {
            self.ce_trap(CE_TRAP_UB_NULL_DEREF, "null dereference");
            return false;
        }
        let cv = self.ce_clone(v, 0);
        if cv.kind == CV_NIL_K {
            return false;
        }
        let o = self.obj_ptr(p.as_data.p.obj);
        if o == null {
            return false;
        }
        if unsafe o.dead != 0 {
            self.ce_trap(CE_TRAP_UB_USE_AFTER_FREE, "use after free");
            return false;
        }
        if p.as_data.p.off as usize >= unsafe o.slots.len() {
            self.ce_trap(CE_TRAP_UB_OOB, "out-of-bounds access");
            return false;
        }
        unsafe o.slots.set(p.as_data.p.off as usize, cv);
        return true;
    }

    fn ce_temp_place(self: &mut Self, v: CeVal) ValRes {
        let id = self.ce_obj_new(1);
        if id == 0 || v.kind == CV_NIL_K {
            return ValRes { ok: false };
        }
        unsafe self.obj_ptr(id).slots.set(0, v);
        return ValRes {
            ok: true,
            v: CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: id, off: 0 } } },
        };
    }

    fn ce_zero(self: &mut Self, m: ModuleId, t: TypeId, depth: i32) CeVal {
        if depth > CE_MAX_DEPTH || t == TYPE_NONE {
            return cv_nil();
        }
        let y = *self.ast_ptr(m).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL {
                return CeVal { kind: CV_BOOL, tm: m, ty: t, as_data: CeValAs { i: 0 } };
            }
            if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 {
                return CeVal { kind: CV_FLOAT, tm: m, ty: t, as_data: CeValAs { f: 0.0 } };
            }
            if b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64 || b == BuiltinType::BT_VALIST || b == BuiltinType::BT_VOID {
                return cv_nil();
            }
            return CeVal { kind: CV_INT, tm: m, ty: t, as_data: CeValAs { i: 0 } };
        }
        if y.kind == TypeKind::TYPE_POINTER {
            return CeVal { kind: CV_PTR, tm: m, ty: t, as_data: CeValAs { p: CvPtr { obj: 0, off: 0 } } };
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len == 0 {
                return cv_nil();
            }
            let id = self.ce_obj_new(y.as_data.arr.len);
            if id == 0 {
                return cv_nil();
            }
            let ez = self.ce_zero(m, y.as_data.arr.elem, depth + 1);
            if ez.kind == CV_NIL_K {
                return cv_nil();
            }
            let alen = (unsafe self.obj_ptr(id).slots.len()) as u32;
            for i in 0..alen {
                let cloned = self.ce_clone(ez, depth + 1);
                unsafe self.obj_ptr(id).slots.set(i as usize, cloned);
            }
            return CeVal { kind: CV_AGG, tm: m, ty: t, as_data: CeValAs { p: CvPtr { obj: id, off: 0 } } };
        }
        return cv_nil();
    }

    // ---- scalar ops ----
    fn ce_int_op(
        self: &mut Self,
        op: TokenType,
        l: CeVal,
        r: CeVal,
        tm: ModuleId,
        rt: TypeId,
        b: BuiltinType,
        ob: BuiltinType,
    ) CeVal {
        let uns = ob != BuiltinType::BT_COUNT && bt_unsigned(ob);
        if op == TokenType::EqualEqual {
            return cv_bool(tm, rt, l.as_data.i == r.as_data.i);
        }
        if op == TokenType::BangEqual {
            return cv_bool(tm, rt, l.as_data.i != r.as_data.i);
        }
        if op == TokenType::LessThan {
            return cv_bool(tm, rt, if_bool(uns, l.as_data.i as u64 < r.as_data.i as u64, l.as_data.i < r.as_data.i));
        }
        if op == TokenType::LessThanEqual {
            return cv_bool(tm, rt, if_bool(uns, l.as_data.i as u64 <= r.as_data.i as u64, l.as_data.i <= r.as_data.i));
        }
        if op == TokenType::GreaterThan {
            return cv_bool(tm, rt, if_bool(uns, l.as_data.i as u64 > r.as_data.i as u64, l.as_data.i > r.as_data.i));
        }
        if op == TokenType::GreaterThanEqual {
            return cv_bool(tm, rt, if_bool(uns, l.as_data.i as u64 >= r.as_data.i as u64, l.as_data.i >= r.as_data.i));
        }
        let mut bits = 64;
        if ob != BuiltinType::BT_COUNT {
            bits = bt_bits(ob);
        }
        let mut v: i64 = 0;
        if uns {
            let ul = l.as_data.i as u64;
            let ur = r.as_data.i as u64;
            let mut u: u64 = 0;
            switch op {
                Plus => {
                    u = ul + ur;
                },
                Minus => {
                    u = ul - ur;
                },
                Star => {
                    u = ul * ur;
                },
                Slash => {
                    if ur == 0 {
                        self.ce_trap(CE_TRAP_UB_DIV_ZERO, "division by zero");
                        return cv_nil();
                    }
                    u = ul / ur;
                },
                Percent => {
                    if ur == 0 {
                        self.ce_trap(CE_TRAP_UB_DIV_ZERO, "division by zero");
                        return cv_nil();
                    }
                    u = ul % ur;
                },
                Ampersand => {
                    u = ul & ur;
                },
                Pipe => {
                    u = ul | ur;
                },
                Caret => {
                    u = ul ^ ur;
                },
                LeftShift => {
                    if r.as_data.i < 0 || r.as_data.i >= bits as i64 {
                        self.ce_trap(CE_TRAP_UB_SHIFT, "shift out of range");
                        return cv_nil();
                    }
                    u = ul << r.as_data.i as u64;
                },
                RightShift => {
                    if r.as_data.i < 0 || r.as_data.i >= bits as i64 {
                        self.ce_trap(CE_TRAP_UB_SHIFT, "shift out of range");
                        return cv_nil();
                    }
                    u = ul >> r.as_data.i as u64;
                },
                _ => {
                    return cv_nil();
                },
            };
            v = wrap_to(ob, u as i64);
            return CeVal { kind: CV_INT, tm: tm, ty: rt, as_data: CeValAs { i: v } };
        }
        let li = l.as_data.i;
        let ri = r.as_data.i;
        let mut type_min = I64_MIN;
        if bits != 64 {
            type_min = (-(1u64 << (bits - 1) as u64)) as i64;
        }
        switch op {
            Plus => {
                let o = add_ovf(li, ri);
                if o.ovf {
                    self.ce_trap(CE_TRAP_UB_OVERFLOW, "arithmetic overflow");
                    return cv_nil();
                }
                v = o.v;
            },
            Minus => {
                let o = sub_ovf(li, ri);
                if o.ovf {
                    self.ce_trap(CE_TRAP_UB_OVERFLOW, "arithmetic overflow");
                    return cv_nil();
                }
                v = o.v;
            },
            Star => {
                let o = mul_ovf(li, ri);
                if o.ovf {
                    self.ce_trap(CE_TRAP_UB_OVERFLOW, "arithmetic overflow");
                    return cv_nil();
                }
                v = o.v;
            },
            Slash => {
                if ri == 0 {
                    self.ce_trap(CE_TRAP_UB_DIV_ZERO, "division by zero");
                    return cv_nil();
                }
                if ri == -1 && li == type_min {
                    self.ce_trap(CE_TRAP_UB_OVERFLOW, "arithmetic overflow");
                    return cv_nil();
                }
                v = li / ri;
            },
            Percent => {
                if ri == 0 {
                    self.ce_trap(CE_TRAP_UB_DIV_ZERO, "division by zero");
                    return cv_nil();
                }
                if ri == -1 && li == type_min {
                    self.ce_trap(CE_TRAP_UB_OVERFLOW, "arithmetic overflow");
                    return cv_nil();
                }
                v = li % ri;
            },
            Ampersand => {
                v = li & ri;
            },
            Pipe => {
                v = li | ri;
            },
            Caret => {
                v = li ^ ri;
            },
            LeftShift => {
                if ri < 0 || ri >= bits as i64 {
                    self.ce_trap(CE_TRAP_UB_SHIFT, "shift out of range");
                    return cv_nil();
                }
                v = wrap_to(ob, (li as u64 << ri as u64) as i64);
            },
            RightShift => {
                if ri < 0 || ri >= bits as i64 {
                    self.ce_trap(CE_TRAP_UB_SHIFT, "shift out of range");
                    return cv_nil();
                }
                v = li >> ri;
            },
            _ => {
                return cv_nil();
            },
        };
        if b != BuiltinType::BT_COUNT && !fits(b, v) {
            if bt_signed(b) {
                self.ce_trap(CE_TRAP_UB_OVERFLOW, "arithmetic overflow");
            }
            return cv_nil();
        }
        return CeVal { kind: CV_INT, tm: tm, ty: rt, as_data: CeValAs { i: v } };
    }

    fn eval_str_literal(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = a.at_const(id).as_data.literal.raw;
        let raw = a.at_const(id).as_data.literal.token_type == TokenType::RawStringLiteral;
        let mut i = sp.start;
        let mut hashes: u32 = 0;
        while i < sp.end && src[i as usize] != b'"' {
            if src[i as usize] == b'#' {
                hashes = hashes + 1;
            }
            i = i + 1;
        }
        if i >= sp.end {
            return cv_nil();
        }
        i = i + 1;
        let mut endpos = sp.end - 1;
        if raw {
            endpos = endpos - hashes;
        }
        let mut bytes = Buf4096 {};
        let mut nb: u32 = 0;
        while i < endpos {
            if nb >= 4096 {
                return cv_nil();
            }
            let mut c = src[i as usize];
            i = i + 1;
            if !raw && c == b'\\' && i < endpos {
                let e = src[i as usize];
                i = i + 1;
                switch e {
                    'n' => {
                        c = 10u8;
                    },
                    't' => {
                        c = 9u8;
                    },
                    'r' => {
                        c = 13u8;
                    },
                    '0' => {
                        c = 0u8;
                    },
                    '\\' => {
                        c = 92u8;
                    },
                    '"' => {
                        c = 34u8;
                    },
                    '\'' => {
                        c = 39u8;
                    },
                    _ => {
                        return cv_nil();
                    },
                };
            }
            bytes[nb as usize] = c;
            nb = nb + 1;
        }
        let rr = self.ce_recv_of(f, m, self.ce_type(m, id));
        if !rr.ok || rr.r.dn == NODE_NONE {
            return cv_nil();
        }
        let block = self.ce_obj_new(nb);
        if block == 0 && nb != 0 {
            return cv_nil();
        }
        if nb != 0 {
            let bo = self.obj_ptr(block);
            unsafe bo.heap = 1;
            unsafe bo.bytes = nb;
            unsafe bo.em = 0;
            unsafe bo.et = Ast::builtin(BuiltinType::BT_U8);
            unsafe bo.esz = 1;
            for k in 0..nb {
                unsafe self.obj_ptr(block).slots.set(
                    k as usize,
                    CeVal {
                        kind: CV_INT,
                        tm: 0,
                        ty: Ast::builtin(BuiltinType::BT_U8),
                        as_data: CeValAs { i: bytes[k as usize] },
                    },
                );
            }
        }
        let so = self.ce_obj_new(self.ce_field_count(rr.r.dm, rr.r.dn));
        if so == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(so).dm = rr.r.dm;
        unsafe self.obj_ptr(so).dn = rr.r.dn;
        // locate ptr/len fields by name
        let da = self.ast_ptr(rr.r.dm);
        let dms = da.at_const(rr.r.dn).as_data.aggregate.members;
        let mut ptr_i: i32 = -1;
        let mut len_i: i32 = -1;
        let mut idx: i32 = 0;
        for kk in 0..dms.len {
            let fid = unsafe da.list(dms)[kk as usize];
            if da.at_const(fid).kind == NodeKind::NODE_FIELD {
                let fn2 = self.name_text(rr.r.dm, da.at_const(fid).as_data.field.name);
                if self.ce_span_is(rr.r.dm, fn2, "ptr") {
                    ptr_i = idx;
                } else if self.ce_span_is(rr.r.dm, fn2, "len") {
                    len_i = idx;
                }
                idx = idx + 1;
            }
        }
        if ptr_i < 0 || len_i < 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(so).slots.set(
            ptr_i as usize,
            CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: block, off: 0 } } },
        );
        unsafe self.obj_ptr(so).slots.set(
            len_i as usize,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: nb } },
        );
        return CeVal { kind: CV_AGG, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
    }

    // Index of the NODE_FIELD named `name` among the decl's fields, -1 when absent.
    fn ce_ti_findf(self: &Self, dm: ModuleId, dn: NodeId, name: str) i32 {
        let da = self.ast_ptr(dm);
        let ms = da.at_const(dn).as_data.aggregate.members;
        let mut idx: i32 = 0;
        for i in 0..ms.len {
            let fid = unsafe da.list(ms)[i as usize];
            if da.at_const(fid).kind == NodeKind::NODE_FIELD {
                if self.ce_span_is(dm, self.name_text(dm, da.at_const(fid).as_data.field.name), name) {
                    return idx;
                }
                idx = idx + 1;
            }
        }
        return -1;
    }

    // A `str` value as a CeVal: a heap byte block plus the two-field view struct, exactly the shape
    // eval_str_literal builds. (sm, sn) is the prelude `str` decl; (stym, sty) its type.
    fn ce_ti_str(self: &mut Self, sm: ModuleId, sn: NodeId, stym: ModuleId, sty: TypeId, bytes: str) CeVal {
        let nb = bytes.len() as u32;
        let mut block: u32 = 0;
        if nb != 0 {
            block = self.ce_obj_new(nb);
            if block == 0 {
                return cv_nil();
            }
            let bo = self.obj_ptr(block);
            unsafe bo.heap = 1;
            unsafe bo.bytes = nb;
            unsafe bo.em = 0;
            unsafe bo.et = Ast::builtin(BuiltinType::BT_U8);
            unsafe bo.esz = 1;
            for k in 0..nb {
                unsafe self.obj_ptr(block).slots.set(
                    k as usize,
                    CeVal {
                        kind: CV_INT,
                        tm: 0,
                        ty: Ast::builtin(BuiltinType::BT_U8),
                        as_data: CeValAs { i: bytes[k as usize] },
                    },
                );
            }
        }
        let ptr_i = self.ce_ti_findf(sm, sn, "ptr");
        let len_i = self.ce_ti_findf(sm, sn, "len");
        if ptr_i < 0 || len_i < 0 {
            return cv_nil();
        }
        let so = self.ce_obj_new(self.ce_field_count(sm, sn));
        if so == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(so).dm = sm;
        unsafe self.obj_ptr(so).dn = sn;
        unsafe self.obj_ptr(so).slots.set(
            ptr_i as usize,
            CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: block, off: 0 } } },
        );
        unsafe self.obj_ptr(so).slots.set(
            len_i as usize,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: nb } },
        );
        return CeVal { kind: CV_AGG, tm: stym, ty: sty, as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
    }

    // The TypeTag variant index for (tm, tt); -1 when the type has no tag (unreachable kinds).
    // Variant order is pinned by std/core.spc's TypeTag declaration.
    fn ce_ti_tag(self: &mut Self, tm: ModuleId, tt: TypeId, strm: ModuleId, strn: NodeId, slm: ModuleId, sln: NodeId) i64 {
        let y = *self.ast_ptr(tm).type_at(tt);
        if y.kind == TypeKind::TYPE_BUILTIN {
            switch y.as_data.builtin {
                BT_VOID => {
                    return 0;
                },
                BT_BOOL => {
                    return 1;
                },
                BT_CHAR | BT_I8 | BT_I16 | BT_I32 | BT_I64 | BT_ISIZE => {
                    return 2;
                },
                BT_U8 | BT_U16 | BT_U32 | BT_U64 | BT_USIZE => {
                    return 3;
                },
                BT_F32 | BT_F64 => {
                    return 4;
                },
                BT_C32 | BT_C64 => {
                    return 5;
                },
                BT_VALIST => {
                    return 17;
                },
                _ => {
                    return -1;
                },
            };
        }
        if y.kind == TypeKind::TYPE_POINTER {
            return 6;
        }
        if y.kind == TypeKind::TYPE_REFERENCE {
            return 7;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            return 8;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return 9;
        }
        if y.kind == TypeKind::TYPE_DYN {
            return 16;
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            return 17;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_INSTANCE {
            let mut dm = y.module;
            let mut dn = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.ast_ptr(tm).instance(y.as_data.inst);
                dm = it.module;
                dn = it.decl;
                if dm == slm && dn == sln {
                    return 10;
                }
                // SliceMut lives beside Slice; matching the decl's own name keeps the compare exact.
                if dm == slm && self.ce_span_is(
                    dm,
                    self.name_text(dm, self.ast_ptr(dm).at_const(dn).as_data.aggregate.name),
                    "SliceMut",
                ) {
                    return 10;
                }
                // `(A, B)` lowered to the prelude Tuple2..4 before this ever ran: report it as the
                // tuple it was written as, not as the struct it lowered to.
                let tnm = self.name_text(dm, self.ast_ptr(dm).at_const(dn).as_data.aggregate.name);
                if self.ce_span_is(dm, tnm, "Tuple2") || self.ce_span_is(dm, tnm, "Tuple3") || self.ce_span_is(
                    dm,
                    tnm,
                    "Tuple4",
                ) {
                    return 12;
                }
            }
            if dm == strm && dn == strn {
                return 11;
            }
            if !self.has_ast(dm) {
                return -1;
            }
            let d = self.ast_ptr(dm).at_const(dn);
            if d.kind == NodeKind::NODE_ENUM {
                return 15;
            }
            if d.kind != NodeKind::NODE_STRUCT {
                return -1;
            }
            if d.as_data.aggregate.is_union {
                return 14;
            }
            if d.as_data.aggregate.is_tuple {
                return 12;
            }
            return 13;
        }
        return -1;
    }

    // Resolve (m0, t0) through a LayoutEnv chain while it names a generic param -- the env-frame
    // sibling of ce_rtype, for field types inside a generic instance's decl.
    fn ce_ti_env_ty(self: &Self, m0: ModuleId, t0: TypeId, env: *const LayoutEnv) RType {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..8 {
            if t == TYPE_NONE {
                return RType { ok: false };
            }
            let y = self.ast_ptr(m).type_at(t);
            if y.kind != TypeKind::TYPE_GENERIC {
                return RType { ok: true, m: m, t: t };
            }
            let ymod = y.module;
            let ydecl = y.as_data.decl;
            let mut e = env;
            let mut found = false;
            while e != null && !found {
                for i in 0..unsafe e.n {
                    if unsafe e.pmod == ymod && unsafe e.params[i as usize] == ydecl {
                        m = unsafe e.argm;
                        t = unsafe e.args[i as usize];
                        found = true;
                        break;
                    }
                }
                e = unsafe e.parent;
            }
            if !found {
                return RType { ok: false };
            }
        }
        return RType { ok: false };
    }

    // `type_info::<T>()`: build the TypeInfo object graph for the recorded type argument. Every decl
    // the graph needs (TypeInfo, str, TypeTag, Slice, FieldInfo, VariantInfo) is derived from the
    // call's own result type, so no name lookup and no package access is involved.
    fn ce_type_info(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Rets {
        let out = Rets { ok: false, n: 0 };
        let mu = self.ast_ptr(m).type_args(id);
        if mu == null || unsafe mu.n == 0 {
            return out;
        }
        let rt = self.ce_rtype(f, m, unsafe mu.args[0]);
        if !rt.ok {
            return out;
        }
        return self.ce_type_info_of(f, m, id, rt.m, rt.t);
    }

    // The graph build behind ce_type_info, with T given explicitly: codegen calls this per emitted
    // call site, where the generic substitution lives in ITS frames, not in a CeFrame.
    fn ce_type_info_of(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId, tm: ModuleId, tt: TypeId) Rets {
        let out = Rets { ok: false, n: 0 };
        let rty = self.ce_type(m, id);
        let rr = self.ce_recv_of(f, m, rty);
        if !rr.ok || rr.r.dn == NODE_NONE {
            return out;
        }
        let tim = rr.r.dm;
        let tin = rr.r.dn;
        // The six TypeInfo fields, by name; their decl types name every other decl the graph uses.
        let da = self.ast_ptr(tim);
        let mut sty = TYPE_NONE; // str
        let mut kty = TYPE_NONE; // TypeTag
        let mut flty = TYPE_NONE; // Slice<FieldInfo>
        let mut vrty = TYPE_NONE; // Slice<VariantInfo>
        let ms = da.at_const(tin).as_data.aggregate.members;
        for i in 0..ms.len {
            let fid = unsafe da.list(ms)[i as usize];
            if da.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let fnm = self.name_text(tim, da.at_const(fid).as_data.field.name);
            let fty = self.ce_type(tim, da.at_const(fid).as_data.field.ty);
            if self.ce_span_is(tim, fnm, "name") {
                sty = fty;
            } else if self.ce_span_is(tim, fnm, "kind") {
                kty = fty;
            } else if self.ce_span_is(tim, fnm, "fields") {
                flty = fty;
            } else if self.ce_span_is(tim, fnm, "variants") {
                vrty = fty;
            }
        }
        if sty == TYPE_NONE || kty == TYPE_NONE || flty == TYPE_NONE || vrty == TYPE_NONE {
            return out;
        }
        let ys = *da.type_at(sty);
        if ys.kind != TypeKind::TYPE_STRUCT {
            return out;
        }
        let strm = ys.module;
        let strn = ys.as_data.decl;
        let yf = *da.type_at(flty);
        let yv = *da.type_at(vrty);
        if yf.kind != TypeKind::TYPE_INSTANCE || yv.kind != TypeKind::TYPE_INSTANCE {
            return out;
        }
        let fit = *da.instance(yf.as_data.inst);
        let vit = *da.instance(yv.as_data.inst);
        let slm = fit.module;
        let sln = fit.decl;
        let fity = fit.args[0]; // FieldInfo, in tim's pool
        let vity = vit.args[0]; // VariantInfo, in tim's pool
        let tag = self.ce_ti_tag(tm, tt, strm, strn, slm, sln);
        if tag < 0 {
            return out;
        }
        // Size and align; void is the one kind with no C layout.
        let mut size: u64 = 0;
        let mut align: u64 = 1;
        if tag != 0 {
            let lay = self.ce_layout_f(f, tm, tt);
            if !lay.ok {
                return out;
            }
            size = lay.size;
            align = lay.align;
        }
        // Name: builtin spelling, or the decl's declared name; anonymous kinds stay "".
        let y = *self.ast_ptr(tm).type_at(tt);
        let mut nm = "";
        if y.kind == TypeKind::TYPE_BUILTIN {
            nm = builtin_name(y.as_data.builtin);
        } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_INSTANCE {
            let mut dm = y.module;
            let mut dn = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.ast_ptr(tm).instance(y.as_data.inst);
                dm = it.module;
                dn = it.decl;
            }
            if self.has_ast(dm) {
                let sp = self.name_text(dm, self.ast_ptr(dm).at_const(dn).as_data.aggregate.name);
                let src = self.ce_src(dm);
                nm = src.slice(sp.start as usize, sp.end as usize);
            }
        }
        // Fields (struct/tuple/union) and variants (enum).
        let mut nfields: u32 = 0;
        let mut fblock: u32 = 0;
        let mut nvars: u32 = 0;
        let mut vblock: u32 = 0;
        self.ti_nfields = 0;
        self.ti_nvars = 0;
        if tag == 12 || tag == 13 || tag == 14 {
            let mut dm2 = y.module;
            let mut dn2 = y.as_data.decl;
            let mut envp: *const LayoutEnv = null;
            let mut frame = LayoutEnv { parent: null, pmod: 0, params: null, argm: tm, n: 0 };
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.ast_ptr(tm).instance(y.as_data.inst);
                dm2 = it.module;
                dn2 = it.decl;
                let gens = self.ast_ptr(dm2).at_const(dn2).as_data.aggregate.generics;
                frame.pmod = dm2;
                frame.params = self.ast_ptr(dm2).list(gens);
                let mut gi: u32 = 0;
                while gi < gens.len && gi as u8 < it.n && frame.n < 8 {
                    unsafe frame.args[frame.n as usize] = unsafe it.args[gi as usize];
                    frame.n = frame.n + 1;
                    gi = gi + 1;
                }
                envp = &frame;
            }
            let fesz = self.layout_of(tim, fity, null, 0);
            if !fesz.ok {
                return out;
            }
            let da2 = self.ast_ptr(dm2);
            let agg = da2.at_const(dn2).as_data.aggregate;
            let is_union = agg.is_union;
            let is_tuple = agg.is_tuple;
            let packed = self.ce_attr(dm2, dn2, AttrKind::ATTR_PACKED) != null;
            let fs = agg.members;
            let mut fobjs = Vector::<CeVal>::new();
            let mut run: u64 = 0;
            for i in 0..fs.len {
                let fid = unsafe da2.list(fs)[i as usize];
                if !is_tuple && da2.at_const(fid).kind != NodeKind::NODE_FIELD {
                    continue;
                }
                let mut ftn = fid;
                if !is_tuple {
                    ftn = da2.at_const(fid).as_data.field.ty;
                }
                let ft = self.ce_type(dm2, ftn);
                let fl = self.layout_of(dm2, ft, envp, 1);
                if ft == TYPE_NONE || !fl.ok {
                    fobjs.free();
                    return out;
                }
                let mut fa = fl.align;
                if packed {
                    fa = 1;
                }
                let mut off: u64 = 0;
                if !is_union {
                    off = round_up(run, fa);
                    run = off + fl.size;
                }
                let mut fname = "";
                let mut tbuf = Buf32 {};
                if is_tuple {
                    let tn = ti_tuple_name(&mut tbuf, fobjs.len() as u32);
                    fname = tn;
                } else {
                    let sp = self.name_text(dm2, da2.at_const(fid).as_data.field.name);
                    let src2 = self.ce_src(dm2);
                    fname = src2.slice(sp.start as usize, sp.end as usize);
                }
                // The field type's own tag, through the instance's substitution; advisory, so an
                // untaggable field type degrades to Void rather than failing the whole descriptor.
                let fr = self.ce_ti_env_ty(dm2, ft, envp);
                let mut ftag: i64 = 0;
                if fr.ok {
                    ftag = self.ce_ti_tag(fr.m, fr.t, strm, strn, slm, sln);
                    if ftag < 0 {
                        ftag = 0;
                    }
                }
                let fv = self.ce_ti_member(strm, strn, tim, sty, kty, fity, fname, off, fl.size, -1, ftag as u64);
                if fv.kind != CV_AGG {
                    fobjs.free();
                    return out;
                }
                fobjs.push(fv);
            }
            nfields = fobjs.len() as u32;
            self.ti_nfields = nfields;
            fblock = self.ce_ti_block(tim, fity, fesz.size, &fobjs);
            let failed = fblock == 0 && nfields != 0;
            fobjs.free();
            if failed {
                return out;
            }
        }
        if tag == 15 {
            let mut dm2 = y.module;
            let mut dn2 = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.ast_ptr(tm).instance(y.as_data.inst);
                dm2 = it.module;
                dn2 = it.decl;
            }
            let vesz = self.layout_of(tim, vity, null, 0);
            if !vesz.ok {
                return out;
            }
            let da2 = self.ast_ptr(dm2);
            let vs = da2.at_const(dn2).as_data.aggregate.members;
            let mut any_payload = false;
            for i in 0..vs.len {
                if da2.at_const(unsafe da2.list(vs)[i as usize]).as_data.variant.payload.len > 0 {
                    any_payload = true;
                }
            }
            let mut vobjs = Vector::<CeVal>::new();
            let mut next: i64 = 0;
            for i in 0..vs.len {
                let vid = unsafe da2.list(vs)[i as usize];
                if !any_payload {
                    let vval = da2.at_const(vid).as_data.variant.value;
                    if vval != NODE_NONE {
                        let e = self.eval(dm2, vval);
                        if e.kind != CONST_INT {
                            vobjs.free();
                            return out;
                        }
                        next = e.as_data.i;
                    }
                }
                let mut vtag = next;
                if any_payload {
                    vtag = i;
                }
                next = next + 1;
                let sp = self.name_text(dm2, da2.at_const(vid).as_data.variant.name);
                let src2 = self.ce_src(dm2);
                let vv = self.ce_ti_member(
                    strm,
                    strn,
                    tim,
                    sty,
                    kty,
                    vity,
                    src2.slice(sp.start as usize, sp.end as usize),
                    0,
                    0,
                    vtag,
                    da2.at_const(vid).as_data.variant.payload.len,
                );
                if vv.kind != CV_AGG {
                    vobjs.free();
                    return out;
                }
                vobjs.push(vv);
            }
            nvars = vobjs.len() as u32;
            self.ti_nvars = nvars;
            vblock = self.ce_ti_block(tim, vity, vesz.size, &vobjs);
            let failed = vblock == 0 && nvars != 0;
            vobjs.free();
            if failed {
                return out;
            }
        }
        // Element tag and array length; advisory like a field's kind, so Void on the untaggable.
        let mut etag: i64 = 0;
        let mut alen: u64 = 0;
        let mut ety2 = TYPE_NONE;
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            ety2 = y.as_data.elem;
        } else if y.kind == TypeKind::TYPE_ARRAY {
            ety2 = y.as_data.arr.elem;
            alen = y.as_data.arr.len;
        } else if tag == 10 && y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_ptr(tm).instance(y.as_data.inst);
            if it.n > 0 {
                ety2 = it.args[0];
            }
        }
        if ety2 != TYPE_NONE {
            etag = self.ce_ti_tag(tm, ety2, strm, strn, slm, sln);
            if etag < 0 {
                etag = 0;
            }
        }
        // Assemble: the two slices, then the TypeInfo struct itself.
        let fsl = self.ce_ti_slice(slm, sln, tim, fity, flty, fblock, nfields);
        let vsl = self.ce_ti_slice(slm, sln, tim, vity, vrty, vblock, nvars);
        let nmv = self.ce_ti_str(strm, strn, tim, sty, nm);
        if fsl.kind != CV_AGG || vsl.kind != CV_AGG || nmv.kind != CV_AGG {
            return out;
        }
        let to = self.ce_obj_new(self.ce_field_count(tim, tin));
        if to == 0 {
            return out;
        }
        unsafe self.obj_ptr(to).dm = tim;
        unsafe self.obj_ptr(to).dn = tin;
        let i_name = self.ce_ti_findf(tim, tin, "name");
        let i_kind = self.ce_ti_findf(tim, tin, "kind");
        let i_size = self.ce_ti_findf(tim, tin, "size");
        let i_align = self.ce_ti_findf(tim, tin, "align");
        let i_elem = self.ce_ti_findf(tim, tin, "elem");
        let i_len = self.ce_ti_findf(tim, tin, "len");
        let i_fields = self.ce_ti_findf(tim, tin, "fields");
        let i_vars = self.ce_ti_findf(tim, tin, "variants");
        if i_name < 0 || i_kind < 0 || i_size < 0 || i_align < 0 || i_elem < 0 || i_len < 0 || i_fields < 0 || i_vars < 0 {
            return out;
        }
        unsafe self.obj_ptr(to).slots.set(
            i_elem as usize,
            CeVal { kind: CV_INT, tm: tim, ty: kty, as_data: CeValAs { i: etag } },
        );
        unsafe self.obj_ptr(to).slots.set(
            i_len as usize,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: alen as i64 } },
        );
        unsafe self.obj_ptr(to).slots.set(i_name as usize, nmv);
        unsafe self.obj_ptr(to).slots.set(
            i_kind as usize,
            CeVal { kind: CV_INT, tm: tim, ty: kty, as_data: CeValAs { i: tag } },
        );
        unsafe self.obj_ptr(to).slots.set(
            i_size as usize,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: size as i64 } },
        );
        unsafe self.obj_ptr(to).slots.set(
            i_align as usize,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: align as i64 } },
        );
        unsafe self.obj_ptr(to).slots.set(i_fields as usize, fsl);
        unsafe self.obj_ptr(to).slots.set(i_vars as usize, vsl);
        let mut ret = Rets { ok: true, n: 1 };
        ret.vals[0] = CeVal { kind: CV_AGG, tm: m, ty: rty, as_data: CeValAs { p: CvPtr { obj: to, off: 0 } } };
        return ret;
    }

    // A FieldInfo (`tag < 0`: name/offset/size/kind, `aux` = the field type's TypeTag index) or
    // VariantInfo (`tag >= 0`: name/tag/payload, `aux` = the payload value count) object. `kty` is
    // the TypeTag enum's TypeId in tim's pool, for the FieldInfo `kind` slot.
    fn ce_ti_member(
        self: &mut Self,
        strm: ModuleId,
        strn: NodeId,
        tim: ModuleId,
        sty: TypeId,
        kty: TypeId,
        ety: TypeId,
        name: str,
        off: u64,
        size: u64,
        tag: i64,
        aux: u64,
    ) CeVal {
        let ye = *self.ast_ptr(tim).type_at(ety);
        if ye.kind != TypeKind::TYPE_STRUCT {
            return cv_nil();
        }
        let em = ye.module;
        let en = ye.as_data.decl;
        let nmv = self.ce_ti_str(strm, strn, tim, sty, name);
        if nmv.kind != CV_AGG {
            return cv_nil();
        }
        let o = self.ce_obj_new(self.ce_field_count(em, en));
        if o == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(o).dm = em;
        unsafe self.obj_ptr(o).dn = en;
        let i_name = self.ce_ti_findf(em, en, "name");
        if i_name < 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(o).slots.set(i_name as usize, nmv);
        if tag >= 0 {
            let i_tag = self.ce_ti_findf(em, en, "tag");
            let i_pl = self.ce_ti_findf(em, en, "payload");
            if i_tag < 0 || i_pl < 0 {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).slots.set(
                i_tag as usize,
                CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_I32), as_data: CeValAs { i: tag } },
            );
            unsafe self.obj_ptr(o).slots.set(
                i_pl as usize,
                CeVal {
                    kind: CV_INT,
                    tm: 0,
                    ty: Ast::builtin(BuiltinType::BT_USIZE),
                    as_data: CeValAs { i: aux as i64 },
                },
            );
        } else {
            let i_off = self.ce_ti_findf(em, en, "offset");
            let i_size = self.ce_ti_findf(em, en, "size");
            let i_kind = self.ce_ti_findf(em, en, "kind");
            if i_off < 0 || i_size < 0 || i_kind < 0 {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).slots.set(
                i_off as usize,
                CeVal {
                    kind: CV_INT,
                    tm: 0,
                    ty: Ast::builtin(BuiltinType::BT_USIZE),
                    as_data: CeValAs { i: off as i64 },
                },
            );
            unsafe self.obj_ptr(o).slots.set(
                i_size as usize,
                CeVal {
                    kind: CV_INT,
                    tm: 0,
                    ty: Ast::builtin(BuiltinType::BT_USIZE),
                    as_data: CeValAs { i: size as i64 },
                },
            );
            unsafe self.obj_ptr(o).slots.set(
                i_kind as usize,
                CeVal { kind: CV_INT, tm: tim, ty: kty, as_data: CeValAs { i: aux as i64 } },
            );
        }
        return CeVal { kind: CV_AGG, tm: tim, ty: ety, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    // A heap block holding `objs` as elements of type (tim, ety); 0 = failed (or empty input).
    fn ce_ti_block(self: &mut Self, tim: ModuleId, ety: TypeId, esz: u64, objs: &Vector<CeVal>) u32 {
        let n = objs.len() as u32;
        if n == 0 {
            return 0;
        }
        let b = self.ce_obj_new(n);
        if b == 0 {
            return 0;
        }
        let bo = self.obj_ptr(b);
        unsafe bo.heap = 1;
        unsafe bo.bytes = n as u64 * esz;
        unsafe bo.em = tim;
        unsafe bo.et = ety;
        unsafe bo.esz = esz;
        for k in 0..n {
            unsafe self.obj_ptr(b).slots.set(k as usize, *objs.at(k as usize));
        }
        return b;
    }

    // A Slice<E> view struct over `block` (0 = the empty slice: null ptr, len 0).
    fn ce_ti_slice(
        self: &mut Self,
        slm: ModuleId,
        sln: NodeId,
        tim: ModuleId,
        ety: TypeId,
        slty: TypeId,
        block: u32,
        n: u32,
    ) CeVal {
        let ptr_i = self.ce_ti_findf(slm, sln, "ptr");
        let len_i = self.ce_ti_findf(slm, sln, "len");
        if ptr_i < 0 || len_i < 0 {
            return cv_nil();
        }
        let so = self.ce_obj_new(self.ce_field_count(slm, sln));
        if so == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(so).dm = slm;
        unsafe self.obj_ptr(so).dn = sln;
        unsafe self.obj_ptr(so).nargs = 1;
        unsafe self.obj_ptr(so).am[0] = tim;
        unsafe self.obj_ptr(so).at[0] = ety;
        unsafe self.obj_ptr(so).slots.set(
            ptr_i as usize,
            CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: block, off: 0 } } },
        );
        unsafe self.obj_ptr(so).slots.set(
            len_i as usize,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: n } },
        );
        return CeVal { kind: CV_AGG, tm: tim, ty: slty, as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
    }
}

// The source spelling of a builtin type, as `type_info` reports it.
const fn builtin_name(bt: BuiltinType) str<'static> {
    switch bt {
        BT_BOOL => {
            return "bool";
        },
        BT_CHAR => {
            return "char";
        },
        BT_I8 => {
            return "i8";
        },
        BT_I16 => {
            return "i16";
        },
        BT_I32 => {
            return "i32";
        },
        BT_I64 => {
            return "i64";
        },
        BT_ISIZE => {
            return "isize";
        },
        BT_U8 => {
            return "u8";
        },
        BT_U16 => {
            return "u16";
        },
        BT_U32 => {
            return "u32";
        },
        BT_U64 => {
            return "u64";
        },
        BT_USIZE => {
            return "usize";
        },
        BT_F32 => {
            return "f32";
        },
        BT_F64 => {
            return "f64";
        },
        BT_C32 => {
            return "c32";
        },
        BT_C64 => {
            return "c64";
        },
        BT_VALIST => {
            return "va_list";
        },
        BT_VOID => {
            return "void";
        },
        _ => {
            return "";
        },
    };
}

// "_<k>" into `buf`: the field names a tuple's members answer to.
fn ti_tuple_name(buf: &mut Buf32, k: u32) str {
    buf[0] = b'_';
    let mut n: usize = 1;
    let mut digits = Buf32 {};
    let mut v = k;
    let mut nd: usize = 0;
    do {
        digits[nd] = b'0' + (v % 10) as u8;
        nd = nd + 1;
        v = v / 10;
    } while v != 0;
    while nd > 0 {
        nd = nd - 1;
        buf[n] = digits[nd];
        n = n + 1;
    }
    return str::from_raw(&buf[0], n);
}

// Backward scan: the innermost binding of a shadowed name wins.
fn ce_local_find(f: *mut CeFrame, decl: NodeId) i32 {
    let mut i = unsafe f.n;
    while i > 0 {
        i = i - 1;
        if unsafe f.locals[i as usize].decl == decl {
            return i as i32;
        }
    }
    return -1;
}

const fn cv_bool(tm: ModuleId, rt: TypeId, b: bool) CeVal {
    let mut i: i64 = 0;
    if b {
        i = 1;
    }
    return CeVal { kind: CV_BOOL, tm: tm, ty: rt, as_data: CeValAs { i: i } };
}

const fn ce_float_op(op: TokenType, l: CeVal, r: CeVal, tm: ModuleId, rt: TypeId, b: BuiltinType) CeVal {
    if op == TokenType::EqualEqual {
        return cv_bool(tm, rt, l.as_data.f == r.as_data.f);
    }
    if op == TokenType::BangEqual {
        return cv_bool(tm, rt, l.as_data.f != r.as_data.f);
    }
    if op == TokenType::LessThan {
        return cv_bool(tm, rt, l.as_data.f < r.as_data.f);
    }
    if op == TokenType::LessThanEqual {
        return cv_bool(tm, rt, l.as_data.f <= r.as_data.f);
    }
    if op == TokenType::GreaterThan {
        return cv_bool(tm, rt, l.as_data.f > r.as_data.f);
    }
    if op == TokenType::GreaterThanEqual {
        return cv_bool(tm, rt, l.as_data.f >= r.as_data.f);
    }
    let mut v: f64 = 0.0;
    switch op {
        Plus => {
            v = l.as_data.f + r.as_data.f;
        },
        Minus => {
            v = l.as_data.f - r.as_data.f;
        },
        Star => {
            v = l.as_data.f * r.as_data.f;
        },
        Slash => {
            v = l.as_data.f / r.as_data.f;
        },
        _ => {
            return cv_nil();
        },
    };
    if b == BuiltinType::BT_F32 {
        v = v as f32;
    }
    return CeVal { kind: CV_FLOAT, tm: tm, ty: rt, as_data: CeValAs { f: v } };
}

const fn cv_scalar_of(v: ConstValue, m: ModuleId) CeVal {
    if v.kind == CONST_INT {
        return CeVal { kind: CV_INT, tm: m, ty: v.ty, as_data: CeValAs { i: v.as_data.i } };
    }
    if v.kind == CONST_BOOL {
        return CeVal { kind: CV_BOOL, tm: m, ty: v.ty, as_data: CeValAs { i: v.as_data.i } };
    }
    return cv_nil();
}

// C's usual arithmetic conversions for two integer operands.
const fn ce_arith_common(a: BuiltinType, b: BuiltinType) BuiltinType {
    if a == BuiltinType::BT_COUNT || b == BuiltinType::BT_COUNT {
        if a == BuiltinType::BT_COUNT {
            return b;
        }
        return a;
    }
    let mut wa = bt_bits(a);
    if wa < 32 {
        wa = 32;
    }
    let mut wb = bt_bits(b);
    if wb < 32 {
        wb = 32;
    }
    let ua = bt_bits(a) >= 32 && bt_unsigned(a);
    let ub = bt_bits(b) >= 32 && bt_unsigned(b);
    let mut w = wb;
    if wa > wb {
        w = wa;
    }
    let mut u = ua;
    if ua != ub {
        let mut lhs = wb;
        let mut rhs = wa;
        if ua {
            lhs = wa;
            rhs = wb;
        }
        u = lhs >= rhs;
    }
    if u {
        if w == 64 {
            return BuiltinType::BT_U64;
        }
        return BuiltinType::BT_U32;
    }
    if w == 64 {
        return BuiltinType::BT_I64;
    }
    return BuiltinType::BT_I32;
}

// --- expression evaluation ----------------------------------------------------------------------

extend ConstEval {
    // The prelude's Range struct decl.
    fn ce_range_decl(self: &Self, dm: *mut ModuleId, dn: *mut NodeId) bool {
        let mut mm: ModuleId = 0;
        while mm as usize < self.nmods {
            if self.has_ast(mm) {
                let a = self.ast_ptr(mm);
                if unsafe a.nodes.len() != 0 {
                    let items = unsafe a.at_const(a.root).as_data.program.items;
                    for i in 0..items.len {
                        let iid = unsafe a.list(items)[i as usize];
                        if a.at_const(iid).kind == NodeKind::NODE_STRUCT && !a.at_const(iid).as_data.aggregate.is_union {
                            let nm = self.name_text(mm, a.at_const(iid).as_data.aggregate.name);
                            if self.ce_span_is(mm, nm, "Range") {
                                unsafe *dm = mm;
                                unsafe *dn = iid;
                                return true;
                            }
                        }
                    }
                }
            }
            mm = mm + 1;
        }
        return false;
    }

    fn ce_range_obj(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let start_n = a.at_const(id).as_data.pattern_range.start;
        let end_n = a.at_const(id).as_data.pattern_range.end;
        let inclusive = a.at_const(id).as_data.pattern_range.inclusive;
        if start_n == NODE_NONE || end_n == NODE_NONE {
            return cv_nil();
        }
        let mut dm: ModuleId = 0;
        let mut dn: NodeId = NODE_NONE;
        if !self.ce_range_decl(&mut dm, &mut dn) {
            return cv_nil();
        }
        let was_s = self.trap_mark();
        let mut sv = self.ev_in(f, m, start_n);
        if sv.kind == CV_NIL_K {
            self.trap_discard(was_s);
            sv = self.ev_in(null, m, start_n);
        }
        let was_e = self.trap_mark();
        let mut e = self.ev_in(f, m, end_n);
        if e.kind == CV_NIL_K {
            self.trap_discard(was_e);
            e = self.ev_in(null, m, end_n);
        }
        if sv.kind == CV_PTR {
            let lr = self.ce_loadp(sv);
            if !lr.ok {
                return cv_nil();
            }
            sv = lr.v;
        }
        if e.kind == CV_PTR {
            let lr = self.ce_loadp(e);
            if !lr.ok {
                return cv_nil();
            }
            e = lr.v;
        }
        if sv.kind != CV_INT || e.kind != CV_INT {
            return cv_nil();
        }
        let o = self.ce_obj_new(self.ce_field_count(dm, dn));
        if o == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(o).dm = dm;
        unsafe self.obj_ptr(o).dn = dn;
        unsafe self.obj_ptr(o).nargs = 1;
        unsafe self.obj_ptr(o).at[0] = Ast::builtin(BuiltinType::BT_USIZE);
        if unsafe self.obj_ptr(o).slots.len() < 3 {
            return cv_nil();
        }
        unsafe self.obj_ptr(o).slots.set(0, sv);
        unsafe self.obj_ptr(o).slots.set(1, e);
        unsafe self.obj_ptr(o).slots.set(2, cv_bool(0, Ast::builtin(BuiltinType::BT_BOOL), inclusive));
        return CeVal { kind: CV_AGG, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    fn ev_in(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        if id == NODE_NONE || !self.ce_tick() || self.depth > CE_MAX_DEPTH as u32 {
            return cv_nil();
        }
        self.depth = self.depth + 1;
        let v = self.ev(f, m, id);
        self.depth = self.depth - 1;
        return v;
    }

    // ev + auto-deref: an expression statically typed as a REFERENCE loads through to its value.
    fn ev_rval(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let mut v = self.ev_in(f, m, id);
        if v.kind != CV_PTR {
            return v;
        }
        let mut tm = m;
        let mut t = self.ce_type(m, id);
        let mut guard = 0;
        while guard < 4 && v.kind == CV_PTR {
            let r = self.ce_rtype(f, tm, t);
            if !r.ok {
                return v;
            }
            tm = r.m;
            t = r.t;
            let y = self.ast_ptr(tm).type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE {
                return v;
            }
            let elem = y.as_data.elem;
            let lr = self.ce_loadp(v);
            if !lr.ok {
                return cv_nil();
            }
            v = lr.v;
            t = elem;
            guard = guard + 1;
        }
        return v;
    }

    // Coerce a value to a wanted resolved type at a binding boundary.
    fn ce_coerce(self: &mut Self, v: CeVal, wm: ModuleId, wt: TypeId) CeVal {
        if v.kind == CV_NIL_K {
            return cv_nil();
        }
        if wt == TYPE_NONE {
            return v;
        }
        let y = *self.ast_ptr(wm).type_at(wt);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION {
            if v.kind == CV_PTR || v.kind == CV_FN {
                return v;
            }
            return cv_nil();
        }
        if v.kind == CV_PTR {
            let lr = self.ce_loadp(v);
            if !lr.ok {
                return cv_nil();
            }
            return self.ce_coerce(lr.v, wm, wt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE && v.kind == CV_AGG && v.ty != TYPE_NONE && self.ast_ptr(v.tm).type_at(
            v.ty,
        ).kind == TypeKind::TYPE_ARRAY {
            let it = *self.ast_ptr(wm).instance(y.as_data.inst);
            let da = self.ast_ptr(it.module);
            let dn = self.name_text(it.module, da.at_const(it.decl).as_data.aggregate.name);
            if !self.ce_span_is(it.module, dn, "Slice") && !self.ce_span_is(it.module, dn, "SliceMut") {
                return cv_nil();
            }
            if self.obj_ptr(v.as_data.p.obj) == null {
                return cv_nil();
            }
            let arrlen = (unsafe self.obj_ptr(v.as_data.p.obj).slots.len()) as i64;
            let so = self.ce_obj_new(2);
            if so == 0 {
                return cv_nil();
            }
            unsafe self.obj_ptr(so).dm = it.module;
            unsafe self.obj_ptr(so).dn = it.decl;
            unsafe self.obj_ptr(so).slots.set(
                0,
                CeVal {
                    kind: CV_PTR,
                    tm: 0,
                    ty: TYPE_NONE,
                    as_data: CeValAs { p: CvPtr { obj: v.as_data.p.obj, off: 0 } },
                },
            );
            unsafe self.obj_ptr(so).slots.set(
                1,
                CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: arrlen } },
            );
            return CeVal { kind: CV_AGG, tm: wm, ty: wt, as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
        }
        if y.kind == TypeKind::TYPE_ARRAY && v.kind == CV_AGG && y.as_data.arr.len != 0 {
            let o = self.obj_ptr(v.as_data.p.obj);
            if o != null && (unsafe o.slots.len()) as u32 < y.as_data.arr.len {
                let from = (unsafe o.slots.len()) as u32;
                let er = self.ce_rtype(null, wm, y.as_data.arr.elem);
                if !er.ok {
                    return cv_nil();
                }
                let z = self.ce_zero(er.m, er.t, 0);
                if z.kind == CV_NIL_K || !self.ce_obj_resize(v.as_data.p.obj, y.as_data.arr.len) {
                    return cv_nil();
                }
                let newlen = (unsafe self.obj_ptr(v.as_data.p.obj).slots.len()) as u32;
                let mut i = from;
                while i < newlen {
                    let cloned = self.ce_clone(z, 0);
                    unsafe self.obj_ptr(v.as_data.p.obj).slots.set(i as usize, cloned);
                    i = i + 1;
                }
            }
        }
        return v;
    }

    // The object behind an aggregate-valued expression, through references.
    fn ce_base_obj(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) ObjRes {
        let mut v = self.ev_in(f, m, id);
        let mut guard = 0;
        while guard < 4 && v.kind == CV_PTR {
            let lr = self.ce_loadp(v);
            if !lr.ok {
                return ObjRes { ok: false };
            }
            v = lr.v;
            guard = guard + 1;
        }
        if v.kind != CV_AGG {
            return ObjRes { ok: false };
        }
        return ObjRes { ok: true, obj: v.as_data.p.obj };
    }

    fn ev_place(self: &mut Self, f: *mut CeFrame, m: ModuleId, id0: NodeId) ValRes {
        let a = self.ast_ptr(m);
        let mut id = id0;
        loop {
            let k = a.at_const(id).kind;
            if k == NodeKind::NODE_UNARY {
                let op = a.at_const(id).as_data.unary.op;
                if op == TokenType::Move || op == TokenType::Unsafe {
                    id = a.at_const(id).as_data.unary.operand;
                    continue;
                }
            }
            break;
        }
        let n_kind = a.at_const(id).kind;
        if n_kind == NodeKind::NODE_IDENTIFIER {
            if f == null {
                return ValRes { ok: false };
            }
            let mut d = a.resolution_def(id);
            if d.node == NODE_NONE {
                d = DefId { module: m, node: a.resolution(id) };
            }
            if d.module != m {
                return ValRes { ok: false };
            }
            let i = ce_local_find(f, d.node);
            if i < 0 {
                return ValRes { ok: false };
            }
            let slot = unsafe f.locals[i as usize].slot;
            return ValRes {
                ok: true,
                v: CeVal {
                    kind: CV_PTR,
                    tm: 0,
                    ty: TYPE_NONE,
                    as_data: CeValAs { p: CvPtr { obj: unsafe f.env, off: slot } },
                },
            };
        }
        if n_kind == NodeKind::NODE_MEMBER {
            if a.at_const(id).as_data.member.path {
                return ValRes { ok: false };
            }
            let mem = a.at_const(id).as_data.member.member;
            let obj_n = a.at_const(id).as_data.member.object;
            let mname = self.name_text(m, mem);
            let br = self.ce_base_obj(f, m, obj_n);
            if !br.ok {
                return ValRes { ok: false };
            }
            let o = self.obj_ptr(br.obj);
            if o == null || unsafe o.dead != 0 {
                return ValRes { ok: false };
            }
            let c0 = self.ce_src(m)[mname.start as usize];
            let mut idx: u32 = 0;
            if c0 >= b'0' && c0 <= b'9' {
                idx = c0 - b'0';
            } else {
                if unsafe o.dn == NODE_NONE {
                    return ValRes { ok: false };
                }
                let fi = self.ce_field_index(unsafe o.dm, unsafe o.dn, m, mname);
                if fi.idx < 0 {
                    return ValRes { ok: false };
                }
                idx = fi.idx as u32;
            }
            if idx >= (unsafe self.obj_ptr(br.obj).slots.len()) as u32 {
                return ValRes { ok: false };
            }
            return ValRes {
                ok: true,
                v: CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: br.obj, off: idx } } },
            };
        }
        if n_kind == NodeKind::NODE_INDEX {
            let obj_n = a.at_const(id).as_data.index.object;
            let index_n = a.at_const(id).as_data.index.index;
            let mut bm = m;
            let mut bt = self.ce_type(m, obj_n);
            for _ in 0..4 {
                let r = self.ce_rtype(f, bm, bt);
                if !r.ok {
                    return ValRes { ok: false };
                }
                bm = r.m;
                bt = r.t;
                let y = self.ast_ptr(bm).type_at(bt);
                if y.kind != TypeKind::TYPE_REFERENCE {
                    break;
                }
                bt = y.as_data.elem;
            }
            let yk = self.ast_ptr(bm).type_at(bt).kind;
            let iv = self.ev_rval(f, m, index_n);
            if iv.kind != CV_INT {
                return ValRes { ok: false };
            }
            if yk == TypeKind::TYPE_POINTER {
                let p = self.ev_rval(f, m, obj_n);
                if p.kind != CV_PTR {
                    return ValRes { ok: false };
                }
                let mut out = p;
                out.as_data.p.off = out.as_data.p.off + iv.as_data.i as u32;
                return ValRes { ok: true, v: out };
            }
            if yk == TypeKind::TYPE_ARRAY {
                let br = self.ce_base_obj(f, m, obj_n);
                if !br.ok {
                    return ValRes { ok: false };
                }
                let olen = (unsafe self.obj_ptr(br.obj).slots.len()) as u64;
                if iv.as_data.i < 0 || iv.as_data.i as u64 >= olen {
                    self.ce_trap(CE_TRAP_UB_OOB, "out-of-bounds access");
                    return ValRes { ok: false };
                }
                return ValRes {
                    ok: true,
                    v: CeVal {
                        kind: CV_PTR,
                        tm: 0,
                        ty: TYPE_NONE,
                        as_data: CeValAs { p: CvPtr { obj: br.obj, off: iv.as_data.i as u32 } },
                    },
                };
            }
            if yk == TypeKind::TYPE_STRUCT || yk == TypeKind::TYPE_INSTANCE {
                let rr = self.ce_recv_of(f, bm, bt);
                if !rr.ok {
                    return ValRes { ok: false };
                }
                let recvr = self.ev_place(f, m, obj_n);
                if !recvr.ok {
                    return ValRes { ok: false };
                }
                let mut args: [CeVal; 8] = [
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                ];
                args[0] = recvr.v;
                args[1] = iv;
                let dr = self.ce_dispatch(rr.r, m, "index_mut", &args[0], 2);
                if !dr.ok || dr.v.kind != CV_PTR {
                    return ValRes { ok: false };
                }
                return ValRes { ok: true, v: dr.v };
            }
            return ValRes { ok: false };
        }
        if n_kind == NodeKind::NODE_UNARY {
            let op = a.at_const(id).as_data.unary.op;
            if op == TokenType::Star {
                let p = self.ev_in(f, m, a.at_const(id).as_data.unary.operand);
                if p.kind != CV_PTR {
                    return ValRes { ok: false };
                }
                return ValRes { ok: true, v: p };
            }
            return ValRes { ok: false };
        }
        return ValRes { ok: false };
    }

    // A const's initializer evaluated under the memo sentinel, so dependency cycles trap as CYCLE
    // instead of burning the depth/step budget.
    fn ev_const_init(self: &mut Self, dm: ModuleId, dval: NodeId) CeVal {
        let prior = self.slot_get(dm, dval);
        if prior.kind == CONST_EVALUATING {
            self.ce_trap(CE_TRAP_CYCLE, "cyclic constant dependency");
            return cv_nil();
        }
        self.slot_set(dm, dval, ConstValue { kind: CONST_EVALUATING });
        let v = self.ev_in(null, dm, dval);
        self.slot_set(dm, dval, prior); // keep any scalar/AGG_OK memo eval() already established
        return v;
    }

    fn ev(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        if !self.has_ast(m) {
            return cv_nil();
        }
        let a = self.ast_ptr(m);
        let n = a.at_const(id);
        let ntt = n.as_data.literal.token_type; // valid only when kind==NODE_LITERAL
        if f != null && self.ce_type(m, id) == TYPE_NONE && !(n.kind == NodeKind::NODE_LITERAL && ntt == TokenType::Null) {
            return cv_nil();
        }
        let src = self.ce_src(m);
        let rt = self.ce_type(m, id);
        if n.kind == NodeKind::NODE_LITERAL {
            if self.ast_ptr(m).wide_lit_of(id) >= 0 {
                return cv_nil(); // wider than the evaluator's scalars; codegen emits the limbs
            }
            if ntt == TokenType::IntegerLiteral {
                return cv_scalar_of(self.eval_int_literal(m, id), m);
            }
            if ntt == TokenType::CharacterLiteral || ntt == TokenType::ByteCharacterLiteral {
                return cv_scalar_of(self.eval_char_literal(m, id), m);
            }
            if ntt == TokenType::FloatLiteral {
                return self.eval_float_literal(m, id);
            }
            if ntt == TokenType::True {
                return cv_bool(m, rt, true);
            }
            if ntt == TokenType::False {
                return cv_bool(m, rt, false);
            }
            if ntt == TokenType::Null {
                return CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: 0, off: 0 } } };
            }
            if ntt == TokenType::StringLiteral || ntt == TokenType::RawStringLiteral {
                return self.eval_str_literal(f, m, id);
            }
            return cv_nil();
        }
        // A one-part type path with a resolution is a const-generic ARGUMENT that named a value: the grammar
        // parses every non-literal argument as a type (see `parse_type_args`), and the resolver binds it to
        // the const it actually names (see `resolve_generic_arg`). From here it evaluates like an identifier,
        // because everything below reads only the node's resolution.
        let mut ident_like = n.kind == NodeKind::NODE_IDENTIFIER;
        if !ident_like && n.kind == NodeKind::NODE_TYPE_PATH {
            let tp = n.as_data.type_path;
            ident_like = tp.parts.len == 1 && tp.args.len == 0 && a.resolution_def(id).node != NODE_NONE;
        }
        if ident_like {
            let mut d = a.resolution_def(id);
            if d.node == NODE_NONE {
                d = DefId { module: m, node: a.resolution(id) };
            }
            if d.node == NODE_NONE || d.module as usize >= self.nmods {
                return cv_nil();
            }
            if f != null && d.module == m {
                let i = ce_local_find(f, d.node);
                if i >= 0 {
                    let slot = unsafe f.locals[i as usize].slot;
                    let env = unsafe f.env;
                    let eo = self.obj_ptr(env);
                    if eo == null || slot as usize >= unsafe eo.slots.len() {
                        return cv_nil();
                    }
                    let mut v = unsafe eo.slots[slot as usize];
                    if v.kind == CV_NIL_K {
                        return cv_nil();
                    }
                    if v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT {
                        v.tm = m;
                        v.ty = rt;
                    }
                    return v;
                }
            }
            let dk = self.ast_ptr(d.module).at_const(d.node).kind;
            if dk == NodeKind::NODE_GENERIC_PARAM {
                // a const-generic parameter (e.g. the N of Array<T, N>): its bound TYPE_CONST value
                if f != null {
                    for i in 0..unsafe f.ng {
                        if unsafe f.pmod == d.module && unsafe f.params_g[i as usize] == d.node {
                            let at2 = unsafe f.at[i as usize];
                            if at2 != TYPE_NONE {
                                let y = self.ast_ptr(unsafe f.am[i as usize]).type_at(at2);
                                if y.kind == TypeKind::TYPE_CONST {
                                    return CeVal {
                                        kind: CV_INT,
                                        tm: m,
                                        ty: rt,
                                        as_data: CeValAs { i: y.as_data.value },
                                    };
                                }
                            }
                            break;
                        }
                    }
                }
                return cv_nil();
            }
            if dk == NodeKind::NODE_FUNCTION {
                return CeVal {
                    kind: CV_FN,
                    tm: m,
                    ty: rt,
                    as_data: CeValAs { fnv: CvFn { m: d.module, fn_id: d.node } },
                };
            }
            if dk != NodeKind::NODE_CONST {
                return cv_nil(); // read the union arm only for a NODE_CONST: a garbage bool byte is UB in C
            }
            let dval = self.ast_ptr(d.module).at_const(d.node).as_data.const_def.value;
            let is_static_mut = self.ast_ptr(d.module).at_const(d.node).as_data.const_def.is_static_mut;
            if dval == NODE_NONE || is_static_mut {
                return cv_nil();
            }
            let mut v = self.ev_const_init(d.module, dval);
            if v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT {
                v.tm = m;
                v.ty = rt;
            }
            return v;
        }
        if n.kind == NodeKind::NODE_MEMBER {
            if !n.as_data.member.path {
                let pv = self.ce_proj_member(m, id);
                if pv.kind != CV_NIL_K {
                    return pv;
                }
            }
            if n.as_data.member.path {
                let mut d = a.resolution_def(id);
                if d.node == NODE_NONE {
                    d = a.resolution_def(n.as_data.member.member);
                }
                if d.node == NODE_NONE {
                    // Pre-typecheck (a cross-module const init demanded before its module is checked):
                    // path-member resolutions are recorded by the TYPECHECKER, so ENUM::VARIANT binds
                    // structurally here instead -- the enum name has a resolver resolution and the
                    // variant matches by name (the same DefId the typechecker records later).
                    let od = a.resolution_def(n.as_data.member.object);
                    if od.node != NODE_NONE && od.module as usize < self.nmods {
                        let oa = self.ast_ptr(od.module);
                        if oa.at_const(od.node).kind == NodeKind::NODE_ENUM {
                            let msp = self.name_text(m, n.as_data.member.member);
                            let lit = diag::span_str(self.ce_src(m), msp.start, msp.end);
                            let vi = self.ce_variant_named(od.module, od.node, lit);
                            if vi >= 0 {
                                let ms = oa.at_const(od.node).as_data.aggregate.members;
                                d = DefId { module: od.module, node: unsafe oa.list(ms)[vi as usize] };
                            }
                        }
                    }
                }
                if d.node == NODE_NONE || d.module as usize >= self.nmods {
                    return cv_nil();
                }
                let dk = self.ast_ptr(d.module).at_const(d.node).kind;
                if dk == NodeKind::NODE_CONST {
                    let dval = self.ast_ptr(d.module).at_const(d.node).as_data.const_def.value;
                    let is_sm = self.ast_ptr(d.module).at_const(d.node).as_data.const_def.is_static_mut;
                    if dval != NODE_NONE && !is_sm {
                        let mut v = self.ev_const_init(d.module, dval);
                        if v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT {
                            v.tm = m;
                            v.ty = rt;
                        }
                        return v;
                    }
                }
                if dk == NodeKind::NODE_FUNCTION {
                    return CeVal {
                        kind: CV_FN,
                        tm: m,
                        ty: rt,
                        as_data: CeValAs { fnv: CvFn { m: d.module, fn_id: d.node } },
                    };
                }
                if dk != NodeKind::NODE_VARIANT {
                    return cv_nil();
                }
                let vp = self.ce_variant_pos(d.module, d.node);
                if vp.pos < 0 {
                    return cv_nil();
                }
                if !self.ce_enum_tagged(d.module, vp.enum_decl) {
                    let mut v = cv_scalar_of(self.variant_value(d.module, d.node), m);
                    v.ty = rt;
                    return v;
                }
                if self.ast_ptr(d.module).at_const(d.node).as_data.variant.payload.len > 0 {
                    return cv_nil();
                }
                if self.ce_user_free(d.module, vp.enum_decl) {
                    return cv_nil();
                }
                let o = self.ce_obj_new(1);
                if o == 0 {
                    return cv_nil();
                }
                unsafe self.obj_ptr(o).is_enum = 1;
                unsafe self.obj_ptr(o).dm = d.module;
                unsafe self.obj_ptr(o).dn = vp.enum_decl;
                unsafe self.obj_ptr(o).slots.set(
                    0,
                    CeVal { kind: CV_INT, tm: 0, ty: TYPE_NONE, as_data: CeValAs { i: vp.pos } },
                );
                return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
            }
            let mname = self.name_text(m, n.as_data.member.member);
            let br = self.ce_base_obj(f, m, n.as_data.member.object);
            if !br.ok {
                return cv_nil();
            }
            let o = self.obj_ptr(br.obj);
            if o == null || unsafe o.dead != 0 {
                return cv_nil();
            }
            let c0 = src[mname.start as usize];
            let mut idx: u32 = 0;
            if c0 >= b'0' && c0 <= b'9' {
                idx = c0 - b'0';
            } else {
                if unsafe o.dn == NODE_NONE {
                    return cv_nil();
                }
                let fi = self.ce_field_index(unsafe o.dm, unsafe o.dn, m, mname);
                if fi.idx < 0 {
                    return cv_nil();
                }
                idx = fi.idx as u32;
            }
            let oo = self.obj_ptr(br.obj);
            if idx >= (unsafe oo.slots.len()) as u32 {
                return cv_nil();
            }
            let sv = unsafe oo.slots[idx as usize];
            if sv.kind == CV_NIL_K {
                return cv_nil();
            }
            return sv;
        }
        if n.kind == NodeKind::NODE_UNARY {
            return self.ev_unary(f, m, id);
        }
        if n.kind == NodeKind::NODE_CAST {
            return self.ev_cast(f, m, id);
        }
        if n.kind == NodeKind::NODE_SIZEOF || n.kind == NodeKind::NODE_ALIGNOF {
            let ty = self.ce_type(m, n.as_data.single.value);
            let lay = self.ce_layout_f(f, m, ty);
            if !lay.ok {
                return cv_nil();
            }
            let mut val = lay.align;
            if n.kind == NodeKind::NODE_SIZEOF {
                val = lay.size;
            }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: val as i64 } };
        }
        if n.kind == NodeKind::NODE_BINARY {
            return self.ev_binary(f, m, id);
        }
        if n.kind == NodeKind::NODE_CALL {
            let cr = self.ce_call(f, m, id);
            if !cr.ok || cr.n != 1 {
                return cv_nil();
            }
            return cr.vals[0];
        }
        if n.kind == NodeKind::NODE_MATCH {
            if f == null {
                return cv_nil();
            }
            let mut out = cv_nil();
            if self.exec_match(f, m, id, &mut out) == Flow::Ok {
                return out;
            }
            return cv_nil();
        }
        if n.kind == NodeKind::NODE_BLOCK {
            return self.ev_block(f, m, id);
        }
        if n.kind == NodeKind::NODE_IF {
            if f == null {
                return cv_nil();
            }
            let c = self.ev_rval(f, m, n.as_data.if_stmt.condition);
            if c.kind != CV_BOOL {
                return cv_nil();
            }
            let mut branch = n.as_data.if_stmt.else_branch;
            if c.as_data.i != 0 {
                branch = n.as_data.if_stmt.then_branch;
            }
            return self.ev_in(f, m, branch);
        }
        if n.kind == NodeKind::NODE_INDEX {
            return self.ev_index(f, m, id);
        }
        if n.kind == NodeKind::NODE_STRUCT_INITIALIZER {
            return self.ev_struct_init(f, m, id);
        }
        if n.kind == NodeKind::NODE_ARRAY_LITERAL {
            return self.ev_array_lit(f, m, id);
        }
        if n.kind == NodeKind::NODE_TUPLE {
            return self.ev_tuple(f, m, id);
        }
        if n.kind == NodeKind::NODE_CLOSURE {
            return CeVal { kind: CV_FN, tm: m, ty: rt, as_data: CeValAs { fnv: CvFn { m: m, fn_id: id } } };
        }
        if n.kind == NodeKind::NODE_RANGE {
            return self.ce_range_obj(f, m, id);
        }
        return cv_nil();
    }

    fn ev_unary(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let n = a.at_const(id);
        let op = n.as_data.unary.op;
        let operand = n.as_data.unary.operand;
        let rt = self.ce_type(m, id);
        if op == TokenType::Move || op == TokenType::Unsafe {
            return self.ev_in(f, m, operand);
        }
        if op == TokenType::Minus && self.ast_ptr(m).wide_lit_of(id) >= 0 {
            return cv_nil(); // a wide negative literal; codegen emits the limbs
        }
        if op == TokenType::Ampersand {
            let was = self.trap_mark();
            let pr = self.ev_place(f, m, operand);
            if pr.ok {
                let mut p = pr.v;
                p.tm = m;
                p.ty = rt;
                return p;
            }
            self.trap_discard(was);
            let v = self.ev_in(f, m, operand);
            if v.kind == CV_NIL_K {
                return cv_nil();
            }
            let tr = self.ce_temp_place(v);
            if !tr.ok {
                return cv_nil();
            }
            let mut out = tr.v;
            out.tm = m;
            out.ty = rt;
            return out;
        }
        if op == TokenType::Star {
            let p = self.ev_in(f, m, operand);
            if p.kind != CV_PTR {
                return cv_nil();
            }
            let lr = self.ce_loadp(p);
            if !lr.ok {
                return cv_nil();
            }
            // A REINTERPRETING deref -- `*((&x) as *const f64 as *const u64)` -- loads a value whose
            // kind disagrees with the deref's static type. The evaluator has no byte representation to
            // pun through, so folding would substitute the unconverted value; refuse instead, and the
            // expression runs at runtime where the pun is real.
            let want = type_builtin(self.ast_ptr(m), rt);
            if want != BuiltinType::BT_COUNT {
                let is_f = want == BuiltinType::BT_F32 || want == BuiltinType::BT_F64;
                if is_f && lr.v.kind != CV_FLOAT || !is_f && lr.v.kind == CV_FLOAT {
                    return cv_nil();
                }
            }
            return lr.v;
        }
        if op == TokenType::Question {
            if f == null {
                return cv_nil();
            }
            let v = self.ev_rval(f, m, operand);
            if v.kind != CV_AGG {
                return cv_nil();
            }
            let o = self.obj_ptr(v.as_data.p.obj);
            if o == null || unsafe o.is_enum == 0 {
                return cv_nil();
            }
            let odm = unsafe o.dm;
            let odn = unsafe o.dn;
            let mut okv = self.ce_variant_named(odm, odn, "Some");
            if okv < 0 {
                okv = self.ce_variant_named(odm, odn, "Ok");
            }
            if okv < 0 {
                return cv_nil();
            }
            let o2 = self.obj_ptr(v.as_data.p.obj);
            let tag = unsafe o2.slots[0].as_data.i;
            if tag == okv as i64 {
                if unsafe o2.slots.len() < 2 || unsafe o2.slots[1].kind == CV_NIL_K {
                    return cv_nil();
                }
                return unsafe o2.slots[1];
            }
            unsafe f.rets[0] = v;
            unsafe f.nrets = 1;
            unsafe f.returned = 1;
            unsafe f.early = 1;
            return cv_nil();
        }
        let o = self.ev_rval(f, m, operand);
        if o.kind == CV_NIL_K {
            return cv_nil();
        }
        let b = self.ce_builtin_of(f, m, rt);
        if op == TokenType::Minus {
            if o.kind == CV_FLOAT {
                let mut v = -o.as_data.f;
                if b == BuiltinType::BT_F32 {
                    v = v as f32;
                }
                return CeVal { kind: CV_FLOAT, tm: m, ty: rt, as_data: CeValAs { f: v } };
            }
            if o.kind != CV_INT || o.as_data.i == I64_MIN {
                return cv_nil();
            }
            let r = -o.as_data.i;
            if b != BuiltinType::BT_COUNT && !fits(b, r) {
                return cv_nil();
            }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: r } };
        }
        if op == TokenType::Tilde {
            if o.kind != CV_INT {
                return cv_nil();
            }
            // A `~` on an operator-overloaded aggregate (e.g. UInt<128>) reaches here only when the
            // operand folded through a scalar coercion; complementing that 64-bit stand-in would be a
            // wrong value at the aggregate's width. Runtime dispatches the overload instead.
            let sr = self.ce_strip_refptr(f, m, self.ce_type(m, operand));
            if sr.ok {
                let k = self.ast_ptr(sr.m).type_at(sr.t).kind;
                if k == TypeKind::TYPE_STRUCT || k == TypeKind::TYPE_INSTANCE {
                    return cv_nil();
                }
            }
            let mut bb = b;
            if b == BuiltinType::BT_COUNT {
                bb = BuiltinType::BT_I64;
            }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: wrap_to(bb, ~o.as_data.i) } };
        }
        if op == TokenType::Bang {
            if o.kind != CV_BOOL {
                return cv_nil();
            }
            return cv_bool(m, rt, o.as_data.i == 0);
        }
        return cv_nil();
    }

    // Builtin named by the cast's TYPE NODE -- for casts demanded BEFORE their module is typechecked
    // (a cross-module const init reached through a foreign struct's array-length, e.g. `[NodeId;
    // BT_COUNT_N]` embedded by value from another module). Pre-typecheck the node has no recorded type
    // and the module's type pool is unseeded, so this works purely at the BuiltinType level: a resolved
    // path maps through the core builtin decls, an unresolved single-name path by name (builtins bind
    // by name at lower time). BT_COUNT = not a builtin cast.
    fn ce_cast_builtin(self: &Self, m: ModuleId, id: NodeId) BuiltinType {
        let a = self.ast_ptr(m);
        let tyn = a.at_const(id).as_data.cast.ty;
        if tyn == NODE_NONE {
            return BuiltinType::BT_COUNT;
        }
        let nk = a.at_const(tyn).kind;
        if nk != NodeKind::NODE_TYPE_PATH && nk != NodeKind::NODE_IDENTIFIER {
            return BuiltinType::BT_COUNT;
        }
        let d = a.resolution_def(tyn);
        if d.node != NODE_NONE {
            let bb = self.pkg.builtin_of_decl(d.module, d.node);
            if bb >= 0 {
                return bb as BuiltinType;
            }
            return BuiltinType::BT_COUNT;
        }
        let mut nm = tok::Span::new(0, 0);
        if nk == NodeKind::NODE_IDENTIFIER {
            nm = a.at_const(tyn).as_data.name.text;
        } else {
            let parts = a.at_const(tyn).as_data.type_path.parts;
            if parts.len != 1 {
                return BuiltinType::BT_COUNT;
            }
            nm = a.at_const(unsafe a.list(parts)[0]).as_data.name.text;
        }
        let b2 = bt_of_name(self.ce_src(m), nm);
        if b2 >= 0 {
            return b2 as BuiltinType;
        }
        return BuiltinType::BT_COUNT;
    }

    // ev_cast for a not-yet-typechecked module: only integer-targeted casts of integer/bool scalars
    // fold (the `E::COUNT as usize` const-init family); everything else stays unfoldable, as before.
    fn ev_cast_untyped(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId, expr: NodeId) CeVal {
        let b = self.ce_cast_builtin(m, id);
        let ok = b == BuiltinType::BT_CHAR || b as u8 >= BuiltinType::BT_I8 as u8 && b as u8 <= BuiltinType::BT_USIZE as u8;
        if !ok {
            return cv_nil();
        }
        let o = self.ev_rval(f, m, expr);
        if o.kind != CV_INT && o.kind != CV_BOOL {
            return cv_nil();
        }
        return CeVal { kind: CV_INT, tm: m, ty: TYPE_NONE, as_data: CeValAs { i: wrap_to(b, o.as_data.i) } };
    }

    fn ev_cast(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let n = a.at_const(id);
        let expr = n.as_data.cast.expression;
        let rt = self.ce_type(m, id);
        if rt == TYPE_NONE {
            return self.ev_cast_untyped(f, m, id, expr);
        }
        let r2 = self.ce_rtype(f, m, rt);
        if !r2.ok {
            return cv_nil();
        }
        // A pointer-targeted cast keeps the operand's place value (`(&mut x) as *mut T` must not
        // auto-deref the fresh reference); everything else reads through references as usual.
        let tk = self.ast_ptr(r2.m).type_at(r2.t).kind;
        let mut o = cv_nil();
        if tk == TypeKind::TYPE_POINTER {
            o = self.ev_in(f, m, expr);
        } else {
            o = self.ev_rval(f, m, expr);
        }
        if o.kind == CV_NIL_K {
            return cv_nil();
        }
        let y = *self.ast_ptr(r2.m).type_at(r2.t);
        if y.kind == TypeKind::TYPE_POINTER {
            if o.kind != CV_PTR {
                return cv_nil();
            }
            let mut v = o;
            v.tm = m;
            v.ty = rt;
            let er = self.ce_rtype(f, r2.m, y.as_data.elem);
            if !er.ok {
                return cv_nil();
            }
            if type_builtin(self.ast_ptr(er.m), er.t) == BuiltinType::BT_VOID {
                return v;
            }
            let blk = self.obj_ptr(o.as_data.p.obj);
            if blk == null {
                return v;
            }
            if unsafe blk.heap != 0 && unsafe blk.et == TYPE_NONE && o.as_data.p.off == 0 {
                let lay = self.ce_layout_f(f, er.m, er.t);
                if !lay.ok || lay.size == 0 {
                    return cv_nil();
                }
                let bytes = unsafe blk.bytes;
                if bytes % lay.size != 0 {
                    return cv_nil();
                }
                if !self.ce_obj_resize(o.as_data.p.obj, (bytes / lay.size) as u32) {
                    return cv_nil();
                }
                let blk2 = self.obj_ptr(o.as_data.p.obj);
                unsafe blk2.em = er.m;
                unsafe blk2.et = er.t;
                unsafe blk2.esz = lay.size;
                return v;
            }
            if unsafe blk.et != TYPE_NONE && !self.ce_teq(unsafe blk.em, unsafe blk.et, er.m, er.t) {
                return cv_nil();
            }
            return v;
        }
        let mut b = BuiltinType::BT_COUNT;
        if y.kind == TypeKind::TYPE_BUILTIN {
            b = y.as_data.builtin;
        }
        if b == BuiltinType::BT_COUNT || b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64 || b == BuiltinType::BT_BOOL || b == BuiltinType::BT_VALIST || b == BuiltinType::BT_VOID {
            return cv_nil();
        }
        if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 {
            let mut v: f64 = 0.0;
            if o.kind == CV_FLOAT {
                v = o.as_data.f;
            } else if o.kind == CV_INT {
                let ob = self.ce_builtin_of(f, m, self.ce_type(m, expr));
                if ob != BuiltinType::BT_COUNT && bt_unsigned(ob) {
                    v = (o.as_data.i as u64) as f64;
                } else {
                    v = o.as_data.i as f64;
                }
            } else {
                return cv_nil();
            }
            if b == BuiltinType::BT_F32 {
                v = v as f32;
            }
            return CeVal { kind: CV_FLOAT, tm: m, ty: rt, as_data: CeValAs { f: v } };
        }
        if o.kind == CV_FLOAT {
            if !ce_isfinite(o.as_data.f) {
                return cv_nil();
            }
            let t = unsafe math::trunc(o.as_data.f);
            if t < -9.3e18 || t > 1.8e19 {
                return cv_nil();
            }
            let mut iv: i64 = t as i64;
            if bt_unsigned(b) {
                iv = (t as u64) as i64;
            }
            if !fits(b, iv) && bt_bits(b) < 64 {
                return cv_nil();
            }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: wrap_to(b, iv) } };
        }
        if o.kind == CV_BOOL || o.kind == CV_INT {
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: wrap_to(b, o.as_data.i) } };
        }
        return cv_nil();
    }

    fn ev_binary(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let n = a.at_const(id);
        let op = n.as_data.binary.op;
        let left = n.as_data.binary.left;
        let right = n.as_data.binary.right;
        let rt = self.ce_type(m, id);
        let sr = self.ce_strip_refptr(f, m, self.ce_type(m, left));
        if sr.ok {
            let lyk = self.ast_ptr(sr.m).type_at(sr.t).kind;
            if lyk == TypeKind::TYPE_STRUCT || lyk == TypeKind::TYPE_INSTANCE {
                let mut mn: str = "";
                if op == TokenType::Plus {
                    mn = "add";
                } else if op == TokenType::Minus {
                    mn = "sub";
                } else if op == TokenType::Star {
                    mn = "mul";
                } else if op == TokenType::Slash {
                    mn = "div";
                } else if op == TokenType::Percent {
                    mn = "rem";
                } else if op == TokenType::EqualEqual || op == TokenType::BangEqual {
                    mn = "eq";
                } else if op == TokenType::LessThan || op == TokenType::LessThanEqual || op == TokenType::GreaterThan || op == TokenType::GreaterThanEqual {
                    mn = "cmp";
                } else if op == TokenType::LeftShift {
                    mn = "shl";
                } else if op == TokenType::RightShift {
                    mn = "shr";
                } else if op == TokenType::Ampersand {
                    mn = "bit_and";
                } else if op == TokenType::Pipe {
                    mn = "bit_or";
                } else if op == TokenType::Caret {
                    mn = "bit_xor";
                }
                // Every operator an aggregate can overload maps to its method above, so an aggregate
                // operand never reaches the scalar fold below -- where a coerced literal's 64-bit
                // value would stand in for the aggregate and fold to a wrong number (or trap a shift
                // that is in range at the aggregate's width).
                if mn.len() != 0 {
                    let rr = self.ce_recv_of(f, sr.m, sr.t);
                    if !rr.ok {
                        return cv_nil();
                    }
                    let mut lhs = cv_nil();
                    let was_lp = self.trap_mark();
                    let lp = self.ev_place(f, m, left);
                    if lp.ok {
                        lhs = lp.v;
                    } else {
                        self.trap_discard(was_lp);
                        let lv = self.ev_in(f, m, left);
                        let tr = self.ce_temp_place(lv);
                        if lv.kind == CV_NIL_K || !tr.ok {
                            return cv_nil();
                        }
                        lhs = tr.v;
                    }
                    let mut rhs = cv_nil();
                    let was_rp = self.trap_mark();
                    let rp = self.ev_place(f, m, right);
                    if rp.ok {
                        rhs = rp.v;
                    } else {
                        self.trap_discard(was_rp);
                        let rv = self.ev_rval(f, m, right);
                        let tr = self.ce_temp_place(rv);
                        if rv.kind == CV_NIL_K || !tr.ok {
                            return cv_nil();
                        }
                        rhs = tr.v;
                    }
                    let mut args: [CeVal; 8] = [
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                    ];
                    args[0] = lhs;
                    args[1] = rhs;
                    let dr = self.ce_dispatch(rr.r, m, mn, &args[0], 2);
                    if !dr.ok {
                        return cv_nil();
                    }
                    let mut res = dr.v;
                    if op == TokenType::EqualEqual || op == TokenType::BangEqual {
                        if res.kind != CV_BOOL {
                            return cv_nil();
                        }
                        if op == TokenType::BangEqual {
                            res.as_data.i = if_i64(res.as_data.i == 0, 1, 0);
                        }
                        res.tm = m;
                        res.ty = rt;
                        return res;
                    }
                    if mn.byte_at(0) == b'c' {
                        if res.kind != CV_INT {
                            return cv_nil();
                        }
                        let c = res.as_data.i;
                        let mut v: i64 = 0;
                        if op == TokenType::LessThan {
                            v = if_i64(c < 0, 1, 0);
                        } else if op == TokenType::LessThanEqual {
                            v = if_i64(c <= 0, 1, 0);
                        } else if op == TokenType::GreaterThan {
                            v = if_i64(c > 0, 1, 0);
                        } else {
                            v = if_i64(c >= 0, 1, 0);
                        }
                        return CeVal { kind: CV_BOOL, tm: m, ty: rt, as_data: CeValAs { i: v } };
                    }
                    return res;
                }
            }
        }
        let l = self.ev_rval(f, m, left);
        if l.kind == CV_NIL_K {
            return cv_nil();
        }
        // A short-circuited RHS never executes at runtime: still evaluated (fold result unchanged),
        // but any trap it leaves is speculative and gets scrubbed.
        let dead_rhs = l.kind == CV_BOOL && (op == TokenType::AmpersandAmpersand && l.as_data.i == 0 || op == TokenType::PipePipe && l.as_data.i != 0);
        let was = self.trap_mark();
        let r = self.ev_rval(f, m, right);
        if dead_rhs {
            self.trap_discard(was);
        }
        if r.kind == CV_NIL_K {
            return cv_nil();
        }
        if l.kind == CV_PTR || r.kind == CV_PTR {
            if op == TokenType::EqualEqual || op == TokenType::BangEqual {
                if l.kind != CV_PTR || r.kind != CV_PTR {
                    return cv_nil();
                }
                let eq = l.as_data.p.obj == r.as_data.p.obj && l.as_data.p.off == r.as_data.p.off;
                let mut vv = eq;
                if op == TokenType::BangEqual {
                    vv = !eq;
                }
                return cv_bool(m, rt, vv);
            }
            if (op == TokenType::Plus || op == TokenType::Minus) && l.kind == CV_PTR && r.kind == CV_INT {
                let mut v = l;
                v.tm = m;
                v.ty = rt;
                if op == TokenType::Plus {
                    v.as_data.p.off = v.as_data.p.off + r.as_data.i as u32;
                } else {
                    v.as_data.p.off = v.as_data.p.off - r.as_data.i as u32;
                }
                return v;
            }
            if op == TokenType::Plus && r.kind == CV_PTR && l.kind == CV_INT {
                let mut v = r;
                v.tm = m;
                v.ty = rt;
                v.as_data.p.off = v.as_data.p.off + l.as_data.i as u32;
                return v;
            }
            return cv_nil();
        }
        if l.kind == CV_BOOL && r.kind == CV_BOOL {
            if op == TokenType::AmpersandAmpersand {
                return cv_bool(m, rt, l.as_data.i != 0 && r.as_data.i != 0);
            }
            if op == TokenType::PipePipe {
                return cv_bool(m, rt, l.as_data.i != 0 || r.as_data.i != 0);
            }
            if op == TokenType::EqualEqual {
                return cv_bool(m, rt, l.as_data.i == r.as_data.i);
            }
            if op == TokenType::BangEqual {
                return cv_bool(m, rt, l.as_data.i != r.as_data.i);
            }
            return cv_nil();
        }
        if l.kind == CV_FLOAT && r.kind == CV_FLOAT {
            return ce_float_op(op, l, r, m, rt, self.ce_builtin_of(f, m, rt));
        }
        if l.kind != CV_INT || r.kind != CV_INT {
            return cv_nil();
        }
        let rb = self.ce_builtin_of(f, m, rt);
        let lb = self.ce_builtin_of(f, m, self.ce_type(m, left));
        let mut ob = lb;
        if op != TokenType::LeftShift && op != TokenType::RightShift {
            let mut lbc = lb;
            if lb == BuiltinType::BT_COUNT {
                lbc = rb;
            }
            ob = ce_arith_common(lbc, self.ce_builtin_of(f, m, self.ce_type(m, right)));
        }
        return self.ce_int_op(op, l, r, m, rt, rb, ob);
    }
}

const fn if_i64(c: bool, a: i64, b: i64) i64 {
    if c {
        return a;
    }
    return b;
}

extend ConstEval {
    fn ev_block(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let stmts = a.at_const(id).as_data.block.statements;
        if f == null || stmts.len == 0 {
            return cv_nil();
        }
        let dbase = unsafe f.ndefers;
        let mut out = cv_nil();
        let mut ok = true;
        let mut i: u32 = 0;
        while ok && i + 1 < stmts.len {
            let sid = unsafe a.list(stmts)[i as usize];
            ok = self.exec_stmt(f, m, sid) == Flow::Ok;
            i = i + 1;
        }
        if ok {
            let lastid = unsafe a.list(stmts)[(stmts.len - 1) as usize];
            let last = a.at_const(lastid);
            if last.kind == NodeKind::NODE_EXPRESSION_STATEMENT && a.at_const(last.as_data.single.value).kind != NodeKind::NODE_ASSIGNMENT {
                out = self.ev_in(f, m, last.as_data.single.value);
            }
        }
        let mut j = unsafe f.ndefers;
        while j > dbase {
            j = j - 1;
            let dv = unsafe f.defers[j as usize];
            let dk = a.at_const(dv).kind;
            let mut ds = Flow::Ok;
            if dk == NodeKind::NODE_BLOCK {
                ds = self.exec_stmt(f, m, dv);
            } else {
                ds = self.exec_expr_stmt(f, m, dv);
            }
            if ds != Flow::Ok {
                out = cv_nil();
            }
        }
        unsafe f.ndefers = dbase;
        return out;
    }

    fn ev_index(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let obj_n = a.at_const(id).as_data.index.object;
        let index_n = a.at_const(id).as_data.index.index;
        let mut bm = m;
        let mut bt = self.ce_type(m, obj_n);
        for _ in 0..4 {
            let r = self.ce_rtype(f, bm, bt);
            if !r.ok {
                return cv_nil();
            }
            bm = r.m;
            bt = r.t;
            let y = self.ast_ptr(bm).type_at(bt);
            if y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            bt = y.as_data.elem;
        }
        let yk = self.ast_ptr(bm).type_at(bt).kind;
        if yk == TypeKind::TYPE_STRUCT || yk == TypeKind::TYPE_INSTANCE {
            let rr = self.ce_recv_of(f, bm, bt);
            if !rr.ok {
                return cv_nil();
            }
            let mut recv = cv_nil();
            let was_rp = self.trap_mark();
            let rp = self.ev_place(f, m, obj_n);
            if rp.ok {
                recv = rp.v;
            } else {
                self.trap_discard(was_rp);
                let rv = self.ev_in(f, m, obj_n);
                let tr = self.ce_temp_place(rv);
                if rv.kind == CV_NIL_K || !tr.ok {
                    return cv_nil();
                }
                recv = tr.v;
            }
            if a.at_const(index_n).kind == NodeKind::NODE_RANGE {
                let iv = self.ce_range_obj(f, m, index_n);
                if iv.kind != CV_AGG {
                    return cv_nil();
                }
                let mut args: [CeVal; 8] = [
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                    cv_nil(),
                ];
                args[0] = recv;
                args[1] = iv;
                let dr = self.ce_dispatch(rr.r, m, "index_range", &args[0], 2);
                if !dr.ok || dr.v.kind != CV_AGG {
                    return cv_nil();
                }
                return dr.v;
            }
            let iv = self.ev_rval(f, m, index_n);
            if iv.kind != CV_INT {
                return cv_nil();
            }
            let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            args[0] = recv;
            args[1] = iv;
            let dr = self.ce_dispatch(rr.r, m, "index", &args[0], 2);
            if !dr.ok || dr.v.kind != CV_PTR {
                return cv_nil();
            }
            let lr = self.ce_loadp(dr.v);
            if !lr.ok {
                return cv_nil();
            }
            return lr.v;
        }
        let pr = self.ev_place(f, m, id);
        if !pr.ok {
            return cv_nil();
        }
        let lr = self.ce_loadp(pr.v);
        if !lr.ok {
            return cv_nil();
        }
        return lr.v;
    }

    // A substitution-only frame (no env) from a receiver's concrete generic args, so decl-side
    // type nodes can be resolved against the instance (incl. const-generic values).
    fn ce_recv_frame(self: &Self, r: &CeRecv) CeFrame {
        let mut g = ce_frame_zero();
        if r.dn == NODE_NONE || r.n == 0 {
            return g;
        }
        let da = self.ast_ptr(r.dm);
        let gens = da.at_const(r.dn).as_data.aggregate.generics;
        let gids = da.list(gens);
        g.pmod = r.dm;
        let mut i: u32 = 0;
        while i < gens.len && i < r.n as u32 && g.ng as u32 < 8 {
            let ng = g.ng;
            unsafe g.params_g[ng as usize] = unsafe gids[i as usize];
            unsafe g.am[ng as usize] = unsafe r.am[i as usize];
            unsafe g.at[ng as usize] = unsafe r.at[i as usize];
            g.ng = ng + 1;
            i = i + 1;
        }
        return g;
    }

    // Zero value for a field TYPE NODE under a substitution frame. Resolves a symbolic
    // const-generic array length ([T; N]) from the node's length expression, since the interned
    // TYPE_ARRAY of a generic decl carries len 0.
    fn ce_zero_node(self: &mut Self, f: *mut CeFrame, m: ModuleId, tyNode: NodeId, depth: i32) CeVal {
        if tyNode == NODE_NONE || depth > CE_MAX_DEPTH {
            return cv_nil();
        }
        let t = self.ce_type(m, tyNode);
        if t == TYPE_NONE {
            return cv_nil();
        }
        let a = self.ast_ptr(m);
        if a.at_const(tyNode).kind == NodeKind::NODE_ARRAY_TYPE {
            let y = a.type_at(t);
            if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len == 0 {
                let lenNode = a.at_const(tyNode).as_data.array_type.length;
                let elemNode = a.at_const(tyNode).as_data.array_type.element;
                let lv = self.ev_in(f, m, lenNode);
                if lv.kind != CV_INT || lv.as_data.i <= 0 || lv.as_data.i > 0xFFFFFFFFi64 {
                    return cv_nil();
                }
                let e = self.ce_subst_deep(f, m, self.ce_type(m, elemNode), depth + 1);
                if e == TYPE_NONE {
                    return cv_nil();
                }
                let nt = self.mut_ast_ptr(m).intern_type(
                    Ty {
                        kind: TypeKind::TYPE_ARRAY,
                        as_data: TyAs { arr: TyArr { elem: e, len: lv.as_data.i as u32 } },
                    },
                );
                return self.ce_zero(m, nt, depth);
            }
        }
        let ct = self.ce_subst_deep(f, m, t, depth);
        if ct == TYPE_NONE {
            return cv_nil();
        }
        return self.ce_zero(m, ct, depth);
    }

    fn ev_struct_init(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let tn = a.at_const(id).as_data.struct_initializer.ty;
        let fields = a.at_const(id).as_data.struct_initializer.fields;
        let rt = self.ce_type(m, id);
        // A '@no_const' value can never exist at compile time; refusing construction here is the
        // evaluator-side backstop behind the fx-scan disqualification.
        if self.ce_ty_no_const(m, rt, 0) {
            return cv_nil();
        }
        // enum struct-payload variant: `Variant { .. }`
        let mut vd = a.resolution_def(tn);
        if vd.node == NODE_NONE {
            vd = DefId { module: m, node: a.resolution(tn) };
        }
        if vd.node != NODE_NONE && vd.module as usize < self.nmods && self.ast_ptr(vd.module).at_const(vd.node).kind == NodeKind::NODE_ENUM && a.at_const(
            tn,
        ).kind == NodeKind::NODE_TYPE_PATH && a.at_const(tn).as_data.type_path.parts.len >= 2 {
            let parts = a.at_const(tn).as_data.type_path.parts;
            let last = unsafe a.list(parts)[(parts.len - 1) as usize];
            let vn = self.name_text(m, last);
            let ea = self.ast_ptr(vd.module);
            let ms = ea.at_const(vd.node).as_data.aggregate.members;
            let mut hit = NODE_NONE;
            for k in 0..ms.len {
                let mid = unsafe ea.list(ms)[k as usize];
                let vname = self.name_text(vd.module, ea.at_const(mid).as_data.variant.name);
                if self.ce_spans_eq(vd.module, vname, m, vn) {
                    hit = mid;
                    break;
                }
            }
            if hit != NODE_NONE {
                vd.node = hit;
            }
        }
        if vd.node != NODE_NONE && vd.module as usize < self.nmods && self.ast_ptr(vd.module).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
            let vp = self.ce_variant_pos(vd.module, vd.node);
            let payload = self.ast_ptr(vd.module).at_const(vd.node).as_data.variant.payload;
            let struct_payload = self.ast_ptr(vd.module).at_const(vd.node).as_data.variant.struct_payload;
            if vp.pos < 0 || !struct_payload || self.ce_user_free(vd.module, vp.enum_decl) {
                return cv_nil();
            }
            let o = self.ce_obj_new(1 + payload.len);
            if o == 0 {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).is_enum = 1;
            unsafe self.obj_ptr(o).dm = vd.module;
            unsafe self.obj_ptr(o).dn = vp.enum_decl;
            unsafe self.obj_ptr(o).slots.set(
                0,
                CeVal { kind: CV_INT, tm: 0, ty: TYPE_NONE, as_data: CeValAs { i: vp.pos } },
            );
            let da = self.ast_ptr(vd.module);
            for i in 0..fields.len {
                let fid = unsafe a.list(fields)[i as usize];
                let fkind = a.at_const(fid).kind;
                let fname_node = a.at_const(fid).as_data.field_initializer.name;
                if fkind != NodeKind::NODE_FIELD_INITIALIZER || fname_node == NODE_NONE {
                    return cv_nil();
                }
                let mut slot: i32 = -1;
                for j in 0..payload.len {
                    let pfid = unsafe da.list(payload)[j as usize];
                    if da.at_const(pfid).kind == NodeKind::NODE_FIELD {
                        let pfname = self.name_text(vd.module, da.at_const(pfid).as_data.field.name);
                        if self.ce_spans_eq(vd.module, pfname, m, self.name_text(m, fname_node)) {
                            slot = j as i32;
                            break;
                        }
                    }
                }
                let v = self.ev_rval(f, m, a.at_const(fid).as_data.field_initializer.value);
                if slot < 0 || v.kind == CV_NIL_K {
                    return cv_nil();
                }
                let cloned = self.ce_clone(v, 0);
                if cloned.kind == CV_NIL_K {
                    return cv_nil();
                }
                unsafe self.obj_ptr(o).slots.set((1 + slot) as usize, cloned);
            }
            return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
        }
        let rr = self.ce_recv_of(f, m, rt);
        if !rr.ok || rr.r.dn == NODE_NONE {
            return cv_nil();
        }
        let da = self.ast_ptr(rr.r.dm);
        let dkind = da.at_const(rr.r.dn).kind;
        let is_union = da.at_const(rr.r.dn).as_data.aggregate.is_union;
        if dkind != NodeKind::NODE_STRUCT {
            return cv_nil();
        }
        // A union literal names exactly ONE member, and that member is what the value holds: record
        // which, so a later read through a DIFFERENT member is refused rather than answered with a
        // slot nothing ever wrote.
        if is_union && fields.len != 1 {
            return cv_nil();
        }
        if self.ce_user_free(rr.r.dm, rr.r.dn) {
            return cv_nil();
        }
        let o = self.ce_obj_new(self.ce_field_count(rr.r.dm, rr.r.dn));
        if o == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(o).dm = rr.r.dm;
        unsafe self.obj_ptr(o).dn = rr.r.dn;
        unsafe self.obj_ptr(o).nargs = rr.r.n;
        for ci in 0..4 {
            unsafe self.obj_ptr(o).am[ci] = unsafe rr.r.am[ci];
            unsafe self.obj_ptr(o).at[ci] = unsafe rr.r.at[ci];
        }
        for i in 0..fields.len {
            let fid = unsafe a.list(fields)[i as usize];
            let fkind = a.at_const(fid).kind;
            let fname_node = a.at_const(fid).as_data.field_initializer.name;
            if fkind != NodeKind::NODE_FIELD_INITIALIZER || fname_node == NODE_NONE {
                return cv_nil();
            }
            let fname = self.name_text(m, fname_node);
            let fi = self.ce_field_index(rr.r.dm, rr.r.dn, m, fname);
            if fi.idx < 0 {
                return cv_nil();
            }
            let v = self.ev_rval(f, m, a.at_const(fid).as_data.field_initializer.value);
            if v.kind == CV_NIL_K {
                return cv_nil();
            }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).slots.set(fi.idx as usize, cloned);
            if is_union {
                unsafe self.obj_ptr(o).uactive = fi.idx;
            }
        }
        // a union holds ONE member: the others are not zero, they are simply not there
        if is_union {
            return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
        }
        // remaining fields: decl-side default, else zero-initialized (a partial struct literal
        // zero-fills in C; the zero is built from the field's TYPE NODE so const-generic array
        // lengths resolve through the receiver's args)
        let ms = da.at_const(rr.r.dn).as_data.aggregate.members;
        let mut idx: i32 = 0;
        for k in 0..ms.len {
            let fd = unsafe da.list(ms)[k as usize];
            if da.at_const(fd).kind == NodeKind::NODE_FIELD {
                if unsafe self.obj_ptr(o).slots[idx as usize].kind == CV_NIL_K {
                    let fval = da.at_const(fd).as_data.field.value;
                    if fval == NODE_NONE {
                        let mut g = self.ce_recv_frame(&rr.r);
                        let z = self.ce_zero_node(&mut g, rr.r.dm, da.at_const(fd).as_data.field.ty, 0);
                        if z.kind == CV_NIL_K {
                            return cv_nil();
                        }
                        unsafe self.obj_ptr(o).slots.set(idx as usize, z);
                    } else {
                        let v = self.ev_in(null, rr.r.dm, fval);
                        if v.kind == CV_NIL_K {
                            return cv_nil();
                        }
                        let cloned = self.ce_clone(v, 0);
                        unsafe self.obj_ptr(o).slots.set(idx as usize, cloned);
                    }
                }
                idx = idx + 1;
            }
        }
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    fn ev_array_lit(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let elements = a.at_const(id).as_data.array_literal.elements;
        let rt = self.ce_type(m, id);
        let r2 = self.ce_rtype(f, m, rt);
        if !r2.ok {
            return cv_nil();
        }
        let y = *self.ast_ptr(r2.m).type_at(r2.t);
        // A literal in a slice position keeps the SLICE as its node type (the typechecker rewrites it
        // there so codegen builds the fat value), so the array shape has to be recovered from the
        // slice's element type. Without this every `f([1, 2, 3])` with a `[]T` parameter was
        // unevaluable, and any constant built from one silently failed to fold.
        if y.kind == TypeKind::TYPE_INSTANCE {
            return self.ev_slice_lit(f, m, id, r2.m, r2.t, rt);
        }
        if y.kind != TypeKind::TYPE_ARRAY {
            return cv_nil();
        }
        let count = elements.len;
        let mut len = y.as_data.arr.len;
        if len == 0 {
            len = count;
            let mut cur: u32 = 0;
            for i in 0..count {
                let el = unsafe a.list(elements)[i as usize];
                if a.at_const(el).kind == NodeKind::NODE_FIELD_INITIALIZER {
                    let iv = self.ev_in(null, m, a.at_const(el).as_data.field_initializer.name);
                    if iv.kind != CV_INT || iv.as_data.i < 0 {
                        return cv_nil();
                    }
                    cur = iv.as_data.i as u32;
                }
                cur = cur + 1;
                if cur > len {
                    len = cur;
                }
            }
        }
        let o = self.ce_obj_new(len);
        if o == 0 {
            return cv_nil();
        }
        if count < len {
            let er = self.ce_rtype(f, r2.m, y.as_data.arr.elem);
            if !er.ok {
                return cv_nil();
            }
            let z = self.ce_zero(er.m, er.t, 0);
            if z.kind == CV_NIL_K {
                return cv_nil();
            }
            for i in 0..len {
                let cloned = self.ce_clone(z, 0);
                unsafe self.obj_ptr(o).slots.set(i as usize, cloned);
            }
        }
        let mut cursor: u32 = 0;
        for i in 0..count {
            let el = unsafe a.list(elements)[i as usize];
            let mut value = el;
            if a.at_const(el).kind == NodeKind::NODE_FIELD_INITIALIZER {
                let iv = self.ev_in(null, m, a.at_const(el).as_data.field_initializer.name);
                if iv.kind != CV_INT || iv.as_data.i < 0 {
                    return cv_nil();
                }
                cursor = iv.as_data.i as u32;
                value = a.at_const(el).as_data.field_initializer.value;
            }
            if cursor >= len {
                return cv_nil();
            }
            let v = self.ev_rval(f, m, value);
            if v.kind == CV_NIL_K {
                return cv_nil();
            }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).slots.set(cursor as usize, cloned);
            cursor = cursor + 1;
        }
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    // `[a, b, c]` written where a `[]T` is wanted: evaluate the elements into an array object, then
    // wrap it in the two-slot Slice (pointer + length) that ce_coerce builds for a named array.
    fn ev_slice_lit(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId, sm: ModuleId, st: TypeId, rt: TypeId) CeVal {
        let a = self.ast_ptr(m);
        let elements = a.at_const(id).as_data.array_literal.elements;
        let sy = *self.ast_ptr(sm).type_at(st);
        let it = *self.ast_ptr(sm).instance(sy.as_data.inst);
        let da = self.ast_ptr(it.module);
        let dn = self.name_text(it.module, da.at_const(it.decl).as_data.aggregate.name);
        if !self.ce_span_is(it.module, dn, "Slice") && !self.ce_span_is(it.module, dn, "SliceMut") {
            return cv_nil();
        }
        let count = elements.len;
        let o = self.ce_obj_new(count);
        if o == 0 {
            return cv_nil();
        }
        for i in 0..count {
            let el = unsafe a.list(elements)[i as usize];
            if a.at_const(el).kind == NodeKind::NODE_FIELD_INITIALIZER {
                return cv_nil(); // a designated initializer has no slice meaning
            }
            let v = self.ev_rval(f, m, el);
            if v.kind == CV_NIL_K {
                return cv_nil();
            }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).slots.set(i as usize, cloned);
        }
        let so = self.ce_obj_new(2);
        if so == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(so).dm = it.module;
        unsafe self.obj_ptr(so).dn = it.decl;
        unsafe self.obj_ptr(so).slots.set(
            0,
            CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } },
        );
        unsafe self.obj_ptr(so).slots.set(
            1,
            CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: count } },
        );
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
    }

    fn ev_tuple(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let elements = a.at_const(id).as_data.array_literal.elements;
        let rt = self.ce_type(m, id);
        let rr = self.ce_recv_of(f, m, rt);
        if !rr.ok || rr.r.dn == NODE_NONE {
            return cv_nil();
        }
        let count = elements.len;
        let o = self.ce_obj_new(count);
        if o == 0 {
            return cv_nil();
        }
        unsafe self.obj_ptr(o).dm = rr.r.dm;
        unsafe self.obj_ptr(o).dn = rr.r.dn;
        unsafe self.obj_ptr(o).nargs = rr.r.n;
        for ci in 0..4 {
            unsafe self.obj_ptr(o).am[ci] = unsafe rr.r.am[ci];
            unsafe self.obj_ptr(o).at[ci] = unsafe rr.r.at[ci];
        }
        for i in 0..count {
            let el = unsafe a.list(elements)[i as usize];
            let v = self.ev_rval(f, m, el);
            if v.kind == CV_NIL_K {
                return cv_nil();
            }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K {
                return cv_nil();
            }
            unsafe self.obj_ptr(o).slots.set(i as usize, cloned);
        }
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    // --- patterns and switch ---
    // Returns 1 = match (bindings applied), 0 = no match, -1 = unfoldable.
    fn pat_match(self: &mut Self, f: *mut CeFrame, m: ModuleId, pid: NodeId, v: CeVal, uns: bool, refobj: u32) i32 {
        let a = self.ast_ptr(m);
        let pk = a.at_const(pid).kind;
        if pk == NodeKind::NODE_PATTERN_WILDCARD {
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_NAME {
            let name_node = a.at_const(pid).as_data.pattern.name;
            let d = a.resolution_def(name_node);
            if d.node != NODE_NONE && d.module as usize < self.nmods && self.ast_ptr(d.module).at_const(d.node).kind == NodeKind::NODE_VARIANT {
                if v.kind == CV_INT || v.kind == CV_BOOL {
                    let tv = self.variant_value(d.module, d.node);
                    if tv.kind == CONST_INT {
                        return if_i32(tv.as_data.i == v.as_data.i, 1, 0);
                    }
                    return -1;
                }
                if v.kind == CV_AGG {
                    let o = self.obj_ptr(v.as_data.p.obj);
                    let vp = self.ce_variant_pos(d.module, d.node);
                    if o != null && unsafe o.is_enum != 0 && vp.pos >= 0 {
                        return if_i32(unsafe o.slots[0].as_data.i == vp.pos as i64, 1, 0);
                    }
                    return -1;
                }
                return -1;
            }
            if !(f != null && self.ce_bind(f, pid, v)) {
                return -1;
            }
            let children = a.at_const(pid).as_data.pattern.children;
            if children.len != 0 {
                let sub = unsafe a.list(children)[0];
                return self.pat_match(f, m, sub, v, uns, refobj);
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_LITERAL {
            let lv = self.ev_in(null, m, a.at_const(pid).as_data.single.value);
            if lv.kind != CV_INT && lv.kind != CV_BOOL {
                return -1;
            }
            return if_i32(lv.as_data.i == v.as_data.i && (v.kind == CV_INT || v.kind == CV_BOOL), 1, 0);
        }
        if pk == NodeKind::NODE_PATTERN_RANGE {
            if v.kind != CV_INT {
                return -1;
            }
            let start_n = a.at_const(pid).as_data.pattern_range.start;
            let end_n = a.at_const(pid).as_data.pattern_range.end;
            let inclusive = a.at_const(pid).as_data.pattern_range.inclusive;
            if start_n != NODE_NONE {
                let mut sn = start_n;
                if a.at_const(start_n).kind == NodeKind::NODE_PATTERN_LITERAL {
                    sn = a.at_const(start_n).as_data.single.value;
                }
                let s = self.ev_in(null, m, sn);
                if s.kind != CV_INT {
                    return -1;
                }
                let below = if_bool(uns, v.as_data.i as u64 < s.as_data.i as u64, v.as_data.i < s.as_data.i);
                if below {
                    return 0;
                }
            }
            if end_n != NODE_NONE {
                let mut en = end_n;
                if a.at_const(end_n).kind == NodeKind::NODE_PATTERN_LITERAL {
                    en = a.at_const(end_n).as_data.single.value;
                }
                let e = self.ev_in(null, m, en);
                if e.kind != CV_INT {
                    return -1;
                }
                let mut above = false;
                if inclusive {
                    above = if_bool(uns, v.as_data.i as u64 > e.as_data.i as u64, v.as_data.i > e.as_data.i);
                } else {
                    above = if_bool(uns, v.as_data.i as u64 >= e.as_data.i as u64, v.as_data.i >= e.as_data.i);
                }
                if above {
                    return 0;
                }
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_OR {
            let children = a.at_const(pid).as_data.pattern.children;
            for i in 0..children.len {
                let cid = unsafe a.list(children)[i as usize];
                let was = self.trap_mark();
                let r = self.pat_match(f, m, cid, v, uns, refobj);
                if r != 0 {
                    return r;
                }
                self.trap_discard(was);
            }
            return 0;
        }
        if pk == NodeKind::NODE_PATTERN_TUPLE {
            let pname = a.at_const(pid).as_data.pattern.name;
            let children = a.at_const(pid).as_data.pattern.children;
            if pname == NODE_NONE {
                if children.len == 1 {
                    return self.pat_match(f, m, unsafe a.list(children)[0], v, uns, refobj);
                }
                return -1;
            }
            if v.kind != CV_AGG {
                return -1;
            }
            let d = a.resolution_def(pname);
            if d.node == NODE_NONE || self.ast_ptr(d.module).at_const(d.node).kind != NodeKind::NODE_VARIANT {
                return -1;
            }
            let o = self.obj_ptr(v.as_data.p.obj);
            let vp = self.ce_variant_pos(d.module, d.node);
            if o == null || unsafe o.is_enum == 0 || vp.pos < 0 {
                return -1;
            }
            if unsafe o.slots[0].as_data.i != vp.pos as i64 {
                return 0;
            }
            for k in 0..children.len {
                let cid = unsafe a.list(children)[k as usize];
                if 1 + k >= (unsafe self.obj_ptr(v.as_data.p.obj).slots.len()) as u32 {
                    return -1;
                }
                if refobj != 0 && a.at_const(cid).kind == NodeKind::NODE_PATTERN_NAME && a.resolution_def(
                    a.at_const(cid).as_data.pattern.name,
                ).node == NODE_NONE {
                    let pv = CeVal {
                        kind: CV_PTR,
                        tm: 0,
                        ty: TYPE_NONE,
                        as_data: CeValAs { p: CvPtr { obj: refobj, off: 1 + k } },
                    };
                    if f == null || !self.ce_bind(f, cid, pv) {
                        return -1;
                    }
                    continue;
                }
                let sv = unsafe self.obj_ptr(v.as_data.p.obj).slots[(1 + k) as usize];
                if sv.kind == CV_NIL_K {
                    return -1;
                }
                let r = self.pat_match(f, m, cid, sv, uns, 0);
                if r != 1 {
                    return r;
                }
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_STRUCT {
            let pname = a.at_const(pid).as_data.pattern.name;
            if v.kind != CV_AGG || pname == NODE_NONE {
                return -1;
            }
            let d = a.resolution_def(pname);
            if d.node == NODE_NONE || self.ast_ptr(d.module).at_const(d.node).kind != NodeKind::NODE_VARIANT {
                return -1;
            }
            let o = self.obj_ptr(v.as_data.p.obj);
            let vp = self.ce_variant_pos(d.module, d.node);
            if o == null || unsafe o.is_enum == 0 || vp.pos < 0 {
                return -1;
            }
            if unsafe o.slots[0].as_data.i != vp.pos as i64 {
                return 0;
            }
            let da = self.ast_ptr(d.module);
            let vpayload = da.at_const(d.node).as_data.variant.payload;
            if !da.at_const(d.node).as_data.variant.struct_payload {
                return -1;
            }
            let children = a.at_const(pid).as_data.pattern.children;
            for k in 0..children.len {
                let cid = unsafe a.list(children)[k as usize];
                let pfname = a.at_const(cid).as_data.pattern.name;
                if a.at_const(cid).kind != NodeKind::NODE_PATTERN_FIELD || pfname == NODE_NONE {
                    return -1;
                }
                let mut slot: i32 = -1;
                for j in 0..vpayload.len {
                    let pfid = unsafe da.list(vpayload)[j as usize];
                    if da.at_const(pfid).kind == NodeKind::NODE_FIELD {
                        let fn2 = self.name_text(d.module, da.at_const(pfid).as_data.field.name);
                        if self.ce_spans_eq(d.module, fn2, m, self.name_text(m, pfname)) {
                            slot = j as i32;
                            break;
                        }
                    }
                }
                if slot < 0 || 1 + slot as u32 >= (unsafe self.obj_ptr(v.as_data.p.obj).slots.len()) as u32 {
                    return -1;
                }
                let child = unsafe a.list(a.at_const(cid).as_data.pattern.children)[0];
                if refobj != 0 && a.at_const(child).kind == NodeKind::NODE_IDENTIFIER {
                    let pv = CeVal {
                        kind: CV_PTR,
                        tm: 0,
                        ty: TYPE_NONE,
                        as_data: CeValAs { p: CvPtr { obj: refobj, off: 1 + slot as u32 } },
                    };
                    if f == null || !self.ce_bind(f, child, pv) {
                        return -1;
                    }
                    continue;
                }
                let sv = unsafe self.obj_ptr(v.as_data.p.obj).slots[(1 + slot) as usize];
                if sv.kind == CV_NIL_K {
                    return -1;
                }
                if a.at_const(child).kind == NodeKind::NODE_IDENTIFIER {
                    if f == null || !self.ce_bind(f, child, sv) {
                        return -1;
                    }
                    continue;
                }
                let r = self.pat_match(f, m, child, sv, uns, 0);
                if r != 1 {
                    return r;
                }
            }
            return 1;
        }
        return -1;
    }

    fn exec_match(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId, out: *mut CeVal) Flow {
        let a = self.ast_ptr(m);
        let value_n = a.at_const(id).as_data.match_expr.value;
        let arms = a.at_const(id).as_data.match_expr.arms;
        let mut v = self.ev_in(f, m, value_n);
        let mut refobj: u32 = 0;
        let mut guard = 0;
        while guard < 4 && v.kind == CV_PTR {
            let lr = self.ce_loadp(v);
            if !lr.ok {
                return Flow::Bail;
            }
            v = lr.v;
            if v.kind == CV_AGG {
                refobj = v.as_data.p.obj;
            }
            guard = guard + 1;
        }
        if v.kind == CV_NIL_K {
            return xfail(f);
        }
        let sb = self.ce_builtin_of(f, m, self.ce_type(m, value_n));
        let uns = sb != BuiltinType::BT_COUNT && bt_unsigned(sb);
        for i in 0..arms.len {
            let aid = unsafe a.list(arms)[i as usize];
            let pattern = a.at_const(aid).as_data.match_arm.pattern;
            let guard_n = a.at_const(aid).as_data.match_arm.guard;
            let body = a.at_const(aid).as_data.match_arm.body;
            let was = self.trap_mark();
            let hit = self.pat_match(f, m, pattern, v, uns, refobj);
            if hit < 0 {
                return Flow::Bail;
            }
            if hit == 0 {
                self.trap_discard(was);
                continue;
            }
            if guard_n != NODE_NONE {
                let g = self.ev_rval(f, m, guard_n);
                if g.kind != CV_BOOL {
                    return xfail(f);
                }
                if g.as_data.i == 0 {
                    continue;
                }
            }
            if out != null {
                unsafe *out = self.ev_in(f, m, body);
                if unsafe out.kind != CV_NIL_K {
                    return Flow::Ok;
                }
                return xfail(f);
            }
            if a.at_const(body).kind == NodeKind::NODE_BLOCK {
                return self.exec_stmt(f, m, body);
            }
            return self.exec_expr_stmt(f, m, body);
        }
        return Flow::Bail;
    }

    // --- statements ---
    fn exec_assign(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let left = a.at_const(id).as_data.binary.left;
        let right = a.at_const(id).as_data.binary.right;
        let op = a.at_const(id).as_data.binary.op;
        let pr = self.ev_place(f, m, left);
        if !pr.ok {
            return xfail(f);
        }
        let mut r = self.ev_rval(f, m, right);
        if r.kind == CV_NIL_K {
            return xfail(f);
        }
        if op != TokenType::Equal {
            let cur = self.ce_loadp(pr.v);
            if !cur.ok {
                return Flow::Bail;
            }
            let cop = compound_op(op);
            let lt = self.ce_type(m, left);
            let tb = self.ce_builtin_of(f, m, lt);
            if cur.v.kind == CV_FLOAT && r.kind == CV_FLOAT {
                r = ce_float_op(cop, cur.v, r, m, lt, tb);
            } else if cur.v.kind == CV_INT && r.kind == CV_INT {
                r = self.ce_int_op(cop, cur.v, r, m, lt, tb, tb);
            } else {
                return Flow::Bail;
            }
            if r.kind == CV_NIL_K {
                return Flow::Bail;
            }
        }
        if self.ce_storep(pr.v, r) {
            return Flow::Ok;
        }
        return Flow::Bail;
    }

    fn exec_expr_stmt(self: &mut Self, f: *mut CeFrame, m: ModuleId, id0: NodeId) Flow {
        let a = self.ast_ptr(m);
        let mut id = id0;
        loop {
            let k = a.at_const(id).kind;
            if k != NodeKind::NODE_UNARY {
                break;
            }
            let op = a.at_const(id).as_data.unary.op;
            if op != TokenType::Move && op != TokenType::Unsafe || a.at_const(a.at_const(id).as_data.unary.operand).kind == NodeKind::NODE_BLOCK {
                break;
            }
            id = a.at_const(id).as_data.unary.operand;
        }
        let k = a.at_const(id).kind;
        if k == NodeKind::NODE_UNARY {
            // a statement-position `unsafe { ... }`/`move { ... }` block: execute it as statements
            // (ev_block would skip a trailing assignment and yield no value)
            let op = a.at_const(id).as_data.unary.op;
            let operand = a.at_const(id).as_data.unary.operand;
            if (op == TokenType::Move || op == TokenType::Unsafe) && a.at_const(operand).kind == NodeKind::NODE_BLOCK {
                return self.exec_stmt(f, m, operand);
            }
        }
        if k == NodeKind::NODE_ASSIGNMENT {
            return self.exec_assign(f, m, id);
        }
        if k == NodeKind::NODE_MATCH {
            return self.exec_match(f, m, id, null);
        }
        if k == NodeKind::NODE_CALL {
            let cr = self.ce_call(f, m, id);
            if cr.ok {
                return Flow::Ok;
            }
            return xfail(f);
        }
        if self.ev_in(f, m, id).kind != CV_NIL_K {
            return Flow::Ok;
        }
        return xfail(f);
    }

    fn exec_stmt(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        if !self.ce_tick() {
            return Flow::Bail;
        }
        let a = self.ast_ptr(m);
        let k = a.at_const(id).kind;
        switch k {
            NODE_BLOCK => {
                let stmts = a.at_const(id).as_data.block.statements;
                let dbase = unsafe f.ndefers;
                let mut st = Flow::Ok;
                let mut i: u32 = 0;
                while st == Flow::Ok && i < stmts.len {
                    st = self.exec_stmt(f, m, unsafe a.list(stmts)[i as usize]);
                    i = i + 1;
                }
                let mut j = unsafe f.ndefers;
                while j > dbase {
                    j = j - 1;
                    let dv = unsafe f.defers[j as usize];
                    let mut ds = Flow::Ok;
                    if a.at_const(dv).kind == NodeKind::NODE_BLOCK {
                        ds = self.exec_stmt(f, m, dv);
                    } else {
                        ds = self.exec_expr_stmt(f, m, dv);
                    }
                    if ds != Flow::Ok {
                        st = Flow::Bail;
                    }
                }
                unsafe f.ndefers = dbase;
                return st;
            },
            NODE_LET => {
                return self.exec_let(f, m, id);
            },
            NODE_IF => {
                let c = self.ev_rval(f, m, a.at_const(id).as_data.if_stmt.condition);
                if c.kind != CV_BOOL {
                    return xfail(f);
                }
                if c.as_data.i != 0 {
                    return self.exec_stmt(f, m, a.at_const(id).as_data.if_stmt.then_branch);
                }
                let eb = a.at_const(id).as_data.if_stmt.else_branch;
                if eb == NODE_NONE {
                    return Flow::Ok;
                }
                return self.exec_stmt(f, m, eb);
            },
            NODE_WHILE => {
                return self.exec_while(f, m, id);
            },
            NODE_FOR | NODE_INLINE_FOR => {
                return self.exec_for(f, m, id);
            },
            NODE_RETURN => {
                let values = a.at_const(id).as_data.return_stmt.values;
                if values.len > 8 {
                    return Flow::Bail;
                }
                unsafe f.nrets = 0;
                for i in 0..values.len {
                    let v = self.ev_in(f, m, unsafe a.list(values)[i as usize]);
                    if v.kind == CV_NIL_K {
                        return xfail(f);
                    }
                    let nr = unsafe f.nrets;
                    unsafe f.rets[nr as usize] = v;
                    unsafe f.nrets = nr + 1;
                }
                unsafe f.returned = 1;
                return Flow::Return;
            },
            NODE_BREAK => {
                let lbl = a.at_const(id).as_data.flow.label;
                if lbl.end > lbl.start || a.at_const(id).as_data.flow.value != NODE_NONE {
                    return Flow::Bail;
                }
                return Flow::Break;
            },
            NODE_CONTINUE => {
                let lbl = a.at_const(id).as_data.flow.label;
                if lbl.end > lbl.start {
                    return Flow::Bail;
                }
                return Flow::Continue;
            },
            NODE_ASM => {
                return Flow::Bail; // machine instructions have no compile-time meaning
            },
            NODE_DEFER => {
                if unsafe f.ndefers >= CE_MAX_DEFERS {
                    return Flow::Bail;
                }
                let nd = unsafe f.ndefers;
                unsafe f.defers[nd as usize] = a.at_const(id).as_data.single.value;
                unsafe f.ndefers = nd + 1;
                return Flow::Ok;
            },
            NODE_EXPRESSION_STATEMENT => {
                return self.exec_expr_stmt(f, m, a.at_const(id).as_data.single.value);
            },
            _ => {},
        };
        return Flow::Bail;
    }

    fn exec_let(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let name_n = a.at_const(id).as_data.let_stmt.name;
        let value_n = a.at_const(id).as_data.let_stmt.value;
        let type_n = a.at_const(id).as_data.let_stmt.ty;
        let nmk = a.at_const(name_n).kind;
        if nmk == NodeKind::NODE_PATTERN_TUPLE {
            let children = a.at_const(name_n).as_data.pattern.children;
            let nbind = children.len;
            if value_n == NODE_NONE {
                return Flow::Bail;
            }
            let mut vals: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            let mut nvals: u32 = 0;
            if a.at_const(value_n).kind == NodeKind::NODE_CALL {
                let cr = self.ce_call(f, m, value_n);
                if !cr.ok {
                    return xfail(f);
                }
                for i in 0..cr.n {
                    unsafe vals[i as usize] = unsafe cr.vals[i as usize];
                }
                nvals = cr.n;
            }
            if nvals <= 1 {
                let mut tv = cv_nil();
                if nvals == 1 {
                    tv = vals[0];
                } else {
                    tv = self.ev_rval(f, m, value_n);
                }
                if tv.kind != CV_AGG {
                    return xfail(f);
                }
                let o = self.obj_ptr(tv.as_data.p.obj);
                if o == null || (unsafe o.slots.len()) as u32 < nbind {
                    return Flow::Bail;
                }
                for i in 0..nbind {
                    unsafe vals[i as usize] = unsafe self.obj_ptr(tv.as_data.p.obj).slots[i as usize];
                }
                nvals = nbind;
            }
            if nvals != nbind {
                return Flow::Bail;
            }
            for i in 0..nbind {
                let cid = unsafe a.list(children)[i as usize];
                if unsafe vals[i as usize].kind == CV_NIL_K || !self.ce_bind(f, cid, unsafe vals[i as usize]) {
                    return xfail(f);
                }
            }
            return Flow::Ok;
        }
        if nmk != NodeKind::NODE_IDENTIFIER {
            return Flow::Bail;
        }
        let mut v = cv_nil();
        if value_n != NODE_NONE {
            if type_n != NODE_NONE {
                let wr = self.ce_rtype(f, m, self.ce_type(m, type_n));
                if !wr.ok {
                    return Flow::Bail;
                }
                let raw = self.ev_in(f, m, value_n);
                v = self.ce_coerce(raw, wr.m, wr.t);
            } else {
                v = self.ev_in(f, m, value_n);
            }
            if v.kind == CV_NIL_K {
                return xfail(f);
            }
        }
        if self.ce_bind(f, id, v) {
            return Flow::Ok;
        }
        return Flow::Bail;
    }

    fn exec_while(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let cond = a.at_const(id).as_data.while_stmt.condition;
        let body = a.at_const(id).as_data.while_stmt.body;
        let mut first = a.at_const(id).as_data.while_stmt.is_do;
        loop {
            if !first && cond != NODE_NONE {
                let c = self.ev_rval(f, m, cond);
                if c.kind != CV_BOOL {
                    return xfail(f);
                }
                if c.as_data.i == 0 {
                    return Flow::Ok;
                }
            }
            first = false;
            let st = self.exec_stmt(f, m, body);
            if st == Flow::Break {
                return Flow::Ok;
            }
            if st == Flow::Return || st == Flow::Bail {
                return st;
            }
            if !self.ce_tick() {
                return Flow::Bail;
            }
        }
    }

    // The active fields-loop iteration `obj_n` (a binder identifier) refers to, by resolution;
    // null when obj_n is not a live binder.
    fn ce_proj_of(self: &Self, m: ModuleId, obj_n: NodeId) *const CeProj {
        let a = self.ast_ptr(m);
        if a.at_const(obj_n).kind != NodeKind::NODE_IDENTIFIER {
            return null;
        }
        let lid = a.resolution(obj_n);
        if lid == NODE_NONE || a.at_const(lid).kind != NodeKind::NODE_INLINE_FOR {
            return null;
        }
        let mut i = self.ce_projs.len();
        while i > 0 {
            i = i - 1;
            if self.ce_projs.at(i).binder == lid {
                return self.ce_projs.at(i);
            }
        }
        return null;
    }

    // `f.name` / `f.index` / `f.value` under the interpreter; CV_NIL_K when `id` is no binder member.
    fn ce_proj_member(self: &mut Self, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        if a.at_const(id).as_data.member.path {
            return cv_nil();
        }
        let pr = self.ce_proj_of(m, a.at_const(id).as_data.member.object);
        if pr == null {
            return cv_nil();
        }
        let mname = self.name_text(m, a.at_const(id).as_data.member.member);
        if self.ce_span_is(m, mname, "index") {
            return CeVal {
                kind: CV_INT,
                tm: 0,
                ty: Ast::builtin(BuiltinType::BT_USIZE),
                as_data: CeValAs { i: unsafe pr.k },
            };
        }
        if self.ce_span_is(m, mname, "value") {
            let sub = unsafe pr.sub;
            if sub.kind != CV_PTR && sub.kind != CV_AGG || sub.as_data.p.off != 0 {
                return cv_nil();
            }
            let o = self.obj_ptr(sub.as_data.p.obj);
            if o == null || (unsafe pr.k) as usize >= unsafe o.slots.len() {
                return cv_nil();
            }
            return unsafe o.slots[(unsafe pr.k) as usize];
        }
        if self.ce_span_is(m, mname, "name") {
            let sty = self.ce_type(m, id);
            if sty == TYPE_NONE {
                return cv_nil();
            }
            let ys = *self.ast_ptr(m).type_at(sty);
            if ys.kind != TypeKind::TYPE_STRUCT {
                return cv_nil();
            }
            let dm = unsafe pr.om;
            let dt = unsafe pr.owner;
            let mut fdm: ModuleId = 0;
            let fid = self.ce_proj_field(dm, dt, unsafe pr.k, &mut fdm);
            if fid == NODE_NONE {
                return cv_nil();
            }
            let da = self.ast_ptr(fdm);
            if da.at_const(fid).kind == NodeKind::NODE_FIELD {
                let sp = self.name_text(fdm, da.at_const(fid).as_data.field.name);
                let src = self.ce_src(fdm);
                return self.ce_ti_str(ys.module, ys.as_data.decl, m, sty, src.slice(sp.start as usize, sp.end as usize));
            }
            let mut tb = Buf32 {};
            return self.ce_ti_str(ys.module, ys.as_data.decl, m, sty, ti_tuple_name(&mut tb, (unsafe pr.k) as u32));
        }
        return cv_nil();
    }

    // The k-th field node of (m, owner), mirroring codegen's walk; NODE_NONE past the end.
    fn ce_proj_field(self: &Self, m: ModuleId, owner: TypeId, idx: i64, out_m: &mut ModuleId) NodeId {
        let y = *self.ast_ptr(m).type_at(owner);
        let mut dm = y.module;
        let mut dn = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT {
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_ptr(m).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
        } else {
            return NODE_NONE;
        }
        if !self.has_ast(dm) || self.ast_ptr(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return NODE_NONE;
        }
        let da = self.ast_ptr(dm);
        let ag = da.at_const(dn).as_data.aggregate;
        let mut k: i64 = 0;
        for i in 0..ag.members.len {
            let fid = unsafe da.list(ag.members)[i as usize];
            if !ag.is_tuple && da.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            if k == idx {
                *out_m = dm;
                return fid;
            }
            k = k + 1;
        }
        return NODE_NONE;
    }

    fn exec_for(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let iter_n = a.at_const(id).as_data.for_stmt.iterable;
        let body = a.at_const(id).as_data.for_stmt.body;
        // fields(&v): interpret the unroll -- one pass per field, the binder served by ce_projs.
        if a.at_const(id).kind == NodeKind::NODE_INLINE_FOR && a.at_const(iter_n).kind == NodeKind::NODE_CALL {
            let fcl = a.at_const(iter_n).as_data.call.callee;
            if a.at_const(fcl).kind != NodeKind::NODE_IDENTIFIER || !self.ce_span_is(
                m,
                a.at_const(fcl).as_data.name.text,
                "fields",
            ) {
                return Flow::Bail; // variants(&e) has no interpreter yet
            }
            let pt = self.ce_type(m, id);
            if pt == TYPE_NONE || self.ast_ptr(m).type_at(pt).kind != TypeKind::TYPE_FIELD_PROJECTION {
                return Flow::Bail;
            }
            let pr = self.ce_rtype(f, m, self.ast_ptr(m).type_at(pt).as_data.proj.owner);
            if !pr.ok {
                return Flow::Bail;
            }
            let arg = unsafe a.list(a.at_const(iter_n).as_data.call.args)[0];
            let sub = self.ev_rval(f, m, arg);
            if sub.kind != CV_PTR && sub.kind != CV_AGG {
                return xfail(f);
            }
            let mut k: i64 = 0;
            loop {
                let mut fdm: ModuleId = 0;
                if self.ce_proj_field(pr.m, pr.t, k, &mut fdm) == NODE_NONE {
                    return Flow::Ok;
                }
                self.ce_projs.push(CeProj { binder: id, k: k, sub: sub, om: pr.m, owner: pr.t });
                let st = self.exec_stmt(f, m, body);
                let _ = self.ce_projs.pop();
                if st == Flow::Return || st == Flow::Bail {
                    return st;
                }
                if !self.ce_tick() {
                    return Flow::Bail;
                }
                k = k + 1;
            }
        }
        if a.at_const(iter_n).kind == NodeKind::NODE_RANGE {
            let start_n = a.at_const(iter_n).as_data.pattern_range.start;
            let end_n = a.at_const(iter_n).as_data.pattern_range.end;
            let inc = a.at_const(iter_n).as_data.pattern_range.inclusive;
            if start_n == NODE_NONE || end_n == NODE_NONE {
                return Flow::Bail;
            }
            let s = self.ev_rval(f, m, start_n);
            if s.kind != CV_INT {
                return xfail(f);
            }
            let eb = self.ce_builtin_of(f, m, self.ce_type(m, iter_n));
            let uns = eb != BuiltinType::BT_COUNT && bt_unsigned(eb);
            let et = self.ce_type(m, id);
            if self.ce_bind_slot(f, id) == null {
                return Flow::Bail;
            }
            let mut v = s.as_data.i;
            loop {
                let e = self.ev_rval(f, m, end_n);
                if e.kind != CV_INT {
                    return xfail(f);
                }
                let last = v == e.as_data.i;
                let mut done = false;
                if uns {
                    done = v as u64 > e.as_data.i as u64 || !inc && last;
                } else {
                    done = v > e.as_data.i || !inc && last;
                }
                if done {
                    return Flow::Ok;
                }
                let slot = self.ce_bind_slot(f, id);
                unsafe *slot = CeVal { kind: CV_INT, tm: m, ty: et, as_data: CeValAs { i: v } };
                let st = self.exec_stmt(f, m, body);
                if st == Flow::Break {
                    return Flow::Ok;
                }
                if st == Flow::Return || st == Flow::Bail {
                    return st;
                }
                if !self.ce_tick() {
                    return Flow::Bail;
                }
                if inc && last {
                    return Flow::Ok;
                }
                v = v + 1;
            }
        }
        let ir = self.ce_rtype(f, m, self.ce_type(m, iter_n));
        if !ir.ok {
            return Flow::Bail;
        }
        if self.ast_ptr(ir.m).type_at(ir.t).kind == TypeKind::TYPE_ARRAY {
            let br = self.ce_base_obj(f, m, iter_n);
            if !br.ok {
                return Flow::Bail;
            }
            let len = (unsafe self.obj_ptr(br.obj).slots.len()) as u32;
            for i in 0..len {
                let sv = unsafe self.obj_ptr(br.obj).slots[i as usize];
                if sv.kind == CV_NIL_K || !self.ce_bind(f, id, sv) {
                    return Flow::Bail;
                }
                let st = self.exec_stmt(f, m, body);
                if st == Flow::Break {
                    return Flow::Ok;
                }
                if st == Flow::Return || st == Flow::Bail {
                    return st;
                }
                if !self.ce_tick() {
                    return Flow::Bail;
                }
            }
            return Flow::Ok;
        }
        // Iterator protocol
        let iv = self.ev_in(f, m, iter_n);
        if iv.kind == CV_NIL_K {
            return xfail(f);
        }
        let tr = self.ce_temp_place(iv);
        if !tr.ok {
            return Flow::Bail;
        }
        let itp = tr.v;
        let rr = self.ce_recv_of(f, m, self.ce_type(m, iter_n));
        if !rr.ok || rr.r.dn == NODE_NONE {
            return Flow::Bail;
        }
        loop {
            let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            args[0] = itp;
            let dr = self.ce_dispatch(rr.r, m, "next", &args[0], 1);
            if !dr.ok || dr.v.kind != CV_AGG {
                return Flow::Bail;
            }
            let oo = self.obj_ptr(dr.v.as_data.p.obj);
            if oo == null || unsafe oo.is_enum == 0 {
                return Flow::Bail;
            }
            let olen = unsafe oo.slots.len();
            if olen < 2 || unsafe oo.slots[1].kind == CV_NIL_K {
                if olen >= 2 {
                    return Flow::Bail;
                }
                return Flow::Ok;
            }
            let payload = unsafe oo.slots[1];
            if !self.ce_bind(f, id, payload) {
                return Flow::Bail;
            }
            let st = self.exec_stmt(f, m, body);
            if st == Flow::Break {
                return Flow::Ok;
            }
            if st == Flow::Return || st == Flow::Bail {
                return st;
            }
            if !self.ce_tick() {
                return Flow::Bail;
            }
        }
    }
}

const fn if_i32(c: bool, a: i32, b: i32) i32 {
    if c {
        return a;
    }
    return b;
}
const fn if_bool(c: bool, a: bool, b: bool) bool {
    if c {
        return a;
    }
    return b;
}
// A nil eval after `?` propagated an early return (frame.early) is a Return, not a failure.
const fn xfail(f: *mut CeFrame) Flow {
    if f != null && unsafe f.early != 0 {
        return Flow::Return;
    }
    return Flow::Bail;
}

const fn compound_op(op: TokenType) TokenType {
    if op == TokenType::PlusEqual {
        return TokenType::Plus;
    }
    if op == TokenType::MinusEqual {
        return TokenType::Minus;
    }
    if op == TokenType::StarEqual {
        return TokenType::Star;
    }
    if op == TokenType::SlashEqual {
        return TokenType::Slash;
    }
    if op == TokenType::PercentEqual {
        return TokenType::Percent;
    }
    if op == TokenType::AmpersandEqual {
        return TokenType::Ampersand;
    }
    if op == TokenType::PipeEqual {
        return TokenType::Pipe;
    }
    if op == TokenType::CaretEqual {
        return TokenType::Caret;
    }
    if op == TokenType::LeftShiftEqual {
        return TokenType::LeftShift;
    }
    if op == TokenType::RightShiftEqual {
        return TokenType::RightShift;
    }
    return TokenType::Equal;
}

const fn cv_pub(v: CeVal) ConstValue {
    if v.kind == CV_INT {
        return ConstValue { kind: CONST_INT, ty: v.ty, as_data: ConstValueAs { i: v.as_data.i } };
    }
    if v.kind == CV_BOOL {
        return ConstValue { kind: CONST_BOOL, ty: v.ty, as_data: ConstValueAs { i: v.as_data.i } };
    }
    if v.kind == CV_FLOAT {
        if !ce_isfinite(v.as_data.f) {
            return ce_none();
        }
        return ConstValue { kind: CONST_FLOAT, ty: v.ty, as_data: ConstValueAs { f: v.as_data.f } };
    }
    return ce_none();
}

const fn cv_is_scalar(v: CeVal) bool {
    return v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT;
}

// --- effect summary (fx) --------------------------------------------------------------------------
// Lazy, memoized, per-function CTFE-eligibility verdicts. FX_NO is kept tight: it must imply the
// interpreter would fail anyway (so consulting it never changes a fold result). The scan covers the
// body's leading straight-line statements only and stops at the first control-flow statement;
// within an expression everything is spine because the interpreter evaluates eagerly (only
// if/match/closures defer their subtrees).

extend ConstEval {
    const fn fx_slot(self: &Self, m: ModuleId, id: NodeId, deep: bool) u8 {
        let tbl = if deep {
            &self.fxd;
        } else {
            &self.fx;
        };
        if m as usize >= tbl.len() {
            return FX_UNKNOWN;
        }
        let inner = tbl.at(m as usize);
        if id as usize >= inner.len() {
            return FX_UNKNOWN;
        }
        return inner[id as usize];
    }
    fn fx_set(self: &mut Self, m: ModuleId, id: NodeId, v: u8, deep: bool) {
        let tbl = if deep {
            &mut self.fxd;
        } else {
            &mut self.fx;
        };
        if m as usize >= tbl.len() {
            return;
        }
        let inner = &mut tbl[m as usize];
        while inner.len() <= id as usize {
            inner.push(FX_UNKNOWN);
        }
        inner.set(id as usize, v);
    }

    // Deep mode never records a reason: its NO is any-path (the site may be conditional), so it must
    // not surface as a def-site 'const fn' diagnostic.
    @c.cold
    fn fx_disq(self: &mut Self, m: ModuleId, owner: NodeId, site: NodeId, why: str, deep: bool) u8 {
        if !deep {
            self.fx_no.push(FxNo { m: m, fn_id: owner, site: site, why: why });
        }
        return FX_NO;
    }

    /// Shallow effect verdict for (m,fn_id) (FX_*): NO = evaluation is certain to fail. Lazy, memoized.
    pub fn fx_get(self: &mut Self, m: ModuleId, fn_id: NodeId) u8 {
        return self.fx_get_in(m, fn_id, false);
    }

    fn fx_get_in(self: &mut Self, m: ModuleId, fn_id: NodeId, deep: bool) u8 {
        if m as usize >= self.nmods || !self.has_ast(m) {
            return FX_MAYBE;
        }
        let cur = self.fx_slot(m, fn_id, deep);
        if cur != FX_UNKNOWN {
            return cur;
        }
        if self.fx_depth >= 128 {
            return FX_MAYBE; // not memoized: a cap-dependent verdict must not stick
        }
        self.fx_set(m, fn_id, FX_ONSTACK, deep);
        self.fx_depth = self.fx_depth + 1;
        let v = self.fx_scan_fn(m, fn_id, deep);
        self.fx_depth = self.fx_depth - 1;
        self.fx_set(m, fn_id, v, deep);
        return v;
    }

    /// Like ce_fn_eligible, but re-scans instead of trusting the memo. The def-site check runs this
    /// AFTER the body has typechecked: type-based disqualifiers ('@no_const' mentions) are invisible
    /// before the body's types exist, and an earlier caller's fold prefilter may have memoized that
    /// blind verdict. The fresh verdict overwrites the memo so later folds agree with it.
    pub fn ce_fn_recheck(self: &mut Self, m: ModuleId, fn_id: NodeId) u8 {
        if m as usize >= self.nmods || !self.has_ast(m) {
            return FX_MAYBE;
        }
        self.fx_set(m, fn_id, FX_ONSTACK, false);
        self.fx_depth = self.fx_depth + 1;
        let v = self.fx_scan_fn(m, fn_id, false);
        self.fx_depth = self.fx_depth - 1;
        self.fx_set(m, fn_id, v, false);
        return v;
    }

    /// The const-suggestion lint's surface: deep FX_YES = every path of the body is provably
    /// CTFE-evaluable, so declaring the function `const fn` passes the def-site check AND cannot
    /// introduce structural fold failures (traps and budgets remain the caller's semantic risk).
    pub fn ce_fn_const_suggest(self: &mut Self, m: ModuleId, fn_id: NodeId) bool {
        return self.fx_get_in(m, fn_id, true) == FX_YES;
    }
    /// The recorded disqualifying site for a shallow FX_NO, or null (deep verdicts record no reason).
    pub fn fx_no_reason(self: &Self, m: ModuleId, fn_id: NodeId) *const FxNo {
        for i in 0..self.fx_no.len() {
            let r = self.fx_no.at(i);
            if r.m == m && r.fn_id == fn_id {
                return r;
            }
        }
        return null;
    }

    fn fx_scan_fn(self: &mut Self, m: ModuleId, fn_id: NodeId, deep: bool) u8 {
        let a = self.ast_ptr(m);
        if unsafe a.nodes.len() == 0 || a.at_const(fn_id).kind != NodeKind::NODE_FUNCTION {
            return FX_MAYBE;
        }
        let fd = a.at_const(fn_id).as_data.function;
        if fd.is_extern || fd.body == NODE_NONE {
            return FX_MAYBE; // externs are classified at their call sites; bodyless may re-dispatch
        }
        if fd.is_variadic {
            return self.fx_disq(m, fn_id, fn_id, "is variadic", deep);
        }
        return self.fx_scan_stmts(m, fn_id, fd.body, 0, deep);
    }

    // Leading straight-line statements of a block; stops at the first control-flow statement.
    // Deep mode instead recurses into if/match/defer (every path), so FX_YES means the whole body is
    // provably evaluable; loops stay MAYBE (step-budget risk), as does anything unmodeled.
    fn fx_scan_stmts(self: &mut Self, m: ModuleId, owner: NodeId, block: NodeId, depth: u32, deep: bool) u8 {
        let a = self.ast_ptr(m);
        if depth > 64 || a.at_const(block).kind != NodeKind::NODE_BLOCK {
            return FX_MAYBE;
        }
        let stmts = a.at_const(block).as_data.block.statements;
        let mut acc = FX_YES;
        for i in 0..stmts.len {
            let sid = unsafe a.list(stmts)[i as usize];
            let k = a.at_const(sid).kind;
            let mut s = FX_YES;
            if k == NodeKind::NODE_EXPRESSION_STATEMENT {
                s = self.fx_scan_expr(m, owner, a.at_const(sid).as_data.single.value, depth + 1, deep);
            } else if k == NodeKind::NODE_LET {
                let v = a.at_const(sid).as_data.let_stmt.value;
                if v != NODE_NONE {
                    s = self.fx_scan_expr(m, owner, v, depth + 1, deep);
                }
            } else if k == NodeKind::NODE_RETURN {
                let values = a.at_const(sid).as_data.return_stmt.values;
                if deep && values.len > 8 {
                    return fx_meet(acc, FX_MAYBE); // the interpreter caps multi-returns at 8
                }
                for j in 0..values.len {
                    s = fx_meet(s, self.fx_scan_expr(m, owner, unsafe a.list(values)[j as usize], depth + 1, deep));
                }
                return fx_meet(acc, s); // nothing executes after a spine return
            } else if k == NodeKind::NODE_BLOCK {
                s = self.fx_scan_stmts(m, owner, sid, depth + 1, deep);
            } else if k == NodeKind::NODE_STATIC_ASSERT {
                continue;
            } else if deep && (k == NodeKind::NODE_IF || k == NodeKind::NODE_MATCH) {
                s = self.fx_scan_expr(m, owner, sid, depth + 1, true);
            } else if k == NodeKind::NODE_ASM {
                return FX_NO; // inline assembly is never compile-time evaluable
            } else if deep && k == NodeKind::NODE_DEFER {
                s = self.fx_scan_body(m, owner, a.at_const(sid).as_data.single.value, depth + 1);
            } else {
                return fx_meet(acc, FX_MAYBE); // control flow: the spine ends here (deep: loops/unmodeled)
            }
            acc = fx_meet(acc, s);
            if acc == FX_NO {
                return FX_NO;
            }
        }
        return acc;
    }

    // Deep-only helpers: a branch/arm/defer body is a block or a bare expression.
    fn fx_scan_body(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32) u8 {
        if id == NODE_NONE {
            return FX_YES;
        }
        if self.ast_ptr(m).at_const(id).kind == NodeKind::NODE_BLOCK {
            return self.fx_scan_stmts(m, owner, id, depth, true);
        }
        return self.fx_scan_expr(m, owner, id, depth, true);
    }

    fn fx_scan_match(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32) u8 {
        let a = self.ast_ptr(m);
        let mut acc = self.fx_scan_expr(m, owner, a.at_const(id).as_data.match_expr.value, depth + 1, true);
        let arms = a.at_const(id).as_data.match_expr.arms;
        for i in 0..arms.len {
            if acc != FX_YES {
                return acc;
            }
            let arm = a.at_const(unsafe a.list(arms)[i as usize]).as_data.match_arm;
            acc = fx_meet(acc, self.fx_scan_pat(m, arm.pattern, depth + 1));
            if arm.guard != NODE_NONE {
                acc = fx_meet(acc, self.fx_scan_expr(m, owner, arm.guard, depth + 1, true));
            }
            acc = fx_meet(acc, self.fx_scan_body(m, owner, arm.body, depth + 1));
        }
        return acc;
    }

    // Would pat_match handle this pattern? Literals/range endpoints must be integer-classed (int,
    // char, bool): str and float literal patterns make pat_match report a mismatch (-1).
    fn fx_pat_lit_ok(self: &Self, m: ModuleId, vn: NodeId) bool {
        let b = self.ce_builtin_of(null, m, self.ce_type(m, vn));
        return b != BuiltinType::BT_COUNT && (bt_signed(b) || bt_unsigned(b) || b == BuiltinType::BT_BOOL);
    }

    fn fx_scan_pat(self: &mut Self, m: ModuleId, pid: NodeId, depth: u32) u8 {
        if depth > 64 {
            return FX_MAYBE;
        }
        let a = self.ast_ptr(m);
        let n = a.at_const(pid);
        switch n.kind {
            NODE_PATTERN_WILDCARD => {
                return FX_YES;
            },
            NODE_PATTERN_LITERAL => {
                if self.fx_pat_lit_ok(m, n.as_data.single.value) {
                    return FX_YES;
                }
            },
            NODE_PATTERN_RANGE => {
                let sn = n.as_data.pattern_range.start;
                let en = n.as_data.pattern_range.end;
                let mut ok = true;
                if sn != NODE_NONE {
                    ok = self.fx_scan_pat(m, sn, depth + 1) == FX_YES;
                }
                if ok && en != NODE_NONE {
                    ok = self.fx_scan_pat(m, en, depth + 1) == FX_YES;
                }
                if ok {
                    return FX_YES;
                }
            },
            NODE_PATTERN_FIELD => {
                let children = n.as_data.pattern.children;
                if n.as_data.pattern.name == NODE_NONE || children.len != 1 {
                    return FX_MAYBE;
                }
                let child = unsafe a.list(children)[0];
                if a.at_const(child).kind == NodeKind::NODE_IDENTIFIER {
                    return FX_YES; // a bare binding, not a sub-pattern
                }
                return self.fx_scan_pat(m, child, depth + 1);
            },
            NODE_PATTERN_NAME | NODE_PATTERN_OR | NODE_PATTERN_TUPLE | NODE_PATTERN_STRUCT => {
                // tuple/struct patterns match through pat_match only as enum-variant payloads; a
                // paren-group tuple (no name, one child) passes through
                if n.kind == NodeKind::NODE_PATTERN_TUPLE || n.kind == NodeKind::NODE_PATTERN_STRUCT {
                    let pname = n.as_data.pattern.name;
                    if pname == NODE_NONE {
                        if n.kind == NodeKind::NODE_PATTERN_STRUCT || n.as_data.pattern.children.len != 1 {
                            return FX_MAYBE;
                        }
                    } else {
                        let d = a.resolution_def(pname);
                        if d.node == NODE_NONE || d.module as usize >= self.nmods || self.ast_ptr(d.module).at_const(
                            d.node,
                        ).kind != NodeKind::NODE_VARIANT {
                            return FX_MAYBE;
                        }
                        if n.kind == NodeKind::NODE_PATTERN_STRUCT && !self.ast_ptr(d.module).at_const(d.node).as_data.variant.struct_payload {
                            return FX_MAYBE;
                        }
                    }
                }
                let children = n.as_data.pattern.children;
                for i in 0..children.len {
                    if self.fx_scan_pat(m, unsafe a.list(children)[i as usize], depth + 1) != FX_YES {
                        return FX_MAYBE;
                    }
                }
                return FX_YES;
            },
            _ => {},
        };
        return FX_MAYBE;
    }

    fn fx_scan_expr(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32, deep: bool) u8 {
        if id == NODE_NONE {
            return FX_YES;
        }
        if depth > 64 {
            return FX_MAYBE;
        }
        if self.ce_ty_no_const(m, self.ce_type(m, id), 0) {
            return self.fx_disq(m, owner, id, "uses a '@no_const' type", deep);
        }
        let a = self.ast_ptr(m);
        let n = a.at_const(id);
        switch n.kind {
            NODE_LITERAL | NODE_SIZEOF | NODE_ALIGNOF => {
                return FX_YES;
            },
            NODE_IDENTIFIER => {
                let d = a.resolution_def(id);
                if d.node != NODE_NONE && d.module as usize < self.nmods && self.ast_ptr(d.module).at_const(d.node).kind == NodeKind::NODE_CONST && self.ast_ptr(
                    d.module,
                ).at_const(d.node).as_data.const_def.is_static_mut {
                    return self.fx_disq(m, owner, id, "accesses a 'static mut'", deep);
                }
                return FX_YES;
            },
            NODE_MEMBER => {
                if n.as_data.member.path {
                    let d = a.resolution_def(id);
                    if d.node != NODE_NONE && d.module as usize < self.nmods && self.ast_ptr(d.module).at_const(d.node).kind == NodeKind::NODE_CONST && self.ast_ptr(
                        d.module,
                    ).at_const(d.node).as_data.const_def.is_static_mut {
                        return self.fx_disq(m, owner, id, "accesses a 'static mut'", deep);
                    }
                    return FX_YES;
                }
                return self.fx_scan_expr(m, owner, n.as_data.member.object, depth + 1, deep);
            },
            NODE_UNARY => {
                let operand = n.as_data.unary.operand;
                if a.at_const(operand).kind == NodeKind::NODE_BLOCK {
                    return self.fx_scan_stmts(m, owner, operand, depth + 1, deep);
                }
                return self.fx_scan_expr(m, owner, operand, depth + 1, deep);
            },
            NODE_BINARY | NODE_ASSIGNMENT => {
                let l = self.fx_scan_expr(m, owner, n.as_data.binary.left, depth + 1, deep);
                if l == FX_NO {
                    return FX_NO;
                }
                return fx_meet(l, self.fx_scan_expr(m, owner, n.as_data.binary.right, depth + 1, deep));
            },
            NODE_CAST => {
                return self.fx_scan_expr(m, owner, n.as_data.cast.expression, depth + 1, deep);
            },
            NODE_INDEX => {
                let o = self.fx_scan_expr(m, owner, n.as_data.index.object, depth + 1, deep);
                if o == FX_NO {
                    return FX_NO;
                }
                return fx_meet(o, self.fx_scan_expr(m, owner, n.as_data.index.index, depth + 1, deep));
            },
            NODE_STRUCT_INITIALIZER => {
                // Resolution-based (types may not exist yet at the def-site check): constructing a
                // '@no_const' type is certain failure on every path that reaches it.
                let tn = n.as_data.struct_initializer.ty;
                let mut vd = a.resolution_def(tn);
                if vd.node == NODE_NONE {
                    vd = DefId { module: m, node: a.resolution(tn) };
                }
                if vd.node != NODE_NONE && vd.module as usize < self.nmods && self.ce_attr(
                    vd.module,
                    vd.node,
                    AttrKind::ATTR_NO_CONST,
                ) != null {
                    return self.fx_disq(m, owner, id, "constructs a '@no_const' value", deep);
                }
                let fields = n.as_data.struct_initializer.fields;
                let mut acc = FX_YES;
                for i in 0..fields.len {
                    let fid = unsafe a.list(fields)[i as usize];
                    if a.at_const(fid).kind == NodeKind::NODE_FIELD_INITIALIZER {
                        acc = fx_meet(
                            acc,
                            self.fx_scan_expr(
                                m,
                                owner,
                                a.at_const(fid).as_data.field_initializer.value,
                                depth + 1,
                                deep,
                            ),
                        );
                    }
                    if acc == FX_NO {
                        return FX_NO;
                    }
                }
                return acc;
            },
            NODE_ARRAY_LITERAL | NODE_TUPLE => {
                let elements = n.as_data.array_literal.elements;
                let mut acc = FX_YES;
                for i in 0..elements.len {
                    acc = fx_meet(
                        acc,
                        self.fx_scan_expr(m, owner, unsafe a.list(elements)[i as usize], depth + 1, deep),
                    );
                    if acc == FX_NO {
                        return FX_NO;
                    }
                }
                return acc;
            },
            NODE_RANGE => {
                let s = self.fx_scan_expr(m, owner, n.as_data.pattern_range.start, depth + 1, deep);
                if s == FX_NO {
                    return FX_NO;
                }
                return fx_meet(s, self.fx_scan_expr(m, owner, n.as_data.pattern_range.end, depth + 1, deep));
            },
            NODE_BLOCK => {
                return self.fx_scan_stmts(m, owner, id, depth + 1, deep);
            },
            NODE_CALL => {
                return self.fx_scan_call(m, owner, id, depth, deep);
            },
            NODE_IF => {
                if deep {
                    let c = self.fx_scan_expr(m, owner, n.as_data.if_stmt.condition, depth + 1, true);
                    if c == FX_NO {
                        return FX_NO;
                    }
                    let t = fx_meet(c, self.fx_scan_body(m, owner, n.as_data.if_stmt.then_branch, depth + 1));
                    if t == FX_NO {
                        return FX_NO;
                    }
                    return fx_meet(t, self.fx_scan_body(m, owner, n.as_data.if_stmt.else_branch, depth + 1));
                }
            },
            NODE_MATCH => {
                if deep {
                    return self.fx_scan_match(m, owner, id, depth);
                }
            },
            _ => {},
        };
        return FX_MAYBE; // if/match/closures and anything unmodeled: conditional or unknown
    }

    fn fx_scan_call(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32, deep: bool) u8 {
        let a = self.ast_ptr(m);
        let mut callee = a.at_const(id).as_data.call.callee;
        if a.at_const(callee).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            callee = a.at_const(callee).as_data.specialization.expression;
        }
        let ck = a.at_const(callee).kind;
        let call_args = a.at_const(id).as_data.call.args;
        let mut acc = FX_YES;
        for i in 0..call_args.len {
            acc = fx_meet(acc, self.fx_scan_expr(m, owner, unsafe a.list(call_args)[i as usize], depth + 1, deep));
            if acc == FX_NO {
                return FX_NO;
            }
        }
        if deep && call_args.len > 7 {
            acc = FX_MAYBE; // the interpreter caps calls at 8 slots (receiver + args)
        }
        let mut is_path = ck == NodeKind::NODE_IDENTIFIER;
        if ck == NodeKind::NODE_MEMBER && a.at_const(callee).as_data.member.path {
            is_path = true;
        }
        if !is_path {
            if ck != NodeKind::NODE_MEMBER {
                return FX_MAYBE; // calling a call/index/closure expression: unresolvable statically
            }
            let o = self.fx_scan_expr(m, owner, a.at_const(callee).as_data.member.object, depth + 1, deep);
            if o == FX_NO {
                return FX_NO;
            }
            acc = fx_meet(acc, o);
            if !deep {
                return FX_MAYBE; // method dispatch: past the shallow spine
            }
            // deep: fall through -- the interpreter resolves the method through the same tables
        }
        let mut fd = a.resolution_def(callee);
        if fd.node == NODE_NONE && ck == NodeKind::NODE_MEMBER {
            fd = a.resolution_def(a.at_const(callee).as_data.member.member);
        }
        if fd.node == NODE_NONE && ck == NodeKind::NODE_IDENTIFIER {
            fd = DefId { module: m, node: a.resolution(callee) };
        }
        if fd.node == NODE_NONE || fd.module as usize >= self.nmods || !self.has_ast(fd.module) {
            return FX_MAYBE;
        }
        let fa = self.ast_ptr(fd.module);
        let dk = fa.at_const(fd.node).kind;
        if dk == NodeKind::NODE_VARIANT {
            if deep {
                // mirror ce_call's payload-constructor gates (untagged/user-Free enums bail)
                let vp = self.ce_variant_pos(fd.module, fd.node);
                if vp.pos < 0 || !self.ce_enum_tagged(fd.module, vp.enum_decl) || self.ce_user_free(
                    fd.module,
                    vp.enum_decl,
                ) {
                    return fx_meet(acc, FX_MAYBE);
                }
            }
            return acc; // enum constructor: args already scanned
        }
        if dk != NodeKind::NODE_FUNCTION {
            return FX_MAYBE; // fn value bound to a const/local
        }
        let cfd = fa.at_const(fd.node).as_data.function;
        if cfd.is_extern {
            let nm = self.name_text(fd.module, cfd.name);
            if self.ce_intercept_name(fd.module, nm) {
                return acc;
            }
            return self.fx_disq(m, owner, id, "calls an extern function", deep);
        }
        if cfd.is_variadic {
            return self.fx_disq(m, owner, id, "calls a variadic function", deep);
        }
        if cfd.body == NODE_NONE {
            return FX_MAYBE; // interface requirement: dispatch may substitute a concrete method
        }
        if deep && self.ce_container_of(fd.module, fd.node, null) == 2 {
            return fx_meet(acc, FX_MAYBE); // interface default body: dispatch may substitute an impl
        }
        let cv = self.fx_get_in(fd.module, fd.node, deep);
        if cv == FX_NO {
            return self.fx_disq(m, owner, id, "calls a function that cannot be evaluated at compile time", deep);
        }
        if cv == FX_ONSTACK {
            if deep {
                return fx_meet(acc, FX_MAYBE); // recursion: depth/step budgets make folds input-dependent
            }
            return acc; // gray edge: neutral (recursion is legal)
        }
        return fx_meet(acc, cv);
    }
}

// --- calls --------------------------------------------------------------------------------------

extend ConstEval {
    fn ce_subst_add(self: &Self, g: *mut CeFrame, pmod: ModuleId, param: NodeId, am: ModuleId, at: TypeId) bool {
        for i in 0..unsafe g.ng {
            if unsafe g.pmod == pmod && unsafe g.params_g[i as usize] == param {
                return self.ce_teq(unsafe g.am[i as usize], unsafe g.at[i as usize], am, at);
            }
        }
        if unsafe g.ng >= 8 || unsafe g.ng != 0 && unsafe g.pmod != pmod {
            return false;
        }
        unsafe g.pmod = pmod;
        let ng = unsafe g.ng;
        unsafe g.params_g[ng as usize] = param;
        unsafe g.am[ng as usize] = am;
        unsafe g.at[ng as usize] = at;
        unsafe g.ng = ng + 1;
        return true;
    }

    fn ce_bind_extend(self: &Self, g: *mut CeFrame, xm: ModuleId, extnode: NodeId, recv: *const CeRecv) bool {
        let xa = self.ast_ptr(xm);
        let gens = xa.at_const(extnode).as_data.extend_def.generics;
        if gens.len == 0 {
            return true;
        }
        if recv == null || unsafe recv.dn == NODE_NONE {
            return false;
        }
        let target = xa.at_const(extnode).as_data.extend_def.target_type;
        if xa.at_const(target).kind != NodeKind::NODE_TYPE_PATH || xa.at_const(target).as_data.type_path.args.len != (unsafe recv.n) as u32 {
            return false;
        }
        let targs = xa.at_const(target).as_data.type_path.args;
        for i in 0..unsafe recv.n {
            let aid = unsafe xa.list(targs)[i as usize];
            let ad = xa.resolution_def(aid);
            if ad.node != NODE_NONE && ad.module as usize < self.nmods && self.ast_ptr(ad.module).at_const(ad.node).kind == NodeKind::NODE_GENERIC_PARAM {
                if !self.ce_subst_add(g, ad.module, ad.node, unsafe recv.am[i as usize], unsafe recv.at[i as usize]) {
                    return false;
                }
            } else {
                let at2 = self.ce_type(xm, aid);
                if at2 == TYPE_NONE {
                    return false;
                }
                // a target arg typed as one of the extend's own params (e.g. the N of `W<T, N>`,
                // whose node may carry no generic-param resolution) binds like the resolved case
                let y2 = *self.ast_ptr(xm).type_at(at2);
                if y2.kind == TypeKind::TYPE_GENERIC {
                    if !self.ce_subst_add(
                        g,
                        y2.module,
                        y2.as_data.decl,
                        unsafe recv.am[i as usize],
                        unsafe recv.at[i as usize],
                    ) {
                        return false;
                    }
                } else if !self.ce_teq(xm, at2, unsafe recv.am[i as usize], unsafe recv.at[i as usize]) {
                    return false;
                }
            }
        }
        let gids = xa.list(gens);
        for j in 0..gens.len {
            let mut bound = false;
            for k in 0..unsafe g.ng {
                if unsafe g.pmod == xm && unsafe g.params_g[k as usize] == unsafe gids[j as usize] {
                    bound = true;
                }
            }
            if !bound {
                return false;
            }
        }
        return true;
    }

    // Does ce_intercept model this extern name? Heap/trap names are listed here (keep in sync with
    // ce_intercept below); libm names route through libm1/libm2 so those lists cannot drift.
    // Does this value point at single bytes? Only a byte pointer can address storage the abstract heap
    // does not carve into typed elements (an inline array, a struct field).
    const fn ce_ptr_elem_is_byte(self: &Self, v: CeVal) bool {
        if v.ty == TYPE_NONE {
            return false;
        }
        let y = self.ast_ptr(v.tm).type_at(v.ty);
        if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
            return false;
        }
        let e = self.ast_ptr(v.tm).type_at(y.as_data.elem);
        return e.kind == TypeKind::TYPE_BUILTIN && (e.as_data.builtin == BuiltinType::BT_U8 || e.as_data.builtin == BuiltinType::BT_I8 || e.as_data.builtin == BuiltinType::BT_CHAR);
    }

    fn ce_intercept_name(self: &Self, fm: ModuleId, nm: tok::Span) bool {
        if self.ce_span_is(fm, nm, "malloc") || self.ce_span_is(fm, nm, "realloc") || self.ce_span_is(fm, nm, "free") || self.ce_span_is(
            fm,
            nm,
            "memset",
        ) || self.ce_span_is(fm, nm, "memcpy") || self.ce_span_is(fm, nm, "memcmp") || self.ce_span_is(fm, nm, "abort") || self.ce_span_is(
            fm,
            nm,
            "__sc_panic_str",
        ) || self.ce_span_is(fm, nm, "__sc_panic") {
            return true;
        }
        let ln = (nm.end - nm.start) as usize;
        if ln == 0 || ln >= 24 {
            return false;
        }
        let mut name = Buf24 {};
        for ci in 0..ln {
            name[ci] = self.ce_src(fm)[nm.start as usize + ci] as char;
        }
        name[ln] = 0 as char;
        if ln > 1 && name[ln - 1] == 'f' as char {
            name[ln - 1] = 0 as char;
        }
        let nv = diag::cstr(&name[0]);
        if nv == "fma" {
            return true;
        }
        return libm1(nv, 0.0).ok || libm2(nv, 0.0, 0.0).ok;
    }

    // Intercepted extern calls: the C heap, the trap runtime, and libm.
    fn ce_intercept(
        self: &mut Self,
        fm: ModuleId,
        fnode: NodeId,
        args: *const CeVal,
        nargs: u32,
        m: ModuleId,
        callId: NodeId,
    ) Rets {
        let fa = self.ast_ptr(fm);
        let nm = self.name_text(fm, fa.at_const(fnode).as_data.function.name);
        let rt = self.ce_type(m, callId);
        let mut out = Rets { ok: false, n: 0 };
        if self.ce_span_is(fm, nm, "malloc") {
            if nargs != 1 || unsafe args[0].kind != CV_INT || unsafe args[0].as_data.i < 0 {
                return out;
            }
            let o = self.ce_obj_new(0);
            if o == 0 {
                return out;
            }
            unsafe self.obj_ptr(o).heap = 1;
            unsafe self.obj_ptr(o).bytes = (unsafe args[0].as_data.i) as u64;
            unsafe self.obj_ptr(o).et = TYPE_NONE;
            out.vals[0] = CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "realloc") {
            if nargs != 2 || unsafe args[0].kind != CV_PTR || unsafe args[1].kind != CV_INT || unsafe args[1].as_data.i < 0 {
                return out;
            }
            let nbytes = (unsafe args[1].as_data.i) as u64;
            if unsafe args[0].as_data.p.obj == 0 {
                let o = self.ce_obj_new(0);
                if o == 0 {
                    return out;
                }
                unsafe self.obj_ptr(o).heap = 1;
                unsafe self.obj_ptr(o).bytes = nbytes;
                unsafe self.obj_ptr(o).et = TYPE_NONE;
                out.vals[0] = CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
                out.n = 1;
                out.ok = true;
                return out;
            }
            let b = self.obj_ptr(unsafe args[0].as_data.p.obj);
            if b == null || unsafe b.heap == 0 || unsafe args[0].as_data.p.off != 0 {
                return out;
            }
            if unsafe b.dead != 0 {
                self.ce_trap(CE_TRAP_UB_USE_AFTER_FREE, "use after free");
                return out;
            }
            if unsafe b.et != TYPE_NONE {
                let esz = unsafe b.esz;
                if esz == 0 || nbytes % esz != 0 {
                    return out;
                }
                if !self.ce_obj_resize(unsafe args[0].as_data.p.obj, (nbytes / esz) as u32) {
                    return out;
                }
            }
            unsafe self.obj_ptr(unsafe args[0].as_data.p.obj).bytes = nbytes;
            out.vals[0] = CeVal {
                kind: CV_PTR,
                tm: m,
                ty: rt,
                as_data: CeValAs { p: CvPtr { obj: unsafe args[0].as_data.p.obj, off: 0 } },
            };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "free") {
            if nargs != 1 || unsafe args[0].kind != CV_PTR {
                return out;
            }
            if unsafe args[0].as_data.p.obj == 0 {
                out.ok = true;
                return out;
            }
            let b = self.obj_ptr(unsafe args[0].as_data.p.obj);
            if b == null || unsafe b.heap == 0 || unsafe args[0].as_data.p.off != 0 {
                return out;
            }
            if unsafe b.dead != 0 {
                self.ce_trap(CE_TRAP_UB_DOUBLE_FREE, "double free");
                return out;
            }
            unsafe b.dead = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "memset") {
            if nargs != 3 || unsafe args[0].kind != CV_PTR || unsafe args[1].kind != CV_INT || unsafe args[2].kind != CV_INT || unsafe args[2].as_data.i < 0 {
                return out;
            }
            let n = (unsafe args[2].as_data.i) as u64;
            if unsafe args[0].as_data.p.obj == 0 {
                out.ok = n == 0;
                return out;
            }
            let b = self.obj_ptr(unsafe args[0].as_data.p.obj);
            if b == null || unsafe b.heap == 0 {
                return out;
            }
            if unsafe b.dead != 0 {
                self.ce_trap(CE_TRAP_UB_USE_AFTER_FREE, "use after free");
                return out;
            }
            if unsafe b.et == TYPE_NONE && unsafe args[0].as_data.p.off == 0 {
                let bytes = unsafe b.bytes;
                if !self.ce_obj_resize(unsafe args[0].as_data.p.obj, bytes as u32) {
                    return out;
                }
                let b2 = self.obj_ptr(unsafe args[0].as_data.p.obj);
                unsafe b2.em = 0;
                unsafe b2.et = Ast::builtin(BuiltinType::BT_U8);
                unsafe b2.esz = 1;
            }
            let bb = self.obj_ptr(unsafe args[0].as_data.p.obj);
            let esz = unsafe bb.esz;
            if esz == 0 || n % esz != 0 {
                return out;
            }
            let count = n / esz;
            let off = (unsafe args[0].as_data.p.off) as u64;
            if off + count > (unsafe bb.slots.len()) as u64 {
                self.ce_trap(CE_TRAP_UB_OOB, "out-of-bounds access");
                return out;
            }
            let mut fill = cv_nil();
            if esz == 1 {
                fill = CeVal {
                    kind: CV_INT,
                    tm: 0,
                    ty: Ast::builtin(BuiltinType::BT_U8),
                    as_data: CeValAs { i: unsafe args[1].as_data.i & 0xff },
                };
            } else {
                if unsafe args[1].as_data.i != 0 {
                    return out;
                }
                fill = self.ce_zero(unsafe bb.em, unsafe bb.et, 0);
                if fill.kind == CV_NIL_K {
                    return out;
                }
            }
            for i in 0..count {
                let cloned = self.ce_clone(fill, 0);
                unsafe self.obj_ptr(unsafe args[0].as_data.p.obj).slots.set((off + i) as usize, cloned);
            }
            out.vals[0] = unsafe args[0];
            out.n = 1;
            out.ok = true;
            return out;
        }
        // memcpy: a slot-wise copy between two compile-time objects. Both sides must address elements
        // of the same size (the abstract heap has no bytes below its element type), which covers the
        // byte buffers this is actually used for -- String's inline storage, a Vector's block.
        if self.ce_span_is(fm, nm, "memcpy") {
            if nargs != 3 || unsafe args[0].kind != CV_PTR || unsafe args[1].kind != CV_PTR || unsafe args[2].kind != CV_INT || unsafe args[2].as_data.i < 0 {
                return out;
            }
            let n = (unsafe args[2].as_data.i) as u64;
            if n == 0 {
                out.vals[0] = unsafe args[0];
                out.n = 1;
                out.ok = true;
                return out;
            }
            let did = unsafe args[0].as_data.p.obj;
            let sid = unsafe args[1].as_data.p.obj;
            if did == 0 || sid == 0 {
                return out;
            }
            let dp = self.obj_ptr(did);
            let sp2 = self.obj_ptr(sid);
            if dp == null || sp2 == null {
                return out;
            }
            if unsafe dp.dead != 0 || unsafe sp2.dead != 0 {
                self.ce_trap(CE_TRAP_UB_USE_AFTER_FREE, "use after free");
                return out;
            }
            // A fresh HEAP block with no element type yet adopts the source's, exactly as memset does.
            // An inline array (String's small buffer) is not a heap block and must not be reshaped.
            if unsafe dp.heap != 0 && unsafe dp.et == TYPE_NONE && unsafe args[0].as_data.p.off == 0 && unsafe sp2.esz != 0 {
                let bytes = unsafe dp.bytes;
                let esz0 = unsafe sp2.esz;
                if bytes % esz0 == 0 && self.ce_obj_resize(did, (bytes / esz0) as u32) {
                    let d2 = self.obj_ptr(did);
                    unsafe d2.em = unsafe sp2.em;
                    unsafe d2.et = unsafe sp2.et;
                    unsafe d2.esz = esz0;
                }
            }
            let db = self.obj_ptr(did);
            let sb = self.obj_ptr(sid);
            // Element size: a heap block records it; anything else is only copyable through a byte
            // pointer, where the element IS the byte.
            let mut esz = unsafe db.esz;
            if unsafe db.heap == 0 {
                esz = 0;
                if self.ce_ptr_elem_is_byte(unsafe args[0]) {
                    esz = 1;
                }
            }
            let mut ssz = unsafe sb.esz;
            if unsafe sb.heap == 0 {
                ssz = 0;
                if self.ce_ptr_elem_is_byte(unsafe args[1]) {
                    ssz = 1;
                }
            }
            if esz == 0 || esz != ssz || n % esz != 0 {
                return out;
            }
            let count = n / esz;
            let doff = (unsafe args[0].as_data.p.off) as u64;
            let soff = (unsafe args[1].as_data.p.off) as u64;
            if doff + count > (unsafe db.slots.len()) as u64 || soff + count > (unsafe sb.slots.len()) as u64 {
                self.ce_trap(CE_TRAP_UB_OOB, "out-of-bounds access");
                return out;
            }
            for i in 0..count {
                let sv = unsafe self.obj_ptr(sid).slots[(soff + i) as usize];
                if sv.kind == CV_NIL_K {
                    return out;
                }
                let cloned = self.ce_clone(sv, 0);
                if cloned.kind == CV_NIL_K {
                    return out;
                }
                unsafe self.obj_ptr(did).slots.set((doff + i) as usize, cloned);
            }
            out.vals[0] = unsafe args[0];
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "memcmp") {
            if nargs != 3 || unsafe args[0].kind != CV_PTR || unsafe args[1].kind != CV_PTR || unsafe args[2].kind != CV_INT || unsafe args[2].as_data.i < 0 {
                return out;
            }
            let n = (unsafe args[2].as_data.i) as u64;
            if n == 0 {
                out.vals[0] = CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: 0 } };
                out.n = 1;
                out.ok = true;
                return out;
            }
            let b1 = self.obj_ptr(unsafe args[0].as_data.p.obj);
            let b2 = self.obj_ptr(unsafe args[1].as_data.p.obj);
            if b1 == null || b2 == null || unsafe b1.heap == 0 || unsafe b2.heap == 0 || unsafe b1.esz != 1 || unsafe b2.esz != 1 {
                return out; // byte-exact comparison is only modeled for 1-byte-element blocks
            }
            if unsafe b1.dead != 0 || unsafe b2.dead != 0 {
                self.ce_trap(CE_TRAP_UB_USE_AFTER_FREE, "use after free");
                return out;
            }
            let o1 = (unsafe args[0].as_data.p.off) as u64;
            let o2 = (unsafe args[1].as_data.p.off) as u64;
            if o1 + n > (unsafe b1.slots.len()) as u64 || o2 + n > (unsafe b2.slots.len()) as u64 {
                self.ce_trap(CE_TRAP_UB_OOB, "out-of-bounds access");
                return out;
            }
            let mut r: i64 = 0;
            for i in 0..n {
                let s1 = unsafe b1.slots[(o1 + i) as usize];
                let s2 = unsafe b2.slots[(o2 + i) as usize];
                if s1.kind != CV_INT || s2.kind != CV_INT {
                    return out; // uninitialized bytes: not comparable
                }
                let va = s1.as_data.i & 0xff;
                let vb = s2.as_data.i & 0xff;
                if va != vb {
                    r = if_i64(va < vb, -1, 1);
                    break;
                }
            }
            out.vals[0] = CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: r } };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "abort") {
            self.ce_trap(CE_TRAP_PANIC, "abort reached at compile time");
            return out;
        }
        if self.ce_span_is(fm, nm, "__sc_panic_str") || self.ce_span_is(fm, nm, "__sc_panic") {
            self.ce_trap(CE_TRAP_PANIC, "panic reached at compile time");
            return out;
        }
        // libm
        let ln = (nm.end - nm.start) as usize;
        if ln >= 24 || nargs < 1 || nargs > 3 {
            return out;
        }
        let mut name = Buf24 {};
        for ci in 0..ln {
            name[ci] = self.ce_src(fm)[nm.start as usize + ci] as char;
        }
        name[ln] = 0 as char;
        let mut f32suf = false;
        if ln > 1 && name[ln - 1] == 'f' as char {
            f32suf = true;
            name[ln - 1] = 0 as char;
        }
        let mut inv: [f64; 3] = [0.0f64, 0.0f64, 0.0f64];
        for i in 0..nargs {
            if unsafe args[i as usize].kind != CV_FLOAT {
                return out;
            }
            unsafe inv[i as usize] = unsafe args[i as usize].as_data.f;
        }
        let nv = diag::cstr(&name[0]);
        let mut v: f64 = 0.0;
        let mut ok = false;
        if nargs == 1 {
            let r = libm1(nv, inv[0]);
            ok = r.ok;
            v = r.v;
        } else if nargs == 2 {
            let r = libm2(nv, inv[0], inv[1]);
            ok = r.ok;
            v = r.v;
        } else {
            if nv == "fma" {
                v = unsafe math::fma(inv[0], inv[1], inv[2]);
                ok = true;
            }
        }
        if !ok {
            return out;
        }
        if f32suf {
            v = v as f32;
        }
        out.vals[0] = CeVal { kind: CV_FLOAT, tm: m, ty: rt, as_data: CeValAs { f: v } };
        out.n = 1;
        out.ok = true;
        return out;
    }

    // Run a resolved concrete function/closure body in a fresh frame. A failed invoke of a
    // `const fn` is always promotable (the annotation is a guarantee): flag it, synthesizing an
    // UNSUPPORTED trap when the failure was silent.
    fn ce_invoke(
        self: &mut Self,
        fm: ModuleId,
        fnode: NodeId,
        extend_node: NodeId,
        recv: *const CeRecv,
        monom: *const ModuleId,
        monot: *const TypeId,
        nmono: u8,
        args: *const CeVal,
        nargs: u32,
        self_pm: ModuleId,
        self_decl: NodeId,
        self_am: ModuleId,
        self_at: TypeId,
    ) Rets {
        let saved_ran = self.invoke_ran;
        self.invoke_ran = false;
        let r = self.ce_invoke_inner(
            fm,
            fnode,
            extend_node,
            recv,
            monom,
            monot,
            nmono,
            args,
            nargs,
            self_pm,
            self_decl,
            self_am,
            self_at,
        );
        // The const-fn guarantee covers invocations whose bindings resolved and whose body ran
        // (invoke_ran); failing to bind receiver/generics/args means the call site's inputs were
        // not compile-time known — that is not a broken `const fn`.
        if !r.ok && (self.invoke_ran || self.trap.len() != 0) {
            let fa = self.ast_ptr(fm);
            if fa.at_const(fnode).kind == NodeKind::NODE_FUNCTION && fa.at_const(fnode).as_data.function.is_const {
                // a silent failure before the whole package is typed may just be module order:
                // only synthesize the definite trap once all_typed (flush/codegen phases)
                if self.trap.len() == 0 && self.all_typed {
                    self.ce_trap(
                        CE_TRAP_UNSUPPORTED,
                        "a 'const fn' hit an operation the compile-time evaluator does not support",
                    );
                }
                self.trap_in_constfn = true;
            }
        }
        self.invoke_ran = saved_ran;
        return r;
    }

    fn ce_invoke_inner(
        self: &mut Self,
        fm: ModuleId,
        fnode: NodeId,
        extend_node: NodeId,
        recv: *const CeRecv,
        monom: *const ModuleId,
        monot: *const TypeId,
        nmono: u8,
        args: *const CeVal,
        nargs: u32,
        self_pm: ModuleId,
        self_decl: NodeId,
        self_am: ModuleId,
        self_at: TypeId,
    ) Rets {
        let mut out = Rets { ok: false, n: 0 };
        let fa = self.ast_ptr(fm);
        let closure = fa.at_const(fnode).kind == NodeKind::NODE_CLOSURE;
        if !closure && fa.at_const(fnode).kind != NodeKind::NODE_FUNCTION {
            return out;
        }
        let mut params = NodeList { start: 0, len: 0 };
        let mut body = NODE_NONE;
        if closure {
            params = fa.at_const(fnode).as_data.closure.params;
            body = fa.at_const(fnode).as_data.closure.body;
        } else {
            params = fa.at_const(fnode).as_data.function.params;
            body = fa.at_const(fnode).as_data.function.body;
        }
        if body == NODE_NONE || params.len != nargs {
            return out;
        }
        if !closure && fa.at_const(fnode).as_data.function.is_variadic {
            return out;
        }
        // Prefilter: FX_NO means evaluation is certain to fail, so skip interpreting the body.
        if !closure && self.fx_get(fm, fnode) == FX_NO {
            return out;
        }
        if self.nframes >= CE_MAX_FRAMES {
            self.ce_trap(CE_TRAP_BUDGET_DEPTH, "const-eval call depth exceeded");
            return out;
        }
        let mut g = ce_frame_zero();
        let gp = (&mut g) as *mut CeFrame;
        if self_decl != NODE_NONE && !self.ce_subst_add(gp, self_pm, self_decl, self_am, self_at) {
            return out;
        }
        if extend_node != NODE_NONE {
            let xg = fa.at_const(extend_node).as_data.extend_def.generics;
            let mut bound = xg.len == 0;
            if !bound && recv != null && unsafe recv.dn != NODE_NONE && unsafe recv.n != 0 {
                bound = self.ce_bind_extend(gp, fm, extend_node, recv);
            }
            if !bound {
                if nmono as u32 < xg.len {
                    return out;
                }
                let gids = fa.list(xg);
                for i in 0..xg.len {
                    if unsafe monot[i as usize] == TYPE_NONE || !self.ast_ptr(unsafe monom[i as usize]).type_concrete(
                        unsafe monot[i as usize],
                    ) || self.ce_ty_no_const(unsafe monom[i as usize], unsafe monot[i as usize], 0) {
                        // a '@no_const' type argument puts the instantiation outside the const
                        // contract: skip the fold silently (invoke_ran stays false -> no promotion)
                        return out;
                    }
                    if !self.ce_subst_add(
                        gp,
                        fm,
                        unsafe gids[i as usize],
                        unsafe monom[i as usize],
                        unsafe monot[i as usize],
                    ) {
                        return out;
                    }
                }
            }
        }
        if !closure {
            let fg = fa.at_const(fnode).as_data.function.generics;
            if fg.len != 0 {
                if nmono as u32 < fg.len {
                    return out;
                }
                let skip = nmono as u32 - fg.len;
                let gids = fa.list(fg);
                for i in 0..fg.len {
                    let idx = (skip + i) as usize;
                    if unsafe monot[idx] == TYPE_NONE || !self.ast_ptr(unsafe monom[idx]).type_concrete(
                        unsafe monot[idx],
                    ) || self.ce_ty_no_const(unsafe monom[idx], unsafe monot[idx], 0) {
                        // same rule as extend generics: '@no_const' type arguments never fold
                        return out;
                    }
                    if !self.ce_subst_add(gp, fm, unsafe gids[i as usize], unsafe monom[idx], unsafe monot[idx]) {
                        return out;
                    }
                }
            }
        }
        // Memoization: monomorphic calls with all-scalar arguments only; results are cached only when
        // every return is scalar -- an aggregate would hold ids into an object heap that resets
        // between top-level folds.
        let mut cacheable = !closure && unsafe gp.ng == 0 && nargs <= 8;
        let mut ai: u32 = 0;
        while cacheable && ai < nargs {
            cacheable = cv_is_scalar(unsafe args[ai as usize]);
            ai = ai + 1;
        }
        let mut ck = CeCallKey { m: fm, fn_id: fnode, nargs: nargs as u8 };
        if cacheable {
            for i in 0..nargs {
                unsafe ck.kinds[i as usize] = unsafe args[i as usize].kind;
                unsafe ck.bits[i as usize] = unsafe args[i as usize].as_data.i;
            }
            switch self.calls.get(&ck) {
                Some(hit) => {
                    out.n = hit.nrets;
                    for j in 0..hit.nrets {
                        unsafe out.vals[j as usize] = unsafe hit.rets[j as usize];
                    }
                    out.ok = true;
                    return out;
                },
                _ => {},
            };
        }
        unsafe gp.env = self.ce_obj_new(0);
        if unsafe gp.env == 0 {
            return out;
        }
        let pids = fa.list(params);
        for i in 0..nargs {
            let pt0 = self.ce_type(fm, fa.at_const(unsafe pids[i as usize]).as_data.parameter.ty);
            let mut v = unsafe args[i as usize];
            let rr = self.ce_rtype(gp, fm, pt0);
            if rr.ok {
                v = self.ce_coerce(v, rr.m, rr.t);
            }
            if v.kind == CV_NIL_K || !self.ce_bind(gp, unsafe pids[i as usize], v) {
                return out;
            }
        }
        self.invoke_ran = true;
        unsafe self.fstack[self.nframes as usize] = CvFn { m: fm, fn_id: fnode };
        self.nframes = self.nframes + 1;
        let saved = self.depth;
        self.depth = 0;
        let mut st = Flow::Ok;
        if closure && fa.at_const(fnode).as_data.closure.expr_body {
            let v = self.ev_in(gp, fm, body);
            if v.kind == CV_NIL_K {
                st = Flow::Bail;
            } else {
                st = Flow::Return;
            }
            unsafe gp.rets[0] = v;
            unsafe gp.nrets = 1;
            unsafe gp.returned = 1;
        } else {
            st = self.exec_stmt(gp, fm, body);
        }
        self.depth = saved;
        self.nframes = self.nframes - 1;
        if st == Flow::Bail || st == Flow::Break || st == Flow::Continue {
            return out;
        }
        let mut wantret: u32 = 1;
        if !closure {
            wantret = fa.at_const(fnode).as_data.function.returns.len;
            if wantret == 1 {
                let r0 = unsafe fa.list(fa.at_const(fnode).as_data.function.returns)[0];
                if type_builtin(fa, self.ce_type(fm, r0)) == BuiltinType::BT_VOID {
                    wantret = 0;
                }
            }
        }
        if unsafe gp.returned == 0 {
            if wantret > 0 && st != Flow::Return {
                return out;
            }
            unsafe gp.nrets = 0;
        }
        out.n = unsafe gp.nrets;
        for j in 0..unsafe gp.nrets {
            unsafe out.vals[j as usize] = unsafe gp.rets[j as usize];
        }
        if cacheable && out.n <= 8 {
            let mut pure = true;
            let mut k: u8 = 0;
            while pure && k < out.n {
                pure = cv_is_scalar(unsafe out.vals[k as usize]);
                k = k + 1;
            }
            if pure && self.calls.len() < CE_CALLS_MAX {
                let mut hit = CeCallHit { nrets: out.n };
                for z in 0..out.n {
                    unsafe hit.rets[z as usize] = unsafe out.vals[z as usize];
                }
                self.calls.insert(ck, hit);
            }
        }
        out.ok = true;
        return out;
    }

    fn ce_dispatch(self: &mut Self, r: CeRecv, scope: ModuleId, lit: str, args: *const CeVal, nargs: u32) ValRes {
        let mut extnode = NODE_NONE;
        let md = self.ce_find_method(r, scope, 0, tok::Span::empty(), lit, &mut extnode);
        if md.node == NODE_NONE {
            return ValRes { ok: false };
        }
        let inv = self.ce_invoke(
            md.module,
            md.node,
            extnode,
            &r,
            null,
            null,
            0,
            args,
            nargs,
            0,
            NODE_NONE,
            0,
            TYPE_NONE,
        );
        if !inv.ok {
            return ValRes { ok: false };
        }
        let mut out = cv_nil();
        if inv.n != 0 {
            out = inv.vals[0];
        }
        return ValRes { ok: true, v: out };
    }

    fn ce_call(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Rets {
        let a = self.ast_ptr(m);
        let mut callee = a.at_const(id).as_data.call.callee;
        let mut ck = a.at_const(callee).kind;
        if ck == NodeKind::NODE_GENERIC_SPECIALIZATION {
            callee = a.at_const(callee).as_data.specialization.expression;
            ck = a.at_const(callee).kind;
        }
        // type_info::<T>(): intrinsic, no declaration -- the unresolved name is the marker.
        if ck == NodeKind::NODE_IDENTIFIER && a.resolution_def(callee).node == NODE_NONE && a.resolution(callee) == NODE_NONE && self.ce_span_is(
            m,
            a.at_const(callee).as_data.name.text,
            "type_info",
        ) {
            return self.ce_type_info(f, m, id);
        }
        let call_args = a.at_const(id).as_data.call.args;
        let nargs = call_args.len;
        let mut out = Rets { ok: false, n: 0 };
        if nargs + 1 > 8 {
            return out;
        }

        let mut fd = DefId { module: 0, node: NODE_NONE };
        let mut recv_expr = NODE_NONE;
        let mut du: *const DerefUse = null;
        let mut have_recv_type = false;
        let mut recv_syn = DefId { module: 0, node: NODE_NONE };
        let mut rtm: ModuleId = 0;
        let mut rtt = TYPE_NONE;
        if ck == NodeKind::NODE_IDENTIFIER {
            fd = a.resolution_def(callee);
            if fd.node == NODE_NONE {
                fd = DefId { module: m, node: a.resolution(callee) };
            }
            if fd.node != NODE_NONE && fd.module as usize < self.nmods && self.ast_ptr(fd.module).at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
                let v = self.ev_rval(f, m, callee);
                if v.kind != CV_FN {
                    return out;
                }
                fd = DefId { module: v.as_data.fnv.m, node: v.as_data.fnv.fn_id };
            }
        } else if ck == NodeKind::NODE_MEMBER {
            fd = a.resolution_def(callee);
            if fd.node == NODE_NONE {
                fd = a.resolution_def(a.at_const(callee).as_data.member.member);
            }
            let is_path = a.at_const(callee).as_data.member.path;
            let obj_n = a.at_const(callee).as_data.member.object;
            if is_path {
                if obj_n != NODE_NONE && self.ce_type(m, obj_n) != TYPE_NONE {
                    have_recv_type = true;
                    rtm = m;
                    rtt = self.ce_type(m, obj_n);
                } else if obj_n != NODE_NONE {
                    recv_syn = a.resolution_def(obj_n);
                    if recv_syn.node == NODE_NONE {
                        recv_syn = DefId { module: m, node: a.resolution(obj_n) };
                    }
                }
            } else {
                recv_expr = obj_n;
                have_recv_type = true;
                rtm = m;
                rtt = self.ce_type(m, recv_expr);
                du = a.deref_use_at(a.at_const(callee).as_data.member.member);
                if fd.node == NODE_NONE {
                    let mname = self.name_text(m, a.at_const(callee).as_data.member.member);
                    if !self.ce_span_is(m, mname, "free") || nargs != 0 {
                        return out;
                    }
                    let sr = self.ce_strip_refptr(f, rtm, rtt);
                    if !sr.ok {
                        return out;
                    }
                    let rr = self.ce_recv_of(f, sr.m, sr.t);
                    if !rr.ok {
                        return out;
                    }
                    if rr.r.dn == NODE_NONE {
                        out.ok = true;
                        return out;
                    }
                    let mut extnode = NODE_NONE;
                    let md = self.ce_find_method(rr.r, m, 0, tok::Span::empty(), "free", &mut extnode);
                    if md.node == NODE_NONE {
                        out.ok = true;
                        return out;
                    }
                    let mut recv = cv_nil();
                    let was_pr = self.trap_mark();
                    let pr = self.ev_place(f, m, recv_expr);
                    if pr.ok {
                        recv = pr.v;
                    } else {
                        self.trap_discard(was_pr);
                        let rv = self.ev_in(f, m, recv_expr);
                        if rv.kind == CV_PTR {
                            recv = rv;
                        } else {
                            let tr = self.ce_temp_place(rv);
                            if rv.kind == CV_NIL_K || !tr.ok {
                                return out;
                            }
                            recv = tr.v;
                        }
                    }
                    let mut avs: [CeVal; 8] = [
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                    ];
                    avs[0] = recv;
                    return self.ce_invoke(
                        md.module,
                        md.node,
                        extnode,
                        &rr.r,
                        null,
                        null,
                        0,
                        &avs[0],
                        1,
                        0,
                        NODE_NONE,
                        0,
                        TYPE_NONE,
                    );
                }
            }
        } else {
            return out;
        }
        if fd.node == NODE_NONE || fd.module as usize >= self.nmods {
            return out;
        }
        let mut fam = fd.module;
        let mut fnode = fd.node;
        let mut fkind = self.ast_ptr(fam).at_const(fnode).kind;

        if fkind == NodeKind::NODE_VARIANT {
            let vp = self.ce_variant_pos(fd.module, fd.node);
            if vp.pos < 0 || !self.ce_enum_tagged(fd.module, vp.enum_decl) {
                return out;
            }
            let vpayload = self.ast_ptr(fd.module).at_const(fd.node).as_data.variant.payload;
            if vpayload.len != nargs || self.ce_user_free(fd.module, vp.enum_decl) {
                return out;
            }
            let o = self.ce_obj_new(1 + nargs);
            if o == 0 {
                return out;
            }
            unsafe self.obj_ptr(o).is_enum = 1;
            unsafe self.obj_ptr(o).dm = fd.module;
            unsafe self.obj_ptr(o).dn = vp.enum_decl;
            unsafe self.obj_ptr(o).slots.set(
                0,
                CeVal { kind: CV_INT, tm: 0, ty: TYPE_NONE, as_data: CeValAs { i: vp.pos } },
            );
            for i in 0..nargs {
                let v = self.ev_in(f, m, unsafe a.list(call_args)[i as usize]);
                if v.kind == CV_NIL_K {
                    return out;
                }
                let cloned = self.ce_clone(v, 0);
                if cloned.kind == CV_NIL_K {
                    return out;
                }
                unsafe self.obj_ptr(o).slots.set((1 + i) as usize, cloned);
            }
            out.vals[0] = CeVal {
                kind: CV_AGG,
                tm: m,
                ty: self.ce_type(m, id),
                as_data: CeValAs { p: CvPtr { obj: o, off: 0 } },
            };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if fkind != NodeKind::NODE_FUNCTION && fkind != NodeKind::NODE_CLOSURE {
            return out;
        }

        // `x.into()` runs `Target::from(x)`: the owner whose generics bind is the TARGET, which is this
        // call's own type -- the receiver is the argument. Deriving the owner from the receiver found no
        // aggregate at all (an array, a slice) and the call was simply unevaluable.
        let mut conv_ty = TYPE_NONE;
        if ck == NodeKind::NODE_MEMBER && !a.at_const(callee).as_data.member.path && fkind == NodeKind::NODE_FUNCTION {
            let mname = self.name_text(m, a.at_const(callee).as_data.member.member);
            let fname = self.name_text(fd.module, self.ast_ptr(fd.module).at_const(fd.node).as_data.function.name);
            if self.ce_span_is(m, mname, "into") && self.ce_span_is(fd.module, fname, "from") {
                conv_ty = self.ce_type(m, id);
            }
        }
        let mut recv_id = ce_recv_zero();
        let mut have_recv_id = false;
        if conv_ty != TYPE_NONE {
            let sr = self.ce_strip_refptr(f, m, conv_ty);
            if sr.ok {
                let rr = self.ce_recv_of(f, sr.m, sr.t);
                have_recv_id = rr.ok;
                if rr.ok {
                    recv_id = rr.r;
                }
            }
        } else if have_recv_type {
            let mut dt = rtt;
            if du != null {
                dt = unsafe du.target;
            }
            let sr = self.ce_strip_refptr(f, rtm, dt);
            if sr.ok {
                let rr = self.ce_recv_of(f, sr.m, sr.t);
                have_recv_id = rr.ok;
                if rr.ok {
                    recv_id = rr.r;
                }
            }
        } else if recv_syn.node != NODE_NONE && recv_syn.module as usize < self.nmods {
            let odk = self.ast_ptr(recv_syn.module).at_const(recv_syn.node).kind;
            if odk == NodeKind::NODE_GENERIC_PARAM && f != null {
                for i in 0..unsafe f.ng {
                    if unsafe f.pmod == recv_syn.module && unsafe f.params_g[i as usize] == recv_syn.node {
                        let rr = self.ce_recv_of(null, unsafe f.am[i as usize], unsafe f.at[i as usize]);
                        have_recv_id = rr.ok;
                        if rr.ok {
                            recv_id = rr.r;
                        }
                        break;
                    }
                }
            } else if odk == NodeKind::NODE_STRUCT || odk == NodeKind::NODE_ENUM {
                recv_id = ce_recv_zero();
                recv_id.dm = recv_syn.module;
                recv_id.dn = recv_syn.node;
                have_recv_id = true;
            }
        }
        let mut container = NODE_NONE;
        let mut ckind = 0;
        if fkind != NodeKind::NODE_CLOSURE {
            ckind = self.ce_container_of(fd.module, fd.node, &mut container);
        }
        let mut self_pm: ModuleId = 0;
        let mut self_decl = NODE_NONE;
        let mut self_am: ModuleId = 0;
        let mut self_at = TYPE_NONE;
        if ckind == 2 {
            if !have_recv_id {
                return out;
            }
            let mname = self.name_text(fam, self.ast_ptr(fam).at_const(fnode).as_data.function.name);
            let mut extnode = NODE_NONE;
            let md = self.ce_find_method(recv_id, m, fd.module, mname, "", &mut extnode);
            if md.node != NODE_NONE {
                fd = md;
                fam = fd.module;
                fnode = fd.node;
                fkind = self.ast_ptr(fam).at_const(fnode).kind;
                container = extnode;
                ckind = 1;
            } else if self.ast_ptr(fam).at_const(fnode).as_data.function.body != NODE_NONE {
                if recv_id.dn == NODE_NONE {
                    self_at = Ast::builtin(recv_id.b);
                } else if recv_id.n == 0 {
                    self_at = self.ce_pool_find_type(recv_id.dm, recv_id.dn);
                } else {
                    self_at = TYPE_NONE;
                }
                if self_at == TYPE_NONE {
                    return out;
                }
                self_am = 0;
                if recv_id.dn != NODE_NONE {
                    self_am = recv_id.dm;
                }
                self_pm = fd.module;
                self_decl = container;
                ckind = 0;
            } else {
                return out;
            }
        }

        // extern
        if fkind == NodeKind::NODE_FUNCTION && self.ast_ptr(fam).at_const(fnode).as_data.function.is_extern {
            let mut argv: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            for i in 0..nargs {
                unsafe argv[i as usize] = self.ev_rval(f, m, unsafe a.list(call_args)[i as usize]);
                if unsafe argv[i as usize].kind == CV_NIL_K {
                    return out;
                }
            }
            return self.ce_intercept(fd.module, fnode, &argv[0], nargs, m, id);
        }

        // arguments; a method receiver is param 0
        let mut argv: [CeVal; 9] = [
            cv_nil(),
            cv_nil(),
            cv_nil(),
            cv_nil(),
            cv_nil(),
            cv_nil(),
            cv_nil(),
            cv_nil(),
            cv_nil(),
        ];
        let mut na: u32 = 0;
        let mut params = NodeList { start: 0, len: 0 };
        if fkind == NodeKind::NODE_CLOSURE {
            params = self.ast_ptr(fam).at_const(fnode).as_data.closure.params;
        } else {
            params = self.ast_ptr(fam).at_const(fnode).as_data.function.params;
        }
        if recv_expr != NODE_NONE {
            if params.len != nargs + 1 {
                return out;
            }
            let p0 = unsafe self.ast_ptr(fam).list(params)[0];
            let p0t = self.ce_type(fam, self.ast_ptr(fam).at_const(p0).as_data.parameter.ty);
            let want_ref = p0t != TYPE_NONE && self.ast_ptr(fam).type_at(p0t).kind == TypeKind::TYPE_REFERENCE;
            if want_ref || du != null {
                let sr = self.ce_rtype(f, m, rtt);
                let mut recv_is_ptr = false;
                if sr.ok {
                    let sk = self.ast_ptr(sr.m).type_at(sr.t).kind;
                    recv_is_ptr = sk == TypeKind::TYPE_REFERENCE || sk == TypeKind::TYPE_POINTER;
                }
                if recv_is_ptr {
                    unsafe argv[na as usize] = self.ev_in(f, m, recv_expr);
                    if unsafe argv[na as usize].kind != CV_PTR {
                        return out;
                    }
                } else {
                    let was_pr = self.trap_mark();
                    let pr = self.ev_place(f, m, recv_expr);
                    if pr.ok {
                        unsafe argv[na as usize] = pr.v;
                    } else {
                        self.trap_discard(was_pr);
                        let rv = self.ev_in(f, m, recv_expr);
                        let tr = self.ce_temp_place(rv);
                        if rv.kind == CV_NIL_K || !tr.ok {
                            return out;
                        }
                        unsafe argv[na as usize] = tr.v;
                    }
                }
            } else {
                unsafe argv[na as usize] = self.ev_rval(f, m, recv_expr);
                if unsafe argv[na as usize].kind == CV_NIL_K {
                    return out;
                }
            }
            if du != null {
                for hi in 0..unsafe du.n {
                    let hrr = self.ce_recv_of(f, m, unsafe du.recv[hi as usize]);
                    let mut hext = NODE_NONE;
                    if !hrr.ok || self.ce_container_of(
                        unsafe du.method[hi as usize].module,
                        unsafe du.method[hi as usize].node,
                        &mut hext,
                    ) != 1 {
                        return out;
                    }
                    let mut ha: [CeVal; 8] = [
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                        cv_nil(),
                    ];
                    ha[0] = unsafe argv[na as usize];
                    let hinv = self.ce_invoke(
                        unsafe du.method[hi as usize].module,
                        unsafe du.method[hi as usize].node,
                        hext,
                        &hrr.r,
                        null,
                        null,
                        0,
                        &ha[0],
                        1,
                        0,
                        NODE_NONE,
                        0,
                        TYPE_NONE,
                    );
                    if !hinv.ok || hinv.n != 1 || hinv.vals[0].kind != CV_PTR {
                        return out;
                    }
                    unsafe argv[na as usize] = hinv.vals[0];
                }
                if !want_ref {
                    let lr = self.ce_loadp(unsafe argv[na as usize]);
                    if !lr.ok {
                        return out;
                    }
                    unsafe argv[na as usize] = lr.v;
                }
            }
            na = na + 1;
        } else if params.len != nargs {
            return out;
        }
        for i in 0..nargs {
            unsafe argv[na as usize] = self.ev_in(f, m, unsafe a.list(call_args)[i as usize]);
            if unsafe argv[na as usize].kind == CV_NIL_K {
                return out;
            }
            na = na + 1;
        }

        // mono args
        let mut monom: [ModuleId; 4] = [0u16, 0u16, 0u16, 0u16];
        let mut monot: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        let mut nmono: u8 = 0;
        let mu = a.type_args(id);
        if mu != null {
            let mut k: u8 = 0;
            while k < unsafe mu.n && k < 8 {
                unsafe monom[nmono as usize] = m;
                unsafe monot[nmono as usize] = self.ce_subst_deep(f, m, unsafe mu.args[k as usize], 0);
                nmono = nmono + 1;
                k = k + 1;
            }
        }
        let mut ext_arg = NODE_NONE;
        if ckind == 1 {
            ext_arg = container;
        }
        let mut rp: *const CeRecv = null;
        if have_recv_id {
            rp = &recv_id;
        }
        return self.ce_invoke(
            fd.module,
            fd.node,
            ext_arg,
            rp,
            &monom[0],
            &monot[0],
            nmono,
            &argv[0],
            na,
            self_pm,
            self_decl,
            self_am,
            self_at,
        );
    }

    // --- public boundary ---
    /// The public fold boundary: the memoized scalar value of typed expression (m,id), else
    /// CONST_NONE. A top-level call (no live eval) resets budgets, trap state and the object heap;
    /// after a failed fold, ce_trap_get/ce_trap_detail say why. Non-scalar successes memoize as
    /// AGG_OK and still report CONST_NONE.
    pub fn eval(self: &mut Self, m: ModuleId, id: NodeId) ConstValue {
        if id == NODE_NONE || m as usize >= self.nmods {
            return ce_none();
        }
        let memo = self.slot_get(m, id);
        if memo.kind == CONST_EVALUATING {
            self.ce_trap(CE_TRAP_CYCLE, "cyclic constant dependency");
            return ce_none();
        }
        if memo.kind == CONST_AGG_OK {
            return ce_none(); // known non-scalar success: nothing to fold, nothing to re-run
        }
        if memo.kind != CONST_NONE {
            return memo;
        }
        if self.depth > CE_MAX_DEPTH as u32 {
            return ce_none();
        }
        let top = self.depth == 0 && self.nframes == 0;
        if top {
            self.steps = 0;
            self.trap = "";
            self.trap_kind = CE_TRAP_NONE;
            self.trap_nframes = 0;
            self.trap_in_constfn = false;
            self.ce_objs_reset();
        }
        self.slot_set(m, id, ConstValue { kind: CONST_EVALUATING });
        self.depth = self.depth + 1;
        let v = self.ev(null, m, id);
        self.depth = self.depth - 1;
        let pub_v = cv_pub(v);
        if top {
            self.ce_objs_reset();
        }
        // record only genuine failures: a successful aggregate/fn/pointer result also publishes
        // CONST_NONE (the scalar memo covers scalars only) but is not a failed fold
        if top && self.record_folds && self.record_pause == 0 && v.kind == CV_NIL_K && (ce_trap_is_ub(self.trap_kind) || self.trap_in_constfn) {
            self.record_fold_err(m, id);
        }
        // scalar success stores the value; non-scalar success stores the AGG_OK fact; failure
        // restores CONST_NONE (clears the sentinel, stays retryable)
        if pub_v.kind == CONST_NONE && v.kind != CV_NIL_K {
            self.slot_set(m, id, ConstValue { kind: CONST_AGG_OK });
        } else {
            self.slot_set(m, id, pub_v);
        }
        return pub_v;
    }

    pub const fn ce_trap_get(self: &Self) str {
        return self.trap;
    }

    @c.cold
    fn record_fold_err(self: &mut Self, m: ModuleId, id: NodeId) {
        // dedupe: emits_own_parens + emit_expr probe the same failing id twice
        for i in 0..self.fold_errs.len() {
            let r = self.fold_errs.at(i);
            if r.m == m && r.id == id {
                return;
            }
        }
        let detail = self.ce_trap_detail();
        let mut rec = CeFoldErr { m: m, id: id, kind: self.trap_kind, constfn: self.trap_in_constfn };
        let mut i: usize = 0;
        while i < detail.len() && i + 1 < 512 {
            rec.detail[i] = detail[i] as char;
            i = i + 1;
        }
        rec.detail[i] = 0 as char;
        self.fold_errs.push(rec);
    }

    pub const fn ce_trap_kind_get(self: &Self) u8 {
        return self.trap_kind;
    }

    // ---- trap detail rendering (allocation-free, into dbuf) ----
    fn db_push(self: &mut Self, pos: usize, s: str) usize {
        let mut p = pos;
        let mut i: usize = 0;
        while i < s.len() && p + 1 < 512 {
            self.dbuf[p] = s[i] as char;
            p = p + 1;
            i = i + 1;
        }
        return p;
    }
    fn db_push_u32(self: &mut Self, pos: usize, v0: u32) usize {
        let mut tmp = Buf24 {};
        let mut n: usize = 0;
        let mut v = v0;
        do {
            tmp[n] = (b'0' + (v % 10) as u8) as char;
            v = v / 10;
            n = n + 1;
        } while v != 0;
        let mut p = pos;
        while n > 0 && p + 1 < 512 {
            n = n - 1;
            self.dbuf[p] = tmp[n];
            p = p + 1;
        }
        return p;
    }
    fn db_push_span(self: &mut Self, pos: usize, m: ModuleId, sp: tok::Span) usize {
        let src = self.ce_src(m);
        let mut p = pos;
        let mut i = sp.start;
        while i < sp.end && p + 1 < 512 {
            self.dbuf[p] = src[i as usize] as char;
            p = p + 1;
            i = i + 1;
        }
        return p;
    }

    /// Always-panics lint sweep (the `unconditional_panic` analog): interpret a runtime fn body's
    /// top-level statements in a fresh frame -- locals bind as their initializers fold, and the sweep
    /// ENDS at the first statement the interpreter cannot complete (params, runtime calls, budgets).
    /// Returns the statement whose evaluation traps DETERMINISTICALLY -- any UB, or a panic reached
    /// through a `const fn` frame (the checked-accessor class); an explicit user `panic(..)` stays
    /// silent, the same promotion rule as failed const-fn folds -- else NODE_NONE. The verdict is
    /// "always panics IF the function runs this far": statements execute sequentially, known control
    /// flow only.
    pub fn ce_lint_body(self: &mut Self, m: ModuleId, fn_id: NodeId) NodeId {
        if self.depth != 0 || self.nframes != 0 || m as usize >= self.nmods {
            return NODE_NONE;
        }
        let a = self.ast_ptr(m);
        let body = a.at_const(fn_id).as_data.function.body;
        if body == NODE_NONE || a.at_const(body).kind != NodeKind::NODE_BLOCK {
            return NODE_NONE;
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = CE_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.ce_objs_reset();
        let mut f = ce_frame_zero();
        f.env = self.ce_obj_new(0);
        if f.env == 0 {
            self.ce_objs_reset();
            return NODE_NONE;
        }
        // depth guard: a nested eval() of a module const must not think it is a TOP evaluation
        // (it would reset the trap state and the object heap out from under our frame)
        self.depth = 1;
        let stmts = a.at_const(body).as_data.block.statements;
        let mut hit = NODE_NONE;
        for i in 0..stmts.len {
            let sid = unsafe a.list(stmts)[i as usize];
            let flow = self.exec_stmt(&mut f, m, sid);
            if flow != Flow::Ok {
                if ce_trap_is_ub(self.trap_kind) || self.trap_kind == CE_TRAP_PANIC && self.trap_in_constfn {
                    hit = sid;
                }
                break;
            }
        }
        self.depth = 0;
        self.ce_objs_reset();
        return hit;
    }

    /// "<msg> (call stack: outer -> ... -> inner; steps: N/limit)"; sections omitted when empty.
    pub fn ce_trap_detail(self: &mut Self) str {
        let t = self.trap;
        let mut p = self.db_push(0, t);
        let nf = self.trap_nframes as u32;
        if nf != 0 {
            p = self.db_push(p, " (call stack: ");
            let mut show = nf;
            if show > 8 {
                show = 8;
                p = self.db_push(p, "... -> ");
            }
            let mut i = nf - show;
            while i < nf {
                if i != nf - show {
                    p = self.db_push(p, " -> ");
                }
                let fv = unsafe self.trap_stack[i as usize];
                let a = self.ast_ptr(fv.m);
                if a.at_const(fv.fn_id).kind == NodeKind::NODE_FUNCTION {
                    let nm = self.name_text(fv.m, a.at_const(fv.fn_id).as_data.function.name);
                    p = self.db_push_span(p, fv.m, nm);
                } else {
                    p = self.db_push(p, "<closure>");
                }
                i = i + 1;
            }
            p = self.db_push(p, "; steps: ");
            p = self.db_push_u32(p, self.trap_steps);
            p = self.db_push(p, "/");
            p = self.db_push_u32(p, self.max_steps);
            p = self.db_push(p, ")");
        } else if self.trap_kind == CE_TRAP_BUDGET_STEPS || self.trap_kind == CE_TRAP_BUDGET_MEMORY {
            p = self.db_push(p, " (steps: ");
            p = self.db_push_u32(p, self.trap_steps);
            p = self.db_push(p, "/");
            p = self.db_push_u32(p, self.max_steps);
            p = self.db_push(p, "; see --const-eval-steps/--const-eval-memory)");
        }
        self.dbuf[p] = 0 as char;
        return diag::cstr(&self.dbuf[0]);
    }

    /// Queue a static_assert condition for flush_asserts (re-checked once every module is typed).
    pub fn defer_assert(self: &mut Self, m: ModuleId, cond: NodeId) {
        self.pending.push(CePending { m: m, cond: cond });
    }

    /// A call-bearing const initializer undecidable in module order: re-checked by flush_consts.
    pub fn defer_const(self: &mut Self, m: ModuleId, decl: NodeId) {
        self.pending_consts.push(CePending { m: m, cond: decl });
    }

    /// Re-evaluate the deferred const initializers: err() fires with trap detail for a definite
    /// trap, and for a top-level const that still cannot be evaluated.
    pub fn flush_consts(self: &mut Self, err: fn(*mut void, ModuleId, NodeId, *const char) void, ctx: *mut void) {
        for i in 0..self.pending_consts.len() {
            let p = self.pending_consts[i];
            let value = self.ast_ptr(p.m).at_const(p.cond).as_data.const_def.value;
            let v = self.eval(p.m, value);
            if v.kind != CONST_NONE {
                continue;
            }
            if self.trap.len() == 0 && self.eval_static(p.m, value).ok {
                continue;
            }
            if self.trap.len() != 0 {
                err(ctx, p.m, p.cond, self.ce_trap_detail().ptr() as *const char);
            } else if self.ce_const_is_item(p.m, p.cond) {
                // every module is typed now, so a top-level const has no legitimate silent failure
                // left (only unsubstituted generics do, and those are local)
                err(
                    ctx,
                    p.m,
                    p.cond,
                    "the initializer requires execution but could not be evaluated".ptr() as *const char,
                );
            }
        }
        self.pending_consts.clear();
    }

    fn ce_const_is_item(self: &Self, m: ModuleId, id: NodeId) bool {
        let a = self.ast_ptr(m);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            if unsafe a.list(items)[i as usize] == id {
                return true;
            }
        }
        return false;
    }

    /// Re-evaluate the deferred asserts: err() gets null detail for a proven-false condition, trap
    /// detail for a definite trap; still-undecidable conditions stay silent.
    pub fn flush_asserts(self: &mut Self, err: fn(*mut void, ModuleId, NodeId, *const char) void, ctx: *mut void) {
        for i in 0..self.pending.len() {
            let p = self.pending[i];
            let v = self.eval(p.m, p.cond);
            if v.kind == CONST_BOOL && v.as_data.i == 0 {
                err(ctx, p.m, p.cond, null);
            } else if v.kind == CONST_NONE && self.trap.len() != 0 {
                err(ctx, p.m, p.cond, self.ce_trap_detail().ptr() as *const char);
            }
        }
        self.pending.clear();
    }
}

// --- static materialization -----------------------------------------------------------------------
// eval_static evaluates a const initializer like eval(), then serializes the resulting object graph
// into eval-lifetime-independent StaticObj records that codegen renders as static C data with
// relocations. Object identity is preserved (same CeObj -> same static), so shared and cyclic
// pointer graphs survive; deep-clone-on-store guarantees each object is embedded by value in at
// most one parent slot, so only pointers can multi-reference.

pub const CE_STATIC_MAX_SLOTS: u64 = 1048576u64; // 1<<20 serialized slots per constant

pub const SS_STRUCT: u8 = 0;
pub const SS_ENUM: u8 = 1;
pub const SS_ARRAY: u8 = 2;
pub const SS_HEAP: u8 = 3;
pub const SS_CELL: u8 = 4;

pub const SK_ZERO: u8 = 0;
pub const SK_INT: u8 = 1;
pub const SK_BOOL: u8 = 2;
pub const SK_FLOAT: u8 = 3;
pub const SK_NULL: u8 = 4;
pub const SK_AGG: u8 = 5;
pub const SK_REL: u8 = 6;

pub const SREL_STATIC: u8 = 0;
pub const SREL_INTERIOR: u8 = 1;
pub const SREL_FN: u8 = 2;

pub const S_NO_PARENT: u32 = 0xFFFFFFFFu32;

pub struct SRel {
    pub slot: u32,
    pub kind: u8,
    pub target: u32, // absolute statics index (SREL_STATIC/INTERIOR)
    pub toff: u32, // slot index inside the target (SREL_INTERIOR)
    pub fm: ModuleId, // SREL_FN
    pub fnode: NodeId,
}

pub struct SSlot {
    pub kind: u8,
    pub tm: ModuleId, // scalar value type for C literal suffixing
    pub ty: TypeId,
    pub i: i64,
    pub f: f64,
    pub child: u32, // SK_AGG: absolute statics index of the embedded child
}

pub struct StaticObj {
    pub shape: u8,
    pub dm: ModuleId, // SS_STRUCT/SS_ENUM decl identity
    pub dn: NodeId,
    pub nargs: u8, // SS_STRUCT generic instance args
    pub am: [ModuleId; 4],
    pub at: [TypeId; 4],
    pub etm: ModuleId, // HEAP/ARRAY element type; CELL value type
    pub ety: TypeId,
    pub n: u32, // HEAP/ARRAY element count
    pub uactive: i32, // union: the only member present; -1 for a struct/enum
    pub parent: u32, // embedding parent (statics index); S_NO_PARENT = standalone
    pub pslot: u32,
    pub owner: u32, // nearest standalone ancestor (self when standalone)
    pub ord: u32, // ordinal among the group's standalones: 0 = root, k>0 -> "<name>__ct{k-1}"
    pub groupn: u32, // root only: number of statics entries in this group
    pub slots: Vector<SSlot>,
    pub rels: Vector<SRel>,
}

extend StaticObj as Free {
    pub fn free(self: &mut Self) {
        self.slots.free();
        self.rels.free();
    }
}

// One live `inline for f in fields(..)` iteration in the interpreter: which loop, which field,
// and the evaluated subject the field values are read out of.
pub struct CeProj {
    pub binder: NodeId,
    pub k: i64,
    pub sub: CeVal,
    pub om: ModuleId,
    pub owner: TypeId,
}

pub struct StaticRes {
    pub ok: bool,
    pub root: u32,
}

extend ConstEval {
    const fn sref_get(self: &Self, m: ModuleId, id: NodeId) i64 {
        if m as usize >= self.sref.len() {
            return 0;
        }
        let inner = self.sref.at(m as usize);
        if id as usize >= inner.len() {
            return 0;
        }
        return inner[id as usize];
    }
    fn sref_set(self: &mut Self, m: ModuleId, id: NodeId, v: i64) {
        if m as usize >= self.sref.len() {
            return;
        }
        let inner = &mut self.sref[m as usize];
        while inner.len() <= id as usize {
            inner.push(0);
        }
        inner.set(id as usize, v);
    }

    /// Unchecked: `i` must index into statics (as returned by eval_static / StaticObj links).
    pub const fn static_at(self: &Self, i: u32) *const StaticObj {
        return unsafe (self.statics.as_ptr() + i as usize);
    }

    /// Evaluate a const initializer and capture an aggregate result as static data. Scalars return
    /// not-ok (the folded-literal path covers them); failures leave trap/trap_kind describing why.
    pub fn eval_static(self: &mut Self, m: ModuleId, id: NodeId) StaticRes {
        let bad = StaticRes { ok: false, root: 0 };
        if id == NODE_NONE || m as usize >= self.nmods || self.depth != 0 || self.nframes != 0 {
            return bad;
        }
        let memo = self.sref_get(m, id);
        if memo < 0 {
            return bad;
        }
        if memo > 0 {
            return StaticRes { ok: true, root: (memo - 1) as u32 };
        }
        let mk = self.slot_get(m, id).kind;
        if mk != CONST_NONE && mk != CONST_AGG_OK {
            return bad; // scalar memo hit (or in-flight): not an aggregate
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = CE_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.ce_objs_reset();
        self.slot_set(m, id, ConstValue { kind: CONST_EVALUATING });
        self.depth = 1;
        let v = self.ev(null, m, id);
        self.depth = 0;
        let pub_v = cv_pub(v);
        self.slot_set(m, id, pub_v);
        if v.kind != CV_AGG {
            self.ce_objs_reset();
            if pub_v.kind == CONST_NONE {
                if self.record_folds && self.record_pause == 0 && v.kind == CV_NIL_K && (ce_trap_is_ub(self.trap_kind) || self.trap_in_constfn) {
                    self.record_fold_err(m, id);
                }
                if self.trap.len() != 0 {
                    self.sref_set(m, id, -1); // definite failure; undecidable stays retryable
                }
            }
            return bad;
        }
        let r = self.ce_capture(v);
        self.ce_objs_reset();
        if !r.ok {
            self.sref_set(m, id, -1);
            return bad;
        }
        self.sref_set(m, id, r.root as i64 + 1);
        return r;
    }

    /// The `fields.len`/`variants.len` (`want` 0/1) of T's descriptor, computed by the same build
    /// the descriptor itself gets so the two can never disagree; -1 when T has none. Codegen's
    /// inline-for bound fold is the caller -- the T it resolved through its substitution frames is
    /// exactly what CTFE alone cannot see.
    pub fn type_info_count(self: &mut Self, m: ModuleId, id: NodeId, am: ModuleId, at: TypeId, want: i32) i64 {
        if id == NODE_NONE || m as usize >= self.nmods || self.depth != 0 || self.nframes != 0 {
            return -1;
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = CE_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.ce_objs_reset();
        self.depth = 1;
        let r0 = self.ce_type_info_of(null, m, id, am, at);
        self.depth = 0;
        self.ce_objs_reset();
        if !r0.ok {
            return -1;
        }
        if want == 0 {
            return self.ti_nfields;
        }
        return self.ti_nvars;
    }

    /// `type_info::<T>()` at a RUNTIME use site: build and capture the descriptor for the concrete
    /// (am, at) codegen resolved through its substitution frames. Unmemoized -- the same call node
    /// emits once per monomorphized instance, each with its own T, so the (module, node) memo
    /// `eval_static` uses would serve the first instance's answer to all of them.
    pub fn eval_type_info_static(self: &mut Self, m: ModuleId, id: NodeId, am: ModuleId, at: TypeId) StaticRes {
        let bad = StaticRes { ok: false, root: 0 };
        if id == NODE_NONE || m as usize >= self.nmods || self.depth != 0 || self.nframes != 0 {
            return bad;
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = CE_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.ce_objs_reset();
        self.depth = 1;
        let r0 = self.ce_type_info_of(null, m, id, am, at);
        self.depth = 0;
        if !r0.ok || r0.n != 1 || r0.vals[0].kind != CV_AGG {
            self.ce_objs_reset();
            return bad;
        }
        let r = self.ce_capture(r0.vals[0]);
        self.ce_objs_reset();
        return r;
    }

    @c.cold
    fn cap_fail(self: &mut Self, base: u32, kind: u8, msg: str) StaticRes {
        self.statics.truncate(base as usize);
        self.ce_trap(kind, msg);
        return StaticRes { ok: false, root: 0 };
    }

    fn ce_capture(self: &mut Self, rootv: CeVal) StaticRes {
        let bad = StaticRes { ok: false, root: 0 };
        let base = self.statics.len() as u32;
        let nobj = self.objs_live;
        let rid = rootv.as_data.p.obj;
        if rid == 0 || rid as usize > nobj {
            return bad;
        }
        // per-CeObj side tables (ids are 1-based)
        let mut map = Vector::<u32>::new(); // statics index + 1; 0 = unvisited
        let mut embp = Vector::<u32>::new(); // embedding parent CeObj id
        let mut embs = Vector::<u32>::new(); // slot in the embedding parent
        let mut hintm = Vector::<ModuleId>::new(); // value-type hint from the referencing CeVal
        let mut hintt = Vector::<TypeId>::new();
        map.reserve(nobj + 1);
        for _ in 0..nobj + 1 {
            map.push(0);
            embp.push(0);
            embs.push(0);
            hintm.push(0);
            hintt.push(TYPE_NONE);
        }
        hintm.set(rid as usize, rootv.tm);
        hintt.set(rid as usize, rootv.ty);
        // pass A: pre-order discovery; children pushed in reverse so pop order equals slot order
        let mut order = Vector::<u32>::new();
        let mut stack = Vector::<u32>::new();
        stack.push(rid);
        let mut total: u64 = 0;
        while stack.len() != 0 {
            let oid = stack[stack.len() - 1];
            stack.truncate(stack.len() - 1);
            if map[oid as usize] != 0 {
                continue;
            }
            let op = self.obj_ptr(oid);
            if op == null {
                return self.cap_fail(base, CE_TRAP_UNSUPPORTED, "constant value cannot be materialized as static data");
            }
            if unsafe op.dead != 0 {
                return self.cap_fail(base, CE_TRAP_UB_USE_AFTER_FREE, "constant points at freed compile-time memory");
            }
            let sl = (unsafe op.slots.len()) as u32;
            total = total + sl as u64;
            if total > CE_STATIC_MAX_SLOTS {
                return self.cap_fail(base, CE_TRAP_TOO_LARGE, "constant is too large to materialize as static data");
            }
            map.set(oid as usize, base + order.len() as u32 + 1);
            order.push(oid);
            let mut k = sl;
            while k > 0 {
                k = k - 1;
                let sv = unsafe self.obj_ptr(oid).slots[k as usize];
                if sv.kind == CV_AGG {
                    let c = sv.as_data.p.obj;
                    if c == 0 || c as usize > nobj {
                        return self.cap_fail(
                            base,
                            CE_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    embp.set(c as usize, oid);
                    embs.set(c as usize, k);
                    if sv.ty != TYPE_NONE {
                        hintm.set(c as usize, sv.tm);
                        hintt.set(c as usize, sv.ty);
                    }
                    stack.push(c);
                } else if sv.kind == CV_PTR && sv.as_data.p.obj != 0 {
                    let c = sv.as_data.p.obj;
                    if c as usize > nobj {
                        return self.cap_fail(
                            base,
                            CE_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    if sv.ty != TYPE_NONE && hintt[c as usize] == TYPE_NONE {
                        let y = self.ast_ptr(sv.tm).type_at(sv.ty);
                        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                            hintm.set(c as usize, sv.tm);
                            hintt.set(c as usize, y.as_data.elem);
                        }
                    }
                    stack.push(c);
                }
            }
        }
        // pass B: shape every discovered object
        let count = order.len();
        for idx in 0..count {
            let oid = order[idx];
            let sl = (unsafe self.obj_ptr(oid).slots.len()) as u32;
            let standalone = embp[oid as usize] == 0;
            let mut g = StaticObj {
                uactive: -1,
                shape: SS_CELL,
                parent: S_NO_PARENT,
                owner: 0,
                slots: Vector::<SSlot>::new(),
                rels: Vector::<SRel>::new(),
            };
            if !standalone {
                g.parent = map[embp[oid as usize] as usize] - 1;
                g.pslot = embs[oid as usize];
            }
            let op = self.obj_ptr(oid);
            if unsafe op.heap != 0 {
                g.shape = SS_HEAP;
                g.etm = unsafe op.em;
                g.ety = unsafe op.et;
                g.n = sl;
                if g.ety == TYPE_NONE {
                    self.statics.push(g);
                    return self.cap_fail(
                        base,
                        CE_TRAP_UNSUPPORTED,
                        "constant points at an untyped compile-time heap block",
                    );
                }
            } else if unsafe op.is_enum != 0 {
                g.shape = SS_ENUM;
                g.dm = unsafe op.dm;
                g.dn = unsafe op.dn;
                let gens = self.ast_ptr(g.dm).at_const(g.dn).as_data.aggregate.generics.len;
                if standalone && gens != 0 {
                    self.statics.push(g);
                    return self.cap_fail(
                        base,
                        CE_TRAP_UNSUPPORTED,
                        "constant value cannot be materialized as static data",
                    );
                }
            } else if unsafe op.dn != NODE_NONE {
                g.shape = SS_STRUCT;
                g.uactive = unsafe op.uactive; // a union serializes the one member it holds
                g.dm = unsafe op.dm;
                g.dn = unsafe op.dn;
                g.nargs = unsafe op.nargs;
                for ci in 0..4 {
                    unsafe g.am[ci] = unsafe op.am[ci];
                    unsafe g.at[ci] = unsafe op.at[ci];
                }
                let gens = self.ast_ptr(g.dm).at_const(g.dn).as_data.aggregate.generics.len;
                if standalone && gens != 0 && g.nargs == 0 {
                    self.statics.push(g);
                    return self.cap_fail(
                        base,
                        CE_TRAP_UNSUPPORTED,
                        "constant value cannot be materialized as static data",
                    );
                }
            } else {
                let hm = hintm[oid as usize];
                let ht = hintt[oid as usize];
                let mut isarr = false;
                if ht != TYPE_NONE {
                    let y = self.ast_ptr(hm).type_at(ht);
                    if y.kind == TypeKind::TYPE_ARRAY {
                        isarr = true;
                        g.shape = SS_ARRAY;
                        g.etm = hm;
                        g.ety = y.as_data.arr.elem;
                        g.n = sl;
                    }
                }
                if !isarr {
                    if sl != 1 || ht == TYPE_NONE {
                        self.statics.push(g);
                        return self.cap_fail(
                            base,
                            CE_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    g.shape = SS_CELL;
                    g.etm = hm;
                    g.ety = ht;
                }
            }
            self.statics.push(g);
        }
        // ordinals + owners
        let mut nstand: u32 = 0;
        for idx in 0..count {
            let gi = base as usize + idx;
            if self.statics[gi].parent == S_NO_PARENT {
                self.statics[gi].ord = nstand;
                nstand = nstand + 1;
            }
        }
        for idx in 0..count {
            let gi = base as usize + idx;
            let mut cur = gi as u32;
            let mut guard: usize = 0;
            while self.statics[cur as usize].parent != S_NO_PARENT && guard <= count {
                cur = self.statics[cur as usize].parent;
                guard = guard + 1;
            }
            self.statics[gi].owner = cur;
        }
        self.statics[base as usize].groupn = count as u32;
        // pass C: serialize slots + relocations
        for idx in 0..count {
            let oid = order[idx];
            let gi = base as usize + idx;
            let shape = self.statics[gi].shape;
            let sl = (unsafe self.obj_ptr(oid).slots.len()) as u32;
            let mut sslots = Vector::<SSlot>::new();
            let mut srels = Vector::<SRel>::new();
            let uact = self.statics[gi].uactive;
            for k in 0..sl {
                let sv = unsafe self.obj_ptr(oid).slots[k as usize];
                let mut s = SSlot { kind: SK_ZERO, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0, child: 0 };
                if uact >= 0 && k as i32 != uact {
                    sslots.push(s); // an inactive union member holds nothing; never emitted
                    continue;
                }
                if sv.kind == CV_INT || sv.kind == CV_BOOL {
                    s.kind = if_u8(sv.kind == CV_INT, SK_INT, SK_BOOL);
                    s.tm = sv.tm;
                    s.ty = sv.ty;
                    s.i = sv.as_data.i;
                } else if sv.kind == CV_FLOAT {
                    if !ce_isfinite(sv.as_data.f) {
                        return self.cap_fail(base, CE_TRAP_UNSUPPORTED, "constant contains a non-finite float");
                    }
                    s.kind = SK_FLOAT;
                    s.tm = sv.tm;
                    s.ty = sv.ty;
                    s.f = sv.as_data.f;
                } else if sv.kind == CV_NIL_K {
                    if shape == SS_STRUCT || shape == SS_CELL {
                        return self.cap_fail(
                            base,
                            CE_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                } else if sv.kind == CV_PTR {
                    if sv.as_data.p.obj == 0 {
                        s.kind = SK_NULL;
                    } else {
                        let tgt = map[sv.as_data.p.obj as usize];
                        if tgt == 0 {
                            return self.cap_fail(
                                base,
                                CE_TRAP_UNSUPPORTED,
                                "constant value cannot be materialized as static data",
                            );
                        }
                        let ti = tgt - 1;
                        let toff = sv.as_data.p.off;
                        let tshape = self.statics[ti as usize].shape;
                        let tlen = (unsafe self.obj_ptr(order[(ti - base) as usize]).slots.len()) as u32;
                        let past_end = toff == tlen && (tshape == SS_HEAP || tshape == SS_ARRAY);
                        if toff > tlen || toff == tlen && !past_end || toff != 0 && (tshape == SS_ENUM || tshape == SS_CELL) {
                            return self.cap_fail(
                                base,
                                CE_TRAP_UNSUPPORTED,
                                "constant value cannot be materialized as static data",
                            );
                        }
                        s.kind = SK_REL;
                        srels.push(
                            SRel {
                                slot: k,
                                kind: if_u8(toff == 0, SREL_STATIC, SREL_INTERIOR),
                                target: ti,
                                toff: toff,
                                fm: 0,
                                fnode: NODE_NONE,
                            },
                        );
                    }
                } else if sv.kind == CV_FN {
                    let fm2 = sv.as_data.fnv.m;
                    let fnid = sv.as_data.fnv.fn_id;
                    let mut fn_ok = self.has_ast(fm2);
                    if fn_ok {
                        let fa = self.ast_ptr(fm2);
                        fn_ok = fa.at_const(fnid).kind == NodeKind::NODE_FUNCTION;
                        if fn_ok {
                            let fd = fa.at_const(fnid).as_data.function;
                            fn_ok = fd.generics.len == 0 && (fd.body != NODE_NONE || fd.is_extern);
                        }
                    }
                    if !fn_ok {
                        return self.cap_fail(
                            base,
                            CE_TRAP_UNSUPPORTED,
                            "constant contains a function value with no C symbol",
                        );
                    }
                    s.kind = SK_REL;
                    srels.push(SRel { slot: k, kind: SREL_FN, target: 0, toff: 0, fm: fm2, fnode: fnid });
                } else if sv.kind == CV_AGG {
                    s.kind = SK_AGG;
                    s.child = map[sv.as_data.p.obj as usize] - 1;
                } else {
                    return self.cap_fail(
                        base,
                        CE_TRAP_UNSUPPORTED,
                        "constant value cannot be materialized as static data",
                    );
                }
                sslots.push(s);
            }
            self.statics[gi].slots = sslots;
            self.statics[gi].rels = srels;
        }
        return StaticRes { ok: true, root: base };
    }
}

const fn if_u8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}

extend ConstEval as Free {
    pub fn free(self: &mut Self) {
        self.vals.free();
        self.objs.free();
        self.fold_errs.free();
        self.pending.free();
        self.pending_consts.free();
        self.calls.free();
        self.ufree.free();
        self.fx.free();
        self.fxd.free();
        self.fx_no.free();
        self.statics.free();
        self.sref.free();
    }
}

const fn libm1(name: str, x: f64) DblRes {
    if name == "sqrt" {
        return DblRes { ok: true, v: unsafe math::sqrt(x) };
    }
    if name == "cbrt" {
        return DblRes { ok: true, v: unsafe math::cbrt(x) };
    }
    if name == "exp" {
        return DblRes { ok: true, v: unsafe math::exp(x) };
    }
    if name == "exp2" {
        return DblRes { ok: true, v: unsafe math::exp2(x) };
    }
    if name == "expm1" {
        return DblRes { ok: true, v: unsafe math::expm1(x) };
    }
    if name == "log" {
        return DblRes { ok: true, v: unsafe math::log(x) };
    }
    if name == "log2" {
        return DblRes { ok: true, v: unsafe math::log2(x) };
    }
    if name == "log10" {
        return DblRes { ok: true, v: unsafe math::log10(x) };
    }
    if name == "log1p" {
        return DblRes { ok: true, v: unsafe math::log1p(x) };
    }
    if name == "sin" {
        return DblRes { ok: true, v: unsafe math::sin(x) };
    }
    if name == "cos" {
        return DblRes { ok: true, v: unsafe math::cos(x) };
    }
    if name == "tan" {
        return DblRes { ok: true, v: unsafe math::tan(x) };
    }
    if name == "asin" {
        return DblRes { ok: true, v: unsafe math::asin(x) };
    }
    if name == "acos" {
        return DblRes { ok: true, v: unsafe math::acos(x) };
    }
    if name == "atan" {
        return DblRes { ok: true, v: unsafe math::atan(x) };
    }
    if name == "sinh" {
        return DblRes { ok: true, v: unsafe math::sinh(x) };
    }
    if name == "cosh" {
        return DblRes { ok: true, v: unsafe math::cosh(x) };
    }
    if name == "tanh" {
        return DblRes { ok: true, v: unsafe math::tanh(x) };
    }
    if name == "asinh" {
        return DblRes { ok: true, v: unsafe math::asinh(x) };
    }
    if name == "acosh" {
        return DblRes { ok: true, v: unsafe math::acosh(x) };
    }
    if name == "atanh" {
        return DblRes { ok: true, v: unsafe math::atanh(x) };
    }
    if name == "floor" {
        return DblRes { ok: true, v: unsafe math::floor(x) };
    }
    if name == "ceil" {
        return DblRes { ok: true, v: unsafe math::ceil(x) };
    }
    if name == "round" {
        return DblRes { ok: true, v: unsafe math::round(x) };
    }
    if name == "trunc" {
        return DblRes { ok: true, v: unsafe math::trunc(x) };
    }
    if name == "fabs" {
        return DblRes { ok: true, v: unsafe math::fabs(x) };
    }
    return DblRes { ok: false, v: 0.0 };
}

const fn libm2(name: str, x: f64, y: f64) DblRes {
    if name == "pow" {
        return DblRes { ok: true, v: unsafe math::pow(x, y) };
    }
    if name == "hypot" {
        return DblRes { ok: true, v: unsafe math::hypot(x, y) };
    }
    if name == "atan2" {
        return DblRes { ok: true, v: unsafe math::atan2(x, y) };
    }
    if name == "fmod" {
        return DblRes { ok: true, v: unsafe math::fmod(x, y) };
    }
    if name == "copysign" {
        return DblRes { ok: true, v: unsafe math::copysign(x, y) };
    }
    if name == "fmin" {
        return DblRes { ok: true, v: unsafe math::fmin(x, y) };
    }
    if name == "fmax" {
        return DblRes { ok: true, v: unsafe math::fmax(x, y) };
    }
    return DblRes { ok: false, v: 0.0 };
}

pub struct DblRes {
    pub ok: bool,
    pub v: f64,
}
