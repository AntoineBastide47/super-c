// The per-module AST and type arena. Nodes live in one flat Vector indexed by NodeId (0 = NODE_NONE);
// child lists are (start, len) windows into `children`, built through `scratch` via mark/push/commit.
// Types are interned: TypeIds number `type_pool` in INSERTION order, so interned identity (and every
// downstream emission) is independent of hashing. Analysis results for later passes hang off NodeIds
// in side tables (resolutions, types, mono/dyn/deref uses, attrs, lifetime_decls, call_info).
import string as cstring;
import atomic;
import sc_runtime;
import std::parallel::sync as psy;
import lexer::token as tok;
import lexer::token_type as tt;

pub type NodeId = u32;
pub const NODE_NONE: NodeId = 0;
/// Bit 30 of a NodeId (and of a NodeList start) names the module's body arena (`Ast.b`): the
/// syntax of releasable bodies. Every other id indexes the module arena (`Ast.nodes`).
pub const NODE_BODY: u32 = 0x40000000;
pub const NODE_BODY_MASK: u32 = 0x3FFFFFFF;

pub struct NodeList {
    pub start: u32,
    pub len: u32,
}
pub type ModuleId = u16;

/// The emission facts of a function type's declaration node (`Ast::closure_fact`): a closure
/// (`is_closure`) or a `fn(..)` type written in a body. From `cap_start` in `cap_facts`: its
/// `ncaps` captures in capture order, then its `nparams` parameter types, then its `nrets` return
/// types (one entry, possibly TYPE_NONE, for an expression-bodied closure); and the closure's
/// mutable-capture mask.
pub struct ClosureFact {
    pub node: NodeId,
    pub is_closure: bool,
    pub nparams: u32,
    pub nrets: u32,
    pub ncaps: u32,
    pub cap_start: u32,
    pub mut_caps: u64,
}

/// One capture (the captured binding's name text and its type) or one signature type (empty name).
pub struct CapFact {
    pub name: tok::Span,
    pub ty: TypeId,
}

/// One seeded resolution (`Ast::seed_resolution`).
pub struct Seed {
    pub at: NodeId,
    pub def: DefId,
}

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
    ATTR_ARCH,
    ATTR_FMT_SKIP,
    ATTR_BLOCKING,
    // Appended, never inserted: attribute kinds are mirrored by position elsewhere, so adding one in
    // the middle silently renumbers the rest.
    ATTR_BENCH,
    ATTR_NO_CONST,
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

/// One `@reflect(key = value)` entry, in its own side table: the key/value payload does not fit
/// Attr, and the consumers (the type_info graph builder, the binder members) read it by OWNER.
/// `vkind`: 0 = bool (a bare key is `true`), 1 = int, 2 = string (`vspan` is the content, no
/// quotes; spans index the owning module's source).
pub struct MetaAttr {
    pub owner: NodeId,
    pub vkind: u8,
    pub ival: i64,
    pub key: tok::Span,
    pub vspan: tok::Span,
}

pub enum TypeQualifier {
    TYPE_QUAL_NONE,
    TYPE_QUAL_CONST,
    TYPE_QUAL_MUT,
}

/// Which operation a `select` arm waits on. Classified by the parser from the arm's expression shape, so
/// no later pass has to re-read the source text.
pub enum SelectArmKind {
    SELECT_RECV, // `ch.recv()`
    SELECT_SEND, // `ch.send(v)`
    SELECT_TIMEOUT, // `timeout(d)`
    SELECT_DEFAULT, // `default`
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
    NODE_ASM,
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
    // the HIR lowering (src/hir) before typecheck -- no other pass sees it. NODE_LAUNCH carries CallData
    // (a placeholder callee + the operand as the sole arg); desugar seeds the callee's resolution to the
    // runtime shim and flips the kind to NODE_CALL.
    NODE_LAUNCH,
    // `select { .. }`: a NODE_SELECT holding NODE_SELECT_ARM children (BlockData). Desugar rewrites the
    // whole thing into a block that builds a `std::parallel::selector::Selector`, arms it, waits, and runs
    // the winning arm's body -- see src/hir.
    NODE_SELECT,
    NODE_SELECT_ARM,
    // `inline for i in a..b { .. }` (ForData): unrolled at emission -- the bounds must fold to
    // compile-time constants; the body is emitted once per value with `i` a const binding. Checked
    // like NODE_FOR everywhere; break/continue inside are rejected at typecheck.
    NODE_INLINE_FOR,
    // `parallel for i in a..b { .. }` (ForData): sugar for std::parallel::data::range(a..b, body as
    // closure); desugared post-resolve (src/hir), so later passes never see it.
    NODE_PARALLEL_FOR,
    // An interpolating matchertext literal `M{}"(a {hole} b)"` (BlockData): children alternate
    // verbatim segment literals (seg=true, MatchertextLiteral) and hole expressions. Typecheck
    // rewrites it in place into the same `sugar_fmt_*` value block `format()` desugars to, so
    // borrowck/const-eval/codegen never see this kind.
    NODE_INTERP,
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
    // `format` desugar segment: `raw` is BARE content (no quotes) inside a template literal, and
    // doubled braces in it collapse to one on emission/evaluation. Parser-built literals never set this.
    pub seg: bool,
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
    /// Declared inside an `extern "C" "hdr.h"` block: the HEADER defines this type, and the members here
    /// only state its layout. Codegen emits no definition for it and spells it the way C does, so the
    /// binding's type IS the C one; the layout static_assert then checks that claim against the header.
    pub is_extern: bool,
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
    // `unsafe extend T as I {}`: the conformance asserts something the compiler cannot check, so the author
    // carries the obligation. Parsed and preserved; nothing requires it yet.
    pub is_unsafe: bool,
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
/// table lives here too: the typechecker's renderer/lookup delegates to it, and const-eval uses it to
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
/// `asm("tpl" : outs : ins : clobbers)`, GCC extended assembly passed through to the C compiler.
/// `outputs`/`inputs` hold FLAT PAIRS -- constraint literal, then its expression -- so an operand needs
/// no node kind of its own; `clobbers` holds bare string literals.
pub struct AsmData {
    pub template: NodeId,
    pub outputs: NodeList,
    pub inputs: NodeList,
    pub clobbers: NodeList,
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
// One `select` arm, pre-desugar. `binding` is a value-less NODE_LET the parser builds for `v = ch.recv()`
// (NODE_NONE when the arm binds nothing) -- it exists at RESOLVE time so the body's uses of `v` bind to it,
// and desugar fills in its value. The operation is stored TAKEN APART (the `.recv()`/`.send()`/`timeout()`
// call node is dropped at parse time), so no pass has to re-derive it and no synthetic callee ever reaches
// the resolver; the formatter reprints the surface syntax from the pieces.
pub struct SelectArmData {
    pub binding: NodeId,
    pub op: NodeId, // the channel (recv/send), the duration (timeout), NODE_NONE (default)
    pub value: NodeId, // the sent expression (send), else NODE_NONE
    pub body: NodeId,
    pub kind: SelectArmKind,
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
    pub asm_stmt: AsmData,
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
    pub select_arm: SelectArmData,
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
    /// A const-generic argument written as an EXPRESSION over the enclosing generic's own parameters
    /// (`UInt<{BITS * 2}>`). It cannot be a value yet -- those parameters are unbound where it is written --
    /// so it carries the expression (`module` + `as_data.decl`) until substitution folds it to a TYPE_CONST.
    /// Never concrete, so no instance is ever emitted while one is still in the arguments.
    TYPE_CONST_EXPR,
    /// `f.value` inside `inline for f in fields(&v)`: the I-th field of `owner`, where I is the
    /// iteration the emitted copy belongs to. Symbolic like TYPE_CONST_EXPR -- it names a type the
    /// enclosing generic cannot know yet; substitution plus the emitter's current-field state
    /// normalize it to the field's concrete type, one copy at a time. Never concrete.
    TYPE_FIELD_PROJECTION,
}

/// A const-generic expression in canonical form: `k + sum(c_i * P_i)`. Linear is exactly the closed set
/// for widths -- `+`, `-` and scaling by a constant stay inside it, `N * N` does not -- and comparing
/// these instead of the expressions as WRITTEN is what makes two spellings of one width the same type.
pub struct ConstLin {
    pub k: i64,
    pub n: i32,
    pub p: [DefId; 4],
    pub c: [i64; 4],
    /// Floor divisor applied to the WHOLE form, last: value = (k + sum) / div. 0 or 1 = none. What
    /// admits `{(BITS + 7) / 8}` -- the byte count every serialization API is generic over -- into
    /// canonical form; a divided form composes with nothing further (scaling or adding to it would
    /// need distribution floor division does not grant), so every combinator below refuses one.
    pub div: i64,
}

extend ConstLin {
    pub const fn div_of(self: &Self) i64 {
        if self.div <= 1 {
            return 1;
        }
        return self.div;
    }

    pub const fn is_concrete(self: &Self) bool {
        for i in 0..self.n {
            if unsafe self.c[i as usize] != 0 {
                return false;
            }
        }
        return true;
    }

    /// The concrete value of a parameter-free form: the constant term through the floor divisor.
    pub const fn value(self: &Self) i64 {
        let d = self.div_of();
        if d == 1 {
            return self.k;
        }
        let q = self.k / d;
        if self.k % d != 0 && self.k < 0 {
            return q - 1;
        }
        return q;
    }

    pub fn add_term(self: &mut Self, d: DefId, coeff: i64) bool {
        if coeff == 0 {
            return true;
        }
        if self.div_of() != 1 {
            return false; // a term added AFTER the floor divisor would be divided; it was not written so
        }
        for i in 0..self.n {
            if unsafe self.p[i as usize].module == d.module && unsafe self.p[i as usize].node == d.node {
                unsafe {
                    self.c[i as usize] = self.c[i as usize] + coeff;
                }
                return true;
            }
        }
        if self.n >= 4 {
            return false;
        }
        unsafe {
            self.p[self.n as usize] = d;
        }
        unsafe {
            self.c[self.n as usize] = coeff;
        }
        self.n = self.n + 1;
        return true;
    }

    pub fn scale(self: &Self, f: i64, out: &mut ConstLin) bool {
        // Widths are small; a factor this large means the expression is running away, not describing a type.
        if f > 0x40000000 || f < 0 - 0x40000000 || self.k > 0x40000000 || self.k < 0 - 0x40000000 {
            return false;
        }
        if self.div_of() != 1 || out.div_of() != 1 {
            return false; // scaling does not distribute over the floor divisor
        }
        out.k = out.k + self.k * f;
        for i in 0..self.n {
            if !out.add_term(unsafe self.p[i as usize], unsafe self.c[i as usize] * f) {
                return false;
            }
        }
        return true;
    }
}

/// Substitute a const-expression form's parameters and accumulate the result into `out`. `src` holds
/// form `idx`; `params` are bound to `args`, which are types of `dst`. False when the result leaves the
/// linear set (a parameter bound to something that is not a width) -- the caller then keeps the form
/// unfolded rather than inventing a value for it.
pub fn lin_subst(
    dst: &Ast,
    src: &Ast,
    idx: u32,
    params: *const DefId,
    args: *const TypeId,
    n: i32,
    out: &mut ConstLin,
    depth: i32,
) bool {
    if depth > 12 {
        return false;
    }
    let form = *src.const_lin_at(idx);
    if form.div_of() != 1 {
        // The divisor covers the WHOLE form, so it transfers only onto an empty accumulator.
        if out.k != 0 || out.n != 0 || out.div_of() != 1 {
            return false;
        }
        out.div = form.div;
    }
    out.k = out.k + form.k;
    for i in 0..form.n {
        let coeff = unsafe form.c[i as usize];
        if coeff == 0 {
            continue;
        }
        let d = unsafe form.p[i as usize];
        let mut bound = TYPE_NONE;
        for j in 0..n {
            if unsafe params[j as usize].module == d.module && unsafe params[j as usize].node == d.node {
                bound = unsafe args[j as usize];
            }
        }
        if bound == TYPE_NONE {
            if !out.add_term(d, coeff) {
                return false;
            }
            continue;
        }
        let by = *dst.type_at(bound);
        if by.kind == TypeKind::TYPE_CONST {
            out.k = out.k + by.as_data.value * coeff;
            continue;
        }
        if by.kind == TypeKind::TYPE_CONST_EXPR {
            // Occurs-check: the payload is spelled in the OUTER scope, where `d` names the
            // caller's own parameter -- substituting d inside its own binding compounds the
            // width once per recursion (`F -> {F+96}` must widen exactly once).
            let mut fp = Vector::<DefId>::new();
            let mut fa = Vector::<TypeId>::new();
            for j in 0..n {
                let pj = unsafe params[j as usize];
                if pj.module == d.module && pj.node == d.node {
                    continue;
                }
                fp.push(pj);
                fa.push(unsafe args[j as usize]);
            }
            let mut inner = ConstLin { k: 0, n: 0 };
            if !lin_subst(dst, dst, by.as_data.inst, fp.as_ptr(), fa.as_ptr(), fp.len() as i32, &mut inner, depth + 1) {
                return false;
            }
            if inner.is_concrete() {
                out.k = out.k + inner.value() * coeff;
                continue;
            }
            if !inner.scale(coeff, out) {
                return false;
            }
            continue;
        }
        // Bound to ANOTHER parameter -- one generic passing its width to the next -- so the term
        // simply changes which parameter it names.
        if by.kind == TypeKind::TYPE_GENERIC {
            if !out.add_term(DefId { module: by.module, node: by.as_data.decl }, coeff) {
                return false;
            }
            continue;
        }
        return false;
    }
    return true;
}

/// Type identity counters (SC_TYPE_STATS=1): calls, hits, probe steps and root-call nanoseconds of
/// the interning, structural-key, cross-pool translation, instance-key and layout paths, reported by
/// the driver at the end of emission. Off, every instrumented path pays one load and one predictable
/// branch; on, the timed paths add one clock read per outermost call.
pub static mut TS_ON: bool = false;
/// SC_TYPE_COLLIDE=1: every type and instance hashes to one bucket, so the tables run on full
/// equality alone (the validation configuration for the collision path). Off, one predictable branch.
pub static mut TS_COLLIDE: bool = false;
pub static mut TS: [u64; TS_COUNT] = [[0] = 0u64];
pub static mut TS_LAST: [u64; TS_COUNT] = [[0] = 0u64];
pub static mut TS_DEPTH: u32 = 0; // reentry depth shared by the timed translation paths
pub const TS_INTERN: usize = 0; // intern_type calls
pub const TS_INTERN_HIT: usize = 1;
pub const TS_INTERN_PROBE: usize = 2; // extra probe steps (hash collisions)
pub const TS_INTERN_REBUILD: usize = 3;
pub const TS_INST: usize = 4; // intern_instance calls
pub const TS_INST_HIT: usize = 5;
pub const TS_INST_PROBE: usize = 6;
pub const TS_REINTERN: usize = 14; // reintern calls (every level)
pub const TS_REINTERN_NS: usize = 15;
pub const TS_XTY: usize = 16; // inliner xty calls (every level)
pub const TS_XTY_NS: usize = 17;
pub const TS_XTY_HIT: usize = 18; // inliner translation-map hits
pub const TS_LOWER: usize = 19; // foreign lower_type_in calls (every level)
pub const TS_LOWER_HIT: usize = 20; // lower_memo hits
pub const TS_LOWER_NS: usize = 21;
pub const TS_LOWER_MEMO_N: usize = 22; // lower_memo entries summed over modules
pub const TS_IGADD: usize = 23; // instance graph record interns
pub const TS_IGADD_HIT: usize = 24;
pub const TS_IGADD_NS: usize = 25;
pub const TS_IG_BYTES: usize = 26; // instance graph keys, records and index bytes
pub const TS_LAY: usize = 27; // cacheable layout queries
pub const TS_LAY_HIT: usize = 28;
pub const TS_LAY_SVC: usize = 29; // layout services (caches) created
pub const TS_XM_BYTES: usize = 30; // inliner translation-map bytes
pub const TS_FNSIG: usize = 31; // typechecker fn_sig calls (call-site signature lowering)
pub const TS_LAY_RAW: usize = 32; // layouts computed (cache misses and uncacheable queries)
pub const TS_LAY_NS: usize = 33;
pub const TS_DECLIN: usize = 34; // foreign decl_type_in calls (field, parameter and const types of other modules)
pub const TS_REBUILD_N: usize = 35; // pool entries re-hashed by index rebuilds
pub const TS_LOWER_SIG: usize = 36; // foreign lowerings made at item level (signature work, no enclosing body)
pub const TS_LAY_INS: usize = 37; // layout cache entries inserted (bytes: entries times the map slot)
pub const TS_COUNT: usize = 40;

/// Read SC_TYPE_STATS (idempotent).
pub fn ts_init() {
    unsafe TS_ON = stdlib::getenv("SC_TYPE_STATS") != null;
    unsafe TS_COLLIDE = stdlib::getenv("SC_TYPE_COLLIDE") != null;
}

pub fn ts_add(i: usize, v: u64) {
    unsafe TS[i] += v;
}

pub fn ts_get(i: usize) u64 {
    return unsafe TS[i];
}

pub fn ts_now() u64 {
    return unsafe sc_runtime::sc_rt_now_ns();
}

/// Print the counters' change since the previous phase line (SC_TYPE_STATS): the identity work each
/// pipeline phase did.
pub fn ts_phase(label: str) {
    if !unsafe TS_ON {
        return;
    }
    eprintln(
        "type-stats[{}]: intern {} inst {} | reintern {} ({} us) xty {} ({} us) lower {} ({} us) | ig-add {} ({} us) layout {}",
        label,
        ts_delta(TS_INTERN),
        ts_delta(TS_INST),
        ts_delta(TS_REINTERN),
        ts_delta(TS_REINTERN_NS) / 1000,
        ts_delta(TS_XTY),
        ts_delta(TS_XTY_NS) / 1000,
        ts_delta(TS_LOWER),
        ts_delta(TS_LOWER_NS) / 1000,
        ts_delta(TS_IGADD),
        ts_delta(TS_IGADD_NS) / 1000,
        ts_delta(TS_LAY),
    );
    eprintln(
        "type-stats[{}]: fn_sig {} foreign decl types {} foreign lowerings in signatures {} | layouts computed {} ({} us) cached {} | index rebuild entries {}",
        label,
        ts_delta(TS_FNSIG),
        ts_delta(TS_DECLIN),
        ts_delta(TS_LOWER_SIG),
        ts_delta(TS_LAY_RAW),
        ts_delta(TS_LAY_NS) / 1000,
        ts_delta(TS_LAY_INS),
        ts_delta(TS_REBUILD_N),
    );
    for i in 0..TS_COUNT {
        unsafe TS_LAST[i] = unsafe TS[i];
    }
}

fn ts_delta(i: usize) u64 {
    return unsafe TS[i] - unsafe TS_LAST[i];
}

/// One mixing round, the mixer behind type_skey and inst_method_key. A plain FNV-1a round is NOT
/// enough here: its output has no avalanche, so the small structured inputs these keys are built from
/// (node ids, const widths) land clustered, and two live (method, instance) pairs have collided in
/// practice -- silently dropping a demand seed. The splitmix64 finalizer after the FNV step makes
/// every input bit reach every output bit, which puts collisions at the 64-bit birthday bound.
pub const fn skey_mix(h: u64, v: u64) u64 {
    let mut x = (h ^ v) * 1099511628211u64;
    x = (x ^ x >> 30) * 0xBF58476D1CE4E5B9u64;
    x = (x ^ x >> 27) * 0x94D049BB133111EBu64;
    return x ^ x >> 31;
}

pub fn const_lin_eq(a: &ConstLin, b: &ConstLin) bool {
    if a.k != b.k || a.div_of() != b.div_of() {
        return false;
    }
    let mut na: i32 = 0;
    for i in 0..a.n {
        if unsafe a.c[i as usize] == 0 {
            continue;
        }
        na = na + 1;
        let mut found = false;
        for j in 0..b.n {
            if unsafe b.p[j as usize].module == unsafe a.p[i as usize].module && unsafe b.p[j as usize].node == unsafe a.p[i as usize].node && unsafe b.c[j as usize] == unsafe a.c[i as usize] {
                found = true;
            }
        }
        if !found {
            return false;
        }
    }
    let mut nb: i32 = 0;
    for j in 0..b.n {
        if unsafe b.c[j as usize] != 0 {
            nb = nb + 1;
        }
    }
    return na == nb;
}

pub struct TyArr {
    pub elem: TypeId,
    pub len: u32,
}
pub struct TyProj {
    pub owner: TypeId, // the reflected type (may be a generic param); Ty.module is the binder's module
    pub binder: NodeId, // the NODE_INLINE_FOR the projection belongs to
}
pub union TyAs {
    pub builtin: BuiltinType,
    pub elem: TypeId,
    pub decl: NodeId,
    pub inst: u32,
    pub arr: TyArr,
    pub value: i64, // TYPE_CONST: a const-generic value
    pub proj: TyProj, // TYPE_FIELD_PROJECTION
}
pub struct Ty {
    pub kind: TypeKind,
    pub qualifier: u8,
    pub concrete: bool,
    pub module: ModuleId,
    pub as_data: TyAs,
}

extend Ty as Hash {
    // Word-wise FNV over Ty's raw storage. Ty is 8-aligned (its `value: i64` forces alignof 8) and power-of-2
    // sized, so `sizeof(Ty)/8` aligned u64 loads cover every byte the per-byte loop did -- ~8x fewer rounds.
    // The hash only selects a probe bucket: `eq` stays a full memcmp and intern_type numbers TypeIds in
    // insertion order, so the hash function never affects interned identity or emitted output.
    pub fn hash(self: &Self) u64 {
        if unsafe TS_COLLIDE {
            return 7;
        }
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
/// One method reference the type checker resolved, with the receiver type it resolved it ON. The
/// receiver may still mention the enclosing generic's parameters, so what instance it stands for is
/// settled per instantiation (seed_mono_body_instances), not here. Recorded in the referring module's
/// own Ast so modules can be checked in parallel.
pub struct MethodRef {
    pub owner: NodeId, // the function or method the reference sits in; NODE_NONE at item level
    pub recv: TypeId,
    pub callee: DefId,
}

/// A wide integer literal: one whose value does not fit 64 bits, admitted where the expected type is
/// the prelude's UInt<N>/Int<N>. The typechecker parses the digits into STORED limbs here (already
/// two's-complemented and top-masked for a negative or partial width); codegen emits them as the
/// storage's compound literal. 16 limbs (1024 bits) is the cap -- a wider constant is built from parts.
pub struct WideLit {
    pub node: NodeId,
    pub ty: TypeId,
    pub limbs: [u64; 16],
}

/// A conversion the type checker inserted at an expression: `target::from(expr)`. What lets a library
/// integer stand where a built-in one is expected -- at an assignment, an argument, an operand or a cast.
/// `node` names the expression, so the loader can walk these records: a superseded entry (the node was
/// re-checked) is recognized by `coerce_at` no longer pointing at it.
pub struct CoerceUse {
    pub node: NodeId,
    pub target: TypeId,
    pub method: DefId,
}

// One deferred field-projection bound: prove `iface` for every field of `owner` once a call binds
// the owner; owned by fn decl `fnd` in this module.
pub struct ProjOb {
    pub fnd: NodeId,
    pub owner: TypeId,
    pub iface: DefId,
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
        if unsafe TS_COLLIDE {
            return 7;
        }
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

/// Realloc-stable append-only arena behind the intern pools. Entries NEVER move once pushed, so a
/// `&Ty`/`&TyInstance` handed out stays valid while another task appends -- the memory-safety half
/// of the freeze contract's "growth changes no existing answer". Writers must already hold the
/// owning module's intern serialization; readers are lock-free: an entry's bytes land before the
/// length's Release store, and `len()` reads Acquire. Capacity is fixed at POOL_SLOTS chunks;
/// exceeding it aborts (a pool that large indicates runaway interning, not a real program).
pub const POOL_SHIFT: usize = 12;
pub const POOL_CHUNK: usize = 1usize << 12;
pub const POOL_SLOTS: usize = 512;

pub struct ChunkPool<T> {
    tab: *mut *mut T,
    nchunks: u32,
    n: usize,
}

extend<T> ChunkPool<T> {
    pub const fn new() ChunkPool<T> {
        return ChunkPool::<T> { tab: null, nchunks: 0, n: 0 };
    }

    pub fn len(self: &Self) usize {
        return atomic::load_usize(&self.n, 1);
    }

    pub const fn at(self: &Self, i: usize) &T {
        return unsafe &*(unsafe self.tab[i >> POOL_SHIFT] + (i & POOL_CHUNK - 1));
    }

    pub fn push(self: &mut Self, v: T) {
        let i = self.n;
        if i >> POOL_SHIFT >= self.nchunks as usize {
            let mut g = Global {};
            if self.tab == null {
                self.tab = (unsafe g.alloc(POOL_SLOTS * sizeof(*mut T), alignof(*mut T))) as *mut *mut T;
            }
            if self.nchunks as usize >= POOL_SLOTS {
                panic("intern pool exceeded its fixed capacity");
            }
            unsafe self.tab[self.nchunks as usize] = (unsafe g.alloc(POOL_CHUNK * sizeof(T), alignof(T))) as *mut T;
            self.nchunks += 1;
        }
        unsafe (unsafe self.tab[i >> POOL_SHIFT])[i & POOL_CHUNK - 1] = v;
        atomic::store_usize(&mut self.n, i + 1, 2);
    }

    pub const fn index_mut(self: &mut Self, i: usize) &mut T {
        return unsafe &mut *(unsafe self.tab[i >> POOL_SHIFT] + (i & POOL_CHUNK - 1));
    }

    pub const fn set(self: &mut Self, i: usize, v: T) {
        unsafe (unsafe self.tab[i >> POOL_SHIFT])[i & POOL_CHUNK - 1] = v;
    }

    /// Pad with `v` until a run of `need` entries fits inside ONE chunk, then return its start:
    /// `list()` hands out raw pointers into a run, so a run must never straddle a chunk boundary.
    pub fn run_start(self: &mut Self, need: usize, v: T) usize {
        if need > POOL_CHUNK {
            panic("node list exceeds one arena chunk");
        }
        while (self.n & POOL_CHUNK - 1) + need > POOL_CHUNK {
            self.push(v);
        }
        return self.n;
    }

    /// Raw pointer to entry `i` (valid through the end of its chunk; entries never move). An
    /// index one past the end of the last chunk answers a stable dummy -- an empty run's start is
    /// never dereferenced.
    pub const fn ptr_at(self: &Self, i: usize) *const T {
        if self.tab == null || i >> POOL_SHIFT >= self.nchunks as usize {
            return self.tab as *const T;
        }
        return unsafe (self.tab[i >> POOL_SHIFT] + (i & POOL_CHUNK - 1));
    }

    /// Reset the length; chunks stay allocated for reuse.
    pub fn clear(self: &mut Self) {
        atomic::store_usize(&mut self.n, 0, 2);
    }

    pub const fn retained(self: &Self) usize {
        return self.nchunks as usize * POOL_CHUNK * sizeof(T);
    }
}

extend<T> ChunkPool<T> as Free {
    pub fn free(self: &mut Self) {
        if self.tab == null {
            return;
        }
        let mut g = Global {};
        for c in 0..self.nchunks as usize {
            unsafe g.dealloc(unsafe self.tab[c], POOL_CHUNK * sizeof(T), alignof(T));
        }
        unsafe g.dealloc(self.tab, POOL_SLOTS * sizeof(*mut T), alignof(*mut T));
        self.tab = null;
        self.nchunks = 0;
        self.n = 0;
    }
}

// usize MAX on every target width: the cast wraps the u64 value at the target's pointer width, so
// a 32-bit target gets 0xFFFFFFFF instead of a truncated always-false 64-bit literal.
const SV_UNFROZEN: usize = 0xFFFFFFFFFFFFFFFFu64 as usize;

/// Flat storage with a frontier-only overflow arena. Serial (unfrozen): a plain Vector -- one
/// predicted compare of overhead. `freeze()` pins the base allocation (its capacity is the split
/// point) so concurrent readers of PRE-EXISTING entries never see a realloc; growth past the pinned
/// capacity lands in realloc-stable chunks. `thaw()` folds the overflow back into the base once the
/// frontier joins, so every later stage reads a flat array again.
pub struct SplitVec<T> {
    base: Vector<T>,
    split: usize, // usize MAX when unfrozen
    ovf: ChunkPool<T>,
}

extend<T> SplitVec<T> {
    pub fn new() SplitVec<T> {
        return SplitVec::<T> { base: Vector::<T>::new(), split: SV_UNFROZEN, ovf: ChunkPool::<T>::new() };
    }

    pub fn len(self: &Self) usize {
        if self.split == SV_UNFROZEN {
            return self.base.len();
        }
        return self.base.len() + self.ovf.len();
    }

    pub const fn at(self: &Self, i: usize) &T {
        if i < self.split {
            return self.base.at(i);
        }
        return self.ovf.at(i - self.split);
    }

    pub const fn index_mut(self: &mut Self, i: usize) &mut T {
        if i < self.split {
            return self.base.index_mut(i);
        }
        return self.ovf.index_mut(i - self.split);
    }

    pub fn set(self: &mut Self, i: usize, v: T) {
        if i < self.split {
            self.base.set(i, v);
        } else {
            self.ovf.set(i - self.split, v);
        }
    }

    pub fn push(self: &mut Self, v: T) {
        if self.split == SV_UNFROZEN || self.base.len() < self.split {
            self.base.push(v);
        } else {
            self.ovf.push(v);
        }
    }

    pub fn reserve(self: &mut Self, n: usize) {
        if self.split == SV_UNFROZEN {
            self.base.reserve(n);
        }
    }

    /// The contiguous prefix: entries below `base_len` sit at `base_ptr() + i` (the rest, a frozen
    /// array's spill, through `ptr_at`). A scan reads the prefix without the per-entry split test.
    pub const fn base_len(self: &Self) usize {
        return self.base.len();
    }
    pub const fn base_ptr(self: &Self) *const T {
        return self.base.as_ptr();
    }

    /// Raw pointer to entry `i`: valid for the base region for the array's life while frozen, and
    /// within one overflow chunk otherwise. UNCHECKED like the flat array it replaces: an empty
    /// list's start sits one past the end and is never dereferenced.
    pub const fn ptr_at(self: &Self, i: usize) *const T {
        if i < self.split {
            return unsafe (self.base.as_ptr() + i);
        }
        return self.ovf.ptr_at(i - self.split);
    }

    /// Pad so a run of `need` fits contiguously (base region: reserve exactly; frozen spill: keep
    /// the run inside one chunk) and return its start.
    pub fn run_start(self: &mut Self, need: usize, v: T) usize {
        if self.split == SV_UNFROZEN || self.base.len() + need <= self.split {
            return self.base.len();
        }
        // straddling the split: pad the base to the pin, then place the run in the overflow
        while self.base.len() < self.split {
            self.base.push(v);
        }
        return self.split + self.ovf.run_start(need, v);
    }

    /// Pin the base allocation at its CURRENT capacity and route later growth to stable chunks.
    pub fn freeze(self: &mut Self) {
        if self.base.capacity() == self.base.len() {
            self.base.reserve(self.base.len() / 8 + 64); // headroom so small growth stays flat
        }
        self.split = self.base.capacity();
    }

    /// Fold the overflow back into the flat base (single-threaded; frontier pointers are dead).
    pub fn thaw(self: &mut Self) {
        if self.split == SV_UNFROZEN {
            return;
        }
        // the frozen push path filled base exactly to the pin before spilling
        for i in 0..self.ovf.len() {
            self.base.push(*self.ovf.at(i));
        }
        self.ovf.clear();
        self.split = SV_UNFROZEN;
    }

    pub const fn retained(self: &Self) usize {
        return self.base.capacity() * sizeof(T) + self.ovf.retained();
    }

    pub fn clear(self: &mut Self) {
        self.base.clear();
        self.ovf.clear();
        self.split = SV_UNFROZEN;
    }
}

/// `t` after a publication with `map` (final ids and TYPE_NONE pass through).
pub const fn pub_map1(map: &Vector<TypeId>, t: TypeId) TypeId {
    if (t & TYPE_PROV) == 0 {
        return t;
    }
    return map[(t & TYPE_PROV_MASK) as usize];
}

/// Provisional ids: a type interned into a module's pool while the package table is closed carries
/// this bit over its pool index until a publication maps it to a final package id. Final ids stay
/// below TYPE_MAX; the publication aborts the compile past it. Bit 29: the inference solver packs a
/// TypeId into a 30-bit term payload under two tag bits (`infer::it_pub`).
pub const TYPE_PROV: TypeId = 0x20000000;
pub const TYPE_PROV_MASK: TypeId = 0x1FFFFFFF;

/// A dense array index for any id: final ids take the even slots, provisional ids the odd ones, so
/// a memo indexed by type id stays proportional to the ids in use and never grows to `TYPE_PROV`.
pub const fn ty_dense(t: TypeId) usize {
    return (t & TYPE_PROV_MASK) as usize << 1 | (t >> 29 & 1) as usize;
}

/// A memo of three-state answers (unknown, false, true) packed two bits per slot: the slot index
/// is a dense type index, so a per-checker memo over the package id range costs a few kilobytes.
pub const fn memo2_get(v: &Vector<u64>, i: usize) i32 {
    let w = i >> 5;
    if w >= v.len() {
        return -1;
    }
    return (v[w] >> (i & 31) as u64 * 2 & 3) as i32 - 1;
}

pub fn memo2_set(v: &mut Vector<u64>, i: usize, r: bool) {
    let w = i >> 5;
    while v.len() <= w {
        v.push(0);
    }
    let sh = (i & 31) as u64 * 2;
    let mut val: u64 = 1;
    if r {
        val = 2;
    }
    v[w] = v[w] & ~(3u64 << sh) | val << sh;
}
pub const TYPE_MAX: TypeId = 0x1FFFFFF0;

/// A type pool: the Ty records, the instance and const-expression side tables, and the
/// open-addressing indexes over them (0xFFFFFFFF = empty slot; the pool entry is the key, so nothing
/// is stored twice, and every hit verifies the entry). Ids are dense insertion-order indices, so
/// identity never depends on the hash. One per module holds provisional types; the package's
/// (`Package.tt`) holds the published ones, `open` while a serial phase may append to it directly.
pub struct TypePool {
    pub tys: ChunkPool<Ty>,
    tix: Vector<u32>,
    tix_used: u32,
    pub insts: ChunkPool<TyInstance>,
    iix: Vector<u32>,
    iix_used: u32,
    pub clins: Vector<ConstLin>,
    pub open: bool,
}

extend TypePool {
    pub fn new() TypePool {
        return TypePool {
            tys: ChunkPool::<Ty>::new(),
            tix: Vector::<u32>::new(),
            tix_used: 0,
            insts: ChunkPool::<TyInstance>::new(),
            iix: Vector::<u32>::new(),
            iix_used: 0,
            clins: Vector::<ConstLin>::new(),
            open: false,
        };
    }

    pub fn free(self: &mut Self) {
        self.tys.free();
        self.tix.free();
        self.insts.free();
        self.iix.free();
        self.clins.free();
    }

    pub fn clear(self: &mut Self) {
        self.tys.clear();
        self.tix.clear();
        self.tix_used = 0;
        self.insts.clear();
        self.iix.clear();
        self.iix_used = 0;
        self.clins.clear();
    }

    /// The fixed prefix: slot 0 is TYPE_ERROR, then one TYPE_BUILTIN per builtin (`Ast::builtin`).
    /// Seeds pass through ty_canon like every interned entry, or their union tail bytes would be
    /// whatever the C compiler left there and byte-identity dedup would miss them.
    pub fn seed(self: &mut Self) {
        let _ = self.insert_ty(Ast::ty_canon(&Ty { kind: TypeKind::TYPE_ERROR, concrete: true }));
        for b in 0..BuiltinType::BT_COUNT as u8 {
            let _ = self.insert_ty(
                Ast::ty_canon(
                    &Ty { kind: TypeKind::TYPE_BUILTIN, concrete: true, as_data: TyAs { builtin: b as BuiltinType } },
                ),
            );
        }
    }

    pub const fn len(self: &Self) usize {
        return self.tys.len();
    }

    pub const fn at(self: &Self, i: usize) &Ty {
        return self.tys.at(i);
    }

    pub const fn ninst(self: &Self) usize {
        return self.insts.len();
    }

    pub const fn instance(self: &Self, i: usize) &TyInstance {
        return self.insts.at(i);
    }

    pub const fn nclin(self: &Self) usize {
        return self.clins.len();
    }

    pub const fn const_lin_at(self: &Self, i: usize) &ConstLin {
        return self.clins.at(i);
    }

    pub const fn retained(self: &Self) usize {
        return self.tys.retained() + self.tix.capacity() * 4 + self.insts.retained() + self.iix.capacity() * 4 + self.clins.capacity() * sizeof(ConstLin);
    }

    // Rebuild an index table over `pool_len` live pool ids (wipes stale slots). `used` resets to the
    // live count; sizing keeps the load after the rebuild strictly under the 0.75 trigger, so the next
    // call cannot rebuild again (an equal load rebuilt on every intern, hits included, until the pool
    // grew past the boundary: about 2,000 rebuilds per transpile of the compiler).
    fn ix_rebuild(ix: &mut Vector<u32>, pool_len: usize) usize {
        let mut cap: usize = 16;
        while cap * 3 <= (pool_len + 1) * 4 {
            cap = cap * 2;
        }
        ix.clear();
        ix.reserve(cap);
        for _ in 0..cap {
            ix.push(0xFFFFFFFFu32);
        }
        return pool_len;
    }

    fn tix_ready(self: &mut Self) {
        if self.tix.len() == 0 || (self.tix_used as usize + 1) * 4 >= self.tix.len() * 3 {
            if unsafe TS_ON {
                ts_add(TS_INTERN_REBUILD, 1);
                ts_add(TS_REBUILD_N, self.tys.len() as u64);
            }
            self.tix_used = TypePool::ix_rebuild(&mut self.tix, self.tys.len()) as u32;
            for id in 0..self.tys.len() {
                let mask = self.tix.len() - 1;
                let mut i = self.tys.at(id).hash() as usize & mask;
                while self.tix[i] != 0xFFFFFFFFu32 {
                    i = i + 1 & mask;
                }
                self.tix.set(i, id as u32);
            }
        }
    }

    /// The id of canonical `nt` (`concrete` set), or -1. Read-only: safe on a frozen table.
    pub const fn find_ty(self: &Self, nt: &Ty) i64 {
        if self.tix.len() == 0 {
            return -1;
        }
        let mask = self.tix.len() - 1;
        let ixp = self.tix.as_ptr();
        let pn = self.tys.len();
        let mut i = nt.hash() as usize & mask;
        loop {
            let idx = unsafe ixp[i];
            if idx == 0xFFFFFFFFu32 {
                return -1;
            }
            if idx as usize < pn && *self.tys.at(idx as usize) == *nt {
                return idx;
            }
            i = i + 1 & mask;
        }
    }

    /// Find or append canonical `nt`.
    pub fn insert_ty(self: &mut Self, nt: Ty) TypeId {
        self.tix_ready();
        let ts = unsafe TS_ON;
        let mask = self.tix.len() - 1;
        let ixp = self.tix.as_ptr();
        let pn = self.tys.len();
        let mut i = nt.hash() as usize & mask;
        loop {
            let idx = unsafe ixp[i];
            if idx == 0xFFFFFFFFu32 {
                let id = self.tys.len() as TypeId;
                self.tys.push(nt);
                self.tix.set(i, id);
                self.tix_used = self.tix_used + 1;
                return id;
            }
            if idx as usize < pn && *self.tys.at(idx as usize) == nt {
                if ts {
                    ts_add(TS_INTERN_HIT, 1);
                }
                return idx;
            }
            if ts {
                ts_add(TS_INTERN_PROBE, 1);
            }
            i = i + 1 & mask;
        }
    }

    fn iix_ready(self: &mut Self) {
        if self.iix.len() == 0 || (self.iix_used as usize + 1) * 4 >= self.iix.len() * 3 {
            self.iix_used = TypePool::ix_rebuild(&mut self.iix, self.insts.len()) as u32;
            for id in 0..self.insts.len() {
                let mask = self.iix.len() - 1;
                let mut i = self.insts.at(id).hash() as usize & mask;
                while self.iix[i] != 0xFFFFFFFFu32 {
                    i = i + 1 & mask;
                }
                self.iix.set(i, id as u32);
            }
        }
    }

    /// The index of instance record `it`, or -1. Read-only.
    pub const fn find_inst(self: &Self, it: &TyInstance) i64 {
        if self.iix.len() == 0 {
            return -1;
        }
        let mask = self.iix.len() - 1;
        let ixp = self.iix.as_ptr();
        let pn = self.insts.len();
        let mut i = it.hash() as usize & mask;
        loop {
            let cur = unsafe ixp[i];
            if cur == 0xFFFFFFFFu32 {
                return -1;
            }
            if cur as usize < pn && *self.insts.at(cur as usize) == *it {
                return cur;
            }
            i = i + 1 & mask;
        }
    }

    /// Find or append instance record `it`; its index.
    pub fn insert_inst(self: &mut Self, it: &TyInstance) u32 {
        self.iix_ready();
        let ts = unsafe TS_ON;
        let mask = self.iix.len() - 1;
        let ixp = self.iix.as_ptr();
        let pn = self.insts.len();
        let mut i = it.hash() as usize & mask;
        loop {
            let cur = unsafe ixp[i];
            if cur == 0xFFFFFFFFu32 {
                let idx = self.insts.len() as u32;
                self.insts.push(*it);
                self.iix.set(i, idx);
                self.iix_used = self.iix_used + 1;
                return idx;
            }
            if cur as usize < pn && *self.insts.at(cur as usize) == *it {
                if ts {
                    ts_add(TS_INST_HIT, 1);
                }
                return cur;
            }
            if ts {
                ts_add(TS_INST_PROBE, 1);
            }
            i = i + 1 & mask;
        }
    }

    /// The index of const-expression form `l`, or -1 (linear: these are rare).
    pub const fn find_clin(self: &Self, l: &ConstLin) i64 {
        for i in 0..self.clins.len() {
            if const_lin_eq(self.clins.at(i), l) {
                return i as i64;
            }
        }
        return -1;
    }

    pub fn insert_clin(self: &mut Self, l: &ConstLin) u32 {
        let hit = self.find_clin(l);
        if hit >= 0 {
            return hit as u32;
        }
        self.clins.push(*l);
        return self.clins.len() as u32 - 1;
    }

    // Concreteness of a record whose children are this table's ids (one level, reading the
    // children's recorded answer).
    const fn decide_g(self: &Self, ty: &Ty) bool {
        return switch ty.kind {
            TYPE_GENERIC | TYPE_CONST_EXPR | TYPE_FIELD_PROJECTION => false,
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE | TYPE_ARRAY => self.at(ty.as_data.elem as usize).concrete,
            TYPE_INSTANCE => {
                let it = self.instance(ty.as_data.inst as usize);
                let mut ok = true;
                for i in 0..it.n {
                    if !self.at((unsafe it.args[i as usize]) as usize).concrete {
                        ok = false;
                    }
                }
                ok;
            },
            _ => true,
        };
    }

    /// Intern `t` directly into this table (every child of `t` must already be one of its ids):
    /// the serial stages append final ids this way. Returns the final id.
    pub fn intern_g(self: &mut Self, t: Ty) TypeId {
        let mut nt = Ast::ty_canon(&t);
        nt.concrete = self.decide_g(&t);
        return self.insert_ty(nt);
    }

    pub fn intern_instance_g(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8) TypeId {
        let mut m = n;
        if m > 8 {
            m = 8;
        }
        let mut it = TyInstance { module: module, decl: decl, n: m };
        for j in 0..m {
            unsafe it.args[j] = unsafe args[j];
        }
        let idx = self.insert_inst(&it);
        return self.intern_g(Ty { kind: TypeKind::TYPE_INSTANCE, module: module, as_data: TyAs { inst: idx } });
    }

    pub fn intern_dyn_g(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8, qual: u8) TypeId {
        let ii = self.intern_instance_g(module, decl, args, n);
        let idx = self.at(ii as usize).as_data.inst;
        return self.intern_g(
            Ty { kind: TypeKind::TYPE_DYN, qualifier: qual, module: module, as_data: TyAs { inst: idx } },
        );
    }

    pub fn const_value_g(self: &mut Self, v: i64) TypeId {
        return self.intern_g(Ty { kind: TypeKind::TYPE_CONST, module: 0, as_data: TyAs { value: v } });
    }

    pub fn intern_clin_g(self: &mut Self, l: &ConstLin) TypeId {
        let ci = self.insert_clin(l);
        return self.intern_g(Ty { kind: TypeKind::TYPE_CONST_EXPR, module: 0, as_data: TyAs { inst: ci } });
    }
}

/// The syntax of a module's releasable bodies (the block of every function that is not generic,
/// not `const fn`, not an interface member and not a member of a generic `extend`, with the nodes
/// a desugar appends to such a body) and the per-node side tables of those nodes. Ids carry
/// NODE_BODY. The driver frees the arena once the last consumer of body syntax has run
/// (`Ast::release_bodies`); an access after that is a bounds abort.
pub struct BodyArena {
    pub nodes: SplitVec<Node>,
    pub children: SplitVec<u32>,
    pub types: Vector<u32>,
    pub resolutions: SplitVec<DefId>,
    pub mono_at: Vector<u32>,
    pub dyn_at: Vector<u32>,
    pub deref_at: Vector<u32>,
    /// True once `release_bodies` freed the arena: the module's function nodes still name body
    /// ids, which `valid` rejects; the LSP parses the bodies back from the module's source.
    pub released: bool,
}

extend BodyArena as Free {
    pub fn free(self: &mut Self) {
        self.nodes.free();
        self.children.free();
        self.types.free();
        self.resolutions.free();
        self.mono_at.free();
        self.dyn_at.free();
        self.deref_at.free();
    }
}

extend BodyArena {
    pub fn new() BodyArena {
        return BodyArena {
            nodes: SplitVec::<Node>::new(),
            children: SplitVec::<u32>::new(),
            types: Vector::<u32>::new(),
            resolutions: SplitVec::<DefId>::new(),
            mono_at: Vector::<u32>::new(),
            dyn_at: Vector::<u32>::new(),
            deref_at: Vector::<u32>::new(),
            released: false,
        };
    }

    pub const fn retained(self: &Self) usize {
        return self.nodes.retained() + self.children.retained() + self.types.capacity() * 4 + self.resolutions.retained() + self.mono_at.capacity() * 4 + self.dyn_at.capacity() * 4 + self.deref_at.capacity() * 4;
    }
}

pub struct Ast {
    pub nodes: SplitVec<Node>,
    pub children: SplitVec<u32>,
    /// The body arena (ids tagged NODE_BODY) and the sink `add`/`commit` write to: the parser
    /// turns it on for a releasable body, and a later stage that appends nodes sets it to the
    /// arena of the body it works in (`add_in`).
    pub b: BodyArena,
    pub sink_body: bool,
    pub scratch: Vector<u32>,
    // Intern serialization for parallel stages: off = single-threaded (no locking). Task-aware
    // (waiters PARK -- a raw mutex here deadlocks under safepoint preemption) and reentrant by
    // task token, because intern_dyn/intern_const_lin nest into intern_type/intern_instance.
    pub ilock_on: bool,
    pub ilock_sem: psy::Semaphore,
    pub ilock_owner: usize,
    pub ilock_depth: u32,
    // NOTE: a node/module parallel-array split (6 B/entry vs padded 8) was tried and reverted:
    // resolution_def is the compiler's hottest lookup and the second cache line cost ~8 Mcyc of
    // typecheck for a 0.78 MiB saving. Access goes through the accessors below regardless.
    pub resolutions: SplitVec<DefId>,
    /// The module's type pool: every type under module-local identity (`gt` null: the LSP and
    /// standalone checks), or only the provisional types not yet published to the package table.
    pub pool: TypePool,
    /// The package type table (`Package.tt`), null under module-local identity. See `intern_type_i`.
    pub gt: *mut TypePool,
    /// Package identity: every distinct type this module touched, in first-touch order, final ids
    /// once published (provisional TYPE_PROV ids until then); the instance records among them; and
    /// the membership bits of the final ids. What the pool enumeration meant before.
    pub used: Vector<TypeId>,
    pub used_inst: Vector<u32>,
    pub used_bits: Vector<u64>,
    pub types: Vector<u32>,
    pub mono: Vector<MonoUse>,
    // Deferred field-projection bound proofs recorded while this module's bodies were checked
    // (owner still symbolic); discharged by callers -- same-module inline, cross-module in the
    // driver's post-typecheck obligation pass.
    pub proj_obs: Vector<ProjOb>,
    pub mono_at: Vector<u32>,
    pub method_refs: Vector<MethodRef>,
    pub wide_lits: Vector<WideLit>,
    pub coerces: Vector<CoerceUse>,
    pub coerce_at: Map<u32, u32>,
    /// Canonical forms of const-generic expressions (`{BITS * 2}`), interned by VALUE so two spellings of
    /// the same width are one id -- which is what makes `{(N * 2) * 2}` and `{N * 4}` the same type.
    pub method_insts: Vector<MethodInst>,
    pub method_inst_index: Vector<u32>,
    pub dyn_uses: Vector<DynUse>,
    pub dyn_at: Vector<u32>,
    pub deref_uses: Vector<DerefUse>,
    pub deref_at: Vector<u32>,
    pub attrs: Vector<Attr>,
    pub metas: Vector<MetaAttr>,
    pub lifetime_decls: Vector<LifetimeDecl>,
    // Per call node: the (fmod<<40 | fdecl<<8 | skip) the borrow-check pass replays from typechecking.
    pub call_info: Map<u32, u64>,
    /// Per operator node: the method the type checker chose, as (module << 32 | node). Two conformances
    /// may provide one operator for different right operands, so the NAME no longer identifies it and
    /// codegen must not resolve it a second time.
    pub op_method: Map<u32, u64>,
    /// Resolutions a later stage seeded on identifiers it synthesized (a desugar names its callee
    /// and locals by resolution, never by text); `init_resolutions` re-applies them so a re-resolve
    /// of the retained arena keeps them.
    pub seeds: Vector<Seed>,
    /// What the emitter reads of a closure after its body syntax is released: recorded by the
    /// checker (`record_closure`), the mutable-capture mask finalized by the borrow checker.
    pub closure_facts: Vector<ClosureFact>,
    pub cap_facts: Vector<CapFact>,
    pub closure_at: Map<u32, u32>,
    /// `free` methods' touched declarations, `fn << 32 | decl` for every module declaration a
    /// node inside the method's body resolves to (`record_free_touch`): the free-glue emission
    /// completes a `free` that leaves an owning field untouched, after the body syntax is gone.
    pub free_touched: Vector<u64>,
    pub root: NodeId,
    pub module: ModuleId,
    /// Number of sugar-keyword marker nodes (`launch`/`select`/`parallel for`) the parser built.
    /// Zero lets the HIR lowering skip its whole-arena marker scan -- the overwhelmingly common case.
    pub sugar_marks: u32,
}

// Bootstrap constraint: the release compiler skips fields it never typed when it synthesizes a
// destructor, and leaks `call_info` and `op_method`.
extend Ast as Free {
    pub fn free(self: &mut Self) {
        self.nodes.free();
        self.children.free();
        self.b.free();
        self.scratch.free();
        self.ilock_sem.free();
        self.resolutions.free();
        self.pool.free();
        self.used.free();
        self.used_inst.free();
        self.used_bits.free();
        self.types.free();
        self.mono.free();
        self.proj_obs.free();
        self.mono_at.free();
        self.method_refs.free();
        self.wide_lits.free();
        self.coerces.free();
        self.coerce_at.free();
        self.method_insts.free();
        self.method_inst_index.free();
        self.dyn_uses.free();
        self.dyn_at.free();
        self.deref_uses.free();
        self.deref_at.free();
        self.attrs.free();
        self.metas.free();
        self.lifetime_decls.free();
        self.call_info.free();
        self.op_method.free();
        self.seeds.free();
        self.closure_facts.free();
        self.cap_facts.free();
        self.closure_at.free();
        self.free_touched.free();
    }
}

extend Ast {
    pub fn new(token_count: usize) Ast {
        let mut a = Ast {
            nodes: SplitVec::<Node>::new(),
            children: SplitVec::<u32>::new(),
            b: BodyArena::new(),
            sink_body: false,
            scratch: Vector::<u32>::new(),
            ilock_on: false,
            ilock_sem: psy::Semaphore::new(1),
            ilock_owner: 0,
            ilock_depth: 0,
            resolutions: SplitVec::<DefId>::new(),
            pool: TypePool::new(),
            gt: null,
            used: Vector::<TypeId>::new(),
            used_inst: Vector::<u32>::new(),
            used_bits: Vector::<u64>::new(),
            types: Vector::<u32>::new(),
            mono: Vector::<MonoUse>::new(),
            proj_obs: Vector::<ProjOb>::new(),
            mono_at: Vector::<u32>::new(),
            method_refs: Vector::<MethodRef>::new(),
            wide_lits: Vector::<WideLit>::new(),
            coerces: Vector::<CoerceUse>::new(),
            coerce_at: Map::<u32, u32>::new(),
            method_insts: Vector::<MethodInst>::new(),
            method_inst_index: Vector::<u32>::new(),
            dyn_uses: Vector::<DynUse>::new(),
            dyn_at: Vector::<u32>::new(),
            deref_uses: Vector::<DerefUse>::new(),
            deref_at: Vector::<u32>::new(),
            attrs: Vector::<Attr>::new(),
            metas: Vector::<MetaAttr>::new(),
            root: NODE_NONE,
            module: 0,
        };
        // nodes/tokens sits at ~0.78 across real corpora; 7/8 trims the over-reserve while keeping
        // the high-ratio outlier modules from doubling past the reserve.
        // nodes/tokens sits at ~0.78 across real corpora, with bodies holding about 87% of the
        // nodes and 65% of the list entries; the reserves keep the high-ratio outlier modules from
        // doubling past them (a freeze pins capacity, and a full arena would double on its headroom).
        a.nodes.reserve(token_count / 8);
        a.b.nodes.reserve(token_count - token_count * 7 / 32);
        a.children.reserve(token_count / 8);
        a.b.children.reserve(token_count / 4);
        a.nodes.push(Node { kind: NodeKind::NODE_NONE_KIND });
        return a;
    }

    pub fn add(self: &mut Self, node: Node) NodeId {
        if self.sink_body {
            let id = self.b.nodes.len() as NodeId | NODE_BODY;
            self.b.nodes.push(node);
            return id;
        }
        let id = self.nodes.len() as NodeId;
        self.nodes.push(node);
        return id;
    }

    /// True when `id` names the body arena.
    @c.always_inline
    pub const fn in_body(id: NodeId) bool {
        return (id & NODE_BODY) != 0;
    }

    /// Node count over both arenas; `nth_id` enumerates them (module arena first).
    @c.always_inline
    pub const fn nnodes(self: &Self) usize {
        return self.nodes.len() + self.b.nodes.len();
    }
    @c.always_inline
    pub const fn nth_id(self: &Self, k: usize) NodeId {
        return Ast::nth_id_n(self.nodes.len(), k);
    }
    /// `nth_id` over a hoisted module-arena count `nb` (a hot scan keeps it in a register).
    @c.always_inline
    pub const fn nth_id_n(nb: usize, k: usize) NodeId {
        if k < nb {
            return k as NodeId;
        }
        return (k - nb) as NodeId | NODE_BODY;
    }
    /// The dense index of `id` in the `nth_id` order, for a scan's per-node scratch table.
    @c.always_inline
    pub const fn dense(self: &Self, id: NodeId) usize {
        if (id & NODE_BODY) != 0 {
            return self.nodes.len() + (id & NODE_BODY_MASK) as usize;
        }
        return id as usize;
    }
    /// True when `id` names a node of this module (either arena).
    @c.always_inline
    pub const fn valid(self: &Self, id: NodeId) bool {
        if (id & NODE_BODY) != 0 {
            return (id & NODE_BODY_MASK) as usize < self.b.nodes.len();
        }
        return id as usize < self.nodes.len();
    }

    /// Pin both arenas' allocations before a parallel stage appends (see SplitVec::freeze).
    pub fn freeze_nodes(self: &mut Self) {
        self.nodes.freeze();
        self.children.freeze();
        self.b.nodes.freeze();
        self.b.children.freeze();
    }
    pub fn thaw_nodes(self: &mut Self) {
        self.nodes.thaw();
        self.children.thaw();
        self.b.nodes.thaw();
        self.b.children.thaw();
    }
    pub fn freeze_resolutions(self: &mut Self) {
        self.resolutions.freeze();
        self.b.resolutions.freeze();
    }
    pub fn thaw_resolutions(self: &mut Self) {
        self.resolutions.thaw();
        self.b.resolutions.thaw();
    }

    /// Free the body arena: the checked release point of body syntax. Every later read of a
    /// NODE_BODY id aborts on bounds. The seeds aimed at body nodes go with it: a parse-back
    /// (`lsp::analysis`) lowers and checks those bodies again, which seeds them again.
    pub fn release_bodies(self: &mut Self) {
        self.b.free();
        self.b = BodyArena::new();
        self.b.released = true;
        let mut w: usize = 0;
        for i in 0..self.seeds.len() {
            let sd = *self.seeds.at(i);
            if !Ast::in_body(sd.at) {
                self.seeds.set(w, sd);
                w += 1;
            }
        }
        self.seeds.truncate(w);
    }

    pub const fn mark(self: &Self) u32 {
        return self.scratch.len() as u32;
    }
    pub fn push(self: &mut Self, id: NodeId) {
        self.scratch.push(id);
    }

    /// Moves the scratch entries pushed since `mark` into `children` and returns their NodeList.
    /// Nested lists work because an inner list commits (draining its scratch tail) first.
    @c.always_inline
    pub fn commit(self: &mut Self, mark: u32) NodeList {
        let need = self.scratch.len() - mark as usize;
        let list = if self.sink_body {
            let start = self.b.children.run_start(need, 0);
            for i in mark as usize..self.scratch.len() {
                self.b.children.push(self.scratch[i]);
            }
            NodeList { start: start as u32 | NODE_BODY, len: need as u32 };
        } else {
            let start = self.children.run_start(need, 0);
            for i in mark as usize..self.scratch.len() {
                self.children.push(self.scratch[i]);
            }
            NodeList { start: start as u32, len: need as u32 };
        };
        self.scratch.truncate(mark as usize);
        return list;
    }

    pub fn init_resolutions(self: &mut Self) {
        self.resolutions.clear();
        self.resolutions.reserve(self.nodes.len());
        for _ in 0..self.nodes.len() {
            self.resolutions.push(DefId { module: 0, node: NODE_NONE });
        }
        self.b.resolutions.clear();
        self.b.resolutions.reserve(self.b.nodes.len());
        for _ in 0..self.b.nodes.len() {
            self.b.resolutions.push(DefId { module: 0, node: NODE_NONE });
        }
        for i in 0..self.seeds.len() {
            let sd = *self.seeds.at(i);
            self.set_resolution_def(sd.at, sd.def);
        }
    }

    /// Extend the resolution table to cover nodes added since `init_resolutions`. The HIR lowering builds
    /// nodes after resolve and seeds their resolutions by hand, so it grows the table as it goes.
    pub fn grow_resolutions(self: &mut Self) {
        while self.resolutions.len() < self.nodes.len() {
            self.resolutions.push(DefId { module: 0, node: NODE_NONE });
        }
        while self.b.resolutions.len() < self.b.nodes.len() {
            self.b.resolutions.push(DefId { module: 0, node: NODE_NONE });
        }
    }

    /// Like grow_resolutions, but for nodes built DURING typecheck (the `format` rewrite): the type
    /// side table was sized by init_types, so it must grow in lockstep too.
    pub fn grow_sidetables(self: &mut Self) {
        self.grow_resolutions();
        while self.types.len() < self.nodes.len() {
            self.types.push(TYPE_NONE);
        }
        while self.b.types.len() < self.b.nodes.len() {
            self.b.types.push(TYPE_NONE);
        }
    }

    pub fn init_types(self: &mut Self) {
        self.types.clear();
        self.types.reserve(self.nodes.len());
        for _ in 0..self.nodes.len() {
            self.types.push(TYPE_NONE);
        }
        self.b.types.clear();
        self.b.types.reserve(self.b.nodes.len());
        for _ in 0..self.b.nodes.len() {
            self.b.types.push(TYPE_NONE);
        }
        self.closure_facts.clear();
        self.cap_facts.clear();
        self.closure_at.clear();
        self.free_touched.clear();
        self.pool.clear();
        self.used.clear();
        self.used_inst.clear();
        self.used_bits.clear();
        if self.gt == null {
            // Module-local identity: seeds go to the pool (the package table carries them otherwise).
            self.pool.seed();
        }
    }

    // Rewrite a Ty through a zeroed union with only the kind's live arm copied, so equal types are
    // equal BYTES no matter how they were built (the memcmp equality and word-wise hash need it).
    pub const fn ty_canon(t: &Ty) Ty {
        let mut c = Ty {
            kind: t.kind,
            qualifier: t.qualifier,
            concrete: t.concrete,
            module: t.module,
            as_data: TyAs { value: 0 },
        };
        if t.kind == TypeKind::TYPE_CONST {
            c.as_data.value = t.as_data.value;
        } else if t.kind == TypeKind::TYPE_ARRAY {
            c.as_data.arr = t.as_data.arr;
        } else if t.kind == TypeKind::TYPE_FIELD_PROJECTION {
            c.as_data.proj = t.as_data.proj; // both words are significant: owner AND binder
        } else if t.kind != TypeKind::TYPE_ERROR && t.kind != TypeKind::TYPE_NEVER {
            c.as_data.decl = t.as_data.decl; // every 4-byte arm (decl/elem/inst/builtin) overlays these bytes
        }
        return c;
    }

    // The task token for the reentrant intern lock: the running coroutine, or 1 on a plain thread.
    fn itok() usize {
        let c = (unsafe sc_runtime::sc_rt_tls_get()) as usize;
        if c == 0 {
            return 1;
        }
        return c;
    }

    fn ilock_enter(self: &mut Self) {
        if !self.ilock_on {
            return;
        }
        let tok = Ast::itok();
        // atomic fast path: the owner read can only equal `tok` when THIS task stored it
        if atomic::load_usize(&self.ilock_owner, 0) == tok {
            self.ilock_depth += 1;
            return;
        }
        self.ilock_sem.acquire_masked();
        atomic::store_usize(&mut self.ilock_owner, tok, 0);
        self.ilock_depth = 1;
    }

    fn ilock_leave(self: &mut Self) {
        if !self.ilock_on {
            return;
        }
        self.ilock_depth -= 1;
        if self.ilock_depth == 0 {
            atomic::store_usize(&mut self.ilock_owner, 0, 0);
            self.ilock_sem.release();
        }
    }

    pub fn intern_type(self: &mut Self, t: Ty) TypeId {
        self.ilock_enter();
        let r = self.intern_type_i(t);
        self.ilock_leave();
        return r;
    }

    pub fn intern_const_lin(self: &mut Self, l: &ConstLin) TypeId {
        self.ilock_enter();
        let r = self.intern_const_lin_i(l);
        self.ilock_leave();
        return r;
    }

    pub fn intern_instance(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8) TypeId {
        self.ilock_enter();
        let r = self.intern_instance_i(module, decl, args, n);
        self.ilock_leave();
        return r;
    }

    pub fn intern_dyn(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8, qual: u8) TypeId {
        self.ilock_enter();
        let r = self.intern_dyn_i(module, decl, args, n, qual);
        self.ilock_leave();
        return r;
    }

    /// Record a package-table id this module touched (first touch appends to `used`).
    fn mark_used(self: &mut Self, id: TypeId) {
        let w = (id >> 6) as usize;
        while w >= self.used_bits.len() {
            self.used_bits.push(0);
        }
        let bit = 1u64 << (id & 63) as u64;
        if (self.used_bits[w] & bit) != 0 {
            return;
        }
        self.used_bits[w] = self.used_bits[w] | bit;
        self.used.push(id);
        let y = unsafe (&*self.gt).at(id as usize);
        if y.kind == TypeKind::TYPE_INSTANCE {
            self.used_inst.push(y.as_data.inst);
        }
    }

    /// Interns `t`, returning the existing TypeId on a hit. Module-local identity: ids are dense
    /// insertion-order indices into the pool. Package identity (`gt` set): a type the package table
    /// holds answers with its final id; a new type joins the package table while it is open (the
    /// serial phases), else this module's provisional pool under a TYPE_PROV-tagged id that the
    /// next publication maps to a final one. Either way the module notes the type in `used`.
    // Byte identity (the memcmp eq / word-wise hash) is only sound over CANONICAL bytes: a
    // construction site initializes one union arm and leaves the rest of TyAs to the C compiler,
    // which owes us nothing there. ty_canon rewrites the value through a zeroed union with only the
    // kind's live arm copied, so equal types are equal BYTES no matter how they were built.
    fn intern_type_i(self: &mut Self, t: Ty) TypeId {
        let mut nt = Ast::ty_canon(&t);
        nt.concrete = self.tc_decide(t);
        if unsafe TS_ON {
            ts_add(TS_INTERN, 1);
        }
        if self.gt == null {
            return self.pool.insert_ty(nt);
        }
        let g = unsafe &mut *self.gt;
        let hit = g.find_ty(&nt);
        if hit >= 0 {
            self.mark_used(hit as TypeId);
            return hit as TypeId;
        }
        if g.open {
            let id = g.insert_ty(nt);
            self.mark_used(id);
            return id;
        }
        let before = self.pool.len();
        let id = self.pool.insert_ty(nt) | TYPE_PROV;
        if self.pool.len() != before {
            self.used.push(id);
            if nt.kind == TypeKind::TYPE_INSTANCE {
                self.used_inst.push(nt.as_data.inst);
            }
        }
        return id;
    }

    /// Intern a const-expression form, returning the TYPE that stands for it -- a plain TYPE_CONST once
    /// nothing symbolic is left, so a fully substituted width is an ordinary value again.
    fn intern_const_lin_i(self: &mut Self, l: &ConstLin) TypeId {
        let mut nz: i32 = 0;
        for i in 0..l.n {
            if unsafe l.c[i as usize] != 0 {
                nz = nz + 1;
            }
        }
        if nz == 0 {
            return self.const_value(l.value());
        }
        let mut ci: u32 = 0;
        if self.gt == null {
            ci = self.pool.insert_clin(l);
        } else {
            let g = unsafe &mut *self.gt;
            let hit = g.find_clin(l);
            if hit >= 0 {
                ci = hit as u32;
            } else if g.open {
                ci = g.insert_clin(l);
            } else {
                ci = self.pool.insert_clin(l) | TYPE_PROV;
            }
        }
        return self.intern_type(Ty { kind: TypeKind::TYPE_CONST_EXPR, module: 0, as_data: TyAs { inst: ci } });
    }

    pub const fn const_lin_at(self: &Self, i: u32) &ConstLin {
        if self.gt != null && (i & TYPE_PROV) == 0 {
            return unsafe (&*self.gt).const_lin_at(i as usize);
        }
        return self.pool.const_lin_at((i & TYPE_PROV_MASK) as usize);
    }

    /// Index of the wide-literal record for `id`, -1 when it has none. Linear: wide literals are rare.
    pub const fn wide_lit_of(self: &Self, id: NodeId) i64 {
        for i in 0..self.wide_lits.len() {
            if self.wide_lits.at(i).node == id {
                return i as i64;
            }
        }
        return 0 - 1;
    }

    fn intern_instance_i(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8) TypeId {
        let mut m = n;
        if m > 8 {
            m = 8;
        }
        let mut it = TyInstance { module: module, decl: decl, n: m };
        for j in 0..m {
            unsafe it.args[j] = unsafe args[j];
        }
        if unsafe TS_ON {
            ts_add(TS_INST, 1);
        }
        let mut idx: u32 = 0;
        if self.gt == null {
            idx = self.pool.insert_inst(&it);
        } else {
            let g = unsafe &mut *self.gt;
            let hit = g.find_inst(&it);
            if hit >= 0 {
                idx = hit as u32;
            } else if g.open {
                idx = g.insert_inst(&it);
            } else {
                idx = self.pool.insert_inst(&it) | TYPE_PROV;
            }
        }
        return self.intern_type(Ty { kind: TypeKind::TYPE_INSTANCE, module: module, as_data: TyAs { inst: idx } });
    }

    /// Intern a `dyn` type: the payload is an instance-table index carrying the interface decl
    /// and its (possibly empty) type arguments; `module` mirrors the interface's module so
    /// existing `dy.module` reads stay valid.
    fn intern_dyn_i(self: &mut Self, module: ModuleId, decl: NodeId, args: *const TypeId, n: u8, qual: u8) TypeId {
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
        if self.gt != null && (index & TYPE_PROV) == 0 {
            return unsafe (&*self.gt).instance(index as usize);
        }
        return self.pool.instance((index & TYPE_PROV_MASK) as usize);
    }

    /// Apply a publication: every provisional id this module's tables hold becomes its final id
    /// (`map` by pool index, `imap` for instance records, `cmap` for const-expression forms), the
    /// `used` list is rewritten and its membership bits rebuilt, and the pool is cleared.
    pub fn publish_remap(self: &mut Self, map: &Vector<TypeId>, imap: &Vector<u32>, cmap: &Vector<u32>) {
        for i in 0..self.types.len() {
            self.types[i] = pub_map1(map, self.types[i]);
        }
        for i in 0..self.b.types.len() {
            self.b.types[i] = pub_map1(map, self.b.types[i]);
        }
        for i in 0..self.cap_facts.len() {
            let c = self.cap_facts.index_mut(i);
            c.ty = pub_map1(map, c.ty);
        }
        for i in 0..self.mono.len() {
            let u = self.mono.index_mut(i);
            for k in 0..u.n {
                unsafe u.args[k as usize] = pub_map1(map, unsafe u.args[k as usize]);
            }
        }
        for i in 0..self.method_refs.len() {
            let r = self.method_refs.index_mut(i);
            r.recv = pub_map1(map, r.recv);
        }
        for i in 0..self.wide_lits.len() {
            let w = self.wide_lits.index_mut(i);
            w.ty = pub_map1(map, w.ty);
        }
        for i in 0..self.coerces.len() {
            let c = self.coerces.index_mut(i);
            c.target = pub_map1(map, c.target);
        }
        for i in 0..self.proj_obs.len() {
            let o = self.proj_obs.index_mut(i);
            o.owner = pub_map1(map, o.owner);
        }
        for i in 0..self.method_insts.len() {
            let mi = self.method_insts.index_mut(i);
            mi.instance = pub_map1(map, mi.instance);
            for k in 0..mi.n {
                unsafe mi.targs[k as usize] = pub_map1(map, unsafe mi.targs[k as usize]);
            }
        }
        for i in 0..self.dyn_uses.len() {
            let d = self.dyn_uses.index_mut(i);
            d.src = pub_map1(map, d.src);
            d.dyn_ty = pub_map1(map, d.dyn_ty);
            d.alloc = pub_map1(map, d.alloc);
        }
        for i in 0..self.deref_uses.len() {
            let d = self.deref_uses.index_mut(i);
            d.target = pub_map1(map, d.target);
            for k in 0..d.n {
                unsafe d.recv[k as usize] = pub_map1(map, unsafe d.recv[k as usize]);
            }
        }
        for i in 0..self.used.len() {
            self.used[i] = pub_map1(map, self.used[i]);
        }
        for i in 0..self.used_inst.len() {
            let ii = self.used_inst[i];
            if (ii & TYPE_PROV) != 0 {
                self.used_inst[i] = imap[(ii & TYPE_PROV_MASK) as usize];
            }
        }
        let _ = cmap;
        self.used_bits.clear();
        for i in 0..self.used.len() {
            let id = self.used[i];
            let w = (id >> 6) as usize;
            while w >= self.used_bits.len() {
                self.used_bits.push(0);
            }
            self.used_bits[w] = self.used_bits[w] | 1u64 << (id & 63) as u64;
        }
        self.method_inst_index.clear();
        // Every provisional record is published: release the pool's chunks (a module that interns
        // again after the checkpoint allocates one fresh chunk).
        self.pool.free();
        self.pool = TypePool::new();
    }

    /// Does any table of this module still hold a provisional id? (Validation after a publication.)
    pub const fn has_provisional(self: &Self) bool {
        for i in 0..self.types.len() {
            if (self.types[i] & TYPE_PROV) != 0 {
                return true;
            }
        }
        for i in 0..self.b.types.len() {
            if (self.b.types[i] & TYPE_PROV) != 0 {
                return true;
            }
        }
        for i in 0..self.cap_facts.len() {
            if (self.cap_facts.at(i).ty & TYPE_PROV) != 0 {
                return true;
            }
        }
        for i in 0..self.used.len() {
            if (self.used[i] & TYPE_PROV) != 0 {
                return true;
            }
        }
        for i in 0..self.mono.len() {
            let u = self.mono.at(i);
            for k in 0..u.n {
                if (unsafe u.args[k as usize] & TYPE_PROV) != 0 {
                    return true;
                }
            }
        }
        for i in 0..self.method_insts.len() {
            if (self.method_insts.at(i).instance & TYPE_PROV) != 0 {
                return true;
            }
        }
        for i in 0..self.method_refs.len() {
            if (self.method_refs.at(i).recv & TYPE_PROV) != 0 {
                return true;
            }
        }
        for i in 0..self.dyn_uses.len() {
            if (self.dyn_uses.at(i).dyn_ty & TYPE_PROV) != 0 {
                return true;
            }
        }
        return false;
    }

    /// The number of types this module can enumerate: its pool (module-local identity) or its
    /// `used` list (package identity); `used_type(i)` names the i-th.
    pub const fn ntypes(self: &Self) usize {
        if self.gt == null {
            return self.pool.len();
        }
        return self.used.len();
    }

    pub const fn used_type(self: &Self, i: usize) TypeId {
        if self.gt == null {
            return i as TypeId;
        }
        return self.used[i];
    }

    /// The instance records this module can enumerate (same rule), by `used_instance(i)`.
    pub const fn ninstances(self: &Self) usize {
        if self.gt == null {
            return self.pool.ninst();
        }
        return self.used_inst.len();
    }

    pub const fn used_instance(self: &Self, i: usize) &TyInstance {
        if self.gt == null {
            return self.pool.instance(i);
        }
        return self.instance(self.used_inst[i]);
    }

    pub const fn nconst_lins(self: &Self) usize {
        if self.gt == null {
            return self.pool.nclin();
        }
        return unsafe (&*self.gt).nclin() + self.pool.nclin();
    }

    /// Is `t` an id this module can resolve (a foreign pool's id is not, under module-local identity)?
    pub const fn type_valid(self: &Self, t: TypeId) bool {
        if self.gt == null {
            return t as usize < self.pool.len();
        }
        if (t & TYPE_PROV) != 0 {
            return (t & TYPE_PROV_MASK) as usize < self.pool.len();
        }
        return t as usize < unsafe (&*self.gt).len();
    }

    /// The exclusive id bound the Core IR verifier checks against: the pool length under module-local
    /// identity; unbounded under package identity, where provisional ids carry the tag bit.
    pub const fn type_bound(self: &Self) usize {
        if self.gt == null {
            return self.pool.len();
        }
        return 0xFFFFFFFF;
    }

    pub const fn instance_valid(self: &Self, i: u32) bool {
        if self.gt == null {
            return i as usize < self.pool.ninst();
        }
        if (i & TYPE_PROV) != 0 {
            return (i & TYPE_PROV_MASK) as usize < self.pool.ninst();
        }
        return i as usize < unsafe (&*self.gt).ninst();
    }

    /// A const-generic argument value, interned as a module-independent TYPE_CONST.
    pub fn const_value(self: &mut Self, v: i64) TypeId {
        return self.intern_type(Ty { kind: TypeKind::TYPE_CONST, module: 0, as_data: TyAs { value: v } });
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

    pub fn add_meta(self: &mut Self, m: MetaAttr) {
        self.metas.push(m);
    }

    pub const fn type_concrete(self: &Self, t: TypeId) bool {
        return self.type_at(t).concrete;
    }
    // One level, reading the recorded answer for the children, which are interned before their parent.
    // `concrete` occupies Ty's former padding byte, so the cached answer needs no parallel allocation.
    fn tc_decide(self: &Self, ty: Ty) bool {
        return switch ty.kind {
            // Not a value yet: an instance holding one must not be emitted until substitution folds it.
            TYPE_GENERIC | TYPE_CONST_EXPR | TYPE_FIELD_PROJECTION => false,
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
    /// recursively. A final (published) id names one package-wide record and passes through;
    /// only a provisional id of another module needs the rebuild.
    pub fn reintern(self: &mut Self, src: &Ast, t: TypeId) TypeId {
        if t == TYPE_NONE || self.gt != null && (t & TYPE_PROV) == 0 {
            return t; // a published id is the same id in every module
        }
        let mut t0: u64 = 0;
        if unsafe TS_ON {
            ts_add(TS_REINTERN, 1);
            if unsafe TS_DEPTH == 0 {
                t0 = ts_now();
            }
            unsafe TS_DEPTH += 1;
        }
        let ty = *src.type_at(t);
        let r = switch ty.kind {
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
            TYPE_FIELD_PROJECTION => {
                let mut nt = ty;
                nt.as_data.proj.owner = self.reintern(src, ty.as_data.proj.owner);
                self.intern_type(nt);
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
        if unsafe TS_ON {
            unsafe TS_DEPTH -= 1;
            if t0 != 0 {
                ts_add(TS_REINTERN_NS, ts_now() - t0);
            }
        }
        return r;
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
        let v = self.mono.len() as u32;
        if (node & NODE_BODY) != 0 {
            let k = (node & NODE_BODY_MASK) as usize;
            ensure_u32_len(&mut self.b.mono_at, self.b.nodes.len(), k + 1);
            self.b.mono_at[k] = v;
        } else {
            ensure_u32_len(&mut self.mono_at, self.nodes.len(), node as usize + 1);
            self.mono_at[node as usize] = v;
        }
    }

    /// The `mono` slot recorded for `node` plus one, or 0 if none.
    pub const fn mono_slot(self: &Self, node: NodeId) u32 {
        return slot_of(&self.mono_at, &self.b.mono_at, node);
    }

    /// The type args recorded for `node`, or null if none.
    pub const fn type_args(self: &Self, node: NodeId) *const MonoUse {
        let idx = slot_of(&self.mono_at, &self.b.mono_at, node);
        if idx == 0 {
            return null;
        }
        return self.mono.at((idx - 1) as usize);
    }

    /// Record the conversion `node` needs. Last writer wins: a node re-checked against a new expected
    /// type converts to that one.
    pub fn set_coerce(self: &mut Self, node: NodeId, target: TypeId, method: DefId) {
        self.coerces.push(CoerceUse { node: node, target: target, method: method });
        self.coerce_at.insert(node, self.coerces.len() as u32 - 1);
    }

    pub const fn coerce_of(self: &Self, node: NodeId) *const CoerceUse {
        switch self.coerce_at.get(&node) {
            Some(i) => {
                return self.coerces.at((*i) as usize);
            },
            None => {},
        };
        return null;
    }

    pub fn add_dyn_use(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId) {
        self.add_dyn_use_alloc(node, src, dyn_ty, TYPE_NONE);
    }
    pub fn add_dyn_use_alloc(self: &mut Self, node: NodeId, src: TypeId, dyn_ty: TypeId, alloc: TypeId) {
        self.dyn_uses.push(DynUse { node: node, src: src, dyn_ty: dyn_ty, alloc: alloc });
        let v = self.dyn_uses.len() as u32;
        if (node & NODE_BODY) != 0 {
            let k = (node & NODE_BODY_MASK) as usize;
            ensure_u32_len(&mut self.b.dyn_at, self.b.nodes.len(), k + 1);
            self.b.dyn_at[k] = v;
        } else {
            ensure_u32_len(&mut self.dyn_at, self.nodes.len(), node as usize + 1);
            self.dyn_at[node as usize] = v;
        }
    }

    /// The dyn-erasure recorded at `node`, or null if none.
    pub const fn dyn_use_at(self: &Self, node: NodeId) *const DynUse {
        let idx = slot_of(&self.dyn_at, &self.b.dyn_at, node);
        if idx == 0 {
            return null;
        }
        return self.dyn_uses.at((idx - 1) as usize);
    }

    pub fn add_deref_use(self: &mut Self, du: &DerefUse) {
        self.deref_uses.push(*du);
        let v = self.deref_uses.len() as u32;
        let node = du.node;
        if (node & NODE_BODY) != 0 {
            let k = (node & NODE_BODY_MASK) as usize;
            ensure_u32_len(&mut self.b.deref_at, self.b.nodes.len(), k + 1);
            self.b.deref_at[k] = v;
        } else {
            ensure_u32_len(&mut self.deref_at, self.nodes.len(), node as usize + 1);
            self.deref_at[node as usize] = v;
        }
    }

    /// The auto-deref chain recorded at `node`, or null if none.
    pub const fn deref_use_at(self: &Self, node: NodeId) *const DerefUse {
        let idx = slot_of(&self.deref_at, &self.b.deref_at, node);
        if idx == 0 {
            return null;
        }
        return self.deref_uses.at((idx - 1) as usize);
    }

    /// The auto-deref chain recorded at `node`, writable (a mutable place use patches method hops
    /// to `deref_mut`), or null if none.
    pub const fn deref_use_mut(self: &mut Self, node: NodeId) *mut DerefUse {
        let idx = slot_of(&self.deref_at, &self.b.deref_at, node);
        if idx == 0 {
            return null;
        }
        return self.deref_uses.index_mut((idx - 1) as usize);
    }

    // Each accessor selects the arena, then runs one indexed access: the select is a conditional
    // move, and the access inlines once.
    @c.always_inline
    pub const fn at(self: &mut Self, id: NodeId) &mut Node {
        let sv = if (id & NODE_BODY) != 0 {
            &mut self.b.nodes;
        } else {
            &mut self.nodes;
        };
        return sv.index_mut((id & NODE_BODY_MASK) as usize);
    }
    @c.always_inline
    pub const fn at_const(self: &Self, id: NodeId) &Node {
        let sv = if (id & NODE_BODY) != 0 {
            &self.b.nodes;
        } else {
            &self.nodes;
        };
        return sv.at((id & NODE_BODY_MASK) as usize);
    }
    @c.always_inline
    pub const fn list(self: &Self, list: NodeList) *const NodeId {
        let sv = if (list.start & NODE_BODY) != 0 {
            &self.b.children;
        } else {
            &self.children;
        };
        return sv.ptr_at((list.start & NODE_BODY_MASK) as usize);
    }
    /// Resolves `ref_id` to a decl in THIS module (the DefId is stamped with `self.module`); use
    /// set_resolution_def for a foreign target.
    pub const fn set_resolution(self: &mut Self, ref_id: NodeId, decl: NodeId) {
        self.set_resolution_def(ref_id, DefId { module: self.module, node: decl });
    }
    /// The resolved decl node with its module DROPPED -- use resolution_def when the target may
    /// live in another module.
    pub const fn resolution(self: &Self, ref_id: NodeId) NodeId {
        return self.resolution_def(ref_id).node;
    }
    @c.always_inline
    pub const fn resolution_def(self: &Self, ref_id: NodeId) DefId {
        // synthesized nodes (post-resolve desugars) have no slot: unresolved, not an abort
        let sv = if (ref_id & NODE_BODY) != 0 {
            &self.b.resolutions;
        } else {
            &self.resolutions;
        };
        let k = (ref_id & NODE_BODY_MASK) as usize;
        if k >= sv.len() {
            return DefId { module: 0, node: NODE_NONE };
        }
        return *sv.at(k);
    }
    @c.always_inline
    pub const fn set_resolution_def(self: &mut Self, ref_id: NodeId, decl: DefId) {
        let sv = if (ref_id & NODE_BODY) != 0 {
            &mut self.b.resolutions;
        } else {
            &mut self.resolutions;
        };
        sv.set((ref_id & NODE_BODY_MASK) as usize, decl);
    }
    /// Resolve the synthesized identifier `ref_id` for good: the resolver never looks its text up,
    /// and a re-resolve restores the binding (see `seeds`).
    pub fn seed_resolution(self: &mut Self, ref_id: NodeId, decl: DefId) {
        self.set_resolution_def(ref_id, decl);
        self.seeds.push(Seed { at: ref_id, def: decl });
    }

    /// Record closure `node`'s emission facts: `entries` holds the captures, then `nparams`
    /// parameter types, then `nrets` return types. A later record replaces the earlier (a re-check).
    pub fn record_closure(
        self: &mut Self,
        node: NodeId,
        is_closure: bool,
        nparams: u32,
        nrets: u32,
        mut_caps: u64,
        entries: Vector<CapFact>,
    ) {
        let start = self.cap_facts.len() as u32;
        let n = entries.len() as u32 - nparams - nrets;
        for i in 0..entries.len() {
            self.cap_facts.push(*entries.at(i));
        }
        let f = ClosureFact {
            node: node,
            is_closure: is_closure,
            nparams: nparams,
            nrets: nrets,
            ncaps: n,
            cap_start: start,
            mut_caps: mut_caps,
        };
        switch self.closure_at.get(&node) {
            Some(i) => {
                let k = *i;
                self.closure_facts.set(k as usize, f);
            },
            None => {
                self.closure_at.insert(node, self.closure_facts.len() as u32);
                self.closure_facts.push(f);
            },
        };
    }

    /// Record that `free` method `fnid`'s body resolves to module declaration `decl` (once).
    pub fn record_free_touch(self: &mut Self, fnid: NodeId, decl: NodeId) {
        let key = fnid as u64 << 32 | decl as u64;
        let mut i = self.free_touched.len();
        while i > 0 && self.free_touched[i - 1] >> 32 == fnid as u64 {
            if self.free_touched[i - 1] == key {
                return;
            }
            i -= 1;
        }
        self.free_touched.push(key);
    }
    /// True when `free` method `fnid`'s body resolves to `decl`.
    pub const fn free_touches(self: &Self, fnid: NodeId, decl: NodeId) bool {
        let key = fnid as u64 << 32 | decl as u64;
        for i in 0..self.free_touched.len() {
            if self.free_touched[i] == key {
                return true;
            }
        }
        return false;
    }

    /// The recorded facts of closure or function-type node `node`, or null.
    pub const fn closure_fact(self: &Self, node: NodeId) *const ClosureFact {
        switch self.closure_at.get(&node) {
            Some(i) => {
                return self.closure_facts.at((*i) as usize);
            },
            None => {
                return null;
            },
        };
    }
    pub fn closure_fact_mut(self: &mut Self, node: NodeId) *mut ClosureFact {
        switch self.closure_at.get(&node) {
            Some(i) => {
                let k = *i;
                return self.closure_facts.index_mut(k as usize);
            },
            None => {
                return null;
            },
        };
    }
    /// The capture facts of closure `f`, from its first capture.
    pub const fn caps_of(self: &Self, f: *const ClosureFact) *const CapFact {
        return self.cap_facts.at((unsafe (&*f).cap_start) as usize);
    }

    /// The name text of binding declaration `decl` (a let, parameter, loop binding, pattern name
    /// or bare identifier); empty otherwise.
    pub const fn decl_name_span(self: &Self, decl: NodeId) tok::Span {
        let n = self.at_const(decl);
        if n.kind == NodeKind::NODE_LET {
            return self.at_const(n.as_data.let_stmt.name).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_PARAMETER {
            return self.at_const(n.as_data.parameter.name).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_FOR || n.kind == NodeKind::NODE_INLINE_FOR {
            return self.at_const(n.as_data.for_stmt.binding).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_PATTERN_NAME {
            return self.at_const(n.as_data.pattern.name).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_IDENTIFIER {
            return n.as_data.name.text;
        }
        return tok::Span { start: 0, end: 0 };
    }
    /// Is call `id` spelled `x.free()`: a member call with no path and no arguments whose member is
    /// named `free`? When no method resolves for it, the call is an explicit drop: destruction IS
    /// the call, and there is no callee declaration to run or to pin.
    pub const fn is_free_call(self: &Self, id: NodeId, src: str) bool {
        let d = self.at_const(id).as_data.call;
        if d.args.len != 0 {
            return false;
        }
        let c = self.at_const(d.callee);
        if c.kind != NodeKind::NODE_MEMBER || c.as_data.member.path {
            return false;
        }
        let msp = self.at_const(c.as_data.member.member).as_data.name.text;
        if (msp.end - msp.start) as usize != 4 {
            return false;
        }
        return src.slice(msp.start as usize, msp.end as usize) == "free";
    }
    /// Builtin TypeIds are fixed by init_types' seeding: pool slot 0 is TYPE_ERROR, then the
    /// builtins in enum order -- hence b + 1.
    pub const fn builtin(b: BuiltinType) TypeId {
        return b as TypeId + 1;
    }
    @c.always_inline
    pub const fn set_type(self: &mut Self, n: NodeId, t: TypeId) {
        let tv = if (n & NODE_BODY) != 0 {
            &mut self.b.types;
        } else {
            &mut self.types;
        };
        tv[(n & NODE_BODY_MASK) as usize] = t;
    }
    @c.always_inline
    pub const fn type_of(self: &Self, n: NodeId) TypeId {
        // nodes synthesized after init_types (typecheck-time desugars) have no slot yet; the
        // constant engine reads through partially-typed modules and must see "untyped", not a
        // bounds abort
        let tv = if (n & NODE_BODY) != 0 {
            &self.b.types;
        } else {
            &self.types;
        };
        let k = (n & NODE_BODY_MASK) as usize;
        if k >= tv.len() {
            return TYPE_NONE;
        }
        return tv[k];
    }
    pub const fn type_at(self: &Self, t: TypeId) &Ty {
        if self.gt != null && (t & TYPE_PROV) == 0 {
            return unsafe (&*self.gt).at(t as usize);
        }
        return self.pool.at((t & TYPE_PROV_MASK) as usize);
    }

    /// Approximate owned bytes (vector CAPACITIES, not lengths): the LSP retention budget's
    /// accounting unit. The map tables are omitted -- small next to the arenas.
    pub const fn retained_bytes(self: &Self) usize {
        return self.nodes.retained() + self.children.retained() + self.b.retained() + self.scratch.capacity() * 4 + self.resolutions.retained() + self.pool.retained() + self.used.capacity() * 4 + self.used_inst.capacity() * 4 + self.used_bits.capacity() * 8 + self.types.capacity() * 4 + self.mono.capacity() * sizeof(MonoUse) + self.mono_at.capacity() * 4 + self.method_insts.capacity() * sizeof(MethodInst) + self.method_inst_index.capacity() * 4 + self.dyn_uses.capacity() * sizeof(DynUse) + self.dyn_at.capacity() * 4 + self.deref_uses.capacity() * sizeof(DerefUse) + self.deref_at.capacity() * 4 + self.attrs.capacity() * sizeof(Attr) + self.metas.capacity() * sizeof(MetaAttr) + self.coerces.capacity() * sizeof(CoerceUse) + self.method_refs.capacity() * sizeof(MethodRef) + self.wide_lits.capacity() * sizeof(WideLit) + self.proj_obs.capacity() * sizeof(ProjOb) + self.lifetime_decls.capacity() * sizeof(LifetimeDecl) + self.seeds.capacity() * sizeof(Seed) + self.closure_facts.capacity() * sizeof(ClosureFact) + self.cap_facts.capacity() * sizeof(CapFact) + self.free_touched.capacity() * 8;
    }

    /// Add this module's syntax accounting to `out` (SC_SYNTAX_STATS): the body arena holds the
    /// releasable body syntax; a pinned body (generic, `const fn`, interface default, generic
    /// extend member) and every constant initializer stay in the module arena.
    pub fn syntax_stats(self: &Self, out: &mut SyntaxStats) {
        let nodes_cap = self.nodes.retained() + self.b.nodes.retained();
        let children_cap = self.children.retained() + self.b.children.retained();
        let resolutions = self.resolutions.retained() + self.b.resolutions.retained();
        let types = (self.types.capacity() + self.b.types.capacity()) * 4;
        out.nodes += self.nnodes();
        out.body_nodes += self.b.nodes.len();
        out.nodes_cap += nodes_cap;
        out.children += self.children.len() + self.b.children.len();
        out.body_children += self.b.children.len();
        out.children_cap += children_cap;
        out.resolutions += resolutions;
        out.types += types;
        out.pool += self.pool.retained();
        out.tables += self.retained_bytes() - nodes_cap - children_cap - resolutions - types - self.pool.retained();
        if self.nodes.len() == 0 {
            return;
        }
        let items = self.at_const(self.root).as_data.program.items;
        for i in 0..items.len {
            let id = unsafe self.list(items)[i as usize];
            let k = self.at_const(id).kind;
            if k == NodeKind::NODE_FUNCTION {
                if self.at_const(id).as_data.function.body != NODE_NONE {
                    out.bodies += 1;
                }
            } else if k == NodeKind::NODE_EXTEND || k == NodeKind::NODE_INTERFACE {
                let members = if k == NodeKind::NODE_EXTEND {
                    self.at_const(id).as_data.extend_def.items;
                } else {
                    self.at_const(id).as_data.interface_def.items;
                };
                for j in 0..members.len {
                    let m = unsafe self.list(members)[j as usize];
                    if self.at_const(m).kind == NodeKind::NODE_FUNCTION && self.at_const(m).as_data.function.body != NODE_NONE {
                        out.bodies += 1;
                    }
                }
            }
        }
    }
}

/// Syntax accounting over a package (`Ast::syntax_stats`), bytes are retained capacities.
pub struct SyntaxStats {
    pub nodes: usize,
    pub body_nodes: usize,
    pub bodies: usize,
    pub children: usize,
    pub body_children: usize,
    pub nodes_cap: usize,
    pub children_cap: usize,
    pub resolutions: usize,
    pub types: usize,
    pub pool: usize,
    pub tables: usize, // every other per-module side table
}

extend SyntaxStats {
    pub const fn new() SyntaxStats {
        return SyntaxStats {
            nodes: 0,
            body_nodes: 0,
            bodies: 0,
            children: 0,
            body_children: 0,
            nodes_cap: 0,
            children_cap: 0,
            resolutions: 0,
            types: 0,
            pool: 0,
            tables: 0,
        };
    }
}

// The per-node index slot of `node` in the module (`v`) or body (`vb`) table, 0 when unrecorded.
@c.always_inline
const fn slot_of(v: &Vector<u32>, vb: &Vector<u32>, node: NodeId) u32 {
    let tv = if (node & NODE_BODY) != 0 {
        vb;
    } else {
        v;
    };
    let k = (node & NODE_BODY_MASK) as usize;
    if k >= tv.len() {
        return 0;
    }
    return tv[k];
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

/// The builtin type a numeric literal's suffix names, or BT_COUNT if it has none. On a match,
/// *sfx_start (when non-null) receives the suffix's start offset. In a hex literal, f32/f64 only
/// count as a suffix after a 'p' exponent -- otherwise those bytes are hex digits.
pub fn ast_numeric_suffix(src: str, start: u32, end: u32, sfx_start: &mut u32) BuiltinType {
    let hex = end - start > 2 && src[start as usize] == b'0' && (src[(start + 1) as usize] | 0x20u8) == b'x';
    let mut hexf = false;
    let mut i = start + 2;
    while hex && i < end && !hexf {
        hexf = (src[i as usize] | 0x20u8) == b'p';
        i = i + 1;
    }
    if end - start > 5 && unsafe cstring::memcmp(unsafe (src.ptr() + (end - 5) as usize), "isize".ptr(), 5) == 0 {
        if sfx_start != null {
            *sfx_start = end - 5;
        }
        return BuiltinType::BT_ISIZE;
    }
    if end - start > 5 && unsafe cstring::memcmp(unsafe (src.ptr() + (end - 5) as usize), "usize".ptr(), 5) == 0 {
        if sfx_start != null {
            *sfx_start = end - 5;
        }
        return BuiltinType::BT_USIZE;
    }
    let mut n: u32 = 3;
    if end - start > n {
        let p = unsafe (src.ptr() + (end - n) as usize);
        if unsafe cstring::memcmp(p, "i16".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_I16;
        }
        if unsafe cstring::memcmp(p, "i32".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_I32;
        }
        if unsafe cstring::memcmp(p, "i64".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_I64;
        }
        if unsafe cstring::memcmp(p, "u16".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_U16;
        }
        if unsafe cstring::memcmp(p, "u32".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_U32;
        }
        if unsafe cstring::memcmp(p, "u64".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_U64;
        }
        if (!hex || hexf) && unsafe cstring::memcmp(p, "f32".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_F32;
        }
        if (!hex || hexf) && unsafe cstring::memcmp(p, "f64".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_F64;
        }
    }
    n = 2;
    if end - start > n {
        let p = unsafe (src.ptr() + (end - n) as usize);
        if unsafe cstring::memcmp(p, "i8".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_I8;
        }
        if unsafe cstring::memcmp(p, "u8".ptr(), n as usize) == 0 {
            if sfx_start != null {
                *sfx_start = end - n;
            }
            return BuiltinType::BT_U8;
        }
    }
    return BuiltinType::BT_COUNT;
}
