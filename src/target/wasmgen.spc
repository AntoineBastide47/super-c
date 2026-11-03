// The wasm32 code generator: one LIR body into one wasm function of the object (`wasmobj`).
//
// wasm has no registers: every scalar value is a local of its wasm type (i8, i16, i32 and pointers in i32
// locals, zero-extended as the evaluator keeps them), constants and addresses rematerialize at each use,
// and i128 and vector values live in frame memory but a vector of 4, 8 or 16 bytes with simd128
// (`Package.vector`), which lives in the low bytes of a v128 local unless an instruction computes it lane by
// lane (`vec_homes`). Values share a local (a frame home) when their live
// ranges, in the analysis pass's layout positions (`codegen::live`), do not overlap; a block parameter's
// range starts at its block and covers the edges into it, which write it (it takes an argument's local
// when one is free), and a value whose range ends in its own block frees its local at its last use.
//
// The frame is on the linear stack below the imported global `__stack_pointer`: the call area (copies of
// arguments, variadic buffers, results in memory) at its base, then the LIR slots, the entry's spills and
// the homes of the memory values. Control flow is Ramsey's structured translation (`codegen::structure`),
// run with an explicit task stack so a deep dominator tree does not deepen the compiler's own stack.
import lir::ir as *;
import lir::verify as lver;
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
import std::float as fl;

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
    pub(package) kind: u8,
    pub(package) blk: u32,
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
    pub(package) kind: u8,
    pub(package) a: u32,
    pub(package) b: u32,
    pub(package) x: u32, // TK_SWITCH: the switch's block
}

extend Task as Copy {}

/// The code generator of one object.
pub(package) struct Gen {
    pub(package) err: String, // the first refusal, empty when every body compiled
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
    asm_code: bool, // the body holds assembled code, whose local accesses `Code::local` does not see
    ret_end: u32, // the code byte past the last `return`
    nxt: Vector<u32>, // `stack_values`: per local access, the next of its local (NONE: none)
    last_of: Vector<u32>, // `stack_values`: per local, its access seen last
    cuts: Vector<u64>, // `stack_values`: the code ranges it removes, start << 32 | end
    me: wa::WSig, // the body's own signature
    cs: wa::WSig, // a call's
    enc: Vector<u8>,
    nwp: u32, // the wasm parameters
    locals: Vector<u8>, // the types of the locals past the parameters
    local_of: Vector<u32>, // per value index, its local (NONE: rematerialized, in memory, or unused)
    simd: bool, // vectors of up to 16 bytes compute in v128 values (`Package.vector`: simd128)
    vreg: Vector<bool>, // per value index, a vector in a v128 local (`vec_homes`)
    home: Vector<u32>, // per value index, the frame offset of a memory value (NONE: none)
    remat: Vector<bool>, // per instruction
    free: Vector<Vector<u32>>, // per class, the free locals
    lref: Vector<u32>, // `assign`: per local, the values holding it
    gone: Vector<bool>, // `assign`: per value index, whether its local or home is released
    seen: Vector<u32>, // `dead_from`: per block, the walk that reached it
    walk: u32, // `dead_from`: the walks so far
    budget: u32, // `dead_from`: the instructions the body's walks may still read
    wstack: Vector<u32>,
    wsucc: Vector<u32>,
    free_home: Vector<u64>, // size << 32 | offset of a free home
    scratch: Vector<Vector<u32>>, // per class, the scratch locals (live within one instruction)
    nscr: Vector<u32>, // per class, the scratch locals the current instruction took
    fp: u32, // the frame base local, NONE without a frame
    osp: u32, // the stack pointer at entry, for a frame aligned past 16 bytes (NONE: none)
    frame: u32,
    falign: u32,
    call_area: u32,
    warm_area: u32, // the call area the blocks but the failure paths (`fails`) need
    /// Per block, whether it is a failure path's: a rare block (`BLOCK_RARE`) that ends in a panic or a
    /// trap, or whose every successor is a failure path's (`failing`).
    fails: Vector<bool>,
    /// Per block, whether it opens the failure paths' frame (`lazy_frame`): a failure-path block that a
    /// block of no failure path jumps to. Empty: the prologue sets the frame up.
    cold_entry: Vector<bool>,
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
    osym: Vector<u32>, // per package symbol, its object symbol in this generator's object (NONE until used)
    itpl: Vector<str<'static>>, // per symbol of the body at hand, its intrinsic's instructions (`intrin::of_symbols`)
    sp_sym: u32,
    table_sym: u32,
    local: bool, // the function compiling is a local copy
    msg_sym: Map<String, u32>, // per C string text, its data symbol
    msg_key: String, // `cstr`'s lookup key
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
    pub(package) fn new(pkg: &Package, o: &mut wo::WObj) Gen {
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
            asm_code: false,
            ret_end: NONE,
            nxt: Vector::<u32>::new(),
            last_of: Vector::<u32>::new(),
            cuts: Vector::<u64>::new(),
            me: wa::WSig::new(),
            cs: wa::WSig::new(),
            enc: Vector::<u8>::new(),
            nwp: 0,
            locals: Vector::<u8>::new(),
            local_of: Vector::<u32>::new(),
            simd: pkg.vector >= 16,
            vreg: Vector::<bool>::new(),
            home: Vector::<u32>::new(),
            remat: Vector::<bool>::new(),
            free: free,
            lref: Vector::<u32>::new(),
            gone: Vector::<bool>::new(),
            seen: Vector::<u32>::new(),
            walk: 0,
            budget: 0,
            wstack: Vector::<u32>::new(),
            wsucc: Vector::<u32>::new(),
            free_home: Vector::<u64>::new(),
            scratch: scratch,
            nscr: nscr,
            fp: NONE,
            osp: NONE,
            frame: 0,
            falign: 16,
            call_area: 0,
            warm_area: 0,
            fails: Vector::<bool>::new(),
            cold_entry: Vector::<bool>::new(),
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
            itpl: Vector::<str<'static>>::new(),
            sp_sym: NONE,
            table_sym: NONE,
            local: false,
            msg_sym: Map::<String, u32>::new(),
            msg_key: String::new(),
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
        return self.pkg_osym(self.b().syms[s as usize]);
    }

    // The object symbol of package symbol `ps`.
    fn pkg_osym(self: &mut Self, ps: u32) u32 {
        if self.osym.len() == 0 {
            fill(&mut self.osym, self.p().syms.len(), NONE);
        }
        if self.osym[ps as usize] == NONE {
            self.osym[ps as usize] = self.pkg_osym_new(ps);
        }
        return self.osym[ps as usize];
    }

    fn pkg_osym_new(self: &mut Self, ps: u32) u32 {
        let y = self.p().syms[ps as usize];
        let nm0 = self.p().spell(y.name);
        // `__sc_x_<name>` is a C library name's alias (a macro of a scoped extern header). The C entry
        // `main` takes argc and argv (`cemit_main_wrapper`), which a wasm C compiler names
        // `__main_argc_argv`: the name the entry point of `std::rt::libc` calls.
        let nm = if y.def == NONE && nm0.starts_with("__sc_x_") {
            nm0.slice(7, nm0.len())
        } else if y.kind == SK_FUNC && nm0 == "main" {
            "__main_argc_argv"
        } else {
            nm0
        };
        let kind = if y.kind == SK_FUNC {
            wo::K_FUNC
        } else {
            wo::K_DATA
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
                w::GLOBAL_SET
            } else {
                w::GLOBAL_GET
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
        // The key in a reused buffer: a text seen before allocates nothing.
        self.msg_key.clear();
        self.msg_key.push_str(text);
        if let Some(k) = self.msg_sym.get(&self.msg_key) {
            return *k;
        }
        let name = format("__sc_msg.{}", self.cstr_n);
        self.cstr_n += 1;
        let o = self.obj();
        let k = o.sym(&name, wo::K_DATA);
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
        self.msg_sym.insert(self.msg_key.clone(), k);
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
    pub(package) fn func(self: &mut Self, s: u32, local: bool) bool {
        self.local = local;
        let ps = self.p().syms[s as usize];
        self.bp = &self.p().bodies[ps.def as usize];
        let b = self.b();
        if self.p().ptr_bytes != 4 {
            return self.refuse("a data model whose pointers are not 32-bit");
        }
        intrin::of_symbols(self.p(), b, "wasm32", &mut self.itpl);
        self.lv.fold_ops = lv::FOLD_FREE_ZEXT | lv::FOLD_CMP;
        self.lv.run(b);
        self.sh.run(b, &self.lv);
        wa::classify(b, b.sig, self.vregs, &mut self.me);
        if self.me.unknown {
            return self.refuse("the signature passes an aggregate whose C class is unknown");
        }
        if b.naked {
            return self.naked(s);
        }
        self.c.clear();
        self.rels.truncate(0);
        self.rows.truncate(0);
        self.locals.truncate(0);
        self.labels.truncate(0);
        self.asm_code = false;
        self.ret_end = NONE;
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
        self.vec_homes();
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
        // A return that ends the code: the function's end returns the values.
        if self.ret_end == self.c.len() {
            let _ = self.c.bytes.pop();
        } else {
            self.c.op(w::UNREACHABLE);
        }
        self.c.op(w::END);
        if !self.asm_code {
            self.stack_values();
        }
        return self.finish(s);
    }

    // The values an instruction or an edge writes to their local that the code reads at once (`local.set l`
    // then `local.get l`, adjacent bytes: the read runs right after the write, and only then) stay on the
    // operand stack. Both go when one instruction reads the value (VW_ONE) and `l` is not read again, or
    // its next access in the code writes it with no control instruction between (`Code.ctl`): every path
    // from the read runs that write before any other read of `l`; or when a `return` follows the read,
    // which ends its path. Else the write becomes `local.tee l`. The scratch locals of one instruction's
    // code, which its own loops may carry, stay. The relocations and the line rows move with the code.
    fn stack_values(self: &mut Self) {
        let n = self.c.acc.len();
        if n < 2 {
            return;
        }
        let nl = self.nwp as usize + self.locals.len();
        fill(&mut self.nxt, n, NONE);
        fill(&mut self.last_of, nl, NONE);
        let mut i = n;
        // Each step visits one access, last first.
        while i > 0 {
            i -= 1;
            let l = (self.c.acc[i] & 0xFFFFFFFF) as usize;
            self.nxt[i] = self.last_of[l];
            self.last_of[l] = i as u32;
        }
        self.cuts.truncate(0);
        // The first control instruction past the read the step sees.
        let mut cq: usize = 0;
        for i in 0..n - 1 {
            let j = self.nxt[i];
            if (self.c.acc_op[i] & ~VW_ONE) != (w::LOCAL_SET | VW_VALUE) || j == NONE || (self.c.acc_op[j as usize] & VW_OP) != w::LOCAL_GET {
                continue;
            }
            let l = (self.c.acc[i] & 0xFFFFFFFF) as u32;
            let at = (self.c.acc[i] >> 32) as u32;
            let len = 1 + uleb_len(l);
            let jat = (self.c.acc[j as usize] >> 32) as u32;
            if jat != at + len {
                continue;
            }
            let k = self.nxt[j as usize];
            while cq < self.c.ctl.len() && self.c.ctl[cq] < jat {
                cq += 1;
            }
            let written = k == NONE || (self.c.acc_op[k as usize] & VW_OP) != w::LOCAL_GET && (cq == self.c.ctl.len() || self.c.ctl[cq] >= (self.c.acc[k as usize] >> 32) as u32);
            // A read a `return` takes next ends its path: nothing reads the write again.
            if self.c.bytes[(jat + len) as usize] != w::RETURN && ((self.c.acc_op[i] & VW_ONE) == 0 || !written) {
                self.c.bytes[at as usize] = w::LOCAL_TEE;
                self.cuts.push(jat as u64 << 32 | (jat + len) as u64);
            } else {
                self.cuts.push(at as u64 << 32 | (jat + len) as u64);
            }
        }
        if self.cuts.len() == 0 {
            return;
        }
        // The code without the cuts, which follow in order.
        let mut out: usize = 0;
        let mut q: usize = 0;
        let total = self.c.bytes.len();
        for p in 0..total {
            while q < self.cuts.len() && (self.cuts[q] & 0xFFFFFFFF) as usize <= p {
                q += 1;
            }
            if q < self.cuts.len() && (self.cuts[q] >> 32) as usize <= p {
                continue;
            }
            self.c.bytes[out] = self.c.bytes[p];
            out += 1;
        }
        self.c.bytes.truncate(out);
        // The relocations and the rows in code order, each walk past the cuts before them.
        let mut cut = Cursor { q: 0, d: 0 };
        self.body_at = self.moved(&mut cut, self.body_at);
        cut = Cursor { q: 0, d: 0 };
        for r in 0..self.rels.len() {
            let o = self.rels[r].off;
            self.rels.index_mut(r).off = self.moved(&mut cut, o);
        }
        // Rows at one byte after the move: the last stands.
        cut = Cursor { q: 0, d: 0 };
        let mut m: usize = 0;
        for r in 0..self.rows.len() {
            let row = self.rows[r];
            let o = self.moved(&mut cut, (row >> 32) as u32) as u64;
            if m != 0 && self.rows[m - 1] >> 32 == o {
                m -= 1;
            }
            self.rows[m] = o << 32 | row & 0xFFFFFFFF;
            m += 1;
        }
        self.rows.truncate(m);
    }

    // Code byte `o` past the cuts (`stack_values`), `o` at least the last one `at` saw: less the bytes cut
    // before it; one inside a cut, at the cut's start.
    fn moved(self: &Self, at: &mut Cursor, o: u32) u32 {
        // Each step passes one cut.
        while at.q < self.cuts.len() && self.cuts[at.q] as u32 <= o {
            at.d += self.cuts[at.q] as u32 - (self.cuts[at.q] >> 32) as u32;
            at.q += 1;
        }
        if at.q < self.cuts.len() && (self.cuts[at.q] >> 32) as u32 < o {
            return (self.cuts[at.q] >> 32) as u32 - at.d;
        }
        return o - at.d;
    }

    // The frame: the call area, the slots, the entry's spills; the homes follow (`assign`). False when a
    // call passes an aggregate whose class is unknown.
    fn frame_layout(self: &mut Self) bool {
        let b = self.b();
        let mut area: u32 = 0;
        // Per instruction, whether its block is a failure path's (`fails`).
        self.failing();
        let mut cold = Vector::<bool>::with_capacity(b.insts.len());
        cold.resize_default(b.insts.len());
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                cold[i as usize] = self.fails[k];
            }
        }
        self.warm_area = 0;
        for k in 0..b.insts.len() {
            let t = b.insts[k];
            let mut need: u32 = 0;
            if t.op == O_CALL || t.op == O_CALLIND {
                wa::classify(b, t.b, self.vregs, &mut self.cs);
                if self.cs.unknown {
                    return self.refuse("a call passes an aggregate whose C class is unknown");
                }
                need = self.call_bytes(t);
            } else if t.op == O_MULO && t.ty == T_I64 {
                need = 16;
            } else if t.op == O_VOP && !(self.simd && self.vop_form(t)) {
                // A 64-bit lane product's high word (compiler-rt) or a halving reduction's copy.
                need = 64;
            } else if t.op == O_JMP || t.op == O_BR || t.op == O_SWITCH {
                // An edge passing several memory values goes through the area.
                b.succ_edges(t, &mut self.succ);
                for e in 0..self.succ.len() {
                    let mut n: u32 = 0;
                    for q in 0..b.edge_nargs(self.succ[e]) {
                        let a = b.edge_arg(self.succ[e], q);
                        if self.mem_v(a) {
                            n += type_bytes(self.vt(a), 4) + 15 & ~15u32;
                        }
                    }
                    need = ast_max(need, n);
                }
            }
            area = ast_max(area, need);
            if !cold[k] {
                self.warm_area = ast_max(self.warm_area, need);
            }
        }
        self.call_area = area + 15 & ~15u32;
        let mut at = self.call_area;
        self.falign = 16;
        fill(&mut self.slot_off, b.slots.len(), 0);
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
        if lver::protected(self.p().protect, b) {
            at = at + 3 & ~3u32;
            self.canary = at;
            at += 4;
        }
        // The entry's spills: a parameter or result passed as one scalar of an aggregate.
        let np = b.pool[b.sig as usize];
        fill(&mut self.pspill, np as usize, NONE);
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
        fill(&mut self.mk_at, nb + 1, 0);
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

const fn pick_v(c: bool, a: Value, b: Value) Value {
    if c {
        return a;
    }
    return b;
}

const fn pick8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}

// A walk over the cuts of `Gen::stack_values` in code order: the next cut, the bytes the ones before it cut.
struct Cursor {
    q: usize,
    d: u32,
}

// The instructions the walks of `Gen::dead_from` may read per body.
const WALK_BUDGET: u32 = 16384;

// The marks `Gen::value_write` puts on a local access's opcode (`Code.acc_op`): the write of a value, of one
// read; the opcode's bits.
const VW_VALUE: u8 = 0x80;
const VW_ONE: u8 = 0x40;
const VW_OP: u8 = 0x3F;

// The bytes of `x` as an unsigned LEB128.
const fn uleb_len(x: u32) u32 {
    let mut n: u32 = 1;
    let mut y = x >> 7;
    // Each step takes 7 bits.
    while y != 0 {
        n += 1;
        y >>= 7;
    }
    return n;
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
        fill(&mut self.local_of, n, NONE);
        fill(&mut self.home, n, NONE);
        fill(&mut self.gone, n, false);
        fill(&mut self.lref, self.nwp as usize, 0);
        fill(&mut self.seen, b.blocks.len(), 0);
        self.walk = 0;
        self.budget = WALK_BUDGET;
        let npos = self.lv.order.len();
        // Ranges: from the definition's position to `end` (`Live::ranges` widened a block parameter's end
        // over the edges into it). A block parameter's range starts at its block: an edge writes it on its
        // own path, past the branch, where no value its source's position holds lives on (that value would
        // live in the target's position).
        let mut start = Vector::<u32>::new();
        let mut end = Vector::<u32>::new();
        fill(&mut start, n, NONE);
        fill(&mut end, n, 0);
        for x in 0..n {
            let d = self.lv.def_blk[x];
            if d != NONE && self.lv.pos[d as usize] != NONE {
                start[x] = self.lv.pos[d as usize];
                end[x] = self.lv.end[x];
            }
        }
        let ni = b.insts.len() as u32;
        // The entry's parameters: where the convention passes them.
        self.entry_params();
        let e0 = ni + b.blocks[0].param_start;
        let e1 = e0 + b.pool[b.sig as usize];
        // Which values need storage: a used result that does not rematerialize, a parameter. An entry
        // parameter in its wasm parameter frees it past its range.
        let mut need = Vector::<bool>::new();
        need.resize_default(n);
        for x in 0..n {
            if start[x] == NONE || self.home[x] != NONE {
                continue;
            }
            if self.local_of[x] != NONE {
                need[x] = x as u32 >= e0 && x as u32 < e1;
                if need[x] {
                    self.lref[self.local_of[x] as usize] = 1;
                }
                continue;
            }
            if x < ni as usize {
                // A memory result needs its home even unused: the instruction writes it.
                let t = b.insts[x];
                need[x] = t.ty != T_NONE && !self.remat[x] && !self.lv.pfold[x] && (self.lv.uses[x] != 0 || self.mem_x(
                    x as u32,
                ));
            } else {
                need[x] = self.lv.uses[x] != 0 || x < (ni + b.params.len() as u32) as usize;
            }
        }
        // A value whose range is one position is freed at its last use (`one`) when it is an instruction's
        // result or an entry parameter in its wasm parameter that no edge writes; the others when the
        // position past their range starts.
        let mut one = Vector::<bool>::new();
        one.resize_default(n);
        for x in 0..n {
            let ep = x as u32 >= e0 && x as u32 < e1 && self.local_of[x] != NONE && self.lv.uses[x] != 0 && self.lv.reads(
                x as u32,
            ) == self.lv.uses[x];
            one[x] = need[x] && start[x] == end[x] && (x < ni as usize || ep);
        }
        let mut by_start = Vector::<u32>::new();
        let mut by_end = Vector::<u32>::new();
        let mut s_at = Vector::<u32>::new();
        fill(&mut s_at, npos + 1, 0);
        let mut e_at = Vector::<u32>::new();
        fill(&mut e_at, npos + 2, 0);
        for x in 0..n {
            if need[x] && !one[x] {
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
        fill(&mut by_start, s_at[npos] as usize, 0);
        fill(&mut by_end, e_at[npos + 1] as usize, 0);
        let mut sf = Vector::<u32>::with_capacity(npos + 1);
        sf.extend_copy(&s_at);
        let mut ef = Vector::<u32>::with_capacity(npos + 2);
        ef.extend_copy(&e_at);
        for x in 0..n {
            if need[x] && !one[x] {
                by_start[sf[start[x] as usize] as usize] = x as u32;
                sf[start[x] as usize] += 1;
                // Freed when position end + 1 starts.
                by_end[ef[end[x] as usize + 1] as usize] = x as u32;
                ef[end[x] as usize + 1] += 1;
            }
        }
        let mut left = Vector::<u32>::new(); // per value, its uses left in its own block
        fill(&mut left, n, 0);
        for q in 0..npos {
            for j in e_at[q]..e_at[q + 1] {
                self.release(by_end[j as usize]);
            }
            for j in s_at[q]..s_at[q + 1] {
                let x = by_start[j as usize];
                if self.local_of[x as usize] == NONE {
                    self.take(x);
                }
            }
            let k = self.lv.order[q];
            let blk = b.blocks[k as usize];
            for i in blk.start..blk.start + blk.len {
                // A memory result takes its home before its operands free theirs: a lowering may write
                // the result's lanes before it reads every operand lane (a gather's fallback lanes).
                let own = one[i as usize];
                let early = own && self.mem_x(i);
                if early {
                    self.take(i);
                }
                self.uses.truncate(0);
                self.uses.extend_from_slice(self.lv.uses_of(i));
                for u in 0..self.uses.len() {
                    let x = self.vx(self.uses[u]);
                    if x == NONE || !one[x as usize] {
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
            }
        }
    }

    // A local or home for value `x`.
    fn take(self: &mut Self, x: u32) {
        let t = self.xty(x);
        if self.mem_x(x) {
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
        let wt = self.wty(x);
        let k = class_of(wt) as usize;
        let mut l = self.arg_local(x, k);
        if l == NONE {
            l = (if let Some(f) = self.free.index_mut(k).pop() {
                f
            } else {
                self.lref.push(0);
                self.new_local(wt)
            });
        }
        self.lref[l as usize] += 1;
        self.local_of[x as usize] = l;
    }

    // For block parameter `x` (class `k`), the local of an argument an edge into its block passes it, so
    // that edge moves nothing: a free one (off the free list), or the argument's own when no code the
    // block reaches reads the argument (`dead_from`), which both then hold. NONE when there is none.
    fn arg_local(self: &mut Self, x: u32, k: usize) u32 {
        let b = self.b();
        let ni = b.insts.len() as u32;
        if x < ni || x >= ni + b.params.len() as u32 {
            return NONE;
        }
        let tb = self.lv.def_blk[x as usize];
        let q = x - ni - b.blocks[tb as usize].param_start;
        for p in self.lv.pat[tb as usize]..self.lv.pat[tb as usize + 1] {
            let pb = b.blocks[self.lv.preds[p as usize] as usize];
            b.succ_edges(b.insts[(pb.start + pb.len - 1) as usize], &mut self.succ);
            for e in 0..self.succ.len() {
                if b.edge_target(self.succ[e]) != tb {
                    continue;
                }
                let ax = self.vx(b.edge_arg(self.succ[e], q));
                if ax == NONE || self.local_of[ax as usize] == NONE {
                    continue;
                }
                let l = self.local_of[ax as usize];
                if !self.gone[ax as usize] {
                    // Only while the argument alone holds it: a parameter that took it already (an edge
                    // passing one value to two parameters) lives on beside this one.
                    if self.lref[l as usize] == 1 && self.dead_from(tb, ax) {
                        return l;
                    }
                    continue;
                }
                if self.lref[l as usize] != 0 {
                    continue;
                }
                let fr = self.free.index_mut(k);
                for f in 0..fr.len() {
                    if fr[f] == l {
                        let _ = fr.swap_remove(f);
                        return l;
                    }
                }
            }
        }
        return NONE;
    }

    // Whether no code block `k` reaches (`k` too) reads value index `ax`. False past the body's walk
    // budget.
    fn dead_from(self: &mut Self, k: u32, ax: u32) bool {
        let b = self.b();
        self.walk += 1;
        self.wstack.truncate(0);
        self.wstack.push(k);
        self.seen[k as usize] = self.walk;
        // Each step reads one block, which the walk marks once; the budget bounds the instructions.
        while let Some(y) = self.wstack.pop() {
            let blk = b.blocks[y as usize];
            if blk.len > self.budget {
                self.budget = 0;
                return false;
            }
            self.budget -= blk.len;
            for i in blk.start..blk.start + blk.len {
                let us = self.lv.uses_of(i);
                for u in 0..us.len() {
                    if self.vx(us[u]) == ax {
                        return false;
                    }
                }
            }
            b.succ_edges(b.insts[(blk.start + blk.len - 1) as usize], &mut self.wsucc);
            for e in 0..self.wsucc.len() {
                let z = b.edge_target(self.wsucc[e]);
                if self.seen[z as usize] != self.walk {
                    self.seen[z as usize] = self.walk;
                    self.wstack.push(z);
                }
            }
        }
        return true;
    }

    // Value `x`'s local or home is free.
    fn release(self: &mut Self, x: u32) {
        if self.home[x as usize] != NONE {
            let sz = type_bytes(self.xty(x), 4) + 15 & ~15u32;
            self.free_home.push(sz as u64 << 32 | self.home[x as usize] as u64);
            return;
        }
        let l = self.local_of[x as usize];
        if l == NONE {
            return;
        }
        self.gone[x as usize] = true;
        self.lref[l as usize] -= 1;
        if self.lref[l as usize] == 0 {
            self.free.index_mut(class_of(self.wty(x)) as usize).push(l);
        }
    }

    // Whether value index `x` lives in frame memory: an i128, or a vector not in a v128 local.
    const fn mem_x(self: &Self, x: u32) bool {
        return in_mem(self.xty(x)) && !self.vreg[x as usize];
    }

    // Whether value `v` lives in frame memory (`mem_x`).
    const fn mem_v(self: &Self, v: Value) bool {
        let x = self.vx(v);
        return in_mem(self.vt(v)) && (x == NONE || !self.vreg[x as usize]);
    }

    // The wasm type of value index `x`'s local.
    const fn wty(self: &Self, x: u32) u8 {
        if self.vreg[x as usize] {
            return w::V128;
        }
        return wa::wtype(self.xty(x));
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
            } else if pa.kind == wa::P_V128 && self.vreg[x as usize] {
                self.local_of[x as usize] = wp;
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
        self.cold_entry.truncate(0);
        if needs_frame && self.lazy_frame() {
            // The failure paths alone use the frame: each entry into them sets it up (`cold_entry`), and no
            // return restores it.
            self.fp = self.new_local(w::I32);
        } else if needs_frame {
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
            1u32
        } else {
            0u32
        };
        for k in 0..np {
            let pa = self.me.params[k as usize];
            let x = ni + e0 + k;
            let pt = b.pool[(b.sig + 3 + k) as usize];
            let used = self.lv.uses[x as usize] != 0;
            if pa.kind == wa::P_DIRECT && !pa.leaf {
                // A narrow signed integer: zero-extended, as every value of its type (the caller extends an
                // unsigned one so already, as the C convention has it).
                let m = narrow_mask(pa.ty);
                if m != 0 && used && pa.sext {
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

    // `fails`: the rare blocks that end in a panic or a trap, then those whose successors all fail, in rounds
    // (at most one per block).
    fn failing(self: &mut Self) {
        let b = self.b();
        let n = b.blocks.len();
        fill(&mut self.fails, n, false);
        for k in 0..n {
            let bk = b.blocks[k];
            let op = b.insts[(bk.start + bk.len - 1) as usize].op;
            self.fails[k] = (bk.flags & BLOCK_RARE) != 0 && (op == O_PANIC || op == O_UNREACHABLE);
        }
        let mut changed = true;
        let mut round: usize = 0;
        while changed && round < n {
            changed = false;
            round += 1;
            for k in 0..n {
                let bk = b.blocks[k];
                if self.fails[k] || (bk.flags & BLOCK_RARE) == 0 {
                    continue;
                }
                b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.succ);
                let mut all = self.succ.len() != 0;
                for e in 0..self.succ.len() {
                    all = all && self.fails[b.edge_target(self.succ[e]) as usize];
                }
                if all {
                    self.fails[k] = true;
                    changed = true;
                }
            }
        }
    }

    // Whether only the failure paths (`fails`, which do not return nor lead back) use the frame: no
    // canary, over-aligned frame, entry spill, result slot or variadic buffer, no parameter home, and every
    // home, read of a slot's address and call area need in a failure path's block. Sets `cold_entry` when so.
    fn lazy_frame(self: &mut Self) bool {
        let b = self.b();
        if self.canary != NONE || self.falign > 16 || self.res_slot != NONE || self.warm_area != 0 || self.me.variadic || self.fails[0] {
            return false;
        }
        for k in 0..self.pspill.len() {
            if self.pspill[k] != NONE {
                return false;
            }
        }
        let ni = b.insts.len();
        for x in ni..self.home.len() {
            if self.home[x] != NONE {
                return false;
            }
        }
        let mut entry = Vector::<bool>::with_capacity(b.blocks.len());
        entry.resize_default(b.blocks.len());
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            let cold = self.fails[k];
            let tm = b.insts[(bk.start + bk.len - 1) as usize];
            if cold && tm.op == O_RET {
                return false;
            }
            for i in bk.start..bk.start + bk.len {
                if cold {
                    continue;
                }
                if self.home[i as usize] != NONE {
                    return false;
                }
                // A slot's address is made where it is read (`remat`): no read of one here.
                let us = self.lv.uses_of(i);
                for q in 0..us.len() {
                    let u = us[q];
                    if (u & (VPARAM | VFLAG)) == 0 && b.insts[u as usize].op == O_SLOTADDR {
                        return false;
                    }
                }
            }
            b.succ_edges(tm, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                let sc = self.fails[s as usize];
                if cold && !sc {
                    return false;
                }
                entry[s as usize] = entry[s as usize] || sc && !cold;
            }
        }
        self.cold_entry = entry;
        return true;
    }

    // The frame of a failure path (`lazy_frame`): the stack pointer less the frame, the frame base.
    fn open_frame(self: &mut Self) {
        self.sp_access(false);
        self.c.i32_const(self.frame as i32);
        self.c.op(w::I32_SUB);
        self.c.local(w::LOCAL_TEE, self.fp);
        self.sp_access(true);
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
        if self.fp == NONE || self.cold_entry.len() != 0 {
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
            wo::F_HIDDEN
        } else {
            wo::F_LOCAL
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
                0u32
            } else {
                (self.rows[q] >> 32) as u32
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
        // A comparison only conditions read (`lv::FOLD_CMP`); a zero extension or a truncation the locals
        // hold so already (`lv::FOLD_FREE_ZEXT`).
        if (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize] {
            let t = self.b().insts[v as usize];
            if t.op == O_ICMP {
                self.cmp_push(t, t.aux, true);
            } else {
                self.get(t.a);
            }
            return;
        }
        let x = self.vx(v);
        let l = if x == NONE {
            NONE
        } else {
            self.local_of[x as usize]
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
    // from its body when the package defines it, else from the signature the lowering recorded
    // (`Sym.sig`), else from a call of it anywhere in the package.
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
        } else if y.sig != NONE {
            let db = &p.decls[y.sig as usize];
            wa::classify(db, db.sig, self.vregs, &mut sg);
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
        self.value_write(self.vx(i));
    }

    // The last local access, a `local.set` of value index `x`: marked for `stack_values` (VW_VALUE, and
    // VW_ONE when one instruction or edge reads it, which no loop keeps).
    fn value_write(self: &mut Self, x: u32) {
        let n = self.c.acc_op.len();
        self.c.acc_op[n - 1] = w::LOCAL_SET | VW_VALUE | pick8(self.lv.reads(x) == 1, VW_ONE, 0);
    }

    // The frame offset of memory value `v`.
    fn mhome(self: &mut Self, v: Value) u32 {
        let x = self.vx(v);
        let h = if x == NONE {
            NONE
        } else {
            self.home[x as usize]
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
            (w::I32_LOAD8_U, 0u32)
        } else if t == T_I16 {
            (w::I32_LOAD16_U, 1u32)
        } else if t == T_I64 {
            (w::I64_LOAD, 3u32)
        } else if t == T_F32 {
            (w::F32_LOAD, 2u32)
        } else if t == T_F64 {
            (w::F64_LOAD, 3u32)
        } else {
            (w::I32_LOAD, 2u32)
        };
        self.c.op(op);
        self.c.memarg(
            if al < nat {
                al
            } else {
                nat
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
            (w::I32_STORE8, 0u32)
        } else if t == T_I16 {
            (w::I32_STORE16, 1u32)
        } else if t == T_I64 {
            (w::I64_STORE, 3u32)
        } else if t == T_F32 {
            (w::F32_STORE, 2u32)
        } else if t == T_F64 {
            (w::F64_STORE, 3u32)
        } else {
            (w::I32_STORE, 2u32)
        };
        self.c.op(op);
        self.c.memarg(
            if al < nat {
                al
            } else {
                nat
            },
            off,
        );
    }

    // Copy `n` bytes from `sl + soff` to `dl + doff` (both locals holding addresses).
    fn copy_mem(self: &mut Self, dl: u32, doff: u32, sl: u32, soff: u32, n: u32) {
        let mut k: u32 = 0;
        while self.simd && k + 16 <= n {
            self.c.local(w::LOCAL_GET, dl);
            self.c.local(w::LOCAL_GET, sl);
            self.sop(w::V128_LOAD);
            self.c.memarg(0, soff + k);
            self.sop(w::V128_STORE);
            self.c.memarg(0, doff + k);
            k += 16;
        }
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
        if self.remat[i as usize] || self.lv.pfold[i as usize] {
            return true;
        }
        if op == O_WCONST {
            if self.local_of[i as usize] == NONE && self.home[i as usize] == NONE {
                return true;
            }
            if self.simd && (t.b == 2 || vfit(t.ty)) {
                self.vpre(i);
                self.vconst(b.words[t.a as usize], pick64(t.b == 2, b.words[t.a as usize + t.b as usize - 1], 0));
                self.vpost(i);
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
        if op == O_VEXTRACT && !self.mem_v(t.a) {
            self.vget(t.a);
            self.lane_op(VL_EXTRACT, t.ty);
            self.c.op(t.aux as u8);
            self.put(i);
            return true;
        }
        if op == O_VEXTRACT {
            // The lane's load from the vector's home; an integer narrowed to its i32 local.
            self.ld_lane(t.a, t.aux, t.ty, false, false);
            if !is_float(t.ty) && wa::wtype(t.ty) == w::I32 {
                self.c.op(w::I32_WRAP_I64);
            }
            self.put(i);
            return true;
        }
        if is_vec(t.ty) && op != O_LOAD && op != O_SELECT && op != O_CALL && op != O_CALLIND && op != O_VAARG && op != O_BITCAST || op == O_VOP {
            return self.vector(i, t);
        }
        if op == O_HTOF || op == O_FTOH {
            // wasm32 converts no binary16 value (`Package.half` is HALF_NONE there).
            return self.refuse("a binary16 conversion");
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
        if op == O_MULHU || op == O_MULHS {
            return self.mulhu(i, t);
        }
        if op == O_FMA {
            // wasm has no scalar fused multiply-add: the C library's, which rounds once.
            self.get(t.a);
            self.get(t.b);
            self.get(t.c);
            if t.ty == T_F64 {
                self.call_rt("fma", [w::F64, w::F64, w::F64], [w::F64]);
            } else {
                self.call_rt("fmaf", [w::F32, w::F32, w::F32], [w::F32]);
            }
            self.put(i);
            return true;
        }
        if op >= O_FADD && op <= O_FNEG || op == O_FSQRT {
            let d = t.ty == T_F64;
            if op == O_FNEG {
                self.get(t.a);
                self.c.op(
                    if d {
                        w::F64_NEG
                    } else {
                        w::F32_NEG
                    },
                );
            } else if op == O_FSQRT {
                self.get(t.a);
                self.c.op(pick8(d, w::F64_SQRT, w::F32_SQRT));
            } else {
                self.get(t.a);
                self.get(t.b);
                let base = if d {
                    w::F64_ADD
                } else {
                    w::F32_ADD
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
                if scale_of(t) != 1 {
                    self.c.i32_const(scale_of(t) as i32);
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
        if op == O_SYS {
            // wasm has no spin instruction; the barriers emit nothing. Its other operations are other
            // processors'.
            if t.aux == SYS_SPIN || t.aux == SYS_BARRIER || t.aux == SYS_KEEP {
                return true;
            }
            return self.refuse("a system operation of another processor");
        }
        if op == O_ASM {
            return self.asm_inst(t);
        }
        if op == O_MEMCPY || op == O_MEMSET {
            // The bulk memory forms (`memory.copy` takes overlapping regions as memmove does), on memory 0.
            self.get(t.a);
            self.get(t.b);
            self.get(t.c);
            if self.vt(t.c) == T_I64 {
                self.c.op(w::I32_WRAP_I64);
            }
            self.c.op(0xFC);
            if op == O_MEMSET {
                self.c.uleb(0xB);
                self.c.uleb(0);
            } else {
                self.c.uleb(0xA);
                self.c.uleb(0);
                self.c.uleb(0);
            }
            self.obj().bulk = true;
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
                    w::I64_SUB
                } else {
                    w::I32_SUB
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
                    o32 + (w::I64_ADD - w::I32_ADD)
                } else {
                    o32
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

    // The high half of a product (`O_MULHU`, `O_MULHS`): up to 32 bits, the extended operands' 64-bit
    // product shifted down; 64 bits, `mulh64` of the operands.
    fn mulhu(self: &mut Self, i: u32, t: Inst) bool {
        let sgn = t.op == O_MULHS;
        if t.ty != T_I64 {
            let bits = type_bits(t.ty, 4);
            let ext = if sgn {
                w::I64_EXTEND_I32_S
            } else {
                w::I64_EXTEND_I32_U
            };
            self.get_ext(t.a, sgn);
            self.c.op(ext);
            self.get_ext(t.b, sgn);
            self.c.op(ext);
            self.c.op(w::I64_MUL);
            self.c.i64_const(bits);
            self.c.op(
                if sgn {
                    w::I64_SHR_S
                } else {
                    w::I64_SHR_U
                },
            );
            self.c.op(w::I32_WRAP_I64);
            // A signed narrow result back to its bits zero-extended, as every value of its type.
            if sgn {
                self.canon(t.ty);
            }
            self.put(i);
            return true;
        }
        let x = self.tmp(w::I64);
        let y = self.tmp(w::I64);
        self.get(t.a);
        self.c.local(w::LOCAL_SET, x);
        self.get(t.b);
        self.c.local(w::LOCAL_SET, y);
        self.mulh64(sgn, x, y);
        self.put(i);
        return true;
    }

    // Push the high 64 bits of the product of i64 locals `x` and `y` (signed `sgn`), from the four products
    // of their 32-bit halves (wasm has no wider multiply): high = ah * bh + (ah * bl >> 32) + (cross >> 32),
    // cross = (al * bl >> 32) + (ah * bl & m) + al * bh, less for a signed one each operand where the other
    // is negative.
    fn mulh64(self: &mut Self, sgn: bool, x: u32, y: u32) {
        let al = self.tmp(w::I64);
        let ah = self.tmp(w::I64);
        let bl = self.tmp(w::I64);
        let bh = self.tmp(w::I64);
        let hl = self.tmp(w::I64);
        self.halves(x, al, ah);
        self.halves(y, bl, bh);
        // hl = ah * bl
        self.c.local(w::LOCAL_GET, ah);
        self.c.local(w::LOCAL_GET, bl);
        self.c.op(w::I64_MUL);
        self.c.local(w::LOCAL_SET, hl);
        // ah * bh + (hl >> 32)
        self.c.local(w::LOCAL_GET, ah);
        self.c.local(w::LOCAL_GET, bh);
        self.c.op(w::I64_MUL);
        self.c.local(w::LOCAL_GET, hl);
        self.c.i64_const(32);
        self.c.op(w::I64_SHR_U);
        self.c.op(w::I64_ADD);
        // cross = (al * bl >> 32) + (hl & m) + al * bh, then its high half
        self.c.local(w::LOCAL_GET, al);
        self.c.local(w::LOCAL_GET, bl);
        self.c.op(w::I64_MUL);
        self.c.i64_const(32);
        self.c.op(w::I64_SHR_U);
        self.c.local(w::LOCAL_GET, hl);
        self.c.i64_const(0xFFFFFFFF);
        self.c.op(w::I64_AND);
        self.c.op(w::I64_ADD);
        self.c.local(w::LOCAL_GET, al);
        self.c.local(w::LOCAL_GET, bh);
        self.c.op(w::I64_MUL);
        self.c.op(w::I64_ADD);
        self.c.i64_const(32);
        self.c.op(w::I64_SHR_U);
        self.c.op(w::I64_ADD);
        if sgn {
            for k in 0..2u32 {
                let (p, q) = if k == 0 {
                    (x, y)
                } else {
                    (y, x)
                };
                self.c.local(w::LOCAL_GET, p);
                self.c.i64_const(63);
                self.c.op(w::I64_SHR_S);
                self.c.local(w::LOCAL_GET, q);
                self.c.op(w::I64_AND);
                self.c.op(w::I64_SUB);
            }
        }
    }

    // The high halves of the products of each pair of lanes of vectors `t.a` and `t.b` (`O_MULHU`,
    // `O_MULHS`): lanes below 8 bytes as the extended lanes' product shifted down, 8-byte ones by `mulh64`.
    fn vec_mulh(self: &mut Self, i: u32, t: Inst) {
        let sgn = t.op == O_MULHS;
        let lt = lane_type(t.ty);
        let lb = type_bits(lt, 4);
        let d = self.vdef(i);
        let x = self.tmp(w::I64);
        let y = self.tmp(w::I64);
        for k in 0..lanes(t.ty) {
            self.ld_lane_to(x, t.a, k, lt, sgn, false);
            self.ld_lane_to(y, t.b, k, lt, sgn, false);
            if lb == 64 {
                self.mulh64(sgn, x, y);
            } else {
                self.c.local(w::LOCAL_GET, x);
                self.c.local(w::LOCAL_GET, y);
                self.c.op(w::I64_MUL);
                self.c.i64_const(lb);
                self.c.op(
                    if sgn {
                        w::I64_SHR_S
                    } else {
                        w::I64_SHR_U
                    },
                );
            }
            self.c.local(w::LOCAL_SET, x);
            self.st_lane(x, d, k, lt, false);
        }
    }

    // The 32-bit halves of i64 local `v` into locals `lo` and `hi`.
    fn halves(self: &mut Self, v: u32, lo: u32, hi: u32) {
        self.c.local(w::LOCAL_GET, v);
        self.c.local(w::LOCAL_TEE, lo);
        self.c.i64_const(32);
        self.c.op(w::I64_SHR_U);
        self.c.local(w::LOCAL_SET, hi);
        self.c.local(w::LOCAL_GET, lo);
        self.c.i64_const(0xFFFFFFFF);
        self.c.op(w::I64_AND);
        self.c.local(w::LOCAL_SET, lo);
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
            NONE
        } else {
            self.local_of[fx as usize]
        };
        if ty == T_I64 && op == O_MULO {
            return self.mulo64(i, t, signed, fl);
        }
        let wide = ty == T_I64;
        let bits = type_bits(ty, 4);
        // An i32 product is exact in 64 bits.
        let big = op == O_MULO && bits == 32;
        let wt = if wide || big {
            w::I64
        } else {
            w::I32
        };
        let ra = self.tmp(wt);
        let rb = self.tmp(wt);
        let r = self.tmp(wt);
        if bits < 32 || big {
            // In 32 bits (a narrow type) or 64 (an i32 product): exact, then compared with its truncation.
            for q in 0..2 {
                let v = if q == 0 {
                    t.a
                } else {
                    t.b
                };
                self.get_ext(v, signed);
                if big {
                    self.c.op(
                        if signed {
                            w::I64_EXTEND_I32_S
                        } else {
                            w::I64_EXTEND_I32_U
                        },
                    );
                }
                self.c.local(
                    w::LOCAL_SET,
                    if q == 0 {
                        ra
                    } else {
                        rb
                    },
                );
            }
            let x = r;
            let big_r = big;
            self.c.local(w::LOCAL_GET, ra);
            self.c.local(w::LOCAL_GET, rb);
            let o = if op == O_ADDO {
                w::I32_ADD
            } else if op == O_SUBO {
                w::I32_SUB
            } else {
                w::I32_MUL
            };
            self.c.op(
                if big_r {
                    o + (w::I64_ADD - w::I32_ADD)
                } else {
                    o
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
                            w::I64_EXTEND_I32_S
                        } else {
                            w::I64_EXTEND_I32_U
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
            w::I32_ADD
        } else {
            w::I32_SUB
        };
        let d = if wide {
            w::I64_ADD - w::I32_ADD
        } else {
            0u8
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
                        r
                    } else {
                        rb
                    },
                );
                self.c.op(w::I32_XOR + d);
                self.c.local(
                    w::LOCAL_GET,
                    if add {
                        rb
                    } else {
                        ra
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
                        w::I64_LT_U
                    } else {
                        w::I32_LT_U
                    },
                );
            } else {
                self.c.local(w::LOCAL_GET, ra);
                self.c.local(w::LOCAL_GET, rb);
                self.c.op(
                    if wide {
                        w::I64_LT_U
                    } else {
                        w::I32_LT_U
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
        self.cmp_push(t, c, false);
        self.put(i);
        return true;
    }

    // Push scalar integer comparison `t` under condition `c` (its own or the inverse). With `truth`, for a
    // reader that tests for nonzero only (a select's or a branch's condition), a 32-bit value's
    // inequality with 0 is the value.
    fn cmp_push(self: &mut Self, t: Inst, c: u16, truth: bool) {
        let ty = self.vt(t.a);
        // An equality with 0: `eqz`.
        let mut z: u64 = 1;
        let x = if (c == C_EQ || c == C_NE) && self.const_of(t.b, &mut z) && z == 0 {
            t.a
        } else if (c == C_EQ || c == C_NE) && self.const_of(t.a, &mut z) && z == 0 {
            t.b
        } else {
            VNONE
        };
        if x != VNONE && (c == C_EQ || truth && ty != T_I64) {
            self.get(x);
            if c == C_EQ {
                self.c.op(pick8(ty == T_I64, w::I64_EQZ, w::I32_EQZ));
            }
            return;
        }
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
        let signed = c >= C_SLT && c <= C_SGE;
        self.get_ext(t.a, signed);
        self.get_ext(t.b, signed);
        let o = ops[c as usize];
        self.c.op(
            if ty == T_I64 {
                o + (w::I64_EQ - w::I32_EQ)
            } else {
                o
            },
        );
    }

    // Push branch or select condition `v`, negated when `neg`.
    fn get_cond(self: &mut Self, v: Value, neg: bool) {
        if (v & (VPARAM | VFLAG)) == 0 && self.lv.pfold[v as usize] && self.b().insts[v as usize].op == O_ICMP {
            let t = self.b().insts[v as usize];
            self.cmp_push(
                t,
                if neg {
                    opposite(t.aux)
                } else {
                    t.aux
                },
                true,
            );
            return;
        }
        self.get(v);
        if neg {
            self.c.op(w::I32_EQZ);
        }
    }

    fn fcmp(self: &mut Self, i: u32, t: Inst) bool {
        let d = if self.vt(t.a) == T_F64 {
            w::F64_EQ - w::F32_EQ
        } else {
            0u8
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
                w::F32_EQ
            } else if c == C_UNE {
                w::F32_NE
            } else if c == C_OLT {
                w::F32_LT
            } else if c == C_OLE {
                w::F32_LE
            } else if c == C_OGT {
                w::F32_GT
            } else {
                w::F32_GE
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
                        w::I64_EXTEND_I32_S
                    } else {
                        w::I64_EXTEND_I32_U
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
                    w::F64_PROMOTE_F32
                } else {
                    w::F32_DEMOTE_F64
                },
            );
            self.put(i);
            return true;
        }
        if op == O_SITOFP || op == O_UITOFP {
            let s = op == O_SITOFP;
            self.get_ext(t.a, s);
            let base = if to == T_F32 {
                w::F32_CONVERT_I32_S
            } else {
                w::F64_CONVERT_I32_S
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
            pick8(fd, w::I64_TRUNC_F64_S, w::I64_TRUNC_F32_S) + pick8(signed, 0, 1)
        } else {
            pick8(fd, w::I32_TRUNC_F64_S, w::I32_TRUNC_F32_S) + pick8(signed || tb < 32, 0, 1)
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
            -fpow2(tb - 1)
        } else {
            0.0
        };
        let hi: f64 = if signed {
            fpow2(tb - 1)
        } else {
            fpow2(tb)
        };
        let mn: u64 = if signed {
            (1u64 << (tb - 1) as u64).wrapping_neg()
        } else {
            0
        };
        let mx: u64 = if signed {
            (1u64 << (tb - 1) as u64) - 1
        } else {
            trunc_to(~0u64, tb)
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
        self.c.f64_const(fl::f64_bits(lo - 1.0));
        self.c.op(w::F64_LE);
        self.c.op(w::IF);
        self.c.op(rt);
        self.int_const(wide, trunc_to(mn, tb));
        self.c.op(w::ELSE);
        self.c.local(w::LOCAL_GET, x);
        if !fd {
            self.c.op(w::F64_PROMOTE_F32);
        }
        self.c.f64_const(fl::f64_bits(hi));
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
        if self.simd && self.cast_fits(t) {
            // A scalar is lane 0 of the vector; an i128 is in memory.
            let vin = is_vec(from) || from == T_I128;
            let sc = pick8(vin, to, from);
            let lt = pick8(is_float(sc), sc, pick8(type_bytes(sc, 4) == 8, T_I64, T_I32));
            self.vpre(i);
            if vin {
                self.vget(t.a);
            } else {
                self.get(t.a);
                self.lane_op(VL_SPLAT, lt);
            }
            if is_vec(to) || to == T_I128 {
                self.vpost(i);
            } else {
                self.lane_op(VL_EXTRACT, lt);
                self.c.op(0);
                self.put(i);
            }
            return true;
        }
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
                        w::I64_EXTEND_I32_S
                    } else {
                        w::I64_EXTEND_I32_U
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
                "__floattidf"
            } else if op == O_SITOFP {
                "__floattisf"
            } else if d {
                "__floatuntidf"
            } else {
                "__floatuntisf"
            };
            self.mword(t.a, 0);
            self.mword(t.a, 1);
            let rt = if d {
                w::F64
            } else {
                w::F32
            };
            self.call_rt(name, [w::I64, w::I64], [rt]);
            self.put(i);
            return true;
        }
        let name = if op == O_FPTOSI && fd {
            "__fixdfti"
        } else if op == O_FPTOSI {
            "__fixsfti"
        } else if fd {
            "__fixunsdfti"
        } else {
            "__fixunssfti"
        };
        let h = self.home[i as usize];
        self.c.local(w::LOCAL_GET, self.fp);
        if h != NONE && h != 0 {
            self.c.i32_const(h as i32);
            self.c.op(w::I32_ADD);
        }
        self.get(t.a);
        let ft = if fd {
            w::F64
        } else {
            w::F32
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
                "__multi3"
            } else if op == O_SDIV {
                "__divti3"
            } else if op == O_UDIV {
                "__udivti3"
            } else if op == O_SREM {
                "__modti3"
            } else {
                "__umodti3"
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
                    w::I64_ADD
                } else {
                    w::I64_SUB
                },
            );
            self.c.local(w::LOCAL_SET, rl);
            self.c.local(w::LOCAL_GET, ah);
            self.c.local(w::LOCAL_GET, bh);
            self.c.op(
                if add {
                    w::I64_ADD
                } else {
                    w::I64_SUB
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
                    w::I64_ADD
                } else {
                    w::I64_SUB
                },
            );
            self.c.local(w::LOCAL_SET, rh);
        } else if op == O_AND || op == O_OR || op == O_XOR {
            let o = if op == O_AND {
                w::I64_AND
            } else if op == O_OR {
                w::I64_OR
            } else {
                w::I64_XOR
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
            w::I64_SHR_S
        } else {
            w::I64_SHR_U
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
            (t.aux & 15) as u32
        } else {
            15u32
        };
        if self.vreg[i as usize] {
            // `v128.load`, `v128.load64_zero` or `v128.load32_zero`.
            let n = type_bytes(t.ty, 4);
            self.get(t.a);
            if off < 0 {
                self.c.i32_const(off);
                self.c.op(w::I32_ADD);
            }
            self.sop(pick32(n == 16, w::V128_LOAD, pick32(n == 8, 0x5D, 0x5C)));
            self.c.memarg(pick32(al < log2u(n), al, log2u(n)), pick32(off < 0, 0, off as u32));
            self.put(i);
            return true;
        }
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
            (t.aux & 15) as u32
        } else {
            15u32
        };
        if self.mem_v(t.b) {
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
        if is_vec(vt) {
            // `v128.store`, or `v128.store64_lane` or `v128.store32_lane` of lane 0.
            let n = type_bytes(vt, 4);
            self.get(t.b);
            self.sop(pick32(n == 16, w::V128_STORE, pick32(n == 8, 0x5B, 0x5A)));
            self.c.memarg(pick32(al < log2u(n), al, log2u(n)), o);
            if n != 16 {
                self.c.op(0);
            }
            return true;
        }
        self.get(t.b);
        self.store_al(vt, o, al);
        return true;
    }

    // O_ARMW and O_ACAS: plain memory operations (no threads).
    fn atomic(self: &mut Self, i: u32, t: Inst) bool {
        let ty = if t.op == O_ACAS {
            self.vt(t.b)
        } else {
            t.ty
        };
        let wide = ty == T_I64;
        let wt = if wide {
            w::I64
        } else {
            w::I32
        };
        let off = if t.op == O_ARMW {
            t.c as i32
        } else {
            0
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
                    w::I64_EQ
                } else {
                    w::I32_EQ
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
                w::I32_ADD
            } else if r == RMW_SUB {
                w::I32_SUB
            } else if r == RMW_AND {
                w::I32_AND
            } else if r == RMW_OR {
                w::I32_OR
            } else {
                w::I32_XOR
            };
            self.c.op(
                if wide {
                    o + (w::I64_ADD - w::I32_ADD)
                } else {
                    o
                },
            );
        }
        self.store_op(ty, 0);
        self.c.local(w::LOCAL_GET, old);
        self.put(i);
        return true;
    }

    fn select_op(self: &mut Self, i: u32, t: Inst) bool {
        if self.simd && vfit(t.ty) {
            self.vpre(i);
            self.vget(t.b);
            self.vget(t.c);
            self.get_cond(t.a, false);
            self.c.op(w::SELECT);
            self.vpost(i);
            return true;
        }
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
        // A constant true side under a comparison that folds in goes second, the comparison inverted: the
        // false side, computed last, may stay on the stack.
        let a = t.a;
        let swap = (a & (VPARAM | VFLAG)) == 0 && self.lv.pfold[a as usize] && self.b().insts[a as usize].op == O_ICMP && self.is_remat(
            t.b,
        ) && !self.is_remat(t.c);
        self.get(pick_v(swap, t.c, t.b));
        self.get(pick_v(swap, t.b, t.c));
        self.get_cond(a, swap);
        self.c.op(w::SELECT);
        self.put(i);
        return true;
    }

    // Whether `v` rematerializes at each use.
    const fn is_remat(self: &Self, v: Value) bool {
        return (v & (VPARAM | VFLAG)) == 0 && self.remat[v as usize];
    }

    fn va_arg(self: &mut Self, i: u32, t: Inst) bool {
        let ty = t.ty;
        let (sz, al) = if ty == T_I128 {
            (16u32, 16u32)
        } else {
            (ast_max(type_bytes(ty, 4), 4), ast_max(type_align(ty, 4), 4))
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
            LB_LOOP
        } else {
            LB_BLOCK
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
        if self.cold_entry.len() != 0 && self.cold_entry[x as usize] {
            self.open_frame();
        }
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
            if self.mem_v(b.edge_arg(e, k)) {
                nmem += 1;
            }
        }
        for k in 0..n {
            let a = b.edge_arg(e, k);
            if !self.mem_v(a) && !self.in_place(a, ni + blk.param_start + k) {
                self.get(a);
            }
        }
        let mut k = n;
        while k > 0 {
            k -= 1;
            let a = b.edge_arg(e, k);
            let x = ni + blk.param_start + k;
            if self.mem_v(a) || self.in_place(a, x) {
                continue;
            }
            let l = self.local_of[x as usize];
            if l == NONE {
                self.c.op(w::DROP);
            } else {
                self.c.local(w::LOCAL_SET, l);
                self.value_write(x);
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
            if !self.mem_v(a) {
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
            if !self.mem_v(a) {
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

    // Whether argument `a` is in parameter `x`'s local already (`arg_local`).
    const fn in_place(self: &Self, a: Value, x: u32) bool {
        let ax = self.vx(a);
        return ax != NONE && self.local_of[x as usize] != NONE && self.local_of[ax as usize] == self.local_of[x as usize];
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
                self.get_cond(t.a, true);
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
                    w::I64_EQ
                } else {
                    w::I32_EQ
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
            return (0, 0);
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
            return (0, 0);
        }
        return (lo, (hi - lo) as u32 + 1);
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
        fill(&mut self.sw_tab, span as usize, n);
        // A later case of an equal value never matches, as in a chain of compares.
        let mut k = n;
        while k > 0 {
            k -= 1;
            self.sw_tab[(trunc_to(b.words[(t.b + k) as usize], bits) - lo) as usize] = k;
        }
        fill(&mut self.sw_blk, n as usize + 1, NONE);
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
                self.sw_tab[q as usize]
            } else {
                n
            };
            let d = if self.sw_blk[c as usize] != NONE {
                self.sw_blk[c as usize]
            } else {
                let tg = b.edge_target(b.switch_edge(t, c));
                self.depth(tg, self.sh.back(x, tg))
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
            self.vget(t.a);
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
        self.ret_end = self.c.len();
        return true;
    }
}

// ---- Calls ----

extend Gen {
    // The instructions of the intrinsic body symbol `s` names (`target::intrin`, `itpl`); empty for another
    // function.
    const fn intrinsic(self: &Self, s: u32) str<'static> {
        return self.itpl[s as usize];
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
            }
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
            fill(&mut tmps, np as usize, NONE);
            for q in 0..args.len() {
                let k = args[q];
                // A vector on the stack is a v128 (`wtype` gives a vector's by-reference form).
                let pa = self.cs.params[k as usize];
                tmps[k as usize] = self.tmp(
                    if pa.kind == wa::P_V128 {
                        w::V128
                    } else {
                        wa::wtype(pa.ty)
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
        return self.asm_text(&body);
    }

    fn call(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let sig = t.b;
        let tpl = if t.op == O_CALL {
            self.intrinsic(t.a)
        } else {
            ""
        };
        // An intrinsic takes its vectors as v128 values.
        wa::classify(
            b,
            sig,
            if tpl.len() != 0 {
                16u32
            } else {
                self.vregs
            },
            &mut self.cs,
        );
        let np = b.pool[sig as usize];
        let rt = b.pool[sig as usize + 2];
        // The call area: copies of memory values passed by reference, then the variadic buffer.
        let mut at: u32 = 0;
        let mut refs = Vector::<u32>::new();
        fill(&mut refs, np as usize, NONE);
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
                        T_I32
                    } else {
                        pa.ty
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
                self.vget(v);
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
        } else if r.kind == wa::P_V128 && !self.mem_x(i) {
            self.put(i);
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
    pub(package) fn data(self: &mut Self, s: u32, local: bool) bool {
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
            String::from_str(p.spell(ps.sect))
        } else if zero && !d.readonly {
            format(".bss.{}", nm)
        } else if d.readonly && d.nrelocs == 0 {
            format(".rodata.{}", nm)
        } else {
            format(".data.{}", nm)
        };
        let mut g = wo::WSeg {
            name: name,
            align_log2: d.align_log2,
            bytes: Vector::<u8>::with_capacity(d.size as usize),
            rels: Vector::<wo::WRel>::new(),
            retain: ps.used,
        };
        let bs = p.data_bytes(&d);
        g.bytes.extend_from_slice(bs);
        ob::pad(&mut g.bytes, d.size);
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
        // A copy of data no unit owns: as `ob::copy_flags` makes it.
        let mut fl = if local && (p.split & ob::SPLIT_DATA) != 0 {
            wo::F_WEAK | wo::F_HIDDEN
        } else if ps.linkage == SL_GLOBAL && !local {
            wo::F_HIDDEN
        } else {
            wo::F_LOCAL
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
            pick8(lt == T_F64, w::F64_LOAD, w::F32_LOAD)
        } else if eb == 1 {
            pick8(sg, w::I64_LOAD8_S, w::I64_LOAD8_U)
        } else if eb == 2 {
            pick8(sg, w::I64_LOAD16_S, w::I64_LOAD16_U)
        } else if eb == 4 {
            pick8(sg, w::I64_LOAD32_S, w::I64_LOAD32_U)
        } else {
            w::I64_LOAD
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
            pick8(lt == T_F64, w::F64_STORE, w::F32_STORE)
        } else if eb == 1 {
            w::I64_STORE8
        } else if eb == 2 {
            w::I64_STORE16
        } else if eb == 4 {
            w::I64_STORE32
        } else {
            w::I64_STORE
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
        if self.simd && op != O_VOP && self.vform(t) {
            return self.vinst(i, t);
        }
        if op == O_VOP {
            if self.simd && self.vop_form(t) {
                return self.vop_reg(i, t);
            }
            return self.vop(i, t);
        }
        if op == O_SPLAT {
            // The scalar in a local, stored to each lane.
            let lt = lane_type(t.ty);
            let d = self.vdef(i);
            let l = if is_float(lt) {
                self.get(t.a);
                self.tmp(pick8(lt == T_F64, w::F64, w::F32))
            } else {
                self.get64(t.a);
                self.tmp(w::I64)
            };
            self.c.local(w::LOCAL_SET, l);
            for k in 0..lanes(t.ty) {
                self.st_lane(l, d, k, lt, false);
            }
            return true;
        }
        if op >= O_ADD && op <= O_NOT || op >= O_FADD && op <= O_FNEG || op == O_FSQRT {
            self.vec_arith(i, t);
            return true;
        }
        if op == O_MULHS || op == O_MULHU {
            self.vec_mulh(i, t);
            return true;
        }
        if op == O_VCMP {
            self.vcmp(i, t);
            return true;
        }
        if op == O_VINSERT {
            // The vector's lanes copied, then the scalar as lane `t.aux`.
            let lt = lane_type(t.ty);
            let d = self.vdef(i);
            let x = self.tmp(w::I64);
            for k in 0..lanes(t.ty) {
                self.ld_lane(t.a, k, lt, false, true);
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, lt, true);
            }
            let l = if is_float(lt) {
                self.get(t.b);
                self.tmp(pick8(lt == T_F64, w::F64, w::F32))
            } else {
                self.get64(t.b);
                x
            };
            self.c.local(w::LOCAL_SET, l);
            self.st_lane(l, d, t.aux, lt, false);
            return true;
        }
        if op == O_VZIPLO || op == O_VZIPHI {
            // Lane 2k is lane h + k of `a`, lane 2k + 1 that of `b` (h: 0, or half the lanes).
            let lt = lane_type(t.ty);
            let n = lanes(t.ty);
            let h = if op == O_VZIPHI {
                n / 2
            } else {
                0
            };
            let d = self.vdef(i);
            let x = self.tmp(w::I64);
            for k in 0..n / 2 {
                self.ld_lane(t.a, h + k, lt, false, true);
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, 2 * k, lt, true);
                self.ld_lane(t.b, h + k, lt, false, true);
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, 2 * k + 1, lt, true);
            }
            return true;
        }
        if op == O_VSUMW {
            // Lane k of `a` plus lanes `k * g` to `k * g + g - 1` of `b` zero-extended.
            let lt = lane_type(t.ty);
            let nl = lane_type(self.vt(t.b));
            let n = lanes(t.ty);
            let g = lanes(self.vt(t.b)) / n;
            let d = self.vdef(i);
            let x = self.tmp(w::I64);
            for k in 0..n {
                self.ld_lane(t.a, k, lt, false, false);
                for j in 0..g {
                    self.ld_lane(t.b, k * g + j, nl, false, false);
                    self.c.op(w::I64_ADD);
                }
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, lt, false);
            }
            return true;
        }
        if op == O_VUNZIP {
            // Lane k is lane 2k (2k + 1 for the odd lanes) of `a ++ b`.
            let lt = lane_type(t.ty);
            let n = lanes(t.ty);
            let d = self.vdef(i);
            let x = self.tmp(w::I64);
            for k in 0..n {
                let j = 2 * k + t.aux as u32;
                if j < n {
                    self.ld_lane(t.a, j, lt, false, true);
                } else {
                    self.ld_lane(t.b, j - n, lt, false, true);
                }
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, lt, true);
            }
            return true;
        }
        if op == O_VSEL {
            // Per lane `c ^ ((b ^ c) & mask)` on the lanes' bits.
            let lt = lane_type(t.ty);
            let d = self.vdef(i);
            let x = self.tmp(w::I64);
            for k in 0..lanes(t.ty) {
                self.ld_lane(t.b, k, lt, false, true);
                self.ld_lane(t.c, k, lt, false, true);
                self.c.op(w::I64_XOR);
                self.ld_lane(t.a, k, lt, false, true);
                self.c.op(w::I64_AND);
                self.ld_lane(t.c, k, lt, false, true);
                self.c.op(w::I64_XOR);
                self.c.local(w::LOCAL_SET, x);
                self.st_lane(x, d, k, lt, true);
            }
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

    // Lane-wise comparison `t` into mask `i`, lane by lane: the comparison's 0 or 1 negated to the lane's
    // mask.
    fn vcmp(self: &mut Self, i: u32, t: Inst) {
        let vt = self.vt(t.a);
        let lt = lane_type(vt);
        let ml = lane_type(mask_type(vt));
        let c = t.aux;
        let d = self.vdef(i);
        let x = self.tmp(w::I64);
        let iops: []u8 = [
            w::I64_EQ,
            w::I64_NE,
            w::I64_LT_S,
            w::I64_LE_S,
            w::I64_GT_S,
            w::I64_GE_S,
            w::I64_LT_U,
            w::I64_LE_U,
            w::I64_GT_U,
            w::I64_GE_U,
        ];
        let fd = pick8(lt == T_F64, w::F64_EQ - w::F32_EQ, 0);
        let fo = if c == C_OEQ {
            w::F32_EQ
        } else if c == C_UNE {
            w::F32_NE
        } else if c == C_OLT {
            w::F32_LT
        } else if c == C_OLE {
            w::F32_LE
        } else if c == C_OGT {
            w::F32_GT
        } else {
            w::F32_GE
        };
        let sg = c >= C_SLT && c <= C_SGE;
        for k in 0..lanes(vt) {
            self.c.i64_const(0);
            if is_float(lt) {
                self.ld_lane(t.a, k, lt, false, false);
                self.ld_lane(t.b, k, lt, false, false);
                self.c.op(fo + fd);
            } else {
                self.ld_lane(t.a, k, lt, sg, false);
                self.ld_lane(t.b, k, lt, sg, false);
                self.c.op(iops[c as usize]);
            }
            self.c.op(w::I64_EXTEND_I32_U);
            self.c.op(w::I64_SUB);
            self.c.local(w::LOCAL_SET, x);
            self.st_lane(x, d, k, ml, false);
        }
    }

    // Vector arithmetic: O_ADD .. O_NOT, O_FADD .. O_FNEG and O_FSQRT, lane by lane.
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
                } else if op == O_FSQRT {
                    self.c.op(pick8(lt == T_F64, w::F64_SQRT, w::F32_SQRT));
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
            self.tmp(pick8(fl == T_F64, w::F64, w::F32))
        } else {
            NONE
        };
        let fr = if is_float(tl) {
            self.tmp(pick8(tl == T_F64, w::F64, w::F32))
        } else {
            NONE
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
            t.b
        } else {
            4u32
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
                w::I64_SHL
            } else {
                pick8(sg, w::I64_SHR_S, w::I64_SHR_U)
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
            tys[1]
        } else if rule == core::SR_ANY {
            t.ty
        } else {
            tys[0]
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
            lt
        } else {
            lane_type(t.ty)
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
            self.tmp(w::I64)
        } else {
            NONE
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
            (self.tmp(ft), self.tmp(ft), self.tmp(ft))
        } else {
            (NONE, NONE, NONE)
        };
        for k in 0..n {
            if c == core::SIMD_IOTA {
                if fl {
                    if lt == T_F64 {
                        self.c.f64_const(fl::f64_bits(k as f64));
                    } else {
                        self.c.f32_const(fl::f32_bits(k as f32));
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
                w::I64_ADD
            } else if sub {
                w::I64_SUB
            } else {
                w::I64_MUL
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
                        z
                    } else {
                        y
                    },
                );
                self.c.op(w::I64_XOR);
                self.c.local(
                    w::LOCAL_GET,
                    if add {
                        y
                    } else {
                        x
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
                    w::I64_ADD
                } else if c == core::SIMD_WRAP_SUB {
                    w::I64_SUB
                } else {
                    w::I64_MUL
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
                    w::I64_SHL
                } else {
                    pick8(sg, w::I64_SHR_S, w::I64_SHR_U)
                },
            );
            self.c.local(w::LOCAL_SET, x);
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            let add = c == core::SIMD_SAT_ADD;
            // The limit: a signed overflow goes the way of the operand's sign, an unsigned one up for a sum.
            let max = if sg {
                (1u64 << (lb - 1) as u64) - 1
            } else {
                trunc_to(~0u64, lb)
            };
            let min = if sg {
                (1u64 << (lb - 1) as u64).wrapping_neg()
            } else {
                0u64
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
                (w::I64_SHL, w::I64_SHR_U)
            } else {
                (w::I64_SHR_U, w::I64_SHL)
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
            (1u64 << (rw - 1) as u64) - 1
        } else {
            trunc_to(~0u64, rw)
        };
        let rmin = if rsg {
            (1u64 << (rw - 1) as u64).wrapping_neg()
        } else {
            0u64
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
                w::F32_EQ
            } else if c == core::SIMD_CMP_NE {
                w::F32_NE
            } else if c == core::SIMD_CMP_LT {
                w::F32_LT
            } else if c == core::SIMD_CMP_LE {
                w::F32_LE
            } else if c == core::SIMD_CMP_GT {
                w::F32_GT
            } else {
                w::F32_GE
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
                w::F32_ABS
            } else if c == core::SIMD_SQRT {
                w::F32_SQRT
            } else if c == core::SIMD_CEIL {
                w::F32_CEIL
            } else if c == core::SIMD_FLOOR {
                w::F32_FLOOR
            } else if c == core::SIMD_TRUNC {
                w::F32_TRUNC
            } else if c == core::SIMD_ROUND_EVEN {
                w::F32_NEAREST
            } else {
                w::F32_NEG
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
                nb
            } else {
                na
            },
        );
        self.c.op(w::SELECT);
        self.c.local(
            w::LOCAL_GET,
            if nan {
                na
            } else {
                nb
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
            rs
        } else {
            bs
        };
        let iw = type_bits(ib, 4) - isg as u32;
        let hi = 1023u64 + iw as u64 << 52;
        let lo = if isg {
            hi | 1u64 << 63
        } else {
            0u64
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
            t.ty
        } else if raw {
            tys[1]
        } else {
            tys[2]
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
                    ops[1]
                } else {
                    ops[2]
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
            0
        } else {
            1
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
                self.fconst(dd, pick64(dd, fl::f64_bits(1.0), fl::f32_bits(1.0)));
            }
            self.c.local(w::LOCAL_SET, acc);
        } else {
            self.ld_lane_to(acc, ops[0], 0, lt, false, false);
        }
        let from: u32 = if fold {
            0
        } else {
            1
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
            1u64 << (lb - 1) as u64
        } else {
            trunc_to(~0u64, lb)
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
                pick8(sg, w::I64_LT_S, w::I64_LT_U)
            } else {
                pick8(sg, w::I64_GT_S, w::I64_GT_U)
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
            tys[1]
        } else {
            tys[0]
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
                d
            } else {
                self.mhome(ops[1])
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
            self.b().pool[t.c as usize]
        } else {
            lanes(tys[1])
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

// ---- SIMD128 ----
//
// With simd128 (`simd`) a vector of 4, 8 or 16 bytes (`vfit`) computes in the low bytes of v128 values,
// whatever the bytes past it hold: an instruction with a SIMD128 form (`vform`) reads its vector operands
// from their v128 locals or their homes (`vget`; a home holds 16 bytes) and writes its result to its local
// or home (`vpre`, `vpost`); a conversion to or from a 32-byte vector reads or writes that vector's home.
// The lane loops above compute the other instructions, whose vectors `vec_homes` keeps in memory. The
// semantics are the lane loops': a float to integer conversion saturates (NaN to 0), a shift's count past
// the lane width is undefined.

// Per lane size (1, 2, 4, 8 bytes), the SIMD128 codes of the integer lanes (NOP: none). A shift's arithmetic
// form follows it, then its logical one; an extraction is the unsigned one.
const NOP: u32 = 0xFFFF;
const V_ADD: [u32; 4] = [0x6E, 0x8E, 0xAE, 0xCE];
const V_SUB: [u32; 4] = [0x71, 0x91, 0xB1, 0xD1];
const V_MUL: [u32; 4] = [NOP, 0x95, 0xB5, 0xD5];
const V_NEG: [u32; 4] = [0x61, 0x81, 0xA1, 0xC1];
const V_SHL: [u32; 4] = [0x6B, 0x8B, 0xAB, 0xCB];
const V_SPLAT: [u32; 4] = [0x0F, 0x10, 0x11, 0x12];
const V_EXTRACT: [u32; 4] = [0x16, 0x19, 0x1B, 0x1D];
const V_REPLACE: [u32; 4] = [0x17, 0x1A, 0x1C, 0x1E];
const V_EQ: [u32; 4] = [0x23, 0x2D, 0x37, 0xD6];
// Per narrow lane size (1, 2, 4 bytes): the products of the low lanes in lanes of twice the size, signed
// (+1: the high lanes; +2: unsigned); the low lanes extended to twice their size, signed (+1: the high
// lanes; +2: unsigned).
const V_EXTMUL: [u32; 3] = [0x9C, 0xBC, 0xDC];
const V_EXTEND: [u32; 3] = [0x87, 0xA7, 0xC7];
// Per integer condition (C_EQ .. C_UGE), its comparison's offset from the lanes' `eq`: 1, 2 and 4-byte lanes
// (eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u), 8-byte lanes (eq, ne, lt_s, gt_s, le_s, ge_s).
const V_CMP: [u32; 10] = [0, 1, 2, 6, 4, 8, 3, 7, 5, 9];
const V_CMP64: [u32; 6] = [0, 1, 2, 4, 3, 5];

// The lane operations of `lane_op`.
const VL_SPLAT: u8 = 0;
const VL_EXTRACT: u8 = 1;
const VL_REPLACE: u8 = 2;

// Whether `t` is a vector of 4, 8 or 16 bytes: one a v128 value holds.
const fn vfit(t: u8) bool {
    let n = type_bytes(t, 4);
    return is_vec(t) && (n == 4 || n == 8 || n == 16);
}

// log2 of the bytes of scalar type `t`.
const fn size_log(t: u8) u32 {
    return log2u(type_bytes(t, 4));
}

const fn pick32(c: bool, a: u32, b: u32) u32 {
    if c {
        return a;
    }
    return b;
}

extend Gen {
    // `vreg`: per value index, whether it is a vector in a v128 local (`vfit`): with simd128, one no
    // instruction defines or reads in memory. An instruction with a SIMD128 form (`vform`, `vop_form`), a
    // load, a store, a select, a bitcast of a vector to or from one of its size, a lane's extraction, a
    // call or a return that passes it as a v128, and an edge take either; an edge's argument and its
    // parameter live alike.
    fn vec_homes(self: &mut Self) {
        let b = self.b();
        let n = self.lv.end.len();
        let ni = b.insts.len();
        self.vreg.truncate(0);
        for x in 0..n {
            self.vreg.push(self.simd && vfit(self.xty(x as u32)));
        }
        if !self.simd {
            return;
        }
        let e0 = ni + b.blocks[0].param_start as usize;
        for k in 0..b.pool[b.sig as usize] as usize {
            if self.me.params[k].kind != wa::P_V128 {
                self.vreg[e0 + k] = false;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            let op = t.op;
            if op == O_JMP || op == O_BR || op == O_SWITCH || op == O_LOAD || op == O_STORE || op == O_WCONST || op == O_VEXTRACT {
                continue;
            }
            if op == O_SELECT || op == O_BITCAST {
                if op == O_SELECT && vfit(t.ty) || op == O_BITCAST && self.cast_fits(t) {
                    continue;
                }
            } else if op == O_RET {
                if self.me.ret.kind == wa::P_V128 {
                    continue;
                }
            } else if op == O_CALL || op == O_CALLIND {
                self.call_homes(i as u32, t);
                continue;
            } else if op == O_VOP && self.vop_form(t) || (is_vec(t.ty) || op == O_VCMP) && op != O_VOP && op != O_VAARG && self.vform(
                t,
            ) {
                continue;
            }
            self.vreg[i] = false;
            lv::each_use(b, t, &mut self.uses);
            for k in 0..self.uses.len() {
                let x = self.vx(self.uses[k]);
                if x != NONE {
                    self.vreg[x as usize] = false;
                }
            }
        }
        // Each round unmarks a value or ends: at most n + 1 rounds.
        for _ in 0..n + 1 {
            let mut changed = false;
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.succ);
                for q in 0..self.succ.len() {
                    let e = self.succ[q];
                    let ps = ni as u32 + b.blocks[b.edge_target(e) as usize].param_start;
                    for j in 0..b.edge_nargs(e) {
                        let ax = self.vx(b.edge_arg(e, j));
                        if ax != NONE && self.vreg[ax as usize] != self.vreg[(ps + j) as usize] {
                            self.vreg[ax as usize] = false;
                            self.vreg[(ps + j) as usize] = false;
                            changed = true;
                        }
                    }
                }
            }
            if !changed {
                break;
            }
        }
    }

    // `vec_homes` of call `i`: a vector it passes or returns other than as a fixed v128 lives in memory.
    fn call_homes(self: &mut Self, i: u32, t: Inst) {
        let b = self.b();
        let tpl = if t.op == O_CALL {
            self.intrinsic(t.a)
        } else {
            ""
        };
        wa::classify(
            b,
            t.b,
            if tpl.len() != 0 {
                16u32
            } else {
                self.vregs
            },
            &mut self.cs,
        );
        if self.cs.ret.kind != wa::P_V128 {
            self.vreg[i as usize] = false;
        }
        let np = b.pool[t.b as usize];
        for k in 0..np {
            let x = self.vx(b.pool[(t.c + k) as usize]);
            if x != NONE && (k >= self.cs.nfixed || self.cs.params[k as usize].kind != wa::P_V128) {
                self.vreg[x as usize] = false;
            }
        }
        if t.op == O_CALLIND {
            let x = self.vx(t.a);
            if x != NONE {
                self.vreg[x as usize] = false;
            }
        }
    }

    // A SIMD128 instruction: the prefix and `code`.
    fn sop(self: &mut Self, code: u32) {
        self.c.simd(code);
        self.obj().simd = true;
    }

    // `v128.const` of the words `lo`, `hi`.
    fn vconst(self: &mut Self, lo: u64, hi: u64) {
        self.sop(w::V128_CONST);
        self.c.u64le(lo);
        self.c.u64le(hi);
    }

    // `i8x16.shuffle` of the two v128 values on the stack: result byte j is byte `idx[j]` of their 32 bytes.
    fn shuffle(self: &mut Self, idx: &[u8; 16]) {
        self.sop(w::I8X16_SHUFFLE);
        for j in 0..16usize {
            self.c.op(idx[j]);
        }
    }

    // Push 16-byte value `v` as a v128: its local, or a load of its home.
    fn vget(self: &mut Self, v: Value) {
        if !self.mem_v(v) {
            self.get(v);
            return;
        }
        let h = self.mhome(v);
        self.c.local(w::LOCAL_GET, self.fp);
        self.sop(w::V128_LOAD);
        self.c.memarg(4, h);
    }

    // Push 16-byte value `v` twice.
    fn vget2(self: &mut Self, v: Value) {
        if !self.mem_v(v) {
            self.get(v);
            self.get(v);
            return;
        }
        let x = self.tmp(w::V128);
        self.vget(v);
        self.c.local(w::LOCAL_TEE, x);
        self.c.local(w::LOCAL_GET, x);
    }

    // Before a 16-byte result of instruction `i` on the stack: its home's base, when it has one.
    fn vpre(self: &mut Self, i: u32) {
        if self.mem_x(i) && self.home[i as usize] != NONE {
            self.c.local(w::LOCAL_GET, self.fp);
        }
    }

    // Pop the 16-byte result of instruction `i` into its local or home (`vpre`).
    fn vpost(self: &mut Self, i: u32) {
        if !self.mem_x(i) {
            self.put(i);
        } else if self.home[i as usize] == NONE {
            self.c.op(w::DROP);
        } else {
            self.sop(w::V128_STORE);
            self.c.memarg(4, self.home[i as usize]);
        }
    }

    // The lane operation `kind` (VL_*) on lanes of `lt`; an extraction or a replacement takes its lane next.
    fn lane_op(self: &mut Self, kind: u8, lt: u8) {
        let code = if is_float(lt) {
            let f = pick32(lt == T_F64, 1, 0);
            if kind == VL_SPLAT {
                0x13 + f
            } else {
                0x1F + 2 * f + (kind - VL_EXTRACT) as u32
            }
        } else {
            let k = size_log(lt) as usize;
            if kind == VL_SPLAT {
                V_SPLAT[k]
            } else if kind == VL_EXTRACT {
                V_EXTRACT[k]
            } else {
                V_REPLACE[k]
            }
        };
        self.sop(code);
    }

    // Whether instruction `t` (not an O_VOP) has a SIMD128 form: its 16-byte vector operands and result may
    // live in v128 locals or in memory.
    fn vform(self: &Self, t: Inst) bool {
        let op = t.op;
        if op >= O_SEXT && op <= O_UITOFP {
            return self.conv_form(t);
        }
        if op == O_VCMP {
            return vfit(self.vt(t.a));
        }
        if !vfit(t.ty) {
            return false;
        }
        if op == O_ADD || op == O_SUB || op == O_MUL || op >= O_AND && op <= O_XOR || op == O_NEG || op == O_NOT || op == O_VSUMW {
            return true;
        }
        if op == O_SHL || op == O_LSHR || op == O_ASHR {
            return self.uniform(t.b);
        }
        if op == O_MULHS || op == O_MULHU {
            return lane_type(t.ty) != T_I64;
        }
        return op >= O_FADD && op <= O_FNEG || op == O_FSQRT || op == O_SPLAT || op == O_VSEL || op == O_VINSERT || op == O_VZIPLO || op == O_VZIPHI || op == O_VUNZIP;
    }

    // Whether vector `v` holds one value in every lane: a splat, or a wide constant whose lanes repeat.
    const fn uniform(self: &Self, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let b = self.b();
        let t = b.insts[v as usize];
        if t.op == O_SPLAT {
            return true;
        }
        if t.op != O_WCONST || t.b != 2 || b.words[t.a as usize] != b.words[t.a as usize + 1] {
            return false;
        }
        let lb = type_bits(lane_type(t.ty), 4) as u64;
        let x = b.words[t.a as usize];
        return lb == 64 || (x >> lb | x << 64 - lb) == x;
    }

    // Push the i32 count of a shift by uniform vector `v` (lanes of `lt`): its lane 0.
    fn shift_count(self: &mut Self, v: Value, lt: u8) {
        let t = self.b().insts[v as usize];
        if t.op == O_WCONST {
            self.c.i32_const((self.b().words[t.a as usize] & 0x3F) as i32);
            return;
        }
        self.vget(v);
        self.lane_op(VL_EXTRACT, lt);
        self.c.op(0);
        if lt == T_I64 {
            self.c.op(w::I32_WRAP_I64);
        }
    }

    // Instruction `i` (`vform`) in SIMD128.
    fn vinst(self: &mut Self, i: u32, t: Inst) bool {
        let op = t.op;
        if op >= O_SEXT && op <= O_UITOFP {
            self.vconv(i, t);
            return true;
        }
        let lt = lane_type(t.ty);
        let k = size_log(lt) as usize;
        let mut idx: [u8; 16] = [0; 16];
        self.vpre(i);
        if op == O_VCMP {
            self.vcmp_reg(t);
        } else if op == O_SPLAT {
            self.get(t.a);
            self.lane_op(VL_SPLAT, lt);
        } else if op == O_VINSERT {
            self.vget(t.a);
            self.get(t.b);
            self.lane_op(VL_REPLACE, lt);
            self.c.op(t.aux as u8);
        } else if op == O_VSEL {
            self.vget(t.b);
            self.vget(t.c);
            self.vget(t.a);
            self.sop(0x52);
        } else if op == O_VZIPLO || op == O_VZIPHI || op == O_VUNZIP {
            // Lane j of a zip is lane j / 2 (plus half the lanes for the high halves) of `a` (j even) or `b`;
            // of an unzip lane 2j + aux of `a ++ b`. `b`'s lanes start at byte 16.
            let eb = type_bytes(lt, 4);
            let n = lanes(t.ty);
            let nr = 16 / eb;
            let h = pick32(op == O_VZIPHI, n / 2, 0);
            for j in 0..16u32 {
                let ln = j / eb;
                let s2 = 2 * ln + t.aux as u32;
                let src = if op != O_VUNZIP {
                    (ln & 1) * nr + h + ln / 2
                } else if s2 < n {
                    s2
                } else {
                    pick32(s2 < 2 * n, nr + s2 - n, 0)
                };
                unsafe idx[j as usize] = (src * eb + j % eb) as u8;
            }
            self.vget(t.a);
            self.vget(t.b);
            self.shuffle(&idx);
        } else if op == O_VSUMW {
            self.vget(t.a);
            self.vsum_pairs(t.b, lane_type(self.vt(t.b)), lt);
            self.sop(V_ADD[k]);
        } else if op == O_MULHS || op == O_MULHU {
            // The double-width products of the low and high lanes, then each one's high half.
            let u = pick32(op == O_MULHU, 2, 0);
            let eb = 1u32 << k as u32;
            self.vget(t.a);
            self.vget(t.b);
            self.sop(V_EXTMUL[k] + u);
            self.vget(t.a);
            self.vget(t.b);
            self.sop(V_EXTMUL[k] + u + 1);
            for j in 0..16u32 {
                unsafe idx[j as usize] = (j / eb * 2 * eb + eb + j % eb) as u8;
            }
            self.shuffle(&idx);
        } else if op >= O_FADD && op <= O_FNEG || op == O_FSQRT {
            let f = lt == T_F64;
            let swap = (op == O_FADD || op == O_FMUL) && (t.b & (VPARAM | VFLAG)) == 0 && t.b + 1 == i;
            self.vget(pick_v(swap, t.b, t.a));
            if op == O_FNEG {
                self.sop(pick32(f, 0xED, 0xE1));
            } else if op == O_FSQRT {
                self.sop(pick32(f, 0xEF, 0xE3));
            } else {
                self.vget(pick_v(swap, t.a, t.b));
                self.sop(pick32(f, 0xF0, 0xE4) + (op - O_FADD) as u32);
            }
        } else if op == O_NOT {
            self.vget(t.a);
            self.sop(0x4D);
        } else if op == O_NEG {
            self.vget(t.a);
            self.sop(V_NEG[k]);
        } else if op >= O_SHL && op <= O_ASHR {
            self.vget(t.a);
            self.shift_count(t.b, lt);
            self.sop(V_SHL[k] + pick32(op == O_SHL, 0, pick32(op == O_ASHR, 1, 2)));
        } else if op == O_MUL && k == 0 {
            // Bytes: the low bytes of the 16-bit products.
            self.vget(t.a);
            self.vget(t.b);
            self.sop(V_EXTMUL[0] + 2);
            self.vget(t.a);
            self.vget(t.b);
            self.sop(V_EXTMUL[0] + 3);
            for j in 0..16u32 {
                unsafe idx[j as usize] = (2 * j) as u8;
            }
            self.shuffle(&idx);
        } else {
            // A commutative operation reads the value the instruction before computed first: it stays on the
            // stack (`stack_values`).
            let swap = op != O_SUB && (t.b & (VPARAM | VFLAG)) == 0 && t.b + 1 == i;
            self.vget(pick_v(swap, t.b, t.a));
            self.vget(pick_v(swap, t.a, t.b));
            let code = if op == O_ADD {
                V_ADD[k]
            } else if op == O_SUB {
                V_SUB[k]
            } else if op == O_MUL {
                V_MUL[k]
            } else if op == O_AND {
                0x4Eu32
            } else if op == O_OR {
                0x50u32
            } else {
                0x51u32
            };
            self.sop(code);
        }
        self.vpost(i);
        return true;
    }

    // The lane-wise comparison `t` of 16-byte vectors (`O_VCMP`): its mask on the stack. Unsigned 8-byte lanes
    // compare as signed with their sign bits flipped.
    fn vcmp_reg(self: &mut Self, t: Inst) {
        let lt = lane_type(self.vt(t.a));
        let c = t.aux;
        if is_float(lt) {
            self.vget(t.a);
            self.vget(t.b);
            let off = if c == C_OEQ {
                0u32
            } else if c == C_UNE {
                1u32
            } else if c == C_OLT {
                2u32
            } else if c == C_OGT {
                3u32
            } else if c == C_OLE {
                4u32
            } else {
                5u32
            };
            self.sop(pick32(lt == T_F64, 0x47, 0x41) + off);
            return;
        }
        let k = size_log(lt) as usize;
        if lt != T_I64 {
            self.vget(t.a);
            self.vget(t.b);
            self.sop(V_EQ[k] + V_CMP[c as usize]);
            return;
        }
        let un = c >= C_ULT;
        let sc = if un {
            c - 4
        } else {
            c
        };
        self.vget(t.a);
        if un {
            self.vconst(1u64 << 63, 1u64 << 63);
            self.sop(0x51);
        }
        self.vget(t.b);
        if un {
            self.vconst(1u64 << 63, 1u64 << 63);
            self.sop(0x51);
        }
        self.sop(V_EQ[3] + V_CMP64[sc as usize]);
    }

    // Push 16-byte integer vector `v` (lanes of `nl`) with its runs of adjacent lanes summed into lanes of
    // `lt`, zero-extended (`O_VSUMW`): each step doubles the lane width, at most three.
    fn vsum_pairs(self: &mut Self, v: Value, nl: u8, lt: u8) {
        self.vget(v);
        let mut eb = type_bytes(nl, 4);
        while eb < type_bytes(lt, 4) {
            if eb == 1 {
                self.sop(0x7D);
            } else if eb == 2 {
                self.sop(0x7F);
            } else {
                // Each 8-byte lane: its low 4 bytes plus its high 4.
                let x = self.tmp(w::V128);
                self.c.local(w::LOCAL_TEE, x);
                self.vconst(0xFFFFFFFF, 0xFFFFFFFF);
                self.sop(0x4E);
                self.c.local(w::LOCAL_GET, x);
                self.c.i32_const(32);
                self.sop(V_SHL[3] + 2);
                self.sop(V_ADD[3]);
            }
            eb *= 2;
        }
    }

    // Whether bitcast `t` has a SIMD128 form: between a vector that fits a v128 (`vfit`) and a vector or an
    // i128 of its size, or a scalar of its size (lane 0).
    const fn cast_fits(self: &Self, t: Inst) bool {
        let from = self.vt(t.a);
        let n = type_bytes(t.ty, 4);
        if n != type_bytes(from, 4) || !vfit(t.ty) && !vfit(from) {
            return false;
        }
        let other = pick8(vfit(t.ty), from, t.ty);
        return is_vec(other) || other == T_I128 || is_float(other) || other == T_I32 || other == T_I64;
    }

    // Whether conversion `t` has a SIMD128 form (`vconv`): between vectors that fit a v128 (`vfit`, or of
    // 2 bytes), or between a 16-byte vector and a 32-byte one.
    fn conv_form(self: &Self, t: Inst) bool {
        let op = t.op;
        let st = self.vt(t.a);
        if !is_vec(st) || !is_vec(t.ty) {
            return false;
        }
        let fb = type_bytes(st, 4);
        let tb = type_bytes(t.ty, 4);
        let fe = type_bytes(lane_type(st), 4);
        let te = type_bytes(lane_type(t.ty), 4);
        if fb == 32 || tb == 32 {
            // Halves: an integer to twice its width and back, f32 to f64 and back, i32 to f64, f64 to i32.
            let wide = op == O_SEXT || op == O_ZEXT || op == O_FPEXT || (op == O_SITOFP || op == O_UITOFP) && fe == 4;
            let narrow = op == O_TRUNC || op == O_FPTRUNC || (op == O_FPTOSI || op == O_FPTOUI) && te == 4;
            return fb == 16 && tb == 32 && wide && te == 2 * fe || fb == 32 && tb == 16 && narrow && fe == 2 * te;
        }
        if fb > 16 || tb > 16 {
            return false;
        }
        if op == O_SITOFP || op == O_UITOFP {
            return te == 4 && fe <= 4 || te == 8 && fe == 4;
        }
        if op == O_FPTOSI || op == O_FPTOUI {
            return te == 4 && (fe == 4 || fe == 8);
        }
        // O_SEXT, O_ZEXT, O_TRUNC, O_FPEXT, O_FPTRUNC.
        return true;
    }

    // Push vector `v` (lanes of `fl`, at most 16 bytes) as a v128 of its low lanes extended to `te` bytes
    // (signed `sg`): a vector of 8 bytes in memory takes the first step in its load (`i16x8.load8x8_s` ..);
    // each step doubles the lane width, at most three.
    fn vext_low(self: &mut Self, v: Value, fl: u8, sg: bool, te: u32) {
        let mut e = type_bytes(fl, 4);
        if !self.mem_v(v) || type_bytes(self.vt(v), 4) != 8 || e >= te {
            self.vget(v);
        } else {
            self.c.local(w::LOCAL_GET, self.fp);
            self.sop(1 + 2 * log2u(e) + pick32(sg, 0, 1));
            self.c.memarg(3, self.mhome(v));
            e *= 2;
        }
        while e < te {
            self.sop(V_EXTEND[log2u(e) as usize] + pick32(sg, 0, 2));
            e *= 2;
        }
    }

    // Conversion `t` (`conv_form`) into instruction `i`.
    fn vconv(self: &mut Self, i: u32, t: Inst) {
        let op = t.op;
        let st = self.vt(t.a);
        let fl = lane_type(st);
        let fb = type_bytes(st, 4);
        let tb = type_bytes(t.ty, 4);
        let fe = type_bytes(fl, 4);
        let te = type_bytes(lane_type(t.ty), 4);
        let sg = op == O_SEXT || op == O_SITOFP || op == O_FPTOSI;
        let mut idx: [u8; 16] = [0; 16];
        if tb == 32 {
            // A widening of 16 bytes: the low lanes' result, then the high lanes'.
            let h = self.home[i as usize];
            if h == NONE {
                return;
            }
            let x = self.vlocal(t.a);
            for j in 0..16u32 {
                unsafe idx[j as usize] = (8 + j % 8) as u8;
            }
            for half in 0..2u32 {
                self.c.local(w::LOCAL_GET, self.fp);
                self.c.local(w::LOCAL_GET, x);
                if op == O_SEXT || op == O_ZEXT {
                    self.sop(V_EXTEND[log2u(fe) as usize] + half + pick32(sg, 0, 2));
                } else {
                    if half == 1 {
                        self.c.local(w::LOCAL_GET, x);
                        self.shuffle(&idx);
                    }
                    self.sop(
                        if op == O_FPEXT {
                            0x5Fu32
                        } else {
                            pick32(sg, 0xFE, 0xFF)
                        },
                    );
                }
                self.sop(w::V128_STORE);
                self.c.memarg(4, h + 16 * half);
            }
            return;
        }
        self.vpre(i);
        if fb == 32 {
            // A narrowing of 32 bytes: each half's lanes, then the bytes of both.
            let h = self.mhome(t.a);
            for half in 0..2u32 {
                self.c.local(w::LOCAL_GET, self.fp);
                self.sop(w::V128_LOAD);
                self.c.memarg(4, h + 16 * half);
                if op == O_FPTRUNC {
                    self.sop(0x5E);
                } else if op != O_TRUNC {
                    self.sop(pick32(sg, 0xFC, 0xFD));
                }
            }
            for j in 0..16u32 {
                unsafe idx[j as usize] = if op == O_TRUNC {
                    (j / te * fe + j % te) as u8
                } else {
                    (j + pick32(j >= 8, 8, 0)) as u8
                };
            }
            self.shuffle(&idx);
        } else if op == O_SEXT || op == O_ZEXT {
            self.vext_low(t.a, fl, sg, te);
        } else if op == O_TRUNC {
            // Each lane's low bytes.
            self.vget2(t.a);
            for j in 0..16u32 {
                unsafe idx[j as usize] = (j / te % (16 / fe) * fe + j % te) as u8;
            }
            self.shuffle(&idx);
        } else if op == O_FPEXT {
            self.vget(t.a);
            self.sop(0x5F);
        } else if op == O_FPTRUNC {
            self.vget(t.a);
            self.sop(0x5E);
        } else if op == O_SITOFP || op == O_UITOFP {
            if te == 8 {
                self.vget(t.a);
                self.sop(pick32(sg, 0xFE, 0xFF));
            } else {
                self.vext_low(t.a, fl, sg, 4);
                self.sop(pick32(sg, 0xFA, 0xFB));
            }
        } else {
            self.vget(t.a);
            self.sop(pick32(fe == 8, pick32(sg, 0xFC, 0xFD), pick32(sg, 0xF8, 0xF9)));
        }
        self.vpost(i);
    }
}

// Per narrow lane size (1, 2, 4 bytes): the signed minimum (+1: unsigned; +2: the maximums); per size (1, 2
// bytes) the signed saturating sum (+1: unsigned; +3: the differences).
const V_MIN: [u32; 3] = [0x76, 0x96, 0xB6];
const V_SAT: [u32; 2] = [0x6F, 0x8F];

extend Gen {
    // A local holding 16-byte value `v`: its own, or a scratch one loaded from its home.
    fn vlocal(self: &mut Self, v: Value) u32 {
        let x = self.vx(v);
        if !self.mem_v(v) && x != NONE && self.local_of[x as usize] != NONE {
            return self.local_of[x as usize];
        }
        let l = self.tmp(w::V128);
        self.vget(v);
        self.c.local(w::LOCAL_SET, l);
        return l;
    }

    // The conversion instruction `vop` cast `t` (`core::OP_CAST`) computes; an O_NOP one when it keeps the
    // lanes' kind and width.
    const fn cast_inst(self: &Self, t: Inst) Inst {
        let a = self.b().pool[t.a as usize];
        let fl = lane_type(self.vt(a));
        let tl = lane_type(t.ty);
        let fe = type_bytes(fl, 4);
        let te = type_bytes(tl, 4);
        let sg = (t.aux & VOP_SIGNED) != 0;
        let op = if is_float(fl) && is_float(tl) {
            pick8(fe < te, O_FPEXT, pick8(fe > te, O_FPTRUNC, 0))
        } else if is_float(tl) {
            pick8(sg, O_SITOFP, O_UITOFP)
        } else if is_float(fl) {
            pick8((t.aux & VOP_DSIGNED) != 0, O_FPTOSI, O_FPTOUI)
        } else {
            pick8(fe < te, pick8(sg, O_SEXT, O_ZEXT), pick8(fe > te, O_TRUNC, 0))
        };
        return Inst { op: op, ty: t.ty, aux: 0, a: a, b: 0, c: 0 };
    }

    // Whether `vop` `t` has a SIMD128 form (`vop_reg`): its 16-byte vector operands and result may live in
    // v128 locals or in memory.
    fn vop_form(self: &Self, t: Inst) bool {
        let b = self.b();
        let code = (t.aux & VOP_CODE) as u32;
        if t.b == 0 {
            return false;
        }
        let t0 = self.vt(b.pool[t.a as usize]);
        if code == core::OP_CAST {
            let ct = self.cast_inst(t);
            return ct.op != 0 && self.conv_form(ct);
        }
        if code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR {
            return vfit(t0) && t0 == t.ty;
        }
        if code < core::OP_SIMD || code >= core::OP_CMP_LANES {
            return false;
        }
        let c = (code - core::OP_SIMD) as u8;
        let rule = core::simd_op(c).rule;
        if rule == core::SR_INDEX {
            let two = c == core::SIMD_SHUFFLE && t.b == 2 && self.vt(b.pool[t.a as usize + 1]) == t0;
            return (c == core::SIMD_SWIZZLE && t.b == 1 || two) && t.c != VNONE && vfit(t0) && vfit(t.ty) && lane_type(
                t0,
            ) == lane_type(t.ty);
        }
        if t.c != VNONE || !vfit(t0) {
            return false;
        }
        if rule == core::SR_BITCAST {
            return vfit(t.ty) && type_bytes(t.ty, 4) == type_bytes(t0, 4);
        }
        let lt = lane_type(t0);
        let fl = is_float(lt);
        if rule == core::SR_REDUCE {
            let tree = c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_REDUCE_MUL_TREE;
            let mul = c == core::SIMD_REDUCE_MUL || c == core::SIMD_REDUCE_MUL_ORD || c == core::SIMD_REDUCE_MUL_TREE;
            let any = c == core::SIMD_REDUCE_ADD || c == core::SIMD_REDUCE_ADD_ORD || c >= core::SIMD_REDUCE_AND && c <= core::SIMD_REDUCE_XOR || c == core::SIMD_REDUCE_MIN || c == core::SIMD_REDUCE_MAX;
            return t.ty == lt && t.b == 1 && (tree || !fl && (any || mul && lt != T_I8));
        }
        if rule != core::SR_VEC && c != core::SIMD_ABS_DIFF || t.ty != t0 || t.b == 2 && self.vt(
            b.pool[t.a as usize + 1],
        ) != t0 || t.b > 2 {
            return false;
        }
        if fl {
            return c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_MINIMUM || c == core::SIMD_MAXIMUM || c == core::SIMD_ABS || c >= core::SIMD_SQRT && c <= core::SIMD_ROUND_EVEN;
        }
        let eb = type_bytes(lt, 4);
        return c == core::SIMD_WRAP_ADD || c == core::SIMD_WRAP_SUB || c == core::SIMD_WRAP_NEG || c == core::SIMD_WRAP_MUL && eb > 1 || c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_WRAP_ABS || c == core::SIMD_ABS && (t.aux & VOP_SIGNED) == 0 || (c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB) && eb <= 2 || c == core::SIMD_ABS_DIFF && eb <= 4;
    }

    // `vop` `t` (`vop_form`) into instruction `i`.
    fn vop_reg(self: &mut Self, i: u32, t: Inst) bool {
        let b = self.b();
        let code = (t.aux & VOP_CODE) as u32;
        let sg = (t.aux & VOP_SIGNED) != 0;
        let a = b.pool[t.a as usize];
        if code == core::OP_CAST {
            self.vconv(i, self.cast_inst(t));
            return true;
        }
        let lt = lane_type(self.vt(a));
        let k = size_log(lt) as usize;
        if code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR {
            self.vpre(i);
            self.vget(a);
            self.get(b.pool[t.a as usize + 1]);
            if self.vt(b.pool[t.a as usize + 1]) == T_I64 {
                self.c.op(w::I32_WRAP_I64);
            }
            self.sop(V_SHL[k] + pick32(code == core::OP_SHL_SCALAR, 0, pick32(sg, 1, 2)));
            self.vpost(i);
            return true;
        }
        let c = (code - core::OP_SIMD) as u8;
        let rule = core::simd_op(c).rule;
        if rule == core::SR_REDUCE {
            self.vreduce_reg(i, c, a, lt, sg);
            return true;
        }
        self.vpre(i);
        if rule == core::SR_INDEX {
            // Lane j is lane idx[j] of `a` (`a ++ b` for a shuffle, `b`'s lanes from byte 16).
            let eb = type_bytes(lt, 4);
            let n = lanes(self.vt(a));
            let cnt = b.pool[t.c as usize];
            let mut idx: [u8; 16] = [0; 16];
            for j in 0..16u32 {
                let x = if j / eb < cnt {
                    b.pool[(t.c + 1 + j / eb) as usize]
                } else {
                    0
                };
                unsafe idx[j as usize] = (pick32(x < n, x, 16 / eb + x - n) * eb + j % eb) as u8;
            }
            if t.b == 2 {
                self.vget(a);
                self.vget(b.pool[t.a as usize + 1]);
            } else {
                self.vget2(a);
            }
            self.shuffle(&idx);
        } else if rule == core::SR_BITCAST {
            self.vget(a);
        } else {
            let y = if t.b == 2 {
                b.pool[t.a as usize + 1]
            } else {
                VNONE
            };
            self.vec_rule(c, a, y, lt, sg);
        }
        self.vpost(i);
        return true;
    }

    // Push the lane rule `c` (`core::SR_VEC`) of 16-byte vectors `a` and `y` (VNONE for one operand), lanes
    // of `lt` (signed `sg`).
    fn vec_rule(self: &mut Self, c: u8, a: Value, y: Value, lt: u8, sg: bool) {
        let k = size_log(lt) as usize;
        let f = pick32(lt == T_F64, 1, 0);
        if is_float(lt) && (c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_MINIMUM || c == core::SIMD_MAXIMUM) {
            self.float_minmax(c, a, y, lt == T_F64);
            return;
        }
        if c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_ABS_DIFF {
            let x = self.vlocal(a);
            let z = self.vlocal(y);
            if c == core::SIMD_ABS_DIFF {
                // The larger lane less the smaller.
                self.int_minmax(x, z, lt, sg, true);
                self.int_minmax(x, z, lt, sg, false);
                self.sop(V_SUB[k]);
            } else {
                self.int_minmax(x, z, lt, sg, c == core::SIMD_MAX);
            }
            return;
        }
        self.vget(a);
        if y != VNONE {
            self.vget(y);
        }
        let code = if is_float(lt) {
            if c == core::SIMD_ABS {
                0xE0 + 12 * f
            } else if c == core::SIMD_SQRT {
                0xE3 + 12 * f
            } else if c == core::SIMD_CEIL {
                pick32(f == 1, 0x74, 0x67)
            } else if c == core::SIMD_FLOOR {
                pick32(f == 1, 0x75, 0x68)
            } else if c == core::SIMD_TRUNC {
                pick32(f == 1, 0x7A, 0x69)
            } else {
                pick32(f == 1, 0x94, 0x6A)
            }
        } else if c == core::SIMD_WRAP_ADD {
            V_ADD[k]
        } else if c == core::SIMD_WRAP_SUB {
            V_SUB[k]
        } else if c == core::SIMD_WRAP_MUL {
            V_MUL[k]
        } else if c == core::SIMD_WRAP_NEG {
            V_NEG[k]
        } else if c == core::SIMD_SAT_ADD || c == core::SIMD_SAT_SUB {
            V_SAT[k] + pick32(c == core::SIMD_SAT_SUB, 3, 0) + pick32(sg, 0, 1)
        } else if sg {
            // A signed lane's absolute value, the lowest value its own.
            0x60 + 0x20 * k as u32
        } else {
            // An unsigned lane is its absolute value.
            NOP
        };
        if code != NOP {
            self.sop(code);
        }
    }

    // Push the lane-wise minimum (`max`: maximum) of v128 locals `x` and `z` (lanes of `lt`, signed `sg`).
    // 8-byte lanes select by a comparison, unsigned ones with their sign bits flipped.
    fn int_minmax(self: &mut Self, x: u32, z: u32, lt: u8, sg: bool, max: bool) {
        let k = size_log(lt) as usize;
        if k < 3 {
            self.c.local(w::LOCAL_GET, x);
            self.c.local(w::LOCAL_GET, z);
            self.sop(V_MIN[k] + pick32(max, 2, 0) + pick32(sg, 0, 1));
            return;
        }
        // bitselect(x, z, x > z) is the maximum; bitselect(z, x, x > z) the minimum.
        self.c.local(w::LOCAL_GET, pick32(max, x, z));
        self.c.local(w::LOCAL_GET, pick32(max, z, x));
        let ls: [u32; 2] = [x, z];
        for q in 0..2usize {
            self.c.local(w::LOCAL_GET, ls[q]);
            if !sg {
                self.vconst(1u64 << 63, 1u64 << 63);
                self.sop(0x51);
            }
        }
        self.sop(V_EQ[3] + V_CMP64[C_SGT as usize]);
        self.sop(0x52);
    }

    // Push the float lane rule `c` (SIMD_MIN, SIMD_MAX, SIMD_MINIMUM, SIMD_MAXIMUM) of 16-byte vectors `a`
    // and `y` (f64 lanes when `dd`) by the lane loops' `fminmax`: SIMD128's `min` or `max`, which orders -0
    // below +0, past the NaNs. SIMD_MIN and SIMD_MAX take the other operand of a NaN, and of two NaNs `a`
    // with its quiet bit set; SIMD_MINIMUM and SIMD_MAXIMUM take a NaN operand, `a` first.
    fn float_minmax(self: &mut Self, c: u8, a: Value, y: Value, dd: bool) {
        let x = self.vlocal(a);
        let z = self.vlocal(y);
        let ne = pick32(dd, 0x48, 0x42);
        let num = c == core::SIMD_MIN || c == core::SIMD_MAX;
        let an = self.tmp(w::V128);
        self.c.local(w::LOCAL_GET, x);
        self.c.local(w::LOCAL_GET, x);
        self.sop(ne);
        self.c.local(w::LOCAL_SET, an);
        // `a`'s lanes where the second mask holds (SIMD_MIN, SIMD_MAX: `y`'s NaNs; else `a`'s).
        self.c.local(w::LOCAL_GET, x);
        if num {
            self.c.local(w::LOCAL_GET, an);
            let qb = pick64(dd, 1u64 << 51, 0x0040000000400000);
            self.vconst(qb, qb);
            self.sop(0x4E);
            self.sop(0x50);
        }
        // `y`'s lanes where the first holds (SIMD_MIN, SIMD_MAX: `a`'s NaNs; else `y`'s), else the minimum or
        // maximum.
        self.c.local(w::LOCAL_GET, z);
        self.c.local(w::LOCAL_GET, x);
        self.c.local(w::LOCAL_GET, z);
        self.sop(pick32(dd, 0xF4, 0xE8) + pick32(c == core::SIMD_MIN || c == core::SIMD_MINIMUM, 0, 1));
        for q in 0..2u32 {
            if num == (q == 0) {
                self.c.local(w::LOCAL_GET, an);
            } else {
                self.c.local(w::LOCAL_GET, z);
                self.c.local(w::LOCAL_GET, z);
                self.sop(ne);
            }
            self.sop(0x52);
        }
    }

    // Reduction `c` (`vop_form`) of vector `a` (lanes of `lt`, signed `sg`) into instruction `i`:
    // each step folds the upper half of the lanes it has left into the lower half, at most four; then lane 0.
    fn vreduce_reg(self: &mut Self, i: u32, c: u8, a: Value, lt: u8, sg: bool) {
        let eb = type_bytes(lt, 4);
        let k = size_log(lt) as usize;
        let f = pick32(lt == T_F64, 1, 0);
        let add = c == core::SIMD_REDUCE_ADD || c == core::SIMD_REDUCE_ADD_ORD || c == core::SIMD_REDUCE_ADD_TREE;
        let code = if is_float(lt) {
            pick32(add, 0xE4, 0xE6) + 12 * f
        } else if add {
            V_ADD[k]
        } else if c == core::SIMD_REDUCE_AND {
            0x4Eu32
        } else if c == core::SIMD_REDUCE_OR {
            0x50u32
        } else if c == core::SIMD_REDUCE_XOR {
            0x51u32
        } else {
            V_MUL[k]
        };
        let pair = (c == core::SIMD_REDUCE_MIN || c == core::SIMD_REDUCE_MAX) && k == 3;
        let acc = self.tmp(w::V128);
        let s = self.tmp(w::V128);
        self.vget(a);
        let mut idx: [u8; 16] = [0; 16];
        let mut h = lanes(self.vt(a)) / 2;
        while h != 0 {
            for j in 0..16u32 {
                unsafe idx[j as usize] = (j + h * eb & 15) as u8;
            }
            self.c.local(pick8(pair, w::LOCAL_SET, w::LOCAL_TEE), acc);
            self.c.local(w::LOCAL_GET, acc);
            if pair {
                self.c.local(w::LOCAL_GET, acc);
                self.shuffle(&idx);
                self.c.local(w::LOCAL_SET, s);
                self.int_minmax(acc, s, lt, sg, c == core::SIMD_REDUCE_MAX);
            } else {
                self.c.local(w::LOCAL_GET, acc);
                self.shuffle(&idx);
                if c == core::SIMD_REDUCE_MIN || c == core::SIMD_REDUCE_MAX {
                    self.sop(V_MIN[k] + pick32(c == core::SIMD_REDUCE_MAX, 2, 0) + pick32(sg, 0, 1));
                } else {
                    self.sop(code);
                }
            }
            h /= 2;
        }
        self.lane_op(VL_EXTRACT, lt);
        self.c.op(0);
        self.put(i);
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
        return self.asm_text(&tpl);
    }

    // Assemble template `text` onto the code, its symbols as relocations.
    fn asm_text(self: &mut Self, text: str) bool {
        self.asm_code = true;
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
            if !self.asm_text(&tpl) {
                return false;
            }
        }
        self.c.op(w::END);
        return self.finish(s);
    }
}
