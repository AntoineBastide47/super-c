// The Core IR constant interpreter: executes verified bodies with compact scalar
// slots and virtual objects -- no host pointers, deterministic step and depth limits, trap = clean
// refusal. Runs in COMPARISON mode against the established AST evaluator (the driver's gate); the
// arithmetic mirrors the language's pinned semantics: unsigned wraps at width, signed overflow,
// division by zero, out-of-range shifts, and MIN / -1 refuse to fold.
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import ir::lower as irl;
import ir::layout as lay;
import lexer::token as tok;
import consteval::consteval as ce;

pub const IV_NONE: u8 = 0; // not evaluable (unsupported construct, trap, or budget)
pub const IV_INT: u8 = 1;
pub const IV_BOOL: u8 = 2;
pub const IV_FLOAT: u8 = 3;
pub const IV_UNIT: u8 = 4;
pub const IV_OBJ: u8 = 5; // aggregate: index into the object store
pub const IV_STR: u8 = 6; // string literal: source span in `i` (start << 32 | end)

pub struct IVal {
    pub kind: u8,
    pub ty: TypeId,
    pub i: i64,
    pub f: f64,
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
    return IVal { kind: IV_NONE, ty: TYPE_NONE, i: 0, f: 0.0 };
}

pub struct Interp {
    pub pkg: *const loader::Package,
    pub steps: u32,
    pub max_steps: u32,
    pub depth: u32,
    pub objs: Vector<Vector<IVal>>,
    pub failed: bool,
    pub fail_span: tok::Span, // first refusal site (diagnostic aid)
    pub lsvc: lay::Svc,
    pub bodies: Vector<Box<irl::Lowerer>>, // lowered callee cache (boxed: nested calls grow it)
    pub body_keys: Vector<u64>, // module << 32 | fn node
    pub call_memo: Map<u64, IVal>, // scalar results keyed over every semantic input (callee + args)
}

extend Interp as Free {
    pub fn free(self: &mut Self) {
        self.objs.free();
    }
}

/// Evaluate module `m`'s constant `cnode` by lowering and executing its initializer body.
pub fn eval_const(pkg: *const loader::Package, m: ModuleId, cnode: NodeId, max_steps: u32) IVal {
    let mut it = Interp {
        pkg: pkg,
        steps: 0,
        max_steps: max_steps,
        depth: 0,
        objs: Vector::<Vector<IVal>>::new(),
        failed: false,
        fail_span: tok::Span { start: 0, end: 0 },
        lsvc: lay::Svc::new(pkg),
        bodies: Vector::<Box<irl::Lowerer>>::new(),
        body_keys: Vector::<u64>::new(),
        call_memo: Map::<u64, IVal>::new(),
    };
    let mut lw = irl::Lowerer::new(pkg, m, cnode);
    if !lw.lower_const(cnode) {
        return none();
    }
    let args = Vector::<IVal>::new();
    let r = it.run(&lw.body, &args);
    return r;
}

extend Interp {
    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    fn bail(self: &mut Self) IVal {
        self.failed = true;
        return none();
    }

    fn bail_at(self: &mut Self, sp: tok::Span) IVal {
        if !self.failed && self.fail_span.end <= self.fail_span.start {
            self.fail_span = sp;
        }
        self.failed = true;
        return none();
    }

    fn spend(self: &mut Self) bool {
        self.steps += 1;
        if self.steps > self.max_steps {
            self.failed = true;
            return false;
        }
        return true;
    }

    // The builtin behind `(m, t)` (BT_NONE-like refusal encoded as bool).
    fn bt_of(self: &Self, m: ModuleId, t: TypeId, out: &mut BuiltinType) bool {
        if t == TYPE_NONE {
            return false;
        }
        let a = unsafe &*self.p().module_ast_const(m);
        let y = *a.type_at(t);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        *out = y.as_data.builtin;
        return true;
    }

    /// Execute one body with `args` bound to its argument locals; the first return slot's value
    /// comes back (IV_UNIT for none).
    pub fn run(self: &mut Self, b: &ir::CoreBody, args: &Vector<IVal>) IVal {
        if self.depth > 24 {
            return self.bail();
        }
        self.depth += 1;
        let mut locals = Vector::<IVal>::new();
        for l in 0..b.locals.len() {
            locals.push(none());
        }
        for i in 0..args.len() {
            let li = b.returns as usize + i;
            if li < b.locals.len() {
                locals.set(li, *args.at(i));
            }
        }
        let mut blk = b.entry;
        let mut r = none();
        loop {
            if !self.spend() {
                break;
            }
            if blk as usize >= b.blocks.len() {
                let _ = self.bail();
                break;
            }
            let bb = *b.blocks.at(blk as usize);
            let mut si: u32 = 0;
            let mut broke = false;
            while si < bb.stmt_len && !self.failed {
                let s = *b.statements.at((bb.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN {
                    let v = self.rvalue(b, &mut locals, s.rvalue);
                    if self.failed {
                        let _ = self.bail_at(s.span);
                        break;
                    }
                    self.write_place(b, &mut locals, s.place, v);
                }
                // storage markers and discriminant writes ride the assign/aggregate model
                si += 1;
            }
            if self.failed {
                break;
            }
            let t = bb.term;
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_DROP {
                blk = t.t0;
            } else if t.kind == ir::TM_SWITCH {
                let d = self.operand(b, &mut locals, t.a);
                if d.kind != IV_INT && d.kind != IV_BOOL {
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
                let c = self.operand(b, &mut locals, t.a);
                if c.kind != IV_BOOL || c.i == 0 {
                    let _ = self.bail();
                    break;
                }
                blk = t.t0;
            } else if t.kind == ir::TM_RETURN {
                if b.returns != 0 {
                    r = locals[0];
                } else {
                    r = IVal { kind: IV_UNIT, ty: TYPE_NONE, i: 0, f: 0.0 };
                }
                broke = true;
            } else if t.kind == ir::TM_CALL {
                if !self.call(b, &mut locals, &t) {
                    break;
                }
                blk = t.t0;
            } else {
                let _ = self.bail();
                break;
            }
            if broke {
                break;
            }
        }
        self.depth -= 1;
        locals.free();
        if self.failed {
            return none();
        }
        return r;
    }

    fn call(self: &mut Self, b: &ir::CoreBody, locals: &mut Vector<IVal>, t: &ir::Terminator) bool {
        if t.callee.node == NODE_NONE || t.is_variadic {
            let _ = self.bail();
            return false;
        }
        // Only plain function bodies fold (no generics: substitution stays with the established
        // evaluator until instance-view bodies exist).
        let mut callable = false;
        {
            let dap = self.p().module_ast_const(t.callee.module);
            let da = unsafe &*dap;
            if da.at_const(t.callee.node).kind == NodeKind::NODE_FUNCTION {
                let fd = da.at_const(t.callee.node).as_data.function;
                callable = !fd.is_extern && fd.body != NODE_NONE && fd.generics.len == 0 && t.targs_len == 0;
            }
        }
        if !callable {
            let _ = self.bail();
            return false;
        }
        let mut args = Vector::<IVal>::new();
        for i in 0..t.args_len {
            let opid = b.oper_pool[(t.args_start + i) as usize];
            let v = self.operand(b, locals, opid);
            if self.failed {
                args.free();
                return false;
            }
            args.push(v);
        }
        // The memo key carries every semantic input: the callee identity and each argument's
        // kind, type, and bits (objects never memo).
        let mut mkey: u64 = 1469598103934665603u64;
        let mut memoable = true;
        mkey = (mkey ^ t.callee.module as u64) * 1099511628211u64;
        mkey = (mkey ^ t.callee.node as u64) * 1099511628211u64;
        for i in 0..args.len() {
            let av = *args.at(i);
            if av.kind == IV_OBJ {
                memoable = false;
            }
            mkey = (mkey ^ av.kind as u64) * 1099511628211u64;
            mkey = (mkey ^ av.ty as u64) * 1099511628211u64;
            mkey = (mkey ^ av.i as u64) * 1099511628211u64;
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
                args.free();
                if t.dests_len >= 1 {
                    let dp = b.dest_pool[t.dests_start as usize];
                    self.write_place(b, locals, dp, hv);
                }
                return !self.failed;
            }
        }
        // Lowered callee bodies cache for the whole evaluation.
        let bkey = t.callee.module as u64 << 32 | t.callee.node as u64;
        let mut bidx: i64 = -1;
        for i in 0..self.body_keys.len() {
            if self.body_keys[i] == bkey {
                bidx = i as i64;
            }
        }
        if bidx < 0 {
            let mut lw = irl::Lowerer::new(self.pkg, t.callee.module, t.callee.node);
            if !lw.lower_fn(t.callee.node) {
                args.free();
                let _ = self.bail();
                return false;
            }
            self.bodies.push(Box::new(lw));
            self.body_keys.push(bkey);
            bidx = self.body_keys.len() as i64 - 1;
        }
        let bp: *const irl::Lowerer = self.bodies.at(bidx as usize).get();
        let bb = (unsafe &(&*bp).body) as *const ir::CoreBody;
        let r = self.run(unsafe &*bb, &args);
        args.free();
        if self.failed {
            return false;
        }
        if memoable && r.kind != IV_OBJ {
            self.call_memo.insert(mkey, r);
        }
        if t.dests_len >= 1 {
            let dp = b.dest_pool[t.dests_start as usize];
            self.write_place(b, locals, dp, r);
        }
        return !self.failed;
    }

    // ---- places -----------------------------------------------------------------------------------

    // Field ordinal of decl `sub` inside its aggregate (payload fields ride the variant slot walk).
    fn field_ordinal(self: &Self, dm: ModuleId, owner: NodeId, sub: NodeId) i64 {
        let a = unsafe &*self.p().module_ast_const(dm);
        let ms = a.at_const(owner).as_data.aggregate.members;
        let mut ord: i64 = 0;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            if a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            if fid == sub {
                return ord;
            }
            ord += 1;
        }
        return -1;
    }

    // Resolve a place to (object slot vector index, slot index) or a bare local (obj == -1).
    fn resolve_place(
        self: &mut Self,
        b: &ir::CoreBody,
        locals: &mut Vector<IVal>,
        pid: ir::PlaceId,
        obj: &mut i64,
        slot: &mut i64,
    ) bool {
        let pl = *b.places.at(pid as usize);
        if b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF {
            self.failed = true;
            return false;
        }
        *obj = -1;
        *slot = pl.base;
        let mut cur = locals[pl.base as usize];
        let mut in_local = true;
        for i in 0..pl.proj_len {
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            let mut idx: i64 = -1;
            if pj.kind == ir::PJ_FIELD {
                if pj.sub != NODE_NONE {
                    // owner decl comes from the CURRENT object's type
                    let a = unsafe &*self.p().module_ast_const(b.module);
                    let mut dm: ModuleId = 0;
                    let mut dn = NODE_NONE;
                    let y = *a.type_at(cur.ty);
                    if y.kind == TypeKind::TYPE_STRUCT {
                        dm = y.module;
                        dn = y.as_data.decl;
                    } else if y.kind == TypeKind::TYPE_INSTANCE {
                        let it = *a.instance(y.as_data.inst);
                        dm = it.module;
                        dn = it.decl;
                    } else {
                        self.failed = true;
                        return false;
                    }
                    idx = self.field_ordinal(dm, dn, pj.sub);
                } else if pj.data != ir::IR_NONE {
                    idx = pj.data;
                }
            } else if pj.kind == ir::PJ_INDEX_CONST {
                idx = pj.data;
            } else if pj.kind == ir::PJ_INDEX_OP {
                let iv = self.operand(b, locals, pj.data);
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
            if idx < 0 || cur.kind != IV_OBJ {
                self.failed = true;
                return false;
            }
            // enum payload objects store the tag at slot 0
            let base_slot: i64 = if self.obj_is_enum(cur) {
                idx + 1;
            } else {
                idx;
            };
            if cur.i as usize >= self.objs.len() || base_slot < 0 || base_slot as usize >= self.objs.at(cur.i as usize).len() {
                self.failed = true;
                return false;
            }
            *obj = cur.i;
            *slot = base_slot;
            cur = self.objs.at(cur.i as usize)[base_slot as usize];
            in_local = false;
        }
        let _ = in_local;
        return true;
    }

    const fn obj_is_enum(self: &Self, v: IVal) bool {
        // enum objects are tagged by construction: slot 0 holds IV_INT tag with ty == TYPE_NONE
        return v.kind == IV_OBJ && v.f == 1.0;
    }

    fn read_place(self: &mut Self, b: &ir::CoreBody, locals: &mut Vector<IVal>, pid: ir::PlaceId) IVal {
        let mut obj: i64 = 0;
        let mut slot: i64 = 0;
        if !self.resolve_place(b, locals, pid, &mut obj, &mut slot) {
            return none();
        }
        if obj < 0 {
            return locals[slot as usize];
        }
        return self.objs.at(obj as usize)[slot as usize];
    }

    fn write_place(self: &mut Self, b: &ir::CoreBody, locals: &mut Vector<IVal>, pid: ir::PlaceId, v: IVal) {
        let mut obj: i64 = 0;
        let mut slot: i64 = 0;
        if !self.resolve_place(b, locals, pid, &mut obj, &mut slot) {
            return;
        }
        if obj < 0 {
            locals.set(slot as usize, v);
        } else {
            self.objs[obj as usize].set(slot as usize, v);
        }
    }

    // ---- operands and rvalues ---------------------------------------------------------------------

    fn operand(self: &mut Self, b: &ir::CoreBody, locals: &mut Vector<IVal>, opid: ir::OperandId) IVal {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            return self.read_place(b, locals, op.data);
        }
        if op.kind != ir::OP_CONST {
            return self.bail();
        }
        let c = *b.constants.at(op.data as usize);
        if c.kind == ir::CK_INT {
            let mut v: i64 = 0;
            if !self.lit_value(b.module, &c, &mut v) {
                return self.bail();
            }
            return IVal { kind: IV_INT, ty: c.ty, i: v, f: 0.0 };
        }
        if c.kind == ir::CK_BOOL {
            return IVal { kind: IV_BOOL, ty: c.ty, i: c.val, f: 0.0 };
        }
        if c.kind == ir::CK_UNIT {
            return IVal { kind: IV_UNIT, ty: c.ty, i: 0, f: 0.0 };
        }
        if c.kind == ir::CK_FLOAT {
            let sp = c.raw;
            let mut fv: f64 = 0.0;
            let mut okf = false;
            {
                let s0 = self.p().modules.at(b.module as usize).source.as_str();
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
            return IVal { kind: IV_FLOAT, ty: c.ty, i: 0, f: fv };
        }
        if c.kind == ir::CK_STR {
            let sp = c.raw;
            return IVal { kind: IV_STR, ty: c.ty, i: sp.start as i64 << 32 | sp.end as i64, f: 0.0 };
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
        let s0 = self.p().modules.at(m as usize).source.as_str();
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
            // 'c' with escapes
            if n < 3 {
                return false;
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
        *out = v as i64;
        return true;
    }

    fn rvalue(self: &mut Self, b: &ir::CoreBody, locals: &mut Vector<IVal>, rid: ir::RvalueId) IVal {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            return self.operand(b, locals, rv.a);
        }
        if rv.kind == ir::RV_BINARY {
            let l = self.operand(b, locals, rv.a);
            let r = self.operand(b, locals, rv.b);
            if self.failed {
                return none();
            }
            return self.binary(l, r, rv.c, b.module, rv.target);
        }
        if rv.kind == ir::RV_UNARY {
            let v = self.operand(b, locals, rv.a);
            if self.failed {
                return none();
            }
            return self.unary(v, rv.b as u8, b.module, rv.target);
        }
        if rv.kind == ir::RV_CAST {
            if rv.b != ir::CAST_NUMERIC {
                return self.bail();
            }
            let v = self.operand(b, locals, rv.a);
            if self.failed {
                return none();
            }
            return self.cast(v, b.module, rv.target);
        }
        if rv.kind == ir::RV_AGGREGATE {
            let mut slots = Vector::<IVal>::new();
            let mut is_enum = false;
            if rv.c == ir::AGG_VARIANT {
                let mut tagv: i64 = -1;
                if !self.variant_value(rv.item, &mut tagv) {
                    slots.free();
                    return self.bail();
                }
                if rv.b == 0 {
                    // a payload-less variant IS its integer value (a bare C enum)
                    slots.free();
                    return IVal { kind: IV_INT, ty: rv.target, i: tagv, f: 0.0 };
                }
                is_enum = true;
                slots.push(IVal { kind: IV_INT, ty: TYPE_NONE, i: tagv, f: 0.0 });
            }
            for i in 0..rv.b {
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    slots.push(none()); // omitted member (zero-fill); reads bail conservatively
                    continue;
                }
                let v = self.operand(b, locals, opid);
                if self.failed {
                    slots.free();
                    return none();
                }
                slots.push(v);
            }
            self.objs.push(slots);
            let mut tag: f64 = 0.0;
            if is_enum {
                tag = 1.0;
            }
            return IVal { kind: IV_OBJ, ty: rv.target, i: self.objs.len() as i64 - 1, f: tag };
        }
        if rv.kind == ir::RV_SLICE {
            return self.bail(); // view slicing never folds
        }
        if rv.kind == ir::RV_DISCRIMINANT {
            let v = self.read_place(b, locals, rv.a);
            if v.kind == IV_INT {
                return IVal { kind: IV_INT, ty: rv.target, i: v.i, f: 0.0 };
            }
            if v.kind != IV_OBJ || !self.obj_is_enum(v) {
                return self.bail();
            }
            let tag = self.objs.at(v.i as usize)[0];
            return IVal { kind: IV_INT, ty: rv.target, i: tag.i, f: 0.0 };
        }
        if rv.kind == ir::RV_INTRINSIC {
            if rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF {
                let l = self.lsvc.layout(b.module, rv.b);
                if !l.ok {
                    return self.bail();
                }
                let mut v = l.size;
                if rv.c == ir::IN_ALIGNOF {
                    v = l.align;
                }
                return IVal { kind: IV_INT, ty: rv.target, i: v as i64, f: 0.0 };
            }
            return self.bail();
        }
        return self.bail();
    }

    // The integer value of enum variant `vd`: explicit literal discriminants set the counter, the
    // rest follow C rules (previous + 1).
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
            let mut cur: i64 = 0;
            let mut found = false;
            for k in 0..ms.len {
                let mid = unsafe a.list(ms)[k as usize];
                if a.at_const(mid).kind != NodeKind::NODE_VARIANT {
                    continue;
                }
                let vexpr = a.at_const(mid).as_data.variant.value;
                if vexpr != NODE_NONE {
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
                    *out = cur;
                    found = true;
                }
                cur += 1;
            }
            if found {
                return true;
            }
        }
        return false;
    }

    // ---- arithmetic (pinned semantics) ------------------------------------------------------------

    fn binary(self: &mut Self, l: IVal, r: IVal, tok: u8, m: ModuleId, target: TypeId) IVal {
        // comparisons and logic
        let is_cmp = tok >= 60 && tok <= 65; // Lt..Ne token band checked below by value
        let _ = is_cmp;
        let bt = BuiltinType::BT_I64;
        if l.kind == IV_INT && r.kind == IV_INT {
            let mut tb = BuiltinType::BT_I64;
            if !self.bt_of(m, l.ty, &mut tb) {
                return self.bail();
            }
            let signed = ce::bt_signed(tb);
            let bits = ce::bt_bits(tb);
            let a = l.i;
            let c = r.i;
            let t2 = tok as u32;
            // token codes come from the lexer's operator band; dispatch by spelling groups
            let res = self.int_op(a, c, t2, signed, bits as u32, tb, m, target);
            return res;
        }
        if l.kind == IV_BOOL && r.kind == IV_BOOL {
            let t2 = tok as u32;
            let bopt = self.bool_op(l.i != 0, r.i != 0, t2, target);
            return bopt;
        }
        let _ = bt;
        return self.bail();
    }

    fn cmp_result(self: &Self, v: bool, target: TypeId) IVal {
        let mut i: i64 = 0;
        if v {
            i = 1;
        }
        return IVal { kind: IV_BOOL, ty: target, i: i, f: 0.0 };
    }

    fn int_result(self: &Self, v: i64, tb: BuiltinType, target: TypeId) IVal {
        return IVal { kind: IV_INT, ty: target, i: ce::wrap_to(tb, v), f: 0.0 };
    }

    fn bool_op(self: &mut Self, a: bool, c: bool, tok: u32, target: TypeId) IVal {
        let t = (tok as u8) as TokenType;
        if t == TokenType::AmpersandAmpersand || t == TokenType::Ampersand {
            return self.cmp_result(a && c, target);
        }
        if t == TokenType::PipePipe || t == TokenType::Pipe {
            return self.cmp_result(a || c, target);
        }
        if t == TokenType::EqualEqual {
            return self.cmp_result(a == c, target);
        }
        if t == TokenType::BangEqual {
            return self.cmp_result(a != c, target);
        }
        return self.bail();
    }

    fn int_op(
        self: &mut Self,
        a: i64,
        c: i64,
        tok: u32,
        signed: bool,
        bits: u32,
        tb: BuiltinType,
        m: ModuleId,
        target: TypeId,
    ) IVal {
        let t = (tok as u8) as TokenType;
        let _ = m;
        if t == TokenType::EqualEqual {
            return self.cmp_result(a == c, target);
        }
        if t == TokenType::BangEqual {
            return self.cmp_result(a != c, target);
        }
        if t == TokenType::LessThan || t == TokenType::LessThanEqual || t == TokenType::GreaterThan || t == TokenType::GreaterThanEqual {
            let mut lt = false;
            let eq = a == c;
            if signed {
                lt = a < c;
            } else {
                lt = a as u64 < c as u64;
            }
            if t == TokenType::LessThan {
                return self.cmp_result(lt, target);
            }
            if t == TokenType::LessThanEqual {
                return self.cmp_result(lt || eq, target);
            }
            if t == TokenType::GreaterThan {
                return self.cmp_result(!lt && !eq, target);
            }
            return self.cmp_result(!lt, target);
        }
        if t == TokenType::Plus || t == TokenType::Minus || t == TokenType::Star {
            if !signed {
                let mut v: u64 = 0;
                if t == TokenType::Plus {
                    v = a as u64 + c as u64;
                } else if t == TokenType::Minus {
                    v = a as u64 - c as u64;
                } else {
                    v = a as u64 * c as u64;
                }
                return self.int_result(v as i64, tb, target);
            }
            let mut v: i64 = 0;
            if t == TokenType::Plus {
                v = (a as u64 + c as u64) as i64;
            } else if t == TokenType::Minus {
                v = (a as u64 - c as u64) as i64;
            } else {
                v = (a as u64 * c as u64) as i64;
            }
            if ce::wrap_to(tb, v) != v {
                return self.bail(); // signed overflow traps
            }
            return self.int_result(v, tb, target);
        }
        if t == TokenType::Slash || t == TokenType::Percent {
            if c == 0 {
                return self.bail();
            }
            if signed {
                if a == ce::wrap_to(tb, (1u64 << (bits - 1) as u64) as i64) && c == -1 {
                    return self.bail();
                }
                if t == TokenType::Slash {
                    return self.int_result(a / c, tb, target);
                }
                return self.int_result(a % c, tb, target);
            }
            let ua = a as u64;
            let uc = c as u64;
            if t == TokenType::Slash {
                return self.int_result((ua / uc) as i64, tb, target);
            }
            return self.int_result((ua % uc) as i64, tb, target);
        }
        if t == TokenType::Ampersand {
            return self.int_result(a & c, tb, target);
        }
        if t == TokenType::Pipe {
            return self.int_result(a | c, tb, target);
        }
        if t == TokenType::Caret {
            return self.int_result(a ^ c, tb, target);
        }
        if t == TokenType::LeftShift || t == TokenType::RightShift {
            if c < 0 || c as u32 >= bits {
                return self.bail(); // out-of-range shifts trap
            }
            if t == TokenType::LeftShift {
                return self.int_result((a as u64 << c as u64) as i64, tb, target);
            }
            if signed {
                return self.int_result(a >> c, tb, target);
            }
            let mask = if bits == 64 {
                0xFFFFFFFFFFFFFFFFu64;
            } else {
                (1u64 << bits as u64) - 1u64;
            };
            return self.int_result(((a as u64 & mask) >> c as u64) as i64, tb, target);
        }
        return self.bail();
    }

    fn unary(self: &mut Self, v: IVal, tok: u8, m: ModuleId, target: TypeId) IVal {
        let t = tok as TokenType;
        if v.kind == IV_BOOL && t == TokenType::Bang {
            let mut i: i64 = 1;
            if v.i != 0 {
                i = 0;
            }
            return IVal { kind: IV_BOOL, ty: target, i: i, f: 0.0 };
        }
        if v.kind != IV_INT {
            return self.bail();
        }
        let mut tb = BuiltinType::BT_I64;
        if !self.bt_of(m, v.ty, &mut tb) {
            return self.bail();
        }
        if t == TokenType::Minus {
            if ce::bt_signed(tb) && ce::wrap_to(tb, (0u64 - v.i as u64) as i64) != (0u64 - v.i as u64) as i64 {
                return self.bail();
            }
            return self.int_result((0u64 - v.i as u64) as i64, tb, target);
        }
        if t == TokenType::Tilde {
            return self.int_result(~v.i, tb, target);
        }
        return self.bail();
    }

    fn cast(self: &mut Self, v: IVal, m: ModuleId, target: TypeId) IVal {
        let mut tb = BuiltinType::BT_I64;
        if !self.bt_of(m, target, &mut tb) {
            return self.bail();
        }
        if v.kind == IV_INT {
            if tb == BuiltinType::BT_F32 || tb == BuiltinType::BT_F64 {
                return self.bail(); // float formatting parity stays with the established evaluator
            }
            if tb == BuiltinType::BT_BOOL {
                return self.bail();
            }
            return IVal { kind: IV_INT, ty: target, i: ce::wrap_to(tb, v.i), f: 0.0 };
        }
        if v.kind == IV_BOOL && tb != BuiltinType::BT_F32 && tb != BuiltinType::BT_F64 {
            return IVal { kind: IV_INT, ty: target, i: v.i, f: 0.0 };
        }
        return self.bail();
    }
}
