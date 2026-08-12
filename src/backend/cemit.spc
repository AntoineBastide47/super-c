// The streaming C backend's function emitter: one verified Core body at a time into
// one reusable buffer, strict C11 portable output -- explicit temporaries, no GNU statement
// expressions, no `__auto_type`. Locals spell as their stable `LocalId` (`_N`), blocks as `BlockId`
// labels (`bb_N`), so two serial runs are byte-identical by construction. The emitter consumes ONLY
// Core IR, the layout target record, and pre-rendered names: it never resolves, searches, infers,
// interns, or evaluates syntax. Bodies outside the currently emittable subset refuse with a reason
// instead of guessing.
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import lexer::token_type as tt;

pub struct CEmit {
    pub pkg: *const loader::Package,
    pub out: String, // the reusable output buffer (caller-owned lifecycle, cleared per TU)
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
}

extend CEmit as Free {
    pub fn free(self: &mut Self) {
        self.out.free();
    }
}

// The portable C spelling of a builtin, or "" when the type is outside the subset.
const fn bt_c(b: BuiltinType) str<'static> {
    if b == BuiltinType::BT_BOOL {
        return "bool";
    }
    if b == BuiltinType::BT_CHAR || b == BuiltinType::BT_U8 {
        return "uint8_t";
    }
    if b == BuiltinType::BT_I8 {
        return "int8_t";
    }
    if b == BuiltinType::BT_I16 {
        return "int16_t";
    }
    if b == BuiltinType::BT_U16 {
        return "uint16_t";
    }
    if b == BuiltinType::BT_I32 {
        return "int32_t";
    }
    if b == BuiltinType::BT_U32 {
        return "uint32_t";
    }
    if b == BuiltinType::BT_I64 {
        return "int64_t";
    }
    if b == BuiltinType::BT_U64 {
        return "uint64_t";
    }
    if b == BuiltinType::BT_ISIZE {
        return "intptr_t";
    }
    if b == BuiltinType::BT_USIZE {
        return "uintptr_t";
    }
    if b == BuiltinType::BT_F32 {
        return "float";
    }
    if b == BuiltinType::BT_F64 {
        return "double";
    }
    return "";
}

extend CEmit {
    pub fn new(pkg: *const loader::Package) CEmit {
        return CEmit { pkg: pkg, out: String::new(), err: "" };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    fn fail(self: &mut Self, why: str<'static>) {
        if self.err.len() == 0 {
            self.err = why;
        }
    }

    // The C spelling of `(m, t)` within the portable subset: builtins, `void`, and single-level
    // pointers/references to them. Aggregates join once the declaration plan exists.
    fn ty_c(self: &mut Self, m: ModuleId, t: TypeId, out: &mut String) bool {
        if t == TYPE_NONE {
            out.push_str("void");
            return true;
        }
        let ap = self.p().module_ast_const(m);
        let y = *unsafe (&*ap).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let s = bt_c(y.as_data.builtin);
            if s.len() == 0 {
                self.fail("type-builtin");
                return false;
            }
            out.push_str(s);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            let ey = *unsafe (&*ap).type_at(y.as_data.elem);
            if ey.kind != TypeKind::TYPE_BUILTIN {
                self.fail("type-pointee");
                return false;
            }
            let s = bt_c(ey.as_data.builtin);
            if s.len() == 0 {
                self.fail("type-pointee");
                return false;
            }
            out.push_str(s);
            if y.kind == TypeKind::TYPE_POINTER && y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                out.push_str(" const");
            }
            out.push_str(" *");
            return true;
        }
        self.fail("type");
        return false;
    }

    /// Emit `b` as one C function named `name` into the shared buffer. False (with `err`) when the
    /// body leaves the portable subset; the buffer then holds no partial function.
    pub fn emit_fn(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        self.err = "";
        let mark = self.out.len();
        if !self.emit_fn_inner(b, name) {
            self.out.truncate(mark);
            return false;
        }
        return true;
    }

    fn emit_fn_inner(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        if b.returns > 1 {
            self.fail("multi-return");
            return false;
        }
        // signature
        let mut rt = String::new();
        let mut rty = TYPE_NONE;
        if b.returns == 1 {
            rty = b.locals.at(0).ty;
        }
        if !self.ty_c(b.module, rty, &mut rt) {
            rt.free();
            return false;
        }
        self.out.push_string(&rt);
        rt.free();
        self.out.push_str(" ");
        self.out.push_str(name);
        self.out.push_str("(");
        for i in 0..b.args {
            if i != 0 {
                self.out.push_str(", ");
            }
            let l = (b.returns + i) as usize;
            let mut ts = String::new();
            if !self.ty_c(b.module, b.locals.at(l).ty, &mut ts) {
                ts.free();
                return false;
            }
            self.out.push_string(&ts);
            ts.free();
            self.out.push_str(" _");
            self.out.push_u64(l as u64);
        }
        if b.args == 0 {
            self.out.push_str("void");
        }
        self.out.push_str(") {\n");
        // every non-argument local declares up front, explicitly typed
        for l in 0..b.locals.len() {
            let st = b.locals.at(l).storage;
            if st == ir::LS_ARG {
                continue;
            }
            if st == ir::LS_STATIC_REF {
                self.fail("static-ref");
                return false;
            }
            let mut ts = String::new();
            if !self.ty_c(b.module, b.locals.at(l).ty, &mut ts) {
                ts.free();
                return false;
            }
            self.out.push_str("  ");
            self.out.push_string(&ts);
            ts.free();
            self.out.push_str(" _");
            self.out.push_u64(l as u64);
            self.out.push_str(";\n");
        }
        // labels only where a goto lands (strict builds reject unused labels)
        let mut targeted = Vector::<bool>::new();
        for _i in 0..b.blocks.len() {
            targeted.push(false);
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.t0 != ir::IR_NONE && t.t0 as usize < b.blocks.len() {
                targeted.set(t.t0 as usize, true);
            }
            if t.kind == ir::TM_SWITCH {
                for k in 0..t.sw_len {
                    let tgt = (b.switch_pool[(t.sw_start + k) as usize] & 0xFFFFFFFFu64) as usize;
                    if tgt < b.blocks.len() {
                        targeted.set(tgt, true);
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            if targeted[bi] {
                self.out.push_str("bb_");
                self.out.push_u64(bi as u64);
                self.out.push_str(": ;\n");
            }
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if !self.emit_stmt(b, &s) {
                    return false;
                }
            }
            if !self.emit_term(b, &blk.term) {
                return false;
            }
        }
        targeted.free();
        self.out.push_str("}\n");
        return self.err.len() == 0;
    }

    fn emit_stmt(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return true; // markers carry no C
        }
        if s.kind != ir::ST_ASSIGN {
            self.fail("stmt");
            return false;
        }
        self.out.push_str("  ");
        if !self.emit_place(b, s.place) {
            return false;
        }
        self.out.push_str(" = ");
        if !self.emit_rvalue(b, s.rvalue) {
            return false;
        }
        self.out.push_str(";\n");
        return true;
    }

    fn emit_place(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId) bool {
        let pl = *b.places.at(pid as usize);
        // dereference chains wrap left-to-right; field/index projections stay out of the subset
        let mut derefs: u32 = 0;
        for i in 0..pl.proj_len {
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            if pj.kind != ir::PJ_DEREF {
                self.fail("projection");
                return false;
            }
            derefs += 1;
        }
        for _i in 0..derefs {
            self.out.push_str("(*");
        }
        self.out.push_str("_");
        self.out.push_u64(pl.base);
        for _i in 0..derefs {
            self.out.push_str(")");
        }
        return true;
    }

    fn emit_operand(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            return self.emit_place(b, op.data);
        }
        if op.kind != ir::OP_CONST {
            self.fail("operand");
            return false;
        }
        let c = *b.constants.at(op.data as usize);
        if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
            // spellings re-render from the span when present (hex etc. stay exact); the decimal
            // fast path covers synthesized constants
            let sp = c.raw;
            let mut digits = Vector::<u8>::new();
            let mut spelled = false;
            {
                let s0 = self.p().modules.at(b.module as usize).source.as_str();
                if sp.end > sp.start && sp.end as usize <= s0.len() {
                    let txt = s0.slice(sp.start as usize, sp.end as usize);
                    let b0 = txt.byte_at(0);
                    if b0 >= 48 && b0 <= 57 {
                        // strip a width suffix C cannot parse; keep the digits exactly
                        let n = txt.len();
                        let mut i: usize = 0;
                        let hex = n > 2 && txt.byte_at(1) == 120;
                        while i < n {
                            let ch = txt.byte_at(i);
                            let is_digit = ch >= 48 && ch <= 57 || ch == 95 || i < 2 && (ch == 120 || ch == 98 || ch == 111) || hex && (ch >= 97 && ch <= 102 || ch >= 65 && ch <= 70);
                            if !is_digit {
                                break;
                            }
                            if ch != 95 {
                                digits.push(ch);
                            }
                            i += 1;
                        }
                        spelled = true;
                    }
                }
            }
            if spelled {
                for k in 0..digits.len() {
                    self.out.push_byte(digits[k]);
                }
                digits.free();
                if c.kind == ir::CK_INT {
                    self.out.push_str("LL");
                }
                return true;
            }
            digits.free();
            if c.kind == ir::CK_BOOL {
                if c.val != 0 {
                    self.out.push_str("true");
                } else {
                    self.out.push_str("false");
                }
                return true;
            }
            self.out.push_i64(c.val);
            self.out.push_str("LL");
            return true;
        }
        self.fail("constant");
        return false;
    }

    fn emit_rvalue(self: &mut Self, b: &ir::CoreBody, rid: ir::RvalueId) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            return self.emit_operand(b, rv.a);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
            self.out.push_str("&");
            return self.emit_place(b, rv.a);
        }
        if rv.kind == ir::RV_CAST {
            if rv.b != ir::CAST_NUMERIC && rv.b != ir::CAST_POINTER {
                self.fail("cast");
                return false;
            }
            self.out.push_str("(");
            let mut ts = String::new();
            if !self.ty_c(b.module, rv.target, &mut ts) {
                ts.free();
                return false;
            }
            self.out.push_string(&ts);
            ts.free();
            self.out.push_str(")");
            return self.emit_operand(b, rv.a);
        }
        if rv.kind == ir::RV_UNARY {
            let t = (rv.b as u8) as tt::TokenType;
            if t == tt::TokenType::Minus {
                self.out.push_str("-");
            } else if t == tt::TokenType::Bang {
                self.out.push_str("!");
            } else if t == tt::TokenType::Tilde {
                self.out.push_str("~");
            } else {
                self.fail("unary");
                return false;
            }
            return self.emit_operand(b, rv.a);
        }
        if rv.kind == ir::RV_BINARY {
            let t = rv.c as tt::TokenType;
            let mut op: str<'static> = "";
            if t == tt::TokenType::Plus {
                op = "+";
            } else if t == tt::TokenType::Minus {
                op = "-";
            } else if t == tt::TokenType::Star {
                op = "*";
            } else if t == tt::TokenType::Slash {
                op = "/";
            } else if t == tt::TokenType::Percent {
                op = "%";
            } else if t == tt::TokenType::Ampersand || t == tt::TokenType::AmpersandAmpersand {
                op = "&";
            } else if t == tt::TokenType::Pipe || t == tt::TokenType::PipePipe {
                op = "|";
            } else if t == tt::TokenType::Caret {
                op = "^";
            } else if t == tt::TokenType::LeftShift {
                op = "<<";
            } else if t == tt::TokenType::RightShift {
                op = ">>";
            } else if t == tt::TokenType::EqualEqual {
                op = "==";
            } else if t == tt::TokenType::BangEqual {
                op = "!=";
            } else if t == tt::TokenType::LessThan {
                op = "<";
            } else if t == tt::TokenType::LessThanEqual {
                op = "<=";
            } else if t == tt::TokenType::GreaterThan {
                op = ">";
            } else if t == tt::TokenType::GreaterThanEqual {
                op = ">=";
            } else {
                self.fail("binary");
                return false;
            }
            self.out.push_str("(");
            if !self.emit_operand(b, rv.a) {
                return false;
            }
            self.out.push_str(" ");
            self.out.push_str(op);
            self.out.push_str(" ");
            if !self.emit_operand(b, rv.b) {
                return false;
            }
            self.out.push_str(")");
            return true;
        }
        self.fail("rvalue");
        return false;
    }

    fn emit_term(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.kind == ir::TM_GOTO || t.kind == ir::TM_DROP {
            // subset bodies carry no destructible values; the drop is pure control flow here
            self.out.push_str("  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_RETURN {
            if b.returns == 1 {
                self.out.push_str("  return _0;\n");
            } else {
                self.out.push_str("  return;\n");
            }
            return true;
        }
        if t.kind == ir::TM_UNREACHABLE {
            self.out.push_str("  abort();\n");
            return true;
        }
        if t.kind == ir::TM_ASSERT {
            self.out.push_str("  if (!(");
            if !self.emit_operand(b, t.a) {
                return false;
            }
            self.out.push_str(")) abort();\n  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_SWITCH {
            for k in 0..t.sw_len {
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                self.out.push_str("  if ((");
                if !self.emit_operand(b, t.a) {
                    return false;
                }
                self.out.push_str(") == ");
                self.out.push_u64(pair >> 32);
                self.out.push_str(") goto bb_");
                self.out.push_u64(pair & 0xFFFFFFFFu64);
                self.out.push_str(";\n");
            }
            self.out.push_str("  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_CALL {
            if t.callee.node == NODE_NONE {
                self.fail("fn-value-call");
                return false;
            }
            if t.dests_len > 1 {
                self.fail("multi-dest");
                return false;
            }
            self.out.push_str("  ");
            if t.dests_len == 1 {
                let dp = b.dest_pool[t.dests_start as usize];
                if !self.emit_place(b, dp) {
                    return false;
                }
                self.out.push_str(" = ");
            }
            // callee names come pre-rendered by the caller's plan; the subset uses fn_symbol
            self.out.push_str("f_");
            self.out.push_u64(t.callee.module);
            self.out.push_str("_");
            self.out.push_u64(t.callee.node);
            self.out.push_str("(");
            for i in 0..t.args_len {
                if i != 0 {
                    self.out.push_str(", ");
                }
                let opid = b.oper_pool[(t.args_start + i) as usize];
                if !self.emit_operand(b, opid) {
                    return false;
                }
            }
            self.out.push_str(");\n  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        self.fail("terminator");
        return false;
    }
}

/// The subset emitter's stable symbol for a function (per-package unique, deterministic).
pub fn fn_symbol(m: ModuleId, node: NodeId, out: &mut String) {
    out.push_str("f_");
    out.push_u64(m);
    out.push_str("_");
    out.push_u64(node);
}
