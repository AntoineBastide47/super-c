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
// anything unfoldable reports "not const" (CONST_NONE / CV_NIL) and stays a runtime construct. See
// src/consteval/consteval.c for the authoritative comments; this is a faithful Super-C port.

pub const CE_MAX_DEPTH: i32 = 32;
pub const CE_DEFAULT_STEPS: u32 = 2097152u32;  // 1<<21
pub const CE_DEFAULT_SLOTS: u64 = 4194304u64;  // 1<<22
pub const CE_MAX_FRAMES: u32 = 48;
pub const CE_MAX_LOCALS: u32 = 96;
pub const CE_MAX_DEFERS: u8 = 24;
pub const CE_MAX_OBJS: u32 = 65536u32;         // 1<<16
pub const CE_CALLS_MAX: usize = 65536;         // 1<<16

// ConstKind (public) / CvKind (interpreter)
pub const CONST_NONE: u8 = 0;
pub const CONST_INT: u8 = 1;
pub const CONST_BOOL: u8 = 2;
pub const CONST_FLOAT: u8 = 3;

pub const CV_NIL_K: u8 = 0;
pub const CV_INT: u8 = 1;
pub const CV_BOOL: u8 = 2;
pub const CV_FLOAT: u8 = 3;
pub const CV_PTR: u8 = 4;
pub const CV_AGG: u8 = 5;
pub const CV_FN: u8 = 6;

// statement outcomes
pub enum Flow { Ok, Return, Break, Continue, Bail }

pub const I64_MIN: i64 = 0x8000000000000000u64 as i64;
pub const I64_MAX: i64 = 0x7FFFFFFFFFFFFFFFu64 as i64;
pub const U64_MAX: u64 = 0xFFFFFFFFFFFFFFFFu64;
pub const F64_MAX: f64 = 1.7976931348623157e308;

// --- value types --------------------------------------------------------------------------------

pub union ConstValueAs { pub i: i64, pub f: f64 }
pub struct ConstValue { pub kind: u8, pub ty: TypeId, pub as_data: ConstValueAs }

pub struct CvPtr { pub obj: u32, pub off: u32 }
pub struct CvFn { pub m: ModuleId, pub fn_id: NodeId }
pub union CeValAs { pub i: i64, pub f: f64, pub p: CvPtr, pub fnv: CvFn }
pub struct CeVal { pub kind: u8, pub tm: ModuleId, pub ty: TypeId, pub as_data: CeValAs }

fn cv_nil() CeVal { return CeVal { kind: CV_NIL_K }; }
fn ce_none() ConstValue { return ConstValue { kind: CONST_NONE }; }

pub struct CePending { pub m: ModuleId, pub cond: NodeId }

// Fixed-buffer wrappers: a struct field zero-inits its array (Super-C has no `[v; N]` repeat-init).
pub struct Buf64 { pub b: [char; 64] }
pub struct Buf24 { pub b: [char; 24] }
pub struct Buf4096 { pub b: [u8; 4096] }

// --- layout engine structs ----------------------------------------------------------------------

pub struct LayoutEnv {
    pub parent: *const LayoutEnv,
    pub pmod: ModuleId,
    pub params: *const NodeId,
    pub argm: ModuleId,
    pub args: [TypeId; 4],
    pub n: u8,
}

pub struct LayoutAcc { pub size: u64, pub align: u64, pub packed: bool, pub is_union: bool }

// --- object store -------------------------------------------------------------------------------

pub struct CeObj {
    pub slots: Vector<CeVal>,
    pub dead: u8,
    pub is_enum: u8,
    pub heap: u8,
    pub dm: ModuleId,
    pub dn: NodeId,
    pub nargs: u8,
    pub am: [ModuleId; 4],
    pub at: [TypeId; 4],
    pub bytes: u64,   // heap: allocated byte size
    pub em: ModuleId, // heap: element type module
    pub et: TypeId,   // heap: element type; TYPE_NONE until the first cast to *mut T
    pub esz: u64,     // heap: sizeof(element)
}

extend CeObj as Free {
    pub fn free(self: &mut Self) void { self.slots.free(); }
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

fn ce_recv_zero() CeRecv { return CeRecv { dn: NODE_NONE, b: BuiltinType::BT_COUNT }; }

// --- frame --------------------------------------------------------------------------------------

pub struct CeLocal { pub decl: NodeId, pub slot: u32 }

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

fn ce_frame_zero() CeFrame { return CeFrame { env: 0 }; }

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
        h = (h ^ (self.m as u64)) * 1099511628211u64;
        h = (h ^ (self.fn_id as u64)) * 1099511628211u64;
        h = (h ^ (self.nargs as u64)) * 1099511628211u64;
        for i in 0..8 {
            h = (h ^ (self.kinds[i] as u64)) * 1099511628211u64;
            h = (h ^ (self.bits[i] as u64)) * 1099511628211u64;
        }
        return h;
    }
}

extend CeCallKey as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        if self.m != other.m || self.fn_id != other.fn_id || self.nargs != other.nargs { return false; }
        for i in 0..8 {
            if self.kinds[i] != other.kinds[i] || self.bits[i] != other.bits[i] { return false; }
        }
        return true;
    }
}

pub struct CeCallHit { pub nrets: u8, pub rets: [CeVal; 8] }

pub struct UFree { pub m: ModuleId, pub n: NodeId, pub user: bool }

pub struct ConstEval {
    pub pkg: *mut loader::Package,
    pub vals: Vector<Vector<ConstValue>>, // [module][node] memo tables
    pub nmods: usize,
    pub depth: u32,
    pub nframes: u32,
    pub steps: u32,
    pub max_steps: u32,
    pub max_slots: u64,
    pub objs: Vector<CeObj>,
    pub live_slots: u64,
    pub trap: str,
    pub pending: Vector<CePending>,
    pub calls: Map<CeCallKey, CeCallHit>,
    pub ufree: Vector<UFree>,
}

// --- small result structs (replace C out-params) ------------------------------------------------

pub struct Layout { pub ok: bool, pub size: u64, pub align: u64 }
pub struct RType { pub ok: bool, pub m: ModuleId, pub t: TypeId }
pub struct RecvRes { pub ok: bool, pub r: CeRecv }
pub struct ValRes { pub ok: bool, pub v: CeVal }
pub struct ObjRes { pub ok: bool, pub obj: u32 }
pub struct Rets { pub ok: bool, pub n: u8, pub vals: [CeVal; 8] }
pub struct FieldIdx { pub idx: i32, pub field: NodeId }
pub struct VarPos { pub pos: i32, pub enum_decl: NodeId }
pub struct OvfRes { pub ovf: bool, pub v: i64 }

// --- scalar helpers (no ce state) ---------------------------------------------------------------

fn bt_signed(b: BuiltinType) bool {
    return b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32
        || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
}
fn bt_unsigned(b: BuiltinType) bool {
    return b == BuiltinType::BT_U8 || b == BuiltinType::BT_U16 || b == BuiltinType::BT_U32
        || b == BuiltinType::BT_U64 || b == BuiltinType::BT_USIZE || b == BuiltinType::BT_CHAR;
}
fn bt_bits(b: BuiltinType) i32 {
    if b == BuiltinType::BT_BOOL || b == BuiltinType::BT_CHAR || b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 { return 8; }
    if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 { return 16; }
    if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 { return 32; }
    return 64;
}

fn wrap_to(b: BuiltinType, v: i64) i64 {
    let bits = bt_bits(b);
    if bits == 64 { return v; }
    let mask = ((1u64 << (bits as u64)) - 1u64);
    let mut u = (v as u64) & mask;
    if bt_signed(b) && (u >> ((bits - 1) as u64)) != 0 { u = u | (~mask); }
    return u as i64;
}

fn fits(b: BuiltinType, v: i64) bool { return wrap_to(b, v) == v; }

fn ce_isfinite(x: f64) bool { return unsafe math::fabs(x) <= F64_MAX; }

// non-trapping (u64-wrapping) checked signed arithmetic; ovf=true means the result overflows i64
fn add_ovf(a: i64, b: i64) OvfRes {
    let s = ((a as u64) + (b as u64)) as i64;
    return OvfRes { ovf: ((a ^ s) & (b ^ s)) < 0, v: s };
}
fn sub_ovf(a: i64, b: i64) OvfRes {
    let d = ((a as u64) - (b as u64)) as i64;
    return OvfRes { ovf: ((a ^ b) & (a ^ d)) < 0, v: d };
}
fn mul_ovf(a: i64, b: i64) OvfRes {
    let p = ((a as u64) * (b as u64)) as i64;
    let mut ovf = false;
    if a > 0 {
        if b > 0 { ovf = a > I64_MAX / b; }
        else { ovf = b < I64_MIN / a; }
    } else if a < 0 {
        if b > 0 { ovf = a < I64_MIN / b; }
        else { ovf = a != 0 && b < I64_MAX / a; }
    }
    return OvfRes { ovf: ovf, v: p };
}

// --- ConstEval methods --------------------------------------------------------------------------

extend ConstEval {
    pub fn new(pkg: *mut loader::Package, max_steps: u32, max_mem_bytes: u64) ConstEval {
        let count = unsafe (*pkg).modules.len();
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
            live_slots: 0,
            trap: "",
            pending: Vector::<CePending>::new(),
            calls: Map::<CeCallKey, CeCallHit>::new(),
            ufree: Vector::<UFree>::new(),
        };
        for _ in 0..count { ce.vals.push(Vector::<ConstValue>::new()); }
        return ce;
    }

    // ---- ast / source access (raw pointers; deref under unsafe, mirroring the C const-view) ----

    fn ast_ptr(self: &Self, m: ModuleId) *const Ast {
        // While a stage holds module `m`'s Ast (moved out of the slot), read the in-flight Ast it points at.
        if m == unsafe (*self.pkg).override_mod && unsafe (*self.pkg).override_ast != null { return unsafe (*self.pkg).override_ast as *const Ast; }
        return unsafe ((&(*self.pkg).modules[m as usize].ast) as *const Ast);
    }
    fn mut_ast_ptr(self: &Self, m: ModuleId) *mut Ast {
        if m == unsafe (*self.pkg).override_mod && unsafe (*self.pkg).override_ast != null { return unsafe (*self.pkg).override_ast; }
        return unsafe ((&mut (*self.pkg).modules[m as usize].ast) as *mut Ast);
    }
    fn has_ast(self: &Self, m: ModuleId) bool {
        if (m as usize) >= self.nmods { return false; }
        return unsafe (*self.pkg).modules[m as usize].has_ast;
    }
    fn ce_src(self: &Self, m: ModuleId) *const u8 {
        return unsafe (*self.pkg).modules[m as usize].source.as_str().ptr();
    }
    fn is_prelude(self: &Self, m: ModuleId) bool {
        return unsafe (*self.pkg).modules[m as usize].prelude;
    }

    // ast_type, safe on a module the checker hasn't reached (types table may not cover id yet).
    fn ce_type(self: &Self, m: ModuleId, id: NodeId) TypeId {
        let a = self.ast_ptr(m);
        if unsafe (*a).types.len() > (id as usize) { return unsafe (*a).type_of(id); }
        return TYPE_NONE;
    }

    fn ce_trap(self: &mut Self, msg: str) void {
        if self.trap.len() == 0 { self.trap = msg; }
    }
    fn ce_tick(self: &mut Self) bool {
        self.steps = self.steps + 1;
        if self.steps > self.max_steps { self.ce_trap("const-eval step budget exceeded"); return false; }
        return true;
    }

    // ---- memo ----
    fn slot_get(self: &Self, m: ModuleId, id: NodeId) ConstValue {
        if (m as usize) >= self.vals.len() { return ce_none(); }
        let inner = self.vals.at(m as usize);
        if (id as usize) >= inner.len() { return ce_none(); }
        return inner[id as usize];
    }
    fn slot_set(self: &mut Self, m: ModuleId, id: NodeId, v: ConstValue) void {
        if (m as usize) >= self.vals.len() { return; }
        let inner = &mut self.vals[m as usize];
        while inner.len() <= (id as usize) { inner.push(ce_none()); }
        inner.set(id as usize, v);
    }

    // ---- spans ----
    fn ce_spans_eq(self: &Self, ma: ModuleId, a: tok::Span, mb: ModuleId, b: tok::Span) bool {
        let la = a.end - a.start;
        if la != b.end - b.start { return false; }
        return unsafe cstring::memcmp((self.ce_src(ma) + a.start as usize),
                                      (self.ce_src(mb) + b.start as usize), la as usize) == 0;
    }
    fn ce_span_is(self: &Self, m: ModuleId, s: tok::Span, lit: str) bool {
        let n = lit.len();
        if (s.end - s.start) as usize != n { return false; }
        return unsafe cstring::memcmp((self.ce_src(m) + s.start as usize), lit.ptr(), n) == 0;
    }
    fn name_text(self: &Self, m: ModuleId, name_node: NodeId) tok::Span {
        let a = self.ast_ptr(m);
        return unsafe (*a).at_const(name_node).as_data.name.text;
    }
}

fn if_default_steps(s: u32) u32 { if s != 0 { return s; } return CE_DEFAULT_STEPS; }
fn if_default_slots(b: u64) u64 { if b != 0 { let s = b / (sizeof(CeVal) as u64); if s != 0 { return s; } return 1; } return CE_DEFAULT_SLOTS; }

fn type_builtin(a: *const Ast, t: TypeId) BuiltinType {
    if t == TYPE_NONE { return BuiltinType::BT_COUNT; }
    let y = unsafe (*a).type_at(t);
    if y.kind == TypeKind::TYPE_BUILTIN { return y.as_data.builtin; }
    return BuiltinType::BT_COUNT;
}

fn round_up(v: u64, a: u64) u64 { if a != 0 { return (v + a - 1) / a * a; } return v; }

fn hexval(ch: u8) i32 {
    if ch >= '0' as u8 && ch <= '9' as u8 { return (ch - '0' as u8) as i32; }
    if ch >= 'a' as u8 && ch <= 'f' as u8 { return (ch - 'a' as u8 + 10u8) as i32; }
    if ch >= 'A' as u8 && ch <= 'F' as u8 { return (ch - 'A' as u8 + 10u8) as i32; }
    return -1;
}

// --- literal parsing + layout engine ------------------------------------------------------------

extend ConstEval {
    fn eval_int_literal(self: &Self, m: ModuleId, id: NodeId) ConstValue {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = unsafe (*a).at_const(id).as_data.literal.raw;
        let mut endd = sp.end;
        unsafe ast_numeric_suffix(src, sp.start, sp.end, (&mut endd) as *mut u32);
        let mut v: u64 = 0;
        let mut i = sp.start;
        let mut base: u64 = 10;
        if sp.end - sp.start > 2 && unsafe src[i as usize] == '0' as u8 {
            let r = unsafe src[(i + 1) as usize];
            if r == 'x' as u8 || r == 'X' as u8 { base = 16; i = i + 2; }
            else if r == 'b' as u8 || r == 'B' as u8 { base = 2; i = i + 2; }
            else if r == 'o' as u8 || r == 'O' as u8 { base = 8; i = i + 2; }
        }
        while i < endd {
            let ch = unsafe src[i as usize];
            if ch == '_' as u8 { i = i + 1; continue; }
            let d = hexval(ch);
            if d < 0 || (d as u64) >= base { return ce_none(); }
            if v > (U64_MAX - (d as u64)) / base { return ce_none(); }
            v = v * base + (d as u64);
            i = i + 1;
        }
        let b = type_builtin(a, self.ce_type(m, id));
        let sv = v as i64;
        if b != BuiltinType::BT_COUNT && !fits(b, sv) { return ce_none(); }
        return ConstValue { kind: CONST_INT, ty: self.ce_type(m, id), as_data: ConstValueAs { i: sv } };
    }

    fn eval_char_literal(self: &Self, m: ModuleId, id: NodeId) ConstValue {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = unsafe (*a).at_const(id).as_data.literal.raw;
        let mut i = sp.start + 1;
        if unsafe src[sp.start as usize] == 'b' as u8 { i = i + 1; }
        if i >= sp.end { return ce_none(); }
        let mut v: i64 = 0;
        if unsafe src[i as usize] != '\\' as u8 {
            v = unsafe src[i as usize] as i64;
        } else {
            let e = unsafe src[(i + 1) as usize];
            switch e {
                'n' => { v = 10; },
                't' => { v = 9; },
                'r' => { v = 13; },
                '0' => { v = 0; },
                '\\' => { v = 92; },
                '\'' => { v = 39; },
                '"' => { v = 34; },
                'x' => {
                    v = 0;
                    let mut k = i + 2;
                    while k < sp.end - 1 {
                        let d = hexval(unsafe src[k as usize]);
                        if d < 0 { return ce_none(); }
                        v = v * 16 + (d as i64);
                        k = k + 1;
                    }
                },
                _ => { return ce_none(); },
            };
        }
        return ConstValue { kind: CONST_INT, ty: self.ce_type(m, id), as_data: ConstValueAs { i: v } };
    }

    fn eval_float_literal(self: &Self, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = unsafe (*a).at_const(id).as_data.literal.raw;
        let mut buf = Buf64 {};
        let mut k: usize = 0;
        let mut i = sp.start;
        while i < sp.end && k + 1 < 64 {
            if unsafe src[i as usize] != '_' as u8 { buf.b[k] = unsafe src[i as usize] as char; k = k + 1; }
            i = i + 1;
        }
        buf.b[k] = 0 as char;
        let mut v = unsafe stdlib::strtod((&buf.b[0]) as *const char, null);
        let b = type_builtin(a, self.ce_type(m, id));
        if b == BuiltinType::BT_F32 { v = (v as f32) as f64; }
        else if b != BuiltinType::BT_F64 && b != BuiltinType::BT_COUNT { return cv_nil(); }
        return CeVal { kind: CV_FLOAT, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { f: v } };
    }

    // ---- layout engine ----
    fn ce_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) *const Attr {
        let a = self.ast_ptr(m);
        for i in 0..unsafe (*a).attrs.len() {
            let at = unsafe (*a).attrs.at(i);
            if at.owner == owner && at.kind == (kind as u8) { return at as *const Attr; }
        }
        return null;
    }

    // Accumulate one field into `acc`; false = unfoldable.
    fn acc_field(self: &mut Self, acc: *mut LayoutAcc, m: ModuleId, ft: TypeId, env: *const LayoutEnv, depth: i32) bool {
        let fl = self.layout_of(m, ft, env, depth);
        if !fl.ok { return false; }
        let mut fa = fl.align;
        if unsafe (*acc).packed { fa = 1; }
        if unsafe (*acc).is_union {
            if fl.size > unsafe (*acc).size { unsafe (*acc).size = fl.size; }
        } else {
            unsafe (*acc).size = round_up(unsafe (*acc).size, fa) + fl.size;
        }
        if fa > unsafe (*acc).align { unsafe (*acc).align = fa; }
        return true;
    }

    fn aggregate_layout(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, depth: i32) Layout {
        let a = self.ast_ptr(dm);
        let dkind = unsafe (*a).at_const(dn).kind;
        if dkind == NodeKind::NODE_ENUM {
            let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
            let mut payload = false;
            for i in 0..ms.len {
                let mid = unsafe ((*a).list(ms))[i as usize];
                if unsafe (*a).at_const(mid).as_data.variant.payload.len > 0 { payload = true; }
            }
            if !payload { return Layout { ok: true, size: 4, align: 4 }; }
            let mut un = LayoutAcc { is_union: true };
            for i in 0..ms.len {
                let mid = unsafe ((*a).list(ms))[i as usize];
                let pl = unsafe (*a).at_const(mid).as_data.variant.payload;
                if pl.len == 0 { continue; }
                let struct_payload = unsafe (*a).at_const(mid).as_data.variant.struct_payload;
                let mut vs = LayoutAcc { };
                for k in 0..pl.len {
                    let pid = unsafe ((*a).list(pl))[k as usize];
                    let mut tn = pid;
                    if struct_payload { tn = unsafe (*a).at_const(pid).as_data.field.ty; }
                    if !self.acc_field((&mut vs) as *mut LayoutAcc, dm, self.ce_type(dm, tn), env, depth) {
                        return Layout { ok: false };
                    }
                }
                vs.size = round_up(vs.size, vs.align);
                if vs.size > un.size { un.size = vs.size; }
                if vs.align > un.align { un.align = vs.align; }
            }
            let mut ssize = round_up(4, un.align) + un.size;
            let mut salign: u64 = 4;
            if un.align > salign { salign = un.align; }
            return Layout { ok: true, size: round_up(ssize, salign), align: salign };
        }
        if dkind != NodeKind::NODE_STRUCT { return Layout { ok: false }; }
        let is_union = unsafe (*a).at_const(dn).as_data.aggregate.is_union;
        let is_tuple = unsafe (*a).at_const(dn).as_data.aggregate.is_tuple;
        let mut acc = LayoutAcc { is_union: is_union };
        acc.packed = self.ce_attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let fs = unsafe (*a).at_const(dn).as_data.aggregate.members;
        for i in 0..fs.len {
            let fid = unsafe ((*a).list(fs))[i as usize];
            let fkind = unsafe (*a).at_const(fid).kind;
            if !is_tuple && fkind != NodeKind::NODE_FIELD { continue; }
            let mut ftn = fid;
            if !is_tuple { ftn = unsafe (*a).at_const(fid).as_data.field.ty; }
            let ft = self.ce_type(dm, ftn);
            if ft == TYPE_NONE { return Layout { ok: false }; }
            if !self.acc_field((&mut acc) as *mut LayoutAcc, dm, ft, env, depth) { return Layout { ok: false }; }
        }
        let al = self.ce_attr(dm, dn, AttrKind::ATTR_ALIGN);
        if al != null && unsafe (*al).arg != 0 {
            if (unsafe (*al).arg as u64) > acc.align { acc.align = unsafe (*al).arg as u64; }
        }
        if acc.align == 0 { acc.align = 1; }
        return Layout { ok: true, size: round_up(acc.size, acc.align), align: acc.align };
    }

    fn layout_of(self: &mut Self, m: ModuleId, t: TypeId, env: *const LayoutEnv, depth: i32) Layout {
        if depth > CE_MAX_DEPTH || t == TYPE_NONE { return Layout { ok: false }; }
        if !self.has_ast(m) { return Layout { ok: false }; }
        let a = self.ast_ptr(m);
        let y = *unsafe (*a).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL || b == BuiltinType::BT_CHAR || b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 { return Layout { ok: true, size: 1, align: 1 }; }
            if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 { return Layout { ok: true, size: 2, align: 2 }; }
            if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_F32 { return Layout { ok: true, size: 4, align: 4 }; }
            if b == BuiltinType::BT_I64 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_ISIZE || b == BuiltinType::BT_USIZE || b == BuiltinType::BT_F64 { return Layout { ok: true, size: 8, align: 8 }; }
            if b == BuiltinType::BT_C32 { return Layout { ok: true, size: 8, align: 4 }; }
            if b == BuiltinType::BT_C64 { return Layout { ok: true, size: 16, align: 8 }; }
            return Layout { ok: false };
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_FUNCTION {
            return Layout { ok: true, size: 8, align: 8 };
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len == 0 { return Layout { ok: false }; }
            let el = self.layout_of(m, y.as_data.arr.elem, env, depth + 1);
            if !el.ok { return Layout { ok: false }; }
            return Layout { ok: true, size: el.size * (y.as_data.arr.len as u64), align: el.align };
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut e = env;
            while e != null {
                for i in 0..unsafe (*e).n {
                    if unsafe (*e).pmod == y.module && unsafe ((*e).params)[i as usize] == y.as_data.decl {
                        return self.layout_of(unsafe (*e).argm, unsafe (*e).args[i as usize], unsafe (*e).parent, depth + 1);
                    }
                }
                e = unsafe (*e).parent;
            }
            return Layout { ok: false };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.aggregate_layout(y.module, y.as_data.decl, null, depth + 1);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            if !self.has_ast(it.module) { return Layout { ok: false }; }
            let da = self.ast_ptr(it.module);
            let gens = unsafe (*da).at_const(it.decl).as_data.aggregate.generics;
            let mut frame = LayoutEnv { parent: env, pmod: it.module, params: unsafe (*da).list(gens), argm: m, n: 0 };
            let mut i: u32 = 0;
            while i < gens.len && (i as u8) < it.n && frame.n < 4 {
                frame.args[frame.n as usize] = it.args[i as usize];
                frame.n = frame.n + 1;
                i = i + 1;
            }
            return self.aggregate_layout(it.module, it.decl, (&frame) as *const LayoutEnv, depth + 1);
        }
        return Layout { ok: false };
    }

    pub fn layout(self: &mut Self, m: ModuleId, t: TypeId) Layout {
        return self.layout_of(m, t, null, 0);
    }

    // ---- type utilities ----

    // Resolve (m,t) through the frame's substitution while it names a generic param (one hop resolves).
    fn ce_rtype(self: &Self, f: *mut CeFrame, m0: ModuleId, t0: TypeId) RType {
        let mut m = m0;
        let mut t = t0;
        for _ in 0..8 {
            if t == TYPE_NONE { return RType { ok: false }; }
            let y = unsafe (*self.ast_ptr(m)).type_at(t);
            if y.kind != TypeKind::TYPE_GENERIC { return RType { ok: true, m: m, t: t }; }
            if f == null { return RType { ok: false }; }
            let ymod = y.module;
            let ydecl = y.as_data.decl;
            let mut found = false;
            for i in 0..unsafe (*f).ng {
                if unsafe (*f).pmod == ymod && unsafe (*f).params_g[i as usize] == ydecl {
                    m = unsafe (*f).am[i as usize];
                    t = unsafe (*f).at[i as usize];
                    found = true;
                    break;
                }
            }
            if !found { return RType { ok: false }; }
        }
        return RType { ok: false };
    }

    fn ce_builtin_of(self: &Self, f: *mut CeFrame, m: ModuleId, t: TypeId) BuiltinType {
        let r = self.ce_rtype(f, m, t);
        if !r.ok { return BuiltinType::BT_COUNT; }
        return type_builtin(self.ast_ptr(r.m), r.t);
    }

    fn ce_layout_f(self: &mut Self, f: *mut CeFrame, m: ModuleId, t: TypeId) Layout {
        if f == null { return self.layout_of(m, t, null, 0); }
        let mut envs: [LayoutEnv; 8] = [LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }, LayoutEnv { pmod: 0 }];
        let mut parent: *const LayoutEnv = null;
        for i in 0..unsafe (*f).ng {
            envs[i as usize] = LayoutEnv {
                parent: parent, pmod: unsafe (*f).pmod,
                params: unsafe ((&(*f).params_g[i as usize]) as *const NodeId),
                argm: unsafe (*f).am[i as usize], n: 1,
            };
            envs[i as usize].args[0] = unsafe (*f).at[i as usize];
            parent = (&envs[i as usize]) as *const LayoutEnv;
        }
        return self.layout_of(m, t, parent, 0);
    }

    // Structural cross-pool type equality.
    fn ce_teq(self: &Self, ma: ModuleId, ta: TypeId, mb: ModuleId, tb: TypeId) bool {
        if ta == TYPE_NONE || tb == TYPE_NONE { return false; }
        let aa = self.ast_ptr(ma);
        let ab = self.ast_ptr(mb);
        let a = *unsafe (*aa).type_at(ta);
        let b = *unsafe (*ab).type_at(tb);
        if a.kind != b.kind { return false; }
        if a.kind == TypeKind::TYPE_BUILTIN { return a.as_data.builtin == b.as_data.builtin; }
        if a.kind == TypeKind::TYPE_POINTER || a.kind == TypeKind::TYPE_REFERENCE {
            return a.qualifier == b.qualifier && self.ce_teq(ma, a.as_data.elem, mb, b.as_data.elem);
        }
        if a.kind == TypeKind::TYPE_ARRAY {
            return a.as_data.arr.len == b.as_data.arr.len && self.ce_teq(ma, a.as_data.arr.elem, mb, b.as_data.arr.elem);
        }
        if a.kind == TypeKind::TYPE_STRUCT || a.kind == TypeKind::TYPE_ENUM
            || a.kind == TypeKind::TYPE_GENERIC || a.kind == TypeKind::TYPE_OPAQUE {
            return a.module == b.module && a.as_data.decl == b.as_data.decl;
        }
        if a.kind == TypeKind::TYPE_INSTANCE {
            let ia = *unsafe (*aa).instance(a.as_data.inst);
            let ib = *unsafe (*ab).instance(b.as_data.inst);
            if ia.module != ib.module || ia.decl != ib.decl || ia.n != ib.n { return false; }
            for i in 0..ia.n {
                if !self.ce_teq(ma, ia.args[i as usize], mb, ib.args[i as usize]) { return false; }
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
            if !r.ok { return RType { ok: false }; }
            m = r.m;
            t = r.t;
            let y = unsafe (*self.ast_ptr(m)).type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
                return RType { ok: true, m: m, t: t };
            }
            t = y.as_data.elem;
        }
        return RType { ok: false };
    }

    // Deep substitution through the frame, re-interning into m's pool. TYPE_NONE = an unbound generic.
    fn ce_subst_deep(self: &mut Self, f: *mut CeFrame, m: ModuleId, t: TypeId, depth: i32) TypeId {
        if t == TYPE_NONE || depth > CE_MAX_DEPTH { return TYPE_NONE; }
        let am = self.mut_ast_ptr(m);
        let y = *unsafe (*am).type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            if f == null { return TYPE_NONE; }
            for i in 0..unsafe (*f).ng {
                if unsafe (*f).pmod == y.module && unsafe (*f).params_g[i as usize] == y.as_data.decl {
                    let fam = unsafe (*f).am[i as usize];
                    let fat = unsafe (*f).at[i as usize];
                    if fam == m { return fat; }
                    return unsafe (*am).reintern(unsafe (&*self.ast_ptr(fam)), fat);
                }
            }
            return TYPE_NONE;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.ce_subst_deep(f, m, y.as_data.elem, depth + 1);
            if e == TYPE_NONE { return TYPE_NONE; }
            if e == y.as_data.elem { return t; }
            let mut ny = y;
            if y.kind == TypeKind::TYPE_ARRAY { ny.as_data.arr = TyArr { elem: e, len: y.as_data.arr.len }; }
            else { ny.as_data.elem = e; }
            return unsafe (*self.mut_ast_ptr(m)).intern_type(ny);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*am).instance(y.as_data.inst);
            let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
            let mut changed = false;
            for i in 0..it.n {
                na[i as usize] = self.ce_subst_deep(f, m, it.args[i as usize], depth + 1);
                if na[i as usize] == TYPE_NONE { return TYPE_NONE; }
                if na[i as usize] != it.args[i as usize] { changed = true; }
            }
            if !changed { return t; }
            return unsafe (*self.mut_ast_ptr(m)).intern_instance(it.module, it.decl, (&na[0]) as *const TypeId, it.n);
        }
        return t;
    }

    fn ce_recv_of(self: &mut Self, f: *mut CeFrame, m0: ModuleId, t0: TypeId) RecvRes {
        let mut out = ce_recv_zero();
        let r = self.ce_rtype(f, m0, t0);
        if !r.ok { return RecvRes { ok: false, r: out }; }
        let m = r.m;
        let y = *unsafe (*self.ast_ptr(m)).type_at(r.t);
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
            let it = *unsafe (*self.ast_ptr(m)).instance(y.as_data.inst);
            out.dm = it.module;
            out.dn = it.decl;
            out.n = it.n;
            for i in 0..it.n {
                out.am[i as usize] = m;
                out.at[i as usize] = self.ce_subst_deep(f, m, it.args[i as usize], 0);
                if out.at[i as usize] == TYPE_NONE || !unsafe (*self.ast_ptr(m)).type_concrete(out.at[i as usize]) {
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
        let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
        let mut n: u32 = 0;
        for i in 0..ms.len {
            let mid = unsafe ((*a).list(ms))[i as usize];
            if unsafe (*a).at_const(mid).kind == NodeKind::NODE_FIELD { n = n + 1; }
        }
        return n;
    }

    fn ce_field_index(self: &Self, dm: ModuleId, dn: NodeId, nm: ModuleId, name: tok::Span) FieldIdx {
        let a = self.ast_ptr(dm);
        let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
        let mut idx: i32 = 0;
        for i in 0..ms.len {
            let fid = unsafe ((*a).list(ms))[i as usize];
            if unsafe (*a).at_const(fid).kind == NodeKind::NODE_FIELD {
                let fname = self.name_text(dm, unsafe (*a).at_const(fid).as_data.field.name);
                if self.ce_spans_eq(dm, fname, nm, name) { return FieldIdx { idx: idx, field: fid }; }
                idx = idx + 1;
            }
        }
        return FieldIdx { idx: -1, field: NODE_NONE };
    }

    fn ce_enum_tagged(self: &Self, dm: ModuleId, dn: NodeId) bool {
        let a = self.ast_ptr(dm);
        let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe ((*a).list(ms))[i as usize];
            if unsafe (*a).at_const(mid).as_data.variant.payload.len > 0 { return true; }
        }
        return false;
    }

    fn ce_variant_pos(self: &Self, vm: ModuleId, vd: NodeId) VarPos {
        let a = self.ast_ptr(vm);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = unsafe (*a).at_const(iid).as_data.aggregate.members;
                for k in 0..ms.len {
                    let mid = unsafe ((*a).list(ms))[k as usize];
                    if mid == vd { return VarPos { pos: k as i32, enum_decl: iid }; }
                }
            }
        }
        return VarPos { pos: -1, enum_decl: NODE_NONE };
    }

    fn ce_variant_named(self: &Self, dm: ModuleId, dn: NodeId, lit: str) i32 {
        let a = self.ast_ptr(dm);
        let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe ((*a).list(ms))[i as usize];
            let vname = self.name_text(dm, unsafe (*a).at_const(mid).as_data.variant.name);
            if self.ce_span_is(dm, vname, lit) { return i as i32; }
        }
        return -1;
    }

    // The TypeId of nominal decl (dm,dn) in its OWN pool; TYPE_NONE if absent.
    fn ce_pool_find_type(self: &Self, dm: ModuleId, dn: NodeId) TypeId {
        let a = self.ast_ptr(dm);
        let mut t: TypeId = 1;
        while (t as usize) < unsafe (*a).type_pool.len() {
            let y = unsafe (*a).type_at(t);
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
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            let ik = unsafe (*a).at_const(iid).kind;
            let mut ms = NodeList { start: 0, len: 0 };
            let mut is_ext = false;
            if ik == NodeKind::NODE_EXTEND { ms = unsafe (*a).at_const(iid).as_data.extend_def.items; is_ext = true; }
            else if ik == NodeKind::NODE_INTERFACE { ms = unsafe (*a).at_const(iid).as_data.interface_def.items; }
            else { continue; }
            for k in 0..ms.len {
                let mid = unsafe ((*a).list(ms))[k as usize];
                if mid == fnode {
                    if out != null { unsafe *out = iid; }
                    if is_ext { return 1; }
                    return 2;
                }
            }
        }
        return 0;
    }

    // Find method name/lit on receiver r: scan extends in the decl's module, then scope, then (builtins) all.
    fn ce_find_method(self: &Self, r: CeRecv, scope: ModuleId, nm: ModuleId, name: tok::Span, lit: str,
                      extend_out: *mut NodeId) DefId {
        let mut first = scope;
        if r.dn != NODE_NONE { first = r.dm; }
        for s in 0..(self.nmods + 2) {
            let mut mm: ModuleId = 0;
            if s == 0 { mm = first; }
            else if s == 1 { mm = scope; }
            else if r.dn == NODE_NONE { mm = (s - 2) as ModuleId; }
            else { break; }
            if s == 1 && mm == first { continue; }
            if !self.has_ast(mm) { continue; }
            let a = self.ast_ptr(mm);
            if unsafe (*a).nodes.len() == 0 { continue; }
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe ((*a).list(items))[i as usize];
                let target = unsafe (*a).at_const(iid).as_data.extend_def.target_type;
                if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND && target != NODE_NONE {
                    let mut match_recv = false;
                    if r.dn != NODE_NONE {
                        let tg = unsafe (*a).resolution_def(target);
                        match_recv = tg.module == r.dm && tg.node == r.dn;
                    } else {
                        let tt = self.ce_type(mm, target);
                        if tt != TYPE_NONE {
                            let ty = unsafe (*self.ast_ptr(mm)).type_at(tt);
                            match_recv = ty.kind == TypeKind::TYPE_BUILTIN && ty.as_data.builtin == r.b;
                        }
                    }
                    if match_recv {
                        let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                        for k in 0..ms.len {
                            let mid = unsafe ((*a).list(ms))[k as usize];
                            if unsafe (*a).at_const(mid).kind == NodeKind::NODE_FUNCTION {
                                let mname = self.name_text(mm, unsafe (*a).at_const(mid).as_data.function.name);
                                let mut hit = false;
                                if lit.len() != 0 { hit = self.ce_span_is(mm, mname, lit); }
                                else { hit = self.ce_spans_eq(mm, mname, nm, name); }
                                if hit {
                                    if extend_out != null { unsafe *extend_out = iid; }
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
            if u.m == dm && u.n == dn { return u.user; }
        }
        let mut user = false;
        let mut mm: usize = 0;
        while mm < self.nmods && !user {
            if !self.is_prelude(mm as ModuleId) && self.has_ast(mm as ModuleId) {
                let a = self.ast_ptr(mm as ModuleId);
                if unsafe (*a).nodes.len() != 0 {
                    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
                    let mut ii: u32 = 0;
                    while ii < items.len && !user {
                        let iid = unsafe ((*a).list(items))[ii as usize];
                        let target = unsafe (*a).at_const(iid).as_data.extend_def.target_type;
                        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND && target != NODE_NONE {
                            let tg = unsafe (*a).resolution_def(target);
                            if tg.module == dm && tg.node == dn {
                                let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                                for k in 0..ms.len {
                                    let mid = unsafe ((*a).list(ms))[k as usize];
                                    if unsafe (*a).at_const(mid).kind == NodeKind::NODE_FUNCTION {
                                        let mname = self.name_text(mm as ModuleId, unsafe (*a).at_const(mid).as_data.function.name);
                                        if self.ce_span_is(mm as ModuleId, mname, "free") { user = true; break; }
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
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = unsafe (*a).at_const(iid).as_data.aggregate.members;
                let mut next: i64 = 0;
                for k in 0..ms.len {
                    let mid = unsafe ((*a).list(ms))[k as usize];
                    if unsafe (*a).at_const(mid).as_data.variant.payload.len > 0 { return ce_none(); }
                    let vval = unsafe (*a).at_const(mid).as_data.variant.value;
                    if vval != NODE_NONE {
                        let e = self.eval(vm, vval);
                        if e.kind != CONST_INT { return ce_none(); }
                        next = e.as_data.i;
                    }
                    if mid == vd { return ConstValue { kind: CONST_INT, ty: TYPE_NONE, as_data: ConstValueAs { i: next } }; }
                    next = next + 1;
                }
            }
        }
        return ce_none();
    }

    // ---- object store ----
    fn ce_objs_reset(self: &mut Self) void {
        self.objs.clear();
        self.live_slots = 0;
    }

    fn obj_ptr(self: &Self, id: u32) *mut CeObj {
        if id == 0 || (id as usize) > self.objs.len() { return null; }
        return unsafe (((self.objs.as_ptr() as *mut CeObj) + ((id - 1) as usize)));
    }

    fn ce_obj_new(self: &mut Self, len: u32) u32 {
        if self.objs.len() as u32 >= CE_MAX_OBJS || self.live_slots + (len as u64) > self.max_slots {
            self.ce_trap("const-eval memory budget exceeded");
            return 0;
        }
        let mut slots = Vector::<CeVal>::new();
        if len != 0 {
            slots.reserve(len as usize);
            for _ in 0..len { slots.push(cv_nil()); }
        }
        self.objs.push(CeObj { slots: slots });
        self.live_slots = self.live_slots + (len as u64);
        return self.objs.len() as u32;
    }

    fn ce_obj_resize(self: &mut Self, id: u32, len: u32) bool {
        let cur = unsafe (*self.obj_ptr(id)).slots.len() as u32;
        if len > cur && self.live_slots + ((len - cur) as u64) > self.max_slots {
            self.ce_trap("const-eval memory budget exceeded");
            return false;
        }
        let o = self.obj_ptr(id);
        if len > cur {
            let mut i = cur;
            while i < len { unsafe (*o).slots.push(cv_nil()); i = i + 1; }
            self.live_slots = self.live_slots + ((len - cur) as u64);
        } else if len < cur {
            unsafe (*o).slots.truncate(len as usize);
        }
        return true;
    }

    // ---- frames and values ----
    fn ce_bind_slot(self: &mut Self, f: *mut CeFrame, decl: NodeId) *mut CeVal {
        let i = ce_local_find(f, decl);
        let envid = unsafe (*f).env;
        if self.obj_ptr(envid) == null { return null; }
        if i >= 0 {
            let slotidx = unsafe (*f).locals[i as usize].slot;
            let o = self.obj_ptr(envid);
            return unsafe (((*o).slots.as_ptr() as *mut CeVal) + (slotidx as usize));
        }
        if unsafe (*f).n >= CE_MAX_LOCALS { return null; }
        let curlen = unsafe (*self.obj_ptr(envid)).slots.len() as u32;
        if !self.ce_obj_resize(envid, curlen + 1) { return null; }
        let n = unsafe (*f).n;
        unsafe (*f).locals[n as usize].decl = decl;
        unsafe (*f).locals[n as usize].slot = curlen;
        unsafe (*f).n = n + 1;
        let o = self.obj_ptr(envid);
        return unsafe (((*o).slots.as_ptr() as *mut CeVal) + (curlen as usize));
    }

    fn ce_bind(self: &mut Self, f: *mut CeFrame, decl: NodeId, v: CeVal) bool {
        let s = self.ce_bind_slot(f, decl);
        if s == null { return false; }
        let cv = self.ce_clone(v, 0);
        unsafe *s = cv;
        return v.kind == CV_NIL_K || unsafe (*s).kind != CV_NIL_K;
    }

    // Deep copy: aggregates get fresh objects (pointer members stay shared); scalars copy by value.
    fn ce_clone(self: &mut Self, v: CeVal, depth: i32) CeVal {
        if v.kind != CV_AGG || depth > CE_MAX_DEPTH {
            if v.kind == CV_AGG && depth > CE_MAX_DEPTH { return cv_nil(); }
            return v;
        }
        let srcp = self.obj_ptr(v.as_data.p.obj);
        if srcp == null || unsafe (*srcp).dead != 0 { return cv_nil(); }
        let srclen = unsafe (*srcp).slots.len() as u32;
        let id = self.ce_obj_new(srclen);
        if id == 0 { return cv_nil(); }
        let src = self.obj_ptr(v.as_data.p.obj);
        let dst = self.obj_ptr(id);
        unsafe {
            (*dst).dead = (*src).dead;
            (*dst).is_enum = (*src).is_enum;
            (*dst).heap = (*src).heap;
            (*dst).dm = (*src).dm;
            (*dst).dn = (*src).dn;
            (*dst).nargs = (*src).nargs;
            (*dst).bytes = (*src).bytes;
            (*dst).em = (*src).em;
            (*dst).et = (*src).et;
            (*dst).esz = (*src).esz;
            for j in 0..4 {
                (*dst).am[j] = (*src).am[j];
                (*dst).at[j] = (*src).at[j];
            }
        }
        for i in 0..srclen {
            let sv = unsafe (*self.obj_ptr(v.as_data.p.obj)).slots[i as usize];
            let cloned = self.ce_clone(sv, depth + 1);
            if sv.kind != CV_NIL_K && cloned.kind == CV_NIL_K { return cv_nil(); }
            unsafe (*self.obj_ptr(id)).slots.set(i as usize, cloned);
        }
        let mut out = v;
        out.as_data.p.obj = id;
        return out;
    }

    fn ce_loadp(self: &mut Self, p: CeVal) ValRes {
        if p.kind != CV_PTR { return ValRes { ok: false }; }
        if p.as_data.p.obj == 0 { self.ce_trap("null dereference"); return ValRes { ok: false }; }
        let o = self.obj_ptr(p.as_data.p.obj);
        if o == null { return ValRes { ok: false }; }
        if unsafe (*o).dead != 0 { self.ce_trap("use after free"); return ValRes { ok: false }; }
        if (p.as_data.p.off as usize) >= unsafe (*o).slots.len() { self.ce_trap("out-of-bounds access"); return ValRes { ok: false }; }
        let out = unsafe (*o).slots[p.as_data.p.off as usize];
        return ValRes { ok: out.kind != CV_NIL_K, v: out };
    }

    fn ce_storep(self: &mut Self, p: CeVal, v: CeVal) bool {
        if p.kind != CV_PTR || v.kind == CV_NIL_K { return false; }
        if p.as_data.p.obj == 0 { self.ce_trap("null dereference"); return false; }
        let cv = self.ce_clone(v, 0);
        if cv.kind == CV_NIL_K { return false; }
        let o = self.obj_ptr(p.as_data.p.obj);
        if o == null { return false; }
        if unsafe (*o).dead != 0 { self.ce_trap("use after free"); return false; }
        if (p.as_data.p.off as usize) >= unsafe (*o).slots.len() { self.ce_trap("out-of-bounds access"); return false; }
        unsafe (*o).slots.set(p.as_data.p.off as usize, cv);
        return true;
    }

    fn ce_temp_place(self: &mut Self, v: CeVal) ValRes {
        let id = self.ce_obj_new(1);
        if id == 0 || v.kind == CV_NIL_K { return ValRes { ok: false }; }
        unsafe (*self.obj_ptr(id)).slots.set(0, v);
        return ValRes { ok: true, v: CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: id, off: 0 } } } };
    }

    fn ce_zero(self: &mut Self, m: ModuleId, t: TypeId, depth: i32) CeVal {
        if depth > CE_MAX_DEPTH || t == TYPE_NONE { return cv_nil(); }
        let y = *unsafe (*self.ast_ptr(m)).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL { return CeVal { kind: CV_BOOL, tm: m, ty: t, as_data: CeValAs { i: 0 } }; }
            if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 { return CeVal { kind: CV_FLOAT, tm: m, ty: t, as_data: CeValAs { f: 0.0 } }; }
            if b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64 || b == BuiltinType::BT_VALIST || b == BuiltinType::BT_VOID { return cv_nil(); }
            return CeVal { kind: CV_INT, tm: m, ty: t, as_data: CeValAs { i: 0 } };
        }
        if y.kind == TypeKind::TYPE_POINTER {
            return CeVal { kind: CV_PTR, tm: m, ty: t, as_data: CeValAs { p: CvPtr { obj: 0, off: 0 } } };
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len == 0 { return cv_nil(); }
            let id = self.ce_obj_new(y.as_data.arr.len);
            if id == 0 { return cv_nil(); }
            let ez = self.ce_zero(m, y.as_data.arr.elem, depth + 1);
            if ez.kind == CV_NIL_K { return cv_nil(); }
            let alen = unsafe (*self.obj_ptr(id)).slots.len() as u32;
            for i in 0..alen {
                let cloned = self.ce_clone(ez, depth + 1);
                unsafe (*self.obj_ptr(id)).slots.set(i as usize, cloned);
            }
            return CeVal { kind: CV_AGG, tm: m, ty: t, as_data: CeValAs { p: CvPtr { obj: id, off: 0 } } };
        }
        return cv_nil();
    }

    // ---- scalar ops ----
    fn ce_int_op(self: &mut Self, op: TokenType, l: CeVal, r: CeVal, tm: ModuleId, rt: TypeId, b: BuiltinType, ob: BuiltinType) CeVal {
        let uns = ob != BuiltinType::BT_COUNT && bt_unsigned(ob);
        if op == TokenType::EqualEqual { return cv_bool(tm, rt, l.as_data.i == r.as_data.i); }
        if op == TokenType::BangEqual { return cv_bool(tm, rt, l.as_data.i != r.as_data.i); }
        if op == TokenType::LessThan { return cv_bool(tm, rt, if_bool(uns, (l.as_data.i as u64) < (r.as_data.i as u64), l.as_data.i < r.as_data.i)); }
        if op == TokenType::LessThanEqual { return cv_bool(tm, rt, if_bool(uns, (l.as_data.i as u64) <= (r.as_data.i as u64), l.as_data.i <= r.as_data.i)); }
        if op == TokenType::GreaterThan { return cv_bool(tm, rt, if_bool(uns, (l.as_data.i as u64) > (r.as_data.i as u64), l.as_data.i > r.as_data.i)); }
        if op == TokenType::GreaterThanEqual { return cv_bool(tm, rt, if_bool(uns, (l.as_data.i as u64) >= (r.as_data.i as u64), l.as_data.i >= r.as_data.i)); }
        let mut bits = 64;
        if ob != BuiltinType::BT_COUNT { bits = bt_bits(ob); }
        let mut v: i64 = 0;
        if uns {
            let ul = l.as_data.i as u64;
            let ur = r.as_data.i as u64;
            let mut u: u64 = 0;
            switch op {
                Plus => { u = ul + ur; },
                Minus => { u = ul - ur; },
                Star => { u = ul * ur; },
                Slash => { if ur == 0 { self.ce_trap("division by zero"); return cv_nil(); } u = ul / ur; },
                Percent => { if ur == 0 { self.ce_trap("division by zero"); return cv_nil(); } u = ul % ur; },
                Ampersand => { u = ul & ur; },
                Pipe => { u = ul | ur; },
                Caret => { u = ul ^ ur; },
                LeftShift => { if r.as_data.i < 0 || r.as_data.i >= (bits as i64) { self.ce_trap("shift out of range"); return cv_nil(); } u = ul << (r.as_data.i as u64); },
                RightShift => { if r.as_data.i < 0 || r.as_data.i >= (bits as i64) { self.ce_trap("shift out of range"); return cv_nil(); } u = ul >> (r.as_data.i as u64); },
                _ => { return cv_nil(); },
            };
            v = wrap_to(ob, u as i64);
            return CeVal { kind: CV_INT, tm: tm, ty: rt, as_data: CeValAs { i: v } };
        }
        let li = l.as_data.i;
        let ri = r.as_data.i;
        let mut type_min = I64_MIN;
        if bits != 64 { type_min = -(((1u64 << ((bits - 1) as u64)) as i64)); }
        switch op {
            Plus => { let o = add_ovf(li, ri); if o.ovf { self.ce_trap("arithmetic overflow"); return cv_nil(); } v = o.v; },
            Minus => { let o = sub_ovf(li, ri); if o.ovf { self.ce_trap("arithmetic overflow"); return cv_nil(); } v = o.v; },
            Star => { let o = mul_ovf(li, ri); if o.ovf { self.ce_trap("arithmetic overflow"); return cv_nil(); } v = o.v; },
            Slash => {
                if ri == 0 { self.ce_trap("division by zero"); return cv_nil(); }
                if ri == -1 && li == type_min { self.ce_trap("arithmetic overflow"); return cv_nil(); }
                v = li / ri;
            },
            Percent => {
                if ri == 0 { self.ce_trap("division by zero"); return cv_nil(); }
                if ri == -1 && li == type_min { self.ce_trap("arithmetic overflow"); return cv_nil(); }
                v = li % ri;
            },
            Ampersand => { v = li & ri; },
            Pipe => { v = li | ri; },
            Caret => { v = li ^ ri; },
            LeftShift => {
                if ri < 0 || ri >= (bits as i64) { self.ce_trap("shift out of range"); return cv_nil(); }
                v = wrap_to(ob, ((li as u64) << (ri as u64)) as i64);
            },
            RightShift => {
                if ri < 0 || ri >= (bits as i64) { self.ce_trap("shift out of range"); return cv_nil(); }
                v = li >> ri;
            },
            _ => { return cv_nil(); },
        };
        if b != BuiltinType::BT_COUNT && !fits(b, v) {
            if bt_signed(b) { self.ce_trap("arithmetic overflow"); }
            return cv_nil();
        }
        return CeVal { kind: CV_INT, tm: tm, ty: rt, as_data: CeValAs { i: v } };
    }

    fn eval_str_literal(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let src = self.ce_src(m);
        let sp = unsafe (*a).at_const(id).as_data.literal.raw;
        let raw = unsafe (*a).at_const(id).as_data.literal.token_type == TokenType::RawStringLiteral;
        let mut i = sp.start;
        let mut hashes: u32 = 0;
        while i < sp.end && unsafe src[i as usize] != '"' as u8 {
            if unsafe src[i as usize] == '#' as u8 { hashes = hashes + 1; }
            i = i + 1;
        }
        if i >= sp.end { return cv_nil(); }
        i = i + 1;
        let mut endpos = sp.end - 1;
        if raw { endpos = endpos - hashes; }
        let mut bytes = Buf4096 {};
        let mut nb: u32 = 0;
        while i < endpos {
            if nb >= 4096 { return cv_nil(); }
            let mut c = unsafe src[i as usize];
            i = i + 1;
            if !raw && c == '\\' as u8 && i < endpos {
                let e = unsafe src[i as usize];
                i = i + 1;
                switch e {
                    'n' => { c = 10u8; },
                    't' => { c = 9u8; },
                    'r' => { c = 13u8; },
                    '0' => { c = 0u8; },
                    '\\' => { c = 92u8; },
                    '"' => { c = 34u8; },
                    '\'' => { c = 39u8; },
                    _ => { return cv_nil(); },
                };
            }
            bytes.b[nb as usize] = c;
            nb = nb + 1;
        }
        let rr = self.ce_recv_of(f, m, self.ce_type(m, id));
        if !rr.ok || rr.r.dn == NODE_NONE { return cv_nil(); }
        let block = self.ce_obj_new(nb);
        if block == 0 && nb != 0 { return cv_nil(); }
        if nb != 0 {
            let bo = self.obj_ptr(block);
            unsafe (*bo).heap = 1;
            unsafe (*bo).bytes = nb as u64;
            unsafe (*bo).em = 0;
            unsafe (*bo).et = Ast::builtin(BuiltinType::BT_U8);
            unsafe (*bo).esz = 1;
            for k in 0..nb {
                unsafe (*self.obj_ptr(block)).slots.set(k as usize, CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_U8), as_data: CeValAs { i: bytes.b[k as usize] as i64 } });
            }
        }
        let so = self.ce_obj_new(self.ce_field_count(rr.r.dm, rr.r.dn));
        if so == 0 { return cv_nil(); }
        unsafe (*self.obj_ptr(so)).dm = rr.r.dm;
        unsafe (*self.obj_ptr(so)).dn = rr.r.dn;
        // locate ptr/len fields by name
        let da = self.ast_ptr(rr.r.dm);
        let dms = unsafe (*da).at_const(rr.r.dn).as_data.aggregate.members;
        let mut ptr_i: i32 = -1;
        let mut len_i: i32 = -1;
        let mut idx: i32 = 0;
        for kk in 0..dms.len {
            let fid = unsafe ((*da).list(dms))[kk as usize];
            if unsafe (*da).at_const(fid).kind == NodeKind::NODE_FIELD {
                let fn2 = self.name_text(rr.r.dm, unsafe (*da).at_const(fid).as_data.field.name);
                if self.ce_span_is(rr.r.dm, fn2, "ptr") { ptr_i = idx; }
                else if self.ce_span_is(rr.r.dm, fn2, "len") { len_i = idx; }
                idx = idx + 1;
            }
        }
        if ptr_i < 0 || len_i < 0 { return cv_nil(); }
        unsafe (*self.obj_ptr(so)).slots.set(ptr_i as usize, CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: block, off: 0 } } });
        unsafe (*self.obj_ptr(so)).slots.set(len_i as usize, CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: nb as i64 } });
        return CeVal { kind: CV_AGG, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
    }
}

fn ce_local_find(f: *mut CeFrame, decl: NodeId) i32 {
    let mut i = unsafe (*f).n;
    while i > 0 {
        i = i - 1;
        if unsafe (*f).locals[i as usize].decl == decl { return i as i32; }
    }
    return -1;
}

fn cv_bool(tm: ModuleId, rt: TypeId, b: bool) CeVal {
    let mut i: i64 = 0;
    if b { i = 1; }
    return CeVal { kind: CV_BOOL, tm: tm, ty: rt, as_data: CeValAs { i: i } };
}

fn ce_float_op(op: TokenType, l: CeVal, r: CeVal, tm: ModuleId, rt: TypeId, b: BuiltinType) CeVal {
    if op == TokenType::EqualEqual { return cv_bool(tm, rt, l.as_data.f == r.as_data.f); }
    if op == TokenType::BangEqual { return cv_bool(tm, rt, l.as_data.f != r.as_data.f); }
    if op == TokenType::LessThan { return cv_bool(tm, rt, l.as_data.f < r.as_data.f); }
    if op == TokenType::LessThanEqual { return cv_bool(tm, rt, l.as_data.f <= r.as_data.f); }
    if op == TokenType::GreaterThan { return cv_bool(tm, rt, l.as_data.f > r.as_data.f); }
    if op == TokenType::GreaterThanEqual { return cv_bool(tm, rt, l.as_data.f >= r.as_data.f); }
    let mut v: f64 = 0.0;
    switch op {
        Plus => { v = l.as_data.f + r.as_data.f; },
        Minus => { v = l.as_data.f - r.as_data.f; },
        Star => { v = l.as_data.f * r.as_data.f; },
        Slash => { v = l.as_data.f / r.as_data.f; },
        _ => { return cv_nil(); },
    };
    if b == BuiltinType::BT_F32 { v = (v as f32) as f64; }
    return CeVal { kind: CV_FLOAT, tm: tm, ty: rt, as_data: CeValAs { f: v } };
}

fn cv_scalar_of(v: ConstValue, m: ModuleId) CeVal {
    if v.kind == CONST_INT { return CeVal { kind: CV_INT, tm: m, ty: v.ty, as_data: CeValAs { i: v.as_data.i } }; }
    if v.kind == CONST_BOOL { return CeVal { kind: CV_BOOL, tm: m, ty: v.ty, as_data: CeValAs { i: v.as_data.i } }; }
    return cv_nil();
}

// C's usual arithmetic conversions for two integer operands.
fn ce_arith_common(a: BuiltinType, b: BuiltinType) BuiltinType {
    if a == BuiltinType::BT_COUNT || b == BuiltinType::BT_COUNT {
        if a == BuiltinType::BT_COUNT { return b; }
        return a;
    }
    let mut wa = bt_bits(a); if wa < 32 { wa = 32; }
    let mut wb = bt_bits(b); if wb < 32 { wb = 32; }
    let ua = bt_bits(a) >= 32 && bt_unsigned(a);
    let ub = bt_bits(b) >= 32 && bt_unsigned(b);
    let mut w = wb;
    if wa > wb { w = wa; }
    let mut u = ua;
    if ua != ub {
        let mut lhs = wb;
        let mut rhs = wa;
        if ua { lhs = wa; rhs = wb; }
        u = lhs >= rhs;
    }
    if u { if w == 64 { return BuiltinType::BT_U64; } return BuiltinType::BT_U32; }
    if w == 64 { return BuiltinType::BT_I64; }
    return BuiltinType::BT_I32;
}

// --- expression evaluation ----------------------------------------------------------------------

extend ConstEval {
    // The prelude's Range struct decl.
    fn ce_range_decl(self: &Self, dm: *mut ModuleId, dn: *mut NodeId) bool {
        let mut mm: ModuleId = 0;
        while (mm as usize) < self.nmods {
            if self.has_ast(mm) {
                let a = self.ast_ptr(mm);
                if unsafe (*a).nodes.len() != 0 {
                    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
                    for i in 0..items.len {
                        let iid = unsafe ((*a).list(items))[i as usize];
                        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_STRUCT && !unsafe (*a).at_const(iid).as_data.aggregate.is_union {
                            let nm = self.name_text(mm, unsafe (*a).at_const(iid).as_data.aggregate.name);
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
        let start_n = unsafe (*a).at_const(id).as_data.pattern_range.start;
        let end_n = unsafe (*a).at_const(id).as_data.pattern_range.end;
        let inclusive = unsafe (*a).at_const(id).as_data.pattern_range.inclusive;
        if start_n == NODE_NONE || end_n == NODE_NONE { return cv_nil(); }
        let mut dm: ModuleId = 0;
        let mut dn: NodeId = NODE_NONE;
        if !self.ce_range_decl((&mut dm) as *mut ModuleId, (&mut dn) as *mut NodeId) { return cv_nil(); }
        let mut sv = self.ev_in(f, m, start_n);
        if sv.kind == CV_NIL_K { sv = self.ev_in(null, m, start_n); }
        let mut e = self.ev_in(f, m, end_n);
        if e.kind == CV_NIL_K { e = self.ev_in(null, m, end_n); }
        if sv.kind == CV_PTR {
            let lr = self.ce_loadp(sv);
            if !lr.ok { return cv_nil(); }
            sv = lr.v;
        }
        if e.kind == CV_PTR {
            let lr = self.ce_loadp(e);
            if !lr.ok { return cv_nil(); }
            e = lr.v;
        }
        if sv.kind != CV_INT || e.kind != CV_INT { return cv_nil(); }
        let o = self.ce_obj_new(self.ce_field_count(dm, dn));
        if o == 0 { return cv_nil(); }
        unsafe (*self.obj_ptr(o)).dm = dm;
        unsafe (*self.obj_ptr(o)).dn = dn;
        unsafe (*self.obj_ptr(o)).nargs = 1;
        unsafe (*self.obj_ptr(o)).at[0] = Ast::builtin(BuiltinType::BT_USIZE);
        if unsafe (*self.obj_ptr(o)).slots.len() < 3 { return cv_nil(); }
        unsafe (*self.obj_ptr(o)).slots.set(0, sv);
        unsafe (*self.obj_ptr(o)).slots.set(1, e);
        unsafe (*self.obj_ptr(o)).slots.set(2, cv_bool(0, Ast::builtin(BuiltinType::BT_BOOL), inclusive));
        return CeVal { kind: CV_AGG, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    fn ev_in(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        if id == NODE_NONE || !self.ce_tick() || self.depth > (CE_MAX_DEPTH as u32) { return cv_nil(); }
        self.depth = self.depth + 1;
        let v = self.ev(f, m, id);
        self.depth = self.depth - 1;
        return v;
    }

    // ev + auto-deref: an expression statically typed as a REFERENCE loads through to its value.
    fn ev_rval(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let mut v = self.ev_in(f, m, id);
        if v.kind != CV_PTR { return v; }
        let mut tm = m;
        let mut t = self.ce_type(m, id);
        let mut guard = 0;
        while guard < 4 && v.kind == CV_PTR {
            let r = self.ce_rtype(f, tm, t);
            if !r.ok { return v; }
            tm = r.m;
            t = r.t;
            let y = unsafe (*self.ast_ptr(tm)).type_at(t);
            if y.kind != TypeKind::TYPE_REFERENCE { return v; }
            let elem = y.as_data.elem;
            let lr = self.ce_loadp(v);
            if !lr.ok { return cv_nil(); }
            v = lr.v;
            t = elem;
            guard = guard + 1;
        }
        return v;
    }

    // Coerce a value to a wanted resolved type at a binding boundary.
    fn ce_coerce(self: &mut Self, v: CeVal, wm: ModuleId, wt: TypeId) CeVal {
        if v.kind == CV_NIL_K { return cv_nil(); }
        if wt == TYPE_NONE { return v; }
        let y = *unsafe (*self.ast_ptr(wm)).type_at(wt);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION {
            if v.kind == CV_PTR || v.kind == CV_FN { return v; }
            return cv_nil();
        }
        if v.kind == CV_PTR {
            let lr = self.ce_loadp(v);
            if !lr.ok { return cv_nil(); }
            return self.ce_coerce(lr.v, wm, wt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE && v.kind == CV_AGG && v.ty != TYPE_NONE
            && unsafe (*self.ast_ptr(v.tm)).type_at(v.ty).kind == TypeKind::TYPE_ARRAY {
            let it = *unsafe (*self.ast_ptr(wm)).instance(y.as_data.inst);
            let da = self.ast_ptr(it.module);
            let dn = self.name_text(it.module, unsafe (*da).at_const(it.decl).as_data.aggregate.name);
            if !self.ce_span_is(it.module, dn, "Slice") && !self.ce_span_is(it.module, dn, "SliceMut") { return cv_nil(); }
            if self.obj_ptr(v.as_data.p.obj) == null { return cv_nil(); }
            let arrlen = unsafe (*self.obj_ptr(v.as_data.p.obj)).slots.len() as i64;
            let so = self.ce_obj_new(2);
            if so == 0 { return cv_nil(); }
            unsafe (*self.obj_ptr(so)).dm = it.module;
            unsafe (*self.obj_ptr(so)).dn = it.decl;
            unsafe (*self.obj_ptr(so)).slots.set(0, CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: v.as_data.p.obj, off: 0 } } });
            unsafe (*self.obj_ptr(so)).slots.set(1, CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_USIZE), as_data: CeValAs { i: arrlen } });
            return CeVal { kind: CV_AGG, tm: wm, ty: wt, as_data: CeValAs { p: CvPtr { obj: so, off: 0 } } };
        }
        if y.kind == TypeKind::TYPE_ARRAY && v.kind == CV_AGG && y.as_data.arr.len != 0 {
            let o = self.obj_ptr(v.as_data.p.obj);
            if o != null && (unsafe (*o).slots.len() as u32) < y.as_data.arr.len {
                let from = unsafe (*o).slots.len() as u32;
                let er = self.ce_rtype(null, wm, y.as_data.arr.elem);
                if !er.ok { return cv_nil(); }
                let z = self.ce_zero(er.m, er.t, 0);
                if z.kind == CV_NIL_K || !self.ce_obj_resize(v.as_data.p.obj, y.as_data.arr.len) { return cv_nil(); }
                let newlen = unsafe (*self.obj_ptr(v.as_data.p.obj)).slots.len() as u32;
                let mut i = from;
                while i < newlen {
                    let cloned = self.ce_clone(z, 0);
                    unsafe (*self.obj_ptr(v.as_data.p.obj)).slots.set(i as usize, cloned);
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
            if !lr.ok { return ObjRes { ok: false }; }
            v = lr.v;
            guard = guard + 1;
        }
        if v.kind != CV_AGG { return ObjRes { ok: false }; }
        return ObjRes { ok: true, obj: v.as_data.p.obj };
    }

    fn ev_place(self: &mut Self, f: *mut CeFrame, m: ModuleId, id0: NodeId) ValRes {
        let a = self.ast_ptr(m);
        let mut id = id0;
        loop {
            let k = unsafe (*a).at_const(id).kind;
            if k == NodeKind::NODE_UNARY {
                let op = unsafe (*a).at_const(id).as_data.unary.op;
                if op == TokenType::Move || op == TokenType::Unsafe {
                    id = unsafe (*a).at_const(id).as_data.unary.operand;
                    continue;
                }
            }
            break;
        }
        let n_kind = unsafe (*a).at_const(id).kind;
        if n_kind == NodeKind::NODE_IDENTIFIER {
            if f == null { return ValRes { ok: false }; }
            let mut d = unsafe (*a).resolution_def(id);
            if d.node == NODE_NONE { d = DefId { module: m, node: unsafe (*a).resolution(id) }; }
            if d.module != m { return ValRes { ok: false }; }
            let i = ce_local_find(f, d.node);
            if i < 0 { return ValRes { ok: false }; }
            let slot = unsafe (*f).locals[i as usize].slot;
            return ValRes { ok: true, v: CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: unsafe (*f).env, off: slot } } } };
        }
        if n_kind == NodeKind::NODE_MEMBER {
            if unsafe (*a).at_const(id).as_data.member.path { return ValRes { ok: false }; }
            let mem = unsafe (*a).at_const(id).as_data.member.member;
            let obj_n = unsafe (*a).at_const(id).as_data.member.object;
            let mname = self.name_text(m, mem);
            let br = self.ce_base_obj(f, m, obj_n);
            if !br.ok { return ValRes { ok: false }; }
            let o = self.obj_ptr(br.obj);
            if o == null || unsafe (*o).dead != 0 { return ValRes { ok: false }; }
            let c0 = unsafe (self.ce_src(m))[mname.start as usize];
            let mut idx: u32 = 0;
            if c0 >= '0' as u8 && c0 <= '9' as u8 {
                idx = (c0 - '0' as u8) as u32;
            } else {
                if unsafe (*o).dn == NODE_NONE { return ValRes { ok: false }; }
                let fi = self.ce_field_index(unsafe (*o).dm, unsafe (*o).dn, m, mname);
                if fi.idx < 0 { return ValRes { ok: false }; }
                idx = fi.idx as u32;
            }
            if idx >= unsafe (*self.obj_ptr(br.obj)).slots.len() as u32 { return ValRes { ok: false }; }
            return ValRes { ok: true, v: CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: br.obj, off: idx } } } };
        }
        if n_kind == NodeKind::NODE_INDEX {
            let obj_n = unsafe (*a).at_const(id).as_data.index.object;
            let index_n = unsafe (*a).at_const(id).as_data.index.index;
            let mut bm = m;
            let mut bt = self.ce_type(m, obj_n);
            for _ in 0..4 {
                let r = self.ce_rtype(f, bm, bt);
                if !r.ok { return ValRes { ok: false }; }
                bm = r.m;
                bt = r.t;
                let y = unsafe (*self.ast_ptr(bm)).type_at(bt);
                if y.kind != TypeKind::TYPE_REFERENCE { break; }
                bt = y.as_data.elem;
            }
            let yk = unsafe (*self.ast_ptr(bm)).type_at(bt).kind;
            let iv = self.ev_rval(f, m, index_n);
            if iv.kind != CV_INT { return ValRes { ok: false }; }
            if yk == TypeKind::TYPE_POINTER {
                let p = self.ev_rval(f, m, obj_n);
                if p.kind != CV_PTR { return ValRes { ok: false }; }
                let mut out = p;
                out.as_data.p.off = out.as_data.p.off + (iv.as_data.i as u32);
                return ValRes { ok: true, v: out };
            }
            if yk == TypeKind::TYPE_ARRAY {
                let br = self.ce_base_obj(f, m, obj_n);
                if !br.ok { return ValRes { ok: false }; }
                let olen = unsafe (*self.obj_ptr(br.obj)).slots.len() as u64;
                if iv.as_data.i < 0 || (iv.as_data.i as u64) >= olen { self.ce_trap("out-of-bounds access"); return ValRes { ok: false }; }
                return ValRes { ok: true, v: CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: br.obj, off: iv.as_data.i as u32 } } } };
            }
            if yk == TypeKind::TYPE_STRUCT || yk == TypeKind::TYPE_INSTANCE {
                let rr = self.ce_recv_of(f, bm, bt);
                if !rr.ok { return ValRes { ok: false }; }
                let recvr = self.ev_place(f, m, obj_n);
                if !recvr.ok { return ValRes { ok: false }; }
                let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
                args[0] = recvr.v;
                args[1] = iv;
                let dr = self.ce_dispatch(rr.r, m, "index_mut", (&args[0]) as *const CeVal, 2);
                if !dr.ok || dr.v.kind != CV_PTR { return ValRes { ok: false }; }
                return ValRes { ok: true, v: dr.v };
            }
            return ValRes { ok: false };
        }
        if n_kind == NodeKind::NODE_UNARY {
            let op = unsafe (*a).at_const(id).as_data.unary.op;
            if op == TokenType::Star {
                let p = self.ev_in(f, m, unsafe (*a).at_const(id).as_data.unary.operand);
                if p.kind != CV_PTR { return ValRes { ok: false }; }
                return ValRes { ok: true, v: p };
            }
            return ValRes { ok: false };
        }
        return ValRes { ok: false };
    }

    fn ev(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        if !self.has_ast(m) { return cv_nil(); }
        let a = self.ast_ptr(m);
        let n = unsafe (*a).at_const(id);
        let ntt = n.as_data.literal.token_type; // valid only when kind==NODE_LITERAL
        if f != null && self.ce_type(m, id) == TYPE_NONE
            && !(n.kind == NodeKind::NODE_LITERAL && ntt == TokenType::Null) {
            return cv_nil();
        }
        let src = self.ce_src(m);
        let rt = self.ce_type(m, id);
        if n.kind == NodeKind::NODE_LITERAL {
            if ntt == TokenType::IntegerLiteral { return cv_scalar_of(self.eval_int_literal(m, id), m); }
            if ntt == TokenType::CharacterLiteral || ntt == TokenType::ByteCharacterLiteral { return cv_scalar_of(self.eval_char_literal(m, id), m); }
            if ntt == TokenType::FloatLiteral { return self.eval_float_literal(m, id); }
            if ntt == TokenType::True { return cv_bool(m, rt, true); }
            if ntt == TokenType::False { return cv_bool(m, rt, false); }
            if ntt == TokenType::Null { return CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: 0, off: 0 } } }; }
            if ntt == TokenType::StringLiteral || ntt == TokenType::RawStringLiteral { return self.eval_str_literal(f, m, id); }
            return cv_nil();
        }
        if n.kind == NodeKind::NODE_IDENTIFIER {
            let mut d = unsafe (*a).resolution_def(id);
            if d.node == NODE_NONE { d = DefId { module: m, node: unsafe (*a).resolution(id) }; }
            if d.node == NODE_NONE || (d.module as usize) >= self.nmods { return cv_nil(); }
            if f != null && d.module == m {
                let i = ce_local_find(f, d.node);
                if i >= 0 {
                    let slot = unsafe (*f).locals[i as usize].slot;
                    let env = unsafe (*f).env;
                    let eo = self.obj_ptr(env);
                    if eo == null || (slot as usize) >= unsafe (*eo).slots.len() { return cv_nil(); }
                    let mut v = unsafe (*eo).slots[slot as usize];
                    if v.kind == CV_NIL_K { return cv_nil(); }
                    if v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT { v.tm = m; v.ty = rt; }
                    return v;
                }
            }
            let dk = unsafe (*self.ast_ptr(d.module)).at_const(d.node).kind;
            if dk == NodeKind::NODE_FUNCTION { return CeVal { kind: CV_FN, tm: m, ty: rt, as_data: CeValAs { fnv: CvFn { m: d.module, fn_id: d.node } } }; }
            let dval = unsafe (*self.ast_ptr(d.module)).at_const(d.node).as_data.const_def.value;
            let is_static_mut = unsafe (*self.ast_ptr(d.module)).at_const(d.node).as_data.const_def.is_static_mut;
            if dk != NodeKind::NODE_CONST || dval == NODE_NONE || is_static_mut { return cv_nil(); }
            let mut v = self.ev_in(null, d.module, dval);
            if v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT { v.tm = m; v.ty = rt; }
            return v;
        }
        if n.kind == NodeKind::NODE_MEMBER {
            if n.as_data.member.path {
                let mut d = unsafe (*a).resolution_def(id);
                if d.node == NODE_NONE { d = unsafe (*a).resolution_def(n.as_data.member.member); }
                if d.node == NODE_NONE || (d.module as usize) >= self.nmods { return cv_nil(); }
                let dk = unsafe (*self.ast_ptr(d.module)).at_const(d.node).kind;
                if dk == NodeKind::NODE_CONST {
                    let dval = unsafe (*self.ast_ptr(d.module)).at_const(d.node).as_data.const_def.value;
                    let is_sm = unsafe (*self.ast_ptr(d.module)).at_const(d.node).as_data.const_def.is_static_mut;
                    if dval != NODE_NONE && !is_sm {
                        let mut v = self.ev_in(null, d.module, dval);
                        if v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT { v.tm = m; v.ty = rt; }
                        return v;
                    }
                }
                if dk == NodeKind::NODE_FUNCTION { return CeVal { kind: CV_FN, tm: m, ty: rt, as_data: CeValAs { fnv: CvFn { m: d.module, fn_id: d.node } } }; }
                if dk != NodeKind::NODE_VARIANT { return cv_nil(); }
                let vp = self.ce_variant_pos(d.module, d.node);
                if vp.pos < 0 { return cv_nil(); }
                if !self.ce_enum_tagged(d.module, vp.enum_decl) {
                    let mut v = cv_scalar_of(self.variant_value(d.module, d.node), m);
                    v.ty = rt;
                    return v;
                }
                if unsafe (*self.ast_ptr(d.module)).at_const(d.node).as_data.variant.payload.len > 0 { return cv_nil(); }
                if self.ce_user_free(d.module, vp.enum_decl) { return cv_nil(); }
                let o = self.ce_obj_new(1);
                if o == 0 { return cv_nil(); }
                unsafe (*self.obj_ptr(o)).is_enum = 1;
                unsafe (*self.obj_ptr(o)).dm = d.module;
                unsafe (*self.obj_ptr(o)).dn = vp.enum_decl;
                unsafe (*self.obj_ptr(o)).slots.set(0, CeVal { kind: CV_INT, tm: 0, ty: TYPE_NONE, as_data: CeValAs { i: vp.pos as i64 } });
                return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
            }
            let mname = self.name_text(m, n.as_data.member.member);
            let br = self.ce_base_obj(f, m, n.as_data.member.object);
            if !br.ok { return cv_nil(); }
            let o = self.obj_ptr(br.obj);
            if o == null || unsafe (*o).dead != 0 { return cv_nil(); }
            let c0 = unsafe src[mname.start as usize];
            let mut idx: u32 = 0;
            if c0 >= '0' as u8 && c0 <= '9' as u8 {
                idx = (c0 - '0' as u8) as u32;
            } else {
                if unsafe (*o).dn == NODE_NONE { return cv_nil(); }
                let fi = self.ce_field_index(unsafe (*o).dm, unsafe (*o).dn, m, mname);
                if fi.idx < 0 { return cv_nil(); }
                idx = fi.idx as u32;
            }
            let oo = self.obj_ptr(br.obj);
            if idx >= unsafe (*oo).slots.len() as u32 { return cv_nil(); }
            let sv = unsafe (*oo).slots[idx as usize];
            if sv.kind == CV_NIL_K { return cv_nil(); }
            return sv;
        }
        if n.kind == NodeKind::NODE_UNARY { return self.ev_unary(f, m, id); }
        if n.kind == NodeKind::NODE_CAST { return self.ev_cast(f, m, id); }
        if n.kind == NodeKind::NODE_SIZEOF || n.kind == NodeKind::NODE_ALIGNOF {
            let ty = self.ce_type(m, n.as_data.single.value);
            let lay = self.ce_layout_f(f, m, ty);
            if !lay.ok { return cv_nil(); }
            let mut val = lay.align;
            if n.kind == NodeKind::NODE_SIZEOF { val = lay.size; }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: val as i64 } };
        }
        if n.kind == NodeKind::NODE_BINARY { return self.ev_binary(f, m, id); }
        if n.kind == NodeKind::NODE_CALL {
            let cr = self.ce_call(f, m, id);
            if !cr.ok || cr.n != 1 { return cv_nil(); }
            return cr.vals[0];
        }
        if n.kind == NodeKind::NODE_MATCH {
            if f == null { return cv_nil(); }
            let mut out = cv_nil();
            if self.exec_match(f, m, id, (&mut out) as *mut CeVal) == Flow::Ok { return out; }
            return cv_nil();
        }
        if n.kind == NodeKind::NODE_BLOCK { return self.ev_block(f, m, id); }
        if n.kind == NodeKind::NODE_IF {
            if f == null { return cv_nil(); }
            let c = self.ev_rval(f, m, n.as_data.if_stmt.condition);
            if c.kind != CV_BOOL { return cv_nil(); }
            let mut branch = n.as_data.if_stmt.else_branch;
            if c.as_data.i != 0 { branch = n.as_data.if_stmt.then_branch; }
            return self.ev_in(f, m, branch);
        }
        if n.kind == NodeKind::NODE_INDEX { return self.ev_index(f, m, id); }
        if n.kind == NodeKind::NODE_STRUCT_INITIALIZER { return self.ev_struct_init(f, m, id); }
        if n.kind == NodeKind::NODE_ARRAY_LITERAL { return self.ev_array_lit(f, m, id); }
        if n.kind == NodeKind::NODE_TUPLE { return self.ev_tuple(f, m, id); }
        if n.kind == NodeKind::NODE_CLOSURE { return CeVal { kind: CV_FN, tm: m, ty: rt, as_data: CeValAs { fnv: CvFn { m: m, fn_id: id } } }; }
        if n.kind == NodeKind::NODE_RANGE { return self.ce_range_obj(f, m, id); }
        return cv_nil();
    }

    fn ev_unary(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let n = unsafe (*a).at_const(id);
        let op = n.as_data.unary.op;
        let operand = n.as_data.unary.operand;
        let rt = self.ce_type(m, id);
        if op == TokenType::Move || op == TokenType::Unsafe { return self.ev_in(f, m, operand); }
        if op == TokenType::Ampersand {
            let pr = self.ev_place(f, m, operand);
            if pr.ok {
                let mut p = pr.v;
                p.tm = m;
                p.ty = rt;
                return p;
            }
            let v = self.ev_in(f, m, operand);
            if v.kind == CV_NIL_K { return cv_nil(); }
            let tr = self.ce_temp_place(v);
            if !tr.ok { return cv_nil(); }
            let mut out = tr.v;
            out.tm = m;
            out.ty = rt;
            return out;
        }
        if op == TokenType::Star {
            let p = self.ev_in(f, m, operand);
            if p.kind != CV_PTR { return cv_nil(); }
            let lr = self.ce_loadp(p);
            if !lr.ok { return cv_nil(); }
            return lr.v;
        }
        if op == TokenType::Question {
            if f == null { return cv_nil(); }
            let v = self.ev_rval(f, m, operand);
            if v.kind != CV_AGG { return cv_nil(); }
            let o = self.obj_ptr(v.as_data.p.obj);
            if o == null || unsafe (*o).is_enum == 0 { return cv_nil(); }
            let odm = unsafe (*o).dm;
            let odn = unsafe (*o).dn;
            let mut okv = self.ce_variant_named(odm, odn, "Some");
            if okv < 0 { okv = self.ce_variant_named(odm, odn, "Ok"); }
            if okv < 0 { return cv_nil(); }
            let o2 = self.obj_ptr(v.as_data.p.obj);
            let tag = unsafe (*o2).slots[0].as_data.i;
            if tag == (okv as i64) {
                if unsafe (*o2).slots.len() < 2 || unsafe (*o2).slots[1].kind == CV_NIL_K { return cv_nil(); }
                return unsafe (*o2).slots[1];
            }
            unsafe (*f).rets[0] = v;
            unsafe (*f).nrets = 1;
            unsafe (*f).returned = 1;
            unsafe (*f).early = 1;
            return cv_nil();
        }
        let o = self.ev_rval(f, m, operand);
        if o.kind == CV_NIL_K { return cv_nil(); }
        let b = self.ce_builtin_of(f, m, rt);
        if op == TokenType::Minus {
            if o.kind == CV_FLOAT {
                let mut v = -o.as_data.f;
                if b == BuiltinType::BT_F32 { v = (v as f32) as f64; }
                return CeVal { kind: CV_FLOAT, tm: m, ty: rt, as_data: CeValAs { f: v } };
            }
            if o.kind != CV_INT || o.as_data.i == I64_MIN { return cv_nil(); }
            let r = -o.as_data.i;
            if b != BuiltinType::BT_COUNT && !fits(b, r) { return cv_nil(); }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: r } };
        }
        if op == TokenType::Tilde {
            if o.kind != CV_INT { return cv_nil(); }
            let mut bb = b;
            if b == BuiltinType::BT_COUNT { bb = BuiltinType::BT_I64; }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: wrap_to(bb, ~o.as_data.i) } };
        }
        if op == TokenType::Bang {
            if o.kind != CV_BOOL { return cv_nil(); }
            return cv_bool(m, rt, o.as_data.i == 0);
        }
        return cv_nil();
    }

    fn ev_cast(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let n = unsafe (*a).at_const(id);
        let expr = n.as_data.cast.expression;
        let rt = self.ce_type(m, id);
        let o = self.ev_rval(f, m, expr);
        if o.kind == CV_NIL_K { return cv_nil(); }
        let r2 = self.ce_rtype(f, m, rt);
        if !r2.ok { return cv_nil(); }
        let y = *unsafe (*self.ast_ptr(r2.m)).type_at(r2.t);
        if y.kind == TypeKind::TYPE_POINTER {
            if o.kind != CV_PTR { return cv_nil(); }
            let mut v = o;
            v.tm = m;
            v.ty = rt;
            let er = self.ce_rtype(f, r2.m, y.as_data.elem);
            if !er.ok { return cv_nil(); }
            if type_builtin(self.ast_ptr(er.m), er.t) == BuiltinType::BT_VOID { return v; }
            let blk = self.obj_ptr(o.as_data.p.obj);
            if blk == null { return v; }
            if unsafe (*blk).heap != 0 && unsafe (*blk).et == TYPE_NONE && o.as_data.p.off == 0 {
                let lay = self.ce_layout_f(f, er.m, er.t);
                if !lay.ok || lay.size == 0 { return cv_nil(); }
                let bytes = unsafe (*blk).bytes;
                if bytes % lay.size != 0 { return cv_nil(); }
                if !self.ce_obj_resize(o.as_data.p.obj, (bytes / lay.size) as u32) { return cv_nil(); }
                let blk2 = self.obj_ptr(o.as_data.p.obj);
                unsafe (*blk2).em = er.m;
                unsafe (*blk2).et = er.t;
                unsafe (*blk2).esz = lay.size;
                return v;
            }
            if unsafe (*blk).et != TYPE_NONE && !self.ce_teq(unsafe (*blk).em, unsafe (*blk).et, er.m, er.t) { return cv_nil(); }
            return v;
        }
        let mut b = BuiltinType::BT_COUNT;
        if y.kind == TypeKind::TYPE_BUILTIN { b = y.as_data.builtin; }
        if b == BuiltinType::BT_COUNT || b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64 || b == BuiltinType::BT_BOOL || b == BuiltinType::BT_VALIST || b == BuiltinType::BT_VOID { return cv_nil(); }
        if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 {
            let mut v: f64 = 0.0;
            if o.kind == CV_FLOAT { v = o.as_data.f; }
            else if o.kind == CV_INT {
                let ob = self.ce_builtin_of(f, m, self.ce_type(m, expr));
                if ob != BuiltinType::BT_COUNT && bt_unsigned(ob) { v = (o.as_data.i as u64) as f64; }
                else { v = o.as_data.i as f64; }
            } else { return cv_nil(); }
            if b == BuiltinType::BT_F32 { v = (v as f32) as f64; }
            return CeVal { kind: CV_FLOAT, tm: m, ty: rt, as_data: CeValAs { f: v } };
        }
        if o.kind == CV_FLOAT {
            if !ce_isfinite(o.as_data.f) { return cv_nil(); }
            let t = unsafe math::trunc(o.as_data.f);
            if t < -9.3e18 || t > 1.8e19 { return cv_nil(); }
            let mut iv: i64 = t as i64;
            if bt_unsigned(b) { iv = (t as u64) as i64; }
            if !fits(b, iv) && bt_bits(b) < 64 { return cv_nil(); }
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: wrap_to(b, iv) } };
        }
        if o.kind == CV_BOOL || o.kind == CV_INT {
            return CeVal { kind: CV_INT, tm: m, ty: rt, as_data: CeValAs { i: wrap_to(b, o.as_data.i) } };
        }
        return cv_nil();
    }

    fn ev_binary(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let n = unsafe (*a).at_const(id);
        let op = n.as_data.binary.op;
        let left = n.as_data.binary.left;
        let right = n.as_data.binary.right;
        let rt = self.ce_type(m, id);
        let sr = self.ce_strip_refptr(f, m, self.ce_type(m, left));
        if sr.ok {
            let lyk = unsafe (*self.ast_ptr(sr.m)).type_at(sr.t).kind;
            if lyk == TypeKind::TYPE_STRUCT || lyk == TypeKind::TYPE_INSTANCE {
                let mut mn: str = "";
                if op == TokenType::Plus { mn = "add"; }
                else if op == TokenType::Minus { mn = "sub"; }
                else if op == TokenType::Star { mn = "mul"; }
                else if op == TokenType::Slash { mn = "div"; }
                else if op == TokenType::Percent { mn = "rem"; }
                else if op == TokenType::EqualEqual || op == TokenType::BangEqual { mn = "eq"; }
                else if op == TokenType::LessThan || op == TokenType::LessThanEqual || op == TokenType::GreaterThan || op == TokenType::GreaterThanEqual { mn = "cmp"; }
                if mn.len() != 0 {
                    let rr = self.ce_recv_of(f, sr.m, sr.t);
                    if !rr.ok { return cv_nil(); }
                    let mut lhs = cv_nil();
                    let lp = self.ev_place(f, m, left);
                    if lp.ok { lhs = lp.v; }
                    else {
                        let lv = self.ev_in(f, m, left);
                        let tr = self.ce_temp_place(lv);
                        if lv.kind == CV_NIL_K || !tr.ok { return cv_nil(); }
                        lhs = tr.v;
                    }
                    let mut rhs = cv_nil();
                    let rp = self.ev_place(f, m, right);
                    if rp.ok { rhs = rp.v; }
                    else {
                        let rv = self.ev_rval(f, m, right);
                        let tr = self.ce_temp_place(rv);
                        if rv.kind == CV_NIL_K || !tr.ok { return cv_nil(); }
                        rhs = tr.v;
                    }
                    let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
                    args[0] = lhs;
                    args[1] = rhs;
                    let dr = self.ce_dispatch(rr.r, m, mn, (&args[0]) as *const CeVal, 2);
                    if !dr.ok { return cv_nil(); }
                    let mut res = dr.v;
                    if op == TokenType::EqualEqual || op == TokenType::BangEqual {
                        if res.kind != CV_BOOL { return cv_nil(); }
                        if op == TokenType::BangEqual { res.as_data.i = if_i64(res.as_data.i == 0, 1, 0); }
                        res.tm = m;
                        res.ty = rt;
                        return res;
                    }
                    if mn.byte_at(0) == 'c' as u8 {
                        if res.kind != CV_INT { return cv_nil(); }
                        let c = res.as_data.i;
                        let mut v: i64 = 0;
                        if op == TokenType::LessThan { v = if_i64(c < 0, 1, 0); }
                        else if op == TokenType::LessThanEqual { v = if_i64(c <= 0, 1, 0); }
                        else if op == TokenType::GreaterThan { v = if_i64(c > 0, 1, 0); }
                        else { v = if_i64(c >= 0, 1, 0); }
                        return CeVal { kind: CV_BOOL, tm: m, ty: rt, as_data: CeValAs { i: v } };
                    }
                    return res;
                }
            }
        }
        let l = self.ev_rval(f, m, left);
        if l.kind == CV_NIL_K { return cv_nil(); }
        let r = self.ev_rval(f, m, right);
        if r.kind == CV_NIL_K { return cv_nil(); }
        if l.kind == CV_PTR || r.kind == CV_PTR {
            if op == TokenType::EqualEqual || op == TokenType::BangEqual {
                if l.kind != CV_PTR || r.kind != CV_PTR { return cv_nil(); }
                let eq = l.as_data.p.obj == r.as_data.p.obj && l.as_data.p.off == r.as_data.p.off;
                let mut vv = eq;
                if op == TokenType::BangEqual { vv = !eq; }
                return cv_bool(m, rt, vv);
            }
            if (op == TokenType::Plus || op == TokenType::Minus) && l.kind == CV_PTR && r.kind == CV_INT {
                let mut v = l;
                v.tm = m;
                v.ty = rt;
                if op == TokenType::Plus { v.as_data.p.off = v.as_data.p.off + (r.as_data.i as u32); }
                else { v.as_data.p.off = v.as_data.p.off - (r.as_data.i as u32); }
                return v;
            }
            if op == TokenType::Plus && r.kind == CV_PTR && l.kind == CV_INT {
                let mut v = r;
                v.tm = m;
                v.ty = rt;
                v.as_data.p.off = v.as_data.p.off + (l.as_data.i as u32);
                return v;
            }
            return cv_nil();
        }
        if l.kind == CV_BOOL && r.kind == CV_BOOL {
            if op == TokenType::AmpersandAmpersand { return cv_bool(m, rt, l.as_data.i != 0 && r.as_data.i != 0); }
            if op == TokenType::PipePipe { return cv_bool(m, rt, l.as_data.i != 0 || r.as_data.i != 0); }
            if op == TokenType::EqualEqual { return cv_bool(m, rt, l.as_data.i == r.as_data.i); }
            if op == TokenType::BangEqual { return cv_bool(m, rt, l.as_data.i != r.as_data.i); }
            return cv_nil();
        }
        if l.kind == CV_FLOAT && r.kind == CV_FLOAT { return ce_float_op(op, l, r, m, rt, self.ce_builtin_of(f, m, rt)); }
        if l.kind != CV_INT || r.kind != CV_INT { return cv_nil(); }
        let rb = self.ce_builtin_of(f, m, rt);
        let lb = self.ce_builtin_of(f, m, self.ce_type(m, left));
        let mut ob = lb;
        if op != TokenType::LeftShift && op != TokenType::RightShift {
            let mut lbc = lb;
            if lb == BuiltinType::BT_COUNT { lbc = rb; }
            ob = ce_arith_common(lbc, self.ce_builtin_of(f, m, self.ce_type(m, right)));
        }
        return self.ce_int_op(op, l, r, m, rt, rb, ob);
    }
}

fn if_i64(c: bool, a: i64, b: i64) i64 { if c { return a; } return b; }

extend ConstEval {
    fn ev_block(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let stmts = unsafe (*a).at_const(id).as_data.block.statements;
        if f == null || stmts.len == 0 { return cv_nil(); }
        let dbase = unsafe (*f).ndefers;
        let mut out = cv_nil();
        let mut ok = true;
        let mut i: u32 = 0;
        while ok && i + 1 < stmts.len {
            let sid = unsafe ((*a).list(stmts))[i as usize];
            ok = self.exec_stmt(f, m, sid) == Flow::Ok;
            i = i + 1;
        }
        if ok {
            let lastid = unsafe ((*a).list(stmts))[(stmts.len - 1) as usize];
            let last = unsafe (*a).at_const(lastid);
            if last.kind == NodeKind::NODE_EXPRESSION_STATEMENT
                && unsafe (*a).at_const(last.as_data.single.value).kind != NodeKind::NODE_ASSIGNMENT {
                out = self.ev_in(f, m, last.as_data.single.value);
            }
        }
        let mut j = unsafe (*f).ndefers;
        while j > dbase {
            j = j - 1;
            let dv = unsafe (*f).defers[j as usize];
            let dk = unsafe (*a).at_const(dv).kind;
            let mut ds = Flow::Ok;
            if dk == NodeKind::NODE_BLOCK { ds = self.exec_stmt(f, m, dv); } else { ds = self.exec_expr_stmt(f, m, dv); }
            if ds != Flow::Ok { out = cv_nil(); }
        }
        unsafe (*f).ndefers = dbase;
        return out;
    }

    fn ev_index(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let obj_n = unsafe (*a).at_const(id).as_data.index.object;
        let index_n = unsafe (*a).at_const(id).as_data.index.index;
        let mut bm = m;
        let mut bt = self.ce_type(m, obj_n);
        for _ in 0..4 {
            let r = self.ce_rtype(f, bm, bt);
            if !r.ok { return cv_nil(); }
            bm = r.m;
            bt = r.t;
            let y = unsafe (*self.ast_ptr(bm)).type_at(bt);
            if y.kind != TypeKind::TYPE_REFERENCE { break; }
            bt = y.as_data.elem;
        }
        let yk = unsafe (*self.ast_ptr(bm)).type_at(bt).kind;
        if yk == TypeKind::TYPE_STRUCT || yk == TypeKind::TYPE_INSTANCE {
            let rr = self.ce_recv_of(f, bm, bt);
            if !rr.ok { return cv_nil(); }
            let mut recv = cv_nil();
            let rp = self.ev_place(f, m, obj_n);
            if rp.ok { recv = rp.v; }
            else {
                let rv = self.ev_in(f, m, obj_n);
                let tr = self.ce_temp_place(rv);
                if rv.kind == CV_NIL_K || !tr.ok { return cv_nil(); }
                recv = tr.v;
            }
            if unsafe (*a).at_const(index_n).kind == NodeKind::NODE_RANGE {
                let iv = self.ce_range_obj(f, m, index_n);
                if iv.kind != CV_AGG { return cv_nil(); }
                let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
                args[0] = recv;
                args[1] = iv;
                let dr = self.ce_dispatch(rr.r, m, "index_range", (&args[0]) as *const CeVal, 2);
                if !dr.ok || dr.v.kind != CV_AGG { return cv_nil(); }
                return dr.v;
            }
            let iv = self.ev_rval(f, m, index_n);
            if iv.kind != CV_INT { return cv_nil(); }
            let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            args[0] = recv;
            args[1] = iv;
            let dr = self.ce_dispatch(rr.r, m, "index", (&args[0]) as *const CeVal, 2);
            if !dr.ok || dr.v.kind != CV_PTR { return cv_nil(); }
            let lr = self.ce_loadp(dr.v);
            if !lr.ok { return cv_nil(); }
            return lr.v;
        }
        let pr = self.ev_place(f, m, id);
        if !pr.ok { return cv_nil(); }
        let lr = self.ce_loadp(pr.v);
        if !lr.ok { return cv_nil(); }
        return lr.v;
    }

    fn ev_struct_init(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let tn = unsafe (*a).at_const(id).as_data.struct_initializer.ty;
        let fields = unsafe (*a).at_const(id).as_data.struct_initializer.fields;
        let rt = self.ce_type(m, id);
        // enum struct-payload variant: `Variant { .. }`
        let mut vd = unsafe (*a).resolution_def(tn);
        if vd.node == NODE_NONE { vd = DefId { module: m, node: unsafe (*a).resolution(tn) }; }
        if vd.node != NODE_NONE && (vd.module as usize) < self.nmods
            && unsafe (*self.ast_ptr(vd.module)).at_const(vd.node).kind == NodeKind::NODE_ENUM
            && unsafe (*a).at_const(tn).kind == NodeKind::NODE_TYPE_PATH
            && unsafe (*a).at_const(tn).as_data.type_path.parts.len >= 2 {
            let parts = unsafe (*a).at_const(tn).as_data.type_path.parts;
            let last = unsafe ((*a).list(parts))[(parts.len - 1) as usize];
            let vn = self.name_text(m, last);
            let ea = self.ast_ptr(vd.module);
            let ms = unsafe (*ea).at_const(vd.node).as_data.aggregate.members;
            let mut hit = NODE_NONE;
            for k in 0..ms.len {
                let mid = unsafe ((*ea).list(ms))[k as usize];
                let vname = self.name_text(vd.module, unsafe (*ea).at_const(mid).as_data.variant.name);
                if self.ce_spans_eq(vd.module, vname, m, vn) { hit = mid; break; }
            }
            if hit != NODE_NONE { vd.node = hit; }
        }
        if vd.node != NODE_NONE && (vd.module as usize) < self.nmods
            && unsafe (*self.ast_ptr(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
            let vp = self.ce_variant_pos(vd.module, vd.node);
            let payload = unsafe (*self.ast_ptr(vd.module)).at_const(vd.node).as_data.variant.payload;
            let struct_payload = unsafe (*self.ast_ptr(vd.module)).at_const(vd.node).as_data.variant.struct_payload;
            if vp.pos < 0 || !struct_payload || self.ce_user_free(vd.module, vp.enum_decl) { return cv_nil(); }
            let o = self.ce_obj_new(1 + payload.len);
            if o == 0 { return cv_nil(); }
            unsafe (*self.obj_ptr(o)).is_enum = 1;
            unsafe (*self.obj_ptr(o)).dm = vd.module;
            unsafe (*self.obj_ptr(o)).dn = vp.enum_decl;
            unsafe (*self.obj_ptr(o)).slots.set(0, CeVal { kind: CV_INT, tm: 0, ty: TYPE_NONE, as_data: CeValAs { i: vp.pos as i64 } });
            let da = self.ast_ptr(vd.module);
            for i in 0..fields.len {
                let fid = unsafe ((*a).list(fields))[i as usize];
                let fkind = unsafe (*a).at_const(fid).kind;
                let fname_node = unsafe (*a).at_const(fid).as_data.field_initializer.name;
                if fkind != NodeKind::NODE_FIELD_INITIALIZER || fname_node == NODE_NONE { return cv_nil(); }
                let mut slot: i32 = -1;
                for j in 0..payload.len {
                    let pfid = unsafe ((*da).list(payload))[j as usize];
                    if unsafe (*da).at_const(pfid).kind == NodeKind::NODE_FIELD {
                        let pfname = self.name_text(vd.module, unsafe (*da).at_const(pfid).as_data.field.name);
                        if self.ce_spans_eq(vd.module, pfname, m, self.name_text(m, fname_node)) { slot = j as i32; break; }
                    }
                }
                let v = self.ev_rval(f, m, unsafe (*a).at_const(fid).as_data.field_initializer.value);
                if slot < 0 || v.kind == CV_NIL_K { return cv_nil(); }
                let cloned = self.ce_clone(v, 0);
                if cloned.kind == CV_NIL_K { return cv_nil(); }
                unsafe (*self.obj_ptr(o)).slots.set((1 + slot) as usize, cloned);
            }
            return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
        }
        let rr = self.ce_recv_of(f, m, rt);
        if !rr.ok || rr.r.dn == NODE_NONE { return cv_nil(); }
        let da = self.ast_ptr(rr.r.dm);
        let dkind = unsafe (*da).at_const(rr.r.dn).kind;
        let is_union = unsafe (*da).at_const(rr.r.dn).as_data.aggregate.is_union;
        if dkind != NodeKind::NODE_STRUCT || is_union { return cv_nil(); }
        if self.ce_user_free(rr.r.dm, rr.r.dn) { return cv_nil(); }
        let o = self.ce_obj_new(self.ce_field_count(rr.r.dm, rr.r.dn));
        if o == 0 { return cv_nil(); }
        unsafe (*self.obj_ptr(o)).dm = rr.r.dm;
        unsafe (*self.obj_ptr(o)).dn = rr.r.dn;
        unsafe (*self.obj_ptr(o)).nargs = rr.r.n;
        for ci in 0..4 {
            unsafe (*self.obj_ptr(o)).am[ci] = rr.r.am[ci];
            unsafe (*self.obj_ptr(o)).at[ci] = rr.r.at[ci];
        }
        for i in 0..fields.len {
            let fid = unsafe ((*a).list(fields))[i as usize];
            let fkind = unsafe (*a).at_const(fid).kind;
            let fname_node = unsafe (*a).at_const(fid).as_data.field_initializer.name;
            if fkind != NodeKind::NODE_FIELD_INITIALIZER || fname_node == NODE_NONE { return cv_nil(); }
            let fname = self.name_text(m, fname_node);
            let fi = self.ce_field_index(rr.r.dm, rr.r.dn, m, fname);
            if fi.idx < 0 { return cv_nil(); }
            let v = self.ev_rval(f, m, unsafe (*a).at_const(fid).as_data.field_initializer.value);
            if v.kind == CV_NIL_K { return cv_nil(); }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K { return cv_nil(); }
            unsafe (*self.obj_ptr(o)).slots.set(fi.idx as usize, cloned);
        }
        // remaining fields need decl-side defaults
        let ms = unsafe (*da).at_const(rr.r.dn).as_data.aggregate.members;
        let mut idx: i32 = 0;
        for k in 0..ms.len {
            let fd = unsafe ((*da).list(ms))[k as usize];
            if unsafe (*da).at_const(fd).kind == NodeKind::NODE_FIELD {
                if unsafe (*self.obj_ptr(o)).slots[idx as usize].kind == CV_NIL_K {
                    let fval = unsafe (*da).at_const(fd).as_data.field.value;
                    if fval == NODE_NONE { return cv_nil(); }
                    let v = self.ev_in(null, rr.r.dm, fval);
                    if v.kind == CV_NIL_K { return cv_nil(); }
                    let cloned = self.ce_clone(v, 0);
                    unsafe (*self.obj_ptr(o)).slots.set(idx as usize, cloned);
                }
                idx = idx + 1;
            }
        }
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    fn ev_array_lit(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let elements = unsafe (*a).at_const(id).as_data.array_literal.elements;
        let rt = self.ce_type(m, id);
        let r2 = self.ce_rtype(f, m, rt);
        if !r2.ok { return cv_nil(); }
        let y = *unsafe (*self.ast_ptr(r2.m)).type_at(r2.t);
        if y.kind != TypeKind::TYPE_ARRAY { return cv_nil(); }
        let count = elements.len;
        let mut len = y.as_data.arr.len;
        if len == 0 {
            len = count;
            let mut cur: u32 = 0;
            for i in 0..count {
                let el = unsafe ((*a).list(elements))[i as usize];
                if unsafe (*a).at_const(el).kind == NodeKind::NODE_FIELD_INITIALIZER {
                    let iv = self.ev_in(null, m, unsafe (*a).at_const(el).as_data.field_initializer.name);
                    if iv.kind != CV_INT || iv.as_data.i < 0 { return cv_nil(); }
                    cur = iv.as_data.i as u32;
                }
                cur = cur + 1;
                if cur > len { len = cur; }
            }
        }
        let o = self.ce_obj_new(len);
        if o == 0 { return cv_nil(); }
        if count < len {
            let er = self.ce_rtype(f, r2.m, y.as_data.arr.elem);
            if !er.ok { return cv_nil(); }
            let z = self.ce_zero(er.m, er.t, 0);
            if z.kind == CV_NIL_K { return cv_nil(); }
            for i in 0..len {
                let cloned = self.ce_clone(z, 0);
                unsafe (*self.obj_ptr(o)).slots.set(i as usize, cloned);
            }
        }
        let mut cursor: u32 = 0;
        for i in 0..count {
            let el = unsafe ((*a).list(elements))[i as usize];
            let mut value = el;
            if unsafe (*a).at_const(el).kind == NodeKind::NODE_FIELD_INITIALIZER {
                let iv = self.ev_in(null, m, unsafe (*a).at_const(el).as_data.field_initializer.name);
                if iv.kind != CV_INT || iv.as_data.i < 0 { return cv_nil(); }
                cursor = iv.as_data.i as u32;
                value = unsafe (*a).at_const(el).as_data.field_initializer.value;
            }
            if cursor >= len { return cv_nil(); }
            let v = self.ev_rval(f, m, value);
            if v.kind == CV_NIL_K { return cv_nil(); }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K { return cv_nil(); }
            unsafe (*self.obj_ptr(o)).slots.set(cursor as usize, cloned);
            cursor = cursor + 1;
        }
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    fn ev_tuple(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) CeVal {
        let a = self.ast_ptr(m);
        let elements = unsafe (*a).at_const(id).as_data.array_literal.elements;
        let rt = self.ce_type(m, id);
        let rr = self.ce_recv_of(f, m, rt);
        if !rr.ok || rr.r.dn == NODE_NONE { return cv_nil(); }
        let count = elements.len;
        let o = self.ce_obj_new(count);
        if o == 0 { return cv_nil(); }
        unsafe (*self.obj_ptr(o)).dm = rr.r.dm;
        unsafe (*self.obj_ptr(o)).dn = rr.r.dn;
        unsafe (*self.obj_ptr(o)).nargs = rr.r.n;
        for ci in 0..4 {
            unsafe (*self.obj_ptr(o)).am[ci] = rr.r.am[ci];
            unsafe (*self.obj_ptr(o)).at[ci] = rr.r.at[ci];
        }
        for i in 0..count {
            let el = unsafe ((*a).list(elements))[i as usize];
            let v = self.ev_rval(f, m, el);
            if v.kind == CV_NIL_K { return cv_nil(); }
            let cloned = self.ce_clone(v, 0);
            if cloned.kind == CV_NIL_K { return cv_nil(); }
            unsafe (*self.obj_ptr(o)).slots.set(i as usize, cloned);
        }
        return CeVal { kind: CV_AGG, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
    }

    // --- patterns and switch ---
    // Returns 1 = match (bindings applied), 0 = no match, -1 = unfoldable.
    fn pat_match(self: &mut Self, f: *mut CeFrame, m: ModuleId, pid: NodeId, v: CeVal, uns: bool, refobj: u32) i32 {
        let a = self.ast_ptr(m);
        let pk = unsafe (*a).at_const(pid).kind;
        if pk == NodeKind::NODE_PATTERN_WILDCARD { return 1; }
        if pk == NodeKind::NODE_PATTERN_NAME {
            let name_node = unsafe (*a).at_const(pid).as_data.pattern.name;
            let d = unsafe (*a).resolution_def(name_node);
            if d.node != NODE_NONE && (d.module as usize) < self.nmods
                && unsafe (*self.ast_ptr(d.module)).at_const(d.node).kind == NodeKind::NODE_VARIANT {
                if v.kind == CV_INT || v.kind == CV_BOOL {
                    let tv = self.variant_value(d.module, d.node);
                    if tv.kind == CONST_INT { return if_i32(tv.as_data.i == v.as_data.i, 1, 0); }
                    return -1;
                }
                if v.kind == CV_AGG {
                    let o = self.obj_ptr(v.as_data.p.obj);
                    let vp = self.ce_variant_pos(d.module, d.node);
                    if o != null && unsafe (*o).is_enum != 0 && vp.pos >= 0 {
                        return if_i32(unsafe (*o).slots[0].as_data.i == (vp.pos as i64), 1, 0);
                    }
                    return -1;
                }
                return -1;
            }
            if !(f != null && self.ce_bind(f, pid, v)) { return -1; }
            let children = unsafe (*a).at_const(pid).as_data.pattern.children;
            if children.len != 0 {
                let sub = unsafe ((*a).list(children))[0];
                return self.pat_match(f, m, sub, v, uns, refobj);
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_LITERAL {
            let lv = self.ev_in(null, m, unsafe (*a).at_const(pid).as_data.single.value);
            if lv.kind != CV_INT && lv.kind != CV_BOOL { return -1; }
            return if_i32(lv.as_data.i == v.as_data.i && (v.kind == CV_INT || v.kind == CV_BOOL), 1, 0);
        }
        if pk == NodeKind::NODE_PATTERN_RANGE {
            if v.kind != CV_INT { return -1; }
            let start_n = unsafe (*a).at_const(pid).as_data.pattern_range.start;
            let end_n = unsafe (*a).at_const(pid).as_data.pattern_range.end;
            let inclusive = unsafe (*a).at_const(pid).as_data.pattern_range.inclusive;
            if start_n != NODE_NONE {
                let mut sn = start_n;
                if unsafe (*a).at_const(start_n).kind == NodeKind::NODE_PATTERN_LITERAL { sn = unsafe (*a).at_const(start_n).as_data.single.value; }
                let s = self.ev_in(null, m, sn);
                if s.kind != CV_INT { return -1; }
                let below = if_bool(uns, (v.as_data.i as u64) < (s.as_data.i as u64), v.as_data.i < s.as_data.i);
                if below { return 0; }
            }
            if end_n != NODE_NONE {
                let mut en = end_n;
                if unsafe (*a).at_const(end_n).kind == NodeKind::NODE_PATTERN_LITERAL { en = unsafe (*a).at_const(end_n).as_data.single.value; }
                let e = self.ev_in(null, m, en);
                if e.kind != CV_INT { return -1; }
                let mut above = false;
                if inclusive { above = if_bool(uns, (v.as_data.i as u64) > (e.as_data.i as u64), v.as_data.i > e.as_data.i); }
                else { above = if_bool(uns, (v.as_data.i as u64) >= (e.as_data.i as u64), v.as_data.i >= e.as_data.i); }
                if above { return 0; }
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_OR {
            let children = unsafe (*a).at_const(pid).as_data.pattern.children;
            for i in 0..children.len {
                let cid = unsafe ((*a).list(children))[i as usize];
                let r = self.pat_match(f, m, cid, v, uns, refobj);
                if r != 0 { return r; }
            }
            return 0;
        }
        if pk == NodeKind::NODE_PATTERN_TUPLE {
            let pname = unsafe (*a).at_const(pid).as_data.pattern.name;
            let children = unsafe (*a).at_const(pid).as_data.pattern.children;
            if pname == NODE_NONE {
                if children.len == 1 { return self.pat_match(f, m, unsafe ((*a).list(children))[0], v, uns, refobj); }
                return -1;
            }
            if v.kind != CV_AGG { return -1; }
            let d = unsafe (*a).resolution_def(pname);
            if d.node == NODE_NONE || unsafe (*self.ast_ptr(d.module)).at_const(d.node).kind != NodeKind::NODE_VARIANT { return -1; }
            let o = self.obj_ptr(v.as_data.p.obj);
            let vp = self.ce_variant_pos(d.module, d.node);
            if o == null || unsafe (*o).is_enum == 0 || vp.pos < 0 { return -1; }
            if unsafe (*o).slots[0].as_data.i != (vp.pos as i64) { return 0; }
            for k in 0..children.len {
                let cid = unsafe ((*a).list(children))[k as usize];
                if (1 + k) >= unsafe (*self.obj_ptr(v.as_data.p.obj)).slots.len() as u32 { return -1; }
                if refobj != 0 && unsafe (*a).at_const(cid).kind == NodeKind::NODE_PATTERN_NAME
                    && unsafe (*a).resolution_def(unsafe (*a).at_const(cid).as_data.pattern.name).node == NODE_NONE {
                    let pv = CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: refobj, off: 1 + k } } };
                    if f == null || !self.ce_bind(f, cid, pv) { return -1; }
                    continue;
                }
                let sv = unsafe (*self.obj_ptr(v.as_data.p.obj)).slots[(1 + k) as usize];
                if sv.kind == CV_NIL_K { return -1; }
                let r = self.pat_match(f, m, cid, sv, uns, 0);
                if r != 1 { return r; }
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_STRUCT {
            let pname = unsafe (*a).at_const(pid).as_data.pattern.name;
            if v.kind != CV_AGG || pname == NODE_NONE { return -1; }
            let d = unsafe (*a).resolution_def(pname);
            if d.node == NODE_NONE || unsafe (*self.ast_ptr(d.module)).at_const(d.node).kind != NodeKind::NODE_VARIANT { return -1; }
            let o = self.obj_ptr(v.as_data.p.obj);
            let vp = self.ce_variant_pos(d.module, d.node);
            if o == null || unsafe (*o).is_enum == 0 || vp.pos < 0 { return -1; }
            if unsafe (*o).slots[0].as_data.i != (vp.pos as i64) { return 0; }
            let da = self.ast_ptr(d.module);
            let vpayload = unsafe (*da).at_const(d.node).as_data.variant.payload;
            if !unsafe (*da).at_const(d.node).as_data.variant.struct_payload { return -1; }
            let children = unsafe (*a).at_const(pid).as_data.pattern.children;
            for k in 0..children.len {
                let cid = unsafe ((*a).list(children))[k as usize];
                let pfname = unsafe (*a).at_const(cid).as_data.pattern.name;
                if unsafe (*a).at_const(cid).kind != NodeKind::NODE_PATTERN_FIELD || pfname == NODE_NONE { return -1; }
                let mut slot: i32 = -1;
                for j in 0..vpayload.len {
                    let pfid = unsafe ((*da).list(vpayload))[j as usize];
                    if unsafe (*da).at_const(pfid).kind == NodeKind::NODE_FIELD {
                        let fn2 = self.name_text(d.module, unsafe (*da).at_const(pfid).as_data.field.name);
                        if self.ce_spans_eq(d.module, fn2, m, self.name_text(m, pfname)) { slot = j as i32; break; }
                    }
                }
                if slot < 0 || (1 + (slot as u32)) >= unsafe (*self.obj_ptr(v.as_data.p.obj)).slots.len() as u32 { return -1; }
                let child = unsafe ((*a).list(unsafe (*a).at_const(cid).as_data.pattern.children))[0];
                if refobj != 0 && unsafe (*a).at_const(child).kind == NodeKind::NODE_IDENTIFIER {
                    let pv = CeVal { kind: CV_PTR, tm: 0, ty: TYPE_NONE, as_data: CeValAs { p: CvPtr { obj: refobj, off: 1 + (slot as u32) } } };
                    if f == null || !self.ce_bind(f, child, pv) { return -1; }
                    continue;
                }
                let sv = unsafe (*self.obj_ptr(v.as_data.p.obj)).slots[(1 + slot) as usize];
                if sv.kind == CV_NIL_K { return -1; }
                if unsafe (*a).at_const(child).kind == NodeKind::NODE_IDENTIFIER {
                    if f == null || !self.ce_bind(f, child, sv) { return -1; }
                    continue;
                }
                let r = self.pat_match(f, m, child, sv, uns, 0);
                if r != 1 { return r; }
            }
            return 1;
        }
        return -1;
    }

    fn exec_match(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId, out: *mut CeVal) Flow {
        let a = self.ast_ptr(m);
        let value_n = unsafe (*a).at_const(id).as_data.match_expr.value;
        let arms = unsafe (*a).at_const(id).as_data.match_expr.arms;
        let mut v = self.ev_in(f, m, value_n);
        let mut refobj: u32 = 0;
        let mut guard = 0;
        while guard < 4 && v.kind == CV_PTR {
            let lr = self.ce_loadp(v);
            if !lr.ok { return Flow::Bail; }
            v = lr.v;
            if v.kind == CV_AGG { refobj = v.as_data.p.obj; }
            guard = guard + 1;
        }
        if v.kind == CV_NIL_K { return xfail(f); }
        let sb = self.ce_builtin_of(f, m, self.ce_type(m, value_n));
        let uns = sb != BuiltinType::BT_COUNT && bt_unsigned(sb);
        for i in 0..arms.len {
            let aid = unsafe ((*a).list(arms))[i as usize];
            let pattern = unsafe (*a).at_const(aid).as_data.match_arm.pattern;
            let guard_n = unsafe (*a).at_const(aid).as_data.match_arm.guard;
            let body = unsafe (*a).at_const(aid).as_data.match_arm.body;
            let hit = self.pat_match(f, m, pattern, v, uns, refobj);
            if hit < 0 { return Flow::Bail; }
            if hit == 0 { continue; }
            if guard_n != NODE_NONE {
                let g = self.ev_rval(f, m, guard_n);
                if g.kind != CV_BOOL { return xfail(f); }
                if g.as_data.i == 0 { continue; }
            }
            if out != null {
                unsafe *out = self.ev_in(f, m, body);
                if unsafe (*out).kind != CV_NIL_K { return Flow::Ok; }
                return xfail(f);
            }
            if unsafe (*a).at_const(body).kind == NodeKind::NODE_BLOCK { return self.exec_stmt(f, m, body); }
            return self.exec_expr_stmt(f, m, body);
        }
        return Flow::Bail;
    }

    // --- statements ---
    fn exec_assign(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let left = unsafe (*a).at_const(id).as_data.binary.left;
        let right = unsafe (*a).at_const(id).as_data.binary.right;
        let op = unsafe (*a).at_const(id).as_data.binary.op;
        let pr = self.ev_place(f, m, left);
        if !pr.ok { return xfail(f); }
        let mut r = self.ev_rval(f, m, right);
        if r.kind == CV_NIL_K { return xfail(f); }
        if op != TokenType::Equal {
            let cur = self.ce_loadp(pr.v);
            if !cur.ok { return Flow::Bail; }
            let cop = compound_op(op);
            let lt = self.ce_type(m, left);
            let tb = self.ce_builtin_of(f, m, lt);
            if cur.v.kind == CV_FLOAT && r.kind == CV_FLOAT { r = ce_float_op(cop, cur.v, r, m, lt, tb); }
            else if cur.v.kind == CV_INT && r.kind == CV_INT { r = self.ce_int_op(cop, cur.v, r, m, lt, tb, tb); }
            else { return Flow::Bail; }
            if r.kind == CV_NIL_K { return Flow::Bail; }
        }
        if self.ce_storep(pr.v, r) { return Flow::Ok; }
        return Flow::Bail;
    }

    fn exec_expr_stmt(self: &mut Self, f: *mut CeFrame, m: ModuleId, id0: NodeId) Flow {
        let a = self.ast_ptr(m);
        let mut id = id0;
        loop {
            let k = unsafe (*a).at_const(id).kind;
            if k != NodeKind::NODE_UNARY { break; }
            let op = unsafe (*a).at_const(id).as_data.unary.op;
            if (op != TokenType::Move && op != TokenType::Unsafe)
                || unsafe (*a).at_const(unsafe (*a).at_const(id).as_data.unary.operand).kind == NodeKind::NODE_BLOCK { break; }
            id = unsafe (*a).at_const(id).as_data.unary.operand;
        }
        let k = unsafe (*a).at_const(id).kind;
        if k == NodeKind::NODE_ASSIGNMENT { return self.exec_assign(f, m, id); }
        if k == NodeKind::NODE_MATCH { return self.exec_match(f, m, id, null); }
        if k == NodeKind::NODE_CALL {
            let cr = self.ce_call(f, m, id);
            if cr.ok { return Flow::Ok; }
            return xfail(f);
        }
        if self.ev_in(f, m, id).kind != CV_NIL_K { return Flow::Ok; }
        return xfail(f);
    }

    fn exec_stmt(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        if !self.ce_tick() { return Flow::Bail; }
        let a = self.ast_ptr(m);
        let k = unsafe (*a).at_const(id).kind;
        switch k {
            NODE_BLOCK => {
                let stmts = unsafe (*a).at_const(id).as_data.block.statements;
                let dbase = unsafe (*f).ndefers;
                let mut st = Flow::Ok;
                let mut i: u32 = 0;
                while st == Flow::Ok && i < stmts.len {
                    st = self.exec_stmt(f, m, unsafe ((*a).list(stmts))[i as usize]);
                    i = i + 1;
                }
                let mut j = unsafe (*f).ndefers;
                while j > dbase {
                    j = j - 1;
                    let dv = unsafe (*f).defers[j as usize];
                    let mut ds = Flow::Ok;
                    if unsafe (*a).at_const(dv).kind == NodeKind::NODE_BLOCK { ds = self.exec_stmt(f, m, dv); }
                    else { ds = self.exec_expr_stmt(f, m, dv); }
                    if ds != Flow::Ok { st = Flow::Bail; }
                }
                unsafe (*f).ndefers = dbase;
                return st;
            },
            NODE_LET => { return self.exec_let(f, m, id); },
            NODE_IF => {
                let c = self.ev_rval(f, m, unsafe (*a).at_const(id).as_data.if_stmt.condition);
                if c.kind != CV_BOOL { return xfail(f); }
                if c.as_data.i != 0 { return self.exec_stmt(f, m, unsafe (*a).at_const(id).as_data.if_stmt.then_branch); }
                let eb = unsafe (*a).at_const(id).as_data.if_stmt.else_branch;
                if eb == NODE_NONE { return Flow::Ok; }
                return self.exec_stmt(f, m, eb);
            },
            NODE_WHILE => { return self.exec_while(f, m, id); },
            NODE_FOR => { return self.exec_for(f, m, id); },
            NODE_RETURN => {
                let values = unsafe (*a).at_const(id).as_data.return_stmt.values;
                if values.len > 8 { return Flow::Bail; }
                unsafe (*f).nrets = 0;
                for i in 0..values.len {
                    let v = self.ev_in(f, m, unsafe ((*a).list(values))[i as usize]);
                    if v.kind == CV_NIL_K { return xfail(f); }
                    let nr = unsafe (*f).nrets;
                    unsafe (*f).rets[nr as usize] = v;
                    unsafe (*f).nrets = nr + 1;
                }
                unsafe (*f).returned = 1;
                return Flow::Return;
            },
            NODE_BREAK => {
                let lbl = unsafe (*a).at_const(id).as_data.flow.label;
                if lbl.end > lbl.start || unsafe (*a).at_const(id).as_data.flow.value != NODE_NONE { return Flow::Bail; }
                return Flow::Break;
            },
            NODE_CONTINUE => {
                let lbl = unsafe (*a).at_const(id).as_data.flow.label;
                if lbl.end > lbl.start { return Flow::Bail; }
                return Flow::Continue;
            },
            NODE_DEFER => {
                if unsafe (*f).ndefers >= CE_MAX_DEFERS { return Flow::Bail; }
                let nd = unsafe (*f).ndefers;
                unsafe (*f).defers[nd as usize] = unsafe (*a).at_const(id).as_data.single.value;
                unsafe (*f).ndefers = nd + 1;
                return Flow::Ok;
            },
            NODE_EXPRESSION_STATEMENT => { return self.exec_expr_stmt(f, m, unsafe (*a).at_const(id).as_data.single.value); },
            _ => {},
        };
        return Flow::Bail;
    }

    fn exec_let(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let name_n = unsafe (*a).at_const(id).as_data.let_stmt.name;
        let value_n = unsafe (*a).at_const(id).as_data.let_stmt.value;
        let type_n = unsafe (*a).at_const(id).as_data.let_stmt.ty;
        let nmk = unsafe (*a).at_const(name_n).kind;
        if nmk == NodeKind::NODE_PATTERN_TUPLE {
            let children = unsafe (*a).at_const(name_n).as_data.pattern.children;
            let nbind = children.len;
            if value_n == NODE_NONE { return Flow::Bail; }
            let mut vals: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            let mut nvals: u32 = 0;
            if unsafe (*a).at_const(value_n).kind == NodeKind::NODE_CALL {
                let cr = self.ce_call(f, m, value_n);
                if !cr.ok { return xfail(f); }
                for i in 0..cr.n { vals[i as usize] = cr.vals[i as usize]; }
                nvals = cr.n as u32;
            }
            if nvals <= 1 {
                let mut tv = cv_nil();
                if nvals == 1 { tv = vals[0]; } else { tv = self.ev_rval(f, m, value_n); }
                if tv.kind != CV_AGG { return xfail(f); }
                let o = self.obj_ptr(tv.as_data.p.obj);
                if o == null || (unsafe (*o).slots.len() as u32) < nbind { return Flow::Bail; }
                for i in 0..nbind { vals[i as usize] = unsafe (*self.obj_ptr(tv.as_data.p.obj)).slots[i as usize]; }
                nvals = nbind;
            }
            if nvals != nbind { return Flow::Bail; }
            for i in 0..nbind {
                let cid = unsafe ((*a).list(children))[i as usize];
                if vals[i as usize].kind == CV_NIL_K || !self.ce_bind(f, cid, vals[i as usize]) { return xfail(f); }
            }
            return Flow::Ok;
        }
        if nmk != NodeKind::NODE_IDENTIFIER { return Flow::Bail; }
        let mut v = cv_nil();
        if value_n != NODE_NONE {
            if type_n != NODE_NONE {
                let wr = self.ce_rtype(f, m, self.ce_type(m, type_n));
                if !wr.ok { return Flow::Bail; }
                let raw = self.ev_in(f, m, value_n);
                v = self.ce_coerce(raw, wr.m, wr.t);
            } else {
                v = self.ev_in(f, m, value_n);
            }
            if v.kind == CV_NIL_K { return xfail(f); }
        }
        if self.ce_bind(f, id, v) { return Flow::Ok; }
        return Flow::Bail;
    }

    fn exec_while(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let cond = unsafe (*a).at_const(id).as_data.while_stmt.condition;
        let body = unsafe (*a).at_const(id).as_data.while_stmt.body;
        let mut first = unsafe (*a).at_const(id).as_data.while_stmt.is_do;
        loop {
            if !first && cond != NODE_NONE {
                let c = self.ev_rval(f, m, cond);
                if c.kind != CV_BOOL { return xfail(f); }
                if c.as_data.i == 0 { return Flow::Ok; }
            }
            first = false;
            let st = self.exec_stmt(f, m, body);
            if st == Flow::Break { return Flow::Ok; }
            if st == Flow::Return || st == Flow::Bail { return st; }
            if !self.ce_tick() { return Flow::Bail; }
        }
    }

    fn exec_for(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Flow {
        let a = self.ast_ptr(m);
        let iter_n = unsafe (*a).at_const(id).as_data.for_stmt.iterable;
        let body = unsafe (*a).at_const(id).as_data.for_stmt.body;
        if unsafe (*a).at_const(iter_n).kind == NodeKind::NODE_RANGE {
            let start_n = unsafe (*a).at_const(iter_n).as_data.pattern_range.start;
            let end_n = unsafe (*a).at_const(iter_n).as_data.pattern_range.end;
            let inc = unsafe (*a).at_const(iter_n).as_data.pattern_range.inclusive;
            if start_n == NODE_NONE || end_n == NODE_NONE { return Flow::Bail; }
            let s = self.ev_rval(f, m, start_n);
            if s.kind != CV_INT { return xfail(f); }
            let eb = self.ce_builtin_of(f, m, self.ce_type(m, iter_n));
            let uns = eb != BuiltinType::BT_COUNT && bt_unsigned(eb);
            let et = self.ce_type(m, id);
            if self.ce_bind_slot(f, id) == null { return Flow::Bail; }
            let mut v = s.as_data.i;
            loop {
                let e = self.ev_rval(f, m, end_n);
                if e.kind != CV_INT { return xfail(f); }
                let last = v == e.as_data.i;
                let mut done = false;
                if uns { done = (v as u64) > (e.as_data.i as u64) || (!inc && last); }
                else { done = v > e.as_data.i || (!inc && last); }
                if done { return Flow::Ok; }
                let slot = self.ce_bind_slot(f, id);
                unsafe *slot = CeVal { kind: CV_INT, tm: m, ty: et, as_data: CeValAs { i: v } };
                let st = self.exec_stmt(f, m, body);
                if st == Flow::Break { return Flow::Ok; }
                if st == Flow::Return || st == Flow::Bail { return st; }
                if !self.ce_tick() { return Flow::Bail; }
                if inc && last { return Flow::Ok; }
                v = v + 1;
            }
        }
        let ir = self.ce_rtype(f, m, self.ce_type(m, iter_n));
        if !ir.ok { return Flow::Bail; }
        if unsafe (*self.ast_ptr(ir.m)).type_at(ir.t).kind == TypeKind::TYPE_ARRAY {
            let br = self.ce_base_obj(f, m, iter_n);
            if !br.ok { return Flow::Bail; }
            let len = unsafe (*self.obj_ptr(br.obj)).slots.len() as u32;
            for i in 0..len {
                let sv = unsafe (*self.obj_ptr(br.obj)).slots[i as usize];
                if sv.kind == CV_NIL_K || !self.ce_bind(f, id, sv) { return Flow::Bail; }
                let st = self.exec_stmt(f, m, body);
                if st == Flow::Break { return Flow::Ok; }
                if st == Flow::Return || st == Flow::Bail { return st; }
                if !self.ce_tick() { return Flow::Bail; }
            }
            return Flow::Ok;
        }
        // Iterator protocol
        let iv = self.ev_in(f, m, iter_n);
        if iv.kind == CV_NIL_K { return xfail(f); }
        let tr = self.ce_temp_place(iv);
        if !tr.ok { return Flow::Bail; }
        let itp = tr.v;
        let rr = self.ce_recv_of(f, m, self.ce_type(m, iter_n));
        if !rr.ok || rr.r.dn == NODE_NONE { return Flow::Bail; }
        loop {
            let mut args: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            args[0] = itp;
            let dr = self.ce_dispatch(rr.r, m, "next", (&args[0]) as *const CeVal, 1);
            if !dr.ok || dr.v.kind != CV_AGG { return Flow::Bail; }
            let oo = self.obj_ptr(dr.v.as_data.p.obj);
            if oo == null || unsafe (*oo).is_enum == 0 { return Flow::Bail; }
            let olen = unsafe (*oo).slots.len();
            if olen < 2 || unsafe (*oo).slots[1].kind == CV_NIL_K {
                if olen >= 2 { return Flow::Bail; }
                return Flow::Ok;
            }
            let payload = unsafe (*oo).slots[1];
            if !self.ce_bind(f, id, payload) { return Flow::Bail; }
            let st = self.exec_stmt(f, m, body);
            if st == Flow::Break { return Flow::Ok; }
            if st == Flow::Return || st == Flow::Bail { return st; }
            if !self.ce_tick() { return Flow::Bail; }
        }
    }
}

fn if_i32(c: bool, a: i32, b: i32) i32 { if c { return a; } return b; }
fn if_bool(c: bool, a: bool, b: bool) bool { if c { return a; } return b; }
fn xfail(f: *mut CeFrame) Flow { if f != null && unsafe (*f).early != 0 { return Flow::Return; } return Flow::Bail; }

fn compound_op(op: TokenType) TokenType {
    if op == TokenType::PlusEqual { return TokenType::Plus; }
    if op == TokenType::MinusEqual { return TokenType::Minus; }
    if op == TokenType::StarEqual { return TokenType::Star; }
    if op == TokenType::SlashEqual { return TokenType::Slash; }
    if op == TokenType::PercentEqual { return TokenType::Percent; }
    if op == TokenType::AmpersandEqual { return TokenType::Ampersand; }
    if op == TokenType::PipeEqual { return TokenType::Pipe; }
    if op == TokenType::CaretEqual { return TokenType::Caret; }
    if op == TokenType::LeftShiftEqual { return TokenType::LeftShift; }
    if op == TokenType::RightShiftEqual { return TokenType::RightShift; }
    return TokenType::Equal;
}

fn cv_pub(v: CeVal) ConstValue {
    if v.kind == CV_INT { return ConstValue { kind: CONST_INT, ty: v.ty, as_data: ConstValueAs { i: v.as_data.i } }; }
    if v.kind == CV_BOOL { return ConstValue { kind: CONST_BOOL, ty: v.ty, as_data: ConstValueAs { i: v.as_data.i } }; }
    if v.kind == CV_FLOAT {
        if !ce_isfinite(v.as_data.f) { return ce_none(); }
        return ConstValue { kind: CONST_FLOAT, ty: v.ty, as_data: ConstValueAs { f: v.as_data.f } };
    }
    return ce_none();
}

fn cv_is_scalar(v: CeVal) bool { return v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT; }

// --- calls --------------------------------------------------------------------------------------

extend ConstEval {
    fn ce_subst_add(self: &Self, g: *mut CeFrame, pmod: ModuleId, param: NodeId, am: ModuleId, at: TypeId) bool {
        for i in 0..unsafe (*g).ng {
            if unsafe (*g).pmod == pmod && unsafe (*g).params_g[i as usize] == param {
                return self.ce_teq(unsafe (*g).am[i as usize], unsafe (*g).at[i as usize], am, at);
            }
        }
        if unsafe (*g).ng >= 8 || (unsafe (*g).ng != 0 && unsafe (*g).pmod != pmod) { return false; }
        unsafe (*g).pmod = pmod;
        let ng = unsafe (*g).ng;
        unsafe (*g).params_g[ng as usize] = param;
        unsafe (*g).am[ng as usize] = am;
        unsafe (*g).at[ng as usize] = at;
        unsafe (*g).ng = ng + 1;
        return true;
    }

    fn ce_bind_extend(self: &Self, g: *mut CeFrame, xm: ModuleId, extnode: NodeId, recv: *const CeRecv) bool {
        let xa = self.ast_ptr(xm);
        let gens = unsafe (*xa).at_const(extnode).as_data.extend_def.generics;
        if gens.len == 0 { return true; }
        if recv == null || unsafe (*recv).dn == NODE_NONE { return false; }
        let target = unsafe (*xa).at_const(extnode).as_data.extend_def.target_type;
        if unsafe (*xa).at_const(target).kind != NodeKind::NODE_TYPE_PATH
            || unsafe (*xa).at_const(target).as_data.type_path.args.len != (unsafe (*recv).n as u32) { return false; }
        let targs = unsafe (*xa).at_const(target).as_data.type_path.args;
        for i in 0..unsafe (*recv).n {
            let aid = unsafe ((*xa).list(targs))[i as usize];
            let ad = unsafe (*xa).resolution_def(aid);
            if ad.node != NODE_NONE && (ad.module as usize) < self.nmods
                && unsafe (*self.ast_ptr(ad.module)).at_const(ad.node).kind == NodeKind::NODE_GENERIC_PARAM {
                if !self.ce_subst_add(g, ad.module, ad.node, unsafe (*recv).am[i as usize], unsafe (*recv).at[i as usize]) { return false; }
            } else {
                let at2 = self.ce_type(xm, aid);
                if at2 == TYPE_NONE || !self.ce_teq(xm, at2, unsafe (*recv).am[i as usize], unsafe (*recv).at[i as usize]) { return false; }
            }
        }
        let gids = unsafe (*xa).list(gens);
        for j in 0..gens.len {
            let mut bound = false;
            for k in 0..unsafe (*g).ng {
                if unsafe (*g).pmod == xm && unsafe (*g).params_g[k as usize] == unsafe gids[j as usize] { bound = true; }
            }
            if !bound { return false; }
        }
        return true;
    }

    // Intercepted extern calls: the C heap, the trap runtime, and libm.
    fn ce_intercept(self: &mut Self, fm: ModuleId, fnode: NodeId, args: *const CeVal, nargs: u32, m: ModuleId, callId: NodeId) Rets {
        let fa = self.ast_ptr(fm);
        let nm = self.name_text(fm, unsafe (*fa).at_const(fnode).as_data.function.name);
        let rt = self.ce_type(m, callId);
        let mut out = Rets { ok: false, n: 0 };
        if self.ce_span_is(fm, nm, "malloc") {
            if nargs != 1 || unsafe args[0].kind != CV_INT || unsafe args[0].as_data.i < 0 { return out; }
            let o = self.ce_obj_new(0);
            if o == 0 { return out; }
            unsafe (*self.obj_ptr(o)).heap = 1;
            unsafe (*self.obj_ptr(o)).bytes = unsafe args[0].as_data.i as u64;
            unsafe (*self.obj_ptr(o)).et = TYPE_NONE;
            out.vals[0] = CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "realloc") {
            if nargs != 2 || unsafe args[0].kind != CV_PTR || unsafe args[1].kind != CV_INT || unsafe args[1].as_data.i < 0 { return out; }
            let nbytes = unsafe args[1].as_data.i as u64;
            if unsafe args[0].as_data.p.obj == 0 {
                let o = self.ce_obj_new(0);
                if o == 0 { return out; }
                unsafe (*self.obj_ptr(o)).heap = 1;
                unsafe (*self.obj_ptr(o)).bytes = nbytes;
                unsafe (*self.obj_ptr(o)).et = TYPE_NONE;
                out.vals[0] = CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
                out.n = 1;
                out.ok = true;
                return out;
            }
            let b = self.obj_ptr(unsafe args[0].as_data.p.obj);
            if b == null || unsafe (*b).heap == 0 || unsafe args[0].as_data.p.off != 0 { return out; }
            if unsafe (*b).dead != 0 { self.ce_trap("use after free"); return out; }
            if unsafe (*b).et != TYPE_NONE {
                let esz = unsafe (*b).esz;
                if esz == 0 || nbytes % esz != 0 { return out; }
                if !self.ce_obj_resize(unsafe args[0].as_data.p.obj, (nbytes / esz) as u32) { return out; }
            }
            unsafe (*self.obj_ptr(unsafe args[0].as_data.p.obj)).bytes = nbytes;
            out.vals[0] = CeVal { kind: CV_PTR, tm: m, ty: rt, as_data: CeValAs { p: CvPtr { obj: unsafe args[0].as_data.p.obj, off: 0 } } };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "free") {
            if nargs != 1 || unsafe args[0].kind != CV_PTR { return out; }
            if unsafe args[0].as_data.p.obj == 0 { out.ok = true; return out; }
            let b = self.obj_ptr(unsafe args[0].as_data.p.obj);
            if b == null || unsafe (*b).heap == 0 || unsafe args[0].as_data.p.off != 0 { return out; }
            if unsafe (*b).dead != 0 { self.ce_trap("double free"); return out; }
            unsafe (*b).dead = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "memset") {
            if nargs != 3 || unsafe args[0].kind != CV_PTR || unsafe args[1].kind != CV_INT || unsafe args[2].kind != CV_INT || unsafe args[2].as_data.i < 0 { return out; }
            let n = unsafe args[2].as_data.i as u64;
            if unsafe args[0].as_data.p.obj == 0 { out.ok = n == 0; return out; }
            let b = self.obj_ptr(unsafe args[0].as_data.p.obj);
            if b == null || unsafe (*b).heap == 0 { return out; }
            if unsafe (*b).dead != 0 { self.ce_trap("use after free"); return out; }
            if unsafe (*b).et == TYPE_NONE && unsafe args[0].as_data.p.off == 0 {
                let bytes = unsafe (*b).bytes;
                if !self.ce_obj_resize(unsafe args[0].as_data.p.obj, bytes as u32) { return out; }
                let b2 = self.obj_ptr(unsafe args[0].as_data.p.obj);
                unsafe (*b2).em = 0;
                unsafe (*b2).et = Ast::builtin(BuiltinType::BT_U8);
                unsafe (*b2).esz = 1;
            }
            let bb = self.obj_ptr(unsafe args[0].as_data.p.obj);
            let esz = unsafe (*bb).esz;
            if esz == 0 || n % esz != 0 { return out; }
            let count = n / esz;
            let off = unsafe args[0].as_data.p.off as u64;
            if off + count > unsafe (*bb).slots.len() as u64 { self.ce_trap("out-of-bounds access"); return out; }
            let mut fill = cv_nil();
            if esz == 1 { fill = CeVal { kind: CV_INT, tm: 0, ty: Ast::builtin(BuiltinType::BT_U8), as_data: CeValAs { i: unsafe args[1].as_data.i & 0xff } }; }
            else {
                if unsafe args[1].as_data.i != 0 { return out; }
                fill = self.ce_zero(unsafe (*bb).em, unsafe (*bb).et, 0);
                if fill.kind == CV_NIL_K { return out; }
            }
            for i in 0..count {
                let cloned = self.ce_clone(fill, 0);
                unsafe (*self.obj_ptr(unsafe args[0].as_data.p.obj)).slots.set((off + i) as usize, cloned);
            }
            out.vals[0] = unsafe args[0];
            out.n = 1;
            out.ok = true;
            return out;
        }
        if self.ce_span_is(fm, nm, "abort") { self.ce_trap("abort reached at compile time"); return out; }
        if self.ce_span_is(fm, nm, "__sc_panic_str") || self.ce_span_is(fm, nm, "__sc_panic") { self.ce_trap("panic reached at compile time"); return out; }
        // libm
        let ln = (nm.end - nm.start) as usize;
        if ln >= 24 || nargs < 1 || nargs > 3 { return out; }
        let mut name = Buf24 {};
        for ci in 0..ln { name.b[ci] = unsafe (self.ce_src(fm))[(nm.start as usize) + ci] as char; }
        name.b[ln] = 0 as char;
        let mut f32suf = false;
        if ln > 1 && name.b[ln - 1] == 'f' as char { f32suf = true; name.b[ln - 1] = 0 as char; }
        let mut inv: [f64; 3] = [0.0f64, 0.0f64, 0.0f64];
        for i in 0..nargs {
            if unsafe args[i as usize].kind != CV_FLOAT { return out; }
            inv[i as usize] = unsafe args[i as usize].as_data.f;
        }
        let nv = diag::cstr((&name.b[0]) as *const char);
        let mut v: f64 = 0.0;
        let mut ok = false;
        if nargs == 1 { let r = libm1(nv, inv[0]); ok = r.ok; v = r.v; }
        else if nargs == 2 { let r = libm2(nv, inv[0], inv[1]); ok = r.ok; v = r.v; }
        else { if nv == "fma" { v = unsafe math::fma(inv[0], inv[1], inv[2]); ok = true; } }
        if !ok { return out; }
        if f32suf { v = (v as f32) as f64; }
        out.vals[0] = CeVal { kind: CV_FLOAT, tm: m, ty: rt, as_data: CeValAs { f: v } };
        out.n = 1;
        out.ok = true;
        return out;
    }

    // Run a resolved concrete function/closure body in a fresh frame.
    fn ce_invoke(self: &mut Self, fm: ModuleId, fnode: NodeId, extend_node: NodeId, recv: *const CeRecv,
                 monom: *const ModuleId, monot: *const TypeId, nmono: u8, args: *const CeVal, nargs: u32,
                 self_pm: ModuleId, self_decl: NodeId, self_am: ModuleId, self_at: TypeId) Rets {
        let mut out = Rets { ok: false, n: 0 };
        let fa = self.ast_ptr(fm);
        let closure = unsafe (*fa).at_const(fnode).kind == NodeKind::NODE_CLOSURE;
        if !closure && unsafe (*fa).at_const(fnode).kind != NodeKind::NODE_FUNCTION { return out; }
        let mut params = NodeList { start: 0, len: 0 };
        let mut body = NODE_NONE;
        if closure { params = unsafe (*fa).at_const(fnode).as_data.closure.params; body = unsafe (*fa).at_const(fnode).as_data.closure.body; }
        else { params = unsafe (*fa).at_const(fnode).as_data.function.params; body = unsafe (*fa).at_const(fnode).as_data.function.body; }
        if body == NODE_NONE || params.len != nargs { return out; }
        if !closure && unsafe (*fa).at_const(fnode).as_data.function.is_variadic { return out; }
        if self.nframes >= CE_MAX_FRAMES { self.ce_trap("const-eval call depth exceeded"); return out; }
        let mut g = ce_frame_zero();
        let gp = (&mut g) as *mut CeFrame;
        if self_decl != NODE_NONE && !self.ce_subst_add(gp, self_pm, self_decl, self_am, self_at) { return out; }
        if extend_node != NODE_NONE {
            let xg = unsafe (*fa).at_const(extend_node).as_data.extend_def.generics;
            let mut bound = xg.len == 0;
            if !bound && recv != null && unsafe (*recv).dn != NODE_NONE && unsafe (*recv).n != 0 {
                bound = self.ce_bind_extend(gp, fm, extend_node, recv);
            }
            if !bound {
                if (nmono as u32) < xg.len { return out; }
                let gids = unsafe (*fa).list(xg);
                for i in 0..xg.len {
                    if unsafe monot[i as usize] == TYPE_NONE || !unsafe (*self.ast_ptr(unsafe monom[i as usize])).type_concrete(unsafe monot[i as usize]) { return out; }
                    if !self.ce_subst_add(gp, fm, unsafe gids[i as usize], unsafe monom[i as usize], unsafe monot[i as usize]) { return out; }
                }
            }
        }
        if !closure {
            let fg = unsafe (*fa).at_const(fnode).as_data.function.generics;
            if fg.len != 0 {
                if (nmono as u32) < fg.len { return out; }
                let skip = (nmono as u32) - fg.len;
                let gids = unsafe (*fa).list(fg);
                for i in 0..fg.len {
                    let idx = (skip + i) as usize;
                    if unsafe monot[idx] == TYPE_NONE || !unsafe (*self.ast_ptr(unsafe monom[idx])).type_concrete(unsafe monot[idx]) { return out; }
                    if !self.ce_subst_add(gp, fm, unsafe gids[i as usize], unsafe monom[idx], unsafe monot[idx]) { return out; }
                }
            }
        }
        // memoization
        let mut cacheable = !closure && unsafe (*gp).ng == 0 && nargs <= 8;
        let mut ai: u32 = 0;
        while cacheable && ai < nargs { cacheable = cv_is_scalar(unsafe args[ai as usize]); ai = ai + 1; }
        let mut ck = CeCallKey { m: fm, fn_id: fnode, nargs: nargs as u8 };
        if cacheable {
            for i in 0..nargs { ck.kinds[i as usize] = unsafe args[i as usize].kind; ck.bits[i as usize] = unsafe args[i as usize].as_data.i; }
            if let Some(hit) = self.calls.get(&ck) {
                out.n = hit.nrets;
                for j in 0..hit.nrets { out.vals[j as usize] = hit.rets[j as usize]; }
                out.ok = true;
                return out;
            }
        }
        unsafe (*gp).env = self.ce_obj_new(0);
        if unsafe (*gp).env == 0 { return out; }
        let pids = unsafe (*fa).list(params);
        for i in 0..nargs {
            let pt0 = self.ce_type(fm, unsafe (*fa).at_const(unsafe pids[i as usize]).as_data.parameter.ty);
            let mut v = unsafe args[i as usize];
            let rr = self.ce_rtype(gp, fm, pt0);
            if rr.ok { v = self.ce_coerce(v, rr.m, rr.t); }
            if v.kind == CV_NIL_K || !self.ce_bind(gp, unsafe pids[i as usize], v) { return out; }
        }
        self.nframes = self.nframes + 1;
        let saved = self.depth;
        self.depth = 0;
        let mut st = Flow::Ok;
        if closure && unsafe (*fa).at_const(fnode).as_data.closure.expr_body {
            let v = self.ev_in(gp, fm, body);
            if v.kind == CV_NIL_K { st = Flow::Bail; } else { st = Flow::Return; }
            unsafe (*gp).rets[0] = v;
            unsafe (*gp).nrets = 1;
            unsafe (*gp).returned = 1;
        } else {
            st = self.exec_stmt(gp, fm, body);
        }
        self.depth = saved;
        self.nframes = self.nframes - 1;
        if st == Flow::Bail || st == Flow::Break || st == Flow::Continue { return out; }
        let mut wantret: u32 = 1;
        if !closure {
            wantret = unsafe (*fa).at_const(fnode).as_data.function.returns.len;
            if wantret == 1 {
                let r0 = unsafe ((*fa).list(unsafe (*fa).at_const(fnode).as_data.function.returns))[0];
                if type_builtin(fa, self.ce_type(fm, r0)) == BuiltinType::BT_VOID { wantret = 0; }
            }
        }
        if unsafe (*gp).returned == 0 {
            if wantret > 0 && st != Flow::Return { return out; }
            unsafe (*gp).nrets = 0;
        }
        out.n = unsafe (*gp).nrets;
        for j in 0..unsafe (*gp).nrets { out.vals[j as usize] = unsafe (*gp).rets[j as usize]; }
        if cacheable && out.n <= 8 {
            let mut pure = true;
            let mut k: u8 = 0;
            while pure && k < out.n { pure = cv_is_scalar(out.vals[k as usize]); k = k + 1; }
            if pure && self.calls.len() < CE_CALLS_MAX {
                let mut hit = CeCallHit { nrets: out.n };
                for z in 0..out.n { hit.rets[z as usize] = out.vals[z as usize]; }
                self.calls.insert(ck, hit);
            }
        }
        out.ok = true;
        return out;
    }

    fn ce_dispatch(self: &mut Self, r: CeRecv, scope: ModuleId, lit: str, args: *const CeVal, nargs: u32) ValRes {
        let mut extnode = NODE_NONE;
        let md = self.ce_find_method(r, scope, 0, tok::Span::empty(), lit, (&mut extnode) as *mut NodeId);
        if md.node == NODE_NONE { return ValRes { ok: false }; }
        let inv = self.ce_invoke(md.module, md.node, extnode, (&r) as *const CeRecv, null, null, 0, args, nargs, 0, NODE_NONE, 0, TYPE_NONE);
        if !inv.ok { return ValRes { ok: false }; }
        let mut out = cv_nil();
        if inv.n != 0 { out = inv.vals[0]; }
        return ValRes { ok: true, v: out };
    }

    fn ce_call(self: &mut Self, f: *mut CeFrame, m: ModuleId, id: NodeId) Rets {
        let a = self.ast_ptr(m);
        let mut callee = unsafe (*a).at_const(id).as_data.call.callee;
        let mut ck = unsafe (*a).at_const(callee).kind;
        if ck == NodeKind::NODE_GENERIC_SPECIALIZATION {
            callee = unsafe (*a).at_const(callee).as_data.specialization.expression;
            ck = unsafe (*a).at_const(callee).kind;
        }
        let call_args = unsafe (*a).at_const(id).as_data.call.args;
        let nargs = call_args.len;
        let mut out = Rets { ok: false, n: 0 };
        if nargs + 1 > 8 { return out; }

        let mut fd = DefId { module: 0, node: NODE_NONE };
        let mut recv_expr = NODE_NONE;
        let mut du: *const DerefUse = null;
        let mut have_recv_type = false;
        let mut recv_syn = DefId { module: 0, node: NODE_NONE };
        let mut rtm: ModuleId = 0;
        let mut rtt = TYPE_NONE;
        if ck == NodeKind::NODE_IDENTIFIER {
            fd = unsafe (*a).resolution_def(callee);
            if fd.node == NODE_NONE { fd = DefId { module: m, node: unsafe (*a).resolution(callee) }; }
            if fd.node != NODE_NONE && (fd.module as usize) < self.nmods
                && unsafe (*self.ast_ptr(fd.module)).at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
                let v = self.ev_rval(f, m, callee);
                if v.kind != CV_FN { return out; }
                fd = DefId { module: v.as_data.fnv.m, node: v.as_data.fnv.fn_id };
            }
        } else if ck == NodeKind::NODE_MEMBER {
            fd = unsafe (*a).resolution_def(callee);
            if fd.node == NODE_NONE { fd = unsafe (*a).resolution_def(unsafe (*a).at_const(callee).as_data.member.member); }
            let is_path = unsafe (*a).at_const(callee).as_data.member.path;
            let obj_n = unsafe (*a).at_const(callee).as_data.member.object;
            if is_path {
                if obj_n != NODE_NONE && self.ce_type(m, obj_n) != TYPE_NONE {
                    have_recv_type = true;
                    rtm = m;
                    rtt = self.ce_type(m, obj_n);
                } else if obj_n != NODE_NONE {
                    recv_syn = unsafe (*a).resolution_def(obj_n);
                    if recv_syn.node == NODE_NONE { recv_syn = DefId { module: m, node: unsafe (*a).resolution(obj_n) }; }
                }
            } else {
                recv_expr = obj_n;
                have_recv_type = true;
                rtm = m;
                rtt = self.ce_type(m, recv_expr);
                du = unsafe (*a).deref_use_at(unsafe (*a).at_const(callee).as_data.member.member);
                if fd.node == NODE_NONE {
                    let mname = self.name_text(m, unsafe (*a).at_const(callee).as_data.member.member);
                    if !self.ce_span_is(m, mname, "free") || nargs != 0 { return out; }
                    let sr = self.ce_strip_refptr(f, rtm, rtt);
                    if !sr.ok { return out; }
                    let rr = self.ce_recv_of(f, sr.m, sr.t);
                    if !rr.ok { return out; }
                    if rr.r.dn == NODE_NONE { out.ok = true; return out; }
                    let mut extnode = NODE_NONE;
                    let md = self.ce_find_method(rr.r, m, 0, tok::Span::empty(), "free", (&mut extnode) as *mut NodeId);
                    if md.node == NODE_NONE { out.ok = true; return out; }
                    let mut recv = cv_nil();
                    let pr = self.ev_place(f, m, recv_expr);
                    if pr.ok { recv = pr.v; }
                    else {
                        let rv = self.ev_in(f, m, recv_expr);
                        if rv.kind == CV_PTR { recv = rv; }
                        else {
                            let tr = self.ce_temp_place(rv);
                            if rv.kind == CV_NIL_K || !tr.ok { return out; }
                            recv = tr.v;
                        }
                    }
                    let mut avs: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
                    avs[0] = recv;
                    return self.ce_invoke(md.module, md.node, extnode, (&rr.r) as *const CeRecv, null, null, 0, (&avs[0]) as *const CeVal, 1, 0, NODE_NONE, 0, TYPE_NONE);
                }
            }
        } else { return out; }
        if fd.node == NODE_NONE || (fd.module as usize) >= self.nmods { return out; }
        let mut fam = fd.module;
        let mut fnode = fd.node;
        let mut fkind = unsafe (*self.ast_ptr(fam)).at_const(fnode).kind;

        if fkind == NodeKind::NODE_VARIANT {
            let vp = self.ce_variant_pos(fd.module, fd.node);
            if vp.pos < 0 || !self.ce_enum_tagged(fd.module, vp.enum_decl) { return out; }
            let vpayload = unsafe (*self.ast_ptr(fd.module)).at_const(fd.node).as_data.variant.payload;
            if vpayload.len != nargs || self.ce_user_free(fd.module, vp.enum_decl) { return out; }
            let o = self.ce_obj_new(1 + nargs);
            if o == 0 { return out; }
            unsafe (*self.obj_ptr(o)).is_enum = 1;
            unsafe (*self.obj_ptr(o)).dm = fd.module;
            unsafe (*self.obj_ptr(o)).dn = vp.enum_decl;
            unsafe (*self.obj_ptr(o)).slots.set(0, CeVal { kind: CV_INT, tm: 0, ty: TYPE_NONE, as_data: CeValAs { i: vp.pos as i64 } });
            for i in 0..nargs {
                let v = self.ev_in(f, m, unsafe ((*a).list(call_args))[i as usize]);
                if v.kind == CV_NIL_K { return out; }
                let cloned = self.ce_clone(v, 0);
                if cloned.kind == CV_NIL_K { return out; }
                unsafe (*self.obj_ptr(o)).slots.set((1 + i) as usize, cloned);
            }
            out.vals[0] = CeVal { kind: CV_AGG, tm: m, ty: self.ce_type(m, id), as_data: CeValAs { p: CvPtr { obj: o, off: 0 } } };
            out.n = 1;
            out.ok = true;
            return out;
        }
        if fkind != NodeKind::NODE_FUNCTION && fkind != NodeKind::NODE_CLOSURE { return out; }

        let mut recv_id = ce_recv_zero();
        let mut have_recv_id = false;
        if have_recv_type {
            let mut dt = rtt;
            if du != null { dt = unsafe (*du).target; }
            let sr = self.ce_strip_refptr(f, rtm, dt);
            if sr.ok {
                let rr = self.ce_recv_of(f, sr.m, sr.t);
                have_recv_id = rr.ok;
                if rr.ok { recv_id = rr.r; }
            }
        } else if recv_syn.node != NODE_NONE && (recv_syn.module as usize) < self.nmods {
            let odk = unsafe (*self.ast_ptr(recv_syn.module)).at_const(recv_syn.node).kind;
            if odk == NodeKind::NODE_GENERIC_PARAM && f != null {
                for i in 0..unsafe (*f).ng {
                    if unsafe (*f).pmod == recv_syn.module && unsafe (*f).params_g[i as usize] == recv_syn.node {
                        let rr = self.ce_recv_of(null, unsafe (*f).am[i as usize], unsafe (*f).at[i as usize]);
                        have_recv_id = rr.ok;
                        if rr.ok { recv_id = rr.r; }
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
        if fkind != NodeKind::NODE_CLOSURE { ckind = self.ce_container_of(fd.module, fd.node, (&mut container) as *mut NodeId); }
        let mut self_pm: ModuleId = 0;
        let mut self_decl = NODE_NONE;
        let mut self_am: ModuleId = 0;
        let mut self_at = TYPE_NONE;
        if ckind == 2 {
            if !have_recv_id { return out; }
            let mname = self.name_text(fam, unsafe (*self.ast_ptr(fam)).at_const(fnode).as_data.function.name);
            let mut extnode = NODE_NONE;
            let md = self.ce_find_method(recv_id, m, fd.module, mname, "", (&mut extnode) as *mut NodeId);
            if md.node != NODE_NONE {
                fd = md;
                fam = fd.module;
                fnode = fd.node;
                fkind = unsafe (*self.ast_ptr(fam)).at_const(fnode).kind;
                container = extnode;
                ckind = 1;
            } else if unsafe (*self.ast_ptr(fam)).at_const(fnode).as_data.function.body != NODE_NONE {
                if recv_id.dn == NODE_NONE { self_at = Ast::builtin(recv_id.b); }
                else if recv_id.n == 0 { self_at = self.ce_pool_find_type(recv_id.dm, recv_id.dn); }
                else { self_at = TYPE_NONE; }
                if self_at == TYPE_NONE { return out; }
                self_am = 0;
                if recv_id.dn != NODE_NONE { self_am = recv_id.dm; }
                self_pm = fd.module;
                self_decl = container;
                ckind = 0;
            } else { return out; }
        }

        // extern
        if fkind == NodeKind::NODE_FUNCTION && unsafe (*self.ast_ptr(fam)).at_const(fnode).as_data.function.is_extern {
            let mut argv: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
            for i in 0..nargs {
                argv[i as usize] = self.ev_rval(f, m, unsafe ((*a).list(call_args))[i as usize]);
                if argv[i as usize].kind == CV_NIL_K { return out; }
            }
            return self.ce_intercept(fd.module, fnode, (&argv[0]) as *const CeVal, nargs, m, id);
        }

        // arguments; a method receiver is param 0
        let mut argv: [CeVal; 9] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
        let mut na: u32 = 0;
        let mut params = NodeList { start: 0, len: 0 };
        if fkind == NodeKind::NODE_CLOSURE { params = unsafe (*self.ast_ptr(fam)).at_const(fnode).as_data.closure.params; }
        else { params = unsafe (*self.ast_ptr(fam)).at_const(fnode).as_data.function.params; }
        if recv_expr != NODE_NONE {
            if params.len != nargs + 1 { return out; }
            let p0 = unsafe ((*self.ast_ptr(fam)).list(params))[0];
            let p0t = self.ce_type(fam, unsafe (*self.ast_ptr(fam)).at_const(p0).as_data.parameter.ty);
            let want_ref = p0t != TYPE_NONE && unsafe (*self.ast_ptr(fam)).type_at(p0t).kind == TypeKind::TYPE_REFERENCE;
            if want_ref || du != null {
                let sr = self.ce_rtype(f, m, rtt);
                let mut recv_is_ptr = false;
                if sr.ok {
                    let sk = unsafe (*self.ast_ptr(sr.m)).type_at(sr.t).kind;
                    recv_is_ptr = sk == TypeKind::TYPE_REFERENCE || sk == TypeKind::TYPE_POINTER;
                }
                if recv_is_ptr {
                    argv[na as usize] = self.ev_in(f, m, recv_expr);
                    if argv[na as usize].kind != CV_PTR { return out; }
                } else {
                    let pr = self.ev_place(f, m, recv_expr);
                    if pr.ok { argv[na as usize] = pr.v; }
                    else {
                        let rv = self.ev_in(f, m, recv_expr);
                        let tr = self.ce_temp_place(rv);
                        if rv.kind == CV_NIL_K || !tr.ok { return out; }
                        argv[na as usize] = tr.v;
                    }
                }
            } else {
                argv[na as usize] = self.ev_rval(f, m, recv_expr);
                if argv[na as usize].kind == CV_NIL_K { return out; }
            }
            if du != null {
                for hi in 0..unsafe (*du).n {
                    let hrr = self.ce_recv_of(f, m, unsafe (*du).recv[hi as usize]);
                    let mut hext = NODE_NONE;
                    if !hrr.ok || self.ce_container_of(unsafe (*du).method[hi as usize].module, unsafe (*du).method[hi as usize].node, (&mut hext) as *mut NodeId) != 1 { return out; }
                    let mut ha: [CeVal; 8] = [cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil(), cv_nil()];
                    ha[0] = argv[na as usize];
                    let hinv = self.ce_invoke(unsafe (*du).method[hi as usize].module, unsafe (*du).method[hi as usize].node, hext, (&hrr.r) as *const CeRecv, null, null, 0, (&ha[0]) as *const CeVal, 1, 0, NODE_NONE, 0, TYPE_NONE);
                    if !hinv.ok || hinv.n != 1 || hinv.vals[0].kind != CV_PTR { return out; }
                    argv[na as usize] = hinv.vals[0];
                }
                if !want_ref {
                    let lr = self.ce_loadp(argv[na as usize]);
                    if !lr.ok { return out; }
                    argv[na as usize] = lr.v;
                }
            }
            na = na + 1;
        } else if params.len != nargs { return out; }
        for i in 0..nargs {
            argv[na as usize] = self.ev_in(f, m, unsafe ((*a).list(call_args))[i as usize]);
            if argv[na as usize].kind == CV_NIL_K { return out; }
            na = na + 1;
        }

        // mono args
        let mut monom: [ModuleId; 4] = [0u16, 0u16, 0u16, 0u16];
        let mut monot: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
        let mut nmono: u8 = 0;
        let mu = unsafe (*a).type_args(id);
        if mu != null {
            let mut k: u8 = 0;
            while k < unsafe (*mu).n && k < 4 {
                monom[nmono as usize] = m;
                monot[nmono as usize] = self.ce_subst_deep(f, m, unsafe (*mu).args[k as usize], 0);
                nmono = nmono + 1;
                k = k + 1;
            }
        }
        let mut ext_arg = NODE_NONE;
        if ckind == 1 { ext_arg = container; }
        let mut rp: *const CeRecv = null;
        if have_recv_id { rp = (&recv_id) as *const CeRecv; }
        return self.ce_invoke(fd.module, fd.node, ext_arg, rp, (&monom[0]) as *const ModuleId, (&monot[0]) as *const TypeId, nmono, (&argv[0]) as *const CeVal, na, self_pm, self_decl, self_am, self_at);
    }

    // --- public boundary ---
    pub fn eval(self: &mut Self, m: ModuleId, id: NodeId) ConstValue {
        if id == NODE_NONE || (m as usize) >= self.nmods { return ce_none(); }
        let memo = self.slot_get(m, id);
        if memo.kind != CONST_NONE { return memo; }
        if self.depth > (CE_MAX_DEPTH as u32) { return ce_none(); }
        let top = self.depth == 0 && self.nframes == 0;
        if top { self.steps = 0; self.trap = ""; self.ce_objs_reset(); }
        self.depth = self.depth + 1;
        let v = self.ev(null, m, id);
        self.depth = self.depth - 1;
        let pub_v = cv_pub(v);
        if top { self.ce_objs_reset(); }
        if pub_v.kind != CONST_NONE { self.slot_set(m, id, pub_v); }
        return pub_v;
    }

    pub fn ce_trap_get(self: &Self) str { return self.trap; }

    pub fn defer_assert(self: &mut Self, m: ModuleId, cond: NodeId) void {
        self.pending.push(CePending { m: m, cond: cond });
    }

    pub fn flush_asserts(self: &mut Self, err: fn(*mut void, ModuleId, NodeId, *const char) void, ctx: *mut void) void {
        for i in 0..self.pending.len() {
            let p = self.pending[i];
            let v = self.eval(p.m, p.cond);
            if v.kind == CONST_BOOL && v.as_data.i == 0 { err(ctx, p.m, p.cond, null); }
            else if v.kind == CONST_NONE && self.trap.len() != 0 { err(ctx, p.m, p.cond, self.trap.ptr() as *const char); }
        }
        self.pending.clear();
    }
}

extend ConstEval as Free {
    pub fn free(self: &mut Self) void {
        self.vals.free();
        self.objs.free();
        self.pending.free();
        self.calls.free();
        self.ufree.free();
    }
}

fn libm1(name: str, x: f64) DblRes {
    if name == "sqrt" { return DblRes { ok: true, v: unsafe math::sqrt(x) }; }
    if name == "cbrt" { return DblRes { ok: true, v: unsafe math::cbrt(x) }; }
    if name == "exp" { return DblRes { ok: true, v: unsafe math::exp(x) }; }
    if name == "exp2" { return DblRes { ok: true, v: unsafe math::exp2(x) }; }
    if name == "expm1" { return DblRes { ok: true, v: unsafe math::expm1(x) }; }
    if name == "log" { return DblRes { ok: true, v: unsafe math::log(x) }; }
    if name == "log2" { return DblRes { ok: true, v: unsafe math::log2(x) }; }
    if name == "log10" { return DblRes { ok: true, v: unsafe math::log10(x) }; }
    if name == "log1p" { return DblRes { ok: true, v: unsafe math::log1p(x) }; }
    if name == "sin" { return DblRes { ok: true, v: unsafe math::sin(x) }; }
    if name == "cos" { return DblRes { ok: true, v: unsafe math::cos(x) }; }
    if name == "tan" { return DblRes { ok: true, v: unsafe math::tan(x) }; }
    if name == "asin" { return DblRes { ok: true, v: unsafe math::asin(x) }; }
    if name == "acos" { return DblRes { ok: true, v: unsafe math::acos(x) }; }
    if name == "atan" { return DblRes { ok: true, v: unsafe math::atan(x) }; }
    if name == "sinh" { return DblRes { ok: true, v: unsafe math::sinh(x) }; }
    if name == "cosh" { return DblRes { ok: true, v: unsafe math::cosh(x) }; }
    if name == "tanh" { return DblRes { ok: true, v: unsafe math::tanh(x) }; }
    if name == "asinh" { return DblRes { ok: true, v: unsafe math::asinh(x) }; }
    if name == "acosh" { return DblRes { ok: true, v: unsafe math::acosh(x) }; }
    if name == "atanh" { return DblRes { ok: true, v: unsafe math::atanh(x) }; }
    if name == "floor" { return DblRes { ok: true, v: unsafe math::floor(x) }; }
    if name == "ceil" { return DblRes { ok: true, v: unsafe math::ceil(x) }; }
    if name == "round" { return DblRes { ok: true, v: unsafe math::round(x) }; }
    if name == "trunc" { return DblRes { ok: true, v: unsafe math::trunc(x) }; }
    if name == "fabs" { return DblRes { ok: true, v: unsafe math::fabs(x) }; }
    return DblRes { ok: false, v: 0.0 };
}

fn libm2(name: str, x: f64, y: f64) DblRes {
    if name == "pow" { return DblRes { ok: true, v: unsafe math::pow(x, y) }; }
    if name == "hypot" { return DblRes { ok: true, v: unsafe math::hypot(x, y) }; }
    if name == "atan2" { return DblRes { ok: true, v: unsafe math::atan2(x, y) }; }
    if name == "fmod" { return DblRes { ok: true, v: unsafe math::fmod(x, y) }; }
    if name == "copysign" { return DblRes { ok: true, v: unsafe math::copysign(x, y) }; }
    if name == "fmin" { return DblRes { ok: true, v: unsafe math::fmin(x, y) }; }
    if name == "fmax" { return DblRes { ok: true, v: unsafe math::fmax(x, y) }; }
    return DblRes { ok: false, v: 0.0 };
}

pub struct DblRes { pub ok: bool, pub v: f64 }
