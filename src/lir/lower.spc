// Core IR to LIR. The C emitter calls `body` after it renders a function or closure body, with its
// substitutions still bound, so the lowering reads every type, layout and symbol the C path read.
// A scalar local whose address the body never takes becomes SSA values (Braun et al., "Simple and
// Efficient Construction of Static Single Assignment Form", CC 2013, with the whole CFG known: a
// phi is a parameter of its block, and the trivial ones go at the end); any other local is a stack
// slot, or the memory a parameter or the result points at. Checks become branches to one cold
// `panic` block per message and location. Aggregates pass as pointers to copies the callee owns,
// an aggregate result through a pointer the caller passes last.
import lir::ir as *;
import ast::ast as *;
import emit::cemit as cbe;
import emit::mangle as mbe;
import ir::core as irc;
import ir::interp as iri;
import ir::layout as lay;
import lexer::token as tok;
import lexer::token_type as tt;
import module::loader as loader;
import target::table as tgt;
import target::intrin as intrin;
import utils::names as nm;
import std::float as fl;
import lir::verify as lv;
import lir::print as lp;
import lir::eval as le;
import stdlib;
import ir::print as irp;
import bindgen::bindgen as bg;
import typechecker::render as rnd;
import std::parallel::sync as psync;

// Value classes of a type.
const VC_ZST: u8 = 0; // no storage: unit, void, never, zero-sized
const VC_SCALAR: u8 = 1;
const VC_MEM: u8 = 2;

// A type as the lowering sees it.
struct TyI {
    pub(package) cls: u8,
    pub(package) mty: u8, // the machine type of a scalar
    pub(package) size: u32,
    pub(package) align: u32,
}

extend TyI as Copy {}

// Local kinds.
const LK_VAR: u8 = 0; // SSA variable `var`
const LK_MEM: u8 = 1; // memory at `addr` (a slot address, a parameter, the result pointer)
const LK_ZST: u8 = 2;
const LK_STATIC: u8 = 3; // an item's storage: `addr` filled on first use
const LK_CAP: u8 = 4; // a closure capture: env field `var` (its offset); by pointer when `byref`

struct LInfo {
    pub(package) kind: u8,
    pub(package) byref: bool,
    pub(package) ti: TyI,
    pub(package) var: u32,
    pub(package) addr: Value,
}

extend LInfo as Copy {}

// A phi: a parameter of core block `blk` for variable `var`; its operands, one per predecessor
// of `blk`, from `ops` in `phi_ops`.
struct Phi {
    pub(package) blk: u32,
    pub(package) var: u32,
    pub(package) ty: u8,
    pub(package) ops: u32,
    pub(package) nops: u32,
    pub(package) repl: Value, // the value it is replaced by, VNONE while live
}

extend Phi as Copy {}

// A draft edge: to LIR block `to`; from core block `src` into core block `dst` (NONE for an edge
// inside one core block's chain or into a panic block).
struct DEdge {
    pub(package) to: u32,
    pub(package) src: u32,
    pub(package) dst: u32,
}

extend DEdge as Copy {}

// The draft value of phi `k`.
const PHI_TAG: u32 = 0x40000000;

/// A body the lowering refused: its symbol and the reason.
pub(package) struct LFail {
    pub(package) sym: String,
    pub(package) why: str<'static>,
}

/// A test function lowered: its symbol and its declaration, for the CTFE comparison.
pub(package) struct LTest {
    pub(package) sym: String,
    pub(package) m: ModuleId,
    pub(package) node: NodeId,
}

// The step budgets of the evaluator check: CTFE's per test (`probe_tests`) and the evaluator's
// (`ctfe_agrees`). The evaluator takes up to 1.4x CTFE's steps for a run both finish.
const CTFE_PROBE_STEPS: u32 = 1 << 18;
const EVAL_STEPS: u64 = 1 << 21;

/// How CTFE ended test `(m, node)`: its trap kind (`ir::interp::IT_TRAP_*`), the message, and the
/// line and column of the test's statement that trapped.
pub(package) struct CtfeRes {
    pub(package) m: ModuleId,
    pub(package) node: NodeId,
    pub(package) kind: u8,
    pub(package) msg: String, // a copy: the trap's text lives in the interpreter's memory, which the next run reuses
    pub(package) line: u32,
    pub(package) col: u32,
    pub(package) ffi: bool, // the run stopped at an extern function CTFE does not model
    pub(package) panics: bool, // `@test(should_panic)`
}

/// Run each test `(m, node)` of `tests` under CTFE, before the function syntax is released.
pub(package) fn probe_tests(pk: *const loader::Package, tests: &Vector<u64>, panics: &Vector<bool>) Vector<CtfeRes> {
    let mut out = Vector::<CtfeRes>::with_capacity(tests.len());
    if tests.len() == 0 {
        return out;
    }
    let mut it = iri::interp_new(pk);
    // Every module is typed: the conformance and method lookups memoize, as the emission's do.
    it.all_typed = true;
    // Of the math and std tests CTFE finishes in its default budget, 18 of 626 take more steps; a run to
    // that budget costs 8x more.
    it.max_steps = CTFE_PROBE_STEPS;
    for i in 0..tests.len() {
        let m = (tests[i] >> 32) as ModuleId;
        let n = tests[i] as NodeId;
        let k = it.probe_test(m, n);
        let mut r = CtfeRes {
            m: m,
            node: n,
            kind: k,
            msg: String::from_str(it.trap),
            line: 0,
            col: 0,
            ffi: it.ffi,
            panics: panics[i],
        };
        if k != iri::IT_TRAP_NONE {
            line_col(unsafe (*pk).modules.at(m as usize).source.as_str(), it.trap_span.start, &mut r.line, &mut r.col);
        }
        out.push(r);
    }
    return out;
}

/// The lowering of one emitter's bodies into its package.
pub(package) struct Lower {
    pub(package) pkg: Package,
    pub(package) fails: Vector<LFail>,
    pub(package) tests: Vector<LTest>,
    /// The function symbols lowered since the last `claim`.
    pend: Vector<u32>,
    /// The bodies since the last `claim` that were lowered already (a cached module's LIR holds them).
    pend_known: u32,
    /// The function symbols a cached module's LIR restored (`load_part`): optimized already.
    pub(package) loaded: Vector<u32>,
    /// The restored ones not lowered again since (`body`).
    relower: Set<u32>,
    pend_c: str<'static>, // what in them no object defines (a C header's constant, an intrinsic), else empty
    pend_name: String, // the C name `pend_c` is about
    fails_seen: usize, // `fails` at the last claim
    /// The units a C chunk without a LIR body landed in, which do not compile, and why.
    pub(package) conly: Vector<u32>,
    pub(package) conly_why: Vector<String>,
    /// The CTFE outcome of each test (`probe_tests`) the check compares the evaluator's with.
    pub(package) ctfe: Vector<CtfeRes>,
    /// The build wraps on integer overflow (a profile without overflow checks).
    pub(package) wrap: bool,
    /// Bodies lowered and refused.
    pub(package) nbodies: u64,
    err: str<'static>,
    dump: String, // `SC_LIR_DUMP`: the body (or refusal reason) whose refusal prints its Core IR
    dbg: bool, // lowering the body `dump` names: report where it fails
    // ---- per body ----
    m: ModuleId,
    file: u32,
    b: Body,
    li: Vector<LInfo>,
    tcache: Map<u64, TyI>, // the classes of concrete types, for every body
    fcache: Map<u64, u64>, // the members of concrete aggregates (`fields_of`): start << 32 | count in `fpool`
    fpool: Vector<FieldAt>,
    bm: ModuleId, // the module of the body being lowered: the pool grounded member types go to
    fl_depth: u32, // the nesting of `fields_layout`
    pmty: u8, // `arg_mode`: the machine type of the parameter's scalar type, T_NONE when unknown
    psgn: bool, // `arg_mode`: the parameter's scalar type is signed
    ind_m: ModuleId, // `arg_mode` of an indirect call: the callee's type, in `ind_m`; TYPE_NONE for a
    ind_t: TypeId, // direct call
    binds: Vector<mbe::MSub>, // scratch: a generic callee's bindings
    td: Tidy, // scratch of `tidy`
    lays: Map<u64, u32>, // the body's layout records by content hash
    var_ty: Vector<u8>,
    spc: u32, // the safepoint counter's variable, NONE without one
    defs: Map<u64, Value>,
    cv: Vector<u64>, // per variable: view << 32 | its value at the current point, valid in view `view`
    view: u32, // the run of blocks lowered last, each the one predecessor of the next
    rpo: Vector<u32>, // per core block (and the virtual entry, 0): its position in `order` plus one
    idom: Vector<u32>, // per core block (and the virtual entry): its immediate dominator
    hdr_before: Vector<u32>, // per position: the loop headers (a predecessor not before them) before it
    wpos: Vector<Vector<u32>>, // per variable: the positions of the blocks that write it, ascending
    phis: Vector<Phi>,
    phi_ops: Vector<Value>,
    lblk: Vector<u32>, // per core block: its LIR block, NONE when unreachable
    npred: Vector<u32>, // per core block (and the virtual entry): predecessor range in `preds`
    preds: Vector<u32>,
    edges: Vector<DEdge>,
    cur: u32, // the core block being lowered (`virt` in the entry block)
    virt: u32,
    panics: Map<u64, u32>,
    pan_list: Vector<u64>, // block << 32 | message, with the location in `pan_loc`
    pan_loc: Vector<u32>,
    sym_map: Map<u32, u32>,
    zeros: Map<u32, Value>, // per type: its zero in the entry block
    loc: u32, // the location of the statement being lowered
    loc_m: ModuleId, // `loc_at`'s last module and line index there
    loc_line: u32,
    ret_ptr: Value, // the result memory of an aggregate or multi-value result
    env: Value, // a closure's env pointer
    noret: bool,
    scratch: Vector<u32>,
    sbuf: String,
    escaped: Vector<bool>, // per local: its address escapes
    fresh: u32, // the local whose storage the block's last statement makes live (NONE: none)
    order: Vector<u32>, // the reachable core blocks in reverse postorder
    temps_free: Vector<u64>, // free temporary slots: size << 40 | align_log2 << 32 | slot
    temps_used: Vector<u64>, // the ones the current statement holds
    ret_off: Vector<u32>, // per result of a multi-value body: its offset in the result memory
    str_len: u64, // the length of the string `str_data` placed last
    hint: TyI, // the type an untyped constant operand takes: its destination's
    upack: Map<u32, u64>, // per untyped local a call fills: its layout (NONE: zero-sized) << 32 | its offsets in `uoffs`
    uoffs: Vector<u32>,
}

extend Lower {
    pub(package) fn new(ptr_bytes: u32, wrap: bool) Lower {
        return Lower {
            pkg: Package::new(ptr_bytes),
            fails: Vector::<LFail>::new(),
            tests: Vector::<LTest>::new(),
            pend: Vector::<u32>::new(),
            pend_known: 0,
            loaded: Vector::<u32>::new(),
            relower: Set::<u32>::new(),
            pend_c: "",
            pend_name: String::new(),
            fails_seen: 0,
            conly: Vector::<u32>::new(),
            conly_why: Vector::<String>::new(),
            ctfe: Vector::<CtfeRes>::new(),
            wrap: wrap,
            nbodies: 0,
            err: "",
            dump: stdlib::get_env("SC_LIR_DUMP").unwrap_or(String::new()),
            dbg: false,
            m: 0,
            file: 0,
            b: Body::new(),
            li: Vector::<LInfo>::new(),
            tcache: Map::<u64, TyI>::new(),
            fcache: Map::<u64, u64>::new(),
            fpool: Vector::<FieldAt>::new(),
            bm: 0,
            fl_depth: 0,
            pmty: T_NONE,
            psgn: false,
            ind_m: 0,
            ind_t: TYPE_NONE,
            binds: Vector::<mbe::MSub>::new(),
            td: Tidy::new(),
            lays: Map::<u64, u32>::new(),
            var_ty: Vector::<u8>::new(),
            spc: NONE,
            defs: Map::<u64, Value>::new(),
            cv: Vector::<u64>::new(),
            view: 0,
            rpo: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            hdr_before: Vector::<u32>::new(),
            wpos: Vector::<Vector<u32>>::new(),
            phis: Vector::<Phi>::new(),
            phi_ops: Vector::<Value>::new(),
            lblk: Vector::<u32>::new(),
            npred: Vector::<u32>::new(),
            preds: Vector::<u32>::new(),
            edges: Vector::<DEdge>::new(),
            cur: 0,
            virt: 0,
            panics: Map::<u64, u32>::new(),
            pan_list: Vector::<u64>::new(),
            pan_loc: Vector::<u32>::new(),
            sym_map: Map::<u32, u32>::new(),
            zeros: Map::<u32, Value>::new(),
            loc: 0,
            loc_m: 0,
            loc_line: NONE,
            ret_ptr: VNONE,
            env: VNONE,
            noret: false,
            scratch: Vector::<u32>::new(),
            sbuf: String::new(),
            escaped: Vector::<bool>::new(),
            fresh: NONE,
            order: Vector::<u32>::new(),
            temps_free: Vector::<u64>::new(),
            temps_used: Vector::<u64>::new(),
            ret_off: Vector::<u32>::new(),
            str_len: 0,
            hint: TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 },
            upack: Map::<u32, u64>::new(),
            uoffs: Vector::<u32>::new(),
        };
    }

    // The package and a module's syntax: the emitter only reads them, so they outlive its borrows.
    const fn p(c: &cbe::CEmit) &'static loader::Package {
        return unsafe &*c.pkg;
    }

    const fn ast(c: &cbe::CEmit, m: ModuleId) &'static Ast {
        return unsafe &*(*c.pkg).module_ast_const(m);
    }

    const fn ptr_int(self: &Self) u8 {
        return ast::pick(self.pkg.ptr_bytes == 8, T_I64, T_I32);
    }

    const fn fail(self: &mut Self, why: str<'static>) bool {
        if self.err.len() == 0 {
            self.err = why;
        }
        return false;
    }

    // ---- Types ----

    // The type `(m, t)` under the active substitutions.
    fn ty(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, t: TypeId, out: &mut TyI) bool {
        if t == TYPE_NONE {
            *out = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
            return true;
        }
        let key = m as u64 << 32 | t as u64;
        switch self.tcache.get(&key) {
            Some(v) => {
                *out = *v;
                return true;
            },
            None => {},
        };
        if !self.ty_raw(c, m, t, out) {
            return false;
        }
        // A type naming a parameter means what the bindings in place make it.
        if Lower::ast(c, m).type_concrete(t) {
            self.tcache.insert(key, *out);
        }
        return true;
    }

    fn ty_raw(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, t: TypeId, out: &mut TyI) bool {
        let mut rm = m;
        let mut rt = t;
        if !c.mg.resolve(m, t, &mut rm, &mut rt) {
            rm = m;
            rt = t;
        }
        let y = *Lower::ast(c, rm).type_at(rt);
        let pb = self.pkg.ptr_bytes;
        let ptr = TyI { cls: VC_SCALAR, mty: T_PTR, size: pb, align: pb };
        if y.kind == TypeKind::TYPE_BUILTIN {
            let bt = y.as_data.builtin;
            *out = if bt == BuiltinType::BT_VOID {
                TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
            } else if bt == BuiltinType::BT_C32 {
                TyI { cls: VC_MEM, mty: T_NONE, size: 8, align: 4 };
            } else if bt == BuiltinType::BT_C64 {
                TyI { cls: VC_MEM, mty: T_NONE, size: 16, align: 8 };
            } else if bt == BuiltinType::BT_VALIST {
                let vb = tgt::callconv_of(Lower::p(c).build_target, Lower::p(c).arch).va_list_bytes as u32;
                TyI { cls: VC_MEM, mty: T_NONE, size: vb, align: pb };
            } else {
                let mt = self.builtin_mty(bt);
                TyI { cls: VC_SCALAR, mty: mt, size: type_bytes(mt, pb), align: type_bytes(mt, pb) };
            };
            return true;
        }
        if y.kind == TypeKind::TYPE_NEVER {
            *out = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            *out = ptr;
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_SLICE {
            *out = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * pb, align: pb };
            return true;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let mut tys = Vector::<TypeId>::new();
            let mut by_ref: u64 = 0;
            if !y.fn_sig() && Lower::ast(c, y.module).closure_env(y.as_data.decl, &mut tys, &mut by_ref) {
                return self.mem_ty(c, rm, rt, out);
            }
            *out = ptr;
            return true;
        }
        if y.kind == TypeKind::TYPE_SIMD || y.kind == TypeKind::TYPE_MASK {
            let n = c.mg.arr_len(rm, &y);
            if n < 1 {
                return self.fail("vector-lanes");
            }
            if y.kind == TypeKind::TYPE_MASK {
                let mt = if n <= 8 {
                    T_I8;
                } else if n <= 16 {
                    T_I16;
                } else if n <= 32 {
                    T_I32;
                } else {
                    T_I64;
                };
                *out = TyI { cls: VC_SCALAR, mty: mt, size: type_bytes(mt, pb), align: type_bytes(mt, pb) };
                return true;
            }
            let mut el = TyI { cls: 0 };
            if !self.ty(c, rm, y.as_data.arr.elem, &mut el) || el.cls != VC_SCALAR || el.mty == T_PTR || is_vec(el.mty) {
                return self.fail("vector-lane-type");
            }
            let vt = vec_type(el.mty, n as u32);
            let lo = c.mg.layout_sub(rm, rt);
            if vt == T_NONE || !lo.ok {
                return self.fail("vector-type");
            }
            *out = TyI { cls: VC_SCALAR, mty: vt, size: lo.size as u32, align: lo.align as u32 };
            return true;
        }
        if y.kind == TypeKind::TYPE_ENUM && !Lower::ast(c, y.module).enum_has_payload(y.as_data.decl) {
            *out = TyI { cls: VC_SCALAR, mty: T_I32, size: 4, align: 4 };
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *Lower::ast(c, rm).instance(y.as_data.inst);
            let da = Lower::ast(c, it.module);
            if da.at_const(it.decl).kind == NodeKind::NODE_ENUM && !da.enum_has_payload(it.decl) {
                *out = TyI { cls: VC_SCALAR, mty: T_I32, size: 4, align: 4 };
                return true;
            }
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            // A C value (`@layout`): the scalar its header's typedef names, which C passes as that scalar
            // (a struct of it may travel otherwise: Microsoft x64), else memory of its layout, whose
            // leaves are unknown.
            if !self.mem_ty(c, rm, rt, out) {
                return false;
            }
            let k = Lower::p(c).opaque_cls.get(&(y.module as u64 << 32 | y.as_data.decl as u64));
            let cl = if k.is_some() {
                *k.unwrap();
            } else {
                bg::SC_NONE;
            };
            let n = out.size;
            // A vector (`arm_neon.h`'s `int8x16_t`, `immintrin.h`'s `__m256`) of 2 or more lanes.
            let el = switch cl {
                bg::SC_V8 => T_I8,
                bg::SC_V16 => T_I16,
                bg::SC_V32 => T_I32,
                bg::SC_V64 => T_I64,
                bg::SC_VF32 => T_F32,
                bg::SC_VF64 => T_F64,
                _ => T_NONE,
            };
            let eb = ast::pick(el == T_NONE, 0u32, type_bytes(el, pb));
            let mt = if cl == bg::SC_INT && n <= 8 && (n & n - 1) == 0 {
                ast::pick(n == 8, T_I64, ast::pick(n == 4, T_I32, ast::pick(n == 2, T_I16, T_I8)));
            } else if cl == bg::SC_F32 && n == 4 {
                T_F32;
            } else if cl == bg::SC_F64 && n == 8 {
                T_F64;
            } else if eb != 0 && n >= 2 * eb && n / eb <= 64 && (n & n - 1) == 0 {
                vec_type(el, n / eb);
            } else {
                T_NONE;
            };
            if mt != T_NONE && is_vec(mt) {
                // A register type's own alignment (`@value`): a vector lives in memory between uses.
                *out = TyI { cls: VC_SCALAR, mty: mt, size: n, align: out.align };
            } else if mt != T_NONE && out.align == n {
                *out = TyI { cls: VC_SCALAR, mty: mt, size: n, align: n };
            }
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY || y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_INSTANCE {
            return self.mem_ty(c, rm, rt, out);
        }
        self.debug_ty(c, "type", rm, rt);
        return self.fail("type");
    }

    fn mem_ty(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId, out: &mut TyI) bool {
        let mut lo = c.mg.layout_sub(rm, rt);
        let y = *Lower::ast(c, rm).type_at(rt);
        let fun = y.kind == TypeKind::TYPE_FUNCTION;
        if !lo.ok && y.kind == TypeKind::TYPE_ARRAY && !lo.big {
            // The layout engine sizes no `dyn` element: the element's class, repeated.
            let n = c.mg.arr_len(rm, &y);
            let mut ei = TyI { cls: 0 };
            if n < 0 || !self.ty(c, rm, y.as_data.arr.elem, &mut ei) {
                return false;
            }
            lo = lay::Layout { ok: true, size: n as u64 * ei.size as u64, align: ei.align };
        } else if !lo.ok && (!lo.unbound || fun) && !lo.big {
            // The layout engine sizes no `void` member (C erases one), nor a closure environment
            // capturing a parameter: the members' own layout.
            lo = self.fields_layout(c, rm, rt);
        }
        if !lo.ok || lo.size > 0x7FFFFFFF {
            self.debug_ty(c, "layout", rm, rt);
            return self.fail("layout");
        }
        if lo.size == 0 {
            *out = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: lo.align as u32 };
            return true;
        }
        *out = TyI { cls: VC_MEM, mty: T_NONE, size: lo.size as u32, align: lo.align as u32 };
        return true;
    }

    const fn builtin_mty(self: &Self, bt: BuiltinType) u8 {
        if bt == BuiltinType::BT_BOOL || bt == BuiltinType::BT_CHAR || bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_U8 {
            return T_I8;
        }
        if bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_U16 {
            return T_I16;
        }
        if bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_U32 {
            return T_I32;
        }
        if bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_U64 {
            return T_I64;
        }
        if bt == BuiltinType::BT_ISIZE || bt == BuiltinType::BT_USIZE {
            return self.ptr_int();
        }
        if bt == BuiltinType::BT_F32 {
            return T_F32;
        }
        return T_F64;
    }

    // The resolved type `(m, t)`.
    fn resolved(c: &cbe::CEmit, m: ModuleId, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) Ty {
        *rm = m;
        *rt = t;
        if !c.mg.resolve(m, t, rm, rt) {
            *rm = m;
            *rt = t;
        }
        return *Lower::ast(c, *rm).type_at(*rt);
    }

    // Whether `(m, t)` is a signed integer (an integer vector's lanes, a char not).
    fn signed(c: &cbe::CEmit, m: ModuleId, t: TypeId) bool {
        let mut rm = m;
        let mut rt = t;
        let mut y = Lower::resolved(c, m, t, &mut rm, &mut rt);
        if y.kind == TypeKind::TYPE_SIMD {
            y = Lower::resolved(c, rm, y.as_data.arr.elem, &mut rm, &mut rt);
        }
        if y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_INSTANCE {
            return true; // a C enum is an int
        }
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bt = y.as_data.builtin;
        return bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE;
    }

    // The builtin of `(m, t)`, BT_VOID for another kind.
    fn builtin(c: &cbe::CEmit, m: ModuleId, t: TypeId) BuiltinType {
        if t == TYPE_NONE {
            return BuiltinType::BT_VOID;
        }
        let mut rm = m;
        let mut rt = t;
        let y = Lower::resolved(c, m, t, &mut rm, &mut rt);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return BuiltinType::BT_VOID;
        }
        return y.as_data.builtin;
    }

    // The name of the aggregate declaration of resolved `(rm, rt)` (an instance's generic one), "" else.
    fn agg_name(c: &cbe::CEmit, rm: ModuleId, rt: TypeId) str<'static> {
        let y = *Lower::ast(c, rm).type_at(rt);
        let mut dm = rm;
        let mut dn = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dm = y.module;
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *Lower::ast(c, rm).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
        } else {
            return "";
        }
        let a = Lower::ast(c, dm);
        let n = a.at_const(dn);
        if n.kind != NodeKind::NODE_STRUCT && n.kind != NodeKind::NODE_ENUM {
            return "";
        }
        let sp = a.at_const(a.ext_name(dn)).as_data.name.text;
        return Lower::p(c).modules.at(dm as usize).source.as_str().slice(sp.start as usize, sp.end as usize);
    }

    // The layout record of memory type `ti` of `(m, t)` in the body's pool: its size, alignment and,
    // up to 64 bytes, its scalar leaves.
    // The signature type of a parameter of memory class `ti` of `(m, t)`: an array passes as a pointer to
    // its elements (a C array parameter), any other aggregate as itself.
    fn param_sig(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, t: TypeId, ti: TyI) u32 {
        if Lower::is_array(c, m, t) {
            return T_PTR;
        }
        return AGG | self.layout_of(c, m, t, ti);
    }

    // Whether `bt` is an integer type, `char` included.
    const fn is_int_bt(bt: BuiltinType) bool {
        return bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE || bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE || bt == BuiltinType::BT_CHAR;
    }

    // Whether `(m, t)` resolves to `str`.
    fn is_str(c: &cbe::CEmit, m: ModuleId, t: TypeId) bool {
        let mut rm = m;
        let mut rt = TYPE_NONE;
        let y = Lower::resolved(c, m, t, &mut rm, &mut rt);
        return y.kind == TypeKind::TYPE_STRUCT && Lower::decl_name(c, y.module, y.as_data.decl) == "str";
    }

    // Whether `(m, t)` resolves to an array.
    fn is_array(c: &cbe::CEmit, m: ModuleId, t: TypeId) bool {
        let mut rm = m;
        let mut rt = TYPE_NONE;
        return t != TYPE_NONE && Lower::resolved(c, m, t, &mut rm, &mut rt).kind == TypeKind::TYPE_ARRAY;
    }

    // The layout record of aggregate `(m, t)`. The calling conventions classify one of at most 64 bytes by
    // its leaves: one whose leaves are unknown (an opaque type that is no scalar, nesting past 8) keeps
    // none, which `abi::unknown_class` reads; past 16 leaves it is no register aggregate, and the first 16
    // say so.
    fn layout_of(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, t: TypeId, ti: TyI) u32 {
        let mut leaves = Vector::<(u32, u8)>::new();
        if ti.size <= 64 && !self.leaves(c, m, t, 0, &mut leaves, 0) {
            leaves.truncate(ast::pick(leaves.len() > 16, 16usize, 0usize));
        }
        return self.layout(ti.size, log2(ti.align), &leaves);
    }

    // The body's layout record of `size` bytes aligned to `1 << al_log2` with `leaves`: one record per
    // distinct layout.
    fn layout(self: &mut Self, size: u32, al_log2: u32, leaves: &Vector<(u32, u8)>) u32 {
        let mut h = size as u64 << 8 | al_log2 as u64;
        for k in 0..leaves.len() {
            h = (h ^ (leaves[k].0 as u64 << 8 | leaves[k].1 as u64)).wrapping_mul(0x100000001B3u64);
        }
        if let Some(at) = self.lays.get(&h) {
            let l = (*at) as usize;
            let mut same = self.b.pool[l] == size && self.b.pool[l + 1] == al_log2 && self.b.pool[l + 2] as usize == leaves.len();
            for k in 0..leaves.len() {
                same = same && self.b.pool[l + 3 + 2 * k] == leaves[k].0 && self.b.pool[l + 4 + 2 * k] == leaves[k].1 as u32;
            }
            if same {
                return *at;
            }
        }
        let at = self.b.layout(size, al_log2, leaves[0..leaves.len()]);
        if !self.lays.contains_key(&h) {
            self.lays.insert(h, at);
        }
        return at;
    }

    // The leaves of a C record of layout `lay` (`bindgen::SC_REC`) at byte `off` into `out`, when the
    // header's size and alignment are the declared ones `ti`; false past 16 leaves.
    fn rec_leaves(lay: str, ti: TyI, off: u32, out: &mut Vector<(u32, u8)>) bool {
        let mut it = lay.split(" ");
        let size = it.next().unwrap_or("").parse_u64().unwrap_or(0);
        let align = it.next().unwrap_or("").parse_u64().unwrap_or(0);
        if size != ti.size as u64 || align != ti.align as u64 {
            return false;
        }
        // Each step takes one leaf of at most 17.
        while let Some(w) = it.next() {
            if out.len() > 16 {
                return false;
            }
            let at = w.slice(0, w.len() - 1).parse_u64().unwrap_or(0) as u32;
            let mty = switch w.byte_at(w.len() - 1) {
                b'b' => T_I8,
                b'h' => T_I16,
                b'w' => T_I32,
                b'q' => T_I64,
                b'f' => T_F32,
                b'd' => T_F64,
                _ => T_PTR,
            };
            out.push((off + at, mty));
        }
        return out.len() <= 16;
    }

    // The scalar leaves of `(m, t)` at byte `off` into `out` (struct fields, array elements, every
    // variant of an enum and member of a union, overlapping); false past 16 leaves.
    fn leaves(
        self: &mut Self,
        c: &mut cbe::CEmit,
        m: ModuleId,
        t: TypeId,
        off: u32,
        out: &mut Vector<(u32, u8)>,
        depth: u32,
    ) bool {
        if out.len() > 16 || depth > 8 {
            return false;
        }
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, m, t, &mut ti) {
            return false;
        }
        if ti.cls == VC_ZST {
            return true;
        }
        if ti.cls == VC_SCALAR {
            out.push((off, ti.mty));
            return true;
        }
        let mut rm = m;
        let mut rt = t;
        let y = Lower::resolved(c, m, t, &mut rm, &mut rt);
        if y.kind == TypeKind::TYPE_BUILTIN {
            // c32, c64: two floats; va_list: pointers.
            let bt = y.as_data.builtin;
            let ft = ast::pick(bt == BuiltinType::BT_C32, T_F32, T_F64);
            if bt == BuiltinType::BT_C32 || bt == BuiltinType::BT_C64 {
                out.push((off, ft));
                out.push((off + ti.size / 2, ft));
                return true;
            }
            for k in 0..ti.size / self.pkg.ptr_bytes {
                out.push((off + k * self.pkg.ptr_bytes, T_PTR));
            }
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_SLICE {
            out.push((off, T_PTR));
            out.push((off + self.pkg.ptr_bytes, ast::pick(y.kind == TypeKind::TYPE_DYN, T_PTR, self.ptr_int())));
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let n = c.mg.arr_len(rm, &y);
            let mut el = TyI { cls: 0 };
            if n < 0 || !self.ty(c, rm, y.as_data.arr.elem, &mut el) || el.size == 0 {
                return el.size == 0 && n >= 0;
            }
            for k in 0..n as u32 {
                if !self.leaves(c, rm, y.as_data.arr.elem, off + k * el.size, out, depth + 1) {
                    return false;
                }
            }
            return true;
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            let key = y.module as u64 << 32 | y.as_data.decl as u64;
            let k = Lower::p(c).opaque_cls.get(&key);
            if k.is_some() && *k.unwrap() == bg::SC_REC {
                return Lower::rec_leaves(Lower::p(c).opaque_lay.get(&key).unwrap().as_str(), ti, off, out);
            }
            // A C register tuple (`bindgen::SC_VTUPLE`): its 128-bit vectors.
            if k.is_none() || *k.unwrap() != bg::SC_VTUPLE || ti.size % 16 != 0 {
                return false;
            }
            for q in 0..ti.size / 16 {
                out.push((off + 16 * q, vec_type(T_I8, 16)));
            }
            return true;
        }
        // Structs, unions, tuples, enums with payloads and closure envs: each member at its offset.
        let mut fl = Vector::<FieldAt>::new();
        if !self.fields_of(c, rm, rt, &mut fl) {
            return false;
        }
        for k in 0..fl.len() {
            let f = fl[k];
            if f.t == TYPE_NONE {
                // An enum's tag or a capture by reference: its scalar alone.
                assert(f.mty != T_NONE, "lir: a member without a type is a scalar");
                out.push((off + f.off, f.mty));
            } else if !self.leaves(c, f.m, f.t, off + f.off, out, depth + 1) {
                return false;
            }
        }
        return true;
    }

    // ---- Members ----

    // Every member of aggregate `(rm, rt)` with its offset and type: a struct's or union's fields, a
    // tuple's members, a closure env's captures, an enum's tag then every variant's payload members.
    fn fields_of(self: &mut Self, c: &mut cbe::CEmit, rm0: ModuleId, rt0: TypeId, out: &mut Vector<FieldAt>) bool {
        // Grounded first: an instance's arguments may read the bindings in place (`Float<{E + 2}, ..>`
        // inside `Float<E, ..>`'s instance), which binding the instance's own parameters would shadow.
        let (rm, rt) = self.grounded(c, rm0, rt0);
        // A concrete aggregate's members are the same in every body.
        let key = rm as u64 << 32 | rt as u64;
        if let Some(v) = self.fcache.get(&key) {
            let at = (*v >> 32) as usize;
            for k in 0..(*v & 0xFFFFFFFF) as usize {
                out.push(self.fpool[at + k]);
            }
            return true;
        }
        let n0 = out.len();
        if !self.fields_of_i(c, rm, rt, out) {
            return false;
        }
        if Lower::ast(c, rm).type_concrete(rt) {
            self.fcache.insert(key, self.fpool.len() as u64 << 32 | (out.len() - n0) as u64);
            for k in n0..out.len() {
                self.fpool.push(out[k]);
            }
        }
        return true;
    }

    fn fields_of_i(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId, out: &mut Vector<FieldAt>) bool {
        let y = *Lower::ast(c, rm).type_at(rt);
        if y.kind == TypeKind::TYPE_FUNCTION {
            let a = Lower::ast(c, y.module);
            let cf = a.closure_fact(y.as_data.decl);
            if cf == null {
                return false;
            }
            let mut off: u32 = 0;
            for k in 0..unsafe (&*cf).ncaps {
                let ct = unsafe a.caps_of(cf)[k as usize].ty;
                let mut ti = TyI { cls: 0 };
                if !self.ty(c, y.module, ct, &mut ti) {
                    return false;
                }
                if ti.cls == VC_ZST {
                    continue;
                }
                let byref = ((unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps) >> k as u64 & 1) != 0;
                let sz = ast::pick(byref, self.pkg.ptr_bytes, ti.size);
                let al = ast::pick(byref, self.pkg.ptr_bytes, ti.align);
                off = round_up(off, al);
                out.push(
                    FieldAt {
                        m: y.module,
                        t: ast::pick(byref, TYPE_NONE, ct),
                        off: off,
                        idx: k,
                        node: NODE_NONE,
                        variant: NODE_NONE,
                        mty: ast::pick(byref, T_PTR, T_NONE),
                    },
                );
                off += sz;
            }
            return true;
        }
        let mut dm = rm;
        let mut dn = NODE_NONE;
        let mut nb: usize = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dm = y.module;
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *Lower::ast(c, rm).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
            nb = c.mg.push_generics(dm, Lower::ast(c, dm).ext(dn).aggregate.generics, rm, &it);
        } else {
            return false;
        }
        let ok = self.decl_fields(c, dm, dn, out);
        c.mg.pop_subs(nb);
        return ok;
    }

    // `fields_of` for declaration `(dm, dn)`, its generic parameters bound.
    fn decl_fields(self: &mut Self, c: &mut cbe::CEmit, dm: ModuleId, dn: NodeId, out: &mut Vector<FieldAt>) bool {
        let a = Lower::ast(c, dm);
        let n = a.at_const(dn);
        let ms = a.ext(dn).aggregate.members;
        if n.kind == NodeKind::NODE_ENUM {
            if !a.enum_has_payload(dn) {
                return false;
            }
            let mut el = EnumL { ok: false };
            if !self.enum_shape(c, dm, dn, &mut el) {
                return false;
            }
            if el.niche == lay::NK_NONE {
                let tag_t = ast::pick(a.enum_tag_is_byte(dn), T_I8, T_I32);
                out.push(
                    FieldAt {
                        m: dm,
                        t: TYPE_NONE,
                        off: 0,
                        idx: 0xFFFFFFFF,
                        node: NODE_NONE,
                        mty: tag_t,
                        variant: NODE_NONE,
                    },
                );
            }
            for i in 0..ms.len {
                let vid = unsafe a.list(ms)[i as usize];
                let pl = a.at_const(vid).as_data.variant.payload;
                let mut off: u32 = 0;
                for k in 0..pl.len {
                    let pid = unsafe a.list(pl)[k as usize];
                    let mt = a.member_ty(pid);
                    let mut ti = TyI { cls: 0 };
                    if mt == TYPE_NONE || !self.ty(c, dm, mt, &mut ti) {
                        return self.fail("payload-type");
                    }
                    off = round_up(off, ti.align);
                    let (gm, gt) = self.grounded(c, dm, mt);
                    out.push(FieldAt { m: gm, t: gt, off: el.payload_off + off, idx: k, node: pid, variant: vid });
                    off += ti.size;
                }
            }
            return true;
        }
        let is_union = a.ext(dn).aggregate.is_union;
        let is_tuple = a.ext(dn).aggregate.is_tuple;
        let packed = a.attr_of(dn, AttrKind::ATTR_PACKED) != null;
        let mut off: u32 = 0;
        let mut idx: u32 = 0;
        for i in 0..ms.len {
            let fid = unsafe a.list(ms)[i as usize];
            if !is_tuple && a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let mt = a.member_ty(fid);
            let mut ti = TyI { cls: 0 };
            if mt == TYPE_NONE || !self.ty(c, dm, mt, &mut ti) {
                return self.fail("field-type");
            }
            let al = ast::pick(packed, 1u32, ti.align);
            if !is_union {
                off = round_up(off, al);
            }
            let (gm, gt) = self.grounded(c, dm, mt);
            out.push(
                FieldAt {
                    m: gm,
                    t: gt,
                    off: ast::pick(is_union, 0u32, off),
                    idx: idx,
                    node: fid,
                    packed: packed,
                    variant: NODE_NONE,
                },
            );
            if !is_union {
                off += ti.size;
            }
            idx += 1;
        }
        return true;
    }

    // The shape of payload enum `(dm, dn)` (its generic parameters bound).
    fn enum_shape(self: &mut Self, c: &mut cbe::CEmit, dm: ModuleId, dn: NodeId, out: &mut EnumL) bool {
        let a = Lower::ast(c, dm);
        let ms = a.ext(dn).aggregate.members;
        let mut ns = NODE_NONE;
        let mut nn = NODE_NONE;
        let nk = c.mg.niche(dm, dn, &mut ns, &mut nn);
        if nk != lay::NK_NONE {
            let mt = a.member_ty(unsafe a.list(a.at_const(ns).as_data.variant.payload)[0]);
            let mut ti = TyI { cls: 0 };
            if !self.ty(c, dm, mt, &mut ti) {
                return self.fail("payload-type");
            }
            *out = EnumL {
                ok: true,
                payload_off: 0,
                tag: T_NONE,
                size: round_up(ti.size, ti.align),
                align: ti.align,
                niche: nk,
                some: ns,
                none: nn,
                vm: dm,
            };
            return true;
        }
        let mut usize9: u32 = 0;
        let mut ualign: u32 = 1;
        for i in 0..ms.len {
            let pl = a.at_const(unsafe a.list(ms)[i as usize]).as_data.variant.payload;
            let mut off: u32 = 0;
            let mut al: u32 = 1;
            for k in 0..pl.len {
                let mt = a.member_ty(unsafe a.list(pl)[k as usize]);
                let mut ti = TyI { cls: 0 };
                if mt == TYPE_NONE || !self.ty(c, dm, mt, &mut ti) {
                    return self.fail("payload-type");
                }
                off = round_up(off, ti.align) + ti.size;
                al = ast::pick(ti.align > al, ti.align, al);
            }
            off = round_up(off, al);
            usize9 = ast::pick(off > usize9, off, usize9);
            ualign = ast::pick(al > ualign, al, ualign);
        }
        let tag: u32 = ast::pick(a.enum_tag_is_byte(dn), 1u32, 4u32);
        out.ok = true;
        out.payload_off = round_up(tag, ualign);
        out.tag = ast::pick(tag == 1, T_I8, T_I32);
        out.align = ast::pick(ualign > tag, ualign, tag);
        out.size = round_up(out.payload_off + usize9, out.align);
        return true;
    }

    // The offset and type of member `pj` (a PJ_FIELD) of aggregate `(rm, rt)`, after a downcast to
    // `variant` (NODE_NONE: none).
    fn member(
        self: &mut Self,
        c: &mut cbe::CEmit,
        rm: ModuleId,
        rt: TypeId,
        pj: irc::Projection,
        variant: NodeId,
        out: &mut FieldAt,
    ) bool {
        let mut fl = Vector::<FieldAt>::new();
        if !self.fields_of(c, rm, rt, &mut fl) {
            if self.dbg {
                eprint("member-of: kind {} err {}\n", Lower::ast(c, rm).type_at(rt).kind as u32, self.err);
            }
            return self.fail("member-of");
        }
        for k in 0..fl.len() {
            let f = fl[k];
            if f.idx == 0xFFFFFFFF {
                continue;
            }
            if variant != NODE_NONE && f.variant != variant {
                continue;
            }
            if variant == NODE_NONE && f.variant != NODE_NONE {
                continue;
            }
            let hit = if pj.sub != NODE_NONE && pj.data != irc::PJ_UNION_FIELD {
                f.node == pj.sub || f.node == NODE_NONE && f.idx == pj.data;
            } else if pj.data == irc::PJ_UNION_FIELD {
                f.node == pj.sub;
            } else {
                f.idx == pj.data;
            };
            if hit {
                *out = f;
                return true;
            }
        }
        return self.fail("member");
    }

    // The offset and machine type of a field named `name` of aggregate `(rm, rt)` (`ptr`, `len`,
    // `data`, `cap`); false when it has none.
    fn named_field(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId, name: str, out: &mut FieldAt) bool {
        let mut fl = Vector::<FieldAt>::new();
        let y = *Lower::ast(c, rm).type_at(rt);
        if y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_SLICE {
            let second = name == "len" || name == "vt";
            *out = FieldAt {
                m: rm,
                t: TYPE_NONE,
                off: ast::pick(second, self.pkg.ptr_bytes, 0u32),
                mty: ast::pick(name == "len", self.ptr_int(), T_PTR),
                variant: NODE_NONE,
                node: NODE_NONE,
            };
            return name == "ptr" || name == "len" || name == "data" || name == "vt";
        }
        if !self.fields_of(c, rm, rt, &mut fl) {
            return false;
        }
        let mut dm = rm;
        if y.kind == TypeKind::TYPE_INSTANCE {
            dm = Lower::ast(c, rm).instance(y.as_data.inst).module;
        } else if y.kind == TypeKind::TYPE_STRUCT {
            dm = y.module;
        }
        let a = Lower::ast(c, dm);
        let src = Lower::p(c).modules.at(dm as usize).source.as_str();
        for k in 0..fl.len() {
            let f = fl[k];
            if f.node == NODE_NONE || a.at_const(f.node).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let sp = a.at_const(a.at_const(f.node).as_data.field.name).as_data.name.text;
            if src.slice(sp.start as usize, sp.end as usize) == name {
                *out = f;
                return true;
            }
        }
        return false;
    }
}

// A member of an aggregate: its type `(m, t)` (TYPE_NONE: a tag or pointer of machine type `mty`),
// its byte offset, its index, its declaration node and, in an enum, its variant.
struct FieldAt {
    pub(package) m: ModuleId,
    pub(package) t: TypeId,
    pub(package) off: u32,
    pub(package) idx: u32,
    pub(package) node: NodeId,
    pub(package) variant: NodeId,
    pub(package) mty: u8,
    pub(package) packed: bool,
}

extend FieldAt as Copy {}

struct EnumL {
    pub(package) ok: bool,
    pub(package) payload_off: u32,
    pub(package) tag: u8,
    pub(package) size: u32,
    pub(package) align: u32,
    /// The niche kind (`lay::niche_kind`): no tag, a null first pointer word of the payload is
    /// `none`; `some` and `none` are the two variants.
    pub(package) niche: u8,
    pub(package) some: NodeId,
    pub(package) none: NodeId,
    pub(package) vm: ModuleId, // the module of `some` and `none`
}

/// `v` rounded up to a multiple of `a`.
pub(package) const fn round_up(v: u32, a: u32) u32 {
    if a <= 1 {
        return v;
    }
    return (v + a - 1) / a * a;
}

/// The log2 of power of two `a`.
pub(package) const fn log2(a: u32) u32 {
    let mut n: u32 = 0;
    while n < 31 && 1u32 << n < a {
        n += 1;
    }
    return n;
}

// A place: SSA variable `var`, memory at `addr`, a value `val` (a folded constant), or no storage.
const PR_VAR: u8 = 0;
const PR_MEM: u8 = 1;
const PR_VAL: u8 = 2;
const PR_ZST: u8 = 3;

struct PlaceRef {
    pub(package) kind: u8,
    pub(package) var: u32,
    pub(package) addr: Value,
    pub(package) m: ModuleId,
    pub(package) t: TypeId,
    pub(package) ti: TyI,
    pub(package) packed: bool,
}

extend PlaceRef as Copy {}

extend Lower {
    // ---- Building ----

    fn inst(self: &mut Self, op: u8, ty: u8, aux: u16, a: u32, b: u32, c: u32) Value {
        return self.b.emit(Inst { op: op, ty: ty, aux: aux, a: a, b: b, c: c }, self.loc);
    }

    fn iconst(self: &mut Self, ty: u8, v: u64) Value {
        let bits = type_bits(ty, self.pkg.ptr_bytes);
        let u = if bits >= 64 {
            v;
        } else {
            v & (1u64 << bits as u64) - 1;
        };
        return self.inst(O_ICONST, ty, 0, u as u32, (u >> 32) as u32, VNONE);
    }

    fn fconst(self: &mut Self, ty: u8, bits: u64) Value {
        return self.inst(O_FCONST, ty, 0, bits as u32, (bits >> 32) as u32, VNONE);
    }

    fn load(self: &mut Self, ty: u8, addr: Value, off: u32, packed: bool) Value {
        let al = ast::pick(packed, 0u16, log2(type_align(ty, self.pkg.ptr_bytes)) as u16);
        let (a, o) = self.fold_addr(addr, off);
        return self.inst(O_LOAD, ty, al, a, VNONE, o);
    }

    fn store(self: &mut Self, v: Value, addr: Value, off: u32, packed: bool) {
        let ty = self.vty(v);
        let al = ast::pick(packed, 0u16, log2(type_align(ty, self.pkg.ptr_bytes)) as u16);
        let (a, o) = self.fold_addr(addr, off);
        let _ = self.inst(O_STORE, T_NONE, al, a, v, o);
    }

    // Address `addr` + `off` with a constant `ptradd` behind `addr` folded into the offset: its base, and
    // the two offsets' sum when it fits.
    const fn fold_addr(self: &Self, addr: Value, off: u32) (Value, u32) {
        if (addr & (VPARAM | VFLAG)) != 0 || addr == VNONE {
            return addr, off;
        }
        let d = self.b.insts[addr as usize];
        if d.op != O_PTRADD || d.b != VNONE || d.c > 0xFFFFFFFF - off {
            return addr, off;
        }
        return d.a, d.c + off;
    }

    fn ptradd(self: &mut Self, base0: Value, ix: Value, scale: u32, off0: u32) Value {
        let (base, off) = self.fold_addr(base0, off0);
        if ix != VNONE && (ix & (VPARAM | VFLAG)) == 0 && self.b.insts[ix as usize].op == O_ICONST {
            // A constant index (sign-extended from its type) at or above zero: its bytes join the offset
            // when they fit.
            let k = self.b.insts[ix as usize].b as u64 << 32 | self.b.insts[ix as usize].a as u64;
            let top = 1u64 << (type_bits(self.vty(ix), self.pkg.ptr_bytes) - 1) as u64;
            // Inside a slot, only an element inside it: a bounds check guards the access of another.
            let mut room: u64 = 0xFFFFFFFF;
            if (base & (VPARAM | VFLAG)) == 0 && self.b.insts[base as usize].op == O_SLOTADDR {
                room = self.b.slots[self.b.insts[base as usize].a as usize].size;
            }
            if k < top && k < 0xFFFFFFFF && off as u64 <= room && (k + 1) * scale as u64 <= room - off as u64 {
                return self.ptradd(base, VNONE, 0, off + (k * scale as u64) as u32);
            }
        }
        if ix == VNONE && off == 0 {
            return base;
        }
        if ix != VNONE && scale == 0 {
            return self.ptradd(base, VNONE, 0, off);
        }
        if ix != VNONE && scale > 65535 {
            let s = self.iconst(self.ptr_int(), scale);
            let k = self.arith(O_MUL, ix, s);
            return self.inst(O_PTRADD, T_PTR, 1, base, k, off);
        }
        return self.inst(O_PTRADD, T_PTR, scale as u16, base, ix, off);
    }

    fn arith(self: &mut Self, op: u8, x: Value, y: Value) Value {
        return self.inst(op, self.vty(x), 0, x, y, VNONE);
    }

    fn icmp(self: &mut Self, cond: u16, x: Value, y: Value) Value {
        return self.inst(O_ICMP, T_I8, cond, x, y, VNONE);
    }

    // Copy a value of memory type `ti` from `src` to `dst` in units of its alignment (8 bytes at most),
    // each load (`load_side`) or each store volatile: one access per unit, in order.
    fn volatile_copy(self: &mut Self, dst: Value, src: Value, ti: TyI, load_side: bool) {
        let mut u: u32 = 8;
        while u > ti.align || ti.size % u != 0 {
            u = u / 2;
        }
        let ty = ast::pick(u == 8, T_I64, ast::pick(u == 4, T_I32, ast::pick(u == 2, T_I16, T_I8)));
        let al = log2(u) as u16;
        let lv = ast::pick(load_side, MEM_VOLATILE, 0u16);
        let sv = MEM_VOLATILE - lv;
        for i in 0..ti.size / u {
            let x = self.inst(O_LOAD, ty, al | lv, src, VNONE, i * u);
            let _ = self.inst(O_STORE, T_NONE, al | sv, dst, x, i * u);
        }
    }

    // IN_VOLATILE_STORE(p, v): `v` written where `p` points with volatile accesses. A zero-sized value
    // has no bytes to write.
    // Inline assembly (`O_ASM`): each output goes through its place's address, or a temporary slot
    // for a value local (written back after); each input is its value. The texts become messages.
    fn asm_stmt(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue) bool {
        let src = Lower::p(c).modules.at(rv.item.module as usize).source.as_str();
        let d = b.asms[rv.item.node as usize];
        let rec = self.b.pool.len() as u32;
        let mut t = String::new();
        if d.template.end > d.template.start {
            cbe::asm_bytes(src.slice(d.template.start as usize, d.template.end as usize), &mut t);
        }
        let tm = self.b.ref_msg(self.pkg.add_message(t.as_str()));
        self.b.pool.push(tm);
        self.b.pool.push(d.nout);
        self.b.pool.push(d.nin);
        self.b.pool.push(d.nclob);
        for k in 0..d.nout + d.nin + d.nclob {
            let cs = b.asm_spans[(d.cons + k) as usize];
            let mut s = String::new();
            cbe::asm_bytes(src.slice(cs.start as usize, cs.end as usize), &mut s);
            let m = self.b.ref_msg(self.pkg.add_message(s.as_str()));
            if k == d.nout {
                // The output types come after the output constraints: their slots, filled below.
                for _ in 0..d.nout {
                    self.b.pool.push(0);
                }
            }
            self.b.pool.push(m);
        }
        if d.nin + d.nclob == 0 {
            for _ in 0..d.nout {
                self.b.pool.push(0);
            }
        }
        let mut vals = Vector::<Value>::new();
        let mut backs = Vector::<(PlaceRef, Value, u8)>::new();
        for k in 0..d.nout {
            let op = b.operands[b.oper_pool[(rv.a + k) as usize] as usize];
            if op.kind != irc::OP_COPY && op.kind != irc::OP_MOVE {
                return self.fail("asm-out");
            }
            let mut p = PlaceRef { kind: 0 };
            if !self.place(c, b, op.data, &mut p) {
                return false;
            }
            if p.kind == PR_ZST || p.ti.cls != VC_SCALAR || p.ti.mty == T_I128 || is_vec(p.ti.mty) {
                return self.fail("asm-out-type");
            }
            self.b.pool[(rec + 4 + d.nout + k) as usize] = p.ti.mty;
            if p.kind == PR_MEM && !p.packed {
                vals.push(p.addr);
                continue;
            }
            let a = self.new_slot(p.ti);
            let cs = b.asm_spans[(d.cons + k) as usize];
            if src.slice(cs.start as usize, cs.end as usize).contains("+") {
                let cur = self.read(p);
                if cur == VNONE {
                    return false;
                }
                self.store(cur, a, 0, false);
            }
            vals.push(a);
            backs.push((p, a, p.ti.mty));
        }
        for k in 0..d.nin {
            let opid = b.oper_pool[(rv.a + d.nout + k) as usize];
            let mut vi = TyI { cls: 0 };
            if !self.ty(c, b.module, Lower::op_ty(b, opid), &mut vi) {
                return false;
            }
            if vi.cls != VC_SCALAR || vi.mty == T_I128 || is_vec(vi.mty) {
                return self.fail("asm-in-type");
            }
            let v = self.operand(c, b, opid);
            if v == VNONE {
                return false;
            }
            vals.push(v);
        }
        let at = self.b.pool_list(vals[0..vals.len()]);
        let _ = self.inst(O_ASM, T_NONE, 0, at, vals.len() as u32, rec);
        for k in 0..backs.len() {
            let (p, a, ty) = backs[k];
            let v = self.load(ty, a, 0, false);
            if !self.write(p, v) {
                return false;
            }
        }
        return true;
    }

    fn volatile_store(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue) bool {
        let vop = b.oper_pool[(rv.a + 1) as usize];
        let mut vi = TyI { cls: 0 };
        if !self.ty(c, b.module, Lower::op_ty(b, vop), &mut vi) {
            return false;
        }
        if vi.cls == VC_ZST {
            return true;
        }
        let a = self.operand(c, b, b.oper_pool[rv.a as usize]);
        if a == VNONE {
            return false;
        }
        if vi.cls == VC_MEM {
            let src = self.operand_addr(c, b, vop, vi);
            if src == VNONE {
                return false;
            }
            self.volatile_copy(a, src, vi, false);
            return true;
        }
        let v = self.operand(c, b, vop);
        if v == VNONE {
            return false;
        }
        let al = log2(type_align(vi.mty, self.pkg.ptr_bytes)) as u16;
        let _ = self.inst(O_STORE, T_NONE, al | MEM_VOLATILE, a, v, 0);
        return true;
    }

    fn memcpy(self: &mut Self, dst: Value, src: Value, n: u32) {
        if n == 0 || dst == src {
            return;
        }
        let k = self.iconst(self.ptr_int(), n);
        let _ = self.inst(O_MEMCPY, T_NONE, MEM_OVERLAP, dst, src, k);
    }

    fn memset0(self: &mut Self, dst: Value, n: u32) {
        if n == 0 {
            return;
        }
        let z = self.iconst(T_I8, 0);
        let k = self.iconst(self.ptr_int(), n);
        let _ = self.inst(O_MEMSET, T_NONE, 0, dst, z, k);
    }

    // The type of draft value `v`.
    const fn vty(self: &Self, v: Value) u8 {
        if (v & VPARAM) != 0 && (v & PHI_TAG) != 0 {
            return self.phis[(v & ~(VPARAM | PHI_TAG)) as usize].ty;
        }
        return self.b.type_of(v);
    }

    // Convert integer `v` to integer type `to`: sign or zero extend (`signed`), or truncate.
    fn int_to(self: &mut Self, v: Value, to: u8, signed: bool) Value {
        let from = self.vty(v);
        if from == to {
            return v;
        }
        if from == T_PTR || to == T_PTR {
            let op = ast::pick(from == T_PTR, O_PTRTOINT, O_INTTOPTR);
            let mid = ast::pick(from == T_PTR, self.ptr_int(), self.ptr_int());
            if from == T_PTR {
                let x = self.inst(O_PTRTOINT, mid, 0, v, VNONE, VNONE);
                return self.int_to(x, to, signed);
            }
            let x = self.int_to(v, mid, signed);
            return self.inst(op, T_PTR, 0, x, VNONE, VNONE);
        }
        let fb = type_bits(from, self.pkg.ptr_bytes);
        let tb = type_bits(to, self.pkg.ptr_bytes);
        if tb < fb {
            return self.inst(O_TRUNC, to, 0, v, VNONE, VNONE);
        }
        if tb == fb {
            return self.inst(O_BITCAST, to, 0, v, VNONE, VNONE);
        }
        return self.inst(ast::pick(signed, O_SEXT, O_ZEXT), to, 0, v, VNONE, VNONE);
    }

    // A new LIR block of no parameters.
    fn block(self: &mut Self) u32 {
        let none: []u8 = [];
        return self.b.add_block(none);
    }

    fn edge(self: &mut Self, to: u32, src: u32, dst: u32) u32 {
        self.edges.push(DEdge { to: to, src: src, dst: dst });
        return self.edges.len() as u32 - 1;
    }

    // Continue in a new block after a branch to `other` taken when `cond` is not 0 (`taken`) or 0.
    fn split(self: &mut Self, cond: Value, other: u32, taken: bool) {
        let next = self.block();
        let eo = self.edge(other, NONE, NONE);
        let en = self.edge(next, NONE, NONE);
        let _ = if taken {
            self.inst(O_BR, T_NONE, 0, cond, eo, en);
        } else {
            self.inst(O_BR, T_NONE, 0, cond, en, eo);
        };
        self.b.begin(next);
    }

    // Trap with `msg` when `fail` is not 0.
    fn check(self: &mut Self, fail: Value, msg: str) {
        let pb = self.panic_block(msg);
        self.split(fail, pb, true);
    }

    // The cold block that panics with `msg` at the current location: one per message and location.
    fn panic_block(self: &mut Self, msg: str) u32 {
        let mid = self.pkg.add_message(msg);
        let key = mid as u64 << 32 | self.loc as u64;
        switch self.panics.get(&key) {
            Some(k) => {
                return *k;
            },
            None => {},
        };
        let k = self.block();
        self.b.blocks.index_mut(k as usize).flags = BLOCK_COLD;
        self.panics.insert(key, k);
        self.pan_list.push(k as u64 << 32 | mid as u64);
        self.pan_loc.push(self.loc);
        return k;
    }

    // The body's number of the package symbol named `name`, made a function or data symbol when new.
    fn sym(self: &mut Self, name: str, kind: u8) u32 {
        let s = self.pkg.symbol(name, kind);
        return self.sym_of(s);
    }

    // The body's number of package symbol `s`.
    fn sym_of(self: &mut Self, s: u32) u32 {
        switch self.sym_map.get(&s) {
            Some(k) => {
                return *k;
            },
            None => {},
        };
        self.b.syms.push(s);
        let k = self.b.syms.len() as u32 - 1;
        self.sym_map.insert(s, k);
        return k;
    }

    fn symaddr(self: &mut Self, name: str, kind: u8) Value {
        let k = self.sym(name, kind);
        return self.inst(O_SYMADDR, T_PTR, 0, k, 0, VNONE);
    }

    // Symbol `name` is a C library's (`Sym.ext`).
    fn mark_ext(self: &mut Self, name: str) {
        let s = self.pkg.find_symbol(name);
        self.pkg.syms.index_mut(s as usize).ext = true;
    }

    // A call of `name` with `args` of types `tys` (each a type code or AGG | layout) and result `ret`.
    fn call_sym(self: &mut Self, name: str, args: []Value, tys: []u32, ret: u32) Value {
        let sg = self.b.signature(tys, tys.len() as u32, false, ret);
        let at = self.b.pool_list(args);
        let k = self.sym(name, SK_FUNC);
        let rty = ast::pick((ret & AGG) != 0, T_NONE, ret as u8);
        return self.inst(O_CALL, rty, args.len() as u16, k, sg, at);
    }

    // The zero of type `ty`: the entry block's for a variable's type, else one here.
    fn zero(self: &mut Self, ty: u8) Value {
        switch self.zeros.get(&(ty as u32)) {
            Some(v) => {
                return *v;
            },
            None => {},
        };
        return self.zero_here(ty);
    }

    const fn fail_v(self: &mut Self, why: str<'static>) Value {
        let _ = self.fail(why);
        return VNONE;
    }

    // ---- SSA variables ----

    const fn dkey(blk: u32, var: u32) u64 {
        return blk as u64 << 32 | var as u64;
    }

    fn write_var(self: &mut Self, var: u32, v: Value) {
        self.defs.insert(Lower::dkey(self.cur, var), v);
        self.cv[var as usize] = self.view as u64 << 32 | v as u64;
        // Blocks are lowered in order, so the positions stay ascending.
        let r = self.rpo[self.cur as usize];
        let wp = self.wpos.index_mut(var as usize);
        if wp.len() == 0 || wp[wp.len() - 1] != r {
            wp.push(r);
        }
    }

    // Whether `var` enters merge block `blk` as it leaves its immediate dominator `d`: no block between
    // them in order is a loop header or writes `var`. A path from `d` to `blk` without a back edge only
    // passes such blocks, and one with a back edge passes a loop header between them.
    fn through_idom(self: &Self, var: u32, d: u32, blk: u32) bool {
        let rd = self.rpo[d as usize];
        let rb = self.rpo[blk as usize];
        if self.hdr_before[rb as usize + 1] != self.hdr_before[rd as usize + 1] {
            return false;
        }
        let wp = &self.wpos[var as usize];
        let i = switch wp.binary_search(&rd) {
            Ok(i) => i + 1,
            Err(i) => i,
        };
        return i == wp.len() || wp[i] >= rb;
    }

    // Start a view: the values cached in the views before are not valid in it.
    const fn new_view(self: &mut Self) {
        if self.view == 0xFFFFFFFF {
            for i in 0..self.cv.len() {
                self.cv[i] = 0;
            }
            self.view = 0;
        }
        self.view += 1;
    }

    // The value of `var` at the end of core block `blk` (at the current point when it is the block
    // being lowered): its last write, else through a single predecessor, else a phi.
    fn read_var(self: &mut Self, var: u32, blk: u32) Value {
        if blk == self.cur && (self.cv[var as usize] >> 32) as u32 == self.view {
            return self.cv[var as usize] as u32;
        }
        self.scratch.truncate(0);
        let mut k = blk;
        let mut v = VNONE;
        // A chain of single predecessors visits each block at most once.
        for _ in 0..self.lblk.len() + 2 {
            switch self.defs.get(&Lower::dkey(k, var)) {
                Some(x) => {
                    v = *x;
                    break;
                },
                None => {},
            };
            if k == self.virt {
                v = self.zero(self.var_ty[var as usize]);
                break;
            }
            let p0 = self.npred[k as usize];
            let np = self.npred[k as usize + 1] - p0;
            if np == 1 {
                self.scratch.push(k);
                k = self.preds[p0 as usize];
                continue;
            }
            if np == 0 {
                v = self.zero(self.var_ty[var as usize]);
                break;
            }
            if self.through_idom(var, self.idom[k as usize], k) {
                self.scratch.push(k);
                k = self.idom[k as usize];
                continue;
            }
            self.phis.push(Phi { blk: k, var: var, ty: self.var_ty[var as usize], ops: 0, nops: 0, repl: VNONE });
            v = VPARAM | PHI_TAG | self.phis.len() as u32 - 1;
            self.defs.insert(Lower::dkey(k, var), v);
            break;
        }
        for i in 0..self.scratch.len() {
            self.defs.insert(Lower::dkey(self.scratch[i], var), v);
        }
        if blk == self.cur {
            self.cv[var as usize] = self.view as u64 << 32 | v as u64;
        }
        return v;
    }

    // `v` after the phis replaced so far.
    const fn find(self: &Self, v: Value) Value {
        let mut x = v;
        // Each step follows a replacement made earlier: at most one per phi.
        for _ in 0..self.phis.len() + 1 {
            if (x & VPARAM) == 0 || (x & PHI_TAG) == 0 || x == VNONE {
                return x;
            }
            let r = self.phis[(x & ~(VPARAM | PHI_TAG)) as usize].repl;
            if r == VNONE {
                return x;
            }
            x = r;
        }
        return x;
    }
}

// How a call argument passes (`arg_mode`), the adjustments the C emitter makes at a call.
const AM_VAL: u8 = 0;
const AM_DEREF: u8 = 1; // the parameter takes the value the reference operand points at
const AM_REF: u8 = 2; // the parameter takes the operand's address
const AM_BOX: u8 = 3; // a Box operand passes its payload pointer
const AM_BOXREF: u8 = 4; // a reference to a Box passes the Box's payload pointer
const AM_F64: u8 = 5; // an f32 operand widens to the f64 parameter
const AM_WIDE: u8 = 6; // a wide literal into a scalar parameter passes its low limb
const AM_ZST_REF: u8 = 7; // a zero-sized operand by reference: the sentinel
const AM_VARARG: u8 = 8; // past a variadic callee's parameters: C's default promotions

extend Lower {
    /// Lower `b`, the body of symbol `name`: a closure's when `cnode` names its node in module `cm`.
    /// A refusal goes to `fails`.
    pub(package) fn body(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        name: str,
        cm: ModuleId,
        cnode: NodeId,
        noret: bool,
    ) bool {
        self.nbodies += 1;
        let s0 = self.pkg.find_symbol(name);
        let known = s0 != NONE && self.pkg.syms[s0 as usize].def != NONE;
        if known {
            self.pend_known += 1;
            // A body a cached module's LIR restored lowers once more, for what its lowering demands; its LIR
            // stays the restored one.
            if !self.relower.remove(&s0) {
                return true; // an emission of a body already lowered
            }
        }
        let cd = c.collect_demand;
        let ro = c.mg.rec_on;
        // A native build compiles what the body calls, which the C may have inlined away; a check of the
        // LIR leaves the C untouched. The TU cache journals what the rendering demanded, or the lowering's
        // demands where the body renders no C.
        c.collect_demand = cd && Lower::p(c).native;
        c.mg.rec_on = ro && !c.renders(b.module);
        self.err = "";
        self.dbg = self.dump.len() != 0 && self.dump.as_str() == name;
        let ok = self.body_i(c, b, name, cm, cnode, noret);
        c.collect_demand = cd;
        c.mg.rec_on = ro;
        if known {
            return true;
        }
        if !ok {
            self.fails.push(LFail { sym: String::from_str(name), why: self.err });
            if self.dbg || self.dump.len() != 0 && self.dump.as_str() == self.err {
                eprint("lir: refused {}: {}\n{}", name, self.err, irp::print_body(b).as_str());
            }
            return false;
        }
        self.tidy();
        let s = self.pkg.symbol(name, SK_FUNC);
        let _ = self.pkg.define(s, &self.b);
        self.pend.push(s);
        if cnode == NODE_NONE {
            self.item_attrs(c, s, b.owner.module, b.owner.node);
        }
        // A test without parameters runs in the CTFE comparison.
        let oa = Lower::ast(c, b.owner.module);
        if cnode == NODE_NONE && b.owner.node != NODE_NONE && b.args == 0 && oa.attr_of(
            b.owner.node,
            AttrKind::ATTR_TEST,
        ) != null {
            self.tests.push(LTest { sym: String::from_str(name), m: b.owner.module, node: b.owner.node });
        }
        return true;
    }

    fn reset(self: &mut Self, m: ModuleId) {
        self.m = m;
        self.b.clear();
        self.li.truncate(0);
        self.var_ty.truncate(0);
        self.spc = NONE;
        self.defs.clear();
        self.phis.truncate(0);
        self.phi_ops.truncate(0);
        self.lblk.truncate(0);
        self.npred.truncate(0);
        self.preds.truncate(0);
        self.edges.truncate(0);
        self.panics.clear();
        self.pan_list.truncate(0);
        self.pan_loc.truncate(0);
        self.sym_map.clear();
        self.zeros.clear();
        self.lays.clear();
        self.loc = 0;
        self.ret_ptr = VNONE;
        self.env = VNONE;
        self.temps_free.truncate(0);
        self.temps_used.truncate(0);
        self.upack.clear();
        self.uoffs.truncate(0);
    }

    fn body_i(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        name: str,
        cm: ModuleId,
        cnode: NodeId,
        noret: bool,
    ) bool {
        self.reset(b.module);
        self.bm = b.module;
        self.noret = noret;
        let pk = Lower::p(c);
        self.file = self.pkg.add_file(pk.modules.at(b.module as usize).file.as_str());
        let oa = Lower::ast(c, b.owner.module);
        // A naked function's code is its assembly: the generators read its `O_ASM`s alone.
        self.b.naked = cnode == NODE_NONE && b.owner.node != NODE_NONE && (oa.unsafe_claims(b.owner.node) & UNSAFE_NAKED) != 0;
        // Captures: the trailing argument locals of a closure body, read through its env.
        let mut ncaps: u32 = 0;
        let mut nparams = b.args;
        let mut byref_caps: u64 = 0;
        if cnode != NODE_NONE {
            let cf = Lower::ast(c, cm).closure_fact(cnode);
            if cf == null {
                return self.fail("closure-fact");
            }
            ncaps = unsafe (&*cf).ncaps;
            nparams = unsafe (&*cf).nparams;
            byref_caps = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
            if b.args != nparams + ncaps {
                return self.fail("closure-args");
            }
        }
        let cap_base = b.returns + nparams;
        // Which locals need memory (a projection other than through a pointer, an address taken), and
        // which have their address escape (then no result is written straight into them).
        let n = b.locals.len();
        let mut mem = Vector::<bool>::new();
        mem.resize_default(n);
        self.escaped.truncate(0);
        self.escaped.resize_default(n);
        if !self.scan(c, b, &mut mem) || !self.untyped(c, b) {
            return false;
        }
        for l in 0..n {
            let d = b.locals[l];
            let mut info = LInfo { kind: LK_MEM, byref: false, ti: TyI { cls: VC_ZST }, var: NONE, addr: VNONE };
            if d.storage == irc::LS_STATIC_REF {
                info.kind = LK_STATIC;
                if !self.ty(c, b.module, d.ty, &mut info.ti) {
                    return false;
                }
            } else if ncaps != 0 && l as u32 >= cap_base && l as u32 < cap_base + ncaps {
                info.kind = LK_CAP;
                info.byref = (byref_caps >> (l as u32 - cap_base) as u64 & 1) != 0;
                if !self.ty(c, b.module, d.ty, &mut info.ti) {
                    return false;
                }
            } else if d.ty == TYPE_NONE && self.upack.contains_key(&(l as u32)) {
                // An untyped local a call of several results fills: the results' memory.
                let lt = (*self.upack.get(&(l as u32)).unwrap() >> 32) as u32;
                if lt == NONE {
                    info.kind = LK_ZST;
                    info.ti = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
                } else {
                    info.ti = TyI {
                        cls: VC_MEM,
                        mty: T_NONE,
                        size: self.b.pool[lt as usize],
                        align: 1u32 << self.b.pool[lt as usize + 1],
                    };
                }
            } else {
                if !self.ty(c, b.module, d.ty, &mut info.ti) {
                    if self.dbg {
                        eprint("lir-debug local {} of {}\n", l, b.locals.len());
                    }
                    return false;
                }
                if info.ti.cls == VC_ZST {
                    info.kind = LK_ZST;
                } else if info.ti.cls == VC_SCALAR && !mem[l] && !(b.returns > 1 && l as u32 < b.returns) {
                    info.kind = LK_VAR;
                    info.var = self.var_ty.len() as u32;
                    self.var_ty.push(info.ti.mty);
                }
            }
            self.li.push(info);
        }
        if !self.cfg(b) {
            return false;
        }
        if !self.entry(c, b, ncaps, nparams, cap_base, cnode == NODE_NONE && self.variadic(c, b)) {
            return false;
        }
        let mut e0: usize = 0;
        for k in 0..self.order.len() {
            let blk = self.order[k];
            // A block whose one predecessor is the block lowered last continues its view, and the LIR
            // block that one ended in when its `jmp` is the one edge to it.
            let p0 = self.npred[blk as usize];
            let next = self.npred[blk as usize + 1] - p0 == 1 && self.preds[p0 as usize] == self.cur;
            if !next {
                self.new_view();
            }
            let joined = next && self.join_last(blk, e0);
            e0 = self.edges.len();
            self.cur = blk;
            if !joined {
                self.b.begin(self.lblk[blk as usize]);
            }
            if !self.lower_block(c, b, blk) {
                return false;
            }
        }
        return self.finish(name);
    }

    // Drop the `jmp` that ends the LIR block lowered last when it is the one edge (of those made since
    // `e0`, when the block lowered last began) to `blk`'s block, so `blk` continues that block. The
    // block left empty is not reached.
    fn join_last(self: &mut Self, blk: u32, e0: usize) bool {
        let lb = self.b.current();
        let to = self.lblk[blk as usize];
        if self.b.blocks[lb as usize].len == 0 || self.b.blocks[lb as usize].flags != self.b.blocks[to as usize].flags {
            return false;
        }
        let t = self.b.insts[self.b.insts.len() - 1];
        if t.op != O_JMP || self.edges[t.a as usize].to != to {
            return false;
        }
        for e in e0..self.edges.len() {
            if self.edges[e].to == to && e != t.a as usize {
                return false;
            }
        }
        self.b.pop();
        return true;
    }

    // Whether `b` is a function defined with a variadic tail.
    fn variadic(self: &Self, c: &cbe::CEmit, b: &irc::CoreBody) bool {
        if b.owner.node == NODE_NONE {
            return false;
        }
        let on = Lower::ast(c, b.owner.module).at_const(b.owner.node);
        return on.kind == NodeKind::NODE_FUNCTION && Lower::ast(c, b.owner.module).ext(b.owner.node).function.is_variadic();
    }

    // Mark in `mem` the locals that need memory and in `escaped` those whose address escapes.
    fn scan(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, mem: &mut Vector<bool>) bool {
        for p in 0..b.places.len() {
            let pl = b.places[p];
            if pl.proj_len == 0 {
                continue;
            }
            let first = b.projections[pl.proj_start as usize];
            if first.kind == irc::PJ_DEREF {
                continue;
            }
            // A field or an index through a pointer local reads the pointer.
            let mut ti = TyI { cls: 0 };
            if !self.ty(c, b.module, b.locals[pl.base as usize].ty, &mut ti) {
                return false;
            }
            if !(ti.cls == VC_SCALAR && ti.mty == T_PTR) {
                mem[pl.base as usize] = true;
            }
        }
        for si in 0..b.statements.len() {
            let s = b.statements[si];
            if s.kind != irc::ST_ASSIGN {
                continue;
            }
            let rv = b.rvalues[s.rvalue as usize];
            if rv.kind == irc::RV_REF || rv.kind == irc::RV_ADDR || rv.kind == irc::RV_SLICE {
                self.take_addr(b, rv.a, mem);
            } else if rv.kind == irc::RV_CLOSURE && rv.b != 0 {
                let cf = Lower::ast(c, rv.item.module).closure_fact(rv.item.node);
                if cf == null {
                    return self.fail("closure-fact");
                }
                let by = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
                for i in 0..rv.b {
                    let op = b.operands[b.oper_pool[(rv.a + i) as usize] as usize];
                    if (by >> i as u64 & 1) != 0 && op.kind != irc::OP_CONST {
                        self.take_addr(b, op.data, mem);
                    }
                }
            } else if rv.kind == irc::RV_INTRINSIC && (rv.c == irc::IN_VA_START || rv.c == irc::IN_VA_END) {
                self.take_addr(b, s.place, mem);
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks[bi].term;
            if t.kind != irc::TM_CALL || t.callee.node == NODE_NONE {
                continue;
            }
            for i in 0..t.args_len {
                let opid = b.oper_pool[(t.args_start + i) as usize];
                let op = b.operands[opid as usize];
                if op.kind == irc::OP_CONST {
                    continue;
                }
                // An interface method resolves to its implementation at the call: either reference rule.
                let am = self.arg_mode(c, b, t.callee, i, opid);
                if am == AM_REF {
                    self.take_addr(b, op.data, mem);
                }
            }
        }
        return true;
    }

    const fn take_addr(self: &mut Self, b: &irc::CoreBody, pid: u32, mem: &mut Vector<bool>) {
        let pl = b.places[pid as usize];
        if pl.proj_len == 0 || b.projections[pl.proj_start as usize].kind != irc::PJ_DEREF {
            mem[pl.base as usize] = true;
            self.escaped[pl.base as usize] = true;
        }
    }

    // The reachable core blocks in reverse postorder (`order`), their LIR blocks and predecessors.
    fn cfg(self: &mut Self, b: &irc::CoreBody) bool {
        let nb = b.blocks.len();
        self.virt = nb as u32;
        self.lblk.resize_default(nb);
        for k in 0..nb {
            self.lblk[k] = NONE;
        }
        // The entry block: the signature's parameters, then a jump into the core entry.
        let sig_tys = Vector::<u8>::new();
        let _ = sig_tys;
        self.order.truncate(0);
        let mut post = Vector::<u32>::new();
        let mut stack = Vector::<u64>::new();
        let mut seen = Vector::<bool>::new();
        seen.resize_default(nb);
        seen[b.entry as usize] = true;
        stack.push(b.entry as u64 << 32);
        let mut succ = Vector::<u32>::new();
        // Each block enters once and each edge is taken once.
        while stack.len() != 0 {
            let top = stack.len() - 1;
            let blk = (stack[top] >> 32) as u32;
            let next = stack[top] as u32;
            Lower::succs(b, blk, &mut succ);
            if next as usize < succ.len() {
                stack[top] = blk as u64 << 32 | (next + 1) as u64;
                let s = succ[next as usize];
                if s as usize >= nb {
                    return self.fail("successor");
                }
                if !seen[s as usize] {
                    seen[s as usize] = true;
                    stack.push(s as u64 << 32);
                }
                continue;
            }
            post.push(blk);
            stack.truncate(top);
        }
        for k in 0..post.len() {
            self.order.push(post[post.len() - 1 - k]);
        }
        // Predecessors, each once, by block; the virtual entry block precedes the core entry.
        let mut pairs = Vector::<u64>::new();
        pairs.push(b.entry as u64 << 32 | self.virt as u64);
        for k in 0..self.order.len() {
            let blk = self.order[k];
            Lower::succs(b, blk, &mut succ);
            for j in 0..succ.len() {
                pairs.push(succ[j] as u64 << 32 | blk as u64);
            }
        }
        pairs.sort();
        self.npred.resize_default(nb + 2);
        let mut j: usize = 0;
        for k in 0..nb + 2 {
            self.npred[k] = self.preds.len() as u32;
            while j < pairs.len() && (pairs[j] >> 32) as usize == k {
                let pr = pairs[j] as u32;
                if self.preds.len() as u32 == self.npred[k] || self.preds[self.preds.len() - 1] != pr {
                    self.preds.push(pr);
                }
                j += 1;
            }
        }
        self.dominators();
        return true;
    }

    // The positions, the immediate dominators (Cooper, Harvey and Kennedy) and the loop headers of the
    // reachable blocks.
    fn dominators(self: &mut Self) {
        let nb = self.lblk.len();
        let n = self.order.len();
        fill_u32(&mut self.rpo, nb + 1, NONE);
        self.rpo[nb] = 0;
        for k in 0..n {
            self.rpo[self.order[k] as usize] = k as u32 + 1;
        }
        fill_u32(&mut self.idom, nb + 1, NONE);
        self.idom[nb] = nb as u32;
        let mut changed = true;
        // Each pass fixes the dominator of one more block at least.
        for _ in 0..n + 1 {
            if !changed {
                break;
            }
            changed = false;
            for k in 0..n {
                let blk = self.order[k] as usize;
                let mut d = NONE;
                for q in self.npred[blk]..self.npred[blk + 1] {
                    let p = self.preds[q as usize];
                    if self.idom[p as usize] != NONE {
                        d = if d == NONE {
                            p;
                        } else {
                            self.common_dom(p, d);
                        };
                    }
                }
                if d != self.idom[blk] {
                    self.idom[blk] = d;
                    changed = true;
                }
            }
        }
        fill_u32(&mut self.hdr_before, n + 2, 0);
        for k in 0..n {
            let blk = self.order[k] as usize;
            let mut h: u32 = 0;
            for q in self.npred[blk]..self.npred[blk + 1] {
                if self.rpo[self.preds[q as usize] as usize] > k as u32 {
                    h = 1;
                }
            }
            self.hdr_before[k + 2] = self.hdr_before[k + 1] + h;
        }
    }

    // The nearest common dominator of `a` and `b`.
    const fn common_dom(self: &Self, a: u32, b: u32) u32 {
        let mut x = a;
        let mut y = b;
        // Each step moves one of them up the tree, to a smaller position.
        for _ in 0..2 * self.rpo.len() + 2 {
            if x == y {
                break;
            }
            if self.rpo[x as usize] > self.rpo[y as usize] {
                x = self.idom[x as usize];
            } else {
                y = self.idom[y as usize];
            }
        }
        return x;
    }

    // The successors of core block `blk`.
    fn succs(b: &irc::CoreBody, blk: u32, out: &mut Vector<u32>) {
        out.truncate(0);
        let t = b.blocks[blk as usize].term;
        if t.kind == irc::TM_SWITCH {
            for k in 0..t.sw_len {
                out.push(b.switch_pool[(t.sw_start + k) as usize] as u32);
            }
        }
        if t.kind != irc::TM_RETURN && t.kind != irc::TM_UNREACHABLE && t.t0 != irc::IR_NONE {
            out.push(t.t0);
        }
    }
}

extend Lower {
    // The signature, the entry block and the storage of every local in memory.
    fn entry(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        ncaps: u32,
        nparams: u32,
        cap_base: u32,
        variadic: bool,
    ) bool {
        let mut ptys = Vector::<u32>::new();
        let mut etys = Vector::<u8>::new();
        let mut pl = Vector::<u32>::new();
        if ncaps != 0 {
            ptys.push(T_PTR);
            etys.push(T_PTR);
            pl.push(NONE);
        }
        for i in 0..nparams {
            let l = b.returns + i;
            let info = self.li[l as usize];
            if info.ti.cls == VC_ZST {
                continue;
            }
            if info.ti.cls == VC_SCALAR {
                ptys.push(sig_code(info.ti.mty, Lower::signed(c, b.module, b.locals[l as usize].ty)));
                etys.push(info.ti.mty);
            } else {
                ptys.push(self.param_sig(c, b.module, b.locals[l as usize].ty, info.ti));
                etys.push(T_PTR);
            }
            pl.push(l);
        }
        let mut ret = T_NONE as u32;
        if b.returns == 1 {
            let info = self.li[0];
            if info.ti.cls == VC_SCALAR {
                ret = sig_code(info.ti.mty, Lower::signed(c, b.module, b.locals[0].ty));
            } else if info.ti.cls == VC_MEM {
                ret = AGG | self.layout_of(c, b.module, b.locals[0].ty, info.ti);
            }
        } else if b.returns > 1 {
            let mut tys = Vector::<TypeId>::new();
            for r in 0..b.returns {
                tys.push(b.locals[r as usize].ty);
            }
            let lt = self.pack(c, b.module, &tys);
            if lt == NONE && self.err.len() != 0 {
                return false;
            }
            if lt != NONE {
                ret = AGG | lt;
            }
        }
        if (ret & AGG) != 0 {
            etys.push(T_PTR);
        }
        self.b.sig = self.b.signature(ptys[0..ptys.len()], ptys.len() as u32, variadic, ret);
        let b0 = self.b.add_block(etys[0..etys.len()]);
        for k in 0..self.order.len() {
            self.lblk[self.order[k] as usize] = self.block();
        }
        self.b.begin(b0);
        self.cur = self.virt;
        // The safepoint counter may add one variable.
        if self.cv.len() <= self.var_ty.len() {
            self.cv.resize_default(self.var_ty.len() + 1);
            self.wpos.resize_default(self.var_ty.len() + 1);
        }
        for v in 0..self.var_ty.len() + 1 {
            self.wpos.index_mut(v).truncate(0);
        }
        self.new_view();
        // One zero per variable type, for a read before any write.
        for v in 0..self.var_ty.len() + 2 {
            let t = if v < self.var_ty.len() {
                self.var_ty[v];
            } else if v == self.var_ty.len() {
                T_I32;
            } else {
                self.ptr_int();
            };
            if self.zeros.contains_key(&(t as u32)) {
                continue;
            }
            let z = if is_vec(t) {
                let w = self.b.words.len() as u32;
                let nw = (type_bytes(t, self.pkg.ptr_bytes) + 7) / 8;
                for _ in 0..nw {
                    self.b.words.push(0);
                }
                self.inst(O_WCONST, t, 0, w, nw, VNONE);
            } else if is_float(t) {
                self.fconst(t, 0);
            } else {
                self.iconst(t, 0);
            };
            self.zeros.insert(t, z);
        }
        for k in 0..pl.len() {
            let v = self.b.param(b0, k as u32);
            let l = pl[k];
            if l == NONE {
                self.env = v;
                continue;
            }
            let info = self.li[l as usize];
            if info.kind == LK_VAR {
                self.write_var(info.var, v);
            } else if info.ti.cls == VC_SCALAR {
                let a = self.new_slot(info.ti);
                self.li.index_mut(l as usize).addr = a;
                self.store(v, a, 0, false);
            } else if b.locals[l as usize].is_mutable && Lower::is_array(c, b.module, b.locals[l as usize].ty) {
                // The caller's array (a C array parameter): a mutable one takes a copy, as C does.
                let a = self.new_slot(info.ti);
                self.memcpy(a, v, info.ti.size);
                self.li.index_mut(l as usize).addr = a;
            } else {
                self.li.index_mut(l as usize).addr = v;
            }
        }
        if (ret & AGG) != 0 {
            self.ret_ptr = self.b.param(b0, pl.len() as u32);
        }
        for l in 0..self.li.len() {
            let info = self.li[l];
            if info.kind != LK_MEM || info.addr != VNONE {
                continue;
            }
            let a = if l as u32 < b.returns && b.returns == 1 {
                self.ret_ptr;
            } else if l as u32 < b.returns {
                self.ptradd(self.ret_ptr, VNONE, 0, self.ret_off[l]);
            } else {
                self.new_slot(info.ti);
            };
            self.li.index_mut(l).addr = a;
        }
        if c.ticks_on(b) {
            self.spc = self.var_ty.len() as u32;
            self.var_ty.push(T_I32);
            let n = self.iconst(T_I32, 2048);
            self.write_var(self.spc, n);
        }
        let e = self.edge(self.lblk[b.entry as usize], self.virt, b.entry);
        let _ = self.inst(O_JMP, T_NONE, 0, e, VNONE, VNONE);
        let _ = cap_base;
        return true;
    }

    // A slot for type `ti`, addressed in the entry block.
    fn new_slot(self: &mut Self, ti: TyI) Value {
        let s = self.b.slot(ast::pick(ti.size == 0, 1u32, ti.size), log2(ti.align) as u8);
        return self.inst(O_SLOTADDR, T_PTR, 0, s, VNONE, VNONE);
    }

    // A temporary slot of `ti` for the statement being lowered; its address is computed here.
    fn temp(self: &mut Self, ti: TyI) Value {
        let key = ti.size as u64 << 40 | log2(ti.align) as u64 << 32;
        let mut s = NONE;
        for k in 0..self.temps_free.len() {
            if (self.temps_free[k] & 0xFFFFFFFF00000000) == key {
                s = self.temps_free[k] as u32;
                self.temps_free.swap_remove(k);
                break;
            }
        }
        if s == NONE {
            s = self.b.slot(ast::pick(ti.size == 0, 1u32, ti.size), log2(ti.align) as u8);
        }
        self.temps_used.push(key | s as u64);
        return self.inst(O_SLOTADDR, T_PTR, 0, s, VNONE, VNONE);
    }

    fn release_temps(self: &mut Self) {
        for k in 0..self.temps_used.len() {
            self.temps_free.push(self.temps_used[k]);
        }
        self.temps_used.truncate(0);
    }

    // The result memory of results `tys`: its layout in the pool, the offsets in `ret_off`; NONE when
    // every result is zero-sized.
    fn pack(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, tys: &Vector<TypeId>) u32 {
        self.ret_off.truncate(0);
        let mut off: u32 = 0;
        let mut al: u32 = 1;
        let mut any = false;
        let mut known = true;
        let mut leaves = Vector::<(u32, u8)>::new();
        for r in 0..tys.len() {
            let mut ti = TyI { cls: 0 };
            if !self.ty(c, m, tys[r], &mut ti) {
                return NONE;
            }
            if ti.cls == VC_ZST {
                self.ret_off.push(0);
                continue;
            }
            any = true;
            off = round_up(off, ti.align);
            self.ret_off.push(off);
            known = known && (leaves.len() > 16 || self.leaves(c, m, tys[r], off, &mut leaves, 0));
            off += ti.size;
            al = ast::pick(ti.align > al, ti.align, al);
        }
        if !any {
            return NONE;
        }
        let size = round_up(off, al);
        // As `layout_of`: none when unknown, the first 16 past 16.
        if size > 64 || !known && leaves.len() <= 16 {
            leaves.truncate(0);
        }
        leaves.truncate(ast::pick(leaves.len() > 16, 16usize, leaves.len()));
        return self.layout(size, log2(al), &leaves);
    }

    // ---- Locations ----

    // The location of byte `pos` of the body's source.
    fn loc_at(self: &mut Self, c: &cbe::CEmit, pos: u32) u32 {
        let p = Lower::p(c);
        let m = self.m as usize;
        if m >= p.lines.len() || pos as usize >= p.modules.at(m).source.len() {
            return 0;
        }
        // The last line start at or before `pos`: a body's statements come in nearby lines, so the search
        // gallops on from the last one found.
        let ls = &p.lines[m];
        let mut lo: usize = 0;
        let mut hi = ls.len();
        let last = self.loc_line as usize;
        if self.loc_m == self.m && last < hi && ls[last] <= pos {
            lo = last;
            let mut step: usize = 1;
            // Each step doubles: at most 32 steps.
            while lo + step < hi && ls[lo + step] <= pos {
                lo += step;
                step *= 2;
            }
            if lo + step < hi {
                hi = lo + step;
            }
        }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2;
            if ls[mid] <= pos {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        let col = pos - ls[lo] + 1;
        self.loc_m = self.m;
        self.loc_line = lo as u32;
        return self.b.loc(Loc { file: self.file, line: lo as u32 + 1, col: col });
    }

    // ---- Places ----

    // Where place `pid` lives, its projections applied.
    fn place(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, pid: u32, out: &mut PlaceRef) bool {
        let pl = b.places[pid as usize];
        let l = pl.base;
        let info = self.li[l as usize];
        let mut cur = PlaceRef {
            kind: PR_MEM,
            var: NONE,
            addr: VNONE,
            m: b.module,
            t: b.locals[l as usize].ty,
            ti: info.ti,
            packed: false,
        };
        // A pointer value standing for the place it points at (a pointer variable, a folded constant).
        let mut ptr_val = VNONE;
        if info.kind == LK_VAR {
            if pl.proj_len == 0 {
                cur.kind = PR_VAR;
                cur.var = info.var;
                *out = cur;
                return true;
            }
            ptr_val = self.read_var(info.var, self.cur);
        } else if info.kind == LK_MEM {
            cur.addr = info.addr;
        } else if info.kind == LK_ZST {
            cur.kind = PR_ZST;
            cur.addr = self.sentinel(c, b.module, b.locals[l as usize].ty);
        } else if info.kind == LK_STATIC {
            let mut v = VNONE;
            if !self.static_ref(c, b, l, &mut v, &mut cur.addr) {
                return false;
            }
            if v != VNONE {
                if pl.proj_len == 0 {
                    cur.kind = PR_VAL;
                    cur.addr = v;
                    *out = cur;
                    return true;
                }
                ptr_val = v;
            }
            if info.ti.cls == VC_ZST {
                cur.kind = PR_ZST;
                cur.addr = self.sentinel(c, b.module, b.locals[l as usize].ty);
            }
        } else {
            // A capture: its env field, or the binding that field points at.
            let k = l - (b.returns + b.args - self.ncaps(b));
            let fa = self.cap_off(c, b, k);
            if fa == NONE {
                return self.fail("capture");
            }
            cur.addr = self.ptradd(self.env, VNONE, 0, fa);
            if info.byref {
                cur.addr = self.load(T_PTR, cur.addr, 0, false);
            }
            if info.ti.cls == VC_ZST {
                cur.kind = PR_ZST;
                cur.addr = self.sentinel(c, b.module, b.locals[l as usize].ty);
            }
        }
        let mut variant = NODE_NONE;
        let mut vbase: u32 = 0;
        for i in 0..pl.proj_len {
            let pj = b.projections[(pl.proj_start + i) as usize];
            if i == 0 && cur.t == TYPE_NONE && self.upack.contains_key(&l) {
                // A result of an untyped local's call.
                let o0 = (*self.upack.get(&l).unwrap() & 0xFFFFFFFF) as u32;
                if pj.kind != irc::PJ_FIELD {
                    return self.fail("untyped-projection");
                }
                cur.addr = self.ptradd(cur.addr, VNONE, 0, self.uoffs[(o0 + pj.data) as usize]);
                cur.t = pj.ty;
                if !self.ty(c, b.module, pj.ty, &mut cur.ti) {
                    return false;
                }
                continue;
            }
            if pj.kind == irc::PJ_DEREF {
                cur.addr = if ptr_val != VNONE {
                    ptr_val;
                } else {
                    self.load(T_PTR, cur.addr, 0, cur.packed);
                };
                ptr_val = VNONE;
                cur.packed = false;
                variant = NODE_NONE;
            } else if pj.kind == irc::PJ_FIELD || pj.kind == irc::PJ_DOWNCAST {
                let mut rm = cur.m;
                let mut rt = cur.t;
                // A member access dereferences the pointers in front of the aggregate.
                for _ in 0..4 {
                    let y = Lower::resolved(c, cur.m, cur.t, &mut rm, &mut rt);
                    if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                        break;
                    }
                    cur.addr = if ptr_val != VNONE {
                        ptr_val;
                    } else {
                        self.load(T_PTR, cur.addr, 0, cur.packed);
                    };
                    ptr_val = VNONE;
                    cur.packed = false;
                    cur.m = rm;
                    cur.t = y.as_data.elem;
                }
                if ptr_val != VNONE {
                    return self.fail("place-pointer");
                }
                let _ = Lower::resolved(c, cur.m, cur.t, &mut rm, &mut rt);
                if pj.kind == irc::PJ_DOWNCAST {
                    let mut el = EnumL { ok: false };
                    if !self.enum_of(c, rm, rt, &mut el) {
                        return self.fail("downcast");
                    }
                    variant = pj.sub;
                    vbase = el.payload_off;
                    cur.addr = self.ptradd(cur.addr, VNONE, 0, el.payload_off);
                    // The payload keeps the enum's type until its member is named.
                } else {
                    let mut f = FieldAt {
                        m: 0,
                        t: TYPE_NONE,
                        off: 0,
                        idx: 0,
                        node: NODE_NONE,
                        variant: NODE_NONE,
                        mty: T_NONE,
                        packed: false,
                    };
                    if !self.member(c, rm, rt, pj, variant, &mut f) {
                        return false;
                    }
                    let mut off = f.off;
                    if variant != NODE_NONE {
                        off -= vbase;
                    }
                    cur.addr = self.ptradd(cur.addr, VNONE, 0, off);
                    cur.packed = cur.packed || f.packed;
                    variant = NODE_NONE;
                }
            } else {
                // An index: through references to the container, into its element storage.
                let mut rm = cur.m;
                let mut rt = cur.t;
                let mut y = Lower::resolved(c, cur.m, cur.t, &mut rm, &mut rt);
                for _ in 0..4 {
                    if y.kind != TypeKind::TYPE_REFERENCE {
                        break;
                    }
                    let mut em = rm;
                    let mut et = y.as_data.elem;
                    let ey = Lower::resolved(c, rm, y.as_data.elem, &mut em, &mut et);
                    let mut hop = ey.kind == TypeKind::TYPE_ARRAY || ey.kind == TypeKind::TYPE_SIMD;
                    if ey.kind == TypeKind::TYPE_INSTANCE {
                        let nm = Lower::agg_name(c, em, et);
                        hop = nm == "Array" || nm == "Vector" || nm == "Slice" || nm == "SliceMut";
                    }
                    if !hop {
                        break;
                    }
                    cur.addr = if ptr_val != VNONE {
                        ptr_val;
                    } else {
                        self.load(T_PTR, cur.addr, 0, cur.packed);
                    };
                    ptr_val = VNONE;
                    cur.packed = false;
                    rm = em;
                    rt = et;
                    y = ey;
                }
                let mut base = VNONE;
                if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                    base = if ptr_val != VNONE {
                        ptr_val;
                    } else {
                        self.load(T_PTR, cur.addr, 0, cur.packed);
                    };
                } else if ptr_val != VNONE {
                    return self.fail("index-pointer");
                } else if y.kind == TypeKind::TYPE_ARRAY || y.kind == TypeKind::TYPE_SIMD {
                    base = cur.addr;
                } else {
                    let nm = Lower::agg_name(c, rm, rt);
                    let fname = ast::pick(nm == "Array", "data", "ptr");
                    let mut f = FieldAt {
                        m: 0,
                        t: TYPE_NONE,
                        off: 0,
                        idx: 0,
                        node: NODE_NONE,
                        variant: NODE_NONE,
                        mty: T_NONE,
                        packed: false,
                    };
                    if !self.named_field(c, rm, rt, fname, &mut f) {
                        return self.fail("index-storage");
                    }
                    base = if nm == "Array" {
                        self.ptradd(cur.addr, VNONE, 0, f.off);
                    } else {
                        self.load(T_PTR, cur.addr, f.off, cur.packed);
                    };
                }
                ptr_val = VNONE;
                let mut eti = TyI { cls: 0 };
                if !self.ty(c, b.module, pj.ty, &mut eti) {
                    return false;
                }
                let ix = if pj.kind == irc::PJ_INDEX_CONST {
                    self.iconst(self.ptr_int(), pj.data);
                } else {
                    let v = self.operand(c, b, pj.data);
                    self.int_to(v, self.ptr_int(), false);
                };
                cur.addr = self.ptradd(base, ix, eti.size, 0);
                cur.packed = false;
                variant = NODE_NONE;
            }
            cur.m = b.module;
            cur.t = pj.ty;
            if pj.kind != irc::PJ_DOWNCAST {
                if !self.ty(c, b.module, pj.ty, &mut cur.ti) {
                    return false;
                }
            }
        }
        if ptr_val != VNONE {
            return self.fail("place-value");
        }
        cur.kind = ast::pick(cur.ti.cls == VC_ZST, PR_ZST, PR_MEM);
        if cur.kind == PR_ZST && pl.proj_len != 0 && !self.zst_place_kept(c, b, pl) {
            cur.addr = self.sentinel(c, b.module, pl.ty);
        }
        *out = cur;
        return true;
    }

    // Whether zero-sized place `pl` keeps its own address instead of the sentinel, as C's references do:
    // `*p` is the pointer, and a field of a sized struct (a flexible array member) sits at its offset.
    fn zst_place_kept(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, pl: irc::Place) bool {
        let last = b.projections[(pl.proj_start + pl.proj_len - 1) as usize];
        if last.kind == irc::PJ_DEREF {
            return true;
        }
        if last.kind != irc::PJ_FIELD {
            return false;
        }
        let mut fm = b.module;
        let mut ft = last.ty;
        let fy = Lower::resolved(c, b.module, last.ty, &mut fm, &mut ft);
        if fy.kind == TypeKind::TYPE_BUILTIN && fy.as_data.builtin == BuiltinType::BT_VOID {
            return false;
        }
        let ownt = if pl.proj_len > 1 {
            b.projections[(pl.proj_start + pl.proj_len - 2) as usize].ty;
        } else {
            b.locals[pl.base as usize].ty;
        };
        let mut om = b.module;
        let mut ot = ownt;
        let oy = Lower::resolved(c, b.module, ownt, &mut om, &mut ot);
        let mut ostruct = oy.kind == TypeKind::TYPE_STRUCT;
        if oy.kind == TypeKind::TYPE_INSTANCE {
            let oi = *Lower::ast(c, om).instance(oy.as_data.inst);
            ostruct = Lower::ast(c, oi.module).at_const(oi.decl).kind == NodeKind::NODE_STRUCT;
        }
        let mut oti = TyI { cls: 0 };
        return ostruct && self.ty(c, b.module, ownt, &mut oti) && oti.cls != VC_ZST;
    }

    // The number of captures of the body being lowered (0 outside a closure).
    const fn ncaps(self: &Self, b: &irc::CoreBody) u32 {
        let mut n: u32 = 0;
        for l in 0..self.li.len() {
            if self.li[l].kind == LK_CAP {
                n += 1;
            }
        }
        let _ = b;
        return n;
    }

    // The env offset of capture `k`, NONE when it has no storage.
    const fn cap_off(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, k: u32) u32 {
        let mut off: u32 = 0;
        let base = b.returns + b.args - self.ncaps(b);
        for i in 0..k + 1 {
            let info = self.li[(base + i) as usize];
            if info.ti.cls == VC_ZST {
                if i == k {
                    return NONE;
                }
                continue;
            }
            let sz = ast::pick(info.byref, self.pkg.ptr_bytes, info.ti.size);
            let al = ast::pick(info.byref, self.pkg.ptr_bytes, info.ti.align);
            off = round_up(off, al);
            if i == k {
                return off;
            }
            off += sz;
        }
        let _ = c;
        return NONE;
    }

    // The shape of payload enum `(rm, rt)`.
    fn enum_of(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId, out: &mut EnumL) bool {
        let y = *Lower::ast(c, rm).type_at(rt);
        if y.kind == TypeKind::TYPE_ENUM {
            return self.enum_shape(c, y.module, y.as_data.decl, out);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *Lower::ast(c, rm).instance(y.as_data.inst);
        let nb = c.mg.push_generics(it.module, Lower::ast(c, it.module).ext(it.decl).aggregate.generics, rm, &it);
        let ok = Lower::ast(c, it.module).at_const(it.decl).kind == NodeKind::NODE_ENUM && self.enum_shape(
            c,
            it.module,
            it.decl,
            out,
        );
        c.mg.pop_subs(nb);
        return ok;
    }

    // The address of the aligned sentinel standing for a zero-sized value of `(m, t)`.
    fn sentinel(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, t: TypeId) Value {
        let mut rm = m;
        let mut rt = t;
        let _ = Lower::resolved(c, m, t, &mut rm, &mut rt);
        let lo = c.mg.layout_sub(rm, rt);
        let al: u64 = ast::pick(lo.ok && lo.align > 1, lo.align, 1u64);
        let s = self.sentinel_sym(c, al);
        let k = self.sym_of(s);
        return self.inst(O_SYMADDR, T_PTR, 0, k, 0, VNONE);
    }

    // The sentinel byte `__sc_zst_<align>` every zero-sized reference of that alignment addresses.
    fn sentinel_sym(self: &mut Self, c: &mut cbe::CEmit, al: u64) u32 {
        // The registry unit defines it: one byte per alignment program-wide.
        let mut cn = String::new();
        c.sentinel(al, &mut cn);
        self.sbuf.clear();
        self.sbuf.push_str("__sc_zst_");
        self.sbuf.push_u64(al);
        let s = self.pkg.symbol(self.sbuf.as_str(), SK_DATA);
        if self.pkg.syms[s as usize].def == NONE {
            let none: []u8 = [];
            let nr: []Reloc = [];
            let _ = self.pkg.add_data(s, 1, log2(al as u32) as u8, false, none, nr);
        }
        return s;
    }

    // A static or constant item's storage `addr`, or its folded value `val` (a const parameter).
    fn static_ref(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, l: u32, val: &mut Value, addr: &mut Value) bool {
        let d = b.locals[l as usize];
        let item = d.item;
        let mut cv: i64 = 0;
        let mut bt = BuiltinType::BT_COUNT;
        if c.mg.fold_param(item.module, item.node, &mut cv, &mut bt) {
            let mt = self.builtin_mty(bt);
            *val = self.iconst(mt, cv as u64);
            return true;
        }
        let mut sym = String::new();
        if item.node == NODE_NONE || !c.mg.const_sym(item.module, item.node, &mut sym) {
            return self.fail("static-sym");
        }
        let ia = Lower::ast(c, item.module).at_const(item.node);
        if ia.kind == NodeKind::NODE_CONST && ia.as_data.const_def.is_extern && !ia.as_data.const_def.is_static_mut {
            // A C header's constant: its value as the header defines it, else only the C compiler knows it.
            if let Some(x) = Lower::p(c).extern_ints.get(&(item.module as u64 << 32 | item.node as u64)) {
                let mut ti = TyI { cls: 0 };
                if !self.ty(c, b.module, d.ty, &mut ti) {
                    return false;
                }
                if ti.cls == VC_SCALAR && (is_int(ti.mty) && ti.mty != T_I128 || ti.mty == T_PTR) {
                    *val = self.iconst(ti.mty, (*x) as u64);
                    return true;
                }
            }
            self.pend_c = "reads a C header's constant";
            self.pend_name = sym.clone();
        }
        // Its storage, which C may not have needed.
        if !c.lir_stat_need(b.module, item, d.ty, sym.as_str()) {
            return self.fail("static-type");
        }
        if c.is_tls(item) {
            let k = self.sym(sym.as_str(), SK_TLS);
            *addr = self.inst(O_SYMADDR, T_PTR, 0, k, 0, VNONE);
            return true;
        }
        *addr = self.symaddr(sym.as_str(), SK_DATA);
        if ia.kind == NodeKind::NODE_CONST && ia.as_data.const_def.is_extern {
            self.mark_ext(sym.as_str());
        }
        return true;
    }

    // The value of scalar place `p`.
    fn read(self: &mut Self, p: PlaceRef) Value {
        if p.kind == PR_VAR {
            return self.read_var(p.var, self.cur);
        }
        if p.kind == PR_VAL {
            return p.addr;
        }
        if p.kind == PR_ZST || p.ti.cls != VC_SCALAR {
            return self.fail_v("read");
        }
        return self.load(p.ti.mty, p.addr, 0, p.packed);
    }

    fn write(self: &mut Self, p: PlaceRef, v: Value) bool {
        if p.kind == PR_VAR {
            self.write_var(p.var, v);
            return true;
        }
        if p.kind == PR_ZST {
            return true;
        }
        if p.kind != PR_MEM {
            return self.fail("write");
        }
        self.store(v, p.addr, 0, p.packed);
        return true;
    }

    // The address of place `pid`.
    fn place_addr(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, pid: u32) Value {
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, pid, &mut p) {
            return VNONE;
        }
        if p.kind == PR_MEM || p.kind == PR_ZST {
            return p.addr;
        }
        return self.fail_v("address-of-value");
    }
}

extend Lower {
    // ---- Operands ----

    // The type of operand `opid` (a copy without one has its place's).
    const fn op_ty(b: &irc::CoreBody, opid: u32) TypeId {
        let op = b.operands[opid as usize];
        if op.ty == TYPE_NONE && op.kind != irc::OP_CONST {
            return b.places[op.data as usize].ty;
        }
        return op.ty;
    }

    // The value of scalar operand `opid`; VNONE for a zero-sized one.
    fn operand(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, opid: u32) Value {
        let op = b.operands[opid as usize];
        if op.kind == irc::OP_CONST {
            let mut ti = self.hint;
            let ct = b.constants[op.data as usize].ty;
            let t0 = ast::pick(ct != TYPE_NONE, ct, op.ty);
            if t0 != TYPE_NONE && !self.ty(c, b.module, t0, &mut ti) {
                return VNONE;
            }
            return self.constant(c, b, op.data, ti);
        }
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, op.data, &mut p) {
            return VNONE;
        }
        if p.kind == PR_ZST {
            return VNONE;
        }
        return self.read(p);
    }

    // The address of operand `opid` held in memory: its place, or a temporary holding the constant.
    fn operand_addr(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, opid: u32, ti: TyI) Value {
        let op = b.operands[opid as usize];
        if op.kind != irc::OP_CONST {
            let mut p = PlaceRef { kind: 0 };
            if !self.place(c, b, op.data, &mut p) {
                return VNONE;
            }
            if p.kind == PR_MEM || p.kind == PR_ZST {
                return p.addr;
            }
            // A scalar place standing for memory of its size (a vector read as its array).
            let v = self.read(p);
            let t = self.temp(ti);
            self.store(v, t, 0, false);
            return t;
        }
        let t = self.temp(ti);
        if !self.const_into(c, b, op.data, t, ti) {
            return VNONE;
        }
        return t;
    }

    // Store operand `opid` of type `ti` into memory at `dst`.
    fn operand_into(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, opid: u32, dst: Value, ti: TyI) bool {
        if ti.cls == VC_ZST {
            return true;
        }
        let op = b.operands[opid as usize];
        self.hint = ti;
        if ti.cls == VC_SCALAR {
            let v = self.operand(c, b, opid);
            if v == VNONE {
                return self.fail("operand");
            }
            // C's implicit conversion at the store.
            let ot = Lower::op_ty(b, opid);
            let fv = self.fit(v, ti.mty, ot != TYPE_NONE && Lower::signed(c, b.module, ot));
            self.store(fv, dst, 0, false);
            return true;
        }
        if op.kind == irc::OP_CONST {
            return self.const_into(c, b, op.data, dst, ti);
        }
        let a = self.operand_addr(c, b, opid, ti);
        if a == VNONE {
            return false;
        }
        self.memcpy(dst, a, ti.size);
        return true;
    }

    // ---- Constants ----

    // The source a constant's span indexes: an inlined constant's own module's.
    const fn const_src(c: &cbe::CEmit, b: &irc::CoreBody, k: &irc::Constant) str<'static> {
        let m = ast::pick(k.item.node != NODE_NONE, k.item.module, b.module);
        return Lower::p(c).modules.at(m as usize).source.as_str();
    }

    // Scalar constant `cid` of type `ti`.
    fn constant(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, cid: u32, ti: TyI) Value {
        let k = b.constants[cid as usize];
        if k.kind == irc::CK_UNIT || ti.cls == VC_ZST {
            return VNONE;
        }
        if ti.cls != VC_SCALAR {
            return self.fail_v("constant-memory");
        }
        let mt = ti.mty;
        if k.kind == irc::CK_INT || k.kind == irc::CK_BOOL {
            let mut v: i64 = k.val;
            if k.kind == irc::CK_INT && !k.int_value(Lower::const_src(c, b, &k), &mut v) {
                return self.fail_v("int-constant");
            }
            if is_float(mt) {
                let f = v as f64;
                return self.fconst(mt, ast::pick(mt == T_F32, fl::f32_bits(f as f32), fl::f64_bits(f)));
            }
            if is_vec(mt) {
                return self.fail_v("vector-int-constant");
            }
            return self.iconst(mt, v as u64);
        }
        if k.kind == irc::CK_FLOAT {
            let src = Lower::const_src(c, b, &k);
            if k.raw.end <= k.raw.start || k.raw.end as usize > src.len() {
                return self.fail_v("float-constant");
            }
            let r = float_literal_value(src, k.raw, mt == T_F32);
            if r.is_none() || !is_float(mt) {
                return self.fail_v("float-constant");
            }
            let f = r.unwrap();
            return self.fconst(mt, ast::pick(mt == T_F32, fl::f32_bits(f as f32), fl::f64_bits(f)));
        }
        if k.kind == irc::CK_FBITS {
            if !is_float(mt) {
                return self.fail_v("float-constant");
            }
            return self.fconst(mt, k.val as u64);
        }
        if k.kind == irc::CK_STR || k.kind == irc::CK_BYTES {
            // A C-string context: the bytes' address.
            return self.str_data(c, b, &k);
        }
        if k.kind == irc::CK_ITEM {
            let ia = Lower::ast(c, k.item.module);
            if k.targ_len() != 0 && ia.at_const(k.item.node).kind == NodeKind::NODE_CONST {
                let a = self.assoc_addr(c, b, &k);
                if a == VNONE {
                    return VNONE;
                }
                return self.load(mt, a, 0, false);
            }
            self.sbuf.clear();
            let mut s = String::new();
            if !c.callee_sym(
                b,
                k.item,
                k.targ_start(),
                k.targ_len(),
                TYPE_NONE,
                TYPE_NONE,
                TYPE_NONE,
                TYPE_NONE,
                &mut s,
            ) {
                return self.fail_v("item-sym");
            }
            let v = self.symaddr(s.as_str(), SK_FUNC);
            let fnn = ia.at_const(k.item.node);
            if fnn.kind == NodeKind::NODE_FUNCTION && ia.ext(k.item.node).function.is_extern() {
                self.mark_ext(s.as_str());
            }
            return v;
        }
        return self.fail_v("constant");
    }

    // The address of an associated constant's static.
    fn assoc_addr(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, k: &irc::Constant) Value {
        let mut s = String::new();
        if !c.assoc_const_ref(b, k, &mut s) {
            return self.fail_v("assoc-const");
        }
        return self.symaddr(s.as_str(), SK_DATA);
    }

    // The read-only data holding string constant `k`'s bytes and a terminating 0: its address.
    fn str_data(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, k: &irc::Constant) Value {
        let mut bytes = String::new();
        if k.kind == irc::CK_BYTES {
            // A folded `const fn` call's: the body holds them.
            for q in 0..k.val & 0xFFFFFFFF {
                bytes.push_byte(b.bytes[((k.val >> 32) + q) as usize]);
            }
        } else {
            let src = Lower::const_src(c, b, k);
            if k.raw.end as usize > src.len() || k.raw.end < k.raw.start {
                return self.fail_v("string-constant");
            }
            let mut tmp = String::new();
            cbe::str_const_bytes(src.slice(k.raw.start as usize, k.raw.end as usize), k.val, &mut tmp, &mut bytes);
        }
        self.str_len = bytes.len() as u64;
        let s = self.rodata(&mut bytes);
        let kk = self.sym_of(s);
        return self.inst(O_SYMADDR, T_PTR, 0, kk, 0, VNONE);
    }

    // The read-only data symbol `.str.<hash>.<size>` of `bytes` and a NUL (appended), one per content.
    fn rodata(self: &mut Self, bytes: &mut String) u32 {
        bytes.push_byte(0);
        self.sbuf.clear();
        self.sbuf.push_str(".str.");
        self.sbuf.push_hex(nm::hash_bytes(bytes.as_ptr(), bytes.len()), false);
        self.sbuf.push_byte(b'.');
        self.sbuf.push_u64(bytes.len() as u64);
        let s = self.pkg.symbol(self.sbuf.as_str(), SK_DATA);
        if self.pkg.syms[s as usize].def == NONE {
            let nr: []Reloc = [];
            let _ = self.pkg.add_data(
                s,
                bytes.len() as u32,
                0,
                true,
                unsafe Slice::<u8> { ptr: bytes.as_ptr(), len: bytes.len() },
                nr,
            );
        }
        return s;
    }

    // Store constant `cid` of memory type `ti` at `dst`.
    fn const_into(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, cid: u32, dst: Value, ti: TyI) bool {
        let k = b.constants[cid as usize];
        if ti.cls == VC_ZST || k.kind == irc::CK_UNIT {
            return true;
        }
        if ti.cls == VC_SCALAR {
            let v = self.constant(c, b, cid, ti);
            if v == VNONE {
                return false;
            }
            self.store(v, dst, 0, false);
            return true;
        }
        if k.kind == irc::CK_INT || k.kind == irc::CK_FLOAT {
            // An integer constant of an aggregate type is its zero; a number of a complex type is its
            // real part.
            self.memset0(dst, ti.size);
            let kb = Lower::builtin(c, b.module, k.ty);
            let cplx = kb == BuiltinType::BT_C32 || kb == BuiltinType::BT_C64 || k.ty == TYPE_NONE && k.kind == irc::CK_FLOAT;
            if cplx && (ti.size == 8 && ti.align == 4 || ti.size == 16 && ti.align == 8) {
                let ft = ast::pick(ti.size == 8, T_F32, T_F64);
                let fv = self.constant(c, b, cid, TyI { cls: VC_SCALAR, mty: ft, size: ti.size / 2, align: ti.align });
                if fv == VNONE {
                    return false;
                }
                self.store(fv, dst, 0, false);
            }
            return true;
        }
        if k.kind == irc::CK_STR || k.kind == irc::CK_BYTES {
            // A `str` view or a slice: the bytes' address and their length.
            let p = self.str_data(c, b, &k);
            if p == VNONE {
                return false;
            }
            let n = self.iconst(self.ptr_int(), self.str_len);
            self.store(p, dst, 0, false);
            self.store(n, dst, self.pkg.ptr_bytes, false);
            return true;
        }
        if k.kind == irc::CK_WIDE {
            let w = *Lower::ast(c, b.module).wide_lits.at(k.val as usize);
            for i in 0..ti.size / 8 {
                let lw = if i < 16 {
                    unsafe w.limbs[i as usize];
                } else {
                    0u64;
                };
                let v = self.iconst(T_I64, lw);
                self.store(v, dst, i * 8, false);
            }
            return true;
        }
        if k.kind == irc::CK_ITEM {
            let a = self.assoc_addr(c, b, &k);
            if a == VNONE {
                return false;
            }
            self.memcpy(dst, a, ti.size);
            return true;
        }
        return self.fail("constant-into");
    }
}

extend Lower {
    // ---- Scalar rvalues ----

    // The value of rvalue `rid`, of scalar type `ti`.
    fn rvalue(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rid: u32, ti: TyI) Value {
        let rv = b.rvalues[rid as usize];
        if rv.kind == irc::RV_USE {
            return self.operand(c, b, rv.a);
        }
        if rv.kind == irc::RV_REF || rv.kind == irc::RV_ADDR {
            return self.place_addr(c, b, rv.a);
        }
        if rv.kind == irc::RV_CAST {
            return self.cast(c, b, rv, ti);
        }
        if rv.kind == irc::RV_UNARY {
            return self.unary(c, b, rv, ti);
        }
        if rv.kind == irc::RV_BINARY {
            return self.binary(c, b, rv, ti);
        }
        if rv.kind == irc::RV_LEN {
            return self.len(c, b, rv.a, ti);
        }
        if rv.kind == irc::RV_DISCRIMINANT {
            return self.discriminant(c, b, rv.a, ti);
        }
        if rv.kind == irc::RV_INTRINSIC {
            return self.intrinsic(c, b, rv, ti);
        }
        if rv.kind == irc::RV_AGGREGATE && rv.c == irc::AGG_VARIANT {
            // A variant of an enum without payloads: its discriminant.
            let mut d: i64 = 0;
            if !self.variant_value(c, rv.item.module, rv.item.node, &mut d) {
                return VNONE;
            }
            return self.iconst(ti.mty, d as u64);
        }
        if rv.kind == irc::RV_CLOSURE && rv.b == 0 {
            let mut s = String::new();
            c.mg.closure_sym(rv.item.module, rv.item.node, &mut s);
            return self.symaddr(s.as_str(), SK_FUNC);
        }
        if rv.kind == irc::RV_SIMD {
            return self.simd(c, b, rv, ti, VNONE);
        }
        return self.fail_v("rvalue");
    }

    // The discriminant of enum variant `vd` (module `vm`): its explicit value, else one past the one
    // before it.
    fn variant_value(self: &mut Self, c: &mut cbe::CEmit, vm: ModuleId, vd: NodeId, out: &mut i64) bool {
        let pk = Lower::p(c);
        let mut pos: i64 = 0;
        let en = pk.variant_enum(DefId { module: vm, node: vd }, &mut pos);
        if pk.cir == null {
            return self.fail("variant");
        }
        let a = Lower::ast(c, vm);
        let mut ms = NodeList { start: 0, len: 0 };
        if en == NODE_NONE {
            // An extern enum's variant (the header checks assert its value): its enum in an extern block.
            ms = Lower::extern_enum_members(a, vd);
            if ms.len == 0 {
                return self.fail("variant");
            }
        } else {
            ms = a.ext(en).aggregate.members;
        }
        let mut cur: i64 = -1;
        let it = pk.cir as *mut iri::Interp;
        for k in 0..ms.len {
            let mid = unsafe a.list(ms)[k as usize];
            if !unsafe (*it).discr(vm, mid, cur, &mut cur) {
                return self.fail("discriminant");
            }
            if mid == vd {
                *out = cur;
                return true;
            }
        }
        return self.fail("variant");
    }

    // A numeric conversion (with the language's saturating float to integer), a mask's bits, a
    // vector's array, or a conversion method's call.
    fn cast(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, ti: TyI) Value {
        if rv.b == irc::CAST_COERCE_FROM {
            return self.coerce(c, b, rv, VNONE, ti);
        }
        let ft0 = Lower::op_ty(b, rv.a);
        let ft = ast::pick(ft0 == TYPE_NONE, rv.target, ft0);
        let mut fi = TyI { cls: 0 };
        if !self.ty(c, b.module, ft, &mut fi) {
            return VNONE;
        }
        self.hint = fi;
        if rv.b == irc::CAST_SIMD_ARRAY {
            // An array to its vector: the same bytes, aligned as the array.
            let a = self.operand_addr(c, b, rv.a, fi);
            if a == VNONE {
                return VNONE;
            }
            return self.inst(O_LOAD, ti.mty, log2(fi.align) as u16, a, VNONE, 0);
        }
        let v = self.operand(c, b, rv.a);
        if v == VNONE || fi.cls != VC_SCALAR {
            return self.fail_v("cast-operand");
        }
        let from = fi.mty;
        let to = ti.mty;
        let fs = Lower::signed(c, b.module, ft);
        let ts = Lower::signed(c, b.module, rv.target);
        if is_vec(from) || is_vec(to) {
            let flags = ast::pick(fs, VOP_SIGNED, 0) | ast::pick(ts, VOP_DSIGNED, 0) | ast::pick(
                rv.b == irc::CAST_UNCHECKED,
                VOP_UNCHECKED,
                0,
            );
            return self.vop(irc::OP_CAST as u16 | flags, to, [v], VNONE);
        }
        if rv.b == irc::CAST_MASK_BITS {
            return self.int_to(v, to, false);
        }
        return self.convert(v, from, to, fs, ts, rv.b == irc::CAST_UNCHECKED);
    }

    // Scalar `v` of type `from` (signed `fs`) as type `to` (signed `ts`).
    fn convert(self: &mut Self, v: Value, from: u8, to: u8, fs: bool, ts: bool, unchecked: bool) Value {
        if from == to {
            return v;
        }
        if is_float(from) && is_float(to) {
            return self.inst(ast::pick(to == T_F64, O_FPEXT, O_FPTRUNC), to, 0, v, VNONE, VNONE);
        }
        if is_float(from) {
            let it = ast::pick(to == T_PTR, self.ptr_int(), to);
            let r = self.inst(
                ast::pick(ts, O_FPTOSI, O_FPTOUI),
                it,
                ast::pick(unchecked, CV_UNCHECKED, 0),
                v,
                VNONE,
                VNONE,
            );
            return self.int_to(r, to, ts);
        }
        if is_float(to) {
            let mut x = v;
            if from == T_PTR {
                x = self.int_to(v, self.ptr_int(), false);
            }
            return self.inst(ast::pick(fs, O_SITOFP, O_UITOFP), to, 0, x, VNONE, VNONE);
        }
        return self.int_to(v, to, fs);
    }

    // `-x`, `!x`, `~x`: checked negation unless the build wraps.
    fn unary(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, ti: TyI) Value {
        let t = (rv.b as u8) as tt::TokenType;
        let mut x = self.operand(c, b, rv.a);
        if x == VNONE {
            return self.fail_v("unary-operand");
        }
        let at = Lower::op_ty(b, rv.a);
        let mut rm = b.module;
        let mut rt = at;
        let y = Lower::resolved(c, b.module, at, &mut rm, &mut rt);
        if y.kind == TypeKind::TYPE_REFERENCE {
            let mut ei = TyI { cls: 0 };
            if !self.ty(c, rm, y.as_data.elem, &mut ei) {
                return VNONE;
            }
            x = self.load(ei.mty, x, 0, false);
        }
        let ty = self.vty(x);
        let mut tyy = Lower::resolved(c, b.module, rv.target, &mut rm, &mut rt);
        if tyy.kind == TypeKind::TYPE_MASK {
            // A mask's `!`: its lane bits flipped, the bits above them kept 0.
            let n = c.mg.arr_len(rm, &tyy) as u64;
            let ones = self.iconst(ty, ~0u64 >> 64 - n);
            return self.arith(O_XOR, x, ones);
        }
        let signed = Lower::signed(c, b.module, at);
        if t == tt::TokenType::Minus {
            if is_float(ty) || is_vec(ty) && is_float(lane_type(ty)) {
                return self.inst(O_FNEG, ty, 0, x, VNONE, VNONE);
            }
            if is_vec(ty) {
                let z = self.zero(ty);
                if !self.wrap && signed {
                    let m = self.vop(
                        (irc::OP_SIMD + irc::SIMD_OVF_SUB as u32) as u16 | VOP_SIGNED,
                        self.mask_of(ty),
                        [z, x],
                        VNONE,
                    );
                    self.lane_check(m, "attempt to negate with overflow");
                }
                return self.arith(O_SUB, z, x);
            }
            let z = self.zero(ty);
            if !self.wrap && signed {
                let o = self.inst(O_SUBO, ty, OV_SIGNED, z, x, VNONE);
                self.check(VFLAG | o, "attempt to negate with overflow");
                return o;
            }
            return self.arith(O_SUB, z, x);
        }
        if t == tt::TokenType::Bang && !is_vec(ty) && Lower::builtin(c, b.module, at) == BuiltinType::BT_BOOL {
            let one = self.iconst(T_I8, 1);
            return self.arith(O_XOR, x, one);
        }
        if t == tt::TokenType::Bang || t == tt::TokenType::Tilde {
            return self.inst(O_NOT, ty, 0, x, VNONE, VNONE);
        }
        let _ = tyy;
        tyy = y;
        let _ = tyy;
        let _ = ti;
        return self.fail_v("unary");
    }

    // The mask type of vector type `vt`: an integer of one bit per lane.
    const fn mask_of(self: &Self, vt: u8) u8 {
        let n = lanes(vt);
        if n <= 8 {
            return T_I8;
        }
        if n <= 16 {
            return T_I16;
        }
        if n <= 32 {
            return T_I32;
        }
        return T_I64;
    }

    // Trap with `msg` when lane mask `m` has a bit set.
    fn lane_check(self: &mut Self, m: Value, msg: str) {
        self.lane_checks(m, msg, VNONE, "");
    }

    // Trap at the lowest lane set in lane mask `m0` or `m1` (VNONE: none): `lane <k>: ` and `msg0` when
    // `m0` holds that lane, else `msg1`, as C's `__sc_panic_lane` does.
    fn lane_checks(self: &mut Self, m0: Value, msg0: str, m1: Value, msg1: str) {
        let f = if m1 == VNONE {
            m0;
        } else {
            self.arith(O_OR, m0, m1);
        };
        let z = self.zero(self.vty(f));
        let fail = self.icmp(C_NE, f, z);
        let pb = self.cold_block();
        let next = self.block();
        let ep = self.edge(pb, NONE, NONE);
        let en = self.edge(next, NONE, NONE);
        let _ = self.inst(O_BR, T_NONE, 0, fail, ep, en);
        self.b.begin(pb);
        if m1 == VNONE {
            self.lane_panic(msg0, f);
        } else {
            // The lowest failing lane's bit, and whether `m0` holds it.
            let neg = self.arith(O_SUB, z, f);
            let low = self.arith(O_AND, f, neg);
            let in0 = self.arith(O_AND, m0, low);
            let s = self.icmp(C_NE, in0, z);
            let p0 = self.cold_block();
            let p1 = self.cold_block();
            let e0 = self.edge(p0, NONE, NONE);
            let e1 = self.edge(p1, NONE, NONE);
            let _ = self.inst(O_BR, T_NONE, 0, s, e0, e1);
            self.b.begin(p0);
            self.lane_panic(msg0, f);
            self.b.begin(p1);
            self.lane_panic(msg1, f);
        }
        self.b.begin(next);
    }

    // When `fail` is not 0, the call of the runtime's trap `name` with `args` (of types `tys`), which does
    // not return.
    fn trap_call(self: &mut Self, fail: Value, name: str, args: []Value, tys: []u32) {
        let pb = self.cold_block();
        let next = self.block();
        let ep = self.edge(pb, NONE, NONE);
        let en = self.edge(next, NONE, NONE);
        let _ = self.inst(O_BR, T_NONE, 0, fail, ep, en);
        self.b.begin(pb);
        let _ = self.call_sym(name, args, tys, T_NONE);
        let _ = self.inst(O_UNREACHABLE, T_NONE, 0, VNONE, VNONE, VNONE);
        self.b.begin(next);
    }

    // A panic with `msg` here; the code after it is unreachable.
    fn panic_now(self: &mut Self, msg: str) {
        let pb = self.cold_block();
        let next = self.block();
        let ep = self.edge(pb, NONE, NONE);
        let en = self.edge(next, NONE, NONE);
        let yes = self.iconst(T_I8, 1);
        let _ = self.inst(O_BR, T_NONE, 0, yes, ep, en);
        self.b.begin(pb);
        let mid = self.b.ref_msg(self.pkg.add_message(msg));
        let _ = self.inst(O_PANIC, T_NONE, 0, mid, VNONE, VNONE);
        self.b.begin(next);
    }

    // A new block that holds only a failure path.
    fn cold_block(self: &mut Self) u32 {
        let k = self.block();
        self.b.blocks.index_mut(k as usize).flags = BLOCK_COLD;
        return k;
    }

    // A panic with `msg` at the lowest lane set in mask `m`.
    fn lane_panic(self: &mut Self, msg: str, m: Value) {
        let mid = self.b.ref_msg(self.pkg.add_message(msg));
        let _ = self.inst(O_PANIC, T_NONE, 0, mid, m, VNONE);
    }

    // A vector operation `op` (an `irc::OP_*` code with VOP flags) on `args`, of result type `ty`;
    // `lanes` an index list in the pool or VNONE.
    fn vop(self: &mut Self, op: u16, ty: u8, args: []Value, lanes: u32) Value {
        let at = self.b.pool_list(args);
        return self.inst(O_VOP, ty, op, at, args.len() as u32, lanes);
    }

    // The operand `opid` of a binary operator as a value: a reference operand reads its referent.
    fn bin_operand(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        opid: u32,
        rm: &mut ModuleId,
        rt: &mut TypeId,
    ) Value {
        let t = Lower::op_ty(b, opid);
        let y = Lower::resolved(c, b.module, t, rm, rt);
        let v = self.operand(c, b, opid);
        if v == VNONE {
            return VNONE;
        }
        if y.kind == TypeKind::TYPE_REFERENCE {
            let em = *rm;
            let mut ei = TyI { cls: 0 };
            let _ = Lower::resolved(c, em, y.as_data.elem, rm, rt);
            if !self.ty(c, *rm, *rt, &mut ei) {
                return VNONE;
            }
            if ei.cls != VC_SCALAR {
                return v; // an aggregate referent stays addressed
            }
            return self.load(ei.mty, v, 0, false);
        }
        return v;
    }
}

extend Lower {
    // A binary operator: the language's meaning on integers (overflow, zero divisors, shift counts),
    // floats, pointers, `str`, vectors, and an aggregate's operator method.
    fn binary(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, ti: TyI) Value {
        let t = rv.c as tt::TokenType;
        let mut am = b.module;
        let mut at = TYPE_NONE;
        let ay = Lower::resolved(c, b.module, Lower::op_ty(b, rv.a), &mut am, &mut at);
        let aref = ay.kind == TypeKind::TYPE_REFERENCE;
        if aref {
            let _ = Lower::resolved(c, am, ay.as_data.elem, &mut am, &mut at);
        }
        let cmp = t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual || t == tt::TokenType::LessThan || t == tt::TokenType::LessThanEqual || t == tt::TokenType::GreaterThan || t == tt::TokenType::GreaterThanEqual;
        let mut ai = TyI { cls: 0 };
        if !self.ty(c, am, at, &mut ai) {
            return VNONE;
        }
        if (t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual) && Lower::agg_name(c, am, at) == "str" && Lower::ast(
            c,
            am,
        ).type_at(at).kind == TypeKind::TYPE_STRUCT {
            let r = self.str_eq(c, b, rv);
            if r == VNONE || t == tt::TokenType::EqualEqual {
                return r;
            }
            let one = self.iconst(T_I8, 1);
            return self.arith(O_XOR, r, one);
        }
        if ai.cls == VC_MEM && c.op_dispatch_agg(am, at) && (cmp || t.op_method().len() != 0) {
            return self.agg_op(c, b, rv, am, at, aref, ti, VNONE);
        }
        let mut bm = b.module;
        let mut bt = TYPE_NONE;
        let mut x = self.bin_operand(c, b, rv.a, &mut am, &mut at);
        let mut y = self.bin_operand(c, b, rv.b, &mut bm, &mut bt);
        if x == VNONE || y == VNONE {
            return self.fail_v("binary-operand");
        }
        let tx = self.vty(x);
        if is_vec(tx) {
            return self.vec_binary(c, b, rv, x, y, ti, Lower::signed(c, am, at));
        }
        let ya = *Lower::ast(c, am).type_at(at);
        if ya.kind == TypeKind::TYPE_POINTER && (t == tt::TokenType::Plus || t == tt::TokenType::Minus) {
            return self.ptr_arith(c, am, ya, t, x, y, bm, bt, ti);
        }
        let sa = Lower::signed(c, am, at);
        let sb = Lower::signed(c, bm, bt);
        if cmp {
            return self.compare(t, x, y, sa, sb);
        }
        let shift = t == tt::TokenType::LeftShift || t == tt::TokenType::RightShift;
        if shift {
            return self.shift(c, b, rv, t, x, y, sa, sb);
        }
        // Every other operator computes at the result's type.
        let ct = ti.mty;
        if is_float(ct) {
            x = self.convert(x, self.vty(x), ct, sa, sa, false);
            y = self.convert(y, self.vty(y), ct, sb, sb, false);
            if t == tt::TokenType::Percent {
                let tys: []u32 = [ct as u32, ct as u32];
                let args: []Value = [x, y];
                return self.call_sym(ast::pick(ct == T_F32, "fmodf", "fmod"), args, tys, ct);
            }
            let op = switch t {
                Plus => O_FADD,
                Minus => O_FSUB,
                Star => O_FMUL,
                Slash => O_FDIV,
                _ => 0u8,
            };
            if op == 0 {
                return self.fail_v("float-operator");
            }
            // Constant operands fold (`eval::float_op`): a NaN made at run time takes the host's sign.
            if (x & (VPARAM | VFLAG)) == 0 && (y & (VPARAM | VFLAG)) == 0 && self.b.insts[x as usize].op == O_FCONST && self.b.insts[y as usize].op == O_FCONST {
                let xi = self.b.insts[x as usize];
                let yi = self.b.insts[y as usize];
                return self.fconst(
                    ct,
                    le::float_op(op, ct, xi.b as u64 << 32 | xi.a as u64, yi.b as u64 << 32 | yi.a as u64),
                );
            }
            return self.arith(op, x, y);
        }
        x = self.int_to(x, ct, sa);
        y = self.int_to(y, ct, sb);
        let rb = Lower::builtin(c, b.module, rv.target);
        let signed = ast::pick(rb != BuiltinType::BT_VOID, Lower::signed(c, b.module, rv.target), sa);
        let checked = rb != BuiltinType::BT_VOID && rb != BuiltinType::BT_BOOL && rb != BuiltinType::BT_CHAR;
        if t == tt::TokenType::Plus || t == tt::TokenType::Minus || t == tt::TokenType::Star {
            let op = ast::pick(t == tt::TokenType::Plus, O_ADD, ast::pick(t == tt::TokenType::Minus, O_SUB, O_MUL));
            if checked && !self.wrap {
                let oo = ast::pick(
                    t == tt::TokenType::Plus,
                    O_ADDO,
                    ast::pick(t == tt::TokenType::Minus, O_SUBO, O_MULO),
                );
                let o = self.inst(oo, ct, ast::pick(signed, OV_SIGNED, 0), x, y, VNONE);
                self.check(
                    VFLAG | o,
                    ast::pick(
                        t == tt::TokenType::Plus,
                        "attempt to add with overflow",
                        ast::pick(
                            t == tt::TokenType::Minus,
                            "attempt to subtract with overflow",
                            "attempt to multiply with overflow",
                        ),
                    ),
                );
                return o;
            }
            return self.arith(op, x, y);
        }
        if t == tt::TokenType::Slash || t == tt::TokenType::Percent {
            let div = t == tt::TokenType::Slash;
            let mut cv: i64 = 0;
            let known = self.const_int(c, b, rv.b, &mut cv) && cv != 0 && !(signed && cv == -1);
            if !known && checked {
                let z = self.zero(ct);
                let f = self.icmp(C_EQ, y, z);
                self.check(
                    f,
                    ast::pick(
                        div,
                        "attempt to divide by zero",
                        "attempt to calculate the remainder with a divisor of zero",
                    ),
                );
                if signed {
                    let bits = type_bits(ct, self.pkg.ptr_bytes);
                    let mn = self.iconst(ct, 1u64 << (bits - 1) as u64);
                    let m1 = self.iconst(ct, 0xFFFFFFFFFFFFFFFF);
                    let fx = self.icmp(C_EQ, x, mn);
                    let fy = self.icmp(C_EQ, y, m1);
                    let f2 = self.arith(O_AND, fx, fy);
                    self.check(
                        f2,
                        ast::pick(
                            div,
                            "attempt to divide with overflow",
                            "attempt to calculate the remainder with overflow",
                        ),
                    );
                }
            }
            let op = if div {
                ast::pick(signed, O_SDIV, O_UDIV);
            } else {
                ast::pick(signed, O_SREM, O_UREM);
            };
            return self.arith(op, x, y);
        }
        let op = switch t {
            Ampersand => O_AND,
            AmpersandAmpersand => O_AND,
            Pipe => O_OR,
            PipePipe => O_OR,
            Caret => O_XOR,
            _ => 0u8,
        };
        if op == 0 {
            return self.fail_v("operator");
        }
        return self.arith(op, x, y);
    }

    // The value of integer constant operand `opid` into `out`; false for another operand.
    const fn const_int(self: &Self, c: &cbe::CEmit, b: &irc::CoreBody, opid: u32, out: &mut i64) bool {
        let op = b.operands[opid as usize];
        if op.kind != irc::OP_CONST {
            return false;
        }
        let k = b.constants[op.data as usize];
        return k.kind == irc::CK_INT && k.int_value(Lower::const_src(c, b, &k), out);
    }

    // A comparison of two scalars: at the wider integer type, signed when that one is.
    fn compare(self: &mut Self, t: tt::TokenType, x0: Value, y0: Value, sa: bool, sb: bool) Value {
        let mut x = x0;
        let mut y = y0;
        let tx = self.vty(x);
        let ty = self.vty(y);
        if is_float(tx) || is_float(ty) {
            let ft = ast::pick(tx == T_F64 || ty == T_F64, T_F64, T_F32);
            x = self.convert(x, tx, ft, sa, sa, false);
            y = self.convert(y, ty, ft, sb, sb, false);
            let cond = switch t {
                EqualEqual => C_OEQ,
                BangEqual => C_UNE,
                LessThan => C_OLT,
                LessThanEqual => C_OLE,
                GreaterThan => C_OGT,
                _ => C_OGE,
            };
            return self.inst(O_FCMP, T_I8, cond, x, y, VNONE);
        }
        let mut signed = sa && sb;
        if tx == T_PTR || ty == T_PTR {
            x = self.int_to(x, T_PTR, false);
            y = self.int_to(y, T_PTR, false);
            signed = false;
        } else if tx != ty {
            let pb = self.pkg.ptr_bytes;
            let wide = ast::pick(type_bits(tx, pb) >= type_bits(ty, pb), tx, ty);
            signed = ast::pick(type_bits(tx, pb) == type_bits(ty, pb), sa && sb, ast::pick(wide == tx, sa, sb));
            x = self.int_to(x, wide, sa);
            y = self.int_to(y, wide, sb);
        }
        let cond = switch t {
            EqualEqual => C_EQ,
            BangEqual => C_NE,
            LessThan => ast::pick(signed, C_SLT, C_ULT),
            LessThanEqual => ast::pick(signed, C_SLE, C_ULE),
            GreaterThan => ast::pick(signed, C_SGT, C_UGT),
            _ => ast::pick(signed, C_SGE, C_UGE),
        };
        return self.icmp(cond, x, y);
    }

    // `x << y`, `x >> y`: a count at or past the width traps in every build; the count converts to
    // the shifted type.
    fn shift(
        self: &mut Self,
        c: &cbe::CEmit,
        b: &irc::CoreBody,
        rv: irc::Rvalue,
        t: tt::TokenType,
        x: Value,
        y0: Value,
        sa: bool,
        sb: bool,
    ) Value {
        let tx = self.vty(x);
        let bits = type_bits(tx, self.pkg.ptr_bytes);
        let mut cv: i64 = 0;
        let known = self.const_int(c, b, rv.b, &mut cv) && cv >= 0 && cv < bits as i64;
        if !known {
            let c64 = self.int_to(y0, T_I64, sb);
            let lim = self.iconst(T_I64, bits);
            let f = self.icmp(C_UGE, c64, lim);
            self.check(
                f,
                ast::pick(
                    t == tt::TokenType::LeftShift,
                    "attempt to shift left with overflow",
                    "attempt to shift right with overflow",
                ),
            );
        }
        let y = self.int_to(y0, tx, false);
        if t == tt::TokenType::LeftShift {
            return self.arith(O_SHL, x, y);
        }
        return self.arith(ast::pick(sa, O_ASHR, O_LSHR), x, y);
    }

    // Pointer plus or minus an integer, or the distance between two pointers, in elements.
    fn ptr_arith(
        self: &mut Self,
        c: &mut cbe::CEmit,
        am: ModuleId,
        ya: Ty,
        t: tt::TokenType,
        x: Value,
        y: Value,
        bm: ModuleId,
        bt: TypeId,
        ti: TyI,
    ) Value {
        let mut ei = TyI { cls: 0 };
        if !self.ty(c, am, ya.as_data.elem, &mut ei) {
            return VNONE;
        }
        let yb = *Lower::ast(c, bm).type_at(bt);
        if yb.kind == TypeKind::TYPE_POINTER {
            if ei.size == 0 {
                let none: []Value = [];
                let nt: []u32 = [];
                let _ = self.call_sym("__sc_zst_ptrdiff", none, nt, T_NONE);
                return self.iconst(ti.mty, 0);
            }
            let pi = self.ptr_int();
            let xi = self.inst(O_PTRTOINT, pi, 0, x, VNONE, VNONE);
            let yi = self.inst(O_PTRTOINT, pi, 0, y, VNONE, VNONE);
            let d = self.arith(O_SUB, xi, yi);
            let sz = self.iconst(pi, ei.size);
            let q = self.arith(O_SDIV, d, sz);
            return self.int_to(q, ti.mty, true);
        }
        if ei.size == 0 {
            return x;
        }
        let mut ix = self.int_to(y, self.ptr_int(), Lower::signed(c, bm, bt));
        if t == tt::TokenType::Minus {
            let z = self.zero(self.ptr_int());
            ix = self.arith(O_SUB, z, ix);
        }
        return self.ptradd(x, ix, ei.size, 0);
    }

    // `a == b` on two `str` values: equal lengths and equal bytes.
    fn str_eq(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue) Value {
        let mut pa = [VNONE, VNONE];
        for k in 0..2 {
            let opid = ast::pick(k == 0, rv.a, rv.b);
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let y = Lower::resolved(c, b.module, Lower::op_ty(b, opid), &mut rm, &mut rt);
            let ti = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * self.pkg.ptr_bytes, align: self.pkg.ptr_bytes };
            let v = if y.kind == TypeKind::TYPE_REFERENCE {
                self.operand(c, b, opid);
            } else {
                self.operand_addr(c, b, opid, ti);
            };
            if v == VNONE {
                return VNONE;
            }
            unsafe pa[k] = v;
        }
        let pi = self.ptr_int();
        let la = self.load(pi, pa[0], self.pkg.ptr_bytes, false);
        let lb = self.load(pi, pa[1], self.pkg.ptr_bytes, false);
        let same = self.icmp(C_EQ, la, lb);
        let z = self.zero(pi);
        let n = self.inst(O_SELECT, pi, 0, same, la, z);
        let p0 = self.load(T_PTR, pa[0], 0, false);
        let p1 = self.load(T_PTR, pa[1], 0, false);
        let args: []Value = [p0, p1, n];
        let tys: []u32 = [T_PTR as u32, T_PTR as u32, pi as u32];
        let r = self.call_sym("memcmp", args, tys, T_I32);
        let z32 = self.zero(T_I32);
        let e = self.icmp(C_EQ, r, z32);
        return self.arith(O_AND, same, e);
    }

    // An operator on aggregates through the type's method: `eq` for `==` and `!=`, `cmp` for an
    // ordering, else the operator's (`add` for `+`). The result goes to `dst` when in memory.
    fn agg_op(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        rv: irc::Rvalue,
        am: ModuleId,
        at: TypeId,
        _aref: bool,
        ti: TyI,
        dst: Value,
    ) Value {
        let t = rv.c as tt::TokenType;
        let eq = t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual;
        let ord = !eq && (t == tt::TokenType::LessThan || t == tt::TokenType::LessThanEqual || t == tt::TokenType::GreaterThan || t == tt::TokenType::GreaterThanEqual);
        let mn = if eq {
            "eq";
        } else if ord {
            "cmp";
        } else {
            t.op_method();
        };
        let mut s = String::new();
        if !c.agg_op_sym(am, at, mn, &mut s) {
            return self.fail_v("agg-op-sym");
        }
        let mut args = [VNONE, VNONE];
        let mut tys = [T_PTR as u32, T_PTR as u32];
        for k in 0..2 {
            let opid = ast::pick(k == 0, rv.a, rv.b);
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let y = Lower::resolved(c, b.module, Lower::op_ty(b, opid), &mut rm, &mut rt);
            let mut oi = TyI { cls: 0 };
            if !self.ty(c, rm, rt, &mut oi) {
                return VNONE;
            }
            let isref = y.kind == TypeKind::TYPE_REFERENCE;
            let agg = y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE;
            // The left operand and an aggregate or compared right one by address; a scalar right
            // operand of an arithmetic operator by value.
            let v = if isref && (k == 0 || eq || ord || agg) {
                self.operand(c, b, opid);
            } else if k == 0 || eq || ord || agg {
                self.operand_addr(c, b, opid, oi);
            } else if isref {
                let p = self.operand(c, b, opid);
                let mut ei = TyI { cls: 0 };
                if !self.ty(c, rm, y.as_data.elem, &mut ei) {
                    return VNONE;
                }
                self.load(ei.mty, p, 0, false);
            } else {
                self.operand(c, b, opid);
            };
            if v == VNONE {
                return self.fail_v("agg-op-operand");
            }
            unsafe args[k] = v;
            unsafe tys[k] = self.vty(v);
        }
        if eq {
            let r = self.call_sym(s.as_str(), args, tys, T_I8);
            if t == tt::TokenType::EqualEqual {
                return r;
            }
            let one = self.iconst(T_I8, 1);
            return self.arith(O_XOR, r, one);
        }
        if ord {
            let r = self.call_sym(s.as_str(), args, tys, T_I32);
            let z = self.zero(T_I32);
            return self.compare(t, r, z, true, true);
        }
        if ti.cls == VC_SCALAR {
            return self.call_sym(s.as_str(), args, tys, ti.mty);
        }
        let lt = self.layout_of(c, b.module, rv.target, ti);
        let all: []Value = [args[0], args[1], dst];
        let atys: []u32 = [tys[0], tys[1], T_PTR as u32];
        let sg = self.b.signature(atys[0..2], 2, false, AGG | lt);
        let ap = self.b.pool_list(all);
        let k = self.sym(s.as_str(), SK_FUNC);
        let _ = self.inst(O_CALL, T_NONE, 3, k, sg, ap);
        return dst;
    }

    // A binary operator on vectors: lane by lane, with the scalar rules' traps per lane.
    fn vec_binary(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        rv: irc::Rvalue,
        x: Value,
        y: Value,
        ti: TyI,
        signed: bool,
    ) Value {
        let t = rv.c as tt::TokenType;
        let vt = self.vty(x);
        let flt = is_float(lane_type(vt));
        let sg = ast::pick(signed, VOP_SIGNED, 0);
        let mt = self.mask_of(vt);
        if t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual {
            let m = self.vop((irc::OP_SIMD + irc::SIMD_CMP_EQ as u32) as u16 | sg, mt, [x, y], VNONE);
            let all = self.iconst(mt, ~0u64 >> (64 - lanes(vt)) as u64);
            return self.icmp(ast::pick(t == tt::TokenType::EqualEqual, C_EQ, C_NE), m, all);
        }
        if t == tt::TokenType::LeftShift || t == tt::TokenType::RightShift {
            let bits = type_bits(lane_type(vt), 8);
            if !is_vec(self.vty(y)) {
                let c64 = self.int_to(y, T_I64, false);
                let lim = self.iconst(T_I64, bits);
                let f = self.icmp(C_UGE, c64, lim);
                // Every lane fails: the lowest is lane 0.
                self.check(
                    f,
                    ast::pick(
                        t == tt::TokenType::LeftShift,
                        "lane 0: attempt to shift left with overflow",
                        "lane 0: attempt to shift right with overflow",
                    ),
                );
                let cnt = self.int_to(y, lane_type(vt), false);
                return self.vop(
                    ast::pick(t == tt::TokenType::LeftShift, irc::OP_SHL_SCALAR, irc::OP_SHR_SCALAR) as u16 | sg,
                    vt,
                    [x, cnt],
                    VNONE,
                );
            }
            let lim = self.splat(vt, bits);
            let m = self.vop((irc::OP_SIMD + irc::SIMD_CMP_GE as u32) as u16, mt, [y, lim], VNONE);
            self.lane_check(
                m,
                ast::pick(
                    t == tt::TokenType::LeftShift,
                    "attempt to shift left with overflow",
                    "attempt to shift right with overflow",
                ),
            );
            return self.arith(ast::pick(t == tt::TokenType::LeftShift, O_SHL, ast::pick(signed, O_ASHR, O_LSHR)), x, y);
        }
        if flt {
            let op = switch t {
                Plus => O_FADD,
                Minus => O_FSUB,
                Star => O_FMUL,
                Slash => O_FDIV,
                _ => 0u8,
            };
            if op != 0 {
                return self.arith(op, x, y);
            }
            if t == tt::TokenType::Percent {
                return self.vop(irc::OP_REM as u16, vt, [x, y], VNONE);
            }
            return self.fail_v("vector-float-operator");
        }
        if t == tt::TokenType::Plus || t == tt::TokenType::Minus || t == tt::TokenType::Star {
            if !self.wrap {
                let code = ast::pick(
                    t == tt::TokenType::Plus,
                    irc::SIMD_OVF_ADD,
                    ast::pick(t == tt::TokenType::Minus, irc::SIMD_OVF_SUB, irc::SIMD_OVF_MUL),
                );
                let m = self.vop((irc::OP_SIMD + code as u32) as u16 | sg, mt, [x, y], VNONE);
                self.lane_check(
                    m,
                    ast::pick(
                        t == tt::TokenType::Plus,
                        "attempt to add with overflow",
                        ast::pick(
                            t == tt::TokenType::Minus,
                            "attempt to subtract with overflow",
                            "attempt to multiply with overflow",
                        ),
                    ),
                );
            }
            return self.arith(
                ast::pick(t == tt::TokenType::Plus, O_ADD, ast::pick(t == tt::TokenType::Minus, O_SUB, O_MUL)),
                x,
                y,
            );
        }
        if t == tt::TokenType::Slash || t == tt::TokenType::Percent {
            let div = t == tt::TokenType::Slash;
            let z = self.zero(vt);
            let m = self.vop((irc::OP_SIMD + irc::SIMD_CMP_EQ as u32) as u16, mt, [y, z], VNONE);
            let zmsg = ast::pick(
                div,
                "attempt to divide by zero",
                "attempt to calculate the remainder with a divisor of zero",
            );
            if signed {
                // A zero divisor and MIN / -1: one trap, at the lowest lane of either.
                let bits = type_bits(lane_type(vt), 8);
                let mn = self.splat(vt, 1u64 << (bits - 1) as u64);
                let m1 = self.splat(vt, 0xFFFFFFFFFFFFFFFF);
                let fx = self.vop((irc::OP_SIMD + irc::SIMD_CMP_EQ as u32) as u16, mt, [x, mn], VNONE);
                let fy = self.vop((irc::OP_SIMD + irc::SIMD_CMP_EQ as u32) as u16, mt, [y, m1], VNONE);
                let f = self.arith(O_AND, fx, fy);
                self.lane_checks(
                    m,
                    zmsg,
                    f,
                    ast::pick(
                        div,
                        "attempt to divide with overflow",
                        "attempt to calculate the remainder with overflow",
                    ),
                );
            } else {
                self.lane_check(m, zmsg);
            }
            let op = if div {
                ast::pick(signed, O_SDIV, O_UDIV);
            } else {
                ast::pick(signed, O_SREM, O_UREM);
            };
            return self.arith(op, x, y);
        }
        let op = switch t {
            Ampersand => O_AND,
            Pipe => O_OR,
            Caret => O_XOR,
            _ => 0u8,
        };
        if op == 0 {
            return self.fail_v("vector-operator");
        }
        let _ = ti;
        let _ = c;
        let _ = b;
        return self.arith(op, x, y);
    }

    // Vector type `vt` with every lane `v` (the lane's low bits).
    fn splat(self: &mut Self, vt: u8, v: u64) Value {
        let lb = type_bits(lane_type(vt), 8);
        let n = lanes(vt);
        let nw = (n * lb + 63) / 64;
        let w = self.b.words.len() as u32;
        for _ in 0..nw {
            self.b.words.push(0);
        }
        let mut lv = v;
        if lb < 64 {
            lv &= (1u64 << lb as u64) - 1;
        }
        for k in 0..n {
            let bit = (k * lb) as u64;
            let at = (w as u64 + bit / 64) as usize;
            self.b.words[at] = self.b.words[at] | lv << bit % 64;
        }
        return self.inst(O_WCONST, vt, 0, w, nw, VNONE);
    }
}

extend Lower {
    // The zero of type `t` here (not shared through the entry block).
    fn zero_here(self: &mut Self, t: u8) Value {
        if is_vec(t) {
            return self.splat(t, 0);
        }
        if is_float(t) {
            return self.fconst(t, 0);
        }
        return self.iconst(t, 0);
    }

    // `len` of place `pid`: an array's or a vector's count, a view's or a container's length field.
    fn len(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, pid: u32, ti: TyI) Value {
        let pl = b.places[pid as usize];
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let y = Lower::resolved(c, b.module, pl.ty, &mut rm, &mut rt);
        if y.kind == TypeKind::TYPE_ARRAY || y.kind == TypeKind::TYPE_SIMD {
            let n = c.mg.arr_len(rm, &y);
            if n < 0 {
                return self.fail_v("len-array");
            }
            return self.iconst(ti.mty, n as u64);
        }
        let nm = Lower::agg_name(c, rm, rt);
        let mut f = FieldAt {
            m: 0,
            t: TYPE_NONE,
            off: 0,
            idx: 0,
            node: NODE_NONE,
            variant: NODE_NONE,
            mty: T_NONE,
            packed: false,
        };
        if nm == "Array" {
            if !self.named_field(c, rm, rt, "data", &mut f) {
                return self.fail_v("len-array-field");
            }
            let mut fm = f.m;
            let mut ft = TYPE_NONE;
            let fy = Lower::resolved(c, f.m, f.t, &mut fm, &mut ft);
            return self.iconst(ti.mty, c.mg.arr_len(fm, &fy) as u64);
        }
        if nm != "Slice" && nm != "SliceMut" && nm != "Vector" && nm != "String" && nm != "str" {
            return self.fail_v("len");
        }
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, pid, &mut p) || p.kind != PR_MEM {
            return self.fail_v("len-place");
        }
        if !self.named_field(c, rm, rt, "len", &mut f) {
            return self.fail_v("len-field");
        }
        return self.load(ti.mty, p.addr, f.off, p.packed);
    }

    // The discriminant of the enum at place `pid` (behind its references).
    fn discriminant(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, pid: u32, ti: TyI) Value {
        let pl = b.places[pid as usize];
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, pid, &mut p) {
            return VNONE;
        }
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let mut y = Lower::resolved(c, b.module, pl.ty, &mut rm, &mut rt);
        let mut v = VNONE;
        let mut addr = p.addr;
        let mut val = p.kind != PR_MEM;
        if val {
            v = self.read(p);
        }
        for _ in 0..4 {
            if y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_POINTER {
                break;
            }
            addr = if val {
                v;
            } else {
                self.load(T_PTR, addr, 0, false);
            };
            val = false;
            y = Lower::resolved(c, rm, y.as_data.elem, &mut rm, &mut rt);
        }
        let mut ei = TyI { cls: 0 };
        if !self.ty(c, rm, rt, &mut ei) {
            return VNONE;
        }
        if ei.cls == VC_SCALAR {
            let x = if val {
                v;
            } else {
                self.load(ei.mty, addr, 0, false);
            };
            return self.int_to(x, ti.mty, true);
        }
        let mut el = EnumL { ok: false };
        if val || !self.enum_of(c, rm, rt, &mut el) {
            return self.fail_v("discriminant");
        }
        if el.niche != lay::NK_NONE {
            // The payload's first pointer word: null is `none`.
            let mut ds: i64 = 0;
            let mut dn: i64 = 0;
            if !self.variant_value(c, el.vm, el.some, &mut ds) || !self.variant_value(c, el.vm, el.none, &mut dn) {
                return VNONE;
            }
            let w = self.load(self.ptr_int(), addr, 0, false);
            let z = self.iconst(self.ptr_int(), 0);
            let set = self.icmp(C_NE, w, z);
            let vs = self.iconst(ti.mty, ds as u64);
            let vn = self.iconst(ti.mty, dn as u64);
            return self.inst(O_SELECT, ti.mty, 0, set, vs, vn);
        }
        let tag = self.load(el.tag, addr, 0, false);
        return self.int_to(tag, ti.mty, el.tag != T_I8);
    }

    // A compiler intrinsic of scalar result `ti`.
    fn intrinsic(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, ti: TyI) Value {
        let k = rv.c;
        if k == irc::IN_SIZEOF || k == irc::IN_ALIGNOF {
            let mut x = TyI { cls: 0 };
            if !self.ty(c, b.module, rv.b, &mut x) {
                return VNONE;
            }
            let v = if k == irc::IN_SIZEOF {
                x.size;
            } else {
                ast::pick(x.align == 0, 1u32, x.align);
            };
            return self.iconst(ti.mty, v);
        }
        if k == irc::IN_TYPE_INFO {
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let _ = Lower::resolved(c, b.module, rv.b, &mut rm, &mut rt);
            let a = self.type_info(c, rm, rt);
            if a == VNONE {
                return VNONE;
            }
            return self.load(ti.mty, a, 0, false);
        }
        if k == irc::IN_DANGLING {
            return self.sentinel(c, b.module, rv.b);
        }
        if k == irc::IN_ZEROED {
            if c.mg.holds_box(b.module, rv.target, 0) {
                self.panic_now(cbe::ZEROED_BOX_MSG);
            }
            return self.zero_here(ti.mty);
        }
        if k == irc::IN_VOLATILE_LOAD {
            let a = self.operand(c, b, b.oper_pool[rv.a as usize]);
            if a == VNONE {
                return VNONE;
            }
            let al = log2(type_align(ti.mty, self.pkg.ptr_bytes)) as u16;
            return self.inst(O_LOAD, ti.mty, al | MEM_VOLATILE, a, VNONE, 0);
        }
        if k == irc::IN_VA_ARG {
            let ap = self.place_addr_op(c, b, b.oper_pool[rv.a as usize]);
            if ap == VNONE {
                return VNONE;
            }
            // A variadic argument arrives promoted: a float as a double, a narrow integer as an int.
            let mt = ti.mty;
            if mt == T_F32 {
                let d = self.inst(O_VAARG, T_F64, 0, ap, VNONE, VNONE);
                return self.inst(O_FPTRUNC, T_F32, 0, d, VNONE, VNONE);
            }
            if mt == T_I8 || mt == T_I16 {
                let d = self.inst(O_VAARG, T_I32, 0, ap, VNONE, VNONE);
                return self.inst(O_TRUNC, mt, 0, d, VNONE, VNONE);
            }
            return self.inst(O_VAARG, mt, 0, ap, VNONE, VNONE);
        }
        if k == irc::IN_DYN_TID || k == irc::IN_DYN_DATA {
            let opid = b.oper_pool[rv.a as usize];
            let fat = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * self.pkg.ptr_bytes, align: self.pkg.ptr_bytes };
            let fa = self.operand_addr(c, b, opid, fat);
            if fa == VNONE {
                return VNONE;
            }
            if k == irc::IN_DYN_DATA {
                return self.load(T_PTR, fa, 0, false);
            }
            // The table's `tid` names the erased type: equal to the queried type's spelling.
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let y = Lower::resolved(c, b.module, rv.target, &mut rm, &mut rt);
            if y.kind != TypeKind::TYPE_REFERENCE {
                return self.fail_v("dyn-tid");
            }
            let mut sp = String::new();
            if !c.mg.type_m(rm, y.as_data.elem, &mut sp) {
                return self.fail_v("dyn-tid");
            }
            let vt = self.load(T_PTR, fa, self.pkg.ptr_bytes, false);
            let tid = self.load(T_PTR, vt, self.pkg.ptr_bytes, false);
            let lit = self.cstr(sp.as_str());
            let args: []Value = [tid, lit];
            let tys: []u32 = [T_PTR as u32, T_PTR as u32];
            let r = self.call_sym("strcmp", args, tys, T_I32);
            let z = self.zero(T_I32);
            return self.icmp(C_EQ, r, z);
        }
        let n = check_args(k);
        let mut v = [VNONE, VNONE, VNONE];
        for i in 0..n {
            let x = self.operand(c, b, b.oper_pool[(rv.a + i) as usize]);
            if x == VNONE {
                return self.fail_v("intrinsic-operand");
            }
            unsafe v[i as usize] = if k == irc::IN_LIKELY || k == irc::IN_UNLIKELY {
                x;
            } else {
                self.int_to(x, self.ptr_int(), false);
            };
        }
        if k == irc::IN_BOUNDS {
            let f = self.icmp(C_UGE, v[0], v[1]);
            if rv.item.node == irc::CHECK_LANES {
                // A vector's lane index: the trap names the index and the lane count (`u64` parameters).
                let tys: [u32; 2] = [T_I64 as u32, T_I64 as u32];
                let args: [Value; 2] = [self.int_to(v[0], T_I64, false), self.int_to(v[1], T_I64, false)];
                self.trap_call(f, "__sc_index_bounds", args[0..2], tys[0..2]);
            } else {
                self.check(f, "index out of bounds");
            }
            return self.int_to(v[0], ti.mty, false);
        }
        if k == irc::IN_BOUNDS_PROVEN || k == irc::IN_BOUNDS_GROUP_PROVEN {
            return self.int_to(v[0], ti.mty, false);
        }
        if k == irc::IN_GROUP_FITS {
            // `index <= len && width <= len - index`: the room is read only where it does not wrap.
            let f1 = self.icmp(C_ULE, v[0], v[1]);
            let room = self.arith(O_SUB, v[1], v[0]);
            let f2 = self.icmp(C_ULE, v[2], room);
            return self.arith(O_AND, f1, f2);
        }
        if k == irc::IN_BOUNDS_GROUP {
            // `index > len`, then `width > len - index` where it does not wrap: one branch each, to one
            // failure block.
            let f1 = self.icmp(C_UGT, v[0], v[1]);
            if rv.item.node == irc::CHECK_VEC {
                // A vector load or store: the trap names the lanes, the start and the length (`u64` parameters).
                let tys: [u32; 3] = [T_I64 as u32, T_I64 as u32, T_I64 as u32];
                let args: [Value; 3] = [
                    self.int_to(v[2], T_I64, false),
                    self.int_to(v[0], T_I64, false),
                    self.int_to(v[1], T_I64, false),
                ];
                let pb = self.cold_block();
                let b2 = self.block();
                let e1 = self.edge(pb, NONE, NONE);
                let e2 = self.edge(b2, NONE, NONE);
                let _ = self.inst(O_BR, T_NONE, 0, f1, e1, e2);
                self.b.begin(pb);
                let _ = self.call_sym("__sc_vec_bounds", args[0..3], tys[0..3], T_NONE);
                let _ = self.inst(O_UNREACHABLE, T_NONE, 0, VNONE, VNONE, VNONE);
                self.b.begin(b2);
                let room = self.arith(O_SUB, v[1], v[0]);
                let f2 = self.icmp(C_UGT, v[2], room);
                let next = self.block();
                let e3 = self.edge(pb, NONE, NONE);
                let e4 = self.edge(next, NONE, NONE);
                let _ = self.inst(O_BR, T_NONE, 0, f2, e3, e4);
                self.b.begin(next);
            } else {
                self.check(f1, "index out of bounds");
                let room = self.arith(O_SUB, v[1], v[0]);
                let f2 = self.icmp(C_UGT, v[2], room);
                self.check(f2, "index out of bounds");
            }
            return self.int_to(v[0], ti.mty, false);
        }
        if k == irc::IN_RANGE_BOUNDS {
            // One branch per bound, to one panic block.
            let f1 = self.icmp(C_UGT, v[0], v[1]);
            self.check(f1, "range out of bounds");
            let f2 = self.icmp(C_UGT, v[1], v[2]);
            self.check(f2, "range out of bounds");
            return self.int_to(v[1], ti.mty, false);
        }
        if k == irc::IN_RANGE_BOUNDS_PROVEN {
            return self.int_to(v[1], ti.mty, false);
        }
        if k == irc::IN_LIKELY || k == irc::IN_UNLIKELY {
            return v[0];
        }
        if k == irc::IN_RETURN_ADDRESS {
            if tgt::isa(Lower::p(c).arch).return_address {
                return self.inst(O_RETADDR, T_PTR, 0, VNONE, VNONE, VNONE);
            }
            return self.iconst(T_PTR, 0);
        }
        if k == irc::IN_CHUNK {
            // The chunk's end: the loop's end where no tick prints, else as far as the tick budget
            // left reaches, which the chunk's other iterations are charged.
            if self.spc == NONE {
                return self.int_to(v[1], ti.mty, false);
            }
            let i = self.int_to(v[0], T_I64, false);
            let e = self.int_to(v[1], T_I64, false);
            let d = self.arith(O_SUB, e, i);
            let bud = self.read_var(self.spc, self.cur);
            let b64 = self.int_to(bud, T_I64, true);
            let over = self.icmp(C_UGT, d, b64);
            let nn = self.inst(O_SELECT, T_I64, 0, over, b64, d);
            let one = self.iconst(T_I64, 1);
            let used = self.arith(O_SUB, nn, one);
            let u32v = self.int_to(used, T_I32, false);
            let left = self.arith(O_SUB, bud, u32v);
            self.write_var(self.spc, left);
            let r = self.arith(O_ADD, i, nn);
            return self.int_to(r, ti.mty, false);
        }
        return self.fail_v("intrinsic");
    }

    // The address of the place of operand `opid` (a copy or a move).
    fn place_addr_op(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, opid: u32) Value {
        let op = b.operands[opid as usize];
        if op.kind == irc::OP_CONST {
            return self.fail_v("place-operand");
        }
        return self.place_addr(c, b, op.data);
    }

    // The address of read-only C string `s` and its terminating 0.
    fn cstr(self: &mut Self, s: str) Value {
        let mut bytes = String::from_str(s);
        let sy = self.rodata(&mut bytes);
        let k = self.sym_of(sy);
        return self.inst(O_SYMADDR, T_PTR, 0, k, 0, VNONE);
    }

    // The address of a vector of type `vt` at element `start` of the slice view at `view`; pointer `view`
    // itself when `raw`.
    fn vaddr(self: &mut Self, view: Value, start: Value, vt: u8, raw: bool) Value {
        if raw {
            return view;
        }
        let p = self.load(T_PTR, view, 0, false);
        return self.ptradd(p, start, type_bytes(lane_type(vt), self.pkg.ptr_bytes), 0);
    }

    // A vector operation (`RV_SIMD`): its operands as values (a view or an array in memory by its
    // address), its index list in the pool. A store has no result; `dst` takes a memory result.
    fn simd(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, ti: TyI, dst: Value) Value {
        let mut args = Vector::<Value>::new();
        let mut signed = false;
        let mut mem_arg = false;
        let mut last_mem = false;
        for i in 0..rv.b {
            let opid = b.oper_pool[(rv.a + i) as usize];
            let t = Lower::op_ty(b, opid);
            let mut oi = TyI { cls: 0 };
            if !self.ty(c, b.module, t, &mut oi) {
                return VNONE;
            }
            if i == 0 {
                signed = Lower::signed(c, b.module, t);
            }
            mem_arg = mem_arg || oi.cls == VC_MEM;
            last_mem = oi.cls == VC_MEM;
            let v = if oi.cls == VC_MEM {
                self.operand_addr(c, b, opid, oi);
            } else {
                self.operand(c, b, opid);
            };
            if v == VNONE {
                return self.fail_v("simd-operand");
            }
            args.push(v);
        }
        if rv.b == 0 {
            signed = Lower::signed(c, b.module, rv.target);
        }
        let mut lanes = VNONE;
        if (rv.c == irc::SIMD_SWIZZLE || rv.c == irc::SIMD_SHUFFLE) && rv.item.node != irc::IR_NONE {
            let n = b.simd_aux[rv.item.node as usize];
            lanes = self.b.pool.len() as u32;
            self.b.pool.push(n);
            for k in 0..n {
                self.b.pool.push(irc::aux_lane(b, rv.item.node, k));
            }
        } else if rv.c == irc::SIMD_SWIZZLE || rv.c == irc::SIMD_SHUFFLE {
            return self.fail_v("simd-lanes");
        }
        // The second lane type: the result's, or for `cast_changed` its cast result operand's.
        let wt = if rv.c == irc::SIMD_CAST_CHANGED && rv.b > 1 {
            Lower::op_ty(b, b.oper_pool[(rv.a + 1) as usize]);
        } else {
            rv.target;
        };
        let dsg = wt != TYPE_NONE && Lower::signed(c, b.module, wt);
        let code = (irc::OP_SIMD + rv.c as u32) as u16 | ast::pick(signed, VOP_SIGNED, 0) | ast::pick(
            dsg,
            VOP_DSIGNED,
            0,
        );
        let rt = ast::pick(ti.cls == VC_SCALAR, ti.mty, T_NONE);
        // A load or store of a whole vector (its bounds checked before): the slice's pointer, then a plain
        // access of no alignment, which the optimizer forwards and hoists like any other.
        let raw = rv.c == irc::SIMD_LOAD_RAW || rv.c == irc::SIMD_STORE_RAW;
        if (rv.c == irc::SIMD_LOAD || rv.c == irc::SIMD_LOAD_RAW) && ti.cls == VC_SCALAR && is_vec(ti.mty) {
            let st = ast::pick(raw, VNONE, args[args.len() - 1]);
            return self.load(ti.mty, self.vaddr(args[0], st, ti.mty, raw), 0, true);
        }
        if (rv.c == irc::SIMD_STORE || raw) && !last_mem {
            let v = args[args.len() - 1];
            let st = ast::pick(raw, VNONE, args[1]);
            let (a, o) = self.fold_addr(self.vaddr(args[0], st, self.vty(v), raw), 0);
            return self.inst(O_STORE, T_NONE, 0, a, v, o);
        }
        // An operation one backend entry computes whole calls it (`CEmit::lir_simd_entry`): its intrinsics
        // in place of the lane loop, which the inliner then splices.
        let mut ename = String::new();
        if ti.cls == VC_SCALAR && !mem_arg && c.lir_simd_entry(b, &rv, &mut ename) {
            let mut tys = Vector::<u32>::with_capacity(args.len());
            for i in 0..args.len() {
                tys.push(self.vty(args[i]));
            }
            return self.call_sym(ename.as_str(), args[0..args.len()], tys[0..tys.len()], ti.mty);
        }
        if ti.cls == VC_MEM {
            args.push(dst);
        }
        return self.vop(code, rt, args[0..args.len()], lanes);
    }
}

// The operand count of check intrinsic `k`, and of the one-operand hints.
const fn check_args(k: u8) u32 {
    if k == irc::IN_LIKELY || k == irc::IN_UNLIKELY {
        return 1;
    }
    if k == irc::IN_BOUNDS || k == irc::IN_BOUNDS_PROVEN || k == irc::IN_CHUNK {
        return 2;
    }
    if irc::is_check(k) || k == irc::IN_GROUP_FITS {
        return 3;
    }
    return 0;
}

extend Lower {
    // ---- Memory rvalues ----

    // Rvalue `rid` of memory type `ti`, built at `dst`.
    fn rvalue_into(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        rid: u32,
        dst: Value,
        ti: TyI,
        place_ty: TypeId,
    ) bool {
        let rv = b.rvalues[rid as usize];
        if rv.kind == irc::RV_USE {
            if rv.target != TYPE_NONE && self.arr_view(c, b, rv.a, rv.target, dst) {
                return true;
            }
            if self.err.len() != 0 {
                return false;
            }
            return self.operand_into(c, b, rv.a, dst, ti);
        }
        if rv.kind == irc::RV_AGGREGATE {
            return self.aggregate(c, b, rv, dst, ti, place_ty);
        }
        if rv.kind == irc::RV_REPEAT {
            return self.repeat(c, b, rv, dst, place_ty);
        }
        if rv.kind == irc::RV_SLICE {
            return self.slice(c, b, rv, dst, place_ty);
        }
        if rv.kind == irc::RV_CLOSURE {
            return self.closure_env(c, b, rv, dst);
        }
        if rv.kind == irc::RV_DYN {
            return self.dyn_value(c, b, rv, dst);
        }
        if rv.kind == irc::RV_CAST && rv.b == irc::CAST_COERCE_FROM {
            return self.coerce(c, b, rv, dst, ti) != VNONE || self.err.len() == 0;
        }
        if rv.kind == irc::RV_CAST && rv.b != irc::CAST_SIMD_ARRAY {
            // C casts an aggregate only to its own type: a copy.
            return self.operand_into(c, b, rv.a, dst, ti);
        }
        if rv.kind == irc::RV_CAST && rv.b == irc::CAST_SIMD_ARRAY {
            // A vector to its array: the same bytes, aligned as the array.
            let v = self.operand(c, b, rv.a);
            if v == VNONE {
                return self.fail("simd-array");
            }
            let _ = self.inst(O_STORE, T_NONE, log2(ti.align) as u16, dst, v, 0);
            return true;
        }
        if rv.kind == irc::RV_BINARY {
            let mut am = b.module;
            let mut at = TYPE_NONE;
            let ay = Lower::resolved(c, b.module, Lower::op_ty(b, rv.a), &mut am, &mut at);
            let aref = ay.kind == TypeKind::TYPE_REFERENCE;
            if aref {
                let _ = Lower::resolved(c, am, ay.as_data.elem, &mut am, &mut at);
            }
            return self.agg_op(c, b, rv, am, at, aref, ti, dst) != VNONE;
        }
        if rv.kind == irc::RV_INTRINSIC && rv.c == irc::IN_ZEROED {
            if c.mg.holds_box(b.module, rv.target, 0) {
                // A value that holds a Box has no all-zero form: the instance panics.
                self.panic_now(cbe::ZEROED_BOX_MSG);
            }
            self.memset0(dst, ti.size);
            return true;
        }
        if rv.kind == irc::RV_INTRINSIC && rv.c == irc::IN_VOLATILE_LOAD {
            let a = self.operand(c, b, b.oper_pool[rv.a as usize]);
            if a == VNONE {
                return false;
            }
            self.volatile_copy(dst, a, ti, true);
            return true;
        }
        if rv.kind == irc::RV_INTRINSIC && rv.c == irc::IN_TYPE_NAME {
            // The instance's spelling, as a `str` constant.
            if rv.b == TYPE_NONE {
                return self.fail("type-name");
            }
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let _ = Lower::resolved(c, b.module, rv.b, &mut rm, &mut rt);
            let mut nm = String::new();
            rnd::render_qualified_name(c.pkg, Lower::p(c).module_ast_const(rm), rt, &mut nm);
            let n = self.iconst(self.ptr_int(), nm.len() as u64);
            let s = self.cstr(nm.as_str());
            self.store(s, dst, 0, false);
            self.store(n, dst, self.pkg.ptr_bytes, false);
            return true;
        }
        if rv.kind == irc::RV_INTRINSIC && rv.c == irc::IN_TYPE_INFO {
            // The descriptor's value.
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let _ = Lower::resolved(c, b.module, rv.b, &mut rm, &mut rt);
            let a = self.type_info(c, rm, rt);
            if a == VNONE {
                return false;
            }
            self.memcpy(dst, a, ti.size);
            return true;
        }
        if rv.kind == irc::RV_SIMD {
            return self.simd(c, b, rv, ti, dst) != VNONE || self.err.len() == 0;
        }
        return self.fail("rvalue-memory");
    }

    // An array operand used as a slice view: `{ &array, N }`; false when `opid` is no array or `want`
    // no view.
    fn arr_view(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, opid: u32, want: TypeId, dst: Value) bool {
        let op = b.operands[opid as usize];
        if op.kind == irc::OP_CONST {
            return false;
        }
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let y = Lower::resolved(c, b.module, op.ty, &mut rm, &mut rt);
        if y.kind != TypeKind::TYPE_ARRAY {
            return false;
        }
        let n = c.mg.arr_len(rm, &y);
        let mut wm = b.module;
        let mut wt = TYPE_NONE;
        let wy = Lower::resolved(c, b.module, want, &mut wm, &mut wt);
        let nm = Lower::agg_name(c, wm, wt);
        if wy.kind != TypeKind::TYPE_INSTANCE || nm != "Slice" && nm != "SliceMut" || n < 0 {
            return false;
        }
        let a = self.place_addr(c, b, op.data);
        if a == VNONE {
            return false;
        }
        let len = self.iconst(self.ptr_int(), n as u64);
        self.store(a, dst, 0, false);
        self.store(len, dst, self.pkg.ptr_bytes, false);
        return true;
    }

    // A struct, tuple, payload-carrying variant or array literal at `dst`.
    fn aggregate(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        rv: irc::Rvalue,
        dst: Value,
        ti: TyI,
        place_ty: TypeId,
    ) bool {
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let ty = Lower::resolved(c, b.module, rv.target, &mut rm, &mut rt);
        if rv.c == irc::AGG_ARRAY {
            // An array literal coerced to a view: the elements in a slot of their own, then the view.
            let mut pm = b.module;
            let mut pt = TYPE_NONE;
            let py = Lower::resolved(c, b.module, place_ty, &mut pm, &mut pt);
            let pn = Lower::agg_name(c, pm, pt);
            let view = py.kind == TypeKind::TYPE_INSTANCE && (pn == "Slice" || pn == "SliceMut");
            let mut ei = TyI { cls: 0 };
            let et = if view {
                Lower::ast(c, pm).instance(py.as_data.inst).args[0];
            } else if ty.kind == TypeKind::TYPE_ARRAY {
                ty.as_data.arr.elem;
            } else {
                TYPE_NONE;
            };
            let em = ast::pick(view, pm, rm);
            if et == TYPE_NONE || !self.ty(c, em, et, &mut ei) {
                return self.fail("array-literal");
            }
            let base = if view {
                let at = TyI {
                    cls: VC_MEM,
                    mty: T_NONE,
                    size: ast::pick(ei.size * rv.b == 0, 1u32, ei.size * rv.b),
                    align: ei.align,
                };
                self.new_slot(at);
            } else {
                dst;
            };
            let mut holes = false;
            for i in 0..rv.b {
                holes = holes || b.oper_pool[(rv.a + i) as usize] == irc::IR_NONE;
            }
            if holes {
                self.memset0(base, ei.size * rv.b);
            }
            for i in 0..rv.b {
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == irc::IR_NONE {
                    continue;
                }
                let ea = self.ptradd(base, VNONE, 0, i * ei.size);
                if !self.operand_into(c, b, opid, ea, ei) {
                    return false;
                }
            }
            if view {
                let len = self.iconst(self.ptr_int(), rv.b);
                self.store(base, dst, 0, false);
                self.store(len, dst, self.pkg.ptr_bytes, false);
            }
            return true;
        }
        let mut fl = Vector::<FieldAt>::new();
        if !self.fields_of(c, rm, rt, &mut fl) {
            return self.fail("aggregate-fields");
        }
        if rv.c == irc::AGG_VARIANT {
            let mut d: i64 = 0;
            let mut el = EnumL { ok: false };
            if !self.variant_value(c, rv.item.module, rv.item.node, &mut d) || !self.enum_of(c, rm, rt, &mut el) {
                return false;
            }
            if el.niche != lay::NK_NONE && rv.item.node != el.some {
                // A niche enum has no tag: `none` is the all-zero value.
                self.memset0(dst, el.size);
                return true;
            }
            if el.niche == lay::NK_NONE {
                let tag = self.iconst(el.tag, d as u64);
                self.store(tag, dst, 0, false);
            }
            let mut k: u32 = 0;
            for j in 0..fl.len() {
                let f = fl[j];
                if f.variant != rv.item.node || f.idx == 0xFFFFFFFF {
                    continue;
                }
                if k >= rv.b {
                    break;
                }
                let opid = b.oper_pool[(rv.a + k) as usize];
                k += 1;
                if opid == irc::IR_NONE {
                    continue;
                }
                let mut fi = TyI { cls: 0 };
                if !self.ty(c, f.m, f.t, &mut fi) {
                    return false;
                }
                let fa = self.ptradd(dst, VNONE, 0, f.off);
                if !self.operand_into(c, b, opid, fa, fi) {
                    return false;
                }
            }
            return true;
        }
        // Struct and tuple members in declaration order; an omitted member is 0.
        let mut holes = rv.b != fl.len() as u32;
        for i in 0..rv.b {
            holes = holes || b.oper_pool[(rv.a + i) as usize] == irc::IR_NONE;
        }
        if holes {
            self.memset0(dst, ti.size);
        }
        for i in 0..rv.b {
            let opid = b.oper_pool[(rv.a + i) as usize];
            if opid == irc::IR_NONE || i as usize >= fl.len() {
                continue;
            }
            let f = fl[i as usize];
            let mut fi = TyI { cls: 0 };
            if !self.ty(c, f.m, f.t, &mut fi) {
                return false;
            }
            let fa = self.ptradd(dst, VNONE, 0, f.off);
            if fi.cls == VC_SCALAR && f.packed {
                let v = self.operand(c, b, opid);
                if v == VNONE {
                    return self.fail("aggregate-member");
                }
                self.store(v, fa, 0, true);
                continue;
            }
            if !self.operand_into(c, b, opid, fa, fi) {
                return false;
            }
        }
        return true;
    }

    // `[v; n]` at `dst`: a fill of zero bytes, unrolled stores up to 16 elements, else a loop.
    fn repeat(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, dst: Value, place_ty: TypeId) bool {
        // The element type is the array's: the operand converts to it.
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let y = Lower::resolved(c, b.module, place_ty, &mut rm, &mut rt);
        let mut n: i64 = -1;
        if !self.const_int(c, b, rv.b, &mut n) || n < 0 {
            n = ast::pick(y.kind == TypeKind::TYPE_ARRAY, c.mg.arr_len(rm, &y), -1);
        }
        if n < 0 {
            return self.fail("repeat-count");
        }
        let mut em = b.module;
        let mut et = Lower::op_ty(b, rv.a);
        if y.kind == TypeKind::TYPE_ARRAY {
            em = rm;
            et = y.as_data.arr.elem;
        }
        let mut ei = TyI { cls: 0 };
        if !self.ty(c, em, et, &mut ei) {
            return false;
        }
        if ei.cls == VC_ZST || n == 0 {
            return true;
        }
        let mut z: i64 = 1;
        if ei.cls == VC_SCALAR && !is_float(ei.mty) && self.const_int(c, b, rv.a, &mut z) && z == 0 {
            self.memset0(dst, ei.size * n as u32);
            return true;
        }
        if n <= 16 {
            for i in 0..n as u32 {
                let ea = self.ptradd(dst, VNONE, 0, i * ei.size);
                if !self.operand_into(c, b, rv.a, ea, ei) {
                    return false;
                }
            }
            return true;
        }
        // The first element, then a loop copying it into the others (a counter in memory).
        if !self.operand_into(c, b, rv.a, dst, ei) {
            return false;
        }
        let pi = self.ptr_int();
        let cnt = self.temp(TyI { cls: VC_SCALAR, mty: pi, size: self.pkg.ptr_bytes, align: self.pkg.ptr_bytes });
        let one = self.iconst(pi, 1);
        self.store(one, cnt, 0, false);
        let head = self.block();
        let body = self.block();
        let done = self.block();
        let eh = self.edge(head, NONE, NONE);
        let _ = self.inst(O_JMP, T_NONE, 0, eh, VNONE, VNONE);
        self.b.begin(head);
        let i = self.load(pi, cnt, 0, false);
        let lim = self.iconst(pi, n as u64);
        let more = self.icmp(C_ULT, i, lim);
        let eb = self.edge(body, NONE, NONE);
        let ed = self.edge(done, NONE, NONE);
        let _ = self.inst(O_BR, T_NONE, 0, more, eb, ed);
        self.b.begin(body);
        let i2 = self.load(pi, cnt, 0, false);
        let ea = self.ptradd(dst, i2, ei.size, 0);
        if ei.cls == VC_SCALAR {
            let v = self.load(ei.mty, dst, 0, false);
            self.store(v, ea, 0, false);
        } else {
            self.memcpy(ea, dst, ei.size);
        }
        let one2 = self.iconst(pi, 1);
        let nx = self.arith(O_ADD, i2, one2);
        self.store(nx, cnt, 0, false);
        let eh2 = self.edge(head, NONE, NONE);
        let _ = self.inst(O_JMP, T_NONE, 0, eh2, VNONE, VNONE);
        self.b.begin(done);
        return true;
    }

    // A view of part of a place: `{ storage + start, end - start }`, its end the place's length when
    // absent.
    fn slice(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, dst: Value, place_ty: TypeId) bool {
        let bpl = b.places[rv.a as usize];
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let by = Lower::resolved(c, b.module, bpl.ty, &mut rm, &mut rt);
        let nm = Lower::agg_name(c, rm, rt);
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, rv.a, &mut p) || p.kind != PR_MEM && p.kind != PR_ZST {
            return self.fail("slice-base");
        }
        let pi = self.ptr_int();
        let mut ptr = p.addr;
        let mut len = VNONE;
        let mut et = TYPE_NONE;
        let mut em = rm;
        let mut f = FieldAt {
            m: 0,
            t: TYPE_NONE,
            off: 0,
            idx: 0,
            node: NODE_NONE,
            variant: NODE_NONE,
            mty: T_NONE,
            packed: false,
        };
        if by.kind == TypeKind::TYPE_ARRAY {
            len = self.iconst(pi, c.mg.arr_len(rm, &by) as u64);
            et = by.as_data.arr.elem;
        } else if nm == "Array" {
            if !self.named_field(c, rm, rt, "data", &mut f) {
                return self.fail("slice-array");
            }
            ptr = self.ptradd(p.addr, VNONE, 0, f.off);
            let mut fm = f.m;
            let mut ft = TYPE_NONE;
            let fy = Lower::resolved(c, f.m, f.t, &mut fm, &mut ft);
            len = self.iconst(pi, c.mg.arr_len(fm, &fy) as u64);
            et = fy.as_data.arr.elem;
            em = fm;
        } else {
            if !self.named_field(c, rm, rt, "ptr", &mut f) {
                return self.fail("slice-ptr");
            }
            ptr = self.load(T_PTR, p.addr, f.off, false);
            let mut fm = f.m;
            let mut ft = TYPE_NONE;
            let fy = Lower::resolved(c, f.m, f.t, &mut fm, &mut ft);
            et = fy.as_data.elem;
            em = fm;
            if nm == "str" {
                et = TYPE_NONE;
            }
            if !self.named_field(c, rm, rt, "len", &mut f) {
                return self.fail("slice-len");
            }
            len = self.load(pi, p.addr, f.off, false);
        }
        // The view's element type names the element where the base's field names a parameter.
        let mut vm = b.module;
        let mut vt = TYPE_NONE;
        let vy = Lower::resolved(c, b.module, place_ty, &mut vm, &mut vt);
        if et != TYPE_NONE && vy.kind == TypeKind::TYPE_INSTANCE {
            et = Lower::ast(c, vm).instance(vy.as_data.inst).args[0];
            em = vm;
        }
        let mut esz: u32 = 1;
        if et != TYPE_NONE {
            let mut ei = TyI { cls: 0 };
            if !self.ty(c, em, et, &mut ei) {
                return false;
            }
            esz = ei.size;
        }
        let mut start = VNONE;
        if rv.b != irc::IR_NONE {
            let s = self.operand(c, b, rv.b);
            start = self.int_to(s, pi, false);
            ptr = self.ptradd(ptr, start, esz, 0);
        }
        if rv.item.node != irc::IR_NONE {
            let e = self.operand(c, b, rv.item.node);
            len = self.int_to(e, pi, false);
        }
        if start != VNONE {
            len = self.arith(O_SUB, len, start);
        }
        self.store(ptr, dst, 0, false);
        self.store(len, dst, self.pkg.ptr_bytes, false);
        return true;
    }

    // A closure's env at `dst`: each capture's value, or the address of a captured binding the body
    // mutates or borrows.
    fn closure_env(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, dst: Value) bool {
        let a = Lower::ast(c, rv.item.module);
        let cf = a.closure_fact(rv.item.node);
        if cf == null || unsafe (&*cf).ncaps != rv.b {
            return self.fail("closure-caps");
        }
        let by = unsafe (&*cf).mut_caps | unsafe (&*cf).ref_caps;
        let mut off: u32 = 0;
        let mut any = false;
        for i in 0..rv.b {
            let opid = b.oper_pool[(rv.a + i) as usize];
            let mut oi = TyI { cls: 0 };
            if !self.ty(c, b.module, Lower::op_ty(b, opid), &mut oi) {
                return false;
            }
            if oi.cls == VC_ZST {
                continue;
            }
            any = true;
            let byref = (by >> i as u64 & 1) != 0;
            let sz = ast::pick(byref, self.pkg.ptr_bytes, oi.size);
            let al = ast::pick(byref, self.pkg.ptr_bytes, oi.align);
            off = round_up(off, al);
            let fa = self.ptradd(dst, VNONE, 0, off);
            if byref {
                let pa = self.place_addr_op(c, b, opid);
                if pa == VNONE {
                    return false;
                }
                self.store(pa, fa, 0, false);
            } else if !self.operand_into(c, b, opid, fa, oi) {
                return false;
            }
            off += sz;
        }
        if !any {
            let z = self.iconst(T_I8, 0);
            self.store(z, dst, 0, false);
        }
        return true;
    }

    // A dyn value at `dst`: the data pointer and the table of the erased type's conformance.
    fn dyn_value(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, dst: Value) bool {
        let ot = Lower::op_ty(b, rv.a);
        let mut om = b.module;
        let mut ott = TYPE_NONE;
        let oy = Lower::resolved(c, b.module, ot, &mut om, &mut ott);
        let mut dm = b.module;
        let mut dt = TYPE_NONE;
        let _ = Lower::resolved(c, b.module, rv.target, &mut dm, &mut dt);
        let mut pair = String::new();
        let pb = self.pkg.ptr_bytes;
        if oy.kind == TypeKind::TYPE_DYN {
            // An upcast: the data pointer stays; the table is the superinterface's the source's names.
            let fat = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * pb, align: pb };
            let fa = self.operand_addr(c, b, rv.a, fat);
            if fa == VNONE {
                return false;
            }
            let slot = c.super_slot(om, ott, dm, dt);
            if slot == NONE {
                return self.fail("dyn-upcast");
            }
            let d = self.load(T_PTR, fa, 0, false);
            let vt = self.load(T_PTR, fa, pb, false);
            let sv = self.load(T_PTR, vt, slot * pb, false);
            self.store(d, dst, 0, false);
            self.store(sv, dst, pb, false);
            return true;
        }
        if oy.kind == TypeKind::TYPE_REFERENCE || oy.kind == TypeKind::TYPE_POINTER {
            let mut em = om;
            let mut et = TYPE_NONE;
            let ey = Lower::resolved(c, om, oy.as_data.elem, &mut em, &mut et);
            if ey.kind == TypeKind::TYPE_DYN {
                // A borrow of an owned dyn value of the same interface (`&Box<dyn I>` as `&dyn I`): its
                // data and table.
                let p = self.operand(c, b, rv.a);
                if p == VNONE {
                    return false;
                }
                let d = self.load(T_PTR, p, 0, false);
                let vt = self.load(T_PTR, p, pb, false);
                self.store(d, dst, 0, false);
                self.store(vt, dst, pb, false);
                return true;
            }
            if !c.dyn_pair(dm, dt, em, et, false, 0, TYPE_NONE, &mut pair) {
                return self.fail("dyn-pair");
            }
            let d = self.operand(c, b, rv.a);
            pair.push_str("__vtbl");
            let vt = self.symaddr(pair.as_str(), SK_DATA);
            self.store(d, dst, 0, false);
            self.store(vt, dst, pb, false);
            return true;
        }
        if oy.kind == TypeKind::TYPE_FUNCTION {
            // A closure erased to `dyn fn`: its env moves to the heap.
            let mut ei = TyI { cls: 0 };
            if !self.ty(c, om, ott, &mut ei) || !c.dyn_pair(dm, dt, om, ott, true, 0, TYPE_NONE, &mut pair) {
                return self.fail("dyn-closure");
            }
            let pa = self.sentinel1(c);
            let sz = self.iconst(self.ptr_int(), ast::pick(ei.size == 0, 1u32, ei.size));
            let al = self.iconst(self.ptr_int(), ast::pick(ei.align == 0, 1u32, ei.align));
            let args: []Value = [pa, sz, al];
            let tys: []u32 = [T_PTR as u32, self.ptr_int() as u32, self.ptr_int() as u32];
            let p = self.call_sym("Global__alloc", args, tys, T_PTR);
            if !self.operand_into(c, b, rv.a, p, ei) {
                return false;
            }
            pair.push_str("__vtbl");
            let vt = self.symaddr(pair.as_str(), SK_DATA);
            self.store(p, dst, 0, false);
            self.store(vt, dst, pb, false);
            return true;
        }
        // An owned Box: its payload pointer moves into the dyn value.
        if oy.kind == TypeKind::TYPE_INSTANCE && Lower::agg_name(c, om, ott) == "Box" {
            let it = *Lower::ast(c, om).instance(oy.as_data.inst);
            let mut em = om;
            let mut et = TYPE_NONE;
            let _ = Lower::resolved(c, om, it.args[0], &mut em, &mut et);
            let mut alm = b.module;
            let mut alt = rv.b;
            if alt != TYPE_NONE {
                let _ = Lower::resolved(c, b.module, rv.b, &mut alm, &mut alt);
                if c.mg.is_global(alm, alt) {
                    alt = TYPE_NONE;
                }
            }
            if !c.dyn_pair(dm, dt, em, et, true, alm, alt, &mut pair) {
                return self.fail("dyn-pair");
            }
            let mut oi = TyI { cls: 0 };
            if !self.ty(c, om, ott, &mut oi) {
                return false;
            }
            let ba = self.operand_addr(c, b, rv.a, oi);
            let mut f = FieldAt {
                m: 0,
                t: TYPE_NONE,
                off: 0,
                idx: 0,
                node: NODE_NONE,
                variant: NODE_NONE,
                mty: T_NONE,
                packed: false,
            };
            if ba == VNONE || !self.named_field(c, om, ott, "ptr", &mut f) {
                return self.fail("dyn-box");
            }
            let d = self.load(T_PTR, ba, f.off, false);
            pair.push_str("__vtbl");
            let vt = self.symaddr(pair.as_str(), SK_DATA);
            self.store(d, dst, 0, false);
            self.store(vt, dst, pb, false);
            return true;
        }
        return self.fail("dyn-owned");
    }

    // The 1-aligned sentinel's address (the `Global` allocator's receiver).
    fn sentinel1(self: &mut Self, c: &mut cbe::CEmit) Value {
        let _ = self.sentinel_sym(c, 1);
        return self.symaddr("__sc_zst_1", SK_DATA);
    }

    // A conversion method's call on operand `rv.a`: its result, or at `dst` in memory.
    fn coerce(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, rv: irc::Rvalue, dst: Value, ti: TyI) Value {
        let cvr = Lower::op_ty(b, rv.a);
        let ga = Lower::ast(c, rv.item.module);
        let own = ga.at_const(rv.item.node).kind == NodeKind::NODE_FUNCTION && ga.ext(rv.item.node).function.generics.len != 0;
        let mut s = String::new();
        let ok = if own {
            c.conv_sym(b, rv.item, cvr, rv.target, &mut s);
        } else {
            c.callee_sym(b, rv.item, 0, 0, cvr, rv.target, TYPE_NONE, TYPE_NONE, &mut s);
        };
        if !ok {
            return self.fail_v("coerce-sym");
        }
        let mut args = Vector::<Value>::new();
        let mut tys = Vector::<u32>::new();
        if !self.call_arg(c, b, rv.item, rv.item, 0, rv.a, &mut args, &mut tys) {
            return VNONE;
        }
        return self.emit_call(s.as_str(), VNONE, &args, &tys, tys.len() as u32, false, ti, c, b.module, rv.target, dst);
    }
}

extend Lower {
    // ---- Calls ----

    // How argument `i` (operand `opid`) of a call of `callee` passes: the adjustments the C emitter
    // makes from the parameter's declared type.
    // The callee's parameter type reads its instance's bindings (`bind_callee`); the argument's type
    // reads the caller's, which those would shadow.
    fn arg_mode(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, callee: DefId, i: u32, opid: u32) u8 {
        self.pmty = T_NONE;
        let mut pm = callee.module;
        let mut pty = TYPE_NONE;
        if callee.node == NODE_NONE {
            // An indirect call: a function pointer's signature, else a closure's declaration.
            if self.ind_t == TYPE_NONE {
                return AM_VAL;
            }
            let ia = Lower::ast(c, self.ind_m);
            let iy = *ia.type_at(self.ind_t);
            if iy.fn_sig() {
                if i >= ia.sig_len(&iy, false) {
                    return AM_VAL;
                }
                pm = self.ind_m;
                pty = ia.sig_at(&iy, false, i);
            } else if iy.kind == TypeKind::TYPE_FUNCTION {
                // A closure: its declaration's facts hold its parameter types; a named function's value:
                // its declaration's parameters, as a direct call reads them.
                let da = Lower::ast(c, iy.module);
                let cf = da.closure_fact(iy.as_data.decl);
                if cf != null {
                    if i >= unsafe (*cf).nparams {
                        return AM_VAL;
                    }
                    pty = da.cap_facts[(unsafe (*cf).cap_start + unsafe (*cf).ncaps + i) as usize].ty;
                } else {
                    let fnn = da.at_const(iy.as_data.decl);
                    if fnn.kind != NodeKind::NODE_FUNCTION || i >= da.ext(iy.as_data.decl).function.params.len {
                        return AM_VAL;
                    }
                    let pn = da.at_const(unsafe da.list(da.ext(iy.as_data.decl).function.params)[i as usize]);
                    if pn.kind != NodeKind::NODE_PARAMETER || pn.as_data.parameter.ty == NODE_NONE {
                        return AM_VAL;
                    }
                    pty = da.type_of(pn.as_data.parameter.ty);
                }
                pm = iy.module;
            } else {
                return AM_VAL;
            }
        } else {
            let fa = Lower::ast(c, callee.module);
            let fnn = fa.at_const(callee.node);
            if fnn.kind != NodeKind::NODE_FUNCTION {
                return AM_VAL;
            }
            let ps = fa.ext(callee.node).function.params;
            if i >= ps.len {
                return ast::pick(fa.ext(callee.node).function.is_variadic(), AM_VARARG, AM_VAL);
            }
            let pn = fa.at_const(unsafe fa.list(ps)[i as usize]);
            if pn.kind != NodeKind::NODE_PARAMETER || pn.as_data.parameter.ty == NODE_NONE {
                return AM_VAL;
            }
            pty = fa.type_of(pn.as_data.parameter.ty);
        }
        if pty == TYPE_NONE {
            return AM_VAL;
        }
        let pk0 = Lower::ast(c, pm).type_at(pty).kind;
        if pk0 == TypeKind::TYPE_GENERIC || pk0 == TypeKind::TYPE_ASSOC {
            // A generic parameter decides by its bound type; an unbound one decides nothing.
            let mut xm = pm;
            let mut xt = pty;
            self.push_binds(c);
            let grounded = c.mg.resolve(pm, pty, &mut xm, &mut xt);
            c.mg.pop_subs(self.binds.len());
            let xk = Lower::ast(c, xm).type_at(xt).kind;
            if !grounded || xk == TypeKind::TYPE_GENERIC || xk == TypeKind::TYPE_ASSOC {
                return AM_VAL;
            }
            pty = xt;
            pm = xm;
        }
        let py = *Lower::ast(c, pm).type_at(pty);
        let aty = Lower::op_ty(b, opid);
        {
            // The prototype's type: C converts a scalar argument to it.
            let mut pi = TyI { cls: 0 };
            let e0 = self.err;
            self.push_binds(c);
            if self.ty(c, pm, pty, &mut pi) && pi.cls == VC_SCALAR {
                self.pmty = pi.mty;
                self.psgn = Lower::signed(c, pm, pty);
            }
            c.mg.pop_subs(self.binds.len());
            self.err = e0;
        }
        if py.kind == TypeKind::TYPE_BUILTIN && py.as_data.builtin == BuiltinType::BT_F64 && Lower::builtin(
            c,
            b.module,
            aty,
        ) == BuiltinType::BT_F32 {
            return AM_F64;
        }
        if callee.node == NODE_NONE {
            // Through a pointer only the prototype's scalar conversions apply.
            return AM_VAL;
        }
        if py.kind != TypeKind::TYPE_REFERENCE && py.kind != TypeKind::TYPE_POINTER {
            if py.kind == TypeKind::TYPE_BUILTIN {
                let op = b.operands[opid as usize];
                if op.kind == irc::OP_CONST && b.constants[op.data as usize].kind == irc::CK_WIDE {
                    return AM_WIDE;
                }
            }
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            if aty != TYPE_NONE && Lower::resolved(c, b.module, aty, &mut rm, &mut rt).kind == TypeKind::TYPE_REFERENCE {
                return AM_DEREF;
            }
            return AM_VAL;
        }
        if py.kind != TypeKind::TYPE_REFERENCE {
            return AM_VAL;
        }
        let mut param_box = false;
        let pe = py.as_data.elem;
        let pa = Lower::ast(c, pm);
        if pe != TYPE_NONE && pa.type_at(pe).kind == TypeKind::TYPE_GENERIC {
            param_box = true;
        } else if pe != TYPE_NONE && pa.type_at(pe).kind == TypeKind::TYPE_INSTANCE {
            let pit = *pa.instance(pa.type_at(pe).as_data.inst);
            let pn2 = Lower::ast(c, pit.module).at_const(pit.decl);
            param_box = (pn2.kind == NodeKind::NODE_STRUCT || pn2.kind == NodeKind::NODE_ENUM) && Lower::decl_name(
                c,
                pit.module,
                pit.decl,
            ) == "Box";
        }
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let mut ay = Lower::resolved(c, b.module, aty, &mut rm, &mut rt);
        let mut through = false;
        if ay.kind == TypeKind::TYPE_REFERENCE || ay.kind == TypeKind::TYPE_POINTER {
            let mut em = rm;
            let mut et = TYPE_NONE;
            if !c.mg.resolve(rm, ay.as_data.elem, &mut em, &mut et) {
                return AM_VAL;
            }
            let ey = *Lower::ast(c, em).type_at(et);
            if ey.kind != TypeKind::TYPE_INSTANCE {
                return AM_VAL;
            }
            rm = em;
            rt = et;
            ay = ey;
            through = true;
        }
        if ay.kind == TypeKind::TYPE_INSTANCE && !param_box && Lower::agg_name(c, rm, rt) == "Box" {
            return ast::pick(through, AM_BOXREF, AM_BOX);
        }
        if through {
            return AM_VAL;
        }
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, b.module, aty, &mut ti) {
            return AM_VAL;
        }
        if ti.cls == VC_ZST && aty != TYPE_NONE && Lower::builtin(c, b.module, aty) != BuiltinType::BT_VOID && ay.kind != TypeKind::TYPE_NEVER {
            return AM_ZST_REF;
        }
        return AM_REF;
    }

    // The name of declaration `(m, d)`.
    fn decl_name(c: &cbe::CEmit, m: ModuleId, d: NodeId) str<'static> {
        let a = Lower::ast(c, m);
        let sp = a.at_const(a.ext_name(d)).as_data.name.text;
        return Lower::p(c).modules.at(m as usize).source.as_str().slice(sp.start as usize, sp.end as usize);
    }

    // Argument `i` (operand `opid`) of a call of `callee` (`pcallee` the declaration its parameters
    // come from): its value and type into `args` and `tys`; nothing for a zero-sized value. An
    // aggregate passes as the address of a copy the callee owns.
    fn call_arg(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        callee: DefId,
        pcallee: DefId,
        i: u32,
        opid: u32,
        args: &mut Vector<Value>,
        tys: &mut Vector<u32>,
    ) bool {
        let _ = callee;
        let am = self.arg_mode(c, b, pcallee, i, opid);
        let aty = Lower::op_ty(b, opid);
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, b.module, aty, &mut ti) {
            return false;
        }
        if aty == TYPE_NONE && self.pmty != T_NONE {
            // An untyped argument (`null`) is of its parameter's type.
            let n = type_bytes(self.pmty, self.pkg.ptr_bytes);
            ti = TyI { cls: VC_SCALAR, mty: self.pmty, size: n, align: n };
        }
        let mut v = VNONE;
        let mut t: u32 = 0;
        if am == AM_REF || am == AM_ZST_REF {
            let op = b.operands[opid as usize];
            if am == AM_ZST_REF {
                v = self.sentinel(c, b.module, aty);
            } else if op.kind == irc::OP_CONST || ti.cls != VC_MEM {
                let p = PlaceRef { kind: 0 };
                let _ = p;
                v = self.operand_addr(c, b, opid, ti);
            } else {
                v = self.place_addr(c, b, op.data);
            }
            t = T_PTR;
        } else if am == AM_BOX || am == AM_BOXREF {
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let mut y = Lower::resolved(c, b.module, aty, &mut rm, &mut rt);
            let ba = if am == AM_BOXREF {
                let p = self.operand(c, b, opid);
                y = Lower::resolved(c, rm, y.as_data.elem, &mut rm, &mut rt);
                p;
            } else {
                self.operand_addr(c, b, opid, ti);
            };
            let mut f = FieldAt {
                m: 0,
                t: TYPE_NONE,
                off: 0,
                idx: 0,
                node: NODE_NONE,
                variant: NODE_NONE,
                mty: T_NONE,
                packed: false,
            };
            if ba == VNONE || !self.named_field(c, rm, rt, "ptr", &mut f) {
                return self.fail("box-arg");
            }
            let _ = y;
            v = self.load(T_PTR, ba, f.off, false);
            t = T_PTR;
        } else if am == AM_DEREF {
            let p = self.operand(c, b, opid);
            let mut rm = b.module;
            let mut rt = TYPE_NONE;
            let y = Lower::resolved(c, b.module, aty, &mut rm, &mut rt);
            let mut ei = TyI { cls: 0 };
            if p == VNONE || !self.ty(c, rm, y.as_data.elem, &mut ei) {
                return self.fail("deref-arg");
            }
            if ei.cls == VC_ZST {
                return true;
            }
            if ei.cls == VC_SCALAR {
                v = self.load(ei.mty, p, 0, false);
                t = ei.mty;
            } else {
                v = self.temp(ei);
                self.memcpy(v, p, ei.size);
                t = self.param_sig(c, rm, y.as_data.elem, ei);
            }
        } else if am == AM_WIDE {
            let k = b.constants[b.operands[opid as usize].data as usize];
            let w = *Lower::ast(c, b.module).wide_lits.at(k.val as usize);
            v = self.iconst(T_I64, w.limbs[0]);
            t = T_I64;
        } else {
            if ti.cls == VC_ZST {
                return true;
            }
            if ti.cls == VC_SCALAR {
                self.hint = ti;
                v = self.operand(c, b, opid);
                t = ti.mty;
                if am == AM_VAL && self.pmty != T_NONE && self.pmty != t && v != VNONE {
                    v = self.fit(v, self.pmty, aty != TYPE_NONE && Lower::signed(c, b.module, aty));
                    t = self.pmty;
                }
                if am == AM_F64 {
                    v = self.inst(O_FPEXT, T_F64, 0, v, VNONE, VNONE);
                    t = T_F64;
                } else if am == AM_VARARG && (ti.mty == T_F32 || ti.mty == T_I8 || ti.mty == T_I16) {
                    // C's default argument promotions.
                    if ti.mty == T_F32 {
                        v = self.inst(O_FPEXT, T_F64, 0, v, VNONE, VNONE);
                        t = T_F64;
                    } else {
                        v = self.int_to(v, T_I32, Lower::signed(c, b.module, aty));
                        t = T_I32;
                    }
                }
            } else {
                // A copy the callee owns; a moved local's own memory when its address never escapes.
                let op = b.operands[opid as usize];
                let pl = if op.kind == irc::OP_CONST {
                    irc::Place { base: 0, proj_start: 0, proj_len: 1, ty: TYPE_NONE };
                } else {
                    b.places[op.data as usize];
                };
                if op.kind == irc::OP_MOVE && pl.proj_len == 0 && self.li[pl.base as usize].kind == LK_MEM && !self.escaped[pl.base as usize] && pl.base >= b.returns + b.args {
                    v = self.li[pl.base as usize].addr;
                } else {
                    v = self.temp(ti);
                    if !self.operand_into(c, b, opid, v, ti) {
                        return false;
                    }
                }
                t = self.param_sig(c, b.module, aty, ti);
            }
        }
        if v == VNONE {
            return self.fail("argument");
        }
        args.push(v);
        if t == T_I8 as u32 || t == T_I16 as u32 {
            let s = ast::pick(self.pmty != T_NONE, self.psgn, aty != TYPE_NONE && Lower::signed(c, b.module, aty));
            t |= ast::pick(s, SIG_SEXT, 0);
        }
        tys.push(t);
        return true;
    }

    // A call of `name` (or of function value `fv`) with `args` of types `tys`, the first `nfixed`
    // fixed; its result of type `ti` (`(m, t)`), in memory at `dst` (a temporary when VNONE).
    fn emit_call(
        self: &mut Self,
        name: str,
        fv: Value,
        args: &Vector<Value>,
        tys: &Vector<u32>,
        nfixed: u32,
        variadic: bool,
        ti: TyI,
        c: &mut cbe::CEmit,
        m: ModuleId,
        t: TypeId,
        dst: Value,
    ) Value {
        let mut ret = T_NONE as u32;
        let mut all = Vector::<Value>::with_capacity(args.len() + 1);
        all.extend_copy(args);
        let mut out = VNONE;
        if ti.cls == VC_SCALAR {
            ret = sig_code(ti.mty, t != TYPE_NONE && Lower::signed(c, m, t));
        } else if ti.cls == VC_MEM {
            out = dst;
            if out == VNONE {
                out = self.temp(ti);
            }
            ret = AGG | self.layout_of(c, m, t, ti);
            all.push(out);
        }
        let sg = self.b.signature(tys[0..tys.len()], nfixed, variadic, ret);
        let at = self.b.pool_list(all[0..all.len()]);
        let rty = ast::pick(ti.cls == VC_SCALAR, ti.mty, T_NONE);
        let r = if fv != VNONE {
            self.inst(O_CALLIND, rty, all.len() as u16, fv, sg, at);
        } else {
            let k = self.sym(name, SK_FUNC);
            self.inst(O_CALL, rty, all.len() as u16, k, sg, at);
        };
        return ast::pick(ti.cls == VC_SCALAR, r, out);
    }
}

extend Lower {
    // ---- Blocks and statements ----

    fn lower_block(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, blk: u32) bool {
        let bb = b.blocks[blk as usize];
        for k in 0..bb.stmt_len {
            let s = b.statements[(bb.stmt_start + k) as usize];
            self.loc = self.loc_at(c, s.span.start);
            if !self.stmt(c, b, s) {
                if self.dbg {
                    eprint("lir-debug at bb{} statement {}\n", blk, k);
                }
                return false;
            }
            self.release_temps();
        }
        self.loc = self.loc_at(c, bb.term.span.start);
        self.fresh = NONE;
        if bb.stmt_len != 0 {
            let s = b.statements[(bb.stmt_start + bb.stmt_len - 1) as usize];
            if s.kind == irc::ST_STORAGE_LIVE {
                self.fresh = s.a;
            }
        }
        let ok = self.term(c, b, blk, bb.term);
        self.release_temps();
        if !ok && self.dbg {
            eprint("lir-debug at bb{} terminator\n", blk);
        }
        return ok;
    }

    fn stmt(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, s: irc::Statement) bool {
        if s.kind != irc::ST_ASSIGN {
            return true;
        }
        let rv = b.rvalues[s.rvalue as usize];
        if rv.kind == irc::RV_INTRINSIC {
            if rv.c == irc::IN_SAFEPOINT {
                self.tick(false);
                return true;
            }
            if rv.c == irc::IN_SAFEPOINT_C {
                let r = self.tick(true);
                let mut p = PlaceRef { kind: 0 };
                return self.place(c, b, s.place, &mut p) && self.write(p, r);
            }
            if rv.c == irc::IN_VOLATILE_STORE {
                return self.volatile_store(c, b, rv);
            }
            if rv.c == irc::IN_ASM {
                return self.asm_stmt(c, b, rv);
            }
            if rv.c == irc::IN_VA_START || rv.c == irc::IN_VA_END {
                let a = self.place_addr(c, b, s.place);
                if a == VNONE {
                    return false;
                }
                let _ = self.inst(ast::pick(rv.c == irc::IN_VA_START, O_VASTART, O_VAEND), T_NONE, 0, a, VNONE, VNONE);
                return true;
            }
        }
        let pty = b.places[s.place as usize].ty;
        let mut ti = TyI { cls: 0 };
        if pty == TYPE_NONE {
            // A place of an untyped local: the type its walk ends at.
            let mut p = PlaceRef { kind: 0 };
            if !self.place(c, b, s.place, &mut p) || b.locals[b.places[s.place as usize].base as usize].ty != TYPE_NONE {
                return self.fail("untyped-place");
            }
            ti = p.ti;
        } else if !self.ty(c, b.module, pty, &mut ti) {
            return false;
        }
        if ti.cls == VC_ZST {
            // A vector store has no value but its effect.
            if rv.kind == irc::RV_SIMD && irc::simd_op(rv.c).effect != irc::SM_NONE {
                return self.simd(c, b, rv, ti, VNONE) != VNONE || self.err.len() == 0;
            }
            return true;
        }
        if rv.kind == irc::RV_USE {
            let op = b.operands[rv.a as usize];
            if op.kind == irc::OP_CONST && b.constants[op.data as usize].kind == irc::CK_UNIT {
                return true;
            }
            if op.kind != irc::OP_CONST && op.ty != TYPE_NONE {
                let mut rm = b.module;
                let mut rt = TYPE_NONE;
                if Lower::resolved(c, b.module, op.ty, &mut rm, &mut rt).kind == TypeKind::TYPE_NEVER {
                    return true;
                }
            }
        }
        if ti.cls == VC_SCALAR {
            self.hint = ti;
            let mut v = self.rvalue(c, b, s.rvalue, ti);
            if v == VNONE {
                return self.fail("rvalue-value");
            }
            // C's implicit conversion at the assignment.
            let st = if rv.kind == irc::RV_USE {
                Lower::op_ty(b, rv.a);
            } else {
                rv.target;
            };
            v = self.fit(v, ti.mty, st != TYPE_NONE && Lower::signed(c, b.module, st));
            let mut p = PlaceRef { kind: 0 };
            return self.place(c, b, s.place, &mut p) && self.write(p, v);
        }
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, s.place, &mut p) {
            return false;
        }
        if p.kind != PR_MEM {
            return self.fail("memory-place");
        }
        // Built in place unless the rvalue may read the destination.
        if self.direct(b, s.place, s.rvalue) {
            return self.rvalue_into(c, b, s.rvalue, p.addr, ti, pty);
        }
        let t = self.temp(ti);
        if !self.rvalue_into(c, b, s.rvalue, t, ti, pty) {
            return false;
        }
        self.memcpy(p.addr, t, ti.size);
        return true;
    }

    // Whether rvalue `rid` can build straight into place `pid`: a whole local whose address never
    // escapes and that no operand reads.
    const fn direct(self: &Self, b: &irc::CoreBody, pid: u32, rid: u32) bool {
        let pl = b.places[pid as usize];
        if pl.proj_len != 0 || self.escaped[pl.base as usize] || self.li[pl.base as usize].kind != LK_MEM {
            return false;
        }
        let rv = b.rvalues[rid as usize];
        if rv.kind == irc::RV_USE {
            return true; // a copy, overlapping or not
        }
        let mut lo: u32 = 0;
        let mut n: u32 = 0;
        if rv.kind == irc::RV_AGGREGATE || rv.kind == irc::RV_CLOSURE {
            lo = rv.a;
            n = rv.b;
        } else if rv.kind == irc::RV_REPEAT || rv.kind == irc::RV_CAST || rv.kind == irc::RV_DYN {
            return !Lower::reads(b, rv.a, pl.base);
        } else if rv.kind == irc::RV_SLICE {
            return b.places[rv.a as usize].base != pl.base;
        } else if rv.kind == irc::RV_BINARY {
            return !Lower::reads(b, rv.a, pl.base) && !Lower::reads(b, rv.b, pl.base);
        }
        for i in 0..n {
            let opid = b.oper_pool[(lo + i) as usize];
            if opid != irc::IR_NONE && Lower::reads(b, opid, pl.base) {
                return false;
            }
        }
        return true;
    }

    // Whether operand `opid` reads local `l`.
    const fn reads(b: &irc::CoreBody, opid: u32, l: u32) bool {
        let op = b.operands[opid as usize];
        return op.kind != irc::OP_CONST && b.places[op.data as usize].base == l;
    }

    // A preemption tick: the counter goes down, and at 0 the runtime's check runs and resets it; the
    // combined form also asks for a pending cancellation (its result). The counter and the result
    // pass the cold path through memory.
    fn tick(self: &mut Self, cancel: bool) Value {
        if self.spc == NONE {
            return self.iconst(T_I32, 0);
        }
        let i32t = TyI { cls: VC_SCALAR, mty: T_I32, size: 4, align: 4 };
        let n = self.read_var(self.spc, self.cur);
        let one = self.iconst(T_I32, 1);
        let m = self.arith(O_SUB, n, one);
        let ts = self.temp(i32t);
        self.store(m, ts, 0, false);
        let r = self.temp(i32t);
        let z = self.zero(T_I32);
        self.store(z, r, 0, false);
        let hit = self.icmp(C_EQ, m, z);
        let cold = self.block();
        self.b.blocks.index_mut(cold as usize).flags = BLOCK_COLD;
        let join = self.block();
        let ec = self.edge(cold, NONE, NONE);
        let ej = self.edge(join, NONE, NONE);
        let _ = self.inst(O_BR, T_NONE, 0, hit, ec, ej);
        self.b.begin(cold);
        let none: []Value = [];
        let nt: []u32 = [];
        let reset = self.call_sym("__sc_preempt_check", none, nt, T_I32);
        self.store(reset, ts, 0, false);
        if cancel {
            let cr = self.call_sym("__sc_cancel_tick", none, nt, T_I32);
            self.store(cr, r, 0, false);
        }
        let ej2 = self.edge(join, NONE, NONE);
        let _ = self.inst(O_JMP, T_NONE, 0, ej2, VNONE, VNONE);
        self.b.begin(join);
        let cur = self.load(T_I32, ts, 0, false);
        self.write_var(self.spc, cur);
        return self.load(T_I32, r, 0, false);
    }
}

extend Lower {
    // ---- Terminators ----

    fn goto(self: &mut Self, to: u32) {
        let e = self.edge(self.lblk[to as usize], self.cur, to);
        let _ = self.inst(O_JMP, T_NONE, 0, e, VNONE, VNONE);
    }

    fn term(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, blk: u32, t: irc::Terminator) bool {
        let k = t.kind;
        if k == irc::TM_GOTO {
            self.goto(t.t0);
            return true;
        }
        if k == irc::TM_SWITCH {
            return self.switch_term(c, b, t);
        }
        if k == irc::TM_CALL {
            return self.call_term(c, b, t);
        }
        if k == irc::TM_RETURN {
            return self.ret(c, b, t);
        }
        if k == irc::TM_DROP {
            if !self.drop_term(c, b, t) {
                return false;
            }
            self.goto(t.t0);
            return true;
        }
        if k == irc::TM_ASSERT {
            return self.assert_term(c, b, t);
        }
        if k == irc::TM_UNREACHABLE {
            self.abort();
            return true;
        }
        let _ = blk;
        return self.fail("terminator");
    }

    // `abort()`: the end of a path that cannot be reached, or of a function that does not return.
    fn abort(self: &mut Self) {
        let none: []Value = [];
        let nt: []u32 = [];
        let _ = self.call_sym("abort", none, nt, T_NONE);
        let _ = self.inst(O_UNREACHABLE, T_NONE, 0, VNONE, VNONE, VNONE);
    }

    fn switch_term(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: irc::Terminator) bool {
        let mut v = self.operand(c, b, t.a);
        if v == VNONE {
            return self.fail("switch-operand");
        }
        if self.vty(v) == T_PTR {
            v = self.int_to(v, self.ptr_int(), false);
        }
        let ty = b.operands[t.a as usize].ty;
        if t.sw_len == 1 && ty != TYPE_NONE && Lower::builtin(c, b.module, ty) == BuiltinType::BT_BOOL {
            // A bool's one case: a two-way branch, which the code generator fuses with its comparison.
            let pr = b.switch_pool[t.sw_start as usize];
            let to = pr as u32;
            let ec = self.edge(self.lblk[to as usize], self.cur, to);
            let ed = self.edge(self.lblk[t.t0 as usize], self.cur, t.t0);
            if pr >> 32 == 0 {
                let _ = self.inst(O_BR, T_NONE, 0, v, ed, ec);
            } else {
                let _ = self.inst(O_BR, T_NONE, 0, v, ec, ed);
            }
            return true;
        }
        let signed = ty != TYPE_NONE && Lower::signed(c, b.module, ty);
        let w0 = self.b.words.len() as u32;
        let mut es = Vector::<u32>::new();
        for k in 0..t.sw_len {
            let pr = b.switch_pool[(t.sw_start + k) as usize];
            let mut cv = (pr >> 32) as i64;
            if cv >= 2147483648 && signed {
                cv -= 4294967296;
            }
            self.b.words.push(cv as u64);
            let to = pr as u32;
            es.push(self.edge(self.lblk[to as usize], self.cur, to));
        }
        es.push(self.edge(self.lblk[t.t0 as usize], self.cur, t.t0));
        let el = self.b.pool_list(es[0..es.len()]);
        let _ = self.inst(O_SWITCH, T_NONE, t.sw_len as u16, v, w0, el);
        return true;
    }

    fn ret(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: irc::Terminator) bool {
        if self.noret && t.args_len != irc::RET_CANCEL {
            self.abort();
            return true;
        }
        if b.returns != 1 || self.li[0].ti.cls != VC_SCALAR {
            let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
            return true;
        }
        if t.args_len == irc::RET_CANCEL {
            // A cancellation return: the caller, unwinding too, never reads the value.
            let z = self.zero(self.li[0].ti.mty);
            let _ = self.inst(O_RET, T_NONE, 0, z, VNONE, VNONE);
            return true;
        }
        let info = self.li[0];
        let v = if info.kind == LK_VAR {
            self.read_var(info.var, self.cur);
        } else {
            self.load(info.ti.mty, info.addr, 0, false);
        };
        let _ = c;
        let _ = self.inst(O_RET, T_NONE, 0, v, VNONE, VNONE);
        return true;
    }

    // `assert`: on failure, the runtime's report of the assertion's text and location.
    fn assert_term(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: irc::Terminator) bool {
        let cond = self.operand(c, b, t.a);
        if cond == VNONE {
            return self.fail("assert-operand");
        }
        let fail = self.block();
        self.b.blocks.index_mut(fail as usize).flags = BLOCK_COLD;
        let eo = self.edge(self.lblk[t.t0 as usize], self.cur, t.t0);
        let ef = self.edge(fail, NONE, NONE);
        let _ = self.inst(O_BR, T_NONE, 0, cond, eo, ef);
        self.b.begin(fail);
        let pk = Lower::p(c);
        let src = pk.modules.at(b.module as usize).source.as_str();
        let mut head = String::from_str("assertion failed: `");
        let msg = t.args_len == 1;
        if t.args_len == 4 {
            let l = b.constants[b.operands[b.oper_pool[(t.args_start + 2) as usize] as usize].data as usize];
            let r = b.constants[b.operands[b.oper_pool[(t.args_start + 3) as usize] as usize].data as usize];
            push_src(src.slice(l.raw.start as usize, l.raw.end as usize), &mut head);
            head.push_str(ast::pick(t.sw_len == 2, " == ", " != "));
            push_src(src.slice(r.raw.start as usize, r.raw.end as usize), &mut head);
        } else {
            push_src(src.slice(t.span.start as usize, t.span.end as usize), &mut head);
        }
        head.push_str(ast::pick(msg, "`: ", "`"));
        let mut tail = String::from_str("\n  at ");
        tail.push_str(pk.modules.at(b.module as usize).file.as_str());
        tail.push_str(":");
        tail.push_u64(self.b.lines[self.loc as usize].line);
        tail.push_str("\n");
        if t.args_len == 4 {
            // `assert_eq`/`assert_ne`: the operands, as C prints them (`__sc_assert_vals`).
            head.push_str("\n");
            let hv = self.cstr(head.as_str());
            let tv = self.cstr(tail.as_str().slice(1, tail.len()));
            let mut kind: u64 = 0;
            let mut w: [Value; 4] = [VNONE, VNONE, VNONE, VNONE];
            for k in 0..2u32 {
                let opid = b.oper_pool[(t.args_start + k) as usize];
                let ot = b.operands[opid as usize].ty;
                let bt = Lower::builtin(c, b.module, ot);
                let mut v = VNONE;
                let mut n = self.iconst(T_I64, 0);
                if bt == BuiltinType::BT_BOOL || bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 || Lower::is_int_bt(
                    bt,
                ) {
                    v = self.operand(c, b, opid);
                    if v == VNONE {
                        return false;
                    }
                    if bt == BuiltinType::BT_BOOL {
                        kind = 4;
                        v = self.int_to(v, T_I64, false);
                    } else if bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 {
                        kind = 3;
                        if bt == BuiltinType::BT_F32 {
                            v = self.inst(O_FPEXT, T_F64, 0, v, VNONE, VNONE);
                        }
                        v = self.inst(O_BITCAST, T_I64, 0, v, VNONE, VNONE);
                    } else {
                        let sg = Lower::signed(c, b.module, ot);
                        kind = ast::pick(sg, 1u64, 2u64);
                        v = self.int_to(v, T_I64, sg);
                    }
                } else if Lower::is_str(c, b.module, ot) {
                    kind = 5;
                    let strt = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * self.pkg.ptr_bytes, align: self.pkg.ptr_bytes };
                    let sa = self.operand_addr(c, b, opid, strt);
                    if sa == VNONE {
                        return false;
                    }
                    v = self.int_to(self.load(T_PTR, sa, 0, false), T_I64, false);
                    n = self.int_to(self.load(self.ptr_int(), sa, self.pkg.ptr_bytes, false), T_I64, false);
                } else {
                    v = self.iconst(T_I64, 0);
                }
                unsafe w[(2 * k) as usize] = v;
                unsafe w[(2 * k + 1) as usize] = n;
            }
            let kv = self.iconst(T_I32, kind);
            let vargs: []Value = [hv, kv, w[0], w[1], w[2], w[3], tv];
            let vtys: []u32 = [
                T_PTR as u32,
                T_I32 as u32,
                T_I64 as u32,
                T_I64 as u32,
                T_I64 as u32,
                T_I64 as u32,
                T_PTR as u32,
            ];
            let _ = self.call_sym("__sc_assert_vals", vargs, vtys, T_NONE);
            let _ = self.inst(O_UNREACHABLE, T_NONE, 0, VNONE, VNONE, VNONE);
            return true;
        }
        let hp = self.cstr(head.as_str());
        let tp = self.cstr(tail.as_str());
        let mut mp = self.iconst(T_PTR, 0);
        let mut ml = self.zero(self.ptr_int());
        if msg {
            let strt = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * self.pkg.ptr_bytes, align: self.pkg.ptr_bytes };
            let sa = self.operand_addr(c, b, b.oper_pool[t.args_start as usize], strt);
            if sa == VNONE {
                return false;
            }
            mp = self.load(T_PTR, sa, 0, false);
            ml = self.load(self.ptr_int(), sa, self.pkg.ptr_bytes, false);
        }
        let args: []Value = [hp, mp, ml, tp];
        let tys: []u32 = [T_PTR as u32, T_PTR as u32, self.ptr_int() as u32, T_PTR as u32];
        let _ = self.call_sym("__sc_assert_fail", args, tys, T_NONE);
        let _ = self.inst(O_UNREACHABLE, T_NONE, 0, VNONE, VNONE, VNONE);
        return true;
    }

    // A scheduled drop: the free glue of the value at the place (its flag first, when guarded), a dyn
    // value's table entry, each element of an array.
    fn drop_term(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: irc::Terminator) bool {
        let pl = b.places[t.a as usize];
        let mut rm = b.module;
        let mut rt = TYPE_NONE;
        let y = Lower::resolved(c, b.module, pl.ty, &mut rm, &mut rt);
        let is_ptr = y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE;
        let uk = Lower::ast(c, b.module).type_at(pl.ty).kind;
        if is_ptr && uk != TypeKind::TYPE_POINTER && uk != TypeKind::TYPE_REFERENCE {
            // A generic value that is a reference in this instance owns nothing (the C emitter's
            // `drop_emits_nothing`); a drop through a place typed as a pointer frees the pointee.
            return true;
        }
        let mut em = rm;
        let mut et = rt;
        if is_ptr && !c.mg.resolve(rm, y.as_data.elem, &mut em, &mut et) {
            return true;
        }
        if is_ptr && !c.is_destructible(em, et) {
            return true;
        }
        if !is_ptr && (y.kind == TypeKind::TYPE_DYN && !y.dyn_owns() || y.kind != TypeKind::TYPE_DYN && !c.is_destructible(
            rm,
            rt,
        )) {
            return true;
        }
        if y.kind == TypeKind::TYPE_BUILTIN {
            return true;
        }
        let mut join = NONE;
        if t.args_len == 1 {
            // A drop guarded by its move flag.
            let fl = self.li[t.args_start as usize];
            let f = if fl.kind == LK_VAR {
                self.read_var(fl.var, self.cur);
            } else {
                self.load(T_I8, fl.addr, 0, false);
            };
            let body = self.block();
            join = self.block();
            let eb = self.edge(body, NONE, NONE);
            let ej = self.edge(join, NONE, NONE);
            let _ = self.inst(O_BR, T_NONE, 0, f, eb, ej);
            self.b.begin(body);
        }
        let mut ok = true;
        if is_ptr {
            let p = self.place_addr_or_value(c, b, t.a);
            ok = p != VNONE && self.drop_at(c, em, et, p, 0);
        } else {
            let mut p = PlaceRef { kind: 0 };
            ok = self.place(c, b, t.a, &mut p) && self.drop_at(c, rm, rt, p.addr, 0);
        }
        if !ok {
            return false;
        }
        if join != NONE {
            let ej = self.edge(join, NONE, NONE);
            let _ = self.inst(O_JMP, T_NONE, 0, ej, VNONE, VNONE);
            self.b.begin(join);
        }
        return true;
    }

    // The value of pointer place `pid`.
    fn place_addr_or_value(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, pid: u32) Value {
        let mut p = PlaceRef { kind: 0 };
        if !self.place(c, b, pid, &mut p) {
            return VNONE;
        }
        return self.read(p);
    }

    // Free the value of resolved type `(rm, rt)` at `addr`.
    fn drop_at(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId, addr: Value, depth: u32) bool {
        let y = *Lower::ast(c, rm).type_at(rt);
        let pb = self.pkg.ptr_bytes;
        if y.kind == TypeKind::TYPE_DYN {
            if !y.dyn_owns() {
                return true; // a borrowed dyn
            }
            let d = self.load(T_PTR, addr, 0, false);
            let vt = self.load(T_PTR, addr, pb, false);
            let fp = self.load(T_PTR, vt, 0, false);
            let tys: []u32 = [T_PTR as u32];
            let sg = self.b.signature(tys, 1, false, T_NONE);
            let args: []Value = [d];
            let at = self.b.pool_list(args);
            let _ = self.inst(O_CALLIND, T_NONE, 1, fp, sg, at);
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let mut em = rm;
            let mut et = TYPE_NONE;
            if !c.mg.resolve(rm, y.as_data.arr.elem, &mut em, &mut et) || depth > 8 {
                return self.fail("drop-array");
            }
            let n = c.mg.arr_len(rm, &y);
            let mut ei = TyI { cls: 0 };
            if n < 0 || !self.ty(c, em, et, &mut ei) {
                return self.fail("drop-array");
            }
            // One element at a time, the counter in memory.
            let pi = self.ptr_int();
            let cnt = self.temp(TyI { cls: VC_SCALAR, mty: pi, size: pb, align: pb });
            let z = self.zero(pi);
            self.store(z, cnt, 0, false);
            let head = self.block();
            let body = self.block();
            let done = self.block();
            let eh = self.edge(head, NONE, NONE);
            let _ = self.inst(O_JMP, T_NONE, 0, eh, VNONE, VNONE);
            self.b.begin(head);
            let i = self.load(pi, cnt, 0, false);
            let lim = self.iconst(pi, n as u64);
            let more = self.icmp(C_ULT, i, lim);
            let eb = self.edge(body, NONE, NONE);
            let ed = self.edge(done, NONE, NONE);
            let _ = self.inst(O_BR, T_NONE, 0, more, eb, ed);
            self.b.begin(body);
            let i2 = self.load(pi, cnt, 0, false);
            let ea = self.ptradd(addr, i2, ei.size, 0);
            if !self.drop_at(c, em, et, ea, depth + 1) {
                return false;
            }
            let i3 = self.load(pi, cnt, 0, false);
            let one = self.iconst(pi, 1);
            let nx = self.arith(O_ADD, i3, one);
            self.store(nx, cnt, 0, false);
            let eh2 = self.edge(head, NONE, NONE);
            let _ = self.inst(O_JMP, T_NONE, 0, eh2, VNONE, VNONE);
            self.b.begin(done);
            return true;
        }
        let mut fs = String::new();
        let user = c.user_free_covers(rm, rt);
        if !c.mg.free_target(rm, rt, user, &mut fs) {
            return self.fail("drop-target");
        }
        if c.collect_demand {
            c.note_free(rm, rt, fs.as_str());
        }
        let a = if c.mg.is_zst(rm, rt) {
            self.sentinel(c, rm, rt);
        } else {
            addr;
        };
        let args: []Value = [a];
        let tys: []u32 = [T_PTR as u32];
        let _ = self.call_sym(fs.as_str(), args, tys, T_NONE);
        return true;
    }
}

// Append source text `t` of an assertion, cut at the C path's limit on a character boundary.
fn push_src(t: str, out: &mut String) {
    let mut n = t.len();
    if n > cbe::ASSERT_SRC_MAX {
        n = cbe::ASSERT_SRC_MAX;
        while n > 0 && (t.byte_at(n) & 0xC0) == 0x80 {
            n -= 1;
        }
    }
    out.push_str(t.slice(0, n));
}

extend Lower {
    // A call: a verified intrinsic as its LIR operation; a dyn receiver or a `dyn fn` through its
    // table; a capturing closure with its env first; a function value indirectly; else the symbol.
    fn call_term(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: irc::Terminator) bool {
        if t.intr != irc::CI_NONE {
            if !self.intrinsic_call(c, b, t) {
                return false;
            }
            self.after_call(t);
            return true;
        }
        let mut args = Vector::<Value>::new();
        let mut tys = Vector::<u32>::new();
        let mut name = String::new();
        let mut fv = VNONE;
        let mut first: u32 = 0;
        let mut pcallee = t.callee;
        let mut nfixed = NONE;
        let mut variadic = t.is_variadic;
        let pb = self.pkg.ptr_bytes;
        let fat = TyI { cls: VC_MEM, mty: T_NONE, size: 2 * pb, align: pb };
        if t.callee.node == NODE_NONE {
            let ct = b.operands[t.a as usize].ty;
            let mut cm = b.module;
            let mut ctt = TYPE_NONE;
            let cy = Lower::resolved(c, b.module, ct, &mut cm, &mut ctt);
            self.ind_m = cm;
            self.ind_t = ctt;
            if cy.kind == TypeKind::TYPE_DYN {
                self.ind_t = Lower::ast(c, cm).dyn_fn_sig(&cy);
                let fa = self.operand_addr(c, b, t.a, fat);
                if fa == VNONE {
                    return false;
                }
                let d = self.load(T_PTR, fa, 0, false);
                let vt = self.load(T_PTR, fa, pb, false);
                fv = self.load(T_PTR, vt, pb, false);
                args.push(d);
                tys.push(T_PTR);
            } else if cy.kind == TypeKind::TYPE_FUNCTION && !cy.fn_sig() && Lower::closure_caps(c, cy) != 0 {
                c.mg.closure_sym(cy.module, cy.as_data.decl, &mut name);
                let mut ei = TyI { cls: 0 };
                if !self.ty(c, cm, ctt, &mut ei) {
                    return false;
                }
                let ea = self.operand_addr(c, b, t.a, ei);
                if ea == VNONE {
                    return false;
                }
                args.push(ea);
                tys.push(T_PTR);
            } else {
                fv = self.operand(c, b, t.a);
                if fv == VNONE {
                    return self.fail("callee-value");
                }
            }
        } else {
            let mut om = b.module;
            let mut ot = TYPE_NONE;
            let mut stars: u32 = 0;
            let recv = c.dyn_recv_of(b, &t, &mut om, &mut ot, &mut stars);
            if recv != irc::IR_NONE {
                // The receiver's data pointer takes `self`; the method comes from the table.
                let mut fa = VNONE;
                if stars == 0 {
                    fa = self.operand_addr(c, b, recv, fat);
                } else {
                    fa = self.operand(c, b, recv);
                    for _ in 1..stars {
                        fa = self.load(T_PTR, fa, 0, false);
                    }
                }
                let slot = c.vt_slot(om, ot, t.callee);
                if fa == VNONE || slot == NONE {
                    return self.fail("dyn-call");
                }
                let d = self.load(T_PTR, fa, 0, false);
                let vt = self.load(T_PTR, fa, pb, false);
                fv = self.load(T_PTR, vt, slot * pb, false);
                args.push(d);
                tys.push(T_PTR);
                first = 1;
            } else {
                if !c.term_callee_sym(b, &t, true, &mut name) {
                    return self.fail("callee-sym");
                }
                // An intrinsic the backend expands is a call of its name (`target::intrin`).
                let isa = tgt::isa(Lower::p(c).arch).name;
                if Lower::p(c).c_fns.contains(&(t.callee.module as u64 << 32 | t.callee.node as u64)) && !intrin::has(
                    isa,
                    name.as_str(),
                ) && intrin::lane_form(isa, name.as_str()) == 0 {
                    // Named as the extern block declares it.
                    let ca = Lower::ast(c, t.callee.module);
                    let nm = ca.at_const(ca.ext_name(t.callee.node)).as_data.name.text;
                    self.pend_c = "calls a function no object defines (a C header's `static` function, or an intrinsic the native backend lacks)";
                    self.pend_name = String::from_str(
                        Lower::p(c).modules.at(t.callee.module as usize).source.as_str().slice(
                            nm.start as usize,
                            nm.end as usize,
                        ),
                    );
                }
                if c.mg.in_interface(t.callee.module, t.callee.node) != NODE_NONE && c.mg.last_method_def.node != NODE_NONE {
                    pcallee = c.mg.last_method_def;
                }
            }
            let fd = Lower::ast(c, pcallee.module).at_const(pcallee.node);
            if fd.kind == NodeKind::NODE_FUNCTION && Lower::ast(c, pcallee.module).ext(pcallee.node).function.is_variadic() {
                variadic = true;
            }
        }
        // A generic callee's parameter types read the bindings of its instance (`arg_mode`); the
        // arguments read the caller's.
        self.bind_callee(c, b, &t);
        for i in first..t.args_len {
            let opid = b.oper_pool[(t.args_start + i) as usize];
            if variadic && nfixed == NONE && t.callee.node != NODE_NONE {
                let fd = Lower::ast(c, pcallee.module).at_const(pcallee.node);
                if fd.kind == NodeKind::NODE_FUNCTION && i >= Lower::ast(c, pcallee.module).ext(pcallee.node).function.params.len {
                    nfixed = args.len() as u32;
                }
            }
            if !self.call_arg(c, b, t.callee, pcallee, i, opid, &mut args, &mut tys) {
                self.binds.clear();
                self.ind_t = TYPE_NONE;
                return false;
            }
        }
        self.binds.clear();
        self.ind_t = TYPE_NONE;
        if nfixed == NONE {
            nfixed = args.len() as u32;
        }
        // The result: one value or memory, or a pack of several.
        let mut ti = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
        let mut dty = TYPE_NONE;
        let mut dst = VNONE;
        let mut dplace = PlaceRef { kind: PR_ZST };
        if t.dests_len == 1 {
            let dp = b.dest_pool[t.dests_start as usize];
            dty = b.places[dp as usize].ty;
            let ub = b.places[dp as usize].base;
            if b.locals[ub as usize].ty == TYPE_NONE && b.places[dp as usize].proj_len == 0 && self.upack.contains_key(
                &ub,
            ) {
                // Several results into an untyped local: its memory takes them; zero-sized ones return
                // nothing.
                let lt = (*self.upack.get(&ub).unwrap() >> 32) as u32;
                let sg = self.b.signature(tys[0..tys.len()], nfixed, variadic, ast::pick(lt == NONE, T_NONE, AGG | lt));
                if lt != NONE {
                    args.push(self.li[ub as usize].addr);
                }
                let at = self.b.pool_list(args[0..args.len()]);
                let _ = if fv != VNONE {
                    self.inst(O_CALLIND, T_NONE, args.len() as u16, fv, sg, at);
                } else {
                    let k = self.sym(name.as_str(), SK_FUNC);
                    self.inst(O_CALL, T_NONE, args.len() as u16, k, sg, at);
                };
                self.after_call(t);
                return true;
            }
            if dty == TYPE_NONE {
                return self.fail("untyped-dest");
            }
            if !self.ty(c, b.module, dty, &mut ti) {
                return false;
            }
            if ti.cls == VC_MEM {
                if !self.place(c, b, dp, &mut dplace) {
                    return false;
                }
                let pl = b.places[dp as usize];
                // A local whose storage just became live holds no value an escaped pointer may read.
                let unseen = !self.escaped[pl.base as usize] || self.fresh == pl.base;
                if pl.proj_len == 0 && unseen && self.li[pl.base as usize].kind == LK_MEM && !Lower::moved_arg(
                    b,
                    &t,
                    pl.base,
                ) {
                    dst = dplace.addr;
                }
            }
        } else if t.dests_len > 1 {
            let mut rtys = Vector::<TypeId>::new();
            for r in 0..t.dests_len {
                rtys.push(b.places[b.dest_pool[(t.dests_start + r) as usize] as usize].ty);
            }
            let saved = replace(&mut self.ret_off, Vector::<u32>::new());
            let lt = self.pack(c, b.module, &rtys);
            let offs = replace(&mut self.ret_off, saved);
            if lt == NONE {
                if self.err.len() != 0 {
                    return false;
                }
            } else {
                let pti = TyI {
                    cls: VC_MEM,
                    mty: T_NONE,
                    size: self.b.pool[lt as usize],
                    align: 1u32 << self.b.pool[lt as usize + 1],
                };
                let tmp = self.temp(pti);
                args.push(tmp);
                let sg = self.b.signature(tys[0..tys.len()], nfixed, variadic, AGG | lt);
                let at = self.b.pool_list(args[0..args.len()]);
                let _ = if fv != VNONE {
                    self.inst(O_CALLIND, T_NONE, args.len() as u16, fv, sg, at);
                } else {
                    let k = self.sym(name.as_str(), SK_FUNC);
                    self.inst(O_CALL, T_NONE, args.len() as u16, k, sg, at);
                };
                for r in 0..t.dests_len {
                    let dp = b.dest_pool[(t.dests_start + r) as usize];
                    let mut ri = TyI { cls: 0 };
                    if !self.ty(c, b.module, rtys[r as usize], &mut ri) {
                        return false;
                    }
                    if ri.cls == VC_ZST {
                        continue;
                    }
                    let mut p = PlaceRef { kind: 0 };
                    if !self.place(c, b, dp, &mut p) {
                        return false;
                    }
                    if ri.cls == VC_SCALAR {
                        let v = self.load(ri.mty, tmp, offs[r as usize], false);
                        if !self.write(p, v) {
                            return false;
                        }
                    } else {
                        let src = self.ptradd(tmp, VNONE, 0, offs[r as usize]);
                        self.memcpy(p.addr, src, ri.size);
                    }
                }
                self.after_call(t);
                return true;
            }
        }
        let mut r = VNONE;
        let nm = name.as_str();
        if fv != VNONE || !self.rt_prim(nm, &args, &mut r) && !self.mem_intrin(c, nm, &args, &tys, ti, &mut r) && !self.lanes_intrin(
            c,
            nm,
            &args,
            ti,
            &mut r,
        ) {
            r = self.emit_call(nm, fv, &args, &tys, nfixed, variadic, ti, c, b.module, dty, dst);
        }
        if t.dests_len == 1 && ti.cls == VC_SCALAR {
            let mut p = PlaceRef { kind: 0 };
            if !self.place(c, b, b.dest_pool[t.dests_start as usize], &mut p) || !self.write(p, r) {
                return false;
            }
        } else if t.dests_len == 1 && ti.cls == VC_MEM && r != dst {
            self.memcpy(dplace.addr, r, ti.size);
        }
        self.after_call(t);
        return true;
    }

    // An intrinsic that only loads or stores one vector (`intrin::mem_form`) as that load or store, with
    // no alignment; one of no instruction as its argument's bytes (a bitcast, else through a slot: a low
    // part, or a wider value whose other bytes are zero; an argument through memory, `tys` its signature
    // type, is read from its bytes): true, with the value in `out` (VNONE for a store), when `name` is one.
    fn mem_intrin(
        self: &mut Self,
        c: &cbe::CEmit,
        name: str,
        a: &Vector<Value>,
        tys: &Vector<u32>,
        ti: TyI,
        out: &mut Value,
    ) bool {
        *out = VNONE;
        let isa = tgt::isa(Lower::p(c).arch).name;
        if !intrin::has(isa, name) {
            return false;
        }
        if intrin::find(isa, name).len() == 0 && a.len() == 1 && ti.cls == VC_SCALAR && (tys[0] & AGG) != 0 {
            // The argument's address: its low bytes, the rest of a wider result zero.
            let asz = self.b.pool[(tys[0] & ~AGG) as usize];
            let tb = type_bytes(ti.mty, self.pkg.ptr_bytes);
            if tb <= asz {
                *out = self.load(ti.mty, a[0], 0, false);
            } else {
                let s = self.temp(TyI { cls: VC_MEM, mty: T_NONE, size: tb, align: 16 });
                self.store(self.zero(ti.mty), s, 0, false);
                self.memcpy(s, a[0], asz);
                *out = self.load(ti.mty, s, 0, false);
            }
            return true;
        }
        if intrin::find(isa, name).len() == 0 && a.len() == 1 && ti.cls == VC_SCALAR {
            let from = self.vty(a[0]);
            let fb = type_bytes(from, self.pkg.ptr_bytes);
            let tb = type_bytes(ti.mty, self.pkg.ptr_bytes);
            if from == ti.mty {
                *out = a[0];
            } else if fb == tb {
                *out = self.inst(O_BITCAST, ti.mty, 0, a[0], VNONE, VNONE);
            } else {
                let big = ast::pick(fb > tb, from, ti.mty);
                let s = self.temp(
                    TyI { cls: VC_MEM, mty: T_NONE, size: type_bytes(big, self.pkg.ptr_bytes), align: 16 },
                );
                if tb > fb {
                    self.store(self.zero(ti.mty), s, 0, false);
                }
                self.store(a[0], s, 0, false);
                *out = self.load(ti.mty, s, 0, false);
            }
            return true;
        }
        let f = intrin::mem_form(name);
        if f == intrin::MF_LOAD && a.len() == 1 && ti.cls == VC_SCALAR && is_vec(ti.mty) {
            *out = self.load(ti.mty, a[0], 0, true);
            return true;
        }
        if f == intrin::MF_STORE && a.len() == 2 && is_vec(self.vty(a[1])) {
            self.store(a[1], a[0], 0, true);
            return true;
        }
        return false;
    }

    // An x86 vector of the lanes its scalar arguments give (`intrin::lane_form`): one of constant lanes
    // loaded from read-only data, as a C compiler does, else stored lane by lane and loaded. True, with the
    // vector in `out`, when `name` is one.
    fn lanes_intrin(self: &mut Self, c: &cbe::CEmit, name: str, a: &Vector<Value>, ti: TyI, out: &mut Value) bool {
        if ti.cls != VC_SCALAR || !is_vec(ti.mty) {
            return false;
        }
        let lb = intrin::lane_form(tgt::isa(Lower::p(c).arch).name, name);
        let n = a.len();
        if lb == 0 || n as u32 * lb != ti.size {
            return false;
        }
        let lt = switch lb {
            1 => T_I8,
            2 => T_I16,
            4 => T_I32,
            _ => T_I64,
        };
        let mut konst = true;
        for k in 0..n {
            konst = konst && (a[k] & (VPARAM | VFLAG)) == 0 && self.b.insts[a[k] as usize].op == O_ICONST;
        }
        if konst {
            let mut bytes = String::new();
            for j in 0..n {
                let d = self.b.insts[a[j] as usize];
                let u = d.b as u64 << 32 | d.a as u64;
                for q in 0..lb {
                    bytes.push_byte((u >> 8 * q) as u8);
                }
            }
            let s = self.rodata(&mut bytes);
            let k = self.sym_of(s);
            let at = self.inst(O_SYMADDR, T_PTR, 0, k, 0, VNONE);
            *out = self.load(ti.mty, at, 0, true);
            return true;
        }
        let s = self.temp(TyI { cls: VC_MEM, mty: T_NONE, size: ti.size, align: ti.align });
        for j in 0..n {
            let mut v = a[j];
            if self.vty(v) != lt {
                v = self.inst(O_TRUNC, lt, 0, v, VNONE, VNONE);
            }
            self.store(v, s, j as u32 * lb, false);
        }
        *out = self.load(ti.mty, s, 0, false);
        return true;
    }

    // A primitive of the C runtime (`super_rt.h`: `std::core`'s bit counts and wrapping arithmetic over 64
    // bits, `std::int`'s 128-bit limb operations and traps, `std::float`'s binary128 probe) as operations:
    // true, with the value in `out` (VNONE for none), when `name` is one.
    fn rt_prim(self: &mut Self, name: str, a: &Vector<Value>, out: &mut Value) bool {
        *out = VNONE;
        if !name.starts_with("sc_") {
            return false;
        }
        let n = a.len();
        if n == 0 {
            if name == "sc_has_i128" || name == "sc_has_f128" {
                // The native backends have 128-bit integers and no binary128 floats (Apple's C compilers on
                // arm64 neither), so the limb code of `std::float` stands.
                *out = self.iconst(T_I32, ast::pick(name == "sc_has_i128", 1u64, 0u64));
                return true;
            }
            return false;
        }
        if n == 1 && (name == "sc_clz64" || name == "sc_ctz64" || name == "sc_popcount64") {
            let op = ast::pick(name == "sc_clz64", O_CLZ, ast::pick(name == "sc_ctz64", O_CTZ, O_POPCNT));
            let c = self.inst(op, T_I64, 0, a[0], VNONE, VNONE);
            *out = self.inst(O_TRUNC, T_I32, 0, c, VNONE, VNONE);
            return true;
        }
        if n == 1 && (name == "sc_int_overflow" || name == "sc_int_div_zero" || name == "sc_int_div_overflow") {
            // A trap with the operator's message; overflow wraps instead in a build without overflow checks.
            if !self.wrap || name != "sc_int_overflow" {
                let sg = self.b.signature([T_PTR as u32][0..1], 1, false, T_NONE);
                let at = self.b.pool_list(a[0..1]);
                let k = self.sym("__sc_panic", SK_FUNC);
                let _ = self.inst(O_CALL, T_NONE, 1, k, sg, at);
            }
            return true;
        }
        if n == 2 && (name == "sc_wadd64" || name == "sc_wsub64" || name == "sc_wmul64") {
            *out = self.arith(
                ast::pick(name == "sc_wadd64", O_ADD, ast::pick(name == "sc_wsub64", O_SUB, O_MUL)),
                a[0],
                a[1],
            );
            return true;
        }
        if n == 2 && (name == "sc_wshl64" || name == "sc_wshr64" || name == "sc_wsar64") {
            let s = self.inst(O_ZEXT, T_I64, 0, a[1], VNONE, VNONE);
            *out = self.arith(
                ast::pick(name == "sc_wshl64", O_SHL, ast::pick(name == "sc_wshr64", O_LSHR, O_ASHR)),
                a[0],
                s,
            );
            return true;
        }
        if n == 2 && (name == "sc_mulo_u64" || name == "sc_mulo_i64") {
            *out = VFLAG | self.inst(O_MULO, T_I64, ast::pick(name == "sc_mulo_i64", OV_SIGNED, 0), a[0], a[1], VNONE);
            return true;
        }
        if n == 3 && name == "sc_mul64" {
            // The full product: the low half returned, the high half stored.
            let p = self.arith(O_MUL, self.wide(a[0]), self.wide(a[1]));
            self.store(self.high(p), a[2], 0, false);
            *out = self.inst(O_TRUNC, T_I64, 0, p, VNONE, VNONE);
            return true;
        }
        if n == 4 && name == "sc_div128by64" {
            let u = self.pair(a[1], a[0]);
            let v = self.wide(a[2]);
            self.store(self.inst(O_TRUNC, T_I64, 0, self.arith(O_UREM, u, v), VNONE, VNONE), a[3], 0, false);
            *out = self.inst(O_TRUNC, T_I64, 0, self.arith(O_UDIV, u, v), VNONE, VNONE);
            return true;
        }
        if n == 7 && (name == "sc_i128_add" || name == "sc_i128_sub") {
            // Limb by limb: the carry (borrow) of the low limbs into the high ones, out of either.
            let op = ast::pick(name == "sc_i128_add", O_ADDO, O_SUBO);
            let lo = self.inst(op, T_I64, 0, a[0], a[2], VNONE);
            let hi0 = self.inst(op, T_I64, 0, a[1], a[3], VNONE);
            let c0 = self.inst(O_ZEXT, T_I64, 0, VFLAG | lo, VNONE, VNONE);
            let hi = self.inst(op, T_I64, 0, hi0, c0, VNONE);
            let c = self.arith(O_OR, VFLAG | hi0, VFLAG | hi);
            self.store(lo, a[4], 0, false);
            self.store(hi, a[5], 0, false);
            self.store(self.inst(O_ZEXT, T_I64, 0, c, VNONE, VNONE), a[6], 0, false);
            return true;
        }
        if n == 8 && name == "sc_i128_mul" {
            // The 256-bit product from four 64 x 64 partials (`super_rt.h`'s order): m1 cannot overflow; m2
            // can, and its carry lands 128 bits up.
            let p0 = self.arith(O_MUL, self.wide(a[0]), self.wide(a[2]));
            let m1 = self.arith(O_ADD, self.arith(O_MUL, self.wide(a[0]), self.wide(a[3])), self.high_wide(p0));
            let m2 = self.arith(O_ADD, m1, self.arith(O_MUL, self.wide(a[1]), self.wide(a[2])));
            let cy = self.inst(O_ZEXT, T_I128, 0, self.icmp(C_ULT, m2, m1), VNONE, VNONE);
            let h0 = self.arith(O_ADD, self.arith(O_MUL, self.wide(a[1]), self.wide(a[3])), self.high_wide(m2));
            let hi = self.arith(O_ADD, h0, self.arith(O_SHL, cy, self.w128(64)));
            self.store(self.inst(O_TRUNC, T_I64, 0, p0, VNONE, VNONE), a[4], 0, false);
            self.store(self.inst(O_TRUNC, T_I64, 0, m2, VNONE, VNONE), a[5], 0, false);
            self.store(self.inst(O_TRUNC, T_I64, 0, hi, VNONE, VNONE), a[6], 0, false);
            self.store(self.inst(O_TRUNC, T_I64, 0, self.high_wide(hi), VNONE, VNONE), a[7], 0, false);
            return true;
        }
        if n == 8 && name == "sc_i128_divmod" {
            let x = self.pair(a[0], a[1]);
            let y = self.pair(a[2], a[3]);
            let q = self.arith(O_UDIV, x, y);
            let r = self.arith(O_UREM, x, y);
            self.store(self.inst(O_TRUNC, T_I64, 0, q, VNONE, VNONE), a[4], 0, false);
            self.store(self.inst(O_TRUNC, T_I64, 0, self.high_wide(q), VNONE, VNONE), a[5], 0, false);
            self.store(self.inst(O_TRUNC, T_I64, 0, r, VNONE, VNONE), a[6], 0, false);
            self.store(self.inst(O_TRUNC, T_I64, 0, self.high_wide(r), VNONE, VNONE), a[7], 0, false);
            return true;
        }
        if name.starts_with("sc_f128_") {
            // Unreachable behind `sc_has_f128` (0): the C stubs abort.
            let sg = self.b.signature([T_PTR as u32][0..0], 0, false, T_NONE);
            let at = self.b.pool_list(a[0..0]);
            let k = self.sym("abort", SK_FUNC);
            let _ = self.inst(O_CALL, T_NONE, 0, k, sg, at);
            return true;
        }
        return false;
    }

    // The 128-bit constant `v`.
    fn w128(self: &mut Self, v: u64) Value {
        let w = self.b.words.len() as u32;
        self.b.words.push(v);
        self.b.words.push(0);
        return self.inst(O_WCONST, T_I128, 0, w, 2, VNONE);
    }

    // 64-bit `v` zero-extended to 128 bits.
    fn wide(self: &mut Self, v: Value) Value {
        return self.inst(O_ZEXT, T_I128, 0, v, VNONE, VNONE);
    }

    // The 128-bit value of 64-bit limbs `lo` and `hi`.
    fn pair(self: &mut Self, lo: Value, hi: Value) Value {
        return self.arith(O_OR, self.arith(O_SHL, self.wide(hi), self.w128(64)), self.wide(lo));
    }

    // The high 64 bits of 128-bit `v`, as a 128-bit value.
    fn high_wide(self: &mut Self, v: Value) Value {
        return self.arith(O_LSHR, v, self.w128(64));
    }

    // The high 64 bits of 128-bit `v`.
    fn high(self: &mut Self, v: Value) Value {
        return self.inst(O_TRUNC, T_I64, 0, self.high_wide(v), VNONE, VNONE);
    }

    // Continue after a call: to its successor, or nowhere when it does not return.
    fn after_call(self: &mut Self, t: irc::Terminator) {
        if t.t0 == irc::IR_NONE {
            let _ = self.inst(O_UNREACHABLE, T_NONE, 0, VNONE, VNONE, VNONE);
            return;
        }
        self.goto(t.t0);
    }

    // Whether call `t` moves local `l` as an argument (its memory then passes to the callee).
    const fn moved_arg(b: &irc::CoreBody, t: &irc::Terminator, l: u32) bool {
        for i in 0..t.args_len {
            let op = b.operands[b.oper_pool[(t.args_start + i) as usize] as usize];
            if op.kind != irc::OP_CONST && b.places[op.data as usize].base == l {
                return true;
            }
        }
        return false;
    }

    // The capture count of closure type `y`.
    fn closure_caps(c: &cbe::CEmit, y: Ty) u32 {
        let cf = Lower::ast(c, y.module).closure_fact(y.as_data.decl);
        if cf == null {
            return 0;
        }
        return unsafe (&*cf).ncaps;
    }

    // A verified intrinsic call: memory copy and fill, atomics and fences.
    fn intrinsic_call(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: irc::Terminator) bool {
        let k = t.intr;
        let mut v = Vector::<Value>::new();
        for i in 0..t.args_len {
            let x = self.operand(c, b, b.oper_pool[(t.args_start + i) as usize]);
            if x == VNONE {
                return self.fail("intrinsic-argument");
            }
            v.push(x);
        }
        let mut res = VNONE;
        if k == irc::CI_MEMCPY || k == irc::CI_MEMMOVE {
            let n = self.int_to(v[2], self.ptr_int(), false);
            let _ = self.inst(O_MEMCPY, T_NONE, ast::pick(k == irc::CI_MEMMOVE, MEM_OVERLAP, 0), v[0], v[1], n);
            res = v[0];
        } else if k == irc::CI_MEMSET {
            let n = self.int_to(v[2], self.ptr_int(), false);
            let byte = self.int_to(v[1], T_I8, false);
            let _ = self.inst(O_MEMSET, T_NONE, 0, v[0], byte, n);
            res = v[0];
        } else if k == irc::CI_FENCE {
            return self.with_order(c, b, t, &v, 0, NONE);
        } else if k == irc::CI_ATOMIC_LOAD {
            return self.with_order(c, b, t, &v, 1, NONE);
        } else if k == irc::CI_ATOMIC_STORE || k == irc::CI_ATOMIC_RMW {
            return self.with_order(c, b, t, &v, 2, NONE);
        } else if k == irc::CI_ATOMIC_CAS {
            return self.with_order(c, b, t, &v, 4, 5);
        } else {
            return self.fail("intrinsic-call");
        }
        if t.dests_len == 1 && res != VNONE {
            let mut p = PlaceRef { kind: 0 };
            let mut ti = TyI { cls: 0 };
            let dp = b.dest_pool[t.dests_start as usize];
            if !self.ty(c, b.module, b.places[dp as usize].ty, &mut ti) {
                return false;
            }
            if ti.cls == VC_SCALAR {
                return self.place(c, b, dp, &mut p) && self.write(p, res);
            }
        }
        return true;
    }

    // An atomic operation whose order is argument `oi` (and failure order `fi` for a compare and
    // exchange): constant orders lower to the operation; others to a switch over the five orders,
    // an invalid one trapping as the runtime does.
    fn with_order(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        t: irc::Terminator,
        v: &Vector<Value>,
        oi: u32,
        fi: u32,
    ) bool {
        let mut so: i64 = 0;
        let mut fo: i64 = 0;
        let sk = self.const_int(c, b, b.oper_pool[(t.args_start + oi) as usize], &mut so);
        let fk = fi == NONE || self.const_int(c, b, b.oper_pool[(t.args_start + fi) as usize], &mut fo);
        let mut dti = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
        if t.dests_len == 1 && !self.ty(
            c,
            b.module,
            b.places[b.dest_pool[t.dests_start as usize] as usize].ty,
            &mut dti,
        ) {
            return false;
        }
        let mut rslot = VNONE;
        if dti.cls == VC_SCALAR {
            rslot = self.temp(dti);
        }
        if sk && fk {
            if !self.atomic(c, b, t, v, so, fo, rslot, dti.mty) {
                return false;
            }
        } else {
            // A runtime order: a block per code it can take, others trap.
            let done = self.block();
            let fcodes: []u64 = [0, 1, 4];
            let mut fbl = Vector::<u32>::new();
            if fk {
                let k = self.block();
                let ek = self.edge(k, NONE, NONE);
                let _ = self.inst(O_JMP, T_NONE, 0, ek, VNONE, VNONE);
                fbl.push(k);
            } else {
                self.order_switch(v[fi as usize], fcodes, &mut fbl);
            }
            for j in 0..fbl.len() {
                self.b.begin(fbl[j]);
                let f = ast::pick(fk, fo, fcodes[j] as i64);
                let scodes: []u64 = [0, 1, 2, 3, 4];
                let mut sbl = Vector::<u32>::new();
                if sk {
                    sbl.push(fbl[j]);
                } else {
                    self.order_switch(v[oi as usize], scodes, &mut sbl);
                }
                for i in 0..sbl.len() {
                    if !sk {
                        self.b.begin(sbl[i]);
                    }
                    if !self.atomic(c, b, t, v, ast::pick(sk, so, i as i64), f, rslot, dti.mty) {
                        return false;
                    }
                    let ed = self.edge(done, NONE, NONE);
                    let _ = self.inst(O_JMP, T_NONE, 0, ed, VNONE, VNONE);
                }
            }
            self.b.begin(done);
        }
        if rslot != VNONE {
            let r = self.load(dti.mty, rslot, 0, false);
            let mut p = PlaceRef { kind: 0 };
            return self.place(c, b, b.dest_pool[t.dests_start as usize], &mut p) && self.write(p, r);
        }
        return true;
    }

    // A switch on memory order `ov` to a new block per code of `codes` (into `out`), any other code to the
    // trap.
    fn order_switch(self: &mut Self, ov: Value, codes: []u64, out: &mut Vector<u32>) {
        let mut es = Vector::<u32>::with_capacity(codes.len() + 1);
        let w0 = self.b.words.len() as u32;
        for i in 0..codes.len() {
            let k = self.block();
            out.push(k);
            es.push(self.edge(k, NONE, NONE));
            self.b.words.push(codes[i]);
        }
        let bad = self.panic_block("invalid memory order");
        es.push(self.edge(bad, NONE, NONE));
        let el = self.b.pool_list(es[0..es.len()]);
        let o = self.int_to(ov, T_I32, false);
        let _ = self.inst(O_SWITCH, T_NONE, codes.len() as u16, o, w0, el);
    }

    // One atomic operation with orders `so` and `fo`; its result into `rslot`.
    fn atomic(
        self: &mut Self,
        c: &mut cbe::CEmit,
        b: &irc::CoreBody,
        t: irc::Terminator,
        v: &Vector<Value>,
        so: i64,
        fo: i64,
        rslot: Value,
        rty: u8,
    ) bool {
        let k = t.intr;
        let valid = if k == irc::CI_ATOMIC_LOAD {
            so == 0 || so == 1 || so == 4;
        } else if k == irc::CI_ATOMIC_STORE {
            so == 0 || so == 2 || so == 4;
        } else {
            so >= 0 && so <= 4 && (fo == 0 || fo == 1 || fo == 4);
        };
        if !valid {
            // The runtime traps an order the operation cannot take.
            let one = self.iconst(T_I8, 1);
            self.check(one, "invalid memory order");
            let _ = c;
            return true;
        }
        let o = so as u16;
        let mut r = VNONE;
        if k == irc::CI_FENCE {
            let _ = self.inst(O_FENCE, T_NONE, o, VNONE, VNONE, VNONE);
        } else if k == irc::CI_ATOMIC_LOAD {
            r = self.inst(O_ALOAD, rty, o, v[0], VNONE, 0);
        } else if k == irc::CI_ATOMIC_STORE {
            let _ = self.inst(O_ASTORE, T_NONE, o, v[0], v[1], 0);
        } else if k == irc::CI_ATOMIC_RMW {
            let mut s = String::new();
            let _ = c.term_callee_sym(b, &t, false, &mut s);
            let nm = s.as_str();
            let op = if nm.contains("_swap_") {
                RMW_XCHG;
            } else if nm.contains("_add_") {
                RMW_ADD;
            } else if nm.contains("_sub_") {
                RMW_SUB;
            } else if nm.contains("_and_") {
                RMW_AND;
            } else if nm.contains("_or_") {
                RMW_OR;
            } else {
                RMW_XOR;
            };
            r = self.inst(O_ARMW, self.vty(v[1]), o | op << 4, v[0], v[1], 0);
        } else {
            let mut wk: i64 = 0;
            let weak = self.const_int(c, b, b.oper_pool[(t.args_start + 3) as usize], &mut wk) && wk != 0;
            r = self.inst(O_ACAS, T_I8, o | fo as u16 << 3 | ast::pick(weak, ACAS_WEAK, 0), v[0], v[1], v[2]);
        }
        if rslot != VNONE && r != VNONE {
            self.store(r, rslot, 0, false);
        }
        return true;
    }
}

extend Lower {
    // ---- Finishing ----

    // The phis' operands, the trivial phis replaced, the panic blocks, the block parameters and the
    // edges with their arguments: the draft becomes the body.
    fn finish(self: &mut Self, name: str) bool {
        let _ = name;
        // Each phi's operand per predecessor, read at that predecessor's end; a read may add phis.
        let mut k: usize = 0;
        while k < self.phis.len() {
            let ph = self.phis[k];
            let p0 = self.npred[ph.blk as usize];
            let p1 = self.npred[ph.blk as usize + 1];
            let ops = self.phi_ops.len() as u32;
            for q in p0..p1 {
                self.phi_ops.push(VNONE);
            }
            for q in p0..p1 {
                let v = self.read_var(ph.var, self.preds[q as usize]);
                self.phi_ops[(ops + q - p0) as usize] = v;
            }
            self.phis.index_mut(k).ops = ops;
            self.phis.index_mut(k).nops = p1 - p0;
            k += 1;
        }
        // A phi whose operands are one value (or itself) is that value; repeat until none changes.
        let mut changed = true;
        for _ in 0..self.phis.len() + 1 {
            if !changed {
                break;
            }
            changed = false;
            for i in 0..self.phis.len() {
                let ph = self.phis[i];
                if ph.repl != VNONE {
                    continue;
                }
                let me = VPARAM | PHI_TAG | i as u32;
                let mut same = VNONE;
                let mut trivial = true;
                for q in 0..ph.nops {
                    let v = self.find(self.phi_ops[(ph.ops + q) as usize]);
                    if v == me || v == same {
                        continue;
                    }
                    if same != VNONE {
                        trivial = false;
                        break;
                    }
                    same = v;
                }
                if trivial {
                    if same == VNONE {
                        same = self.zero(ph.ty);
                    }
                    self.phis.index_mut(i).repl = same;
                    changed = true;
                }
            }
        }
        // The panic blocks.
        for i in 0..self.pan_list.len() {
            let e = self.pan_list[i];
            self.b.begin((e >> 32) as u32);
            self.loc = self.pan_loc[i];
            let m = self.b.ref_msg(e as u32);
            let _ = self.inst(O_PANIC, T_NONE, 0, m, VNONE, VNONE);
        }
        // Block parameters: the entry's, then each core block's live phis.
        let np0 = self.b.blocks[0].param_len as u32;
        let mut pidx = Vector::<u32>::new();
        pidx.resize_default(self.phis.len());
        let mut byblk = Vector::<u64>::new();
        for i in 0..self.phis.len() {
            if self.phis[i].repl == VNONE {
                byblk.push(self.phis[i].blk as u64 << 32 | i as u64);
            }
        }
        byblk.sort();
        self.b.params.truncate(np0 as usize);
        let mut j: usize = 0;
        for blk in 0..self.lblk.len() {
            let lb = self.lblk[blk];
            let st = self.b.params.len() as u32;
            while j < byblk.len() && (byblk[j] >> 32) as usize == blk {
                let i = byblk[j] as u32;
                pidx[i as usize] = self.b.params.len() as u32;
                self.b.params.push(self.phis[i as usize].ty);
                j += 1;
            }
            if lb != NONE {
                let bk = self.b.blocks.index_mut(lb as usize);
                bk.param_start = st;
                bk.param_len = (self.b.params.len() as u32 - st) as u16;
            }
        }
        for bi in 1..self.b.blocks.len() {
            let bk = self.b.blocks[bi];
            if bk.param_len == 0 {
                self.b.blocks.index_mut(bi).param_start = 0;
            }
        }
        if self.b.params.len() > 0x3FFFFFFF {
            return self.fail("parameters");
        }
        // Operands: a phi's value becomes its parameter (or its replacement's).
        for i in 0..self.b.insts.len() {
            let t = self.b.insts[i];
            let f = op_info(t.op).form;
            let a = self.fin(t.a, &pidx, lv::operand_a(f));
            let bb = self.fin(t.b, &pidx, lv::operand_b(f));
            let cc = self.fin(t.c, &pidx, lv::operand_c(f));
            let ins = self.b.insts.index_mut(i);
            ins.a = a;
            ins.b = bb;
            ins.c = cc;
            if f == F_CALL || f == F_CALLIND {
                for q in 0..t.aux as u32 {
                    let at = (t.c + q) as usize;
                    self.b.pool[at] = self.fin(self.b.pool[at], &pidx, true);
                }
            } else if f == F_VOP || f == F_ASM {
                for q in 0..t.b {
                    let at = (t.a + q) as usize;
                    self.b.pool[at] = self.fin(self.b.pool[at], &pidx, true);
                }
            }
        }
        // Edges: each passes its target's phis their values at the end of its source.
        let mut args = Vector::<Value>::new();
        for i in 0..self.b.insts.len() {
            let t = self.b.insts[i];
            if t.op == O_JMP {
                let e = self.real_edge(t.a, &pidx, &byblk, &mut args);
                self.b.insts.index_mut(i).a = e;
            } else if t.op == O_BR {
                let e1 = self.real_edge(t.b, &pidx, &byblk, &mut args);
                let e2 = self.real_edge(t.c, &pidx, &byblk, &mut args);
                self.b.insts.index_mut(i).b = e1;
                self.b.insts.index_mut(i).c = e2;
            } else if t.op == O_SWITCH {
                for q in 0..t.aux as u32 + 1 {
                    let at = (t.c + q) as usize;
                    let e = self.real_edge(self.b.pool[at], &pidx, &byblk, &mut args);
                    self.b.pool[at] = e;
                }
            }
        }
        return self.err.len() == 0;
    }

    // Draft value `v` as a body value; `is_value` false leaves a field that holds no value.
    const fn fin(self: &Self, v: Value, pidx: &Vector<u32>, is_value: bool) Value {
        if !is_value || v == VNONE {
            return v;
        }
        let x = self.find(v);
        if (x & VPARAM) != 0 && (x & PHI_TAG) != 0 {
            return VPARAM | pidx[(x & ~(VPARAM | PHI_TAG)) as usize];
        }
        return x;
    }

    // Draft edge `d` in the pool, with the argument of each live phi of its target.
    fn real_edge(self: &mut Self, d: u32, pidx: &Vector<u32>, byblk: &Vector<u64>, args: &mut Vector<Value>) u32 {
        let de = self.edges[d as usize];
        args.truncate(0);
        if de.dst != NONE {
            // The live phis of `dst` are a run of `byblk`.
            let mut lo: usize = 0;
            let mut hi = byblk.len();
            while lo < hi {
                let mid = (lo + hi) / 2;
                if byblk[mid] >> 32 < de.dst as u64 {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            while lo < byblk.len() && (byblk[lo] >> 32) as u32 == de.dst {
                let ph = self.phis[(byblk[lo] as u32) as usize];
                let p0 = self.npred[de.dst as usize];
                let mut v = VNONE;
                for q in 0..ph.nops {
                    if self.preds[(p0 + q) as usize] == de.src {
                        v = self.phi_ops[(ph.ops + q) as usize];
                    }
                }
                args.push(self.fin(v, pidx, true));
                lo += 1;
            }
        }
        return self.b.edge(de.to, args[0..args.len()]);
    }
}

extend Lower {
    /// The C chunk `what` of unit `unit` (a module) just landed: the functions lowered for it are that
    /// unit's, its `own` ones when the chunk is of the module's own items. A chunk with none (C text the
    /// lowering does not see, or a refused body) or one that needs C (`pend_c`) puts the unit on C.
    pub(package) fn claim(self: &mut Self, unit: u32, what: str, own: bool) {
        if self.pend.len() == 0 && self.pend_known == 0 || self.pend_c.len() != 0 {
            self.conly.push(unit);
            let mut why = String::new();
            if self.pend_c.len() != 0 && self.pend.len() != 0 {
                let nm = self.pkg.spell(self.pkg.syms[self.pend[0] as usize].name);
                why.format_into("{} `{}` {}: `{}`", what, nm, self.pend_c, self.pend_name.as_str());
            } else if self.pend_c.len() != 0 {
                why.format_into("{} {}: `{}`", what, self.pend_c, self.pend_name.as_str());
            } else if self.fails.len() > self.fails_seen {
                let f = self.fails.at(self.fails.len() - 1);
                why.format_into("{} `{}` refused: {}", what, f.sym.as_str(), f.why);
            } else {
                why.format_into("{} has no LIR", what);
            }
            self.conly_why.push(why);
        }
        self.fails_seen = self.fails.len();
        self.pend_known = 0;
        self.pend_c = "";
        for i in 0..self.pend.len() {
            let y = self.pkg.syms.index_mut(self.pend[i] as usize);
            y.unit = unit;
            y.own = own;
        }
        self.pend.truncate(0);
    }

    /// Item `(m, n)`'s `@used` and `@unsafe(link_section)` onto the symbol named `name`, when defined.
    pub(package) fn item_attrs_named(self: &mut Self, c: &mut cbe::CEmit, name: str, m: ModuleId, n: NodeId) {
        let s = self.pkg.find_symbol(name);
        if s != NONE {
            self.item_attrs(c, s, m, n);
        }
    }

    // Item `(m, n)`'s `@used` and `@unsafe(link_section)` onto symbol `s`.
    fn item_attrs(self: &mut Self, c: &mut cbe::CEmit, s: u32, m: ModuleId, n: NodeId) {
        if n == NODE_NONE {
            return;
        }
        let a = Lower::ast(c, m);
        let ua = a.attr_of(n, AttrKind::ATTR_UNSAFE);
        if ua != null && (unsafe (*ua).arg & UNSAFE_LINK_SECTION) != 0 {
            let ss = unsafe (*ua).str_span;
            let spec = Lower::p(c).modules.at(m as usize).source.as_str().slice(ss.start as usize, ss.end as usize);
            self.pkg.set_section(s, spec);
        } else if a.attr_of(n, AttrKind::ATTR_USED) != null {
            self.pkg.syms.index_mut(s as usize).used = true;
        }
        if a.attr_of(n, AttrKind::ATTR_NOINLINE) != null {
            self.pkg.syms.index_mut(s as usize).noinline = true;
        }
    }

    /// Part `p` of a cached module (`Package::read_part`: its own items' LIR, as the build that recorded it
    /// left them) into the package, its functions in `loaded`.
    pub(package) fn load_part(self: &mut Self, p: &Package) {
        let _ = self.pkg.absorb(p);
        for s in 0..p.syms.len() {
            let y = p.syms[s];
            if y.kind == SK_FUNC && y.def != NONE {
                let k = self.pkg.find_symbol(p.spell(y.name));
                self.loaded.push(k);
                let _ = self.relower.insert(k);
            }
        }
    }

    /// Data symbol `name` belongs to unit `unit`; without a LIR definition the unit does not compile.
    pub(package) fn claim_data(self: &mut Self, name: str, unit: u32) {
        let s = self.pkg.find_symbol(name);
        if s != NONE && self.pkg.syms[s as usize].def != NONE {
            self.pkg.syms.index_mut(s as usize).unit = unit;
            return;
        }
        self.conly.push(unit);
        self.conly_why.push(format("`{}` has no LIR", name));
    }

    /// Whether a body lowered since the last claim needs what no object defines (`pend_c`), cleared.
    pub(package) const fn take_pend_c(self: &mut Self) bool {
        let r = self.pend_c.len() != 0;
        self.pend_c = "";
        return r;
    }

    /// Move `other`'s bodies, data and refusals into this lowering.
    pub(package) fn absorb(self: &mut Self, other: &mut Lower) {
        let _ = self.pkg.absorb(&other.pkg);
        for i in 0..other.conly.len() {
            self.conly.push(other.conly[i]);
            self.conly_why.push(replace(other.conly_why.index_mut(i), String::new()));
        }
        other.conly.truncate(0);
        other.conly_why.truncate(0);
        for i in 0..other.fails.len() {
            self.fails.push(LFail { sym: other.fails[i].sym.clone(), why: other.fails[i].why });
        }
        self.nbodies += other.nbodies;
        for i in 0..other.tests.len() {
            let t = &other.tests[i];
            self.tests.push(LTest { sym: t.sym.clone(), m: t.m, node: t.node });
        }
        other.tests.clear();
        other.pkg = Package::new(other.pkg.ptr_bytes);
        other.fails.truncate(0);
        other.nbodies = 0;
    }

    /// The `SC_LIR` checks over the merged package, reported on stderr: every body lowered and every
    /// body verified, and under `SC_LIR_EVAL` each test's evaluator run agrees with CTFE (`ctfe_agrees`).
    /// True when all hold.
    pub(package) fn check_all(self: &mut Self, pk: *const loader::Package) bool {
        // A body with inline assembly stays on the C path by design.
        let mut nasm: u64 = 0;
        for i in 0..self.fails.len() {
            if self.fails[i].why == "asm" {
                nasm += 1;
            }
        }
        let mut ok = self.fails.len() as u64 == nasm;
        let mut v = lv::Verifier::new();
        let mut nbad: u64 = 0;
        for i in 0..self.pkg.syms.len() {
            let s = self.pkg.syms[i];
            if s.def == NONE || s.kind != SK_FUNC {
                continue;
            }
            if !v.check(&self.pkg, self.pkg.spell(s.name), &self.pkg.bodies[s.def as usize]) || !v.check_calls(
                &self.pkg,
                self.pkg.spell(s.name),
                &self.pkg.bodies[s.def as usize],
            ) {
                if nbad < 20 {
                    eprint("lir: verify: {}\n", v.err.as_str());
                }
                if nbad < 3 && stdlib::getenv("SC_LIR_DUMP") != null {
                    let mut t = String::new();
                    lp::print_body(&self.pkg, self.pkg.spell(s.name), &self.pkg.bodies[s.def as usize], &mut t);
                    eprint("{}", t.as_str());
                }
                nbad += 1;
            }
        }
        // The refusals, by reason.
        let mut why = Vector::<str<'static>>::new();
        let mut cnt = Vector::<u64>::new();
        for i in 0..self.fails.len() {
            let w = self.fails[i].why;
            if w == "asm" {
                continue;
            }
            let mut k = why.len();
            for j in 0..why.len() {
                if why[j] == w {
                    k = j;
                }
            }
            if k == why.len() {
                why.push(w);
                cnt.push(0);
                eprint("lir: refused {}: {}\n", self.fails[i].sym.as_str(), w);
            }
            cnt[k] += 1;
        }
        for j in 0..why.len() {
            eprint("lir: {} bodies refused: {}\n", cnt[j], why[j]);
        }
        let ctfe_ok = self.ctfe_agrees(pk);
        if let Some(rn) = stdlib::get_env("SC_LIR_RUN") {
            // A debugging aid: one function run in the evaluator.
            let mut ev = le::Eval::new(&self.pkg);
            let o = ev.run(self.pkg.find_symbol(rn.as_str()), []);
            let mut lt = String::new();
            le::outcome_text(&self.pkg, &o, &mut lt);
            eprint("lir: run {}: {} value {}\n", rn.as_str(), lt.as_str(), o.value);
        }
        ok = ok && nbad == 0 && ctfe_ok;
        if ok && stdlib::getenv("SC_LIR_STATS") == null {
            return true;
        }
        eprint(
            "lir: {} bodies emitted, {} lowered, {} with inline assembly kept in C, {} refused, {} fail the verifier\n",
            self.nbodies,
            self.pkg.bodies.len(),
            nasm,
            self.fails.len() as u64 - nasm,
            nbad,
        );
        return ok;
    }
}

extend Lower {
    // Scalar `v` converted to type `to` as C converts at an assignment (`signed`: its source type is).
    fn fit(self: &mut Self, v: Value, to: u8, signed: bool) Value {
        let from = self.vty(v);
        if from == to || is_vec(from) || is_vec(to) {
            return v;
        }
        if (v & (VPARAM | VFLAG)) == 0 && is_int(from) && is_int(to) && self.b.insts[v as usize].op == O_ICONST {
            // A constant converts here.
            let k = self.b.insts[v as usize];
            let mut x = k.a as u64 | k.b as u64 << 32;
            let fb = type_bits(from, self.pkg.ptr_bytes);
            if signed && fb < 64 && (x >> (fb - 1) as u64 & 1) != 0 {
                x |= ~0u64 << fb as u64;
            }
            if v as usize + 1 != self.b.insts.len() {
                return self.iconst(to, x);
            }
            // The constant was made for this use: retype it in place.
            let tb = type_bits(to, self.pkg.ptr_bytes);
            if tb < 64 {
                x &= (1u64 << tb as u64) - 1;
            }
            let ins = self.b.insts.index_mut(v as usize);
            ins.ty = to;
            ins.a = x as u32;
            ins.b = (x >> 32) as u32;
            return v;
        }
        return self.convert(v, from, to, signed, signed, false);
    }
}

extend Lower {
    // The untyped locals a call of several results fills, and their copies, with the results' layout
    // and offsets. The results' types come from the body's projections of them where they name every
    // result, else from the callee's signature with its own arguments bound.
    fn untyped(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody) bool {
        let n = b.locals.len();
        // Each untyped local's call destination: itself for one, its source's for a copy.
        let mut root = Vector::<u32>::new();
        let mut any = false;
        for bi in 0..b.blocks.len() {
            let t = b.blocks[bi].term;
            if t.kind != irc::TM_CALL || t.dests_len != 1 {
                continue;
            }
            let dp = b.places[b.dest_pool[t.dests_start as usize] as usize];
            if dp.proj_len == 0 && b.locals[dp.base as usize].ty == TYPE_NONE {
                if !any {
                    root.reserve(n);
                    for _ in 0..n {
                        root.push(NONE);
                    }
                    any = true;
                }
                root[dp.base as usize] = dp.base;
            }
        }
        if !any {
            return true;
        }
        let mut grew = true;
        for _ in 0..n {
            if !grew {
                break;
            }
            grew = false;
            for si in 0..b.statements.len() {
                let st = b.statements[si];
                if st.kind != irc::ST_ASSIGN {
                    continue;
                }
                let dp = b.places[st.place as usize];
                let rv = b.rvalues[st.rvalue as usize];
                if dp.proj_len != 0 || root[dp.base as usize] != NONE || b.locals[dp.base as usize].ty != TYPE_NONE || rv.kind != irc::RV_USE {
                    continue;
                }
                let op = b.operands[rv.a as usize];
                if op.kind != irc::OP_CONST && b.places[op.data as usize].proj_len == 0 && root[b.places[op.data as usize].base as usize] != NONE {
                    root[dp.base as usize] = root[b.places[op.data as usize].base as usize];
                    grew = true;
                }
            }
        }
        // The projections' result types, per destination and result.
        let mut seen = Map::<u64, TypeId>::new();
        for pi in 0..b.places.len() {
            let pl = b.places[pi];
            if pl.proj_len == 0 || root[pl.base as usize] == NONE {
                continue;
            }
            let pj = b.projections[pl.proj_start as usize];
            if pj.kind == irc::PJ_FIELD && pj.ty != TYPE_NONE {
                seen.insert(root[pl.base as usize] as u64 << 32 | pj.data as u64, pj.ty);
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks[bi].term;
            if t.kind != irc::TM_CALL || t.dests_len != 1 {
                continue;
            }
            let l = b.places[b.dest_pool[t.dests_start as usize] as usize].base;
            if root[l as usize] != l || self.upack.contains_key(&l) {
                continue;
            }
            let mut tys = Vector::<TypeId>::new();
            let mut tm = b.module;
            let mut nb: usize = 0;
            if t.callee.node != NODE_NONE {
                let fa = Lower::ast(c, t.callee.module);
                let fd = fa.ext(t.callee.node).function;
                let rs = fd.returns;
                for k in 0..rs.len {
                    tys.push(fa.type_of(unsafe fa.list(rs)[k as usize]));
                }
                tm = t.callee.module;
                // A generic callee's own arguments are the call's trailing ones.
                let own = fd.generics.len;
                let tn = ast::pick(own < t.targs_len, own, t.targs_len);
                for k in 0..tn {
                    let at = b.targ_pool[(t.targs_start + t.targs_len - tn + k) as usize];
                    c.mg.push_sub(tm, unsafe fa.list(fd.generics)[(own - tn + k) as usize], b.module, at);
                }
                nb = tn as usize;
            } else {
                let mut rm = b.module;
                let mut rt = TYPE_NONE;
                let mut y = Lower::resolved(c, b.module, b.operands[t.a as usize].ty, &mut rm, &mut rt);
                let a = Lower::ast(c, rm);
                if y.kind == TypeKind::TYPE_DYN {
                    // A `dyn fn`: its function type's results.
                    y = *a.type_at(a.dyn_fn_sig(&y));
                }
                let item = y.kind == TypeKind::TYPE_FUNCTION && !y.fn_sig();
                let da = Lower::ast(c, y.module);
                let cf = if item {
                    da.closure_fact(y.as_data.decl);
                } else {
                    null;
                };
                if cf != null {
                    // A closure: the result types its facts record after the captures and parameters.
                    let at = unsafe (*cf).cap_start + unsafe (*cf).ncaps + unsafe (*cf).nparams;
                    for r in 0..unsafe (*cf).nrets {
                        tys.push(da.cap_facts[(at + r) as usize].ty);
                    }
                    tm = y.module;
                } else if item {
                    // A function item: its declaration's results.
                    let rs = da.ext(y.as_data.decl).function.returns;
                    for k in 0..rs.len {
                        tys.push(da.type_of(unsafe da.list(rs)[k as usize]));
                    }
                    tm = y.module;
                } else {
                    for k in 0..a.sig_len(&y, true) {
                        tys.push(a.sig_at(&y, true, k));
                    }
                    tm = rm;
                }
            }
            let mut all = true;
            for k in 0..tys.len() {
                all = all && seen.contains_key(&(l as u64 << 32 | k as u64));
            }
            if all {
                c.mg.pop_subs(nb);
                nb = 0;
                tm = b.module;
                for k in 0..tys.len() {
                    tys[k] = *seen.get(&(l as u64 << 32 | k as u64)).unwrap();
                }
            }
            let lt = self.pack(c, tm, &tys);
            c.mg.pop_subs(nb);
            if lt == NONE && self.err.len() != 0 {
                return self.fail("untyped-results");
            }
            // NONE: every result is zero-sized.
            let e = lt as u64 << 32 | self.uoffs.len() as u64;
            for k in 0..self.ret_off.len() {
                self.uoffs.push(self.ret_off[k]);
            }
            for x in 0..n {
                if root[x] == l {
                    self.upack.insert(x as u32, e);
                }
            }
        }
        return true;
    }
}

extend Lower {
    // Under `SC_LIR_DEBUG`, the type a refusal names.
    fn debug_ty(self: &Self, c: &mut cbe::CEmit, why: str, m: ModuleId, t: TypeId) {
        if !self.dbg || self.err.len() != 0 {
            return;
        }
        let mut sp = String::new();
        let _ = c.mg.type_m(m, t, &mut sp);
        let y = *Lower::ast(c, m).type_at(t);
        let mut rm = m;
        let mut rt = t;
        let rs = c.mg.resolve(m, t, &mut rm, &mut rt);
        let lo = c.mg.layout_sub(m, t);
        eprint(
            "lir-debug {}: m{} t{} kind {} `{}` resolve {} -> m{} t{} layout ok {} unbound {} nsubs {}\n",
            why,
            m,
            t,
            y.kind as u32,
            sp.as_str(),
            rs,
            rm,
            rt,
            lo.ok,
            lo.unbound,
            c.mg.subs.len(),
        );
        if y.kind == TypeKind::TYPE_ARRAY {
            let ey = *Lower::ast(c, m).type_at(y.as_data.arr.elem);
            eprint("lir-debug   elem kind {} len {}\n", ey.kind as u32, c.mg.arr_len(m, &y));
        }
    }
}

extend Lower {
    // Member type `(m, t)` with the bindings in place substituted (into the body's module), so it
    // keeps its meaning after they are popped; itself when it names no parameter or cannot ground.
    fn grounded(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, t: TypeId) (ModuleId, TypeId) {
        if Lower::ast(c, m).type_concrete(t) {
            return m, t;
        }
        let mut g = TYPE_NONE;
        if c.mg.ground(m, t, self.bm, &mut g) {
            return self.bm, g;
        }
        return m, t;
    }
}

extend Lower {
    // The address of the type descriptor of `(rm, rt)`.
    fn type_info(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId) Value {
        let mut s = String::new();
        if !c.ti_need(rm, rt, &mut s) {
            return self.fail_v("type-info");
        }
        return self.symaddr(s.as_str(), SK_DATA);
    }
}

extend Lower {
    // The layout of aggregate `(rm, rt)` from its members' offsets and classes, a `void` one empty.
    fn fields_layout(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId) lay::Layout {
        let y = *Lower::ast(c, rm).type_at(rt);
        let mut dm = y.module;
        let mut dn = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT {
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *Lower::ast(c, rm).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
        }
        if y.kind != TypeKind::TYPE_FUNCTION && (dn == NODE_NONE || Lower::ast(c, dm).attr_of(dn, AttrKind::ATTR_ALIGN) != null) {
            return lay::Layout { ok: false };
        }
        // The engine refuses a type that grows through its members for its depth: each level would
        // retry every member. The cases this serves nest a few levels.
        if self.fl_depth >= 8 {
            return lay::Layout { ok: false };
        }
        let mut fl = Vector::<FieldAt>::new();
        self.fl_depth += 1;
        let ok = self.fields_of(c, rm, rt, &mut fl);
        self.fl_depth -= 1;
        if !ok {
            return lay::Layout { ok: false };
        }
        let mut size: u64 = 0;
        let mut al: u64 = 1;
        for k in 0..fl.len() {
            let f = fl[k];
            let mut ti = TyI {
                cls: VC_SCALAR,
                mty: f.mty,
                size: type_bytes(f.mty, self.pkg.ptr_bytes),
                align: type_bytes(f.mty, self.pkg.ptr_bytes),
            };
            let tok = f.t == TYPE_NONE || self.ty(c, f.m, f.t, &mut ti);
            if !tok {
                return lay::Layout { ok: false };
            }
            let end = f.off as u64 + ti.size as u64;
            if end > size {
                size = end;
            }
            if !f.packed && ti.align as u64 > al {
                al = ti.align;
            }
        }
        return lay::Layout { ok: true, size: round_up(size as u32, al as u32), align: al };
    }
}

extend Lower {
    // The members of the extern enum of variant `vd`, empty when no extern block declares it.
    fn extern_enum_members(a: &Ast, vd: NodeId) NodeList {
        let its = a.at_const(a.root).as_data.program.items;
        for i in 0..its.len {
            let n = a.at_const(unsafe a.list(its)[i as usize]);
            if n.kind != NodeKind::NODE_EXTERN_BLOCK {
                continue;
            }
            let inner = n.as_data.extern_block.items;
            for j in 0..inner.len {
                let e = a.at_const(unsafe a.list(inner)[j as usize]);
                if e.kind != NodeKind::NODE_ENUM {
                    continue;
                }
                let ms = a.ext(unsafe a.list(inner)[j as usize]).aggregate.members;
                for k in 0..ms.len {
                    if unsafe a.list(ms)[k as usize] == vd {
                        return ms;
                    }
                }
            }
        }
        return NodeList { start: 0, len: 0 };
    }
}

extend Lower {
    // Run the tests under the evaluator, spread over workers with an evaluator each. A test CTFE ran to
    // its end (no call it cannot run, no budget) must end alike: returning, or trapping with the same
    // class of trap at the same statement of the test. A test CTFE does not support must end as the
    // test expects. A test past a budget is not compared. A mismatch is reported; true when none.
    fn ctfe_agrees(self: &mut Self, pk: *const loader::Package) bool {
        if self.ctfe.len() == 0 {
            return true;
        }
        let mut by = Map::<u64, u32>::new();
        for i in 0..self.tests.len() {
            by.insert(self.tests[i].m as u64 << 32 | self.tests[i].node as u64, i as u32);
        }
        // The runs: the symbols of the tests to run, and per entry of `ctfe` its test, NONE for a test that
        // does not run (an FFI call, a body the emission did not lower, CTFE past a budget).
        let n = self.ctfe.len();
        let mut syms = Vector::<u32>::with_capacity(n);
        let mut test_of = Vector::<u32>::with_capacity(n);
        for i in 0..n {
            let r = self.ctfe.at(i);
            let ti = by.get(&(r.m as u64 << 32 | r.node as u64));
            if r.ffi || ti.is_none() || ctfe_budget(r.kind) {
                test_of.push(NONE);
            } else {
                test_of.push(*ti.unwrap());
                syms.push(self.pkg.find_symbol(self.tests[(*ti.unwrap()) as usize].sym.as_str()));
            }
        }
        let nr = syms.len();
        let jobs = (unsafe (*pk).jobs) as usize;
        let nw = if jobs < 2 || nr < 2 {
            1usize;
        } else if jobs < nr {
            jobs;
        } else {
            nr;
        };
        // Worker w runs w, w + nw, ...: long tests cluster by file.
        let mut outs = Vector::<Vector<le::Outcome>>::with_capacity(nw);
        for _ in 0..nw {
            outs.push(Vector::<le::Outcome>::new());
        }
        if nw == 1 {
            eval_task(EvalTask { pkg: &self.pkg, syms: &syms, w: 0, nw: 1, outs: outs.index_mut(0) });
        } else {
            let wg = psync::WaitGroup::new();
            for w in 0..nw {
                wg.add(1);
                let t = EvalTask { pkg: &self.pkg, syms: &syms, w: w, nw: nw, outs: outs.index_mut(w) };
                let wgc = wg.clone();
                launch || {
                    eval_task(t);
                    wgc.done();
                };
            }
            wg.wait_masked();
        }
        let mut ran: u64 = 0;
        let mut alone: u64 = 0;
        let mut bad: u64 = 0;
        let mut bad_c: u64 = 0;
        let mut ffi: u64 = 0;
        let mut budget: u64 = 0;
        let stats = stdlib::getenv("SC_LIR_STATS") != null;
        let mut j: usize = 0;
        for i in 0..n {
            let r = self.ctfe.at(i);
            let k = r.kind;
            if test_of[i] == NONE {
                if ctfe_budget(k) {
                    budget += 1;
                } else {
                    ffi += 1;
                }
                continue;
            }
            let t = &self.tests[test_of[i] as usize];
            let o = outs.at(j % nw).at(j / nw);
            j += 1;
            let lk = trap_class(o);
            let ctfe_ran = k != iri::IT_TRAP_UNSUPPORTED;
            if o.kind == le::EV_FFI {
                ffi += 1;
                if stats {
                    eprint("lir: ctfe: {}: the evaluator calls FFI: {}\n", t.sym.as_str(), o.msg.as_str());
                }
                continue;
            }
            if lk == iri::IT_TRAP_BUDGET_STEPS || lk == iri::IT_TRAP_BUDGET_MEMORY || lk == iri::IT_TRAP_BUDGET_DEPTH {
                budget += 1;
                continue;
            }
            // CTFE's run is the oracle; where CTFE does not run a test that makes no FFI call, the test's
            // own expectation is: it passes, or with `should_panic` it traps.
            let same = if ctfe_ran {
                lk == k && (k == iri::IT_TRAP_NONE || o.top.line == r.line && o.top.col == r.col);
            } else {
                lk == iri::IT_TRAP_NONE != r.panics;
            };
            if ctfe_ran {
                ran += 1;
            } else {
                alone += 1;
            }
            if same {
                continue;
            }
            bad += 1;
            if ctfe_ran {
                bad_c += 1;
            }
            if bad <= 20 || stats {
                let mut lt = String::new();
                le::outcome_text(&self.pkg, o, &mut lt);
                if ctfe_ran {
                    eprint(
                        "lir: ctfe: {}: CTFE kind {} \"{}\" at {}:{}, the evaluator {} (test statement {}:{})\n",
                        t.sym.as_str(),
                        k,
                        r.msg.as_str(),
                        r.line,
                        r.col,
                        lt.as_str(),
                        o.top.line,
                        o.top.col,
                    );
                } else {
                    eprint(
                        "lir: ctfe: {}: the test {}, the evaluator {} (test statement {}:{})\n",
                        t.sym.as_str(),
                        ast::pick(r.panics, "panics", "passes"),
                        lt.as_str(),
                        o.top.line,
                        o.top.col,
                    );
                }
            }
        }
        if bad != 0 || stats {
            eprint(
                "lir: ctfe: {} tests: {} compared with CTFE ({} disagree), {} CTFE does not finish checked against their expectation ({} fail it), {} call FFI, {} past a budget\n",
                self.ctfe.len(),
                ran,
                bad_c,
                alone,
                bad - bad_c,
                ffi,
                budget,
            );
        }
        return bad == 0;
    }
}

// Whether CTFE trap kind `k` ends a run at a budget: steps, memory, depth, an evaluation cycle, a value
// too large.
const fn ctfe_budget(k: u8) bool {
    return k == iri::IT_TRAP_BUDGET_STEPS || k == iri::IT_TRAP_BUDGET_MEMORY || k == iri::IT_TRAP_BUDGET_DEPTH || k == iri::IT_TRAP_CYCLE || k == iri::IT_TRAP_TOO_LARGE;
}

// One worker of `ctfe_agrees`: the tests `w`, `w + nw`, ... of `syms`, each run's outcome pushed to
// `outs` in that order.
struct EvalTask {
    pub(package) pkg: *const Package,
    pub(package) syms: *const Vector<u32>,
    pub(package) w: usize,
    pub(package) nw: usize,
    pub(package) outs: *mut Vector<le::Outcome>,
}

extend EvalTask as Copy {}

// Each task reads the package and the symbols, which outlive the tasks, and writes its own outcomes.
unsafe extend EvalTask as Send {}

fn eval_task(t: EvalTask) {
    let syms = unsafe &*t.syms;
    let outs = unsafe &mut *t.outs;
    let mut ev = le::Eval::new(unsafe &*t.pkg);
    ev.max_steps = EVAL_STEPS;
    let mut i = t.w;
    while i < syms.len() {
        outs.push(ev.run(syms[i], []));
        i += t.nw;
    }
}

// The interpreter's trap kind of evaluator outcome `o`: a lowered check's panic is the trap the
// interpreter raises for it.
const fn trap_class(o: &le::Outcome) u8 {
    if o.kind == le::EV_OK {
        return iri::IT_TRAP_NONE;
    }
    if o.kind != iri::IT_TRAP_PANIC {
        return o.kind;
    }
    let m = o.msg.as_str();
    if m.starts_with("attempt to shift") {
        return iri::IT_TRAP_UB_SHIFT;
    }
    if m == "attempt to divide by zero" || m == "attempt to calculate the remainder with a divisor of zero" {
        return iri::IT_TRAP_UB_DIV_ZERO;
    }
    if m.starts_with("attempt to ") && m.ends_with(" with overflow") {
        return iri::IT_TRAP_UB_OVERFLOW;
    }
    if m.starts_with("index out of bounds") || m == "range out of bounds" {
        return iri::IT_TRAP_UB_OOB;
    }
    return iri::IT_TRAP_PANIC;
}

// The 1-based line and column of byte `pos` of `src`.
const fn line_col(src: str, pos: u32, line: &mut u32, col: &mut u32) {
    let mut l: u32 = 1;
    let mut st: usize = 0;
    let end = if pos as usize > src.len() {
        src.len();
    } else {
        pos as usize;
    };
    for k in 0..end {
        if src.byte_at(k) == b'\n' {
            l += 1;
            st = k + 1;
        }
    }
    *line = l;
    *col = (end - st) as u32 + 1;
}

// ---- Static data ----

// One static object being rendered: its bytes and relocations.
struct DataBuf {
    pub(package) bytes: Vector<u8>,
    pub(package) relocs: Vector<Reloc>,
}

extend Lower {
    /// Define constant or static `name` of type `(em, ty)` with CTFE value `v` as package data:
    /// read-only `ro`, thread-local `tls`, aligned to at least `align`. A value CTFE gives no static
    /// form refuses the definition (reported by the check).
    pub(package) fn static_value(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &mut iri::Interp,
        name: str,
        em: ModuleId,
        ty: TypeId,
        v: iri::IVal,
        ro: bool,
        tls: bool,
        align: u64,
    ) {
        self.err = "";
        self.bm = em;
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, em, ty, &mut ti) {
            self.data_fail(name);
            return;
        }
        let mut d = DataBuf { bytes: Vector::<u8>::new(), relocs: Vector::<Reloc>::new() };
        d.bytes.resize_default(ti.size as usize);
        if self.dump.len() != 0 && self.dump.as_str() == name {
            eprint("lir: data {}: value kind {}\n", name, v.kind);
        }
        if v.kind == iri::IV_OBJ {
            let sr = cev.capture(v, true);
            if !sr.ok {
                self.data_fail(name);
                return;
            }
            self.static_group(c, cev, name, sr.root, ro, tls, align);
            return;
        }
        if v.kind == iri::IV_INT || v.kind == iri::IV_BOOL {
            put_le(&mut d.bytes, 0, v.i as u64, ti.size);
        } else if v.kind == iri::IV_FLOAT {
            let bits = if ti.mty == T_F32 {
                fl::f32_bits(v.f as f32) as u64;
            } else {
                fl::f64_bits(v.f);
            };
            put_le(&mut d.bytes, 0, bits, ti.size);
        } else if v.kind == iri::IV_STR {
            // A `str` view of the literal's bytes: the span indexes its own module's source.
            let src = Lower::p(c).modules.at(v.tm as usize).source.as_str();
            let a0 = (v.i >> 32) as usize;
            let b0 = (v.i & 0xFFFFFFFF) as usize;
            if b0 > src.len() || a0 >= b0 || ti.size != 2 * self.pkg.ptr_bytes {
                self.data_fail(name);
                return;
            }
            let mut tmp = String::new();
            let mut bytes = String::new();
            cbe::str_const_bytes(src.slice(a0, b0), v.f as i64, &mut tmp, &mut bytes);
            let n = bytes.len() as u64;
            let s = self.rodata(&mut bytes);
            d.relocs.push(Reloc { offset: 0, sym: s, addend: 0 });
            put_le(&mut d.bytes, self.pkg.ptr_bytes, n, self.pkg.ptr_bytes);
        } else if !(v.kind == iri::IV_PTR && v.i == 0) {
            self.data_fail(name);
            return;
        }
        self.data_define(name, ti, ro, tls, align, &d);
    }

    /// Define constant `name` of type `(em, ty)` as zero bytes.
    pub(package) fn static_zero(
        self: &mut Self,
        c: &mut cbe::CEmit,
        name: str,
        em: ModuleId,
        ty: TypeId,
        ro: bool,
        tls: bool,
        align: u64,
    ) {
        self.err = "";
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, em, ty, &mut ti) {
            self.data_fail(name);
            return;
        }
        let d = DataBuf { bytes: Vector::<u8>::new(), relocs: Vector::<Reloc>::new() };
        self.data_define(name, ti, ro, tls, align, &d);
    }

    /// Define static object group `root` of `cev` (a constant's, a type descriptor's) as `name` and
    /// its auxiliaries `name__ct<k>` (read-only), as the C path names them.
    pub(package) fn static_group(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &iri::Interp,
        name: str,
        root: u32,
        ro: bool,
        tls: bool,
        align: u64,
    ) {
        self.err = "";
        let groupn = unsafe (*cev.static_at(root)).groupn;
        for gi in root..root + groupn {
            let g = cev.static_at(gi);
            if gi != root && (unsafe (*g).parent != iri::S_NO_PARENT || unsafe (*g).inode != NODE_NONE) {
                continue;
            }
            let mut ti = TyI { cls: 0 };
            if !self.obj_ty(c, cev, gi, &mut ti) {
                self.data_fail(name);
                return;
            }
            if gi != root && ti.size == 0 {
                continue; // a zero-sized object's references name the sentinel
            }
            let mut d = DataBuf { bytes: Vector::<u8>::new(), relocs: Vector::<Reloc>::new() };
            d.bytes.resize_default(ti.size as usize);
            if !self.write_obj(c, cev, name, gi, 0, &mut d) {
                self.data_fail(name);
                return;
            }
            let mut sn = String::from_str(name);
            if gi != root {
                sn.format_into("__ct{}", unsafe (*g).ord - 1);
            }
            self.data_define(
                sn.as_str(),
                ti,
                gi != root || ro,
                gi == root && tls,
                ast::pick(gi == root, align, 1u64),
                &d,
            );
        }
    }

    // The data symbol `name` of class `ti` with `d`'s bytes and relocations.
    fn data_define(self: &mut Self, name: str, ti: TyI, ro: bool, tls: bool, align: u64, d: &DataBuf) {
        let s = self.pkg.symbol(name, ast::pick(tls, SK_TLS, SK_DATA));
        if self.pkg.syms[s as usize].def != NONE {
            return; // defined by an emission another emitter repeated
        }
        let mut al = ast::pick(ti.align == 0, 1u64, ti.align);
        if align > al {
            al = align;
        }
        let mut n = d.bytes.len();
        while n > 0 && d.bytes[n - 1] == 0 {
            n -= 1;
        }
        if !self.pkg.add_data(s, ti.size, log2(al as u32) as u8, ro, d.bytes[0..n], d.relocs[0..d.relocs.len()]) {
            self.data_fail(name);
        }
    }

    fn data_fail(self: &mut Self, name: str) {
        if self.dump.len() != 0 && self.dump.as_str() == name {
            eprint("lir: data {} refused: {}\n", name, self.err);
        }
        self.fails.push(
            LFail { sym: String::from_str(name), why: ast::pick(self.err.len() == 0, "static-data", self.err) },
        );
    }

    // The class of standalone or embedded static object `gi`.
    fn obj_ty(self: &mut Self, c: &mut cbe::CEmit, cev: &iri::Interp, gi: u32, out: &mut TyI) bool {
        let g = cev.static_at(gi);
        let shape = unsafe (*g).shape;
        if unsafe (*g).vt != TYPE_NONE {
            return self.ty(c, unsafe (*g).vm, unsafe (*g).vt, out);
        }
        if shape == iri::SS_HEAP || shape == iri::SS_ARRAY || shape == iri::SS_CELL {
            if !self.elem_ty(c, cev, gi, out) {
                return false;
            }
            if shape != iri::SS_CELL {
                let n = ast::pick(unsafe (*g).n == 0, 1u32, unsafe (*g).n);
                *out = TyI { cls: VC_MEM, mty: T_NONE, size: out.size * n, align: out.align };
            }
            return true;
        }
        let nb = self.push_obj_args(c, g);
        let ok = self.decl_ty(c, unsafe (*g).dm, unsafe (*g).dn, out);
        c.mg.pop_subs(nb);
        return ok;
    }

    // The element type of array or heap object `gi`, the value type of a cell: the recorded one, the
    // element of the array (or the type) an item's object declares, a share of the parent's place for an embedded array,
    // else the type of its first typed slot; a refusal when none is known (offsets need the element's
    // size).
    fn elem_ty(self: &mut Self, c: &mut cbe::CEmit, cev: &iri::Interp, gi: u32, out: &mut TyI) bool {
        let g = cev.static_at(gi);
        if unsafe (*g).ety != TYPE_NONE {
            return self.ty(c, unsafe (*g).etm, unsafe (*g).ety, out);
        }
        let n = (unsafe (*g).slots.len()) as u32;
        if unsafe (*g).inode != NODE_NONE {
            let a = Lower::ast(c, unsafe (*g).im);
            let tn = a.at_const(unsafe (*g).inode).as_data.const_def.ty;
            if tn != NODE_NONE {
                let mut rm = unsafe (*g).im;
                let mut rt = TYPE_NONE;
                let y = Lower::resolved(c, unsafe (*g).im, a.type_of(tn), &mut rm, &mut rt);
                // A cell holds the item's value whole.
                if y.kind == TypeKind::TYPE_ARRAY && unsafe (*g).shape != iri::SS_CELL {
                    return self.ty(c, rm, y.as_data.arr.elem, out);
                }
                return self.ty(c, rm, rt, out);
            }
        }
        if unsafe (*g).parent != iri::S_NO_PARENT && n != 0 {
            // The parent's place holds the whole array: each element its share.
            let mut pt = TyI { cls: 0 };
            let mut po: u32 = 0;
            let mut zal: u64 = 0;
            if !self.slot_ty(c, cev, unsafe (*g).parent, unsafe (*g).pslot, &mut po, &mut zal, &mut pt) {
                return false;
            }
            *out = TyI { cls: VC_MEM, mty: T_NONE, size: pt.size / n, align: pt.align };
            return true;
        }
        for k in 0..n {
            let sl = *unsafe (*g).slots.at(k as usize);
            if sl.ty != TYPE_NONE {
                return self.ty(c, sl.tm, sl.ty, out);
            }
        }
        if n == 0 {
            *out = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
            return true;
        }
        return self.fail("static-elem");
    }

    // Bind the generic parameters of static object `g`'s aggregate to its recorded arguments.
    fn push_obj_args(self: &mut Self, c: &mut cbe::CEmit, g: *const iri::StaticObj) usize {
        let dm = unsafe (*g).dm;
        let a = Lower::ast(c, dm);
        let gens = a.ext(unsafe (*g).dn).aggregate.generics;
        let mut nb: usize = 0;
        for i in 0..gens.len {
            if i as u8 >= unsafe (*g).nargs {
                break;
            }
            c.mg.push_sub(dm, unsafe a.list(gens)[i as usize], unsafe (*g).am[i as usize], unsafe (*g).at[i as usize]);
            nb += 1;
        }
        return nb;
    }

    // The class of aggregate declaration `(dm, dn)` under the bindings in place.
    fn decl_ty(self: &mut Self, c: &mut cbe::CEmit, dm: ModuleId, dn: NodeId, out: &mut TyI) bool {
        let a = Lower::ast(c, dm);
        if a.at_const(dn).kind == NodeKind::NODE_ENUM {
            if !a.enum_has_payload(dn) {
                let tb = ast::pick(a.enum_tag_is_byte(dn), 1u32, 4u32);
                *out = TyI { cls: VC_MEM, mty: T_NONE, size: tb, align: tb };
                return true;
            }
            let mut el = EnumL { ok: false };
            if !self.enum_shape(c, dm, dn, &mut el) {
                return false;
            }
            *out = TyI { cls: VC_MEM, mty: T_NONE, size: el.size, align: el.align };
            return true;
        }
        let mut fl = Vector::<FieldAt>::new();
        if !self.decl_fields(c, dm, dn, &mut fl) {
            return false;
        }
        let mut size: u32 = 0;
        let mut al: u32 = 1;
        for k in 0..fl.len() {
            let f = fl[k];
            let mut ti = TyI { cls: 0 };
            if !self.ty(c, f.m, f.t, &mut ti) {
                return false;
            }
            if f.off + ti.size > size {
                size = f.off + ti.size;
            }
            if !f.packed && ti.align > al {
                al = ti.align;
            }
        }
        let at = a.attr_of(dn, AttrKind::ATTR_ALIGN);
        if at != null {
            let mut v = (unsafe (*at).arg) as u64;
            if unsafe (*at).expr {
                let av = a.attr_value(dn, AttrKind::ATTR_ALIGN);
                if !av.ok {
                    return self.fail("align");
                }
                v = av.v;
            }
            if v as u32 > al {
                al = v as u32;
            }
        }
        *out = TyI { cls: VC_MEM, mty: T_NONE, size: round_up(size, al), align: al };
        return true;
    }

    // Write static object `gi` at offset `off` of `d`.
    fn write_obj(self: &mut Self, c: &mut cbe::CEmit, cev: &iri::Interp, name: str, gi: u32, off: u32, d: &mut DataBuf) bool {
        let g = cev.static_at(gi);
        let shape = unsafe (*g).shape;
        let nslots = (unsafe (*g).slots.len()) as u32;
        if shape == iri::SS_CELL {
            return nslots == 0 || self.write_slot(c, cev, name, gi, 0, off, unsafe (*g).etm, unsafe (*g).ety, d);
        }
        if shape == iri::SS_ARRAY || shape == iri::SS_HEAP {
            let mut ei = TyI { cls: 0 };
            if !self.elem_ty(c, cev, gi, &mut ei) {
                return false;
            }
            for k in 0..nslots {
                if !self.write_slot(c, cev, name, gi, k, off + k * ei.size, unsafe (*g).etm, unsafe (*g).ety, d) {
                    return false;
                }
            }
            return true;
        }
        let nb = self.push_obj_args(c, g);
        let ok = self.write_agg(c, cev, name, gi, off, d);
        c.mg.pop_subs(nb);
        return ok;
    }

    // `write_obj` for a struct, union or enum object, its arguments bound.
    fn write_agg(self: &mut Self, c: &mut cbe::CEmit, cev: &iri::Interp, name: str, gi: u32, off: u32, d: &mut DataBuf) bool {
        let g = cev.static_at(gi);
        let dm = unsafe (*g).dm;
        let dn = unsafe (*g).dn;
        let a = Lower::ast(c, dm);
        let nslots = (unsafe (*g).slots.len()) as u32;
        if unsafe (*g).shape == iri::SS_ENUM {
            let ms = a.ext(dn).aggregate.members;
            let ord = unsafe (*g).slots.at(0).i;
            if ord < 0 || ord as u32 >= ms.len {
                return true; // C writes `{0}`
            }
            let vid = unsafe a.list(ms)[ord as usize];
            let mut dv: i64 = 0;
            if !self.variant_value(c, dm, vid, &mut dv) {
                return false;
            }
            if !a.enum_has_payload(dn) {
                put_le(&mut d.bytes, off, dv as u64, ast::pick(a.enum_tag_is_byte(dn), 1u32, 4u32));
                return true;
            }
            let mut fl = Vector::<FieldAt>::new();
            if !self.decl_fields(c, dm, dn, &mut fl) {
                return false;
            }
            for i in 0..fl.len() {
                let f = fl[i];
                if f.idx == 0xFFFFFFFF {
                    put_le(&mut d.bytes, off + f.off, dv as u64, type_bytes(f.mty, self.pkg.ptr_bytes));
                } else if f.variant == vid && f.idx + 1 < nslots {
                    if !self.write_slot(c, cev, name, gi, f.idx + 1, off + f.off, f.m, f.t, d) {
                        return false;
                    }
                }
            }
            return true;
        }
        let mut fl = Vector::<FieldAt>::new();
        if !self.decl_fields(c, dm, dn, &mut fl) {
            return false;
        }
        let uact = unsafe (*g).uactive;
        for i in 0..fl.len() {
            let f = fl[i];
            if f.idx >= nslots || uact >= 0 && f.idx != uact as u32 {
                continue;
            }
            if !self.write_slot(c, cev, name, gi, f.idx, off + f.off, f.m, f.t, d) {
                return false;
            }
        }
        return true;
    }

    // Write slot `k` of static object `gi`, of type `(m, t)`, at offset `off` of `d`.
    fn write_slot(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &iri::Interp,
        name: str,
        gi: u32,
        k: u32,
        off: u32,
        m: ModuleId,
        t: TypeId,
        d: &mut DataBuf,
    ) bool {
        let g = cev.static_at(gi);
        let sl = *unsafe (*g).slots.at(k as usize);
        if sl.kind == iri::SK_ZERO || sl.kind == iri::SK_NULL {
            return true;
        }
        if sl.kind == iri::SK_AGG {
            return self.write_obj(c, cev, name, sl.child(), off, d);
        }
        if sl.kind == iri::SK_REL {
            for ri in 0..unsafe (*g).rels.len() {
                let r = *unsafe (*g).rels.at(ri);
                if r.slot == k {
                    return self.data_reloc(c, cev, name, r, off, d);
                }
            }
            return true;
        }
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, m, t, &mut ti) || ti.cls != VC_SCALAR {
            return self.fail("static-slot");
        }
        let bits = if sl.kind == iri::SK_FLOAT && ti.mty == T_F32 {
            fl::f32_bits(sl.f() as f32) as u64;
        } else {
            sl.i as u64;
        };
        put_le(&mut d.bytes, off, bits, ti.size);
        return true;
    }

    // The relocation of slot `r` at offset `off` of `d`: a function, the sentinel of a zero-sized
    // object, an item's storage, or a place in an object of the group.
    fn data_reloc(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &iri::Interp,
        name: str,
        r: iri::SRel,
        off: u32,
        d: &mut DataBuf,
    ) bool {
        let mut sn = String::new();
        if r.kind == iri::SREL_FN {
            let tgt = c.mg.method_target(r.fm, r.fnode);
            if !c.mg.fn_sym(r.fm, r.fnode, tgt, &mut sn) {
                return self.fail("static-fn");
            }
            d.relocs.push(Reloc { offset: off, sym: self.pkg.symbol(sn.as_str(), SK_FUNC), addend: 0 });
            return true;
        }
        let t = cev.static_at(r.target);
        let mut ti = TyI { cls: 0 };
        if !self.obj_ty(c, cev, r.target, &mut ti) {
            return false;
        }
        if unsafe (*t).ety != TYPE_NONE && ti.size == 0 && unsafe (*t).inode == NODE_NONE {
            let lo = c.mg.layout_sub(unsafe (*t).etm, unsafe (*t).ety);
            let al: u64 = ast::pick(lo.ok && lo.align > 1, lo.align, 1u64);
            d.relocs.push(Reloc { offset: off, sym: self.sentinel_sym(c, al), addend: 0 });
            return true;
        }
        // The place: an element or a field of the target, inside its standalone owner.
        let mut add: u32 = 0;
        let mut zal: u64 = 0;
        if r.toff != 0 && !self.slot_off(c, cev, r.target, r.toff, &mut add, &mut zal) {
            return false;
        }
        if zal != 0 {
            // A zero-sized place: the sentinel, as every zero-sized address.
            d.relocs.push(Reloc { offset: off, sym: self.sentinel_sym(c, zal), addend: 0 });
            return true;
        }
        let mut o = r.target;
        for _ in 0..1024 {
            let og = cev.static_at(o);
            if unsafe (*og).parent == iri::S_NO_PARENT || unsafe (*og).inode != NODE_NONE {
                break;
            }
            let mut so: u32 = 0;
            if !self.slot_off(c, cev, unsafe (*og).parent, unsafe (*og).pslot, &mut so, &mut zal) {
                return false;
            }
            add += so;
            o = unsafe (*og).parent;
        }
        let og = cev.static_at(o);
        if unsafe (*og).inode != NODE_NONE {
            if !c.mg.const_sym(unsafe (*og).im, unsafe (*og).inode, &mut sn) {
                return self.fail("static-item");
            }
        } else {
            sn.push_str(name);
            if unsafe (*og).ord != 0 {
                sn.format_into("__ct{}", unsafe (*og).ord - 1);
            }
        }
        d.relocs.push(Reloc { offset: off, sym: self.pkg.symbol(sn.as_str(), SK_DATA), addend: add });
        return true;
    }

    // The offset of slot `k` inside static object `gi`; `zal` the alignment of the slot's type when it is
    // zero-sized, else 0.
    fn slot_off(self: &mut Self, c: &mut cbe::CEmit, cev: &iri::Interp, gi: u32, k: u32, out: &mut u32, zal: &mut u64) bool {
        let mut st = TyI { cls: 0 };
        return self.slot_ty(c, cev, gi, k, out, zal, &mut st);
    }

    // `slot_off`, and the slot's type into `st`.
    fn slot_ty(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &iri::Interp,
        gi: u32,
        k: u32,
        out: &mut u32,
        zal: &mut u64,
        st: &mut TyI,
    ) bool {
        let g = cev.static_at(gi);
        let shape = unsafe (*g).shape;
        *zal = 0;
        if shape == iri::SS_CELL || shape == iri::SS_ARRAY || shape == iri::SS_HEAP {
            if !self.elem_ty(c, cev, gi, st) {
                return false;
            }
            *out = ast::pick(shape == iri::SS_CELL, 0u32, k * st.size);
        } else {
            let nb = self.push_obj_args(c, g);
            let ok = self.field_slot(c, g, k, out, st);
            c.mg.pop_subs(nb);
            if !ok {
                return false;
            }
        }
        if st.size == 0 {
            *zal = ast::pick(st.align > 1, st.align, 1u32);
        }
        return true;
    }

    // The offset and the type of field slot `k` of struct or enum object `g`, its arguments bound.
    fn field_slot(self: &mut Self, c: &mut cbe::CEmit, g: *const iri::StaticObj, k: u32, out: &mut u32, st: &mut TyI) bool {
        let mut fl = Vector::<FieldAt>::new();
        if !self.decl_fields(c, unsafe (*g).dm, unsafe (*g).dn, &mut fl) {
            return false;
        }
        let mut variant = NODE_NONE;
        let mut idx = k;
        if unsafe (*g).shape == iri::SS_ENUM {
            let a = Lower::ast(c, unsafe (*g).dm);
            let ms = a.ext(unsafe (*g).dn).aggregate.members;
            variant = unsafe a.list(ms)[(unsafe (*g).slots.at(0).i) as usize];
            idx = k - 1;
        }
        for i in 0..fl.len() {
            if fl[i].idx == idx && fl[i].variant == variant {
                *out = fl[i].off;
                return self.ty(c, fl[i].m, fl[i].t, st);
            }
        }
        return self.fail("static-place");
    }
}

// `v`'s low `n` bytes, little-endian, at `off` of `b`.
const fn put_le(b: &mut Vector<u8>, off: u32, v: u64, n: u32) {
    for i in 0..n {
        if i < 8 {
            b[(off + i) as usize] = (v >> (8 * i) as u64) as u8;
        }
    }
}

extend Lower {
    /// Define array-literal constant `name` of type `(em, ty)` from its elements `els` (module `cm`'s
    /// literals and struct initializers), as the C path renders it: an array, a vector's lanes, or a
    /// view of the data array `name__data`.
    pub(package) fn static_elems(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &mut iri::Interp,
        name: str,
        em: ModuleId,
        ty: TypeId,
        cm: ModuleId,
        els: NodeList,
        ro: bool,
        tls: bool,
        align: u64,
    ) {
        self.err = "";
        self.bm = em;
        let mut rm = em;
        let mut rt = TYPE_NONE;
        let y = Lower::resolved(c, em, ty, &mut rm, &mut rt);
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, em, ty, &mut ti) {
            self.data_fail(name);
            return;
        }
        let a = Lower::ast(c, cm);
        let mut view = false;
        let erm = rm;
        let mut ert = TYPE_NONE;
        if y.kind == TypeKind::TYPE_INSTANCE && Lower::ast(c, rm).instance(y.as_data.inst).n > 0 && y.kind != TypeKind::TYPE_SIMD {
            view = true;
            ert = Lower::ast(c, rm).instance(y.as_data.inst).args[0];
        } else if y.kind == TypeKind::TYPE_ARRAY {
            ert = y.as_data.arr.elem;
        } else if y.kind == TypeKind::TYPE_SIMD {
            ert = y.as_data.elem;
        }
        let mut ei = TyI { cls: 0 };
        if ert == TYPE_NONE || !self.ty(c, erm, ert, &mut ei) {
            self.data_fail(name);
            return;
        }
        let mut d = DataBuf { bytes: Vector::<u8>::new(), relocs: Vector::<Reloc>::new() };
        d.bytes.resize_default((ei.size * els.len) as usize);
        for k in 0..els.len {
            if !self.write_elem(c, cev, cm, unsafe a.list(els)[k as usize], k * ei.size, erm, ert, &mut d) {
                self.data_fail(name);
                return;
            }
        }
        if !view {
            if d.bytes.len() < ti.size as usize {
                d.bytes.resize_default(ti.size as usize);
            }
            self.data_define(name, ti, ro, tls, align, &d);
            return;
        }
        // The view: the data array, or the aligned sentinel for none.
        let mut v = DataBuf { bytes: Vector::<u8>::new(), relocs: Vector::<Reloc>::new() };
        v.bytes.resize_default(ti.size as usize);
        let ds = if els.len == 0 {
            self.sentinel_sym(c, ast::pick(ei.align > 1, ei.align, 1u64));
        } else {
            let mut dn = String::from_str(name);
            dn.push_str("__data");
            self.data_define(
                dn.as_str(),
                TyI { cls: VC_MEM, mty: T_NONE, size: ei.size * els.len, align: ei.align },
                true,
                false,
                0,
                &d,
            );
            self.pkg.symbol(dn.as_str(), SK_DATA);
        };
        v.relocs.push(Reloc { offset: 0, sym: ds, addend: 0 });
        put_le(&mut v.bytes, self.pkg.ptr_bytes, els.len, self.pkg.ptr_bytes);
        self.data_define(name, ti, ro, tls, align, &v);
    }

    // Write element `eid` (module `cm`) of type `(m, t)` at offset `off` of `d`: a literal (its CTFE
    // value; a string as a view of its bytes) or a struct initializer, member by member.
    fn write_elem(
        self: &mut Self,
        c: &mut cbe::CEmit,
        cev: &mut iri::Interp,
        cm: ModuleId,
        eid: NodeId,
        off: u32,
        m: ModuleId,
        t: TypeId,
        d: &mut DataBuf,
    ) bool {
        let a = Lower::ast(c, cm);
        let n = a.at_const(eid);
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, m, t, &mut ti) {
            return false;
        }
        if n.kind == NodeKind::NODE_STRUCT_INITIALIZER {
            let mut rm = m;
            let mut rt = TYPE_NONE;
            let _ = Lower::resolved(c, m, t, &mut rm, &mut rt);
            let mut fl = Vector::<FieldAt>::new();
            if !self.fields_of(c, rm, rt, &mut fl) {
                return false;
            }
            let fls = n.as_data.struct_initializer.fields;
            for i in 0..fls.len {
                let fi = unsafe a.list(fls)[i as usize];
                let fd = a.resolution_def(a.at_const(fi).as_data.field_initializer.name);
                let mut hit = false;
                for k in 0..fl.len() {
                    if fl[k].node == fd.node {
                        hit = true;
                        if !self.write_elem(
                            c,
                            cev,
                            cm,
                            a.at_const(fi).as_data.field_initializer.value,
                            off + fl[k].off,
                            fl[k].m,
                            fl[k].t,
                            d,
                        ) {
                            return false;
                        }
                    }
                }
                if !hit {
                    return self.fail("static-field");
                }
            }
            return true;
        }
        if n.kind != NodeKind::NODE_LITERAL {
            return self.fail("static-element");
        }
        let tk = n.as_data.literal.token_type;
        if tk == tt::TokenType::StringLiteral || tk == tt::TokenType::ByteStringLiteral || tk == tt::TokenType::MatchertextLiteral {
            if ti.size != 2 * self.pkg.ptr_bytes {
                return self.fail("static-string");
            }
            let rsp = n.as_data.literal.raw;
            let src = Lower::p(c).modules.at(cm as usize).source.as_str();
            let mut tmp = String::new();
            let mut bytes = String::new();
            cbe::str_const_bytes(src.slice(rsp.start as usize, rsp.end as usize), tk as i64, &mut tmp, &mut bytes);
            let len = bytes.len() as u64;
            let s = self.rodata(&mut bytes);
            d.relocs.push(Reloc { offset: off, sym: s, addend: 0 });
            put_le(&mut d.bytes, off + self.pkg.ptr_bytes, len, self.pkg.ptr_bytes);
            return true;
        }
        if tk == tt::TokenType::Null {
            return true;
        }
        let v = cev.eval(cm, eid);
        if ti.cls != VC_SCALAR {
            return self.fail("static-literal");
        }
        let bits = if v.kind == iri::IV_FLOAT && ti.mty == T_F32 {
            fl::f32_bits(v.f as f32) as u64;
        } else if v.kind == iri::IV_FLOAT {
            fl::f64_bits(v.f);
        } else if v.kind == iri::IV_INT || v.kind == iri::IV_BOOL {
            v.i as u64;
        } else {
            return self.fail("static-literal");
        };
        put_le(&mut d.bytes, off, bits, ti.size);
        return true;
    }
}

extend Lower {
    fn push_binds(self: &Self, c: &mut cbe::CEmit) {
        for k in 0..self.binds.len() {
            c.mg.push_msub(self.binds[k]);
        }
    }

    // `binds`: the bindings of the instance generic call `t` calls (`CEmit::callee_binds`) past the
    // active ones; empty for a concrete callee.
    fn bind_callee(self: &mut Self, c: &mut cbe::CEmit, b: &irc::CoreBody, t: &irc::Terminator) {
        self.binds.clear();
        let cl = t.callee;
        if cl.node == NODE_NONE {
            return;
        }
        let fd = Lower::ast(c, cl.module).at_const(cl.node);
        if fd.kind != NodeKind::NODE_FUNCTION || Lower::ast(c, cl.module).ext(cl.node).function.generics.len == 0 && !c.mg.in_generic_extend(
            cl.module,
            cl.node,
        ) && !c.mg.in_keyed_extend(cl.module, cl.node) {
            return;
        }
        c.callee_binds(b, t, &mut self.binds);
        let base = c.mg.subs.len();
        // Keep the callee's own: the active ones lead the copy.
        let mut k: usize = 0;
        while base + k < self.binds.len() {
            self.binds[k] = self.binds[base + k];
            k += 1;
        }
        self.binds.truncate(k);
    }
}

// ---- Tidying ----

// The scratch of `Lower::tidy`, kept across bodies.
struct Tidy {
    pub(package) bmap: Vector<u32>, // a block's new index; NONE when unreached
    pub(package) fwd: Vector<u32>, // the edge a block's lone live `jmp` takes (NONE for any other), then its predecessor count, then the block merged after it
    pub(package) jp: Vector<u32>, // the predecessor a block merges into; NONE when it stays
    pub(package) psub: Vector<Value>, // a merged block's parameter: the value its predecessor passes; VNONE for others
    pub(package) puse: Vector<u32>, // the live uses of each parameter
    pub(package) hoisted: Vector<bool>, // a live constant, defined once at the entry
    pub(package) consts: Vector<u32>, // the constants the entry defines, by instruction
    pub(package) ckey: Map<u64, u32>, // a constant's key: its first instruction
    pub(package) imap: Vector<u32>, // an instruction's new index; NONE when dropped
    pub(package) pmap: Vector<u32>, // a parameter's new index
    pub(package) work: Vector<u32>,
    pub(package) uses: Vector<Value>,
    pub(package) done: Vector<bool>, // a pool edge already renumbered
    pub(package) insts: Vector<Inst>,
    pub(package) locs: Vector<u32>,
    pub(package) params: Vector<u8>,
    pub(package) blocks: Vector<Block>,
    // Slot forwarding (`forward_slots`).
    pub(package) kill: Vector<bool>, // a copy forwarding dropped
    pub(package) smap: Vector<u32>, // an instruction's slot when it is a `slotaddr`, else NONE; then a slot's new index
    pub(package) srep: Vector<u32>, // the slot a slot became (itself when it stays)
    pub(package) snuse: Vector<u32>, // a slot's uses
    pub(package) sseen: Vector<u32>, // its uses before the instruction at hand
    pub(package) sblk: Vector<u32>, // the block of all its uses; NONE before the first, MULTI for several
    pub(package) sfirst: Vector<u32>, // its first use
    pub(package) slast: Vector<u32>, // its last use so far, and that use's block
    pub(package) slastb: Vector<u32>,
    pub(package) sesc: Vector<bool>, // its address goes beyond a load, a store, a copy or a fill of it
}

extend Tidy {
    fn new() Tidy {
        return Tidy {
            bmap: Vector::<u32>::new(),
            fwd: Vector::<u32>::new(),
            jp: Vector::<u32>::new(),
            psub: Vector::<Value>::new(),
            puse: Vector::<u32>::new(),
            hoisted: Vector::<bool>::new(),
            consts: Vector::<u32>::new(),
            ckey: Map::<u64, u32>::new(),
            imap: Vector::<u32>::new(),
            pmap: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
            uses: Vector::<Value>::new(),
            done: Vector::<bool>::new(),
            insts: Vector::<Inst>::new(),
            locs: Vector::<u32>::new(),
            params: Vector::<u8>::new(),
            blocks: Vector::<Block>::new(),
            kill: Vector::<bool>::new(),
            smap: Vector::<u32>::new(),
            srep: Vector::<u32>::new(),
            snuse: Vector::<u32>::new(),
            sseen: Vector::<u32>::new(),
            sblk: Vector::<u32>::new(),
            sfirst: Vector::<u32>::new(),
            slast: Vector::<u32>::new(),
            slastb: Vector::<u32>::new(),
            sesc: Vector::<bool>::new(),
        };
    }
}

const MULTI: u32 = 0xFFFFFFFE;

// Whether value `u`, a slot's address, is only the address instruction `t` reads or writes through:
// a load's or a store's address, a copy's destination or source, a fill's destination.
const fn slot_access(t: Inst, u: Value) bool {
    if t.op == O_LOAD {
        return true;
    }
    if t.op == O_STORE || t.op == O_MEMSET {
        return t.a == u && t.b != u && t.c != u;
    }
    return t.op == O_MEMCPY && t.c != u;
}

// The signature code of scalar machine type `t`: an `i8` or `i16` of a signed type with SIG_SEXT.
const fn sig_code(t: u8, signed: bool) u32 {
    return t as u32 | ast::pick(signed && (t == T_I8 || t == T_I16), SIG_SEXT, 0);
}

// Whether instruction `t` has no effect but its value: dropped when nothing uses it.
const fn pure_inst(t: Inst) bool {
    let op = t.op;
    return op >= O_ICONST && op <= O_MUL || op >= O_AND && op <= O_INTTOPTR || op == O_PTRADD || op == O_SELECT || op == O_RETADDR || op == O_LOAD && (t.aux & MEM_VOLATILE) == 0;
}

// The values instruction `t` of `b` uses into `out`: its operands, a call's arguments, a vector
// operation's operands and each edge's arguments.
fn inst_uses(b: &Body, t: Inst, out: &mut Vector<Value>) {
    out.truncate(0);
    let f = op_info(t.op).form;
    if lv::operand_a(f) && t.a != VNONE {
        out.push(t.a);
    }
    if lv::operand_b(f) && t.b != VNONE {
        out.push(t.b);
    }
    if lv::operand_c(f) && t.c != VNONE {
        out.push(t.c);
    }
    if f == F_CALL || f == F_CALLIND {
        for k in 0..t.aux as u32 {
            out.push(b.pool[(t.c + k) as usize]);
        }
    } else if f == F_VOP || f == F_ASM {
        for k in 0..t.b {
            out.push(b.pool[(t.a + k) as usize]);
        }
    }
    for k in 0..term_edges(t) {
        let e = term_edge(b, t, k);
        for x in 0..b.edge_nargs(e) {
            out.push(b.edge_arg(e, x));
        }
    }
}

// The number of edges terminator `t` takes (0 for any other instruction).
const fn term_edges(t: Inst) u32 {
    if t.op == O_JMP {
        return 1;
    }
    if t.op == O_BR {
        return 2;
    }
    if t.op == O_SWITCH {
        return t.aux as u32 + 1;
    }
    return 0;
}

// Edge `k` of terminator `t` of `b`.
const fn term_edge(b: &Body, t: Inst, k: u32) u32 {
    if t.op == O_JMP {
        return t.a;
    }
    if t.op == O_BR {
        return ast::pick(k == 0, t.b, t.c);
    }
    return b.switch_edge(t, k);
}

extend Lower {
    // Compact the finished body: drop the pure instructions nothing uses, send each edge to a block
    // that only jumps on to that jump's target, drop the blocks the entry no longer reaches, and
    // renumber what is left in block order. Every step is linear in the body.
    // The tidy body, then slot forwarding over its merged blocks, which a second pass applies.
    fn tidy(self: &mut Self) {
        fill_bool(&mut self.td.kill, self.b.insts.len(), false);
        self.tidy_pass();
        if self.forward_slots() {
            self.tidy_pass();
        }
        self.drop_unused_slots();
    }

    fn tidy_pass(self: &mut Self) {
        let nb = self.b.blocks.len();
        let ni = self.b.insts.len();
        self.fold_conversions();
        self.tidy_reach();
        // Liveness: the instructions with an effect in a reached block, then what they use.
        fill_u32(&mut self.td.imap, ni, NONE);
        self.td.work.truncate(0);
        for k in 0..nb {
            if self.td.bmap[k] == NONE {
                continue;
            }
            let bk = self.b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                if !pure_inst(self.b.insts[i as usize]) && !self.td.kill[i as usize] {
                    self.td.imap[i as usize] = 0;
                    self.td.work.push(i);
                }
            }
        }
        fill_u32(&mut self.td.puse, self.b.params.len(), 0);
        while self.td.work.len() != 0 {
            let i = self.td.work.pop().unwrap();
            inst_uses(&self.b, self.b.insts[i as usize], &mut self.td.uses);
            for u in 0..self.td.uses.len() {
                let v = self.td.uses[u];
                let d = v & ~VFLAG;
                if (v & VPARAM) != 0 {
                    self.td.puse[(v & ~VPARAM) as usize] += 1;
                } else if self.td.imap[d as usize] == NONE {
                    self.td.imap[d as usize] = 0;
                    self.td.work.push(d);
                }
            }
        }
        // Threading: a reached block whose one live instruction is a `jmp` forwards: one of no
        // parameter, or one that passes its parameters on in order.
        fill_u32(&mut self.td.fwd, nb, NONE);
        let mut any = false;
        for k in 1..nb {
            let bk = self.b.blocks[k];
            if self.td.bmap[k] == NONE {
                continue;
            }
            let end = bk.start + bk.len - 1;
            let j = self.b.insts[end as usize];
            let mut only = j.op == O_JMP && (bk.param_len == 0 || self.b.edge_nargs(j.a) == bk.param_len as u32);
            // Each parameter is used by the `jmp` alone: the edges that bypass the block pass it on.
            for q in 0..bk.param_len as u32 {
                only = only && self.b.edge_arg(j.a, q) == (VPARAM | bk.param_start + q) && self.td.puse[(bk.param_start + q) as usize] == 1;
            }
            let mut i = bk.start;
            while only && i < end {
                only = self.td.imap[i as usize] == NONE;
                i += 1;
            }
            if only {
                self.td.fwd[k] = self.b.insts[end as usize].a;
                any = true;
            }
        }
        if any {
            for k in 0..nb {
                if self.td.bmap[k] == NONE {
                    continue;
                }
                let bk = self.b.blocks[k];
                let ti = (bk.start + bk.len - 1) as usize;
                let t = self.b.insts[ti];
                if t.op == O_JMP {
                    self.b.insts.index_mut(ti).a = self.thread(t.a, nb);
                } else if t.op == O_BR {
                    let e1 = self.thread(t.b, nb);
                    let e2 = self.thread(t.c, nb);
                    self.b.insts.index_mut(ti).b = e1;
                    self.b.insts.index_mut(ti).c = e2;
                } else if t.op == O_SWITCH {
                    for q in 0..t.aux as u32 + 1 {
                        let e = self.thread(self.b.switch_edge(t, q), nb);
                        self.b.pool[(t.c + q) as usize] = e;
                    }
                }
            }
            self.tidy_reach();
        }
        // Merging: a block of no parameter whose one predecessor `jmp`s to it continues that block.
        let _ = self.tidy_merges();
        // Renumber: the constants, one of each, first; then the blocks left (a run of merged blocks
        // as one), their parameters and live instructions in block order.
        let mut n = self.hoist_constants();
        let mut np: u32 = 0;
        fill_u32(&mut self.td.pmap, self.b.params.len(), NONE);
        for k in 0..nb {
            if self.td.bmap[k] == NONE {
                continue;
            }
            let bk = self.b.blocks[k];
            for q in 0..bk.param_len as u32 {
                self.td.pmap[(bk.param_start + q) as usize] = np;
                np += 1;
            }
            let mut cur = k as u32;
            for _ in 0..nb {
                let nx = self.td.fwd[cur as usize];
                let ck = self.b.blocks[cur as usize];
                for i in ck.start..ck.start + ck.len - ast::pick(nx != NONE, 1u32, 0) {
                    if self.td.imap[i as usize] != NONE && !self.td.hoisted[i as usize] {
                        self.td.imap[i as usize] = n;
                        n += 1;
                    }
                }
                if nx == NONE {
                    break;
                }
                cur = nx;
            }
        }
        self.td.insts.truncate(0);
        self.td.locs.truncate(0);
        self.td.params.truncate(0);
        self.td.blocks.truncate(0);
        fill_bool(&mut self.td.done, self.b.pool.len(), false);
        for k in 0..nb {
            if self.td.bmap[k] == NONE {
                continue;
            }
            let bk = self.b.blocks[k];
            let start = self.td.insts.len() as u32;
            let ps = self.td.params.len() as u32;
            for q in 0..bk.param_len as u32 {
                self.td.params.push(self.b.params[(bk.param_start + q) as usize]);
            }
            if k == 0 {
                for q in 0..self.td.consts.len() {
                    self.td.insts.push(self.b.insts[self.td.consts[q] as usize]);
                    self.td.locs.push(0);
                }
            }
            let mut cur = k as u32;
            for _ in 0..nb {
                let nx = self.td.fwd[cur as usize];
                let ck = self.b.blocks[cur as usize];
                for i in ck.start..ck.start + ck.len - ast::pick(nx != NONE, 1u32, 0) {
                    if self.td.imap[i as usize] != NONE && !self.td.hoisted[i as usize] {
                        let t = self.renumber(self.b.insts[i as usize]);
                        self.td.insts.push(t);
                        self.td.locs.push(self.b.locs[i as usize]);
                    }
                }
                if nx == NONE {
                    break;
                }
                cur = nx;
            }
            self.td.blocks.push(
                Block {
                    start: start,
                    len: self.td.insts.len() as u32 - start,
                    param_start: ast::pick(bk.param_len == 0, 0u32, ps),
                    param_len: bk.param_len,
                    flags: bk.flags,
                },
            );
        }
        self.td.insts = replace(&mut self.b.insts, replace(&mut self.td.insts, Vector::<Inst>::new()));
        self.td.locs = replace(&mut self.b.locs, replace(&mut self.td.locs, Vector::<u32>::new()));
        self.td.params = replace(&mut self.b.params, replace(&mut self.td.params, Vector::<u8>::new()));
        self.td.blocks = replace(&mut self.b.blocks, replace(&mut self.td.blocks, Vector::<Block>::new()));
        self.td.blocks.truncate(0);
    }

    // Copy forwarding: a slot S whose uses are all in one block, each a load, a store, a copy or a fill
    // through its address, and whose last use copies it whole into slot D, becomes D, and the copy goes,
    // when nothing uses D between S's first use and the copy and, when D's address goes further,
    // nothing there reads or writes memory through another address. A value built in temporaries and
    // moved into its variable then fills the variable's slot alone. Whether a copy went.
    fn forward_slots(self: &mut Self) bool {
        let ni = self.b.insts.len();
        let ns = self.b.slots.len();
        fill_bool(&mut self.td.kill, ni, false);
        if ns < 2 {
            return false;
        }
        fill_u32(&mut self.td.smap, ni, NONE);
        for i in 0..ni {
            if self.b.insts[i].op == O_SLOTADDR {
                self.td.smap[i] = self.b.insts[i].a;
            }
        }
        fill_u32(&mut self.td.snuse, ns, 0);
        fill_u32(&mut self.td.sblk, ns, NONE);
        fill_bool(&mut self.td.sesc, ns, false);
        // A tidy pass ran: every block is reached.
        let nb = self.b.blocks.len();
        for k in 0..nb {
            let bk = self.b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = self.b.insts[i as usize];
                inst_uses(&self.b, t, &mut self.td.uses);
                for q in 0..self.td.uses.len() {
                    let u = self.td.uses[q];
                    if !self.is_slot_addr(u) {
                        continue;
                    }
                    let sl = self.td.smap[u as usize] as usize;
                    self.td.snuse[sl] += 1;
                    self.td.sblk[sl] = ast::pick(
                        self.td.sblk[sl] == NONE || self.td.sblk[sl] == k as u32,
                        k as u32,
                        MULTI,
                    );
                    if !slot_access(t, u) {
                        self.td.sesc[sl] = true;
                    }
                }
            }
        }
        fill_u32(&mut self.td.srep, ns, 0);
        for sl in 0..ns {
            self.td.srep[sl] = sl as u32;
        }
        fill_u32(&mut self.td.sseen, ns, 0);
        fill_u32(&mut self.td.sfirst, ns, NONE);
        fill_u32(&mut self.td.slast, ns, NONE);
        fill_u32(&mut self.td.slastb, ns, NONE);
        let mut any = false;
        for k in 0..nb {
            let bk = self.b.blocks[k];
            // The last instruction of the block that may reach memory through an unknown address.
            let mut opaque = NONE;
            for i in bk.start..bk.start + bk.len {
                let t = self.b.insts[i as usize];
                if t.op == O_MEMCPY && self.forward_copy(t, i, k as u32, opaque) {
                    any = true;
                    continue;
                }
                inst_uses(&self.b, t, &mut self.td.uses);
                for q in 0..self.td.uses.len() {
                    let u = self.td.uses[q];
                    if !self.is_slot_addr(u) {
                        continue;
                    }
                    let sl = self.slot_rep(self.td.smap[u as usize]) as usize;
                    self.td.sseen[sl] += 1;
                    if self.td.sfirst[sl] == NONE {
                        self.td.sfirst[sl] = i;
                    }
                    self.td.slast[sl] = i;
                    self.td.slastb[sl] = k as u32;
                }
                let mem = t.op == O_LOAD || t.op == O_STORE || t.op == O_MEMSET || t.op == O_MEMCPY;
                let through_slots = mem && self.is_slot_addr(t.a) && (t.op != O_MEMCPY || self.is_slot_addr(t.b));
                if mem && !through_slots || !mem && !pure_inst(t) {
                    opaque = i;
                }
            }
        }
        if !any {
            return false;
        }
        for i in 0..ni {
            if self.b.insts[i].op == O_SLOTADDR {
                let r = self.slot_rep(self.b.insts[i].a);
                self.b.insts.index_mut(i).a = r;
            }
        }
        return true;
    }

    // `forward_copy` of copy `t`, instruction `i` of block `k`, whose last instruction that may reach
    // memory through an unknown address is `opaque`: whether it forwarded the source slot into the
    // destination slot and dropped the copy.
    fn forward_copy(self: &mut Self, t: Inst, i: u32, k: u32, opaque: u32) bool {
        if !self.is_slot_addr(t.a) || !self.is_slot_addr(t.b) || (t.c & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let ct = self.b.insts[t.c as usize];
        if ct.op != O_ICONST {
            return false;
        }
        let n = ct.a as u64 | ct.b as u64 << 32;
        let d = self.slot_rep(self.td.smap[t.a as usize]) as usize;
        let sl = self.slot_rep(self.td.smap[t.b as usize]) as usize;
        let first = ast::pick(self.td.sfirst[sl] == NONE, i, self.td.sfirst[sl]);
        let ok = sl != d && !self.td.sesc[sl] && self.td.sblk[sl] == k && self.td.sseen[sl] + 1 == self.td.snuse[sl] && self.b.slots[sl].size as u64 == n && self.b.slots[d].size as u64 == n && !(self.td.slastb[d] == k && self.td.slast[d] >= first) && (!self.td.sesc[d] || opaque == NONE || opaque < first);
        if !ok {
            return false;
        }
        self.td.kill[i as usize] = true;
        self.td.srep[sl] = d as u32;
        self.td.snuse[d] = self.td.snuse[d] + self.td.snuse[sl] - 2;
        self.td.sseen[d] = self.td.sseen[d] + self.td.sseen[sl];
        self.td.sblk[d] = ast::pick(self.td.sblk[d] == NONE || self.td.sblk[d] == k, k, MULTI);
        if self.td.sfirst[d] == NONE || self.td.sfirst[sl] < self.td.sfirst[d] {
            self.td.sfirst[d] = self.td.sfirst[sl];
        }
        if self.td.slast[sl] != NONE {
            self.td.slast[d] = self.td.slast[sl];
            self.td.slastb[d] = k;
        }
        let al = self.b.slots[sl].align_log2;
        if al > self.b.slots[d].align_log2 {
            self.b.slots.index_mut(d).align_log2 = al;
        }
        return true;
    }

    // Whether value `v` is a slot's address (`forward_slots`).
    const fn is_slot_addr(self: &Self, v: Value) bool {
        return (v & (VPARAM | VFLAG)) == 0 && self.td.smap[v as usize] != NONE;
    }

    // The slot slot `s` became (`forward_slots`).
    const fn slot_rep(self: &Self, s: u32) u32 {
        let mut r = s;
        for _ in 0..self.td.srep.len() {
            if self.td.srep[r as usize] == r {
                return r;
            }
            r = self.td.srep[r as usize];
        }
        panic("a slot forwarding chain is acyclic");
    }

    // Drop the slots no instruction takes the address of, and renumber the others in order.
    fn drop_unused_slots(self: &mut Self) {
        let ns = self.b.slots.len();
        fill_u32(&mut self.td.smap, ns, NONE);
        for i in 0..self.b.insts.len() {
            if self.b.insts[i].op == O_SLOTADDR {
                self.td.smap[self.b.insts[i].a as usize] = 0;
            }
        }
        let mut n: u32 = 0;
        for sl in 0..ns {
            if self.td.smap[sl] != NONE {
                self.td.smap[sl] = n;
                self.b.slots.set(n as usize, self.b.slots[sl]);
                n += 1;
            }
        }
        if n as usize == ns {
            return;
        }
        self.b.slots.truncate(n as usize);
        for i in 0..self.b.insts.len() {
            if self.b.insts[i].op == O_SLOTADDR {
                let to = self.td.smap[self.b.insts[i].a as usize];
                self.b.insts.index_mut(i).a = to;
            }
        }
    }

    // `jp`: for each reached block of no parameter, but the entry, whose one predecessor reaches it
    // by a `jmp` and has its flags, that predecessor; NONE for the others, which `bmap` renumbers.
    // `fwd`: the block merged after each block; NONE when none is. The number of merged blocks.
    fn tidy_merges(self: &mut Self) u32 {
        let nb = self.b.blocks.len();
        fill_u32(&mut self.td.fwd, nb, 0);
        fill_u32(&mut self.td.jp, nb, NONE);
        for k in 0..nb {
            if self.td.bmap[k] == NONE {
                continue;
            }
            let bk = self.b.blocks[k];
            let t = self.b.insts[(bk.start + bk.len - 1) as usize];
            for q in 0..term_edges(t) {
                let to = self.b.edge_target(term_edge(&self.b, t, q)) as usize;
                self.td.fwd[to] += 1;
                if t.op == O_JMP {
                    self.td.jp[to] = k as u32;
                }
            }
        }
        let mut m: u32 = 0;
        self.td.jp[0] = NONE;
        for k in 1..nb {
            let bk = self.b.blocks[k];
            let p = self.td.jp[k];
            if p == NONE || self.td.fwd[k] != 1 || self.b.blocks[p as usize].flags != bk.flags {
                self.td.jp[k] = NONE;
            } else {
                m += 1;
            }
        }
        fill_u32(&mut self.td.psub, self.b.params.len(), VNONE);
        if m == 0 {
            fill_u32(&mut self.td.fwd, nb, NONE);
            return 0;
        }
        // A merged block's parameters are the values its predecessor's `jmp` passes.
        for k in 1..nb {
            let p = self.td.jp[k];
            let bk = self.b.blocks[k];
            if p == NONE || bk.param_len == 0 {
                continue;
            }
            let pb = self.b.blocks[p as usize];
            let e = self.b.insts[(pb.start + pb.len - 1) as usize].a;
            for q in 0..bk.param_len as u32 {
                self.td.psub[(bk.param_start + q) as usize] = self.b.edge_arg(e, q);
            }
        }
        // `fwd`: the block merged after each, read before renumbering rewrites the edges.
        for k in 0..nb {
            self.td.fwd[k] = if self.td.bmap[k] != NONE || self.td.jp[k] != NONE {
                self.chain_next(k as u32);
            } else {
                NONE;
            };
        }
        let mut n: u32 = 0;
        for k in 0..nb {
            if self.td.bmap[k] != NONE && self.td.jp[k] == NONE {
                self.td.bmap[k] = n;
                n += 1;
            } else {
                self.td.bmap[k] = NONE;
            }
        }
        return m;
    }

    // The block merged after block `k` (its `jmp`'s target); NONE when none is.
    const fn chain_next(self: &Self, k: u32) u32 {
        let bk = self.b.blocks[k as usize];
        let t = self.b.insts[(bk.start + bk.len - 1) as usize];
        if t.op != O_JMP {
            return NONE;
        }
        let to = self.b.edge_target(t.a);
        return ast::pick(self.td.jp[to as usize] != NONE, to, NONE);
    }

    // Number the live constants of the reached blocks from 0, one per value (an operation, a type
    // and an immediate): `consts` lists the first of each, `hoisted` marks them all, and `imap`
    // sends each to its first. The entry defines them: it dominates every use. The count.
    fn hoist_constants(self: &mut Self) u32 {
        let nb = self.b.blocks.len();
        fill_bool(&mut self.td.hoisted, self.b.insts.len(), false);
        self.td.consts.truncate(0);
        self.td.ckey.clear();
        for k in 0..nb {
            if self.td.bmap[k] == NONE && self.td.jp[k] == NONE {
                continue;
            }
            let bk = self.b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = self.b.insts[i as usize];
                if self.td.imap[i as usize] == NONE || t.op != O_ICONST && t.op != O_FCONST && t.op != O_SYMADDR && t.op != O_SLOTADDR {
                    continue;
                }
                // A thread-local variable's address is the running thread's: computed where it is read.
                if t.op == O_SYMADDR && self.pkg.syms[self.b.syms[t.a as usize] as usize].kind == SK_TLS {
                    continue;
                }
                self.td.hoisted[i as usize] = true;
                let key = (t.op as u64 << 56 | t.ty as u64 << 48 | t.b as u64).wrapping_mul(0x9E3779B97F4A7C15u64) ^ t.a as u64;
                let mut at = NONE;
                if let Some(f) = self.td.ckey.get(&key) {
                    let r = self.b.insts[(*f) as usize];
                    if r.op == t.op && r.ty == t.ty && r.aux == t.aux && r.a == t.a && r.b == t.b {
                        at = *f;
                    }
                }
                if at != NONE {
                    self.td.imap[i as usize] = self.td.imap[at as usize];
                    continue;
                }
                if !self.td.ckey.contains_key(&key) {
                    self.td.ckey.insert(key, i);
                }
                self.td.imap[i as usize] = self.td.consts.len() as u32;
                self.td.consts.push(i);
            }
        }
        return self.td.consts.len() as u32;
    }

    // Rewrite each integer conversion of an integer constant to the constant it makes.
    fn fold_conversions(self: &mut Self) {
        let ptr = self.pkg.ptr_bytes;
        for i in 0..self.b.insts.len() {
            let t = self.b.insts[i];
            if t.op != O_SEXT && t.op != O_ZEXT && t.op != O_TRUNC || (t.a & (VPARAM | VFLAG)) != 0 || !is_int(t.ty) || t.ty == T_I128 {
                continue;
            }
            let x = self.b.insts[t.a as usize];
            if x.op != O_ICONST || x.ty == T_I128 {
                continue;
            }
            let v = x.b as u64 << 32 | x.a as u64;
            let u = if t.op == O_SEXT {
                lp::sign_extend(v, type_bits(x.ty, ptr)) as u64;
            } else {
                v;
            };
            let tb = type_bits(t.ty, ptr);
            let r = if tb >= 64 {
                u;
            } else {
                u & (1u64 << tb as u64) - 1;
            };
            let ins = self.b.insts.index_mut(i);
            ins.op = O_ICONST;
            ins.aux = 0;
            ins.a = r as u32;
            ins.b = (r >> 32) as u32;
            ins.c = VNONE;
        }
    }

    // `bmap`: each block the entry reaches, numbered in block order; NONE for the others.
    fn tidy_reach(self: &mut Self) {
        let nb = self.b.blocks.len();
        fill_u32(&mut self.td.bmap, nb, NONE);
        self.td.work.truncate(0);
        self.td.bmap[0] = 0;
        self.td.work.push(0);
        // Each block enters the stack once.
        while self.td.work.len() != 0 {
            let k = self.td.work.pop().unwrap();
            let bk = self.b.blocks[k as usize];
            let t = self.b.insts[(bk.start + bk.len - 1) as usize];
            for q in 0..term_edges(t) {
                let to = self.b.edge_target(term_edge(&self.b, t, q));
                if self.td.bmap[to as usize] == NONE {
                    self.td.bmap[to as usize] = 0;
                    self.td.work.push(to);
                }
            }
        }
        let mut n: u32 = 0;
        for k in 0..nb {
            if self.td.bmap[k] != NONE {
                self.td.bmap[k] = n;
                n += 1;
            }
        }
    }

    // Edge `e` past the blocks that only jump: a block of no parameter by its `jmp`'s edge, one that
    // passes its parameters on by retargeting `e` (every edge to it passes them alike). At most `nb`
    // steps, so a loop of such blocks stops.
    const fn thread(self: &mut Self, e: u32, nb: usize) u32 {
        let mut x = e;
        for _ in 0..nb {
            let t = self.b.edge_target(x) as usize;
            let f = self.td.fwd[t];
            if f == NONE || f == x {
                break;
            }
            if self.b.blocks[t].param_len == 0 {
                x = f;
            } else {
                self.b.pool[x as usize] = self.b.edge_target(f);
            }
        }
        return x;
    }

    // Value `v` renumbered (a merged block's parameter as the value its predecessor passes).
    const fn renum(self: &Self, v0: Value) Value {
        let mut v = v0;
        for _ in 0..self.td.psub.len() {
            if v == VNONE || (v & VPARAM) == 0 || self.td.psub[(v & ~VPARAM) as usize] == VNONE {
                break;
            }
            v = self.td.psub[(v & ~VPARAM) as usize];
        }
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            return VPARAM | self.td.pmap[(v & ~VPARAM) as usize];
        }
        return v & VFLAG | self.td.imap[(v & ~VFLAG) as usize];
    }

    // Instruction `t` with its values, edges and their arguments renumbered (a pool list in place;
    // an edge two terminators share, once).
    const fn renumber(self: &mut Self, t0: Inst) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.renum(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.renum(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.renum(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            for k in 0..t.aux as u32 {
                let at = (t.c + k) as usize;
                self.b.pool[at] = self.renum(self.b.pool[at]);
            }
        } else if f == F_VOP || f == F_ASM {
            for k in 0..t.b {
                let at = (t.a + k) as usize;
                self.b.pool[at] = self.renum(self.b.pool[at]);
            }
        }
        for k in 0..term_edges(t) {
            let e = term_edge(&self.b, t, k);
            if self.td.done[e as usize] {
                continue;
            }
            self.td.done[e as usize] = true;
            self.b.pool[e as usize] = self.td.bmap[self.b.pool[e as usize] as usize];
            for x in 0..self.b.edge_nargs(e) {
                let at = (e + 2 + x) as usize;
                self.b.pool[at] = self.renum(self.b.pool[at]);
            }
        }
        return t;
    }
}

// `v` as `n` copies of `x`, its buffer reused.
fn fill_u32(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

fn fill_bool(v: &mut Vector<bool>, n: usize, x: bool) {
    v.truncate(0);
    v.resize_default(n);
    if x != false {
        v.as_mut_slice().fill(x);
    }
}

extend Lower {
    /// Lower derived destructor `sym` of resolved type `(rm, rt)`, under the bindings its use recorded:
    /// `void sym(T *self)` frees each destructible member in order, an enum's under its variant's tag
    /// and a closure env's owned captures. A refusal goes to `fails`.
    /// The destructor `sym` of a type `rt` of module `rm`: with `fb` empty the derived one, which frees
    /// every member; else a user `free`'s wrapper, which calls the user body `fb` and then frees the
    /// members `fields` (their declarations) that body leaves.
    pub(package) fn glue(
        self: &mut Self,
        c: &mut cbe::CEmit,
        rm: ModuleId,
        rt: TypeId,
        sym: str,
        fb: str,
        fields: []NodeId,
    ) bool {
        let s0 = self.pkg.find_symbol(sym);
        if s0 != NONE && self.pkg.syms[s0 as usize].def != NONE {
            return true;
        }
        let (cd, ro) = self.synth_begin(c, rm);
        let ok = self.glue_i(c, rm, rt, fb, fields);
        return self.synth_end(c, cd, ro, sym, ok);
    }

    // Begin a body the lowering makes without Core IR, in module `m`: the emitter's demand collection and
    // recording pause (their settings returned).
    fn synth_begin(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId) (bool, bool) {
        self.nbodies += 1;
        let cd = c.collect_demand;
        let ro = c.mg.rec_on;
        c.collect_demand = false;
        c.mg.rec_on = false;
        self.err = "";
        self.reset(m);
        self.bm = m;
        self.noret = false;
        self.file = self.pkg.add_file(Lower::p(c).modules.at(m as usize).file.as_str());
        return cd, ro;
    }

    // End the body `synth_begin` began: when `ok`, finished as function `sym`; else a refusal.
    fn synth_end(self: &mut Self, c: &mut cbe::CEmit, cd: bool, ro: bool, sym: str, ok: bool) bool {
        let done = ok && self.finish(sym);
        c.collect_demand = cd;
        c.mg.rec_on = ro;
        if !done {
            self.fails.push(LFail { sym: String::from_str(sym), why: self.err });
            return false;
        }
        self.tidy();
        let s = self.pkg.symbol(sym, SK_FUNC);
        let _ = self.pkg.define(s, &self.b);
        self.pend.push(s);
        return true;
    }

    /// The test wrapper `__sc_test_w_<tm>_<func>(genv)` (`CEmit::emit_test_wrapper`): with `wants` bit 0 a
    /// fixture from `fx_init`, then the call of test `func` with the fixture's address and (bit 1) the
    /// global env, then the fixture's teardown `fx_free` (NODE_NONE: none) and its destructor.
    pub(package) fn test_wrapper(
        self: &mut Self,
        c: &mut cbe::CEmit,
        tm: ModuleId,
        func: NodeId,
        wants: u8,
        fx_init: NodeId,
        fx_free: NodeId,
    ) bool {
        let mut name = String::new();
        name.format_into("__sc_test_w_{}_{}", tm, func);
        if self.pkg.find_symbol(name.as_str()) != NONE && self.pkg.syms[self.pkg.find_symbol(name.as_str()) as usize].def != NONE {
            return true;
        }
        let (cd, ro) = self.synth_begin(c, tm);
        let ok = self.test_wrapper_i(c, tm, func, wants, fx_init, fx_free);
        return self.synth_end(c, cd, ro, name.as_str(), ok);
    }

    fn test_wrapper_i(
        self: &mut Self,
        c: &mut cbe::CEmit,
        tm: ModuleId,
        func: NodeId,
        wants: u8,
        fx_init: NodeId,
        fx_free: NodeId,
    ) bool {
        let pt: []u32 = [T_PTR as u32];
        self.b.sig = self.b.signature(pt, 1, false, T_NONE);
        let pb: []u8 = [T_PTR];
        let b0 = self.b.add_block(pb);
        self.b.begin(b0);
        let genv = self.b.param(b0, 0);
        let mut fx = VNONE;
        let mut fxt = TYPE_NONE;
        if (wants & 1) != 0 {
            fxt = c.fn_ret_ty(tm, fx_init);
            if fxt == TYPE_NONE {
                return self.fail("test-fx");
            }
            fx = self.call_init(c, tm, fx_init, fxt);
            if fx == VNONE {
                return false;
            }
        }
        let mut args = Vector::<Value>::new();
        if (wants & 1) != 0 {
            args.push(fx);
        }
        if (wants & 2) != 0 {
            args.push(genv);
        }
        if !self.call_fn(c, tm, func, args[0..args.len()]) {
            return false;
        }
        if (wants & 1) != 0 {
            if fx_free != NODE_NONE {
                let one: []Value = [fx];
                if !self.call_fn(c, tm, fx_free, one) {
                    return false;
                }
            }
            if c.is_destructible(tm, fxt) && !self.drop_at(c, tm, fxt, fx, 0) {
                return false;
            }
        }
        let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
        return true;
    }

    // The value of init function `(m, f)` (no arguments, of result type `ty`) in memory: its address, the
    // sentinel for a zero-sized one; VNONE on a refusal.
    fn call_init(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, f: NodeId, ty: TypeId) Value {
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, m, ty, &mut ti) {
            return VNONE;
        }
        let mut s = String::new();
        if !c.mg.fn_sym(m, f, c.mg.method_target(m, f), &mut s) {
            return self.fail_v("test-sym");
        }
        let k = self.sym(s.as_str(), SK_FUNC);
        let none: []u32 = [];
        let nv: []Value = [];
        if ti.cls == VC_ZST {
            let sg = self.b.signature(none, 0, false, T_NONE);
            let at = self.b.pool_list(nv);
            let _ = self.inst(O_CALL, T_NONE, 0, k, sg, at);
            return self.sentinel(c, m, ty);
        }
        let slot = self.temp(ti);
        if ti.cls == VC_SCALAR {
            let sg = self.b.signature(none, 0, false, ti.mty);
            let at = self.b.pool_list(nv);
            let r = self.inst(O_CALL, ti.mty, 0, k, sg, at);
            self.store(r, slot, 0, false);
            return slot;
        }
        let lt = self.layout_of(c, m, ty, ti);
        let sg = self.b.signature(none, 0, false, AGG | lt);
        let one: [Value; 1] = [slot];
        let at = self.b.pool_list(one[0..1]);
        let _ = self.inst(O_CALL, T_NONE, 1, k, sg, at);
        return slot;
    }

    /// The wrapper `wn` of extern function `d` (C name `callee`) that C emits beside it
    /// (`CEmit::blk_wrapper_defs`): with `blocking` it moves the call to a blocking thread
    /// (`__sc_blocking_run` with `<wn>_run` and an env of the arguments and the result), else it calls
    /// `callee` itself. Both are module `d.module`'s. A parameter of array type (C copies it) is refused.
    pub(package) fn blk_wrapper(self: &mut Self, c: &mut cbe::CEmit, d: DefId, wn: str, callee: str, blocking: bool) bool {
        let s0 = self.pkg.find_symbol(wn);
        if s0 != NONE && self.pkg.syms[s0 as usize].def != NONE {
            return true;
        }
        let m = d.module;
        let a = Lower::ast(c, m);
        let f = a.ext(d.node).function;
        // The parameters' and the result's types, and the env's layout: each argument, then the result.
        let mut pts = Vector::<TypeId>::new();
        let mut tis = Vector::<TyI>::new();
        let mut offs = Vector::<u32>::new();
        let mut at: u32 = 0;
        let mut al: u32 = 1;
        let mut ok = true;
        for k in 0..f.params.len {
            let pid = unsafe a.list(f.params)[k as usize];
            let pt = a.type_of(a.at_const(pid).as_data.parameter.ty);
            let mut ti = TyI { cls: 0 };
            if Lower::is_array(c, m, pt) {
                // An array parameter is a pointer to the caller's array (`param_sig`).
                let pb = self.pkg.ptr_bytes;
                ti = TyI { cls: VC_SCALAR, mty: T_PTR, size: pb, align: pb };
            } else {
                ok = self.ty(c, m, pt, &mut ti);
            }
            if !ok {
                break;
            }
            at = round_up(at, ti.align);
            offs.push(at);
            at += ti.size;
            al = ast::pick(ti.align > al, ti.align, al);
            pts.push(pt);
            tis.push(ti);
        }
        let mut rt = TYPE_NONE;
        let mut ri = TyI { cls: VC_ZST, mty: T_NONE, size: 0, align: 1 };
        if ok && f.returns.len == 1 {
            rt = a.type_of(unsafe a.list(f.returns)[0]);
            ok = self.ty(c, m, rt, &mut ri);
        }
        if !ok {
            self.fails.push(LFail { sym: String::from_str(wn), why: "blocking-wrapper" });
            return false;
        }
        at = round_up(at, ri.align);
        let roff = at;
        at += ri.size;
        let env = TyI { cls: VC_MEM, mty: T_NONE, size: round_up(at, al), align: al };
        let mut run = String::from_str(wn);
        run.push_str("_run");
        let (cd, ro) = self.synth_begin(c, m);
        let ok1 = self.blk_outer(c, m, &pts, &tis, &offs, rt, ri, roff, env, run.as_str(), callee, blocking);
        if !self.synth_end(c, cd, ro, wn, ok1) {
            return false;
        }
        self.own_last(m);
        if !blocking {
            return true;
        }
        let (cd2, ro2) = self.synth_begin(c, m);
        let ok2 = self.blk_run(c, m, &pts, &tis, &offs, rt, ri, roff, callee);
        if !self.synth_end(c, cd2, ro2, run.as_str(), ok2) {
            return false;
        }
        self.own_last(m);
        return true;
    }

    // The function `synth_end` just defined is unit `m`'s, not the claim's next chunk's.
    fn own_last(self: &mut Self, m: ModuleId) {
        let s = self.pend.pop().unwrap();
        self.pkg.syms.index_mut(s as usize).unit = m;
    }

    // The signature types of parameters `(m, pts)` of classes `tis` (zero-sized ones take none) and of the
    // result `(m, rt)` of class `ri`: into `ptys`; the entry block's value types into `etys`.
    fn blk_sig(
        self: &mut Self,
        c: &mut cbe::CEmit,
        m: ModuleId,
        pts: &Vector<TypeId>,
        tis: &Vector<TyI>,
        rt: TypeId,
        ri: TyI,
        etys: &mut Vector<u8>,
    ) {
        let mut ptys = Vector::<u32>::new();
        for k in 0..pts.len() {
            let ti = tis[k];
            if ti.cls == VC_SCALAR {
                ptys.push(sig_code(ti.mty, Lower::signed(c, m, pts[k])));
                etys.push(ti.mty);
            } else if ti.cls == VC_MEM {
                ptys.push(self.param_sig(c, m, pts[k], ti));
                etys.push(T_PTR);
            }
        }
        let mut ret = T_NONE as u32;
        if ri.cls == VC_SCALAR {
            ret = sig_code(ri.mty, Lower::signed(c, m, rt));
        } else if ri.cls == VC_MEM {
            ret = AGG | self.layout_of(c, m, rt, ri);
            etys.push(T_PTR);
        }
        self.b.sig = self.b.signature(ptys[0..ptys.len()], ptys.len() as u32, false, ret);
    }

    // The wrapper itself: the arguments into the env, the run on a blocking thread, the result from it; or,
    // not `blocking`, the call of `callee` with the arguments.
    fn blk_outer(
        self: &mut Self,
        c: &mut cbe::CEmit,
        m: ModuleId,
        pts: &Vector<TypeId>,
        tis: &Vector<TyI>,
        offs: &Vector<u32>,
        rt: TypeId,
        ri: TyI,
        roff: u32,
        env: TyI,
        run: str,
        callee: str,
        blocking: bool,
    ) bool {
        let mut etys = Vector::<u8>::new();
        self.blk_sig(c, m, pts, tis, rt, ri, &mut etys);
        let sig = self.b.sig;
        let b0 = self.b.add_block(etys[0..etys.len()]);
        self.b.begin(b0);
        let mut ps = Vector::<Value>::new();
        for k in 0..etys.len() {
            ps.push(self.b.param(b0, k as u32));
        }
        let rmem = if ri.cls == VC_MEM {
            ps[ps.len() - 1];
        } else {
            VNONE;
        };
        if !blocking {
            let k = self.sym(callee, SK_FUNC);
            let at = self.b.pool_list(ps[0..ps.len()]);
            let r = self.inst(O_CALL, ast::pick(ri.cls == VC_SCALAR, ri.mty, T_NONE), ps.len() as u16, k, sig, at);
            let _ = self.inst(O_RET, T_NONE, 0, ast::pick(ri.cls == VC_SCALAR, r, VNONE), VNONE, VNONE);
            return true;
        }
        let e = self.temp(env);
        let mut q: usize = 0;
        for k in 0..pts.len() {
            let ti = tis[k];
            if ti.cls == VC_ZST {
                continue;
            }
            let fa = self.ptradd(e, VNONE, 0, offs[k]);
            if ti.cls == VC_SCALAR {
                self.store(ps[q], fa, 0, false);
            } else {
                self.memcpy(fa, ps[q], ti.size);
            }
            q += 1;
        }
        let kr = self.symaddr(run, SK_FUNC);
        let two: []u32 = [T_PTR as u32, T_PTR as u32];
        let rsig = self.b.signature(two, 2, false, T_NONE);
        let args: []Value = [kr, e];
        let at = self.b.pool_list(args);
        let kb = self.sym("__sc_blocking_run", SK_FUNC);
        let _ = self.inst(O_CALL, T_NONE, 2, kb, rsig, at);
        let ra = self.ptradd(e, VNONE, 0, roff);
        let mut r = VNONE;
        if ri.cls == VC_SCALAR {
            r = self.load(ri.mty, ra, 0, false);
        } else if ri.cls == VC_MEM {
            self.memcpy(rmem, ra, ri.size);
        }
        let _ = self.inst(O_RET, T_NONE, 0, r, VNONE, VNONE);
        return true;
    }

    // `<wn>_run(env)`: the call of `callee` with the env's arguments, its result into the env.
    fn blk_run(
        self: &mut Self,
        c: &mut cbe::CEmit,
        m: ModuleId,
        pts: &Vector<TypeId>,
        tis: &Vector<TyI>,
        offs: &Vector<u32>,
        rt: TypeId,
        ri: TyI,
        roff: u32,
        callee: str,
    ) bool {
        let one: []u32 = [T_PTR as u32];
        self.b.sig = self.b.signature(one, 1, false, T_NONE);
        let pb: []u8 = [T_PTR];
        let b0 = self.b.add_block(pb);
        self.b.begin(b0);
        let e = self.b.param(b0, 0);
        // The callee's signature: the wrapper's.
        let mut etys = Vector::<u8>::new();
        let saved = self.b.sig;
        self.blk_sig(c, m, pts, tis, rt, ri, &mut etys);
        let csig = self.b.sig;
        self.b.sig = saved;
        let mut args = Vector::<Value>::new();
        for k in 0..pts.len() {
            let ti = tis[k];
            if ti.cls == VC_ZST {
                continue;
            }
            let fa = self.ptradd(e, VNONE, 0, offs[k]);
            if ti.cls == VC_SCALAR {
                args.push(self.load(ti.mty, fa, 0, false));
            } else {
                // A copy the callee owns: the env's own, which no one reads after.
                args.push(fa);
            }
        }
        let ra = self.ptradd(e, VNONE, 0, roff);
        if ri.cls == VC_MEM {
            args.push(ra);
        }
        let k = self.sym(callee, SK_FUNC);
        let at = self.b.pool_list(args[0..args.len()]);
        let r = self.inst(O_CALL, ast::pick(ri.cls == VC_SCALAR, ri.mty, T_NONE), args.len() as u16, k, csig, at);
        if ri.cls == VC_SCALAR {
            self.store(r, ra, 0, false);
        }
        let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
        return true;
    }

    // Whether function or data `sym` has a definition.
    const fn defined(self: &Self, sym: str) bool {
        let s = self.pkg.find_symbol(sym);
        return s != NONE && self.pkg.syms[s as usize].def != NONE;
    }

    /// A dyn table's slot `sym(self, args)` (`CEmit::dyn_thunk`) of unit `unit`: the call of `callee` with
    /// `self` first when `env`, then the arguments, of types `(m, ps)`; its result, of types `(m, rs)`.
    pub(package) fn dyn_thunk(
        self: &mut Self,
        c: &mut cbe::CEmit,
        m: ModuleId,
        ps: &Vector<TypeId>,
        rs: &Vector<TypeId>,
        sym: str,
        callee: str,
        env: bool,
        unit: ModuleId,
    ) bool {
        if self.defined(sym) {
            return true;
        }
        let (cd, ro) = self.synth_begin(c, m);
        let ok = self.thunk_i(c, m, ps, rs, callee, env);
        if !self.synth_end(c, cd, ro, sym, ok) {
            return false;
        }
        self.own_last(unit);
        return true;
    }

    fn thunk_i(
        self: &mut Self,
        c: &mut cbe::CEmit,
        m: ModuleId,
        ps: &Vector<TypeId>,
        rs: &Vector<TypeId>,
        callee: str,
        env: bool,
    ) bool {
        let mut ptys = Vector::<u32>::new();
        let mut etys = Vector::<u8>::new();
        ptys.push(T_PTR);
        etys.push(T_PTR);
        for k in 0..ps.len() {
            let mut ti = TyI { cls: 0 };
            if !self.ty(c, m, ps[k], &mut ti) {
                return false;
            }
            if ti.cls == VC_SCALAR {
                ptys.push(sig_code(ti.mty, Lower::signed(c, m, ps[k])));
                etys.push(ti.mty);
            } else if ti.cls == VC_MEM {
                ptys.push(self.param_sig(c, m, ps[k], ti));
                etys.push(T_PTR);
            }
        }
        let mut ret = T_NONE as u32;
        let mut rty = T_NONE;
        if rs.len() == 1 {
            let mut ri = TyI { cls: 0 };
            if !self.ty(c, m, rs[0], &mut ri) {
                return false;
            }
            if ri.cls == VC_SCALAR {
                ret = sig_code(ri.mty, Lower::signed(c, m, rs[0]));
                rty = ri.mty;
            } else if ri.cls == VC_MEM {
                ret = AGG | self.layout_of(c, m, rs[0], ri);
            }
        } else if rs.len() > 1 {
            let lt = self.pack(c, m, rs);
            if lt == NONE && self.err.len() != 0 {
                return false;
            }
            if lt != NONE {
                ret = AGG | lt;
            }
        }
        if (ret & AGG) != 0 {
            etys.push(T_PTR);
        }
        let n = ptys.len() as u32;
        self.b.sig = self.b.signature(ptys[0..ptys.len()], n, false, ret);
        // A callee without an env takes the arguments only.
        let skip = ast::pick(env, 0u32, 1u32);
        let csig = if env {
            self.b.sig;
        } else {
            self.b.signature(ptys[1..ptys.len()], n - 1, false, ret);
        };
        let b0 = self.b.add_block(etys[0..etys.len()]);
        self.b.begin(b0);
        let mut args = Vector::<Value>::new();
        for k in skip..etys.len() as u32 {
            args.push(self.b.param(b0, k));
        }
        let kf = self.sym(callee, SK_FUNC);
        let at = self.b.pool_list(args[0..args.len()]);
        let r = self.inst(O_CALL, rty, args.len() as u16, kf, csig, at);
        let _ = self.inst(O_RET, T_NONE, 0, ast::pick(rty != T_NONE, r, VNONE), VNONE, VNONE);
        return true;
    }

    /// An owned dyn table's `__free` slot `sym(self)` of unit `unit`: the destructor of the value of type
    /// `(sm, st)` at `self`, then its block back to `Global`, or (`at` not TYPE_NONE) to the allocator
    /// `(am, at)` its `Default` rebuilds.
    pub(package) fn dyn_free(
        self: &mut Self,
        c: &mut cbe::CEmit,
        sm: ModuleId,
        st: TypeId,
        am: ModuleId,
        at: TypeId,
        sym: str,
        unit: ModuleId,
    ) bool {
        if self.defined(sym) {
            return true;
        }
        let (cd, ro) = self.synth_begin(c, sm);
        let ok = self.dyn_free_i(c, sm, st, am, at);
        if !self.synth_end(c, cd, ro, sym, ok) {
            return false;
        }
        self.own_last(unit);
        return true;
    }

    fn dyn_free_i(self: &mut Self, c: &mut cbe::CEmit, sm: ModuleId, st: TypeId, am: ModuleId, at: TypeId) bool {
        let one: []u32 = [T_PTR as u32];
        self.b.sig = self.b.signature(one, 1, false, T_NONE);
        let pb: []u8 = [T_PTR];
        let b0 = self.b.add_block(pb);
        self.b.begin(b0);
        let p = self.b.param(b0, 0);
        let mut rm = sm;
        let mut rt = TYPE_NONE;
        let _ = Lower::resolved(c, sm, st, &mut rm, &mut rt);
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, sm, st, &mut ti) || c.is_destructible(rm, rt) && !self.drop_at(c, rm, rt, p, 0) {
            return false;
        }
        if ti.size == 0 {
            // A zero-sized value occupies no bytes: its box holds the sentinel, which was never allocated.
            let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
            return true;
        }
        let pi = self.ptr_int();
        let sz = self.iconst(pi, ti.size);
        let al = self.iconst(pi, ast::pick(ti.align == 0, 1u32, ti.align));
        let dt: []u32 = [T_PTR as u32, T_PTR as u32, pi as u32, pi as u32];
        if at == TYPE_NONE {
            let g = self.sentinel1(c);
            let args: []Value = [g, p, sz, al];
            let _ = self.call_sym("Global__dealloc", args, dt, T_NONE);
        } else {
            // The allocator its `Default` rebuilds: the fat value carries no allocator state.
            let mut ds = String::new();
            let mut dd = String::new();
            let mut ai = TyI { cls: 0 };
            if !c.mg.method_by_name(am, at, "default", &mut ds) || !c.mg.method_by_name(am, at, "dealloc", &mut dd) || !self.ty(
                c,
                am,
                at,
                &mut ai,
            ) {
                return self.fail("dyn-free-allocator");
            }
            let none: []Value = [];
            let nt: []u32 = [];
            let mut a = VNONE;
            if ai.cls == VC_ZST {
                let _ = self.call_sym(ds.as_str(), none, nt, T_NONE);
                a = self.sentinel(c, am, at);
            } else if ai.cls == VC_SCALAR {
                let v = self.call_sym(ds.as_str(), none, nt, sig_code(ai.mty, Lower::signed(c, am, at)));
                a = self.temp(ai);
                self.store(v, a, 0, false);
            } else {
                a = self.temp(ai);
                let sr: []Value = [a];
                let _ = self.call_sym(ds.as_str(), sr, nt, AGG | self.layout_of(c, am, at, ai));
            }
            let args: []Value = [a, p, sz, al];
            let _ = self.call_sym(dd.as_str(), args, dt, T_NONE);
        }
        let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
        return true;
    }

    /// The dyn table `sym` of unit `unit` (`CEmit::dyn_pair_tabs`): the `__free` slot `free` ("": null),
    /// the erased type's name `tid` when `named`, then the slots `slots`, each a function, or (`data`)
    /// another table.
    pub(package) fn dyn_table(
        self: &mut Self,
        sym: str,
        free: str,
        named: bool,
        tid: str,
        slots: &Vector<String>,
        data: &Vector<bool>,
        unit: ModuleId,
    ) bool {
        if self.defined(sym) {
            return true;
        }
        let pb = self.pkg.ptr_bytes;
        let mut rs = Vector::<Reloc>::with_capacity(slots.len() + 2);
        let mut at: u32 = 0;
        if free.len() != 0 {
            rs.push(Reloc { offset: 0, sym: self.pkg.symbol(free, SK_FUNC), addend: 0 });
        }
        at += pb;
        if named {
            let mut bytes = String::from_str(tid);
            rs.push(Reloc { offset: at, sym: self.rodata(&mut bytes), addend: 0 });
            at += pb;
        }
        for k in 0..slots.len() {
            let kd = ast::pick(data[k], SK_DATA, SK_FUNC);
            rs.push(Reloc { offset: at, sym: self.pkg.symbol(slots.at(k).as_str(), kd), addend: 0 });
            at += pb;
        }
        let s = self.pkg.symbol(sym, SK_DATA);
        let none: []u8 = [];
        if !self.pkg.add_data(s, at, log2(pb) as u8, true, none, rs[0..rs.len()]) {
            return false;
        }
        self.pkg.syms.index_mut(s as usize).unit = unit;
        return true;
    }

    // A call of function `(m, f)` with pointer arguments `args` and no result.
    fn call_fn(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, f: NodeId, args: []Value) bool {
        let mut s = String::new();
        if !c.mg.fn_sym(m, f, c.mg.method_target(m, f), &mut s) {
            return self.fail("test-sym");
        }
        let k = self.sym(s.as_str(), SK_FUNC);
        let mut pt = Vector::<u32>::new();
        for _ in 0..args.len() {
            pt.push(T_PTR);
        }
        let sg = self.b.signature(pt[0..pt.len()], args.len() as u32, false, T_NONE);
        let at = self.b.pool_list(args);
        let _ = self.inst(O_CALL, T_NONE, args.len() as u16, k, sg, at);
        return true;
    }

    /// The global test env hooks (`CEmit::emit_test_genv`): `__sc_test_genv_init` keeps the env of `ginit`
    /// in a cell and returns its address; `__sc_test_genv_free(p)` runs teardown `gfree` (NODE_NONE: none)
    /// then the env's destructor.
    pub(package) fn test_genv(self: &mut Self, c: &mut cbe::CEmit, gm: ModuleId, ginit: NodeId, gfree: NodeId) bool {
        let gt = c.fn_ret_ty(gm, ginit);
        if gt == TYPE_NONE {
            return false;
        }
        let (cd, ro) = self.synth_begin(c, gm);
        let ok = self.genv_init_i(c, gm, ginit, gt);
        if !self.synth_end(c, cd, ro, "__sc_test_genv_init", ok) {
            return false;
        }
        let (cd2, ro2) = self.synth_begin(c, gm);
        let ok2 = self.genv_free_i(c, gm, gfree, gt);
        return self.synth_end(c, cd2, ro2, "__sc_test_genv_free", ok2);
    }

    fn genv_init_i(self: &mut Self, c: &mut cbe::CEmit, gm: ModuleId, ginit: NodeId, gt: TypeId) bool {
        let none: []u32 = [];
        self.b.sig = self.b.signature(none, 0, false, T_PTR);
        let pb: []u8 = [];
        let b0 = self.b.add_block(pb);
        self.b.begin(b0);
        let mut ti = TyI { cls: 0 };
        if !self.ty(c, gm, gt, &mut ti) {
            return false;
        }
        let mut r = VNONE;
        if ti.cls == VC_ZST {
            r = self.call_init(c, gm, ginit, gt);
        } else {
            // The env's cell: a zeroed static of its type, filled by the init's result.
            let s = self.pkg.symbol("__sc_test_genv", SK_DATA);
            if self.pkg.syms[s as usize].def == NONE {
                let nb: []u8 = [];
                let nr: []Reloc = [];
                let _ = self.pkg.add_data(s, ti.size, log2(ti.align) as u8, false, nb, nr);
                self.pend.push(s);
            }
            let v = self.call_init(c, gm, ginit, gt);
            if v == VNONE {
                return false;
            }
            r = self.symaddr("__sc_test_genv", SK_DATA);
            self.memcpy(r, v, ti.size);
        }
        if r == VNONE {
            return false;
        }
        let _ = self.inst(O_RET, T_NONE, 0, r, VNONE, VNONE);
        return true;
    }

    fn genv_free_i(self: &mut Self, c: &mut cbe::CEmit, gm: ModuleId, gfree: NodeId, gt: TypeId) bool {
        let pt: []u32 = [T_PTR as u32];
        self.b.sig = self.b.signature(pt, 1, false, T_NONE);
        let pb: []u8 = [T_PTR];
        let b0 = self.b.add_block(pb);
        self.b.begin(b0);
        let p = self.b.param(b0, 0);
        if gfree != NODE_NONE {
            let one: []Value = [p];
            if !self.call_fn(c, gm, gfree, one) {
                return false;
            }
        }
        if c.is_destructible(gm, gt) && !self.drop_at(c, gm, gt, p, 0) {
            return false;
        }
        let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
        return true;
    }

    /// The C entry `main(argc, argv)` of the main module `m` (`cemit_main_wrapper`): the value of the user
    /// main `__sc_user_main`, which takes the arguments as a `Vector<str>` when it has a parameter.
    pub(package) fn main_wrapper(self: &mut Self, c: &mut cbe::CEmit, m: ModuleId, argv: bool) bool {
        let (cd, ro) = self.synth_begin(c, m);
        let ok = self.main_i(c, argv);
        return self.synth_end(c, cd, ro, "main", ok);
    }

    // The user main `__sc_user_main` returns an i32 and, when `wants`, takes the arguments as a
    // `Vector<str>`: pointer, length and capacity.
    fn main_i(self: &mut Self, c: &mut cbe::CEmit, wants: bool) bool {
        let pb = self.pkg.ptr_bytes;
        let pi = self.ptr_int();
        let np = wants as u32;
        let tys: []u32 = [T_I32 as u32, T_PTR as u32];
        self.b.sig = self.b.signature(tys, 2, false, T_I32);
        let pt: []u8 = [T_I32, T_PTR];
        let b0 = self.b.add_block(pt);
        self.b.begin(b0);
        let argc = self.b.param(b0, 0);
        let argv = self.b.param(b0, 1);
        let mut args = Vector::<Value>::new();
        let mut atys = Vector::<u32>::new();
        if wants {
            let al = log2(pb);
            let mut leaves = Vector::<(u32, u8)>::new();
            leaves.push((0u32, T_PTR));
            leaves.push((pb, pi));
            leaves.push((2 * pb, pi));
            let lt = self.layout(3 * pb, al, &leaves);
            let vec = self.temp(TyI { cls: VC_MEM, mty: T_NONE, size: 3 * pb, align: pb });
            let zero = self.iconst(pi, 0);
            for k in 0..3u32 {
                self.store(zero, vec, k * pb, false);
            }
            let n = self.int_to(argc, pi, true);
            let some = self.icmp(C_SGT, argc, self.iconst(T_I32, 0));
            let done = self.block();
            self.split(some, done, false);
            // The strings: each argument and its length.
            let bytes = self.arith(O_MUL, n, self.iconst(pi, 2 * pb as u64));
            let atys3: []u32 = [T_PTR as u32, pi as u32, pi as u32];
            let sg = self.b.signature(atys3, 3, false, T_PTR);
            let g = self.sentinel1(c);
            let alv = self.iconst(pi, pb);
            let av: []Value = [g, bytes, alv];
            let at = self.b.pool_list(av);
            let k = self.sym("Global__alloc", SK_FUNC);
            let buf = self.inst(O_CALL, T_PTR, 3, k, sg, at);
            self.store(buf, vec, 0, false);
            self.store(n, vec, pb, false);
            self.store(n, vec, 2 * pb, false);
            let islot = self.temp(TyI { cls: VC_SCALAR, mty: pi, size: pb, align: pb });
            self.store(zero, islot, 0, false);
            let lp = self.block();
            let el = self.edge(lp, NONE, NONE);
            let _ = self.inst(O_JMP, T_NONE, 0, el, VNONE, VNONE);
            self.b.begin(lp);
            let i = self.load(pi, islot, 0, false);
            let pa = self.ptradd(argv, i, pb, 0);
            let s = self.load(T_PTR, pa, 0, false);
            let st: []u32 = [T_PTR as u32];
            let ssg = self.b.signature(st, 1, false, pi);
            let sv: []Value = [s];
            let sat = self.b.pool_list(sv);
            let sk = self.sym("strlen", SK_FUNC);
            let len = self.inst(O_CALL, pi, 1, sk, ssg, sat);
            let ea = self.ptradd(buf, i, 2 * pb, 0);
            self.store(s, ea, 0, false);
            self.store(len, ea, pb, false);
            let i1 = self.arith(O_ADD, i, self.iconst(pi, 1));
            self.store(i1, islot, 0, false);
            let more = self.icmp(C_ULT, i1, n);
            let eb = self.edge(lp, NONE, NONE);
            let ed = self.edge(done, NONE, NONE);
            let _ = self.inst(O_BR, T_NONE, 0, more, eb, ed);
            self.b.begin(done);
            args.push(vec);
            atys.push(AGG | lt);
        }
        let usg = self.b.signature(atys[0..atys.len()], np, false, T_I32);
        let uat = self.b.pool_list(args[0..args.len()]);
        let uk = self.sym("__sc_user_main", SK_FUNC);
        let r = self.inst(O_CALL, T_I32, np as u16, uk, usg, uat);
        let _ = self.inst(O_RET, T_NONE, 0, r, VNONE, VNONE);
        return true;
    }

    fn glue_i(self: &mut Self, c: &mut cbe::CEmit, rm: ModuleId, rt: TypeId, fb: str, fields: []NodeId) bool {
        let tys: []u32 = [T_PTR as u32];
        self.b.sig = self.b.signature(tys, 1, false, T_NONE);
        let pt: []u8 = [T_PTR];
        let b0 = self.b.add_block(pt);
        self.b.begin(b0);
        let me = self.b.param(b0, 0);
        if fb.len() != 0 {
            let k = self.sym(fb, SK_FUNC);
            let sg = self.b.signature(tys, 1, false, T_NONE);
            let ms: []Value = [me];
            let at = self.b.pool_list(ms);
            let _ = self.inst(O_CALL, T_NONE, 1, k, sg, at);
        }
        let mut fl = Vector::<FieldAt>::new();
        let y = *Lower::ast(c, rm).type_at(rt);
        let decl = if y.kind == TypeKind::TYPE_ENUM {
            y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            Lower::ast(c, rm).instance(y.as_data.inst).decl;
        } else {
            NODE_NONE;
        };
        let dm = if y.kind == TypeKind::TYPE_INSTANCE {
            Lower::ast(c, rm).instance(y.as_data.inst).module;
        } else {
            y.module;
        };
        let is_enum = decl != NODE_NONE && Lower::ast(c, dm).at_const(decl).kind == NodeKind::NODE_ENUM;
        if is_enum && !Lower::ast(c, dm).enum_has_payload(decl) || y.kind != TypeKind::TYPE_FUNCTION && y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM && y.kind != TypeKind::TYPE_INSTANCE {
            let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
            return true;
        }
        if !self.fields_of(c, rm, rt, &mut fl) {
            return self.fail("glue-fields");
        }
        let mut el = EnumL { ok: false };
        let mut tag = VNONE;
        if is_enum {
            if !self.enum_of(c, rm, rt, &mut el) {
                return self.fail("glue-enum");
            }
            if el.niche != lay::NK_NONE {
                // Only `some` has members: it holds when the payload's pointer word is not null.
                let w = self.load(self.ptr_int(), me, 0, false);
                let z = self.iconst(self.ptr_int(), 0);
                tag = self.icmp(C_NE, w, z);
            } else {
                tag = self.load(el.tag, me, 0, false);
            }
        }
        // Each member in order; an enum's run of one variant's members behind its tag test.
        let mut k: usize = 0;
        for _ in 0..fl.len() {
            if k >= fl.len() {
                break;
            }
            let v = fl[k].variant;
            let mut end = k + 1;
            while end < fl.len() && fl[end].variant == v {
                end += 1;
            }
            let mut any = false;
            for j in k..end {
                any = any || Lower::listed(fb, fields, fl[j].node) && self.glue_member(c, fl[j], VNONE, true);
            }
            if any {
                let mut skip = NONE;
                if is_enum && v != NODE_NONE {
                    let mut hit = tag;
                    if el.niche == lay::NK_NONE {
                        let mut d: i64 = 0;
                        if !self.variant_value(c, dm, v, &mut d) {
                            return false;
                        }
                        let dv = self.iconst(el.tag, d as u64);
                        hit = self.icmp(C_EQ, tag, dv);
                    }
                    let body = self.block();
                    skip = self.block();
                    let eb = self.edge(body, NONE, NONE);
                    let es = self.edge(skip, NONE, NONE);
                    let _ = self.inst(O_BR, T_NONE, 0, hit, eb, es);
                    self.b.begin(body);
                }
                for j in k..end {
                    if Lower::listed(fb, fields, fl[j].node) {
                        let _ = self.glue_member(c, fl[j], me, false);
                    }
                    if self.err.len() != 0 {
                        return false;
                    }
                }
                if skip != NONE {
                    let es = self.edge(skip, NONE, NONE);
                    let _ = self.inst(O_JMP, T_NONE, 0, es, VNONE, VNONE);
                    self.b.begin(skip);
                }
            }
            k = end;
        }
        let _ = self.inst(O_RET, T_NONE, 0, VNONE, VNONE, VNONE);
        return true;
    }

    // Whether a destructor frees member `node`: a derived one (`fb` empty) every member, a wrapper the
    // `fields` it lists.
    const fn listed(fb: str, fields: []NodeId, node: NodeId) bool {
        if fb.len() == 0 {
            return true;
        }
        for i in 0..fields.len() {
            if fields[i] == node {
                return true;
            }
        }
        return false;
    }

    // Whether member `f` (not an enum's tag, not a capture by reference) needs a free; with `probe`
    // false, free it in the object at `me`.
    fn glue_member(self: &mut Self, c: &mut cbe::CEmit, f: FieldAt, me: Value, probe: bool) bool {
        if f.t == TYPE_NONE || f.idx == 0xFFFFFFFF {
            return false;
        }
        let mut frm = f.m;
        let mut frt = f.t;
        if !c.mg.resolve(f.m, f.t, &mut frm, &mut frt) || !c.is_destructible(frm, frt) {
            return false;
        }
        if probe {
            return true;
        }
        let at = self.ptradd(me, VNONE, 0, f.off);
        return self.drop_at(c, frm, frt, at, 0);
    }
}
