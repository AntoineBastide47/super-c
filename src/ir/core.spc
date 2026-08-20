// Core IR: the typed, control-flow, non-SSA executable form every body lowers
// to. One CoreBody per function, method, closure, or constant initializer. Storage is dense
// append-only vectors of u32-indexed records -- no per-node heap allocation, no pointers into other
// stages. Types are the owning module's TypeIds; syntax is referenced only through spans and the
// optional origin NodeId kept for diagnostic compatibility.
import ast::ast as *;
import lexer::token as tok;

pub type BlockId = u32;
pub type LocalId = u32;
pub type StmtId = u32;
pub type PlaceId = u32;
pub type OperandId = u32;
pub type RvalueId = u32;
pub type ProjId = u32;
pub type ConstId = u32;
pub const IR_NONE: u32 = 0xFFFFFFFF;

/// Local storage classes (LocalDecl.storage).
pub const LS_ARG: u8 = 0;
pub const LS_RET: u8 = 1;
pub const LS_USER: u8 = 2;
pub const LS_TEMP: u8 = 3;
pub const LS_STATIC_REF: u8 = 4; // a reference to an item (global/static); base of item places

/// One local slot: argument, return slot, user variable, or compiler temporary.
pub struct LocalDecl {
    pub ty: TypeId,
    pub storage: u8,
    pub is_mutable: bool,
    pub span: tok::Span,
    pub decl: NodeId, // binding decl node for user locals (diagnostic compatibility); NODE_NONE else
    pub item: DefId, // LS_STATIC_REF: the item this local names; {0, NODE_NONE} else
}

/// Place projections (applied left to right from the base local).
pub const PJ_DEREF: u8 = 0;
pub const PJ_FIELD: u8 = 1; // data = stable field index, sub = field decl NodeId
pub const PJ_INDEX_CONST: u8 = 2; // data = constant index
pub const PJ_UNION_FIELD: u32 = 0xFFFFFFFE; // PJ_FIELD data marker: union member (fields alias)
pub const PJ_INDEX_OP: u8 = 3; // data = OperandId of the dynamic index
pub const PJ_DOWNCAST: u8 = 4; // data = variant index, sub = variant decl NodeId

pub struct Projection {
    pub kind: u8,
    pub data: u32,
    pub sub: u32,
    pub ty: TypeId, // the type AFTER this projection applies
}

/// A place: base local plus a projection range (into CoreBody.projections).
pub struct Place {
    pub base: LocalId,
    pub proj_start: u32,
    pub proj_len: u32,
    pub ty: TypeId, // the final projected type
}

/// Operand kinds.
pub const OP_COPY: u8 = 0; // data = PlaceId
pub const OP_MOVE: u8 = 1; // data = PlaceId
pub const OP_CONST: u8 = 2; // data = ConstId
pub const OP_ITEM: u8 = 3; // a function/constant item value; data = ConstId carrying the DefId

pub struct Operand {
    pub kind: u8,
    pub data: u32,
    pub ty: TypeId,
}

/// Constant kinds.
pub const CK_INT: u8 = 0; // val = bits (sign per ty)
pub const CK_FLOAT: u8 = 1; // raw span keeps the exact literal spelling
pub const CK_BOOL: u8 = 2; // val = 0/1
pub const CK_STR: u8 = 3; // raw span = content
pub const CK_UNIT: u8 = 4; // no value (void/empty)
pub const CK_ITEM: u8 = 5; // item = resolved fn/const DefId
pub const CK_WIDE: u8 = 6; // val = wide-literal record index in the module Ast
pub const CK_ERROR: u8 = 7; // error-recovery constant (error-typed)

pub struct Constant {
    pub kind: u8,
    pub ty: TypeId,
    pub val: i64,
    pub raw: tok::Span,
    pub item: DefId,
    pub targ_start: u32, // CK_ITEM: bound generic arguments in CoreBody.targ_pool
    pub targ_len: u32,
}

/// Rvalue kinds.
pub const RV_USE: u8 = 0; // a = OperandId
// Borrowck replay tape events (recorded by the Lowerer at the walk's AST sites; consumed by
// bc_replay): entry = kind << 56 | aux << 32 | node. Synthetic/desugared lowering never records.
pub const TP_SCOPE_PUSH: u8 = 1;
pub const TP_SCOPE_POP: u8 = 2;
pub const TP_NLL: u8 = 3; // node = block, aux = statement index
pub const TP_MARK_PUSH: u8 = 4;
pub const TP_MARK_POP: u8 = 5;
pub const TP_LET: u8 = 6;
pub const TP_LET_TUPLE: u8 = 7;
pub const TP_ASSIGN_PRE: u8 = 8;
pub const TP_ASSIGN_POST: u8 = 9;
pub const TP_RET_VAL: u8 = 10; // node = value expr, aux = index
pub const TP_RET_POST: u8 = 11;
pub const TP_CALL_MARK: u8 = 12;
pub const TP_CALL: u8 = 13; // aux 1 = dyn free receiver
pub const TP_REF: u8 = 14;
pub const TP_CAST_ERASE: u8 = 15; // node = cast expression operand
pub const TP_SLICE: u8 = 16;
pub const TP_CLOSURE: u8 = 17;
pub const TP_DEFER: u8 = 18; // node = deferred expr
pub const TP_FLOW_SAVE: u8 = 19;
pub const TP_FLOW_ELSE: u8 = 20;
pub const TP_FLOW_JOIN: u8 = 21;
pub const TP_LOOP_PUSH: u8 = 22; // aux 1 = for loop
pub const TP_LOOP_POP: u8 = 23;
pub const TP_BODY_START: u8 = 24; // aux 1 = always runs; for-loops also record the binding depth
pub const TP_BODY_END: u8 = 25;
pub const TP_MATCH_PRE: u8 = 26; // aux 1 = value position
pub const TP_ARM: u8 = 27; // node = arm, aux = arm index
pub const TP_ARM_END: u8 = 28;
pub const TP_MATCH_POST: u8 = 29;
pub const TP_WALK_EXPR: u8 = 30; // escape hatch: replay walks the subtree
pub const TP_WALK_STMT: u8 = 31;

pub const RV_REF: u8 = 1; // &place; a = PlaceId, b = 1 when mutable
pub const RV_ADDR: u8 = 2; // raw address of place; a = PlaceId, b = 1 when *mut
pub const RV_UNARY: u8 = 3; // a = OperandId, b = token op
pub const RV_BINARY: u8 = 4; // a/b = OperandIds, c = token op
pub const RV_CAST: u8 = 5; // a = OperandId, b = CastKind, target = ty
pub const RV_AGGREGATE: u8 = 6; // a = operand range start, b = len, c = AggKind, item = decl/variant
pub const RV_REPEAT: u8 = 7; // a = element OperandId, b = count
pub const RV_LEN: u8 = 8; // a = PlaceId
pub const RV_DISCRIMINANT: u8 = 9; // a = PlaceId
pub const RV_DYN: u8 = 10; // dynamic-interface construction; a = OperandId, b = alloc TypeId
pub const RV_CLOSURE: u8 = 11; // a = capture operand range start, b = len, item = closure body owner
pub const RV_INTRINSIC: u8 = 12; // a = operand range start, b = len (IN_SIZEOF/IN_ALIGNOF: the measured TypeId), c = IntrinsicKind
/// Structural view slicing `base[lo..hi]`: a = the container PLACE, b = start OperandId (IR_NONE =
/// from 0), item.node = end OperandId (IR_NONE = to the container's length), c bit0 = inclusive.
/// Kept structural so end-openness survives (a materialized Range value cannot express it).
pub const RV_SLICE: u8 = 13;

/// Cast kinds (RV_CAST.b).
pub const CAST_NUMERIC: u8 = 0;
pub const CAST_POINTER: u8 = 1;
pub const CAST_COERCE_FROM: u8 = 2; // library `from` conversion; item = selected method
pub const CAST_NEVER: u8 = 3; // never-to-any
pub const CAST_ARRAY_SLICE: u8 = 4; // array -> slice view

/// Aggregate kinds (RV_AGGREGATE.c).
pub const AGG_STRUCT: u8 = 0;
pub const AGG_TUPLE: u8 = 1;
pub const AGG_ARRAY: u8 = 2;
pub const AGG_VARIANT: u8 = 3; // item = variant decl; c2 = discriminant index

/// Compiler intrinsics that stay explicit operations (RV_INTRINSIC.c). Append-only.
pub const IN_SIZEOF: u8 = 0;
pub const IN_ALIGNOF: u8 = 1;
pub const IN_VA_START: u8 = 2;
pub const IN_VA_ARG: u8 = 3;
pub const IN_VA_END: u8 = 4;
pub const IN_TYPE_INFO: u8 = 5;
pub const IN_ZEROED: u8 = 6;
pub const IN_REFLECT: u8 = 7; // angle-3 compatibility: reflection binder/projection forms
pub const IN_ASM_OPERAND: u8 = 8;
pub const IN_NEW: u8 = 9; // heap allocation of the initializer operand (`new T { .. }`)
// Inline assembly: `item` names the NODE_ASM (template/constraints/clobbers read from the AST);
// operands are the outputs' places (as copies) then the input values, in source order.
pub const IN_ASM: u8 = 10;
pub const IN_SAFEPOINT: u8 = 11; // loop-body preemption marker; printed only for runtime-using programs
pub const IN_DANGLING: u8 = 12; // non-null aligned no-storage pointer (`dangling::<T>()`; ZST buffers)

// Field order packs to 24 bytes (kind/c share the item's tail padding); bodies hold one record
// per expression, so the two byte flags sit last.
pub struct Rvalue {
    pub a: u32,
    pub b: u32,
    pub target: TypeId, // result type
    pub item: DefId, // selected method/decl when the kind carries one
    pub kind: u8,
    pub c: u8,
}

/// Statement kinds.
pub const ST_ASSIGN: u8 = 0; // place = rvalue
pub const ST_STORAGE_LIVE: u8 = 1; // a = LocalId
pub const ST_STORAGE_DEAD: u8 = 2; // a = LocalId
pub const ST_SET_DISCR: u8 = 3; // place, a = variant index
pub const ST_DEINIT: u8 = 4; // place
pub const ST_ASM: u8 = 5; // a = operand range start, b = len; raw span = template
pub const ST_NOP: u8 = 6;

pub struct Statement {
    pub kind: u8,
    pub place: PlaceId,
    pub rvalue: RvalueId,
    pub a: u32,
    pub b: u32,
    pub span: tok::Span,
}

/// Terminator kinds.
pub const TM_GOTO: u8 = 0; // t0 = successor
pub const TM_SWITCH: u8 = 1; // a = discriminant OperandId; values/targets in switch pool; t0 = otherwise
pub const TM_CALL: u8 = 2; // callee item or fn-value operand; args in operand range; t0 = normal
pub const TM_RETURN: u8 = 3;
pub const TM_DROP: u8 = 4; // place; t0 = successor
pub const TM_ASSERT: u8 = 5; // a = condition OperandId; t0 = success
pub const TM_UNREACHABLE: u8 = 6;

// Field order packs to 64 bytes (one record per cache line); the byte flags ride the tail padding.
pub struct Terminator {
    pub a: u32, // per kind (see above)
    pub args_start: u32, // TM_CALL: argument operand range
    pub args_len: u32,
    pub dests_start: u32, // TM_CALL: destination place range (multi-return)
    pub dests_len: u32,
    pub sw_start: u32, // TM_SWITCH: (value, target) pair range in switch pool
    pub sw_len: u32,
    pub t0: BlockId, // primary successor (goto/normal/success/otherwise)
    pub targs_start: u32, // TM_CALL: the checker's bound generic arguments (CoreBody.targ_pool)
    pub targs_len: u32,
    pub callee: DefId, // TM_CALL resolved target; node == NODE_NONE for fn-value calls (a = operand)
    pub span: tok::Span,
    pub kind: u8,
    pub is_variadic: bool,
}

/// One basic block: a statement range plus exactly one terminator.
pub struct BasicBlock {
    pub stmt_start: u32,
    pub stmt_len: u32,
    pub term: Terminator,
    pub sealed: bool, // terminator present (the verifier rejects unsealed blocks)
}

/// One lowered body. All ranges index the body-local pools below; nothing points at another body.
pub struct CoreBody {
    pub owner: DefId, // the function/const decl this body lowers
    pub module: ModuleId,
    pub args: u32,
    pub returns: u32,
    pub is_generic: bool, // generic bodies may carry symbolic types (verifier rule 15)
    /// The body contains an UNEXPANDED reflection binder (`inline for .. in fields(..)` whose
    /// owner stayed symbolic): instances must RE-LOWER with the demand env, never share this body.
    pub has_reflect: bool,
    /// The body contains an unfolded `sizeof(T) <op> <const>` branch: instances re-lower with the
    /// demand env so the untaken side (a ZST container path or its material twin) never emits.
    pub has_zst_cond: bool,
    // Some `let x: T;` declared a local without a value: only then can a use-before-init exist,
    // so bodies without it (and without moves) skip the move/init dataflow outright.
    pub has_uninit_decl: bool,
    pub locals: Vector<LocalDecl>,
    pub blocks: Vector<BasicBlock>,
    pub statements: Vector<Statement>,
    pub places: Vector<Place>,
    pub projections: Vector<Projection>,
    pub operands: Vector<Operand>,
    pub rvalues: Vector<Rvalue>,
    pub constants: Vector<Constant>,
    pub oper_pool: Vector<OperandId>, // argument/aggregate operand ranges
    pub dest_pool: Vector<PlaceId>, // call destination ranges
    pub switch_pool: Vector<u64>, // TM_SWITCH pairs: value<<32 | target (values are u32-encoded)
    pub targ_pool: Vector<TypeId>, // generic-argument ranges for calls and item constants
    // Bit per operand: this OP_MOVE is a USER consumption (let/return/argument/aggregate/assign
    // positions the walk's move rules check) -- pattern binds, downcasts, and spills stay unmarked.
    pub user_moves: Vector<u64>,
    pub entry: BlockId,
}

extend CoreBody {
    pub fn new(owner: DefId, module: ModuleId) CoreBody {
        return CoreBody {
            owner: owner,
            module: module,
            args: 0,
            returns: 0,
            is_generic: false,
            has_reflect: false,
            has_zst_cond: false,
            has_uninit_decl: false,
            locals: Vector::<LocalDecl>::new(),
            blocks: Vector::<BasicBlock>::new(),
            statements: Vector::<Statement>::new(),
            places: Vector::<Place>::new(),
            projections: Vector::<Projection>::new(),
            operands: Vector::<Operand>::new(),
            rvalues: Vector::<Rvalue>::new(),
            constants: Vector::<Constant>::new(),
            oper_pool: Vector::<OperandId>::new(),
            dest_pool: Vector::<PlaceId>::new(),
            switch_pool: Vector::<u64>::new(),
            targ_pool: Vector::<TypeId>::new(),
            user_moves: Vector::<u64>::new(),
            entry: 0,
        };
    }

    /// Re-seed for a fresh body, keeping every pool's heap capacity so the next lowering refills
    /// instead of reallocating. Callers that reuse one Lowerer across bodies rely on this.
    pub fn clear(self: &mut Self, owner: DefId, module: ModuleId) {
        self.owner = owner;
        self.module = module;
        self.args = 0;
        self.returns = 0;
        self.is_generic = false;
        self.has_reflect = false;
        self.has_zst_cond = false;
        self.has_uninit_decl = false;
        self.locals.truncate(0);
        self.blocks.truncate(0);
        self.statements.truncate(0);
        self.places.truncate(0);
        self.projections.truncate(0);
        self.operands.truncate(0);
        self.rvalues.truncate(0);
        self.constants.truncate(0);
        self.oper_pool.truncate(0);
        self.dest_pool.truncate(0);
        self.switch_pool.truncate(0);
        self.targ_pool.truncate(0);
        self.user_moves.truncate(0);
        self.entry = 0;
    }

    /// An exact-size deep copy: every pool reserves its final length, so a kept body carries no
    /// growth slack and costs one allocation per non-empty pool.
    pub fn compact_from(src: &CoreBody) CoreBody {
        let mut out = CoreBody::new(src.owner, src.module);
        out.args = src.args;
        out.returns = src.returns;
        out.is_generic = src.is_generic;
        out.has_reflect = src.has_reflect;
        out.has_zst_cond = src.has_zst_cond;
        out.entry = src.entry;
        out.locals.reserve(src.locals.len());
        for i in 0..src.locals.len() {
            out.locals.push(*src.locals.at(i));
        }
        out.blocks.reserve(src.blocks.len());
        for i in 0..src.blocks.len() {
            out.blocks.push(*src.blocks.at(i));
        }
        out.statements.reserve(src.statements.len());
        for i in 0..src.statements.len() {
            out.statements.push(*src.statements.at(i));
        }
        out.places.reserve(src.places.len());
        for i in 0..src.places.len() {
            out.places.push(*src.places.at(i));
        }
        out.projections.reserve(src.projections.len());
        for i in 0..src.projections.len() {
            out.projections.push(*src.projections.at(i));
        }
        out.operands.reserve(src.operands.len());
        for i in 0..src.operands.len() {
            out.operands.push(*src.operands.at(i));
        }
        out.rvalues.reserve(src.rvalues.len());
        for i in 0..src.rvalues.len() {
            out.rvalues.push(*src.rvalues.at(i));
        }
        out.constants.reserve(src.constants.len());
        for i in 0..src.constants.len() {
            out.constants.push(*src.constants.at(i));
        }
        out.oper_pool.reserve(src.oper_pool.len());
        for i in 0..src.oper_pool.len() {
            out.oper_pool.push(*src.oper_pool.at(i));
        }
        out.dest_pool.reserve(src.dest_pool.len());
        for i in 0..src.dest_pool.len() {
            out.dest_pool.push(*src.dest_pool.at(i));
        }
        out.switch_pool.reserve(src.switch_pool.len());
        for i in 0..src.switch_pool.len() {
            out.switch_pool.push(*src.switch_pool.at(i));
        }
        out.targ_pool.reserve(src.targ_pool.len());
        for i in 0..src.targ_pool.len() {
            out.targ_pool.push(*src.targ_pool.at(i));
        }
        return out;
    }

    /// Retained bytes across every pool (capacity, the number that reaches RSS).
    pub const fn retained_bytes(self: &Self) usize {
        let mut b = self.locals.capacity() * sizeof(LocalDecl);
        b += self.blocks.capacity() * sizeof(BasicBlock);
        b += self.statements.capacity() * sizeof(Statement);
        b += self.places.capacity() * sizeof(Place);
        b += self.projections.capacity() * sizeof(Projection);
        b += self.operands.capacity() * sizeof(Operand);
        b += self.rvalues.capacity() * sizeof(Rvalue);
        b += self.constants.capacity() * sizeof(Constant);
        b += self.oper_pool.capacity() * 4 + self.dest_pool.capacity() * 4 + self.switch_pool.capacity() * 8 + self.targ_pool.capacity() * 4;
        return b;
    }

    pub fn add_local(self: &mut Self, d: LocalDecl) LocalId {
        self.locals.push(d);
        return self.locals.len() as LocalId - 1;
    }

    /// Open a new (unsealed) block; statements append through stmt() until seal().
    pub fn add_block(self: &mut Self) BlockId {
        self.blocks.push(
            BasicBlock {
                stmt_start: 0,
                stmt_len: 0,
                term: Terminator {
                    kind: TM_UNREACHABLE,
                    a: IR_NONE,
                    args_start: 0,
                    args_len: 0,
                    dests_start: 0,
                    dests_len: 0,
                    sw_start: 0,
                    sw_len: 0,
                    t0: IR_NONE,
                    callee: DefId { module: 0, node: NODE_NONE },
                    targs_start: 0,
                    targs_len: 0,
                    is_variadic: false,
                    span: tok::Span { start: 0, end: 0 },
                },
                sealed: false,
            },
        );
        return self.blocks.len() as BlockId - 1;
    }
}

extend CoreBody as Free {
    pub fn free(self: &mut Self) {
        self.locals.free();
        self.blocks.free();
        self.statements.free();
        self.places.free();
        self.projections.free();
        self.operands.free();
        self.rvalues.free();
        self.constants.free();
        self.oper_pool.free();
        self.dest_pool.free();
        self.switch_pool.free();
        self.targ_pool.free();
        self.user_moves.free();
    }
}
