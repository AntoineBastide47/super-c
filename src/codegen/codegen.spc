import string as cstring;
import stdlib;
import stdio;
import lexer::token as tok;
import lexer::token_type as *;
import ast::ast as *;
import driver_shim as shim;
import module::loader as loader;
import consteval::consteval as ce;
import utils::errors as diag;

extern "C" {
    fn strtoull(s: *const char, endptr: *mut *mut char, base: i32) u64;
    fn strtoll(s: *const char, endptr: *mut *mut char, base: i32) i64;
}

// The full C standard library include block the generated runtime pulls in. Emitted verbatim into the
// shared super_rt.h. (Faithful reconstruction pending — filled when codegen_emit is ported; only the
// content of this constant is deferred, never a code path.)
pub fn super_rt_includes() *const char {
    return r#"#if __has_include(<assert.h>)
#include <assert.h>
#endif
#if __has_include(<complex.h>)
#include <complex.h>
#endif
#if __has_include(<ctype.h>)
#include <ctype.h>
#endif
#if __has_include(<errno.h>)
#include <errno.h>
#endif
#if __has_include(<fenv.h>)
#include <fenv.h>
#endif
#if __has_include(<float.h>)
#include <float.h>
#endif
#if __has_include(<inttypes.h>)
#include <inttypes.h>
#endif
#if __has_include(<iso646.h>)
#include <iso646.h>
#endif
#if __has_include(<limits.h>)
#include <limits.h>
#endif
#if __has_include(<locale.h>)
#include <locale.h>
#endif
#if __has_include(<math.h>)
#include <math.h>
#endif
#if __has_include(<dlfcn.h>)
#include <dlfcn.h>
#endif
#if __has_include(<signal.h>)
#include <signal.h>
#endif
#if __has_include(<stdalign.h>)
#include <stdalign.h>
#endif
#if __has_include(<stdarg.h>)
#include <stdarg.h>
#endif
#if __has_include(<stdatomic.h>)
#include <stdatomic.h>
#endif
#if __has_include(<stdbit.h>)
#include <stdbit.h>
#endif
#if __has_include(<stdbool.h>)
#include <stdbool.h>
#endif
#if __has_include(<stdckdint.h>)
#include <stdckdint.h>
#endif
#if __has_include(<stddef.h>)
#include <stddef.h>
#endif
#if __has_include(<stdint.h>)
#include <stdint.h>
#endif
#if __has_include(<stdio.h>)
#include <stdio.h>
#endif
#if __has_include(<stdlib.h>)
#include <stdlib.h>
#endif
#if __has_include(<stdnoreturn.h>)
#include <stdnoreturn.h>
#endif
#if __has_include(<string.h>)
#include <string.h>
#endif
#if __has_include(<tgmath.h>)
#include <tgmath.h>
#endif
#if __has_include(<threads.h>)
#include <threads.h>
#endif
#if __has_include(<time.h>)
#include <time.h>
#endif
#if __has_include(<uchar.h>)
#include <uchar.h>
#endif
#if __has_include(<wchar.h>)
#include <wchar.h>
#endif
#if __has_include(<wctype.h>)
#include <wctype.h>
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#define SC_AT(T,S) \
static inline T __sc_atomic_load_##S(const T*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);} \
static inline void __sc_atomic_store_##S(T*p,T v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_swap_##S(T*p,T v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_add_##S(T*p,T v){return __atomic_fetch_add(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_sub_##S(T*p,T v){return __atomic_fetch_sub(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_and_##S(T*p,T v){return __atomic_fetch_and(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_or_##S(T*p,T v){return __atomic_fetch_or(p,v,__ATOMIC_SEQ_CST);} \
static inline T __sc_atomic_xor_##S(T*p,T v){return __atomic_fetch_xor(p,v,__ATOMIC_SEQ_CST);} \
static inline bool __sc_atomic_cas_##S(T*p,T e,T d){return __atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}
SC_AT(int8_t,i8) SC_AT(int16_t,i16) SC_AT(int32_t,i32) SC_AT(int64_t,i64) SC_AT(intptr_t,isize)
SC_AT(uint8_t,u8) SC_AT(uint16_t,u16) SC_AT(uint32_t,u32) SC_AT(uint64_t,u64) SC_AT(size_t,usize)
#undef SC_AT
static inline bool __sc_atomic_load_bool(const bool*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);}
static inline void __sc_atomic_store_bool(bool*p,bool v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);}
static inline bool __sc_atomic_swap_bool(bool*p,bool v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);}
static inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d){return __atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}
static inline void __sc_atomic_fence(void){__atomic_thread_fence(__ATOMIC_SEQ_CST);}
#pragma GCC diagnostic pop
#endif
static inline __attribute__((unused)) FILE* __sc_stdin(void){return stdin;}
static inline __attribute__((unused)) FILE* __sc_stdout(void){return stdout;}
static inline __attribute__((unused)) FILE* __sc_stderr(void){return stderr;}
static inline __attribute__((unused)) int* __sc_errno_location(void){return &errno;}
static _Noreturn __attribute__((unused)) void __sc_panic(const char *__m) {
  fprintf(stderr, "super-c: %s\n", __m); abort();
}
static _Noreturn __attribute__((unused)) void __sc_panic_str(const uint8_t *__p, size_t __n) {
  fprintf(stderr, "panic: %.*s\n", (int)__n, (const char *)__p); abort();
}
static __attribute__((unused)) inline size_t __sc_bounds(size_t __i, size_t __n) {
  if (__i >= __n) __sc_panic("index out of bounds");
  return __i;
}
"#.ptr() as *const char;
}

// Builtin names (for matching unresolved type paths) and their C spellings, indexed by BuiltinType.
const fn builtin_c(b: BuiltinType) *const char {
    let i = b as i32;
    if i == 0 {
        return "bool".ptr() as *const char;
    }
    if i == 1 {
        return "char".ptr() as *const char;
    }
    if i == 2 {
        return "int8_t".ptr() as *const char;
    }
    if i == 3 {
        return "int16_t".ptr() as *const char;
    }
    if i == 4 {
        return "int32_t".ptr() as *const char;
    }
    if i == 5 {
        return "int64_t".ptr() as *const char;
    }
    if i == 6 {
        return "intptr_t".ptr() as *const char;
    }
    if i == 7 {
        return "uint8_t".ptr() as *const char;
    }
    if i == 8 {
        return "uint16_t".ptr() as *const char;
    }
    if i == 9 {
        return "uint32_t".ptr() as *const char;
    }
    if i == 10 {
        return "uint64_t".ptr() as *const char;
    }
    if i == 11 {
        return "size_t".ptr() as *const char;
    }
    if i == 12 {
        return "float".ptr() as *const char;
    }
    if i == 13 {
        return "double".ptr() as *const char;
    }
    if i == 14 {
        return "float _Complex".ptr() as *const char;
    }
    if i == 15 {
        return "double _Complex".ptr() as *const char;
    }
    if i == 16 {
        return "va_list".ptr() as *const char;
    }
    return "void".ptr() as *const char;
}

// which-set for prototype emission
pub const PROTO_ALL: i32 = 0;
pub const PROTO_PUBLIC: i32 = 1;
pub const PROTO_PRIVATE: i32 = 2;

pub const CG_PASTE: char = 1 as char;

// ---- nested record types ----
pub struct CgSubst {
    pub param: DefId,
    pub concrete: TypeId,
}
pub struct CgInst {
    pub func: DefId,
    pub n: u8,
    pub args: [TypeId; 4],
}
// A conditional-move candidate recorded during the (single) move walk, replayed after the walk
// completes so the "already unconditionally moved" suppression sees the FULL moved[] set, exactly
// as the old second pass did. flags: bit0 = push a cond_site, bit1 = closure capture (site is the
// closure node, pushed once per closure on its first surviving capture).
pub struct CgPendMove {
    pub decl: NodeId,
    pub site: NodeId,
    pub flags: u32,
}
pub struct CgCbInst {
    pub func: DefId,
    pub param: NodeId,
    pub cbidx: u32,
    pub callee: DefId,
    pub callee_closure: bool,
}
pub struct CgLoop {
    pub node: NodeId,
    pub defer_base: u32,
    pub seq: u32,
    pub used_brk: bool,
    pub used_cnt: bool,
    pub is_expr: bool,
}
pub struct CgTestCase {
    pub func: NodeId,
    pub wants: u8,
    pub suite: DefId,
    pub suite_is_enum: bool,
    pub suite_init: NodeId,
    pub suite_free: NodeId,
}
pub struct CgTestInfo {
    pub enabled: bool,
    pub cases: *const CgTestCase,
    pub ncases: u32,
    pub fx_init: NodeId,
    pub fx_free: NodeId,
    pub fx_type: DefId,
    pub fx_is_enum: bool,
    pub genv_init: NodeId,
    pub genv_free: NodeId,
    pub genv_type: DefId,
    pub genv_is_enum: bool,
}

// zero-init buffer wrappers (fixed C-string scratch)
pub type Buf32 = Array<char, 32>;
pub type ExtChain = Array<i32, 64>;
pub type Bools64 = Array<bool, 64>;
pub type Buf64 = Array<char, 64>;
pub type Buf128 = Array<char, 128>;
pub type Buf160 = Array<char, 160>;
pub type Buf256 = Array<char, 256>;
pub type Buf512 = Array<char, 512>;

pub struct Codegen {
    pub ast: *mut Ast,
    pub source: str,
    pub buf: String,
    pub enum_of_variant: Map<u32, u32>,
    // CG-3: memoize cg_free_extend by (tmod,tdecl). A Codegen is per-module, so cur_module (the 2nd search
    // scope) is constant, and the scanned EXTEND items are stable -> the result is a pure function of the key.
    pub free_ext_cache: Map<u64, DefId>,
    // CG-4: per-module chain index of extend items keyed by resolved target NODE. ext_head maps
    // (module<<32|target) to the FIRST matching item position, ext_next links positions in item
    // order, so chain walks visit extends exactly as the full item scan did. Built lazily per
    // module; modules >= 64 (ext_built is a bitmask) fall back to the full scan.
    pub ext_head: Map<u64, u32>,
    pub ext_next: Map<u64, u32>,
    pub ext_built: u64,
    // CG-5: cg_type_satisfies memo. TypeIds are per-pool, so hits are only valid while self.ast
    // is this Codegen's home ast (owner swaps bypass the memo), and only for concrete types
    // (generic args would depend on the live subst stack).
    pub sat_memo: Map<u64, u64>,
    pub home_ast: *mut Ast,
    // CG-6: per-module interface-member NodeId presence set (same bitmask scheme as CG-4).
    pub ifm_set: Map<u64, u64>,
    pub ifm_built: u64,
    // CG-7: monotone cursor for cg_line_of -- asserts are emitted in source order, so resuming
    // from the last query makes the per-module cost linear instead of quadratic.
    pub lc_src: *const u8,
    pub lc_off: u32,
    pub lc_line: u32,
    // CG-8: prelude Slice/SliceMut/Range hits resolved once per Codegen (prelude_lookup is a
    // linear scan and these were re-resolved per indexed expression).
    pub ph_set: bool,
    pub ph_slice: loader::LookupHit,
    pub ph_slicemut: loader::LookupHit,
    pub ph_range: loader::LookupHit,
    // CG-9: seed watermark -- an instance's seeding outcome is fixed at interning time, so
    // instances processed by earlier seed passes never need re-processing.
    pub seed_mark: u32,
    // CG-10: NODE_CALL nids of call_ast in ascending order (expand_nested_insts scans calls
    // per instance; this replaces the full node-arena sweep per instance).
    pub call_list: Vector<NodeId>,
    pub call_ast: *mut Ast,
    // Memoized "type mentions a TYPE_GENERIC" bits (0 unknown / 1 no / 2 yes) for the instance
    // seeding sweep: concrete types (virtually the whole pool) are skipped without a walk.
    pub genty: Vector<u8>,
    pub genty_ast: *mut Ast,
    // collect_insts runs for the header AND the body of the same module: the second run is a no-op.
    pub insts_ast: *mut Ast,
    // CG-12: O(1) move-set membership. Epoch-tagged stamps (indexed by decl NodeId) mirror
    // moved[]/cond_moved[] appends EXACTLY -- caps included -- so answers match the linear
    // scans; the arrays stay authoritative and stamps are just an accelerator. stamp_cap == 0
    // (or an out-of-range decl) falls back to the scan.
    pub move_epoch: u32,
    pub moved_stamp: *mut u32,
    pub cond_stamp: *mut u32,
    pub stamp_cap: usize,
    // CG-13: per-module mangling prefix cache (pure function of the module path); served by
    // memcpy when the caller's cap fits, rebuilt char-by-char otherwise.
    pub modpfx_set: u64,
    pub modpfx_cur: u32,
    pub modpfx_off: [u16; 64],
    pub modpfx_len: [u16; 64],
    pub modpfx_buf: [char; 4096],
    // CG-15: record_inst dedup index -- FNV key of (func, args) -> inst slot. Exact compare on a
    // hit; a key collision falls back to the full scan; first-key-wins, so key absence proves no
    // equal inst was ever appended. Cleared with ninsts in collect_insts.
    pub inst_idx: Map<u64, u32>,
    // CG-16: per-module attr chain index keyed by (module<<32|owner), same scheme and bitmask
    // fallback as CG-4 (modules >= 64 use the full attr-table scan).
    pub attr_head: Map<u64, u32>,
    pub attr_next: Map<u64, u32>,
    pub attr_built: u64,
    // CG-17: NODE_CLOSURE ids in ascending (= emission) order, collected by collect_insts'
    // arena sweep so emit_closures does not re-sweep the whole arena in both proto and body passes.
    pub clos_list: Vector<NodeId>,
    // CG-18: precomputed cb_specialized_away verdicts (private fns fully replaced by callback
    // specializations); rebuilt by collect_callbacks, empty before it runs (= all-false, as today).
    pub cb_away: Map<u32, u8>,
    // CG-14: cg_type_is_free memo keyed by the RESOLVED TypeId (1 = not Free / 2 = Free); CG-5's
    // validity rules (home pool only, concrete only, owner swaps bypass); never reset.
    pub free_memo: Map<u64, u64>,
    // CG-19/CG-20: mangled-name memos (mangle_type by TypeId, inst_name by TyInstance value).
    // Guarded home-pool + no-subst + non-macro + concrete. Values are SERVED BY COPY (copy_sym)
    // and never handed out as pointers: a Map rehash memcpy-moves the Strings and SSO bytes.
    pub mangle_memo: Map<u64, String>,
    pub instname_memo: Map<TyInstance, String>,
    // CG-21: conditional-move events from the fused single move walk (cleared per body; the heap
    // storage is reused across functions).
    pub pend_moves: Vector<CgPendMove>,
    pub depth: u32,
    pub tmp: u32,
    pub current_ret: [char; 128],
    pub current_fn_ret_node: NodeId,
    pub package: *mut loader::Package,
    pub mangle: bool,
    pub multifile: bool,
    pub const_ctx: bool,
    pub subst: [CgSubst; 16],
    pub nsubst: i32,
    pub insts: [CgInst; 1024],
    pub ninsts: i32,
    pub insts_overflow: bool,
    pub cb_insts: [CgCbInst; 256],
    pub n_cb_insts: i32,
    pub cb_keep_fns: [NodeId; 128],
    pub n_cb_keep: i32,
    pub cb_param: NodeId,
    pub cb_callee: DefId,
    pub cb_callee_closure: bool,
    pub macro_mode: bool,
    pub macro_self: NodeId,
    pub macro_self_mod: ModuleId,
    pub borrowed: bool,
    pub dflt_home: ModuleId,
    pub dflt_home_set: bool,
    pub fnval_pass: bool,
    pub slice_raw: NodeId,
    pub dyn_raw: NodeId,
    pub env_clos: NodeId,
    pub minst_only: bool,
    pub defer_stack: [NodeId; 256],
    pub defer_kind: [u8; 256],
    pub defer_top: u32,
    pub loop_defer_base: u32,
    pub loop_stack: [CgLoop; 32],
    pub nloops: u32,
    pub label_seq: u32,
    pub pending_cnt: u32,
    pub test: CgTestInfo,
    pub moved: [NodeId; 512],
    pub nmoved: u32,
    pub cond_moved: [NodeId; 256],
    pub ncond_moved: u32,
    pub cond_sites: [NodeId; 256],
    pub ncond_sites: u32,
    pub param_flags: [NodeId; 32],
    pub nparam_flags: u32,
    pub unused_params: [NodeId; 32],
    pub nunused_params: u32,
    pub no_temp_free: bool,
    pub type_state: *mut u8,
    pub inst_emit_state: *mut u8,
    pub inst_emit_n: usize,
    pub errors: diag::Errors,
}

extend Codegen as Free {
    // The Ast is borrowed (not owned); free only what codegen allocated itself.
    pub fn free(self: &mut Self) {
        self.buf.free();
        self.genty.free();
        self.enum_of_variant.free();
        self.free_ext_cache.free();
        self.ext_head.free();
        self.ext_next.free();
        self.sat_memo.free();
        self.ifm_set.free();
        self.inst_idx.free();
        self.attr_head.free();
        self.attr_next.free();
        self.clos_list.free();
        self.cb_away.free();
        self.free_memo.free();
        self.mangle_memo.free();
        self.instname_memo.free();
        self.pend_moves.free();
        self.call_list.free();
        if self.moved_stamp != null {
            unsafe stdlib::free(self.moved_stamp);
        }
        if self.cond_stamp != null {
            unsafe stdlib::free(self.cond_stamp);
        }
        self.errors.free();
        if self.type_state != null {
            unsafe stdlib::free(self.type_state);
        }
        if self.inst_emit_state != null {
            unsafe stdlib::free(self.inst_emit_state);
        }
    }
}

extend Codegen {
    pub fn new(ast: *mut Ast, source: str, package: *mut loader::Package) Codegen {
        let mut user_mods: usize = 0;
        if package != null {
            for i in 0..unsafe (*package).modules.len() {
                if !unsafe (*package).modules[i].prelude {
                    user_mods = user_mods + 1;
                }
            }
        }
        let mangle = user_mods > 1;
        let cap = source.len() * 4 + 4096;
        // *mut-to-Free values are move-tracked, so the second use of `ast` in the literal
        // (home_ast) has to go through a usize.
        let ast_u = ast as usize;
        // Fixed-array fields are omitted -> partial init zero-fills them (NODE_NONE == 0).
        return Codegen {
            ast: ast_u as *mut Ast,
            source: source,
            buf: String::with_capacity(cap),
            enum_of_variant: Map::<u32, u32>::new(),
            free_ext_cache: Map::<u64, DefId>::new(),
            ext_head: Map::<u64, u32>::new(),
            ext_next: Map::<u64, u32>::new(),
            sat_memo: Map::<u64, u64>::new(),
            ifm_set: Map::<u64, u64>::new(),
            inst_idx: Map::<u64, u32>::new(),
            attr_head: Map::<u64, u32>::new(),
            attr_next: Map::<u64, u32>::new(),
            clos_list: Vector::<NodeId>::new(),
            cb_away: Map::<u32, u8>::new(),
            free_memo: Map::<u64, u64>::new(),
            mangle_memo: Map::<u64, String>::new(),
            instname_memo: Map::<TyInstance, String>::new(),
            pend_moves: Vector::<CgPendMove>::new(),
            home_ast: ast_u as *mut Ast,
            call_list: Vector::<NodeId>::new(),
            genty: Vector::<u8>::new(),
            genty_ast: null,
            insts_ast: null,
            package: package,
            mangle: mangle,
            multifile: mangle,
            errors: diag::Errors::new(),
        };
    }

    pub fn take_ast(self: &mut Self) *mut Ast {
        return self.ast;
    }

    pub fn has_errors(self: &Self) bool {
        return self.errors.has_errors();
    }
    pub fn log_errors(self: &Self) {
        self.errors.log();
    }
    pub fn set_multifile(self: &mut Self, on: bool) {
        self.multifile = on;
    }
    pub fn set_test_info(self: &mut Self, ti: *const CgTestInfo) {
        self.test = unsafe *ti;
    }

    // ---- module accessors ----
    fn cur_ast(self: &Self) *mut Ast {
        return self.ast;
    }
    fn mod_ast(self: &Self, m: ModuleId) *mut Ast {
        if self.package != null && m != unsafe (*self.ast).module {
            return unsafe &mut (*self.package).modules[m as usize].ast;
        }
        return self.ast;
    }
    fn mod_src(self: &Self, m: ModuleId) str {
        if self.package != null && m != unsafe (*self.ast).module {
            return unsafe (*self.package).modules[m as usize].source.as_str();
        }
        return self.source;
    }
    fn pkg_count(self: &Self) usize {
        if self.package == null {
            return 0;
        }
        return unsafe (*self.package).modules.len();
    }
    fn ceval(self: &Self) *mut ce::ConstEval {
        if self.package == null {
            return null;
        }
        return (unsafe (*self.package).ceval) as *mut ce::ConstEval;
    }
    fn cur_module(self: &Self) ModuleId {
        return unsafe (*self.ast).module;
    }
    fn type_at(self: &Self, x: TypeId) &Ty {
        return unsafe (*self.cur_ast()).type_at(x);
    }

    // `<mod>__closure_<nodeid>`: a hoisted closure's C symbol.
    fn closure_sym_in(self: &Self, m: ModuleId, id: NodeId, out: *mut char, cap: usize) {
        let mut k = self.render_modpfx(m, out, cap);
        k = bappend(out, cap, k, "closure_".ptr() as *const char);
        let mut idb = Buf32 {};
        unsafe stdio::snprintf(&mut idb[0], 16, "%u".ptr() as *const char, id);
        bappend(out, cap, k, &idb[0]);
    }
    fn closure_name(self: &Self, id: NodeId, out: *mut char, cap: usize) {
        self.closure_sym_in(self.cur_module(), id, out, cap);
    }

    // ---- low-level output buffer (a String: growth + RAII come from it; we fill its spare tail) ----
    fn emit_bytes(self: &mut Self, p: *const char, n: usize) {
        let tail = self.buf.spare_mut(n);
        unsafe cstring::memcpy(tail, p, n);
        self.buf.advance_len(n);
    }
    fn emit_cstr(self: &mut Self, text: *const char) {
        self.emit_bytes(text, unsafe cstring::strlen(text));
    }
    // CG-11: literal emission -- a str carries its length, so fixed text skips the strlen
    // emit_cstr pays on every call.
    fn emit_str(self: &mut Self, s: str) {
        self.emit_bytes(s.ptr() as *const char, s.len());
    }
    // Emit a C octal byte-escape `\NNN` (3 zero-padded octal digits) for byte `b` (0..=255) -- the one
    // printf spec `format()` lacks; a fixed byte->3-digit render pushed straight into the buffer.
    fn emit_octal_escape(self: &mut Self, b: u32) {
        self.buf.push_byte(b'\\');
        self.buf.push_byte(('0' as u32 + (b >> 6 & 7u32)) as u8);
        self.buf.push_byte(('0' as u32 + (b >> 3 & 7u32)) as u8);
        self.buf.push_byte(('0' as u32 + (b & 7u32)) as u8);
    }
    fn emit_indent(self: &mut Self) {
        let mut n = self.depth * 2;
        while n != 0 {
            let mut k = n;
            if k > 32 {
                k = 32;
            }
            self.emit_bytes("                                ".ptr() as *const char, k as usize);
            n = n - k;
        }
    }
    fn emit_paste(self: &mut Self) {
        if self.macro_mode {
            let p = CG_PASTE;
            self.emit_bytes(&p, 1);
        }
    }

    fn fresh(self: &mut Self, buf: *mut char, cap: usize) {
        unsafe stdio::snprintf(buf, cap, "__sc%u".ptr() as *const char, self.tmp);
        self.tmp = self.tmp + 1;
    }

    fn name_span(self: &Self, name_node: NodeId) tok::Span {
        return unsafe (*self.ast).at_const(name_node).as_data.name.text;
    }
    fn name_span_in(self: &Self, m: ModuleId, name_node: NodeId) tok::Span {
        return unsafe (*self.mod_ast(m)).at_const(name_node).as_data.name.text;
    }
    fn emit_span(self: &mut Self, s: tok::Span) {
        self.emit_bytes((unsafe (self.source.ptr() + s.start as usize)) as *const char, (s.end - s.start) as usize);
    }
    fn emit_ident(self: &mut Self, s: tok::Span) {
        self.emit_span(s);
        if is_c_keyword(self.source, s) {
            self.emit_bytes("_".ptr() as *const char, 1);
        }
    }
    fn render_ident(self: &Self, s: tok::Span, buf: *mut char, cap: usize) usize {
        return render_ident_src(self.source, s, buf, cap);
    }

    // CG-13: the prefix is a pure function of the module path; build it once, then serve it
    // with a memcpy. When the full prefix + NUL fits the caller's cap, every boundary check in
    // the char-by-char builder passes, so the copy is byte-identical; smaller caps (or modules
    // beyond the bitmask) fall back to the original builder for its exact truncation behavior.
    fn render_modpfx(self: &Self, m: ModuleId, buf: *mut char, cap: usize) usize {
        if m as u32 < 64 && self.mangle {
            let bit = 1u64 << m as u64;
            if (self.modpfx_set & bit) == 0 {
                let mp = (self as *const Codegen) as *mut Codegen;
                let mut tb = Buf256 {};
                let n2 = self.render_modpfx_uncached(m, &mut tb[0], 256);
                if n2 + 1 < 256 && self.modpfx_cur as usize + n2 <= 4096 {
                    let off = self.modpfx_cur as usize;
                    let mut q: usize = 0;
                    while q < n2 {
                        unsafe {
                            (*mp).modpfx_buf[off + q] = tb[q];
                        }
                        q += 1;
                    }
                    unsafe {
                        (*mp).modpfx_off[m as usize] = off as u16;
                        (*mp).modpfx_len[m as usize] = n2 as u16;
                        (*mp).modpfx_cur = (off + n2) as u32;
                        (*mp).modpfx_set = self.modpfx_set | bit;
                    }
                }
            }
            if (self.modpfx_set & bit) != 0 {
                let ln = self.modpfx_len[m as usize] as usize;
                if ln + 1 <= cap {
                    let off = self.modpfx_off[m as usize] as usize;
                    unsafe cstring::memcpy(buf, &self.modpfx_buf[off], ln);
                    unsafe buf[ln] = 0 as char;
                    return ln;
                }
            }
        }
        return self.render_modpfx_uncached(m, buf, cap);
    }
    fn render_modpfx_uncached(self: &Self, m: ModuleId, buf: *mut char, cap: usize) usize {
        if cap != 0 {
            unsafe buf[0] = 0 as char;
        }
        if !self.mangle {
            return 0;
        }
        if unsafe (*self.package).modules[m as usize].prelude {
            return 0;
        }
        let path = unsafe (*self.package).modules[m as usize].path.as_str();
        let n = path.len();
        let mut at: usize = 0;
        let mut i: usize = 0;
        while i < n {
            if path.byte_at(i) == b':' && i + 1 < n && path.byte_at(i + 1) == b':' {
                i = i + 1;
                if at + 2 < cap {
                    unsafe buf[at] = '_' as char;
                    unsafe buf[at + 1] = '_' as char;
                }
                at = at + 2;
            } else {
                if at + 1 < cap {
                    unsafe buf[at] = path.byte_at(i) as char;
                }
                at = at + 1;
            }
            i = i + 1;
        }
        if at + 2 < cap {
            unsafe buf[at] = '_' as char;
            unsafe buf[at + 1] = '_' as char;
        }
        at = at + 2;
        if at < cap {
            unsafe buf[at] = 0 as char;
        }
        return at;
    }
    fn render_qualified(self: &Self, owner: ModuleId, name_node: NodeId, buf: *mut char, cap: usize) usize {
        let at = self.render_modpfx(owner, buf, cap);
        let mut off = at;
        if off >= cap {
            if cap != 0 {
                off = cap - 1;
            } else {
                off = 0;
            }
        }
        let s = unsafe (*self.mod_ast(owner)).at_const(name_node).as_data.name.text;
        let mut rem: usize = 0;
        if cap > off {
            rem = cap - off;
        }
        return at + render_ident_src(self.mod_src(owner), s, unsafe (buf + off), rem);
    }
    fn render_iface_stem(self: &Self, m: ModuleId, iface: NodeId, out: *mut char, cap: usize) usize {
        return self.render_qualified(m, unsafe (*self.mod_ast(m)).at_const(iface).as_data.interface_def.name, out, cap);
    }
    fn emit_ident_mod(self: &mut Self, m: ModuleId, name_node: NodeId) {
        let mut nm = Buf160 {};
        render_ident_src(
            self.mod_src(m),
            unsafe (*self.mod_ast(m)).at_const(name_node).as_data.name.text,
            &mut nm[0],
            160,
        );
        self.emit_cstr(&nm[0]);
    }
    fn emit_local_type_name(self: &mut Self, aggregate_name: NodeId) {
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), aggregate_name, &mut nm[0], 160);
        self.emit_cstr(&nm[0]);
    }
    fn build_enum_index(self: &mut Self) {
        let a = self.cur_ast();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = unsafe (*a).at_const(iid).as_data.aggregate.members;
                for j in 0..ms.len {
                    self.enum_of_variant.insert(unsafe (*a).list(ms)[j as usize], iid);
                }
            }
        }
    }

    // ---- String-based mangling core: unbounded composition, preallocated close to final size.
    // The out/cap wrappers below copy the result and HARD-ERROR on overflow -- never truncate.
    fn copy_sym(self: &Self, sym: &String, out: *mut char, cap: usize) {
        let n = sym.len();
        let mut m = n;
        if m + 1 > cap {
            m = cap - 1;
            let mp = (self as *const Codegen) as *mut Codegen;
            unsafe (*mp).errors.emit(
                0,
                0,
                format("internal: symbol name of {} bytes exceeds a {}-byte buffer ({})", n, cap, sym.as_str()),
            );
        }
        unsafe cstring::memcpy(out, sym.as_str().ptr(), m);
        unsafe out[m] = 0 as char;
    }
    fn mangle_type_s(self: &Self, t: TypeId) String {
        let ty = *self.type_at(t);
        if ty.kind == TypeKind::TYPE_BUILTIN {
            return String::from_cstr(builtin_name(ty.as_data.builtin));
        }
        if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM {
            let mut q = Buf256 {};
            self.render_qualified(
                ty.module,
                unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl).as_data.aggregate.name,
                &mut q[0],
                256,
            );
            return String::from_cstr(&q[0]);
        }
        if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
            let e = self.mangle_type_s(ty.as_data.elem);
            let mut o = String::with_capacity(e.len() + 4);
            o.push_str("ptr_");
            o.push_string(&e);
            return o;
        }
        if ty.kind == TypeKind::TYPE_SLICE {
            let e = self.mangle_type_s(ty.as_data.elem);
            let mut o = String::with_capacity(e.len() + 6);
            o.push_str("slice_");
            o.push_string(&e);
            return o;
        }
        if ty.kind == TypeKind::TYPE_ARRAY {
            let e = self.mangle_type_s(ty.as_data.arr.elem);
            let mut o = String::with_capacity(e.len() + 14);
            if ty.as_data.arr.len != 0 {
                o.push_str("arr");
                o.push_u64(ty.as_data.arr.len);
                o.push_str("_");
            } else {
                o.push_str("arr_");
            }
            o.push_string(&e);
            return o;
        }
        if ty.kind == TypeKind::TYPE_INSTANCE {
            return self.inst_name_s(unsafe (*self.cur_ast()).instance(ty.as_data.inst));
        }
        if ty.kind == TypeKind::TYPE_FUNCTION {
            let fd = unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl);
            let mut q = Buf256 {};
            if fd.kind == NodeKind::NODE_FUNCTION {
                self.render_qualified(ty.module, fd.as_data.function.name, &mut q[0], 256);
                return String::from_cstr(&q[0]);
            }
            if fd.kind == NodeKind::NODE_CLOSURE {
                self.closure_sym_in(ty.module, ty.as_data.decl, &mut q[0], 256);
                return String::from_cstr(&q[0]);
            }
            return format("fnt{}_{}", ty.module as u32, ty.as_data.decl);
        }
        if ty.kind == TypeKind::TYPE_DYN {
            let e = self.dyn_stem_s_dy(&ty);
            let mut o = String::with_capacity(e.len() + 6);
            if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                o.push_str("dynm_");
            } else if ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                o.push_str("dyn_");
            } else {
                o.push_str("dynb_");
            }
            o.push_string(&e);
            return o;
        }
        if ty.kind == TypeKind::TYPE_CONST {
            return format("{}", ty.as_data.value);
        }
        return String::from_str("v");
    }
    fn dyn_stem_s(self: &Self, m: ModuleId, decl: NodeId) String {
        let da = self.mod_ast(m);
        let fn2 = unsafe (*da).at_const(decl);
        if fn2.kind != NodeKind::NODE_FUNCTION_TYPE {
            let mut q = Buf256 {};
            self.render_iface_stem(m, decl, &mut q[0], 256);
            return String::from_cstr(&q[0]);
        }
        let ftp = fn2.as_data.function_type;
        let mut o = String::with_capacity(8 + ftp.params.len as usize * 20);
        o.push_str("dynfn");
        for i in 0..ftp.params.len {
            let pid = unsafe (*da).list(ftp.params)[i as usize];
            let e = self.mangle_type_s(unsafe (*self.cur_ast()).reintern(unsafe &*da, unsafe (*da).type_of(pid)));
            o.push_str("__");
            o.push_string(&e);
        }
        if ftp.returns.len == 1 {
            let r0 = unsafe (*da).list(ftp.returns)[0];
            let rn = unsafe (*da).at_const(r0);
            let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            let e = self.mangle_type_s(unsafe (*self.cur_ast()).reintern(unsafe &*da, unsafe (*da).type_of(tn)));
            o.push_str("__r_");
            o.push_string(&e);
        }
        return o;
    }
    fn inst_name_s(self: &Self, it: &TyInstance) String {
        if self.is_self_instance(it) {
            return String::from_str("NAME");
        }
        let mut q = Buf256 {};
        self.render_qualified(
            it.module,
            unsafe (*self.mod_ast(it.module)).at_const(it.decl).as_data.aggregate.name,
            &mut q[0],
            256,
        );
        let mut o = String::with_capacity(unsafe cstring::strlen(&q[0]) + 4 + it.n as usize * 20);
        o.push_str(str::from_cstr(&q[0]));
        for i in 0..it.n {
            if self.macro_mode {
                if i != 0 {
                    o.push_byte(CG_PASTE as u8);
                    o.push_str("__");
                    o.push_byte(CG_PASTE as u8);
                } else {
                    o.push_str("__");
                    o.push_byte(CG_PASTE as u8);
                }
                let mut e = Buf256 {};
                self.macro_arg_token(it.args[i as usize], &mut e[0], 176);
                o.push_str(str::from_cstr(&e[0]));
            } else {
                o.push_str("__");
                let e = self.mangle_type_s(self.subst_resolve(it.args[i as usize]));
                o.push_string(&e);
            }
        }
        return o;
    }
    // ---- type mangling ----
    fn mangle_type(self: &Self, t: TypeId, out: *mut char, cap: usize) {
        // CG-19: name memo; with no live subst and a concrete home-pool id, the render is a pure
        // function of the pool, and the inner subst_resolve calls are identity. Served by copy.
        let cacheable = self.ast == self.home_ast && self.nsubst == 0 && !self.macro_mode && self.type_is_concrete(t);
        if cacheable {
            switch self.mangle_memo.get(&(t as u64)) {
                Some(s) => {
                    self.copy_sym(s, out, cap);
                    return;
                },
                None => {},
            };
        }
        let sym = self.mangle_type_s(t);
        self.copy_sym(&sym, out, cap);
        if cacheable {
            let mp = (self as *const Codegen) as *mut Codegen;
            unsafe {
                (*mp).mangle_memo.insert(t, sym);
            }
        }
    }
    fn dyn_stem(self: &Self, m: ModuleId, decl: NodeId, out: *mut char, cap: usize) {
        let sym = self.dyn_stem_s(m, decl);
        self.copy_sym(&sym, out, cap);
    }
    // Args-aware stems: a dyn over an instantiated generic interface mangles its type arguments
    // into the stem, so Producer<i32> and Producer<u8> get distinct vt/dyn C types.
    // Map the dyn's interface generics to its instance args in self.subst (for thunk/typedef
    // member rendering); returns the saved nsubst to restore.
    fn cg_dyn_push_subst(self: &mut Self, dy: &Ty) i32 {
        let saved = self.nsubst;
        let inst = *unsafe (*self.cur_ast()).instance(dy.as_data.inst);
        if inst.n == 0 || unsafe (*self.mod_ast(inst.module)).at_const(inst.decl).kind != NodeKind::NODE_INTERFACE {
            return saved;
        }
        let ig = unsafe (*self.mod_ast(inst.module)).at_const(inst.decl).as_data.interface_def.generics;
        let gids = unsafe (*self.mod_ast(inst.module)).list(ig);
        self.nsubst = 0;
        let mut i: u32 = 0;
        while i < ig.len && i < inst.n as u32 && self.nsubst < 16 {
            self.subst[self.nsubst as usize].param = DefId { module: inst.module, node: unsafe gids[i as usize] };
            self.subst[self.nsubst as usize].concrete = inst.args[i as usize];
            self.nsubst = self.nsubst + 1;
            i = i + 1;
        }
        return saved;
    }
    // dyn_cast::<T>(d): compare the vtable's tid string against T's mangled name; Some wraps the
    // data pointer, None otherwise.
    fn emit_dyn_cast(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let arg = unsafe (*a).list(unsafe (*a).at_const(id).as_data.call.args)[0];
        let dt = self.subst_resolve(unsafe (*a).type_of(arg));
        let ot = self.subst_resolve(unsafe (*a).type_of(id));
        let oinst = *unsafe (*a).instance(self.type_at(ot).as_data.inst);
        let reft = oinst.args[0];
        let tt = self.type_at(reft).as_data.elem;
        let mut dtn = Buf256 {};
        self.render_type_id(dt, "".ptr() as *const char, &mut dtn[0], 240);
        let mut otn = Buf256 {};
        self.render_type_id(ot, "".ptr() as *const char, &mut otn[0], 240);
        let mut rfn = Buf256 {};
        self.render_type_id(reft, "".ptr() as *const char, &mut rfn[0], 240);
        let mut mt = Buf256 {};
        self.mangle_type(tt, &mut mt[0], 200);
        let hit = unsafe (*self.package).prelude_lookup("Option", true);
        let oa2 = self.mod_ast(hit.mid);
        let members = unsafe (*oa2).at_const(hit.node).as_data.aggregate.members;
        let mut some_n = NODE_NONE;
        let mut none_n = NODE_NONE;
        for i in 0..members.len {
            let vid = unsafe (*oa2).list(members)[i as usize];
            let vnm = unsafe (*oa2).at_const(unsafe (*oa2).at_const(vid).as_data.variant.name).as_data.name.text;
            if span_is(self.mod_src(hit.mid), vnm, "Some".ptr() as *const char) {
                some_n = vid;
            } else if span_is(self.mod_src(hit.mid), vnm, "None".ptr() as *const char) {
                none_n = vid;
            }
        }
        let mut tmp = Buf32 {};
        self.fresh(&mut tmp[0], 32);
        self.buf.format_into("({{ const {} {} = ", diag::cstr(&dtn[0]), diag::cstr(&tmp[0]));
        self.emit_expr(arg);
        self.buf.format_into(
            "; {}.vt->tid != 0 && strcmp({}.vt->tid, \"{}\") == 0 ? ({}){{ .tag = ",
            diag::cstr(&tmp[0]),
            diag::cstr(&tmp[0]),
            diag::cstr(&mt[0]),
            diag::cstr(&otn[0]),
        );
        self.emit_tag_mod(hit.mid, hit.node, some_n);
        self.buf.format_into(
            ", .payload.Some = {{ ({}){}.data }} }} : ({}){{ .tag = ",
            diag::cstr(&rfn[0]),
            diag::cstr(&tmp[0]),
            diag::cstr(&otn[0]),
        );
        self.emit_tag_mod(hit.mid, hit.node, none_n);
        self.emit_str(" }; })");
    }

    fn dyn_stem_s_dy(self: &Self, dy: &Ty) String {
        let inst = *unsafe (*self.cur_ast()).instance(dy.as_data.inst);
        let mut o = self.dyn_stem_s(inst.module, inst.decl);
        for i in 0..inst.n {
            let e = self.mangle_type_s(inst.args[i as usize]);
            o.push_str("__");
            o.push_string(&e);
        }
        return o;
    }
    fn dyn_stem_dy(self: &Self, dy: &Ty, out: *mut char, cap: usize) {
        let sym = self.dyn_stem_s_dy(dy);
        self.copy_sym(&sym, out, cap);
    }
    fn dyn_pair_stem_dy(self: &Self, src: TypeId, dy: &Ty, out: *mut char, cap: usize) {
        let mut sm = Buf256 {};
        let mut stem = Buf256 {};
        self.mangle_type(src, &mut sm[0], 176);
        self.dyn_stem_dy(dy, &mut stem[0], 176);
        unsafe stdio::snprintf(out, cap, "%s__%s".ptr() as *const char, &sm[0], &stem[0]);
    }
    fn dyn_pair_stem(self: &Self, src: TypeId, im: ModuleId, iface: NodeId, out: *mut char, cap: usize) {
        let mut sm = Buf256 {};
        let mut stem = Buf256 {};
        self.mangle_type(src, &mut sm[0], 176);
        self.dyn_stem(im, iface, &mut stem[0], 176);
        unsafe stdio::snprintf(out, cap, "%s__%s".ptr() as *const char, &sm[0], &stem[0]);
    }
    fn spec_name(self: &Self, fn2: DefId, args: *const TypeId, n: i32, out: *mut char, cap: usize) {
        let mut at = self.render_qualified(
            fn2.module,
            unsafe (*self.mod_ast(fn2.module)).at_const(fn2.node).as_data.function.name,
            out,
            cap,
        );
        for i in 0..n {
            at = bappend(out, cap, at, "__".ptr() as *const char);
            let mut e = Buf256 {};
            self.mangle_type(unsafe args[i as usize], &mut e[0], 176);
            at = bappend(out, cap, at, &e[0]);
        }
    }
    fn render_macro_param(self: &Self, m: ModuleId, decl: NodeId, buf: *mut char, cap: usize) usize {
        let gp = unsafe (*self.mod_ast(m)).at_const(decl);
        return render_ident_src(self.mod_src(m), self.name_span_in(m, gp.as_data.generic_param.name), buf, cap);
    }
    fn macro_arg_token(self: &Self, arg: TypeId, out: *mut char, cap: usize) {
        let y = *self.type_at(arg);
        if y.kind == TypeKind::TYPE_GENERIC {
            let at = bappend(out, cap, 0, "_SCM_".ptr() as *const char);
            self.render_macro_param(y.module, y.as_data.decl, unsafe (out + at), cap - at);
            return;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let mut pfx = "ptr_".ptr() as *const char;
            if y.kind == TypeKind::TYPE_SLICE {
                pfx = "slice_".ptr() as *const char;
            } else if y.kind == TypeKind::TYPE_ARRAY {
                pfx = "arr_".ptr() as *const char;
            }
            let mut at = bappend(out, cap, 0, pfx);
            if at < cap {
                unsafe out[at] = CG_PASTE;
                at = at + 1;
            }
            if at < cap {
                unsafe out[at] = 0 as char;
            }
            let mut rem: usize = 0;
            if cap > at {
                rem = cap - at;
            }
            self.macro_arg_token(y.as_data.elem, unsafe (out + at), rem);
            return;
        }
        self.mangle_type(arg, out, cap);
    }
    fn is_self_instance(self: &Self, it: &TyInstance) bool {
        if !self.macro_mode || it.decl != self.macro_self || it.module != self.macro_self_mod {
            return false;
        }
        let sa = self.mod_ast(self.macro_self_mod);
        let gens = unsafe (*sa).at_const(self.macro_self).as_data.aggregate.generics;
        if gens.len != it.n as u32 {
            return false;
        }
        for i in 0..it.n {
            let gid = unsafe (*sa).list(gens)[i as usize];
            let y = self.type_at(it.args[i as usize]);
            if y.kind != TypeKind::TYPE_GENERIC || y.as_data.decl != gid || y.module != self.macro_self_mod {
                return false;
            }
        }
        return true;
    }
    fn inst_name(self: &Self, it: &TyInstance, out: *mut char, cap: usize) {
        // CG-20: instance-name memo keyed by the TyInstance VALUE (args are home-pool TypeIds,
        // hence the home-ast guard); same purity argument and copy-out discipline as CG-19.
        let mut cacheable = self.ast == self.home_ast && self.nsubst == 0 && !self.macro_mode && !self.is_self_instance(
            it,
        );
        if cacheable {
            for i in 0..it.n {
                if !self.type_is_concrete(it.args[i as usize]) {
                    cacheable = false;
                }
            }
        }
        if cacheable {
            switch self.instname_memo.get(it) {
                Some(s) => {
                    self.copy_sym(s, out, cap);
                    return;
                },
                None => {},
            };
        }
        let sym = self.inst_name_s(it);
        self.copy_sym(&sym, out, cap);
        if cacheable {
            let mp = (self as *const Codegen) as *mut Codegen;
            unsafe {
                (*mp).instname_memo.insert(*it, sym);
            }
        }
    }

    // ---- monomorphization substitution ----
    fn subst_lookup(self: &Self, m: ModuleId, decl: NodeId) TypeId {
        for i in 0..self.nsubst {
            if self.subst[i as usize].param.module == m && self.subst[i as usize].param.node == decl {
                return self.subst[i as usize].concrete;
            }
        }
        return TYPE_NONE;
    }
    fn subst_resolve(self: &Self, t: TypeId) TypeId {
        if self.nsubst == 0 {
            return t;
        }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            let s = self.subst_lookup(y.module, y.as_data.decl);
            if s != TYPE_NONE {
                return s;
            }
            return t;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.subst_resolve(y.as_data.elem);
            if e == y.as_data.elem {
                return t;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            return unsafe (*self.cur_ast()).intern_type(nt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let src = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut na = TyArgs8 {};
            let mut changed = false;
            for i in 0..src.n {
                na[i as usize] = self.subst_resolve(src.args[i as usize]);
                if na[i as usize] != src.args[i as usize] {
                    changed = true;
                }
            }
            if changed {
                return unsafe (*self.cur_ast()).intern_instance(src.module, src.decl, &na[0], src.n);
            }
            return t;
        }
        return t;
    }
    // If `id` is a const-generic param bound to a value in the active subst map, write it to `out` and return true.
    fn cg_const_param_value(self: &Self, id: NodeId, out: *mut i64) bool {
        if self.nsubst == 0 {
            return false;
        }
        if unsafe (*self.cur_ast()).at_const(id).kind != NodeKind::NODE_IDENTIFIER {
            return false;
        }
        let d = unsafe (*self.cur_ast()).resolution(id);
        if d == NODE_NONE || unsafe (*self.cur_ast()).at_const(d).kind != NodeKind::NODE_GENERIC_PARAM {
            return false;
        }
        let s = self.subst_lookup(unsafe (*self.cur_ast()).module, d);
        if s == TYPE_NONE || self.type_at(s).kind != TypeKind::TYPE_CONST {
            return false;
        }
        unsafe *out = self.type_at(s).as_data.value;
        return true;
    }
    // An array-length expr's const-generic value (see cg_const_param_value); -1 if not a bound const param.
    fn cg_const_len_subst(self: &Self, length: NodeId) i64 {
        let mut v: i64 = 0;
        if self.cg_const_param_value(length, &mut v) {
            return v;
        }
        return -1;
    }
    fn type_is_concrete(self: &Self, t: TypeId) bool {
        let y = self.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            return false;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.type_is_concrete(y.as_data.elem);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            for i in 0..it.n {
                if !self.type_is_concrete(it.args[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        return true;
    }

    // ---- generic instantiation collection ----
    fn generic_call_target(self: &Self, callId: NodeId, args: *mut TypeId, n: *mut i32) DefId {
        unsafe *n = 0;
        let a = self.cur_ast();
        let call = unsafe (*a).at_const(callId);
        if call.kind != NodeKind::NODE_CALL {
            return DefId { module: 0, node: NODE_NONE };
        }
        let callee = unsafe (*a).at_const(call.as_data.call.callee);
        let mut fn2 = DefId { module: 0, node: NODE_NONE };
        if callee.kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
            fn2 = unsafe (*a).resolution_def(callee.as_data.specialization.expression);
        } else {
            fn2 = unsafe (*a).resolution_def(call.as_data.call.callee);
        }
        if fn2.node == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let fnnode = unsafe (*self.mod_ast(fn2.module)).at_const(fn2.node);
        if fnnode.kind != NodeKind::NODE_FUNCTION || fnnode.as_data.function.generics.len == 0 {
            return DefId { module: 0, node: NODE_NONE };
        }
        let mu = unsafe (*a).type_args(callId);
        if mu == null {
            return DefId { module: 0, node: NODE_NONE };
        }
        let mut i: u8 = 0;
        while i < unsafe (*mu).n && unsafe *n < 8 {
            let k = unsafe *n;
            unsafe args[k as usize] = unsafe (*mu).args[i as usize];
            unsafe *n = k + 1;
            i = i + 1;
        }
        return fn2;
    }
    fn record_inst(self: &mut Self, fn2: DefId, args: *const TypeId, n: i32, site: NodeId) {
        // CG-15: hash probe instead of the O(ninsts) dedup scan; the scan survives only as the
        // key-collision fallback, so the "exists" verdict and the append order are unchanged.
        let key = cg_inst_key(fn2, args, n);
        let mut collide = false;
        switch self.inst_idx.get(&key) {
            Some(ix) => {
                let i = (*ix) as usize;
                if self.insts[i].func.module == fn2.module && self.insts[i].func.node == fn2.node && self.insts[i].n as i32 == n {
                    let mut same = true;
                    for j in 0..n {
                        if self.insts[i].args[j as usize] != unsafe args[j as usize] {
                            same = false;
                        }
                    }
                    if same {
                        return;
                    }
                }
                collide = true;
            },
            None => {},
        };
        if collide {
            for i in 0..self.ninsts {
                if self.insts[i as usize].func.module == fn2.module && self.insts[i as usize].func.node == fn2.node && self.insts[i as usize].n as i32 == n {
                    let mut same = true;
                    for j in 0..n {
                        if self.insts[i as usize].args[j as usize] != unsafe args[j as usize] {
                            same = false;
                        }
                    }
                    if same {
                        return;
                    }
                }
            }
        }
        if self.ninsts >= 1024 {
            if !self.insts_overflow {
                self.insts_overflow = true;
                let sp = unsafe (*self.cur_ast()).at_const(site).span;
                self.errors.emit(
                    sp.start,
                    sp.end - sp.start,
                    format("codegen: too many distinct generic instantiations in one module (max {})", 1024),
                );
            }
            return;
        }
        let k = self.ninsts;
        self.insts[k as usize].func = fn2;
        self.insts[k as usize].n = n as u8;
        for j in 0..n {
            self.insts[k as usize].args[j as usize] = unsafe args[j as usize];
        }
        self.ninsts = k + 1;
        if !collide {
            self.inst_idx.insert(key, k as u32);
        }
    }
    // Does pool type `t` transitively mention a TYPE_GENERIC? Memoized in genty (0 unknown /
    // 1 no / 2 yes), valid per genty_ast.
    fn cg_mentions_generic(self: &mut Self, t: TypeId, depth: u32) bool {
        if t == TYPE_NONE || depth > 64 {
            return false;
        }
        while self.genty.len() <= t as usize {
            self.genty.push(0);
        }
        let memo = self.genty[t as usize];
        if memo != 0 {
            return memo == 2;
        }
        let y = *self.type_at(t);
        let mut r = false;
        if y.kind == TypeKind::TYPE_GENERIC {
            r = true;
        } else if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            r = self.cg_mentions_generic(y.as_data.elem, depth + 1);
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            for i in 0..it.n {
                if self.cg_mentions_generic(it.args[i as usize], depth + 1) {
                    r = true;
                }
            }
        }
        if r {
            self.genty.set(t as usize, 2);
        } else {
            self.genty.set(t as usize, 1);
        }
        return r;
    }

    fn collect_insts(self: &mut Self) {
        if self.insts_ast == self.ast {
            return; // header pass already collected for this module
        }
        self.insts_ast = self.ast;
        self.ninsts = 0;
        self.inst_idx.free();
        self.inst_idx = Map::<u64, u32>::new();
        self.clos_list.clear();
        let mut i: u32 = 1;
        while i as usize < unsafe (*self.cur_ast()).nodes.len() {
            if unsafe (*self.cur_ast()).at_const(i).kind == NodeKind::NODE_CLOSURE {
                self.clos_list.push(i);
            }
            if unsafe (*self.cur_ast()).at_const(i).kind == NodeKind::NODE_CALL {
                let mut args = TyArgs8 {};
                let mut n: i32 = 0;
                let fn2 = self.generic_call_target(i, &mut args[0], &mut n);
                if fn2.node != NODE_NONE {
                    self.record_inst(fn2, &args[0], n, i);
                }
            }
            i = i + 1;
        }
        self.expand_nested_insts();
    }
    fn expand_nested_insts(self: &mut Self) {
        // Worklist: record_inst appends while we iterate, and each new entry must itself be
        // expanded (transitive f<i32> -> g<i32> -> h<i32>), so the bound is re-read each pass
        // -- a `for` range would pin it at entry.
        let mut i: i32 = 0;
        while i < self.ninsts {
            let cur = i as usize;
            i += 1;
            let fn2 = self.insts[cur].func;
            let fn_n = self.insts[cur].n;
            let mut fargs = TyArgs8 {};
            for k in 0..fn_n {
                fargs[k as usize] = self.insts[cur].args[k as usize];
            }
            let foreign = fn2.module != self.cur_module();
            if foreign && (self.package == null || fn2.module as usize >= self.pkg_count()) {
                continue;
            }
            let home = self.ast;
            let hsrc = self.source;
            let mut oninst: usize = 0;
            if foreign {
                let owner = self.mod_ast(fn2.module);
                self.source = self.mod_src(fn2.module);
                self.borrowed = true;
                oninst = unsafe (*owner).instances.len();
                self.ast = owner;
                for kk in 0..fn_n {
                    fargs[kk as usize] = unsafe (*self.cur_ast()).reintern(unsafe &*home, fargs[kk as usize]);
                }
            }
            let fnn = unsafe (*self.cur_ast()).at_const(fn2.node);
            let fsp = fnn.span;
            let gens = fnn.as_data.function.generics;
            self.nsubst = 0;
            let mut g: u32 = 0;
            while g < gens.len && g < fn_n as u32 && self.nsubst < 16 {
                let gid = unsafe (*self.cur_ast()).list(gens)[g as usize];
                let ns = self.nsubst;
                self.subst[ns as usize].param = DefId { module: fn2.module, node: gid };
                self.subst[ns as usize].concrete = fargs[g as usize];
                self.nsubst = ns + 1;
                g = g + 1;
            }
            // CG-10: visit only NODE_CALLs (same nid order as the full arena sweep). The list is
            // cached per ast -- expand swaps to the owner ast for foreign insts, and a rebuild
            // costs the one node sweep it replaces.
            if self.call_ast != self.ast {
                self.call_ast = self.ast;
                self.call_list.clear();
                let mut cn: u32 = 1;
                while cn as usize < unsafe (*self.cur_ast()).nodes.len() {
                    if unsafe (*self.cur_ast()).at_const(cn).kind == NodeKind::NODE_CALL {
                        self.call_list.push(cn);
                    }
                    cn = cn + 1;
                }
            }
            let mut ci: usize = 0;
            while ci < self.call_list.len() {
                let nid = *self.call_list.at(ci);
                ci += 1;
                let nn = unsafe (*self.cur_ast()).at_const(nid);
                if nn.span.start < fsp.start || nn.span.end > fsp.end {
                    continue;
                }
                let mut args = TyArgs8 {};
                let mut n: i32 = 0;
                let g2 = self.generic_call_target(nid, &mut args[0], &mut n);
                if g2.node == NODE_NONE {
                    continue;
                }
                let mut concrete = true;
                for kk in 0..n {
                    args[kk as usize] = self.subst_resolve(args[kk as usize]);
                    if !self.type_is_concrete(args[kk as usize]) {
                        concrete = false;
                    }
                    if foreign {
                        args[kk as usize] = unsafe (*home).reintern(unsafe &*self.cur_ast(), args[kk as usize]);
                    }
                }
                if concrete {
                    self.record_inst(g2, &args[0], n, nid);
                }
            }
            // Seed the aggregate instances this fn's types name (e.g. a `W<T, N> {}` literal in
            // the body): the body is emitted with this subst map active, so every substitution
            // result must exist as a pool instance BEFORE phase_types defines the C structs.
            // Nested fn insts are handled by the call walk above; foreign insts are truncated
            // below and re-homed by instance propagation instead. Only generic-mentioning types
            // can substitute, so the memoized prefilter skips virtually the whole pool; the
            // bound is pinned because mid-sweep interns are substitution results (concrete).
            if !foreign {
                if self.genty_ast != self.ast {
                    self.genty_ast = self.ast;
                    self.genty.clear();
                }
                let np = unsafe (*self.cur_ast()).type_pool.len();
                let mut ti: usize = 1;
                while ti < np {
                    if self.cg_mentions_generic(ti as TypeId, 0) {
                        let _ = self.subst_resolve(ti as TypeId);
                    }
                    ti = ti + 1;
                }
            }
            self.nsubst = 0;
            if foreign {
                unsafe (*self.cur_ast()).instances.truncate(oninst);
                self.borrowed = false;
                self.ast = home;
                self.source = hsrc;
            }
        }
    }
}

extend Codegen {
    fn cg_alias_extended(self: &Self, m: ModuleId, aliasDecl: NodeId) bool {
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        // CG-4: only extends whose target resolves to aliasDecl can match.
        let mut ch = ExtChain {};
        let nchain = self.cg_ext_chain(m, aliasDecl, &mut ch[0], 64);
        let total = if nchain >= 0 {
            nchain;
        } else {
            items.len as i32;
        };
        for x in 0..total {
            let i = if nchain >= 0 {
                ch[x as usize];
            } else {
                x;
            };
            let iid = unsafe (*a).list(items)[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.target_type != NODE_NONE {
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tg.module == m && tg.node == aliasDecl {
                    return true;
                }
            }
        }
        return false;
    }
    fn cg_fn_is_capturing(self: &Self, fy: &Ty) bool {
        if fy.kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let fnn = unsafe (*self.mod_ast(fy.module)).at_const(fy.as_data.decl);
        return fnn.kind == NodeKind::NODE_CLOSURE && fnn.as_data.closure.captures.len != 0;
    }

    fn render_type_node(self: &mut Self, tn: NodeId, decl: *const char, out: *mut char, cap: usize) {
        if tn == NODE_NONE {
            buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
            return;
        }
        let a = self.cur_ast();
        let n = *unsafe (*a).at_const(tn);
        let nk = n.kind;
        if nk == NodeKind::NODE_TYPE_PATH || nk == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*a).resolution_def(tn);
            if d.node != NODE_NONE {
                let nt = unsafe (*a).type_of(tn);
                if nt != TYPE_NONE {
                    let ntk = self.type_at(nt).kind;
                    if ntk == TypeKind::TYPE_INSTANCE || ntk == TypeKind::TYPE_DYN {
                        self.render_type_id(nt, decl, out, cap);
                        return;
                    }
                }
                let mut bb: i32 = -1;
                if self.package != null {
                    bb = unsafe (*self.package).builtin_of_decl(d.module, d.node);
                }
                if bb >= 0 {
                    buf_join3(out, cap, builtin_c(bb as BuiltinType), sep(decl), decl);
                    return;
                }
                let dn = *unsafe (*self.mod_ast(d.module)).at_const(d.node);
                if dn.kind == NodeKind::NODE_STRUCT || dn.kind == NodeKind::NODE_ENUM {
                    let mut nm = Buf256 {};
                    self.render_qualified(d.module, dn.as_data.aggregate.name, &mut nm[0], 160);
                    buf_join3(out, cap, &nm[0], sep(decl), decl);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS && dn.as_data.type_alias.ty == NODE_NONE {
                    let mut nm = Buf256 {};
                    render_ident_src(
                        self.mod_src(d.module),
                        unsafe (*self.mod_ast(d.module)).at_const(dn.as_data.type_alias.name).as_data.name.text,
                        &mut nm[0],
                        160,
                    );
                    buf_join3(out, cap, &nm[0], sep(decl), decl);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS && dn.as_data.type_alias.generics.len == 0 && self.cg_alias_extended(
                    d.module,
                    d.node,
                ) {
                    let mut nm = Buf256 {};
                    self.render_qualified(d.module, dn.as_data.type_alias.name, &mut nm[0], 160);
                    buf_join3(out, cap, &nm[0], sep(decl), decl);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS && d.module == self.cur_module() {
                    self.render_type_node(dn.as_data.type_alias.ty, decl, out, cap);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS {
                    let t0 = unsafe (*self.cur_ast()).type_of(tn);
                    if t0 != TYPE_NONE {
                        self.render_type_id(t0, decl, out, cap);
                    } else {
                        // A foreign alias with no cached node type: render its body in the owner
                        // module (same switch pattern as emit_referenced_fwd).
                        let sa = self.cur_ast();
                        let ss = self.source;
                        self.source = self.mod_src(d.module);
                        self.ast = self.mod_ast(d.module);
                        self.render_type_node(dn.as_data.type_alias.ty, decl, out, cap);
                        self.ast = sa;
                        self.source = ss;
                    }
                } else if dn.kind == NodeKind::NODE_GENERIC_PARAM || dn.kind == NodeKind::NODE_INTERFACE {
                    let s = self.subst_lookup(d.module, d.node);
                    if s != TYPE_NONE {
                        self.render_type_id(s, decl, out, cap);
                    } else if self.macro_mode && dn.kind == NodeKind::NODE_GENERIC_PARAM {
                        let mut p = Buf64 {};
                        self.render_macro_param(d.module, d.node, &mut p[0], 64);
                        buf_join3(out, cap, &p[0], sep(decl), decl);
                    } else {
                        buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
                    }
                } else {
                    self.errors.emit(
                        n.span.start,
                        n.span.end - n.span.start,
                        format("codegen: opaque type is not yet supported"),
                    );
                    self.errors.note(
                        format("{}", "opaque extern types are supported through 'extern \"C\" { type Name; }' aliases"),
                    );
                    buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
                }
                return;
            }
            let mut s = n.span;
            if nk == NodeKind::NODE_TYPE_PATH {
                let parts = n.as_data.type_path.parts;
                if parts.len != 0 {
                    s = self.name_span(unsafe (*a).list(parts)[0]);
                }
            } else {
                s = n.as_data.name.text;
            }
            let b = builtin_of(self.source, s);
            if b >= 0 {
                buf_join3(out, cap, builtin_c(b as BuiltinType), sep(decl), decl);
            } else {
                self.errors.emit(
                    s.start,
                    s.end - s.start,
                    format("codegen: unresolved type '{}'", diag::span_str(self.source, s.start, s.end)),
                );
                buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
            }
            return;
        }
        if nk == NodeKind::NODE_POINTER_TYPE || nk == NodeKind::NODE_REFERENCE_TYPE {
            let it = n.as_data.indirect_type;
            let pt = unsafe (*self.cur_ast()).type_of(it.ty);
            let mut ptr = TYPE_NONE;
            if pt != TYPE_NONE {
                ptr = self.subst_resolve(pt);
            }
            if ptr != TYPE_NONE {
                let ay = *self.type_at(ptr);
                if ay.kind == TypeKind::TYPE_ARRAY && ay.as_data.arr.len != 0 {
                    let mut spiral = Buf512 {};
                    unsafe stdio::snprintf(
                        &mut spiral[0],
                        480,
                        "(*%s)[%u]".ptr() as *const char,
                        decl,
                        ay.as_data.arr.len,
                    );
                    let mut cp = it.qualifier == TypeQualifier::TYPE_QUAL_CONST;
                    if nk == NodeKind::NODE_REFERENCE_TYPE {
                        cp = it.qualifier != TypeQualifier::TYPE_QUAL_MUT;
                    }
                    let mut base = Buf512 {};
                    self.render_type_id(ay.as_data.elem, &spiral[0], &mut base[0], 512);
                    let mut pfx = "".ptr() as *const char;
                    if cp && not_const_prefixed(&base[0]) {
                        pfx = "const ".ptr() as *const char;
                    }
                    buf_join3(out, cap, pfx, "".ptr() as *const char, &base[0]);
                    return;
                }
            }
            let mut inner = Buf512 {};
            buf_join3(&mut inner[0], 480, "*".ptr() as *const char, "".ptr() as *const char, decl);
            let mut const_pointee = it.qualifier == TypeQualifier::TYPE_QUAL_CONST;
            if nk == NodeKind::NODE_REFERENCE_TYPE {
                const_pointee = it.qualifier != TypeQualifier::TYPE_QUAL_MUT;
            }
            let mut elem_is_ptr = false;
            if ptr != TYPE_NONE && self.type_at(ptr).kind == TypeKind::TYPE_POINTER {
                elem_is_ptr = true;
            }
            if const_pointee && elem_is_ptr {
                // Element is a pointer: east-const the pointer (`char *const *`), not its pointee.
                let mut cinner = Buf512 {};
                buf_join3(&mut cinner[0], 480, "const ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
                self.render_type_node(it.ty, &cinner[0], out, cap);
            } else if const_pointee {
                let mut base = Buf512 {};
                self.render_type_node(it.ty, &inner[0], &mut base[0], 512);
                let mut pfx = "const ".ptr() as *const char;
                if !not_const_prefixed(&base[0]) {
                    pfx = "".ptr() as *const char;
                }
                buf_join3(out, cap, pfx, "".ptr() as *const char, &base[0]);
            } else {
                self.render_type_node(it.ty, &inner[0], out, cap);
            }
            return;
        }
        if nk == NodeKind::NODE_SLICE_TYPE || nk == NodeKind::NODE_TUPLE_TYPE || nk == NodeKind::NODE_DYN_TYPE {
            self.render_type_id(unsafe (*self.cur_ast()).type_of(tn), decl, out, cap);
            return;
        }
        if nk == NodeKind::NODE_ARRAY_TYPE {
            let att = unsafe (*self.cur_ast()).type_of(tn);
            let mut flen: u32 = 0;
            if att != TYPE_NONE && self.type_at(att).kind == TypeKind::TYPE_ARRAY {
                flen = self.type_at(att).as_data.arr.len;
            }
            let mut inner = Buf512 {};
            let clen = if flen != 0 {
                -1i64;
            } else {
                self.cg_const_len_subst(n.as_data.array_type.length);
            };
            if flen != 0 {
                unsafe stdio::snprintf(&mut inner[0], 480, "%s[%u]".ptr() as *const char, decl, flen);
            } else if clen >= 0 {
                // Monomorphized const-generic length (e.g. `[T; N]` with N bound to a value).
                unsafe stdio::snprintf(&mut inner[0], 480, "%s[%lld]".ptr() as *const char, decl, clen);
            } else {
                let ls = unsafe (*self.cur_ast()).at_const(n.as_data.array_type.length).span;
                let mut at = bappend(&mut inner[0], 480, 0, decl);
                at = bappend(&mut inner[0], 480, at, "[".ptr() as *const char);
                at = bappend_bytes(&mut inner[0], 480, at, src_at(self.source, ls.start), (ls.end - ls.start) as usize);
                bappend(&mut inner[0], 480, at, "]".ptr() as *const char);
            }
            self.render_type_node(n.as_data.array_type.element, &inner[0], out, cap);
            return;
        }
        if nk == NodeKind::NODE_FUNCTION_TYPE {
            let ft = n.as_data.function_type;
            let mut params = Buf512 {};
            let mut k: usize = 0;
            let mut i: u32 = 0;
            while i < ft.params.len && k < 480 {
                let pid = unsafe (*self.cur_ast()).list(ft.params)[i as usize];
                let mut t = Buf256 {};
                self.render_type_node(pid, "".ptr() as *const char, &mut t[0], 256);
                if i != 0 {
                    k = bappend(&mut params[0], 480, k, ", ".ptr() as *const char);
                }
                k = bappend(&mut params[0], 480, k, &t[0]);
                i = i + 1;
            }
            let mut inner = Buf512 {};
            let mut at = bappend(&mut inner[0], 512, 0, "(*".ptr() as *const char);
            at = bappend(&mut inner[0], 512, at, decl);
            at = bappend(&mut inner[0], 512, at, ")(".ptr() as *const char);
            let mut pstr = "void".ptr() as *const char;
            if ft.params.len != 0 {
                pstr = &params[0];
            }
            at = bappend(&mut inner[0], 512, at, pstr);
            bappend(&mut inner[0], 512, at, ")".ptr() as *const char);
            if ft.returns.len == 1 {
                let r0 = unsafe (*self.cur_ast()).list(ft.returns)[0];
                let rn = unsafe (*self.cur_ast()).at_const(r0);
                let rtn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
                self.render_type_node(rtn, &inner[0], out, cap);
            } else if ft.returns.len == 0 {
                buf_join3(out, cap, "void ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
            } else {
                self.errors.emit(
                    n.span.start,
                    n.span.end - n.span.start,
                    format("codegen: multi-return function pointer is not yet supported"),
                );
                buf_join3(out, cap, "void ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
            }
            return;
        }
        self.errors.emit(n.span.start, n.span.end - n.span.start, format("codegen: unsupported type"));
        buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
    }

    fn render_type_id(self: &mut Self, t: TypeId, decl: *const char, out: *mut char, cap: usize) {
        let ty = *self.type_at(t);
        if ty.kind == TypeKind::TYPE_BUILTIN {
            buf_join3(out, cap, builtin_c(ty.as_data.builtin), sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_NEVER {
            buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM {
            let mut nm = Buf256 {};
            self.render_qualified(
                ty.module,
                unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl).as_data.aggregate.name,
                &mut nm[0],
                160,
            );
            buf_join3(out, cap, &nm[0], sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
            let el = *self.type_at(ty.as_data.elem);
            if el.kind == TypeKind::TYPE_ARRAY && el.as_data.arr.len != 0 {
                let mut inner = Buf512 {};
                unsafe stdio::snprintf(&mut inner[0], 480, "(*%s)[%u]".ptr() as *const char, decl, el.as_data.arr.len);
                let mut cp = ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8;
                if ty.kind == TypeKind::TYPE_REFERENCE {
                    cp = ty.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
                }
                let mut base = Buf512 {};
                self.render_type_id(el.as_data.elem, &inner[0], &mut base[0], 512);
                let mut pfx = "".ptr() as *const char;
                if cp && not_const_prefixed(&base[0]) {
                    pfx = "const ".ptr() as *const char;
                }
                buf_join3(out, cap, pfx, "".ptr() as *const char, &base[0]);
                return;
            }
            let mut inner = Buf512 {};
            buf_join3(&mut inner[0], 480, "*".ptr() as *const char, "".ptr() as *const char, decl);
            let mut const_pointee = ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8;
            if ty.kind == TypeKind::TYPE_REFERENCE {
                const_pointee = ty.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
            }
            let elem_is_ptr = self.type_at(self.subst_resolve(ty.as_data.elem)).kind == TypeKind::TYPE_POINTER;
            if const_pointee && elem_is_ptr {
                // The element is itself a pointer (resolve generics first): `const T` must qualify the POINTER
                // (east: `char *const *`), not its pointee (`const char **`, an illegal 2nd-level qualifier).
                let mut cinner = Buf512 {};
                buf_join3(&mut cinner[0], 480, "const ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
                self.render_type_id(ty.as_data.elem, &cinner[0], out, cap);
            } else if const_pointee {
                let mut base = Buf512 {};
                self.render_type_id(ty.as_data.elem, &inner[0], &mut base[0], 512);
                let mut pfx = "const ".ptr() as *const char;
                if !not_const_prefixed(&base[0]) {
                    pfx = "".ptr() as *const char;
                }
                buf_join3(out, cap, pfx, "".ptr() as *const char, &base[0]);
            } else {
                self.render_type_id(ty.as_data.elem, &inner[0], out, cap);
            }
        } else if ty.kind == TypeKind::TYPE_SLICE {
            buf_join3(out, cap, "SCslice".ptr() as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_ARRAY {
            let mut inner = Buf512 {};
            if ty.as_data.arr.len != 0 {
                let mut lenb = Buf32 {};
                unsafe stdio::snprintf(&mut lenb[0], 16, "[%u]".ptr() as *const char, ty.as_data.arr.len);
                buf_join3(&mut inner[0], 480, decl, "".ptr() as *const char, &lenb[0]);
            } else {
                buf_join3(&mut inner[0], 480, "*".ptr() as *const char, "".ptr() as *const char, decl);
            }
            self.render_type_id(ty.as_data.elem, &inner[0], out, cap);
        } else if ty.kind == TypeKind::TYPE_GENERIC {
            let s = self.subst_lookup(ty.module, ty.as_data.decl);
            if s != TYPE_NONE {
                self.render_type_id(s, decl, out, cap);
            } else if self.macro_mode {
                let mut p = Buf64 {};
                self.render_macro_param(ty.module, ty.as_data.decl, &mut p[0], 64);
                buf_join3(out, cap, &p[0], sep(decl), decl);
            } else {
                buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
            }
        } else if ty.kind == TypeKind::TYPE_INSTANCE {
            let mut nm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(ty.as_data.inst), &mut nm[0], 200);
            buf_join3(out, cap, &nm[0], sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_OPAQUE {
            let mut nm = Buf256 {};
            let dn = *unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl);
            render_ident_src(
                self.mod_src(ty.module),
                unsafe (*self.mod_ast(ty.module)).at_const(dn.as_data.type_alias.name).as_data.name.text,
                &mut nm[0],
                160,
            );
            buf_join3(out, cap, &nm[0], sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_FUNCTION {
            if self.cg_fn_is_capturing(&ty) {
                let mut envn = Buf256 {};
                self.closure_sym_in(ty.module, ty.as_data.decl, &mut envn[0], 240);
                let el2 = unsafe cstring::strlen(&envn[0]);
                bappend(&mut envn[0], 240, el2, "_env".ptr() as *const char);
                buf_join3(out, cap, &envn[0], sep(decl), decl);
            } else {
                self.render_fn_ptr_id(ty, decl, out, cap);
            }
        } else if ty.kind == TypeKind::TYPE_DYN {
            let mut nm = Buf256 {};
            self.dyn_stem_dy(&ty, &mut nm[0], 200);
            let dl = unsafe cstring::strlen(&nm[0]);
            bappend(&mut nm[0], 200, dl, "__dyn".ptr() as *const char);
            buf_join3(out, cap, &nm[0], sep(decl), decl);
        } else {
            buf_join3(out, cap, "void".ptr() as *const char, sep(decl), decl);
        }
    }

    fn render_fn_ptr_id(self: &mut Self, fy: Ty, decl: *const char, out: *mut char, cap: usize) {
        let fa = self.mod_ast(fy.module);
        let fnn = *unsafe (*fa).at_const(fy.as_data.decl);
        let mut ps = NodeList { start: 0, len: 0 };
        let mut rs = NodeList { start: 0, len: 0 };
        let mut body = NODE_NONE;
        if fnn.kind == NodeKind::NODE_FUNCTION {
            ps = fnn.as_data.function.params;
            rs = fnn.as_data.function.returns;
        } else if fnn.kind == NodeKind::NODE_CLOSURE {
            ps = fnn.as_data.closure.params;
            rs = fnn.as_data.closure.returns;
            if fnn.as_data.closure.expr_body {
                body = fnn.as_data.closure.body;
            }
        } else {
            ps = fnn.as_data.function_type.params;
            rs = fnn.as_data.function_type.returns;
        }
        let mut params = Buf512 {};
        let mut k: usize = 0;
        let mut i: u32 = 0;
        while i < ps.len && k < 480 {
            let pid = unsafe (*fa).list(ps)[i as usize];
            let pn = unsafe (*fa).at_const(pid);
            let mut tn = pid;
            if pn.kind == NodeKind::NODE_PARAMETER {
                tn = pn.as_data.parameter.ty;
            }
            let mut anchor = tn;
            if tn == NODE_NONE {
                anchor = pid;
            }
            let mut tt = Buf256 {};
            self.render_type_id(
                unsafe (*self.cur_ast()).reintern(unsafe &*fa, unsafe (*fa).type_of(anchor)),
                "".ptr() as *const char,
                &mut tt[0],
                256,
            );
            if i != 0 {
                k = bappend(&mut params[0], 480, k, ", ".ptr() as *const char);
            }
            k = bappend(&mut params[0], 480, k, &tt[0]);
            i = i + 1;
        }
        let mut inner = Buf512 {};
        let mut at = bappend(&mut inner[0], 512, 0, "(*".ptr() as *const char);
        at = bappend(&mut inner[0], 512, at, decl);
        at = bappend(&mut inner[0], 512, at, ")(".ptr() as *const char);
        let mut pstr = "void".ptr() as *const char;
        if ps.len != 0 {
            pstr = &params[0];
        }
        at = bappend(&mut inner[0], 512, at, pstr);
        bappend(&mut inner[0], 512, at, ")".ptr() as *const char);
        let mut rt = TYPE_NONE;
        if rs.len == 1 {
            let r0 = unsafe (*fa).list(rs)[0];
            let rn = unsafe (*fa).at_const(r0);
            let rtn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            rt = unsafe (*self.cur_ast()).reintern(unsafe &*fa, unsafe (*fa).type_of(rtn));
        } else if body != NODE_NONE {
            rt = unsafe (*self.cur_ast()).reintern(unsafe &*fa, unsafe (*fa).type_of(body));
        }
        if rt != TYPE_NONE {
            self.render_type_id(rt, &inner[0], out, cap);
        } else {
            buf_join3(out, cap, "void ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
        }
    }
}

extend Codegen {
    // ---- enum index / tags ----
    fn enclosing_enum(self: &Self, variant: NodeId) NodeId {
        switch self.enum_of_variant.get(&variant) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        return NODE_NONE;
    }
    fn enclosing_enum_in(self: &Self, m: ModuleId, variant: NodeId) NodeId {
        if m == self.cur_module() && !self.borrowed {
            return self.enclosing_enum(variant);
        }
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = unsafe (*a).at_const(iid).as_data.aggregate.members;
                for j in 0..ms.len {
                    if unsafe (*a).list(ms)[j as usize] == variant {
                        return iid;
                    }
                }
            }
        }
        return NODE_NONE;
    }
    fn emit_tag_mod(self: &mut Self, m: ModuleId, enum_decl: NodeId, variant: NodeId) {
        let src = self.mod_src(m);
        let mut pfx = Buf64 {};
        self.render_modpfx(m, &mut pfx[0], 64);
        self.emit_cstr(&pfx[0]);
        let es = self.name_span_in(m, unsafe (*self.mod_ast(m)).at_const(enum_decl).as_data.aggregate.name);
        self.emit_bytes(src_at(src, es.start), (es.end - es.start) as usize);
        self.emit_str("_");
        let vs = self.name_span_in(m, unsafe (*self.mod_ast(m)).at_const(variant).as_data.variant.name);
        self.emit_bytes(src_at(src, vs.start), (vs.end - vs.start) as usize);
    }
    fn emit_tag(self: &mut Self, enum_decl: NodeId, variant: NodeId) {
        self.emit_tag_mod(self.cur_module(), enum_decl, variant);
    }
    fn render_variant_name(self: &Self, m: ModuleId, variant: NodeId, buf: *mut char, cap: usize) {
        render_ident_src(
            self.mod_src(m),
            self.name_span_in(m, unsafe (*self.mod_ast(m)).at_const(variant).as_data.variant.name),
            buf,
            cap,
        );
    }
    fn aggregate_has_payload_in(self: &Self, m: ModuleId, enum_decl: NodeId) bool {
        let a = self.mod_ast(m);
        let members = unsafe (*a).at_const(enum_decl).as_data.aggregate.members;
        for i in 0..members.len {
            if unsafe (*a).at_const(unsafe (*a).list(members)[i as usize]).as_data.variant.payload.len > 0 {
                return true;
            }
        }
        return false;
    }
    fn aggregate_has_payload(self: &Self, enum_decl: NodeId) bool {
        return self.aggregate_has_payload_in(self.cur_module(), enum_decl);
    }

    // ---- type peeling ----
    fn strip_ptr(self: &Self, t0: TypeId) TypeId {
        let mut t = t0;
        let mut y = self.type_at(t);
        while y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            t = y.as_data.elem;
            y = self.type_at(t);
        }
        return t;
    }
    fn strip_ref_only(self: &Self, t0: TypeId) TypeId {
        let mut t = t0;
        let mut y = self.type_at(t);
        while y.kind == TypeKind::TYPE_REFERENCE {
            t = y.as_data.elem;
            y = self.type_at(t);
        }
        if y.kind == TypeKind::TYPE_POINTER {
            return TYPE_NONE;
        }
        return t;
    }
    fn cg_ref_depth(self: &Self, t: TypeId) i32 {
        let mut d: i32 = 0;
        let mut y = self.type_at(t);
        while y.kind == TypeKind::TYPE_REFERENCE {
            d = d + 1;
            y = self.type_at(y.as_data.elem);
        }
        return d;
    }

    // ---- Free / ownership detection ----
    fn cg_fn_owns(self: &mut Self, fy: &Ty) bool {
        if fy.kind != TypeKind::TYPE_FUNCTION {
            return false;
        }
        let fa = self.mod_ast(fy.module);
        let fnn = *unsafe (*fa).at_const(fy.as_data.decl);
        if fnn.kind != NodeKind::NODE_CLOSURE {
            return false;
        }
        let caps = fnn.as_data.closure.captures;
        let mut_caps = fnn.as_data.closure.mut_caps as u64;
        for i in 0..caps.len {
            let cid = unsafe (*fa).list(caps)[i as usize];
            if (mut_caps >> i as u64 & 1u64) == 0 {
                let rt = unsafe (*self.cur_ast()).reintern(unsafe &*fa, unsafe (*fa).type_of(cid));
                if self.cg_type_is_free(rt) {
                    return true;
                }
            }
        }
        return false;
    }
    // CG-8: the Slice/SliceMut/Range DefIds are constants per package; resolve them once
    // instead of a prelude_lookup linear scan per indexed/ranged expression.
    fn cg_prelude_hits(self: &Self) {
        if self.ph_set {
            return;
        }
        let mp = (self as *const Codegen) as *mut Codegen;
        unsafe {
            (*mp).ph_slice = (*self.package).prelude_lookup("Slice", true);
            (*mp).ph_slicemut = (*self.package).prelude_lookup("SliceMut", true);
            (*mp).ph_range = (*self.package).prelude_lookup("Range", true);
            (*mp).ph_set = true;
        }
    }
    fn cg_slice_elem(self: &Self, tid: TypeId, elem: *mut TypeId) bool {
        if self.package == null {
            return false;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        self.cg_prelude_hits();
        let is_slice = it.module == self.ph_slice.mid && it.decl == self.ph_slice.node || it.module == self.ph_slicemut.mid && it.decl == self.ph_slicemut.node;
        if is_slice && it.n == 1 && elem != null {
            unsafe *elem = it.args[0];
        }
        return is_slice && it.n == 1;
    }
    fn cg_range_elem(self: &Self, tid: TypeId, elem: *mut TypeId) bool {
        if self.package == null {
            return false;
        }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        self.cg_prelude_hits();
        let is_range = it.n == 1 && it.module == self.ph_range.mid && it.decl == self.ph_range.node;
        if is_range && elem != null {
            unsafe *elem = it.args[0];
        }
        return is_range;
    }
    fn cg_free_extend(self: &Self, tmod: ModuleId, tdecl: NodeId) DefId {
        let key = tmod as u64 << 32 | tdecl as u64;
        return switch self.free_ext_cache.get(&key) {
            Some(d) => *d,
            None => {
                let r = self.cg_free_extend_uncached(tmod, tdecl);
                let mp = (self as *const Codegen) as *mut Codegen;
                unsafe {
                    (*mp).free_ext_cache.insert(key, r);
                }
                r;
            },
        };
    }
    fn cg_free_extend_uncached(self: &Self, tmod: ModuleId, tdecl: NodeId) DefId {
        let mut ns = 1;
        if tmod != self.cur_module() {
            ns = 2;
        }
        for s in 0..ns {
            let mut m = tmod;
            if s == 1 {
                m = self.cur_module();
            }
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*a).list(items)[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.interface_type != NODE_NONE && it.as_data.extend_def.target_type != NODE_NONE {
                    let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                    if tg.module == tmod && tg.node == tdecl {
                        let tr = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                        if tr.node != NODE_NONE {
                            let trn = unsafe (*self.mod_ast(tr.module)).at_const(tr.node);
                            if trn.kind == NodeKind::NODE_INTERFACE && span_is(
                                self.mod_src(tr.module),
                                unsafe (*self.mod_ast(tr.module)).at_const(trn.as_data.interface_def.name).as_data.name.text,
                                "Free".ptr() as *const char,
                            ) {
                                return DefId { module: m, node: iid };
                            }
                        }
                    }
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_free_method(self: &Self, tmod: ModuleId, tdecl: NodeId) DefId {
        let ext = self.cg_free_extend(tmod, tdecl);
        if ext.node == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let a = self.mod_ast(ext.module);
        let ms = unsafe (*a).at_const(ext.node).as_data.extend_def.items;
        for j in 0..ms.len {
            let mid = unsafe (*a).list(ms)[j as usize];
            let mn = unsafe (*a).at_const(mid);
            if mn.kind == NodeKind::NODE_FUNCTION && span_is(
                self.mod_src(ext.module),
                unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text,
                "free".ptr() as *const char,
            ) {
                return DefId { module: ext.module, node: mid };
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.mod_ast(m);
        let bs = unsafe (*a).at_const(gp).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let bd = unsafe (*a).resolution_def(unsafe (*a).list(bs)[i as usize]);
            if bd.node != NODE_NONE {
                let bn = unsafe (*self.mod_ast(bd.module)).at_const(bd.node);
                if bn.kind == NodeKind::NODE_INTERFACE && span_is(
                    self.mod_src(bd.module),
                    unsafe (*self.mod_ast(bd.module)).at_const(bn.as_data.interface_def.name).as_data.name.text,
                    "Free".ptr() as *const char,
                ) {
                    return true;
                }
            }
        }
        return false;
    }
    fn cg_type_is_free(self: &mut Self, ty0: TypeId) bool {
        let rt = self.subst_resolve(ty0);
        // CG-14: memo on the resolved id; home pool + concrete only (CG-5's rules), so the
        // verdict is a pure function of frozen decls and never needs resetting.
        let cacheable = self.ast == self.home_ast && !self.cg_mentions_generic(rt, 0);
        if cacheable {
            switch self.free_memo.get(&(rt as u64)) {
                Some(v) => {
                    return *v == 2;
                },
                None => {},
            };
        }
        let res = self.cg_type_is_free_uncached(rt);
        if cacheable {
            let mut enc: u64 = 1;
            if res {
                enc = 2;
            }
            self.free_memo.insert(rt, enc);
        }
        return res;
    }
    fn cg_type_is_free_uncached(self: &mut Self, rt: TypeId) bool {
        let y = *self.type_at(rt);
        if y.kind == TypeKind::TYPE_FUNCTION {
            return self.cg_fn_owns(&y);
        }
        if y.kind == TypeKind::TYPE_DYN {
            return y.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8;
        }
        if y.kind == TypeKind::TYPE_STRUCT {
            return self.cg_free_method(y.module, y.as_data.decl).node != NODE_NONE;
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let ii = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
        let ext = self.cg_free_extend(ii.module, ii.decl);
        if ext.node == NODE_NONE {
            return false;
        }
        let ia = self.mod_ast(ext.module);
        let gens = unsafe (*ia).at_const(ext.node).as_data.extend_def.generics;
        let mut i: u32 = 0;
        while i < gens.len && i as u8 < ii.n {
            let gid = unsafe (*ia).list(gens)[i as usize];
            if self.cg_param_has_free_bound(ext.module, gid) && !self.cg_type_is_free(ii.args[i as usize]) {
                return false;
            }
            i = i + 1;
        }
        return true;
    }
    fn cg_is_moved(self: &Self, decl: NodeId) bool {
        if decl as usize < self.stamp_cap {
            return unsafe self.moved_stamp[decl as usize] == self.move_epoch;
        }
        for i in 0..self.nmoved {
            if self.moved[i as usize] == decl {
                return true;
            }
        }
        return false;
    }
    fn cg_is_cond_moved(self: &Self, decl: NodeId) bool {
        if decl as usize < self.stamp_cap {
            return unsafe self.cond_stamp[decl as usize] == self.move_epoch;
        }
        for i in 0..self.ncond_moved {
            if self.cond_moved[i as usize] == decl {
                return true;
            }
        }
        return false;
    }
    // CG-12: bump the epoch (and size the stamp arrays for the current arena) at the same
    // point the move arrays are cleared -- emit_function's per-body reset.
    fn cg_move_stamps_reset(self: &mut Self) {
        let need = unsafe (*self.cur_ast()).nodes.len();
        if need > self.stamp_cap {
            if self.moved_stamp != null {
                unsafe stdlib::free(self.moved_stamp);
            }
            if self.cond_stamp != null {
                unsafe stdlib::free(self.cond_stamp);
            }
            self.moved_stamp = (unsafe stdlib::calloc(need, 4)) as *mut u32;
            self.cond_stamp = (unsafe stdlib::calloc(need, 4)) as *mut u32;
            if self.moved_stamp == null || self.cond_stamp == null {
                if self.moved_stamp != null {
                    unsafe stdlib::free(self.moved_stamp);
                }
                if self.cond_stamp != null {
                    unsafe stdlib::free(self.cond_stamp);
                }
                self.moved_stamp = null;
                self.cond_stamp = null;
                self.stamp_cap = 0;
            } else {
                self.stamp_cap = need;
            }
        }
        self.move_epoch = self.move_epoch + 1;
    }
    fn cg_is_cond_site(self: &Self, expr: NodeId) bool {
        for i in 0..self.ncond_sites {
            if self.cond_sites[i as usize] == expr {
                return true;
            }
        }
        return false;
    }

    // ---- method lookup ----
    // CG-4 builder: index module m's extend items by resolved target node. Reverse iteration
    // prepends, so each chain ends up in item order. m must be < 64 (caller-checked).
    fn cg_ext_index(self: &Self, m: ModuleId) {
        let bit = 1u64 << m as u64;
        if (self.ext_built & bit) != 0 {
            return;
        }
        let mp = (self as *const Codegen) as *mut Codegen;
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let ids = unsafe (*a).list(items);
        let mut i = items.len as i32 - 1;
        while i >= 0 {
            let iid = unsafe ids[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.target_type != NODE_NONE {
                let tg = unsafe (*a).resolution(it.as_data.extend_def.target_type);
                if tg != NODE_NONE {
                    let key = m as u64 << 32 | tg as u64;
                    switch self.ext_head.get(&key) {
                        Some(h) => {
                            unsafe {
                                (*mp).ext_next.insert(m as u64 << 32 | i as u64, *h);
                            }
                        },
                        _ => {},
                    };
                    unsafe {
                        (*mp).ext_head.insert(key, i as u32);
                    }
                }
            }
            i -= 1;
        }
        unsafe {
            (*mp).ext_built = self.ext_built | bit;
        }
    }
    // Collect the item positions of module m's extends whose resolved target node == tdecl into
    // out[0..cap), in item order. Returns the count, or -1 when the caller must fall back to a
    // full item scan (module beyond the bitmask, or chain overflow).
    fn cg_ext_chain(self: &Self, m: ModuleId, tdecl: NodeId, out: *mut i32, cap: i32) i32 {
        if m as u32 >= 64 {
            return -1;
        }
        self.cg_ext_index(m);
        let mut n: i32 = 0;
        let mut pos = switch self.ext_head.get(&(m as u64 << 32 | tdecl as u64)) {
            Some(h) => (*h) as i32,
            None => -1,
        };
        while pos >= 0 {
            if n >= cap {
                return -1;
            }
            unsafe out[n as usize] = pos;
            n += 1;
            pos = (switch self.ext_next.get(&(m as u64 << 32 | pos as u64)) {
                Some(h) => (*h) as i32,
                None => -1,
            });
        }
        return n;
    }
    fn cg_find_method_impl(self: &Self, tmod: ModuleId, tdecl: NodeId, nsrc: str, name: tok::Span, lit: *const char) DefId {
        let mut scopes = ScopeArr {};
        let mut ns: i32 = 0;
        scopes[0] = tmod;
        ns = 1;
        if self.cur_module() != tmod {
            scopes[ns as usize] = self.cur_module();
            ns = ns + 1;
        }
        if self.dflt_home_set && self.dflt_home != tmod && self.dflt_home != self.cur_module() {
            scopes[ns as usize] = self.dflt_home;
            ns = ns + 1;
        }
        for s in 0..ns {
            let m = scopes[s as usize];
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            // CG-4: only extends whose target resolves to tdecl can match; walk that chain.
            let mut ch = ExtChain {};
            let nchain = self.cg_ext_chain(m, tdecl, &mut ch[0], 64);
            let total = if nchain >= 0 {
                nchain;
            } else {
                items.len as i32;
            };
            for x in 0..total {
                let i = if nchain >= 0 {
                    ch[x as usize];
                } else {
                    x;
                };
                let iid = unsafe (*a).list(items)[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.target_type != NODE_NONE {
                    let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                    if tg.module == tmod && tg.node == tdecl {
                        let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                        for j in 0..ms.len {
                            let mid = unsafe (*a).list(ms)[j as usize];
                            let mn = unsafe (*a).at_const(mid);
                            if mn.kind == NodeKind::NODE_FUNCTION {
                                let mname = unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text;
                                let mut hit = false;
                                if lit != null {
                                    hit = span_is(self.mod_src(m), mname, lit);
                                } else {
                                    hit = spans_eq2(nsrc, name, self.mod_src(m), mname);
                                }
                                if hit {
                                    return DefId { module: m, node: mid };
                                }
                            }
                        }
                    }
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_find_method(self: &Self, tmod: ModuleId, tdecl: NodeId, nsrc: str, name: tok::Span) DefId {
        return self.cg_find_method_impl(tmod, tdecl, nsrc, name, null);
    }
    fn cg_find_method_cstr(self: &Self, tmod: ModuleId, tdecl: NodeId, lit: *const char) DefId {
        return self.cg_find_method_impl(tmod, tdecl, "", tok::Span::empty(), lit);
    }

    // CG-1: a conservative, allocation-free "could this node fold?" pre-filter. Returns false ONLY when the
    // node is PROVABLY a runtime value, so the hot const-ness probes can skip the eval() call. It mirrors the
    // consteval interpreter's nil-propagation on the f==null (codegen) path EXACTLY: a compound folds only if
    // all its operands could, and a name folds only to a fn / valid non-static-mut const (unresolved / unknown
    // kinds stay conservative TRUE). Invariant: cg_maybe_const(id)==false => eval(id)==CONST_NONE, so gating a
    // probe with `&& cg_maybe_const(id)` never suppresses a real fold -> emitted C stays byte-identical.
    fn cg_def_const_ok(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE {
            return true;
        }
        if d.module as usize >= unsafe (*self.package).modules.len() {
            return true;
        }
        let dk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
        if dk == NodeKind::NODE_FUNCTION || dk == NodeKind::NODE_VARIANT {
            return true;
        }
        if dk == NodeKind::NODE_CONST {
            let cd = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def;
            return cd.value != NODE_NONE && !cd.is_static_mut;
        }
        return false;
    }
    // Probe-root gate: emit-time folding can only USE scalar results (emit_scalar_folded), so
    // evaluating an expression whose static type is an aggregate is pure waste — the interpreter
    // would run the whole body and the CONST_NONE publication discards it. Applies at probe roots
    // only (a scalar call may take aggregate-typed constant arguments).
    fn cg_fold_worthwhile(self: &Self, id: NodeId) bool {
        let t = unsafe (*self.cur_ast()).type_of(id);
        if t == TYPE_NONE {
            return false;
        }
        let y = self.type_at(self.subst_resolve(t));
        if y.kind == TypeKind::TYPE_ENUM {
            return true; // payload-less tags fold to their integer value
        }
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let b = y.as_data.builtin;
        return b != BuiltinType::BT_VOID && b != BuiltinType::BT_VALIST && b != BuiltinType::BT_C32 && b != BuiltinType::BT_C64;
    }

    fn cg_maybe_const(self: &Self, id: NodeId) bool {
        if id == NODE_NONE {
            return true;
        }
        let a = self.cur_ast();
        let n = *unsafe (*a).at_const(id);
        let k = n.kind;
        if k == NodeKind::NODE_LITERAL || k == NodeKind::NODE_SIZEOF || k == NodeKind::NODE_ALIGNOF {
            return true;
        }
        if k == NodeKind::NODE_BINARY {
            return self.cg_maybe_const(n.as_data.binary.left) && self.cg_maybe_const(n.as_data.binary.right);
        }
        if k == NodeKind::NODE_UNARY {
            return self.cg_maybe_const(n.as_data.unary.operand);
        }
        if k == NodeKind::NODE_CAST {
            return self.cg_maybe_const(n.as_data.cast.expression);
        }
        if k == NodeKind::NODE_INDEX {
            return self.cg_maybe_const(n.as_data.index.object) && self.cg_maybe_const(n.as_data.index.index);
        }
        if k == NodeKind::NODE_CALL {
            if !self.cg_maybe_const(n.as_data.call.callee) {
                return false;
            }
            let args = n.as_data.call.args;
            let ids = unsafe (*a).list(args);
            for i in 0..args.len {
                if !self.cg_maybe_const(unsafe ids[i as usize]) {
                    return false;
                }
            }
            return true;
        }
        if k == NodeKind::NODE_IDENTIFIER {
            let mut d = unsafe (*a).resolution_def(id);
            if d.node == NODE_NONE {
                d = DefId { module: unsafe (*a).module, node: unsafe (*a).resolution(id) };
            }
            return self.cg_def_const_ok(d);
        }
        if k == NodeKind::NODE_MEMBER {
            if n.as_data.member.path {
                let mut d = unsafe (*a).resolution_def(id);
                if d.node == NODE_NONE {
                    d = unsafe (*a).resolution_def(n.as_data.member.member);
                }
                return self.cg_def_const_ok(d);
            }
            return self.cg_maybe_const(n.as_data.member.object);
        }
        return true;
    }

    // Safe to emit more than once: a place built only from identifiers, members, and derefs.
    // Anything effectful or checked (calls, indexes, ...) must be materialized instead.
    fn cg_pure_place(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_IDENTIFIER {
            return true;
        }
        if n.kind == NodeKind::NODE_MEMBER {
            return n.as_data.member.path || self.cg_pure_place(n.as_data.member.object);
        }
        if n.kind == NodeKind::NODE_UNARY {
            let op = n.as_data.unary.op;
            if op == TokenType::Star || op == TokenType::Move || op == TokenType::Unsafe {
                return self.cg_pure_place(n.as_data.unary.operand);
            }
        }
        return false;
    }
    fn is_lvalue(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_INDEX {
            return true;
        }
        if n.kind == NodeKind::NODE_MEMBER {
            return !n.as_data.member.path;
        }
        if n.kind == NodeKind::NODE_UNARY {
            if n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe {
                return self.is_lvalue(n.as_data.unary.operand);
            }
            return n.as_data.unary.op == TokenType::Star;
        }
        return false;
    }
}

// ---- free helpers ----
// CG-15: FNV-1a key of a generic instantiation (func identity + arg TypeIds).
fn cg_inst_key(fn2: DefId, args: *const TypeId, n: i32) u64 {
    let mut h: u64 = 14695981039346656037;
    h = (h ^ fn2.module as u64) * 1099511628211;
    h = (h ^ fn2.node as u64) * 1099511628211;
    h = (h ^ n as u64) * 1099511628211;
    for j in 0..n {
        h = (h ^ (unsafe args[j as usize]) as u64) * 1099511628211;
    }
    return h;
}
const fn if_node(c: bool, a: NodeId, b: NodeId) NodeId {
    if c {
        return a;
    }
    return b;
}
pub type ScopeArr = Array<ModuleId, 3>;

fn cg_move_flag(out: *mut char, cap: usize, decl: NodeId) {
    unsafe stdio::snprintf(out, cap, "__mv%u".ptr() as *const char, decl);
}
const fn ref_derefs(d0: i32) *const char {
    let mut d = d0;
    if d < 1 {
        d = 1;
    } else if d > 7 {
        d = 7;
    }
    // C: `s + sizeof s - d` over "*******" (sizeof 8, incl NUL) -> (d-1) asterisks; ref_derefs(1) == "".
    return (unsafe ("*******".ptr() + (8 - d) as usize)) as *const char;
}
const fn c_op(t: TokenType) *const char {
    if t == TokenType::Plus {
        return "+".ptr() as *const char;
    }
    if t == TokenType::Minus {
        return "-".ptr() as *const char;
    }
    if t == TokenType::Star {
        return "*".ptr() as *const char;
    }
    if t == TokenType::Slash {
        return "/".ptr() as *const char;
    }
    if t == TokenType::Percent {
        return "%".ptr() as *const char;
    }
    if t == TokenType::Ampersand {
        return "&".ptr() as *const char;
    }
    if t == TokenType::Pipe {
        return "|".ptr() as *const char;
    }
    if t == TokenType::Caret {
        return "^".ptr() as *const char;
    }
    if t == TokenType::LeftShift {
        return "<<".ptr() as *const char;
    }
    if t == TokenType::RightShift {
        return ">>".ptr() as *const char;
    }
    if t == TokenType::AmpersandAmpersand {
        return "&&".ptr() as *const char;
    }
    if t == TokenType::PipePipe {
        return "||".ptr() as *const char;
    }
    if t == TokenType::EqualEqual {
        return "==".ptr() as *const char;
    }
    if t == TokenType::BangEqual {
        return "!=".ptr() as *const char;
    }
    if t == TokenType::LessThan {
        return "<".ptr() as *const char;
    }
    if t == TokenType::LessThanEqual {
        return "<=".ptr() as *const char;
    }
    if t == TokenType::GreaterThan {
        return ">".ptr() as *const char;
    }
    if t == TokenType::GreaterThanEqual {
        return ">=".ptr() as *const char;
    }
    if t == TokenType::Equal {
        return "=".ptr() as *const char;
    }
    if t == TokenType::PlusEqual {
        return "+=".ptr() as *const char;
    }
    if t == TokenType::MinusEqual {
        return "-=".ptr() as *const char;
    }
    if t == TokenType::StarEqual {
        return "*=".ptr() as *const char;
    }
    if t == TokenType::SlashEqual {
        return "/=".ptr() as *const char;
    }
    if t == TokenType::PercentEqual {
        return "%=".ptr() as *const char;
    }
    if t == TokenType::AmpersandEqual {
        return "&=".ptr() as *const char;
    }
    if t == TokenType::PipeEqual {
        return "|=".ptr() as *const char;
    }
    if t == TokenType::CaretEqual {
        return "^=".ptr() as *const char;
    }
    if t == TokenType::LeftShiftEqual {
        return "<<=".ptr() as *const char;
    }
    if t == TokenType::RightShiftEqual {
        return ">>=".ptr() as *const char;
    }
    if t == TokenType::Bang {
        return "!".ptr() as *const char;
    }
    if t == TokenType::Tilde {
        return "~".ptr() as *const char;
    }
    return "?".ptr() as *const char;
}
// Compound-assignment token -> arithmetic overload method ("+=" -> add); null = not overloadable
// (bitwise/shift compounds are integer-gated by the typechecker and never reach a struct).
const fn cg_compound_method(op: TokenType) *const char {
    if op == TokenType::PlusEqual {
        return "add".ptr() as *const char;
    }
    if op == TokenType::MinusEqual {
        return "sub".ptr() as *const char;
    }
    if op == TokenType::StarEqual {
        return "mul".ptr() as *const char;
    }
    if op == TokenType::SlashEqual {
        return "div".ptr() as *const char;
    }
    if op == TokenType::PercentEqual {
        return "rem".ptr() as *const char;
    }
    return null;
}

const fn cg_arith_op_method(op: TokenType) *const char {
    if op == TokenType::Plus {
        return "add".ptr() as *const char;
    }
    if op == TokenType::Minus {
        return "sub".ptr() as *const char;
    }
    if op == TokenType::Star {
        return "mul".ptr() as *const char;
    }
    if op == TokenType::Slash {
        return "div".ptr() as *const char;
    }
    if op == TokenType::Percent {
        return "rem".ptr() as *const char;
    }
    return null;
}
const fn hex_val(ch: u8) i32 {
    if ch >= b'0' && ch <= b'9' {
        return ch - b'0';
    }
    if ch >= b'a' && ch <= b'f' {
        return (ch - b'a') as i32 + 10;
    }
    if ch >= b'A' && ch <= b'F' {
        return (ch - b'A') as i32 + 10;
    }
    return 0;
}
fn utf8_encode(cp: u32, out: *mut u8) i32 {
    if cp < 0x80 {
        unsafe out[0] = cp as u8;
        return 1;
    }
    if cp < 0x800 {
        unsafe out[0] = (0xC0u32 | cp >> 6) as u8;
        unsafe out[1] = (0x80u32 | cp & 0x3Fu32) as u8;
        return 2;
    }
    if cp < 0x10000 {
        unsafe out[0] = (0xE0u32 | cp >> 12) as u8;
        unsafe out[1] = (0x80u32 | cp >> 6 & 0x3Fu32) as u8;
        unsafe out[2] = (0x80u32 | cp & 0x3Fu32) as u8;
        return 3;
    }
    unsafe out[0] = (0xF0u32 | cp >> 18) as u8;
    unsafe out[1] = (0x80u32 | cp >> 12 & 0x3Fu32) as u8;
    unsafe out[2] = (0x80u32 | cp >> 6 & 0x3Fu32) as u8;
    unsafe out[3] = (0x80u32 | cp & 0x3Fu32) as u8;
    return 4;
}
const fn raw_string_content(src: str, s: tok::Span) tok::Span {
    let mut i = s.start + 1;
    let mut h: u32 = 0;
    while src[i as usize] == b'#' {
        i = i + 1;
        h = h + 1;
    }
    return tok::Span { start: i + 1, end: s.end - 1 - h };
}

extend Codegen {
    fn emit_number(self: &mut Self, s: tok::Span, tt: TokenType, rb: BuiltinType) {
        let mut sfx = s.end;
        let sb = unsafe ast_numeric_suffix(self.source, s.start, s.end, &mut sfx);
        let mut eb = sb;
        if sb == BuiltinType::BT_COUNT {
            if tt == TokenType::IntegerLiteral {
                eb = rb;
            } else {
                eb = BuiltinType::BT_COUNT;
            }
        }
        let mut buf = Buf256 {};
        let mut n: usize = 0;
        let mut i = s.start;
        while i < sfx && n < 255 {
            if self.source[i as usize] != b'_' {
                buf[n] = self.source[i as usize] as char;
                n = n + 1;
            }
            i = i + 1;
        }
        buf[n] = 0 as char;
        let bufp = (&buf[0]) as *const char;
        if tt == TokenType::IntegerLiteral && n >= 2 && buf[0] == '0' as char {
            let k = buf[1];
            if k == 'b' as char || k == 'B' as char {
                let mut v: u64 = 0;
                let mut j: usize = 2;
                while j < n {
                    v = v << 1 | (buf[j] as u8 - b'0') as u64;
                    j = j + 1;
                }
                if v > 0x7FFFFFFFFFFFFFFFu64 && eb == BuiltinType::BT_COUNT {
                    self.buf.format_into("{}ull", v);
                } else {
                    self.buf.format_into("{}", v);
                }
            } else if k == 'o' as char || k == 'O' as char {
                self.buf.format_into("0{}", diag::cstr(unsafe (bufp + 2)));
            } else if k == 'x' as char || k == 'X' as char {
                self.emit_cstr(bufp);
            } else {
                let mut z: usize = 0;
                while z + 1 < n && buf[z] == '0' as char {
                    z = z + 1;
                }
                self.emit_cstr(unsafe (bufp + z));
                if eb == BuiltinType::BT_COUNT && unsafe strtoull(unsafe (bufp + z), null, 10) > 0x7FFFFFFFFFFFFFFFu64 {
                    self.emit_str("ull");
                }
            }
        } else if tt == TokenType::IntegerLiteral && eb == BuiltinType::BT_COUNT && unsafe strtoull(bufp, null, 10) > 0x7FFFFFFFFFFFFFFFu64 {
            self.emit_cstr(bufp);
            self.emit_str("ull");
        } else {
            self.emit_cstr(bufp);
            let hexf = n > 2 && buf[0] == '0' as char && (buf[1] as u8 | 0x20u8) == b'x';
            if !hexf && (sb == BuiltinType::BT_F32 || sb == BuiltinType::BT_F64) && unsafe cstring::memchr(bufp, '.', n) == null && unsafe cstring::memchr(
                bufp,
                'e',
                n,
            ) == null && unsafe cstring::memchr(bufp, 'E', n) == null {
                self.emit_str(".0");
            }
        }
        if eb == BuiltinType::BT_I64 || eb == BuiltinType::BT_ISIZE {
            self.emit_str("LL");
        } else if eb == BuiltinType::BT_U8 || eb == BuiltinType::BT_U16 || eb == BuiltinType::BT_U32 {
            self.emit_str("U");
        } else if eb == BuiltinType::BT_U64 || eb == BuiltinType::BT_USIZE {
            self.emit_str("ULL");
        } else if eb == BuiltinType::BT_F32 {
            self.emit_str("f");
        }
    }

    fn emit_reescaped(self: &mut Self, s: tok::Span, is_char: bool) {
        let src = self.source;
        let mut q = '"' as i32;
        if is_char {
            q = '\'';
        }
        self.buf.push_byte(q as u8);
        let mut i = (s.start + 1) as usize;
        let end = (s.end - 1) as usize;
        while i < end {
            if src[i] != b'\\' {
                if is_char && src[i] >= 0x80u8 {
                    let cp = (src[i] & 0x1Fu8) as u32 << 6 | (src[i + 1] & 0x3Fu8) as u32;
                    self.emit_octal_escape(cp & 0xFFu32);
                    i = i + 2;
                    continue;
                }
                self.buf.push_byte((src[i] as i32) as u8);
                i = i + 1;
                continue;
            }
            i = i + 1;
            if i >= end {
                break;
            }
            let e = src[i];
            i = i + 1;
            if e == b'n' || e == b'r' || e == b't' || e == b'\\' || e == b'"' || e == b'\'' {
                self.buf.push_byte(b'\\');
                self.buf.push_byte((e as i32) as u8);
            } else if e == b'0' {
                self.emit_str("\\000");
            } else if e == b'x' {
                let v = (hex_val(src[i]) << 4 | hex_val(src[i + 1])) as u32;
                i = i + 2;
                self.emit_octal_escape(v & 0xFFu32);
            } else if e == b'u' {
                if i < end && src[i] == b'{' {
                    i = i + 1;
                }
                let mut cp: u32 = 0;
                while i < end && src[i] != b'}' {
                    cp = cp << 4 | hex_val(src[i]) as u32;
                    i = i + 1;
                }
                if i < end && src[i] == b'}' {
                    i = i + 1;
                }
                if is_char {
                    self.emit_octal_escape(cp & 0xFFu32);
                } else {
                    let mut b = Bytes4 {};
                    let bn = utf8_encode(cp, &mut b[0]);
                    for kk in 0..bn {
                        self.emit_octal_escape(b[kk as usize]);
                    }
                }
            } else {
                self.buf.push_byte(b'\\');
                self.buf.push_byte((e as i32) as u8);
            }
        }
        self.buf.push_byte(q as u8);
    }

    fn emit_raw_c_string(self: &mut Self, content: tok::Span) {
        self.emit_str("\"");
        let mut i = content.start;
        while i < content.end {
            let b = self.source[i as usize];
            if b == b'"' || b == b'\\' {
                self.buf.push_byte(b'\\');
                self.buf.push_byte((b as i32) as u8);
            } else if b == b'\n' {
                self.emit_str("\\n");
            } else if b < 0x20u8 {
                self.emit_octal_escape(b);
            } else {
                self.buf.push_byte((b as i32) as u8);
            }
            i = i + 1;
        }
        self.emit_str("\"");
    }
}

pub type Bytes4 = Array<u8, 4>;

// ---- stubs: filled in later chunks (codegen is never run by the stub main, so these keep the build green) ----
extend Codegen {
    fn emit_format_builtin(self: &mut Self, id: NodeId) bool {
        if self.package == null {
            return false;
        }
        let callee = unsafe (*self.cur_ast()).at_const(id).as_data.call.callee;
        let ck = unsafe (*self.cur_ast()).at_const(callee).kind;
        let mut kind: i32 = 0;
        let mut dst_recv: NodeId = NODE_NONE;
        if ck == NodeKind::NODE_MEMBER {
            // Method form `<dst>.format_into("template", args..)`: dst is the receiver, so its &mut borrow
            // defers past the args (a free-fn `&mut dst` arg would collide with any `self.X` arg).
            let mem = unsafe (*self.cur_ast()).at_const(callee).as_data.member.member;
            let memname = unsafe (*self.cur_ast()).at_const(mem).as_data.name.text;
            if span_is(self.mod_src(self.cur_module()), memname, "format_into".ptr() as *const char) {
                kind = 6;
                dst_recv = unsafe (*self.cur_ast()).at_const(callee).as_data.member.object;
            }
            if kind == 0 {
                return false;
            }
        } else if ck == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(callee);
            if d.node == NODE_NONE || d.module as usize >= self.pkg_count() || !unsafe (*self.package).modules[d.module as usize].prelude {
                return false;
            }
            if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_FUNCTION {
                return false;
            }
            let fnamenode = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.name;
            let fnm = unsafe (*self.mod_ast(d.module)).at_const(fnamenode).as_data.name.text;
            let dsrc = self.mod_src(d.module);
            if span_is(dsrc, fnm, "format".ptr() as *const char) {
                kind = 1;
            } else if span_is(dsrc, fnm, "print".ptr() as *const char) {
                kind = 2;
            } else if span_is(dsrc, fnm, "println".ptr() as *const char) {
                kind = 3;
            } else if span_is(dsrc, fnm, "eprint".ptr() as *const char) {
                kind = 4;
            } else if span_is(dsrc, fnm, "eprintln".ptr() as *const char) {
                kind = 5;
            }
            if kind == 0 {
                return false;
            }
        } else {
            return false;
        }
        let args = unsafe (*self.cur_ast()).at_const(id).as_data.call.args;
        let aids = unsafe (*self.cur_ast()).list(args);
        let ti: u32 = 0u32; // template literal is always arg[0] (format/print + method .format_into)
        let mut is_raw = false;
        let mut ok_lit = false;
        if args.len > ti {
            let a0 = unsafe aids[ti as usize];
            if unsafe (*self.cur_ast()).at_const(a0).kind == NodeKind::NODE_LITERAL {
                let tt = unsafe (*self.cur_ast()).at_const(a0).as_data.literal.token_type;
                is_raw = tt == TokenType::RawStringLiteral;
                ok_lit = tt == TokenType::StringLiteral || is_raw;
            }
        }
        if !ok_lit {
            let sspan = unsafe (*self.cur_ast()).at_const(id).span;
            self.errors.emit(
                sspan.start,
                sspan.end - sspan.start,
                format("{}", "codegen: format string must be a string literal"),
            );
            self.errors.note(format("format strings are parsed at compile time so placeholders can be checked"));
            return true;
        }
        let a0 = unsafe aids[ti as usize];
        let raw = unsafe (*self.cur_ast()).at_const(a0).as_data.literal.raw;
        let src = self.source;
        let content = if is_raw {
            raw_string_content(src, raw);
        } else {
            tok::Span { start: raw.start + 1, end: raw.end - 1 };
        };
        // Literal-only print family: no braces in the template and no value args means no
        // formatting work at all -- emit a single fwrite of the escaped literal, no String.
        if kind >= 2 && kind != 6 && args.len == 1 {
            let mut brace = false;
            let mut k = content.start as usize;
            while k < content.end as usize {
                if src[k] == b'{' || src[k] == b'}' {
                    brace = true;
                    break;
                }
                k = k + 1;
            }
            if !brace {
                let nl = kind == 3 || kind == 5;
                let out = if kind >= 4 {
                    "__sc_stderr()".ptr() as *const char;
                } else {
                    "__sc_stdout()".ptr() as *const char;
                };
                self.emit_str("((void)fwrite(");
                self.emit_fmt_lit(is_raw, content.start as usize, content.end as usize, nl);
                self.emit_str(", 1, sizeof(");
                self.emit_fmt_lit(is_raw, content.start as usize, content.end as usize, nl);
                self.buf.format_into(") - 1, {}))", diag::cstr(out));
                return true;
            }
        }
        let mut ff = Buf32 {};
        self.fresh(&mut ff[0], 32);
        let mut fpb = Buf64 {};
        let mut fp = (&ff[0]) as *const char;
        if kind == 6 {
            // Append into the receiver buffer: bind a String* to it, and route every push through `(*ptr)`
            // so the helpers' `&%s` folds back to the pointer (zero allocation). A receiver that is
            // already a reference (a `&mut String` parameter) is a String* in C: no address-of, and any
            // extra levels deref down to one.
            let rd = self.cg_ref_depth(unsafe (*self.cur_ast()).type_of(dst_recv));
            if rd == 0 {
                self.buf.format_into("({{ String__Global *{} = &(", diag::cstr(&ff[0]));
            } else {
                self.buf.format_into("({{ String__Global *{} = {}(", diag::cstr(&ff[0]), diag::cstr(ref_derefs(rd)));
            }
            self.emit_expr(dst_recv);
            self.emit_str(");\n");
            unsafe stdio::snprintf(&mut fpb[0], 64, "(*%s)".ptr() as *const char, &ff[0]);
            fp = &fpb[0];
        } else {
            self.buf.format_into("({{ String__Global {} = String__Global__new();\n", diag::cstr(fp));
        }
        let mut i = content.start as usize;
        let endc = content.end as usize;
        let mut seg = i;
        let mut ai: u32 = ti + 1;
        while i < endc {
            if (src[i] == b'{' || src[i] == b'}') && i + 1 < endc && src[i + 1] == src[i] {
                i = i + 2;
                continue;
            }
            if src[i] == b'{' {
                let mut sp = FmtSpec { ty: 0 as char, align: 0 as char, fill: 0, width: 0, prec: -1 };
                let mut j = i + 1;
                if j < endc && src[j] == b':' {
                    j = j + 1;
                    if j + 1 < endc && (src[j + 1] == b'<' || src[j + 1] == b'>' || src[j + 1] == b'^') && src[j] != b'}' {
                        sp.fill = src[j];
                        sp.align = src[j + 1] as char;
                        j = j + 2;
                    } else if j < endc && (src[j] == b'<' || src[j] == b'>' || src[j] == b'^') {
                        sp.align = src[j] as char;
                        j = j + 1;
                    }
                    if j < endc && src[j] == b'0' && sp.fill == 0 as u8 {
                        sp.fill = b'0';
                        j = j + 1;
                    }
                    while j < endc && src[j] >= b'0' && src[j] <= b'9' {
                        sp.width = sp.width * 10 + (src[j] as i32 - '0' as i32);
                        j = j + 1;
                    }
                    if j < endc && src[j] == b'.' {
                        j = j + 1;
                        sp.prec = 0;
                        while j < endc && src[j] >= b'0' && src[j] <= b'9' {
                            sp.prec = sp.prec * 10 + (src[j] as i32 - '0' as i32);
                            j = j + 1;
                        }
                    }
                    if j < endc && (src[j] == b'x' || src[j] == b'X' || src[j] == b'b') {
                        sp.ty = src[j] as char;
                        j = j + 1;
                    }
                }
                if j < endc && src[j] == b'}' {
                    if i > seg {
                        self.emit_fmt_seg(fp, is_raw, seg, i, false);
                    }
                    if ai >= args.len {
                        let sspan = unsafe (*self.cur_ast()).at_const(id).span;
                        self.errors.emit(
                            sspan.start,
                            sspan.end - sspan.start,
                            format("{}", "codegen: more `{}` placeholders than arguments"),
                        );
                        self.errors.note(
                            format(
                                "{}",
                                "add an argument for each placeholder or escape literal braces as '{{' and '}}'",
                            ),
                        );
                        self.buf.format_into("{}; }})", diag::cstr(fp));
                        return true;
                    }
                    let argid = unsafe aids[ai as usize];
                    if !self.emit_format_arg(fp, argid, &sp) {
                        let aspan = unsafe (*self.cur_ast()).at_const(argid).span;
                        let msg = if sp.ty != 0 as char {
                            "codegen: `{:x}`/`{:X}`/`{:b}` formats require an integer argument".ptr() as *const char;
                        } else if sp.prec >= 0 {
                            "codegen: `{:.N}` precision requires a float argument".ptr() as *const char;
                        } else {
                            "codegen: argument is not directly formattable (call its .fmt())".ptr() as *const char;
                        };
                        self.errors.emit(aspan.start, aspan.end - aspan.start, format("{}", diag::cstr(msg)));
                        if sp.ty == 0 as char && sp.prec < 0 {
                            self.errors.note(
                                format("implement Format for this type or pass a value that already formats directly"),
                            );
                        }
                    }
                    ai = ai + 1;
                    i = j + 1;
                    seg = i;
                    continue;
                }
            }
            i = i + 1;
        }
        let want_nl = kind == 3 || kind == 5;
        if endc > seg {
            self.emit_fmt_seg(fp, is_raw, seg, endc, want_nl);
        } else if want_nl {
            self.buf.format_into("String__Global__push_byte(&{}, 10);\n", diag::cstr(fp));
        }
        if ai < args.len {
            let sspan = unsafe (*self.cur_ast()).at_const(id).span;
            self.errors.emit(
                sspan.start,
                sspan.end - sspan.start,
                format("{}", "codegen: more arguments than `{}` placeholders"),
            );
            self.errors.note(format("{}", "remove the extra argument or add a matching '{}' placeholder"));
        }
        if kind == 6 {
            self.emit_str("})"); // void: appended in place, dst is borrowed (no free)
        } else if kind == 1 {
            self.buf.format_into("{}; }})", diag::cstr(fp));
        } else if kind >= 4 {
            self.buf.format_into(
                "String__Global__eprint(&{}); String__Global__free(&{}); }})",
                diag::cstr(fp),
                diag::cstr(fp),
            );
        } else {
            self.buf.format_into(
                "String__Global__print(&{}); String__Global__free(&{}); }})",
                diag::cstr(fp),
                diag::cstr(fp),
            );
        }
        return true;
    }
    fn emit_assert_builtin(self: &mut Self, id: NodeId) bool {
        let kind = self.cg_assert_kind(id);
        if kind == 0 {
            return false;
        }
        let args = unsafe (*self.cur_ast()).at_const(id).as_data.call.args;
        let aids = unsafe (*self.cur_ast()).list(args);
        let sspan = unsafe (*self.cur_ast()).at_const(id).span;
        let line = self.cg_line_of(sspan.start);
        let file = self.cg_file();
        if kind == 1 {
            let a0 = unsafe aids[0 as usize];
            let cs = unsafe (*self.cur_ast()).at_const(a0).span;
            self.emit_str("({ if (!(");
            self.emit_expr(a0);
            self.emit_str(")) { ");
            if args.len == 2 {
                self.emit_str("const str __scm = ");
                self.emit_expr(unsafe aids[1 as usize]);
                self.emit_str("; ");
            }
            self.emit_str("fprintf(stderr, \"assertion failed: `");
            self.emit_pct_escaped(unsafe (self.source.ptr() + cs.start as usize), (cs.end - cs.start) as usize);
            self.emit_str("`");
            if args.len == 2 {
                self.emit_str(": %.*s");
            }
            self.emit_str("\\n  at ");
            self.emit_pct_escaped(file as *const u8, unsafe cstring::strlen(file));
            self.buf.format_into(":{}\\n\"", line);
            if args.len == 2 {
                self.emit_str(", (int)__scm.len, (const char *)__scm.ptr");
            }
            self.emit_str("); abort(); } })");
            return true;
        }
        let a0 = unsafe aids[0 as usize];
        let a1 = unsafe aids[1 as usize];
        let ls = unsafe (*self.cur_ast()).at_const(a0).span;
        let rs = unsafe (*self.cur_ast()).at_const(a1).span;
        let lt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(a0));
        let depth = self.cg_ref_depth(lt);
        let base = self.strip_ptr(lt);
        let y = *self.type_at(base);
        let mut lb = Buf32 {};
        let mut rb = Buf32 {};
        self.fresh(&mut lb[0], 32);
        self.fresh(&mut rb[0], 32);
        let lp = (&lb[0]) as *const char;
        let rp = (&rb[0]) as *const char;
        let mut lacc = Buf64 {};
        let mut racc = Buf64 {};
        if depth != 0 {
            unsafe stdio::snprintf(&mut lacc[0], 48, "(*%s)".ptr() as *const char, lp);
            unsafe stdio::snprintf(&mut racc[0], 48, "(*%s)".ptr() as *const char, rp);
        } else {
            unsafe stdio::snprintf(&mut lacc[0], 48, "%s".ptr() as *const char, lp);
            unsafe stdio::snprintf(&mut racc[0], 48, "%s".ptr() as *const char, rp);
        }
        let laccp = (&lacc[0]) as *const char;
        let raccp = (&racc[0]) as *const char;
        let mut ldecl = Buf256 {};
        let mut rdecl = Buf256 {};
        self.render_type_id(lt, lp, &mut ldecl[0], 256);
        self.render_type_id(lt, rp, &mut rdecl[0], 256);
        self.buf.format_into("({{ {} = ", diag::cstr(&ldecl[0]));
        self.emit_expr(a0);
        self.buf.format_into("; {} = ", diag::cstr(&rdecl[0]));
        self.emit_expr(a1);
        self.emit_str("; if (");
        if kind == 2 {
            self.emit_str("!(");
        }
        if self.cg_struct_name_is(&y, "str".ptr() as *const char) {
            self.buf.format_into(
                "{}.len == {}.len && ({}.len == 0 || memcmp({}.ptr, {}.ptr, {}.len) == 0)",
                diag::cstr(laccp),
                diag::cstr(raccp),
                diag::cstr(laccp),
                diag::cstr(laccp),
                diag::cstr(raccp),
                diag::cstr(laccp),
            );
        } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE || y.kind == TypeKind::TYPE_ENUM && self.aggregate_has_payload_in(
            y.module,
            y.as_data.decl,
        ) {
            let mut om = y.module;
            let mut od = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
                om = it.module;
                od = it.decl;
            }
            let eq = self.cg_find_method_cstr(om, od, "eq".ptr() as *const char);
            self.emit_op_method(y, om, od, eq);
            self.buf.format_into("(&{}, &{})", diag::cstr(laccp), diag::cstr(raccp));
        } else {
            self.buf.format_into("{} == {}", diag::cstr(laccp), diag::cstr(raccp));
        }
        if kind == 2 {
            self.emit_str(")) {\n");
        } else {
            self.emit_str(") {\n");
        }
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_str("fprintf(stderr, \"assertion failed: `");
        self.emit_pct_escaped(unsafe (self.source.ptr() + ls.start as usize), (ls.end - ls.start) as usize);
        if kind == 2 {
            self.emit_str(" == ");
        } else {
            self.emit_str(" != ");
        }
        self.emit_pct_escaped(unsafe (self.source.ptr() + rs.start as usize), (rs.end - rs.start) as usize);
        self.emit_str("`\\n\");\n");
        self.emit_indent();
        self.emit_assert_value_line("left: ".ptr() as *const char, laccp, y, base);
        self.emit_indent();
        self.emit_assert_value_line("right:".ptr() as *const char, raccp, y, base);
        self.emit_indent();
        self.emit_str("fprintf(stderr, \"  at ");
        self.emit_pct_escaped(file as *const u8, unsafe cstring::strlen(file));
        self.buf.format_into(":{}\\n\");\n", line);
        self.emit_indent();
        self.emit_str("abort();\n");
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("}");
        for i in 0..2 {
            let ai = if i == 0 {
                a0;
            } else {
                a1;
            };
            if !self.is_lvalue(ai) && depth == 0 && self.cg_type_is_free(base) {
                self.emit_str(" ");
                self.emit_free_target(base);
                let nmp = if i == 0 {
                    lp;
                } else {
                    rp;
                };
                self.buf.format_into("(&{});", diag::cstr(nmp));
            }
        }
        self.emit_str(" })");
        return true;
    }
    fn cb_known_callee(self: &mut Self, arg: NodeId, out: *mut DefId, is_closure: *mut bool) bool {
        let ak = unsafe (*self.cur_ast()).at_const(arg).kind;
        if ak == NodeKind::NODE_CLOSURE {
            unsafe *out = DefId { module: self.cur_module(), node: arg };
            unsafe *is_closure = true;
            return true;
        }
        if ak == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(arg);
            if d.node != NODE_NONE {
                let dnk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
                let dbody = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.body;
                if dnk == NodeKind::NODE_FUNCTION && dbody != NODE_NONE {
                    unsafe *out = d;
                    unsafe *is_closure = false;
                    return true;
                }
            }
        }
        return false;
    }
    fn cb_spec_name(self: &mut Self, fn2: DefId, callee: DefId, is_closure: bool, out: *mut char, cap: usize) {
        self.function_name(fn2.node, DefId { module: 0, node: NODE_NONE }, out, cap, true);
        let at0 = unsafe cstring::strlen(out);
        let at = bappend(out, cap, at0, "__cb_".ptr() as *const char);
        let mut sym = Buf200 {};
        if is_closure {
            self.closure_name(callee.node, &mut sym[0], 200);
        } else {
            let cn = unsafe (*self.mod_ast(callee.module)).at_const(callee.node).as_data.function.name;
            self.render_qualified(callee.module, cn, &mut sym[0], 200);
        }
        bappend(out, cap, at, &sym[0]);
    }
    fn cb_single_callback_param(self: &Self, fnNode: NodeId, cbidx: *mut u32, param: *mut NodeId) bool {
        let ps = unsafe (*self.cur_ast()).at_const(fnNode).as_data.function.params;
        let pids = unsafe (*self.cur_ast()).list(ps);
        let mut found: i32 = -1;
        for i in 0..ps.len {
            let tn = unsafe (*self.cur_ast()).at_const(unsafe pids[i as usize]).as_data.parameter.ty;
            if tn != NODE_NONE && unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_FUNCTION_TYPE {
                if found >= 0 {
                    return false;
                }
                found = i as i32;
            }
        }
        if found < 0 {
            return false;
        }
        unsafe *cbidx = found as u32;
        unsafe *param = unsafe pids[found as usize];
        return true;
    }
    fn param_only_callee(self: &Self, param: NodeId) bool {
        let mut uses: u32 = 0;
        let mut callees: u32 = 0;
        let nn = unsafe (*self.cur_ast()).nodes.len();
        let mut i: u32 = 0;
        while i as usize < nn {
            let nk = unsafe (*self.cur_ast()).at_const(i).kind;
            if nk == NodeKind::NODE_IDENTIFIER {
                let d = unsafe (*self.cur_ast()).resolution_def(i);
                if d.module == self.cur_module() && d.node == param {
                    uses = uses + 1;
                }
            } else if nk == NodeKind::NODE_CALL {
                let ce = unsafe (*self.cur_ast()).at_const(i).as_data.call.callee;
                if unsafe (*self.cur_ast()).at_const(ce).kind == NodeKind::NODE_IDENTIFIER {
                    let d = unsafe (*self.cur_ast()).resolution_def(ce);
                    if d.module == self.cur_module() && d.node == param {
                        callees = callees + 1;
                    }
                }
            }
            i = i + 1;
        }
        return uses == callees;
    }
    fn cb_record(self: &mut Self, fn2: DefId, param: NodeId, cbidx: u32, callee: DefId, is_closure: bool) {
        for i in 0..self.n_cb_insts {
            let ci = self.cb_insts[i as usize];
            if ci.func.node == fn2.node && ci.func.module == fn2.module && ci.callee.node == callee.node && ci.callee.module == callee.module && ci.callee_closure == is_closure {
                return;
            }
        }
        if self.n_cb_insts >= 256 {
            return;
        }
        self.cb_insts[self.n_cb_insts as usize].func = fn2;
        self.cb_insts[self.n_cb_insts as usize].param = param;
        self.cb_insts[self.n_cb_insts as usize].cbidx = cbidx;
        self.cb_insts[self.n_cb_insts as usize].callee = callee;
        self.cb_insts[self.n_cb_insts as usize].callee_closure = is_closure;
        self.n_cb_insts = self.n_cb_insts + 1;
    }
    fn cb_keep(self: &mut Self, fn2: NodeId) {
        for i in 0..self.n_cb_keep {
            if self.cb_keep_fns[i as usize] == fn2 {
                return;
            }
        }
        if self.n_cb_keep < 128 {
            self.cb_keep_fns[self.n_cb_keep as usize] = fn2;
            self.n_cb_keep = self.n_cb_keep + 1;
        }
    }
    fn cg_decl_name_node(self: &Self, m: ModuleId, decl: NodeId) NodeId {
        let dn = unsafe (*self.mod_ast(m)).at_const(decl);
        if dn.kind == NodeKind::NODE_TYPE_ALIAS {
            return dn.as_data.type_alias.name;
        }
        return dn.as_data.aggregate.name;
    }
    fn cg_conv_lit(self: &Self, m: ModuleId, name: tok::Span) *const char {
        if span_is(self.mod_src(m), name, "from".ptr() as *const char) {
            return "from".ptr() as *const char;
        }
        if span_is(self.mod_src(m), name, "try_from".ptr() as *const char) {
            return "try_from".ptr() as *const char;
        }
        return null;
    }
    fn emit_deref_hop(self: &mut Self, recv: TypeId, md: DefId) {
        let b = *self.type_at(self.subst_resolve(recv));
        if b.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(b.as_data.inst), &mut inm[0], 200);
            self.emit_cstr(&inm[0]);
            self.emit_paste();
            self.emit_str("__");
        } else if b.kind == TypeKind::TYPE_STRUCT || b.kind == TypeKind::TYPE_ENUM {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_ident_mod(
                b.module,
                unsafe (*self.mod_ast(b.module)).at_const(b.as_data.decl).as_data.aggregate.name,
            );
            self.emit_str("__");
        }
        self.emit_ident_mod(md.module, unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name);
        self.emit_str("(");
    }
    fn emit_call_args(self: &mut Self, args: NodeList) {
        for i in 0..args.len {
            if i != 0 {
                self.emit_str(", ");
            }
            self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
        }
    }
    fn emit_call_path(self: &mut Self, id: NodeId, n: Node, callee: Node) bool {
        let args = n.as_data.call.args;
        let member = callee.as_data.member.member;
        let md = unsafe (*self.cur_ast()).resolution_def(member);
        if md.node == NODE_NONE {
            return false;
        }
        let mdk = unsafe (*self.mod_ast(md.module)).at_const(md.node).kind;
        if mdk == NodeKind::NODE_VARIANT {
            self.emit_variant_construct(
                md,
                args,
                unsafe (*self.cur_ast()).list(args),
                unsafe (*self.cur_ast()).type_of(id),
            );
            return true;
        }
        if mdk != NodeKind::NODE_FUNCTION {
            return false;
        }
        let mut ov = Buf256 {};
        let ovr = self.cg_symbol_override(md.module, md.node, &mut ov[0], 160);
        if ovr || unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.is_extern {
            if ovr {
                self.emit_cstr(&ov[0]);
            } else {
                self.emit_ident_mod(
                    md.module,
                    unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name,
                );
            }
            self.emit_str("(");
            self.emit_call_args(args);
            self.emit_str(")");
            return true;
        }
        let base_t = unsafe (*self.cur_ast()).type_of(callee.as_data.member.object);
        let td = unsafe (*self.cur_ast()).resolution_def(callee.as_data.member.object);
        let mut emd = md;
        let mut param_tgt = TYPE_NONE;
        if td.node != NODE_NONE && unsafe (*self.mod_ast(td.module)).at_const(td.node).kind == NodeKind::NODE_GENERIC_PARAM {
            let r = self.subst_resolve(
                unsafe (*self.cur_ast()).intern_type(
                    Ty { kind: TypeKind::TYPE_GENERIC, module: td.module, as_data: TyAs { decl: td.node } },
                ),
            );
            if self.type_is_concrete(r) {
                param_tgt = r;
            }
        } else if td.node != NODE_NONE && unsafe (*self.mod_ast(td.module)).at_const(td.node).kind == NodeKind::NODE_INTERFACE {
            let r = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            if self.type_is_concrete(r) {
                param_tgt = r;
            }
        }
        if base_t != TYPE_NONE && self.type_at(base_t).kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(self.type_at(base_t).as_data.inst), &mut inm[0], 200);
            self.emit_cstr(&inm[0]);
            self.emit_paste();
            self.emit_str("__");
        } else if param_tgt != TYPE_NONE && self.type_at(param_tgt).kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bt = self.type_at(param_tgt).as_data.builtin;
            let bd = unsafe (*self.package).builtin_decl(bt);
            if bd != NODE_NONE {
                let cm = self.cg_find_method(
                    unsafe (*self.package).core_module,
                    bd,
                    self.source,
                    self.name_span(member),
                );
                if cm.node != NODE_NONE {
                    emd = cm;
                }
            }
            let mut pfx = Buf64 {};
            self.render_modpfx(emd.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_cstr(builtin_name(bt));
            self.emit_str("__");
        } else if param_tgt != TYPE_NONE {
            let rb = *self.type_at(param_tgt);
            let mut omod: ModuleId = 0;
            let mut odecl = NODE_NONE;
            if rb.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(rb.as_data.inst);
                omod = it.module;
                odecl = it.decl;
            } else {
                omod = rb.module;
                odecl = rb.as_data.decl;
            }
            let cm = self.cg_find_method(omod, odecl, self.source, self.name_span(member));
            if cm.node != NODE_NONE {
                emd = cm;
            }
            if rb.kind == TypeKind::TYPE_INSTANCE {
                let mut inm = Buf256 {};
                self.inst_name(unsafe (*self.cur_ast()).instance(rb.as_data.inst), &mut inm[0], 200);
                self.emit_cstr(&inm[0]);
                self.emit_paste();
                self.emit_str("__");
            } else if rb.kind == TypeKind::TYPE_STRUCT || rb.kind == TypeKind::TYPE_ENUM {
                let mut pfx = Buf64 {};
                self.render_modpfx(emd.module, &mut pfx[0], 64);
                self.emit_cstr(&pfx[0]);
                self.emit_ident_mod(omod, unsafe (*self.mod_ast(omod)).at_const(odecl).as_data.aggregate.name);
                self.emit_str("__");
            }
        } else if self.macro_mode && td.node != NODE_NONE && unsafe (*self.mod_ast(td.module)).at_const(td.node).kind == NodeKind::NODE_GENERIC_PARAM {
            let mut pp = Buf64 {};
            self.emit_str("_SCM_");
            self.render_macro_param(td.module, td.node, &mut pp[0], 64);
            self.emit_cstr(&pp[0]);
            self.emit_paste();
            self.emit_str("__");
        } else {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            if td.node != NODE_NONE {
                let mut bb: i32 = -1;
                if self.package != null {
                    bb = unsafe (*self.package).builtin_of_decl(td.module, td.node);
                }
                if bb >= 0 {
                    self.emit_cstr(builtin_name(bb as BuiltinType));
                } else {
                    self.emit_ident_mod(td.module, self.cg_decl_name_node(td.module, td.node));
                }
                self.emit_str("__");
            }
        }
        self.emit_ident_mod(emd.module, unsafe (*self.mod_ast(emd.module)).at_const(emd.node).as_data.function.name);
        if td.node != NODE_NONE && args.len != 0 {
            let mut sfx = Buf256 {};
            let a0t = unsafe (*self.cur_ast()).type_of(unsafe (*self.cur_ast()).list(args)[0]);
            self.cg_conv_suffix(td, self.cg_conv_lit(self.cur_module(), self.name_span(member)), a0t, &mut sfx[0], 200);
            self.emit_cstr(&sfx[0]);
        }
        self.emit_method_targs(id, emd);
        self.emit_str("(");
        self.emit_call_args(args);
        self.emit_str(")");
        return true;
    }
    fn emit_call_method(self: &mut Self, id: NodeId, n: Node, callee: Node) bool {
        let args = n.as_data.call.args;
        let member = callee.as_data.member.member;
        let obj = callee.as_data.member.object;
        let mut md = unsafe (*self.cur_ast()).resolution_def(member);
        if md.node == NODE_NONE || unsafe (*self.mod_ast(md.module)).at_const(md.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        // into/try_into conversion
        let memn = self.name_span(member);
        let mdn = unsafe (*self.mod_ast(md.module)).at_const(
            unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name,
        ).as_data.name.text;
        let conv = span_is(self.mod_src(self.cur_module()), memn, "into".ptr() as *const char) && span_is(
            self.mod_src(md.module),
            mdn,
            "from".ptr() as *const char,
        ) || span_is(self.mod_src(self.cur_module()), memn, "try_into".ptr() as *const char) && span_is(
            self.mod_src(md.module),
            mdn,
            "try_from".ptr() as *const char,
        );
        if conv {
            let mut tgt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            if span_is(self.mod_src(md.module), mdn, "try_from".ptr() as *const char) && self.type_at(tgt).kind == TypeKind::TYPE_INSTANCE {
                tgt = self.subst_resolve(unsafe (*self.cur_ast()).instance(self.type_at(tgt).as_data.inst).args[0]);
            }
            let tb = *self.type_at(tgt);
            let mut ct = DefId { module: tb.module, node: tb.as_data.decl };
            if tb.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(tb.as_data.inst);
                ct = DefId { module: it.module, node: it.decl };
                let mut inm = Buf256 {};
                self.inst_name(unsafe (*self.cur_ast()).instance(tb.as_data.inst), &mut inm[0], 200);
                self.emit_cstr(&inm[0]);
                self.emit_paste();
                self.emit_str("__");
            } else {
                let mut pfx = Buf64 {};
                self.render_modpfx(md.module, &mut pfx[0], 64);
                self.emit_cstr(&pfx[0]);
                self.emit_ident_mod(
                    tb.module,
                    unsafe (*self.mod_ast(tb.module)).at_const(tb.as_data.decl).as_data.aggregate.name,
                );
                self.emit_str("__");
            }
            self.emit_ident_mod(md.module, unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name);
            let mut sfx = Buf256 {};
            self.cg_conv_suffix(
                ct,
                self.cg_conv_lit(md.module, mdn),
                unsafe (*self.cur_ast()).type_of(obj),
                &mut sfx[0],
                200,
            );
            self.emit_cstr(&sfx[0]);
            self.emit_str("(");
            self.emit_expr(obj);
            self.emit_str(")");
            return true;
        }
        let obj_t = unsafe (*self.cur_ast()).type_of(obj);
        let pointee = self.strip_ptr(obj_t);
        let du = unsafe (*self.cur_ast()).deref_use_at(member);
        // generic-param receiver -> concrete method
        if self.type_at(pointee).kind == TypeKind::TYPE_GENERIC {
            let rb = *self.type_at(self.subst_resolve(pointee));
            if rb.kind == TypeKind::TYPE_STRUCT || rb.kind == TypeKind::TYPE_ENUM {
                let cm = self.cg_find_method(
                    rb.module,
                    rb.as_data.decl,
                    self.mod_src(self.cur_module()),
                    self.name_span(member),
                );
                if cm.node != NODE_NONE {
                    md = cm;
                }
            } else if rb.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                let bd = unsafe (*self.package).builtin_decl(rb.as_data.builtin);
                if bd != NODE_NONE {
                    let cm = self.cg_find_method(
                        unsafe (*self.package).core_module,
                        bd,
                        self.mod_src(self.cur_module()),
                        self.name_span(member),
                    );
                    if cm.node != NODE_NONE {
                        md = cm;
                    }
                }
            }
        }
        // dyn receiver: vtable dispatch
        let dt = self.subst_resolve(pointee);
        if self.type_at(dt).kind == TypeKind::TYPE_DYN {
            let mut mn = Buf128 {};
            render_ident_src(
                self.mod_src(md.module),
                unsafe (*self.mod_ast(md.module)).at_const(
                    unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name,
                ).as_data.name.text,
                &mut mn[0],
                128,
            );
            let ok = self.type_at(obj_t).kind;
            let obj_ind = ok == TypeKind::TYPE_POINTER || ok == TypeKind::TYPE_REFERENCE;
            let simple = !obj_ind && unsafe (*self.cur_ast()).at_const(obj).kind == NodeKind::NODE_IDENTIFIER;
            let mut tmp = Buf32 {};
            if simple {
                self.emit_expr(obj);
                self.buf.format_into(".vt->{}(", diag::cstr(&mn[0]));
                self.emit_expr(obj);
                self.emit_str(".data");
            } else {
                let mut dtn = Buf256 {};
                self.render_type_id(dt, "".ptr() as *const char, &mut dtn[0], 240);
                self.fresh(&mut tmp[0], 32);
                self.buf.format_into("({{ const {} {} = ", diag::cstr(&dtn[0]), diag::cstr(&tmp[0]));
                if obj_ind {
                    self.emit_str("*");
                }
                self.emit_expr(obj);
                self.buf.format_into(
                    "; {}.vt->{}({}.data",
                    diag::cstr(&tmp[0]),
                    diag::cstr(&mn[0]),
                    diag::cstr(&tmp[0]),
                );
            }
            for i in 0..args.len {
                self.emit_str(", ");
                self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
            }
            self.emit_str(")");
            if !simple {
                self.emit_str("; })");
            }
            return true;
        }
        let ma = self.mod_ast(md.module);
        let mut basety = pointee;
        if du != null {
            basety = unsafe (*du).target;
        }
        let base = *self.type_at(self.subst_resolve(basety));
        let params = unsafe (*ma).at_const(md.node).as_data.function.params;
        let mut self_type = NODE_NONE;
        if params.len != 0 {
            self_type = unsafe (*ma).at_const(unsafe (*ma).list(params)[0]).as_data.parameter.ty;
        }
        let mut sk = NodeKind::NODE_NONE_KIND;
        if self_type != NODE_NONE {
            sk = unsafe (*ma).at_const(self_type).kind;
        }
        let self_ptr = sk == NodeKind::NODE_POINTER_TYPE || sk == NodeKind::NODE_REFERENCE_TYPE;
        let mut self_is_mut = false;
        if self_ptr && self_type != NODE_NONE {
            self_is_mut = unsafe (*ma).at_const(self_type).as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT;
        }
        let obj_ptr = self.type_at(obj_t).kind == TypeKind::TYPE_POINTER || self.type_at(obj_t).kind == TypeKind::TYPE_REFERENCE;
        let materialize = (self_ptr || du != null) && !obj_ptr && !self.is_lvalue(obj);
        let crt = unsafe (*self.cur_ast()).type_of(id);
        let mut void_ret = crt == TYPE_NONE;
        let mut ref_ret = false;
        if crt != TYPE_NONE {
            let crk = self.type_at(crt).kind;
            void_ret = crk == TypeKind::TYPE_BUILTIN && self.type_at(crt).as_data.builtin == BuiltinType::BT_VOID;
            ref_ret = crk == TypeKind::TYPE_POINTER || crk == TypeKind::TYPE_REFERENCE;
        }
        let free_tmp = materialize && !ref_ret && self.cg_type_is_free(obj_t);
        let mut tmp = Buf32 {};
        let mut tres = Buf32 {};
        if materialize {
            self.fresh(&mut tmp[0], 32);
            self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&tmp[0]));
            self.emit_expr(obj);
            self.emit_str("; ");
            if free_tmp && !void_ret {
                self.fresh(&mut tres[0], 32);
                self.buf.format_into("__auto_type {} = ", diag::cstr(&tres[0]));
            }
        }
        let xt = self.cg_method_extend_target(md);
        let mut xtk = NodeKind::NODE_NONE_KIND;
        if xt.node != NODE_NONE {
            xtk = unsafe (*self.mod_ast(xt.module)).at_const(xt.node).kind;
        }
        if xt.node != NODE_NONE && xtk == NodeKind::NODE_TYPE_ALIAS {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_ident_mod(xt.module, self.cg_decl_name_node(xt.module, xt.node));
            self.emit_str("__");
        } else if self.macro_mode && base.kind == TypeKind::TYPE_GENERIC {
            let mut pp = Buf64 {};
            self.emit_str("_SCM_");
            self.render_macro_param(base.module, base.as_data.decl, &mut pp[0], 64);
            self.emit_cstr(&pp[0]);
            self.emit_paste();
            self.emit_str("__");
        } else if base.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(base.as_data.inst), &mut inm[0], 200);
            self.emit_cstr(&inm[0]);
            self.emit_paste();
            self.emit_str("__");
        } else if base.kind == TypeKind::TYPE_STRUCT || base.kind == TypeKind::TYPE_ENUM {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_ident_mod(
                base.module,
                unsafe (*self.mod_ast(base.module)).at_const(base.as_data.decl).as_data.aggregate.name,
            );
            self.emit_str("__");
        } else if base.kind == TypeKind::TYPE_BUILTIN {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_cstr(builtin_name(base.as_data.builtin));
            self.emit_str("__");
        } else {
            self.errors.emit(
                n.span.start,
                n.span.end - n.span.start,
                format("codegen: method receiver is not a struct or enum"),
            );
        }
        self.emit_ident_mod(md.module, unsafe (*ma).at_const(md.node).as_data.function.name);
        self.emit_method_targs(id, md);
        self.emit_str("(");
        let mut wrote = false;
        if params.len > 0 && du != null {
            if !self_ptr {
                self.emit_str("*");
            }
            let mut i = unsafe (*du).n;
            while i > 0 {
                i = i - 1;
                self.emit_deref_hop(unsafe (*du).recv[i as usize], unsafe (*du).method[i as usize]);
            }
            if materialize {
                self.buf.format_into("&{}", diag::cstr(&tmp[0]));
            } else if !obj_ptr {
                self.emit_prefixed(obj, "&".ptr() as *const char);
            } else {
                self.emit_expr(obj);
            }
            for j in 0..unsafe (*du).n {
                self.emit_str(")");
            }
            wrote = true;
        } else if params.len > 0 {
            if materialize {
                self.buf.format_into("&{}", diag::cstr(&tmp[0]));
            } else if self_ptr && !obj_ptr {
                self.emit_recv_addr(obj, self_is_mut);
            } else if !self_ptr && obj_ptr {
                self.emit_prefixed(obj, "*".ptr() as *const char);
            } else {
                self.emit_expr(obj);
            }
            wrote = true;
        }
        for i in 0..args.len {
            if wrote || i != 0 {
                self.emit_str(", ");
            }
            self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
        }
        self.emit_str(")");
        if materialize {
            if free_tmp {
                self.emit_str("; ");
                self.emit_free_target(obj_t);
                self.buf.format_into("(&{});", diag::cstr(&tmp[0]));
                if !void_ret {
                    self.buf.format_into(" {};", diag::cstr(&tres[0]));
                }
                self.emit_str(" })");
            } else {
                self.emit_str("; })");
            }
        }
        return true;
    }
    fn emit_call(self: &mut Self, id: NodeId) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let callee_id = n.as_data.call.callee;
        let callee = *unsafe (*self.cur_ast()).at_const(callee_id);
        let args = n.as_data.call.args;
        if self.emit_format_builtin(id) {
            return;
        }
        if self.emit_assert_builtin(id) {
            return;
        }
        // `x.free()` intrinsic on an unresolved generic receiver
        if callee.kind == NodeKind::NODE_MEMBER && !callee.as_data.member.path && args.len == 0 && unsafe (*self.cur_ast()).resolution_def(
            callee.as_data.member.member,
        ).node == NODE_NONE && span_is(
            self.mod_src(self.cur_module()),
            unsafe (*self.cur_ast()).at_const(callee.as_data.member.member).as_data.name.text,
            "free".ptr() as *const char,
        ) {
            let recv = callee.as_data.member.object;
            let raw = *self.type_at(unsafe (*self.cur_ast()).type_of(recv));
            let isref = raw.kind == TypeKind::TYPE_POINTER || raw.kind == TypeKind::TYPE_REFERENCE;
            let rt = *self.type_at(self.subst_resolve(self.strip_ptr(unsafe (*self.cur_ast()).type_of(recv))));
            if rt.kind == TypeKind::TYPE_DYN && rt.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                let mut stem = Buf256 {};
                self.dyn_stem_dy(&rt, &mut stem[0], 176);
                self.buf.format_into("{}__dyn_free", diag::cstr(&stem[0]));
                if isref {
                    self.emit_str("(");
                } else {
                    self.emit_str("(&");
                }
                self.emit_expr(recv);
                self.emit_str(")");
                return;
            }
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            if rt.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(rt.as_data.inst);
                om = it.module;
                od = it.decl;
            } else if rt.kind == TypeKind::TYPE_STRUCT {
                om = rt.module;
                od = rt.as_data.decl;
            }
            let mut fm = DefId { module: 0, node: NODE_NONE };
            if od != NODE_NONE {
                fm = self.cg_find_method_cstr(om, od, "free".ptr() as *const char);
            }
            if fm.node != NODE_NONE {
                self.emit_op_method(rt, om, od, fm);
                if isref {
                    self.emit_str("(");
                } else {
                    self.emit_str("(&");
                }
                self.emit_expr(recv);
                self.emit_str(")");
            } else if self.macro_mode && rt.kind == TypeKind::TYPE_GENERIC {
                let mut pp = Buf64 {};
                self.emit_str("_SCM_");
                self.render_macro_param(rt.module, rt.as_data.decl, &mut pp[0], 64);
                self.emit_cstr(&pp[0]);
                self.emit_paste();
                self.emit_str("__free");
                if isref {
                    self.emit_str("(");
                } else {
                    self.emit_str("(&");
                }
                self.emit_expr(recv);
                self.emit_str(")");
            } else {
                self.emit_str("(void)(");
                self.emit_expr(recv);
                self.emit_str(")");
            }
            return;
        }
        // tuple-struct construction
        if callee.kind == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(callee_id);
            if d.node != NODE_NONE {
                let dn = unsafe (*self.mod_ast(d.module)).at_const(d.node);
                if dn.kind == NodeKind::NODE_STRUCT && dn.as_data.aggregate.is_tuple {
                    let mut tn = Buf256 {};
                    self.render_type_id(
                        self.subst_resolve(unsafe (*self.cur_ast()).type_of(id)),
                        "".ptr() as *const char,
                        &mut tn[0],
                        200,
                    );
                    self.buf.format_into("({}){{ ", diag::cstr(&tn[0]));
                    for i in 0..args.len {
                        if i != 0 {
                            self.emit_str(", ");
                        }
                        self.buf.format_into("._{} = ", i);
                        self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
                    }
                    if args.len != 0 {
                        self.emit_str(" }");
                    } else {
                        self.emit_str("0 }");
                    }
                    return;
                }
            }
        }
        // callback specialization: call to elided cb param
        if self.cb_param != NODE_NONE && callee.kind == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(callee_id);
            if d.module == self.cur_module() && d.node == self.cb_param {
                let mut sym = Buf256 {};
                if self.cb_callee_closure {
                    self.closure_name(self.cb_callee.node, &mut sym[0], 200);
                } else {
                    self.render_qualified(
                        self.cb_callee.module,
                        unsafe (*self.mod_ast(self.cb_callee.module)).at_const(self.cb_callee.node).as_data.function.name,
                        &mut sym[0],
                        200,
                    );
                }
                self.emit_cstr(&sym[0]);
                self.emit_str("(");
                self.emit_call_args(args);
                self.emit_str(")");
                return;
            }
        }
        // callback specialization: call site with known callback
        if callee.kind == NodeKind::NODE_IDENTIFIER {
            let fn2 = unsafe (*self.cur_ast()).resolution_def(callee_id);
            for k in 0..self.n_cb_insts {
                if self.cb_insts[k as usize].func.node == fn2.node && self.cb_insts[k as usize].func.module == fn2.module {
                    let cbidx = self.cb_insts[k as usize].cbidx;
                    let mut ac = DefId { module: 0, node: NODE_NONE };
                    let mut acclo = false;
                    let mut known = false;
                    if cbidx < args.len {
                        known = self.cb_known_callee(
                            unsafe (*self.cur_ast()).list(args)[cbidx as usize],
                            &mut ac,
                            &mut acclo,
                        );
                    }
                    if known && ac.node == self.cb_insts[k as usize].callee.node && ac.module == self.cb_insts[k as usize].callee.module {
                        let mut nm = Buf256 {};
                        self.cb_spec_name(fn2, ac, acclo, &mut nm[0], 260);
                        self.emit_cstr(&nm[0]);
                        self.emit_str("(");
                        let mut wrote = false;
                        for i in 0..args.len {
                            if i != cbidx {
                                if wrote {
                                    self.emit_str(", ");
                                }
                                self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
                                wrote = true;
                            }
                        }
                        self.emit_str(")");
                        return;
                    }
                }
            }
        }
        // call through a dyn-fn / capturing-closure value
        let ct0 = unsafe (*self.cur_ast()).type_of(callee_id);
        if ct0 != TYPE_NONE {
            let cty = *self.type_at(self.subst_resolve(ct0));
            if cty.kind == TypeKind::TYPE_DYN {
                let simple = unsafe (*self.cur_ast()).at_const(callee_id).kind == NodeKind::NODE_IDENTIFIER;
                let mut tmp = Buf32 {};
                if simple {
                    self.emit_expr(callee_id);
                    self.emit_str(".vt->call(");
                    self.emit_expr(callee_id);
                    self.emit_str(".data");
                } else {
                    let mut dtn = Buf256 {};
                    self.render_type_id(self.subst_resolve(ct0), "".ptr() as *const char, &mut dtn[0], 240);
                    self.fresh(&mut tmp[0], 32);
                    self.buf.format_into("({{ const {} {} = ", diag::cstr(&dtn[0]), diag::cstr(&tmp[0]));
                    self.emit_expr(callee_id);
                    self.buf.format_into("; {}.vt->call({}.data", diag::cstr(&tmp[0]), diag::cstr(&tmp[0]));
                }
                for i in 0..args.len {
                    self.emit_str(", ");
                    self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
                }
                self.emit_str(")");
                if !simple {
                    self.emit_str("; })");
                }
                return;
            }
            if cty.kind == TypeKind::TYPE_FUNCTION && self.cg_fn_is_capturing(&cty) {
                let mut sym = Buf256 {};
                self.closure_sym_in(cty.module, cty.as_data.decl, &mut sym[0], 200);
                self.buf.format_into("{}(&(", diag::cstr(&sym[0]));
                self.emit_expr(callee_id);
                self.emit_str(")");
                for i in 0..args.len {
                    self.emit_str(", ");
                    self.emit_expr(unsafe (*self.cur_ast()).list(args)[i as usize]);
                }
                self.emit_str(")");
                return;
            }
        }
        // generic function specialization
        let mut ga = TyArgs8 {};
        let mut gn: i32 = 0;
        let g = self.generic_call_target(id, &mut ga[0], &mut gn);
        if g.node != NODE_NONE {
            for k in 0..gn {
                ga[k as usize] = self.subst_resolve(ga[k as usize]);
            }
            let mut nm = Buf256 {};
            self.spec_name(g, &ga[0], gn, &mut nm[0], 256);
            self.emit_cstr(&nm[0]);
            self.emit_str("(");
            self.emit_call_args(args);
            self.emit_str(")");
            return;
        }
        if callee.kind == NodeKind::NODE_MEMBER && callee.as_data.member.path {
            if self.emit_call_path(id, n, callee) {
                return;
            }
        }
        if callee.kind == NodeKind::NODE_MEMBER && !callee.as_data.member.path {
            if self.emit_call_method(id, n, callee) {
                return;
            }
        }
        self.emit_expr(callee_id);
        self.emit_str("(");
        self.emit_call_args(args);
        self.emit_str(")");
    }
    fn emit_struct_init(self: &mut Self, id: NodeId) {
        let si = unsafe (*self.cur_ast()).at_const(id).as_data.struct_initializer;
        let mut t = Buf256 {};
        self.render_type_node(si.ty, "".ptr() as *const char, &mut t[0], 256);
        let fields = si.fields;
        let stn = si.ty;
        if unsafe (*self.cur_ast()).at_const(stn).kind == NodeKind::NODE_TYPE_PATH {
            let parts = unsafe (*self.cur_ast()).at_const(stn).as_data.type_path.parts;
            if parts.len >= 2 {
                let vd = unsafe (*self.cur_ast()).resolution_def(
                    unsafe (*self.cur_ast()).list(parts)[(parts.len - 1) as usize],
                );
                if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                    let en = self.enclosing_enum_in(vd.module, vd.node);
                    let mut vn = Buf128 {};
                    self.render_variant_name(vd.module, vd.node, &mut vn[0], 128);
                    self.buf.format_into("({}){{ .tag = ", diag::cstr(&t[0]));
                    if en != NODE_NONE {
                        self.emit_tag_mod(vd.module, en, vd.node);
                    } else {
                        self.emit_str("0");
                    }
                    self.buf.format_into(", .payload.{} = {{", diag::cstr(&vn[0]));
                    for i in 0..fields.len {
                        let fi = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(fields)[i as usize]).as_data.field_initializer;
                        if i != 0 {
                            self.emit_str(", .");
                        } else {
                            self.emit_str(" .");
                        }
                        self.emit_ident(self.name_span(fi.name));
                        self.emit_str(" = ");
                        if unsafe (*self.cur_ast()).at_const(fi.value).kind == NodeKind::NODE_ARRAY_LITERAL {
                            self.emit_array_braces(fi.value);
                        } else {
                            self.emit_expr(fi.value);
                        }
                    }
                    if fields.len != 0 {
                        self.emit_str(" } }");
                    } else {
                        self.emit_str("0 } }");
                    }
                    return;
                }
            }
        }
        if fields.len == 0 {
            let mut zero_fields = false;
            let d = unsafe (*self.cur_ast()).resolution_def(stn);
            if d.node != NODE_NONE {
                let dn = unsafe (*self.mod_ast(d.module)).at_const(d.node);
                zero_fields = dn.kind == NodeKind::NODE_STRUCT && dn.as_data.aggregate.members.len == 0;
            }
            if zero_fields {
                self.buf.format_into("({}){{}}", diag::cstr(&t[0]));
            } else {
                self.buf.format_into("({}){{0}}", diag::cstr(&t[0]));
            }
            return;
        }
        let mut arr_copy = false;
        let mut i: u32 = 0;
        while i < fields.len {
            let fv = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(fields)[i as usize]).as_data.field_initializer.value;
            let fvt = unsafe (*self.cur_ast()).type_of(fv);
            if unsafe (*self.cur_ast()).at_const(fv).kind != NodeKind::NODE_ARRAY_LITERAL && fvt != TYPE_NONE && self.type_at(
                fvt,
            ).kind == TypeKind::TYPE_ARRAY {
                arr_copy = true;
            }
            i = i + 1;
        }
        let mut st = Buf32 {};
        if arr_copy {
            self.fresh(&mut st[0], 32);
            self.buf.format_into("({{ {} {} = ", diag::cstr(&t[0]), diag::cstr(&st[0]));
        }
        self.buf.format_into("({}){{ ", diag::cstr(&t[0]));
        i = 0;
        while i < fields.len {
            let fi = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(fields)[i as usize]).as_data.field_initializer;
            if i != 0 {
                self.emit_str(", ");
            }
            self.emit_str(".");
            self.emit_ident(self.name_span(fi.name));
            self.emit_str(" = ");
            let fvt = unsafe (*self.cur_ast()).type_of(fi.value);
            let arr_field = unsafe (*self.cur_ast()).at_const(fi.value).kind != NodeKind::NODE_ARRAY_LITERAL && fvt != TYPE_NONE && self.type_at(
                fvt,
            ).kind == TypeKind::TYPE_ARRAY;
            if unsafe (*self.cur_ast()).at_const(fi.value).kind == NodeKind::NODE_ARRAY_LITERAL {
                self.emit_array_braces(fi.value);
            } else if arr_field {
                self.emit_str("{0}");
            } else {
                self.emit_expr(fi.value);
            }
            i = i + 1;
        }
        self.emit_str(" }");
        if !arr_copy {
            return;
        }
        self.emit_str(";");
        i = 0;
        while i < fields.len {
            let fi = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(fields)[i as usize]).as_data.field_initializer;
            let fvt = unsafe (*self.cur_ast()).type_of(fi.value);
            if unsafe (*self.cur_ast()).at_const(fi.value).kind == NodeKind::NODE_ARRAY_LITERAL || fvt == TYPE_NONE || self.type_at(
                fvt,
            ).kind != TypeKind::TYPE_ARRAY {
                i = i + 1;
                continue;
            }
            self.buf.format_into(" memcpy(&{}.", diag::cstr(&st[0]));
            self.emit_ident(self.name_span(fi.name));
            self.emit_str(", &(");
            self.emit_expr(fi.value);
            self.buf.format_into("), sizeof {}.", diag::cstr(&st[0]));
            self.emit_ident(self.name_span(fi.name));
            self.emit_str(");");
            i = i + 1;
        }
        self.buf.format_into(" {}; }})", diag::cstr(&st[0]));
    }
    fn emit_new(self: &mut Self, id: NodeId) {
        let ne = unsafe (*self.cur_ast()).at_const(id).as_data.new_expr;
        let mut t = Buf256 {};
        self.render_type_node(ne.ty, "".ptr() as *const char, &mut t[0], 256);
        if ne.initializer == NODE_NONE {
            self.buf.format_into("(({}*)malloc(sizeof({})))", diag::cstr(&t[0]), diag::cstr(&t[0]));
            return;
        }
        let mut tmp = Buf32 {};
        self.fresh(&mut tmp[0], 32);
        self.buf.format_into(
            "({{ {} *{} = malloc(sizeof({})); *{} = ",
            diag::cstr(&t[0]),
            diag::cstr(&tmp[0]),
            diag::cstr(&t[0]),
            diag::cstr(&tmp[0]),
        );
        self.emit_expr(ne.initializer);
        self.buf.format_into("; {}; }})", diag::cstr(&tmp[0]));
    }
    fn emit_match_expr(self: &mut Self, id: NodeId) {
        let rt = unsafe (*self.cur_ast()).type_of(id);
        let mut res = Buf32 {};
        self.fresh(&mut res[0], 32);
        let mut decl = Buf256 {};
        if rt != TYPE_NONE {
            self.render_type_id(rt, &res[0], &mut decl[0], 256);
        } else {
            buf_join3(&mut decl[0], 256, "int ".ptr() as *const char, "".ptr() as *const char, &res[0]);
        }
        self.emit_str("({\n");
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_cstr(&decl[0]);
        self.emit_str(";\n");
        self.emit_match_core(id, 1, &res[0]);
        self.emit_indent();
        self.emit_cstr(&res[0]);
        self.emit_str(";\n");
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("})");
    }
    fn emit_match_stmt(self: &mut Self, id: NodeId) {
        self.emit_str("{\n");
        self.depth = self.depth + 1;
        self.emit_match_core(id, 0, null);
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("}\n");
    }
    fn emit_if_expr(self: &mut Self, id: NodeId) {
        let rt = unsafe (*self.cur_ast()).type_of(id);
        let mut res = Buf32 {};
        self.fresh(&mut res[0], 32);
        let mut decl = Buf256 {};
        if rt != TYPE_NONE {
            self.render_type_id(rt, &res[0], &mut decl[0], 256);
        } else {
            buf_join3(&mut decl[0], 256, "int ".ptr() as *const char, "".ptr() as *const char, &res[0]);
        }
        self.emit_str("({\n");
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_cstr(&decl[0]);
        self.emit_str(";\n");
        self.emit_indent();
        self.emit_if_value(id, &res[0]);
        self.emit_str("\n");
        self.emit_indent();
        self.emit_cstr(&res[0]);
        self.emit_str(";\n");
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("})");
    }
    fn emit_try(self: &mut Self, id: NodeId) {
        let operand = unsafe (*self.cur_ast()).at_const(id).as_data.unary.operand;
        let bt = *self.type_at(self.subst_resolve(self.strip_ptr(unsafe (*self.cur_ast()).type_of(operand))));
        if bt.kind != TypeKind::TYPE_INSTANCE {
            self.emit_expr(operand);
            return;
        }
        let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
        let om = it.module;
        let od = it.decl;
        let noneV = self.cg_enum_variant(om, od, "None".ptr() as *const char);
        let is_option = noneV != NODE_NONE;
        let mut failV = noneV;
        if !is_option {
            failV = self.cg_enum_variant(om, od, "Err".ptr() as *const char);
        }
        let mut okName2 = "Ok".ptr() as *const char;
        if is_option {
            okName2 = "Some".ptr() as *const char;
        }
        let okV = self.cg_enum_variant(om, od, okName2);
        let mut okName = Buf128 {};
        let mut failName = Buf128 {};
        self.render_variant_name(om, okV, &mut okName[0], 128);
        self.render_variant_name(om, failV, &mut failName[0], 128);
        let mut rtn = Buf256 {};
        rtn[0] = 0 as char;
        if self.current_fn_ret_node != NODE_NONE {
            self.render_type_node(self.current_fn_ret_node, "".ptr() as *const char, &mut rtn[0], 200);
        }
        let mut tmp = Buf32 {};
        self.fresh(&mut tmp[0], 32);
        self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&tmp[0]));
        self.emit_expr(operand);
        self.buf.format_into("; if ({}.tag == ", diag::cstr(&tmp[0]));
        self.emit_tag_mod(om, od, failV);
        self.emit_str(") {\n");
        self.depth = self.depth + 1;
        self.emit_defers_to(0);
        self.emit_indent();
        self.buf.format_into("return ({}){{ .tag = ", diag::cstr(&rtn[0]));
        self.emit_tag_mod(om, od, failV);
        if !is_option {
            let conv = unsafe (*self.cur_ast()).resolution_def(id);
            let mut tg = DefId { module: 0, node: NODE_NONE };
            if conv.node != NODE_NONE {
                tg = self.cg_method_extend_target(conv);
            }
            self.buf.format_into(", .payload.{}._0 = ", diag::cstr(&failName[0]));
            if tg.node != NODE_NONE {
                let mut pfx = Buf64 {};
                self.render_modpfx(conv.module, &mut pfx[0], 64);
                self.emit_cstr(&pfx[0]);
                self.emit_ident_mod(
                    tg.module,
                    unsafe (*self.mod_ast(tg.module)).at_const(tg.node).as_data.aggregate.name,
                );
                self.emit_str("__");
                self.emit_ident_mod(
                    conv.module,
                    unsafe (*self.mod_ast(conv.module)).at_const(conv.node).as_data.function.name,
                );
                let mut sfx = Buf256 {};
                self.cg_conv_suffix(tg, "from".ptr() as *const char, self.subst_resolve(it.args[1]), &mut sfx[0], 200);
                self.emit_cstr(&sfx[0]);
                self.buf.format_into("({}.payload.{}._0)", diag::cstr(&tmp[0]), diag::cstr(&failName[0]));
            } else {
                self.buf.format_into("{}.payload.{}._0", diag::cstr(&tmp[0]), diag::cstr(&failName[0]));
            }
        }
        self.emit_str(" };\n");
        self.depth = self.depth - 1;
        self.emit_indent();
        self.buf.format_into("}} {}.payload.{}._0; }})", diag::cstr(&tmp[0]), diag::cstr(&okName[0]));
    }
    fn emit_stmt(self: &mut Self, id: NodeId) {
        if id == NODE_NONE {
            return;
        }
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let nk = n.kind;
        switch nk {
            NODE_STATIC_ASSERT => {
                self.emit_static_assert(id);
            },
            NODE_BLOCK => {
                self.emit_block(id);
                self.emit_str("\n");
            },
            NODE_LET => {
                let nameN = n.as_data.let_stmt.name;
                let nameK = unsafe (*self.cur_ast()).at_const(nameN).kind;
                if nameK == NodeKind::NODE_IDENTIFIER && span_is(
                    self.mod_src(self.cur_module()),
                    unsafe (*self.cur_ast()).at_const(nameN).as_data.name.text,
                    "_".ptr() as *const char,
                ) {
                    let dvt = unsafe (*self.cur_ast()).type_of(n.as_data.let_stmt.value);
                    if dvt != TYPE_NONE && self.cg_type_is_free(dvt) {
                        self.emit_expr_stmt(n.as_data.let_stmt.value);
                    } else {
                        self.emit_str("(void)(");
                        self.emit_expr(n.as_data.let_stmt.value);
                        self.emit_str(");\n");
                    }
                    return;
                }
                if nameK == NodeKind::NODE_PATTERN_TUPLE {
                    self.emit_tuple_let(id);
                    let children = unsafe (*self.cur_ast()).at_const(nameN).as_data.pattern.children;
                    for i in 0..children.len {
                        let eid = unsafe (*self.cur_ast()).list(children)[i as usize];
                        if !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(eid)) || self.cg_is_moved(eid) || span_is(
                            self.mod_src(self.cur_module()),
                            self.name_span(eid),
                            "_".ptr() as *const char,
                        ) {
                            continue;
                        }
                        if self.cg_is_cond_moved(eid) {
                            let mut fl = Buf32 {};
                            cg_move_flag(&mut fl[0], 32, eid);
                            self.emit_indent();
                            self.buf.format_into("bool {} = false;\n", diag::cstr(&fl[0]));
                        }
                        self.cg_register_auto_free(eid);
                    }
                    return;
                }
                let autofree = self.cg_will_auto_free(id);
                let is_const = !n.as_data.let_stmt.is_mutable && !self.cg_type_is_free(
                    unsafe (*self.cur_ast()).type_of(id),
                );
                let lbt = unsafe (*self.cur_ast()).type_of(id);
                let lval = n.as_data.let_stmt.value;
                if lval != NODE_NONE && lbt != TYPE_NONE && self.type_at(lbt).kind == TypeKind::TYPE_ARRAY && unsafe (*self.cur_ast()).at_const(
                    lval,
                ).kind != NodeKind::NODE_ARRAY_LITERAL {
                    let mut arrtn = n.as_data.let_stmt.ty;
                    if arrtn == NODE_NONE && unsafe (*self.cur_ast()).at_const(lval).kind == NodeKind::NODE_CALL {
                        let fd = unsafe (*self.cur_ast()).resolution_def(
                            unsafe (*self.cur_ast()).at_const(lval).as_data.call.callee,
                        );
                        if fd.node != NODE_NONE && fd.module == self.cur_module() && unsafe (*self.mod_ast(fd.module)).at_const(
                            fd.node,
                        ).kind == NodeKind::NODE_FUNCTION {
                            arrtn = self.fn_array_return(fd.node);
                        }
                    }
                    if arrtn != NODE_NONE {
                        let mut nm = Buf128 {};
                        self.render_ident(self.name_span(nameN), &mut nm[0], 128);
                        let mut decl = Buf512 {};
                        self.render_binding_node(arrtn, &nm[0], false, &mut decl[0], 300);
                        self.emit_cstr(&decl[0]);
                        self.buf.format_into("; memcpy({}, ", diag::cstr(&nm[0]));
                        self.emit_expr(lval);
                        self.buf.format_into(", sizeof({}));\n", diag::cstr(&nm[0]));
                        return;
                    }
                }
                if n.as_data.let_stmt.ty != NODE_NONE {
                    let mut nm = Buf128 {};
                    self.render_ident(self.name_span(nameN), &mut nm[0], 128);
                    let mut decl = Buf512 {};
                    self.render_binding_node(n.as_data.let_stmt.ty, &nm[0], is_const, &mut decl[0], 300);
                    self.emit_cstr(&decl[0]);
                } else {
                    self.emit_binding(unsafe (*self.cur_ast()).type_of(id), self.name_span(nameN), is_const);
                }
                if n.as_data.let_stmt.value != NODE_NONE {
                    self.emit_str(" = ");
                    self.emit_initializer(n.as_data.let_stmt.ty, n.as_data.let_stmt.value);
                }
                self.emit_str(";\n");
                if autofree && self.cg_is_cond_moved(id) {
                    let mut fl = Buf32 {};
                    cg_move_flag(&mut fl[0], 32, id);
                    self.emit_indent();
                    self.buf.format_into("bool {} = false;\n", diag::cstr(&fl[0]));
                }
                if autofree {
                    self.cg_register_auto_free(id);
                }
            },
            NODE_CONST => {
                let mut nm = Buf128 {};
                self.render_ident(self.name_span(n.as_data.const_def.name), &mut nm[0], 128);
                let mut decl = Buf256 {};
                self.render_type_node(n.as_data.const_def.ty, &nm[0], &mut decl[0], 256);
                self.emit_str("static const ");
                self.emit_cstr(&decl[0]);
                if n.as_data.const_def.value != NODE_NONE {
                    self.emit_str(" = ");
                    let sc = self.const_ctx;
                    self.const_ctx = true;
                    self.emit_initializer(n.as_data.const_def.ty, n.as_data.const_def.value);
                    self.const_ctx = sc;
                }
                self.emit_str(";\n");
            },
            NODE_RETURN => {
                self.emit_return(id);
            },
            NODE_IF => {
                self.emit_if(id);
                self.emit_str("\n");
            },
            NODE_WHILE => {
                let saved_ldb = self.loop_defer_base;
                self.loop_defer_base = self.defer_top;
                let le = self.cg_loop_push(id, false);
                if n.as_data.while_stmt.is_do {
                    self.emit_str("do ");
                    self.pending_cnt = (le + 1) as u32;
                    self.emit_block(n.as_data.while_stmt.body);
                    self.emit_str(" while ");
                    self.emit_condition(n.as_data.while_stmt.condition);
                    self.emit_str(";\n");
                } else {
                    if n.as_data.while_stmt.condition == NODE_NONE {
                        self.emit_str("for (;;) ");
                    } else {
                        self.emit_str("while ");
                        self.emit_condition(n.as_data.while_stmt.condition);
                        self.emit_str(" ");
                    }
                    self.pending_cnt = (le + 1) as u32;
                    self.emit_block(n.as_data.while_stmt.body);
                    self.emit_str("\n");
                }
                self.cg_loop_brk_label(le);
                self.cg_loop_pop(le);
                self.loop_defer_base = saved_ldb;
            },
            NODE_FOR => {
                let saved_ldb = self.loop_defer_base;
                self.loop_defer_base = self.defer_top;
                let le = self.cg_loop_push(id, false);
                self.emit_for(id);
                self.cg_loop_brk_label(le);
                self.cg_loop_pop(le);
                self.loop_defer_base = saved_ldb;
            },
            NODE_BREAK | NODE_CONTINUE => {
                let is_brk = nk == NodeKind::NODE_BREAK;
                let le = self.cg_loop_find(unsafe (*self.cur_ast()).resolution(id));
                let top = le < 0 || le as u32 == self.nloops - 1;
                let mut dbase = self.loop_defer_base;
                if le >= 0 {
                    dbase = self.loop_stack[le as usize].defer_base;
                }
                let mut value = NODE_NONE;
                if is_brk {
                    value = n.as_data.flow.value;
                }
                let mut kw = "continue".ptr() as *const char;
                if is_brk {
                    kw = "break".ptr() as *const char;
                }
                if top && value == NODE_NONE {
                    if self.defer_top > dbase {
                        self.emit_str("{\n");
                        self.depth = self.depth + 1;
                        self.emit_defers_to(dbase);
                        self.emit_indent();
                        self.buf.format_into("{};\n", diag::cstr(kw));
                        self.depth = self.depth - 1;
                        self.emit_indent();
                        self.emit_str("}\n");
                    } else {
                        self.buf.format_into("{};\n", diag::cstr(kw));
                    }
                    return;
                }
                self.emit_str("{\n");
                self.depth = self.depth + 1;
                if value != NODE_NONE && le >= 0 && self.loop_stack[le as usize].is_expr {
                    self.emit_indent();
                    self.buf.format_into("__lv{} = ", self.loop_stack[le as usize].seq);
                    self.emit_expr(value);
                    self.emit_str(";\n");
                }
                self.emit_defers_to(dbase);
                self.emit_indent();
                if top {
                    self.buf.format_into("{};\n", diag::cstr(kw));
                } else if is_brk {
                    self.loop_stack[le as usize].used_brk = true;
                    self.buf.format_into("goto __brk{};\n", self.loop_stack[le as usize].seq);
                } else {
                    self.loop_stack[le as usize].used_cnt = true;
                    self.buf.format_into("goto __cnt{};\n", self.loop_stack[le as usize].seq);
                }
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_str("}\n");
            },
            NODE_DEFER => {
                if self.defer_top >= 256 {
                    self.errors.emit(
                        n.span.start,
                        n.span.end - n.span.start,
                        format("codegen: too many nested 'defer' statements"),
                    );
                } else {
                    let t = self.defer_top;
                    self.defer_kind[t as usize] = 0;
                    self.defer_stack[t as usize] = n.as_data.single.value;
                    self.defer_top = t + 1;
                }
            },
            NODE_EXPRESSION_STATEMENT => {
                self.emit_expr_stmt(n.as_data.single.value);
            },
            _ => {},
        };
    }
    fn emit_block(self: &mut Self, id: NodeId) {
        self.emit_block_from(id, self.defer_top);
    }
    fn emit_binding(self: &mut Self, t: TypeId, name: tok::Span, is_const: bool) {
        let mut nm = Buf128 {};
        self.render_ident(name, &mut nm[0], 128);
        let k = self.type_at(t).kind;
        // An abstract (generic template) or error type has no spellable C type here -- let C infer it, exactly
        // as the const-view of a pointer element would otherwise mis-qualify (`const int *` vs `int *const`).
        if k == TypeKind::TYPE_GENERIC || k == TypeKind::TYPE_ERROR {
            if is_const {
                self.emit_str("const __auto_type ");
            } else {
                self.emit_str("__auto_type ");
            }
            self.emit_cstr(&nm[0]);
            return;
        }
        if is_const && (k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE) {
            let mut cn = Buf256 {};
            buf_join3(&mut cn[0], 200, "const ".ptr() as *const char, "".ptr() as *const char, &nm[0]);
            let mut decl = Buf512 {};
            self.render_type_id(t, &cn[0], &mut decl[0], 512);
            self.emit_cstr(&decl[0]);
        } else {
            let mut decl = Buf512 {};
            self.render_type_id(t, &nm[0], &mut decl[0], 512);
            if is_const {
                self.emit_str("const ");
            }
            self.emit_cstr(&decl[0]);
        }
    }
    fn render_binding_node(self: &mut Self, tn: NodeId, name: *const char, is_const: bool, out: *mut char, cap: usize) {
        if is_const {
            let mut cn = Buf256 {};
            buf_join3(&mut cn[0], 200, "const ".ptr() as *const char, "".ptr() as *const char, name);
            self.render_type_node(tn, &cn[0], out, cap);
        } else {
            self.render_type_node(tn, name, out, cap);
        }
    }
    fn emit_static_assert(self: &mut Self, id: NodeId) {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        self.emit_str("_Static_assert(");
        let sc = self.const_ctx;
        self.const_ctx = true;
        self.emit_expr(bd.left);
        self.const_ctx = sc;
        self.emit_str(", ");
        if bd.right != NODE_NONE {
            self.emit_reescaped(unsafe (*self.cur_ast()).at_const(bd.right).as_data.literal.raw, false);
        } else {
            self.emit_str("\"static assertion failed\"");
        }
        self.emit_str(");\n");
    }
    fn emit_tuple_let(self: &mut Self, id: NodeId) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let mut tmp = Buf32 {};
        self.fresh(&mut tmp[0], 32);
        let pnm = unsafe (*self.cur_ast()).at_const(n.as_data.let_stmt.name).as_data.pattern.children;
        let mut freed_discard = false;
        let mut i: u32 = 0;
        while i < pnm.len {
            let pid = unsafe (*self.cur_ast()).list(pnm)[i as usize];
            if span_is(self.mod_src(self.cur_module()), self.name_span(pid), "_".ptr() as *const char) && self.cg_type_is_free(
                unsafe (*self.cur_ast()).type_of(pid),
            ) {
                freed_discard = true;
            }
            i = i + 1;
        }
        let mut cq = "const ".ptr() as *const char;
        if freed_discard {
            cq = "".ptr() as *const char;
        }
        self.buf.format_into("{}__auto_type {} = ", diag::cstr(cq), diag::cstr(&tmp[0]));
        self.emit_expr(n.as_data.let_stmt.value);
        self.emit_str(";\n");
        let names = unsafe (*self.cur_ast()).at_const(n.as_data.let_stmt.name).as_data.pattern.children;
        i = 0;
        while i < names.len {
            let nid = unsafe (*self.cur_ast()).list(names)[i as usize];
            let mut bn = Buf128 {};
            self.render_ident(self.name_span(nid), &mut bn[0], 128);
            if bn[0] == '_' as char && bn[1] == 0 as char {
                if self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(nid)) {
                    self.emit_indent();
                    if self.emit_free_target(unsafe (*self.cur_ast()).type_of(nid)) {
                        self.buf.format_into("(&{}._{})", diag::cstr(&tmp[0]), i);
                    } else {
                        self.buf.format_into("(void){}._{}", diag::cstr(&tmp[0]), i);
                    }
                    self.emit_str(";\n");
                }
                i = i + 1;
                continue;
            }
            self.emit_indent();
            let element_const = !n.as_data.let_stmt.is_mutable && !self.cg_type_is_free(
                unsafe (*self.cur_ast()).type_of(nid),
            );
            let mut ecq = "".ptr() as *const char;
            if element_const {
                ecq = "const ".ptr() as *const char;
            }
            self.buf.format_into(
                "{}__auto_type {} = {}._{};\n",
                diag::cstr(ecq),
                diag::cstr(&bn[0]),
                diag::cstr(&tmp[0]),
                i,
            );
            i = i + 1;
        }
    }
    fn emit_return(self: &mut Self, id: NodeId) {
        let vals = unsafe (*self.cur_ast()).at_const(id).as_data.return_stmt.values;
        let has_ret = self.current_ret[0] != 0 as char;
        let crp = (&self.current_ret[0]) as *const char;
        if self.defer_top > 0 {
            self.emit_str("{\n");
            self.depth = self.depth + 1;
            if vals.len == 0 {
                self.emit_defers_to(0);
                self.emit_indent();
                self.emit_str("return;\n");
            } else {
                let mut rv = Buf32 {};
                self.fresh(&mut rv[0], 32);
                self.emit_indent();
                if has_ret {
                    self.buf.format_into("{} {} = ({}){{ ", diag::cstr(crp), diag::cstr(&rv[0]), diag::cstr(crp));
                    let v0 = unsafe (*self.cur_ast()).list(vals)[0];
                    if vals.len == 1 && unsafe (*self.cur_ast()).at_const(v0).kind == NodeKind::NODE_ARRAY_LITERAL {
                        self.emit_array_braces(v0);
                    } else {
                        let mut i: u32 = 0;
                        while i < vals.len {
                            if i != 0 {
                                self.emit_str(", ");
                            }
                            self.emit_expr(unsafe (*self.cur_ast()).list(vals)[i as usize]);
                            i = i + 1;
                        }
                    }
                    self.emit_str(" };\n");
                } else {
                    let v0 = unsafe (*self.cur_ast()).list(vals)[0];
                    let rvt0 = unsafe (*self.cur_ast()).type_of(v0);
                    if rvt0 != TYPE_NONE && self.type_at(rvt0).kind == TypeKind::TYPE_NEVER {
                        self.emit_expr(v0);
                        self.emit_str(";\n");
                        self.depth = self.depth - 1;
                        self.emit_indent();
                        self.emit_str("}\n");
                        return;
                    }
                    self.buf.format_into("__auto_type {} = ", diag::cstr(&rv[0]));
                    self.emit_expr(v0);
                    self.emit_str(";\n");
                }
                self.emit_defers_to(0);
                self.emit_indent();
                self.buf.format_into("return {};\n", diag::cstr(&rv[0]));
            }
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            return;
        }
        if vals.len == 0 {
            self.emit_str("return;\n");
            return;
        }
        if vals.len == 1 {
            let v0 = unsafe (*self.cur_ast()).list(vals)[0];
            if unsafe (*self.cur_ast()).at_const(v0).kind == NodeKind::NODE_MATCH {
                self.emit_str("{\n");
                self.depth = self.depth + 1;
                self.emit_match_core(v0, 2, null);
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_str("}\n");
                return;
            }
            if has_ret {
                self.buf.format_into("return ({}){{ ", diag::cstr(crp));
                if unsafe (*self.cur_ast()).at_const(v0).kind == NodeKind::NODE_ARRAY_LITERAL {
                    self.emit_array_braces(v0);
                } else {
                    self.emit_expr(v0);
                }
                self.emit_str(" };\n");
                return;
            }
            let rvt = unsafe (*self.cur_ast()).type_of(v0);
            if rvt != TYPE_NONE && self.type_at(rvt).kind == TypeKind::TYPE_NEVER {
                self.emit_expr(v0);
                self.emit_str(";\n");
                return;
            }
            self.emit_str("return ");
            self.emit_expr(v0);
            self.emit_str(";\n");
            return;
        }
        self.buf.format_into("return ({}){{ ", diag::cstr(crp));
        for i in 0..vals.len {
            if i != 0 {
                self.emit_str(", ");
            }
            self.emit_expr(unsafe (*self.cur_ast()).list(vals)[i as usize]);
        }
        self.emit_str(" };\n");
    }
    fn cg_loop_body_tail(self: &mut Self, dbase: u32, le: i32) {
        self.emit_defers_to(dbase);
        self.defer_top = dbase;
        if le >= 0 && self.loop_stack[le as usize].used_cnt {
            self.emit_indent();
            self.buf.format_into("__cnt{}:;\n", self.loop_stack[le as usize].seq);
        }
    }
    fn emit_for_range(self: &mut Self, id: NodeId) {
        let fs = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt;
        let r = unsafe (*self.cur_ast()).at_const(fs.iterable).as_data.pattern_range;
        let lo = r.start;
        let hi = r.end;
        let name = self.name_span(fs.binding);
        let mut nm = Buf128 {};
        self.render_ident(name, &mut nm[0], 128);
        // Range semantics: both bounds are evaluated ONCE, left-to-right, before iteration --
        // a non-literal upper bound is materialized in the init clause so body effects
        // (e.g. growing the iterated vector) never re-enter the condition.
        let hoist = hi != NODE_NONE && unsafe (*self.cur_ast()).at_const(hi).kind != NodeKind::NODE_LITERAL;
        let mut hb = Buf32 {};
        if hoist {
            self.fresh(&mut hb[0], 32);
        }
        self.emit_str("for (");
        self.emit_binding(unsafe (*self.cur_ast()).type_of(fs.iterable), name, false);
        self.emit_str(" = ");
        if lo != NODE_NONE {
            self.emit_expr(lo);
        } else {
            self.emit_str("0");
        }
        if hoist {
            self.buf.format_into(", {} = ", diag::cstr(&hb[0]));
            self.emit_expr(hi);
        }
        self.emit_str("; ");
        if hi != NODE_NONE {
            let mut cmp = "<".ptr() as *const char;
            if r.inclusive {
                cmp = "<=".ptr() as *const char;
            }
            self.buf.format_into("{} {} ", diag::cstr(&nm[0]), diag::cstr(cmp));
            if hoist {
                self.buf.format_into("{}", diag::cstr(&hb[0]));
            } else {
                self.emit_expr(hi);
            }
        }
        self.buf.format_into("; {}++) ", diag::cstr(&nm[0]));
        self.pending_cnt = (self.cg_loop_find(id) + 1) as u32;
        self.emit_block(fs.body);
        self.emit_str("\n");
    }
    fn emit_for(self: &mut Self, id: NodeId) {
        let le = self.cg_loop_find(id);
        let fs = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt;
        if unsafe (*self.cur_ast()).at_const(fs.iterable).kind == NodeKind::NODE_RANGE {
            self.emit_for_range(id);
            return;
        }
        let ity = *self.type_at(unsafe (*self.cur_ast()).type_of(fs.iterable));
        let body = fs.body;
        let stmts = unsafe (*self.cur_ast()).at_const(body).as_data.block.statements;
        let mut idx = Buf32 {};
        self.fresh(&mut idx[0], 32);
        if ity.kind == TypeKind::TYPE_ARRAY {
            let len = self.array_length_of(fs.iterable);
            self.buf.format_into("for (size_t {} = 0; {} < ", diag::cstr(&idx[0]), diag::cstr(&idx[0]));
            if len != NODE_NONE {
                self.emit_expr(len);
            } else {
                self.emit_str("sizeof(");
                self.emit_expr(fs.iterable);
                self.emit_str(")/sizeof((");
                self.emit_expr(fs.iterable);
                self.emit_str(")[0])");
            }
            self.buf.format_into("; {}++) {{\n", diag::cstr(&idx[0]));
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_binding(ity.as_data.arr.elem, self.name_span(fs.binding), true);
            self.emit_str(" = (");
            self.emit_expr(fs.iterable);
            self.buf.format_into(")[{}];\n", diag::cstr(&idx[0]));
            let dbase = self.defer_top;
            for i in 0..stmts.len {
                self.emit_indent();
                self.emit_stmt(unsafe (*self.cur_ast()).list(stmts)[i as usize]);
            }
            self.cg_loop_body_tail(dbase, le);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            return;
        }
        let mut selem: TypeId = TYPE_NONE;
        if self.cg_slice_elem(unsafe (*self.cur_ast()).type_of(fs.iterable), &mut selem) {
            let mut s = Buf32 {};
            self.fresh(&mut s[0], 32);
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(fs.iterable), &s[0], &mut styp[0], 200);
            self.emit_str("{\n");
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_cstr(&styp[0]);
            self.emit_str(" = ");
            self.emit_expr(fs.iterable);
            self.emit_str(";\n");
            self.emit_indent();
            self.buf.format_into(
                "for (size_t {} = 0; {} < {}.len; {}++) {{\n",
                diag::cstr(&idx[0]),
                diag::cstr(&idx[0]),
                diag::cstr(&s[0]),
                diag::cstr(&idx[0]),
            );
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_binding(selem, self.name_span(fs.binding), true);
            self.buf.format_into(" = {}.ptr[{}];\n", diag::cstr(&s[0]), diag::cstr(&idx[0]));
            let dbase = self.defer_top;
            for i in 0..stmts.len {
                self.emit_indent();
                self.emit_stmt(unsafe (*self.cur_ast()).list(stmts)[i as usize]);
            }
            self.cg_loop_body_tail(dbase, le);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            return;
        }
        let mut relem: TypeId = TYPE_NONE;
        if self.cg_range_elem(unsafe (*self.cur_ast()).type_of(fs.iterable), &mut relem) {
            let mut rr = Buf32 {};
            self.fresh(&mut rr[0], 32);
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(fs.iterable), &rr[0], &mut styp[0], 200);
            let mut nm = Buf128 {};
            self.render_ident(self.name_span(fs.binding), &mut nm[0], 128);
            self.emit_str("{\n");
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_cstr(&styp[0]);
            self.emit_str(" = ");
            self.emit_expr(fs.iterable);
            self.emit_str(";\n");
            self.emit_indent();
            self.emit_str("for (");
            self.emit_binding(relem, self.name_span(fs.binding), false);
            self.buf.format_into(
                " = {}.start; {}.inclusive ? {} <= {}.end : {} < {}.end; {}++) {{\n",
                diag::cstr(&rr[0]),
                diag::cstr(&rr[0]),
                diag::cstr(&nm[0]),
                diag::cstr(&rr[0]),
                diag::cstr(&nm[0]),
                diag::cstr(&rr[0]),
                diag::cstr(&nm[0]),
            );
            self.depth = self.depth + 1;
            let dbase = self.defer_top;
            for i in 0..stmts.len {
                self.emit_indent();
                self.emit_stmt(unsafe (*self.cur_ast()).list(stmts)[i as usize]);
            }
            self.cg_loop_body_tail(dbase, le);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            return;
        }
        // Iterator protocol
        let bt = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(fs.iterable)));
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if bt.kind == TypeKind::TYPE_STRUCT {
            om = bt.module;
            od = bt.as_data.decl;
        } else if bt.kind == TypeKind::TYPE_INSTANCE {
            let ii = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
            om = ii.module;
            od = ii.decl;
        }
        let mut nx = DefId { module: 0, node: NODE_NONE };
        if od != NODE_NONE {
            nx = self.cg_find_method_cstr(om, od, "next".ptr() as *const char);
        }
        if nx.node != NODE_NONE {
            let na = self.mod_ast(nx.module);
            let rets = unsafe (*na).at_const(nx.node).as_data.function.returns;
            let r0 = unsafe (*na).list(rets)[0];
            let rn = unsafe (*na).at_const(r0);
            let opt = unsafe (*na).resolution_def(
                if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0),
            );
            let elem = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            if opt.node != NODE_NONE && elem != TYPE_NONE {
                let oa = self.mod_ast(opt.module);
                let mem = unsafe (*oa).at_const(opt.node).as_data.aggregate.members;
                let mut some = NODE_NONE;
                let mut none2 = NODE_NONE;
                let mut i: u32 = 0;
                while i < mem.len {
                    let vid = unsafe (*oa).list(mem)[i as usize];
                    let v = unsafe (*oa).at_const(vid);
                    if v.kind == NodeKind::NODE_VARIANT {
                        let vs = unsafe (*oa).at_const(v.as_data.variant.name).as_data.name.text;
                        if span_is(self.mod_src(opt.module), vs, "Some".ptr() as *const char) {
                            some = vid;
                        } else if span_is(self.mod_src(opt.module), vs, "None".ptr() as *const char) {
                            none2 = vid;
                        }
                    }
                    i = i + 1;
                }
                if some != NODE_NONE && none2 != NODE_NONE {
                    let optTy = unsafe (*self.cur_ast()).intern_instance(opt.module, opt.node, &elem, 1);
                    let mut itn = Buf32 {};
                    let mut ov = Buf32 {};
                    self.fresh(&mut itn[0], 32);
                    self.fresh(&mut ov[0], 32);
                    let mut vn = Buf128 {};
                    self.render_variant_name(opt.module, some, &mut vn[0], 128);
                    self.emit_str("{\n");
                    self.depth = self.depth + 1;
                    self.emit_indent();
                    self.buf.format_into("__auto_type {} = ", diag::cstr(&itn[0]));
                    self.emit_expr(fs.iterable);
                    self.emit_str(";\n");
                    self.emit_indent();
                    self.emit_str("for (;;) {\n");
                    self.depth = self.depth + 1;
                    self.emit_indent();
                    let mut odecl = Buf256 {};
                    self.render_type_id(optTy, &ov[0], &mut odecl[0], 256);
                    self.emit_cstr(&odecl[0]);
                    self.emit_str(" = ");
                    if bt.kind == TypeKind::TYPE_INSTANCE {
                        let mut inm = Buf256 {};
                        self.inst_name(unsafe (*self.cur_ast()).instance(bt.as_data.inst), &mut inm[0], 200);
                        self.emit_cstr(&inm[0]);
                        self.emit_paste();
                        self.emit_str("__");
                    } else {
                        let mut pfx = Buf64 {};
                        self.render_modpfx(nx.module, &mut pfx[0], 64);
                        self.emit_cstr(&pfx[0]);
                        self.emit_ident_mod(om, unsafe (*self.mod_ast(om)).at_const(od).as_data.aggregate.name);
                        self.emit_str("__");
                    }
                    self.emit_ident_mod(
                        nx.module,
                        unsafe (*self.mod_ast(nx.module)).at_const(nx.node).as_data.function.name,
                    );
                    self.buf.format_into("(&{});\n", diag::cstr(&itn[0]));
                    self.emit_indent();
                    self.buf.format_into("if ({}.tag == ", diag::cstr(&ov[0]));
                    self.emit_tag_mod(opt.module, opt.node, none2);
                    self.emit_str(") break;\n");
                    self.emit_indent();
                    self.emit_binding(elem, self.name_span(fs.binding), true);
                    self.buf.format_into(" = {}.payload.{}._0;\n", diag::cstr(&ov[0]), diag::cstr(&vn[0]));
                    let dbase = self.defer_top;
                    i = 0;
                    while i < stmts.len {
                        self.emit_indent();
                        self.emit_stmt(unsafe (*self.cur_ast()).list(stmts)[i as usize]);
                        i = i + 1;
                    }
                    self.cg_loop_body_tail(dbase, le);
                    self.depth = self.depth - 1;
                    self.emit_indent();
                    self.emit_str("}\n");
                    self.depth = self.depth - 1;
                    self.emit_indent();
                    self.emit_str("}\n");
                    return;
                }
            }
        }
        let sp = unsafe (*self.cur_ast()).at_const(id).span;
        self.errors.emit(sp.start, sp.end - sp.start, format("codegen: cannot iterate over a non-array/slice value"));
    }
    fn emit_initializer(self: &mut Self, tn: NodeId, val: NodeId) {
        if unsafe (*self.cur_ast()).at_const(val).kind == NodeKind::NODE_ARRAY_LITERAL && tn != NODE_NONE && unsafe (*self.cur_ast()).at_const(
            tn,
        ).kind == NodeKind::NODE_ARRAY_TYPE {
            self.emit_array_braces(val);
        } else {
            self.emit_expr(val);
        }
    }
    fn render_binding_id(self: &mut Self, t: TypeId, name: *const char, is_const: bool, out: *mut char, cap: usize) {
        let k = self.type_at(t).kind;
        if is_const && (k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE) {
            let mut cn = Buf256 {};
            buf_join3(&mut cn[0], 200, "const ".ptr() as *const char, "".ptr() as *const char, name);
            self.render_type_id(t, &cn[0], out, cap);
        } else if is_const {
            let mut body = Buf512 {};
            self.render_type_id(t, name, &mut body[0], 512);
            buf_join3(out, cap, "const ".ptr() as *const char, "".ptr() as *const char, &body[0]);
        } else {
            self.render_type_id(t, name, out, cap);
        }
    }
    fn cg_arm_frees(self: &mut Self, pid: NodeId, do_emit: bool) i32 {
        let p = *unsafe (*self.cur_ast()).at_const(pid);
        let pk = p.kind;
        if pk == NodeKind::NODE_PATTERN_NAME || pk == NodeKind::NODE_IDENTIFIER {
            let mut nm = p.as_data.name.text;
            if pk == NodeKind::NODE_PATTERN_NAME {
                nm = self.name_span(p.as_data.pattern.name);
                let vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
                if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                    return 0;
                }
            }
            let t = unsafe (*self.cur_ast()).type_of(pid);
            if !self.cg_type_is_free(t) || self.cg_is_moved(pid) || self.cg_is_cond_moved(pid) {
                return 0;
            }
            if do_emit {
                self.emit_indent();
                self.emit_free_target(t);
                let mut b = Buf128 {};
                self.render_ident(nm, &mut b[0], 128);
                self.buf.format_into("(&{});\n", diag::cstr(&b[0]));
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_TUPLE {
            let ch = p.as_data.pattern.children;
            let mut nn: i32 = 0;
            for i in 0..ch.len {
                nn = nn + self.cg_arm_frees(unsafe (*self.cur_ast()).list(ch)[i as usize], do_emit);
            }
            return nn;
        }
        if pk == NodeKind::NODE_PATTERN_STRUCT {
            let ch = p.as_data.pattern.children;
            let mut nn: i32 = 0;
            for i in 0..ch.len {
                let sub = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(ch)[i as usize]).as_data.pattern.children;
                if sub.len != 0 {
                    nn = nn + self.cg_arm_frees(unsafe (*self.cur_ast()).list(sub)[0], do_emit);
                }
            }
            return nn;
        }
        if pk == NodeKind::NODE_PATTERN_OR {
            let alts = p.as_data.pattern.children;
            if alts.len != 0 {
                return self.cg_arm_frees(unsafe (*self.cur_ast()).list(alts)[0], do_emit);
            }
            return 0;
        }
        return 0;
    }
    fn emit_arm_body(self: &mut Self, body: NodeId, mode: i32, result: *const char, pattern: NodeId, by_ref: bool) {
        let bt0 = unsafe (*self.cur_ast()).type_of(body);
        if bt0 != TYPE_NONE && self.type_at(bt0).kind == TypeKind::TYPE_NEVER {
            self.emit_indent();
            self.emit_expr(body);
            self.emit_str(";\n");
            return;
        }
        let mut frees: i32 = 0;
        if !by_ref {
            frees = self.cg_arm_frees(pattern, false);
        }
        if mode == 2 {
            self.emit_indent();
            if frees == 0 {
                self.emit_str("return ");
                self.emit_expr(body);
                self.emit_str(";\n");
                return;
            }
            let rt = unsafe (*self.cur_ast()).type_of(body);
            let mut voidret = rt == TYPE_NONE;
            if rt != TYPE_NONE {
                voidret = self.type_at(rt).kind == TypeKind::TYPE_BUILTIN && self.type_at(rt).as_data.builtin == BuiltinType::BT_VOID;
            }
            let mut r = Buf32 {};
            if voidret {
                self.emit_str("{ ");
                self.emit_expr(body);
                self.emit_str(";\n");
            } else {
                self.fresh(&mut r[0], 32);
                self.buf.format_into("{{ __auto_type {} = ", diag::cstr(&r[0]));
                self.emit_expr(body);
                self.emit_str(";\n");
            }
            self.cg_arm_frees(pattern, true);
            self.emit_indent();
            if voidret {
                self.emit_str("return; }\n");
            } else {
                self.buf.format_into("return {}; }}\n", diag::cstr(&r[0]));
            }
            return;
        }
        if mode == 1 {
            self.emit_indent();
            self.buf.format_into("{} = ", diag::cstr(result));
            self.emit_expr(body);
            self.emit_str(";\n");
        } else if unsafe (*self.cur_ast()).at_const(body).kind == NodeKind::NODE_BLOCK {
            self.emit_indent();
            self.emit_block(body);
            self.emit_str("\n");
        } else if unsafe (*self.cur_ast()).at_const(body).kind == NodeKind::NODE_MATCH {
            self.emit_indent();
            self.emit_match_stmt(body);
        } else if unsafe (*self.cur_ast()).at_const(body).kind == NodeKind::NODE_IF {
            self.emit_indent();
            self.emit_if(body);
            self.emit_str("\n");
        } else {
            self.emit_indent();
            self.emit_expr(body);
            self.emit_str(";\n");
        }
        if frees != 0 {
            self.cg_arm_frees(pattern, true);
        }
    }
    fn emit_match_core(self: &mut Self, id: NodeId, mode: i32, result: *const char) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let mut scrut = Buf32 {};
        self.fresh(&mut scrut[0], 32);
        let outer = unsafe (*self.cur_ast()).type_of(n.as_data.match_expr.value);
        let mut derefs: u32 = 0;
        let mut base = outer;
        let mut y = self.type_at(base);
        while y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            base = y.as_data.elem;
            derefs = derefs + 1;
            y = self.type_at(base);
        }
        let by_ref = derefs > 0;
        let mut mut_ref = false;
        if by_ref {
            mut_ref = self.type_at(outer).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8;
        }
        let bk = self.type_at(base).kind;
        let mut access = Buf64 {};
        self.emit_indent();
        if by_ref {
            let mut aggr = Buf256 {};
            self.render_type_id(base, "".ptr() as *const char, &mut aggr[0], 256);
            let mut cq = "const ".ptr() as *const char;
            if mut_ref {
                cq = "".ptr() as *const char;
            }
            self.buf.format_into("{}{} *const {} = ", diag::cstr(cq), diag::cstr(&aggr[0]), diag::cstr(&scrut[0]));
            let mut i: u32 = 0;
            while i + 1 < derefs {
                self.emit_str("(*");
                i = i + 1;
            }
            self.emit_expr(n.as_data.match_expr.value);
            i = 0;
            while i + 1 < derefs {
                self.emit_str(")");
                i = i + 1;
            }
            unsafe stdio::snprintf(&mut access[0], 40, "(*%s)".ptr() as *const char, &scrut[0]);
        } else if bk == TypeKind::TYPE_ERROR || bk == TypeKind::TYPE_FUNCTION || bk == TypeKind::TYPE_GENERIC {
            self.buf.format_into("const __auto_type {} = ", diag::cstr(&scrut[0]));
            self.emit_expr(n.as_data.match_expr.value);
            unsafe stdio::snprintf(&mut access[0], 40, "%s".ptr() as *const char, &scrut[0]);
        } else {
            let mut d = Buf512 {};
            self.render_binding_id(base, &scrut[0], true, &mut d[0], 300);
            self.emit_cstr(&d[0]);
            self.emit_str(" = ");
            self.emit_expr(n.as_data.match_expr.value);
            unsafe stdio::snprintf(&mut access[0], 40, "%s".ptr() as *const char, &scrut[0]);
        }
        self.emit_str(";\n");
        let accp = (&access[0]) as *const char;
        let arms = n.as_data.match_expr.arms;
        let mut has_guard = false;
        let mut i: u32 = 0;
        while i < arms.len {
            if unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(arms)[i as usize]).as_data.match_arm.guard != NODE_NONE {
                has_guard = true;
            }
            i = i + 1;
        }
        if !has_guard {
            i = 0;
            while i < arms.len {
                let arm = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(arms)[i as usize]).as_data.match_arm;
                self.emit_indent();
                if i != 0 {
                    self.emit_str("else if (");
                } else {
                    self.emit_str("if (");
                }
                self.emit_pattern_test(arm.pattern, accp);
                self.emit_str(") {\n");
                self.depth = self.depth + 1;
                self.emit_pattern_binds(arm.pattern, accp, by_ref);
                self.emit_arm_body(arm.body, mode, result, arm.pattern, by_ref);
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_str("}\n");
                i = i + 1;
            }
            if mode != 0 && arms.len > 0 {
                self.emit_indent();
                self.emit_str("else { __builtin_unreachable(); }\n");
            }
            return;
        }
        self.emit_indent();
        self.emit_str("do {\n");
        self.depth = self.depth + 1;
        i = 0;
        while i < arms.len {
            let arm = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(arms)[i as usize]).as_data.match_arm;
            let guard = arm.guard;
            self.emit_indent();
            self.emit_str("if (");
            self.emit_pattern_test(arm.pattern, accp);
            self.emit_str(") {\n");
            self.depth = self.depth + 1;
            self.emit_pattern_binds(arm.pattern, accp, by_ref);
            if guard != NODE_NONE {
                self.emit_indent();
                self.emit_str("if (");
                self.emit_condition(guard);
                self.emit_str(") {\n");
                self.depth = self.depth + 1;
            }
            self.emit_arm_body(arm.body, mode, result, arm.pattern, by_ref);
            if mode != 2 {
                self.emit_indent();
                self.emit_str("break;\n");
            }
            if guard != NODE_NONE {
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_str("}\n");
            }
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_str("}\n");
            i = i + 1;
        }
        if mode != 0 {
            self.emit_indent();
            self.emit_str("__builtin_unreachable();\n");
        }
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("} while (0);\n");
    }
    fn cg_enum_variant(self: &Self, m: ModuleId, enumDecl: NodeId, lit: *const char) NodeId {
        let a = self.mod_ast(m);
        let e = unsafe (*a).at_const(enumDecl);
        if e.kind != NodeKind::NODE_ENUM {
            return NODE_NONE;
        }
        let ms = e.as_data.aggregate.members;
        for i in 0..ms.len {
            let vid = unsafe (*a).list(ms)[i as usize];
            let v = unsafe (*a).at_const(vid);
            if v.kind == NodeKind::NODE_VARIANT && span_is(
                self.mod_src(m),
                unsafe (*a).at_const(v.as_data.variant.name).as_data.name.text,
                lit,
            ) {
                return vid;
            }
        }
        return NODE_NONE;
    }
    fn cg_method_extend_target(self: &Self, md: DefId) DefId {
        let a = self.mod_ast(md.module);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND {
                let ms = it.as_data.extend_def.items;
                for j in 0..ms.len {
                    if unsafe (*a).list(ms)[j as usize] == md.node {
                        return unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                    }
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_will_auto_free(self: &mut Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_LET && unsafe (*self.cur_ast()).at_const(n.as_data.let_stmt.name).kind == NodeKind::NODE_PATTERN_TUPLE {
            return false;
        }
        if self.cg_is_moved(id) {
            return false;
        }
        return self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(id));
    }
    fn cg_register_auto_free(self: &mut Self, id: NodeId) {
        if self.defer_top >= 256 {
            return;
        }
        let t = self.defer_top;
        self.defer_stack[t as usize] = id;
        self.defer_kind[t as usize] = 1;
        self.defer_top = t + 1;
    }
    fn emit_capture_init(self: &mut Self, clos: NodeId, idx: u32) {
        let caps = unsafe (*self.cur_ast()).at_const(clos).as_data.closure.captures;
        let mut_caps = (unsafe (*self.cur_ast()).at_const(clos).as_data.closure.mut_caps) as u64;
        let decl = unsafe (*self.cur_ast()).list(caps)[idx as usize];
        let want_ptr = (mut_caps >> idx as u64 & 1 as u64) != 0 as u64;
        let mut nm = Buf128 {};
        let csp = self.cg_decl_name_span(decl);
        self.render_ident(csp, &mut nm[0], 128);
        self.buf.format_into(".{} = ", diag::cstr(&nm[0]));
        let mut outer_mut = false;
        let oi = self.cg_env_capture(decl, &mut outer_mut);
        if want_ptr {
            if oi >= 0 && outer_mut {
                self.emit_str("");
            } else {
                self.emit_str("&");
            }
        } else if oi >= 0 && outer_mut {
            self.emit_str("*");
        }
        if oi >= 0 {
            self.emit_str("__env->");
        }
        self.emit_cstr(&nm[0]);
    }
    fn cg_mark_move(self: &mut Self, expr0: NodeId, cond: bool, site: bool) {
        if expr0 == NODE_NONE {
            return;
        }
        let mut expr = expr0;
        let mut go = true;
        while go {
            let me = unsafe (*self.cur_ast()).at_const(expr);
            if me.kind == NodeKind::NODE_UNARY && (me.as_data.unary.op == TokenType::Move || me.as_data.unary.op == TokenType::Unsafe) {
                expr = me.as_data.unary.operand;
            } else {
                go = false;
            }
        }
        let mek = unsafe (*self.cur_ast()).at_const(expr).kind;
        if mek == NodeKind::NODE_MEMBER {
            let is_path = unsafe (*self.cur_ast()).at_const(expr).as_data.member.path;
            let obj = unsafe (*self.cur_ast()).at_const(expr).as_data.member.object;
            if !is_path && self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(expr)) {
                self.cg_mark_move(obj, cond, false);
                return;
            }
        }
        if mek != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let d = unsafe (*self.cur_ast()).resolution_def(expr);
        if d.module != self.cur_module() || d.node == NODE_NONE {
            return;
        }
        let dk = unsafe (*self.cur_ast()).at_const(d.node).kind;
        let mut tuple_elem = false;
        if dk == NodeKind::NODE_IDENTIFIER {
            let letid = unsafe (*self.cur_ast()).resolution(d.node);
            if letid != NODE_NONE && unsafe (*self.cur_ast()).at_const(letid).kind == NodeKind::NODE_LET {
                let lname = unsafe (*self.cur_ast()).at_const(letid).as_data.let_stmt.name;
                if unsafe (*self.cur_ast()).at_const(lname).kind == NodeKind::NODE_PATTERN_TUPLE {
                    tuple_elem = true;
                }
            }
        }
        if dk != NodeKind::NODE_LET && dk != NodeKind::NODE_PARAMETER && dk != NodeKind::NODE_PATTERN_NAME && !tuple_elem {
            return;
        }
        if !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(expr)) {
            return;
        }
        // CG-21: unconditional moves are recorded inline (the old pass 0); conditional candidates
        // become replay events so the moved[]-suppression sees the complete set (the old pass 1).
        if !cond || dk == NodeKind::NODE_PATTERN_NAME {
            if self.nmoved < 512 {
                self.moved[self.nmoved as usize] = d.node;
                self.nmoved = self.nmoved + 1;
                if d.node as usize < self.stamp_cap {
                    unsafe self.moved_stamp[d.node as usize] = self.move_epoch;
                }
            }
            return;
        }
        let mut fl: u32 = 0;
        if site {
            fl = 1;
        }
        self.pend_moves.push(CgPendMove { decl: d.node, site: expr, flags: fl });
    }
    fn cg_mark_move_tail(self: &mut Self, e: NodeId, cond: bool) {
        if e == NODE_NONE {
            return;
        }
        let nk = unsafe (*self.cur_ast()).at_const(e).kind;
        if nk == NodeKind::NODE_MATCH {
            let arms = unsafe (*self.cur_ast()).at_const(e).as_data.match_expr.arms;
            let ids = unsafe (*self.cur_ast()).list(arms);
            for i in 0..arms.len {
                let body = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.match_arm.body;
                self.cg_mark_move_tail(body, true);
            }
        } else if nk == NodeKind::NODE_IF {
            let tb = unsafe (*self.cur_ast()).at_const(e).as_data.if_stmt.then_branch;
            let eb = unsafe (*self.cur_ast()).at_const(e).as_data.if_stmt.else_branch;
            self.cg_mark_move_tail(tb, true);
            self.cg_mark_move_tail(eb, true);
        } else if nk == NodeKind::NODE_BLOCK {
            let ss = unsafe (*self.cur_ast()).at_const(e).as_data.block.statements;
            if ss.len != 0 {
                let lastid = unsafe (*self.cur_ast()).list(ss)[(ss.len - 1) as usize];
                let lastk = unsafe (*self.cur_ast()).at_const(lastid).kind;
                if lastk == NodeKind::NODE_EXPRESSION_STATEMENT {
                    let lv = unsafe (*self.cur_ast()).at_const(lastid).as_data.single.value;
                    if unsafe (*self.cur_ast()).at_const(lv).kind != NodeKind::NODE_ASSIGNMENT {
                        self.cg_mark_move_tail(lv, cond);
                    }
                }
            }
        } else {
            self.cg_mark_move(e, cond, true);
        }
    }
    fn cg_scan_moves(self: &mut Self, id: NodeId, cond: bool) {
        if id == NODE_NONE {
            return;
        }
        let nk = unsafe (*self.cur_ast()).at_const(id).kind;
        if nk == NodeKind::NODE_BLOCK {
            let ss = unsafe (*self.cur_ast()).at_const(id).as_data.block.statements;
            let ids = unsafe (*self.cur_ast()).list(ss);
            for i in 0..ss.len {
                self.cg_scan_moves(unsafe ids[i as usize], cond);
            }
        } else if nk == NodeKind::NODE_LET {
            let v = unsafe (*self.cur_ast()).at_const(id).as_data.let_stmt.value;
            self.cg_mark_move_tail(v, cond);
            self.cg_scan_moves(v, cond);
        } else if nk == NodeKind::NODE_RETURN {
            let vs = unsafe (*self.cur_ast()).at_const(id).as_data.return_stmt.values;
            let ids = unsafe (*self.cur_ast()).list(vs);
            for i in 0..vs.len {
                let vid = unsafe ids[i as usize];
                self.cg_mark_move_tail(vid, cond);
                self.cg_scan_moves(vid, cond);
            }
        } else if nk == NodeKind::NODE_ASSIGNMENT {
            let l = unsafe (*self.cur_ast()).at_const(id).as_data.binary.left;
            let r = unsafe (*self.cur_ast()).at_const(id).as_data.binary.right;
            self.cg_mark_move_tail(r, cond);
            self.cg_scan_moves(l, cond);
            self.cg_scan_moves(r, cond);
        } else if nk == NodeKind::NODE_STRUCT_INITIALIZER {
            let fs = unsafe (*self.cur_ast()).at_const(id).as_data.struct_initializer.fields;
            let ids = unsafe (*self.cur_ast()).list(fs);
            for i in 0..fs.len {
                let v = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.field_initializer.value;
                self.cg_mark_move_tail(v, cond);
                self.cg_scan_moves(v, cond);
            }
        } else if nk == NodeKind::NODE_IF {
            let cnd = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt.condition;
            let tb = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt.then_branch;
            let eb = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt.else_branch;
            self.cg_scan_moves(cnd, cond);
            self.cg_scan_moves(tb, true);
            self.cg_scan_moves(eb, true);
        } else if nk == NodeKind::NODE_WHILE {
            let cnd = unsafe (*self.cur_ast()).at_const(id).as_data.while_stmt.condition;
            let b = unsafe (*self.cur_ast()).at_const(id).as_data.while_stmt.body;
            self.cg_scan_moves(cnd, cond);
            self.cg_scan_moves(b, true);
        } else if nk == NodeKind::NODE_FOR {
            let it = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt.iterable;
            let b = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt.body;
            self.cg_scan_moves(it, cond);
            self.cg_scan_moves(b, true);
        } else if nk == NodeKind::NODE_MATCH {
            let val = unsafe (*self.cur_ast()).at_const(id).as_data.match_expr.value;
            self.cg_mark_move(val, cond, true);
            self.cg_scan_moves(val, cond);
            let arms = unsafe (*self.cur_ast()).at_const(id).as_data.match_expr.arms;
            let ids = unsafe (*self.cur_ast()).list(arms);
            for i in 0..arms.len {
                let body = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.match_arm.body;
                self.cg_scan_moves(body, true);
            }
        } else if nk == NodeKind::NODE_EXPRESSION_STATEMENT || nk == NodeKind::NODE_DEFER {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.single.value, cond);
        } else if nk == NodeKind::NODE_CALL {
            let callee_id = unsafe (*self.cur_ast()).at_const(id).as_data.call.callee;
            self.cg_scan_moves(callee_id, cond);
            let ck = unsafe (*self.cur_ast()).at_const(callee_id).kind;
            if ck == NodeKind::NODE_MEMBER {
                let cpath = unsafe (*self.cur_ast()).at_const(callee_id).as_data.member.path;
                let cmember = unsafe (*self.cur_ast()).at_const(callee_id).as_data.member.member;
                let cobj = unsafe (*self.cur_ast()).at_const(callee_id).as_data.member.object;
                if !cpath && span_is(
                    self.mod_src(self.cur_module()),
                    unsafe (*self.cur_ast()).at_const(cmember).as_data.name.text,
                    "free".ptr() as *const char,
                ) {
                    let rk = unsafe (*self.cur_ast()).type_at(unsafe (*self.cur_ast()).type_of(cobj)).kind;
                    if rk != TypeKind::TYPE_POINTER && rk != TypeKind::TYPE_REFERENCE {
                        self.cg_mark_move(cobj, cond, false);
                    }
                } else if !cpath {
                    let md = unsafe (*self.cur_ast()).resolution_def(cmember);
                    if md.node != NODE_NONE {
                        let mnk = unsafe (*self.mod_ast(md.module)).at_const(md.node).kind;
                        let mparams = unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.params;
                        if mnk == NodeKind::NODE_FUNCTION && mparams.len > 0 {
                            let p0 = unsafe (*self.mod_ast(md.module)).list(mparams)[0];
                            let pt = unsafe (*self.mod_ast(md.module)).at_const(p0).as_data.parameter.ty;
                            let ptk = if pt != NODE_NONE {
                                unsafe (*self.mod_ast(md.module)).at_const(pt).kind;
                            } else {
                                NodeKind::NODE_NONE_KIND;
                            };
                            if ptk != NodeKind::NODE_POINTER_TYPE && ptk != NodeKind::NODE_REFERENCE_TYPE {
                                self.cg_mark_move(cobj, cond, true);
                            }
                        }
                    }
                }
            }
            let args = unsafe (*self.cur_ast()).at_const(id).as_data.call.args;
            let ids = unsafe (*self.cur_ast()).list(args);
            for i in 0..args.len {
                let aid = unsafe ids[i as usize];
                self.cg_mark_move(aid, cond, true);
                self.cg_scan_moves(aid, cond);
            }
        } else if nk == NodeKind::NODE_CLOSURE {
            let caps = unsafe (*self.cur_ast()).at_const(id).as_data.closure.captures;
            let mut_caps = (unsafe (*self.cur_ast()).at_const(id).as_data.closure.mut_caps) as u64;
            let cids = unsafe (*self.cur_ast()).list(caps);
            for i in 0..caps.len {
                let decl = unsafe cids[i as usize];
                if (mut_caps >> i as u64 & 1 as u64) != 0 as u64 || !self.cg_type_is_free(
                    unsafe (*self.cur_ast()).type_of(decl),
                ) {
                    continue;
                }
                let patb = unsafe (*self.cur_ast()).at_const(decl).kind == NodeKind::NODE_PATTERN_NAME;
                // CG-21: same split as cg_mark_move -- unconditional inline, conditional as an
                // event (flag bit1 = closure; replay pushes the closure site once per group).
                if !cond || patb {
                    if self.nmoved < 512 {
                        self.moved[self.nmoved as usize] = decl;
                        self.nmoved = self.nmoved + 1;
                        if decl as usize < self.stamp_cap {
                            unsafe self.moved_stamp[decl as usize] = self.move_epoch;
                        }
                    }
                    continue;
                }
                self.pend_moves.push(CgPendMove { decl: decl, site: id, flags: 2 });
            }
        } else if nk == NodeKind::NODE_BINARY {
            let l = unsafe (*self.cur_ast()).at_const(id).as_data.binary.left;
            let r = unsafe (*self.cur_ast()).at_const(id).as_data.binary.right;
            let op = unsafe (*self.cur_ast()).at_const(id).as_data.binary.op;
            self.cg_scan_moves(l, cond);
            self.cg_scan_moves(r, cond || op == TokenType::AmpersandAmpersand || op == TokenType::PipePipe);
        } else if nk == NodeKind::NODE_UNARY {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.unary.operand, cond);
        } else if nk == NodeKind::NODE_MEMBER {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.member.object, cond);
        } else if nk == NodeKind::NODE_INDEX {
            let o = unsafe (*self.cur_ast()).at_const(id).as_data.index.object;
            let ix = unsafe (*self.cur_ast()).at_const(id).as_data.index.index;
            self.cg_scan_moves(o, cond);
            self.cg_scan_moves(ix, cond);
        } else if nk == NodeKind::NODE_CAST {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.cast.expression, cond);
        }
    }
    // CG-21: replay the conditional-move events in traversal order against the now-complete
    // moved[] set -- exactly the old pass 1's view. Closure events for one closure are contiguous
    // (the closure arm never recurses between captures), so a site is pushed once per closure on
    // its first surviving capture, matching the old site_pushed flag.
    fn cg_replay_cond_moves(self: &mut Self) {
        let mut last_clos = NODE_NONE;
        let mut clos_pushed = false;
        for i in 0..self.pend_moves.len() {
            let ev = *self.pend_moves.at(i);
            if (ev.flags & 2) != 0 {
                if ev.site != last_clos {
                    last_clos = ev.site;
                    clos_pushed = false;
                }
                if self.cg_is_moved(ev.decl) {
                    continue;
                }
                if !self.cg_is_cond_moved(ev.decl) && self.ncond_moved < 256 {
                    self.cond_moved[self.ncond_moved as usize] = ev.decl;
                    self.ncond_moved = self.ncond_moved + 1;
                    if ev.decl as usize < self.stamp_cap {
                        unsafe self.cond_stamp[ev.decl as usize] = self.move_epoch;
                    }
                }
                if !clos_pushed && self.ncond_sites < 256 {
                    self.cond_sites[self.ncond_sites as usize] = ev.site;
                    self.ncond_sites = self.ncond_sites + 1;
                    clos_pushed = true;
                }
                continue;
            }
            last_clos = NODE_NONE;
            if self.cg_is_moved(ev.decl) {
                continue;
            }
            if !self.cg_is_cond_moved(ev.decl) && self.ncond_moved < 256 {
                self.cond_moved[self.ncond_moved as usize] = ev.decl;
                self.ncond_moved = self.ncond_moved + 1;
                if ev.decl as usize < self.stamp_cap {
                    unsafe self.cond_stamp[ev.decl as usize] = self.move_epoch;
                }
            }
            if (ev.flags & 1) != 0 && self.ncond_sites < 256 {
                self.cond_sites[self.ncond_sites as usize] = ev.site;
                self.ncond_sites = self.ncond_sites + 1;
            }
        }
    }
    fn emit_arith_overload(self: &mut Self, id: NodeId) bool {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let m = cg_arith_op_method(bd.op);
        if m == null {
            return false;
        }
        let lt0 = unsafe (*self.cur_ast()).type_of(bd.left);
        if lt0 == TYPE_NONE {
            return false;
        }
        let lt = self.strip_ref_only(self.subst_resolve(lt0));
        if lt == TYPE_NONE {
            return false;
        }
        let bt = *self.type_at(lt);
        if bt.kind != TypeKind::TYPE_STRUCT && bt.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if bt.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
            om = it.module;
            od = it.decl;
        } else {
            om = bt.module;
            od = bt.as_data.decl;
        }
        let mth = self.cg_find_method_cstr(om, od, m);
        if mth.node == NODE_NONE {
            return false;
        }
        let rt0 = unsafe (*self.cur_ast()).type_of(bd.right);
        let dl = self.cg_ref_depth(self.subst_resolve(unsafe (*self.cur_ast()).type_of(bd.left)));
        let mut dr: i32 = 0;
        if rt0 != TYPE_NONE {
            dr = self.cg_ref_depth(self.subst_resolve(rt0));
        }
        let mut l = Buf32 {};
        let mut r = Buf32 {};
        self.fresh(&mut l[0], 32);
        self.fresh(&mut r[0], 32);
        self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&l[0]));
        self.emit_expr(bd.left);
        self.buf.format_into("; __auto_type {} = ", diag::cstr(&r[0]));
        self.emit_expr(bd.right);
        self.emit_str("; ");
        self.emit_op_method(bt, om, od, mth);
        let mut lp = "&".ptr() as *const char;
        if dl != 0 {
            lp = ref_derefs(dl);
        }
        let mut rp = "&".ptr() as *const char;
        if dr != 0 {
            rp = ref_derefs(dr);
        }
        self.buf.format_into("({}{}, {}{}); }})", diag::cstr(lp), diag::cstr(&l[0]), diag::cstr(rp), diag::cstr(&r[0]));
        return true;
    }
    fn emit_cg_checked_arith(self: &mut Self, id: NodeId) bool {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let op = bd.op;
        let add = op == TokenType::Plus;
        let sub = op == TokenType::Minus;
        let mul = op == TokenType::Star;
        let dv = op == TokenType::Slash;
        let rm = op == TokenType::Percent;
        let shl = op == TokenType::LeftShift;
        let shr = op == TokenType::RightShift;
        if !(add || sub || mul || dv || rm || shl || shr) {
            return false;
        }
        let rt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
        if rt == TYPE_NONE {
            return false;
        }
        let ry = *self.type_at(rt);
        if ry.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let b = ry.as_data.builtin;
        let sgn = b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
        let uns = b == BuiltinType::BT_U8 || b == BuiltinType::BT_U16 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_USIZE;
        if !sgn && !uns {
            return false;
        }
        let lnode = bd.left;
        let rnode = bd.right;
        let lt = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(lnode)));
        let rtt = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(rnode)));
        if lt.kind != TypeKind::TYPE_BUILTIN || rtt.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bits: i32 = if b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 {
            8;
        } else if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 {
            16;
        } else if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 {
            32;
        } else {
            64;
        };
        let mut lv: i64 = 0;
        let mut rv: i64 = 0;
        let ll = self.cg_int_lit(lnode, &mut lv);
        let rl = self.cg_int_lit(rnode, &mut rv);
        if ll && rl {
            let mut bad: *const char = null;
            if (dv || rm) && rv == 0 {
                bad = "constant division by zero".ptr() as *const char;
            } else if shl || shr {
                if rv < 0 || rv >= bits as i64 {
                    bad = "constant shift out of range".ptr() as *const char;
                }
            } else if sgn && (dv || rm) && rv == -1 && lv == (1 as u64 << 63) as i64 {
                bad = "constant arithmetic overflow".ptr() as *const char;
            } else if sgn {
                let mut ov = false;
                let mut res: i64 = 0;
                if add {
                    let u = lv as u64 + rv as u64;
                    res = u as i64;
                    if ((lv ^ res) & (rv ^ res)) < 0 {
                        ov = true;
                    }
                } else if sub {
                    let u = lv as u64 - rv as u64;
                    res = u as i64;
                    if ((lv ^ rv) & (lv ^ res)) < 0 {
                        ov = true;
                    }
                } else if mul {
                    let u = lv as u64 * rv as u64;
                    res = u as i64;
                } else if dv {
                    res = lv / rv;
                } else {
                    res = lv % rv;
                }
                let mut mn: i64 = 0;
                let mut mx: i64 = 0;
                cg_int_range(b, &mut mn, &mut mx);
                if ov || res < mn || res > mx {
                    bad = "constant arithmetic overflow".ptr() as *const char;
                }
            }
            if bad != null {
                let sp = unsafe (*self.cur_ast()).at_const(id).span;
                self.errors.emit(sp.start, sp.end - sp.start, format("{}", diag::cstr(bad)));
            }
        }
        if self.const_ctx {
            return false;
        }
        let mut rts = Buf64 {};
        self.render_type_id(rt, "".ptr() as *const char, &mut rts[0], 64);
        let rtsp = (&rts[0]) as *const char;
        if sgn && (add || sub || mul) {
            let bn = if add {
                "add".ptr() as *const char;
            } else if sub {
                "sub".ptr() as *const char;
            } else {
                "mul".ptr() as *const char;
            };
            self.buf.format_into("({{ {} __sc_r; if (__builtin_{}_overflow(", diag::cstr(rtsp), diag::cstr(bn));
            self.emit_expr(lnode);
            self.emit_str(", ");
            self.emit_expr(rnode);
            self.emit_str(", &__sc_r)) { __sc_panic(\"arithmetic overflow\"); } __sc_r; })");
            return true;
        }
        if uns && (add || sub || mul) && bits < 32 {
            let opc = if add {
                "+".ptr() as *const char;
            } else if sub {
                "-".ptr() as *const char;
            } else {
                "*".ptr() as *const char;
            };
            self.buf.format_into("(({})((uint32_t)", diag::cstr(rtsp));
            self.emit_expr(lnode);
            self.buf.format_into(" {} (uint32_t)", diag::cstr(opc));
            self.emit_expr(rnode);
            self.emit_str("))");
            return true;
        }
        if shl || shr {
            let uts = if bits == 8 {
                "uint8_t".ptr() as *const char;
            } else if bits == 16 {
                "uint16_t".ptr() as *const char;
            } else if bits == 32 {
                "uint32_t".ptr() as *const char;
            } else {
                "uint64_t".ptr() as *const char;
            };
            let mut a = Buf32 {};
            let mut s = Buf32 {};
            self.fresh(&mut a[0], 32);
            self.fresh(&mut s[0], 32);
            let ap = (&a[0]) as *const char;
            let sp2 = (&s[0]) as *const char;
            self.buf.format_into("({{ {} {} = ", diag::cstr(rtsp), diag::cstr(ap));
            self.emit_expr(lnode);
            self.buf.format_into("; int64_t {} = (int64_t)(", diag::cstr(sp2));
            self.emit_expr(rnode);
            self.buf.format_into(
                "); if ((uint64_t){} >= {}) {{ __sc_panic(\"shift out of range\"); }} ",
                diag::cstr(sp2),
                bits,
            );
            if shl {
                self.buf.format_into(
                    "({})(({})(({}){} << {})); }})",
                    diag::cstr(rtsp),
                    diag::cstr(uts),
                    diag::cstr(uts),
                    diag::cstr(ap),
                    diag::cstr(sp2),
                );
            } else {
                self.buf.format_into("({})({} >> {}); }})", diag::cstr(rtsp), diag::cstr(ap), diag::cstr(sp2));
            }
            return true;
        }
        if dv || rm {
            let mut a = Buf32 {};
            let mut d = Buf32 {};
            self.fresh(&mut a[0], 32);
            self.fresh(&mut d[0], 32);
            let ap = (&a[0]) as *const char;
            let dp = (&d[0]) as *const char;
            self.buf.format_into("({{ {} {} = ", diag::cstr(rtsp), diag::cstr(ap));
            self.emit_expr(lnode);
            self.buf.format_into("; {} {} = ", diag::cstr(rtsp), diag::cstr(dp));
            self.emit_expr(rnode);
            self.buf.format_into("; if ({} == 0) {{ __sc_panic(\"divide by zero\"); }} ", diag::cstr(dp));
            if sgn {
                let mn = if bits == 8 {
                    "INT8_MIN".ptr() as *const char;
                } else if bits == 16 {
                    "INT16_MIN".ptr() as *const char;
                } else if bits == 32 {
                    "INT32_MIN".ptr() as *const char;
                } else {
                    "INT64_MIN".ptr() as *const char;
                };
                self.buf.format_into(
                    "if ({} == -1 && {} == {}) {{ __sc_panic(\"arithmetic overflow\"); }} ",
                    diag::cstr(dp),
                    diag::cstr(ap),
                    diag::cstr(mn),
                );
            }
            let opc = if dv {
                "/".ptr() as *const char;
            } else {
                "%".ptr() as *const char;
            };
            self.buf.format_into("({} {} {}); }})", diag::cstr(ap), diag::cstr(opc), diag::cstr(dp));
            return true;
        }
        return false;
    }
    fn emit_slice_coercion(self: &mut Self, id: NodeId) bool {
        let mut selem: TypeId = TYPE_NONE;
        let st = unsafe (*self.cur_ast()).type_of(id);
        if !self.cg_slice_elem(st, &mut selem) {
            return false;
        }
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let is_lit = n.kind == NodeKind::NODE_ARRAY_LITERAL;
        let mut lenN = NODE_NONE;
        if !is_lit {
            lenN = self.array_length_of(id);
        }
        if !is_lit && lenN == NODE_NONE {
            return false;
        }
        let mut styp = Buf256 {};
        self.render_type_id(st, "".ptr() as *const char, &mut styp[0], 200);
        self.buf.format_into("({}){{ .ptr = ", diag::cstr(&styp[0]));
        if is_lit {
            let mut et = Buf256 {};
            self.render_type_id(selem, "".ptr() as *const char, &mut et[0], 256);
            self.buf.format_into("({}[{}])", diag::cstr(&et[0]), n.as_data.array_literal.elements.len);
            self.emit_array_braces(id);
            self.buf.format_into(", .len = {} }}", n.as_data.array_literal.elements.len);
            return true;
        }
        self.slice_raw = id;
        self.emit_expr(id);
        self.slice_raw = NODE_NONE;
        self.emit_str(", .len = ");
        self.emit_expr(lenN);
        self.emit_str(" }");
        return true;
    }
    fn emit_dyn_coercion(self: &mut Self, id: NodeId) bool {
        let du = unsafe (*self.cur_ast()).dyn_use_at(id);
        if du == null {
            return false;
        }
        let src = unsafe (*du).src;
        let dynTy = unsafe (*du).dyn_ty;
        if src == TYPE_NONE {
            self.emit_str("(*(");
            self.dyn_raw = id;
            self.emit_expr(id);
            self.dyn_raw = NODE_NONE;
            self.emit_str("))");
            return true;
        }
        let dy = *self.type_at(dynTy);
        let mut dt = Buf256 {};
        let mut pair = Buf512 {};
        self.render_type_id(dynTy, "".ptr() as *const char, &mut dt[0], 240);
        if self.type_at(src).kind == TypeKind::TYPE_DYN {
            // upcast: same data, vtable swapped to the source vtable's __super_<target> embed
            let mut ss = Buf176 {};
            self.dyn_stem_dy(&dy, &mut ss[0], 176);
            let mut st = Buf256 {};
            self.render_type_id(src, "".ptr() as *const char, &mut st[0], 256);
            let mut utmp = Buf32 {};
            self.fresh(&mut utmp[0], 32);
            self.buf.format_into("({{ const {} {} = ", diag::cstr(&st[0]), diag::cstr(&utmp[0]));
            self.dyn_raw = id;
            self.emit_expr(id);
            self.dyn_raw = NODE_NONE;
            self.buf.format_into(
                "; ({}){{ {}.data, {}.vt->__super_{} }}; }})",
                diag::cstr(&dt[0]),
                diag::cstr(&utmp[0]),
                diag::cstr(&utmp[0]),
                diag::cstr(&ss[0]),
            );
            return true;
        }
        self.dyn_pair_stem_dy(src, &dy, &mut pair[0], 368);
        let nat = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(id)));
        if nat.kind == TypeKind::TYPE_FUNCTION {
            if !self.cg_fn_is_capturing(&nat) {
                self.buf.format_into("(({}){{ .data = 0, .vt = &{}__vtbl }})", diag::cstr(&dt[0]), diag::cstr(&pair[0]));
                return true;
            }
            let mut envn = Buf256 {};
            let mut gt = Buf256 {};
            let mut vtmp = Buf32 {};
            let mut gtmp = Buf32 {};
            let mut ptmp = Buf32 {};
            self.render_type_id(src, "".ptr() as *const char, &mut envn[0], 256);
            let gh = unsafe (*self.package).prelude_lookup("Global", true);
            self.render_qualified(
                gh.mid,
                unsafe (*self.mod_ast(gh.mid)).at_const(gh.node).as_data.aggregate.name,
                &mut gt[0],
                160,
            );
            self.fresh(&mut vtmp[0], 32);
            self.fresh(&mut gtmp[0], 32);
            self.fresh(&mut ptmp[0], 32);
            self.buf.format_into("({{ {} {} = ", diag::cstr(&envn[0]), diag::cstr(&vtmp[0]));
            self.dyn_raw = id;
            self.emit_expr(id);
            self.dyn_raw = NODE_NONE;
            self.buf.format_into(
                "; {} {} = {}__default_(); ",
                diag::cstr(&gt[0]),
                diag::cstr(&gtmp[0]),
                diag::cstr(&gt[0]),
            );
            self.buf.format_into(
                "{} *{} = ({} *){}__alloc(&{}, sizeof({}), _Alignof({})); *{} = {}; ",
                diag::cstr(&envn[0]),
                diag::cstr(&ptmp[0]),
                diag::cstr(&envn[0]),
                diag::cstr(&gt[0]),
                diag::cstr(&gtmp[0]),
                diag::cstr(&envn[0]),
                diag::cstr(&envn[0]),
                diag::cstr(&ptmp[0]),
                diag::cstr(&vtmp[0]),
            );
            self.buf.format_into(
                "(({}){{ .data = {}, .vt = &{}__vtbl }}); }})",
                diag::cstr(&dt[0]),
                diag::cstr(&ptmp[0]),
                diag::cstr(&pair[0]),
            );
            return true;
        }
        let box_src = nat.kind == TypeKind::TYPE_INSTANCE;
        self.buf.format_into("(({}){{ .data = (void *)(", diag::cstr(&dt[0]));
        self.dyn_raw = id;
        self.emit_expr(id);
        self.dyn_raw = NODE_NONE;
        let mut tail = ")".ptr() as *const char;
        if box_src {
            tail = ").ptr".ptr() as *const char;
        }
        self.buf.format_into("{}, .vt = &{}__vtbl }})", diag::cstr(tail), diag::cstr(&pair[0]));
        return true;
    }
    fn array_length_of(self: &mut Self, iter: NodeId) NodeId {
        if unsafe (*self.cur_ast()).at_const(iter).kind != NodeKind::NODE_IDENTIFIER {
            return NODE_NONE;
        }
        let d = unsafe (*self.cur_ast()).resolution(iter);
        if d == NODE_NONE {
            return NODE_NONE;
        }
        let dn = *unsafe (*self.cur_ast()).at_const(d);
        let mut tn = NODE_NONE;
        if dn.kind == NodeKind::NODE_PARAMETER {
            tn = dn.as_data.parameter.ty;
        } else if dn.kind == NodeKind::NODE_LET {
            tn = dn.as_data.let_stmt.ty;
        } else if dn.kind == NodeKind::NODE_FIELD {
            tn = dn.as_data.field.ty;
        }
        if tn != NODE_NONE && unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_ARRAY_TYPE {
            return unsafe (*self.cur_ast()).at_const(tn).as_data.array_type.length;
        }
        return NODE_NONE;
    }
    fn array_literal_count(self: &mut Self, obj: NodeId) i64 {
        let o = *unsafe (*self.cur_ast()).at_const(obj);
        if o.kind == NodeKind::NODE_ARRAY_LITERAL {
            return o.as_data.array_literal.elements.len;
        }
        if o.kind != NodeKind::NODE_IDENTIFIER {
            return -1;
        }
        let d = unsafe (*self.cur_ast()).resolution(obj);
        if d == NODE_NONE {
            return -1;
        }
        let dn = *unsafe (*self.cur_ast()).at_const(d);
        let mut v = NODE_NONE;
        if dn.kind == NodeKind::NODE_LET {
            v = dn.as_data.let_stmt.value;
        }
        if v != NODE_NONE && unsafe (*self.cur_ast()).at_const(v).kind == NodeKind::NODE_ARRAY_LITERAL {
            return unsafe (*self.cur_ast()).at_const(v).as_data.array_literal.elements.len;
        }
        return -1;
    }
    fn cg_int_lit(self: &mut Self, e: NodeId, out: *mut i64) bool {
        let n = *unsafe (*self.cur_ast()).at_const(e);
        if n.kind != NodeKind::NODE_LITERAL || n.as_data.literal.token_type != TokenType::IntegerLiteral {
            return false;
        }
        let raw = n.as_data.literal.raw;
        let mut buf = Buf32 {};
        let mut k: usize = 0;
        let mut i = raw.start;
        while i < raw.end && k + 1 < 32 {
            let ch = self.source[i as usize];
            if ch == b'_' {
                i = i + 1;
                continue;
            }
            if k == 0 && ch == b'0' && i + 1 < raw.end {
                buf[k] = ch as char;
                k = k + 1;
                i = i + 1;
                continue;
            }
            let hexish = ch >= b'0' && ch <= b'9' || ch >= b'a' && ch <= b'f' || ch >= b'A' && ch <= b'F' || ch == b'x' || ch == b'X' || ch == b'b' || ch == b'B' || ch == b'o' || ch == b'O';
            if !hexish {
                break;
            }
            buf[k] = ch as char;
            k = k + 1;
            i = i + 1;
        }
        buf[k] = 0 as char;
        if k == 0 {
            return false;
        }
        let mut endp: *mut char = null;
        let v = unsafe strtoll(&buf[0], &mut endp, 0);
        if endp == &mut buf[0] {
            return false;
        }
        unsafe *out = v;
        return true;
    }
    // CG-16: lazily build module m's (owner -> attr positions) chain, mirroring CG-4's scheme:
    // reverse insertion makes attr_head the FIRST table position per owner and attr_next walk
    // positions in table order, so chain queries see attrs exactly as the full scan did.
    fn cg_attr_index(self: &Self, m: ModuleId) {
        let bit = 1u64 << m as u64;
        if (self.attr_built & bit) != 0 {
            return;
        }
        let mp = (self as *const Codegen) as *mut Codegen;
        let a = self.mod_ast(m);
        let mut i = (unsafe (*a).attrs.len()) as i32 - 1;
        while i >= 0 {
            let key = m as u64 << 32 | (unsafe (*a).attrs.at(i as usize).owner) as u64;
            switch self.attr_head.get(&key) {
                Some(h) => {
                    unsafe {
                        (*mp).attr_next.insert(m as u64 << 32 | i as u64, *h);
                    }
                },
                _ => {},
            };
            unsafe {
                (*mp).attr_head.insert(key, i as u32);
            }
            i -= 1;
        }
        unsafe {
            (*mp).attr_built = self.attr_built | bit;
        }
    }
    fn cg_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) *const Attr {
        let a = self.mod_ast(m);
        if m as u32 >= 64 {
            for i in 0..unsafe (*a).attrs.len() {
                let at = unsafe (*a).attrs.at(i);
                if at.owner == owner && at.kind == kind as u8 {
                    return at;
                }
            }
            return null;
        }
        self.cg_attr_index(m);
        let mut pos = switch self.attr_head.get(&(m as u64 << 32 | owner as u64)) {
            Some(h) => (*h) as i32,
            None => -1,
        };
        while pos >= 0 {
            let at = unsafe (*a).attrs.at(pos as usize);
            if at.kind == kind as u8 {
                return at;
            }
            pos = (switch self.attr_next.get(&(m as u64 << 32 | pos as u64)) {
                Some(h) => (*h) as i32,
                None => -1,
            });
        }
        return null;
    }
    fn cg_symbol_override(self: &Self, m: ModuleId, fn2: NodeId, out: *mut char, cap: usize) bool {
        let mut a = self.cg_attr(m, fn2, AttrKind::ATTR_EXPORT);
        if a == null {
            a = self.cg_attr(m, fn2, AttrKind::ATTR_IMPORT);
        }
        if a == null || cap == 0 {
            return false;
        }
        let sp = unsafe (*a).str_span;
        let mut nn = (sp.end - sp.start) as usize;
        if nn >= cap {
            nn = cap - 1;
        }
        unsafe cstring::memcpy(out, src_at(self.mod_src(m), sp.start), nn);
        unsafe out[nn] = 0 as char;
        return true;
    }
    fn decl_is_toplevel(self: &Self, m: ModuleId, node: NodeId) bool {
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            if unsafe (*a).list(items)[i as usize] == node {
                return true;
            }
        }
        return false;
    }
    fn cg_env_capture(self: &Self, decl: NodeId, is_mut: *mut bool) i32 {
        if self.env_clos == NODE_NONE || decl == NODE_NONE {
            return -1;
        }
        let caps = unsafe (*self.cur_ast()).at_const(self.env_clos).as_data.closure.captures;
        let mut_caps = (unsafe (*self.cur_ast()).at_const(self.env_clos).as_data.closure.mut_caps) as u64;
        let cids = unsafe (*self.cur_ast()).list(caps);
        for i in 0..caps.len {
            if unsafe cids[i as usize] == decl {
                unsafe *is_mut = (mut_caps >> i as u64 & 1 as u64) != 0 as u64;
                return i as i32;
            }
        }
        return -1;
    }
    fn cg_decl_name_span(self: &Self, decl: NodeId) tok::Span {
        let n = unsafe (*self.cur_ast()).at_const(decl);
        if n.kind == NodeKind::NODE_LET {
            return self.name_span(n.as_data.let_stmt.name);
        }
        if n.kind == NodeKind::NODE_PARAMETER {
            return self.name_span(n.as_data.parameter.name);
        }
        return tok::Span { start: 0, end: 0 };
    }
    fn emit_auto_free(self: &mut Self, bid: NodeId) {
        let bt = unsafe (*self.cur_ast()).type_of(bid);
        if !self.cg_type_is_free(bt) {
            return;
        }
        if self.cg_is_cond_moved(bid) {
            let mut fl = Buf32 {};
            cg_move_flag(&mut fl[0], 32, bid);
            self.buf.format_into("if (!{}) ", diag::cstr(&fl[0]));
        }
        self.emit_free_target(bt);
        let ln = *unsafe (*self.cur_ast()).at_const(bid);
        let mut nameNode = ln.as_data.let_stmt.name;
        if ln.kind == NodeKind::NODE_PARAMETER {
            nameNode = ln.as_data.parameter.name;
        } else if ln.kind == NodeKind::NODE_IDENTIFIER {
            nameNode = bid;
        }
        let mut nm = Buf128 {};
        self.render_ident(self.name_span(nameNode), &mut nm[0], 128);
        self.buf.format_into("(&{});\n", diag::cstr(&nm[0]));
    }
    fn emit_expr_stmt(self: &mut Self, v0: NodeId) {
        let mut v = v0;
        let mut n = *unsafe (*self.cur_ast()).at_const(v);
        while n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
            v = n.as_data.unary.operand;
            n = *unsafe (*self.cur_ast()).at_const(v);
        }
        if self.ceval() != null && n.kind == NodeKind::NODE_CALL && self.cg_fold_worthwhile(v) && self.cg_maybe_const(v) && unsafe (*self.ceval()).eval(
            self.cur_module(),
            v,
        ).kind != ce::CONST_NONE {
            self.emit_str(";\n");
            return;
        }
        if n.kind == NodeKind::NODE_BLOCK {
            self.emit_block(v);
            self.emit_str("\n");
            return;
        }
        if n.kind == NodeKind::NODE_IF {
            self.emit_if(v);
            self.emit_str("\n");
            return;
        }
        if n.kind == NodeKind::NODE_MATCH {
            self.emit_match_stmt(v);
            return;
        }
        let vt = unsafe (*self.cur_ast()).type_of(v);
        if vt != TYPE_NONE && !self.no_temp_free && n.kind != NodeKind::NODE_ASSIGNMENT && !self.is_lvalue(v) && self.cg_type_is_free(
            vt,
        ) {
            let mut tmp = Buf32 {};
            self.fresh(&mut tmp[0], 32);
            self.buf.format_into("{{ __auto_type {} = ", diag::cstr(&tmp[0]));
            self.emit_expr(v);
            self.emit_str("; ");
            self.emit_free_target(vt);
            self.buf.format_into("(&{}); }}\n", diag::cstr(&tmp[0]));
            return;
        }
        self.emit_expr(v);
        self.emit_str(";\n");
    }
    fn emit_assignment(self: &mut Self, id: NodeId) {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let lt = unsafe (*self.cur_ast()).type_of(bd.left);
        let mut ltr = TYPE_NONE;
        if lt != TYPE_NONE {
            ltr = self.subst_resolve(lt);
        }
        if bd.op == TokenType::Equal && ltr != TYPE_NONE && self.type_at(ltr).kind == TypeKind::TYPE_ARRAY {
            self.emit_str("memcpy(");
            self.emit_expr(bd.left);
            self.emit_str(", ");
            self.emit_expr(bd.right);
            self.emit_str(", sizeof(");
            self.emit_expr(bd.left);
            self.emit_str("))");
            return;
        }
        // a compound assignment on an operator-overloaded struct lowers to `L = L.op(R)` with L's
        // place evaluated once -- C cannot `+=` structs
        if bd.op != TokenType::Equal && ltr != TYPE_NONE {
            let y = *self.type_at(ltr);
            if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE {
                let mut om = y.module;
                let mut od = y.as_data.decl;
                if y.kind == TypeKind::TYPE_INSTANCE {
                    let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
                    om = it.module;
                    od = it.decl;
                }
                let mm = cg_compound_method(bd.op);
                if mm != null {
                    let m = self.cg_find_method_cstr(om, od, mm);
                    if m.node != NODE_NONE {
                        let rt0 = unsafe (*self.cur_ast()).type_of(bd.right);
                        let mut dr: i32 = 0;
                        if rt0 != TYPE_NONE {
                            dr = self.cg_ref_depth(self.subst_resolve(rt0));
                        }
                        let mut lp = Buf32 {};
                        let mut rr = Buf32 {};
                        self.fresh(&mut lp[0], 32);
                        self.fresh(&mut rr[0], 32);
                        self.buf.format_into("({{ __auto_type {} = &(", diag::cstr(&lp[0]));
                        self.emit_expr(bd.left);
                        self.buf.format_into("); __auto_type {} = ", diag::cstr(&rr[0]));
                        self.emit_expr(bd.right);
                        self.buf.format_into("; *{} = ", diag::cstr(&lp[0]));
                        self.emit_op_method(y, om, od, m);
                        let mut rp = "&".ptr() as *const char;
                        if dr != 0 {
                            rp = ref_derefs(dr);
                        }
                        self.buf.format_into("({}, {}{}); }})", diag::cstr(&lp[0]), diag::cstr(rp), diag::cstr(&rr[0]));
                        return;
                    }
                }
            }
        }
        let mut lhsId = bd.left;
        let mut lhs = *unsafe (*self.cur_ast()).at_const(lhsId);
        while lhs.kind == NodeKind::NODE_UNARY && (lhs.as_data.unary.op == TokenType::Move || lhs.as_data.unary.op == TokenType::Unsafe) {
            lhsId = lhs.as_data.unary.operand;
            lhs = *unsafe (*self.cur_ast()).at_const(lhsId);
        }
        let mut ld = DefId { module: 0, node: NODE_NONE };
        if lhs.kind == NodeKind::NODE_IDENTIFIER {
            ld = unsafe (*self.cur_ast()).resolution_def(lhsId);
        }
        if bd.op == TokenType::Equal && lhs.kind == NodeKind::NODE_IDENTIFIER && self.cg_type_is_free(lt) && ld.node != NODE_NONE && !self.cg_is_moved(
            ld.node,
        ) {
            let mut r = Buf32 {};
            self.fresh(&mut r[0], 32);
            self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&r[0]));
            self.emit_expr(bd.right);
            self.emit_str("; ");
            self.emit_free_target(lt);
            self.emit_str("(&");
            self.emit_expr(bd.left);
            self.emit_str("); (");
            self.emit_expr(bd.left);
            self.buf.format_into(" = {}); }})", diag::cstr(&r[0]));
            return;
        }
        if lhs.kind == NodeKind::NODE_INDEX && unsafe (*self.cur_ast()).at_const(lhs.as_data.index.index).kind != NodeKind::NODE_RANGE {
            let iot = unsafe (*self.cur_ast()).type_of(lhs.as_data.index.object);
            let mut riot = TYPE_NONE;
            if iot != TYPE_NONE {
                riot = self.strip_ref_only(self.subst_resolve(iot));
            }
            let mut ird: i32 = 0;
            if iot != TYPE_NONE {
                ird = self.cg_ref_depth(self.subst_resolve(iot));
            }
            let mut ibk = TypeKind::TYPE_ERROR;
            if riot != TYPE_NONE {
                ibk = self.type_at(riot).kind;
            }
            if riot != TYPE_NONE && (ibk == TypeKind::TYPE_STRUCT || ibk == TypeKind::TYPE_INSTANCE) && !self.cg_slice_elem(
                riot,
                null,
            ) {
                let ibt = *self.type_at(riot);
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                if ibt.kind == TypeKind::TYPE_INSTANCE {
                    let it = *unsafe (*self.cur_ast()).instance(ibt.as_data.inst);
                    om = it.module;
                    od = it.decl;
                } else {
                    om = ibt.module;
                    od = ibt.as_data.decl;
                }
                let mth = self.cg_find_method_cstr(om, od, "index_mut".ptr() as *const char);
                if mth.node != NODE_NONE {
                    let mut refp = "&".ptr() as *const char;
                    if ird != 0 {
                        refp = ref_derefs(ird);
                    }
                    if bd.op == TokenType::Equal && lt != TYPE_NONE && self.cg_type_is_free(lt) {
                        let mut r = Buf32 {};
                        let mut p = Buf32 {};
                        self.fresh(&mut r[0], 32);
                        self.fresh(&mut p[0], 32);
                        self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&r[0]));
                        self.emit_expr(bd.right);
                        self.buf.format_into("; __auto_type {} = ", diag::cstr(&p[0]));
                        self.emit_op_method(ibt, om, od, mth);
                        self.emit_str("(");
                        self.emit_prefixed(lhs.as_data.index.object, refp);
                        self.emit_str(", ");
                        self.emit_expr(lhs.as_data.index.index);
                        self.emit_str("); ");
                        self.emit_free_target(lt);
                        self.buf.format_into(
                            "({}); (*{} = {}); }})",
                            diag::cstr(&p[0]),
                            diag::cstr(&p[0]),
                            diag::cstr(&r[0]),
                        );
                    } else {
                        self.emit_str("(*");
                        self.emit_op_method(ibt, om, od, mth);
                        self.emit_str("(");
                        self.emit_prefixed(lhs.as_data.index.object, refp);
                        self.emit_str(", ");
                        self.emit_expr(lhs.as_data.index.index);
                        self.buf.format_into(") {} ", diag::cstr(c_op(bd.op)));
                        self.emit_expr(bd.right);
                        self.emit_str(")");
                    }
                    return;
                }
            }
        }
        self.emit_str("(");
        self.emit_place(bd.left, true);
        self.buf.format_into(" {} ", diag::cstr(c_op(bd.op)));
        self.emit_expr(bd.right);
        self.emit_str(")");
    }
    fn emit_free_target(self: &mut Self, bt: TypeId) bool {
        let y = *self.type_at(self.subst_resolve(bt));
        if y.kind == TypeKind::TYPE_FUNCTION {
            if !self.cg_fn_owns(&y) {
                return false;
            }
            let mut sym = Buf256 {};
            self.closure_sym_in(y.module, y.as_data.decl, &mut sym[0], 220);
            self.buf.format_into("{}_env_free", diag::cstr(&sym[0]));
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN {
            if y.qualifier != TypeQualifier::TYPE_QUAL_NONE as u8 {
                return false;
            }
            let mut stem = Buf256 {};
            self.dyn_stem_dy(&y, &mut stem[0], 176);
            self.buf.format_into("{}__dyn_free", diag::cstr(&stem[0]));
            return true;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let ii = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            om = ii.module;
            od = ii.decl;
        } else if y.kind == TypeKind::TYPE_STRUCT {
            om = y.module;
            od = y.as_data.decl;
        } else {
            return false;
        }
        let dm = self.cg_free_method(om, od);
        if dm.node == NODE_NONE {
            return false;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(y.as_data.inst), &mut inm[0], 200);
            self.emit_cstr(&inm[0]);
            self.emit_paste();
            self.emit_str("__");
        } else {
            let mut pfx = Buf64 {};
            self.render_modpfx(dm.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_ident_mod(om, unsafe (*self.mod_ast(om)).at_const(od).as_data.aggregate.name);
            self.emit_str("__");
        }
        self.emit_ident_mod(dm.module, unsafe (*self.mod_ast(dm.module)).at_const(dm.node).as_data.function.name);
        return true;
    }
    fn pat_trivial(self: &Self, pid: NodeId) bool {
        let p = unsafe (*self.cur_ast()).at_const(pid);
        if p.kind == NodeKind::NODE_PATTERN_NAME {
            return p.as_data.pattern.children.len == 0;
        }
        return p.kind == NodeKind::NODE_PATTERN_WILDCARD || p.kind == NodeKind::NODE_IDENTIFIER;
    }
    // The overloaded-comparison home of a literal pattern's value: its recorded type when the
    // typechecker left one, else string literals map to the prelude `str` struct (pattern values are
    // not expression-checked, so they usually carry no type). false = not an overload candidate.
    fn cg_pattern_overload_target(self: &mut Self, val: NodeId, bt: *mut Ty, om: *mut ModuleId, od: *mut NodeId) bool {
        let vt0 = unsafe (*self.cur_ast()).type_of(val);
        if vt0 != TYPE_NONE {
            let vt = self.strip_ref_only(self.subst_resolve(vt0));
            if vt == TYPE_NONE {
                return false;
            }
            let y = *self.type_at(vt);
            if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
                return false;
            }
            unsafe *bt = y;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
                unsafe *om = it.module;
                unsafe *od = it.decl;
            } else {
                unsafe *om = y.module;
                unsafe *od = y.as_data.decl;
            }
            return true;
        }
        let vn = unsafe (*self.cur_ast()).at_const(val);
        if vn.kind != NodeKind::NODE_LITERAL || self.package == null {
            return false;
        }
        let tt = vn.as_data.literal.token_type;
        if tt != TokenType::StringLiteral && tt != TokenType::RawStringLiteral {
            return false;
        }
        let h = unsafe (*self.package).prelude_lookup("str", true);
        if h.node == NODE_NONE {
            return false;
        }
        unsafe *om = h.mid;
        unsafe *od = h.node;
        unsafe *bt = Ty { kind: TypeKind::TYPE_STRUCT, module: h.mid, as_data: TyAs { decl: h.node } };
        return true;
    }

    // A struct-typed literal pattern (a string pattern in a `switch` over `str`) compares through the
    // type's `eq` overload -- C cannot `==` structs. Mirrors emit_cmp_overload's lowering; false = no
    // overload applies (scalar patterns keep the plain `==`).
    fn emit_pattern_eq_overload(self: &mut Self, pid: NodeId, scrut: *const char) bool {
        let val = unsafe (*self.cur_ast()).at_const(pid).as_data.single.value;
        let mut bt = Ty { kind: TypeKind::TYPE_ERROR };
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if !self.cg_pattern_overload_target(val, &mut bt, &mut om, &mut od) {
            return false;
        }
        let m = self.cg_find_method_cstr(om, od, "eq".ptr() as *const char);
        if m.node == NODE_NONE {
            return false;
        }
        let mut lb = Buf32 {};
        let mut rb = Buf32 {};
        self.fresh(&mut lb[0], 32);
        self.fresh(&mut rb[0], 32);
        self.buf.format_into(
            "(({{ __auto_type {} = {}; __auto_type {} = ",
            diag::cstr(&lb[0]),
            diag::cstr(scrut),
            diag::cstr(&rb[0]),
        );
        self.emit_expr(val);
        self.emit_str("; ");
        self.emit_op_method(bt, om, od, m);
        self.buf.format_into("(&{}, &{}); }}))", diag::cstr(&lb[0]), diag::cstr(&rb[0]));
        return true;
    }

    // A range pattern over an overloaded type (string ranges) tests through `cmp`; `rel` is the C
    // relation the bound uses (">=", "<", "<="). false = scalar range, keep the plain operators.
    fn emit_pattern_cmp_overload(self: &mut Self, bound: NodeId, scrut: *const char, rel: *const char) bool {
        let mut bt = Ty { kind: TypeKind::TYPE_ERROR };
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if !self.cg_pattern_overload_target(bound, &mut bt, &mut om, &mut od) {
            return false;
        }
        let m = self.cg_find_method_cstr(om, od, "cmp".ptr() as *const char);
        if m.node == NODE_NONE {
            return false;
        }
        let mut lb = Buf32 {};
        let mut rb = Buf32 {};
        self.fresh(&mut lb[0], 32);
        self.fresh(&mut rb[0], 32);
        self.buf.format_into(
            "(({{ __auto_type {} = {}; __auto_type {} = ",
            diag::cstr(&lb[0]),
            diag::cstr(scrut),
            diag::cstr(&rb[0]),
        );
        self.emit_expr(bound);
        self.emit_str("; ");
        self.emit_op_method(bt, om, od, m);
        self.buf.format_into("(&{}, &{}) {} 0; }}))", diag::cstr(&lb[0]), diag::cstr(&rb[0]), diag::cstr(rel));
        return true;
    }

    fn emit_pattern_test(self: &mut Self, pid: NodeId, scrut: *const char) {
        let p = *unsafe (*self.cur_ast()).at_const(pid);
        let pk = p.kind;
        if pk == NodeKind::NODE_PATTERN_NAME {
            let vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                let en = self.enclosing_enum_in(vd.module, vd.node);
                let payload = en != NODE_NONE && self.aggregate_has_payload_in(vd.module, en);
                if payload {
                    self.buf.format_into("{}.tag == ", diag::cstr(scrut));
                } else {
                    self.buf.format_into("{} == ", diag::cstr(scrut));
                }
                if en != NODE_NONE {
                    self.emit_tag_mod(vd.module, en, vd.node);
                } else {
                    self.emit_str("0");
                }
            } else if p.as_data.pattern.children.len != 0 {
                self.emit_pattern_test(unsafe (*self.cur_ast()).list(p.as_data.pattern.children)[0], scrut);
            } else {
                self.emit_str("1");
            }
        } else if pk == NodeKind::NODE_PATTERN_WILDCARD || pk == NodeKind::NODE_IDENTIFIER {
            self.emit_str("1");
        } else if pk == NodeKind::NODE_PATTERN_LITERAL {
            if !self.emit_pattern_eq_overload(pid, scrut) {
                self.buf.format_into("{} == ", diag::cstr(scrut));
                self.emit_expr(p.as_data.single.value);
            }
        } else if pk == NodeKind::NODE_PATTERN_RANGE {
            let lo = p.as_data.pattern_range.start;
            let hi = p.as_data.pattern_range.end;
            if lo != NODE_NONE {
                let lon = unsafe (*self.cur_ast()).at_const(lo);
                let lov = if_node(lon.kind == NodeKind::NODE_PATTERN_LITERAL, lon.as_data.single.value, lo);
                if !self.emit_pattern_cmp_overload(lov, scrut, ">=".ptr() as *const char) {
                    self.buf.format_into("{} >= ", diag::cstr(scrut));
                    self.emit_expr(lov);
                }
            }
            if hi != NODE_NONE {
                let hin = unsafe (*self.cur_ast()).at_const(hi);
                let mut andp = "".ptr() as *const char;
                if lo != NODE_NONE {
                    andp = " && ".ptr() as *const char;
                }
                let mut cmp = "<".ptr() as *const char;
                if p.as_data.pattern_range.inclusive {
                    cmp = "<=".ptr() as *const char;
                }
                let hiv = if_node(hin.kind == NodeKind::NODE_PATTERN_LITERAL, hin.as_data.single.value, hi);
                self.buf.format_into("{}", diag::cstr(andp));
                if !self.emit_pattern_cmp_overload(hiv, scrut, cmp) {
                    self.buf.format_into("{} {} ", diag::cstr(scrut), diag::cstr(cmp));
                    self.emit_expr(hiv);
                }
            }
        } else if pk == NodeKind::NODE_PATTERN_TUPLE {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE {
                vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            }
            let ch = p.as_data.pattern.children;
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                let en = self.enclosing_enum_in(vd.module, vd.node);
                let payload = en != NODE_NONE && self.aggregate_has_payload_in(vd.module, en);
                if payload {
                    self.buf.format_into("{}.tag == ", diag::cstr(scrut));
                } else {
                    self.buf.format_into("{} == ", diag::cstr(scrut));
                }
                if en != NODE_NONE {
                    self.emit_tag_mod(vd.module, en, vd.node);
                } else {
                    self.emit_str("0");
                }
                let mut vn = Buf128 {};
                self.render_variant_name(vd.module, vd.node, &mut vn[0], 128);
                for i in 0..ch.len {
                    let cid = unsafe (*self.cur_ast()).list(ch)[i as usize];
                    if !self.pat_trivial(cid) {
                        let mut sub = Buf256 {};
                        unsafe stdio::snprintf(
                            &mut sub[0],
                            256,
                            "%s.payload.%s._%u".ptr() as *const char,
                            scrut,
                            &vn[0],
                            i,
                        );
                        self.emit_str(" && ");
                        self.emit_pattern_test(cid, &sub[0]);
                    }
                }
            } else if ch.len == 1 {
                self.emit_pattern_test(unsafe (*self.cur_ast()).list(ch)[0], scrut);
            } else {
                self.emit_str("1");
            }
        } else if pk == NodeKind::NODE_PATTERN_STRUCT {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE {
                vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            }
            let is_variant = vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT;
            let ch = p.as_data.pattern.children;
            let mut prefix = Buf512 {};
            let mut wrote = false;
            if is_variant {
                let en = self.enclosing_enum_in(vd.module, vd.node);
                let payload = en != NODE_NONE && self.aggregate_has_payload_in(vd.module, en);
                if payload {
                    self.buf.format_into("{}.tag == ", diag::cstr(scrut));
                } else {
                    self.buf.format_into("{} == ", diag::cstr(scrut));
                }
                if en != NODE_NONE {
                    self.emit_tag_mod(vd.module, en, vd.node);
                } else {
                    self.emit_str("0");
                }
                wrote = true;
                let mut vn = Buf128 {};
                self.render_variant_name(vd.module, vd.node, &mut vn[0], 128);
                unsafe stdio::snprintf(&mut prefix[0], 300, "%s.payload.%s".ptr() as *const char, scrut, &vn[0]);
            } else {
                unsafe stdio::snprintf(&mut prefix[0], 300, "%s".ptr() as *const char, scrut);
            }
            for i in 0..ch.len {
                let fid = unsafe (*self.cur_ast()).list(ch)[i as usize];
                let f = unsafe (*self.cur_ast()).at_const(fid);
                let sub = f.as_data.pattern.children;
                let mut subpat = NODE_NONE;
                if sub.len != 0 {
                    subpat = unsafe (*self.cur_ast()).list(sub)[0];
                }
                if subpat != NODE_NONE && !self.pat_trivial(subpat) {
                    let mut m = Buf128 {};
                    self.render_ident(self.name_span(f.as_data.pattern.name), &mut m[0], 128);
                    let mut acc = Buf512 {};
                    unsafe stdio::snprintf(&mut acc[0], 440, "%s.%s".ptr() as *const char, &prefix[0], &m[0]);
                    if wrote {
                        self.emit_str(" && ");
                    }
                    self.emit_pattern_test(subpat, &acc[0]);
                    wrote = true;
                }
            }
            if !wrote {
                self.emit_str("1");
            }
        } else if pk == NodeKind::NODE_PATTERN_OR {
            let alts = p.as_data.pattern.children;
            if alts.len == 0 {
                self.emit_str("1");
                return;
            }
            for i in 0..alts.len {
                if i != 0 {
                    self.emit_str(" || (");
                } else {
                    self.emit_str("(");
                }
                self.emit_pattern_test(unsafe (*self.cur_ast()).list(alts)[i as usize], scrut);
                self.emit_str(")");
            }
        } else {
            self.emit_str("1");
        }
    }
    fn emit_bind(self: &mut Self, pid: NodeId, name: tok::Span, is_mut: bool, scrut: *const char, by_ref: bool) {
        self.emit_indent();
        if by_ref {
            let mut nm = Buf128 {};
            self.render_ident(name, &mut nm[0], 128);
            let mut cq = "const ".ptr() as *const char;
            if is_mut {
                cq = "".ptr() as *const char;
            }
            self.buf.format_into("{}__auto_type {} = &({});\n", diag::cstr(cq), diag::cstr(&nm[0]), diag::cstr(scrut));
        } else {
            let pt = unsafe (*self.cur_ast()).type_of(pid);
            self.emit_binding(pt, name, !is_mut && !self.cg_type_is_free(pt));
            self.buf.format_into(" = {};\n", diag::cstr(scrut));
        }
    }
    fn emit_pattern_binds(self: &mut Self, pid: NodeId, scrut: *const char, by_ref: bool) {
        let p = *unsafe (*self.cur_ast()).at_const(pid);
        let pk = p.kind;
        if pk == NodeKind::NODE_PATTERN_NAME {
            let vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                return;
            }
            let is_mut = unsafe (*self.cur_ast()).at_const(p.as_data.pattern.name).as_data.name.is_mutable;
            self.emit_bind(pid, self.name_span(p.as_data.pattern.name), is_mut, scrut, by_ref);
            if p.as_data.pattern.children.len != 0 {
                self.emit_pattern_binds(unsafe (*self.cur_ast()).list(p.as_data.pattern.children)[0], scrut, by_ref);
            }
        } else if pk == NodeKind::NODE_IDENTIFIER {
            self.emit_bind(pid, p.as_data.name.text, p.as_data.name.is_mutable, scrut, by_ref);
        } else if pk == NodeKind::NODE_PATTERN_TUPLE {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE {
                vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            }
            let ch = p.as_data.pattern.children;
            let mut vn = Buf128 {};
            vn[0] = 0 as char;
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                self.render_variant_name(vd.module, vd.node, &mut vn[0], 128);
            }
            for i in 0..ch.len {
                let mut sub = Buf256 {};
                if vn[0] != 0 as char {
                    unsafe stdio::snprintf(&mut sub[0], 256, "%s.payload.%s._%u".ptr() as *const char, scrut, &vn[0], i);
                } else {
                    unsafe stdio::snprintf(&mut sub[0], 256, "%s".ptr() as *const char, scrut);
                }
                self.emit_pattern_binds(unsafe (*self.cur_ast()).list(ch)[i as usize], &sub[0], by_ref);
            }
        } else if pk == NodeKind::NODE_PATTERN_STRUCT {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE {
                vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            }
            let mut prefix = Buf512 {};
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                let mut vn = Buf128 {};
                self.render_variant_name(vd.module, vd.node, &mut vn[0], 128);
                unsafe stdio::snprintf(&mut prefix[0], 300, "%s.payload.%s".ptr() as *const char, scrut, &vn[0]);
            } else {
                unsafe stdio::snprintf(&mut prefix[0], 300, "%s".ptr() as *const char, scrut);
            }
            let ch = p.as_data.pattern.children;
            for i in 0..ch.len {
                let fid = unsafe (*self.cur_ast()).list(ch)[i as usize];
                let f = unsafe (*self.cur_ast()).at_const(fid);
                let mut m = Buf128 {};
                self.render_ident(self.name_span(f.as_data.pattern.name), &mut m[0], 128);
                let mut acc = Buf512 {};
                unsafe stdio::snprintf(&mut acc[0], 440, "%s.%s".ptr() as *const char, &prefix[0], &m[0]);
                let sub = f.as_data.pattern.children;
                if sub.len != 0 {
                    self.emit_pattern_binds(unsafe (*self.cur_ast()).list(sub)[0], &acc[0], by_ref);
                }
            }
        } else if pk == NodeKind::NODE_PATTERN_OR {
            let alts = p.as_data.pattern.children;
            if alts.len != 0 {
                self.emit_pattern_binds(unsafe (*self.cur_ast()).list(alts)[0], scrut, by_ref);
            }
        }
    }
    fn emit_index(self: &mut Self, id: NodeId, want_mut: bool) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let obj = n.as_data.index.object;
        let idxNode = n.as_data.index.index;
        let idxn = *unsafe (*self.cur_ast()).at_const(idxNode);
        if idxn.kind == NodeKind::NODE_RANGE {
            let lo = idxn.as_data.pattern_range.start;
            let hi = idxn.as_data.pattern_range.end;
            let incl = idxn.as_data.pattern_range.inclusive;
            let oty0 = unsafe (*self.cur_ast()).type_of(obj);
            let mut roty = TYPE_NONE;
            if oty0 != TYPE_NONE {
                roty = self.strip_ref_only(self.subst_resolve(oty0));
            }
            let mut refd: i32 = 0;
            if oty0 != TYPE_NONE {
                refd = self.cg_ref_depth(self.subst_resolve(oty0));
            }
            if self.package != null && !self.cg_slice_elem(roty, null) {
                let mut btk = TypeKind::TYPE_ERROR;
                if roty != TYPE_NONE {
                    btk = self.type_at(roty).kind;
                }
                if roty != TYPE_NONE && (btk == TypeKind::TYPE_STRUCT || btk == TypeKind::TYPE_INSTANCE) {
                    let bt = *self.type_at(roty);
                    let mut om: ModuleId = 0;
                    let mut od = NODE_NONE;
                    if bt.kind == TypeKind::TYPE_INSTANCE {
                        let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
                        om = it.module;
                        od = it.decl;
                    } else {
                        om = bt.module;
                        od = bt.as_data.decl;
                    }
                    let mth = self.cg_find_method_cstr(om, od, "index_range".ptr() as *const char);
                    if mth.node != NODE_NONE {
                        self.cg_prelude_hits();
                        let usz = Ast::builtin(BuiltinType::BT_USIZE);
                        let rangeTy = unsafe (*self.cur_ast()).intern_instance(
                            self.ph_range.mid,
                            self.ph_range.node,
                            &usz,
                            1,
                        );
                        let mut rn = Buf256 {};
                        self.render_type_id(rangeTy, "".ptr() as *const char, &mut rn[0], 200);
                        let mut o = Buf32 {};
                        self.fresh(&mut o[0], 32);
                        if refd > 0 {
                            self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&o[0]));
                            self.emit_prefixed(obj, ref_derefs(refd));
                        } else if self.is_lvalue(obj) {
                            self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&o[0]));
                            self.emit_prefixed(obj, "&".ptr() as *const char);
                        } else {
                            let mut v = Buf32 {};
                            self.fresh(&mut v[0], 32);
                            self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&v[0]));
                            self.emit_expr(obj);
                            self.buf.format_into("; __auto_type {} = &{}", diag::cstr(&o[0]), diag::cstr(&v[0]));
                        }
                        self.emit_str("; ");
                        self.emit_op_method(bt, om, od, mth);
                        self.buf.format_into("({}, ({}){{ .start = ", diag::cstr(&o[0]), diag::cstr(&rn[0]));
                        if lo != NODE_NONE {
                            self.emit_expr(lo);
                        } else {
                            self.emit_str("0");
                        }
                        self.emit_str(", .end = ");
                        if hi != NODE_NONE {
                            self.emit_expr(hi);
                        } else {
                            let lm = self.cg_find_method_cstr(om, od, "len".ptr() as *const char);
                            if lm.node != NODE_NONE {
                                self.emit_op_method(bt, om, od, lm);
                                self.buf.format_into("({})", diag::cstr(&o[0]));
                            } else {
                                self.emit_str("0");
                            }
                        }
                        let mut incls = "false".ptr() as *const char;
                        if incl {
                            incls = "true".ptr() as *const char;
                        }
                        self.buf.format_into(", .inclusive = {} }}); }})", diag::cstr(incls));
                        return;
                    }
                }
            }
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(id), "".ptr() as *const char, &mut styp[0], 200);
            let isslice = self.cg_slice_elem(roty, null);
            let mut arrlen = NODE_NONE;
            if !isslice {
                arrlen = self.array_length_of(obj);
            }
            let mut b = Buf32 {};
            self.fresh(&mut b[0], 32);
            self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&b[0]));
            if refd > 0 {
                self.emit_prefixed(obj, ref_derefs(refd + 1));
            } else {
                self.emit_expr(obj);
            }
            let mut sfx = "".ptr() as *const char;
            if isslice {
                sfx = ".ptr".ptr() as *const char;
            }
            self.buf.format_into("; ({}){{ .ptr = {}{} + ", diag::cstr(&styp[0]), diag::cstr(&b[0]), diag::cstr(sfx));
            if lo != NODE_NONE {
                self.emit_str("(");
                self.emit_expr(lo);
                self.emit_str(")");
            } else {
                self.emit_str("0");
            }
            self.emit_str(", .len = ");
            if hi != NODE_NONE {
                self.emit_str("(");
                self.emit_expr(hi);
                if incl {
                    self.emit_str(") + 1");
                } else {
                    self.emit_str(")");
                }
            } else if isslice {
                self.buf.format_into("{}.len", diag::cstr(&b[0]));
            } else if arrlen != NODE_NONE {
                self.emit_expr(arrlen);
            } else {
                let cnt = self.array_literal_count(obj);
                if cnt >= 0 {
                    self.buf.format_into("{}", cnt);
                } else {
                    self.emit_str("0");
                }
            }
            self.emit_str(" - ");
            if lo != NODE_NONE {
                self.emit_str("(");
                self.emit_expr(lo);
                self.emit_str(")");
            } else {
                self.emit_str("0");
            }
            self.emit_str(" }; })");
            return;
        }
        // index overload: obj[i] on struct/instance -> index method
        let ot = unsafe (*self.cur_ast()).type_of(obj);
        let mut rot = TYPE_NONE;
        if ot != TYPE_NONE {
            rot = self.strip_ref_only(self.subst_resolve(ot));
        }
        let mut rd: i32 = 0;
        if ot != TYPE_NONE {
            rd = self.cg_ref_depth(self.subst_resolve(ot));
        }
        let mut btk = TypeKind::TYPE_ERROR;
        if rot != TYPE_NONE {
            btk = self.type_at(rot).kind;
        }
        if rot != TYPE_NONE && (btk == TypeKind::TYPE_STRUCT || btk == TypeKind::TYPE_INSTANCE) && !self.cg_slice_elem(
            rot,
            null,
        ) {
            let bt = *self.type_at(rot);
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            if bt.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
                om = it.module;
                od = it.decl;
            } else {
                om = bt.module;
                od = bt.as_data.decl;
            }
            // A `&mut self` method receiver (or address-of-mut) wants the mutable place, so select
            // `index_mut` -- `&(*index_mut(v,i))` folds to `index_mut(v,i)` (a mutable element pointer),
            // avoiding the const `index` that would mutate through a `const T*`. Falls back to `index`.
            let mut mname = "index".ptr() as *const char;
            if want_mut {
                mname = "index_mut".ptr() as *const char;
            }
            let mut mth = self.cg_find_method_cstr(om, od, mname);
            if mth.node == NODE_NONE && want_mut {
                mth = self.cg_find_method_cstr(om, od, "index".ptr() as *const char);
            }
            if mth.node != NODE_NONE {
                let mam = self.mod_ast(mth.module);
                let mrets = unsafe (*mam).at_const(mth.node).as_data.function.returns;
                let mut retref = false;
                if mrets.len == 1 {
                    let mr0 = unsafe (*mam).list(mrets)[0];
                    let mrn = unsafe (*mam).at_const(mr0);
                    let mtn = if_node(mrn.kind == NodeKind::NODE_PARAMETER, mrn.as_data.parameter.ty, mr0);
                    retref = mtn != NODE_NONE && unsafe (*mam).at_const(mtn).kind == NodeKind::NODE_REFERENCE_TYPE;
                }
                let mut o = Buf32 {};
                self.fresh(&mut o[0], 32);
                if retref {
                    self.emit_str("(*");
                }
                if rd > 0 {
                    self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&o[0]));
                    self.emit_prefixed(obj, ref_derefs(rd));
                } else if self.is_lvalue(obj) {
                    self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&o[0]));
                    self.emit_prefixed(obj, "&".ptr() as *const char);
                } else {
                    let mut v = Buf32 {};
                    self.fresh(&mut v[0], 32);
                    self.buf.format_into("({{ __auto_type {} = ", diag::cstr(&v[0]));
                    self.emit_expr(obj);
                    self.buf.format_into("; __auto_type {} = &{}", diag::cstr(&o[0]), diag::cstr(&v[0]));
                }
                self.emit_str("; ");
                self.emit_op_method(bt, om, od, mth);
                self.buf.format_into("({}, ", diag::cstr(&o[0]));
                self.emit_expr(idxNode);
                if retref {
                    self.emit_str("); }))");
                } else {
                    self.emit_str("); })");
                }
                return;
            }
        }
        // plain / bounds-checked indexing
        let bty = unsafe (*self.cur_ast()).type_of(obj);
        let mut rbty = TYPE_NONE;
        if bty != TYPE_NONE {
            rbty = self.strip_ref_only(self.subst_resolve(bty));
        }
        let mut rd2: i32 = 0;
        if bty != TYPE_NONE {
            rd2 = self.cg_ref_depth(self.subst_resolve(bty));
        }
        if self.cg_slice_elem(rbty, null) {
            if self.cg_pure_place(obj) {
                self.emit_slice_base(obj, rd2);
                self.emit_str(".ptr[__sc_bounds(");
                self.emit_expr(idxNode);
                self.emit_str(", ");
                self.emit_slice_base(obj, rd2);
                self.emit_str(".len)]");
                return;
            }
            // Effectful base: evaluate the slice ONCE into a temp; `*(&elem)` keeps the
            // whole expression an lvalue so `xs[i] = v` still works.
            let mut sb = Buf32 {};
            self.fresh(&mut sb[0], 32);
            self.buf.format_into("(*({{ __auto_type {} = ", diag::cstr(&sb[0]));
            self.emit_slice_base(obj, rd2);
            self.buf.format_into("; &{}.ptr[__sc_bounds(", diag::cstr(&sb[0]));
            self.emit_expr(idxNode);
            self.buf.format_into(", {}.len)]; }}))", diag::cstr(&sb[0]));
            return;
        }
        let oty = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(obj)));
        let mut lenN = NODE_NONE;
        if oty.kind == TypeKind::TYPE_ARRAY {
            lenN = self.array_length_of(obj);
        }
        let mut licnt: i64 = -1;
        if oty.kind == TypeKind::TYPE_ARRAY && lenN == NODE_NONE {
            licnt = self.array_literal_count(obj);
        }
        if lenN != NODE_NONE || licnt >= 0 {
            let mut iv: i64 = 0;
            let mut nv: i64 = licnt;
            let mut nconst = licnt >= 0;
            if lenN != NODE_NONE {
                nconst = self.cg_int_lit(lenN, &mut nv);
            }
            if self.cg_int_lit(idxNode, &mut iv) && nconst {
                if iv < 0 || iv >= nv {
                    let sp = unsafe (*self.cur_ast()).at_const(idxNode).span;
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format("index {} is out of bounds for an array of length {}", iv, nv),
                    );
                }
                self.emit_expr(obj);
                self.emit_str("[");
                self.emit_expr(idxNode);
                self.emit_str("]");
                return;
            }
            self.emit_expr(obj);
            self.emit_str("[__sc_bounds(");
            self.emit_expr(idxNode);
            self.emit_str(", ");
            if lenN != NODE_NONE {
                self.emit_expr(lenN);
            } else {
                self.buf.format_into("{}", licnt);
            }
            self.emit_str(")]");
            return;
        }
        self.emit_expr(obj);
        self.emit_str("[");
        self.emit_expr(idxNode);
        self.emit_str("]");
    }
    // Emit a place expression, selecting `index_mut` for a scalar `v[i]` index base when the place is used
    // mutably (assignment LHS, `&mut`, `&mut self` method receiver). With `want_mut == false` this is exactly
    // `emit_expr` (member->emit_member(false)==emit_expr, index->emit_index(false)==emit_expr).
    fn emit_place(self: &mut Self, id: NodeId, want_mut: bool) {
        let k = unsafe (*self.cur_ast()).at_const(id).kind;
        if k == NodeKind::NODE_MEMBER {
            self.emit_member(id, want_mut);
        } else if want_mut && k == NodeKind::NODE_INDEX && unsafe (*self.cur_ast()).at_const(
            unsafe (*self.cur_ast()).at_const(id).as_data.index.index,
        ).kind != NodeKind::NODE_RANGE {
            self.emit_index(id, true);
        } else {
            self.emit_expr(id);
        }
    }

    fn emit_member(self: &mut Self, id: NodeId, want_mut: bool) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        if n.as_data.member.path {
            let mut d = unsafe (*self.cur_ast()).resolution_def(id);
            if d.node == NODE_NONE {
                d = unsafe (*self.cur_ast()).resolution_def(n.as_data.member.member);
            }
            let mut dk = NodeKind::NODE_NONE_KIND;
            if d.node != NODE_NONE {
                dk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
            }
            if d.node != NODE_NONE && dk == NodeKind::NODE_CONST && unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.is_extern {
                let mut ov = Buf256 {};
                if self.cg_symbol_override(d.module, d.node, &mut ov[0], 160) {
                    self.emit_cstr(&ov[0]);
                } else {
                    self.emit_ident_mod(
                        d.module,
                        unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.name,
                    );
                }
            } else if d.node != NODE_NONE && dk == NodeKind::NODE_CONST && self.decl_is_toplevel(d.module, d.node) {
                let mut nm = Buf256 {};
                self.render_qualified(
                    d.module,
                    unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.name,
                    &mut nm[0],
                    160,
                );
                self.emit_cstr(&nm[0]);
            } else if d.node != NODE_NONE && dk == NodeKind::NODE_FUNCTION {
                let mut nm = Buf256 {};
                self.render_qualified(
                    d.module,
                    unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.name,
                    &mut nm[0],
                    160,
                );
                self.emit_cstr(&nm[0]);
            } else if d.node != NODE_NONE && dk == NodeKind::NODE_CONST {
                // associated const Type::NAME -> `<mod>__<Type>__NAME`
                let da = self.mod_ast(d.module);
                let ditems = unsafe (*da).at_const((*da).root).as_data.program.items;
                let mut target = DefId { module: 0, node: NODE_NONE };
                let mut di: u32 = 0;
                while di < ditems.len && target.node == NODE_NONE {
                    let did = unsafe (*da).list(ditems)[di as usize];
                    let de = unsafe (*da).at_const(did);
                    if de.kind == NodeKind::NODE_EXTEND {
                        let dmis = de.as_data.extend_def.items;
                        for dj in 0..dmis.len {
                            if unsafe (*da).list(dmis)[dj as usize] == d.node {
                                target = unsafe (*da).resolution_def(de.as_data.extend_def.target_type);
                            }
                        }
                    }
                    di = di + 1;
                }
                let mut nm = Buf512 {};
                let mut k = self.render_modpfx(d.module, &mut nm[0], 256);
                let mut bb: i32 = -1;
                if self.package != null && target.node != NODE_NONE {
                    bb = unsafe (*self.package).builtin_of_decl(target.module, target.node);
                }
                if bb >= 0 {
                    k = bappend(&mut nm[0], 256, k, builtin_name(bb as BuiltinType));
                } else if target.node != NODE_NONE {
                    k = k + render_ident_src(
                        self.mod_src(target.module),
                        self.name_span_in(
                            target.module,
                            unsafe (*self.mod_ast(target.module)).at_const(target.node).as_data.aggregate.name,
                        ),
                        unsafe ((&mut nm[0]) as *mut char + k),
                        256 - k,
                    );
                }
                k = bappend(&mut nm[0], 256, k, "__".ptr() as *const char);
                render_ident_src(
                    self.mod_src(d.module),
                    unsafe (*da).at_const(unsafe (*da).at_const(d.node).as_data.const_def.name).as_data.name.text,
                    unsafe ((&mut nm[0]) as *mut char + k),
                    256 - k,
                );
                self.emit_cstr(&nm[0]);
            } else {
                self.emit_variant_value(d, unsafe (*self.cur_ast()).type_of(id));
            }
            return;
        }
        let ot = *self.type_at(unsafe (*self.cur_ast()).type_of(n.as_data.member.object));
        let ptr = ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE;
        self.emit_place(n.as_data.member.object, want_mut);
        if ptr {
            self.emit_str("->");
        } else {
            self.emit_str(".");
        }
        let msp = self.name_span(n.as_data.member.member);
        if self.source[msp.start as usize] >= b'0' && self.source[msp.start as usize] <= b'9' {
            self.emit_str("_");
        }
        self.emit_ident(msp);
    }
    fn emit_sizeof(self: &mut Self, id: NodeId) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let vnode = n.as_data.single.value;
        let d = unsafe (*self.cur_ast()).resolution_def(vnode);
        let mut dk = NodeKind::NODE_NONE_KIND;
        if d.node != NODE_NONE {
            dk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
        }
        let mut ty = Buf256 {};
        if d.node != NODE_NONE && (dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_FOR || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_PATTERN_NAME || dk == NodeKind::NODE_CONST) {
            if n.kind == NodeKind::NODE_ALIGNOF {
                let mut vt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(vnode));
                let mut y = self.type_at(vt);
                while y.kind == TypeKind::TYPE_ARRAY {
                    vt = y.as_data.arr.elem;
                    y = self.type_at(vt);
                }
                self.render_type_id(vt, "".ptr() as *const char, &mut ty[0], 256);
            } else if dk == NodeKind::NODE_CONST && (!self.mangle || self.decl_is_toplevel(d.module, d.node)) {
                self.render_qualified(
                    d.module,
                    unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.name,
                    &mut ty[0],
                    256,
                );
            } else {
                self.render_ident(self.cg_decl_name_span(d.node), &mut ty[0], 256);
            }
        } else {
            self.render_type_node(vnode, "".ptr() as *const char, &mut ty[0], 256);
        }
        if n.kind == NodeKind::NODE_ALIGNOF {
            self.buf.format_into("_Alignof({})", diag::cstr(&ty[0]));
        } else {
            self.buf.format_into("sizeof({})", diag::cstr(&ty[0]));
        }
    }
    fn emit_loop_expr(self: &mut Self, id: NodeId) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let saved_ldb = self.loop_defer_base;
        self.loop_defer_base = self.defer_top;
        let le = self.cg_loop_push(id, true);
        let ty = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
        let mut has_val = false;
        if ty != TYPE_NONE {
            let yk = self.type_at(ty).kind;
            has_val = yk != TypeKind::TYPE_NEVER && !(yk == TypeKind::TYPE_BUILTIN && self.type_at(ty).as_data.builtin == BuiltinType::BT_VOID);
        }
        self.emit_str("({ ");
        if has_val && le >= 0 {
            let mut vn = Buf32 {};
            unsafe stdio::snprintf(&mut vn[0], 32, "__lv%u".ptr() as *const char, self.loop_stack[le as usize].seq);
            let mut decl = Buf256 {};
            self.render_type_id(ty, &vn[0], &mut decl[0], 256);
            self.buf.format_into("{}; ", diag::cstr(&decl[0]));
        }
        self.emit_str("for (;;) ");
        self.pending_cnt = (le + 1) as u32;
        self.emit_block(n.as_data.while_stmt.body);
        if le >= 0 && self.loop_stack[le as usize].used_brk {
            self.buf.format_into(" __brk{}:;", self.loop_stack[le as usize].seq);
        }
        if has_val && le >= 0 {
            self.buf.format_into(" __lv{}; }})", self.loop_stack[le as usize].seq);
        } else {
            self.emit_str(" })");
        }
        self.cg_loop_pop(le);
        self.loop_defer_base = saved_ldb;
    }
    fn cg_stmt_diverges(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_RETURN || n.kind == NodeKind::NODE_BREAK || n.kind == NodeKind::NODE_CONTINUE {
            return true;
        }
        if n.kind == NodeKind::NODE_BLOCK {
            let s = n.as_data.block.statements;
            return s.len > 0 && self.cg_stmt_diverges(unsafe (*self.cur_ast()).list(s)[(s.len - 1) as usize]);
        }
        if n.kind == NodeKind::NODE_IF {
            return n.as_data.if_stmt.else_branch != NODE_NONE && self.cg_stmt_diverges(n.as_data.if_stmt.then_branch) && self.cg_stmt_diverges(
                n.as_data.if_stmt.else_branch,
            );
        }
        return false;
    }
    fn cg_loop_push(self: &mut Self, node: NodeId, is_expr: bool) i32 {
        if self.nloops >= 32 {
            return -1;
        }
        let k = self.nloops;
        self.loop_stack[k as usize] = CgLoop {
            node: node,
            defer_base: self.defer_top,
            seq: self.label_seq,
            used_brk: false,
            used_cnt: false,
            is_expr: is_expr,
        };
        self.label_seq = self.label_seq + 1;
        self.nloops = k + 1;
        return k as i32;
    }
    fn cg_loop_pop(self: &mut Self, le: i32) {
        if le >= 0 {
            self.nloops = le as u32;
        }
    }
    fn cg_loop_find(self: &Self, node: NodeId) i32 {
        let mut i = self.nloops;
        while i > 0 {
            if self.loop_stack[(i - 1) as usize].node == node {
                return (i - 1) as i32;
            }
            i = i - 1;
        }
        return -1;
    }
    fn cg_loop_brk_label(self: &mut Self, le: i32) {
        if le >= 0 && self.loop_stack[le as usize].used_brk {
            self.emit_indent();
            self.buf.format_into("__brk{}:;\n", self.loop_stack[le as usize].seq);
        }
    }
    fn emit_defers_to(self: &mut Self, base: u32) {
        let mut i = self.defer_top;
        while i > base {
            i = i - 1;
            self.emit_indent();
            if self.defer_kind[i as usize] == 1 {
                self.emit_auto_free(self.defer_stack[i as usize]);
            } else {
                self.emit_expr_stmt(self.defer_stack[i as usize]);
            }
        }
    }
    fn emit_block_from(self: &mut Self, id: NodeId, dbase: u32) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let cnt_hook = self.pending_cnt;
        self.pending_cnt = 0;
        self.emit_str("{\n");
        self.depth = self.depth + 1;
        let mut i: u32 = 0;
        while i < self.nparam_flags {
            let mut fl = Buf32 {};
            cg_move_flag(&mut fl[0], 32, self.param_flags[i as usize]);
            self.emit_indent();
            self.buf.format_into("bool {} = false;\n", diag::cstr(&fl[0]));
            i = i + 1;
        }
        self.nparam_flags = 0;
        i = 0;
        while i < self.nunused_params {
            let mut pn = Buf128 {};
            self.render_ident(
                self.name_span(unsafe (*self.cur_ast()).at_const(self.unused_params[i as usize]).as_data.parameter.name),
                &mut pn[0],
                128,
            );
            if pn[0] == '_' as char && pn[1] == 0 as char {
                unsafe stdio::snprintf(&mut pn[0], 128, "__sc_u%u".ptr() as *const char, self.unused_params[i as usize]);
            }
            self.emit_indent();
            self.buf.format_into("(void){};\n", diag::cstr(&pn[0]));
            i = i + 1;
        }
        self.nunused_params = 0;
        let stmts = n.as_data.block.statements;
        i = 0;
        while i < stmts.len {
            self.emit_indent();
            self.emit_stmt(unsafe (*self.cur_ast()).list(stmts)[i as usize]);
            i = i + 1;
        }
        let mut diverges = false;
        if stmts.len > 0 {
            diverges = self.cg_stmt_diverges(unsafe (*self.cur_ast()).list(stmts)[(stmts.len - 1) as usize]);
        }
        if !diverges {
            self.emit_defers_to(dbase);
        }
        self.defer_top = dbase;
        if cnt_hook != 0 && self.loop_stack[(cnt_hook - 1) as usize].used_cnt {
            self.emit_indent();
            self.buf.format_into("__cnt{}:;\n", self.loop_stack[(cnt_hook - 1) as usize].seq);
        }
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("}");
    }
    fn emits_own_parens(self: &mut Self, id: NodeId) bool {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        if self.ceval() != null && self.cg_fold_worthwhile(id) && self.cg_maybe_const(id) && unsafe (*self.ceval()).eval(
            self.cur_module(),
            id,
        ).kind != ce::CONST_NONE {
            return false;
        }
        if n.kind == NodeKind::NODE_BINARY || n.kind == NodeKind::NODE_CAST {
            return true;
        }
        if n.kind == NodeKind::NODE_UNARY {
            if n.as_data.unary.op != TokenType::Move && n.as_data.unary.op != TokenType::Unsafe {
                return true;
            }
            return self.emits_own_parens(n.as_data.unary.operand);
        }
        if n.kind == NodeKind::NODE_NEW {
            return n.as_data.new_expr.initializer == NODE_NONE;
        }
        return false;
    }
    fn emit_condition(self: &mut Self, id: NodeId) {
        if self.emits_own_parens(id) {
            self.emit_expr(id);
        } else {
            self.emit_str("(");
            self.emit_expr(id);
            self.emit_str(")");
        }
    }
    fn emit_if(self: &mut Self, id: NodeId) {
        let ifd = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt;
        self.emit_str("if ");
        self.emit_condition(ifd.condition);
        self.emit_str(" ");
        self.emit_block(ifd.then_branch);
        if ifd.else_branch != NODE_NONE {
            self.emit_str(" else ");
            if unsafe (*self.cur_ast()).at_const(ifd.else_branch).kind == NodeKind::NODE_IF {
                self.emit_if(ifd.else_branch);
            } else {
                self.emit_block(ifd.else_branch);
            }
        }
    }
    fn emit_block_value(self: &mut Self, id: NodeId, result: *const char) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        self.emit_str("{\n");
        self.depth = self.depth + 1;
        let dbase = self.defer_top;
        let stmts = n.as_data.block.statements;
        for i in 0..stmts.len {
            let sid = unsafe (*self.cur_ast()).list(stmts)[i as usize];
            let s = *unsafe (*self.cur_ast()).at_const(sid);
            self.emit_indent();
            if i + 1 == stmts.len && s.kind == NodeKind::NODE_EXPRESSION_STATEMENT {
                let vt = unsafe (*self.cur_ast()).type_of(s.as_data.single.value);
                if vt == TYPE_NONE || self.type_at(vt).kind != TypeKind::TYPE_NEVER {
                    self.buf.format_into("{} = ", diag::cstr(result));
                }
                self.emit_expr(s.as_data.single.value);
                self.emit_str(";\n");
            } else {
                self.emit_stmt(sid);
            }
        }
        self.emit_defers_to(dbase);
        self.defer_top = dbase;
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("}");
    }
    fn emit_if_value(self: &mut Self, id: NodeId, result: *const char) {
        let ifd = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt;
        self.emit_str("if ");
        self.emit_condition(ifd.condition);
        self.emit_str(" ");
        self.emit_block_value(ifd.then_branch, result);
        if ifd.else_branch != NODE_NONE {
            self.emit_str(" else ");
            if unsafe (*self.cur_ast()).at_const(ifd.else_branch).kind == NodeKind::NODE_IF {
                self.emit_if_value(ifd.else_branch, result);
            } else {
                self.emit_block_value(ifd.else_branch, result);
            }
        }
    }
}

extend Codegen {
    fn emit_prefixed(self: &mut Self, obj: NodeId, prefix: *const char) {
        let k = unsafe (*self.cur_ast()).at_const(obj).kind;
        let primary = k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_MEMBER || k == NodeKind::NODE_INDEX || k == NodeKind::NODE_CALL;
        self.emit_cstr(prefix);
        if primary {
            self.emit_expr(obj);
        } else {
            self.emit_str("(");
            self.emit_expr(obj);
            self.emit_str(")");
        }
    }

    // Emit `&recv` for a by-value method receiver. When the callee takes `&mut self` and `recv` is `v[i]`
    // (a scalar index overload), route through `index_mut` so the element is reached mutably -- otherwise
    // `v[i].mut_method()` would mutate through the const `index` pointer.
    fn emit_recv_addr(self: &mut Self, obj: NodeId, want_mut: bool) {
        if want_mut {
            let k = unsafe (*self.cur_ast()).at_const(obj).kind;
            let idx_ok = k == NodeKind::NODE_INDEX && unsafe (*self.cur_ast()).at_const(
                unsafe (*self.cur_ast()).at_const(obj).as_data.index.index,
            ).kind != NodeKind::NODE_RANGE;
            if idx_ok || k == NodeKind::NODE_MEMBER {
                // `&(*index_mut(v,i))` folds to `index_mut(v,i)`; for a `v[i].field.method()` receiver the
                // member chain routes its index base through index_mut too (via emit_place).
                self.emit_str("&");
                self.emit_place(obj, true);
                return;
            }
        }
        self.emit_prefixed(obj, "&".ptr() as *const char);
    }
    fn emit_slice_base(self: &mut Self, obj: NodeId, rd: i32) {
        if rd == 0 {
            self.emit_expr(obj);
            return;
        }
        self.emit_str("(");
        self.emit_prefixed(obj, ref_derefs(rd + 1));
        self.emit_str(")");
    }
    fn render_enum_cname(self: &mut Self, v: DefId, en: NodeId, enum_ty: TypeId, buf: *mut char, cap: usize) {
        if enum_ty != TYPE_NONE && self.type_at(enum_ty).kind == TypeKind::TYPE_INSTANCE {
            self.inst_name(unsafe (*self.cur_ast()).instance(self.type_at(enum_ty).as_data.inst), buf, cap);
        } else {
            self.render_qualified(
                v.module,
                unsafe (*self.mod_ast(v.module)).at_const(en).as_data.aggregate.name,
                buf,
                cap,
            );
        }
    }
    fn emit_variant_value(self: &mut Self, v: DefId, enum_ty: TypeId) {
        let en = self.enclosing_enum_in(v.module, v.node);
        if en == NODE_NONE {
            self.emit_str("0");
            return;
        }
        if !self.aggregate_has_payload_in(v.module, en) {
            self.emit_tag_mod(v.module, en, v.node);
            return;
        }
        let mut enm = Buf256 {};
        self.render_enum_cname(v, en, enum_ty, &mut enm[0], 200);
        self.buf.format_into("({}){{ .tag = ", diag::cstr(&enm[0]));
        self.emit_tag_mod(v.module, en, v.node);
        self.emit_str(" }");
    }
    fn emit_variant_construct(self: &mut Self, v: DefId, args: NodeList, aids: *const NodeId, enum_ty: TypeId) {
        let en = self.enclosing_enum_in(v.module, v.node);
        if en == NODE_NONE || !self.aggregate_has_payload_in(v.module, en) {
            self.emit_variant_value(v, enum_ty);
            return;
        }
        let mut enm = Buf256 {};
        let mut vn = Buf128 {};
        self.render_enum_cname(v, en, enum_ty, &mut enm[0], 200);
        self.render_variant_name(v.module, v.node, &mut vn[0], 128);
        self.buf.format_into("({}){{ .tag = ", diag::cstr(&enm[0]));
        self.emit_tag_mod(v.module, en, v.node);
        if args.len != 0 {
            self.buf.format_into(", .payload.{} = {{ ", diag::cstr(&vn[0]));
            for i in 0..args.len {
                if i != 0 {
                    self.emit_str(", ");
                }
                self.emit_expr(unsafe aids[i as usize]);
            }
            self.emit_str(" }");
        }
        self.emit_str(" }");
    }
    fn emit_method_targs(self: &mut Self, callId: NodeId, md: DefId) {
        let mn = unsafe (*self.mod_ast(md.module)).at_const(md.node);
        if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.generics.len == 0 {
            return;
        }
        let mu = unsafe (*self.cur_ast()).type_args(callId);
        let mut i: u8 = 0;
        while mu != null && i < unsafe (*mu).n {
            let mut e = Buf256 {};
            self.mangle_type(self.subst_resolve(unsafe (*mu).args[i as usize]), &mut e[0], 176);
            self.buf.format_into("__{}", diag::cstr(&e[0]));
            i = i + 1;
        }
    }
    fn emit_op_method(self: &mut Self, bt: Ty, om: ModuleId, od: NodeId, mth: DefId) {
        if bt.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(bt.as_data.inst), &mut inm[0], 200);
            self.emit_cstr(&inm[0]);
            self.emit_paste();
            self.emit_str("__");
        } else {
            let mut pfx = Buf64 {};
            self.render_modpfx(mth.module, &mut pfx[0], 64);
            self.emit_cstr(&pfx[0]);
            self.emit_ident_mod(om, unsafe (*self.mod_ast(om)).at_const(od).as_data.aggregate.name);
            self.emit_str("__");
        }
        self.emit_ident_mod(mth.module, unsafe (*self.mod_ast(mth.module)).at_const(mth.node).as_data.function.name);
    }
    // Emit `node` for a by-value comparison: reference levels are peeled with `*` so the pointees are
    // compared. Pointers (ref depth 0) are left as-is (address comparison).
    fn emit_cmp_value(self: &mut Self, node: NodeId) {
        let t = unsafe (*self.cur_ast()).type_of(node);
        let d = if t != TYPE_NONE {
            self.cg_ref_depth(self.subst_resolve(t));
        } else {
            0;
        };
        if d <= 0 {
            self.emit_expr(node);
            return;
        }
        self.emit_str("(");
        for _ in 0..d {
            self.emit_str("*");
        }
        self.emit_expr(node);
        self.emit_str(")");
    }

    fn emit_cmp_overload(self: &mut Self, id: NodeId) bool {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let op = bd.op;
        if op != TokenType::EqualEqual && op != TokenType::BangEqual && op != TokenType::LessThan && op != TokenType::LessThanEqual && op != TokenType::GreaterThan && op != TokenType::GreaterThanEqual {
            return false;
        }
        let lt0 = unsafe (*self.cur_ast()).type_of(bd.left);
        if lt0 == TYPE_NONE {
            return false;
        }
        let lt = self.strip_ref_only(self.subst_resolve(lt0));
        if lt == TYPE_NONE {
            return false;
        }
        let bt = *self.type_at(lt);
        if bt.kind != TypeKind::TYPE_STRUCT && bt.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if bt.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
            om = it.module;
            od = it.decl;
        } else {
            om = bt.module;
            od = bt.as_data.decl;
        }
        let ord = op != TokenType::EqualEqual && op != TokenType::BangEqual;
        let mut mm = "eq".ptr() as *const char;
        if ord {
            mm = "cmp".ptr() as *const char;
        }
        let m = self.cg_find_method_cstr(om, od, mm);
        if m.node == NODE_NONE {
            return false;
        }
        let rt0 = unsafe (*self.cur_ast()).type_of(bd.right);
        let dl = self.cg_ref_depth(self.subst_resolve(unsafe (*self.cur_ast()).type_of(bd.left)));
        let mut dr: i32 = 0;
        if rt0 != TYPE_NONE {
            dr = self.cg_ref_depth(self.subst_resolve(rt0));
        }
        let mut lb = Buf32 {};
        let mut rb = Buf32 {};
        self.fresh(&mut lb[0], 32);
        self.fresh(&mut rb[0], 32);
        self.buf.format_into("(({{ __auto_type {} = ", diag::cstr(&lb[0]));
        self.emit_expr(bd.left);
        self.buf.format_into("; __auto_type {} = ", diag::cstr(&rb[0]));
        self.emit_expr(bd.right);
        self.emit_str("; ");
        if op == TokenType::BangEqual {
            self.emit_str("!");
        }
        if ord {
            self.emit_str("(");
        }
        self.emit_op_method(bt, om, od, m);
        let mut lp = "&".ptr() as *const char;
        if dl != 0 {
            lp = ref_derefs(dl);
        }
        let mut rp = "&".ptr() as *const char;
        if dr != 0 {
            rp = ref_derefs(dr);
        }
        self.buf.format_into("({}{}, {}{})", diag::cstr(lp), diag::cstr(&lb[0]), diag::cstr(rp), diag::cstr(&rb[0]));
        if ord {
            self.buf.format_into(" {} 0)", diag::cstr(c_op(op)));
        }
        self.emit_str("; }))");
        return true;
    }

    fn emit_ident_ref(self: &mut Self, id: NodeId) {
        let d = unsafe (*self.cur_ast()).resolution_def(id);
        let nt = unsafe (*self.cur_ast()).at_const(id).as_data.name.text;
        if d.node != NODE_NONE && d.module == self.cur_module() {
            let mut is_mut = false;
            if self.cg_env_capture(d.node, &mut is_mut) >= 0 {
                if is_mut {
                    self.emit_str("(*__env->");
                } else {
                    self.emit_str("__env->");
                }
                self.emit_ident(nt);
                if is_mut {
                    self.emit_str(")");
                }
                return;
            }
        }
        if d.node != NODE_NONE {
            let da = self.mod_ast(d.module);
            let dn = *unsafe (*da).at_const(d.node);
            if dn.kind == NodeKind::NODE_VARIANT {
                let en = self.enclosing_enum_in(d.module, d.node);
                if en != NODE_NONE {
                    self.emit_tag_mod(d.module, en, d.node);
                    return;
                }
            }
            if dn.kind == NodeKind::NODE_FUNCTION {
                let mut ov = Buf256 {};
                if self.cg_symbol_override(d.module, d.node, &mut ov[0], 160) {
                    self.emit_cstr(&ov[0]);
                    return;
                }
            }
            if dn.kind == NodeKind::NODE_FUNCTION && dn.as_data.function.body != NODE_NONE && !span_is(
                self.mod_src(d.module),
                unsafe (*da).at_const(dn.as_data.function.name).as_data.name.text,
                "main".ptr() as *const char,
            ) {
                let mut nm = Buf256 {};
                self.render_qualified(d.module, dn.as_data.function.name, &mut nm[0], 160);
                self.emit_cstr(&nm[0]);
                return;
            }
            if dn.kind == NodeKind::NODE_CONST && dn.as_data.const_def.is_extern {
                let mut ov = Buf256 {};
                if self.cg_symbol_override(d.module, d.node, &mut ov[0], 160) {
                    self.emit_cstr(&ov[0]);
                } else {
                    self.emit_ident_mod(d.module, dn.as_data.const_def.name);
                }
                return;
            }
            if dn.kind == NodeKind::NODE_CONST && (!self.mangle || self.decl_is_toplevel(d.module, d.node)) {
                let mut nm = Buf256 {};
                self.render_qualified(d.module, dn.as_data.const_def.name, &mut nm[0], 160);
                self.emit_cstr(&nm[0]);
                return;
            }
        }
        self.emit_ident(nt);
    }

    fn emit_array_braces(self: &mut Self, id: NodeId) {
        let elements = unsafe (*self.cur_ast()).at_const(id).as_data.array_literal.elements;
        self.emit_str("{ ");
        for i in 0..elements.len {
            if i != 0 {
                self.emit_str(", ");
            }
            let eid = unsafe (*self.cur_ast()).list(elements)[i as usize];
            let el = unsafe (*self.cur_ast()).at_const(eid);
            if el.kind == NodeKind::NODE_FIELD_INITIALIZER {
                self.emit_str("[");
                let nameNode = el.as_data.field_initializer.name;
                let valNode = el.as_data.field_initializer.value;
                let mut folded = false;
                if self.ceval() != null {
                    let iv = unsafe (*self.ceval()).eval(self.cur_module(), nameNode);
                    if iv.kind == ce::CONST_INT {
                        self.buf.format_into("{}", iv.as_data.i);
                        folded = true;
                    }
                }
                if !folded {
                    self.emit_expr(nameNode);
                }
                self.emit_str("] = ");
                if unsafe (*self.cur_ast()).at_const(valNode).kind == NodeKind::NODE_ARRAY_LITERAL {
                    self.emit_array_braces(valNode);
                } else {
                    self.emit_expr(valNode);
                }
            } else if el.kind == NodeKind::NODE_ARRAY_LITERAL {
                self.emit_array_braces(eid);
            } else {
                self.emit_expr(eid);
            }
        }
        self.emit_str(" }");
    }

    // Render a folded scalar as a C literal (typed suffixes, the INT64_MIN special case, %.17g
    // floats). False when the value is not a foldable scalar.
    fn emit_scalar_folded(self: &mut Self, v: ce::ConstValue) bool {
        if v.kind == ce::CONST_BOOL {
            if v.as_data.i != 0 {
                self.emit_str("true");
            } else {
                self.emit_str("false");
            }
            return true;
        }
        if v.kind == ce::CONST_INT {
            let mut vb = BuiltinType::BT_COUNT;
            if v.ty != TYPE_NONE && self.type_at(v.ty).kind == TypeKind::TYPE_BUILTIN {
                vb = self.type_at(v.ty).as_data.builtin;
            }
            let uns = vb == BuiltinType::BT_U8 || vb == BuiltinType::BT_U16 || vb == BuiltinType::BT_U32 || vb == BuiltinType::BT_U64 || vb == BuiltinType::BT_USIZE;
            if uns {
                if vb == BuiltinType::BT_U64 || vb == BuiltinType::BT_USIZE {
                    self.buf.format_into("{}ULL", v.as_data.i as u64);
                } else {
                    self.buf.format_into("{}U", v.as_data.i as u64);
                }
            } else if v.as_data.i == -9223372036854775807i64 - 1 {
                self.emit_str("(-9223372036854775807ll - 1)");
            } else if vb == BuiltinType::BT_I64 || vb == BuiltinType::BT_ISIZE {
                self.buf.format_into("{}LL", v.as_data.i);
            } else if v.as_data.i > 0x7FFFFFFFi64 || v.as_data.i < -0x80000000i64 {
                self.buf.format_into("{}ll", v.as_data.i);
            } else {
                self.buf.format_into("{}", v.as_data.i);
            }
            return true;
        }
        if v.kind == ce::CONST_FLOAT {
            let mut f32t = false;
            if v.ty != TYPE_NONE && self.type_at(v.ty).kind == TypeKind::TYPE_BUILTIN && self.type_at(v.ty).as_data.builtin == BuiltinType::BT_F32 {
                f32t = true;
            }
            let mut fb = Buf64 {};
            unsafe stdio::snprintf(&mut fb[0], 48, "%.17g".ptr() as *const char, v.as_data.f);
            let fl = unsafe cstring::strlen(&fb[0]);
            let has = unsafe cstring::memchr(&fb[0], '.', fl) != null || unsafe cstring::memchr(&fb[0], 'e', fl) != null || unsafe cstring::memchr(
                &fb[0],
                'E',
                fl,
            ) != null;
            if !has {
                bappend(&mut fb[0], 48, fl, ".0".ptr() as *const char);
            }
            if f32t {
                self.buf.format_into("{}f", diag::cstr(&fb[0]));
            } else {
                self.emit_cstr(&fb[0]);
            }
            return true;
        }
        return false;
    }

    fn emit_expr(self: &mut Self, id: NodeId) {
        if id == NODE_NONE {
            return;
        }
        if id != self.slice_raw && self.emit_slice_coercion(id) {
            return;
        }
        if id != self.dyn_raw && self.emit_dyn_coercion(id) {
            return;
        }
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let nk = n.kind;
        if self.ceval() != null && (nk == NodeKind::NODE_BINARY || nk == NodeKind::NODE_UNARY || nk == NodeKind::NODE_CAST || nk == NodeKind::NODE_CALL || nk == NodeKind::NODE_SIZEOF || nk == NodeKind::NODE_ALIGNOF) && self.cg_fold_worthwhile(
            id,
        ) && self.cg_maybe_const(id) {
            let v = unsafe (*self.ceval()).eval(self.cur_module(), id);
            if self.emit_scalar_folded(v) {
                return;
            }
        }
        switch nk {
            NODE_LITERAL => {
                self.emit_literal(id);
            },
            NODE_IDENTIFIER => {
                let mut cv: i64 = 0;
                if self.cg_const_param_value(id, &mut cv) {
                    self.buf.format_into("{}", cv); // monomorphized const-generic value
                } else if self.cg_is_cond_site(id) {
                    let mut fl = Buf32 {};
                    cg_move_flag(&mut fl[0], 32, unsafe (*self.cur_ast()).resolution_def(id).node);
                    self.buf.format_into("({} = true, ", diag::cstr(&fl[0]));
                    self.emit_ident_ref(id);
                    self.emit_str(")");
                } else {
                    self.emit_ident_ref(id);
                }
            },
            NODE_UNARY => {
                let op = n.as_data.unary.op;
                let operand = n.as_data.unary.operand;
                if op == TokenType::Question {
                    self.emit_try(id);
                } else if op == TokenType::Move || op == TokenType::Unsafe {
                    self.emit_expr(operand);
                } else if op == TokenType::Ampersand && !self.is_lvalue(operand) && self.type_at(
                    unsafe (*self.cur_ast()).type_of(operand),
                ).kind == TypeKind::TYPE_BUILTIN {
                    let mut ty = Buf256 {};
                    self.render_type_id(
                        unsafe (*self.cur_ast()).type_of(operand),
                        "".ptr() as *const char,
                        &mut ty[0],
                        128,
                    );
                    self.buf.format_into("(&({}){{", diag::cstr(&ty[0]));
                    self.emit_expr(operand);
                    self.emit_str("})");
                } else {
                    let addr_mut = op == TokenType::Ampersand && n.as_data.unary.qualifier == TypeQualifier::TYPE_QUAL_MUT;
                    self.buf.format_into("({}", diag::cstr(c_op(op)));
                    self.emit_place(operand, addr_mut);
                    self.emit_str(")");
                }
            },
            NODE_BINARY => {
                if self.emit_cmp_overload(id) {
                    return;
                }
                if self.emit_arith_overload(id) {
                    return;
                }
                let bd = n.as_data.binary;
                if bd.op == TokenType::Percent {
                    let lt = self.type_at(unsafe (*self.cur_ast()).type_of(bd.left));
                    if lt.kind == TypeKind::TYPE_BUILTIN && (lt.as_data.builtin == BuiltinType::BT_F32 || lt.as_data.builtin == BuiltinType::BT_F64) {
                        let mut fn2 = "fmod".ptr() as *const char;
                        if lt.as_data.builtin == BuiltinType::BT_F32 {
                            fn2 = "fmodf".ptr() as *const char;
                        }
                        self.buf.format_into("{}(", diag::cstr(fn2));
                        self.emit_expr(bd.left);
                        self.emit_str(", ");
                        self.emit_expr(bd.right);
                        self.emit_str(")");
                        return;
                    }
                }
                if self.emit_cg_checked_arith(id) {
                    return;
                }
                // References compare by value: a `&T` operand of a comparison is dereferenced so the
                // scalar values are compared, matching the struct `eq`/`cmp` path. Raw pointers keep
                // TYPE_POINTER (ref depth 0), so `*const T == *const T` stays an address comparison.
                let cmpop = bd.op == TokenType::EqualEqual || bd.op == TokenType::BangEqual || bd.op == TokenType::LessThan || bd.op == TokenType::LessThanEqual || bd.op == TokenType::GreaterThan || bd.op == TokenType::GreaterThanEqual;
                self.emit_str("(");
                if cmpop {
                    self.emit_cmp_value(bd.left);
                } else {
                    self.emit_expr(bd.left);
                }
                self.buf.format_into(" {} ", diag::cstr(c_op(bd.op)));
                // The RHS of a short-circuit op only conditionally executes: a proven-UB fold
                // failure inside it must not be promoted to an error.
                let sc = bd.op == TokenType::AmpersandAmpersand || bd.op == TokenType::PipePipe;
                let scce = self.ceval();
                if sc && scce != null {
                    let rp = unsafe (*scce).record_pause;
                    unsafe (*scce).record_pause = rp + 1;
                }
                if cmpop {
                    self.emit_cmp_value(bd.right);
                } else {
                    self.emit_expr(bd.right);
                }
                if sc && scce != null {
                    let rp = unsafe (*scce).record_pause;
                    unsafe (*scce).record_pause = rp - 1;
                }
                self.emit_str(")");
            },
            NODE_ASSIGNMENT => {
                self.emit_assignment(id);
            },
            NODE_CALL => {
                let ct = unsafe (*self.cur_ast()).type_of(id);
                let arr_ret = ct != TYPE_NONE && self.type_at(ct).kind == TypeKind::TYPE_ARRAY;
                let cn = unsafe (*self.cur_ast()).at_const(n.as_data.call.callee);
                if cn.kind == NodeKind::NODE_GENERIC_SPECIALIZATION && unsafe (*self.cur_ast()).at_const(
                    cn.as_data.specialization.expression,
                ).kind == NodeKind::NODE_IDENTIFIER && unsafe (*self.cur_ast()).resolution_def(
                    cn.as_data.specialization.expression,
                ).node == NODE_NONE && span_is(
                    self.mod_src(self.cur_module()),
                    unsafe (*self.cur_ast()).at_const(cn.as_data.specialization.expression).as_data.name.text,
                    "dyn_cast".ptr() as *const char,
                ) {
                    self.emit_dyn_cast(id);
                    return;
                }
                let mut freeflag = Buf32 {};
                freeflag[0] = 0 as char;
                if cn.kind == NodeKind::NODE_MEMBER && !cn.as_data.member.path && cn.as_data.member.object != NODE_NONE && unsafe (*self.cur_ast()).at_const(
                    cn.as_data.member.object,
                ).kind == NodeKind::NODE_IDENTIFIER && span_is(
                    self.mod_src(self.cur_module()),
                    unsafe (*self.cur_ast()).at_const(cn.as_data.member.member).as_data.name.text,
                    "free".ptr() as *const char,
                ) {
                    let rd = unsafe (*self.cur_ast()).resolution_def(cn.as_data.member.object);
                    if rd.module == self.cur_module() && self.cg_is_cond_moved(rd.node) {
                        cg_move_flag(&mut freeflag[0], 32, rd.node);
                        self.buf.format_into("({} = true, ", diag::cstr(&freeflag[0]));
                    }
                }
                if arr_ret {
                    self.emit_str("(");
                }
                self.emit_call(id);
                if arr_ret {
                    self.emit_str(")._");
                }
                if freeflag[0] != 0 as char {
                    self.emit_str(")");
                }
            },
            NODE_CLOSURE => {
                let mut nm = Buf256 {};
                self.closure_name(id, &mut nm[0], 200);
                if n.as_data.closure.captures.len != 0 {
                    let mut wrapped = false;
                    if self.cg_is_cond_site(id) {
                        let caps = n.as_data.closure.captures;
                        for i in 0..caps.len {
                            let cid = unsafe (*self.cur_ast()).list(caps)[i as usize];
                            if (n.as_data.closure.mut_caps as u64 >> i as u64 & 1u64) != 0 || !self.cg_is_cond_moved(
                                cid,
                            ) {
                                continue;
                            }
                            let mut fl = Buf32 {};
                            cg_move_flag(&mut fl[0], 32, cid);
                            if wrapped {
                                self.buf.format_into("{} = true, ", diag::cstr(&fl[0]));
                            } else {
                                self.buf.format_into("({} = true, ", diag::cstr(&fl[0]));
                            }
                            wrapped = true;
                        }
                    }
                    self.buf.format_into("(({}_env){{ ", diag::cstr(&nm[0]));
                    let caps = n.as_data.closure.captures;
                    for i in 0..caps.len {
                        if i != 0 {
                            self.emit_str(", ");
                        }
                        self.emit_capture_init(id, i);
                    }
                    self.emit_str(" })");
                    if wrapped {
                        self.emit_str(")");
                    }
                } else {
                    self.emit_cstr(&nm[0]);
                }
            },
            NODE_TUPLE => {
                let mut styp = Buf256 {};
                self.render_type_id(unsafe (*self.cur_ast()).type_of(id), "".ptr() as *const char, &mut styp[0], 200);
                self.buf.format_into("({}){{ ", diag::cstr(&styp[0]));
                let elems = n.as_data.array_literal.elements;
                for i in 0..elems.len {
                    if i != 0 {
                        self.buf.format_into(", ._{} = ", i);
                    } else {
                        self.buf.format_into("._{} = ", i);
                    }
                    self.emit_expr(unsafe (*self.cur_ast()).list(elems)[i as usize]);
                }
                self.emit_str(" }");
            },
            NODE_RANGE => {
                let mut styp = Buf256 {};
                self.render_type_id(unsafe (*self.cur_ast()).type_of(id), "".ptr() as *const char, &mut styp[0], 200);
                self.buf.format_into("({}){{ .start = ", diag::cstr(&styp[0]));
                self.emit_expr(n.as_data.pattern_range.start);
                self.emit_str(", .end = ");
                self.emit_expr(n.as_data.pattern_range.end);
                let mut incl = "false".ptr() as *const char;
                if n.as_data.pattern_range.inclusive {
                    incl = "true".ptr() as *const char;
                }
                self.buf.format_into(", .inclusive = {} }}", diag::cstr(incl));
            },
            NODE_INDEX => {
                self.emit_index(id, false);
            },
            NODE_MEMBER => {
                self.emit_member(id, false);
            },
            NODE_CAST => {
                let mut t = Buf256 {};
                self.render_type_node(n.as_data.cast.ty, "".ptr() as *const char, &mut t[0], 256);
                self.buf.format_into("(({})", diag::cstr(&t[0]));
                self.emit_expr(n.as_data.cast.expression);
                self.emit_str(")");
            },
            NODE_GENERIC_SPECIALIZATION => {
                self.emit_expr(n.as_data.specialization.expression);
            },
            NODE_SIZEOF | NODE_ALIGNOF => {
                self.emit_sizeof(id);
            },
            NODE_VA_EXPR => {
                let vo = n.as_data.va_op;
                if vo.op == VA_ARG {
                    let mut ty = Buf256 {};
                    self.render_type_node(vo.extra, "".ptr() as *const char, &mut ty[0], 256);
                    self.emit_str("va_arg(");
                    self.emit_expr(vo.ap);
                    self.buf.format_into(", {})", diag::cstr(&ty[0]));
                } else if vo.op == VA_START {
                    self.emit_str("va_start(");
                    self.emit_expr(vo.ap);
                    self.emit_str(", ");
                    self.emit_expr(vo.extra);
                    self.emit_str(")");
                } else {
                    self.emit_str("va_end(");
                    self.emit_expr(vo.ap);
                    self.emit_str(")");
                }
            },
            NODE_STRUCT_INITIALIZER => {
                self.emit_struct_init(id);
            },
            NODE_NEW => {
                self.emit_new(id);
            },
            NODE_ARRAY_LITERAL => {
                let at = unsafe (*self.cur_ast()).type_of(id);
                let mut et = Buf256 {};
                if at != TYPE_NONE {
                    let ae = self.type_at(at).as_data.elem;
                    self.render_type_id(ae, "".ptr() as *const char, &mut et[0], 256);
                } else {
                    unsafe stdio::snprintf(&mut et[0], 256, "%s".ptr() as *const char, "int".ptr() as *const char);
                }
                self.buf.format_into("({}[{}])", diag::cstr(&et[0]), n.as_data.array_literal.elements.len);
                self.emit_array_braces(id);
            },
            NODE_MATCH => {
                self.emit_match_expr(id);
            },
            NODE_IF => {
                self.emit_if_expr(id);
            },
            NODE_WHILE => {
                self.emit_loop_expr(id);
            },
            NODE_BLOCK => {
                self.emit_str("(");
                self.emit_str("{\n");
                self.depth = self.depth + 1;
                let stmts = n.as_data.block.statements;
                let saved = self.no_temp_free;
                for i in 0..stmts.len {
                    self.no_temp_free = i + 1 == stmts.len;
                    self.emit_indent();
                    self.emit_stmt(unsafe (*self.cur_ast()).list(stmts)[i as usize]);
                }
                self.no_temp_free = saved;
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_str("})");
            },
            _ => {
                self.errors.emit(n.span.start, n.span.end - n.span.start, format("codegen: unsupported expression"));
            },
        };
    }

    fn emit_literal(self: &mut Self, id: NodeId) {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let s = n.as_data.literal.raw;
        let tt = n.as_data.literal.token_type;
        if tt == TokenType::True {
            self.emit_str("true");
        } else if tt == TokenType::False {
            self.emit_str("false");
        } else if tt == TokenType::Null {
            self.emit_str("NULL");
        } else if tt == TokenType::CharacterLiteral {
            self.emit_reescaped(s, true);
        } else if tt == TokenType::StringLiteral {
            let tid = unsafe (*self.cur_ast()).type_of(id);
            let mut isptr = false;
            if tid != TYPE_NONE && self.type_at(tid).kind == TypeKind::TYPE_POINTER {
                isptr = true;
            }
            if isptr {
                let pe = *self.type_at(self.type_at(tid).as_data.elem);
                if pe.kind == TypeKind::TYPE_BUILTIN && pe.as_data.builtin == BuiltinType::BT_U8 {
                    self.emit_str("(const uint8_t *)");
                }
                self.emit_reescaped(s, false);
            } else {
                self.emit_str("(str){ (const uint8_t *)");
                self.emit_reescaped(s, false);
                self.emit_str(", sizeof(");
                self.emit_reescaped(s, false);
                self.emit_str(") - 1 }");
            }
        } else if tt == TokenType::ByteStringLiteral {
            let mut sn = Buf256 {};
            self.render_type_id(
                self.subst_resolve(unsafe (*self.cur_ast()).type_of(id)),
                "".ptr() as *const char,
                &mut sn[0],
                200,
            );
            let bc = tok::Span { start: s.start + 1, end: s.end };
            self.buf.format_into("({}){{ .ptr = (const uint8_t *)", diag::cstr(&sn[0]));
            self.emit_reescaped(bc, false);
            self.emit_str(", .len = sizeof(");
            self.emit_reescaped(bc, false);
            self.emit_str(") - 1 }");
        } else if tt == TokenType::ByteCharacterLiteral {
            self.emit_str("(uint8_t)");
            if s.end > s.start && self.source[s.start as usize] == b'b' {
                self.emit_bytes(src_at(self.source, s.start + 1), ((s.end - s.start - 1) as i32) as usize);
            } else {
                self.emit_span(s);
            }
        } else if tt == TokenType::RawStringLiteral {
            let rc = raw_string_content(self.source, s);
            let tid = unsafe (*self.cur_ast()).type_of(id);
            let mut isptr = false;
            if tid != TYPE_NONE && self.type_at(tid).kind == TypeKind::TYPE_POINTER {
                isptr = true;
            }
            if isptr {
                let pe = *self.type_at(self.type_at(tid).as_data.elem);
                if pe.kind == TypeKind::TYPE_BUILTIN && pe.as_data.builtin == BuiltinType::BT_U8 {
                    self.emit_str("(const uint8_t *)");
                }
                self.emit_raw_c_string(rc);
            } else {
                self.emit_str("(str){ (const uint8_t *)");
                self.emit_raw_c_string(rc);
                self.buf.format_into(", {} }}", rc.end - rc.start);
            }
        } else {
            let lt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            let mut b = BuiltinType::BT_COUNT;
            if lt != TYPE_NONE && self.type_at(lt).kind == TypeKind::TYPE_BUILTIN {
                b = self.type_at(lt).as_data.builtin;
            }
            self.emit_number(s, tt, b);
        }
    }
}
const fn sep(decl: *const char) *const char {
    if unsafe decl[0] != 0 as char {
        return " ".ptr() as *const char;
    }
    return "".ptr() as *const char;
}
fn not_const_prefixed(base: *const char) bool {
    return unsafe cstring::strncmp(base, "const ".ptr() as *const char, 6) != 0;
}
fn buf_join3(out: *mut char, cap: usize, first: *const char, second: *const char, third: *const char) {
    if cap != 0 {
        unsafe out[0] = 0 as char;
    }
    let mut at = bappend(out, cap, 0, first);
    at = bappend(out, cap, at, second);
    bappend(out, cap, at, third);
}
fn src_at(p: str, off: u32) *const char {
    return (unsafe (p.ptr() + off as usize)) as *const char;
}

fn span_is(src: str, s: tok::Span, lit: *const char) bool {
    let n = unsafe cstring::strlen(lit);
    if (s.end - s.start) as usize != n {
        return false;
    }
    return unsafe cstring::memcmp(src.ptr() + s.start as usize, lit, n) == 0;
}
fn spans_eq2(sa: str, a: tok::Span, sb: str, b: tok::Span) bool {
    let la = a.end - a.start;
    if la != b.end - b.start {
        return false;
    }
    return unsafe cstring::memcmp(sa.ptr() + a.start as usize, sb.ptr() + b.start as usize, la as usize) == 0;
}
fn builtin_name(b: BuiltinType) *const char {
    if b == BuiltinType::BT_BOOL {
        return "bool".ptr() as *const char;
    }
    if b == BuiltinType::BT_CHAR {
        return "char".ptr() as *const char;
    }
    if b == BuiltinType::BT_I8 {
        return "i8".ptr() as *const char;
    }
    if b == BuiltinType::BT_I16 {
        return "i16".ptr() as *const char;
    }
    if b == BuiltinType::BT_I32 {
        return "i32".ptr() as *const char;
    }
    if b == BuiltinType::BT_I64 {
        return "i64".ptr() as *const char;
    }
    if b == BuiltinType::BT_ISIZE {
        return "isize".ptr() as *const char;
    }
    if b == BuiltinType::BT_U8 {
        return "u8".ptr() as *const char;
    }
    if b == BuiltinType::BT_U16 {
        return "u16".ptr() as *const char;
    }
    if b == BuiltinType::BT_U32 {
        return "u32".ptr() as *const char;
    }
    if b == BuiltinType::BT_U64 {
        return "u64".ptr() as *const char;
    }
    if b == BuiltinType::BT_USIZE {
        return "usize".ptr() as *const char;
    }
    if b == BuiltinType::BT_F32 {
        return "f32".ptr() as *const char;
    }
    if b == BuiltinType::BT_F64 {
        return "f64".ptr() as *const char;
    }
    if b == BuiltinType::BT_C32 {
        return "c32".ptr() as *const char;
    }
    if b == BuiltinType::BT_C64 {
        return "c64".ptr() as *const char;
    }
    if b == BuiltinType::BT_VALIST {
        return "va_list".ptr() as *const char;
    }
    return "void".ptr() as *const char;
}
fn builtin_of(src: str, s: tok::Span) i32 {
    for i in 0..BuiltinType::BT_COUNT as i32 {
        if span_is(src, s, builtin_name(i as BuiltinType)) {
            return i;
        }
    }
    return -1;
}

fn render_ident_src(src: str, s: tok::Span, buf: *mut char, cap: usize) usize {
    let source_len = (s.end - s.start) as usize;
    let suffix = is_c_keyword(src, s);
    let mut full = source_len;
    if suffix {
        full = full + 1;
    }
    if cap != 0 {
        let mut copied = source_len;
        if copied > cap - 1 {
            copied = cap - 1;
        }
        unsafe cstring::memcpy(buf, src.ptr() + s.start as usize, copied);
        let mut written = copied;
        if suffix && written + 1 < cap {
            unsafe buf[written] = '_' as char;
            written = written + 1;
        }
        unsafe buf[written] = 0 as char;
    }
    return full;
}

// Set when any bappend hits its buffer cap; checked at finalize so a truncated C declarator is a
// hard compile error, never silently-invalid emitted C.
pub static mut CG_TRUNCATED: bool = false;

fn bappend_bytes(out: *mut char, cap: usize, at: usize, text: *const char, n: usize) usize {
    if at < cap {
        let room = cap - at - 1;
        let mut copied = n;
        if copied > room {
            copied = room;
            CG_TRUNCATED = true;
        }
        unsafe cstring::memcpy(out + at, text, copied);
        unsafe out[at + copied] = 0 as char;
    } else {
        CG_TRUNCATED = true;
    }
    return at + n;
}
fn bappend(out: *mut char, cap: usize, at: usize, text: *const char) usize {
    return bappend_bytes(out, cap, at, text, unsafe cstring::strlen(text));
}

// Length-carrying keyword compare: a str literal knows its length, so candidates are rejected
// on one immediate compare instead of a strlen per probe (span_is strlens its C-string literal).
fn ckw(src: str, s: tok::Span, lit: str) bool {
    if (s.end - s.start) as usize != lit.len() {
        return false;
    }
    return unsafe cstring::memcmp(src.ptr() + s.start as usize, lit.ptr(), lit.len()) == 0;
}
fn is_c_keyword(src: str, s: tok::Span) bool {
    let n = (s.end - s.start) as usize;
    if n == 0 {
        return false;
    }
    let c0 = src[s.start as usize];
    if c0 == b'N' {
        return ckw(src, s, "NULL");
    }
    if c0 == b'_' {
        return ckw(src, s, "_Bool") || ckw(src, s, "_Complex") || ckw(src, s, "_Atomic") || ckw(src, s, "_Noreturn") || ckw(
            src,
            s,
            "_Generic",
        ) || ckw(src, s, "_Static_assert") || ckw(src, s, "_Thread_local");
    }
    if c0 == b'a' {
        return ckw(src, s, "auto");
    }
    if c0 == b'b' {
        return ckw(src, s, "break") || ckw(src, s, "bool");
    }
    if c0 == b'c' {
        return ckw(src, s, "case") || ckw(src, s, "char") || ckw(src, s, "const") || ckw(src, s, "continue");
    }
    if c0 == b'd' {
        return ckw(src, s, "default") || ckw(src, s, "do") || ckw(src, s, "double");
    }
    if c0 == b'e' {
        return ckw(src, s, "else") || ckw(src, s, "enum") || ckw(src, s, "extern");
    }
    if c0 == b'f' {
        return ckw(src, s, "float") || ckw(src, s, "for") || ckw(src, s, "false");
    }
    if c0 == b'g' {
        return ckw(src, s, "goto");
    }
    if c0 == b'i' {
        return ckw(src, s, "if") || ckw(src, s, "inline") || ckw(src, s, "int");
    }
    if c0 == b'l' {
        return ckw(src, s, "long");
    }
    if c0 == b'r' {
        return ckw(src, s, "register") || ckw(src, s, "restrict") || ckw(src, s, "return");
    }
    if c0 == b's' {
        return ckw(src, s, "short") || ckw(src, s, "signed") || ckw(src, s, "sizeof") || ckw(src, s, "static") || ckw(
            src,
            s,
            "struct",
        ) || ckw(src, s, "switch");
    }
    if c0 == b't' {
        return ckw(src, s, "typedef") || ckw(src, s, "true");
    }
    if c0 == b'u' {
        return ckw(src, s, "union") || ckw(src, s, "unsigned");
    }
    if c0 == b'v' {
        return ckw(src, s, "void") || ckw(src, s, "volatile");
    }
    if c0 == b'w' {
        return ckw(src, s, "while");
    }
    return false;
}

pub type TyArgs8 = Array<TypeId, 8>;

// ---- larger scratch buffers for the backend ----
pub type Buf176 = Array<char, 176>;
pub type Buf200 = Array<char, 200>;
pub type Buf240 = Array<char, 240>;
pub type Buf300 = Array<char, 300>;
pub type Buf320 = Array<char, 320>;
pub type Buf368 = Array<char, 368>;
pub type Buf400 = Array<char, 400>;
pub type Buf600 = Array<char, 600>;
pub type Buf1024 = Array<char, 1024>;
pub type Buf1320 = Array<char, 1320>;
pub type Buf1400 = Array<char, 1400>;
pub type Buf4096 = Array<char, 4096>;
pub type TyArgs32 = Array<TypeId, 32>;
pub type Ids64 = Array<NodeId, 64>;

fn agg_kw(n: &Node) *const char {
    if n.kind == NodeKind::NODE_STRUCT && n.as_data.aggregate.is_union {
        return "union".ptr() as *const char;
    }
    return "struct".ptr() as *const char;
}

fn want_fn(which: i32, is_public: bool) bool {
    return which == PROTO_ALL || which == PROTO_PUBLIC == is_public;
}

fn cg_span_eq(sa: str, a: tok::Span, sb: str, b: tok::Span) bool {
    let la = (a.end - a.start) as usize;
    if la != (b.end - b.start) as usize {
        return false;
    }
    return unsafe cstring::memcmp(sa.ptr() + a.start as usize, sb.ptr() + b.start as usize, la) == 0;
}

// ---- backend: declarations, function emission ----
extend Codegen {
    fn program_items(self: &Self) NodeList {
        return unsafe (*self.cur_ast()).at_const((*self.cur_ast()).root).as_data.program.items;
    }

    fn type_emittable(self: &Self, declId: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(declId);
        if n.kind == NodeKind::NODE_STRUCT && n.as_data.aggregate.generics.len == 0 {
            return true;
        }
        if n.kind == NodeKind::NODE_ENUM && n.as_data.aggregate.generics.len == 0 && self.aggregate_has_payload(declId) {
            return true;
        }
        return false;
    }

    // The array-type node a function returns by value (`fn f() [T; N]`), else NODE_NONE.
    fn fn_array_return(self: &Self, fn_id: NodeId) NodeId {
        let rets = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.returns;
        if rets.len != 1 {
            return NODE_NONE;
        }
        let r0 = unsafe (*self.cur_ast()).list(rets)[0];
        let rn = unsafe (*self.cur_ast()).at_const(r0);
        let tn = if rn.kind == NodeKind::NODE_PARAMETER {
            rn.as_data.parameter.ty;
        } else {
            r0;
        };
        if unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_ARRAY_TYPE {
            return tn;
        }
        return NODE_NONE;
    }

    // Emit the `<name>_ret` struct backing a multi-return / array-by-value function.
    fn emit_ret_struct_named(self: &mut Self, fn_id: NodeId, nm: *const char) {
        let rets = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.returns;
        let arr = self.fn_array_return(fn_id);
        if arr != NODE_NONE {
            let mut d = Buf256 {};
            self.render_type_node(arr, "_".ptr() as *const char, &mut d[0], 256);
            self.buf.format_into("typedef struct {{ {}; }} {}_ret;\n", diag::cstr(&d[0]), diag::cstr(nm));
            return;
        }
        if rets.len <= 1 {
            return;
        }
        self.emit_str("typedef struct { ");
        for i in 0..rets.len {
            let rid = unsafe (*self.cur_ast()).list(rets)[i as usize];
            let rn = unsafe (*self.cur_ast()).at_const(rid);
            let tn = if rn.kind == NodeKind::NODE_PARAMETER {
                rn.as_data.parameter.ty;
            } else {
                rid;
            };
            let mut fld = Buf32 {};
            unsafe stdio::snprintf(&mut fld[0], 16, "_%u".ptr() as *const char, i);
            let mut d = Buf256 {};
            self.render_type_node(tn, &fld[0], &mut d[0], 256);
            self.emit_cstr(&d[0]);
            self.emit_str("; ");
        }
        self.buf.format_into("}} {}_ret;\n", diag::cstr(nm));
    }

    fn emit_ret_struct(self: &mut Self, fn_id: NodeId, target: DefId) {
        let rets = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.returns;
        if rets.len <= 1 && self.fn_array_return(fn_id) == NODE_NONE {
            return;
        }
        let mut nm = Buf256 {};
        self.function_name(fn_id, target, &mut nm[0], 256, true);
        self.emit_ret_struct_named(fn_id, &nm[0]);
    }

    // The number of `from`/`try_from` methods across all extends targeting (tmod,tdecl).
    fn cg_conv_count(self: &Self, tmod: ModuleId, tdecl: NodeId, lit: *const char) i32 {
        let mut n: i32 = 0;
        let cur = self.cur_module();
        let ns = if tmod == cur {
            1;
        } else {
            2;
        };
        for s in 0..ns {
            let m = if s == 0 {
                tmod;
            } else {
                cur;
            };
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*a).list(items)[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND || it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tg.module != tmod || tg.node != tdecl {
                    continue;
                }
                let ms = it.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe (*a).list(ms)[j as usize];
                    let mn = unsafe (*a).at_const(mid);
                    if mn.kind == NodeKind::NODE_FUNCTION && span_is(
                        self.mod_src(m),
                        unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text,
                        lit,
                    ) {
                        n = n + 1;
                    }
                }
            }
        }
        return n;
    }

    fn cg_conv_suffix(self: &mut Self, target: DefId, lit: *const char, srcTy: TypeId, out: *mut char, cap: usize) {
        if cap != 0 {
            unsafe out[0] = 0 as char;
        }
        if target.node == NODE_NONE || srcTy == TYPE_NONE || lit == null || self.cg_conv_count(
            target.module,
            target.node,
            lit,
        ) < 2 {
            return;
        }
        let at = bappend(out, cap, 0, "__".ptr() as *const char);
        let mut e = Buf176 {};
        self.mangle_type(self.subst_resolve(srcTy), &mut e[0], 176);
        bappend(out, cap, at, &e[0]);
    }

    // "void" / "T0 p0, T1 p1" — a function's C parameter list.
    fn render_params(self: &mut Self, params: NodeList, out: *mut char, cap: usize) {
        let ids = unsafe (*self.cur_ast()).list(params);
        let mut k: usize = 0;
        unsafe out[0] = 0 as char;
        let mut any = false;
        let mut i: u32 = 0;
        while i < params.len && k < cap {
            let pid = unsafe ids[i as usize];
            if pid == self.cb_param {
                i = i + 1;
                continue;
            }
            let p = unsafe (*self.cur_ast()).at_const(pid).as_data.parameter;
            let mut nm = Buf128 {};
            self.render_ident(unsafe (*self.cur_ast()).at_const(p.name).as_data.name.text, &mut nm[0], 128);
            if nm[0] == '_' as char && nm[1] == 0 as char {
                unsafe stdio::snprintf(&mut nm[0], 128, "__sc_u%u".ptr() as *const char, pid);
            }
            let pty = unsafe (*self.cur_ast()).type_of(pid);
            let pconst = !p.is_mutable && !self.cg_type_is_free(pty);
            let mut d = Buf300 {};
            if p.ty == NODE_NONE {
                self.render_type_id(self.subst_resolve(pty), &nm[0], &mut d[0], 300);
            } else {
                self.render_binding_node(p.ty, &nm[0], pconst, &mut d[0], 300);
            }
            if any {
                k = bappend(out, cap, k, ", ".ptr() as *const char);
            }
            k = bappend(out, cap, k, &d[0]);
            any = true;
            i = i + 1;
        }
        if !any {
            buf_join3(out, cap, "void".ptr() as *const char, "".ptr() as *const char, "".ptr() as *const char);
        }
    }

    // Build a function's C name.
    fn function_name(self: &mut Self, fn_id: NodeId, target: DefId, out: *mut char, cap: usize, prefixed: bool) {
        if self.cg_symbol_override(self.cur_module(), fn_id, out, cap) {
            return;
        }
        let fname = self.name_span(unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.name);
        let is_main = target.node == NODE_NONE && span_is(self.source, fname, "main".ptr() as *const char);
        let mut k: usize = 0;
        if prefixed && !is_main {
            k = self.render_modpfx(self.cur_module(), out, cap);
        }
        if k >= cap {
            if cap != 0 {
                k = cap - 1;
            } else {
                k = 0;
            }
        }
        if target.node != NODE_NONE {
            let mut bb: i32 = -1;
            if self.package != null {
                bb = unsafe (*self.package).builtin_of_decl(target.module, target.node);
            }
            if bb >= 0 {
                k = bappend(out, cap, k, builtin_name(bb as BuiltinType));
            } else {
                let ts = self.name_span_in(target.module, self.cg_decl_name_node(target.module, target.node));
                k = k + render_ident_src(self.mod_src(target.module), ts, unsafe (out + k), cap - k);
            }
            if k + 2 < cap {
                unsafe out[k] = '_' as char;
                unsafe out[k + 1] = '_' as char;
                k = k + 2;
            }
        }
        k = k + self.render_ident(fname, unsafe (out + k), cap - k);
        let params = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.params;
        let lit = self.cg_conv_lit(self.cur_module(), fname);
        if lit != null && target.node != NODE_NONE && params.len != 0 {
            let p0 = unsafe (*self.cur_ast()).list(params)[0];
            let p0ty = unsafe (*self.cur_ast()).type_of(unsafe (*self.cur_ast()).at_const(p0).as_data.parameter.ty);
            self.cg_conv_suffix(target, lit, p0ty, unsafe (out + k), cap - k);
        }
    }

    // Does the subtree rooted at `id` reference parameter `param` (a NODE_PARAMETER of the current module)?
    fn cg_subtree_uses(self: &Self, id: NodeId, param: NodeId) bool {
        let mut used0 = false;
        let mut left0: i32 = 1;
        self.cg_subtree_uses_multi(id, &param, 1, &mut used0, &mut left0);
        return used0;
    }
    // The same traversal answering "is this decl referenced" for np params in ONE body walk
    // (emit_function used to re-walk the body once per parameter). Marks used[j] per match;
    // the bool result means "every param found -- stop descending".
    fn cg_subtree_uses_multi(self: &Self, id: NodeId, pids: *const NodeId, np: i32, used: *mut bool, left: *mut i32) bool {
        if unsafe *left == 0 {
            return true;
        }
        if id == NODE_NONE {
            return false;
        }
        let n = unsafe (*self.cur_ast()).at_const(id);
        let k = n.kind;
        if k == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(id);
            if d.module == self.cur_module() {
                let mut j: i32 = 0;
                while j < np {
                    if unsafe pids[j as usize] == d.node && !unsafe used[j as usize] {
                        unsafe used[j as usize] = true;
                        unsafe {
                            *left = *left - 1;
                        }
                    }
                    j += 1;
                }
            }
            return unsafe *left == 0;
        }
        if k == NodeKind::NODE_BLOCK {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.block.statements);
            for i in 0..n.as_data.block.statements.len {
                if self.cg_subtree_uses_multi(unsafe ids[i as usize], pids, np, used, left) {
                    return true;
                }
            }
            return false;
        }
        if k == NodeKind::NODE_LET {
            return self.cg_subtree_uses_multi(n.as_data.let_stmt.value, pids, np, used, left);
        }
        if k == NodeKind::NODE_RETURN {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.return_stmt.values);
            for i in 0..n.as_data.return_stmt.values.len {
                if self.cg_subtree_uses_multi(unsafe ids[i as usize], pids, np, used, left) {
                    return true;
                }
            }
            return false;
        }
        if k == NodeKind::NODE_DEFER || k == NodeKind::NODE_EXPRESSION_STATEMENT {
            return self.cg_subtree_uses_multi(n.as_data.single.value, pids, np, used, left);
        }
        if k == NodeKind::NODE_IF {
            if self.cg_subtree_uses_multi(n.as_data.if_stmt.condition, pids, np, used, left) {
                return true;
            }
            if self.cg_subtree_uses_multi(n.as_data.if_stmt.then_branch, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.if_stmt.else_branch, pids, np, used, left);
        }
        if k == NodeKind::NODE_WHILE {
            if self.cg_subtree_uses_multi(n.as_data.while_stmt.condition, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.while_stmt.body, pids, np, used, left);
        }
        if k == NodeKind::NODE_FOR {
            if self.cg_subtree_uses_multi(n.as_data.for_stmt.iterable, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.for_stmt.body, pids, np, used, left);
        }
        if k == NodeKind::NODE_MATCH {
            if self.cg_subtree_uses_multi(n.as_data.match_expr.value, pids, np, used, left) {
                return true;
            }
            let ids = unsafe (*self.cur_ast()).list(n.as_data.match_expr.arms);
            for i in 0..n.as_data.match_expr.arms.len {
                let arm = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]);
                if self.cg_subtree_uses_multi(arm.as_data.match_arm.guard, pids, np, used, left) {
                    return true;
                }
                if self.cg_subtree_uses_multi(arm.as_data.match_arm.body, pids, np, used, left) {
                    return true;
                }
            }
            return false;
        }
        if k == NodeKind::NODE_ASSIGNMENT || k == NodeKind::NODE_BINARY {
            if self.cg_subtree_uses_multi(n.as_data.binary.left, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.binary.right, pids, np, used, left);
        }
        if k == NodeKind::NODE_UNARY {
            return self.cg_subtree_uses_multi(n.as_data.unary.operand, pids, np, used, left);
        }
        if k == NodeKind::NODE_CALL {
            if self.cg_subtree_uses_multi(n.as_data.call.callee, pids, np, used, left) {
                return true;
            }
            let ids = unsafe (*self.cur_ast()).list(n.as_data.call.args);
            for i in 0..n.as_data.call.args.len {
                if self.cg_subtree_uses_multi(unsafe ids[i as usize], pids, np, used, left) {
                    return true;
                }
            }
            return false;
        }
        if k == NodeKind::NODE_INDEX {
            if self.cg_subtree_uses_multi(n.as_data.index.object, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.index.index, pids, np, used, left);
        }
        if k == NodeKind::NODE_MEMBER {
            return self.cg_subtree_uses_multi(n.as_data.member.object, pids, np, used, left);
        }
        if k == NodeKind::NODE_CAST {
            return self.cg_subtree_uses_multi(n.as_data.cast.expression, pids, np, used, left);
        }
        if k == NodeKind::NODE_GENERIC_SPECIALIZATION {
            return self.cg_subtree_uses_multi(n.as_data.specialization.expression, pids, np, used, left);
        }
        if k == NodeKind::NODE_NEW {
            return self.cg_subtree_uses_multi(n.as_data.new_expr.initializer, pids, np, used, left);
        }
        if k == NodeKind::NODE_VA_EXPR {
            if self.cg_subtree_uses_multi(n.as_data.va_op.ap, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.va_op.extra, pids, np, used, left);
        }
        if k == NodeKind::NODE_ARRAY_LITERAL {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.array_literal.elements);
            for i in 0..n.as_data.array_literal.elements.len {
                if self.cg_subtree_uses_multi(unsafe ids[i as usize], pids, np, used, left) {
                    return true;
                }
            }
            return false;
        }
        if k == NodeKind::NODE_STRUCT_INITIALIZER {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.struct_initializer.fields);
            for i in 0..n.as_data.struct_initializer.fields.len {
                let fv = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.field_initializer.value;
                if self.cg_subtree_uses_multi(fv, pids, np, used, left) {
                    return true;
                }
            }
            return false;
        }
        if k == NodeKind::NODE_CLOSURE {
            return self.cg_subtree_uses_multi(n.as_data.closure.body, pids, np, used, left);
        }
        if k == NodeKind::NODE_RANGE {
            if self.cg_subtree_uses_multi(n.as_data.pattern_range.start, pids, np, used, left) {
                return true;
            }
            return self.cg_subtree_uses_multi(n.as_data.pattern_range.end, pids, np, used, left);
        }
        return false;
    }
}

fn addg(g: *mut char, cap: usize, gn: usize, s: *const char) usize {
    let mut at = gn;
    if at != 0 {
        at = bappend(g, cap, at, ", ".ptr() as *const char);
    }
    return bappend(g, cap, at, s);
}

extend Codegen {
    fn cg_is_prelude_decl(self: &Self, t: TypeId, name: str) bool {
        if self.package == null {
            return false;
        }
        let hit = unsafe (*self.package).prelude_lookup(name, true);
        if hit.node == NODE_NONE {
            return false;
        }
        let y = self.type_at(t);
        return y.kind == TypeKind::TYPE_STRUCT && y.module == hit.mid && y.as_data.decl == hit.node;
    }
    fn cg_main_argv_vector(self: &Self, params: NodeList) bool {
        if params.len != 1 || self.package == null {
            return false;
        }
        let ids = unsafe (*self.cur_ast()).list(params);
        let argv = self.type_at(unsafe (*self.cur_ast()).type_of(unsafe ids[0]));
        if argv.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let hit = unsafe (*self.package).prelude_lookup("Vector", true);
        if hit.node == NODE_NONE {
            return false;
        }
        let it = unsafe (*self.cur_ast()).instance(argv.as_data.inst);
        return it.module == hit.mid && it.decl == hit.node && it.n >= 1 && self.cg_is_prelude_decl(it.args[0], "str");
    }
    fn emit_main_argv_wrapper(self: &mut Self, params: NodeList) {
        let ids = unsafe (*self.cur_ast()).list(params);
        let ty = unsafe (*self.cur_ast()).type_of(unsafe ids[0]);
        let mut vec = Buf256 {};
        self.render_type_id(ty, "".ptr() as *const char, &mut vec[0], 256);
        self.buf.format_into(
            "\nstatic {} __sc_argv_to_vector(int argc, char **argv) {{\n  {} out = ({}){{0}};\n  if (argc > 0) {{\n    out.alloc = (Global){{}};\n    out.ptr = (str *)Global__alloc(&out.alloc, sizeof(str) * (size_t)argc, _Alignof(str));\n    out.len = (size_t)argc;\n    out.cap = (size_t)argc;\n    for (int i = 0; i < argc; i++) {{ out.ptr[i] = str__from_cstr(argv[i]); }}\n  }}\n  return out;\n}}\n\nint main(int argc, char **argv) {{\n  return __sc_user_main(__sc_argv_to_vector(argc, argv));\n}}\n\n",
            diag::cstr(&vec[0]),
            diag::cstr(&vec[0]),
            diag::cstr(&vec[0]),
        );
    }

    // Emit a function signature; with_body emits the block, otherwise a prototype `;`.
    fn emit_function(
        self: &mut Self,
        fn_id: NodeId,
        target: DefId,
        extern_q: bool,
        with_body: bool,
        name_override: *const char,
        spec_static: bool,
    ) {
        let f = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function;
        let mut nm = Buf256 {};
        if name_override != null {
            bappend(&mut nm[0], 256, 0, name_override);
        } else {
            self.function_name(fn_id, target, &mut nm[0], 256, !extern_q);
        }
        let is_main = target.node == NODE_NONE && name_override == null && span_is(
            self.source,
            self.name_span(f.name),
            "main".ptr() as *const char,
        );
        let main_argv_vector = is_main && self.cg_main_argv_vector(f.params);
        if main_argv_vector {
            bappend(&mut nm[0], 256, 0, "__sc_user_main".ptr() as *const char);
        }
        let exported = self.cg_attr(self.cur_module(), fn_id, AttrKind::ATTR_EXPORT) != null;
        let is_static = if name_override != null {
            spec_static;
        } else {
            self.multifile && !extern_q && !is_main && !exported && !f.is_public;
        };
        let mut ps = Buf1024 {};
        self.render_params(f.params, &mut ps[0], 1024);
        if f.is_variadic && unsafe cstring::strcmp(&ps[0], "void".ptr() as *const char) != 0 {
            let psl = unsafe cstring::strlen(&ps[0]);
            bappend(&mut ps[0], 1024, psl, ", ...".ptr() as *const char);
        }
        let mut decl = Buf1320 {};
        let mut at: usize = 0;
        decl[0] = 0 as char;
        if extern_q {
            at = bappend(&mut decl[0], 1320, at, "(".ptr() as *const char);
        }
        at = bappend(&mut decl[0], 1320, at, &nm[0]);
        if extern_q {
            at = bappend(&mut decl[0], 1320, at, ")".ptr() as *const char);
        }
        at = bappend(&mut decl[0], 1320, at, "(".ptr() as *const char);
        at = bappend(&mut decl[0], 1320, at, &ps[0]);
        bappend(&mut decl[0], 1320, at, ")".ptr() as *const char);

        if extern_q {
            self.emit_str("extern ");
        }
        if is_static {
            self.emit_str("static ");
        }

        let fmod = self.cur_module();
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_NORETURN) != null {
            self.emit_str("_Noreturn ");
        }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_INLINE) != null || self.cg_attr(
            fmod,
            fn_id,
            AttrKind::ATTR_ALWAYS_INLINE,
        ) != null {
            self.emit_str("inline ");
        }
        let mut g = Buf256 {};
        g[0] = 0 as char;
        let mut gn: usize = 0;
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_ALWAYS_INLINE) != null {
            gn = addg(&mut g[0], 256, gn, "always_inline".ptr() as *const char);
        }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_NOINLINE) != null {
            gn = addg(&mut g[0], 256, gn, "noinline".ptr() as *const char);
        }
        // @c.cold: mark rare/error paths cold + noinline (bundled, mirroring the reference C `COLD` macro) so
        // the optimizer keeps them out of the hot path's I-cache and predicts their branches as unlikely.
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_COLD) != null {
            gn = addg(&mut g[0], 256, gn, "cold".ptr() as *const char);
            if self.cg_attr(fmod, fn_id, AttrKind::ATTR_NOINLINE) == null {
                gn = addg(&mut g[0], 256, gn, "noinline".ptr() as *const char);
            }
        }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_USED) != null {
            gn = addg(&mut g[0], 256, gn, "used".ptr() as *const char);
        }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_UNUSED) != null {
            gn = addg(&mut g[0], 256, gn, "unused".ptr() as *const char);
        }
        if is_static && self.cg_attr(fmod, fn_id, AttrKind::ATTR_USED) == null {
            gn = addg(&mut g[0], 256, gn, "unused".ptr() as *const char);
        }
        let sec = self.cg_attr(fmod, fn_id, AttrKind::ATTR_SECTION);
        if sec != null {
            let sp = unsafe (*sec).str_span;
            let mut nl = (sp.end - sp.start) as usize;
            if nl >= 128 {
                nl = 127;
            }
            let mut nm2 = Buf128 {};
            unsafe cstring::memcpy(&mut nm2[0], self.mod_src(fmod).ptr() + sp.start as usize, nl);
            nm2[nl] = 0 as char;
            let mut sb = Buf160 {};
            unsafe stdio::snprintf(&mut sb[0], 160, "section(\"%s\")".ptr() as *const char, &nm2[0]);
            gn = addg(&mut g[0], 256, gn, &sb[0]);
        }
        if gn != 0 {
            self.buf.format_into("__attribute__(({})) ", diag::cstr(&g[0]));
        }

        let rets = f.returns;
        unsafe self.current_ret[0] = 0 as char;
        self.current_fn_ret_node = NODE_NONE;
        if target.node == NODE_NONE && !extern_q && span_is(
            self.source,
            self.name_span(f.name),
            "main".ptr() as *const char,
        ) {
            self.buf.format_into("int {}", diag::cstr(&decl[0]));
        } else if rets.len > 1 {
            buf_join3(&mut self.current_ret[0], 128, &nm[0], "".ptr() as *const char, "_ret".ptr() as *const char);
            let cr = (&self.current_ret[0]) as *const char;
            self.emit_cstr(cr);
            self.emit_str(" ");
            self.emit_cstr(&decl[0]);
        } else if self.fn_array_return(fn_id) != NODE_NONE {
            buf_join3(&mut self.current_ret[0], 128, &nm[0], "".ptr() as *const char, "_ret".ptr() as *const char);
            let cr = (&self.current_ret[0]) as *const char;
            self.emit_cstr(cr);
            self.emit_str(" ");
            self.emit_cstr(&decl[0]);
        } else if rets.len == 1 {
            let r0 = unsafe (*self.cur_ast()).list(rets)[0];
            let rn = unsafe (*self.cur_ast()).at_const(r0);
            self.current_fn_ret_node = if rn.kind == NodeKind::NODE_PARAMETER {
                rn.as_data.parameter.ty;
            } else {
                r0;
            };
            let mut out = Buf1400 {};
            self.render_type_node(self.current_fn_ret_node, &decl[0], &mut out[0], 1400);
            self.emit_cstr(&out[0]);
        } else {
            self.emit_str("void ");
            self.emit_cstr(&decl[0]);
        }

        if with_body && f.body != NODE_NONE {
            self.emit_str(" ");
            self.defer_top = 0;
            self.loop_defer_base = 0;
            self.nmoved = 0;
            self.ncond_moved = 0;
            self.ncond_sites = 0;
            self.cg_move_stamps_reset();
            self.pend_moves.clear();
            self.cg_scan_moves(f.body, false);
            self.cg_replay_cond_moves();
            let pids = unsafe (*self.cur_ast()).list(f.params);
            self.nparam_flags = 0;
            self.nunused_params = 0;
            // One body walk answers "is this param used" for every parameter at once.
            let mut upids = Ids64 {};
            let mut uarr = Bools64 {};
            let mut np: i32 = 0;
            while np < 64 && np as u32 < f.params.len {
                upids[np as usize] = unsafe pids[np as usize];
                np += 1;
            }
            let mut uleft = np;
            if np > 0 {
                self.cg_subtree_uses_multi(f.body, &upids[0], np, &mut uarr[0], &mut uleft);
            }
            for i in 0..f.params.len {
                let pid = unsafe pids[i as usize];
                let pused = if i < 64 {
                    uarr[i as usize];
                } else {
                    self.cg_subtree_uses(f.body, pid);
                };
                if self.cg_will_auto_free(pid) {
                    self.cg_register_auto_free(pid);
                    if self.cg_is_cond_moved(pid) && self.nparam_flags < 32 {
                        self.param_flags[self.nparam_flags as usize] = pid;
                        self.nparam_flags = self.nparam_flags + 1;
                    }
                } else if !pused && self.nunused_params < 32 {
                    self.unused_params[self.nunused_params as usize] = pid;
                    self.nunused_params = self.nunused_params + 1;
                }
            }
            self.emit_block_from(f.body, 0);
            self.emit_str("\n\n");
            if main_argv_vector {
                self.emit_main_argv_wrapper(f.params);
            }
        } else {
            self.emit_str(";\n");
        }
    }
}

// ---- backend stubs: filled in below, kept as at-least-decls so the whole file compiles green ----
extend Codegen {
    fn cg_is_format_builtin(self: &Self, m: ModuleId, node: NodeId) bool {
        if self.package == null || m as usize >= self.pkg_count() || !unsafe (*self.package).modules[m as usize].prelude {
            return false;
        }
        let a = self.mod_ast(m);
        if unsafe (*a).at_const(node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let fnm = unsafe (*a).at_const(unsafe (*a).at_const(node).as_data.function.name).as_data.name.text;
        let s = self.mod_src(m);
        return span_is(s, fnm, "format".ptr() as *const char) || span_is(s, fnm, "format_into".ptr() as *const char) || span_is(
            s,
            fnm,
            "print".ptr() as *const char,
        ) || span_is(s, fnm, "println".ptr() as *const char) || span_is(s, fnm, "eprint".ptr() as *const char) || span_is(
            s,
            fnm,
            "eprintln".ptr() as *const char,
        ) || span_is(s, fnm, "assert".ptr() as *const char) || span_is(s, fnm, "assert_eq".ptr() as *const char) || span_is(
            s,
            fnm,
            "assert_ne".ptr() as *const char,
        );
    }

    fn cg_type_mentions_fnval(self: &Self, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_FUNCTION {
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.cg_type_mentions_fnval(y.as_data.elem);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            for i in 0..it.n {
                if self.cg_type_mentions_fnval(it.args[i as usize]) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }
    fn inst_mentions_fnval(self: &Self, it: &TyInstance) bool {
        for i in 0..it.n {
            if self.cg_type_mentions_fnval(it.args[i as usize]) {
                return true;
            }
        }
        return false;
    }

    fn cg_test_skip(self: &Self, fn2: NodeId, method: bool) bool {
        if self.test.enabled {
            let f = unsafe (*self.cur_ast()).at_const(fn2);
            return !method && f.kind == NodeKind::NODE_FUNCTION && span_is(
                self.source,
                unsafe (*self.cur_ast()).at_const(f.as_data.function.name).as_data.name.text,
                "main".ptr() as *const char,
            );
        }
        return self.cg_attr(self.cur_module(), fn2, AttrKind::ATTR_TEST) != null || self.cg_attr(
            self.cur_module(),
            fn2,
            AttrKind::ATTR_TEST_INIT,
        ) != null || self.cg_attr(self.cur_module(), fn2, AttrKind::ATTR_TEST_FREE) != null;
    }

    fn emit_enum_full(self: &mut Self, enum_id: NodeId) {
        let ag = unsafe (*self.cur_ast()).at_const(enum_id).as_data.aggregate;
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), ag.name, &mut nm[0], 160);
        self.buf.format_into("#ifndef SUPER_ENUM_{}\n#define SUPER_ENUM_{}\n", diag::cstr(&nm[0]), diag::cstr(&nm[0]));
        self.emit_str("typedef enum { ");
        let ms = ag.members;
        for j in 0..ms.len {
            if j != 0 {
                self.emit_str(", ");
            }
            let mid = unsafe (*self.cur_ast()).list(ms)[j as usize];
            self.emit_tag(enum_id, mid);
            let disc = unsafe (*self.cur_ast()).at_const(mid).as_data.variant.value;
            if disc != NODE_NONE {
                self.emit_str(" = ");
                let sc = self.const_ctx;
                self.const_ctx = true;
                self.emit_expr(disc);
                self.const_ctx = sc;
            }
        }
        self.emit_str(" } ");
        self.emit_local_type_name(ag.name);
        self.emit_str(";\n#endif\n");
    }
    fn emit_enum_tag_decl(self: &mut Self, enum_id: NodeId) {
        let ag = unsafe (*self.cur_ast()).at_const(enum_id).as_data.aggregate;
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), ag.name, &mut nm[0], 160);
        self.buf.format_into(
            "#ifndef SUPER_ENUMTAG_{}\n#define SUPER_ENUMTAG_{}\n",
            diag::cstr(&nm[0]),
            diag::cstr(&nm[0]),
        );
        self.emit_str("typedef enum { ");
        let ms = ag.members;
        for j in 0..ms.len {
            if j != 0 {
                self.emit_str(", ");
            }
            let mid = unsafe (*self.cur_ast()).list(ms)[j as usize];
            self.emit_tag(enum_id, mid);
            let disc = unsafe (*self.cur_ast()).at_const(mid).as_data.variant.value;
            if disc != NODE_NONE {
                self.emit_str(" = ");
                let sc = self.const_ctx;
                self.const_ctx = true;
                self.emit_expr(disc);
                self.const_ctx = sc;
            }
        }
        self.emit_str(" } ");
        self.emit_local_type_name(ag.name);
        self.emit_str("Tag;\n#endif\n");
    }
    fn emit_enum_struct_body(self: &mut Self, dn_id: NodeId) {
        let ag = unsafe (*self.cur_ast()).at_const(dn_id).as_data.aggregate;
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_local_type_name(ag.name);
        self.emit_str("Tag tag;\n");
        self.emit_indent();
        self.emit_str("union {\n");
        self.depth = self.depth + 1;
        let ms = ag.members;
        for j in 0..ms.len {
            let mid = unsafe (*self.cur_ast()).list(ms)[j as usize];
            let v = unsafe (*self.cur_ast()).at_const(mid).as_data.variant;
            let payload = v.payload;
            if payload.len == 0 {
                continue;
            }
            self.emit_indent();
            self.emit_str("struct { ");
            for k in 0..payload.len {
                let pid = unsafe (*self.cur_ast()).list(payload)[k as usize];
                let pe = unsafe (*self.cur_ast()).at_const(pid);
                let mut d = Buf256 {};
                if v.struct_payload {
                    let mut m = Buf128 {};
                    let msp = self.name_span(pe.as_data.field.name);
                    self.render_ident(msp, &mut m[0], 128);
                    self.render_type_node(pe.as_data.field.ty, &m[0], &mut d[0], 256);
                } else {
                    let mut fld = Buf32 {};
                    unsafe stdio::snprintf(&mut fld[0], 24, "_%u".ptr() as *const char, k);
                    self.render_type_node(pid, &fld[0], &mut d[0], 256);
                }
                self.emit_cstr(&d[0]);
                self.emit_str("; ");
            }
            self.emit_str("} ");
            let vsp = self.name_span(v.name);
            self.emit_span(vsp);
            self.emit_str(";\n");
        }
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_str("} payload;\n");
        self.depth = self.depth - 1;
    }
    fn emit_type_decl(self: &mut Self, declId: NodeId) {
        let ag = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate;
        let kind = unsafe (*self.cur_ast()).at_const(declId).kind;
        let kw = agg_kw(unsafe (*self.cur_ast()).at_const(declId));
        self.buf.format_into("{} ", diag::cstr(kw));
        let pk = self.cg_attr(self.cur_module(), declId, AttrKind::ATTR_PACKED);
        let al = self.cg_attr(self.cur_module(), declId, AttrKind::ATTR_ALIGN);
        if pk != null || al != null {
            let mut g = Buf64 {};
            g[0] = 0 as char;
            let mut gn: usize = 0;
            if pk != null {
                gn = bappend(&mut g[0], 64, gn, "packed".ptr() as *const char);
            }
            if al != null {
                if gn != 0 {
                    gn = bappend(&mut g[0], 64, gn, ", ".ptr() as *const char);
                }
                let mut a = Buf32 {};
                unsafe stdio::snprintf(&mut a[0], 32, "aligned(%u)".ptr() as *const char, unsafe (*al).arg);
                bappend(&mut g[0], 64, gn, &a[0]);
            }
            self.buf.format_into("__attribute__(({})) ", diag::cstr(&g[0]));
        }
        self.emit_local_type_name(ag.name);
        self.emit_str(" {\n");
        if kind == NodeKind::NODE_ENUM {
            self.emit_enum_struct_body(declId);
        } else if ag.is_tuple {
            self.depth = self.depth + 1;
            for j in 0..ag.members.len {
                let ftn = unsafe (*self.cur_ast()).list(ag.members)[j as usize];
                let mut nm = Buf32 {};
                unsafe stdio::snprintf(&mut nm[0], 16, "_%u".ptr() as *const char, j);
                let mut d = Buf256 {};
                self.render_type_node(ftn, &nm[0], &mut d[0], 256);
                self.emit_indent();
                self.emit_cstr(&d[0]);
                self.emit_str(";\n");
            }
            self.depth = self.depth - 1;
        } else {
            self.depth = self.depth + 1;
            for j in 0..ag.members.len {
                let fid = unsafe (*self.cur_ast()).list(ag.members)[j as usize];
                let fld = unsafe (*self.cur_ast()).at_const(fid).as_data.field;
                let mut nm = Buf128 {};
                let fnsp = self.name_span(fld.name);
                self.render_ident(fnsp, &mut nm[0], 128);
                let mut d = Buf256 {};
                self.render_type_node(fld.ty, &nm[0], &mut d[0], 256);
                self.emit_indent();
                self.emit_cstr(&d[0]);
                self.emit_str(";\n");
            }
            self.depth = self.depth - 1;
        }
        self.emit_str("};\n");
    }
    fn emit_struct_inst(self: &mut Self, it: &TyInstance, with_body: bool) {
        let kw = agg_kw(unsafe (*self.cur_ast()).at_const(it.decl));
        let mut nm = Buf200 {};
        self.inst_name(it, &mut nm[0], 200);
        if !with_body {
            self.buf.format_into("typedef {} {} {};\n", diag::cstr(kw), diag::cstr(&nm[0]), diag::cstr(&nm[0]));
            return;
        }
        if self.inst_mentions_fnval(it) != self.fnval_pass {
            return;
        }
        let ag = unsafe (*self.cur_ast()).at_const(it.decl).as_data.aggregate;
        let gids = unsafe (*self.cur_ast()).list(ag.generics);
        self.nsubst = 0;
        let mut i: u32 = 0;
        while i < ag.generics.len && i < it.n as u32 && self.nsubst < 16 {
            self.subst[self.nsubst as usize].param = DefId { module: it.module, node: unsafe gids[i as usize] };
            self.subst[self.nsubst as usize].concrete = it.args[i as usize];
            self.nsubst = self.nsubst + 1;
            i = i + 1;
        }
        self.buf.format_into("{} {} {{\n", diag::cstr(kw), diag::cstr(&nm[0]));
        self.depth = self.depth + 1;
        for j in 0..ag.members.len {
            let fid = unsafe (*self.cur_ast()).list(ag.members)[j as usize];
            let fld = unsafe (*self.cur_ast()).at_const(fid).as_data.field;
            let mut fnm = Buf128 {};
            let fnsp = self.name_span(fld.name);
            self.render_ident(fnsp, &mut fnm[0], 128);
            let mut d = Buf256 {};
            self.render_type_node(fld.ty, &fnm[0], &mut d[0], 256);
            self.emit_indent();
            self.emit_cstr(&d[0]);
            self.emit_str(";\n");
        }
        self.depth = self.depth - 1;
        self.emit_str("};\n");
        self.nsubst = 0;
    }
    fn emit_enum_inst(self: &mut Self, it: &TyInstance, with_body: bool) {
        let mut nm = Buf200 {};
        self.inst_name(it, &mut nm[0], 200);
        let ag = unsafe (*self.cur_ast()).at_const(it.decl).as_data.aggregate;
        if !self.aggregate_has_payload(it.decl) {
            if with_body {
                self.emit_str("typedef ");
                self.emit_local_type_name(ag.name);
                self.buf.format_into(" {};\n", diag::cstr(&nm[0]));
            }
            return;
        }
        if !with_body {
            self.buf.format_into("typedef struct {} {};\n", diag::cstr(&nm[0]), diag::cstr(&nm[0]));
            return;
        }
        if self.inst_mentions_fnval(it) != self.fnval_pass {
            return;
        }
        let gids = unsafe (*self.cur_ast()).list(ag.generics);
        self.nsubst = 0;
        let mut i: u32 = 0;
        while i < ag.generics.len && i < it.n as u32 && self.nsubst < 16 {
            self.subst[self.nsubst as usize].param = DefId { module: it.module, node: unsafe gids[i as usize] };
            self.subst[self.nsubst as usize].concrete = it.args[i as usize];
            self.nsubst = self.nsubst + 1;
            i = i + 1;
        }
        self.buf.format_into("struct {} {{\n", diag::cstr(&nm[0]));
        self.emit_enum_struct_body(it.decl);
        self.emit_str("};\n");
        self.nsubst = 0;
    }
    fn emit_generic_enum_shared(self: &mut Self) {
        let mut seen = Ids64 {};
        let mut ns: i32 = 0;
        for i in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(i as u32);
            if it.module != self.cur_module() {
                continue;
            }
            if unsafe (*self.cur_ast()).at_const(it.decl).kind != NodeKind::NODE_ENUM {
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                continue;
            }
            let mut dup = false;
            for s in 0..ns {
                if seen[s as usize] == it.decl {
                    dup = true;
                }
            }
            if dup {
                continue;
            }
            if ns < 64 {
                seen[ns as usize] = it.decl;
                ns = ns + 1;
            }
            if self.aggregate_has_payload(it.decl) {
                self.emit_enum_tag_decl(it.decl);
            } else {
                self.emit_enum_full(it.decl);
            }
        }
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for ii in 0..items.len {
            let did = unsafe ids[ii as usize];
            let dn = unsafe (*self.cur_ast()).at_const(did);
            if dn.kind != NodeKind::NODE_ENUM || dn.as_data.aggregate.generics.len == 0 || !dn.as_data.aggregate.is_public {
                continue;
            }
            let mut dup = false;
            for s in 0..ns {
                if seen[s as usize] == did {
                    dup = true;
                }
            }
            if dup {
                continue;
            }
            if ns < 64 {
                seen[ns as usize] = did;
                ns = ns + 1;
            }
            if self.aggregate_has_payload(did) {
                self.emit_enum_tag_decl(did);
            } else {
                self.emit_enum_full(did);
            }
        }
    }
    fn push_home_dep(self: &Self, st0: TypeId, deps: *mut TypeId, nh: *mut i32) {
        if unsafe *nh >= 32 || st0 == TYPE_NONE {
            return;
        }
        let mut st = st0;
        let mut y = *self.type_at(st);
        while y.kind == TypeKind::TYPE_ARRAY {
            st = y.as_data.elem;
            y = *self.type_at(st);
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM && y.kind != TypeKind::TYPE_INSTANCE {
            return;
        }
        for i in 0..unsafe *nh {
            if unsafe deps[i as usize] == st {
                return;
            }
        }
        let cur = unsafe *nh;
        unsafe deps[cur as usize] = st;
        unsafe *nh = cur + 1;
    }
    fn emit_home_dep(self: &mut Self, st: TypeId) {
        if st == TYPE_NONE {
            return;
        }
        let y = *self.type_at(st);
        if (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM) && y.module == self.cur_module() && self.type_state != null {
            if self.type_emittable(y.as_data.decl) {
                let ts = self.type_state;
                self.emit_type_dfs(y.as_data.decl, ts);
            }
        } else if y.kind == TypeKind::TYPE_INSTANCE && self.inst_emit_state != null {
            let ies = self.inst_emit_state;
            let ien = self.inst_emit_n;
            self.emit_inst_dfs(y.as_data.inst, ies, ien, true);
            self.emit_rehomed_struct_dfs(y.as_data.inst, ies, ien, true);
        }
    }
    fn emit_inst_dfs(self: &mut Self, idx: u32, state: *mut u8, nstate: usize, with_body: bool) {
        if idx as usize >= nstate || unsafe state[idx as usize] != 0 as u8 {
            return;
        }
        let it = *unsafe (*self.cur_ast()).instance(idx);
        let mut concrete = true;
        for k in 0..it.n {
            if !self.type_is_concrete(it.args[k as usize]) {
                concrete = false;
            }
        }
        if it.module != self.cur_module() || !concrete {
            return;
        }
        unsafe state[idx as usize] = 1;
        let ag = unsafe (*self.cur_ast()).at_const(it.decl).as_data.aggregate;
        let dk = unsafe (*self.cur_ast()).at_const(it.decl).kind;
        let mut deps = TyArgs32 {};
        let mut nh: i32 = 0;
        let gids = unsafe (*self.cur_ast()).list(ag.generics);
        let saved = self.nsubst;
        self.nsubst = 0;
        let mut g: u32 = 0;
        while g < ag.generics.len && g < it.n as u32 && self.nsubst < 16 {
            self.subst[self.nsubst as usize].param = DefId { module: it.module, node: unsafe gids[g as usize] };
            self.subst[self.nsubst as usize].concrete = it.args[g as usize];
            self.nsubst = self.nsubst + 1;
            g = g + 1;
        }
        let mids = unsafe (*self.cur_ast()).list(ag.members);
        for m in 0..ag.members.len {
            let mn = unsafe (*self.cur_ast()).at_const(unsafe mids[m as usize]);
            if dk == NodeKind::NODE_STRUCT && mn.kind == NodeKind::NODE_FIELD {
                let ft = self.subst_resolve(unsafe (*self.cur_ast()).type_of(mn.as_data.field.ty));
                self.push_home_dep(ft, &mut deps[0], &mut nh);
            } else if dk == NodeKind::NODE_ENUM && mn.kind == NodeKind::NODE_VARIANT {
                let pids = unsafe (*self.cur_ast()).list(mn.as_data.variant.payload);
                for kk in 0..mn.as_data.variant.payload.len {
                    let pf = unsafe (*self.cur_ast()).at_const(unsafe pids[kk as usize]);
                    let ptn = if pf.kind == NodeKind::NODE_FIELD {
                        pf.as_data.field.ty;
                    } else {
                        unsafe pids[kk as usize];
                    };
                    let ft = self.subst_resolve(unsafe (*self.cur_ast()).type_of(ptn));
                    self.push_home_dep(ft, &mut deps[0], &mut nh);
                }
            }
        }
        self.nsubst = saved;
        for d in 0..nh {
            self.emit_home_dep(deps[d as usize]);
        }
        if dk == NodeKind::NODE_STRUCT {
            self.emit_struct_inst(&it, with_body);
        } else if dk == NodeKind::NODE_ENUM {
            self.emit_enum_inst(&it, with_body);
        }
        unsafe state[idx as usize] = 2;
    }
    fn emit_type_dfs(self: &mut Self, declId: NodeId, state: *mut u8) {
        if unsafe state[declId as usize] != 0 as u8 {
            return;
        }
        unsafe state[declId as usize] = 1;
        let n_kind = unsafe (*self.cur_ast()).at_const(declId).kind;
        let members = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.members;
        let is_tuple = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.is_tuple;
        let mut deps = TyArgs32 {};
        let mut nh: i32 = 0;
        let mids = unsafe (*self.cur_ast()).list(members);
        for i in 0..members.len {
            let m = unsafe (*self.cur_ast()).at_const(unsafe mids[i as usize]);
            if n_kind == NodeKind::NODE_STRUCT && is_tuple {
                self.push_home_dep(unsafe (*self.cur_ast()).type_of(unsafe mids[i as usize]), &mut deps[0], &mut nh);
            } else if n_kind == NodeKind::NODE_STRUCT && m.kind == NodeKind::NODE_FIELD {
                self.push_home_dep(unsafe (*self.cur_ast()).type_of(m.as_data.field.ty), &mut deps[0], &mut nh);
            } else if n_kind == NodeKind::NODE_ENUM && m.kind == NodeKind::NODE_VARIANT {
                let plids = unsafe (*self.cur_ast()).list(m.as_data.variant.payload);
                for kk in 0..m.as_data.variant.payload.len {
                    let pf = unsafe (*self.cur_ast()).at_const(unsafe plids[kk as usize]);
                    let ptn = if pf.kind == NodeKind::NODE_FIELD {
                        pf.as_data.field.ty;
                    } else {
                        unsafe plids[kk as usize];
                    };
                    self.push_home_dep(unsafe (*self.cur_ast()).type_of(ptn), &mut deps[0], &mut nh);
                }
            }
        }
        for d in 0..nh {
            self.emit_home_dep(deps[d as usize]);
        }
        self.emit_type_decl(declId);
        unsafe state[declId as usize] = 2;
    }
    fn cg_type_state(self: &mut Self) *mut u8 {
        if self.type_state == null {
            self.type_state = (unsafe stdlib::calloc(unsafe (*self.cur_ast()).nodes.len(), 1)) as *mut u8;
        }
        return self.type_state;
    }
    fn emit_agg_spec_fallback(self: &mut Self, with_body: bool) {
        for i in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(i as u32);
            let mut concrete = true;
            for k in 0..it.n {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if it.module != self.cur_module() || !concrete {
                continue;
            }
            let dk = unsafe (*self.cur_ast()).at_const(it.decl).kind;
            if dk == NodeKind::NODE_STRUCT {
                self.emit_struct_inst(&it, with_body);
            } else if dk == NodeKind::NODE_ENUM {
                self.emit_enum_inst(&it, with_body);
            }
        }
    }
    fn emit_aggregate_specializations(self: &mut Self, with_body: bool) {
        if !with_body {
            self.emit_generic_enum_shared();
        }
        let n = unsafe (*self.cur_ast()).instances.len();
        if with_body {
            let state = self.inst_emit_state;
            let nstate = self.inst_emit_n;
            if state == null {
                self.emit_agg_spec_fallback(with_body);
                return;
            }
            let mut i: usize = 0;
            while i < n && i < nstate {
                self.emit_inst_dfs(i as u32, state, nstate, with_body);
                i = i + 1;
            }
        } else {
            let cnt = if n != 0 {
                n;
            } else {
                1 as usize;
            };
            let state = (unsafe stdlib::calloc(cnt, 1)) as *mut u8;
            if state == null {
                self.emit_agg_spec_fallback(with_body);
                return;
            }
            for i in 0..n {
                self.emit_inst_dfs(i as u32, state, n, with_body);
            }
            unsafe stdlib::free(state);
        }
    }
    fn inst_rehomed_here(self: &Self, it: &TyInstance) bool {
        if self.package == null || it.module == self.cur_module() {
            return false;
        }
        for k in 0..it.n {
            if !self.type_is_concrete(it.args[k as usize]) {
                return false;
            }
        }
        return unsafe (*self.package).instance_home(unsafe &*self.cur_ast(), it) == self.cur_module();
    }
    fn rehome_subst_type(self: &mut Self, owner_mod: ModuleId, it: &TyInstance, t: TypeId) TypeId {
        if t == TYPE_NONE {
            return TYPE_NONE;
        }
        let ty = *unsafe (*self.mod_ast(owner_mod)).type_at(t);
        if ty.kind == TypeKind::TYPE_GENERIC {
            let gens = unsafe (*self.mod_ast(owner_mod)).at_const(it.decl).as_data.aggregate.generics;
            let gids = unsafe (*self.mod_ast(owner_mod)).list(gens);
            let mut i: u32 = 0;
            while i < gens.len && i < it.n as u32 {
                if ty.module == it.module && ty.as_data.decl == unsafe gids[i as usize] {
                    return it.args[i as usize];
                }
                i = i + 1;
            }
            return unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(owner_mod), t);
        }
        if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE || ty.kind == TypeKind::TYPE_SLICE || ty.kind == TypeKind::TYPE_ARRAY {
            let e = self.rehome_subst_type(owner_mod, it, ty.as_data.elem);
            let mut nt = ty;
            nt.as_data.elem = e;
            return unsafe (*self.cur_ast()).intern_type(nt);
        }
        if ty.kind == TypeKind::TYPE_INSTANCE {
            let inst = *unsafe (*self.mod_ast(owner_mod)).instance(ty.as_data.inst);
            let mut na = TyArgs8 {};
            let nn = if inst.n < 8 {
                inst.n;
            } else {
                4 as u8;
            };
            for i in 0..nn {
                na[i as usize] = self.rehome_subst_type(owner_mod, it, inst.args[i as usize]);
            }
            return unsafe (*self.cur_ast()).intern_instance(inst.module, inst.decl, &na[0], nn);
        }
        return unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(owner_mod), t);
    }
    fn emit_rehomed_struct(self: &mut Self, it: &TyInstance, with_body: bool) {
        let home = self.cur_ast();
        let hsrc = self.source;
        let owner = self.mod_ast(it.module);
        let osrc = self.mod_src(it.module);
        let oninst = unsafe (*owner).instances.len();
        let mut oit = *it;
        for k in 0..it.n {
            unsafe oit.args[k as usize] = unsafe (*owner).reintern(unsafe &*home, it.args[k as usize]);
        }
        self.source = osrc;
        self.borrowed = true;
        self.ast = self.mod_ast(it.module);
        let dk = unsafe (*self.cur_ast()).at_const(oit.decl).kind;
        if dk == NodeKind::NODE_STRUCT {
            self.emit_struct_inst(&oit, with_body);
        } else if dk == NodeKind::NODE_ENUM {
            self.emit_enum_inst(&oit, with_body);
        }
        unsafe (*self.cur_ast()).instances.truncate(oninst);
        self.borrowed = false;
        self.ast = home;
        self.source = hsrc;
        self.nsubst = 0;
    }
    fn emit_rehomed_struct_dfs(self: &mut Self, idx: u32, state: *mut u8, nstate: usize, with_body: bool) {
        if idx as usize >= nstate || unsafe state[idx as usize] != 0 as u8 {
            return;
        }
        let it = *unsafe (*self.cur_ast()).instance(idx);
        if !self.inst_rehomed_here(&it) {
            unsafe state[idx as usize] = 2;
            return;
        }
        unsafe state[idx as usize] = 1;
        let owner_mod = it.module;
        let dn_kind = unsafe (*self.mod_ast(owner_mod)).at_const(it.decl).kind;
        let members = unsafe (*self.mod_ast(owner_mod)).at_const(it.decl).as_data.aggregate.members;
        let mut deps = TyArgs32 {};
        let mut nh: i32 = 0;
        let mids = unsafe (*self.mod_ast(owner_mod)).list(members);
        for m in 0..members.len {
            let mid = unsafe mids[m as usize];
            let mnk = unsafe (*self.mod_ast(owner_mod)).at_const(mid).kind;
            if dn_kind == NodeKind::NODE_STRUCT && mnk == NodeKind::NODE_FIELD {
                let fty = unsafe (*self.mod_ast(owner_mod)).at_const(mid).as_data.field.ty;
                let fnode_ty = unsafe (*self.mod_ast(owner_mod)).type_of(fty);
                let ft = self.rehome_subst_type(owner_mod, &it, fnode_ty);
                self.push_home_dep(ft, &mut deps[0], &mut nh);
            } else if dn_kind == NodeKind::NODE_ENUM && mnk == NodeKind::NODE_VARIANT {
                let payload = unsafe (*self.mod_ast(owner_mod)).at_const(mid).as_data.variant.payload;
                let pids = unsafe (*self.mod_ast(owner_mod)).list(payload);
                for kk in 0..payload.len {
                    let pid = unsafe pids[kk as usize];
                    let pfk = unsafe (*self.mod_ast(owner_mod)).at_const(pid).kind;
                    let tn = if pfk == NodeKind::NODE_FIELD {
                        unsafe (*self.mod_ast(owner_mod)).at_const(pid).as_data.field.ty;
                    } else {
                        pid;
                    };
                    let fnode_ty = unsafe (*self.mod_ast(owner_mod)).type_of(tn);
                    let ft = self.rehome_subst_type(owner_mod, &it, fnode_ty);
                    self.push_home_dep(ft, &mut deps[0], &mut nh);
                }
            }
        }
        for d in 0..nh {
            self.emit_home_dep(deps[d as usize]);
        }
        self.emit_rehomed_struct(&it, with_body);
        unsafe state[idx as usize] = 2;
    }
    fn emit_rehomed_structs(self: &mut Self, with_body: bool) {
        if self.package == null {
            return;
        }
        let n = unsafe (*self.cur_ast()).instances.len();
        if with_body {
            let state = self.inst_emit_state;
            let nstate = self.inst_emit_n;
            if state == null {
                for ii in 0..n {
                    let it = *unsafe (*self.cur_ast()).instance(ii as u32);
                    if self.inst_rehomed_here(&it) {
                        self.emit_rehomed_struct(&it, with_body);
                    }
                }
                return;
            }
            let mut ii: usize = 0;
            while ii < n && ii < nstate {
                self.emit_rehomed_struct_dfs(ii as u32, state, nstate, with_body);
                ii = ii + 1;
            }
        } else {
            let cnt = if n != 0 {
                n;
            } else {
                1 as usize;
            };
            let state = (unsafe stdlib::calloc(cnt, 1)) as *mut u8;
            if state == null {
                for ii in 0..n {
                    let it = *unsafe (*self.cur_ast()).instance(ii as u32);
                    if self.inst_rehomed_here(&it) {
                        self.emit_rehomed_struct(&it, with_body);
                    }
                }
                return;
            }
            for ii in 0..n {
                self.emit_rehomed_struct_dfs(ii as u32, state, n, with_body);
            }
            unsafe stdlib::free(state);
        }
    }
    fn emit_rehomed_forwards(self: &mut Self) {
        if self.package == null {
            return;
        }
        for i in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(i as u32);
            if !self.inst_rehomed_here(&it) {
                continue;
            }
            let dn_kind = unsafe (*self.mod_ast(it.module)).at_const(it.decl).kind;
            let mut inm = Buf200 {};
            self.inst_name(&it, &mut inm[0], 200);
            if dn_kind == NodeKind::NODE_STRUCT || self.aggregate_has_payload_in(it.module, it.decl) {
                let kw = agg_kw(unsafe (*self.mod_ast(it.module)).at_const(it.decl));
                self.buf.format_into("typedef {} {} {};\n", diag::cstr(kw), diag::cstr(&inm[0]), diag::cstr(&inm[0]));
            } else {
                let anm = unsafe (*self.mod_ast(it.module)).at_const(it.decl).as_data.aggregate.name;
                let mut en = Buf160 {};
                self.render_qualified(it.module, anm, &mut en[0], 160);
                self.buf.format_into("typedef {} {};\n", diag::cstr(&en[0]), diag::cstr(&inm[0]));
            }
        }
    }
    fn emit_fnval_instance_structs(self: &mut Self) {
        let n = unsafe (*self.cur_ast()).instances.len();
        let cnt = if n != 0 {
            n;
        } else {
            1 as usize;
        };
        let state = (unsafe stdlib::calloc(cnt, 1)) as *mut u8;
        self.fnval_pass = true;
        if state != null {
            self.inst_emit_state = state;
            self.inst_emit_n = n;
            for i in 0..n {
                self.emit_inst_dfs(i as u32, state, n, true);
                self.emit_rehomed_struct_dfs(i as u32, state, n, true);
            }
            self.inst_emit_state = null;
            self.inst_emit_n = 0;
            unsafe stdlib::free(state);
        } else {
            for i in 0..n {
                let it = *unsafe (*self.cur_ast()).instance(i as u32);
                let mut concrete = true;
                for k in 0..it.n {
                    if !self.type_is_concrete(it.args[k as usize]) {
                        concrete = false;
                    }
                }
                if !concrete {
                    continue;
                }
                if it.module == self.cur_module() {
                    let dk = unsafe (*self.cur_ast()).at_const(it.decl).kind;
                    if dk == NodeKind::NODE_STRUCT {
                        self.emit_struct_inst(&it, true);
                    } else if dk == NodeKind::NODE_ENUM {
                        self.emit_enum_inst(&it, true);
                    }
                } else if self.inst_rehomed_here(&it) {
                    self.emit_rehomed_struct(&it, true);
                }
            }
        }
        self.fnval_pass = false;
    }
    fn emit_generic_macros(self: &mut Self) {
        if self.package == null {
            return;
        }
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            let ng = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate.generics.len;
            if nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM || ng == 0 {
                continue;
            }
            if self.cg_attr(self.cur_module(), nid, AttrKind::ATTR_EMIT_MACRO) == null {
                continue;
            }
            if nk == NodeKind::NODE_ENUM {
                if self.aggregate_has_payload(nid) {
                    self.emit_enum_tag_decl(nid);
                } else {
                    self.emit_enum_full(nid);
                }
            }
            self.emit_generic_macro(nid, false);
            self.emit_generic_macro(nid, true);
            self.emit_generic_method_macros(nid);
            self.emit_generic_conformance_macros(nid);
        }
    }
    fn emit_inst_methods(
        self: &mut Self,
        it: &TyInstance,
        mi_src: *mut Ast,
        mi_inst: TypeId,
        which: i32,
        with_body: bool,
    ) {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        let mut inm = Buf200 {};
        self.inst_name(it, &mut inm[0], 200);
        let ifnv = self.inst_mentions_fnval(it);
        // CG-4: only extends whose target resolves to it.decl can match this instance.
        let mut ch = ExtChain {};
        let nchain = self.cg_ext_chain(self.cur_module(), it.decl, &mut ch[0], 64);
        let total = if nchain >= 0 {
            nchain;
        } else {
            items.len as i32;
        };
        for x in 0..total {
            let i = if nchain >= 0 {
                ch[x as usize];
            } else {
                x;
            };
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 {
                continue;
            }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != it.decl {
                continue;
            }
            let itrait = self.extend_interface(nid);
            if itrait.node != NODE_NONE {
                let itty = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, &it.args[0], it.n);
                if !self.cg_type_satisfies(itty, itrait, 0) {
                    continue;
                }
            }
            if !self.cg_extend_bounds_hold(nid, &it.args[0], it.n) {
                continue;
            }
            let gens = ed.generics;
            let gids = unsafe (*self.cur_ast()).list(gens);
            let ms = ed.items;
            let mids = unsafe (*self.cur_ast()).list(ms);
            for j in 0..ms.len {
                let mid = unsafe mids[j as usize];
                let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
                let mk_kind = unsafe (*self.cur_ast()).at_const(mid).kind;
                if mk_kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let mut skip = false;
                if with_body {
                    skip = mf.body == NODE_NONE;
                } else {
                    skip = mf.generics.len == 0 && !want_fn(which, !ifnv && mf.is_public);
                }
                if skip {
                    continue;
                }
                self.nsubst = 0;
                let mut g: u32 = 0;
                while g < gens.len && g < it.n as u32 && self.nsubst < 16 {
                    self.subst[self.nsubst as usize].param = DefId {
                        module: self.cur_module(),
                        node: unsafe gids[g as usize],
                    };
                    self.subst[self.nsubst as usize].concrete = it.args[g as usize];
                    self.nsubst = self.nsubst + 1;
                    g = g + 1;
                }
                let mut nm = Buf320 {};
                let mut at = bappend(&mut nm[0], 320, 0, &inm[0]);
                at = bappend(&mut nm[0], 320, at, "__".ptr() as *const char);
                let mnsp = self.name_span(mf.name);
                self.render_ident(mnsp, unsafe ((&mut nm[0]) as *mut char + at), 320 - at);
                let stat = self.multifile && (ifnv || !mf.is_public);
                if self.minst_only && mf.generics.len == 0 {
                    self.nsubst = 0;
                    continue;
                }
                if mf.generics.len == 0 {
                    let mdef = DefId { module: self.cur_module(), node: mid };
                    if self.multifile && itrait.node == NODE_NONE && self.cg_attr(
                        self.cur_module(),
                        it.decl,
                        AttrKind::ATTR_EMIT_MACRO,
                    ) == null && !unsafe (*self.package).method_used_get(mdef) {
                        self.nsubst = 0;
                        continue;
                    }
                    if !with_body {
                        self.emit_ret_struct_named(mid, &nm[0]);
                    }
                    self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, with_body, &nm[0], stat);
                    self.nsubst = 0;
                    continue;
                }
                let nimpl = self.nsubst;
                let mg = mf.generics;
                let mgids = unsafe (*self.cur_ast()).list(mg);
                for mk in 0..unsafe (*mi_src).method_insts.len() {
                    let minst = unsafe (*mi_src).method_insts[mk];
                    if minst.method != mid || minst.instance != mi_inst {
                        continue;
                    }
                    self.nsubst = nimpl;
                    let mut fnval = ifnv;
                    let mut mgi: u32 = 0;
                    while mgi < mg.len && mgi < minst.n as u32 && self.nsubst < 16 {
                        let ta = if mi_src == self.cur_ast() {
                            minst.targs[mgi as usize];
                        } else {
                            unsafe (*self.cur_ast()).reintern(unsafe &*mi_src, minst.targs[mgi as usize]);
                        };
                        self.subst[self.nsubst as usize].param = DefId {
                            module: self.cur_module(),
                            node: unsafe mgids[mgi as usize],
                        };
                        self.subst[self.nsubst as usize].concrete = ta;
                        if self.cg_type_mentions_fnval(ta) {
                            fnval = true;
                        }
                        self.nsubst = self.nsubst + 1;
                        mgi = mgi + 1;
                    }
                    let mut wf = false;
                    if fnval {
                        wf = which != PROTO_PUBLIC;
                    } else {
                        wf = want_fn(which, mf.is_public);
                    }
                    if !with_body && !wf {
                        continue;
                    }
                    let mut snm = Buf400 {};
                    let mut a2 = bappend(&mut snm[0], 400, 0, &nm[0]);
                    for gg in 0..minst.n {
                        a2 = bappend(&mut snm[0], 400, a2, "__".ptr() as *const char);
                        let tg = if mi_src == self.cur_ast() {
                            minst.targs[gg as usize];
                        } else {
                            unsafe (*self.cur_ast()).reintern(unsafe &*mi_src, minst.targs[gg as usize]);
                        };
                        let mut e = Buf176 {};
                        self.mangle_type(tg, &mut e[0], 176);
                        a2 = bappend(&mut snm[0], 400, a2, &e[0]);
                    }
                    if !with_body {
                        self.emit_ret_struct_named(mid, &snm[0]);
                    }
                    self.emit_function(
                        mid,
                        DefId { module: 0, node: NODE_NONE },
                        false,
                        with_body,
                        &snm[0],
                        stat || fnval,
                    );
                }
                self.nsubst = 0;
            }
        }
    }
    fn emit_method_specializations(self: &mut Self, which: i32, with_body: bool) {
        for ii in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            if it.module != self.cur_module() {
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                continue;
            }
            let itTy = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, &it.args[0], it.n);
            let src = self.cur_ast();
            self.emit_inst_methods(&it, src, itTy, which, with_body);
            self.nsubst = 0;
        }
    }
    fn emit_rehomed_methods(self: &mut Self, which: i32, with_body: bool) {
        if self.package == null {
            return;
        }
        for ii in 0..unsafe (*self.cur_ast()).instances.len() {
            let home = self.cur_ast();
            let home_mod = unsafe (*home).module;
            let hsrc = self.source;
            let it = *unsafe (*home).instance(ii as u32);
            if !self.inst_rehomed_here(&it) {
                continue;
            }
            let itTy = unsafe (*home).intern_instance(it.module, it.decl, &it.args[0], it.n);
            let owner = self.mod_ast(it.module);
            let osrc = self.mod_src(it.module);
            let oninst = unsafe (*owner).instances.len();
            let mut oit = it;
            for k in 0..it.n {
                unsafe oit.args[k as usize] = unsafe (*owner).reintern(unsafe &*home, it.args[k as usize]);
            }
            self.source = osrc;
            self.borrowed = true;
            self.ast = self.mod_ast(it.module);
            self.emit_inst_methods(&oit, self.mod_ast(home_mod), itTy, which, with_body);
            unsafe (*self.cur_ast()).instances.truncate(oninst);
            self.borrowed = false;
            self.ast = home;
            self.source = hsrc;
            self.nsubst = 0;
        }
    }
    fn emit_local_method_insts(self: &mut Self, which: i32, with_body: bool) {
        if self.package == null || !with_body && which == PROTO_PUBLIC {
            return;
        }
        for ii in 0..unsafe (*self.cur_ast()).instances.len() {
            let home = self.cur_ast();
            let home_mod = unsafe (*home).module;
            let hsrc = self.source;
            let it = *unsafe (*home).instance(ii as u32);
            if it.module == home_mod || it.module as usize >= self.pkg_count() || self.inst_rehomed_here(&it) {
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                continue;
            }
            let itTy = unsafe (*home).intern_instance(it.module, it.decl, &it.args[0], it.n);
            let mut any = false;
            let mut mk: usize = 0;
            while mk < unsafe (*home).method_insts.len() && !any {
                if unsafe (*home).method_insts[mk].instance == itTy {
                    any = true;
                }
                mk = mk + 1;
            }
            if !any {
                continue;
            }
            let owner = self.mod_ast(it.module);
            let osrc = self.mod_src(it.module);
            let oninst = unsafe (*owner).instances.len();
            let mut oit = it;
            for k2 in 0..it.n {
                unsafe oit.args[k2 as usize] = unsafe (*owner).reintern(unsafe &*home, it.args[k2 as usize]);
            }
            self.source = osrc;
            self.borrowed = true;
            self.minst_only = true;
            self.ast = self.mod_ast(it.module);
            self.emit_inst_methods(&oit, self.mod_ast(home_mod), itTy, which, with_body);
            self.minst_only = false;
            unsafe (*self.cur_ast()).instances.truncate(oninst);
            self.borrowed = false;
            self.ast = home;
            self.source = hsrc;
            self.nsubst = 0;
        }
    }
    fn emit_specializations(self: &mut Self, with_body: bool) {
        for i in 0..self.ninsts {
            let inst = self.insts[i as usize];
            let fn2 = inst.func;
            let mut concrete = true;
            for k in 0..inst.n {
                if !self.type_is_concrete(inst.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                continue;
            }
            if fn2.module == self.cur_module() {
                let gens = unsafe (*self.cur_ast()).at_const(fn2.node).as_data.function.generics;
                let gids = unsafe (*self.cur_ast()).list(gens);
                self.nsubst = 0;
                let mut g: u32 = 0;
                while g < gens.len && g < inst.n as u32 && self.nsubst < 16 {
                    self.subst[self.nsubst as usize].param = DefId { module: fn2.module, node: unsafe gids[g as usize] };
                    self.subst[self.nsubst as usize].concrete = inst.args[g as usize];
                    self.nsubst = self.nsubst + 1;
                    g = g + 1;
                }
                let mut nm = Buf256 {};
                self.spec_name(fn2, &inst.args[0], inst.n, &mut nm[0], 256);
                if !with_body {
                    self.emit_ret_struct_named(fn2.node, &nm[0]);
                }
                self.emit_function(fn2.node, DefId { module: 0, node: NODE_NONE }, false, with_body, &nm[0], true);
                self.nsubst = 0;
                continue;
            }
            if self.package == null || fn2.module as usize >= self.pkg_count() {
                continue;
            }
            let home = self.cur_ast();
            let hsrc = self.source;
            let owner = self.mod_ast(fn2.module);
            let osrc = self.mod_src(fn2.module);
            let oninst = unsafe (*owner).instances.len();
            let mut oargs = TyArgs8 {};
            for k2 in 0..inst.n {
                oargs[k2 as usize] = unsafe (*owner).reintern(unsafe &*home, inst.args[k2 as usize]);
            }
            self.ast = owner;
            self.source = osrc;
            self.borrowed = true;
            let gens = unsafe (*self.cur_ast()).at_const(fn2.node).as_data.function.generics;
            let gids = unsafe (*self.cur_ast()).list(gens);
            self.nsubst = 0;
            let mut g: u32 = 0;
            while g < gens.len && g < inst.n as u32 && self.nsubst < 16 {
                self.subst[self.nsubst as usize].param = DefId { module: fn2.module, node: unsafe gids[g as usize] };
                self.subst[self.nsubst as usize].concrete = oargs[g as usize];
                self.nsubst = self.nsubst + 1;
                g = g + 1;
            }
            let mut nm = Buf256 {};
            self.spec_name(fn2, &oargs[0], inst.n, &mut nm[0], 256);
            if !with_body {
                self.emit_ret_struct_named(fn2.node, &nm[0]);
            }
            self.emit_function(fn2.node, DefId { module: 0, node: NODE_NONE }, false, with_body, &nm[0], true);
            self.nsubst = 0;
            unsafe (*self.cur_ast()).instances.truncate(oninst);
            self.borrowed = false;
            self.ast = home;
            self.source = hsrc;
        }
    }
    fn emit_default_methods(self: &mut Self, which: i32, with_body: bool) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.interface_type == NODE_NONE || ed.target_type == NODE_NONE || ed.generics.len != 0 {
                continue;
            }
            let iface = unsafe (*self.cur_ast()).resolution_def(ed.interface_type);
            let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
            if iface.node == NODE_NONE || target.node == NODE_NONE {
                continue;
            }
            let foreign = iface.module != self.cur_module();
            if foreign && (self.package == null || iface.module as usize >= self.pkg_count()) {
                continue;
            }
            let mut bb: i32 = -1;
            if self.package != null {
                bb = unsafe (*self.package).builtin_of_decl(target.module, target.node);
            }
            let tkind_is_enum = unsafe (*self.mod_ast(target.module)).at_const(target.node).kind == NodeKind::NODE_ENUM;
            let ia = self.mod_ast(iface.module);
            let mut tyv = Ty { kind: TypeKind::TYPE_STRUCT, module: target.module, as_data: TyAs { decl: target.node } };
            if bb >= 0 {
                tyv = Ty { kind: TypeKind::TYPE_BUILTIN, as_data: TyAs { builtin: bb as BuiltinType } };
            } else if tkind_is_enum {
                tyv = Ty { kind: TypeKind::TYPE_ENUM, module: target.module, as_data: TyAs { decl: target.node } };
            }
            let tty = unsafe (*ia).intern_type(tyv);
            let req = unsafe (*ia).at_const(iface.node).as_data.interface_def.items;
            let rids = unsafe (*ia).list(req);
            let have = ed.items;
            let hids = unsafe (*self.cur_ast()).list(have);
            let vis = unsafe (*ia).at_const(iface.node).as_data.interface_def.is_public && target.module == self.cur_module();
            for r in 0..req.len {
                let rid = unsafe rids[r as usize];
                let rm = unsafe (*ia).at_const(rid);
                if rm.kind != NodeKind::NODE_FUNCTION || rm.as_data.function.body == NODE_NONE || rm.as_data.function.generics.len != 0 {
                    continue;
                }
                if !with_body && !want_fn(which, vis) {
                    continue;
                }
                let rmn = unsafe (*ia).at_const(rm.as_data.function.name).as_data.name.text;
                let mut overridden = false;
                let mut h: u32 = 0;
                while h < have.len && !overridden {
                    let hm = unsafe (*self.cur_ast()).at_const(unsafe hids[h as usize]);
                    if hm.kind == NodeKind::NODE_FUNCTION {
                        let hmn = unsafe (*self.cur_ast()).at_const(hm.as_data.function.name).as_data.name.text;
                        if cg_span_eq(self.source, hmn, self.mod_src(iface.module), rmn) {
                            overridden = true;
                        }
                    }
                    h = h + 1;
                }
                if overridden {
                    continue;
                }
                let home = self.cur_ast();
                let hsrc = self.source;
                let mut oninst: usize = 0;
                if foreign {
                    self.source = self.mod_src(iface.module);
                    self.ast = self.mod_ast(iface.module);
                    self.borrowed = true;
                    self.dflt_home = unsafe (*home).module;
                    self.dflt_home_set = true;
                    oninst = unsafe (*self.cur_ast()).instances.len();
                }
                self.nsubst = 1;
                self.subst[0].param = iface;
                self.subst[0].concrete = tty;
                if !with_body {
                    self.emit_ret_struct(rid, target);
                }
                let mut dnm = Buf256 {};
                self.function_name(rid, target, &mut dnm[0], 256, true);
                let stat = self.multifile && !vis;
                self.emit_function(rid, target, false, with_body, &dnm[0], stat);
                self.nsubst = 0;
                if foreign {
                    unsafe (*self.cur_ast()).instances.truncate(oninst);
                    self.borrowed = false;
                    self.dflt_home_set = false;
                    self.ast = home;
                    self.source = hsrc;
                }
            }
        }
    }
    fn emit_closure_fn(self: &mut Self, id: NodeId, with_body: bool) {
        let cl = unsafe (*self.cur_ast()).at_const(id).as_data.closure;
        let caps = cl.captures.len != 0;
        let mut nm = Buf200 {};
        self.closure_name(id, &mut nm[0], 200);
        if caps && !with_body {
            self.emit_str("typedef struct { ");
            let cids = unsafe (*self.cur_ast()).list(cl.captures);
            for i in 0..cl.captures.len {
                let cid = unsafe cids[i as usize];
                let mut fnm = Buf128 {};
                let csp = self.cg_decl_name_span(cid);
                self.render_ident(csp, &mut fnm[0], 128);
                let mut ft = unsafe (*self.cur_ast()).type_of(cid);
                if (cl.mut_caps as u64 >> i as u64 & 1 as u64) != 0 as u64 {
                    ft = unsafe (*self.cur_ast()).intern_type(
                        Ty {
                            kind: TypeKind::TYPE_POINTER,
                            qualifier: TypeQualifier::TYPE_QUAL_MUT as u8,
                            as_data: TyAs { elem: ft },
                        },
                    );
                }
                let mut d = Buf300 {};
                self.render_type_id(ft, &fnm[0], &mut d[0], 300);
                self.buf.format_into("{}; ", diag::cstr(&d[0]));
            }
            self.buf.format_into("}} {}_env;\n", diag::cstr(&nm[0]));
            let fnty = Ty { kind: TypeKind::TYPE_FUNCTION, module: self.cur_module(), as_data: TyAs { decl: id } };
            if self.cg_fn_owns(&fnty) {
                self.buf.format_into(
                    "static __attribute__((unused)) {}_env_free({}_env *const __e) {{ ",
                    diag::cstr(&nm[0]),
                    diag::cstr(&nm[0]),
                );
                for i2 in 0..cl.captures.len {
                    let cid = unsafe cids[i2 as usize];
                    if (cl.mut_caps as u64 >> i2 as u64 & 1 as u64) != 0 as u64 || !self.cg_type_is_free(
                        unsafe (*self.cur_ast()).type_of(cid),
                    ) {
                        continue;
                    }
                    let mut fnm = Buf128 {};
                    let csp = self.cg_decl_name_span(cid);
                    self.render_ident(csp, &mut fnm[0], 128);
                    if self.emit_free_target(unsafe (*self.cur_ast()).type_of(cid)) {
                        self.buf.format_into("(&__e->{}); ", diag::cstr(&fnm[0]));
                    }
                }
                self.emit_str("}\n");
            }
        }
        let mut ps = Buf1024 {};
        self.render_params(cl.params, &mut ps[0], 1024);
        let mut decl = Buf1320 {};
        let mut at = bappend(&mut decl[0], 1320, 0, &nm[0]);
        at = bappend(&mut decl[0], 1320, at, "(".ptr() as *const char);
        if caps {
            at = bappend(&mut decl[0], 1320, at, "const ".ptr() as *const char);
            at = bappend(&mut decl[0], 1320, at, &nm[0]);
            at = bappend(&mut decl[0], 1320, at, "_env *const __env".ptr() as *const char);
            if unsafe cstring::strcmp(&ps[0], "void".ptr() as *const char) != 0 {
                at = bappend(&mut decl[0], 1320, at, ", ".ptr() as *const char);
                at = bappend(&mut decl[0], 1320, at, &ps[0]);
            }
        } else {
            at = bappend(&mut decl[0], 1320, at, &ps[0]);
        }
        bappend(&mut decl[0], 1320, at, ")".ptr() as *const char);

        let body = cl.body;
        let expr_body = cl.expr_body;
        let mut rt = TYPE_NONE;
        if expr_body {
            rt = unsafe (*self.cur_ast()).type_of(body);
        }
        self.emit_str("static __attribute__((unused)) ");
        let mut out = Buf1400 {};
        if expr_body {
            self.render_type_id(rt, &decl[0], &mut out[0], 1400);
        } else {
            let rets = cl.returns;
            if rets.len == 1 {
                let r0 = unsafe (*self.cur_ast()).list(rets)[0];
                let rn = unsafe (*self.cur_ast()).at_const(r0);
                let rtn = if rn.kind == NodeKind::NODE_PARAMETER {
                    rn.as_data.parameter.ty;
                } else {
                    r0;
                };
                self.render_type_node(rtn, &decl[0], &mut out[0], 1400);
            } else {
                buf_join3(&mut out[0], 1400, "void ".ptr() as *const char, "".ptr() as *const char, &decl[0]);
            }
        }
        self.emit_cstr(&out[0]);
        if !with_body {
            self.emit_str(";\n");
            return;
        }
        unsafe self.current_ret[0] = 0 as char;
        let saved_env = self.env_clos;
        self.env_clos = if caps {
            id;
        } else {
            NODE_NONE;
        };
        if expr_body {
            let mut is_void = false;
            if rt != TYPE_NONE {
                let rty = *self.type_at(rt);
                is_void = rty.kind == TypeKind::TYPE_BUILTIN && rty.as_data.builtin == BuiltinType::BT_VOID;
            }
            self.emit_str(" {\n");
            self.depth = self.depth + 1;
            self.emit_indent();
            if !is_void {
                self.emit_str("return ");
            }
            self.emit_expr(body);
            self.emit_str(";\n");
            self.depth = self.depth - 1;
            self.emit_str("}\n\n");
        } else {
            self.emit_str(" ");
            self.defer_top = 0;
            self.loop_defer_base = 0;
            self.emit_block(body);
            self.emit_str("\n\n");
        }
        self.env_clos = saved_env;
    }
    fn emit_closures(self: &mut Self, with_body: bool) {
        // CG-17: iterate the ids collected by collect_insts' sweep (ascending = old scan order)
        // instead of re-sweeping the whole node arena in both the proto and body passes.
        for i in 0..self.clos_list.len() {
            let cid = *self.clos_list.at(i);
            // A @platform-gated-away item is never typechecked; skip its orphaned, untyped closures.
            if unsafe (*self.cur_ast()).type_of(cid) == TYPE_NONE {
                continue;
            }
            self.emit_closure_fn(cid, with_body);
        }
    }
    fn cb_specialized_away(self: &Self, fnId: NodeId) bool {
        // CG-18: verdicts precomputed by collect_callbacks (cb_insts/cb_keep_fns are final once
        // it returns); an empty map = all-false, matching the pre-collect state.
        return self.cb_away.contains_key(&fnId);
    }
    fn collect_callbacks(self: &mut Self) {
        self.n_cb_insts = 0;
        self.n_cb_keep = 0;
        self.cb_away.free();
        self.cb_away = Map::<u32, u8>::new();
        let nn = unsafe (*self.cur_ast()).nodes.len();
        let mut i: u32 = 0;
        while i as usize < nn {
            let ck = unsafe (*self.cur_ast()).at_const(i).kind;
            if ck != NodeKind::NODE_CALL {
                i = i + 1;
                continue;
            }
            let callee_id = unsafe (*self.cur_ast()).at_const(i).as_data.call.callee;
            if unsafe (*self.cur_ast()).at_const(callee_id).kind != NodeKind::NODE_IDENTIFIER {
                i = i + 1;
                continue;
            }
            let fn2 = unsafe (*self.cur_ast()).resolution_def(callee_id);
            if fn2.module != self.cur_module() || fn2.node == NODE_NONE {
                i = i + 1;
                continue;
            }
            let fnk = unsafe (*self.cur_ast()).at_const(fn2.node).kind;
            let ff = unsafe (*self.cur_ast()).at_const(fn2.node).as_data.function;
            if fnk != NodeKind::NODE_FUNCTION || ff.generics.len != 0 || ff.body == NODE_NONE {
                i = i + 1;
                continue;
            }
            if !self.decl_is_toplevel(fn2.module, fn2.node) {
                i = i + 1;
                continue;
            }
            let mut cbidx: u32 = 0;
            let mut param: NodeId = NODE_NONE;
            let single = self.cb_single_callback_param(fn2.node, &mut cbidx, &mut param);
            if !single || !self.param_only_callee(param) {
                i = i + 1;
                continue;
            }
            let args = unsafe (*self.cur_ast()).at_const(i).as_data.call.args;
            let aids = unsafe (*self.cur_ast()).list(args);
            let mut callee = DefId { module: 0, node: NODE_NONE };
            let mut isclo = false;
            let known = if cbidx < args.len {
                self.cb_known_callee(unsafe aids[cbidx as usize], &mut callee, &mut isclo);
            } else {
                false;
            };
            if known {
                self.cb_record(fn2, param, cbidx, callee, isclo);
            } else {
                self.cb_keep(fn2.node);
            }
            i = i + 1;
        }
        // CG-18: bake the cb_specialized_away verdicts (old logic verbatim: a private local
        // function with at least one recorded specialization and no keep-marker).
        let mut ci: i32 = 0;
        while ci < self.n_cb_insts {
            let fnId = self.cb_insts[ci as usize].func.node;
            ci = ci + 1;
            if self.cb_insts[(ci - 1) as usize].func.module != self.cur_module() || self.cb_away.contains_key(&fnId) {
                continue;
            }
            let fk = unsafe (*self.cur_ast()).at_const(fnId).kind;
            if fk != NodeKind::NODE_FUNCTION || unsafe (*self.cur_ast()).at_const(fnId).as_data.function.is_public {
                continue;
            }
            let mut kept = false;
            for j in 0..self.n_cb_keep {
                if self.cb_keep_fns[j as usize] == fnId {
                    kept = true;
                }
            }
            if !kept {
                self.cb_away.insert(fnId, 1);
            }
        }
    }
    fn emit_callback_specializations(self: &mut Self, with_body: bool) {
        for i in 0..self.n_cb_insts {
            let ci = self.cb_insts[i as usize];
            if ci.func.module != self.cur_module() {
                continue;
            }
            self.cb_param = ci.param;
            self.cb_callee = ci.callee;
            self.cb_callee_closure = ci.callee_closure;
            let mut nm = Buf300 {};
            self.cb_spec_name(ci.func, self.cb_callee, self.cb_callee_closure, &mut nm[0], 300);
            self.emit_function(ci.func.node, DefId { module: 0, node: NODE_NONE }, false, with_body, &nm[0], true);
            self.cb_param = NODE_NONE;
        }
    }
    fn emit_dyn_typedefs(self: &mut Self) {
        // Exact-identity seen set ((module,inst) IS the old scan's equality) replaces the
        // O(pool^2) earlier-entries rescan.
        let mut dyn_seen = Map::<u64, u8>::new();
        for i in 0..unsafe (*self.cur_ast()).type_pool.len() {
            let dy = *unsafe (*self.cur_ast()).type_at(i as TypeId);
            if dy.kind != TypeKind::TYPE_DYN {
                continue;
            }
            let dkey = dy.module as u64 << 32 | dy.as_data.inst as u64;
            if dyn_seen.contains_key(&dkey) {
                continue;
            }
            dyn_seen.insert(dkey, 1);
            let mut stem = Buf176 {};
            self.dyn_stem_dy(&dy, &mut stem[0], 176);
            let sp = (&stem[0]) as *const char;
            let idn_kind = unsafe (*self.mod_ast(dy.module)).at_const(unsafe (*self.cur_ast()).dyn_decl_of(&dy)).kind;
            self.buf.format_into("#ifndef SC_DYN_{}\n#define SC_DYN_{}\n", diag::cstr(sp), diag::cstr(sp));
            self.buf.format_into("typedef struct {}__vt {{\n    void (*__free)(void *self);\n", diag::cstr(sp));
            if idn_kind != NodeKind::NODE_FUNCTION_TYPE {
                // slot 2: the concrete type's mangled name, compared by dyn_cast (string content,
                // so per-TU vtable statics stay independent)
                self.emit_str("    const char *tid;\n");
            }
            if idn_kind == NodeKind::NODE_FUNCTION_TYPE {
                let ftp = unsafe (*self.mod_ast(dy.module)).at_const(unsafe (*self.cur_ast()).dyn_decl_of(&dy)).as_data.function_type.params;
                let pid = unsafe (*self.mod_ast(dy.module)).list(ftp);
                let mut inner = Buf512 {};
                let mut at = bappend(&mut inner[0], 512, 0, "(*call)(void *self".ptr() as *const char);
                for p in 0..ftp.len {
                    let src_ty = unsafe (*self.mod_ast(dy.module)).type_of(unsafe pid[p as usize]);
                    let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(dy.module), src_ty);
                    let mut pt = Buf200 {};
                    self.render_type_id(pt_ty, "".ptr() as *const char, &mut pt[0], 200);
                    at = bappend(&mut inner[0], 512, at, ", ".ptr() as *const char);
                    at = bappend(&mut inner[0], 512, at, &pt[0]);
                }
                bappend(&mut inner[0], 512, at, ")".ptr() as *const char);
                let rt = self.cg_dynfn_ret(dy.module, unsafe (*self.cur_ast()).dyn_decl_of(&dy));
                let mut memb = Buf600 {};
                if rt != TYPE_NONE {
                    self.render_type_id(rt, &inner[0], &mut memb[0], 600);
                } else {
                    buf_join3(&mut memb[0], 600, "void ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
                }
                self.buf.format_into("    {};\n", diag::cstr(&memb[0]));
                self.buf.format_into(
                    "}} {}__vt;\ntypedef struct {}__dyn {{ void *data; const {}__vt *vt; }} {}__dyn;\n",
                    diag::cstr(sp),
                    diag::cstr(sp),
                    diag::cstr(sp),
                    diag::cstr(sp),
                );
                self.buf.format_into(
                    "static inline void {}__dyn_free({}__dyn *const d) {{ d->vt->__free(d->data); }}\n#endif\n",
                    diag::cstr(sp),
                    diag::cstr(sp),
                );
                continue;
            }
            let mut clo = CgDefs8 {};
            let nclo = self.cg_dyn_closure(dy.module, unsafe (*self.cur_ast()).dyn_decl_of(&dy), &mut clo[0], 8);
            let saved_subst = self.cg_dyn_push_subst(&dy);
            for ci in 0..nclo {
                let cd = clo[ci as usize];
                let idn_items = unsafe (*self.mod_ast(cd.module)).at_const(cd.node).as_data.interface_def.items;
                let mids = unsafe (*self.mod_ast(cd.module)).list(idn_items);
                for km in 0..idn_items.len {
                    let mid = unsafe mids[km as usize];
                    if !self.cg_dyn_method(cd.module, mid) {
                        continue;
                    }
                    let mname_node = unsafe (*self.mod_ast(cd.module)).at_const(mid).as_data.function.name;
                    let mut mn = Buf128 {};
                    render_ident_src(
                        self.mod_src(cd.module),
                        unsafe (*self.mod_ast(cd.module)).at_const(mname_node).as_data.name.text,
                        &mut mn[0],
                        128,
                    );
                    let mparams = unsafe (*self.mod_ast(cd.module)).at_const(mid).as_data.function.params;
                    let pids = unsafe (*self.mod_ast(cd.module)).list(mparams);
                    let mut inner = Buf512 {};
                    let mut at = bappend(&mut inner[0], 512, 0, "(*".ptr() as *const char);
                    at = bappend(&mut inner[0], 512, at, &mn[0]);
                    at = bappend(&mut inner[0], 512, at, ")(void *self".ptr() as *const char);
                    let mut p: u32 = 1;
                    while p < mparams.len {
                        let ptn = unsafe (*self.mod_ast(cd.module)).at_const(unsafe pids[p as usize]).as_data.parameter.ty;
                        let src_ty = unsafe (*self.mod_ast(cd.module)).type_of(ptn);
                        let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(cd.module), src_ty);
                        let mut pt = Buf200 {};
                        self.render_type_id(self.subst_resolve(pt_ty), "".ptr() as *const char, &mut pt[0], 200);
                        at = bappend(&mut inner[0], 512, at, ", ".ptr() as *const char);
                        at = bappend(&mut inner[0], 512, at, &pt[0]);
                        p = p + 1;
                    }
                    bappend(&mut inner[0], 512, at, ")".ptr() as *const char);
                    let rt = self.subst_resolve(self.cg_dyn_ret(cd.module, mid));
                    let mut memb = Buf600 {};
                    if rt != TYPE_NONE {
                        self.render_type_id(rt, &inner[0], &mut memb[0], 600);
                    } else {
                        buf_join3(&mut memb[0], 600, "void ".ptr() as *const char, "".ptr() as *const char, &inner[0]);
                    }
                    self.buf.format_into("    {};\n", diag::cstr(&memb[0]));
                }
            }
            self.nsubst = saved_subst;
            // upcast embeds: one pointer per transitive superinterface (incomplete-struct
            // pointers, so declaration order between dyn typedefs does not matter)
            for ciu in 1..nclo {
                let sdd = clo[ciu as usize];
                let mut ss = Buf176 {};
                self.dyn_stem(sdd.module, sdd.node, &mut ss[0], 176);
                self.buf.format_into("    const struct {}__vt *__super_{};\n", diag::cstr(&ss[0]), diag::cstr(&ss[0]));
            }
            self.buf.format_into(
                "}} {}__vt;\ntypedef struct {}__dyn {{ void *data; const {}__vt *vt; }} {}__dyn;\n",
                diag::cstr(sp),
                diag::cstr(sp),
                diag::cstr(sp),
                diag::cstr(sp),
            );
            self.buf.format_into(
                "static inline void {}__dyn_free({}__dyn *const d) {{ d->vt->__free(d->data); }}\n#endif\n",
                diag::cstr(sp),
                diag::cstr(sp),
            );
        }
        dyn_seen.free();
    }
    fn emit_dynfn_table(self: &mut Self, src: TypeId, dy: Ty) {
        let sy = *unsafe (*self.cur_ast()).type_at(src);
        let fd_kind = unsafe (*self.mod_ast(sy.module)).at_const(sy.as_data.decl).kind;
        let capt = self.cg_fn_is_capturing(&sy);
        let mut pair = Buf368 {};
        self.dyn_pair_stem_dy(src, &dy, &mut pair[0], 368);
        let pp = (&pair[0]) as *const char;
        let sig_params = unsafe (*self.mod_ast(dy.module)).at_const(unsafe (*self.cur_ast()).dyn_decl_of(&dy)).as_data.function_type.params;
        let rt = self.cg_dynfn_ret(dy.module, unsafe (*self.cur_ast()).dyn_decl_of(&dy));
        let mut rts = Buf256 {};
        if rt != TYPE_NONE {
            self.render_type_id(rt, "".ptr() as *const char, &mut rts[0], 256);
        } else {
            bappend(&mut rts[0], 256, 0, "void".ptr() as *const char);
        }
        self.buf.format_into(
            "static __attribute__((unused)) {} {}__call(void *__self",
            diag::cstr(&rts[0]),
            diag::cstr(pp),
        );
        let pid = unsafe (*self.mod_ast(dy.module)).list(sig_params);
        for p in 0..sig_params.len {
            let mut an = Buf32 {};
            unsafe stdio::snprintf(&mut an[0], 16, "_a%u".ptr() as *const char, p);
            let src_ty = unsafe (*self.mod_ast(dy.module)).type_of(unsafe pid[p as usize]);
            let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(dy.module), src_ty);
            let mut pd = Buf240 {};
            self.render_type_id(pt_ty, &an[0], &mut pd[0], 240);
            self.buf.format_into(", {}", diag::cstr(&pd[0]));
        }
        self.emit_str(") { ");
        if !capt {
            self.emit_str("(void)__self; ");
        }
        if rt != TYPE_NONE {
            self.emit_str("return ");
        }
        let mut sym = Buf240 {};
        if fd_kind == NodeKind::NODE_CLOSURE {
            self.closure_sym_in(sy.module, sy.as_data.decl, &mut sym[0], 240);
        } else {
            let fname = unsafe (*self.mod_ast(sy.module)).at_const(sy.as_data.decl).as_data.function.name;
            self.render_qualified(sy.module, fname, &mut sym[0], 240);
        }
        self.emit_cstr(&sym[0]);
        self.emit_str("(");
        let mut wrote = false;
        let mut envn = Buf256 {};
        if capt {
            self.render_type_id(src, "".ptr() as *const char, &mut envn[0], 256);
            self.buf.format_into("(const {} *)__self", diag::cstr(&envn[0]));
            wrote = true;
        }
        for p2 in 0..sig_params.len {
            if wrote || p2 != 0 {
                self.emit_str(", ");
            }
            self.buf.format_into("_a{}", p2);
            wrote = true;
        }
        self.emit_str("); }\n");
        let mut owned = false;
        let mut jj: usize = 0;
        while jj < unsafe (*self.cur_ast()).dyn_uses.len() && !owned {
            let oju = unsafe (*self.cur_ast()).dyn_uses[jj];
            if oju.src == src {
                let oy = *unsafe (*self.cur_ast()).type_at(oju.dyn_ty);
                if oy.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                    owned = true;
                }
            }
            jj = jj + 1;
        }
        if owned && self.package != null {
            let hit = unsafe (*self.package).prelude_lookup("Global", true);
            let gname = unsafe (*self.mod_ast(hit.mid)).at_const(hit.node).as_data.aggregate.name;
            let mut gt = Buf160 {};
            self.render_qualified(hit.mid, gname, &mut gt[0], 160);
            let gtp = (&gt[0]) as *const char;
            self.buf.format_into("static void {}____free(void *__self) {{\n", diag::cstr(pp));
            if capt {
                if self.cg_fn_owns(&sy) {
                    let mut csym = Buf240 {};
                    self.closure_sym_in(sy.module, sy.as_data.decl, &mut csym[0], 240);
                    self.buf.format_into("    {}_env_free(({} *)__self);\n", diag::cstr(&csym[0]), diag::cstr(&envn[0]));
                }
                self.buf.format_into(
                    "    {} __g = {}__default_();\n    {}__dealloc(&__g, __self, sizeof({}), _Alignof({}));\n",
                    diag::cstr(gtp),
                    diag::cstr(gtp),
                    diag::cstr(gtp),
                    diag::cstr(&envn[0]),
                    diag::cstr(&envn[0]),
                );
            } else {
                self.emit_str("    (void)__self;\n");
            }
            self.emit_str("}\n");
        }
        let mut stem = Buf176 {};
        self.dyn_stem_dy(&dy, &mut stem[0], 176);
        self.buf.format_into(
            "static const {}__vt {}__vtbl __attribute__((unused)) = {{ ",
            diag::cstr(&stem[0]),
            diag::cstr(pp),
        );
        if owned {
            self.buf.format_into("{}____free", diag::cstr(pp));
        } else {
            self.emit_str("0");
        }
        self.buf.format_into(", {}__call }};\n", diag::cstr(pp));
    }
    fn emit_dyn_tables(self: &mut Self) {
        let n = unsafe (*self.cur_ast()).dyn_uses.len();
        // Content-keyed ((src, rendered stem)) seen map replacing the O(uses^2) rescan: a hash
        // hit is verified by re-rendering the stored first use's stem; a failed verify (a true
        // 64-bit collision) falls back to the authoritative old j<i scan.
        let mut tbl_seen = Map::<u64, u32>::new();
        for i in 0..n {
            let dui = unsafe (*self.cur_ast()).dyn_uses[i];
            if dui.src == TYPE_NONE {
                continue;
            }
            let dy = *unsafe (*self.cur_ast()).type_at(dui.dyn_ty);
            let mut istem = Buf176 {};
            self.dyn_stem_dy(&dy, &mut istem[0], 176);
            let ilen = unsafe cstring::strlen(&istem[0]);
            let ikey = str::from_raw(((&istem[0]) as *const char) as *const u8, ilen).hash() * 1099511628211 ^ dui.src as u64;
            let mut seen = false;
            let mut miss = true;
            switch tbl_seen.get(&ikey) {
                Some(fi) => {
                    miss = false;
                    let duj = unsafe (*self.cur_ast()).dyn_uses[(*fi) as usize];
                    let pj = *unsafe (*self.cur_ast()).type_at(duj.dyn_ty);
                    let mut jstem = Buf176 {};
                    self.dyn_stem_dy(&pj, &mut jstem[0], 176);
                    if duj.src == dui.src && unsafe cstring::strcmp(&istem[0], &jstem[0]) == 0 {
                        seen = true;
                    } else {
                        let mut j: usize = 0;
                        while j < i && !seen {
                            let du2 = unsafe (*self.cur_ast()).dyn_uses[j];
                            if du2.src != dui.src {
                                j = j + 1;
                                continue;
                            }
                            let p2 = *unsafe (*self.cur_ast()).type_at(du2.dyn_ty);
                            if p2.module == dy.module && p2.as_data.inst == dy.as_data.inst {
                                seen = true;
                            } else {
                                let mut jstem2 = Buf176 {};
                                self.dyn_stem_dy(&p2, &mut jstem2[0], 176);
                                if unsafe cstring::strcmp(&istem[0], &jstem2[0]) == 0 {
                                    seen = true;
                                }
                            }
                            j = j + 1;
                        }
                    }
                },
                None => {},
            };
            if miss {
                tbl_seen.insert(ikey, i as u32);
            }
            if seen {
                continue;
            }
            let src = dui.src;
            let sy = *unsafe (*self.cur_ast()).type_at(src);
            if unsafe (*self.mod_ast(dy.module)).at_const(unsafe (*self.cur_ast()).dyn_decl_of(&dy)).kind == NodeKind::NODE_FUNCTION_TYPE {
                self.emit_dynfn_table(src, dy);
                continue;
            }
            let mut tm: ModuleId = 0;
            let mut td: NodeId = NODE_NONE;
            if !self.cg_dyn_target(&sy, &mut tm, &mut td) {
                continue;
            }
            let mut pair = Buf368 {};
            self.dyn_pair_stem_dy(src, &dy, &mut pair[0], 368);
            let pp = (&pair[0]) as *const char;
            let mut recv = Buf256 {};
            self.render_type_id(src, "".ptr() as *const char, &mut recv[0], 256);
            let rvp = (&recv[0]) as *const char;
            let mut clo2 = CgDefs8 {};
            let nclo2 = self.cg_dyn_closure(dy.module, unsafe (*self.cur_ast()).dyn_decl_of(&dy), &mut clo2[0], 8);
            let saved_subst2 = self.cg_dyn_push_subst(&dy);
            for ci2 in 0..nclo2 {
                let cd = clo2[ci2 as usize];
                let idn_items = unsafe (*self.mod_ast(cd.module)).at_const(cd.node).as_data.interface_def.items;
                let mids = unsafe (*self.mod_ast(cd.module)).list(idn_items);
                for km in 0..idn_items.len {
                    let mid = unsafe mids[km as usize];
                    if !self.cg_dyn_method(cd.module, mid) {
                        continue;
                    }
                    let mnamenode = unsafe (*self.mod_ast(cd.module)).at_const(mid).as_data.function.name;
                    let mspan = unsafe (*self.mod_ast(cd.module)).at_const(mnamenode).as_data.name.text;
                    let mut mn = Buf128 {};
                    render_ident_src(self.mod_src(cd.module), mspan, &mut mn[0], 128);
                    let rt = self.subst_resolve(self.cg_dyn_ret(cd.module, mid));
                    let mut rts = Buf256 {};
                    if rt != TYPE_NONE {
                        self.render_type_id(rt, "".ptr() as *const char, &mut rts[0], 256);
                    } else {
                        bappend(&mut rts[0], 256, 0, "void".ptr() as *const char);
                    }
                    self.buf.format_into(
                        "static __attribute__((unused)) {} {}__{}(void *__self",
                        diag::cstr(&rts[0]),
                        diag::cstr(pp),
                        diag::cstr(&mn[0]),
                    );
                    let mparams = unsafe (*self.mod_ast(cd.module)).at_const(mid).as_data.function.params;
                    let pids = unsafe (*self.mod_ast(cd.module)).list(mparams);
                    let mut p: u32 = 1;
                    while p < mparams.len {
                        let mut an = Buf32 {};
                        unsafe stdio::snprintf(&mut an[0], 16, "_a%u".ptr() as *const char, p);
                        let ptn = unsafe (*self.mod_ast(cd.module)).at_const(unsafe pids[p as usize]).as_data.parameter.ty;
                        let src_ty = unsafe (*self.mod_ast(cd.module)).type_of(ptn);
                        let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(cd.module), src_ty);
                        let mut pd = Buf240 {};
                        self.render_type_id(self.subst_resolve(pt_ty), &an[0], &mut pd[0], 240);
                        self.buf.format_into(", {}", diag::cstr(&pd[0]));
                        p = p + 1;
                    }
                    if rt != TYPE_NONE {
                        self.emit_str(") { return ");
                    } else {
                        self.emit_str(") { ");
                    }
                    let mut cm = self.cg_find_method(tm, td, self.mod_src(cd.module), mspan);
                    if cm.node == NODE_NONE {
                        cm = DefId { module: cd.module, node: mid };
                    }
                    self.emit_op_method(sy, tm, td, cm);
                    self.buf.format_into("(({} *)__self", diag::cstr(rvp));
                    let mut p2: u32 = 1;
                    while p2 < mparams.len {
                        self.buf.format_into(", _a{}", p2);
                        p2 = p2 + 1;
                    }
                    self.emit_str("); }\n");
                }
            }
            let mut owned = false;
            let mut oalloc = TYPE_NONE;
            let mut ojo: usize = 0;
            while ojo < unsafe (*self.cur_ast()).dyn_uses.len() && !owned {
                let du = unsafe (*self.cur_ast()).dyn_uses[ojo];
                let oy = *unsafe (*self.cur_ast()).type_at(du.dyn_ty);
                if du.src == src && oy.module == dy.module && oy.as_data.inst == dy.as_data.inst && oy.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                    owned = true;
                    oalloc = du.alloc;
                }
                ojo = ojo + 1;
            }
            if owned && self.package != null {
                let mut gt = Buf160 {};
                if oalloc != TYPE_NONE {
                    // custom allocator (A: Default): the glue reconstructs it via default()
                    self.render_type_id(oalloc, "".ptr() as *const char, &mut gt[0], 160);
                } else {
                    let hit = unsafe (*self.package).prelude_lookup("Global", true);
                    let gname = unsafe (*self.mod_ast(hit.mid)).at_const(hit.node).as_data.aggregate.name;
                    self.render_qualified(hit.mid, gname, &mut gt[0], 160);
                }
                let gtp = (&gt[0]) as *const char;
                self.buf.format_into("static void {}____free(void *__self) {{\n", diag::cstr(pp));
                if self.cg_type_is_free(src) {
                    self.emit_str("    ");
                    self.emit_free_target(src);
                    self.buf.format_into("(({} *)__self);\n", diag::cstr(rvp));
                }
                self.buf.format_into(
                    "    {} __g = {}__default_();\n    {}__dealloc(&__g, __self, sizeof({}), _Alignof({}));\n}}\n",
                    diag::cstr(gtp),
                    diag::cstr(gtp),
                    diag::cstr(gtp),
                    diag::cstr(rvp),
                    diag::cstr(rvp),
                );
            }
            let mut stem = Buf176 {};
            self.dyn_stem_dy(&dy, &mut stem[0], 176);
            self.buf.format_into(
                "static const {}__vt {}__vtbl __attribute__((unused)) = {{ ",
                diag::cstr(&stem[0]),
                diag::cstr(pp),
            );
            if owned {
                self.buf.format_into("{}____free", diag::cstr(pp));
            } else {
                self.emit_str("0");
            }
            {
                let mut tid = Buf256 {};
                self.mangle_type(src, &mut tid[0], 200);
                self.buf.format_into(", \"{}\"", diag::cstr(&tid[0]));
            }
            for ci3 in 0..nclo2 {
                let cd = clo2[ci3 as usize];
                let idn_items = unsafe (*self.mod_ast(cd.module)).at_const(cd.node).as_data.interface_def.items;
                let mids = unsafe (*self.mod_ast(cd.module)).list(idn_items);
                for km2 in 0..idn_items.len {
                    let mid = unsafe mids[km2 as usize];
                    if !self.cg_dyn_method(cd.module, mid) {
                        continue;
                    }
                    let mnamenode = unsafe (*self.mod_ast(cd.module)).at_const(mid).as_data.function.name;
                    let mut mn = Buf128 {};
                    render_ident_src(
                        self.mod_src(cd.module),
                        unsafe (*self.mod_ast(cd.module)).at_const(mnamenode).as_data.name.text,
                        &mut mn[0],
                        128,
                    );
                    self.buf.format_into(", {}__{}", diag::cstr(pp), diag::cstr(&mn[0]));
                }
            }
            // __super_* embeds point at the (superinterface, src) vtables the synthetic
            // dyn_uses emitted just above this one
            for ciu2 in 1..nclo2 {
                let sdd = clo2[ciu2 as usize];
                let mut sp2 = Buf368 {};
                self.dyn_pair_stem(src, sdd.module, sdd.node, &mut sp2[0], 368);
                self.buf.format_into(", &{}__vtbl", diag::cstr(&sp2[0]));
            }
            self.emit_str(" };\n");
            self.nsubst = saved_subst2;
        }
        tbl_seen.free();
        if unsafe (*self.cur_ast()).dyn_uses.len() != 0 {
            self.emit_str("\n");
        }
    }
    fn emit_layout_asserts(self: &mut Self) {
        let ce = self.ceval();
        if ce == null {
            return;
        }
        let mut any = false;
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            let ng = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate.generics.len;
            if nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM || ng != 0 {
                continue;
            }
            if nk == NodeKind::NODE_ENUM && !self.aggregate_has_payload(nid) {
                continue;
            }
            let tkind = if nk == NodeKind::NODE_ENUM {
                TypeKind::TYPE_ENUM;
            } else {
                TypeKind::TYPE_STRUCT;
            };
            let t = unsafe (*self.cur_ast()).intern_type(
                Ty { kind: tkind, module: self.cur_module(), as_data: TyAs { decl: nid } },
            );
            let lo = unsafe (*ce).layout(self.cur_module(), t);
            if !lo.ok {
                continue;
            }
            let mut nm = Buf256 {};
            self.render_type_id(t, "".ptr() as *const char, &mut nm[0], 256);
            self.buf.format_into(
                "_Static_assert(sizeof({}) == {} && _Alignof({}) == {}, \"super-c layout model mismatch: {}\");\n",
                diag::cstr(&nm[0]),
                lo.size,
                diag::cstr(&nm[0]),
                lo.align,
                diag::cstr(&nm[0]),
            );
            any = true;
        }
        for ii in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            if it.module != self.cur_module() {
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete || self.inst_mentions_fnval(&it) {
                continue;
            }
            let t = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, &it.args[0], it.n);
            let lo = unsafe (*ce).layout(self.cur_module(), t);
            if !lo.ok {
                continue;
            }
            let mut nm = Buf256 {};
            self.render_type_id(t, "".ptr() as *const char, &mut nm[0], 256);
            self.buf.format_into(
                "_Static_assert(sizeof({}) == {} && _Alignof({}) == {}, \"super-c layout model mismatch: {}\");\n",
                diag::cstr(&nm[0]),
                lo.size,
                diag::cstr(&nm[0]),
                lo.align,
                diag::cstr(&nm[0]),
            );
            any = true;
        }
        if any {
            self.emit_str("\n");
        }
    }
    // --- materialized consts: CTFE object graphs rendered as static C data with relocations ----

    // True when today's syntactic emission cannot yield a C constant expression (the initializer
    // requires execution); only these attempt materialization, keeping all other output unchanged.
    fn cg_init_needs_ctfe(self: &Self, id: NodeId) bool {
        let a = self.cur_ast();
        let n = unsafe (*a).at_const(id);
        switch n.kind {
            NODE_CALL | NODE_INDEX | NODE_IF | NODE_MATCH | NODE_BLOCK | NODE_CLOSURE => {
                return true;
            },
            NODE_UNARY => {
                return self.cg_init_needs_ctfe(n.as_data.unary.operand);
            },
            NODE_BINARY | NODE_ASSIGNMENT => {
                return self.cg_init_needs_ctfe(n.as_data.binary.left) || self.cg_init_needs_ctfe(n.as_data.binary.right);
            },
            NODE_CAST => {
                return self.cg_init_needs_ctfe(n.as_data.cast.expression);
            },
            NODE_MEMBER => {
                if n.as_data.member.path {
                    return false;
                }
                return self.cg_init_needs_ctfe(n.as_data.member.object);
            },
            NODE_STRUCT_INITIALIZER => {
                let fields = n.as_data.struct_initializer.fields;
                for i in 0..fields.len {
                    let fid = unsafe (*a).list(fields)[i as usize];
                    if unsafe (*a).at_const(fid).kind == NodeKind::NODE_FIELD_INITIALIZER && self.cg_init_needs_ctfe(
                        unsafe (*a).at_const(fid).as_data.field_initializer.value,
                    ) {
                        return true;
                    }
                }
                return false;
            },
            NODE_ARRAY_LITERAL | NODE_TUPLE => {
                let elements = n.as_data.array_literal.elements;
                for i in 0..elements.len {
                    if self.cg_init_needs_ctfe(unsafe (*a).list(elements)[i as usize]) {
                        return true;
                    }
                }
                return false;
            },
            _ => {},
        };
        return false;
    }

    // C type (in the current pool) of a standalone static; TYPE_NONE when underivable.
    fn cg_static_type(self: &mut Self, gi: u32) TypeId {
        let ce = self.ceval();
        let g = unsafe (*ce).static_at(gi);
        let shape = unsafe (*g).shape;
        if shape == ce::SS_HEAP || shape == ce::SS_ARRAY {
            let em = unsafe (*g).etm;
            let mut e = unsafe (*g).ety;
            if em != self.cur_module() {
                e = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(em), e);
            }
            if e == TYPE_NONE {
                return TYPE_NONE;
            }
            let mut len = unsafe (*g).n;
            if len == 0 {
                len = 1;
            }
            return unsafe (*self.cur_ast()).intern_type(
                Ty {
                    kind: TypeKind::TYPE_ARRAY,
                    module: self.cur_module(),
                    as_data: TyAs { arr: TyArr { elem: e, len: len } },
                },
            );
        }
        if shape == ce::SS_ENUM {
            return unsafe (*self.cur_ast()).intern_type(
                Ty { kind: TypeKind::TYPE_ENUM, module: unsafe (*g).dm, as_data: TyAs { decl: unsafe (*g).dn } },
            );
        }
        if shape == ce::SS_STRUCT {
            if unsafe (*g).nargs == 0 {
                return unsafe (*self.cur_ast()).intern_type(
                    Ty { kind: TypeKind::TYPE_STRUCT, module: unsafe (*g).dm, as_data: TyAs { decl: unsafe (*g).dn } },
                );
            }
            let mut args: [TypeId; 4] = [TYPE_NONE, TYPE_NONE, TYPE_NONE, TYPE_NONE];
            for ci in 0..unsafe (*g).nargs {
                let am = unsafe (*g).am[ci as usize];
                let mut at2 = unsafe (*g).at[ci as usize];
                if am != self.cur_module() {
                    at2 = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(am), at2);
                }
                if at2 == TYPE_NONE {
                    return TYPE_NONE;
                }
                args[ci as usize] = at2;
            }
            return unsafe (*self.cur_ast()).intern_instance(unsafe (*g).dm, unsafe (*g).dn, &args[0], unsafe (*g).nargs);
        }
        // SS_CELL
        let em = unsafe (*g).etm;
        let mut e = unsafe (*g).ety;
        if em != self.cur_module() {
            e = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(em), e);
        }
        return e;
    }

    // Emission preflight: every standalone must be typable, and function relocations must resolve
    // to symbols visible where this const lands (headers see only public prototypes).
    fn cg_static_group_ok(self: &mut Self, root: u32, is_public: bool) bool {
        let ce = self.ceval();
        let groupn = unsafe (*(*ce).static_at(root)).groupn;
        for gi in root..root + groupn {
            let g = unsafe (*ce).static_at(gi);
            if unsafe (*g).parent == ce::S_NO_PARENT && gi != root && self.cg_static_type(gi) == TYPE_NONE {
                return false;
            }
            for ri in 0..unsafe (*g).rels.len() {
                let r = unsafe (*g).rels.at(ri);
                if r.kind != ce::SREL_FN {
                    continue;
                }
                let pubfn = unsafe (*self.mod_ast(r.fm)).at_const(r.fnode).as_data.function.is_public;
                if !pubfn && (is_public || r.fm != self.cur_module()) {
                    return false;
                }
            }
        }
        return true;
    }

    fn emit_static_field(self: &mut Self, dm: ModuleId, dn: NodeId, idx: u32) {
        let a = self.mod_ast(dm);
        if unsafe (*a).at_const(dn).as_data.aggregate.is_tuple {
            self.buf.format_into("._{}", idx);
            return;
        }
        let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
        let mut fi: u32 = 0;
        for i in 0..ms.len {
            let fid = unsafe (*a).list(ms)[i as usize];
            if unsafe (*a).at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            if fi == idx {
                let mut fb = Buf128 {};
                render_ident_src(
                    self.mod_src(dm),
                    self.name_span_in(dm, unsafe (*a).at_const(fid).as_data.field.name),
                    &mut fb[0],
                    128,
                );
                self.buf.format_into(".{}", diag::cstr(&fb[0]));
                return;
            }
            fi = fi + 1;
        }
        self.buf.format_into("._{}", idx); // unreachable fallback
    }

    // The C lvalue path of static gi, rooted at its owner's name.
    fn emit_static_path(self: &mut Self, name: *const char, gi: u32) {
        let ce = self.ceval();
        let g = unsafe (*ce).static_at(gi);
        if unsafe (*g).parent == ce::S_NO_PARENT {
            if unsafe (*g).ord == 0 {
                self.emit_cstr(name);
            } else {
                self.buf.format_into("{}__ct{}", diag::cstr(name), unsafe (*g).ord - 1);
            }
            return;
        }
        let pi = unsafe (*g).parent;
        self.emit_static_path(name, pi);
        let p = unsafe (*ce).static_at(pi);
        let pshape = unsafe (*p).shape;
        let pslot = unsafe (*g).pslot;
        if pshape == ce::SS_ARRAY || pshape == ce::SS_HEAP {
            self.buf.format_into("[{}]", pslot);
        } else if pshape == ce::SS_STRUCT {
            self.emit_static_field(unsafe (*p).dm, unsafe (*p).dn, pslot);
        } else if pshape == ce::SS_ENUM {
            let a = self.mod_ast(unsafe (*p).dm);
            let ms = unsafe (*a).at_const(unsafe (*p).dn).as_data.aggregate.members;
            let tag = (unsafe (*p).slots.at(0).i) as u32;
            let vid = unsafe (*a).list(ms)[tag as usize];
            let mut vb = Buf128 {};
            render_ident_src(
                self.mod_src(unsafe (*p).dm),
                self.name_span_in(unsafe (*p).dm, unsafe (*a).at_const(vid).as_data.variant.name),
                &mut vb[0],
                128,
            );
            self.buf.format_into(".payload.{}", diag::cstr(&vb[0]));
            let vdat = unsafe (*a).at_const(vid).as_data.variant;
            if vdat.struct_payload {
                let pfid = unsafe (*a).list(vdat.payload)[(pslot - 1) as usize];
                let mut fb = Buf128 {};
                render_ident_src(
                    self.mod_src(unsafe (*p).dm),
                    self.name_span_in(unsafe (*p).dm, unsafe (*a).at_const(pfid).as_data.field.name),
                    &mut fb[0],
                    128,
                );
                self.buf.format_into(".{}", diag::cstr(&fb[0]));
            } else {
                self.buf.format_into("._{}", pslot - 1);
            }
        }
        // SS_CELL parent: the cell IS the value; no path component
    }

    fn emit_static_rel(self: &mut Self, name: *const char, r: &ce::SRel) {
        if r.kind == ce::SREL_FN {
            let mut ov = Buf160 {};
            if self.cg_symbol_override(r.fm, r.fnode, &mut ov[0], 160) {
                self.emit_cstr(&ov[0]);
                return;
            }
            let mut fb = Buf160 {};
            self.render_qualified(
                r.fm,
                unsafe (*self.mod_ast(r.fm)).at_const(r.fnode).as_data.function.name,
                &mut fb[0],
                160,
            );
            self.emit_cstr(&fb[0]);
            return;
        }
        let ce = self.ceval();
        let tshape = unsafe (*(*ce).static_at(r.target)).shape;
        if tshape == ce::SS_ARRAY || tshape == ce::SS_HEAP {
            if r.toff == 0 {
                self.emit_str("(void *)");
                self.emit_static_path(name, r.target);
            } else {
                self.emit_str("(void *)&");
                self.emit_static_path(name, r.target);
                self.buf.format_into("[{}]", r.toff);
            }
            return;
        }
        self.emit_str("(void *)&");
        self.emit_static_path(name, r.target);
        if tshape == ce::SS_STRUCT && r.toff != 0 {
            self.emit_static_field(
                unsafe (*(*ce).static_at(r.target)).dm,
                unsafe (*(*ce).static_at(r.target)).dn,
                r.toff,
            );
        }
    }

    fn emit_static_slot(self: &mut Self, name: *const char, gi: u32, k: u32) {
        let ce = self.ceval();
        let g = unsafe (*ce).static_at(gi);
        let s = *unsafe (*g).slots.at(k as usize);
        if s.kind == ce::SK_ZERO {
            self.emit_str("{0}");
            return;
        }
        if s.kind == ce::SK_NULL {
            self.emit_str("NULL");
            return;
        }
        if s.kind == ce::SK_AGG {
            self.emit_static_init(name, s.child);
            return;
        }
        if s.kind == ce::SK_REL {
            for ri in 0..unsafe (*g).rels.len() {
                let r = unsafe (*g).rels.at(ri);
                if r.slot == k {
                    self.emit_static_rel(name, r);
                    return;
                }
            }
            self.emit_str("NULL"); // unreachable
            return;
        }
        let mut ty = s.ty;
        if ty != TYPE_NONE && s.tm != self.cur_module() {
            ty = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(s.tm), ty);
        }
        let mut kind = ce::CONST_INT;
        if s.kind == ce::SK_BOOL {
            kind = ce::CONST_BOOL;
        } else if s.kind == ce::SK_FLOAT {
            kind = ce::CONST_FLOAT;
        }
        let mut v = ce::ConstValue { kind: kind, ty: ty, as_data: ce::ConstValueAs { i: s.i } };
        if s.kind == ce::SK_FLOAT {
            v.as_data.f = s.f;
        }
        self.emit_scalar_folded(v);
    }

    fn emit_static_init(self: &mut Self, name: *const char, gi: u32) {
        let ce = self.ceval();
        let g = unsafe (*ce).static_at(gi);
        let shape = unsafe (*g).shape;
        let nslots = (unsafe (*g).slots.len()) as u32;
        if shape == ce::SS_CELL {
            self.emit_static_slot(name, gi, 0);
            return;
        }
        if shape == ce::SS_ARRAY || shape == ce::SS_HEAP {
            let mut allzero = true;
            for k in 0..nslots {
                if unsafe (*g).slots.at(k as usize).kind != ce::SK_ZERO {
                    allzero = false;
                    break;
                }
            }
            if allzero {
                self.emit_str("{0}");
                return;
            }
            // zero elements render per element-type shape: bare 0 for scalars, {0} for aggregates
            let em = unsafe (*g).etm;
            let mut et = unsafe (*g).ety;
            if em != self.cur_module() {
                et = unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(em), et);
            }
            let ek = self.type_at(et).kind;
            let escalar = ek == TypeKind::TYPE_BUILTIN || ek == TypeKind::TYPE_POINTER || ek == TypeKind::TYPE_REFERENCE || ek == TypeKind::TYPE_FUNCTION;
            self.emit_str("{ ");
            for k in 0..nslots {
                if k != 0 {
                    self.emit_str(", ");
                }
                if unsafe (*g).slots.at(k as usize).kind == ce::SK_ZERO && escalar {
                    self.emit_str("0");
                } else {
                    self.emit_static_slot(name, gi, k);
                }
            }
            self.emit_str(" }");
            return;
        }
        if shape == ce::SS_ENUM {
            let dm = unsafe (*g).dm;
            let dn = unsafe (*g).dn;
            let a = self.mod_ast(dm);
            let ms = unsafe (*a).at_const(dn).as_data.aggregate.members;
            let tag = (unsafe (*g).slots.at(0).i) as u32;
            if tag >= ms.len {
                self.emit_str("{0}");
                return;
            }
            let vid = unsafe (*a).list(ms)[tag as usize];
            self.emit_str("{ .tag = ");
            self.emit_tag_mod(dm, dn, vid);
            let mut haspay = false;
            for k in 1..nslots {
                if unsafe (*g).slots.at(k as usize).kind != ce::SK_ZERO {
                    haspay = true;
                }
            }
            if haspay {
                let vdat = unsafe (*a).at_const(vid).as_data.variant;
                let mut vb = Buf128 {};
                render_ident_src(self.mod_src(dm), self.name_span_in(dm, vdat.name), &mut vb[0], 128);
                self.buf.format_into(", .payload.{} = ", diag::cstr(&vb[0]));
                self.emit_str("{ ");
                let mut first = true;
                for k in 1..nslots {
                    if unsafe (*g).slots.at(k as usize).kind == ce::SK_ZERO {
                        continue;
                    }
                    if !first {
                        self.emit_str(", ");
                    }
                    first = false;
                    if vdat.struct_payload {
                        let pfid = unsafe (*a).list(vdat.payload)[(k - 1) as usize];
                        let mut fb = Buf128 {};
                        render_ident_src(
                            self.mod_src(dm),
                            self.name_span_in(dm, unsafe (*a).at_const(pfid).as_data.field.name),
                            &mut fb[0],
                            128,
                        );
                        self.buf.format_into(".{} = ", diag::cstr(&fb[0]));
                    } else {
                        self.buf.format_into("._{} = ", k - 1);
                    }
                    self.emit_static_slot(name, gi, k);
                }
                self.emit_str(" }");
            }
            self.emit_str(" }");
            return;
        }
        // SS_STRUCT
        if nslots == 0 {
            self.emit_str("{}");
            return;
        }
        self.emit_str("{ ");
        for k in 0..nslots {
            if k != 0 {
                self.emit_str(", ");
            }
            self.emit_static_field(unsafe (*g).dm, unsafe (*g).dn, k);
            self.emit_str(" = ");
            self.emit_static_slot(name, gi, k);
        }
        self.emit_str(" }");
    }

    fn emit_static_group(self: &mut Self, name: *const char, root: u32) {
        let ce = self.ceval();
        let groupn = unsafe (*(*ce).static_at(root)).groupn;
        if groupn <= 1 {
            return;
        }
        // tentative forward declarations first: back-references and cycles resolve against them
        for gi in root + 1..root + groupn {
            if unsafe (*(*ce).static_at(gi)).parent != ce::S_NO_PARENT {
                continue;
            }
            let t = self.cg_static_type(gi);
            let og = unsafe (*(*ce).static_at(gi)).ord;
            let mut aux = Buf256 {};
            unsafe stdio::snprintf(&mut aux[0], 256, "%s__ct%u".ptr() as *const char, name, og - 1);
            let mut d = Buf512 {};
            self.render_type_id(t, &aux[0], &mut d[0], 512);
            self.emit_str("static const ");
            self.emit_cstr(&d[0]);
            self.emit_str(";\n");
        }
        for gi in root + 1..root + groupn {
            if unsafe (*(*ce).static_at(gi)).parent != ce::S_NO_PARENT {
                continue;
            }
            let t = self.cg_static_type(gi);
            let og = unsafe (*(*ce).static_at(gi)).ord;
            let mut aux = Buf256 {};
            unsafe stdio::snprintf(&mut aux[0], 256, "%s__ct%u".ptr() as *const char, name, og - 1);
            let mut d = Buf512 {};
            self.render_type_id(t, &aux[0], &mut d[0], 512);
            self.emit_str("__attribute__((unused)) static const ");
            self.emit_cstr(&d[0]);
            self.emit_str(" = ");
            self.emit_static_init(name, gi);
            self.emit_str(";\n");
        }
    }

    // Materialize a call-bearing const initializer as static data; false = use the syntactic path.
    fn emit_const_materialized(self: &mut Self, name: *const char, decl: *const char, value: NodeId, is_public: bool) bool {
        if value == NODE_NONE || self.ceval() == null || !self.cg_init_needs_ctfe(value) {
            return false;
        }
        let sr = unsafe (*self.ceval()).eval_static(self.cur_module(), value);
        if !sr.ok {
            return false;
        }
        if !self.cg_static_group_ok(sr.root, is_public) {
            return false;
        }
        self.emit_static_group(name, sr.root);
        self.emit_str("__attribute__((unused)) static const ");
        self.emit_cstr(decl);
        self.emit_str(" = ");
        self.emit_static_init(name, sr.root);
        self.emit_str(";\n");
        return true;
    }

    fn emit_toplevel_const(self: &mut Self, id: NodeId) {
        let cd = unsafe (*self.cur_ast()).at_const(id).as_data.const_def;
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), cd.name, &mut nm[0], 160);
        let mut decl = Buf256 {};
        self.render_type_node(cd.ty, &nm[0], &mut decl[0], 256);
        if cd.is_static_mut {
            if !cd.is_public {
                self.emit_str("static ");
            }
            self.emit_cstr(&decl[0]);
            self.emit_str(" = ");
            self.emit_initializer(cd.ty, cd.value);
            self.emit_str(";\n");
            return;
        }
        if self.emit_const_materialized(&nm[0], &decl[0], cd.value, cd.is_public) {
            return;
        }
        if self.ceval() != null {
            self.emit_str("__attribute__((unused)) ");
        }
        self.emit_str("static const ");
        self.emit_cstr(&decl[0]);
        if cd.value != NODE_NONE {
            self.emit_str(" = ");
            self.emit_initializer(cd.ty, cd.value);
        }
        self.emit_str(";\n");
    }
    fn emit_assoc_consts(self: &mut Self, public_pass: bool) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len != 0 || ed.target_type == NODE_NONE {
                continue;
            }
            let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
            if target.node == NODE_NONE {
                continue;
            }
            let mids = unsafe (*self.cur_ast()).list(ed.items);
            for j in 0..ed.items.len {
                let mid = unsafe mids[j as usize];
                let cnk = unsafe (*self.cur_ast()).at_const(mid).kind;
                if cnk != NodeKind::NODE_CONST {
                    continue;
                }
                let cd = unsafe (*self.cur_ast()).at_const(mid).as_data.const_def;
                if self.multifile && cd.is_public != public_pass {
                    continue;
                }
                let mut nm = Buf256 {};
                let np = (&mut nm[0]) as *mut char;
                let mut k = self.render_modpfx(self.cur_module(), np, 256);
                let mut bb: i32 = -1;
                if self.package != null {
                    bb = unsafe (*self.package).builtin_of_decl(target.module, target.node);
                }
                if bb >= 0 {
                    k = bappend(np, 256, k, builtin_name(bb as BuiltinType));
                } else {
                    let tsp = self.name_span_in(target.module, self.cg_decl_name_node(target.module, target.node));
                    k = k + render_ident_src(self.mod_src(target.module), tsp, unsafe (np + k), 256 - k);
                }
                k = bappend(np, 256, k, "__".ptr() as *const char);
                let csp = self.name_span(cd.name);
                self.render_ident(csp, unsafe (np + k), 256 - k);
                let mut decl = Buf320 {};
                self.render_type_node(cd.ty, np, &mut decl[0], 320);
                if self.emit_const_materialized(np, &decl[0], cd.value, cd.is_public) {
                    continue;
                }
                if self.ceval() != null {
                    self.emit_str("__attribute__((unused)) ");
                }
                self.emit_str("static const ");
                self.emit_cstr(&decl[0]);
                self.emit_str(" = ");
                self.emit_initializer(cd.ty, cd.value);
                self.emit_str(";\n");
            }
        }
    }
    fn emit_public_consts(self: &mut Self) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_CONST {
                continue;
            }
            let cd = unsafe (*self.cur_ast()).at_const(nid).as_data.const_def;
            if !cd.is_public {
                continue;
            }
            if cd.is_static_mut {
                let mut nm = Buf160 {};
                self.render_qualified(self.cur_module(), cd.name, &mut nm[0], 160);
                let mut decl = Buf256 {};
                self.render_type_node(cd.ty, &nm[0], &mut decl[0], 256);
                self.emit_str("extern ");
                self.emit_cstr(&decl[0]);
                self.emit_str(";\n");
            } else {
                self.emit_toplevel_const(nid);
            }
        }
        self.emit_assoc_consts(true);
    }
    fn emit_referenced_fwd(self: &mut Self) {
        let cur = self.cur_module();
        let np = unsafe (*self.cur_ast()).type_pool.len();
        for i in 0..np {
            let t = *unsafe (*self.cur_ast()).type_at(i as TypeId);
            if t.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(t.as_data.inst);
                if it.module == cur || it.module as usize >= self.pkg_count() {
                    continue;
                }
                let mut concrete = true;
                for k in 0..it.n {
                    if !self.type_is_concrete(it.args[k as usize]) {
                        concrete = false;
                    }
                }
                if !concrete {
                    continue;
                }
                let idn_kind = unsafe (*self.mod_ast(it.module)).at_const(it.decl).kind;
                if idn_kind == NodeKind::NODE_STRUCT || self.aggregate_has_payload_in(it.module, it.decl) {
                    let kw = agg_kw(unsafe (*self.mod_ast(it.module)).at_const(it.decl));
                    let mut inm = Buf200 {};
                    self.inst_name(&it, &mut inm[0], 200);
                    self.buf.format_into(
                        "typedef {} {} {};\n",
                        diag::cstr(kw),
                        diag::cstr(&inm[0]),
                        diag::cstr(&inm[0]),
                    );
                }
                continue;
            }
            if t.module == cur || t.module as usize >= self.pkg_count() {
                continue;
            }
            if self.package != null && unsafe (*self.package).builtin_of_decl(t.module, t.as_data.decl) >= 0 {
                continue;
            }
            if t.kind == TypeKind::TYPE_STRUCT && unsafe (*self.mod_ast(t.module)).at_const(t.as_data.decl).kind == NodeKind::NODE_TYPE_ALIAS {
                // A nominal (extended) alias: a plain `typedef struct X X;` would clash with the owner
                // header's `typedef <underlying> X;`. Re-emit the owner's typedef instead (an identical
                // redeclaration is legal C11), fwd-declaring the underlying instance struct first.
                let sa = self.cur_ast();
                let ss = self.source;
                self.source = self.mod_src(t.module);
                self.ast = self.mod_ast(t.module);
                let ta = unsafe (*self.cur_ast()).at_const(t.as_data.decl).as_data.type_alias;
                let uty = unsafe (*self.cur_ast()).type_of(ta.ty);
                if uty != TYPE_NONE && self.type_at(uty).kind == TypeKind::TYPE_INSTANCE {
                    let uit = *unsafe (*self.cur_ast()).instance(self.type_at(uty).as_data.inst);
                    let mut inm = Buf200 {};
                    self.inst_name(&uit, &mut inm[0], 200);
                    self.buf.format_into("typedef struct {} {};\n", diag::cstr(&inm[0]), diag::cstr(&inm[0]));
                }
                let mut nm = Buf160 {};
                self.render_qualified(t.module, ta.name, &mut nm[0], 160);
                let mut d = Buf256 {};
                self.render_type_node(ta.ty, &nm[0], &mut d[0], 256);
                self.buf.format_into("typedef {};\n", diag::cstr(&d[0]));
                self.ast = sa;
                self.source = ss;
            } else if t.kind == TypeKind::TYPE_STRUCT || t.kind == TypeKind::TYPE_ENUM && self.aggregate_has_payload_in(
                t.module,
                t.as_data.decl,
            ) {
                let kw = agg_kw(unsafe (*self.mod_ast(t.module)).at_const(t.as_data.decl));
                let anm = unsafe (*self.mod_ast(t.module)).at_const(t.as_data.decl).as_data.aggregate.name;
                let mut nm = Buf160 {};
                self.render_qualified(t.module, anm, &mut nm[0], 160);
                self.buf.format_into("typedef {} {} {};\n", diag::cstr(kw), diag::cstr(&nm[0]), diag::cstr(&nm[0]));
            } else if t.kind == TypeKind::TYPE_ENUM {
                let sa = self.cur_ast();
                let ss = self.source;
                let tmod = t.module;
                let tdecl = t.as_data.decl;
                self.source = self.mod_src(tmod);
                self.ast = self.mod_ast(tmod);
                self.emit_enum_full(tdecl);
                self.ast = sa;
                self.source = ss;
            }
        }
    }
    fn emit_referenced_includes(self: &mut Self) {
        let nmod = self.pkg_count();
        let cur = self.cur_module();
        let want = (unsafe stdlib::calloc(
            if nmod != 0 {
                nmod;
            } else {
                1 as usize;
            },
            1,
        )) as *mut bool;
        if want == null {
            return;
        }
        for i in 0..unsafe (*self.cur_ast()).resolutions.len() {
            let d = unsafe (*self.cur_ast()).resolutions[i];
            if d.node == NODE_NONE || d.module == cur || d.module as usize >= nmod {
                continue;
            }
            if self.cg_decl_is_interface_member(d.module, d.node) {
                continue;
            }
            if unsafe (*self.package).builtin_of_decl(d.module, d.node) >= 0 {
                continue;
            }
            unsafe want[d.module as usize] = true;
        }
        for ti in 0..unsafe (*self.cur_ast()).type_pool.len() {
            let t = *unsafe (*self.cur_ast()).type_at(ti as TypeId);
            if t.kind != TypeKind::TYPE_STRUCT && t.kind != TypeKind::TYPE_ENUM && t.kind != TypeKind::TYPE_FUNCTION || t.module == cur || t.module as usize >= nmod {
                continue;
            }
            if unsafe (*self.package).builtin_of_decl(t.module, t.as_data.decl) >= 0 {
                continue;
            }
            if t.kind == TypeKind::TYPE_FUNCTION && self.cg_decl_is_interface_member(t.module, t.as_data.decl) {
                continue;
            }
            unsafe want[t.module as usize] = true;
        }
        for ii in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            let mut concrete = it.module as usize < nmod || it.module == cur;
            let mut k: u8 = 0;
            while k < it.n && concrete {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
                k = k + 1;
            }
            if !concrete {
                continue;
            }
            let home = unsafe (*self.package).instance_home(unsafe &*self.cur_ast(), &it);
            if it.module != cur && it.module as usize < nmod {
                unsafe want[it.module as usize] = true;
            }
            if home != cur && home as usize < nmod {
                unsafe want[home as usize] = true;
            }
        }
        if unsafe (*self.package).core_seeded && unsafe (*self.package).core_module != cur && (unsafe (*self.package).core_module) as usize < nmod {
            let mut need_core = false;
            let mut ci: usize = 0;
            while ci < unsafe (*self.cur_ast()).instances.len() && !need_core {
                let it = *unsafe (*self.cur_ast()).instance(ci as u32);
                let mut concrete = it.module as usize < nmod || it.module == cur;
                let mut k: u8 = 0;
                while k < it.n && concrete {
                    if !self.type_is_concrete(it.args[k as usize]) {
                        concrete = false;
                    }
                    k = k + 1;
                }
                let mut k2: u8 = 0;
                while k2 < it.n && concrete && !need_core {
                    if self.type_mentions_builtin(it.args[k2 as usize]) {
                        need_core = true;
                    }
                    k2 = k2 + 1;
                }
                ci = ci + 1;
            }
            let mut ni: i32 = 0;
            while ni < self.ninsts && !need_core {
                let mut k: u8 = 0;
                while k < self.insts[ni as usize].n && !need_core {
                    if self.type_mentions_builtin(self.insts[ni as usize].args[k as usize]) {
                        need_core = true;
                    }
                    k = k + 1;
                }
                ni = ni + 1;
            }
            if need_core {
                unsafe want[(unsafe (*self.package).core_module) as usize] = true;
            }
        }
        for m in 0..nmod {
            if unsafe want[m] {
                self.emit_modpath_include(unsafe (*self.package).modules[m].path.as_str());
            }
        }
        unsafe stdlib::free(want);
    }
    fn emit_header_includes(self: &mut Self) {
        let nmod = self.pkg_count();
        let cur = self.cur_module();
        let want = (unsafe stdlib::calloc(
            if nmod != 0 {
                nmod;
            } else {
                1 as usize;
            },
            1,
        )) as *mut bool;
        if want == null {
            return;
        }
        let saved = self.nsubst;
        self.nsubst = 0;
        let mut pub_const_expr = false;
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if (nk == NodeKind::NODE_STRUCT || nk == NodeKind::NODE_ENUM) && unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate.generics.len == 0 {
                self.mark_aggregate_layout(nid, want, nmod);
            } else if nk == NodeKind::NODE_FUNCTION && unsafe (*self.cur_ast()).at_const(nid).as_data.function.returns.len > 1 {
                let rets = unsafe (*self.cur_ast()).at_const(nid).as_data.function.returns;
                let rids = unsafe (*self.cur_ast()).list(rets);
                for r in 0..rets.len {
                    let rid = unsafe rids[r as usize];
                    let rn = unsafe (*self.cur_ast()).at_const(rid);
                    let rtn = if rn.kind == NodeKind::NODE_PARAMETER {
                        rn.as_data.parameter.ty;
                    } else {
                        rid;
                    };
                    self.mark_layout_module(unsafe (*self.cur_ast()).type_of(rtn), want, nmod);
                }
            } else if nk == NodeKind::NODE_CONST {
                let cd = unsafe (*self.cur_ast()).at_const(nid).as_data.const_def;
                if !cd.is_extern {
                    self.mark_layout_module(unsafe (*self.cur_ast()).type_of(cd.ty), want, nmod);
                    if cd.is_public && cd.value != NODE_NONE && unsafe (*self.cur_ast()).at_const(cd.value).kind != NodeKind::NODE_LITERAL {
                        pub_const_expr = true;
                    }
                }
            }
        }
        for ii in 0..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            let mut concrete = it.module as usize < nmod || it.module == cur;
            let mut k: u8 = 0;
            while k < it.n && concrete {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
                k = k + 1;
            }
            if !concrete {
                continue;
            }
            let home = unsafe (*self.package).instance_home(unsafe &*self.cur_ast(), &it);
            if home != cur {
                continue;
            }
            if it.module == cur {
                let ag = unsafe (*self.cur_ast()).at_const(it.decl).as_data.aggregate;
                let gids = unsafe (*self.cur_ast()).list(ag.generics);
                self.nsubst = 0;
                let mut g: u32 = 0;
                while g < ag.generics.len && g < it.n as u32 && self.nsubst < 16 {
                    self.subst[self.nsubst as usize].param = DefId { module: it.module, node: unsafe gids[g as usize] };
                    self.subst[self.nsubst as usize].concrete = it.args[g as usize];
                    self.nsubst = self.nsubst + 1;
                    g = g + 1;
                }
                self.mark_aggregate_layout(it.decl, want, nmod);
                self.nsubst = 0;
            } else {
                if it.module as usize < nmod {
                    unsafe want[it.module as usize] = true;
                }
                for k2 in 0..it.n {
                    self.mark_layout_module(it.args[k2 as usize], want, nmod);
                }
            }
        }
        self.nsubst = saved;
        if pub_const_expr {
            for ri in 0..unsafe (*self.cur_ast()).resolutions.len() {
                let d = unsafe (*self.cur_ast()).resolutions[ri];
                if d.node != NODE_NONE && d.module != cur && d.module as usize < nmod && !self.cg_decl_is_interface_member(
                    d.module,
                    d.node,
                ) {
                    unsafe want[d.module as usize] = true;
                }
            }
            for ti in 0..unsafe (*self.cur_ast()).type_pool.len() {
                let t = *unsafe (*self.cur_ast()).type_at(ti as TypeId);
                if (t.kind == TypeKind::TYPE_STRUCT || t.kind == TypeKind::TYPE_ENUM) && t.module != cur && t.module as usize < nmod && unsafe (*self.package).builtin_of_decl(
                    t.module,
                    t.as_data.decl,
                ) < 0 {
                    unsafe want[t.module as usize] = true;
                }
            }
        }
        for m in 0..nmod {
            if m != cur as usize && unsafe want[m] {
                self.emit_modpath_include(unsafe (*self.package).modules[m].path.as_str());
            }
        }
        unsafe stdlib::free(want);
    }
    fn emit_extern_includes(self: &mut Self) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTERN_BLOCK {
                i = i + 1;
                continue;
            }
            let hdr = unsafe (*self.cur_ast()).at_const(nid).as_data.extern_block.header;
            if hdr == NODE_NONE {
                i = i + 1;
                continue;
            }
            let hs = unsafe (*self.cur_ast()).at_const(hdr).span;
            let s = hs.start + 1;
            let e = hs.end - 1;
            if e <= s {
                i = i + 1;
                continue;
            }
            let mut dup = false;
            let mut j: u32 = 0;
            while j < i && !dup {
                let mid = unsafe ids[j as usize];
                if unsafe (*self.cur_ast()).at_const(mid).kind == NodeKind::NODE_EXTERN_BLOCK {
                    let mh = unsafe (*self.cur_ast()).at_const(mid).as_data.extern_block.header;
                    if mh != NODE_NONE {
                        let ms = unsafe (*self.cur_ast()).at_const(mh).span;
                        if ms.end - ms.start == hs.end - hs.start && unsafe cstring::memcmp(
                            self.source.ptr() + ms.start as usize,
                            self.source.ptr() + hs.start as usize,
                            (hs.end - hs.start) as usize,
                        ) == 0 {
                            dup = true;
                        }
                    }
                }
                j = j + 1;
            }
            if dup {
                i = i + 1;
                continue;
            }
            // Resolve the header relative to the declaring module's file (realpath), then emit a
            // build-relative include when it sits under the project root, else its absolute path.
            let mut done = false;
            let cm = self.cur_module();
            if self.package != null && cm as usize < unsafe (*self.package).modules.len() {
                if unsafe (*self.package).modules[cm as usize].file.len() != 0 {
                    let file = unsafe (*self.package).modules[cm as usize].file.cstr();
                    let mut rel = Buf4096 {};
                    let hp = (unsafe (self.source.ptr() + s as usize)) as *const char;
                    let hlen = (e - s) as i32;
                    let slash = unsafe cstring::strrchr(file, '/');
                    if slash != null {
                        let dlen = (slash as usize - file as usize) as i32;
                        unsafe stdio::snprintf(
                            &mut rel[0],
                            4096,
                            "%.*s/%.*s".ptr() as *const char,
                            dlen,
                            file,
                            hlen,
                            hp,
                        );
                    } else {
                        unsafe stdio::snprintf(&mut rel[0], 4096, "./%.*s".ptr() as *const char, hlen, hp);
                    }
                    let mut absb = Buf4096 {};
                    // Absolute realpath, like @c.source wrapper TUs: the emitted tree then compiles
                    // from ANY location (no root-relative "../" placement contract).
                    let ra = unsafe shim::sc_realpath(&rel[0], &mut absb[0]);
                    if ra != null {
                        self.emit_str("#include \"");
                        self.emit_cstr(&absb[0]);
                        self.emit_str("\"\n");
                        done = true;
                    }
                }
            }
            if !done {
                let local = self.source[s as usize] == b'.' || self.source[s as usize] == b'/';
                if local {
                    self.emit_str("#include \"");
                } else {
                    self.emit_str("#include <");
                }
                self.emit_bytes((unsafe (self.source.ptr() + s as usize)) as *const char, (e - s) as usize);
                if local {
                    self.emit_str("\"\n");
                } else {
                    self.emit_str(">\n");
                }
            }
            i = i + 1;
        }
    }
    fn emit_includes(self: &mut Self) {
        let p = unsafe (*self.package).modules[self.cur_module() as usize].path.as_str();
        self.emit_modpath_include(p);
        self.emit_referenced_includes();
        self.emit_str("\n");
    }
    fn cg_test_type(self: &mut Self, d: DefId, is_enum: bool) TypeId {
        let tk = if is_enum {
            TypeKind::TYPE_ENUM;
        } else {
            TypeKind::TYPE_STRUCT;
        };
        return unsafe (*self.cur_ast()).intern_type(Ty { kind: tk, module: d.module, as_data: TyAs { decl: d.node } });
    }
    fn emit_test_wrappers(self: &mut Self) {
        if !self.test.enabled || self.test.ncases == 0 && self.test.genv_init == NODE_NONE {
            return;
        }
        self.emit_str("\n/* --test wrappers */\n");
        for i in 0..self.test.ncases {
            let tc = unsafe self.test.cases[i as usize];
            let suite = tc.suite.node != NODE_NONE;
            let fx_type = if suite {
                tc.suite;
            } else {
                self.test.fx_type;
            };
            let fx_is_enum = if suite {
                tc.suite_is_enum;
            } else {
                self.test.fx_is_enum;
            };
            let fx_init = if suite {
                tc.suite_init;
            } else {
                self.test.fx_init;
            };
            let fx_free = if suite {
                tc.suite_free;
            } else {
                self.test.fx_free;
            };
            let target = if suite {
                tc.suite;
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            let mut fname = Buf240 {};
            self.function_name(tc.func, target, &mut fname[0], 240, true);
            self.buf.format_into(
                "void __sc_test_w_{}_{}(void *__genv) {{\n  (void)__genv;\n",
                self.cur_module() as u32,
                tc.func,
            );
            if (tc.wants & 1) != 0 {
                let fxt = self.cg_test_type(fx_type, fx_is_enum);
                let mut decl = Buf256 {};
                self.render_type_id(fxt, "__fx".ptr() as *const char, &mut decl[0], 256);
                let mut init = Buf240 {};
                self.function_name(fx_init, target, &mut init[0], 240, true);
                self.buf.format_into("  {} = {}();\n", diag::cstr(&decl[0]), diag::cstr(&init[0]));
            }
            self.buf.format_into("  {}(", diag::cstr(&fname[0]));
            if (tc.wants & 1) != 0 {
                self.emit_str("&__fx");
            }
            if (tc.wants & 2) != 0 {
                let gt = self.cg_test_type(self.test.genv_type, self.test.genv_is_enum);
                let mut gty = Buf200 {};
                self.render_type_id(gt, "".ptr() as *const char, &mut gty[0], 200);
                let sep = if (tc.wants & 1) != 0 {
                    ", ".ptr() as *const char;
                } else {
                    "".ptr() as *const char;
                };
                self.buf.format_into("{}(const {} *)__genv", diag::cstr(sep), diag::cstr(&gty[0]));
            }
            self.emit_str(");\n");
            if (tc.wants & 1) != 0 && fx_free != NODE_NONE {
                let mut fre = Buf240 {};
                self.function_name(fx_free, target, &mut fre[0], 240, true);
                self.buf.format_into("  {}(&__fx);\n", diag::cstr(&fre[0]));
            }
            if (tc.wants & 1) != 0 {
                let fxt = self.cg_test_type(fx_type, fx_is_enum);
                if self.cg_type_is_free(fxt) {
                    self.emit_str("  ");
                    self.emit_free_target(fxt);
                    self.emit_str("(&__fx);\n");
                }
            }
            self.emit_str("}\n");
        }
        if self.test.genv_init != NODE_NONE {
            let gt = self.cg_test_type(self.test.genv_type, self.test.genv_is_enum);
            let mut gdecl = Buf256 {};
            self.render_type_id(gt, "__sc_genv".ptr() as *const char, &mut gdecl[0], 256);
            let mut gty = Buf200 {};
            self.render_type_id(gt, "".ptr() as *const char, &mut gty[0], 200);
            let giname = unsafe (*self.cur_ast()).at_const(self.test.genv_init).as_data.function.name;
            let mut init = Buf200 {};
            self.render_qualified(self.cur_module(), giname, &mut init[0], 200);
            self.buf.format_into(
                "void *__sc_test_genv_init(void) {{ static {}; __sc_genv = {}(); return &__sc_genv; }}\n",
                diag::cstr(&gdecl[0]),
                diag::cstr(&init[0]),
            );
            self.emit_str("void __sc_test_genv_free(void *__p) {\n  (void)__p;\n");
            if self.test.genv_free != NODE_NONE {
                let gfname = unsafe (*self.cur_ast()).at_const(self.test.genv_free).as_data.function.name;
                let mut fre = Buf200 {};
                self.render_qualified(self.cur_module(), gfname, &mut fre[0], 200);
                self.buf.format_into("  {}(({} *)__p);\n", diag::cstr(&fre[0]), diag::cstr(&gty[0]));
            }
            if self.cg_type_is_free(gt) {
                self.emit_str("  ");
                self.emit_free_target(gt);
                self.buf.format_into("(({} *)__p);\n", diag::cstr(&gty[0]));
            }
            self.emit_str("}\n");
        }
    }
    pub fn codegen_emit_header(self: &mut Self, out: *mut stdio::FILE) {
        if self.ceval() != null {
            unsafe (*self.ceval()).record_folds = true;
            unsafe (*self.ceval()).all_typed = true;
        }
        self.build_enum_index();
        self.collect_insts(); // phase_types below must see body-substituted aggregate instances
        let mut guard = Buf160 {};
        let np = (&mut guard[0]) as *mut char;
        let mut at = bappend(np, 160, 0, "SUPER_".ptr() as *const char);
        let mp = unsafe (*self.package).modules[self.cur_module() as usize].path.as_str();
        let n = mp.len();
        let mut i: usize = 0;
        while i < n && at + 2 < 160 {
            if mp.byte_at(i) == b':' && i + 1 < n && mp.byte_at(i + 1) == b':' {
                guard[at] = '_' as char;
                guard[at + 1] = '_' as char;
                at = at + 2;
                i = i + 1;
            } else {
                guard[at] = mp.byte_at(i) as char;
                at = at + 1;
            }
            i = i + 1;
        }
        guard[at] = 0 as char;
        bappend(np, 160, at, "_H".ptr() as *const char);
        let mut gi: usize = 0;
        while guard[gi] != 0 as char {
            let ch = guard[gi];
            if ch >= 'a' as char && ch <= 'z' as char {
                guard[gi] = (ch as i32 - 32) as char;
            }
            gi = gi + 1;
        }
        let gp = np as *const char;
        self.buf.format_into("#ifndef {}\n#define {}\n\n", diag::cstr(gp), diag::cstr(gp));
        self.emit_str("#include \"");
        self.emit_rel_prefix();
        self.emit_str("super_rt.h\"\n");
        self.emit_extern_includes();
        self.emit_referenced_fwd();
        self.emit_header_includes();
        self.emit_str("\n");
        self.phase_forward();
        self.emit_str("\n");
        self.phase_types();
        self.phase_ret_structs();
        self.emit_str("\n");
        self.phase_prototypes(PROTO_PUBLIC);
        self.emit_str("\n");
        self.emit_public_consts();
        self.emit_str("\n#endif\n");
        if self.buf.len() != 0 {
            unsafe stdio::fwrite(self.buf.as_ptr(), 1, self.buf.len(), out);
        }
        self.buf.clear();
    }
    pub fn codegen_emit(self: &mut Self, out: *mut stdio::FILE) {
        if self.ceval() != null {
            unsafe (*self.ceval()).record_folds = true;
            unsafe (*self.ceval()).all_typed = true;
        }
        self.build_enum_index();
        self.collect_insts();
        self.collect_callbacks();
        if self.multifile {
            self.emit_includes();
            self.emit_layout_asserts();
            self.phase_prototypes(PROTO_PRIVATE);
            self.emit_str("\n");
            self.emit_dyn_tables();
            self.phase_bodies();
            self.emit_test_wrappers();
        } else {
            self.emit_cstr(super_rt_includes());
            self.emit_extern_includes();
            self.emit_str("\n");
            self.phase_forward();
            self.emit_str("\n");
            self.phase_types();
            self.phase_ret_structs();
            self.emit_str("\n");
            self.emit_layout_asserts();
            self.phase_prototypes(PROTO_ALL);
            self.emit_str("\n");
            self.emit_dyn_tables();
            self.phase_bodies();
            self.emit_test_wrappers();
        }
        let src = self.source;
        let mut file: str = "";
        if self.package != null && self.cur_module() as usize < self.pkg_count() {
            file = unsafe (*self.package).modules[self.cur_module() as usize].file.as_str();
        }
        if CG_TRUNCATED {
            CG_TRUNCATED = false;
            self.errors.emit(
                0,
                0,
                format(
                    "internal: a rendered C declaration exceeded its buffer (type too deeply nested); the emitted C would be invalid",
                ),
            );
        }
        // Promoted fold failures (proven UB) recorded by the evaluator for this module become
        // errors; only the outermost record of nested failing subexpressions is reported.
        let ceptr = self.ceval();
        if ceptr != null {
            let nerr = unsafe (*ceptr).fold_errs.len();
            for i in 0..nerr {
                if unsafe (*ceptr).fold_errs.at(i).m != self.cur_module() {
                    continue;
                }
                let rid = unsafe (*ceptr).fold_errs.at(i).id;
                let sp = unsafe (*self.cur_ast()).at_const(rid).span;
                let mut inner = false;
                for j in 0..nerr {
                    if j == i || unsafe (*ceptr).fold_errs.at(j).m != self.cur_module() {
                        continue;
                    }
                    let sp2 = unsafe (*self.cur_ast()).at_const(unsafe (*ceptr).fold_errs.at(j).id).span;
                    if sp2.start <= sp.start && sp.end <= sp2.end && (sp2.start < sp.start || sp.end < sp2.end) {
                        inner = true;
                        break;
                    }
                }
                if inner {
                    continue;
                }
                let rkind = unsafe (*ceptr).fold_errs.at(i).kind;
                if ce::ce_trap_is_ub(rkind) {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "expression has undefined behavior when evaluated: {}",
                            diag::cstr(unsafe &(*ceptr).fold_errs.at(i).detail[0]),
                        ),
                    );
                } else {
                    self.errors.emit(
                        sp.start,
                        sp.end - sp.start,
                        format(
                            "this 'const fn' call has compile-time-known arguments but failed to evaluate: {}",
                            diag::cstr(unsafe &(*ceptr).fold_errs.at(i).detail[0]),
                        ),
                    );
                }
            }
        }
        self.errors.finalize(src, file);
        if self.buf.len() != 0 {
            unsafe stdio::fwrite(self.buf.as_ptr(), 1, self.buf.len(), out);
        }
    }
    fn seed_emitted_type_instances(self: &mut Self) {
        // Evaluate-once loop bounds mean instances interned during a pass are visited in the
        // NEXT pass (one nesting level per pass), so the backstop cap is per-level now.
        for pass in 0..256 {
            if !self.seed_emitted_generic_method_signature_instances() {
                return;
            }
        }
    }
    fn phase_forward(self: &mut Self) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_STRUCT {
                let ag = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate;
                if ag.generics.len != 0 {
                    continue;
                }
                let kw = agg_kw(unsafe (*self.cur_ast()).at_const(nid));
                self.buf.format_into("typedef {} ", diag::cstr(kw));
                self.emit_local_type_name(ag.name);
                self.emit_str(" ");
                self.emit_local_type_name(ag.name);
                self.emit_str(";\n");
            } else if nk == NodeKind::NODE_ENUM {
                let ag = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate;
                if ag.generics.len != 0 {
                    continue;
                }
                if !self.aggregate_has_payload(nid) {
                    self.emit_enum_full(nid);
                    continue;
                }
                self.emit_enum_tag_decl(nid);
                self.emit_str("typedef struct ");
                self.emit_local_type_name(ag.name);
                self.emit_str(" ");
                self.emit_local_type_name(ag.name);
                self.emit_str(";\n");
            } else if nk == NodeKind::NODE_TYPE_ALIAS {
                let ta = unsafe (*self.cur_ast()).at_const(nid).as_data.type_alias;
                if ta.ty != NODE_NONE && ta.generics.len == 0 && self.cg_alias_extended(self.cur_module(), nid) {
                    let mut nm = Buf160 {};
                    self.render_qualified(self.cur_module(), ta.name, &mut nm[0], 160);
                    let mut d = Buf256 {};
                    self.render_type_node(ta.ty, &nm[0], &mut d[0], 256);
                    self.buf.format_into("typedef {};\n", diag::cstr(&d[0]));
                }
            }
        }
        self.emit_aggregate_specializations(false);
        self.emit_rehomed_forwards();
    }
    fn phase_types(self: &mut Self) {
        self.emit_dyn_typedefs();
        self.seed_emitted_type_instances();
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let state = self.cg_type_state();
        let ni = unsafe (*self.cur_ast()).instances.len();
        let cnt = if ni != 0 {
            ni;
        } else {
            1 as usize;
        };
        self.inst_emit_state = (unsafe stdlib::calloc(cnt, 1)) as *mut u8;
        if self.inst_emit_state != null {
            self.inst_emit_n = ni;
        } else {
            self.inst_emit_n = 0;
        }
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            if self.type_emittable(nid) {
                if state != null {
                    self.emit_type_dfs(nid, state);
                } else {
                    self.emit_type_decl(nid);
                }
            }
        }
        self.emit_aggregate_specializations(true);
        self.emit_rehomed_structs(true);
        self.emit_generic_macros();
        unsafe stdlib::free(self.inst_emit_state);
        self.inst_emit_state = null;
        self.inst_emit_n = 0;
    }
    fn phase_ret_structs(self: &mut Self) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_FUNCTION {
                if unsafe (*self.cur_ast()).at_const(nid).as_data.function.generics.len == 0 {
                    self.emit_ret_struct(nid, DefId { module: 0, node: NODE_NONE });
                }
            } else if nk == NodeKind::NODE_EXTEND {
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                if ed.generics.len != 0 {
                    continue;
                }
                let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
                let ms = ed.items;
                let mids = unsafe (*self.cur_ast()).list(ms);
                for j in 0..ms.len {
                    let mid = unsafe mids[j as usize];
                    if unsafe (*self.cur_ast()).at_const(mid).kind == NodeKind::NODE_FUNCTION {
                        self.emit_ret_struct(mid, target);
                    }
                }
            }
        }
    }
    fn phase_prototypes(self: &mut Self, which: i32) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_FUNCTION {
                let ff = unsafe (*self.cur_ast()).at_const(nid).as_data.function;
                if ff.generics.len != 0 {
                    continue;
                }
                if self.cb_specialized_away(nid) || self.cg_is_format_builtin(self.cur_module(), nid) || self.cg_test_skip(
                    nid,
                    false,
                ) {
                    continue;
                }
                if want_fn(which, ff.is_public) {
                    self.emit_function(nid, DefId { module: 0, node: NODE_NONE }, false, false, null, false);
                }
            } else if nk == NodeKind::NODE_EXTEND {
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                if ed.generics.len != 0 {
                    continue;
                }
                let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
                let mids = unsafe (*self.cur_ast()).list(ed.items);
                for j in 0..ed.items.len {
                    let mid = unsafe mids[j as usize];
                    let mk_kind = unsafe (*self.cur_ast()).at_const(mid).kind;
                    if mk_kind == NodeKind::NODE_FUNCTION {
                        let mpub = unsafe (*self.cur_ast()).at_const(mid).as_data.function.is_public;
                        if want_fn(which, mpub) && !self.cg_test_skip(mid, true) {
                            self.emit_function(mid, target, false, false, null, false);
                        }
                    }
                }
            }
        }
        if which != PROTO_PUBLIC {
            self.emit_closures(false);
            self.emit_fnval_instance_structs();
            self.emit_specializations(false);
            self.emit_callback_specializations(false);
        }
        self.emit_method_specializations(which, false);
        self.emit_rehomed_methods(which, false);
        self.emit_local_method_insts(which, false);
        self.emit_default_methods(which, false);
    }
    fn phase_bodies(self: &mut Self) {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_CONST {
                let cd = unsafe (*self.cur_ast()).at_const(nid).as_data.const_def;
                if cd.is_static_mut || !(self.multifile && cd.is_public) {
                    self.emit_toplevel_const(nid);
                }
            } else if nk == NodeKind::NODE_STATIC_ASSERT {
                self.emit_static_assert(nid);
            }
        }
        self.emit_assoc_consts(false);
        self.emit_default_methods(PROTO_ALL, true);
        self.emit_specializations(true);
        self.emit_method_specializations(PROTO_ALL, true);
        self.emit_rehomed_methods(PROTO_ALL, true);
        self.emit_local_method_insts(PROTO_ALL, true);
        self.emit_closures(true);
        self.emit_callback_specializations(true);
        for i2 in 0..items.len {
            let nid = unsafe ids[i2 as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_FUNCTION {
                let ff = unsafe (*self.cur_ast()).at_const(nid).as_data.function;
                if ff.generics.len == 0 && ff.body != NODE_NONE && !self.cb_specialized_away(nid) && !self.cg_is_format_builtin(
                    self.cur_module(),
                    nid,
                ) && !self.cg_test_skip(nid, false) {
                    self.emit_function(nid, DefId { module: 0, node: NODE_NONE }, false, true, null, false);
                }
            } else if nk == NodeKind::NODE_EXTEND {
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                if ed.generics.len == 0 {
                    let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
                    let mids = unsafe (*self.cur_ast()).list(ed.items);
                    for j in 0..ed.items.len {
                        let mid = unsafe mids[j as usize];
                        let mk_kind = unsafe (*self.cur_ast()).at_const(mid).kind;
                        if mk_kind == NodeKind::NODE_FUNCTION {
                            let mbody = unsafe (*self.cur_ast()).at_const(mid).as_data.function.body;
                            if mbody != NODE_NONE && !self.cg_test_skip(mid, true) {
                                self.emit_function(mid, target, false, true, null, false);
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---- conformance gating + instance seeding ----
extend Codegen {
    // CG-5: memoized front for cg_type_satisfies_uncached. Only top-level (depth 0) queries on
    // concrete types are cached, and only while self.ast is the home ast: TypeIds are pool-local
    // and non-concrete answers depend on the live subst stack. iface fields must fit the key.
    fn cg_type_satisfies(self: &mut Self, ty: TypeId, iface: DefId, depth: i32) bool {
        if depth != 0 || self.ast != self.home_ast || iface.module as u32 >= 256 || iface.node >= 16777216 || !self.type_is_concrete(
            ty,
        ) {
            return self.cg_type_satisfies_uncached(ty, iface, depth);
        }
        let key = ty as u64 | iface.module as u64 << 32 | iface.node as u64 << 40;
        return switch self.sat_memo.get(&key) {
            Some(v) => *v != 0,
            None => {
                let r = self.cg_type_satisfies_uncached(ty, iface, depth);
                self.sat_memo.insert(
                    key,
                    if r {
                        1u64;
                    } else {
                        0u64;
                    },
                );
                r;
            },
        };
    }
    fn cg_type_satisfies_uncached(self: &mut Self, ty: TypeId, iface: DefId, depth: i32) bool {
        if ty == TYPE_NONE || depth > 8 {
            return true;
        }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC {
            return true;
        }
        let mut tmod: ModuleId = 0;
        let mut tdecl: NodeId = NODE_NONE;
        let mut iargs = TyArgs8 {};
        let mut in_: i32 = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            tmod = y.module;
            tdecl = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            tmod = it.module;
            tdecl = it.decl;
            let mut k: u8 = 0;
            while k < it.n && in_ < 8 {
                iargs[in_ as usize] = it.args[k as usize];
                in_ = in_ + 1;
                k = k + 1;
            }
        } else if y.kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bd = unsafe (*self.package).builtin_decl(y.as_data.builtin);
            if bd == NODE_NONE {
                return false;
            }
            tmod = unsafe (*self.package).core_module;
            tdecl = bd;
        } else {
            return false;
        }
        let ns = if tmod == self.cur_module() {
            1;
        } else {
            2;
        };
        for s in 0..ns {
            let m = if s == 0 {
                tmod;
            } else {
                self.cur_module();
            };
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*a).list(items)[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND || it.as_data.extend_def.interface_type == NODE_NONE || it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tr = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tr.module != iface.module || tr.node != iface.node || tg.module != tmod || tg.node != tdecl {
                    continue;
                }
                let gens = it.as_data.extend_def.generics;
                let gids = unsafe (*a).list(gens);
                let mut ok = true;
                let mut g: u32 = 0;
                while g < gens.len && g as i32 < in_ && ok {
                    let gb = unsafe (*a).at_const(unsafe gids[g as usize]).as_data.generic_param.bounds;
                    let gbids = unsafe (*a).list(gb);
                    let mut b: u32 = 0;
                    while b < gb.len && ok {
                        let gbi = unsafe (*a).resolution_def(unsafe gbids[b as usize]);
                        if gbi.node != NODE_NONE && !self.cg_type_satisfies(iargs[g as usize], gbi, depth + 1) {
                            ok = false;
                        }
                        b = b + 1;
                    }
                    g = g + 1;
                }
                if ok {
                    return true;
                }
            }
        }
        return false;
    }

    fn extend_interface(self: &Self, extend_id: NodeId) DefId {
        let it = unsafe (*self.cur_ast()).at_const(extend_id);
        if it.as_data.extend_def.interface_type == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        return unsafe (*self.cur_ast()).resolution_def(it.as_data.extend_def.interface_type);
    }

    fn cg_extend_bounds_hold(self: &mut Self, extend_id: NodeId, args: *const TypeId, n: u8) bool {
        let gens = unsafe (*self.cur_ast()).at_const(extend_id).as_data.extend_def.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        let mut g: u32 = 0;
        while g < gens.len && g < n as u32 {
            let gb = unsafe (*self.cur_ast()).at_const(unsafe gids[g as usize]).as_data.generic_param.bounds;
            let gbids = unsafe (*self.cur_ast()).list(gb);
            for b in 0..gb.len {
                let gbi = unsafe (*self.cur_ast()).resolution_def(unsafe gbids[b as usize]);
                if gbi.node != NODE_NONE && !self.cg_type_satisfies(unsafe args[g as usize], gbi, 0) {
                    return false;
                }
            }
            g = g + 1;
        }
        return true;
    }
}

extend Codegen {
    fn seed_type_instances_from_type(self: &mut Self, ty0: TypeId) bool {
        if ty0 == TYPE_NONE {
            return false;
        }
        let ty = self.subst_resolve(ty0);
        let y = *self.type_at(ty);
        let mut changed = false;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut concrete = true;
            for i in 0..it.n {
                if !self.type_is_concrete(it.args[i as usize]) {
                    concrete = false;
                }
            }
            if concrete {
                let before = unsafe (*self.cur_ast()).instances.len();
                unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, &it.args[0], it.n);
                if unsafe (*self.cur_ast()).instances.len() != before {
                    changed = true;
                }
                for j in 0..it.n {
                    if self.seed_type_instances_from_type(it.args[j as usize]) {
                        changed = true;
                    }
                }
            }
        } else if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_ARRAY {
            if self.seed_type_instances_from_type(y.as_data.elem) {
                changed = true;
            }
        }
        return changed;
    }
    fn seed_type_instances_from_type_node(self: &mut Self, type_node: NodeId) bool {
        if type_node == NODE_NONE {
            return false;
        }
        let ty = unsafe (*self.cur_ast()).type_of(type_node);
        return ty != TYPE_NONE && self.seed_type_instances_from_type(ty);
    }
    fn seed_type_instances_from_fn_signature(self: &mut Self, fn_id: NodeId) bool {
        let f = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function;
        let mut changed = false;
        let pids = unsafe (*self.cur_ast()).list(f.params);
        for i in 0..f.params.len {
            let ptn = unsafe (*self.cur_ast()).at_const(unsafe pids[i as usize]).as_data.parameter.ty;
            if self.seed_type_instances_from_type_node(ptn) {
                changed = true;
            }
        }
        let rids = unsafe (*self.cur_ast()).list(f.returns);
        for r in 0..f.returns.len {
            let rid = unsafe rids[r as usize];
            let rn = unsafe (*self.cur_ast()).at_const(rid);
            let rtn = if rn.kind == NodeKind::NODE_PARAMETER {
                rn.as_data.parameter.ty;
            } else {
                rid;
            };
            if self.seed_type_instances_from_type_node(rtn) {
                changed = true;
            }
        }
        return changed;
    }
    fn seed_emitted_generic_method_signature_instances(self: &mut Self) bool {
        let mut changed = false;
        // CG-9: an instance's seeding outcome is fixed when it is interned (conformance and
        // bounds depend only on its concrete args), so each pass starts at the watermark and
        // instances interned mid-pass are handled by the NEXT pass.
        let start = self.seed_mark as usize;
        self.seed_mark = (unsafe (*self.cur_ast()).instances.len()) as u32;
        for ii in start..unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            if it.module != self.cur_module() {
                continue;
            }
            let mut concrete = true;
            for k in 0..it.n {
                if !self.type_is_concrete(it.args[k as usize]) {
                    concrete = false;
                }
            }
            if !concrete {
                continue;
            }
            let items = self.program_items();
            let iids = unsafe (*self.cur_ast()).list(items);
            // CG-4: only extends whose target resolves to it.decl can match this instance.
            let mut ch = ExtChain {};
            let nchain = self.cg_ext_chain(self.cur_module(), it.decl, &mut ch[0], 64);
            let total = if nchain >= 0 {
                nchain;
            } else {
                items.len as i32;
            };
            for x in 0..total {
                let i = if nchain >= 0 {
                    ch[x as usize];
                } else {
                    x;
                };
                let nid = unsafe iids[i as usize];
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
                if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 {
                    continue;
                }
                if unsafe (*self.cur_ast()).resolution(ed.target_type) != it.decl {
                    continue;
                }
                let itrait = self.extend_interface(nid);
                if itrait.node != NODE_NONE {
                    let itty = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, &it.args[0], it.n);
                    if !self.cg_type_satisfies(itty, itrait, 0) {
                        continue;
                    }
                }
                if !self.cg_extend_bounds_hold(nid, &it.args[0], it.n) {
                    continue;
                }
                let gens = ed.generics;
                let gids = unsafe (*self.cur_ast()).list(gens);
                let saved = self.nsubst;
                self.nsubst = 0;
                let mut g: u32 = 0;
                while g < gens.len && g < it.n as u32 && self.nsubst < 16 {
                    self.subst[self.nsubst as usize].param = DefId {
                        module: self.cur_module(),
                        node: unsafe gids[g as usize],
                    };
                    self.subst[self.nsubst as usize].concrete = it.args[g as usize];
                    self.nsubst = self.nsubst + 1;
                    g = g + 1;
                }
                let ms = ed.items;
                let mids = unsafe (*self.cur_ast()).list(ms);
                for j in 0..ms.len {
                    let mid = unsafe mids[j as usize];
                    let mn = unsafe (*self.cur_ast()).at_const(mid);
                    if mn.kind == NodeKind::NODE_FUNCTION && mn.as_data.function.generics.len == 0 {
                        if self.seed_type_instances_from_fn_signature(mid) {
                            changed = true;
                        }
                    }
                }
                self.nsubst = saved;
            }
        }
        return changed;
    }
}

// ---- header/source #include machinery ----
extend Codegen {
    fn module_depth(self: &Self) usize {
        let p = unsafe (*self.package).modules[self.cur_module() as usize].path.as_str();
        let n = p.len();
        let mut d: usize = 0;
        let mut i: usize = 0;
        while i < n {
            if p.byte_at(i) == b':' && i + 1 < n && p.byte_at(i + 1) == b':' {
                d = d + 1;
                i = i + 1;
            }
            i = i + 1;
        }
        return d;
    }
    fn emit_rel_prefix(self: &mut Self) {
        let d = self.module_depth();
        for i in 0..d {
            self.emit_str("../");
        }
    }
    fn emit_modpath_include(self: &mut Self, path: str) {
        self.emit_str("#include \"");
        self.emit_rel_prefix();
        let n = path.len();
        let mut i: usize = 0;
        while i < n {
            if path.byte_at(i) == b':' && i + 1 < n && path.byte_at(i + 1) == b':' {
                self.emit_str("/");
                i = i + 1;
            } else {
                self.emit_bytes((unsafe (path.ptr() + i)) as *const char, 1);
            }
            i = i + 1;
        }
        self.emit_str(".h\"\n");
    }
    fn type_mentions_builtin(self: &Self, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.type_mentions_builtin(y.as_data.elem);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            for i in 0..it.n {
                if self.type_mentions_builtin(it.args[i as usize]) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }
    fn cg_decl_is_interface_member(self: &Self, m: ModuleId, node: NodeId) bool {
        let a = self.mod_ast(m);
        let nk = unsafe (*a).at_const(node).kind;
        if nk == NodeKind::NODE_INTERFACE {
            return true;
        }
        if nk != NodeKind::NODE_FUNCTION {
            return false;
        }
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let ids = unsafe (*a).list(items);
        // CG-6: build module m's interface-member set once; queries become O(1) probes.
        if m as u32 < 64 {
            let bit = 1u64 << m as u64;
            if (self.ifm_built & bit) == 0 {
                let mp = (self as *const Codegen) as *mut Codegen;
                for i in 0..items.len {
                    let it = unsafe (*a).at_const(unsafe ids[i as usize]);
                    if it.kind == NodeKind::NODE_INTERFACE {
                        let ms = it.as_data.interface_def.items;
                        let mids = unsafe (*a).list(ms);
                        for j in 0..ms.len {
                            unsafe {
                                (*mp).ifm_set.insert(m as u64 << 32 | (unsafe mids[j as usize]) as u64, 1);
                            }
                        }
                    }
                }
                unsafe {
                    (*mp).ifm_built = self.ifm_built | bit;
                }
            }
            return switch self.ifm_set.get(&(m as u64 << 32 | node as u64)) {
                Some(_) => true,
                None => false,
            };
        }
        for i in 0..items.len {
            let it = unsafe (*a).at_const(unsafe ids[i as usize]);
            if it.kind == NodeKind::NODE_INTERFACE {
                let ms = it.as_data.interface_def.items;
                let mids = unsafe (*a).list(ms);
                for j in 0..ms.len {
                    if unsafe mids[j as usize] == node {
                        return true;
                    }
                }
            }
        }
        return false;
    }
    fn mark_layout_module(self: &Self, ft: TypeId, want: *mut bool, nmod: usize) {
        if ft == TYPE_NONE {
            return;
        }
        let mut cft = self.subst_resolve(ft);
        let mut y = *self.type_at(cft);
        while y.kind == TypeKind::TYPE_ARRAY {
            cft = y.as_data.elem;
            y = *self.type_at(cft);
        }
        let cur = self.cur_module();
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let mut bb: i32 = -1;
            if self.package != null {
                bb = unsafe (*self.package).builtin_of_decl(y.module, y.as_data.decl);
            }
            if y.module != cur && y.module as usize < nmod && bb < 0 {
                unsafe want[y.module as usize] = true;
            }
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let home = unsafe (*self.package).instance_home(unsafe &*self.cur_ast(), &it);
            if home != cur && home as usize < nmod {
                unsafe want[home as usize] = true;
            }
        }
    }
    fn mark_aggregate_layout(self: &Self, dn_id: NodeId, want: *mut bool, nmod: usize) {
        let ag = unsafe (*self.cur_ast()).at_const(dn_id).as_data.aggregate;
        let dk = unsafe (*self.cur_ast()).at_const(dn_id).kind;
        let ms = ag.members;
        let mids = unsafe (*self.cur_ast()).list(ms);
        for m in 0..ms.len {
            let mid = unsafe mids[m as usize];
            let mnk = unsafe (*self.cur_ast()).at_const(mid).kind;
            if dk == NodeKind::NODE_STRUCT && ag.is_tuple {
                self.mark_layout_module(unsafe (*self.cur_ast()).type_of(mid), want, nmod);
            } else if dk == NodeKind::NODE_STRUCT && mnk == NodeKind::NODE_FIELD {
                let fty = unsafe (*self.cur_ast()).at_const(mid).as_data.field.ty;
                self.mark_layout_module(unsafe (*self.cur_ast()).type_of(fty), want, nmod);
            } else if dk == NodeKind::NODE_ENUM && mnk == NodeKind::NODE_VARIANT {
                let payload = unsafe (*self.cur_ast()).at_const(mid).as_data.variant.payload;
                let plids = unsafe (*self.cur_ast()).list(payload);
                for k in 0..payload.len {
                    let pid = unsafe plids[k as usize];
                    let pfk = unsafe (*self.cur_ast()).at_const(pid).kind;
                    let tn = if pfk == NodeKind::NODE_FIELD {
                        unsafe (*self.cur_ast()).at_const(pid).as_data.field.ty;
                    } else {
                        pid;
                    };
                    self.mark_layout_module(unsafe (*self.cur_ast()).type_of(tn), want, nmod);
                }
            }
        }
    }
}

// ---- dyn trait objects: vtables + glue ----
type CgDefs8 = Array<DefId, 8>;

extend Codegen {
    // Transitive superinterface closure of (im, inode), itself first (BFS, deduped). The order is
    // load-bearing: vtable typedef fields and every positional __vtbl initializer iterate it.
    fn cg_dyn_closure(self: &Self, im: ModuleId, inode: NodeId, out: *mut DefId, cap: i32) i32 {
        unsafe out[0] = DefId { module: im, node: inode };
        let mut n: i32 = 1;
        let mut scan: i32 = 0;
        while scan < n {
            let cur = unsafe out[scan as usize];
            let ca = self.mod_ast(cur.module);
            if unsafe (*ca).at_const(cur.node).kind != NodeKind::NODE_INTERFACE {
                scan = scan + 1;
                continue;
            }
            let bs = unsafe (*ca).at_const(cur.node).as_data.interface_def.bounds;
            for b in 0..bs.len {
                let bd = unsafe (*ca).resolution_def(unsafe (*ca).list(bs)[b as usize]);
                if bd.node == NODE_NONE || unsafe (*self.mod_ast(bd.module)).at_const(bd.node).kind != NodeKind::NODE_INTERFACE {
                    continue;
                }
                let mut dup = false;
                for k in 0..n {
                    if unsafe out[k as usize].module == bd.module && unsafe out[k as usize].node == bd.node {
                        dup = true;
                    }
                }
                if !dup && n < cap {
                    unsafe out[n as usize] = bd;
                    n = n + 1;
                }
            }
            scan = scan + 1;
        }
        return n;
    }

    fn cg_dyn_method(self: &Self, im: ModuleId, m_id: NodeId) bool {
        let mf = unsafe (*self.mod_ast(im)).at_const(m_id).as_data.function;
        let mk = unsafe (*self.mod_ast(im)).at_const(m_id).kind;
        if mk != NodeKind::NODE_FUNCTION || mf.params.len == 0 {
            return false;
        }
        let p0 = unsafe (*self.mod_ast(im)).list(mf.params)[0];
        let p0name = unsafe (*self.mod_ast(im)).at_const(p0).as_data.parameter.name;
        return span_is(
            self.mod_src(im),
            unsafe (*self.mod_ast(im)).at_const(p0name).as_data.name.text,
            "self".ptr() as *const char,
        );
    }
    fn cg_dyn_ret(self: &mut Self, im: ModuleId, m_id: NodeId) TypeId {
        let rets = unsafe (*self.mod_ast(im)).at_const(m_id).as_data.function.returns;
        if rets.len != 1 {
            return TYPE_NONE;
        }
        let r0 = unsafe (*self.mod_ast(im)).list(rets)[0];
        let rn = unsafe (*self.mod_ast(im)).at_const(r0);
        let rtn = if rn.kind == NodeKind::NODE_PARAMETER {
            rn.as_data.parameter.ty;
        } else {
            r0;
        };
        let rt = unsafe (*self.mod_ast(im)).type_of(rtn);
        if rt == TYPE_NONE {
            return TYPE_NONE;
        }
        let rty = *unsafe (*self.mod_ast(im)).type_at(rt);
        if rty.kind == TypeKind::TYPE_BUILTIN && rty.as_data.builtin == BuiltinType::BT_VOID {
            return TYPE_NONE;
        }
        return unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(im), rt);
    }
    fn cg_dyn_target(self: &Self, sy: &Ty, tm: *mut ModuleId, td: *mut NodeId) bool {
        if sy.kind == TypeKind::TYPE_INSTANCE {
            unsafe *tm = unsafe (*self.cur_ast()).instance(sy.as_data.inst).module;
            unsafe *td = unsafe (*self.cur_ast()).instance(sy.as_data.inst).decl;
        } else if sy.kind == TypeKind::TYPE_STRUCT || sy.kind == TypeKind::TYPE_ENUM {
            unsafe *tm = sy.module;
            unsafe *td = sy.as_data.decl;
        } else if sy.kind == TypeKind::TYPE_BUILTIN && self.package != null && unsafe (*self.package).builtin_decl(
            sy.as_data.builtin,
        ) != NODE_NONE {
            unsafe *tm = unsafe (*self.package).core_module;
            unsafe *td = unsafe (*self.package).builtin_decl(sy.as_data.builtin);
        } else {
            return false;
        }
        return true;
    }
    fn cg_dynfn_ret(self: &mut Self, m: ModuleId, sig: NodeId) TypeId {
        let ft = unsafe (*self.mod_ast(m)).at_const(sig).as_data.function_type;
        if ft.returns.len != 1 {
            return TYPE_NONE;
        }
        let r0 = unsafe (*self.mod_ast(m)).list(ft.returns)[0];
        let rn = unsafe (*self.mod_ast(m)).at_const(r0);
        let rtn = if rn.kind == NodeKind::NODE_PARAMETER {
            rn.as_data.parameter.ty;
        } else {
            r0;
        };
        let rt = unsafe (*self.mod_ast(m)).type_of(rtn);
        if rt == TYPE_NONE {
            return TYPE_NONE;
        }
        let rty = *unsafe (*self.mod_ast(m)).type_at(rt);
        if rty.kind == TypeKind::TYPE_BUILTIN && rty.as_data.builtin == BuiltinType::BT_VOID {
            return TYPE_NONE;
        }
        return unsafe (*self.cur_ast()).reintern(unsafe &*self.mod_ast(m), rt);
    }
}

fn cg_int_range(b: BuiltinType, mn: *mut i64, mx: *mut i64) {
    if b == BuiltinType::BT_I8 {
        unsafe *mn = -128;
        unsafe *mx = 127;
    } else if b == BuiltinType::BT_I16 {
        unsafe *mn = -32768;
        unsafe *mx = 32767;
    } else if b == BuiltinType::BT_I32 {
        unsafe *mn = -2147483648;
        unsafe *mx = 2147483647;
    } else {
        unsafe *mn = (1 as u64 << 63) as i64;
        unsafe *mx = ((1 as u64 << 63) - 1) as i64;
    }
}

// ---- assert / format builtins ----
extend Codegen {
    fn cg_struct_name_is(self: &Self, y: &Ty, lit: *const char) bool {
        let mut m: ModuleId = 0;
        let mut decl: NodeId = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT {
            m = y.module;
            decl = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            m = it.module;
            decl = it.decl;
        } else {
            return false;
        }
        let anm = unsafe (*self.mod_ast(m)).at_const(decl).as_data.aggregate.name;
        return span_is(self.mod_src(m), unsafe (*self.mod_ast(m)).at_const(anm).as_data.name.text, lit);
    }
    fn cg_line_of(self: &Self, off: u32) u32 {
        // CG-7: asserts are emitted in source order, so resume counting from the last query;
        // a backwards query or a source swap resets the cursor.
        let mp = (self as *const Codegen) as *mut Codegen;
        if self.lc_src != self.source.ptr() || off < self.lc_off {
            unsafe {
                (*mp).lc_src = self.source.ptr();
                (*mp).lc_off = 0;
                (*mp).lc_line = 1;
            }
        }
        let mut line: u32 = self.lc_line;
        let mut i: u32 = self.lc_off;
        while i < off && i as usize < self.source.len() {
            if self.source[i as usize] == b'\n' {
                line = line + 1;
            }
            i = i + 1;
        }
        unsafe {
            (*mp).lc_off = i;
            (*mp).lc_line = line;
        }
        return line;
    }
    fn emit_pct_escaped(self: &mut Self, text: *const u8, len: usize) {
        for i in 0..len {
            let byte = unsafe text[i];
            if byte == b'%' {
                self.emit_str("%%");
            } else if byte == b'"' || byte == b'\\' {
                self.buf.push_byte(b'\\');
                self.buf.push_byte((byte as i32) as u8);
            } else if byte == b'\n' {
                self.emit_str("\\n");
            } else if byte < 0x20 as u8 {
                self.emit_octal_escape((byte as i32) as u32);
            } else {
                self.buf.push_byte((byte as i32) as u8);
            }
        }
    }
    fn cg_file(self: &mut Self) *const char {
        if self.package != null && self.cur_module() as usize < self.pkg_count() {
            if unsafe (*self.package).modules[self.cur_module() as usize].file.len() != 0 {
                return unsafe (*self.package).modules[self.cur_module() as usize].file.cstr();
            }
        }
        return "<src>".ptr() as *const char;
    }
    fn cg_assert_kind(self: &Self, id: NodeId) i32 {
        if self.package == null {
            return 0;
        }
        let callee = unsafe (*self.cur_ast()).at_const(id).as_data.call.callee;
        if unsafe (*self.cur_ast()).at_const(callee).kind != NodeKind::NODE_IDENTIFIER {
            return 0;
        }
        let d = unsafe (*self.cur_ast()).resolution_def(callee);
        if d.node == NODE_NONE || d.module as usize >= self.pkg_count() || !unsafe (*self.package).modules[d.module as usize].prelude {
            return 0;
        }
        if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return 0;
        }
        let fnamenode = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.name;
        let fnm = unsafe (*self.mod_ast(d.module)).at_const(fnamenode).as_data.name.text;
        let s = self.mod_src(d.module);
        if span_is(s, fnm, "assert".ptr() as *const char) {
            return 1;
        }
        if span_is(s, fnm, "assert_eq".ptr() as *const char) {
            return 2;
        }
        if span_is(s, fnm, "assert_ne".ptr() as *const char) {
            return 3;
        }
        return 0;
    }
    fn emit_assert_value_line(self: &mut Self, label: *const char, acc: *const char, y: Ty, base: TypeId) {
        self.buf.format_into("fprintf(stderr, \"  {} ", diag::cstr(label));
        if y.kind == TypeKind::TYPE_BUILTIN {
            let bt = y.as_data.builtin;
            if bt == BuiltinType::BT_BOOL {
                self.buf.format_into("%s\\n\", {} ? \"true\" : \"false\");\n", diag::cstr(acc));
                return;
            }
            if bt == BuiltinType::BT_CHAR {
                self.buf.format_into("'%c'\\n\", (int){});\n", diag::cstr(acc));
                return;
            }
            if bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE {
                self.buf.format_into("%lld\\n\", (long long){});\n", diag::cstr(acc));
                return;
            }
            if bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE {
                self.buf.format_into("%llu\\n\", (unsigned long long){});\n", diag::cstr(acc));
                return;
            }
            if bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 {
                self.buf.format_into("%g\\n\", (double){});\n", diag::cstr(acc));
                return;
            }
        }
        if self.cg_struct_name_is(&y, "str".ptr() as *const char) {
            self.buf.format_into(
                "\\\"%.*s\\\"\\n\", (int){}.len, (const char *){}.ptr);\n",
                diag::cstr(acc),
                diag::cstr(acc),
            );
            return;
        }
        if self.cg_struct_name_is(&y, "String".ptr() as *const char) {
            let mut sm = Buf200 {};
            self.render_type_id(base, "".ptr() as *const char, &mut sm[0], 200);
            self.buf.format_into(
                "\\\"%.*s\\\"\\n\", (int){}__as_str(&{}).len, (const char *){}__as_str(&{}).ptr);\n",
                diag::cstr(&sm[0]),
                diag::cstr(acc),
                diag::cstr(&sm[0]),
                diag::cstr(acc),
            );
            return;
        }
        self.emit_str("(value of a non-printable type)\\n\");\n");
    }
}

// A parsed `{...}` placeholder: `{:[fill][<^>][0][width][.prec][x|X|b]}`.
pub struct FmtSpec {
    pub ty: char,
    pub align: char,
    pub fill: u8,
    pub width: i32,
    pub prec: i32,
}

fn bt_is_numeric(b: BuiltinType) bool {
    let v = b as i32;
    return v >= BuiltinType::BT_I8 as i32 && v <= BuiltinType::BT_F64 as i32;
}
fn bt_is_signed_int(b: BuiltinType) bool {
    let v = b as i32;
    return v >= BuiltinType::BT_I8 as i32 && v <= BuiltinType::BT_ISIZE as i32;
}
fn bt_is_unsigned_int(b: BuiltinType) bool {
    let v = b as i32;
    return v >= BuiltinType::BT_U8 as i32 && v <= BuiltinType::BT_USIZE as i32;
}
fn bt_is_binfmt(b: BuiltinType) bool {
    let v = b as i32;
    return v >= BuiltinType::BT_CHAR as i32 && v <= BuiltinType::BT_USIZE as i32;
}
fn bt_unsigned_cast(b: BuiltinType) *const char {
    if b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 || b == BuiltinType::BT_CHAR {
        return "uint8_t".ptr() as *const char;
    }
    if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 {
        return "uint16_t".ptr() as *const char;
    }
    if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 {
        return "uint32_t".ptr() as *const char;
    }
    return "uint64_t".ptr() as *const char;
}

extend Codegen {
    fn fmt_arg_core(self: &mut Self, tb: *const char, arg: NodeId, sp: &FmtSpec, y: Ty, t: TypeId) bool {
        if sp.ty == 'x' as char || sp.ty == 'X' as char {
            let ud = if sp.ty == 'X' as char {
                "true".ptr() as *const char;
            } else {
                "false".ptr() as *const char;
            };
            if y.kind != TypeKind::TYPE_BUILTIN {
                return false;
            }
            let b = y.as_data.builtin;
            if bt_is_signed_int(b) {
                self.buf.format_into("String__Global__push_hex_i64(&{}, (int64_t)(", diag::cstr(tb));
                self.emit_expr(arg);
                self.buf.format_into("), {});\n", diag::cstr(ud));
                return true;
            }
            if bt_is_unsigned_int(b) || b == BuiltinType::BT_CHAR {
                self.buf.format_into("String__Global__push_hex(&{}, (uint64_t)(", diag::cstr(tb));
                self.emit_expr(arg);
                self.buf.format_into("), {});\n", diag::cstr(ud));
                return true;
            }
            return false;
        }
        if sp.ty == 'b' as char {
            if y.kind != TypeKind::TYPE_BUILTIN || !bt_is_binfmt(y.as_data.builtin) {
                return false;
            }
            self.buf.format_into(
                "String__Global__push_bin(&{}, (uint64_t)({})(",
                diag::cstr(tb),
                diag::cstr(bt_unsigned_cast(y.as_data.builtin)),
            );
            self.emit_expr(arg);
            self.emit_str("));\n");
            return true;
        }
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL {
                self.emit_str("if (");
                self.emit_expr(arg);
                self.buf.format_into(
                    ") String__Global__push_str(&{}, (str){{ .ptr = (const uint8_t*)\"true\", .len = 4 }});",
                    diag::cstr(tb),
                );
                self.buf.format_into(
                    " else String__Global__push_str(&{}, (str){{ .ptr = (const uint8_t*)\"false\", .len = 5 }});\n",
                    diag::cstr(tb),
                );
                return true;
            }
            if b == BuiltinType::BT_CHAR {
                self.buf.format_into("String__Global__push_byte(&{}, (uint8_t)(", diag::cstr(tb));
                self.emit_expr(arg);
                self.emit_str("));\n");
                return true;
            }
            if bt_is_signed_int(b) {
                self.buf.format_into("String__Global__push_i64(&{}, (int64_t)(", diag::cstr(tb));
                self.emit_expr(arg);
                self.emit_str("));\n");
                return true;
            }
            if bt_is_unsigned_int(b) {
                self.buf.format_into("String__Global__push_u64(&{}, (uint64_t)(", diag::cstr(tb));
                self.emit_expr(arg);
                self.emit_str("));\n");
                return true;
            }
            if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 {
                if sp.prec >= 0 {
                    self.buf.format_into("String__Global__push_f64_prec(&{}, (double)(", diag::cstr(tb));
                    self.emit_expr(arg);
                    self.buf.format_into("), {});\n", sp.prec);
                } else {
                    self.buf.format_into("String__Global__push_f64(&{}, (double)(", diag::cstr(tb));
                    self.emit_expr(arg);
                    self.emit_str("));\n");
                }
                return true;
            }
            return false;
        }
        if self.cg_struct_name_is(&y, "str".ptr() as *const char) {
            self.buf.format_into("String__Global__push_str(&{}, ", diag::cstr(tb));
            self.emit_expr(arg);
            self.emit_str(");\n");
            return true;
        }
        if self.cg_struct_name_is(&y, "String".ptr() as *const char) {
            let mut sm = Buf200 {};
            self.render_type_id(t, "".ptr() as *const char, &mut sm[0], 200);
            let smp = (&sm[0]) as *const char;
            if self.is_lvalue(arg) {
                self.buf.format_into("String__Global__push_str(&{}, {}__as_str(&(", diag::cstr(tb), diag::cstr(smp));
                self.emit_expr(arg);
                self.emit_str(")));\n");
            } else {
                let mut tmp = Buf32 {};
                self.fresh(&mut tmp[0], 32);
                let tmpp = (&tmp[0]) as *const char;
                self.buf.format_into("{{ {} {} = ", diag::cstr(smp), diag::cstr(tmpp));
                self.emit_expr(arg);
                self.buf.format_into(
                    "; String__Global__push_str(&{}, {}__as_str(&{})); {}__free(&{}); }}\n",
                    diag::cstr(tb),
                    diag::cstr(smp),
                    diag::cstr(tmpp),
                    diag::cstr(smp),
                    diag::cstr(tmpp),
                );
            }
            return true;
        }
        return false;
    }
    fn emit_format_arg(self: &mut Self, f: *const char, arg: NodeId, sp: &FmtSpec) bool {
        let t = self.subst_resolve(unsafe (*self.cur_ast()).type_of(arg));
        let y = *self.type_at(t);
        if sp.prec >= 0 && !(y.kind == TypeKind::TYPE_BUILTIN && (y.as_data.builtin == BuiltinType::BT_F32 || y.as_data.builtin == BuiltinType::BT_F64)) {
            return false;
        }
        if sp.width <= 0 {
            return self.fmt_arg_core(f, arg, sp, y, t);
        }
        let numeric = y.kind == TypeKind::TYPE_BUILTIN && bt_is_numeric(y.as_data.builtin);
        let align = if sp.align == '<' as char {
            0;
        } else if sp.align == '^' as char {
            2;
        } else if sp.align == '>' as char {
            1;
        } else if numeric {
            1;
        } else {
            0;
        };
        let fill = if sp.fill != 0 as u8 {
            sp.fill;
        } else {
            b' ';
        };
        if self.cg_struct_name_is(&y, "str".ptr() as *const char) {
            self.buf.format_into("String__Global__push_padded(&{}, ", diag::cstr(f));
            self.emit_expr(arg);
            self.buf.format_into(", {}, {}, {});\n", sp.width, fill as u32, align);
            return true;
        }
        let mut tmp = Buf32 {};
        self.fresh(&mut tmp[0], 32);
        let tp = (&tmp[0]) as *const char;
        self.buf.format_into("{{ size_t {} = String__Global__len(&{});\n", diag::cstr(tp), diag::cstr(f));
        if !self.fmt_arg_core(f, arg, sp, y, t) {
            self.emit_str("}\n");
            return false;
        }
        self.buf.format_into(
            "String__Global__pad_at(&{}, {}, {}, {}, {});\n",
            diag::cstr(f),
            diag::cstr(tp),
            sp.width,
            fill as u32,
            align,
        );
        self.emit_str("}\n");
        return true;
    }
    fn emit_fmt_cstr(self: &mut Self, a: usize, b: usize) {
        let src = self.source;
        self.emit_str("\"");
        let mut i = a;
        while i < b {
            if (src[i] == b'{' || src[i] == b'}') && i + 1 < b && src[i + 1] == src[i] {
                self.buf.push_byte((src[i] as i32) as u8);
                i = i + 2;
                continue;
            }
            if src[i] == b'\\' && i + 1 < b {
                let e = src[i + 1];
                if e == b'x' && i + 3 < b {
                    let v = (hex_val(src[i + 2]) << 4 | hex_val(src[i + 3])) & 0xFF;
                    self.emit_octal_escape(v as u32);
                    i = i + 4;
                } else if e == b'0' {
                    self.emit_str("\\000");
                    i = i + 2;
                } else {
                    self.buf.push_byte(b'\\');
                    self.buf.push_byte((e as i32) as u8);
                    i = i + 2;
                }
                continue;
            }
            self.buf.push_byte((src[i] as i32) as u8);
            i = i + 1;
        }
        self.emit_str("\"");
    }
    fn emit_fmt_raw_cstr(self: &mut Self, a: usize, b: usize) {
        let src = self.source;
        self.emit_str("\"");
        let mut i = a;
        while i < b {
            if (src[i] == b'{' || src[i] == b'}') && i + 1 < b && src[i + 1] == src[i] {
                self.buf.push_byte((src[i] as i32) as u8);
                i = i + 2;
                continue;
            }
            let byte = src[i];
            i = i + 1;
            if byte == b'"' || byte == b'\\' {
                self.buf.push_byte(b'\\');
                self.buf.push_byte((byte as i32) as u8);
            } else if byte == b'\n' {
                self.emit_str("\\n");
            } else if byte < 0x20 as u8 {
                self.emit_octal_escape((byte as i32) as u32);
            } else {
                self.buf.push_byte((byte as i32) as u8);
            }
        }
        self.emit_str("\"");
    }
    // The escaped literal for [from, to), with an optional trailing "\n" folded in as an
    // adjacent C string literal (concatenated by the C compiler, so sizeof sees it too).
    fn emit_fmt_lit(self: &mut Self, is_raw: bool, from: usize, to: usize, nl: bool) {
        if is_raw {
            self.emit_fmt_raw_cstr(from, to);
        } else {
            self.emit_fmt_cstr(from, to);
        }
        if nl {
            self.emit_str(" \"\\n\"");
        }
    }
    fn emit_fmt_seg(self: &mut Self, f: *const char, is_raw: bool, from: usize, to: usize, nl: bool) {
        self.buf.format_into("String__Global__push_str(&{}, (str){{ .ptr = (const uint8_t*)", diag::cstr(f));
        self.emit_fmt_lit(is_raw, from, to, nl);
        self.emit_str(", .len = sizeof(");
        self.emit_fmt_lit(is_raw, from, to, nl);
        self.emit_str(") - 1 });\n");
    }
}

// ---- @emit_macro C-reuse templates ----
extend Codegen {
    fn macro_stem(self: &Self, m: ModuleId, aggregate_name: NodeId, out: *mut char, cap: usize) {
        let n = self.render_qualified(m, aggregate_name, out, cap);
        let mut i: usize = 0;
        while i < n && i < cap {
            let ch = unsafe out[i];
            if ch >= 'a' as char && ch <= 'z' as char {
                unsafe out[i] = (ch as i32 - 32) as char;
            } else if !(ch >= 'A' as char && ch <= 'Z' as char || ch >= '0' as char && ch <= '9' as char) {
                unsafe out[i] = '_' as char;
            }
            i = i + 1;
        }
    }
    fn macro_finish(self: &mut Self, start: usize) {
        if self.buf.len() <= start {
            return;
        }
        let mut endp = self.buf.len();
        while endp > start && unsafe self.buf.as_ptr()[endp - 1] == b'\n' {
            endp = endp - 1;
        }
        let nlen = endp - start;
        let tmp = (unsafe stdlib::malloc(nlen)) as *mut char;
        if tmp == null {
            diag::oom();
        }
        unsafe cstring::memcpy(tmp, self.buf.as_ptr() + start, nlen);
        self.buf.truncate(start);
        for i in 0..nlen {
            let ch = unsafe tmp[i];
            if ch == '\n' as char {
                self.emit_bytes(" \\\n".ptr() as *const char, 3);
            } else if ch == CG_PASTE {
                self.emit_bytes("##".ptr() as *const char, 2);
            } else {
                self.emit_bytes(unsafe (tmp + i), 1);
            }
        }
        self.emit_bytes("\n".ptr() as *const char, 1);
        unsafe stdlib::free(tmp);
    }
    fn emit_generic_macro_methods(self: &mut Self, declId: NodeId, define: bool) {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 {
                continue;
            }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != declId {
                continue;
            }
            if ed.interface_type != NODE_NONE {
                continue;
            }
            let mids = unsafe (*self.cur_ast()).list(ed.items);
            for j in 0..ed.items.len {
                let mid = unsafe mids[j as usize];
                let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
                let mk = unsafe (*self.cur_ast()).at_const(mid).kind;
                if mk != NodeKind::NODE_FUNCTION || mf.generics.len != 0 || mf.returns.len > 1 {
                    continue;
                }
                if define && mf.body == NODE_NONE {
                    continue;
                }
                let mut nm = Buf320 {};
                let mut at = bappend(&mut nm[0], 320, 0, "NAME".ptr() as *const char);
                nm[at] = CG_PASTE;
                at = at + 1;
                at = bappend(&mut nm[0], 320, at, "__".ptr() as *const char);
                let mnsp = self.name_span(mf.name);
                self.render_ident(mnsp, unsafe ((&mut nm[0]) as *mut char + at), 320 - at);
                self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, define, &nm[0], false);
            }
        }
    }
    fn conformance_tag(self: &Self, extend_id: NodeId, out: *mut char, cap: usize) usize {
        let it = unsafe (*self.cur_ast()).resolution_def(
            unsafe (*self.cur_ast()).at_const(extend_id).as_data.extend_def.interface_type,
        );
        let at = bappend(out, cap, 0, "as_".ptr() as *const char);
        if it.node == NODE_NONE {
            return at;
        }
        let trname = unsafe (*self.mod_ast(it.module)).at_const(it.node).as_data.interface_def.name;
        let sp = unsafe (*self.mod_ast(it.module)).at_const(trname).as_data.name.text;
        let room = if cap > at {
            cap - at;
        } else {
            0 as usize;
        };
        return at + render_ident_src(self.mod_src(it.module), sp, unsafe (out + at), room);
    }
    fn emit_generic_conformance_macro(self: &mut Self, declId: NodeId, implId: NodeId, define: bool) {
        let dn_name = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.name;
        let mut stem = Buf160 {};
        self.macro_stem(self.cur_module(), dn_name, &mut stem[0], 160);
        let mut tag = Buf128 {};
        self.conformance_tag(implId, &mut tag[0], 128);
        let word = if define {
            "DEFINE".ptr() as *const char;
        } else {
            "DECLARE".ptr() as *const char;
        };
        self.buf.format_into("#define {}_{}_{}(", diag::cstr(&stem[0]), diag::cstr(&tag[0]), diag::cstr(word));
        let gens = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        for i in 0..gens.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe gids[i as usize], &mut p[0], 64);
            self.buf.format_into("{}, _SCM_{}, ", diag::cstr(&p[0]), diag::cstr(&p[0]));
        }
        self.emit_str("NAME) ");
        self.macro_mode = true;
        self.macro_self = declId;
        self.macro_self_mod = self.cur_module();
        self.nsubst = 0;
        let start = self.buf.len();
        let mids = unsafe (*self.cur_ast()).list(unsafe (*self.cur_ast()).at_const(implId).as_data.extend_def.items);
        let msn = unsafe (*self.cur_ast()).at_const(implId).as_data.extend_def.items.len;
        for j in 0..msn {
            let mid = unsafe mids[j as usize];
            let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
            let mk = unsafe (*self.cur_ast()).at_const(mid).kind;
            if mk != NodeKind::NODE_FUNCTION || mf.generics.len != 0 || mf.returns.len > 1 {
                continue;
            }
            if define && mf.body == NODE_NONE {
                continue;
            }
            let mut nm = Buf320 {};
            let mut at = bappend(&mut nm[0], 320, 0, "NAME".ptr() as *const char);
            nm[at] = CG_PASTE;
            at = at + 1;
            at = bappend(&mut nm[0], 320, at, "__".ptr() as *const char);
            let mnsp = self.name_span(mf.name);
            self.render_ident(mnsp, unsafe ((&mut nm[0]) as *mut char + at), 320 - at);
            self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, define, &nm[0], false);
        }
        self.macro_mode = false;
        self.macro_self = NODE_NONE;
        self.macro_finish(start);
        self.emit_str("\n");
    }
    fn emit_generic_conformance_macros(self: &mut Self, declId: NodeId) {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 || ed.interface_type == NODE_NONE {
                continue;
            }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != declId {
                continue;
            }
            self.emit_generic_conformance_macro(declId, nid, false);
            self.emit_generic_conformance_macro(declId, nid, true);
        }
    }
    fn emit_generic_macro(self: &mut Self, declId: NodeId, define: bool) {
        let dn_name = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.name;
        let dn_kind = unsafe (*self.cur_ast()).at_const(declId).kind;
        let mut stem = Buf160 {};
        self.macro_stem(self.cur_module(), dn_name, &mut stem[0], 160);
        let gens = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        let word = if define {
            "DEFINE".ptr() as *const char;
        } else {
            "DECLARE".ptr() as *const char;
        };
        self.buf.format_into("#define {}_{}(", diag::cstr(&stem[0]), diag::cstr(word));
        for i in 0..gens.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe gids[i as usize], &mut p[0], 64);
            self.buf.format_into("{}, _SCM_{}, ", diag::cstr(&p[0]), diag::cstr(&p[0]));
        }
        self.emit_str("NAME) ");
        self.macro_mode = true;
        self.macro_self = declId;
        self.macro_self_mod = self.cur_module();
        self.nsubst = 0;
        let start = self.buf.len();
        if !define {
            if dn_kind == NodeKind::NODE_STRUCT {
                let kw = agg_kw(unsafe (*self.cur_ast()).at_const(declId));
                self.buf.format_into("typedef {} NAME NAME;\n", diag::cstr(kw));
                self.buf.format_into("{} NAME {{\n", diag::cstr(kw));
                self.depth = self.depth + 1;
                let fs = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.members;
                let fids = unsafe (*self.cur_ast()).list(fs);
                for jj in 0..fs.len {
                    let f = unsafe (*self.cur_ast()).at_const(unsafe fids[jj as usize]).as_data.field;
                    let mut fnm = Buf128 {};
                    let fnsp = self.name_span(f.name);
                    self.render_ident(fnsp, &mut fnm[0], 128);
                    let mut dd = Buf256 {};
                    self.render_type_node(f.ty, &fnm[0], &mut dd[0], 256);
                    self.emit_indent();
                    self.emit_cstr(&dd[0]);
                    self.emit_str(";\n");
                }
                self.depth = self.depth - 1;
                self.emit_str("};\n");
            } else if self.aggregate_has_payload(declId) {
                self.emit_str("typedef struct NAME NAME;\n");
                self.emit_str("struct NAME {\n");
                self.emit_enum_struct_body(declId);
                self.emit_str("};\n");
            } else {
                self.emit_str("typedef ");
                self.emit_local_type_name(dn_name);
                self.emit_str(" NAME;\n");
            }
        }
        self.emit_generic_macro_methods(declId, define);
        self.macro_mode = false;
        self.macro_self = NODE_NONE;
        self.macro_finish(start);
        self.emit_str("\n");
    }
    fn macro_method_name(self: &Self, methodId: NodeId, out: *mut char, cap: usize) {
        let mnnode = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.name;
        let mnsp = self.name_span(mnnode);
        let mut at = bappend(out, cap, 0, "NAME".ptr() as *const char);
        if at < cap {
            unsafe out[at] = CG_PASTE;
            at = at + 1;
        }
        at = bappend(out, cap, at, "__".ptr() as *const char);
        at = at + self.render_ident(mnsp, unsafe (out + at), cap - at);
        at = bappend(out, cap, at, "__".ptr() as *const char);
        let mg = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.generics;
        let mgids = unsafe (*self.cur_ast()).list(mg);
        for k in 0..mg.len {
            if k != 0 {
                if at < cap {
                    unsafe out[at] = CG_PASTE;
                    at = at + 1;
                }
                at = bappend(out, cap, at, "__".ptr() as *const char);
            }
            if at < cap {
                unsafe out[at] = CG_PASTE;
                at = at + 1;
            }
            at = bappend(out, cap, at, "_SCM_".ptr() as *const char);
            at = at + self.render_macro_param(self.cur_module(), unsafe mgids[k as usize], unsafe (out + at), cap - at);
        }
    }
    fn emit_generic_method_macro(self: &mut Self, declId: NodeId, methodId: NodeId, define: bool) {
        let dn_name = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.name;
        let mut stem = Buf160 {};
        self.macro_stem(self.cur_module(), dn_name, &mut stem[0], 160);
        let mnnode = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.name;
        let mut mnm = Buf64 {};
        let mnsp = self.name_span(mnnode);
        self.render_ident(mnsp, &mut mnm[0], 64);
        let word = if define {
            "DEFINE".ptr() as *const char;
        } else {
            "DECLARE".ptr() as *const char;
        };
        self.buf.format_into("#define {}_{}_{}(", diag::cstr(&stem[0]), diag::cstr(&mnm[0]), diag::cstr(word));
        let gens = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        for i in 0..gens.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe gids[i as usize], &mut p[0], 64);
            self.buf.format_into("{}, _SCM_{}, ", diag::cstr(&p[0]), diag::cstr(&p[0]));
        }
        self.emit_str("NAME");
        let mg = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.generics;
        let mgids = unsafe (*self.cur_ast()).list(mg);
        for k in 0..mg.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe mgids[k as usize], &mut p[0], 64);
            self.buf.format_into(", {}, _SCM_{}", diag::cstr(&p[0]), diag::cstr(&p[0]));
        }
        self.emit_str(") ");
        self.macro_mode = true;
        self.macro_self = declId;
        self.macro_self_mod = self.cur_module();
        self.nsubst = 0;
        let start = self.buf.len();
        let mut ov = Buf400 {};
        self.macro_method_name(methodId, &mut ov[0], 400);
        self.emit_function(methodId, DefId { module: 0, node: NODE_NONE }, false, define, &ov[0], false);
        self.macro_mode = false;
        self.macro_self = NODE_NONE;
        self.macro_finish(start);
        self.emit_str("\n");
    }
    fn emit_generic_method_macros(self: &mut Self, declId: NodeId) {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        for i in 0..items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 {
                continue;
            }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != declId {
                continue;
            }
            let mids = unsafe (*self.cur_ast()).list(ed.items);
            for j in 0..ed.items.len {
                let mid = unsafe mids[j as usize];
                let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
                let mk = unsafe (*self.cur_ast()).at_const(mid).kind;
                if mk == NodeKind::NODE_FUNCTION && mf.generics.len != 0 && mf.returns.len <= 1 {
                    self.emit_generic_method_macro(declId, mid, false);
                    self.emit_generic_method_macro(declId, mid, true);
                }
            }
        }
    }
}
