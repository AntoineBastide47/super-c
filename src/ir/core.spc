// Core IR: the typed, control-flow, non-SSA executable form every body lowers
// to. One CoreBody per function, method, closure, or constant initializer. Storage is dense
// append-only vectors of u32-indexed records -- no per-node heap allocation, no pointers into other
// stages. Types are the owning module's TypeIds; syntax is referenced only through spans and the
// optional origin NodeId kept for diagnostic compatibility.
import ast::ast as *;
import lexer::token as tok;
import lexer::token_type as tt;

pub(package) type BlockId = u32;
pub(package) type LocalId = u32;
pub(package) type StmtId = u32;
pub(package) type PlaceId = u32;
pub(package) type OperandId = u32;
pub(package) type RvalueId = u32;
pub(package) type ProjId = u32;
pub(package) type ConstId = u32;
pub(package) const IR_NONE: u32 = 0xFFFFFFFF;

/// Local storage classes (LocalDecl.storage).
pub(package) const LS_ARG: u8 = 0;
pub(package) const LS_RET: u8 = 1;
pub(package) const LS_USER: u8 = 2;
pub(package) const LS_TEMP: u8 = 3;
pub(package) const LS_STATIC_REF: u8 = 4; // a reference to an item (global/static); base of item places
/// An inlined callee's declared local (its arg or user binding, decl cleared by the splice):
/// drop elaboration schedules its storage-death drops exactly as the callee's own would have.
pub(package) const LS_INL: u8 = 5;

/// The declaration a user local binds (`LocalDecl.dkind`): what the emitter reads of it after
/// the body syntax is released.
pub(package) const LK_NONE: u8 = 0;
pub(package) const LK_LET: u8 = 1;
pub(package) const LK_FOR: u8 = 3; // `for` / `inline for` binding
pub(package) const LK_PATTERN: u8 = 4;

// The `@derive(Copy)` tags of this file restate the derivation for the bootstrap compiler, which checks a
// `Copy` bound against written conformances only.
/// One local slot: argument, return slot, user variable, or compiler temporary.
@derive(Copy)
pub(package) struct LocalDecl {
    pub(package) ty: TypeId,
    pub(package) storage: u8,
    pub(package) is_mutable: bool,
    pub(package) dkind: u8, // an LK_* kind
    pub(package) span: tok::Span,
    pub(package) decl: NodeId, // binding decl node for user locals (diagnostic compatibility); NODE_NONE else
    // The binding's name text as (offset from `span.start`, length); 0/0 for a temporary. Packed
    // so the record stays at 32 bytes (the analyses copy it by value).
    pub(package) name_off: u16,
    pub(package) name_len: u16,
    pub(package) item: DefId, // LS_STATIC_REF: the item this local names; {0, NODE_NONE} else
}

extend LocalDecl {
    /// A mutable nameless local of `storage` class with no binding decl and no item.
    pub(package) const fn anon(ty: TypeId, storage: u8, span: tok::Span) LocalDecl {
        return LocalDecl {
            ty: ty,
            storage: storage,
            is_mutable: true,
            dkind: LK_NONE,
            span: span,
            decl: NODE_NONE,
            name_off: 0,
            name_len: 0,
            item: DefId { module: 0, node: NODE_NONE },
        };
    }

    /// The binding's name text span (empty for a temporary).
    pub(package) const fn name(self: &Self) tok::Span {
        return tok::Span {
            start: self.span.start + self.name_off as u32,
            end: self.span.start + self.name_off as u32 + self.name_len as u32,
        };
    }
}

/// One inline-assembly statement's text (see IN_ASM): the template and, in `CoreBody.asm_spans`
/// from `cons`, the output constraints, the input constraints, then the clobbers.
@derive(Copy)
pub(package) struct AsmRec {
    pub(package) template: tok::Span, // empty = none
    pub(package) cons: u32,
    pub(package) nout: u32,
    pub(package) nin: u32,
    pub(package) nclob: u32,
}

/// Place projections (applied left to right from the base local).
pub(package) const PJ_DEREF: u8 = 0;
pub(package) const PJ_FIELD: u8 = 1; // sub = field decl NodeId (data then IR_NONE or the index); positional: data = index
pub(package) const PJ_INDEX_CONST: u8 = 2; // data = constant index
pub(package) const PJ_UNION_FIELD: u32 = 0xFFFFFFFE; // PJ_FIELD data marker: union member (fields alias)
pub(package) const PJ_INDEX_OP: u8 = 3; // data = OperandId of the dynamic index
pub(package) const PJ_DOWNCAST: u8 = 4; // data = variant index, sub = variant decl NodeId

@derive(Copy)
pub(package) struct Projection {
    pub(package) kind: u8,
    pub(package) data: u32,
    pub(package) sub: u32,
    pub(package) ty: TypeId, // the type AFTER this projection applies
}

/// Do field projections `x` and `y` of one struct name different members? Named members compare by
/// declaration (`data` may or may not carry the index), positional members by index; a named and a
/// positional projection prove nothing. Union members (`PJ_UNION_FIELD`) share storage: test them
/// first, as everything below one union member overlaps everything below another.
pub(package) const fn fields_differ(x: &Projection, y: &Projection) bool {
    if x.sub != NODE_NONE || y.sub != NODE_NONE {
        return x.sub != NODE_NONE && y.sub != NODE_NONE && x.sub != y.sub;
    }
    return x.data != IR_NONE && y.data != IR_NONE && x.data != y.data;
}

/// The `data` of field projection `pj` with a named member's index dropped, so one member has one
/// identity whichever form names it.
pub(package) const fn field_data(pj: &Projection) u32 {
    if pj.sub != NODE_NONE && pj.data != PJ_UNION_FIELD {
        return IR_NONE;
    }
    return pj.data;
}

/// A place: base local plus a projection range (into CoreBody.projections).
@derive(Copy)
pub(package) struct Place {
    pub(package) base: LocalId,
    pub(package) proj_start: u32,
    pub(package) proj_len: u32,
    pub(package) ty: TypeId, // the final projected type
}

/// Operand kinds.
pub(package) const OP_COPY: u8 = 0; // data = PlaceId
pub(package) const OP_MOVE: u8 = 1; // data = PlaceId
pub(package) const OP_CONST: u8 = 2; // data = ConstId

@derive(Copy)
pub(package) struct Operand {
    pub(package) kind: u8,
    pub(package) data: u32,
    pub(package) ty: TypeId,
}

/// Constant kinds.
pub(package) const CK_INT: u8 = 0; // val = bits (sign per ty)
pub(package) const CK_FLOAT: u8 = 1; // raw span keeps the exact literal spelling
pub(package) const CK_BOOL: u8 = 2; // val = 0/1
pub(package) const CK_STR: u8 = 3; // raw span = content
pub(package) const CK_UNIT: u8 = 4; // no value (void/empty)
pub(package) const CK_ITEM: u8 = 5; // item = resolved fn/const DefId; val = bound generic arguments (targ_val)
pub(package) const CK_WIDE: u8 = 6; // val = wide-literal record index in the module Ast
/// A folded `const fn` call's float: val = its IEEE bits (an `f32`'s in the low 32).
pub(package) const CK_FBITS: u8 = 7;
/// A folded `const fn` call's `str`: val = start << 32 | length of its bytes in CoreBody.bytes.
pub(package) const CK_BYTES: u8 = 8;

@derive(Copy)
pub(package) struct Constant {
    pub(package) kind: u8,
    pub(package) ty: TypeId,
    pub(package) val: i64,
    pub(package) raw: tok::Span,
    pub(package) item: DefId,
}
static_assert(sizeof(Constant) == 32, "Constant stays 32 bytes: CK_ITEM keeps its generic arguments in val");

/// A CK_ITEM `val`: `len` bound generic arguments from `start` in CoreBody.targ_pool.
pub(package) const fn targ_val(start: u32, len: u32) i64 {
    return len as i64 << 32 | start as i64;
}

extend Constant {
    /// CK_ITEM: the first bound generic argument in CoreBody.targ_pool.
    pub(package) const fn targ_start(self: &Self) u32 {
        return self.val as u32;
    }

    /// CK_ITEM: the number of bound generic arguments.
    pub(package) const fn targ_len(self: &Self) u32 {
        return (self.val >> 32) as u32;
    }

    /// CK_INT: the exact integer behind the spelling in `src`, the source its span indexes: decimal,
    /// hex, binary, octal, underscores, width suffixes, character literals with escapes, and `null`
    /// (0). A lowered literal's `val` holds the same value. False past u64::MAX or for a malformed
    /// character literal.
    pub(package) const fn int_value(self: &Self, src: str, out: &mut i64) bool {
        let sp = self.raw;
        if sp.end <= sp.start || sp.end as usize > src.len() {
            *out = self.val;
            return true;
        }
        let s = src.slice(sp.start as usize, sp.end as usize);
        let n = s.len();
        let b0 = s.byte_at(0);
        if b0 == 39 {
            // 'c' with escapes -- but ONLY a real character literal (a synthesized constant may
            // carry a diagnostic span that happens to start at a label's quote)
            if n < 3 || s.byte_at(n - 1) != 39 {
                *out = self.val;
                return true;
            }
            let v = tok::char_literal_value(src, sp);
            if v.is_none() {
                return false;
            }
            *out = v.unwrap();
            return true;
        }
        if !(b0 >= 48 && b0 <= 57) {
            // `null` and every other non-numeric spelling lower with the value the record carries
            *out = self.val;
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
            if v > (0xFFFFFFFFFFFFFFFFu64 - d as u64) / base {
                // Past u64::MAX. The checker reports the literal ("integer literal is too large to fit in a
                // 64-bit integer"), but a constant initializer that holds it still reaches the evaluator.
                return false;
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
                *out = self.val;
                return true;
            }
            i += 1;
        }
        *out = v as i64;
        return true;
    }
}

/// Rvalue kinds.
pub(package) const RV_USE: u8 = 0; // a = OperandId; b = 1 (shared) or 2 (mutable) for an array's slice view, which borrows the array
// Borrowck replay tape events (recorded by the Lowerer at the walk's AST sites; consumed by
// bc_replay): entry = kind << 56 | aux << 32 | node. Synthetic/desugared lowering never records.
pub(package) const TP_SCOPE_PUSH: u8 = 1;
pub(package) const TP_SCOPE_POP: u8 = 2;
pub(package) const TP_NLL: u8 = 3; // node = block, aux = statement index
pub(package) const TP_MARK_PUSH: u8 = 4;
pub(package) const TP_MARK_POP: u8 = 5;
pub(package) const TP_LET: u8 = 6;
pub(package) const TP_LET_TUPLE: u8 = 7;
pub(package) const TP_ASSIGN_PRE: u8 = 8;
pub(package) const TP_ASSIGN_POST: u8 = 9;
pub(package) const TP_RET_VAL: u8 = 10; // node = value expr, aux = index
pub(package) const TP_RET_POST: u8 = 11;
pub(package) const TP_CALL_MARK: u8 = 12;
pub(package) const TP_CALL: u8 = 13; // aux 1 = dyn free receiver
pub(package) const TP_REF: u8 = 14;
pub(package) const TP_CAST_ERASE: u8 = 15; // node = cast expression operand
pub(package) const TP_SLICE: u8 = 16;
pub(package) const TP_CLOSURE: u8 = 17;
pub(package) const TP_FLOW_SAVE: u8 = 19;
pub(package) const TP_FLOW_ELSE: u8 = 20;
pub(package) const TP_FLOW_JOIN: u8 = 21;
pub(package) const TP_LOOP_PUSH: u8 = 22; // aux 1 = for loop
pub(package) const TP_LOOP_POP: u8 = 23;
pub(package) const TP_BODY_START: u8 = 24; // aux 1 = always runs; for-loops also record the binding depth
pub(package) const TP_BODY_END: u8 = 25;
pub(package) const TP_MATCH_PRE: u8 = 26; // aux 1 = value position
pub(package) const TP_ARM: u8 = 27; // node = arm, aux = arm index
pub(package) const TP_ARM_END: u8 = 28;
pub(package) const TP_MATCH_POST: u8 = 29;
/// An argument a FOLDED call consumed: no IR op survives for the analysis, so the replay marks
/// the move directly with the const-move category loud (the one flow check a fold erases).
pub(package) const TP_CONST_MOVE: u8 = 30;

pub(package) const RV_REF: u8 = 1; // &place; a = PlaceId, b = 1 when mutable
pub(package) const RV_ADDR: u8 = 2; // raw address of place; a = PlaceId, b = 1 when *mut
pub(package) const RV_UNARY: u8 = 3; // a = OperandId, b = token op
pub(package) const RV_BINARY: u8 = 4; // a/b = OperandIds, c = token op
pub(package) const RV_CAST: u8 = 5; // a = OperandId, b = CastKind, target = ty
pub(package) const RV_AGGREGATE: u8 = 6; // a = operand range start, b = len, c = AggKind, item = decl/variant
pub(package) const RV_REPEAT: u8 = 7; // a = element OperandId, b = count OperandId
pub(package) const RV_LEN: u8 = 8; // a = PlaceId
pub(package) const RV_DISCRIMINANT: u8 = 9; // a = PlaceId
pub(package) const RV_DYN: u8 = 10; // dynamic-interface construction; a = OperandId, b = alloc TypeId
pub(package) const RV_CLOSURE: u8 = 11; // a = capture operand range start, b = len, item = closure body owner
pub(package) const RV_INTRINSIC: u8 = 12; // a = operand range start, b = len (IN_SIZEOF/IN_ALIGNOF: the measured TypeId), c = IntrinsicKind
/// Structural view slicing `base[lo..hi]`: a = the container PLACE, b = start OperandId (IR_NONE =
/// from 0), item.node = end OperandId (IR_NONE = to the container's length), c bit0 = inclusive.
/// Kept structural so end-openness survives (a materialized Range value cannot express it).
pub(package) const RV_SLICE: u8 = 13;
/// A named vector operation: a = operand range start, b = len, c = SIMD_* code, target = result
/// type, item.node = the start of its index list in `simd_aux` (SIMD_SWIZZLE, SIMD_SHUFFLE) or IR_NONE.
/// Lane-wise operators and casts stay RV_BINARY, RV_UNARY and RV_CAST over vector types.
pub(package) const RV_SIMD: u8 = 14;

/// The live edge of switch block `x` of `b` when it switches on a literal: the index of the case it
/// takes (`sw_len` for the default edge), IR_NONE otherwise. Every pass that walks the control flow
/// skips the dead edges.
pub(package) const fn const_switch_edge(b: &CoreBody, x: u32) u32 {
    let t = b.blocks.at(x as usize).term;
    if t.kind != TM_SWITCH {
        return IR_NONE;
    }
    let op = *b.operands.at(t.a as usize);
    if op.kind != OP_CONST {
        return IR_NONE;
    }
    let c = *b.constants.at(op.data as usize);
    if c.kind != CK_INT && c.kind != CK_BOOL {
        return IR_NONE;
    }
    for k in 0..t.sw_len {
        if (b.switch_pool[(t.sw_start + k) as usize] >> 32) as u32 == c.val as u32 {
            return k;
        }
    }
    return t.sw_len;
}

/// True for the rvalue kinds whose operands are the range `a`, `b` long, in `oper_pool`.
pub(package) const fn has_op_range(rv: &Rvalue) bool {
    return rv.kind == RV_AGGREGATE || rv.kind == RV_CLOSURE || rv.kind == RV_SIMD || rv.kind == RV_INTRINSIC && !type_payload(
        rv.c,
    );
}

/// RV_SIMD operation codes (`Rvalue.c`), indexes of SIMD_OPS. Append-only. One code per lane rule:
/// the element kind selects the scalar rule, as for RV_BINARY (`MIN` is IEEE minimumNumber on float
/// lanes, `ABS` clears the sign bit of a float lane).
pub(package) const SIMD_IOTA: u8 = 0;
pub(package) const SIMD_CMP_EQ: u8 = 1;
pub(package) const SIMD_CMP_NE: u8 = 2;
pub(package) const SIMD_CMP_LT: u8 = 3;
pub(package) const SIMD_CMP_LE: u8 = 4;
pub(package) const SIMD_CMP_GT: u8 = 5;
pub(package) const SIMD_CMP_GE: u8 = 6;
pub(package) const SIMD_CHOOSE: u8 = 7;
pub(package) const SIMD_WRAP_ADD: u8 = 8;
pub(package) const SIMD_WRAP_SUB: u8 = 9;
pub(package) const SIMD_WRAP_MUL: u8 = 10;
pub(package) const SIMD_WRAP_NEG: u8 = 11;
pub(package) const SIMD_WRAP_SHL: u8 = 12;
pub(package) const SIMD_WRAP_SHR: u8 = 13;
pub(package) const SIMD_OVF_ADD: u8 = 14;
pub(package) const SIMD_OVF_SUB: u8 = 15;
pub(package) const SIMD_OVF_MUL: u8 = 16;
pub(package) const SIMD_SAT_ADD: u8 = 17;
pub(package) const SIMD_SAT_SUB: u8 = 18;
pub(package) const SIMD_MIN: u8 = 19;
pub(package) const SIMD_MAX: u8 = 20;
pub(package) const SIMD_ABS: u8 = 21;
pub(package) const SIMD_WRAP_ABS: u8 = 22;
pub(package) const SIMD_ABS_DIFF: u8 = 23;
pub(package) const SIMD_CLZ: u8 = 24;
pub(package) const SIMD_CTZ: u8 = 25;
pub(package) const SIMD_POPCNT: u8 = 26;
pub(package) const SIMD_ROTL: u8 = 27;
pub(package) const SIMD_ROTR: u8 = 28;
pub(package) const SIMD_BITREV: u8 = 29;
pub(package) const SIMD_BSWAP: u8 = 30;
pub(package) const SIMD_COPYSIGN: u8 = 31;
pub(package) const SIMD_MINIMUM: u8 = 32;
pub(package) const SIMD_MAXIMUM: u8 = 33;
pub(package) const SIMD_SQRT: u8 = 34;
pub(package) const SIMD_CEIL: u8 = 35;
pub(package) const SIMD_FLOOR: u8 = 36;
pub(package) const SIMD_TRUNC: u8 = 37;
pub(package) const SIMD_ROUND_EVEN: u8 = 38;
pub(package) const SIMD_FMA: u8 = 39;
pub(package) const SIMD_IS_NAN: u8 = 40;
pub(package) const SIMD_IS_INF: u8 = 41;
pub(package) const SIMD_IS_FINITE: u8 = 42;
pub(package) const SIMD_IS_NORMAL: u8 = 43;
pub(package) const SIMD_IS_SUBNORMAL: u8 = 44;
pub(package) const SIMD_IS_SIGN_NEG: u8 = 45;
pub(package) const SIMD_CAST_CHANGED: u8 = 46; // (source, cast result): the lanes whose value changed or were NaN
pub(package) const SIMD_NARROW_CHECKED: u8 = 47;
pub(package) const SIMD_NARROW_SAT: u8 = 48;
pub(package) const SIMD_BITCAST: u8 = 49;
pub(package) const SIMD_LOW_HALF: u8 = 50;
pub(package) const SIMD_HIGH_HALF: u8 = 51;
pub(package) const SIMD_CONCAT: u8 = 52;
pub(package) const SIMD_LOAD: u8 = 53; // (slice, checked start): reads N elements
pub(package) const SIMD_STORE: u8 = 54; // (slice, checked start, vector): writes N elements
pub(package) const SIMD_LOAD_RAW: u8 = 55; // (pointer): reads sizeof(T) * N bytes
pub(package) const SIMD_STORE_RAW: u8 = 56; // (pointer, vector): writes sizeof(T) * N bytes
pub(package) const SIMD_SWIZZLE: u8 = 57; // (v) and an index list: lane i is v[idx[i]]
pub(package) const SIMD_SHUFFLE: u8 = 58; // (a, b) and an index list: lane i is (a ++ b)[idx[i]]
pub(package) const SIMD_SWIZZLE_ZERO: u8 = 59; // (v, idx): lane i is v[idx[i]], or 0 past the lanes
pub(package) const SIMD_SWIZZLE_OOB: u8 = 60; // (v, idx): the lanes whose index is past the lanes
pub(package) const SIMD_COMPRESS: u8 = 61; // (m, v, fill)
pub(package) const SIMD_EXPAND: u8 = 62; // (m, packed, fill)
pub(package) const SIMD_REDUCE_ADD: u8 = 63;
pub(package) const SIMD_REDUCE_MUL: u8 = 64;
pub(package) const SIMD_REDUCE_ADD_ORD: u8 = 65;
pub(package) const SIMD_REDUCE_MUL_ORD: u8 = 66;
pub(package) const SIMD_REDUCE_ADD_TREE: u8 = 67;
pub(package) const SIMD_REDUCE_MUL_TREE: u8 = 68;
pub(package) const SIMD_REDUCE_ADD_OVF: u8 = 69; // whether the exact sum does not fit the lane type
pub(package) const SIMD_REDUCE_MUL_OVF: u8 = 70;
pub(package) const SIMD_REDUCE_MIN: u8 = 71;
pub(package) const SIMD_REDUCE_MAX: u8 = 72;
pub(package) const SIMD_REDUCE_MIN_NUM: u8 = 73;
pub(package) const SIMD_REDUCE_MAX_NUM: u8 = 74;
pub(package) const SIMD_REDUCE_MINIMUM: u8 = 75;
pub(package) const SIMD_REDUCE_MAXIMUM: u8 = 76;
pub(package) const SIMD_REDUCE_AND: u8 = 77;
pub(package) const SIMD_REDUCE_OR: u8 = 78;
pub(package) const SIMD_REDUCE_XOR: u8 = 79;
pub(package) const SIMD_ARG_MIN: u8 = 80; // the lowest lane holding the extreme value
pub(package) const SIMD_ARG_MAX: u8 = 81;
pub(package) const SIMD_ARG_MIN_NUM: u8 = 82; // the same over the non-NaN lanes; N when every lane is NaN
pub(package) const SIMD_ARG_MAX_NUM: u8 = 83;
pub(package) const SIMD_DOT: u8 = 84; // (a, b): the products in the result type, summed as REDUCE_ADD(_ORD)
pub(package) const SIMD_LOAD_OR: u8 = 85; // (slice, start, fallback)
pub(package) const SIMD_LOAD_MASKED: u8 = 86; // (slice, start, m, fallback)
pub(package) const SIMD_STORE_MASKED: u8 = 87; // (slice, start, m, v)
pub(package) const SIMD_GATHER: u8 = 88; // (slice, idx, m, fallback)
pub(package) const SIMD_SCATTER: u8 = 89; // (slice, idx, m, v)
pub(package) const SIMD_COMPRESS_STORE: u8 = 90; // (slice, start, m, v): the active lane count
pub(package) const SIMD_GATHER_UNCHECKED: u8 = 91; // (slice, idx, m, fallback): `GATHER` with no index check
pub(package) const SIMD_GATHER_PTR: u8 = 92; // ([*const T; N], m, fallback)
pub(package) const SIMD_SCATTER_PTR: u8 = 93; // ([*mut T; N], m, v)
pub(package) const SIMD_LOAD_MASKED_PTR: u8 = 94; // (pointer, m, fallback)
pub(package) const SIMD_STORE_MASKED_PTR: u8 = 95; // (pointer, m, v)

/// SimdOp.rule: how the operands and the result relate (V is operand 0's vector type, N its lanes).
pub(package) const SR_VEC: u8 = 0; // every operand and the result are V
pub(package) const SR_MASK: u8 = 1; // every operand is V; the result is Mask<N>
pub(package) const SR_CHOOSE: u8 = 2; // (Mask<N>, V, V) -> V; V is operand 1's type
pub(package) const SR_LANES: u8 = 3; // (V) or (V, V) -> a vector of N other lanes
pub(package) const SR_CHANGED: u8 = 4; // (V, W), W of N lanes -> Mask<N>
pub(package) const SR_BITCAST: u8 = 5; // V -> a vector of the same size
pub(package) const SR_HALF: u8 = 6; // V -> N / 2 lanes of V's element
pub(package) const SR_CONCAT: u8 = 7; // (V, V) -> 2 * N lanes of V's element
pub(package) const SR_ANY: u8 = 8; // no operand; the result is any vector
pub(package) const SR_LOAD: u8 = 9; // a slice or pointer of T [, usize start] -> Simd<T, N>
pub(package) const SR_STORE: u8 = 10; // a slice or pointer of T [, usize start], Simd<T, N> -> unit
pub(package) const SR_INDEX: u8 = 11; // (V) or (V, V) and an index list of M -> M lanes of V's element
pub(package) const SR_RT_INDEX: u8 = 12; // (V, M lanes of an unsigned integer) -> M lanes of V's element, or Mask<M>
pub(package) const SR_MASKED: u8 = 13; // (Mask<N>, V, V) -> V
pub(package) const SR_REDUCE: u8 = 14; // (V) -> the element (bool for an overflow test, usize for a lane index)
pub(package) const SR_DOT: u8 = 15; // (V, V) -> a scalar of the same kind, at least as wide as the element
pub(package) const SR_MLOAD: u8 = 16; // the elements' place, [start or index vector,] [Mask<N>,] V -> V
pub(package) const SR_MSTORE: u8 = 17; // the elements' place, start or index vector, Mask<N>, V -> unit (usize)

/// SimdOp.elem: the lane types the operation accepts (operand 0's lanes, or the result's for SR_ANY).
pub(package) const SE_ANY: u8 = 0;
pub(package) const SE_INT: u8 = 1;
pub(package) const SE_FLOAT: u8 = 2;
pub(package) const SE_SIGNED: u8 = 3; // a signed integer or a float
pub(package) const SE_SINT: u8 = 4; // a signed integer

/// SimdOp.effect: the memory the operation touches through operand 0: none, the lanes' elements, or
/// (masked and gather forms) one element per active lane at a lane-dependent address.
pub(package) const SM_NONE: u8 = 0;
pub(package) const SM_READ: u8 = 1;
pub(package) const SM_WRITE: u8 = 2;
pub(package) const SM_READ_LANES: u8 = 3;
pub(package) const SM_WRITE_LANES: u8 = 4;

/// One RV_SIMD operation: its intrinsic name (`@intrinsic("simd.<name>")`), operand count, type
/// rule, lane types, and memory effect through operand 0.
pub(package) struct SimdOp {
    pub(package) name: str<'static>,
    pub(package) arity: u8,
    pub(package) rule: u8,
    pub(package) elem: u8,
    pub(package) effect: u8,
}

const fn sop(name: str<'static>, arity: u8, rule: u8, elem: u8) SimdOp {
    return SimdOp { name: name, arity: arity, rule: rule, elem: elem, effect: SM_NONE };
}

const fn mop(name: str<'static>, arity: u8, rule: u8, effect: u8) SimdOp {
    return SimdOp { name: name, arity: arity, rule: rule, elem: SE_ANY, effect: effect };
}

/// The number of RV_SIMD codes.
pub(package) const SIMD_CODES: usize = 96;

pub(package) const SIMD_OPS: [SimdOp; SIMD_CODES] = [
    sop("iota", 0, SR_ANY, SE_ANY),
    sop("eq", 2, SR_MASK, SE_ANY),
    sop("ne", 2, SR_MASK, SE_ANY),
    sop("lt", 2, SR_MASK, SE_ANY),
    sop("le", 2, SR_MASK, SE_ANY),
    sop("gt", 2, SR_MASK, SE_ANY),
    sop("ge", 2, SR_MASK, SE_ANY),
    sop("choose", 3, SR_CHOOSE, SE_ANY),
    sop("wrapping_add", 2, SR_VEC, SE_INT),
    sop("wrapping_sub", 2, SR_VEC, SE_INT),
    sop("wrapping_mul", 2, SR_VEC, SE_INT),
    sop("wrapping_neg", 1, SR_VEC, SE_INT),
    sop("wrapping_shl", 2, SR_VEC, SE_INT),
    sop("wrapping_shr", 2, SR_VEC, SE_INT),
    sop("overflow_add", 2, SR_MASK, SE_INT),
    sop("overflow_sub", 2, SR_MASK, SE_INT),
    sop("overflow_mul", 2, SR_MASK, SE_INT),
    sop("saturating_add", 2, SR_VEC, SE_INT),
    sop("saturating_sub", 2, SR_VEC, SE_INT),
    sop("min", 2, SR_VEC, SE_ANY),
    sop("max", 2, SR_VEC, SE_ANY),
    sop("abs", 1, SR_VEC, SE_SIGNED),
    sop("wrapping_abs", 1, SR_VEC, SE_SINT),
    sop("abs_diff", 2, SR_LANES, SE_INT),
    sop("leading_zeros", 1, SR_VEC, SE_INT),
    sop("trailing_zeros", 1, SR_VEC, SE_INT),
    sop("count_ones", 1, SR_VEC, SE_INT),
    sop("rotate_left", 2, SR_VEC, SE_INT),
    sop("rotate_right", 2, SR_VEC, SE_INT),
    sop("reverse_bits", 1, SR_VEC, SE_INT),
    sop("swap_bytes", 1, SR_VEC, SE_INT),
    sop("copysign", 2, SR_VEC, SE_FLOAT),
    sop("minimum", 2, SR_VEC, SE_FLOAT),
    sop("maximum", 2, SR_VEC, SE_FLOAT),
    sop("sqrt", 1, SR_VEC, SE_FLOAT),
    sop("ceil", 1, SR_VEC, SE_FLOAT),
    sop("floor", 1, SR_VEC, SE_FLOAT),
    sop("trunc", 1, SR_VEC, SE_FLOAT),
    sop("round_even", 1, SR_VEC, SE_FLOAT),
    sop("fma", 3, SR_VEC, SE_FLOAT),
    sop("is_nan", 1, SR_MASK, SE_FLOAT),
    sop("is_infinite", 1, SR_MASK, SE_FLOAT),
    sop("is_finite", 1, SR_MASK, SE_FLOAT),
    sop("is_normal", 1, SR_MASK, SE_FLOAT),
    sop("is_subnormal", 1, SR_MASK, SE_FLOAT),
    sop("is_sign_negative", 1, SR_MASK, SE_FLOAT),
    sop("cast_changed", 2, SR_CHANGED, SE_ANY),
    sop("narrow", 1, SR_LANES, SE_INT),
    sop("narrow_saturating", 1, SR_LANES, SE_INT),
    sop("bitcast", 1, SR_BITCAST, SE_ANY),
    sop("low_half", 1, SR_HALF, SE_ANY),
    sop("high_half", 1, SR_HALF, SE_ANY),
    sop("concat", 2, SR_CONCAT, SE_ANY),
    SimdOp { name: "load", arity: 2, rule: SR_LOAD, elem: SE_ANY, effect: SM_READ },
    SimdOp { name: "store", arity: 3, rule: SR_STORE, elem: SE_ANY, effect: SM_WRITE },
    SimdOp { name: "load_raw", arity: 1, rule: SR_LOAD, elem: SE_ANY, effect: SM_READ },
    SimdOp { name: "store_raw", arity: 2, rule: SR_STORE, elem: SE_ANY, effect: SM_WRITE },
    sop("swizzle", 1, SR_INDEX, SE_ANY),
    sop("shuffle", 2, SR_INDEX, SE_ANY),
    sop("swizzle_or_zero", 2, SR_RT_INDEX, SE_ANY),
    sop("swizzle_oob", 2, SR_RT_INDEX, SE_ANY),
    sop("compress", 3, SR_MASKED, SE_ANY),
    sop("expand", 3, SR_MASKED, SE_ANY),
    sop("reduce_add", 1, SR_REDUCE, SE_INT),
    sop("reduce_mul", 1, SR_REDUCE, SE_INT),
    sop("reduce_add_ordered", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_mul_ordered", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_add_tree", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_mul_tree", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_add_overflows", 1, SR_REDUCE, SE_INT),
    sop("reduce_mul_overflows", 1, SR_REDUCE, SE_INT),
    sop("reduce_min", 1, SR_REDUCE, SE_INT),
    sop("reduce_max", 1, SR_REDUCE, SE_INT),
    sop("reduce_min_num", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_max_num", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_minimum", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_maximum", 1, SR_REDUCE, SE_FLOAT),
    sop("reduce_and", 1, SR_REDUCE, SE_INT),
    sop("reduce_or", 1, SR_REDUCE, SE_INT),
    sop("reduce_xor", 1, SR_REDUCE, SE_INT),
    sop("arg_min", 1, SR_REDUCE, SE_INT),
    sop("arg_max", 1, SR_REDUCE, SE_INT),
    sop("arg_min_num", 1, SR_REDUCE, SE_FLOAT),
    sop("arg_max_num", 1, SR_REDUCE, SE_FLOAT),
    sop("dot", 2, SR_DOT, SE_ANY),
    mop("load_or", 3, SR_MLOAD, SM_READ_LANES),
    mop("load_masked", 4, SR_MLOAD, SM_READ_LANES),
    mop("store_masked", 4, SR_MSTORE, SM_WRITE_LANES),
    mop("gather", 4, SR_MLOAD, SM_READ_LANES),
    mop("scatter", 4, SR_MSTORE, SM_WRITE_LANES),
    mop("compress_store", 4, SR_MSTORE, SM_WRITE_LANES),
    mop("gather_unchecked", 4, SR_MLOAD, SM_READ_LANES),
    mop("gather_ptr", 3, SR_MLOAD, SM_READ_LANES),
    mop("scatter_ptr", 3, SR_MSTORE, SM_WRITE_LANES),
    mop("load_masked_ptr", 3, SR_MLOAD, SM_READ_LANES),
    mop("store_masked_ptr", 3, SR_MSTORE, SM_WRITE_LANES),
];

/// The SIMD_OPS row of code `c`.
pub(package) const fn simd_op(c: u8) SimdOp {
    let t: []SimdOp = SIMD_OPS;
    return t[c as usize];
}

/// Lane `i` of the index list at `simd_aux[start..]`: its length, then its lanes four to a word.
pub(package) const fn aux_lane(b: &CoreBody, start: u32, i: u64) u32 {
    return b.simd_aux[(start as u64 + 1 + i / 4) as usize] >> (i % 4 * 8) as u32 & 0xFF;
}

/// Whether code `c` writes through operand 0 (`SM_WRITE`, `SM_WRITE_LANES`).
pub(package) const fn simd_writes(c: u8) bool {
    let e = simd_op(c).effect;
    return e == SM_WRITE || e == SM_WRITE_LANES;
}

/// What `@intrinsic("simd.<name>")` lowers to (`simd_intrinsic`).
pub(package) const SI_BINARY: u32 = 1; // RV_BINARY, c = the operator token
pub(package) const SI_UNARY: u32 = 2; // RV_UNARY, b = the operator token
pub(package) const SI_CAST: u32 = 3; // RV_CAST, c = the cast kind
pub(package) const SI_SIMD: u32 = 4; // RV_SIMD, c = the code
pub(package) const SI_HINT: u32 = 5; // RV_INTRINSIC, c = IN_LIKELY, IN_UNLIKELY, IN_RETURN_ADDRESS, IN_VOLATILE_LOAD or IN_VOLATILE_STORE

/// The lowering of `@intrinsic("<name>")`: SI_* << 8 | c, or 0 for an unknown name.
pub(package) const fn simd_intrinsic(name: str) u32 {
    if name == "float.to_int_unchecked" {
        return SI_CAST << 8 | CAST_UNCHECKED as u32;
    }
    if name == "hint.likely" || name == "hint.unlikely" {
        return SI_HINT << 8 | pick(name == "hint.likely", IN_LIKELY, IN_UNLIKELY) as u32;
    }
    if name == "frame.return_address" {
        return SI_HINT << 8 | IN_RETURN_ADDRESS as u32;
    }
    if name == "mem.volatile_load" || name == "mem.volatile_store" {
        return SI_HINT << 8 | pick(name == "mem.volatile_load", IN_VOLATILE_LOAD, IN_VOLATILE_STORE) as u32;
    }
    if !name.starts_with("simd.") {
        return 0;
    }
    let n = name.slice(5, name.len());
    let ops: []str = ["add", "sub", "mul", "div", "rem", "and", "or", "xor", "shl", "shr"];
    let toks: []tt::TokenType = [
        tt::TokenType::Plus,
        tt::TokenType::Minus,
        tt::TokenType::Star,
        tt::TokenType::Slash,
        tt::TokenType::Percent,
        tt::TokenType::Ampersand,
        tt::TokenType::Pipe,
        tt::TokenType::Caret,
        tt::TokenType::LeftShift,
        tt::TokenType::RightShift,
    ];
    for i in 0..ops.len() {
        if n == ops[i] {
            return SI_BINARY << 8 | toks[i] as u32;
        }
    }
    if n == "neg" || n == "not" {
        return SI_UNARY << 8 | pick(n == "neg", tt::TokenType::Minus, tt::TokenType::Tilde) as u32;
    }
    if n == "cast" {
        return SI_CAST << 8 | CAST_NUMERIC as u32;
    }
    let t: []SimdOp = SIMD_OPS;
    for c in 0..t.len() {
        if n == t[c].name {
            return SI_SIMD << 8 | c as u32;
        }
    }
    return 0;
}

/// The portable vector operations a `@simd_impl` entry implements, `std::simd::Op` in the same
/// order (a variant's discriminant is its index): the operators of `simd_intrinsic` (`add` to `shr`,
/// `neg`, `not`), the numeric cast, the RV_SIMD codes from OP_SIMD, then the forms only the
/// lowering planner uses: the comparisons and `choose` over lane masks (a lane of all ones when
/// true), the conversions between a lane mask and `Mask<N>`, the lane-mask `any` and `all`, and the
/// shifts by one scalar count already checked to be below the lane width.
pub(package) const OP_ADD: u32 = 0;
pub(package) const OP_SUB: u32 = 1;
pub(package) const OP_MUL: u32 = 2;
pub(package) const OP_DIV: u32 = 3;
pub(package) const OP_REM: u32 = 4;
pub(package) const OP_AND: u32 = 5;
pub(package) const OP_OR: u32 = 6;
pub(package) const OP_XOR: u32 = 7;
pub(package) const OP_SHL: u32 = 8;
pub(package) const OP_SHR: u32 = 9;
pub(package) const OP_NEG: u32 = 10;
pub(package) const OP_NOT: u32 = 11;
pub(package) const OP_CAST: u32 = 12;
pub(package) const OP_SIMD: u32 = 13;
pub(package) const OP_CMP_LANES: u32 = OP_SIMD + SIMD_CODES as u32; // eq, ne, lt, le, gt, ge
pub(package) const OP_CHOOSE_LANES: u32 = OP_CMP_LANES + 6;
pub(package) const OP_LANES_TO_MASK: u32 = OP_CHOOSE_LANES + 1;
pub(package) const OP_MASK_TO_LANES: u32 = OP_CHOOSE_LANES + 2;
pub(package) const OP_ANY_LANES: u32 = OP_CHOOSE_LANES + 3;
pub(package) const OP_ALL_LANES: u32 = OP_CHOOSE_LANES + 4;
pub(package) const OP_SHL_SCALAR: u32 = OP_CHOOSE_LANES + 5;
pub(package) const OP_SHR_SCALAR: u32 = OP_CHOOSE_LANES + 6;
pub(package) const OP_COUNT: u32 = OP_CHOOSE_LANES + 7;

const OP_NAMES: [str<'static>; 13] = [
    "add",
    "sub",
    "mul",
    "div",
    "rem",
    "and",
    "or",
    "xor",
    "shl",
    "shr",
    "neg",
    "not",
    "cast",
];
const OP_PLAN_NAMES: [str<'static>; 13] = [
    "cmp_eq_lanes",
    "cmp_ne_lanes",
    "cmp_lt_lanes",
    "cmp_le_lanes",
    "cmp_gt_lanes",
    "cmp_ge_lanes",
    "choose_lanes",
    "lanes_to_mask",
    "mask_to_lanes",
    "any_lanes",
    "all_lanes",
    "shl_scalar",
    "shr_scalar",
];

/// The name of operation `op` (below OP_COUNT): an operator's, a vector operation's, a planner form's.
pub(package) const fn op_name(op: u32) str<'static> {
    let ops: []str<'static> = OP_NAMES;
    let pl: []str<'static> = OP_PLAN_NAMES;
    if op < OP_SIMD {
        return ops[op as usize];
    }
    if op < OP_CMP_LANES {
        return simd_op((op - OP_SIMD) as u8).name;
    }
    return pl[(op - OP_CMP_LANES) as usize];
}

/// The `std::simd::Op` variant of operation `op`: its name in CamelCase, a comparison prefixed `Cmp`.
pub(package) const fn op_variant(op: u32) String {
    let mut out = String::new();
    let n = op_name(op);
    if op >= OP_SIMD + SIMD_CMP_EQ as u32 && op <= OP_SIMD + SIMD_CMP_GE as u32 {
        out.push_str("Cmp");
    }
    let mut up = true;
    for i in 0..n.len() {
        let c = n.byte_at(i);
        if c == b'_' {
            up = true;
        } else {
            out.push_byte(pick(up && c >= b'a' && c <= b'z', c - 32, c));
            up = false;
        }
    }
    return out;
}

/// The run-time and compile-time trap message of a failing lane of rvalue kind `rk`: RV_BINARY with
/// operator token `op`, RV_UNARY (`-`), or RV_SIMD with code `op`; `second` for the second failure
/// kind of `/` and `%` (MIN / -1 after a zero divisor). The trap reads `lane <i>: <message>`.
pub(package) const fn lane_trap_msg(rk: u8, op: u8, second: bool) str<'static> {
    if rk != RV_BINARY {
        return pick(
            rk == RV_SIMD && op == SIMD_NARROW_CHECKED,
            "attempt to narrow a lane that does not fit",
            "attempt to negate with overflow",
        );
    }
    let t = op as tt::TokenType;
    return switch t {
        Plus => "attempt to add with overflow",
        Minus => "attempt to subtract with overflow",
        Star => "attempt to multiply with overflow",
        Slash => pick(second, "attempt to divide with overflow", "attempt to divide by zero"),
        Percent => pick(
            second,
            "attempt to calculate the remainder with overflow",
            "attempt to calculate the remainder with a divisor of zero",
        ),
        LeftShift => "attempt to shift left with overflow",
        RightShift => "attempt to shift right with overflow",
        _ => "attempt to negate with overflow",
    };
}

/// Cast kinds (RV_CAST.b).
pub(package) const CAST_NUMERIC: u8 = 0;
pub(package) const CAST_COERCE_FROM: u8 = 1; // library `from` conversion; item = selected method
pub(package) const CAST_SIMD_ARRAY: u8 = 2; // `[T; N]` to `Simd<T, N>` or back: the same lanes (std only)
pub(package) const CAST_MASK_BITS: u8 = 3; // `Mask<N>` to `u64` or back: lane `i` is bit `i` (std only)
pub(package) const CAST_UNCHECKED: u8 = 4; // float to integer by truncation, no saturation: the value is not NaN and fits (std's `to_int_unchecked`)

/// Aggregate kinds (RV_AGGREGATE.c).
pub(package) const AGG_STRUCT: u8 = 0;
pub(package) const AGG_TUPLE: u8 = 1;
pub(package) const AGG_ARRAY: u8 = 2;
pub(package) const AGG_VARIANT: u8 = 3; // item = variant decl; c2 = discriminant index

/// Compiler intrinsics that stay explicit operations (RV_INTRINSIC.c). Append-only.
pub(package) const IN_SIZEOF: u8 = 0;
pub(package) const IN_ALIGNOF: u8 = 1;
pub(package) const IN_VA_START: u8 = 2;
pub(package) const IN_VA_ARG: u8 = 3;
pub(package) const IN_VA_END: u8 = 4;
pub(package) const IN_TYPE_INFO: u8 = 5;
pub(package) const IN_ZEROED: u8 = 6;
pub(package) const IN_REFLECT: u8 = 7; // angle-3 compatibility: reflection binder/projection forms
// Inline assembly: `item.node` indexes the body's `asms` record (template, constraints and
// clobbers as source spans); operands are the outputs' places (as copies) then the input values,
// in source order.
pub(package) const IN_ASM: u8 = 10;
pub(package) const IN_SAFEPOINT: u8 = 11; // loop-body preemption marker; printed only for runtime-using programs
pub(package) const IN_DANGLING: u8 = 12; // non-null aligned no-storage pointer (`dangling::<T>()`; ZST buffers)
pub(package) const IN_DYN_TID: u8 = 13; // dyn_cast type test: operand = the fat value, target = the queried &T
pub(package) const IN_DYN_DATA: u8 = 14; // dyn_cast payload: operand = the fat value, target = the result &T
/// Safe-access checks (bounds-check normalization).
/// IN_BOUNDS(index, len): panics when index >= len, else returns the unchanged index. The
/// PROVEN twin has identical language semantics but a BCE proof that the panic edge is
/// unreachable: the C emitter prints only the index; the interpreter still checks.
pub(package) const IN_BOUNDS: u8 = 15;
/// The `item.node` of an IN_BOUNDS on a vector lane index: its trap names the index and the lane count.
pub(package) const CHECK_LANES: NodeId = 1;
pub(package) const IN_BOUNDS_PROVEN: u8 = 16;
/// IN_RANGE_BOUNDS(start, end, len): panics unless start <= end <= len, else returns the
/// validated exclusive end. Inclusive ranges are decomposed at lowering (IN_BOUNDS(end, len)
/// proves end < len BEFORE end + 1 is computed), so no inclusive flag exists in the IR.
pub(package) const IN_RANGE_BOUNDS: u8 = 17;
pub(package) const IN_RANGE_BOUNDS_PROVEN: u8 = 18;
/// IN_BOUNDS_GROUP(index, len, width): panics unless index <= len && width <= len - index (the
/// overflow-safe spelling of `index + width <= len`), else returns the unchanged index. Two
/// producers: BCE range-check coalescing (one group check at the FIRST access site covers the
/// accesses index .. index + width - 1, whose own element checks become IN_BOUNDS_PROVEN), and
/// the lowering of a vector load or store (SIMD_LOAD, SIMD_STORE), whose check is `CHECK_VEC`.
pub(package) const IN_BOUNDS_GROUP: u8 = 19;
/// The `item.node` of the IN_BOUNDS_GROUP before a vector load or store: its trap names the start,
/// the lane count and the length.
pub(package) const CHECK_VEC: NodeId = 2;
/// Combined preemption + cancellation safepoint (i32 result): the emitted hot path is the same
/// tick decrement as IN_SAFEPOINT; the cold half additionally asks the runtime's cancel hook
/// whether an unmasked request is pending, ACCEPTS it, and reports 1 -- the following switch then
/// enters the frame's cancellation ladder. Emitted instead of IN_SAFEPOINT when the body can carry
/// a cancellation edge.
pub(package) const IN_SAFEPOINT_C: u8 = 20;
/// Strip-mined counted loop: IN_CHUNK(i, end) with `i < end` returns the exclusive end `lim` of the
/// chunk that starts at `i`, `i < lim <= end`. A safepoint right before it counted the chunk's first
/// iteration; the chunk's other `lim - i - 1` iterations fit the tick budget left and are charged
/// to it here, so the chunk's backedges run without a tick. Where no tick prints, `lim` is `end`.
pub(package) const IN_CHUNK: u8 = 21;
/// IN_LIKELY(cond): returns the bool `cond` unchanged; the C emitter tells the C compiler that it
/// is usually true (the success test of `?`, whose failure path returns early, and `likely`).
pub(package) const IN_LIKELY: u8 = 22;
/// IN_BOUNDS_GROUP with a BCE proof that the panic edge is unreachable (a vector access's group
/// check in a strided loop): the C emitter prints only the index; the interpreter still checks.
pub(package) const IN_BOUNDS_GROUP_PROVEN: u8 = 23;
/// IN_UNLIKELY(cond): IN_LIKELY's twin for a condition that is usually false (`unlikely`).
pub(package) const IN_UNLIKELY: u8 = 24;
/// IN_RETURN_ADDRESS(): the code address the running function returns to (`*const void`), null where
/// the target has no frame walk (wasm). No compile-time value. Only a `@noinline` function names its
/// own caller with it (`std::rt::base`'s allocation sites).
pub(package) const IN_RETURN_ADDRESS: u8 = 25;
/// IN_VOLATILE_LOAD(p): the value `p` points to, read once (`*(volatile T *)p`); target = T.
/// IN_VOLATILE_STORE(p, v): writes `v` where `p` points, once; target = void. Neither is pure: no
/// pass drops one, merges two, or moves one across another, and C keeps each access. The evaluator
/// runs them as an ordinary load and store.
pub(package) const IN_VOLATILE_LOAD: u8 = 26;
pub(package) const IN_VOLATILE_STORE: u8 = 27;
/// IN_GROUP_FITS(index, len, width): the bool `index <= len && width <= len - index`, the
/// overflow-safe spelling of `index + width <= len`. It never panics: BCE widens the first of a run
/// of panic guards `root + k < len` to it, and its true edge proves every member guard.
pub(package) const IN_GROUP_FITS: u8 = 28;
/// IN_TYPE_NAME: `type_info::<T>().qualified_name` read alone, T in `b`: a `str` constant spelling T,
/// with the trailing generic arguments that equal their parameter's default dropped (`Vector<i32>`).
pub(package) const IN_TYPE_NAME: u8 = 29;

/// True for the intrinsics whose `b` is a type, not an operand count: the measuring, describing and
/// naming intrinsics and `dangling`.
pub(package) const fn type_payload(c: u8) bool {
    return c == IN_SIZEOF || c == IN_ALIGNOF || c == IN_TYPE_INFO || c == IN_DANGLING || c == IN_TYPE_NAME;
}

/// True for the six safe-access check intrinsics.
pub(package) const fn is_check(c: u8) bool {
    return c == IN_BOUNDS || c == IN_BOUNDS_PROVEN || c == IN_BOUNDS_GROUP || c == IN_BOUNDS_GROUP_PROVEN || c == IN_RANGE_BOUNDS || c == IN_RANGE_BOUNDS_PROVEN;
}

/// Operand count of a check intrinsic: element checks take (index, len); range and group checks
/// take (start, end, len) / (index, len, width).
pub(package) const fn check_arity(c: u8) u32 {
    if c == IN_BOUNDS || c == IN_BOUNDS_PROVEN {
        return 2;
    }
    return 3;
}

// Field order packs to 24 bytes (kind/c share the item's tail padding); bodies hold one record
// per expression, so the two byte flags sit last.
@derive(Copy)
pub(package) struct Rvalue {
    pub(package) a: u32,
    pub(package) b: u32,
    pub(package) target: TypeId, // result type
    pub(package) item: DefId, // selected method/decl when the kind carries one
    pub(package) kind: u8,
    pub(package) c: u8,
}

/// An Rvalue that selects no item.
pub(package) const fn rv(kind: u8, a: u32, b: u32, c: u8, target: TypeId) Rvalue {
    return Rvalue { a: a, b: b, target: target, item: DefId { module: 0, node: NODE_NONE }, kind: kind, c: c };
}

/// Statement kinds.
pub(package) const ST_ASSIGN: u8 = 0; // place = rvalue
pub(package) const ST_STORAGE_LIVE: u8 = 1; // a = LocalId
pub(package) const ST_STORAGE_DEAD: u8 = 2; // a = LocalId

@derive(Copy)
pub(package) struct Statement {
    pub(package) kind: u8,
    pub(package) place: PlaceId,
    pub(package) rvalue: RvalueId,
    pub(package) a: u32,
    pub(package) span: tok::Span,
}

/// Terminator kinds.
pub(package) const TM_GOTO: u8 = 0; // t0 = successor
pub(package) const TM_SWITCH: u8 = 1; // a = discriminant OperandId; values/targets in switch pool; t0 = otherwise
pub(package) const TM_CALL: u8 = 2; // callee item or fn-value operand; args in operand range; t0 = normal
pub(package) const TM_RETURN: u8 = 3; // args_len = RET_CANCEL marks a cancellation return (zero-valued, unread)

/// TM_RETURN.args_len value marking a cancellation-edge return: the frame's cleanup already ran and
/// the caller (itself unwinding) never reads the value, so the backend spells a zero literal.
pub(package) const RET_CANCEL: u32 = 1;
pub(package) const TM_DROP: u8 = 4; // place; t0 = successor
pub(package) const TM_ASSERT: u8 = 5; // a = condition OperandId; t0 = success
pub(package) const TM_UNREACHABLE: u8 = 6;

/// Verified intrinsic calls (Terminator.intr): a TM_CALL of the extern C memory or atomic routine the
/// kind names, with the routine's arity and a pointer or reference first argument (CI_FENCE takes
/// none). Analyses read the exact effect from the kind; the call itself stays an ordinary call.
/// Append-only.
pub(package) const CI_NONE: u8 = 0;
pub(package) const CI_MEMCPY: u8 = 1;
pub(package) const CI_MEMMOVE: u8 = 2;
pub(package) const CI_MEMSET: u8 = 3;
pub(package) const CI_ATOMIC_LOAD: u8 = 4; // `__sc_atomic_load_<T>(p, order)`
pub(package) const CI_ATOMIC_STORE: u8 = 5; // `__sc_atomic_store_<T>(p, v, order)`
pub(package) const CI_ATOMIC_RMW: u8 = 6; // `__sc_atomic_{swap,add,sub,and,or,xor}_<T>(p, v, order)`
pub(package) const CI_ATOMIC_CAS: u8 = 7; // `__sc_atomic_cas_<T>(p, expected, desired, weak, success, failure)`
pub(package) const CI_FENCE: u8 = 8; // `__sc_atomic_fence(order)`

/// The intrinsic kind an extern function named `name` is, or CI_NONE.
pub(package) const fn ci_of_name(name: str) u8 {
    if name == "memcpy" {
        return CI_MEMCPY;
    }
    if name == "memmove" {
        return CI_MEMMOVE;
    }
    if name == "memset" {
        return CI_MEMSET;
    }
    if !name.starts_with("__sc_atomic_") {
        return CI_NONE;
    }
    let op = name.slice(12, name.len());
    if op == "fence" {
        return CI_FENCE;
    }
    if op.starts_with("load_") {
        return CI_ATOMIC_LOAD;
    }
    if op.starts_with("store_") {
        return CI_ATOMIC_STORE;
    }
    if op.starts_with("cas_") {
        return CI_ATOMIC_CAS;
    }
    if op.starts_with("swap_") || op.starts_with("add_") || op.starts_with("sub_") || op.starts_with("and_") || op.starts_with(
        "or_",
    ) || op.starts_with("xor_") {
        return CI_ATOMIC_RMW;
    }
    return CI_NONE;
}

/// The argument count of intrinsic kind `k` (0 for CI_NONE).
pub(package) const fn ci_arity(k: u8) u32 {
    if k == CI_MEMCPY || k == CI_MEMMOVE || k == CI_MEMSET || k == CI_ATOMIC_STORE || k == CI_ATOMIC_RMW {
        return 3;
    }
    if k == CI_ATOMIC_LOAD {
        return 2;
    }
    if k == CI_ATOMIC_CAS {
        return 6;
    }
    if k == CI_FENCE {
        return 1;
    }
    return 0;
}

/// The printed name of intrinsic kind `k`.
pub(package) const fn ci_name(k: u8) str<'static> {
    if k == CI_MEMCPY {
        return "memcpy";
    }
    if k == CI_MEMMOVE {
        return "memmove";
    }
    if k == CI_MEMSET {
        return "memset";
    }
    if k == CI_ATOMIC_LOAD {
        return "atomic_load";
    }
    if k == CI_ATOMIC_STORE {
        return "atomic_store";
    }
    if k == CI_ATOMIC_RMW {
        return "atomic_rmw";
    }
    if k == CI_ATOMIC_CAS {
        return "atomic_cas";
    }
    if k == CI_FENCE {
        return "fence";
    }
    return "none";
}

// Field order leaves no interior padding: 68 bytes, the three byte fields in the tail.
@derive(Copy)
pub(package) struct Terminator {
    pub(package) a: u32, // per kind (see above)
    pub(package) args_start: u32, // TM_CALL: argument operand range
    pub(package) args_len: u32,
    pub(package) dests_start: u32, // TM_CALL: destination place range (multi-return)
    pub(package) dests_len: u32,
    pub(package) sw_start: u32, // TM_SWITCH: (value, target) pair range in switch pool
    pub(package) sw_len: u32,
    pub(package) t0: BlockId, // primary successor (goto/normal/success/otherwise)
    pub(package) targs_start: u32, // TM_CALL: the checker's bound generic arguments (CoreBody.targ_pool)
    pub(package) targs_len: u32,
    pub(package) callee: DefId, // TM_CALL resolved target; node == NODE_NONE for fn-value calls (a = operand)
    // TM_CALL of a generic interface's method through a bound: `dyn I<args>` naming the conformance
    // each instance dispatches to (`BoundCall`); TYPE_NONE otherwise.
    pub(package) iface: TypeId,
    // TM_CALL of an interface's associated function through a type parameter (`T::count()`,
    // `Self::make()` in a default body): the implementor, the parameter itself; TYPE_NONE otherwise.
    pub(package) recv: TypeId,
    pub(package) span: tok::Span,
    pub(package) kind: u8,
    pub(package) is_variadic: bool,
    pub(package) intr: u8, // TM_CALL: a CI_* verified intrinsic kind, CI_NONE otherwise
}
static_assert(sizeof(Terminator) == 68, "Terminator stays 68 bytes: intr sits in the tail padding");

/// A terminator of `kind` with no operands and no successor.
pub(package) const fn term0(kind: u8, sp: tok::Span) Terminator {
    return Terminator {
        kind: kind,
        a: IR_NONE,
        args_start: 0,
        args_len: 0,
        dests_start: 0,
        dests_len: 0,
        sw_start: 0,
        sw_len: 0,
        t0: IR_NONE,
        callee: DefId { module: 0, node: NODE_NONE },
        iface: TYPE_NONE,
        recv: TYPE_NONE,
        targs_start: 0,
        targs_len: 0,
        is_variadic: false,
        intr: CI_NONE,
        span: sp,
    };
}

/// A goto to `to`.
pub(package) const fn goto_term(to: BlockId, sp: tok::Span) Terminator {
    let mut t = term0(TM_GOTO, sp);
    t.t0 = to;
    return t;
}

/// One basic block: a statement range plus exactly one terminator.
@derive(Copy)
pub(package) struct BasicBlock {
    pub(package) stmt_start: u32,
    pub(package) stmt_len: u32,
    pub(package) term: Terminator,
    pub(package) sealed: bool, // terminator present (the verifier rejects unsealed blocks)
}
static_assert(sizeof(BasicBlock) == 80, "BasicBlock stays 80 bytes");

/// One lowered body. All ranges index the body-local pools below; nothing points at another body.
pub(package) struct CoreBody {
    pub(package) owner: DefId, // the function/const decl this body lowers
    pub(package) module: ModuleId,
    pub(package) args: u32,
    pub(package) returns: u32,
    pub(package) is_generic: bool, // generic bodies may carry symbolic types (verifier rule 15)
    /// The body contains an UNEXPANDED reflection binder (`inline for .. in fields(..)` whose
    /// owner stayed symbolic): instances must RE-LOWER with the demand env, never share this body.
    pub(package) has_reflect: bool,
    /// A vector index list names a generic parameter (`SIMD_SWIZZLE`/`SIMD_SHUFFLE` with no
    /// `simd_aux` record): instances re-lower with the demand env as for `has_reflect`, and the
    /// inliner re-lowers the callee under each call's bindings.
    pub(package) has_lists: bool,
    /// The body contains an unfolded `sizeof(T) <op> <const>` branch: instances re-lower with the
    /// demand env so the untaken side (a ZST container path or its material twin) never emits.
    pub(package) has_zst_cond: bool,
    // Some `let x: T;` declared a local without a value: only then can a use-before-init exist,
    // so bodies without it (and without moves) skip the move/init dataflow outright.
    pub(package) has_uninit_decl: bool,
    /// Drop elaboration ran on this body (`ir::drops`): every scheduled drop is a `TM_DROP`
    /// terminator and the guarded ones read their flag temps. The borrow pass elaborates every
    /// body it keeps; emission elaborates only the bodies it lowers itself.
    pub(package) elaborated: bool,
    /// The pre-elaboration size passed the inliner's callee limits (`ir::inline`): the vet reads
    /// this bit so an elaborated callee is judged by the shape the limits were tuned for.
    pub(package) inline_size_ok: bool,
    /// The owner is a std decl that runs user code only through bound dispatch
    /// (`Package::co_inst_on`): an instance prints its preemption ticks only when a binding names
    /// a type whose methods can be user code.
    pub(package) inst_ticks: bool,
    /// The blocks and the chunks the counted-loop lowering added (`chunk_open`: one block per
    /// counted loop; `chunk_close`: two blocks, two statements and two locals per chunk): the
    /// inliner's size gate leaves them out.
    pub(package) count_blocks: u32,
    pub(package) chunks: u32,
    pub(package) locals: Vector<LocalDecl>,
    pub(package) blocks: Vector<BasicBlock>,
    pub(package) statements: Vector<Statement>,
    pub(package) places: Vector<Place>,
    pub(package) projections: Vector<Projection>,
    pub(package) operands: Vector<Operand>,
    pub(package) rvalues: Vector<Rvalue>,
    pub(package) constants: Vector<Constant>,
    pub(package) oper_pool: Vector<OperandId>, // argument/aggregate operand ranges
    pub(package) dest_pool: Vector<PlaceId>, // call destination ranges
    pub(package) switch_pool: Vector<u64>, // TM_SWITCH pairs: value<<32 | target (values are u32-encoded)
    pub(package) targ_pool: Vector<TypeId>, // generic-argument ranges for calls and item constants
    // Bit per operand: this OP_MOVE is a USER consumption (let/return/argument/aggregate/assign
    // positions the walk's move rules check) -- pattern binds, downcasts, and spills stay unmarked.
    pub(package) user_moves: Vector<u64>,
    pub(package) asms: Vector<AsmRec>,
    pub(package) asm_spans: Vector<tok::Span>,
    /// The bytes of the CK_BYTES constants.
    pub(package) bytes: Vector<u8>,
    /// RV_SIMD index lists (`item.node` is the start): the length, then the lane indexes four `u8` per
    /// word, low byte first.
    pub(package) simd_aux: Vector<u32>,
    /// The calls the inliner replaced whose callee instance holds a per-instantiation
    /// `static_assert`: the emitter still demands each instance, so the assert still runs.
    pub(package) demands: Vector<Terminator>,
    /// The blocks whose `TM_GOTO` replaced a call of the body's function to itself (`ir::tailcall`):
    /// the unbounded-recursion check reads each one as that call (`ir::recursion`).
    pub(package) tail_jumps: Vector<BlockId>,
    pub(package) entry: BlockId,
}

// An exact-capacity copy of `v` (a kept body never grows).
fn exact<T: Copy>(v: &Vector<T>) Vector<T> {
    let mut out = Vector::<T>::with_capacity(v.len());
    out.extend_copy(v);
    return out;
}

extend CoreBody {
    /// True when a projection of place `pl` is a deref: the place reaches through a reference.
    pub(package) const fn place_has_deref(self: &Self, pl: PlaceId) bool {
        return self.deref_past(pl, 0);
    }

    /// True when a projection of place `pl` past its first `n` is a deref: a place `n` projections
    /// long on its path holds a reference the place reaches through.
    pub(package) const fn deref_past(self: &Self, pl: PlaceId, n: u32) bool {
        let p = self.places.at(pl as usize);
        for i in n..p.proj_len {
            if self.projections.at((p.proj_start + i) as usize).kind == PJ_DEREF {
                return true;
            }
        }
        return false;
    }

    /// Rewrite every type this body holds through a publication map (`Package::map_type` for the
    /// body's module): locals, places, projections, operands, constants, generic arguments, rvalue
    /// result types and the type payloads of dyn construction and the measuring intrinsics.
    pub(package) const fn remap_types(self: &mut Self, map: &Vector<TypeId>) {
        for i in 0..self.locals.len() {
            let l = self.locals.index_mut(i);
            l.ty = pub_map1(map, l.ty);
        }
        for i in 0..self.places.len() {
            let pl = self.places.index_mut(i);
            pl.ty = pub_map1(map, pl.ty);
        }
        for i in 0..self.projections.len() {
            let pj = self.projections.index_mut(i);
            pj.ty = pub_map1(map, pj.ty);
        }
        for i in 0..self.operands.len() {
            let o = self.operands.index_mut(i);
            o.ty = pub_map1(map, o.ty);
        }
        for i in 0..self.constants.len() {
            let c = self.constants.index_mut(i);
            c.ty = pub_map1(map, c.ty);
        }
        for i in 0..self.targ_pool.len() {
            self.targ_pool[i] = pub_map1(map, self.targ_pool[i]);
        }
        for i in 0..self.blocks.len() {
            let t = &mut self.blocks.index_mut(i).term;
            t.iface = pub_map1(map, t.iface);
            t.recv = pub_map1(map, t.recv);
        }
        for i in 0..self.demands.len() {
            let t = self.demands.index_mut(i);
            t.iface = pub_map1(map, t.iface);
            t.recv = pub_map1(map, t.recv);
        }
        for i in 0..self.rvalues.len() {
            let rv = self.rvalues.index_mut(i);
            rv.target = pub_map1(map, rv.target);
            if rv.kind == RV_DYN || rv.kind == RV_INTRINSIC && type_payload(rv.c) {
                rv.b = pub_map1(map, rv.b);
            }
        }
    }

    pub(package) fn new(owner: DefId, module: ModuleId) CoreBody {
        return CoreBody {
            owner: owner,
            module: module,
            args: 0,
            returns: 0,
            is_generic: false,
            has_reflect: false,
            has_lists: false,
            has_zst_cond: false,
            inst_ticks: false,
            count_blocks: 0,
            chunks: 0,
            has_uninit_decl: false,
            elaborated: false,
            inline_size_ok: false,
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
            asms: Vector::<AsmRec>::new(),
            asm_spans: Vector::<tok::Span>::new(),
            bytes: Vector::<u8>::new(),
            simd_aux: Vector::<u32>::new(),
            demands: Vector::<Terminator>::new(),
            tail_jumps: Vector::<BlockId>::new(),
            entry: 0,
        };
    }

    /// Re-seed for a fresh body, keeping every pool's heap capacity so the next lowering refills
    /// instead of reallocating. Callers that reuse one Lowerer across bodies rely on this.
    pub(package) fn clear(self: &mut Self, owner: DefId, module: ModuleId) {
        self.owner = owner;
        self.module = module;
        self.args = 0;
        self.returns = 0;
        self.is_generic = false;
        self.has_reflect = false;
        self.has_lists = false;
        self.has_zst_cond = false;
        self.inst_ticks = false;
        self.count_blocks = 0;
        self.chunks = 0;
        self.has_uninit_decl = false;
        self.elaborated = false;
        self.inline_size_ok = false;
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
        self.asms.truncate(0);
        self.asm_spans.truncate(0);
        self.bytes.truncate(0);
        self.simd_aux.truncate(0);
        self.demands.truncate(0);
        self.tail_jumps.truncate(0);
        self.entry = 0;
    }

    /// The bytes the body's pools hold (capacity, slack included).
    pub(package) const fn retained_bytes(self: &Self) u64 {
        let mut n = self.locals.capacity() * sizeof(LocalDecl) + self.blocks.capacity() * sizeof(BasicBlock);
        n += self.statements.capacity() * sizeof(Statement) + self.places.capacity() * sizeof(Place);
        n += self.projections.capacity() * sizeof(Projection) + self.operands.capacity() * sizeof(Operand);
        n += self.rvalues.capacity() * sizeof(Rvalue) + self.constants.capacity() * sizeof(Constant);
        n += (self.oper_pool.capacity() + self.dest_pool.capacity() + self.targ_pool.capacity() + self.simd_aux.capacity() + self.tail_jumps.capacity()) * 4;
        n += (self.switch_pool.capacity() + self.user_moves.capacity()) * 8;
        n += self.asms.capacity() * sizeof(AsmRec) + self.asm_spans.capacity() * sizeof(tok::Span);
        n += self.demands.capacity() * sizeof(Terminator) + self.bytes.capacity();
        return n as u64;
    }

    /// An exact-size deep copy: every pool reserves its final length, so a kept body carries no
    /// growth slack and costs one allocation per non-empty pool. The copy leaves out the borrow
    /// pass inputs `has_uninit_decl` and `user_moves`: every reader of them runs before the copy.
    pub(package) fn compact_from(src: &CoreBody) CoreBody {
        let mut out = CoreBody::new(src.owner, src.module);
        out.args = src.args;
        out.returns = src.returns;
        out.is_generic = src.is_generic;
        out.has_reflect = src.has_reflect;
        out.has_lists = src.has_lists;
        out.has_zst_cond = src.has_zst_cond;
        out.inst_ticks = src.inst_ticks;
        out.count_blocks = src.count_blocks;
        out.chunks = src.chunks;
        out.elaborated = src.elaborated;
        out.inline_size_ok = src.inline_size_ok;
        out.entry = src.entry;
        out.locals = exact(&src.locals);
        out.blocks = exact(&src.blocks);
        out.statements = exact(&src.statements);
        out.places = exact(&src.places);
        out.projections = exact(&src.projections);
        out.operands = exact(&src.operands);
        out.rvalues = exact(&src.rvalues);
        out.constants = exact(&src.constants);
        out.oper_pool = exact(&src.oper_pool);
        out.dest_pool = exact(&src.dest_pool);
        out.switch_pool = exact(&src.switch_pool);
        out.targ_pool = exact(&src.targ_pool);
        out.asms = exact(&src.asms);
        out.asm_spans = exact(&src.asm_spans);
        out.bytes = exact(&src.bytes);
        out.simd_aux = exact(&src.simd_aux);
        out.demands = exact(&src.demands);
        out.tail_jumps = exact(&src.tail_jumps);
        return out;
    }

    /// Append statement `place = rv`.
    /// Does the body hold a preemption safepoint (plain or combined)?
    pub(package) const fn has_safepoint(self: &Self) bool {
        for si in 0..self.statements.len() {
            let s = *self.statements.at(si);
            if s.kind == ST_ASSIGN {
                let rv = *self.rvalues.at(s.rvalue as usize);
                if rv.kind == RV_INTRINSIC && (rv.c as u32 == IN_SAFEPOINT as u32 || rv.c as u32 == IN_SAFEPOINT_C as u32) {
                    return true;
                }
            }
        }
        return false;
    }

    pub(package) fn push_assign(self: &mut Self, place: PlaceId, rv: Rvalue, sp: tok::Span) {
        self.rvalues.push(rv);
        self.statements.push(
            Statement { kind: ST_ASSIGN, place: place, rvalue: self.rvalues.len() as u32 - 1, a: 0, span: sp },
        );
    }

    /// Append `l = rv` through a fresh whole-local place.
    pub(package) fn assign_local(self: &mut Self, l: LocalId, rv: Rvalue, sp: tok::Span) {
        self.places.push(Place { base: l, proj_start: 0, proj_len: 0, ty: self.locals.at(l as usize).ty });
        self.push_assign(self.places.len() as u32 - 1, rv, sp);
    }

    /// Append `l = op` (RV_USE at the local's type).
    pub(package) fn assign_local_use(self: &mut Self, l: LocalId, op: OperandId, sp: tok::Span) {
        self.assign_local(l, rv(RV_USE, op, 0, 0, self.locals.at(l as usize).ty), sp);
    }

    pub(package) fn add_local(self: &mut Self, d: LocalDecl) LocalId {
        self.locals.push(d);
        return self.locals.len() as LocalId - 1;
    }

    /// Open a new (unsealed) block; statements append through stmt() until seal().
    pub(package) fn add_block(self: &mut Self) BlockId {
        self.blocks.push(
            BasicBlock {
                stmt_start: 0,
                stmt_len: 0,
                term: term0(TM_UNREACHABLE, tok::Span { start: 0, end: 0 }),
                sealed: false,
            },
        );
        return self.blocks.len() as BlockId - 1;
    }
}

// The value of hex digit `c`, or -1.
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
