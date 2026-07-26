// The per-module AST and type arena. Nodes live in one flat Vector indexed by NodeId (0 = NODE_NONE);
// child lists are (start, len) windows into `children`, built through `scratch` via mark/push/commit.
// Types are interned: TypeIds number `type_pool` in INSERTION order, so interned identity (and every
// downstream emission) is independent of hashing. Analysis results for later passes hang off NodeIds
// in side tables (resolutions, types, mono/dyn/deref uses, attrs, lifetime_decls, call_info).
import string as cstring;
import lexer::token as tok;
import lexer::token_type as tt;

pub type NodeId = u32;
pub const NODE_NONE: NodeId = 0;

pub struct NodeList {
    pub start: u32,
    pub len: u32,
}
pub type ModuleId = u16;

pub struct DefId {
    pub module: ModuleId,
    pub node: NodeId,
}

pub enum AttrKind {
    ATTR_INLINE,
    ATTR_ALWAYS_INLINE,
    ATTR_NOINLINE,
    ATTR_NORETURN,
    ATTR_ALIGN,
    ATTR_PACKED,
    ATTR_EXPORT,
    ATTR_IMPORT,
    ATTR_SECTION,
    ATTR_USED,
    ATTR_UNUSED,
    ATTR_EMIT_MACRO,
    ATTR_TEST,
    ATTR_TEST_INIT,
    ATTR_TEST_FREE,
    ATTR_C_SOURCE,
    ATTR_C_LINK,
    ATTR_COLD,
    ATTR_PLATFORM,
    ATTR_FMT_SKIP,
    ATTR_BLOCKING,
}

// A decl's lifetime generic params (`fn f<'a>`, `struct S<'a>`). Held in an Ast SIDE TABLE rather
// than inline on the decl data, so `Node` keeps its tuned size: lifetimes are erased, rare, and only
// read by the formatter and the region checker.
pub struct LifetimeDecl {
    pub owner: NodeId,
    pub list: NodeList,
}

pub struct Attr {
    pub owner: NodeId,
    pub kind: u8,
    pub arg: u32,
    pub str_span: tok::Span,
}

pub enum TypeQualifier {
    TYPE_QUAL_NONE,
    TYPE_QUAL_CONST,
    TYPE_QUAL_MUT,
}

pub enum NodeKind {
    NODE_NONE_KIND,
    NODE_PROGRAM,
    NODE_IDENTIFIER,
    NODE_LITERAL,
    NODE_FUNCTION,
    NODE_PARAMETER,
    NODE_STRUCT,
    NODE_FIELD,
    NODE_ENUM,
    NODE_VARIANT,
    NODE_INTERFACE,
    NODE_EXTEND,
    NODE_TYPE_ALIAS,
    NODE_CONST,
    NODE_STATIC_ASSERT,
    NODE_EXTERN_BLOCK,
    NODE_IMPORT,
    NODE_GENERIC_PARAM,
    NODE_WHERE_PREDICATE,
    NODE_TYPE_PATH,
    NODE_POINTER_TYPE,
    NODE_REFERENCE_TYPE,
    NODE_SLICE_TYPE,
    NODE_ARRAY_TYPE,
    NODE_FUNCTION_TYPE,
    NODE_DYN_TYPE,
    NODE_BLOCK,
    NODE_LET,
    NODE_RETURN,
    NODE_BREAK,
    NODE_CONTINUE,
    NODE_DEFER,
    NODE_IF,
    NODE_WHILE,
    NODE_FOR,
    NODE_EXPRESSION_STATEMENT,
    NODE_UNARY,
    NODE_BINARY,
    NODE_ASSIGNMENT,
    NODE_CALL,
    NODE_CLOSURE,
    NODE_INDEX,
    NODE_MEMBER,
    NODE_CAST,
    NODE_GENERIC_SPECIALIZATION,
    NODE_MATCH,
    NODE_MATCH_ARM,
    NODE_NEW,
    NODE_SIZEOF,
    NODE_ALIGNOF,
    NODE_VA_EXPR,
    NODE_ARRAY_LITERAL,
    NODE_STRUCT_INITIALIZER,
    NODE_FIELD_INITIALIZER,
    NODE_PATTERN_WILDCARD,
    NODE_PATTERN_LITERAL,
    NODE_PATTERN_NAME,
    NODE_PATTERN_TUPLE,
    NODE_PATTERN_STRUCT,
    NODE_PATTERN_FIELD,
    NODE_PATTERN_RANGE,
    NODE_PATTERN_OR,
    NODE_RANGE,
    NODE_TUPLE,
    NODE_TUPLE_TYPE,
    // A lifetime name: `'a` as a generic param's name, a lifetime argument, or an outlives bound.
    // Appended at the END so an older bootstrap compiler keeps the established numeric values.
    NODE_LIFETIME,
    // Sugar-keyword marker: produced by the parser, printed by the formatter, and lowered to a core node by
    // the desugar pass (src/desugar) before typecheck -- no other pass sees it. NODE_LAUNCH carries CallData
    // (a placeholder callee + the operand as the sole arg); desugar seeds the callee's resolution to the
    // runtime shim and flips the kind to NODE_CALL.
    NODE_LAUNCH,
    NODE_KIND_COUNT,
}

pub const VA_START: u8 = 0;
pub const VA_ARG: u8 = 1;
pub const VA_END: u8 = 2;

pub struct ProgramData {
    pub items: NodeList,
}
pub struct NameData {
    pub text: tok::Span,
    pub is_mutable: bool,
}
pub struct LiteralData {
    pub raw: tok::Span,
    pub token_type: tt::TokenType,
}
pub struct FunctionData {
    pub name: NodeId,
    pub generics: NodeList,
    pub params: NodeList,
    pub returns: NodeList,
    pub where_clause: NodeList,
    pub body: NodeId,
    pub is_public: bool,
    pub is_extern: bool,
    pub is_variadic: bool,
    pub is_const: bool, // `const fn`: must evaluate at compile time when its arguments are known
    pub is_unsafe: bool, // `unsafe fn`: calls require an unsafe context (like extern "C" fns)
}
pub struct ParameterData {
    pub name: NodeId,
    pub ty: NodeId,
    pub is_mutable: bool,
}
pub struct AggregateData {
    pub name: NodeId,
    pub generics: NodeList,
    pub members: NodeList,
    pub is_public: bool,
    pub is_union: bool,
    pub is_tuple: bool,
}
pub struct FieldData {
    pub name: NodeId,
    pub ty: NodeId,
    pub value: NodeId,
    pub is_public: bool,
}
pub struct VariantData {
    pub name: NodeId,
    pub payload: NodeList,
    pub struct_payload: bool,
    pub value: NodeId,
}
pub struct InterfaceData {
    pub name: NodeId,
    pub generics: NodeList,
    pub bounds: NodeList,
    pub items: NodeList,
    pub is_public: bool,
}
pub struct ExtendData {
    pub generics: NodeList,
    pub interface_type: NodeId,
    pub target_type: NodeId,
    pub items: NodeList,
}
pub struct TypeAliasData {
    pub name: NodeId,
    pub generics: NodeList,
    pub ty: NodeId,
    pub is_public: bool,
}
pub struct ConstData {
    pub name: NodeId,
    pub ty: NodeId,
    pub value: NodeId,
    pub is_public: bool,
    pub is_extern: bool,
    pub is_static_mut: bool,
}
pub struct ExternBlockData {
    pub abi: NodeId,
    pub header: NodeId,
    pub items: NodeList,
}
pub struct ImportData {
    pub path: NodeList,
    pub alias: NodeId,
    pub glob: bool,
}
pub struct GenericParamData {
    pub name: NodeId,
    pub bounds: NodeList,
    pub default_type: NodeId,
    pub is_const: bool,
    pub const_type: NodeId,
    // A LIFETIME param (`<'a>`): `bounds` holds its outlives bounds (`'a: 'b`), `const_type` and
    // `default_type` are NODE_NONE. Lifetimes are ERASED before monomorphization -- every consumer
    // that maps generic params onto `Ty` args must SKIP these (see non_lifetime_count).
    pub is_lifetime: bool,
}
pub struct WherePredicateData {
    pub ty: NodeId,
    pub bounds: NodeList,
}
/// The builtin types' surface names. BuiltinType is declared in this module, so the shared name
/// table lives here too: the typechecker's renderer/lookup delegates to it, and consteval uses it to
/// fold builtin-targeted casts demanded before their module is typechecked.
pub const fn bt_name(b: BuiltinType) str<'static> {
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

/// The BuiltinType whose name the span spells, -1 if none.
pub const fn bt_of_name(src: str, s: tok::Span) i32 {
    let n = (s.end - s.start) as usize;
    for i in 0..BuiltinType::BT_COUNT as i32 {
        let lit = bt_name(i as BuiltinType);
        if lit.len() == n && unsafe cstring::memcmp(src.ptr() + s.start as usize, lit.ptr(), n) == 0 {
            return i;
        }
    }
    return -1;
}

pub struct TypePathData {
    pub parts: NodeList,
    pub args: NodeList,
}
pub struct IndirectTypeData {
    pub ty: NodeId,
    pub qualifier: TypeQualifier,
    // The source lifetime annotation on a NODE_REFERENCE_TYPE (`&'a T`): a NODE_LIFETIME node, or
    // NODE_NONE when elided. Never set for pointers. Erased from the interned `Ty` -- the region
    // checker reads it from here.
    pub lifetime: NodeId,
}
pub struct ArrayTypeData {
    pub element: NodeId,
    pub length: NodeId,
}
pub struct FunctionTypeData {
    pub params: NodeList,
    pub returns: NodeList,
    pub is_move: bool,
}
pub struct BlockData {
    pub statements: NodeList,
}
pub struct LetData {
    pub name: NodeId,
    pub ty: NodeId,
    pub value: NodeId,
    pub is_mutable: bool,
}
pub struct SingleData {
    pub value: NodeId,
}
pub struct VaOpData {
    pub op: u8,
    pub ap: NodeId,
    pub extra: NodeId,
}
pub struct ReturnData {
    pub values: NodeList,
}
pub struct IfData {
    pub condition: NodeId,
    pub then_branch: NodeId,
    pub else_branch: NodeId,
}
pub struct WhileData {
    pub condition: NodeId,
    pub body: NodeId,
    pub is_do: bool,
    pub label: tok::Span,
}
pub struct ForData {
    pub binding: NodeId,
    pub iterable: NodeId,
    pub body: NodeId,
    pub label: tok::Span,
}
pub struct FlowData {
    pub value: NodeId,
    pub label: tok::Span,
}
pub struct UnaryData {
    pub op: tt::TokenType,
    pub operand: NodeId,
    pub qualifier: TypeQualifier,
}
pub struct BinaryData {
    pub op: tt::TokenType,
    pub left: NodeId,
    pub right: NodeId,
}
pub struct CallData {
    pub callee: NodeId,
    pub args: NodeList,
}
// mut_caps is a u32 mutated-capture bitmask (≤32 captures). u32 (not u64) is deliberate: it leaves
// ClosureData with no 8-aligned member, so NodeAs stays 4-aligned and Node is 56 bytes instead of 64.
pub struct ClosureData {
    pub params: NodeList,
    pub returns: NodeList,
    pub body: NodeId,
    pub expr_body: bool,
    pub captures: NodeList,
    pub mut_caps: u32,
}
pub struct IndexData {
    pub object: NodeId,
    pub index: NodeId,
}
pub struct MemberData {
    pub object: NodeId,
    pub member: NodeId,
    pub pointer: bool,
    pub path: bool,
}
pub struct CastData {
    pub expression: NodeId,
    pub ty: NodeId,
}
pub struct SpecializationData {
    pub expression: NodeId,
    pub types: NodeList,
}
pub struct MatchData {
    pub value: NodeId,
    pub arms: NodeList,
}
pub struct MatchArmData {
    pub pattern: NodeId,
    pub guard: NodeId,
    pub body: NodeId,
}
pub struct NewData {
    pub ty: NodeId,
    pub initializer: NodeId,
}
pub struct ArrayLiteralData {
    pub elements: NodeList,
    // `[v; N]`: `elements` holds exactly the value and the count, rather than the elements themselves.
    // A flag rather than a node kind of its own, so every pass that just walks `elements` (the resolver,
    // const-eval) keeps working on both forms unchanged.
    pub repeat: bool,
}
pub struct StructInitializerData {
    pub ty: NodeId,
    pub fields: NodeList,
}
pub struct FieldInitializerData {
    pub name: NodeId,
    pub value: NodeId,
}
pub struct PatternData {
    pub name: NodeId,
    pub children: NodeList,
}
pub struct PatternRangeData {
    pub start: NodeId,
    pub end: NodeId,
    pub inclusive: bool,
}

pub union NodeAs {
    pub program: ProgramData,
    pub name: NameData,
    pub literal: LiteralData,
    pub function: FunctionData,
    pub parameter: ParameterData,
    pub aggregate: AggregateData,
    pub field: FieldData,
    pub variant: VariantData,
    pub interface_def: InterfaceData,
    pub extend_def: ExtendData,
    pub type_alias: TypeAliasData,
    pub const_def: ConstData,
    pub extern_block: ExternBlockData,
    pub import_decl: ImportData,
    pub generic_param: GenericParamData,
    pub where_predicate: WherePredicateData,
    pub type_path: TypePathData,
    pub indirect_type: IndirectTypeData,
    pub array_type: ArrayTypeData,
    pub function_type: FunctionTypeData,
    pub block: BlockData,
    pub let_stmt: LetData,
    pub single: SingleData,
    pub va_op: VaOpData,
    pub return_stmt: ReturnData,
    pub if_stmt: IfData,
    pub while_stmt: WhileData,
    pub for_stmt: ForData,
    pub flow: FlowData,
    pub unary: UnaryData,
    pub binary: BinaryData,
    pub call: CallData,
    pub closure: ClosureData,
    pub index: IndexData,
    pub member: MemberData,
    pub cast: CastData,
    pub specialization: SpecializationData,
    pub match_expr: MatchData,
    pub match_arm: MatchArmData,
    pub new_expr: NewData,
    pub array_literal: ArrayLiteralData,
    pub struct_initializer: StructInitializerData,
    pub field_initializer: FieldInitializerData,
    pub pattern: PatternData,
    pub pattern_range: PatternRangeData,
}

pub struct Node {
    pub kind: NodeKind,
    pub span: tok::Span,
    pub as_data: NodeAs,
}

pub type TypeId = u32;
pub const TYPE_NONE: TypeId = 0;

pub enum BuiltinType {
    BT_BOOL,
    BT_CHAR,
    BT_I8,
    BT_I16,
    BT_I32,
    BT_I64,
    BT_ISIZE,
    BT_U8,
    BT_U16,
    BT_U32,
    BT_U64,
    BT_USIZE,
    BT_F32,
    BT_F64,
    BT_C32,
    BT_C64,
    BT_VALIST,
    BT_VOID,
    BT_COUNT,
}

pub enum TypeKind {
    TYPE_ERROR,
    TYPE_BUILTIN,
    TYPE_POINTER,
    TYPE_REFERENCE,
    TYPE_SLICE,
    TYPE_ARRAY,
    TYPE_FUNCTION,
    TYPE_STRUCT,
    TYPE_ENUM,
    TYPE_GENERIC,
    TYPE_INSTANCE,
    TYPE_OPAQUE,
    TYPE_DYN,
    TYPE_NEVER,
    TYPE_CONST, // a const-generic argument value (as_data.value)
}

pub struct TyArr {
    pub elem: TypeId,
    pub len: u32,
}
pub union TyAs {
    pub builtin: BuiltinType,
    pub elem: TypeId,
    pub decl: NodeId,
    pub inst: u32,
    pub arr: TyArr,
    pub value: i64, // TYPE_CONST: a const-generic value
}
pub struct Ty {
    pub kind: TypeKind,
    pub qualifier: u8,
    pub module: ModuleId,
    pub as_data: TyAs,
}

extend Ty as Hash {
    // Word-wise FNV over Ty's raw storage. Ty is 8-aligned (its `value: i64` forces alignof 8) and power-of-2
    // sized, so `sizeof(Ty)/8` aligned u64 loads cover every byte the per-byte loop did -- ~8x fewer rounds.
    // The hash only selects a probe bucket: `eq` stays a full memcmp and intern_type numbers TypeIds in
    // insertion order, so the hash function never affects interned identity or emitted output.
    pub fn hash(self: &Self) u64 {
        let p = (self as *const Ty) as *const u64;
        let mut h: u64 = 1469598103934665603u64;
        for i in 0..sizeof(Ty) / 8 {
            h = h ^ unsafe p[i];
            h = h * 1099511628211u64;
        }
        return h;
    }
}

extend Ty as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        return unsafe cstring::memcmp(self as *const Ty, other as *const Ty, sizeof(Ty)) == 0;
    }
}

pub struct TyInstance {
    pub module: ModuleId,
    pub decl: NodeId,
    pub n: u8,
    pub args: [TypeId; 8],
}
pub struct MonoUse {
    pub node: NodeId,
    pub n: u8,
    pub args: [TypeId; 8],
}
pub struct DynUse {
    pub node: NodeId,
    pub src: TypeId,
    pub dyn_ty: TypeId,
    pub alloc: TypeId, // Box-erase allocator (TYPE_NONE = Global); its free glue calls A::default()
}
pub struct DerefUse {
    pub node: NodeId,
    pub target: TypeId,
    pub n: u8,
    pub recv: [TypeId; 8],
    pub method: [DefId; 8],
}
pub struct MethodInst {
    pub instance: TypeId,
    pub method: NodeId,
    pub n: u8,
    pub targs: [TypeId; 8],
}

// Field-wise Hash/Eq over the SIGNIFICANT prefix (module/decl/n + args[0..n]) — deliberately NOT a
// sizeof-memcmp, so the unused args[n..8] tail (left uninitialized by the `{module,decl,n}` literal) can
// never affect identity. This exactly mirrors intern_instance's linear comparison, keeping the interned
// index numbering byte-identical.
extend TyInstance as Hash {
    pub fn hash(self: &Self) u64 {
        let mut h: u64 = 1469598103934665603u64;
        h = (h ^ self.module as u64) * 1099511628211u64;
        h = (h ^ self.decl as u64) * 1099511628211u64;
        h = (h ^ self.n as u64) * 1099511628211u64;
        for i in 0..self.n {
            h = (h ^ (unsafe self.args[i]) as u64) * 1099511628211u64;
        }
        return h;
    }
}
extend TyInstance as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        if self.module != other.module || self.decl != other.decl || self.n != other.n {
            return false;
        }
        for i in 0..self.n {
            if unsafe self.args[i] != unsafe other.args[i] {
                return false;
            }
        }
        return true;
    }
}
extend MethodInst as Hash {
    pub fn hash(self: &Self) u64 {
        let mut h: u64 = 1469598103934665603u64;
        h = (h ^ self.instance as u64) * 1099511628211u64;
        h = (h ^ self.method as u64) * 1099511628211u64;
        h = (h ^ self.n as u64) * 1099511628211u64;
        for i in 0..self.n {
            h = (h ^ (unsafe self.targs[i]) as u64) * 1099511628211u64;
        }
        return h;
    }
}
extend MethodInst as Eq {
    pub fn eq(self: &Self, other: &Self) bool {
        if self.instance != other.instance || self.method != other.method || self.n != other.n {
            return false;
        }
        for i in 0..self.n {
            if unsafe self.targs[i] != unsafe other.targs[i] {
                return false;
            }
        }
        return true;
    }
}

pub struct Ast {
    pub nodes: Vector<Node>,
    pub children: Vector<u32>,
    pub scratch: Vector<u32>,
    // NOTE: a node/module parallel-array split (6 B/entry vs padded 8) was tried and reverted:
    // resolution_def is the compiler's hottest lookup and the second cache line cost ~8 Mcyc of
    // typecheck for a 0.78 MiB saving. Access goes through the accessors below regardless.
    pub resolutions: Vector<DefId>,
    pub type_pool: Vector<Ty>,
    // Open-addressing INDEX tables over the pools (0xFFFFFFFF = empty slot): the pool entry itself is
    // the key, so nothing is stored twice. Every hit VERIFIES the pool entry (codegen truncate()s
    // `instances` during owner-swap emission, leaving stale ids behind — a stale or out-of-range id
    // just probes on, self-healing). `*_ix_used` counts occupied slots (staleness included) so the
    // load-factor rebuild can never be starved by a truncated pool.
    pub type_index: Vector<u32>,
    pub type_ix_used: u32,
    pub types: Vector<u32>,
    pub mono: Vector<MonoUse>,
    pub mono_at: Vector<u32>,
    pub instances: Vector<TyInstance>,
    pub method_insts: Vector<MethodInst>,
    pub instance_index: Vector<u32>,
    pub inst_ix_used: u32,
    pub method_inst_index: Vector<u32>,
    pub mi_ix_used: u32,
    pub dyn_uses: Vector<DynUse>,
    pub dyn_at: Vector<u32>,
    pub deref_uses: Vector<DerefUse>,
    pub deref_at: Vector<u32>,
    pub attrs: Vector<Attr>,
    pub lifetime_decls: Vector<LifetimeDecl>,
    // Per call node: the (fmod<<40 | fdecl<<8 | skip) the borrow-check pass replays from typechecking.
    pub call_info: Map<u32, u64>,
    pub root: NodeId,
    pub module: ModuleId,
}

extend Ast {
    pub fn new(token_count: usize) Ast {
        let mut a = Ast {
            nodes: Vector::<Node>::new(),
            children: Vector::<u32>::new(),
            scratch: Vector::<u32>::new(),
            resolutions: Vector::<DefId>::new(),
            type_pool: Vector::<Ty>::new(),
            type_index: Vector::<u32>::new(),
            type_ix_used: 0,
            types: Vector::<u32>::new(),
            mono: Vector::<MonoUse>::new(),
            mono_at: Vector::<u32>::new(),
            instances: Vector::<TyInstance>::new(),
            method_insts: Vector::<MethodInst>::new(),
            instance_index: Vector::<u32>::new(),
            inst_ix_used: 0,
            method_inst_index: Vector::<u32>::new(),
            mi_ix_used: 0,
            dyn_uses: Vector::<DynUse>::new(),
            dyn_at: Vector::<u32>::new(),
            deref_uses: Vector::<DerefUse>::new(),
            deref_at: Vector::<u32>::new(),
            attrs: Vector::<Attr>::new(),
            root: NODE_NONE,
            module: 0,
        };
        // nodes/tokens sits at ~0.78 across real corpora; 7/8 trims the over-reserve while keeping
        // the high-ratio outlier modules from doubling past the reserve.
        a.nodes.reserve(token_count - token_count / 8);
        a.children.reserve(token_count / 2);
        a.nodes.push(Node { kind: NodeKind::NODE_NONE_KIND });
        return a;
    }

    pub fn add(self: &mut Self, node: Node) NodeId {
        let id = self.nodes.len() as NodeId;
        self.nodes.push(node);
        return id;
    }

    pub const fn mark(self: &Self) u32 {
        return self.scratch.len() as u32;
    }
    pub fn push(self: &mut Self, id: NodeId) {
        self.scratch.push(id);
    }

    /// Moves the scratch entries pushed since `mark` into `children` and returns their NodeList.
    /// Nested lists work because an inner list commits (draining its scratch tail) first.
    pub fn commit(self: &mut Self, mark: u32) NodeList {
        let list = NodeList { start: self.children.len() as u32, len: self.scratch.len() as u32 - mark };
        for i in mark as usize..self.scratch.len() {
            self.children.push(self.scratch[i]);
        }
        self.scratch.truncate(mark as usize);
        return list;
    }

    pub fn init_resolutions(self: &mut Self) {
        self.resolutions.clear();
        self.resolutions.reserve(self.nodes.len());
        for _ in 0..self.nodes.len() {
            self.resolutions.push(DefId { module: 0, node: NODE_NONE });
        }
    }

    pub const fn resolutions_len(self: &Self) usize {
        return self.resolutions.len();
    }

    pub fn init_types(self: &mut Self) {
        self.types.clear();
        self.types.reserve(self.nodes.len());
        for _ in 0..self.nodes.len() {
            self.types.push(TYPE_NONE);
        }
        self.type_pool.clear();
        self.type_index.clear();
        self.type_ix_used = 0;
        // seeds go to the pool only: the first intern_type rebuild indexes the whole pool
        self.type_pool.push(Ty { kind: TypeKind::TYPE_ERROR });
        for b in 0..BuiltinType::BT_COUNT as u8 {
            self.type_pool.push(Ty { kind: TypeKind::TYPE_BUILTIN, as_data: TyAs { builtin: b as BuiltinType } });
        }
    }

    // Rebuild an index table over `pool_len` live pool ids (wipes stale slots). `used` resets to the
    // live count; sizing keeps the post-insert load under 0.75.
    fn ix_rebuild(ix: &mut Vector<u32>, pool_len: usize) usize {
        let mut cap: usize = 16;
        while cap * 3 < (pool_len + 1) * 4 {
            cap = cap * 2;
        }
        ix.clear();
        ix.reserve(cap);
        for _ in 0..cap {
            ix.push(0xFFFFFFFFu32);
        }
        return pool_len;
    }

    /// Interns `t`, returning the existing TypeId on a hit. Ids are dense insertion-order indices
    /// into `type_pool`; the hash index only picks probe buckets, so identity never depends on it.
    pub fn intern_type(self: &mut Self, t: Ty) TypeId {
        if self.type_index.len() == 0 || (self.type_ix_used as usize + 1) * 4 >= self.type_index.len() * 3 {
            self.type_ix_used = Ast::ix_rebuild(&mut self.type_index, self.type_pool.len()) as u32;
            for id in 0..self.type_pool.len() {
                let mask = self.type_index.len() - 1;
                let mut i = self.type_pool.at(id).hash() as usize & mask;
                while self.type_index[i] != 0xFFFFFFFFu32 {
                    i = i + 1 & mask;
                }
                self.type_index.set(i, id as u32);
            }
        }
        let mask = self.type_index.len() - 1;
        let ixp = self.type_index.as_ptr();
        let pp = self.type_pool.as_ptr();
        let pn = self.type_pool.len();
        let mut i = t.hash() as usize & mask;
        loop {
            let idx = unsafe ixp[i];
            if idx == 0xFFFFFFFFu32 {
                let id = self.type_pool.len() as TypeId;
                self.type_pool.push(t);
                self.type_index.set(i, id);
                self.type_ix_used = self.type_ix_used + 1;
                return id;
            }
            if idx as usize < pn && unsafe pp[idx as usize] == t {
                return idx;
            }
            i = i + 1 & mask;
        }
    }

    /// Interns a (module, decl, args) instantiation and returns its TYPE_INSTANCE TypeId. `n` is
    /// clamped to 8 (the fixed args capacity). Safety: `args` must point at `n` readable TypeIds.
    pub fn intern_instance(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8) TypeId {
        let mut m = n;
        if m > 8 {
            m = 8;
        }
        let mut it = TyInstance { module: module, decl: decl, n: m };
        for j in 0..m {
            unsafe it.args[j] = unsafe args[j];
        }
        if self.instance_index.len() == 0 || (self.inst_ix_used as usize + 1) * 4 >= self.instance_index.len() * 3 {
            self.inst_ix_used = Ast::ix_rebuild(&mut self.instance_index, self.instances.len()) as u32;
            for id in 0..self.instances.len() {
                let mask = self.instance_index.len() - 1;
                let mut i = self.instances.at(id).hash() as usize & mask;
                while self.instance_index[i] != 0xFFFFFFFFu32 {
                    i = i + 1 & mask;
                }
                self.instance_index.set(i, id as u32);
            }
        }
        let mask = self.instance_index.len() - 1;
        let ixp = self.instance_index.as_ptr();
        let pp = self.instances.as_ptr();
        let pn = self.instances.len();
        let mut i = it.hash() as usize & mask;
        let mut idx = 0xFFFFFFFFu32;
        loop {
            let cur = unsafe ixp[i];
            if cur == 0xFFFFFFFFu32 {
                idx = self.instances.len() as u32;
                self.instances.push(it);
                self.instance_index.set(i, idx);
                self.inst_ix_used = self.inst_ix_used + 1;
                break;
            }
            if cur as usize < pn && unsafe pp[cur as usize] == it {
                idx = cur;
                break;
            }
            i = i + 1 & mask;
        }
        return self.intern_type(Ty { kind: TypeKind::TYPE_INSTANCE, module: module, as_data: TyAs { inst: idx } });
    }

    /// Intern a `dyn` type: the payload is an instance-table index carrying the interface decl
    /// and its (possibly empty) type arguments; `module` mirrors the interface's module so
    /// existing `dy.module` reads stay valid.
    pub fn intern_dyn(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8, qual: u8) TypeId {
        let ii = self.intern_instance(module, decl, args, n);
        let idx = self.type_at(ii).as_data.inst;
        return self.intern_type(
            Ty { kind: TypeKind::TYPE_DYN, qualifier: qual, module: module, as_data: TyAs { inst: idx } },
        );
    }

    /// The interface (or dyn-fn signature) node behind a TYPE_DYN payload.
    pub const fn dyn_decl_of(self: &Self, dy: &Ty) NodeId {
        return self.instance(dy.as_data.inst).decl;
    }

    pub const fn instance(self: &Self, index: u32) &TyInstance {
        return self.instances.at(index as usize);
    }

    /// A const-generic argument value, interned as a module-independent TYPE_CONST.
    pub fn const_value(self: &mut Self, v: i64) TypeId {
        return self.intern_type(Ty { kind: TypeKind::TYPE_CONST, module: 0, as_data: TyAs { value: v } });
    }

    /// Records a method instantiation; returns false if it was already recorded. `n` is clamped to
    /// 8. Safety: `targs` must point at `n` readable TypeIds.
    pub fn add_method_inst(self: &mut Self, instance: TypeId, method: NodeId, targs: *const TypeId, n: u8) bool {
        let mut m = n;
        if m > 8 {
            m = 8;
        }
        let mut mi = MethodInst { instance: instance, method: method, n: m };
        for j in 0..m {
            unsafe mi.targs[j] = unsafe targs[j];
        }
        if self.method_inst_index.len() == 0 || (self.mi_ix_used as usize + 1) * 4 >= self.method_inst_index.len() * 3 {
            self.mi_ix_used = Ast::ix_rebuild(&mut self.method_inst_index, self.method_insts.len()) as u32;
            for id in 0..self.method_insts.len() {
                let mask = self.method_inst_index.len() - 1;
                let mut i = self.method_insts.at(id).hash() as usize & mask;
                while self.method_inst_index[i] != 0xFFFFFFFFu32 {
                    i = i + 1 & mask;
                }
                self.method_inst_index.set(i, id as u32);
            }
        }
        let mask = self.method_inst_index.len() - 1;
        let ixp = self.method_inst_index.as_ptr();
        let pp = self.method_insts.as_ptr();
        let pn = self.method_insts.len();
        let mut i = mi.hash() as usize & mask;
        loop {
            let cur = unsafe ixp[i];
            if cur == 0xFFFFFFFFu32 {
                self.method_inst_index.set(i, self.method_insts.len() as u32);
                self.mi_ix_used = self.mi_ix_used + 1;
                self.method_insts.push(mi);
                return true;
            }
            if cur as usize < pn && unsafe pp[cur as usize] == mi {
                return false;
            }
            i = i + 1 & mask;
        }
    }

    /// Record a decl's lifetime params (no-op for the overwhelmingly common empty case).
    pub fn set_lifetimes(self: &mut Self, owner: NodeId, list: NodeList) {
        if list.len == 0 {
            return;
        }
        self.lifetime_decls.push(LifetimeDecl { owner: owner, list: list });
    }

    pub fn lifetimes_of(self: &Self, owner: NodeId) NodeList {
        for i in 0..self.lifetime_decls.len() {
            if self.lifetime_decls.at(i).owner == owner {
                return self.lifetime_decls.at(i).list;
            }
        }
        return NodeList { start: 0, len: 0 };
    }

    pub fn add_attr(self: &mut Self, attr: Attr) {
        self.attrs.push(attr);
    }

    pub fn type_concrete(self: &Self, t: TypeId) bool {
        let ty = self.type_at(t);
        return switch ty.kind {
            TYPE_GENERIC => false,
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE | TYPE_ARRAY => self.type_concrete(ty.as_data.elem),
            TYPE_INSTANCE => {
                let it = self.instance(ty.as_data.inst);
                for i in 0..it.n {
                    if !self.type_concrete(unsafe it.args[i]) {
                        return false;
                    }
                }
                true;
            },
            _ => true,
        };
    }

    /// Re-interns `src`'s type `t` into THIS Ast, rebuilding element and instance payloads
    /// recursively -- TypeIds are per-Ast and never transfer directly.
    pub fn reintern(self: &mut Self, src: &Ast, t: TypeId) TypeId {
        if t == TYPE_NONE {
            return t;
        }
        let ty = *src.type_at(t);
        return switch ty.kind {
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE | TYPE_ARRAY => {
                let mut nt = ty;
                nt.as_data.elem = self.reintern(src, ty.as_data.elem);
                self.intern_type(nt);
            },
            TYPE_INSTANCE => {
                let inst = *src.instance(ty.as_data.inst);
                let mut na: [TypeId; 8] = [0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32];
                for i in 0..inst.n {
                    unsafe na[i] = self.reintern(src, unsafe inst.args[i]);
                }
                self.intern_instance(inst.module, inst.decl, &na[0], inst.n);
            },
            TYPE_DYN => {
                // dyn payload is an instance index (interface + optional type args): remap it
                // into this Ast's instance table, preserving kind/qualifier/module
                let inst = *src.instance(ty.as_data.inst);
                let mut na: [TypeId; 8] = [0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u32];
                for i in 0..inst.n {
                    unsafe na[i] = self.reintern(src, unsafe inst.args[i]);
                }
                let ii = self.intern_instance(inst.module, inst.decl, &na[0], inst.n);
                let mut nd = ty;
                nd.as_data.inst = self.type_at(ii).as_data.inst;
                self.intern_type(nd);
            },
            _ => self.intern_type(ty),
        };
    }

    /// Records the concrete type args a use site instantiates with. `n` is clamped to 8. Safety:
    /// `args` must point at `n` readable TypeIds.
    pub fn set_type_args(self: &mut Self, node: NodeId, args: *const TypeId, n: u8) {
        let mut m = n;
        if m > 8 {
            m = 8;
        }
        let mut u = MonoUse { node: node, n: m };
        for i in 0..m {
            unsafe u.args[i] = unsafe args[i];
        }
        self.mono.push(u);
        ensure_u32_len(&mut self.mono_at, self.nodes.len(), node as usize + 1);
        self.mono_at[node as usize] = self.mono.len() as u32;
    }

    /// The type args recorded for `node`, or null if none.
    pub const fn type_args(self: &Self, node: NodeId) *const MonoUse {
        if node as usize >= self.mono_at.len() {
            return null;
        }
        let idx = self.mono_at[node as usize];
        if idx == 0 {
            return null;
        }
        return self.mono.at((idx - 1) as usize);
    }

    pub fn add_dyn_use(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId) {
        self.add_dyn_use_alloc(node, src, dyn_ty, TYPE_NONE);
    }
    pub fn add_dyn_use_alloc(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId, alloc: TypeId) {
        self.dyn_uses.push(DynUse { node: node, src: src, dyn_ty: dyn_ty, alloc: alloc });
        ensure_u32_len(&mut self.dyn_at, self.nodes.len(), node as usize + 1);
        self.dyn_at[node as usize] = self.dyn_uses.len() as u32;
    }

    /// The dyn-erasure recorded at `node`, or null if none.
    pub const fn dyn_use_at(self: &Self, node: NodeId) *const DynUse {
        if node as usize >= self.dyn_at.len() {
            return null;
        }
        let idx = self.dyn_at[node as usize];
        if idx == 0 {
            return null;
        }
        return self.dyn_uses.at((idx - 1) as usize);
    }

    pub fn add_deref_use(self: &mut Self, du: &DerefUse) {
        self.deref_uses.push(*du);
        ensure_u32_len(&mut self.deref_at, self.nodes.len(), du.node as usize + 1);
        self.deref_at[du.node as usize] = self.deref_uses.len() as u32;
    }

    /// The auto-deref chain recorded at `node`, or null if none.
    pub const fn deref_use_at(self: &Self, node: NodeId) *const DerefUse {
        if node as usize >= self.deref_at.len() {
            return null;
        }
        let idx = self.deref_at[node as usize];
        if idx == 0 {
            return null;
        }
        return self.deref_uses.at((idx - 1) as usize);
    }

    pub const fn at(self: &mut Self, id: NodeId) &mut Node {
        return &mut self.nodes[id as usize];
    }
    pub const fn at_const(self: &Self, id: NodeId) &Node {
        return self.nodes.at(id as usize);
    }
    pub const fn list(self: &Self, list: NodeList) *const NodeId {
        return unsafe (self.children.as_ptr() + list.start as usize);
    }
    /// Resolves `ref_id` to a decl in THIS module (the DefId is stamped with `self.module`); use
    /// set_resolution_def for a foreign target.
    pub const fn set_resolution(self: &mut Self, ref_id: NodeId, decl: NodeId) {
        self.resolutions[ref_id as usize] = DefId { module: self.module, node: decl };
    }
    /// The resolved decl node with its module DROPPED -- use resolution_def when the target may
    /// live in another module.
    pub const fn resolution(self: &Self, ref_id: NodeId) NodeId {
        return self.resolutions[ref_id as usize].node;
    }
    pub const fn resolution_def(self: &Self, ref_id: NodeId) DefId {
        return self.resolutions[ref_id as usize];
    }
    pub const fn set_resolution_def(self: &mut Self, ref_id: NodeId, decl: DefId) {
        self.resolutions[ref_id as usize] = decl;
    }
    /// Builtin TypeIds are fixed by init_types' seeding: pool slot 0 is TYPE_ERROR, then the
    /// builtins in enum order -- hence b + 1.
    pub const fn builtin(b: BuiltinType) TypeId {
        return b as TypeId + 1;
    }
    pub const fn set_type(self: &mut Self, n: NodeId, t: TypeId) {
        self.types[n as usize] = t;
    }
    pub const fn type_of(self: &Self, n: NodeId) TypeId {
        return self.types[n as usize];
    }
    pub const fn type_at(self: &Self, t: TypeId) &Ty {
        return self.type_pool.at(t as usize);
    }
}

fn ensure_u32_len(v: &mut Vector<u32>, nodes_len: usize, need: usize) {
    let mut want = need;
    if nodes_len > want {
        want = nodes_len;
    }
    v.reserve(want);
    while v.len() < want {
        v.push(0);
    }
}

extend Ast as Free {
    pub fn free(self: &mut Self) {
        self.nodes.free();
        self.children.free();
        self.scratch.free();
        self.resolutions.free();
        self.type_pool.free();
        self.type_index.free();
        self.types.free();
        self.mono.free();
        self.mono_at.free();
        self.instances.free();
        self.method_insts.free();
        self.instance_index.free();
        self.method_inst_index.free();
        self.dyn_uses.free();
        self.dyn_at.free();
        self.deref_uses.free();
        self.deref_at.free();
        self.attrs.free();
        self.lifetime_decls.free();
        self.call_info.free();
    }
}

/// The builtin type a numeric literal's suffix names, or BT_COUNT if it has none. On a match,
/// *sfx_start (when non-null) receives the suffix's start offset. In a hex literal, f32/f64 only
/// count as a suffix after a 'p' exponent -- otherwise those bytes are hex digits.
pub fn ast_numeric_suffix(src: str, start: u32, end: u32, sfx_start: *mut u32) BuiltinType {
    let hex = end - start > 2 && src[start as usize] == b'0' && (src[(start + 1) as usize] | 0x20u8) == b'x';
    let mut hexf = false;
    let mut i = start + 2;
    while hex && i < end && !hexf {
        hexf = (src[i as usize] | 0x20u8) == b'p';
        i = i + 1;
    }
    if end - start > 5 && unsafe cstring::memcmp(unsafe (src.ptr() + (end - 5) as usize), "isize".ptr(), 5) == 0 {
        if sfx_start != null {
            unsafe *sfx_start = end - 5;
        }
        return BuiltinType::BT_ISIZE;
    }
    if end - start > 5 && unsafe cstring::memcmp(unsafe (src.ptr() + (end - 5) as usize), "usize".ptr(), 5) == 0 {
        if sfx_start != null {
            unsafe *sfx_start = end - 5;
        }
        return BuiltinType::BT_USIZE;
    }
    let mut n: u32 = 3;
    if end - start > n {
        let p = unsafe (src.ptr() + (end - n) as usize);
        if unsafe cstring::memcmp(p, "i16".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_I16;
        }
        if unsafe cstring::memcmp(p, "i32".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_I32;
        }
        if unsafe cstring::memcmp(p, "i64".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_I64;
        }
        if unsafe cstring::memcmp(p, "u16".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_U16;
        }
        if unsafe cstring::memcmp(p, "u32".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_U32;
        }
        if unsafe cstring::memcmp(p, "u64".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_U64;
        }
        if (!hex || hexf) && unsafe cstring::memcmp(p, "f32".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_F32;
        }
        if (!hex || hexf) && unsafe cstring::memcmp(p, "f64".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_F64;
        }
    }
    n = 2;
    if end - start > n {
        let p = unsafe (src.ptr() + (end - n) as usize);
        if unsafe cstring::memcmp(p, "i8".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_I8;
        }
        if unsafe cstring::memcmp(p, "u8".ptr(), n as usize) == 0 {
            if sfx_start != null {
                unsafe *sfx_start = end - n;
            }
            return BuiltinType::BT_U8;
        }
    }
    return BuiltinType::BT_COUNT;
}
