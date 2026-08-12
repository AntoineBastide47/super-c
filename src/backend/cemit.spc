// The streaming C backend's function emitter: one verified Core body at a time into one reusable
// buffer, strict C11 portable output -- explicit temporaries, no GNU statement expressions, no
// `__auto_type`. Locals spell as their stable `LocalId` (`_N`), blocks as `BlockId` labels
// (`bb_N`), so two serial runs are byte-identical by construction. Types and symbols come from the
// frozen mangler (backend::mangle); the emitter consumes ONLY Core IR and pool reads for spelling:
// it never resolves overloads, searches extends at emission time, infers, interns, or evaluates
// syntax. Bodies outside the currently emittable subset refuse with a reason instead of guessing.
import ast::ast as *;
import backend::mangle as mbe;
import ir::core as ir;
import lexer::token_type as tt;
import module::loader as loader;

pub struct CEmit {
    pub pkg: *const loader::Package,
    pub out: String, // the reusable output buffer (caller-owned lifecycle, cleared per TU)
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
    pub mg: mbe::Mangler,
}

extend CEmit as Free {
    pub fn free(self: &mut Self) {
        self.out.free();
        self.mg.free();
    }
}

extend CEmit {
    pub fn new(pkg: *const loader::Package) CEmit {
        return CEmit { pkg: pkg, out: String::new(), err: "", mg: mbe::Mangler::new(pkg) };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    fn fail(self: &mut Self, why: str<'static>) bool {
        if self.err.len() == 0 {
            self.err = why;
        }
        return false;
    }

    // `(pm, t)` as a C declarator around `decl`; TYPE_NONE (unit) spells `void`.
    fn ty_c(self: &mut Self, m: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        if t == TYPE_NONE {
            out.push_str("void");
            if decl.len() != 0 {
                out.push_str(" ");
                out.push_str(decl);
            }
            return true;
        }
        if !self.mg.ctype(m, t, decl, out) {
            return self.fail("ctype");
        }
        return true;
    }

    // The module whose ast declares the aggregate behind pool type `(b.module, t)` (instances
    // answer their owner). Used to spell member and variant names.
    fn agg_module(self: &Self, b: &ir::CoreBody, t: TypeId) ModuleId {
        let a = self.p().module_ast_const(b.module);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).module;
        }
        return y.module;
    }

    // The aggregate DECL node behind pool type `(b.module, t)` (instances answer the generic decl).
    fn agg_decl(self: &Self, b: &ir::CoreBody, t: TypeId) NodeId {
        let a = self.p().module_ast_const(b.module);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).decl;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return y.as_data.decl;
        }
        return NODE_NONE;
    }

    // Does this enum (by decl) carry any payload -- i.e. emit as {tag, payload} instead of a C enum?
    fn enum_has_payload(self: &Self, m: ModuleId, decl: NodeId) bool {
        let a = self.p().module_ast_const(m);
        let ms = a.at_const(decl).as_data.aggregate.members;
        for i in 0..ms.len {
            let vid = unsafe a.list(ms)[i as usize];
            if a.at_const(vid).kind == NodeKind::NODE_VARIANT && a.at_const(vid).as_data.variant.payload.len != 0 {
                return true;
            }
        }
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
            return self.fail("multi-return");
        }
        let mut rty = TYPE_NONE;
        if b.returns == 1 {
            rty = b.locals.at(0).ty;
        }
        let mut rt = String::new();
        let ok0 = self.ty_c(b.module, rty, "", &mut rt);
        if ok0 {
            self.out.push_string(&rt);
            self.out.push_str(" ");
            self.out.push_str(name);
            self.out.push_str("(");
        }
        rt.free();
        if !ok0 {
            return false;
        }
        for i in 0..b.args {
            if i != 0 {
                self.out.push_str(", ");
            }
            let l = (b.returns + i) as usize;
            let mut nm = String::from_str("_");
            nm.push_u64(l as u64);
            let mut ts = String::new();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_string(&ts);
            }
            ts.free();
            nm.free();
            if !ok {
                return false;
            }
        }
        if b.args == 0 {
            self.out.push_str("void");
        }
        self.out.push_str(") {\n");
        // every non-argument local declares up front, explicitly typed; unit locals carry no C
        for l in 0..b.locals.len() {
            let st = b.locals.at(l).storage;
            if st == ir::LS_ARG || b.locals.at(l).ty == TYPE_NONE {
                continue;
            }
            if st == ir::LS_STATIC_REF {
                continue; // reads spell the item's own symbol; the local never declares
            }
            let mut nm = String::from_str("_");
            nm.push_u64(l as u64);
            let mut ts = String::new();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&ts);
                self.out.push_str(";\n");
            }
            ts.free();
            nm.free();
            if !ok {
                return false;
            }
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
        let mut ok2 = true;
        for bi in 0..b.blocks.len() {
            if !ok2 {
                break;
            }
            if targeted[bi] {
                self.out.push_str("bb_");
                self.out.push_u64(bi as u64);
                self.out.push_str(": ;\n");
            }
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if !self.emit_stmt(b, &s) {
                    ok2 = false;
                    break;
                }
            }
            if ok2 && !self.emit_term(b, &blk.term) {
                ok2 = false;
            }
        }
        targeted.free();
        if !ok2 {
            return false;
        }
        self.out.push_str("}\n");
        return self.err.len() == 0;
    }

    fn emit_stmt(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return true; // markers carry no C
        }
        if s.kind != ir::ST_ASSIGN {
            return self.fail("stmt");
        }
        // rvalues are effect-free (calls are terminators), so a unit-typed store carries no C
        if b.places.at(s.place as usize).ty == TYPE_NONE {
            return true;
        }
        // a stored CK_UNIT is the lowerer's "no meaningful value" marker (expression-statement
        // results); the established emitter never materializes it
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_USE {
                let op0 = *b.operands.at(rv0.a as usize);
                if op0.kind == ir::OP_CONST && b.constants.at(op0.data as usize).kind == ir::CK_UNIT {
                    return true;
                }
            }
        }
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_ARRAY {
                return self.emit_array_stores(b, s, &rv0);
            }
            if rv0.kind == ir::RV_REPEAT {
                return self.emit_repeat_stores(b, s, &rv0);
            }
        }
        let mut lhs = String::new();
        let mut rhs = String::new();
        let ok = self.emit_place(b, s.place, &mut lhs) && self.emit_rvalue(b, s.rvalue, &mut rhs);
        if ok {
            self.out.push_str("  ");
            self.out.push_string(&lhs);
            self.out.push_str(" = ");
            self.out.push_string(&rhs);
            self.out.push_str(";\n");
        }
        lhs.free();
        rhs.free();
        return ok;
    }

    // C forbids array assignment: an array literal stores element-wise into the place.
    fn emit_array_stores(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let mut base = String::new();
        let mut ok = self.emit_place(b, s.place, &mut base);
        for i in 0..rv.b {
            if !ok {
                break;
            }
            let mut el = String::new();
            ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], &mut el);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&base);
                self.out.push_str("[");
                self.out.push_u64(i);
                self.out.push_str("] = ");
                self.out.push_string(&el);
                self.out.push_str(";\n");
            }
            el.free();
        }
        base.free();
        return ok;
    }

    // `[v; N]` with a small constant count unrolls to element stores (the count operand id rides
    // rv.b); larger repeats stay unfrozen.
    fn emit_repeat_stores(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let cnt = *b.operands.at(rv.b as usize);
        if cnt.kind != ir::OP_CONST {
            return self.fail("repeat-count");
        }
        let c = *b.constants.at(cnt.data as usize);
        if c.kind != ir::CK_INT || c.val < 0 || c.val > 64 {
            return self.fail("repeat-count");
        }
        let mut base = String::new();
        let mut el = String::new();
        let ok = self.emit_place(b, s.place, &mut base) && self.emit_operand(b, rv.a, &mut el);
        if ok {
            for i in 0..c.val {
                self.out.push_str("  ");
                self.out.push_string(&base);
                self.out.push_str("[");
                self.out.push_u64(i as u64);
                self.out.push_str("] = ");
                self.out.push_string(&el);
                self.out.push_str(";\n");
            }
        }
        base.free();
        el.free();
        return ok;
    }

    fn emit_place(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId, dst: &mut String) bool {
        let pl = *b.places.at(pid as usize);
        let mut cur = String::new();
        if b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF {
            let item = b.locals.at(pl.base as usize).item;
            if item.node == NODE_NONE || !self.mg.const_sym(b.module, item.module, item.node, &mut cur) {
                cur.free();
                return self.fail("static-sym");
            }
        } else {
            cur.push_str("_");
            cur.push_u64(pl.base);
        }
        let mut pre = b.locals.at(pl.base as usize).ty;
        let mut ok = true;
        for i in 0..pl.proj_len {
            if !ok {
                break;
            }
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF {
                let mut w = String::from_str("(*");
                w.push_string(&cur);
                w.push_str(")");
                cur.free();
                cur = w;
            } else if pj.kind == ir::PJ_FIELD {
                cur.push_str(".");
                if pj.sub == NODE_NONE {
                    // positional payload/tuple member: the emitted C names it `_<index>`
                    cur.push_str("_");
                    cur.push_u64(pj.data);
                } else {
                    let am = self.agg_module(b, pre);
                    let fa = self.p().module_ast_const(am);
                    self.mg.ident(am, fa.at_const(fa.at_const(pj.sub).as_data.field.name).as_data.name.text, &mut cur);
                }
            } else if pj.kind == ir::PJ_INDEX_CONST {
                cur.push_str("[");
                cur.push_u64(pj.data);
                cur.push_str("]");
            } else if pj.kind == ir::PJ_INDEX_OP {
                cur.push_str("[");
                ok = self.emit_operand(b, pj.data, &mut cur);
                cur.push_str("]");
            } else if pj.kind == ir::PJ_DOWNCAST {
                cur.push_str(".payload.");
                let am = self.agg_module(b, pre);
                let fa = self.p().module_ast_const(am);
                self.mg.ident(am, fa.at_const(fa.at_const(pj.sub).as_data.variant.name).as_data.name.text, &mut cur);
            } else {
                ok = self.fail("projection");
            }
            pre = pj.ty;
        }
        if ok {
            dst.push_string(&cur);
        }
        cur.free();
        return ok;
    }

    fn emit_operand(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            return self.emit_place(b, op.data, dst);
        }
        if op.kind != ir::OP_CONST {
            return self.fail("operand");
        }
        return self.emit_const(b, op.data, dst);
    }

    fn emit_const(self: &mut Self, b: &ir::CoreBody, cid: u32, dst: &mut String) bool {
        let c = *b.constants.at(cid as usize);
        let src = self.p().modules.at(b.module as usize).source.as_str();
        if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
            return self.emit_int(b, &c, dst);
        }
        if c.kind == ir::CK_FLOAT {
            // the exact source spelling, with the language width suffix mapped to C's
            let txt = src.slice(c.raw.start as usize, c.raw.end as usize);
            let n = txt.len();
            if n > 3 && txt.slice(n - 3, n) == "f32" {
                dst.push_str(txt.slice(0, n - 3));
                dst.push_str("f");
            } else if n > 3 && txt.slice(n - 3, n) == "f64" {
                dst.push_str(txt.slice(0, n - 3));
            } else {
                dst.push_str(txt);
            }
            return true;
        }
        if c.kind == ir::CK_STR {
            // quoted spellings carry C-valid escapes and copy verbatim; matchertext/raw segments
            // are raw BYTES and re-escape byte-wise (the lowerer records the token kind in val)
            let plain = c.val == tt::TokenType::StringLiteral as i64 || c.val == tt::TokenType::ByteStringLiteral as i64;
            let raw0 = src.slice(c.raw.start as usize, c.raw.end as usize);
            let mut esc = String::new();
            if plain {
                esc.push_str(raw0);
            } else {
                push_c_escaped(raw0, &mut esc);
            }
            let txt = esc.as_str();
            let a = self.p().module_ast_const(b.module);
            let is_slice = a.type_at(c.ty).kind == TypeKind::TYPE_INSTANCE;
            let mut cast = String::new();
            if !self.ty_c(b.module, c.ty, "", &mut cast) {
                cast.free();
                esc.free();
                return false;
            }
            dst.push_str("(");
            dst.push_string(&cast);
            cast.free();
            if is_slice {
                dst.push_str("){ .ptr = (const uint8_t *)\"");
                dst.push_str(txt);
                dst.push_str("\", .len = sizeof(\"");
                dst.push_str(txt);
                dst.push_str("\") - 1 }");
            } else {
                dst.push_str("){ (const uint8_t *)\"");
                dst.push_str(txt);
                dst.push_str("\", sizeof(\"");
                dst.push_str(txt);
                dst.push_str("\") - 1 }");
            }
            esc.free();
            return true;
        }
        if c.kind == ir::CK_ITEM {
            let mut sym = String::new();
            let mut ok = true;
            if self.mg.in_generic_extend(c.item.module, c.item.node) {
                ok = self.fail("method-inst");
            } else {
                let tgt = self.mg.method_target(c.item.module, c.item.node);
                if !self.mg.fn_sym(c.item.module, c.item.node, tgt, true, &mut sym) {
                    ok = self.fail("callee-sym");
                }
            }
            for k in 0..c.targ_len {
                if !ok {
                    break;
                }
                sym.push_str("__");
                if !self.mg.type_m(b.module, b.targ_pool[(c.targ_start + k) as usize], &mut sym) {
                    ok = self.fail("callee-targ");
                }
            }
            if ok {
                dst.push_string(&sym);
            }
            sym.free();
            return ok;
        }
        return self.fail("constant");
    }

    fn emit_int(self: &mut Self, b: &ir::CoreBody, c: &ir::Constant, dst: &mut String) bool {
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
                dst.push_byte(digits[k]);
            }
            digits.free();
            if c.kind == ir::CK_INT {
                dst.push_str("LL");
            }
            return true;
        }
        digits.free();
        if c.kind == ir::CK_BOOL {
            if c.val != 0 {
                dst.push_str("true");
            } else {
                dst.push_str("false");
            }
            return true;
        }
        dst.push_i64(c.val);
        dst.push_str("LL");
        return true;
    }

    // The callee's C symbol: the frozen fn symbol plus `__<targ>` per bound generic argument
    // (free-fn specializations and generic methods share that composition).
    // Peel references/pointers off `t` and answer the receiver instance when it instantiates the
    // generic decl `tgt`; TYPE_NONE-style miss = `it.decl == NODE_NONE`.
    fn recv_inst(self: &Self, b: &ir::CoreBody, t: TypeId, tgt: DefId) TyInstance {
        let a = self.p().module_ast_const(b.module);
        let mut cur = t;
        let mut guard = 0;
        while cur != TYPE_NONE && guard < 8 {
            let y = *a.type_at(cur);
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                cur = y.as_data.elem;
                guard += 1;
                continue;
            }
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *a.instance(y.as_data.inst);
                if it.module == tgt.module && it.decl == tgt.node {
                    return it;
                }
            }
            break;
        }
        return TyInstance { decl: NODE_NONE };
    }

    fn callee_sym(
        self: &mut Self,
        b: &ir::CoreBody,
        callee: DefId,
        targs_start: u32,
        targs_len: u32,
        recv_ty: TypeId,
        dest_ty: TypeId,
        dst: &mut String,
    ) bool {
        let mut sym = String::new();
        let mut ok = true;
        if self.mg.in_generic_extend(callee.module, callee.node) {
            // a generic extend's method emits per receiver instance: `<InstName>__<method>`
            let tgt = self.mg.method_target(callee.module, callee.node);
            let mut it = self.recv_inst(b, recv_ty, tgt);
            if it.decl == NODE_NONE {
                it = self.recv_inst(b, dest_ty, tgt);
            }
            if it.decl == NODE_NONE {
                sym.free();
                return self.fail("method-inst");
            }
            if !self.mg.inst_name(b.module, &it, &mut sym) {
                ok = self.fail("callee-inst");
            }
            if ok {
                sym.push_str("__");
                let ca = self.p().module_ast_const(callee.module);
                self.mg.ident(
                    callee.module,
                    ca.at_const(ca.at_const(callee.node).as_data.function.name).as_data.name.text,
                    &mut sym,
                );
            }
        } else {
            let tgt = self.mg.method_target(callee.module, callee.node);
            if !self.mg.fn_sym(callee.module, callee.node, tgt, true, &mut sym) {
                ok = self.fail("callee-sym");
            }
        }
        for k in 0..targs_len {
            if !ok {
                break;
            }
            sym.push_str("__");
            if !self.mg.type_m(b.module, b.targ_pool[(targs_start + k) as usize], &mut sym) {
                ok = self.fail("callee-targ");
            }
        }
        if ok {
            dst.push_string(&sym);
        }
        sym.free();
        return ok;
    }

    fn emit_rvalue(self: &mut Self, b: &ir::CoreBody, rid: ir::RvalueId, dst: &mut String) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            return self.emit_operand(b, rv.a, dst);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
            dst.push_str("&");
            return self.emit_place(b, rv.a, dst);
        }
        if rv.kind == ir::RV_CAST {
            if rv.b == ir::CAST_COERCE_FROM {
                // the checker's selected conversion method, called as a plain C expression
                let cvr = b.operands.at(rv.a as usize).ty;
                let mut ok = self.callee_sym(b, rv.item, 0, 0, cvr, rv.target, dst);
                if ok {
                    dst.push_str("(");
                    ok = self.emit_operand(b, rv.a, dst);
                    dst.push_str(")");
                }
                return ok;
            }
            if rv.b != ir::CAST_NUMERIC && rv.b != ir::CAST_POINTER {
                return self.fail("cast");
            }
            let mut ts = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut ts);
            if ok {
                dst.push_str("(");
                dst.push_string(&ts);
                dst.push_str(")");
            }
            ts.free();
            if ok {
                ok = self.emit_operand(b, rv.a, dst);
            }
            return ok;
        }
        if rv.kind == ir::RV_UNARY {
            let t = (rv.b as u8) as tt::TokenType;
            if t == tt::TokenType::Unsafe {
                // the `unsafe` prefix carries no C
            } else if t == tt::TokenType::Minus {
                dst.push_str("-");
            } else if t == tt::TokenType::Bang {
                dst.push_str("!");
            } else if t == tt::TokenType::Tilde {
                dst.push_str("~");
            } else {
                return self.fail("unary");
            }
            return self.emit_operand(b, rv.a, dst);
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
                return self.fail("binary");
            }
            dst.push_str("(");
            let mut ok = self.emit_operand(b, rv.a, dst);
            if ok {
                dst.push_str(" ");
                dst.push_str(op);
                dst.push_str(" ");
                ok = self.emit_operand(b, rv.b, dst);
            }
            dst.push_str(")");
            return ok;
        }
        if rv.kind == ir::RV_AGGREGATE {
            return self.emit_aggregate(b, &rv, dst);
        }
        if rv.kind == ir::RV_LEN {
            let pl = *b.places.at(rv.a as usize);
            let y = *self.p().module_ast_const(b.module).type_at(pl.ty);
            if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len != 0 {
                dst.push_u64(y.as_data.arr.len);
                return true;
            }
            return self.fail("len");
        }
        if rv.kind == ir::RV_DISCRIMINANT {
            let pl = *b.places.at(rv.a as usize);
            let decl = self.agg_decl(b, pl.ty);
            if decl == NODE_NONE {
                return self.fail("discr");
            }
            let am = self.agg_module(b, pl.ty);
            let ok = self.emit_place(b, rv.a, dst);
            if ok && self.enum_has_payload(am, decl) {
                dst.push_str(".tag");
            }
            return ok;
        }
        if rv.kind == ir::RV_INTRINSIC {
            let k = rv.c as u32;
            if k == ir::IN_SIZEOF as u32 || k == ir::IN_ALIGNOF as u32 {
                let mut ts = String::new();
                let ok = self.ty_c(b.module, rv.b, "", &mut ts);
                if ok {
                    dst.push_str(if_s(k == ir::IN_SIZEOF as u32, "sizeof(", "_Alignof("));
                    dst.push_string(&ts);
                    dst.push_str(")");
                }
                ts.free();
                return ok;
            }
            if k == ir::IN_ZEROED as u32 {
                let mut ts = String::new();
                let ok = self.ty_c(b.module, rv.target, "", &mut ts);
                if ok {
                    dst.push_str("(");
                    dst.push_string(&ts);
                    dst.push_str("){0}");
                }
                ts.free();
                return ok;
            }
            return self.fail("intrinsic");
        }
        if rv.kind == ir::RV_CLOSURE {
            // env literal `(closure_N_env){ .cap = op, ... }`; a capture-less closure value is the
            // bare hoisted function; mutable captures (pointer cells) stay unfrozen
            let cm = rv.item.module;
            let cn = rv.item.node;
            let ca = self.p().module_ast_const(cm);
            if rv.b == 0 {
                self.mg.closure_sym(cm, cn, dst);
                return true;
            }
            if ca.at_const(cn).as_data.closure.mut_caps != 0 {
                return self.fail("closure-mut");
            }
            let caps = ca.at_const(cn).as_data.closure.captures;
            if caps.len != rv.b {
                return self.fail("closure-caps");
            }
            dst.push_str("(");
            let mut nm = String::new();
            self.mg.closure_sym(cm, cn, &mut nm);
            dst.push_string(&nm);
            nm.free();
            dst.push_str("_env){ ");
            let mut ok = true;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                if i != 0 {
                    dst.push_str(", ");
                }
                dst.push_str(".");
                let decl = unsafe ca.list(caps)[i as usize];
                let csp = self.mg.decl_name_span(cm, decl);
                if csp.end <= csp.start {
                    ok = self.fail("closure-cap-name");
                    break;
                }
                self.mg.ident(cm, csp, dst);
                dst.push_str(" = ");
                ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], dst);
            }
            dst.push_str(" }");
            return ok;
        }
        return self.fail("rvalue");
    }

    fn emit_aggregate(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, dst: &mut String) bool {
        if rv.c == ir::AGG_VARIANT {
            let edecl = self.agg_decl(b, rv.target);
            if edecl == NODE_NONE {
                return self.fail("agg-enum");
            }
            let am = self.agg_module(b, rv.target);
            let mut tag = String::new();
            self.mg.enum_tag(am, edecl, rv.item.node, &mut tag);
            if !self.enum_has_payload(am, edecl) {
                dst.push_string(&tag);
                tag.free();
                return true;
            }
            let mut cast = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut cast);
            if ok {
                dst.push_str("(");
                dst.push_string(&cast);
                dst.push_str("){ .tag = ");
                dst.push_string(&tag);
                if rv.b != 0 {
                    dst.push_str(", .payload.");
                    let ea = self.p().module_ast_const(am);
                    self.mg.ident(
                        am,
                        ea.at_const(ea.at_const(rv.item.node).as_data.variant.name).as_data.name.text,
                        dst,
                    );
                    dst.push_str(" = { ");
                    for i in 0..rv.b {
                        if !ok {
                            break;
                        }
                        if i != 0 {
                            dst.push_str(", ");
                        }
                        ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], dst);
                    }
                    dst.push_str(" }");
                }
                dst.push_str(" }");
            }
            cast.free();
            tag.free();
            return ok;
        }
        if rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE {
            let mut cast = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut cast);
            if !ok {
                cast.free();
                return false;
            }
            dst.push_str("(");
            dst.push_string(&cast);
            dst.push_str(")");
            cast.free();
            if rv.b == 0 {
                dst.push_str("{0}");
                return true;
            }
            dst.push_str("{ ");
            if rv.c == ir::AGG_TUPLE {
                for i in 0..rv.b {
                    if !ok {
                        break;
                    }
                    if i != 0 {
                        dst.push_str(", ");
                    }
                    dst.push_str("._");
                    dst.push_u64(i);
                    dst.push_str(" = ");
                    ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], dst);
                }
                dst.push_str(" }");
                return ok;
            }
            let sdecl = self.agg_decl(b, rv.target);
            if sdecl == NODE_NONE {
                return self.fail("agg-struct");
            }
            let am = self.agg_module(b, rv.target);
            let sa = self.p().module_ast_const(am);
            let ms = sa.at_const(sdecl).as_data.aggregate.members;
            if ms.len != rv.b {
                return self.fail("agg-arity");
            }
            // decl-order operands with IR_NONE holes: omitted members zero-fill in C
            let mut emitted: u32 = 0;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    continue;
                }
                if emitted != 0 {
                    dst.push_str(", ");
                }
                dst.push_str(".");
                let fid = unsafe sa.list(ms)[i as usize];
                self.mg.ident(am, sa.at_const(sa.at_const(fid).as_data.field.name).as_data.name.text, dst);
                dst.push_str(" = ");
                ok = self.emit_operand(b, opid, dst);
                emitted += 1;
            }
            if emitted == 0 {
                dst.push_str("0");
            }
            dst.push_str(" }");
            return ok;
        }
        return self.fail("agg-kind");
    }

    fn emit_term(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.kind == ir::TM_GOTO {
            self.out.push_str("  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_DROP {
            // scalar drops are pure control flow; destructible values need the declaration plan's
            // free glue and stay unfrozen
            let pl = *b.places.at(t.a as usize);
            let y = *self.p().module_ast_const(b.module).type_at(pl.ty);
            if y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                return self.fail("drop");
            }
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
            let mut cond = String::new();
            let ok = self.emit_operand(b, t.a, &mut cond);
            if ok {
                self.out.push_str("  if (!(");
                self.out.push_string(&cond);
                self.out.push_str(")) abort();\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            cond.free();
            return ok;
        }
        if t.kind == ir::TM_SWITCH {
            let mut d = String::new();
            let ok = self.emit_operand(b, t.a, &mut d);
            for k in 0..t.sw_len {
                if !ok {
                    break;
                }
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                self.out.push_str("  if ((");
                self.out.push_string(&d);
                self.out.push_str(") == ");
                self.out.push_u64(pair >> 32);
                self.out.push_str(") goto bb_");
                self.out.push_u64(pair & 0xFFFFFFFFu64);
                self.out.push_str(";\n");
            }
            d.free();
            if ok {
                self.out.push_str("  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            return ok;
        }
        if t.kind == ir::TM_CALL {
            if t.dests_len > 1 {
                return self.fail("multi-dest");
            }
            let mut line = String::new();
            let mut ok = true;
            if t.dests_len == 1 {
                let dp = b.dest_pool[t.dests_start as usize];
                if b.places.at(dp as usize).ty != TYPE_NONE {
                    ok = self.emit_place(b, dp, &mut line);
                    line.push_str(" = ");
                }
            }
            // a capturing closure value calls its hoisted function with the env first
            let mut env_first = false;
            if ok && t.callee.node == NODE_NONE {
                let cop = *b.operands.at(t.a as usize);
                let cy = *self.p().module_ast_const(b.module).type_at(cop.ty);
                if cy.kind == TypeKind::TYPE_FUNCTION {
                    let cd = self.p().module_ast_const(cy.module).at_const(cy.as_data.decl);
                    if cd.kind == NodeKind::NODE_CLOSURE && cd.as_data.closure.captures.len != 0 {
                        self.mg.closure_sym(cy.module, cy.as_data.decl, &mut line);
                        env_first = true;
                    }
                }
                if !env_first {
                    ok = self.emit_operand(b, t.a, &mut line);
                }
            } else if ok {
                let mut rty2 = TYPE_NONE;
                if t.args_len > 0 {
                    rty2 = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
                }
                let mut dty2 = TYPE_NONE;
                if t.dests_len == 1 {
                    dty2 = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
                }
                ok = self.callee_sym(b, t.callee, t.targs_start, t.targs_len, rty2, dty2, &mut line);
            }
            if ok {
                line.push_str("(");
                if env_first {
                    line.push_str("&");
                    ok = self.emit_operand(b, t.a, &mut line);
                    if t.args_len != 0 {
                        line.push_str(", ");
                    }
                }
                for i in 0..t.args_len {
                    if !ok {
                        break;
                    }
                    if i != 0 {
                        line.push_str(", ");
                    }
                    ok = self.emit_operand(b, b.oper_pool[(t.args_start + i) as usize], &mut line);
                }
            }
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&line);
                self.out.push_str(");\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            line.free();
            return ok;
        }
        return self.fail("terminator");
    }
}

// Raw bytes into a C string literal: printable ASCII stays, specials get named escapes, the rest
// three-digit octal (fixed width, so a following digit can never extend the escape).
fn push_c_escaped(txt: str, dst: &mut String) {
    for i in 0..txt.len() {
        let b = txt.byte_at(i);
        if b == 34 {
            dst.push_str("\\\"");
        } else if b == 92 {
            dst.push_str("\\\\");
        } else if b == 10 {
            dst.push_str("\\n");
        } else if b == 13 {
            dst.push_str("\\r");
        } else if b == 9 {
            dst.push_str("\\t");
        } else if b >= 32 && b <= 126 {
            dst.push_byte(b);
        } else {
            dst.push_str("\\");
            dst.push_byte(48 + (b >> 6 & 7));
            dst.push_byte(48 + (b >> 3 & 7));
            dst.push_byte(48 + (b & 7));
        }
    }
}

const fn if_s(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
