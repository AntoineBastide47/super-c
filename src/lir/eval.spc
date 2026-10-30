// The LIR evaluator: runs a package's bodies with the host data model, so the lowering can be checked
// against the CTFE interpreter (`ir::interp`) and an optimizer pass against its input. Memory is
// byte-addressed per object: each stack slot, heap block, data symbol and function is an object, and a
// pointer is `object << 32 | offset`, so an access outside its object, through a freed object or through
// null is an error, as in the interpreter, while a pointer still converts to an integer and back. Calls
// run on an explicit frame stack. The C library and runtime routines the interpreter models are modeled
// here alike; any other extern call ends the run as FFI. Steps, memory and call depth are budgeted.
import lir::ir as *;
import lir::print as lprint;
import ir::interp as iri;
import ast::ast as ast;
import std::float as fl;
import math;
import stdlib;
import ir::core as core;

/// How a run ended (`Outcome.kind`): the interpreter's trap kinds (`ir::interp::IT_TRAP_*`), or one of these.
pub(package) const EV_OK: u8 = 0;
/// An extern call or inline assembly the evaluator does not model.
pub(package) const EV_FFI: u8 = 100;
/// An instruction the evaluator cannot run: a malformed body or an unsupported operation.
pub(package) const EV_ERROR: u8 = 101;

/// The end of a run: its kind, the message, the location of the instruction that ended it (a panic, a
/// trap, the failing access), and a scalar result.
pub(package) struct Outcome {
    pub(package) kind: u8,
    pub(package) msg: String,
    pub(package) loc: Loc,
    /// The location of the outermost frame's instruction when the run ended (the test's statement).
    pub(package) top: Loc,
    pub(package) value: u64,
}

// Object kinds.
const OB_STACK: u8 = 0;
const OB_HEAP: u8 = 1;
const OB_DATA: u8 = 2;
const OB_FUNC: u8 = 3;

// An object: `size` bytes at `base` of its arena (the stack arena for a slot, the heap arena else).
struct Obj {
    pub(package) base: u64,
    pub(package) size: u64,
    pub(package) kind: u8,
    pub(package) live: bool,
    pub(package) sym: u32, // a data or function object's symbol
}

// One call: its body, the next instruction, its values' first word, and where its result goes.
struct Frame {
    pub(package) body: u32,
    pub(package) pc: u32,
    pub(package) vbase: u32,
    pub(package) obj0: u32, // the object of its slot 0
    pub(package) stack_mark: u64, // the stack arena's length at entry
    pub(package) ret_word: u32, // the caller's word for the result, NONE without one
    pub(package) ret_ty: u8,
    pub(package) va: u32, // its variadic arguments' first word in `vargs`
    pub(package) nva: u32,
    pub(package) va_ty: u32, // their types' first entry in `vatys`
}

// Per body, the first word of each value: instructions, then block parameters.
struct Words {
    pub(package) off: Vector<u32>,
    pub(package) total: u32,
}

/// The evaluator over one package.
pub(package) struct Eval {
    pkg: *const Package,
    pub(package) max_steps: u64,
    pub(package) max_bytes: u64,
    pub(package) max_depth: u32,
    steps: u64,
    objs: Vector<Obj>,
    stack: Vector<u8>,
    heap: Vector<u8>,
    vals: Vector<u64>,
    frames: Vector<Frame>,
    words: Vector<Words>, // per body, built on first call
    sym_obj: Vector<u32>, // per symbol, its object, 0 before its first address
    icode: Vector<u8>, // per symbol, the routine the evaluator models (`IC_*`), IC_NONE for none
    vargs: Vector<u64>,
    vatys: Vector<u8>,
    tmp: Vector<u64>,
    succ: Vector<u32>,
    trace: bool, // SC_LIR_TRACE: print each call with its argument words and each return with its result words
    acct_on: bool, // the allocation accounting (`sc_bs_alloc_enable`) is on
    acct_calls: u64, // the malloc, calloc and realloc calls counted
    acct_bytes: u64, // the bytes they requested
    out: Outcome,
}

extend Obj as Copy {}
extend Frame as Copy {}

extend Eval {
    pub(package) fn new(pkg: &Package) Eval {
        let mut e = Eval {
            pkg: pkg,
            max_steps: 50000000,
            max_bytes: 1u64 << 30,
            max_depth: 4096,
            steps: 0,
            objs: Vector::<Obj>::new(),
            stack: Vector::<u8>::new(),
            heap: Vector::<u8>::new(),
            vals: Vector::<u64>::new(),
            frames: Vector::<Frame>::new(),
            words: Vector::<Words>::new(),
            sym_obj: Vector::<u32>::new(),
            icode: Vector::<u8>::new(),
            vargs: Vector::<u64>::new(),
            vatys: Vector::<u8>::new(),
            tmp: Vector::<u64>::new(),
            succ: Vector::<u32>::new(),
            trace: stdlib::getenv("SC_LIR_TRACE") != null,
            acct_on: false,
            acct_calls: 0,
            acct_bytes: 0,
            out: Outcome {
                kind: EV_OK,
                msg: String::new(),
                loc: Loc { file: 0, line: 0, col: 0 },
                top: Loc { file: 0, line: 0, col: 0 },
                value: 0,
            },
        };
        // Object 0 is null.
        e.objs.push(Obj { base: 0, size: 0, kind: OB_HEAP, live: false, sym: NONE });
        e.sym_obj.resize_default(pkg.syms.len());
        e.icode.reserve(pkg.syms.len());
        for i in 0..pkg.syms.len() {
            e.icode.push(
                if pkg.syms[i].kind == SK_FUNC {
                    icode_of(pkg.spell(pkg.syms[i].name))
                } else {
                    IC_NONE
                },
            );
        }
        e.words.reserve(pkg.bodies.len());
        for _ in 0..pkg.bodies.len() {
            e.words.push(Words { off: Vector::<u32>::new(), total: NONE });
        }
        return e;
    }

    /// Run function symbol `sym` with the scalar arguments `args` (one word each) from the package's
    /// initial memory; the outcome.
    pub(package) fn run(self: &mut Self, sym: u32, args: []u64) Outcome {
        self.acct_on = false;
        self.acct_calls = 0;
        self.acct_bytes = 0;
        self.out.kind = EV_OK;
        self.out.msg.clear();
        self.out.loc = Loc { file: 0, line: 0, col: 0 };
        self.out.top = self.out.loc;
        self.out.value = 0;
        self.steps = 0;
        self.frames.truncate(0);
        self.vals.truncate(0);
        self.objs.truncate(1);
        self.stack.truncate(0);
        self.heap.truncate(0);
        for k in 0..self.sym_obj.len() {
            self.sym_obj[k] = 0;
        }
        if sym as usize >= (unsafe &*self.pkg).syms.len() {
            self.stop(EV_ERROR, "no such symbol");
            return self.result();
        }
        let s = (unsafe &*self.pkg).syms[sym as usize];
        if s.kind != SK_FUNC || s.def == NONE {
            self.stop(EV_FFI, (unsafe &*self.pkg).spell(s.name));
            return self.result();
        }
        self.tmp.truncate(0);
        for i in 0..args.len() {
            self.tmp.push(args[i]);
        }
        if self.enter(s.def, NONE, T_NONE, 0) {
            self.exec();
        }
        return self.result();
    }

    fn result(self: &mut Self) Outcome {
        return Outcome {
            kind: self.out.kind,
            msg: self.out.msg.clone(),
            loc: self.out.loc,
            top: self.out.top,
            value: self.out.value,
        };
    }

    fn stop(self: &mut Self, kind: u8, msg: str) bool {
        if self.out.kind == EV_OK {
            self.out.kind = kind;
            self.out.msg.push_str(msg);
            if self.frames.len() != 0 {
                self.out.loc = self.frame_loc(self.frames.len() - 1);
                self.out.top = self.frame_site(0);
            }
        }
        return false;
    }

    // The location of frame `fi`'s current instruction.
    const fn frame_loc(self: &Self, fi: usize) Loc {
        let f = self.frames[fi];
        let b = &(unsafe &*self.pkg).bodies[f.body as usize];
        let mut i: u32 = 0;
        if f.pc != 0 {
            i = f.pc - 1;
        }
        if i as usize < b.locs.len() {
            return b.lines[b.locs[i as usize] as usize];
        }
        return Loc { file: 0, line: 0, col: 0 };
    }

    // The location of frame `fi`'s current statement: its instruction's, or the call that instruction was
    // inlined from.
    const fn frame_site(self: &Self, fi: usize) Loc {
        let f = self.frames[fi];
        let b = &(unsafe &*self.pkg).bodies[f.body as usize];
        let i = if f.pc != 0 {
            f.pc - 1
        } else {
            0u32
        };
        if i as usize < b.inl.len() && b.inl[i as usize] != 0 {
            return b.lines[b.inl[i as usize] as usize];
        }
        return self.frame_loc(fi);
    }

    // The value words of body `bi`.
    fn words_of(self: &mut Self, bi: u32) {
        if self.words[bi as usize].total != NONE {
            return;
        }
        let b = &(unsafe &*self.pkg).bodies[bi as usize];
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let mut off = Vector::<u32>::with_capacity(b.insts.len() + b.params.len());
        let mut n: u32 = 0;
        for i in 0..b.insts.len() {
            off.push(n);
            // A checked operation's flag is the word after its value (of one word).
            n += value_words(b.insts[i].ty, ptr) + ast::pick(op_info(b.insts[i].op).form == F_OVF, 1u32, 0);
        }
        for i in 0..b.params.len() {
            off.push(n);
            n += value_words(b.params[i], ptr);
        }
        self.words[bi as usize] = Words { off: off, total: n };
    }

    // Push a frame for body `bi` with the arguments in `tmp` (one word each, wide values in order) as its
    // entry parameters; its result goes to the caller's word `ret_word`.
    fn enter(self: &mut Self, bi: u32, ret_word: u32, ret_ty: u8, nfixed_words: u32) bool {
        if self.frames.len() as u32 >= self.max_depth {
            return self.stop(iri::IT_TRAP_BUDGET_DEPTH, "call depth exceeded");
        }
        self.words_of(bi);
        if self.trace {
            let pk = unsafe &*self.pkg;
            for q in 0..pk.syms.len() {
                if pk.syms[q].def == bi && pk.syms[q].kind == SK_FUNC {
                    eprint("lir-trace {} {}", self.frames.len(), pk.spell(pk.syms[q].name));
                }
            }
            for q in 0..self.tmp.len() {
                eprint(" {}", self.tmp[q]);
            }
            eprint("\n");
        }
        let vbase = self.vals.len() as u32;
        let total = self.words[bi as usize].total;
        self.vals.resize_default(self.vals.len() + total as usize);
        let b = &(unsafe &*self.pkg).bodies[bi as usize];
        let obj0 = self.objs.len() as u32;
        let mark = self.stack.len() as u64;
        for k in 0..b.slots.len() {
            let sl = b.slots[k];
            let al = 1u64 << sl.align_log2 as u64;
            let base = self.stack.len() as u64 + al - 1 & ~(al - 1);
            self.stack.resize_default(base as usize + sl.size as usize);
            self.objs.push(Obj { base: base, size: sl.size, kind: OB_STACK, live: true, sym: NONE });
        }
        if self.stack.len() as u64 + self.heap.len() as u64 > self.max_bytes {
            return self.stop(iri::IT_TRAP_BUDGET_MEMORY, "memory budget exceeded");
        }
        let entry = b.blocks[0];
        let words = &self.words[bi as usize];
        let mut w: usize = 0;
        for k in 0..entry.param_len as u32 {
            let pi = entry.param_start + k;
            let at = vbase + words.off[b.insts.len() + pi as usize];
            let nw = value_words(b.params[pi as usize], (unsafe &*self.pkg).ptr_bytes);
            for j in 0..nw {
                if w >= self.tmp.len() {
                    return self.stop(EV_ERROR, "a call passes fewer arguments than its callee takes");
                }
                self.vals[(at + j) as usize] = self.tmp[w];
                w += 1;
            }
        }
        // The words past the fixed parameters are the variadic arguments.
        let va = self.vargs.len() as u32;
        let nva = (self.tmp.len() - w) as u32;
        for j in w..self.tmp.len() {
            self.vargs.push(self.tmp[j]);
        }
        let _ = nfixed_words;
        self.frames.push(
            Frame {
                body: bi,
                pc: entry.start,
                vbase: vbase,
                obj0: obj0,
                stack_mark: mark,
                ret_word: ret_word,
                ret_ty: ret_ty,
                va: va,
                nva: nva,
                va_ty: self.vatys.len() as u32,
            },
        );
        return true;
    }

    // Leave the top frame: its slots die, its values and variadic words go, and its result (in `tmp`)
    // reaches the caller.
    fn leave(self: &mut Self) {
        let f = self.frames[self.frames.len() - 1];
        let b = &(unsafe &*self.pkg).bodies[f.body as usize];
        for k in 0..b.slots.len() {
            self.objs.index_mut((f.obj0 + k as u32) as usize).live = false;
        }
        self.stack.truncate(f.stack_mark as usize);
        self.vals.truncate(f.vbase as usize);
        self.vargs.truncate(f.va as usize);
        self.vatys.truncate(f.va_ty as usize);
        self.frames.truncate(self.frames.len() - 1);
        if self.trace {
            eprint("lir-trace {} ret", self.frames.len());
            for q in 0..self.tmp.len() {
                eprint(" {}", self.tmp[q]);
            }
            eprint("\n");
        }
        if f.ret_word != NONE {
            for j in 0..self.tmp.len() {
                self.vals[f.ret_word as usize + j] = self.tmp[j];
            }
        } else if self.tmp.len() != 0 && self.frames.len() == 0 {
            self.out.value = self.tmp[0];
        }
    }

    // The first word of value `v` of the top frame.
    const fn word(self: &Self, f: &Frame, b: &Body, v: Value) u32 {
        let w = &self.words[f.body as usize];
        if (v & VPARAM) != 0 {
            return f.vbase + w.off[b.insts.len() + (v & ~VPARAM) as usize];
        }
        if (v & VFLAG) != 0 {
            return f.vbase + w.off[(v & ~VFLAG) as usize] + 1;
        }
        return f.vbase + w.off[v as usize];
    }

    const fn val(self: &Self, f: &Frame, b: &Body, v: Value) u64 {
        return self.vals[self.word(f, b, v) as usize];
    }

    fn exec(self: &mut Self) {
        // Each step runs one instruction; the step budget bounds the loop.
        while self.frames.len() != 0 && self.out.kind == EV_OK {
            self.steps += 1;
            if self.steps > self.max_steps {
                let _ = self.stop(iri::IT_TRAP_BUDGET_STEPS, "step budget exceeded");
                return;
            }
            let _ = self.step();
        }
    }

    fn step(self: &mut Self) bool {
        let fi = self.frames.len() - 1;
        let f = self.frames[fi];
        let b = &(unsafe &*self.pkg).bodies[f.body as usize];
        let t = b.insts[f.pc as usize];
        self.frames.index_mut(fi).pc = f.pc + 1;
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let dst = if t.ty != T_NONE {
            self.word(&f, b, f.pc)
        } else {
            NONE
        };
        let op = t.op;
        if op == O_ICONST || op == O_FCONST {
            self.vals[dst as usize] = t.b as u64 << 32 | t.a as u64;
            return true;
        }
        if op == O_WCONST {
            for k in 0..t.b {
                self.vals[(dst + k) as usize] = b.words[(t.a + k) as usize];
            }
            return true;
        }
        if op == O_SYMADDR {
            let o = self.sym_object(b.syms[t.a as usize]);
            if o == 0 {
                return false;
            }
            self.vals[dst as usize] = (o as u64 << 32).wrapping_add(((t.b as i32) as i64) as u64);
            return true;
        }
        if op == O_SLOTADDR {
            self.vals[dst as usize] = (f.obj0 + t.a) as u64 << 32;
            return true;
        }
        if op >= O_ADD && op <= O_NOT {
            if is_vec(t.ty) {
                return self.vec_int(&f, b, t, dst);
            }
            if t.ty == T_I128 {
                return self.int128(&f, b, t, dst);
            }
            return self.int_op(
                op,
                t.ty,
                self.val(&f, b, t.a),
                if t.b != VNONE && op != O_NEG && op != O_NOT {
                    self.val(&f, b, t.b)
                } else {
                    0
                },
                dst,
            );
        }
        if op == O_SPLAT {
            let lb = type_bits(lane_type(t.ty), ptr);
            let x = self.val(&f, b, t.a);
            for k in 0..lanes(t.ty) {
                set_lane(&mut self.vals, dst, k, lb, x);
            }
            return true;
        }
        if op == O_VCMP {
            let vt = b.type_of(t.a);
            let lt = lane_type(vt);
            let lb = type_bits(lt, ptr);
            let wa = self.word(&f, b, t.a);
            let wb = self.word(&f, b, t.b);
            for k in 0..lanes(vt) {
                let x = get_lane(&self.vals, wa, k, lb);
                let y = get_lane(&self.vals, wb, k, lb);
                let holds = if is_float(lt) {
                    fcmp(t.aux, to_f64(lt, x), to_f64(lt, y))
                } else {
                    icmp(t.aux, lt, ptr, x, y)
                };
                set_lane(&mut self.vals, dst, k, lb, ast::pick(holds, ~0u64, 0u64));
            }
            return true;
        }
        if op == O_VEXTRACT {
            let vt = b.type_of(t.a);
            let wa = self.word(&f, b, t.a);
            self.vals[dst as usize] = get_lane(&self.vals, wa, t.aux, type_bits(lane_type(vt), ptr));
            return true;
        }
        if op == O_VINSERT {
            let wa = self.word(&f, b, t.a);
            let x = self.val(&f, b, t.b);
            for k in 0..value_words(t.ty, ptr) {
                self.vals[(dst + k) as usize] = self.vals[(wa + k) as usize];
            }
            set_lane(&mut self.vals, dst, t.aux, type_bits(lane_type(t.ty), ptr), x);
            return true;
        }
        if op == O_VZIPLO || op == O_VZIPHI {
            let lb = type_bits(lane_type(t.ty), ptr);
            let n = lanes(t.ty);
            let wa = self.word(&f, b, t.a);
            let wb = self.word(&f, b, t.b);
            let h = if op == O_VZIPHI {
                n / 2
            } else {
                0
            };
            for k in 0..n / 2 {
                let x = get_lane(&self.vals, wa, h + k, lb);
                let y = get_lane(&self.vals, wb, h + k, lb);
                set_lane(&mut self.vals, dst, 2 * k, lb, x);
                set_lane(&mut self.vals, dst, 2 * k + 1, lb, y);
            }
            return true;
        }
        if op == O_VUNZIP {
            let lb = type_bits(lane_type(t.ty), ptr);
            let n = lanes(t.ty);
            let wa = self.word(&f, b, t.a);
            let wb = self.word(&f, b, t.b);
            for k in 0..n {
                let j = 2 * k;
                let x = if j < n {
                    get_lane(&self.vals, wa, j, lb)
                } else {
                    get_lane(&self.vals, wb, j - n, lb)
                };
                set_lane(&mut self.vals, dst, k, lb, x);
            }
            return true;
        }
        if op == O_HTOF {
            self.vals[dst as usize] = half_to_f32_bits(self.val(&f, b, t.a) as u32 & 0xFFFF);
            return true;
        }
        if op == O_FTOH {
            self.vals[dst as usize] = f32_bits_to_half(self.val(&f, b, t.a) as u32);
            return true;
        }
        if op == O_VSEL {
            let wm = self.word(&f, b, t.a);
            let wx = self.word(&f, b, t.b);
            let wy = self.word(&f, b, t.c);
            for q in 0..value_words(t.ty, ptr) {
                let m = self.vals[(wm + q) as usize];
                self.vals[(dst + q) as usize] = self.vals[(wx + q) as usize] & m | self.vals[(wy + q) as usize] & ~m;
            }
            return true;
        }
        if op == O_MULHU {
            let bits = type_bits(t.ty, ptr);
            let x = trunc_bits(self.val(&f, b, t.a), bits) as u128;
            let y = trunc_bits(self.val(&f, b, t.b), bits) as u128;
            self.vals[dst as usize] = (x * y >> bits as usize) as u64;
            return true;
        }
        if op == O_MULHS {
            let bits = type_bits(t.ty, ptr);
            let x = sign_ext(self.val(&f, b, t.a), bits) as i128;
            let y = sign_ext(self.val(&f, b, t.b), bits) as i128;
            self.vals[dst as usize] = trunc_bits((x * y >> bits as usize) as u64, bits);
            return true;
        }
        if op == O_CLZ || op == O_CTZ || op == O_POPCNT {
            let bits = type_bits(t.ty, ptr);
            let x = trunc_bits(self.val(&f, b, t.a), bits);
            self.vals[dst as usize] = if op == O_POPCNT {
                x.count_ones() as u64
            } else if x == 0 {
                bits
            } else if op == O_CLZ {
                (x.leading_zeros() - (64 - bits as usize)) as u64
            } else {
                x.trailing_zeros() as u64
            };
            return true;
        }
        if op == O_ADDO || op == O_SUBO || op == O_MULO {
            let x = self.val(&f, b, t.a);
            let y = self.val(&f, b, t.b);
            self.vals[dst as usize + 1] = overflows(op, t.ty, ptr, t.aux == OV_SIGNED, x, y) as u64;
            return self.int_op(op - (O_ADDO - O_ADD), t.ty, x, y, dst);
        }
        if op == O_ICMP {
            let ty = b.type_of(t.a);
            if ty == T_I128 {
                let wa = self.word(&f, b, t.a);
                let wb = self.word(&f, b, t.b);
                self.vals[dst as usize] = icmp128(
                    t.aux,
                    self.vals[wa as usize],
                    self.vals[wa as usize + 1],
                    self.vals[wb as usize],
                    self.vals[wb as usize + 1],
                ) as u64;
                return true;
            }
            self.vals[dst as usize] = icmp(t.aux, ty, ptr, self.val(&f, b, t.a), self.val(&f, b, t.b)) as u64;
            return true;
        }
        if op == O_FCMP {
            let ty = b.type_of(t.a);
            self.vals[dst as usize] = fcmp(t.aux, to_f64(ty, self.val(&f, b, t.a)), to_f64(ty, self.val(&f, b, t.b))) as u64;
            return true;
        }
        if op >= O_FADD && op <= O_FNEG || op == O_FSQRT {
            if is_vec(t.ty) {
                return self.vec_float(&f, b, t, dst);
            }
            self.vals[dst as usize] = float_op(
                op,
                t.ty,
                self.val(&f, b, t.a),
                if op != O_FNEG && op != O_FSQRT {
                    self.val(&f, b, t.b)
                } else {
                    0
                },
            );
            return true;
        }
        if op >= O_SEXT && op <= O_INTTOPTR {
            return self.convert(&f, b, t, dst);
        }
        if op == O_PTRADD {
            let mut p = self.val(&f, b, t.a);
            if t.b != VNONE {
                let ix = sign_ext(self.val(&f, b, t.b), type_bits(b.type_of(t.b), ptr));
                p = p.wrapping_add((ix as u64).wrapping_mul(t.aux));
            }
            self.vals[dst as usize] = p.wrapping_add(((t.c as i32) as i64) as u64);
            return true;
        }
        if op == O_LOAD || op == O_ALOAD {
            let p = self.val(&f, b, t.a).wrapping_add(
                pick_u64(op == O_LOAD, ((t.c as i32) as i64) as u64, ((t.c as i32) as i64) as u64),
            );
            return self.load(p, t.ty, dst);
        }
        if op == O_STORE || op == O_ASTORE {
            let p = self.val(&f, b, t.a).wrapping_add(((t.c as i32) as i64) as u64);
            return self.store(p, b.type_of(t.b), self.word(&f, b, t.b));
        }
        if op == O_ARMW {
            let p = self.val(&f, b, t.a).wrapping_add(((t.c as i32) as i64) as u64);
            if !self.load(p, t.ty, dst) {
                return false;
            }
            let old = self.vals[dst as usize];
            let v = self.val(&f, b, t.b);
            let r = t.aux >> 4;
            let nv = if r == RMW_XCHG {
                v
            } else if r == RMW_ADD {
                old.wrapping_add(v)
            } else if r == RMW_SUB {
                old.wrapping_sub(v)
            } else if r == RMW_AND {
                old & v
            } else if r == RMW_OR {
                old | v
            } else {
                old ^ v
            };
            self.tmp.truncate(0);
            self.tmp.push(trunc_bits(nv, type_bits(t.ty, ptr)));
            return self.store_words(p, t.ty);
        }
        if op == O_ACAS {
            let p = self.val(&f, b, t.a);
            let ty = b.type_of(t.b);
            let w0 = self.vals.len();
            self.vals.push(0);
            if !self.load(p, ty, w0 as u32) {
                return false;
            }
            let old = self.vals[w0];
            self.vals.truncate(w0);
            let hit = old == self.val(&f, b, t.b);
            if hit {
                self.tmp.truncate(0);
                self.tmp.push(self.val(&f, b, t.c));
                if !self.store_words(p, ty) {
                    return false;
                }
            }
            self.vals[dst as usize] = hit as u64;
            return true;
        }
        if op == O_FENCE {
            return true;
        }
        if op == O_MEMCPY {
            return self.copy_bytes(self.val(&f, b, t.a), self.val(&f, b, t.b), self.val(&f, b, t.c));
        }
        if op == O_MEMSET {
            return self.set_bytes(self.val(&f, b, t.a), self.val(&f, b, t.b) as u8, self.val(&f, b, t.c));
        }
        if op == O_FMA {
            let x = self.val(&f, b, t.a);
            let y = self.val(&f, b, t.b);
            let z = self.val(&f, b, t.c);
            self.vals[dst as usize] = if t.ty == T_F32 {
                fl::f32_bits(
                    math::fmaf(fl::f32_from_bits(x as u32), fl::f32_from_bits(y as u32), fl::f32_from_bits(z as u32)),
                )
            } else {
                fl::f64_bits(math::fma(fl::f64_from_bits(x), fl::f64_from_bits(y), fl::f64_from_bits(z)))
            };
            return true;
        }
        if op == O_SELECT {
            let src = if self.val(&f, b, t.a) != 0 {
                t.b
            } else {
                t.c
            };
            let sw = self.word(&f, b, src);
            for k in 0..value_words(t.ty, ptr) {
                self.vals[(dst + k) as usize] = self.vals[(sw + k) as usize];
            }
            return true;
        }
        if op == O_RETADDR {
            return self.stop(iri::IT_TRAP_UNSUPPORTED, "a return address has no evaluated value");
        }
        if op == O_SYS {
            // A spin hint and the barriers change no value; the processor's other operations the evaluator
            // does not model, as an extern call.
            if t.aux == SYS_SPIN || t.aux == SYS_BARRIER || t.aux == SYS_KEEP {
                return true;
            }
            return self.stop(EV_FFI, "a system operation");
        }
        if op == O_ASM {
            // An empty template without outputs runs nothing (a compiler barrier); other machine code the
            // evaluator does not model, as an extern call.
            let pk = unsafe &*self.pkg;
            if asm_nout(b, t.c) == 0 && pk.spell(pk.msgs[b.msgs[asm_template(b, t.c) as usize] as usize]).trim().len() == 0 {
                return true;
            }
            return self.stop(EV_FFI, "inline assembly");
        }
        if op == O_CALL || op == O_CALLIND {
            return self.call(&f, b, t, dst);
        }
        if op == O_VOP {
            return self.vop(&f, b, t, dst);
        }
        if op == O_VASTART {
            // A va_list holds the frame's first variadic word and the next one to read.
            self.tmp.truncate(0);
            self.tmp.push(f.va as u64 << 32 | 0);
            return self.store_words(self.val(&f, b, t.a), T_I64);
        }
        if op == O_VAARG {
            let p = self.val(&f, b, t.a);
            let w0 = self.vals.len();
            self.vals.push(0);
            if !self.load(p, T_I64, w0 as u32) {
                return false;
            }
            let st = self.vals[w0];
            self.vals.truncate(w0);
            let base = (st >> 32) as u32;
            let k = st as u32;
            let nw = value_words(t.ty, ptr);
            if base != f.va || k + nw > f.nva {
                return self.stop(EV_ERROR, "va_arg past the variadic arguments");
            }
            for j in 0..nw {
                self.vals[(dst + j) as usize] = self.vargs[(base + k + j) as usize];
            }
            self.tmp.truncate(0);
            self.tmp.push(base as u64 << 32 | (k + nw) as u64);
            return self.store_words(p, T_I64);
        }
        if op == O_VAEND {
            return true;
        }
        if op == O_JMP {
            return self.take(&f, b, t.a);
        }
        if op == O_BR {
            return self.take(&f, b, pick_u32(self.val(&f, b, t.a) != 0, t.b, t.c));
        }
        if op == O_SWITCH {
            let v = self.val(&f, b, t.a);
            let bits = type_bits(b.type_of(t.a), ptr);
            for k in 0..t.aux as u32 {
                if trunc_bits(b.words[(t.b + k) as usize], bits) == v {
                    return self.take(&f, b, b.switch_edge(t, k));
                }
            }
            return self.take(&f, b, b.switch_edge(t, t.aux));
        }
        if op == O_RET {
            self.tmp.truncate(0);
            if t.a != VNONE {
                let w = self.word(&f, b, t.a);
                for k in 0..value_words(b.type_of(t.a), ptr) {
                    self.tmp.push(self.vals[(w + k) as usize]);
                }
            }
            self.leave();
            return true;
        }
        if op == O_PANIC {
            let m = (unsafe &*self.pkg).spell((unsafe &*self.pkg).msgs[b.msgs[t.a as usize] as usize]);
            if t.b == VNONE {
                return self.stop(iri::IT_TRAP_PANIC, m);
            }
            let lane = self.val(&f, b, t.b).trailing_zeros();
            return self.stop(iri::IT_TRAP_PANIC, format("lane {}: {}", lane, m).as_str());
        }
        if op == O_UNREACHABLE {
            return self.stop(EV_ERROR, "unreachable reached");
        }
        return self.stop(EV_ERROR, "an unknown opcode");
    }

    // Take edge `e` of the top frame: its arguments (read first) become its target's parameters.
    fn take(self: &mut Self, f: &Frame, b: &Body, e: u32) bool {
        let tb = b.edge_target(e);
        let blk = b.blocks[tb as usize];
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        self.tmp.truncate(0);
        for k in 0..b.edge_nargs(e) {
            let v = b.edge_arg(e, k);
            let w = self.word(f, b, v);
            for j in 0..value_words(b.type_of(v), ptr) {
                self.tmp.push(self.vals[(w + j) as usize]);
            }
        }
        let mut x: usize = 0;
        for k in 0..blk.param_len as u32 {
            let pv = VPARAM | blk.param_start + k;
            let w = self.word(f, b, pv);
            for j in 0..value_words(b.params[(blk.param_start + k) as usize], ptr) {
                self.vals[(w + j) as usize] = self.tmp[x];
                x += 1;
            }
        }
        self.frames.index_mut(self.frames.len() - 1).pc = blk.start;
        return true;
    }

    // A 128-bit integer operation: each value is two words, the low one first.
    fn int128(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let op = t.op;
        let wa = self.word(f, b, t.a);
        let xl = self.vals[wa as usize];
        let xh = self.vals[wa as usize + 1];
        let mut yl: u64 = 0;
        let mut yh: u64 = 0;
        if op != O_NEG && op != O_NOT {
            let wb = self.word(f, b, t.b);
            yl = self.vals[wb as usize];
            yh = self.vals[wb as usize + 1];
        }
        let (trap, rl, rh) = int128_fold(op, xl, xh, yl, yh);
        if trap == FOLD_DIV_ZERO {
            return self.stop(iri::IT_TRAP_UB_DIV_ZERO, "division by zero");
        }
        if trap == FOLD_OVERFLOW {
            return self.stop(iri::IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
        }
        if trap == FOLD_SHIFT {
            return self.stop(iri::IT_TRAP_UB_SHIFT, "shift out of range");
        }
        self.vals[dst as usize] = rl;
        self.vals[dst as usize + 1] = rh;
        return true;
    }

    fn int_op(self: &mut Self, op: u8, ty: u8, x: u64, y: u64, dst: u32) bool {
        let mut r: u64 = 0;
        let trap = int_fold(op, ty, (unsafe &*self.pkg).ptr_bytes, x, y, &mut r);
        if trap == FOLD_DIV_ZERO {
            return self.stop(iri::IT_TRAP_UB_DIV_ZERO, "division by zero");
        }
        if trap == FOLD_OVERFLOW {
            return self.stop(iri::IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
        }
        if trap == FOLD_SHIFT {
            return self.stop(iri::IT_TRAP_UB_SHIFT, "shift out of range");
        }
        self.vals[dst as usize] = r;
        return true;
    }

    fn convert(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let from = b.type_of(t.a);
        if is_vec(from) && t.op != O_BITCAST {
            return self.vec_convert(f, b, t, dst);
        }
        if t.op == O_BITCAST {
            let w = self.word(f, b, t.a);
            for k in 0..value_words(t.ty, ptr) {
                self.vals[(dst + k) as usize] = self.vals[(w + k) as usize];
            }
            return true;
        }
        let x = self.val(f, b, t.a);
        if t.ty == T_I128 && (t.op == O_SEXT || t.op == O_ZEXT) {
            // The low word extended to 64 bits, the high word its sign or 0.
            let fb = type_bits(from, ptr);
            let lo = if t.op == O_SEXT {
                sign_ext(x, fb) as u64
            } else {
                trunc_bits(x, fb)
            };
            self.vals[dst as usize] = lo;
            self.vals[dst as usize + 1] = pick_u64(t.op == O_SEXT && lo >> 63 != 0, 0xFFFFFFFFFFFFFFFF, 0);
            return true;
        }
        if from == T_I128 && t.op == O_TRUNC {
            self.vals[dst as usize] = trunc_bits(x, type_bits(t.ty, ptr));
            return true;
        }
        if from == T_I128 || t.ty == T_I128 {
            return self.stop(EV_ERROR, "an i128 float conversion is not evaluated");
        }
        let mut r: u64 = 0;
        if !scalar_convert(t.op, t.aux, from, t.ty, ptr, x, &mut r) {
            return self.stop(iri::IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
        }
        self.vals[dst as usize] = r;
        return true;
    }

    // ---- Memory ----

    // The object and offset of pointer `p` for an access of `n` bytes, or an error stop.
    fn locate(self: &mut Self, p: u64, n: u64, out_base: &mut u64, heap: &mut bool) bool {
        let o = (p >> 32) as u32;
        let off = p & 0xFFFFFFFF;
        if o == 0 {
            return self.stop(iri::IT_TRAP_UB_NULL_DEREF, "null dereference");
        }
        if o as usize >= self.objs.len() {
            return self.stop(iri::IT_TRAP_UB_OOB, "out-of-bounds access");
        }
        let ob = self.objs[o as usize];
        if ob.kind == OB_DATA && !ob.live {
            return self.stop(iri::IT_TRAP_UB_OOB, "out-of-bounds access");
        }
        if !ob.live {
            return self.stop(
                iri::IT_TRAP_UB_USE_AFTER_FREE,
                pick_str(ob.kind == OB_STACK, "use after return", "use after free"),
            );
        }
        if off + n > ob.size {
            return self.stop(iri::IT_TRAP_UB_OOB, "out-of-bounds access");
        }
        *out_base = ob.base + off;
        *heap = ob.kind != OB_STACK;
        return true;
    }

    // Read a value of type `ty` at `p` into the words from `dst`.
    fn load(self: &mut Self, p: u64, ty: u8, dst: u32) bool {
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let n = type_bytes(ty, ptr) as u64;
        let mut base: u64 = 0;
        let mut heap = false;
        if !self.locate(p, n, &mut base, &mut heap) {
            return false;
        }
        let nw = value_words(ty, ptr);
        for k in 0..nw {
            let mut w: u64 = 0;
            let lo = k as u64 * 8;
            let hi = pick_u64(lo + 8 < n, lo + 8, n);
            let mut j = hi;
            while j > lo {
                j -= 1;
                let byte = if heap {
                    self.heap[(base + j) as usize]
                } else {
                    self.stack[(base + j) as usize]
                };
                w = w << 8 | byte as u64;
            }
            self.vals[(dst + k) as usize] = w;
        }
        return true;
    }

    // Write the value of type `ty` in the words from `src` at `p`.
    fn store(self: &mut Self, p: u64, ty: u8, src: u32) bool {
        let nw = value_words(ty, (unsafe &*self.pkg).ptr_bytes);
        self.tmp.truncate(0);
        for k in 0..nw {
            self.tmp.push(self.vals[(src + k) as usize]);
        }
        return self.store_words(p, ty);
    }

    // Write the value of type `ty` in `tmp` at `p`.
    fn store_words(self: &mut Self, p: u64, ty: u8) bool {
        let n = type_bytes(ty, (unsafe &*self.pkg).ptr_bytes) as u64;
        let mut base: u64 = 0;
        let mut heap = false;
        if !self.locate(p, n, &mut base, &mut heap) {
            return false;
        }
        for j in 0..n {
            let byte = (self.tmp[(j / 8) as usize] >> j % 8 * 8) as u8;
            if heap {
                self.heap[(base + j) as usize] = byte;
            } else {
                self.stack[(base + j) as usize] = byte;
            }
        }
        return true;
    }

    fn byte_at(self: &mut Self, p: u64, out: &mut u8) bool {
        let mut base: u64 = 0;
        let mut heap = false;
        if !self.locate(p, 1, &mut base, &mut heap) {
            return false;
        }
        *out = if heap {
            self.heap[base as usize]
        } else {
            self.stack[base as usize]
        };
        return true;
    }

    // Copy `n` bytes from `src` to `dst`; the regions may overlap (memmove), and a zero count touches
    // nothing.
    fn copy_bytes(self: &mut Self, dst: u64, src: u64, n: u64) bool {
        if n == 0 {
            return true;
        }
        let mut sb: u64 = 0;
        let mut sh = false;
        let mut db: u64 = 0;
        let mut dh = false;
        if !self.locate(src, n, &mut sb, &mut sh) || !self.locate(dst, n, &mut db, &mut dh) {
            return false;
        }
        // Within one arena, copy away from the overlap: forward when the destination is below the source.
        let back = sh == dh && db > sb;
        for k in 0..n {
            let j = if back {
                n - 1 - k
            } else {
                k
            };
            let c = if sh {
                self.heap[(sb + j) as usize]
            } else {
                self.stack[(sb + j) as usize]
            };
            if dh {
                self.heap[(db + j) as usize] = c;
            } else {
                self.stack[(db + j) as usize] = c;
            }
        }
        return true;
    }

    fn set_bytes(self: &mut Self, dst: u64, v: u8, n: u64) bool {
        if n == 0 {
            return true;
        }
        let mut db: u64 = 0;
        let mut dh = false;
        if !self.locate(dst, n, &mut db, &mut dh) {
            return false;
        }
        for j in 0..n {
            if dh {
                self.heap[(db + j) as usize] = v;
            } else {
                self.stack[(db + j) as usize] = v;
            }
        }
        return true;
    }

    // A new heap object of `n` bytes, zeroed; its pointer, 0 past the memory budget.
    fn heap_new(self: &mut Self, n: u64, kind: u8, sym: u32) u64 {
        if self.stack.len() as u64 + self.heap.len() as u64 + n > self.max_bytes || n > 0xFFFFFFFF {
            let _ = self.stop(iri::IT_TRAP_BUDGET_MEMORY, "memory budget exceeded");
            return 0;
        }
        let base = self.heap.len() as u64 + 15 & ~15u64;
        self.heap.resize_default((base + n) as usize);
        self.objs.push(Obj { base: base, size: n, kind: kind, live: true, sym: sym });
        return (self.objs.len() - 1) as u64 << 32;
    }

    // The object of symbol `s`, made on first use: a function's (no bytes), or a data symbol's with its
    // initial bytes and relocations; 0 after an error stop (an extern data symbol).
    fn sym_object(self: &mut Self, s: u32) u32 {
        if self.sym_obj[s as usize] != 0 {
            return self.sym_obj[s as usize];
        }
        let sy = (unsafe &*self.pkg).syms[s as usize];
        if sy.kind == SK_FUNC {
            self.objs.push(Obj { base: 0, size: 0, kind: OB_FUNC, live: true, sym: s });
            self.sym_obj[s as usize] = self.objs.len() as u32 - 1;
            return self.sym_obj[s as usize];
        }
        if sy.def == NONE {
            let _ = self.stop(EV_FFI, (unsafe &*self.pkg).spell(sy.name));
            return 0;
        }
        let d = (unsafe &*self.pkg).data[sy.def as usize];
        let p = self.heap_new(d.size, OB_DATA, s);
        if p == 0 {
            return 0;
        }
        let o = (p >> 32) as u32;
        self.sym_obj[s as usize] = o;
        let base = self.objs[o as usize].base;
        for j in 0..d.nbytes {
            self.heap[(base + j as u64) as usize] = (unsafe &*self.pkg).bytes[(d.bytes + j) as usize];
        }
        for k in 0..d.nrelocs {
            let r = (unsafe &*self.pkg).relocs[(d.relocs + k) as usize];
            let to = self.sym_object(r.sym);
            if to == 0 {
                return 0;
            }
            self.tmp.truncate(0);
            self.tmp.push((to as u64 << 32).wrapping_add(r.addend as u64));
            if !self.store_words(p + r.offset as u64, T_PTR) {
                return 0;
            }
        }
        if d.readonly {
            // Read-only data stays readable; a store through it is a constant's mutation, which the
            // lowering never emits.
        }
        return o;
    }

    // ---- Calls ----

    fn call(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let mut s: u32 = NONE;
        if t.op == O_CALL {
            s = b.syms[t.a as usize];
        } else {
            let pv = self.val(f, b, t.a);
            let o = (pv >> 32) as u32;
            if o == 0 || o as usize >= self.objs.len() || self.objs[o as usize].kind != OB_FUNC || (pv & 0xFFFFFFFF) != 0 {
                return self.stop(iri::IT_TRAP_UB_NULL_DEREF, "a call through a pointer to no function");
            }
            s = self.objs[o as usize].sym;
        }
        self.tmp.truncate(0);
        for k in 0..t.aux as u32 {
            let v = b.pool[(t.c + k) as usize];
            let w = self.word(f, b, v);
            for j in 0..value_words(b.type_of(v), ptr) {
                self.tmp.push(self.vals[(w + j) as usize]);
            }
        }
        // A routine the interpreter models runs as modeled, even where the package defines it (the
        // runtime's allocator and traps are Super-C).
        let sy = (unsafe &*self.pkg).syms[s as usize];
        let ic = self.icode[s as usize];
        if ic != IC_NONE {
            return self.intercept(ic, (unsafe &*self.pkg).spell(sy.name), t.ty, dst);
        }
        if sy.def != NONE && sy.kind == SK_FUNC {
            return self.enter(sy.def, dst, t.ty, 0);
        }
        return self.stop(EV_FFI, (unsafe &*self.pkg).spell(sy.name));
    }

    // The routines the interpreter models (`icode_of`): the C heap and memory routines, the traps, the
    // runtime's arithmetic and bit-count primitives, and libm.
    // Value word `dst` (NONE: an unused result) takes `v`.
    const fn put(self: &mut Self, dst: u32, v: u64) {
        if dst != NONE {
            self.vals[dst as usize] = v;
        }
    }

    fn intercept(self: &mut Self, ic: u8, name: str, rt: u8, dst: u32) bool {
        // Every modeled routine takes at most four words.
        let n = self.tmp.len();
        let mut args: [u64; 4] = [0, 0, 0, 0];
        for k in 0..pick_usize(n < 4, n, 4) {
            unsafe args[k] = self.tmp[k];
        }
        if ic == IC_MALLOC || ic == IC_ALIGNED {
            if ic == IC_MALLOC {
                self.count_alloc(args[0]);
            }
            let p = self.heap_new(args[0], OB_HEAP, NONE);
            self.put(dst, p);
            return p != 0;
        }
        if ic == IC_CALLOC {
            self.count_alloc(args[0].wrapping_mul(args[1]));
            let p = self.heap_new(args[0].wrapping_mul(args[1]), OB_HEAP, NONE);
            self.put(dst, p);
            return p != 0;
        }
        if ic == IC_ACCT_ON {
            self.acct_on = args[0] as u32 != 0;
            return true;
        }
        if ic == IC_ACCT_ENABLED {
            self.put(dst, pick_u64(self.acct_on, 1, 0));
            return true;
        }
        if ic == IC_ACCT_SNAPSHOT {
            // calls, bytes, one thread, no shared line.
            let words: [u64; 4] = [self.acct_calls, self.acct_bytes, 1, 0];
            for k in 0..4u64 {
                self.vals.push(unsafe words[k as usize]);
                let w = self.vals.len() as u32 - 1;
                if !self.store(args[0] + k * 8, T_I64, w) {
                    return false;
                }
                self.vals.truncate(w as usize);
            }
            return true;
        }
        if ic == IC_REALLOC {
            self.count_alloc(args[1]);
            let old = args[0];
            let np = self.heap_new(args[1], OB_HEAP, NONE);
            if np == 0 {
                return false;
            }
            if old != 0 {
                let o = (old >> 32) as u32;
                if o as usize >= self.objs.len() || self.objs[o as usize].kind != OB_HEAP || (old & 0xFFFFFFFF) != 0 {
                    return self.stop(iri::IT_TRAP_UB_OOB, "realloc of no heap block");
                }
                if !self.objs[o as usize].live {
                    return self.stop(iri::IT_TRAP_UB_USE_AFTER_FREE, "use after free");
                }
                let keep = pick_u64(self.objs[o as usize].size < args[1], self.objs[o as usize].size, args[1]);
                if !self.copy_bytes(np, old, keep) {
                    return false;
                }
                self.objs.index_mut(o as usize).live = false;
            }
            self.put(dst, np);
            return true;
        }
        if ic == IC_FREE {
            let p = args[0];
            if p == 0 {
                return true;
            }
            let o = (p >> 32) as u32;
            if o as usize >= self.objs.len() || self.objs[o as usize].kind != OB_HEAP || (p & 0xFFFFFFFF) != 0 {
                return self.stop(iri::IT_TRAP_UB_OOB, "free of no heap block");
            }
            if !self.objs[o as usize].live {
                return self.stop(iri::IT_TRAP_UB_DOUBLE_FREE, "double free");
            }
            self.objs.index_mut(o as usize).live = false;
            return true;
        }
        if ic == IC_MEMCPY {
            self.put(dst, args[0]);
            return self.copy_bytes(args[0], args[1], args[2]);
        }
        if ic == IC_MEMSET {
            self.put(dst, args[0]);
            return self.set_bytes(args[0], args[1] as u8, args[2]);
        }
        if ic == IC_MEMCMP {
            let mut r: i32 = 0;
            for j in 0..args[2] {
                let mut x: u8 = 0;
                let mut y: u8 = 0;
                if !self.byte_at(args[0] + j, &mut x) || !self.byte_at(args[1] + j, &mut y) {
                    return false;
                }
                if x != y {
                    r = pick_i32(x < y, -1, 1);
                    break;
                }
            }
            self.put(dst, r as u32);
            return true;
        }
        if ic == IC_STRLEN {
            let mut m = String::new();
            if !self.cstring(args[0], &mut m) {
                return false;
            }
            self.put(dst, m.len() as u64);
            return true;
        }
        if ic == IC_STRCMP {
            let mut x = String::new();
            let mut y = String::new();
            if !self.cstring(args[0], &mut x) || !self.cstring(args[1], &mut y) {
                return false;
            }
            let r: i32 = if x.as_str() < y.as_str() {
                -1
            } else if x.as_str() == y.as_str() {
                0
            } else {
                1
            };
            self.put(dst, r as u32);
            return true;
        }
        if ic == IC_ABORT {
            return self.stop(iri::IT_TRAP_PANIC, "abort reached at compile time");
        }
        if ic == IC_PANIC {
            let mut m = String::new();
            if !self.cstring(args[0], &mut m) {
                return false;
            }
            return self.stop(iri::IT_TRAP_PANIC, &m);
        }
        if ic == IC_PANIC_STR {
            let mut m = String::new();
            for j in 0..args[1] {
                let mut c: u8 = 0;
                if !self.byte_at(args[0] + j, &mut c) {
                    return false;
                }
                m.push_byte(c);
            }
            return self.stop(iri::IT_TRAP_PANIC, &m);
        }
        if ic == IC_ASSERT {
            return self.stop(iri::IT_TRAP_PANIC, "assertion failed");
        }
        if ic == IC_TRAP_ORDER {
            return self.stop(iri::IT_TRAP_PANIC, "invalid memory order");
        }
        if ic == IC_INDEX_BOUNDS {
            let m = format("index out of bounds: the index is {} but the length is {}", args[0], args[1]);
            return self.stop(iri::IT_TRAP_UB_OOB, &m);
        }
        if ic == IC_VEC_BOUNDS {
            let m = format("index out of bounds: {} lanes from {} but the length is {}", args[0], args[1], args[2]);
            return self.stop(iri::IT_TRAP_UB_OOB, &m);
        }
        if ic == IC_LANE_BOUNDS {
            let mut m = format("lane {}: index out of bounds: the index is {}", args[0], args[1]);
            if (args[3] & 1) != 0 {
                m.format_into(" + {}", args[0]);
            }
            m.format_into(" but the length is {}", args[2]);
            return self.stop(iri::IT_TRAP_UB_OOB, &m);
        }
        if ic == IC_LANE_PANIC {
            let mut t = String::new();
            if !self.cstring(args[1], &mut t) {
                return false;
            }
            let m = format("lane {}: {}", args[0], t.as_str());
            return self.stop(iri::IT_TRAP_PANIC, &m);
        }
        if ic == IC_ZST_DIFF {
            return self.stop(iri::IT_TRAP_PANIC, "pointer distance on a zero-sized element type");
        }
        if ic == IC_OVERFLOW {
            return self.stop(iri::IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
        }
        if ic == IC_DIV_ZERO {
            return self.stop(iri::IT_TRAP_UB_DIV_ZERO, "division by zero");
        }
        if ic == IC_ZERO {
            self.put(dst, 0);
            return true;
        }
        if ic == IC_PREEMPT {
            self.put(dst, 2048);
            return true;
        }
        if ic == IC_WRAP {
            let x = args[0];
            let y = args[1];
            let rv = if name == "sc_mulo_u64" {
                ov64(O_MULO, false, x, y) as u64
            } else if name == "sc_mulo_i64" {
                ov64(O_MULO, true, x, y) as u64
            } else if name == "sc_wadd64" {
                x.wrapping_add(y)
            } else if name == "sc_wsub64" {
                x.wrapping_sub(y)
            } else if name == "sc_wmul64" {
                x.wrapping_mul(y)
            } else if name == "sc_wshl64" {
                x.wrapping_shl(y as u32)
            } else if name == "sc_wshr64" {
                x.wrapping_shr(y as u32)
            } else {
                (x as i64).wrapping_shr(y as u32) as u64
            };
            self.put(dst, rv);
            return true;
        }
        if ic == IC_BITS {
            let x = args[0];
            let rv = if name == "sc_ctz64" {
                x.trailing_zeros()
            } else if name == "sc_clz64" {
                x.leading_zeros()
            } else {
                x.count_ones()
            } as u64;
            self.put(dst, rv);
            return true;
        }
        // libm: a trailing `f` selects the f32 function.
        let f32suf = name.len() > 1 && name.ends_with("f") && rt == T_F32;
        let base = if f32suf {
            name.slice(0, name.len() - 1)
        } else {
            name
        };
        if (rt == T_F32 || rt == T_F64) && n >= 1 && n <= 3 {
            let mut x: [f64; 3] = [0.0, 0.0, 0.0];
            for k in 0..n {
                unsafe x[k] = if f32suf {
                    fl::f32_from_bits((unsafe args[k]) as u32)
                } else {
                    fl::f64_from_bits(unsafe args[k])
                };
            }
            let mut r = iri::DblRes { ok: false, v: 0.0 };
            if n == 1 {
                r = if f32suf {
                    iri::libm1f(base, x[0] as f32)
                } else {
                    iri::libm1(base, x[0])
                };
            } else if n == 2 {
                r = if f32suf {
                    iri::libm2f(base, x[0] as f32, x[1] as f32)
                } else {
                    iri::libm2(base, x[0], x[1])
                };
            } else if base == "fma" {
                r = iri::DblRes {
                    ok: true,
                    v: if f32suf {
                        math::fmaf(x[0] as f32, x[1] as f32, x[2] as f32)
                    } else {
                        math::fma(x[0], x[1], x[2])
                    },
                };
            }
            if r.ok {
                let rv = if f32suf {
                    fl::f32_bits(r.v as f32) as u64
                } else {
                    fl::f64_bits(r.v)
                };
                self.put(dst, rv);
                return true;
            }
        }
        return self.stop(EV_FFI, name);
    }

    // The NUL-terminated string at `p` into `out`.
    fn cstring(self: &mut Self, p: u64, out: &mut String) bool {
        // An offset has 32 bits, so a string ends, or leaves its object, within 2^32 bytes.
        for k in 0..0x100000000u64 {
            let mut c: u8 = 0;
            if !self.byte_at(p + k, &mut c) {
                return false;
            }
            if c == 0 {
                return true;
            }
            out.push_byte(c);
        }
        return self.stop(iri::IT_TRAP_UB_OOB, "out-of-bounds access");
    }

    // ---- Vectors ----

    fn vec_int(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let lb = type_bits(lt, ptr);
        let wa = self.word(f, b, t.a);
        let wb = if t.b != VNONE && t.op != O_NEG && t.op != O_NOT {
            self.word(f, b, t.b)
        } else {
            NONE
        };
        let w0 = self.vals.len() as u32;
        self.vals.push(0);
        for k in 0..n {
            let x = get_lane(&self.vals, wa, k, lb);
            let y = if wb != NONE {
                get_lane(&self.vals, wb, k, lb)
            } else {
                0
            };
            if !self.int_op(t.op, lt, x, y, w0) {
                return false;
            }
            let r = self.vals[w0 as usize];
            set_lane(&mut self.vals, dst, k, lb, r);
        }
        self.vals.truncate(w0 as usize);
        return true;
    }

    fn vec_float(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let lt = lane_type(t.ty);
        let n = lanes(t.ty);
        let lb = type_bits(lt, 8);
        let wa = self.word(f, b, t.a);
        let wb = if t.op != O_FNEG && t.op != O_FSQRT {
            self.word(f, b, t.b)
        } else {
            NONE
        };
        for k in 0..n {
            let x = get_lane(&self.vals, wa, k, lb);
            let y = if wb != NONE {
                get_lane(&self.vals, wb, k, lb)
            } else {
                0
            };
            set_lane(&mut self.vals, dst, k, lb, float_op(t.op, lt, x, y));
        }
        return true;
    }

    fn vec_convert(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let from = b.type_of(t.a);
        let fl = lane_type(from);
        let tl = lane_type(t.ty);
        let n = lanes(from);
        let wa = self.word(f, b, t.a);
        let fb = type_bits(fl, 8);
        let tb = type_bits(tl, 8);
        for k in 0..n {
            let mut r: u64 = 0;
            if !scalar_convert(t.op, t.aux, fl, tl, 8, get_lane(&self.vals, wa, k, fb), &mut r) {
                return self.stop(iri::IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
            }
            set_lane(&mut self.vals, dst, k, tb, r);
        }
        return true;
    }

    // ---- Vector operations ----

    // A `vop`: the portable vector operation of its code over its operands' lanes, as the CTFE
    // interpreter's lane rules define it; a lane that traps traps at the lowest lane.
    fn vop(self: &mut Self, f: &Frame, b: &Body, t: Inst, dst: u32) bool {
        let code = (t.aux & VOP_CODE) as u32;
        let sg = (t.aux & VOP_SIGNED) != 0;
        let dsg = (t.aux & VOP_DSIGNED) != 0;
        let mut w: [u32; 4] = [0, 0, 0, 0];
        let mut ty: [u8; 4] = [T_NONE, T_NONE, T_NONE, T_NONE];
        for k in 0..pick_u32(t.b < 4, t.b, 4) {
            let v = b.pool[(t.a + k) as usize];
            unsafe w[k as usize] = self.word(f, b, v);
            unsafe ty[k as usize] = b.type_of(v);
        }
        if code == core::OP_CAST {
            return self.vcast(t, w[0], ty[0], dst);
        }
        if code == core::OP_REM && is_vec(ty[0]) && is_float(lane_type(ty[0])) {
            let lt = lane_type(ty[0]);
            let lb = type_bits(lt, 8);
            for i in 0..lanes(ty[0]) {
                let x = to_f64(lt, get_lane(&self.vals, w[0], i, lb));
                let y = to_f64(lt, get_lane(&self.vals, w[1], i, lb));
                let r = if lt == T_F32 {
                    iri::libm2f("fmodf", x as f32, y as f32).v
                } else {
                    iri::libm2("fmod", x, y).v
                };
                set_lane(&mut self.vals, dst, i, lb, from_f64(lt, r));
            }
            return true;
        }
        if (code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR) && is_vec(ty[0]) {
            let lt = lane_type(ty[0]);
            let lb = type_bits(lt, 8);
            let k = self.vals[w[1] as usize] & lb as u64 - 1;
            for i in 0..lanes(ty[0]) {
                let x = get_lane(&self.vals, w[0], i, lb);
                let r = if code == core::OP_SHL_SCALAR {
                    x << k
                } else if sg {
                    (sign_ext(x, lb) >> k as i64) as u64
                } else {
                    x >> k
                };
                set_lane(&mut self.vals, dst, i, lb, r);
            }
            return true;
        }
        if code < core::OP_SIMD || code >= core::OP_CMP_LANES {
            return self.stop(EV_ERROR, "a vector operation the lowering does not make");
        }
        let c = (code - core::OP_SIMD) as u8;
        let rule = core::simd_op(c).rule;
        if rule == core::SR_LOAD || rule == core::SR_STORE {
            return self.vmem(t, c, &w, &ty, dst);
        }
        if rule == core::SR_MLOAD || rule == core::SR_MSTORE {
            return self.vmem_masked(t, c, &w, &ty, dst);
        }
        if rule == core::SR_REDUCE || rule == core::SR_DOT {
            return self.vreduce(t, c, sg, &w, &ty, dst);
        }
        if rule == core::SR_INDEX || rule == core::SR_RT_INDEX || rule == core::SR_MASKED {
            return self.vrearrange(b, t, c, &w, &ty, dst);
        }
        return self.vlanes(t, c, sg, dsg, &w, &ty, dst);
    }

    // A conversion of each lane of the vector at word `w` (type `from`) to the result's lane type.
    fn vcast(self: &mut Self, t: Inst, w: u32, from: u8, dst: u32) bool {
        let fl = lane_type(from);
        let tl = lane_type(t.ty);
        let fs = (t.aux & VOP_SIGNED) != 0;
        let ts = (t.aux & VOP_DSIGNED) != 0;
        let unchecked = (t.aux & VOP_UNCHECKED) != 0;
        let fb = type_bits(fl, 8);
        let tb = type_bits(tl, 8);
        let op = if is_float(fl) && is_float(tl) {
            pick_u8(fb < tb, O_FPEXT, pick_u8(fb > tb, O_FPTRUNC, O_ZEXT))
        } else if is_float(fl) {
            pick_u8(ts, O_FPTOSI, O_FPTOUI)
        } else if is_float(tl) {
            pick_u8(fs, O_SITOFP, O_UITOFP)
        } else if fb < tb && fs {
            O_SEXT
        } else {
            O_ZEXT
        };
        for i in 0..lanes(from) {
            let mut r: u64 = 0;
            if !scalar_convert(
                op,
                pick_u16(unchecked, CV_UNCHECKED, 0),
                fl,
                tl,
                8,
                get_lane(&self.vals, w, i, fb),
                &mut r,
            ) {
                return self.stop(iri::IT_TRAP_UB_OVERFLOW, "arithmetic overflow");
            }
            set_lane(&mut self.vals, dst, i, tb, r);
        }
        return true;
    }
}

/// The text of an outcome for a report: its kind, message and location.
pub(package) fn outcome_text(p: &Package, o: &Outcome, out: &mut String) {
    out.format_into("kind {} \"{}\"", o.kind, o.msg.as_str());
    if o.loc.line != 0 {
        out.format_into(" at {}:{}:{}", p.spell(p.files[o.loc.file as usize]), o.loc.line, o.loc.col);
    }
}

// The words a value of type `t` takes.
/// `int_fold`'s outcomes: the result, or the trap the operation raises.
pub(package) const FOLD_OK: u8 = 0;
pub(package) const FOLD_DIV_ZERO: u8 = 1;
pub(package) const FOLD_OVERFLOW: u8 = 2;
pub(package) const FOLD_SHIFT: u8 = 3;

/// Integer operation `op` (`O_ADD` to `O_NOT`; `O_NEG` and `O_NOT` read `x` alone) of a scalar integer
/// or pointer type `ty` on `x` and `y` into `out`, truncated to the type: the evaluator's arithmetic,
/// which the optimizer folds with. FOLD_OK, or the trap it raises (and `out` unchanged).
pub(package) const fn int_fold(op: u8, ty: u8, ptr: u32, x: u64, y: u64, out: &mut u64) u8 {
    let bits = type_bits(ty, ptr);
    let sx = sign_ext(x, bits);
    let sy = sign_ext(y, bits);
    let mut r: u64 = 0;
    if op == O_ADD {
        r = x.wrapping_add(y);
    } else if op == O_SUB {
        r = x.wrapping_sub(y);
    } else if op == O_MUL {
        r = x.wrapping_mul(y);
    } else if op == O_SDIV || op == O_SREM {
        if sy == 0 {
            return FOLD_DIV_ZERO;
        }
        if sy == -1 && sx == sign_ext(1u64 << (bits - 1) as u64, bits) {
            return FOLD_OVERFLOW;
        }
        r = if op == O_SDIV {
            (sx / sy) as u64
        } else {
            (sx % sy) as u64
        };
    } else if op == O_UDIV || op == O_UREM {
        if y == 0 {
            return FOLD_DIV_ZERO;
        }
        r = if op == O_UDIV {
            x / y
        } else {
            x % y
        };
    } else if op == O_AND {
        r = x & y;
    } else if op == O_OR {
        r = x | y;
    } else if op == O_XOR {
        r = x ^ y;
    } else if op == O_SHL || op == O_LSHR || op == O_ASHR {
        if y >= bits as u64 {
            return FOLD_SHIFT;
        }
        if op == O_SHL {
            r = x << y;
        } else if op == O_LSHR {
            r = x >> y;
        } else {
            r = (sx >> y as i64) as u64;
        }
    } else if op == O_NEG {
        r = 0u64.wrapping_sub(x);
    } else {
        r = ~x;
    }
    *out = trunc_bits(r, bits);
    return FOLD_OK;
}

const fn value_words(t: u8, ptr: u32) u32 {
    if t == T_NONE {
        return 0;
    }
    return (type_bytes(t, ptr) + 7) / 8;
}

const fn pick_u32(c: bool, a: u32, b: u32) u32 {
    return ast::pick(c, a, b);
}

const fn pick_u64(c: bool, a: u64, b: u64) u64 {
    return ast::pick(c, a, b);
}

const fn pick_i32(c: bool, a: i32, b: i32) i32 {
    return ast::pick(c, a, b);
}

const fn pick_str(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    return ast::pick(c, a, b);
}

// `x` truncated to its low `bits` bits.
/// The f32 encoding of IEEE binary16 encoding `h`: exact; a NaN quiet, its payload's bits on top (as
/// FCVT and VCVTPH2PS give it).
pub(package) const fn half_to_f32_bits(h: u32) u32 {
    let s = (h & 0x8000) << 16;
    let e = h >> 10 & 0x1F;
    let m = h & 0x3FF;
    if e == 0x1F {
        return s | 0x7F800000 | m << 13 | ast::pick(m != 0, 0x400000u32, 0u32);
    }
    if e != 0 {
        return s | e + 112 << 23 | m << 13;
    }
    if m == 0 {
        return s;
    }
    // A subnormal, normalized: each step moves the significand's top bit up one, at most 10 steps.
    let mut k: u32 = 0;
    let mut n = m;
    while (n & 0x400) == 0 {
        n <<= 1;
        k += 1;
    }
    return s | 113 - k << 23 | (n & 0x3FF) << 13;
}

/// The IEEE binary16 encoding of f32 encoding `x`, rounded to nearest, ties to even; a NaN quiet, the top
/// bits of its payload kept (as FCVT and VCVTPS2PH give it).
pub(package) const fn f32_bits_to_half(x: u32) u32 {
    let s = x >> 16 & 0x8000;
    let e = (x >> 23 & 0xFF) as i32;
    let m = x & 0x7FFFFF;
    if e == 0xFF {
        return s | ast::pick(m != 0, 0x7E00 | m >> 13 & 0x1FF, 0x7C00u32);
    }
    // An f32 below 2^-126 lies far below half the smallest binary16 step (2^-25): zero.
    if e == 0 {
        return s;
    }
    let sig = m | 0x800000;
    // The binary16 exponent field; at 0 or below, the result is subnormal and keeps fewer bits.
    let he = e - 127 + 15;
    let sh = if he >= 1 {
        13i32
    } else {
        14 - he
    };
    if sh > 24 {
        return s;
    }
    let mut r = sig >> sh as u32;
    let rem = sig & (1u32 << sh as u32) - 1;
    let half = 1u32 << (sh - 1) as u32;
    if rem > half || rem == half && (r & 1) != 0 {
        r += 1;
    }
    if he < 1 {
        // A subnormal that rounds up to 0x400 is the smallest normal: its field bits say so.
        return s | r;
    }
    // A significand that rounds up to 2^11 moves the exponent up one.
    let mut ef = he as u32;
    if r == 0x800 {
        r = 0x400;
        ef += 1;
    }
    if ef >= 0x1F {
        return s | 0x7C00;
    }
    return s | ef << 10 | r & 0x3FF;
}

pub(package) const fn trunc_bits(x: u64, bits: u32) u64 {
    if bits >= 64 {
        return x;
    }
    return x & (1u64 << bits as u64) - 1;
}

// The 128-bit product of `x` and `y`: its low and high words.
/// Integer operation `op` (`O_ADD` to `O_NOT`) on 128-bit `x` and `y` (low and high words; `O_NEG` and
/// `O_NOT` read `x` alone): FOLD_OK and the result's words, or the trap it raises. The evaluator's
/// arithmetic, which the optimizer folds with.
pub(package) const fn int128_fold(op: u8, xl: u64, xh: u64, yl: u64, yh: u64) (u8, u64, u64) {
    let mut rl: u64 = 0;
    let mut rh: u64 = 0;
    if op == O_ADD {
        rl = xl.wrapping_add(yl);
        rh = xh.wrapping_add(yh).wrapping_add((rl < xl) as u64);
    } else if op == O_SUB {
        rl = xl.wrapping_sub(yl);
        rh = xh.wrapping_sub(yh).wrapping_sub((xl < yl) as u64);
    } else if op == O_MUL {
        let (pl, ph) = mul64(xl, yl);
        rl = pl;
        rh = ph.wrapping_add(xl.wrapping_mul(yh)).wrapping_add(xh.wrapping_mul(yl));
    } else if op >= O_SDIV && op <= O_UREM {
        if yl == 0 && yh == 0 {
            return (FOLD_DIV_ZERO, 0, 0);
        }
        let signed = op == O_SDIV || op == O_SREM;
        let xn = signed && xh >> 63 != 0;
        let yn = signed && yh >> 63 != 0;
        if signed && xh == 0x8000000000000000 && xl == 0 && yl == 0xFFFFFFFFFFFFFFFF && yh == 0xFFFFFFFFFFFFFFFF {
            return (FOLD_OVERFLOW, 0, 0);
        }
        // Magnitudes divided; the quotient negative when the signs differ, the remainder with the dividend's.
        let (al, ah) = neg_if(xn, xl, xh);
        let (bl, bh) = neg_if(yn, yl, yh);
        let (ql, qh, ml, mh) = divmod128(al, ah, bl, bh);
        if op == O_SDIV || op == O_UDIV {
            let (u, v) = neg_if(xn != yn, ql, qh);
            rl = u;
            rh = v;
        } else {
            let (u, v) = neg_if(xn, ml, mh);
            rl = u;
            rh = v;
        }
    } else if op == O_AND {
        rl = xl & yl;
        rh = xh & yh;
    } else if op == O_OR {
        rl = xl | yl;
        rh = xh | yh;
    } else if op == O_XOR {
        rl = xl ^ yl;
        rh = xh ^ yh;
    } else if op == O_SHL || op == O_LSHR || op == O_ASHR {
        if yh != 0 || yl >= 128 {
            return (FOLD_SHIFT, 0, 0);
        }
        let (u, v) = shift128(op, xl, xh, yl as u32);
        rl = u;
        rh = v;
    } else if op == O_NEG {
        let (u, v) = neg_if(true, xl, xh);
        rl = u;
        rh = v;
    } else {
        rl = ~xl;
        rh = ~xh;
    }
    return (FOLD_OK, rl, rh);
}

const fn mul64(x: u64, y: u64) (u64, u64) {
    let (x0, x1) = (x & 0xFFFFFFFF, x >> 32);
    let (y0, y1) = (y & 0xFFFFFFFF, y >> 32);
    let p00 = x0 * y0;
    let p01 = x0 * y1;
    let p10 = x1 * y0;
    let mid = (p00 >> 32) + (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF);
    return (mid << 32 | p00 & 0xFFFFFFFF, x1 * y1 + (p01 >> 32) + (p10 >> 32) + (mid >> 32));
}

// The 128-bit value `(l, h)`, negated when `neg`.
const fn neg_if(neg: bool, l: u64, h: u64) (u64, u64) {
    if !neg {
        return (l, h);
    }
    return (0u64.wrapping_sub(l), (~h).wrapping_add((l == 0) as u64));
}

// `(l, h)` shifted by `n` (below 128) by shift operation `op`.
const fn shift128(op: u8, l: u64, h: u64, n: u32) (u64, u64) {
    if n == 0 {
        return (l, h);
    }
    let fill = pick_u64(op == O_ASHR && h >> 63 != 0, 0xFFFFFFFFFFFFFFFF, 0);
    if n >= 64 {
        let k = (n - 64) as u64;
        if op == O_SHL {
            return (0, l << k);
        }
        let hi = if op == O_ASHR {
            (h as i64 >> k as i64) as u64
        } else {
            h >> k
        };
        return (hi, fill);
    }
    let k = n as u64;
    if op == O_SHL {
        return (l << k, h << k | l >> 64 - k);
    }
    let hi = if op == O_ASHR {
        (h as i64 >> k as i64) as u64
    } else {
        h >> k
    };
    return (l >> k | h << 64 - k, hi);
}

// The unsigned quotient and remainder of `(al, ah)` by `(bl, bh)` (not 0), one bit per step.
const fn divmod128(al: u64, ah: u64, bl: u64, bh: u64) (u64, u64, u64, u64) {
    let mut ql: u64 = 0;
    let mut qh: u64 = 0;
    let mut rl: u64 = 0;
    let mut rh: u64 = 0;
    for k in 0..128u32 {
        let i = 127 - k;
        // r = r << 1 | bit i of a.
        rh = rh << 1 | rl >> 63;
        let bit = if i >= 64 {
            ah >> (i - 64) as u64
        } else {
            al >> i as u64
        };
        rl = rl << 1 | bit & 1;
        if rh > bh || rh == bh && rl >= bl {
            let bw = (rl < bl) as u64;
            rl = rl.wrapping_sub(bl);
            rh = rh.wrapping_sub(bh).wrapping_sub(bw);
            if i >= 64 {
                qh |= 1u64 << (i - 64) as u64;
            } else {
                ql |= 1u64 << i as u64;
            }
        }
    }
    return (ql, qh, rl, rh);
}

// Condition `c` between the 128-bit values `(xl, xh)` and `(yl, yh)`.
const fn icmp128(c: u16, xl: u64, xh: u64, yl: u64, yh: u64) bool {
    if c == C_EQ || c == C_NE {
        return (xl == yl && xh == yh) == (c == C_EQ);
    }
    let signed = c == C_SLT || c == C_SLE || c == C_SGT || c == C_SGE;
    let less = xh != yh && (signed && xh as i64 < yh as i64 || !signed && xh < yh) || xh == yh && xl < yl;
    let eq = xl == yl && xh == yh;
    if c == C_SLT || c == C_ULT {
        return less;
    }
    if c == C_SLE || c == C_ULE {
        return less || eq;
    }
    if c == C_SGT || c == C_UGT {
        return !less && !eq;
    }
    return !less;
}

pub(package) const fn sign_ext(x: u64, bits: u32) i64 {
    return lprint::sign_extend(x, bits);
}

// Lane `k` of `bits`-bit lanes of the vector whose words start at `w`.
const fn get_lane(vals: &Vector<u64>, w: u32, k: u32, bits: u32) u64 {
    let bit = k as u64 * bits as u64;
    return trunc_bits(vals[(w as u64 + bit / 64) as usize] >> bit % 64, bits);
}

const fn set_lane(vals: &mut Vector<u64>, w: u32, k: u32, bits: u32, v: u64) {
    let bit = k as u64 * bits as u64;
    let at = (w as u64 + bit / 64) as usize;
    let sh = bit % 64;
    let mask = trunc_bits(0xFFFFFFFFFFFFFFFFu64, bits) << sh;
    vals[at] = vals[at] & ~mask | trunc_bits(v, bits) << sh;
}

// Whether `op` (add, subtract, multiply) of the `ty` integers `x` and `y` leaves the type's range.
/// Whether checked operation `op` (`O_ADDO`, `O_SUBO`, `O_MULO`) of `x` and `y` of type `ty` overflows.
pub(package) const fn overflows(op: u8, ty: u8, ptr: u32, signed: bool, x: u64, y: u64) bool {
    let bits = type_bits(ty, ptr);
    if signed {
        let a = sign_ext(x, bits);
        let c = sign_ext(y, bits);
        if bits == 64 {
            return ov64(op, true, x, y);
        }
        let r = if op == O_ADDO {
            a + c
        } else if op == O_SUBO {
            a - c
        } else {
            a * c
        };
        return r != sign_ext(r as u64, bits);
    }
    if bits == 64 {
        return ov64(op, false, x, y);
    }
    if op == O_SUBO {
        return y > x;
    }
    let r = if op == O_ADDO {
        x + y
    } else {
        x * y
    };
    return r != trunc_bits(r, bits);
}

// Whether 64-bit `op` of `x` and `y` overflows.
const fn ov64(op: u8, signed: bool, x: u64, y: u64) bool {
    if signed {
        let a = x as i64;
        let c = y as i64;
        if op == O_ADDO {
            let (_, o) = a.overflowing_add(c);
            return o;
        }
        if op == O_SUBO {
            let (_, o) = a.overflowing_sub(c);
            return o;
        }
        let (_, o) = a.overflowing_mul(c);
        return o;
    }
    if op == O_ADDO {
        let (_, o) = x.overflowing_add(y);
        return o;
    }
    if op == O_SUBO {
        let (_, o) = x.overflowing_sub(y);
        return o;
    }
    let (_, o) = x.overflowing_mul(y);
    return o;
}

pub(package) const fn icmp(c: u16, ty: u8, ptr: u32, x: u64, y: u64) bool {
    let bits = type_bits(ty, ptr);
    let a = sign_ext(x, bits);
    let d = sign_ext(y, bits);
    if c == C_EQ {
        return x == y;
    }
    if c == C_NE {
        return x != y;
    }
    if c == C_SLT {
        return a < d;
    }
    if c == C_SLE {
        return a <= d;
    }
    if c == C_SGT {
        return a > d;
    }
    if c == C_SGE {
        return a >= d;
    }
    if c == C_ULT {
        return x < y;
    }
    if c == C_ULE {
        return x <= y;
    }
    if c == C_UGT {
        return x > y;
    }
    return x >= y;
}

const fn fcmp(c: u16, x: f64, y: f64) bool {
    let uno = x != x || y != y;
    if c == C_UNO {
        return uno;
    }
    if c == C_UEQ {
        return uno || x == y;
    }
    if c == C_UNE {
        return uno || x != y;
    }
    if uno {
        return false;
    }
    if c == C_OEQ {
        return x == y;
    }
    if c == C_ONE {
        return x != y;
    }
    if c == C_OLT {
        return x < y;
    }
    if c == C_OLE {
        return x <= y;
    }
    if c == C_OGT {
        return x > y;
    }
    return x >= y;
}

const fn to_f64(ty: u8, w: u64) f64 {
    if ty == T_F32 {
        return fl::f32_from_bits(w as u32);
    }
    return fl::f64_from_bits(w);
}

/// A float operation on f32 rounds to f32. A NaN result is the first NaN operand quieted, else the
/// positive quiet NaN, as LLVM folds it: the host's own NaN (x86's is negative) never shows.
pub(package) const fn float_op(op: u8, ty: u8, x: u64, y: u64) u64 {
    if ty == T_F32 {
        let a = fl::f32_from_bits(x as u32);
        let c = fl::f32_from_bits(y as u32);
        let r = if op == O_FADD {
            a + c
        } else if op == O_FSUB {
            a - c
        } else if op == O_FMUL {
            a * c
        } else if op == O_FDIV {
            a / c
        } else if op == O_FSQRT {
            a.sqrt()
        } else {
            -a
        };
        if r == r || op == O_FNEG {
            return fl::f32_bits(r);
        }
        if a != a {
            return x | 0x400000;
        }
        if c != c {
            return y | 0x400000;
        }
        return 0x7FC00000;
    }
    let a = fl::f64_from_bits(x);
    let c = fl::f64_from_bits(y);
    let r = if op == O_FADD {
        a + c
    } else if op == O_FSUB {
        a - c
    } else if op == O_FMUL {
        a * c
    } else if op == O_FDIV {
        a / c
    } else if op == O_FSQRT {
        a.sqrt()
    } else {
        -a
    };
    if r == r || op == O_FNEG {
        return fl::f64_bits(r);
    }
    if a != a {
        return x | 0x8000000000000;
    }
    if c != c {
        return y | 0x8000000000000;
    }
    return 0x7FF8000000000000;
}

// Scalar conversion `op` of `x` from `from` to `to`; false for an unchecked float conversion out of range.
pub(package) const fn scalar_convert(op: u8, aux: u16, from: u8, to: u8, ptr: u32, x: u64, out: &mut u64) bool {
    let fb = type_bits(from, ptr);
    let tb = type_bits(to, ptr);
    if op == O_SEXT {
        *out = trunc_bits(sign_ext(x, fb) as u64, tb);
        return true;
    }
    if op == O_ZEXT || op == O_TRUNC || op == O_PTRTOINT || op == O_INTTOPTR {
        *out = trunc_bits(x, tb);
        return true;
    }
    if op == O_FPEXT {
        *out = fl::f64_bits(fl::f32_from_bits(x as u32));
        return true;
    }
    if op == O_FPTRUNC {
        *out = fl::f32_bits(fl::f64_from_bits(x) as f32);
        return true;
    }
    if op == O_SITOFP || op == O_UITOFP {
        let v: f64 = if op == O_SITOFP {
            sign_ext(x, fb) as f64
        } else {
            x as f64
        };
        // A 64-bit integer converts with one rounding, straight to f32 when that is the result.
        if to == T_F32 {
            let r: f32 = if op == O_SITOFP {
                sign_ext(x, fb) as f32
            } else {
                x as f32
            };
            *out = fl::f32_bits(r);
        } else {
            *out = fl::f64_bits(v);
        }
        return true;
    }
    // A float to an integer: truncate, saturating (NaN is 0) unless unchecked.
    let v = to_f64(from, x);
    let signed = op == O_FPTOSI;
    let lo: f64 = if signed {
        -2.0f64.powi((tb - 1) as i32)
    } else {
        0.0
    };
    let hi: f64 = if signed {
        2.0f64.powi((tb - 1) as i32)
    } else {
        2.0f64.powi(tb as i32)
    };
    if v != v || v <= lo - 1.0 || v >= hi {
        if aux == CV_UNCHECKED {
            return false;
        }
        if v != v {
            *out = 0;
        } else if v < 0.0 {
            *out = trunc_bits(pick_u64(signed, (1u64 << (tb - 1) as u64).wrapping_neg(), 0), tb);
        } else {
            *out = trunc_bits(pick_u64(signed, (1u64 << (tb - 1) as u64) - 1, 0xFFFFFFFFFFFFFFFFu64), tb);
        }
        return true;
    }
    if signed {
        *out = trunc_bits((v as i64) as u64, tb);
    } else {
        *out = trunc_bits(v as u64, tb);
    }
    return true;
}

const fn wrap_name(n: str) bool {
    return n == "sc_wadd64" || n == "sc_wsub64" || n == "sc_wmul64" || n == "sc_wshl64" || n == "sc_wshr64" || n == "sc_wsar64" || n == "sc_mulo_u64" || n == "sc_mulo_i64";
}

// The routines the evaluator models.
const IC_NONE: u8 = 0;
const IC_MALLOC: u8 = 1;
const IC_CALLOC: u8 = 2;
const IC_REALLOC: u8 = 3;
const IC_FREE: u8 = 4;
const IC_MEMCPY: u8 = 5;
const IC_MEMSET: u8 = 6;
const IC_MEMCMP: u8 = 7;
const IC_STRLEN: u8 = 8;
const IC_STRCMP: u8 = 9;
const IC_ABORT: u8 = 10;
const IC_PANIC: u8 = 11;
const IC_PANIC_STR: u8 = 12;
const IC_ASSERT: u8 = 13;
const IC_TRAP_ORDER: u8 = 14;
const IC_ZST_DIFF: u8 = 15;
const IC_OVERFLOW: u8 = 16;
const IC_DIV_ZERO: u8 = 17;
const IC_ZERO: u8 = 18;
const IC_PREEMPT: u8 = 19;
const IC_WRAP: u8 = 20;
const IC_BITS: u8 = 21;
const IC_LIBM: u8 = 22;
const IC_ALIGNED: u8 = 23; // sc_lk_aligned_alloc(n, align)
const IC_ACCT_ON: u8 = 24; // std::testing::bench_sys's allocation accounting switch
const IC_ACCT_ENABLED: u8 = 25;
const IC_ACCT_SNAPSHOT: u8 = 26;
const IC_INDEX_BOUNDS: u8 = 27; // __sc_index_bounds(i, n)
const IC_VEC_BOUNDS: u8 = 28; // __sc_vec_bounds(w, i, n)
const IC_LANE_BOUNDS: u8 = 29; // __sc_lane_bounds(lane, x, n, start)
const IC_LANE_PANIC: u8 = 30; // __sc_lane_panic(lane, m)

/// Whether the evaluator runs function `name` as it models it, not its body: the optimizer keeps the
/// calls of such a function.
pub(package) const fn modeled(name: str) bool {
    return icode_of(name) != IC_NONE;
}

// The routine function symbol `name` names (`__sc_x_<c name>` is a C library name's alias).
const fn icode_of(name0: str) u8 {
    let name = if name0.starts_with("__sc_x_") {
        name0.slice(7, name0.len())
    } else {
        name0
    };
    if name == "malloc" || name == "sc_lk_malloc" {
        return IC_MALLOC;
    }
    if name == "calloc" || name == "sc_lk_calloc" {
        return IC_CALLOC;
    }
    if name == "realloc" || name == "sc_lk_realloc" {
        return IC_REALLOC;
    }
    if name == "free" || name == "sc_lk_free" || name == "sc_lk_aligned_free" {
        return IC_FREE;
    }
    if name == "sc_lk_aligned_alloc" {
        return IC_ALIGNED;
    }
    // `std::testing::bench_sys`'s accounting counts the C malloc family's calls, which the evaluator's
    // heap replaces: it counts its own.
    if name == "bench_sys__sc_bs_alloc_enable" {
        return IC_ACCT_ON;
    }
    if name == "bench_sys__sc_bs_alloc_enabled" {
        return IC_ACCT_ENABLED;
    }
    if name == "bench_sys__sc_bs_alloc_snapshot" {
        return IC_ACCT_SNAPSHOT;
    }
    if name == "memcpy" || name == "memmove" {
        return IC_MEMCPY;
    }
    if name == "memset" {
        return IC_MEMSET;
    }
    if name == "memcmp" {
        return IC_MEMCMP;
    }
    if name == "strlen" {
        return IC_STRLEN;
    }
    if name == "strcmp" {
        return IC_STRCMP;
    }
    if name == "abort" {
        return IC_ABORT;
    }
    if name == "__sc_panic" {
        return IC_PANIC;
    }
    if name == "__sc_panic_str" {
        return IC_PANIC_STR;
    }
    if name == "__sc_assert_fail" || name == "__sc_assert_vals" {
        return IC_ASSERT;
    }
    if name == "__sc_trap_order" {
        return IC_TRAP_ORDER;
    }
    if name == "__sc_index_bounds" {
        return IC_INDEX_BOUNDS;
    }
    if name == "__sc_vec_bounds" {
        return IC_VEC_BOUNDS;
    }
    if name == "__sc_lane_bounds" {
        return IC_LANE_BOUNDS;
    }
    if name == "__sc_lane_panic" {
        return IC_LANE_PANIC;
    }
    if name == "__sc_zst_ptrdiff" {
        return IC_ZST_DIFF;
    }
    if name == "sc_int_overflow" || name == "sc_int_div_overflow" {
        return IC_OVERFLOW;
    }
    if name == "sc_int_div_zero" {
        return IC_DIV_ZERO;
    }
    if name == "sc_has_i128" || name == "sc_has_f128" || name == "sc_has_f16" || name == "__sc_cancel_tick" {
        return IC_ZERO;
    }
    if name == "__sc_preempt_check" {
        return IC_PREEMPT;
    }
    if wrap_name(name) {
        return IC_WRAP;
    }
    if name == "sc_ctz64" || name == "sc_clz64" || name == "sc_popcount64" {
        return IC_BITS;
    }
    let base = if name.len() > 1 && name.ends_with("f") {
        name.slice(0, name.len() - 1)
    } else {
        name
    };
    if iri::libm1(name, 1.0).ok || iri::libm2(name, 1.0, 1.0).ok || iri::libm1(base, 1.0).ok || iri::libm2(
        base,
        1.0,
        1.0,
    ).ok || base == "fma" {
        return IC_LIBM;
    }
    return IC_NONE;
}

const fn pick_usize(c: bool, a: usize, b: usize) usize {
    return ast::pick(c, a, b);
}

extend Eval {
    // The element-wise operations: comparisons and choices, integer and float lane rules, the lane
    // count changes (halves, concatenation, narrowing) and `bitcast`.
    fn vlanes(self: &mut Self, t: Inst, c: u8, sg: bool, dsg: bool, w: &[u32; 4], ty: &[u8; 4], dst: u32) bool {
        let rule = core::simd_op(c).rule;
        // The vector the lanes come from: the choice's first, else operand 0, else the result.
        let vt = if rule == core::SR_CHOOSE {
            ty[1]
        } else if rule == core::SR_ANY {
            t.ty
        } else {
            ty[0]
        };
        let lt = lane_type(vt);
        let lb = type_bits(lt, 8);
        let n = lanes(vt);
        let fl = is_float(lt);
        if rule == core::SR_BITCAST {
            // Lanes are little-endian bytes in the words: the same bits.
            for k in 0..value_words(t.ty, 8) {
                self.vals[(dst + k) as usize] = self.vals[(w[0] + k) as usize];
            }
            return true;
        }
        if rule == core::SR_HALF || rule == core::SR_CONCAT {
            let rn = lanes(t.ty);
            for i in 0..rn {
                let x = if rule == core::SR_CONCAT && i >= n {
                    get_lane(&self.vals, w[1], i - n, lb)
                } else if c == core::SIMD_HIGH_HALF {
                    get_lane(&self.vals, w[0], i + rn, lb)
                } else {
                    get_lane(&self.vals, w[0], i, lb)
                };
                set_lane(&mut self.vals, dst, i, lb, x);
            }
            return true;
        }
        let mask = rule == core::SR_MASK || rule == core::SR_CHANGED;
        let rlt = if mask || !is_vec(t.ty) {
            lt
        } else {
            lane_type(t.ty)
        };
        let rlb = type_bits(rlt, 8);
        let mut bits: u64 = 0;
        for i in 0..n {
            let a = if rule == core::SR_CHOOSE {
                get_lane(&self.vals, w[1], i, lb)
            } else if rule == core::SR_ANY {
                0
            } else {
                get_lane(&self.vals, w[0], i, lb)
            };
            // Operand 1: a lane, or one scalar for every lane (a count).
            let c2 = if rule == core::SR_CHOOSE {
                get_lane(&self.vals, w[2], i, lb)
            } else if ty[1] != T_NONE && is_vec(ty[1]) {
                get_lane(&self.vals, w[1], i, type_bits(lane_type(ty[1]), 8))
            } else if ty[1] != T_NONE {
                self.vals[w[1] as usize]
            } else {
                0
            };
            let c3 = if ty[2] != T_NONE && is_vec(ty[2]) {
                get_lane(&self.vals, w[2], i, lb)
            } else {
                0
            };
            let mut bit = false;
            let mut r: u64 = 0;
            if c == core::SIMD_IOTA {
                r = if fl {
                    from_f64(lt, i as f64)
                } else {
                    i
                };
            } else if c >= core::SIMD_CMP_EQ && c <= core::SIMD_CMP_GE {
                bit = lane_cmp(c, a, c2, lt, sg);
            } else if c == core::SIMD_CHOOSE {
                r = pick_u64((self.vals[w[0] as usize] >> i as u64 & 1) != 0, a, c2);
            } else if c == core::SIMD_CAST_CHANGED {
                bit = lane_changed(
                    a,
                    lt,
                    sg,
                    get_lane(&self.vals, w[1], i, type_bits(lane_type(ty[1]), 8)),
                    lane_type(ty[1]),
                    dsg,
                );
            } else if fl {
                r = lane_float(c, a, c2, c3, lt, &mut bit);
            } else if !self.lane_int(c, a, c2, lt, sg, rlt, dsg, &mut r, &mut bit) {
                // The trap names its lane, as a lane check does.
                let m = replace(&mut self.out.msg, format("lane {}: ", i));
                self.out.msg.push_string(&m);
                return false;
            }
            if mask {
                bits = bits | pick_u64(bit, 1, 0) << i as u64;
            } else {
                set_lane(&mut self.vals, dst, i, rlb, r);
            }
        }
        if mask {
            self.vals[dst as usize] = bits;
        }
        return true;
    }

    // Integer lane rule `c` on lanes `a`, `c2` (bits) of `lt`, signed `sg`, into `r` (a lane of `rlt`,
    // signed `rsg`) or the mask bit `bit`; false when the lane traps.
    fn lane_int(
        self: &mut Self,
        c: u8,
        a0: u64,
        c20: u64,
        lt: u8,
        sg: bool,
        rlt: u8,
        rsg: bool,
        r: &mut u64,
        bit: &mut bool,
    ) bool {
        let w = type_bits(lt, 8);
        let a = lane_val(a0, w, sg);
        let c2 = lane_val(c20, w, sg);
        let u = trunc_bits(a0, w);
        let min = if sg {
            (1u64 << (w - 1) as u64).wrapping_neg() as i64
        } else {
            0
        };
        let max = if sg {
            ((1u64 << (w - 1) as u64) - 1) as i64
        } else {
            trunc_bits(0xFFFFFFFFFFFFFFFFu64, w) as i64
        };
        let k = c20 & w as u64 - 1;
        let lt_ = if sg {
            a < c2
        } else {
            a as u64 < c2 as u64
        };
        if c >= core::SIMD_WRAP_ADD && c <= core::SIMD_WRAP_MUL || c >= core::SIMD_OVF_ADD && c <= core::SIMD_SAT_SUB {
            let add = c == core::SIMD_WRAP_ADD || c == core::SIMD_OVF_ADD || c == core::SIMD_SAT_ADD;
            let sub = c == core::SIMD_WRAP_SUB || c == core::SIMD_OVF_SUB || c == core::SIMD_SAT_SUB;
            let oc = pick_u8(add, O_ADDO, pick_u8(sub, O_SUBO, O_MULO));
            let ua = a as u64;
            let uc = c2 as u64;
            let mut v = if add {
                ua.wrapping_add(uc)
            } else if sub {
                ua.wrapping_sub(uc)
            } else {
                ua.wrapping_mul(uc)
            } as i64;
            let o = ov64(oc, sg, ua, uc) || w < 64 && if sg {
                sign_ext(trunc_bits(v as u64, w), w) != v
            } else {
                v as u64 >> w as u64 != 0
            };
            if c >= core::SIMD_OVF_ADD && c <= core::SIMD_OVF_MUL {
                *bit = o;
                return true;
            }
            if c == core::SIMD_SAT_ADD && o {
                v = pick_i64(sg && c2 < 0, min, max);
            } else if c == core::SIMD_SAT_SUB && o {
                v = pick_i64(sg && c2 < 0, max, min);
            }
            *r = trunc_bits(v as u64, w);
            return true;
        }
        if c == core::SIMD_ABS && sg && a == min {
            return self.stop(iri::IT_TRAP_UB_OVERFLOW, core::lane_trap_msg(core::RV_SIMD, c, false));
        }
        if c == core::SIMD_NARROW_CHECKED {
            let rw = type_bits(rlt, 8);
            let fits = if !sg && a < 0 {
                !rsg && rw == 64
            } else if !rsg && rw == 64 {
                a >= 0 || !sg
            } else {
                lane_fits(a, rw, rsg)
            };
            if !fits {
                return self.stop(iri::IT_TRAP_UB_OVERFLOW, core::lane_trap_msg(core::RV_SIMD, c, false));
            }
            *r = trunc_bits(a as u64, rw);
            return true;
        }
        if c == core::SIMD_NARROW_SAT {
            let rw = type_bits(rlt, 8);
            let rmax = pick_u64(rsg, (1u64 << (rw - 1) as u64) - 1, trunc_bits(0xFFFFFFFFFFFFFFFFu64, rw)) as i64;
            let rmin = pick_i64(rsg, (1u64 << (rw - 1) as u64).wrapping_neg() as i64, 0);
            let v = pick_i64(a < 0 && sg && !rsg, 0, a);
            let big = pick_bool(sg, v > rmax, v as u64 > rmax as u64);
            *r = trunc_bits(pick_i64(big, rmax, pick_i64(sg && v < rmin, rmin, v)) as u64, rw);
            return true;
        }
        if c == core::SIMD_BITREV || c == core::SIMD_BSWAP {
            let step = pick_u64(c == core::SIMD_BSWAP, 8, 1);
            let mut x: u64 = 0;
            let mut j: u64 = 0;
            for _ in 0..64 {
                if j >= w as u64 {
                    break;
                }
                x = x | (u >> j & (1u64 << step) - 1) << w as u64 - step - j;
                j += step;
            }
            *r = trunc_bits(x, w);
            return true;
        }
        let v: i64 = if c == core::SIMD_WRAP_NEG {
            a.wrapping_neg()
        } else if c == core::SIMD_WRAP_SHL {
            (u << k) as i64
        } else if c == core::SIMD_WRAP_SHR {
            pick_i64(sg, a >> k as i64, (u >> k) as i64)
        } else if c == core::SIMD_MIN {
            pick_i64(lt_, a, c2)
        } else if c == core::SIMD_MAX {
            pick_i64(lt_, c2, a)
        } else if c == core::SIMD_ABS || c == core::SIMD_WRAP_ABS {
            pick_i64(sg && a < 0, a.wrapping_neg(), a)
        } else if c == core::SIMD_ABS_DIFF {
            let d = pick_u64(
                pick_bool(sg, a > c2, a as u64 > c2 as u64),
                (a as u64).wrapping_sub(c2 as u64),
                (c2 as u64).wrapping_sub(a as u64),
            );
            *r = trunc_bits(d, type_bits(rlt, 8));
            return true;
        } else if c == core::SIMD_CLZ {
            (u.leading_zeros() as u64 - (64 - w as u64)) as i64
        } else if c == core::SIMD_CTZ {
            pick_u64(u == 0, w, u.trailing_zeros() as u64) as i64
        } else if c == core::SIMD_POPCNT {
            u.count_ones() as i64
        } else if c == core::SIMD_ROTL {
            (u << k | u >> (w as u64 - k & w as u64 - 1)) as i64
        } else if c == core::SIMD_ROTR {
            (u >> k | u << (w as u64 - k & w as u64 - 1)) as i64
        } else {
            return self.stop(EV_ERROR, "an integer vector operation the evaluator does not model");
        };
        *r = trunc_bits(v as u64, w);
        return true;
    }
}

// Lane bits `x` of `w` bits as a value: sign-extended for a signed lane.
const fn lane_val(x: u64, w: u32, sg: bool) i64 {
    if sg {
        return sign_ext(x, w);
    }
    return trunc_bits(x, w) as i64;
}

// Whether `v` fits a lane of `w` bits (signed `sg`).
const fn lane_fits(v: i64, w: u32, sg: bool) bool {
    if w >= 64 {
        return sg || v >= 0;
    }
    if sg {
        return sign_ext(trunc_bits(v as u64, w), w) == v;
    }
    return v >= 0 && v as u64 >> w as u64 == 0;
}

// Comparison `c` (SIMD_CMP_EQ to SIMD_CMP_GE) of lanes `a`, `b` of `lt`.
const fn lane_cmp(c: u8, a: u64, b: u64, lt: u8, sg: bool) bool {
    if is_float(lt) {
        let x = to_f64(lt, a);
        let y = to_f64(lt, b);
        return if c == core::SIMD_CMP_EQ {
            x == y
        } else if c == core::SIMD_CMP_NE {
            x != y
        } else if c == core::SIMD_CMP_LT {
            x < y
        } else if c == core::SIMD_CMP_LE {
            x <= y
        } else if c == core::SIMD_CMP_GT {
            x > y
        } else {
            x >= y
        };
    }
    let w = type_bits(lt, 8);
    let x = lane_val(a, w, sg);
    let y = lane_val(b, w, sg);
    let less = pick_bool(sg, x < y, x as u64 < y as u64);
    return if c == core::SIMD_CMP_EQ {
        x == y
    } else if c == core::SIMD_CMP_NE {
        x != y
    } else if c == core::SIMD_CMP_LT {
        less
    } else if c == core::SIMD_CMP_LE {
        less || x == y
    } else if c == core::SIMD_CMP_GT {
        !less && x != y
    } else {
        !less
    };
}

// Whether casting lane `a` of `bt` (signed `bs`) to lane `d` of `rt` (signed `rs`) changed its value,
// or `a` is a NaN (the interpreter's `lane_changed`).
fn lane_changed(a: u64, bt: u8, bs: bool, d: u64, rt: u8, rs: bool) bool {
    let ff = is_float(bt);
    let tf = is_float(rt);
    if ff && tf {
        let x = to_f64(bt, a);
        return x != x || to_f64(rt, d) != x;
    }
    // The exact float range of the integer side: [lo, hi).
    let ib = pick_u8(ff, rt, bt);
    let isg = pick_bool(ff, rs, bs);
    let iw = type_bits(ib, 8) as i32 - pick_i32(isg, 1, 0);
    let hi = math::ldexp(1.0, iw);
    let lo = if isg {
        0.0 - hi
    } else {
        0.0
    };
    if ff {
        let x = to_f64(bt, a);
        return !(x >= lo && x < hi && math::trunc(x) == x);
    }
    let av = lane_val(a, type_bits(bt, 8), bs);
    if tf {
        let y = to_f64(rt, d);
        let back = if bs {
            y as i64
        } else {
            (y as u64) as i64
        };
        return !(y >= lo && y < hi && back == av);
    }
    let rw = type_bits(rt, 8);
    if !bs && av < 0 {
        return !(!rs && rw == 64);
    }
    if !rs && rw == 64 {
        return !(av >= 0 || !bs);
    }
    return !lane_fits(av, rw, rs);
}

// Float lane rule `c` on lanes `a`, `c2`, `c3` (bits) of `lt`: the result lane's bits, or a mask code's
// lane bit in `bit` (the interpreter's `lane_float`, `fminmax` and `fsign_lane`).
fn lane_float(c: u8, a0: u64, c20: u64, c30: u64, lt: u8, bit: &mut bool) u64 {
    let f32l = lt == T_F32;
    let a = to_f64(lt, a0);
    let c2 = to_f64(lt, c20);
    let c3 = to_f64(lt, c30);
    let sb = pick_u64(f32l, 1u64 << 31, 1u64 << 63);
    if c == core::SIMD_ABS {
        return a0 & ~sb;
    }
    if c == core::SIMD_COPYSIGN {
        return a0 & ~sb | c20 & sb;
    }
    if c == core::SIMD_MIN || c == core::SIMD_MAX || c == core::SIMD_MINIMUM || c == core::SIMD_MAXIMUM {
        let lo = c == core::SIMD_MIN || c == core::SIMD_MINIMUM;
        let nan = c >= core::SIMD_MINIMUM;
        if !nan && a != a && c2 != c2 {
            // Two NaNs: `a` with its quiet bit set (IEEE 754 minimumNumber).
            return a0 | pick_u64(f32l, 1u64 << 22, 1u64 << 51);
        }
        return pick_u64(fminmax(a, c2, lo, nan), a0, c20);
    }
    let minn = pick_f64(f32l, 1.1754943508222875e-38, 2.2250738585072014e-308);
    let maxf = pick_f64(f32l, 3.4028234663852886e38, 1.7976931348623157e308);
    let ab = math::fabs(a);
    if c >= core::SIMD_IS_NAN && c <= core::SIMD_IS_SIGN_NEG {
        *bit = if c == core::SIMD_IS_NAN {
            a != a
        } else if c == core::SIMD_IS_INF {
            ab > maxf
        } else if c == core::SIMD_IS_FINITE {
            ab <= maxf
        } else if c == core::SIMD_IS_NORMAL {
            ab >= minn && ab <= maxf
        } else if c == core::SIMD_IS_SUBNORMAL {
            ab != 0.0 && ab < minn
        } else {
            (a0 & sb) != 0
        };
        return 0;
    }
    if c == core::SIMD_FMA && f32l {
        // `fmaf`: the product of two f32 lanes is exact in f64, the sum's error exact (two-sum), and
        // the sum rounded to odd keeps the one f32 rounding.
        let p = a * c2;
        let s = p + c3;
        let bb = s - p;
        let e = p - (s - bb) + (c3 - bb);
        let sbits = fl::f64_bits(s);
        let fin = s == s && math::fabs(s) <= 1.7976931348623157e308;
        let r = if e != 0.0 && fin && (sbits & 1) == 0 {
            fl::f64_from_bits(pick_u64(e > 0.0 == s > 0.0, sbits + 1, sbits - 1))
        } else {
            s
        };
        return from_f64(lt, r);
    }
    let r = if c == core::SIMD_SQRT {
        math::sqrt(a)
    } else if c == core::SIMD_CEIL {
        math::ceil(a)
    } else if c == core::SIMD_FLOOR {
        math::floor(a)
    } else if c == core::SIMD_TRUNC {
        math::trunc(a)
    } else if c == core::SIMD_ROUND_EVEN {
        math::nearbyint(a)
    } else if c == core::SIMD_FMA {
        math::fma(a, c2, c3)
    } else {
        0.0
    };
    return from_f64(lt, r);
}

// IEEE 754-2019 minimumNumber (`min`, else maximumNumber) of `a`, `c`, or with `nan` minimum
// (maximum): whether `a` is the kept operand.
const fn fminmax(a: f64, c: f64, min: bool, nan: bool) bool {
    if a != a || c != c {
        return pick_bool(nan, a != a, c != c);
    }
    if a != c {
        return a < c == min;
    }
    return fl::f64_bits(a) >> 63 != 0 == min;
}

// `x` as the bits of a lane of float type `lt` (an f32 lane rounds once).
const fn from_f64(lt: u8, x: f64) u64 {
    if lt == T_F32 {
        return fl::f32_bits(x as f32);
    }
    return fl::f64_bits(x);
}

const fn pick_u8(c: bool, a: u8, b: u8) u8 {
    return ast::pick(c, a, b);
}

const fn pick_u16(c: bool, a: u16, b: u16) u16 {
    return ast::pick(c, a, b);
}

const fn pick_i64(c: bool, a: i64, b: i64) i64 {
    return ast::pick(c, a, b);
}

const fn pick_f64(c: bool, a: f64, b: f64) f64 {
    return ast::pick(c, a, b);
}

const fn pick_bool(c: bool, a: bool, b: bool) bool {
    return ast::pick(c, a, b);
}

extend Eval {
    // The element of type `lt` `k` elements past address `p`, read into (`load`) or written from lane
    // `i` of the vector at word `vw`.
    fn lane_mem(self: &mut Self, p: u64, k: u64, lt: u8, vw: u32, i: u32, load: bool) bool {
        let lb = type_bits(lt, 8);
        let at = p + k * (lb / 8) as u64;
        let w0 = self.vals.len() as u32;
        self.vals.push(0);
        let ok = if load {
            self.load(at, lt, w0)
        } else {
            self.vals[w0 as usize] = get_lane(&self.vals, vw, i, lb);
            self.store(at, lt, w0)
        };
        if ok && load {
            let x = self.vals[w0 as usize];
            set_lane(&mut self.vals, vw, i, lb, x);
        }
        self.vals.truncate(w0 as usize);
        return ok;
    }

    // `load`, `store` and their raw forms: N elements from the slice's pointer at the checked start,
    // or through the pointer.
    fn vmem(self: &mut Self, t: Inst, c: u8, w: &[u32; 4], ty: &[u8; 4], dst: u32) bool {
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let raw = c == core::SIMD_LOAD_RAW || c == core::SIMD_STORE_RAW;
        let load = c == core::SIMD_LOAD || c == core::SIMD_LOAD_RAW;
        let mut p = self.vals[w[0] as usize];
        let mut start: u64 = 0;
        if !raw {
            // Operand 0 is the slice view's address: its pointer is the first field.
            let w0 = self.vals.len() as u32;
            self.vals.push(0);
            let ok = self.load(p, T_PTR, w0);
            p = self.vals[w0 as usize];
            self.vals.truncate(w0 as usize);
            if !ok {
                return false;
            }
            start = trunc_bits(self.vals[w[1] as usize], ptr * 8);
        }
        let vt = if load {
            t.ty
        } else {
            unsafe ty[pick_usize(raw, 1, 2)]
        };
        let vw = if load {
            dst
        } else {
            unsafe w[pick_usize(raw, 1, 2)]
        };
        for i in 0..lanes(vt) {
            if !self.lane_mem(p, start + i as u64, lane_type(vt), vw, i, load) {
                return false;
            }
        }
        return true;
    }

    // The masked, partial and gather forms: every active lane is checked before the first access,
    // and the lowest failing one traps; an inactive lane never touches its element.
    fn vmem_masked(self: &mut Self, t: Inst, c: u8, w: &[u32; 4], ty: &[u8; 4], dst: u32) bool {
        let ptr = (unsafe &*self.pkg).ptr_bytes;
        let op = core::simd_op(c);
        let ar = op.arity as usize;
        let store = op.rule == core::SR_MSTORE;
        let vt = unsafe ty[ar - 1];
        let vw0 = unsafe w[ar - 1];
        let lt = lane_type(vt);
        let n = lanes(vt);
        let ptrs = c == core::SIMD_GATHER_PTR || c == core::SIMD_SCATTER_PTR;
        let gat = c == core::SIMD_GATHER || c == core::SIMD_SCATTER || c == core::SIMD_GATHER_UNCHECKED;
        let sl = c < core::SIMD_GATHER_PTR;
        let mut p = self.vals[w[0] as usize];
        let mut len: u64 = 0;
        if sl {
            let w0 = self.vals.len() as u32;
            self.vals.push(0);
            self.vals.push(0);
            let ok = self.load(p, T_PTR, w0) && self.load(
                p + ptr as u64,
                if ptr == 8 {
                    T_I64
                } else {
                    T_I32
                },
                w0 + 1,
            );
            p = self.vals[w0 as usize];
            len = self.vals[(w0 + 1) as usize];
            self.vals.truncate(w0 as usize);
            if !ok {
                return false;
            }
        }
        let start = if sl && !gat {
            trunc_bits(self.vals[w[1] as usize], ptr * 8)
        } else {
            0
        };
        // The index vector of a gather or scatter.
        let iw = w[1];
        let ib = if gat {
            type_bits(lane_type(ty[1]), 8)
        } else {
            0
        };
        let mut act: u64 = if c == core::SIMD_LOAD_OR {
            0
        } else {
            self.vals[(unsafe w[ar - 2]) as usize]
        };
        if c == core::SIMD_LOAD_OR {
            for i in 0..n {
                if start <= len && i as u64 < len - start {
                    act = act | 1u64 << i as u64;
                }
            }
        }
        if n < 64 {
            act = act & (1u64 << n as u64) - 1;
        }
        let count = act.count_ones() as u64;
        if c == core::SIMD_COMPRESS_STORE && (start > len || count > len - start) {
            let mut m = String::new();
            m.format_into("index out of bounds: {} lanes from {} but the length is {}", count, start, len);
            return self.stop(iri::IT_TRAP_UB_OOB, &m);
        }
        if sl && c != core::SIMD_COMPRESS_STORE {
            for i in 0..n {
                let ix = if gat {
                    get_lane(&self.vals, iw, i, ib)
                } else {
                    start
                };
                let bad = if gat {
                    ix >= len
                } else {
                    start > len || i as u64 >= len - start
                };
                if (act >> i as u64 & 1) != 0 && bad {
                    let mut m = String::new();
                    if gat {
                        m.format_into("lane {}: index out of bounds: the index is {} but the length is {}", i, ix, len);
                    } else {
                        m.format_into(
                            "lane {}: index out of bounds: the index is {} + {} but the length is {}",
                            i,
                            start,
                            i,
                            len,
                        );
                    }
                    return self.stop(iri::IT_TRAP_UB_OOB, &m);
                }
            }
        }
        // A load starts from the fallback lanes.
        if !store {
            for k in 0..value_words(t.ty, ptr) {
                self.vals[(dst + k) as usize] = self.vals[(vw0 + k) as usize];
            }
        }
        let vw = if store {
            vw0
        } else {
            dst
        };
        let mut k: u64 = 0;
        for i in 0..n {
            if (act >> i as u64 & 1) == 0 {
                continue;
            }
            let mut base = p;
            let at = if ptrs {
                // Lane i's pointer: element i of the pointer array at operand 0's address.
                let w0 = self.vals.len() as u32;
                self.vals.push(0);
                let ok = self.load(p + i as u64 * ptr as u64, T_PTR, w0);
                base = self.vals[w0 as usize];
                self.vals.truncate(w0 as usize);
                if !ok {
                    return false;
                }
                0
            } else if gat {
                get_lane(&self.vals, iw, i, ib)
            } else if c == core::SIMD_COMPRESS_STORE {
                start + k
            } else {
                start + i as u64
            };
            k += 1;
            let ok = if c == core::SIMD_COMPRESS_STORE {
                // Lane i goes to the next packed position.
                self.lane_mem(base, at, lt, vw, i, false)
            } else {
                self.lane_mem(base, at, lt, vw, i, !store)
            };
            if !ok {
                return false;
            }
        }
        if c == core::SIMD_COMPRESS_STORE && t.ty != T_NONE {
            self.put(dst, count);
        }
        return true;
    }
}

extend Eval {
    // The reductions and `dot` over the lanes of operand 0 (and 1): a left-to-right fold, the
    // halving tree, the lowest extreme lane, or the exact-result test.
    fn vreduce(self: &mut Self, t: Inst, c: u8, sg: bool, w: &[u32; 4], ty: &[u8; 4], dst: u32) bool {
        let vt = ty[0];
        let lt = lane_type(vt);
        let lb = type_bits(lt, 8);
        let n = lanes(vt);
        let fl = is_float(lt);
        if c == core::SIMD_REDUCE_ADD_OVF || c == core::SIMD_REDUCE_MUL_OVF {
            self.put(dst, pick_u64(exact_fits(c == core::SIMD_REDUCE_ADD_OVF, &self.vals, w[0], n, lb, sg), 0, 1));
            return true;
        }
        if c >= core::SIMD_ARG_MIN && c <= core::SIMD_ARG_MAX_NUM {
            // The lowest lane whose value beats every lane before it; a NaN lane never does, and -0.0
            // is below +0.0.
            let min = c == core::SIMD_ARG_MIN || c == core::SIMD_ARG_MIN_NUM;
            let mut best = n;
            for i in 0..n {
                let l = get_lane(&self.vals, w[0], i, lb);
                if fl && to_f64(lt, l) != to_f64(lt, l) {
                    continue;
                }
                if best == n {
                    best = i;
                    continue;
                }
                let o = get_lane(&self.vals, w[0], best, lb);
                let beats = if fl {
                    let x = to_f64(lt, l);
                    let y = to_f64(lt, o);
                    let xs = l >> (lb - 1) as u64 != 0;
                    let ys = o >> (lb - 1) as u64 != 0;
                    x != y && x < y == min || x == y && xs != ys && xs == min
                } else {
                    let x = lane_val(l, lb, sg);
                    let y = lane_val(o, lb, sg);
                    x != y && pick_bool(sg, x < y, x as u64 < y as u64) == min
                };
                if beats {
                    best = i;
                }
            }
            self.put(dst, best);
            return true;
        }
        // The accumulator's type: the result's (`dot` widens each product to it).
        let at = t.ty;
        let ab = type_bits(at, 8);
        let add = c == core::SIMD_REDUCE_ADD || c == core::SIMD_REDUCE_ADD_ORD || c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_DOT;
        let mul = c == core::SIMD_REDUCE_MUL || c == core::SIMD_REDUCE_MUL_ORD || c == core::SIMD_REDUCE_MUL_TREE;
        // Lane i as the accumulator's type: for `dot` the product, rounded or wrapped there.
        let w0 = self.vals.len() as u32;
        for i in 0..n {
            let mut a = get_lane(&self.vals, w[0], i, lb);
            if c == core::SIMD_DOT {
                let q0 = get_lane(&self.vals, w[1], i, lb);
                if fl {
                    let p = from_f64(at, to_f64(lt, a));
                    let q = from_f64(at, to_f64(lt, q0));
                    a = float_op(O_FMUL, at, p, q);
                } else {
                    let p = lane_val(a, lb, sg) as u64;
                    let q = lane_val(q0, lb, sg) as u64;
                    a = trunc_bits(p.wrapping_mul(q), ab);
                }
            }
            self.vals.push(a);
        }
        let fop = pick_u8(add, O_FADD, O_FMUL);
        if c == core::SIMD_REDUCE_ADD_TREE || c == core::SIMD_REDUCE_MUL_TREE {
            // Halves: lane i of the lower half with lane i of the upper, until one lane.
            let mut h = n / 2;
            while h != 0 {
                for i in 0..h {
                    let x = float_op(fop, at, self.vals[(w0 + i) as usize], self.vals[(w0 + i + h) as usize]);
                    self.vals[(w0 + i) as usize] = x;
                }
                h = h / 2;
            }
            let r = self.vals[w0 as usize];
            self.vals.truncate(w0 as usize);
            self.put(dst, r);
            return true;
        }
        let ffold = fl && (add || mul);
        let mut acc = if ffold {
            from_f64(at, pick_f64(add, -0.0, 1.0))
        } else if c == core::SIMD_DOT {
            0
        } else {
            self.vals[w0 as usize]
        };
        let from = pick_u32(ffold || c == core::SIMD_DOT, 0, 1);
        for i in from..n {
            let a = self.vals[(w0 + i) as usize];
            if ffold {
                acc = float_op(fop, at, acc, a);
            } else if fl {
                // min_num, max_num, minimum, maximum: the lane rule, the kept operand itself.
                let lo = c == core::SIMD_REDUCE_MIN_NUM || c == core::SIMD_REDUCE_MINIMUM;
                acc = pick_u64(fminmax(to_f64(at, acc), to_f64(at, a), lo, c >= core::SIMD_REDUCE_MINIMUM), acc, a);
            } else if c == core::SIMD_REDUCE_AND {
                acc = acc & a;
            } else if c == core::SIMD_REDUCE_OR {
                acc = acc | a;
            } else if c == core::SIMD_REDUCE_XOR {
                acc = acc ^ a;
            } else if add {
                acc = trunc_bits(acc.wrapping_add(a), ab);
            } else if mul {
                acc = trunc_bits(acc.wrapping_mul(a), ab);
            } else {
                let x = lane_val(acc, ab, sg);
                let y = lane_val(a, ab, sg);
                let less = pick_bool(sg, y < x, y as u64 < x as u64);
                acc = pick_u64(less == (c == core::SIMD_REDUCE_MIN), a, acc);
            }
        }
        self.vals.truncate(w0 as usize);
        self.put(dst, acc);
        return true;
    }

    // The index forms (`swizzle`, `shuffle`, `swizzle_or_zero`, `swizzle_oob`) and `compress`,
    // `expand`.
    fn vrearrange(self: &mut Self, b: &Body, t: Inst, c: u8, w: &[u32; 4], ty: &[u8; 4], dst: u32) bool {
        let rule = core::simd_op(c).rule;
        let vt = pick_u8(rule == core::SR_MASKED, ty[1], ty[0]);
        let lt = lane_type(vt);
        let lb = type_bits(lt, 8);
        let n = lanes(vt);
        if rule == core::SR_MASKED {
            // compress: the active lanes of v from position 0; expand: active lane i takes the next
            // packed lane. The rest come from `fill`.
            for i in 0..n {
                let x = get_lane(&self.vals, w[2], i, lb);
                set_lane(&mut self.vals, dst, i, lb, x);
            }
            let m = self.vals[w[0] as usize];
            let mut k: u32 = 0;
            for i in 0..n {
                if (m >> i as u64 & 1) != 0 {
                    let (to, from) = if c == core::SIMD_COMPRESS {
                        (k, i)
                    } else {
                        (i, k)
                    };
                    let x = get_lane(&self.vals, w[1], from, lb);
                    set_lane(&mut self.vals, dst, to, lb, x);
                    k += 1;
                }
            }
            return true;
        }
        let cnt = if rule == core::SR_INDEX {
            b.pool[t.c as usize]
        } else {
            lanes(ty[1])
        };
        let ib = if rule == core::SR_RT_INDEX {
            type_bits(lane_type(ty[1]), 8)
        } else {
            0
        };
        let mut bits: u64 = 0;
        for i in 0..cnt {
            let k = if rule == core::SR_INDEX {
                b.pool[(t.c + 1 + i) as usize] as u64
            } else {
                get_lane(&self.vals, w[1], i, ib)
            };
            if c == core::SIMD_SWIZZLE_OOB {
                bits = bits | pick_u64(k >= n as u64, 1, 0) << i as u64;
                continue;
            }
            let x = if k < n as u64 {
                get_lane(&self.vals, w[0], k as u32, lb)
            } else if c == core::SIMD_SHUFFLE {
                get_lane(&self.vals, w[1], (k - n as u64) as u32, lb)
            } else {
                0
            };
            set_lane(&mut self.vals, dst, i, lb, x);
        }
        if c == core::SIMD_SWIZZLE_OOB {
            self.put(dst, bits);
        }
        return true;
    }
}

// Whether the exact sum (`add`) or product of the `n` integer lanes of `lb` bits (signed `sg`) at
// word `w` fits their type. The sum runs in 128 bits (`hi`:`lo`); a product with no zero lane only
// grows in magnitude, so one past 64 bits never fits.
const fn exact_fits(add: bool, vals: &Vector<u64>, w: u32, n: u32, lb: u32, sg: bool) bool {
    let mut lo: u64 = pick_u64(add, 0, 1);
    let mut hi: i64 = 0;
    let mut neg = false;
    let mut over = false;
    for i in 0..n {
        let a = lane_val(get_lane(vals, w, i, lb), lb, sg);
        if add {
            let s = lo.wrapping_add(a as u64);
            hi = hi + pick_i64(sg && a < 0, -1, 0) + pick_i64(s < lo, 1, 0);
            lo = s;
            continue;
        }
        let mag = pick_u64(sg && a < 0, (a as u64).wrapping_neg(), a as u64);
        if mag == 0 {
            return true;
        }
        neg = neg != (sg && a < 0);
        over = over || lo > 0xFFFFFFFFFFFFFFFFu64 / mag;
        lo = lo.wrapping_mul(mag);
    }
    if add {
        return pick_bool(
            sg,
            hi == lo as i64 >> 63 && lane_fits(lo as i64, lb, true),
            hi == 0 && (lb == 64 || lo >> lb as u64 == 0),
        );
    }
    let mut lim = 1u64 << (lb - 1) as u64;
    if !sg {
        lim = lim - 1 + lim;
    }
    return !over && (!sg && lo <= lim || sg && (lo < lim || neg && lo == lim));
}

extend Eval {
    // Count one malloc-family call of `n` bytes when the accounting is on.
    const fn count_alloc(self: &mut Self, n: u64) {
        if self.acct_on {
            self.acct_calls += 1;
            self.acct_bytes = self.acct_bytes.wrapping_add(n);
        }
    }
}
