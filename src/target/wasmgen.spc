// The wasm32 code generator: one LIR body into one wasm function of the object (`wasmobj`).
//
// wasm has no registers: every scalar value is a local of its wasm type (i8, i16, i32 and pointers in i32
// locals, zero-extended as the evaluator keeps them), constants and addresses rematerialize at each use,
// and i128 and vector values live in frame memory. Values share a local (a frame home) when their live
// ranges, in the analysis pass's layout positions (`codegen::live`), do not overlap; a block parameter's
// range covers its predecessors, whose edges write it, and a value whose range ends in its own block
// frees its local at its last use.
//
// The frame is on the linear stack below the imported global `__stack_pointer`: the call area (copies of
// arguments, variadic buffers, results in memory) at its base, then the LIR slots, the entry's spills and
// the homes of the memory values. Control flow is Ramsey's structured translation (`codegen::structure`),
// run with an explicit task stack so a deep dominator tree does not deepen the compiler's own stack.
import lir::ir as *;
import codegen::live as lv;
import codegen::structure as st;
import target::wasm as w;
import target::wasmobj as wo;
import codegen::obj as ob;
import target::wasmabi as wa;
import ir::core as core;
import target::assembler as asmr;
import target::wasmasm as wasm_asm;
import target::intrin as intrin;

// The local and home classes: the four scalar wasm types, then v128.
const CL_I32: u32 = 0;
const CL_I64: u32 = 1;
const CL_F32: u32 = 2;
const CL_F64: u32 = 3;
const CL_V128: u32 = 4;
const CL_N: u32 = 5;

// Label frames of the structured code: a block whose end the code of block `blk` follows, the loop
// headed by block `blk`, an `if`.
const LB_BLOCK: u8 = 0;
const LB_LOOP: u8 = 1;
const LB_IF: u8 = 2;

struct Label {
    pub kind: u8,
    pub blk: u32,
}

extend Label as Copy {}

// Tasks of the structured translation, run last pushed first: the code of a dominator-tree node; a node
// inside blocks for its first `b` merge children; the end of the innermost label; an edge (its moves,
// then a branch or the inlined target); the cases of a switch from case `b`.
const TK_TREE: u8 = 0;
const TK_WITHIN: u8 = 1;
const TK_END: u8 = 2;
const TK_EDGE: u8 = 3;
const TK_SWITCH: u8 = 4;

struct Task {
    pub kind: u8,
    pub a: u32,
    pub b: u32,
    pub x: u32, // TK_SWITCH: the switch's block
}

extend Task as Copy {}

/// The code generator of one object.
pub struct Gen {
    pub err: String, // the first refusal, empty when every body compiled
    pkg: *const Package,
    o: *mut wo::WObj,
    vregs: u32,
    // ---- per body ----
    bp: *const Body,
    lv: lv::Live,
    sh: st::Shape,
    c: w::Code,
    rels: Vector<wo::WRel>,
    rows: Vector<u64>, // with debug information, per change of location: its code byte << 32 | its `lines` index
    body_at: u32, // where the body starts past the prologue
    me: wa::WSig, // the body's own signature
    cs: wa::WSig, // a call's
    enc: Vector<u8>,
    nwp: u32, // the wasm parameters
    locals: Vector<u8>, // the types of the locals past the parameters
    local_of: Vector<u32>, // per value index, its local (NONE: rematerialized, in memory, or unused)
    home: Vector<u32>, // per value index, the frame offset of a memory value (NONE: none)
    remat: Vector<bool>, // per instruction
    free: Vector<Vector<u32>>, // per class, the free locals
    free_home: Vector<u64>, // size << 32 | offset of a free home
    scratch: Vector<Vector<u32>>, // per class, the scratch locals (live within one instruction)
    nscr: Vector<u32>, // per class, the scratch locals the current instruction took
    fp: u32, // the frame base local, NONE without a frame
    osp: u32, // the stack pointer at entry, for a frame aligned past 16 bytes (NONE: none)
    frame: u32,
    falign: u32,
    call_area: u32,
    slot_off: Vector<u32>,
    pspill: Vector<u32>, // per entry parameter, the frame offset of its spill (NONE: none)
    home_base: u32,
    home_top: u32,
    va_local: u32, // the variadic buffer's pointer (NONE: not variadic)
    sret_local: u32, // the result's prepended pointer (NONE: none)
    res_slot: u32, // the frame offset of an aggregate result passed as one scalar (NONE)
    canary: u32, // the frame offset of the stack canary above the LIR slots (NONE)
    labels: Vector<Label>,
    tasks: Vector<Task>,
    mk_at: Vector<u32>, // per block, its merge children's start in `mk` (ascending reverse postorder)
    mk: Vector<u32>,
    osym: Vector<u32>, // per body symbol, its object symbol (NONE until used)
    sp_sym: u32,
    table_sym: u32,
    local: bool, // the function compiling is a local copy
    msg_sym: Map<String, u32>, // per C string text, its data symbol
    cstr_n: u32,
    uses: Vector<Value>,
    succ: Vector<u32>,
    sw_tab: Vector<u32>, // a `br_table` switch's entries: per value less the lowest case, its case (n: the default)
    sw_blk: Vector<u32>, // per case and the default, its block (NONE: an enclosing label)
    sw_case: Vector<u32>, // per block, its case
}

const fn bref(p: *const Body) &'static Body {
    return unsafe &*p;
}

const fn oref(p: *mut wo::WObj) &'static mut wo::WObj {
    return unsafe &mut *p;
}

// The local class of wasm type `t`.
const fn class_of(t: u8) u32 {
    if t == w::I64 {
        return CL_I64;
    }
    if t == w::F32 {
        return CL_F32;
    }
    if t == w::F64 {
        return CL_F64;
    }
    if t == w::V128 {
        return CL_V128;
    }
    return CL_I32;
}

// Whether LIR type `t` lives in frame memory: i128 and vectors.
const fn in_mem(t: u8) bool {
    return t == T_I128 || is_vec(t);
}

// The mask of a narrow integer type's bits, 0 for a type of 32 bits or more.
const fn narrow_mask(t: u8) u32 {
    if t == T_I8 {
        return 0xFF;
    }
    if t == T_I16 {
        return 0xFFFF;
    }
    return 0;
}

extend Gen {
    pub fn new(pkg: &Package, o: &mut wo::WObj) Gen {
        let mut free = Vector::<Vector<u32>>::new();
        let mut scratch = Vector::<Vector<u32>>::new();
        let mut nscr = Vector::<u32>::new();
        for _ in 0..CL_N {
            free.push(Vector::<u32>::new());
            scratch.push(Vector::<u32>::new());
            nscr.push(0);
        }
        return Gen {
            err: String::new(),
            pkg: pkg,
            o: o,
            vregs: pkg.vec_regs,
            bp: null,
            lv: lv::Live::new(),
            sh: st::Shape::new(),
            c: w::Code::new(),
            rels: Vector::<wo::WRel>::new(),
            rows: Vector::<u64>::new(),
            body_at: 0,
            me: wa::WSig::new(),
            cs: wa::WSig::new(),
            enc: Vector::<u8>::new(),
            nwp: 0,
            locals: Vector::<u8>::new(),
            local_of: Vector::<u32>::new(),
            home: Vector::<u32>::new(),
            remat: Vector::<bool>::new(),
            free: free,
            free_home: Vector::<u64>::new(),
            scratch: scratch,
            nscr: nscr,
            fp: NONE,
            osp: NONE,
            frame: 0,
            falign: 16,
            call_area: 0,
            slot_off: Vector::<u32>::new(),
            pspill: Vector::<u32>::new(),
            home_base: 0,
            home_top: 0,
            va_local: NONE,
            sret_local: NONE,
            res_slot: NONE,
            canary: NONE,
            labels: Vector::<Label>::new(),
            tasks: Vector::<Task>::new(),
            mk_at: Vector::<u32>::new(),
            mk: Vector::<u32>::new(),
            osym: Vector::<u32>::new(),
            sp_sym: NONE,
            table_sym: NONE,
            local: false,
            msg_sym: Map::<String, u32>::new(),
            cstr_n: 0,
            uses: Vector::<Value>::new(),
            succ: Vector::<u32>::new(),
            sw_tab: Vector::<u32>::new(),
            sw_blk: Vector::<u32>::new(),
            sw_case: Vector::<u32>::new(),
        };
    }

    const fn b(self: &Self) &'static Body {
        return bref(self.bp);
    }

    const fn obj(self: &Self) &'static mut wo::WObj {
        return oref(self.o);
    }

    const fn p(self: &Self) &'static Package {
        return unsafe &*self.pkg;
    }

    fn refuse(self: &mut Self, why: str) bool {
        if self.err.len() == 0 {
            self.err.push_str(why);
        }
        return false;
    }

    // The value index of `v`.
    const fn vx(self: &Self, v: Value) u32 {
        return self.lv.vix(self.b(), v);
    }

    // The LIR type of `v`.
    const fn vt(self: &Self, v: Value) u8 {
        if (v & VFLAG) != 0 {
            return T_I8;
        }
        return self.b().type_of(v);
    }

    // ---- Object symbols ----

    // The object symbol of body symbol `s`: a function or data (thread-locals are plain data: no threads).
    fn osym_of(self: &mut Self, s: u32) u32 {
        if self.osym[s as usize] == NONE {
            self.osym[s as usize] = self.pkg_osym(self.b().syms[s as usize]);
        }
        return self.osym[s as usize];
    }

    // The object symbol of package symbol `ps`.
    fn pkg_osym(self: &mut Self, ps: u32) u32 {
        let y = self.p().syms[ps as usize];
        let nm0 = self.p().spell(y.name);
        // `__sc_x_<name>` is a C library name's alias (a macro of a scoped extern header). The C entry
        // `main` takes argc and argv (`cemit_main_wrapper`), which a wasm C compiler names
        // `__main_argc_argv`: the name the entry point of `std::rt::libc` calls.
        let nm = if y.def == NONE && nm0.starts_with("__sc_x_") {
            nm0.slice(7, nm0.len());
        } else if y.kind == SK_FUNC && nm0 == "main" {
            "__main_argc_argv";
        } else {
            nm0;
        };
        let kind = if y.kind == SK_FUNC {
            wo::K_FUNC;
        } else {
            wo::K_DATA;
        };
        return self.obj().sym(nm, kind);
    }

    // A relocation at the next byte of the code.
    fn reloc(self: &mut Self, kind: u8, sym: u32, addend: i32) {
        self.rels.push(wo::WRel { kind: kind, off: self.c.len(), sym: sym, addend: addend });
    }

    // `global.get` (`set`: `global.set`) of the stack pointer.
    fn sp_access(self: &mut Self, set: bool) {
        if self.sp_sym == NONE {
            self.sp_sym = self.obj().sym("__stack_pointer", wo::K_GLOBAL);
        }
        self.c.op(
            if set {
                w::GLOBAL_SET;
            } else {
                w::GLOBAL_GET;
            },
        );
        self.reloc(w::R_GLOBAL_INDEX_LEB, self.sp_sym, 0);
        self.c.uleb5(0);
    }

    // `call` of object function symbol `k` of wasm type `ty`.
    fn call_sym(self: &mut Self, k: u32, ty: u32) {
        self.obj().import_type(k, ty);
        self.c.op(w::CALL);
        self.reloc(w::R_FUNCTION_INDEX_LEB, k, 0);
        self.c.uleb5(0);
    }

    // `call` of runtime function `name` whose wasm type has parameters `ps` and results `rs`.
    fn call_rt(self: &mut Self, name: str, ps: []u8, rs: []u8) {
        self.enc.truncate(0);
        w::uleb(&mut self.enc, ps.len() as u64);
        self.enc.extend_from_slice(ps);
        w::uleb(&mut self.enc, rs.len() as u64);
        self.enc.extend_from_slice(rs);
        let ty = self.obj().type_index(&self.enc);
        let k = self.obj().sym(name, wo::K_FUNC);
        self.call_sym(k, ty);
    }

    // The data symbol of C string `text`, one per text.
    fn cstr(self: &mut Self, text: str) u32 {
        let key = String::from_str(text);
        if let Some(k) = self.msg_sym.get(&key) {
            return *k;
        }
        let name = format("__sc_msg.{}", self.cstr_n);
        self.cstr_n += 1;
        let o = self.obj();
        let k = o.sym(name.as_str(), wo::K_DATA);
        let mut g = wo::WSeg {
            name: format(".rodata.{}", name.as_str()),
            align_log2: 0,
            bytes: Vector::<u8>::with_capacity(text.len() + 1),
            rels: Vector::<wo::WRel>::new(),
            retain: false,
        };
        for j in 0..text.len() {
            g.bytes.push(text.byte_at(j));
        }
        g.bytes.push(0);
        o.define_data(k, wo::F_LOCAL, g);
        self.msg_sym.insert(key, k);
        return k;
    }

    // `i32.const` of the address of data symbol `k` plus `addend`.
    fn data_addr(self: &mut Self, k: u32, addend: i32) {
        self.c.op(w::I32_CONST);
        self.reloc(w::R_MEMORY_ADDR_SLEB, k, addend);
        self.c.sleb5(0);
    }

    // ---- Scratch locals: live within one instruction ----

    fn tmp(self: &mut Self, t: u8) u32 {
        let k = class_of(t);
        let n = self.nscr[k as usize];
        if n as usize == self.scratch.at(k as usize).len() {
            let l = self.new_local(t);
            self.scratch.index_mut(k as usize).push(l);
        }
        self.nscr[k as usize] = n + 1;
        return self.scratch.at(k as usize)[n as usize];
    }

    const fn end_inst(self: &mut Self) {
        for k in 0..CL_N as usize {
            self.nscr[k] = 0;
        }
    }

    fn new_local(self: &mut Self, t: u8) u32 {
        self.locals.push(t);
        return self.nwp + self.locals.len() as u32 - 1;
    }
}

// ---- The body ----

extend Gen {
    /// Compile the body of package function symbol `s` into the object. False (with `err`) when the body
    /// uses what the generator does not compile.
    pub fn func(self: &mut Self, s: u32, local: bool) bool {
        self.local = local;
        let ps = self.p().syms[s as usize];
        self.bp = &self.p().bodies[ps.def as usize];
        let b = self.b();
        if self.p().ptr_bytes != 4 {
            return self.refuse("a data model whose pointers are not 32-bit");
        }
        self.lv.run(b);
        self.sh.run(b);
        wa::classify(b, b.sig, self.vregs, &mut self.me);
        if self.me.unknown {
            return self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        if b.naked {
            return self.naked(s);
        }
        lv::fill(&mut self.osym, b.syms.len(), NONE);
        self.c.clear();
        self.rels.truncate(0);
        self.rows.truncate(0);
        self.locals.truncate(0);
        self.labels.truncate(0);
        self.tasks.truncate(0);
        for k in 0..CL_N as usize {
            self.free.index_mut(k).truncate(0);
            self.scratch.index_mut(k).truncate(0);
            self.nscr[k] = 0;
        }
        self.free_home.truncate(0);
        self.remat.truncate(0);
        for k in 0..b.insts.len() {
            let op = b.insts[k].op;
            self.remat.push(op == O_ICONST || op == O_FCONST || op == O_SYMADDR || op == O_SLOTADDR || op == O_RETADDR);
        }
        // The wasm parameters: the result's pointer, the fixed parameters' values, the variadic buffer.
        wa::encode(&self.me, &mut self.enc);
        self.nwp = self.enc[0];
        if !self.frame_layout() {
            return false;
        }
        self.merge_kids();
        self.assign();
        if self.err.len() != 0 {
            return false;
        }
        self.prologue();
        self.body_at = self.c.bytes.len() as u32;
        self.tasks.push(Task { kind: TK_TREE, a: 0, b: 0, x: 0 });
        // Each task emits code once; the tasks a node pushes are bounded by its edges and children.
        while self.tasks.len() != 0 {
            let tk = self.tasks.pop().unwrap();
            if !self.task(tk) {
                return false;
            }
        }
        self.c.op(w::UNREACHABLE);
        self.c.op(w::END);
        return self.finish(s);
    }

    // The frame: the call area, the slots, the entry's spills; the homes follow (`assign`). False when a
    // call passes an aggregate whose class is unknown.
    fn frame_layout(self: &mut Self) bool {
        let b = self.b();
        let mut area: u32 = 0;
        for k in 0..b.insts.len() {
            let t = b.insts[k];
            if t.op == O_CALL || t.op == O_CALLIND {
                wa::classify(b, t.b, self.vregs, &mut self.cs);
                if self.cs.unknown {
                    return self.refuse("a call passes an aggregate whose C class is unknown");
                }
                let n = self.call_bytes(t);
                if n > area {
                    area = n;
                }
            } else if t.op == O_MULO && t.ty == T_I64 {
                area = ast_max(area, 16);
            } else if t.op == O_VOP {
                // A 64-bit lane product's high word (compiler-rt) or a halving reduction's copy.
                area = ast_max(area, 64);
            } else if t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH {
                // An edge passing several memory values goes through the area.
                b.succ_edges(t, &mut self.succ);
                for e in 0..self.succ.len() {
                    let mut n: u32 = 0;
                    for q in 0..b.edge_nargs(self.succ[e]) {
                        let a = b.edge_arg(self.succ[e], q);
                        if in_mem(self.vt(a)) {
                            n += type_bytes(self.vt(a), 4) + 15 & ~15u32;
                        }
                    }
                    area = ast_max(area, n);
                }
            }
        }
        self.call_area = area + 15 & ~15u32;
        let mut at = self.call_area;
        self.falign = 16;
        lv::fill(&mut self.slot_off, b.slots.len(), 0);
        for k in 0..b.slots.len() {
            let sl = b.slots[k];
            let al = 1u32 << sl.align_log2 as u32;
            self.falign = ast_max(self.falign, al);
            at = at + al - 1 & ~(al - 1);
            self.slot_off[k] = at;
            at += sl.size;
        }
        // The canary between the slots and the frame memory above them.
        self.canary = NONE;
        if protected(self.p().protect, b) {
            at = at + 3 & ~3u32;
            self.canary = at;
            at += 4;
        }
        // The entry's spills: a parameter or result passed as one scalar of an aggregate.
        let np = b.pool[b.sig as usize];
        lv::fill(&mut self.pspill, np as usize, NONE);
        for k in 0..np {
            let pa = self.me.params[k as usize];
            if pa.kind == wa::P_DIRECT && pa.leaf {
                at = at + 15 & ~15u32;
                self.pspill[k as usize] = at;
                at += 16;
            }
        }
        self.res_slot = NONE;
        if self.me.ret.kind == wa::P_DIRECT && self.me.ret.leaf {
            at = at + 15 & ~15u32;
            self.res_slot = at;
            at += 16;
        }
        self.home_base = at + 15 & ~15u32;
        self.home_top = 0;
        return true;
    }

    // The call area bytes call `t` needs: copies of its memory values passed by reference, and its
    // variadic buffer.
    fn call_bytes(self: &Self, t: Inst) u32 {
        let b = self.b();
        let np = b.pool[t.b as usize];
        let mut n: u32 = 0;
        for k in 0..np {
            let pa = self.cs.params[k as usize];
            let pt = b.pool[(t.b + 3 + k) as usize];
            if k >= self.cs.nfixed {
                let (sz, al) = wa::va_slot(b, pt, self.vregs);
                n = (n + al - 1 & ~(al - 1)) + sz;
                if pa.kind == wa::P_REF && (pt & AGG) == 0 {
                    n = (n + 15 & ~15u32) + type_bytes(pa.ty, 4);
                }
            } else if pa.kind == wa::P_REF && (pt & AGG) == 0 {
                n = (n + 15 & ~15u32) + type_bytes(pa.ty, 4);
            }
        }
        return n;
    }

    // Per block, its merge children in ascending reverse postorder.
    fn merge_kids(self: &mut Self) {
        let nb = self.b().blocks.len();
        lv::fill(&mut self.mk_at, nb + 1, 0);
        self.mk.truncate(0);
        for k in 0..nb {
            self.mk_at[k] = self.mk.len() as u32;
            for q in self.sh.kids_at[k]..self.sh.kids_at[k + 1] {
                let y = self.sh.kids[q as usize];
                if self.sh.merge(y) {
                    self.mk.push(y);
                }
            }
        }
        self.mk_at[nb] = self.mk.len() as u32;
    }
}

const fn pick64(c: bool, a: u64, b: u64) u64 {
    if c {
        return a;
    }
    return b;
}

// log2 of power of two `n`.
const fn log2u(n: u32) u32 {
    return n.trailing_zeros() as u32;
}

// The i64 comparison of integer lane rule `c` (SIMD_CMP_EQ .. SIMD_CMP_GE), signed `sg`.
const fn int_cmp64(c: u8, sg: bool) u8 {
    if c == core::SIMD_CMP_EQ {
        return w::I64_EQ;
    }
    if c == core::SIMD_CMP_NE {
        return w::I64_NE;
    }
    if c == core::SIMD_CMP_LT {
        return pick8(sg, w::I64_LT_S, w::I64_LT_U);
    }
    if c == core::SIMD_CMP_LE {
        return pick8(sg, w::I64_LE_S, w::I64_LE_U);
    }
    if c == core::SIMD_CMP_GT {
        return pick8(sg, w::I64_GT_S, w::I64_GT_U);
    }
    return pick8(sg, w::I64_GE_S, w::I64_GE_U);
}

const fn f32_bits(x: f32) u32 {
    return unsafe *(((&x) as *const f32) as *const u32);
}

const fn pick8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}

const fn ast_max(a: u32, b: u32) u32 {
    if a > b {
        return a;
    }
    return b;
}

// ---- Locals and homes ----

extend Gen {
    // The local or home of every value: the entry's parameters at their wasm parameters, the others in
    // live-range order (see the file comment).
    fn assign(self: &mut Self) {
        let b = self.b();
        let n = self.lv.end.len();
        lv::fill(&mut self.local_of, n, NONE);
        lv::fill(&mut self.home, n, NONE);
        let np = b.blocks.len();
        let npos = self.lv.order.len();
        // Ranges: from the definition's position to `end`; a block parameter's widened over its
        // predecessors.
        let mut start = Vector::<u32>::new();
        let mut end = Vector::<u32>::new();
        lv::fill(&mut start, n, NONE);
        lv::fill(&mut end, n, 0);
        for x in 0..n {
            let d = self.lv.def_blk[x];
            if d != NONE && self.lv.pos[d as usize] != NONE {
                start[x] = self.lv.pos[d as usize];
                end[x] = self.lv.end[x];
            }
        }
        let ni = b.insts.len() as u32;
        for k in 0..np {
            if self.lv.pos[k] == NONE {
                continue;
            }
            let t = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let tb = b.blocks[b.edge_target(self.succ[e]) as usize];
                let q = self.lv.pos[k];
                for j in 0..tb.param_len as u32 {
                    let x = (ni + tb.param_start + j) as usize;
                    if start[x] == NONE {
                        continue;
                    }
                    if q < start[x] {
                        start[x] = q;
                    }
                    if q > end[x] {
                        end[x] = q;
                    }
                }
            }
        }
        // The entry's parameters: where the convention passes them.
        self.entry_params();
        // Which values need storage: a used result that does not rematerialize, a parameter.
        let mut need = Vector::<bool>::new();
        need.resize_default(n);
        for x in 0..n {
            if start[x] == NONE || self.local_of[x] != NONE || self.home[x] != NONE {
                continue;
            }
            if x < ni as usize {
                // A memory result needs its home even unused: the instruction writes it.
                let t = b.insts[x];
                need[x] = t.ty != T_NONE && !self.remat[x] && (self.lv.uses[x] != 0 || in_mem(t.ty));
            } else {
                need[x] = self.lv.uses[x] != 0 || x < (ni + b.params.len() as u32) as usize;
            }
        }
        // A value whose range is one position and is no parameter is freed at its last use; the others
        // when the position past their range starts.
        let mut by_start = Vector::<u32>::new();
        let mut by_end = Vector::<u32>::new();
        let mut s_at = Vector::<u32>::new();
        lv::fill(&mut s_at, npos + 1, 0);
        let mut e_at = Vector::<u32>::new();
        lv::fill(&mut e_at, npos + 2, 0);
        for x in 0..n {
            if need[x] && !(start[x] == end[x] && x < ni as usize) {
                s_at[start[x] as usize + 1] += 1;
                e_at[end[x] as usize + 2] += 1;
            }
        }
        for q in 0..npos {
            s_at[q + 1] += s_at[q];
        }
        for q in 0..npos + 1 {
            e_at[q + 1] += e_at[q];
        }
        lv::fill(&mut by_start, s_at[npos] as usize, 0);
        lv::fill(&mut by_end, e_at[npos + 1] as usize, 0);
        let mut sf = Vector::<u32>::with_capacity(npos + 1);
        sf.extend_copy(&s_at);
        let mut ef = Vector::<u32>::with_capacity(npos + 2);
        ef.extend_copy(&e_at);
        for x in 0..n {
            if need[x] && !(start[x] == end[x] && x < ni as usize) {
                by_start[sf[start[x] as usize] as usize] = x as u32;
                sf[start[x] as usize] += 1;
                // Freed when position end + 1 starts.
                by_end[ef[end[x] as usize + 1] as usize] = x as u32;
                ef[end[x] as usize + 1] += 1;
            }
        }
        let mut left = Vector::<u32>::new(); // per value, its uses left in its own block
        lv::fill(&mut left, n, 0);
        for q in 0..npos {
            for j in e_at[q]..e_at[q + 1] {
                self.release(by_end[j as usize]);
            }
            for j in s_at[q]..s_at[q + 1] {
                self.take(by_start[j as usize]);
            }
            let k = self.lv.order[q];
            let blk = b.blocks[k as usize];
            for i in blk.start..blk.start + blk.len {
                let t = b.insts[i as usize];
                // A memory result takes its home before its operands free theirs: a lowering may write
                // the result's lanes before it reads every operand lane (a gather's fallback lanes).
                let own = need[i as usize] && start[i as usize] == end[i as usize];
                let early = own && in_mem(t.ty);
                if early {
                    self.take(i);
                }
                lv::each_use(b, t, &mut self.uses);
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    let x = self.vx(v);
                    if x == NONE || x >= ni || !need[x as usize] || start[x as usize] != end[x as usize] {
                        continue;
                    }
                    if left[x as usize] == 0 {
                        left[x as usize] = self.lv.uses[x as usize];
                    }
                    left[x as usize] -= 1;
                    if left[x as usize] == 0 {
                        self.release(x);
                    }
                }
                if own {
                    if !early {
                        self.take(i);
                    }
                    if self.lv.uses[i as usize] == 0 {
                        self.release(i);
                    }
                }
                if let Some(fx) = self.lv.flag_of.get(&i) {
                    let f = (*fx) as usize;
                    if need[f] && start[f] == end[f] {
                        self.take(f as u32);
                    }
                }
            }
        }
    }

    // A local or home for value `x`.
    fn take(self: &mut Self, x: u32) {
        let t = self.xty(x);
        if in_mem(t) {
            let sz = type_bytes(t, 4) + 15 & ~15u32;
            for q in 0..self.free_home.len() {
                if (self.free_home[q] >> 32) as u32 == sz {
                    self.home[x as usize] = self.free_home[q] as u32;
                    let _ = self.free_home.swap_remove(q);
                    return;
                }
            }
            self.home[x as usize] = self.home_base + self.home_top;
            self.home_top += sz;
            return;
        }
        let wt = wa::wtype(t);
        let k = class_of(wt) as usize;
        if let Some(l) = self.free.index_mut(k).pop() {
            self.local_of[x as usize] = l;
            return;
        }
        self.local_of[x as usize] = self.new_local(wt);
    }

    // Value `x`'s local or home is free.
    fn release(self: &mut Self, x: u32) {
        let t = self.xty(x);
        if self.home[x as usize] != NONE {
            let sz = type_bytes(t, 4) + 15 & ~15u32;
            self.free_home.push(sz as u64 << 32 | self.home[x as usize] as u64);
            return;
        }
        let l = self.local_of[x as usize];
        if l == NONE || l < self.nwp {
            return;
        }
        self.free.index_mut(class_of(wa::wtype(t)) as usize).push(l);
    }

    // The LIR type of value index `x`.
    const fn xty(self: &Self, x: u32) u8 {
        let b = self.b();
        let ni = b.insts.len() as u32;
        if x < ni {
            return b.insts[x as usize].ty;
        }
        if x < ni + b.params.len() as u32 {
            return b.params[(x - ni) as usize];
        }
        return T_I8;
    }

    // The entry block's parameters: a scalar passed as one wasm value is its wasm parameter's local; the
    // others take homes (filled by the prologue) or are the frame address of their spill.
    const fn entry_params(self: &mut Self) {
        let b = self.b();
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        let np = b.pool[b.sig as usize];
        let mut wp: u32 = 0;
        self.sret_local = NONE;
        self.va_local = NONE;
        if self.me.sret() {
            self.sret_local = 0;
            wp = 1;
        }
        for k in 0..np {
            let pa = self.me.params[k as usize];
            let x = ni + e0 + k;
            if pa.kind == wa::P_DIRECT && !pa.leaf {
                self.local_of[x as usize] = wp;
                wp += 1;
            } else if pa.kind == wa::P_DIRECT {
                wp += 1;
            } else if pa.kind == wa::P_I128 {
                wp += 2;
            } else if pa.kind == wa::P_REF && (b.pool[(b.sig + 3 + k) as usize] & AGG) != 0 {
                // An aggregate's address is the pointer.
                self.local_of[x as usize] = wp;
                wp += 1;
            } else if pa.kind != wa::P_SKIP {
                wp += 1;
            }
        }
        if self.me.variadic {
            self.va_local = wp;
        }
        // An aggregate result: the prepended pointer, or the spill slot (its address, a local the prologue
        // sets).
        let rt = b.pool[b.sig as usize + 2];
        if (rt & AGG) != 0 && self.me.ret.kind == wa::P_REF {
            self.local_of[(ni + e0 + np) as usize] = 0;
        }
    }
}

// ---- The prologue and the epilogue ----

extend Gen {
    // The frame and the entry's parameters that do not arrive as their own wasm value.
    fn prologue(self: &mut Self) {
        let b = self.b();
        self.frame = self.home_base + self.home_top + 15 & ~15u32;
        let needs_frame = self.frame != 0;
        self.fp = NONE;
        self.osp = NONE;
        if needs_frame {
            self.fp = self.new_local(w::I32);
            if self.falign > 16 {
                self.osp = self.new_local(w::I32);
                self.sp_access(false);
                self.c.local(w::LOCAL_SET, self.osp);
            }
            self.sp_access(false);
            self.c.i32_const(self.frame as i32);
            self.c.op(w::I32_SUB);
            if self.falign > 16 {
                self.c.i32_const(-(self.falign as i32));
                self.c.op(w::I32_AND);
            }
            self.c.local(w::LOCAL_TEE, self.fp);
            self.sp_access(true);
        }
        if self.canary != NONE {
            self.c.local(w::LOCAL_GET, self.fp);
            self.guard();
            self.store_op(T_I32, self.canary);
        }
        let ni = b.insts.len() as u32;
        let e0 = b.blocks[0].param_start;
        let np = b.pool[b.sig as usize];
        let mut wp: u32 = if self.me.sret() {
            1u32;
        } else {
            0u32;
        };
        for k in 0..np {
            let pa = self.me.params[k as usize];
            let x = ni + e0 + k;
            let pt = b.pool[(b.sig + 3 + k) as usize];
            let used = self.lv.uses[x as usize] != 0;
            if pa.kind == wa::P_DIRECT && !pa.leaf {
                // A narrow integer: zero-extended, as every value of its type.
                let m = narrow_mask(pa.ty);
                if m != 0 && used {
                    self.c.local(w::LOCAL_GET, wp);
                    self.c.i32_const(m as i32);
                    self.c.op(w::I32_AND);
                    self.c.local(w::LOCAL_SET, wp);
                }
                wp += 1;
            } else if pa.kind == wa::P_DIRECT {
                // An aggregate's one scalar: spilled, the value its spill's address.
                let off = self.pspill[k as usize];
                self.c.local(w::LOCAL_GET, self.fp);
                self.c.local(w::LOCAL_GET, wp);
                self.store_op(pa.ty, off);
                if self.local_of[x as usize] != NONE {
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.c.i32_const(off as i32);
                    self.c.op(w::I32_ADD);
                    self.c.local(w::LOCAL_SET, self.local_of[x as usize]);
                }
                wp += 1;
            } else if pa.kind == wa::P_I128 {
                if self.home[x as usize] != NONE {
                    let h = self.home[x as usize];
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.c.local(w::LOCAL_GET, wp);
                    self.store_op(T_I64, h);
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.c.local(w::LOCAL_GET, wp + 1);
                    self.store_op(T_I64, h + 8);
                }
                wp += 2;
            } else if pa.kind == wa::P_V128 {
                if self.home[x as usize] != NONE {
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.c.local(w::LOCAL_GET, wp);
                    self.c.simd(w::V128_STORE);
                    self.c.memarg(4, self.home[x as usize]);
                    self.obj().simd = true;
                }
                wp += 1;
            } else if pa.kind == wa::P_REF && (pt & AGG) == 0 {
                // A memory value passed by reference: its bytes into its home.
                if self.home[x as usize] != NONE {
                    let h = self.home[x as usize];
                    self.copy_mem(self.fp, h, wp, 0, type_bytes(pa.ty, 4));
                }
                wp += 1;
            } else if pa.kind != wa::P_SKIP {
                wp += 1;
            }
        }
        // An aggregate result in a spill: its address is the result parameter's value.
        let rt = b.pool[b.sig as usize + 2];
        let rx = (ni + e0 + np) as usize;
        if (rt & AGG) != 0 && self.res_slot != NONE && self.local_of[rx] != NONE {
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.i32_const(self.res_slot as i32);
            self.c.op(w::I32_ADD);
            self.c.local(w::LOCAL_SET, self.local_of[rx]);
        }
    }

    // The value of `__stack_chk_guard` on the operand stack.
    fn guard(self: &mut Self) {
        let k = self.obj().sym("__stack_chk_guard", wo::K_DATA);
        self.data_addr(k, 0);
        self.load_op(T_I32, 0);
    }

    // Check the canary, then restore the stack pointer before a return: on a mismatch
    // `__stack_chk_fail`, which does not return.
    fn epilogue(self: &mut Self) {
        if self.fp == NONE {
            return;
        }
        if self.canary != NONE {
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(T_I32, self.canary);
            self.guard();
            self.c.op(w::I32_NE);
            self.c.op(w::IF);
            self.c.op(w::BLOCK_EMPTY);
            self.call_rt("__stack_chk_fail", [], []);
            self.c.op(w::UNREACHABLE);
            self.c.op(w::END);
        }
        if self.osp != NONE {
            self.c.local(w::LOCAL_GET, self.osp);
        } else {
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.i32_const(self.frame as i32);
            self.c.op(w::I32_ADD);
        }
        self.sp_access(true);
    }

    // Define function symbol `s` with the code.
    fn finish(self: &mut Self, s: u32) bool {
        let ps = self.p().syms[s as usize];
        let k = self.pkg_osym(s);
        let o = self.obj();
        if o.syms[k as usize].def != wo::NONE {
            return self.refuse("a function defined twice in one object");
        }
        wa::encode(&self.me, &mut self.enc);
        let ty = o.type_index(&self.enc);
        let mut fl = if ps.linkage == SL_GLOBAL && !self.local {
            wo::F_HIDDEN;
        } else {
            wo::F_LOCAL;
        };
        if ps.used {
            fl |= wo::F_NO_STRIP;
        }
        let mut f = wo::WFunc {
            sym: k,
            locals: Vector::<u8>::with_capacity(self.locals.len()),
            code: Vector::<u8>::with_capacity(self.c.bytes.len()),
            rels: Vector::<wo::WRel>::with_capacity(self.rels.len()),
            lines: Vector::<ob::OLine>::with_capacity(self.rows.len()),
            body: self.body_at,
        };
        // The rows, the first from the function's start: the prologue takes its location.
        for q in 0..self.rows.len() {
            let l = self.b().lines[(self.rows[q] & 0xFFFFFFFF) as usize];
            let off = if q == 0 {
                0u32;
            } else {
                (self.rows[q] >> 32) as u32;
            };
            f.lines.push(ob::OLine { off: off, file: l.file, line: l.line, col: l.col });
        }
        f.locals.extend_copy(&self.locals);
        f.code.extend_copy(&self.c.bytes);
        f.rels.extend_copy(&self.rels);
        o.define_func(k, ty, fl, f);
        return true;
    }
}

// ---- Values ----

extend Gen {
    // Push scalar value `v`.
    fn get(self: &mut Self, v: Value) {
        if (v & (VPARAM | VFLAG)) == 0 && self.remat[v as usize] {
            self.remat_value(v);
            return;
        }
        let x = self.vx(v);
        let l = if x == NONE {
            NONE;
        } else {
            self.local_of[x as usize];
        };
        if l == NONE {
            let _ = self.refuse("internal: a value without a local");
            self.c.i32_const(0);
            return;
        }
        self.c.local(w::LOCAL_GET, l);
    }

    // Push the value of rematerialized instruction `i`.
    fn remat_value(self: &mut Self, i: u32) {
        let t = self.b().insts[i as usize];
        let op = t.op;
        if op == O_ICONST {
            let bits = t.b as u64 << 32 | t.a as u64;
            if t.ty == T_I64 {
                self.c.i64_const(bits as i64);
            } else {
                self.c.i32_const(t.a as i32);
            }
        } else if op == O_FCONST {
            if t.ty == T_F32 {
                self.c.f32_const(t.a);
            } else {
                self.c.f64_const(t.b as u64 << 32 | t.a as u64);
            }
        } else if op == O_SYMADDR {
            let ps = self.p().syms[self.b().syms[t.a as usize] as usize];
            let k = self.osym_of(t.a);
            self.c.op(w::I32_CONST);
            if ps.kind == SK_FUNC {
                if t.b != 0 {
                    let _ = self.refuse("an offset into a function's address");
                }
                self.fn_type_known(self.b().syms[t.a as usize], k);
                self.reloc(w::R_TABLE_INDEX_SLEB, k, 0);
            } else {
                self.reloc(w::R_MEMORY_ADDR_SLEB, k, t.b as i32);
            }
            self.c.sleb5(0);
        } else if op == O_SLOTADDR {
            self.c.local(w::LOCAL_GET, self.fp);
            let off = self.slot_off[t.a as usize];
            if off != 0 {
                self.c.i32_const(off as i32);
                self.c.op(w::I32_ADD);
            }
        } else {
            // O_RETADDR: wasm walks no frames; C's value is null.
            self.c.i32_const(0);
        }
    }

    // Function object symbol `k` (package symbol `ps`) whose address is taken: an import needs its type,
    // from its body when the package defines it, else from a call of it anywhere in the package.
    fn fn_type_known(self: &mut Self, ps: u32, k: u32) {
        if self.obj().syms[k as usize].ty != wo::NONE {
            return;
        }
        let p = self.p();
        let y = p.syms[ps as usize];
        let mut sg = wa::WSig::new();
        let mut found = false;
        if y.def != NONE {
            let cb = &p.bodies[y.def as usize];
            wa::classify(cb, cb.sig, self.vregs, &mut sg);
            found = true;
        } else {
            // Bounded by the package's instructions.
            for bi in 0..p.bodies.len() {
                let cb = &p.bodies[bi];
                for j in 0..cb.insts.len() {
                    let ct = cb.insts[j];
                    if ct.op == O_CALL && cb.syms[ct.a as usize] == ps {
                        wa::classify(cb, ct.b, self.vregs, &mut sg);
                        found = true;
                        break;
                    }
                }
                if found {
                    break;
                }
            }
        }
        if !found {
            let _ = self.refuse("the address of an external function no call shows the signature of");
            return;
        }
        let mut enc = Vector::<u8>::new();
        wa::encode(&sg, &mut enc);
        let ty = self.obj().type_index(&enc);
        self.obj().import_type(k, ty);
    }

    // Pop the stack into instruction `i`'s local; drop it when the result has none.
    fn put(self: &mut Self, i: u32) {
        let l = self.local_of[i as usize];
        if l == NONE {
            self.c.op(w::DROP);
            return;
        }
        self.c.local(w::LOCAL_SET, l);
    }

    // The frame offset of memory value `v`.
    fn mhome(self: &mut Self, v: Value) u32 {
        let x = self.vx(v);
        let h = if x == NONE {
            NONE;
        } else {
            self.home[x as usize];
        };
        if h == NONE {
            let _ = self.refuse("internal: a memory value without a home");
            return 0;
        }
        return h;
    }

    // Push the address of memory value `v`.
    fn maddr(self: &mut Self, v: Value) {
        let h = self.mhome(v);
        self.c.local(w::LOCAL_GET, self.fp);
        self.c.i32_const(h as i32);
        self.c.op(w::I32_ADD);
    }

    // Push the i64 word `k` of memory value `v`.
    fn mword(self: &mut Self, v: Value, k: u32) {
        let h = self.mhome(v);
        self.c.local(w::LOCAL_GET, self.fp);
        self.load_op(T_I64, h + 8 * k);
    }

    // A load of LIR scalar type `t` at offset `off` of the address on the stack (natural alignment).
    fn load_op(self: &mut Self, t: u8, off: u32) {
        self.load_al(t, off, 15);
    }

    // A load whose alignment claims at most 2^`al` bytes.
    fn load_al(self: &mut Self, t: u8, off: u32, al: u32) {
        let (op, nat) = if t == T_I8 {
            (w::I32_LOAD8_U, 0u32);
        } else if t == T_I16 {
            (w::I32_LOAD16_U, 1u32);
        } else if t == T_I64 {
            (w::I64_LOAD, 3u32);
        } else if t == T_F32 {
            (w::F32_LOAD, 2u32);
        } else if t == T_F64 {
            (w::F64_LOAD, 3u32);
        } else {
            (w::I32_LOAD, 2u32);
        };
        self.c.op(op);
        self.c.memarg(
            if al < nat {
                al;
            } else {
                nat;
            },
            off,
        );
    }

    // A store of LIR scalar type `t` at offset `off` of the address under the value on the stack.
    fn store_op(self: &mut Self, t: u8, off: u32) {
        self.store_al(t, off, 15);
    }

    fn store_al(self: &mut Self, t: u8, off: u32, al: u32) {
        let (op, nat) = if t == T_I8 {
            (w::I32_STORE8, 0u32);
        } else if t == T_I16 {
            (w::I32_STORE16, 1u32);
        } else if t == T_I64 {
            (w::I64_STORE, 3u32);
        } else if t == T_F32 {
            (w::F32_STORE, 2u32);
        } else if t == T_F64 {
            (w::F64_STORE, 3u32);
        } else {
            (w::I32_STORE, 2u32);
        };
        self.c.op(op);
        self.c.memarg(
            if al < nat {
                al;
            } else {
                nat;
            },
            off,
        );
    }

    // Copy `n` bytes from `sl + soff` to `dl + doff` (both locals holding addresses).
    fn copy_mem(self: &mut Self, dl: u32, doff: u32, sl: u32, soff: u32, n: u32) {
        let mut k: u32 = 0;
        while k + 8 <= n {
            self.c.local(w::LOCAL_GET, dl);
            self.c.local(w::LOCAL_GET, sl);
            self.load_al(T_I64, soff + k, 0);
            self.store_al(T_I64, doff + k, 0);
            k += 8;
        }
        let tail: []u8 = [T_I32, T_I16, T_I8];
        let size: []u32 = [4, 2, 1];
        for q in 0..3usize {
            if k + size[q] <= n {
                self.c.local(w::LOCAL_GET, dl);
                self.c.local(w::LOCAL_GET, sl);
                self.load_al(tail[q], soff + k, 0);
                self.store_al(tail[q], doff + k, 0);
                k += size[q];
            }
        }
    }

    // Narrow integer of type `t` on the stack (zero-extended in i32): sign-extended to 32 bits.
    fn sx(self: &mut Self, t: u8) {
        if t == T_I8 {
            self.c.op(w::I32_EXTEND8_S);
        } else if t == T_I16 {
            self.c.op(w::I32_EXTEND16_S);
        }
    }

    // An i32 on the stack truncated to narrow type `t`'s bits.
    fn canon(self: &mut Self, t: u8) {
        let m = narrow_mask(t);
        if m != 0 {
            self.c.i32_const(m as i32);
            self.c.op(w::I32_AND);
        }
    }

    // Push value `v` sign-extended when `signed` and narrow.
    fn get_ext(self: &mut Self, v: Value, signed: bool) {
        self.get(v);
        if signed {
            let t = self.vt(v);
            self.sx(t);
        }
    }
}

// ---- Instructions ----

extend Gen {
    // Compile non-terminator instruction `i`.
    fn inst(self: &mut Self, i: u32) bool {
        let b = self.b();
        let t = b.insts[i as usize];
        let op = t.op;
        if self.remat[i as usize] {
            return true;
        }
        if op == O_WCONST {
            if self.local_of[i as usize] == NONE && self.home[i as usize] == NONE {
                return true;
            }
            let h = self.home[i as usize];
            for k in 0..t.b {
                self.c.local(w::LOCAL_GET, self.fp);
                self.c.i64_const(b.words[(t.a + k) as usize] as i64);
                self.store_op(T_I64, h + 8 * k);
            }
            return true;
        }
        if is_vec(t.ty) && op != O_LOAD && op != O_SELECT && op != O_CALL && op != O_CALLIND && op != O_VAARG && op != O_BITCAST || op == O_VOP {
            return self.vector(i, t);
        }
        if op >= O_ADD && op <= O_NOT {
            if t.ty == T_I128 {
                return self.int128(i, t);
            }
            return self.int_op(i, t);
        }
        if op == O_CLZ || op == O_CTZ || op == O_POPCNT {
            return self.bit_count(i, t);
        }
        if op == O_ADDO || op == O_SUBO || op == O_MULO {
            return self.ovf(i, t);
        }
        if op == O_ICMP {
            return self.icmp(i, t);
        }
        if op == O_FCMP {
            return self.fcmp(i, t);
        }
        if op >= O_FADD && op <= O_FNEG {
            let d = t.ty == T_F64;
            if op == O_FNEG {
                self.get(t.a);
                self.c.op(
                    if d {
                        w::F64_NEG;
                    } else {
                        w::F32_NEG;
                    },
                );
            } else {
                self.get(t.a);
                self.get(t.b);
                let base = if d {
                    w::F64_ADD;
                } else {
                    w::F32_ADD;
                };
                self.c.op(base + (op - O_FADD));
            }
            self.put(i);
            return true;
        }
        if op >= O_SEXT && op <= O_INTTOPTR {
            return self.convert(i, t);
        }
        if op == O_PTRADD {
            self.get(t.a);
            if t.b != VNONE {
                self.get(t.b);
                if t.aux != 1 {
                    self.c.i32_const(t.aux);
                    self.c.op(w::I32_MUL);
                }
                self.c.op(w::I32_ADD);
            }
            if t.c != 0 {
                self.c.i32_const(t.c as i32);
                self.c.op(w::I32_ADD);
            }
            self.put(i);
            return true;
        }
        if op == O_LOAD || op == O_ALOAD {
            return self.load(i, t);
        }
        if op == O_STORE || op == O_ASTORE {
            return self.store(t);
        }
        if op == O_ARMW || op == O_ACAS {
            return self.atomic(i, t);
        }
        if op == O_FENCE || op == O_VAEND {
            return true;
        }
        if op == O_ASM {
            return self.asm_inst(t);
        }
        if op == O_MEMCPY || op == O_MEMSET {
            self.get(t.a);
            if op == O_MEMCPY {
                self.get(t.b);
            } else {
                self.get(t.b);
            }
            self.get(t.c);
            if self.vt(t.c) == T_I64 {
                self.c.op(w::I32_WRAP_I64);
            }
            let name = if op == O_MEMSET {
                "memset";
            } else if t.aux == MEM_OVERLAP {
                "memmove";
            } else {
                "memcpy";
            };
            self.call_rt(name, [w::I32, w::I32, w::I32], [w::I32]);
            self.c.op(w::DROP);
            return true;
        }
        if op == O_SELECT {
            return self.select_op(i, t);
        }
        if op == O_CALL || op == O_CALLIND {
            return self.call(i, t);
        }
        if op == O_VASTART {
            self.get(t.a);
            if self.va_local == NONE {
                return self.refuse("va_start in a function that is not variadic");
            }
            self.c.local(w::LOCAL_GET, self.va_local);
            self.store_op(T_PTR, 0);
            return true;
        }
        if op == O_VAARG {
            return self.va_arg(i, t);
        }
        return self.refuse("an instruction the wasm generator does not compile");
    }

    // The scalar integer operations O_ADD .. O_NOT.
    fn int_op(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let ty = t.ty;
        let wide = ty == T_I64;
        let signed = op == O_SDIV || op == O_SREM || op == O_ASHR;
        if op == O_NEG {
            if wide {
                self.c.i64_const(0);
            } else {
                self.c.i32_const(0);
            }
            self.get(t.a);
            self.c.op(
                if wide {
                    w::I64_SUB;
                } else {
                    w::I32_SUB;
                },
            );
        } else if op == O_NOT {
            self.get(t.a);
            if wide {
                self.c.i64_const(-1);
                self.c.op(w::I64_XOR);
            } else {
                self.c.i32_const(-1);
                self.c.op(w::I32_XOR);
            }
        } else {
            self.get_ext(t.a, signed);
            if op == O_ASHR {
                self.get(t.b);
            } else {
                self.get_ext(t.b, signed);
            }
            let k = op - O_ADD;
            // O_ADD .. O_ASHR in the order of i32.add .. i32.shr_u, but with `lshr` before `ashr`.
            let ops: []u8 = [
                w::I32_ADD,
                w::I32_SUB,
                w::I32_MUL,
                w::I32_DIV_S,
                w::I32_DIV_U,
                w::I32_REM_S,
                w::I32_REM_U,
                w::I32_AND,
                w::I32_OR,
                w::I32_XOR,
                w::I32_SHL,
                w::I32_SHR_U,
                w::I32_SHR_S,
            ];
            let o32 = ops[k as usize];
            self.c.op(
                if wide {
                    o32 + (w::I64_ADD - w::I32_ADD);
                } else {
                    o32;
                },
            );
        }
        let keeps = op == O_AND || op == O_OR || op == O_XOR || op == O_UDIV || op == O_UREM || op == O_LSHR;
        if !wide && !keeps {
            self.canon(ty);
        }
        self.put(i);
        return true;
    }

    fn bit_count(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let bits = type_bits(ty, 4);
        if ty == T_I64 {
            self.get(t.a);
            self.c.op(w::I64_CLZ + (t.op - O_CLZ));
        } else if t.op == O_CLZ {
            self.get(t.a);
            self.c.op(w::I32_CLZ);
            if bits < 32 {
                self.c.i32_const((32 - bits) as i32);
                self.c.op(w::I32_SUB);
            }
        } else if t.op == O_CTZ {
            self.get(t.a);
            if bits < 32 {
                self.c.i32_const((1u32 << bits) as i32);
                self.c.op(w::I32_OR);
            }
            self.c.op(w::I32_CTZ);
        } else {
            self.get(t.a);
            self.c.op(w::I32_POPCNT);
        }
        self.put(i);
        return true;
    }

    // A checked operation: its wrapped value and its flag (1 when the exact result does not fit).
    fn ovf(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let op = t.op;
        let signed = t.aux == OV_SIGNED;
        let fx = switch self.lv.flag_of.get(&i) {
            Some(k) => *k,
            None => NONE,
        };
        let fl = if fx == NONE {
            NONE;
        } else {
            self.local_of[fx as usize];
        };
        if ty == T_I64 && op == O_MULO {
            return self.mulo64(i, t, signed, fl);
        }
        let wide = ty == T_I64;
        let bits = type_bits(ty, 4);
        // An i32 product is exact in 64 bits.
        let big = op == O_MULO && bits == 32;
        let wt = if wide || big {
            w::I64;
        } else {
            w::I32;
        };
        let ra = self.tmp(wt);
        let rb = self.tmp(wt);
        let r = self.tmp(wt);
        if bits < 32 || big {
            // In 32 bits (a narrow type) or 64 (an i32 product): exact, then compared with its truncation.
            for q in 0..2 {
                let v = if q == 0 {
                    t.a;
                } else {
                    t.b;
                };
                self.get_ext(v, signed);
                if big {
                    self.c.op(
                        if signed {
                            w::I64_EXTEND_I32_S;
                        } else {
                            w::I64_EXTEND_I32_U;
                        },
                    );
                }
                self.c.local(
                    w::LOCAL_SET,
                    if q == 0 {
                        ra;
                    } else {
                        rb;
                    },
                );
            }
            let x = r;
            let big_r = big;
            self.c.local(w::LOCAL_GET, ra);
            self.c.local(w::LOCAL_GET, rb);
            let o = if op == O_ADDO {
                w::I32_ADD;
            } else if op == O_SUBO {
                w::I32_SUB;
            } else {
                w::I32_MUL;
            };
            self.c.op(
                if big_r {
                    o + (w::I64_ADD - w::I32_ADD);
                } else {
                    o;
                },
            );
            self.c.local(w::LOCAL_SET, x);
            if fl != NONE {
                // The exact value against its truncation, extended back.
                self.c.local(w::LOCAL_GET, x);
                if big_r {
                    self.c.local(w::LOCAL_GET, x);
                    self.c.op(w::I32_WRAP_I64);
                    self.c.op(
                        if signed {
                            w::I64_EXTEND_I32_S;
                        } else {
                            w::I64_EXTEND_I32_U;
                        },
                    );
                    self.c.op(w::I64_NE);
                } else {
                    self.c.local(w::LOCAL_GET, x);
                    self.canon(ty);
                    if signed {
                        self.sx(ty);
                    }
                    self.c.op(w::I32_NE);
                }
                self.c.local(w::LOCAL_SET, fl);
            }
            if self.local_of[i as usize] != NONE {
                self.c.local(w::LOCAL_GET, x);
                if big_r {
                    self.c.op(w::I32_WRAP_I64);
                } else {
                    self.canon(ty);
                }
                self.c.local(w::LOCAL_SET, self.local_of[i as usize]);
            }
            return true;
        }
        // 32 or 64 bits, add or subtract: the wrapped value, and the flag from its operands.
        self.get(t.a);
        self.c.local(w::LOCAL_TEE, ra);
        self.get(t.b);
        self.c.local(w::LOCAL_TEE, rb);
        let add = op == O_ADDO;
        let o = if add {
            w::I32_ADD;
        } else {
            w::I32_SUB;
        };
        let d = if wide {
            w::I64_ADD - w::I32_ADD;
        } else {
            0u8;
        };
        self.c.op(o + d);
        self.c.local(w::LOCAL_SET, r);
        if fl != NONE {
            if signed {
                // add: (a ^ r) & (b ^ r) < 0; sub: (a ^ b) & (a ^ r) < 0.
                self.c.local(w::LOCAL_GET, ra);
                self.c.local(
                    w::LOCAL_GET,
                    if add {
                        r;
                    } else {
                        rb;
                    },
                );
                self.c.op(w::I32_XOR + d);
                self.c.local(
                    w::LOCAL_GET,
                    if add {
                        rb;
                    } else {
                        ra;
                    },
                );
                self.c.local(w::LOCAL_GET, r);
                self.c.op(w::I32_XOR + d);
                self.c.op(w::I32_AND + d);
                if wide {
                    self.c.i64_const(0);
                    self.c.op(w::I64_LT_S);
                } else {
                    self.c.i32_const(0);
                    self.c.op(w::I32_LT_S);
                }
            } else if add {
                self.c.local(w::LOCAL_GET, r);
                self.c.local(w::LOCAL_GET, ra);
                self.c.op(
                    if wide {
                        w::I64_LT_U;
                    } else {
                        w::I32_LT_U;
                    },
                );
            } else {
                self.c.local(w::LOCAL_GET, ra);
                self.c.local(w::LOCAL_GET, rb);
                self.c.op(
                    if wide {
                        w::I64_LT_U;
                    } else {
                        w::I32_LT_U;
                    },
                );
            }
            self.c.local(w::LOCAL_SET, fl);
        }
        if self.local_of[i as usize] != NONE {
            self.c.local(w::LOCAL_GET, r);
            self.c.local(w::LOCAL_SET, self.local_of[i as usize]);
        }
        return true;
    }

    // A checked 64-bit product through compiler-rt: `__mulodi4` (signed), or the high word of `__multi3`.
    fn mulo64(self: &mut Self, i: u32, t: Inst, signed: bool, fl: u32) bool {
        let area = 0u32;
        if signed {
            self.get(t.a);
            self.get(t.b);
            self.c.local(w::LOCAL_GET, self.fp);
            if area != 0 {
                self.c.i32_const(area as i32);
                self.c.op(w::I32_ADD);
            }
            self.call_rt("__mulodi4", [w::I64, w::I64, w::I32], [w::I64]);
            self.put(i);
            if fl != NONE {
                self.c.local(w::LOCAL_GET, self.fp);
                self.load_op(T_I32, area);
                self.c.i32_const(0);
                self.c.op(w::I32_NE);
                self.c.local(w::LOCAL_SET, fl);
            }
            return true;
        }
        self.c.local(w::LOCAL_GET, self.fp);
        self.get(t.a);
        self.c.i64_const(0);
        self.get(t.b);
        self.c.i64_const(0);
        self.call_rt("__multi3", [w::I32, w::I64, w::I64, w::I64, w::I64], []);
        if self.local_of[i as usize] != NONE {
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(T_I64, area);
            self.c.local(w::LOCAL_SET, self.local_of[i as usize]);
        }
        if fl != NONE {
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(T_I64, area + 8);
            self.c.i64_const(0);
            self.c.op(w::I64_NE);
            self.c.local(w::LOCAL_SET, fl);
        }
        return true;
    }

    fn icmp(self: &mut Self, i: u32, t: Inst) bool {
        let ty = self.vt(t.a);
        let c = t.aux;
        let ops: []u8 = [
            w::I32_EQ,
            w::I32_NE,
            w::I32_LT_S,
            w::I32_LE_S,
            w::I32_GT_S,
            w::I32_GE_S,
            w::I32_LT_U,
            w::I32_LE_U,
            w::I32_GT_U,
            w::I32_GE_U,
        ];
        if ty == T_I128 {
            let al = self.tmp(w::I64);
            let ah = self.tmp(w::I64);
            let bl = self.tmp(w::I64);
            let bh = self.tmp(w::I64);
            self.mword(t.a, 0);
            self.c.local(w::LOCAL_SET, al);
            self.mword(t.a, 1);
            self.c.local(w::LOCAL_SET, ah);
            self.mword(t.b, 0);
            self.c.local(w::LOCAL_SET, bl);
            self.mword(t.b, 1);
            self.c.local(w::LOCAL_SET, bh);
            if c == C_EQ || c == C_NE {
                self.c.local(w::LOCAL_GET, al);
                self.c.local(w::LOCAL_GET, bl);
                self.c.op(w::I64_XOR);
                self.c.local(w::LOCAL_GET, ah);
                self.c.local(w::LOCAL_GET, bh);
                self.c.op(w::I64_XOR);
                self.c.op(w::I64_OR);
                self.c.op(w::I64_EQZ);
                if c == C_NE {
                    self.c.op(w::I32_EQZ);
                }
            } else {
                // The high words strictly, or equal high words and the low words unsigned.
                let strict: []u8 = [
                    0,
                    0,
                    w::I64_LT_S,
                    w::I64_LT_S,
                    w::I64_GT_S,
                    w::I64_GT_S,
                    w::I64_LT_U,
                    w::I64_LT_U,
                    w::I64_GT_U,
                    w::I64_GT_U,
                ];
                let low: []u8 = [
                    0,
                    0,
                    w::I64_LT_U,
                    w::I64_LE_U,
                    w::I64_GT_U,
                    w::I64_GE_U,
                    w::I64_LT_U,
                    w::I64_LE_U,
                    w::I64_GT_U,
                    w::I64_GE_U,
                ];
                self.c.local(w::LOCAL_GET, ah);
                self.c.local(w::LOCAL_GET, bh);
                self.c.op(strict[c as usize]);
                self.c.local(w::LOCAL_GET, ah);
                self.c.local(w::LOCAL_GET, bh);
                self.c.op(w::I64_EQ);
                self.c.local(w::LOCAL_GET, al);
                self.c.local(w::LOCAL_GET, bl);
                self.c.op(low[c as usize]);
                self.c.op(w::I32_AND);
                self.c.op(w::I32_OR);
            }
            self.put(i);
            return true;
        }
        let signed = c >= C_SLT && c <= C_SGE;
        self.get_ext(t.a, signed);
        self.get_ext(t.b, signed);
        let o = ops[c as usize];
        self.c.op(
            if ty == T_I64 {
                o + (w::I64_EQ - w::I32_EQ);
            } else {
                o;
            },
        );
        self.put(i);
        return true;
    }

    fn fcmp(self: &mut Self, i: u32, t: Inst) bool {
        let d = if self.vt(t.a) == T_F64 {
            w::F64_EQ - w::F32_EQ;
        } else {
            0u8;
        };
        let c = t.aux;
        if c == C_UNO {
            self.get(t.a);
            self.get(t.a);
            self.c.op(w::F32_NE + d);
            self.get(t.b);
            self.get(t.b);
            self.c.op(w::F32_NE + d);
            self.c.op(w::I32_OR);
        } else if c == C_ONE || c == C_UEQ {
            self.get(t.a);
            self.get(t.b);
            self.c.op(w::F32_LT + d);
            self.get(t.a);
            self.get(t.b);
            self.c.op(w::F32_GT + d);
            self.c.op(w::I32_OR);
            if c == C_UEQ {
                self.c.op(w::I32_EQZ);
            }
        } else {
            self.get(t.a);
            self.get(t.b);
            let o = if c == C_OEQ {
                w::F32_EQ;
            } else if c == C_UNE {
                w::F32_NE;
            } else if c == C_OLT {
                w::F32_LT;
            } else if c == C_OLE {
                w::F32_LE;
            } else if c == C_OGT {
                w::F32_GT;
            } else {
                w::F32_GE;
            };
            self.c.op(o + d);
        }
        self.put(i);
        return true;
    }

    // Conversions O_SEXT .. O_INTTOPTR between scalars, and those of i128.
    fn convert(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if op == O_BITCAST {
            return self.bitcast(i, t);
        }
        if from == T_I128 || to == T_I128 {
            return self.convert128(i, t);
        }
        if op == O_SEXT || op == O_ZEXT || op == O_TRUNC || op == O_PTRTOINT || op == O_INTTOPTR {
            self.get(t.a);
            let fw = from == T_I64;
            let tw = to == T_I64;
            if op == O_SEXT && !fw {
                self.sx(from);
            }
            if !fw && tw {
                self.c.op(
                    if op == O_SEXT {
                        w::I64_EXTEND_I32_S;
                    } else {
                        w::I64_EXTEND_I32_U;
                    },
                );
            } else if fw && !tw {
                self.c.op(w::I32_WRAP_I64);
            }
            if !tw {
                self.canon(to);
            }
            self.put(i);
            return true;
        }
        if op == O_FPEXT || op == O_FPTRUNC {
            self.get(t.a);
            self.c.op(
                if op == O_FPEXT {
                    w::F64_PROMOTE_F32;
                } else {
                    w::F32_DEMOTE_F64;
                },
            );
            self.put(i);
            return true;
        }
        if op == O_SITOFP || op == O_UITOFP {
            let s = op == O_SITOFP;
            self.get_ext(t.a, s);
            let base = if to == T_F32 {
                w::F32_CONVERT_I32_S;
            } else {
                w::F64_CONVERT_I32_S;
            };
            // _i32_s, _i32_u, _i64_s, _i64_u in order.
            let k = pick8(from == T_I64, 2, 0) + pick8(s, 0, 1);
            self.c.op(base + k);
            self.put(i);
            return true;
        }
        return self.fp_to_int(i, t);
    }

    // A float to an integer: truncated, saturating (NaN is 0) unless unchecked, as the evaluator converts.
    fn fp_to_int(self: &mut Self, i: u32, t: Inst) bool {
        let fd = self.vt(t.a) == T_F64;
        let x = self.tmp(pick8(fd, w::F64, w::F32));
        self.get(t.a);
        self.c.local(w::LOCAL_SET, x);
        self.trunc_sat(x, fd, t.ty, t.op == O_FPTOSI, t.aux == CV_UNCHECKED);
        self.put(i);
        return true;
    }

    // Push float local `x` (f64 when `fd`) truncated to integer type `to` (signed `signed`): an i64 for
    // i64, else an i32 holding the canonical value. Saturating, NaN to 0, unless `unchecked`.
    fn trunc_sat(self: &mut Self, x: u32, fd: bool, to: u8, signed: bool, unchecked: bool) {
        let tb = type_bits(to, 4);
        let wide = to == T_I64;
        // The truncation: to i32 (signed for a narrow type, which fits either way) or i64.
        let tr = if wide {
            pick8(fd, w::I64_TRUNC_F64_S, w::I64_TRUNC_F32_S) + pick8(signed, 0, 1);
        } else {
            pick8(fd, w::I32_TRUNC_F64_S, w::I32_TRUNC_F32_S) + pick8(signed || tb < 32, 0, 1);
        };
        if unchecked {
            self.c.local(w::LOCAL_GET, x);
            self.c.op(tr);
            if !wide {
                self.canon(to);
            }
            return;
        }
        let rt = pick8(wide, w::I64, w::I32);
        let lo: f64 = if signed {
            -fpow2(tb - 1);
        } else {
            0.0;
        };
        let hi: f64 = if signed {
            fpow2(tb - 1);
        } else {
            fpow2(tb);
        };
        let mn: u64 = if signed {
            (1u64 << (tb - 1) as u64).wrapping_neg();
        } else {
            0;
        };
        let mx: u64 = if signed {
            (1u64 << (tb - 1) as u64) - 1;
        } else {
            trunc_to(~0u64, tb);
        };
        // NaN: 0.
        self.c.local(w::LOCAL_GET, x);
        self.c.local(w::LOCAL_GET, x);
        self.c.op(pick8(fd, w::F64_NE, w::F32_NE));
        self.c.op(w::IF);
        self.c.op(rt);
        self.int_const(wide, 0);
        self.c.op(w::ELSE);
        // At or below lo - 1: the minimum. The bounds compare in f64, where they are exact.
        self.c.local(w::LOCAL_GET, x);
        if !fd {
            self.c.op(w::F64_PROMOTE_F32);
        }
        self.c.f64_const(f64_bits(lo - 1.0));
        self.c.op(w::F64_LE);
        self.c.op(w::IF);
        self.c.op(rt);
        self.int_const(wide, trunc_to(mn, tb));
        self.c.op(w::ELSE);
        self.c.local(w::LOCAL_GET, x);
        if !fd {
            self.c.op(w::F64_PROMOTE_F32);
        }
        self.c.f64_const(f64_bits(hi));
        self.c.op(w::F64_GE);
        self.c.op(w::IF);
        self.c.op(rt);
        self.int_const(wide, trunc_to(mx, tb));
        self.c.op(w::ELSE);
        self.c.local(w::LOCAL_GET, x);
        self.c.op(tr);
        if !wide {
            self.canon(to);
        }
        self.c.op(w::END);
        self.c.op(w::END);
        self.c.op(w::END);
    }

    // An i32 (or i64 when `wide`) constant of bits `v`.
    fn int_const(self: &mut Self, wide: bool, v: u64) {
        if wide {
            self.c.i64_const(v as i64);
        } else {
            self.c.i32_const((v as u32) as i32);
        }
    }

    fn bitcast(self: &mut Self, i: u32, t: Inst) bool {
        let from = self.vt(t.a);
        let to = t.ty;
        let mf = in_mem(from);
        let mt = in_mem(to);
        if mf && mt {
            if self.home[i as usize] != NONE {
                let n = type_bytes(to, 4);
                let d = self.home[i as usize];
                let s = self.mhome(t.a);
                if d != s {
                    self.copy_mem(self.fp, d, self.fp, s, n);
                }
            }
            return true;
        }
        if mf {
            let s = self.mhome(t.a);
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(to, s);
            self.put(i);
            return true;
        }
        if mt {
            if self.home[i as usize] != NONE {
                self.c.local(w::LOCAL_GET, self.fp);
                self.get(t.a);
                self.store_op(from, self.home[i as usize]);
            }
            return true;
        }
        self.get(t.a);
        if from == T_F32 && to != T_F32 {
            self.c.op(w::I32_REINTERPRET_F32);
        } else if from == T_F64 && to != T_F64 {
            self.c.op(w::I64_REINTERPRET_F64);
        } else if to == T_F32 && from != T_F32 {
            self.c.op(w::F32_REINTERPRET_I32);
        } else if to == T_F64 && from != T_F64 {
            self.c.op(w::F64_REINTERPRET_I64);
        }
        self.put(i);
        return true;
    }

    fn convert128(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let from = self.vt(t.a);
        let to = t.ty;
        if op == O_SEXT || op == O_ZEXT {
            if self.home[i as usize] == NONE {
                return true;
            }
            let h = self.home[i as usize];
            let lo = self.tmp(w::I64);
            self.get(t.a);
            if from != T_I64 {
                if op == O_SEXT {
                    self.sx(from);
                }
                self.c.op(
                    if op == O_SEXT {
                        w::I64_EXTEND_I32_S;
                    } else {
                        w::I64_EXTEND_I32_U;
                    },
                );
            }
            self.c.local(w::LOCAL_SET, lo);
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.local(w::LOCAL_GET, lo);
            self.store_op(T_I64, h);
            self.c.local(w::LOCAL_GET, self.fp);
            if op == O_SEXT {
                self.c.local(w::LOCAL_GET, lo);
                self.c.i64_const(63);
                self.c.op(w::I64_SHR_S);
            } else {
                self.c.i64_const(0);
            }
            self.store_op(T_I64, h + 8);
            return true;
        }
        if op == O_TRUNC {
            self.mword(t.a, 0);
            if to != T_I64 {
                self.c.op(w::I32_WRAP_I64);
                self.canon(to);
            }
            self.put(i);
            return true;
        }
        let d = to == T_F64;
        let fd = from == T_F64;
        if op == O_SITOFP || op == O_UITOFP {
            let name = if op == O_SITOFP && d {
                "__floattidf";
            } else if op == O_SITOFP {
                "__floattisf";
            } else if d {
                "__floatuntidf";
            } else {
                "__floatuntisf";
            };
            self.mword(t.a, 0);
            self.mword(t.a, 1);
            let rt = if d {
                w::F64;
            } else {
                w::F32;
            };
            self.call_rt(name, [w::I64, w::I64], [rt]);
            self.put(i);
            return true;
        }
        let name = if op == O_FPTOSI && fd {
            "__fixdfti";
        } else if op == O_FPTOSI {
            "__fixsfti";
        } else if fd {
            "__fixunsdfti";
        } else {
            "__fixunssfti";
        };
        let h = self.home[i as usize];
        self.c.local(w::LOCAL_GET, self.fp);
        if h != NONE && h != 0 {
            self.c.i32_const(h as i32);
            self.c.op(w::I32_ADD);
        }
        self.get(t.a);
        let ft = if fd {
            w::F64;
        } else {
            w::F32;
        };
        self.call_rt(name, [w::I32, ft], []);
        return true;
    }

    // An i128 operation on the halves, or through compiler-rt.
    fn int128(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        let h = self.home[i as usize];
        if h == NONE {
            return true;
        }
        if op == O_MUL || op >= O_SDIV && op <= O_UREM {
            let name = if op == O_MUL {
                "__multi3";
            } else if op == O_SDIV {
                "__divti3";
            } else if op == O_UDIV {
                "__udivti3";
            } else if op == O_SREM {
                "__modti3";
            } else {
                "__umodti3";
            };
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.i32_const(h as i32);
            self.c.op(w::I32_ADD);
            self.mword(t.a, 0);
            self.mword(t.a, 1);
            self.mword(t.b, 0);
            self.mword(t.b, 1);
            self.call_rt(name, [w::I32, w::I64, w::I64, w::I64, w::I64], []);
            return true;
        }
        let al = self.tmp(w::I64);
        let ah = self.tmp(w::I64);
        let bl = self.tmp(w::I64);
        let bh = self.tmp(w::I64);
        let rl = self.tmp(w::I64);
        let rh = self.tmp(w::I64);
        self.mword(t.a, 0);
        self.c.local(w::LOCAL_SET, al);
        self.mword(t.a, 1);
        self.c.local(w::LOCAL_SET, ah);
        if op != O_NEG && op != O_NOT {
            self.mword(t.b, 0);
            self.c.local(w::LOCAL_SET, bl);
            if op < O_SHL || op > O_ASHR {
                self.mword(t.b, 1);
                self.c.local(w::LOCAL_SET, bh);
            }
        }
        if op == O_ADD || op == O_SUB {
            let add = op == O_ADD;
            self.c.local(w::LOCAL_GET, al);
            self.c.local(w::LOCAL_GET, bl);
            self.c.op(
                if add {
                    w::I64_ADD;
                } else {
                    w::I64_SUB;
                },
            );
            self.c.local(w::LOCAL_SET, rl);
            self.c.local(w::LOCAL_GET, ah);
            self.c.local(w::LOCAL_GET, bh);
            self.c.op(
                if add {
                    w::I64_ADD;
                } else {
                    w::I64_SUB;
                },
            );
            // The carry (rl < al) or the borrow (al < bl).
            if add {
                self.c.local(w::LOCAL_GET, rl);
                self.c.local(w::LOCAL_GET, al);
            } else {
                self.c.local(w::LOCAL_GET, al);
                self.c.local(w::LOCAL_GET, bl);
            }
            self.c.op(w::I64_LT_U);
            self.c.op(w::I64_EXTEND_I32_U);
            self.c.op(
                if add {
                    w::I64_ADD;
                } else {
                    w::I64_SUB;
                },
            );
            self.c.local(w::LOCAL_SET, rh);
        } else if op == O_AND || op == O_OR || op == O_XOR {
            let o = if op == O_AND {
                w::I64_AND;
            } else if op == O_OR {
                w::I64_OR;
            } else {
                w::I64_XOR;
            };
            self.c.local(w::LOCAL_GET, al);
            self.c.local(w::LOCAL_GET, bl);
            self.c.op(o);
            self.c.local(w::LOCAL_SET, rl);
            self.c.local(w::LOCAL_GET, ah);
            self.c.local(w::LOCAL_GET, bh);
            self.c.op(o);
            self.c.local(w::LOCAL_SET, rh);
        } else if op == O_NOT {
            self.c.local(w::LOCAL_GET, al);
            self.c.i64_const(-1);
            self.c.op(w::I64_XOR);
            self.c.local(w::LOCAL_SET, rl);
            self.c.local(w::LOCAL_GET, ah);
            self.c.i64_const(-1);
            self.c.op(w::I64_XOR);
            self.c.local(w::LOCAL_SET, rh);
        } else if op == O_NEG {
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, al);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_SET, rl);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, ah);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_GET, al);
            self.c.i64_const(0);
            self.c.op(w::I64_NE);
            self.c.op(w::I64_EXTEND_I32_U);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_SET, rh);
        } else {
            self.shift128(op, al, ah, bl, rl, rh);
        }
        self.c.local(w::LOCAL_GET, self.fp);
        self.c.local(w::LOCAL_GET, rl);
        self.store_op(T_I64, h);
        self.c.local(w::LOCAL_GET, self.fp);
        self.c.local(w::LOCAL_GET, rh);
        self.store_op(T_I64, h + 8);
        return true;
    }

    // `rl`, `rh` = (`al`, `ah`) shifted by `n` (below 128): the form below 64 bits, replaced at 64 and above.
    // `(x >> 1) >> (63 - n)` is `x >> (64 - n)` that stays 0 at n = 0.
    fn shift128(self: &mut Self, op: u8, al: u32, ah: u32, n: u32, rl: u32, rh: u32) {
        let left = op == O_SHL;
        let sh_hi = if op == O_ASHR {
            w::I64_SHR_S;
        } else {
            w::I64_SHR_U;
        };
        if left {
            self.c.local(w::LOCAL_GET, al);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(w::I64_SHL);
            self.c.local(w::LOCAL_SET, rl);
            self.c.local(w::LOCAL_GET, ah);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(w::I64_SHL);
            self.c.local(w::LOCAL_GET, al);
            self.c.i64_const(1);
            self.c.op(w::I64_SHR_U);
            self.c.i64_const(63);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(w::I64_SUB);
            self.c.op(w::I64_SHR_U);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, rh);
        } else {
            self.c.local(w::LOCAL_GET, al);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(w::I64_SHR_U);
            self.c.local(w::LOCAL_GET, ah);
            self.c.i64_const(1);
            self.c.op(w::I64_SHL);
            self.c.i64_const(63);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(w::I64_SUB);
            self.c.op(w::I64_SHL);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, rl);
            self.c.local(w::LOCAL_GET, ah);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(sh_hi);
            self.c.local(w::LOCAL_SET, rh);
        }
        // 64 and above: one word moves, shifted by n - 64 (the count wasm takes modulo 64).
        self.c.local(w::LOCAL_GET, n);
        self.c.i64_const(64);
        self.c.op(w::I64_GE_U);
        self.c.op(w::IF);
        self.c.op(w::BLOCK_EMPTY);
        if left {
            self.c.local(w::LOCAL_GET, al);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(w::I64_SHL);
            self.c.local(w::LOCAL_SET, rh);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, rl);
        } else {
            self.c.local(w::LOCAL_GET, ah);
            self.c.local(w::LOCAL_GET, n);
            self.c.op(sh_hi);
            self.c.local(w::LOCAL_SET, rl);
            if op == O_ASHR {
                self.c.local(w::LOCAL_GET, ah);
                self.c.i64_const(63);
                self.c.op(w::I64_SHR_S);
            } else {
                self.c.i64_const(0);
            }
            self.c.local(w::LOCAL_SET, rh);
        }
        self.c.op(w::END);
    }

    fn load(self: &mut Self, i: u32, t: Inst) bool {
        let off = t.c as i32;
        let al = if t.op == O_LOAD {
            (t.aux & 15) as u32;
        } else {
            15u32;
        };
        if in_mem(t.ty) {
            if self.home[i as usize] == NONE {
                return true;
            }
            let a = self.tmp(w::I32);
            self.addr_into(t.a, off, a);
            self.copy_mem(self.fp, self.home[i as usize], a, 0, type_bytes(t.ty, 4));
            return true;
        }
        if off >= 0 {
            self.get(t.a);
            self.load_al(t.ty, off as u32, al);
        } else {
            self.get(t.a);
            self.c.i32_const(off);
            self.c.op(w::I32_ADD);
            self.load_al(t.ty, 0, al);
        }
        self.put(i);
        return true;
    }

    // Local `a` = the address in `v` plus `off`.
    fn addr_into(self: &mut Self, v: Value, off: i32, a: u32) {
        self.get(v);
        if off != 0 {
            self.c.i32_const(off);
            self.c.op(w::I32_ADD);
        }
        self.c.local(w::LOCAL_SET, a);
    }

    fn store(self: &mut Self, t: Inst) bool {
        let off = t.c as i32;
        let vt = self.vt(t.b);
        let al = if t.op == O_STORE {
            (t.aux & 15) as u32;
        } else {
            15u32;
        };
        if in_mem(vt) {
            let a = self.tmp(w::I32);
            self.addr_into(t.a, off, a);
            let h = self.mhome(t.b);
            self.copy_mem(a, 0, self.fp, h, type_bytes(vt, 4));
            return true;
        }
        self.get(t.a);
        let mut o: u32 = 0;
        if off >= 0 {
            o = off as u32;
        } else {
            self.c.i32_const(off);
            self.c.op(w::I32_ADD);
        }
        self.get(t.b);
        self.store_al(vt, o, al);
        return true;
    }

    // O_ARMW and O_ACAS: plain memory operations (no threads).
    fn atomic(self: &mut Self, i: u32, t: Inst) bool {
        let ty = if t.op == O_ACAS {
            self.vt(t.b);
        } else {
            t.ty;
        };
        let wide = ty == T_I64;
        let wt = if wide {
            w::I64;
        } else {
            w::I32;
        };
        let off = if t.op == O_ARMW {
            t.c as i32;
        } else {
            0;
        };
        let a = self.tmp(w::I32);
        self.addr_into(t.a, off, a);
        let old = self.tmp(wt);
        self.c.local(w::LOCAL_GET, a);
        self.load_op(ty, 0);
        self.c.local(w::LOCAL_SET, old);
        if t.op == O_ACAS {
            let hit = self.tmp(w::I32);
            self.c.local(w::LOCAL_GET, old);
            self.get(t.b);
            self.c.op(
                if wide {
                    w::I64_EQ;
                } else {
                    w::I32_EQ;
                },
            );
            self.c.local(w::LOCAL_TEE, hit);
            self.c.op(w::IF);
            self.c.op(w::BLOCK_EMPTY);
            self.c.local(w::LOCAL_GET, a);
            self.get(t.c);
            self.store_op(ty, 0);
            self.c.op(w::END);
            self.c.local(w::LOCAL_GET, hit);
            self.put(i);
            return true;
        }
        let r = t.aux >> 4;
        self.c.local(w::LOCAL_GET, a);
        if r == RMW_XCHG {
            self.get(t.b);
        } else {
            self.c.local(w::LOCAL_GET, old);
            self.get(t.b);
            let o = if r == RMW_ADD {
                w::I32_ADD;
            } else if r == RMW_SUB {
                w::I32_SUB;
            } else if r == RMW_AND {
                w::I32_AND;
            } else if r == RMW_OR {
                w::I32_OR;
            } else {
                w::I32_XOR;
            };
            self.c.op(
                if wide {
                    o + (w::I64_ADD - w::I32_ADD);
                } else {
                    o;
                },
            );
        }
        self.store_op(ty, 0);
        self.c.local(w::LOCAL_GET, old);
        self.put(i);
        return true;
    }

    fn select_op(self: &mut Self, i: u32, t: Inst) bool {
        if in_mem(t.ty) {
            let d = self.home[i as usize];
            if d == NONE {
                return true;
            }
            let n = type_bytes(t.ty, 4);
            let hb = self.mhome(t.b);
            let hc = self.mhome(t.c);
            self.get(t.a);
            self.c.op(w::IF);
            self.c.op(w::BLOCK_EMPTY);
            if d != hb {
                self.copy_mem(self.fp, d, self.fp, hb, n);
            }
            self.c.op(w::ELSE);
            if d != hc {
                self.copy_mem(self.fp, d, self.fp, hc, n);
            }
            self.c.op(w::END);
            return true;
        }
        self.get(t.b);
        self.get(t.c);
        self.get(t.a);
        self.c.op(w::SELECT);
        self.put(i);
        return true;
    }

    fn va_arg(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let (sz, al) = if ty == T_I128 {
            (16u32, 16u32);
        } else {
            (ast_max(type_bytes(ty, 4), 4), ast_max(type_align(ty, 4), 4));
        };
        let la = self.tmp(w::I32);
        let pa = self.tmp(w::I32);
        self.get(t.a);
        self.c.local(w::LOCAL_TEE, la);
        self.load_op(T_PTR, 0);
        if al > 4 {
            self.c.i32_const((al - 1) as i32);
            self.c.op(w::I32_ADD);
            self.c.i32_const(-(al as i32));
            self.c.op(w::I32_AND);
        }
        self.c.local(w::LOCAL_SET, pa);
        if in_mem(ty) {
            if self.home[i as usize] != NONE {
                self.copy_mem(self.fp, self.home[i as usize], pa, 0, sz);
            }
        } else {
            self.c.local(w::LOCAL_GET, pa);
            self.load_op(ty, 0);
            self.put(i);
        }
        self.c.local(w::LOCAL_GET, la);
        self.c.local(w::LOCAL_GET, pa);
        self.c.i32_const(sz as i32);
        self.c.op(w::I32_ADD);
        self.store_op(T_PTR, 0);
        return true;
    }
}

// 2^k as an f64 (k at most 64).
const fn fpow2(k: u32) f64 {
    let mut x: f64 = 1.0;
    for _ in 0..k {
        x = x * 2.0;
    }
    return x;
}

const fn f64_bits(x: f64) u64 {
    return unsafe *(((&x) as *const f64) as *const u64);
}

// `v` truncated to `bits` bits.
const fn trunc_to(v: u64, bits: u32) u64 {
    if bits >= 64 {
        return v;
    }
    return v & (1u64 << bits as u64) - 1;
}

// ---- Control flow ----

extend Gen {
    // Whether a branch from block `s` to block `t` is a `br`: a back edge, or to a merge node.
    const fn brable(self: &Self, s: u32, t: u32) bool {
        return self.sh.back(s, t) || self.sh.merge(t);
    }

    // The `br` depth of the label a branch to block `t` takes (`back`: the loop it heads).
    fn depth(self: &mut Self, t: u32, back: bool) u32 {
        let kind = if back {
            LB_LOOP;
        } else {
            LB_BLOCK;
        };
        let n = self.labels.len();
        for q in 0..n {
            let l = self.labels[n - 1 - q];
            if l.kind == kind && l.blk == t {
                return q as u32;
            }
        }
        let _ = self.refuse("internal: a branch to a block no label encloses");
        return 0;
    }

    fn open(self: &mut Self, op: u8, kind: u8, blk: u32) {
        self.c.op(op);
        self.c.op(w::BLOCK_EMPTY);
        self.labels.push(Label { kind: kind, blk: blk });
    }

    fn task(self: &mut Self, tk: Task) bool {
        if tk.kind == TK_TREE {
            let x = tk.a;
            let n = self.mk_at[x as usize + 1] - self.mk_at[x as usize];
            if self.sh.header[x as usize] {
                self.open(w::LOOP, LB_LOOP, x);
                self.tasks.push(Task { kind: TK_END, a: 0, b: 0, x: 0 });
            }
            self.tasks.push(Task { kind: TK_WITHIN, a: x, b: n, x: 0 });
            return true;
        }
        if tk.kind == TK_WITHIN {
            let x = tk.a;
            if tk.b != 0 {
                // The highest-numbered remaining merge child follows a block around the rest.
                let y = self.mk[(self.mk_at[x as usize] + tk.b - 1) as usize];
                self.open(w::BLOCK, LB_BLOCK, y);
                self.tasks.push(Task { kind: TK_TREE, a: y, b: 0, x: 0 });
                self.tasks.push(Task { kind: TK_END, a: 0, b: 0, x: 0 });
                self.tasks.push(Task { kind: TK_WITHIN, a: x, b: tk.b - 1, x: 0 });
                return true;
            }
            return self.block_code(x);
        }
        if tk.kind == TK_END {
            self.c.op(w::END);
            let _ = self.labels.pop();
            return true;
        }
        if tk.kind == TK_EDGE {
            return self.edge(tk.a, tk.b);
        }
        return self.switch_case(tk.x, tk.a, tk.b);
    }

    // The instructions of block `x`, then its terminator.
    fn block_code(self: &mut Self, x: u32) bool {
        let blk = self.b().blocks[x as usize];
        let dbg = self.p().debug;
        for i in blk.start..blk.start + blk.len - 1 {
            if dbg {
                self.row(self.b().locs[i as usize]);
            }
            if !self.inst(i) {
                return false;
            }
            self.end_inst();
        }
        let ti = blk.start + blk.len - 1;
        if dbg {
            self.row(self.b().locs[ti as usize]);
        }
        let ok = self.terminator(x, ti);
        self.end_inst();
        return ok;
    }

    // A line row at the next code byte for location `loc` (a `lines` index) when it differs from the last.
    fn row(self: &mut Self, loc: u32) {
        let n = self.rows.len();
        if loc == 0 || n != 0 && (self.rows[n - 1] & 0xFFFFFFFF) as u32 == loc {
            return;
        }
        let at = self.c.bytes.len() as u64 << 32;
        if n != 0 && self.rows[n - 1] >> 32 == at >> 32 {
            self.rows[n - 1] = at | loc as u64;
            return;
        }
        self.rows.push(at | loc as u64);
    }

    // Edge `e` of block `s`: the target's parameters, then a `br`, or the target's code inline.
    fn edge(self: &mut Self, s: u32, e: u32) bool {
        let t = self.b().edge_target(e);
        self.moves(e);
        if self.brable(s, t) {
            let d = self.depth(t, self.sh.back(s, t));
            self.c.op(w::BR);
            self.c.uleb(d);
            return true;
        }
        self.tasks.push(Task { kind: TK_TREE, a: t, b: 0, x: 0 });
        return true;
    }

    // The arguments of edge `e` into its target's parameters, as one parallel move: the scalars through the
    // stack, the memory values through the call area when several move.
    fn moves(self: &mut Self, e: u32) {
        let b = self.b();
        let t = b.edge_target(e);
        let blk = b.blocks[t as usize];
        let n = b.edge_nargs(e);
        let ni = b.insts.len() as u32;
        let mut nmem: u32 = 0;
        for k in 0..n {
            if in_mem(self.vt(b.edge_arg(e, k))) {
                nmem += 1;
            }
        }
        for k in 0..n {
            let a = b.edge_arg(e, k);
            if !in_mem(self.vt(a)) {
                self.get(a);
            }
        }
        let mut k = n;
        while k > 0 {
            k -= 1;
            let a = b.edge_arg(e, k);
            if in_mem(self.vt(a)) {
                continue;
            }
            let x = ni + blk.param_start + k;
            let l = self.local_of[x as usize];
            if l == NONE {
                self.c.op(w::DROP);
            } else {
                self.c.local(w::LOCAL_SET, l);
            }
        }
        if nmem == 0 {
            return;
        }
        // Memory values: straight when one moves, else every source to the call area first.
        let mut at: u32 = 0;
        for k in 0..n {
            let a = b.edge_arg(e, k);
            let ty = self.vt(a);
            if !in_mem(ty) {
                continue;
            }
            let src = self.mhome(a);
            let dst = self.home[(ni + blk.param_start + k) as usize];
            let sz = type_bytes(ty, 4);
            if dst == NONE {
                continue;
            }
            if nmem == 1 {
                if src != dst {
                    self.copy_mem(self.fp, dst, self.fp, src, sz);
                }
                return;
            }
            self.copy_mem(self.fp, at, self.fp, src, sz);
            at += sz + 15 & ~15u32;
        }
        at = 0;
        for k in 0..n {
            let a = b.edge_arg(e, k);
            let ty = self.vt(a);
            if !in_mem(ty) {
                continue;
            }
            let dst = self.home[(ni + blk.param_start + k) as usize];
            let sz = type_bytes(ty, 4);
            if dst == NONE {
                continue;
            }
            self.copy_mem(self.fp, dst, self.fp, at, sz);
            at += sz + 15 & ~15u32;
        }
    }

    fn terminator(self: &mut Self, x: u32, i: u32) bool {
        let b = self.b();
        let t = b.insts[i as usize];
        let op = t.op;
        if op == O_JMP {
            return self.edge(x, t.a);
        }
        if op == O_BR {
            let tt = b.edge_target(t.b);
            let tf = b.edge_target(t.c);
            if self.brable(x, tt) && b.edge_nargs(t.b) == 0 {
                self.get(t.a);
                let d = self.depth(tt, self.sh.back(x, tt));
                self.c.op(w::BR_IF);
                self.c.uleb(d);
                return self.edge(x, t.c);
            }
            if self.brable(x, tf) && b.edge_nargs(t.c) == 0 {
                self.get(t.a);
                self.c.op(w::I32_EQZ);
                let d = self.depth(tf, self.sh.back(x, tf));
                self.c.op(w::BR_IF);
                self.c.uleb(d);
                return self.edge(x, t.b);
            }
            // The true edge inside an `if`; the false one after it.
            self.get(t.a);
            self.open(w::IF, LB_IF, NONE);
            self.tasks.push(Task { kind: TK_EDGE, a: x, b: t.c, x: 0 });
            self.tasks.push(Task { kind: TK_END, a: 0, b: 0, x: 0 });
            return self.edge(x, t.b);
        }
        if op == O_SWITCH {
            let (lo, span) = self.table_span(t);
            if span != 0 {
                return self.switch_table(x, i, lo, span);
            }
            return self.switch_case(x, i, 0);
        }
        if op == O_RET {
            return self.ret(t);
        }
        if op == O_PANIC {
            let p = self.p();
            let m = p.spell(p.msgs[b.msgs[t.a as usize] as usize]);
            let k = self.cstr(m);
            if t.b == VNONE {
                self.data_addr(k, 0);
                self.call_rt("__sc_panic", [w::I32], []);
            } else {
                // The lowest set lane of the mask.
                self.get(t.b);
                if self.vt(t.b) == T_I64 {
                    self.c.op(w::I64_CTZ);
                } else {
                    self.c.op(w::I32_CTZ);
                    self.c.op(w::I64_EXTEND_I32_U);
                }
                self.data_addr(k, 0);
                self.call_rt("__sc_lane_panic", [w::I64, w::I32], []);
            }
            self.c.op(w::UNREACHABLE);
            return true;
        }
        if op == O_UNREACHABLE {
            self.c.op(w::UNREACHABLE);
            return true;
        }
        return self.refuse("internal: a terminator the verifier rejects");
    }

    // The cases of switch instruction `i` from case `k`: a compare and a `br_if` per case that branches with
    // no arguments, an `if` around the others, the default edge last.
    fn switch_case(self: &mut Self, x: u32, i: u32, k0: u32) bool {
        let b = self.b();
        let t = b.insts[i as usize];
        let ty = self.vt(t.a);
        let wide = ty == T_I64;
        let bits = type_bits(ty, 4);
        let n = t.aux as u32;
        let mut k = k0;
        // Each case is compared once.
        while k < n {
            let e = b.switch_edge(t, k);
            let tg = b.edge_target(e);
            let cv = trunc_to(b.words[(t.b + k) as usize], bits);
            self.get(t.a);
            self.int_const(wide, cv);
            self.c.op(
                if wide {
                    w::I64_EQ;
                } else {
                    w::I32_EQ;
                },
            );
            if self.brable(x, tg) && b.edge_nargs(e) == 0 {
                let d = self.depth(tg, self.sh.back(x, tg));
                self.c.op(w::BR_IF);
                self.c.uleb(d);
                k += 1;
                continue;
            }
            self.open(w::IF, LB_IF, NONE);
            self.tasks.push(Task { kind: TK_SWITCH, a: i, b: k + 1, x: x });
            self.tasks.push(Task { kind: TK_END, a: 0, b: 0, x: 0 });
            return self.edge(x, e);
        }
        return self.edge(x, b.switch_edge(t, n));
    }

    // The lowest case value of switch `t` and the span to its highest, when a table over them is dense: 4
    // cases or more, the span at most 4 times their count. A span of 0 otherwise.
    fn table_span(self: &Self, t: Inst) (u64, u32) {
        let b = self.b();
        let n = t.aux as u32;
        if n < 4 {
            return 0, 0;
        }
        let bits = type_bits(self.vt(t.a), 4);
        let mut lo = 0xFFFFFFFFFFFFFFFFu64;
        let mut hi: u64 = 0;
        for k in 0..n {
            let v = trunc_to(b.words[(t.b + k) as usize], bits);
            if v < lo {
                lo = v;
            }
            if v > hi {
                hi = v;
            }
        }
        if hi - lo >= 4 * n as u64 {
            return 0, 0;
        }
        return lo, (hi - lo) as u32 + 1;
    }

    // Switch instruction `i` of block `x` through one `br_table` indexed by its value less `lo` (the
    // lowest case; `span` entries): an entry whose edge takes no argument to a label already open branches
    // there, any other edge takes a block, the innermost first, after whose end its moves and its target
    // follow. A value off the table takes the default edge.
    fn switch_table(self: &mut Self, x: u32, i: u32, lo: u64, span: u32) bool {
        let b = self.b();
        let t = b.insts[i as usize];
        let n = t.aux as u32;
        let ty = self.vt(t.a);
        let wide = ty == T_I64;
        let bits = type_bits(ty, 4);
        lv::fill(&mut self.sw_tab, span as usize, n);
        // A later case of an equal value never matches, as in a chain of compares.
        let mut k = n;
        while k > 0 {
            k -= 1;
            self.sw_tab[(trunc_to(b.words[(t.b + k) as usize], bits) - lo) as usize] = k;
        }
        lv::fill(&mut self.sw_blk, n as usize + 1, NONE);
        self.sw_case.truncate(0);
        for c in 0..n + 1 {
            let e = b.switch_edge(t, c);
            let tg = b.edge_target(e);
            if !self.brable(x, tg) || b.edge_nargs(e) != 0 {
                self.sw_blk[c as usize] = self.sw_case.len() as u32;
                self.sw_case.push(c);
            }
        }
        let m = self.sw_case.len() as u32;
        for _ in 0..m {
            self.open(w::BLOCK, LB_IF, NONE);
        }
        self.get(t.a);
        if wide {
            let d = self.tmp(w::I64);
            self.c.i64_const(lo as i64);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_TEE, d);
            self.c.op(w::I32_WRAP_I64);
            self.c.i32_const(span as i32);
            self.c.local(w::LOCAL_GET, d);
            self.c.i64_const(span);
            self.c.op(w::I64_LT_U);
            self.c.op(w::SELECT);
        } else if lo != 0 {
            self.c.i32_const((lo as u32) as i32);
            self.c.op(w::I32_SUB);
        }
        self.c.op(w::BR_TABLE);
        self.c.uleb(span);
        for q in 0..span + 1 {
            let c = if q < span {
                self.sw_tab[q as usize];
            } else {
                n;
            };
            let d = if self.sw_blk[c as usize] != NONE {
                self.sw_blk[c as usize];
            } else {
                let tg = b.edge_target(b.switch_edge(t, c));
                self.depth(tg, self.sh.back(x, tg));
            };
            self.c.uleb(d);
        }
        // Run last pushed first: the innermost block's end and its edge first.
        let mut j = m;
        while j > 0 {
            j -= 1;
            self.tasks.push(Task { kind: TK_EDGE, a: x, b: b.switch_edge(t, self.sw_case[j as usize]), x: 0 });
            self.tasks.push(Task { kind: TK_END, a: 0, b: 0, x: 0 });
        }
        return true;
    }

    // Return: the result where the convention returns it, the stack pointer restored.
    fn ret(self: &mut Self, t: Inst) bool {
        let r = self.me.ret;
        let b = self.b();
        let rt = b.pool[b.sig as usize + 2];
        if r.kind == wa::P_DIRECT && !r.leaf {
            self.get(t.a);
            if r.sext {
                self.sx(r.ty);
            }
        } else if r.kind == wa::P_DIRECT {
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(r.ty, self.res_slot);
        } else if r.kind == wa::P_V128 {
            let h = self.mhome(t.a);
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.simd(w::V128_LOAD);
            self.c.memarg(4, h);
            self.obj().simd = true;
        } else if (r.kind == wa::P_I128 || r.kind == wa::P_REF) && (rt & AGG) == 0 {
            // A memory value: its bytes to the prepended pointer.
            let h = self.mhome(t.a);
            self.copy_mem(self.sret_local, 0, self.fp, h, type_bytes(self.vt(t.a), 4));
        } else if r.kind == wa::P_I128 {
            // An aggregate of one i128 returned through the pointer: the slot's bytes there.
            self.copy_mem(self.sret_local, 0, self.fp, self.res_slot, 16);
        }
        self.epilogue();
        self.c.op(w::RETURN);
        return true;
    }
}

// ---- Calls ----

extend Gen {
    // The instructions of the intrinsic body symbol `s` names (`target::intrin`); empty for another
    // function.
    const fn intrinsic(self: &Self, s: u32) str<'static> {
        let p = self.p();
        let ps = p.syms[self.b().syms[s as usize] as usize];
        if ps.def != NONE {
            return "";
        }
        let nm = p.spell(ps.name);
        return intrin::find(
            "wasm32",
            if nm.starts_with("__sc_x_") {
                nm.slice(7, nm.len());
            } else {
                nm;
            },
        );
    }

    // Whether `v` is an integer constant: its bits in `out`.
    const fn const_of(self: &Self, v: Value, out: &mut u64) bool {
        if (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = self.b().insts[v as usize];
        if t.op != O_ICONST {
            return false;
        }
        *out = t.b as u64 << 32 | t.a as u64;
        return true;
    }

    // Intrinsic `tpl` in place of call `t`, its arguments on the operand stack: its instructions, with
    // `local.get k` argument `k`. Arguments in order the instructions take as they are; else they go to
    // locals first.
    fn intrinsic_call(self: &mut Self, t: Inst, tpl: str) bool {
        let b = self.b();
        let np = b.pool[t.b as usize];
        let mut imm = Vector::<i64>::with_capacity(np as usize);
        let mut known = Vector::<bool>::with_capacity(np as usize);
        for k in 0..np {
            let mut u: u64 = 0;
            known.push(self.const_of(b.pool[(t.c + k) as usize], &mut u));
            imm.push(u as i64);
        }
        let mut text = String::new();
        if !intrin::expand(tpl, imm[0..imm.len()], known[0..known.len()], &mut text) {
            return self.refuse("an intrinsic's immediate argument of no constant value");
        }
        let mut lines = Vector::<str>::new();
        let mut it = text.as_str().split("\n");
        loop {
            switch it.next() {
                Some(l) => lines.push(l),
                None => {
                    break;
                },
            };
        }
        // The arguments on the stack: those the instructions read.
        let mut args = Vector::<u32>::new();
        for k in 0..np {
            if reads_arg(tpl, k) {
                args.push(k);
            }
        }
        let mut lead: usize = 0;
        while lead < lines.len() && lead < args.len() && lines[lead] == format("local.get {}", args[lead]).as_str() {
            lead += 1;
        }
        let mut rest = false;
        for q in lead..lines.len() {
            rest = rest || lines[q].starts_with("local.");
        }
        let mut body = String::new();
        if lead == args.len() && !rest {
            for q in lead..lines.len() {
                body.push_str(lines[q]);
                body.push_byte(b'\n');
            }
        } else {
            let mut tmps = Vector::<u32>::new();
            lv::fill(&mut tmps, np as usize, NONE);
            for q in 0..args.len() {
                let k = args[q];
                // A vector on the stack is a v128 (`wtype` gives a vector's by-reference form).
                let pa = self.cs.params[k as usize];
                tmps[k as usize] = self.tmp(
                    if pa.kind == wa::P_V128 {
                        w::V128;
                    } else {
                        wa::wtype(pa.ty);
                    },
                );
            }
            let mut q = args.len();
            while q > 0 {
                q -= 1;
                self.c.local(w::LOCAL_SET, tmps[args[q] as usize]);
            }
            for q in 0..lines.len() {
                let l = lines[q];
                if l.starts_with("local.get ") {
                    let n = l.slice(10, l.len()).parse_i64().unwrap_or(-1);
                    assert(
                        n >= 0 && n < np as i64 && tmps[n as usize] != NONE,
                        "wasm: an intrinsic reads its arguments alone",
                    );
                    body.format_into("local.get {}\n", tmps[n as usize]);
                } else {
                    body.push_str(l);
                    body.push_byte(b'\n');
                }
            }
        }
        self.obj().simd = true;
        return self.asm_text(body.as_str());
    }

    fn call(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let sig = t.b;
        let tpl = if t.op == O_CALL {
            self.intrinsic(t.a);
        } else {
            "";
        };
        // An intrinsic takes its vectors as v128 values.
        wa::classify(
            b,
            sig,
            if tpl.len() != 0 {
                16u32;
            } else {
                self.vregs;
            },
            &mut self.cs,
        );
        let np = b.pool[sig as usize];
        let rt = b.pool[sig as usize + 2];
        // The call area: copies of memory values passed by reference, then the variadic buffer.
        let mut at: u32 = 0;
        let mut refs = Vector::<u32>::new();
        lv::fill(&mut refs, np as usize, NONE);
        for k in 0..self.cs.nfixed {
            let pa = self.cs.params[k as usize];
            let pt = b.pool[(sig + 3 + k) as usize];
            if pa.kind == wa::P_REF && (pt & AGG) == 0 {
                at = at + 15 & ~15u32;
                let v = b.pool[(t.c + k) as usize];
                let h = self.mhome(v);
                self.copy_mem(self.fp, at, self.fp, h, type_bytes(pa.ty, 4));
                refs[k as usize] = at;
                at += type_bytes(pa.ty, 4);
            }
        }
        let mut vbuf = NONE;
        if self.cs.variadic {
            // The variadic arguments' copies of memory values first, then the buffer.
            for k in self.cs.nfixed..np {
                let pa = self.cs.params[k as usize];
                let pt = b.pool[(sig + 3 + k) as usize];
                if pa.kind == wa::P_REF && (pt & AGG) == 0 {
                    at = at + 15 & ~15u32;
                    let v = b.pool[(t.c + k) as usize];
                    let h = self.mhome(v);
                    self.copy_mem(self.fp, at, self.fp, h, type_bytes(pa.ty, 4));
                    refs[k as usize] = at;
                    at += type_bytes(pa.ty, 4);
                }
            }
            at = at + 15 & ~15u32;
            vbuf = at;
            let mut pos: u32 = 0;
            for k in self.cs.nfixed..np {
                let pa = self.cs.params[k as usize];
                let pt = b.pool[(sig + 3 + k) as usize];
                let v = b.pool[(t.c + k) as usize];
                let (sz, al) = wa::va_slot(b, pt, self.vregs);
                pos = pos + al - 1 & ~(al - 1);
                let o = vbuf + pos;
                if pa.kind == wa::P_DIRECT && !pa.leaf {
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.get(v);
                    let st = if narrow_mask(pa.ty) != 0 {
                        if pa.sext {
                            self.sx(pa.ty);
                        }
                        T_I32;
                    } else {
                        pa.ty;
                    };
                    self.store_op(st, o);
                } else if pa.kind == wa::P_DIRECT {
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.get(v);
                    self.load_op(pa.ty, 0);
                    self.store_op(pa.ty, o);
                } else if pa.kind == wa::P_I128 && !pa.leaf {
                    let h = self.mhome(v);
                    self.copy_mem(self.fp, o, self.fp, h, 16);
                } else if pa.kind == wa::P_I128 {
                    let a = self.tmp(w::I32);
                    self.get(v);
                    self.c.local(w::LOCAL_SET, a);
                    self.copy_mem(self.fp, o, a, 0, 16);
                } else if pa.kind == wa::P_V128 {
                    let h = self.mhome(v);
                    self.copy_mem(self.fp, o, self.fp, h, 16);
                } else if pa.kind == wa::P_REF {
                    self.c.local(w::LOCAL_GET, self.fp);
                    if (pt & AGG) != 0 {
                        self.get(v);
                    } else {
                        self.c.local(w::LOCAL_GET, self.fp);
                        self.c.i32_const(refs[k as usize] as i32);
                        self.c.op(w::I32_ADD);
                    }
                    self.store_op(T_PTR, o);
                }
                pos += sz;
            }
        }
        // The wasm arguments.
        if self.cs.sret() {
            if (rt & AGG) != 0 {
                self.get(b.pool[(t.c + np) as usize]);
            } else {
                self.maddr(i);
            }
        }
        for k in 0..self.cs.nfixed {
            let pa = self.cs.params[k as usize];
            let v = b.pool[(t.c + k) as usize];
            if tpl.len() != 0 && !reads_arg(tpl, k) {
                continue; // an intrinsic's immediate
            }
            if pa.kind == wa::P_DIRECT && !pa.leaf {
                self.get(v);
                if pa.sext {
                    self.sx(pa.ty);
                }
            } else if pa.kind == wa::P_DIRECT {
                self.get(v);
                self.load_op(pa.ty, 0);
            } else if pa.kind == wa::P_I128 && !pa.leaf {
                self.mword(v, 0);
                self.mword(v, 1);
            } else if pa.kind == wa::P_I128 {
                self.get(v);
                self.load_op(T_I64, 0);
                self.get(v);
                self.load_op(T_I64, 8);
            } else if pa.kind == wa::P_REF {
                if refs[k as usize] != NONE {
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.c.i32_const(refs[k as usize] as i32);
                    self.c.op(w::I32_ADD);
                } else {
                    self.get(v);
                }
            } else if pa.kind == wa::P_V128 {
                let h = self.mhome(v);
                self.c.local(w::LOCAL_GET, self.fp);
                self.c.simd(w::V128_LOAD);
                self.c.memarg(4, h);
                self.obj().simd = true;
            }
        }
        if self.cs.variadic {
            if self.fp == NONE {
                self.c.i32_const(0);
            } else {
                self.c.local(w::LOCAL_GET, self.fp);
                if vbuf != 0 {
                    self.c.i32_const(vbuf as i32);
                    self.c.op(w::I32_ADD);
                }
            }
        }
        if tpl.len() != 0 {
            if !self.intrinsic_call(t, tpl) {
                return false;
            }
        } else if t.op == O_CALL {
            wa::encode(&self.cs, &mut self.enc);
            let ty = self.obj().type_index(&self.enc);
            let k = self.osym_of(t.a);
            self.call_sym(k, ty);
        } else {
            wa::encode(&self.cs, &mut self.enc);
            let ty = self.obj().type_index(&self.enc);
            self.get(t.a);
            if self.table_sym == NONE {
                self.table_sym = self.obj().sym("__indirect_function_table", wo::K_TABLE);
                self.obj().syms.index_mut(self.table_sym as usize).flags = wo::F_UNDEFINED | wo::F_NO_STRIP;
            }
            self.c.op(w::CALL_INDIRECT);
            self.reloc(w::R_TYPE_INDEX_LEB, ty, 0);
            self.c.uleb5(ty);
            self.reloc(w::R_TABLE_NUMBER_LEB, self.table_sym, 0);
            self.c.uleb5(0);
        }
        // The result.
        let r = self.cs.ret;
        if r.kind == wa::P_DIRECT && !r.leaf {
            self.canon(r.ty);
            self.put(i);
        } else if r.kind == wa::P_DIRECT {
            let tv = self.tmp(wa::wtype(r.ty));
            self.c.local(w::LOCAL_SET, tv);
            self.get(b.pool[(t.c + np) as usize]);
            self.c.local(w::LOCAL_GET, tv);
            self.store_op(r.ty, 0);
        } else if r.kind == wa::P_V128 {
            let tv = self.tmp(w::V128);
            self.c.local(w::LOCAL_SET, tv);
            let h = self.mhome(i);
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.local(w::LOCAL_GET, tv);
            self.c.simd(w::V128_STORE);
            self.c.memarg(4, h);
        }
        return true;
    }
}

// Whether intrinsic template `tpl` reads argument `k` (a line `local.get k`).
const fn reads_arg(tpl: str, k: u32) bool {
    let mut it = tpl.split("\n");
    loop {
        let l = switch it.next() {
            Some(x) => x,
            None => {
                return false;
            },
        };
        if l.starts_with("local.get ") && l.slice(10, l.len()).parse_i64().unwrap_or(-1) == k as i64 {
            return true;
        }
    }
}

// ---- Data ----

extend Gen {
    /// Define package data symbol `s` as a segment of the object.
    pub fn data(self: &mut Self, s: u32, local: bool) bool {
        let p = self.p();
        let ps = p.syms[s as usize];
        let d = p.data[ps.def as usize];
        let mut zero = d.nrelocs == 0;
        for j in 0..d.nbytes {
            zero = zero && p.bytes[(d.bytes + j) as usize] == 0;
        }
        let nm = p.spell(ps.name);
        // Thread-locals are plain data: no threads.
        let name = if ps.sect != NONE {
            String::from_str(p.spell(ps.sect));
        } else if zero && !d.readonly {
            format(".bss.{}", nm);
        } else if d.readonly && d.nrelocs == 0 {
            format(".rodata.{}", nm);
        } else {
            format(".data.{}", nm);
        };
        let mut g = wo::WSeg {
            name: name,
            align_log2: d.align_log2,
            bytes: Vector::<u8>::with_capacity(d.size as usize),
            rels: Vector::<wo::WRel>::new(),
            retain: ps.used,
        };
        let bs = p.data_bytes(&d);
        for j in 0..bs.len() {
            g.bytes.push(bs[j]);
        }
        while g.bytes.len() < d.size as usize {
            g.bytes.push(0);
        }
        for j in 0..d.nrelocs {
            let r = p.relocs[(d.relocs + j) as usize];
            let k = self.pkg_osym(r.sym);
            if p.syms[r.sym as usize].kind == SK_FUNC {
                if r.addend != 0 {
                    return self.refuse("an offset into a function's address");
                }
                self.fn_type_known(r.sym, k);
                if self.err.len() != 0 {
                    return false;
                }
                g.rels.push(wo::WRel { kind: w::R_TABLE_INDEX_I32, off: r.offset, sym: k, addend: 0 });
            } else {
                g.rels.push(wo::WRel { kind: w::R_MEMORY_ADDR_I32, off: r.offset, sym: k, addend: r.addend as i32 });
            }
        }
        let k = self.pkg_osym(s);
        let o = self.obj();
        if o.syms[k as usize].def != wo::NONE {
            return self.refuse("data defined twice in one object");
        }
        let mut fl = if ps.linkage == SL_GLOBAL && !local {
            wo::F_HIDDEN;
        } else {
            wo::F_LOCAL;
        };
        if ps.used {
            fl |= wo::F_NO_STRIP;
        }
        o.define_data(k, fl, g);
        return true;
    }
}

// ---- Vectors ----
//
// Vectors live in frame memory and their operations are lane loops (no simd128): an integer lane computes
// in an i64 local (loaded extended by its sign; the bit operations take it zero-extended) and stores its
// low bits, a float lane computes in a local of its type. The semantics are the evaluator's
// (`lir::eval`), as `a64gen`'s lane code follows them: a float min or max keeps one operand's bits, a
// float to integer conversion saturates unless unchecked, a failing lane panics with the lowest such
// lane.

extend Gen {
    // Instruction `i`'s home (a vector result).
    fn vdef(self: &mut Self, i: u32) u32 {
        let h = self.home[i as usize];
        if h == NONE {
            let _ = self.refuse("internal: a vector result without a home");
            return 0;
        }
        return h;
    }

    // Push lane `k` of memory value `v` (lanes of `lt`): an integer extended to i64 (signed `sg`), a float
    // as itself, or with `raw` a float's bits zero-extended to i64.
    fn ld_lane(self: &mut Self, v: Value, k: u32, lt: u8, sg: bool, raw: bool) {
        let eb = type_bytes(lt, 4);
        let off = self.mhome(v) + k * eb;
        self.c.local(w::LOCAL_GET, self.fp);
        self.lane_load(lt, sg, raw, off);
    }

    // The load of a lane of `lt` at offset `off` of the address on the stack (`ld_lane`'s kinds).
    fn lane_load(self: &mut Self, lt: u8, sg: bool, raw: bool, off: u32) {
        let eb = type_bytes(lt, 4);
        let al = log2u(eb);
        let op = if is_float(lt) && !raw {
            pick8(lt == T_F64, w::F64_LOAD, w::F32_LOAD);
        } else if eb == 1 {
            pick8(sg, w::I64_LOAD8_S, w::I64_LOAD8_U);
        } else if eb == 2 {
            pick8(sg, w::I64_LOAD16_S, w::I64_LOAD16_U);
        } else if eb == 4 {
            pick8(sg, w::I64_LOAD32_S, w::I64_LOAD32_U);
        } else {
            w::I64_LOAD;
        };
        self.c.op(op);
        self.c.memarg(al, off);
    }

    fn ld_lane_to(self: &mut Self, l: u32, v: Value, k: u32, lt: u8, sg: bool, raw: bool) {
        self.ld_lane(v, k, lt, sg, raw);
        self.c.local(w::LOCAL_SET, l);
    }

    // Store local `l` (an i64 for an integer lane or with `raw`, else the float) as lane `k` of the vector
    // at frame offset `d`.
    fn st_lane(self: &mut Self, l: u32, d: u32, k: u32, lt: u8, raw: bool) {
        self.c.local(w::LOCAL_GET, self.fp);
        self.c.local(w::LOCAL_GET, l);
        self.lane_store(lt, raw, d + k * type_bytes(lt, 4));
    }

    // The store of the value on the stack as a lane of `lt` at offset `off` of the address under it.
    fn lane_store(self: &mut Self, lt: u8, raw: bool, off: u32) {
        let eb = type_bytes(lt, 4);
        let op = if is_float(lt) && !raw {
            pick8(lt == T_F64, w::F64_STORE, w::F32_STORE);
        } else if eb == 1 {
            w::I64_STORE8;
        } else if eb == 2 {
            w::I64_STORE16;
        } else if eb == 4 {
            w::I64_STORE32;
        } else {
            w::I64_STORE;
        };
        self.c.op(op);
        self.c.memarg(log2u(eb), off);
    }

    // Push scalar `v` as an i64 (zero-extended).
    fn get64(self: &mut Self, v: Value) {
        self.get(v);
        if wa::wtype(self.vt(v)) == w::I32 {
            self.c.op(w::I64_EXTEND_I32_U);
        }
    }

    // `mk` |= the i32 condition on the stack << `k`.
    fn mask_bit(self: &mut Self, mk: u32, k: u32) {
        self.c.op(w::I64_EXTEND_I32_U);
        if k != 0 {
            self.c.i64_const(k);
            self.c.op(w::I64_SHL);
        }
        self.c.local(w::LOCAL_GET, mk);
        self.c.op(w::I64_OR);
        self.c.local(w::LOCAL_SET, mk);
    }

    // Instruction `i`'s mask result from i64 local `mk`.
    fn put_mask(self: &mut Self, i: u32, mk: u32) {
        self.c.local(w::LOCAL_GET, mk);
        if wa::wtype(self.b().insts[i as usize].ty) == w::I32 {
            self.c.op(w::I32_WRAP_I64);
        }
        self.put(i);
    }

    // `l` = (i32 condition on the stack) ? `a` : `b`, i64 locals.
    fn sel64(self: &mut Self, l: u32, a: u32, b: u32) {
        let c = self.tmp(w::I32);
        self.c.local(w::LOCAL_SET, c);
        self.c.local(w::LOCAL_GET, a);
        self.c.local(w::LOCAL_GET, b);
        self.c.local(w::LOCAL_GET, c);
        self.c.op(w::SELECT);
        self.c.local(w::LOCAL_SET, l);
    }

    // Push `x` << (64 - `lb`) >> (64 - `lb`), arithmetic: the low `lb` bits sign-extended.
    fn sext_bits(self: &mut Self, x: u32, lb: u32) {
        self.c.local(w::LOCAL_GET, x);
        if lb < 64 {
            self.c.i64_const(64 - lb);
            self.c.op(w::I64_SHL);
            self.c.i64_const(64 - lb);
            self.c.op(w::I64_SHR_S);
        }
    }

    // The panic of lane `k` with the message of vector rule `c` when the i32 condition on the stack holds.
    fn lane_trap_if(self: &mut Self, k: u32, msg: str) {
        self.c.op(w::IF);
        self.c.op(w::BLOCK_EMPTY);
        self.c.i64_const(k);
        let m = self.cstr(msg);
        self.data_addr(m, 0);
        self.call_rt("__sc_lane_panic", [w::I64, w::I32], []);
        self.c.op(w::UNREACHABLE);
        self.c.op(w::END);
    }

    fn vector(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        if op == O_VOP {
            return self.vop(i, t);
        }
        if op >= O_ADD && op <= O_NOT || op >= O_FADD && op <= O_FNEG {
            self.vec_arith(i, t);
            return true;
        }
        if op >= O_SEXT && op <= O_UITOFP {
            let fl = lane_type(self.vt(t.a));
            let tl = lane_type(t.ty);
            let fs = op == O_SEXT || op == O_SITOFP;
            self.vec_conv(i, t.a, fl, fs, tl, op == O_FPTOSI, t.aux == CV_UNCHECKED);
            return true;
        }
        return self.refuse("a vector instruction the verifier rejects");
    }

    // Vector arithmetic: O_ADD .. O_NOT and O_FADD .. O_FNEG, lane by lane.
    fn vec_arith(self: &mut Self, i: u32, t: Inst) {
        let op = t.op;
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let d = self.vdef(i);
        if is_float(lt) {
            let ft = pick8(lt == T_F64, w::F64, w::F32);
            let fd = pick8(lt == T_F64, w::F64_ADD - w::F32_ADD, 0);
            let fa = self.tmp(ft);
            for k in 0..n {
                self.ld_lane(t.a, k, lt, false, false);
                if op == O_FNEG {
                    self.c.op(pick8(lt == T_F64, w::F64_NEG, w::F32_NEG));
                } else {
                    self.ld_lane(t.b, k, lt, false, false);
                    self.c.op(w::F32_ADD + (op - O_FADD) + fd);
                }
                self.c.local(w::LOCAL_SET, fa);
                self.st_lane(fa, d, k, lt, false);
            }
            return;
        }
        let sg = op == O_ASHR || op == O_SDIV || op == O_SREM;
        let x = self.tmp(w::I64);
        let ops: []u8 = [
            w::I64_ADD,
            w::I64_SUB,
            w::I64_MUL,
            w::I64_DIV_S,
            w::I64_DIV_U,
            w::I64_REM_S,
            w::I64_REM_U,
            w::I64_AND,
            w::I64_OR,
            w::I64_XOR,
            w::I64_SHL,
            w::I64_SHR_U,
            w::I64_SHR_S,
        ];
        for k in 0..n {
            if op == O_NEG {
                self.c.i64_const(0);
                self.ld_lane(t.a, k, lt, false, false);
                self.c.op(w::I64_SUB);
            } else if op == O_NOT {
                self.ld_lane(t.a, k, lt, false, false);
                self.c.i64_const(-1);
                self.c.op(w::I64_XOR);
            } else {
                self.ld_lane(t.a, k, lt, sg, false);
                self.ld_lane(t.b, k, lt, sg && op != O_ASHR, false);
                self.c.op(ops[(op - O_ADD) as usize]);
            }
            self.c.local(w::LOCAL_SET, x);
            self.st_lane(x, d, k, lt, false);
        }
    }

    // A lane-wise conversion of vector `v` (lanes of `fl`, signed `fs`) to the lanes of `tl` (signed `ts`)
    // into instruction `i`'s home; a float to an integer saturates unless `unchecked`.
    fn vec_conv(self: &mut Self, i: u32, v: Value, fl: u8, fs: bool, tl: u8, ts: bool, unchecked: bool) {
        let n = lanes(self.vt(v));
        let d = self.vdef(i);
        let x = self.tmp(w::I64);
        let fa = if is_float(fl) {
            self.tmp(pick8(fl == T_F64, w::F64, w::F32));
        } else {
            NONE;
        };
        let fr = if is_float(tl) {
            self.tmp(pick8(tl == T_F64, w::F64, w::F32));
        } else {
            NONE;
        };
        for k in 0..n {
            if is_float(fl) && is_float(tl) {
                self.ld_lane(v, k, fl, false, false);
                if fl != tl {
                    self.c.op(pick8(tl == T_F64, w::F64_PROMOTE_F32, w::F32_DEMOTE_F64));
                }
                self.c.local(w::LOCAL_SET, fr);
                self.st_lane(fr, d, k, tl, false);
            } else if is_float(tl) {
                self.ld_lane(v, k, fl, fs, false);
                let base = pick8(tl == T_F64, w::F64_CONVERT_I64_S, w::F32_CONVERT_I64_S);
                self.c.op(base + pick8(fs, 0, 1));
                self.c.local(w::LOCAL_SET, fr);
                self.st_lane(fr, d, k, tl, false);
            } else if is_float(fl) {
                self.ld_lane_to(fa, v, k, fl, false, false);
                self.trunc_sat(fa, fl == T_F64, tl, ts, unchecked);
                if tl != T_I64 {
                    self.c.op(w::I64_EXTEND_I32_U);
                }
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, tl, false);
            } else {
                self.ld_lane_to(x, v, k, fl, fs, false);
                self.st_lane(x, d, k, tl, false);
            }
        }
    }

    // A portable vector operation (`O_VOP`).
    fn vop(self: &mut Self, i: u32, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        let sg = (t.aux & VOP_SIGNED) != 0;
        let dsg = (t.aux & VOP_DSIGNED) != 0;
        let mut ops: [Value; 4] = [VNONE, VNONE, VNONE, VNONE];
        let mut tys: [u8; 4] = [T_NONE, T_NONE, T_NONE, T_NONE];
        let na = if t.b < 4 {
            t.b;
        } else {
            4u32;
        };
        for k in 0..na {
            let v = self.b().pool[(t.a + k) as usize];
            unsafe ops[k as usize] = v;
            unsafe tys[k as usize] = self.vt(v);
        }
        if code == core::OP_CAST {
            let fl = lane_type(tys[0]);
            let tl = lane_type(t.ty);
            // An integer widens by its source's sign; every other integer change keeps the low bits.
            let ext = is_float(fl) || is_float(tl) || type_bits(fl, 4) < type_bits(tl, 4) && sg;
            self.vec_conv(i, ops[0], fl, sg && ext, tl, dsg, (t.aux & VOP_UNCHECKED) != 0);
            return true;
        }
        if code == core::OP_REM {
            self.vec_fmod(i, ops[0], ops[1]);
            return true;
        }
        if code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR {
            let lt = lane_type(tys[0]);
            let lb = type_bits(lt, 4);
            let d = self.vdef(i);
            let cnt = self.tmp(w::I64);
            let x = self.tmp(w::I64);
            self.get64(ops[1]);
            self.c.i64_const(lb - 1);
            self.c.op(w::I64_AND);
            self.c.local(w::LOCAL_SET, cnt);
            let sop = if code == core::OP_SHL_SCALAR {
                w::I64_SHL;
            } else {
                pick8(sg, w::I64_SHR_S, w::I64_SHR_U);
            };
            for k in 0..lanes(tys[0]) {
                self.ld_lane(ops[0], k, lt, sg, false);
                self.c.local(w::LOCAL_GET, cnt);
                self.c.op(sop);
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, lt, false);
            }
            return true;
        }
        if code < core::OP_SIMD || code >= core::OP_CMP_LANES {
            return self.refuse("a vector operation the verifier rejects");
        }
        let c = (code - core::OP_SIMD) as u8;
        let rule = core::simd_op(c).rule;
        if rule == core::SR_LOAD || rule == core::SR_STORE {
            self.vmem(i, t, c, &ops, &tys);
            return true;
        }
        if rule == core::SR_MLOAD || rule == core::SR_MSTORE {
            self.vmem_masked(i, t, c, &ops, &tys);
            return true;
        }
        if rule == core::SR_REDUCE || rule == core::SR_DOT {
            self.vreduce(i, t, c, sg, &ops, &tys);
            return true;
        }
        if rule == core::SR_INDEX || rule == core::SR_RT_INDEX || rule == core::SR_MASKED {
            self.vrearrange(i, t, c, &ops, &tys);
            return true;
        }
        self.vlanes(i, t, c, sg, dsg, &ops, &tys);
        return true;
    }

    // Float vectors `x` % `y` lane by lane through C's `fmod` (`fmodf`).
    fn vec_fmod(self: &mut Self, i: u32, x: Value, y: Value) {
        let lt = lane_type(self.vt(x));
        let ft = pick8(lt == T_F64, w::F64, w::F32);
        let d = self.vdef(i);
        let fa = self.tmp(ft);
        for k in 0..lanes(self.vt(x)) {
            self.ld_lane(x, k, lt, false, false);
            self.ld_lane(y, k, lt, false, false);
            if lt == T_F64 {
                self.call_rt("fmod", [w::F64, w::F64], [w::F64]);
            } else {
                self.call_rt("fmodf", [w::F32, w::F32], [w::F32]);
            }
            self.c.local(w::LOCAL_SET, fa);
            self.st_lane(fa, d, k, lt, false);
        }
    }

    // The lane rules (`core::SR_VEC`, masks, `choose`, lane changes, casts of bits, halves).
    fn vlanes(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, dsg: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let rule = core::simd_op(c).rule;
        let vt = if rule == core::SR_CHOOSE {
            tys[1];
        } else if rule == core::SR_ANY {
            t.ty;
        } else {
            tys[0];
        };
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 4);
        let lb = eb * 8;
        let n = lanes(vt);
        let nb = n * eb;
        let fl = is_float(lt);
        if rule == core::SR_BITCAST || rule == core::SR_HALF || rule == core::SR_CONCAT {
            let d = self.vdef(i);
            let rb = type_bytes(t.ty, 4);
            let h0 = self.mhome(ops[0]);
            if rule == core::SR_CONCAT {
                let h1 = self.mhome(ops[1]);
                self.copy_mem(self.fp, d, self.fp, h0, nb);
                self.copy_mem(self.fp, d + nb, self.fp, h1, nb);
            } else if c == core::SIMD_HIGH_HALF {
                self.copy_mem(self.fp, d, self.fp, h0 + rb, rb);
            } else {
                self.copy_mem(self.fp, d, self.fp, h0, rb);
            }
            return;
        }
        let mask = rule == core::SR_MASK || rule == core::SR_CHANGED;
        if !mask && rule == core::SR_VEC && !fl && !sg && (c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS) {
            // The absolute value of an unsigned lane is the lane.
            let d = self.vdef(i);
            let h0 = self.mhome(ops[0]);
            self.copy_mem(self.fp, d, self.fp, h0, nb);
            return;
        }
        let rlt = if mask || !is_vec(t.ty) {
            lt;
        } else {
            lane_type(t.ty);
        };
        let mut mk = NONE;
        let mut d: u32 = 0;
        if mask {
            mk = self.tmp(w::I64);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, mk);
        } else {
            d = self.vdef(i);
        }
        // Operand 1 as one scalar for every lane.
        let scalar1 = rule != core::SR_CHOOSE && tys[1] != T_NONE && !is_vec(tys[1]);
        let x = self.tmp(w::I64);
        let y = self.tmp(w::I64);
        let z = self.tmp(w::I64);
        let fr = self.tmp(w::I32);
        if scalar1 {
            self.get64(ops[1]);
            self.c.local(w::LOCAL_SET, y);
            if sg && type_bits(tys[1], 4) < 64 {
                self.sext_bits(y, type_bits(tys[1], 4));
                self.c.local(w::LOCAL_SET, y);
            }
        }
        let cm = if rule == core::SR_CHOOSE {
            self.tmp(w::I64);
        } else {
            NONE;
        };
        if cm != NONE {
            self.get64(ops[0]);
            self.c.local(w::LOCAL_SET, cm);
        }
        let trap_msg = core::lane_trap_msg(core::RV_SIMD, c, false);
        let traps = !fl && sg && c == core::SIMD_ABS || c == core::SIMD_NARROW_CHECKED;
        // Bit operations read the lane's bits.
        let bitop = c >= core::SIMD_CLZ && c <= core::SIMD_BSWAP;
        let ft = pick8(lt == T_F64, w::F64, w::F32);
        let (fa, fb, fc) = if fl {
            (self.tmp(ft), self.tmp(ft), self.tmp(ft));
        } else {
            (NONE, NONE, NONE);
        };
        for k in 0..n {
            if c == core::SIMD_IOTA {
                if fl {
                    if lt == T_F64 {
                        self.c.f64_const(f64_bits(k as f64));
                    } else {
                        self.c.f32_const(f32_bits(k as f32));
                    }
                    self.c.local(w::LOCAL_SET, fa);
                    self.st_lane(fa, d, k, lt, false);
                } else {
                    self.c.i64_const(k);
                    self.c.local(w::LOCAL_SET, x);
                    self.st_lane(x, d, k, lt, false);
                }
                continue;
            }
            if rule == core::SR_CHOOSE {
                self.ld_lane_to(x, ops[1], k, lt, false, true);
                self.ld_lane_to(y, ops[2], k, lt, false, true);
                self.c.local(w::LOCAL_GET, cm);
                self.c.i64_const((1u64 << k as u64) as i64);
                self.c.op(w::I64_AND);
                self.c.i64_const(0);
                self.c.op(w::I64_NE);
                self.sel64(x, x, y);
                self.st_lane(x, d, k, lt, true);
                continue;
            }
            if c == core::SIMD_CAST_CHANGED {
                self.lane_changed(mk, k, ops, tys, sg, dsg, x, z, fr);
                continue;
            }
            if fl {
                self.float_rule(c, k, ops, lt, mk, d, x, y, fa, fb, fc);
                continue;
            }
            self.ld_lane_to(x, ops[0], k, lt, sg && !bitop, false);
            if !scalar1 && tys[1] != T_NONE {
                self.ld_lane_to(y, ops[1], k, lane_type(tys[1]), sg && !bitop, false);
            }
            if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
                self.c.local(w::LOCAL_GET, x);
                self.c.local(w::LOCAL_GET, y);
                self.c.op(int_cmp64(c, sg));
                self.mask_bit(mk, k);
                continue;
            }
            if c >= core::SIMD_OVF_ADD && c <= core::SIMD_OVF_MUL {
                self.ovf_lane(c, lb, sg, x, y, z);
                self.mask_bit(mk, k);
                continue;
            }
            if traps {
                self.c.i32_const(0);
                self.c.local(w::LOCAL_SET, fr);
            }
            self.int_rule(c, lb, sg, rlt, dsg, x, y, z, fr);
            if traps {
                self.c.local(w::LOCAL_GET, fr);
                self.lane_trap_if(k, trap_msg);
            }
            self.st_lane(x, d, k, rlt, false);
        }
        if mask {
            self.put_mask(i, mk);
        }
    }

    // The overflow test of lane rule `c` (OVF_ADD .. OVF_MUL, and the SAT forms) of `lb`-bit lanes
    // (signed `sg`, extended to 64 bits in `x` and `y`): pushes 1 when the exact result does not fit the
    // lane; `x` keeps the wrapped result.
    fn ovf_lane(self: &mut Self, c: u8, lb: u32, sg: bool, x: u32, y: u32, z: u32) {
        let add = c == core::SIMD_OVF_ADD || c == core::SIMD_SAT_ADD;
        let sub = c == core::SIMD_OVF_SUB || c == core::SIMD_SAT_SUB;
        if lb == 64 && !add && !sub {
            self.mul_hi(x, y, sg);
            return;
        }
        self.c.local(w::LOCAL_GET, x);
        self.c.local(w::LOCAL_GET, y);
        self.c.op(
            if add {
                w::I64_ADD;
            } else if sub {
                w::I64_SUB;
            } else {
                w::I64_MUL;
            },
        );
        self.c.local(w::LOCAL_SET, z);
        if lb == 64 {
            if sg {
                // add: (x ^ r) & (y ^ r) < 0; sub: (x ^ y) & (x ^ r) < 0.
                self.c.local(w::LOCAL_GET, x);
                self.c.local(
                    w::LOCAL_GET,
                    if add {
                        z;
                    } else {
                        y;
                    },
                );
                self.c.op(w::I64_XOR);
                self.c.local(
                    w::LOCAL_GET,
                    if add {
                        y;
                    } else {
                        x;
                    },
                );
                self.c.local(w::LOCAL_GET, z);
                self.c.op(w::I64_XOR);
                self.c.op(w::I64_AND);
                self.c.i64_const(0);
                self.c.op(w::I64_LT_S);
            } else if add {
                self.c.local(w::LOCAL_GET, z);
                self.c.local(w::LOCAL_GET, x);
                self.c.op(w::I64_LT_U);
            } else {
                self.c.local(w::LOCAL_GET, x);
                self.c.local(w::LOCAL_GET, y);
                self.c.op(w::I64_LT_U);
            }
        } else if sg {
            // The exact result against its lane's extension.
            self.sext_bits(z, lb);
            self.c.local(w::LOCAL_GET, z);
            self.c.op(w::I64_NE);
        } else {
            self.c.local(w::LOCAL_GET, z);
            self.c.i64_const(lb);
            self.c.op(w::I64_SHR_U);
            self.c.i64_const(0);
            self.c.op(w::I64_NE);
        }
        self.c.local(w::LOCAL_GET, z);
        self.c.local(w::LOCAL_SET, x);
    }

    // The 64-bit product `x` * `y` (signed `sg`) into `x`, and 1 pushed when it does not fit 64 bits:
    // compiler-rt's `__mulodi4`, or the high word of `__multi3` (the call area's first 16 bytes).
    fn mul_hi(self: &mut Self, x: u32, y: u32, sg: bool) {
        if sg {
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, y);
            self.c.local(w::LOCAL_GET, self.fp);
            self.call_rt("__mulodi4", [w::I64, w::I64, w::I32], [w::I64]);
            self.c.local(w::LOCAL_SET, x);
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(T_I32, 0);
            self.c.i32_const(0);
            self.c.op(w::I32_NE);
            return;
        }
        self.c.local(w::LOCAL_GET, self.fp);
        self.c.local(w::LOCAL_GET, x);
        self.c.i64_const(0);
        self.c.local(w::LOCAL_GET, y);
        self.c.i64_const(0);
        self.call_rt("__multi3", [w::I32, w::I64, w::I64, w::I64, w::I64], []);
        self.c.local(w::LOCAL_GET, self.fp);
        self.load_op(T_I64, 0);
        self.c.local(w::LOCAL_SET, x);
        self.c.local(w::LOCAL_GET, self.fp);
        self.load_op(T_I64, 8);
        self.c.i64_const(0);
        self.c.op(w::I64_NE);
    }

    // Integer lane rule `c` on `x` (and `y`) of `lb`-bit lanes (signed `sg`, extended to 64 bits; a bit
    // operation's zero-extended): the result lane (of `rlt`, signed `rsg`) in `x`; a lane that traps sets
    // `fr`.
    fn int_rule(self: &mut Self, c: u8, lb: u32, sg: bool, rlt: u8, rsg: bool, x: u32, y: u32, z: u32, fr: u32) {
        let lt_op = pick8(sg, w::I64_LT_S, w::I64_LT_U);
        if c == core::SIMD_WRAP_ADD || c == core::SIMD_WRAP_SUB || c == core::SIMD_WRAP_MUL {
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, y);
            self.c.op(
                if c == core::SIMD_WRAP_ADD {
                    w::I64_ADD;
                } else if c == core::SIMD_WRAP_SUB {
                    w::I64_SUB;
                } else {
                    w::I64_MUL;
                },
            );
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_WRAP_NEG {
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_WRAP_SHL || c == core::SIMD_WRAP_SHR {
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, y);
            self.c.i64_const(lb - 1);
            self.c.op(w::I64_AND);
            self.c.op(
                if c == core::SIMD_WRAP_SHL {
                    w::I64_SHL;
                } else {
                    pick8(sg, w::I64_SHR_S, w::I64_SHR_U);
                },
            );
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let add = c == core::SIMD_SAT_ADD;
            // The limit: a signed overflow goes the way of the operand's sign, an unsigned one up for a sum.
            let max = if sg {
                (1u64 << (lb - 1) as u64) - 1;
            } else {
                trunc_to(~0u64, lb);
            };
            let min = if sg {
                (1u64 << (lb - 1) as u64).wrapping_neg();
            } else {
                0u64;
            };
            let ov = self.tmp(w::I32);
            self.ovf_lane(c, lb, sg, x, y, z);
            self.c.local(w::LOCAL_SET, ov);
            if sg {
                self.c.i64_const(pick64(add, min, max) as i64);
                self.c.i64_const(pick64(add, max, min) as i64);
                self.c.local(w::LOCAL_GET, y);
                self.c.i64_const(0);
                self.c.op(w::I64_LT_S);
                self.c.op(w::SELECT);
            } else {
                self.c.i64_const(pick64(add, max, min) as i64);
            }
            self.c.local(w::LOCAL_SET, z);
            self.c.local(w::LOCAL_GET, ov);
            self.sel64(x, z, x);
        } else if c == core::SIMD_MIN || c == core::SIMD_MAX {
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, y);
            self.c.op(lt_op);
            if c == core::SIMD_MIN {
                self.sel64(x, x, y);
            } else {
                self.sel64(x, y, x);
            }
        } else if c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS {
            if c == core::SIMD_ABS {
                // The lowest value has no absolute value in its lane.
                self.c.local(w::LOCAL_GET, x);
                self.c.i64_const((1u64 << (lb - 1) as u64).wrapping_neg() as i64);
                self.c.op(w::I64_EQ);
                self.c.local(w::LOCAL_GET, fr);
                self.c.op(w::I32_OR);
                self.c.local(w::LOCAL_SET, fr);
            }
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_SET, z);
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const(0);
            self.c.op(w::I64_LT_S);
            self.sel64(x, z, x);
        } else if c == core::SIMD_ABS_DIFF {
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, y);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_GET, y);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_GET, y);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(lt_op);
            self.c.op(w::SELECT);
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_CLZ {
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_CLZ);
            if lb < 64 {
                self.c.i64_const(64 - lb);
                self.c.op(w::I64_SUB);
            }
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_CTZ {
            self.c.local(w::LOCAL_GET, x);
            if lb < 64 {
                self.c.i64_const((1u64 << lb as u64) as i64);
                self.c.op(w::I64_OR);
            }
            self.c.op(w::I64_CTZ);
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_POPCNT {
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_POPCNT);
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_ROTL || c == core::SIMD_ROTR {
            // (u << k | u >> (lb - k) % lb), or the reverse: the store keeps the lane's bits.
            self.c.local(w::LOCAL_GET, y);
            self.c.i64_const(lb - 1);
            self.c.op(w::I64_AND);
            self.c.local(w::LOCAL_SET, y);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, y);
            self.c.op(w::I64_SUB);
            self.c.i64_const(lb - 1);
            self.c.op(w::I64_AND);
            self.c.local(w::LOCAL_SET, z);
            let (s0, s1) = if c == core::SIMD_ROTL {
                (w::I64_SHL, w::I64_SHR_U);
            } else {
                (w::I64_SHR_U, w::I64_SHL);
            };
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, y);
            self.c.op(s0);
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, z);
            self.c.op(s1);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_BITREV {
            self.bit_reverse(x, z);
            if lb < 64 {
                self.c.local(w::LOCAL_GET, x);
                self.c.i64_const(64 - lb);
                self.c.op(w::I64_SHR_U);
                self.c.local(w::LOCAL_SET, x);
            }
        } else if c == core::SIMD_BSWAP {
            if lb > 8 {
                // Byte j of the lane to byte lb / 8 - 1 - j.
                let nbytes = lb / 8;
                self.c.i64_const(0);
                for j in 0..nbytes {
                    self.c.local(w::LOCAL_GET, x);
                    if j != 0 {
                        self.c.i64_const(8 * j);
                        self.c.op(w::I64_SHR_U);
                    }
                    self.c.i64_const(0xFF);
                    self.c.op(w::I64_AND);
                    let to = 8 * (nbytes - 1 - j);
                    if to != 0 {
                        self.c.i64_const(to);
                        self.c.op(w::I64_SHL);
                    }
                    self.c.op(w::I64_OR);
                }
                self.c.local(w::LOCAL_SET, x);
            }
        } else if c == core::SIMD_NARROW_CHECKED || c == core::SIMD_NARROW_SAT {
            self.narrow_lane(c == core::SIMD_NARROW_SAT, lb, sg, type_bits(rlt, 4), rsg, x, z, fr);
        }
    }

    // `x` = its 64 bits reversed (`z` a temporary): adjacent bits, pairs, nibbles, bytes, halves and words
    // swap.
    fn bit_reverse(self: &mut Self, x: u32, z: u32) {
        let masks: []u64 = [
            0x5555555555555555,
            0x3333333333333333,
            0x0F0F0F0F0F0F0F0F,
            0x00FF00FF00FF00FF,
            0x0000FFFF0000FFFF,
        ];
        for q in 0..5usize {
            let sh = 1i64 << q as i64;
            let m = masks[q] as i64;
            // x = (x >> sh) & m | (x & m) << sh
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const(sh);
            self.c.op(w::I64_SHR_U);
            self.c.i64_const(m);
            self.c.op(w::I64_AND);
            self.c.local(w::LOCAL_SET, z);
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const(m);
            self.c.op(w::I64_AND);
            self.c.i64_const(sh);
            self.c.op(w::I64_SHL);
            self.c.local(w::LOCAL_GET, z);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, x);
        }
        self.c.local(w::LOCAL_GET, x);
        self.c.i64_const(32);
        self.c.op(w::I64_ROTL);
        self.c.local(w::LOCAL_SET, x);
    }

    // A lane `x` of `lb` bits (signed `sg`, extended) to `rw` bits (signed `rsg`): saturated (`sat`), else
    // kept when it fits and failing `fr` when not.
    fn narrow_lane(self: &mut Self, sat: bool, lb: u32, sg: bool, rw: u32, rsg: bool, x: u32, z: u32, fr: u32) {
        let rmax = if rsg {
            (1u64 << (rw - 1) as u64) - 1;
        } else {
            trunc_to(~0u64, rw);
        };
        let rmin = if rsg {
            (1u64 << (rw - 1) as u64).wrapping_neg();
        } else {
            0u64;
        };
        // `x` above 2^63 only for an unsigned 64-bit lane: its top bit, taken as a value, is positive.
        let huge_u = !sg && lb == 64;
        if !sat {
            let mut checks: u32 = 0;
            if rsg {
                if rw < 64 {
                    self.sext_bits(x, rw);
                    self.c.local(w::LOCAL_GET, x);
                    self.c.op(w::I64_NE);
                    checks += 1;
                }
                if huge_u {
                    self.c.local(w::LOCAL_GET, x);
                    self.c.i64_const(0);
                    self.c.op(w::I64_LT_S);
                    checks += 1;
                }
            } else {
                if sg {
                    self.c.local(w::LOCAL_GET, x);
                    self.c.i64_const(0);
                    self.c.op(w::I64_LT_S);
                    checks += 1;
                }
                if rw < 64 {
                    self.c.local(w::LOCAL_GET, x);
                    self.c.i64_const(rw);
                    self.c.op(w::I64_SHR_U);
                    self.c.i64_const(0);
                    self.c.op(w::I64_NE);
                    checks += 1;
                }
            }
            for _ in 0..checks {
                self.c.local(w::LOCAL_GET, fr);
                self.c.op(w::I32_OR);
                self.c.local(w::LOCAL_SET, fr);
            }
            return;
        }
        // Saturate: a negative signed value into an unsigned lane is 0, then the range clamps.
        if sg && !rsg {
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, z);
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const(0);
            self.c.op(w::I64_LT_S);
            self.sel64(x, z, x);
        }
        self.c.i64_const(rmax as i64);
        self.c.local(w::LOCAL_SET, z);
        self.c.local(w::LOCAL_GET, z);
        self.c.local(w::LOCAL_GET, x);
        self.c.op(pick8(sg, w::I64_LT_S, w::I64_LT_U));
        self.sel64(x, z, x);
        if sg && rsg {
            self.c.i64_const(rmin as i64);
            self.c.local(w::LOCAL_SET, z);
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, z);
            self.c.op(w::I64_LT_S);
            self.sel64(x, z, x);
        }
    }

    // Float lane rule `c` on lane `k` (lanes of `lt`): the result lane stored at frame offset `d`, or a
    // mask bit into `mk`.
    fn float_rule(
        self: &mut Self,
        c: u8,
        k: u32,
        ops: &[Value; 4],
        lt: u8,
        mk: u32,
        d: u32,
        x: u32,
        y: u32,
        fa: u32,
        fb: u32,
        fc: u32,
    ) {
        let dd = lt == T_F64;
        let lb = type_bits(lt, 4);
        let sb = 1u64 << (lb - 1) as u64;
        let cd = pick8(dd, w::F64_EQ - w::F32_EQ, 0);
        let ud = pick8(dd, w::F64_ABS - w::F32_ABS, 0);
        if c == core::SIMD_COPYSIGN || c == core::SIMD_IS_SIGN_NEG {
            self.ld_lane_to(x, ops[0], k, lt, false, true);
            if c == core::SIMD_IS_SIGN_NEG {
                self.c.local(w::LOCAL_GET, x);
                self.c.i64_const(sb as i64);
                self.c.op(w::I64_AND);
                self.c.i64_const(0);
                self.c.op(w::I64_NE);
                self.mask_bit(mk, k);
                return;
            }
            self.ld_lane_to(y, ops[1], k, lt, false, true);
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const((sb - 1) as i64);
            self.c.op(w::I64_AND);
            self.c.local(w::LOCAL_GET, y);
            self.c.i64_const(sb as i64);
            self.c.op(w::I64_AND);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, x);
            self.st_lane(x, d, k, lt, true);
            return;
        }
        self.ld_lane_to(fa, ops[0], k, lt, false, false);
        if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
            self.ld_lane_to(fb, ops[1], k, lt, false, false);
            self.c.local(w::LOCAL_GET, fa);
            self.c.local(w::LOCAL_GET, fb);
            let o = if c == core::SIMD_CMP_EQ {
                w::F32_EQ;
            } else if c == core::SIMD_CMP_NE {
                w::F32_NE;
            } else if c == core::SIMD_CMP_LT {
                w::F32_LT;
            } else if c == core::SIMD_CMP_LE {
                w::F32_LE;
            } else if c == core::SIMD_CMP_GT {
                w::F32_GT;
            } else {
                w::F32_GE;
            };
            self.c.op(o + cd);
            self.mask_bit(mk, k);
            return;
        }
        if c >= core::SIMD_IS_NAN && c <= core::SIMD_IS_SUBNORMAL {
            if c == core::SIMD_IS_NAN {
                self.c.local(w::LOCAL_GET, fa);
                self.c.local(w::LOCAL_GET, fa);
                self.c.op(w::F32_NE + cd);
                self.mask_bit(mk, k);
                return;
            }
            let minn = pick64(dd, 0x0010000000000000, 0x00800000);
            let maxf = pick64(dd, 0x7FEFFFFFFFFFFFFF, 0x7F7FFFFF);
            self.c.local(w::LOCAL_GET, fa);
            self.c.op(w::F32_ABS + ud);
            self.c.local(w::LOCAL_SET, fa);
            if c == core::SIMD_IS_SUBNORMAL {
                // Not 0 and below the least normal (a NaN compares false).
                self.c.local(w::LOCAL_GET, fa);
                self.fconst(dd, minn);
                self.c.op(w::F32_LT + cd);
                self.c.local(w::LOCAL_GET, fa);
                self.fconst(dd, 0);
                self.c.op(w::F32_NE + cd);
                self.c.op(w::I32_AND);
            } else if c == core::SIMD_IS_INF {
                self.c.local(w::LOCAL_GET, fa);
                self.fconst(dd, maxf);
                self.c.op(w::F32_GT + cd);
            } else if c == core::SIMD_IS_FINITE {
                self.c.local(w::LOCAL_GET, fa);
                self.fconst(dd, maxf);
                self.c.op(w::F32_LE + cd);
            } else {
                // Normal: at most the greatest finite and at least the least normal.
                self.c.local(w::LOCAL_GET, fa);
                self.fconst(dd, maxf);
                self.c.op(w::F32_LE + cd);
                self.c.local(w::LOCAL_GET, fa);
                self.fconst(dd, minn);
                self.c.op(w::F32_GE + cd);
                self.c.op(w::I32_AND);
            }
            self.mask_bit(mk, k);
            return;
        }
        if c == core::SIMD_FMA {
            self.c.local(w::LOCAL_GET, fa);
            self.ld_lane(ops[1], k, lt, false, false);
            self.ld_lane(ops[2], k, lt, false, false);
            if dd {
                self.call_rt("fma", [w::F64, w::F64, w::F64], [w::F64]);
            } else {
                self.call_rt("fmaf", [w::F32, w::F32, w::F32], [w::F32]);
            }
            self.c.local(w::LOCAL_SET, fa);
        } else if c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_MINIMUM || c == core::SIMD_MAXIMUM {
            self.ld_lane_to(fb, ops[1], k, lt, false, false);
            let lo = c == core::SIMD_MIN || c == core::SIMD_MINIMUM;
            self.fminmax(dd, lo, c >= core::SIMD_MINIMUM, true, fa, fa, fb, fc);
        } else {
            let o = if c == core::SIMD_ABS {
                w::F32_ABS;
            } else if c == core::SIMD_SQRT {
                w::F32_SQRT;
            } else if c == core::SIMD_CEIL {
                w::F32_CEIL;
            } else if c == core::SIMD_FLOOR {
                w::F32_FLOOR;
            } else if c == core::SIMD_TRUNC {
                w::F32_TRUNC;
            } else if c == core::SIMD_ROUND_EVEN {
                w::F32_NEAREST;
            } else {
                w::F32_NEG;
            };
            self.c.local(w::LOCAL_GET, fa);
            self.c.op(o + ud);
            self.c.local(w::LOCAL_SET, fa);
        }
        self.st_lane(fa, d, k, lt, false);
    }

    // Push float constant `bits` (f64 when `dd`).
    fn fconst(self: &mut Self, dd: bool, bits: u64) {
        if dd {
            self.c.f64_const(bits);
        } else {
            self.c.f32_const(bits as u32);
        }
    }

    // The float min (`lo`) or max of locals `a` and `b` into `d` by the evaluator's `fminmax`, one operand's
    // bits kept: with `nan` a NaN operand is the result (`a` first); else a NaN gives the other operand,
    // and two give `a`, its quiet bit set when `quiet` (the lane rule; a reduction keeps `a`). `t` is a
    // scratch local of the type.
    fn fminmax(self: &mut Self, dd: bool, lo: bool, nan: bool, quiet: bool, d: u32, a: u32, b: u32, t: u32) {
        let cd = pick8(dd, w::F64_EQ - w::F32_EQ, 0);
        let na = self.tmp(w::I32);
        let nb = self.tmp(w::I32);
        self.c.local(w::LOCAL_GET, a);
        self.c.local(w::LOCAL_GET, a);
        self.c.op(w::F32_NE + cd);
        self.c.local(w::LOCAL_SET, na);
        self.c.local(w::LOCAL_GET, b);
        self.c.local(w::LOCAL_GET, b);
        self.c.op(w::F32_NE + cd);
        self.c.local(w::LOCAL_SET, nb);
        // Whether `a` is taken: past the NaNs, the strict order, or with equal values the sign.
        self.c.i32_const(1);
        self.c.i32_const(0);
        self.c.local(w::LOCAL_GET, a);
        self.c.local(w::LOCAL_GET, b);
        self.c.op(pick8(lo, w::F32_LT, w::F32_GT) + cd);
        // Equal: `a` when its sign is the min side's.
        self.c.local(w::LOCAL_GET, a);
        if dd {
            self.c.op(w::I64_REINTERPRET_F64);
            self.c.i64_const(63);
            self.c.op(w::I64_SHR_U);
            self.c.op(w::I32_WRAP_I64);
        } else {
            self.c.op(w::I32_REINTERPRET_F32);
            self.c.i32_const(31);
            self.c.op(w::I32_SHR_U);
        }
        if !lo {
            self.c.op(w::I32_EQZ);
        }
        self.c.local(w::LOCAL_GET, a);
        self.c.local(w::LOCAL_GET, b);
        self.c.op(w::F32_NE + cd);
        self.c.op(w::SELECT);
        // nan: a NaN `a` first, then a NaN `b`; else a NaN `b` keeps `a`, a NaN `a` takes `b`.
        self.c.local(
            w::LOCAL_GET,
            if nan {
                nb;
            } else {
                na;
            },
        );
        self.c.op(w::SELECT);
        self.c.local(
            w::LOCAL_GET,
            if nan {
                na;
            } else {
                nb;
            },
        );
        self.c.op(w::SELECT);
        let pa = self.tmp(w::I32);
        self.c.local(w::LOCAL_SET, pa);
        self.c.local(w::LOCAL_GET, a);
        self.c.local(w::LOCAL_GET, b);
        self.c.local(w::LOCAL_GET, pa);
        self.c.op(w::SELECT);
        self.c.local(w::LOCAL_SET, t);
        if !nan && quiet {
            // Two NaNs: `a` with its quiet bit set.
            self.c.local(w::LOCAL_GET, a);
            if dd {
                self.c.op(w::I64_REINTERPRET_F64);
                self.c.i64_const(1i64 << 51);
                self.c.op(w::I64_OR);
                self.c.op(w::F64_REINTERPRET_I64);
            } else {
                self.c.op(w::I32_REINTERPRET_F32);
                self.c.i32_const(1i32 << 22);
                self.c.op(w::I32_OR);
                self.c.op(w::F32_REINTERPRET_I32);
            }
            self.c.local(w::LOCAL_GET, t);
            self.c.local(w::LOCAL_GET, na);
            self.c.local(w::LOCAL_GET, nb);
            self.c.op(w::I32_AND);
            self.c.op(w::SELECT);
            self.c.local(w::LOCAL_SET, t);
        }
        self.c.local(w::LOCAL_GET, t);
        self.c.local(w::LOCAL_SET, d);
    }

    // `cast_changed` lane `k`: whether casting lane `a` of operand 0 (signed `bs`) to lane `d` of operand 1
    // (signed `rs`) changed its value, or `a` is a NaN, as a bit of `mk` (the evaluator's `lane_changed`).
    fn lane_changed(
        self: &mut Self,
        mk: u32,
        k: u32,
        ops: &[Value; 4],
        tys: &[u8; 4],
        bs: bool,
        rs: bool,
        x: u32,
        z: u32,
        fr: u32,
    ) {
        let bt = lane_type(tys[0]);
        let rt = lane_type(tys[1]);
        let ff = is_float(bt);
        let tf = is_float(rt);
        if ff && tf {
            // Both in f64: unordered or not equal.
            self.ld_lane(ops[0], k, bt, false, false);
            if bt == T_F32 {
                self.c.op(w::F64_PROMOTE_F32);
            }
            self.ld_lane(ops[1], k, rt, false, false);
            if rt == T_F32 {
                self.c.op(w::F64_PROMOTE_F32);
            }
            self.c.op(w::F64_NE);
            self.mask_bit(mk, k);
            return;
        }
        if !ff && !tf {
            // Integers: the source value does not fit the result lane.
            self.ld_lane_to(x, ops[0], k, bt, bs, false);
            self.c.i32_const(0);
            self.c.local(w::LOCAL_SET, fr);
            self.narrow_lane(false, type_bits(bt, 4), bs, type_bits(rt, 4), rs, x, z, fr);
            self.c.local(w::LOCAL_GET, fr);
            self.mask_bit(mk, k);
            return;
        }
        // A float and an integer: the integer side's range [lo, hi) as f64 bounds.
        let ib = pick8(ff, rt, bt);
        let isg = if ff {
            rs;
        } else {
            bs;
        };
        let iw = type_bits(ib, 4) - isg as u32;
        let hi = 1023u64 + iw as u64 << 52;
        let lo = if isg {
            hi | 1u64 << 63;
        } else {
            0u64;
        };
        let va = self.tmp(w::F64);
        if ff {
            self.ld_lane(ops[0], k, bt, false, false);
            if bt == T_F32 {
                self.c.op(w::F64_PROMOTE_F32);
            }
        } else {
            self.ld_lane(ops[1], k, rt, false, false);
            if rt == T_F32 {
                self.c.op(w::F64_PROMOTE_F32);
            }
        }
        self.c.local(w::LOCAL_SET, va);
        // In range: va >= lo && va < hi (false for a NaN).
        self.c.local(w::LOCAL_GET, va);
        self.c.f64_const(lo);
        self.c.op(w::F64_GE);
        self.c.local(w::LOCAL_GET, va);
        self.c.f64_const(hi);
        self.c.op(w::F64_LT);
        self.c.op(w::I32_AND);
        if ff {
            // And integral: trunc(x) == x.
            self.c.local(w::LOCAL_GET, va);
            self.c.op(w::F64_TRUNC);
            self.c.local(w::LOCAL_GET, va);
            self.c.op(w::F64_EQ);
            self.c.op(w::I32_AND);
        } else {
            // And the integer back equals the source: only in range is the conversion defined.
            self.c.local(w::LOCAL_SET, fr);
            self.c.local(w::LOCAL_GET, fr);
            self.c.op(w::IF);
            self.c.op(w::BLOCK_EMPTY);
            self.ld_lane_to(x, ops[0], k, bt, bs, false);
            self.c.local(w::LOCAL_GET, va);
            self.c.op(pick8(bs, w::I64_TRUNC_F64_S, w::I64_TRUNC_F64_U));
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_EQ);
            self.c.local(w::LOCAL_SET, fr);
            self.c.op(w::END);
            self.c.local(w::LOCAL_GET, fr);
        }
        // Changed when not (in range and exact).
        self.c.op(w::I32_EQZ);
        self.mask_bit(mk, k);
    }
}

extend Gen {
    // The pointer and the length of slice operand `v` (a pointer to `{ptr, len}`) into locals `p` and
    // `len` (the length zero-extended to i64).
    fn slice_parts(self: &mut Self, v: Value, p: u32, len: u32) {
        self.get(v);
        self.load_op(T_PTR, 0);
        self.c.local(w::LOCAL_SET, p);
        self.get(v);
        self.load_op(T_I32, 4);
        self.c.op(w::I64_EXTEND_I32_U);
        self.c.local(w::LOCAL_SET, len);
    }

    // `load`, `store` and their raw forms: the vector's bytes from or to the slice's pointer at the checked
    // start, or the pointer.
    fn vmem(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4], tys: &[u8; 4]) {
        let raw = c == core::SIMD_LOAD_RAW || c == core::SIMD_STORE_RAW;
        let load = c == core::SIMD_LOAD || c == core::SIMD_LOAD_RAW;
        let vt = if load {
            t.ty;
        } else if raw {
            tys[1];
        } else {
            tys[2];
        };
        let eb = type_bytes(lane_type(vt), 4);
        let nb = type_bytes(vt, 4);
        let p = self.tmp(w::I32);
        self.get(ops[0]);
        if !raw {
            self.load_op(T_PTR, 0);
            self.get(ops[1]);
            if eb != 1 {
                self.c.i32_const(eb as i32);
                self.c.op(w::I32_MUL);
            }
            self.c.op(w::I32_ADD);
        }
        self.c.local(w::LOCAL_SET, p);
        if load {
            let d = self.vdef(i);
            self.copy_mem(self.fp, d, p, 0, nb);
        } else {
            let h = self.mhome(
                if raw {
                    ops[1];
                } else {
                    ops[2];
                },
            );
            self.copy_mem(p, 0, self.fp, h, nb);
        }
    }

    // The masked, partial and gather forms (the evaluator's `vmem_masked`): every active lane is checked
    // before the first access, the lowest failing one traps; an inactive lane never touches its element.
    fn vmem_masked(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4], tys: &[u8; 4]) {
        let op = core::simd_op(c);
        let ar = op.arity as usize;
        let store = op.rule == core::SR_MSTORE;
        let vt = unsafe tys[ar - 1];
        let vv = unsafe ops[ar - 1];
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 4);
        let n = lanes(vt);
        let ptrs = c == core::SIMD_GATHER_PTR || c == core::SIMD_SCATTER_PTR;
        let gat = c == core::SIMD_GATHER || c == core::SIMD_SCATTER || c == core::SIMD_GATHER_UNCHECKED;
        let sl = c < core::SIMD_GATHER_PTR;
        let cs = c == core::SIMD_COMPRESS_STORE;
        let p = self.tmp(w::I32);
        let len = self.tmp(w::I64);
        let act = self.tmp(w::I64);
        let x = self.tmp(w::I64);
        let ix = self.tmp(w::I64);
        let st = self.tmp(w::I64);
        let a = self.tmp(w::I32);
        if sl {
            self.slice_parts(ops[0], p, len);
        } else {
            self.get(ops[0]);
            self.c.local(w::LOCAL_SET, p);
        }
        if sl && !gat {
            self.get64(ops[1]);
            self.c.local(w::LOCAL_SET, st);
        }
        let all = trunc_to(~0u64, n);
        if c == core::SIMD_LOAD_OR {
            // The lanes below len - start, all of them past n, none when start is past len.
            self.c.local(w::LOCAL_GET, len);
            self.c.local(w::LOCAL_GET, st);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_SET, x);
            self.c.i64_const(all as i64);
            self.c.i64_const(1);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_SHL);
            self.c.i64_const(1);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const(n);
            self.c.op(w::I64_GE_U);
            self.c.op(w::SELECT);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, len);
            self.c.local(w::LOCAL_GET, st);
            self.c.op(w::I64_GE_U);
            self.c.op(w::SELECT);
            self.c.local(w::LOCAL_SET, act);
        } else {
            self.get64(unsafe ops[ar - 2]);
            if n < 64 {
                self.c.i64_const(all as i64);
                self.c.op(w::I64_AND);
            }
            self.c.local(w::LOCAL_SET, act);
        }
        if cs {
            // The packed lanes must fit from start: start <= len and the count <= len - start.
            self.c.local(w::LOCAL_GET, act);
            self.c.op(w::I64_POPCNT);
            self.c.local(w::LOCAL_SET, x);
            self.c.local(w::LOCAL_GET, len);
            self.c.local(w::LOCAL_GET, st);
            self.c.op(w::I64_LT_U);
            self.c.local(w::LOCAL_GET, len);
            self.c.local(w::LOCAL_GET, st);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_LT_U);
            self.c.op(w::I32_OR);
            self.c.op(w::IF);
            self.c.op(w::BLOCK_EMPTY);
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, st);
            self.c.local(w::LOCAL_GET, len);
            self.call_rt("__sc_vec_bounds", [w::I64, w::I64, w::I64], []);
            self.c.op(w::UNREACHABLE);
            self.c.op(w::END);
        }
        let unchecked = c == core::SIMD_GATHER_UNCHECKED;
        if sl && !cs && !unchecked {
            for k in 0..n {
                self.lane_active(act, k);
                self.c.op(w::IF);
                self.c.op(w::BLOCK_EMPTY);
                if gat {
                    self.ld_lane_to(ix, ops[1], k, lane_type(tys[1]), false, false);
                    self.c.local(w::LOCAL_GET, ix);
                    self.c.local(w::LOCAL_GET, len);
                    self.c.op(w::I64_GE_U);
                    self.lane_oob_if(k, ix, len, false);
                } else {
                    // start + k < len, without overflow: start <= len and k < len - start.
                    self.c.local(w::LOCAL_GET, len);
                    self.c.local(w::LOCAL_GET, st);
                    self.c.op(w::I64_LT_U);
                    self.c.local(w::LOCAL_GET, len);
                    self.c.local(w::LOCAL_GET, st);
                    self.c.op(w::I64_SUB);
                    self.c.i64_const(k);
                    self.c.op(w::I64_LE_U);
                    self.c.op(w::I32_OR);
                    self.lane_oob_if(k, st, len, true);
                }
                self.c.op(w::END);
            }
        }
        // A load starts from the fallback lanes.
        let mut d: u32 = 0;
        if !store {
            d = self.vdef(i);
            let hf = self.mhome(vv);
            self.copy_mem(self.fp, d, self.fp, hf, type_bytes(vt, 4));
        }
        if cs {
            self.c.local(w::LOCAL_GET, st);
            self.c.local(w::LOCAL_SET, ix);
        }
        for k in 0..n {
            self.lane_active(act, k);
            self.c.op(w::IF);
            self.c.op(w::BLOCK_EMPTY);
            // The element's address into `a`: lane k's pointer, or the base plus the element's index.
            if ptrs {
                self.c.local(w::LOCAL_GET, p);
                self.load_op(T_PTR, k * 4);
            } else {
                if gat {
                    self.ld_lane_to(ix, ops[1], k, lane_type(tys[1]), false, false);
                } else if !cs {
                    if sl {
                        self.c.local(w::LOCAL_GET, st);
                        self.c.i64_const(k);
                        self.c.op(w::I64_ADD);
                    } else {
                        self.c.i64_const(k);
                    }
                    self.c.local(w::LOCAL_SET, ix);
                }
                self.c.local(w::LOCAL_GET, p);
                self.c.local(w::LOCAL_GET, ix);
                self.c.op(w::I32_WRAP_I64);
                if eb != 1 {
                    self.c.i32_const(eb as i32);
                    self.c.op(w::I32_MUL);
                }
                self.c.op(w::I32_ADD);
            }
            self.c.local(w::LOCAL_SET, a);
            if store {
                self.ld_lane_to(x, vv, k, lt, false, true);
                self.c.local(w::LOCAL_GET, a);
                self.c.local(w::LOCAL_GET, x);
                self.lane_store(lt, true, 0);
            } else {
                self.c.local(w::LOCAL_GET, a);
                self.lane_load(lt, false, true, 0);
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, lt, true);
            }
            if cs {
                self.c.local(w::LOCAL_GET, ix);
                self.c.i64_const(1);
                self.c.op(w::I64_ADD);
                self.c.local(w::LOCAL_SET, ix);
            }
            self.c.op(w::END);
        }
        if cs && t.ty != T_NONE {
            // The active lane count.
            self.c.local(w::LOCAL_GET, ix);
            self.c.local(w::LOCAL_GET, st);
            self.c.op(w::I64_SUB);
            if wa::wtype(t.ty) == w::I32 {
                self.c.op(w::I32_WRAP_I64);
            }
            self.put(i);
        }
    }

    // Push whether bit `k` of i64 local `m` is set (i32).
    fn lane_active(self: &mut Self, m: u32, k: u32) {
        self.c.local(w::LOCAL_GET, m);
        if k != 0 {
            self.c.i64_const(k);
            self.c.op(w::I64_SHR_U);
        }
        self.c.i64_const(1);
        self.c.op(w::I64_AND);
        self.c.op(w::I32_WRAP_I64);
    }

    // The bounds trap of lane `k` when the i32 condition on the stack holds: element `x` (+ k from start
    // when `start`) of `len`.
    fn lane_oob_if(self: &mut Self, k: u32, x: u32, len: u32, start: bool) {
        self.c.op(w::IF);
        self.c.op(w::BLOCK_EMPTY);
        self.c.i64_const(k);
        self.c.local(w::LOCAL_GET, x);
        self.c.local(w::LOCAL_GET, len);
        self.c.i32_const(start as i32);
        self.call_rt("__sc_lane_bounds", [w::I64, w::I64, w::I64, w::I32], []);
        self.c.op(w::UNREACHABLE);
        self.c.op(w::END);
    }

    // The reductions and `dot` (the evaluator's `vreduce`): a left-to-right fold, the halving tree, the
    // lowest extreme lane, or the exact-result test; the result into instruction `i`.
    fn vreduce(self: &mut Self, i: u32, t: Inst, c: u8, sg: bool, ops: &[Value; 4], tys: &[u8; 4]) {
        let vt = tys[0];
        let lt = lane_type(vt);
        let n = lanes(vt);
        if c == core::SIMD_REDUCE_ADD_OVF || c == core::SIMD_REDUCE_MUL_OVF {
            self.reduce_ovf(i, c == core::SIMD_REDUCE_ADD_OVF, ops[0], lt, sg);
            return;
        }
        if c >= core::SIMD_ARG_MIN && c <= core::SIMD_ARG_MAX_NUM {
            self.reduce_arg(i, c == core::SIMD_ARG_MIN || c == core::SIMD_ARG_MIN_NUM, ops[0], lt, sg);
            return;
        }
        // The accumulator's type: the result's (`dot` widens each product to it).
        let at = t.ty;
        let add = c == core::SIMD_REDUCE_ADD || c == core::SIMD_REDUCE_ADD_ORD || c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_DOT;
        let mul = c == core::SIMD_REDUCE_MUL || c == core::SIMD_REDUCE_MUL_ORD || c == core::SIMD_REDUCE_MUL_TREE;
        let dot = c == core::SIMD_DOT;
        if is_float(lt) {
            self.reduce_float(i, c, add, mul, dot, at, ops, lt, n);
            return;
        }
        let acc = self.tmp(w::I64);
        let x = self.tmp(w::I64);
        if dot {
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, acc);
        } else {
            self.ld_lane_to(acc, ops[0], 0, lt, sg, false);
        }
        let from: u32 = if dot {
            0;
        } else {
            1;
        };
        for k in from..n {
            self.ld_lane_to(x, ops[0], k, lt, sg, false);
            if dot {
                self.c.local(w::LOCAL_GET, acc);
                self.c.local(w::LOCAL_GET, x);
                self.ld_lane(ops[1], k, lt, sg, false);
                self.c.op(w::I64_MUL);
                self.c.op(w::I64_ADD);
                self.c.local(w::LOCAL_SET, acc);
            } else if c == core::SIMD_REDUCE_AND || c == core::SIMD_REDUCE_OR || c == core::SIMD_REDUCE_XOR {
                self.c.local(w::LOCAL_GET, acc);
                self.c.local(w::LOCAL_GET, x);
                self.c.op(w::I64_AND + (c - core::SIMD_REDUCE_AND));
                self.c.local(w::LOCAL_SET, acc);
            } else if add || mul {
                self.c.local(w::LOCAL_GET, acc);
                self.c.local(w::LOCAL_GET, x);
                self.c.op(pick8(add, w::I64_ADD, w::I64_MUL));
                self.c.local(w::LOCAL_SET, acc);
            } else {
                // min takes a lane below the accumulator, max one not below: both stay extended.
                self.c.local(w::LOCAL_GET, x);
                self.c.local(w::LOCAL_GET, acc);
                self.c.op(pick8(sg, w::I64_LT_S, w::I64_LT_U));
                if c == core::SIMD_REDUCE_MIN {
                    self.sel64(acc, x, acc);
                } else {
                    self.sel64(acc, acc, x);
                }
            }
        }
        self.c.local(w::LOCAL_GET, acc);
        if wa::wtype(at) == w::I32 {
            self.c.op(w::I32_WRAP_I64);
            self.canon(at);
        }
        self.put(i);
    }

    // A float reduction (`vreduce`) of rule `c` into an `at` result over the `n` lanes (of `lt`) of operand 0
    // (and 1 for `dot`).
    fn reduce_float(
        self: &mut Self,
        i: u32,
        c: u8,
        add: bool,
        mul: bool,
        dot: bool,
        at: u8,
        ops: &[Value; 4],
        lt: u8,
        n: u32,
    ) {
        let dd = at == T_F64;
        let aty = pick8(dd, w::F64, w::F32);
        let fop = pick8(add, w::F32_ADD, w::F32_MUL) + pick8(dd, w::F64_ADD - w::F32_ADD, 0);
        let acc = self.tmp(aty);
        if c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_REDUCE_MUL_TREE {
            // Halves in a copy in the call area: lane j of the lower half with lane j of the upper, to one
            // lane.
            let eb = type_bytes(lt, 4);
            let h0 = self.mhome(ops[0]);
            self.copy_mem(self.fp, 0, self.fp, h0, n * eb);
            let mut h = n / 2;
            while h != 0 {
                for j in 0..h {
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.lane_load(lt, false, false, j * eb);
                    self.c.local(w::LOCAL_GET, self.fp);
                    self.lane_load(lt, false, false, (j + h) * eb);
                    self.c.op(fop);
                    self.lane_store(lt, false, j * eb);
                }
                h = h / 2;
            }
            self.c.local(w::LOCAL_GET, self.fp);
            self.lane_load(lt, false, false, 0);
            self.put(i);
            return;
        }
        // A sum folds from -0.0, a product from 1.0; the extremes from lane 0.
        let fold = add || mul;
        if fold {
            if add {
                self.fconst(dd, pick64(dd, 0x8000000000000000, 0x80000000));
            } else {
                self.fconst(dd, pick64(dd, f64_bits(1.0), f32_bits(1.0)));
            }
            self.c.local(w::LOCAL_SET, acc);
        } else {
            self.ld_lane_to(acc, ops[0], 0, lt, false, false);
        }
        let from: u32 = if fold {
            0;
        } else {
            1;
        };
        let fa = self.tmp(aty);
        let fb = self.tmp(aty);
        let lo = c == core::SIMD_REDUCE_MIN_NUM || c == core::SIMD_REDUCE_MINIMUM;
        for k in from..n {
            self.ld_lane(ops[0], k, lt, false, false);
            if dot {
                // The product in the result's type.
                if at != lt {
                    self.c.op(w::F64_PROMOTE_F32);
                }
                self.ld_lane(ops[1], k, lt, false, false);
                if at != lt {
                    self.c.op(w::F64_PROMOTE_F32);
                }
                self.c.op(pick8(dd, w::F64_MUL, w::F32_MUL));
            }
            self.c.local(w::LOCAL_SET, fa);
            if fold {
                self.c.local(w::LOCAL_GET, acc);
                self.c.local(w::LOCAL_GET, fa);
                self.c.op(fop);
                self.c.local(w::LOCAL_SET, acc);
            } else {
                // The kept operand itself, as the lane rule's.
                self.fminmax(dd, lo, c >= core::SIMD_REDUCE_MINIMUM, false, acc, acc, fa, fb);
            }
        }
        self.c.local(w::LOCAL_GET, acc);
        self.put(i);
    }

    // `reduce_add_ovf` (`add`) or `reduce_mul_ovf` of vector `v` (lanes of `lt`, signed `sg`): 1 when the
    // exact sum or product does not fit the lane type (the evaluator's `exact_fits`).
    fn reduce_ovf(self: &mut Self, i: u32, add: bool, v: Value, lt: u8, sg: bool) {
        let lb = type_bits(lt, 4);
        let n = lanes(self.vt(v));
        let x = self.tmp(w::I64);
        let y = self.tmp(w::I64);
        let z = self.tmp(w::I64);
        let lo = self.tmp(w::I64);
        let hi = self.tmp(w::I64);
        let r = self.tmp(w::I32);
        self.c.i64_const(pick64(add, 0, 1) as i64);
        self.c.local(w::LOCAL_SET, lo);
        self.c.i64_const(0);
        self.c.local(w::LOCAL_SET, hi);
        if add {
            // The sum in 128 bits: lo, and hi taking each lane's sign and carry.
            for k in 0..n {
                self.ld_lane_to(x, v, k, lt, sg, false);
                self.c.local(w::LOCAL_GET, lo);
                self.c.local(w::LOCAL_GET, x);
                self.c.op(w::I64_ADD);
                self.c.local(w::LOCAL_SET, z);
                self.c.local(w::LOCAL_GET, hi);
                if sg {
                    self.c.local(w::LOCAL_GET, x);
                    self.c.i64_const(63);
                    self.c.op(w::I64_SHR_S);
                    self.c.op(w::I64_ADD);
                }
                self.c.local(w::LOCAL_GET, z);
                self.c.local(w::LOCAL_GET, lo);
                self.c.op(w::I64_LT_U);
                self.c.op(w::I64_EXTEND_I32_U);
                self.c.op(w::I64_ADD);
                self.c.local(w::LOCAL_SET, hi);
                self.c.local(w::LOCAL_GET, z);
                self.c.local(w::LOCAL_SET, lo);
            }
            // Not fitting: signed, hi is not lo's sign or lo leaves the lane; unsigned, hi is not 0 or lo
            // leaves the lane.
            self.c.local(w::LOCAL_GET, hi);
            if sg {
                self.c.local(w::LOCAL_GET, lo);
                self.c.i64_const(63);
                self.c.op(w::I64_SHR_S);
                self.c.op(w::I64_NE);
                if lb < 64 {
                    self.sext_bits(lo, lb);
                    self.c.local(w::LOCAL_GET, lo);
                    self.c.op(w::I64_NE);
                    self.c.op(w::I32_OR);
                }
            } else {
                self.c.i64_const(0);
                self.c.op(w::I64_NE);
                if lb < 64 {
                    self.c.local(w::LOCAL_GET, lo);
                    self.c.i64_const(lb);
                    self.c.op(w::I64_SHR_U);
                    self.c.i64_const(0);
                    self.c.op(w::I64_NE);
                    self.c.op(w::I32_OR);
                }
            }
            self.put(i);
            return;
        }
        // The product of the magnitudes: `hi` gathers the bits past 64, `y` the sign, `z` the zero lanes.
        self.c.i64_const(0);
        self.c.local(w::LOCAL_SET, y);
        self.c.i64_const(0);
        self.c.local(w::LOCAL_SET, z);
        for k in 0..n {
            self.ld_lane_to(x, v, k, lt, sg, false);
            if sg {
                self.c.local(w::LOCAL_GET, y);
                self.c.local(w::LOCAL_GET, x);
                self.c.i64_const(63);
                self.c.op(w::I64_SHR_U);
                self.c.op(w::I64_XOR);
                self.c.local(w::LOCAL_SET, y);
                // |x| (the lowest value's magnitude is its unsigned bits).
                self.c.i64_const(0);
                self.c.local(w::LOCAL_GET, x);
                self.c.op(w::I64_SUB);
                self.c.local(w::LOCAL_GET, x);
                self.c.local(w::LOCAL_GET, x);
                self.c.i64_const(0);
                self.c.op(w::I64_LT_S);
                self.c.op(w::SELECT);
                self.c.local(w::LOCAL_SET, x);
            }
            self.c.local(w::LOCAL_GET, z);
            self.c.local(w::LOCAL_GET, x);
            self.c.op(w::I64_EQZ);
            self.c.op(w::I64_EXTEND_I32_U);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, z);
            // hi |= the high word of lo * x; lo = lo * x.
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.local(w::LOCAL_GET, lo);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, x);
            self.c.i64_const(0);
            self.call_rt("__multi3", [w::I32, w::I64, w::I64, w::I64, w::I64], []);
            self.c.local(w::LOCAL_GET, hi);
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(T_I64, 8);
            self.c.op(w::I64_OR);
            self.c.local(w::LOCAL_SET, hi);
            self.c.local(w::LOCAL_GET, self.fp);
            self.load_op(T_I64, 0);
            self.c.local(w::LOCAL_SET, lo);
        }
        // Not fitting: past 64 bits, or the magnitude past the limit (the negative limit one more).
        let lim = if sg {
            1u64 << (lb - 1) as u64;
        } else {
            trunc_to(~0u64, lb);
        };
        self.c.local(w::LOCAL_GET, lo);
        self.c.i64_const(lim as i64);
        self.c.op(w::I64_GT_U);
        if sg {
            // lo == lim fits only negative.
            self.c.local(w::LOCAL_GET, lo);
            self.c.i64_const(lim as i64);
            self.c.op(w::I64_EQ);
            self.c.local(w::LOCAL_GET, y);
            self.c.op(w::I64_EQZ);
            self.c.op(w::I32_AND);
            self.c.op(w::I32_OR);
        }
        self.c.local(w::LOCAL_GET, hi);
        self.c.i64_const(0);
        self.c.op(w::I64_NE);
        self.c.op(w::I32_OR);
        self.c.local(w::LOCAL_SET, r);
        // A zero lane: the product is 0, which fits.
        self.c.i32_const(0);
        self.c.local(w::LOCAL_GET, r);
        self.c.local(w::LOCAL_GET, z);
        self.c.op(w::I32_WRAP_I64);
        self.c.op(w::SELECT);
        self.put(i);
    }

    // `arg_min` (`min`) or `arg_max` and their `_num` forms of vector `v`: the lowest lane whose value beats
    // every lane before it; a NaN lane never does, -0.0 is below +0.0; the lane count when none.
    fn reduce_arg(self: &mut Self, i: u32, min: bool, v: Value, lt: u8, sg: bool) {
        let n = lanes(self.vt(v));
        let rd = self.tmp(w::I64);
        if !is_float(lt) {
            // The best value in `y`; a strictly better lane takes over.
            let x = self.tmp(w::I64);
            let y = self.tmp(w::I64);
            let c = if min {
                pick8(sg, w::I64_LT_S, w::I64_LT_U);
            } else {
                pick8(sg, w::I64_GT_S, w::I64_GT_U);
            };
            let take = self.tmp(w::I32);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, rd);
            self.ld_lane_to(y, v, 0, lt, sg, false);
            for k in 1..n {
                self.ld_lane_to(x, v, k, lt, sg, false);
                self.c.local(w::LOCAL_GET, x);
                self.c.local(w::LOCAL_GET, y);
                self.c.op(c);
                self.c.local(w::LOCAL_SET, take);
                self.c.local(w::LOCAL_GET, take);
                self.sel64(y, x, y);
                self.c.i64_const(k);
                self.c.local(w::LOCAL_GET, rd);
                self.c.local(w::LOCAL_GET, take);
                self.c.op(w::SELECT);
                self.c.local(w::LOCAL_SET, rd);
            }
        } else {
            let dd = lt == T_F64;
            let ft = pick8(dd, w::F64, w::F32);
            let cd = pick8(dd, w::F64_EQ - w::F32_EQ, 0);
            let fa = self.tmp(ft);
            let fb = self.tmp(ft);
            let take = self.tmp(w::I32);
            self.c.i64_const(n);
            self.c.local(w::LOCAL_SET, rd);
            for k in 0..n {
                self.ld_lane_to(fa, v, k, lt, false, false);
                // A NaN lane never takes.
                self.c.local(w::LOCAL_GET, fa);
                self.c.local(w::LOCAL_GET, fa);
                self.c.op(w::F32_EQ + cd);
                self.c.op(w::IF);
                self.c.op(w::BLOCK_EMPTY);
                if k == 0 {
                    self.c.i32_const(1);
                } else {
                    // No best yet, strictly beyond the best, or equal with differing signs and the lane's
                    // sign on the min side.
                    self.c.local(w::LOCAL_GET, rd);
                    self.c.i64_const(n);
                    self.c.op(w::I64_EQ);
                    self.c.local(w::LOCAL_GET, fa);
                    self.c.local(w::LOCAL_GET, fb);
                    self.c.op(pick8(min, w::F32_LT, w::F32_GT) + cd);
                    self.c.op(w::I32_OR);
                    self.c.local(w::LOCAL_GET, fa);
                    self.c.local(w::LOCAL_GET, fb);
                    self.c.op(w::F32_EQ + cd);
                    self.float_sign(fa, dd);
                    self.float_sign(fb, dd);
                    self.c.op(w::I32_NE);
                    self.c.op(w::I32_AND);
                    self.float_sign(fa, dd);
                    if !min {
                        self.c.op(w::I32_EQZ);
                    }
                    self.c.op(w::I32_AND);
                    self.c.op(w::I32_OR);
                }
                self.c.local(w::LOCAL_SET, take);
                self.c.local(w::LOCAL_GET, take);
                self.c.op(w::IF);
                self.c.op(w::BLOCK_EMPTY);
                self.c.local(w::LOCAL_GET, fa);
                self.c.local(w::LOCAL_SET, fb);
                self.c.i64_const(k);
                self.c.local(w::LOCAL_SET, rd);
                self.c.op(w::END);
                self.c.op(w::END);
            }
        }
        self.c.local(w::LOCAL_GET, rd);
        if wa::wtype(self.b().insts[i as usize].ty) == w::I32 {
            self.c.op(w::I32_WRAP_I64);
        }
        self.put(i);
    }

    // Push float local `x`'s sign bit (i32; f64 when `dd`).
    fn float_sign(self: &mut Self, x: u32, dd: bool) {
        self.c.local(w::LOCAL_GET, x);
        if dd {
            self.c.op(w::I64_REINTERPRET_F64);
            self.c.i64_const(63);
            self.c.op(w::I64_SHR_U);
            self.c.op(w::I32_WRAP_I64);
        } else {
            self.c.op(w::I32_REINTERPRET_F32);
            self.c.i32_const(31);
            self.c.op(w::I32_SHR_U);
        }
    }

    // The index forms (`swizzle`, `shuffle`, `swizzle_or_zero`, `swizzle_oob`) and `compress`, `expand`
    // (the evaluator's `vrearrange`): lane bits move as they are.
    fn vrearrange(self: &mut Self, i: u32, t: Inst, c: u8, ops: &[Value; 4], tys: &[u8; 4]) {
        let rule = core::simd_op(c).rule;
        let vt = if rule == core::SR_MASKED {
            tys[1];
        } else {
            tys[0];
        };
        let lt = lane_type(vt);
        let eb = type_bytes(lt, 4);
        let n = lanes(vt);
        let x = self.tmp(w::I64);
        let ix = self.tmp(w::I64);
        let ad = self.tmp(w::I32);
        if rule == core::SR_MASKED {
            // From `fill`, then compress: the active lanes of v from position 0; expand: active lane j takes
            // the next packed lane.
            let d = self.vdef(i);
            let hf = self.mhome(ops[2]);
            self.copy_mem(self.fp, d, self.fp, hf, n * eb);
            let m = self.tmp(w::I64);
            self.get64(ops[0]);
            self.c.local(w::LOCAL_SET, m);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, ix);
            // The packed side's frame offset: the result for compress, v for expand.
            let base = if c == core::SIMD_COMPRESS {
                d;
            } else {
                self.mhome(ops[1]);
            };
            for k in 0..n {
                self.lane_active(m, k);
                self.c.op(w::IF);
                self.c.op(w::BLOCK_EMPTY);
                self.c.local(w::LOCAL_GET, self.fp);
                self.c.local(w::LOCAL_GET, ix);
                self.c.op(w::I32_WRAP_I64);
                if eb != 1 {
                    self.c.i32_const(eb as i32);
                    self.c.op(w::I32_MUL);
                }
                self.c.op(w::I32_ADD);
                self.c.local(w::LOCAL_SET, ad);
                if c == core::SIMD_COMPRESS {
                    self.ld_lane_to(x, ops[1], k, lt, false, true);
                    self.c.local(w::LOCAL_GET, ad);
                    self.c.local(w::LOCAL_GET, x);
                    self.lane_store(lt, true, base);
                } else {
                    self.c.local(w::LOCAL_GET, ad);
                    self.lane_load(lt, false, true, base);
                    self.c.local(w::LOCAL_SET, x);
                    self.st_lane(x, d, k, lt, true);
                }
                self.c.local(w::LOCAL_GET, ix);
                self.c.i64_const(1);
                self.c.op(w::I64_ADD);
                self.c.local(w::LOCAL_SET, ix);
                self.c.op(w::END);
            }
            return;
        }
        let cnt = if rule == core::SR_INDEX {
            self.b().pool[t.c as usize];
        } else {
            lanes(tys[1]);
        };
        if c == core::SIMD_SWIZZLE_OOB {
            // The mask of the lanes whose index is past the lanes.
            let mk = self.tmp(w::I64);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_SET, mk);
            let ilt = lane_type(tys[1]);
            for k in 0..cnt {
                self.ld_lane(ops[1], k, ilt, false, false);
                self.c.i64_const(n);
                self.c.op(w::I64_GE_U);
                self.mask_bit(mk, k);
            }
            self.put_mask(i, mk);
            return;
        }
        let d = self.vdef(i);
        if rule == core::SR_INDEX {
            for k in 0..cnt {
                let j = self.b().pool[(t.c + 1 + k) as usize];
                if j < n {
                    self.ld_lane_to(x, ops[0], j, lt, false, true);
                } else if c == core::SIMD_SHUFFLE {
                    self.ld_lane_to(x, ops[1], j - n, lt, false, true);
                } else {
                    self.c.i64_const(0);
                    self.c.local(w::LOCAL_SET, x);
                }
                self.st_lane(x, d, k, lt, true);
            }
            return;
        }
        // `swizzle_or_zero`: lane k is v[idx[k]], or 0 past the lanes (the index clamped before the load).
        let ilt = lane_type(tys[1]);
        let hv = self.mhome(ops[0]);
        let inr = self.tmp(w::I32);
        for k in 0..cnt {
            self.ld_lane_to(ix, ops[1], k, ilt, false, false);
            self.c.local(w::LOCAL_GET, ix);
            self.c.i64_const(n);
            self.c.op(w::I64_LT_U);
            self.c.local(w::LOCAL_SET, inr);
            // The element at v + (in range ? idx : 0) * eb.
            self.c.local(w::LOCAL_GET, self.fp);
            self.c.local(w::LOCAL_GET, ix);
            self.c.op(w::I32_WRAP_I64);
            self.c.i32_const(0);
            self.c.local(w::LOCAL_GET, inr);
            self.c.op(w::SELECT);
            if eb != 1 {
                self.c.i32_const(eb as i32);
                self.c.op(w::I32_MUL);
            }
            self.c.op(w::I32_ADD);
            self.lane_load(lt, false, true, hv);
            self.c.i64_const(0);
            self.c.local(w::LOCAL_GET, inr);
            self.c.op(w::SELECT);
            self.c.local(w::LOCAL_SET, x);
            self.st_lane(x, d, k, lt, true);
        }
    }
}

// ---- Inline assembly ----

extend Gen {
    // The text of body message `m`.
    const fn msg_text(self: &Self, m: u32) str {
        let p = self.p();
        return p.spell(p.msgs[self.b().msgs[m as usize] as usize]);
    }

    // Inline assembly (`O_ASM`) without operands: its instructions in place, which leave the operand
    // stack as they find it. A template that names operands has no form here.
    fn asm_inst(self: &mut Self, t: Inst) bool {
        let b = self.b();
        if asm_nout(b, t.c) + asm_nin(b, t.c) != 0 {
            return self.refuse("inline assembly with operands on wasm");
        }
        let tpl = String::from_str(self.msg_text(asm_template(b, t.c)));
        return self.asm_text(tpl.as_str());
    }

    // Assemble template `text` onto the code, its symbols as relocations.
    fn asm_text(self: &mut Self, text: str) bool {
        let mut sts = Vector::<asmr::Stmt>::new();
        asmr::statements(text, true, &mut sts);
        let none = Vector::<asmr::WasmType>::new();
        for k in 0..sts.len() {
            let body = sts[k].body.as_str();
            if sts[k].labels.len() != 0 || body.len() != 0 && body.byte_at(0) == b'.' {
                return self.refuse("inline assembly with a label or a directive on wasm");
            }
            if body.len() == 0 {
                continue;
            }
            let at = self.c.len();
            let mut fx = Vector::<wasm_asm::Fix>::new();
            let mut e = String::new();
            if !wasm_asm::assemble(body, &mut self.c.bytes, &mut fx, &mut e) {
                self.err.format_into("inline assembly: {}", e.as_str());
                return false;
            }
            for q in 0..fx.len() {
                let mut rel = wo::WRel { kind: 0, off: 0, sym: 0, addend: 0 };
                if !asmr::wasm_reloc(self.obj(), &fx[q], at + fx[q].at, &none, &mut rel, &mut e) {
                    self.err.format_into("inline assembly: {}", e.as_str());
                    return false;
                }
                self.rels.push(rel);
            }
        }
        return true;
    }

    // A naked function: its templates' code alone, then the body's `end`.
    fn naked(self: &mut Self, s: u32) bool {
        self.c.clear();
        self.rels.truncate(0);
        self.rows.truncate(0);
        self.locals.truncate(0);
        let b = self.b();
        for i in 0..b.insts.len() {
            if b.insts[i].op != O_ASM {
                continue;
            }
            let tpl = String::from_str(self.msg_text(asm_template(b, b.insts[i].c)));
            if !self.asm_text(tpl.as_str()) {
                return false;
            }
        }
        self.c.op(w::END);
        return self.finish(s);
    }
}
