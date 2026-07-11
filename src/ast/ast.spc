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
}
pub struct WherePredicateData {
    pub ty: NodeId,
    pub bounds: NodeList,
}
pub struct TypePathData {
    pub parts: NodeList,
    pub args: NodeList,
}
pub struct IndirectTypeData {
    pub ty: NodeId,
    pub qualifier: TypeQualifier,
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
        let p = self as *const Ty as *const u64;
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
    pub args: [TypeId; 4],
}
pub struct MonoUse {
    pub node: NodeId,
    pub n: u8,
    pub args: [TypeId; 4],
}
pub struct DynUse {
    pub node: NodeId,
    pub src: TypeId,
    pub dyn_ty: TypeId,
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
    pub targs: [TypeId; 4],
}

// Field-wise Hash/Eq over the SIGNIFICANT prefix (module/decl/n + args[0..n]) — deliberately NOT a
// sizeof-memcmp, so the unused args[n..4] tail (left uninitialized by the `{module,decl,n}` literal) can
// never affect identity. This exactly mirrors intern_instance's linear comparison, keeping the interned
// index numbering byte-identical.
extend TyInstance as Hash {
    pub fn hash(self: &Self) u64 {
        let mut h: u64 = 1469598103934665603u64;
        h = (h ^ self.module as u64) * 1099511628211u64;
        h = (h ^ self.decl as u64) * 1099511628211u64;
        h = (h ^ self.n as u64) * 1099511628211u64;
        for i in 0..self.n {
            h = (h ^ self.args[i] as u64) * 1099511628211u64;
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
            if self.args[i] != other.args[i] {
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
            h = (h ^ self.targs[i] as u64) * 1099511628211u64;
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
            if self.targs[i] != other.targs[i] {
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
    pub resolutions: Vector<DefId>,
    pub type_pool: Vector<Ty>,
    pub type_index: Map<Ty, TypeId>,
    pub types: Vector<u32>,
    pub mono: Vector<MonoUse>,
    pub mono_at: Vector<u32>,
    pub instances: Vector<TyInstance>,
    pub method_insts: Vector<MethodInst>,
    // O(1) dedupe HINT indices mirroring instances/method_insts (TC-2): key -> its position. A hint because
    // codegen truncate()s `instances` during owner-swap emission, so a lookup always VERIFIES the hinted slot
    // still holds the same value before trusting it (else falls through to a fresh push) — self-healing.
    pub instance_index: Map<TyInstance, u32>,
    pub method_inst_index: Map<MethodInst, u32>,
    pub dyn_uses: Vector<DynUse>,
    pub dyn_at: Vector<u32>,
    pub deref_uses: Vector<DerefUse>,
    pub deref_at: Vector<u32>,
    pub attrs: Vector<Attr>,
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
            type_index: Map::<Ty, TypeId>::new(),
            types: Vector::<u32>::new(),
            mono: Vector::<MonoUse>::new(),
            mono_at: Vector::<u32>::new(),
            instances: Vector::<TyInstance>::new(),
            method_insts: Vector::<MethodInst>::new(),
            instance_index: Map::<TyInstance, u32>::new(),
            method_inst_index: Map::<MethodInst, u32>::new(),
            dyn_uses: Vector::<DynUse>::new(),
            dyn_at: Vector::<u32>::new(),
            deref_uses: Vector::<DerefUse>::new(),
            deref_at: Vector::<u32>::new(),
            attrs: Vector::<Attr>::new(),
            root: NODE_NONE,
            module: 0,
        };
        a.nodes.reserve(token_count);
        a.children.reserve(token_count / 2);
        a.nodes.push(Node { kind: NodeKind::NODE_NONE_KIND });
        return a;
    }

    pub fn add(self: &mut Self, node: Node) NodeId {
        let id = self.nodes.len() as NodeId;
        self.nodes.push(node);
        return id;
    }

    pub fn mark(self: &Self) u32 {
        return self.scratch.len() as u32;
    }
    pub fn push(self: &mut Self, id: NodeId) void {
        self.scratch.push(id);
    }

    pub fn commit(self: &mut Self, mark: u32) NodeList {
        let list = NodeList { start: self.children.len() as u32, len: self.scratch.len() as u32 - mark };
        for i in mark as usize..self.scratch.len() {
            self.children.push(self.scratch[i]);
        }
        self.scratch.truncate(mark as usize);
        return list;
    }

    pub fn init_resolutions(self: &mut Self) void {
        self.resolutions.clear();
        self.resolutions.reserve(self.nodes.len());
        for _ in 0..self.nodes.len() {
            self.resolutions.push(DefId { module: 0, node: NODE_NONE });
        }
    }

    pub fn init_types(self: &mut Self) void {
        self.types.clear();
        self.types.reserve(self.nodes.len());
        for _ in 0..self.nodes.len() {
            self.types.push(TYPE_NONE);
        }
        self.type_pool.clear();
        self.type_index = Map::<Ty, TypeId>::new();
        let err = Ty { kind: TypeKind::TYPE_ERROR };
        self.type_pool.push(err);
        self.type_index.insert(err, 0);
        for b in 0..BuiltinType::BT_COUNT as u8 {
            let t = Ty { kind: TypeKind::TYPE_BUILTIN, as_data: TyAs { builtin: b as BuiltinType } };
            self.type_pool.push(t);
            self.type_index.insert(t, b as TypeId + 1);
        }
    }

    pub fn intern_type(self: &mut Self, t: Ty) TypeId {
        return switch self.type_index.get(&t) {
            Some(id) => *id,
            None => {
                let id = self.type_pool.len() as TypeId;
                self.type_pool.push(t);
                self.type_index.insert(t, id);
                id;
            },
        };
    }

    pub fn intern_instance(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8) TypeId {
        let mut m = n;
        if m > 4 {
            m = 4;
        }
        let mut it = TyInstance { module: module, decl: decl, n: m };
        for j in 0..m {
            it.args[j] = unsafe args[j];
        }
        let hinted = switch self.instance_index.get(&it) {
            Some(id) => *id,
            None => 0xFFFFFFFFu32,
        };
        let cur = self.instances.len();
        let mut idx = cur as u32;
        let mut valid = false;
        if hinted != 0xFFFFFFFFu32 && hinted as usize < cur {
            valid = self.instances.at(hinted as usize).eq(&it);
        }
        if valid {
            idx = hinted;
        } else {
            self.instances.push(it);
            self.instance_index.insert(it, idx);
        }
        return self.intern_type(Ty { kind: TypeKind::TYPE_INSTANCE, module: module, as_data: TyAs { inst: idx } });
    }

    pub fn instance(self: &Self, index: u32) &TyInstance {
        return self.instances.at(index as usize);
    }

    // A const-generic argument value, interned as a module-independent TYPE_CONST.
    pub fn const_value(self: &mut Self, v: i64) TypeId {
        return self.intern_type(Ty { kind: TypeKind::TYPE_CONST, module: 0, as_data: TyAs { value: v } });
    }

    pub fn add_method_inst(self: &mut Self, instance: TypeId, method: NodeId, targs: *const TypeId, n: u8) bool {
        let mut m = n;
        if m > 4 {
            m = 4;
        }
        let mut mi = MethodInst { instance: instance, method: method, n: m };
        for j in 0..m {
            mi.targs[j] = unsafe targs[j];
        }
        let hinted = switch self.method_inst_index.get(&mi) {
            Some(id) => *id,
            None => 0xFFFFFFFFu32,
        };
        if hinted != 0xFFFFFFFFu32 && hinted as usize < self.method_insts.len() && self.method_insts.at(hinted as usize).eq(
            &mi,
        ) {
            return false;
        }
        let idx = self.method_insts.len() as u32;
        self.method_insts.push(mi);
        self.method_inst_index.insert(mi, idx);
        return true;
    }

    pub fn add_attr(self: &mut Self, attr: Attr) void {
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
                    if !self.type_concrete(it.args[i]) {
                        return false;
                    }
                }
                true;
            },
            _ => true,
        };
    }

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
                let mut na: [TypeId; 4] = [0u32, 0u32, 0u32, 0u32];
                for i in 0..inst.n {
                    na[i] = self.reintern(&*src, inst.args[i]);
                }
                self.intern_instance(inst.module, inst.decl, &na[0], inst.n);
            },
            _ => self.intern_type(ty),
        };
    }

    pub fn set_type_args(self: &mut Self, node: NodeId, args: *const TypeId, n: u8) void {
        let mut m = n;
        if m > 4 {
            m = 4;
        }
        let mut u = MonoUse { node: node, n: m };
        for i in 0..m {
            u.args[i] = unsafe args[i];
        }
        self.mono.push(u);
        ensure_u32_len(&mut self.mono_at, self.nodes.len(), node as usize + 1);
        self.mono_at[node as usize] = self.mono.len() as u32;
    }

    pub fn type_args(self: &Self, node: NodeId) *const MonoUse {
        if node as usize >= self.mono_at.len() {
            return null;
        }
        let idx = self.mono_at[node as usize];
        if idx == 0 {
            return null;
        }
        return self.mono.at((idx - 1) as usize) as *const MonoUse;
    }

    pub fn add_dyn_use(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId) void {
        self.dyn_uses.push(DynUse { node: node, src: src, dyn_ty: dyn_ty });
        ensure_u32_len(&mut self.dyn_at, self.nodes.len(), node as usize + 1);
        self.dyn_at[node as usize] = self.dyn_uses.len() as u32;
    }

    pub fn dyn_use_at(self: &Self, node: NodeId) *const DynUse {
        if node as usize >= self.dyn_at.len() {
            return null;
        }
        let idx = self.dyn_at[node as usize];
        if idx == 0 {
            return null;
        }
        return self.dyn_uses.at((idx - 1) as usize) as *const DynUse;
    }

    pub fn add_deref_use(self: &mut Self, du: &DerefUse) void {
        self.deref_uses.push(*du);
        ensure_u32_len(&mut self.deref_at, self.nodes.len(), du.node as usize + 1);
        self.deref_at[du.node as usize] = self.deref_uses.len() as u32;
    }

    pub fn deref_use_at(self: &Self, node: NodeId) *const DerefUse {
        if node as usize >= self.deref_at.len() {
            return null;
        }
        let idx = self.deref_at[node as usize];
        if idx == 0 {
            return null;
        }
        return self.deref_uses.at((idx - 1) as usize) as *const DerefUse;
    }

    pub fn at(self: &mut Self, id: NodeId) &mut Node {
        return &mut self.nodes[id as usize];
    }
    pub fn at_const(self: &Self, id: NodeId) &Node {
        return self.nodes.at(id as usize);
    }
    pub fn list(self: &Self, list: NodeList) *const NodeId {
        return unsafe (self.children.as_ptr() + list.start as usize);
    }
    pub fn set_resolution(self: &mut Self, ref_id: NodeId, decl: NodeId) void {
        self.resolutions[ref_id as usize] = DefId { module: self.module, node: decl };
    }
    pub fn resolution(self: &Self, ref_id: NodeId) NodeId {
        return self.resolutions[ref_id as usize].node;
    }
    pub fn resolution_def(self: &Self, ref_id: NodeId) DefId {
        return self.resolutions[ref_id as usize];
    }
    pub fn set_resolution_def(self: &mut Self, ref_id: NodeId, decl: DefId) void {
        self.resolutions[ref_id as usize] = decl;
    }
    pub fn builtin(b: BuiltinType) TypeId {
        return b as TypeId + 1;
    }
    pub fn set_type(self: &mut Self, n: NodeId, t: TypeId) void {
        self.types[n as usize] = t;
    }
    pub fn type_of(self: &Self, n: NodeId) TypeId {
        return self.types[n as usize];
    }
    pub fn type_at(self: &Self, t: TypeId) &Ty {
        return self.type_pool.at(t as usize);
    }
}

fn ensure_u32_len(v: &mut Vector<u32>, nodes_len: usize, need: usize) void {
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
    pub fn free(self: &mut Self) void {
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
    }
}

pub fn ast_numeric_suffix(src: *const u8, start: u32, end: u32, sfx_start: *mut u32) BuiltinType {
    let hex = end - start > 2 && unsafe src[start] == b'0' && (unsafe src[start + 1] | 0x20u8) == b'x';
    let mut hexf = false;
    let mut i = start + 2;
    while hex && i < end && !hexf {
        hexf = (unsafe src[i] | 0x20u8) == b'p';
        i = i + 1;
    }
    if end - start > 5 && unsafe cstring::memcmp(unsafe src + end - 5, "isize".ptr(), 5) == 0 {
        if sfx_start != null {
            unsafe *sfx_start = end - 5;
        }
        return BuiltinType::BT_ISIZE;
    }
    if end - start > 5 && unsafe cstring::memcmp(unsafe src + end - 5, "usize".ptr(), 5) == 0 {
        if sfx_start != null {
            unsafe *sfx_start = end - 5;
        }
        return BuiltinType::BT_USIZE;
    }
    let mut n: u32 = 3;
    if end - start > n {
        let p = unsafe (src + (end - n) as usize);
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
        let p = unsafe (src + (end - n) as usize);
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
