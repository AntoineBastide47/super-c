// The Core IR constant interpreter -- the ONLY compile-time evaluator: executes verified bodies
// over an abstract object store -- no host pointers, deterministic step/frame/memory budgets, and
// the established trap taxonomy (UB traps carry messages; a silent refusal stays retryable).
// Serves every type-check fold, the backend's const/static definitions, the fx `const fn`
// eligibility scan, and the always-panics probe. The arithmetic mirrors the language's pinned
// semantics: unsigned wraps at width, signed overflow, division by zero, out-of-range shifts, and
// MIN / -1 trap.
import string as cstring;
import atomic;
import sc_runtime;
import std::parallel::sync as psy;
import stdlib;
import math;
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import ir::lower as irl;
import ir::layout as lay;
import lexer::token as tok;
import lexer::token_type as *;

pub const IV_NONE: u8 = 0; // not evaluable (unsupported construct, trap, or budget)
pub const IV_INT: u8 = 1;
pub const IV_BOOL: u8 = 2;
pub const IV_FLOAT: u8 = 3;
pub const IV_UNIT: u8 = 4;
pub const IV_OBJ: u8 = 5; // aggregate: 1-based id into the object store in `i`
pub const IV_STR: u8 = 6; // string literal: source span in `i` (start << 32 | end)
pub const IV_PTR: u8 = 7; // abstract pointer: object id << 32 | slot offset in `i` (id 0 = null)
pub const IV_FN: u8 = 8; // function value: module << 32 | fn node in `i`

// Trap kinds (identical taxonomy and messages to the established evaluator).
pub const IT_TRAP_NONE: u8 = 0;
pub const IT_TRAP_BUDGET_STEPS: u8 = 1;
pub const IT_TRAP_BUDGET_MEMORY: u8 = 2;
pub const IT_TRAP_BUDGET_DEPTH: u8 = 3;
pub const IT_TRAP_CYCLE: u8 = 4;
pub const IT_TRAP_TOO_LARGE: u8 = 5;
pub const IT_TRAP_UNSUPPORTED: u8 = 6;
pub const IT_TRAP_PANIC: u8 = 7;
pub const IT_TRAP_UB_DIV_ZERO: u8 = 8;
pub const IT_TRAP_UB_OVERFLOW: u8 = 9;
pub const IT_TRAP_UB_SHIFT: u8 = 10;
pub const IT_TRAP_UB_NULL_DEREF: u8 = 11;
pub const IT_TRAP_UB_USE_AFTER_FREE: u8 = 12;
pub const IT_TRAP_UB_DOUBLE_FREE: u8 = 13;
pub const IT_TRAP_UB_OOB: u8 = 14;

pub const I64_MIN: i64 = 0x8000000000000000u64 as i64;
pub const I64_MAX: i64 = 0x7FFFFFFFFFFFFFFFu64 as i64;
pub const F64_MAX: f64 = 1.7976931348623157e308;

pub const EV_EVALUATING: u8 = 250; // ememo sentinel: fold in flight (re-entry = cycle)
pub const EV_AGG_OK: u8 = 251; // ememo: known non-scalar success

pub const fn it_trap_is_ub(k: u8) bool {
    return k >= IT_TRAP_UB_DIV_ZERO;
}

// Effect-summary verdicts (the fx scanner): NO must imply evaluation is certain to fail.
pub const FX_UNKNOWN: u8 = 0;
pub const FX_YES: u8 = 1;
pub const FX_MAYBE: u8 = 2;
pub const FX_NO: u8 = 3;
pub const FX_ONSTACK: u8 = 4;

pub const fn fx_meet(a: u8, b: u8) u8 {
    if a == FX_NO || b == FX_NO {
        return FX_NO;
    }
    if a == FX_MAYBE || b == FX_MAYBE {
        return FX_MAYBE;
    }
    return FX_YES;
}

/// The recorded disqualifying site for a shallow FX_NO verdict.
pub struct FxNo<'a> {
    pub m: ModuleId,
    pub fn_id: NodeId,
    pub site: NodeId,
    pub why: str<'a>,
}

pub const IT_MAX_FRAMES: u32 = 48;
pub const IT_MAX_OBJS: usize = 65536;
pub const IT_DEFAULT_STEPS: u32 = 2097152; // 1 << 21
pub const IT_DEFAULT_SLOTS: u64 = 4194304; // 1 << 22 IVal slots of abstract memory
const CLONE_MAX_DEPTH: i32 = 32;

pub struct IVal {
    pub kind: u8,
    pub tm: ModuleId, // the module whose type pool `ty` indexes
    pub ty: TypeId,
    pub i: i64,
    pub f: f64,
}

/// One generic-parameter binding of the ACTIVE frame: `pnode` of `pmod` stands for `(am, at)`.
pub struct ISub {
    pub pmod: ModuleId,
    pub pnode: NodeId,
    pub am: ModuleId,
    pub at: TypeId,
}

// ---- static data capture ------------------------------------------------------------------------
// Deep-clone-on-store guarantees each object is embedded by value in at most one parent; pointer
// members keep object identity, so shared and cyclic graphs survive serialization.

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

pub const S_NO_PARENT: u32 = 0xFFFFFFFF;
pub const IT_STATIC_MAX_SLOTS: u64 = 1048576; // serialized slots per constant

pub struct SRel {
    pub slot: u32,
    pub kind: u8,
    pub target: u32, // statics index (SREL_STATIC/INTERIOR)
    pub toff: u32,
    pub fm: ModuleId, // SREL_FN: the function
    pub fnode: NodeId,
}

pub struct SSlot {
    pub kind: u8,
    pub tm: ModuleId,
    pub ty: TypeId,
    pub i: i64,
    pub f: f64,
    pub child: u32, // SK_AGG: statics index of the embedded object
}

pub struct StaticObj {
    pub shape: u8,
    pub nargs: u8,
    pub uactive: i32, // union: the only member present; -1 otherwise
    pub dm: ModuleId, // struct/enum decl identity
    pub dn: NodeId,
    pub am: [ModuleId; 4],
    pub at: [TypeId; 4],
    pub etm: ModuleId, // heap/array element type; cell value type
    pub ety: TypeId,
    pub n: u32, // heap/array element count
    pub parent: u32, // embedding parent (S_NO_PARENT = standalone)
    pub pslot: u32,
    pub owner: u32, // nearest standalone ancestor (self when standalone)
    pub ord: u32, // ordinal among the group's standalones; k > 0 -> "<name>__ct{k-1}"
    pub groupn: u32, // root only: entries in this group
    pub slots: Vector<SSlot>,
    pub rels: Vector<SRel>,
}

pub struct StaticRes {
    pub ok: bool,
    pub root: u32,
}

/// A virtual object: aggregate slots plus the identity the static capture needs (decl, instance
/// args, heap-block element typing, union active member).
pub struct IObj {
    pub slots: Vector<IVal>,
    pub dead: u8,
    pub is_enum: u8,
    pub heap: u8,
    pub clos: u8, // closure environment: dm/dn name the closure node, slots hold the captures
    pub nargs: u8,
    pub uactive: i32, // union: the member written through; -1 otherwise
    pub dm: ModuleId, // struct/enum decl identity (0/NODE_NONE when shapeless)
    pub dn: NodeId,
    pub am: [ModuleId; 4],
    pub at: [TypeId; 4],
    pub bytes: u64, // heap blocks: the byte size malloc gave out
    pub em: ModuleId, // heap blocks: element type once adopted
    pub et: TypeId,
    pub esz: u64,
}

const fn hex_digit(c: u8) i64 {
    if c >= 48 && c <= 57 {
        return c - 48;
    }
    if c >= 97 && c <= 102 {
        return c - 87;
    }
    if c >= 65 && c <= 70 {
        return c - 55;
    }
    return -1;
}

const fn none() IVal {
    return IVal { kind: IV_NONE, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 };
}

const fn iv_unit() IVal {
    return IVal { kind: IV_UNIT, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 };
}

const fn iv_int(tm: ModuleId, ty: TypeId, v: i64) IVal {
    return IVal { kind: IV_INT, tm: tm, ty: ty, i: v, f: 0.0 };
}

const fn iv_bool(tm: ModuleId, ty: TypeId, v: bool) IVal {
    let mut i: i64 = 0;
    if v {
        i = 1;
    }
    return IVal { kind: IV_BOOL, tm: tm, ty: ty, i: i, f: 0.0 };
}

const fn iv_float(tm: ModuleId, ty: TypeId, v: f64) IVal {
    return IVal { kind: IV_FLOAT, tm: tm, ty: ty, i: 0, f: v };
}

const fn iv_ptr(tm: ModuleId, ty: TypeId, obj: u32, off: u32) IVal {
    return IVal { kind: IV_PTR, tm: tm, ty: ty, i: obj as i64 << 32 | off as i64, f: 0.0 };
}

pub const fn pv_obj(v: IVal) u32 {
    return (v.i >> 32) as u32;
}

pub const fn pv_off(v: IVal) u32 {
    return (v.i & 0xFFFFFFFF) as u32;
}

const fn it_isfinite(x: f64) bool {
    return unsafe math::fabs(x) <= F64_MAX;
}

struct OvfRes {
    pub ovf: bool,
    pub v: i64,
}

// non-trapping (u64-wrapping) checked signed arithmetic; ovf = the result overflows i64
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

const fn bt_signed(b: BuiltinType) bool {
    return b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
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

// Wrap `v` to builtin `b`'s width with sign-extension for signed targets.
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

const fn bt_unsigned(b: BuiltinType) bool {
    return b == BuiltinType::BT_U8 || b == BuiltinType::BT_U16 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_USIZE || b == BuiltinType::BT_CHAR;
}

struct DblRes {
    pub ok: bool,
    pub v: f64,
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

/// A recorded failed fold (deduped per node); the driver renders these after emission.
pub struct IFoldErr {
    pub m: ModuleId,
    pub id: NodeId,
    pub kind: u8,
    pub constfn: bool, // the failure happened at or below a `const fn` frame
    pub detail: String,
}

struct UFree {
    pub m: ModuleId,
    pub n: NodeId,
    pub user: bool,
}

pub struct Interp {
    pub pkg: *const loader::Package,
    pub steps: u32,
    pub max_steps: u32,
    pub max_slots: u64,
    pub objs: Vector<IObj>,
    pub objs_live: usize,
    pub live_slots: u64,
    pub failed: bool,
    pub trap: str<'static>,
    pub trap_kind: u8,
    pub trap_steps: u32,
    pub nframes: u32,
    pub fstack: [DefId; 48],
    pub trap_nframes: u8,
    pub trap_stack: [DefId; 48],
    pub lsvc: lay::Svc,
    pub bodies: Vector<Box<irl::Lowerer>>, // lowered callee cache (boxed: nested calls grow it)
    pub body_keys: Vector<u64>, // module << 32 | fn node
    pub body_ix: Map<u64, u64>, // bkey -> bodies slot (the linear key scan was O(n^2) over a sweep)
    pub cont_memo: Map<u64, u64>, // (m << 32 | fn) -> kind << 32 | container: called per interpreted call
    pub call_memo: Map<u64, IVal>, // scalar results keyed over every semantic input (callee + args)
    pub item_memo: Map<u64, IVal>, // referenced-const values (scalar only), keyed module << 32 | node
    pub item_active: Vector<u64>, // consts being evaluated right now: a re-entry is a cycle
    pub rets: Vector<IVal>, // the last finished frame's return slots (multi-return call writes)
    pub ufree: Vector<UFree>, // decl -> has a user free method (folding such values is refused)
    pub subst: Vector<ISub>, // generic bindings, all frames; [sub_base, len) is the active window
    pub sub_base: usize,
    pub ext_memo: Map<u64, u32>, // fn node -> enclosing extend node (NODE_NONE = none)
    pub statics: Vector<StaticObj>, // captured static data groups, appended per constant
    pub all_typed: bool, // silent const-fn failures promote to definite traps only once true
    pub record_folds: bool, // failed folds with promotable traps record into fold_errs
    pub record_pause: u32, // >0 suppresses recording (short-circuit RHS probes)
    pub trap_in_constfn: bool,
    // Engine serialization for parallel stages: off = single-threaded. Task-aware (waiters PARK --
    // a raw mutex here deadlocks under safepoint preemption) and reentrant by task token -- the
    // interpreter re-enters its own facade while lowering callee bodies.
    pub elock_on: bool,
    // Parallel frontend: the module whose check requested the CURRENT top-level evaluation (the
    // index-aware gate emulates serial module-order visibility), and the module a gated lowering
    // asked to WAIT for (-1 = none; the facade releases the engine, waits, and re-runs).
    pub tc_par: bool,
    pub root_mod: ModuleId,
    pub retry_mod: i64,
    pub elock_sem: psy::Semaphore,
    pub elock_owner: usize,
    pub elock_depth: u32,
    pub lint_on: bool, // lint_body tracking: record the executing top-frame statement span
    pub top_span: tok::Span,
    pub trap_span: tok::Span, // top-frame span snapshotted at first trap
    pub in_run: u32, // frames currently executing (re-entrant lowering must not re-fold)
    pub ev_depth: u32, // facade eval nesting
    pub fold_errs: Vector<IFoldErr>,
    pub ememo: Map<u64, IVal>, // expression fold memo keyed module << 32 | node
    pub dbuf: String, // trap_detail's rendering buffer (the returned str views it)
    pub sref: Map<u64, i64>, // eval_static memo: -1 definite failure, >0 root+1 (retryable absent)
    pub fx: Vector<Vector<u8>>, // shallow effect verdicts per (module, fn node)
    pub fxd: Vector<Vector<u8>>, // deep (all-paths) effect verdicts
    pub fx_no: Vector<FxNo<'static>>, // first disqualifying site per shallow FX_NO
    pub fx_depth: u32,
    pub pending: Vector<u64>, // deferred static_assert conditions (module << 32 | node)
    pub pending_consts: Vector<u64>, // deferred call-bearing const decls
}

extend Interp as Free {
    pub fn free(self: &mut Self) {
        self.objs.free();
        self.bodies.free();
        self.body_keys.free();
        self.body_ix.free();
        self.cont_memo.free();
        self.call_memo.free();
        self.item_memo.free();
        self.item_active.free();
        self.rets.free();
        self.ufree.free();
        self.subst.free();
        self.ext_memo.free();
        self.statics.free();
        self.fold_errs.free();
        self.ememo.free();
        self.dbuf.free();
        self.sref.free();
        self.elock_sem.free();
        self.fx.free();
        self.fxd.free();
        self.fx_no.free();
        self.pending.free();
        self.pending_consts.free();
        self.lsvc.free();
    }
}

pub fn interp_new(pkg: *const loader::Package) Interp {
    return Interp {
        pkg: pkg,
        steps: 0,
        max_steps: IT_DEFAULT_STEPS,
        max_slots: IT_DEFAULT_SLOTS,
        objs: Vector::<IObj>::new(),
        objs_live: 0,
        live_slots: 0,
        failed: false,
        trap: "",
        trap_kind: IT_TRAP_NONE,
        trap_steps: 0,
        nframes: 0,
        trap_nframes: 0,
        lsvc: lay::Svc::new(pkg),
        bodies: Vector::<Box<irl::Lowerer>>::new(),
        body_keys: Vector::<u64>::new(),
        body_ix: Map::<u64, u64>::new(),
        cont_memo: Map::<u64, u64>::new(),
        call_memo: Map::<u64, IVal>::new(),
        item_memo: Map::<u64, IVal>::new(),
        item_active: Vector::<u64>::new(),
        rets: Vector::<IVal>::new(),
        ufree: Vector::<UFree>::new(),
        subst: Vector::<ISub>::new(),
        sub_base: 0,
        ext_memo: Map::<u64, u32>::new(),
        statics: Vector::<StaticObj>::new(),
        all_typed: false,
        record_folds: false,
        record_pause: 0,
        trap_in_constfn: false,
        elock_on: false,
        tc_par: false,
        root_mod: 0,
        retry_mod: 0 - 1,
        elock_sem: psy::Semaphore::new(1),
        elock_owner: 0,
        elock_depth: 0,
        lint_on: false,
        top_span: tok::Span { start: 0, end: 0 },
        trap_span: tok::Span { start: 0, end: 0 },
        in_run: 0,
        ev_depth: 0,
        fold_errs: Vector::<IFoldErr>::new(),
        ememo: Map::<u64, IVal>::new(),
        dbuf: String::new(),
        sref: Map::<u64, i64>::new(),
        fx: Vector::<Vector<u8>>::new(),
        fxd: Vector::<Vector<u8>>::new(),
        fx_no: Vector::<FxNo>::new(),
        fx_depth: 0,
        pending: Vector::<u64>::new(),
        pending_consts: Vector::<u64>::new(),
    };
}

const fn ti_round_up(v: u64, a: u64) u64 {
    if a == 0 {
        return v;
    }
    let r = v % a;
    if r == 0 {
        return v;
    }
    return v + (a - r);
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

// "_<k>" into `buf` (32 bytes): the field names a tuple's members answer to.
fn ti_tuple_name<'a>(buf: *mut u8, k: u32) str<'a> {
    unsafe buf[0] = 95;
    let mut n: usize = 1;
    let mut digits: [u8; 16] = [0; 16];
    let mut v = k;
    let mut nd: usize = 0;
    do {
        unsafe digits[nd] = 48 + (v % 10) as u8;
        nd += 1;
        v = v / 10;
    } while v != 0;
    while nd > 0 {
        nd -= 1;
        unsafe buf[n] = unsafe digits[nd];
        n += 1;
    }
    return str::from_raw(buf, n);
}

extend Interp {
    /// Evaluate `cnode` through a REUSED interpreter: the per-evaluation state resets while the
    /// lowered-callee cache and the call memo (scalar-only, so no object id can dangle across the
    /// object-store reset) persist -- one interpreter serves a whole emission pass.
    pub fn eval_const_in(self: &mut Self, m: ModuleId, cnode: NodeId, max_steps: u32) IVal {
        self.steps = 0;
        self.max_steps = max_steps;
        self.failed = false;
        self.trap = "";
        self.trap_kind = IT_TRAP_NONE;
        self.trap_nframes = 0;
        self.nframes = 0;
        self.objs_live = 0;
        self.live_slots = 0;
        self.item_active.truncate(0);
        self.subst.truncate(0);
        self.sub_base = 0;
        let mut lw = irl::Lowerer::new(self.pkg, m, cnode);
        if !lw.lower_const(cnode) {
            self.failed = true;
            return none();
        }
        let args = Vector::<IVal>::new();
        let r = self.run(&lw.body, &args);
        return r;
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    const fn src_of(self: &Self, m: ModuleId) str {
        return self.p().modules.at(m as usize).source.as_str();
    }

    const fn span_is(self: &Self, m: ModuleId, s: tok::Span, lit: str) bool {
        let n = lit.len();
        if (s.end - s.start) as usize != n {
            return false;
        }
        return unsafe cstring::memcmp(self.src_of(m).ptr() + s.start as usize, lit.ptr(), n) == 0;
    }

    @c.cold
    fn it_trap(self: &mut Self, kind: u8, msg: str<'static>) {
        if self.trap.len() == 0 {
            self.trap = msg;
            self.trap_kind = kind;
            self.trap_steps = self.steps;
            let mut n = self.nframes;
            if n > IT_MAX_FRAMES {
                n = IT_MAX_FRAMES;
            }
            self.trap_nframes = n as u8;
            self.trap_span = self.top_span;
            for i in 0..n {
                unsafe self.trap_stack[i as usize] = unsafe self.fstack[i as usize];
            }
        }
        self.failed = true;
    }

    const fn bail(self: &mut Self) IVal {
        self.failed = true;
        return none();
    }

    fn tick(self: &mut Self) bool {
        self.steps += 1;
        if self.steps > self.max_steps {
            self.it_trap(IT_TRAP_BUDGET_STEPS, "const-eval step budget exceeded");
            return false;
        }
        return true;
    }

    // ---- object store -----------------------------------------------------------------------------

    // Object ids are 1-based; 0 is the abstract null pointer, and ids past objs_live are stale.
    const fn obj_ptr(self: &Self, id: u32) *mut IObj {
        if id == 0 || id as usize > self.objs_live {
            return null;
        }
        return unsafe (self.objs.as_ptr() as *mut IObj + (id - 1) as usize);
    }

    fn obj_new(self: &mut Self, len: u32) u32 {
        if self.objs_live >= IT_MAX_OBJS || self.live_slots + len as u64 > self.max_slots {
            self.it_trap(IT_TRAP_BUDGET_MEMORY, "const-eval memory budget exceeded");
            return 0;
        }
        if self.objs_live < self.objs.len() {
            // reuse a retained object: refit its slot vector, zero the metadata push{} would zero
            let o = unsafe (self.objs.as_ptr() as *mut IObj + self.objs_live);
            unsafe o.slots.clear();
            if len != 0 {
                unsafe o.slots.reserve(len as usize);
                for _ in 0..len {
                    unsafe o.slots.push(none());
                }
            }
            unsafe o.dead = 0;
            unsafe o.is_enum = 0;
            unsafe o.heap = 0;
            unsafe o.clos = 0;
            unsafe o.nargs = 0;
            unsafe o.uactive = -1;
            unsafe o.dm = 0;
            unsafe o.dn = NODE_NONE;
            unsafe o.bytes = 0;
            unsafe o.em = 0;
            unsafe o.et = TYPE_NONE;
            unsafe o.esz = 0;
        } else {
            let mut slots = Vector::<IVal>::new();
            if len != 0 {
                slots.reserve(len as usize);
                for _ in 0..len {
                    slots.push(none());
                }
            }
            self.objs.push(IObj { slots: slots, uactive: -1, dn: NODE_NONE });
        }
        self.objs_live += 1;
        self.live_slots += len;
        return self.objs_live as u32;
    }

    fn obj_resize(self: &mut Self, id: u32, len: u32) bool {
        let cur = (unsafe self.obj_ptr(id).slots.len()) as u32;
        if len > cur && self.live_slots + (len - cur) as u64 > self.max_slots {
            self.it_trap(IT_TRAP_BUDGET_MEMORY, "const-eval memory budget exceeded");
            return false;
        }
        let o = self.obj_ptr(id);
        if len > cur {
            let mut i = cur;
            while i < len {
                unsafe o.slots.push(none());
                i += 1;
            }
            self.live_slots += len - cur;
        } else if len < cur {
            unsafe o.slots.truncate(len as usize);
        }
        return true;
    }

    // Deep copy: aggregates get fresh objects (pointer members stay shared); scalars copy by value.
    fn obj_clone(self: &mut Self, v: IVal, depth: i32) IVal {
        if v.kind != IV_OBJ || depth > CLONE_MAX_DEPTH {
            if v.kind == IV_OBJ && depth > CLONE_MAX_DEPTH {
                return none();
            }
            return v;
        }
        let sid = v.i as u32;
        let srcp = self.obj_ptr(sid);
        if srcp == null || unsafe srcp.dead != 0 {
            return none();
        }
        let srclen = (unsafe srcp.slots.len()) as u32;
        let id = self.obj_new(srclen);
        if id == 0 {
            return none();
        }
        let src = self.obj_ptr(sid);
        let dst = self.obj_ptr(id);
        unsafe {
            dst.dead = src.dead;
            dst.is_enum = src.is_enum;
            dst.clos = src.clos;
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
            let sv = unsafe self.obj_ptr(sid).slots[i as usize];
            let cloned = self.obj_clone(sv, depth + 1);
            if sv.kind != IV_NONE && cloned.kind == IV_NONE {
                return none();
            }
            unsafe self.obj_ptr(id).slots.set(i as usize, cloned);
        }
        let mut out = v;
        out.i = id;
        return out;
    }

    // Read through an abstract pointer with the null/dead/bounds trap ladder.
    fn loadp(self: &mut Self, pv: IVal, out: &mut IVal) bool {
        if pv.kind != IV_PTR {
            return false;
        }
        let id = pv_obj(pv);
        if id == 0 {
            // offset 0 is the true null; a nonzero offset is a storage-free SENTINEL (see
            // cast_pointer): its access is elided by the backend, so it fails benignly here
            if pv_off(pv) != 0 {
                self.failed = true;
                return false;
            }
            self.it_trap(IT_TRAP_UB_NULL_DEREF, "null dereference");
            return false;
        }
        let o = self.obj_ptr(id);
        if o == null {
            return false;
        }
        if unsafe o.dead != 0 {
            self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
            return false;
        }
        if pv_off(pv) as usize >= unsafe o.slots.len() {
            self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
            return false;
        }
        *out = unsafe o.slots[pv_off(pv) as usize];
        return out.kind != IV_NONE;
    }

    // The user-free screen: a value of a type with a user-written `free` method never folds (its
    // destructor is runtime behavior the evaluator cannot honor).
    fn user_free(self: &mut Self, dm: ModuleId, dn: NodeId) bool {
        for i in 0..self.ufree.len() {
            let u = self.ufree.at(i);
            if u.m == dm && u.n == dn {
                return u.user;
            }
        }
        let mut user = false;
        let nm = self.p().modules.len();
        let mut mm: usize = 0;
        while mm < nm && !user {
            let md = self.p().modules.at(mm);
            if !md.prelude && md.ast.nodes.len() != 0 {
                let a = unsafe &*self.p().module_ast_const(mm as ModuleId);
                let items = a.at_const(a.root).as_data.program.items;
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
                                    let mname = a.at_const(a.at_const(mid).as_data.function.name).as_data.name.text;
                                    if self.span_is(mm as ModuleId, mname, "free") {
                                        user = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    ii += 1;
                }
            }
            mm += 1;
        }
        self.ufree.push(UFree { m: dm, n: dn, user: user });
        return user;
    }

    // Resolve `(m, t)` through the ACTIVE frame's substitution window while it names a generic
    // parameter (one hop per binding, 8 hops max).
    const fn rty(self: &Self, m0: ModuleId, t0: TypeId, om: &mut ModuleId, ot: &mut TypeId) bool {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..8 {
            if t == TYPE_NONE {
                return false;
            }
            // builtin ids are positional (b + 1) by the seeding contract, so they resolve even
            // in a module whose pool was never seeded (an unchecked module's const initializer)
            if t >= 1 && t <= BuiltinType::BT_COUNT as u32 {
                *om = m;
                *ot = t;
                return true;
            }
            let a = unsafe &*self.p().module_ast_const(m);
            if t as usize >= a.type_pool.len() {
                return false; // a foreign-pool id: unanswerable in this pool
            }
            let y = *a.type_at(t);
            if y.kind != TypeKind::TYPE_GENERIC {
                *om = m;
                *ot = t;
                return true;
            }
            let mut found = false;
            let mut i = self.sub_base;
            while i < self.subst.len() {
                let sb = self.subst.at(i);
                if sb.pmod == y.module && sb.pnode == y.as_data.decl {
                    m = sb.am;
                    t = sb.at;
                    found = true;
                    break;
                }
                i += 1;
            }
            if !found {
                return false;
            }
        }
        return false;
    }

    // The builtin behind `(m, t)` (refusal encoded as bool).
    const fn bt_of(self: &Self, m: ModuleId, t: TypeId, out: &mut BuiltinType) bool {
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        if !self.rty(m, t, &mut rm, &mut rt) {
            return false;
        }
        if rt >= 1 && rt <= BuiltinType::BT_COUNT as u32 {
            *out = ((rt - 1) as u8) as BuiltinType;
            return true;
        }
        let a = unsafe &*self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        *out = y.as_data.builtin;
        return true;
    }

    /// Whether `t` mentions a '@no_const' declaration anywhere (through pointers, references,
    /// slices, arrays and instance arguments); such a value can never exist at compile time.
    fn ty_no_const(self: &Self, m: ModuleId, t: TypeId, depth: u32) bool {
        if t == TYPE_NONE || depth > 16 {
            return false;
        }
        let a = unsafe &*self.p().module_ast_const(m);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.ty_no_const(m, y.as_data.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.has_attr(y.module, y.as_data.decl, AttrKind::ATTR_NO_CONST);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            if self.has_attr(it.module, it.decl, AttrKind::ATTR_NO_CONST) {
                return true;
            }
            for i in 0..it.n {
                if self.ty_no_const(m, unsafe it.args[i as usize], depth + 1) {
                    return true;
                }
            }
        }
        return false;
    }

    const fn has_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) bool {
        let a = unsafe &*self.p().module_ast_const(m);
        for i in 0..a.attrs.len() {
            let at2 = a.attrs.at(i);
            if at2.owner == owner && at2.kind == kind as u8 {
                return true;
            }
        }
        return false;
    }

    // The NODE_EXTEND enclosing `fnode` in module `m` (NODE_NONE when top-level), memoized.
    fn extend_of(self: &mut Self, m: ModuleId, fnode: NodeId) NodeId {
        let key = m as u64 << 32 | fnode as u64;
        switch self.ext_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            None => {},
        };
        let a = unsafe &*self.p().module_ast_const(m);
        let mut found = NODE_NONE;
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let ms = a.at_const(iid).as_data.extend_def.items;
            for k in 0..ms.len {
                if unsafe a.list(ms)[k as usize] == fnode {
                    found = iid;
                }
            }
        }
        self.ext_memo.insert(key, found);
        return found;
    }

    // Add one binding to `list` (dedup checks the SAME substitution; mixed param modules refuse,
    // matching the established evaluator's single-pmod frame).
    fn subst_add(self: &mut Self, list: &mut Vector<ISub>, pmod: ModuleId, pnode: NodeId, am: ModuleId, at: TypeId) bool {
        for i in 0..list.len() {
            let sb = *list.at(i);
            if sb.pmod == pmod && sb.pnode == pnode {
                return self.teq(sb.am, sb.at, am, at);
            }
        }
        if list.len() >= 8 || list.len() != 0 && list.at(0).pmod != pmod {
            return false;
        }
        list.push(ISub { pmod: pmod, pnode: pnode, am: am, at: at });
        return true;
    }

    // The receiver decl behind Self's static type at a call site (refs/pointers peeled).
    fn recv_of(
        self: &Self,
        m0: ModuleId,
        t0: TypeId,
        dm: &mut ModuleId,
        dn: &mut NodeId,
        n: &mut u8,
        am: *mut ModuleId,
        at: *mut TypeId,
    ) bool {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..3 {
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            if !self.rty(m, t, &mut rm, &mut rt) {
                return false;
            }
            m = rm;
            t = rt;
            let y = *(unsafe &*self.p().module_ast_const(m)).type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
                break;
            }
            t = y.as_data.elem;
        }
        let y = *(unsafe &*self.p().module_ast_const(m)).type_at(t);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            *dm = y.module;
            *dn = y.as_data.decl;
            *n = 0;
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *(unsafe &*self.p().module_ast_const(m)).instance(y.as_data.inst);
            *dm = it.module;
            *dn = it.decl;
            let mut na = it.n;
            if na > 4 {
                na = 4;
            }
            *n = na;
            for i in 0..na {
                // each argument resolves through the ACTIVE window: a generic frame's receiver
                // spells its instance with the frame's own parameters
                let mut gm: ModuleId = 0;
                let mut gt = TYPE_NONE;
                if !self.rty(m, unsafe it.args[i as usize], &mut gm, &mut gt) {
                    return false;
                }
                unsafe am[i as usize] = gm;
                unsafe at[i as usize] = gt;
            }
            return true;
        }
        return false;
    }

    // Match the extend head's target-type arguments against the receiver instance, binding the
    // extend's generic parameters; every parameter must end up bound.
    fn bind_extend(
        self: &mut Self,
        list: &mut Vector<ISub>,
        xm: ModuleId,
        extnode: NodeId,
        rn: u8,
        ram: *const ModuleId,
        rat: *const TypeId,
    ) bool {
        let xa = unsafe &*self.p().module_ast_const(xm);
        let gens = xa.at_const(extnode).as_data.extend_def.generics;
        if gens.len == 0 {
            return true;
        }
        let target = xa.at_const(extnode).as_data.extend_def.target_type;
        if xa.at_const(target).kind != NodeKind::NODE_TYPE_PATH || xa.at_const(target).as_data.type_path.args.len != rn as u32 {
            return false;
        }
        let targs = xa.at_const(target).as_data.type_path.args;
        for i in 0..rn {
            let aid = unsafe xa.list(targs)[i as usize];
            let ad = xa.resolution_def(aid);
            let ram_i = unsafe ram[i as usize];
            let rat_i = unsafe rat[i as usize];
            if ad.node != NODE_NONE && (unsafe &*self.p().module_ast_const(ad.module)).at_const(ad.node).kind == NodeKind::NODE_GENERIC_PARAM {
                if !self.subst_add(list, ad.module, ad.node, ram_i, rat_i) {
                    return false;
                }
            } else {
                let at2 = self.tof(xm, xa, aid);
                if at2 == TYPE_NONE {
                    return false;
                }
                let y2 = *xa.type_at(at2);
                if y2.kind == TypeKind::TYPE_GENERIC {
                    if !self.subst_add(list, y2.module, y2.as_data.decl, ram_i, rat_i) {
                        return false;
                    }
                } else if !self.teq(xm, at2, ram_i, rat_i) {
                    return false;
                }
            }
        }
        let gids = xa.list(gens);
        for j in 0..gens.len {
            let mut bound = false;
            for k in 0..list.len() {
                if list.at(k).pmod == xm && list.at(k).pnode == unsafe gids[j as usize] {
                    bound = true;
                }
            }
            if !bound {
                return false;
            }
        }
        return true;
    }

    // The zero value of `(m, t)`: builtins, pointers/references/functions (null), arrays and
    // plain structs/instances field-by-field through the instance substitution.
    fn zero_of(self: &mut Self, m: ModuleId, t: TypeId, depth: i32) IVal {
        if depth > CLONE_MAX_DEPTH || t == TYPE_NONE {
            return none();
        }
        let a = unsafe &*self.p().module_ast_const(m);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL {
                return iv_bool(m, t, false);
            }
            if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 {
                return iv_float(m, t, 0.0);
            }
            if b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64 || b == BuiltinType::BT_VALIST || b == BuiltinType::BT_VOID {
                return none();
            }
            return iv_int(m, t, 0);
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_FUNCTION {
            return iv_ptr(m, t, 0, 0);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len == 0 {
                return none();
            }
            let id = self.obj_new(y.as_data.arr.len);
            if id == 0 {
                return none();
            }
            let ez = self.zero_of(m, y.as_data.arr.elem, depth + 1);
            if ez.kind == IV_NONE {
                return none();
            }
            let alen = (unsafe self.obj_ptr(id).slots.len()) as u32;
            for i in 0..alen {
                let cloned = self.obj_clone(ez, depth + 1);
                unsafe self.obj_ptr(id).slots.set(i as usize, cloned);
            }
            return IVal { kind: IV_OBJ, tm: m, ty: t, i: id, f: 0.0 };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE {
            let mut dm = y.module;
            let mut dn = y.as_data.decl;
            let mut inst = TyInstance {};
            let mut has_inst = false;
            if y.kind == TypeKind::TYPE_INSTANCE {
                inst = *a.instance(y.as_data.inst);
                dm = inst.module;
                dn = inst.decl;
                has_inst = true;
            }
            let da = unsafe &*self.p().module_ast_const(dm);
            if da.at_const(dn).kind != NodeKind::NODE_STRUCT || da.at_const(dn).as_data.aggregate.is_union {
                return none();
            }
            if self.user_free(dm, dn) {
                return none();
            }
            let nf = self.field_count(dm, dn);
            let id = self.obj_new(nf);
            if id == 0 {
                return none();
            }
            unsafe self.obj_ptr(id).dm = dm;
            unsafe self.obj_ptr(id).dn = dn;
            if has_inst {
                let mut na = inst.n;
                if na > 4 {
                    na = 4;
                }
                unsafe self.obj_ptr(id).nargs = na;
                for gi in 0..na {
                    let mut gm2: ModuleId = m;
                    let mut gt2 = unsafe inst.args[gi as usize];
                    let _ = self.rty(m, unsafe inst.args[gi as usize], &mut gm2, &mut gt2);
                    unsafe self.obj_ptr(id).am[gi as usize] = gm2;
                    unsafe self.obj_ptr(id).at[gi as usize] = gt2;
                }
            }
            let mut zam: [ModuleId; 4] = [0, 0, 0, 0];
            let mut zat: [TypeId; 4] = [TYPE_NONE, TYPE_NONE, TYPE_NONE, TYPE_NONE];
            let mut zn: u8 = 0;
            if has_inst {
                zn = inst.n;
                if zn > 4 {
                    zn = 4;
                }
                for gi in 0..zn {
                    unsafe zam[gi as usize] = m;
                    unsafe zat[gi as usize] = unsafe inst.args[gi as usize];
                }
            }
            let mut si: usize = 0;
            for i in 0..nf {
                let fv = self.zero_field(dm, dn, zn, &zam[0], &zat[0], i);
                self.failed = false;
                if fv.kind == IV_NONE {
                    return none();
                }
                unsafe self.obj_ptr(id).slots.set(si, fv);
                si += 1;
            }
            return IVal { kind: IV_OBJ, tm: m, ty: t, i: id, f: 0.0 };
        }
        return none();
    }

    // ---- frames -----------------------------------------------------------------------------------

    /// Execute one body with `args` bound to its argument locals; the first return slot's value
    /// comes back (IV_UNIT for none) and every return slot lands in `self.rets` for multi-return
    /// call sites (read it before the next frame runs).
    pub fn run(self: &mut Self, b: &ir::CoreBody, args: &Vector<IVal>) IVal {
        let env = self.obj_new(b.locals.len() as u32);
        if env == 0 {
            return none();
        }
        self.in_run += 1;
        for i in 0..args.len() {
            let li = b.returns as usize + i;
            if li < b.locals.len() {
                // a reference-typed parameter binds the caller's value WITHOUT a copy: an
                // aggregate handle is the reference, so cloning would sever the aliasing
                let lty = b.locals.at(li).ty;
                let mut rm2: ModuleId = 0;
                let mut rt2 = TYPE_NONE;
                let mut ref_like = false;
                if lty != TYPE_NONE && self.rty(b.module, lty, &mut rm2, &mut rt2) {
                    let yk = (unsafe &*self.p().module_ast_const(rm2)).type_at(rt2).kind;
                    ref_like = yk == TypeKind::TYPE_REFERENCE || yk == TypeKind::TYPE_POINTER;
                }
                let mut av = if ref_like {
                    *args.at(i);
                } else {
                    self.obj_clone(*args.at(i), 0);
                };
                av = self.maybe_slice_wrap(b.module, lty, av);
                unsafe self.obj_ptr(env).slots.set(li, av);
            }
        }
        let mut blk = b.entry;
        let mut r = none();
        loop {
            if blk as usize >= b.blocks.len() {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: block out of range blk={} nblocks={}\n", blk, b.blocks.len());
                }
                let _ = self.bail();
                break;
            }
            let bb = *b.blocks.at(blk as usize);
            let mut si: u32 = 0;
            while si < bb.stmt_len && !self.failed {
                let s = *b.statements.at((bb.stmt_start + si) as usize);
                if self.lint_on && self.in_run == 1 {
                    self.top_span = s.span;
                }
                if s.kind == ir::ST_ASSIGN {
                    if !self.tick() {
                        break;
                    }
                    let v = self.rvalue(b, env, s.rvalue);
                    if self.failed {
                        if stdlib::getenv("SC_IRI_DBG") != null {
                            let rv9 = *b.rvalues.at(s.rvalue as usize);
                            let mut ok9: u32 = 999;
                            let mut ck9: u32 = 999;
                            if rv9.kind == ir::RV_USE {
                                let op9 = *b.operands.at(rv9.a as usize);
                                ok9 = op9.kind;
                                if op9.kind == ir::OP_CONST {
                                    ck9 = b.constants.at(op9.data as usize).kind;
                                } else {
                                    let pl9 = *b.places.at(op9.data as usize);
                                    let ld9 = *b.locals.at(pl9.base as usize);
                                    eprint(
                                        "iri:   place base={} storage={} proj={} item={}:{}\n",
                                        pl9.base,
                                        ld9.storage,
                                        pl9.proj_len,
                                        ld9.item.module,
                                        ld9.item.node,
                                    );
                                }
                            }
                            eprint(
                                "iri: rvalue failed own={}:{} blk={} si={} rvkind={} b={} c={} opk={} ck={}\n",
                                b.owner.module,
                                b.owner.node,
                                blk,
                                si,
                                rv9.kind,
                                rv9.b,
                                rv9.c,
                                ok9,
                                ck9,
                            );
                        }
                        break;
                    }
                    self.write_place(b, env, s.place, v);
                }
                // storage markers and discriminant writes ride the assign/aggregate model
                si += 1;
            }
            if self.failed {
                break;
            }
            if !self.tick() {
                break;
            }
            let t = bb.term;
            if self.lint_on && self.in_run == 1 {
                self.top_span = t.span;
            }
            let mut broke = false;
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_DROP {
                blk = t.t0;
            } else if t.kind == ir::TM_SWITCH {
                let d = self.operand(b, env, t.a);
                if d.kind != IV_INT && d.kind != IV_BOOL {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: switch operand kind={} blk={}\n", d.kind, blk);
                    }
                    let _ = self.bail();
                    break;
                }
                let mut target = t.t0;
                for k in 0..t.sw_len {
                    let pair = b.switch_pool[(t.sw_start + k) as usize];
                    if (pair >> 32) as i64 == (d.i & 0xFFFFFFFF) {
                        target = (pair & 0xFFFFFFFFu64) as u32;
                    }
                }
                blk = target;
            } else if t.kind == ir::TM_ASSERT {
                let c = self.operand(b, env, t.a);
                if c.kind != IV_BOOL || c.i == 0 {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: assert failed kind={} blk={}\n", c.kind, blk);
                    }
                    let _ = self.bail();
                    break;
                }
                blk = t.t0;
            } else if t.kind == ir::TM_RETURN {
                self.rets.truncate(0);
                if b.returns != 0 {
                    for ri in 0..b.returns {
                        self.rets.push(unsafe self.obj_ptr(env).slots[ri as usize]);
                    }
                    r = *self.rets.at(0);
                } else {
                    r = iv_unit();
                }
                broke = true;
            } else if t.kind == ir::TM_CALL {
                if !self.call(b, env, &t) {
                    break;
                }
                blk = t.t0;
            } else {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: terminator refused kind={} blk={}\n", t.kind, blk);
                }
                let _ = self.bail();
                break;
            }
            if broke {
                break;
            }
        }
        self.in_run -= 1;
        if self.failed {
            return none();
        }
        return r;
    }

    // The lowered body of `(m, fnode)` under `binds` (a generic instance lowers env-aware, so
    // reflection binders and sizeof folds expand for real), cached for the interpreter's lifetime;
    // -1 = does not lower.
    fn body_of(self: &mut Self, m: ModuleId, fnode: NodeId, binds: &Vector<ISub>, closure: bool) i64 {
        let mut bkey: u64 = 1469598103934665603u64;
        bkey = (bkey ^ m as u64) * 1099511628211u64;
        bkey = (bkey ^ fnode as u64) * 1099511628211u64;
        for i in 0..binds.len() {
            let sb = binds.at(i);
            bkey = (bkey ^ sb.pmod as u64) * 1099511628211u64;
            bkey = (bkey ^ sb.pnode as u64) * 1099511628211u64;
            bkey = (bkey ^ sb.am as u64) * 1099511628211u64;
            bkey = (bkey ^ sb.at as u64) * 1099511628211u64;
        }
        switch self.body_ix.get(&bkey) {
            Some(v) => {
                return (*v) as i64;
            },
            None => {},
        };
        {
            // an UNCHECKED body must not run: lowering would degrade its widths to i64 and
            // compute wrong values (the AST evaluator's per-node gate refused these silently).
            // The checker records each COMPLETED top-level item; a function's item is itself or
            // its enclosing extend/interface. Closures live inside some checked body's item; the
            // engine only ever reaches one through a value its checked context built.
            if !closure {
                let mut cont = NODE_NONE;
                let ck9 = self.container_of(m, fnode, &mut cont);
                let item9 = if ck9 == 0 {
                    fnode;
                } else {
                    cont;
                };
                let mut done9 = false;
                if self.tc_par && m != self.root_mod {
                    // serial module-order visibility: a LOWER-indexed module is fully checked by
                    // the time this one runs -- wait for it if its task has not finished; a
                    // HIGHER-indexed one is unchecked regardless of live parallel progress
                    if m < self.root_mod {
                        if m as usize < self.p().tc_mod_done.len() && *self.p().tc_mod_done.at(m as usize) != 0 {
                            done9 = true;
                        } else {
                            self.retry_mod = m;
                            return -1;
                        }
                    }
                } else if m as usize < self.p().tc_done.len() {
                    done9 = self.p().tc_done.at(m as usize).contains(&(m as u64 << 32 | item9 as u64));
                }
                if !done9 {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tc_done gate m={} fn={} item={} ck={}\n", m, fnode, item9, ck9);
                    }
                    return -1;
                }
            }
        }
        let mut lw = irl::Lowerer::new(self.pkg, m, fnode);
        for i in 0..binds.len() {
            let sb = *binds.at(i);
            lw.env.push(irl::LSub { pm: sb.pmod, pnode: sb.pnode, am: sb.am, at: sb.at });
        }
        let ok = if closure {
            lw.lower_closure_body(fnode);
        } else {
            lw.lower_fn(fnode);
        };
        if !ok {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: lower err=`{}` m={} n={}\n", lw.err, m, fnode);
            }
            return -1;
        }
        self.bodies.push(Box::new(lw));
        self.body_keys.push(bkey);
        self.body_ix.insert(bkey, self.body_keys.len() as u64 - 1);
        return self.body_keys.len() as i64 - 1;
    }

    fn call(self: &mut Self, b: &ir::CoreBody, env: u32, t: &ir::Terminator) bool {
        let mut fm = t.callee.module;
        let mut fnode = t.callee.node;
        if t.is_variadic {
            let _ = self.bail();
            return false;
        }
        let mut args = Vector::<IVal>::new();
        for i in 0..t.args_len {
            let opid = b.oper_pool[(t.args_start + i) as usize];
            let v = self.operand(b, env, opid);
            if self.failed {
                return false;
            }
            args.push(v);
        }
        let mut closure = false;
        if fnode == NODE_NONE {
            // indirect call: a function value or a closure environment
            let fv = self.operand(b, env, t.a);
            if self.failed {
                return false;
            }
            if fv.kind == IV_FN {
                fm = (fv.i >> 32) as ModuleId;
                fnode = (fv.i & 0xFFFFFFFF) as NodeId;
            } else if fv.kind == IV_OBJ {
                let op = self.obj_ptr(fv.i as u32);
                if op == null || unsafe op.clos == 0 {
                    let _ = self.bail();
                    return false;
                }
                fm = unsafe op.dm;
                fnode = unsafe op.dn;
                closure = true;
                let ncap = unsafe op.slots.len();
                for ci in 0..ncap {
                    args.push(unsafe self.obj_ptr(fv.i as u32).slots[ci]);
                }
            } else {
                let _ = self.bail();
                return false;
            }
        }
        let mut binds = Vector::<ISub>::new();
        let mut is_extern = false;
        {
            let da = unsafe &*self.p().module_ast_const(fm);
            let k = da.at_const(fnode).kind;
            if closure || k == NodeKind::NODE_CLOSURE {
                closure = true;
                if da.at_const(fnode).kind != NodeKind::NODE_CLOSURE {
                    let _ = self.bail();
                    return false;
                }
            } else {
                if k != NodeKind::NODE_FUNCTION {
                    let _ = self.bail();
                    return false;
                }
                is_extern = da.at_const(fnode).as_data.function.is_extern;
            }
        }
        if is_extern {
            return self.intercept(b, env, t, fm, fnode, &args);
        }
        if !closure {
            // An interface member: the receiver's own override wins; an inherited DEFAULT body
            // runs with Self bound to the receiver type (mirroring the established evaluator).
            let mut container = NODE_NONE;
            let ck2 = self.container_of(fm, fnode, &mut container);
            if ck2 == 2 {
                let mut st_t = TYPE_NONE;
                if t.args_len != 0 {
                    st_t = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
                } else if t.dests_len >= 1 {
                    st_t = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
                }
                let mut sm2: ModuleId = 0;
                let mut st2 = TYPE_NONE;
                if st_t == TYPE_NONE || !self.rty(b.module, st_t, &mut sm2, &mut st2) {
                    let _ = self.bail();
                    return false;
                }
                // peel references/pointers to the receiver value type, re-resolving each hop
                for _ in 0..3 {
                    let y2 = *(unsafe &*self.p().module_ast_const(sm2)).type_at(st2);
                    if y2.kind != TypeKind::TYPE_REFERENCE && y2.kind != TypeKind::TYPE_POINTER {
                        break;
                    }
                    let mut pm2: ModuleId = 0;
                    let mut pt2 = TYPE_NONE;
                    if !self.rty(sm2, y2.as_data.elem, &mut pm2, &mut pt2) {
                        let _ = self.bail();
                        return false;
                    }
                    sm2 = pm2;
                    st2 = pt2;
                }
                let mut rdm: ModuleId = 0;
                let mut rdn = NODE_NONE;
                let mut rn: u8 = 0;
                let mut ram: [ModuleId; 4] = [0, 0, 0, 0];
                let mut rat: [TypeId; 4] = [TYPE_NONE, TYPE_NONE, TYPE_NONE, TYPE_NONE];
                let mut rb = BuiltinType::BT_COUNT;
                let yr = *(unsafe &*self.p().module_ast_const(sm2)).type_at(st2);
                if yr.kind == TypeKind::TYPE_BUILTIN {
                    rb = yr.as_data.builtin;
                } else if !self.recv_of(sm2, st2, &mut rdm, &mut rdn, &mut rn, &mut ram[0], &mut rat[0]) {
                    let _ = self.bail();
                    return false;
                }
                let fa0 = unsafe &*self.p().module_ast_const(fm);
                let mnm = fa0.at_const(fa0.at_const(fnode).as_data.function.name).as_data.name.text;
                let md = self.find_method(rdm, rdn, rb, b.module, fm, mnm);
                if md.node != NODE_NONE {
                    fm = md.module;
                    fnode = md.node;
                    let fa1 = unsafe &*self.p().module_ast_const(fm);
                    if fa1.at_const(fnode).kind != NodeKind::NODE_FUNCTION || fa1.at_const(fnode).as_data.function.body == NODE_NONE {
                        let _ = self.bail();
                        return false;
                    }
                } else if fa0.at_const(fnode).as_data.function.body != NODE_NONE {
                    // the interface's default body: only a NON-generic receiver binds Self
                    if rn != 0 {
                        let _ = self.bail();
                        return false;
                    }
                    if !self.subst_add(&mut binds, fm, container, sm2, st2) {
                        let _ = self.bail();
                        return false;
                    }
                } else {
                    let _ = self.bail();
                    return false;
                }
            }
            {
                // a bodyless callee survives only long enough for the interface dispatch above
                // to redirect it; anything still without a body cannot fold
                let fa9 = unsafe &*self.p().module_ast_const(fm);
                if fa9.at_const(fnode).as_data.function.body == NODE_NONE {
                    let _ = self.bail();
                    return false;
                }
            }
            // generic bindings: the enclosing extend's parameters bind from the receiver's
            // instance, the function's own from the call's type arguments
            let ext = self.extend_of(fm, fnode);
            if ext != NODE_NONE {
                let xa = unsafe &*self.p().module_ast_const(fm);
                let xgens = xa.at_const(ext).as_data.extend_def.generics;
                if xgens.len != 0 {
                    // the receiver's instance binds the extend parameters; a receiver-less
                    // associated call binds them from the leading type arguments, or (like the
                    // emitter's symbol resolution) from the DESTINATION type
                    let mut bound = false;
                    if t.args_len != 0 {
                        let rop = *b.operands.at(b.oper_pool[t.args_start as usize] as usize);
                        let mut rdm: ModuleId = 0;
                        let mut rdn = NODE_NONE;
                        let mut rn: u8 = 0;
                        let mut ram: [ModuleId; 4] = [0, 0, 0, 0];
                        let mut rat: [TypeId; 4] = [TYPE_NONE, TYPE_NONE, TYPE_NONE, TYPE_NONE];
                        if self.recv_of(b.module, rop.ty, &mut rdm, &mut rdn, &mut rn, &mut ram[0], &mut rat[0]) {
                            bound = self.bind_extend(&mut binds, fm, ext, rn, &ram[0], &rat[0]);
                        }
                    }
                    if !bound && t.dests_len >= 1 {
                        let dty = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
                        let mut rdm: ModuleId = 0;
                        let mut rdn = NODE_NONE;
                        let mut rn: u8 = 0;
                        let mut ram: [ModuleId; 4] = [0, 0, 0, 0];
                        let mut rat: [TypeId; 4] = [TYPE_NONE, TYPE_NONE, TYPE_NONE, TYPE_NONE];
                        if dty != TYPE_NONE && self.recv_of(
                            b.module,
                            dty,
                            &mut rdm,
                            &mut rdn,
                            &mut rn,
                            &mut ram[0],
                            &mut rat[0],
                        ) {
                            bound = self.bind_extend(&mut binds, fm, ext, rn, &ram[0], &rat[0]);
                        }
                    }
                    if !bound {
                        if t.targs_len < xgens.len {
                            let _ = self.bail();
                            return false;
                        }
                        let xids = xa.list(xgens);
                        for i in 0..xgens.len {
                            let targ = b.targ_pool[(t.targs_start + i) as usize];
                            let mut am2: ModuleId = 0;
                            let mut at2 = TYPE_NONE;
                            if !self.rty(b.module, targ, &mut am2, &mut at2) {
                                let _ = self.bail();
                                return false;
                            }
                            let ta = unsafe &*self.p().module_ast_const(am2);
                            if !ta.type_concrete(at2) || self.ty_no_const(am2, at2, 0) {
                                let _ = self.bail();
                                return false;
                            }
                            if !self.subst_add(&mut binds, fm, unsafe xids[i as usize], am2, at2) {
                                let _ = self.bail();
                                return false;
                            }
                        }
                    }
                }
            }
            let fa = unsafe &*self.p().module_ast_const(fm);
            let fg = fa.at_const(fnode).as_data.function.generics;
            if fg.len != 0 {
                if t.targs_len < fg.len {
                    let _ = self.bail();
                    return false;
                }
                let skip = t.targs_len - fg.len;
                let gids = fa.list(fg);
                for i in 0..fg.len {
                    let targ = b.targ_pool[(t.targs_start + skip + i) as usize];
                    let mut am2: ModuleId = 0;
                    let mut at2 = TYPE_NONE;
                    if !self.rty(b.module, targ, &mut am2, &mut at2) {
                        let _ = self.bail();
                        return false;
                    }
                    let ta = unsafe &*self.p().module_ast_const(am2);
                    if !ta.type_concrete(at2) || self.ty_no_const(am2, at2, 0) {
                        // a '@no_const' type argument puts the call outside the const contract
                        let _ = self.bail();
                        return false;
                    }
                    if !self.subst_add(&mut binds, fm, unsafe gids[i as usize], am2, at2) {
                        let _ = self.bail();
                        return false;
                    }
                }
            }
        }
        // The memo key carries every semantic input: the callee identity and each argument's
        // kind, type, and bits (objects, pointers, and generic instances never memo).
        let mut mkey: u64 = 1469598103934665603u64;
        let mut memoable = t.dests_len <= 1 && binds.len() == 0 && !closure;
        mkey = (mkey ^ fm as u64) * 1099511628211u64;
        mkey = (mkey ^ fnode as u64) * 1099511628211u64;
        for i in 0..args.len() {
            let av = *args.at(i);
            if av.kind == IV_OBJ || av.kind == IV_PTR {
                memoable = false;
            }
            mkey = (mkey ^ av.kind as u64) * 1099511628211u64;
            mkey = (mkey ^ av.ty as u64) * 1099511628211u64;
            mkey = (mkey ^ av.i as u64) * 1099511628211u64;
            mkey = (mkey ^ av.f as u64) * 1099511628211u64;
        }
        if memoable {
            let mut hit = false;
            let mut hv = none();
            switch self.call_memo.get(&mkey) {
                Some(v) => {
                    hit = true;
                    hv = *v;
                },
                None => {},
            };
            if hit {
                if t.dests_len >= 1 {
                    let dp = b.dest_pool[t.dests_start as usize];
                    self.write_place(b, env, dp, hv);
                }
                return !self.failed;
            }
        }
        // The const-fn guarantee: a failure at or below a `const fn` whose bindings resolved is
        // promotable (silent ones synthesize the definite trap once the package is fully typed).
        let mut is_constfn = false;
        if !closure {
            let fa2 = unsafe &*self.p().module_ast_const(fm);
            is_constfn = fa2.at_const(fnode).as_data.function.is_const;
        }
        let bidx = self.body_of(fm, fnode, &binds, closure);
        if bidx < 0 {
            if stdlib::getenv("SC_IRI_DBG") != null {
                let da9 = unsafe &*self.p().module_ast_const(fm);
                let nm9 = da9.at_const(da9.at_const(fnode).as_data.function.name).as_data.name.text;
                let src9 = self.src_of(fm);
                eprint(
                    "iri: body_of failed `{}` const={} binds={}\n",
                    src9.slice(nm9.start as usize, nm9.end as usize),
                    is_constfn,
                    binds.len(),
                );
            }
            if is_constfn {
                if self.trap.len() == 0 && self.all_typed {
                    self.it_trap(
                        IT_TRAP_UNSUPPORTED,
                        "a 'const fn' hit an operation the compile-time evaluator does not support",
                    );
                }
                self.trap_in_constfn = true;
            }
            let _ = self.bail();
            return false;
        }
        if self.nframes >= IT_MAX_FRAMES {
            self.it_trap(IT_TRAP_BUDGET_DEPTH, "const-eval call depth exceeded");
            return false;
        }
        let bp: *const irl::Lowerer = self.bodies.at(bidx as usize).get();
        let bb = (unsafe &(&*bp).body) as *const ir::CoreBody;
        // the callee frame's substitution window
        let sb0 = self.subst.len();
        for i in 0..binds.len() {
            self.subst.push(*binds.at(i));
        }
        let prev_base = self.sub_base;
        self.sub_base = sb0;
        unsafe self.fstack[self.nframes as usize] = DefId { module: fm, node: fnode };
        self.nframes += 1;
        let r = self.run(unsafe &*bb, &args);
        self.nframes -= 1;
        self.sub_base = prev_base;
        self.subst.truncate(sb0);

        if self.failed {
            if stdlib::getenv("SC_IRI_DBG") != null {
                let da9 = unsafe &*self.p().module_ast_const(fm);
                let nm9 = da9.at_const(da9.at_const(fnode).as_data.function.name).as_data.name.text;
                let src9 = self.src_of(fm);
                eprint(
                    "iri: run failed `{}` const={} trap=`{}`\n",
                    src9.slice(nm9.start as usize, nm9.end as usize),
                    is_constfn,
                    self.trap,
                );
            }
            if is_constfn {
                if self.trap.len() == 0 && self.all_typed {
                    self.it_trap(
                        IT_TRAP_UNSUPPORTED,
                        "a 'const fn' hit an operation the compile-time evaluator does not support",
                    );
                }
                self.trap_in_constfn = true;
            }
            return false;
        }
        if memoable && r.kind != IV_OBJ && r.kind != IV_PTR {
            self.call_memo.insert(mkey, r);
        }
        // every return slot lands in its destination (self.rets dies with the next frame)
        for di in 0..t.dests_len {
            if di as usize >= self.rets.len() && di != 0 {
                break;
            }
            let dv = if di == 0 {
                r;
            } else {
                *self.rets.at(di as usize);
            };
            let dp = b.dest_pool[(t.dests_start + di) as usize];
            self.write_place(b, env, dp, dv);
            if self.failed && stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: dest write failed di={} dvkind={}\n", di, dv.kind);
            }
        }
        return !self.failed;
    }

    // Intercepted extern calls: the C heap, the trap runtime, and libm.
    fn intercept(
        self: &mut Self,
        b: &ir::CoreBody,
        env: u32,
        t: &ir::Terminator,
        fm: ModuleId,
        fnode: NodeId,
        args: &Vector<IVal>,
    ) bool {
        let da = unsafe &*self.p().module_ast_const(fm);
        let nm = da.at_const(da.at_const(fnode).as_data.function.name).as_data.name.text;
        let nargs = args.len();
        let mut out = none();
        let mut ok = false;
        let rt = if t.dests_len >= 1 {
            b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
        } else {
            TYPE_NONE;
        };
        if self.span_is(fm, nm, "malloc") {
            if nargs != 1 || args.at(0).kind != IV_INT || args.at(0).i < 0 {
                let _ = self.bail();
                return false;
            }
            let o = self.obj_new(0);
            if o == 0 {
                return false;
            }
            unsafe self.obj_ptr(o).heap = 1;
            unsafe self.obj_ptr(o).bytes = args.at(0).i as u64;
            out = iv_ptr(b.module, rt, o, 0);
            ok = true;
        } else if self.span_is(fm, nm, "realloc") {
            if nargs != 2 || args.at(0).kind != IV_PTR || args.at(1).kind != IV_INT || args.at(1).i < 0 {
                let _ = self.bail();
                return false;
            }
            let nbytes = args.at(1).i as u64;
            let pid = pv_obj(*args.at(0));
            if pid == 0 {
                let o = self.obj_new(0);
                if o == 0 {
                    return false;
                }
                unsafe self.obj_ptr(o).heap = 1;
                unsafe self.obj_ptr(o).bytes = nbytes;
                out = iv_ptr(b.module, rt, o, 0);
                ok = true;
            } else {
                let blk = self.obj_ptr(pid);
                if blk == null || unsafe blk.heap == 0 || pv_off(*args.at(0)) != 0 {
                    let _ = self.bail();
                    return false;
                }
                if unsafe blk.dead != 0 {
                    self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
                    return false;
                }
                if unsafe blk.et != TYPE_NONE {
                    let esz = unsafe blk.esz;
                    if esz == 0 || nbytes % esz != 0 {
                        let _ = self.bail();
                        return false;
                    }
                    if !self.obj_resize(pid, (nbytes / esz) as u32) {
                        return false;
                    }
                }
                unsafe self.obj_ptr(pid).bytes = nbytes;
                out = iv_ptr(b.module, rt, pid, 0);
                ok = true;
            }
        } else if self.span_is(fm, nm, "free") {
            if nargs != 1 || args.at(0).kind != IV_PTR {
                let _ = self.bail();
                return false;
            }
            let pid = pv_obj(*args.at(0));
            if pid != 0 {
                let blk = self.obj_ptr(pid);
                if blk == null || unsafe blk.heap == 0 || pv_off(*args.at(0)) != 0 {
                    let _ = self.bail();
                    return false;
                }
                if unsafe blk.dead != 0 {
                    self.it_trap(IT_TRAP_UB_DOUBLE_FREE, "double free");
                    return false;
                }
                unsafe blk.dead = 1;
            }
            out = iv_unit();
            ok = true;
        } else if self.span_is(fm, nm, "memset") {
            if !self.mem_set(b, args, rt, &mut out) {
                return false;
            }
            ok = true;
        } else if self.span_is(fm, nm, "memcpy") {
            if !self.mem_cpy(b, args, rt, &mut out) {
                return false;
            }
            ok = true;
        } else if self.span_is(fm, nm, "memcmp") {
            if !self.mem_cmp(b, args, rt, &mut out) {
                return false;
            }
            ok = true;
        } else if self.span_is(fm, nm, "abort") {
            self.it_trap(IT_TRAP_PANIC, "abort reached at compile time");
            return false;
        } else if self.span_is(fm, nm, "__sc_panic_str") || self.span_is(fm, nm, "__sc_panic") {
            self.it_trap(IT_TRAP_PANIC, "panic reached at compile time");
            return false;
        } else {
            // libm by name; a trailing `f` selects the f32 narrowing
            let ln = (nm.end - nm.start) as usize;
            if ln == 0 || ln >= 24 || nargs < 1 || nargs > 3 {
                let _ = self.bail();
                return false;
            }
            let full = self.src_of(fm).slice(nm.start as usize, nm.end as usize);
            let mut name = full;
            let mut f32suf = false;
            if ln > 1 && full.byte_at(ln - 1) == 102 {
                f32suf = true;
                name = full.slice(0, ln - 1);
            }
            let mut inv: [f64; 3] = [0.0f64, 0.0f64, 0.0f64];
            for i in 0..nargs {
                if args.at(i).kind != IV_FLOAT {
                    let _ = self.bail();
                    return false;
                }
                unsafe inv[i] = args.at(i).f;
            }
            let mut v: f64 = 0.0;
            let mut okm = false;
            if nargs == 1 {
                let r = libm1(name, inv[0]);
                okm = r.ok;
                v = r.v;
            } else if nargs == 2 {
                let r = libm2(name, inv[0], inv[1]);
                okm = r.ok;
                v = r.v;
            } else if name == "fma" {
                v = unsafe math::fma(inv[0], inv[1], inv[2]);
                okm = true;
            }
            if !okm {
                let _ = self.bail();
                return false;
            }
            if f32suf {
                v = v as f32;
            }
            out = iv_float(b.module, rt, v);
            ok = true;
        }
        if !ok {
            let _ = self.bail();
            return false;
        }
        if t.dests_len >= 1 && out.kind != IV_UNIT {
            let dp = b.dest_pool[t.dests_start as usize];
            self.write_place(b, env, dp, out);
        }
        return !self.failed;
    }

    fn mem_set(self: &mut Self, b: &ir::CoreBody, args: &Vector<IVal>, rt: TypeId, out: &mut IVal) bool {
        let _ = b;
        if args.len() != 3 || args.at(0).kind != IV_PTR || args.at(1).kind != IV_INT || args.at(2).kind != IV_INT || args.at(
            2,
        ).i < 0 {
            let _ = self.bail();
            return false;
        }
        let n = args.at(2).i as u64;
        let pid = pv_obj(*args.at(0));
        if pid == 0 {
            if n != 0 {
                let _ = self.bail();
                return false;
            }
            *out = *args.at(0);
            return true;
        }
        let blk = self.obj_ptr(pid);
        if blk == null || unsafe blk.heap == 0 {
            let _ = self.bail();
            return false;
        }
        if unsafe blk.dead != 0 {
            self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
            return false;
        }
        if unsafe blk.et == TYPE_NONE && pv_off(*args.at(0)) == 0 {
            let bytes = unsafe blk.bytes;
            if !self.obj_resize(pid, bytes as u32) {
                return false;
            }
            let b2 = self.obj_ptr(pid);
            unsafe b2.em = 0;
            unsafe b2.et = Ast::builtin(BuiltinType::BT_U8);
            unsafe b2.esz = 1;
        }
        let bb = self.obj_ptr(pid);
        let esz = unsafe bb.esz;
        if esz == 0 || n % esz != 0 {
            let _ = self.bail();
            return false;
        }
        let count = n / esz;
        let off = pv_off(*args.at(0)) as u64;
        if off + count > (unsafe bb.slots.len()) as u64 {
            self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
            return false;
        }
        let mut fill = none();
        if esz == 1 {
            fill = iv_int(0, Ast::builtin(BuiltinType::BT_U8), args.at(1).i & 0xff);
        } else {
            if args.at(1).i != 0 {
                let _ = self.bail();
                return false;
            }
            fill = self.zero_of(unsafe bb.em, unsafe bb.et, 0);
            if fill.kind == IV_NONE {
                let _ = self.bail();
                return false;
            }
        }
        for i in 0..count {
            let cloned = self.obj_clone(fill, 0);
            unsafe self.obj_ptr(pid).slots.set((off + i) as usize, cloned);
        }
        let _ = rt;
        *out = *args.at(0);
        return true;
    }

    // A byte-typed (non-heap) pointer copies with element size 1; heap blocks use their own.
    const fn ptr_elem_is_byte(self: &Self, v: IVal) bool {
        if v.ty == TYPE_NONE {
            return false;
        }
        let a = unsafe &*self.p().module_ast_const(v.tm);
        let y = *a.type_at(v.ty);
        if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
            return false;
        }
        let e = *a.type_at(y.as_data.elem);
        return e.kind == TypeKind::TYPE_BUILTIN && (e.as_data.builtin == BuiltinType::BT_U8 || e.as_data.builtin == BuiltinType::BT_I8 || e.as_data.builtin == BuiltinType::BT_CHAR);
    }

    fn mem_cpy(self: &mut Self, b: &ir::CoreBody, args: &Vector<IVal>, rt: TypeId, out: &mut IVal) bool {
        let _ = b;
        let _ = rt;
        if args.len() != 3 || args.at(0).kind != IV_PTR || args.at(1).kind != IV_PTR || args.at(2).kind != IV_INT || args.at(
            2,
        ).i < 0 {
            let _ = self.bail();
            return false;
        }
        let n = args.at(2).i as u64;
        if n == 0 {
            *out = *args.at(0);
            return true;
        }
        let did = pv_obj(*args.at(0));
        let sid = pv_obj(*args.at(1));
        if did == 0 || sid == 0 {
            let _ = self.bail();
            return false;
        }
        let dp = self.obj_ptr(did);
        let sp2 = self.obj_ptr(sid);
        if dp == null || sp2 == null {
            let _ = self.bail();
            return false;
        }
        if unsafe dp.dead != 0 || unsafe sp2.dead != 0 {
            self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
            return false;
        }
        // A fresh HEAP block with no element type yet adopts the source's, exactly as memset does.
        // An inline array (String's small buffer) is not a heap block and must not be reshaped.
        if unsafe dp.heap != 0 && unsafe dp.et == TYPE_NONE && pv_off(*args.at(0)) == 0 && unsafe sp2.esz != 0 {
            let bytes = unsafe dp.bytes;
            let esz0 = unsafe sp2.esz;
            if bytes % esz0 == 0 && self.obj_resize(did, (bytes / esz0) as u32) {
                let d2 = self.obj_ptr(did);
                unsafe d2.em = unsafe sp2.em;
                unsafe d2.et = unsafe sp2.et;
                unsafe d2.esz = esz0;
            }
        }
        let db = self.obj_ptr(did);
        let sb = self.obj_ptr(sid);
        let mut esz = unsafe db.esz;
        if unsafe db.heap == 0 {
            esz = 0;
            if self.ptr_elem_is_byte(*args.at(0)) {
                esz = 1;
            }
        }
        let mut ssz = unsafe sb.esz;
        if unsafe sb.heap == 0 {
            ssz = 0;
            if self.ptr_elem_is_byte(*args.at(1)) {
                ssz = 1;
            }
        }
        if esz == 0 || esz != ssz || n % esz != 0 {
            let _ = self.bail();
            return false;
        }
        let count = n / esz;
        let doff = pv_off(*args.at(0)) as u64;
        let soff = pv_off(*args.at(1)) as u64;
        if doff + count > (unsafe db.slots.len()) as u64 || soff + count > (unsafe sb.slots.len()) as u64 {
            self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
            return false;
        }
        for i in 0..count {
            let sv = unsafe self.obj_ptr(sid).slots[(soff + i) as usize];
            if sv.kind == IV_NONE {
                let _ = self.bail();
                return false;
            }
            let cloned = self.obj_clone(sv, 0);
            if cloned.kind == IV_NONE {
                let _ = self.bail();
                return false;
            }
            unsafe self.obj_ptr(did).slots.set((doff + i) as usize, cloned);
        }
        *out = *args.at(0);
        return true;
    }

    fn mem_cmp(self: &mut Self, b: &ir::CoreBody, args: &Vector<IVal>, rt: TypeId, out: &mut IVal) bool {
        if args.len() != 3 || args.at(0).kind != IV_PTR || args.at(1).kind != IV_PTR || args.at(2).kind != IV_INT || args.at(
            2,
        ).i < 0 {
            let _ = self.bail();
            return false;
        }
        let n = args.at(2).i as u64;
        if n == 0 {
            *out = iv_int(b.module, rt, 0);
            return true;
        }
        let b1 = self.obj_ptr(pv_obj(*args.at(0)));
        let b2 = self.obj_ptr(pv_obj(*args.at(1)));
        if b1 == null || b2 == null || unsafe b1.heap == 0 || unsafe b2.heap == 0 || unsafe b1.esz != 1 || unsafe b2.esz != 1 {
            let _ = self.bail(); // byte-exact comparison is only modeled for 1-byte-element blocks
            return false;
        }
        if unsafe b1.dead != 0 || unsafe b2.dead != 0 {
            self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
            return false;
        }
        let o1 = pv_off(*args.at(0)) as u64;
        let o2 = pv_off(*args.at(1)) as u64;
        if o1 + n > (unsafe b1.slots.len()) as u64 || o2 + n > (unsafe b2.slots.len()) as u64 {
            self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
            return false;
        }
        let mut r: i64 = 0;
        for i in 0..n {
            let s1 = unsafe b1.slots[(o1 + i) as usize];
            let s2 = unsafe b2.slots[(o2 + i) as usize];
            if s1.kind != IV_INT || s2.kind != IV_INT {
                let _ = self.bail(); // uninitialized bytes: not comparable
                return false;
            }
            let va = s1.i & 0xff;
            let vb = s2.i & 0xff;
            if va != vb {
                r = 1;
                if va < vb {
                    r = 0 - 1;
                }
                break;
            }
        }
        *out = iv_int(b.module, rt, r);
        return true;
    }

    // ---- places -----------------------------------------------------------------------------------

    // Field/tuple-member count of aggregate decl `(dm, dn)`.
    fn field_count(self: &Self, dm: ModuleId, dn: NodeId) u32 {
        let a = unsafe &*self.p().module_ast_const(dm);
        let is_tuple = a.at_const(dn).as_data.aggregate.is_tuple;
        let ms = a.at_const(dn).as_data.aggregate.members;
        let mut n: u32 = 0;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            if !is_tuple && a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            n += 1;
        }
        return n;
    }

    // Field ordinal of decl `sub` inside its aggregate (payload fields ride the variant slot walk).
    fn field_ordinal(self: &Self, dm: ModuleId, owner: NodeId, sub: NodeId) i64 {
        let a = unsafe &*self.p().module_ast_const(dm);
        let is_tuple = a.at_const(owner).as_data.aggregate.is_tuple;
        let ms = a.at_const(owner).as_data.aggregate.members;
        let mut ord: i64 = 0;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            // tuple members are bare type nodes; named members are NODE_FIELD
            if !is_tuple && a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            if fid == sub {
                return ord;
            }
            ord += 1;
        }
        return -1;
    }

    // Classify decl (dm, dn) as an indexable view the way cemit routes subscripts: 1 = ptr/len
    // view (str, Slice, SliceMut, Vector; `p` and `l` get the ptr/len field ordinals), 2 = Array
    // (`p` gets the data ordinal), 0 = not a view.
    fn view_of(self: &Self, dm: ModuleId, dn: NodeId, p: &mut i64, l: &mut i64) u8 {
        let a = unsafe &*self.p().module_ast_const(dm);
        if a.at_const(dn).kind != NodeKind::NODE_STRUCT || a.at_const(dn).as_data.aggregate.is_tuple {
            return 0;
        }
        let nm = a.at_const(a.at_const(dn).as_data.aggregate.name).as_data.name.text;
        let mut kind: u8 = 0;
        if self.span_is(dm, nm, "str") || self.span_is(dm, nm, "Slice") || self.span_is(dm, nm, "SliceMut") || self.span_is(
            dm,
            nm,
            "Vector",
        ) {
            kind = 1;
        } else if self.span_is(dm, nm, "Array") {
            kind = 2;
        } else {
            return 0;
        }
        let ms = a.at_const(dn).as_data.aggregate.members;
        let mut ord: i64 = 0;
        *p = -1;
        *l = -1;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            if a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let fnm = a.at_const(a.at_const(fid).as_data.field.name).as_data.name.text;
            if kind == 1 && self.span_is(dm, fnm, "ptr") {
                *p = ord;
            } else if kind == 1 && self.span_is(dm, fnm, "len") {
                *l = ord;
            } else if kind == 2 && self.span_is(dm, fnm, "data") {
                *p = ord;
            }
            ord += 1;
        }
        if *p < 0 || kind == 1 && *l < 0 {
            return 0;
        }
        return kind;
    }

    /// The value of referenced item `(m, cnode)`, lowered and executed on demand. Memoized for
    /// scalars; a re-entry while active is a cyclic constant dependency. Objects are NOT memoized
    /// (their ids die with the evaluation that built them). A function item is its value.
    fn item_value(self: &mut Self, m: ModuleId, cnode: NodeId) IVal {
        let key = m as u64 << 32 | cnode as u64;
        switch self.item_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            None => {},
        };
        let a = unsafe &*self.p().module_ast_const(m);
        if a.at_const(cnode).kind == NodeKind::NODE_FUNCTION {
            return IVal { kind: IV_FN, tm: m, ty: TYPE_NONE, i: m as i64 << 32 | cnode as i64, f: 0.0 };
        }
        if a.at_const(cnode).kind == NodeKind::NODE_GENERIC_PARAM {
            // a const-generic parameter referenced as a value: its binding in the ACTIVE window
            // carries the interned TYPE_CONST
            let mut i2 = self.sub_base;
            while i2 < self.subst.len() {
                let sb2 = *self.subst.at(i2);
                if sb2.pmod == m && sb2.pnode == cnode {
                    let ya = unsafe &*self.p().module_ast_const(sb2.am);
                    if sb2.at as usize < ya.type_pool.len() {
                        let yv = *ya.type_at(sb2.at);
                        if yv.kind == TypeKind::TYPE_CONST {
                            return iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), yv.as_data.value);
                        }
                    }
                    break;
                }
                i2 += 1;
            }
            return self.bail();
        }
        if a.at_const(cnode).kind == NodeKind::NODE_VARIANT {
            // a payload-less variant referenced as an item IS its discriminant (an untyped
            // module's `E::COUNT as usize` const family)
            if a.at_const(cnode).as_data.variant.payload.len > 0 {
                return self.bail();
            }
            let mut ed = NODE_NONE;
            let items9 = a.at_const(a.root).as_data.program.items;
            for i9 in 0..items9.len {
                let iid9 = unsafe a.list(items9)[i9 as usize];
                if a.at_const(iid9).kind != NodeKind::NODE_ENUM {
                    continue;
                }
                let ms9 = a.at_const(iid9).as_data.aggregate.members;
                for k9 in 0..ms9.len {
                    if unsafe a.list(ms9)[k9 as usize] == cnode {
                        ed = iid9;
                    }
                }
            }
            if ed == NODE_NONE || self.user_free(m, ed) {
                return self.bail();
            }
            let mut tagv: i64 = -1;
            if !self.variant_value(DefId { module: m, node: cnode }, &mut tagv) {
                return self.bail();
            }
            return iv_int(m, TYPE_NONE, tagv);
        }
        for i in 0..self.item_active.len() {
            if self.item_active[i] == key {
                self.it_trap(IT_TRAP_CYCLE, "cyclic constant dependency");
                return none();
            }
        }
        if a.at_const(cnode).kind != NodeKind::NODE_CONST {
            return self.bail();
        }
        let cd = a.at_const(cnode).as_data.const_def;
        if cd.value == NODE_NONE || cd.is_extern || cd.is_static_mut {
            return self.bail();
        }
        self.item_active.push(key);
        let mut lw = irl::Lowerer::new(self.pkg, m, cnode);
        let mut r = none();
        if lw.lower_const(cnode) {
            let args = Vector::<IVal>::new();
            r = self.run(&lw.body, &args);
        } else {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: item lower failed m={} n={} err=`{}`\n", m, cnode, lw.err);
            }
            let _ = self.bail();
        }
        let _ = self.item_active.pop();
        if !self.failed && r.kind != IV_OBJ && r.kind != IV_PTR && r.kind != IV_NONE {
            self.item_memo.insert(key, r);
        }
        return r;
    }

    // Turn a string-literal value into its object form (byte heap block + the str struct with
    // ptr/len located by field name) so projections and calls read through it.
    fn str_materialize(self: &mut Self, m: ModuleId, v: IVal) IVal {
        let sp = tok::Span { start: (v.i >> 32) as u32, end: (v.i & 0xFFFFFFFF) as u32 };
        let src = self.src_of(m);
        if sp.end < sp.start || sp.end as usize > src.len() {
            return self.bail();
        }
        let form = v.f as i64;
        let ttk = ((form & 0xFF) as u8) as TokenType;
        let seg = (form & 256) != 0;
        let raw = ttk == TokenType::RawStringLiteral || ttk == TokenType::MatchertextLiteral;
        let mut i = sp.start;
        let mut endpos = sp.end;
        if sp.end == sp.start {
            // nothing to scan: fall through with an empty range
        } else if !seg && ttk == TokenType::MatchertextLiteral {
            // past `Md"(` and before `)"`; the delimiter chain ends at the quote
            while i < sp.end && src.byte_at(i as usize) != 34 {
                i += 1;
            }
            if i + 2 >= sp.end {
                return self.bail();
            }
            i += 2;
            endpos = sp.end - 2;
        } else if !seg && ttk == TokenType::RawStringLiteral && sp.end > sp.start && src.byte_at(sp.start as usize) != 34 && src.byte_at(
            sp.start as usize,
        ) != 35 {
            // a verbatim content span (meta strings): no delimiters at all
        } else if !seg {
            let mut hashes: u32 = 0;
            while i < sp.end && src.byte_at(i as usize) != 34 {
                if src.byte_at(i as usize) == 35 {
                    hashes += 1;
                }
                i += 1;
            }
            if i >= sp.end {
                return self.bail();
            }
            i += 1;
            endpos = sp.end - 1;
            if raw {
                endpos -= hashes;
            }
        }
        let mut bytes = Vector::<u8>::new();
        while i < endpos {
            if bytes.len() >= 4096 {
                bytes.free();
                return self.bail();
            }
            let mut c = src.byte_at(i as usize);
            i += 1;
            if seg && ttk != TokenType::MatchertextLiteral && (c == 123 || c == 125) && i < endpos && src.byte_at(
                i as usize,
            ) == c {
                i += 1; // doubled template brace: one byte survives
            }
            if !raw && c == 92 && i < endpos {
                let e = src.byte_at(i as usize);
                i += 1;
                if e == 110 {
                    c = 10;
                } else if e == 116 {
                    c = 9;
                } else if e == 114 {
                    c = 13;
                } else if e == 48 {
                    c = 0;
                } else if e == 92 || e == 34 || e == 39 {
                    c = e;
                } else {
                    bytes.free();
                    return self.bail();
                }
            }
            bytes.push(c);
        }
        // the str struct decl comes from the literal's own type
        let a = unsafe &*self.p().module_ast_const(m);
        let mut dm: ModuleId = 0;
        let mut dn = NODE_NONE;
        if v.ty != TYPE_NONE {
            let y = *a.type_at(v.ty);
            if y.kind == TypeKind::TYPE_STRUCT {
                dm = y.module;
                dn = y.as_data.decl;
            } else if y.kind == TypeKind::TYPE_INSTANCE {
                let it2 = *a.instance(y.as_data.inst);
                dm = it2.module;
                dn = it2.decl;
            }
        }
        if dn == NODE_NONE {
            bytes.free();
            return self.bail();
        }
        let nb = bytes.len() as u32;
        let block = self.obj_new(nb);
        if block == 0 && nb != 0 {
            bytes.free();
            return none();
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
                    iv_int(0, Ast::builtin(BuiltinType::BT_U8), bytes[k as usize]),
                );
            }
        }
        bytes.free();
        let so = self.obj_new(self.field_count(dm, dn));
        if so == 0 {
            return none();
        }
        unsafe self.obj_ptr(so).dm = dm;
        unsafe self.obj_ptr(so).dn = dn;
        let da = unsafe &*self.p().module_ast_const(dm);
        let dms = da.at_const(dn).as_data.aggregate.members;
        let mut ptr_i: i64 = -1;
        let mut len_i: i64 = -1;
        let mut idx: i64 = 0;
        for kk in 0..dms.len {
            let fid = unsafe da.list(dms)[kk as usize];
            if da.at_const(fid).kind == NodeKind::NODE_FIELD {
                let fn2 = da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text;
                if self.span_is(dm, fn2, "ptr") {
                    ptr_i = idx;
                } else if self.span_is(dm, fn2, "len") {
                    len_i = idx;
                }
                idx += 1;
            }
        }
        if ptr_i < 0 || len_i < 0 {
            return self.bail();
        }
        unsafe self.obj_ptr(so).slots.set(ptr_i as usize, iv_ptr(0, TYPE_NONE, block, 0));
        unsafe self.obj_ptr(so).slots.set(len_i as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), nb));
        return IVal { kind: IV_OBJ, tm: m, ty: v.ty, i: so, f: 0.0 };
    }

    // A fixed array flowing into a slice-typed destination wraps into a view over its own
    // storage (mirroring the emitter's use-site wrap); anything else passes through.
    // A spelled-count designated literal is SHORTER than its destination array: C zero-fills the
    // tail at the destination, so the object grows zeroed slots to the destination extent here.
    fn arr_widen(self: &mut Self, rm: ModuleId, y: Ty, v: IVal) IVal {
        let want_len = y.as_data.arr.len as i64;
        let op = self.obj_ptr(v.i as u32);
        if op == null || want_len <= 0 {
            return v;
        }
        if unsafe op.dn != NODE_NONE || unsafe op.heap != 0 || unsafe op.is_enum != 0 || unsafe op.clos != 0 {
            return v;
        }
        let have = (unsafe op.slots.len()) as i64;
        if have >= want_len {
            return v;
        }
        let mut em2 = rm;
        let mut et2 = y.as_data.arr.elem;
        let _ = self.rty(rm, y.as_data.arr.elem, &mut em2, &mut et2);
        let ez = self.zero_of(em2, et2, 0);
        self.failed = false;
        if ez.kind == IV_NONE {
            return v;
        }
        if self.live_slots + (want_len - have) as u64 > self.max_slots {
            return v;
        }
        self.live_slots += (want_len - have) as u64;
        for _ in have..want_len {
            let cloned = self.obj_clone(ez, 0);
            unsafe self.obj_ptr(v.i as u32).slots.push(cloned);
        }
        return v;
    }

    fn maybe_slice_wrap(self: &mut Self, m: ModuleId, want: TypeId, v: IVal) IVal {
        if v.kind != IV_OBJ || want == TYPE_NONE {
            return v;
        }
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        if !self.rty(m, want, &mut rm, &mut rt) {
            return v;
        }
        let y = *(unsafe &*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.arr_widen(rm, y, v);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return v;
        }
        let it = *(unsafe &*self.p().module_ast_const(rm)).instance(y.as_data.inst);
        if self.ti_findf(it.module, it.decl, "ptr") < 0 || self.ti_findf(it.module, it.decl, "len") < 0 {
            return v; // not a slice-family destination
        }
        let op = self.obj_ptr(v.i as u32);
        if op == null {
            return v;
        }
        if unsafe op.dm == it.module && unsafe op.dn == it.decl {
            return v; // already the view
        }
        if unsafe op.dn != NODE_NONE || unsafe op.heap != 0 || unsafe op.is_enum != 0 || unsafe op.clos != 0 {
            return v; // only shapeless (array) objects wrap
        }
        let n = (unsafe op.slots.len()) as i64;
        let w = self.slice_view(m, want, v.i as u32, 0, n);
        if w.kind == IV_OBJ {
            return w;
        }
        self.failed = false;
        return v;
    }

    // A Slice/SliceMut view struct over storage (obj, off) with `n` elements; the decl comes
    // from the resolved slice type. IV_NONE = untranslatable target.
    fn slice_view(self: &mut Self, m: ModuleId, sty: TypeId, obj: u32, off: u32, n: i64) IVal {
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        if !self.rty(m, sty, &mut rm, &mut rt) {
            return none();
        }
        let y = *(unsafe &*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return none();
        }
        let it = *(unsafe &*self.p().module_ast_const(rm)).instance(y.as_data.inst);
        let sm = it.module;
        let sn = it.decl;
        let ptr_i = self.ti_findf(sm, sn, "ptr");
        let len_i = self.ti_findf(sm, sn, "len");
        if ptr_i < 0 || len_i < 0 || n < 0 {
            return none();
        }
        let so = self.obj_new(self.field_count(sm, sn));
        if so == 0 {
            return none();
        }
        unsafe self.obj_ptr(so).dm = sm;
        unsafe self.obj_ptr(so).dn = sn;
        unsafe self.obj_ptr(so).nargs = 1;
        unsafe self.obj_ptr(so).am[0] = if it.n > 0 {
            rm;
        } else {
            0;
        };
        unsafe self.obj_ptr(so).at[0] = if it.n > 0 {
            it.args[0];
        } else {
            TYPE_NONE;
        };
        unsafe self.obj_ptr(so).slots.set(ptr_i as usize, iv_ptr(0, TYPE_NONE, obj, off));
        unsafe self.obj_ptr(so).slots.set(len_i as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), n));
        return IVal { kind: IV_OBJ, tm: m, ty: sty, i: so, f: 0.0 };
    }

    // The byte contents of a `str` value: a literal decodes its span, a view struct reads its
    // ptr block. False = not a str-shaped value (or an unreadable one).
    fn str_bytes(self: &mut Self, v: IVal, out: &mut Vector<u8>) bool {
        let mut sv = v;
        if sv.kind == IV_STR {
            sv = self.str_materialize(sv.tm, sv);
            if self.failed || sv.kind != IV_OBJ {
                self.failed = false;
                return false;
            }
        }
        if sv.kind != IV_OBJ {
            return false;
        }
        let op = self.obj_ptr(sv.i as u32);
        if op == null || unsafe op.dn == NODE_NONE {
            return false;
        }
        let dm = unsafe op.dm;
        let dn = unsafe op.dn;
        let ptr_i = self.ti_findf(dm, dn, "ptr");
        let len_i = self.ti_findf(dm, dn, "len");
        if ptr_i < 0 || len_i < 0 {
            return false;
        }
        let pv = unsafe op.slots[ptr_i as usize];
        let lv = unsafe op.slots[len_i as usize];
        if lv.kind != IV_INT || lv.i < 0 {
            return false;
        }
        if lv.i == 0 {
            return true;
        }
        if pv.kind != IV_PTR || pv_obj(pv) == 0 {
            return false;
        }
        let blk = self.obj_ptr(pv_obj(pv));
        if blk == null || unsafe blk.dead != 0 {
            return false;
        }
        let off = pv_off(pv) as u64;
        if off + lv.i as u64 > (unsafe blk.slots.len()) as u64 {
            return false;
        }
        for i in 0..lv.i {
            let bv = unsafe self.obj_ptr(pv_obj(pv)).slots[(off + i as u64) as usize];
            if bv.kind != IV_INT {
                return false;
            }
            out.push((bv.i & 0xff) as u8);
        }
        return true;
    }

    // Resolve a place to (object id, slot). Frame locals live in the frame's env object, so every
    // resolved place is object-addressed; derefs walk through abstract pointers with the UB ladder.
    fn resolve_place(self: &mut Self, b: &ir::CoreBody, env: u32, pid: ir::PlaceId, obj: &mut u32, slot: &mut u32) bool {
        let pl = *b.places.at(pid as usize);
        *obj = env;
        *slot = pl.base;
        if b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF {
            // a referenced item: materialize its value into the local slot on first touch, so
            // projections read through it like any other local
            if (unsafe self.obj_ptr(env).slots[pl.base as usize]).kind == IV_NONE {
                let it = b.locals.at(pl.base as usize).item;
                let v = self.item_value(it.module, it.node);
                if self.failed {
                    return false;
                }
                unsafe self.obj_ptr(env).slots.set(pl.base as usize, v);
            }
        }
        let mut cur = unsafe self.obj_ptr(env).slots[pl.base as usize];
        for i in 0..pl.proj_len {
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            // a string literal materializes into its object form the moment a projection reads
            // through it (identity is preserved by writing the object back)
            if cur.kind == IV_STR {
                let sv = self.str_materialize(cur.tm, cur);
                if self.failed || sv.kind != IV_OBJ {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint(
                            "iri: str_materialize failed tm={} ty={} span={}..{}\n",
                            cur.tm,
                            cur.ty,
                            (cur.i >> 32) as u32,
                            (cur.i & 0xFFFFFFFF) as u32,
                        );
                    }
                    self.failed = true;
                    return false;
                }
                unsafe self.obj_ptr(*obj).slots.set((*slot) as usize, sv);
                cur = sv;
            }
            if pj.kind == ir::PJ_DEREF {
                if cur.kind == IV_OBJ {
                    continue; // an aggregate handle IS its referent (object ids alias like refs)
                }
                // the UB ladder, WITHOUT requiring the target initialized (a store through the
                // pointer addresses uninitialized storage legitimately)
                if cur.kind != IV_PTR {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint(
                            "iri: deref failed curkind={} obj={} off={} live={}\n",
                            cur.kind,
                            pv_obj(cur),
                            pv_off(cur),
                            self.objs_live,
                        );
                    }
                    self.failed = true;
                    return false;
                }
                let did = pv_obj(cur);
                if did == 0 {
                    if pv_off(cur) != 0 {
                        self.failed = true; // sentinel pointer: benign, not provable UB
                        return false;
                    }
                    self.it_trap(IT_TRAP_UB_NULL_DEREF, "null dereference");
                    return false;
                }
                let dop = self.obj_ptr(did);
                if dop == null {
                    self.failed = true;
                    return false;
                }
                if unsafe dop.dead != 0 {
                    self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
                    return false;
                }
                if pv_off(cur) as usize >= unsafe dop.slots.len() {
                    self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
                    return false;
                }
                *obj = did;
                *slot = pv_off(cur);
                cur = unsafe dop.slots[pv_off(cur) as usize];
                continue;
            }
            let mut idx: i64 = -1;
            let mut is_union = false;
            if pj.kind == ir::PJ_FIELD {
                if pj.data == ir::PJ_UNION_FIELD {
                    is_union = true;
                }
                if pj.sub != NODE_NONE {
                    // owner decl comes from the CURRENT object's identity when it has one, else
                    // from the value's type
                    let mut dm: ModuleId = 0;
                    let mut dn = NODE_NONE;
                    if cur.kind == IV_OBJ {
                        let op = self.obj_ptr(cur.i as u32);
                        if op != null && unsafe op.dn != NODE_NONE {
                            dm = unsafe op.dm;
                            dn = unsafe op.dn;
                        }
                    }
                    if dn == NODE_NONE {
                        let a = unsafe &*self.p().module_ast_const(cur.tm);
                        if cur.ty == TYPE_NONE {
                            self.failed = true;
                            return false;
                        }
                        let y = *a.type_at(cur.ty);
                        if y.kind == TypeKind::TYPE_STRUCT {
                            dm = y.module;
                            dn = y.as_data.decl;
                        } else if y.kind == TypeKind::TYPE_INSTANCE {
                            let it2 = *a.instance(y.as_data.inst);
                            dm = it2.module;
                            dn = it2.decl;
                        } else {
                            self.failed = true;
                            return false;
                        }
                    }
                    idx = self.field_ordinal(dm, dn, pj.sub);
                } else if pj.data != ir::IR_NONE && !is_union {
                    idx = pj.data;
                }
            } else if pj.kind == ir::PJ_INDEX_CONST {
                idx = pj.data;
            } else if pj.kind == ir::PJ_INDEX_OP {
                let iv = self.operand(b, env, pj.data);
                if iv.kind != IV_INT {
                    self.failed = true;
                    return false;
                }
                idx = iv.i;
            } else if pj.kind == ir::PJ_DOWNCAST {
                // payload slots follow the tag: slot k of variant payload = 1 + k, resolved by the
                // following field projection; the downcast itself just checks the object
                if cur.kind != IV_OBJ {
                    self.failed = true;
                    return false;
                }
                continue;
            } else {
                self.failed = true;
                return false;
            }
            if cur.kind == IV_OBJ && (pj.kind == ir::PJ_INDEX_CONST || pj.kind == ir::PJ_INDEX_OP) {
                // subscripting a length-carrying view (str/Slice/SliceMut/Vector) or an Array
                // routes through its storage member, exactly as cemit subscripts `.ptr`/`.data`
                let vop = self.obj_ptr(cur.i as u32);
                if vop != null && unsafe vop.dn != NODE_NONE {
                    let mut pord: i64 = -1;
                    let mut lord: i64 = -1;
                    let vk = self.view_of(unsafe vop.dm, unsafe vop.dn, &mut pord, &mut lord);
                    if vk == 1 {
                        let lenv = unsafe vop.slots[lord as usize];
                        if lenv.kind == IV_INT && (idx < 0 || idx >= lenv.i) {
                            self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
                            return false;
                        }
                        cur = unsafe vop.slots[pord as usize];
                        if cur.kind != IV_PTR {
                            self.failed = true;
                            return false;
                        }
                    } else if vk == 2 {
                        cur = unsafe vop.slots[pord as usize];
                    }
                }
            }
            if idx >= 0 && cur.kind == IV_PTR && (pj.kind == ir::PJ_INDEX_CONST || pj.kind == ir::PJ_INDEX_OP) {
                // p[i] through a pointer VALUE: address (p.obj, p.off + i) with the UB ladder
                let tid = pv_obj(cur);
                if tid == 0 {
                    if pv_off(cur) != 0 {
                        self.failed = true; // sentinel pointer: benign, not provable UB
                        return false;
                    }
                    self.it_trap(IT_TRAP_UB_NULL_DEREF, "null dereference");
                    return false;
                }
                let top = self.obj_ptr(tid);
                if top == null {
                    self.failed = true;
                    return false;
                }
                if unsafe top.dead != 0 {
                    self.it_trap(IT_TRAP_UB_USE_AFTER_FREE, "use after free");
                    return false;
                }
                let no = pv_off(cur) as i64 + idx;
                if no < 0 || no as usize >= unsafe top.slots.len() {
                    self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
                    return false;
                }
                *obj = tid;
                *slot = no as u32;
                cur = unsafe top.slots[no as usize];
                continue;
            }
            if idx >= 0 && cur.kind != IV_OBJ && cur.kind != IV_NONE && (pj.kind == ir::PJ_INDEX_CONST || pj.kind == ir::PJ_INDEX_OP) {
                // pointer-style element addressing: the index moves the SLOT position within the
                // addressed object's storage (the abstract heap is slot-indexed); an UNINITIALIZED
                // base is unknown storage, a benign failure, never a provable OOB
                let op2 = self.obj_ptr(*obj);
                if op2 == null {
                    self.failed = true;
                    return false;
                }
                let ns = (*slot) as i64 + idx;
                if ns < 0 || ns as usize >= unsafe op2.slots.len() {
                    self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
                    return false;
                }
                *slot = ns as u32;
                cur = unsafe op2.slots[ns as usize];
                continue;
            }
            if idx < 0 || cur.kind != IV_OBJ {
                self.failed = true;
                return false;
            }
            let id = cur.i as u32;
            let op = self.obj_ptr(id);
            if op == null {
                self.failed = true;
                return false;
            }
            // enum payload objects store the tag at slot 0
            let mut base_slot = idx;
            if unsafe op.is_enum != 0 {
                base_slot = idx + 1;
            }
            if base_slot < 0 || base_slot as usize >= unsafe op.slots.len() {
                if pj.kind == ir::PJ_INDEX_CONST || pj.kind == ir::PJ_INDEX_OP {
                    self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
                } else {
                    self.failed = true;
                }
                return false;
            }
            // a union read through a member other than the one written is refused; the write
            // path re-marks the active member after resolution
            if is_union && unsafe op.uactive >= 0 && unsafe op.uactive != base_slot as i32 {
                self.failed = true;
                return false;
            }
            *obj = id;
            *slot = base_slot as u32;
            cur = unsafe op.slots[base_slot as usize];
        }
        return true;
    }

    fn read_place(self: &mut Self, b: &ir::CoreBody, env: u32, pid: ir::PlaceId) IVal {
        let mut obj: u32 = 0;
        let mut slot: u32 = 0;
        if !self.resolve_place(b, env, pid, &mut obj, &mut slot) {
            return none();
        }
        return unsafe self.obj_ptr(obj).slots[slot as usize];
    }

    fn write_place(self: &mut Self, b: &ir::CoreBody, env: u32, pid: ir::PlaceId, v0: IVal) {
        let v = self.maybe_slice_wrap(b.module, b.places.at(pid as usize).ty, v0);
        let mut obj: u32 = 0;
        let mut slot: u32 = 0;
        if !self.resolve_place(b, env, pid, &mut obj, &mut slot) {
            return;
        }
        let cv = self.obj_clone(v, 0);
        if v.kind != IV_NONE && cv.kind == IV_NONE {
            self.failed = true;
            return;
        }
        let op = self.obj_ptr(obj);
        if op == null {
            self.failed = true;
            return;
        }
        // a union member write marks the active member
        if unsafe op.uactive >= 0 || unsafe op.dn != NODE_NONE && obj != env && self.is_union_decl(
            unsafe op.dm,
            unsafe op.dn,
        ) {
            unsafe op.uactive = slot as i32;
        }
        unsafe op.slots.set(slot as usize, cv);
    }

    const fn is_union_decl(self: &Self, dm: ModuleId, dn: NodeId) bool {
        let a = unsafe &*self.p().module_ast_const(dm);
        return a.at_const(dn).kind == NodeKind::NODE_STRUCT && a.at_const(dn).as_data.aggregate.is_union;
    }

    // ---- operands and rvalues ---------------------------------------------------------------------

    fn operand(self: &mut Self, b: &ir::CoreBody, env: u32, opid: ir::OperandId) IVal {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            let mut v = self.read_place(b, env, op.data);
            // the PLACE's checked type is authoritative for a scalar read: a stored literal may
            // carry its own (pre-adoption) type, and width-sensitive ops derive widths from it
            if v.kind == IV_INT || v.kind == IV_FLOAT {
                let pty = b.places.at(op.data as usize).ty;
                if pty != TYPE_NONE {
                    let mut pb = BuiltinType::BT_COUNT;
                    if self.bt_of(b.module, pty, &mut pb) && pb != BuiltinType::BT_COUNT {
                        v.tm = b.module;
                        v.ty = pty;
                    }
                }
            }
            return v;
        }
        if op.kind != ir::OP_CONST {
            return self.bail();
        }
        let c = *b.constants.at(op.data as usize);
        if c.kind == ir::CK_INT {
            // `null` IS the abstract null pointer, whatever type the record coalesced to
            if c.raw.end > c.raw.start {
                let s0n = self.src_of(b.module);
                if c.raw.end as usize <= s0n.len() && s0n.slice(c.raw.start as usize, c.raw.end as usize) == "null" {
                    return iv_ptr(b.module, c.ty, 0, 0);
                }
            }
            let mut v: i64 = 0;
            if !self.lit_value(b.module, &c, &mut v) {
                return self.bail();
            }
            return iv_int(b.module, c.ty, v);
        }
        if c.kind == ir::CK_BOOL {
            return IVal { kind: IV_BOOL, tm: b.module, ty: c.ty, i: c.val, f: 0.0 };
        }
        if c.kind == ir::CK_UNIT {
            return IVal { kind: IV_UNIT, tm: b.module, ty: c.ty, i: 0, f: 0.0 };
        }
        if c.kind == ir::CK_ITEM {
            if c.targ_len != 0 {
                return self.bail(); // generic associated consts do not fold yet
            }
            return self.item_value(c.item.module, c.item.node);
        }
        if c.kind == ir::CK_FLOAT {
            let sp = c.raw;
            let mut fv: f64 = 0.0;
            let mut okf = false;
            {
                let s0 = self.src_of(b.module);
                if sp.end > sp.start && sp.end as usize <= s0.len() {
                    let txt = s0.slice(sp.start as usize, sp.end as usize);
                    switch txt.parse_f64() {
                        Some(v) => {
                            fv = v;
                            okf = true;
                        },
                        None => {},
                    };
                }
            }
            if !okf {
                return self.bail();
            }
            return iv_float(b.module, c.ty, fv);
        }
        if c.kind == ir::CK_STR {
            let sp = c.raw;
            // `f` carries the literal form: token type | seg << 8 (the lowering encodes it)
            return IVal {
                kind: IV_STR,
                tm: b.module,
                ty: c.ty,
                i: sp.start as i64 << 32 | sp.end as i64,
                f: c.val as f64,
            };
        }
        return self.bail();
    }

    // The exact integer behind a CK_INT spelling: decimal, hex, binary, octal, underscores,
    // width suffixes, character literals with escapes, and `null` (0).
    fn lit_value(self: &mut Self, m: ModuleId, c: &ir::Constant, out: &mut i64) bool {
        let sp = c.raw;
        if sp.end <= sp.start {
            *out = c.val;
            return true;
        }
        let s0 = self.src_of(m);
        if sp.end as usize > s0.len() {
            *out = c.val;
            return true;
        }
        let s = s0.slice(sp.start as usize, sp.end as usize);
        let n = s.len();
        if n == 0 {
            *out = c.val;
            return true;
        }
        let b0 = s.byte_at(0);
        if b0 == 39 {
            // 'c' with escapes -- but ONLY a real character literal (a synthesized constant may
            // carry a diagnostic span that happens to start at a label's quote)
            if n < 3 || n > 8 || s.byte_at(n - 1) != 39 {
                *out = c.val;
                return true;
            }
            let c1 = s.byte_at(1);
            if c1 != 92 {
                *out = c1;
                return true;
            }
            let e = s.byte_at(2);
            if e == 110 {
                *out = 10;
            } else if e == 116 {
                *out = 9;
            } else if e == 114 {
                *out = 13;
            } else if e == 48 {
                *out = 0;
            } else if e == 92 || e == 39 || e == 34 {
                *out = e;
            } else if e == 120 && n >= 5 {
                let mut v: u64 = 0;
                for i in 3..n - 1 {
                    let d = hex_digit(s.byte_at(i));
                    if d < 0 {
                        return false;
                    }
                    v = v * 16 + d as u64;
                }
                *out = v as i64;
            } else {
                return false;
            }
            return true;
        }
        if !(b0 >= 48 && b0 <= 57) {
            // `null` and every other non-numeric spelling lower with the value the record carries
            *out = c.val;
            return true;
        }
        let mut base: u64 = 10;
        let mut i: usize = 0;
        if n > 2 && b0 == 48 {
            let b1 = s.byte_at(1);
            if b1 == 120 || b1 == 88 {
                base = 16;
                i = 2;
            } else if b1 == 98 || b1 == 66 {
                base = 2;
                i = 2;
            } else if b1 == 111 || b1 == 79 {
                base = 8;
                i = 2;
            }
        }
        let mut v: u64 = 0;
        let mut any = false;
        while i < n {
            let ch = s.byte_at(i);
            if ch == 95 {
                i += 1;
                continue;
            }
            let mut d: i64 = -1;
            if base == 16 {
                d = hex_digit(ch);
            } else if ch >= 48 && ch as u64 < 48 + base {
                d = ch - 48;
            }
            if d < 0 {
                break; // suffix
            }
            v = v * base + d as u64;
            any = true;
            i += 1;
        }
        if !any {
            return false;
        }
        // the tail must be a width suffix (identifier characters only): anything else means the
        // span is a synthesized diagnostic span, not this constant's spelling -- trust `val`
        while i < n {
            let ch2 = s.byte_at(i);
            let idc = ch2 == 95 || ch2 >= 48 && ch2 <= 57 || ch2 >= 97 && ch2 <= 122 || ch2 >= 65 && ch2 <= 90;
            if !idc {
                *out = c.val;
                return true;
            }
            i += 1;
        }
        *out = v as i64;
        return true;
    }

    fn rvalue(self: &mut Self, b: &ir::CoreBody, env: u32, rid: ir::RvalueId) IVal {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            return self.operand(b, env, rv.a);
        }
        if rv.kind == ir::RV_BINARY {
            let l = self.operand(b, env, rv.a);
            let r = self.operand(b, env, rv.b);
            if self.failed {
                return none();
            }
            return self.binary(l, r, rv.c, b.module, rv.target);
        }
        if rv.kind == ir::RV_UNARY {
            let v = self.operand(b, env, rv.a);
            if self.failed {
                return none();
            }
            return self.unary(v, rv.b as u8, b.module, rv.target);
        }
        if rv.kind == ir::RV_CAST {
            if rv.b == ir::CAST_NEVER {
                return self.bail();
            }
            let v = self.operand(b, env, rv.a);
            if self.failed {
                return none();
            }
            if rv.b == ir::CAST_POINTER {
                return self.cast_pointer(v, b.module, rv.target);
            }
            if rv.b == ir::CAST_ARRAY_SLICE {
                // an array coerces to a view over its own storage
                let mut av = v;
                let mut peel2 = 0;
                while av.kind == IV_PTR && peel2 < 2 {
                    let mut lv2 = none();
                    if !self.loadp(av, &mut lv2) {
                        return none();
                    }
                    av = lv2;
                    peel2 += 1;
                }
                if av.kind != IV_OBJ {
                    return self.bail();
                }
                let ap2 = self.obj_ptr(av.i as u32);
                if ap2 == null {
                    return self.bail();
                }
                let alen = (unsafe ap2.slots.len()) as i64;
                let sv = self.slice_view(b.module, rv.target, av.i as u32, 0, alen);
                if sv.kind != IV_OBJ {
                    return self.bail();
                }
                return sv;
            }
            if rv.b != ir::CAST_NUMERIC {
                return self.bail(); // coerce-from conversions never fold here
            }
            return self.cast(v, b.module, rv.target);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
            let mut obj: u32 = 0;
            let mut slot: u32 = 0;
            if !self.resolve_place(b, env, rv.a, &mut obj, &mut slot) {
                return none();
            }
            return iv_ptr(b.module, rv.target, obj, slot);
        }
        if rv.kind == ir::RV_AGGREGATE {
            return self.aggregate(b, env, &rv);
        }
        if rv.kind == ir::RV_REPEAT {
            let ev = self.operand(b, env, rv.a);
            if self.failed {
                return none();
            }
            let id = self.obj_new(rv.b);
            if id == 0 {
                return none();
            }
            for i in 0..rv.b {
                let cloned = self.obj_clone(ev, 0);
                if ev.kind != IV_NONE && cloned.kind == IV_NONE {
                    return none();
                }
                unsafe self.obj_ptr(id).slots.set(i as usize, cloned);
            }
            return IVal { kind: IV_OBJ, tm: b.module, ty: rv.target, i: id, f: 0.0 };
        }
        if rv.kind == ir::RV_CLOSURE {
            let id = self.obj_new(rv.b);
            if id == 0 {
                return none();
            }
            unsafe self.obj_ptr(id).clos = 1;
            unsafe self.obj_ptr(id).dm = rv.item.module;
            unsafe self.obj_ptr(id).dn = rv.item.node;
            for i in 0..rv.b {
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    return self.bail();
                }
                let v = self.operand(b, env, opid);
                if self.failed {
                    return none();
                }
                let cv = self.obj_clone(v, 0);
                if v.kind != IV_NONE && cv.kind == IV_NONE {
                    return none();
                }
                unsafe self.obj_ptr(id).slots.set(i as usize, cv);
            }
            return IVal { kind: IV_OBJ, tm: b.module, ty: rv.target, i: id, f: 0.0 };
        }
        if rv.kind == ir::RV_LEN {
            let mut v = self.read_place(b, env, rv.a);
            let mut peel = 0;
            while v.kind == IV_PTR && peel < 3 {
                let mut lv = none();
                if !self.loadp(v, &mut lv) {
                    return none();
                }
                v = lv;
                peel += 1;
            }
            if v.kind == IV_STR {
                v = self.str_materialize(v.tm, v);
                if self.failed || v.kind != IV_OBJ {
                    self.failed = true;
                    return none();
                }
            }
            if v.kind == IV_OBJ {
                let op = self.obj_ptr(v.i as u32);
                if op == null {
                    return self.bail();
                }
                // a length-carrying view struct answers its logical `len` field, not its slot count
                if unsafe op.dn != NODE_NONE {
                    let pi = self.ti_findf(unsafe op.dm, unsafe op.dn, "ptr");
                    let li = self.ti_findf(unsafe op.dm, unsafe op.dn, "len");
                    if pi >= 0 && li >= 0 {
                        let lv2 = unsafe op.slots[li as usize];
                        if lv2.kind != IV_INT {
                            return self.bail();
                        }
                        return iv_int(b.module, rv.target, lv2.i);
                    }
                }
                let mut n = (unsafe op.slots.len()) as i64;
                if unsafe op.is_enum != 0 {
                    n -= 1;
                }
                return iv_int(b.module, rv.target, n);
            }
            return self.bail();
        }
        if rv.kind == ir::RV_SLICE {
            // base[lo..hi]: a view over the container's storage. The container is an array
            // object or an existing view (str/slice struct with ptr+len).
            let mut cv2 = self.read_place(b, env, rv.a);
            if cv2.kind == IV_STR {
                cv2 = self.str_materialize(cv2.tm, cv2);
                if self.failed || cv2.kind != IV_OBJ {
                    self.failed = true;
                    return none();
                }
            }
            if cv2.kind != IV_OBJ {
                return self.bail();
            }
            let cid = cv2.i as u32;
            let cp2 = self.obj_ptr(cid);
            if cp2 == null {
                return self.bail();
            }
            // storage + total length: a view struct redirects to its ptr block
            let mut sobj = cid;
            let mut soff: u32 = 0;
            let mut total = (unsafe cp2.slots.len()) as i64;
            if unsafe cp2.dn != NODE_NONE {
                let pi2 = self.ti_findf(unsafe cp2.dm, unsafe cp2.dn, "ptr");
                let li2 = self.ti_findf(unsafe cp2.dm, unsafe cp2.dn, "len");
                if pi2 >= 0 && li2 >= 0 {
                    let pv2 = unsafe cp2.slots[pi2 as usize];
                    let lv3 = unsafe cp2.slots[li2 as usize];
                    if pv2.kind != IV_PTR || lv3.kind != IV_INT {
                        return self.bail();
                    }
                    sobj = pv_obj(pv2);
                    soff = pv_off(pv2);
                    total = lv3.i;
                }
            }
            let mut lo: i64 = 0;
            if rv.b != ir::IR_NONE {
                let lov = self.operand(b, env, rv.b);
                if lov.kind != IV_INT {
                    return self.bail();
                }
                lo = lov.i;
            }
            let mut hi = total;
            if rv.item.node != NODE_NONE {
                let hv2 = self.operand(b, env, rv.item.node);
                if hv2.kind != IV_INT {
                    return self.bail();
                }
                hi = hv2.i;
            }
            if (rv.c & 1) != 0 {
                hi += 1; // inclusive end
            }
            if lo < 0 || hi < lo || hi > total {
                self.it_trap(IT_TRAP_UB_OOB, "out-of-bounds access");
                return none();
            }
            let sv = self.slice_view(b.module, rv.target, sobj, soff + lo as u32, hi - lo);
            if sv.kind != IV_OBJ {
                return self.bail();
            }
            return sv;
        }
        if rv.kind == ir::RV_DISCRIMINANT {
            let mut v = self.read_place(b, env, rv.a);
            // the discriminant reads through references implicitly (the emitter derefs by type)
            let mut peel = 0;
            while v.kind == IV_PTR && peel < 3 {
                let mut lv = none();
                if !self.loadp(v, &mut lv) {
                    return none();
                }
                v = lv;
                peel += 1;
            }
            if v.kind == IV_INT {
                return iv_int(b.module, rv.target, v.i);
            }
            if v.kind != IV_OBJ {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: discr place kind={} failed={}\n", v.kind, self.failed);
                }
                return self.bail();
            }
            let op = self.obj_ptr(v.i as u32);
            if op == null || unsafe op.is_enum == 0 {
                return self.bail();
            }
            let tag = unsafe op.slots[0];
            return iv_int(b.module, rv.target, tag.i);
        }
        if rv.kind == ir::RV_INTRINSIC {
            if rv.c == ir::IN_SAFEPOINT {
                // a runtime preemption marker: nothing to evaluate
                return IVal { kind: IV_UNIT, tm: b.module, ty: rv.target, i: 0, f: 0.0 };
            }
            if rv.c == ir::IN_BOUNDS || rv.c == ir::IN_BOUNDS_PROVEN {
                // PROVEN keeps the identical check here: CTFE catches a false proof as a trap
                let iv = self.operand(b, env, b.oper_pool[rv.a as usize]);
                let lv = self.operand(b, env, b.oper_pool[(rv.a + 1) as usize]);
                if iv.kind != IV_INT || lv.kind != IV_INT {
                    return self.bail();
                }
                if iv.i as u64 >= lv.i as u64 {
                    self.it_trap(IT_TRAP_UB_OOB, "index out of bounds");
                    return none();
                }
                return iv_int(b.module, rv.target, iv.i);
            }
            if rv.c == ir::IN_BOUNDS_GROUP {
                let iv = self.operand(b, env, b.oper_pool[rv.a as usize]);
                let lv = self.operand(b, env, b.oper_pool[(rv.a + 1) as usize]);
                let wv = self.operand(b, env, b.oper_pool[(rv.a + 2) as usize]);
                if iv.kind != IV_INT || lv.kind != IV_INT || wv.kind != IV_INT {
                    return self.bail();
                }
                if iv.i as u64 > lv.i as u64 || wv.i as u64 > lv.i as u64 - iv.i as u64 {
                    self.it_trap(IT_TRAP_UB_OOB, "index out of bounds");
                    return none();
                }
                return iv_int(b.module, rv.target, iv.i);
            }
            if rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS_PROVEN {
                let sv = self.operand(b, env, b.oper_pool[rv.a as usize]);
                let ev = self.operand(b, env, b.oper_pool[(rv.a + 1) as usize]);
                let nv = self.operand(b, env, b.oper_pool[(rv.a + 2) as usize]);
                if sv.kind != IV_INT || ev.kind != IV_INT || nv.kind != IV_INT {
                    return self.bail();
                }
                if sv.i as u64 > ev.i as u64 || ev.i as u64 > nv.i as u64 {
                    self.it_trap(IT_TRAP_UB_OOB, "range out of bounds");
                    return none();
                }
                return iv_int(b.module, rv.target, ev.i);
            }
            if rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF {
                let mut lm: ModuleId = 0;
                let mut lt = TYPE_NONE;
                if !self.rty(b.module, rv.b, &mut lm, &mut lt) {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint(
                            "iri: sizeof rty failed m={} t={} subs={} base={}\n",
                            b.module,
                            rv.b,
                            self.subst.len(),
                            self.sub_base,
                        );
                    }
                    return self.bail();
                }
                let l = self.lsvc.layout(lm, lt);
                if !l.ok {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: sizeof layout failed m={} t={}\n", lm, lt);
                    }
                    return self.bail();
                }
                let mut v = l.size;
                if rv.c == ir::IN_ALIGNOF {
                    v = l.align;
                }
                return iv_int(b.module, rv.target, v as i64);
            }
            if rv.c == ir::IN_ZEROED {
                // the zeroed type IS the result type
                let mut zm: ModuleId = 0;
                let mut zt = TYPE_NONE;
                if !self.rty(b.module, rv.target, &mut zm, &mut zt) {
                    return self.bail();
                }
                let z = self.zero_of(zm, zt, 0);
                if z.kind == IV_NONE {
                    return self.bail();
                }
                let mut out = z;
                out.tm = b.module;
                out.ty = rv.target;
                return out;
            }
            if rv.c == ir::IN_TYPE_INFO {
                // rv.b = T; the result type names the TypeInfo decl
                let mut tm2: ModuleId = 0;
                let mut tt2 = TYPE_NONE;
                if !self.rty(b.module, rv.b, &mut tm2, &mut tt2) {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: ti rty failed m={} b={}\n", b.module, rv.b);
                    }
                    return self.bail();
                }
                if rv.target == TYPE_NONE {
                    return self.bail();
                }
                let yt = *(unsafe &*self.p().module_ast_const(b.module)).type_at(rv.target);
                if yt.kind != TypeKind::TYPE_STRUCT {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: ti target kind={} m={} t={}\n", yt.kind as u32, b.module, rv.target);
                    }
                    return self.bail();
                }
                let v = self.type_info_decl(b.module, yt.module, yt.as_data.decl, rv.target, tm2, tt2);
                if v.kind != IV_OBJ {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: ti decl build failed\n");
                    }
                    return self.bail();
                }
                return v;
            }
            if rv.c == ir::IN_NEW {
                return self.bail(); // Box construction does not fold yet
            }
            return self.bail();
        }
        return self.bail();
    }

    fn aggregate(self: &mut Self, b: &ir::CoreBody, env: u32, rv: &ir::Rvalue) IVal {
        let mut is_enum = false;
        let mut tagv: i64 = -1;
        if rv.c == ir::AGG_VARIANT {
            if !self.variant_value(rv.item, &mut tagv) {
                return self.bail();
            }
            if rv.b == 0 {
                // a payload-less variant IS its integer value (a bare C enum)
                return iv_int(b.module, rv.target, tagv);
            }
            is_enum = true;
        }
        // decl identity (and the user-free screen) ride the object for structs and enums
        let mut dm: ModuleId = 0;
        let mut dn = NODE_NONE;
        let mut nargs: u8 = 0;
        let mut am: [ModuleId; 4] = [0, 0, 0, 0];
        let mut at: [TypeId; 4] = [TYPE_NONE, TYPE_NONE, TYPE_NONE, TYPE_NONE];
        if rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE {
            let mut am0: ModuleId = b.module;
            let mut at0 = rv.target;
            if rv.target != TYPE_NONE && !self.rty(b.module, rv.target, &mut am0, &mut at0) {
                am0 = b.module;
                at0 = rv.target;
            }
            let a = unsafe &*self.p().module_ast_const(am0);
            if at0 != TYPE_NONE {
                let y = *a.type_at(at0);
                if y.kind == TypeKind::TYPE_STRUCT {
                    dm = y.module;
                    dn = y.as_data.decl;
                } else if y.kind == TypeKind::TYPE_INSTANCE {
                    let it2 = *a.instance(y.as_data.inst);
                    dm = it2.module;
                    dn = it2.decl;
                    nargs = it2.n;
                    if nargs > 4 {
                        nargs = 4;
                    }
                    for gi in 0..nargs {
                        // instance args resolve through the window: a generic frame's literal
                        // spells its instance with the frame's own parameters
                        let mut gm2: ModuleId = 0;
                        let mut gt2 = TYPE_NONE;
                        if self.rty(am0, unsafe it2.args[gi as usize], &mut gm2, &mut gt2) {
                            unsafe am[gi as usize] = gm2;
                            unsafe at[gi as usize] = gt2;
                        } else {
                            unsafe am[gi as usize] = am0;
                            unsafe at[gi as usize] = unsafe it2.args[gi as usize];
                        }
                    }
                }
            }
            if dn == NODE_NONE && rv.item.node != NODE_NONE {
                dm = rv.item.module;
                dn = rv.item.node;
            }
        } else if rv.c == ir::AGG_VARIANT {
            // the owning enum decl
            let da = unsafe &*self.p().module_ast_const(rv.item.module);
            let mut en = NODE_NONE;
            let items = da.at_const(da.root).as_data.program.items;
            for i in 0..items.len {
                let nid = unsafe da.list(items)[i as usize];
                if da.at_const(nid).kind != NodeKind::NODE_ENUM {
                    continue;
                }
                let ms = da.at_const(nid).as_data.aggregate.members;
                for k in 0..ms.len {
                    if unsafe da.list(ms)[k as usize] == rv.item.node {
                        en = nid;
                    }
                }
            }
            dm = rv.item.module;
            dn = en;
        }
        if dn != NODE_NONE && self.user_free(dm, dn) {
            return self.bail(); // a user-free type never folds
        }
        let mut nslots = rv.b;
        if is_enum {
            nslots += 1;
        }
        let id = self.obj_new(nslots);
        if id == 0 {
            return none();
        }
        unsafe self.obj_ptr(id).dm = dm;
        unsafe self.obj_ptr(id).dn = dn;
        unsafe self.obj_ptr(id).nargs = nargs;
        for gi in 0..nargs {
            unsafe self.obj_ptr(id).am[gi as usize] = unsafe am[gi as usize];
            unsafe self.obj_ptr(id).at[gi as usize] = unsafe at[gi as usize];
        }
        if dn != NODE_NONE && self.is_union_decl(dm, dn) {
            unsafe self.obj_ptr(id).uactive = -1;
        }
        let is_union2 = dn != NODE_NONE && self.is_union_decl(dm, dn);
        let mut si: usize = 0;
        if is_enum {
            unsafe self.obj_ptr(id).is_enum = 1;
            unsafe self.obj_ptr(id).slots.set(0, iv_int(0, TYPE_NONE, tagv));
            si = 1;
        }
        let base2 = si;
        for i in 0..rv.b {
            let opid = b.oper_pool[(rv.a + i) as usize];
            if opid == ir::IR_NONE {
                // an omitted member zero-fills (C initializer semantics); a union's inactive
                // members stay empty, an unresolvable field type stays empty (reads bail)
                if !is_union2 && dn != NODE_NONE && !is_enum {
                    let z = self.zero_field(dm, dn, nargs, &am[0], &at[0], i);
                    self.failed = false;
                    if z.kind != IV_NONE {
                        unsafe self.obj_ptr(id).slots.set(si, z);
                    }
                }
                si += 1;
                continue;
            }
            let v = self.operand(b, env, opid);
            if self.failed {
                return none();
            }
            let mut cv = self.obj_clone(v, 0);
            if v.kind != IV_NONE && cv.kind == IV_NONE {
                return none();
            }
            // a short designated array literal grows to the FIELD's extent (C zero-fills there)
            if cv.kind == IV_OBJ && !is_union2 && dn != NODE_NONE && !is_enum {
                let mut fm3: ModuleId = 0;
                let mut ft3 = TYPE_NONE;
                if self.agg_field_type(dm, dn, nargs, &am[0], &at[0], i, &mut fm3, &mut ft3) {
                    cv = self.maybe_slice_wrap(fm3, ft3, cv);
                }
                self.failed = false;
            }
            unsafe self.obj_ptr(id).slots.set(si, cv);
            if is_union2 {
                unsafe self.obj_ptr(id).uactive = (si - base2) as i32;
            }
            si += 1;
        }
        return IVal { kind: IV_OBJ, tm: b.module, ty: rv.target, i: id, f: 0.0 };
    }

    // The zero value of field `ord` of decl (dm, dn) under instance args: resolves the field
    // type through the args, and a symbolic `[T; N]` (interned len 0) recovers its length from
    // the field's TYPE NODE evaluated under the decl's own parameter bindings.
    fn zero_field(
        self: &mut Self,
        dm: ModuleId,
        dn: NodeId,
        nargs: u8,
        am: *const ModuleId,
        at: *const TypeId,
        ord: u32,
    ) IVal {
        let mut fm: ModuleId = 0;
        let mut ft = TYPE_NONE;
        if !self.agg_field_type(dm, dn, nargs, am, at, ord, &mut fm, &mut ft) {
            return none();
        }
        let da = unsafe &*self.p().module_ast_const(fm);
        if ft as usize < da.type_pool.len() {
            let y = *da.type_at(ft);
            if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len == 0 {
                // recover the symbolic length: find the field's type node and evaluate its
                // length expression with the decl's parameters temporarily bound
                let a0 = unsafe &*self.p().module_ast_const(dm);
                let agg = a0.at_const(dn).as_data.aggregate;
                let gens = agg.generics;
                let ms = agg.members;
                let is_tuple = agg.is_tuple;
                let mut oi: u32 = 0;
                let mut ftn = NODE_NONE;
                for i in 0..ms.len {
                    let fid = unsafe a0.list(ms)[i as usize];
                    if !is_tuple && a0.at_const(fid).kind != NodeKind::NODE_FIELD {
                        continue;
                    }
                    if oi == ord {
                        ftn = if is_tuple {
                            fid;
                        } else {
                            a0.at_const(fid).as_data.field.ty;
                        };
                        break;
                    }
                    oi += 1;
                }
                if ftn == NODE_NONE || a0.at_const(ftn).kind != NodeKind::NODE_ARRAY_TYPE {
                    return none();
                }
                let lnode = a0.at_const(ftn).as_data.array_type.length;
                if lnode == NODE_NONE {
                    return none();
                }
                // the length is a literal or a direct reference to one of the decl's const
                // parameters; anything else stays unfoldable (no eval: the facade memo is
                // per-node and would poison the length across instances)
                let mut nlen: i64 = 0;
                let ld = a0.resolution_def(lnode);
                if ld.node != NODE_NONE && ld.module == dm {
                    let mut gi: u32 = 0;
                    while gi < gens.len && gi < nargs as u32 {
                        if unsafe a0.list(gens)[gi as usize] == ld.node {
                            let ya = unsafe &*self.p().module_ast_const(unsafe am[gi as usize]);
                            let yat = unsafe at[gi as usize];
                            if yat as usize < ya.type_pool.len() && ya.type_at(yat).kind == TypeKind::TYPE_CONST {
                                nlen = ya.type_at(yat).as_data.value;
                            }
                            break;
                        }
                        gi += 1;
                    }
                }
                if nlen <= 0 {
                    return none();
                }
                let lv = iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), nlen);
                let mut em2: ModuleId = fm;
                let mut et2 = y.as_data.arr.elem;
                // the element resolves through the DECL's own parameter list (the frame window
                // binds the extend's params, not the struct's)
                let ey = *da.type_at(et2);
                if ey.kind == TypeKind::TYPE_GENERIC {
                    let mut gi2: u32 = 0;
                    while gi2 < gens.len && gi2 < nargs as u32 {
                        if unsafe a0.list(gens)[gi2 as usize] == ey.as_data.decl {
                            em2 = unsafe am[gi2 as usize];
                            et2 = unsafe at[gi2 as usize];
                            break;
                        }
                        gi2 += 1;
                    }
                } else {
                    let _ = self.rty(fm, et2, &mut em2, &mut et2);
                }
                let id = self.obj_new(lv.i as u32);
                if id == 0 {
                    return none();
                }
                let ez = self.zero_of(em2, et2, 0);
                if ez.kind == IV_NONE {
                    return none();
                }
                for k in 0..lv.i {
                    let cloned = self.obj_clone(ez, 0);
                    unsafe self.obj_ptr(id).slots.set(k as usize, cloned);
                }
                return IVal { kind: IV_OBJ, tm: fm, ty: ft, i: id, f: 0.0 };
            }
        }
        return self.zero_of(fm, ft, 0);
    }

    // The declared type of field ordinal `ord` of (dm, dn), resolved through the instance args.
    fn agg_field_type(
        self: &Self,
        dm: ModuleId,
        dn: NodeId,
        nargs: u8,
        am: *const ModuleId,
        at: *const TypeId,
        ord: u32,
        fm: &mut ModuleId,
        ft: &mut TypeId,
    ) bool {
        let da = unsafe &*self.p().module_ast_const(dm);
        if da.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        let agg = da.at_const(dn).as_data.aggregate;
        let ms = agg.members;
        let is_tuple = agg.is_tuple;
        let gens = agg.generics;
        let mut oi: u32 = 0;
        for i in 0..ms.len {
            let fid = unsafe da.list(ms)[i as usize];
            if !is_tuple && da.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            if oi != ord {
                oi += 1;
                continue;
            }
            let ftn = if is_tuple {
                fid;
            } else {
                da.at_const(fid).as_data.field.ty;
            };
            let t0 = self.tof(dm, da, ftn);
            if t0 == TYPE_NONE {
                return false;
            }
            let y = *da.type_at(t0);
            if y.kind == TypeKind::TYPE_GENERIC && nargs != 0 {
                let mut gi: u32 = 0;
                while gi < gens.len && gi < nargs as u32 {
                    if unsafe da.list(gens)[gi as usize] == y.as_data.decl {
                        *fm = unsafe am[gi as usize];
                        *ft = unsafe at[gi as usize];
                        return true;
                    }
                    gi += 1;
                }
                return false;
            }
            *fm = dm;
            *ft = t0;
            return true;
        }
        return false;
    }

    // The integer value of enum variant `vd`: explicit literal discriminants set the counter, the
    // rest follow C rules (previous + 1); payload enums tag by declaration ordinal.
    fn variant_value(self: &mut Self, vd: DefId, out: &mut i64) bool {
        if vd.node == NODE_NONE {
            return false;
        }
        let ap = self.p().module_ast_const(vd.module);
        let a = unsafe &*ap;
        // owning enum: scan items containing this variant via the variant's enclosing decl walk
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            if a.at_const(nid).kind != NodeKind::NODE_ENUM {
                continue;
            }
            let ms = a.at_const(nid).as_data.aggregate.members;
            let mut has_pay = false;
            for k in 0..ms.len {
                let mid = unsafe a.list(ms)[k as usize];
                if a.at_const(mid).kind == NodeKind::NODE_VARIANT && a.at_const(mid).as_data.variant.payload.len != 0 {
                    has_pay = true;
                }
            }
            let mut cur: i64 = 0;
            let mut ord: i64 = 0;
            let mut found = false;
            for k in 0..ms.len {
                let mid = unsafe a.list(ms)[k as usize];
                if a.at_const(mid).kind != NodeKind::NODE_VARIANT {
                    continue;
                }
                let vexpr = a.at_const(mid).as_data.variant.value;
                if vexpr != NODE_NONE && !has_pay {
                    let vn = a.at_const(vexpr);
                    if vn.kind != NodeKind::NODE_LITERAL {
                        return false;
                    }
                    let c = ir::Constant {
                        kind: ir::CK_INT,
                        ty: TYPE_NONE,
                        val: 0,
                        raw: vn.as_data.literal.raw,
                        item: DefId { module: 0, node: NODE_NONE },
                        targ_start: 0,
                        targ_len: 0,
                    };
                    let mut v: i64 = 0;
                    if !self.lit_value(vd.module, &c, &mut v) {
                        return false;
                    }
                    cur = v;
                }
                if mid == vd.node {
                    // the C tag: declaration ordinal for payload enums, the running constant for
                    // bare ones
                    if has_pay {
                        *out = ord;
                    } else {
                        *out = cur;
                    }
                    found = true;
                }
                cur += 1;
                ord += 1;
            }
            if found {
                return true;
            }
        }
        return false;
    }

    // ---- arithmetic (pinned semantics) ------------------------------------------------------------

    fn binary(self: &mut Self, l: IVal, r: IVal, tok2: u8, m: ModuleId, target: TypeId) IVal {
        if l.kind == IV_INT && r.kind == IV_INT {
            // unresolved operand/result types degrade exactly like the established evaluator:
            // BT_COUNT means 64-bit signed arithmetic with no narrowing check
            let mut ob = BuiltinType::BT_COUNT;
            let _ = self.bt_of(l.tm, l.ty, &mut ob);
            let mut rb = BuiltinType::BT_COUNT;
            let _ = self.bt_of(m, target, &mut rb);
            return self.int_op(l.i, r.i, tok2, ob, rb, m, target);
        }
        if l.kind == IV_BOOL && r.kind == IV_BOOL {
            return self.bool_op(l.i != 0, r.i != 0, tok2, m, target);
        }
        if l.kind == IV_FLOAT && r.kind == IV_FLOAT {
            let mut tb = BuiltinType::BT_F64;
            let _ = self.bt_of(l.tm, l.ty, &mut tb);
            return self.float_op(l.f, r.f, tok2, tb, m, target);
        }
        if l.kind == IV_PTR && r.kind == IV_PTR {
            let t = tok2 as TokenType;
            if t == TokenType::EqualEqual {
                return iv_bool(m, target, l.i == r.i);
            }
            if t == TokenType::BangEqual {
                return iv_bool(m, target, l.i != r.i);
            }
            return self.bail();
        }
        let teq0 = tok2 as TokenType;
        if (teq0 == TokenType::EqualEqual || teq0 == TokenType::BangEqual) && (l.kind == IV_PTR && r.kind == IV_INT && r.i == 0 || l.kind == IV_INT && l.i == 0 && r.kind == IV_PTR) {
            // a null-literal comparison: the abstract null is object id 0
            let pv = if l.kind == IV_PTR {
                l;
            } else {
                r;
            };
            let isnull = pv.i == 0;
            let t = tok2 as TokenType;
            if t == TokenType::EqualEqual {
                return iv_bool(m, target, isnull);
            }
            if t == TokenType::BangEqual {
                return iv_bool(m, target, !isnull);
            }
            return self.bail();
        }
        if l.kind == IV_PTR && r.kind == IV_INT {
            // pointer arithmetic moves the slot offset
            let t = tok2 as TokenType;
            let mut d = r.i;
            if t == TokenType::Minus {
                d = 0 - d;
            } else if t != TokenType::Plus {
                return self.bail();
            }
            let no = pv_off(l) as i64 + d;
            if no < 0 || no > 0xFFFFFFFF {
                return self.bail();
            }
            return iv_ptr(m, target, pv_obj(l), no as u32);
        }
        // `str` equality is a native operator (the emitter compares bytes; so does the engine)
        if (teq0 == TokenType::EqualEqual || teq0 == TokenType::BangEqual) && (l.kind == IV_STR || r.kind == IV_STR || l.kind == IV_OBJ && r.kind == IV_OBJ) {
            let mut lb = Vector::<u8>::new();
            let mut rb2 = Vector::<u8>::new();
            let okl = self.str_bytes(l, &mut lb);
            let okr = okl && self.str_bytes(r, &mut rb2);
            if okl && okr {
                let mut eq = lb.len() == rb2.len();
                if eq {
                    for i in 0..lb.len() {
                        if lb[i] != rb2[i] {
                            eq = false;
                            break;
                        }
                    }
                }
                lb.free();
                rb2.free();
                if teq0 == TokenType::BangEqual {
                    eq = !eq;
                }
                return iv_bool(m, target, eq);
            }
            lb.free();
            rb2.free();
        }
        if stdlib::getenv("SC_IRI_DBG") != null {
            eprint("iri: binary refused lk={} rk={} tok={}\n", l.kind, r.kind, tok2);
        }
        return self.bail();
    }

    const fn float_op(self: &mut Self, a: f64, c: f64, tok2: u32, tb: BuiltinType, m: ModuleId, target: TypeId) IVal {
        let t = (tok2 as u8) as TokenType;
        if t == TokenType::EqualEqual {
            return iv_bool(m, target, a == c);
        }
        if t == TokenType::BangEqual {
            return iv_bool(m, target, a != c);
        }
        if t == TokenType::LessThan {
            return iv_bool(m, target, a < c);
        }
        if t == TokenType::LessThanEqual {
            return iv_bool(m, target, a <= c);
        }
        if t == TokenType::GreaterThan {
            return iv_bool(m, target, a > c);
        }
        if t == TokenType::GreaterThanEqual {
            return iv_bool(m, target, a >= c);
        }
        let mut v: f64 = 0.0;
        if t == TokenType::Plus {
            v = a + c;
        } else if t == TokenType::Minus {
            v = a - c;
        } else if t == TokenType::Star {
            v = a * c;
        } else if t == TokenType::Slash {
            v = a / c;
        } else {
            return self.bail();
        }
        if tb == BuiltinType::BT_F32 {
            v = v as f32;
        }
        return iv_float(m, target, v);
    }

    const fn bool_op(self: &mut Self, a: bool, c: bool, tok2: u32, m: ModuleId, target: TypeId) IVal {
        let t = (tok2 as u8) as TokenType;
        if t == TokenType::AmpersandAmpersand || t == TokenType::Ampersand {
            return iv_bool(m, target, a && c);
        }
        if t == TokenType::PipePipe || t == TokenType::Pipe {
            return iv_bool(m, target, a || c);
        }
        if t == TokenType::EqualEqual {
            return iv_bool(m, target, a == c);
        }
        if t == TokenType::BangEqual {
            return iv_bool(m, target, a != c);
        }
        return self.bail();
    }

    fn int_op(self: &mut Self, a: i64, c: i64, tok2: u32, ob: BuiltinType, rb: BuiltinType, m: ModuleId, target: TypeId) IVal {
        let t = (tok2 as u8) as TokenType;
        let uns = ob != BuiltinType::BT_COUNT && bt_unsigned(ob);
        let mut bits = 64;
        if ob != BuiltinType::BT_COUNT {
            bits = bt_bits(ob);
        }
        if t == TokenType::EqualEqual {
            return iv_bool(m, target, a == c);
        }
        if t == TokenType::BangEqual {
            return iv_bool(m, target, a != c);
        }
        if t == TokenType::LessThan || t == TokenType::LessThanEqual || t == TokenType::GreaterThan || t == TokenType::GreaterThanEqual {
            let mut lt = false;
            let eq = a == c;
            if uns {
                lt = a as u64 < c as u64;
            } else {
                lt = a < c;
            }
            if t == TokenType::LessThan {
                return iv_bool(m, target, lt);
            }
            if t == TokenType::LessThanEqual {
                return iv_bool(m, target, lt || eq);
            }
            if t == TokenType::GreaterThan {
                return iv_bool(m, target, !lt && !eq);
            }
            return iv_bool(m, target, !lt);
        }
        if uns {
            let ul = a as u64;
            let ur = c as u64;
            let mut u: u64 = 0;
            if t == TokenType::Plus {
                u = ul + ur;
            } else if t == TokenType::Minus {
                u = ul - ur;
            } else if t == TokenType::Star {
                u = ul * ur;
            } else if t == TokenType::Slash || t == TokenType::Percent {
                if ur == 0 {
                    self.it_trap(IT_TRAP_UB_DIV_ZERO, "division by zero");
                    return none();
                }
                if t == TokenType::Slash {
                    u = ul / ur;
                } else {
                    u = ul % ur;
                }
            } else if t == TokenType::Ampersand {
                u = ul & ur;
            } else if t == TokenType::Pipe {
                u = ul | ur;
            } else if t == TokenType::Caret {
                u = ul ^ ur;
            } else if t == TokenType::LeftShift || t == TokenType::RightShift {
                if c < 0 || c >= bits as i64 {
                    self.it_trap(IT_TRAP_UB_SHIFT, "shift out of range");
                    return none();
                }
                if t == TokenType::LeftShift {
                    u = ul << c as u64;
                } else {
                    let mask = if bits == 64 {
                        0xFFFFFFFFFFFFFFFFu64;
                    } else {
                        (1u64 << bits as u64) - 1u64;
                    };
                    u = (ul & mask) >> c as u64;
                }
            } else {
                return self.bail();
            }
            return iv_int(m, target, wrap_to(ob, u as i64));
        }
        let mut type_min = I64_MIN;
        if bits != 64 {
            type_min = (0u64 - (1u64 << (bits - 1) as u64)) as i64;
        }
        let mut v: i64 = 0;
        if t == TokenType::Plus || t == TokenType::Minus || t == TokenType::Star {
            let o = if t == TokenType::Plus {
                add_ovf(a, c);
            } else if t == TokenType::Minus {
                sub_ovf(a, c);
            } else {
                mul_ovf(a, c);
            };
            if o.ovf {
                self.it_trap(IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
                return none();
            }
            v = o.v;
        } else if t == TokenType::Slash || t == TokenType::Percent {
            if c == 0 {
                self.it_trap(IT_TRAP_UB_DIV_ZERO, "division by zero");
                return none();
            }
            if c == -1 && a == type_min {
                self.it_trap(IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
                return none();
            }
            if t == TokenType::Slash {
                v = a / c;
            } else {
                v = a % c;
            }
        } else if t == TokenType::Ampersand {
            v = a & c;
        } else if t == TokenType::Pipe {
            v = a | c;
        } else if t == TokenType::Caret {
            v = a ^ c;
        } else if t == TokenType::LeftShift || t == TokenType::RightShift {
            if c < 0 || c >= bits as i64 {
                self.it_trap(IT_TRAP_UB_SHIFT, "shift out of range");
                return none();
            }
            if t == TokenType::LeftShift {
                if ob == BuiltinType::BT_COUNT {
                    v = (a as u64 << c as u64) as i64;
                } else {
                    v = wrap_to(ob, (a as u64 << c as u64) as i64);
                }
            } else {
                v = a >> c;
            }
        } else {
            return self.bail();
        }
        if rb != BuiltinType::BT_COUNT && !fits(rb, v) {
            if bt_signed(rb) {
                self.it_trap(IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
                return none();
            }
            return self.bail();
        }
        return iv_int(m, target, v);
    }

    const fn unary(self: &mut Self, v: IVal, tok2: u8, m: ModuleId, target: TypeId) IVal {
        let t = tok2 as TokenType;
        if t == TokenType::Unsafe || t == TokenType::Move {
            return v; // wrappers: the operand IS the value
        }
        if v.kind == IV_BOOL && t == TokenType::Bang {
            return iv_bool(m, target, v.i == 0);
        }
        if v.kind == IV_FLOAT && t == TokenType::Minus {
            let mut tb = BuiltinType::BT_F64;
            let _ = self.bt_of(v.tm, v.ty, &mut tb);
            let mut r = -v.f;
            if tb == BuiltinType::BT_F32 {
                r = r as f32;
            }
            return iv_float(m, target, r);
        }
        if v.kind != IV_INT {
            return self.bail();
        }
        let mut tb = BuiltinType::BT_COUNT;
        let _ = self.bt_of(m, target, &mut tb);
        if t == TokenType::Minus {
            if v.i == I64_MIN {
                return self.bail();
            }
            let r = -v.i;
            if tb != BuiltinType::BT_COUNT && !fits(tb, r) {
                return self.bail();
            }
            return iv_int(m, target, r);
        }
        if t == TokenType::Tilde {
            let mut bb = tb;
            if bb == BuiltinType::BT_COUNT {
                bb = BuiltinType::BT_I64;
            }
            return iv_int(m, target, wrap_to(bb, ~v.i));
        }
        return self.bail();
    }

    // Pointer-targeted casts keep the abstract pointer; a fresh untyped heap block adopts the
    // element type the cast names.
    fn cast_pointer(self: &mut Self, v: IVal, m: ModuleId, target: TypeId) IVal {
        if v.kind == IV_INT && v.i == 0 {
            return iv_ptr(m, target, 0, 0);
        }
        if v.kind == IV_INT && v.i > 0 && v.i <= 0xFFFFFFFF {
            // a positive address literal folds as a storage-free sentinel (object id 0, the
            // value in the offset): `alignof(T) as *mut T` dangling pointers compare non-null
            // and round-trip nowhere -- a dereference traps like null
            return iv_ptr(m, target, 0, v.i as u32);
        }
        if v.kind != IV_PTR {
            return self.bail();
        }
        let mut out = v;
        out.tm = m;
        out.ty = target;
        if target == TYPE_NONE {
            return out;
        }
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        if !self.rty(m, target, &mut rm, &mut rt) {
            return self.bail();
        }
        let a = unsafe &*self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
            return self.bail();
        }
        let mut em: ModuleId = 0;
        let mut et = TYPE_NONE;
        if !self.rty(rm, y.as_data.elem, &mut em, &mut et) {
            return self.bail();
        }
        let ey = *(unsafe &*self.p().module_ast_const(em)).type_at(et);
        if ey.kind == TypeKind::TYPE_BUILTIN && ey.as_data.builtin == BuiltinType::BT_VOID {
            return out;
        }
        let blk = self.obj_ptr(pv_obj(v));
        if blk == null {
            return out;
        }
        if unsafe blk.heap != 0 && unsafe blk.et == TYPE_NONE && pv_off(v) == 0 {
            let l = self.lsvc.layout(em, et);
            if !l.ok || l.size == 0 {
                return self.bail();
            }
            let bytes = unsafe blk.bytes;
            if bytes % l.size != 0 {
                return self.bail();
            }
            if !self.obj_resize(pv_obj(v), (bytes / l.size) as u32) {
                return none();
            }
            let b2 = self.obj_ptr(pv_obj(v));
            unsafe b2.em = em;
            unsafe b2.et = et;
            unsafe b2.esz = l.size;
            return out;
        }
        if unsafe blk.et != TYPE_NONE && !self.teq(unsafe blk.em, unsafe blk.et, em, et) {
            return self.bail();
        }
        return out;
    }

    // Structural type equality across module pools.
    fn teq(self: &Self, ma: ModuleId, ta: TypeId, mb: ModuleId, tb: TypeId) bool {
        if ta == TYPE_NONE || tb == TYPE_NONE {
            return false;
        }
        let aa = unsafe &*self.p().module_ast_const(ma);
        let ab = unsafe &*self.p().module_ast_const(mb);
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
            return a.qualifier == b.qualifier && self.teq(ma, a.as_data.elem, mb, b.as_data.elem);
        }
        if a.kind == TypeKind::TYPE_ARRAY {
            return a.as_data.arr.len == b.as_data.arr.len && self.teq(ma, a.as_data.arr.elem, mb, b.as_data.arr.elem);
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
                if !self.teq(ma, unsafe ia.args[i as usize], mb, unsafe ib.args[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    fn cast(self: &mut Self, v: IVal, m: ModuleId, target: TypeId) IVal {
        // the target decides the shape: a pointer-typed cast keeps the abstract pointer
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        if self.rty(m, target, &mut rm, &mut rt) {
            let yk = (unsafe &*self.p().module_ast_const(rm)).type_at(rt).kind;
            if yk == TypeKind::TYPE_POINTER || yk == TypeKind::TYPE_REFERENCE {
                return self.cast_pointer(v, m, target);
            }
        }
        let mut tb = BuiltinType::BT_I64;
        if !self.bt_of(m, target, &mut tb) {
            return self.bail();
        }
        if tb == BuiltinType::BT_C32 || tb == BuiltinType::BT_C64 || tb == BuiltinType::BT_BOOL || tb == BuiltinType::BT_VALIST || tb == BuiltinType::BT_VOID {
            return self.bail();
        }
        if tb == BuiltinType::BT_F32 || tb == BuiltinType::BT_F64 {
            let mut fv: f64 = 0.0;
            if v.kind == IV_FLOAT {
                fv = v.f;
            } else if v.kind == IV_INT {
                let mut ob = BuiltinType::BT_I64;
                let _ = self.bt_of(v.tm, v.ty, &mut ob);
                if bt_unsigned(ob) {
                    fv = (v.i as u64) as f64;
                } else {
                    fv = v.i as f64;
                }
            } else {
                return self.bail();
            }
            if tb == BuiltinType::BT_F32 {
                fv = fv as f32;
            }
            return iv_float(m, target, fv);
        }
        if v.kind == IV_FLOAT {
            if !it_isfinite(v.f) {
                return self.bail();
            }
            let t = unsafe math::trunc(v.f);
            if t < -9.3e18 || t > 1.8e19 {
                return self.bail();
            }
            let mut iv2: i64 = t as i64;
            if bt_unsigned(tb) {
                iv2 = (t as u64) as i64;
            }
            if !fits(tb, iv2) && bt_bits(tb) < 64 {
                return self.bail();
            }
            return iv_int(m, target, wrap_to(tb, iv2));
        }
        if v.kind == IV_BOOL || v.kind == IV_INT {
            return iv_int(m, target, wrap_to(tb, v.i));
        }
        return self.bail();
    }

    // The container item of fn `fnode` in module `fm`: 1 = extend, 2 = interface, 0 = top-level.
    fn container_of(self: &mut Self, fm: ModuleId, fnode: NodeId, out: &mut NodeId) i32 {
        let ckey = fm as u64 << 32 | fnode as u64;
        switch self.cont_memo.get(&ckey) {
            Some(v) => {
                *out = (*v & 0xFFFFFFFFu64) as NodeId;
                return (*v >> 32) as i32;
            },
            None => {},
        };
        let a = unsafe &*self.p().module_ast_const(fm);
        let items = a.at_const(a.root).as_data.program.items;
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
                if unsafe a.list(ms)[k as usize] == fnode {
                    *out = iid;
                    let kd = if is_ext {
                        1u64;
                    } else {
                        2 as u64;
                    };
                    self.cont_memo.insert(ckey, kd << 32 | iid as u64);
                    return kd as i32;
                }
            }
        }
        self.cont_memo.insert(ckey, 0);
        return 0;
    }

    // The receiver's OWN method named like (nm, name): the conformer's override wins over an
    // interface default. Search order mirrors the established evaluator: the receiver's module,
    // the calling scope, then (builtin receivers only) every module.
    fn find_method(
        self: &Self,
        rdm: ModuleId,
        rdn: NodeId,
        rb: BuiltinType,
        scope: ModuleId,
        nm: ModuleId,
        name: tok::Span,
    ) DefId {
        let none2 = DefId { module: 0, node: NODE_NONE };
        let nmods = self.p().modules.len();
        let mut first = scope;
        if rdn != NODE_NONE {
            first = rdm;
        }
        for s2 in 0..nmods + 2 {
            let mut mm: ModuleId = 0;
            if s2 == 0 {
                mm = first;
            } else if s2 == 1 {
                mm = scope;
            } else if rdn == NODE_NONE {
                mm = (s2 - 2) as ModuleId;
            } else {
                break;
            }
            if s2 == 1 && mm == first {
                continue;
            }
            let a = unsafe &*self.p().module_ast_const(mm);
            if a.nodes.len() == 0 {
                continue;
            }
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe a.list(items)[i as usize];
                let target = a.at_const(iid).as_data.extend_def.target_type;
                if a.at_const(iid).kind != NodeKind::NODE_EXTEND || target == NODE_NONE {
                    continue;
                }
                let mut match_recv = false;
                if rdn != NODE_NONE {
                    let tg = a.resolution_def(target);
                    match_recv = tg.module == rdm && tg.node == rdn;
                } else {
                    let tt = self.tof(mm, a, target);
                    if tt != TYPE_NONE {
                        let ty = a.type_at(tt);
                        match_recv = ty.kind == TypeKind::TYPE_BUILTIN && ty.as_data.builtin == rb;
                    }
                }
                if !match_recv {
                    continue;
                }
                let ms = a.at_const(iid).as_data.extend_def.items;
                for k in 0..ms.len {
                    let mid = unsafe a.list(ms)[k as usize];
                    if a.at_const(mid).kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let mname = a.at_const(a.at_const(mid).as_data.function.name).as_data.name.text;
                    let asrc = self.src_of(mm);
                    let bsrc = self.src_of(nm);
                    let atxt = asrc.slice(mname.start as usize, mname.end as usize);
                    let btxt = bsrc.slice(name.start as usize, name.end as usize);
                    if atxt == btxt {
                        return DefId { module: mm, node: mid };
                    }
                }
            }
        }
        return none2;
    }

    /// Unchecked index into the captured static groups.
    pub const fn static_at(self: &Self, i: u32) *const StaticObj {
        return unsafe (self.statics.as_ptr() + i as usize);
    }

    @c.cold
    fn cap_fail(self: &mut Self, base: u32, kind: u8, msg: str<'static>) StaticRes {
        self.statics.truncate(base as usize);
        self.it_trap(kind, msg);
        return StaticRes { ok: false, root: 0 };
    }

    /// Serialize the object graph behind `rootv` (an IV_OBJ) into `statics`: pass A discovers
    /// pre-order (children pushed in reverse so pop order equals slot order), pass B shapes each
    /// object, pass C serializes slots and relocations. Object identity is preserved, so shared
    /// and cyclic pointer graphs survive.
    pub fn capture(self: &mut Self, rootv: IVal) StaticRes {
        let bad = StaticRes { ok: false, root: 0 };
        let base = self.statics.len() as u32;
        let nobj = self.objs_live;
        let rid = rootv.i as u32;
        if rootv.kind != IV_OBJ || rid == 0 || rid as usize > nobj {
            return bad;
        }
        // per-object side tables (ids are 1-based)
        let mut map = Vector::<u32>::new(); // statics index + 1; 0 = unvisited
        let mut embp = Vector::<u32>::new(); // embedding parent object id
        let mut embs = Vector::<u32>::new(); // slot in the embedding parent
        let mut hintm = Vector::<ModuleId>::new(); // value-type hint from the referencing IVal
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
                return self.cap_fail(base, IT_TRAP_UNSUPPORTED, "constant value cannot be materialized as static data");
            }
            if unsafe op.dead != 0 {
                return self.cap_fail(base, IT_TRAP_UB_USE_AFTER_FREE, "constant points at freed compile-time memory");
            }
            let sl = (unsafe op.slots.len()) as u32;
            total += sl;
            if total > IT_STATIC_MAX_SLOTS {
                return self.cap_fail(base, IT_TRAP_TOO_LARGE, "constant is too large to materialize as static data");
            }
            map.set(oid as usize, base + order.len() as u32 + 1);
            order.push(oid);
            let mut k = sl;
            while k > 0 {
                k -= 1;
                let mut sv = unsafe self.obj_ptr(oid).slots[k as usize];
                if sv.kind == IV_STR {
                    // a nested string literal materializes into its object form for serialization
                    sv = self.str_materialize(sv.tm, sv);
                    if self.failed || sv.kind != IV_OBJ {
                        return self.cap_fail(
                            base,
                            IT_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    unsafe self.obj_ptr(oid).slots.set(k as usize, sv);
                }
                if sv.kind == IV_OBJ {
                    let c = sv.i as u32;
                    if c == 0 || c as usize > self.objs_live {
                        return self.cap_fail(
                            base,
                            IT_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    if c as usize >= map.len() {
                        // materialization grew the store past the side tables
                        while map.len() <= c as usize {
                            map.push(0);
                            embp.push(0);
                            embs.push(0);
                            hintm.push(0);
                            hintt.push(TYPE_NONE);
                        }
                    }
                    embp.set(c as usize, oid);
                    embs.set(c as usize, k);
                    if sv.ty != TYPE_NONE {
                        hintm.set(c as usize, sv.tm);
                        hintt.set(c as usize, sv.ty);
                    }
                    stack.push(c);
                } else if sv.kind == IV_PTR && pv_obj(sv) != 0 {
                    let c = pv_obj(sv);
                    if c as usize > self.objs_live {
                        return self.cap_fail(
                            base,
                            IT_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    if c as usize >= map.len() {
                        while map.len() <= c as usize {
                            map.push(0);
                            embp.push(0);
                            embs.push(0);
                            hintm.push(0);
                            hintt.push(TYPE_NONE);
                        }
                    }
                    if sv.ty != TYPE_NONE && hintt[c as usize] == TYPE_NONE {
                        let a = unsafe &*self.p().module_ast_const(sv.tm);
                        let y = *a.type_at(sv.ty);
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
                dn: NODE_NONE,
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
                        IT_TRAP_UNSUPPORTED,
                        "constant points at an untyped compile-time heap block",
                    );
                }
            } else if unsafe op.is_enum != 0 {
                g.shape = SS_ENUM;
                g.dm = unsafe op.dm;
                g.dn = unsafe op.dn;
                let ga = unsafe &*self.p().module_ast_const(g.dm);
                let gens = ga.at_const(g.dn).as_data.aggregate.generics.len;
                if standalone && gens != 0 {
                    self.statics.push(g);
                    return self.cap_fail(
                        base,
                        IT_TRAP_UNSUPPORTED,
                        "constant value cannot be materialized as static data",
                    );
                }
            } else if unsafe op.dn != NODE_NONE && unsafe op.clos == 0 {
                g.shape = SS_STRUCT;
                g.uactive = unsafe op.uactive; // a union serializes the one member it holds
                g.dm = unsafe op.dm;
                g.dn = unsafe op.dn;
                g.nargs = unsafe op.nargs;
                for ci in 0..4 {
                    unsafe g.am[ci] = unsafe op.am[ci];
                    unsafe g.at[ci] = unsafe op.at[ci];
                }
                let ga = unsafe &*self.p().module_ast_const(g.dm);
                let gens = ga.at_const(g.dn).as_data.aggregate.generics.len;
                if standalone && gens != 0 && g.nargs == 0 {
                    self.statics.push(g);
                    return self.cap_fail(
                        base,
                        IT_TRAP_UNSUPPORTED,
                        "constant value cannot be materialized as static data",
                    );
                }
            } else if unsafe op.clos == 0 {
                let hm = hintm[oid as usize];
                let ht = hintt[oid as usize];
                let mut isarr = false;
                if ht != TYPE_NONE {
                    let ha = unsafe &*self.p().module_ast_const(hm);
                    let y = *ha.type_at(ht);
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
                            IT_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                    g.shape = SS_CELL;
                    g.etm = hm;
                    g.ety = ht;
                }
            } else {
                self.statics.push(g);
                return self.cap_fail(base, IT_TRAP_UNSUPPORTED, "constant value cannot be materialized as static data");
            }
            self.statics.push(g);
        }
        // ordinals + owners
        let mut nstand: u32 = 0;
        for idx in 0..count {
            let gi = base as usize + idx;
            if self.statics[gi].parent == S_NO_PARENT {
                self.statics[gi].ord = nstand;
                nstand += 1;
            }
        }
        for idx in 0..count {
            let gi = base as usize + idx;
            let mut cur = gi as u32;
            let mut guard: usize = 0;
            while self.statics[cur as usize].parent != S_NO_PARENT && guard <= count {
                cur = self.statics[cur as usize].parent;
                guard += 1;
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
                let mut sk = SSlot { kind: SK_ZERO, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0, child: 0 };
                if uact >= 0 && k as i32 != uact {
                    sslots.push(sk); // an inactive union member holds nothing; never emitted
                    continue;
                }
                if sv.kind == IV_INT || sv.kind == IV_BOOL {
                    sk.kind = SK_INT;
                    if sv.kind == IV_BOOL {
                        sk.kind = SK_BOOL;
                    }
                    sk.tm = sv.tm;
                    sk.ty = sv.ty;
                    sk.i = sv.i;
                } else if sv.kind == IV_FLOAT {
                    if !it_isfinite(sv.f) {
                        return self.cap_fail(base, IT_TRAP_UNSUPPORTED, "constant contains a non-finite float");
                    }
                    sk.kind = SK_FLOAT;
                    sk.tm = sv.tm;
                    sk.ty = sv.ty;
                    sk.f = sv.f;
                } else if sv.kind == IV_NONE || sv.kind == IV_UNIT {
                    if shape == SS_STRUCT || shape == SS_CELL {
                        return self.cap_fail(
                            base,
                            IT_TRAP_UNSUPPORTED,
                            "constant value cannot be materialized as static data",
                        );
                    }
                } else if sv.kind == IV_PTR {
                    if pv_obj(sv) == 0 {
                        sk.kind = SK_NULL;
                    } else {
                        let tgt = map[pv_obj(sv) as usize];
                        if tgt == 0 {
                            return self.cap_fail(
                                base,
                                IT_TRAP_UNSUPPORTED,
                                "constant value cannot be materialized as static data",
                            );
                        }
                        let ti = tgt - 1;
                        let toff = pv_off(sv);
                        let tshape = self.statics[ti as usize].shape;
                        let tlen = (unsafe self.obj_ptr(order[(ti - base) as usize]).slots.len()) as u32;
                        let past_end = toff == tlen && (tshape == SS_HEAP || tshape == SS_ARRAY);
                        if toff > tlen || toff == tlen && !past_end || toff != 0 && (tshape == SS_ENUM || tshape == SS_CELL) {
                            return self.cap_fail(
                                base,
                                IT_TRAP_UNSUPPORTED,
                                "constant value cannot be materialized as static data",
                            );
                        }
                        sk.kind = SK_REL;
                        let mut rk = SREL_INTERIOR;
                        if toff == 0 {
                            rk = SREL_STATIC;
                        }
                        srels.push(SRel { slot: k, kind: rk, target: ti, toff: toff, fm: 0, fnode: NODE_NONE });
                    }
                } else if sv.kind == IV_FN {
                    let fm2 = (sv.i >> 32) as ModuleId;
                    let fnid = (sv.i & 0xFFFFFFFF) as NodeId;
                    let fa = unsafe &*self.p().module_ast_const(fm2);
                    let mut fn_ok = fa.at_const(fnid).kind == NodeKind::NODE_FUNCTION;
                    if fn_ok {
                        let fd = fa.at_const(fnid).as_data.function;
                        fn_ok = fd.generics.len == 0 && (fd.body != NODE_NONE || fd.is_extern);
                    }
                    if !fn_ok {
                        return self.cap_fail(
                            base,
                            IT_TRAP_UNSUPPORTED,
                            "constant contains a function value with no C symbol",
                        );
                    }
                    sk.kind = SK_REL;
                    srels.push(SRel { slot: k, kind: SREL_FN, target: 0, toff: 0, fm: fm2, fnode: fnid });
                } else if sv.kind == IV_OBJ {
                    sk.kind = SK_AGG;
                    sk.child = map[sv.i as usize] - 1;
                } else {
                    return self.cap_fail(
                        base,
                        IT_TRAP_UNSUPPORTED,
                        "constant value cannot be materialized as static data",
                    );
                }
                sslots.push(sk);
            }
            self.statics[gi].slots = sslots;
            self.statics[gi].rels = srels;
        }
        return StaticRes { ok: true, root: base };
    }

    // ---- the expression-fold facade ---------------------------------------------------------------

    /// Always-panics probe for one fn body: interpret it with NO inputs; the span of the top-frame
    /// statement whose execution trapped with UB (or a panic reached through a `const fn` frame),
    /// or an empty span. Statements touching a parameter fail benignly, ending the probe silently.
    /// Generic bodies are skipped: unbound widths would degrade to i64 and fabricate traps.
    pub fn lint_body(self: &mut Self, m: ModuleId, fn_id: NodeId) tok::Span {
        let zero = tok::Span { start: 0, end: 0 };
        if self.in_run != 0 || self.ev_depth != 0 || self.nframes != 0 {
            return zero;
        }
        let a = unsafe &*self.p().module_ast_const(m);
        if a.nodes.len() == 0 || a.at_const(fn_id).kind != NodeKind::NODE_FUNCTION {
            return zero;
        }
        let fd = a.at_const(fn_id).as_data.function;
        if fd.body == NODE_NONE || fd.is_extern || fd.generics.len != 0 {
            return zero;
        }
        {
            let mut cont = NODE_NONE;
            if self.container_of(m, fn_id, &mut cont) != 0 && a.at_const(cont).kind == NodeKind::NODE_EXTEND && a.at_const(
                cont,
            ).as_data.extend_def.generics.len != 0 {
                return zero;
            }
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = IT_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.nframes = 0;
        self.objs_live = 0;
        self.live_slots = 0;
        self.item_active.truncate(0);
        self.failed = false;
        self.subst.truncate(0);
        self.sub_base = 0;
        self.top_span = zero;
        self.trap_span = zero;
        let binds = Vector::<ISub>::new();
        let bidx = self.body_of(m, fn_id, &binds, false);
        if bidx < 0 {
            self.failed = false;
            return zero;
        }
        self.lint_on = true;
        let bp: *const irl::Lowerer = self.bodies.at(bidx as usize).get();
        let args = Vector::<IVal>::new();
        let _ = self.run(unsafe &(&*bp).body, &args);
        self.lint_on = false;
        self.failed = false;
        if (it_trap_is_ub(self.trap_kind) || self.trap_kind == IT_TRAP_PANIC && self.trap_in_constfn) && self.trap_span.end > self.trap_span.start {
            return self.trap_span;
        }
        return zero;
    }

    // ---- effect summary (fx) ----------------------------------------------------------------------
    // Lazy, memoized, per-function CTFE-eligibility verdicts, ported from the established
    // evaluator: FX_NO is kept tight (it must imply the interpreter would fail anyway). The
    // shallow scan covers the body's leading straight-line statements; deep mode recurses into
    // if/match/defer so FX_YES means every path is provably evaluable.

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
        while tbl.len() <= m as usize {
            tbl.push(Vector::<u8>::new());
        }
        let inner = &mut tbl[m as usize];
        while inner.len() <= id as usize {
            inner.push(FX_UNKNOWN);
        }
        inner.set(id as usize, v);
    }

    // Deep mode never records a reason: its NO is any-path (the site may be conditional), so it
    // must not surface as a def-site 'const fn' diagnostic.
    @c.cold
    fn fx_disq(self: &mut Self, m: ModuleId, owner: NodeId, site: NodeId, why: str<'static>, deep: bool) u8 {
        if !deep {
            self.fx_no.push(FxNo { m: m, fn_id: owner, site: site, why: why });
        }
        return FX_NO;
    }

    fn fx_get_in(self: &mut Self, m: ModuleId, fn_id: NodeId, deep: bool) u8 {
        let cur = self.fx_slot(m, fn_id, deep);
        if cur != FX_UNKNOWN {
            return cur;
        }
        if self.fx_depth >= 128 {
            return FX_MAYBE; // not memoized: a cap-dependent verdict must not stick
        }
        self.fx_set(m, fn_id, FX_ONSTACK, deep);
        self.fx_depth += 1;
        let v = self.fx_scan_fn(m, fn_id, deep);
        self.fx_depth -= 1;
        self.fx_set(m, fn_id, v, deep);
        return v;
    }

    /// Re-scan instead of trusting the memo: the def-site `const fn` check runs AFTER the body has
    /// typechecked (type-based disqualifiers are invisible before), and overwrites any blind
    /// memoized verdict so later folds agree with it.
    pub fn fn_recheck(self: &mut Self, m: ModuleId, fn_id: NodeId) u8 {
        self.eng_enter();
        self.root_mod = m; // fx scans of HIGHER modules read them as serial order saw them: unchecked
        let r = self.fn_recheck_g(m, fn_id);
        self.eng_leave();
        return r;
    }

    fn fn_recheck_g(self: &mut Self, m: ModuleId, fn_id: NodeId) u8 {
        self.fx_set(m, fn_id, FX_ONSTACK, false);
        self.fx_depth += 1;
        let v = self.fx_scan_fn(m, fn_id, false);
        self.fx_depth -= 1;
        self.fx_set(m, fn_id, v, false);
        return v;
    }

    /// The const-suggestion lint's surface: deep FX_YES = every path is provably CTFE-evaluable.
    pub fn fn_const_suggest(self: &mut Self, m: ModuleId, fn_id: NodeId) bool {
        return self.fx_get_in(m, fn_id, true) == FX_YES;
    }

    /// The recorded disqualifying site for a shallow FX_NO, or null.
    pub const fn fx_no_reason(self: &Self, m: ModuleId, fn_id: NodeId) *const FxNo {
        for i in 0..self.fx_no.len() {
            let r = self.fx_no.at(i);
            if r.m == m && r.fn_id == fn_id {
                return r;
            }
        }
        return null;
    }

    fn fx_scan_fn(self: &mut Self, m: ModuleId, fn_id: NodeId, deep: bool) u8 {
        let a = unsafe &*self.p().module_ast_const(m);
        if a.nodes.len() == 0 || a.at_const(fn_id).kind != NodeKind::NODE_FUNCTION {
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

    fn fx_scan_stmts(self: &mut Self, m: ModuleId, owner: NodeId, block: NodeId, depth: u32, deep: bool) u8 {
        let a = unsafe &*self.p().module_ast_const(m);
        if depth > 64 || a.at_const(block).kind != NodeKind::NODE_BLOCK {
            return FX_MAYBE;
        }
        let stmts = a.at_const(block).as_data.block.statements;
        let mut acc = FX_YES;
        for i in 0..stmts.len {
            let sid = unsafe a.list(stmts)[i as usize];
            let k = a.at_const(sid).kind;
            let mut st = FX_YES;
            if k == NodeKind::NODE_EXPRESSION_STATEMENT {
                st = self.fx_scan_expr(m, owner, a.at_const(sid).as_data.single.value, depth + 1, deep);
            } else if k == NodeKind::NODE_LET {
                let v = a.at_const(sid).as_data.let_stmt.value;
                if v != NODE_NONE {
                    st = self.fx_scan_expr(m, owner, v, depth + 1, deep);
                }
            } else if k == NodeKind::NODE_RETURN {
                let values = a.at_const(sid).as_data.return_stmt.values;
                if deep && values.len > 8 {
                    return fx_meet(acc, FX_MAYBE); // multi-returns cap at 8
                }
                for j in 0..values.len {
                    st = fx_meet(st, self.fx_scan_expr(m, owner, unsafe a.list(values)[j as usize], depth + 1, deep));
                }
                return fx_meet(acc, st); // nothing executes after a spine return
            } else if k == NodeKind::NODE_BLOCK {
                st = self.fx_scan_stmts(m, owner, sid, depth + 1, deep);
            } else if k == NodeKind::NODE_STATIC_ASSERT {
                continue;
            } else if deep && (k == NodeKind::NODE_IF || k == NodeKind::NODE_MATCH) {
                st = self.fx_scan_expr(m, owner, sid, depth + 1, true);
            } else if k == NodeKind::NODE_ASM {
                return FX_NO; // inline assembly is never compile-time evaluable
            } else if deep && k == NodeKind::NODE_DEFER {
                st = self.fx_scan_body(m, owner, a.at_const(sid).as_data.single.value, depth + 1);
            } else {
                return fx_meet(acc, FX_MAYBE); // control flow: the spine ends here
            }
            acc = fx_meet(acc, st);
            if acc == FX_NO {
                return FX_NO;
            }
        }
        return acc;
    }

    fn fx_scan_body(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32) u8 {
        if id == NODE_NONE {
            return FX_YES;
        }
        if (unsafe &*self.p().module_ast_const(m)).at_const(id).kind == NodeKind::NODE_BLOCK {
            return self.fx_scan_stmts(m, owner, id, depth, true);
        }
        return self.fx_scan_expr(m, owner, id, depth, true);
    }

    fn fx_scan_match(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32) u8 {
        let a = unsafe &*self.p().module_ast_const(m);
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

    // Would pat_match handle this pattern? Literals/range endpoints must be integer-classed.
    fn fx_pat_lit_ok(self: &Self, m: ModuleId, vn: NodeId) bool {
        let a = unsafe &*self.p().module_ast_const(m);
        let mut b = BuiltinType::BT_COUNT;
        let _ = self.bt_of(m, self.tof(m, a, vn), &mut b);
        return b != BuiltinType::BT_COUNT && (bt_signed(b) || bt_unsigned(b) || b == BuiltinType::BT_BOOL);
    }

    fn fx_scan_pat(self: &mut Self, m: ModuleId, pid: NodeId, depth: u32) u8 {
        if depth > 64 {
            return FX_MAYBE;
        }
        let a = unsafe &*self.p().module_ast_const(m);
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
                        if d.node == NODE_NONE || (unsafe &*self.p().module_ast_const(d.module)).at_const(d.node).kind != NodeKind::NODE_VARIANT {
                            return FX_MAYBE;
                        }
                        if n.kind == NodeKind::NODE_PATTERN_STRUCT && !(unsafe &*self.p().module_ast_const(d.module)).at_const(
                            d.node,
                        ).as_data.variant.struct_payload {
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
        let a = unsafe &*self.p().module_ast_const(m);
        if self.ty_no_const(m, self.tof(m, a, id), 0) {
            return self.fx_disq(m, owner, id, "uses a '@no_const' type", deep);
        }
        let n = a.at_const(id);
        switch n.kind {
            NODE_LITERAL | NODE_SIZEOF | NODE_ALIGNOF => {
                return FX_YES;
            },
            NODE_IDENTIFIER => {
                let d = a.resolution_def(id);
                if d.node != NODE_NONE && (unsafe &*self.p().module_ast_const(d.module)).at_const(d.node).kind == NodeKind::NODE_CONST && (unsafe &*self.p().module_ast_const(
                    d.module,
                )).at_const(d.node).as_data.const_def.is_static_mut {
                    return self.fx_disq(m, owner, id, "accesses a 'static mut'", deep);
                }
                return FX_YES;
            },
            NODE_MEMBER => {
                if n.as_data.member.path {
                    let d = a.resolution_def(id);
                    if d.node != NODE_NONE && (unsafe &*self.p().module_ast_const(d.module)).at_const(d.node).kind == NodeKind::NODE_CONST && (unsafe &*self.p().module_ast_const(
                        d.module,
                    )).at_const(d.node).as_data.const_def.is_static_mut {
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
                if vd.node != NODE_NONE && self.has_attr(vd.module, vd.node, AttrKind::ATTR_NO_CONST) {
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
                let st = self.fx_scan_expr(m, owner, n.as_data.pattern_range.start, depth + 1, deep);
                if st == FX_NO {
                    return FX_NO;
                }
                return fx_meet(st, self.fx_scan_expr(m, owner, n.as_data.pattern_range.end, depth + 1, deep));
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

    // Does the intercept model this extern name? Heap/trap names, then libm by (suffix-stripped)
    // name probe.
    fn intercept_name(self: &Self, fm: ModuleId, nm: tok::Span) bool {
        if self.span_is(fm, nm, "malloc") || self.span_is(fm, nm, "realloc") || self.span_is(fm, nm, "free") || self.span_is(
            fm,
            nm,
            "memset",
        ) || self.span_is(fm, nm, "memcpy") || self.span_is(fm, nm, "memcmp") || self.span_is(fm, nm, "abort") || self.span_is(
            fm,
            nm,
            "__sc_panic_str",
        ) || self.span_is(fm, nm, "__sc_panic") {
            return true;
        }
        let ln = (nm.end - nm.start) as usize;
        if ln == 0 || ln >= 24 {
            return false;
        }
        let full = self.src_of(fm).slice(nm.start as usize, nm.end as usize);
        let mut name = full;
        if ln > 1 && full.byte_at(ln - 1) == 102 {
            name = full.slice(0, ln - 1);
        }
        if name == "fma" {
            return true;
        }
        return libm1(name, 0.0).ok || libm2(name, 0.0, 0.0).ok;
    }

    // The declaration position of variant `vd` in its enum (mirrors the payload-enum tag).
    const fn variant_pos(self: &Self, vm: ModuleId, vd: NodeId, enum_out: &mut NodeId) i32 {
        let a = unsafe &*self.p().module_ast_const(vm);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = a.at_const(iid).as_data.aggregate.members;
                for k in 0..ms.len {
                    if unsafe a.list(ms)[k as usize] == vd {
                        *enum_out = iid;
                        return k as i32;
                    }
                }
            }
        }
        *enum_out = NODE_NONE;
        return 0 - 1;
    }

    const fn enum_tagged(self: &Self, dm: ModuleId, dn: NodeId) bool {
        let a = unsafe &*self.p().module_ast_const(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        for i in 0..ms.len {
            if a.at_const(unsafe a.list(ms)[i as usize]).as_data.variant.payload.len > 0 {
                return true;
            }
        }
        return false;
    }

    fn fx_scan_call(self: &mut Self, m: ModuleId, owner: NodeId, id: NodeId, depth: u32, deep: bool) u8 {
        let a = unsafe &*self.p().module_ast_const(m);
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
            acc = FX_MAYBE; // calls cap at 8 slots (receiver + args)
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
        }
        let mut fd = a.resolution_def(callee);
        if fd.node == NODE_NONE && ck == NodeKind::NODE_MEMBER {
            fd = a.resolution_def(a.at_const(callee).as_data.member.member);
        }
        if fd.node == NODE_NONE && ck == NodeKind::NODE_IDENTIFIER {
            fd = DefId { module: m, node: a.resolution(callee) };
        }
        if fd.node == NODE_NONE {
            return FX_MAYBE;
        }
        let fa = unsafe &*self.p().module_ast_const(fd.module);
        let dk = fa.at_const(fd.node).kind;
        if dk == NodeKind::NODE_VARIANT {
            if deep {
                // mirror the payload-constructor gates (untagged/user-Free enums bail)
                let mut ed = NODE_NONE;
                let vp = self.variant_pos(fd.module, fd.node, &mut ed);
                if vp < 0 || !self.enum_tagged(fd.module, ed) || self.user_free(fd.module, ed) {
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
            let nm = fa.at_const(cfd.name).as_data.name.text;
            if self.intercept_name(fd.module, nm) {
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
        if deep {
            let mut cont2 = NODE_NONE;
            if self.container_of(fd.module, fd.node, &mut cont2) == 2 {
                return fx_meet(acc, FX_MAYBE); // interface default body: dispatch may substitute
            }
        }
        let cv = self.fx_get_in(fd.module, fd.node, deep);
        if cv == FX_NO {
            return self.fx_disq(m, owner, id, "calls a function that cannot be evaluated at compile time", deep);
        }
        if cv == FX_ONSTACK {
            if deep {
                return fx_meet(acc, FX_MAYBE); // recursion: budgets make folds input-dependent
            }
            return acc; // gray edge: neutral (recursion is legal)
        }
        return fx_meet(acc, cv);
    }

    pub const fn trap_get(self: &Self) str {
        return self.trap;
    }

    pub const fn trap_kind_get(self: &Self) u8 {
        return self.trap_kind;
    }

    /// The current trap with its call stack and step count: "<msg> (call stack: outer -> ... ->
    /// inner; steps: N/limit)"; a frameless budget trap names the widening flags instead.
    pub fn trap_detail(self: &mut Self) str {
        let mut out = String::new();
        out.push_str(self.trap);
        let nf = self.trap_nframes as u32;
        if nf != 0 {
            out.push_str(" (call stack: ");
            let mut show = nf;
            if show > 8 {
                show = 8;
                out.push_str("... -> ");
            }
            let mut i = nf - show;
            while i < nf {
                if i != nf - show {
                    out.push_str(" -> ");
                }
                let fv = unsafe self.trap_stack[i as usize];
                let a = unsafe &*self.p().module_ast_const(fv.module);
                if a.at_const(fv.node).kind == NodeKind::NODE_FUNCTION {
                    let nm = a.at_const(a.at_const(fv.node).as_data.function.name).as_data.name.text;
                    let src = self.src_of(fv.module);
                    out.push_str(src.slice(nm.start as usize, nm.end as usize));
                } else {
                    out.push_str("<closure>");
                }
                i += 1;
            }
            out.push_str("; steps: ");
            out.push_u64(self.trap_steps);
            out.push_str("/");
            out.push_u64(self.max_steps);
            out.push_str(")");
        } else if self.trap_kind == IT_TRAP_BUDGET_STEPS || self.trap_kind == IT_TRAP_BUDGET_MEMORY {
            out.push_str(" (steps: ");
            out.push_u64(self.trap_steps);
            out.push_str("/");
            out.push_u64(self.max_steps);
            out.push_str("; see --const-eval-steps/--const-eval-memory)");
        }
        self.dbuf.clear();
        self.dbuf.push_string(&out);
        out.free();
        return self.dbuf.as_str();
    }

    fn record_fold_err(self: &mut Self, m: ModuleId, id: NodeId) {
        // dedupe: emission probes the same failing node more than once
        for i in 0..self.fold_errs.len() {
            let r = self.fold_errs.at(i);
            if r.m == m && r.id == id {
                return;
            }
        }
        let detail = self.trap_detail();
        let mut d = String::new();
        d.push_str(detail);
        self.fold_errs.push(IFoldErr { m: m, id: id, kind: self.trap_kind, constfn: self.trap_in_constfn, detail: d });
    }

    /// Fold expression `id` of module `m` to a scalar; IV_NONE = not compile-time evaluable
    /// (retryable unless a trap is set). Mirrors the established evaluator's memo protocol:
    /// scalar successes store, non-scalar successes store a positive fact, in-flight re-entry
    /// is a cyclic constant dependency.

    // A module's per-node type under serial-order visibility: a module checked EARLY by the
    // parallel schedule but AFTER the requester in id order answers TYPE_NONE, as it did serially.
    fn tof(self: &Self, m: ModuleId, a: &Ast, n: NodeId) TypeId {
        if self.tc_par && m > self.root_mod {
            return TYPE_NONE;
        }
        return a.type_of(n);
    }

    fn etok() usize {
        let c = (unsafe sc_runtime::sc_rt_tls_get()) as usize;
        if c == 0 {
            return 1;
        }
        return c;
    }

    /// Is THIS task inside one of its own engine evaluations? Engine-driven lowering must not
    /// re-enter implicit folding; another task's live evaluation is NOT a reason to skip (the
    /// facade serializes on entry), or folds would depend on scheduling.
    pub fn folding_self(self: &Self) bool {
        if self.elock_on && atomic::load_usize(&self.elock_owner, 0) != Interp::etok() {
            return false;
        }
        return self.in_run != 0 || self.ev_depth != 0;
    }

    /// Public bracket for callers that must read trap state coherently with their own evaluation
    /// (the trap fields describe the LAST evaluation; another task's eval must not run between).
    /// Reentrant: nested facade entries under a held bracket are free.
    pub fn eng_lock(self: &mut Self) {
        self.eng_enter();
    }

    pub fn eng_unlock(self: &mut Self) {
        self.eng_leave();
    }

    fn eng_enter(self: &mut Self) {
        if !self.elock_on {
            return;
        }
        let tok = Interp::etok();
        // the fast-path owner read is atomic: it can only equal `tok` when THIS task stored it
        if atomic::load_usize(&self.elock_owner, 0) == tok {
            self.elock_depth += 1;
            return;
        }
        self.elock_sem.acquire();
        atomic::store_usize(&mut self.elock_owner, tok, 0);
        self.elock_depth = 1;
    }

    fn eng_leave(self: &mut Self) {
        if !self.elock_on {
            return;
        }
        self.elock_depth -= 1;
        if self.elock_depth == 0 {
            atomic::store_usize(&mut self.elock_owner, 0, 0);
            self.elock_sem.release();
        }
    }

    /// Suppress fold recording across a speculative probe (the short-circuit RHS): a method so the
    /// counter update serializes with the engine under parallel stages.
    pub fn pause_folds(self: &mut Self) {
        self.eng_enter();
        self.record_pause += 1;
        self.eng_leave();
    }

    pub fn resume_folds(self: &mut Self) {
        self.eng_enter();
        self.record_pause -= 1;
        self.eng_leave();
    }

    pub fn eval(self: &mut Self, m: ModuleId, id: NodeId) IVal {
        self.eng_enter();
        let top9 = self.ev_depth == 0 && self.in_run == 0;
        if top9 {
            self.root_mod = m;
        }
        let mut r = self.eval_g(m, id);
        // Parallel-frontend retry: a lowering was gated on a LOWER-indexed module still being
        // checked. Serial semantics say that module IS checked by now, so wait for its task
        // (indexes strictly decrease across waits -- acyclic) and re-run the whole evaluation.
        while top9 && self.tc_par && self.retry_mod >= 0 {
            let wm = self.retry_mod as ModuleId;
            self.retry_mod = 0 - 1;
            self.eng_leave();
            let wf = self.p().tc_wait;
            wf(self.p().tc_wait_ctx, wm);
            self.eng_enter();
            self.root_mod = m;
            r = self.eval_g(m, id);
        }
        if top9 {
            self.retry_mod = 0 - 1;
        }
        self.eng_leave();
        return r;
    }

    fn eval_g(self: &mut Self, m: ModuleId, id: NodeId) IVal {
        if id == NODE_NONE {
            return none();
        }
        let key = m as u64 << 32 | id as u64;
        let mut memo_kind: u8 = IV_NONE;
        let mut memo_hit = false;
        let mut memo_v = none();
        switch self.ememo.get(&key) {
            Some(v) => {
                memo_hit = true;
                memo_kind = v.kind;
                memo_v = *v;
            },
            None => {},
        };
        if memo_hit {
            if memo_kind == EV_EVALUATING {
                self.it_trap(IT_TRAP_CYCLE, "cyclic constant dependency");
                self.failed = false;
                return none();
            }
            if memo_kind == EV_AGG_OK {
                return none(); // known non-scalar success: nothing to fold, nothing to re-run
            }
            return memo_v;
        }
        let top = self.ev_depth == 0 && self.in_run == 0;
        if top {
            self.steps = 0;
            self.trap = "";
            self.trap_kind = IT_TRAP_NONE;
            self.trap_nframes = 0;
            self.trap_in_constfn = false;
            self.nframes = 0;
            self.objs_live = 0;
            self.live_slots = 0;
            self.item_active.truncate(0);
            self.failed = false;
        }
        let failed0 = self.failed;
        self.ememo.insert(key, IVal { kind: EV_EVALUATING, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 });
        self.ev_depth += 1;
        let mut lw = irl::Lowerer::new(self.pkg, m, id);
        if self.tc_par && m > self.root_mod {
            lw.f.unchecked_view = true; // serial-order visibility: this module was unchecked then
        }
        let mut v = none();
        // a CONST DECL as the target evaluates its initializer (the established evaluator's `ev`
        // did the same); anything else is a bare expression
        let isconst = (unsafe &*self.p().module_ast_const(m)).at_const(id).kind == NodeKind::NODE_CONST;
        let ok0 = if isconst {
            lw.lower_const(id);
        } else {
            lw.lower_expr_root(id);
        };
        if ok0 {
            let args = Vector::<IVal>::new();
            v = self.run(&lw.body, &args);
        }
        self.ev_depth -= 1;
        if top && self.retry_mod < 0 && self.record_folds && self.record_pause == 0 && v.kind == IV_NONE && (it_trap_is_ub(
            self.trap_kind,
        ) || self.trap_in_constfn) {
            self.record_fold_err(m, id);
        }
        // scalar success stores the value; non-scalar success stores the positive fact; failure
        // clears the sentinel and stays retryable
        let scalar = v.kind == IV_INT || v.kind == IV_BOOL || v.kind == IV_FLOAT;
        if scalar {
            self.ememo.insert(key, v);
        } else if !self.failed && (v.kind == IV_OBJ || v.kind == IV_PTR || v.kind == IV_FN || v.kind == IV_STR || v.kind == IV_UNIT) {
            self.ememo.insert(key, IVal { kind: EV_AGG_OK, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 });
        } else {
            let _ = self.ememo.remove(&key);
        }
        if !top {
            self.failed = failed0;
        } else {
            self.failed = false;
        }
        if scalar {
            return v;
        }
        return none();
    }

    /// Fold `id` under an explicit generic substitution (per-instantiation static_asserts);
    /// deliberately unmemoized.
    pub fn eval_typed(
        self: &mut Self,
        m: ModuleId,
        id: NodeId,
        pmod: ModuleId,
        params: *const NodeId,
        am2: *const ModuleId,
        at2: *const TypeId,
        n: u8,
    ) IVal {
        if id == NODE_NONE || self.ev_depth != 0 || self.in_run != 0 {
            return none();
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = IT_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.nframes = 0;
        self.objs_live = 0;
        self.live_slots = 0;
        self.item_active.truncate(0);
        self.failed = false;
        let sb0 = self.subst.len();
        for i in 0..n {
            self.subst.push(
                ISub {
                    pmod: pmod,
                    pnode: unsafe params[i as usize],
                    am: unsafe am2[i as usize],
                    at: unsafe at2[i as usize],
                },
            );
        }
        let prev_base = self.sub_base;
        self.sub_base = sb0;
        let mut lw = irl::Lowerer::new(self.pkg, m, id);
        if self.tc_par && m > self.root_mod {
            lw.f.unchecked_view = true;
        }
        for i in 0..n {
            let sb = *self.subst.at(sb0 + i as usize);
            lw.env.push(irl::LSub { pm: sb.pmod, pnode: sb.pnode, am: sb.am, at: sb.at });
        }
        let mut v = none();
        self.ev_depth += 1;
        if lw.lower_expr_root(id) {
            let args = Vector::<IVal>::new();
            v = self.run(&lw.body, &args);
        }
        self.ev_depth -= 1;
        self.sub_base = prev_base;
        self.subst.truncate(sb0);
        self.failed = false;
        if v.kind == IV_INT || v.kind == IV_BOOL || v.kind == IV_FLOAT {
            return v;
        }
        return none();
    }

    /// Field/tuple-member count of aggregate decl `(dm, dn)` -- `type_info::<T>().fields.len`.
    pub fn field_count_of(self: &Self, dm: ModuleId, dn: NodeId) u32 {
        return self.field_count(dm, dn);
    }

    /// Variant count of enum decl `(dm, dn)` -- `type_info::<T>().variants.len`.
    pub const fn variant_count_of(self: &Self, dm: ModuleId, dn: NodeId) u32 {
        let a = unsafe &*self.p().module_ast_const(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        let mut n: u32 = 0;
        for i in 0..ms.len {
            if a.at_const(unsafe a.list(ms)[i as usize]).kind == NodeKind::NODE_VARIANT {
                n += 1;
            }
        }
        return n;
    }

    /// The `TypeTag` variant index for a type (order pinned by std/core.spc); -1 = untaggable.
    pub const fn ti_tag(self: &Self, tm: ModuleId, tt: TypeId, strm: ModuleId, strn: NodeId, slm: ModuleId, sln: NodeId) i64 {
        let a0 = unsafe &*self.p().module_ast_const(tm);
        let y = *a0.type_at(tt);
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
                    return 0 - 1;
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
                let it = *a0.instance(y.as_data.inst);
                dm = it.module;
                dn = it.decl;
                if dm == slm && dn == sln {
                    return 10;
                }
                let da = unsafe &*self.p().module_ast_const(dm);
                // SliceMut lives beside Slice; matching the decl's own name keeps the compare exact.
                let tnm = da.at_const(da.at_const(dn).as_data.aggregate.name).as_data.name.text;
                if dm == slm && self.span_is(dm, tnm, "SliceMut") {
                    return 10;
                }
                // `(A, B)` lowered to the prelude Tuple2..4 before this ever ran: report it as the
                // tuple it was written as, not as the struct it lowered to.
                if self.span_is(dm, tnm, "Tuple2") || self.span_is(dm, tnm, "Tuple3") || self.span_is(dm, tnm, "Tuple4") {
                    return 12;
                }
            }
            if dm == strm && dn == strn {
                return 11;
            }
            let d = (unsafe &*self.p().module_ast_const(dm)).at_const(dn);
            if d.kind == NodeKind::NODE_ENUM {
                return 15;
            }
            if d.kind != NodeKind::NODE_STRUCT {
                return 0 - 1;
            }
            if d.as_data.aggregate.is_union {
                return 14;
            }
            if d.as_data.aggregate.is_tuple {
                return 12;
            }
            return 13;
        }
        return 0 - 1;
    }

    /// Queue a static_assert condition for flush_asserts (re-checked once every module is typed).
    pub fn defer_assert(self: &mut Self, m: ModuleId, cond: NodeId) {
        self.eng_enter();
        self.defer_assert_g(m, cond);
        self.eng_leave();
    }

    fn defer_assert_g(self: &mut Self, m: ModuleId, cond: NodeId) {
        self.pending.push(m as u64 << 32 | cond as u64);
    }

    /// Queue a call-bearing const initializer undecidable in module order.
    pub fn defer_const(self: &mut Self, m: ModuleId, decl: NodeId) {
        self.eng_enter();
        self.defer_const_g(m, decl);
        self.eng_leave();
    }

    fn defer_const_g(self: &mut Self, m: ModuleId, decl: NodeId) {
        self.pending_consts.push(m as u64 << 32 | decl as u64);
    }

    const fn const_is_item(self: &Self, m: ModuleId, id: NodeId) bool {
        let a = unsafe &*self.p().module_ast_const(m);
        let items = a.at_const(a.root).as_data.program.items;
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
            let pk = self.pending[i];
            let m = (pk >> 32) as ModuleId;
            let cond = (pk & 0xFFFFFFFFu64) as NodeId;
            let v = self.eval(m, cond);
            if v.kind == IV_BOOL && v.i == 0 {
                err(ctx, m, cond, null);
            } else if v.kind == IV_NONE && self.trap.len() != 0 {
                let _ = self.trap_detail();
                err(ctx, m, cond, self.dbuf.cstr());
            }
        }
        self.pending.clear();
    }

    /// Re-evaluate the deferred const initializers: err() fires with trap detail for a definite
    /// trap, and for a top-level const that still cannot be evaluated.
    pub fn flush_consts(self: &mut Self, err: fn(*mut void, ModuleId, NodeId, *const char) void, ctx: *mut void) {
        for i in 0..self.pending_consts.len() {
            let pk = self.pending_consts[i];
            let m = (pk >> 32) as ModuleId;
            let decl = (pk & 0xFFFFFFFFu64) as NodeId;
            let value = (unsafe &*self.p().module_ast_const(m)).at_const(decl).as_data.const_def.value;
            let v = self.eval(m, value);
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: flush const m={} decl={} value={} -> kind={}\n", m, decl, value, v.kind);
            }
            if v.kind != IV_NONE {
                continue;
            }
            if self.trap.len() == 0 && self.eval_static(m, value).ok {
                continue;
            }
            if self.trap.len() != 0 {
                let _ = self.trap_detail();
                err(ctx, m, decl, self.dbuf.cstr());
            } else if self.const_is_item(m, decl) {
                // every module is typed now, so a top-level const has no legitimate silent failure
                // left (only unsubstituted generics do, and those are local)
                err(ctx, m, decl, "the initializer requires execution but could not be evaluated".ptr() as *const char);
            }
        }
        self.pending_consts.clear();
    }

    /// Evaluate expression `id` and capture its aggregate as static data; scalars and failures
    /// report not-ok (a definite trap pins the failure in the memo, silence stays retryable).

    /// A `TypeInfo` descriptor for target type (am, at), captured as static data (the @reflect /
    /// type_info emission path). `rty` is the interned TypeInfo struct type in module `m`.
    pub fn eval_type_info_export(self: &mut Self, m: ModuleId, rty: TypeId, am: ModuleId, at: TypeId) StaticRes {
        let bad = StaticRes { ok: false, root: 0 };
        if self.ev_depth != 0 || self.in_run != 0 || self.nframes != 0 {
            return bad;
        }
        let tih = self.p().prelude_lookup("TypeInfo", true);
        if tih.node == NODE_NONE {
            return bad;
        }
        self.steps = 0;
        self.trap = "";
        self.trap_kind = IT_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.nframes = 0;
        self.objs_live = 0;
        self.live_slots = 0;
        self.item_active.truncate(0);
        self.failed = false;
        self.ev_depth += 1;
        let v = self.type_info_decl(m, tih.mid, tih.node, rty, am, at);
        self.ev_depth -= 1;
        if self.failed || v.kind != IV_OBJ {
            self.failed = false;
            return bad;
        }
        let r = self.capture(v);
        self.failed = false;
        return r;
    }

    pub fn eval_static(self: &mut Self, m: ModuleId, id: NodeId) StaticRes {
        self.eng_enter();
        let top9 = self.ev_depth == 0 && self.in_run == 0;
        if top9 {
            self.root_mod = m;
        }
        let mut r = self.eval_static_g(m, id);
        while top9 && self.tc_par && self.retry_mod >= 0 {
            let wm = self.retry_mod as ModuleId;
            self.retry_mod = 0 - 1;
            self.eng_leave();
            let wf = self.p().tc_wait;
            wf(self.p().tc_wait_ctx, wm);
            self.eng_enter();
            self.root_mod = m;
            r = self.eval_static_g(m, id);
        }
        if top9 {
            self.retry_mod = 0 - 1;
        }
        self.eng_leave();
        return r;
    }

    fn eval_static_g(self: &mut Self, m: ModuleId, id: NodeId) StaticRes {
        let bad = StaticRes { ok: false, root: 0 };
        if id == NODE_NONE || self.ev_depth != 0 || self.in_run != 0 {
            return bad;
        }
        let key = m as u64 << 32 | id as u64;
        switch self.sref.get(&key) {
            Some(v) => {
                if *v < 0 {
                    return bad;
                }
                return StaticRes { ok: true, root: (*v - 1) as u32 };
            },
            None => {},
        };
        switch self.ememo.get(&key) {
            Some(v) => {
                if v.kind != EV_AGG_OK {
                    return bad; // scalar memo hit (or in-flight): not an aggregate
                }
            },
            None => {},
        };
        self.steps = 0;
        self.trap = "";
        self.trap_kind = IT_TRAP_NONE;
        self.trap_nframes = 0;
        self.trap_in_constfn = false;
        self.nframes = 0;
        self.objs_live = 0;
        self.live_slots = 0;
        self.item_active.truncate(0);
        self.failed = false;
        self.ememo.insert(key, IVal { kind: EV_EVALUATING, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 });
        self.ev_depth += 1;
        let mut lw = irl::Lowerer::new(self.pkg, m, id);
        if self.tc_par && m > self.root_mod {
            lw.f.unchecked_view = true;
        }
        let mut v = none();
        let isconst2 = (unsafe &*self.p().module_ast_const(m)).at_const(id).kind == NodeKind::NODE_CONST;
        let ok02 = if isconst2 {
            lw.lower_const(id);
        } else {
            lw.lower_expr_root(id);
        };
        if ok02 {
            let args = Vector::<IVal>::new();
            v = self.run(&lw.body, &args);
        }
        self.ev_depth -= 1;
        let scalar = v.kind == IV_INT || v.kind == IV_BOOL || v.kind == IV_FLOAT;
        if scalar {
            self.ememo.insert(key, v);
        } else if !self.failed && v.kind != IV_NONE {
            self.ememo.insert(key, IVal { kind: EV_AGG_OK, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 });
        } else {
            let _ = self.ememo.remove(&key);
        }
        if v.kind == IV_STR {
            // a str view IS static data: materialize its object form and capture that
            let sv2 = self.str_materialize(v.tm, v);
            if !self.failed && sv2.kind == IV_OBJ {
                v = sv2;
            } else {
                self.failed = false;
            }
        }
        if v.kind != IV_OBJ {
            if self.retry_mod < 0 && self.record_folds && self.record_pause == 0 && v.kind == IV_NONE && (it_trap_is_ub(
                self.trap_kind,
            ) || self.trap_in_constfn) {
                self.record_fold_err(m, id);
            }
            if self.retry_mod < 0 && self.trap.len() != 0 {
                self.sref.insert(key, 0 - 1); // definite failure; undecidable stays retryable
            }
            self.failed = false;
            return bad;
        }
        let r = self.capture(v);
        self.failed = false;
        if !r.ok {
            self.sref.insert(key, 0 - 1);
            return bad;
        }
        self.sref.insert(key, r.root as i64 + 1);
        return r;
    }

    // ---- type_info descriptor graphs --------------------------------------------------------------

    // Field ordinal of the field NAMED `name` in aggregate decl (dm, dn); -1 = absent.
    const fn ti_findf(self: &Self, dm: ModuleId, dn: NodeId, name: str) i32 {
        let da = unsafe &*self.p().module_ast_const(dm);
        let ms = da.at_const(dn).as_data.aggregate.members;
        let mut idx: i32 = 0;
        for i in 0..ms.len {
            let fid = unsafe da.list(ms)[i as usize];
            if da.at_const(fid).kind == NodeKind::NODE_FIELD {
                if self.span_is(dm, da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text, name) {
                    return idx;
                }
                idx += 1;
            }
        }
        return 0 - 1;
    }

    // A `str` value: a heap byte block plus the two-field view struct, exactly the shape
    // str_materialize builds. (sm, sn) is the `str` decl; (stym, sty) its type.
    fn ti_str(self: &mut Self, sm: ModuleId, sn: NodeId, stym: ModuleId, sty: TypeId, bytes: str) IVal {
        let nb = bytes.len() as u32;
        let mut block: u32 = 0;
        if nb != 0 {
            block = self.obj_new(nb);
            if block == 0 {
                return none();
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
                    iv_int(0, Ast::builtin(BuiltinType::BT_U8), bytes.byte_at(k as usize)),
                );
            }
        }
        let ptr_i = self.ti_findf(sm, sn, "ptr");
        let len_i = self.ti_findf(sm, sn, "len");
        if ptr_i < 0 || len_i < 0 {
            return none();
        }
        let so = self.obj_new(self.field_count(sm, sn));
        if so == 0 {
            return none();
        }
        unsafe self.obj_ptr(so).dm = sm;
        unsafe self.obj_ptr(so).dn = sn;
        unsafe self.obj_ptr(so).slots.set(ptr_i as usize, iv_ptr(0, TYPE_NONE, block, 0));
        unsafe self.obj_ptr(so).slots.set(len_i as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), nb));
        return IVal { kind: IV_OBJ, tm: stym, ty: sty, i: so, f: 0.0 };
    }

    // A heap block holding `objs` as elements of type (tim, ety); 0 = failed (or empty input).
    fn ti_block(self: &mut Self, tim: ModuleId, ety: TypeId, esz: u64, objs: &Vector<IVal>) u32 {
        let n = objs.len() as u32;
        if n == 0 {
            return 0;
        }
        let blk = self.obj_new(n);
        if blk == 0 {
            return 0;
        }
        let bo = self.obj_ptr(blk);
        unsafe bo.heap = 1;
        unsafe bo.bytes = n as u64 * esz;
        unsafe bo.em = tim;
        unsafe bo.et = ety;
        unsafe bo.esz = esz;
        for k in 0..n {
            unsafe self.obj_ptr(blk).slots.set(k as usize, *objs.at(k as usize));
        }
        return blk;
    }

    // A Slice<E> view struct over `block` (0 = the empty slice: null ptr, len 0).
    fn ti_slice(
        self: &mut Self,
        slm: ModuleId,
        sln: NodeId,
        tim: ModuleId,
        ety: TypeId,
        slty: TypeId,
        block: u32,
        n: u32,
    ) IVal {
        let ptr_i = self.ti_findf(slm, sln, "ptr");
        let len_i = self.ti_findf(slm, sln, "len");
        if ptr_i < 0 || len_i < 0 {
            return none();
        }
        let so = self.obj_new(self.field_count(slm, sln));
        if so == 0 {
            return none();
        }
        unsafe self.obj_ptr(so).dm = slm;
        unsafe self.obj_ptr(so).dn = sln;
        unsafe self.obj_ptr(so).nargs = 1;
        unsafe self.obj_ptr(so).am[0] = tim;
        unsafe self.obj_ptr(so).at[0] = ety;
        unsafe self.obj_ptr(so).slots.set(ptr_i as usize, iv_ptr(0, TYPE_NONE, block, 0));
        unsafe self.obj_ptr(so).slots.set(len_i as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), n));
        return IVal { kind: IV_OBJ, tm: tim, ty: slty, i: so, f: 0.0 };
    }

    // Resolve (m0, t0) through a LayoutEnv chain while it names a generic param -- the env-frame
    // sibling of rty, for field types inside a generic instance's decl.
    const fn ti_env_ty(
        self: &Self,
        m0: ModuleId,
        t0: TypeId,
        env: *const lay::LayoutEnv,
        om: &mut ModuleId,
        ot: &mut TypeId,
    ) bool {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..8 {
            if t == TYPE_NONE {
                return false;
            }
            let y = (unsafe &*self.p().module_ast_const(m)).type_at(t);
            if y.kind != TypeKind::TYPE_GENERIC {
                *om = m;
                *ot = t;
                return true;
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
                return false;
            }
        }
        return false;
    }

    // A FieldInfo (`tag < 0`: name/offset/size/kind, `aux` = the field type's TypeTag index) or
    // VariantInfo (`tag >= 0`: name/tag/payload, `aux` = the payload value count) object.
    fn ti_member(
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
    ) IVal {
        let ye = *(unsafe &*self.p().module_ast_const(tim)).type_at(ety);
        if ye.kind != TypeKind::TYPE_STRUCT {
            return none();
        }
        let em = ye.module;
        let en = ye.as_data.decl;
        let nmv = self.ti_str(strm, strn, tim, sty, name);
        if nmv.kind != IV_OBJ {
            return none();
        }
        let o = self.obj_new(self.field_count(em, en));
        if o == 0 {
            return none();
        }
        unsafe self.obj_ptr(o).dm = em;
        unsafe self.obj_ptr(o).dn = en;
        let i_name = self.ti_findf(em, en, "name");
        if i_name < 0 {
            return none();
        }
        unsafe self.obj_ptr(o).slots.set(i_name as usize, nmv);
        if tag >= 0 {
            let i_tag = self.ti_findf(em, en, "tag");
            let i_pl = self.ti_findf(em, en, "payload");
            if i_tag < 0 || i_pl < 0 {
                return none();
            }
            unsafe self.obj_ptr(o).slots.set(i_tag as usize, iv_int(0, Ast::builtin(BuiltinType::BT_I32), tag));
            unsafe self.obj_ptr(o).slots.set(i_pl as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), aux as i64));
        } else {
            let i_off = self.ti_findf(em, en, "offset");
            let i_size = self.ti_findf(em, en, "size");
            let i_kind = self.ti_findf(em, en, "kind");
            if i_off < 0 || i_size < 0 || i_kind < 0 {
                return none();
            }
            unsafe self.obj_ptr(o).slots.set(i_off as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), off as i64));
            unsafe self.obj_ptr(o).slots.set(
                i_size as usize,
                iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), size as i64),
            );
            unsafe self.obj_ptr(o).slots.set(i_kind as usize, iv_int(tim, kty, aux as i64));
        }
        return IVal { kind: IV_OBJ, tm: tim, ty: ety, i: o, f: 0.0 };
    }

    // A MethodInfo object for the extend function (mm, mid): name/arity/is_pub/ret by field name.
    fn ti_method(
        self: &mut Self,
        mm: ModuleId,
        mid: NodeId,
        strm: ModuleId,
        strn: NodeId,
        slm: ModuleId,
        sln: NodeId,
        tim: ModuleId,
        sty: TypeId,
        kty: TypeId,
        hty: TypeId,
    ) IVal {
        let yh = *(unsafe &*self.p().module_ast_const(tim)).type_at(hty);
        if yh.kind != TypeKind::TYPE_STRUCT {
            return none();
        }
        let em = yh.module;
        let en = yh.as_data.decl;
        let fa2 = unsafe &*self.p().module_ast_const(mm);
        let fd = fa2.at_const(mid).as_data.function;
        let sp = fa2.at_const(fd.name).as_data.name.text;
        let src2 = self.src_of(mm);
        let nmv = self.ti_str(strm, strn, tim, sty, src2.slice(sp.start as usize, sp.end as usize));
        if nmv.kind != IV_OBJ {
            return none();
        }
        let mut ar = fd.params.len as i64;
        if fd.params.len > 0 {
            let p0 = fa2.at_const(unsafe fa2.list(fd.params)[0]).as_data.parameter.name;
            if self.span_is(mm, fa2.at_const(p0).as_data.name.text, "self") {
                ar -= 1;
            }
        }
        let mut rtag: i64 = 0;
        if fd.returns.len == 1 {
            let r0 = fa2.type_of(unsafe fa2.list(fd.returns)[0]);
            if r0 != TYPE_NONE {
                let t2 = self.ti_tag(mm, r0, strm, strn, slm, sln);
                if t2 > 0 {
                    rtag = t2;
                }
            }
        }
        let o = self.obj_new(self.field_count(em, en));
        if o == 0 {
            return none();
        }
        unsafe self.obj_ptr(o).dm = em;
        unsafe self.obj_ptr(o).dn = en;
        let i_name = self.ti_findf(em, en, "name");
        let i_ar = self.ti_findf(em, en, "arity");
        let i_pub = self.ti_findf(em, en, "is_pub");
        let i_ret = self.ti_findf(em, en, "ret");
        if i_name < 0 || i_ar < 0 || i_pub < 0 || i_ret < 0 {
            return none();
        }
        unsafe self.obj_ptr(o).slots.set(i_name as usize, nmv);
        unsafe self.obj_ptr(o).slots.set(i_ar as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), ar));
        unsafe self.obj_ptr(o).slots.set(i_pub as usize, iv_bool(0, Ast::builtin(BuiltinType::BT_BOOL), fd.is_public));
        unsafe self.obj_ptr(o).slots.set(i_ret as usize, iv_int(tim, kty, rtag));
        return IVal { kind: IV_OBJ, tm: tim, ty: hty, i: o, f: 0.0 };
    }

    // The `@reflect` entries attached to decl `own` in module `dm`, as a MetaInfo slice value;
    // the empty slice when there are none.
    fn ti_meta_slice(
        self: &mut Self,
        dm: ModuleId,
        own: NodeId,
        tim: ModuleId,
        strm: ModuleId,
        strn: NodeId,
        slm: ModuleId,
        sln: NodeId,
        sty: TypeId,
        mety: TypeId,
        mkty: TypeId,
        mslty: TypeId,
        mesz: u64,
    ) IVal {
        let ym = *(unsafe &*self.p().module_ast_const(tim)).type_at(mety);
        let mem = ym.module;
        let men = ym.as_data.decl;
        let i_name = self.ti_findf(mem, men, "name");
        let i_kind = self.ti_findf(mem, men, "kind");
        let i_b = self.ti_findf(mem, men, "b");
        let i_i = self.ti_findf(mem, men, "i");
        let i_s = self.ti_findf(mem, men, "s");
        if i_name < 0 || i_kind < 0 || i_b < 0 || i_i < 0 || i_s < 0 {
            return none();
        }
        let mut objs = Vector::<IVal>::new();
        let src = self.src_of(dm);
        let da = unsafe &*self.p().module_ast_const(dm);
        let nmetas = if own != NODE_NONE {
            da.metas.len();
        } else {
            0 as usize;
        };
        for i in 0..nmetas {
            let ma = *da.metas.at(i);
            if ma.owner != own {
                continue;
            }
            let o = self.obj_new(self.field_count(mem, men));
            if o == 0 {
                objs.free();
                return none();
            }
            unsafe self.obj_ptr(o).dm = mem;
            unsafe self.obj_ptr(o).dn = men;
            let nmv = self.ti_str(strm, strn, tim, sty, src.slice(ma.key.start as usize, ma.key.end as usize));
            let mut sv = self.ti_str(strm, strn, tim, sty, "");
            if ma.vkind == 2 {
                sv = self.ti_str(strm, strn, tim, sty, src.slice(ma.vspan.start as usize, ma.vspan.end as usize));
            }
            if nmv.kind != IV_OBJ || sv.kind != IV_OBJ {
                objs.free();
                return none();
            }
            unsafe self.obj_ptr(o).slots.set(i_name as usize, nmv);
            unsafe self.obj_ptr(o).slots.set(i_kind as usize, iv_int(tim, mkty, ma.vkind));
            let mut bv: i64 = 0;
            if ma.vkind == 0 {
                bv = ma.ival;
            }
            let mut iv2: i64 = 0;
            if ma.vkind == 1 {
                iv2 = ma.ival;
            }
            unsafe self.obj_ptr(o).slots.set(i_b as usize, iv_bool(0, Ast::builtin(BuiltinType::BT_BOOL), bv != 0));
            unsafe self.obj_ptr(o).slots.set(i_i as usize, iv_int(0, Ast::builtin(BuiltinType::BT_I64), iv2));
            unsafe self.obj_ptr(o).slots.set(i_s as usize, sv);
            objs.push(IVal { kind: IV_OBJ, tm: tim, ty: mety, i: o, f: 0.0 });
        }
        let n2 = objs.len() as u32;
        let blk = self.ti_block(tim, mety, mesz, &objs);
        objs.free();
        if blk == 0 && n2 != 0 {
            return none();
        }
        return self.ti_slice(slm, sln, tim, mety, mslty, blk, n2);
    }

    // Attach decl `own`'s meta slice to a just-built FieldInfo/VariantInfo object; false = failed.
    fn ti_attach_meta(
        self: &mut Self,
        member: IVal,
        dm: ModuleId,
        own: NodeId,
        tim: ModuleId,
        strm: ModuleId,
        strn: NodeId,
        slm: ModuleId,
        sln: NodeId,
        sty: TypeId,
        mety: TypeId,
        mkty: TypeId,
        mslty: TypeId,
        mesz: u64,
    ) bool {
        let ms = self.ti_meta_slice(dm, own, tim, strm, strn, slm, sln, sty, mety, mkty, mslty, mesz);
        if ms.kind != IV_OBJ {
            return false;
        }
        let o = member.i as u32;
        let op = self.obj_ptr(o);
        if op == null {
            return false;
        }
        let i_m = self.ti_findf(unsafe op.dm, unsafe op.dn, "meta");
        if i_m < 0 {
            return false;
        }
        unsafe self.obj_ptr(o).slots.set(i_m as usize, ms);
        return true;
    }

    /// `type_info::<T>()`: build the TypeInfo object graph for the CONCRETE (tm, tt), against the
    /// TypeInfo decl (tim, tin) named by the intrinsic's result type; every other decl the graph
    /// uses (str, TypeTag, Slice, FieldInfo, VariantInfo, MetaInfo, MethodInfo) is derived from
    /// the TypeInfo declaration's own field types.
    fn type_info_decl(self: &mut Self, m: ModuleId, tim: ModuleId, tin: NodeId, rty: TypeId, tm: ModuleId, tt: TypeId) IVal {
        let da = unsafe &*self.p().module_ast_const(tim);
        let mut sty = TYPE_NONE; // str
        let mut kty = TYPE_NONE; // TypeTag
        let mut flty = TYPE_NONE; // Slice<FieldInfo>
        let mut vrty = TYPE_NONE; // Slice<VariantInfo>
        let mut mty = TYPE_NONE; // Slice<MetaInfo>
        let mut mmty = TYPE_NONE; // Slice<MethodInfo>
        let tims = da.at_const(tin).as_data.aggregate.members;
        for i in 0..tims.len {
            let fid = unsafe da.list(tims)[i as usize];
            if da.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let fnm = da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text;
            let fty = da.type_of(da.at_const(fid).as_data.field.ty);
            if self.span_is(tim, fnm, "name") {
                sty = fty;
            } else if self.span_is(tim, fnm, "kind") {
                kty = fty;
            } else if self.span_is(tim, fnm, "fields") {
                flty = fty;
            } else if self.span_is(tim, fnm, "variants") {
                vrty = fty;
            } else if self.span_is(tim, fnm, "meta") {
                mty = fty;
            } else if self.span_is(tim, fnm, "methods") {
                mmty = fty;
            }
        }
        if sty == TYPE_NONE || kty == TYPE_NONE || flty == TYPE_NONE || vrty == TYPE_NONE {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 1 tim={} tin={} sty={} kty={} flty={} vrty={}\n", tim, tin, sty, kty, flty, vrty);
            }
            return none();
        }
        let ys = *da.type_at(sty);
        if ys.kind != TypeKind::TYPE_STRUCT {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 2\n");
            }
            return none();
        }
        let strm = ys.module;
        let strn = ys.as_data.decl;
        let yf = *da.type_at(flty);
        let yv = *da.type_at(vrty);
        if yf.kind != TypeKind::TYPE_INSTANCE || yv.kind != TypeKind::TYPE_INSTANCE {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 3\n");
            }
            return none();
        }
        let fit = *da.instance(yf.as_data.inst);
        let vit = *da.instance(yv.as_data.inst);
        let slm = fit.module;
        let sln = fit.decl;
        let fity = fit.args[0]; // FieldInfo, in tim's pool
        let vity = vit.args[0]; // VariantInfo, in tim's pool
        // MetaInfo's type, its `kind` enum's type, and its element size, all from the decls.
        let mut mety = TYPE_NONE;
        let mut mkty = TYPE_NONE;
        let mut mesz: u64 = 0;
        if mty != TYPE_NONE {
            let ym0 = *da.type_at(mty);
            if ym0.kind == TypeKind::TYPE_INSTANCE {
                let mit = *da.instance(ym0.as_data.inst);
                mety = mit.args[0];
                let ymm = *da.type_at(mety);
                if ymm.kind == TypeKind::TYPE_STRUCT {
                    let mem0 = ymm.module;
                    let men0 = ymm.as_data.decl;
                    let mma = unsafe &*self.p().module_ast_const(mem0);
                    let mms = mma.at_const(men0).as_data.aggregate.members;
                    for q in 0..mms.len {
                        let mfid = unsafe mma.list(mms)[q as usize];
                        if mma.at_const(mfid).kind != NodeKind::NODE_FIELD {
                            continue;
                        }
                        if self.span_is(
                            mem0,
                            mma.at_const(mma.at_const(mfid).as_data.field.name).as_data.name.text,
                            "kind",
                        ) {
                            mkty = mma.type_of(mma.at_const(mfid).as_data.field.ty);
                        }
                    }
                    let mlay = self.lsvc.layout_of(tim, mety, null, 0);
                    if mlay.ok {
                        mesz = mlay.size;
                    }
                }
            }
            if mety == TYPE_NONE || mkty == TYPE_NONE || mesz == 0 {
                mety = TYPE_NONE;
            }
        }
        // MethodInfo's type and element size, schema-driven like meta.
        let mut mhty = TYPE_NONE;
        let mut mhsz: u64 = 0;
        if mmty != TYPE_NONE {
            let yh0 = *da.type_at(mmty);
            if yh0.kind == TypeKind::TYPE_INSTANCE {
                let hit = *da.instance(yh0.as_data.inst);
                mhty = hit.args[0];
                if da.type_at(mhty).kind == TypeKind::TYPE_STRUCT {
                    let hlay = self.lsvc.layout_of(tim, mhty, null, 0);
                    if hlay.ok {
                        mhsz = hlay.size;
                    }
                }
            }
            if mhty == TYPE_NONE || mhsz == 0 {
                mhty = TYPE_NONE;
            }
        }
        let tag = self.ti_tag(tm, tt, strm, strn, slm, sln);
        if tag < 0 {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 4\n");
            }
            return none();
        }
        // Size and align; void is the one kind with no C layout.
        let mut size: u64 = 0;
        let mut align: u64 = 1;
        if tag != 0 {
            let lay0 = self.lsvc.layout(tm, tt);
            if !lay0.ok {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 5\n");
                }
                return none();
            }
            size = lay0.size;
            align = lay0.align;
        }
        // Name: builtin spelling, or the decl's declared name; anonymous kinds stay "".
        let y = *(unsafe &*self.p().module_ast_const(tm)).type_at(tt);
        let mut nm = "";
        if y.kind == TypeKind::TYPE_BUILTIN {
            nm = builtin_name(y.as_data.builtin);
        } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_INSTANCE {
            let mut dm = y.module;
            let mut dn = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *(unsafe &*self.p().module_ast_const(tm)).instance(y.as_data.inst);
                dm = it.module;
                dn = it.decl;
            }
            let na = unsafe &*self.p().module_ast_const(dm);
            let sp = na.at_const(na.at_const(dn).as_data.aggregate.name).as_data.name.text;
            let src = self.src_of(dm);
            nm = src.slice(sp.start as usize, sp.end as usize);
        }
        // Fields (struct/tuple/union) and variants (enum).
        let mut nfields: u32 = 0;
        let mut fblock: u32 = 0;
        let mut nvars: u32 = 0;
        let mut vblock: u32 = 0;
        if tag == 12 || tag == 13 || tag == 14 {
            let mut dm2 = y.module;
            let mut dn2 = y.as_data.decl;
            let mut envp: *const lay::LayoutEnv = null;
            let mut frame = lay::LayoutEnv { parent: null, pmod: 0, params: null, argm: tm, n: 0 };
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *(unsafe &*self.p().module_ast_const(tm)).instance(y.as_data.inst);
                dm2 = it.module;
                dn2 = it.decl;
                let ga = unsafe &*self.p().module_ast_const(dm2);
                let gens = ga.at_const(dn2).as_data.aggregate.generics;
                frame.pmod = dm2;
                frame.params = ga.list(gens);
                let mut gi: u32 = 0;
                while gi < gens.len && gi as u8 < it.n && frame.n < 8 {
                    unsafe frame.args[frame.n as usize] = unsafe it.args[gi as usize];
                    frame.n += 1;
                    gi += 1;
                }
                envp = &frame;
            }
            let fesz = self.lsvc.layout_of(tim, fity, null, 0);
            if !fesz.ok {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 6\n");
                }
                return none();
            }
            let da2 = unsafe &*self.p().module_ast_const(dm2);
            let agg = da2.at_const(dn2).as_data.aggregate;
            let is_union = agg.is_union;
            let is_tuple = agg.is_tuple;
            let packed = self.has_attr(dm2, dn2, AttrKind::ATTR_PACKED);
            let fs = agg.members;
            let mut fobjs = Vector::<IVal>::new();
            let mut run2: u64 = 0;
            for i in 0..fs.len {
                let fid = unsafe da2.list(fs)[i as usize];
                if !is_tuple && da2.at_const(fid).kind != NodeKind::NODE_FIELD {
                    continue;
                }
                let mut ftn = fid;
                if !is_tuple {
                    ftn = da2.at_const(fid).as_data.field.ty;
                }
                let ft = da2.type_of(ftn);
                let fl = self.lsvc.layout_of(dm2, ft, envp, 1);
                if ft == TYPE_NONE || !fl.ok {
                    fobjs.free();
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 7\n");
                    }
                    return none();
                }
                let mut fa3 = fl.align;
                if packed {
                    fa3 = 1;
                }
                let mut off: u64 = 0;
                if !is_union {
                    off = ti_round_up(run2, fa3);
                    run2 = off + fl.size;
                }
                let mut fname = "";
                let mut tbuf: [u8; 32] = [0; 32];
                if is_tuple {
                    fname = ti_tuple_name(&mut tbuf[0], fobjs.len() as u32);
                } else {
                    let sp = da2.at_const(da2.at_const(fid).as_data.field.name).as_data.name.text;
                    let src2 = self.src_of(dm2);
                    fname = src2.slice(sp.start as usize, sp.end as usize);
                }
                // The field type's own tag, through the instance's substitution; advisory, so an
                // untaggable field type degrades to Void rather than failing the whole descriptor.
                let mut frm: ModuleId = 0;
                let mut frt = TYPE_NONE;
                let mut ftag: i64 = 0;
                if self.ti_env_ty(dm2, ft, envp, &mut frm, &mut frt) {
                    ftag = self.ti_tag(frm, frt, strm, strn, slm, sln);
                    if ftag < 0 {
                        ftag = 0;
                    }
                }
                let fv = self.ti_member(strm, strn, tim, sty, kty, fity, fname, off, fl.size, 0 - 1, ftag as u64);
                if fv.kind != IV_OBJ {
                    fobjs.free();
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 8\n");
                    }
                    return none();
                }
                if mety != TYPE_NONE && !self.ti_attach_meta(
                    fv,
                    dm2,
                    fid,
                    tim,
                    strm,
                    strn,
                    slm,
                    sln,
                    sty,
                    mety,
                    mkty,
                    mty,
                    mesz,
                ) {
                    fobjs.free();
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 9\n");
                    }
                    return none();
                }
                fobjs.push(fv);
            }
            nfields = fobjs.len() as u32;
            fblock = self.ti_block(tim, fity, fesz.size, &fobjs);
            let failed2 = fblock == 0 && nfields != 0;
            fobjs.free();
            if failed2 {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 10\n");
                }
                return none();
            }
        }
        if tag == 15 {
            let mut dm2 = y.module;
            let mut dn2 = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *(unsafe &*self.p().module_ast_const(tm)).instance(y.as_data.inst);
                dm2 = it.module;
                dn2 = it.decl;
            }
            let vesz = self.lsvc.layout_of(tim, vity, null, 0);
            if !vesz.ok {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 11\n");
                }
                return none();
            }
            let da2 = unsafe &*self.p().module_ast_const(dm2);
            let vs = da2.at_const(dn2).as_data.aggregate.members;
            let mut any_payload = false;
            for i in 0..vs.len {
                if da2.at_const(unsafe da2.list(vs)[i as usize]).as_data.variant.payload.len > 0 {
                    any_payload = true;
                }
            }
            let mut vobjs = Vector::<IVal>::new();
            let mut next: i64 = 0;
            for i in 0..vs.len {
                let vid = unsafe da2.list(vs)[i as usize];
                if !any_payload {
                    let vval = da2.at_const(vid).as_data.variant.value;
                    if vval != NODE_NONE {
                        let e = self.eval(dm2, vval);
                        if e.kind != IV_INT {
                            vobjs.free();
                            if stdlib::getenv("SC_IRI_DBG") != null {
                                eprint("iri: tid exit 12\n");
                            }
                            return none();
                        }
                        next = e.i;
                    }
                }
                let mut vtag = next;
                if any_payload {
                    vtag = i;
                }
                next += 1;
                let sp = da2.at_const(da2.at_const(vid).as_data.variant.name).as_data.name.text;
                let src2 = self.src_of(dm2);
                let vv = self.ti_member(
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
                if vv.kind != IV_OBJ {
                    vobjs.free();
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 13\n");
                    }
                    return none();
                }
                if mety != TYPE_NONE && !self.ti_attach_meta(
                    vv,
                    dm2,
                    vid,
                    tim,
                    strm,
                    strn,
                    slm,
                    sln,
                    sty,
                    mety,
                    mkty,
                    mty,
                    mesz,
                ) {
                    vobjs.free();
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 14\n");
                    }
                    return none();
                }
                vobjs.push(vv);
            }
            nvars = vobjs.len() as u32;
            vblock = self.ti_block(tim, vity, vesz.size, &vobjs);
            let failed2 = vblock == 0 && nvars != 0;
            vobjs.free();
            if failed2 {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 15\n");
                }
                return none();
            }
        }
        // Methods: every `extend` function declared for a decl-backed or builtin T, across all
        // modules in load order, declaration order within a module.
        let mut nmeths: u32 = 0;
        let mut hblock: u32 = 0;
        if mhty != TYPE_NONE {
            let mut dm3: ModuleId = 0;
            let mut dn3 = NODE_NONE;
            let mut bb2 = BuiltinType::BT_COUNT;
            if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
                dm3 = y.module;
                dn3 = y.as_data.decl;
            } else if y.kind == TypeKind::TYPE_INSTANCE {
                let it4 = *(unsafe &*self.p().module_ast_const(tm)).instance(y.as_data.inst);
                dm3 = it4.module;
                dn3 = it4.decl;
            } else if y.kind == TypeKind::TYPE_BUILTIN {
                bb2 = y.as_data.builtin;
            }
            if dn3 != NODE_NONE || bb2 != BuiltinType::BT_COUNT {
                let mut hobjs = Vector::<IVal>::new();
                let mut fail = false;
                let nmods = self.p().modules.len();
                let mut q: usize = 0;
                while q < nmods && !fail {
                    let qm = q as ModuleId;
                    q += 1;
                    let qa = unsafe &*self.p().module_ast_const(qm);
                    if qa.nodes.len() == 0 {
                        continue;
                    }
                    let items = qa.at_const(qa.root).as_data.program.items;
                    for i3 in 0..items.len {
                        let iid = unsafe qa.list(items)[i3 as usize];
                        if qa.at_const(iid).kind != NodeKind::NODE_EXTEND {
                            continue;
                        }
                        let target = qa.at_const(iid).as_data.extend_def.target_type;
                        if target == NODE_NONE {
                            continue;
                        }
                        let mut match_recv = false;
                        if dn3 != NODE_NONE {
                            let tg = qa.resolution_def(target);
                            match_recv = tg.module == dm3 && tg.node == dn3;
                        } else {
                            let tt2 = qa.type_of(target);
                            if tt2 != TYPE_NONE {
                                let ty2 = qa.type_at(tt2);
                                match_recv = ty2.kind == TypeKind::TYPE_BUILTIN && ty2.as_data.builtin == bb2;
                            }
                        }
                        if !match_recv {
                            continue;
                        }
                        let ms2 = qa.at_const(iid).as_data.extend_def.items;
                        for k2 in 0..ms2.len {
                            let mid = unsafe qa.list(ms2)[k2 as usize];
                            if qa.at_const(mid).kind != NodeKind::NODE_FUNCTION {
                                continue;
                            }
                            let hv = self.ti_method(qm, mid, strm, strn, slm, sln, tim, sty, kty, mhty);
                            if hv.kind != IV_OBJ {
                                fail = true;
                                break;
                            }
                            if mety != TYPE_NONE && !self.ti_attach_meta(
                                hv,
                                qm,
                                mid,
                                tim,
                                strm,
                                strn,
                                slm,
                                sln,
                                sty,
                                mety,
                                mkty,
                                mty,
                                mesz,
                            ) {
                                fail = true;
                                break;
                            }
                            hobjs.push(hv);
                        }
                        if fail {
                            break;
                        }
                    }
                }
                if fail {
                    hobjs.free();
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 16\n");
                    }
                    return none();
                }
                nmeths = hobjs.len() as u32;
                hblock = self.ti_block(tim, mhty, mhsz, &hobjs);
                let hfailed = hblock == 0 && nmeths != 0;
                hobjs.free();
                if hfailed {
                    if stdlib::getenv("SC_IRI_DBG") != null {
                        eprint("iri: tid exit 17\n");
                    }
                    return none();
                }
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
            let it = *(unsafe &*self.p().module_ast_const(tm)).instance(y.as_data.inst);
            if it.n > 0 {
                ety2 = it.args[0];
            }
        }
        if ety2 != TYPE_NONE {
            etag = self.ti_tag(tm, ety2, strm, strn, slm, sln);
            if etag < 0 {
                etag = 0;
            }
        }
        // Assemble: the two slices, then the TypeInfo struct itself.
        let fsl = self.ti_slice(slm, sln, tim, fity, flty, fblock, nfields);
        let vsl = self.ti_slice(slm, sln, tim, vity, vrty, vblock, nvars);
        let nmv = self.ti_str(strm, strn, tim, sty, nm);
        if fsl.kind != IV_OBJ || vsl.kind != IV_OBJ || nmv.kind != IV_OBJ {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 18\n");
            }
            return none();
        }
        let to = self.obj_new(self.field_count(tim, tin));
        if to == 0 {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 19\n");
            }
            return none();
        }
        unsafe self.obj_ptr(to).dm = tim;
        unsafe self.obj_ptr(to).dn = tin;
        let i_name = self.ti_findf(tim, tin, "name");
        let i_kind = self.ti_findf(tim, tin, "kind");
        let i_size = self.ti_findf(tim, tin, "size");
        let i_align = self.ti_findf(tim, tin, "align");
        let i_elem = self.ti_findf(tim, tin, "elem");
        let i_len = self.ti_findf(tim, tin, "len");
        let i_fields = self.ti_findf(tim, tin, "fields");
        let i_vars = self.ti_findf(tim, tin, "variants");
        if i_name < 0 || i_kind < 0 || i_size < 0 || i_align < 0 || i_elem < 0 || i_len < 0 || i_fields < 0 || i_vars < 0 {
            if stdlib::getenv("SC_IRI_DBG") != null {
                eprint("iri: tid exit 20\n");
            }
            return none();
        }
        unsafe self.obj_ptr(to).slots.set(i_elem as usize, iv_int(tim, kty, etag));
        unsafe self.obj_ptr(to).slots.set(i_len as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), alen as i64));
        unsafe self.obj_ptr(to).slots.set(i_name as usize, nmv);
        unsafe self.obj_ptr(to).slots.set(i_kind as usize, iv_int(tim, kty, tag));
        unsafe self.obj_ptr(to).slots.set(i_size as usize, iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), size as i64));
        unsafe self.obj_ptr(to).slots.set(
            i_align as usize,
            iv_int(0, Ast::builtin(BuiltinType::BT_USIZE), align as i64),
        );
        unsafe self.obj_ptr(to).slots.set(i_fields as usize, fsl);
        unsafe self.obj_ptr(to).slots.set(i_vars as usize, vsl);
        if mety != TYPE_NONE {
            // the TYPE declaration's own `@reflect` entries (a non-decl kind matches nothing)
            let mut tdm = tm;
            let mut tdn = NODE_NONE;
            if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
                tdm = y.module;
                tdn = y.as_data.decl;
            } else if y.kind == TypeKind::TYPE_INSTANCE {
                let it3 = *(unsafe &*self.p().module_ast_const(tm)).instance(y.as_data.inst);
                tdm = it3.module;
                tdn = it3.decl;
            }
            let tms = self.ti_meta_slice(tdm, tdn, tim, strm, strn, slm, sln, sty, mety, mkty, mty, mesz);
            let i_meta = self.ti_findf(tim, tin, "meta");
            if tms.kind != IV_OBJ || i_meta < 0 {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 21\n");
                }
                return none();
            }
            unsafe self.obj_ptr(to).slots.set(i_meta as usize, tms);
        }
        if mhty != TYPE_NONE {
            let hsl = self.ti_slice(slm, sln, tim, mhty, mmty, hblock, nmeths);
            let i_meth = self.ti_findf(tim, tin, "methods");
            if hsl.kind != IV_OBJ || i_meth < 0 {
                if stdlib::getenv("SC_IRI_DBG") != null {
                    eprint("iri: tid exit 22\n");
                }
                return none();
            }
            unsafe self.obj_ptr(to).slots.set(i_meth as usize, hsl);
        }
        return IVal { kind: IV_OBJ, tm: m, ty: rty, i: to, f: 0.0 };
    }
}
