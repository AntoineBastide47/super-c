// The LIR verifier: the meaning checks a body passes before any use (the text parser checks syntax only).
// One pass over the instructions checks each operand's type for its opcode, each table index and each
// edge against its target's parameters; then every block must be reachable, the CFG reducible (each
// retreating edge targets a block that dominates its source) and each use dominated by its definition.
// Dominators come from the iterative algorithm of Cooper, Harvey and Kennedy over reverse postorder.
// The cost is linear in the body but for the dominator fixpoint, which converges in two passes on a
// reducible CFG.
import ast::ast as ast;
import lir::ir as *;
import ir::core as core;
import lir::print as lprint;

/// The limits a body stays within: an instruction index stays below VFLAG.
pub(package) const MAX_INSTS: u32 = 0x3FFFFFFF;
pub(package) const MAX_ARGS: u32 = 65535;

// Scratch reused across bodies.
pub(package) struct Verifier {
    pub(package) err: String,
    rpo: Vector<u32>, // blocks in reverse postorder
    order: Vector<u32>, // per block, its position in `rpo`; NONE when unreachable
    idom: Vector<u32>,
    stack: Vector<u64>, // block << 32 | next successor index
    on_stack: Vector<bool>,
    succ: Vector<u32>,
    def_block: Vector<u32>, // per instruction, its block
    param_block: Vector<u32>, // per block parameter, its block
    pkg: *const Package, // the package of the body under check, for its file names
    slot_base: Vector<u64>, // per instruction: slot + 1 << 32 | byte offset (i32), 0 when unknown
}

extend Verifier {
    pub(package) fn new() Verifier {
        return Verifier {
            err: String::new(),
            rpo: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            stack: Vector::<u64>::new(),
            on_stack: Vector::<bool>::new(),
            succ: Vector::<u32>::new(),
            def_block: Vector::<u32>::new(),
            param_block: Vector::<u32>::new(),
            pkg: null,
            slot_base: Vector::<u64>::new(),
        };
    }

    /// Check body `b` of symbol `name` against package `p`; true when it holds. On a failure `err` names
    /// the location of the instruction (or the block) and the rule.
    pub(package) fn check(self: &mut Self, p: &Package, name: str, b: &Body) bool {
        self.err.clear();
        self.pkg = p;
        let n = b.insts.len();
        if n as u64 > MAX_INSTS as u64 || b.params.len() as u64 > MAX_INSTS as u64 {
            return self.fail_body(name, "the body passes the instruction limit");
        }
        if b.blocks.len() == 0 {
            return self.fail_body(name, "the body has no block");
        }
        if b.locs.len() != n {
            return self.fail_body(name, "the location table has not one entry per instruction");
        }
        if b.lines.len() == 0 {
            return self.fail_body(name, "the line table has no entry 0");
        }
        for k in 1..b.lines.len() {
            if b.lines[k].file as usize >= p.files.len() {
                return self.fail_body(name, "a location names no file of the package");
            }
        }
        for k in 0..b.syms.len() {
            if b.syms[k] as usize >= p.syms.len() {
                return self.fail_body(name, "the body names a symbol the package does not hold");
            }
        }
        for k in 0..b.msgs.len() {
            if b.msgs[k] as usize >= p.msgs.len() {
                return self.fail_body(name, "the body names a message the package does not hold");
            }
        }
        if !self.blocks_ok(name, b) || !self.sig_ok(name, b) {
            return false;
        }
        self.slot_base.truncate(0);
        for i in 0..n {
            if !self.inst_ok(p, name, b, i as u32) {
                return false;
            }
        }
        if !self.order_blocks(name, b) {
            return false;
        }
        self.dominators(b);
        return self.cfg_ok(name, b) && self.uses_ok(name, b);
    }

    @cold
    fn fail_body(self: &mut Self, name: str, why: str) bool {
        self.err.format_into("lir: @{}: {}", name, why);
        return false;
    }

    @cold
    fn fail_at(self: &mut Self, name: str, b: &Body, i: u32, why: str) bool {
        self.err.format_into("lir: @{}", name);
        let l = b.lines[b.locs[i as usize] as usize];
        if l.line != 0 {
            let p = unsafe &*self.pkg;
            self.err.format_into(" at {}:{}:{}", p.spell(p.files[l.file as usize]), l.line, l.col);
        }
        self.err.format_into(": instruction {} ({}): {}", i, op_info(b.insts[i as usize].op).name, why);
        return false;
    }

    // Every block holds instructions ending in its one terminator, the blocks cover the instructions
    // once, and each block's parameters are in the parameter table.
    fn blocks_ok(self: &mut Self, name: str, b: &Body) bool {
        let n = b.insts.len();
        self.def_block.truncate(0);
        self.def_block.resize_default(n);
        for i in 0..n {
            self.def_block[i] = NONE;
        }
        for k in 0..b.blocks.len() {
            let blk = b.blocks[k];
            if blk.len == 0 || blk.start as u64 + blk.len as u64 > n as u64 {
                return self.fail_body(name, "a block is empty or past the instructions");
            }
            if blk.param_start as u64 + blk.param_len as u64 > b.params.len() as u64 {
                return self.fail_body(name, "a block's parameters are past the parameter table");
            }
            for j in 0..blk.len {
                let i = blk.start + j;
                if self.def_block[i as usize] != NONE {
                    return self.fail_at(name, b, i, "the instruction is in two blocks");
                }
                self.def_block[i as usize] = k as u32;
                if is_terminator(b.insts[i as usize].op) != (j + 1 == blk.len) {
                    return self.fail_at(name, b, i, "a block ends with exactly one terminator");
                }
            }
        }
        for i in 0..n {
            if self.def_block[i] == NONE {
                return self.fail_at(name, b, i as u32, "the instruction is in no block");
            }
        }
        self.param_block.truncate(0);
        self.param_block.resize_default(b.params.len());
        for k in 0..b.params.len() {
            self.param_block[k] = NONE;
        }
        for k in 0..b.blocks.len() {
            let blk = b.blocks[k];
            for j in 0..blk.param_len as u32 {
                if self.param_block[(blk.param_start + j) as usize] != NONE {
                    return self.fail_body(name, "two blocks share a parameter");
                }
                self.param_block[(blk.param_start + j) as usize] = k as u32;
            }
        }
        for k in 0..b.params.len() {
            if !type_ok(b.params[k]) || self.param_block[k] == NONE {
                return self.fail_body(name, "a block parameter has no machine type or no block");
            }
        }
        return true;
    }

    // The body's signature is in its pool, and the entry block's parameters are its parameters (an
    // aggregate as its pointer), then the result's pointer for an aggregate result.
    fn sig_ok(self: &mut Self, name: str, b: &Body) bool {
        if !sig_valid(b, b.sig, (unsafe &*self.pkg).ptr_bytes) {
            return self.fail_body(name, "the body's signature is not a signature of its pool");
        }
        let np = b.pool[b.sig as usize];
        let ret = b.pool[b.sig as usize + 2];
        let entry = b.blocks[0];
        let want = np + ast::pick((ret & AGG) != 0, 1u32, 0);
        if entry.param_len as u32 != want {
            return self.fail_body(name, "the entry block's parameters are not the signature's");
        }
        for k in 0..np {
            let pt = b.pool[(b.sig + 3 + k) as usize];
            if b.params[(entry.param_start + k) as usize] != carrier(pt) {
                return self.fail_body(name, "an entry parameter's type is not the signature's");
            }
        }
        for k in 0..64u32 {
            if (b.bools >> k as u64 & 1) != 0 && (k >= np || b.params[(entry.param_start + k) as usize] != T_I8) {
                return self.fail_body(name, "a bool parameter is no i8 parameter of the signature");
            }
        }
        if (ret & AGG) != 0 && b.params[(entry.param_start + np) as usize] != T_PTR {
            return self.fail_body(name, "an aggregate result's entry parameter is not a pointer");
        }
        return true;
    }

    // The type of value `v` used by instruction `i`, T_NONE when `v` is no value of the body.
    const fn vty(self: &Self, b: &Body, v: Value) u8 {
        if v == VNONE {
            return T_NONE;
        }
        if (v & VPARAM) != 0 {
            let k = v & ~VPARAM;
            if k as usize >= b.params.len() {
                return T_NONE;
            }
            return b.params[k as usize];
        }
        if (v & VFLAG) != 0 {
            let k = v & ~VFLAG;
            if k as usize >= b.insts.len() || op_info(b.insts[k as usize].op).form != F_OVF {
                return T_NONE;
            }
            return T_I8;
        }
        if v as usize >= b.insts.len() {
            return T_NONE;
        }
        return b.insts[v as usize].ty;
    }

    // `O_SYS` instruction `t` (`i` of `b`): its operands by `sys_arity`, of their types; a context switch
    // or entry the whole body of a naked function.
    fn sys_ok(self: &mut Self, name: str, b: &Body, i: u32, t: Inst, ta: u8, tb: u8, tc: u8) bool {
        let s = t.aux;
        if s >= SYS_COUNT {
            return self.fail_at(name, b, i, "no such system operation");
        }
        let n = sys_arity(s);
        if t.a != VNONE != n > 0 || t.b != VNONE != n > 1 || t.c != VNONE != n > 2 {
            return self.fail_at(name, b, i, "a system operation takes its operands and no other");
        }
        let res = if s == SYS_CYCLES || s == SYS_GSLOAD || s == SYS_XGETBV || s == SYS_SVL {
            T_I64;
        } else {
            T_NONE;
        };
        let ok = if s == SYS_FPSAVE {
            ta == T_PTR;
        } else if s == SYS_GSLOAD {
            ta == T_I64;
        } else if s == SYS_GSSTORE {
            ta == T_I64 && tb == T_I64;
        } else if s == SYS_CPUID {
            ta == T_PTR && tb == T_I32 && tc == T_I32;
        } else if s == SYS_XGETBV {
            ta == T_I32;
        } else if s == SYS_CTXSWAP {
            ta == T_PTR && tb == T_PTR && b.naked;
        } else if s == SYS_CTXENTRY {
            b.naked;
        } else {
            true;
        };
        return self.need(
            name,
            b,
            i,
            ok && t.ty == res,
            "the operands and the result its operation takes (a context switch in a naked function)",
        );
    }

    fn inst_ok(self: &mut Self, p: &Package, name: str, b: &Body, i: u32) bool {
        let t = b.insts[i as usize];
        self.slot_base.push(0);
        if t.op == 0 || t.op >= OP_COUNT {
            return self.fail_at(name, b, i, "no such opcode");
        }
        if t.ty != T_NONE && !type_ok(t.ty) {
            return self.fail_at(name, b, i, "the result has no machine type");
        }
        let ta = self.vty(b, t.a);
        let tb = self.vty(b, t.b);
        let tc = self.vty(b, t.c);
        let op = t.op;
        if op == O_ICONST {
            return self.need(
                name,
                b,
                i,
                (is_int(t.ty) && t.ty != T_I128 || t.ty == T_PTR) && fits(t),
                "an integer constant of up to 64 bits",
            );
        }
        if op == O_FCONST {
            return self.need(name, b, i, is_float(t.ty) && (t.ty == T_F64 || t.b == 0), "a float constant");
        }
        if op == O_WCONST {
            let words = (type_bytes(t.ty, p.ptr_bytes) + 7) / 8;
            return self.need(
                name,
                b,
                i,
                (t.ty == T_I128 || is_vec(t.ty)) && t.b == words && t.a as u64 + t.b as u64 <= b.words.len() as u64,
                "a wide constant of its type's words",
            );
        }
        if op == O_SYMADDR {
            return self.need(name, b, i, t.ty == T_PTR && t.a as usize < b.syms.len(), "the address of a body symbol");
        }
        if op == O_SLOTADDR {
            if t.ty != T_PTR || t.a as usize >= b.slots.len() {
                return self.fail_at(name, b, i, "the address of a slot");
            }
            self.slot_base[i as usize] = t.a as u64 + 1 << 32;
            return true;
        }
        if op >= O_ADD && op <= O_ASHR {
            return self.need(
                name,
                b,
                i,
                int_like(t.ty) && ta == t.ty && tb == t.ty && (t.aux == 0 || op == O_LSHR && t.aux == SH_EXACT),
                "two integer operands of the result's type (an exact flag on a logical right shift only)",
            );
        }
        if op == O_NEG || op == O_NOT {
            return self.need(name, b, i, int_like(t.ty) && ta == t.ty, "an integer operand of the result's type");
        }
        if op == O_SPLAT {
            return self.need(
                name,
                b,
                i,
                is_vec(t.ty) && ta == lane_type(t.ty),
                "a vector of the operand's type in each lane",
            );
        }
        if op == O_MULHU {
            return self.need(
                name,
                b,
                i,
                is_int(t.ty) && t.ty != T_I128 && ta == t.ty && tb == t.ty,
                "two integer operands of the result's type, up to 64 bits",
            );
        }
        if op == O_CLZ || op == O_CTZ || op == O_POPCNT {
            return self.need(
                name,
                b,
                i,
                is_int(t.ty) && t.ty != T_I128 && ta == t.ty,
                "an integer operand of the result's type, up to 64 bits",
            );
        }
        if op == O_ADDO || op == O_SUBO || op == O_MULO {
            return self.need(
                name,
                b,
                i,
                is_int(t.ty) && t.ty != T_I128 && ta == t.ty && tb == t.ty && t.aux <= OV_SIGNED,
                "two integer operands of the result's type, up to 64 bits",
            );
        }
        if op == O_ICMP {
            return self.need(
                name,
                b,
                i,
                t.ty == T_I8 && (is_int(ta) || ta == T_PTR) && tb == ta && t.aux <= C_UGE,
                "two integer or pointer operands of one type, an integer condition and an i8 result",
            );
        }
        if op == O_FCMP {
            return self.need(
                name,
                b,
                i,
                t.ty == T_I8 && is_float(ta) && tb == ta && t.aux >= C_OEQ && t.aux < C_COUNT,
                "two float operands of one type, a float condition and an i8 result",
            );
        }
        if op >= O_FADD && op <= O_FDIV {
            return self.need(
                name,
                b,
                i,
                float_like(t.ty) && ta == t.ty && tb == t.ty,
                "two float operands of the result's type",
            );
        }
        if op == O_FNEG {
            return self.need(name, b, i, float_like(t.ty) && ta == t.ty, "a float operand of the result's type");
        }
        if op >= O_SEXT && op <= O_INTTOPTR {
            return self.need(
                name,
                b,
                i,
                conv_ok(op, ta, t.ty, p.ptr_bytes),
                "an operand its conversion takes to the result's type",
            );
        }
        if op == O_PTRADD {
            let ix_ok = t.b == VNONE || (tb == T_I64 || tb == T_I32) && type_bytes(tb, p.ptr_bytes) == p.ptr_bytes && t.aux != 0;
            if t.ty != T_PTR || ta != T_PTR || !ix_ok {
                return self.fail_at(
                    name,
                    b,
                    i,
                    "a pointer, a pointer-sized index or none, and a nonzero scale with an index",
                );
            }
            let base = self.base_of(t.a);
            if base != 0 && t.b == VNONE {
                let off = ((base as u32) as i32) as i64 + (t.c as i32) as i64;
                self.slot_base[i as usize] = base >> 32 << 32 | (off as u32) as u64;
                return self.slot_access(name, b, i, base >> 32, off, 0);
            }
            return true;
        }
        if op == O_LOAD || op == O_STORE {
            let vt = ast::pick(op == O_LOAD, t.ty, tb);
            if ta != T_PTR || vt == T_NONE || op == O_STORE && t.ty != T_NONE || (t.aux & ~(MEM_VOLATILE | MEM_TBAA | MEM_BOOL | 15)) != 0 {
                return self.fail_at(name, b, i, "a pointer address and a typed value");
            }
            if (t.aux & MEM_BOOL) != 0 && (op != O_LOAD || vt != T_I8) {
                return self.fail_at(name, b, i, "a bool load of an i8");
            }
            if tbaa(t) != 0 && tbaa(t) != tbaa_of(vt) as usize {
                return self.fail_at(name, b, i, "a type tag of the accessed type");
            }
            let base = self.base_of(t.a);
            if base != 0 {
                let off = ((base as u32) as i32) as i64 + (t.c as i32) as i64;
                // The access claims no more alignment than the slot and the offset give it.
                let al = (t.aux & 15) as u64;
                let sal = b.slots[((base >> 32) - 1) as usize].align_log2 as u64;
                if al > sal || (off as u64 & (1u64 << al) - 1) != 0 {
                    return self.fail_at(name, b, i, "an access aligned as its slot and offset allow");
                }
                return self.slot_access(name, b, i, base >> 32, off, type_bytes(vt, p.ptr_bytes));
            }
            return true;
        }
        if op == O_MEMCPY || op == O_MEMSET {
            let src_ok = if op == O_MEMCPY {
                tb == T_PTR;
            } else {
                tb == T_I8;
            };
            return self.need(
                name,
                b,
                i,
                t.ty == T_NONE && ta == T_PTR && src_ok && is_int(tc) && tc != T_I128 && t.aux <= MEM_OVERLAP,
                "a destination pointer, a source, an integer size",
            );
        }
        if op == O_ALOAD {
            return self.need(
                name,
                b,
                i,
                ta == T_PTR && atomic_type(t.ty) && order_ok(t.aux, true, false),
                "a pointer and a load order",
            );
        }
        if op == O_ASTORE {
            return self.need(
                name,
                b,
                i,
                t.ty == T_NONE && ta == T_PTR && atomic_type(tb) && order_ok(t.aux, false, true),
                "a pointer, a value and a store order",
            );
        }
        if op == O_ARMW {
            return self.need(
                name,
                b,
                i,
                ta == T_PTR && atomic_type(tb) && t.ty == tb && order_ok(t.aux & 7, true, true) && t.aux >> 4 <= RMW_XOR,
                "a pointer, an integer of the result's type, an operation and an order",
            );
        }
        if op == O_ACAS {
            let ok = (t.aux & 7) <= MO_SEQ_CST && order_ok(t.aux >> 3 & 7, true, false);
            return self.need(
                name,
                b,
                i,
                t.ty == T_I8 && ta == T_PTR && atomic_type(tb) && tc == tb && ok,
                "a pointer, an expected and a desired value of one type, two orders, and an i8 result",
            );
        }
        if op == O_FENCE {
            return self.need(name, b, i, t.ty == T_NONE && t.aux <= MO_SEQ_CST, "an order");
        }
        if op == O_SELECT {
            return self.need(
                name,
                b,
                i,
                ta == T_I8 && tb == t.ty && tc == t.ty,
                "an i8 condition and two values of the result's type",
            );
        }
        if op == O_SYS {
            return self.sys_ok(name, b, i, t, ta, tb, tc);
        }
        if op == O_FMA {
            return self.need(
                name,
                b,
                i,
                is_float(t.ty) && ta == t.ty && tb == t.ty && tc == t.ty,
                "three floats of the result's type",
            );
        }
        if op == O_RETADDR {
            return self.need(name, b, i, t.ty == T_PTR, "a pointer result");
        }
        if op == O_CALL || op == O_CALLIND {
            return self.call_ok(name, b, i);
        }
        if op == O_ASM {
            return self.asm_ok(name, b, i);
        }
        if op == O_VOP {
            return self.need(
                name,
                b,
                i,
                t.a as u64 + t.b as u64 <= b.pool.len() as u64 && (t.c == VNONE || t.c as usize < b.pool.len()) && self.vop_args_ok(
                    b,
                    t,
                ),
                "operands in the pool, each a value of the body",
            );
        }
        if op == O_VASTART || op == O_VAEND {
            return self.need(name, b, i, ta == T_PTR && t.ty == T_NONE, "the address of a va_list");
        }
        if op == O_VAARG {
            return self.need(
                name,
                b,
                i,
                ta == T_PTR && t.ty != T_NONE && !is_vec(t.ty),
                "the address of a va_list and a scalar result",
            );
        }
        if op == O_JMP {
            return self.edge_ok(name, b, i, t.a);
        }
        if op == O_BR {
            return self.need(name, b, i, ta == T_I8, "an i8 condition") && self.edge_ok(name, b, i, t.b) && self.edge_ok(
                name,
                b,
                i,
                t.c,
            );
        }
        if op == O_SWITCH {
            if !is_int(ta) || ta == T_I128 || t.b as u64 + t.aux as u64 > b.words.len() as u64 || t.c as u64 + t.aux as u64 + 1 > b.pool.len() as u64 {
                return self.fail_at(name, b, i, "an integer value, its cases and their edges");
            }
            for k in 0..t.aux as u32 + 1 {
                if !self.edge_ok(name, b, i, b.switch_edge(t, k)) {
                    return false;
                }
            }
            return true;
        }
        if op == O_RET {
            let ret = b.pool[b.sig as usize + 2];
            let want = ast::pick((ret & AGG) != 0, T_NONE, ret as u8);
            return self.need(name, b, i, ta == want && t.a == VNONE == (want == T_NONE), "the signature's result");
        }
        if op == O_PANIC {
            let tb = if t.b == VNONE {
                T_I64;
            } else {
                b.type_of(t.b);
            };
            return self.need(name, b, i, t.a as usize < b.msgs.len(), "a message of the body") && self.need(
                name,
                b,
                i,
                !is_vec(tb) && !is_float(tb) && type_bits(tb, 8) <= 64 && tb != T_PTR,
                "an integer lane mask",
            );
        }
        return self.need(name, b, i, op == O_UNREACHABLE, "a known opcode");
    }

    fn need(self: &mut Self, name: str, b: &Body, i: u32, ok: bool, what: str) bool {
        if ok {
            return true;
        }
        return self.fail_at(name, b, i, what);
    }

    // The slot and constant byte offset value `v` points at (slot + 1 << 32 | offset), 0 when unknown.
    const fn base_of(self: &Self, v: Value) u64 {
        if (v & VPARAM) != 0 || v as usize >= self.slot_base.len() {
            return 0;
        }
        return self.slot_base[v as usize];
    }

    // An access of `size` bytes at byte `off` of slot `s1 - 1` stays inside the slot.
    fn slot_access(self: &mut Self, name: str, b: &Body, i: u32, s1: u64, off: i64, size: u32) bool {
        let sz = b.slots[(s1 - 1) as usize].size as i64;
        return self.need(name, b, i, off >= 0 && off + size as i64 <= sz, "an access inside its slot");
    }

    // An asm's record lies in the pool, each text is a body message, an output has an address and a
    // scalar type, an input a scalar value.
    fn asm_ok(self: &mut Self, name: str, b: &Body, i: u32) bool {
        let t = b.insts[i as usize];
        let r = t.c as u64;
        let np = b.pool.len() as u64;
        if t.ty != T_NONE || r + 4 > np || t.a as u64 + t.b as u64 > np {
            return self.fail_at(name, b, i, "no result, and a record and values of the pool");
        }
        let no = asm_nout(b, t.c);
        let ni = asm_nin(b, t.c);
        let nc = asm_nclob(b, t.c);
        if no as u64 + ni as u64 != t.b as u64 || r + 4 + 2 * no as u64 + ni as u64 + nc as u64 > np {
            return self.fail_at(name, b, i, "a value per output and input, and the record's texts in the pool");
        }
        let nm = b.msgs.len() as u32;
        if asm_template(b, t.c) >= nm {
            return self.fail_at(name, b, i, "a template message");
        }
        for k in 0..no {
            let ty = asm_out_ty(b, t.c, k);
            if asm_out_con(b, t.c, k) >= nm || self.vty(b, b.pool[(t.a + k) as usize]) != T_PTR || !(is_int(ty) && ty != T_I128 || is_float(
                ty,
            ) || ty == T_PTR) {
                return self.fail_at(name, b, i, "an output's constraint, its address and a scalar type");
            }
        }
        for k in 0..ni {
            let ty = self.vty(b, b.pool[(t.a + no + k) as usize]);
            if asm_in_con(b, t.c, k) >= nm || !(is_int(ty) && ty != T_I128 || is_float(ty) || ty == T_PTR) {
                return self.fail_at(name, b, i, "an input's constraint and a scalar value");
            }
        }
        for k in 0..nc {
            if asm_clob(b, t.c, k) >= nm {
                return self.fail_at(name, b, i, "a clobber message");
            }
        }
        return true;
    }

    fn call_ok(self: &mut Self, name: str, b: &Body, i: u32) bool {
        let t = b.insts[i as usize];
        if t.op == O_CALL && t.a as usize >= b.syms.len() || t.op == O_CALLIND && self.vty(b, t.a) != T_PTR {
            return self.fail_at(name, b, i, "a body symbol or a pointer callee");
        }
        if !sig_valid(b, t.b, (unsafe &*self.pkg).ptr_bytes) || t.c as u64 + t.aux as u64 > b.pool.len() as u64 {
            return self.fail_at(name, b, i, "a signature and arguments of the pool");
        }
        let np = b.pool[t.b as usize];
        let ret = b.pool[t.b as usize + 2];
        let agg = (ret & AGG) != 0;
        let want_ty = ast::pick(agg, T_NONE, ret as u8);
        let n = t.aux as u32;
        if t.ty != want_ty || n != np + ast::pick(agg, 1u32, 0) {
            return self.fail_at(name, b, i, "the signature's argument count and result");
        }
        for k in 0..n {
            let at = self.vty(b, b.pool[(t.c + k) as usize]);
            let want = if k < np {
                carrier(b.pool[(t.b + 3 + k) as usize]);
            } else {
                T_PTR;
            };
            if at == T_NONE || at != want {
                return self.fail_at(name, b, i, "an argument of its parameter's type");
            }
        }
        return true;
    }

    /// The calls of body `b` (named `name`) of package `p` to bodies `p` defines take each callee's
    /// signature: its parameter types (the fixed ones of a variadic callee) and its result, an
    /// aggregate's layout compared by its size, alignment and leaves. False, with `err`, at the first
    /// call that does not.
    pub(package) fn check_calls(self: &mut Self, p: &Package, name: str, b: &Body) bool {
        self.err.clear();
        self.pkg = p;
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            if t.op != O_CALL {
                continue;
            }
            let sy = p.syms[b.syms[t.a as usize] as usize];
            if sy.kind != SK_FUNC || sy.def == NONE {
                continue;
            }
            let cb = &p.bodies[sy.def as usize];
            let cs = cb.sig as usize;
            let ks = t.b as usize;
            let cn = cb.pool[cs];
            let cflags = cb.pool[cs + 1];
            let kn = b.pool[ks];
            let kfixed = b.pool[ks + 1] & ~SIG_VARIADIC;
            let cvar = (cflags & SIG_VARIADIC) != 0;
            let mut ok = same_type(cb, cb.pool[cs + 2], b, b.pool[ks + 2]);
            ok = ok && if cvar {
                kfixed == cn;
            } else {
                kn == cn;
            };
            for k in 0..cn {
                ok = ok && k < kn && same_type(cb, cb.pool[cs + 3 + k as usize], b, b.pool[ks + 3 + k as usize]);
            }
            if !ok {
                let _ = self.fail_at(name, b, i as u32, "a call of its callee's signature");
                self.err.format_into(" (the call: ");
                push_sig(b, ks, &mut self.err);
                self.err.format_into("; @{}: ", p.spell(sy.name));
                push_sig(cb, cs, &mut self.err);
                self.err.push_str(")");
                return false;
            }
        }
        return true;
    }

    const fn vop_args_ok(self: &Self, b: &Body, t: Inst) bool {
        for k in 0..t.b {
            if self.vty(b, b.pool[(t.a + k) as usize]) == T_NONE {
                return false;
            }
        }
        // The operations the lowering makes: a lane conversion, a float remainder, a shift by one count,
        // or a SIMD operation. No result: one that writes memory, through operand 0 or at its last.
        let code = (t.aux & VOP_CODE) as u32;
        let simd = code >= core::OP_SIMD && code < core::OP_CMP_LANES;
        let float_rem = code == core::OP_REM && t.b == 2 && is_vec(t.ty) && is_float(lane_type(t.ty));
        let known = simd || float_rem || code == core::OP_CAST || code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR;
        return known && (t.ty != T_NONE || simd && t.b != 0);
    }

    // Edge `e` leaves instruction `i`: its target is a block and its arguments are the target's
    // parameters, in number and type.
    fn edge_ok(self: &mut Self, name: str, b: &Body, i: u32, e: u32) bool {
        if e as u64 + 2 > b.pool.len() as u64 || b.pool[e as usize] as usize >= b.blocks.len() {
            return self.fail_at(name, b, i, "an edge to a block of the body");
        }
        let blk = b.blocks[b.pool[e as usize] as usize];
        let nargs = b.pool[e as usize + 1];
        if nargs > MAX_ARGS || nargs != blk.param_len as u32 || e as u64 + 2 + nargs as u64 > b.pool.len() as u64 {
            return self.fail_at(name, b, i, "an edge with one argument per parameter of its target");
        }
        for k in 0..nargs {
            if self.vty(b, b.edge_arg(e, k)) != b.params[(blk.param_start + k) as usize] {
                return self.fail_at(name, b, i, "an edge argument of its parameter's type");
            }
        }
        return true;
    }

    // Number the blocks in reverse postorder of a depth-first walk from the entry; every block must be
    // reached.
    fn order_blocks(self: &mut Self, name: str, b: &Body) bool {
        let nb = b.blocks.len();
        self.order.truncate(0);
        self.order.resize_default(nb);
        self.on_stack.truncate(0);
        self.on_stack.resize_default(nb);
        for k in 0..nb {
            self.order[k] = NONE;
        }
        self.rpo.truncate(0);
        self.stack.truncate(0);
        let mut seen = Vector::<bool>::new();
        seen.resize_default(nb);
        seen[0] = true;
        self.stack.push(0);
        // Each block enters the stack once and each edge is taken once: at most nb + edges steps.
        while self.stack.len() != 0 {
            let top = self.stack.len() - 1;
            let blk = (self.stack[top] >> 32) as u32;
            let next = self.stack[top] as u32;
            let tm = b.insts[(b.blocks[blk as usize].start + b.blocks[blk as usize].len - 1) as usize];
            b.succ_edges(tm, &mut self.succ);
            if next < self.succ.len() as u32 {
                self.stack[top] = blk as u64 << 32 | (next + 1) as u64;
                let s = b.edge_target(self.succ[next as usize]);
                if !seen[s as usize] {
                    seen[s as usize] = true;
                    self.stack.push(s as u64 << 32);
                }
                continue;
            }
            self.rpo.push(blk);
            self.stack.truncate(top);
        }
        for k in 0..nb {
            if !seen[k] {
                return self.fail_body(name, "a block is unreachable from the entry");
            }
        }
        // Postorder to reverse postorder.
        let n = self.rpo.len();
        for k in 0..n / 2 {
            let x = self.rpo[k];
            self.rpo[k] = self.rpo[n - 1 - k];
            self.rpo[n - 1 - k] = x;
        }
        for k in 0..n {
            self.order[self.rpo[k] as usize] = k as u32;
        }
        return true;
    }

    // Immediate dominators by the iterative algorithm over reverse postorder (Cooper, Harvey, Kennedy:
    // "A Simple, Fast Dominance Algorithm").
    fn dominators(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        self.idom.truncate(0);
        self.idom.resize_default(nb);
        for k in 0..nb {
            self.idom[k] = NONE;
        }
        self.idom[0] = 0;
        // Predecessors: one pass over the edges, as (target, source) pairs sorted by target.
        let mut preds = Vector::<u64>::new();
        for k in 0..nb {
            let tm = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(tm, &mut self.succ);
            for e in 0..self.succ.len() {
                preds.push(b.edge_target(self.succ[e]) as u64 << 32 | k as u64);
            }
        }
        preds.sort();
        let mut first = Vector::<u32>::new();
        first.resize_default(nb + 1);
        let mut j: usize = 0;
        for k in 0..nb + 1 {
            while j < preds.len() && preds[j] >> 32 < k as u64 {
                j += 1;
            }
            first[k] = j as u32;
        }
        let mut changed = true;
        // Each round lowers some idom along a finite order: at most nb rounds.
        while changed {
            changed = false;
            for r in 1..self.rpo.len() {
                let blk = self.rpo[r];
                let mut nd = NONE;
                for q in first[blk as usize]..first[blk as usize + 1] {
                    let pb = preds[q as usize] as u32;
                    if self.idom[pb as usize] == NONE {
                        continue;
                    }
                    nd = if nd == NONE {
                        pb;
                    } else {
                        self.intersect(pb, nd);
                    };
                }
                if nd != self.idom[blk as usize] {
                    self.idom[blk as usize] = nd;
                    changed = true;
                }
            }
        }
    }

    const fn intersect(self: &Self, x: u32, y: u32) u32 {
        let mut a = x;
        let mut c = y;
        while a != c {
            while self.order[a as usize] > self.order[c as usize] {
                a = self.idom[a as usize];
            }
            while self.order[c as usize] > self.order[a as usize] {
                c = self.idom[c as usize];
            }
        }
        return a;
    }

    // Whether block `d` dominates block `x`.
    const fn dominates(self: &Self, d: u32, x: u32) bool {
        let mut k = x;
        // The dominator tree is at most one level per block deep.
        for _ in 0..self.idom.len() + 1 {
            if k == d {
                return true;
            }
            if k == 0 {
                return false;
            }
            k = self.idom[k as usize];
        }
        return false;
    }

    // Reducibility: an edge to a block at or before its source in reverse postorder (a retreating edge)
    // must target a block that dominates the source.
    fn cfg_ok(self: &mut Self, name: str, b: &Body) bool {
        for k in 0..b.blocks.len() {
            let tm = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(tm, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                if self.order[s as usize] <= self.order[k] && !self.dominates(s, k as u32) {
                    return self.fail_body(name, "the CFG is irreducible: a loop has two entries");
                }
            }
        }
        return true;
    }

    // Each operand is dominated by its definition: an instruction earlier in the same block, or in a
    // dominating block; a block parameter of a dominating block.
    fn uses_ok(self: &mut Self, name: str, b: &Body) bool {
        for k in 0..b.blocks.len() {
            let blk = b.blocks[k];
            for j in 0..blk.len {
                let i = blk.start + j;
                let t = b.insts[i as usize];
                let f = op_info(t.op).form;
                if !self.use_ok(k as u32, i, t.a, operand_a(f)) || !self.use_ok(k as u32, i, t.b, operand_b(f)) || !self.use_ok(
                    k as u32,
                    i,
                    t.c,
                    operand_c(f),
                ) {
                    return self.fail_at(name, b, i, "an operand its definition does not dominate");
                }
                if !self.list_uses_ok(b, k as u32, i, t, f) {
                    return self.fail_at(name, b, i, "a listed operand its definition does not dominate");
                }
            }
        }
        return true;
    }

    const fn use_ok(self: &Self, blk: u32, i: u32, v: Value, is_value: bool) bool {
        if !is_value || v == VNONE {
            return true;
        }
        if (v & VPARAM) != 0 {
            return self.dominates(self.param_block[(v & ~VPARAM) as usize], blk);
        }
        let d = v & ~VFLAG;
        let db = self.def_block[d as usize];
        if db == blk {
            return d < i;
        }
        return self.dominates(db, blk);
    }

    // The values of a call's argument list, a vector operation's operands and each edge's arguments: an
    // edge argument is used at the end of the edge's source block.
    const fn list_uses_ok(self: &Self, b: &Body, blk: u32, i: u32, t: Inst, f: u8) bool {
        if f == F_CALL || f == F_CALLIND {
            for k in 0..t.aux as u32 {
                if !self.use_ok(blk, i, b.pool[(t.c + k) as usize], true) {
                    return false;
                }
            }
        } else if f == F_VOP || f == F_ASM {
            for k in 0..t.b {
                if !self.use_ok(blk, i, b.pool[(t.a + k) as usize], true) {
                    return false;
                }
            }
        } else if f == F_JMP || f == F_BR || f == F_SWITCH {
            let mut n: u32 = 1;
            if f == F_BR {
                n = 2;
            } else if f == F_SWITCH {
                n = t.aux as u32 + 1;
            }
            for k in 0..n {
                let e = if f == F_JMP {
                    t.a;
                } else if f == F_BR {
                    ast::pick(k == 0, t.b, t.c);
                } else {
                    b.switch_edge(t, k);
                };
                for x in 0..b.edge_nargs(e) {
                    if !self.use_ok(blk, i, b.edge_arg(e, x), true) {
                        return false;
                    }
                }
            }
        }
        return true;
    }
}

// Per form, whether its operand `a` (bit 1) or `b` (bit 2) is a value; a byte indexes the 256 entries.
const OPS: [u8; 256] = operand_bits();

const fn operand_bits() [u8; 256] {
    let mut t = [0u8; 256];
    let a: [u8; 13] = [
        F_UN,
        F_BIN,
        F_CMP,
        F_OVF,
        F_TRI,
        F_PTRADD,
        F_LOAD,
        F_STORE,
        F_CALLIND,
        F_BR,
        F_SWITCH,
        F_RET,
        F_SYS,
    ];
    let b: [u8; 8] = [F_BIN, F_CMP, F_OVF, F_TRI, F_PTRADD, F_STORE, F_PANIC, F_SYS];
    for f in a {
        // A form stays below the 256 entries.
        unsafe {
            t[f as usize] |= 1;
        }
    }
    for f in b {
        // A form stays below the 256 entries.
        unsafe {
            t[f as usize] |= 2;
        }
    }
    return t;
}

/// Whether operand `a` of form `f` is a value.
pub(package) const fn operand_a(f: u8) bool {
    return (unsafe OPS[f as usize] & 1) != 0;
}

/// Whether operand `b` of form `f` is a value (VNONE allowed where optional).
pub(package) const fn operand_b(f: u8) bool {
    return (unsafe OPS[f as usize] & 2) != 0;
}

/// The values instruction `t` of `b` uses into `out`: its operands, a call's arguments, a vector operation's
/// or an assembly statement's operands; not its edges' arguments.
pub(package) fn uses(b: &Body, t: Inst, out: &mut Vector<Value>) {
    out.truncate(0);
    let f = op_info(t.op).form;
    if operand_a(f) && t.a != VNONE {
        out.push(t.a);
    }
    if operand_b(f) && t.b != VNONE {
        out.push(t.b);
    }
    if operand_c(f) && t.c != VNONE {
        out.push(t.c);
    }
    if f == F_CALL || f == F_CALLIND {
        for q in 0..t.aux as u32 {
            out.push(b.pool[(t.c + q) as usize]);
        }
    } else if f == F_VOP || f == F_ASM {
        for q in 0..t.b {
            out.push(b.pool[(t.a + q) as usize]);
        }
    }
}

/// Whether the address of a slot of `b` (through address arithmetic, selects and block parameters) is
/// used but as an access's or a copy's address or a comparison's operand: a call, a store of it, a
/// return. True also when the derivation does not settle in FRAME_ROUNDS rounds.
pub(package) fn frame_escapes(b: &Body) bool {
    if b.slots.len() == 0 {
        return false;
    }
    let ni = b.insts.len();
    let mut d = Vector::<bool>::new();
    d.resize_default(ni + b.params.len());
    let mut uses_ = Vector::<Value>::new();
    let mut edges = Vector::<u32>::new();
    // Each round marks at least one more value or ends.
    for round in 0..FRAME_ROUNDS + 1 {
        if round == FRAME_ROUNDS {
            return true;
        }
        let mut changed = false;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let der = t.op == O_SLOTADDR || t.op == O_PTRADD && derived(&d, ni, t.a) || t.op == O_SELECT && (derived(
                    &d,
                    ni,
                    t.b,
                ) || derived(&d, ni, t.c));
                if der && !d[i as usize] {
                    d[i as usize] = true;
                    changed = true;
                }
            }
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut edges);
            for e in 0..edges.len() {
                let tb = b.blocks[b.edge_target(edges[e]) as usize];
                for q in 0..b.edge_nargs(edges[e]) {
                    let p = ni + (tb.param_start + q) as usize;
                    if derived(&d, ni, b.edge_arg(edges[e], q)) && !d[p] {
                        d[p] = true;
                        changed = true;
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
    for k in 0..b.blocks.len() {
        let bk = b.blocks[k];
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if t.op == O_PTRADD || t.op == O_SELECT || t.op == O_ICMP || t.op == O_LOAD || t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH {
                continue;
            }
            // A store's, a copy's or a fill's address may be one (a copy's source too); a stored value or
            // a length may not.
            if t.op == O_STORE && derived(&d, ni, t.b) || (t.op == O_MEMCPY || t.op == O_MEMSET) && derived(&d, ni, t.c) {
                return true;
            }
            if t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET {
                continue;
            }
            uses(b, t, &mut uses_);
            for u in 0..uses_.len() {
                if derived(&d, ni, uses_[u]) {
                    return true;
                }
            }
        }
    }
    return false;
}

// Whether value `v` is marked in `d` (instructions, then block parameters past `ni`).
fn derived(d: &Vector<bool>, ni: usize, v: Value) bool {
    if v == VNONE || (v & VFLAG) != 0 {
        return false;
    }
    return if (v & VPARAM) != 0 {
        d[ni + (v & ~VPARAM) as usize];
    } else {
        d[v as usize];
    };
}

// `frame_escapes` derives addresses in at most FRAME_ROUNDS rounds.
const FRAME_ROUNDS: u32 = 8;

/// Whether operand `c` of form `f` is a value.
pub(package) const fn operand_c(f: u8) bool {
    return f == F_TRI || f == F_SYS;
}

/// Whether `t` is a machine type: a scalar, or a vector of 2 to 64 lanes of a scalar of up to 64 bits
/// whose size is at most 64 bytes.
pub(package) const fn type_ok(t: u8) bool {
    if !is_vec(t) {
        return t >= T_I8 && t <= T_PTR;
    }
    let e = t >> 3 & 7;
    let lg = t & 7;
    return t < 0x80 && e <= ELEM_F64 && lg >= 1 && lg <= 6 && type_bytes(t, 8) <= 64;
}

// The type a parameter or result of a signature passes in: an aggregate as its pointer.
const fn carrier(pt: u32) u8 {
    if (pt & AGG) != 0 {
        return T_PTR;
    }
    return pt as u8;
}

// Whether `s` indexes a signature of `b`'s pool whose aggregates index layouts of the pool.
const fn sig_valid(b: &Body, s: u32, ptr: u32) bool {
    if s == NONE || s as u64 + 3 > b.pool.len() as u64 {
        return false;
    }
    let np = b.pool[s as usize];
    let nfixed = b.pool[s as usize + 1];
    if np > MAX_ARGS || (nfixed & ~SIG_VARIADIC) > np || (nfixed & SIG_VARIADIC) == 0 && nfixed != np || s as u64 + 3 + np as u64 > b.pool.len() as u64 {
        return false;
    }
    for k in 0..np + 1 {
        let pt = if k == np {
            b.pool[s as usize + 2];
        } else {
            b.pool[(s + 3 + k) as usize];
        };
        if (pt & AGG) != 0 {
            let l = pt & ~AGG;
            if l as u64 + 3 > b.pool.len() as u64 || l as u64 + 3 + 2 * b.pool[l as usize + 2] as u64 > b.pool.len() as u64 {
                return false;
            }
            // Each leaf is a machine type inside the layout's size.
            for x in 0..b.pool[l as usize + 2] as usize {
                let lt = b.pool[l as usize + 4 + 2 * x];
                if lt > 255 || !type_ok(lt as u8) || b.pool[l as usize + 3 + 2 * x] as u64 + type_bytes(lt as u8, ptr) as u64 > b.pool[l as usize] as u64 {
                    return false;
                }
            }
        } else if k == np && pt == T_NONE as u32 {
            continue;
        } else if (pt & SIG_SEXT) != 0 && pt != (SIG_SEXT | T_I8 as u32) && pt != (SIG_SEXT | T_I16 as u32) || (pt & ~SIG_SEXT) > 255 || !type_ok(
            pt as u8,
        ) {
            return false;
        }
    }
    return true;
}

// An integer or integer vector type.
const fn int_like(t: u8) bool {
    return is_int(t) || is_vec(t) && is_int(lane_type(t));
}

const fn float_like(t: u8) bool {
    return is_float(t) || is_vec(t) && is_float(lane_type(t));
}

// An integer constant's immediate fits its type.
const fn fits(t: Inst) bool {
    return t.ty == T_I64 || t.ty == T_PTR || t.b == 0 && (t.ty == T_I32 || t.a >> type_bits(t.ty, 8) == 0);
}

// The types an atomic operation takes: an integer of up to 64 bits or a pointer.
const fn atomic_type(t: u8) bool {
    return is_int(t) && t != T_I128 || t == T_PTR;
}

// Whether `o` is a memory order a load (`load`), a store (`store`), or both (a read-modify-write) takes.
const fn order_ok(o: u16, load: bool, store: bool) bool {
    if o > MO_SEQ_CST {
        return false;
    }
    if load && store {
        return true;
    }
    if load {
        return o == MO_RELAXED || o == MO_ACQUIRE || o == MO_SEQ_CST;
    }
    return o == MO_RELAXED || o == MO_RELEASE || o == MO_SEQ_CST;
}

// Conversion `op` from `from` to `to`, lane-wise between vectors of one lane count.
const fn conv_ok(op: u8, from: u8, to: u8, ptr: u32) bool {
    if from == T_NONE || to == T_NONE {
        return false;
    }
    if op == O_BITCAST {
        return from != T_PTR && to != T_PTR && type_bytes(from, ptr) == type_bytes(to, ptr);
    }
    if is_vec(from) != is_vec(to) {
        return false;
    }
    if is_vec(from) && lanes(from) != lanes(to) {
        return false;
    }
    let f = ast::pick(is_vec(from), lane_type(from), from);
    let t = ast::pick(is_vec(to), lane_type(to), to);
    if op == O_SEXT || op == O_ZEXT {
        return is_int(f) && is_int(t) && t > f;
    }
    if op == O_TRUNC {
        return is_int(f) && is_int(t) && t < f;
    }
    if op == O_FPEXT {
        return f == T_F32 && t == T_F64;
    }
    if op == O_FPTRUNC {
        return f == T_F64 && t == T_F32;
    }
    if op == O_FPTOSI || op == O_FPTOUI {
        return is_float(f) && is_int(t);
    }
    if op == O_SITOFP || op == O_UITOFP {
        return is_int(f) && is_float(t);
    }
    if op == O_PTRTOINT {
        return f == T_PTR && is_int(t) && type_bytes(t, ptr) == ptr;
    }
    return is_int(f) && t == T_PTR && type_bytes(f, ptr) == ptr;
}

// Whether signature type `x` of body `bx` and `y` of `by` are one type: a scalar type, or two
// aggregate layouts of one size, alignment and leaves.
const fn same_type(bx: &Body, x: u32, by: &Body, y: u32) bool {
    if (x & AGG) == 0 || (y & AGG) == 0 {
        return x == y;
    }
    let lx = (x & ~AGG) as usize;
    let ly = (y & ~AGG) as usize;
    let n = bx.pool[lx + 2];
    if bx.pool[lx] != by.pool[ly] || bx.pool[lx + 1] != by.pool[ly + 1] || n != by.pool[ly + 2] {
        return false;
    }
    for k in 0..2 * n as usize {
        if bx.pool[lx + 3 + k] != by.pool[ly + 3 + k] {
            return false;
        }
    }
    return true;
}

// Signature `s` of body `b` as text: its parameter types then its result.
fn push_sig(b: &Body, s: usize, out: &mut String) {
    out.push_str("(");
    for k in 0..b.pool[s] as usize {
        if k != 0 {
            out.push_str(", ");
        }
        push_sig_type(b, b.pool[s + 3 + k], out);
    }
    if (b.pool[s + 1] & SIG_VARIADIC) != 0 {
        out.format_into(" fixed {}, ...", b.pool[s + 1] & ~SIG_VARIADIC);
    }
    out.push_str(") -> ");
    push_sig_type(b, b.pool[s + 2], out);
}

fn push_sig_type(b: &Body, t: u32, out: &mut String) {
    if (t & AGG) != 0 {
        let l = (t & ~AGG) as usize;
        out.format_into("agg{} align {} [", b.pool[l], b.pool[l + 1]);
        for k in 0..b.pool[l + 2] as usize {
            out.format_into("{}{} ", ast::pick(k == 0, "", ", "), b.pool[l + 3 + 2 * k]);
            lprint::push_type(b.pool[l + 4 + 2 * k] as u8, out);
        }
        out.push_str("]");
    } else {
        lprint::push_type(t as u8, out);
    }
}
