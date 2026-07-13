import string as cstring;
import stdlib;
import stdio;
import lexer::token as tok;
import lexer::token_type as *;
import ast::ast as *;
import module::loader as loader;
import consteval::consteval as ce;
import utils::errors as diag;

pub const TYPE_ALIAS_MAX_DEPTH: u32 = 64;
pub const BOUND_MAX_DEPTH: i32 = 8;
pub const PLACE_MAX_STEPS: i32 = 16;
pub const MATCH_MAX_VARIANTS: u32 = 256;
pub const BORROW_ESCAPE_MAX_DEPTH: u32 = 64;

pub const BORROW_SHARED: u8 = 0;
pub const BORROW_MUT: u8 = 1;
pub const PS_FIELD: u8 = 0;
pub const PS_INDEX: u8 = 1;
pub const PS_DEREF: u8 = 2;

// --- fixed-buffer / small-array wrappers (a struct field zero-inits its array) ------------------
pub type Buf96 = Array<char, 96>;
pub type Buf512 = Array<char, 512>;
pub type Defs8 = Array<DefId, 8>;
pub type Tys8 = Array<TypeId, 8>;
pub type BoundArr8 = Array<BoundIface, 8>;
pub type Names14 = Array<*const char, 16>;
pub type Steps16 = Array<PStep, 16>;
pub type Keep256 = Array<bool, 256>;
pub type Cover4 = Array<u64, 4>;
pub type Buf128 = Array<char, 128>;
pub type NodeArr16 = Array<NodeId, 16>;

pub struct Borrow {
    pub root: NodeId,
    pub place: NodeId,
    pub origin: NodeId,
    pub binding: NodeId,
    pub region: u16,
    pub kind: u8,
}

pub struct PStep {
    pub kind: u8,
    pub index_const: bool,
    pub index_val: i64,
    pub name: tok::Span,
}

pub struct BoundIface {
    pub iface: DefId,
    pub n: u8,
    pub args: [TypeId; 8],
}

pub struct LoopEntry {
    pub label: tok::Span,
    pub node: NodeId,
    pub break_ty: TypeId,
    pub value_loop: bool,
    pub saw_value: bool,
    pub saw_bare: bool,
}

// A captured snapshot of the flow-sensitive analysis state.
pub struct FlowState {
    pub moved: [NodeId; 256],
    pub nmoved: u32,
    pub uninit: [NodeId; 64],
    pub nuninit: u32,
    pub freed: [NodeId; 64],
    pub nfreed: u32,
    pub borrows: [Borrow; 64],
    pub nborrows: u32,
}

pub struct TypeChecker {
    pub ast: Ast,
    pub source: str,
    pub current_returns: NodeList,
    pub current_self: NodeId,
    pub current_extend: NodeId,
    pub current_fn: NodeId,
    pub clos_stack: [NodeId; 8],
    pub nclos: u32,
    pub package: *mut loader::Package,
    pub alias_depth: u32,
    pub ext_scope: Vector<ModuleId>,
    pub n_ext_scope: i32,
    // TC-1: per-module list of EXTEND item ids (item order), built lazily. The find_*/dispatch scans iterate
    // this instead of every top-level item; targets are still peeled on-demand in the same order, so type
    // interning (hence emitted C) is byte-identical.
    pub ext_items: Vector<Vector<NodeId>>,
    pub ext_items_built: Vector<bool>,
    pub expected: TypeId,
    pub moved: [NodeId; 1024],
    pub nmoved: u32,
    pub uninit: [NodeId; 256],
    pub nuninit: u32,
    pub freed: [NodeId; 256],
    pub nfreed: u32,
    pub borrows: [Borrow; 256],
    pub nborrows: u32,
    pub scope_depth: u32,
    pub loop_depth: u32,
    pub binding_depth: Map<u32, u32>,
    pub defer_stack: [NodeId; 256],
    pub defer_depth: [u32; 256],
    pub ndefers: u32,
    pub in_loop_recheck: bool,
    pub place_use: bool,
    pub addr_ctx: bool,
    pub mret_call: NodeId,
    pub mret_types: [TypeId; 8],
    pub mret_n: u8,
    pub mret_total: u32,
    pub unsafe_depth: u32,
    pub unsafe_used: u32, // ops inside the innermost active 'unsafe' that actually required it (lint)
    pub lint: bool,
    pub loop_stack: [LoopEntry; 32],
    pub nloops: u32,
    pub loop_floor: u32,
    pub errors: diag::Errors,
    // TC-3: per-decl index of the LAST node whose resolution targets it (built lazily from the
    // resolver's tables; the one typechecker-added resolution kind that can target a binding --
    // break/continue -> loop node -- is folded in at its set site). Replaces the full-arena scan
    // in borrow_dead_after; answers are identical by construction.
    pub last_use: Vector<NodeId>,
    pub last_use_built: bool,
    // TC-5: presence bitset mirroring moved[0..nmoved] (bit index = decl NodeId), so is_moved is
    // O(1) per identifier. Kept in sync at every moved[] mutation site.
    pub moved_bits: Vector<u64>,
    // TC-6: (module<<32|decl) -> packed (module<<32|extend) of the type's Free extend (0 = none).
    // Same shape as codegen's CG-3 memo; the first full scan already interned everything the
    // repeat scans would, so pool order is unchanged.
    pub free_ext_memo: Map<u64, u64>,
    // TC-8: (module<<32|method) -> enclosing extend/interface item (NODE_NONE misses included).
    pub encl_ext_memo: Map<u64, NodeId>,
    pub encl_trait_memo: Map<u64, NodeId>,
    // TC-7: dyn-fn canonicalization worklist -- pool indices of TYPE_DYN-over-fn entries, collected
    // incrementally (each pool index scanned once); list order == pool order == old rescan order.
    pub dynfn_list: Vector<TypeId>,
    pub dynfn_scan: TypeId,
    // TC-9: format helpers are marked used once per module, not once per print call.
    pub fmt_marked: bool,
    // TC-10: prelude lookup hits resolved once at construction (prelude_lookup is a linear scan).
    pub ph_str: loader::LookupHit,
    pub ph_slice: loader::LookupHit,
    pub ph_slicemut: loader::LookupHit,
    pub ph_range: loader::LookupHit,
    pub ph_box: loader::LookupHit,
    pub ph_global: loader::LookupHit,
    pub ph_t2: loader::LookupHit,
    pub ph_t3: loader::LookupHit,
    pub ph_t4: loader::LookupHit,
    pub ph_option: loader::LookupHit,
    pub ph_result: loader::LookupHit,
}

// Takes the package pointer as usize: a *mut Package value is move-tracked (Package is Free).
fn ph_lookup(pkg: usize, name: str) loader::LookupHit {
    let package = pkg as *mut loader::Package;
    if package == null {
        return loader::LookupHit { node: NODE_NONE, mid: 0 };
    }
    return unsafe (*package).prelude_lookup(name, true);
}

// --- result structs (out-params) ----------------------------------------------------------------
pub struct FnSig {
    pub n: i32,
    pub params: [TypeId; 4],
    pub ret: TypeId,
}
pub struct SliceKind {
    pub kind: i32,
    pub elem: TypeId,
}
pub struct BoxOf {
    pub ok: bool,
    pub inner: TypeId,
    pub global_alloc: bool,
}
pub struct RecvSubst {
    pub n: i32,
    pub p: [DefId; 8],
    pub a: [TypeId; 8],
}

// --- span helpers -------------------------------------------------------------------------------
fn span_is(src: str, s: tok::Span, lit: str) bool {
    let n = lit.len();
    if (s.end - s.start) as usize != n {
        return false;
    }
    return unsafe cstring::memcmp(src.ptr() + s.start as usize, lit.ptr(), n) == 0;
}

fn spans_eq2(sa: str, a: tok::Span, sb: str, b: tok::Span) bool {
    let la = a.end - a.start;
    if la != b.end - b.start {
        return false;
    }
    return unsafe cstring::memcmp(sa.ptr() + a.start as usize, sb.ptr() + b.start as usize, la as usize) == 0;
}

fn builtin_name(b: BuiltinType) str {
    if b == BuiltinType::BT_BOOL {
        return "bool";
    }
    if b == BuiltinType::BT_CHAR {
        return "char";
    }
    if b == BuiltinType::BT_I8 {
        return "i8";
    }
    if b == BuiltinType::BT_I16 {
        return "i16";
    }
    if b == BuiltinType::BT_I32 {
        return "i32";
    }
    if b == BuiltinType::BT_I64 {
        return "i64";
    }
    if b == BuiltinType::BT_ISIZE {
        return "isize";
    }
    if b == BuiltinType::BT_U8 {
        return "u8";
    }
    if b == BuiltinType::BT_U16 {
        return "u16";
    }
    if b == BuiltinType::BT_U32 {
        return "u32";
    }
    if b == BuiltinType::BT_U64 {
        return "u64";
    }
    if b == BuiltinType::BT_USIZE {
        return "usize";
    }
    if b == BuiltinType::BT_F32 {
        return "f32";
    }
    if b == BuiltinType::BT_F64 {
        return "f64";
    }
    if b == BuiltinType::BT_C32 {
        return "c32";
    }
    if b == BuiltinType::BT_C64 {
        return "c64";
    }
    if b == BuiltinType::BT_VALIST {
        return "va_list";
    }
    return "void";
}

fn builtin_of(src: str, s: tok::Span) i32 {
    for i in 0..BuiltinType::BT_COUNT as i32 {
        if span_is(src, s, builtin_name(i as BuiltinType)) {
            return i;
        }
    }
    return -1;
}

fn bt_is_int(b: BuiltinType) bool {
    return b as u8 >= BuiltinType::BT_I8 as u8 && b as u8 <= BuiltinType::BT_USIZE as u8;
}
fn bt_is_float(b: BuiltinType) bool {
    return b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64;
}
fn bt_is_complex(b: BuiltinType) bool {
    return b == BuiltinType::BT_C32 || b == BuiltinType::BT_C64;
}

fn bt_int_max(b: BuiltinType) u64 {
    if b == BuiltinType::BT_I8 {
        return 127u64;
    }
    if b == BuiltinType::BT_I16 {
        return 32767u64;
    }
    if b == BuiltinType::BT_I32 {
        return 2147483647u64;
    }
    if b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE {
        return 9223372036854775807u64;
    }
    if b == BuiltinType::BT_U8 {
        return 255u64;
    }
    if b == BuiltinType::BT_U16 {
        return 65535u64;
    }
    if b == BuiltinType::BT_U32 {
        return 4294967295u64;
    }
    return 0u64; // u64/usize
}

fn tc_lit_in_range(b: BuiltinType, mag: u64, neg: bool) bool {
    let mx = bt_int_max(b);
    if neg {
        let sgn = b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
        return sgn && (mx == 0 || mag <= mx + 1);
    }
    return mx == 0 || mag <= mx;
}

// Implicit lossless numeric widening.
fn bt_widens(from: BuiltinType, to: BuiltinType) bool {
    if from == BuiltinType::BT_F32 && to == BuiltinType::BT_F64 {
        return true;
    }
    let fs = from as u8 >= BuiltinType::BT_I8 as u8 && from as u8 <= BuiltinType::BT_I64 as u8;
    let fu = from as u8 >= BuiltinType::BT_U8 as u8 && from as u8 <= BuiltinType::BT_U64 as u8;
    let ts = to as u8 >= BuiltinType::BT_I8 as u8 && to as u8 <= BuiltinType::BT_I64 as u8;
    let tu = to as u8 >= BuiltinType::BT_U8 as u8 && to as u8 <= BuiltinType::BT_U64 as u8;
    if !(fs || fu) || !(ts || tu) {
        return false;
    }
    let mut fw = from as i32 - BuiltinType::BT_U8 as i32;
    if fs {
        fw = from as i32 - BuiltinType::BT_I8 as i32;
    }
    let mut tw = to as i32 - BuiltinType::BT_U8 as i32;
    if ts {
        tw = to as i32 - BuiltinType::BT_I8 as i32;
    }
    if fu {
        return tw > fw;
    }
    return ts && tw > fw;
}

// Shared integer-literal base-prefix detection: returns (base, prefix chars consumed).
fn lit_base_prefix(p: *const u8, len: usize) (u64, usize) {
    if len >= 2 && unsafe p[0] == b'0' {
        let c1 = unsafe p[1] | 0x20u8;
        if c1 == b'x' {
            return 16u64, 2;
        }
        if c1 == b'b' {
            return 2u64, 2;
        }
        if c1 == b'o' {
            return 8u64, 2;
        }
    }
    return 10u64, 0;
}

fn hex_digit(c: u8) u32 {
    if c <= b'9' {
        return (c - b'0') as u32;
    }
    return ((c | 0x20u8) - b'a' + 10u8) as u32;
}

extend TypeChecker {
    pub fn new(ast: Ast, source: str, package: *mut loader::Package) TypeChecker {
        let pkg = package as usize; // read the address before the literal's `package:` field moves it
        return TypeChecker {
            ast: ast,
            source: source,
            current_returns: NodeList { start: 0, len: 0 },
            current_self: NODE_NONE,
            current_extend: NODE_NONE,
            current_fn: NODE_NONE,
            nclos: 0,
            package: package,
            alias_depth: 0,
            ext_scope: Vector::<ModuleId>::new(),
            n_ext_scope: -1,
            ext_items: Vector::<Vector<NodeId>>::new(),
            ext_items_built: Vector::<bool>::new(),
            expected: TYPE_NONE,
            nmoved: 0,
            nuninit: 0,
            nfreed: 0,
            nborrows: 0,
            scope_depth: 0,
            loop_depth: 0,
            binding_depth: Map::<u32, u32>::new(),
            ndefers: 0,
            in_loop_recheck: false,
            place_use: false,
            addr_ctx: false,
            mret_call: NODE_NONE,
            mret_n: 0,
            mret_total: 0,
            unsafe_depth: 0,
            unsafe_used: 0,
            lint: false,
            nloops: 0,
            loop_floor: 0,
            errors: diag::Errors::new(),
            last_use: Vector::<NodeId>::new(),
            last_use_built: false,
            moved_bits: Vector::<u64>::new(),
            free_ext_memo: Map::<u64, u64>::new(),
            encl_ext_memo: Map::<u64, NodeId>::new(),
            encl_trait_memo: Map::<u64, NodeId>::new(),
            dynfn_list: Vector::<TypeId>::new(),
            dynfn_scan: 1,
            fmt_marked: false,
            ph_str: ph_lookup(pkg, "str"),
            ph_slice: ph_lookup(pkg, "Slice"),
            ph_slicemut: ph_lookup(pkg, "SliceMut"),
            ph_range: ph_lookup(pkg, "Range"),
            ph_box: ph_lookup(pkg, "Box"),
            ph_global: ph_lookup(pkg, "Global"),
            ph_t2: ph_lookup(pkg, "Tuple2"),
            ph_t3: ph_lookup(pkg, "Tuple3"),
            ph_t4: ph_lookup(pkg, "Tuple4"),
            ph_option: ph_lookup(pkg, "Option"),
            ph_result: ph_lookup(pkg, "Result"),
        };
    }

    pub fn take_ast(self: &mut Self) Ast {
        let out = self.ast;
        self.ast = Ast::new(0);
        return out;
    }

    // ---- ast / source access (raw pointers) ----
    fn cur_ast(self: &Self) *mut Ast {
        return (&self.ast) as *mut Ast;
    }

    fn mod_ast(self: &Self, m: ModuleId) *mut Ast {
        if self.package != null && m != self.ast.module {
            return (unsafe &mut (*self.package).modules[m as usize].ast) as *mut Ast;
        }
        return (&self.ast) as *mut Ast;
    }
    fn mod_src(self: &Self, m: ModuleId) str {
        if self.package != null && m != self.ast.module {
            return unsafe (*self.package).modules[m as usize].source.as_str();
        }
        return self.source;
    }
    fn pkg_count(self: &Self) usize {
        if self.package == null {
            return 0;
        }
        return unsafe (*self.package).modules.len();
    }
    fn ceval(self: &Self) *mut ce::ConstEval {
        if self.package == null {
            return null;
        }
        return (unsafe (*self.package).ceval) as *mut ce::ConstEval;
    }

    fn name_span(self: &Self, name_node: NodeId) tok::Span {
        return unsafe (*self.cur_ast()).at_const(name_node).as_data.name.text;
    }

    fn type_at(self: &Self, x: TypeId) &Ty {
        return unsafe (*self.cur_ast()).type_at(x);
    }
    fn at_not_fn(self: &Self, x: TypeId) bool {
        return self.type_at(x).kind != TypeKind::TYPE_FUNCTION;
    }

    // ---- simple type predicates ----
    fn is_bool(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_BOOL;
    }
    fn is_int(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && bt_is_int(y.as_data.builtin);
    }
    fn is_numeric(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && (bt_is_int(y.as_data.builtin) || bt_is_float(y.as_data.builtin) || bt_is_complex(
            y.as_data.builtin,
        ));
    }
    fn is_void_type(self: &Self, x: TypeId) bool {
        let y = self.type_at(x);
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID;
    }
    fn bt_of(self: &Self, x: TypeId) BuiltinType {
        let y = self.type_at(x);
        if y.kind == TypeKind::TYPE_BUILTIN {
            return y.as_data.builtin;
        }
        return BuiltinType::BT_COUNT;
    }
    fn is_plain_enum(self: &Self, x: TypeId) bool {
        let y = *self.type_at(x);
        if y.kind != TypeKind::TYPE_ENUM {
            return false;
        }
        let a = self.mod_ast(y.module);
        let ms = unsafe (*a).at_const(y.as_data.decl).as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe (*a).list(ms)[i as usize];
            if unsafe (*a).at_const(mid).as_data.variant.payload.len > 0 {
                return false;
            }
        }
        return true;
    }
    fn strip(self: &Self, x0: TypeId) TypeId {
        let mut x = x0;
        let mut y = self.type_at(x);
        while y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            x = y.as_data.elem;
            y = self.type_at(x);
        }
        return x;
    }
    fn tc_ref(self: &mut Self, elem: TypeId, mut2: bool) TypeId {
        let mut q = TypeQualifier::TYPE_QUAL_NONE;
        if mut2 {
            q = TypeQualifier::TYPE_QUAL_MUT;
        }
        return unsafe (*self.cur_ast()).intern_type(
            Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: q as u8, as_data: TyAs { elem: elem } },
        );
    }

    fn tc_is_prelude_decl(self: &Self, t: TypeId, name: str) bool {
        if self.package == null {
            return false;
        }
        let hit = unsafe (*self.package).prelude_lookup(name, true);
        if hit.node == NODE_NONE {
            return false;
        }
        let y = self.type_at(t);
        return y.kind == TypeKind::TYPE_STRUCT && y.module == hit.mid && y.as_data.decl == hit.node;
    }
    fn tc_main_params_ok(self: &Self, params: NodeList) bool {
        if params.len == 0 {
            return true;
        }
        if params.len != 1 || self.package == null {
            return false;
        }
        let ids = unsafe (*self.cur_ast()).list(params);
        let argv = self.type_at(unsafe (*self.cur_ast()).type_of(unsafe ids[0]));
        if argv.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let hit = unsafe (*self.package).prelude_lookup("Vector", true);
        if hit.node == NODE_NONE {
            return false;
        }
        let it = unsafe (*self.cur_ast()).instance(argv.as_data.inst);
        return it.module == hit.mid && it.decl == hit.node && it.n >= 1 && self.tc_is_prelude_decl(it.args[0], "str");
    }

    // ---- loop stack ----
    fn tc_loop_push(self: &mut Self, label: tok::Span, node: NodeId, value_loop: bool) i32 {
        if self.nloops >= 32 {
            return -1;
        }
        let n = self.nloops;
        self.loop_stack[n as usize] = LoopEntry {
            label: label,
            node: node,
            break_ty: TYPE_NONE,
            value_loop: value_loop,
            saw_value: false,
            saw_bare: false,
        };
        self.nloops = n + 1;
        return n as i32;
    }
    fn tc_loop_pop(self: &mut Self, le: i32, sp: tok::Span) void {
        if le < 0 {
            return;
        }
        if self.loop_stack[le as usize].saw_value && self.loop_stack[le as usize].saw_bare {
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("every 'break' in a value-yielding 'loop' must carry a value"),
            );
        }
        self.nloops = le as u32;
    }
    fn tc_find_loop(self: &Self, label: tok::Span) i32 {
        let mut i = self.nloops;
        while i > self.loop_floor {
            i = i - 1;
            if label.end == label.start {
                return i as i32;
            }
            let ls = self.loop_stack[i as usize].label;
            if ls.end - ls.start == label.end - label.start && unsafe cstring::memcmp(
                self.source.ptr() + ls.start as usize,
                self.source.ptr() + label.start as usize,
                (ls.end - ls.start) as usize,
            ) == 0 {
                return i as i32;
            }
        }
        return -1;
    }

    // ---- test-fn visibility ----
    fn tc_is_test_fn(self: &Self, m: ModuleId, fnode: NodeId) bool {
        let a = self.mod_ast(m);
        for i in 0..unsafe (*a).attrs.len() {
            let at = unsafe (*a).attrs.at(i);
            if at.owner == fnode && (at.kind == AttrKind::ATTR_TEST as u8 || at.kind == AttrKind::ATTR_TEST_INIT as u8 || at.kind == AttrKind::ATTR_TEST_FREE as u8) {
                return true;
            }
        }
        return false;
    }
    fn tc_in_test_fn(self: &Self) bool {
        return self.current_fn != NODE_NONE && self.tc_is_test_fn(self.ast.module, self.current_fn);
    }
    fn tc_check_test_ref(self: &mut Self, d: DefId, sp: tok::Span) void {
        if d.node == NODE_NONE || !self.tc_is_test_fn(d.module, d.node) || self.tc_in_test_fn() {
            return;
        }
        self.errors.emit(
            sp.start,
            sp.end - sp.start,
            format("a '@test' function can only be called from other test functions"),
        );
        self.errors.note(
            format("test functions are not compiled outside 'super-c --test'; move shared logic into a plain function"),
        );
    }

    // ---- literal helpers ----
    fn tc_literal_pinned(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind != NodeKind::NODE_LITERAL {
            return false;
        }
        let tt = n.as_data.literal.token_type;
        if tt != TokenType::IntegerLiteral && tt != TokenType::FloatLiteral {
            return false;
        }
        return unsafe ast_numeric_suffix(self.source, n.as_data.literal.raw.start, n.as_data.literal.raw.end, null) != BuiltinType::BT_COUNT;
    }
    fn is_integer_literal_node(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return false;
        }
        let a = self.cur_ast();
        let mut nid = id;
        let n0 = unsafe (*a).at_const(nid);
        if n0.kind == NodeKind::NODE_UNARY && n0.as_data.unary.op == TokenType::Minus {
            nid = n0.as_data.unary.operand;
        }
        let n = unsafe (*a).at_const(nid);
        return n.kind == NodeKind::NODE_LITERAL && n.as_data.literal.token_type == TokenType::IntegerLiteral;
    }
    fn lit_mag(self: &Self, id: NodeId, out: *mut u64) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        let lr = n.as_data.literal.raw;
        let mut endd = lr.end;
        unsafe ast_numeric_suffix(self.source, lr.start, lr.end, (&mut endd) as *mut u32);
        let mut p = unsafe (self.source.ptr() + lr.start as usize);
        let mut len = (endd - lr.start) as usize;
        let (base, skip) = lit_base_prefix(p, len);
        p = unsafe (p + skip);
        len = len - skip;
        let mut acc: u64 = 0;
        for i in 0..len {
            let ch = unsafe p[i];
            if ch == b'_' {
                continue;
            }
            let mut d: u64 = 0;
            if ch <= b'9' {
                d = (ch - b'0') as u64;
            } else {
                d = ((ch | 0x20u8) - b'a' + 10u8) as u64;
            }
            if d >= base || acc > (0xFFFFFFFFFFFFFFFFu64 - d) / base {
                return false;
            }
            acc = acc * base + d;
        }
        unsafe *out = acc;
        return true;
    }

    fn char_literal_cp(self: &Self, s: tok::Span) u32 {
        let src = self.source;
        let mut i = (s.start + 1) as usize;
        if i >= s.end as usize {
            return 0;
        }
        if src[i] != b'\\' {
            let b = src[i];
            if b < 0x80u8 {
                return b as u32;
            }
            if b <= 0xDFu8 {
                return (b & 0x1Fu8) as u32 << 6 | (src[i + 1] & 0x3Fu8) as u32;
            }
            if b <= 0xEFu8 {
                return (b & 0x0Fu8) as u32 << 12 | (src[i + 1] & 0x3Fu8) as u32 << 6 | (src[i + 2] & 0x3Fu8) as u32;
            }
            return (b & 0x07u8) as u32 << 18 | (src[i + 1] & 0x3Fu8) as u32 << 12 | (src[i + 2] & 0x3Fu8) as u32 << 6 | (src[i + 3] & 0x3Fu8) as u32;
        }
        i = i + 1;
        let e = src[i];
        i = i + 1;
        if e == b'x' {
            return hex_digit(src[i]) << 4 | hex_digit(src[i + 1]);
        }
        if e == b'u' {
            if i < s.end as usize && src[i] == b'{' {
                i = i + 1;
            }
            let mut cp: u32 = 0;
            while i < s.end as usize && src[i] != b'}' {
                cp = cp << 4 | hex_digit(src[i]);
                i = i + 1;
            }
            return cp;
        }
        return 0;
    }

    // An operation that requires 'unsafe': counts against the innermost active marker (for the
    // unnecessary-unsafe lint) and reports whether the requirement is unmet.
    fn tc_needs_unsafe(self: &mut Self) bool {
        self.unsafe_used = self.unsafe_used + 1;
        return self.unsafe_depth == 0;
    }

    // ---- error / misc ----
    @c.cold
    fn err_unsafe(self: &mut Self, sp: tok::Span, what: str) void {
        self.errors.emit(sp.start, sp.end - sp.start, format("{} requires an 'unsafe' block", what));
        self.errors.note(format("{}", "wrap the operation in 'unsafe { ... }' or prefix the expression with 'unsafe'"));
    }
    fn tc_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) *const Attr {
        let a = self.mod_ast(m);
        for i in 0..unsafe (*a).attrs.len() {
            let at = unsafe (*a).attrs.at(i);
            if at.owner == owner && at.kind == kind as u8 {
                return at as *const Attr;
            }
        }
        return null;
    }
    fn peel_wrappers(self: &Self, id0: NodeId) NodeId {
        let a = self.cur_ast();
        let mut id = id0;
        loop {
            let n = unsafe (*a).at_const(id);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                id = n.as_data.unary.operand;
            } else {
                break;
            }
        }
        return id;
    }
    fn through_raw_pointer(self: &Self, ty0: TypeId) bool {
        let mut ty = ty0;
        let mut y = self.type_at(ty);
        while y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            if y.kind == TypeKind::TYPE_POINTER {
                return true;
            }
            ty = y.as_data.elem;
            y = self.type_at(ty);
        }
        return false;
    }

    fn render_type(self: &Self, tid: TypeId, buf: *mut char, cap: usize) void {
        let ty = *self.type_at(tid);
        if ty.kind == TypeKind::TYPE_BUILTIN {
            unsafe stdio::snprintf(
                buf,
                cap,
                "%s".ptr() as *const char,
                builtin_name(ty.as_data.builtin).ptr() as *const char,
            );
        } else if ty.kind == TypeKind::TYPE_NEVER {
            unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "never".ptr() as *const char);
        } else if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
            let mut inb = Buf96 {};
            self.render_type(ty.as_data.elem, &mut inb[0], 96);
            let mut pfx = "&".ptr() as *const char;
            if ty.kind == TypeKind::TYPE_POINTER {
                pfx = "*".ptr() as *const char;
            }
            let mut mq = "".ptr() as *const char;
            if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                mq = "mut ".ptr() as *const char;
            }
            unsafe stdio::snprintf(buf, cap, "%s%s%s".ptr() as *const char, pfx, mq, &inb[0]);
        } else if ty.kind == TypeKind::TYPE_SLICE {
            let mut inb = Buf96 {};
            self.render_type(ty.as_data.elem, &mut inb[0], 96);
            unsafe stdio::snprintf(buf, cap, "[]%s".ptr() as *const char, &inb[0]);
        } else if ty.kind == TypeKind::TYPE_ARRAY {
            let mut inb = Buf96 {};
            self.render_type(ty.as_data.arr.elem, &mut inb[0], 96);
            unsafe stdio::snprintf(buf, cap, "[%s]".ptr() as *const char, &inb[0]);
        } else if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM || ty.kind == TypeKind::TYPE_GENERIC {
            let a = self.mod_ast(ty.module);
            let d = unsafe (*a).at_const(ty.as_data.decl);
            let mut nm = d.as_data.aggregate.name;
            if d.kind == NodeKind::NODE_GENERIC_PARAM {
                nm = d.as_data.generic_param.name;
            }
            let s = unsafe (*a).at_const(nm).as_data.name.text;
            unsafe stdio::snprintf(
                buf,
                cap,
                "%.*s".ptr() as *const char,
                (s.end - s.start) as i32,
                src_at(self.mod_src(ty.module), s.start),
            );
        } else if ty.kind == TypeKind::TYPE_OPAQUE {
            let a = self.mod_ast(ty.module);
            let s = unsafe (*a).at_const(unsafe (*a).at_const(ty.as_data.decl).as_data.type_alias.name).as_data.name.text;
            unsafe stdio::snprintf(
                buf,
                cap,
                "%.*s".ptr() as *const char,
                (s.end - s.start) as i32,
                src_at(self.mod_src(ty.module), s.start),
            );
        } else if ty.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
            let a = self.mod_ast(it.module);
            let s = unsafe (*a).at_const(unsafe (*a).at_const(it.decl).as_data.aggregate.name).as_data.name.text;
            let at0 = unsafe stdio::snprintf(
                buf,
                cap,
                "%.*s<".ptr() as *const char,
                (s.end - s.start) as i32,
                src_at(self.mod_src(it.module), s.start),
            );
            let mut at = at0 as usize;
            let mut i: u8 = 0;
            while i < it.n && at < cap {
                let mut argb = Buf96 {};
                self.render_type(it.args[i as usize], &mut argb[0], 64);
                let mut sep = "".ptr() as *const char;
                if i != 0 {
                    sep = ", ".ptr() as *const char;
                }
                let mut room: usize = 0;
                if cap > at {
                    room = cap - at;
                }
                let w = unsafe stdio::snprintf(buf + at, room, "%s%s".ptr() as *const char, sep, &argb[0]);
                at = at + w as usize;
                i = i + 1;
            }
            if at < cap {
                unsafe stdio::snprintf(buf + at, cap - at, "%s".ptr() as *const char, ">".ptr() as *const char);
            }
        } else if ty.kind == TypeKind::TYPE_FUNCTION {
            unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "fn".ptr() as *const char);
        } else if ty.kind == TypeKind::TYPE_DYN {
            let a = self.mod_ast(ty.module);
            let mut pfx = "Box<dyn ".ptr() as *const char;
            if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                pfx = "&mut dyn ".ptr() as *const char;
            } else if ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                pfx = "&dyn ".ptr() as *const char;
            }
            let mut sfx = "".ptr() as *const char;
            if ty.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                sfx = ">".ptr() as *const char;
            }
            if unsafe (*a).at_const(ty.as_data.decl).kind == NodeKind::NODE_FUNCTION_TYPE {
                unsafe stdio::snprintf(buf, cap, "%sfn(..) ..%s".ptr() as *const char, pfx, sfx);
            } else {
                let s = unsafe (*a).at_const(unsafe (*a).at_const(ty.as_data.decl).as_data.interface_def.name).as_data.name.text;
                unsafe stdio::snprintf(
                    buf,
                    cap,
                    "%s%.*s%s".ptr() as *const char,
                    pfx,
                    (s.end - s.start) as i32,
                    src_at(self.mod_src(ty.module), s.start),
                    sfx,
                );
            }
        } else {
            unsafe stdio::snprintf(buf, cap, "%s".ptr() as *const char, "?".ptr() as *const char);
        }
    }

    @c.cold
    fn err_mismatch(self: &mut Self, node: NodeId, expected: TypeId) void {
        let mut e = Buf96 {};
        let mut f = Buf96 {};
        self.render_type(expected, &mut e[0], 96);
        self.render_type(unsafe (*self.cur_ast()).type_of(node), &mut f[0], 96);
        let sp = unsafe (*self.cur_ast()).at_const(node).span;
        self.errors.emit(
            sp.start,
            sp.end - sp.start,
            format("mismatched types: expected '{}', found '{}'", diag::cstr(&e[0]), diag::cstr(&f[0])),
        );
    }

    // ---- function-type helpers ----
    fn fn_sig(self: &mut Self, fid: TypeId, params: *mut TypeId, cap: i32, ret: *mut TypeId) i32 {
        let fty = *self.type_at(fid);
        let m = fty.module;
        let fa = self.mod_ast(m);
        let fk = unsafe (*fa).at_const(fty.as_data.decl).kind;
        let mut ps = NodeList { start: 0, len: 0 };
        let mut rs = NodeList { start: 0, len: 0 };
        if fk == NodeKind::NODE_FUNCTION {
            ps = unsafe (*fa).at_const(fty.as_data.decl).as_data.function.params;
            rs = unsafe (*fa).at_const(fty.as_data.decl).as_data.function.returns;
        } else if fk == NodeKind::NODE_CLOSURE {
            ps = unsafe (*fa).at_const(fty.as_data.decl).as_data.closure.params;
            rs = unsafe (*fa).at_const(fty.as_data.decl).as_data.closure.returns;
        } else {
            ps = unsafe (*fa).at_const(fty.as_data.decl).as_data.function_type.params;
            rs = unsafe (*fa).at_const(fty.as_data.decl).as_data.function_type.returns;
        }
        let mut i: u32 = 0;
        while i < ps.len && i as i32 < cap {
            let pid = unsafe (*fa).list(ps)[i as usize];
            let p = unsafe (*fa).at_const(pid);
            if p.kind == NodeKind::NODE_PARAMETER && p.as_data.parameter.ty == NODE_NONE {
                let pty = unsafe (*fa).type_of(pid);
                unsafe params[i as usize] = pty;
            } else {
                let tn = if_node(p.kind == NodeKind::NODE_PARAMETER, p.as_data.parameter.ty, pid);
                unsafe params[i as usize] = self.lower_type_in(m, tn);
            }
            i = i + 1;
        }
        if fk == NodeKind::NODE_CLOSURE && unsafe (*fa).at_const(fty.as_data.decl).as_data.closure.expr_body {
            let rty = unsafe (*fa).type_of(unsafe (*fa).at_const(fty.as_data.decl).as_data.closure.body);
            unsafe *ret = rty;
        } else if rs.len == 1 {
            let r0 = unsafe (*fa).list(rs)[0];
            let rn = unsafe (*fa).at_const(r0);
            let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            unsafe *ret = self.lower_type_in(m, tn);
        } else {
            unsafe *ret = TYPE_NONE;
        }
        return ps.len as i32;
    }

    fn receiver_type_eq(self: &Self, a: TypeId, b: TypeId) bool {
        if a == b {
            return true;
        }
        let at = self.type_at(a);
        let bt = self.type_at(b);
        let ap = at.kind == TypeKind::TYPE_POINTER || at.kind == TypeKind::TYPE_REFERENCE;
        let bp = bt.kind == TypeKind::TYPE_POINTER || bt.kind == TypeKind::TYPE_REFERENCE;
        return ap && bp && at.qualifier == bt.qualifier && at.as_data.elem == bt.as_data.elem;
    }

    fn generic_fn_bound(self: &Self, m: ModuleId, decl: NodeId) NodeId {
        let a = self.mod_ast(m);
        let gp = unsafe (*a).at_const(decl);
        if gp.kind != NodeKind::NODE_GENERIC_PARAM {
            return NODE_NONE;
        }
        let bounds = gp.as_data.generic_param.bounds;
        for i in 0..bounds.len {
            let bid = unsafe (*a).list(bounds)[i as usize];
            if unsafe (*a).at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                return bid;
            }
        }
        if self.current_fn != NODE_NONE && (self.package == null || m == self.ast.module) {
            let wc = unsafe (*self.cur_ast()).at_const(self.current_fn).as_data.function.where_clause;
            for w in 0..wc.len {
                let wid = unsafe (*self.cur_ast()).list(wc)[w as usize];
                let wp = unsafe (*self.cur_ast()).at_const(wid).as_data.where_predicate;
                if unsafe (*self.cur_ast()).resolution(wp.ty) == decl {
                    for b in 0..wp.bounds.len {
                        let wbid = unsafe (*self.cur_ast()).list(wp.bounds)[b as usize];
                        if unsafe (*self.cur_ast()).at_const(wbid).kind == NodeKind::NODE_FUNCTION_TYPE {
                            return wbid;
                        }
                    }
                }
            }
        }
        return NODE_NONE;
    }

    fn fn_is_capturing(self: &Self, fid: TypeId) bool {
        let fy = self.type_at(fid);
        if fy.kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let a = self.mod_ast(fy.module);
        let fnn = unsafe (*a).at_const(fy.as_data.decl);
        return fnn.kind == NodeKind::NODE_CLOSURE && fnn.as_data.closure.captures.len != 0;
    }

    fn tc_capture_index(self: &Self, clos: NodeId, decl: NodeId) i32 {
        let a = self.cur_ast();
        let caps = unsafe (*a).at_const(clos).as_data.closure.captures;
        for i in 0..caps.len {
            let cid = unsafe (*a).list(caps)[i as usize];
            if cid == decl {
                return i as i32;
            }
        }
        return -1;
    }

    fn fn_owns(self: &mut Self, fid: TypeId) bool {
        let fy = *self.type_at(fid);
        if fy.kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let fa = self.mod_ast(fy.module);
        let fnn = unsafe (*fa).at_const(fy.as_data.decl);
        if fnn.kind != NodeKind::NODE_CLOSURE {
            return false;
        }
        let caps = fnn.as_data.closure.captures;
        let mut_caps = fnn.as_data.closure.mut_caps as u64;
        for i in 0..caps.len {
            let cid = unsafe (*fa).list(caps)[i as usize];
            if (mut_caps >> i as u64 & 1u64) == 0 {
                let rt = unsafe (*self.cur_ast()).reintern(unsafe &*fa, unsafe (*fa).type_of(cid));
                if self.tc_type_is_free(rt) {
                    return true;
                }
            }
        }
        return false;
    }

    fn tc_mark_capture_mut(self: &mut Self, expr0: NodeId) void {
        if self.nclos == 0 {
            return;
        }
        let a = self.cur_ast();
        let mut expr = expr0;
        loop {
            let n = unsafe (*a).at_const(expr);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                expr = n.as_data.unary.operand;
            } else if n.kind == NodeKind::NODE_MEMBER && !n.as_data.member.path {
                expr = n.as_data.member.object;
            } else if n.kind == NodeKind::NODE_INDEX {
                expr = n.as_data.index.object;
            } else {
                break;
            }
        }
        if unsafe (*a).at_const(expr).kind != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let d = unsafe (*a).resolution_def(expr);
        if d.module != self.ast.module || d.node == NODE_NONE {
            return;
        }
        for f in 0..self.nclos {
            let idx = self.tc_capture_index(self.clos_stack[f as usize], d.node);
            if idx >= 0 {
                let cs = self.clos_stack[f as usize];
                let old = (unsafe (*self.cur_ast()).at(cs).as_data.closure.mut_caps) as u64;
                unsafe (*self.cur_ast()).at(cs).as_data.closure.mut_caps = (old | 1u64 << idx as u64) as u32;
            }
        }
    }

    fn ret_eq(self: &Self, a: TypeId, b: TypeId) bool {
        if a == b {
            return true;
        }
        let v = Ast::builtin(BuiltinType::BT_VOID);
        return (a == TYPE_NONE || a == v) && (b == TYPE_NONE || b == v);
    }

    fn fn_compatible(self: &mut Self, exid: TypeId, acid: TypeId) bool {
        if exid != acid && self.fn_is_capturing(acid) {
            return false;
        }
        return self.dynfn_sig_ok(exid, acid);
    }

    fn dynfn_sig_ok(self: &mut Self, exid: TypeId, acid: TypeId) bool {
        let mut ep = Tys8 {};
        let mut ap = Tys8 {};
        let mut er: TypeId = TYPE_NONE;
        let mut ar: TypeId = TYPE_NONE;
        let en = self.fn_sig(exid, (&mut ep[0]) as *mut TypeId, 4, (&mut er) as *mut TypeId);
        let an = self.fn_sig(acid, (&mut ap[0]) as *mut TypeId, 4, (&mut ar) as *mut TypeId);
        if en != an || en > 4 || !self.ret_eq(er, ar) {
            return false;
        }
        for i in 0..en {
            if ep[i as usize] != ap[i as usize] {
                return false;
            }
        }
        return true;
    }

    fn tc_dyn_fn_sig(self: &mut Self, ty: &Ty) TypeId {
        if ty.kind != TypeKind::TYPE_DYN {
            return TYPE_NONE;
        }
        if unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl).kind != NodeKind::NODE_FUNCTION_TYPE {
            return TYPE_NONE;
        }
        return self.lower_type_in(ty.module, ty.as_data.decl);
    }

    fn tc_dyn_same(self: &mut Self, a: &Ty, b: &Ty) bool {
        let as2 = self.tc_dyn_fn_sig(a);
        let bs = self.tc_dyn_fn_sig(b);
        if as2 != TYPE_NONE != (bs != TYPE_NONE) {
            return false;
        }
        if as2 != TYPE_NONE {
            return as2 == bs || self.fn_compatible(as2, bs);
        }
        return a.module == b.module && a.as_data.decl == b.as_data.decl;
    }
}

fn if_node(c: bool, a: NodeId, b: NodeId) NodeId {
    if c {
        return a;
    }
    return b;
}
fn if_ty(c: bool, a: TypeId, b: TypeId) TypeId {
    if c {
        return a;
    }
    return b;
}
fn src_at(p: str, off: u32) *const char {
    return (unsafe (p.ptr() + off as usize)) as *const char;
}

pub const TYPE_ERROR: TypeId = 0;

extend TypeChecker {
    // Unwrap a struct/enum/instance type to its module + decl (+ instance arg substitution).
    fn aggregate_of(
        self: &Self,
        ty: TypeId,
        mod_out: *mut ModuleId,
        decl_out: *mut NodeId,
        params: *mut DefId,
        args: *mut TypeId,
        n_out: *mut i32,
    ) bool {
        unsafe *n_out = 0;
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            unsafe *mod_out = y.module;
            unsafe *decl_out = y.as_data.decl;
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            unsafe *mod_out = it.module;
            unsafe *decl_out = it.decl;
            let da = self.mod_ast(it.module);
            let gens = unsafe (*da).at_const(it.decl).as_data.aggregate.generics;
            let mut nn: i32 = 0;
            let mut i: u32 = 0;
            while i < gens.len && i as u8 < it.n && nn < 8 {
                let gid = unsafe (*da).list(gens)[i as usize];
                unsafe params[nn as usize] = DefId { module: it.module, node: gid };
                unsafe args[nn as usize] = it.args[i as usize];
                nn = nn + 1;
                i = i + 1;
            }
            unsafe *n_out = nn;
            return true;
        }
        return false;
    }

    fn subst_type(self: &mut Self, ty: TypeId, params: *const DefId, args: *const TypeId, n: i32) TypeId {
        if ty == TYPE_NONE || n == 0 {
            return ty;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..n {
                if unsafe params[i as usize].module == y.module && unsafe params[i as usize].node == y.as_data.decl {
                    return unsafe args[i as usize];
                }
            }
            return ty;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.subst_type(y.as_data.elem, params, args, n);
            if e == y.as_data.elem {
                return ty;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            return unsafe (*self.cur_ast()).intern_type(nt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let src = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut na = Tys8 {};
            let mut changed = false;
            for i in 0..src.n {
                na[i as usize] = self.subst_type(src.args[i as usize], params, args, n);
                if na[i as usize] != src.args[i as usize] {
                    changed = true;
                }
            }
            if changed {
                return unsafe (*self.cur_ast()).intern_instance(src.module, src.decl, (&na[0]) as *const TypeId, src.n);
            }
            return ty;
        }
        return ty;
    }

    fn unify_infer(self: &mut Self, param_ty: TypeId, arg_ty: TypeId, params: *const DefId, bound: *mut TypeId, n: i32) void {
        if param_ty == TYPE_NONE || arg_ty == TYPE_NONE {
            return;
        }
        let p = *self.type_at(param_ty);
        if p.kind == TypeKind::TYPE_GENERIC {
            for i in 0..n {
                if unsafe params[i as usize].module == p.module && unsafe params[i as usize].node == p.as_data.decl {
                    if unsafe bound[i as usize] == TYPE_NONE {
                        unsafe bound[i as usize] = arg_ty;
                    }
                    return;
                }
            }
            return;
        }
        let aT = *self.type_at(arg_ty);
        if aT.kind == p.kind && (p.kind == TypeKind::TYPE_POINTER || p.kind == TypeKind::TYPE_REFERENCE || p.kind == TypeKind::TYPE_SLICE || p.kind == TypeKind::TYPE_ARRAY) {
            self.unify_infer(p.as_data.elem, aT.as_data.elem, params, bound, n);
        } else if p.kind == TypeKind::TYPE_INSTANCE && aT.kind == TypeKind::TYPE_INSTANCE {
            let pi = *unsafe (*self.cur_ast()).instance(p.as_data.inst);
            let ai = *unsafe (*self.cur_ast()).instance(aT.as_data.inst);
            if pi.decl == ai.decl && pi.module == ai.module && pi.n == ai.n {
                for i in 0..pi.n {
                    self.unify_infer(pi.args[i as usize], ai.args[i as usize], params, bound, n);
                }
            }
        } else if p.kind == TypeKind::TYPE_FUNCTION && aT.kind == TypeKind::TYPE_FUNCTION {
            let mut pp = Tys8 {};
            let mut ap = Tys8 {};
            let mut pr: TypeId = TYPE_NONE;
            let mut ar: TypeId = TYPE_NONE;
            let pn = self.fn_sig(param_ty, (&mut pp[0]) as *mut TypeId, 4, (&mut pr) as *mut TypeId);
            let an = self.fn_sig(arg_ty, (&mut ap[0]) as *mut TypeId, 4, (&mut ar) as *mut TypeId);
            if pn == an && pn <= 4 {
                for i in 0..pn {
                    self.unify_infer(pp[i as usize], ap[i as usize], params, bound, n);
                }
                self.unify_infer(pr, ar, params, bound, n);
            }
        }
    }

    fn named_type_of(self: &mut Self, m: ModuleId, decl: NodeId) TypeId {
        let a = self.mod_ast(m);
        let dk = unsafe (*a).at_const(decl).kind;
        if dk == NodeKind::NODE_STRUCT {
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_STRUCT, module: m, as_data: TyAs { decl: decl } },
            );
        }
        if dk == NodeKind::NODE_ENUM {
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_ENUM, module: m, as_data: TyAs { decl: decl } },
            );
        }
        if dk == NodeKind::NODE_TYPE_ALIAS {
            let aliased_node = unsafe (*a).at_const(decl).as_data.type_alias.ty;
            if aliased_node == NODE_NONE {
                return unsafe (*self.cur_ast()).intern_type(
                    Ty { kind: TypeKind::TYPE_OPAQUE, module: m, as_data: TyAs { decl: decl } },
                );
            }
            if self.alias_depth >= TYPE_ALIAS_MAX_DEPTH {
                let sp = unsafe (*a).at_const(decl).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("type alias is cyclic"));
                return TYPE_ERROR;
            }
            self.alias_depth = self.alias_depth + 1;
            let aliased = self.lower_type_in(m, aliased_node);
            self.alias_depth = self.alias_depth - 1;
            return aliased;
        }
        if dk == NodeKind::NODE_GENERIC_PARAM || dk == NodeKind::NODE_INTERFACE {
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_GENERIC, module: m, as_data: TyAs { decl: decl } },
            );
        }
        return TYPE_ERROR;
    }

    fn agg_has_default_at(self: &Self, dmod: ModuleId, dn: NodeId, from: u32) bool {
        let da = self.mod_ast(dmod);
        let gens = unsafe (*da).at_const(dn).as_data.aggregate.generics;
        if from >= gens.len {
            return false;
        }
        let gid = unsafe (*da).list(gens)[from as usize];
        return unsafe (*da).at_const(gid).as_data.generic_param.default_type != NODE_NONE;
    }

    fn apply_default_args(self: &mut Self, dmod: ModuleId, dn: NodeId, ta: *mut TypeId, tn: *mut u8) void {
        let da = self.mod_ast(dmod);
        let gens = unsafe (*da).at_const(dn).as_data.aggregate.generics;
        if unsafe *tn >= gens.len as u8 {
            return;
        }
        let mut i = (unsafe *tn) as u32;
        while i < gens.len && unsafe *tn < 8 {
            let gid = unsafe (*da).list(gens)[i as usize];
            let dft = unsafe (*da).at_const(gid).as_data.generic_param.default_type;
            if dft == NODE_NONE {
                break;
            }
            let mut d = self.lower_type_in(dmod, dft);
            if unsafe *tn > 0 {
                let mut prm = Defs8 {};
                for j in 0..unsafe *tn {
                    let gj = unsafe (*da).list(gens)[j as usize];
                    prm[j as usize] = DefId { module: dmod, node: gj };
                }
                d = self.subst_type(d, (&prm[0]) as *const DefId, ta as *const TypeId, (unsafe *tn) as i32);
            }
            let k = unsafe *tn;
            unsafe ta[k as usize] = d;
            unsafe *tn = k + 1;
            i = i + 1;
        }
    }

    // ---- prelude type intercepts (all through the TC-10 cached hits) ----
    fn prelude_str_type(self: &mut Self) TypeId {
        if self.package == null {
            return TYPE_ERROR;
        }
        if self.ph_str.node != NODE_NONE {
            return self.named_type_of(self.ph_str.mid, self.ph_str.node);
        }
        return TYPE_ERROR;
    }
    fn prelude_slice_type(self: &mut Self, elem: TypeId, mut2: bool) TypeId {
        if self.package == null {
            return TYPE_ERROR;
        }
        let mut hit = self.ph_slice;
        if mut2 {
            hit = self.ph_slicemut;
        }
        if hit.node != NODE_NONE {
            return unsafe (*self.cur_ast()).intern_instance(hit.mid, hit.node, (&elem) as *const TypeId, 1);
        }
        return TYPE_ERROR;
    }
    fn prelude_range_type(self: &mut Self, elem: TypeId) TypeId {
        if self.package == null {
            return TYPE_ERROR;
        }
        if self.ph_range.node != NODE_NONE {
            return unsafe (*self.cur_ast()).intern_instance(
                self.ph_range.mid,
                self.ph_range.node,
                (&elem) as *const TypeId,
                1,
            );
        }
        return TYPE_ERROR;
    }
    fn prelude_tuple_type(self: &mut Self, args: *const TypeId, n: u32) TypeId {
        if self.package == null || n < 2 || n > 4 {
            return TYPE_ERROR;
        }
        let mut hit = self.ph_t2;
        if n == 3 {
            hit = self.ph_t3;
        } else if n == 4 {
            hit = self.ph_t4;
        }
        if hit.node != NODE_NONE {
            return unsafe (*self.cur_ast()).intern_instance(hit.mid, hit.node, args, n as u8);
        }
        return TYPE_ERROR;
    }

    // If `tid` is the prelude instance `hit`, copy its args into `out` and return the count; else -1.
    fn prelude_instance_args_hit(self: &Self, tid: TypeId, hit: loader::LookupHit, out: *mut TypeId, maxn: i32) i32 {
        if self.package == null || tid == TYPE_NONE || hit.node == NODE_NONE {
            return -1;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return -1;
        }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        if it.module != hit.mid || it.decl != hit.node {
            return -1;
        }
        let mut i: i32 = 0;
        while i < it.n as i32 && i < maxn {
            unsafe out[i as usize] = it.args[i as usize];
            i = i + 1;
        }
        return it.n as i32;
    }
    fn tuple_args_of(self: &Self, tid: TypeId, out: *mut TypeId, maxn: i32) i32 {
        let n2 = self.prelude_instance_args_hit(tid, self.ph_t2, out, maxn);
        if n2 >= 0 {
            return n2;
        }
        let n3 = self.prelude_instance_args_hit(tid, self.ph_t3, out, maxn);
        if n3 >= 0 {
            return n3;
        }
        return self.prelude_instance_args_hit(tid, self.ph_t4, out, maxn);
    }
    fn range_instance_elem(self: &Self, tid: TypeId) TypeId {
        if self.package == null {
            return TYPE_NONE;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return TYPE_NONE;
        }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        if it.n == 1 && it.module == self.ph_range.mid && it.decl == self.ph_range.node {
            return it.args[0];
        }
        return TYPE_NONE;
    }
    // 0 not a slice, 1 Slice<E>, 2 SliceMut<E>; sets *elem.
    fn slice_kind(self: &Self, tid: TypeId, elem: *mut TypeId) i32 {
        if self.package == null {
            return 0;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return 0;
        }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        if it.n != 1 {
            return 0;
        }
        let mut kind: i32 = 0;
        if it.module == self.ph_slice.mid && it.decl == self.ph_slice.node {
            kind = 1;
        } else if it.module == self.ph_slicemut.mid && it.decl == self.ph_slicemut.node {
            kind = 2;
        }
        if kind != 0 && elem != null {
            unsafe *elem = it.args[0];
        }
        return kind;
    }
    fn tc_box_of(self: &Self, y: &Ty, inner: *mut TypeId, global_alloc: *mut bool) bool {
        if y.kind != TypeKind::TYPE_INSTANCE || self.package == null {
            return false;
        }
        let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
        if it.module != self.ph_box.mid || it.decl != self.ph_box.node || it.n < 1 {
            return false;
        }
        unsafe *inner = it.args[0];
        let mut ga = false;
        if it.n >= 2 {
            let ay = self.type_at(it.args[1]);
            ga = ay.kind == TypeKind::TYPE_STRUCT && ay.module == self.ph_global.mid && ay.as_data.decl == self.ph_global.node;
        }
        unsafe *global_alloc = ga;
        return true;
    }

    fn decl_type_in(self: &mut Self, m: ModuleId, decl: NodeId) TypeId {
        if decl == NODE_NONE {
            return TYPE_NONE;
        }
        let local = self.package == null || m == self.ast.module;
        if local {
            let cached = unsafe (*self.cur_ast()).type_of(decl);
            if cached != TYPE_NONE {
                return cached;
            }
        }
        let a = self.mod_ast(m);
        let dk = unsafe (*a).at_const(decl).kind;
        let mut result = TYPE_NONE;
        if dk == NodeKind::NODE_PARAMETER {
            result = self.lower_type_in(m, unsafe (*a).at_const(decl).as_data.parameter.ty);
        } else if dk == NodeKind::NODE_FIELD {
            result = self.lower_type_in(m, unsafe (*a).at_const(decl).as_data.field.ty);
        } else if dk == NodeKind::NODE_CONST {
            result = self.lower_type_in(m, unsafe (*a).at_const(decl).as_data.const_def.ty);
        } else if dk == NodeKind::NODE_LET {
            result = self.lower_type_in(m, unsafe (*a).at_const(decl).as_data.let_stmt.ty);
        } else if dk == NodeKind::NODE_FUNCTION {
            result = unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_FUNCTION, module: m, as_data: TyAs { decl: decl } },
            );
        } else if dk == NodeKind::NODE_GENERIC_PARAM {
            let gp = unsafe (*a).at_const(decl).as_data.generic_param;
            // In value position a const-generic param has its declared type (e.g. usize); a type param is TYPE_GENERIC.
            if gp.is_const {
                result = self.lower_type_in(m, gp.const_type);
            } else {
                result = self.named_type_of(m, decl);
            }
        } else if dk == NodeKind::NODE_STRUCT || dk == NodeKind::NODE_ENUM {
            result = self.named_type_of(m, decl);
        }
        if local {
            unsafe (*self.cur_ast()).set_type(decl, result);
        }
        return result;
    }
    fn decl_type(self: &mut Self, decl: NodeId) TypeId {
        return self.decl_type_in(self.ast.module, decl);
    }

    fn type_of_type_node(self: &mut Self, id: NodeId) TypeId {
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        if unsafe (*self.cur_ast()).at_const(id).kind != NodeKind::NODE_IDENTIFIER {
            return self.resolve_type(id);
        }
        let d = unsafe (*self.cur_ast()).resolution_def(id);
        if d.node != NODE_NONE {
            return self.named_type_of(d.module, d.node);
        }
        let b = builtin_of(self.source, self.name_span(id));
        if b >= 0 {
            return Ast::builtin(b as BuiltinType);
        }
        return TYPE_ERROR;
    }

    // Fold a const-generic argument expression (e.g. the `4` in `Buff<i32, 4>`) to an interned TYPE_CONST value.
    fn tc_const_arg(self: &mut Self, m: ModuleId, aid: NodeId) TypeId {
        let ceptr = self.ceval();
        if ceptr != null {
            let lv = unsafe (*ceptr).eval(m, aid);
            if lv.kind == ce::CONST_INT {
                return unsafe (*self.cur_ast()).const_value(lv.as_data.i);
            }
        }
        let sp = unsafe (*self.mod_ast(m)).at_const(aid).span;
        self.errors.emit(sp.start, sp.end - sp.start, format("const generic argument must be a constant integer"));
        return TYPE_ERROR;
    }

    fn ce_array_len(self: &mut Self, m: ModuleId, lenNode: NodeId) u32 {
        let ceptr = self.ceval();
        if ceptr == null {
            return 0;
        }
        let lv = unsafe (*ceptr).eval(m, lenNode);
        if lv.kind == ce::CONST_INT && lv.as_data.i > 0 && lv.as_data.i <= 0xFFFFFFFFi64 {
            return lv.as_data.i as u32;
        }
        return 0;
    }

    // Lower a type node in module `m` to an interned TypeId in the current pool.
    fn lower_type_in(self: &mut Self, m: ModuleId, id: NodeId) TypeId {
        if self.package == null || m == self.ast.module {
            return self.resolve_type(id);
        }
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        let a = self.mod_ast(m);
        let nk = unsafe (*a).at_const(id).kind;
        if nk == NodeKind::NODE_TYPE_PATH {
            let d = unsafe (*a).resolution_def(id);
            let args = unsafe (*a).at_const(id).as_data.type_path.args;
            if d.node != NODE_NONE {
                let bb = unsafe (*self.package).builtin_of_decl(d.module, d.node);
                if bb >= 0 {
                    return Ast::builtin(bb as BuiltinType);
                }
                let dnk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
                if args.len == 1 && self.package != null {
                    let a0 = unsafe (*a).list(args)[0];
                    let an = unsafe (*a).at_const(a0);
                    if an.kind == NodeKind::NODE_DYN_TYPE && an.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_NONE {
                        if d.module == self.ph_box.mid && d.node == self.ph_box.node {
                            return self.lower_type_in(m, a0);
                        }
                    }
                }
                if (dnk == NodeKind::NODE_STRUCT || dnk == NodeKind::NODE_ENUM) && unsafe (*self.mod_ast(d.module)).at_const(
                    d.node,
                ).as_data.aggregate.generics.len > 0 && (args.len > 0 || self.agg_has_default_at(
                    d.module,
                    d.node,
                    args.len,
                )) {
                    let mut ta = Tys8 {};
                    if args.len > 8 {
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("too many generic arguments ({}; the maximum is 8)", args.len),
                        );
                    }
                    let mut tn: u8 = 0;
                    let mut i: u32 = 0;
                    while i < args.len && tn < 8 {
                        let aid = unsafe (*a).list(args)[i as usize];
                        if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LITERAL {
                            ta[tn as usize] = self.tc_const_arg(m, aid);
                            tn = tn + 1;
                            i = i + 1;
                            continue;
                        }
                        ta[tn as usize] = self.lower_type_in(m, aid);
                        if ta[tn as usize] != TYPE_NONE && self.type_at(ta[tn as usize]).kind == TypeKind::TYPE_ARRAY && self.type_at(
                            ta[tn as usize],
                        ).as_data.arr.len == 0 {
                            let asp = unsafe (*a).at_const(aid).span;
                            self.errors.emit(
                                asp.start,
                                asp.end - asp.start,
                                format(
                                    "a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct",
                                ),
                            );
                            ta[tn as usize] = TYPE_NONE;
                        }
                        tn = tn + 1;
                        i = i + 1;
                    }
                    self.apply_default_args(d.module, d.node, (&mut ta[0]) as *mut TypeId, (&mut tn) as *mut u8);
                    return unsafe (*self.cur_ast()).intern_instance(d.module, d.node, (&ta[0]) as *const TypeId, tn);
                }
                return self.named_type_of(d.module, d.node);
            }
            let parts = unsafe (*a).at_const(id).as_data.type_path.parts;
            let mut b: i32 = -1;
            if parts.len != 0 {
                let p0 = unsafe (*a).list(parts)[0];
                b = builtin_of(self.mod_src(m), unsafe (*a).at_const(p0).as_data.name.text);
            }
            if b >= 0 {
                return Ast::builtin(b as BuiltinType);
            }
            return TYPE_ERROR;
        }
        if nk == NodeKind::NODE_SLICE_TYPE {
            let it = unsafe (*a).at_const(id).as_data.indirect_type;
            return self.prelude_slice_type(self.lower_type_in(m, it.ty), it.qualifier == TypeQualifier::TYPE_QUAL_MUT);
        }
        if nk == NodeKind::NODE_TUPLE_TYPE {
            let elems = unsafe (*a).at_const(id).as_data.array_literal.elements;
            if elems.len > 4 {
                return TYPE_ERROR;
            }
            let mut targs = Tys8 {};
            for i in 0..elems.len {
                targs[i as usize] = self.lower_type_in(m, unsafe (*a).list(elems)[i as usize]);
            }
            return self.prelude_tuple_type((&targs[0]) as *const TypeId, elems.len);
        }
        if nk == NodeKind::NODE_POINTER_TYPE || nk == NodeKind::NODE_REFERENCE_TYPE {
            let it = unsafe (*a).at_const(id).as_data.indirect_type;
            let mut k = TypeKind::TYPE_REFERENCE;
            if nk == NodeKind::NODE_POINTER_TYPE {
                k = TypeKind::TYPE_POINTER;
            }
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: k, qualifier: it.qualifier as u8, as_data: TyAs { elem: self.lower_type_in(m, it.ty) } },
            );
        }
        if nk == NodeKind::NODE_ARRAY_TYPE {
            let at = unsafe (*a).at_const(id).as_data.array_type;
            let alen = self.ce_array_len(m, at.length);
            return unsafe (*self.cur_ast()).intern_type(
                Ty {
                    kind: TypeKind::TYPE_ARRAY,
                    as_data: TyAs { arr: TyArr { elem: self.lower_type_in(m, at.element), len: alen } },
                },
            );
        }
        if nk == NodeKind::NODE_FUNCTION_TYPE {
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_FUNCTION, module: m, as_data: TyAs { decl: id } },
            );
        }
        if nk == NodeKind::NODE_DYN_TYPE {
            let it = unsafe (*a).at_const(id).as_data.indirect_type;
            let inner = it.ty;
            if unsafe (*a).at_const(inner).kind == NodeKind::NODE_FUNCTION_TYPE {
                return self.tc_intern_dynfn(m, inner, it.qualifier);
            }
            let mut d = DefId { module: 0, node: NODE_NONE };
            if unsafe (*a).at_const(inner).kind == NodeKind::NODE_TYPE_PATH {
                d = unsafe (*a).resolution_def(inner);
            }
            if d.node == NODE_NONE || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_INTERFACE {
                return TYPE_ERROR;
            }
            return unsafe (*self.cur_ast()).intern_type(
                Ty {
                    kind: TypeKind::TYPE_DYN,
                    qualifier: it.qualifier as u8,
                    module: d.module,
                    as_data: TyAs { decl: d.node },
                },
            );
        }
        return TYPE_ERROR;
    }

    fn resolve_type(self: &mut Self, id: NodeId) TypeId {
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        let cached = unsafe (*self.cur_ast()).type_of(id);
        if cached != TYPE_NONE {
            return cached;
        }
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(id).kind;
        let mut result = TYPE_ERROR;
        switch nk {
            NODE_TYPE_PATH => {
                let parts = unsafe (*a).at_const(id).as_data.type_path.parts;
                let args = unsafe (*a).at_const(id).as_data.type_path.args;
                // Box<dyn I> interception
                let mut i: u32 = 0;
                while i < args.len && self.package != null {
                    let aid = unsafe (*a).list(args)[i as usize];
                    let an = unsafe (*a).at_const(aid);
                    if an.kind != NodeKind::NODE_DYN_TYPE || an.as_data.indirect_type.qualifier != TypeQualifier::TYPE_QUAL_NONE {
                        i = i + 1;
                        continue;
                    }
                    let bh = self.ph_box;
                    let hd = unsafe (*a).resolution_def(id);
                    if args.len == 1 && hd.module == bh.mid && hd.node == bh.node {
                        result = self.resolve_dyn_node(unsafe (*a).list(args)[0], TypeQualifier::TYPE_QUAL_NONE);
                    } else {
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("a bare 'dyn' type can only be the generic argument of 'Box'"),
                        );
                    }
                    unsafe (*self.cur_ast()).set_type(id, result);
                    return result;
                }
                i = 0;
                while i < args.len {
                    self.resolve_type(unsafe (*a).list(args)[i as usize]);
                    i = i + 1;
                }
                let d = unsafe (*a).resolution_def(id);
                if d.node != NODE_NONE {
                    let mut bb: i32 = -1;
                    if self.package != null {
                        bb = unsafe (*self.package).builtin_of_decl(d.module, d.node);
                    }
                    if bb >= 0 {
                        result = Ast::builtin(bb as BuiltinType);
                    } else {
                        let dnk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
                        let generic_agg = (dnk == NodeKind::NODE_STRUCT || dnk == NodeKind::NODE_ENUM) && unsafe (*self.mod_ast(
                            d.module,
                        )).at_const(d.node).as_data.aggregate.generics.len > 0;
                        if generic_agg && args.len == 0 && self.current_extend != NODE_NONE && d.module == self.ast.module && d.node == self.current_self {
                            let target = unsafe (*a).at_const(self.current_extend).as_data.extend_def.target_type;
                            if target != id {
                                result = self.resolve_type(target);
                            } else {
                                result = self.named_type_of(d.module, d.node);
                            }
                        } else if generic_agg && (args.len > 0 || self.agg_has_default_at(d.module, d.node, args.len)) {
                            let mut ta = Tys8 {};
                            if args.len > 8 {
                                let sp = unsafe (*a).at_const(id).span;
                                self.errors.emit(
                                    sp.start,
                                    sp.end - sp.start,
                                    format("too many generic arguments ({}; the maximum is 8)", args.len),
                                );
                            }
                            let mut tn: u8 = 0;
                            let mut j: u32 = 0;
                            while j < args.len && tn < 8 {
                                let aid = unsafe (*a).list(args)[j as usize];
                                if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LITERAL {
                                    ta[tn as usize] = self.tc_const_arg(self.ast.module, aid);
                                } else {
                                    ta[tn as usize] = self.resolve_type(aid);
                                    if ta[tn as usize] != TYPE_NONE && self.type_at(ta[tn as usize]).kind == TypeKind::TYPE_ARRAY && self.type_at(
                                        ta[tn as usize],
                                    ).as_data.arr.len == 0 {
                                        let asp = unsafe (*a).at_const(aid).span;
                                        self.errors.emit(
                                            asp.start,
                                            asp.end - asp.start,
                                            format(
                                                "a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct",
                                            ),
                                        );
                                        ta[tn as usize] = TYPE_NONE;
                                    }
                                }
                                tn = tn + 1;
                                j = j + 1;
                            }
                            self.apply_default_args(d.module, d.node, (&mut ta[0]) as *mut TypeId, (&mut tn) as *mut u8);
                            result = unsafe (*self.cur_ast()).intern_instance(
                                d.module,
                                d.node,
                                (&ta[0]) as *const TypeId,
                                tn,
                            );
                        } else {
                            result = self.named_type_of(d.module, d.node);
                            if dnk == NodeKind::NODE_INTERFACE && parts.len != 0 && !span_is(
                                self.source,
                                self.name_span(unsafe (*a).list(parts)[0]),
                                "Self",
                            ) {
                                let isp = self.name_span(unsafe (*a).list(parts)[0]);
                                self.errors.emit(
                                    isp.start,
                                    isp.end - isp.start,
                                    format(
                                        "an interface is not a type; use '&dyn {}', 'Box<dyn {}>', or a generic bound",
                                        diag::span_str(self.source, isp.start, isp.end),
                                        diag::span_str(self.source, isp.start, isp.end),
                                    ),
                                );
                            }
                            if d.module == self.ast.module {
                                for k in 1..parts.len {
                                    let pid = unsafe (*a).list(parts)[k as usize];
                                    let member = self.find_member(d.module, d.node, self.name_span(pid));
                                    if member != NODE_NONE {
                                        unsafe (*self.cur_ast()).set_resolution(pid, member);
                                    }
                                }
                            }
                        }
                    }
                } else if parts.len > 0 {
                    let b = builtin_of(self.source, self.name_span(unsafe (*a).list(parts)[0]));
                    if b >= 0 {
                        result = Ast::builtin(b as BuiltinType);
                    } else {
                        result = TYPE_ERROR;
                    }
                }
            },
            NODE_SLICE_TYPE => {
                let it = unsafe (*a).at_const(id).as_data.indirect_type;
                result = self.prelude_slice_type(self.resolve_type(it.ty), it.qualifier == TypeQualifier::TYPE_QUAL_MUT);
            },
            NODE_TUPLE_TYPE => {
                let elems = unsafe (*a).at_const(id).as_data.array_literal.elements;
                if elems.len > 4 {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("tuple arity is limited to 4 elements"));
                } else {
                    let mut targs = Tys8 {};
                    for i in 0..elems.len {
                        targs[i as usize] = self.resolve_type(unsafe (*a).list(elems)[i as usize]);
                    }
                    result = self.prelude_tuple_type((&targs[0]) as *const TypeId, elems.len);
                }
            },
            NODE_POINTER_TYPE | NODE_REFERENCE_TYPE => {
                let it = unsafe (*a).at_const(id).as_data.indirect_type;
                let mut k = TypeKind::TYPE_REFERENCE;
                if nk == NodeKind::NODE_POINTER_TYPE {
                    k = TypeKind::TYPE_POINTER;
                }
                result = unsafe (*self.cur_ast()).intern_type(
                    Ty { kind: k, qualifier: it.qualifier as u8, as_data: TyAs { elem: self.resolve_type(it.ty) } },
                );
            },
            NODE_ARRAY_TYPE => {
                let at = unsafe (*a).at_const(id).as_data.array_type;
                self.check_expr(at.length);
                let alen = self.ce_array_len(self.ast.module, at.length);
                result = unsafe (*self.cur_ast()).intern_type(
                    Ty {
                        kind: TypeKind::TYPE_ARRAY,
                        as_data: TyAs { arr: TyArr { elem: self.resolve_type(at.element), len: alen } },
                    },
                );
            },
            NODE_FUNCTION_TYPE => {
                result = unsafe (*self.cur_ast()).intern_type(
                    Ty { kind: TypeKind::TYPE_FUNCTION, module: self.ast.module, as_data: TyAs { decl: id } },
                );
            },
            NODE_DYN_TYPE => {
                let q = unsafe (*a).at_const(id).as_data.indirect_type.qualifier;
                if q == TypeQualifier::TYPE_QUAL_NONE {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a 'dyn' type must be '&dyn I', '&mut dyn I', or 'Box<dyn I>'"),
                    );
                } else {
                    result = self.resolve_dyn_node(id, q);
                }
            },
            _ => {},
        };
        unsafe (*self.cur_ast()).set_type(id, result);
        return result;
    }

    // ---- dyn trait objects ----
    fn tc_intern_dynfn(self: &mut Self, m: ModuleId, sig: NodeId, qual: TypeQualifier) TypeId {
        let mysig = self.lower_type_in(m, sig);
        // TC-7: candidates come from dynfn_list instead of a full pool rescan. New pool entries
        // (including ones interned by the compares below) are absorbed before each compare, so the
        // candidate sequence is exactly the old in-order scan's.
        let mut idx: usize = 0;
        loop {
            while self.dynfn_scan as usize < unsafe (*self.cur_ast()).type_pool.len() {
                let e = *self.type_at(self.dynfn_scan);
                if e.kind == TypeKind::TYPE_DYN && unsafe (*self.mod_ast(e.module)).at_const(e.as_data.decl).kind == NodeKind::NODE_FUNCTION_TYPE {
                    self.dynfn_list.push(self.dynfn_scan);
                }
                self.dynfn_scan = self.dynfn_scan + 1;
            }
            if idx >= self.dynfn_list.len() {
                break;
            }
            let e = *self.type_at(self.dynfn_list[idx]);
            idx = idx + 1;
            let esig = self.lower_type_in(e.module, e.as_data.decl);
            if esig == mysig || self.fn_compatible(esig, mysig) {
                return unsafe (*self.cur_ast()).intern_type(
                    Ty {
                        kind: TypeKind::TYPE_DYN,
                        qualifier: qual as u8,
                        module: e.module,
                        as_data: TyAs { decl: e.as_data.decl },
                    },
                );
            }
        }
        return unsafe (*self.cur_ast()).intern_type(
            Ty { kind: TypeKind::TYPE_DYN, qualifier: qual as u8, module: m, as_data: TyAs { decl: sig } },
        );
    }

    fn resolve_dyn_node(self: &mut Self, id: NodeId, qual: TypeQualifier) TypeId {
        let a = self.cur_ast();
        let inner = unsafe (*a).at_const(id).as_data.indirect_type.ty;
        let mut result = TYPE_ERROR;
        if unsafe (*a).at_const(inner).kind == NodeKind::NODE_FUNCTION_TYPE {
            let sp = unsafe (*a).at_const(id).span;
            let mut concrete = qual != TypeQualifier::TYPE_QUAL_MUT;
            if !concrete {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("a 'dyn fn' is always called through a shared view; write '&dyn fn(..) ..'"),
                );
            }
            let ftp = unsafe (*a).at_const(inner).as_data.function_type;
            let mut i: u32 = 0;
            while concrete && i < ftp.params.len {
                concrete = self.type_at(self.resolve_type(unsafe (*a).list(ftp.params)[i as usize])).kind != TypeKind::TYPE_GENERIC;
                i = i + 1;
            }
            i = 0;
            while concrete && i < ftp.returns.len {
                let rid = unsafe (*a).list(ftp.returns)[i as usize];
                let rn = unsafe (*a).at_const(rid);
                let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rid);
                concrete = self.type_at(self.resolve_type(tn)).kind != TypeKind::TYPE_GENERIC;
                i = i + 1;
            }
            if concrete {
                result = self.tc_intern_dynfn(self.ast.module, inner, qual);
            } else if qual != TypeQualifier::TYPE_QUAL_MUT {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("a 'dyn fn' signature cannot name a generic parameter"),
                );
            }
            unsafe (*self.cur_ast()).set_type(id, result);
            return result;
        }
        let mut d = DefId { module: 0, node: NODE_NONE };
        if unsafe (*a).at_const(inner).kind == NodeKind::NODE_TYPE_PATH {
            d = unsafe (*a).resolution_def(inner);
        }
        let sp = unsafe (*a).at_const(id).span;
        if d.node == NODE_NONE || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_INTERFACE {
            self.errors.emit(sp.start, sp.end - sp.start, format("'dyn' requires an interface"));
        } else if self.dyn_compatible(d, sp) {
            result = unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_DYN, qualifier: qual as u8, module: d.module, as_data: TyAs { decl: d.node } },
            );
        }
        unsafe (*self.cur_ast()).set_type(id, result);
        return result;
    }

    fn dyn_method(self: &Self, imod: ModuleId, mnode: NodeId) bool {
        let ia = self.mod_ast(imod);
        let mn = unsafe (*ia).at_const(mnode);
        if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.params.len == 0 {
            return false;
        }
        let p0 = unsafe (*ia).list(mn.as_data.function.params)[0];
        let pnm = unsafe (*ia).at_const(unsafe (*ia).at_const(p0).as_data.parameter.name).as_data.name.text;
        return span_is(self.mod_src(imod), pnm, "self");
    }

    fn tc_mentions_self(self: &Self, imod: ModuleId, tn: NodeId, iface: DefId) bool {
        if tn == NODE_NONE {
            return false;
        }
        let ia = self.mod_ast(imod);
        let n = unsafe (*ia).at_const(tn);
        if n.kind == NodeKind::NODE_TYPE_PATH {
            let d = unsafe (*ia).resolution_def(tn);
            if d.module == iface.module && d.node == iface.node {
                return true;
            }
            let args = n.as_data.type_path.args;
            for i in 0..args.len {
                if self.tc_mentions_self(imod, unsafe (*ia).list(args)[i as usize], iface) {
                    return true;
                }
            }
            return false;
        }
        if n.kind == NodeKind::NODE_POINTER_TYPE || n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE || n.kind == NodeKind::NODE_DYN_TYPE {
            return self.tc_mentions_self(imod, n.as_data.indirect_type.ty, iface);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.tc_mentions_self(imod, n.as_data.array_type.element, iface);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let elems = n.as_data.array_literal.elements;
            for i in 0..elems.len {
                if self.tc_mentions_self(imod, unsafe (*ia).list(elems)[i as usize], iface) {
                    return true;
                }
            }
            return false;
        }
        if n.kind == NodeKind::NODE_FUNCTION_TYPE {
            let ft = n.as_data.function_type;
            for i in 0..ft.params.len {
                if self.tc_mentions_self(imod, unsafe (*ia).list(ft.params)[i as usize], iface) {
                    return true;
                }
            }
            for i in 0..ft.returns.len {
                if self.tc_mentions_self(imod, unsafe (*ia).list(ft.returns)[i as usize], iface) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    fn dyn_compatible(self: &mut Self, iface: DefId, at: tok::Span) bool {
        let ia = self.mod_ast(iface.module);
        let isrc = self.mod_src(iface.module);
        let idn = unsafe (*ia).at_const(iface.node).as_data.interface_def;
        let mut why: str = "";
        let mut mn = tok::Span { start: 0, end: 0 };
        if idn.generics.len != 0 {
            why = "the interface has generic parameters";
        } else if idn.bounds.len != 0 {
            why = "the interface has superinterfaces";
        }
        let mut i: u32 = 0;
        while why.len() == 0 && i < idn.items.len {
            let mid = unsafe (*ia).list(idn.items)[i as usize];
            if self.dyn_method(iface.module, mid) {
                let m = unsafe (*ia).at_const(mid).as_data.function;
                mn = unsafe (*ia).at_const(m.name).as_data.name.text;
                let p0 = unsafe (*ia).list(m.params)[0];
                let st = unsafe (*ia).at_const(p0).as_data.parameter.ty;
                let mut sk = NodeKind::NODE_NONE_KIND;
                if st != NODE_NONE {
                    sk = unsafe (*ia).at_const(st).kind;
                }
                if m.generics.len != 0 {
                    why = "a method has its own generic parameters";
                } else if sk != NodeKind::NODE_REFERENCE_TYPE && sk != NodeKind::NODE_POINTER_TYPE {
                    why = "a method takes 'Self' by value";
                } else if m.returns.len > 1 {
                    why = "a method has multiple return values";
                }
                let mut p: u32 = 1;
                while why.len() == 0 && p < m.params.len {
                    let pid = unsafe (*ia).list(m.params)[p as usize];
                    if self.tc_mentions_self(iface.module, unsafe (*ia).at_const(pid).as_data.parameter.ty, iface) {
                        why = "a method mentions 'Self' outside the receiver";
                    }
                    p = p + 1;
                }
                let mut r: u32 = 0;
                while why.len() == 0 && r < m.returns.len {
                    let rid = unsafe (*ia).list(m.returns)[r as usize];
                    let rn = unsafe (*ia).at_const(rid);
                    let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rid);
                    if self.tc_mentions_self(iface.module, tn, iface) {
                        why = "a method mentions 'Self' outside the receiver";
                    }
                    r = r + 1;
                }
            }
            i = i + 1;
        }
        if why.len() == 0 {
            return true;
        }
        let inm = unsafe (*ia).at_const(idn.name).as_data.name.text;
        self.errors.emit(
            at.start,
            at.end - at.start,
            format("interface '{}' is not dyn-compatible: {}", diag::span_str(isrc, inm.start, inm.end), why),
        );
        if mn.end > mn.start {
            self.errors.note(format("offending method: '{}'", diag::span_str(isrc, mn.start, mn.end)));
        }
        return false;
    }

    // ---- extension / method lookup ----
    fn ext_scopes(self: &mut Self) i32 {
        if self.n_ext_scope < 0 {
            self.ext_scope.clear();
            self.ext_scope.push(self.ast.module);
            if self.package != null {
                let mut closure = unsafe (*self.package).import_closure(self.ast.module);
                for i in 0..closure.len() {
                    self.ext_scope.push(closure[i]);
                }
            }
            self.n_ext_scope = self.ext_scope.len() as i32;
        }
        return self.n_ext_scope;
    }
    fn ext_scope_at(self: &Self, i: i32) ModuleId {
        return self.ext_scope[i as usize];
    }

    // Build (once) module `mm`'s list of top-level EXTEND item ids. No type interning happens here, so it is
    // safe to build lazily at any point during type-checking.
    fn ensure_ext_items(self: &mut Self, mm: ModuleId) void {
        let idx = mm as usize;
        while self.ext_items.len() <= idx {
            self.ext_items.push(Vector::<NodeId>::new());
        }
        while self.ext_items_built.len() <= idx {
            self.ext_items_built.push(false);
        }
        if self.ext_items_built[idx] {
            return;
        }
        self.ext_items_built[idx] = true;
        let a = self.mod_ast(mm);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
                self.ext_items[idx].push(iid);
            }
        }
    }
    fn ext_items_len(self: &Self, mm: ModuleId) usize {
        return self.ext_items[mm as usize].len();
    }
    fn ext_items_at(self: &Self, mm: ModuleId, i: usize) NodeId {
        return self.ext_items[mm as usize][i];
    }

    // The type-identity an extend's target dispatches on (peeling a transparent alias).
    fn tc_peel_target(self: &mut Self, tg: DefId) DefId {
        if tg.node == NODE_NONE {
            return tg;
        }
        let dn = *unsafe (*self.mod_ast(tg.module)).at_const(tg.node);
        if dn.kind != NodeKind::NODE_TYPE_ALIAS || dn.as_data.type_alias.ty == NODE_NONE || dn.as_data.type_alias.generics.len != 0 {
            return tg;
        }
        let ty = *self.type_at(self.named_type_of(tg.module, tg.node));
        if ty.kind == TypeKind::TYPE_BUILTIN {
            let mut bd = NODE_NONE;
            if self.package != null {
                bd = unsafe (*self.package).builtin_decl(ty.as_data.builtin);
            }
            if bd != NODE_NONE {
                return DefId { module: unsafe (*self.package).core_module, node: bd };
            }
            return tg;
        }
        if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM {
            return DefId { module: ty.module, node: ty.as_data.decl };
        }
        if ty.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
            return DefId { module: it.module, node: it.decl };
        }
        return tg;
    }

    fn find_member(self: &Self, m: ModuleId, decl: NodeId, name: tok::Span) NodeId {
        let a = self.mod_ast(m);
        let src = self.mod_src(m);
        let d = unsafe (*a).at_const(decl);
        if d.kind != NodeKind::NODE_STRUCT && d.kind != NodeKind::NODE_ENUM {
            return NODE_NONE;
        }
        let members = d.as_data.aggregate.members;
        for i in 0..members.len {
            let mid = unsafe (*a).list(members)[i as usize];
            let mem = unsafe (*a).at_const(mid);
            let mname = if_node(mem.kind == NodeKind::NODE_FIELD, mem.as_data.field.name, mem.as_data.variant.name);
            if spans_eq2(self.source, name, src, unsafe (*a).at_const(mname).as_data.name.text) {
                return mid;
            }
        }
        return NODE_NONE;
    }
    fn find_member_cstr(self: &Self, m: ModuleId, decl: NodeId, name: str) NodeId {
        let a = self.mod_ast(m);
        let src = self.mod_src(m);
        let d = unsafe (*a).at_const(decl);
        if d.kind != NodeKind::NODE_STRUCT && d.kind != NodeKind::NODE_ENUM {
            return NODE_NONE;
        }
        let members = d.as_data.aggregate.members;
        let nl = name.len();
        for i in 0..members.len {
            let mid = unsafe (*a).list(members)[i as usize];
            let mem = unsafe (*a).at_const(mid);
            let mname = if_node(mem.kind == NodeKind::NODE_FIELD, mem.as_data.field.name, mem.as_data.variant.name);
            let sp = unsafe (*a).at_const(mname).as_data.name.text;
            if (sp.end - sp.start) as usize == nl && unsafe cstring::memcmp(
                src.ptr() + sp.start as usize,
                name.ptr(),
                nl,
            ) == 0 {
                return mid;
            }
        }
        return NODE_NONE;
    }

    // TC-8: both lookups are memoized -- callers re-resolve the same method's owner repeatedly
    // (tc_method_param + tc_method_ret alone scan twice per operator check). Lazy insert through a
    // const-cast, the codebase's established pattern for caches behind &Self.
    fn enclosing_extend(self: &Self, m: ModuleId, method: NodeId) NodeId {
        let key = m as u64 << 32 | method as u64;
        switch self.encl_ext_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut res = NODE_NONE;
        let mut i: u32 = 0;
        while i < items.len && res == NODE_NONE {
            let iid = unsafe (*a).list(items)[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
                let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                for j in 0..ms.len {
                    if unsafe (*a).list(ms)[j as usize] == method {
                        res = iid;
                        break;
                    }
                }
            }
            i = i + 1;
        }
        let mself = (self as *const TypeChecker) as *mut TypeChecker;
        unsafe (*mself).encl_ext_memo.insert(key, res);
        return res;
    }
    fn enclosing_trait(self: &Self, m: ModuleId, method: NodeId) NodeId {
        let key = m as u64 << 32 | method as u64;
        switch self.encl_trait_memo.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut res = NODE_NONE;
        let mut i: u32 = 0;
        while i < items.len && res == NODE_NONE {
            let iid = unsafe (*a).list(items)[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_INTERFACE {
                let ms = unsafe (*a).at_const(iid).as_data.interface_def.items;
                for j in 0..ms.len {
                    if unsafe (*a).list(ms)[j as usize] == method {
                        res = iid;
                        break;
                    }
                }
            }
            i = i + 1;
        }
        let mself = (self as *const TypeChecker) as *mut TypeChecker;
        unsafe (*mself).encl_trait_memo.insert(key, res);
        return res;
    }

    // Find a method named `name`/`lit` in an extend of (m,decl); marks it used. Searches the type's home
    // module, then the current module + imports.
    fn find_method_impl(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span, lit: str) DefId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut mm = m;
            if s >= 0 {
                mm = self.ext_scope_at(s);
            }
            if s >= 0 && mm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(mm);
            let a = self.mod_ast(mm);
            let ne = self.ext_items_len(mm);
            for i in 0..ne {
                let iid = self.ext_items_at(mm, i);
                let it = unsafe (*a).at_const(iid);
                if it.as_data.extend_def.target_type != NODE_NONE {
                    let tg = self.tc_peel_target(unsafe (*a).resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == m && tg.node == decl {
                        let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let mid = unsafe (*a).list(ms)[j as usize];
                            let mn = unsafe (*a).at_const(mid);
                            // Privacy: a method from another module must be `pub` (mirrors find_assoc_const).
                            if mn.kind == NodeKind::NODE_FUNCTION && !(mm != self.ast.module && !mn.as_data.function.is_public) {
                                let mname = unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text;
                                let mut hit = false;
                                if lit.len() != 0 {
                                    hit = span_is(self.mod_src(mm), mname, lit);
                                } else {
                                    hit = spans_eq2(self.source, name, self.mod_src(mm), mname);
                                }
                                if hit {
                                    unsafe (*self.package).mark_method_used(DefId { module: mm, node: mid });
                                    return DefId { module: mm, node: mid };
                                }
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn find_method(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span) DefId {
        return self.find_method_impl(m, decl, name, "");
    }
    fn find_method_cstr(self: &mut Self, m: ModuleId, decl: NodeId, lit: str) DefId {
        return self.find_method_impl(m, decl, tok::Span::empty(), lit);
    }

    fn find_assoc_const(self: &mut Self, m: ModuleId, decl: NodeId, name: tok::Span) DefId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut sm = m;
            if s >= 0 {
                sm = self.ext_scope_at(s);
            }
            if s >= 0 && sm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(sm);
            let a = self.mod_ast(sm);
            let ne = self.ext_items_len(sm);
            for i in 0..ne {
                let iid = self.ext_items_at(sm, i);
                let it = unsafe (*a).at_const(iid);
                if it.as_data.extend_def.generics.len == 0 {
                    let tg = self.tc_peel_target(unsafe (*a).resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == m && tg.node == decl {
                        let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let cid = unsafe (*a).list(ms)[j as usize];
                            let cn = unsafe (*a).at_const(cid);
                            if cn.kind == NodeKind::NODE_CONST && !(sm != self.ast.module && !cn.as_data.const_def.is_public) {
                                if spans_eq2(
                                    self.source,
                                    name,
                                    self.mod_src(sm),
                                    unsafe (*a).at_const(cn.as_data.const_def.name).as_data.name.text,
                                ) {
                                    return DefId { module: sm, node: cid };
                                }
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn find_extend_as(self: &mut Self, tmod: ModuleId, tdecl: NodeId, iface: DefId, imod: *mut ModuleId) NodeId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut m = tmod;
            if s >= 0 {
                m = self.ext_scope_at(s);
            }
            if s >= 0 && m == tmod {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(m);
            let a = self.mod_ast(m);
            let ne = self.ext_items_len(m);
            for i in 0..ne {
                let iid = self.ext_items_at(m, i);
                let it = unsafe (*a).at_const(iid);
                if it.as_data.extend_def.interface_type != NODE_NONE && it.as_data.extend_def.target_type != NODE_NONE {
                    let tr = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                    let tg = self.tc_peel_target(unsafe (*a).resolution_def(it.as_data.extend_def.target_type));
                    if tr.module == iface.module && tr.node == iface.node && tg.module == tmod && tg.node == tdecl {
                        unsafe *imod = m;
                        return iid;
                    }
                }
            }
            s = s + 1;
        }
        return NODE_NONE;
    }

    fn find_interface_method(self: &Self, m: ModuleId, iface: NodeId, name: tok::Span, depth: i32) DefId {
        if depth > 8 {
            return DefId { module: 0, node: NODE_NONE };
        }
        let a = self.mod_ast(m);
        let tn = unsafe (*a).at_const(iface);
        if tn.kind != NodeKind::NODE_INTERFACE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let items = tn.as_data.interface_def.items;
        for i in 0..items.len {
            let mid = unsafe (*a).list(items)[i as usize];
            let mn = unsafe (*a).at_const(mid);
            if mn.kind == NodeKind::NODE_FUNCTION && spans_eq2(
                self.source,
                name,
                self.mod_src(m),
                unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text,
            ) {
                return DefId { module: m, node: mid };
            }
        }
        let bounds = tn.as_data.interface_def.bounds;
        for i in 0..bounds.len {
            let bid = unsafe (*a).list(bounds)[i as usize];
            let sb = unsafe (*a).resolution_def(bid);
            if sb.node != NODE_NONE {
                let r = self.find_interface_method(sb.module, sb.node, name, depth + 1);
                if r.node != NODE_NONE {
                    return r;
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn find_default_method(self: &mut Self, tmod: ModuleId, tdecl: NodeId, name: tok::Span) DefId {
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut m = tmod;
            if s >= 0 {
                m = self.ext_scope_at(s);
            }
            if s >= 0 && m == tmod {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(m);
            let a = self.mod_ast(m);
            let ne = self.ext_items_len(m);
            for i in 0..ne {
                let iid = self.ext_items_at(m, i);
                let it = unsafe (*a).at_const(iid);
                if it.as_data.extend_def.interface_type != NODE_NONE {
                    let tg = self.tc_peel_target(unsafe (*a).resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == tmod && tg.node == tdecl {
                        let iff = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                        if iff.node != NODE_NONE {
                            let mth = self.find_interface_method(iff.module, iff.node, name, 0);
                            if mth.node != NODE_NONE && unsafe (*self.mod_ast(mth.module)).at_const(mth.node).as_data.function.body != NODE_NONE {
                                return mth;
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn add_bound_ifaces_full(
        self: &mut Self,
        m: ModuleId,
        bounds: NodeList,
        out: *mut BoundIface,
        n: *mut i32,
        cap: i32,
    ) void {
        let a = self.mod_ast(m);
        let mut i: u32 = 0;
        while i < bounds.len && unsafe *n < cap {
            let bid = unsafe (*a).list(bounds)[i as usize];
            let d = unsafe (*a).resolution_def(bid);
            if d.node != NODE_NONE {
                let mut b = BoundIface { iface: d, n: 0 };
                if unsafe (*a).at_const(bid).kind == NodeKind::NODE_TYPE_PATH {
                    let aids = unsafe (*a).at_const(bid).as_data.type_path.args;
                    let mut k: u32 = 0;
                    while k < aids.len && b.n < 8 {
                        b.args[b.n as usize] = self.lower_type_in(m, unsafe (*a).list(aids)[k as usize]);
                        b.n = b.n + 1;
                        k = k + 1;
                    }
                }
                let idx = unsafe *n;
                unsafe out[idx as usize] = b;
                unsafe *n = idx + 1;
            }
            i = i + 1;
        }
    }
    fn collect_param_bounds_full(self: &mut Self, pmod: ModuleId, pdecl: NodeId, out: *mut BoundIface, cap: i32) i32 {
        let mut n: i32 = 0;
        let pa = self.mod_ast(pmod);
        self.add_bound_ifaces_full(
            pmod,
            unsafe (*pa).at_const(pdecl).as_data.generic_param.bounds,
            out,
            (&mut n) as *mut i32,
            cap,
        );
        if pmod == self.ast.module && self.current_fn != NODE_NONE {
            let wc = unsafe (*self.cur_ast()).at_const(self.current_fn).as_data.function.where_clause;
            for w in 0..wc.len {
                let wid = unsafe (*self.cur_ast()).list(wc)[w as usize];
                let wp = unsafe (*self.cur_ast()).at_const(wid).as_data.where_predicate;
                if unsafe (*self.cur_ast()).resolution(wp.ty) == pdecl {
                    self.add_bound_ifaces_full(self.ast.module, wp.bounds, out, (&mut n) as *mut i32, cap);
                }
            }
        }
        return n;
    }
    fn trait_contains_method(self: &Self, iface: DefId, method: DefId, depth: i32) bool {
        if iface.node == NODE_NONE || depth > 8 {
            return false;
        }
        let ia = self.mod_ast(iface.module);
        let idn = unsafe (*ia).at_const(iface.node);
        if idn.kind != NodeKind::NODE_INTERFACE {
            return false;
        }
        let items = idn.as_data.interface_def.items;
        for i in 0..items.len {
            if iface.module == method.module && unsafe (*ia).list(items)[i as usize] == method.node {
                return true;
            }
        }
        let bounds = idn.as_data.interface_def.bounds;
        for i in 0..bounds.len {
            if self.trait_contains_method(
                unsafe (*ia).resolution_def(unsafe (*ia).list(bounds)[i as usize]),
                method,
                depth + 1,
            ) {
                return true;
            }
        }
        return false;
    }
    fn bound_method_subst(
        self: &mut Self,
        pmod: ModuleId,
        pdecl: NodeId,
        method: DefId,
        outp: *mut DefId,
        outa: *mut TypeId,
        cap: i32,
    ) i32 {
        let mut ifaces = BoundArr8 {};
        let ni = self.collect_param_bounds_full(pmod, pdecl, (&mut ifaces[0]) as *mut BoundIface, 8);
        for i in 0..ni {
            if self.trait_contains_method(ifaces[i as usize].iface, method, 0) {
                let ia = self.mod_ast(ifaces[i as usize].iface.module);
                let gens = unsafe (*ia).at_const(ifaces[i as usize].iface.node).as_data.interface_def.generics;
                let mut n: i32 = 0;
                let mut g: u32 = 0;
                while g < gens.len && g as u8 < ifaces[i as usize].n && n < cap {
                    let gid = unsafe (*ia).list(gens)[g as usize];
                    unsafe outp[n as usize] = DefId { module: ifaces[i as usize].iface.module, node: gid };
                    unsafe outa[n as usize] = ifaces[i as usize].args[g as usize];
                    n = n + 1;
                    g = g + 1;
                }
                return n;
            }
        }
        return 0;
    }
    fn find_bound_method(self: &mut Self, pmod: ModuleId, pdecl: NodeId, name: tok::Span, iface: *mut DefId) DefId {
        let mut ifaces = BoundArr8 {};
        let ni = self.collect_param_bounds_full(pmod, pdecl, (&mut ifaces[0]) as *mut BoundIface, 8);
        for b in 0..ni {
            let id = ifaces[b as usize].iface;
            let m = self.find_interface_method(id.module, id.node, name, 0);
            if m.node != NODE_NONE {
                if iface != null {
                    unsafe *iface = id;
                }
                return m;
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn interface_declares_cstr(self: &Self, iface: DefId, m: str, depth: i32) bool {
        if depth > 8 || iface.node == NODE_NONE {
            return false;
        }
        let a = self.mod_ast(iface.module);
        let idn = unsafe (*a).at_const(iface.node);
        if idn.kind != NodeKind::NODE_INTERFACE {
            return false;
        }
        let items = idn.as_data.interface_def.items;
        for i in 0..items.len {
            let mid = unsafe (*a).list(items)[i as usize];
            let mn = unsafe (*a).at_const(mid);
            if mn.kind == NodeKind::NODE_FUNCTION && span_is(
                self.mod_src(iface.module),
                unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text,
                m,
            ) {
                return true;
            }
        }
        let bounds = idn.as_data.interface_def.bounds;
        for i in 0..bounds.len {
            if self.interface_declares_cstr(
                unsafe (*a).resolution_def(unsafe (*a).list(bounds)[i as usize]),
                m,
                depth + 1,
            ) {
                return true;
            }
        }
        return false;
    }
    fn tc_param_bound_provides(self: &mut Self, pmod: ModuleId, pdecl: NodeId, m: str) bool {
        let mut ifaces = BoundArr8 {};
        let ni = self.collect_param_bounds_full(pmod, pdecl, (&mut ifaces[0]) as *mut BoundIface, 8);
        for b in 0..ni {
            if self.interface_declares_cstr(ifaces[b as usize].iface, m, 0) {
                return true;
            }
        }
        return false;
    }

    fn type_satisfies(self: &mut Self, ty: TypeId, iface: DefId, depth: i32) bool {
        if ty == TYPE_NONE || ty == TYPE_ERROR || depth > BOUND_MAX_DEPTH {
            return true;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC {
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN {
            return y.module == iface.module && y.as_data.decl == iface.node;
        }
        let mut tmod: ModuleId = 0;
        let mut tdecl = NODE_NONE;
        let mut iargs = Tys8 {};
        let mut in2: i32 = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            tmod = y.module;
            tdecl = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            tmod = inst.module;
            tdecl = inst.decl;
            let mut k: u8 = 0;
            while k < inst.n && in2 < 8 {
                iargs[in2 as usize] = inst.args[k as usize];
                in2 = in2 + 1;
                k = k + 1;
            }
        } else if y.kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bd = unsafe (*self.package).builtin_decl(y.as_data.builtin);
            if bd == NODE_NONE {
                return false;
            }
            tmod = unsafe (*self.package).core_module;
            tdecl = bd;
        } else {
            return false;
        }
        let mut imod: ModuleId = 0;
        let extnode = self.find_extend_as(tmod, tdecl, iface, (&mut imod) as *mut ModuleId);
        if extnode == NODE_NONE {
            return false;
        }
        let ia = self.mod_ast(imod);
        let gens = unsafe (*ia).at_const(extnode).as_data.extend_def.generics;
        let mut g: u32 = 0;
        while g < gens.len && g as i32 < in2 {
            let gid = unsafe (*ia).list(gens)[g as usize];
            let gb = unsafe (*ia).at_const(gid).as_data.generic_param.bounds;
            for b in 0..gb.len {
                let gbi = unsafe (*ia).resolution_def(unsafe (*ia).list(gb)[b as usize]);
                if gbi.node != NODE_NONE && !self.type_satisfies(iargs[g as usize], gbi, depth + 1) {
                    return false;
                }
            }
            g = g + 1;
        }
        return true;
    }

    fn is_free_iface(self: &Self, tr: DefId) bool {
        if tr.node == NODE_NONE {
            return false;
        }
        let trn = unsafe (*self.mod_ast(tr.module)).at_const(tr.node);
        return trn.kind == NodeKind::NODE_INTERFACE && span_is(
            self.mod_src(tr.module),
            unsafe (*self.mod_ast(tr.module)).at_const(trn.as_data.interface_def.name).as_data.name.text,
            "Free",
        );
    }
    fn tc_param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.mod_ast(m);
        let bs = unsafe (*a).at_const(gp).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let bd = unsafe (*a).resolution_def(unsafe (*a).list(bs)[i as usize]);
            if self.is_free_iface(bd) {
                return true;
            }
        }
        return false;
    }
    fn tc_type_is_free(self: &mut Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y0 = *self.type_at(ty);
        if y0.kind == TypeKind::TYPE_FUNCTION {
            return self.fn_owns(ty);
        }
        if y0.kind == TypeKind::TYPE_DYN {
            return y0.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8;
        }
        if y0.kind == TypeKind::TYPE_GENERIC {
            let fb = self.generic_fn_bound(y0.module, y0.as_data.decl);
            if fb != NODE_NONE {
                return unsafe (*self.mod_ast(y0.module)).at_const(fb).as_data.function_type.is_move;
            }
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(
            self.strip(ty),
            (&mut om) as *mut ModuleId,
            (&mut od) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            return false;
        }
        // TC-6: the (first) Free extend of a (module, decl) is a parse-time fact -- memoize it and
        // re-run only the per-instance bound check below. 0 = "no Free extend".
        let key = om as u64 << 32 | od as u64;
        let mut fm: ModuleId = 0;
        let mut fx = NODE_NONE;
        let mut have = false;
        switch self.free_ext_memo.get(&key) {
            Some(v) => {
                if *v == 0u64 {
                    return false;
                }
                fm = (*v >> 32) as ModuleId;
                fx = (*v & 0xFFFFFFFFu64) as NodeId;
                have = true;
            },
            _ => {},
        };
        if !have {
            let ni = self.ext_scopes();
            let mut s: i32 = -1;
            while s < ni && !have {
                let mut m = om;
                if s >= 0 {
                    m = self.ext_scope_at(s);
                }
                if s >= 0 && m == om {
                    s = s + 1;
                    continue;
                }
                self.ensure_ext_items(m);
                let a = self.mod_ast(m);
                let ne = self.ext_items_len(m);
                let mut i: usize = 0;
                while i < ne && !have {
                    let iid = self.ext_items_at(m, i);
                    let it = unsafe (*a).at_const(iid);
                    if it.as_data.extend_def.interface_type != NODE_NONE && it.as_data.extend_def.target_type != NODE_NONE {
                        let tg = self.tc_peel_target(unsafe (*a).resolution_def(it.as_data.extend_def.target_type));
                        if tg.module == om && tg.node == od {
                            let tr = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                            if self.is_free_iface(tr) {
                                fm = m;
                                fx = iid;
                                have = true;
                            }
                        }
                    }
                    i = i + 1;
                }
                s = s + 1;
            }
            if !have {
                self.free_ext_memo.insert(key, 0u64);
                return false;
            }
            self.free_ext_memo.insert(key, fm as u64 << 32 | fx as u64);
        }
        let fa = self.mod_ast(fm);
        let gens = unsafe (*fa).at_const(fx).as_data.extend_def.generics;
        let mut k: u32 = 0;
        while k < gens.len && k as i32 < gn {
            let gid = unsafe (*fa).list(gens)[k as usize];
            if self.tc_param_has_free_bound(fm, gid) && !self.tc_type_is_free(ga[k as usize]) {
                return false;
            }
            k = k + 1;
        }
        return true;
    }

    fn method_extend_bounds_hold(self: &mut Self, target: TypeId, md: DefId) bool {
        if target == TYPE_NONE || md.node == NODE_NONE {
            return true;
        }
        let extnode = self.enclosing_extend(md.module, md.node);
        if extnode == NODE_NONE {
            return true;
        }
        let ia = self.mod_ast(md.module);
        let gens = unsafe (*ia).at_const(extnode).as_data.extend_def.generics;
        if gens.len == 0 {
            return true;
        }
        let mut tm: ModuleId = 0;
        let mut td = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(
            self.strip(target),
            (&mut tm) as *mut ModuleId,
            (&mut td) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            return true;
        }
        for g in 0..gens.len {
            if g as i32 >= gn {
                return false;
            }
            let gid = unsafe (*ia).list(gens)[g as usize];
            let gb = unsafe (*ia).at_const(gid).as_data.generic_param.bounds;
            for b in 0..gb.len {
                let bi = unsafe (*ia).resolution_def(unsafe (*ia).list(gb)[b as usize]);
                if bi.node != NODE_NONE && !self.type_satisfies(ga[g as usize], bi, 0) {
                    return false;
                }
            }
        }
        return true;
    }
    fn err_method_extend_bounds(self: &mut Self, at: tok::Span, target: TypeId, md: DefId) void {
        let mut ty = Buf96 {};
        self.render_type(self.strip(target), &mut ty[0], 96);
        let ma = self.mod_ast(md.module);
        let mn = unsafe (*ma).at_const(unsafe (*ma).at_const(md.node).as_data.function.name).as_data.name.text;
        self.errors.emit(
            at.start,
            at.end - at.start,
            format(
                "cannot call '{}::{}': unsatisfied interface bounds",
                diag::cstr(&ty[0]),
                diag::span_str(self.mod_src(md.module), mn.start, mn.end),
            ),
        );
        self.errors.note(format("these bounds come from the extend block that defines the method"));
    }

    fn mark_format_helpers(self: &mut Self) void {
        if self.package == null || self.fmt_marked {
            return;
        }
        let sh = unsafe (*self.package).prelude_lookup("String", true);
        if sh.node == NODE_NONE {
            return;
        }
        self.fmt_marked = true;
        let mut names = Names14 {};
        names[0] = "new".ptr() as *const char;
        names[1] = "print".ptr() as *const char;
        names[2] = "eprint".ptr() as *const char;
        names[3] = "push_i64".ptr() as *const char;
        names[4] = "push_u64".ptr() as *const char;
        names[5] = "push_f64".ptr() as *const char;
        names[6] = "push_hex_i64".ptr() as *const char;
        names[7] = "push_hex".ptr() as *const char;
        names[8] = "push_byte".ptr() as *const char;
        names[9] = "push_str".ptr() as *const char;
        names[10] = "as_str".ptr() as *const char;
        names[11] = "push_bin".ptr() as *const char;
        names[12] = "push_f64_prec".ptr() as *const char;
        names[13] = "push_padded".ptr() as *const char;
        names[14] = "pad_at".ptr() as *const char;
        names[15] = "len".ptr() as *const char;
        for i in 0..16 {
            self.find_method_cstr(sh.mid, sh.node, diag::cstr(names[i as usize]));
        }
    }

    fn resolve_conversion(self: &mut Self, name: tok::Span, want: TypeId) DefId {
        let is_into = span_is(self.source, name, "into");
        let is_try = span_is(self.source, name, "try_into");
        if !is_into && !is_try || want == TYPE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let mut m: ModuleId = 0;
        let mut decl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(
            self.strip(want),
            (&mut m) as *mut ModuleId,
            (&mut decl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            return DefId { module: 0, node: NODE_NONE };
        }
        if is_try {
            if gn < 1 {
                return DefId { module: 0, node: NODE_NONE };
            }
            if !self.aggregate_of(
                self.strip(ga[0]),
                (&mut m) as *mut ModuleId,
                (&mut decl) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            ) {
                return DefId { module: 0, node: NODE_NONE };
            }
        }
        let mut lit = "from";
        if is_try {
            lit = "try_from";
        }
        return self.find_method_cstr(m, decl, lit);
    }

    fn tc_find_from_for(self: &mut Self, target: TypeId, src: TypeId) DefId {
        let ty = *self.type_at(self.strip(target));
        if ty.kind != TypeKind::TYPE_STRUCT && ty.kind != TypeKind::TYPE_ENUM {
            return DefId { module: 0, node: NODE_NONE };
        }
        let m = ty.module;
        let decl = ty.as_data.decl;
        let ni = self.ext_scopes();
        let mut s: i32 = -1;
        while s < ni {
            let mut mm = m;
            if s >= 0 {
                mm = self.ext_scope_at(s);
            }
            if s >= 0 && mm == m {
                s = s + 1;
                continue;
            }
            self.ensure_ext_items(mm);
            let a = self.mod_ast(mm);
            let ne = self.ext_items_len(mm);
            for i in 0..ne {
                let iid = self.ext_items_at(mm, i);
                let it = unsafe (*a).at_const(iid);
                if it.as_data.extend_def.target_type != NODE_NONE && it.as_data.extend_def.generics.len == 0 {
                    let tg = self.tc_peel_target(unsafe (*a).resolution_def(it.as_data.extend_def.target_type));
                    if tg.module == m && tg.node == decl {
                        let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let mid = unsafe (*a).list(ms)[j as usize];
                            let mn = unsafe (*a).at_const(mid);
                            if mn.kind == NodeKind::NODE_FUNCTION && span_is(
                                self.mod_src(mm),
                                unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text,
                                "from",
                            ) {
                                let ps = mn.as_data.function.params;
                                if ps.len == 1 && self.decl_type_in(mm, unsafe (*a).list(ps)[0]) == src {
                                    unsafe (*self.package).mark_method_used(DefId { module: mm, node: mid });
                                    return DefId { module: mm, node: mid };
                                }
                            }
                        }
                    }
                }
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    fn dyn_coerce(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId) bool {
        let dy = *self.type_at(dyn_ty);
        let iface = DefId { module: dy.module, node: dy.as_data.decl };
        let sy = *self.type_at(src);
        let sp = unsafe (*self.cur_ast()).at_const(node).span;
        if sy.kind == TypeKind::TYPE_GENERIC {
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot erase a generic type parameter to 'dyn'"));
            return true;
        }
        if !self.type_satisfies(src, iface, 0) {
            return false;
        }
        let mut tmod: ModuleId = 0;
        let mut tdecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(
            src,
            (&mut tmod) as *mut ModuleId,
            (&mut tdecl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            if sy.kind == TypeKind::TYPE_BUILTIN && self.package != null && unsafe (*self.package).builtin_decl(
                sy.as_data.builtin,
            ) != NODE_NONE {
                tmod = unsafe (*self.package).core_module;
                tdecl = unsafe (*self.package).builtin_decl(sy.as_data.builtin);
            } else {
                return false;
            }
        }
        let ia = self.mod_ast(iface.module);
        let isrc = self.mod_src(iface.module);
        let items = unsafe (*ia).at_const(iface.node).as_data.interface_def.items;
        for i in 0..items.len {
            let mid = unsafe (*ia).list(items)[i as usize];
            if self.dyn_method(iface.module, mid) {
                let mn = unsafe (*ia).at_const(unsafe (*ia).at_const(mid).as_data.function.name).as_data.name.text;
                let mut nmb = Buf96 {};
                unsafe stdio::snprintf(
                    &mut nmb[0],
                    96,
                    "%.*s".ptr() as *const char,
                    (mn.end - mn.start) as i32,
                    src_at(isrc, mn.start),
                );
                if self.find_method_cstr(tmod, tdecl, diag::cstr(&nmb[0])).node != NODE_NONE {
                    continue;
                }
                let mut emod: ModuleId = 0;
                if unsafe (*ia).at_const(mid).as_data.function.body != NODE_NONE && self.find_extend_as(
                    tmod,
                    tdecl,
                    iface,
                    (&mut emod) as *mut ModuleId,
                ) != NODE_NONE {
                    continue;
                }
                let mut tn = Buf96 {};
                self.render_type(src, &mut tn[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "cannot erase '{}' to 'dyn': method '{}' has no emittable implementation",
                        diag::cstr(&tn[0]),
                        diag::cstr(&nmb[0]),
                    ),
                );
                self.errors.note(format("implement the method in an 'extend .. as ..' block or give it a default body"));
                return true;
            }
        }
        unsafe (*self.cur_ast()).add_dyn_use(node, src, dyn_ty);
        return true;
    }

    // Is the value at `node` assignable to a slot of type `expected`?
    fn compatible(self: &mut Self, expected: TypeId, node: NodeId) bool {
        let actual = unsafe (*self.cur_ast()).type_of(node);
        if actual == TYPE_NONE && expected != TYPE_NONE {
            // `null` types as TYPE_NONE; don't let the wildcard below accept it for value types
            // (str, structs, ints) -- it is only a pointer/reference/fn-pointer literal.
            let n = unsafe (*self.cur_ast()).at_const(node);
            if n.kind == NodeKind::NODE_LITERAL && n.as_data.literal.token_type == TokenType::Null {
                let ek = self.type_at(expected).kind;
                return ek == TypeKind::TYPE_POINTER || ek == TypeKind::TYPE_REFERENCE || ek == TypeKind::TYPE_FUNCTION;
            }
        }
        if expected == TYPE_NONE || expected == actual {
            return true;
        }
        if actual == TYPE_NONE {
            // An untyped expression: only lenient as error recovery. In an error-free compile an
            // untyped node reaching a compat check is a typechecker hole, not a wildcard match.
            return self.errors.errors.len() != 0;
        }
        let ex = *self.type_at(expected);
        let ac = *self.type_at(actual);
        if ac.kind == TypeKind::TYPE_NEVER {
            return true;
        }
        // A reference coalesces to its raw-pointer form (`&T` -> `*const T`, `&mut T` -> `*mut T`).
        // Normalizing it here lets the single pointer rule below apply transitively, so `&T` reaches
        // `*const void` via `*const T` (ref -> ptr -> void) with no special case.
        let mut acp = ac;
        if ac.kind == TypeKind::TYPE_REFERENCE && ex.kind == TypeKind::TYPE_POINTER {
            acp.kind = TypeKind::TYPE_POINTER;
            if acp.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                acp.qualifier = TypeQualifier::TYPE_QUAL_CONST as u8;
            }
        }
        if ex.kind == TypeKind::TYPE_REFERENCE && ac.kind == TypeKind::TYPE_REFERENCE && ex.as_data.elem == ac.as_data.elem && ex.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 && ac.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return true;
        }
        if ex.kind == TypeKind::TYPE_POINTER && acp.kind == TypeKind::TYPE_POINTER && (ex.as_data.elem == acp.as_data.elem || ex.as_data.elem == Ast::builtin(
            BuiltinType::BT_VOID,
        )) && (ex.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 || acp.qualifier != TypeQualifier::TYPE_QUAL_CONST as u8) {
            return true;
        }
        if ex.kind == TypeKind::TYPE_FUNCTION && ac.kind == TypeKind::TYPE_FUNCTION {
            return self.fn_compatible(expected, actual);
        }
        if ex.kind == TypeKind::TYPE_ARRAY && ac.kind == TypeKind::TYPE_ARRAY {
            if ex.as_data.arr.len != 0 && ac.as_data.arr.len != 0 && ex.as_data.arr.len != ac.as_data.arr.len {
                return false;
            }
            if ex.as_data.arr.elem == ac.as_data.arr.elem {
                return true;
            }
            let ee = self.type_at(ex.as_data.arr.elem).kind;
            let ae = self.type_at(ac.as_data.arr.elem).kind;
            return ee == TypeKind::TYPE_FUNCTION && ae == TypeKind::TYPE_FUNCTION && self.fn_compatible(
                ex.as_data.arr.elem,
                ac.as_data.arr.elem,
            );
        }
        if ac.kind == TypeKind::TYPE_ARRAY {
            let mut selem: TypeId = TYPE_NONE;
            let sk = self.slice_kind(expected, (&mut selem) as *mut TypeId);
            if sk != 0 && selem == ac.as_data.arr.elem && (sk == 1 || self.is_assignable(node)) {
                unsafe (*self.cur_ast()).set_type(node, expected);
                return true;
            }
        }
        if ex.kind == TypeKind::TYPE_DYN {
            let exsig = self.tc_dyn_fn_sig(&ex);
            let sp = unsafe (*self.cur_ast()).at_const(node).span;
            if ac.kind == TypeKind::TYPE_DYN {
                return self.tc_dyn_same(&ex, &ac) && (ex.qualifier == ac.qualifier || ex.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 && ac.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8);
            }
            if ex.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 && ac.kind == TypeKind::TYPE_REFERENCE {
                let rel = *self.type_at(ac.as_data.elem);
                if rel.kind == TypeKind::TYPE_DYN {
                    if rel.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 || !self.tc_dyn_same(&ex, &rel) {
                        return false;
                    }
                    unsafe (*self.cur_ast()).add_dyn_use(node, TYPE_NONE, expected);
                    return true;
                }
                if exsig != TYPE_NONE {
                    if rel.kind != TypeKind::TYPE_FUNCTION || !self.dynfn_sig_ok(exsig, ac.as_data.elem) {
                        return false;
                    }
                    unsafe (*self.cur_ast()).add_dyn_use(node, ac.as_data.elem, expected);
                    return true;
                }
                if ex.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 && ac.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    return false;
                }
                return self.dyn_coerce(node, ac.as_data.elem, expected);
            }
            if exsig != TYPE_NONE && ac.kind == TypeKind::TYPE_FUNCTION {
                if unsafe (*self.mod_ast(ac.module)).at_const(ac.as_data.decl).kind == NodeKind::NODE_FUNCTION_TYPE {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a runtime 'fn(..)' pointer cannot erase to 'dyn fn'; wrap it in a closure"),
                    );
                    return true;
                }
                if !self.dynfn_sig_ok(exsig, actual) {
                    return false;
                }
                if ex.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 && self.fn_is_capturing(actual) {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a capturing closure must be borrowed to view it as '&dyn fn': write '&f'"),
                    );
                    return true;
                }
                unsafe (*self.cur_ast()).add_dyn_use(node, actual, expected);
                return true;
            }
            if ex.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 && ac.kind == TypeKind::TYPE_INSTANCE && exsig == TYPE_NONE {
                let mut inner: TypeId = TYPE_NONE;
                let mut galloc = false;
                if self.tc_box_of(&ac, (&mut inner) as *mut TypeId, (&mut galloc) as *mut bool) {
                    if !galloc {
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("only a default-allocated 'Box<T>' can be erased to 'Box<dyn I>'"),
                        );
                        return true;
                    }
                    return self.dyn_coerce(node, inner, expected);
                }
            }
            return false;
        }
        if ex.kind == TypeKind::TYPE_BUILTIN && ac.kind == TypeKind::TYPE_BUILTIN && bt_widens(
            ac.as_data.builtin,
            ex.as_data.builtin,
        ) {
            return true;
        }
        let mut vid = node;
        let v0 = unsafe (*self.cur_ast()).at_const(node);
        if v0.kind == NodeKind::NODE_UNARY && v0.as_data.unary.op == TokenType::Minus {
            vid = v0.as_data.unary.operand;
        }
        let v = unsafe (*self.cur_ast()).at_const(vid);
        if v.kind != NodeKind::NODE_LITERAL {
            return false;
        }
        let et = *self.type_at(expected);
        let tt = v.as_data.literal.token_type;
        if tt == TokenType::IntegerLiteral {
            if self.tc_literal_pinned(vid) {
                return false;
            }
            if et.kind != TypeKind::TYPE_BUILTIN || !(bt_is_int(et.as_data.builtin) || bt_is_float(et.as_data.builtin) || bt_is_complex(
                et.as_data.builtin,
            )) {
                return false;
            }
            if bt_is_int(et.as_data.builtin) {
                let mut mag: u64 = 0;
                let neg = vid != node;
                let got = self.lit_mag(vid, (&mut mag) as *mut u64);
                if got && !tc_lit_in_range(et.as_data.builtin, mag, neg) {
                    let mut tn = Buf96 {};
                    self.render_type(expected, &mut tn[0], 96);
                    let vsp = unsafe (*self.cur_ast()).at_const(node).span;
                    self.errors.emit(
                        vsp.start,
                        vsp.end - vsp.start,
                        format("integer literal is out of range for '{}'", diag::cstr(&tn[0])),
                    );
                    return true;
                }
                if !neg {
                    unsafe (*self.cur_ast()).set_type(node, expected);
                }
            }
            return true;
        }
        if tt == TokenType::CharacterLiteral {
            return et.kind == TypeKind::TYPE_BUILTIN && bt_is_int(et.as_data.builtin);
        }
        if tt == TokenType::FloatLiteral {
            if self.tc_literal_pinned(vid) {
                return false;
            }
            return et.kind == TypeKind::TYPE_BUILTIN && (bt_is_float(et.as_data.builtin) || bt_is_complex(
                et.as_data.builtin,
            ));
        }
        if tt == TokenType::StringLiteral || tt == TokenType::RawStringLiteral {
            if et.kind != TypeKind::TYPE_POINTER || et.qualifier != TypeQualifier::TYPE_QUAL_CONST as u8 {
                return false;
            }
            let pe = self.type_at(et.as_data.elem);
            if pe.kind != TypeKind::TYPE_BUILTIN || pe.as_data.builtin != BuiltinType::BT_CHAR && pe.as_data.builtin != BuiltinType::BT_U8 {
                return false;
            }
            unsafe (*self.cur_ast()).set_type(node, expected);
            return true;
        }
        if tt == TokenType::Null {
            return et.kind == TypeKind::TYPE_POINTER || et.kind == TypeKind::TYPE_REFERENCE;
        }
        return false;
    }

    fn return_list_is_explicit_void(self: &mut Self, rets: NodeList) bool {
        if rets.len != 1 {
            return false;
        }
        let r0 = unsafe (*self.cur_ast()).list(rets)[0];
        let rn = unsafe (*self.cur_ast()).at_const(r0);
        let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
        return self.is_void_type(self.resolve_type(tn));
    }

    fn range_type(self: &mut Self, id: NodeId, start: TypeId, end: TypeId) TypeId {
        let n = unsafe (*self.cur_ast()).at_const(id).as_data.pattern_range;
        let has_start = n.start != NODE_NONE;
        let has_end = n.end != NODE_NONE;
        let start_ok = !has_start || start == TYPE_NONE || self.is_int(start);
        let end_ok = !has_end || end == TYPE_NONE || self.is_int(end);
        let sp = unsafe (*self.cur_ast()).at_const(id).span;
        if !start_ok || !end_ok {
            self.errors.emit(sp.start, sp.end - sp.start, format("range bounds must be integers"));
            return TYPE_NONE;
        }
        if !has_start {
            return end;
        }
        if !has_end {
            return start;
        }
        if start == TYPE_NONE {
            return end;
        }
        if end == TYPE_NONE || start == end {
            return start;
        }
        if self.is_integer_literal_node(n.start) && self.compatible(end, n.start) {
            return end;
        }
        if self.is_integer_literal_node(n.end) && self.compatible(start, n.end) {
            return start;
        }
        self.err_mismatch(n.end, start);
        return TYPE_NONE;
    }

    // ---- places / assignability ----
    fn tc_path_static_mut(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        let mut d = unsafe (*self.cur_ast()).resolution_def(id);
        if d.node == NODE_NONE {
            d = unsafe (*self.cur_ast()).resolution_def(n.as_data.member.member);
        }
        if d.node == NODE_NONE {
            return false;
        }
        let dn = unsafe (*self.mod_ast(d.module)).at_const(d.node);
        return dn.kind == NodeKind::NODE_CONST && dn.as_data.const_def.is_static_mut;
    }
    fn is_assignable(self: &mut Self, node_in: NodeId) bool {
        let node = self.peel_wrappers(node_in);
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(node).kind;
        if nk == NodeKind::NODE_IDENTIFIER {
            let dd = unsafe (*a).resolution_def(node);
            if dd.node != NODE_NONE && dd.module != self.ast.module {
                let fdn = unsafe (*self.mod_ast(dd.module)).at_const(dd.node);
                return fdn.kind == NodeKind::NODE_CONST && fdn.as_data.const_def.is_static_mut;
            }
            let d = unsafe (*a).resolution(node);
            if d == NODE_NONE {
                return false;
            }
            let dn = unsafe (*a).at_const(d);
            if dn.kind == NodeKind::NODE_CONST {
                return dn.as_data.const_def.is_static_mut;
            }
            if dn.kind == NodeKind::NODE_LET {
                return dn.as_data.let_stmt.is_mutable;
            }
            if dn.kind == NodeKind::NODE_PARAMETER {
                return dn.as_data.parameter.is_mutable;
            }
            if dn.kind == NodeKind::NODE_PATTERN_NAME {
                return unsafe (*a).at_const(dn.as_data.pattern.name).as_data.name.is_mutable;
            }
            if dn.kind == NodeKind::NODE_IDENTIFIER {
                let letn = unsafe (*a).resolution(d);
                return letn != NODE_NONE && unsafe (*a).at_const(letn).kind == NodeKind::NODE_LET && unsafe (*a).at_const(
                    letn,
                ).as_data.let_stmt.is_mutable;
            }
            return false;
        }
        if nk == NodeKind::NODE_UNARY {
            if unsafe (*a).at_const(node).as_data.unary.op != TokenType::Star {
                return false;
            }
            let ot = self.type_at(unsafe (*a).type_of(unsafe (*a).at_const(node).as_data.unary.operand));
            return (ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE) && ot.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
        }
        if nk == NodeKind::NODE_INDEX || nk == NodeKind::NODE_MEMBER {
            if nk == NodeKind::NODE_MEMBER && unsafe (*a).at_const(node).as_data.member.path {
                return self.tc_path_static_mut(node);
            }
            let obj = if_node(
                nk == NodeKind::NODE_INDEX,
                unsafe (*a).at_const(node).as_data.index.object,
                unsafe (*a).at_const(node).as_data.member.object,
            );
            let mut oty = unsafe (*a).type_of(obj);
            let mut via_ref = false;
            let mut ref_mut = false;
            if nk == NodeKind::NODE_INDEX {
                let mut y = *self.type_at(oty);
                while y.kind == TypeKind::TYPE_REFERENCE {
                    via_ref = true;
                    ref_mut = y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
                    oty = y.as_data.elem;
                    y = *self.type_at(oty);
                }
            }
            let mut sk: i32 = 0;
            if nk == NodeKind::NODE_INDEX {
                sk = self.slice_kind(oty, null);
            }
            if sk != 0 {
                return sk == 2;
            }
            let ot = *self.type_at(oty);
            if nk == NodeKind::NODE_INDEX && (ot.kind == TypeKind::TYPE_STRUCT || ot.kind == TypeKind::TYPE_INSTANCE) {
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                let mut gp = Defs8 {};
                let mut ga = Tys8 {};
                let mut gn: i32 = 0;
                if !self.aggregate_of(
                    oty,
                    (&mut om) as *mut ModuleId,
                    (&mut od) as *mut NodeId,
                    (&gp[0]) as *mut DefId,
                    (&ga[0]) as *mut TypeId,
                    (&mut gn) as *mut i32,
                ) {
                    return false;
                }
                let im = self.find_method_cstr(om, od, "index_mut");
                if im.node == NODE_NONE {
                    return false;
                }
                let ia = self.mod_ast(im.module);
                let irs = unsafe (*ia).at_const(im.node).as_data.function.returns;
                if irs.len != 1 {
                    return false;
                }
                let ir0 = unsafe (*ia).list(irs)[0];
                let irn = unsafe (*ia).at_const(ir0);
                let itn = if_node(irn.kind == NodeKind::NODE_PARAMETER, irn.as_data.parameter.ty, ir0);
                if itn == NODE_NONE || unsafe (*ia).at_const(itn).kind != NodeKind::NODE_REFERENCE_TYPE {
                    return false;
                }
                if via_ref {
                    return ref_mut;
                }
                return self.is_assignable(obj);
            }
            if ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE {
                return ot.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
            }
            return self.is_assignable(obj);
        }
        return false;
    }
    fn is_place(self: &Self, id: NodeId) bool {
        let node = self.peel_wrappers(id);
        let n = unsafe (*self.cur_ast()).at_const(node);
        if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_INDEX {
            return true;
        }
        if n.kind == NodeKind::NODE_MEMBER {
            return !n.as_data.member.path || self.tc_path_static_mut(node);
        }
        if n.kind == NodeKind::NODE_UNARY {
            return n.as_data.unary.op == TokenType::Star;
        }
        return false;
    }
    fn receiver_mutable(self: &mut Self, recv: NodeId) bool {
        let rt = unsafe (*self.cur_ast()).type_of(recv);
        if rt != TYPE_NONE {
            let rty = self.type_at(rt);
            if rty.kind == TypeKind::TYPE_POINTER || rty.kind == TypeKind::TYPE_REFERENCE {
                return rty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
            }
        }
        if self.is_place(recv) {
            return self.is_assignable(recv);
        }
        return true;
    }

    // ---- move / definite-init / free tracking ----
    fn tc_binding_depth(self: &Self, decl: NodeId) u32 {
        if decl == NODE_NONE || unsafe (*self.cur_ast()).at_const(decl).kind == NodeKind::NODE_PARAMETER {
            return 0;
        }
        switch self.binding_depth.get(&decl) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        return 0;
    }
    fn tc_record_binding_depth(self: &mut Self, decl: NodeId) void {
        if decl != NODE_NONE {
            self.binding_depth.insert(decl, self.scope_depth);
        }
    }

    fn tc_capture_move_guard(self: &mut Self, expr0: NodeId) bool {
        if self.nclos == 0 {
            return false;
        }
        let a = self.cur_ast();
        let mut expr = expr0;
        loop {
            let n = unsafe (*a).at_const(expr);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                expr = n.as_data.unary.operand;
            } else {
                break;
            }
        }
        if unsafe (*a).at_const(expr).kind != NodeKind::NODE_IDENTIFIER {
            return false;
        }
        let d = unsafe (*a).resolution_def(expr);
        if d.module != self.ast.module || d.node == NODE_NONE || self.tc_capture_index(
            self.clos_stack[(self.nclos - 1) as usize],
            d.node,
        ) < 0 || !self.tc_type_is_free(unsafe (*a).type_of(expr)) {
            return false;
        }
        let sp = unsafe (*a).at_const(expr).span;
        self.errors.emit(
            sp.start,
            sp.end - sp.start,
            format("cannot move a captured value out of a closure (the closure's env owns it)"),
        );
        return true;
    }

    // TC-5: moved[] membership bitset (bit index = decl NodeId). moved[] stays authoritative for
    // flow save/merge; the bits are updated at every mutation site so is_moved is O(1).
    fn ms_bit_set(self: &mut Self, d: NodeId) void {
        let idx = (d >> 6) as usize;
        while self.moved_bits.len() <= idx {
            self.moved_bits.push(0u64);
        }
        self.moved_bits.set(idx, self.moved_bits[idx] | 1u64 << (d & 63u32) as u64);
    }
    fn ms_bit_clear(self: &mut Self, d: NodeId) void {
        let idx = (d >> 6) as usize;
        if idx < self.moved_bits.len() {
            self.moved_bits.set(idx, self.moved_bits[idx] & ~(1u64 << (d & 63u32) as u64));
        }
    }
    fn is_moved(self: &Self, decl: NodeId) bool {
        let idx = (decl >> 6) as usize;
        if idx >= self.moved_bits.len() {
            return false;
        }
        return (self.moved_bits[idx] >> (decl & 63u32) as u64 & 1u64) != 0u64;
    }
    fn tc_mark_move(self: &mut Self, expr0: NodeId) void {
        if expr0 == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let mut expr = expr0;
        loop {
            let n = unsafe (*a).at_const(expr);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                expr = n.as_data.unary.operand;
            } else {
                break;
            }
        }
        if unsafe (*a).at_const(expr).kind != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let d = unsafe (*a).resolution_def(expr);
        if d.module != self.ast.module || d.node == NODE_NONE {
            return;
        }
        let dk = unsafe (*a).at_const(d.node).kind;
        if dk != NodeKind::NODE_LET && dk != NodeKind::NODE_PARAMETER || !self.tc_type_is_free(
            unsafe (*a).type_of(expr),
        ) {
            return;
        }
        // A reference-typed binding never owns its pointee: passing it borrows through it (an
        // implicit reborrow -- the same pointer `p` would produce), so the binding is not
        // consumed. Shared `&` is freely duplicable; `&mut` stays usable after the callee returns.
        let ek = self.type_at(unsafe (*a).type_of(expr)).kind;
        if ek == TypeKind::TYPE_REFERENCE || ek == TypeKind::TYPE_POINTER {
            return;
        }
        if self.tc_capture_move_guard(expr) {
            return;
        }
        for i in 0..self.nborrows {
            if self.borrows[i as usize].root == d.node && self.borrows[i as usize].kind == BORROW_SHARED {
                if self.borrow_dead_after(self.borrows[i as usize], expr) {
                    self.borrow_tombstone_at(i);
                } else {
                    let sp = unsafe (*a).at_const(expr).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("cannot move this value while it is borrowed"));
                    break;
                }
            }
        }
        if self.is_moved(d.node) {
            return;
        }
        if self.nmoved < 1024 {
            let k = self.nmoved;
            self.moved[k as usize] = d.node;
            self.nmoved = k + 1;
            self.ms_bit_set(d.node);
        } else {
            let sp = unsafe (*a).at_const(expr).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("too many moved values in one function (move-analysis limit)"),
            );
        }
    }

    fn tc_is_uninit(self: &Self, decl: NodeId) bool {
        for i in 0..self.nuninit {
            if self.uninit[i as usize] == decl {
                return true;
            }
        }
        return false;
    }
    fn tc_add_uninit(self: &mut Self, decl: NodeId) void {
        if self.tc_is_uninit(decl) {
            return;
        }
        if self.nuninit < 256 {
            let k = self.nuninit;
            self.uninit[k as usize] = decl;
            self.nuninit = k + 1;
        } else {
            let sp = unsafe (*self.cur_ast()).at_const(decl).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("too many uninitialized bindings in one function (definite-init analysis limit)"),
            );
        }
    }
    fn tc_init(self: &mut Self, decl: NodeId) void {
        let mut i: u32 = 0;
        while i < self.nuninit {
            if self.uninit[i as usize] == decl {
                self.nuninit = self.nuninit - 1;
                self.uninit[i as usize] = self.uninit[self.nuninit as usize];
                return;
            }
            i = i + 1;
        }
    }
    fn tc_unmark_move(self: &mut Self, decl: NodeId) void {
        let mut i: u32 = 0;
        while i < self.nmoved {
            if self.moved[i as usize] == decl {
                self.nmoved = self.nmoved - 1;
                self.moved[i as usize] = self.moved[self.nmoved as usize];
                break;
            }
            i = i + 1;
        }
        // moved[] can hold duplicates (closure captures push unguarded) -- only drop the bit once
        // no entry remains.
        let mut still = false;
        i = 0;
        while i < self.nmoved {
            if self.moved[i as usize] == decl {
                still = true;
                break;
            }
            i = i + 1;
        }
        if !still {
            self.ms_bit_clear(decl);
        }
        i = 0;
        while i < self.nfreed {
            if self.freed[i as usize] == decl {
                self.nfreed = self.nfreed - 1;
                self.freed[i as usize] = self.freed[self.nfreed as usize];
                break;
            }
            i = i + 1;
        }
    }

    // ---- flow state save/set/collect ----
    // TC-4b: save/clear fill an uninitialized caller local through an out-param and only touch the
    // counted prefixes -- a by-value `FlowState {}` zero-fills ~3KB twice per branch construct.
    fn tc_flow_save(self: &Self, s: &mut FlowState) void {
        s.nmoved = self.nmoved;
        for i in 0..self.nmoved {
            s.moved[i as usize] = self.moved[i as usize];
        }
        s.nuninit = self.nuninit;
        for i in 0..self.nuninit {
            s.uninit[i as usize] = self.uninit[i as usize];
        }
        s.nfreed = self.nfreed;
        for i in 0..self.nfreed {
            s.freed[i as usize] = self.freed[i as usize];
        }
        s.nborrows = self.nborrows;
        for i in 0..self.nborrows {
            s.borrows[i as usize] = self.borrows[i as usize];
        }
    }
    fn tc_flow_set(self: &mut Self, s: &FlowState) void {
        for i in 0..self.nmoved {
            self.ms_bit_clear(self.moved[i as usize]);
        }
        self.nmoved = s.nmoved;
        for i in 0..s.nmoved {
            self.moved[i as usize] = s.moved[i as usize];
            self.ms_bit_set(s.moved[i as usize]);
        }
        self.nuninit = s.nuninit;
        for i in 0..s.nuninit {
            self.uninit[i as usize] = s.uninit[i as usize];
        }
        self.nfreed = s.nfreed;
        for i in 0..s.nfreed {
            self.freed[i as usize] = s.freed[i as usize];
        }
        self.nborrows = s.nborrows;
        for i in 0..s.nborrows {
            self.borrows[i as usize] = s.borrows[i as usize];
        }
    }
    fn tc_flow_clear(self: &Self, s: &mut FlowState) void {
        s.nmoved = 0;
        s.nuninit = 0;
        s.nfreed = 0;
        s.nborrows = 0;
    }
    fn borrow_same(self: &Self, a: Borrow, b: Borrow) bool {
        return a.root == b.root && a.kind == b.kind && a.region == b.region && a.origin == b.origin;
    }
    fn tc_flow_collect(self: &Self, acc: *mut FlowState) bool {
        let mut overflow = false;
        for i in 0..self.nmoved {
            let mut seen = false;
            for j in 0..unsafe (*acc).nmoved {
                if unsafe (*acc).moved[j as usize] == self.moved[i as usize] {
                    seen = true;
                }
            }
            if !seen {
                if unsafe (*acc).nmoved < 256 {
                    let k = unsafe (*acc).nmoved;
                    unsafe (*acc).moved[k as usize] = self.moved[i as usize];
                    unsafe (*acc).nmoved = k + 1;
                } else {
                    overflow = true;
                }
            }
        }
        for i in 0..self.nuninit {
            let mut seen = false;
            for j in 0..unsafe (*acc).nuninit {
                if unsafe (*acc).uninit[j as usize] == self.uninit[i as usize] {
                    seen = true;
                }
            }
            if !seen {
                if unsafe (*acc).nuninit < 64 {
                    let k = unsafe (*acc).nuninit;
                    unsafe (*acc).uninit[k as usize] = self.uninit[i as usize];
                    unsafe (*acc).nuninit = k + 1;
                } else {
                    overflow = true;
                }
            }
        }
        for i in 0..self.nfreed {
            let mut seen = false;
            for j in 0..unsafe (*acc).nfreed {
                if unsafe (*acc).freed[j as usize] == self.freed[i as usize] {
                    seen = true;
                }
            }
            if !seen {
                if unsafe (*acc).nfreed < 64 {
                    let k = unsafe (*acc).nfreed;
                    unsafe (*acc).freed[k as usize] = self.freed[i as usize];
                    unsafe (*acc).nfreed = k + 1;
                } else {
                    overflow = true;
                }
            }
        }
        for i in 0..self.nborrows {
            let mut seen = false;
            for j in 0..unsafe (*acc).nborrows {
                if self.borrow_same(unsafe (*acc).borrows[j as usize], self.borrows[i as usize]) {
                    seen = true;
                }
            }
            if !seen {
                if unsafe (*acc).nborrows < 64 {
                    let k = unsafe (*acc).nborrows;
                    unsafe (*acc).borrows[k as usize] = self.borrows[i as usize];
                    unsafe (*acc).nborrows = k + 1;
                } else {
                    overflow = true;
                }
            }
        }
        return overflow;
    }
    fn tc_flow_overflow(self: &mut Self, at: NodeId) void {
        let sp = unsafe (*self.cur_ast()).at_const(at).span;
        self.errors.emit(
            sp.start,
            sp.end - sp.start,
            format("too many flow facts to merge across branches in one function (analysis limit)"),
        );
    }

    fn tc_stmt_returns(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return false;
        }
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_RETURN {
            return true;
        }
        if n.kind == NodeKind::NODE_BLOCK {
            let ss = n.as_data.block.statements;
            return ss.len != 0 && self.tc_stmt_returns(unsafe (*self.cur_ast()).list(ss)[(ss.len - 1) as usize]);
        }
        if n.kind == NodeKind::NODE_IF {
            return n.as_data.if_stmt.else_branch != NODE_NONE && self.tc_stmt_returns(n.as_data.if_stmt.then_branch) && self.tc_stmt_returns(
                n.as_data.if_stmt.else_branch,
            );
        }
        if n.kind == NodeKind::NODE_EXPRESSION_STATEMENT {
            let ty = unsafe (*self.cur_ast()).type_of(n.as_data.single.value);
            return ty != TYPE_NONE && self.type_at(ty).kind == TypeKind::TYPE_NEVER;
        }
        return false;
    }

    // ---- scope / borrow set ----
    fn tc_scope_enter(self: &mut Self) void {
        self.scope_depth = self.scope_depth + 1;
    }
    fn tc_scope_exit(self: &mut Self) void {
        let d = self.scope_depth;
        let mut w: u32 = 0;
        for i in 0..self.nborrows {
            let b = self.borrows[i as usize];
            if b.region as u32 >= d {
                continue;
            }
            if b.binding != NODE_NONE && b.root != NODE_NONE && self.tc_binding_depth(b.root) >= d {
                let sp = unsafe (*self.cur_ast()).at_const(b.origin).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
                    ),
                );
                continue;
            }
            self.borrows[w as usize] = self.borrows[i as usize];
            w = w + 1;
        }
        self.nborrows = w;
        if self.scope_depth != 0 {
            self.scope_depth = self.scope_depth - 1;
        }
    }

    fn place_index_const(self: &Self, idx: NodeId, out: *mut i64) bool {
        let n = unsafe (*self.cur_ast()).at_const(idx);
        if n.kind != NodeKind::NODE_LITERAL || n.as_data.literal.token_type != TokenType::IntegerLiteral {
            return false;
        }
        let lr = n.as_data.literal.raw;
        let mut p = unsafe (self.source.ptr() + lr.start as usize);
        let mut len = (lr.end - lr.start) as usize;
        let (base, skip) = lit_base_prefix(p, len);
        p = unsafe (p + skip);
        len = len - skip;
        let mut acc: u64 = 0;
        for i in 0..len {
            let ch = unsafe p[i];
            if ch == b'_' {
                continue;
            }
            let mut d: u64 = 0;
            if ch <= b'9' {
                d = (ch - b'0') as u64;
            } else {
                d = ((ch | 0x20u8) - b'a' + 10u8) as u64;
            }
            if d >= base || acc > (0x7FFFFFFFFFFFFFFFi64 - d as i64) as u64 / base {
                return false;
            }
            acc = acc * base + d;
        }
        unsafe *out = acc as i64;
        return true;
    }

    fn tc_type_is_union(self: &Self, ty: TypeId) bool {
        let mut m: ModuleId = 0;
        let mut d = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if ty == TYPE_NONE || !self.aggregate_of(
            ty,
            (&mut m) as *mut ModuleId,
            (&mut d) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            return false;
        }
        let dn = unsafe (*self.mod_ast(m)).at_const(d);
        return dn.kind == NodeKind::NODE_STRUCT && dn.as_data.aggregate.is_union;
    }

    // Decompose a place `&x.f[i]…` into its root binding + access steps (leaf-first).
    fn place_decompose(self: &mut Self, place0: NodeId, steps: *mut PStep, nsteps: *mut i32, cap: i32) NodeId {
        unsafe *nsteps = 0;
        let a = self.cur_ast();
        let mut place = place0;
        loop {
            let pn = unsafe (*a).at_const(place);
            if pn.kind == NodeKind::NODE_UNARY && (pn.as_data.unary.op == TokenType::Move || pn.as_data.unary.op == TokenType::Unsafe) {
                place = pn.as_data.unary.operand;
                continue;
            }
            if pn.kind == NodeKind::NODE_UNARY && pn.as_data.unary.op == TokenType::Star {
                let op = pn.as_data.unary.operand;
                let ot = unsafe (*a).type_of(op);
                if ot == TYPE_NONE || self.type_at(ot).kind != TypeKind::TYPE_REFERENCE {
                    return NODE_NONE;
                }
                if unsafe *nsteps < cap {
                    let k = unsafe *nsteps;
                    unsafe steps[k as usize] = PStep { kind: PS_DEREF };
                    unsafe *nsteps = k + 1;
                }
                place = op;
                continue;
            }
            let mut base = NODE_NONE;
            let mut step = PStep { kind: PS_FIELD };
            if pn.kind == NodeKind::NODE_MEMBER && !pn.as_data.member.path {
                base = pn.as_data.member.object;
                step.kind = PS_FIELD;
                step.name = self.name_span(pn.as_data.member.member);
            } else if pn.kind == NodeKind::NODE_INDEX {
                base = pn.as_data.index.object;
                step.kind = PS_INDEX;
                let mut v: i64 = 0;
                if self.place_index_const(pn.as_data.index.index, (&mut v) as *mut i64) {
                    step.index_const = true;
                    step.index_val = v;
                }
            } else {
                break;
            }
            let bt = unsafe (*a).type_of(base);
            if bt == TYPE_NONE {
                return NODE_NONE;
            }
            let btk = *self.type_at(bt);
            let mut union_ty = bt;
            if btk.kind == TypeKind::TYPE_REFERENCE {
                union_ty = btk.as_data.elem;
            }
            let base_union = pn.kind == NodeKind::NODE_MEMBER && self.tc_type_is_union(union_ty);
            if base_union {
                unsafe *nsteps = 0;
            }
            if btk.kind == TypeKind::TYPE_REFERENCE {
                if pn.kind == NodeKind::NODE_INDEX {
                    return NODE_NONE;
                }
                if !base_union && unsafe *nsteps < cap {
                    let k = unsafe *nsteps;
                    unsafe steps[k as usize] = step;
                    unsafe *nsteps = k + 1;
                }
                if unsafe *nsteps < cap {
                    let k = unsafe *nsteps;
                    unsafe steps[k as usize] = PStep { kind: PS_DEREF };
                    unsafe *nsteps = k + 1;
                }
                place = base;
                continue;
            }
            if btk.kind == TypeKind::TYPE_POINTER {
                return NODE_NONE;
            }
            if pn.kind == NodeKind::NODE_INDEX && btk.kind != TypeKind::TYPE_ARRAY {
                return NODE_NONE;
            }
            if !base_union && unsafe *nsteps < cap {
                let k = unsafe *nsteps;
                unsafe steps[k as usize] = step;
                unsafe *nsteps = k + 1;
            }
            place = base;
        }
        if unsafe (*a).at_const(place).kind != NodeKind::NODE_IDENTIFIER {
            return NODE_NONE;
        }
        let d = unsafe (*a).resolution_def(place);
        if d.node == NODE_NONE || d.module != self.ast.module {
            return NODE_NONE;
        }
        let dk = unsafe (*a).at_const(d.node).kind;
        if dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PATTERN_NAME || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_FOR {
            return d.node;
        }
        return NODE_NONE;
    }
    fn borrow_place_root(self: &mut Self, place: NodeId) NodeId {
        let mut steps = Steps16 {};
        let mut n: i32 = 0;
        return self.place_decompose(place, (&mut steps[0]) as *mut PStep, (&mut n) as *mut i32, PLACE_MAX_STEPS);
    }
    fn places_overlap(self: &mut Self, aN: NodeId, bN: NodeId) bool {
        let mut sa = Steps16 {};
        let mut sb = Steps16 {};
        let mut na: i32 = 0;
        let mut nb: i32 = 0;
        let ra = self.place_decompose(aN, (&mut sa[0]) as *mut PStep, (&mut na) as *mut i32, PLACE_MAX_STEPS);
        let rb = self.place_decompose(bN, (&mut sb[0]) as *mut PStep, (&mut nb) as *mut i32, PLACE_MAX_STEPS);
        if ra == NODE_NONE || rb == NODE_NONE || ra != rb {
            return false;
        }
        let mut common = na;
        if nb < na {
            common = nb;
        }
        for i in 0..common {
            let pa = sa[(na - 1 - i) as usize];
            let pb = sb[(nb - 1 - i) as usize];
            if pa.kind != pb.kind {
                return true;
            }
            if pa.kind == PS_FIELD {
                let la = pa.name.end - pa.name.start;
                let lb = pb.name.end - pb.name.start;
                if la != lb || unsafe cstring::memcmp(
                    self.source.ptr() + pa.name.start as usize,
                    self.source.ptr() + pb.name.start as usize,
                    la as usize,
                ) != 0 {
                    return false;
                }
            } else if pa.kind == PS_INDEX && pa.index_const && pb.index_const && pa.index_val != pb.index_val {
                return false;
            }
        }
        return true;
    }

    fn place_through_binding(self: &Self, place0: NodeId) NodeId {
        let a = self.cur_ast();
        let mut place = place0;
        loop {
            let pn = unsafe (*a).at_const(place);
            let mut base = NODE_NONE;
            if pn.kind == NodeKind::NODE_UNARY && pn.as_data.unary.op == TokenType::Star {
                base = pn.as_data.unary.operand;
            } else if pn.kind == NodeKind::NODE_MEMBER && !pn.as_data.member.path {
                base = pn.as_data.member.object;
            } else if pn.kind == NodeKind::NODE_INDEX {
                base = pn.as_data.index.object;
            } else {
                return NODE_NONE;
            }
            let bt = unsafe (*a).type_of(base);
            let mut is_ref = false;
            if bt != TYPE_NONE && self.type_at(bt).kind == TypeKind::TYPE_REFERENCE {
                is_ref = true;
            }
            if (pn.kind == NodeKind::NODE_UNARY || is_ref) && unsafe (*a).at_const(base).kind == NodeKind::NODE_IDENTIFIER {
                let d = unsafe (*a).resolution_def(base);
                if d.node != NODE_NONE && d.module == self.ast.module {
                    return d.node;
                }
                return NODE_NONE;
            }
            place = base;
        }
    }

    fn borrow_mark(self: &Self) u32 {
        return self.nborrows;
    }
    fn borrow_release_to(self: &mut Self, mark: u32) void {
        if self.nborrows <= mark {
            return;
        }
        let mut w = mark;
        let mut i = mark;
        while i < self.nborrows {
            if self.borrows[i as usize].binding != NODE_NONE {
                self.borrows[w as usize] = self.borrows[i as usize];
                w = w + 1;
            }
            i = i + 1;
        }
        self.nborrows = w;
    }
    fn borrow_tombstone_at(self: &mut Self, i: u32) void {
        self.borrows[i as usize].root = NODE_NONE;
        self.borrows[i as usize].binding = NODE_NONE;
    }

    // TC-3: one pass over the resolution table records, per local decl, the LAST node that
    // resolves to it. "any use after `after`" then collapses to one compare. Typechecker-added
    // resolutions never target a value binding except break/continue -> loop node (a `for` node IS
    // its loop binding), which tc_note_resolution folds in at the set site.
    fn tc_build_last_use(self: &mut Self) void {
        self.last_use_built = true;
        let n = unsafe (*self.cur_ast()).nodes.len();
        self.last_use.clear();
        let mut i: usize = 0;
        while i < n {
            self.last_use.push(NODE_NONE);
            i = i + 1;
        }
        let mut nid: NodeId = 0;
        while nid as usize < n {
            let rd = unsafe (*self.cur_ast()).resolution_def(nid);
            if rd.node != NODE_NONE && rd.module == self.ast.module && rd.node as usize < n {
                self.last_use.set(rd.node as usize, nid);
            }
            nid = nid + 1;
        }
    }
    fn tc_note_resolution(self: &mut Self, ref_id: NodeId, decl: NodeId) void {
        if self.last_use_built && decl as usize < self.last_use.len() && ref_id > self.last_use[decl as usize] {
            self.last_use.set(decl as usize, ref_id);
        }
    }

    fn borrow_dead_after(self: &mut Self, b: Borrow, after: NodeId) bool {
        if b.binding == NODE_NONE || self.loop_depth != 0 {
            return false;
        }
        let bn = unsafe (*self.cur_ast()).at_const(b.binding);
        if bn.kind == NodeKind::NODE_LET && unsafe (*self.cur_ast()).at_const(bn.as_data.let_stmt.name).kind == NodeKind::NODE_PATTERN_TUPLE {
            return false;
        }
        for i in 0..self.nborrows {
            if self.borrows[i as usize].binding != b.binding && self.place_through_binding(
                self.borrows[i as usize].place,
            ) == b.binding {
                return false;
            }
        }
        if !self.last_use_built {
            self.tc_build_last_use();
        }
        if b.binding as usize < self.last_use.len() && self.last_use[b.binding as usize] > after {
            return false;
        }
        return true;
    }

    fn borrow_report_conflict(self: &mut Self, place: NodeId, kind: u8, origin: NodeId) bool {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return false;
        }
        for i in 0..self.nborrows {
            let b = self.borrows[i as usize];
            if b.root != root || kind == BORROW_SHARED && b.kind == BORROW_SHARED || !self.places_overlap(
                place,
                b.place,
            ) {
                continue;
            }
            if self.borrow_dead_after(b, origin) {
                self.borrow_tombstone_at(i);
                continue;
            }
            let sp = unsafe (*self.cur_ast()).at_const(origin).span;
            let mut k1 = "immutable".ptr() as *const char;
            if kind == BORROW_MUT {
                k1 = "mutable".ptr() as *const char;
            }
            let mut k2 = "immutable".ptr() as *const char;
            if b.kind == BORROW_MUT {
                k2 = "mutable".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format(
                    "cannot borrow this value as {} while it is already borrowed as {}",
                    diag::cstr(k1),
                    diag::cstr(k2),
                ),
            );
            self.errors.note(
                format(
                    "a value may have many '&' borrows or a single '&mut', not both; the earlier borrow must end first",
                ),
            );
            return true;
        }
        return false;
    }
    fn borrow_push(self: &mut Self, root: NodeId, kind: u8, place: NodeId, origin: NodeId) void {
        if self.nborrows < 256 {
            let k = self.nborrows;
            self.borrows[k as usize] = Borrow {
                root: root,
                place: place,
                kind: kind,
                region: self.scope_depth as u16,
                origin: origin,
                binding: NODE_NONE,
            };
            self.nborrows = k + 1;
        } else {
            let sp = unsafe (*self.cur_ast()).at_const(origin).span;
            self.errors.emit(
                sp.start,
                1,
                format("too many simultaneous borrows in one function (borrow-checker limit)"),
            );
        }
    }
    fn borrow_create(self: &mut Self, place: NodeId, kind: u8, origin: NodeId) void {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return;
        }
        if !self.borrow_report_conflict(place, kind, origin) {
            self.borrow_push(root, kind, place, origin);
        }
    }
    fn borrow_conflicting_read(self: &mut Self, place: NodeId) bool {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return false;
        }
        for i in 0..self.nborrows {
            let b = self.borrows[i as usize];
            if b.root != root || b.kind != BORROW_MUT || !self.places_overlap(place, b.place) {
                continue;
            }
            if self.borrow_dead_after(b, place) {
                self.borrow_tombstone_at(i);
                continue;
            }
            return true;
        }
        return false;
    }
    fn borrow_conflicting_write(self: &mut Self, place: NodeId, after: NodeId) bool {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return false;
        }
        for i in 0..self.nborrows {
            let b = self.borrows[i as usize];
            if b.root != root || b.kind != BORROW_SHARED || b.binding == NODE_NONE || !self.places_overlap(
                place,
                b.place,
            ) {
                continue;
            }
            if self.borrow_dead_after(b, after) {
                self.borrow_tombstone_at(i);
                continue;
            }
            return true;
        }
        return false;
    }
    fn borrow_transfer_ref(self: &mut Self, init: NodeId, binding: NodeId) void {
        let a = self.cur_ast();
        let mut e = init;
        loop {
            let n = unsafe (*a).at_const(e);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                e = n.as_data.unary.operand;
            } else {
                break;
            }
        }
        if unsafe (*a).at_const(e).kind != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let rd = unsafe (*a).resolution_def(e);
        if rd.node == NODE_NONE || rd.module != self.ast.module {
            return;
        }
        let n0 = self.nborrows;
        let region = self.tc_binding_depth(binding) as u16;
        let mut moved = false;
        for i in 0..n0 {
            if self.borrows[i as usize].binding == rd.node {
                if self.borrows[i as usize].kind == BORROW_MUT {
                    self.borrows[i as usize].binding = binding;
                    self.borrows[i as usize].region = region;
                    moved = true;
                } else if self.nborrows < 256 {
                    let k = self.nborrows;
                    self.borrows[k as usize] = self.borrows[i as usize];
                    self.borrows[k as usize].region = region;
                    self.borrows[k as usize].binding = binding;
                    self.nborrows = k + 1;
                }
            }
        }
        if moved && !self.is_moved(rd.node) && self.nmoved < 1024 {
            let k = self.nmoved;
            self.moved[k as usize] = rd.node;
            self.nmoved = k + 1;
            self.ms_bit_set(rd.node);
        }
    }
    fn tuple_binds_reference(self: &Self, name: NodeId) bool {
        let a = self.cur_ast();
        let names = unsafe (*a).at_const(name).as_data.pattern.children;
        for i in 0..names.len {
            let nid = unsafe (*a).list(names)[i as usize];
            let et = unsafe (*a).type_of(nid);
            if et != TYPE_NONE && self.type_at(et).kind == TypeKind::TYPE_REFERENCE {
                return true;
            }
        }
        return false;
    }
    fn borrow_nll_drop(self: &mut Self, block_id: NodeId, ids: *const NodeId, si: u32) void {
        let mut keep = Keep256 {};
        for k in 0..self.nborrows {
            keep[k as usize] = true;
            let b = self.borrows[k as usize];
            if b.binding != NODE_NONE && b.region == self.scope_depth as u16 {
                let bn = unsafe (*self.cur_ast()).at_const(b.binding);
                let tuple = bn.kind == NodeKind::NODE_LET && unsafe (*self.cur_ast()).at_const(bn.as_data.let_stmt.name).kind == NodeKind::NODE_PATTERN_TUPLE;
                if !tuple {
                    keep[k as usize] = false;
                    let mut nid = unsafe ids[si as usize] + 1;
                    while nid < block_id && !keep[k as usize] {
                        let rd = unsafe (*self.cur_ast()).resolution_def(nid);
                        keep[k as usize] = rd.node == b.binding && rd.module == self.ast.module;
                        nid = nid + 1;
                    }
                }
            }
        }
        let mut kk = self.nborrows as i32 - 1;
        while kk >= 0 {
            if keep[kk as usize] {
                let thru = self.place_through_binding(self.borrows[kk as usize].place);
                if thru != NODE_NONE {
                    for j in 0..self.nborrows {
                        if self.borrows[j as usize].binding == thru {
                            keep[j as usize] = true;
                        }
                    }
                }
            }
            kk = kk - 1;
        }
        let mut w: u32 = 0;
        for k in 0..self.nborrows {
            if keep[k as usize] {
                self.borrows[w as usize] = self.borrows[k as usize];
                w = w + 1;
            }
        }
        self.nborrows = w;
    }

    // ---- escape analysis ----
    fn place_escape(self: &mut Self, place: NodeId, depth: u32) i32 {
        let mut steps = Steps16 {};
        let mut ns: i32 = 0;
        let root = self.place_decompose(place, (&mut steps[0]) as *mut PStep, (&mut ns) as *mut i32, PLACE_MAX_STEPS);
        if root == NODE_NONE {
            return 0;
        }
        let mut thru = false;
        for i in 0..ns {
            if steps[i as usize].kind == PS_DEREF {
                thru = true;
            }
        }
        if thru {
            if unsafe (*self.cur_ast()).at_const(root).kind == NodeKind::NODE_PARAMETER {
                return 0;
            }
            return self.borrow_escape_of_binding(root, depth + 1);
        }
        if unsafe (*self.cur_ast()).at_const(root).kind == NodeKind::NODE_PARAMETER {
            return 2;
        }
        return 1;
    }
    fn borrow_escape_of_binding(self: &mut Self, binding: NodeId, depth: u32) i32 {
        if depth > 8 {
            return 0;
        }
        let mut esc: i32 = 0;
        for i in 0..self.nborrows {
            if self.borrows[i as usize].binding == binding {
                let e = self.place_escape(self.borrows[i as usize].place, depth);
                if e == 1 {
                    return 1;
                }
                if e != 0 {
                    esc = e;
                }
            }
        }
        return esc;
    }
    fn addr_escape_at(self: &mut Self, e0: NodeId, depth: u32) i32 {
        let a = self.cur_ast();
        let mut e = e0;
        loop {
            let n = unsafe (*a).at_const(e);
            if n.kind == NodeKind::NODE_CAST {
                e = n.as_data.cast.expression;
            } else if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                e = n.as_data.unary.operand;
            } else {
                break;
            }
        }
        let n = unsafe (*a).at_const(e);
        if n.kind == NodeKind::NODE_UNARY && n.as_data.unary.op == TokenType::Ampersand {
            return self.place_escape(n.as_data.unary.operand, depth);
        }
        if n.kind == NodeKind::NODE_IDENTIFIER && depth < BORROW_ESCAPE_MAX_DEPTH {
            let d = unsafe (*a).resolution_def(e);
            if d.module == self.ast.module && d.node != NODE_NONE {
                let dn = unsafe (*a).at_const(d.node);
                let dt = unsafe (*a).type_of(d.node);
                if dt != TYPE_NONE && self.type_at(dt).kind == TypeKind::TYPE_REFERENCE {
                    return self.borrow_escape_of_binding(d.node, depth);
                }
                if dn.kind == NodeKind::NODE_LET && dn.as_data.let_stmt.value != NODE_NONE {
                    return self.addr_escape_at(dn.as_data.let_stmt.value, depth + 1);
                }
            }
        }
        return 0;
    }
    fn addr_escape(self: &mut Self, e: NodeId) i32 {
        return self.addr_escape_at(e, 0);
    }

    // ---- extend conformance ----
    fn find_extend_item_named(self: &Self, extnode: NodeId, name: tok::Span, nmod: ModuleId) NodeId {
        let a = self.cur_ast();
        let have = unsafe (*a).at_const(extnode).as_data.extend_def.items;
        for j in 0..have.len {
            let hid = unsafe (*a).list(have)[j as usize];
            let hm = unsafe (*a).at_const(hid);
            if hm.kind == NodeKind::NODE_FUNCTION && spans_eq2(
                self.mod_src(nmod),
                name,
                self.source,
                unsafe (*a).at_const(hm.as_data.function.name).as_data.name.text,
            ) {
                return hid;
            }
        }
        return NODE_NONE;
    }
    fn extend_method_signature_matches(
        self: &mut Self,
        req: DefId,
        have: NodeId,
        subp: *const DefId,
        suba: *const TypeId,
        nsub: i32,
    ) bool {
        let ra = self.mod_ast(req.module);
        let rf = unsafe (*ra).at_const(req.node).as_data.function;
        let hf = unsafe (*self.cur_ast()).at_const(have).as_data.function;
        if rf.params.len != hf.params.len {
            return false;
        }
        for i in 0..rf.params.len {
            let rp = unsafe (*ra).list(rf.params)[i as usize];
            let hp = unsafe (*self.cur_ast()).list(hf.params)[i as usize];
            let mut rt = self.lower_type_in(req.module, unsafe (*ra).at_const(rp).as_data.parameter.ty);
            rt = self.subst_type(rt, subp, suba, nsub);
            let ht = self.lower_type_in(self.ast.module, unsafe (*self.cur_ast()).at_const(hp).as_data.parameter.ty);
            if rt != ht && (i != 0 || !self.receiver_type_eq(rt, ht)) {
                return false;
            }
        }
        if rf.returns.len != hf.returns.len {
            if rf.returns.len > 1 || hf.returns.len > 1 {
                return false;
            }
            let mut rt: TypeId = TYPE_NONE;
            let mut ht: TypeId = TYPE_NONE;
            if rf.returns.len == 1 {
                let rr = unsafe (*ra).list(rf.returns)[0];
                let rn = unsafe (*ra).at_const(rr);
                rt = self.lower_type_in(
                    req.module,
                    if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rr),
                );
                rt = self.subst_type(rt, subp, suba, nsub);
            }
            if hf.returns.len == 1 {
                let hr = unsafe (*self.cur_ast()).list(hf.returns)[0];
                let hn = unsafe (*self.cur_ast()).at_const(hr);
                ht = self.lower_type_in(
                    self.ast.module,
                    if_node(hn.kind == NodeKind::NODE_PARAMETER, hn.as_data.parameter.ty, hr),
                );
            }
            return self.ret_eq(rt, ht);
        }
        for k in 0..rf.returns.len {
            let rr = unsafe (*ra).list(rf.returns)[k as usize];
            let hr = unsafe (*self.cur_ast()).list(hf.returns)[k as usize];
            let rn = unsafe (*ra).at_const(rr);
            let hn = unsafe (*self.cur_ast()).at_const(hr);
            let mut rt = self.lower_type_in(
                req.module,
                if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, rr),
            );
            rt = self.subst_type(rt, subp, suba, nsub);
            let ht = self.lower_type_in(
                self.ast.module,
                if_node(hn.kind == NodeKind::NODE_PARAMETER, hn.as_data.parameter.ty, hr),
            );
            if !self.ret_eq(rt, ht) {
                return false;
            }
        }
        return true;
    }
    fn check_interface_requirements(
        self: &mut Self,
        extnode: NodeId,
        iface: DefId,
        self_ty: TypeId,
        subp: *const DefId,
        suba: *const TypeId,
        nsub: i32,
        depth: i32,
    ) void {
        if iface.node == NODE_NONE || depth > 8 {
            return;
        }
        let ia = self.mod_ast(iface.module);
        if unsafe (*ia).at_const(iface.node).kind != NodeKind::NODE_INTERFACE {
            return;
        }
        let req = unsafe (*ia).at_const(iface.node).as_data.interface_def.items;
        for i in 0..req.len {
            let rid = unsafe (*ia).list(req)[i as usize];
            let rm = unsafe (*ia).at_const(rid);
            if rm.kind == NodeKind::NODE_FUNCTION && rm.as_data.function.body == NODE_NONE {
                let rn = unsafe (*ia).at_const(rm.as_data.function.name).as_data.name.text;
                let hm = self.find_extend_item_named(extnode, rn, iface.module);
                let reqdef = DefId { module: iface.module, node: rid };
                if hm == NODE_NONE {
                    let at = unsafe (*self.cur_ast()).at_const(
                        unsafe (*self.cur_ast()).at_const(extnode).as_data.extend_def.interface_type,
                    ).span;
                    self.errors.emit(
                        at.start,
                        at.end - at.start,
                        format(
                            "missing method '{}' required by this interface",
                            diag::span_str(self.mod_src(iface.module), rn.start, rn.end),
                        ),
                    );
                } else if !self.extend_method_signature_matches(reqdef, hm, subp, suba, nsub) {
                    let at = unsafe (*self.cur_ast()).at_const(hm).span;
                    self.errors.emit(
                        at.start,
                        at.end - at.start,
                        format(
                            "method '{}' does not match interface signature",
                            diag::span_str(self.mod_src(iface.module), rn.start, rn.end),
                        ),
                    );
                }
            }
        }
        let bounds = unsafe (*ia).at_const(iface.node).as_data.interface_def.bounds;
        for i in 0..bounds.len {
            let sb = unsafe (*ia).resolution_def(unsafe (*ia).list(bounds)[i as usize]);
            if sb.node != NODE_NONE && !self.type_satisfies(self_ty, sb, 0) {
                let at = unsafe (*self.cur_ast()).at_const(
                    unsafe (*self.cur_ast()).at_const(extnode).as_data.extend_def.interface_type,
                ).span;
                self.errors.emit(at.start, at.end - at.start, format("type does not satisfy required superinterface"));
            }
        }
    }
    fn check_extend_conformance(self: &mut Self, id: NodeId) void {
        let iface = unsafe (*self.cur_ast()).resolution_def(
            unsafe (*self.cur_ast()).at_const(id).as_data.extend_def.interface_type,
        );
        if iface.node == NODE_NONE {
            return;
        }
        let target = unsafe (*self.cur_ast()).at_const(id).as_data.extend_def.target_type;
        let self_ty = self.resolve_type(target);
        let mut subp = Defs8 {};
        let mut suba = Tys8 {};
        let mut nsub: i32 = 0;
        subp[0] = DefId { module: iface.module, node: iface.node };
        suba[0] = self_ty;
        nsub = 1;
        let ia = self.mod_ast(iface.module);
        let itype = unsafe (*self.cur_ast()).at_const(id).as_data.extend_def.interface_type;
        if unsafe (*ia).at_const(iface.node).kind == NodeKind::NODE_INTERFACE && unsafe (*self.cur_ast()).at_const(
            itype,
        ).kind == NodeKind::NODE_TYPE_PATH {
            let gens = unsafe (*ia).at_const(iface.node).as_data.interface_def.generics;
            let targs = unsafe (*self.cur_ast()).at_const(itype).as_data.type_path.args;
            let mut i: u32 = 0;
            while i < gens.len && i < targs.len && nsub < 8 {
                let gid = unsafe (*ia).list(gens)[i as usize];
                subp[nsub as usize] = DefId { module: iface.module, node: gid };
                suba[nsub as usize] = self.resolve_type(unsafe (*self.cur_ast()).list(targs)[i as usize]);
                nsub = nsub + 1;
                i = i + 1;
            }
        }
        self.check_interface_requirements(
            id,
            iface,
            self_ty,
            (&subp[0]) as *const DefId,
            (&suba[0]) as *const TypeId,
            nsub,
            0,
        );
    }

    // ---- operators ----
    fn method_recv_subst(self: &mut Self, recv: TypeId, md: DefId, rsubp: *mut DefId, rsuba: *mut TypeId) i32 {
        let mut nrsub: i32 = 0;
        let mut rmod: ModuleId = 0;
        let mut rdecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut sn: i32 = 0;
        let agok = self.aggregate_of(
            self.strip(recv),
            (&mut rmod) as *mut ModuleId,
            (&mut rdecl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut sn) as *mut i32,
        );
        if agok && sn > 0 {
            let extnode = self.enclosing_extend(md.module, md.node);
            if extnode != NODE_NONE {
                let ma = self.mod_ast(md.module);
                let ig = unsafe (*ma).at_const(extnode).as_data.extend_def.generics;
                let mut g = ig.len as i32;
                if sn < g {
                    g = sn;
                }
                let mut i: i32 = 0;
                while i < g && nrsub < 8 {
                    let gid = unsafe (*ma).list(ig)[i as usize];
                    unsafe rsubp[nrsub as usize] = DefId { module: md.module, node: gid };
                    unsafe rsuba[nrsub as usize] = ga[i as usize];
                    nrsub = nrsub + 1;
                    i = i + 1;
                }
            }
        }
        return nrsub;
    }
    fn tc_method_ret(self: &mut Self, recv: TypeId, md: DefId) TypeId {
        let fa = self.mod_ast(md.module);
        let fnn = unsafe (*fa).at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.returns.len != 1 {
            return TYPE_NONE;
        }
        let mut rsubp = Defs8 {};
        let mut rsuba = Tys8 {};
        let nrsub = self.method_recv_subst(recv, md, (&mut rsubp[0]) as *mut DefId, (&mut rsuba[0]) as *mut TypeId);
        let r0 = unsafe (*fa).list(fnn.as_data.function.returns)[0];
        let rn = unsafe (*fa).at_const(r0);
        let ret = self.lower_type_in(
            md.module,
            if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
        );
        return self.subst_type(ret, (&rsubp[0]) as *const DefId, (&rsuba[0]) as *const TypeId, nrsub);
    }
    fn tc_method_param(self: &mut Self, recv: TypeId, md: DefId, idx: i32) TypeId {
        let fa = self.mod_ast(md.module);
        let fnn = unsafe (*fa).at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.params.len as i32 <= idx {
            return TYPE_NONE;
        }
        let mut rsubp = Defs8 {};
        let mut rsuba = Tys8 {};
        let nrsub = self.method_recv_subst(recv, md, (&mut rsubp[0]) as *mut DefId, (&mut rsuba[0]) as *mut TypeId);
        let p = unsafe (*fa).list(fnn.as_data.function.params)[idx as usize];
        let pn = unsafe (*fa).at_const(p);
        let pt = self.lower_type_in(md.module, if_node(pn.kind == NodeKind::NODE_PARAMETER, pn.as_data.parameter.ty, p));
        return self.subst_type(pt, (&rsubp[0]) as *const DefId, (&rsuba[0]) as *const TypeId, nrsub);
    }
    fn method_self_kind(self: &mut Self, md: DefId) i32 {
        let fa = self.mod_ast(md.module);
        let fnn = unsafe (*fa).at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.params.len == 0 {
            return 0;
        }
        let pt = self.decl_type_in(md.module, unsafe (*fa).list(fnn.as_data.function.params)[0]);
        let y = self.type_at(pt);
        if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
            return 0;
        }
        if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return 2;
        }
        return 1;
    }
    fn operand_fits_param(self: &mut Self, pt: TypeId, operand: NodeId) bool {
        if pt == TYPE_NONE || self.compatible(pt, operand) {
            return true;
        }
        let p = *self.type_at(pt);
        return p.kind == TypeKind::TYPE_REFERENCE && self.compatible(p.as_data.elem, operand);
    }
}

fn arith_method_name(op: TokenType) str {
    if op == TokenType::Plus {
        return "add";
    }
    if op == TokenType::Minus {
        return "sub";
    }
    if op == TokenType::Star {
        return "mul";
    }
    if op == TokenType::Slash {
        return "div";
    }
    if op == TokenType::Percent {
        return "rem";
    }
    return "";
}

extend TypeChecker {
    fn check_unary(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let op = unsafe (*a).at_const(id).as_data.unary.op;
        let operand = unsafe (*a).at_const(id).as_data.unary.operand;
        let qual = unsafe (*a).at_const(id).as_data.unary.qualifier;
        if op == TokenType::Ampersand {
            self.addr_ctx = true;
        }
        let outer_unsafe_used = self.unsafe_used;
        if op == TokenType::Unsafe {
            self.unsafe_depth = self.unsafe_depth + 1;
            self.unsafe_used = 0;
        }
        let bm = self.borrow_mark();
        let opnd = self.check_expr(operand);
        if op == TokenType::Unsafe {
            self.unsafe_depth = self.unsafe_depth - 1;
            if self.lint && self.unsafe_used == 0 {
                let usp = unsafe (*a).at_const(id).span;
                self.errors.warn(usp.start, 6, format("unnecessary 'unsafe': nothing inside requires it"));
                // Prefix form only: a bare block is not an expression, so `unsafe { .. }` keeps its marker.
                // Delete just the keyword + trailing blanks -- the operand span excludes dropped grouping
                // parens, so deleting up to it would swallow a '(' (`unsafe (a + 1)`).
                if unsafe (*a).at_const(operand).kind != NodeKind::NODE_BLOCK {
                    let mut fe = usp.start + 6;
                    while fe as usize < self.source.len() && (self.source[fe as usize] == b' ' || self.source[fe as usize] == b'\t') {
                        fe = fe + 1;
                    }
                    self.errors.fix(usp.start, fe, 0);
                }
            }
            self.unsafe_used = outer_unsafe_used;
        }
        let sp = unsafe (*a).at_const(id).span;
        if op == TokenType::Minus {
            if opnd != TYPE_NONE && !self.is_numeric(opnd) {
                self.errors.emit(sp.start, sp.end - sp.start, format("unary '-' requires a numeric operand"));
            }
            return opnd;
        }
        if op == TokenType::Bang {
            if opnd != TYPE_NONE && !self.is_bool(opnd) {
                self.errors.emit(sp.start, sp.end - sp.start, format("unary '!' requires a 'bool' operand"));
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if op == TokenType::Tilde {
            if opnd != TYPE_NONE && !self.is_int(opnd) {
                self.errors.emit(sp.start, sp.end - sp.start, format("unary '~' requires an integer operand"));
            }
            return opnd;
        }
        if op == TokenType::Star {
            if opnd == TYPE_NONE {
                return TYPE_NONE;
            }
            let ot = *self.type_at(opnd);
            if ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE {
                if ot.kind == TypeKind::TYPE_POINTER && self.tc_needs_unsafe() {
                    self.err_unsafe(sp, "dereferencing a raw pointer");
                }
                if !self.is_place(operand) {
                    let mut i = bm;
                    while i < self.nborrows {
                        if self.borrows[i as usize].binding == NODE_NONE && self.borrows[i as usize].kind == BORROW_SHARED {
                            self.borrow_tombstone_at(i);
                        }
                        i = i + 1;
                    }
                }
                return ot.as_data.elem;
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot dereference a non-pointer"));
            return TYPE_NONE;
        }
        if op == TokenType::Ampersand {
            let mut2 = qual == TypeQualifier::TYPE_QUAL_MUT;
            if mut2 && self.is_place(operand) && !self.is_assignable(operand) {
                let osp = unsafe (*a).at_const(operand).span;
                self.errors.emit(
                    osp.start,
                    osp.end - osp.start,
                    format("cannot take '&mut' of an immutable binding (bind it with 'mut')"),
                );
            }
            if mut2 {
                self.tc_mark_capture_mut(operand);
            }
            let mut opw = operand;
            loop {
                let onn = unsafe (*a).at_const(opw);
                if onn.kind == NodeKind::NODE_UNARY && (onn.as_data.unary.op == TokenType::Move || onn.as_data.unary.op == TokenType::Unsafe) {
                    opw = onn.as_data.unary.operand;
                } else {
                    break;
                }
            }
            let onk = unsafe (*a).at_const(opw).kind;
            if mut2 && onk == NodeKind::NODE_IDENTIFIER {
                let od = unsafe (*a).resolution_def(opw);
                if od.module == self.ast.module && od.node != NODE_NONE {
                    self.tc_init(od.node);
                }
            }
            if !self.is_place(opw) && opnd != TYPE_NONE && self.type_at(opnd).kind != TypeKind::TYPE_BUILTIN && (onk == NodeKind::NODE_CALL || onk == NodeKind::NODE_IF || onk == NodeKind::NODE_MATCH || onk == NodeKind::NODE_BLOCK || onk == NodeKind::NODE_BINARY || onk == NodeKind::NODE_ASSIGNMENT || onk == NodeKind::NODE_CAST) {
                let osp = unsafe (*a).at_const(opw).span;
                self.errors.emit(
                    osp.start,
                    osp.end - osp.start,
                    format("cannot take the address of a temporary value; bind it to a 'let' first"),
                );
            }
            let mut bk = BORROW_SHARED;
            if mut2 {
                bk = BORROW_MUT;
            }
            self.borrow_create(operand, bk, id);
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_REFERENCE, qualifier: qual as u8, as_data: TyAs { elem: opnd } },
            );
        }
        if op == TokenType::Question {
            if opnd == TYPE_NONE {
                return TYPE_NONE;
            }
            let os = self.strip(opnd);
            let mut oa = Tys8 {};
            let mut fa = Tys8 {};
            let nopt = self.prelude_instance_args_hit(os, self.ph_option, (&mut oa[0]) as *mut TypeId, 2);
            let mut nres: i32 = -1;
            if nopt < 0 {
                nres = self.prelude_instance_args_hit(os, self.ph_result, (&mut oa[0]) as *mut TypeId, 2);
            }
            if nopt < 0 && nres < 0 {
                self.errors.emit(sp.start, sp.end - sp.start, format("'?' requires an Option or Result operand"));
                self.errors.note(format("the operand must be an Option<T> or Result<T, E> value"));
                return TYPE_NONE;
            }
            let mut fnret: TypeId = TYPE_NONE;
            if self.current_returns.len == 1 {
                let r0 = unsafe (*self.cur_ast()).list(self.current_returns)[0];
                let rnn = unsafe (*self.cur_ast()).at_const(r0);
                fnret = self.resolve_type(if_node(rnn.kind == NodeKind::NODE_PARAMETER, rnn.as_data.parameter.ty, r0));
            }
            let mut frs = TYPE_NONE;
            if fnret != TYPE_NONE {
                frs = self.strip(fnret);
            }
            if nopt >= 0 {
                if self.prelude_instance_args_hit(frs, self.ph_option, (&mut fa[0]) as *mut TypeId, 2) < 0 {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("'?' on an Option requires the function to return an Option"),
                    );
                    self.errors.note(format("change the function return type or handle None explicitly"));
                }
                return oa[0];
            }
            if self.prelude_instance_args_hit(frs, self.ph_result, (&mut fa[0]) as *mut TypeId, 2) < 0 {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'?' on a Result requires the function to return a Result"),
                );
                self.errors.note(format("the function must return Result<_, E> with the same error type"));
            } else if oa[1] != fa[1] {
                let conv = self.tc_find_from_for(fa[1], oa[1]);
                if conv.node != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(id, conv);
                } else {
                    let mut a1 = Buf96 {};
                    let mut a2 = Buf96 {};
                    self.render_type(oa[1], &mut a1[0], 96);
                    self.render_type(fa[1], &mut a2[0], 96);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "'?' error type '{}' does not match the function's error type '{}'",
                            diag::cstr(&a1[0]),
                            diag::cstr(&a2[0]),
                        ),
                    );
                }
            }
            return oa[0];
        }
        return opnd;
    }

    fn binary_numeric(self: &mut Self, id: NodeId, l: TypeId, ln: NodeId, r: TypeId, rn: NodeId, require_int: bool) TypeId {
        if l == TYPE_NONE || r == TYPE_NONE {
            return TYPE_NONE;
        }
        let sp = unsafe (*self.cur_ast()).at_const(id).span;
        let mut ok = self.is_numeric(l) && self.is_numeric(r);
        if require_int {
            ok = self.is_int(l) && self.is_int(r);
        }
        if !ok {
            let mut w = "numeric".ptr() as *const char;
            if require_int {
                w = "integer".ptr() as *const char;
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("operator requires {} operands", diag::cstr(w)));
            return TYPE_NONE;
        }
        if l == r {
            return l;
        }
        if unsafe (*self.cur_ast()).at_const(ln).kind == NodeKind::NODE_LITERAL && !self.tc_literal_pinned(ln) {
            if self.is_int(r) {
                let mut mag: u64 = 0;
                let got = self.lit_mag(ln, (&mut mag) as *mut u64);
                let rb = self.type_at(r).as_data.builtin;
                if got && !tc_lit_in_range(rb, mag, false) {
                    let mut tn = Buf96 {};
                    self.render_type(r, &mut tn[0], 96);
                    let lsp = unsafe (*self.cur_ast()).at_const(ln).span;
                    self.errors.emit(
                        lsp.start,
                        lsp.end - lsp.start,
                        format("integer literal is out of range for '{}'", diag::cstr(&tn[0])),
                    );
                } else {
                    unsafe (*self.cur_ast()).set_type(ln, r);
                }
            }
            return r;
        }
        if unsafe (*self.cur_ast()).at_const(rn).kind == NodeKind::NODE_LITERAL && !self.tc_literal_pinned(rn) {
            if self.is_int(l) {
                let mut mag: u64 = 0;
                let got = self.lit_mag(rn, (&mut mag) as *mut u64);
                let lb = self.type_at(l).as_data.builtin;
                if got && !tc_lit_in_range(lb, mag, false) {
                    let mut tn = Buf96 {};
                    self.render_type(l, &mut tn[0], 96);
                    let rsp = unsafe (*self.cur_ast()).at_const(rn).span;
                    self.errors.emit(
                        rsp.start,
                        rsp.end - rsp.start,
                        format("integer literal is out of range for '{}'", diag::cstr(&tn[0])),
                    );
                } else {
                    unsafe (*self.cur_ast()).set_type(rn, l);
                }
            }
            return l;
        }
        if bt_widens(self.bt_of(l), self.bt_of(r)) {
            return r;
        }
        if bt_widens(self.bt_of(r), self.bt_of(l)) {
            return l;
        }
        self.err_mismatch(rn, l);
        return l;
    }

    fn check_ptr_arith(self: &mut Self, id: NodeId, l: TypeId, r: TypeId, handled: *mut bool) TypeId {
        unsafe *handled = false;
        if l == TYPE_NONE || r == TYPE_NONE {
            return TYPE_NONE;
        }
        let lp = self.type_at(l).kind == TypeKind::TYPE_POINTER;
        let rp = self.type_at(r).kind == TypeKind::TYPE_POINTER;
        if !lp && !rp {
            return TYPE_NONE;
        }
        unsafe *handled = true;
        let sp = unsafe (*self.cur_ast()).at_const(id).span;
        if self.tc_needs_unsafe() {
            self.err_unsafe(sp, "raw pointer arithmetic");
        }
        let minus = unsafe (*self.cur_ast()).at_const(id).as_data.binary.op == TokenType::Minus;
        if lp && rp {
            if minus && l == r {
                return Ast::builtin(BuiltinType::BT_ISIZE);
            }
            self.errors.emit(sp.start, sp.end - sp.start, format("invalid pointer arithmetic"));
            return TYPE_NONE;
        }
        if lp && self.is_int(r) {
            return l;
        }
        if rp && !minus && self.is_int(l) {
            return r;
        }
        self.errors.emit(sp.start, sp.end - sp.start, format("pointer arithmetic requires an integer offset"));
        return TYPE_NONE;
    }

    fn check_arith_overload(self: &mut Self, id: NodeId, l: TypeId, out: *mut TypeId) bool {
        let op = unsafe (*self.cur_ast()).at_const(id).as_data.binary.op;
        let m = arith_method_name(op);
        if m.len() == 0 {
            return false;
        }
        let mut ls = l;
        while ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_REFERENCE {
            ls = self.type_at(ls).as_data.elem;
        }
        if ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_POINTER {
            return false;
        }
        if ls == TYPE_NONE {
            return false;
        }
        let lt = *self.type_at(ls);
        let right = unsafe (*self.cur_ast()).at_const(id).as_data.binary.right;
        if lt.kind == TypeKind::TYPE_GENERIC {
            if !self.tc_param_bound_provides(lt.module, lt.as_data.decl, m) {
                let sp = unsafe (*self.cur_ast()).at_const(id).span;
                let mut ty = Buf96 {};
                self.render_type(ls, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "type parameter '{}' has no '{}' method for this operator (add a bound that provides it)",
                        diag::cstr(&ty[0]),
                        m,
                    ),
                );
                unsafe *out = TYPE_NONE;
            }
            return true;
        }
        if lt.kind != TypeKind::TYPE_STRUCT && lt.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        unsafe *out = ls;
        if self.aggregate_of(
            ls,
            (&mut om) as *mut ModuleId,
            (&mut od) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            let md = self.find_method_cstr(om, od, m);
            if md.node == NODE_NONE {
                let sp = unsafe (*self.cur_ast()).at_const(id).span;
                let mut ty = Buf96 {};
                self.render_type(ls, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'{}' has no '{}' method for this operator", diag::cstr(&ty[0]), m),
                );
                unsafe *out = TYPE_NONE;
            } else {
                if !self.method_extend_bounds_hold(ls, md) {
                    let sp = unsafe (*self.cur_ast()).at_const(id).span;
                    self.err_method_extend_bounds(sp, ls, md);
                    unsafe *out = TYPE_NONE;
                    return true;
                }
                let p1 = self.tc_method_param(ls, md, 1);
                if !self.operand_fits_param(p1, right) {
                    self.err_mismatch(right, p1);
                }
                let ret = self.tc_method_ret(ls, md);
                if ret != TYPE_NONE {
                    unsafe *out = ret;
                }
            }
        }
        return true;
    }

    fn check_binary(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let bd = unsafe (*a).at_const(id).as_data.binary;
        let ln = bd.left;
        let rn = bd.right;
        let op = bd.op;
        let l = self.check_expr(ln);
        let r = self.check_expr(rn);
        let sp = unsafe (*a).at_const(id).span;
        if op == TokenType::Plus || op == TokenType::Minus {
            let mut ov: TypeId = TYPE_NONE;
            if self.check_arith_overload(id, l, (&mut ov) as *mut TypeId) {
                return ov;
            }
            let mut handled = false;
            let pt = self.check_ptr_arith(id, l, r, (&mut handled) as *mut bool);
            if handled {
                return pt;
            }
            return self.binary_numeric(id, l, ln, r, rn, false);
        }
        if op == TokenType::Star || op == TokenType::Slash || op == TokenType::Percent {
            let mut ov: TypeId = TYPE_NONE;
            if self.check_arith_overload(id, l, (&mut ov) as *mut TypeId) {
                return ov;
            }
            return self.binary_numeric(id, l, ln, r, rn, false);
        }
        if op == TokenType::Ampersand || op == TokenType::Pipe || op == TokenType::Caret || op == TokenType::LeftShift || op == TokenType::RightShift {
            return self.binary_numeric(id, l, ln, r, rn, true);
        }
        if op == TokenType::AmpersandAmpersand || op == TokenType::PipePipe {
            if l != TYPE_NONE && !self.is_bool(l) || r != TYPE_NONE && !self.is_bool(r) {
                self.errors.emit(sp.start, sp.end - sp.start, format("logical operator requires 'bool' operands"));
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        // comparisons
        let ord = op == TokenType::LessThan || op == TokenType::LessThanEqual || op == TokenType::GreaterThan || op == TokenType::GreaterThanEqual;
        // `null == value` mirror of the null-operand check in the struct-eq branch below.
        let lnn = unsafe (*self.cur_ast()).at_const(ln);
        if lnn.kind == NodeKind::NODE_LITERAL && lnn.as_data.literal.token_type == TokenType::Null && r != TYPE_NONE {
            let mut rs = r;
            while self.type_at(rs).kind == TypeKind::TYPE_REFERENCE {
                rs = self.type_at(rs).as_data.elem;
            }
            let rk = self.type_at(rs).kind;
            if rk == TypeKind::TYPE_STRUCT || rk == TypeKind::TYPE_INSTANCE {
                let mut ty = Buf96 {};
                self.render_type(rs, &mut ty[0], 96);
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("cannot compare '{}' with 'null' (it is a value, not a pointer)", diag::cstr(&ty[0])),
                );
                return Ast::builtin(BuiltinType::BT_BOOL);
            }
        }
        let mut ls = l;
        while ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_REFERENCE {
            ls = self.type_at(ls).as_data.elem;
        }
        if ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_POINTER {
            if l != TYPE_NONE && r != TYPE_NONE && l != r && !self.compatible(l, rn) && !self.compatible(r, ln) {
                self.err_mismatch(rn, l);
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if ls != TYPE_NONE && (self.type_at(ls).kind == TypeKind::TYPE_STRUCT || self.type_at(ls).kind == TypeKind::TYPE_INSTANCE) {
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            if self.aggregate_of(
                ls,
                (&mut om) as *mut ModuleId,
                (&mut od) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            ) {
                let mut mm = "eq";
                if ord {
                    mm = "cmp";
                }
                let rnn = unsafe (*self.cur_ast()).at_const(rn);
                if rnn.kind == NodeKind::NODE_LITERAL && rnn.as_data.literal.token_type == TokenType::Null {
                    let mut ty = Buf96 {};
                    self.render_type(ls, &mut ty[0], 96);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot compare '{}' with 'null' (it is a value, not a pointer)", diag::cstr(&ty[0])),
                    );
                    return Ast::builtin(BuiltinType::BT_BOOL);
                }
                let md = self.find_method_cstr(om, od, mm);
                if md.node == NODE_NONE {
                    let mut ty = Buf96 {};
                    self.render_type(ls, &mut ty[0], 96);
                    let mut iface = "Eq".ptr() as *const char;
                    if ord {
                        iface = "Ord".ptr() as *const char;
                    }
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "'{}' has no '{}' method for this operator (implement {})",
                            diag::cstr(&ty[0]),
                            mm,
                            diag::cstr(iface),
                        ),
                    );
                    self.errors.note(format("operator overloads are resolved through interface-style methods"));
                } else if !self.method_extend_bounds_hold(ls, md) {
                    self.err_method_extend_bounds(sp, ls, md);
                } else {
                    let p1 = self.tc_method_param(ls, md, 1);
                    if !self.operand_fits_param(p1, rn) {
                        self.err_mismatch(rn, p1);
                    }
                }
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if ls != TYPE_NONE && self.type_at(ls).kind == TypeKind::TYPE_GENERIC {
            let gy = *self.type_at(ls);
            let mut mm = "eq";
            if ord {
                mm = "cmp";
            }
            if !self.tc_param_bound_provides(gy.module, gy.as_data.decl, mm) {
                let mut iface = "Eq".ptr() as *const char;
                if ord {
                    iface = "Ord".ptr() as *const char;
                }
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format(
                        "type parameter has no '{}' method for this operator (add a `{}` bound)",
                        mm,
                        diag::cstr(iface),
                    ),
                );
            }
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if l != TYPE_NONE && r != TYPE_NONE && l != r && !self.compatible(l, rn) && !self.compatible(r, ln) {
            self.err_mismatch(rn, l);
        }
        return Ast::builtin(BuiltinType::BT_BOOL);
    }

    fn check_variant_call(self: &mut Self, id: NodeId, vmod: ModuleId, variant: NodeId, enum_ty: TypeId) TypeId {
        let a = self.cur_ast();
        let args = unsafe (*a).at_const(id).as_data.call.args;
        for i in 0..args.len {
            self.check_expr(unsafe (*a).list(args)[i as usize]);
        }
        let va = self.mod_ast(vmod);
        let payload = unsafe (*va).at_const(variant).as_data.variant.payload;
        let sp = unsafe (*a).at_const(id).span;
        let mut amod: ModuleId = 0;
        let mut adecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        let inst = self.aggregate_of(
            enum_ty,
            (&mut amod) as *mut ModuleId,
            (&mut adecl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        );
        if args.len != payload.len {
            let mut s2 = "s".ptr() as *const char;
            if payload.len == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("variant expects {} argument{}, found {}", payload.len, diag::cstr(s2), args.len),
            );
        } else {
            for k in 0..args.len {
                let pid = unsafe (*va).list(payload)[k as usize];
                let pe = unsafe (*va).at_const(pid);
                let raw = self.lower_type_in(vmod, if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, pid));
                let mut pt = raw;
                if inst {
                    pt = self.subst_type(raw, (&gp[0]) as *const DefId, (&ga[0]) as *const TypeId, gn);
                }
                let aid = unsafe (*a).list(args)[k as usize];
                if !self.compatible(pt, aid) {
                    self.err_mismatch(aid, pt);
                }
            }
        }
        return enum_ty;
    }

    fn tc_is_iface_assoc_call(self: &Self, e: NodeId) bool {
        let a = self.cur_ast();
        let en = unsafe (*a).at_const(e);
        if en.kind != NodeKind::NODE_CALL {
            return false;
        }
        let cn = unsafe (*a).at_const(en.as_data.call.callee);
        if cn.kind != NodeKind::NODE_MEMBER || !cn.as_data.member.path {
            return false;
        }
        let ob = unsafe (*a).resolution_def(cn.as_data.member.object);
        return ob.node != NODE_NONE && (ob.module == self.ast.module || self.package != null && ob.module as usize < self.pkg_count()) && unsafe (*self.mod_ast(
            ob.module,
        )).at_const(ob.node).kind == NodeKind::NODE_INTERFACE;
    }

    fn tc_param_expected(self: &mut Self, callee: TypeId, callee_node: NodeId, argi: u32) TypeId {
        if callee == TYPE_NONE {
            return TYPE_NONE;
        }
        let ct = *self.type_at(callee);
        if ct.kind != TypeKind::TYPE_FUNCTION {
            return TYPE_NONE;
        }
        let fa = self.mod_ast(ct.module);
        let fnn = unsafe (*fa).at_const(ct.as_data.decl);
        if fnn.kind != NodeKind::NODE_FUNCTION {
            return TYPE_NONE;
        }
        let cnn = unsafe (*self.cur_ast()).at_const(callee_node);
        let mut skip: u32 = 0;
        if cnn.kind == NodeKind::NODE_MEMBER && !cnn.as_data.member.path && fnn.as_data.function.params.len > 0 {
            let md = unsafe (*self.cur_ast()).resolution_def(cnn.as_data.member.member);
            if md.node != NODE_NONE && unsafe (*self.mod_ast(md.module)).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                skip = 1;
            }
        }
        if argi + skip >= fnn.as_data.function.params.len {
            return TYPE_NONE;
        }
        let mut pt = self.decl_type_in(
            ct.module,
            unsafe (*fa).list(fnn.as_data.function.params)[(argi + skip) as usize],
        );
        if pt != TYPE_NONE && self.type_at(pt).kind == TypeKind::TYPE_GENERIC {
            let g = *self.type_at(pt);
            let fb = self.generic_fn_bound(g.module, g.as_data.decl);
            if fb != NODE_NONE {
                pt = self.lower_type_in(ct.module, fb);
            }
        }
        if pt != TYPE_NONE && !unsafe (*self.cur_ast()).type_concrete(pt) && skip != 0 {
            let md = unsafe (*self.cur_ast()).resolution_def(cnn.as_data.member.member);
            let mut extnode = NODE_NONE;
            if md.node != NODE_NONE {
                extnode = self.enclosing_extend(md.module, md.node);
            }
            let mut rm: ModuleId = 0;
            let mut rd = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agok = extnode != NODE_NONE && self.aggregate_of(
                self.strip(unsafe (*self.cur_ast()).type_of(cnn.as_data.member.object)),
                (&mut rm) as *mut ModuleId,
                (&mut rd) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            );
            if agok && gn > 0 {
                let ma = self.mod_ast(md.module);
                let ig = unsafe (*ma).at_const(extnode).as_data.extend_def.generics;
                let mut sp2 = Defs8 {};
                let mut sa = Tys8 {};
                let mut ns: i32 = 0;
                let mut i: u32 = 0;
                while i < ig.len && i as i32 < gn && ns < 8 {
                    let gid = unsafe (*ma).list(ig)[i as usize];
                    sp2[ns as usize] = DefId { module: md.module, node: gid };
                    sa[ns as usize] = ga[i as usize];
                    ns = ns + 1;
                    i = i + 1;
                }
                pt = self.subst_type(pt, (&sp2[0]) as *const DefId, (&sa[0]) as *const TypeId, ns);
            }
        }
        if pt != TYPE_NONE && unsafe (*self.cur_ast()).type_concrete(pt) {
            return pt;
        }
        return TYPE_NONE;
    }

    fn iter_elem_type(self: &mut Self, it: TypeId) TypeId {
        let mut im: ModuleId = 0;
        let mut idl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(
            it,
            (&mut im) as *mut ModuleId,
            (&mut idl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            return TYPE_NONE;
        }
        let nx = self.find_method_cstr(im, idl, "next");
        if nx.node == NODE_NONE {
            return TYPE_NONE;
        }
        let na = self.mod_ast(nx.module);
        let rets = unsafe (*na).at_const(nx.node).as_data.function.returns;
        if rets.len != 1 {
            return TYPE_NONE;
        }
        let r0 = unsafe (*na).list(rets)[0];
        let rn = unsafe (*na).at_const(r0);
        let mut ret = self.lower_type_in(
            nx.module,
            if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
        );
        let extnode = self.enclosing_extend(nx.module, nx.node);
        if extnode != NODE_NONE && gn > 0 {
            let ig = unsafe (*na).at_const(extnode).as_data.extend_def.generics;
            let mut ip = Defs8 {};
            let mut ia = Tys8 {};
            let mut in2: i32 = 0;
            let mut i: u32 = 0;
            while i < ig.len && i as i32 < gn && in2 < 8 {
                let gid = unsafe (*na).list(ig)[i as usize];
                ip[in2 as usize] = DefId { module: nx.module, node: gid };
                ia[in2 as usize] = ga[i as usize];
                in2 = in2 + 1;
                i = i + 1;
            }
            ret = self.subst_type(ret, (&ip[0]) as *const DefId, (&ia[0]) as *const TypeId, in2);
        }
        let rt = self.type_at(ret);
        if rt.kind == TypeKind::TYPE_INSTANCE {
            let oi = *unsafe (*self.cur_ast()).instance(rt.as_data.inst);
            if oi.n >= 1 {
                return oi.args[0];
            }
        }
        return TYPE_NONE;
    }

    fn tc_check_assert(self: &mut Self, id: NodeId, kind: i32) TypeId {
        let a = self.cur_ast();
        let args = unsafe (*a).at_const(id).as_data.call.args;
        let sp = unsafe (*a).at_const(id).span;
        if kind == 1 {
            if args.len < 1 || args.len > 2 {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("'assert' takes a condition and an optional str message"),
                );
                for i in 0..args.len {
                    self.check_expr(unsafe (*a).list(args)[i as usize]);
                }
                return Ast::builtin(BuiltinType::BT_VOID);
            }
            let ct = self.check_expr(unsafe (*a).list(args)[0]);
            if ct != TYPE_NONE && !self.is_bool(ct) {
                self.errors.emit(sp.start, sp.end - sp.start, format("'assert' condition must be 'bool'"));
            }
            if args.len == 2 {
                let mt = self.check_expr(unsafe (*a).list(args)[1]);
                if mt != TYPE_NONE && self.strip(mt) != self.prelude_str_type() {
                    self.errors.emit(sp.start, sp.end - sp.start, format("'assert' message must be a 'str'"));
                }
            }
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        let mut nm = "assert_eq".ptr() as *const char;
        if kind == 3 {
            nm = "assert_ne".ptr() as *const char;
        }
        if args.len != 2 {
            self.errors.emit(sp.start, sp.end - sp.start, format("'{}' takes exactly two arguments", diag::cstr(nm)));
            for i in 0..args.len {
                self.check_expr(unsafe (*a).list(args)[i as usize]);
            }
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        let lt = self.check_expr(unsafe (*a).list(args)[0]);
        self.expected = lt;
        let rt = self.check_expr(unsafe (*a).list(args)[1]);
        if lt == TYPE_NONE || rt == TYPE_NONE {
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        if lt != rt && !self.compatible(lt, unsafe (*a).list(args)[1]) && !self.compatible(
            rt,
            unsafe (*a).list(args)[0],
        ) {
            self.err_mismatch(unsafe (*a).list(args)[1], lt);
        }
        let base = self.strip(lt);
        let y = *self.type_at(base);
        let mut comparable = y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin != BuiltinType::BT_VOID && y.as_data.builtin != BuiltinType::BT_VALIST;
        if base == self.prelude_str_type() {
            comparable = true;
        }
        if !comparable && (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE || y.kind == TypeKind::TYPE_ENUM) {
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            if self.aggregate_of(
                base,
                (&mut om) as *mut ModuleId,
                (&mut od) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            ) {
                comparable = self.find_method_cstr(om, od, "eq").node != NODE_NONE;
                if !comparable && self.is_plain_enum(base) {
                    comparable = true;
                }
                if comparable {
                    self.find_method_cstr(om, od, "as_str");
                }
            }
        }
        if !comparable {
            let mut ty = Buf96 {};
            self.render_type(lt, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("'{}' cannot compare values of type '{}'", diag::cstr(nm), diag::cstr(&ty[0])),
            );
            self.errors.note(format("implement 'Eq' (an 'eq' method) for the type, or compare a field/element instead"));
        }
        return Ast::builtin(BuiltinType::BT_VOID);
    }

    fn infer_from_bounds(
        self: &mut Self,
        fmod: ModuleId,
        fdecl: NodeId,
        gids: *const NodeId,
        gparams: *const DefId,
        bound: *mut TypeId,
        g: i32,
    ) void {
        let fa = self.mod_ast(fmod);
        for pass in 0..2 {
            for i in 0..g {
                if unsafe bound[i as usize] != TYPE_NONE {
                    let mut bs = BoundArr8 {};
                    let mut nb: i32 = 0;
                    self.add_bound_ifaces_full(
                        fmod,
                        unsafe (*fa).at_const(unsafe gids[i as usize]).as_data.generic_param.bounds,
                        (&mut bs[0]) as *mut BoundIface,
                        (&mut nb) as *mut i32,
                        8,
                    );
                    let wc = unsafe (*fa).at_const(fdecl).as_data.function.where_clause;
                    for w in 0..wc.len {
                        let wid = unsafe (*fa).list(wc)[w as usize];
                        let wp = unsafe (*fa).at_const(wid).as_data.where_predicate;
                        if unsafe (*fa).resolution(wp.ty) == unsafe gids[i as usize] {
                            self.add_bound_ifaces_full(
                                fmod,
                                wp.bounds,
                                (&mut bs[0]) as *mut BoundIface,
                                (&mut nb) as *mut i32,
                                8,
                            );
                        }
                    }
                    for b in 0..nb {
                        if bs[b as usize].n != 0 {
                            let mut tm: ModuleId = 0;
                            let mut td = NODE_NONE;
                            let mut sp = Defs8 {};
                            let mut sa = Tys8 {};
                            let mut sn: i32 = 0;
                            if self.aggregate_of(
                                self.strip(unsafe bound[i as usize]),
                                (&mut tm) as *mut ModuleId,
                                (&mut td) as *mut NodeId,
                                (&sp[0]) as *mut DefId,
                                (&sa[0]) as *mut TypeId,
                                (&mut sn) as *mut i32,
                            ) {
                                let mut imod: ModuleId = 0;
                                let extn = self.find_extend_as(
                                    tm,
                                    td,
                                    bs[b as usize].iface,
                                    (&mut imod) as *mut ModuleId,
                                );
                                if extn != NODE_NONE {
                                    let ia = self.mod_ast(imod);
                                    let egids = unsafe (*ia).at_const(extn).as_data.extend_def.generics;
                                    let mut egp = Defs8 {};
                                    let mut ega = Tys8 {};
                                    let mut egn: i32 = 0;
                                    let mut k: u32 = 0;
                                    while k < egids.len && k as i32 < sn && egn < 8 {
                                        let xg = unsafe (*ia).list(egids)[k as usize];
                                        egp[egn as usize] = DefId { module: imod, node: xg };
                                        ega[egn as usize] = sa[k as usize];
                                        egn = egn + 1;
                                        k = k + 1;
                                    }
                                    let itf = unsafe (*ia).at_const(
                                        unsafe (*ia).at_const(extn).as_data.extend_def.interface_type,
                                    );
                                    if itf.kind == NodeKind::NODE_TYPE_PATH {
                                        let iargs = itf.as_data.type_path.args;
                                        let mut kk: u32 = 0;
                                        while kk < iargs.len && kk < bs[b as usize].n as u32 {
                                            let lowered = self.lower_type_in(
                                                imod,
                                                unsafe (*ia).list(iargs)[kk as usize],
                                            );
                                            let subst = self.subst_type(
                                                lowered,
                                                (&egp[0]) as *const DefId,
                                                (&ega[0]) as *const TypeId,
                                                egn,
                                            );
                                            self.unify_infer(bs[b as usize].args[kk as usize], subst, gparams, bound, g);
                                            kk = kk + 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn fn_compatible_subst(
        self: &mut Self,
        exid: TypeId,
        acid: TypeId,
        gp: *const DefId,
        ga: *const TypeId,
        gn: i32,
        rp: *const DefId,
        ra: *const TypeId,
        rn: i32,
    ) bool {
        if exid != acid && self.fn_owns(acid) {
            let exy = *self.type_at(exid);
            let exn = unsafe (*self.mod_ast(exy.module)).at_const(exy.as_data.decl);
            if exn.kind != NodeKind::NODE_FUNCTION_TYPE || !exn.as_data.function_type.is_move {
                return false;
            }
        }
        let mut ep = Tys8 {};
        let mut ap = Tys8 {};
        let mut er: TypeId = TYPE_NONE;
        let mut ar: TypeId = TYPE_NONE;
        let en = self.fn_sig(exid, (&mut ep[0]) as *mut TypeId, 4, (&mut er) as *mut TypeId);
        let an = self.fn_sig(acid, (&mut ap[0]) as *mut TypeId, 4, (&mut ar) as *mut TypeId);
        if en != an || en > 4 {
            return false;
        }
        let er2 = self.subst_type(self.subst_type(er, gp, ga, gn), rp, ra, rn);
        if !self.ret_eq(er2, ar) {
            return false;
        }
        for i in 0..en {
            let ep2 = self.subst_type(self.subst_type(ep[i as usize], gp, ga, gn), rp, ra, rn);
            if ep2 != ap[i as usize] {
                return false;
            }
        }
        return true;
    }

    fn check_field_visibility(self: &mut Self, m: ModuleId, field: NodeId, owner: NodeId, at: tok::Span) void {
        let f = unsafe (*self.mod_ast(m)).at_const(field);
        let inside_owner = (self.package == null || m == self.ast.module) && owner == self.current_self;
        if f.kind == NodeKind::NODE_FIELD && !f.as_data.field.is_public && !inside_owner {
            self.errors.emit(
                at.start,
                at.end - at.start,
                format("field '{}' is private", diag::span_str(self.source, at.start, at.end)),
            );
        }
    }

    fn check_call(self: &mut Self, id: NodeId, want: TypeId) TypeId {
        let a = self.cur_ast();
        let callee_id = unsafe (*a).at_const(id).as_data.call.callee;
        let pck = unsafe (*a).at_const(callee_id).kind;
        let mut callee = TYPE_NONE;
        // `x.free()` intrinsic no-op check
        if pck == NodeKind::NODE_MEMBER && !unsafe (*a).at_const(callee_id).as_data.member.path && unsafe (*a).at_const(
            id,
        ).as_data.call.args.len == 0 {
            let mem = unsafe (*a).at_const(callee_id).as_data.member.member;
            if span_is(self.mod_src(self.ast.module), unsafe (*a).at_const(mem).as_data.name.text, "free") {
                let obj = unsafe (*a).at_const(callee_id).as_data.member.object;
                let rt = self.check_expr(obj);
                let fname = self.name_span(mem);
                let mut resolvable = false;
                if rt != TYPE_NONE {
                    let rty = *self.type_at(self.strip(rt));
                    if rty.kind == TypeKind::TYPE_STRUCT || rty.kind == TypeKind::TYPE_INSTANCE {
                        let mut om: ModuleId = 0;
                        let mut od = NODE_NONE;
                        let mut gp = Defs8 {};
                        let mut ga = Tys8 {};
                        let mut gn: i32 = 0;
                        if self.aggregate_of(
                            self.strip(rt),
                            (&mut om) as *mut ModuleId,
                            (&mut od) as *mut NodeId,
                            (&gp[0]) as *mut DefId,
                            (&ga[0]) as *mut TypeId,
                            (&mut gn) as *mut i32,
                        ) {
                            resolvable = self.find_method_cstr(om, od, "free").node != NODE_NONE;
                        }
                    } else if rty.kind == TypeKind::TYPE_GENERIC {
                        let mut iface = DefId { module: 0, node: NODE_NONE };
                        resolvable = self.find_bound_method(
                            rty.module,
                            rty.as_data.decl,
                            fname,
                            (&mut iface) as *mut DefId,
                        ).node != NODE_NONE;
                    } else if rty.kind == TypeKind::TYPE_DYN && rty.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                        self.tc_mark_move(obj);
                        return Ast::builtin(BuiltinType::BT_VOID);
                    }
                }
                if !resolvable {
                    return Ast::builtin(BuiltinType::BT_VOID);
                }
            }
        }
        if pck == NodeKind::NODE_MEMBER && unsafe (*a).at_const(callee_id).as_data.member.path {
            self.expected = want;
            callee = self.check_expr(callee_id);
            let vd = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                return self.check_variant_call(id, vd.module, vd.node, callee);
            }
        } else if pck == NodeKind::NODE_MEMBER {
            self.expected = want;
            callee = self.check_member(callee_id, true);
            let fd = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            if fd.node != NODE_NONE && (fd.module == self.ast.module || self.package != null && fd.module as usize < self.pkg_count()) && unsafe (*self.mod_ast(
                fd.module,
            )).at_const(fd.node).kind == NodeKind::NODE_FIELD {
                unsafe (*self.cur_ast()).set_type(callee_id, callee);
            }
        } else {
            callee = self.check_expr(callee_id);
        }
        if pck == NodeKind::NODE_MEMBER {
            let md = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            let addressable = md.module == self.ast.module || self.package != null && md.module as usize < self.pkg_count();
            if md.node != NODE_NONE && addressable && unsafe (*self.mod_ast(md.module)).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                self.tc_check_test_ref(md, unsafe (*a).at_const(id).span);
            }
        }
        // assert builtins
        if pck == NodeKind::NODE_IDENTIFIER && self.package != null {
            let ad = unsafe (*a).resolution_def(callee_id);
            if ad.node != NODE_NONE && ad.module as usize < self.pkg_count() && unsafe (*self.package).modules[ad.module as usize].prelude && unsafe (*self.mod_ast(
                ad.module,
            )).at_const(ad.node).kind == NodeKind::NODE_FUNCTION {
                let anm = unsafe (*self.mod_ast(ad.module)).at_const(
                    unsafe (*self.mod_ast(ad.module)).at_const(ad.node).as_data.function.name,
                ).as_data.name.text;
                let mut akind: i32 = 0;
                if span_is(self.mod_src(ad.module), anm, "assert") {
                    akind = 1;
                } else if span_is(self.mod_src(ad.module), anm, "assert_eq") {
                    akind = 2;
                } else if span_is(self.mod_src(ad.module), anm, "assert_ne") {
                    akind = 3;
                }
                if akind != 0 {
                    return self.tc_check_assert(id, akind);
                }
            }
        }
        let args = unsafe (*a).at_const(id).as_data.call.args;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if self.tc_is_iface_assoc_call(aid) || unsafe (*a).at_const(aid).kind == NodeKind::NODE_CLOSURE {
                self.expected = self.tc_param_expected(callee, callee_id, i);
            }
            self.check_expr(aid);
            self.tc_mark_move(aid);
        }
        if callee == TYPE_NONE {
            return TYPE_NONE;
        }
        let mut ct = *self.type_at(callee);
        let sp = unsafe (*a).at_const(id).span;
        if ct.kind == TypeKind::TYPE_GENERIC {
            let fb = self.generic_fn_bound(ct.module, ct.as_data.decl);
            if fb != NODE_NONE {
                callee = self.lower_type_in(ct.module, fb);
                ct = *self.type_at(callee);
            }
        }
        if ct.kind == TypeKind::TYPE_DYN {
            let ds = self.tc_dyn_fn_sig(&ct);
            if ds != TYPE_NONE {
                callee = ds;
                ct = *self.type_at(callee);
            }
        }
        if ct.kind == TypeKind::TYPE_STRUCT {
            let sd = unsafe (*self.mod_ast(ct.module)).at_const(ct.as_data.decl);
            if sd.kind == NodeKind::NODE_STRUCT && sd.as_data.aggregate.is_tuple {
                let sm = ct.module;
                let sdecl = ct.as_data.decl;
                let members = sd.as_data.aggregate.members;
                if args.len != members.len {
                    let mut s2 = "s".ptr() as *const char;
                    if members.len == 1 {
                        s2 = "".ptr() as *const char;
                    }
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("tuple struct takes {} element{}, got {}", members.len, diag::cstr(s2), args.len),
                    );
                    return TYPE_NONE;
                }
                for k in 0..args.len {
                    let et = self.lower_type_in(sm, unsafe (*self.mod_ast(sm)).list(members)[k as usize]);
                    let aid = unsafe (*a).list(args)[k as usize];
                    if !self.compatible(et, aid) {
                        self.err_mismatch(aid, et);
                    }
                }
                return self.named_type_of(sm, sdecl);
            }
        }
        if ct.kind != TypeKind::TYPE_FUNCTION {
            self.errors.emit(sp.start, sp.end - sp.start, format("called value is not a function"));
            return TYPE_NONE;
        }
        let fmod = ct.module;
        let fdecl = ct.as_data.decl;
        let fa = self.mod_ast(fmod);
        let fk = unsafe (*fa).at_const(fdecl).kind;
        let named = fk == NodeKind::NODE_FUNCTION;
        if named && unsafe (*fa).at_const(fdecl).as_data.function.is_extern && self.tc_needs_unsafe() {
            self.err_unsafe(sp, "calling an extern \"C\" function");
        }
        let clos = fk == NodeKind::NODE_CLOSURE;
        let mut params = NodeList { start: 0, len: 0 };
        let mut returns = NodeList { start: 0, len: 0 };
        if named {
            params = unsafe (*fa).at_const(fdecl).as_data.function.params;
            returns = unsafe (*fa).at_const(fdecl).as_data.function.returns;
        } else if clos {
            params = unsafe (*fa).at_const(fdecl).as_data.closure.params;
            returns = unsafe (*fa).at_const(fdecl).as_data.closure.returns;
        } else {
            params = unsafe (*fa).at_const(fdecl).as_data.function_type.params;
            returns = unsafe (*fa).at_const(fdecl).as_data.function_type.returns;
        }
        let mut fmt_builtin = false;
        if named && self.package != null && fmod as usize < self.pkg_count() && unsafe (*self.package).modules[fmod as usize].prelude {
            let fnm = unsafe (*fa).at_const(unsafe (*fa).at_const(fdecl).as_data.function.name).as_data.name.text;
            fmt_builtin = span_is(self.mod_src(fmod), fnm, "format") || span_is(self.mod_src(fmod), fnm, "format_into") || span_is(
                self.mod_src(fmod),
                fnm,
                "print",
            ) || span_is(self.mod_src(fmod), fnm, "println") || span_is(self.mod_src(fmod), fnm, "eprint") || span_is(
                self.mod_src(fmod),
                fnm,
                "eprintln",
            );
            if fmt_builtin {
                self.mark_format_helpers();
            }
        }
        let mut skip: u32 = 0;
        let cn_path = unsafe (*a).at_const(callee_id).as_data.member.path;
        if named && pck == NodeKind::NODE_MEMBER && !cn_path && params.len > 0 {
            let md = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            if md.node != NODE_NONE && unsafe (*self.mod_ast(md.module)).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                skip = 1;
            }
        }
        // receiver move/borrow bookkeeping for methods
        if pck == NodeKind::NODE_MEMBER && skip == 1 && unsafe (*a).at_const(callee_id).as_data.member.object != NODE_NONE {
            self.check_call_receiver(callee_id, fmod, params, returns);
        }
        // generic-instance receiver substitution + generic call inference
        let ret = self.check_call_finish(
            id,
            callee_id,
            fmod,
            fdecl,
            named,
            clos,
            params,
            returns,
            args,
            skip,
            want,
            fmt_builtin,
        );
        return ret;
    }

    fn check_call_receiver(self: &mut Self, callee_id: NodeId, fmod: ModuleId, params: NodeList, returns: NodeList) void {
        let a = self.cur_ast();
        let mem = unsafe (*a).at_const(callee_id).as_data.member.member;
        let recv = unsafe (*a).at_const(callee_id).as_data.member.object;
        let is_free = span_is(self.mod_src(self.ast.module), unsafe (*a).at_const(mem).as_data.name.text, "free");
        if is_free {
            let rty = *self.type_at(unsafe (*a).type_of(recv));
            let mut thru = NODE_NONE;
            if rty.kind == TypeKind::TYPE_REFERENCE && unsafe (*a).at_const(recv).kind == NodeKind::NODE_IDENTIFIER {
                let rd = unsafe (*a).resolution_def(recv);
                if rd.module == self.ast.module {
                    thru = rd.node;
                }
            } else if rty.kind != TypeKind::TYPE_POINTER {
                thru = self.place_through_binding(recv);
            }
            let mut through_owner = false;
            let mut i: u32 = 0;
            while thru != NODE_NONE && i < self.nborrows && !through_owner {
                let b = self.borrows[i as usize];
                if b.binding == thru && b.root != NODE_NONE {
                    let rk = unsafe (*a).at_const(b.root).kind;
                    if rk == NodeKind::NODE_LET || rk == NodeKind::NODE_PATTERN_NAME || rk == NodeKind::NODE_IDENTIFIER || rk == NodeKind::NODE_FOR {
                        let rsp = unsafe (*a).at_const(recv).span;
                        self.errors.emit(
                            rsp.start,
                            rsp.end - rsp.start,
                            format("cannot free a borrowed value: its owning binding frees it again at scope exit"),
                        );
                        through_owner = true;
                    }
                }
                i = i + 1;
            }
            if !through_owner && rty.kind != TypeKind::TYPE_POINTER && rty.kind != TypeKind::TYPE_REFERENCE && self.tc_type_is_free(
                unsafe (*a).type_of(recv),
            ) {
                self.tc_mark_move(recv);
                if unsafe (*a).at_const(recv).kind == NodeKind::NODE_IDENTIFIER {
                    let rd = unsafe (*a).resolution_def(recv);
                    if rd.module == self.ast.module && rd.node != NODE_NONE {
                        if self.nfreed < 256 {
                            let k = self.nfreed;
                            self.freed[k as usize] = rd.node;
                            self.nfreed = k + 1;
                        }
                    }
                }
            }
            return;
        }
        let fa = self.mod_ast(fmod);
        let p0 = unsafe (*fa).list(params)[0];
        let pt = unsafe (*fa).at_const(p0).as_data.parameter.ty;
        let mut ptk = NodeKind::NODE_NONE_KIND;
        if pt != NODE_NONE {
            ptk = unsafe (*fa).at_const(pt).kind;
        }
        if ptk != NodeKind::NODE_POINTER_TYPE && ptk != NodeKind::NODE_REFERENCE_TYPE {
            if unsafe (*a).deref_use_at(mem) != null {
                self.borrow_report_conflict(recv, BORROW_SHARED, recv);
            } else {
                self.tc_mark_move(recv);
            }
        } else {
            let mut bk = BORROW_SHARED;
            if unsafe (*fa).at_const(pt).as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                bk = BORROW_MUT;
            }
            let mut ret_ref = false;
            if returns.len == 1 {
                let rr0 = unsafe (*fa).list(returns)[0];
                let rrn = unsafe (*fa).at_const(rr0);
                let rtn = if_node(rrn.kind == NodeKind::NODE_PARAMETER, rrn.as_data.parameter.ty, rr0);
                ret_ref = rtn != NODE_NONE && unsafe (*fa).at_const(rtn).kind == NodeKind::NODE_REFERENCE_TYPE;
            }
            if ret_ref {
                self.borrow_create(recv, bk, recv);
            } else {
                self.borrow_report_conflict(recv, bk, recv);
            }
        }
    }

    fn check_call_finish(
        self: &mut Self,
        id: NodeId,
        callee_id: NodeId,
        fmod: ModuleId,
        fdecl: NodeId,
        named: bool,
        clos: bool,
        params: NodeList,
        returns: NodeList,
        args: NodeList,
        skip: u32,
        want: TypeId,
        fmt_builtin: bool,
    ) TypeId {
        let a = self.cur_ast();
        let fa = self.mod_ast(fmod);
        let sp = unsafe (*a).at_const(id).span;
        let cn_kind = unsafe (*a).at_const(callee_id).kind;
        let cn_path = cn_kind == NodeKind::NODE_MEMBER && unsafe (*a).at_const(callee_id).as_data.member.path;
        let mut cdu: *const DerefUse = null;
        if cn_kind == NodeKind::NODE_MEMBER && !cn_path {
            cdu = unsafe (*a).deref_use_at(unsafe (*a).at_const(callee_id).as_data.member.member);
        }
        let mut rsubp = Defs8 {};
        let mut rsuba = Tys8 {};
        let mut nrsub: i32 = 0;
        if cn_kind == NodeKind::NODE_MEMBER {
            let md = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            let mut recvbase = self.strip(unsafe (*a).type_of(unsafe (*a).at_const(callee_id).as_data.member.object));
            if cdu != null {
                recvbase = unsafe (*cdu).target;
            }
            let mut rmod: ModuleId = 0;
            let mut rdecl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut sn: i32 = 0;
            let mdfn = md.node != NODE_NONE && unsafe (*self.mod_ast(md.module)).at_const(md.node).kind == NodeKind::NODE_FUNCTION;
            let agok = mdfn && self.aggregate_of(
                recvbase,
                (&mut rmod) as *mut ModuleId,
                (&mut rdecl) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut sn) as *mut i32,
            );
            if agok && sn > 0 {
                let extnode = self.enclosing_extend(md.module, md.node);
                if extnode != NODE_NONE {
                    let ma = self.mod_ast(md.module);
                    let ig = unsafe (*ma).at_const(extnode).as_data.extend_def.generics;
                    let mut g = ig.len as i32;
                    if sn < g {
                        g = sn;
                    }
                    let mut i: i32 = 0;
                    while i < g && nrsub < 8 {
                        let gid = unsafe (*ma).list(ig)[i as usize];
                        rsubp[nrsub as usize] = DefId { module: md.module, node: gid };
                        rsuba[nrsub as usize] = ga[i as usize];
                        nrsub = nrsub + 1;
                        i = i + 1;
                    }
                }
            }
        }
        // method through a generic bound: substitute interface Self
        if cn_kind == NodeKind::NODE_MEMBER && !cn_path && nrsub < 8 {
            let md = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            let mut tr = NODE_NONE;
            if md.node != NODE_NONE {
                tr = self.enclosing_trait(md.module, md.node);
            }
            if tr != NODE_NONE {
                let mut target = self.strip(unsafe (*a).type_of(unsafe (*a).at_const(callee_id).as_data.member.object));
                if cdu != null {
                    target = unsafe (*cdu).target;
                }
                rsubp[nrsub as usize] = DefId { module: md.module, node: tr };
                rsuba[nrsub as usize] = target;
                nrsub = nrsub + 1;
                let ro = *self.type_at(target);
                if ro.kind == TypeKind::TYPE_GENERIC && nrsub < 8 {
                    nrsub = nrsub + self.bound_method_subst(
                        ro.module,
                        ro.as_data.decl,
                        md,
                        unsafe ((&mut rsubp[0]) as *mut DefId + nrsub as usize),
                        unsafe ((&mut rsuba[0]) as *mut TypeId + nrsub as usize),
                        4 - nrsub,
                    );
                }
            }
        }
        // `T::assoc()` (a static interface method on a type param): substitute the interface's Self by the
        // param's type, so a `Self` return resolves to T inside the generic function.
        if cn_kind == NodeKind::NODE_MEMBER && cn_path && nrsub < 8 {
            let md = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            let mut tr = NODE_NONE;
            if md.node != NODE_NONE {
                tr = self.enclosing_trait(md.module, md.node);
            }
            let ob = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.object);
            let mut ob_kind = NodeKind::NODE_NONE_KIND;
            if ob.node != NODE_NONE {
                ob_kind = unsafe (*self.mod_ast(ob.module)).at_const(ob.node).kind;
            }
            if tr != NODE_NONE && ob.node != NODE_NONE && ob_kind == NodeKind::NODE_GENERIC_PARAM {
                rsubp[nrsub as usize] = DefId { module: md.module, node: tr };
                rsuba[nrsub as usize] = self.named_type_of(ob.module, ob.node);
                nrsub = nrsub + 1;
                if nrsub < 8 {
                    nrsub = nrsub + self.bound_method_subst(
                        ob.module,
                        ob.node,
                        md,
                        unsafe ((&mut rsubp[0]) as *mut DefId + nrsub as usize),
                        unsafe ((&mut rsuba[0]) as *mut TypeId + nrsub as usize),
                        4 - nrsub,
                    );
                }
            }
            // `Interface::assoc()` on a generic instance target (`let v: Vector<String> = Default::default();`):
            // the resolved method's signature uses the EXTEND's type params -- bind them to the target's args.
            if ob.node != NODE_NONE && md.node != NODE_NONE && ob_kind == NodeKind::NODE_INTERFACE {
                let mut em: ModuleId = 0;
                let mut ed = NODE_NONE;
                let mut egp2 = Defs8 {};
                let mut ega2 = Tys8 {};
                let mut egn2: i32 = 0;
                let mut agg = false;
                if want != TYPE_NONE {
                    let sw = self.strip(want);
                    agg = self.aggregate_of(
                        sw,
                        (&mut em) as *mut ModuleId,
                        (&mut ed) as *mut NodeId,
                        (&egp2[0]) as *mut DefId,
                        (&ega2[0]) as *mut TypeId,
                        (&mut egn2) as *mut i32,
                    );
                }
                if agg && egn2 > 0 {
                    let ext = self.enclosing_extend(md.module, md.node);
                    if ext != NODE_NONE {
                        let ma = self.mod_ast(md.module);
                        let ig = unsafe (*ma).at_const(ext).as_data.extend_def.generics;
                        let gids = unsafe (*ma).list(ig);
                        let mut i: u32 = 0;
                        while i < ig.len && i as i32 < egn2 && nrsub < 8 {
                            rsubp[nrsub as usize] = DefId { module: md.module, node: unsafe gids[i as usize] };
                            rsuba[nrsub as usize] = ega2[i as usize];
                            nrsub = nrsub + 1;
                            i = i + 1;
                        }
                    }
                }
            }
        }
        // method-extend bounds check
        if cn_kind == NodeKind::NODE_MEMBER {
            let md = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.member);
            if md.node != NODE_NONE && unsafe (*self.mod_ast(md.module)).at_const(md.node).kind == NodeKind::NODE_FUNCTION {
                let mut mt = TYPE_NONE;
                if !cn_path {
                    if cdu != null {
                        mt = unsafe (*cdu).target;
                    } else {
                        mt = self.strip(unsafe (*a).type_of(unsafe (*a).at_const(callee_id).as_data.member.object));
                    }
                } else {
                    let ob = unsafe (*a).resolution_def(unsafe (*a).at_const(callee_id).as_data.member.object);
                    if ob.node != NODE_NONE && unsafe (*self.mod_ast(ob.module)).at_const(ob.node).kind == NodeKind::NODE_INTERFACE && want != TYPE_NONE {
                        mt = self.strip(want);
                    } else {
                        mt = self.strip(unsafe (*a).type_of(unsafe (*a).at_const(callee_id).as_data.member.object));
                    }
                }
                if mt != TYPE_NONE && !self.method_extend_bounds_hold(mt, md) {
                    self.err_method_extend_bounds(sp, mt, md);
                    return TYPE_NONE;
                }
            }
        }
        // generic function call inference
        let mut gparams = Defs8 {};
        let mut gargs = Tys8 {};
        let mut gn: i32 = 0;
        if named && unsafe (*fa).at_const(fdecl).as_data.function.generics.len != 0 {
            let gens = unsafe (*fa).at_const(fdecl).as_data.function.generics;
            let mut g = gens.len as i32;
            if g > 8 {
                g = 8;
            }
            for ii in 0..g {
                gparams[ii as usize] = DefId { module: fmod, node: unsafe (*fa).list(gens)[ii as usize] };
                gargs[ii as usize] = TYPE_NONE;
            }
            let mut bound = Tys8 {};
            let mut nexplicit: i32 = 0;
            if cn_kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
                let tas = unsafe (*a).at_const(callee_id).as_data.specialization.types;
                let mut i: u32 = 0;
                while i < tas.len && nexplicit < g {
                    bound[nexplicit as usize] = unsafe (*a).type_of(unsafe (*a).list(tas)[i as usize]);
                    nexplicit = nexplicit + 1;
                    i = i + 1;
                }
            }
            if nexplicit < g && args.len == params.len - skip {
                for i in 0..args.len {
                    let pid = unsafe (*fa).list(params)[(i + skip) as usize];
                    self.unify_infer(
                        self.decl_type_in(fmod, pid),
                        unsafe (*a).type_of(unsafe (*a).list(args)[i as usize]),
                        (&gparams[0]) as *const DefId,
                        (&mut bound[0]) as *mut TypeId,
                        g,
                    );
                }
                for k in 0..g {
                    if bound[k as usize] != TYPE_NONE && self.type_at(bound[k as usize]).kind == TypeKind::TYPE_FUNCTION {
                        let fb = self.generic_fn_bound(fmod, unsafe (*fa).list(gens)[k as usize]);
                        if fb != NODE_NONE {
                            self.unify_infer(
                                self.lower_type_in(fmod, fb),
                                bound[k as usize],
                                (&gparams[0]) as *const DefId,
                                (&mut bound[0]) as *mut TypeId,
                                g,
                            );
                        }
                    }
                }
                self.infer_from_bounds(
                    fmod,
                    fdecl,
                    unsafe (*fa).list(gens),
                    (&gparams[0]) as *const DefId,
                    (&mut bound[0]) as *mut TypeId,
                    g,
                );
                nexplicit = g;
            }
            for i in 0..nexplicit {
                gargs[i as usize] = bound[i as usize];
            }
            gn = nexplicit;
            if gn == g {
                unsafe (*self.cur_ast()).set_type_args(id, (&gargs[0]) as *const TypeId, gn as u8);
                // enforce bounds (best-effort; diagnostics)
                self.check_generic_bounds(
                    id,
                    fmod,
                    fdecl,
                    gens,
                    (&gparams[0]) as *const DefId,
                    (&gargs[0]) as *const TypeId,
                    gn,
                    (&rsubp[0]) as *const DefId,
                    (&rsuba[0]) as *const TypeId,
                    nrsub,
                );
            }
        }
        // arity + arg compatibility
        let variadic = named && unsafe (*fa).at_const(fdecl).as_data.function.is_variadic;
        let expected = params.len - skip;
        let bad = if_bool(variadic, args.len < expected, args.len != expected);
        if bad {
            let mut s2 = "s".ptr() as *const char;
            if expected == 1 {
                s2 = "".ptr() as *const char;
            }
            if variadic {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("expected at least {} argument{}, found {}", expected, diag::cstr(s2), args.len),
                );
            } else {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("expected {} argument{}, found {}", expected, diag::cstr(s2), args.len),
                );
            }
        } else {
            for i in 0..expected {
                let pid = unsafe (*fa).list(params)[(i + skip) as usize];
                let raw = if_ty(named, self.decl_type_in(fmod, pid), self.lower_type_in(fmod, pid));
                let pt = self.subst_type(
                    self.subst_type(raw, (&gparams[0]) as *const DefId, (&gargs[0]) as *const TypeId, gn),
                    (&rsubp[0]) as *const DefId,
                    (&rsuba[0]) as *const TypeId,
                    nrsub,
                );
                let aid = unsafe (*a).list(args)[i as usize];
                if self.type_at(pt).kind == TypeKind::TYPE_FUNCTION {
                    let at = unsafe (*a).type_of(aid);
                    if pt != at && at != TYPE_NONE && self.fn_is_capturing(at) {
                        let asp = unsafe (*a).at_const(aid).span;
                        self.errors.emit(
                            asp.start,
                            asp.end - asp.start,
                            format("a capturing closure cannot be passed as a bare 'fn' pointer"),
                        );
                    } else if at == TYPE_NONE || self.at_not_fn(at) || !self.fn_compatible_subst(
                        pt,
                        at,
                        (&gparams[0]) as *const DefId,
                        (&gargs[0]) as *const TypeId,
                        gn,
                        (&rsubp[0]) as *const DefId,
                        (&rsuba[0]) as *const TypeId,
                        nrsub,
                    ) {
                        self.err_mismatch(aid, pt);
                    }
                } else if !self.compatible(pt, aid) {
                    self.err_mismatch(aid, pt);
                }
            }
        }
        // C-vararg string-literal default to *const char
        if variadic && !fmt_builtin && args.len >= expected {
            let cstr = unsafe (*self.cur_ast()).intern_type(
                Ty {
                    kind: TypeKind::TYPE_POINTER,
                    qualifier: TypeQualifier::TYPE_QUAL_CONST as u8,
                    as_data: TyAs { elem: Ast::builtin(BuiltinType::BT_CHAR) },
                },
            );
            let mut i = expected;
            while i < args.len {
                let aid = unsafe (*a).list(args)[i as usize];
                let an = unsafe (*a).at_const(aid);
                if an.kind == NodeKind::NODE_LITERAL && (an.as_data.literal.token_type == TokenType::StringLiteral || an.as_data.literal.token_type == TokenType::RawStringLiteral) {
                    unsafe (*self.cur_ast()).set_type(aid, cstr);
                }
                i = i + 1;
            }
        }
        // &mut self receiver mutability
        if skip == 1 && cn_kind == NodeKind::NODE_MEMBER && params.len > 0 {
            let selfp = *self.type_at(self.decl_type_in(fmod, unsafe (*fa).list(params)[0]));
            if (selfp.kind == TypeKind::TYPE_REFERENCE || selfp.kind == TypeKind::TYPE_POINTER) && selfp.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                let recv = unsafe (*a).at_const(callee_id).as_data.member.object;
                let rvt = *self.type_at(unsafe (*a).type_of(recv));
                if rvt.kind == TypeKind::TYPE_DYN {
                    if rvt.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                        let rsp = unsafe (*a).at_const(recv).span;
                        self.errors.emit(
                            rsp.start,
                            rsp.end - rsp.start,
                            format("cannot call a '&mut self' method through '&dyn' (use '&mut dyn')"),
                        );
                    } else if rvt.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 && !self.receiver_mutable(recv) {
                        let rsp = unsafe (*a).at_const(recv).span;
                        self.errors.emit(
                            rsp.start,
                            rsp.end - rsp.start,
                            format("cannot call a '&mut self' method on an immutable binding (bind it with 'mut')"),
                        );
                    }
                } else {
                    let consuming_free = rvt.kind != TypeKind::TYPE_REFERENCE && rvt.kind != TypeKind::TYPE_POINTER && span_is(
                        self.mod_src(self.ast.module),
                        unsafe (*a).at_const(unsafe (*a).at_const(callee_id).as_data.member.member).as_data.name.text,
                        "free",
                    );
                    if !consuming_free {
                        self.tc_mark_capture_mut(recv);
                        if !self.receiver_mutable(recv) {
                            let rsp = unsafe (*a).at_const(recv).span;
                            self.errors.emit(
                                rsp.start,
                                rsp.end - rsp.start,
                                format("cannot call a '&mut self' method on an immutable binding (bind it with 'mut')"),
                            );
                        }
                    }
                }
            }
        }
        if clos && unsafe (*fa).at_const(fdecl).as_data.closure.expr_body {
            return unsafe (*fa).type_of(unsafe (*fa).at_const(fdecl).as_data.closure.body);
        }
        if named && self.tc_attr(fmod, fdecl, AttrKind::ATTR_NORETURN) != null {
            return unsafe (*self.cur_ast()).intern_type(Ty { kind: TypeKind::TYPE_NEVER });
        }
        if returns.len != 1 {
            if returns.len > 1 {
                self.mret_n = if_u8(returns.len < 8, returns.len as u8, 8);
                self.mret_total = returns.len;
                for i in 0..self.mret_n {
                    let mrid = unsafe (*fa).list(returns)[i as usize];
                    let mrn = unsafe (*fa).at_const(mrid);
                    let mrt = self.lower_type_in(
                        fmod,
                        if_node(mrn.kind == NodeKind::NODE_PARAMETER, mrn.as_data.parameter.ty, mrid),
                    );
                    self.mret_types[i as usize] = self.subst_type(
                        self.subst_type(mrt, (&gparams[0]) as *const DefId, (&gargs[0]) as *const TypeId, gn),
                        (&rsubp[0]) as *const DefId,
                        (&rsuba[0]) as *const TypeId,
                        nrsub,
                    );
                }
                self.mret_call = id;
            }
            return TYPE_NONE;
        }
        let r0 = unsafe (*fa).list(returns)[0];
        let rn = unsafe (*fa).at_const(r0);
        let ret = self.lower_type_in(fmod, if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
        return self.subst_type(
            self.subst_type(ret, (&gparams[0]) as *const DefId, (&gargs[0]) as *const TypeId, gn),
            (&rsubp[0]) as *const DefId,
            (&rsuba[0]) as *const TypeId,
            nrsub,
        );
    }

    fn check_generic_bounds(
        self: &mut Self,
        id: NodeId,
        fmod: ModuleId,
        fdecl: NodeId,
        gens: NodeList,
        gparams: *const DefId,
        gargs: *const TypeId,
        gn: i32,
        rsubp: *const DefId,
        rsuba: *const TypeId,
        nrsub: i32,
    ) void {
        let a = self.cur_ast();
        let fa = self.mod_ast(fmod);
        let sp = unsafe (*a).at_const(id).span;
        for i in 0..gn {
            let gid = unsafe (*fa).list(gens)[i as usize];
            let pb = unsafe (*fa).at_const(gid).as_data.generic_param.bounds;
            for b in 0..pb.len {
                let bid = unsafe (*fa).list(pb)[b as usize];
                if unsafe (*fa).at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                    let bt = self.lower_type_in(fmod, bid);
                    let garg = unsafe gargs[i as usize];
                    if garg != TYPE_NONE {
                        let gy = *self.type_at(garg);
                        if gy.kind != TypeKind::TYPE_GENERIC && (gy.kind != TypeKind::TYPE_FUNCTION || !self.fn_compatible_subst(
                            bt,
                            garg,
                            gparams,
                            gargs,
                            gn,
                            rsubp,
                            rsuba,
                            nrsub,
                        )) {
                            let mut tn = Buf96 {};
                            self.render_type(garg, &mut tn[0], 96);
                            let bsp = unsafe (*fa).at_const(bid).span;
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format(
                                    "type '{}' does not satisfy bound '{}'",
                                    diag::cstr(&tn[0]),
                                    diag::span_str(self.mod_src(fmod), bsp.start, bsp.end),
                                ),
                            );
                        }
                    }
                } else {
                    let bi = unsafe (*fa).resolution_def(bid);
                    if bi.node != NODE_NONE && !self.type_satisfies(unsafe gargs[i as usize], bi, 0) {
                        let mut tn = Buf96 {};
                        self.render_type(unsafe gargs[i as usize], &mut tn[0], 96);
                        let bsp = unsafe (*fa).at_const(bid).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format(
                                "type '{}' does not satisfy bound '{}'",
                                diag::cstr(&tn[0]),
                                diag::span_str(self.mod_src(fmod), bsp.start, bsp.end),
                            ),
                        );
                    }
                }
            }
        }
        // where clause
        let wc = unsafe (*fa).at_const(fdecl).as_data.function.where_clause;
        for w in 0..wc.len {
            let wp = unsafe (*fa).at_const(unsafe (*fa).list(wc)[w as usize]).as_data.where_predicate;
            let wt = self.subst_type(self.lower_type_in(fmod, wp.ty), gparams, gargs, gn);
            for b in 0..wp.bounds.len {
                let wbid = unsafe (*fa).list(wp.bounds)[b as usize];
                if unsafe (*fa).at_const(wbid).kind == NodeKind::NODE_FUNCTION_TYPE {
                    let bt = self.lower_type_in(fmod, wbid);
                    if wt != TYPE_NONE {
                        let wy = *self.type_at(wt);
                        if wy.kind != TypeKind::TYPE_GENERIC && (wy.kind != TypeKind::TYPE_FUNCTION || !self.fn_compatible_subst(
                            bt,
                            wt,
                            gparams,
                            gargs,
                            gn,
                            rsubp,
                            rsuba,
                            nrsub,
                        )) {
                            let mut tn = Buf96 {};
                            self.render_type(wt, &mut tn[0], 96);
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format("type '{}' does not satisfy a where-clause bound", diag::cstr(&tn[0])),
                            );
                        }
                    }
                } else {
                    let bi = unsafe (*fa).resolution_def(wbid);
                    if bi.node != NODE_NONE && !self.type_satisfies(wt, bi, 0) {
                        let mut tn = Buf96 {};
                        self.render_type(wt, &mut tn[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("type '{}' does not satisfy a where-clause bound", diag::cstr(&tn[0])),
                        );
                    }
                }
            }
        }
    }
}

fn if_u8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}

extend TypeChecker {
    fn check_member(self: &mut Self, id: NodeId, prefer_method: bool) TypeId {
        let a = self.cur_ast();
        let want = self.expected;
        self.expected = TYPE_NONE;
        let obj_node = unsafe (*a).at_const(id).as_data.member.object;
        let obj = self.check_expr(obj_node);
        if obj == TYPE_NONE {
            return TYPE_NONE;
        }
        let mname = unsafe (*a).at_const(id).as_data.member.member;
        let name = self.name_span(mname);
        let base = self.strip(obj);
        let mut bmod: ModuleId = 0;
        let mut bdecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if self.aggregate_of(
            base,
            (&mut bmod) as *mut ModuleId,
            (&mut bdecl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            let mut mhit = DefId { module: 0, node: NODE_NONE };
            let mut fhit = NODE_NONE;
            let mut digits = name.end > name.start && name.end - name.start <= 2;
            let mut di = name.start;
            while di < name.end && digits {
                if self.source[di as usize] < b'0' || self.source[di as usize] > b'9' {
                    digits = false;
                }
                di = di + 1;
            }
            if digits {
                let bd0 = unsafe (*self.mod_ast(bmod)).at_const(bdecl);
                if bd0.kind == NodeKind::NODE_STRUCT && bd0.as_data.aggregate.is_tuple {
                    let mut idx: u32 = 0;
                    let mut k = name.start;
                    while k < name.end {
                        idx = idx * 10 + (self.source[k as usize] - b'0') as u32;
                        k = k + 1;
                    }
                    if idx >= bd0.as_data.aggregate.members.len {
                        self.errors.emit(
                            name.start,
                            name.end - name.start,
                            format("tuple struct has no element {}", idx),
                        );
                        return TYPE_NONE;
                    }
                    let tnode = unsafe (*self.mod_ast(bmod)).list(bd0.as_data.aggregate.members)[idx as usize];
                    unsafe (*self.cur_ast()).set_resolution_def(mname, DefId { module: bmod, node: tnode });
                    return self.subst_type(
                        self.lower_type_in(bmod, tnode),
                        (&gp[0]) as *const DefId,
                        (&ga[0]) as *const TypeId,
                        gn,
                    );
                }
                let mut fld = Buf96 {};
                unsafe stdio::snprintf(
                    &mut fld[0],
                    8,
                    "_%.*s".ptr() as *const char,
                    (name.end - name.start) as i32,
                    src_at(self.source, name.start),
                );
                fhit = self.find_member_cstr(bmod, bdecl, diag::cstr(&fld[0]));
            }
            if fhit == NODE_NONE && prefer_method {
                mhit = self.find_method(bmod, bdecl, name);
                if mhit.node == NODE_NONE {
                    fhit = self.find_member(bmod, bdecl, name);
                }
            } else if fhit == NODE_NONE {
                fhit = self.find_member(bmod, bdecl, name);
                if fhit == NODE_NONE {
                    mhit = self.find_method(bmod, bdecl, name);
                }
            }
            if mhit.node != NODE_NONE {
                unsafe (*self.cur_ast()).set_resolution_def(mname, mhit);
                return self.subst_type(
                    self.decl_type_in(mhit.module, mhit.node),
                    (&gp[0]) as *const DefId,
                    (&ga[0]) as *const TypeId,
                    gn,
                );
            }
            if fhit != NODE_NONE {
                unsafe (*self.cur_ast()).set_resolution_def(mname, DefId { module: bmod, node: fhit });
                if unsafe (*self.mod_ast(bmod)).at_const(fhit).kind == NodeKind::NODE_FIELD {
                    self.check_field_visibility(bmod, fhit, bdecl, name);
                    if self.tc_needs_unsafe() && self.through_raw_pointer(obj) {
                        self.err_unsafe(unsafe (*a).at_const(id).span, "accessing a field through a raw pointer");
                    }
                }
                return self.subst_type(
                    self.decl_type_in(bmod, fhit),
                    (&gp[0]) as *const DefId,
                    (&ga[0]) as *const TypeId,
                    gn,
                );
            }
            if prefer_method {
                let dm = self.find_default_method(bmod, bdecl, name);
                if dm.node != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(mname, dm);
                    return self.subst_type(
                        self.decl_type_in(dm.module, dm.node),
                        (&gp[0]) as *const DefId,
                        (&ga[0]) as *const TypeId,
                        gn,
                    );
                }
            }
        }
        // builtin method
        let bty = *self.type_at(base);
        if bty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bd = unsafe (*self.package).builtin_decl(bty.as_data.builtin);
            if bd != NODE_NONE {
                let mut mhit = self.find_method(unsafe (*self.package).core_module, bd, name);
                if mhit.node == NODE_NONE {
                    mhit = self.find_default_method(unsafe (*self.package).core_module, bd, name);
                }
                if mhit.node != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(mname, mhit);
                    return self.decl_type_in(mhit.module, mhit.node);
                }
            }
        }
        // generic/dyn receiver bound method
        let bt2 = *self.type_at(base);
        if bt2.kind == TypeKind::TYPE_GENERIC || bt2.kind == TypeKind::TYPE_DYN {
            let gd = unsafe (*self.mod_ast(bt2.module)).at_const(bt2.as_data.decl);
            if gd.kind == NodeKind::NODE_INTERFACE {
                let m = self.find_interface_method(bt2.module, bt2.as_data.decl, name, 0);
                if m.node != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(mname, m);
                    return self.decl_type_in(m.module, m.node);
                }
            } else {
                let mut iface = DefId { module: 0, node: NODE_NONE };
                let m = self.find_bound_method(bt2.module, bt2.as_data.decl, name, (&mut iface) as *mut DefId);
                if m.node != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(mname, m);
                    return self.decl_type_in(m.module, m.node);
                }
            }
        }
        // into/try_into conversion
        if prefer_method {
            let conv = self.resolve_conversion(name, want);
            if conv.node != NODE_NONE {
                unsafe (*self.cur_ast()).set_resolution_def(mname, conv);
                return self.decl_type_in(conv.module, conv.node);
            }
        }
        // auto-deref chain
        let mut deref_capped = false;
        if prefer_method {
            let mut du = DerefUse { node: mname, n: 0 };
            let mut cur = base;
            let mut seen = Tys8 {};
            seen[0] = base;
            let mut nseen: i32 = 1;
            loop {
                if du.n >= 8 {
                    break;
                }
                let mut cm: ModuleId = 0;
                let mut cd = NODE_NONE;
                let mut cgp = Defs8 {};
                let mut cga = Tys8 {};
                let mut cgn: i32 = 0;
                if !self.aggregate_of(
                    cur,
                    (&mut cm) as *mut ModuleId,
                    (&mut cd) as *mut NodeId,
                    (&cgp[0]) as *mut DefId,
                    (&cga[0]) as *mut TypeId,
                    (&mut cgn) as *mut i32,
                ) {
                    break;
                }
                let dm = self.find_method_cstr(cm, cd, "deref");
                if dm.node == NODE_NONE {
                    break;
                }
                let dret = self.tc_method_ret(cur, dm);
                if dret == TYPE_NONE {
                    break;
                }
                let dry = *self.type_at(dret);
                if dry.kind != TypeKind::TYPE_REFERENCE && dry.kind != TypeKind::TYPE_POINTER {
                    break;
                }
                let target = dry.as_data.elem;
                let mut cyc = false;
                for z in 0..nseen {
                    if seen[z as usize] == target {
                        cyc = true;
                    }
                }
                if cyc {
                    self.errors.emit(
                        name.start,
                        name.end - name.start,
                        format(
                            "cyclic deref chain while resolving '{}'",
                            diag::span_str(self.source, name.start, name.end),
                        ),
                    );
                    return TYPE_NONE;
                }
                du.recv[du.n as usize] = cur;
                du.method[du.n as usize] = dm;
                du.n = du.n + 1;
                seen[nseen as usize] = target;
                nseen = nseen + 1;
                let mut tm: ModuleId = 0;
                let mut td = NODE_NONE;
                let mut tgp = Defs8 {};
                let mut tga = Tys8 {};
                let mut tgn: i32 = 0;
                let mut mhit = DefId { module: 0, node: NODE_NONE };
                let tty = *self.type_at(target);
                if self.aggregate_of(
                    target,
                    (&mut tm) as *mut ModuleId,
                    (&mut td) as *mut NodeId,
                    (&tgp[0]) as *mut DefId,
                    (&tga[0]) as *mut TypeId,
                    (&mut tgn) as *mut i32,
                ) {
                    mhit = self.find_method(tm, td, name);
                    if mhit.node == NODE_NONE {
                        mhit = self.find_default_method(tm, td, name);
                    }
                } else if tty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                    let bd = unsafe (*self.package).builtin_decl(tty.as_data.builtin);
                    if bd != NODE_NONE {
                        mhit = self.find_method(unsafe (*self.package).core_module, bd, name);
                        if mhit.node == NODE_NONE {
                            mhit = self.find_default_method(unsafe (*self.package).core_module, bd, name);
                        }
                    }
                }
                if mhit.node != NODE_NONE {
                    let sk = self.method_self_kind(mhit);
                    if sk == 0 && tty.kind != TypeKind::TYPE_BUILTIN {
                        self.errors.emit(
                            name.start,
                            name.end - name.start,
                            format("cannot call a by-value 'self' method through auto-deref"),
                        );
                        return TYPE_NONE;
                    }
                    if sk == 2 {
                        for hi in 0..du.n {
                            let mut hm: ModuleId = 0;
                            let mut hd = NODE_NONE;
                            let mut hgp = Defs8 {};
                            let mut hga = Tys8 {};
                            let mut hgn: i32 = 0;
                            self.aggregate_of(
                                du.recv[hi as usize],
                                (&mut hm) as *mut ModuleId,
                                (&mut hd) as *mut NodeId,
                                (&hgp[0]) as *mut DefId,
                                (&hga[0]) as *mut TypeId,
                                (&mut hgn) as *mut i32,
                            );
                            let dmm = self.find_method_cstr(hm, hd, "deref_mut");
                            if dmm.node == NODE_NONE {
                                let mut tn = Buf96 {};
                                self.render_type(du.recv[hi as usize], &mut tn[0], 96);
                                self.errors.emit(
                                    name.start,
                                    name.end - name.start,
                                    format(
                                        "cannot call a '&mut self' method through '{}': it has 'deref' but no 'deref_mut'",
                                        diag::cstr(&tn[0]),
                                    ),
                                );
                                return TYPE_NONE;
                            }
                            du.method[hi as usize] = dmm;
                        }
                    }
                    du.target = target;
                    unsafe (*self.cur_ast()).add_deref_use(&du);
                    unsafe (*self.cur_ast()).set_resolution_def(mname, mhit);
                    return self.subst_type(
                        self.decl_type_in(mhit.module, mhit.node),
                        (&tgp[0]) as *const DefId,
                        (&tga[0]) as *const TypeId,
                        tgn,
                    );
                }
                cur = target;
            }
            deref_capped = du.n == 8;
        }
        let mut ty = Buf96 {};
        self.render_type(base, &mut ty[0], 96);
        self.errors.emit(
            name.start,
            name.end - name.start,
            format(
                "no field or method '{}' on '{}'",
                diag::span_str(self.source, name.start, name.end),
                diag::cstr(&ty[0]),
            ),
        );
        if deref_capped {
            self.errors.note(format("auto-deref stopped after its maximum of 8 hops"));
        } else {
            self.errors.note(
                format(
                    "fields are accessed as 'value.name'; methods must be declared in an 'extend' block or provided by a bound",
                ),
            );
        }
        return TYPE_NONE;
    }

    fn check_path_member(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let direct = unsafe (*a).resolution_def(id);
        let mem = unsafe (*a).at_const(id).as_data.member.member;
        if direct.node != NODE_NONE {
            let dnk = unsafe (*self.mod_ast(direct.module)).at_const(direct.node).kind;
            if dnk == NodeKind::NODE_FUNCTION || dnk == NodeKind::NODE_CONST || dnk == NodeKind::NODE_LET {
                unsafe (*self.cur_ast()).set_resolution_def(mem, direct);
                return self.decl_type_in(direct.module, direct.node);
            }
            return self.named_type_of(direct.module, direct.node);
        }
        let obj = unsafe (*a).at_const(id).as_data.member.object;
        let on_kind = unsafe (*a).at_const(obj).kind;
        let mut bmod: ModuleId = 0;
        let mut bdecl = NODE_NONE;
        let mut inst_ty = TYPE_NONE;
        if on_kind == NodeKind::NODE_IDENTIFIER {
            let b = unsafe (*a).resolution_def(obj);
            bmod = b.module;
            bdecl = b.node;
            if bdecl == NODE_NONE && self.package != null {
                let bb = builtin_of(self.source, unsafe (*a).at_const(obj).span);
                let mut bnd = NODE_NONE;
                if bb >= 0 {
                    bnd = unsafe (*self.package).builtin_decl(bb as BuiltinType);
                }
                if bnd != NODE_NONE {
                    bmod = unsafe (*self.package).core_module;
                    bdecl = bnd;
                }
            }
            if bdecl != NODE_NONE && unsafe (*self.mod_ast(bmod)).at_const(bdecl).kind == NodeKind::NODE_TYPE_ALIAS {
                let at = self.named_type_of(bmod, bdecl);
                if at != TYPE_NONE && at != TYPE_ERROR {
                    let aty = *self.type_at(at);
                    if aty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                        bmod = unsafe (*self.package).core_module;
                        bdecl = unsafe (*self.package).builtin_decl(aty.as_data.builtin);
                    } else if aty.kind == TypeKind::TYPE_STRUCT || aty.kind == TypeKind::TYPE_ENUM {
                        bmod = aty.module;
                        bdecl = aty.as_data.decl;
                    } else if aty.kind == TypeKind::TYPE_INSTANCE {
                        let ai = *unsafe (*self.cur_ast()).instance(aty.as_data.inst);
                        bmod = ai.module;
                        bdecl = ai.decl;
                        inst_ty = at;
                        unsafe (*self.cur_ast()).set_type(obj, at);
                    }
                }
            }
            if bdecl != NODE_NONE {
                let bdn = unsafe (*self.mod_ast(bmod)).at_const(bdecl);
                if (bdn.kind == NodeKind::NODE_STRUCT || bdn.kind == NodeKind::NODE_ENUM) && bdn.as_data.aggregate.generics.len > 0 && self.agg_has_default_at(
                    bmod,
                    bdecl,
                    0,
                ) {
                    let mut ta = Tys8 {};
                    let mut tn: u8 = 0;
                    self.apply_default_args(bmod, bdecl, (&mut ta[0]) as *mut TypeId, (&mut tn) as *mut u8);
                    if tn == bdn.as_data.aggregate.generics.len as u8 {
                        inst_ty = unsafe (*self.cur_ast()).intern_instance(bmod, bdecl, (&ta[0]) as *const TypeId, tn);
                        unsafe (*self.cur_ast()).set_type(obj, inst_ty);
                    }
                }
            }
        } else {
            let bt = self.check_expr(obj);
            let ty = *self.type_at(bt);
            if ty.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
                bmod = it.module;
                bdecl = it.decl;
                inst_ty = bt;
            } else if ty.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                bmod = unsafe (*self.package).core_module;
                bdecl = unsafe (*self.package).builtin_decl(ty.as_data.builtin);
            } else {
                bmod = ty.module;
                bdecl = if_node(
                    bt != TYPE_NONE && (ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM),
                    ty.as_data.decl,
                    NODE_NONE,
                );
            }
        }
        let mname = self.name_span(mem);
        let mut bd_kind = NodeKind::NODE_NONE_KIND;
        if bdecl != NODE_NONE {
            bd_kind = unsafe (*self.mod_ast(bmod)).at_const(bdecl).kind;
        }
        if bdecl != NODE_NONE && bd_kind == NodeKind::NODE_GENERIC_PARAM {
            let mut iface = DefId { module: 0, node: NODE_NONE };
            let m = self.find_bound_method(bmod, bdecl, mname, (&mut iface) as *mut DefId);
            if m.node != NODE_NONE {
                unsafe (*self.cur_ast()).set_resolution_def(mem, m);
                return self.decl_type_in(m.module, m.node);
            }
        }
        if bdecl != NODE_NONE && bd_kind == NodeKind::NODE_INTERFACE && expected != TYPE_NONE {
            let mut emod: ModuleId = 0;
            let mut edecl = NODE_NONE;
            let mut egp = Defs8 {};
            let mut ega = Tys8 {};
            let mut egn: i32 = 0;
            if self.aggregate_of(
                self.strip(expected),
                (&mut emod) as *mut ModuleId,
                (&mut edecl) as *mut NodeId,
                (&egp[0]) as *mut DefId,
                (&ega[0]) as *mut TypeId,
                (&mut egn) as *mut i32,
            ) {
                let m = self.find_method(emod, edecl, mname);
                if m.node != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(mem, m);
                    return self.decl_type_in(m.module, m.node);
                }
            }
        }
        if bdecl == NODE_NONE || bd_kind != NodeKind::NODE_STRUCT && bd_kind != NodeKind::NODE_ENUM {
            let sp = unsafe (*a).at_const(id).span;
            if bdecl != NODE_NONE && bd_kind == NodeKind::NODE_INTERFACE {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("cannot infer the implementing type for this interface call"),
                );
            } else {
                self.errors.emit(sp.start, sp.end - sp.start, format("'::' base must be a struct or enum type"));
            }
            return TYPE_NONE;
        }
        if bd_kind == NodeKind::NODE_ENUM {
            let variant = self.find_member(bmod, bdecl, mname);
            if variant != NODE_NONE && unsafe (*self.mod_ast(bmod)).at_const(variant).kind == NodeKind::NODE_VARIANT {
                unsafe (*self.cur_ast()).set_resolution_def(mem, DefId { module: bmod, node: variant });
                return if_ty(inst_ty != TYPE_NONE, inst_ty, self.named_type_of(bmod, bdecl));
            }
        }
        let method = self.find_method(bmod, bdecl, mname);
        if method.node != NODE_NONE {
            unsafe (*self.cur_ast()).set_resolution_def(mem, method);
            return self.decl_type_in(method.module, method.node);
        }
        let ac = self.find_assoc_const(bmod, bdecl, mname);
        if ac.node != NODE_NONE {
            unsafe (*self.cur_ast()).set_resolution_def(mem, ac);
            return self.decl_type_in(ac.module, ac.node);
        }
        let mut kindw = "associated method or constant".ptr() as *const char;
        if bd_kind == NodeKind::NODE_ENUM {
            kindw = "variant, method, or constant".ptr() as *const char;
        }
        self.errors.emit(
            mname.start,
            mname.end - mname.start,
            format("no {} '{}' on this type", diag::cstr(kindw), diag::span_str(self.source, mname.start, mname.end)),
        );
        return TYPE_NONE;
    }

    fn check_struct_init(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let stn = unsafe (*a).at_const(id).as_data.struct_initializer.ty;
        let sty = self.type_of_type_node(stn);
        let mut smod: ModuleId = 0;
        let mut decl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(
            sty,
            (&mut smod) as *mut ModuleId,
            (&mut decl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        ) {
            decl = NODE_NONE;
        }
        let mut variant = NODE_NONE;
        let mut vmod = smod;
        if unsafe (*a).at_const(stn).kind == NodeKind::NODE_TYPE_PATH {
            let parts = unsafe (*a).at_const(stn).as_data.type_path.parts;
            if parts.len >= 2 {
                let vd = unsafe (*a).resolution_def(unsafe (*a).list(parts)[(parts.len - 1) as usize]);
                if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                    variant = vd.node;
                    vmod = vd.module;
                }
            }
        }
        let fields = unsafe (*a).at_const(id).as_data.struct_initializer.fields;
        for i in 0..fields.len {
            let fid = unsafe (*a).list(fields)[i as usize];
            let fnn = unsafe (*a).at_const(fid).as_data.field_initializer.name;
            let fval = unsafe (*a).at_const(fid).as_data.field_initializer.value;
            let fname = self.name_span(fnn);
            if variant == NODE_NONE && decl != NODE_NONE && self.tc_is_iface_assoc_call(fval) {
                let field = self.find_member(smod, decl, fname);
                let ft = if_ty(
                    field != NODE_NONE,
                    self.subst_type(
                        self.decl_type_in(smod, field),
                        (&gp[0]) as *const DefId,
                        (&ga[0]) as *const TypeId,
                        gn,
                    ),
                    TYPE_NONE,
                );
                if ft != TYPE_NONE && unsafe (*self.cur_ast()).type_concrete(ft) {
                    self.expected = ft;
                }
            }
            self.check_expr(fval);
            self.tc_mark_move(fval);
            if variant != NODE_NONE {
                let va = self.mod_ast(vmod);
                let vpl = unsafe (*va).at_const(variant).as_data.variant.payload;
                let mut field = NODE_NONE;
                for j in 0..vpl.len {
                    let pfid = unsafe (*va).list(vpl)[j as usize];
                    let pf = unsafe (*va).at_const(pfid);
                    if pf.kind == NodeKind::NODE_FIELD && spans_eq2(
                        self.source,
                        fname,
                        self.mod_src(vmod),
                        unsafe (*va).at_const(pf.as_data.field.name).as_data.name.text,
                    ) {
                        field = pfid;
                        break;
                    }
                }
                if field == NODE_NONE {
                    let mut ty = Buf96 {};
                    self.render_type(sty, &mut ty[0], 96);
                    self.errors.emit(
                        fname.start,
                        fname.end - fname.start,
                        format(
                            "no field '{}' on '{}'",
                            diag::span_str(self.source, fname.start, fname.end),
                            diag::cstr(&ty[0]),
                        ),
                    );
                } else {
                    unsafe (*self.cur_ast()).set_resolution_def(fnn, DefId { module: vmod, node: field });
                    let ft = self.subst_type(
                        self.lower_type_in(vmod, unsafe (*self.mod_ast(vmod)).at_const(field).as_data.field.ty),
                        (&gp[0]) as *const DefId,
                        (&ga[0]) as *const TypeId,
                        gn,
                    );
                    if !self.compatible(ft, fval) {
                        self.err_mismatch(fval, ft);
                    }
                }
                continue;
            }
            if decl == NODE_NONE {
                continue;
            }
            let field = self.find_member(smod, decl, fname);
            if field == NODE_NONE {
                let mut ty = Buf96 {};
                self.render_type(sty, &mut ty[0], 96);
                self.errors.emit(
                    fname.start,
                    fname.end - fname.start,
                    format(
                        "no field '{}' on '{}'",
                        diag::span_str(self.source, fname.start, fname.end),
                        diag::cstr(&ty[0]),
                    ),
                );
                continue;
            }
            unsafe (*self.cur_ast()).set_resolution_def(fnn, DefId { module: smod, node: field });
            self.check_field_visibility(smod, field, decl, fname);
            let ft = self.subst_type(
                self.decl_type_in(smod, field),
                (&gp[0]) as *const DefId,
                (&ga[0]) as *const TypeId,
                gn,
            );
            if !self.compatible(ft, fval) {
                self.err_mismatch(fval, ft);
            }
        }
        return sty;
    }

    fn check_if_stmt(self: &mut Self, id: NodeId) void {
        let a = self.cur_ast();
        let ifd = unsafe (*a).at_const(id).as_data.if_stmt;
        let bm = self.borrow_mark();
        let c = self.check_expr(ifd.condition);
        if c != TYPE_NONE && !self.is_bool(c) {
            let sp = unsafe (*a).at_const(ifd.condition).span;
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("if condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
        }
        self.borrow_release_to(bm);
        let mut pre: FlowState;
        self.tc_flow_save(&mut pre);
        self.check_stmt(ifd.then_branch);
        let mut acc: FlowState;
        self.tc_flow_clear(&mut acc);
        let mut ovf = false;
        if !self.tc_stmt_returns(ifd.then_branch) {
            if self.tc_flow_collect((&mut acc) as *mut FlowState) {
                ovf = true;
            }
        }
        self.tc_flow_set(&pre);
        self.check_stmt(ifd.else_branch);
        if !self.tc_stmt_returns(ifd.else_branch) {
            if self.tc_flow_collect((&mut acc) as *mut FlowState) {
                ovf = true;
            }
        }
        self.tc_flow_set(&acc);
        if ovf {
            self.tc_flow_overflow(ifd.condition);
        }
    }

    fn pattern_irrefutable(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return true;
        }
        let a = self.cur_ast();
        let p = unsafe (*a).at_const(id);
        if p.kind == NodeKind::NODE_PATTERN_WILDCARD || p.kind == NodeKind::NODE_IDENTIFIER {
            return true;
        }
        if p.kind == NodeKind::NODE_PATTERN_NAME || p.kind == NodeKind::NODE_PATTERN_TUPLE || p.kind == NodeKind::NODE_PATTERN_STRUCT {
            let nameId = p.as_data.pattern.name;
            if nameId != NODE_NONE {
                let d = unsafe (*a).resolution_def(nameId);
                if d.node != NODE_NONE && unsafe (*self.mod_ast(d.module)).at_const(d.node).kind == NodeKind::NODE_VARIANT {
                    return false;
                }
            }
            if p.kind == NodeKind::NODE_PATTERN_NAME {
                return true;
            }
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                if !self.pattern_irrefutable(unsafe (*a).list(children)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if p.kind == NodeKind::NODE_PATTERN_FIELD {
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                if !self.pattern_irrefutable(unsafe (*a).list(children)[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if p.kind == NodeKind::NODE_PATTERN_OR {
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                if self.pattern_irrefutable(unsafe (*a).list(children)[i as usize]) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }
    fn pattern_covered_variant(self: &Self, id: NodeId) NodeId {
        let a = self.cur_ast();
        let p = unsafe (*a).at_const(id);
        if p.kind != NodeKind::NODE_PATTERN_NAME && p.kind != NodeKind::NODE_PATTERN_TUPLE && p.kind != NodeKind::NODE_PATTERN_STRUCT {
            return NODE_NONE;
        }
        let nameId = p.as_data.pattern.name;
        if nameId == NODE_NONE {
            return NODE_NONE;
        }
        let d = unsafe (*a).resolution_def(nameId);
        if d.node == NODE_NONE || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_VARIANT {
            return NODE_NONE;
        }
        let children = p.as_data.pattern.children;
        for i in 0..children.len {
            if !self.pattern_irrefutable(unsafe (*a).list(children)[i as usize]) {
                return NODE_NONE;
            }
        }
        return d.node;
    }
    fn match_arm_coverage(
        self: &Self,
        pid: NodeId,
        emod: ModuleId,
        has_ea: bool,
        variants: NodeList,
        covered: *mut u64,
        catchall: *mut bool,
        tcov: *mut bool,
        fcov: *mut bool,
    ) void {
        if pid == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let p = unsafe (*a).at_const(pid);
        if p.kind == NodeKind::NODE_PATTERN_OR {
            let children = p.as_data.pattern.children;
            for i in 0..children.len {
                self.match_arm_coverage(
                    unsafe (*a).list(children)[i as usize],
                    emod,
                    has_ea,
                    variants,
                    covered,
                    catchall,
                    tcov,
                    fcov,
                );
            }
            return;
        }
        if self.pattern_irrefutable(pid) {
            unsafe *catchall = true;
            return;
        }
        if p.kind == NodeKind::NODE_PATTERN_LITERAL {
            let v = unsafe (*a).at_const(p.as_data.single.value);
            if v.kind == NodeKind::NODE_LITERAL && v.as_data.literal.token_type == TokenType::True {
                unsafe *tcov = true;
            } else if v.kind == NodeKind::NODE_LITERAL && v.as_data.literal.token_type == TokenType::False {
                unsafe *fcov = true;
            }
            return;
        }
        let var = self.pattern_covered_variant(pid);
        if var == NODE_NONE || !has_ea {
            return;
        }
        let ea = self.mod_ast(emod);
        let mut i: u32 = 0;
        while i < variants.len && i < MATCH_MAX_VARIANTS {
            if unsafe (*ea).list(variants)[i as usize] == var {
                let idx = (i >> 6) as usize;
                let cur = unsafe covered[idx];
                unsafe covered[idx] = cur | 1u64 << (i & 63) as u64;
                return;
            }
            i = i + 1;
        }
    }
    fn check_match_exhaustive(self: &mut Self, id: NodeId, scrut: TypeId) void {
        if scrut == TYPE_NONE {
            return;
        }
        let a = self.cur_ast();
        let base = self.strip(scrut);
        let mut emod: ModuleId = 0;
        let mut edecl = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        let agok = self.aggregate_of(
            base,
            (&mut emod) as *mut ModuleId,
            (&mut edecl) as *mut NodeId,
            (&gp[0]) as *mut DefId,
            (&ga[0]) as *mut TypeId,
            (&mut gn) as *mut i32,
        );
        let is_enum = agok && unsafe (*self.mod_ast(emod)).at_const(edecl).kind == NodeKind::NODE_ENUM;
        let mut variants = NodeList { start: 0, len: 0 };
        if is_enum {
            variants = unsafe (*self.mod_ast(emod)).at_const(edecl).as_data.aggregate.members;
        }
        let mut covered = Cover4 {};
        let mut catchall = false;
        let mut tcov = false;
        let mut fcov = false;
        let arms = unsafe (*a).at_const(id).as_data.match_expr.arms;
        for i in 0..arms.len {
            let arm = unsafe (*a).at_const(unsafe (*a).list(arms)[i as usize]);
            if arm.as_data.match_arm.guard == NODE_NONE {
                self.match_arm_coverage(
                    arm.as_data.match_arm.pattern,
                    emod,
                    is_enum,
                    variants,
                    (&mut covered[0]) as *mut u64,
                    (&mut catchall) as *mut bool,
                    (&mut tcov) as *mut bool,
                    (&mut fcov) as *mut bool,
                );
            }
        }
        if catchall {
            return;
        }
        let sp = unsafe (*a).at_const(unsafe (*a).at_const(id).as_data.match_expr.value).span;
        if is_enum && variants.len <= MATCH_MAX_VARIANTS {
            let mut nmiss: u32 = 0;
            for k in 0..variants.len {
                if (covered[(k >> 6) as usize] & 1u64 << (k & 63) as u64) == 0 {
                    nmiss = nmiss + 1;
                }
            }
            if nmiss == 0 {
                return;
            }
            let mut s2 = "s".ptr() as *const char;
            if nmiss == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("switch is not exhaustive: missing {} variant{}", nmiss, diag::cstr(s2)),
            );
            self.errors.note(format("match every variant or add a '_' arm"));
            return;
        }
        if base == Ast::builtin(BuiltinType::BT_BOOL) && tcov && fcov {
            return;
        }
        self.errors.emit(sp.start, sp.end - sp.start, format("switch is not exhaustive"));
        self.errors.note(format("add a '_' arm to cover the remaining values"));
    }

    fn check_assignment(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let bd = unsafe (*a).at_const(id).as_data.binary;
        let plain = bd.op == TokenType::Equal;
        let mut ld = DefId { module: 0, node: NODE_NONE };
        if plain && unsafe (*a).at_const(bd.left).kind == NodeKind::NODE_IDENTIFIER {
            ld = unsafe (*a).resolution_def(bd.left);
        }
        let lhs_local = ld.node != NODE_NONE && ld.module == self.ast.module;
        if lhs_local {
            self.tc_init(ld.node);
            self.tc_unmark_move(ld.node);
        }
        let lt = if_ty(lhs_local, self.decl_type_in(ld.module, ld.node), TYPE_NONE);
        let ref_rebind = lt != TYPE_NONE && self.type_at(lt).kind == TypeKind::TYPE_REFERENCE;
        if ref_rebind {
            for i in 0..self.nborrows {
                if self.borrows[i as usize].binding == ld.node {
                    self.borrow_tombstone_at(i);
                }
            }
        }
        let bm = self.borrow_mark();
        let l = self.check_expr(bd.left);
        self.tc_mark_capture_mut(bd.left);
        self.expected = l;
        self.check_expr(bd.right);
        self.tc_mark_move(bd.right);
        if ref_rebind {
            if self.nborrows > bm {
                let region = self.tc_binding_depth(ld.node) as u16;
                let mut k = bm;
                while k < self.nborrows {
                    self.borrows[k as usize].binding = ld.node;
                    self.borrows[k as usize].region = region;
                    k = k + 1;
                }
            } else {
                self.borrow_transfer_ref(bd.right, ld.node);
            }
        }
        if !self.is_assignable(bd.left) {
            let sp = unsafe (*a).at_const(bd.left).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot assign to this expression"));
        } else if self.borrow_conflicting_write(bd.left, id) {
            let sp = unsafe (*a).at_const(bd.left).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot assign to this value while it is borrowed"));
        } else if !self.compatible(l, bd.right) {
            self.err_mismatch(bd.right, l);
        }
        return l;
    }

    fn check_closure(self: &mut Self, id: NodeId, cwant: TypeId) TypeId {
        let a = self.cur_ast();
        let params = unsafe (*a).at_const(id).as_data.closure.params;
        let mut sigp = Tys8 {};
        let mut sigr: TypeId = TYPE_NONE;
        let mut sn: i32 = -1;
        for i in 0..params.len {
            let pid = unsafe (*a).list(params)[i as usize];
            if unsafe (*a).at_const(pid).as_data.parameter.ty != NODE_NONE {
                continue;
            }
            if sn < 0 {
                if cwant != TYPE_NONE && self.type_at(cwant).kind == TypeKind::TYPE_FUNCTION {
                    sn = self.fn_sig(cwant, (&mut sigp[0]) as *mut TypeId, 8, (&mut sigr) as *mut TypeId);
                } else {
                    sn = 0;
                }
            }
            if i as i32 < sn && sigp[i as usize] != TYPE_NONE {
                unsafe (*self.cur_ast()).set_type(pid, sigp[i as usize]);
            } else {
                let psp = unsafe (*a).at_const(pid).span;
                self.errors.emit(
                    psp.start,
                    psp.end - psp.start,
                    format("closure parameter needs a type annotation (no expected function type supplies one)"),
                );
                self.errors.note(
                    format("annotate it (`|x: i32| ..`) or bind the closure where a 'fn' type is expected"),
                );
            }
        }
        for i in 0..params.len {
            self.decl_type(unsafe (*a).list(params)[i as usize]);
        }
        if self.nclos >= 8 {
            let sp = unsafe (*a).at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("closures nested too deeply (max 8)"));
            return TYPE_NONE;
        }
        let cn = self.nclos;
        self.clos_stack[cn as usize] = id;
        self.nclos = cn + 1;
        let saved_lf = self.loop_floor;
        self.loop_floor = self.nloops;
        if unsafe (*a).at_const(id).as_data.closure.expr_body {
            self.check_expr(unsafe (*a).at_const(id).as_data.closure.body);
            self.tc_capture_move_guard(unsafe (*a).at_const(id).as_data.closure.body);
        } else {
            let saved = self.current_returns;
            self.current_returns = unsafe (*a).at_const(id).as_data.closure.returns;
            self.check_stmt(unsafe (*a).at_const(id).as_data.closure.body);
            self.current_returns = saved;
        }
        self.loop_floor = saved_lf;
        self.nclos = self.nclos - 1;
        // capture validation
        let caps = unsafe (*a).at_const(id).as_data.closure.captures;
        let mut_caps = (unsafe (*a).at_const(id).as_data.closure.mut_caps) as u64;
        for i in 0..caps.len {
            let cid = unsafe (*a).list(caps)[i as usize];
            let cty = self.decl_type(cid);
            let is_mut = (mut_caps >> i as u64 & 1u64) != 0;
            if cty != TYPE_NONE && !is_mut && self.type_at(cty).kind == TypeKind::TYPE_ARRAY {
                let sp = unsafe (*a).at_const(id).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("closure cannot capture a fixed-size array by copy; capture a slice instead"),
                );
                continue;
            }
            if cty == TYPE_NONE || is_mut || !self.tc_type_is_free(cty) {
                continue;
            }
            if self.is_moved(cid) {
                let sp = unsafe (*a).at_const(id).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("closure captures a moved value (use of moved value)"),
                );
            }
            for f in 0..self.nclos {
                if self.tc_capture_index(self.clos_stack[f as usize], cid) >= 0 {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot take ownership of a value also captured by an enclosing closure"),
                    );
                    break;
                }
            }
            for b in 0..self.nborrows {
                if self.borrows[b as usize].root == cid {
                    if self.borrow_dead_after(self.borrows[b as usize], id) {
                        self.borrow_tombstone_at(b);
                    } else {
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("cannot capture this value while it is borrowed"),
                        );
                        break;
                    }
                }
            }
            if self.nmoved < 1024 {
                let k = self.nmoved;
                self.moved[k as usize] = cid;
                self.nmoved = k + 1;
                self.ms_bit_set(cid);
            }
        }
        return unsafe (*self.cur_ast()).intern_type(
            Ty { kind: TypeKind::TYPE_FUNCTION, module: self.ast.module, as_data: TyAs { decl: id } },
        );
    }

    fn check_index(self: &mut Self, id: NodeId, addr_ctx: bool, place_use: bool) TypeId {
        let a = self.cur_ast();
        let obj_n = unsafe (*a).at_const(id).as_data.index.object;
        let index_n = unsafe (*a).at_const(id).as_data.index.index;
        self.addr_ctx = addr_ctx;
        self.place_use = !addr_ctx;
        let mut obj = self.check_expr(obj_n);
        if !addr_ctx && !place_use && self.borrow_conflicting_read(id) {
            let sp = unsafe (*a).at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("cannot use this value while it is mutably borrowed"));
        }
        if self.type_at(obj).kind == TypeKind::TYPE_REFERENCE {
            let mut p = obj;
            let mut y = *self.type_at(p);
            while y.kind == TypeKind::TYPE_REFERENCE {
                p = y.as_data.elem;
                y = *self.type_at(p);
            }
            if y.kind != TypeKind::TYPE_ARRAY {
                obj = p;
            }
        }
        let ot = *self.type_at(obj);
        let idxn_kind = unsafe (*a).at_const(index_n).kind;
        if idxn_kind == NodeKind::NODE_RANGE {
            let mut elem = TYPE_NONE;
            let mut selem: TypeId = TYPE_NONE;
            let mut user_result = TYPE_NONE;
            if ot.kind == TypeKind::TYPE_ARRAY || ot.kind == TypeKind::TYPE_POINTER {
                if ot.kind == TypeKind::TYPE_POINTER && self.tc_needs_unsafe() {
                    self.err_unsafe(unsafe (*a).at_const(obj_n).span, "slicing a raw pointer");
                }
                elem = ot.as_data.elem;
            } else if self.slice_kind(obj, (&mut selem) as *mut TypeId) != 0 {
                elem = selem;
            } else if ot.kind == TypeKind::TYPE_STRUCT || ot.kind == TypeKind::TYPE_INSTANCE {
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                let mut gp = Defs8 {};
                let mut ga = Tys8 {};
                let mut gn: i32 = 0;
                let sp = unsafe (*a).at_const(obj_n).span;
                if self.aggregate_of(
                    self.strip(obj),
                    (&mut om) as *mut ModuleId,
                    (&mut od) as *mut NodeId,
                    (&gp[0]) as *mut DefId,
                    (&ga[0]) as *mut TypeId,
                    (&mut gn) as *mut i32,
                ) {
                    let md = self.find_method_cstr(om, od, "index_range");
                    if md.node == NODE_NONE {
                        let mut ty = Buf96 {};
                        self.render_type(self.strip(obj), &mut ty[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("'{}' has no 'index_range' method for '[..]'", diag::cstr(&ty[0])),
                        );
                    } else if !self.method_extend_bounds_hold(self.strip(obj), md) {
                        self.err_method_extend_bounds(sp, self.strip(obj), md);
                    } else {
                        if unsafe (*a).at_const(index_n).as_data.pattern_range.end == NODE_NONE && self.find_method_cstr(
                            om,
                            od,
                            "len",
                        ).node == NODE_NONE {
                            let mut ty = Buf96 {};
                            self.render_type(self.strip(obj), &mut ty[0], 96);
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format(
                                    "an open-ended range index needs a 'len' method on '{}' to supply the end",
                                    diag::cstr(&ty[0]),
                                ),
                            );
                        }
                        self.prelude_range_type(Ast::builtin(BuiltinType::BT_USIZE));
                        user_result = self.tc_method_ret(self.strip(obj), md);
                    }
                }
            } else if obj != TYPE_NONE {
                let sp = unsafe (*a).at_const(obj_n).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("cannot slice this expression"));
            }
            let bstart = unsafe (*a).at_const(index_n).as_data.pattern_range.start;
            let bend = unsafe (*a).at_const(index_n).as_data.pattern_range.end;
            if bstart != NODE_NONE {
                let bt = self.check_expr(bstart);
                if bt != TYPE_NONE && !self.is_int(bt) && unsafe (*a).at_const(bstart).kind != NodeKind::NODE_LITERAL {
                    let sp = unsafe (*a).at_const(bstart).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("range bound must be an integer"));
                }
            }
            if bend != NODE_NONE {
                let bt = self.check_expr(bend);
                if bt != TYPE_NONE && !self.is_int(bt) && unsafe (*a).at_const(bend).kind != NodeKind::NODE_LITERAL {
                    let sp = unsafe (*a).at_const(bend).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("range bound must be an integer"));
                }
            }
            if user_result != TYPE_NONE {
                return user_result;
            }
            if elem != TYPE_NONE {
                return self.prelude_slice_type(elem, false);
            }
            return TYPE_NONE;
        }
        let idx = self.check_expr(index_n);
        let mut overloaded = false;
        let mut result = TYPE_NONE;
        if obj != TYPE_NONE {
            let mut selem: TypeId = TYPE_NONE;
            if ot.kind == TypeKind::TYPE_ARRAY || ot.kind == TypeKind::TYPE_POINTER {
                if ot.kind == TypeKind::TYPE_POINTER && self.tc_needs_unsafe() {
                    self.err_unsafe(unsafe (*a).at_const(obj_n).span, "indexing a raw pointer");
                }
                result = ot.as_data.elem;
            } else if self.slice_kind(obj, (&mut selem) as *mut TypeId) != 0 {
                result = selem;
            } else if ot.kind == TypeKind::TYPE_STRUCT || ot.kind == TypeKind::TYPE_INSTANCE {
                overloaded = true;
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                let mut gp = Defs8 {};
                let mut ga = Tys8 {};
                let mut gn: i32 = 0;
                let sp = unsafe (*a).at_const(obj_n).span;
                if self.aggregate_of(
                    self.strip(obj),
                    (&mut om) as *mut ModuleId,
                    (&mut od) as *mut NodeId,
                    (&gp[0]) as *mut DefId,
                    (&ga[0]) as *mut TypeId,
                    (&mut gn) as *mut i32,
                ) {
                    let md = self.find_method_cstr(om, od, "index");
                    if md.node == NODE_NONE {
                        let mut ty = Buf96 {};
                        self.render_type(self.strip(obj), &mut ty[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("'{}' has no 'index' method for '[]'", diag::cstr(&ty[0])),
                        );
                    } else if !self.method_extend_bounds_hold(self.strip(obj), md) {
                        self.err_method_extend_bounds(sp, self.strip(obj), md);
                        result = TYPE_NONE;
                    } else {
                        let p1 = self.tc_method_param(self.strip(obj), md, 1);
                        if !self.operand_fits_param(p1, index_n) {
                            self.err_mismatch(index_n, p1);
                        }
                        result = self.tc_method_ret(self.strip(obj), md);
                        if result != TYPE_NONE && self.type_at(result).kind == TypeKind::TYPE_REFERENCE {
                            result = self.type_at(result).as_data.elem;
                        }
                    }
                }
            } else {
                let sp = unsafe (*a).at_const(obj_n).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("cannot index this expression"));
            }
        }
        if !overloaded && idx != TYPE_NONE && !self.is_int(idx) && unsafe (*a).at_const(index_n).kind != NodeKind::NODE_LITERAL {
            let sp = unsafe (*a).at_const(index_n).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("index must be an integer"));
        }
        return result;
    }

    fn check_match_expr(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let bm = self.borrow_mark();
        let scrut = self.check_expr(unsafe (*a).at_const(id).as_data.match_expr.value);
        let sy = *self.type_at(scrut);
        let mut bind_ref: i32 = 0;
        if sy.kind == TypeKind::TYPE_REFERENCE || sy.kind == TypeKind::TYPE_POINTER {
            if sy.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                bind_ref = 2;
            } else {
                bind_ref = 1;
            }
        }
        if bind_ref == 0 {
            self.borrow_release_to(bm);
            self.tc_mark_move(unsafe (*a).at_const(id).as_data.match_expr.value);
        }
        let arms = unsafe (*a).at_const(id).as_data.match_expr.arms;
        let mut first = true;
        let mut ovf = false;
        let mut mpre: FlowState;
        self.tc_flow_save(&mut mpre);
        let mut acc: FlowState;
        self.tc_flow_clear(&mut acc);
        let mut result = TYPE_NONE;
        for i in 0..arms.len {
            let aid = unsafe (*a).list(arms)[i as usize];
            let arm = unsafe (*a).at_const(aid).as_data.match_arm;
            self.tc_flow_set(&mpre);
            self.check_pattern(arm.pattern, scrut, bind_ref);
            let g = self.check_expr(arm.guard);
            if arm.guard != NODE_NONE && g != TYPE_NONE && !self.is_bool(g) {
                let sp = unsafe (*a).at_const(arm.guard).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("match guard must be 'bool'"));
            }
            let body = self.check_expr(arm.body);
            if self.tc_flow_collect((&mut acc) as *mut FlowState) {
                ovf = true;
            }
            let body_never = body != TYPE_NONE && self.type_at(body).kind == TypeKind::TYPE_NEVER;
            if first {
                result = body;
                first = false;
            } else if result != TYPE_NONE && self.type_at(result).kind == TypeKind::TYPE_NEVER {
                result = body;
            } else if !body_never && result != body && body != TYPE_NONE && result != TYPE_NONE {
                self.err_mismatch(arm.body, result);
                result = TYPE_NONE;
            }
        }
        if arms.len != 0 {
            self.tc_flow_set(&acc);
        }
        if ovf {
            self.tc_flow_overflow(id);
        }
        self.borrow_release_to(bm);
        self.check_match_exhaustive(id, scrut);
        return result;
    }

    fn check_expr(self: &mut Self, id: NodeId) TypeId {
        if id == NODE_NONE {
            return TYPE_NONE;
        }
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(id).kind;
        let expected = self.expected;
        self.expected = TYPE_NONE;
        let addr_ctx = self.addr_ctx;
        self.addr_ctx = false;
        let place_use = self.place_use;
        self.place_use = false;
        let mut result = TYPE_NONE;
        switch nk {
            NODE_LITERAL => {
                result = self.check_literal(id);
            },
            NODE_IDENTIFIER => {
                let d = unsafe (*a).resolution_def(id);
                result = self.decl_type_in(d.module, d.node);
                if d.node != NODE_NONE && unsafe (*self.mod_ast(d.module)).at_const(d.node).kind == NodeKind::NODE_FUNCTION {
                    self.tc_check_test_ref(d, unsafe (*a).at_const(id).span);
                }
                if d.module == self.ast.module && d.node != NODE_NONE {
                    if self.is_moved(d.node) {
                        let mut freed = false;
                        for k in 0..self.nfreed {
                            if self.freed[k as usize] == d.node {
                                freed = true;
                            }
                        }
                        let sp = unsafe (*a).at_const(id).span;
                        let mut msg = "use of moved value".ptr() as *const char;
                        if freed {
                            msg = "use after free".ptr() as *const char;
                        }
                        self.errors.emit(sp.start, sp.end - sp.start, format("{}", diag::cstr(msg)));
                    }
                    if !addr_ctx && self.tc_is_uninit(d.node) {
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(sp.start, sp.end - sp.start, format("use of possibly uninitialized value"));
                    }
                    if !addr_ctx && !place_use && self.borrow_conflicting_read(id) {
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("cannot use this value while it is mutably borrowed"),
                        );
                    }
                }
            },
            NODE_UNARY => {
                result = self.check_unary(id);
                if unsafe (*a).at_const(id).as_data.unary.op == TokenType::Star && !addr_ctx && !place_use && self.borrow_conflicting_read(
                    id,
                ) {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot use this value while it is mutably borrowed"),
                    );
                }
            },
            NODE_BINARY => {
                result = self.check_binary(id);
            },
            NODE_ASSIGNMENT => {
                result = self.check_assignment(id);
            },
            NODE_CALL => {
                result = self.check_call(id, expected);
            },
            NODE_CLOSURE => {
                result = self.check_closure(id, expected);
            },
            NODE_INDEX => {
                result = self.check_index(id, addr_ctx, place_use);
            },
            NODE_MEMBER => {
                let value_read = !unsafe (*a).at_const(id).as_data.member.path && !addr_ctx;
                self.addr_ctx = addr_ctx;
                self.place_use = value_read;
                if unsafe (*a).at_const(id).as_data.member.path {
                    result = self.check_path_member(id, expected);
                } else {
                    self.expected = expected;
                    result = self.check_member(id, false);
                }
                if value_read && !place_use && self.borrow_conflicting_read(id) {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot use this value while it is mutably borrowed"),
                    );
                }
            },
            NODE_CAST => {
                let src = self.check_expr(unsafe (*a).at_const(id).as_data.cast.expression);
                let dst = self.resolve_type(unsafe (*a).at_const(id).as_data.cast.ty);
                if self.lint && src != TYPE_NONE && src == dst && unsafe (*a).at_const(
                    unsafe (*a).at_const(id).as_data.cast.expression,
                ).kind != NodeKind::NODE_LITERAL {
                    let csp = unsafe (*a).at_const(id).span;
                    self.errors.warn(
                        csp.start,
                        csp.end - csp.start,
                        format("unnecessary cast: the expression already has this type"),
                    );
                    // Delete ` as T`. Grouping parens are dropped without re-spanning, so skip the
                    // fix if a ')' sits between the expression end and the cast end (`(x) as T`).
                    let esp = unsafe (*a).at_const(unsafe (*a).at_const(id).as_data.cast.expression).span;
                    let mut fixable = esp.end < csp.end && esp.start >= csp.start;
                    let mut j = esp.end;
                    while fixable && j < csp.end && self.source[j as usize] != b'a' {
                        if self.source[j as usize] == b')' {
                            fixable = false;
                        }
                        j = j + 1;
                    }
                    if fixable {
                        self.errors.fix(esp.end, csp.end, 0);
                    }
                }
                if src != TYPE_NONE && dst != TYPE_NONE && src != dst {
                    let sk = self.type_at(src).kind;
                    let dk = self.type_at(dst).kind;
                    let aggregate = sk == TypeKind::TYPE_STRUCT || sk == TypeKind::TYPE_ENUM || sk == TypeKind::TYPE_FUNCTION || dk == TypeKind::TYPE_STRUCT || dk == TypeKind::TYPE_ENUM || dk == TypeKind::TYPE_FUNCTION;
                    let enum_int = self.is_plain_enum(src) && self.is_int(dst) || self.is_plain_enum(dst) && self.is_int(
                        src,
                    );
                    let complex_lossy = sk == TypeKind::TYPE_BUILTIN && bt_is_complex(self.type_at(src).as_data.builtin) && dk == TypeKind::TYPE_BUILTIN && !bt_is_complex(
                        self.type_at(dst).as_data.builtin,
                    );
                    if aggregate && !enum_int || complex_lossy {
                        let mut s = Buf96 {};
                        let mut d = Buf96 {};
                        self.render_type(src, &mut s[0], 96);
                        self.render_type(dst, &mut d[0], 96);
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("invalid cast from '{}' to '{}'", diag::cstr(&s[0]), diag::cstr(&d[0])),
                        );
                    }
                }
                result = dst;
            },
            NODE_SIZEOF | NODE_ALIGNOF => {
                let v = unsafe (*a).at_const(id).as_data.single.value;
                let d = unsafe (*a).resolution_def(v);
                let mut dk = NodeKind::NODE_NONE_KIND;
                if d.node != NODE_NONE && d.module == self.ast.module {
                    dk = unsafe (*a).at_const(d.node).kind;
                }
                if dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_FOR || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_PATTERN_NAME || dk == NodeKind::NODE_CONST {
                    let vt = unsafe (*a).type_of(d.node);
                    if vt == TYPE_NONE {
                        let vsp = unsafe (*a).at_const(v).span;
                        self.errors.emit(
                            vsp.start,
                            vsp.end - vsp.start,
                            format("cannot take the size of this value here"),
                        );
                    }
                    unsafe (*self.cur_ast()).set_type(v, vt);
                } else {
                    self.resolve_type(v);
                }
                result = Ast::builtin(BuiltinType::BT_USIZE);
            },
            NODE_VA_EXPR => {
                let vo = unsafe (*a).at_const(id).as_data.va_op;
                if vo.op == VA_START && unsafe (*a).at_const(vo.ap).kind == NodeKind::NODE_IDENTIFIER {
                    let d = unsafe (*a).resolution_def(vo.ap);
                    if d.module == self.ast.module && d.node != NODE_NONE {
                        self.tc_init(d.node);
                    }
                }
                let apt = self.check_expr(vo.ap);
                if apt != TYPE_NONE {
                    let ay = *self.type_at(apt);
                    if !(ay.kind == TypeKind::TYPE_BUILTIN && ay.as_data.builtin == BuiltinType::BT_VALIST) {
                        let sp = unsafe (*a).at_const(vo.ap).span;
                        let mut ty = Buf96 {};
                        self.render_type(apt, &mut ty[0], 96);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("expected a 'va_list', found '{}'", diag::cstr(&ty[0])),
                        );
                    }
                }
                if vo.op == VA_ARG {
                    result = self.resolve_type(vo.extra);
                } else {
                    if vo.op == VA_START {
                        self.check_expr(vo.extra);
                    }
                    result = Ast::builtin(BuiltinType::BT_VOID);
                }
            },
            NODE_GENERIC_SPECIALIZATION => {
                let inner = unsafe (*a).at_const(id).as_data.specialization.expression;
                let types = unsafe (*a).at_const(id).as_data.specialization.types;
                // A literal arg is a const-generic value: cache its TYPE_CONST so both the
                // aggregate instance below and fn-turbofish binding (type_of) see it.
                for i in 0..types.len {
                    let tid = unsafe (*a).list(types)[i as usize];
                    if unsafe (*a).at_const(tid).kind == NodeKind::NODE_LITERAL {
                        unsafe (*self.cur_ast()).set_type(tid, self.tc_const_arg(self.ast.module, tid));
                    } else {
                        self.resolve_type(tid);
                    }
                }
                let d = unsafe (*a).resolution_def(inner);
                let mut is_agg = false;
                if d.node != NODE_NONE {
                    let dn = unsafe (*self.mod_ast(d.module)).at_const(d.node);
                    is_agg = (dn.kind == NodeKind::NODE_ENUM || dn.kind == NodeKind::NODE_STRUCT) && dn.as_data.aggregate.generics.len > 0 && types.len > 0;
                }
                if is_agg {
                    if types.len > 8 {
                        let sp = unsafe (*a).at_const(id).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("too many generic arguments ({}; the maximum is 8)", types.len),
                        );
                    }
                    let mut ta = Tys8 {};
                    let mut tn: u8 = 0;
                    let mut j: u32 = 0;
                    while j < types.len && tn < 8 {
                        let tj = unsafe (*a).list(types)[j as usize];
                        ta[tn as usize] = if unsafe (*a).at_const(tj).kind == NodeKind::NODE_LITERAL {
                            unsafe (*a).type_of(tj);
                        } else {
                            self.resolve_type(tj);
                        };
                        tn = tn + 1;
                        j = j + 1;
                    }
                    self.apply_default_args(d.module, d.node, (&mut ta[0]) as *mut TypeId, (&mut tn) as *mut u8);
                    result = unsafe (*self.cur_ast()).intern_instance(d.module, d.node, (&ta[0]) as *const TypeId, tn);
                } else {
                    result = self.check_expr(inner);
                }
            },
            NODE_MATCH => {
                result = self.check_match_expr(id);
            },
            NODE_NEW => {
                let declared = self.resolve_type(unsafe (*a).at_const(id).as_data.new_expr.ty);
                let mut inner = declared;
                let init = unsafe (*a).at_const(id).as_data.new_expr.initializer;
                if init != NODE_NONE {
                    let it = self.check_expr(init);
                    if unsafe (*a).at_const(init).kind == NodeKind::NODE_STRUCT_INITIALIZER {
                        inner = it;
                    } else if !self.compatible(declared, init) {
                        self.err_mismatch(init, declared);
                    }
                }
                result = unsafe (*self.cur_ast()).intern_type(
                    Ty {
                        kind: TypeKind::TYPE_POINTER,
                        qualifier: TypeQualifier::TYPE_QUAL_MUT as u8,
                        as_data: TyAs { elem: inner },
                    },
                );
            },
            NODE_ARRAY_LITERAL => {
                result = self.check_array_literal(id);
            },
            NODE_STRUCT_INITIALIZER => {
                result = self.check_struct_init(id);
            },
            NODE_BLOCK => {
                result = self.check_block_value(id);
            },
            NODE_WHILE => {
                self.loop_depth = self.loop_depth + 1;
                let le = self.tc_loop_push(tok::Span { start: 0, end: 0 }, id, true);
                self.check_loop_body(unsafe (*a).at_const(id).as_data.while_stmt.body);
                if le >= 0 {
                    result = self.loop_stack[le as usize].break_ty;
                    self.tc_loop_pop(le, unsafe (*a).at_const(id).span);
                }
                if result == TYPE_NONE {
                    result = unsafe (*self.cur_ast()).intern_type(Ty { kind: TypeKind::TYPE_NEVER });
                }
                self.loop_depth = self.loop_depth - 1;
            },
            NODE_IF => {
                result = self.check_if_value(id);
            },
            NODE_TUPLE => {
                result = self.check_tuple_value(id, expected);
            },
            NODE_RANGE => {
                let s = self.check_expr(unsafe (*a).at_const(id).as_data.pattern_range.start);
                let e = self.check_expr(unsafe (*a).at_const(id).as_data.pattern_range.end);
                let elem = self.range_type(id, s, e);
                if unsafe (*a).at_const(id).as_data.pattern_range.start == NODE_NONE || unsafe (*a).at_const(id).as_data.pattern_range.end == NODE_NONE {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(sp.start, sp.end - sp.start, format("a range value needs both a start and an end"));
                } else {
                    result = if_ty(elem != TYPE_NONE, self.prelude_range_type(elem), TYPE_NONE);
                }
            },
            _ => {},
        };
        unsafe (*self.cur_ast()).set_type(id, result);
        return result;
    }

    fn check_literal(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let tt = unsafe (*a).at_const(id).as_data.literal.token_type;
        let lr = unsafe (*a).at_const(id).as_data.literal.raw;
        if tt == TokenType::IntegerLiteral {
            let mut sfx = lr.end;
            let sb = unsafe ast_numeric_suffix(self.source, lr.start, lr.end, (&mut sfx) as *mut u32);
            let mut result = Ast::builtin(BuiltinType::BT_I32);
            if sb != BuiltinType::BT_COUNT {
                result = Ast::builtin(sb);
            }
            let mut p = unsafe (self.source.ptr() + lr.start as usize);
            let mut len = (sfx - lr.start) as usize;
            let (base, skip) = lit_base_prefix(p, len);
            p = unsafe (p + skip);
            len = len - skip;
            let mut acc: u64 = 0;
            let mut overflow = false;
            let mut i: usize = 0;
            while i < len && !overflow {
                let ch = unsafe p[i];
                if ch == b'_' {
                    i = i + 1;
                    continue;
                }
                let mut d: u64 = 0;
                if ch <= b'9' {
                    d = (ch - b'0') as u64;
                } else {
                    d = ((ch | 0x20u8) - b'a' + 10u8) as u64;
                }
                if acc > (0xFFFFFFFFFFFFFFFFu64 - d) / base {
                    overflow = true;
                } else {
                    acc = acc * base + d;
                }
                i = i + 1;
            }
            let sp = unsafe (*a).at_const(id).span;
            if overflow {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("integer literal is too large to fit in a 64-bit integer"),
                );
            } else if sb != BuiltinType::BT_COUNT && bt_int_max(sb) != 0 && acc > bt_int_max(sb) {
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("integer literal does not fit in its suffixed type"),
                );
            }
            return result;
        }
        if tt == TokenType::FloatLiteral {
            let sb = unsafe ast_numeric_suffix(self.source, lr.start, lr.end, null);
            if sb == BuiltinType::BT_F64 {
                return Ast::builtin(BuiltinType::BT_F64);
            }
            return Ast::builtin(BuiltinType::BT_F32);
        }
        if tt == TokenType::CharacterLiteral {
            if self.char_literal_cp(lr) > 0xFF {
                let sp = unsafe (*a).at_const(id).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("character literal does not fit in 'char' (one byte); use a string or an integer"),
                );
            }
            return Ast::builtin(BuiltinType::BT_CHAR);
        }
        if tt == TokenType::ByteCharacterLiteral {
            return Ast::builtin(BuiltinType::BT_U8);
        }
        if tt == TokenType::True || tt == TokenType::False {
            return Ast::builtin(BuiltinType::BT_BOOL);
        }
        if tt == TokenType::StringLiteral || tt == TokenType::RawStringLiteral {
            return self.prelude_str_type();
        }
        if tt == TokenType::ByteStringLiteral {
            return self.prelude_slice_type(Ast::builtin(BuiltinType::BT_U8), false);
        }
        return TYPE_NONE;
    }

    fn check_array_literal(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let elements = unsafe (*a).at_const(id).as_data.array_literal.elements;
        if elements.len == 0 {
            let sp = unsafe (*a).at_const(id).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("cannot infer the element type of an empty array literal"),
            );
            return TYPE_NONE;
        }
        let mut elem = TYPE_NONE;
        for i in 0..elements.len {
            let eid = unsafe (*a).list(elements)[i as usize];
            let el = unsafe (*a).at_const(eid);
            let mut et = TYPE_NONE;
            if el.kind == NodeKind::NODE_FIELD_INITIALIZER {
                let it = self.check_expr(el.as_data.field_initializer.name);
                if it != TYPE_NONE {
                    let iy = *self.type_at(it);
                    if !(iy.kind == TypeKind::TYPE_BUILTIN && (bt_is_int(iy.as_data.builtin) || iy.as_data.builtin == BuiltinType::BT_CHAR)) {
                        let sp = unsafe (*a).at_const(el.as_data.field_initializer.name).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("array designator index must be an integer"),
                        );
                    } else {
                        let ceptr = self.ceval();
                        if ceptr != null && unsafe (*ceptr).eval(self.ast.module, el.as_data.field_initializer.name).kind == ce::CONST_NONE {
                            let sp = unsafe (*a).at_const(el.as_data.field_initializer.name).span;
                            self.errors.emit(
                                sp.start,
                                sp.end - sp.start,
                                format("array designator index must be a constant expression"),
                            );
                        }
                    }
                }
                et = self.check_expr(el.as_data.field_initializer.value);
            } else {
                et = self.check_expr(eid);
            }
            if i == 0 {
                elem = et;
            } else if et != elem && et != TYPE_NONE && elem != TYPE_NONE {
                let e0 = self.type_at(elem).kind;
                let ei = self.type_at(et).kind;
                if !(e0 == TypeKind::TYPE_FUNCTION && ei == TypeKind::TYPE_FUNCTION && self.fn_compatible(elem, et)) {
                    self.err_mismatch(eid, elem);
                    elem = TYPE_NONE;
                }
            }
        }
        if elem != TYPE_NONE {
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_ARRAY, as_data: TyAs { arr: TyArr { elem: elem, len: 0 } } },
            );
        }
        return TYPE_NONE;
    }

    fn check_block_value(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let stmts = unsafe (*a).at_const(id).as_data.block.statements;
        self.tc_scope_enter();
        for i in 0..stmts.len {
            let sid = unsafe (*a).list(stmts)[i as usize];
            self.check_stmt(sid);
            self.borrow_nll_drop(id, unsafe (*a).list(stmts), i);
        }
        while self.ndefers != 0 && self.defer_depth[(self.ndefers - 1) as usize] == self.scope_depth {
            self.ndefers = self.ndefers - 1;
            let dv = self.defer_stack[self.ndefers as usize];
            let dbm = self.borrow_mark();
            self.check_expr(dv);
            self.borrow_release_to(dbm);
        }
        self.tc_scope_exit();
        if stmts.len > 0 {
            let lastid = unsafe (*a).list(stmts)[(stmts.len - 1) as usize];
            let last = unsafe (*a).at_const(lastid);
            let lv = if_node(last.kind == NodeKind::NODE_EXPRESSION_STATEMENT, last.as_data.single.value, NODE_NONE);
            if lv != NODE_NONE && unsafe (*a).at_const(lv).kind != NodeKind::NODE_ASSIGNMENT {
                return unsafe (*a).type_of(lv);
            }
            return Ast::builtin(BuiltinType::BT_VOID);
        }
        return Ast::builtin(BuiltinType::BT_VOID);
    }

    fn check_if_value(self: &mut Self, id: NodeId) TypeId {
        let a = self.cur_ast();
        let ifd = unsafe (*a).at_const(id).as_data.if_stmt;
        let bm = self.borrow_mark();
        let c = self.check_expr(ifd.condition);
        if c != TYPE_NONE && !self.is_bool(c) {
            let sp = unsafe (*a).at_const(ifd.condition).span;
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("if condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
        }
        self.borrow_release_to(bm);
        let mut ifpre: FlowState;
        self.tc_flow_save(&mut ifpre);
        let then_ty = self.check_expr(ifd.then_branch);
        if ifd.else_branch == NODE_NONE {
            let sp = unsafe (*a).at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("an 'if' used as a value must have an 'else' branch"));
            return TYPE_NONE;
        }
        let mut acc: FlowState;
        self.tc_flow_clear(&mut acc);
        let mut ovf = self.tc_flow_collect((&mut acc) as *mut FlowState);
        self.tc_flow_set(&ifpre);
        let else_ty = self.check_expr(ifd.else_branch);
        if self.tc_flow_collect((&mut acc) as *mut FlowState) {
            ovf = true;
        }
        self.tc_flow_set(&acc);
        if ovf {
            self.tc_flow_overflow(id);
        }
        let then_never = then_ty != TYPE_NONE && self.type_at(then_ty).kind == TypeKind::TYPE_NEVER;
        let else_never = else_ty != TYPE_NONE && self.type_at(else_ty).kind == TypeKind::TYPE_NEVER;
        if then_never || else_never {
            return if_ty(then_never, else_ty, then_ty);
        }
        if then_ty != else_ty && then_ty != TYPE_NONE && else_ty != TYPE_NONE {
            self.err_mismatch(ifd.else_branch, then_ty);
            return TYPE_NONE;
        }
        return then_ty;
    }

    fn check_tuple_value(self: &mut Self, id: NodeId, expected: TypeId) TypeId {
        let a = self.cur_ast();
        let elems = unsafe (*a).at_const(id).as_data.array_literal.elements;
        if elems.len > 4 {
            let sp = unsafe (*a).at_const(id).span;
            self.errors.emit(sp.start, sp.end - sp.start, format("tuple arity is limited to 4 elements"));
            return TYPE_NONE;
        }
        let mut wargs = Tys8 {};
        let mut wn: i32 = -1;
        if expected != TYPE_NONE {
            wn = self.tuple_args_of(self.strip(expected), (&mut wargs[0]) as *mut TypeId, 4);
        }
        let mut targs = Tys8 {};
        for i in 0..elems.len {
            let eid = unsafe (*a).list(elems)[i as usize];
            let et = self.check_expr(eid);
            targs[i as usize] = et;
            if i as i32 < wn && et != wargs[i as usize] && self.compatible(wargs[i as usize], eid) {
                targs[i as usize] = wargs[i as usize];
                unsafe (*self.cur_ast()).set_type(eid, wargs[i as usize]);
            }
            self.tc_mark_move(eid);
        }
        return self.prelude_tuple_type((&targs[0]) as *const TypeId, elems.len);
    }

    fn check_loop_body(self: &mut Self, body: NodeId) void {
        let nm0 = self.nmoved;
        let nb0 = self.nborrows;
        self.check_stmt(body);
        if (self.nmoved > nm0 || self.nborrows > nb0) && !self.in_loop_recheck {
            self.in_loop_recheck = true;
            self.check_stmt(body);
            self.in_loop_recheck = false;
        }
    }

    fn check_tuple_let(self: &mut Self, id: NodeId) void {
        let a = self.cur_ast();
        let value = unsafe (*a).at_const(id).as_data.let_stmt.value;
        let nm = unsafe (*a).at_const(id).as_data.let_stmt.name;
        let names = unsafe (*a).at_const(nm).as_data.pattern.children;
        self.mret_call = NODE_NONE;
        self.check_expr(value);
        let stashed = value != NODE_NONE && self.mret_call == value;
        let mut targs = Tys8 {};
        let mut tn: i32 = -1;
        if !stashed && value != NODE_NONE {
            tn = self.tuple_args_of(self.strip(unsafe (*a).type_of(value)), (&mut targs[0]) as *mut TypeId, 4);
            if tn >= 0 {
                self.tc_mark_move(value);
            }
        }
        let mut returns = NodeList { start: 0, len: 0 };
        let mut ok = false;
        if value != NODE_NONE && unsafe (*a).at_const(value).kind == NodeKind::NODE_CALL {
            let calleeId = unsafe (*a).at_const(value).as_data.call.callee;
            let callee = unsafe (*a).type_of(calleeId);
            if callee != TYPE_NONE {
                let ct = *self.type_at(callee);
                if ct.kind == TypeKind::TYPE_FUNCTION {
                    let fnn = unsafe (*self.mod_ast(ct.module)).at_const(ct.as_data.decl);
                    returns = if_nl(
                        fnn.kind == NodeKind::NODE_FUNCTION,
                        fnn.as_data.function.returns,
                        fnn.as_data.function_type.returns,
                    );
                    ok = true;
                }
            } else {
                let cn = unsafe (*a).at_const(calleeId);
                if cn.kind == NodeKind::NODE_MEMBER {
                    let md = unsafe (*a).resolution_def(cn.as_data.member.member);
                    if md.node != NODE_NONE && md.module == self.ast.module && unsafe (*self.mod_ast(md.module)).at_const(
                        md.node,
                    ).kind == NodeKind::NODE_FUNCTION {
                        returns = unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.returns;
                        ok = true;
                    }
                }
            }
        }
        if !ok && !stashed && tn < 0 {
            let sp = unsafe (*a).at_const(id).span;
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("a tuple binding requires a multi-value function call or a tuple value"),
            );
            return;
        }
        let nret = if_u32(stashed, self.mret_total, if_u32(tn >= 0, tn as u32, returns.len));
        if names.len != nret {
            let sp = unsafe (*a).at_const(id).span;
            let mut s1 = "s".ptr() as *const char;
            if names.len == 1 {
                s1 = "".ptr() as *const char;
            }
            let mut s2 = "s".ptr() as *const char;
            if nret == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format(
                    "expected {} binding{}, the call returns {} value{}",
                    names.len,
                    diag::cstr(s1),
                    nret,
                    diag::cstr(s2),
                ),
            );
        }
        for i in 0..names.len {
            let mut et = TYPE_NONE;
            if stashed && i < self.mret_n as u32 {
                et = self.mret_types[i as usize];
            } else if tn >= 0 {
                et = if_ty(i < tn as u32, targs[i as usize], TYPE_NONE);
            } else if i < returns.len {
                let r0 = unsafe (*self.cur_ast()).list(returns)[i as usize];
                let rn = unsafe (*self.cur_ast()).at_const(r0);
                et = self.resolve_type(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
            }
            unsafe (*self.cur_ast()).set_type(unsafe (*self.cur_ast()).list(names)[i as usize], et);
        }
    }

    fn check_return(self: &mut Self, id: NodeId) void {
        let a = self.cur_ast();
        let values = unsafe (*a).at_const(id).as_data.return_stmt.values;
        let rets = self.current_returns;
        let returns_void = self.return_list_is_explicit_void(rets);
        if values.len == 1 && !returns_void && rets.len == 1 {
            let r0 = unsafe (*a).list(rets)[0];
            let rn = unsafe (*a).at_const(r0);
            self.expected = self.resolve_type(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
        }
        for i in 0..values.len {
            let vid = unsafe (*a).list(values)[i as usize];
            self.check_expr(vid);
            self.tc_capture_move_guard(vid);
        }
        for i in 0..values.len {
            let vid = unsafe (*a).list(values)[i as usize];
            let esc = self.addr_escape(vid);
            if esc != 0 {
                let sp = unsafe (*a).at_const(vid).span;
                let mut w = "local variable".ptr() as *const char;
                if esc == 2 {
                    w = "function parameter".ptr() as *const char;
                }
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("returning a pointer/reference to a {}, which does not outlive the call", diag::cstr(w)),
                );
            }
        }
        let expected = if_u32(returns_void, 0, rets.len);
        if values.len != expected {
            let sp = unsafe (*a).at_const(id).span;
            let mut s2 = "s".ptr() as *const char;
            if expected == 1 {
                s2 = "".ptr() as *const char;
            }
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("expected {} return value{}, found {}", expected, diag::cstr(s2), values.len),
            );
            return;
        }
        if returns_void {
            return;
        }
        for i in 0..values.len {
            let vid = unsafe (*a).list(values)[i as usize];
            let r0 = unsafe (*a).list(rets)[i as usize];
            let rn = unsafe (*a).at_const(r0);
            let rt = self.resolve_type(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
            if !self.compatible(rt, vid) {
                self.err_mismatch(vid, rt);
            }
        }
    }

    fn check_static_assert(self: &mut Self, id: NodeId) void {
        let a = self.cur_ast();
        let left = unsafe (*a).at_const(id).as_data.binary.left;
        let c = self.check_expr(left);
        let sp = unsafe (*a).at_const(left).span;
        if c != TYPE_NONE && !self.is_bool(c) {
            let mut ty = Buf96 {};
            self.render_type(c, &mut ty[0], 96);
            self.errors.emit(
                sp.start,
                sp.end - sp.start,
                format("static_assert condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
            );
            return;
        }
        let ceptr = self.ceval();
        if ceptr == null {
            return;
        }
        let v = unsafe (*ceptr).eval(self.ast.module, left);
        if v.kind == ce::CONST_BOOL && v.as_data.i == 0 {
            self.errors.emit(sp.start, sp.end - sp.start, format("static assertion failed"));
        } else if v.kind == ce::CONST_NONE {
            let trap = unsafe (*ceptr).ce_trap_get();
            if trap.len() != 0 {
                self.errors.emit(sp.start, sp.end - sp.start, format("static assertion cannot be evaluated: {}", trap));
            } else {
                unsafe (*ceptr).defer_assert(self.ast.module, left);
            }
        }
    }

    fn check_stmt(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(id).kind;
        switch nk {
            NODE_STATIC_ASSERT => {
                self.check_static_assert(id);
            },
            NODE_BLOCK => {
                let stmts = unsafe (*a).at_const(id).as_data.block.statements;
                self.tc_scope_enter();
                for i in 0..stmts.len {
                    self.check_stmt(unsafe (*a).list(stmts)[i as usize]);
                    self.borrow_nll_drop(id, unsafe (*a).list(stmts), i);
                }
                while self.ndefers != 0 && self.defer_depth[(self.ndefers - 1) as usize] == self.scope_depth {
                    self.ndefers = self.ndefers - 1;
                    let dv = self.defer_stack[self.ndefers as usize];
                    let dbm = self.borrow_mark();
                    self.check_expr(dv);
                    self.borrow_release_to(dbm);
                }
                self.tc_scope_exit();
            },
            NODE_LET => {
                let bm = self.borrow_mark();
                let nm = unsafe (*a).at_const(id).as_data.let_stmt.name;
                if unsafe (*a).at_const(nm).kind == NodeKind::NODE_PATTERN_TUPLE {
                    self.check_tuple_let(id);
                    let eids = unsafe (*self.cur_ast()).at_const(nm).as_data.pattern.children;
                    for k in 0..eids.len {
                        self.tc_record_binding_depth(unsafe (*self.cur_ast()).list(eids)[k as usize]);
                    }
                    self.tc_record_binding_depth(id);
                    if self.tuple_binds_reference(nm) && self.nborrows > bm {
                        for j in bm..self.nborrows {
                            self.borrows[j as usize].binding = id;
                            self.borrows[j as usize].region = self.scope_depth as u16;
                        }
                    } else {
                        self.borrow_release_to(bm);
                    }
                    return;
                }
                self.tc_record_binding_depth(id);
                let tyn = unsafe (*a).at_const(id).as_data.let_stmt.ty;
                let value = unsafe (*a).at_const(id).as_data.let_stmt.value;
                let annotated = tyn != NODE_NONE;
                let valued = value != NODE_NONE;
                let declared = if_ty(annotated, self.resolve_type(tyn), TYPE_NONE);
                if valued {
                    self.expected = declared;
                    self.check_expr(value);
                    self.tc_mark_move(value);
                    self.tc_unmark_move(id);
                }
                let mut binding = TYPE_NONE;
                if annotated {
                    if valued && !self.compatible(declared, value) {
                        self.err_mismatch(value, declared);
                    }
                    binding = declared;
                } else if valued {
                    binding = unsafe (*self.cur_ast()).type_of(value);
                } else {
                    let sp = self.name_span(nm);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("cannot infer type of '{}'", diag::span_str(self.source, sp.start, sp.end)),
                    );
                }
                unsafe (*self.cur_ast()).set_type(id, binding);
                if annotated && !valued {
                    if self.tc_type_is_free(binding) {
                        let sp = self.name_span(nm);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("a Free-typed binding must be initialized when declared (it is freed at scope exit)"),
                        );
                    } else {
                        self.tc_add_uninit(id);
                    }
                }
                let binding_is_ref = binding != TYPE_NONE && self.type_at(binding).kind == TypeKind::TYPE_REFERENCE;
                if binding_is_ref && self.nborrows > bm {
                    for k in bm..self.nborrows {
                        self.borrows[k as usize].binding = id;
                        self.borrows[k as usize].region = self.scope_depth as u16;
                    }
                } else {
                    self.borrow_release_to(bm);
                    if binding_is_ref && valued {
                        self.borrow_transfer_ref(value, id);
                    }
                }
            },
            NODE_CONST => {
                let bm = self.borrow_mark();
                let declared = self.resolve_type(unsafe (*a).at_const(id).as_data.const_def.ty);
                let value = unsafe (*a).at_const(id).as_data.const_def.value;
                if value != NODE_NONE {
                    self.check_expr(value);
                    if !self.compatible(declared, value) {
                        self.err_mismatch(value, declared);
                    }
                }
                unsafe (*self.cur_ast()).set_type(id, declared);
                self.borrow_release_to(bm);
            },
            NODE_RETURN => {
                let bm = self.borrow_mark();
                self.check_return(id);
                self.borrow_release_to(bm);
            },
            NODE_DEFER => {
                let mut pre: FlowState;
                self.tc_flow_save(&mut pre);
                let bm = self.borrow_mark();
                let dv = unsafe (*a).at_const(id).as_data.single.value;
                self.check_expr(dv);
                self.borrow_release_to(bm);
                self.tc_flow_set(&pre);
                if self.ndefers < 256 {
                    let k = self.ndefers;
                    self.defer_stack[k as usize] = dv;
                    self.defer_depth[k as usize] = self.scope_depth;
                    self.ndefers = k + 1;
                } else {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("too many pending 'defer' statements in one function (analysis limit)"),
                    );
                }
            },
            NODE_IF => {
                self.check_if_stmt(id);
            },
            NODE_WHILE => {
                self.loop_depth = self.loop_depth + 1;
                let le = self.tc_loop_push(unsafe (*a).at_const(id).as_data.while_stmt.label, id, false);
                let bm = self.borrow_mark();
                let c = self.check_expr(unsafe (*a).at_const(id).as_data.while_stmt.condition);
                if c != TYPE_NONE && !self.is_bool(c) {
                    let sp = unsafe (*a).at_const(unsafe (*a).at_const(id).as_data.while_stmt.condition).span;
                    let mut ty = Buf96 {};
                    self.render_type(c, &mut ty[0], 96);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("while condition must be 'bool', found '{}'", diag::cstr(&ty[0])),
                    );
                }
                self.borrow_release_to(bm);
                let body = unsafe (*a).at_const(id).as_data.while_stmt.body;
                if unsafe (*a).at_const(id).as_data.while_stmt.is_do || unsafe (*a).at_const(id).as_data.while_stmt.condition == NODE_NONE {
                    self.check_loop_body(body);
                } else {
                    let mut pre: FlowState;
                    self.tc_flow_save(&mut pre);
                    self.check_loop_body(body);
                    let mut acc: FlowState;
                    self.tc_flow_clear(&mut acc);
                    let mut ovf = self.tc_flow_collect((&mut acc) as *mut FlowState);
                    self.tc_flow_set(&pre);
                    if self.tc_flow_collect((&mut acc) as *mut FlowState) {
                        ovf = true;
                    }
                    self.tc_flow_set(&acc);
                    if ovf {
                        self.tc_flow_overflow(unsafe (*self.cur_ast()).at_const(id).as_data.while_stmt.condition);
                    }
                }
                if le >= 0 {
                    self.tc_loop_pop(le, unsafe (*self.cur_ast()).at_const(id).span);
                }
                self.loop_depth = self.loop_depth - 1;
            },
            NODE_FOR => {
                self.loop_depth = self.loop_depth + 1;
                let le = self.tc_loop_push(unsafe (*a).at_const(id).as_data.for_stmt.label, id, false);
                let bm = self.borrow_mark();
                let iter = unsafe (*a).at_const(id).as_data.for_stmt.iterable;
                let mut elem = TYPE_NONE;
                if unsafe (*a).at_const(iter).kind == NodeKind::NODE_RANGE {
                    let s = self.check_expr(unsafe (*a).at_const(iter).as_data.pattern_range.start);
                    let e = self.check_expr(unsafe (*a).at_const(iter).as_data.pattern_range.end);
                    elem = self.range_type(iter, s, e);
                    unsafe (*self.cur_ast()).set_type(iter, elem);
                } else {
                    let it = self.check_expr(iter);
                    let ity = *self.type_at(it);
                    let mut selem: TypeId = TYPE_NONE;
                    if ity.kind == TypeKind::TYPE_ARRAY {
                        elem = ity.as_data.elem;
                    } else if self.slice_kind(it, (&mut selem) as *mut TypeId) != 0 {
                        elem = selem;
                    } else {
                        elem = self.range_instance_elem(it);
                    }
                    if elem == TYPE_NONE && it != TYPE_NONE {
                        elem = self.iter_elem_type(it);
                    }
                    if elem == TYPE_NONE && it != TYPE_NONE {
                        let sp = unsafe (*self.cur_ast()).at_const(iter).span;
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("cannot iterate over this value (need an array, slice, range, or an Iterator)"),
                        );
                    }
                }
                unsafe (*self.cur_ast()).set_type(id, elem);
                if id != NODE_NONE {
                    self.binding_depth.insert(id, self.scope_depth + 1);
                }
                self.borrow_release_to(bm);
                let mut pre: FlowState;
                self.tc_flow_save(&mut pre);
                self.check_loop_body(unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt.body);
                let mut acc: FlowState;
                self.tc_flow_clear(&mut acc);
                let mut ovf = self.tc_flow_collect((&mut acc) as *mut FlowState);
                self.tc_flow_set(&pre);
                if self.tc_flow_collect((&mut acc) as *mut FlowState) {
                    ovf = true;
                }
                self.tc_flow_set(&acc);
                if ovf {
                    self.tc_flow_overflow(iter);
                }
                if le >= 0 {
                    self.tc_loop_pop(le, unsafe (*self.cur_ast()).at_const(id).span);
                }
                self.loop_depth = self.loop_depth - 1;
            },
            NODE_EXPRESSION_STATEMENT => {
                let bm = self.borrow_mark();
                self.check_expr(unsafe (*a).at_const(id).as_data.single.value);
                self.borrow_release_to(bm);
            },
            NODE_BREAK | NODE_CONTINUE => {
                let lb = unsafe (*a).at_const(id).as_data.flow.label;
                let le = self.tc_find_loop(lb);
                if le < 0 {
                    let sp = unsafe (*a).at_const(id).span;
                    if lb.end > lb.start {
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("no enclosing loop is labeled {}", diag::span_str(self.source, lb.start, lb.end)),
                        );
                    } else {
                        let mut w = "continue".ptr() as *const char;
                        if nk == NodeKind::NODE_BREAK {
                            w = "break".ptr() as *const char;
                        }
                        self.errors.emit(sp.start, sp.end - sp.start, format("'{}' outside of a loop", diag::cstr(w)));
                    }
                    let fv = unsafe (*a).at_const(id).as_data.flow.value;
                    if fv != NODE_NONE {
                        self.check_expr(fv);
                    }
                    return;
                }
                unsafe (*self.cur_ast()).set_resolution(id, self.loop_stack[le as usize].node);
                self.tc_note_resolution(id, self.loop_stack[le as usize].node);
                if nk != NodeKind::NODE_BREAK {
                    return;
                }
                let fv = unsafe (*self.cur_ast()).at_const(id).as_data.flow.value;
                if fv == NODE_NONE {
                    self.loop_stack[le as usize].saw_bare = true;
                    return;
                }
                self.expected = self.loop_stack[le as usize].break_ty;
                let vt = self.check_expr(fv);
                let sp = unsafe (*self.cur_ast()).at_const(id).span;
                if !self.loop_stack[le as usize].value_loop {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("'break' can only carry a value inside a 'loop' expression"),
                    );
                } else if self.loop_stack[le as usize].break_ty == TYPE_NONE {
                    self.loop_stack[le as usize].break_ty = vt;
                } else if !self.compatible(self.loop_stack[le as usize].break_ty, fv) {
                    self.err_mismatch(fv, self.loop_stack[le as usize].break_ty);
                }
                self.loop_stack[le as usize].saw_value = true;
                self.tc_mark_move(fv);
            },
            _ => {},
        };
    }

    fn check_pattern(self: &mut Self, id: NodeId, expected: TypeId, bind_ref: i32) void {
        if id == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(id).kind;
        if nk == NodeKind::NODE_IDENTIFIER {
            unsafe (*self.cur_ast()).set_type(id, if_ty(bind_ref != 0, self.tc_ref(expected, bind_ref == 2), expected));
            self.tc_record_binding_depth(id);
        } else if nk == NodeKind::NODE_PATTERN_NAME {
            let nameId = unsafe (*a).at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = 0;
            let mut decl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agok = self.aggregate_of(
                self.strip(expected),
                (&mut bmod) as *mut ModuleId,
                (&mut decl) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            );
            if agok && unsafe (*self.mod_ast(bmod)).at_const(decl).kind == NodeKind::NODE_ENUM {
                let v = self.find_member(bmod, decl, self.name_span(nameId));
                if v != NODE_NONE && unsafe (*self.mod_ast(bmod)).at_const(v).kind == NodeKind::NODE_VARIANT && unsafe (*self.mod_ast(
                    bmod,
                )).at_const(v).as_data.variant.payload.len == 0 {
                    unsafe (*self.cur_ast()).set_resolution_def(nameId, DefId { module: bmod, node: v });
                    return;
                }
            }
            unsafe (*self.cur_ast()).set_type(id, if_ty(bind_ref != 0, self.tc_ref(expected, bind_ref == 2), expected));
            self.tc_record_binding_depth(id);
            let subs = unsafe (*self.cur_ast()).at_const(id).as_data.pattern.children;
            for i in 0..subs.len {
                self.check_pattern(unsafe (*self.cur_ast()).list(subs)[i as usize], expected, bind_ref);
            }
        } else if nk == NodeKind::NODE_PATTERN_STRUCT {
            let base = self.strip(expected);
            let nameId = unsafe (*a).at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = 0;
            let mut decl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agg = self.aggregate_of(
                base,
                (&mut bmod) as *mut ModuleId,
                (&mut decl) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            );
            let mut variant = NODE_NONE;
            if agg && nameId != NODE_NONE && unsafe (*self.mod_ast(bmod)).at_const(decl).kind == NodeKind::NODE_ENUM {
                let v = self.find_member(bmod, decl, self.name_span(nameId));
                if v != NODE_NONE && unsafe (*self.mod_ast(bmod)).at_const(v).kind == NodeKind::NODE_VARIANT {
                    variant = v;
                    unsafe (*self.cur_ast()).set_resolution_def(nameId, DefId { module: bmod, node: variant });
                }
            }
            let children = unsafe (*self.cur_ast()).at_const(id).as_data.pattern.children;
            if variant != NODE_NONE {
                let va = self.mod_ast(bmod);
                let vpl = unsafe (*va).at_const(variant).as_data.variant.payload;
                for i in 0..children.len {
                    let fid = unsafe (*self.cur_ast()).list(children)[i as usize];
                    let fldName = unsafe (*self.cur_ast()).at_const(fid).as_data.pattern.name;
                    let fn2 = self.name_span(fldName);
                    let mut ft = TYPE_NONE;
                    let mut matchId = NODE_NONE;
                    for j in 0..vpl.len {
                        let pfid = unsafe (*va).list(vpl)[j as usize];
                        let pf = unsafe (*va).at_const(pfid);
                        if pf.kind == NodeKind::NODE_FIELD && spans_eq2(
                            self.source,
                            fn2,
                            self.mod_src(bmod),
                            unsafe (*va).at_const(pf.as_data.field.name).as_data.name.text,
                        ) {
                            matchId = pfid;
                            ft = self.subst_type(
                                self.lower_type_in(bmod, pf.as_data.field.ty),
                                (&gp[0]) as *const DefId,
                                (&ga[0]) as *const TypeId,
                                gn,
                            );
                            break;
                        }
                    }
                    if matchId != NODE_NONE {
                        unsafe (*self.cur_ast()).set_resolution_def(fldName, DefId { module: bmod, node: matchId });
                    } else {
                        let mut ty = Buf96 {};
                        self.render_type(base, &mut ty[0], 96);
                        self.errors.emit(
                            fn2.start,
                            fn2.end - fn2.start,
                            format(
                                "no field '{}' on '{}'",
                                diag::span_str(self.source, fn2.start, fn2.end),
                                diag::cstr(&ty[0]),
                            ),
                        );
                    }
                    let fc = unsafe (*self.cur_ast()).at_const(fid).as_data.pattern.children;
                    for k in 0..fc.len {
                        self.check_pattern(unsafe (*self.cur_ast()).list(fc)[k as usize], ft, bind_ref);
                    }
                }
            } else {
                if agg && nameId != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(nameId, DefId { module: bmod, node: decl });
                }
                for i in 0..children.len {
                    self.check_pattern(unsafe (*self.cur_ast()).list(children)[i as usize], base, bind_ref);
                }
            }
        } else if nk == NodeKind::NODE_PATTERN_FIELD {
            let base = self.strip(expected);
            let nameId = unsafe (*a).at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = 0;
            let mut decl = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agg = self.aggregate_of(
                base,
                (&mut bmod) as *mut ModuleId,
                (&mut decl) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            );
            let mut field_type = TYPE_NONE;
            if agg && nameId != NODE_NONE {
                let fname = self.name_span(nameId);
                let field = self.find_member(bmod, decl, fname);
                if field != NODE_NONE {
                    unsafe (*self.cur_ast()).set_resolution_def(nameId, DefId { module: bmod, node: field });
                    field_type = self.subst_type(
                        self.decl_type_in(bmod, field),
                        (&gp[0]) as *const DefId,
                        (&ga[0]) as *const TypeId,
                        gn,
                    );
                } else {
                    let mut ty = Buf96 {};
                    self.render_type(base, &mut ty[0], 96);
                    self.errors.emit(
                        fname.start,
                        fname.end - fname.start,
                        format(
                            "no field '{}' on '{}'",
                            diag::span_str(self.source, fname.start, fname.end),
                            diag::cstr(&ty[0]),
                        ),
                    );
                }
            }
            let children = unsafe (*self.cur_ast()).at_const(id).as_data.pattern.children;
            for i in 0..children.len {
                self.check_pattern(unsafe (*self.cur_ast()).list(children)[i as usize], field_type, bind_ref);
            }
        } else if nk == NodeKind::NODE_PATTERN_TUPLE {
            let base = self.strip(expected);
            let nameId = unsafe (*a).at_const(id).as_data.pattern.name;
            let mut bmod: ModuleId = self.ast.module;
            let mut decl0 = NODE_NONE;
            let mut gp = Defs8 {};
            let mut ga = Tys8 {};
            let mut gn: i32 = 0;
            let agok = self.aggregate_of(
                base,
                (&mut bmod) as *mut ModuleId,
                (&mut decl0) as *mut NodeId,
                (&gp[0]) as *mut DefId,
                (&ga[0]) as *mut TypeId,
                (&mut gn) as *mut i32,
            );
            let agg = agok && unsafe (*self.mod_ast(bmod)).at_const(decl0).kind == NodeKind::NODE_ENUM;
            let decl = if_node(agg, decl0, NODE_NONE);
            let mut variant = NODE_NONE;
            if nameId != NODE_NONE {
                let vname = self.name_span(nameId);
                if decl == NODE_NONE {
                    let mut ty = Buf96 {};
                    self.render_type(base, &mut ty[0], 96);
                    self.errors.emit(
                        vname.start,
                        vname.end - vname.start,
                        format(
                            "pattern '{}(..)' expects an enum, but the value has type '{}'",
                            diag::span_str(self.source, vname.start, vname.end),
                            diag::cstr(&ty[0]),
                        ),
                    );
                } else {
                    variant = self.find_member(bmod, decl, vname);
                    if variant != NODE_NONE {
                        unsafe (*self.cur_ast()).set_resolution_def(nameId, DefId { module: bmod, node: variant });
                    } else {
                        let mut ty = Buf96 {};
                        self.render_type(base, &mut ty[0], 96);
                        self.errors.emit(
                            vname.start,
                            vname.end - vname.start,
                            format(
                                "no variant '{}' on '{}'",
                                diag::span_str(self.source, vname.start, vname.end),
                                diag::cstr(&ty[0]),
                            ),
                        );
                    }
                }
            }
            let children = unsafe (*self.cur_ast()).at_const(id).as_data.pattern.children;
            let mut payload = NodeList { start: 0, len: 0 };
            let mut va: *mut Ast = a;
            if variant != NODE_NONE {
                va = self.mod_ast(bmod);
                payload = unsafe (*va).at_const(variant).as_data.variant.payload;
            }
            for i in 0..children.len {
                let mut pt = TYPE_NONE;
                if i < payload.len {
                    let plid = unsafe (*va).list(payload)[i as usize];
                    let pe = unsafe (*va).at_const(plid);
                    pt = self.subst_type(
                        self.lower_type_in(bmod, if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, plid)),
                        (&gp[0]) as *const DefId,
                        (&ga[0]) as *const TypeId,
                        gn,
                    );
                }
                self.check_pattern(unsafe (*self.cur_ast()).list(children)[i as usize], pt, bind_ref);
            }
        } else if nk == NodeKind::NODE_PATTERN_OR {
            let children = unsafe (*a).at_const(id).as_data.pattern.children;
            for i in 0..children.len {
                self.check_pattern(unsafe (*self.cur_ast()).list(children)[i as usize], expected, bind_ref);
            }
        }
    }

    fn tc_embeds_by_value(self: &mut Self, m: ModuleId, d: NodeId, tm: ModuleId, td: NodeId, depth: i32) bool {
        if depth > 16 {
            return false;
        }
        let a = self.mod_ast(m);
        let dn = *unsafe (*a).at_const(d);
        if dn.kind != NodeKind::NODE_STRUCT && dn.kind != NodeKind::NODE_ENUM || dn.as_data.aggregate.generics.len != 0 {
            return false;
        }
        let members = dn.as_data.aggregate.members;
        for i in 0..members.len {
            let mid = unsafe (*a).list(members)[i as usize];
            let mn = *unsafe (*a).at_const(mid);
            let mut tns = NodeArr16 {};
            let mut ntn: u32 = 0;
            if dn.as_data.aggregate.is_tuple {
                tns[0] = mid;
                ntn = 1;
            } else if mn.kind == NodeKind::NODE_FIELD {
                tns[0] = mn.as_data.field.ty;
                ntn = 1;
            } else if mn.kind == NodeKind::NODE_VARIANT {
                let pl = mn.as_data.variant.payload;
                let mut j: u32 = 0;
                while j < pl.len && ntn < 16 {
                    let plid = unsafe (*a).list(pl)[j as usize];
                    let pe = unsafe (*a).at_const(plid);
                    tns[ntn as usize] = if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, plid);
                    ntn = ntn + 1;
                    j = j + 1;
                }
            }
            for j in 0..ntn {
                let mut ft = self.lower_type_in(m, tns[j as usize]);
                let mut y = *self.type_at(ft);
                while y.kind == TypeKind::TYPE_ARRAY {
                    ft = y.as_data.elem;
                    y = *self.type_at(ft);
                }
                if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
                    if y.module == tm && y.as_data.decl == td || self.tc_embeds_by_value(
                        y.module,
                        y.as_data.decl,
                        tm,
                        td,
                        depth + 1,
                    ) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn check_item(self: &mut Self, id: NodeId) void {
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(id).kind;
        switch nk {
            NODE_STATIC_ASSERT => {
                self.check_static_assert(id);
            },
            NODE_FUNCTION => {
                let params = unsafe (*a).at_const(id).as_data.function.params;
                for i in 0..params.len {
                    self.decl_type(unsafe (*a).list(params)[i as usize]);
                }
                let fnd = unsafe (*self.cur_ast()).at_const(id).as_data.function;
                if fnd.is_variadic && !fnd.is_extern && params.len == 0 {
                    let sp = self.name_span(fnd.name);
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a variadic function needs at least one fixed parameter before '...'"),
                    );
                }
                if span_is(self.source, self.name_span(fnd.name), "main") {
                    let rets = fnd.returns;
                    let mut rt = TYPE_NONE;
                    if rets.len == 1 {
                        let r0 = unsafe (*self.cur_ast()).list(rets)[0];
                        let rn = unsafe (*self.cur_ast()).at_const(r0);
                        rt = self.resolve_type(
                            if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
                        );
                    }
                    if !self.tc_main_params_ok(params) || rets.len != 1 || rt != Ast::builtin(BuiltinType::BT_I32) {
                        let sp = self.name_span(fnd.name);
                        self.errors.emit(
                            sp.start,
                            sp.end - sp.start,
                            format("'main' must be declared 'fn main() i32' or 'fn main(argv: Vector<str>) i32'"),
                        );
                    }
                }
                let saved = self.current_returns;
                let savedfn = self.current_fn;
                self.current_returns = fnd.returns;
                self.current_fn = id;
                for mi in 0..self.nmoved {
                    self.ms_bit_clear(self.moved[mi as usize]);
                }
                self.nmoved = 0;
                self.nuninit = 0;
                self.nfreed = 0;
                self.nborrows = 0;
                self.scope_depth = 0;
                self.loop_depth = 0;
                self.ndefers = 0;
                if fnd.body != NODE_NONE {
                    self.check_stmt(fnd.body);
                }
                for mi in 0..self.nmoved {
                    self.ms_bit_clear(self.moved[mi as usize]);
                }
                self.nmoved = 0;
                self.nuninit = 0;
                self.nfreed = 0;
                self.nborrows = 0;
                self.scope_depth = 0;
                self.loop_depth = 0;
                self.ndefers = 0;
                self.current_returns = saved;
                self.current_fn = savedfn;
            },
            NODE_STRUCT | NODE_ENUM => {
                let agg = unsafe (*a).at_const(id).as_data.aggregate;
                let members = agg.members;
                if agg.is_tuple {
                    for i in 0..members.len {
                        self.resolve_type(unsafe (*self.cur_ast()).list(members)[i as usize]);
                    }
                } else {
                    for i in 0..members.len {
                        let mid = unsafe (*self.cur_ast()).list(members)[i as usize];
                        let mn = *unsafe (*self.cur_ast()).at_const(mid);
                        if mn.kind == NodeKind::NODE_FIELD {
                            self.resolve_type(mn.as_data.field.ty);
                        } else {
                            if mn.as_data.variant.value != NODE_NONE {
                                let vt = self.check_expr(mn.as_data.variant.value);
                                if vt != TYPE_NONE && !self.is_int(vt) {
                                    let sp = unsafe (*self.cur_ast()).at_const(mn.as_data.variant.value).span;
                                    self.errors.emit(
                                        sp.start,
                                        sp.end - sp.start,
                                        format("enum discriminant must be an integer"),
                                    );
                                }
                            }
                            let payload = mn.as_data.variant.payload;
                            for j in 0..payload.len {
                                let plid = unsafe (*self.cur_ast()).list(payload)[j as usize];
                                let pe = unsafe (*self.cur_ast()).at_const(plid);
                                self.resolve_type(if_node(pe.kind == NodeKind::NODE_FIELD, pe.as_data.field.ty, plid));
                            }
                        }
                    }
                }
                if agg.generics.len == 0 && self.tc_embeds_by_value(self.ast.module, id, self.ast.module, id, 0) {
                    let sp = unsafe (*self.cur_ast()).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("this type embeds itself by value, so it would have infinite size"),
                    );
                    self.errors.note(format("break the cycle with a pointer ('*mut T'), a reference, or 'Box<T>'"));
                }
            },
            NODE_INTERFACE => {
                self.check_associated(unsafe (*a).at_const(id).as_data.interface_def.items);
            },
            NODE_EXTEND => {
                let saved = self.current_self;
                let saved_impl = self.current_extend;
                self.current_self = unsafe (*a).resolution(unsafe (*a).at_const(id).as_data.extend_def.target_type);
                self.current_extend = id;
                if unsafe (*self.cur_ast()).at_const(id).as_data.extend_def.interface_type != NODE_NONE {
                    self.check_extend_conformance(id);
                }
                self.check_associated(unsafe (*self.cur_ast()).at_const(id).as_data.extend_def.items);
                self.current_self = saved;
                self.current_extend = saved_impl;
            },
            NODE_CONST => {
                let declared = self.resolve_type(unsafe (*a).at_const(id).as_data.const_def.ty);
                let cd = unsafe (*self.cur_ast()).at_const(id).as_data.const_def;
                if cd.value != NODE_NONE {
                    self.check_expr(cd.value);
                    if !self.compatible(declared, cd.value) {
                        self.err_mismatch(cd.value, declared);
                    }
                }
                if cd.is_static_mut && self.tc_type_is_free(declared) {
                    let sp = unsafe (*self.cur_ast()).at_const(id).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("a 'static mut' cannot hold an owning (Free) type"),
                    );
                    self.errors.note(
                        format("no scope ever frees a global; store a scalar/view or manage the value locally"),
                    );
                }
            },
            NODE_TYPE_ALIAS => {
                let _ = self.resolve_type(unsafe (*a).at_const(id).as_data.type_alias.ty);
            },
            NODE_EXTERN_BLOCK => {
                self.check_associated(unsafe (*a).at_const(id).as_data.extern_block.items);
            },
            _ => {},
        };
    }

    fn check_associated(self: &mut Self, items: NodeList) void {
        for i in 0..items.len {
            self.check_item(unsafe (*self.cur_ast()).list(items)[i as usize]);
        }
    }

    fn close_instances(self: &mut Self) void {
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            let mut concrete = true;
            for k in 0..it.n {
                if !unsafe (*self.cur_ast()).type_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                ii = ii + 1;
                continue;
            }
            self.ensure_ext_items(it.module);
            let ma = self.mod_ast(it.module);
            let ne = self.ext_items_len(it.module);
            for i in 0..ne {
                let iid = self.ext_items_at(it.module, i);
                let itn = unsafe (*ma).at_const(iid);
                if itn.as_data.extend_def.generics.len != 0 && unsafe (*ma).resolution(
                    itn.as_data.extend_def.target_type,
                ) == it.decl {
                    let gens = itn.as_data.extend_def.generics;
                    let mut ip = Defs8 {};
                    let mut ia = Tys8 {};
                    let mut ipn: i32 = 0;
                    let mut g: u32 = 0;
                    while g < gens.len && g as u8 < it.n && ipn < 8 {
                        ip[ipn as usize] = DefId { module: it.module, node: unsafe (*ma).list(gens)[g as usize] };
                        ia[ipn as usize] = it.args[g as usize];
                        ipn = ipn + 1;
                        g = g + 1;
                    }
                    let ms = unsafe (*ma).at_const(iid).as_data.extend_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe (*ma).list(ms)[j as usize];
                        let mn = unsafe (*ma).at_const(mid);
                        if mn.kind == NodeKind::NODE_FUNCTION && mn.as_data.function.generics.len == 0 {
                            let ps = mn.as_data.function.params;
                            for p in 0..ps.len {
                                let pid = unsafe (*ma).list(ps)[p as usize];
                                self.subst_type(
                                    self.lower_type_in(it.module, unsafe (*ma).at_const(pid).as_data.parameter.ty),
                                    (&ip[0]) as *const DefId,
                                    (&ia[0]) as *const TypeId,
                                    ipn,
                                );
                            }
                            let rs = mn.as_data.function.returns;
                            if rs.len == 1 {
                                let r0 = unsafe (*ma).list(rs)[0];
                                let rn = unsafe (*ma).at_const(r0);
                                self.subst_type(
                                    self.lower_type_in(
                                        it.module,
                                        if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
                                    ),
                                    (&ip[0]) as *const DefId,
                                    (&ia[0]) as *const TypeId,
                                    ipn,
                                );
                            }
                        }
                    }
                }
            }
            ii = ii + 1;
        }
    }

    pub fn check(self: &mut Self) void {
        unsafe (*self.cur_ast()).init_types();
        let items = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).root).as_data.program.items;
        for i in 0..items.len {
            self.check_item(unsafe (*self.cur_ast()).list(items)[i as usize]);
        }
        self.close_instances();
        let mut file: str = "";
        if self.package != null && self.ast.module as usize < self.pkg_count() {
            file = unsafe (*self.package).modules[self.ast.module as usize].file.as_str();
        }
        self.errors.finalize(self.source, file);
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) void {
        self.errors.log();
    }
}

extend TypeChecker as Free {
    pub fn free(self: &mut Self) void {
        self.ext_scope.free();
        self.ext_items.free();
        self.ext_items_built.free();
        self.binding_depth.free();
        self.last_use.free();
        self.moved_bits.free();
        self.free_ext_memo.free();
        self.encl_ext_memo.free();
        self.encl_trait_memo.free();
        self.dynfn_list.free();
        self.errors.free();
        self.ast.free();
    }
}

fn if_bool(c: bool, a: bool, b: bool) bool {
    if c {
        return a;
    }
    return b;
}
fn if_u32(c: bool, a: u32, b: u32) u32 {
    if c {
        return a;
    }
    return b;
}
fn if_nl(c: bool, a: NodeList, b: NodeList) NodeList {
    if c {
        return a;
    }
    return b;
}
