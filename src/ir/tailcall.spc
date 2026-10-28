// Self tail calls to loops, in every build profile. A direct call of the body's function to itself
// whose result is the function's return value becomes stores of the arguments into the parameters
// and a jump back to the start of the body, so the recursion runs in one frame. The pass runs on an
// elaborated body (every drop is a `TM_DROP`), once per kept body in the borrow pass and once per
// body emission lowers itself, and converts a call only when the jump keeps the program's meaning:
//
// - nothing runs after the call but moves of its result into the return slot (of each member into
//   its slot, for several results), storage markers and stores of constants into the frame (drop
//   flags): no drop, no deferred block, no cancellation check, no other use of the result;
// - the call reaches the instance the body runs as (the function's own generic parameters);
// - each argument reaches its parameter unchanged, or through an adjustment the pass repeats (a
//   safe numeric widening, an implicit borrow or dereference);
// - no parameter's new value may hold a borrow of the frame, which the next iteration overwrites,
//   and no raw address of the frame is made anywhere in the body (it could be read after the call).
//
// A call that stays a call is reported as a `TailMiss`; `@tail_recurse` makes each one an error.
import ast::ast as *;
import lexer::token as tok;
import ir::core as ir;
import module::loader as loader;
import borrowck::facts as bfx;

/// Why a call of the body's function to itself stays a call (`TailMiss.reason`).
pub(package) const TR_NOT_TAIL: u8 = 1; // the result is not returned as it is
pub(package) const TR_DROP: u8 = 2; // `local` is dropped after the call returns
pub(package) const TR_AFTER: u8 = 3; // the statement at `at` runs after the call returns
pub(package) const TR_INSTANCE: u8 = 4; // the call may reach another instance of the function
pub(package) const TR_ADJUST: u8 = 5; // argument `arg` has another type than its parameter
pub(package) const TR_BORROW: u8 = 6; // argument `arg` may hold a borrow of `local`, which the jump overwrites
pub(package) const TR_ADDRESS: u8 = 7; // a raw address of `local` exists: it could be read after the call
pub(package) const TR_CANCEL: u8 = 8; // the call can accept a task cancellation: its check runs after it
// The call never runs: an argument diverges (internal, never a miss).
const TR_DEAD: u8 = 255;

/// A frame local the analysis cannot name (`TailMiss.local`).
pub(package) const LOCAL_UNKNOWN: u32 = 0xFFFFFFFE;

/// One call of the body's function to itself that the pass leaves a call.
pub(package) struct TailMiss {
    pub(package) span: tok::Span, // the call
    pub(package) at: tok::Span, // TR_AFTER, TR_DROP: what runs after the call
    pub(package) local: u32, // TR_DROP, TR_BORROW, TR_ADDRESS: the local, or LOCAL_UNKNOWN
    pub(package) arg: u32, // TR_ADJUST, TR_BORROW: the argument index
    pub(package) reason: u8,
}

// The taint of the frame over one body, flow-insensitive: which locals may hold a borrow of frame
// storage (a local, an argument or a temporary of this call), which locals have their storage
// borrowed, and whether a raw address of frame storage exists.
struct Taint {
    pub(package) on: Vector<bool>,
    pub(package) src: Vector<u32>, // per tainted local: the frame local it may borrow, or LOCAL_UNKNOWN
    pub(package) addr: Vector<bool>,
    pub(package) raw: u32, // the frame local whose raw address exists, LOCAL_UNKNOWN, or IR_NONE: none
}

/// Convert every call of `b`'s function to itself that a jump can replace (see the module comment);
/// every other one that can run is appended to `misses`. The number of calls converted, plus the
/// calls that never run (an argument diverges).
pub(package) fn convert(b: &mut ir::CoreBody, ow: &mut bfx::Owner, misses: &mut Vector<TailMiss>) u32 {
    let mut sites = Vector::<u32>::new();
    for bi in 0..b.blocks.len() {
        let t = b.blocks.at(bi).term;
        if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE && t.callee.node == b.owner.node && t.callee.module == b.owner.module {
            sites.push(bi as u32);
        }
    }
    if sites.len() == 0 || !candidate(unsafe &*ow.pkg, b) {
        return 0;
    }
    let tn = taint(b, ow);
    let mut ok = Vector::<u32>::new();
    let mut dead: u32 = 0;
    for s in 0..sites.len() {
        let m = check_site(b, ow, &tn, sites[s]);
        if m.reason == 0 {
            ok.push(sites[s]);
        } else if m.reason == TR_DEAD {
            dead += 1;
        } else {
            misses.push(m);
        }
    }
    if ok.len() != 0 {
        rewrite(b, ow, &tn, &ok);
    }
    return ok.len() as u32 + dead;
}

// A body whose calls to itself can become jumps: a function of its own (not a closure, a constant
// or an interface default, whose calls dispatch per implementor) without variadic parameters.
fn candidate(p: &loader::Package, b: &ir::CoreBody) bool {
    let a = unsafe &*p.module_ast_const(b.owner.module);
    let n = a.at_const(b.owner.node);
    if n.kind != NodeKind::NODE_FUNCTION || a.ext(b.owner.node).function.is_variadic() {
        return false;
    }
    let c = a.container_of(b.owner.node);
    return c == NODE_NONE || a.at_const(c).kind == NodeKind::NODE_EXTEND;
}

// The reason call block `bi` stays a call, or a miss with reason 0.
fn check_site(b: &ir::CoreBody, ow: &mut bfx::Owner, tn: &Taint, bi: u32) TailMiss {
    let t = b.blocks.at(bi as usize).term;
    let mut m = TailMiss { span: t.span, at: t.span, local: LOCAL_UNKNOWN, arg: 0, reason: 0 };
    for k in 0..t.args_len {
        let ty = b.operands.at(b.oper_pool[(t.args_start + k) as usize] as usize).ty;
        if ow.ast_of(b.module).type_at(ty).kind == TypeKind::TYPE_NEVER {
            m.reason = TR_DEAD;
            return m;
        }
    }
    if !same_instance(unsafe &*ow.pkg, b, &t) {
        m.reason = TR_INSTANCE;
        return m;
    }
    if t.dests_len != 1 || t.args_len != b.args || t.is_variadic {
        m.reason = TR_NOT_TAIL;
        return m;
    }
    path_after(unsafe &*ow.pkg, b, &t, &mut m, null, null);
    if m.reason != 0 {
        return m;
    }
    for k in 0..t.args_len {
        let oi = b.oper_pool[(t.args_start + k) as usize];
        let o = *b.operands.at(oi as usize);
        let pt = b.locals.at((b.returns + k) as usize).ty;
        m.arg = k;
        let ak = arg_kind(ow, b, &o, pt);
        if ak == AK_NONE {
            m.reason = TR_ADJUST;
            return m;
        }
        // The frame local the parameter's new value may borrow.
        let src = if ak == AK_REF {
            place_root(b, tn, o.data);
        } else if ow.carries(b.module, pt) {
            operand_taint(b, tn, oi);
        } else {
            ir::IR_NONE;
        };
        if src != ir::IR_NONE {
            m.reason = TR_BORROW;
            m.local = src;
            return m;
        }
    }
    if tn.raw != ir::IR_NONE {
        m.reason = TR_ADDRESS;
        m.local = tn.raw;
    }
    return m;
}

// Does call `t` reach the instance the body runs as? No interface dispatch and no named receiver
// type, and every generic argument is the function's own parameter: its own list, or for a keyed
// extend the extend's list, then its own. A method of a generic extend reached through its
// receiver argument is the same instance when the arguments have the parameters' types, which the
// argument check requires.
fn same_instance(p: &loader::Package, b: &ir::CoreBody, t: &ir::Terminator) bool {
    if t.iface != TYPE_NONE || t.recv != TYPE_NONE {
        return false;
    }
    let a = unsafe &*p.module_ast_const(b.owner.module);
    let own = a.ext(b.owner.node).function.generics;
    let ext = a.container_of(b.owner.node);
    let eg = if ext != NODE_NONE {
        a.ext(ext).extend_def.generics;
    } else {
        NodeList { start: 0, len: 0 };
    };
    if t.targs_len == own.len {
        if eg.len != 0 && !has_receiver(a, b) {
            // An associated function of a generic extend names its instance by type alone.
            return false;
        }
        return own_params(a, b, t.targs_start, own);
    }
    if t.targs_len == eg.len + own.len {
        return own_params(a, b, t.targs_start, eg) && own_params(a, b, t.targs_start + eg.len, own);
    }
    return false;
}

// Do the `list.len` generic arguments at `targ_pool[start]` name `list`'s parameters in order?
fn own_params(a: &Ast, b: &ir::CoreBody, start: u32, list: NodeList) bool {
    for k in 0..list.len {
        let y = *a.type_at(b.targ_pool[(start + k) as usize]);
        if y.kind != TypeKind::TYPE_GENERIC || y.module != b.owner.module || y.as_data.decl != unsafe a.list(list)[k as usize] {
            return false;
        }
    }
    return true;
}

// Does the function take a parameter of its extend's target type (`Self`, `&Self`, `&mut Self`)?
fn has_receiver(a: &Ast, b: &ir::CoreBody) bool {
    let ext = a.container_of(b.owner.node);
    let tgt = a.type_of(a.ext(ext).extend_def.target_type);
    for k in 0..b.args {
        let mut ty = b.locals.at((b.returns + k) as usize).ty;
        let y = *a.type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            ty = y.as_data.elem;
        }
        if ty == tgt {
            return true;
        }
    }
    return false;
}

// How an argument reaches its parameter (`arg_kind`), as the call spells it in C (`CEmit::
// emit_call_arg`): unchanged (a function as a function pointer too, as a `let` stores it), through
// an implicit borrow of its place, through an implicit dereference, or converted (a safe numeric
// widening). AK_NONE: another adjustment, which the pass does not repeat.
const AK_NONE: u8 = 0;
const AK_SAME: u8 = 1;
const AK_REF: u8 = 2;
const AK_DEREF: u8 = 3;
const AK_CAST: u8 = 4;

fn arg_kind(ow: &bfx::Owner, b: &ir::CoreBody, o: &ir::Operand, pt: TypeId) u8 {
    if o.ty == pt {
        return AK_SAME;
    }
    let a = ow.ast_of(b.module);
    let y = *a.type_at(pt);
    let z = *a.type_at(o.ty);
    if y.kind == TypeKind::TYPE_BUILTIN && z.kind == TypeKind::TYPE_BUILTIN {
        return pick(numeric(y.as_data.builtin) && numeric(z.as_data.builtin), AK_CAST, AK_NONE);
    }
    if y.fn_sig() && z.kind == TypeKind::TYPE_FUNCTION && !z.fn_sig() {
        return AK_SAME;
    }
    if o.kind == ir::OP_CONST {
        return AK_NONE;
    }
    if y.kind == TypeKind::TYPE_REFERENCE && y.as_data.elem == o.ty {
        return AK_REF;
    }
    if z.kind == TypeKind::TYPE_REFERENCE && z.as_data.elem == pt && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
        return AK_DEREF;
    }
    return AK_NONE;
}

// An integer or floating-point builtin.
const fn numeric(t: BuiltinType) bool {
    return t as u32 >= BuiltinType::BT_I8 as u32 && t as u32 <= BuiltinType::BT_F64 as u32;
}

// Walk the path after call `t` to the return. The path may only move the result into the return
// slots: with one slot the whole result through whole-local copies, with several each member `k`
// into slot `k` (the call's one destination is a temporary the caller copies whole and reads as
// members `0..returns`, `inline::multi_alias`). Anything more sets `m.reason`. With `deads`, the
// storage deaths of the path's locals other than arguments and return slots are appended to it,
// and the path's blocks to `blocks`.
fn path_after(
    p: &loader::Package,
    b: &ir::CoreBody,
    t: &ir::Terminator,
    m: &mut TailMiss,
    deads: *mut Vector<ir::Statement>,
    blocks: *mut Vector<u32>,
) {
    let dp = *b.places.at(b.dest_pool[t.dests_start as usize] as usize);
    if dp.proj_len != 0 || b.returns > 64 {
        m.reason = TR_NOT_TAIL;
        return;
    }
    // The locals holding the whole result, and those holding one member of it (`mem_k`).
    let mut whole = Vector::<u32>::new();
    let mut mem_l = Vector::<u32>::new();
    let mut mem_k = Vector::<u32>::new();
    whole.push(dp.base);
    // Bit `k`: return slot `k` holds its part of the result.
    let mut done: u64 = 0;
    let mut cur = t.t0;
    // A path visits each block at most once on its way to the return.
    for _ in 0..b.blocks.len() + 1 {
        let blk = *b.blocks.at(cur as usize);
        if blocks != null {
            unsafe (*blocks).push(cur);
        }
        for si in 0..blk.stmt_len {
            let st = *b.statements.at((blk.stmt_start + si) as usize);
            if st.kind == ir::ST_STORAGE_DEAD {
                let sk = b.locals.at(st.a as usize).storage;
                if deads != null && sk != ir::LS_ARG && sk != ir::LS_RET {
                    unsafe (*deads).push(st);
                }
                continue;
            }
            if st.kind != ir::ST_ASSIGN {
                continue;
            }
            let d = *b.places.at(st.place as usize);
            let rv = *b.rvalues.at(st.rvalue as usize);
            let to_ret = d.base < b.returns;
            if d.proj_len == 0 && rv.kind == ir::RV_USE && b.operands.at(rv.a as usize).kind != ir::OP_CONST {
                let sp = *b.places.at(b.operands.at(rv.a as usize).data as usize);
                let same = d.ty == sp.ty;
                // The member `k` the read takes: a whole holder's field, or a member holder.
                let mut k: u32 = ir::IR_NONE;
                if sp.proj_len == 1 && whole.contains(&sp.base) && b.returns > 1 {
                    let pj = *b.projections.at(sp.proj_start as usize);
                    if pj.kind == ir::PJ_FIELD && pj.data < b.returns {
                        k = pj.data;
                    }
                } else if sp.proj_len == 0 {
                    for i in 0..mem_l.len() {
                        if mem_l[i] == sp.base {
                            k = mem_k[i];
                        }
                    }
                }
                if same && sp.proj_len == 0 && whole.contains(&sp.base) && (!to_ret || b.returns == 1) {
                    if to_ret {
                        done = done | 1;
                    } else {
                        whole.push(d.base);
                    }
                    continue;
                }
                if same && k != ir::IR_NONE && (!to_ret || d.base == k) {
                    if to_ret {
                        done = done | 1u64 << k as u64;
                    } else {
                        mem_l.push(d.base);
                        mem_k.push(k);
                    }
                    continue;
                }
            }
            let ds = b.locals.at(d.base as usize).storage;
            let held = whole.contains(&d.base) || mem_l.contains(&d.base);
            if d.proj_len == 0 && rv.kind == ir::RV_USE && b.operands.at(rv.a as usize).kind == ir::OP_CONST && ds != ir::LS_RET && ds != ir::LS_STATIC_REF && !held {
                // A constant into the frame (a drop flag): nothing reads the frame after the return.
                continue;
            }
            m.reason = if to_ret || held || reads_any(b, &rv, &whole) || reads_any(b, &rv, &mem_l) {
                TR_NOT_TAIL;
            } else {
                TR_AFTER;
            };
            m.at = st.span;
            return;
        }
        let tm = blk.term;
        if tm.kind == ir::TM_GOTO {
            cur = tm.t0;
            continue;
        }
        if tm.kind == ir::TM_RETURN {
            let all = if b.returns == 64 {
                0xFFFFFFFFFFFFFFFFu64;
            } else {
                (1u64 << b.returns as u64) - 1;
            };
            if tm.args_len == ir::RET_CANCEL || done != all {
                m.reason = TR_NOT_TAIL;
            }
            return;
        }
        if tm.kind == ir::TM_UNREACHABLE {
            // The call does not return.
            return;
        }
        if tm.kind == ir::TM_DROP {
            m.reason = TR_DROP;
            m.local = b.places.at(tm.a as usize).base;
            m.at = tm.span;
            return;
        }
        let probe = p.sugar_item(loader::SugarItem::SI_CANCEL_PROBE);
        if tm.kind == ir::TM_CALL && probe.node != NODE_NONE && tm.callee.node == probe.node && tm.callee.module == probe.module {
            m.reason = TR_CANCEL;
            m.at = tm.span;
            return;
        }
        let mut reads = false;
        for i in 0..whole.len() {
            reads = reads || term_reads(b, &tm, whole[i]);
        }
        for i in 0..mem_l.len() {
            reads = reads || term_reads(b, &tm, mem_l[i]);
        }
        m.reason = if reads {
            TR_NOT_TAIL;
        } else {
            TR_AFTER;
        };
        m.at = tm.span;
        return;
    }
    m.reason = TR_NOT_TAIL;
}

// Does `rv` read any of `ls`?
fn reads_any(b: &ir::CoreBody, rv: &ir::Rvalue, ls: &Vector<u32>) bool {
    for i in 0..ls.len() {
        if rv_reads(b, rv, ls[i]) {
            return true;
        }
    }
    return false;
}

// Is operand `o` a read of the whole local `l`?
const fn whole_read(b: &ir::CoreBody, o: u32, l: u32) bool {
    let op = *b.operands.at(o as usize);
    if op.kind == ir::OP_CONST {
        return false;
    }
    let pl = *b.places.at(op.data as usize);
    return pl.base == l && pl.proj_len == 0;
}

// Does place `pl` read local `l` (as its base or in an index)?
fn place_reads(b: &ir::CoreBody, pl: u32, l: u32) bool {
    let p = *b.places.at(pl as usize);
    if p.base == l {
        return true;
    }
    for i in 0..p.proj_len {
        let pj = *b.projections.at((p.proj_start + i) as usize);
        if pj.kind == ir::PJ_INDEX_OP && op_reads(b, pj.data, l) {
            return true;
        }
    }
    return false;
}

fn op_reads(b: &ir::CoreBody, o: u32, l: u32) bool {
    let op = *b.operands.at(o as usize);
    return op.kind != ir::OP_CONST && place_reads(b, op.data, l);
}

// The operands of `rv` (the places of the place-reading kinds go through `rv_places`).
fn rv_operands(b: &ir::CoreBody, rv: &ir::Rvalue, out: &mut Vector<u32>) {
    out.truncate(0);
    if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_DYN {
        out.push(rv.a);
    } else if rv.kind == ir::RV_BINARY || rv.kind == ir::RV_REPEAT {
        out.push(rv.a);
        out.push(rv.b);
    } else if rv.kind == ir::RV_SLICE {
        if rv.b != ir::IR_NONE {
            out.push(rv.b);
        }
        if rv.item.node != ir::IR_NONE {
            out.push(rv.item.node);
        }
    } else if ir::has_op_range(rv) {
        for i in 0..rv.b {
            let e = b.oper_pool[(rv.a + i) as usize];
            if e != ir::IR_NONE {
                out.push(e);
            }
        }
    }
}

// Is `rv` a kind whose `a` is a place (a borrow, an address, a length or a discriminant read)?
const fn rv_place(rv: &ir::Rvalue) bool {
    return rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE;
}

fn rv_reads(b: &ir::CoreBody, rv: &ir::Rvalue, l: u32) bool {
    if rv_place(rv) && place_reads(b, rv.a, l) {
        return true;
    }
    let mut ops = Vector::<u32>::new();
    rv_operands(b, rv, &mut ops);
    for i in 0..ops.len() {
        if op_reads(b, ops[i], l) {
            return true;
        }
    }
    return false;
}

fn term_reads(b: &ir::CoreBody, t: &ir::Terminator, l: u32) bool {
    if (t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT) && op_reads(b, t.a, l) {
        return true;
    }
    if t.kind == ir::TM_CALL {
        if t.a != ir::IR_NONE && op_reads(b, t.a, l) {
            return true;
        }
        for k in 0..t.args_len {
            if op_reads(b, b.oper_pool[(t.args_start + k) as usize], l) {
                return true;
            }
        }
    }
    return false;
}

// The frame local whose storage place `pl` lies in, LOCAL_UNKNOWN for frame storage the taint
// cannot name, or IR_NONE outside the frame (a static, or behind a reference that holds no borrow
// of the frame).
const fn place_root(b: &ir::CoreBody, tn: &Taint, pl: u32) u32 {
    let p = *b.places.at(pl as usize);
    if b.locals.at(p.base as usize).storage == ir::LS_STATIC_REF {
        return ir::IR_NONE;
    }
    if !b.place_has_deref(pl) {
        return p.base;
    }
    if tn.on[p.base as usize] {
        return tn.src[p.base as usize];
    }
    return ir::IR_NONE;
}

// The frame local operand `o` may carry a borrow of (LOCAL_UNKNOWN when unnamed), or IR_NONE.
fn operand_taint(b: &ir::CoreBody, tn: &Taint, o: u32) u32 {
    let op = *b.operands.at(o as usize);
    if op.kind == ir::OP_CONST {
        return ir::IR_NONE;
    }
    return place_taint(b, tn, op.data);
}

fn place_taint(b: &ir::CoreBody, tn: &Taint, pl: u32) u32 {
    let p = *b.places.at(pl as usize);
    if tn.on[p.base as usize] {
        return tn.src[p.base as usize];
    }
    for i in 0..p.proj_len {
        let pj = *b.projections.at((p.proj_start + i) as usize);
        if pj.kind == ir::PJ_INDEX_OP {
            let s = operand_taint(b, tn, pj.data);
            if s != ir::IR_NONE {
                return s;
            }
        }
    }
    return ir::IR_NONE;
}

// Mark local `l` as holding a borrow of `src` when its type can hold one. True when that is new.
fn mark(tn: &mut Taint, ow: &mut bfx::Owner, b: &ir::CoreBody, l: u32, src: u32) bool {
    if tn.on[l as usize] || b.locals.at(l as usize).storage == ir::LS_STATIC_REF || !ow.carries(
        b.module,
        b.locals.at(l as usize).ty,
    ) {
        return false;
    }
    tn.on.set(l as usize, true);
    tn.src.set(l as usize, src);
    return true;
}

// A borrow may have been stored where it cannot be followed: every local whose storage is
// borrowed and whose type can hold a borrow may now hold one.
fn mark_borrowed(tn: &mut Taint, ow: &mut bfx::Owner, b: &ir::CoreBody) bool {
    let mut grew = false;
    for l in 0..b.locals.len() {
        if tn.addr[l] && mark(tn, ow, b, l as u32, LOCAL_UNKNOWN) {
            grew = true;
        }
    }
    return grew;
}

// Solve the frame taint of `b` to its fixed point: each round sets a bit or ends, so at most one
// round per local and two more run.
fn taint(b: &ir::CoreBody, ow: &mut bfx::Owner) Taint {
    let n = b.locals.len();
    let mut tn = Taint {
        on: Vector::<bool>::new(),
        src: Vector::<u32>::new(),
        addr: Vector::<bool>::new(),
        raw: ir::IR_NONE,
    };
    tn.on.resize_default(n);
    tn.addr.resize_default(n);
    for _ in 0..n {
        tn.src.push(ir::IR_NONE);
    }
    let mut ops = Vector::<u32>::new();
    for _ in 0..n + 2 {
        let mut grew = false;
        for si in 0..b.statements.len() {
            let st = *b.statements.at(si);
            if st.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = *b.rvalues.at(st.rvalue as usize);
            let d = *b.places.at(st.place as usize);
            // The frame local the value may borrow, or IR_NONE. A slice of a fixed array views the
            // array's storage; a slice of any other value (a view, a vector, a string) views the
            // buffer it refers to, as a dereference does.
            let mut src = ir::IR_NONE;
            let viewed = rv.kind == ir::RV_SLICE && ow.ast_of(b.module).type_at(b.places.at(rv.a as usize).ty).kind != TypeKind::TYPE_ARRAY;
            if !viewed && (rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_USE && rv.b != 0) {
                let pl = if rv.kind == ir::RV_USE {
                    b.operands.at(rv.a as usize).data;
                } else {
                    rv.a;
                };
                src = place_root(b, &tn, pl);
                if src != ir::IR_NONE && src != LOCAL_UNKNOWN && !tn.addr[src as usize] {
                    tn.addr.set(src as usize, true);
                    grew = true;
                }
                if src != ir::IR_NONE && rv.kind == ir::RV_ADDR && tn.raw == ir::IR_NONE {
                    tn.raw = src;
                    grew = true;
                }
            }
            if rv.kind == ir::RV_CLOSURE {
                // A capture may be taken by reference.
                rv_operands(b, &rv, &mut ops);
                for i in 0..ops.len() {
                    let op = *b.operands.at(ops[i] as usize);
                    if op.kind == ir::OP_CONST {
                        continue;
                    }
                    let r = place_root(b, &tn, op.data);
                    if r != ir::IR_NONE {
                        src = r;
                        if r != LOCAL_UNKNOWN && !tn.addr[r as usize] {
                            tn.addr.set(r as usize, true);
                            grew = true;
                        }
                    }
                }
            }
            if src == ir::IR_NONE {
                if rv_place(&rv) && rv.kind != ir::RV_LEN && rv.kind != ir::RV_DISCRIMINANT {
                    src = place_taint(b, &tn, rv.a);
                }
                rv_operands(b, &rv, &mut ops);
                for i in 0..ops.len() {
                    if src == ir::IR_NONE {
                        src = operand_taint(b, &tn, ops[i]);
                    }
                }
            }
            if src == ir::IR_NONE {
                continue;
            }
            if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_ASM || rv.c == ir::IN_VOLATILE_STORE) && tn.raw == ir::IR_NONE {
                // Inline assembly can keep any address it is given; a volatile store keeps the one
                // it stores.
                tn.raw = src;
                grew = true;
            }
            let dk = ow.ast_of(b.module).type_at(d.ty).kind;
            let cast_out = rv.kind == ir::RV_CAST && !ow.carries(b.module, rv.target);
            if (cast_out || dk == TypeKind::TYPE_POINTER) && tn.raw == ir::IR_NONE {
                // A borrow of the frame becomes a raw pointer or an integer.
                tn.raw = src;
                grew = true;
            }
            if b.locals.at(d.base as usize).storage == ir::LS_STATIC_REF && tn.raw == ir::IR_NONE {
                tn.raw = src;
                grew = true;
            }
            if b.place_has_deref(st.place) {
                // Stored through a reference: into a borrowed local the taint cannot name (a value
                // that holds no borrow stores none).
                if ow.carries(b.module, d.ty) && mark_borrowed(&mut tn, ow, b) {
                    grew = true;
                }
            } else if mark(&mut tn, ow, b, d.base, src) {
                grew = true;
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && call_taint(b, ow, &mut tn, &t) {
                grew = true;
            }
        }
        if !grew {
            break;
        }
    }
    return tn;
}

// The declared parameters of call `t`'s callee function; none for a function value or a closure.
fn callee_params(ow: &bfx::Owner, t: &ir::Terminator) NodeList {
    if t.callee.node == NODE_NONE {
        return NodeList { start: 0, len: 0 };
    }
    let n = ow.ast_of(t.callee.module).at_const(t.callee.node);
    if n.kind != NodeKind::NODE_FUNCTION {
        return NodeList { start: 0, len: 0 };
    }
    return ow.ast_of(t.callee.module).ext(t.callee.node).function.params;
}

// The taint call `t` moves: a call given a borrow of the frame (a borrowing argument, or an
// implicit borrow of a frame place) may return it, and given two may store one into the other.
// A borrow given to a raw-pointer parameter becomes a raw address. True when the taint grew.
fn call_taint(b: &ir::CoreBody, ow: &mut bfx::Owner, tn: &mut Taint, t: &ir::Terminator) bool {
    let mut grew = false;
    let mut given: u32 = 0;
    let mut src = ir::IR_NONE;
    // The taint the result may hold: an implicit borrow reaches it only through the signature.
    let mut rsrc = ir::IR_NONE;
    let ps = callee_params(ow, t);
    if t.a != ir::IR_NONE {
        let s = operand_taint(b, tn, t.a);
        if s != ir::IR_NONE {
            given += 1;
            src = s;
        }
    }
    for k in 0..t.args_len {
        let o = b.oper_pool[(t.args_start + k) as usize];
        let op = *b.operands.at(o as usize);
        let mut s = operand_taint(b, tn, o);
        // The declared parameter kind: an implicit borrow of a value, or a raw pointer.
        let mut pk = TypeKind::TYPE_ERROR;
        if k < ps.len {
            let ca = ow.ast_of(t.callee.module);
            let pn = ca.at_const(unsafe ca.list(ps)[k as usize]).as_data.parameter.ty;
            if pn != NODE_NONE {
                let pty = ca.type_of(pn);
                if pty != TYPE_NONE {
                    pk = ca.type_at(pty).kind;
                }
            }
        }
        let mut implicit = false;
        if op.kind != ir::OP_CONST && pk == TypeKind::TYPE_REFERENCE {
            let ok = ow.ast_of(b.module).type_at(op.ty).kind;
            if ok != TypeKind::TYPE_REFERENCE && ok != TypeKind::TYPE_POINTER {
                let r = place_root(b, tn, op.data);
                if r != ir::IR_NONE {
                    s = r;
                    implicit = true;
                    if r != LOCAL_UNKNOWN && !tn.addr[r as usize] {
                        tn.addr.set(r as usize, true);
                        grew = true;
                    }
                }
            }
        }
        if s == ir::IR_NONE {
            continue;
        }
        given += 1;
        src = s;
        if !implicit || autoref_returned(ow, t, k) {
            rsrc = s;
        }
        if pk == TypeKind::TYPE_POINTER && tn.raw == ir::IR_NONE {
            tn.raw = s;
            grew = true;
        }
    }
    if given == 0 {
        return grew;
    }
    for k in 0..t.dests_len {
        let dp = *b.places.at(b.dest_pool[(t.dests_start + k) as usize] as usize);
        if rsrc != ir::IR_NONE && mark(tn, ow, b, dp.base, rsrc) {
            grew = true;
        }
    }
    if given >= 2 && mark_borrowed(tn, ow, b) {
        grew = true;
    }
    return grew;
}

// Does call `t` return what its implicit borrow of argument `k` borrows: the reference parameter's
// lifetime appears in a result (an elided one: when that parameter can be the elision source), or a
// declared outlives bound may widen it there?
fn autoref_returned(ow: &mut bfx::Owner, t: &ir::Terminator, k: u32) bool {
    let ps = callee_params(ow, t);
    if k >= ps.len {
        return true;
    }
    let rel = ow.callee_rel(t.callee);
    let cm = t.callee.module;
    let ca = ow.ast_of(cm);
    let pn = ca.at_const(ca.at_const(unsafe ca.list(ps)[k as usize]).as_data.parameter.ty);
    if !pn.is_ref_type() {
        return true;
    }
    let tk = ow.lt_tok(cm, pn.as_data.indirect_type.lifetime);
    if tk != 0 && (rel & 0xFFFF) != 0 {
        return true;
    }
    // An elided result lifetime is the `self` reference's when there is one.
    let p0 = ca.at_const(unsafe ca.list(ps)[0]);
    let self_ref = ca.at_const(p0.as_data.parameter.ty).is_ref_type() && ow.span_text_is(
        cm,
        ca.at_const(p0.as_data.parameter.name).as_data.name.text,
        "self",
    );
    let rets = ca.ext(t.callee.node).function.returns;
    for r in 0..rets.len {
        let rn = ca.slot_type_node(unsafe ca.list(rets)[r as usize]);
        if tk != 0 && node_names_lt(ow, cm, rn, tk, 0) {
            return true;
        }
        if tk == 0 && (k == 0 || !self_ref) && node_elides(ow, cm, rn, 0) {
            return true;
        }
    }
    return false;
}

// Does type node `tn` of module `m` name lifetime token `tk`? `Self` may name any.
fn node_names_lt(ow: &bfx::Owner, m: ModuleId, tn: NodeId, tk: u64, depth: i32) bool {
    if tn == NODE_NONE || depth > 6 {
        return false;
    }
    let a = ow.ast_of(m);
    let n = a.at_const(tn);
    if n.has_lt_slot() {
        return ow.lt_tok(m, n.as_data.indirect_type.lifetime) == tk || node_names_lt(
            ow,
            m,
            n.as_data.indirect_type.ty,
            tk,
            depth + 1,
        );
    }
    if n.kind == NodeKind::NODE_ARRAY_TYPE {
        return node_names_lt(ow, m, n.as_data.array_type.element, tk, depth + 1);
    }
    let args = if n.kind == NodeKind::NODE_TYPE_PATH {
        a.at_const(tn).as_data.type_path.args;
    } else if n.kind == NodeKind::NODE_TUPLE_TYPE {
        n.as_data.array_literal.elements;
    } else {
        return n.kind != NodeKind::NODE_POINTER_TYPE;
    };
    if n.kind == NodeKind::NODE_TYPE_PATH && a.at_const(tn).as_data.type_path.parts.len == 1 && ow.span_text_is(
        m,
        a.at_const(unsafe a.list(a.at_const(tn).as_data.type_path.parts)[0]).as_data.name.text,
        "Self",
    ) {
        return true;
    }
    for i in 0..args.len {
        let aid = unsafe a.list(args)[i as usize];
        if a.at_const(aid).kind == NodeKind::NODE_LIFETIME {
            if ow.lt_tok(m, aid) == tk {
                return true;
            }
        } else if node_names_lt(ow, m, aid, tk, depth + 1) {
            return true;
        }
    }
    return false;
}

// Does type node `tn` of module `m` hold an elided lifetime position? `Self` may hold one.
fn node_elides(ow: &bfx::Owner, m: ModuleId, tn: NodeId, depth: i32) bool {
    if tn == NODE_NONE || depth > 6 {
        return false;
    }
    let a = ow.ast_of(m);
    let n = a.at_const(tn);
    if n.has_lt_slot() {
        return ow.lt_tok(m, n.as_data.indirect_type.lifetime) == 0 || node_elides(
            ow,
            m,
            n.as_data.indirect_type.ty,
            depth + 1,
        );
    }
    if n.kind == NodeKind::NODE_ARRAY_TYPE {
        return node_elides(ow, m, n.as_data.array_type.element, depth + 1);
    }
    if n.kind == NodeKind::NODE_TUPLE_TYPE {
        let es = n.as_data.array_literal.elements;
        for i in 0..es.len {
            if node_elides(ow, m, unsafe a.list(es)[i as usize], depth + 1) {
                return true;
            }
        }
        return false;
    }
    if n.kind != NodeKind::NODE_TYPE_PATH {
        return n.kind != NodeKind::NODE_POINTER_TYPE;
    }
    if a.at_const(tn).as_data.type_path.parts.len == 1 && ow.span_text_is(
        m,
        a.at_const(unsafe a.list(a.at_const(tn).as_data.type_path.parts)[0]).as_data.name.text,
        "Self",
    ) {
        return true;
    }
    let args = a.at_const(tn).as_data.type_path.args;
    let mut named: u32 = 0;
    for i in 0..args.len {
        let aid = unsafe a.list(args)[i as usize];
        if a.at_const(aid).kind == NodeKind::NODE_LIFETIME {
            if ow.lt_tok(m, aid) == 0 {
                return true;
            }
            named += 1;
        } else if node_elides(ow, m, aid, depth + 1) {
            return true;
        }
    }
    let d = a.path_def(tn);
    return d.node != NODE_NONE && ow.ast_of(d.module).lifetimes_of(d.node).len > named;
}

// Replace each call block in `sites` with the parameter stores and a jump to the start of the body.
// The start moves to a new empty entry block that jumps to the old one, so the loop's head has a
// predecessor of its own. Each argument goes to its parameter in order; one that reads a parameter
// an earlier store overwrote (or a part of its own) is first copied to a temporary. The path's
// storage deaths follow, as at a loop's back edge. The blocks of a path no longer reachable are
// emptied, and the operands of their moves made constants, so no read of the call's result is
// left behind. The statement pool is rebuilt in block order.
fn rewrite(b: &mut ir::CoreBody, ow: &bfx::Owner, tn: &Taint, sites: &Vector<u32>) {
    let head = b.entry;
    let sp0 = b.blocks.at(head as usize).term.span;
    let e = b.add_block();
    b.blocks[e as usize].term = ir::goto_term(head, sp0);
    b.blocks[e as usize].sealed = true;
    b.entry = e;
    // Per block: IR_NONE, or the index of its extra statements in `extra_at`.
    let mut slot = Vector::<u32>::new();
    for _ in 0..b.blocks.len() {
        slot.push(ir::IR_NONE);
    }
    let mut extra = Vector::<ir::Statement>::new();
    let mut extra_at = Vector::<u32>::new(); // run starts, then the end
    let mut rvs = Vector::<ir::Rvalue>::new();
    let mut tmps = Vector::<u32>::new();
    let mut paths = Vector::<u32>::new();
    for s in 0..sites.len() {
        let bi = sites[s];
        let t = b.blocks.at(bi as usize).term;
        slot.set(bi as usize, extra_at.len() as u32);
        extra_at.push(extra.len() as u32);
        rvs.truncate(0);
        tmps.truncate(0);
        let n = t.args_len;
        // The value of each argument: its operand, or the implicit borrow of its place.
        for k in 0..n {
            let o = b.oper_pool[(t.args_start + k) as usize];
            let op = *b.operands.at(o as usize);
            let pt = b.locals.at((b.returns + k) as usize).ty;
            let ak = arg_kind(ow, b, &op, pt);
            if ak == AK_REF {
                let y = *ow.ast_of(b.module).type_at(pt);
                let mt = (y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8) as u32;
                rvs.push(ir::rv(ir::RV_REF, op.data, mt, 0, pt));
            } else if ak == AK_DEREF {
                // A copy of the referent: the argument's place, then a dereference.
                let src = *b.places.at(op.data as usize);
                let ps = b.projections.len() as u32;
                for i in 0..src.proj_len {
                    b.projections.push(*b.projections.at((src.proj_start + i) as usize));
                }
                b.projections.push(ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: pt });
                b.places.push(ir::Place { base: src.base, proj_start: ps, proj_len: src.proj_len + 1, ty: pt });
                b.operands.push(ir::Operand { kind: ir::OP_COPY, data: b.places.len() as u32 - 1, ty: pt });
                rvs.push(ir::rv(ir::RV_USE, b.operands.len() as u32 - 1, 0, 0, pt));
            } else if ak == AK_CAST {
                rvs.push(ir::rv(ir::RV_CAST, o, ir::CAST_NUMERIC, 0, pt));
            } else {
                rvs.push(ir::rv(ir::RV_USE, o, 0, 0, pt));
            }
            tmps.push(ir::IR_NONE);
        }
        // Copies first: every read of a parameter happens before the first store into one.
        for k in 0..n {
            let rv = rvs[k as usize];
            if identity(b, &rv, b.returns + k) || !needs_copy(b, tn, &rv, k) {
                continue;
            }
            let tl = b.add_local(ir::LocalDecl::anon(rv.target, ir::LS_TEMP, t.span));
            tmps.set(k as usize, tl);
            extra.push(store(b, tl, rv, t.span));
        }
        for k in 0..n {
            let mut rv = rvs[k as usize];
            let pl = b.returns + k;
            if identity(b, &rv, pl) {
                continue;
            }
            let tl = tmps[k as usize];
            if tl != ir::IR_NONE {
                b.places.push(ir::Place { base: tl, proj_start: 0, proj_len: 0, ty: rv.target });
                b.operands.push(ir::Operand { kind: ir::OP_MOVE, data: b.places.len() as u32 - 1, ty: rv.target });
                rv = ir::rv(ir::RV_USE, b.operands.len() as u32 - 1, 0, 0, rv.target);
            }
            // The parameter is written now: a `&mut` one is not `restrict` (`CEmit`).
            b.locals.index_mut(pl as usize).is_mutable = true;
            extra.push(store(b, pl, rv, t.span));
        }
        let mut m = TailMiss { span: t.span, at: t.span, local: LOCAL_UNKNOWN, arg: 0, reason: 0 };
        let mut deads = Vector::<ir::Statement>::new();
        path_after(unsafe &*ow.pkg, b, &t, &mut m, &mut deads, &mut paths);
        assert(m.reason == 0 && tn.raw == ir::IR_NONE, "a converted call passed its checks");
        for i in 0..deads.len() {
            extra.push(deads[i]);
        }
        b.blocks[bi as usize].term = ir::goto_term(head, t.span);
        b.tail_jumps.push(bi);
    }
    extra_at.push(extra.len() as u32);
    let mut reach = Vector::<bool>::new();
    reachable(b, &mut reach);
    b.constants.push(
        ir::Constant {
            kind: ir::CK_UNIT,
            ty: Ast::builtin(BuiltinType::BT_VOID),
            val: 0,
            raw: tok::Span::empty(),
            item: DefId { module: 0, node: NODE_NONE },
        },
    );
    let unit = b.constants.len() as u32 - 1;
    for i in 0..paths.len() {
        let p = paths[i] as usize;
        if reach[p] {
            continue;
        }
        let blk = *b.blocks.at(p);
        for si in 0..blk.stmt_len {
            let st = *b.statements.at((blk.stmt_start + si) as usize);
            if st.kind == ir::ST_ASSIGN && b.rvalues.at(st.rvalue as usize).kind == ir::RV_USE {
                let o = b.operands.index_mut(b.rvalues.at(st.rvalue as usize).a as usize);
                o.kind = ir::OP_CONST;
                o.data = unit;
                o.ty = Ast::builtin(BuiltinType::BT_VOID);
            }
        }
        b.blocks[p].stmt_len = 0;
        b.blocks[p].term = ir::term0(ir::TM_UNREACHABLE, blk.term.span);
    }
    let mut ns = Vector::<ir::Statement>::with_capacity(b.statements.len() + extra.len());
    for bi in 0..b.blocks.len() {
        let blk = *b.blocks.at(bi);
        let s0 = ns.len() as u32;
        for i in 0..blk.stmt_len {
            ns.push(*b.statements.at((blk.stmt_start + i) as usize));
        }
        let x = slot[bi];
        if x != ir::IR_NONE {
            for i in extra_at[x as usize]..extra_at[x as usize + 1] {
                ns.push(extra[i as usize]);
            }
        }
        b.blocks[bi].stmt_start = s0;
        b.blocks[bi].stmt_len = ns.len() as u32 - s0;
    }
    b.statements = ns;
}

// `out[k]`: block `k` of `b` is reachable from the entry.
fn reachable(b: &ir::CoreBody, out: &mut Vector<bool>) {
    out.clear();
    out.resize_default(b.blocks.len());
    let mut stack = Vector::<u32>::new();
    let mut next = Vector::<u32>::new();
    stack.push(b.entry);
    out.set(b.entry as usize, true);
    // Each block is pushed once.
    while stack.len() != 0 {
        let t = b.blocks.at(stack[stack.len() - 1] as usize).term;
        stack.truncate(stack.len() - 1);
        next.truncate(0);
        if t.kind == ir::TM_SWITCH {
            for k in 0..t.sw_len {
                next.push((b.switch_pool[(t.sw_start + k) as usize] & 0xFFFFFFFFu64) as u32);
            }
        }
        if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE && t.t0 != ir::IR_NONE {
            next.push(t.t0);
        }
        for k in 0..next.len() {
            if !out[next[k] as usize] {
                out.set(next[k] as usize, true);
                stack.push(next[k]);
            }
        }
    }
}

// Is `rv` a read of the whole local `l` (a store into `l` that changes nothing)?
const fn identity(b: &ir::CoreBody, rv: &ir::Rvalue, l: u32) bool {
    return rv.kind == ir::RV_USE && whole_read(b, rv.a, l);
}

// Must argument `k`'s value `rv` be copied before the parameter stores? When it reads a parameter
// the stores before `k` overwrite, or a part of parameter `k` itself (C leaves a store from an
// overlapping object undefined), or reads through a reference that may point into the frame.
fn needs_copy(b: &ir::CoreBody, tn: &Taint, rv: &ir::Rvalue, k: u32) bool {
    let pl = if rv.kind == ir::RV_REF {
        rv.a;
    } else {
        let op = *b.operands.at(rv.a as usize);
        if op.kind == ir::OP_CONST {
            return false;
        }
        if b.place_has_deref(op.data) && tn.on[b.places.at(op.data as usize).base as usize] {
            return true;
        }
        op.data;
    };
    for j in 0..k + 1 {
        if place_reads(b, pl, b.returns + j) {
            return true;
        }
    }
    return false;
}

// The statement `l = rv`, its place and rvalue appended to the pools.
fn store(b: &mut ir::CoreBody, l: u32, rv: ir::Rvalue, sp: tok::Span) ir::Statement {
    b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: b.locals.at(l as usize).ty });
    b.rvalues.push(rv);
    return ir::Statement {
        kind: ir::ST_ASSIGN,
        place: b.places.len() as u32 - 1,
        rvalue: b.rvalues.len() as u32 - 1,
        a: 0,
        span: sp,
    };
}
