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
    fn vsnprintf(buf: *mut char, n: usize, fmt: *const char, ap: va_list) i32;
    fn va_copy(dst: va_list, src: va_list) void;
    fn strtoull(s: *const char, endptr: *mut *mut char, base: i32) u64;
    fn strtol(s: *const char, endptr: *mut *mut char, base: i32) i64;
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
"#.ptr as *const char;
}

// Builtin names (for matching unresolved type paths) and their C spellings, indexed by BuiltinType.
fn builtin_c(b: BuiltinType) *const char {
    let i = b as i32;
    if i == 0 { return "bool".ptr as *const char; }
    if i == 1 { return "char".ptr as *const char; }
    if i == 2 { return "int8_t".ptr as *const char; }
    if i == 3 { return "int16_t".ptr as *const char; }
    if i == 4 { return "int32_t".ptr as *const char; }
    if i == 5 { return "int64_t".ptr as *const char; }
    if i == 6 { return "intptr_t".ptr as *const char; }
    if i == 7 { return "uint8_t".ptr as *const char; }
    if i == 8 { return "uint16_t".ptr as *const char; }
    if i == 9 { return "uint32_t".ptr as *const char; }
    if i == 10 { return "uint64_t".ptr as *const char; }
    if i == 11 { return "size_t".ptr as *const char; }
    if i == 12 { return "float".ptr as *const char; }
    if i == 13 { return "double".ptr as *const char; }
    if i == 14 { return "float _Complex".ptr as *const char; }
    if i == 15 { return "double _Complex".ptr as *const char; }
    if i == 16 { return "va_list".ptr as *const char; }
    return "void".ptr as *const char;
}

// which-set for prototype emission
pub const PROTO_ALL: i32 = 0;
pub const PROTO_PUBLIC: i32 = 1;
pub const PROTO_PRIVATE: i32 = 2;

pub const CG_PASTE: char = 1 as char;

// ---- nested record types ----
pub struct CgSubst { pub param: DefId, pub concrete: TypeId }
pub struct CgInst { pub func: DefId, pub n: u8, pub args: [TypeId; 4] }
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
pub struct Buf32 { pub b: [char; 32] }
pub struct Buf64 { pub b: [char; 64] }
pub struct Buf128 { pub b: [char; 128] }
pub struct Buf160 { pub b: [char; 160] }
pub struct Buf256 { pub b: [char; 256] }
pub struct Buf512 { pub b: [char; 512] }

pub struct Codegen {
    pub ast: *mut Ast,
    pub source: *const u8,
    pub len: usize,
    pub buf: *mut char,
    pub buf_len: usize,
    pub buf_cap: usize,
    pub enum_of_variant: Map<u32, u32>,
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

extend Codegen {
    pub fn new(ast: *mut Ast, source: *const char, len: usize, package: *mut loader::Package) Codegen {
        let mut user_mods: usize = 0;
        if package != null {
            let mut i: usize = 0;
            while i < unsafe (*package).modules.len() { if !unsafe (*package).modules.at(i).prelude { user_mods = user_mods + 1; } i = i + 1; }
        }
        let mangle = user_mods > 1;
        let cap = len * 4 + 4096;
        let buf = unsafe stdlib::malloc(cap) as *mut char;
        if buf == null { diag::oom(); }
        // Fixed-array fields are omitted -> partial init zero-fills them (NODE_NONE == 0).
        return Codegen {
            ast: ast,
            source: source as *const u8,
            len: len,
            buf: buf,
            buf_cap: cap,
            enum_of_variant: Map::<u32, u32>::new(),
            package: package,
            mangle: mangle,
            multifile: mangle,
            errors: diag::Errors::new(),
        };
    }

    pub fn take_ast(self: &mut Self) *mut Ast { return self.ast; }

    // The Ast is borrowed (not owned); free only what codegen allocated itself.
    pub fn free(self: &mut Self) void {
        if self.buf != null { unsafe stdlib::free(self.buf as *mut void); }
        self.enum_of_variant.free();
        self.errors.free();
        if self.type_state != null { unsafe stdlib::free(self.type_state as *mut void); }
        if self.inst_emit_state != null { unsafe stdlib::free(self.inst_emit_state as *mut void); }
    }

    pub fn has_errors(self: &Self) bool { return self.errors.has_errors(); }
    pub fn log_errors(self: &Self) void { self.errors.log(); }
    pub fn set_multifile(self: &mut Self, on: bool) void { self.multifile = on; }
    pub fn set_test_info(self: &mut Self, ti: *const CgTestInfo) void { self.test = unsafe *ti; }

    // ---- module accessors ----
    fn cur_ast(self: &Self) *mut Ast { return self.ast; }
    fn mod_ast(self: &Self, m: ModuleId) *mut Ast {
        if self.package != null && m != unsafe (*self.ast).module {
            return unsafe ((&mut (*self.package).modules.index_mut(m as usize).ast) as *mut Ast);
        }
        return self.ast;
    }
    fn mod_src(self: &Self, m: ModuleId) *const u8 {
        if self.package != null && m != unsafe (*self.ast).module {
            return unsafe (*self.package).modules.at(m as usize).source as *const u8;
        }
        return self.source;
    }
    fn pkg_count(self: &Self) usize {
        if self.package == null { return 0; }
        return unsafe (*self.package).modules.len();
    }
    fn ceval(self: &Self) *mut ce::ConstEval {
        if self.package == null { return null; }
        return unsafe (*self.package).ceval as *mut ce::ConstEval;
    }
    fn cur_module(self: &Self) ModuleId { return unsafe (*self.ast).module; }
    fn type_at(self: &Self, x: TypeId) &Ty { return unsafe (*self.cur_ast()).type_at(x); }

    // `<mod>__closure_<nodeid>`: a hoisted closure's C symbol.
    fn closure_sym_in(self: &Self, m: ModuleId, id: NodeId, out: *mut char, cap: usize) void {
        let mut k = self.render_modpfx(m, out, cap);
        k = bappend(out, cap, k, "closure_".ptr as *const char);
        let mut idb = Buf32 {};
        unsafe stdio::snprintf((&mut idb.b[0]) as *mut char, 16, "%u".ptr as *const char, id);
        bappend(out, cap, k, (&idb.b[0]) as *const char);
    }
    fn closure_name(self: &Self, id: NodeId, out: *mut char, cap: usize) void {
        self.closure_sym_in(self.cur_module(), id, out, cap);
    }

    // ---- low-level output buffer ----
    fn emit_reserve(self: &mut Self, extra: usize) void {
        if self.buf_len + extra <= self.buf_cap { return; }
        let mut cap = self.buf_cap;
        if cap == 0 { cap = 4096; }
        while cap < self.buf_len + extra { cap = cap * 2; }
        let nb = unsafe stdlib::realloc(self.buf as *mut void, cap) as *mut char;
        if nb == null { diag::oom(); }
        self.buf = nb;
        self.buf_cap = cap;
    }
    fn emit_bytes(self: &mut Self, p: *const char, n: usize) void {
        self.emit_reserve(n);
        unsafe cstring::memcpy((self.buf + self.buf_len) as *mut void, p as *const void, n);
        self.buf_len = self.buf_len + n;
    }
    fn emit_cstr(self: &mut Self, text: *const char) void {
        self.emit_bytes(text, unsafe cstring::strlen(text));
    }
    fn vemit(self: &mut Self, fmt: *const char, mut args: va_list) void {
        let mut copy = args;
        unsafe va_copy(copy, args);
        let avail = self.buf_cap - self.buf_len;
        let n = unsafe vsnprintf((self.buf + self.buf_len) as *mut char, avail, fmt, copy);
        va_end(copy);
        if n > 0 {
            if (n as usize) >= avail {
                self.emit_reserve((n as usize) + 1);
                unsafe vsnprintf((self.buf + self.buf_len) as *mut char, (n as usize) + 1, fmt, args);
            }
            self.buf_len = self.buf_len + (n as usize);
        }
    }
    fn emit(self: &mut Self, fmt: *const char, ...) void {
        if unsafe cstring::strchr(fmt, '%' as i32) == null { self.emit_cstr(fmt); return; }
        let mut args: va_list;
        va_start(args, fmt);
        self.vemit(fmt, args);
        va_end(args);
    }
    fn emit_indent(self: &mut Self) void {
        let mut n = self.depth * 2;
        while n != 0 {
            let mut k = n;
            if k > 32 { k = 32; }
            self.emit_bytes("                                ".ptr as *const char, k as usize);
            n = n - k;
        }
    }
    fn emit_paste(self: &mut Self) void {
        if self.macro_mode { let p = CG_PASTE; self.emit_bytes((&p) as *const char, 1); }
    }

    fn fresh(self: &mut Self, buf: *mut char, cap: usize) void {
        unsafe stdio::snprintf(buf, cap, "__sc%u".ptr as *const char, self.tmp);
        self.tmp = self.tmp + 1;
    }

    fn name_span(self: &Self, name_node: NodeId) tok::Span {
        return unsafe (*self.ast).at_const(name_node).as_data.name.text;
    }
    fn name_span_in(self: &Self, m: ModuleId, name_node: NodeId) tok::Span {
        return unsafe (*self.mod_ast(m)).at_const(name_node).as_data.name.text;
    }
    fn emit_span(self: &mut Self, s: tok::Span) void {
        self.emit_bytes(unsafe (self.source + s.start as usize) as *const char, (s.end - s.start) as usize);
    }
    fn emit_ident(self: &mut Self, s: tok::Span) void {
        self.emit_span(s);
        if is_c_keyword(self.source, s) { self.emit_bytes("_".ptr as *const char, 1); }
    }
    fn render_ident(self: &Self, s: tok::Span, buf: *mut char, cap: usize) usize {
        return render_ident_src(self.source, s, buf, cap);
    }

    fn render_modpfx(self: &Self, m: ModuleId, buf: *mut char, cap: usize) usize {
        if cap != 0 { unsafe buf[0] = 0 as char; }
        if !self.mangle { return 0; }
        if unsafe (*self.package).modules.at(m as usize).prelude { return 0; }
        let path = unsafe (*self.package).modules.at(m as usize).path;
        let mut at: usize = 0;
        let mut i: usize = 0;
        while unsafe path[i] != 0 as char {
            if unsafe path[i] == ':' as char && unsafe path[i + 1] == ':' as char {
                i = i + 1;
                if at + 2 < cap { unsafe buf[at] = '_' as char; unsafe buf[at + 1] = '_' as char; }
                at = at + 2;
            } else {
                if at + 1 < cap { unsafe buf[at] = unsafe path[i]; }
                at = at + 1;
            }
            i = i + 1;
        }
        if at + 2 < cap { unsafe buf[at] = '_' as char; unsafe buf[at + 1] = '_' as char; }
        at = at + 2;
        if at < cap { unsafe buf[at] = 0 as char; }
        return at;
    }
    fn render_qualified(self: &Self, owner: ModuleId, name_node: NodeId, buf: *mut char, cap: usize) usize {
        let at = self.render_modpfx(owner, buf, cap);
        let mut off = at;
        if off >= cap { if cap != 0 { off = cap - 1; } else { off = 0; } }
        let s = unsafe (*self.mod_ast(owner)).at_const(name_node).as_data.name.text;
        let mut rem: usize = 0;
        if cap > off { rem = cap - off; }
        return at + render_ident_src(self.mod_src(owner), s, unsafe (buf + off) as *mut char, rem);
    }
    fn render_iface_stem(self: &Self, m: ModuleId, iface: NodeId, out: *mut char, cap: usize) usize {
        return self.render_qualified(m, unsafe (*self.mod_ast(m)).at_const(iface).as_data.interface_def.name, out, cap);
    }
    fn emit_ident_mod(self: &mut Self, m: ModuleId, name_node: NodeId) void {
        let mut nm = Buf160 {};
        render_ident_src(self.mod_src(m), unsafe (*self.mod_ast(m)).at_const(name_node).as_data.name.text, (&mut nm.b[0]) as *mut char, 160);
        self.emit_cstr((&nm.b[0]) as *const char);
    }
    fn emit_local_type_name(self: &mut Self, aggregate_name: NodeId) void {
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), aggregate_name, (&mut nm.b[0]) as *mut char, 160);
        self.emit_cstr((&nm.b[0]) as *const char);
    }
    fn build_enum_index(self: &mut Self) void {
        let a = self.cur_ast();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut i: u32 = 0;
        while i < items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = unsafe (*a).at_const(iid).as_data.aggregate.members;
                let mut j: u32 = 0;
                while j < ms.len { self.enum_of_variant.insert(unsafe ((*a).list(ms))[j as usize], iid); j = j + 1; }
            }
            i = i + 1;
        }
    }

    // ---- type mangling ----
    fn mangle_type(self: &Self, t: TypeId, out: *mut char, cap: usize) void {
        let ty = *self.type_at(t);
        if ty.kind == TypeKind::TYPE_BUILTIN {
            bappend(out, cap, 0, builtin_name(ty.as_data.builtin));
        } else if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM {
            self.render_qualified(ty.module, unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl).as_data.aggregate.name, out, cap);
        } else if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
            let mut e = Buf256 {};
            self.mangle_type(ty.as_data.elem, (&mut e.b[0]) as *mut char, 176);
            unsafe stdio::snprintf(out, cap, "ptr_%s".ptr as *const char, (&e.b[0]) as *const char);
        } else if ty.kind == TypeKind::TYPE_SLICE {
            let mut e = Buf256 {};
            self.mangle_type(ty.as_data.elem, (&mut e.b[0]) as *mut char, 176);
            unsafe stdio::snprintf(out, cap, "slice_%s".ptr as *const char, (&e.b[0]) as *const char);
        } else if ty.kind == TypeKind::TYPE_ARRAY {
            let mut e = Buf256 {};
            self.mangle_type(ty.as_data.arr.elem, (&mut e.b[0]) as *mut char, 176);
            if ty.as_data.arr.len != 0 { unsafe stdio::snprintf(out, cap, "arr%u_%s".ptr as *const char, ty.as_data.arr.len, (&e.b[0]) as *const char); }
            else { unsafe stdio::snprintf(out, cap, "arr_%s".ptr as *const char, (&e.b[0]) as *const char); }
        } else if ty.kind == TypeKind::TYPE_INSTANCE {
            self.inst_name(unsafe (*self.cur_ast()).instance(ty.as_data.inst), out, cap);
        } else if ty.kind == TypeKind::TYPE_FUNCTION {
            let fd = unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl);
            if fd.kind == NodeKind::NODE_FUNCTION { self.render_qualified(ty.module, fd.as_data.function.name, out, cap); }
            else if fd.kind == NodeKind::NODE_CLOSURE { self.closure_sym_in(ty.module, ty.as_data.decl, out, cap); }
            else { unsafe stdio::snprintf(out, cap, "fnt%u_%u".ptr as *const char, ty.module as u32, ty.as_data.decl); }
        } else if ty.kind == TypeKind::TYPE_DYN {
            let mut e = Buf256 {};
            self.dyn_stem(ty.module, ty.as_data.decl, (&mut e.b[0]) as *mut char, 176);
            let mut pfx = "dynb".ptr as *const char;
            if ty.qualifier == (TypeQualifier::TYPE_QUAL_MUT as u8) { pfx = "dynm".ptr as *const char; }
            else if ty.qualifier == (TypeQualifier::TYPE_QUAL_CONST as u8) { pfx = "dyn".ptr as *const char; }
            unsafe stdio::snprintf(out, cap, "%s_%s".ptr as *const char, pfx, (&e.b[0]) as *const char);
        } else {
            bappend(out, cap, 0, "v".ptr as *const char);
        }
    }
    fn dyn_stem(self: &Self, m: ModuleId, decl: NodeId, out: *mut char, cap: usize) void {
        let da = self.mod_ast(m);
        let fn2 = unsafe (*da).at_const(decl);
        if fn2.kind != NodeKind::NODE_FUNCTION_TYPE { self.render_iface_stem(m, decl, out, cap); return; }
        let mut at = bappend(out, cap, 0, "dynfn".ptr as *const char);
        let ftp = fn2.as_data.function_type;
        let mut i: u32 = 0;
        while i < ftp.params.len {
            let pid = unsafe ((*da).list(ftp.params))[i as usize];
            let mut e = Buf256 {};
            self.mangle_type(unsafe (*self.cur_ast()).reintern(unsafe (&*da), unsafe (*da).type_of(pid)), (&mut e.b[0]) as *mut char, 176);
            at = bappend(out, cap, at, "__".ptr as *const char);
            at = bappend(out, cap, at, (&e.b[0]) as *const char);
            i = i + 1;
        }
        if ftp.returns.len == 1 {
            let r0 = unsafe ((*da).list(ftp.returns))[0];
            let rn = unsafe (*da).at_const(r0);
            let tn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            let mut e = Buf256 {};
            self.mangle_type(unsafe (*self.cur_ast()).reintern(unsafe (&*da), unsafe (*da).type_of(tn)), (&mut e.b[0]) as *mut char, 176);
            at = bappend(out, cap, at, "__r_".ptr as *const char);
            bappend(out, cap, at, (&e.b[0]) as *const char);
        }
    }
    fn dyn_pair_stem(self: &Self, src: TypeId, im: ModuleId, iface: NodeId, out: *mut char, cap: usize) void {
        let mut sm = Buf256 {};
        let mut stem = Buf256 {};
        self.mangle_type(src, (&mut sm.b[0]) as *mut char, 176);
        self.dyn_stem(im, iface, (&mut stem.b[0]) as *mut char, 176);
        unsafe stdio::snprintf(out, cap, "%s__%s".ptr as *const char, (&sm.b[0]) as *const char, (&stem.b[0]) as *const char);
    }
    fn spec_name(self: &Self, fn2: DefId, args: *const TypeId, n: i32, out: *mut char, cap: usize) void {
        let mut at = self.render_qualified(fn2.module, unsafe (*self.mod_ast(fn2.module)).at_const(fn2.node).as_data.function.name, out, cap);
        let mut i: i32 = 0;
        while i < n {
            at = bappend(out, cap, at, "__".ptr as *const char);
            let mut e = Buf256 {};
            self.mangle_type(unsafe args[i as usize], (&mut e.b[0]) as *mut char, 176);
            at = bappend(out, cap, at, (&e.b[0]) as *const char);
            i = i + 1;
        }
    }
    fn render_macro_param(self: &Self, m: ModuleId, decl: NodeId, buf: *mut char, cap: usize) usize {
        let gp = unsafe (*self.mod_ast(m)).at_const(decl);
        return render_ident_src(self.mod_src(m), self.name_span_in(m, gp.as_data.generic_param.name), buf, cap);
    }
    fn macro_arg_token(self: &Self, arg: TypeId, out: *mut char, cap: usize) void {
        let y = *self.type_at(arg);
        if y.kind == TypeKind::TYPE_GENERIC {
            let at = bappend(out, cap, 0, "_SCM_".ptr as *const char);
            self.render_macro_param(y.module, y.as_data.decl, unsafe (out + at) as *mut char, cap - at);
            return;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let mut pfx = "ptr_".ptr as *const char;
            if y.kind == TypeKind::TYPE_SLICE { pfx = "slice_".ptr as *const char; }
            else if y.kind == TypeKind::TYPE_ARRAY { pfx = "arr_".ptr as *const char; }
            let mut at = bappend(out, cap, 0, pfx);
            if at < cap { unsafe out[at] = CG_PASTE; at = at + 1; }
            if at < cap { unsafe out[at] = 0 as char; }
            let mut rem: usize = 0;
            if cap > at { rem = cap - at; }
            self.macro_arg_token(y.as_data.elem, unsafe (out + at) as *mut char, rem);
            return;
        }
        self.mangle_type(arg, out, cap);
    }
    fn is_self_instance(self: &Self, it: &TyInstance) bool {
        if !self.macro_mode || it.decl != self.macro_self || it.module != self.macro_self_mod { return false; }
        let sa = self.mod_ast(self.macro_self_mod);
        let gens = unsafe (*sa).at_const(self.macro_self).as_data.aggregate.generics;
        if gens.len != (it.n as u32) { return false; }
        let mut i: u8 = 0;
        while i < it.n {
            let gid = unsafe ((*sa).list(gens))[i as usize];
            let y = self.type_at(it.args[i as usize]);
            if y.kind != TypeKind::TYPE_GENERIC || y.as_data.decl != gid || y.module != self.macro_self_mod { return false; }
            i = i + 1;
        }
        return true;
    }
    fn inst_name(self: &Self, it: &TyInstance, out: *mut char, cap: usize) void {
        if self.is_self_instance(&*it) { bappend(out, cap, 0, "NAME".ptr as *const char); return; }
        let mut at = self.render_qualified(it.module, unsafe (*self.mod_ast(it.module)).at_const(it.decl).as_data.aggregate.name, out, cap);
        let sent = CG_PASTE;
        let mut i: u8 = 0;
        while i < it.n {
            if self.macro_mode {
                if i != 0 { at = bappend(out, cap, at, (&sent) as *const char); }
                else { at = bappend(out, cap, at, "__".ptr as *const char); }
                if i != 0 { at = bappend(out, cap, at, "__".ptr as *const char); }
                else { at = bappend(out, cap, at, (&sent) as *const char); }
                if i != 0 { at = bappend(out, cap, at, (&sent) as *const char); }
                let mut e = Buf256 {};
                self.macro_arg_token(it.args[i as usize], (&mut e.b[0]) as *mut char, 176);
                at = bappend(out, cap, at, (&e.b[0]) as *const char);
            } else {
                at = bappend(out, cap, at, "__".ptr as *const char);
                let mut e = Buf256 {};
                self.mangle_type(self.subst_resolve(it.args[i as usize]), (&mut e.b[0]) as *mut char, 176);
                at = bappend(out, cap, at, (&e.b[0]) as *const char);
            }
            i = i + 1;
        }
    }

    // ---- monomorphization substitution ----
    fn subst_lookup(self: &Self, m: ModuleId, decl: NodeId) TypeId {
        let mut i: i32 = 0;
        while i < self.nsubst { if self.subst[i as usize].param.module == m && self.subst[i as usize].param.node == decl { return self.subst[i as usize].concrete; } i = i + 1; }
        return TYPE_NONE;
    }
    fn subst_resolve(self: &Self, t: TypeId) TypeId {
        if self.nsubst == 0 { return t; }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            let s = self.subst_lookup(y.module, y.as_data.decl);
            if s != TYPE_NONE { return s; }
            return t;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            let e = self.subst_resolve(y.as_data.elem);
            if e == y.as_data.elem { return t; }
            let mut nt = y;
            nt.as_data.elem = e;
            return unsafe (*self.cur_ast()).intern_type(nt);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let src = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut na = TyArgs4 {};
            let mut changed = false;
            let mut i: u8 = 0;
            while i < src.n { na.t[i as usize] = self.subst_resolve(src.args[i as usize]); if na.t[i as usize] != src.args[i as usize] { changed = true; } i = i + 1; }
            if changed { return unsafe (*self.cur_ast()).intern_instance(src.module, src.decl, (&na.t[0]) as *const TypeId, src.n); }
            return t;
        }
        return t;
    }
    fn type_is_concrete(self: &Self, t: TypeId) bool {
        let y = self.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC { return false; }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY { return self.type_is_concrete(y.as_data.elem); }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut i: u8 = 0;
            while i < it.n { if !self.type_is_concrete(it.args[i as usize]) { return false; } i = i + 1; }
            return true;
        }
        return true;
    }

    // ---- generic instantiation collection ----
    fn generic_call_target(self: &Self, callId: NodeId, args: *mut TypeId, n: *mut i32) DefId {
        unsafe *n = 0;
        let a = self.cur_ast();
        let call = unsafe (*a).at_const(callId);
        if call.kind != NodeKind::NODE_CALL { return DefId { module: 0, node: NODE_NONE }; }
        let callee = unsafe (*a).at_const(call.as_data.call.callee);
        let mut fn2 = DefId { module: 0, node: NODE_NONE };
        if callee.kind == NodeKind::NODE_GENERIC_SPECIALIZATION { fn2 = unsafe (*a).resolution_def(callee.as_data.specialization.expression); }
        else { fn2 = unsafe (*a).resolution_def(call.as_data.call.callee); }
        if fn2.node == NODE_NONE { return DefId { module: 0, node: NODE_NONE }; }
        let fnnode = unsafe (*self.mod_ast(fn2.module)).at_const(fn2.node);
        if fnnode.kind != NodeKind::NODE_FUNCTION || fnnode.as_data.function.generics.len == 0 { return DefId { module: 0, node: NODE_NONE }; }
        let mu = unsafe (*a).type_args(callId);
        if mu == null { return DefId { module: 0, node: NODE_NONE }; }
        let mut i: u8 = 0;
        while i < unsafe (*mu).n && unsafe *n < 4 { let k = unsafe *n; unsafe args[k as usize] = unsafe (*mu).args[i as usize]; unsafe *n = k + 1; i = i + 1; }
        return fn2;
    }
    fn record_inst(self: &mut Self, fn2: DefId, args: *const TypeId, n: i32, site: NodeId) void {
        let mut i: i32 = 0;
        while i < self.ninsts {
            if self.insts[i as usize].func.module == fn2.module && self.insts[i as usize].func.node == fn2.node && (self.insts[i as usize].n as i32) == n {
                let mut same = true;
                let mut j: i32 = 0;
                while j < n { if self.insts[i as usize].args[j as usize] != unsafe args[j as usize] { same = false; } j = j + 1; }
                if same { return; }
            }
            i = i + 1;
        }
        if self.ninsts >= 1024 {
            if !self.insts_overflow {
                self.insts_overflow = true;
                let sp = unsafe (*self.cur_ast()).at_const(site).span;
                self.errors.emitf(sp.start, sp.end - sp.start, "codegen: too many distinct generic instantiations in one module (max %d)".ptr as *const char, 1024);
            }
            return;
        }
        let k = self.ninsts;
        self.insts[k as usize].func = fn2;
        self.insts[k as usize].n = n as u8;
        let mut j: i32 = 0;
        while j < n { self.insts[k as usize].args[j as usize] = unsafe args[j as usize]; j = j + 1; }
        self.ninsts = k + 1;
    }
    fn collect_insts(self: &mut Self) void {
        self.ninsts = 0;
        let mut i: u32 = 1;
        while (i as usize) < unsafe (*self.cur_ast()).nodes.len() {
            if unsafe (*self.cur_ast()).at_const(i).kind == NodeKind::NODE_CALL {
                let mut args = TyArgs4 {};
                let mut n: i32 = 0;
                let fn2 = self.generic_call_target(i, (&mut args.t[0]) as *mut TypeId, (&mut n) as *mut i32);
                if fn2.node != NODE_NONE { self.record_inst(fn2, (&args.t[0]) as *const TypeId, n, i); }
            }
            i = i + 1;
        }
        self.expand_nested_insts();
    }
    fn expand_nested_insts(self: &mut Self) void {
        let mut i: i32 = 0;
        while i < self.ninsts {
            let fn2 = self.insts[i as usize].func;
            let fn_n = self.insts[i as usize].n;
            let mut fargs = TyArgs4 {};
            let mut k: u8 = 0;
            while k < fn_n { fargs.t[k as usize] = self.insts[i as usize].args[k as usize]; k = k + 1; }
            let foreign = fn2.module != self.cur_module();
            if foreign && (self.package == null || (fn2.module as usize) >= self.pkg_count()) { i = i + 1; continue; }
            let home = self.ast;
            let hsrc = self.source;
            let hlen = self.len;
            let mut oninst: usize = 0;
            if foreign {
                let owner = self.mod_ast(fn2.module);
                self.source = self.mod_src(fn2.module);
                self.len = unsafe (*self.package).modules.at(fn2.module as usize).source_len;
                self.borrowed = true;
                oninst = unsafe (*owner).instances.len();
                self.ast = owner;
                let mut kk: u8 = 0;
                while kk < fn_n { fargs.t[kk as usize] = unsafe (*self.cur_ast()).reintern(unsafe (&*home), fargs.t[kk as usize]); kk = kk + 1; }
            }
            let fnn = unsafe (*self.cur_ast()).at_const(fn2.node);
            let fsp = fnn.span;
            let gens = fnn.as_data.function.generics;
            self.nsubst = 0;
            let mut g: u32 = 0;
            while g < gens.len && g < (fn_n as u32) && self.nsubst < 16 {
                let gid = unsafe ((*self.cur_ast()).list(gens))[g as usize];
                let ns = self.nsubst;
                self.subst[ns as usize].param = DefId { module: fn2.module, node: gid };
                self.subst[ns as usize].concrete = fargs.t[g as usize];
                self.nsubst = ns + 1;
                g = g + 1;
            }
            let mut nid: u32 = 1;
            while (nid as usize) < unsafe (*self.cur_ast()).nodes.len() {
                let nn = unsafe (*self.cur_ast()).at_const(nid);
                if nn.kind != NodeKind::NODE_CALL || nn.span.start < fsp.start || nn.span.end > fsp.end { nid = nid + 1; continue; }
                let mut args = TyArgs4 {};
                let mut n: i32 = 0;
                let g2 = self.generic_call_target(nid, (&mut args.t[0]) as *mut TypeId, (&mut n) as *mut i32);
                if g2.node == NODE_NONE { nid = nid + 1; continue; }
                let mut concrete = true;
                let mut kk: i32 = 0;
                while kk < n {
                    args.t[kk as usize] = self.subst_resolve(args.t[kk as usize]);
                    if !self.type_is_concrete(args.t[kk as usize]) { concrete = false; }
                    if foreign { args.t[kk as usize] = unsafe (*home).reintern(unsafe (&*self.cur_ast()), args.t[kk as usize]); }
                    kk = kk + 1;
                }
                if concrete { self.record_inst(g2, (&args.t[0]) as *const TypeId, n, nid); }
                nid = nid + 1;
            }
            self.nsubst = 0;
            if foreign {
                unsafe (*self.cur_ast()).instances.truncate(oninst);
                self.borrowed = false;
                self.ast = home;
                self.source = hsrc;
                self.len = hlen;
            }
            i = i + 1;
        }
    }
}

extend Codegen {
    fn cg_alias_extended(self: &Self, m: ModuleId, aliasDecl: NodeId) bool {
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut i: u32 = 0;
        while i < items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.target_type != NODE_NONE {
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tg.module == m && tg.node == aliasDecl { return true; }
            }
            i = i + 1;
        }
        return false;
    }
    fn cg_fn_is_capturing(self: &Self, fy: &Ty) bool {
        if fy.kind != TypeKind::TYPE_FUNCTION { return false; }
        let fnn = unsafe (*self.mod_ast(fy.module)).at_const(fy.as_data.decl);
        return fnn.kind == NodeKind::NODE_CLOSURE && fnn.as_data.closure.captures.len != 0;
    }

    fn render_type_node(self: &mut Self, tn: NodeId, decl: *const char, out: *mut char, cap: usize) void {
        if tn == NODE_NONE { buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl); return; }
        let a = self.cur_ast();
        let n = *unsafe (*a).at_const(tn);
        let nk = n.kind;
        if nk == NodeKind::NODE_TYPE_PATH || nk == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*a).resolution_def(tn);
            if d.node != NODE_NONE {
                let nt = unsafe (*a).type_of(tn);
                if nt != TYPE_NONE {
                    let ntk = self.type_at(nt).kind;
                    if ntk == TypeKind::TYPE_INSTANCE || ntk == TypeKind::TYPE_DYN { self.render_type_id(nt, decl, out, cap); return; }
                }
                let mut bb: i32 = -1;
                if self.package != null { bb = unsafe (*self.package).builtin_of_decl(d.module, d.node); }
                if bb >= 0 { buf_join3(out, cap, builtin_c(bb as BuiltinType), sep(decl), decl); return; }
                let dn = *unsafe (*self.mod_ast(d.module)).at_const(d.node);
                if dn.kind == NodeKind::NODE_STRUCT || dn.kind == NodeKind::NODE_ENUM {
                    let mut nm = Buf256 {};
                    self.render_qualified(d.module, dn.as_data.aggregate.name, (&mut nm.b[0]) as *mut char, 160);
                    buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS && dn.as_data.type_alias.ty == NODE_NONE {
                    let mut nm = Buf256 {};
                    render_ident_src(self.mod_src(d.module), unsafe (*self.mod_ast(d.module)).at_const(dn.as_data.type_alias.name).as_data.name.text, (&mut nm.b[0]) as *mut char, 160);
                    buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS && dn.as_data.type_alias.generics.len == 0 && self.cg_alias_extended(d.module, d.node) {
                    let mut nm = Buf256 {};
                    self.render_qualified(d.module, dn.as_data.type_alias.name, (&mut nm.b[0]) as *mut char, 160);
                    buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS && d.module == self.cur_module() {
                    self.render_type_node(dn.as_data.type_alias.ty, decl, out, cap);
                } else if dn.kind == NodeKind::NODE_TYPE_ALIAS {
                    self.render_type_id(unsafe (*self.cur_ast()).type_of(tn), decl, out, cap);
                } else if dn.kind == NodeKind::NODE_GENERIC_PARAM || dn.kind == NodeKind::NODE_INTERFACE {
                    let s = self.subst_lookup(d.module, d.node);
                    if s != TYPE_NONE { self.render_type_id(s, decl, out, cap); }
                    else if self.macro_mode && dn.kind == NodeKind::NODE_GENERIC_PARAM {
                        let mut p = Buf64 {};
                        self.render_macro_param(d.module, d.node, (&mut p.b[0]) as *mut char, 64);
                        buf_join3(out, cap, (&p.b[0]) as *const char, sep(decl), decl);
                    } else { buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl); }
                } else {
                    self.errors.emitf(n.span.start, n.span.end - n.span.start, "codegen: opaque type is not yet supported".ptr as *const char);
                    self.errors.notef("opaque extern types are supported through 'extern \"C\" { type Name; }' aliases".ptr as *const char);
                    buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl);
                }
                return;
            }
            let mut s = n.span;
            if nk == NodeKind::NODE_TYPE_PATH {
                let parts = n.as_data.type_path.parts;
                if parts.len != 0 { s = self.name_span(unsafe ((*a).list(parts))[0]); }
            } else { s = n.as_data.name.text; }
            let b = builtin_of(self.source, s);
            if b >= 0 { buf_join3(out, cap, builtin_c(b as BuiltinType), sep(decl), decl); }
            else {
                self.errors.emitf(s.start, s.end - s.start, "codegen: unresolved type '%.*s'".ptr as *const char, (s.end - s.start) as i32, src_at(self.source, s.start));
                buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl);
            }
            return;
        }
        if nk == NodeKind::NODE_POINTER_TYPE || nk == NodeKind::NODE_REFERENCE_TYPE {
            let it = n.as_data.indirect_type;
            let pt = unsafe (*self.cur_ast()).type_of(it.ty);
            let mut ptr = TYPE_NONE;
            if pt != TYPE_NONE { ptr = self.subst_resolve(pt); }
            if ptr != TYPE_NONE {
                let ay = *self.type_at(ptr);
                if ay.kind == TypeKind::TYPE_ARRAY && ay.as_data.arr.len != 0 {
                    let mut spiral = Buf512 {};
                    unsafe stdio::snprintf((&mut spiral.b[0]) as *mut char, 480, "(*%s)[%u]".ptr as *const char, decl, ay.as_data.arr.len);
                    let mut cp = it.qualifier == TypeQualifier::TYPE_QUAL_CONST;
                    if nk == NodeKind::NODE_REFERENCE_TYPE { cp = it.qualifier != TypeQualifier::TYPE_QUAL_MUT; }
                    let mut base = Buf512 {};
                    self.render_type_id(ay.as_data.elem, (&spiral.b[0]) as *const char, (&mut base.b[0]) as *mut char, 512);
                    let mut pfx = "".ptr as *const char;
                    if cp && not_const_prefixed((&base.b[0]) as *const char) { pfx = "const ".ptr as *const char; }
                    buf_join3(out, cap, pfx, "".ptr as *const char, (&base.b[0]) as *const char);
                    return;
                }
            }
            let mut inner = Buf512 {};
            buf_join3((&mut inner.b[0]) as *mut char, 480, "*".ptr as *const char, "".ptr as *const char, decl);
            let mut const_pointee = it.qualifier == TypeQualifier::TYPE_QUAL_CONST;
            if nk == NodeKind::NODE_REFERENCE_TYPE { const_pointee = it.qualifier != TypeQualifier::TYPE_QUAL_MUT; }
            let mut elem_is_ptr = false;
            if ptr != TYPE_NONE && self.type_at(ptr).kind == TypeKind::TYPE_POINTER { elem_is_ptr = true; }
            if const_pointee && elem_is_ptr {
                // Element is a pointer: east-const the pointer (`char *const *`), not its pointee.
                let mut cinner = Buf512 {};
                buf_join3((&mut cinner.b[0]) as *mut char, 480, "const ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char);
                self.render_type_node(it.ty, (&cinner.b[0]) as *const char, out, cap);
            } else if const_pointee {
                let mut base = Buf512 {};
                self.render_type_node(it.ty, (&inner.b[0]) as *const char, (&mut base.b[0]) as *mut char, 512);
                let mut pfx = "const ".ptr as *const char;
                if !not_const_prefixed((&base.b[0]) as *const char) { pfx = "".ptr as *const char; }
                buf_join3(out, cap, pfx, "".ptr as *const char, (&base.b[0]) as *const char);
            } else {
                self.render_type_node(it.ty, (&inner.b[0]) as *const char, out, cap);
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
            if att != TYPE_NONE && self.type_at(att).kind == TypeKind::TYPE_ARRAY { flen = self.type_at(att).as_data.arr.len; }
            let mut inner = Buf512 {};
            if flen != 0 {
                unsafe stdio::snprintf((&mut inner.b[0]) as *mut char, 480, "%s[%u]".ptr as *const char, decl, flen);
            } else {
                let ls = unsafe (*self.cur_ast()).at_const(n.as_data.array_type.length).span;
                let mut at = bappend((&mut inner.b[0]) as *mut char, 480, 0, decl);
                at = bappend((&mut inner.b[0]) as *mut char, 480, at, "[".ptr as *const char);
                at = bappend_bytes((&mut inner.b[0]) as *mut char, 480, at, src_at(self.source, ls.start), (ls.end - ls.start) as usize);
                bappend((&mut inner.b[0]) as *mut char, 480, at, "]".ptr as *const char);
            }
            self.render_type_node(n.as_data.array_type.element, (&inner.b[0]) as *const char, out, cap);
            return;
        }
        if nk == NodeKind::NODE_FUNCTION_TYPE {
            let ft = n.as_data.function_type;
            let mut params = Buf512 {};
            let mut k: usize = 0;
            let mut i: u32 = 0;
            while i < ft.params.len && k < 480 {
                let pid = unsafe ((*self.cur_ast()).list(ft.params))[i as usize];
                let mut t = Buf256 {};
                self.render_type_node(pid, "".ptr as *const char, (&mut t.b[0]) as *mut char, 256);
                if i != 0 { k = bappend((&mut params.b[0]) as *mut char, 480, k, ", ".ptr as *const char); }
                k = bappend((&mut params.b[0]) as *mut char, 480, k, (&t.b[0]) as *const char);
                i = i + 1;
            }
            let mut inner = Buf512 {};
            let mut at = bappend((&mut inner.b[0]) as *mut char, 512, 0, "(*".ptr as *const char);
            at = bappend((&mut inner.b[0]) as *mut char, 512, at, decl);
            at = bappend((&mut inner.b[0]) as *mut char, 512, at, ")(".ptr as *const char);
            let mut pstr = "void".ptr as *const char;
            if ft.params.len != 0 { pstr = (&params.b[0]) as *const char; }
            at = bappend((&mut inner.b[0]) as *mut char, 512, at, pstr);
            bappend((&mut inner.b[0]) as *mut char, 512, at, ")".ptr as *const char);
            if ft.returns.len == 1 {
                let r0 = unsafe ((*self.cur_ast()).list(ft.returns))[0];
                let rn = unsafe (*self.cur_ast()).at_const(r0);
                let rtn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
                self.render_type_node(rtn, (&inner.b[0]) as *const char, out, cap);
            } else if ft.returns.len == 0 {
                buf_join3(out, cap, "void ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char);
            } else {
                self.errors.emitf(n.span.start, n.span.end - n.span.start, "codegen: multi-return function pointer is not yet supported".ptr as *const char);
                buf_join3(out, cap, "void ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char);
            }
            return;
        }
        self.errors.emitf(n.span.start, n.span.end - n.span.start, "codegen: unsupported type".ptr as *const char);
        buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl);
    }

    fn render_type_id(self: &mut Self, t: TypeId, decl: *const char, out: *mut char, cap: usize) void {
        let ty = *self.type_at(t);
        if ty.kind == TypeKind::TYPE_BUILTIN {
            buf_join3(out, cap, builtin_c(ty.as_data.builtin), sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_NEVER {
            buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM {
            let mut nm = Buf256 {};
            self.render_qualified(ty.module, unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl).as_data.aggregate.name, (&mut nm.b[0]) as *mut char, 160);
            buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
            let el = *self.type_at(ty.as_data.elem);
            if el.kind == TypeKind::TYPE_ARRAY && el.as_data.arr.len != 0 {
                let mut inner = Buf512 {};
                unsafe stdio::snprintf((&mut inner.b[0]) as *mut char, 480, "(*%s)[%u]".ptr as *const char, decl, el.as_data.arr.len);
                let mut cp = ty.qualifier == (TypeQualifier::TYPE_QUAL_CONST as u8);
                if ty.kind == TypeKind::TYPE_REFERENCE { cp = ty.qualifier != (TypeQualifier::TYPE_QUAL_MUT as u8); }
                let mut base = Buf512 {};
                self.render_type_id(el.as_data.elem, (&inner.b[0]) as *const char, (&mut base.b[0]) as *mut char, 512);
                let mut pfx = "".ptr as *const char;
                if cp && not_const_prefixed((&base.b[0]) as *const char) { pfx = "const ".ptr as *const char; }
                buf_join3(out, cap, pfx, "".ptr as *const char, (&base.b[0]) as *const char);
                return;
            }
            let mut inner = Buf512 {};
            buf_join3((&mut inner.b[0]) as *mut char, 480, "*".ptr as *const char, "".ptr as *const char, decl);
            let mut const_pointee = ty.qualifier == (TypeQualifier::TYPE_QUAL_CONST as u8);
            if ty.kind == TypeKind::TYPE_REFERENCE { const_pointee = ty.qualifier != (TypeQualifier::TYPE_QUAL_MUT as u8); }
            let elem_is_ptr = self.type_at(self.subst_resolve(ty.as_data.elem)).kind == TypeKind::TYPE_POINTER;
            if const_pointee && elem_is_ptr {
                // The element is itself a pointer (resolve generics first): `const T` must qualify the POINTER
                // (east: `char *const *`), not its pointee (`const char **`, an illegal 2nd-level qualifier).
                let mut cinner = Buf512 {};
                buf_join3((&mut cinner.b[0]) as *mut char, 480, "const ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char);
                self.render_type_id(ty.as_data.elem, (&cinner.b[0]) as *const char, out, cap);
            } else if const_pointee {
                let mut base = Buf512 {};
                self.render_type_id(ty.as_data.elem, (&inner.b[0]) as *const char, (&mut base.b[0]) as *mut char, 512);
                let mut pfx = "const ".ptr as *const char;
                if !not_const_prefixed((&base.b[0]) as *const char) { pfx = "".ptr as *const char; }
                buf_join3(out, cap, pfx, "".ptr as *const char, (&base.b[0]) as *const char);
            } else {
                self.render_type_id(ty.as_data.elem, (&inner.b[0]) as *const char, out, cap);
            }
        } else if ty.kind == TypeKind::TYPE_SLICE {
            buf_join3(out, cap, "SCslice".ptr as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_ARRAY {
            let mut inner = Buf512 {};
            if ty.as_data.arr.len != 0 {
                let mut lenb = Buf32 {};
                unsafe stdio::snprintf((&mut lenb.b[0]) as *mut char, 16, "[%u]".ptr as *const char, ty.as_data.arr.len);
                buf_join3((&mut inner.b[0]) as *mut char, 480, decl, "".ptr as *const char, (&lenb.b[0]) as *const char);
            } else {
                buf_join3((&mut inner.b[0]) as *mut char, 480, "*".ptr as *const char, "".ptr as *const char, decl);
            }
            self.render_type_id(ty.as_data.elem, (&inner.b[0]) as *const char, out, cap);
        } else if ty.kind == TypeKind::TYPE_GENERIC {
            let s = self.subst_lookup(ty.module, ty.as_data.decl);
            if s != TYPE_NONE { self.render_type_id(s, decl, out, cap); }
            else if self.macro_mode {
                let mut p = Buf64 {};
                self.render_macro_param(ty.module, ty.as_data.decl, (&mut p.b[0]) as *mut char, 64);
                buf_join3(out, cap, (&p.b[0]) as *const char, sep(decl), decl);
            } else { buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl); }
        } else if ty.kind == TypeKind::TYPE_INSTANCE {
            let mut nm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(ty.as_data.inst), (&mut nm.b[0]) as *mut char, 200);
            buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_OPAQUE {
            let mut nm = Buf256 {};
            let dn = *unsafe (*self.mod_ast(ty.module)).at_const(ty.as_data.decl);
            render_ident_src(self.mod_src(ty.module), unsafe (*self.mod_ast(ty.module)).at_const(dn.as_data.type_alias.name).as_data.name.text, (&mut nm.b[0]) as *mut char, 160);
            buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
        } else if ty.kind == TypeKind::TYPE_FUNCTION {
            if self.cg_fn_is_capturing(&ty) {
                let mut envn = Buf256 {};
                self.closure_sym_in(ty.module, ty.as_data.decl, (&mut envn.b[0]) as *mut char, 240);
                let el2 = unsafe cstring::strlen((&envn.b[0]) as *const char);
                bappend((&mut envn.b[0]) as *mut char, 240, el2, "_env".ptr as *const char);
                buf_join3(out, cap, (&envn.b[0]) as *const char, sep(decl), decl);
            } else {
                self.render_fn_ptr_id(ty, decl, out, cap);
            }
        } else if ty.kind == TypeKind::TYPE_DYN {
            let mut nm = Buf256 {};
            self.dyn_stem(ty.module, ty.as_data.decl, (&mut nm.b[0]) as *mut char, 200);
            let dl = unsafe cstring::strlen((&nm.b[0]) as *const char);
            bappend((&mut nm.b[0]) as *mut char, 200, dl, "__dyn".ptr as *const char);
            buf_join3(out, cap, (&nm.b[0]) as *const char, sep(decl), decl);
        } else {
            buf_join3(out, cap, "void".ptr as *const char, sep(decl), decl);
        }
    }

    fn render_fn_ptr_id(self: &mut Self, fy: Ty, decl: *const char, out: *mut char, cap: usize) void {
        let fa = self.mod_ast(fy.module);
        let fnn = *unsafe (*fa).at_const(fy.as_data.decl);
        let mut ps = NodeList { start: 0, len: 0 };
        let mut rs = NodeList { start: 0, len: 0 };
        let mut body = NODE_NONE;
        if fnn.kind == NodeKind::NODE_FUNCTION { ps = fnn.as_data.function.params; rs = fnn.as_data.function.returns; }
        else if fnn.kind == NodeKind::NODE_CLOSURE {
            ps = fnn.as_data.closure.params;
            rs = fnn.as_data.closure.returns;
            if fnn.as_data.closure.expr_body { body = fnn.as_data.closure.body; }
        } else { ps = fnn.as_data.function_type.params; rs = fnn.as_data.function_type.returns; }
        let mut params = Buf512 {};
        let mut k: usize = 0;
        let mut i: u32 = 0;
        while i < ps.len && k < 480 {
            let pid = unsafe ((*fa).list(ps))[i as usize];
            let pn = unsafe (*fa).at_const(pid);
            let mut tn = pid;
            if pn.kind == NodeKind::NODE_PARAMETER { tn = pn.as_data.parameter.ty; }
            let mut anchor = tn;
            if tn == NODE_NONE { anchor = pid; }
            let mut tt = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).reintern(unsafe (&*fa), unsafe (*fa).type_of(anchor)), "".ptr as *const char, (&mut tt.b[0]) as *mut char, 256);
            if i != 0 { k = bappend((&mut params.b[0]) as *mut char, 480, k, ", ".ptr as *const char); }
            k = bappend((&mut params.b[0]) as *mut char, 480, k, (&tt.b[0]) as *const char);
            i = i + 1;
        }
        let mut inner = Buf512 {};
        let mut at = bappend((&mut inner.b[0]) as *mut char, 512, 0, "(*".ptr as *const char);
        at = bappend((&mut inner.b[0]) as *mut char, 512, at, decl);
        at = bappend((&mut inner.b[0]) as *mut char, 512, at, ")(".ptr as *const char);
        let mut pstr = "void".ptr as *const char;
        if ps.len != 0 { pstr = (&params.b[0]) as *const char; }
        at = bappend((&mut inner.b[0]) as *mut char, 512, at, pstr);
        bappend((&mut inner.b[0]) as *mut char, 512, at, ")".ptr as *const char);
        let mut rt = TYPE_NONE;
        if rs.len == 1 {
            let r0 = unsafe ((*fa).list(rs))[0];
            let rn = unsafe (*fa).at_const(r0);
            let rtn = if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0);
            rt = unsafe (*self.cur_ast()).reintern(unsafe (&*fa), unsafe (*fa).type_of(rtn));
        } else if body != NODE_NONE {
            rt = unsafe (*self.cur_ast()).reintern(unsafe (&*fa), unsafe (*fa).type_of(body));
        }
        if rt != TYPE_NONE { self.render_type_id(rt, (&inner.b[0]) as *const char, out, cap); }
        else { buf_join3(out, cap, "void ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char); }
    }
}

extend Codegen {
    // ---- enum index / tags ----
    fn enclosing_enum(self: &Self, variant: NodeId) NodeId {
        if let Some(v) = self.enum_of_variant.get(&variant) { return *v; }
        return NODE_NONE;
    }
    fn enclosing_enum_in(self: &Self, m: ModuleId, variant: NodeId) NodeId {
        if m == self.cur_module() && !self.borrowed { return self.enclosing_enum(variant); }
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut i: u32 = 0;
        while i < items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_ENUM {
                let ms = unsafe (*a).at_const(iid).as_data.aggregate.members;
                let mut j: u32 = 0;
                while j < ms.len { if unsafe ((*a).list(ms))[j as usize] == variant { return iid; } j = j + 1; }
            }
            i = i + 1;
        }
        return NODE_NONE;
    }
    fn emit_tag_mod(self: &mut Self, m: ModuleId, enum_decl: NodeId, variant: NodeId) void {
        let src = self.mod_src(m);
        let mut pfx = Buf64 {};
        self.render_modpfx(m, (&mut pfx.b[0]) as *mut char, 64);
        self.emit_cstr((&pfx.b[0]) as *const char);
        let es = self.name_span_in(m, unsafe (*self.mod_ast(m)).at_const(enum_decl).as_data.aggregate.name);
        self.emit_bytes(src_at(src, es.start), (es.end - es.start) as usize);
        self.emit_cstr("_".ptr as *const char);
        let vs = self.name_span_in(m, unsafe (*self.mod_ast(m)).at_const(variant).as_data.variant.name);
        self.emit_bytes(src_at(src, vs.start), (vs.end - vs.start) as usize);
    }
    fn emit_tag(self: &mut Self, enum_decl: NodeId, variant: NodeId) void { self.emit_tag_mod(self.cur_module(), enum_decl, variant); }
    fn render_variant_name(self: &Self, m: ModuleId, variant: NodeId, buf: *mut char, cap: usize) void {
        render_ident_src(self.mod_src(m), self.name_span_in(m, unsafe (*self.mod_ast(m)).at_const(variant).as_data.variant.name), buf, cap);
    }
    fn aggregate_has_payload_in(self: &Self, m: ModuleId, enum_decl: NodeId) bool {
        let a = self.mod_ast(m);
        let members = unsafe (*a).at_const(enum_decl).as_data.aggregate.members;
        let mut i: u32 = 0;
        while i < members.len {
            if unsafe (*a).at_const(unsafe ((*a).list(members))[i as usize]).as_data.variant.payload.len > 0 { return true; }
            i = i + 1;
        }
        return false;
    }
    fn aggregate_has_payload(self: &Self, enum_decl: NodeId) bool { return self.aggregate_has_payload_in(self.cur_module(), enum_decl); }

    // ---- type peeling ----
    fn strip_ptr(self: &Self, t0: TypeId) TypeId {
        let mut t = t0;
        let mut y = self.type_at(t);
        while y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE { t = y.as_data.elem; y = self.type_at(t); }
        return t;
    }
    fn strip_ref_only(self: &Self, t0: TypeId) TypeId {
        let mut t = t0;
        let mut y = self.type_at(t);
        while y.kind == TypeKind::TYPE_REFERENCE { t = y.as_data.elem; y = self.type_at(t); }
        if y.kind == TypeKind::TYPE_POINTER { return TYPE_NONE; }
        return t;
    }
    fn cg_ref_depth(self: &Self, t: TypeId) i32 {
        let mut d: i32 = 0;
        let mut y = self.type_at(t);
        while y.kind == TypeKind::TYPE_REFERENCE { d = d + 1; y = self.type_at(y.as_data.elem); }
        return d;
    }

    // ---- Free / ownership detection ----
    fn cg_fn_owns(self: &mut Self, fy: &Ty) bool {
        if fy.kind != TypeKind::TYPE_FUNCTION { return false; }
        let fa = self.mod_ast(fy.module);
        let fnn = *unsafe (*fa).at_const(fy.as_data.decl);
        if fnn.kind != NodeKind::NODE_CLOSURE { return false; }
        let caps = fnn.as_data.closure.captures;
        let mut_caps = fnn.as_data.closure.mut_caps;
        let mut i: u32 = 0;
        while i < caps.len {
            let cid = unsafe ((*fa).list(caps))[i as usize];
            if ((mut_caps >> (i as u64)) & 1u64) == 0 {
                let rt = unsafe (*self.cur_ast()).reintern(unsafe (&*fa), unsafe (*fa).type_of(cid));
                if self.cg_type_is_free(rt) { return true; }
            }
            i = i + 1;
        }
        return false;
    }
    fn cg_slice_elem(self: &Self, tid: TypeId, elem: *mut TypeId) bool {
        if self.package == null { return false; }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE { return false; }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        let sh = unsafe (*self.package).prelude_lookup("Slice".ptr as *const char, 5, true);
        let mh = unsafe (*self.package).prelude_lookup("SliceMut".ptr as *const char, 8, true);
        let is_slice = (it.module == sh.mid && it.decl == sh.node) || (it.module == mh.mid && it.decl == mh.node);
        if is_slice && it.n == 1 && elem != null { unsafe *elem = it.args[0]; }
        return is_slice && it.n == 1;
    }
    fn cg_range_elem(self: &Self, tid: TypeId, elem: *mut TypeId) bool {
        if self.package == null { return false; }
        let ty = self.type_at(tid);
        if ty.kind != TypeKind::TYPE_INSTANCE { return false; }
        let it = *unsafe (*self.cur_ast()).instance(ty.as_data.inst);
        let rh = unsafe (*self.package).prelude_lookup("Range".ptr as *const char, 5, true);
        let is_range = it.n == 1 && it.module == rh.mid && it.decl == rh.node;
        if is_range && elem != null { unsafe *elem = it.args[0]; }
        return is_range;
    }
    fn cg_free_extend(self: &Self, tmod: ModuleId, tdecl: NodeId) DefId {
        let mut ns = 1;
        if tmod != self.cur_module() { ns = 2; }
        let mut s = 0;
        while s < ns {
            let mut m = tmod;
            if s == 1 { m = self.cur_module(); }
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            let mut i: u32 = 0;
            while i < items.len {
                let iid = unsafe ((*a).list(items))[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.interface_type != NODE_NONE && it.as_data.extend_def.target_type != NODE_NONE {
                    let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                    if tg.module == tmod && tg.node == tdecl {
                        let tr = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                        if tr.node != NODE_NONE {
                            let trn = unsafe (*self.mod_ast(tr.module)).at_const(tr.node);
                            if trn.kind == NodeKind::NODE_INTERFACE && span_is(self.mod_src(tr.module), unsafe (*self.mod_ast(tr.module)).at_const(trn.as_data.interface_def.name).as_data.name.text, "Free".ptr as *const char) {
                                return DefId { module: m, node: iid };
                            }
                        }
                    }
                }
                i = i + 1;
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_free_method(self: &Self, tmod: ModuleId, tdecl: NodeId) DefId {
        let ext = self.cg_free_extend(tmod, tdecl);
        if ext.node == NODE_NONE { return DefId { module: 0, node: NODE_NONE }; }
        let a = self.mod_ast(ext.module);
        let ms = unsafe (*a).at_const(ext.node).as_data.extend_def.items;
        let mut j: u32 = 0;
        while j < ms.len {
            let mid = unsafe ((*a).list(ms))[j as usize];
            let mn = unsafe (*a).at_const(mid);
            if mn.kind == NodeKind::NODE_FUNCTION && span_is(self.mod_src(ext.module), unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text, "free".ptr as *const char) { return DefId { module: ext.module, node: mid }; }
            j = j + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.mod_ast(m);
        let bs = unsafe (*a).at_const(gp).as_data.generic_param.bounds;
        let mut i: u32 = 0;
        while i < bs.len {
            let bd = unsafe (*a).resolution_def(unsafe ((*a).list(bs))[i as usize]);
            if bd.node != NODE_NONE {
                let bn = unsafe (*self.mod_ast(bd.module)).at_const(bd.node);
                if bn.kind == NodeKind::NODE_INTERFACE && span_is(self.mod_src(bd.module), unsafe (*self.mod_ast(bd.module)).at_const(bn.as_data.interface_def.name).as_data.name.text, "Free".ptr as *const char) { return true; }
            }
            i = i + 1;
        }
        return false;
    }
    fn cg_type_is_free(self: &mut Self, ty0: TypeId) bool {
        let y = *self.type_at(self.subst_resolve(ty0));
        if y.kind == TypeKind::TYPE_FUNCTION { return self.cg_fn_owns(&y); }
        if y.kind == TypeKind::TYPE_DYN { return y.qualifier == (TypeQualifier::TYPE_QUAL_NONE as u8); }
        if y.kind == TypeKind::TYPE_STRUCT { return self.cg_free_method(y.module, y.as_data.decl).node != NODE_NONE; }
        if y.kind != TypeKind::TYPE_INSTANCE { return false; }
        let ii = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
        let ext = self.cg_free_extend(ii.module, ii.decl);
        if ext.node == NODE_NONE { return false; }
        let ia = self.mod_ast(ext.module);
        let gens = unsafe (*ia).at_const(ext.node).as_data.extend_def.generics;
        let mut i: u32 = 0;
        while i < gens.len && (i as u8) < ii.n {
            let gid = unsafe ((*ia).list(gens))[i as usize];
            if self.cg_param_has_free_bound(ext.module, gid) && !self.cg_type_is_free(ii.args[i as usize]) { return false; }
            i = i + 1;
        }
        return true;
    }
    fn cg_is_moved(self: &Self, decl: NodeId) bool {
        let mut i: u32 = 0;
        while i < self.nmoved { if self.moved[i as usize] == decl { return true; } i = i + 1; }
        return false;
    }
    fn cg_is_cond_moved(self: &Self, decl: NodeId) bool {
        let mut i: u32 = 0;
        while i < self.ncond_moved { if self.cond_moved[i as usize] == decl { return true; } i = i + 1; }
        return false;
    }
    fn cg_is_cond_site(self: &Self, expr: NodeId) bool {
        let mut i: u32 = 0;
        while i < self.ncond_sites { if self.cond_sites[i as usize] == expr { return true; } i = i + 1; }
        return false;
    }

    // ---- method lookup ----
    fn cg_find_method_impl(self: &Self, tmod: ModuleId, tdecl: NodeId, nsrc: *const u8, name: tok::Span, lit: *const char) DefId {
        let mut scopes = ScopeArr {};
        let mut ns: i32 = 0;
        scopes.s[0] = tmod; ns = 1;
        if self.cur_module() != tmod { scopes.s[ns as usize] = self.cur_module(); ns = ns + 1; }
        if self.dflt_home_set && self.dflt_home != tmod && self.dflt_home != self.cur_module() { scopes.s[ns as usize] = self.dflt_home; ns = ns + 1; }
        let mut s: i32 = 0;
        while s < ns {
            let m = scopes.s[s as usize];
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            let mut i: u32 = 0;
            while i < items.len {
                let iid = unsafe ((*a).list(items))[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind == NodeKind::NODE_EXTEND && it.as_data.extend_def.target_type != NODE_NONE {
                    let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                    if tg.module == tmod && tg.node == tdecl {
                        let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                        let mut j: u32 = 0;
                        while j < ms.len {
                            let mid = unsafe ((*a).list(ms))[j as usize];
                            let mn = unsafe (*a).at_const(mid);
                            if mn.kind == NodeKind::NODE_FUNCTION {
                                let mname = unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text;
                                let mut hit = false;
                                if lit != null { hit = span_is(self.mod_src(m), mname, lit); }
                                else { hit = spans_eq2(nsrc, name, self.mod_src(m), mname); }
                                if hit { return DefId { module: m, node: mid }; }
                            }
                            j = j + 1;
                        }
                    }
                }
                i = i + 1;
            }
            s = s + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_find_method(self: &Self, tmod: ModuleId, tdecl: NodeId, nsrc: *const u8, name: tok::Span) DefId {
        return self.cg_find_method_impl(tmod, tdecl, nsrc, name, null);
    }
    fn cg_find_method_cstr(self: &Self, tmod: ModuleId, tdecl: NodeId, lit: *const char) DefId {
        return self.cg_find_method_impl(tmod, tdecl, null, tok::Span::empty(), lit);
    }

    fn is_lvalue(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_INDEX { return true; }
        if n.kind == NodeKind::NODE_MEMBER { return !n.as_data.member.path; }
        if n.kind == NodeKind::NODE_UNARY {
            if n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe { return self.is_lvalue(n.as_data.unary.operand); }
            return n.as_data.unary.op == TokenType::Star;
        }
        return false;
    }
}

// ---- free helpers ----
fn if_node(c: bool, a: NodeId, b: NodeId) NodeId { if c { return a; } return b; }
pub struct ScopeArr { pub s: [ModuleId; 3] }

fn cg_move_flag(out: *mut char, cap: usize, decl: NodeId) void {
    unsafe stdio::snprintf(out, cap, "__mv%u".ptr as *const char, decl);
}
fn ref_derefs(d0: i32) *const char {
    let mut d = d0;
    if d < 1 { d = 1; } else if d > 7 { d = 7; }
    // C: `s + sizeof s - d` over "*******" (sizeof 8, incl NUL) -> (d-1) asterisks; ref_derefs(1) == "".
    return unsafe (("*******".ptr as *const char) + (8 - d) as usize) as *const char;
}
fn c_op(t: TokenType) *const char {
    if t == TokenType::Plus { return "+".ptr as *const char; }
    if t == TokenType::Minus { return "-".ptr as *const char; }
    if t == TokenType::Star { return "*".ptr as *const char; }
    if t == TokenType::Slash { return "/".ptr as *const char; }
    if t == TokenType::Percent { return "%".ptr as *const char; }
    if t == TokenType::Ampersand { return "&".ptr as *const char; }
    if t == TokenType::Pipe { return "|".ptr as *const char; }
    if t == TokenType::Caret { return "^".ptr as *const char; }
    if t == TokenType::LeftShift { return "<<".ptr as *const char; }
    if t == TokenType::RightShift { return ">>".ptr as *const char; }
    if t == TokenType::AmpersandAmpersand { return "&&".ptr as *const char; }
    if t == TokenType::PipePipe { return "||".ptr as *const char; }
    if t == TokenType::EqualEqual { return "==".ptr as *const char; }
    if t == TokenType::BangEqual { return "!=".ptr as *const char; }
    if t == TokenType::LessThan { return "<".ptr as *const char; }
    if t == TokenType::LessThanEqual { return "<=".ptr as *const char; }
    if t == TokenType::GreaterThan { return ">".ptr as *const char; }
    if t == TokenType::GreaterThanEqual { return ">=".ptr as *const char; }
    if t == TokenType::Equal { return "=".ptr as *const char; }
    if t == TokenType::PlusEqual { return "+=".ptr as *const char; }
    if t == TokenType::MinusEqual { return "-=".ptr as *const char; }
    if t == TokenType::StarEqual { return "*=".ptr as *const char; }
    if t == TokenType::SlashEqual { return "/=".ptr as *const char; }
    if t == TokenType::PercentEqual { return "%=".ptr as *const char; }
    if t == TokenType::AmpersandEqual { return "&=".ptr as *const char; }
    if t == TokenType::PipeEqual { return "|=".ptr as *const char; }
    if t == TokenType::CaretEqual { return "^=".ptr as *const char; }
    if t == TokenType::LeftShiftEqual { return "<<=".ptr as *const char; }
    if t == TokenType::RightShiftEqual { return ">>=".ptr as *const char; }
    if t == TokenType::Bang { return "!".ptr as *const char; }
    if t == TokenType::Tilde { return "~".ptr as *const char; }
    return "?".ptr as *const char;
}
fn cg_arith_op_method(op: TokenType) *const char {
    if op == TokenType::Plus { return "add".ptr as *const char; }
    if op == TokenType::Minus { return "sub".ptr as *const char; }
    if op == TokenType::Star { return "mul".ptr as *const char; }
    if op == TokenType::Slash { return "div".ptr as *const char; }
    if op == TokenType::Percent { return "rem".ptr as *const char; }
    return null;
}
fn hex_val(ch: u8) i32 {
    if ch >= '0' as u8 && ch <= '9' as u8 { return (ch - '0' as u8) as i32; }
    if ch >= 'a' as u8 && ch <= 'f' as u8 { return (ch - 'a' as u8) as i32 + 10; }
    if ch >= 'A' as u8 && ch <= 'F' as u8 { return (ch - 'A' as u8) as i32 + 10; }
    return 0;
}
fn utf8_encode(cp: u32, out: *mut u8) i32 {
    if cp < 0x80 { unsafe out[0] = cp as u8; return 1; }
    if cp < 0x800 {
        unsafe out[0] = (0xC0u32 | (cp >> 6)) as u8;
        unsafe out[1] = (0x80u32 | (cp & 0x3Fu32)) as u8;
        return 2;
    }
    if cp < 0x10000 {
        unsafe out[0] = (0xE0u32 | (cp >> 12)) as u8;
        unsafe out[1] = (0x80u32 | ((cp >> 6) & 0x3Fu32)) as u8;
        unsafe out[2] = (0x80u32 | (cp & 0x3Fu32)) as u8;
        return 3;
    }
    unsafe out[0] = (0xF0u32 | (cp >> 18)) as u8;
    unsafe out[1] = (0x80u32 | ((cp >> 12) & 0x3Fu32)) as u8;
    unsafe out[2] = (0x80u32 | ((cp >> 6) & 0x3Fu32)) as u8;
    unsafe out[3] = (0x80u32 | (cp & 0x3Fu32)) as u8;
    return 4;
}
fn raw_string_content(src: *const u8, s: tok::Span) tok::Span {
    let mut i = s.start + 1;
    let mut h: u32 = 0;
    while unsafe src[i as usize] == '#' as u8 { i = i + 1; h = h + 1; }
    return tok::Span { start: i + 1, end: s.end - 1 - h };
}

extend Codegen {
    fn emit_number(self: &mut Self, s: tok::Span, tt: TokenType, rb: BuiltinType) void {
        let mut sfx = s.end;
        let sb = unsafe ast_numeric_suffix(self.source, s.start, s.end, (&mut sfx) as *mut u32);
        let mut eb = sb;
        if sb == BuiltinType::BT_COUNT { if tt == TokenType::IntegerLiteral { eb = rb; } else { eb = BuiltinType::BT_COUNT; } }
        let mut buf = Buf256 {};
        let mut n: usize = 0;
        let mut i = s.start;
        while i < sfx && n < 255 { if unsafe self.source[i as usize] != '_' as u8 { buf.b[n] = unsafe self.source[i as usize] as char; n = n + 1; } i = i + 1; }
        buf.b[n] = 0 as char;
        let bufp = (&buf.b[0]) as *const char;
        if tt == TokenType::IntegerLiteral && n >= 2 && buf.b[0] == '0' as char {
            let k = buf.b[1];
            if k == 'b' as char || k == 'B' as char {
                let mut v: u64 = 0;
                let mut j: usize = 2;
                while j < n { v = (v << 1) | ((buf.b[j] as u8) - '0' as u8) as u64; j = j + 1; }
                if v > 0x7FFFFFFFFFFFFFFFu64 && eb == BuiltinType::BT_COUNT { self.emit("%lluull".ptr as *const char, v); } else { self.emit("%llu".ptr as *const char, v); }
            } else if k == 'o' as char || k == 'O' as char {
                self.emit("0%s".ptr as *const char, unsafe (bufp + 2) as *const char);
            } else if k == 'x' as char || k == 'X' as char {
                self.emit_cstr(bufp);
            } else {
                let mut z: usize = 0;
                while z + 1 < n && buf.b[z] == '0' as char { z = z + 1; }
                self.emit_cstr(unsafe (bufp + z) as *const char);
                if eb == BuiltinType::BT_COUNT && unsafe strtoull(unsafe (bufp + z) as *const char, null, 10) > 0x7FFFFFFFFFFFFFFFu64 { self.emit_cstr("ull".ptr as *const char); }
            }
        } else if tt == TokenType::IntegerLiteral && eb == BuiltinType::BT_COUNT && unsafe strtoull(bufp, null, 10) > 0x7FFFFFFFFFFFFFFFu64 {
            self.emit_cstr(bufp);
            self.emit_cstr("ull".ptr as *const char);
        } else {
            self.emit_cstr(bufp);
            let hexf = n > 2 && buf.b[0] == '0' as char && ((buf.b[1] as u8) | 0x20u8) == 'x' as u8;
            if !hexf && (sb == BuiltinType::BT_F32 || sb == BuiltinType::BT_F64) && unsafe cstring::memchr(bufp as *const void, '.' as i32, n) == null && unsafe cstring::memchr(bufp as *const void, 'e' as i32, n) == null && unsafe cstring::memchr(bufp as *const void, 'E' as i32, n) == null { self.emit_cstr(".0".ptr as *const char); }
        }
        if eb == BuiltinType::BT_I64 || eb == BuiltinType::BT_ISIZE { self.emit_cstr("LL".ptr as *const char); }
        else if eb == BuiltinType::BT_U8 || eb == BuiltinType::BT_U16 || eb == BuiltinType::BT_U32 { self.emit_cstr("U".ptr as *const char); }
        else if eb == BuiltinType::BT_U64 || eb == BuiltinType::BT_USIZE { self.emit_cstr("ULL".ptr as *const char); }
        else if eb == BuiltinType::BT_F32 { self.emit_cstr("f".ptr as *const char); }
    }

    fn emit_reescaped(self: &mut Self, s: tok::Span, is_char: bool) void {
        let src = self.source;
        let mut q = '"' as i32;
        if is_char { q = '\'' as i32; }
        self.emit("%c".ptr as *const char, q);
        let mut i = (s.start + 1) as usize;
        let end = (s.end - 1) as usize;
        while i < end {
            if unsafe src[i] != '\\' as u8 {
                if is_char && unsafe src[i] >= 0x80u8 {
                    let cp = (((unsafe src[i] & 0x1Fu8) as u32) << 6) | ((unsafe src[i + 1] & 0x3Fu8) as u32);
                    self.emit("\\%03o".ptr as *const char, cp & 0xFFu32);
                    i = i + 2;
                    continue;
                }
                self.emit("%c".ptr as *const char, unsafe src[i] as i32);
                i = i + 1;
                continue;
            }
            i = i + 1;
            if i >= end { break; }
            let e = unsafe src[i];
            i = i + 1;
            if e == 'n' as u8 || e == 'r' as u8 || e == 't' as u8 || e == '\\' as u8 || e == '"' as u8 || e == '\'' as u8 {
                self.emit("\\%c".ptr as *const char, e as i32);
            } else if e == '0' as u8 {
                self.emit_cstr("\\000".ptr as *const char);
            } else if e == 'x' as u8 {
                let v = ((hex_val(unsafe src[i]) << 4) | hex_val(unsafe src[i + 1])) as u32;
                i = i + 2;
                self.emit("\\%03o".ptr as *const char, v & 0xFFu32);
            } else if e == 'u' as u8 {
                if i < end && unsafe src[i] == '{' as u8 { i = i + 1; }
                let mut cp: u32 = 0;
                while i < end && unsafe src[i] != '}' as u8 { cp = (cp << 4) | (hex_val(unsafe src[i]) as u32); i = i + 1; }
                if i < end && unsafe src[i] == '}' as u8 { i = i + 1; }
                if is_char { self.emit("\\%03o".ptr as *const char, cp & 0xFFu32); }
                else {
                    let mut b = Bytes4 {};
                    let bn = utf8_encode(cp, (&mut b.b[0]) as *mut u8);
                    let mut kk: i32 = 0;
                    while kk < bn { self.emit("\\%03o".ptr as *const char, b.b[kk as usize] as u32); kk = kk + 1; }
                }
            } else {
                self.emit("\\%c".ptr as *const char, e as i32);
            }
        }
        self.emit("%c".ptr as *const char, q);
    }

    fn emit_raw_c_string(self: &mut Self, content: tok::Span) void {
        self.emit_cstr("\"".ptr as *const char);
        let mut i = content.start;
        while i < content.end {
            let b = unsafe self.source[i as usize];
            if b == '"' as u8 || b == '\\' as u8 { self.emit("\\%c".ptr as *const char, b as i32); }
            else if b == '\n' as u8 { self.emit_cstr("\\n".ptr as *const char); }
            else if b < 0x20u8 { self.emit("\\%03o".ptr as *const char, b as u32); }
            else { self.emit("%c".ptr as *const char, b as i32); }
            i = i + 1;
        }
        self.emit_cstr("\"".ptr as *const char);
    }
}

pub struct Bytes4 { pub b: [u8; 4] }

// ---- stubs: filled in later chunks (codegen is never run by the stub main, so these keep the build green) ----
extend Codegen {
    fn emit_format_builtin(self: &mut Self, id: NodeId) bool {
        if self.package == null { return false; }
        let callee = unsafe (*self.cur_ast()).at_const(id).as_data.call.callee;
        if unsafe (*self.cur_ast()).at_const(callee).kind != NodeKind::NODE_IDENTIFIER { return false; }
        let d = unsafe (*self.cur_ast()).resolution_def(callee);
        if d.node == NODE_NONE || d.module as usize >= self.pkg_count() || !unsafe (*self.package).modules.at(d.module as usize).prelude { return false; }
        if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_FUNCTION { return false; }
        let fnamenode = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.name;
        let fnm = unsafe (*self.mod_ast(d.module)).at_const(fnamenode).as_data.name.text;
        let dsrc = self.mod_src(d.module);
        let mut kind: i32 = 0;
        if span_is(dsrc, fnm, "format".ptr as *const char) { kind = 1; }
        else if span_is(dsrc, fnm, "print".ptr as *const char) { kind = 2; }
        else if span_is(dsrc, fnm, "println".ptr as *const char) { kind = 3; }
        else if span_is(dsrc, fnm, "eprint".ptr as *const char) { kind = 4; }
        else if span_is(dsrc, fnm, "eprintln".ptr as *const char) { kind = 5; }
        if kind == 0 { return false; }
        let args = unsafe (*self.cur_ast()).at_const(id).as_data.call.args;
        let aids = unsafe (*self.cur_ast()).list(args);
        let mut is_raw = false;
        let mut ok_lit = false;
        if args.len != 0 {
            let a0 = unsafe aids[0 as usize];
            if unsafe (*self.cur_ast()).at_const(a0).kind == NodeKind::NODE_LITERAL {
                let tt = unsafe (*self.cur_ast()).at_const(a0).as_data.literal.token_type;
                is_raw = tt == TokenType::RawStringLiteral;
                ok_lit = tt == TokenType::StringLiteral || is_raw;
            }
        }
        if !ok_lit {
            let sspan = unsafe (*self.cur_ast()).at_const(id).span;
            self.errors.emitf(sspan.start, sspan.end - sspan.start, "%s".ptr as *const char, "codegen: format string must be a string literal".ptr as *const char);
            self.errors.notef("format strings are parsed at compile time so placeholders can be checked".ptr as *const char);
            return true;
        }
        let mut ff = Buf32 {};
        self.fresh((&mut ff.b[0]) as *mut char, 32);
        let fp = (&ff.b[0]) as *const char;
        self.emit("({ String__Global %s = String__Global__new();\n".ptr as *const char, fp);
        let a0 = unsafe aids[0 as usize];
        let raw = unsafe (*self.cur_ast()).at_const(a0).as_data.literal.raw;
        let src = self.source;
        let content = if (is_raw) { raw_string_content(src, raw); } else { tok::Span { start: raw.start + 1, end: raw.end - 1 }; };
        let mut i = content.start as usize;
        let endc = content.end as usize;
        let mut seg = i;
        let mut ai: u32 = 1;
        while i < endc {
            if (unsafe src[i] == '{' as u8 || unsafe src[i] == '}' as u8) && i + 1 < endc && unsafe src[i + 1] == unsafe src[i] {
                i = i + 2;
                continue;
            }
            if unsafe src[i] == '{' as u8 {
                let mut sp = FmtSpec { ty: 0 as char, align: 0 as char, fill: 0 as u8, width: 0, prec: -1 };
                let mut j = i + 1;
                if j < endc && unsafe src[j] == ':' as u8 {
                    j = j + 1;
                    if j + 1 < endc && (unsafe src[j + 1] == '<' as u8 || unsafe src[j + 1] == '>' as u8 || unsafe src[j + 1] == '^' as u8) && unsafe src[j] != '}' as u8 {
                        sp.fill = unsafe src[j];
                        sp.align = unsafe src[j + 1] as char;
                        j = j + 2;
                    } else if j < endc && (unsafe src[j] == '<' as u8 || unsafe src[j] == '>' as u8 || unsafe src[j] == '^' as u8) {
                        sp.align = unsafe src[j] as char;
                        j = j + 1;
                    }
                    if j < endc && unsafe src[j] == '0' as u8 && sp.fill == 0 as u8 {
                        sp.fill = '0' as u8;
                        j = j + 1;
                    }
                    while j < endc && unsafe src[j] >= '0' as u8 && unsafe src[j] <= '9' as u8 {
                        sp.width = sp.width * 10 + (unsafe src[j] as i32 - '0' as i32);
                        j = j + 1;
                    }
                    if j < endc && unsafe src[j] == '.' as u8 {
                        j = j + 1;
                        sp.prec = 0;
                        while j < endc && unsafe src[j] >= '0' as u8 && unsafe src[j] <= '9' as u8 {
                            sp.prec = sp.prec * 10 + (unsafe src[j] as i32 - '0' as i32);
                            j = j + 1;
                        }
                    }
                    if j < endc && (unsafe src[j] == 'x' as u8 || unsafe src[j] == 'X' as u8 || unsafe src[j] == 'b' as u8) {
                        sp.ty = unsafe src[j] as char;
                        j = j + 1;
                    }
                }
                if j < endc && unsafe src[j] == '}' as u8 {
                    if i > seg { self.emit_fmt_seg(fp, is_raw, seg, i); }
                    if ai >= args.len {
                        let sspan = unsafe (*self.cur_ast()).at_const(id).span;
                        self.errors.emitf(sspan.start, sspan.end - sspan.start, "%s".ptr as *const char, "codegen: more `{}` placeholders than arguments".ptr as *const char);
                        self.errors.notef("add an argument for each placeholder or escape literal braces as '{{' and '}}'".ptr as *const char);
                        self.emit("%s; })".ptr as *const char, fp);
                        return true;
                    }
                    let argid = unsafe aids[ai as usize];
                    if !self.emit_format_arg(fp, argid, &sp) {
                        let aspan = unsafe (*self.cur_ast()).at_const(argid).span;
                        let msg = if (sp.ty != 0 as char) { "codegen: `{:x}`/`{:X}`/`{:b}` formats require an integer argument".ptr as *const char; } else if (sp.prec >= 0) { "codegen: `{:.N}` precision requires a float argument".ptr as *const char; } else { "codegen: argument is not directly formattable (call its .fmt())".ptr as *const char; };
                        self.errors.emitf(aspan.start, aspan.end - aspan.start, "%s".ptr as *const char, msg);
                        if sp.ty == 0 as char && sp.prec < 0 { self.errors.notef("implement Format for this type or pass a value that already formats directly".ptr as *const char); }
                    }
                    ai = ai + 1;
                    i = j + 1;
                    seg = i;
                    continue;
                }
            }
            i = i + 1;
        }
        if endc > seg { self.emit_fmt_seg(fp, is_raw, seg, endc); }
        if ai < args.len {
            let sspan = unsafe (*self.cur_ast()).at_const(id).span;
            self.errors.emitf(sspan.start, sspan.end - sspan.start, "%s".ptr as *const char, "codegen: more arguments than `{}` placeholders".ptr as *const char);
            self.errors.notef("remove the extra argument or add a matching '{}' placeholder".ptr as *const char);
        }
        if kind == 3 || kind == 5 { self.emit("String__Global__push_byte(&%s, 10);\n".ptr as *const char, fp); }
        if kind == 1 {
            self.emit("%s; })".ptr as *const char, fp);
        } else if kind >= 4 {
            self.emit("String__Global__eprint(&%s); String__Global__free(&%s); })".ptr as *const char, fp, fp);
        } else {
            self.emit("String__Global__print(&%s); String__Global__free(&%s); })".ptr as *const char, fp, fp);
        }
        return true;
    }
    fn emit_assert_builtin(self: &mut Self, id: NodeId) bool {
        let kind = self.cg_assert_kind(id);
        if kind == 0 { return false; }
        let args = unsafe (*self.cur_ast()).at_const(id).as_data.call.args;
        let aids = unsafe (*self.cur_ast()).list(args);
        let sspan = unsafe (*self.cur_ast()).at_const(id).span;
        let line = self.cg_line_of(sspan.start);
        let file = self.cg_file();
        if kind == 1 {
            let a0 = unsafe aids[0 as usize];
            let cs = unsafe (*self.cur_ast()).at_const(a0).span;
            self.emit_cstr("({ if (!(".ptr as *const char);
            self.emit_expr(a0);
            self.emit_cstr(")) { ".ptr as *const char);
            if args.len == 2 {
                self.emit_cstr("const str __scm = ".ptr as *const char);
                self.emit_expr(unsafe aids[1 as usize]);
                self.emit_cstr("; ".ptr as *const char);
            }
            self.emit_cstr("fprintf(stderr, \"assertion failed: `".ptr as *const char);
            self.emit_pct_escaped(unsafe (self.source + cs.start as usize), (cs.end - cs.start) as usize);
            self.emit_cstr("`".ptr as *const char);
            if args.len == 2 { self.emit_cstr(": %.*s".ptr as *const char); }
            self.emit_cstr("\\n  at ".ptr as *const char);
            self.emit_pct_escaped(file as *const u8, unsafe cstring::strlen(file));
            self.emit(":%u\\n\"".ptr as *const char, line);
            if args.len == 2 { self.emit_cstr(", (int)__scm.len, (const char *)__scm.ptr".ptr as *const char); }
            self.emit_cstr("); abort(); } })".ptr as *const char);
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
        self.fresh((&mut lb.b[0]) as *mut char, 32);
        self.fresh((&mut rb.b[0]) as *mut char, 32);
        let lp = (&lb.b[0]) as *const char;
        let rp = (&rb.b[0]) as *const char;
        let mut lacc = Buf64 {};
        let mut racc = Buf64 {};
        if depth != 0 {
            unsafe stdio::snprintf((&mut lacc.b[0]) as *mut char, 48, "(*%s)".ptr as *const char, lp);
            unsafe stdio::snprintf((&mut racc.b[0]) as *mut char, 48, "(*%s)".ptr as *const char, rp);
        } else {
            unsafe stdio::snprintf((&mut lacc.b[0]) as *mut char, 48, "%s".ptr as *const char, lp);
            unsafe stdio::snprintf((&mut racc.b[0]) as *mut char, 48, "%s".ptr as *const char, rp);
        }
        let laccp = (&lacc.b[0]) as *const char;
        let raccp = (&racc.b[0]) as *const char;
        let mut ldecl = Buf256 {};
        let mut rdecl = Buf256 {};
        self.render_type_id(lt, lp, (&mut ldecl.b[0]) as *mut char, 256);
        self.render_type_id(lt, rp, (&mut rdecl.b[0]) as *mut char, 256);
        self.emit("({ %s = ".ptr as *const char, (&ldecl.b[0]) as *const char);
        self.emit_expr(a0);
        self.emit("; %s = ".ptr as *const char, (&rdecl.b[0]) as *const char);
        self.emit_expr(a1);
        self.emit_cstr("; if (".ptr as *const char);
        if kind == 2 { self.emit_cstr("!(".ptr as *const char); }
        if self.cg_struct_name_is(&y, "str".ptr as *const char) {
            self.emit("%s.len == %s.len && (%s.len == 0 || memcmp(%s.ptr, %s.ptr, %s.len) == 0)".ptr as *const char, laccp, raccp, laccp, laccp, raccp, laccp);
        } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE || (y.kind == TypeKind::TYPE_ENUM && self.aggregate_has_payload_in(y.module, y.as_data.decl)) {
            let mut om = y.module;
            let mut od = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
                om = it.module;
                od = it.decl;
            }
            let eq = self.cg_find_method_cstr(om, od, "eq".ptr as *const char);
            self.emit_op_method(y, om, od, eq);
            self.emit("(&%s, &%s)".ptr as *const char, laccp, raccp);
        } else {
            self.emit("%s == %s".ptr as *const char, laccp, raccp);
        }
        if kind == 2 { self.emit_cstr(")) {\n".ptr as *const char); } else { self.emit_cstr(") {\n".ptr as *const char); }
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_cstr("fprintf(stderr, \"assertion failed: `".ptr as *const char);
        self.emit_pct_escaped(unsafe (self.source + ls.start as usize), (ls.end - ls.start) as usize);
        if kind == 2 { self.emit_cstr(" == ".ptr as *const char); } else { self.emit_cstr(" != ".ptr as *const char); }
        self.emit_pct_escaped(unsafe (self.source + rs.start as usize), (rs.end - rs.start) as usize);
        self.emit_cstr("`\\n\");\n".ptr as *const char);
        self.emit_indent();
        self.emit_assert_value_line("left: ".ptr as *const char, laccp, y, base);
        self.emit_indent();
        self.emit_assert_value_line("right:".ptr as *const char, raccp, y, base);
        self.emit_indent();
        self.emit_cstr("fprintf(stderr, \"  at ".ptr as *const char);
        self.emit_pct_escaped(file as *const u8, unsafe cstring::strlen(file));
        self.emit(":%u\\n\");\n".ptr as *const char, line);
        self.emit_indent();
        self.emit_cstr("abort();\n".ptr as *const char);
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("}".ptr as *const char);
        let mut i: i32 = 0;
        while i < 2 {
            let ai = if (i == 0) { a0; } else { a1; };
            if !self.is_lvalue(ai) && depth == 0 && self.cg_type_is_free(base) {
                self.emit_cstr(" ".ptr as *const char);
                self.emit_free_target(base);
                let nmp = if (i == 0) { lp; } else { rp; };
                self.emit("(&%s);".ptr as *const char, nmp);
            }
            i = i + 1;
        }
        self.emit_cstr(" })".ptr as *const char);
        return true;
    }
    fn cb_known_callee(self: &mut Self, arg: NodeId, out: *mut DefId, is_closure: *mut bool) bool {
        let ak = unsafe (*self.cur_ast()).at_const(arg).kind;
        if ak == NodeKind::NODE_CLOSURE {
            unsafe (*out) = DefId { module: self.cur_module(), node: arg };
            unsafe (*is_closure) = true;
            return true;
        }
        if ak == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(arg);
            if d.node != NODE_NONE {
                let dnk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind;
                let dbody = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.body;
                if dnk == NodeKind::NODE_FUNCTION && dbody != NODE_NONE {
                    unsafe (*out) = d;
                    unsafe (*is_closure) = false;
                    return true;
                }
            }
        }
        return false;
    }
    fn cb_spec_name(self: &mut Self, fn2: DefId, callee: DefId, is_closure: bool, out: *mut char, cap: usize) void {
        self.function_name(fn2.node, DefId { module: 0, node: NODE_NONE }, out, cap, true);
        let at0 = unsafe cstring::strlen(out as *const char);
        let at = bappend(out, cap, at0, "__cb_".ptr as *const char);
        let mut sym = Buf200 {};
        if is_closure {
            self.closure_name(callee.node, (&mut sym.b[0]) as *mut char, 200);
        } else {
            let cn = unsafe (*self.mod_ast(callee.module)).at_const(callee.node).as_data.function.name;
            self.render_qualified(callee.module, cn, (&mut sym.b[0]) as *mut char, 200);
        }
        bappend(out, cap, at, (&sym.b[0]) as *const char);
    }
    fn cb_single_callback_param(self: &Self, fnNode: NodeId, cbidx: *mut u32, param: *mut NodeId) bool {
        let ps = unsafe (*self.cur_ast()).at_const(fnNode).as_data.function.params;
        let pids = unsafe (*self.cur_ast()).list(ps);
        let mut found: i32 = -1;
        let mut i: u32 = 0;
        while i < ps.len {
            let tn = unsafe (*self.cur_ast()).at_const(unsafe pids[i as usize]).as_data.parameter.ty;
            if tn != NODE_NONE && unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_FUNCTION_TYPE {
                if found >= 0 { return false; }
                found = i as i32;
            }
            i = i + 1;
        }
        if found < 0 { return false; }
        unsafe (*cbidx) = found as u32;
        unsafe (*param) = unsafe pids[found as usize];
        return true;
    }
    fn param_only_callee(self: &Self, param: NodeId) bool {
        let mut uses: u32 = 0;
        let mut callees: u32 = 0;
        let nn = unsafe (*self.cur_ast()).nodes.len();
        let mut i: u32 = 0;
        while (i as usize) < nn {
            let nk = unsafe (*self.cur_ast()).at_const(i).kind;
            if nk == NodeKind::NODE_IDENTIFIER {
                let d = unsafe (*self.cur_ast()).resolution_def(i);
                if d.module == self.cur_module() && d.node == param { uses = uses + 1; }
            } else if nk == NodeKind::NODE_CALL {
                let ce = unsafe (*self.cur_ast()).at_const(i).as_data.call.callee;
                if unsafe (*self.cur_ast()).at_const(ce).kind == NodeKind::NODE_IDENTIFIER {
                    let d = unsafe (*self.cur_ast()).resolution_def(ce);
                    if d.module == self.cur_module() && d.node == param { callees = callees + 1; }
                }
            }
            i = i + 1;
        }
        return uses == callees;
    }
    fn cb_record(self: &mut Self, fn2: DefId, param: NodeId, cbidx: u32, callee: DefId, is_closure: bool) void {
        let mut i: i32 = 0;
        while i < self.n_cb_insts {
            let ci = self.cb_insts[i as usize];
            if ci.func.node == fn2.node && ci.func.module == fn2.module && ci.callee.node == callee.node && ci.callee.module == callee.module && ci.callee_closure == is_closure { return; }
            i = i + 1;
        }
        if self.n_cb_insts >= 256 { return; }
        self.cb_insts[self.n_cb_insts as usize].func = fn2;
        self.cb_insts[self.n_cb_insts as usize].param = param;
        self.cb_insts[self.n_cb_insts as usize].cbidx = cbidx;
        self.cb_insts[self.n_cb_insts as usize].callee = callee;
        self.cb_insts[self.n_cb_insts as usize].callee_closure = is_closure;
        self.n_cb_insts = self.n_cb_insts + 1;
    }
    fn cb_keep(self: &mut Self, fn2: NodeId) void {
        let mut i: i32 = 0;
        while i < self.n_cb_keep { if self.cb_keep_fns[i as usize] == fn2 { return; } i = i + 1; }
        if self.n_cb_keep < 128 { self.cb_keep_fns[self.n_cb_keep as usize] = fn2; self.n_cb_keep = self.n_cb_keep + 1; }
    }
    fn cg_decl_name_node(self: &Self, m: ModuleId, decl: NodeId) NodeId {
        let dn = unsafe (*self.mod_ast(m)).at_const(decl);
        if dn.kind == NodeKind::NODE_TYPE_ALIAS { return dn.as_data.type_alias.name; }
        return dn.as_data.aggregate.name;
    }
    fn cg_conv_lit(self: &Self, m: ModuleId, name: tok::Span) *const char {
        if span_is(self.mod_src(m), name, "from".ptr as *const char) { return "from".ptr as *const char; }
        if span_is(self.mod_src(m), name, "try_from".ptr as *const char) { return "try_from".ptr as *const char; }
        return null;
    }
    fn emit_deref_hop(self: &mut Self, recv: TypeId, md: DefId) void {
        let b = *self.type_at(self.subst_resolve(recv));
        if b.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(b.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
            self.emit_cstr((&inm.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else if b.kind == TypeKind::TYPE_STRUCT || b.kind == TypeKind::TYPE_ENUM {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_ident_mod(b.module, unsafe (*self.mod_ast(b.module)).at_const(b.as_data.decl).as_data.aggregate.name);
            self.emit_cstr("__".ptr as *const char);
        }
        self.emit_ident_mod(md.module, unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name);
        self.emit_cstr("(".ptr as *const char);
    }
    fn emit_call_args(self: &mut Self, args: NodeList) void {
        let mut i: u32 = 0;
        while i < args.len { if i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); i = i + 1; }
    }
    fn emit_call_path(self: &mut Self, id: NodeId, n: Node, callee: Node) bool {
        let args = n.as_data.call.args;
        let member = callee.as_data.member.member;
        let md = unsafe (*self.cur_ast()).resolution_def(member);
        if md.node == NODE_NONE { return false; }
        let mdk = unsafe (*self.mod_ast(md.module)).at_const(md.node).kind;
        if mdk == NodeKind::NODE_VARIANT { self.emit_variant_construct(md, args, unsafe (*self.cur_ast()).list(args), unsafe (*self.cur_ast()).type_of(id)); return true; }
        if mdk != NodeKind::NODE_FUNCTION { return false; }
        let mut ov = Buf256 {};
        let ovr = self.cg_symbol_override(md.module, md.node, (&mut ov.b[0]) as *mut char, 160);
        if ovr || unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.is_extern {
            if ovr { self.emit_cstr((&ov.b[0]) as *const char); } else { self.emit_ident_mod(md.module, unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name); }
            self.emit_cstr("(".ptr as *const char);
            self.emit_call_args(args);
            self.emit_cstr(")".ptr as *const char);
            return true;
        }
        let base_t = unsafe (*self.cur_ast()).type_of(callee.as_data.member.object);
        let td = unsafe (*self.cur_ast()).resolution_def(callee.as_data.member.object);
        let mut emd = md;
        let mut param_tgt = TYPE_NONE;
        if td.node != NODE_NONE && unsafe (*self.mod_ast(td.module)).at_const(td.node).kind == NodeKind::NODE_GENERIC_PARAM {
            let r = self.subst_resolve(unsafe (*self.cur_ast()).intern_type(Ty { kind: TypeKind::TYPE_GENERIC, module: td.module, as_data: TyAs { decl: td.node } }));
            if self.type_is_concrete(r) { param_tgt = r; }
        } else if td.node != NODE_NONE && unsafe (*self.mod_ast(td.module)).at_const(td.node).kind == NodeKind::NODE_INTERFACE {
            let r = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            if self.type_is_concrete(r) { param_tgt = r; }
        }
        if base_t != TYPE_NONE && self.type_at(base_t).kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(self.type_at(base_t).as_data.inst), (&mut inm.b[0]) as *mut char, 200);
            self.emit_cstr((&inm.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else if param_tgt != TYPE_NONE && self.type_at(param_tgt).kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bt = self.type_at(param_tgt).as_data.builtin;
            let bd = unsafe (*self.package).builtin_decl(bt);
            if bd != NODE_NONE {
                let cm = self.cg_find_method(unsafe (*self.package).core_module, bd, self.source, self.name_span(member));
                if cm.node != NODE_NONE { emd = cm; }
            }
            let mut pfx = Buf64 {};
            self.render_modpfx(emd.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_cstr(builtin_name(bt));
            self.emit_cstr("__".ptr as *const char);
        } else if param_tgt != TYPE_NONE {
            let rb = *self.type_at(param_tgt);
            let mut omod: ModuleId = 0;
            let mut odecl = NODE_NONE;
            if rb.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(rb.as_data.inst); omod = it.module; odecl = it.decl; }
            else { omod = rb.module; odecl = rb.as_data.decl; }
            let cm = self.cg_find_method(omod, odecl, self.source, self.name_span(member));
            if cm.node != NODE_NONE { emd = cm; }
            if rb.kind == TypeKind::TYPE_INSTANCE {
                let mut inm = Buf256 {};
                self.inst_name(unsafe (*self.cur_ast()).instance(rb.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
                self.emit_cstr((&inm.b[0]) as *const char);
                self.emit_paste();
                self.emit_cstr("__".ptr as *const char);
            } else if rb.kind == TypeKind::TYPE_STRUCT || rb.kind == TypeKind::TYPE_ENUM {
                let mut pfx = Buf64 {};
                self.render_modpfx(emd.module, (&mut pfx.b[0]) as *mut char, 64);
                self.emit_cstr((&pfx.b[0]) as *const char);
                self.emit_ident_mod(omod, unsafe (*self.mod_ast(omod)).at_const(odecl).as_data.aggregate.name);
                self.emit_cstr("__".ptr as *const char);
            }
        } else if self.macro_mode && td.node != NODE_NONE && unsafe (*self.mod_ast(td.module)).at_const(td.node).kind == NodeKind::NODE_GENERIC_PARAM {
            let mut pp = Buf64 {};
            self.emit_cstr("_SCM_".ptr as *const char);
            self.render_macro_param(td.module, td.node, (&mut pp.b[0]) as *mut char, 64);
            self.emit_cstr((&pp.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            if td.node != NODE_NONE {
                let mut bb: i32 = -1;
                if self.package != null { bb = unsafe (*self.package).builtin_of_decl(td.module, td.node); }
                if bb >= 0 { self.emit_cstr(builtin_name(bb as BuiltinType)); }
                else { self.emit_ident_mod(td.module, self.cg_decl_name_node(td.module, td.node)); }
                self.emit_cstr("__".ptr as *const char);
            }
        }
        self.emit_ident_mod(emd.module, unsafe (*self.mod_ast(emd.module)).at_const(emd.node).as_data.function.name);
        if td.node != NODE_NONE && args.len != 0 {
            let mut sfx = Buf256 {};
            let a0t = unsafe (*self.cur_ast()).type_of(unsafe ((*self.cur_ast()).list(args))[0]);
            self.cg_conv_suffix(td, self.cg_conv_lit(self.cur_module(), self.name_span(member)), a0t, (&mut sfx.b[0]) as *mut char, 200);
            self.emit_cstr((&sfx.b[0]) as *const char);
        }
        self.emit_method_targs(id, emd);
        self.emit_cstr("(".ptr as *const char);
        self.emit_call_args(args);
        self.emit_cstr(")".ptr as *const char);
        return true;
    }
    fn emit_call_method(self: &mut Self, id: NodeId, n: Node, callee: Node) bool {
        let args = n.as_data.call.args;
        let member = callee.as_data.member.member;
        let obj = callee.as_data.member.object;
        let mut md = unsafe (*self.cur_ast()).resolution_def(member);
        if md.node == NODE_NONE || unsafe (*self.mod_ast(md.module)).at_const(md.node).kind != NodeKind::NODE_FUNCTION { return false; }
        // into/try_into conversion
        let memn = self.name_span(member);
        let mdn = unsafe (*self.mod_ast(md.module)).at_const(unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name).as_data.name.text;
        let conv = (span_is(self.mod_src(self.cur_module()), memn, "into".ptr as *const char) && span_is(self.mod_src(md.module), mdn, "from".ptr as *const char)) || (span_is(self.mod_src(self.cur_module()), memn, "try_into".ptr as *const char) && span_is(self.mod_src(md.module), mdn, "try_from".ptr as *const char));
        if conv {
            let mut tgt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            if span_is(self.mod_src(md.module), mdn, "try_from".ptr as *const char) && self.type_at(tgt).kind == TypeKind::TYPE_INSTANCE { tgt = self.subst_resolve(unsafe (*self.cur_ast()).instance(self.type_at(tgt).as_data.inst).args[0]); }
            let tb = *self.type_at(tgt);
            let mut ct = DefId { module: tb.module, node: tb.as_data.decl };
            if tb.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(tb.as_data.inst);
                ct = DefId { module: it.module, node: it.decl };
                let mut inm = Buf256 {};
                self.inst_name(unsafe (*self.cur_ast()).instance(tb.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
                self.emit_cstr((&inm.b[0]) as *const char);
                self.emit_paste();
                self.emit_cstr("__".ptr as *const char);
            } else {
                let mut pfx = Buf64 {};
                self.render_modpfx(md.module, (&mut pfx.b[0]) as *mut char, 64);
                self.emit_cstr((&pfx.b[0]) as *const char);
                self.emit_ident_mod(tb.module, unsafe (*self.mod_ast(tb.module)).at_const(tb.as_data.decl).as_data.aggregate.name);
                self.emit_cstr("__".ptr as *const char);
            }
            self.emit_ident_mod(md.module, unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name);
            let mut sfx = Buf256 {};
            self.cg_conv_suffix(ct, self.cg_conv_lit(md.module, mdn), unsafe (*self.cur_ast()).type_of(obj), (&mut sfx.b[0]) as *mut char, 200);
            self.emit_cstr((&sfx.b[0]) as *const char);
            self.emit_cstr("(".ptr as *const char);
            self.emit_expr(obj);
            self.emit_cstr(")".ptr as *const char);
            return true;
        }
        let obj_t = unsafe (*self.cur_ast()).type_of(obj);
        let pointee = self.strip_ptr(obj_t);
        let du = unsafe (*self.cur_ast()).deref_use_at(member);
        // generic-param receiver -> concrete method
        if self.type_at(pointee).kind == TypeKind::TYPE_GENERIC {
            let rb = *self.type_at(self.subst_resolve(pointee));
            if rb.kind == TypeKind::TYPE_STRUCT || rb.kind == TypeKind::TYPE_ENUM {
                let cm = self.cg_find_method(rb.module, rb.as_data.decl, self.mod_src(self.cur_module()), self.name_span(member));
                if cm.node != NODE_NONE { md = cm; }
            } else if rb.kind == TypeKind::TYPE_BUILTIN && self.package != null {
                let bd = unsafe (*self.package).builtin_decl(rb.as_data.builtin);
                if bd != NODE_NONE { let cm = self.cg_find_method(unsafe (*self.package).core_module, bd, self.mod_src(self.cur_module()), self.name_span(member)); if cm.node != NODE_NONE { md = cm; } }
            }
        }
        // dyn receiver: vtable dispatch
        let dt = self.subst_resolve(pointee);
        if self.type_at(dt).kind == TypeKind::TYPE_DYN {
            let mut mn = Buf128 {};
            render_ident_src(self.mod_src(md.module), unsafe (*self.mod_ast(md.module)).at_const(unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.name).as_data.name.text, (&mut mn.b[0]) as *mut char, 128);
            let ok = self.type_at(obj_t).kind;
            let obj_ind = ok == TypeKind::TYPE_POINTER || ok == TypeKind::TYPE_REFERENCE;
            let simple = !obj_ind && unsafe (*self.cur_ast()).at_const(obj).kind == NodeKind::NODE_IDENTIFIER;
            let mut tmp = Buf32 {};
            if simple {
                self.emit_expr(obj);
                self.emit(".vt->%s(".ptr as *const char, (&mn.b[0]) as *const char);
                self.emit_expr(obj);
                self.emit_cstr(".data".ptr as *const char);
            } else {
                let mut dtn = Buf256 {};
                self.render_type_id(dt, "".ptr as *const char, (&mut dtn.b[0]) as *mut char, 240);
                self.fresh((&mut tmp.b[0]) as *mut char, 32);
                self.emit("({ const %s %s = ".ptr as *const char, (&dtn.b[0]) as *const char, (&tmp.b[0]) as *const char);
                if obj_ind { self.emit_cstr("*".ptr as *const char); }
                self.emit_expr(obj);
                self.emit("; %s.vt->%s(%s.data".ptr as *const char, (&tmp.b[0]) as *const char, (&mn.b[0]) as *const char, (&tmp.b[0]) as *const char);
            }
            let mut i: u32 = 0;
            while i < args.len { self.emit_cstr(", ".ptr as *const char); self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); i = i + 1; }
            self.emit_cstr(")".ptr as *const char);
            if !simple { self.emit_cstr("; })".ptr as *const char); }
            return true;
        }
        let ma = self.mod_ast(md.module);
        let mut basety = pointee;
        if du != null { basety = unsafe (*du).target; }
        let base = *self.type_at(self.subst_resolve(basety));
        let params = unsafe (*ma).at_const(md.node).as_data.function.params;
        let mut self_type = NODE_NONE;
        if params.len != 0 { self_type = unsafe (*ma).at_const(unsafe ((*ma).list(params))[0]).as_data.parameter.ty; }
        let mut sk = NodeKind::NODE_NONE_KIND;
        if self_type != NODE_NONE { sk = unsafe (*ma).at_const(self_type).kind; }
        let self_ptr = sk == NodeKind::NODE_POINTER_TYPE || sk == NodeKind::NODE_REFERENCE_TYPE;
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
            self.fresh((&mut tmp.b[0]) as *mut char, 32);
            self.emit("({ __auto_type %s = ".ptr as *const char, (&tmp.b[0]) as *const char);
            self.emit_expr(obj);
            self.emit_cstr("; ".ptr as *const char);
            if free_tmp && !void_ret { self.fresh((&mut tres.b[0]) as *mut char, 32); self.emit("__auto_type %s = ".ptr as *const char, (&tres.b[0]) as *const char); }
        }
        let xt = self.cg_method_extend_target(md);
        let mut xtk = NodeKind::NODE_NONE_KIND;
        if xt.node != NODE_NONE { xtk = unsafe (*self.mod_ast(xt.module)).at_const(xt.node).kind; }
        if xt.node != NODE_NONE && xtk == NodeKind::NODE_TYPE_ALIAS {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_ident_mod(xt.module, self.cg_decl_name_node(xt.module, xt.node));
            self.emit_cstr("__".ptr as *const char);
        } else if self.macro_mode && base.kind == TypeKind::TYPE_GENERIC {
            let mut pp = Buf64 {};
            self.emit_cstr("_SCM_".ptr as *const char);
            self.render_macro_param(base.module, base.as_data.decl, (&mut pp.b[0]) as *mut char, 64);
            self.emit_cstr((&pp.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else if base.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(base.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
            self.emit_cstr((&inm.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else if base.kind == TypeKind::TYPE_STRUCT || base.kind == TypeKind::TYPE_ENUM {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_ident_mod(base.module, unsafe (*self.mod_ast(base.module)).at_const(base.as_data.decl).as_data.aggregate.name);
            self.emit_cstr("__".ptr as *const char);
        } else if base.kind == TypeKind::TYPE_BUILTIN {
            let mut pfx = Buf64 {};
            self.render_modpfx(md.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_cstr(builtin_name(base.as_data.builtin));
            self.emit_cstr("__".ptr as *const char);
        } else {
            self.errors.emitf(n.span.start, n.span.end - n.span.start, "codegen: method receiver is not a struct or enum".ptr as *const char);
        }
        self.emit_ident_mod(md.module, unsafe (*ma).at_const(md.node).as_data.function.name);
        self.emit_method_targs(id, md);
        self.emit_cstr("(".ptr as *const char);
        let mut wrote = false;
        if params.len > 0 && du != null {
            if !self_ptr { self.emit_cstr("*".ptr as *const char); }
            let mut i = unsafe (*du).n;
            while i > 0 { i = i - 1; self.emit_deref_hop(unsafe (*du).recv[i as usize], unsafe (*du).method[i as usize]); }
            if materialize { self.emit("&%s".ptr as *const char, (&tmp.b[0]) as *const char); }
            else if !obj_ptr { self.emit_prefixed(obj, "&".ptr as *const char); }
            else { self.emit_expr(obj); }
            let mut j: u8 = 0;
            while j < unsafe (*du).n { self.emit_cstr(")".ptr as *const char); j = j + 1; }
            wrote = true;
        } else if params.len > 0 {
            if materialize { self.emit("&%s".ptr as *const char, (&tmp.b[0]) as *const char); }
            else if self_ptr && !obj_ptr { self.emit_prefixed(obj, "&".ptr as *const char); }
            else if !self_ptr && obj_ptr { self.emit_prefixed(obj, "*".ptr as *const char); }
            else { self.emit_expr(obj); }
            wrote = true;
        }
        let mut i: u32 = 0;
        while i < args.len { if wrote || i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); i = i + 1; }
        self.emit_cstr(")".ptr as *const char);
        if materialize {
            if free_tmp {
                self.emit_cstr("; ".ptr as *const char);
                self.emit_free_target(obj_t);
                self.emit("(&%s);".ptr as *const char, (&tmp.b[0]) as *const char);
                if !void_ret { self.emit(" %s;".ptr as *const char, (&tres.b[0]) as *const char); }
                self.emit_cstr(" })".ptr as *const char);
            } else { self.emit_cstr("; })".ptr as *const char); }
        }
        return true;
    }
    fn emit_call(self: &mut Self, id: NodeId) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let callee_id = n.as_data.call.callee;
        let callee = *unsafe (*self.cur_ast()).at_const(callee_id);
        let args = n.as_data.call.args;
        if self.emit_format_builtin(id) { return; }
        if self.emit_assert_builtin(id) { return; }
        // `x.free()` intrinsic on an unresolved generic receiver
        if callee.kind == NodeKind::NODE_MEMBER && !callee.as_data.member.path && args.len == 0 && unsafe (*self.cur_ast()).resolution_def(callee.as_data.member.member).node == NODE_NONE && span_is(self.mod_src(self.cur_module()), unsafe (*self.cur_ast()).at_const(callee.as_data.member.member).as_data.name.text, "free".ptr as *const char) {
            let recv = callee.as_data.member.object;
            let raw = *self.type_at(unsafe (*self.cur_ast()).type_of(recv));
            let isref = raw.kind == TypeKind::TYPE_POINTER || raw.kind == TypeKind::TYPE_REFERENCE;
            let rt = *self.type_at(self.subst_resolve(self.strip_ptr(unsafe (*self.cur_ast()).type_of(recv))));
            if rt.kind == TypeKind::TYPE_DYN && rt.qualifier == (TypeQualifier::TYPE_QUAL_NONE as u8) {
                let mut stem = Buf256 {};
                self.dyn_stem(rt.module, rt.as_data.decl, (&mut stem.b[0]) as *mut char, 176);
                self.emit("%s__dyn_free".ptr as *const char, (&stem.b[0]) as *const char);
                if isref { self.emit_cstr("(".ptr as *const char); } else { self.emit_cstr("(&".ptr as *const char); }
                self.emit_expr(recv);
                self.emit_cstr(")".ptr as *const char);
                return;
            }
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            if rt.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(rt.as_data.inst); om = it.module; od = it.decl; }
            else if rt.kind == TypeKind::TYPE_STRUCT { om = rt.module; od = rt.as_data.decl; }
            let mut fm = DefId { module: 0, node: NODE_NONE };
            if od != NODE_NONE { fm = self.cg_find_method_cstr(om, od, "free".ptr as *const char); }
            if fm.node != NODE_NONE {
                self.emit_op_method(rt, om, od, fm);
                if isref { self.emit_cstr("(".ptr as *const char); } else { self.emit_cstr("(&".ptr as *const char); }
                self.emit_expr(recv);
                self.emit_cstr(")".ptr as *const char);
            } else if self.macro_mode && rt.kind == TypeKind::TYPE_GENERIC {
                let mut pp = Buf64 {};
                self.emit_cstr("_SCM_".ptr as *const char);
                self.render_macro_param(rt.module, rt.as_data.decl, (&mut pp.b[0]) as *mut char, 64);
                self.emit_cstr((&pp.b[0]) as *const char);
                self.emit_paste();
                self.emit_cstr("__free".ptr as *const char);
                if isref { self.emit_cstr("(".ptr as *const char); } else { self.emit_cstr("(&".ptr as *const char); }
                self.emit_expr(recv);
                self.emit_cstr(")".ptr as *const char);
            } else {
                self.emit_cstr("(void)(".ptr as *const char);
                self.emit_expr(recv);
                self.emit_cstr(")".ptr as *const char);
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
                    self.render_type_id(self.subst_resolve(unsafe (*self.cur_ast()).type_of(id)), "".ptr as *const char, (&mut tn.b[0]) as *mut char, 200);
                    self.emit("(%s){ ".ptr as *const char, (&tn.b[0]) as *const char);
                    let mut i: u32 = 0;
                    while i < args.len { if i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit("._%u = ".ptr as *const char, i); self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); i = i + 1; }
                    if args.len != 0 { self.emit_cstr(" }".ptr as *const char); } else { self.emit_cstr("0 }".ptr as *const char); }
                    return;
                }
            }
        }
        // callback specialization: call to elided cb param
        if self.cb_param != NODE_NONE && callee.kind == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(callee_id);
            if d.module == self.cur_module() && d.node == self.cb_param {
                let mut sym = Buf256 {};
                if self.cb_callee_closure { self.closure_name(self.cb_callee.node, (&mut sym.b[0]) as *mut char, 200); }
                else { self.render_qualified(self.cb_callee.module, unsafe (*self.mod_ast(self.cb_callee.module)).at_const(self.cb_callee.node).as_data.function.name, (&mut sym.b[0]) as *mut char, 200); }
                self.emit_cstr((&sym.b[0]) as *const char);
                self.emit_cstr("(".ptr as *const char);
                self.emit_call_args(args);
                self.emit_cstr(")".ptr as *const char);
                return;
            }
        }
        // callback specialization: call site with known callback
        if callee.kind == NodeKind::NODE_IDENTIFIER {
            let fn2 = unsafe (*self.cur_ast()).resolution_def(callee_id);
            let mut k: i32 = 0;
            while k < self.n_cb_insts {
                if self.cb_insts[k as usize].func.node == fn2.node && self.cb_insts[k as usize].func.module == fn2.module {
                    let cbidx = self.cb_insts[k as usize].cbidx;
                    let mut ac = DefId { module: 0, node: NODE_NONE };
                    let mut acclo = false;
                    let mut known = false;
                    if cbidx < args.len { known = self.cb_known_callee(unsafe ((*self.cur_ast()).list(args))[cbidx as usize], (&mut ac) as *mut DefId, (&mut acclo) as *mut bool); }
                    if known && ac.node == self.cb_insts[k as usize].callee.node && ac.module == self.cb_insts[k as usize].callee.module {
                        let mut nm = Buf256 {};
                        self.cb_spec_name(fn2, ac, acclo, (&mut nm.b[0]) as *mut char, 260);
                        self.emit_cstr((&nm.b[0]) as *const char);
                        self.emit_cstr("(".ptr as *const char);
                        let mut wrote = false;
                        let mut i: u32 = 0;
                        while i < args.len { if i != cbidx { if wrote { self.emit_cstr(", ".ptr as *const char); } self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); wrote = true; } i = i + 1; }
                        self.emit_cstr(")".ptr as *const char);
                        return;
                    }
                }
                k = k + 1;
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
                    self.emit_cstr(".vt->call(".ptr as *const char);
                    self.emit_expr(callee_id);
                    self.emit_cstr(".data".ptr as *const char);
                } else {
                    let mut dtn = Buf256 {};
                    self.render_type_id(self.subst_resolve(ct0), "".ptr as *const char, (&mut dtn.b[0]) as *mut char, 240);
                    self.fresh((&mut tmp.b[0]) as *mut char, 32);
                    self.emit("({ const %s %s = ".ptr as *const char, (&dtn.b[0]) as *const char, (&tmp.b[0]) as *const char);
                    self.emit_expr(callee_id);
                    self.emit("; %s.vt->call(%s.data".ptr as *const char, (&tmp.b[0]) as *const char, (&tmp.b[0]) as *const char);
                }
                let mut i: u32 = 0;
                while i < args.len { self.emit_cstr(", ".ptr as *const char); self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); i = i + 1; }
                self.emit_cstr(")".ptr as *const char);
                if !simple { self.emit_cstr("; })".ptr as *const char); }
                return;
            }
            if cty.kind == TypeKind::TYPE_FUNCTION && self.cg_fn_is_capturing(&cty) {
                let mut sym = Buf256 {};
                self.closure_sym_in(cty.module, cty.as_data.decl, (&mut sym.b[0]) as *mut char, 200);
                self.emit("%s(&(".ptr as *const char, (&sym.b[0]) as *const char);
                self.emit_expr(callee_id);
                self.emit_cstr(")".ptr as *const char);
                let mut i: u32 = 0;
                while i < args.len { self.emit_cstr(", ".ptr as *const char); self.emit_expr(unsafe ((*self.cur_ast()).list(args))[i as usize]); i = i + 1; }
                self.emit_cstr(")".ptr as *const char);
                return;
            }
        }
        // generic function specialization
        let mut ga = TyArgs4 {};
        let mut gn: i32 = 0;
        let g = self.generic_call_target(id, (&mut ga.t[0]) as *mut TypeId, (&mut gn) as *mut i32);
        if g.node != NODE_NONE {
            let mut k: i32 = 0;
            while k < gn { ga.t[k as usize] = self.subst_resolve(ga.t[k as usize]); k = k + 1; }
            let mut nm = Buf256 {};
            self.spec_name(g, (&ga.t[0]) as *const TypeId, gn, (&mut nm.b[0]) as *mut char, 256);
            self.emit_cstr((&nm.b[0]) as *const char);
            self.emit_cstr("(".ptr as *const char);
            self.emit_call_args(args);
            self.emit_cstr(")".ptr as *const char);
            return;
        }
        if callee.kind == NodeKind::NODE_MEMBER && callee.as_data.member.path { if self.emit_call_path(id, n, callee) { return; } }
        if callee.kind == NodeKind::NODE_MEMBER && !callee.as_data.member.path { if self.emit_call_method(id, n, callee) { return; } }
        self.emit_expr(callee_id);
        self.emit_cstr("(".ptr as *const char);
        self.emit_call_args(args);
        self.emit_cstr(")".ptr as *const char);
    }
    fn emit_struct_init(self: &mut Self, id: NodeId) void {
        let si = unsafe (*self.cur_ast()).at_const(id).as_data.struct_initializer;
        let mut t = Buf256 {};
        self.render_type_node(si.ty, "".ptr as *const char, (&mut t.b[0]) as *mut char, 256);
        let fields = si.fields;
        let stn = si.ty;
        if unsafe (*self.cur_ast()).at_const(stn).kind == NodeKind::NODE_TYPE_PATH {
            let parts = unsafe (*self.cur_ast()).at_const(stn).as_data.type_path.parts;
            if parts.len >= 2 {
                let vd = unsafe (*self.cur_ast()).resolution_def(unsafe ((*self.cur_ast()).list(parts))[(parts.len - 1) as usize]);
                if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                    let en = self.enclosing_enum_in(vd.module, vd.node);
                    let mut vn = Buf128 {};
                    self.render_variant_name(vd.module, vd.node, (&mut vn.b[0]) as *mut char, 128);
                    self.emit("(%s){ .tag = ".ptr as *const char, (&t.b[0]) as *const char);
                    if en != NODE_NONE { self.emit_tag_mod(vd.module, en, vd.node); } else { self.emit_cstr("0".ptr as *const char); }
                    self.emit(", .payload.%s = {".ptr as *const char, (&vn.b[0]) as *const char);
                    let mut i: u32 = 0;
                    while i < fields.len {
                        let fi = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(fields))[i as usize]).as_data.field_initializer;
                        if i != 0 { self.emit_cstr(", .".ptr as *const char); } else { self.emit_cstr(" .".ptr as *const char); }
                        self.emit_ident(self.name_span(fi.name));
                        self.emit_cstr(" = ".ptr as *const char);
                        if unsafe (*self.cur_ast()).at_const(fi.value).kind == NodeKind::NODE_ARRAY_LITERAL { self.emit_array_braces(fi.value); } else { self.emit_expr(fi.value); }
                        i = i + 1;
                    }
                    if fields.len != 0 { self.emit_cstr(" } }".ptr as *const char); } else { self.emit_cstr("0 } }".ptr as *const char); }
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
            if zero_fields { self.emit("(%s){}".ptr as *const char, (&t.b[0]) as *const char); } else { self.emit("(%s){0}".ptr as *const char, (&t.b[0]) as *const char); }
            return;
        }
        let mut arr_copy = false;
        let mut i: u32 = 0;
        while i < fields.len {
            let fv = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(fields))[i as usize]).as_data.field_initializer.value;
            let fvt = unsafe (*self.cur_ast()).type_of(fv);
            if unsafe (*self.cur_ast()).at_const(fv).kind != NodeKind::NODE_ARRAY_LITERAL && fvt != TYPE_NONE && self.type_at(fvt).kind == TypeKind::TYPE_ARRAY { arr_copy = true; }
            i = i + 1;
        }
        let mut st = Buf32 {};
        if arr_copy { self.fresh((&mut st.b[0]) as *mut char, 32); self.emit("({ %s %s = ".ptr as *const char, (&t.b[0]) as *const char, (&st.b[0]) as *const char); }
        self.emit("(%s){ ".ptr as *const char, (&t.b[0]) as *const char);
        i = 0;
        while i < fields.len {
            let fi = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(fields))[i as usize]).as_data.field_initializer;
            if i != 0 { self.emit_cstr(", ".ptr as *const char); }
            self.emit_cstr(".".ptr as *const char);
            self.emit_ident(self.name_span(fi.name));
            self.emit_cstr(" = ".ptr as *const char);
            let fvt = unsafe (*self.cur_ast()).type_of(fi.value);
            let arr_field = unsafe (*self.cur_ast()).at_const(fi.value).kind != NodeKind::NODE_ARRAY_LITERAL && fvt != TYPE_NONE && self.type_at(fvt).kind == TypeKind::TYPE_ARRAY;
            if unsafe (*self.cur_ast()).at_const(fi.value).kind == NodeKind::NODE_ARRAY_LITERAL { self.emit_array_braces(fi.value); }
            else if arr_field { self.emit_cstr("{0}".ptr as *const char); }
            else { self.emit_expr(fi.value); }
            i = i + 1;
        }
        self.emit_cstr(" }".ptr as *const char);
        if !arr_copy { return; }
        self.emit_cstr(";".ptr as *const char);
        i = 0;
        while i < fields.len {
            let fi = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(fields))[i as usize]).as_data.field_initializer;
            let fvt = unsafe (*self.cur_ast()).type_of(fi.value);
            if unsafe (*self.cur_ast()).at_const(fi.value).kind == NodeKind::NODE_ARRAY_LITERAL || fvt == TYPE_NONE || self.type_at(fvt).kind != TypeKind::TYPE_ARRAY { i = i + 1; continue; }
            self.emit(" memcpy(&%s.".ptr as *const char, (&st.b[0]) as *const char);
            self.emit_ident(self.name_span(fi.name));
            self.emit_cstr(", &(".ptr as *const char);
            self.emit_expr(fi.value);
            self.emit("), sizeof %s.".ptr as *const char, (&st.b[0]) as *const char);
            self.emit_ident(self.name_span(fi.name));
            self.emit_cstr(");".ptr as *const char);
            i = i + 1;
        }
        self.emit(" %s; })".ptr as *const char, (&st.b[0]) as *const char);
    }
    fn emit_new(self: &mut Self, id: NodeId) void {
        let ne = unsafe (*self.cur_ast()).at_const(id).as_data.new_expr;
        let mut t = Buf256 {};
        self.render_type_node(ne.ty, "".ptr as *const char, (&mut t.b[0]) as *mut char, 256);
        if ne.initializer == NODE_NONE { self.emit("((%s*)malloc(sizeof(%s)))".ptr as *const char, (&t.b[0]) as *const char, (&t.b[0]) as *const char); return; }
        let mut tmp = Buf32 {};
        self.fresh((&mut tmp.b[0]) as *mut char, 32);
        self.emit("({ %s *%s = malloc(sizeof(%s)); *%s = ".ptr as *const char, (&t.b[0]) as *const char, (&tmp.b[0]) as *const char, (&t.b[0]) as *const char, (&tmp.b[0]) as *const char);
        self.emit_expr(ne.initializer);
        self.emit("; %s; })".ptr as *const char, (&tmp.b[0]) as *const char);
    }
    fn emit_match_expr(self: &mut Self, id: NodeId) void {
        let rt = unsafe (*self.cur_ast()).type_of(id);
        let mut res = Buf32 {};
        self.fresh((&mut res.b[0]) as *mut char, 32);
        let mut decl = Buf256 {};
        if rt != TYPE_NONE { self.render_type_id(rt, (&res.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 256); }
        else { buf_join3((&mut decl.b[0]) as *mut char, 256, "int ".ptr as *const char, "".ptr as *const char, (&res.b[0]) as *const char); }
        self.emit_cstr("({\n".ptr as *const char);
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_cstr((&decl.b[0]) as *const char);
        self.emit_cstr(";\n".ptr as *const char);
        self.emit_match_core(id, 1, (&res.b[0]) as *const char);
        self.emit_indent();
        self.emit_cstr((&res.b[0]) as *const char);
        self.emit_cstr(";\n".ptr as *const char);
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("})".ptr as *const char);
    }
    fn emit_match_stmt(self: &mut Self, id: NodeId) void {
        self.emit_cstr("{\n".ptr as *const char);
        self.depth = self.depth + 1;
        self.emit_match_core(id, 0, null);
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("}\n".ptr as *const char);
    }
    fn emit_if_expr(self: &mut Self, id: NodeId) void {
        let rt = unsafe (*self.cur_ast()).type_of(id);
        let mut res = Buf32 {};
        self.fresh((&mut res.b[0]) as *mut char, 32);
        let mut decl = Buf256 {};
        if rt != TYPE_NONE { self.render_type_id(rt, (&res.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 256); }
        else { buf_join3((&mut decl.b[0]) as *mut char, 256, "int ".ptr as *const char, "".ptr as *const char, (&res.b[0]) as *const char); }
        self.emit_cstr("({\n".ptr as *const char);
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_cstr((&decl.b[0]) as *const char);
        self.emit_cstr(";\n".ptr as *const char);
        self.emit_indent();
        self.emit_if_value(id, (&res.b[0]) as *const char);
        self.emit_cstr("\n".ptr as *const char);
        self.emit_indent();
        self.emit_cstr((&res.b[0]) as *const char);
        self.emit_cstr(";\n".ptr as *const char);
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("})".ptr as *const char);
    }
    fn emit_try(self: &mut Self, id: NodeId) void {
        let operand = unsafe (*self.cur_ast()).at_const(id).as_data.unary.operand;
        let bt = *self.type_at(self.subst_resolve(self.strip_ptr(unsafe (*self.cur_ast()).type_of(operand))));
        if bt.kind != TypeKind::TYPE_INSTANCE { self.emit_expr(operand); return; }
        let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst);
        let om = it.module;
        let od = it.decl;
        let noneV = self.cg_enum_variant(om, od, "None".ptr as *const char);
        let is_option = noneV != NODE_NONE;
        let mut failV = noneV;
        if !is_option { failV = self.cg_enum_variant(om, od, "Err".ptr as *const char); }
        let mut okName2 = "Ok".ptr as *const char;
        if is_option { okName2 = "Some".ptr as *const char; }
        let okV = self.cg_enum_variant(om, od, okName2);
        let mut okName = Buf128 {};
        let mut failName = Buf128 {};
        self.render_variant_name(om, okV, (&mut okName.b[0]) as *mut char, 128);
        self.render_variant_name(om, failV, (&mut failName.b[0]) as *mut char, 128);
        let mut rtn = Buf256 {};
        rtn.b[0] = 0 as char;
        if self.current_fn_ret_node != NODE_NONE { self.render_type_node(self.current_fn_ret_node, "".ptr as *const char, (&mut rtn.b[0]) as *mut char, 200); }
        let mut tmp = Buf32 {};
        self.fresh((&mut tmp.b[0]) as *mut char, 32);
        self.emit("({ __auto_type %s = ".ptr as *const char, (&tmp.b[0]) as *const char);
        self.emit_expr(operand);
        self.emit("; if (%s.tag == ".ptr as *const char, (&tmp.b[0]) as *const char);
        self.emit_tag_mod(om, od, failV);
        self.emit_cstr(") {\n".ptr as *const char);
        self.depth = self.depth + 1;
        self.emit_defers_to(0);
        self.emit_indent();
        self.emit("return (%s){ .tag = ".ptr as *const char, (&rtn.b[0]) as *const char);
        self.emit_tag_mod(om, od, failV);
        if !is_option {
            let conv = unsafe (*self.cur_ast()).resolution_def(id);
            let mut tg = DefId { module: 0, node: NODE_NONE };
            if conv.node != NODE_NONE { tg = self.cg_method_extend_target(conv); }
            self.emit(", .payload.%s._0 = ".ptr as *const char, (&failName.b[0]) as *const char);
            if tg.node != NODE_NONE {
                let mut pfx = Buf64 {};
                self.render_modpfx(conv.module, (&mut pfx.b[0]) as *mut char, 64);
                self.emit_cstr((&pfx.b[0]) as *const char);
                self.emit_ident_mod(tg.module, unsafe (*self.mod_ast(tg.module)).at_const(tg.node).as_data.aggregate.name);
                self.emit_cstr("__".ptr as *const char);
                self.emit_ident_mod(conv.module, unsafe (*self.mod_ast(conv.module)).at_const(conv.node).as_data.function.name);
                let mut sfx = Buf256 {};
                self.cg_conv_suffix(tg, "from".ptr as *const char, self.subst_resolve(it.args[1]), (&mut sfx.b[0]) as *mut char, 200);
                self.emit_cstr((&sfx.b[0]) as *const char);
                self.emit("(%s.payload.%s._0)".ptr as *const char, (&tmp.b[0]) as *const char, (&failName.b[0]) as *const char);
            } else {
                self.emit("%s.payload.%s._0".ptr as *const char, (&tmp.b[0]) as *const char, (&failName.b[0]) as *const char);
            }
        }
        self.emit_cstr(" };\n".ptr as *const char);
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit("} %s.payload.%s._0; })".ptr as *const char, (&tmp.b[0]) as *const char, (&okName.b[0]) as *const char);
    }
    fn emit_stmt(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE { return; }
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let nk = n.kind;
        if nk == NodeKind::NODE_STATIC_ASSERT { self.emit_static_assert(id); }
        else if nk == NodeKind::NODE_BLOCK { self.emit_block(id); self.emit_cstr("\n".ptr as *const char); }
        else if nk == NodeKind::NODE_LET {
            let nameN = n.as_data.let_stmt.name;
            let nameK = unsafe (*self.cur_ast()).at_const(nameN).kind;
            if nameK == NodeKind::NODE_IDENTIFIER && span_is(self.mod_src(self.cur_module()), unsafe (*self.cur_ast()).at_const(nameN).as_data.name.text, "_".ptr as *const char) {
                let dvt = unsafe (*self.cur_ast()).type_of(n.as_data.let_stmt.value);
                if dvt != TYPE_NONE && self.cg_type_is_free(dvt) { self.emit_expr_stmt(n.as_data.let_stmt.value); }
                else { self.emit_cstr("(void)(".ptr as *const char); self.emit_expr(n.as_data.let_stmt.value); self.emit_cstr(");\n".ptr as *const char); }
                return;
            }
            if nameK == NodeKind::NODE_PATTERN_TUPLE {
                self.emit_tuple_let(id);
                let children = unsafe (*self.cur_ast()).at_const(nameN).as_data.pattern.children;
                let mut i: u32 = 0;
                while i < children.len {
                    let eid = unsafe ((*self.cur_ast()).list(children))[i as usize];
                    if !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(eid)) || self.cg_is_moved(eid) || span_is(self.mod_src(self.cur_module()), self.name_span(eid), "_".ptr as *const char) { i = i + 1; continue; }
                    if self.cg_is_cond_moved(eid) {
                        let mut fl = Buf32 {};
                        cg_move_flag((&mut fl.b[0]) as *mut char, 32, eid);
                        self.emit_indent();
                        self.emit("bool %s = false;\n".ptr as *const char, (&fl.b[0]) as *const char);
                    }
                    self.cg_register_auto_free(eid);
                    i = i + 1;
                }
                return;
            }
            let autofree = self.cg_will_auto_free(id);
            let is_const = !n.as_data.let_stmt.is_mutable && !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(id));
            let lbt = unsafe (*self.cur_ast()).type_of(id);
            let lval = n.as_data.let_stmt.value;
            if lval != NODE_NONE && lbt != TYPE_NONE && self.type_at(lbt).kind == TypeKind::TYPE_ARRAY && unsafe (*self.cur_ast()).at_const(lval).kind != NodeKind::NODE_ARRAY_LITERAL {
                let mut arrtn = n.as_data.let_stmt.ty;
                if arrtn == NODE_NONE && unsafe (*self.cur_ast()).at_const(lval).kind == NodeKind::NODE_CALL {
                    let fd = unsafe (*self.cur_ast()).resolution_def(unsafe (*self.cur_ast()).at_const(lval).as_data.call.callee);
                    if fd.node != NODE_NONE && fd.module == self.cur_module() && unsafe (*self.mod_ast(fd.module)).at_const(fd.node).kind == NodeKind::NODE_FUNCTION { arrtn = self.fn_array_return(fd.node); }
                }
                if arrtn != NODE_NONE {
                    let mut nm = Buf128 {};
                    self.render_ident(self.name_span(nameN), (&mut nm.b[0]) as *mut char, 128);
                    let mut decl = Buf512 {};
                    self.render_binding_node(arrtn, (&nm.b[0]) as *const char, false, (&mut decl.b[0]) as *mut char, 300);
                    self.emit_cstr((&decl.b[0]) as *const char);
                    self.emit("; memcpy(%s, ".ptr as *const char, (&nm.b[0]) as *const char);
                    self.emit_expr(lval);
                    self.emit(", sizeof(%s));\n".ptr as *const char, (&nm.b[0]) as *const char);
                    return;
                }
            }
            if n.as_data.let_stmt.ty != NODE_NONE {
                let mut nm = Buf128 {};
                self.render_ident(self.name_span(nameN), (&mut nm.b[0]) as *mut char, 128);
                let mut decl = Buf512 {};
                self.render_binding_node(n.as_data.let_stmt.ty, (&nm.b[0]) as *const char, is_const, (&mut decl.b[0]) as *mut char, 300);
                self.emit_cstr((&decl.b[0]) as *const char);
            } else {
                self.emit_binding(unsafe (*self.cur_ast()).type_of(id), self.name_span(nameN), is_const);
            }
            if n.as_data.let_stmt.value != NODE_NONE {
                self.emit_cstr(" = ".ptr as *const char);
                self.emit_initializer(n.as_data.let_stmt.ty, n.as_data.let_stmt.value);
            }
            self.emit_cstr(";\n".ptr as *const char);
            if autofree && self.cg_is_cond_moved(id) {
                let mut fl = Buf32 {};
                cg_move_flag((&mut fl.b[0]) as *mut char, 32, id);
                self.emit_indent();
                self.emit("bool %s = false;\n".ptr as *const char, (&fl.b[0]) as *const char);
            }
            if autofree { self.cg_register_auto_free(id); }
        }
        else if nk == NodeKind::NODE_CONST {
            let mut nm = Buf128 {};
            self.render_ident(self.name_span(n.as_data.const_def.name), (&mut nm.b[0]) as *mut char, 128);
            let mut decl = Buf256 {};
            self.render_type_node(n.as_data.const_def.ty, (&nm.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 256);
            self.emit_cstr("static const ".ptr as *const char);
            self.emit_cstr((&decl.b[0]) as *const char);
            if n.as_data.const_def.value != NODE_NONE {
                self.emit_cstr(" = ".ptr as *const char);
                let sc = self.const_ctx;
                self.const_ctx = true;
                self.emit_initializer(n.as_data.const_def.ty, n.as_data.const_def.value);
                self.const_ctx = sc;
            }
            self.emit_cstr(";\n".ptr as *const char);
        }
        else if nk == NodeKind::NODE_RETURN { self.emit_return(id); }
        else if nk == NodeKind::NODE_IF { self.emit_if(id); self.emit_cstr("\n".ptr as *const char); }
        else if nk == NodeKind::NODE_WHILE {
            let saved_ldb = self.loop_defer_base;
            self.loop_defer_base = self.defer_top;
            let le = self.cg_loop_push(id, false);
            if n.as_data.while_stmt.is_do {
                self.emit_cstr("do ".ptr as *const char);
                self.pending_cnt = (le + 1) as u32;
                self.emit_block(n.as_data.while_stmt.body);
                self.emit_cstr(" while ".ptr as *const char);
                self.emit_condition(n.as_data.while_stmt.condition);
                self.emit_cstr(";\n".ptr as *const char);
            } else {
                if n.as_data.while_stmt.condition == NODE_NONE { self.emit_cstr("for (;;) ".ptr as *const char); }
                else { self.emit_cstr("while ".ptr as *const char); self.emit_condition(n.as_data.while_stmt.condition); self.emit_cstr(" ".ptr as *const char); }
                self.pending_cnt = (le + 1) as u32;
                self.emit_block(n.as_data.while_stmt.body);
                self.emit_cstr("\n".ptr as *const char);
            }
            self.cg_loop_brk_label(le);
            self.cg_loop_pop(le);
            self.loop_defer_base = saved_ldb;
        }
        else if nk == NodeKind::NODE_FOR {
            let saved_ldb = self.loop_defer_base;
            self.loop_defer_base = self.defer_top;
            let le = self.cg_loop_push(id, false);
            self.emit_for(id);
            self.cg_loop_brk_label(le);
            self.cg_loop_pop(le);
            self.loop_defer_base = saved_ldb;
        }
        else if nk == NodeKind::NODE_BREAK || nk == NodeKind::NODE_CONTINUE {
            let is_brk = nk == NodeKind::NODE_BREAK;
            let le = self.cg_loop_find(unsafe (*self.cur_ast()).resolution(id));
            let top = le < 0 || (le as u32) == self.nloops - 1;
            let mut dbase = self.loop_defer_base;
            if le >= 0 { dbase = self.loop_stack[le as usize].defer_base; }
            let mut value = NODE_NONE;
            if is_brk { value = n.as_data.flow.value; }
            let mut kw = "continue".ptr as *const char;
            if is_brk { kw = "break".ptr as *const char; }
            if top && value == NODE_NONE {
                if self.defer_top > dbase {
                    self.emit_cstr("{\n".ptr as *const char);
                    self.depth = self.depth + 1;
                    self.emit_defers_to(dbase);
                    self.emit_indent();
                    self.emit("%s;\n".ptr as *const char, kw);
                    self.depth = self.depth - 1;
                    self.emit_indent();
                    self.emit_cstr("}\n".ptr as *const char);
                } else { self.emit("%s;\n".ptr as *const char, kw); }
                return;
            }
            self.emit_cstr("{\n".ptr as *const char);
            self.depth = self.depth + 1;
            if value != NODE_NONE && le >= 0 && self.loop_stack[le as usize].is_expr {
                self.emit_indent();
                self.emit("__lv%u = ".ptr as *const char, self.loop_stack[le as usize].seq);
                self.emit_expr(value);
                self.emit_cstr(";\n".ptr as *const char);
            }
            self.emit_defers_to(dbase);
            self.emit_indent();
            if top { self.emit("%s;\n".ptr as *const char, kw); }
            else if is_brk { self.loop_stack[le as usize].used_brk = true; self.emit("goto __brk%u;\n".ptr as *const char, self.loop_stack[le as usize].seq); }
            else { self.loop_stack[le as usize].used_cnt = true; self.emit("goto __cnt%u;\n".ptr as *const char, self.loop_stack[le as usize].seq); }
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
        }
        else if nk == NodeKind::NODE_DEFER {
            if self.defer_top >= 256 { self.errors.emitf(n.span.start, n.span.end - n.span.start, "codegen: too many nested 'defer' statements".ptr as *const char); }
            else { let t = self.defer_top; self.defer_kind[t as usize] = 0; self.defer_stack[t as usize] = n.as_data.single.value; self.defer_top = t + 1; }
        }
        else if nk == NodeKind::NODE_EXPRESSION_STATEMENT { self.emit_expr_stmt(n.as_data.single.value); }
    }
    fn emit_block(self: &mut Self, id: NodeId) void { self.emit_block_from(id, self.defer_top); }
    fn emit_binding(self: &mut Self, t: TypeId, name: tok::Span, is_const: bool) void {
        let mut nm = Buf128 {};
        self.render_ident(name, (&mut nm.b[0]) as *mut char, 128);
        let k = self.type_at(t).kind;
        // An abstract (generic template) or error type has no spellable C type here -- let C infer it, exactly
        // as the const-view of a pointer element would otherwise mis-qualify (`const int *` vs `int *const`).
        if k == TypeKind::TYPE_GENERIC || k == TypeKind::TYPE_ERROR {
            if is_const { self.emit_cstr("const __auto_type ".ptr as *const char); } else { self.emit_cstr("__auto_type ".ptr as *const char); }
            self.emit_cstr((&nm.b[0]) as *const char);
            return;
        }
        if is_const && (k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE) {
            let mut cn = Buf256 {};
            buf_join3((&mut cn.b[0]) as *mut char, 200, "const ".ptr as *const char, "".ptr as *const char, (&nm.b[0]) as *const char);
            let mut decl = Buf512 {};
            self.render_type_id(t, (&cn.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 512);
            self.emit_cstr((&decl.b[0]) as *const char);
        } else {
            let mut decl = Buf512 {};
            self.render_type_id(t, (&nm.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 512);
            if is_const { self.emit_cstr("const ".ptr as *const char); }
            self.emit_cstr((&decl.b[0]) as *const char);
        }
    }
    fn render_binding_node(self: &mut Self, tn: NodeId, name: *const char, is_const: bool, out: *mut char, cap: usize) void {
        if is_const {
            let mut cn = Buf256 {};
            buf_join3((&mut cn.b[0]) as *mut char, 200, "const ".ptr as *const char, "".ptr as *const char, name);
            self.render_type_node(tn, (&cn.b[0]) as *const char, out, cap);
        } else {
            self.render_type_node(tn, name, out, cap);
        }
    }
    fn emit_static_assert(self: &mut Self, id: NodeId) void {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        self.emit_cstr("_Static_assert(".ptr as *const char);
        let sc = self.const_ctx;
        self.const_ctx = true;
        self.emit_expr(bd.left);
        self.const_ctx = sc;
        self.emit_cstr(", ".ptr as *const char);
        if bd.right != NODE_NONE { self.emit_reescaped(unsafe (*self.cur_ast()).at_const(bd.right).as_data.literal.raw, false); }
        else { self.emit_cstr("\"static assertion failed\"".ptr as *const char); }
        self.emit_cstr(");\n".ptr as *const char);
    }
    fn emit_tuple_let(self: &mut Self, id: NodeId) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let mut tmp = Buf32 {};
        self.fresh((&mut tmp.b[0]) as *mut char, 32);
        let pnm = unsafe (*self.cur_ast()).at_const(n.as_data.let_stmt.name).as_data.pattern.children;
        let mut freed_discard = false;
        let mut i: u32 = 0;
        while i < pnm.len {
            let pid = unsafe ((*self.cur_ast()).list(pnm))[i as usize];
            if span_is(self.mod_src(self.cur_module()), self.name_span(pid), "_".ptr as *const char) && self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(pid)) { freed_discard = true; }
            i = i + 1;
        }
        let mut cq = "const ".ptr as *const char;
        if freed_discard { cq = "".ptr as *const char; }
        self.emit("%s__auto_type %s = ".ptr as *const char, cq, (&tmp.b[0]) as *const char);
        self.emit_expr(n.as_data.let_stmt.value);
        self.emit_cstr(";\n".ptr as *const char);
        let names = unsafe (*self.cur_ast()).at_const(n.as_data.let_stmt.name).as_data.pattern.children;
        i = 0;
        while i < names.len {
            let nid = unsafe ((*self.cur_ast()).list(names))[i as usize];
            let mut bn = Buf128 {};
            self.render_ident(self.name_span(nid), (&mut bn.b[0]) as *mut char, 128);
            if bn.b[0] == '_' as char && bn.b[1] == 0 as char {
                if self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(nid)) {
                    self.emit_indent();
                    if self.emit_free_target(unsafe (*self.cur_ast()).type_of(nid)) { self.emit("(&%s._%u)".ptr as *const char, (&tmp.b[0]) as *const char, i); }
                    else { self.emit("(void)%s._%u".ptr as *const char, (&tmp.b[0]) as *const char, i); }
                    self.emit_cstr(";\n".ptr as *const char);
                }
                i = i + 1;
                continue;
            }
            self.emit_indent();
            let element_const = !n.as_data.let_stmt.is_mutable && !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(nid));
            let mut ecq = "".ptr as *const char;
            if element_const { ecq = "const ".ptr as *const char; }
            self.emit("%s__auto_type %s = %s._%u;\n".ptr as *const char, ecq, (&bn.b[0]) as *const char, (&tmp.b[0]) as *const char, i);
            i = i + 1;
        }
    }
    fn emit_return(self: &mut Self, id: NodeId) void {
        let vals = unsafe (*self.cur_ast()).at_const(id).as_data.return_stmt.values;
        let has_ret = self.current_ret[0] != 0 as char;
        let crp = (&self.current_ret[0]) as *const char;
        if self.defer_top > 0 {
            self.emit_cstr("{\n".ptr as *const char);
            self.depth = self.depth + 1;
            if vals.len == 0 {
                self.emit_defers_to(0);
                self.emit_indent();
                self.emit_cstr("return;\n".ptr as *const char);
            } else {
                let mut rv = Buf32 {};
                self.fresh((&mut rv.b[0]) as *mut char, 32);
                self.emit_indent();
                if has_ret {
                    self.emit("%s %s = (%s){ ".ptr as *const char, crp, (&rv.b[0]) as *const char, crp);
                    let v0 = unsafe ((*self.cur_ast()).list(vals))[0];
                    if vals.len == 1 && unsafe (*self.cur_ast()).at_const(v0).kind == NodeKind::NODE_ARRAY_LITERAL { self.emit_array_braces(v0); }
                    else { let mut i: u32 = 0; while i < vals.len { if i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit_expr(unsafe ((*self.cur_ast()).list(vals))[i as usize]); i = i + 1; } }
                    self.emit_cstr(" };\n".ptr as *const char);
                } else {
                    let v0 = unsafe ((*self.cur_ast()).list(vals))[0];
                    let rvt0 = unsafe (*self.cur_ast()).type_of(v0);
                    if rvt0 != TYPE_NONE && self.type_at(rvt0).kind == TypeKind::TYPE_NEVER {
                        self.emit_expr(v0);
                        self.emit_cstr(";\n".ptr as *const char);
                        self.depth = self.depth - 1;
                        self.emit_indent();
                        self.emit_cstr("}\n".ptr as *const char);
                        return;
                    }
                    self.emit("__auto_type %s = ".ptr as *const char, (&rv.b[0]) as *const char);
                    self.emit_expr(v0);
                    self.emit_cstr(";\n".ptr as *const char);
                }
                self.emit_defers_to(0);
                self.emit_indent();
                self.emit("return %s;\n".ptr as *const char, (&rv.b[0]) as *const char);
            }
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            return;
        }
        if vals.len == 0 { self.emit_cstr("return;\n".ptr as *const char); return; }
        if vals.len == 1 {
            let v0 = unsafe ((*self.cur_ast()).list(vals))[0];
            if unsafe (*self.cur_ast()).at_const(v0).kind == NodeKind::NODE_MATCH {
                self.emit_cstr("{\n".ptr as *const char);
                self.depth = self.depth + 1;
                self.emit_match_core(v0, 2, null);
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_cstr("}\n".ptr as *const char);
                return;
            }
            if has_ret {
                self.emit("return (%s){ ".ptr as *const char, crp);
                if unsafe (*self.cur_ast()).at_const(v0).kind == NodeKind::NODE_ARRAY_LITERAL { self.emit_array_braces(v0); }
                else { self.emit_expr(v0); }
                self.emit_cstr(" };\n".ptr as *const char);
                return;
            }
            let rvt = unsafe (*self.cur_ast()).type_of(v0);
            if rvt != TYPE_NONE && self.type_at(rvt).kind == TypeKind::TYPE_NEVER { self.emit_expr(v0); self.emit_cstr(";\n".ptr as *const char); return; }
            self.emit_cstr("return ".ptr as *const char);
            self.emit_expr(v0);
            self.emit_cstr(";\n".ptr as *const char);
            return;
        }
        self.emit("return (%s){ ".ptr as *const char, crp);
        let mut i: u32 = 0;
        while i < vals.len { if i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit_expr(unsafe ((*self.cur_ast()).list(vals))[i as usize]); i = i + 1; }
        self.emit_cstr(" };\n".ptr as *const char);
    }
    fn cg_loop_body_tail(self: &mut Self, dbase: u32, le: i32) void {
        self.emit_defers_to(dbase);
        self.defer_top = dbase;
        if le >= 0 && self.loop_stack[le as usize].used_cnt {
            self.emit_indent();
            self.emit("__cnt%u:;\n".ptr as *const char, self.loop_stack[le as usize].seq);
        }
    }
    fn emit_for_range(self: &mut Self, id: NodeId) void {
        let fs = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt;
        let r = unsafe (*self.cur_ast()).at_const(fs.iterable).as_data.pattern_range;
        let lo = r.start;
        let hi = r.end;
        let name = self.name_span(fs.binding);
        let mut nm = Buf128 {};
        self.render_ident(name, (&mut nm.b[0]) as *mut char, 128);
        self.emit_cstr("for (".ptr as *const char);
        self.emit_binding(unsafe (*self.cur_ast()).type_of(fs.iterable), name, false);
        self.emit_cstr(" = ".ptr as *const char);
        if lo != NODE_NONE { self.emit_expr(lo); } else { self.emit_cstr("0".ptr as *const char); }
        self.emit_cstr("; ".ptr as *const char);
        if hi != NODE_NONE {
            let mut cmp = "<".ptr as *const char;
            if r.inclusive { cmp = "<=".ptr as *const char; }
            self.emit("%s %s ".ptr as *const char, (&nm.b[0]) as *const char, cmp);
            self.emit_expr(hi);
        }
        self.emit("; %s++) ".ptr as *const char, (&nm.b[0]) as *const char);
        self.pending_cnt = (self.cg_loop_find(id) + 1) as u32;
        self.emit_block(fs.body);
        self.emit_cstr("\n".ptr as *const char);
    }
    fn emit_for(self: &mut Self, id: NodeId) void {
        let le = self.cg_loop_find(id);
        let fs = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt;
        if unsafe (*self.cur_ast()).at_const(fs.iterable).kind == NodeKind::NODE_RANGE { self.emit_for_range(id); return; }
        let ity = *self.type_at(unsafe (*self.cur_ast()).type_of(fs.iterable));
        let body = fs.body;
        let stmts = unsafe (*self.cur_ast()).at_const(body).as_data.block.statements;
        let mut idx = Buf32 {};
        self.fresh((&mut idx.b[0]) as *mut char, 32);
        if ity.kind == TypeKind::TYPE_ARRAY {
            let len = self.array_length_of(fs.iterable);
            self.emit("for (size_t %s = 0; %s < ".ptr as *const char, (&idx.b[0]) as *const char, (&idx.b[0]) as *const char);
            if len != NODE_NONE { self.emit_expr(len); }
            else {
                self.emit_cstr("sizeof(".ptr as *const char); self.emit_expr(fs.iterable); self.emit_cstr(")/sizeof((".ptr as *const char); self.emit_expr(fs.iterable); self.emit_cstr(")[0])".ptr as *const char);
            }
            self.emit("; %s++) {\n".ptr as *const char, (&idx.b[0]) as *const char);
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_binding(ity.as_data.arr.elem, self.name_span(fs.binding), true);
            self.emit_cstr(" = (".ptr as *const char);
            self.emit_expr(fs.iterable);
            self.emit(")[%s];\n".ptr as *const char, (&idx.b[0]) as *const char);
            let dbase = self.defer_top;
            let mut i: u32 = 0;
            while i < stmts.len { self.emit_indent(); self.emit_stmt(unsafe ((*self.cur_ast()).list(stmts))[i as usize]); i = i + 1; }
            self.cg_loop_body_tail(dbase, le);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            return;
        }
        let mut selem: TypeId = TYPE_NONE;
        if self.cg_slice_elem(unsafe (*self.cur_ast()).type_of(fs.iterable), (&mut selem) as *mut TypeId) {
            let mut s = Buf32 {};
            self.fresh((&mut s.b[0]) as *mut char, 32);
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(fs.iterable), (&s.b[0]) as *const char, (&mut styp.b[0]) as *mut char, 200);
            self.emit_cstr("{\n".ptr as *const char);
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_cstr((&styp.b[0]) as *const char);
            self.emit_cstr(" = ".ptr as *const char);
            self.emit_expr(fs.iterable);
            self.emit_cstr(";\n".ptr as *const char);
            self.emit_indent();
            self.emit("for (size_t %s = 0; %s < %s.len; %s++) {\n".ptr as *const char, (&idx.b[0]) as *const char, (&idx.b[0]) as *const char, (&s.b[0]) as *const char, (&idx.b[0]) as *const char);
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_binding(selem, self.name_span(fs.binding), true);
            self.emit(" = %s.ptr[%s];\n".ptr as *const char, (&s.b[0]) as *const char, (&idx.b[0]) as *const char);
            let dbase = self.defer_top;
            let mut i: u32 = 0;
            while i < stmts.len { self.emit_indent(); self.emit_stmt(unsafe ((*self.cur_ast()).list(stmts))[i as usize]); i = i + 1; }
            self.cg_loop_body_tail(dbase, le);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            return;
        }
        let mut relem: TypeId = TYPE_NONE;
        if self.cg_range_elem(unsafe (*self.cur_ast()).type_of(fs.iterable), (&mut relem) as *mut TypeId) {
            let mut rr = Buf32 {};
            self.fresh((&mut rr.b[0]) as *mut char, 32);
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(fs.iterable), (&rr.b[0]) as *const char, (&mut styp.b[0]) as *mut char, 200);
            let mut nm = Buf128 {};
            self.render_ident(self.name_span(fs.binding), (&mut nm.b[0]) as *mut char, 128);
            self.emit_cstr("{\n".ptr as *const char);
            self.depth = self.depth + 1;
            self.emit_indent();
            self.emit_cstr((&styp.b[0]) as *const char);
            self.emit_cstr(" = ".ptr as *const char);
            self.emit_expr(fs.iterable);
            self.emit_cstr(";\n".ptr as *const char);
            self.emit_indent();
            self.emit_cstr("for (".ptr as *const char);
            self.emit_binding(relem, self.name_span(fs.binding), false);
            self.emit(" = %s.start; %s.inclusive ? %s <= %s.end : %s < %s.end; %s++) {\n".ptr as *const char, (&rr.b[0]) as *const char, (&rr.b[0]) as *const char, (&nm.b[0]) as *const char, (&rr.b[0]) as *const char, (&nm.b[0]) as *const char, (&rr.b[0]) as *const char, (&nm.b[0]) as *const char);
            self.depth = self.depth + 1;
            let dbase = self.defer_top;
            let mut i: u32 = 0;
            while i < stmts.len { self.emit_indent(); self.emit_stmt(unsafe ((*self.cur_ast()).list(stmts))[i as usize]); i = i + 1; }
            self.cg_loop_body_tail(dbase, le);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            return;
        }
        // Iterator protocol
        let bt = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(fs.iterable)));
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if bt.kind == TypeKind::TYPE_STRUCT { om = bt.module; od = bt.as_data.decl; }
        else if bt.kind == TypeKind::TYPE_INSTANCE { let ii = *unsafe (*self.cur_ast()).instance(bt.as_data.inst); om = ii.module; od = ii.decl; }
        let mut nx = DefId { module: 0, node: NODE_NONE };
        if od != NODE_NONE { nx = self.cg_find_method_cstr(om, od, "next".ptr as *const char); }
        if nx.node != NODE_NONE {
            let na = self.mod_ast(nx.module);
            let rets = unsafe (*na).at_const(nx.node).as_data.function.returns;
            let r0 = unsafe ((*na).list(rets))[0];
            let rn = unsafe (*na).at_const(r0);
            let opt = unsafe (*na).resolution_def(if_node(rn.kind == NodeKind::NODE_PARAMETER, rn.as_data.parameter.ty, r0));
            let elem = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            if opt.node != NODE_NONE && elem != TYPE_NONE {
                let oa = self.mod_ast(opt.module);
                let mem = unsafe (*oa).at_const(opt.node).as_data.aggregate.members;
                let mut some = NODE_NONE;
                let mut none2 = NODE_NONE;
                let mut i: u32 = 0;
                while i < mem.len {
                    let vid = unsafe ((*oa).list(mem))[i as usize];
                    let v = unsafe (*oa).at_const(vid);
                    if v.kind == NodeKind::NODE_VARIANT {
                        let vs = unsafe (*oa).at_const(v.as_data.variant.name).as_data.name.text;
                        if span_is(self.mod_src(opt.module), vs, "Some".ptr as *const char) { some = vid; }
                        else if span_is(self.mod_src(opt.module), vs, "None".ptr as *const char) { none2 = vid; }
                    }
                    i = i + 1;
                }
                if some != NODE_NONE && none2 != NODE_NONE {
                    let optTy = unsafe (*self.cur_ast()).intern_instance(opt.module, opt.node, (&elem) as *const TypeId, 1);
                    let mut itn = Buf32 {};
                    let mut ov = Buf32 {};
                    self.fresh((&mut itn.b[0]) as *mut char, 32);
                    self.fresh((&mut ov.b[0]) as *mut char, 32);
                    let mut vn = Buf128 {};
                    self.render_variant_name(opt.module, some, (&mut vn.b[0]) as *mut char, 128);
                    self.emit_cstr("{\n".ptr as *const char);
                    self.depth = self.depth + 1;
                    self.emit_indent();
                    self.emit("__auto_type %s = ".ptr as *const char, (&itn.b[0]) as *const char);
                    self.emit_expr(fs.iterable);
                    self.emit_cstr(";\n".ptr as *const char);
                    self.emit_indent();
                    self.emit_cstr("for (;;) {\n".ptr as *const char);
                    self.depth = self.depth + 1;
                    self.emit_indent();
                    let mut odecl = Buf256 {};
                    self.render_type_id(optTy, (&ov.b[0]) as *const char, (&mut odecl.b[0]) as *mut char, 256);
                    self.emit_cstr((&odecl.b[0]) as *const char);
                    self.emit_cstr(" = ".ptr as *const char);
                    if bt.kind == TypeKind::TYPE_INSTANCE {
                        let mut inm = Buf256 {};
                        self.inst_name(unsafe (*self.cur_ast()).instance(bt.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
                        self.emit_cstr((&inm.b[0]) as *const char);
                        self.emit_paste();
                        self.emit_cstr("__".ptr as *const char);
                    } else {
                        let mut pfx = Buf64 {};
                        self.render_modpfx(nx.module, (&mut pfx.b[0]) as *mut char, 64);
                        self.emit_cstr((&pfx.b[0]) as *const char);
                        self.emit_ident_mod(om, unsafe (*self.mod_ast(om)).at_const(od).as_data.aggregate.name);
                        self.emit_cstr("__".ptr as *const char);
                    }
                    self.emit_ident_mod(nx.module, unsafe (*self.mod_ast(nx.module)).at_const(nx.node).as_data.function.name);
                    self.emit("(&%s);\n".ptr as *const char, (&itn.b[0]) as *const char);
                    self.emit_indent();
                    self.emit("if (%s.tag == ".ptr as *const char, (&ov.b[0]) as *const char);
                    self.emit_tag_mod(opt.module, opt.node, none2);
                    self.emit_cstr(") break;\n".ptr as *const char);
                    self.emit_indent();
                    self.emit_binding(elem, self.name_span(fs.binding), true);
                    self.emit(" = %s.payload.%s._0;\n".ptr as *const char, (&ov.b[0]) as *const char, (&vn.b[0]) as *const char);
                    let dbase = self.defer_top;
                    i = 0;
                    while i < stmts.len { self.emit_indent(); self.emit_stmt(unsafe ((*self.cur_ast()).list(stmts))[i as usize]); i = i + 1; }
                    self.cg_loop_body_tail(dbase, le);
                    self.depth = self.depth - 1;
                    self.emit_indent();
                    self.emit_cstr("}\n".ptr as *const char);
                    self.depth = self.depth - 1;
                    self.emit_indent();
                    self.emit_cstr("}\n".ptr as *const char);
                    return;
                }
            }
        }
        let sp = unsafe (*self.cur_ast()).at_const(id).span;
        self.errors.emitf(sp.start, sp.end - sp.start, "codegen: cannot iterate over a non-array/slice value".ptr as *const char);
    }
    fn emit_initializer(self: &mut Self, tn: NodeId, val: NodeId) void {
        if unsafe (*self.cur_ast()).at_const(val).kind == NodeKind::NODE_ARRAY_LITERAL && tn != NODE_NONE && unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_ARRAY_TYPE { self.emit_array_braces(val); }
        else { self.emit_expr(val); }
    }
    fn render_binding_id(self: &mut Self, t: TypeId, name: *const char, is_const: bool, out: *mut char, cap: usize) void {
        let k = self.type_at(t).kind;
        if is_const && (k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE) {
            let mut cn = Buf256 {};
            buf_join3((&mut cn.b[0]) as *mut char, 200, "const ".ptr as *const char, "".ptr as *const char, name);
            self.render_type_id(t, (&cn.b[0]) as *const char, out, cap);
        } else if is_const {
            let mut body = Buf512 {};
            self.render_type_id(t, name, (&mut body.b[0]) as *mut char, 512);
            buf_join3(out, cap, "const ".ptr as *const char, "".ptr as *const char, (&body.b[0]) as *const char);
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
                if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT { return 0; }
            }
            let t = unsafe (*self.cur_ast()).type_of(pid);
            if !self.cg_type_is_free(t) || self.cg_is_moved(pid) || self.cg_is_cond_moved(pid) { return 0; }
            if do_emit {
                self.emit_indent();
                self.emit_free_target(t);
                let mut b = Buf128 {};
                self.render_ident(nm, (&mut b.b[0]) as *mut char, 128);
                self.emit("(&%s);\n".ptr as *const char, (&b.b[0]) as *const char);
            }
            return 1;
        }
        if pk == NodeKind::NODE_PATTERN_TUPLE {
            let ch = p.as_data.pattern.children;
            let mut nn: i32 = 0;
            let mut i: u32 = 0;
            while i < ch.len { nn = nn + self.cg_arm_frees(unsafe ((*self.cur_ast()).list(ch))[i as usize], do_emit); i = i + 1; }
            return nn;
        }
        if pk == NodeKind::NODE_PATTERN_STRUCT {
            let ch = p.as_data.pattern.children;
            let mut nn: i32 = 0;
            let mut i: u32 = 0;
            while i < ch.len {
                let sub = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(ch))[i as usize]).as_data.pattern.children;
                if sub.len != 0 { nn = nn + self.cg_arm_frees(unsafe ((*self.cur_ast()).list(sub))[0], do_emit); }
                i = i + 1;
            }
            return nn;
        }
        if pk == NodeKind::NODE_PATTERN_OR {
            let alts = p.as_data.pattern.children;
            if alts.len != 0 { return self.cg_arm_frees(unsafe ((*self.cur_ast()).list(alts))[0], do_emit); }
            return 0;
        }
        return 0;
    }
    fn emit_arm_body(self: &mut Self, body: NodeId, mode: i32, result: *const char, pattern: NodeId, by_ref: bool) void {
        let bt0 = unsafe (*self.cur_ast()).type_of(body);
        if bt0 != TYPE_NONE && self.type_at(bt0).kind == TypeKind::TYPE_NEVER {
            self.emit_indent();
            self.emit_expr(body);
            self.emit_cstr(";\n".ptr as *const char);
            return;
        }
        let mut frees: i32 = 0;
        if !by_ref { frees = self.cg_arm_frees(pattern, false); }
        if mode == 2 {
            self.emit_indent();
            if frees == 0 { self.emit_cstr("return ".ptr as *const char); self.emit_expr(body); self.emit_cstr(";\n".ptr as *const char); return; }
            let rt = unsafe (*self.cur_ast()).type_of(body);
            let mut voidret = rt == TYPE_NONE;
            if rt != TYPE_NONE { voidret = self.type_at(rt).kind == TypeKind::TYPE_BUILTIN && self.type_at(rt).as_data.builtin == BuiltinType::BT_VOID; }
            let mut r = Buf32 {};
            if voidret { self.emit_cstr("{ ".ptr as *const char); self.emit_expr(body); self.emit_cstr(";\n".ptr as *const char); }
            else { self.fresh((&mut r.b[0]) as *mut char, 32); self.emit("{ __auto_type %s = ".ptr as *const char, (&r.b[0]) as *const char); self.emit_expr(body); self.emit_cstr(";\n".ptr as *const char); }
            self.cg_arm_frees(pattern, true);
            self.emit_indent();
            if voidret { self.emit_cstr("return; }\n".ptr as *const char); } else { self.emit("return %s; }\n".ptr as *const char, (&r.b[0]) as *const char); }
            return;
        }
        if mode == 1 {
            self.emit_indent();
            self.emit("%s = ".ptr as *const char, result);
            self.emit_expr(body);
            self.emit_cstr(";\n".ptr as *const char);
        } else if unsafe (*self.cur_ast()).at_const(body).kind == NodeKind::NODE_BLOCK {
            self.emit_indent(); self.emit_block(body); self.emit_cstr("\n".ptr as *const char);
        } else if unsafe (*self.cur_ast()).at_const(body).kind == NodeKind::NODE_MATCH {
            self.emit_indent(); self.emit_match_stmt(body);
        } else if unsafe (*self.cur_ast()).at_const(body).kind == NodeKind::NODE_IF {
            self.emit_indent(); self.emit_if(body); self.emit_cstr("\n".ptr as *const char);
        } else {
            self.emit_indent(); self.emit_expr(body); self.emit_cstr(";\n".ptr as *const char);
        }
        if frees != 0 { self.cg_arm_frees(pattern, true); }
    }
    fn emit_match_core(self: &mut Self, id: NodeId, mode: i32, result: *const char) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let mut scrut = Buf32 {};
        self.fresh((&mut scrut.b[0]) as *mut char, 32);
        let outer = unsafe (*self.cur_ast()).type_of(n.as_data.match_expr.value);
        let mut derefs: u32 = 0;
        let mut base = outer;
        let mut y = self.type_at(base);
        while y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE { base = y.as_data.elem; derefs = derefs + 1; y = self.type_at(base); }
        let by_ref = derefs > 0;
        let mut mut_ref = false;
        if by_ref { mut_ref = self.type_at(outer).qualifier == (TypeQualifier::TYPE_QUAL_MUT as u8); }
        let bk = self.type_at(base).kind;
        let mut access = Buf64 {};
        self.emit_indent();
        if by_ref {
            let mut aggr = Buf256 {};
            self.render_type_id(base, "".ptr as *const char, (&mut aggr.b[0]) as *mut char, 256);
            let mut cq = "const ".ptr as *const char;
            if mut_ref { cq = "".ptr as *const char; }
            self.emit("%s%s *const %s = ".ptr as *const char, cq, (&aggr.b[0]) as *const char, (&scrut.b[0]) as *const char);
            let mut i: u32 = 0;
            while i + 1 < derefs { self.emit_cstr("(*".ptr as *const char); i = i + 1; }
            self.emit_expr(n.as_data.match_expr.value);
            i = 0;
            while i + 1 < derefs { self.emit_cstr(")".ptr as *const char); i = i + 1; }
            unsafe stdio::snprintf((&mut access.b[0]) as *mut char, 40, "(*%s)".ptr as *const char, (&scrut.b[0]) as *const char);
        } else if bk == TypeKind::TYPE_ERROR || bk == TypeKind::TYPE_FUNCTION || bk == TypeKind::TYPE_GENERIC {
            self.emit("const __auto_type %s = ".ptr as *const char, (&scrut.b[0]) as *const char);
            self.emit_expr(n.as_data.match_expr.value);
            unsafe stdio::snprintf((&mut access.b[0]) as *mut char, 40, "%s".ptr as *const char, (&scrut.b[0]) as *const char);
        } else {
            let mut d = Buf512 {};
            self.render_binding_id(base, (&scrut.b[0]) as *const char, true, (&mut d.b[0]) as *mut char, 300);
            self.emit_cstr((&d.b[0]) as *const char);
            self.emit_cstr(" = ".ptr as *const char);
            self.emit_expr(n.as_data.match_expr.value);
            unsafe stdio::snprintf((&mut access.b[0]) as *mut char, 40, "%s".ptr as *const char, (&scrut.b[0]) as *const char);
        }
        self.emit_cstr(";\n".ptr as *const char);
        let accp = (&access.b[0]) as *const char;
        let arms = n.as_data.match_expr.arms;
        let mut has_guard = false;
        let mut i: u32 = 0;
        while i < arms.len { if unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(arms))[i as usize]).as_data.match_arm.guard != NODE_NONE { has_guard = true; } i = i + 1; }
        if !has_guard {
            i = 0;
            while i < arms.len {
                let arm = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(arms))[i as usize]).as_data.match_arm;
                self.emit_indent();
                if i != 0 { self.emit_cstr("else if (".ptr as *const char); } else { self.emit_cstr("if (".ptr as *const char); }
                self.emit_pattern_test(arm.pattern, accp);
                self.emit_cstr(") {\n".ptr as *const char);
                self.depth = self.depth + 1;
                self.emit_pattern_binds(arm.pattern, accp, by_ref);
                self.emit_arm_body(arm.body, mode, result, arm.pattern, by_ref);
                self.depth = self.depth - 1;
                self.emit_indent();
                self.emit_cstr("}\n".ptr as *const char);
                i = i + 1;
            }
            if mode != 0 && arms.len > 0 { self.emit_indent(); self.emit_cstr("else { __builtin_unreachable(); }\n".ptr as *const char); }
            return;
        }
        self.emit_indent();
        self.emit_cstr("do {\n".ptr as *const char);
        self.depth = self.depth + 1;
        i = 0;
        while i < arms.len {
            let arm = unsafe (*self.cur_ast()).at_const(unsafe ((*self.cur_ast()).list(arms))[i as usize]).as_data.match_arm;
            let guard = arm.guard;
            self.emit_indent();
            self.emit_cstr("if (".ptr as *const char);
            self.emit_pattern_test(arm.pattern, accp);
            self.emit_cstr(") {\n".ptr as *const char);
            self.depth = self.depth + 1;
            self.emit_pattern_binds(arm.pattern, accp, by_ref);
            if guard != NODE_NONE {
                self.emit_indent();
                self.emit_cstr("if (".ptr as *const char);
                self.emit_condition(guard);
                self.emit_cstr(") {\n".ptr as *const char);
                self.depth = self.depth + 1;
            }
            self.emit_arm_body(arm.body, mode, result, arm.pattern, by_ref);
            if mode != 2 { self.emit_indent(); self.emit_cstr("break;\n".ptr as *const char); }
            if guard != NODE_NONE { self.depth = self.depth - 1; self.emit_indent(); self.emit_cstr("}\n".ptr as *const char); }
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("}\n".ptr as *const char);
            i = i + 1;
        }
        if mode != 0 { self.emit_indent(); self.emit_cstr("__builtin_unreachable();\n".ptr as *const char); }
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("} while (0);\n".ptr as *const char);
    }
    fn cg_enum_variant(self: &Self, m: ModuleId, enumDecl: NodeId, lit: *const char) NodeId {
        let a = self.mod_ast(m);
        let e = unsafe (*a).at_const(enumDecl);
        if e.kind != NodeKind::NODE_ENUM { return NODE_NONE; }
        let ms = e.as_data.aggregate.members;
        let mut i: u32 = 0;
        while i < ms.len {
            let vid = unsafe ((*a).list(ms))[i as usize];
            let v = unsafe (*a).at_const(vid);
            if v.kind == NodeKind::NODE_VARIANT && span_is(self.mod_src(m), unsafe (*a).at_const(v.as_data.variant.name).as_data.name.text, lit) { return vid; }
            i = i + 1;
        }
        return NODE_NONE;
    }
    fn cg_method_extend_target(self: &Self, md: DefId) DefId {
        let a = self.mod_ast(md.module);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut i: u32 = 0;
        while i < items.len {
            let iid = unsafe ((*a).list(items))[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND {
                let ms = it.as_data.extend_def.items;
                let mut j: u32 = 0;
                while j < ms.len { if unsafe ((*a).list(ms))[j as usize] == md.node { return unsafe (*a).resolution_def(it.as_data.extend_def.target_type); } j = j + 1; }
            }
            i = i + 1;
        }
        return DefId { module: 0, node: NODE_NONE };
    }
    fn cg_will_auto_free(self: &mut Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_LET && unsafe (*self.cur_ast()).at_const(n.as_data.let_stmt.name).kind == NodeKind::NODE_PATTERN_TUPLE { return false; }
        if self.cg_is_moved(id) { return false; }
        return self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(id));
    }
    fn cg_register_auto_free(self: &mut Self, id: NodeId) void {
        if self.defer_top >= 256 { return; }
        let t = self.defer_top;
        self.defer_stack[t as usize] = id;
        self.defer_kind[t as usize] = 1;
        self.defer_top = t + 1;
    }
    fn emit_capture_init(self: &mut Self, clos: NodeId, idx: u32) void {
        let caps = unsafe (*self.cur_ast()).at_const(clos).as_data.closure.captures;
        let mut_caps = unsafe (*self.cur_ast()).at_const(clos).as_data.closure.mut_caps;
        let decl = unsafe ((*self.cur_ast()).list(caps))[idx as usize];
        let want_ptr = ((mut_caps >> (idx as u64)) & (1 as u64)) != 0 as u64;
        let mut nm = Buf128 {};
        let csp = self.cg_decl_name_span(decl);
        self.render_ident(csp, (&mut nm.b[0]) as *mut char, 128);
        self.emit(".%s = ".ptr as *const char, (&nm.b[0]) as *const char);
        let mut outer_mut = false;
        let oi = self.cg_env_capture(decl, (&mut outer_mut) as *mut bool);
        if want_ptr {
            if oi >= 0 && outer_mut { self.emit_cstr("".ptr as *const char); } else { self.emit_cstr("&".ptr as *const char); }
        } else if oi >= 0 && outer_mut {
            self.emit_cstr("*".ptr as *const char);
        }
        if oi >= 0 { self.emit_cstr("__env->".ptr as *const char); }
        self.emit_cstr((&nm.b[0]) as *const char);
    }
    fn cg_mark_move(self: &mut Self, expr0: NodeId, cond: bool, pass: i32, site: bool) void {
        if expr0 == NODE_NONE { return; }
        let mut expr = expr0;
        let mut go = true;
        while go {
            let me = unsafe (*self.cur_ast()).at_const(expr);
            if me.kind == NodeKind::NODE_UNARY && (me.as_data.unary.op == TokenType::Move || me.as_data.unary.op == TokenType::Unsafe) {
                expr = me.as_data.unary.operand;
            } else { go = false; }
        }
        let mek = unsafe (*self.cur_ast()).at_const(expr).kind;
        if mek == NodeKind::NODE_MEMBER {
            let is_path = unsafe (*self.cur_ast()).at_const(expr).as_data.member.path;
            let obj = unsafe (*self.cur_ast()).at_const(expr).as_data.member.object;
            if !is_path && self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(expr)) {
                self.cg_mark_move(obj, cond, pass, false);
                return;
            }
        }
        if mek != NodeKind::NODE_IDENTIFIER { return; }
        let d = unsafe (*self.cur_ast()).resolution_def(expr);
        if d.module != self.cur_module() || d.node == NODE_NONE { return; }
        let dk = unsafe (*self.cur_ast()).at_const(d.node).kind;
        let mut tuple_elem = false;
        if dk == NodeKind::NODE_IDENTIFIER {
            let letid = unsafe (*self.cur_ast()).resolution(d.node);
            if letid != NODE_NONE && unsafe (*self.cur_ast()).at_const(letid).kind == NodeKind::NODE_LET {
                let lname = unsafe (*self.cur_ast()).at_const(letid).as_data.let_stmt.name;
                if unsafe (*self.cur_ast()).at_const(lname).kind == NodeKind::NODE_PATTERN_TUPLE { tuple_elem = true; }
            }
        }
        if dk != NodeKind::NODE_LET && dk != NodeKind::NODE_PARAMETER && dk != NodeKind::NODE_PATTERN_NAME && !tuple_elem { return; }
        if !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(expr)) { return; }
        if pass == 0 {
            if (!cond || dk == NodeKind::NODE_PATTERN_NAME) && self.nmoved < 512 { self.moved[self.nmoved as usize] = d.node; self.nmoved = self.nmoved + 1; }
            return;
        }
        if dk == NodeKind::NODE_PATTERN_NAME { return; }
        if !cond || self.cg_is_moved(d.node) { return; }
        if !self.cg_is_cond_moved(d.node) && self.ncond_moved < 256 { self.cond_moved[self.ncond_moved as usize] = d.node; self.ncond_moved = self.ncond_moved + 1; }
        if site && self.ncond_sites < 256 { self.cond_sites[self.ncond_sites as usize] = expr; self.ncond_sites = self.ncond_sites + 1; }
    }
    fn cg_mark_move_tail(self: &mut Self, e: NodeId, cond: bool, pass: i32) void {
        if e == NODE_NONE { return; }
        let nk = unsafe (*self.cur_ast()).at_const(e).kind;
        if nk == NodeKind::NODE_MATCH {
            let arms = unsafe (*self.cur_ast()).at_const(e).as_data.match_expr.arms;
            let ids = unsafe (*self.cur_ast()).list(arms);
            let mut i: u32 = 0;
            while i < arms.len {
                let body = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.match_arm.body;
                self.cg_mark_move_tail(body, true, pass);
                i = i + 1;
            }
        } else if nk == NodeKind::NODE_IF {
            let tb = unsafe (*self.cur_ast()).at_const(e).as_data.if_stmt.then_branch;
            let eb = unsafe (*self.cur_ast()).at_const(e).as_data.if_stmt.else_branch;
            self.cg_mark_move_tail(tb, true, pass);
            self.cg_mark_move_tail(eb, true, pass);
        } else if nk == NodeKind::NODE_BLOCK {
            let ss = unsafe (*self.cur_ast()).at_const(e).as_data.block.statements;
            if ss.len != 0 {
                let lastid = unsafe ((*self.cur_ast()).list(ss))[(ss.len - 1) as usize];
                let lastk = unsafe (*self.cur_ast()).at_const(lastid).kind;
                if lastk == NodeKind::NODE_EXPRESSION_STATEMENT {
                    let lv = unsafe (*self.cur_ast()).at_const(lastid).as_data.single.value;
                    if unsafe (*self.cur_ast()).at_const(lv).kind != NodeKind::NODE_ASSIGNMENT {
                        self.cg_mark_move_tail(lv, cond, pass);
                    }
                }
            }
        } else {
            self.cg_mark_move(e, cond, pass, true);
        }
    }
    fn cg_scan_moves(self: &mut Self, id: NodeId, cond: bool, pass: i32) void {
        if id == NODE_NONE { return; }
        let nk = unsafe (*self.cur_ast()).at_const(id).kind;
        if nk == NodeKind::NODE_BLOCK {
            let ss = unsafe (*self.cur_ast()).at_const(id).as_data.block.statements;
            let ids = unsafe (*self.cur_ast()).list(ss);
            let mut i: u32 = 0;
            while i < ss.len { self.cg_scan_moves(unsafe ids[i as usize], cond, pass); i = i + 1; }
        } else if nk == NodeKind::NODE_LET {
            let v = unsafe (*self.cur_ast()).at_const(id).as_data.let_stmt.value;
            self.cg_mark_move_tail(v, cond, pass);
            self.cg_scan_moves(v, cond, pass);
        } else if nk == NodeKind::NODE_RETURN {
            let vs = unsafe (*self.cur_ast()).at_const(id).as_data.return_stmt.values;
            let ids = unsafe (*self.cur_ast()).list(vs);
            let mut i: u32 = 0;
            while i < vs.len {
                let vid = unsafe ids[i as usize];
                self.cg_mark_move_tail(vid, cond, pass);
                self.cg_scan_moves(vid, cond, pass);
                i = i + 1;
            }
        } else if nk == NodeKind::NODE_ASSIGNMENT {
            let l = unsafe (*self.cur_ast()).at_const(id).as_data.binary.left;
            let r = unsafe (*self.cur_ast()).at_const(id).as_data.binary.right;
            self.cg_mark_move_tail(r, cond, pass);
            self.cg_scan_moves(l, cond, pass);
            self.cg_scan_moves(r, cond, pass);
        } else if nk == NodeKind::NODE_STRUCT_INITIALIZER {
            let fs = unsafe (*self.cur_ast()).at_const(id).as_data.struct_initializer.fields;
            let ids = unsafe (*self.cur_ast()).list(fs);
            let mut i: u32 = 0;
            while i < fs.len {
                let v = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.field_initializer.value;
                self.cg_mark_move_tail(v, cond, pass);
                self.cg_scan_moves(v, cond, pass);
                i = i + 1;
            }
        } else if nk == NodeKind::NODE_IF {
            let cnd = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt.condition;
            let tb = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt.then_branch;
            let eb = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt.else_branch;
            self.cg_scan_moves(cnd, cond, pass);
            self.cg_scan_moves(tb, true, pass);
            self.cg_scan_moves(eb, true, pass);
        } else if nk == NodeKind::NODE_WHILE {
            let cnd = unsafe (*self.cur_ast()).at_const(id).as_data.while_stmt.condition;
            let b = unsafe (*self.cur_ast()).at_const(id).as_data.while_stmt.body;
            self.cg_scan_moves(cnd, cond, pass);
            self.cg_scan_moves(b, true, pass);
        } else if nk == NodeKind::NODE_FOR {
            let it = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt.iterable;
            let b = unsafe (*self.cur_ast()).at_const(id).as_data.for_stmt.body;
            self.cg_scan_moves(it, cond, pass);
            self.cg_scan_moves(b, true, pass);
        } else if nk == NodeKind::NODE_MATCH {
            let val = unsafe (*self.cur_ast()).at_const(id).as_data.match_expr.value;
            self.cg_mark_move(val, cond, pass, true);
            self.cg_scan_moves(val, cond, pass);
            let arms = unsafe (*self.cur_ast()).at_const(id).as_data.match_expr.arms;
            let ids = unsafe (*self.cur_ast()).list(arms);
            let mut i: u32 = 0;
            while i < arms.len {
                let body = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.match_arm.body;
                self.cg_scan_moves(body, true, pass);
                i = i + 1;
            }
        } else if nk == NodeKind::NODE_EXPRESSION_STATEMENT || nk == NodeKind::NODE_DEFER {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.single.value, cond, pass);
        } else if nk == NodeKind::NODE_CALL {
            let callee_id = unsafe (*self.cur_ast()).at_const(id).as_data.call.callee;
            self.cg_scan_moves(callee_id, cond, pass);
            let ck = unsafe (*self.cur_ast()).at_const(callee_id).kind;
            if ck == NodeKind::NODE_MEMBER {
                let cpath = unsafe (*self.cur_ast()).at_const(callee_id).as_data.member.path;
                let cmember = unsafe (*self.cur_ast()).at_const(callee_id).as_data.member.member;
                let cobj = unsafe (*self.cur_ast()).at_const(callee_id).as_data.member.object;
                if !cpath && span_is(self.mod_src(self.cur_module()), unsafe (*self.cur_ast()).at_const(cmember).as_data.name.text, "free".ptr as *const char) {
                    let rk = unsafe (*self.cur_ast()).type_at(unsafe (*self.cur_ast()).type_of(cobj)).kind;
                    if rk != TypeKind::TYPE_POINTER && rk != TypeKind::TYPE_REFERENCE { self.cg_mark_move(cobj, cond, pass, false); }
                } else if !cpath {
                    let md = unsafe (*self.cur_ast()).resolution_def(cmember);
                    if md.node != NODE_NONE {
                        let mnk = unsafe (*self.mod_ast(md.module)).at_const(md.node).kind;
                        let mparams = unsafe (*self.mod_ast(md.module)).at_const(md.node).as_data.function.params;
                        if mnk == NodeKind::NODE_FUNCTION && mparams.len > 0 {
                            let p0 = unsafe ((*self.mod_ast(md.module)).list(mparams))[0];
                            let pt = unsafe (*self.mod_ast(md.module)).at_const(p0).as_data.parameter.ty;
                            let ptk = if (pt != NODE_NONE) { unsafe (*self.mod_ast(md.module)).at_const(pt).kind; } else { NodeKind::NODE_NONE_KIND; };
                            if ptk != NodeKind::NODE_POINTER_TYPE && ptk != NodeKind::NODE_REFERENCE_TYPE { self.cg_mark_move(cobj, cond, pass, true); }
                        }
                    }
                }
            }
            let args = unsafe (*self.cur_ast()).at_const(id).as_data.call.args;
            let ids = unsafe (*self.cur_ast()).list(args);
            let mut i: u32 = 0;
            while i < args.len {
                let aid = unsafe ids[i as usize];
                self.cg_mark_move(aid, cond, pass, true);
                self.cg_scan_moves(aid, cond, pass);
                i = i + 1;
            }
        } else if nk == NodeKind::NODE_CLOSURE {
            let caps = unsafe (*self.cur_ast()).at_const(id).as_data.closure.captures;
            let mut_caps = unsafe (*self.cur_ast()).at_const(id).as_data.closure.mut_caps;
            let cids = unsafe (*self.cur_ast()).list(caps);
            let mut site_pushed = false;
            let mut i: u32 = 0;
            while i < caps.len {
                let decl = unsafe cids[i as usize];
                if ((mut_caps >> (i as u64)) & (1 as u64)) != 0 as u64 || !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(decl)) { i = i + 1; continue; }
                let patb = unsafe (*self.cur_ast()).at_const(decl).kind == NodeKind::NODE_PATTERN_NAME;
                if pass == 0 {
                    if (!cond || patb) && self.nmoved < 512 { self.moved[self.nmoved as usize] = decl; self.nmoved = self.nmoved + 1; }
                    i = i + 1;
                    continue;
                }
                if patb || !cond || self.cg_is_moved(decl) { i = i + 1; continue; }
                if !self.cg_is_cond_moved(decl) && self.ncond_moved < 256 { self.cond_moved[self.ncond_moved as usize] = decl; self.ncond_moved = self.ncond_moved + 1; }
                if !site_pushed && self.ncond_sites < 256 { self.cond_sites[self.ncond_sites as usize] = id; self.ncond_sites = self.ncond_sites + 1; site_pushed = true; }
                i = i + 1;
            }
        } else if nk == NodeKind::NODE_BINARY {
            let l = unsafe (*self.cur_ast()).at_const(id).as_data.binary.left;
            let r = unsafe (*self.cur_ast()).at_const(id).as_data.binary.right;
            let op = unsafe (*self.cur_ast()).at_const(id).as_data.binary.op;
            self.cg_scan_moves(l, cond, pass);
            self.cg_scan_moves(r, cond || op == TokenType::AmpersandAmpersand || op == TokenType::PipePipe, pass);
        } else if nk == NodeKind::NODE_UNARY {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.unary.operand, cond, pass);
        } else if nk == NodeKind::NODE_MEMBER {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.member.object, cond, pass);
        } else if nk == NodeKind::NODE_INDEX {
            let o = unsafe (*self.cur_ast()).at_const(id).as_data.index.object;
            let ix = unsafe (*self.cur_ast()).at_const(id).as_data.index.index;
            self.cg_scan_moves(o, cond, pass);
            self.cg_scan_moves(ix, cond, pass);
        } else if nk == NodeKind::NODE_CAST {
            self.cg_scan_moves(unsafe (*self.cur_ast()).at_const(id).as_data.cast.expression, cond, pass);
        }
    }
    fn emit_arith_overload(self: &mut Self, id: NodeId) bool {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let m = cg_arith_op_method(bd.op);
        if m == null { return false; }
        let lt0 = unsafe (*self.cur_ast()).type_of(bd.left);
        if lt0 == TYPE_NONE { return false; }
        let lt = self.strip_ref_only(self.subst_resolve(lt0));
        if lt == TYPE_NONE { return false; }
        let bt = *self.type_at(lt);
        if bt.kind != TypeKind::TYPE_STRUCT && bt.kind != TypeKind::TYPE_INSTANCE { return false; }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if bt.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst); om = it.module; od = it.decl; }
        else { om = bt.module; od = bt.as_data.decl; }
        let mth = self.cg_find_method_cstr(om, od, m);
        if mth.node == NODE_NONE { return false; }
        let rt0 = unsafe (*self.cur_ast()).type_of(bd.right);
        let dl = self.cg_ref_depth(self.subst_resolve(unsafe (*self.cur_ast()).type_of(bd.left)));
        let mut dr: i32 = 0;
        if rt0 != TYPE_NONE { dr = self.cg_ref_depth(self.subst_resolve(rt0)); }
        let mut l = Buf32 {};
        let mut r = Buf32 {};
        self.fresh((&mut l.b[0]) as *mut char, 32);
        self.fresh((&mut r.b[0]) as *mut char, 32);
        self.emit("({ __auto_type %s = ".ptr as *const char, (&l.b[0]) as *const char);
        self.emit_expr(bd.left);
        self.emit("; __auto_type %s = ".ptr as *const char, (&r.b[0]) as *const char);
        self.emit_expr(bd.right);
        self.emit_cstr("; ".ptr as *const char);
        self.emit_op_method(bt, om, od, mth);
        let mut lp = "&".ptr as *const char;
        if dl != 0 { lp = ref_derefs(dl); }
        let mut rp = "&".ptr as *const char;
        if dr != 0 { rp = ref_derefs(dr); }
        self.emit("(%s%s, %s%s); })".ptr as *const char, lp, (&l.b[0]) as *const char, rp, (&r.b[0]) as *const char);
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
        if !(add || sub || mul || dv || rm || shl || shr) { return false; }
        let rt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
        if rt == TYPE_NONE { return false; }
        let ry = *self.type_at(rt);
        if ry.kind != TypeKind::TYPE_BUILTIN { return false; }
        let b = ry.as_data.builtin;
        let sgn = b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
        let uns = b == BuiltinType::BT_U8 || b == BuiltinType::BT_U16 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_USIZE;
        if !sgn && !uns { return false; }
        let lnode = bd.left;
        let rnode = bd.right;
        let lt = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(lnode)));
        let rtt = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(rnode)));
        if lt.kind != TypeKind::TYPE_BUILTIN || rtt.kind != TypeKind::TYPE_BUILTIN { return false; }
        let bits: i32 = if (b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8) { 8; } else if (b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16) { 16; } else if (b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32) { 32; } else { 64; };
        let mut lv: i64 = 0;
        let mut rv: i64 = 0;
        let ll = self.cg_int_lit(lnode, (&mut lv) as *mut i64);
        let rl = self.cg_int_lit(rnode, (&mut rv) as *mut i64);
        if ll && rl {
            let mut bad: *const char = null;
            if (dv || rm) && rv == 0 {
                bad = "constant division by zero".ptr as *const char;
            } else if shl || shr {
                if rv < 0 || rv >= bits as i64 { bad = "constant shift out of range".ptr as *const char; }
            } else if sgn && (dv || rm) && rv == -1 && lv == (1 as u64 << 63) as i64 {
                bad = "constant arithmetic overflow".ptr as *const char;
            } else if sgn {
                let mut ov = false;
                let mut res: i64 = 0;
                if add { let u = (lv as u64) + (rv as u64); res = u as i64; if ((lv ^ res) & (rv ^ res)) < 0 { ov = true; } }
                else if sub { let u = (lv as u64) - (rv as u64); res = u as i64; if ((lv ^ rv) & (lv ^ res)) < 0 { ov = true; } }
                else if mul { let u = (lv as u64) * (rv as u64); res = u as i64; }
                else if dv { res = lv / rv; }
                else { res = lv % rv; }
                let mut mn: i64 = 0;
                let mut mx: i64 = 0;
                cg_int_range(b, (&mut mn) as *mut i64, (&mut mx) as *mut i64);
                if ov || res < mn || res > mx { bad = "constant arithmetic overflow".ptr as *const char; }
            }
            if bad != null {
                let sp = unsafe (*self.cur_ast()).at_const(id).span;
                self.errors.emitf(sp.start, sp.end - sp.start, "%s".ptr as *const char, bad);
            }
        }
        if self.const_ctx { return false; }
        let mut rts = Buf64 {};
        self.render_type_id(rt, "".ptr as *const char, (&mut rts.b[0]) as *mut char, 64);
        let rtsp = (&rts.b[0]) as *const char;
        if sgn && (add || sub || mul) {
            let bn = if (add) { "add".ptr as *const char; } else if (sub) { "sub".ptr as *const char; } else { "mul".ptr as *const char; };
            self.emit("({ %s __sc_r; if (__builtin_%s_overflow(".ptr as *const char, rtsp, bn);
            self.emit_expr(lnode);
            self.emit_cstr(", ".ptr as *const char);
            self.emit_expr(rnode);
            self.emit_cstr(", &__sc_r)) { __sc_panic(\"arithmetic overflow\"); } __sc_r; })".ptr as *const char);
            return true;
        }
        if uns && (add || sub || mul) && bits < 32 {
            let opc = if (add) { "+".ptr as *const char; } else if (sub) { "-".ptr as *const char; } else { "*".ptr as *const char; };
            self.emit("((%s)((uint32_t)".ptr as *const char, rtsp);
            self.emit_expr(lnode);
            self.emit(" %s (uint32_t)".ptr as *const char, opc);
            self.emit_expr(rnode);
            self.emit_cstr("))".ptr as *const char);
            return true;
        }
        if shl || shr {
            let uts = if (bits == 8) { "uint8_t".ptr as *const char; } else if (bits == 16) { "uint16_t".ptr as *const char; } else if (bits == 32) { "uint32_t".ptr as *const char; } else { "uint64_t".ptr as *const char; };
            let mut a = Buf32 {};
            let mut s = Buf32 {};
            self.fresh((&mut a.b[0]) as *mut char, 32);
            self.fresh((&mut s.b[0]) as *mut char, 32);
            let ap = (&a.b[0]) as *const char;
            let sp2 = (&s.b[0]) as *const char;
            self.emit("({ %s %s = ".ptr as *const char, rtsp, ap);
            self.emit_expr(lnode);
            self.emit("; int64_t %s = (int64_t)(".ptr as *const char, sp2);
            self.emit_expr(rnode);
            self.emit("); if ((uint64_t)%s >= %d) { __sc_panic(\"shift out of range\"); } ".ptr as *const char, sp2, bits);
            if shl { self.emit("(%s)((%s)((%s)%s << %s)); })".ptr as *const char, rtsp, uts, uts, ap, sp2); }
            else { self.emit("(%s)(%s >> %s); })".ptr as *const char, rtsp, ap, sp2); }
            return true;
        }
        if dv || rm {
            let mut a = Buf32 {};
            let mut d = Buf32 {};
            self.fresh((&mut a.b[0]) as *mut char, 32);
            self.fresh((&mut d.b[0]) as *mut char, 32);
            let ap = (&a.b[0]) as *const char;
            let dp = (&d.b[0]) as *const char;
            self.emit("({ %s %s = ".ptr as *const char, rtsp, ap);
            self.emit_expr(lnode);
            self.emit("; %s %s = ".ptr as *const char, rtsp, dp);
            self.emit_expr(rnode);
            self.emit("; if (%s == 0) { __sc_panic(\"divide by zero\"); } ".ptr as *const char, dp);
            if sgn {
                let mn = if (bits == 8) { "INT8_MIN".ptr as *const char; } else if (bits == 16) { "INT16_MIN".ptr as *const char; } else if (bits == 32) { "INT32_MIN".ptr as *const char; } else { "INT64_MIN".ptr as *const char; };
                self.emit("if (%s == -1 && %s == %s) { __sc_panic(\"arithmetic overflow\"); } ".ptr as *const char, dp, ap, mn);
            }
            let opc = if (dv) { "/".ptr as *const char; } else { "%".ptr as *const char; };
            self.emit("(%s %s %s); })".ptr as *const char, ap, opc, dp);
            return true;
        }
        return false;
    }
    fn emit_slice_coercion(self: &mut Self, id: NodeId) bool {
        let mut selem: TypeId = TYPE_NONE;
        let st = unsafe (*self.cur_ast()).type_of(id);
        if !self.cg_slice_elem(st, (&mut selem) as *mut TypeId) { return false; }
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let is_lit = n.kind == NodeKind::NODE_ARRAY_LITERAL;
        let mut lenN = NODE_NONE;
        if !is_lit { lenN = self.array_length_of(id); }
        if !is_lit && lenN == NODE_NONE { return false; }
        let mut styp = Buf256 {};
        self.render_type_id(st, "".ptr as *const char, (&mut styp.b[0]) as *mut char, 200);
        self.emit("(%s){ .ptr = ".ptr as *const char, (&styp.b[0]) as *const char);
        if is_lit {
            let mut et = Buf256 {};
            self.render_type_id(selem, "".ptr as *const char, (&mut et.b[0]) as *mut char, 256);
            self.emit("(%s[%u])".ptr as *const char, (&et.b[0]) as *const char, n.as_data.array_literal.elements.len);
            self.emit_array_braces(id);
            self.emit(", .len = %u }".ptr as *const char, n.as_data.array_literal.elements.len);
            return true;
        }
        self.slice_raw = id;
        self.emit_expr(id);
        self.slice_raw = NODE_NONE;
        self.emit_cstr(", .len = ".ptr as *const char);
        self.emit_expr(lenN);
        self.emit_cstr(" }".ptr as *const char);
        return true;
    }
    fn emit_dyn_coercion(self: &mut Self, id: NodeId) bool {
        let du = unsafe (*self.cur_ast()).dyn_use_at(id);
        if du == null { return false; }
        let src = unsafe (*du).src;
        let dynTy = unsafe (*du).dyn_ty;
        if src == TYPE_NONE {
            self.emit_cstr("(*(".ptr as *const char);
            self.dyn_raw = id;
            self.emit_expr(id);
            self.dyn_raw = NODE_NONE;
            self.emit_cstr("))".ptr as *const char);
            return true;
        }
        let dy = *self.type_at(dynTy);
        let mut dt = Buf256 {};
        let mut pair = Buf512 {};
        self.render_type_id(dynTy, "".ptr as *const char, (&mut dt.b[0]) as *mut char, 240);
        self.dyn_pair_stem(src, dy.module, dy.as_data.decl, (&mut pair.b[0]) as *mut char, 368);
        let nat = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(id)));
        if nat.kind == TypeKind::TYPE_FUNCTION {
            if !self.cg_fn_is_capturing(&nat) {
                self.emit("((%s){ .data = 0, .vt = &%s__vtbl })".ptr as *const char, (&dt.b[0]) as *const char, (&pair.b[0]) as *const char);
                return true;
            }
            let mut envn = Buf256 {};
            let mut gt = Buf256 {};
            let mut vtmp = Buf32 {};
            let mut gtmp = Buf32 {};
            let mut ptmp = Buf32 {};
            self.render_type_id(src, "".ptr as *const char, (&mut envn.b[0]) as *mut char, 256);
            let gh = unsafe (*self.package).prelude_lookup("Global".ptr as *const char, 6, true);
            self.render_qualified(gh.mid, unsafe (*self.mod_ast(gh.mid)).at_const(gh.node).as_data.aggregate.name, (&mut gt.b[0]) as *mut char, 160);
            self.fresh((&mut vtmp.b[0]) as *mut char, 32);
            self.fresh((&mut gtmp.b[0]) as *mut char, 32);
            self.fresh((&mut ptmp.b[0]) as *mut char, 32);
            self.emit("({ %s %s = ".ptr as *const char, (&envn.b[0]) as *const char, (&vtmp.b[0]) as *const char);
            self.dyn_raw = id;
            self.emit_expr(id);
            self.dyn_raw = NODE_NONE;
            self.emit("; %s %s = %s__default_(); ".ptr as *const char, (&gt.b[0]) as *const char, (&gtmp.b[0]) as *const char, (&gt.b[0]) as *const char);
            self.emit("%s *%s = (%s *)%s__alloc(&%s, sizeof(%s), _Alignof(%s)); *%s = %s; ".ptr as *const char, (&envn.b[0]) as *const char, (&ptmp.b[0]) as *const char, (&envn.b[0]) as *const char, (&gt.b[0]) as *const char, (&gtmp.b[0]) as *const char, (&envn.b[0]) as *const char, (&envn.b[0]) as *const char, (&ptmp.b[0]) as *const char, (&vtmp.b[0]) as *const char);
            self.emit("((%s){ .data = %s, .vt = &%s__vtbl }); })".ptr as *const char, (&dt.b[0]) as *const char, (&ptmp.b[0]) as *const char, (&pair.b[0]) as *const char);
            return true;
        }
        let box_src = nat.kind == TypeKind::TYPE_INSTANCE;
        self.emit("((%s){ .data = (void *)(".ptr as *const char, (&dt.b[0]) as *const char);
        self.dyn_raw = id;
        self.emit_expr(id);
        self.dyn_raw = NODE_NONE;
        let mut tail = ")".ptr as *const char;
        if box_src { tail = ").ptr".ptr as *const char; }
        self.emit("%s, .vt = &%s__vtbl })".ptr as *const char, tail, (&pair.b[0]) as *const char);
        return true;
    }
    fn array_length_of(self: &mut Self, iter: NodeId) NodeId {
        if unsafe (*self.cur_ast()).at_const(iter).kind != NodeKind::NODE_IDENTIFIER { return NODE_NONE; }
        let d = unsafe (*self.cur_ast()).resolution(iter);
        if d == NODE_NONE { return NODE_NONE; }
        let dn = *unsafe (*self.cur_ast()).at_const(d);
        let mut tn = NODE_NONE;
        if dn.kind == NodeKind::NODE_PARAMETER { tn = dn.as_data.parameter.ty; }
        else if dn.kind == NodeKind::NODE_LET { tn = dn.as_data.let_stmt.ty; }
        else if dn.kind == NodeKind::NODE_FIELD { tn = dn.as_data.field.ty; }
        if tn != NODE_NONE && unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_ARRAY_TYPE { return unsafe (*self.cur_ast()).at_const(tn).as_data.array_type.length; }
        return NODE_NONE;
    }
    fn array_literal_count(self: &mut Self, obj: NodeId) i64 {
        let o = *unsafe (*self.cur_ast()).at_const(obj);
        if o.kind == NodeKind::NODE_ARRAY_LITERAL { return o.as_data.array_literal.elements.len as i64; }
        if o.kind != NodeKind::NODE_IDENTIFIER { return -1; }
        let d = unsafe (*self.cur_ast()).resolution(obj);
        if d == NODE_NONE { return -1; }
        let dn = *unsafe (*self.cur_ast()).at_const(d);
        let mut v = NODE_NONE;
        if dn.kind == NodeKind::NODE_LET { v = dn.as_data.let_stmt.value; }
        if v != NODE_NONE && unsafe (*self.cur_ast()).at_const(v).kind == NodeKind::NODE_ARRAY_LITERAL { return unsafe (*self.cur_ast()).at_const(v).as_data.array_literal.elements.len as i64; }
        return -1;
    }
    fn cg_int_lit(self: &mut Self, e: NodeId, out: *mut i64) bool {
        let n = *unsafe (*self.cur_ast()).at_const(e);
        if n.kind != NodeKind::NODE_LITERAL || n.as_data.literal.token_type != TokenType::IntegerLiteral { return false; }
        let raw = n.as_data.literal.raw;
        let mut buf = Buf32 {};
        let mut k: usize = 0;
        let mut i = raw.start;
        while i < raw.end && k + 1 < 32 {
            let ch = unsafe self.source[i as usize];
            if ch == '_' as u8 { i = i + 1; continue; }
            if k == 0 && ch == '0' as u8 && i + 1 < raw.end { buf.b[k] = ch as char; k = k + 1; i = i + 1; continue; }
            let hexish = (ch >= '0' as u8 && ch <= '9' as u8) || (ch >= 'a' as u8 && ch <= 'f' as u8) || (ch >= 'A' as u8 && ch <= 'F' as u8) || ch == 'x' as u8 || ch == 'X' as u8 || ch == 'b' as u8 || ch == 'B' as u8 || ch == 'o' as u8 || ch == 'O' as u8;
            if !hexish { break; }
            buf.b[k] = ch as char;
            k = k + 1;
            i = i + 1;
        }
        buf.b[k] = 0 as char;
        if k == 0 { return false; }
        let mut endp: *mut char = null;
        let v = unsafe strtol((&buf.b[0]) as *const char, (&mut endp) as *mut *mut char, 0);
        if endp == (&mut buf.b[0]) as *mut char { return false; }
        unsafe *out = v;
        return true;
    }
    fn cg_attr(self: &Self, m: ModuleId, owner: NodeId, kind: AttrKind) *const Attr {
        let a = self.mod_ast(m);
        let mut i: usize = 0;
        while i < unsafe (*a).attrs.len() {
            let at = unsafe (*a).attrs.at(i);
            if at.owner == owner && at.kind == (kind as u8) { return at as *const Attr; }
            i = i + 1;
        }
        return null;
    }
    fn cg_symbol_override(self: &Self, m: ModuleId, fn2: NodeId, out: *mut char, cap: usize) bool {
        let mut a = self.cg_attr(m, fn2, AttrKind::ATTR_EXPORT);
        if a == null { a = self.cg_attr(m, fn2, AttrKind::ATTR_IMPORT); }
        if a == null || cap == 0 { return false; }
        let sp = unsafe (*a).str_span;
        let mut nn = (sp.end - sp.start) as usize;
        if nn >= cap { nn = cap - 1; }
        unsafe cstring::memcpy(out as *mut void, src_at(self.mod_src(m), sp.start) as *const void, nn);
        unsafe out[nn] = 0 as char;
        return true;
    }
    fn decl_is_toplevel(self: &Self, m: ModuleId, node: NodeId) bool {
        let a = self.mod_ast(m);
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let mut i: u32 = 0;
        while i < items.len { if unsafe ((*a).list(items))[i as usize] == node { return true; } i = i + 1; }
        return false;
    }
    fn cg_env_capture(self: &Self, decl: NodeId, is_mut: *mut bool) i32 {
        if self.env_clos == NODE_NONE || decl == NODE_NONE { return -1; }
        let caps = unsafe (*self.cur_ast()).at_const(self.env_clos).as_data.closure.captures;
        let mut_caps = unsafe (*self.cur_ast()).at_const(self.env_clos).as_data.closure.mut_caps;
        let cids = unsafe (*self.cur_ast()).list(caps);
        let mut i: u32 = 0;
        while i < caps.len {
            if unsafe cids[i as usize] == decl {
                unsafe (*is_mut) = ((mut_caps >> (i as u64)) & (1 as u64)) != 0 as u64;
                return i as i32;
            }
            i = i + 1;
        }
        return -1;
    }
    fn cg_decl_name_span(self: &Self, decl: NodeId) tok::Span {
        let n = unsafe (*self.cur_ast()).at_const(decl);
        if n.kind == NodeKind::NODE_LET { return self.name_span(n.as_data.let_stmt.name); }
        if n.kind == NodeKind::NODE_PARAMETER { return self.name_span(n.as_data.parameter.name); }
        return tok::Span { start: 0, end: 0 };
    }
    fn emit_auto_free(self: &mut Self, bid: NodeId) void {
        let bt = unsafe (*self.cur_ast()).type_of(bid);
        if !self.cg_type_is_free(bt) { return; }
        if self.cg_is_cond_moved(bid) {
            let mut fl = Buf32 {};
            cg_move_flag((&mut fl.b[0]) as *mut char, 32, bid);
            self.emit("if (!%s) ".ptr as *const char, (&fl.b[0]) as *const char);
        }
        self.emit_free_target(bt);
        let ln = *unsafe (*self.cur_ast()).at_const(bid);
        let mut nameNode = ln.as_data.let_stmt.name;
        if ln.kind == NodeKind::NODE_PARAMETER { nameNode = ln.as_data.parameter.name; }
        else if ln.kind == NodeKind::NODE_IDENTIFIER { nameNode = bid; }
        let mut nm = Buf128 {};
        self.render_ident(self.name_span(nameNode), (&mut nm.b[0]) as *mut char, 128);
        self.emit("(&%s);\n".ptr as *const char, (&nm.b[0]) as *const char);
    }
    fn emit_expr_stmt(self: &mut Self, v0: NodeId) void {
        let mut v = v0;
        let mut n = *unsafe (*self.cur_ast()).at_const(v);
        while n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
            v = n.as_data.unary.operand;
            n = *unsafe (*self.cur_ast()).at_const(v);
        }
        if self.ceval() != null && n.kind == NodeKind::NODE_CALL && unsafe (*self.ceval()).eval(self.cur_module(), v).kind != ce::CONST_NONE { self.emit_cstr(";\n".ptr as *const char); return; }
        if n.kind == NodeKind::NODE_BLOCK { self.emit_block(v); self.emit_cstr("\n".ptr as *const char); return; }
        if n.kind == NodeKind::NODE_IF { self.emit_if(v); self.emit_cstr("\n".ptr as *const char); return; }
        if n.kind == NodeKind::NODE_MATCH { self.emit_match_stmt(v); return; }
        let vt = unsafe (*self.cur_ast()).type_of(v);
        if vt != TYPE_NONE && !self.no_temp_free && n.kind != NodeKind::NODE_ASSIGNMENT && !self.is_lvalue(v) && self.cg_type_is_free(vt) {
            let mut tmp = Buf32 {};
            self.fresh((&mut tmp.b[0]) as *mut char, 32);
            self.emit("{ __auto_type %s = ".ptr as *const char, (&tmp.b[0]) as *const char);
            self.emit_expr(v);
            self.emit_cstr("; ".ptr as *const char);
            self.emit_free_target(vt);
            self.emit("(&%s); }\n".ptr as *const char, (&tmp.b[0]) as *const char);
            return;
        }
        self.emit_expr(v);
        self.emit_cstr(";\n".ptr as *const char);
    }
    fn emit_assignment(self: &mut Self, id: NodeId) void {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let lt = unsafe (*self.cur_ast()).type_of(bd.left);
        let mut ltr = TYPE_NONE;
        if lt != TYPE_NONE { ltr = self.subst_resolve(lt); }
        if bd.op == TokenType::Equal && ltr != TYPE_NONE && self.type_at(ltr).kind == TypeKind::TYPE_ARRAY {
            self.emit_cstr("memcpy(".ptr as *const char);
            self.emit_expr(bd.left);
            self.emit_cstr(", ".ptr as *const char);
            self.emit_expr(bd.right);
            self.emit_cstr(", sizeof(".ptr as *const char);
            self.emit_expr(bd.left);
            self.emit_cstr("))".ptr as *const char);
            return;
        }
        let mut lhsId = bd.left;
        let mut lhs = *unsafe (*self.cur_ast()).at_const(lhsId);
        while lhs.kind == NodeKind::NODE_UNARY && (lhs.as_data.unary.op == TokenType::Move || lhs.as_data.unary.op == TokenType::Unsafe) {
            lhsId = lhs.as_data.unary.operand;
            lhs = *unsafe (*self.cur_ast()).at_const(lhsId);
        }
        let mut ld = DefId { module: 0, node: NODE_NONE };
        if lhs.kind == NodeKind::NODE_IDENTIFIER { ld = unsafe (*self.cur_ast()).resolution_def(lhsId); }
        if bd.op == TokenType::Equal && lhs.kind == NodeKind::NODE_IDENTIFIER && self.cg_type_is_free(lt) && ld.node != NODE_NONE && !self.cg_is_moved(ld.node) {
            let mut r = Buf32 {};
            self.fresh((&mut r.b[0]) as *mut char, 32);
            self.emit("({ __auto_type %s = ".ptr as *const char, (&r.b[0]) as *const char);
            self.emit_expr(bd.right);
            self.emit_cstr("; ".ptr as *const char);
            self.emit_free_target(lt);
            self.emit_cstr("(&".ptr as *const char);
            self.emit_expr(bd.left);
            self.emit_cstr("); (".ptr as *const char);
            self.emit_expr(bd.left);
            self.emit(" = %s); })".ptr as *const char, (&r.b[0]) as *const char);
            return;
        }
        if lhs.kind == NodeKind::NODE_INDEX && unsafe (*self.cur_ast()).at_const(lhs.as_data.index.index).kind != NodeKind::NODE_RANGE {
            let iot = unsafe (*self.cur_ast()).type_of(lhs.as_data.index.object);
            let mut riot = TYPE_NONE;
            if iot != TYPE_NONE { riot = self.strip_ref_only(self.subst_resolve(iot)); }
            let mut ird: i32 = 0;
            if iot != TYPE_NONE { ird = self.cg_ref_depth(self.subst_resolve(iot)); }
            let mut ibk = TypeKind::TYPE_ERROR;
            if riot != TYPE_NONE { ibk = self.type_at(riot).kind; }
            if riot != TYPE_NONE && (ibk == TypeKind::TYPE_STRUCT || ibk == TypeKind::TYPE_INSTANCE) && !self.cg_slice_elem(riot, null) {
                let ibt = *self.type_at(riot);
                let mut om: ModuleId = 0;
                let mut od = NODE_NONE;
                if ibt.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(ibt.as_data.inst); om = it.module; od = it.decl; }
                else { om = ibt.module; od = ibt.as_data.decl; }
                let mth = self.cg_find_method_cstr(om, od, "index_mut".ptr as *const char);
                if mth.node != NODE_NONE {
                    let mut refp = "&".ptr as *const char;
                    if ird != 0 { refp = ref_derefs(ird); }
                    if bd.op == TokenType::Equal && lt != TYPE_NONE && self.cg_type_is_free(lt) {
                        let mut r = Buf32 {};
                        let mut p = Buf32 {};
                        self.fresh((&mut r.b[0]) as *mut char, 32);
                        self.fresh((&mut p.b[0]) as *mut char, 32);
                        self.emit("({ __auto_type %s = ".ptr as *const char, (&r.b[0]) as *const char);
                        self.emit_expr(bd.right);
                        self.emit("; __auto_type %s = ".ptr as *const char, (&p.b[0]) as *const char);
                        self.emit_op_method(ibt, om, od, mth);
                        self.emit_cstr("(".ptr as *const char);
                        self.emit_prefixed(lhs.as_data.index.object, refp);
                        self.emit_cstr(", ".ptr as *const char);
                        self.emit_expr(lhs.as_data.index.index);
                        self.emit_cstr("); ".ptr as *const char);
                        self.emit_free_target(lt);
                        self.emit("(%s); (*%s = %s); })".ptr as *const char, (&p.b[0]) as *const char, (&p.b[0]) as *const char, (&r.b[0]) as *const char);
                    } else {
                        self.emit_cstr("(*".ptr as *const char);
                        self.emit_op_method(ibt, om, od, mth);
                        self.emit_cstr("(".ptr as *const char);
                        self.emit_prefixed(lhs.as_data.index.object, refp);
                        self.emit_cstr(", ".ptr as *const char);
                        self.emit_expr(lhs.as_data.index.index);
                        self.emit(") %s ".ptr as *const char, c_op(bd.op));
                        self.emit_expr(bd.right);
                        self.emit_cstr(")".ptr as *const char);
                    }
                    return;
                }
            }
        }
        self.emit_cstr("(".ptr as *const char);
        self.emit_expr(bd.left);
        self.emit(" %s ".ptr as *const char, c_op(bd.op));
        self.emit_expr(bd.right);
        self.emit_cstr(")".ptr as *const char);
    }
    fn emit_free_target(self: &mut Self, bt: TypeId) bool {
        let y = *self.type_at(self.subst_resolve(bt));
        if y.kind == TypeKind::TYPE_FUNCTION {
            if !self.cg_fn_owns(&y) { return false; }
            let mut sym = Buf256 {};
            self.closure_sym_in(y.module, y.as_data.decl, (&mut sym.b[0]) as *mut char, 220);
            self.emit("%s_env_free".ptr as *const char, (&sym.b[0]) as *const char);
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN {
            if y.qualifier != (TypeQualifier::TYPE_QUAL_NONE as u8) { return false; }
            let mut stem = Buf256 {};
            self.dyn_stem(y.module, y.as_data.decl, (&mut stem.b[0]) as *mut char, 176);
            self.emit("%s__dyn_free".ptr as *const char, (&stem.b[0]) as *const char);
            return true;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if y.kind == TypeKind::TYPE_INSTANCE { let ii = *unsafe (*self.cur_ast()).instance(y.as_data.inst); om = ii.module; od = ii.decl; }
        else if y.kind == TypeKind::TYPE_STRUCT { om = y.module; od = y.as_data.decl; }
        else { return false; }
        let dm = self.cg_free_method(om, od);
        if dm.node == NODE_NONE { return false; }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(y.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
            self.emit_cstr((&inm.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else {
            let mut pfx = Buf64 {};
            self.render_modpfx(dm.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_ident_mod(om, unsafe (*self.mod_ast(om)).at_const(od).as_data.aggregate.name);
            self.emit_cstr("__".ptr as *const char);
        }
        self.emit_ident_mod(dm.module, unsafe (*self.mod_ast(dm.module)).at_const(dm.node).as_data.function.name);
        return true;
    }
    fn pat_trivial(self: &Self, pid: NodeId) bool {
        let p = unsafe (*self.cur_ast()).at_const(pid);
        if p.kind == NodeKind::NODE_PATTERN_NAME { return p.as_data.pattern.children.len == 0; }
        return p.kind == NodeKind::NODE_PATTERN_WILDCARD || p.kind == NodeKind::NODE_IDENTIFIER;
    }
    fn emit_pattern_test(self: &mut Self, pid: NodeId, scrut: *const char) void {
        let p = *unsafe (*self.cur_ast()).at_const(pid);
        let pk = p.kind;
        if pk == NodeKind::NODE_PATTERN_NAME {
            let vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                let en = self.enclosing_enum_in(vd.module, vd.node);
                let payload = en != NODE_NONE && self.aggregate_has_payload_in(vd.module, en);
                if payload { self.emit("%s.tag == ".ptr as *const char, scrut); } else { self.emit("%s == ".ptr as *const char, scrut); }
                if en != NODE_NONE { self.emit_tag_mod(vd.module, en, vd.node); } else { self.emit_cstr("0".ptr as *const char); }
            } else if p.as_data.pattern.children.len != 0 {
                self.emit_pattern_test(unsafe ((*self.cur_ast()).list(p.as_data.pattern.children))[0], scrut);
            } else { self.emit_cstr("1".ptr as *const char); }
        }
        else if pk == NodeKind::NODE_PATTERN_WILDCARD || pk == NodeKind::NODE_IDENTIFIER { self.emit_cstr("1".ptr as *const char); }
        else if pk == NodeKind::NODE_PATTERN_LITERAL {
            self.emit("%s == ".ptr as *const char, scrut);
            self.emit_expr(p.as_data.single.value);
        }
        else if pk == NodeKind::NODE_PATTERN_RANGE {
            let lo = p.as_data.pattern_range.start;
            let hi = p.as_data.pattern_range.end;
            if lo != NODE_NONE {
                let lon = unsafe (*self.cur_ast()).at_const(lo);
                self.emit("%s >= ".ptr as *const char, scrut);
                self.emit_expr(if_node(lon.kind == NodeKind::NODE_PATTERN_LITERAL, lon.as_data.single.value, lo));
            }
            if hi != NODE_NONE {
                let hin = unsafe (*self.cur_ast()).at_const(hi);
                let mut andp = "".ptr as *const char;
                if lo != NODE_NONE { andp = " && ".ptr as *const char; }
                let mut cmp = "<".ptr as *const char;
                if p.as_data.pattern_range.inclusive { cmp = "<=".ptr as *const char; }
                self.emit("%s%s %s ".ptr as *const char, andp, scrut, cmp);
                self.emit_expr(if_node(hin.kind == NodeKind::NODE_PATTERN_LITERAL, hin.as_data.single.value, hi));
            }
        }
        else if pk == NodeKind::NODE_PATTERN_TUPLE {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE { vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name); }
            let ch = p.as_data.pattern.children;
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                let en = self.enclosing_enum_in(vd.module, vd.node);
                let payload = en != NODE_NONE && self.aggregate_has_payload_in(vd.module, en);
                if payload { self.emit("%s.tag == ".ptr as *const char, scrut); } else { self.emit("%s == ".ptr as *const char, scrut); }
                if en != NODE_NONE { self.emit_tag_mod(vd.module, en, vd.node); } else { self.emit_cstr("0".ptr as *const char); }
                let mut vn = Buf128 {};
                self.render_variant_name(vd.module, vd.node, (&mut vn.b[0]) as *mut char, 128);
                let mut i: u32 = 0;
                while i < ch.len {
                    let cid = unsafe ((*self.cur_ast()).list(ch))[i as usize];
                    if !self.pat_trivial(cid) {
                        let mut sub = Buf256 {};
                        unsafe stdio::snprintf((&mut sub.b[0]) as *mut char, 256, "%s.payload.%s._%u".ptr as *const char, scrut, (&vn.b[0]) as *const char, i);
                        self.emit_cstr(" && ".ptr as *const char);
                        self.emit_pattern_test(cid, (&sub.b[0]) as *const char);
                    }
                    i = i + 1;
                }
            } else if ch.len == 1 { self.emit_pattern_test(unsafe ((*self.cur_ast()).list(ch))[0], scrut); }
            else { self.emit_cstr("1".ptr as *const char); }
        }
        else if pk == NodeKind::NODE_PATTERN_STRUCT {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE { vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name); }
            let is_variant = vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT;
            let ch = p.as_data.pattern.children;
            let mut prefix = Buf512 {};
            let mut wrote = false;
            if is_variant {
                let en = self.enclosing_enum_in(vd.module, vd.node);
                let payload = en != NODE_NONE && self.aggregate_has_payload_in(vd.module, en);
                if payload { self.emit("%s.tag == ".ptr as *const char, scrut); } else { self.emit("%s == ".ptr as *const char, scrut); }
                if en != NODE_NONE { self.emit_tag_mod(vd.module, en, vd.node); } else { self.emit_cstr("0".ptr as *const char); }
                wrote = true;
                let mut vn = Buf128 {};
                self.render_variant_name(vd.module, vd.node, (&mut vn.b[0]) as *mut char, 128);
                unsafe stdio::snprintf((&mut prefix.b[0]) as *mut char, 300, "%s.payload.%s".ptr as *const char, scrut, (&vn.b[0]) as *const char);
            } else {
                unsafe stdio::snprintf((&mut prefix.b[0]) as *mut char, 300, "%s".ptr as *const char, scrut);
            }
            let mut i: u32 = 0;
            while i < ch.len {
                let fid = unsafe ((*self.cur_ast()).list(ch))[i as usize];
                let f = unsafe (*self.cur_ast()).at_const(fid);
                let sub = f.as_data.pattern.children;
                let mut subpat = NODE_NONE;
                if sub.len != 0 { subpat = unsafe ((*self.cur_ast()).list(sub))[0]; }
                if subpat != NODE_NONE && !self.pat_trivial(subpat) {
                    let mut m = Buf128 {};
                    self.render_ident(self.name_span(f.as_data.pattern.name), (&mut m.b[0]) as *mut char, 128);
                    let mut acc = Buf512 {};
                    unsafe stdio::snprintf((&mut acc.b[0]) as *mut char, 440, "%s.%s".ptr as *const char, (&prefix.b[0]) as *const char, (&m.b[0]) as *const char);
                    if wrote { self.emit_cstr(" && ".ptr as *const char); }
                    self.emit_pattern_test(subpat, (&acc.b[0]) as *const char);
                    wrote = true;
                }
                i = i + 1;
            }
            if !wrote { self.emit_cstr("1".ptr as *const char); }
        }
        else if pk == NodeKind::NODE_PATTERN_OR {
            let alts = p.as_data.pattern.children;
            if alts.len == 0 { self.emit_cstr("1".ptr as *const char); return; }
            let mut i: u32 = 0;
            while i < alts.len {
                if i != 0 { self.emit_cstr(" || (".ptr as *const char); } else { self.emit_cstr("(".ptr as *const char); }
                self.emit_pattern_test(unsafe ((*self.cur_ast()).list(alts))[i as usize], scrut);
                self.emit_cstr(")".ptr as *const char);
                i = i + 1;
            }
        }
        else { self.emit_cstr("1".ptr as *const char); }
    }
    fn emit_bind(self: &mut Self, pid: NodeId, name: tok::Span, is_mut: bool, scrut: *const char, by_ref: bool) void {
        self.emit_indent();
        if by_ref {
            let mut nm = Buf128 {};
            self.render_ident(name, (&mut nm.b[0]) as *mut char, 128);
            let mut cq = "const ".ptr as *const char;
            if is_mut { cq = "".ptr as *const char; }
            self.emit("%s__auto_type %s = &(%s);\n".ptr as *const char, cq, (&nm.b[0]) as *const char, scrut);
        } else {
            let pt = unsafe (*self.cur_ast()).type_of(pid);
            self.emit_binding(pt, name, !is_mut && !self.cg_type_is_free(pt));
            self.emit(" = %s;\n".ptr as *const char, scrut);
        }
    }
    fn emit_pattern_binds(self: &mut Self, pid: NodeId, scrut: *const char, by_ref: bool) void {
        let p = *unsafe (*self.cur_ast()).at_const(pid);
        let pk = p.kind;
        if pk == NodeKind::NODE_PATTERN_NAME {
            let vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name);
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT { return; }
            let is_mut = unsafe (*self.cur_ast()).at_const(p.as_data.pattern.name).as_data.name.is_mutable;
            self.emit_bind(pid, self.name_span(p.as_data.pattern.name), is_mut, scrut, by_ref);
            if p.as_data.pattern.children.len != 0 { self.emit_pattern_binds(unsafe ((*self.cur_ast()).list(p.as_data.pattern.children))[0], scrut, by_ref); }
        }
        else if pk == NodeKind::NODE_IDENTIFIER {
            self.emit_bind(pid, p.as_data.name.text, p.as_data.name.is_mutable, scrut, by_ref);
        }
        else if pk == NodeKind::NODE_PATTERN_TUPLE {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE { vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name); }
            let ch = p.as_data.pattern.children;
            let mut vn = Buf128 {};
            vn.b[0] = 0 as char;
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT { self.render_variant_name(vd.module, vd.node, (&mut vn.b[0]) as *mut char, 128); }
            let mut i: u32 = 0;
            while i < ch.len {
                let mut sub = Buf256 {};
                if vn.b[0] != 0 as char { unsafe stdio::snprintf((&mut sub.b[0]) as *mut char, 256, "%s.payload.%s._%u".ptr as *const char, scrut, (&vn.b[0]) as *const char, i); }
                else { unsafe stdio::snprintf((&mut sub.b[0]) as *mut char, 256, "%s".ptr as *const char, scrut); }
                self.emit_pattern_binds(unsafe ((*self.cur_ast()).list(ch))[i as usize], (&sub.b[0]) as *const char, by_ref);
                i = i + 1;
            }
        }
        else if pk == NodeKind::NODE_PATTERN_STRUCT {
            let mut vd = DefId { module: 0, node: NODE_NONE };
            if p.as_data.pattern.name != NODE_NONE { vd = unsafe (*self.cur_ast()).resolution_def(p.as_data.pattern.name); }
            let mut prefix = Buf512 {};
            if vd.node != NODE_NONE && unsafe (*self.mod_ast(vd.module)).at_const(vd.node).kind == NodeKind::NODE_VARIANT {
                let mut vn = Buf128 {};
                self.render_variant_name(vd.module, vd.node, (&mut vn.b[0]) as *mut char, 128);
                unsafe stdio::snprintf((&mut prefix.b[0]) as *mut char, 300, "%s.payload.%s".ptr as *const char, scrut, (&vn.b[0]) as *const char);
            } else { unsafe stdio::snprintf((&mut prefix.b[0]) as *mut char, 300, "%s".ptr as *const char, scrut); }
            let ch = p.as_data.pattern.children;
            let mut i: u32 = 0;
            while i < ch.len {
                let fid = unsafe ((*self.cur_ast()).list(ch))[i as usize];
                let f = unsafe (*self.cur_ast()).at_const(fid);
                let mut m = Buf128 {};
                self.render_ident(self.name_span(f.as_data.pattern.name), (&mut m.b[0]) as *mut char, 128);
                let mut acc = Buf512 {};
                unsafe stdio::snprintf((&mut acc.b[0]) as *mut char, 440, "%s.%s".ptr as *const char, (&prefix.b[0]) as *const char, (&m.b[0]) as *const char);
                let sub = f.as_data.pattern.children;
                if sub.len != 0 { self.emit_pattern_binds(unsafe ((*self.cur_ast()).list(sub))[0], (&acc.b[0]) as *const char, by_ref); }
                i = i + 1;
            }
        }
        else if pk == NodeKind::NODE_PATTERN_OR {
            let alts = p.as_data.pattern.children;
            if alts.len != 0 { self.emit_pattern_binds(unsafe ((*self.cur_ast()).list(alts))[0], scrut, by_ref); }
        }
    }
    fn emit_index(self: &mut Self, id: NodeId) void {
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
            if oty0 != TYPE_NONE { roty = self.strip_ref_only(self.subst_resolve(oty0)); }
            let mut refd: i32 = 0;
            if oty0 != TYPE_NONE { refd = self.cg_ref_depth(self.subst_resolve(oty0)); }
            if self.package != null && !self.cg_slice_elem(roty, null) {
                let mut btk = TypeKind::TYPE_ERROR;
                if roty != TYPE_NONE { btk = self.type_at(roty).kind; }
                if roty != TYPE_NONE && (btk == TypeKind::TYPE_STRUCT || btk == TypeKind::TYPE_INSTANCE) {
                    let bt = *self.type_at(roty);
                    let mut om: ModuleId = 0;
                    let mut od = NODE_NONE;
                    if bt.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst); om = it.module; od = it.decl; }
                    else { om = bt.module; od = bt.as_data.decl; }
                    let mth = self.cg_find_method_cstr(om, od, "index_range".ptr as *const char);
                    if mth.node != NODE_NONE {
                        let rh = unsafe (*self.package).prelude_lookup("Range".ptr as *const char, 5, true);
                        let usz = Ast::builtin(BuiltinType::BT_USIZE);
                        let rangeTy = unsafe (*self.cur_ast()).intern_instance(rh.mid, rh.node, (&usz) as *const TypeId, 1);
                        let mut rn = Buf256 {};
                        self.render_type_id(rangeTy, "".ptr as *const char, (&mut rn.b[0]) as *mut char, 200);
                        let mut o = Buf32 {};
                        self.fresh((&mut o.b[0]) as *mut char, 32);
                        if refd > 0 {
                            self.emit("({ __auto_type %s = ".ptr as *const char, (&o.b[0]) as *const char);
                            self.emit_prefixed(obj, ref_derefs(refd));
                        } else if self.is_lvalue(obj) {
                            self.emit("({ __auto_type %s = ".ptr as *const char, (&o.b[0]) as *const char);
                            self.emit_prefixed(obj, "&".ptr as *const char);
                        } else {
                            let mut v = Buf32 {};
                            self.fresh((&mut v.b[0]) as *mut char, 32);
                            self.emit("({ __auto_type %s = ".ptr as *const char, (&v.b[0]) as *const char);
                            self.emit_expr(obj);
                            self.emit("; __auto_type %s = &%s".ptr as *const char, (&o.b[0]) as *const char, (&v.b[0]) as *const char);
                        }
                        self.emit_cstr("; ".ptr as *const char);
                        self.emit_op_method(bt, om, od, mth);
                        self.emit("(%s, (%s){ .start = ".ptr as *const char, (&o.b[0]) as *const char, (&rn.b[0]) as *const char);
                        if lo != NODE_NONE { self.emit_expr(lo); } else { self.emit_cstr("0".ptr as *const char); }
                        self.emit_cstr(", .end = ".ptr as *const char);
                        if hi != NODE_NONE { self.emit_expr(hi); }
                        else {
                            let lm = self.cg_find_method_cstr(om, od, "len".ptr as *const char);
                            if lm.node != NODE_NONE { self.emit_op_method(bt, om, od, lm); self.emit("(%s)".ptr as *const char, (&o.b[0]) as *const char); } else { self.emit_cstr("0".ptr as *const char); }
                        }
                        let mut incls = "false".ptr as *const char;
                        if incl { incls = "true".ptr as *const char; }
                        self.emit(", .inclusive = %s }); })".ptr as *const char, incls);
                        return;
                    }
                }
            }
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(id), "".ptr as *const char, (&mut styp.b[0]) as *mut char, 200);
            let isslice = self.cg_slice_elem(roty, null);
            let mut arrlen = NODE_NONE;
            if !isslice { arrlen = self.array_length_of(obj); }
            let mut b = Buf32 {};
            self.fresh((&mut b.b[0]) as *mut char, 32);
            self.emit("({ __auto_type %s = ".ptr as *const char, (&b.b[0]) as *const char);
            if refd > 0 { self.emit_prefixed(obj, ref_derefs(refd + 1)); } else { self.emit_expr(obj); }
            let mut sfx = "".ptr as *const char;
            if isslice { sfx = ".ptr".ptr as *const char; }
            self.emit("; (%s){ .ptr = %s%s + ".ptr as *const char, (&styp.b[0]) as *const char, (&b.b[0]) as *const char, sfx);
            if lo != NODE_NONE { self.emit_cstr("(".ptr as *const char); self.emit_expr(lo); self.emit_cstr(")".ptr as *const char); } else { self.emit_cstr("0".ptr as *const char); }
            self.emit_cstr(", .len = ".ptr as *const char);
            if hi != NODE_NONE {
                self.emit_cstr("(".ptr as *const char);
                self.emit_expr(hi);
                if incl { self.emit_cstr(") + 1".ptr as *const char); } else { self.emit_cstr(")".ptr as *const char); }
            } else if isslice { self.emit("%s.len".ptr as *const char, (&b.b[0]) as *const char); }
            else if arrlen != NODE_NONE { self.emit_expr(arrlen); }
            else { let cnt = self.array_literal_count(obj); if cnt >= 0 { self.emit("%ld".ptr as *const char, cnt); } else { self.emit_cstr("0".ptr as *const char); } }
            self.emit_cstr(" - ".ptr as *const char);
            if lo != NODE_NONE { self.emit_cstr("(".ptr as *const char); self.emit_expr(lo); self.emit_cstr(")".ptr as *const char); } else { self.emit_cstr("0".ptr as *const char); }
            self.emit_cstr(" }; })".ptr as *const char);
            return;
        }
        // index overload: obj[i] on struct/instance -> index method
        let ot = unsafe (*self.cur_ast()).type_of(obj);
        let mut rot = TYPE_NONE;
        if ot != TYPE_NONE { rot = self.strip_ref_only(self.subst_resolve(ot)); }
        let mut rd: i32 = 0;
        if ot != TYPE_NONE { rd = self.cg_ref_depth(self.subst_resolve(ot)); }
        let mut btk = TypeKind::TYPE_ERROR;
        if rot != TYPE_NONE { btk = self.type_at(rot).kind; }
        if rot != TYPE_NONE && (btk == TypeKind::TYPE_STRUCT || btk == TypeKind::TYPE_INSTANCE) && !self.cg_slice_elem(rot, null) {
            let bt = *self.type_at(rot);
            let mut om: ModuleId = 0;
            let mut od = NODE_NONE;
            if bt.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst); om = it.module; od = it.decl; }
            else { om = bt.module; od = bt.as_data.decl; }
            let mth = self.cg_find_method_cstr(om, od, "index".ptr as *const char);
            if mth.node != NODE_NONE {
                let mam = self.mod_ast(mth.module);
                let mrets = unsafe (*mam).at_const(mth.node).as_data.function.returns;
                let mut retref = false;
                if mrets.len == 1 {
                    let mr0 = unsafe ((*mam).list(mrets))[0];
                    let mrn = unsafe (*mam).at_const(mr0);
                    let mtn = if_node(mrn.kind == NodeKind::NODE_PARAMETER, mrn.as_data.parameter.ty, mr0);
                    retref = mtn != NODE_NONE && unsafe (*mam).at_const(mtn).kind == NodeKind::NODE_REFERENCE_TYPE;
                }
                let mut o = Buf32 {};
                self.fresh((&mut o.b[0]) as *mut char, 32);
                if retref { self.emit_cstr("(*".ptr as *const char); }
                if rd > 0 {
                    self.emit("({ __auto_type %s = ".ptr as *const char, (&o.b[0]) as *const char);
                    self.emit_prefixed(obj, ref_derefs(rd));
                } else if self.is_lvalue(obj) {
                    self.emit("({ __auto_type %s = ".ptr as *const char, (&o.b[0]) as *const char);
                    self.emit_prefixed(obj, "&".ptr as *const char);
                } else {
                    let mut v = Buf32 {};
                    self.fresh((&mut v.b[0]) as *mut char, 32);
                    self.emit("({ __auto_type %s = ".ptr as *const char, (&v.b[0]) as *const char);
                    self.emit_expr(obj);
                    self.emit("; __auto_type %s = &%s".ptr as *const char, (&o.b[0]) as *const char, (&v.b[0]) as *const char);
                }
                self.emit_cstr("; ".ptr as *const char);
                self.emit_op_method(bt, om, od, mth);
                self.emit("(%s, ".ptr as *const char, (&o.b[0]) as *const char);
                self.emit_expr(idxNode);
                if retref { self.emit_cstr("); }))".ptr as *const char); } else { self.emit_cstr("); })".ptr as *const char); }
                return;
            }
        }
        // plain / bounds-checked indexing
        let bty = unsafe (*self.cur_ast()).type_of(obj);
        let mut rbty = TYPE_NONE;
        if bty != TYPE_NONE { rbty = self.strip_ref_only(self.subst_resolve(bty)); }
        let mut rd2: i32 = 0;
        if bty != TYPE_NONE { rd2 = self.cg_ref_depth(self.subst_resolve(bty)); }
        if self.cg_slice_elem(rbty, null) {
            self.emit_slice_base(obj, rd2);
            self.emit_cstr(".ptr[__sc_bounds(".ptr as *const char);
            self.emit_expr(idxNode);
            self.emit_cstr(", ".ptr as *const char);
            self.emit_slice_base(obj, rd2);
            self.emit_cstr(".len)]".ptr as *const char);
            return;
        }
        let oty = *self.type_at(self.subst_resolve(unsafe (*self.cur_ast()).type_of(obj)));
        let mut lenN = NODE_NONE;
        if oty.kind == TypeKind::TYPE_ARRAY { lenN = self.array_length_of(obj); }
        let mut licnt: i64 = -1;
        if oty.kind == TypeKind::TYPE_ARRAY && lenN == NODE_NONE { licnt = self.array_literal_count(obj); }
        if lenN != NODE_NONE || licnt >= 0 {
            let mut iv: i64 = 0;
            let mut nv: i64 = licnt;
            let mut nconst = licnt >= 0;
            if lenN != NODE_NONE { nconst = self.cg_int_lit(lenN, (&mut nv) as *mut i64); }
            if self.cg_int_lit(idxNode, (&mut iv) as *mut i64) && nconst {
                if iv < 0 || iv >= nv { let sp = unsafe (*self.cur_ast()).at_const(idxNode).span; self.errors.emitf(sp.start, sp.end - sp.start, "index %ld is out of bounds for an array of length %ld".ptr as *const char, iv, nv); }
                self.emit_expr(obj);
                self.emit_cstr("[".ptr as *const char);
                self.emit_expr(idxNode);
                self.emit_cstr("]".ptr as *const char);
                return;
            }
            self.emit_expr(obj);
            self.emit_cstr("[__sc_bounds(".ptr as *const char);
            self.emit_expr(idxNode);
            self.emit_cstr(", ".ptr as *const char);
            if lenN != NODE_NONE { self.emit_expr(lenN); } else { self.emit("%ld".ptr as *const char, licnt); }
            self.emit_cstr(")]".ptr as *const char);
            return;
        }
        self.emit_expr(obj);
        self.emit_cstr("[".ptr as *const char);
        self.emit_expr(idxNode);
        self.emit_cstr("]".ptr as *const char);
    }
    fn emit_member(self: &mut Self, id: NodeId) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        if n.as_data.member.path {
            let mut d = unsafe (*self.cur_ast()).resolution_def(id);
            if d.node == NODE_NONE { d = unsafe (*self.cur_ast()).resolution_def(n.as_data.member.member); }
            let mut dk = NodeKind::NODE_NONE_KIND;
            if d.node != NODE_NONE { dk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind; }
            if d.node != NODE_NONE && dk == NodeKind::NODE_CONST && unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.is_extern {
                let mut ov = Buf256 {};
                if self.cg_symbol_override(d.module, d.node, (&mut ov.b[0]) as *mut char, 160) { self.emit_cstr((&ov.b[0]) as *const char); }
                else { self.emit_ident_mod(d.module, unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.name); }
            } else if d.node != NODE_NONE && dk == NodeKind::NODE_CONST && self.decl_is_toplevel(d.module, d.node) {
                let mut nm = Buf256 {};
                self.render_qualified(d.module, unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.name, (&mut nm.b[0]) as *mut char, 160);
                self.emit_cstr((&nm.b[0]) as *const char);
            } else if d.node != NODE_NONE && dk == NodeKind::NODE_FUNCTION {
                let mut nm = Buf256 {};
                self.render_qualified(d.module, unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.name, (&mut nm.b[0]) as *mut char, 160);
                self.emit_cstr((&nm.b[0]) as *const char);
            } else if d.node != NODE_NONE && dk == NodeKind::NODE_CONST {
                // associated const Type::NAME -> `<mod>__<Type>__NAME`
                let da = self.mod_ast(d.module);
                let ditems = unsafe (*da).at_const((*da).root).as_data.program.items;
                let mut target = DefId { module: 0, node: NODE_NONE };
                let mut di: u32 = 0;
                while di < ditems.len && target.node == NODE_NONE {
                    let did = unsafe ((*da).list(ditems))[di as usize];
                    let de = unsafe (*da).at_const(did);
                    if de.kind == NodeKind::NODE_EXTEND {
                        let dmis = de.as_data.extend_def.items;
                        let mut dj: u32 = 0;
                        while dj < dmis.len { if unsafe ((*da).list(dmis))[dj as usize] == d.node { target = unsafe (*da).resolution_def(de.as_data.extend_def.target_type); } dj = dj + 1; }
                    }
                    di = di + 1;
                }
                let mut nm = Buf512 {};
                let mut k = self.render_modpfx(d.module, (&mut nm.b[0]) as *mut char, 256);
                let mut bb: i32 = -1;
                if self.package != null && target.node != NODE_NONE { bb = unsafe (*self.package).builtin_of_decl(target.module, target.node); }
                if bb >= 0 { k = bappend((&mut nm.b[0]) as *mut char, 256, k, builtin_name(bb as BuiltinType)); }
                else if target.node != NODE_NONE {
                    k = k + render_ident_src(self.mod_src(target.module), self.name_span_in(target.module, unsafe (*self.mod_ast(target.module)).at_const(target.node).as_data.aggregate.name), unsafe (((&mut nm.b[0]) as *mut char) + k), 256 - k);
                }
                k = bappend((&mut nm.b[0]) as *mut char, 256, k, "__".ptr as *const char);
                render_ident_src(self.mod_src(d.module), unsafe (*da).at_const(unsafe (*da).at_const(d.node).as_data.const_def.name).as_data.name.text, unsafe (((&mut nm.b[0]) as *mut char) + k), 256 - k);
                self.emit_cstr((&nm.b[0]) as *const char);
            } else {
                self.emit_variant_value(d, unsafe (*self.cur_ast()).type_of(id));
            }
            return;
        }
        let ot = *self.type_at(unsafe (*self.cur_ast()).type_of(n.as_data.member.object));
        let ptr = ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_REFERENCE;
        self.emit_expr(n.as_data.member.object);
        if ptr { self.emit_cstr("->".ptr as *const char); } else { self.emit_cstr(".".ptr as *const char); }
        let msp = self.name_span(n.as_data.member.member);
        if unsafe self.source[msp.start as usize] >= '0' as u8 && unsafe self.source[msp.start as usize] <= '9' as u8 { self.emit_cstr("_".ptr as *const char); }
        self.emit_ident(msp);
    }
    fn emit_sizeof(self: &mut Self, id: NodeId) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let vnode = n.as_data.single.value;
        let d = unsafe (*self.cur_ast()).resolution_def(vnode);
        let mut dk = NodeKind::NODE_NONE_KIND;
        if d.node != NODE_NONE { dk = unsafe (*self.mod_ast(d.module)).at_const(d.node).kind; }
        let mut ty = Buf256 {};
        if d.node != NODE_NONE && (dk == NodeKind::NODE_LET || dk == NodeKind::NODE_PARAMETER || dk == NodeKind::NODE_FOR || dk == NodeKind::NODE_IDENTIFIER || dk == NodeKind::NODE_PATTERN_NAME || dk == NodeKind::NODE_CONST) {
            if n.kind == NodeKind::NODE_ALIGNOF {
                let mut vt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(vnode));
                let mut y = self.type_at(vt);
                while y.kind == TypeKind::TYPE_ARRAY { vt = y.as_data.arr.elem; y = self.type_at(vt); }
                self.render_type_id(vt, "".ptr as *const char, (&mut ty.b[0]) as *mut char, 256);
            } else if dk == NodeKind::NODE_CONST && (!self.mangle || self.decl_is_toplevel(d.module, d.node)) {
                self.render_qualified(d.module, unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def.name, (&mut ty.b[0]) as *mut char, 256);
            } else {
                self.render_ident(self.cg_decl_name_span(d.node), (&mut ty.b[0]) as *mut char, 256);
            }
        } else {
            self.render_type_node(vnode, "".ptr as *const char, (&mut ty.b[0]) as *mut char, 256);
        }
        if n.kind == NodeKind::NODE_ALIGNOF { self.emit("_Alignof(%s)".ptr as *const char, (&ty.b[0]) as *const char); }
        else { self.emit("sizeof(%s)".ptr as *const char, (&ty.b[0]) as *const char); }
    }
    fn emit_loop_expr(self: &mut Self, id: NodeId) void {
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
        self.emit_cstr("({ ".ptr as *const char);
        if has_val && le >= 0 {
            let mut vn = Buf32 {};
            unsafe stdio::snprintf((&mut vn.b[0]) as *mut char, 32, "__lv%u".ptr as *const char, self.loop_stack[le as usize].seq);
            let mut decl = Buf256 {};
            self.render_type_id(ty, (&vn.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 256);
            self.emit("%s; ".ptr as *const char, (&decl.b[0]) as *const char);
        }
        self.emit_cstr("for (;;) ".ptr as *const char);
        self.pending_cnt = (le + 1) as u32;
        self.emit_block(n.as_data.while_stmt.body);
        if le >= 0 && self.loop_stack[le as usize].used_brk { self.emit(" __brk%u:;".ptr as *const char, self.loop_stack[le as usize].seq); }
        if has_val && le >= 0 { self.emit(" __lv%u; })".ptr as *const char, self.loop_stack[le as usize].seq); } else { self.emit_cstr(" })".ptr as *const char); }
        self.cg_loop_pop(le);
        self.loop_defer_base = saved_ldb;
    }
    fn cg_stmt_diverges(self: &Self, id: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(id);
        if n.kind == NodeKind::NODE_RETURN || n.kind == NodeKind::NODE_BREAK || n.kind == NodeKind::NODE_CONTINUE { return true; }
        if n.kind == NodeKind::NODE_BLOCK {
            let s = n.as_data.block.statements;
            return s.len > 0 && self.cg_stmt_diverges(unsafe ((*self.cur_ast()).list(s))[(s.len - 1) as usize]);
        }
        if n.kind == NodeKind::NODE_IF {
            return n.as_data.if_stmt.else_branch != NODE_NONE && self.cg_stmt_diverges(n.as_data.if_stmt.then_branch) && self.cg_stmt_diverges(n.as_data.if_stmt.else_branch);
        }
        return false;
    }
    fn cg_loop_push(self: &mut Self, node: NodeId, is_expr: bool) i32 {
        if self.nloops >= 32 { return -1; }
        let k = self.nloops;
        self.loop_stack[k as usize] = CgLoop { node: node, defer_base: self.defer_top, seq: self.label_seq, used_brk: false, used_cnt: false, is_expr: is_expr };
        self.label_seq = self.label_seq + 1;
        self.nloops = k + 1;
        return k as i32;
    }
    fn cg_loop_pop(self: &mut Self, le: i32) void { if le >= 0 { self.nloops = le as u32; } }
    fn cg_loop_find(self: &Self, node: NodeId) i32 {
        let mut i = self.nloops;
        while i > 0 { if self.loop_stack[(i - 1) as usize].node == node { return (i - 1) as i32; } i = i - 1; }
        return -1;
    }
    fn cg_loop_brk_label(self: &mut Self, le: i32) void {
        if le >= 0 && self.loop_stack[le as usize].used_brk { self.emit_indent(); self.emit("__brk%u:;\n".ptr as *const char, self.loop_stack[le as usize].seq); }
    }
    fn emit_defers_to(self: &mut Self, base: u32) void {
        let mut i = self.defer_top;
        while i > base {
            i = i - 1;
            self.emit_indent();
            if self.defer_kind[i as usize] == 1 { self.emit_auto_free(self.defer_stack[i as usize]); }
            else { self.emit_expr_stmt(self.defer_stack[i as usize]); }
        }
    }
    fn emit_block_from(self: &mut Self, id: NodeId, dbase: u32) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let cnt_hook = self.pending_cnt;
        self.pending_cnt = 0;
        self.emit_cstr("{\n".ptr as *const char);
        self.depth = self.depth + 1;
        let mut i: u32 = 0;
        while i < self.nparam_flags {
            let mut fl = Buf32 {};
            cg_move_flag((&mut fl.b[0]) as *mut char, 32, self.param_flags[i as usize]);
            self.emit_indent();
            self.emit("bool %s = false;\n".ptr as *const char, (&fl.b[0]) as *const char);
            i = i + 1;
        }
        self.nparam_flags = 0;
        i = 0;
        while i < self.nunused_params {
            let mut pn = Buf128 {};
            self.render_ident(self.name_span(unsafe (*self.cur_ast()).at_const(self.unused_params[i as usize]).as_data.parameter.name), (&mut pn.b[0]) as *mut char, 128);
            if pn.b[0] == '_' as char && pn.b[1] == 0 as char { unsafe stdio::snprintf((&mut pn.b[0]) as *mut char, 128, "__sc_u%u".ptr as *const char, self.unused_params[i as usize]); }
            self.emit_indent();
            self.emit("(void)%s;\n".ptr as *const char, (&pn.b[0]) as *const char);
            i = i + 1;
        }
        self.nunused_params = 0;
        let stmts = n.as_data.block.statements;
        i = 0;
        while i < stmts.len { self.emit_indent(); self.emit_stmt(unsafe ((*self.cur_ast()).list(stmts))[i as usize]); i = i + 1; }
        let mut diverges = false;
        if stmts.len > 0 { diverges = self.cg_stmt_diverges(unsafe ((*self.cur_ast()).list(stmts))[(stmts.len - 1) as usize]); }
        if !diverges { self.emit_defers_to(dbase); }
        self.defer_top = dbase;
        if cnt_hook != 0 && self.loop_stack[(cnt_hook - 1) as usize].used_cnt {
            self.emit_indent();
            self.emit("__cnt%u:;\n".ptr as *const char, self.loop_stack[(cnt_hook - 1) as usize].seq);
        }
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("}".ptr as *const char);
    }
    fn emits_own_parens(self: &mut Self, id: NodeId) bool {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        if self.ceval() != null && unsafe (*self.ceval()).eval(self.cur_module(), id).kind != ce::CONST_NONE { return false; }
        if n.kind == NodeKind::NODE_BINARY || n.kind == NodeKind::NODE_CAST { return true; }
        if n.kind == NodeKind::NODE_UNARY {
            if n.as_data.unary.op != TokenType::Move && n.as_data.unary.op != TokenType::Unsafe { return true; }
            return self.emits_own_parens(n.as_data.unary.operand);
        }
        if n.kind == NodeKind::NODE_NEW { return n.as_data.new_expr.initializer == NODE_NONE; }
        return false;
    }
    fn emit_condition(self: &mut Self, id: NodeId) void {
        if self.emits_own_parens(id) { self.emit_expr(id); }
        else { self.emit_cstr("(".ptr as *const char); self.emit_expr(id); self.emit_cstr(")".ptr as *const char); }
    }
    fn emit_if(self: &mut Self, id: NodeId) void {
        let ifd = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt;
        self.emit_cstr("if ".ptr as *const char);
        self.emit_condition(ifd.condition);
        self.emit_cstr(" ".ptr as *const char);
        self.emit_block(ifd.then_branch);
        if ifd.else_branch != NODE_NONE {
            self.emit_cstr(" else ".ptr as *const char);
            if unsafe (*self.cur_ast()).at_const(ifd.else_branch).kind == NodeKind::NODE_IF { self.emit_if(ifd.else_branch); }
            else { self.emit_block(ifd.else_branch); }
        }
    }
    fn emit_block_value(self: &mut Self, id: NodeId, result: *const char) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        self.emit_cstr("{\n".ptr as *const char);
        self.depth = self.depth + 1;
        let dbase = self.defer_top;
        let stmts = n.as_data.block.statements;
        let mut i: u32 = 0;
        while i < stmts.len {
            let sid = unsafe ((*self.cur_ast()).list(stmts))[i as usize];
            let s = *unsafe (*self.cur_ast()).at_const(sid);
            self.emit_indent();
            if i + 1 == stmts.len && s.kind == NodeKind::NODE_EXPRESSION_STATEMENT {
                let vt = unsafe (*self.cur_ast()).type_of(s.as_data.single.value);
                if vt == TYPE_NONE || self.type_at(vt).kind != TypeKind::TYPE_NEVER { self.emit("%s = ".ptr as *const char, result); }
                self.emit_expr(s.as_data.single.value);
                self.emit_cstr(";\n".ptr as *const char);
            } else { self.emit_stmt(sid); }
            i = i + 1;
        }
        self.emit_defers_to(dbase);
        self.defer_top = dbase;
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("}".ptr as *const char);
    }
    fn emit_if_value(self: &mut Self, id: NodeId, result: *const char) void {
        let ifd = unsafe (*self.cur_ast()).at_const(id).as_data.if_stmt;
        self.emit_cstr("if ".ptr as *const char);
        self.emit_condition(ifd.condition);
        self.emit_cstr(" ".ptr as *const char);
        self.emit_block_value(ifd.then_branch, result);
        if ifd.else_branch != NODE_NONE {
            self.emit_cstr(" else ".ptr as *const char);
            if unsafe (*self.cur_ast()).at_const(ifd.else_branch).kind == NodeKind::NODE_IF { self.emit_if_value(ifd.else_branch, result); }
            else { self.emit_block_value(ifd.else_branch, result); }
        }
    }
}

extend Codegen {
    fn emit_prefixed(self: &mut Self, obj: NodeId, prefix: *const char) void {
        let k = unsafe (*self.cur_ast()).at_const(obj).kind;
        let primary = k == NodeKind::NODE_IDENTIFIER || k == NodeKind::NODE_MEMBER || k == NodeKind::NODE_INDEX || k == NodeKind::NODE_CALL;
        self.emit_cstr(prefix);
        if primary { self.emit_expr(obj); }
        else { self.emit_cstr("(".ptr as *const char); self.emit_expr(obj); self.emit_cstr(")".ptr as *const char); }
    }
    fn emit_slice_base(self: &mut Self, obj: NodeId, rd: i32) void {
        if rd == 0 { self.emit_expr(obj); return; }
        self.emit_cstr("(".ptr as *const char);
        self.emit_prefixed(obj, ref_derefs(rd + 1));
        self.emit_cstr(")".ptr as *const char);
    }
    fn render_enum_cname(self: &mut Self, v: DefId, en: NodeId, enum_ty: TypeId, buf: *mut char, cap: usize) void {
        if enum_ty != TYPE_NONE && self.type_at(enum_ty).kind == TypeKind::TYPE_INSTANCE {
            self.inst_name(unsafe (*self.cur_ast()).instance(self.type_at(enum_ty).as_data.inst), buf, cap);
        } else {
            self.render_qualified(v.module, unsafe (*self.mod_ast(v.module)).at_const(en).as_data.aggregate.name, buf, cap);
        }
    }
    fn emit_variant_value(self: &mut Self, v: DefId, enum_ty: TypeId) void {
        let en = self.enclosing_enum_in(v.module, v.node);
        if en == NODE_NONE { self.emit_cstr("0".ptr as *const char); return; }
        if !self.aggregate_has_payload_in(v.module, en) { self.emit_tag_mod(v.module, en, v.node); return; }
        let mut enm = Buf256 {};
        self.render_enum_cname(v, en, enum_ty, (&mut enm.b[0]) as *mut char, 200);
        self.emit("(%s){ .tag = ".ptr as *const char, (&enm.b[0]) as *const char);
        self.emit_tag_mod(v.module, en, v.node);
        self.emit_cstr(" }".ptr as *const char);
    }
    fn emit_variant_construct(self: &mut Self, v: DefId, args: NodeList, aids: *const NodeId, enum_ty: TypeId) void {
        let en = self.enclosing_enum_in(v.module, v.node);
        if en == NODE_NONE || !self.aggregate_has_payload_in(v.module, en) { self.emit_variant_value(v, enum_ty); return; }
        let mut enm = Buf256 {};
        let mut vn = Buf128 {};
        self.render_enum_cname(v, en, enum_ty, (&mut enm.b[0]) as *mut char, 200);
        self.render_variant_name(v.module, v.node, (&mut vn.b[0]) as *mut char, 128);
        self.emit("(%s){ .tag = ".ptr as *const char, (&enm.b[0]) as *const char);
        self.emit_tag_mod(v.module, en, v.node);
        if args.len != 0 {
            self.emit(", .payload.%s = { ".ptr as *const char, (&vn.b[0]) as *const char);
            let mut i: u32 = 0;
            while i < args.len { if i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit_expr(unsafe aids[i as usize]); i = i + 1; }
            self.emit_cstr(" }".ptr as *const char);
        }
        self.emit_cstr(" }".ptr as *const char);
    }
    fn emit_method_targs(self: &mut Self, callId: NodeId, md: DefId) void {
        let mn = unsafe (*self.mod_ast(md.module)).at_const(md.node);
        if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.generics.len == 0 { return; }
        let mu = unsafe (*self.cur_ast()).type_args(callId);
        let mut i: u8 = 0;
        while mu != null && i < unsafe (*mu).n {
            let mut e = Buf256 {};
            self.mangle_type(self.subst_resolve(unsafe (*mu).args[i as usize]), (&mut e.b[0]) as *mut char, 176);
            self.emit("__%s".ptr as *const char, (&e.b[0]) as *const char);
            i = i + 1;
        }
    }
    fn emit_op_method(self: &mut Self, bt: Ty, om: ModuleId, od: NodeId, mth: DefId) void {
        if bt.kind == TypeKind::TYPE_INSTANCE {
            let mut inm = Buf256 {};
            self.inst_name(unsafe (*self.cur_ast()).instance(bt.as_data.inst), (&mut inm.b[0]) as *mut char, 200);
            self.emit_cstr((&inm.b[0]) as *const char);
            self.emit_paste();
            self.emit_cstr("__".ptr as *const char);
        } else {
            let mut pfx = Buf64 {};
            self.render_modpfx(mth.module, (&mut pfx.b[0]) as *mut char, 64);
            self.emit_cstr((&pfx.b[0]) as *const char);
            self.emit_ident_mod(om, unsafe (*self.mod_ast(om)).at_const(od).as_data.aggregate.name);
            self.emit_cstr("__".ptr as *const char);
        }
        self.emit_ident_mod(mth.module, unsafe (*self.mod_ast(mth.module)).at_const(mth.node).as_data.function.name);
    }
    fn emit_cmp_overload(self: &mut Self, id: NodeId) bool {
        let bd = unsafe (*self.cur_ast()).at_const(id).as_data.binary;
        let op = bd.op;
        if op != TokenType::EqualEqual && op != TokenType::BangEqual && op != TokenType::LessThan && op != TokenType::LessThanEqual && op != TokenType::GreaterThan && op != TokenType::GreaterThanEqual { return false; }
        let lt0 = unsafe (*self.cur_ast()).type_of(bd.left);
        if lt0 == TYPE_NONE { return false; }
        let lt = self.strip_ref_only(self.subst_resolve(lt0));
        if lt == TYPE_NONE { return false; }
        let bt = *self.type_at(lt);
        if bt.kind != TypeKind::TYPE_STRUCT && bt.kind != TypeKind::TYPE_INSTANCE { return false; }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if bt.kind == TypeKind::TYPE_INSTANCE { let it = *unsafe (*self.cur_ast()).instance(bt.as_data.inst); om = it.module; od = it.decl; }
        else { om = bt.module; od = bt.as_data.decl; }
        let ord = op != TokenType::EqualEqual && op != TokenType::BangEqual;
        let mut mm = "eq".ptr as *const char;
        if ord { mm = "cmp".ptr as *const char; }
        let m = self.cg_find_method_cstr(om, od, mm);
        if m.node == NODE_NONE { return false; }
        let rt0 = unsafe (*self.cur_ast()).type_of(bd.right);
        let dl = self.cg_ref_depth(self.subst_resolve(unsafe (*self.cur_ast()).type_of(bd.left)));
        let mut dr: i32 = 0;
        if rt0 != TYPE_NONE { dr = self.cg_ref_depth(self.subst_resolve(rt0)); }
        let mut lb = Buf32 {};
        let mut rb = Buf32 {};
        self.fresh((&mut lb.b[0]) as *mut char, 32);
        self.fresh((&mut rb.b[0]) as *mut char, 32);
        self.emit("(({ __auto_type %s = ".ptr as *const char, (&lb.b[0]) as *const char);
        self.emit_expr(bd.left);
        self.emit("; __auto_type %s = ".ptr as *const char, (&rb.b[0]) as *const char);
        self.emit_expr(bd.right);
        self.emit_cstr("; ".ptr as *const char);
        if op == TokenType::BangEqual { self.emit_cstr("!".ptr as *const char); }
        if ord { self.emit_cstr("(".ptr as *const char); }
        self.emit_op_method(bt, om, od, m);
        let mut lp = "&".ptr as *const char;
        if dl != 0 { lp = ref_derefs(dl); }
        let mut rp = "&".ptr as *const char;
        if dr != 0 { rp = ref_derefs(dr); }
        self.emit("(%s%s, %s%s)".ptr as *const char, lp, (&lb.b[0]) as *const char, rp, (&rb.b[0]) as *const char);
        if ord { self.emit(" %s 0)".ptr as *const char, c_op(op)); }
        self.emit_cstr("; }))".ptr as *const char);
        return true;
    }

    fn emit_ident_ref(self: &mut Self, id: NodeId) void {
        let d = unsafe (*self.cur_ast()).resolution_def(id);
        let nt = unsafe (*self.cur_ast()).at_const(id).as_data.name.text;
        if d.node != NODE_NONE && d.module == self.cur_module() {
            let mut is_mut = false;
            if self.cg_env_capture(d.node, (&mut is_mut) as *mut bool) >= 0 {
                if is_mut { self.emit_cstr("(*__env->".ptr as *const char); } else { self.emit_cstr("__env->".ptr as *const char); }
                self.emit_ident(nt);
                if is_mut { self.emit_cstr(")".ptr as *const char); }
                return;
            }
        }
        if d.node != NODE_NONE {
            let da = self.mod_ast(d.module);
            let dn = *unsafe (*da).at_const(d.node);
            if dn.kind == NodeKind::NODE_VARIANT {
                let en = self.enclosing_enum_in(d.module, d.node);
                if en != NODE_NONE { self.emit_tag_mod(d.module, en, d.node); return; }
            }
            if dn.kind == NodeKind::NODE_FUNCTION {
                let mut ov = Buf256 {};
                if self.cg_symbol_override(d.module, d.node, (&mut ov.b[0]) as *mut char, 160) { self.emit_cstr((&ov.b[0]) as *const char); return; }
            }
            if dn.kind == NodeKind::NODE_FUNCTION && dn.as_data.function.body != NODE_NONE && !span_is(self.mod_src(d.module), unsafe (*da).at_const(dn.as_data.function.name).as_data.name.text, "main".ptr as *const char) {
                let mut nm = Buf256 {};
                self.render_qualified(d.module, dn.as_data.function.name, (&mut nm.b[0]) as *mut char, 160);
                self.emit_cstr((&nm.b[0]) as *const char);
                return;
            }
            if dn.kind == NodeKind::NODE_CONST && dn.as_data.const_def.is_extern {
                let mut ov = Buf256 {};
                if self.cg_symbol_override(d.module, d.node, (&mut ov.b[0]) as *mut char, 160) { self.emit_cstr((&ov.b[0]) as *const char); }
                else { self.emit_ident_mod(d.module, dn.as_data.const_def.name); }
                return;
            }
            if dn.kind == NodeKind::NODE_CONST && (!self.mangle || self.decl_is_toplevel(d.module, d.node)) {
                let mut nm = Buf256 {};
                self.render_qualified(d.module, dn.as_data.const_def.name, (&mut nm.b[0]) as *mut char, 160);
                self.emit_cstr((&nm.b[0]) as *const char);
                return;
            }
        }
        self.emit_ident(nt);
    }

    fn emit_array_braces(self: &mut Self, id: NodeId) void {
        let elements = unsafe (*self.cur_ast()).at_const(id).as_data.array_literal.elements;
        self.emit_cstr("{ ".ptr as *const char);
        let mut i: u32 = 0;
        while i < elements.len {
            if i != 0 { self.emit_cstr(", ".ptr as *const char); }
            let eid = unsafe ((*self.cur_ast()).list(elements))[i as usize];
            let el = unsafe (*self.cur_ast()).at_const(eid);
            if el.kind == NodeKind::NODE_FIELD_INITIALIZER {
                self.emit_cstr("[".ptr as *const char);
                let nameNode = el.as_data.field_initializer.name;
                let valNode = el.as_data.field_initializer.value;
                let mut folded = false;
                if self.ceval() != null {
                    let iv = unsafe (*self.ceval()).eval(self.cur_module(), nameNode);
                    if iv.kind == ce::CONST_INT { self.emit("%lld".ptr as *const char, iv.as_data.i); folded = true; }
                }
                if !folded { self.emit_expr(nameNode); }
                self.emit_cstr("] = ".ptr as *const char);
                if unsafe (*self.cur_ast()).at_const(valNode).kind == NodeKind::NODE_ARRAY_LITERAL { self.emit_array_braces(valNode); }
                else { self.emit_expr(valNode); }
            } else if el.kind == NodeKind::NODE_ARRAY_LITERAL {
                self.emit_array_braces(eid);
            } else {
                self.emit_expr(eid);
            }
            i = i + 1;
        }
        self.emit_cstr(" }".ptr as *const char);
    }

    fn emit_expr(self: &mut Self, id: NodeId) void {
        if id == NODE_NONE { return; }
        if id != self.slice_raw && self.emit_slice_coercion(id) { return; }
        if id != self.dyn_raw && self.emit_dyn_coercion(id) { return; }
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let nk = n.kind;
        if self.ceval() != null && (nk == NodeKind::NODE_BINARY || nk == NodeKind::NODE_UNARY || nk == NodeKind::NODE_CAST || nk == NodeKind::NODE_CALL || nk == NodeKind::NODE_SIZEOF || nk == NodeKind::NODE_ALIGNOF) {
            let v = unsafe (*self.ceval()).eval(self.cur_module(), id);
            if v.kind == ce::CONST_BOOL { if v.as_data.i != 0 { self.emit_cstr("true".ptr as *const char); } else { self.emit_cstr("false".ptr as *const char); } return; }
            if v.kind == ce::CONST_INT {
                let mut vb = BuiltinType::BT_COUNT;
                if v.ty != TYPE_NONE && self.type_at(v.ty).kind == TypeKind::TYPE_BUILTIN { vb = self.type_at(v.ty).as_data.builtin; }
                let uns = vb == BuiltinType::BT_U8 || vb == BuiltinType::BT_U16 || vb == BuiltinType::BT_U32 || vb == BuiltinType::BT_U64 || vb == BuiltinType::BT_USIZE;
                if uns {
                    if vb == BuiltinType::BT_U64 || vb == BuiltinType::BT_USIZE { self.emit("%lluULL".ptr as *const char, v.as_data.i as u64); } else { self.emit("%lluU".ptr as *const char, v.as_data.i as u64); }
                } else if v.as_data.i == (-9223372036854775807i64 - 1) {
                    self.emit_cstr("(-9223372036854775807ll - 1)".ptr as *const char);
                } else if vb == BuiltinType::BT_I64 || vb == BuiltinType::BT_ISIZE {
                    self.emit("%lldLL".ptr as *const char, v.as_data.i);
                } else if v.as_data.i > 0x7FFFFFFFi64 || v.as_data.i < (-0x80000000i64) {
                    self.emit("%lldll".ptr as *const char, v.as_data.i);
                } else {
                    self.emit("%lld".ptr as *const char, v.as_data.i);
                }
                return;
            }
            if v.kind == ce::CONST_FLOAT {
                let mut f32t = false;
                if v.ty != TYPE_NONE && self.type_at(v.ty).kind == TypeKind::TYPE_BUILTIN && self.type_at(v.ty).as_data.builtin == BuiltinType::BT_F32 { f32t = true; }
                let mut fb = Buf64 {};
                unsafe stdio::snprintf((&mut fb.b[0]) as *mut char, 48, "%.17g".ptr as *const char, v.as_data.f);
                let fl = unsafe cstring::strlen((&fb.b[0]) as *const char);
                let has = unsafe cstring::memchr((&fb.b[0]) as *const void, '.' as i32, fl) != null || unsafe cstring::memchr((&fb.b[0]) as *const void, 'e' as i32, fl) != null || unsafe cstring::memchr((&fb.b[0]) as *const void, 'E' as i32, fl) != null;
                if !has { bappend((&mut fb.b[0]) as *mut char, 48, fl, ".0".ptr as *const char); }
                if f32t { self.emit("%sf".ptr as *const char, (&fb.b[0]) as *const char); } else { self.emit("%s".ptr as *const char, (&fb.b[0]) as *const char); }
                return;
            }
        }
        if nk == NodeKind::NODE_LITERAL { self.emit_literal(id); }
        else if nk == NodeKind::NODE_IDENTIFIER {
            if self.cg_is_cond_site(id) {
                let mut fl = Buf32 {};
                cg_move_flag((&mut fl.b[0]) as *mut char, 32, unsafe (*self.cur_ast()).resolution_def(id).node);
                self.emit("(%s = true, ".ptr as *const char, (&fl.b[0]) as *const char);
                self.emit_ident_ref(id);
                self.emit_cstr(")".ptr as *const char);
            } else { self.emit_ident_ref(id); }
        }
        else if nk == NodeKind::NODE_UNARY {
            let op = n.as_data.unary.op;
            let operand = n.as_data.unary.operand;
            if op == TokenType::Question { self.emit_try(id); }
            else if op == TokenType::Move || op == TokenType::Unsafe { self.emit_expr(operand); }
            else if op == TokenType::Ampersand && !self.is_lvalue(operand) && self.type_at(unsafe (*self.cur_ast()).type_of(operand)).kind == TypeKind::TYPE_BUILTIN {
                let mut ty = Buf256 {};
                self.render_type_id(unsafe (*self.cur_ast()).type_of(operand), "".ptr as *const char, (&mut ty.b[0]) as *mut char, 128);
                self.emit("(&(%s){".ptr as *const char, (&ty.b[0]) as *const char);
                self.emit_expr(operand);
                self.emit_cstr("})".ptr as *const char);
            } else {
                self.emit("(%s".ptr as *const char, c_op(op));
                self.emit_expr(operand);
                self.emit_cstr(")".ptr as *const char);
            }
        }
        else if nk == NodeKind::NODE_BINARY {
            if self.emit_cmp_overload(id) { return; }
            if self.emit_arith_overload(id) { return; }
            let bd = n.as_data.binary;
            if bd.op == TokenType::Percent {
                let lt = self.type_at(unsafe (*self.cur_ast()).type_of(bd.left));
                if lt.kind == TypeKind::TYPE_BUILTIN && (lt.as_data.builtin == BuiltinType::BT_F32 || lt.as_data.builtin == BuiltinType::BT_F64) {
                    let mut fn2 = "fmod".ptr as *const char;
                    if lt.as_data.builtin == BuiltinType::BT_F32 { fn2 = "fmodf".ptr as *const char; }
                    self.emit("%s(".ptr as *const char, fn2);
                    self.emit_expr(bd.left);
                    self.emit_cstr(", ".ptr as *const char);
                    self.emit_expr(bd.right);
                    self.emit_cstr(")".ptr as *const char);
                    return;
                }
            }
            if self.emit_cg_checked_arith(id) { return; }
            self.emit_cstr("(".ptr as *const char);
            self.emit_expr(bd.left);
            self.emit(" %s ".ptr as *const char, c_op(bd.op));
            self.emit_expr(bd.right);
            self.emit_cstr(")".ptr as *const char);
        }
        else if nk == NodeKind::NODE_ASSIGNMENT { self.emit_assignment(id); }
        else if nk == NodeKind::NODE_CALL {
            let ct = unsafe (*self.cur_ast()).type_of(id);
            let arr_ret = ct != TYPE_NONE && self.type_at(ct).kind == TypeKind::TYPE_ARRAY;
            let cn = unsafe (*self.cur_ast()).at_const(n.as_data.call.callee);
            let mut freeflag = Buf32 {};
            freeflag.b[0] = 0 as char;
            if cn.kind == NodeKind::NODE_MEMBER && !cn.as_data.member.path && cn.as_data.member.object != NODE_NONE && unsafe (*self.cur_ast()).at_const(cn.as_data.member.object).kind == NodeKind::NODE_IDENTIFIER && span_is(self.mod_src(self.cur_module()), unsafe (*self.cur_ast()).at_const(cn.as_data.member.member).as_data.name.text, "free".ptr as *const char) {
                let rd = unsafe (*self.cur_ast()).resolution_def(cn.as_data.member.object);
                if rd.module == self.cur_module() && self.cg_is_cond_moved(rd.node) {
                    cg_move_flag((&mut freeflag.b[0]) as *mut char, 32, rd.node);
                    self.emit("(%s = true, ".ptr as *const char, (&freeflag.b[0]) as *const char);
                }
            }
            if arr_ret { self.emit_cstr("(".ptr as *const char); }
            self.emit_call(id);
            if arr_ret { self.emit_cstr(")._".ptr as *const char); }
            if freeflag.b[0] != 0 as char { self.emit_cstr(")".ptr as *const char); }
        }
        else if nk == NodeKind::NODE_CLOSURE {
            let mut nm = Buf256 {};
            self.closure_name(id, (&mut nm.b[0]) as *mut char, 200);
            if n.as_data.closure.captures.len != 0 {
                let mut wrapped = false;
                if self.cg_is_cond_site(id) {
                    let caps = n.as_data.closure.captures;
                    let mut i: u32 = 0;
                    while i < caps.len {
                        let cid = unsafe ((*self.cur_ast()).list(caps))[i as usize];
                        if ((n.as_data.closure.mut_caps >> (i as u64)) & 1u64) != 0 || !self.cg_is_cond_moved(cid) { i = i + 1; continue; }
                        let mut fl = Buf32 {};
                        cg_move_flag((&mut fl.b[0]) as *mut char, 32, cid);
                        if wrapped { self.emit("%s = true, ".ptr as *const char, (&fl.b[0]) as *const char); } else { self.emit("(%s = true, ".ptr as *const char, (&fl.b[0]) as *const char); }
                        wrapped = true;
                        i = i + 1;
                    }
                }
                self.emit("((%s_env){ ".ptr as *const char, (&nm.b[0]) as *const char);
                let caps = n.as_data.closure.captures;
                let mut i: u32 = 0;
                while i < caps.len { if i != 0 { self.emit_cstr(", ".ptr as *const char); } self.emit_capture_init(id, i); i = i + 1; }
                self.emit_cstr(" })".ptr as *const char);
                if wrapped { self.emit_cstr(")".ptr as *const char); }
            } else {
                self.emit_cstr((&nm.b[0]) as *const char);
            }
        }
        else if nk == NodeKind::NODE_TUPLE {
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(id), "".ptr as *const char, (&mut styp.b[0]) as *mut char, 200);
            self.emit("(%s){ ".ptr as *const char, (&styp.b[0]) as *const char);
            let elems = n.as_data.array_literal.elements;
            let mut i: u32 = 0;
            while i < elems.len {
                if i != 0 { self.emit(", ._%u = ".ptr as *const char, i); } else { self.emit("._%u = ".ptr as *const char, i); }
                self.emit_expr(unsafe ((*self.cur_ast()).list(elems))[i as usize]);
                i = i + 1;
            }
            self.emit_cstr(" }".ptr as *const char);
        }
        else if nk == NodeKind::NODE_RANGE {
            let mut styp = Buf256 {};
            self.render_type_id(unsafe (*self.cur_ast()).type_of(id), "".ptr as *const char, (&mut styp.b[0]) as *mut char, 200);
            self.emit("(%s){ .start = ".ptr as *const char, (&styp.b[0]) as *const char);
            self.emit_expr(n.as_data.pattern_range.start);
            self.emit_cstr(", .end = ".ptr as *const char);
            self.emit_expr(n.as_data.pattern_range.end);
            let mut incl = "false".ptr as *const char;
            if n.as_data.pattern_range.inclusive { incl = "true".ptr as *const char; }
            self.emit(", .inclusive = %s }".ptr as *const char, incl);
        }
        else if nk == NodeKind::NODE_INDEX { self.emit_index(id); }
        else if nk == NodeKind::NODE_MEMBER { self.emit_member(id); }
        else if nk == NodeKind::NODE_CAST {
            let mut t = Buf256 {};
            self.render_type_node(n.as_data.cast.ty, "".ptr as *const char, (&mut t.b[0]) as *mut char, 256);
            self.emit("((%s)".ptr as *const char, (&t.b[0]) as *const char);
            self.emit_expr(n.as_data.cast.expression);
            self.emit_cstr(")".ptr as *const char);
        }
        else if nk == NodeKind::NODE_GENERIC_SPECIALIZATION { self.emit_expr(n.as_data.specialization.expression); }
        else if nk == NodeKind::NODE_SIZEOF || nk == NodeKind::NODE_ALIGNOF { self.emit_sizeof(id); }
        else if nk == NodeKind::NODE_VA_EXPR {
            let vo = n.as_data.va_op;
            if vo.op == VA_ARG {
                let mut ty = Buf256 {};
                self.render_type_node(vo.extra, "".ptr as *const char, (&mut ty.b[0]) as *mut char, 256);
                self.emit_cstr("va_arg(".ptr as *const char);
                self.emit_expr(vo.ap);
                self.emit(", %s)".ptr as *const char, (&ty.b[0]) as *const char);
            } else if vo.op == VA_START {
                self.emit_cstr("va_start(".ptr as *const char);
                self.emit_expr(vo.ap);
                self.emit_cstr(", ".ptr as *const char);
                self.emit_expr(vo.extra);
                self.emit_cstr(")".ptr as *const char);
            } else {
                self.emit_cstr("va_end(".ptr as *const char);
                self.emit_expr(vo.ap);
                self.emit_cstr(")".ptr as *const char);
            }
        }
        else if nk == NodeKind::NODE_STRUCT_INITIALIZER { self.emit_struct_init(id); }
        else if nk == NodeKind::NODE_NEW { self.emit_new(id); }
        else if nk == NodeKind::NODE_ARRAY_LITERAL {
            let at = unsafe (*self.cur_ast()).type_of(id);
            let mut et = Buf256 {};
            if at != TYPE_NONE { let ae = self.type_at(at).as_data.elem; self.render_type_id(ae, "".ptr as *const char, (&mut et.b[0]) as *mut char, 256); }
            else { unsafe stdio::snprintf((&mut et.b[0]) as *mut char, 256, "%s".ptr as *const char, "int".ptr as *const char); }
            self.emit("(%s[%u])".ptr as *const char, (&et.b[0]) as *const char, n.as_data.array_literal.elements.len);
            self.emit_array_braces(id);
        }
        else if nk == NodeKind::NODE_MATCH { self.emit_match_expr(id); }
        else if nk == NodeKind::NODE_IF { self.emit_if_expr(id); }
        else if nk == NodeKind::NODE_WHILE { self.emit_loop_expr(id); }
        else if nk == NodeKind::NODE_BLOCK {
            self.emit_cstr("(".ptr as *const char);
            self.emit_cstr("{\n".ptr as *const char);
            self.depth = self.depth + 1;
            let stmts = n.as_data.block.statements;
            let saved = self.no_temp_free;
            let mut i: u32 = 0;
            while i < stmts.len {
                self.no_temp_free = i + 1 == stmts.len;
                self.emit_indent();
                self.emit_stmt(unsafe ((*self.cur_ast()).list(stmts))[i as usize]);
                i = i + 1;
            }
            self.no_temp_free = saved;
            self.depth = self.depth - 1;
            self.emit_indent();
            self.emit_cstr("})".ptr as *const char);
        }
        else {
            self.errors.emitf(n.span.start, n.span.end - n.span.start, "codegen: unsupported expression".ptr as *const char);
        }
    }

    fn emit_literal(self: &mut Self, id: NodeId) void {
        let n = *unsafe (*self.cur_ast()).at_const(id);
        let s = n.as_data.literal.raw;
        let tt = n.as_data.literal.token_type;
        if tt == TokenType::True { self.emit_cstr("true".ptr as *const char); }
        else if tt == TokenType::False { self.emit_cstr("false".ptr as *const char); }
        else if tt == TokenType::Null { self.emit_cstr("NULL".ptr as *const char); }
        else if tt == TokenType::CharacterLiteral { self.emit_reescaped(s, true); }
        else if tt == TokenType::StringLiteral {
            let tid = unsafe (*self.cur_ast()).type_of(id);
            let mut isptr = false;
            if tid != TYPE_NONE && self.type_at(tid).kind == TypeKind::TYPE_POINTER { isptr = true; }
            if isptr {
                let pe = *self.type_at(self.type_at(tid).as_data.elem);
                if pe.kind == TypeKind::TYPE_BUILTIN && pe.as_data.builtin == BuiltinType::BT_U8 { self.emit_cstr("(const uint8_t *)".ptr as *const char); }
                self.emit_reescaped(s, false);
            } else {
                self.emit_cstr("(str){ (const uint8_t *)".ptr as *const char);
                self.emit_reescaped(s, false);
                self.emit_cstr(", sizeof(".ptr as *const char);
                self.emit_reescaped(s, false);
                self.emit_cstr(") - 1 }".ptr as *const char);
            }
        }
        else if tt == TokenType::ByteStringLiteral {
            let mut sn = Buf256 {};
            self.render_type_id(self.subst_resolve(unsafe (*self.cur_ast()).type_of(id)), "".ptr as *const char, (&mut sn.b[0]) as *mut char, 200);
            let bc = tok::Span { start: s.start + 1, end: s.end };
            self.emit("(%s){ .ptr = (const uint8_t *)".ptr as *const char, (&sn.b[0]) as *const char);
            self.emit_reescaped(bc, false);
            self.emit_cstr(", .len = sizeof(".ptr as *const char);
            self.emit_reescaped(bc, false);
            self.emit_cstr(") - 1 }".ptr as *const char);
        }
        else if tt == TokenType::ByteCharacterLiteral {
            self.emit_cstr("(uint8_t)".ptr as *const char);
            if s.end > s.start && unsafe self.source[s.start as usize] == 'b' as u8 { self.emit("%.*s".ptr as *const char, (s.end - s.start - 1) as i32, src_at(self.source, s.start + 1)); }
            else { self.emit_span(s); }
        }
        else if tt == TokenType::RawStringLiteral {
            let rc = raw_string_content(self.source, s);
            let tid = unsafe (*self.cur_ast()).type_of(id);
            let mut isptr = false;
            if tid != TYPE_NONE && self.type_at(tid).kind == TypeKind::TYPE_POINTER { isptr = true; }
            if isptr {
                let pe = *self.type_at(self.type_at(tid).as_data.elem);
                if pe.kind == TypeKind::TYPE_BUILTIN && pe.as_data.builtin == BuiltinType::BT_U8 { self.emit_cstr("(const uint8_t *)".ptr as *const char); }
                self.emit_raw_c_string(rc);
            } else {
                self.emit_cstr("(str){ (const uint8_t *)".ptr as *const char);
                self.emit_raw_c_string(rc);
                self.emit(", %u }".ptr as *const char, rc.end - rc.start);
            }
        }
        else {
            let lt = self.subst_resolve(unsafe (*self.cur_ast()).type_of(id));
            let mut b = BuiltinType::BT_COUNT;
            if lt != TYPE_NONE && self.type_at(lt).kind == TypeKind::TYPE_BUILTIN { b = self.type_at(lt).as_data.builtin; }
            self.emit_number(s, tt, b);
        }
    }
}
fn sep(decl: *const char) *const char { if unsafe decl[0] != 0 as char { return " ".ptr as *const char; } return "".ptr as *const char; }
fn not_const_prefixed(base: *const char) bool { return unsafe cstring::strncmp(base, "const ".ptr as *const char, 6) != 0; }
fn buf_join3(out: *mut char, cap: usize, first: *const char, second: *const char, third: *const char) void {
    if cap != 0 { unsafe out[0] = 0 as char; }
    let mut at = bappend(out, cap, 0, first);
    at = bappend(out, cap, at, second);
    bappend(out, cap, at, third);
}
fn src_at(p: *const u8, off: u32) *const char { return unsafe (p + off as usize) as *const char; }

fn span_is(src: *const u8, s: tok::Span, lit: *const char) bool {
    let n = unsafe cstring::strlen(lit);
    if (s.end - s.start) as usize != n { return false; }
    return unsafe cstring::memcmp((src + s.start as usize) as *const void, lit as *const void, n) == 0;
}
fn spans_eq2(sa: *const u8, a: tok::Span, sb: *const u8, b: tok::Span) bool {
    let la = a.end - a.start;
    if la != b.end - b.start { return false; }
    return unsafe cstring::memcmp((sa + a.start as usize) as *const void, (sb + b.start as usize) as *const void, la as usize) == 0;
}
fn builtin_name(b: BuiltinType) *const char {
    if b == BuiltinType::BT_BOOL { return "bool".ptr as *const char; }
    if b == BuiltinType::BT_CHAR { return "char".ptr as *const char; }
    if b == BuiltinType::BT_I8 { return "i8".ptr as *const char; }
    if b == BuiltinType::BT_I16 { return "i16".ptr as *const char; }
    if b == BuiltinType::BT_I32 { return "i32".ptr as *const char; }
    if b == BuiltinType::BT_I64 { return "i64".ptr as *const char; }
    if b == BuiltinType::BT_ISIZE { return "isize".ptr as *const char; }
    if b == BuiltinType::BT_U8 { return "u8".ptr as *const char; }
    if b == BuiltinType::BT_U16 { return "u16".ptr as *const char; }
    if b == BuiltinType::BT_U32 { return "u32".ptr as *const char; }
    if b == BuiltinType::BT_U64 { return "u64".ptr as *const char; }
    if b == BuiltinType::BT_USIZE { return "usize".ptr as *const char; }
    if b == BuiltinType::BT_F32 { return "f32".ptr as *const char; }
    if b == BuiltinType::BT_F64 { return "f64".ptr as *const char; }
    if b == BuiltinType::BT_C32 { return "c32".ptr as *const char; }
    if b == BuiltinType::BT_C64 { return "c64".ptr as *const char; }
    if b == BuiltinType::BT_VALIST { return "va_list".ptr as *const char; }
    return "void".ptr as *const char;
}
fn builtin_of(src: *const u8, s: tok::Span) i32 {
    let mut i: i32 = 0;
    while i < (BuiltinType::BT_COUNT as i32) { if span_is(src, s, builtin_name(i as BuiltinType)) { return i; } i = i + 1; }
    return -1;
}

fn render_ident_src(src: *const u8, s: tok::Span, buf: *mut char, cap: usize) usize {
    let source_len = (s.end - s.start) as usize;
    let suffix = is_c_keyword(src, s);
    let mut full = source_len;
    if suffix { full = full + 1; }
    if cap != 0 {
        let mut copied = source_len;
        if copied > cap - 1 { copied = cap - 1; }
        unsafe cstring::memcpy(buf as *mut void, (src + s.start as usize) as *const void, copied);
        let mut written = copied;
        if suffix && written + 1 < cap { unsafe buf[written] = '_' as char; written = written + 1; }
        unsafe buf[written] = 0 as char;
    }
    return full;
}

fn bappend_bytes(out: *mut char, cap: usize, at: usize, text: *const char, n: usize) usize {
    if at < cap {
        let room = cap - at - 1;
        let mut copied = n;
        if copied > room { copied = room; }
        unsafe cstring::memcpy((out + at) as *mut void, text as *const void, copied);
        unsafe out[at + copied] = 0 as char;
    }
    return at + n;
}
fn bappend(out: *mut char, cap: usize, at: usize, text: *const char) usize {
    return bappend_bytes(out, cap, at, text, unsafe cstring::strlen(text));
}

fn is_c_keyword(src: *const u8, s: tok::Span) bool {
    let n = (s.end - s.start) as usize;
    if n == 0 { return false; }
    let c0 = unsafe src[s.start as usize];
    if c0 == 'N' as u8 { return span_is(src, s, "NULL".ptr as *const char); }
    if c0 == '_' as u8 {
        return span_is(src, s, "_Bool".ptr as *const char) || span_is(src, s, "_Complex".ptr as *const char) || span_is(src, s, "_Atomic".ptr as *const char) || span_is(src, s, "_Noreturn".ptr as *const char) || span_is(src, s, "_Generic".ptr as *const char) || span_is(src, s, "_Static_assert".ptr as *const char) || span_is(src, s, "_Thread_local".ptr as *const char);
    }
    if c0 == 'a' as u8 { return span_is(src, s, "auto".ptr as *const char); }
    if c0 == 'b' as u8 { return span_is(src, s, "break".ptr as *const char) || span_is(src, s, "bool".ptr as *const char); }
    if c0 == 'c' as u8 { return span_is(src, s, "case".ptr as *const char) || span_is(src, s, "char".ptr as *const char) || span_is(src, s, "const".ptr as *const char) || span_is(src, s, "continue".ptr as *const char); }
    if c0 == 'd' as u8 { return span_is(src, s, "default".ptr as *const char) || span_is(src, s, "do".ptr as *const char) || span_is(src, s, "double".ptr as *const char); }
    if c0 == 'e' as u8 { return span_is(src, s, "else".ptr as *const char) || span_is(src, s, "enum".ptr as *const char) || span_is(src, s, "extern".ptr as *const char); }
    if c0 == 'f' as u8 { return span_is(src, s, "float".ptr as *const char) || span_is(src, s, "for".ptr as *const char) || span_is(src, s, "false".ptr as *const char); }
    if c0 == 'g' as u8 { return span_is(src, s, "goto".ptr as *const char); }
    if c0 == 'i' as u8 { return span_is(src, s, "if".ptr as *const char) || span_is(src, s, "inline".ptr as *const char) || span_is(src, s, "int".ptr as *const char); }
    if c0 == 'l' as u8 { return span_is(src, s, "long".ptr as *const char); }
    if c0 == 'r' as u8 { return span_is(src, s, "register".ptr as *const char) || span_is(src, s, "restrict".ptr as *const char) || span_is(src, s, "return".ptr as *const char); }
    if c0 == 's' as u8 { return span_is(src, s, "short".ptr as *const char) || span_is(src, s, "signed".ptr as *const char) || span_is(src, s, "sizeof".ptr as *const char) || span_is(src, s, "static".ptr as *const char) || span_is(src, s, "struct".ptr as *const char) || span_is(src, s, "switch".ptr as *const char); }
    if c0 == 't' as u8 { return span_is(src, s, "typedef".ptr as *const char) || span_is(src, s, "true".ptr as *const char); }
    if c0 == 'u' as u8 { return span_is(src, s, "union".ptr as *const char) || span_is(src, s, "unsigned".ptr as *const char); }
    if c0 == 'v' as u8 { return span_is(src, s, "void".ptr as *const char) || span_is(src, s, "volatile".ptr as *const char); }
    if c0 == 'w' as u8 { return span_is(src, s, "while".ptr as *const char); }
    return false;
}

pub struct TyArgs4 { pub t: [TypeId; 4] }

// ---- larger scratch buffers for the backend ----
pub struct Buf176 { pub b: [char; 176] }
pub struct Buf200 { pub b: [char; 200] }
pub struct Buf240 { pub b: [char; 240] }
pub struct Buf300 { pub b: [char; 300] }
pub struct Buf320 { pub b: [char; 320] }
pub struct Buf368 { pub b: [char; 368] }
pub struct Buf400 { pub b: [char; 400] }
pub struct Buf600 { pub b: [char; 600] }
pub struct Buf1024 { pub b: [char; 1024] }
pub struct Buf1320 { pub b: [char; 1320] }
pub struct Buf1400 { pub b: [char; 1400] }
pub struct Buf4096 { pub b: [char; 4096] }
pub struct TyArgs32 { pub t: [TypeId; 32] }
pub struct Ids64 { pub b: [NodeId; 64] }

fn agg_kw(n: &Node) *const char {
    if n.kind == NodeKind::NODE_STRUCT && n.as_data.aggregate.is_union { return "union".ptr as *const char; }
    return "struct".ptr as *const char;
}

fn want_fn(which: i32, is_public: bool) bool {
    return which == PROTO_ALL || (which == PROTO_PUBLIC) == is_public;
}

fn cg_span_eq(sa: *const u8, a: tok::Span, sb: *const u8, b: tok::Span) bool {
    let la = (a.end - a.start) as usize;
    if la != (b.end - b.start) as usize { return false; }
    return unsafe cstring::memcmp((sa + a.start as usize) as *const void, (sb + b.start as usize) as *const void, la) == 0;
}

// ---- backend: declarations, function emission ----
extend Codegen {
    fn program_items(self: &Self) NodeList {
        return unsafe (*self.cur_ast()).at_const((*self.cur_ast()).root).as_data.program.items;
    }

    fn type_emittable(self: &Self, declId: NodeId) bool {
        let n = unsafe (*self.cur_ast()).at_const(declId);
        if n.kind == NodeKind::NODE_STRUCT && n.as_data.aggregate.generics.len == 0 { return true; }
        if n.kind == NodeKind::NODE_ENUM && n.as_data.aggregate.generics.len == 0 && self.aggregate_has_payload(declId) { return true; }
        return false;
    }

    // The array-type node a function returns by value (`fn f() [T; N]`), else NODE_NONE.
    fn fn_array_return(self: &Self, fn_id: NodeId) NodeId {
        let rets = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.returns;
        if rets.len != 1 { return NODE_NONE; }
        let r0 = unsafe ((*self.cur_ast()).list(rets))[0];
        let rn = unsafe (*self.cur_ast()).at_const(r0);
        let tn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { r0; };
        if unsafe (*self.cur_ast()).at_const(tn).kind == NodeKind::NODE_ARRAY_TYPE { return tn; }
        return NODE_NONE;
    }

    // Emit the `<name>_ret` struct backing a multi-return / array-by-value function.
    fn emit_ret_struct_named(self: &mut Self, fn_id: NodeId, nm: *const char) void {
        let rets = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.returns;
        let arr = self.fn_array_return(fn_id);
        if arr != NODE_NONE {
            let mut d = Buf256 {};
            self.render_type_node(arr, "_".ptr as *const char, (&mut d.b[0]) as *mut char, 256);
            self.emit("typedef struct { %s; } %s_ret;\n".ptr as *const char, (&d.b[0]) as *const char, nm);
            return;
        }
        if rets.len <= 1 { return; }
        self.emit_cstr("typedef struct { ".ptr as *const char);
        let mut i: u32 = 0;
        while i < rets.len {
            let rid = unsafe ((*self.cur_ast()).list(rets))[i as usize];
            let rn = unsafe (*self.cur_ast()).at_const(rid);
            let tn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { rid; };
            let mut fld = Buf32 {};
            unsafe stdio::snprintf((&mut fld.b[0]) as *mut char, 16, "_%u".ptr as *const char, i);
            let mut d = Buf256 {};
            self.render_type_node(tn, (&fld.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
            self.emit_cstr((&d.b[0]) as *const char);
            self.emit_cstr("; ".ptr as *const char);
            i = i + 1;
        }
        self.emit("} %s_ret;\n".ptr as *const char, nm);
    }

    fn emit_ret_struct(self: &mut Self, fn_id: NodeId, target: DefId) void {
        let rets = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.returns;
        if rets.len <= 1 && self.fn_array_return(fn_id) == NODE_NONE { return; }
        let mut nm = Buf256 {};
        self.function_name(fn_id, target, (&mut nm.b[0]) as *mut char, 256, true);
        self.emit_ret_struct_named(fn_id, (&nm.b[0]) as *const char);
    }

    // The number of `from`/`try_from` methods across all extends targeting (tmod,tdecl).
    fn cg_conv_count(self: &Self, tmod: ModuleId, tdecl: NodeId, lit: *const char) i32 {
        let mut n: i32 = 0;
        let cur = self.cur_module();
        let ns = if tmod == cur { 1; } else { 2; };
        let mut s: i32 = 0;
        while s < ns {
            let m = if s == 0 { tmod; } else { cur; };
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            let mut i: u32 = 0;
            while i < items.len {
                let iid = unsafe ((*a).list(items))[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND || it.as_data.extend_def.target_type == NODE_NONE { i = i + 1; continue; }
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tg.module != tmod || tg.node != tdecl { i = i + 1; continue; }
                let ms = it.as_data.extend_def.items;
                let mut j: u32 = 0;
                while j < ms.len {
                    let mid = unsafe ((*a).list(ms))[j as usize];
                    let mn = unsafe (*a).at_const(mid);
                    if mn.kind == NodeKind::NODE_FUNCTION && span_is(self.mod_src(m), unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text, lit) { n = n + 1; }
                    j = j + 1;
                }
                i = i + 1;
            }
            s = s + 1;
        }
        return n;
    }

    fn cg_conv_suffix(self: &mut Self, target: DefId, lit: *const char, srcTy: TypeId, out: *mut char, cap: usize) void {
        if cap != 0 { unsafe out[0] = 0 as char; }
        if target.node == NODE_NONE || srcTy == TYPE_NONE || lit == null || self.cg_conv_count(target.module, target.node, lit) < 2 { return; }
        let at = bappend(out, cap, 0, "__".ptr as *const char);
        let mut e = Buf176 {};
        self.mangle_type(self.subst_resolve(srcTy), (&mut e.b[0]) as *mut char, 176);
        bappend(out, cap, at, (&e.b[0]) as *const char);
    }

    // "void" / "T0 p0, T1 p1" — a function's C parameter list.
    fn render_params(self: &mut Self, params: NodeList, out: *mut char, cap: usize) void {
        let ids = unsafe (*self.cur_ast()).list(params);
        let mut k: usize = 0;
        unsafe out[0] = 0 as char;
        let mut any = false;
        let mut i: u32 = 0;
        while i < params.len && k < cap {
            let pid = unsafe ids[i as usize];
            if pid == self.cb_param { i = i + 1; continue; }
            let p = unsafe (*self.cur_ast()).at_const(pid).as_data.parameter;
            let mut nm = Buf128 {};
            self.render_ident(unsafe (*self.cur_ast()).at_const(p.name).as_data.name.text, (&mut nm.b[0]) as *mut char, 128);
            if unsafe nm.b[0] == '_' as char && unsafe nm.b[1] == 0 as char {
                unsafe stdio::snprintf((&mut nm.b[0]) as *mut char, 128, "__sc_u%u".ptr as *const char, pid);
            }
            let pty = unsafe (*self.cur_ast()).type_of(pid);
            let pconst = !p.is_mutable && !self.cg_type_is_free(pty);
            let mut d = Buf300 {};
            if p.ty == NODE_NONE {
                self.render_type_id(self.subst_resolve(pty), (&nm.b[0]) as *const char, (&mut d.b[0]) as *mut char, 300);
            } else {
                self.render_binding_node(p.ty, (&nm.b[0]) as *const char, pconst, (&mut d.b[0]) as *mut char, 300);
            }
            if any { k = bappend(out, cap, k, ", ".ptr as *const char); }
            k = bappend(out, cap, k, (&d.b[0]) as *const char);
            any = true;
            i = i + 1;
        }
        if !any { buf_join3(out, cap, "void".ptr as *const char, "".ptr as *const char, "".ptr as *const char); }
    }

    // Build a function's C name.
    fn function_name(self: &mut Self, fn_id: NodeId, target: DefId, out: *mut char, cap: usize, prefixed: bool) void {
        if self.cg_symbol_override(self.cur_module(), fn_id, out, cap) { return; }
        let fname = self.name_span(unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.name);
        let is_main = target.node == NODE_NONE && span_is(self.source, fname, "main".ptr as *const char);
        let mut k: usize = 0;
        if prefixed && !is_main { k = self.render_modpfx(self.cur_module(), out, cap); }
        if k >= cap { if cap != 0 { k = cap - 1; } else { k = 0; } }
        if target.node != NODE_NONE {
            let mut bb: i32 = -1;
            if self.package != null { bb = unsafe (*self.package).builtin_of_decl(target.module, target.node); }
            if bb >= 0 {
                k = bappend(out, cap, k, builtin_name(bb as BuiltinType));
            } else {
                let ts = self.name_span_in(target.module, self.cg_decl_name_node(target.module, target.node));
                k = k + render_ident_src(self.mod_src(target.module), ts, unsafe (out + k) as *mut char, cap - k);
            }
            if k + 2 < cap { unsafe out[k] = '_' as char; unsafe out[k + 1] = '_' as char; k = k + 2; }
        }
        k = k + self.render_ident(fname, unsafe (out + k) as *mut char, cap - k);
        let params = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function.params;
        let lit = self.cg_conv_lit(self.cur_module(), fname);
        if lit != null && target.node != NODE_NONE && params.len != 0 {
            let p0 = unsafe ((*self.cur_ast()).list(params))[0];
            let p0ty = unsafe (*self.cur_ast()).type_of(unsafe (*self.cur_ast()).at_const(p0).as_data.parameter.ty);
            self.cg_conv_suffix(target, lit, p0ty, unsafe (out + k) as *mut char, cap - k);
        }
    }

    // Does the subtree rooted at `id` reference parameter `param` (a NODE_PARAMETER of the current module)?
    fn cg_subtree_uses(self: &Self, id: NodeId, param: NodeId) bool {
        if id == NODE_NONE { return false; }
        let n = unsafe (*self.cur_ast()).at_const(id);
        let k = n.kind;
        if k == NodeKind::NODE_IDENTIFIER {
            let d = unsafe (*self.cur_ast()).resolution_def(id);
            return d.module == self.cur_module() && d.node == param;
        }
        if k == NodeKind::NODE_BLOCK {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.block.statements);
            let mut i: u32 = 0;
            while i < n.as_data.block.statements.len { if self.cg_subtree_uses(unsafe ids[i as usize], param) { return true; } i = i + 1; }
            return false;
        }
        if k == NodeKind::NODE_LET { return self.cg_subtree_uses(n.as_data.let_stmt.value, param); }
        if k == NodeKind::NODE_RETURN {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.return_stmt.values);
            let mut i: u32 = 0;
            while i < n.as_data.return_stmt.values.len { if self.cg_subtree_uses(unsafe ids[i as usize], param) { return true; } i = i + 1; }
            return false;
        }
        if k == NodeKind::NODE_DEFER || k == NodeKind::NODE_EXPRESSION_STATEMENT { return self.cg_subtree_uses(n.as_data.single.value, param); }
        if k == NodeKind::NODE_IF { return self.cg_subtree_uses(n.as_data.if_stmt.condition, param) || self.cg_subtree_uses(n.as_data.if_stmt.then_branch, param) || self.cg_subtree_uses(n.as_data.if_stmt.else_branch, param); }
        if k == NodeKind::NODE_WHILE { return self.cg_subtree_uses(n.as_data.while_stmt.condition, param) || self.cg_subtree_uses(n.as_data.while_stmt.body, param); }
        if k == NodeKind::NODE_FOR { return self.cg_subtree_uses(n.as_data.for_stmt.iterable, param) || self.cg_subtree_uses(n.as_data.for_stmt.body, param); }
        if k == NodeKind::NODE_MATCH {
            if self.cg_subtree_uses(n.as_data.match_expr.value, param) { return true; }
            let ids = unsafe (*self.cur_ast()).list(n.as_data.match_expr.arms);
            let mut i: u32 = 0;
            while i < n.as_data.match_expr.arms.len {
                let arm = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]);
                if self.cg_subtree_uses(arm.as_data.match_arm.guard, param) || self.cg_subtree_uses(arm.as_data.match_arm.body, param) { return true; }
                i = i + 1;
            }
            return false;
        }
        if k == NodeKind::NODE_ASSIGNMENT || k == NodeKind::NODE_BINARY { return self.cg_subtree_uses(n.as_data.binary.left, param) || self.cg_subtree_uses(n.as_data.binary.right, param); }
        if k == NodeKind::NODE_UNARY { return self.cg_subtree_uses(n.as_data.unary.operand, param); }
        if k == NodeKind::NODE_CALL {
            if self.cg_subtree_uses(n.as_data.call.callee, param) { return true; }
            let ids = unsafe (*self.cur_ast()).list(n.as_data.call.args);
            let mut i: u32 = 0;
            while i < n.as_data.call.args.len { if self.cg_subtree_uses(unsafe ids[i as usize], param) { return true; } i = i + 1; }
            return false;
        }
        if k == NodeKind::NODE_INDEX { return self.cg_subtree_uses(n.as_data.index.object, param) || self.cg_subtree_uses(n.as_data.index.index, param); }
        if k == NodeKind::NODE_MEMBER { return self.cg_subtree_uses(n.as_data.member.object, param); }
        if k == NodeKind::NODE_CAST { return self.cg_subtree_uses(n.as_data.cast.expression, param); }
        if k == NodeKind::NODE_GENERIC_SPECIALIZATION { return self.cg_subtree_uses(n.as_data.specialization.expression, param); }
        if k == NodeKind::NODE_NEW { return self.cg_subtree_uses(n.as_data.new_expr.initializer, param); }
        if k == NodeKind::NODE_VA_EXPR { return self.cg_subtree_uses(n.as_data.va_op.ap, param) || self.cg_subtree_uses(n.as_data.va_op.extra, param); }
        if k == NodeKind::NODE_ARRAY_LITERAL {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.array_literal.elements);
            let mut i: u32 = 0;
            while i < n.as_data.array_literal.elements.len { if self.cg_subtree_uses(unsafe ids[i as usize], param) { return true; } i = i + 1; }
            return false;
        }
        if k == NodeKind::NODE_STRUCT_INITIALIZER {
            let ids = unsafe (*self.cur_ast()).list(n.as_data.struct_initializer.fields);
            let mut i: u32 = 0;
            while i < n.as_data.struct_initializer.fields.len {
                let fv = unsafe (*self.cur_ast()).at_const(unsafe ids[i as usize]).as_data.field_initializer.value;
                if self.cg_subtree_uses(fv, param) { return true; }
                i = i + 1;
            }
            return false;
        }
        if k == NodeKind::NODE_CLOSURE { return self.cg_subtree_uses(n.as_data.closure.body, param); }
        if k == NodeKind::NODE_RANGE { return self.cg_subtree_uses(n.as_data.pattern_range.start, param) || self.cg_subtree_uses(n.as_data.pattern_range.end, param); }
        return false;
    }
}

fn addg(g: *mut char, cap: usize, gn: usize, s: *const char) usize {
    let mut at = gn;
    if at != 0 { at = bappend(g, cap, at, ", ".ptr as *const char); }
    return bappend(g, cap, at, s);
}

extend Codegen {
    // Emit a function signature; with_body emits the block, otherwise a prototype `;`.
    fn emit_function(self: &mut Self, fn_id: NodeId, target: DefId, extern_q: bool, with_body: bool, name_override: *const char, spec_static: bool) void {
        let f = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function;
        let mut nm = Buf256 {};
        if name_override != null {
            bappend((&mut nm.b[0]) as *mut char, 256, 0, name_override);
        } else {
            self.function_name(fn_id, target, (&mut nm.b[0]) as *mut char, 256, !extern_q);
        }
        let is_main = target.node == NODE_NONE && name_override == null && span_is(self.source, self.name_span(f.name), "main".ptr as *const char);
        let exported = self.cg_attr(self.cur_module(), fn_id, AttrKind::ATTR_EXPORT) != null;
        let is_static = if name_override != null { spec_static; } else { self.multifile && !extern_q && !is_main && !exported && !f.is_public; };
        let mut ps = Buf1024 {};
        self.render_params(f.params, (&mut ps.b[0]) as *mut char, 1024);
        if f.is_variadic && unsafe cstring::strcmp((&ps.b[0]) as *const char, "void".ptr as *const char) != 0 {
            let psl = unsafe cstring::strlen((&ps.b[0]) as *const char);
            bappend((&mut ps.b[0]) as *mut char, 1024, psl, ", ...".ptr as *const char);
        }
        let mut decl = Buf1320 {};
        let mut at: usize = 0;
        unsafe decl.b[0] = 0 as char;
        if extern_q { at = bappend((&mut decl.b[0]) as *mut char, 1320, at, "(".ptr as *const char); }
        at = bappend((&mut decl.b[0]) as *mut char, 1320, at, (&nm.b[0]) as *const char);
        if extern_q { at = bappend((&mut decl.b[0]) as *mut char, 1320, at, ")".ptr as *const char); }
        at = bappend((&mut decl.b[0]) as *mut char, 1320, at, "(".ptr as *const char);
        at = bappend((&mut decl.b[0]) as *mut char, 1320, at, (&ps.b[0]) as *const char);
        bappend((&mut decl.b[0]) as *mut char, 1320, at, ")".ptr as *const char);

        if extern_q { self.emit_cstr("extern ".ptr as *const char); }
        if is_static { self.emit_cstr("static ".ptr as *const char); }

        let fmod = self.cur_module();
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_NORETURN) != null { self.emit_cstr("_Noreturn ".ptr as *const char); }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_INLINE) != null || self.cg_attr(fmod, fn_id, AttrKind::ATTR_ALWAYS_INLINE) != null { self.emit_cstr("inline ".ptr as *const char); }
        let mut g = Buf256 {};
        unsafe g.b[0] = 0 as char;
        let mut gn: usize = 0;
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_ALWAYS_INLINE) != null { gn = addg((&mut g.b[0]) as *mut char, 256, gn, "always_inline".ptr as *const char); }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_NOINLINE) != null { gn = addg((&mut g.b[0]) as *mut char, 256, gn, "noinline".ptr as *const char); }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_USED) != null { gn = addg((&mut g.b[0]) as *mut char, 256, gn, "used".ptr as *const char); }
        if self.cg_attr(fmod, fn_id, AttrKind::ATTR_UNUSED) != null { gn = addg((&mut g.b[0]) as *mut char, 256, gn, "unused".ptr as *const char); }
        if is_static && self.cg_attr(fmod, fn_id, AttrKind::ATTR_USED) == null { gn = addg((&mut g.b[0]) as *mut char, 256, gn, "unused".ptr as *const char); }
        let sec = self.cg_attr(fmod, fn_id, AttrKind::ATTR_SECTION);
        if sec != null {
            let sp = unsafe (*sec).str_span;
            let mut nl = (sp.end - sp.start) as usize;
            if nl >= 128 { nl = 127; }
            let mut nm2 = Buf128 {};
            unsafe cstring::memcpy((&mut nm2.b[0]) as *mut void, (self.mod_src(fmod) + sp.start as usize) as *const void, nl);
            unsafe nm2.b[nl] = 0 as char;
            let mut sb = Buf160 {};
            unsafe stdio::snprintf((&mut sb.b[0]) as *mut char, 160, "section(\"%s\")".ptr as *const char, (&nm2.b[0]) as *const char);
            gn = addg((&mut g.b[0]) as *mut char, 256, gn, (&sb.b[0]) as *const char);
        }
        if gn != 0 { self.emit("__attribute__((%s)) ".ptr as *const char, (&g.b[0]) as *const char); }

        let rets = f.returns;
        unsafe self.current_ret[0] = 0 as char;
        self.current_fn_ret_node = NODE_NONE;
        if target.node == NODE_NONE && !extern_q && span_is(self.source, self.name_span(f.name), "main".ptr as *const char) {
            self.emit("int %s".ptr as *const char, (&decl.b[0]) as *const char);
        } else if rets.len > 1 {
            buf_join3((&mut self.current_ret[0]) as *mut char, 128, (&nm.b[0]) as *const char, "".ptr as *const char, "_ret".ptr as *const char);
            let cr = (&self.current_ret[0]) as *const char;
            self.emit_cstr(cr);
            self.emit_cstr(" ".ptr as *const char);
            self.emit_cstr((&decl.b[0]) as *const char);
        } else if self.fn_array_return(fn_id) != NODE_NONE {
            buf_join3((&mut self.current_ret[0]) as *mut char, 128, (&nm.b[0]) as *const char, "".ptr as *const char, "_ret".ptr as *const char);
            let cr = (&self.current_ret[0]) as *const char;
            self.emit_cstr(cr);
            self.emit_cstr(" ".ptr as *const char);
            self.emit_cstr((&decl.b[0]) as *const char);
        } else if rets.len == 1 {
            let r0 = unsafe ((*self.cur_ast()).list(rets))[0];
            let rn = unsafe (*self.cur_ast()).at_const(r0);
            self.current_fn_ret_node = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { r0; };
            let mut out = Buf1400 {};
            self.render_type_node(self.current_fn_ret_node, (&decl.b[0]) as *const char, (&mut out.b[0]) as *mut char, 1400);
            self.emit_cstr((&out.b[0]) as *const char);
        } else {
            self.emit_cstr("void ".ptr as *const char);
            self.emit_cstr((&decl.b[0]) as *const char);
        }

        if with_body && f.body != NODE_NONE {
            self.emit_cstr(" ".ptr as *const char);
            self.defer_top = 0;
            self.loop_defer_base = 0;
            self.nmoved = 0;
            self.ncond_moved = 0;
            self.ncond_sites = 0;
            self.cg_scan_moves(f.body, false, 0);
            self.cg_scan_moves(f.body, false, 1);
            let pids = unsafe (*self.cur_ast()).list(f.params);
            self.nparam_flags = 0;
            self.nunused_params = 0;
            let mut i: u32 = 0;
            while i < f.params.len {
                let pid = unsafe pids[i as usize];
                if self.cg_will_auto_free(pid) {
                    self.cg_register_auto_free(pid);
                    if self.cg_is_cond_moved(pid) && self.nparam_flags < 32 { self.param_flags[self.nparam_flags as usize] = pid; self.nparam_flags = self.nparam_flags + 1; }
                } else if !self.cg_subtree_uses(f.body, pid) && self.nunused_params < 32 {
                    self.unused_params[self.nunused_params as usize] = pid;
                    self.nunused_params = self.nunused_params + 1;
                }
                i = i + 1;
            }
            self.emit_block_from(f.body, 0);
            self.emit_cstr("\n\n".ptr as *const char);
        } else {
            self.emit_cstr(";\n".ptr as *const char);
        }
    }
}

// ---- backend stubs: filled in below, kept as at-least-decls so the whole file compiles green ----
extend Codegen {
    fn cg_is_format_builtin(self: &Self, m: ModuleId, node: NodeId) bool {
        if self.package == null || (m as usize) >= self.pkg_count() || !unsafe (*self.package).modules.at(m as usize).prelude { return false; }
        let a = self.mod_ast(m);
        if unsafe (*a).at_const(node).kind != NodeKind::NODE_FUNCTION { return false; }
        let fnm = unsafe (*a).at_const(unsafe (*a).at_const(node).as_data.function.name).as_data.name.text;
        let s = self.mod_src(m);
        return span_is(s, fnm, "format".ptr as *const char) || span_is(s, fnm, "print".ptr as *const char)
            || span_is(s, fnm, "println".ptr as *const char) || span_is(s, fnm, "eprint".ptr as *const char)
            || span_is(s, fnm, "eprintln".ptr as *const char) || span_is(s, fnm, "assert".ptr as *const char)
            || span_is(s, fnm, "assert_eq".ptr as *const char) || span_is(s, fnm, "assert_ne".ptr as *const char);
    }

    fn cg_type_mentions_fnval(self: &Self, t: TypeId) bool {
        if t == TYPE_NONE { return false; }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_FUNCTION { return true; }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.cg_type_mentions_fnval(y.as_data.elem);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut i: u8 = 0;
            while i < it.n { if self.cg_type_mentions_fnval(it.args[i as usize]) { return true; } i = i + 1; }
            return false;
        }
        return false;
    }
    fn inst_mentions_fnval(self: &Self, it: &TyInstance) bool {
        let mut i: u8 = 0;
        while i < it.n { if self.cg_type_mentions_fnval(it.args[i as usize]) { return true; } i = i + 1; }
        return false;
    }

    fn cg_test_skip(self: &Self, fn2: NodeId, method: bool) bool {
        if self.test.enabled {
            let f = unsafe (*self.cur_ast()).at_const(fn2);
            return !method && f.kind == NodeKind::NODE_FUNCTION && span_is(self.source, unsafe (*self.cur_ast()).at_const(f.as_data.function.name).as_data.name.text, "main".ptr as *const char);
        }
        return self.cg_attr(self.cur_module(), fn2, AttrKind::ATTR_TEST) != null || self.cg_attr(self.cur_module(), fn2, AttrKind::ATTR_TEST_INIT) != null || self.cg_attr(self.cur_module(), fn2, AttrKind::ATTR_TEST_FREE) != null;
    }

    fn emit_enum_full(self: &mut Self, enum_id: NodeId) void {
        let ag = unsafe (*self.cur_ast()).at_const(enum_id).as_data.aggregate;
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), ag.name, (&mut nm.b[0]) as *mut char, 160);
        self.emit("#ifndef SUPER_ENUM_%s\n#define SUPER_ENUM_%s\n".ptr as *const char, (&nm.b[0]) as *const char, (&nm.b[0]) as *const char);
        self.emit_cstr("typedef enum { ".ptr as *const char);
        let ms = ag.members;
        let mut j: u32 = 0;
        while j < ms.len {
            if j != 0 { self.emit_cstr(", ".ptr as *const char); }
            let mid = unsafe ((*self.cur_ast()).list(ms))[j as usize];
            self.emit_tag(enum_id, mid);
            let disc = unsafe (*self.cur_ast()).at_const(mid).as_data.variant.value;
            if disc != NODE_NONE {
                self.emit_cstr(" = ".ptr as *const char);
                let sc = self.const_ctx;
                self.const_ctx = true;
                self.emit_expr(disc);
                self.const_ctx = sc;
            }
            j = j + 1;
        }
        self.emit_cstr(" } ".ptr as *const char);
        self.emit_local_type_name(ag.name);
        self.emit_cstr(";\n#endif\n".ptr as *const char);
    }
    fn emit_enum_tag_decl(self: &mut Self, enum_id: NodeId) void {
        let ag = unsafe (*self.cur_ast()).at_const(enum_id).as_data.aggregate;
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), ag.name, (&mut nm.b[0]) as *mut char, 160);
        self.emit("#ifndef SUPER_ENUMTAG_%s\n#define SUPER_ENUMTAG_%s\n".ptr as *const char, (&nm.b[0]) as *const char, (&nm.b[0]) as *const char);
        self.emit_cstr("typedef enum { ".ptr as *const char);
        let ms = ag.members;
        let mut j: u32 = 0;
        while j < ms.len {
            if j != 0 { self.emit_cstr(", ".ptr as *const char); }
            let mid = unsafe ((*self.cur_ast()).list(ms))[j as usize];
            self.emit_tag(enum_id, mid);
            let disc = unsafe (*self.cur_ast()).at_const(mid).as_data.variant.value;
            if disc != NODE_NONE {
                self.emit_cstr(" = ".ptr as *const char);
                let sc = self.const_ctx;
                self.const_ctx = true;
                self.emit_expr(disc);
                self.const_ctx = sc;
            }
            j = j + 1;
        }
        self.emit_cstr(" } ".ptr as *const char);
        self.emit_local_type_name(ag.name);
        self.emit_cstr("Tag;\n#endif\n".ptr as *const char);
    }
    fn emit_enum_struct_body(self: &mut Self, dn_id: NodeId) void {
        let ag = unsafe (*self.cur_ast()).at_const(dn_id).as_data.aggregate;
        self.depth = self.depth + 1;
        self.emit_indent();
        self.emit_local_type_name(ag.name);
        self.emit_cstr("Tag tag;\n".ptr as *const char);
        self.emit_indent();
        self.emit_cstr("union {\n".ptr as *const char);
        self.depth = self.depth + 1;
        let ms = ag.members;
        let mut j: u32 = 0;
        while j < ms.len {
            let mid = unsafe ((*self.cur_ast()).list(ms))[j as usize];
            let v = unsafe (*self.cur_ast()).at_const(mid).as_data.variant;
            let payload = v.payload;
            if payload.len == 0 { j = j + 1; continue; }
            self.emit_indent();
            self.emit_cstr("struct { ".ptr as *const char);
            let mut k: u32 = 0;
            while k < payload.len {
                let pid = unsafe ((*self.cur_ast()).list(payload))[k as usize];
                let pe = unsafe (*self.cur_ast()).at_const(pid);
                let mut d = Buf256 {};
                if v.struct_payload {
                    let mut m = Buf128 {};
                    let msp = self.name_span(pe.as_data.field.name);
                    self.render_ident(msp, (&mut m.b[0]) as *mut char, 128);
                    self.render_type_node(pe.as_data.field.ty, (&m.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
                } else {
                    let mut fld = Buf32 {};
                    unsafe stdio::snprintf((&mut fld.b[0]) as *mut char, 24, "_%u".ptr as *const char, k);
                    self.render_type_node(pid, (&fld.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
                }
                self.emit_cstr((&d.b[0]) as *const char);
                self.emit_cstr("; ".ptr as *const char);
                k = k + 1;
            }
            self.emit_cstr("} ".ptr as *const char);
            let vsp = self.name_span(v.name);
            self.emit_span(vsp);
            self.emit_cstr(";\n".ptr as *const char);
            j = j + 1;
        }
        self.depth = self.depth - 1;
        self.emit_indent();
        self.emit_cstr("} payload;\n".ptr as *const char);
        self.depth = self.depth - 1;
    }
    fn emit_type_decl(self: &mut Self, declId: NodeId) void {
        let ag = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate;
        let kind = unsafe (*self.cur_ast()).at_const(declId).kind;
        let kw = agg_kw(unsafe (*self.cur_ast()).at_const(declId));
        self.emit("%s ".ptr as *const char, kw);
        let pk = self.cg_attr(self.cur_module(), declId, AttrKind::ATTR_PACKED);
        let al = self.cg_attr(self.cur_module(), declId, AttrKind::ATTR_ALIGN);
        if pk != null || al != null {
            let mut g = Buf64 {};
            unsafe g.b[0] = 0 as char;
            let mut gn: usize = 0;
            if pk != null { gn = bappend((&mut g.b[0]) as *mut char, 64, gn, "packed".ptr as *const char); }
            if al != null {
                if gn != 0 { gn = bappend((&mut g.b[0]) as *mut char, 64, gn, ", ".ptr as *const char); }
                let mut a = Buf32 {};
                unsafe stdio::snprintf((&mut a.b[0]) as *mut char, 32, "aligned(%u)".ptr as *const char, unsafe (*al).arg);
                bappend((&mut g.b[0]) as *mut char, 64, gn, (&a.b[0]) as *const char);
            }
            self.emit("__attribute__((%s)) ".ptr as *const char, (&g.b[0]) as *const char);
        }
        self.emit_local_type_name(ag.name);
        self.emit_cstr(" {\n".ptr as *const char);
        if kind == NodeKind::NODE_ENUM {
            self.emit_enum_struct_body(declId);
        } else if ag.is_tuple {
            self.depth = self.depth + 1;
            let mut j: u32 = 0;
            while j < ag.members.len {
                let ftn = unsafe ((*self.cur_ast()).list(ag.members))[j as usize];
                let mut nm = Buf32 {};
                unsafe stdio::snprintf((&mut nm.b[0]) as *mut char, 16, "_%u".ptr as *const char, j);
                let mut d = Buf256 {};
                self.render_type_node(ftn, (&nm.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
                self.emit_indent();
                self.emit_cstr((&d.b[0]) as *const char);
                self.emit_cstr(";\n".ptr as *const char);
                j = j + 1;
            }
            self.depth = self.depth - 1;
        } else {
            self.depth = self.depth + 1;
            let mut j: u32 = 0;
            while j < ag.members.len {
                let fid = unsafe ((*self.cur_ast()).list(ag.members))[j as usize];
                let fld = unsafe (*self.cur_ast()).at_const(fid).as_data.field;
                let mut nm = Buf128 {};
                let fnsp = self.name_span(fld.name);
                self.render_ident(fnsp, (&mut nm.b[0]) as *mut char, 128);
                let mut d = Buf256 {};
                self.render_type_node(fld.ty, (&nm.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
                self.emit_indent();
                self.emit_cstr((&d.b[0]) as *const char);
                self.emit_cstr(";\n".ptr as *const char);
                j = j + 1;
            }
            self.depth = self.depth - 1;
        }
        self.emit_cstr("};\n".ptr as *const char);
    }
    fn emit_struct_inst(self: &mut Self, it: &TyInstance, with_body: bool) void {
        let kw = agg_kw(unsafe (*self.cur_ast()).at_const(it.decl));
        let mut nm = Buf200 {};
        self.inst_name(it, (&mut nm.b[0]) as *mut char, 200);
        if !with_body {
            self.emit("typedef %s %s %s;\n".ptr as *const char, kw, (&nm.b[0]) as *const char, (&nm.b[0]) as *const char);
            return;
        }
        if self.inst_mentions_fnval(it) != self.fnval_pass { return; }
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
        self.emit("%s %s {\n".ptr as *const char, kw, (&nm.b[0]) as *const char);
        self.depth = self.depth + 1;
        let mut j: u32 = 0;
        while j < ag.members.len {
            let fid = unsafe ((*self.cur_ast()).list(ag.members))[j as usize];
            let fld = unsafe (*self.cur_ast()).at_const(fid).as_data.field;
            let mut fnm = Buf128 {};
            let fnsp = self.name_span(fld.name);
            self.render_ident(fnsp, (&mut fnm.b[0]) as *mut char, 128);
            let mut d = Buf256 {};
            self.render_type_node(fld.ty, (&fnm.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
            self.emit_indent();
            self.emit_cstr((&d.b[0]) as *const char);
            self.emit_cstr(";\n".ptr as *const char);
            j = j + 1;
        }
        self.depth = self.depth - 1;
        self.emit_cstr("};\n".ptr as *const char);
        self.nsubst = 0;
    }
    fn emit_enum_inst(self: &mut Self, it: &TyInstance, with_body: bool) void {
        let mut nm = Buf200 {};
        self.inst_name(it, (&mut nm.b[0]) as *mut char, 200);
        let ag = unsafe (*self.cur_ast()).at_const(it.decl).as_data.aggregate;
        if !self.aggregate_has_payload(it.decl) {
            if with_body {
                self.emit_cstr("typedef ".ptr as *const char);
                self.emit_local_type_name(ag.name);
                self.emit(" %s;\n".ptr as *const char, (&nm.b[0]) as *const char);
            }
            return;
        }
        if !with_body {
            self.emit("typedef struct %s %s;\n".ptr as *const char, (&nm.b[0]) as *const char, (&nm.b[0]) as *const char);
            return;
        }
        if self.inst_mentions_fnval(it) != self.fnval_pass { return; }
        let gids = unsafe (*self.cur_ast()).list(ag.generics);
        self.nsubst = 0;
        let mut i: u32 = 0;
        while i < ag.generics.len && i < it.n as u32 && self.nsubst < 16 {
            self.subst[self.nsubst as usize].param = DefId { module: it.module, node: unsafe gids[i as usize] };
            self.subst[self.nsubst as usize].concrete = it.args[i as usize];
            self.nsubst = self.nsubst + 1;
            i = i + 1;
        }
        self.emit("struct %s {\n".ptr as *const char, (&nm.b[0]) as *const char);
        self.emit_enum_struct_body(it.decl);
        self.emit_cstr("};\n".ptr as *const char);
        self.nsubst = 0;
    }
    fn emit_generic_enum_shared(self: &mut Self) void {
        let mut seen = Ids64 {};
        let mut ns: i32 = 0;
        let mut i: usize = 0;
        while i < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(i as u32);
            if it.module != self.cur_module() { i = i + 1; continue; }
            if unsafe (*self.cur_ast()).at_const(it.decl).kind != NodeKind::NODE_ENUM { i = i + 1; continue; }
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { i = i + 1; continue; }
            let mut dup = false;
            let mut s: i32 = 0;
            while s < ns { if unsafe seen.b[s as usize] == it.decl { dup = true; } s = s + 1; }
            if dup { i = i + 1; continue; }
            if ns < 64 { unsafe seen.b[ns as usize] = it.decl; ns = ns + 1; }
            if self.aggregate_has_payload(it.decl) { self.emit_enum_tag_decl(it.decl); } else { self.emit_enum_full(it.decl); }
            i = i + 1;
        }
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut ii: u32 = 0;
        while ii < items.len {
            let did = unsafe ids[ii as usize];
            let dn = unsafe (*self.cur_ast()).at_const(did);
            if dn.kind != NodeKind::NODE_ENUM || dn.as_data.aggregate.generics.len == 0 || !dn.as_data.aggregate.is_public { ii = ii + 1; continue; }
            let mut dup = false;
            let mut s: i32 = 0;
            while s < ns { if unsafe seen.b[s as usize] == did { dup = true; } s = s + 1; }
            if dup { ii = ii + 1; continue; }
            if ns < 64 { unsafe seen.b[ns as usize] = did; ns = ns + 1; }
            if self.aggregate_has_payload(did) { self.emit_enum_tag_decl(did); } else { self.emit_enum_full(did); }
            ii = ii + 1;
        }
    }
    fn push_home_dep(self: &Self, st0: TypeId, deps: *mut TypeId, nh: *mut i32) void {
        if unsafe (*nh) >= 32 || st0 == TYPE_NONE { return; }
        let mut st = st0;
        let mut y = *self.type_at(st);
        while y.kind == TypeKind::TYPE_ARRAY {
            st = y.as_data.elem;
            y = *self.type_at(st);
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM && y.kind != TypeKind::TYPE_INSTANCE { return; }
        let mut i: i32 = 0;
        while i < unsafe (*nh) { if unsafe deps[i as usize] == st { return; } i = i + 1; }
        let cur = unsafe (*nh);
        unsafe deps[cur as usize] = st;
        unsafe (*nh) = cur + 1;
    }
    fn emit_home_dep(self: &mut Self, st: TypeId) void {
        if st == TYPE_NONE { return; }
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
    fn emit_inst_dfs(self: &mut Self, idx: u32, state: *mut u8, nstate: usize, with_body: bool) void {
        if idx as usize >= nstate || unsafe state[idx as usize] != 0 as u8 { return; }
        let it = *unsafe (*self.cur_ast()).instance(idx);
        let mut concrete = true;
        let mut k: u8 = 0;
        while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
        if it.module != self.cur_module() || !concrete { return; }
        unsafe state[idx as usize] = 1 as u8;
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
        let mut m: u32 = 0;
        while m < ag.members.len {
            let mn = unsafe (*self.cur_ast()).at_const(unsafe mids[m as usize]);
            if dk == NodeKind::NODE_STRUCT && mn.kind == NodeKind::NODE_FIELD {
                let ft = self.subst_resolve(unsafe (*self.cur_ast()).type_of(mn.as_data.field.ty));
                self.push_home_dep(ft, (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
            } else if dk == NodeKind::NODE_ENUM && mn.kind == NodeKind::NODE_VARIANT {
                let pids = unsafe (*self.cur_ast()).list(mn.as_data.variant.payload);
                let mut kk: u32 = 0;
                while kk < mn.as_data.variant.payload.len {
                    let pf = unsafe (*self.cur_ast()).at_const(unsafe pids[kk as usize]);
                    let ptn = if (pf.kind == NodeKind::NODE_FIELD) { pf.as_data.field.ty; } else { unsafe pids[kk as usize]; };
                    let ft = self.subst_resolve(unsafe (*self.cur_ast()).type_of(ptn));
                    self.push_home_dep(ft, (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
                    kk = kk + 1;
                }
            }
            m = m + 1;
        }
        self.nsubst = saved;
        let mut d: i32 = 0;
        while d < nh { self.emit_home_dep(unsafe deps.t[d as usize]); d = d + 1; }
        if dk == NodeKind::NODE_STRUCT { self.emit_struct_inst(&it, with_body); }
        else if dk == NodeKind::NODE_ENUM { self.emit_enum_inst(&it, with_body); }
        unsafe state[idx as usize] = 2 as u8;
    }
    fn emit_type_dfs(self: &mut Self, declId: NodeId, state: *mut u8) void {
        if unsafe state[declId as usize] != 0 as u8 { return; }
        unsafe state[declId as usize] = 1 as u8;
        let n_kind = unsafe (*self.cur_ast()).at_const(declId).kind;
        let members = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.members;
        let is_tuple = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.is_tuple;
        let mut deps = TyArgs32 {};
        let mut nh: i32 = 0;
        let mids = unsafe (*self.cur_ast()).list(members);
        let mut i: u32 = 0;
        while i < members.len {
            let m = unsafe (*self.cur_ast()).at_const(unsafe mids[i as usize]);
            if n_kind == NodeKind::NODE_STRUCT && is_tuple {
                self.push_home_dep(unsafe (*self.cur_ast()).type_of(unsafe mids[i as usize]), (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
            } else if n_kind == NodeKind::NODE_STRUCT && m.kind == NodeKind::NODE_FIELD {
                self.push_home_dep(unsafe (*self.cur_ast()).type_of(m.as_data.field.ty), (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
            } else if n_kind == NodeKind::NODE_ENUM && m.kind == NodeKind::NODE_VARIANT {
                let plids = unsafe (*self.cur_ast()).list(m.as_data.variant.payload);
                let mut kk: u32 = 0;
                while kk < m.as_data.variant.payload.len {
                    let pf = unsafe (*self.cur_ast()).at_const(unsafe plids[kk as usize]);
                    let ptn = if (pf.kind == NodeKind::NODE_FIELD) { pf.as_data.field.ty; } else { unsafe plids[kk as usize]; };
                    self.push_home_dep(unsafe (*self.cur_ast()).type_of(ptn), (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
                    kk = kk + 1;
                }
            }
            i = i + 1;
        }
        let mut d: i32 = 0;
        while d < nh { self.emit_home_dep(unsafe deps.t[d as usize]); d = d + 1; }
        self.emit_type_decl(declId);
        unsafe state[declId as usize] = 2 as u8;
    }
    fn cg_type_state(self: &mut Self) *mut u8 { if self.type_state == null { self.type_state = unsafe stdlib::calloc(unsafe (*self.cur_ast()).nodes.len(), 1) as *mut u8; } return self.type_state; }
    fn emit_agg_spec_fallback(self: &mut Self, with_body: bool) void {
        let mut i: usize = 0;
        while i < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(i as u32);
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if it.module != self.cur_module() || !concrete { i = i + 1; continue; }
            let dk = unsafe (*self.cur_ast()).at_const(it.decl).kind;
            if dk == NodeKind::NODE_STRUCT { self.emit_struct_inst(&it, with_body); }
            else if dk == NodeKind::NODE_ENUM { self.emit_enum_inst(&it, with_body); }
            i = i + 1;
        }
    }
    fn emit_aggregate_specializations(self: &mut Self, with_body: bool) void {
        if !with_body { self.emit_generic_enum_shared(); }
        let n = unsafe (*self.cur_ast()).instances.len();
        if with_body {
            let state = self.inst_emit_state;
            let nstate = self.inst_emit_n;
            if state == null { self.emit_agg_spec_fallback(with_body); return; }
            let mut i: usize = 0;
            while i < n && i < nstate { self.emit_inst_dfs(i as u32, state, nstate, with_body); i = i + 1; }
        } else {
            let cnt = if n != 0 { n; } else { 1 as usize; };
            let state = unsafe stdlib::calloc(cnt, 1) as *mut u8;
            if state == null { self.emit_agg_spec_fallback(with_body); return; }
            let mut i: usize = 0;
            while i < n { self.emit_inst_dfs(i as u32, state, n, with_body); i = i + 1; }
            unsafe stdlib::free(state as *mut void);
        }
    }
    fn inst_rehomed_here(self: &Self, it: &TyInstance) bool {
        if self.package == null || it.module == self.cur_module() { return false; }
        let mut k: u8 = 0;
        while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { return false; } k = k + 1; }
        return unsafe (*self.package).instance_home(unsafe (&*self.cur_ast()), it) == self.cur_module();
    }
    fn rehome_subst_type(self: &mut Self, owner_mod: ModuleId, it: &TyInstance, t: TypeId) TypeId {
        if t == TYPE_NONE { return TYPE_NONE; }
        let ty = *unsafe (*self.mod_ast(owner_mod)).type_at(t);
        if ty.kind == TypeKind::TYPE_GENERIC {
            let gens = unsafe (*self.mod_ast(owner_mod)).at_const(it.decl).as_data.aggregate.generics;
            let gids = unsafe (*self.mod_ast(owner_mod)).list(gens);
            let mut i: u32 = 0;
            while i < gens.len && i < it.n as u32 {
                if ty.module == it.module && ty.as_data.decl == unsafe gids[i as usize] { return it.args[i as usize]; }
                i = i + 1;
            }
            return unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(owner_mod)), t);
        }
        if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE || ty.kind == TypeKind::TYPE_SLICE || ty.kind == TypeKind::TYPE_ARRAY {
            let e = self.rehome_subst_type(owner_mod, it, ty.as_data.elem);
            let mut nt = ty;
            nt.as_data.elem = e;
            return unsafe (*self.cur_ast()).intern_type(nt);
        }
        if ty.kind == TypeKind::TYPE_INSTANCE {
            let inst = *unsafe (*self.mod_ast(owner_mod)).instance(ty.as_data.inst);
            let mut na = TyArgs4 {};
            let nn = if (inst.n < 4) { inst.n; } else { 4 as u8; };
            let mut i: u8 = 0;
            while i < nn { unsafe na.t[i as usize] = self.rehome_subst_type(owner_mod, it, inst.args[i as usize]); i = i + 1; }
            return unsafe (*self.cur_ast()).intern_instance(inst.module, inst.decl, (&na.t[0]) as *const TypeId, nn);
        }
        return unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(owner_mod)), t);
    }
    fn emit_rehomed_struct(self: &mut Self, it: &TyInstance, with_body: bool) void {
        let home = self.cur_ast();
        let hsrc = self.source;
        let hlen = self.len;
        let owner = self.mod_ast(it.module);
        let osrc = self.mod_src(it.module);
        let oninst = unsafe (*owner).instances.len();
        let mut oit = *it;
        let mut k: u8 = 0;
        while k < it.n { unsafe oit.args[k as usize] = unsafe (*owner).reintern(unsafe (&*home), it.args[k as usize]); k = k + 1; }
        self.source = osrc;
        self.len = unsafe (*self.package).modules.at(it.module as usize).source_len;
        self.borrowed = true;
        self.ast = self.mod_ast(it.module);
        let dk = unsafe (*self.cur_ast()).at_const(oit.decl).kind;
        if dk == NodeKind::NODE_STRUCT { self.emit_struct_inst(&oit, with_body); }
        else if dk == NodeKind::NODE_ENUM { self.emit_enum_inst(&oit, with_body); }
        unsafe (*self.cur_ast()).instances.truncate(oninst);
        self.borrowed = false;
        self.ast = home;
        self.source = hsrc;
        self.len = hlen;
        self.nsubst = 0;
    }
    fn emit_rehomed_struct_dfs(self: &mut Self, idx: u32, state: *mut u8, nstate: usize, with_body: bool) void {
        if idx as usize >= nstate || unsafe state[idx as usize] != 0 as u8 { return; }
        let it = *unsafe (*self.cur_ast()).instance(idx);
        if !self.inst_rehomed_here(&it) { unsafe state[idx as usize] = 2 as u8; return; }
        unsafe state[idx as usize] = 1 as u8;
        let owner_mod = it.module;
        let dn_kind = unsafe (*self.mod_ast(owner_mod)).at_const(it.decl).kind;
        let members = unsafe (*self.mod_ast(owner_mod)).at_const(it.decl).as_data.aggregate.members;
        let mut deps = TyArgs32 {};
        let mut nh: i32 = 0;
        let mids = unsafe (*self.mod_ast(owner_mod)).list(members);
        let mut m: u32 = 0;
        while m < members.len {
            let mid = unsafe mids[m as usize];
            let mnk = unsafe (*self.mod_ast(owner_mod)).at_const(mid).kind;
            if dn_kind == NodeKind::NODE_STRUCT && mnk == NodeKind::NODE_FIELD {
                let fty = unsafe (*self.mod_ast(owner_mod)).at_const(mid).as_data.field.ty;
                let fnode_ty = unsafe (*self.mod_ast(owner_mod)).type_of(fty);
                let ft = self.rehome_subst_type(owner_mod, &it, fnode_ty);
                self.push_home_dep(ft, (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
            } else if dn_kind == NodeKind::NODE_ENUM && mnk == NodeKind::NODE_VARIANT {
                let payload = unsafe (*self.mod_ast(owner_mod)).at_const(mid).as_data.variant.payload;
                let pids = unsafe (*self.mod_ast(owner_mod)).list(payload);
                let mut kk: u32 = 0;
                while kk < payload.len {
                    let pid = unsafe pids[kk as usize];
                    let pfk = unsafe (*self.mod_ast(owner_mod)).at_const(pid).kind;
                    let tn = if (pfk == NodeKind::NODE_FIELD) { unsafe (*self.mod_ast(owner_mod)).at_const(pid).as_data.field.ty; } else { pid; };
                    let fnode_ty = unsafe (*self.mod_ast(owner_mod)).type_of(tn);
                    let ft = self.rehome_subst_type(owner_mod, &it, fnode_ty);
                    self.push_home_dep(ft, (&mut deps.t[0]) as *mut TypeId, (&mut nh) as *mut i32);
                    kk = kk + 1;
                }
            }
            m = m + 1;
        }
        let mut d: i32 = 0;
        while d < nh { self.emit_home_dep(unsafe deps.t[d as usize]); d = d + 1; }
        self.emit_rehomed_struct(&it, with_body);
        unsafe state[idx as usize] = 2 as u8;
    }
    fn emit_rehomed_structs(self: &mut Self, with_body: bool) void {
        if self.package == null { return; }
        let n = unsafe (*self.cur_ast()).instances.len();
        if with_body {
            let state = self.inst_emit_state;
            let nstate = self.inst_emit_n;
            if state == null {
                let mut ii: usize = 0;
                while ii < n {
                    let it = *unsafe (*self.cur_ast()).instance(ii as u32);
                    if self.inst_rehomed_here(&it) { self.emit_rehomed_struct(&it, with_body); }
                    ii = ii + 1;
                }
                return;
            }
            let mut ii: usize = 0;
            while ii < n && ii < nstate { self.emit_rehomed_struct_dfs(ii as u32, state, nstate, with_body); ii = ii + 1; }
        } else {
            let cnt = if n != 0 { n; } else { 1 as usize; };
            let state = unsafe stdlib::calloc(cnt, 1) as *mut u8;
            if state == null {
                let mut ii: usize = 0;
                while ii < n {
                    let it = *unsafe (*self.cur_ast()).instance(ii as u32);
                    if self.inst_rehomed_here(&it) { self.emit_rehomed_struct(&it, with_body); }
                    ii = ii + 1;
                }
                return;
            }
            let mut ii: usize = 0;
            while ii < n { self.emit_rehomed_struct_dfs(ii as u32, state, n, with_body); ii = ii + 1; }
            unsafe stdlib::free(state as *mut void);
        }
    }
    fn emit_rehomed_forwards(self: &mut Self) void {
        if self.package == null { return; }
        let mut i: usize = 0;
        while i < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(i as u32);
            if !self.inst_rehomed_here(&it) { i = i + 1; continue; }
            let dn_kind = unsafe (*self.mod_ast(it.module)).at_const(it.decl).kind;
            let mut inm = Buf200 {};
            self.inst_name(&it, (&mut inm.b[0]) as *mut char, 200);
            if dn_kind == NodeKind::NODE_STRUCT || self.aggregate_has_payload_in(it.module, it.decl) {
                let kw = agg_kw(unsafe (*self.mod_ast(it.module)).at_const(it.decl));
                self.emit("typedef %s %s %s;\n".ptr as *const char, kw, (&inm.b[0]) as *const char, (&inm.b[0]) as *const char);
            } else {
                let anm = unsafe (*self.mod_ast(it.module)).at_const(it.decl).as_data.aggregate.name;
                let mut en = Buf160 {};
                self.render_qualified(it.module, anm, (&mut en.b[0]) as *mut char, 160);
                self.emit("typedef %s %s;\n".ptr as *const char, (&en.b[0]) as *const char, (&inm.b[0]) as *const char);
            }
            i = i + 1;
        }
    }
    fn emit_fnval_instance_structs(self: &mut Self) void {
        let n = unsafe (*self.cur_ast()).instances.len();
        let cnt = if n != 0 { n; } else { 1 as usize; };
        let state = unsafe stdlib::calloc(cnt, 1) as *mut u8;
        self.fnval_pass = true;
        if state != null {
            self.inst_emit_state = state;
            self.inst_emit_n = n;
            let mut i: usize = 0;
            while i < n {
                self.emit_inst_dfs(i as u32, state, n, true);
                self.emit_rehomed_struct_dfs(i as u32, state, n, true);
                i = i + 1;
            }
            self.inst_emit_state = null;
            self.inst_emit_n = 0;
            unsafe stdlib::free(state as *mut void);
        } else {
            let mut i: usize = 0;
            while i < n {
                let it = *unsafe (*self.cur_ast()).instance(i as u32);
                let mut concrete = true;
                let mut k: u8 = 0;
                while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
                if !concrete { i = i + 1; continue; }
                if it.module == self.cur_module() {
                    let dk = unsafe (*self.cur_ast()).at_const(it.decl).kind;
                    if dk == NodeKind::NODE_STRUCT { self.emit_struct_inst(&it, true); }
                    else if dk == NodeKind::NODE_ENUM { self.emit_enum_inst(&it, true); }
                } else if self.inst_rehomed_here(&it) {
                    self.emit_rehomed_struct(&it, true);
                }
                i = i + 1;
            }
        }
        self.fnval_pass = false;
    }
    fn emit_generic_macros(self: &mut Self) void {
        if self.package == null { return; }
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            let ng = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate.generics.len;
            if (nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM) || ng == 0 { i = i + 1; continue; }
            if self.cg_attr(self.cur_module(), nid, AttrKind::ATTR_EMIT_MACRO) == null { i = i + 1; continue; }
            if nk == NodeKind::NODE_ENUM {
                if self.aggregate_has_payload(nid) { self.emit_enum_tag_decl(nid); } else { self.emit_enum_full(nid); }
            }
            self.emit_generic_macro(nid, false);
            self.emit_generic_macro(nid, true);
            self.emit_generic_method_macros(nid);
            self.emit_generic_conformance_macros(nid);
            i = i + 1;
        }
    }
    fn emit_inst_methods(self: &mut Self, it: &TyInstance, mi_src: *mut Ast, mi_inst: TypeId, which: i32, with_body: bool) void {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        let mut inm = Buf200 {};
        self.inst_name(it, (&mut inm.b[0]) as *mut char, 200);
        let ifnv = self.inst_mentions_fnval(it);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 { i = i + 1; continue; }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != it.decl { i = i + 1; continue; }
            let itrait = self.extend_interface(nid);
            if itrait.node != NODE_NONE {
                let itty = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
                if !self.cg_type_satisfies(itty, itrait, 0) { i = i + 1; continue; }
            }
            if !self.cg_extend_bounds_hold(nid, (&it.args[0]) as *const TypeId, it.n) { i = i + 1; continue; }
            let gens = ed.generics;
            let gids = unsafe (*self.cur_ast()).list(gens);
            let ms = ed.items;
            let mids = unsafe (*self.cur_ast()).list(ms);
            let mut j: u32 = 0;
            while j < ms.len {
                let mid = unsafe mids[j as usize];
                let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
                let mk_kind = unsafe (*self.cur_ast()).at_const(mid).kind;
                if mk_kind != NodeKind::NODE_FUNCTION { j = j + 1; continue; }
                let mut skip = false;
                if with_body { skip = mf.body == NODE_NONE; }
                else { skip = mf.generics.len == 0 && !want_fn(which, !ifnv && mf.is_public); }
                if skip { j = j + 1; continue; }
                self.nsubst = 0;
                let mut g: u32 = 0;
                while g < gens.len && g < it.n as u32 && self.nsubst < 16 {
                    self.subst[self.nsubst as usize].param = DefId { module: self.cur_module(), node: unsafe gids[g as usize] };
                    self.subst[self.nsubst as usize].concrete = it.args[g as usize];
                    self.nsubst = self.nsubst + 1;
                    g = g + 1;
                }
                let mut nm = Buf320 {};
                let mut at = bappend((&mut nm.b[0]) as *mut char, 320, 0, (&inm.b[0]) as *const char);
                at = bappend((&mut nm.b[0]) as *mut char, 320, at, "__".ptr as *const char);
                let mnsp = self.name_span(mf.name);
                self.render_ident(mnsp, unsafe ((&mut nm.b[0]) as *mut char + at) as *mut char, 320 - at);
                let stat = self.multifile && (ifnv || !mf.is_public);
                if self.minst_only && mf.generics.len == 0 { self.nsubst = 0; j = j + 1; continue; }
                if mf.generics.len == 0 {
                    let mdef = DefId { module: self.cur_module(), node: mid };
                    if self.multifile && itrait.node == NODE_NONE && self.cg_attr(self.cur_module(), it.decl, AttrKind::ATTR_EMIT_MACRO) == null && !unsafe (*self.package).method_used_get(mdef) {
                        self.nsubst = 0;
                        j = j + 1;
                        continue;
                    }
                    if !with_body { self.emit_ret_struct_named(mid, (&nm.b[0]) as *const char); }
                    self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, with_body, (&nm.b[0]) as *const char, stat);
                    self.nsubst = 0;
                    j = j + 1;
                    continue;
                }
                let nimpl = self.nsubst;
                let mg = mf.generics;
                let mgids = unsafe (*self.cur_ast()).list(mg);
                let mut mk: usize = 0;
                while mk < unsafe (*mi_src).method_insts.len() {
                    let minst = unsafe *(*mi_src).method_insts.at(mk);
                    if minst.method != mid || minst.instance != mi_inst { mk = mk + 1; continue; }
                    self.nsubst = nimpl;
                    let mut fnval = ifnv;
                    let mut mgi: u32 = 0;
                    while mgi < mg.len && mgi < minst.n as u32 && self.nsubst < 16 {
                        let ta = if (mi_src == self.cur_ast()) { minst.targs[mgi as usize]; } else { unsafe (*self.cur_ast()).reintern(unsafe (&*mi_src), minst.targs[mgi as usize]); };
                        self.subst[self.nsubst as usize].param = DefId { module: self.cur_module(), node: unsafe mgids[mgi as usize] };
                        self.subst[self.nsubst as usize].concrete = ta;
                        if self.cg_type_mentions_fnval(ta) { fnval = true; }
                        self.nsubst = self.nsubst + 1;
                        mgi = mgi + 1;
                    }
                    let mut wf = false;
                    if fnval { wf = which != PROTO_PUBLIC; } else { wf = want_fn(which, mf.is_public); }
                    if !with_body && !wf { mk = mk + 1; continue; }
                    let mut snm = Buf400 {};
                    let mut a2 = bappend((&mut snm.b[0]) as *mut char, 400, 0, (&nm.b[0]) as *const char);
                    let mut gg: u8 = 0;
                    while gg < minst.n {
                        a2 = bappend((&mut snm.b[0]) as *mut char, 400, a2, "__".ptr as *const char);
                        let tg = if (mi_src == self.cur_ast()) { minst.targs[gg as usize]; } else { unsafe (*self.cur_ast()).reintern(unsafe (&*mi_src), minst.targs[gg as usize]); };
                        let mut e = Buf176 {};
                        self.mangle_type(tg, (&mut e.b[0]) as *mut char, 176);
                        a2 = bappend((&mut snm.b[0]) as *mut char, 400, a2, (&e.b[0]) as *const char);
                        gg = gg + 1;
                    }
                    if !with_body { self.emit_ret_struct_named(mid, (&snm.b[0]) as *const char); }
                    self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, with_body, (&snm.b[0]) as *const char, stat || fnval);
                    mk = mk + 1;
                }
                self.nsubst = 0;
                j = j + 1;
            }
            i = i + 1;
        }
    }
    fn emit_method_specializations(self: &mut Self, which: i32, with_body: bool) void {
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            if it.module != self.cur_module() { ii = ii + 1; continue; }
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { ii = ii + 1; continue; }
            let itTy = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
            let src = self.cur_ast();
            self.emit_inst_methods(&it, src, itTy, which, with_body);
            self.nsubst = 0;
            ii = ii + 1;
        }
    }
    fn emit_rehomed_methods(self: &mut Self, which: i32, with_body: bool) void {
        if self.package == null { return; }
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let home = self.cur_ast();
            let home_mod = unsafe (*home).module;
            let hsrc = self.source;
            let hlen = self.len;
            let it = *unsafe (*home).instance(ii as u32);
            if !self.inst_rehomed_here(&it) { ii = ii + 1; continue; }
            let itTy = unsafe (*home).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
            let owner = self.mod_ast(it.module);
            let osrc = self.mod_src(it.module);
            let oninst = unsafe (*owner).instances.len();
            let mut oit = it;
            let mut k: u8 = 0;
            while k < it.n { unsafe oit.args[k as usize] = unsafe (*owner).reintern(unsafe (&*home), it.args[k as usize]); k = k + 1; }
            self.source = osrc;
            self.len = unsafe (*self.package).modules.at(it.module as usize).source_len;
            self.borrowed = true;
            self.ast = self.mod_ast(it.module);
            self.emit_inst_methods(&oit, self.mod_ast(home_mod), itTy, which, with_body);
            unsafe (*self.cur_ast()).instances.truncate(oninst);
            self.borrowed = false;
            self.ast = home;
            self.source = hsrc;
            self.len = hlen;
            self.nsubst = 0;
            ii = ii + 1;
        }
    }
    fn emit_local_method_insts(self: &mut Self, which: i32, with_body: bool) void {
        if self.package == null || (!with_body && which == PROTO_PUBLIC) { return; }
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let home = self.cur_ast();
            let home_mod = unsafe (*home).module;
            let hsrc = self.source;
            let hlen = self.len;
            let it = *unsafe (*home).instance(ii as u32);
            if it.module == home_mod || it.module as usize >= self.pkg_count() || self.inst_rehomed_here(&it) { ii = ii + 1; continue; }
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { ii = ii + 1; continue; }
            let itTy = unsafe (*home).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
            let mut any = false;
            let mut mk: usize = 0;
            while mk < unsafe (*home).method_insts.len() && !any {
                if unsafe (*home).method_insts.at(mk).instance == itTy { any = true; }
                mk = mk + 1;
            }
            if !any { ii = ii + 1; continue; }
            let owner = self.mod_ast(it.module);
            let osrc = self.mod_src(it.module);
            let oninst = unsafe (*owner).instances.len();
            let mut oit = it;
            let mut k2: u8 = 0;
            while k2 < it.n { unsafe oit.args[k2 as usize] = unsafe (*owner).reintern(unsafe (&*home), it.args[k2 as usize]); k2 = k2 + 1; }
            self.source = osrc;
            self.len = unsafe (*self.package).modules.at(it.module as usize).source_len;
            self.borrowed = true;
            self.minst_only = true;
            self.ast = self.mod_ast(it.module);
            self.emit_inst_methods(&oit, self.mod_ast(home_mod), itTy, which, with_body);
            self.minst_only = false;
            unsafe (*self.cur_ast()).instances.truncate(oninst);
            self.borrowed = false;
            self.ast = home;
            self.source = hsrc;
            self.len = hlen;
            self.nsubst = 0;
            ii = ii + 1;
        }
    }
    fn emit_specializations(self: &mut Self, with_body: bool) void {
        let mut i: i32 = 0;
        while i < self.ninsts {
            let inst = self.insts[i as usize];
            let fn2 = inst.func;
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < inst.n { if !self.type_is_concrete(inst.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { i = i + 1; continue; }
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
                self.spec_name(fn2, (&inst.args[0]) as *const TypeId, inst.n as i32, (&mut nm.b[0]) as *mut char, 256);
                if !with_body { self.emit_ret_struct_named(fn2.node, (&nm.b[0]) as *const char); }
                self.emit_function(fn2.node, DefId { module: 0, node: NODE_NONE }, false, with_body, (&nm.b[0]) as *const char, true);
                self.nsubst = 0;
                i = i + 1;
                continue;
            }
            if self.package == null || fn2.module as usize >= self.pkg_count() { i = i + 1; continue; }
            let home = self.cur_ast();
            let hsrc = self.source;
            let hlen = self.len;
            let owner = self.mod_ast(fn2.module);
            let osrc = self.mod_src(fn2.module);
            let oninst = unsafe (*owner).instances.len();
            let mut oargs = TyArgs4 {};
            let mut k2: u8 = 0;
            while k2 < inst.n { unsafe oargs.t[k2 as usize] = unsafe (*owner).reintern(unsafe (&*home), inst.args[k2 as usize]); k2 = k2 + 1; }
            self.ast = owner;
            self.source = osrc;
            self.len = unsafe (*self.package).modules.at(fn2.module as usize).source_len;
            self.borrowed = true;
            let gens = unsafe (*self.cur_ast()).at_const(fn2.node).as_data.function.generics;
            let gids = unsafe (*self.cur_ast()).list(gens);
            self.nsubst = 0;
            let mut g: u32 = 0;
            while g < gens.len && g < inst.n as u32 && self.nsubst < 16 {
                self.subst[self.nsubst as usize].param = DefId { module: fn2.module, node: unsafe gids[g as usize] };
                self.subst[self.nsubst as usize].concrete = unsafe oargs.t[g as usize];
                self.nsubst = self.nsubst + 1;
                g = g + 1;
            }
            let mut nm = Buf256 {};
            self.spec_name(fn2, (&oargs.t[0]) as *const TypeId, inst.n as i32, (&mut nm.b[0]) as *mut char, 256);
            if !with_body { self.emit_ret_struct_named(fn2.node, (&nm.b[0]) as *const char); }
            self.emit_function(fn2.node, DefId { module: 0, node: NODE_NONE }, false, with_body, (&nm.b[0]) as *const char, true);
            self.nsubst = 0;
            unsafe (*self.cur_ast()).instances.truncate(oninst);
            self.borrowed = false;
            self.ast = home;
            self.source = hsrc;
            self.len = hlen;
            i = i + 1;
        }
    }
    fn emit_default_methods(self: &mut Self, which: i32, with_body: bool) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.interface_type == NODE_NONE || ed.target_type == NODE_NONE || ed.generics.len != 0 { i = i + 1; continue; }
            let iface = unsafe (*self.cur_ast()).resolution_def(ed.interface_type);
            let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
            if iface.node == NODE_NONE || target.node == NODE_NONE { i = i + 1; continue; }
            let foreign = iface.module != self.cur_module();
            if foreign && (self.package == null || iface.module as usize >= self.pkg_count()) { i = i + 1; continue; }
            let mut bb: i32 = -1;
            if self.package != null { bb = unsafe (*self.package).builtin_of_decl(target.module, target.node); }
            let tkind_is_enum = unsafe (*self.mod_ast(target.module)).at_const(target.node).kind == NodeKind::NODE_ENUM;
            let ia = self.mod_ast(iface.module);
            let mut tyv = Ty { kind: TypeKind::TYPE_STRUCT, module: target.module, as_data: TyAs { decl: target.node } };
            if bb >= 0 { tyv = Ty { kind: TypeKind::TYPE_BUILTIN, as_data: TyAs { builtin: bb as BuiltinType } }; }
            else if tkind_is_enum { tyv = Ty { kind: TypeKind::TYPE_ENUM, module: target.module, as_data: TyAs { decl: target.node } }; }
            let tty = unsafe (*ia).intern_type(tyv);
            let req = unsafe (*ia).at_const(iface.node).as_data.interface_def.items;
            let rids = unsafe (*ia).list(req);
            let have = ed.items;
            let hids = unsafe (*self.cur_ast()).list(have);
            let vis = unsafe (*ia).at_const(iface.node).as_data.interface_def.is_public && target.module == self.cur_module();
            let mut r: u32 = 0;
            while r < req.len {
                let rid = unsafe rids[r as usize];
                let rm = unsafe (*ia).at_const(rid);
                if rm.kind != NodeKind::NODE_FUNCTION || rm.as_data.function.body == NODE_NONE || rm.as_data.function.generics.len != 0 { r = r + 1; continue; }
                if !with_body && !want_fn(which, vis) { r = r + 1; continue; }
                let rmn = unsafe (*ia).at_const(rm.as_data.function.name).as_data.name.text;
                let mut overridden = false;
                let mut h: u32 = 0;
                while h < have.len && !overridden {
                    let hm = unsafe (*self.cur_ast()).at_const(unsafe hids[h as usize]);
                    if hm.kind == NodeKind::NODE_FUNCTION {
                        let hmn = unsafe (*self.cur_ast()).at_const(hm.as_data.function.name).as_data.name.text;
                        if cg_span_eq(self.source, hmn, self.mod_src(iface.module), rmn) { overridden = true; }
                    }
                    h = h + 1;
                }
                if overridden { r = r + 1; continue; }
                let home = self.cur_ast();
                let hsrc = self.source;
                let hlen = self.len;
                let mut oninst: usize = 0;
                if foreign {
                    self.source = self.mod_src(iface.module);
                    self.len = unsafe (*self.package).modules.at(iface.module as usize).source_len;
                    self.ast = self.mod_ast(iface.module);
                    self.borrowed = true;
                    self.dflt_home = unsafe (*home).module;
                    self.dflt_home_set = true;
                    oninst = unsafe (*self.cur_ast()).instances.len();
                }
                self.nsubst = 1;
                self.subst[0].param = iface;
                self.subst[0].concrete = tty;
                if !with_body { self.emit_ret_struct(rid, target); }
                let mut dnm = Buf256 {};
                self.function_name(rid, target, (&mut dnm.b[0]) as *mut char, 256, true);
                let stat = self.multifile && !vis;
                self.emit_function(rid, target, false, with_body, (&dnm.b[0]) as *const char, stat);
                self.nsubst = 0;
                if foreign {
                    unsafe (*self.cur_ast()).instances.truncate(oninst);
                    self.borrowed = false;
                    self.dflt_home_set = false;
                    self.ast = home;
                    self.source = hsrc;
                    self.len = hlen;
                }
                r = r + 1;
            }
            i = i + 1;
        }
    }
    fn emit_closure_fn(self: &mut Self, id: NodeId, with_body: bool) void {
        let cl = unsafe (*self.cur_ast()).at_const(id).as_data.closure;
        let caps = cl.captures.len != 0;
        let mut nm = Buf200 {};
        self.closure_name(id, (&mut nm.b[0]) as *mut char, 200);
        if caps && !with_body {
            self.emit_cstr("typedef struct { ".ptr as *const char);
            let cids = unsafe (*self.cur_ast()).list(cl.captures);
            let mut i: u32 = 0;
            while i < cl.captures.len {
                let cid = unsafe cids[i as usize];
                let mut fnm = Buf128 {};
                let csp = self.cg_decl_name_span(cid);
                self.render_ident(csp, (&mut fnm.b[0]) as *mut char, 128);
                let mut ft = unsafe (*self.cur_ast()).type_of(cid);
                if ((cl.mut_caps >> (i as u64)) & (1 as u64)) != 0 as u64 {
                    ft = unsafe (*self.cur_ast()).intern_type(Ty { kind: TypeKind::TYPE_POINTER, qualifier: TypeQualifier::TYPE_QUAL_MUT as u8, as_data: TyAs { elem: ft } });
                }
                let mut d = Buf300 {};
                self.render_type_id(ft, (&fnm.b[0]) as *const char, (&mut d.b[0]) as *mut char, 300);
                self.emit("%s; ".ptr as *const char, (&d.b[0]) as *const char);
                i = i + 1;
            }
            self.emit("} %s_env;\n".ptr as *const char, (&nm.b[0]) as *const char);
            let fnty = Ty { kind: TypeKind::TYPE_FUNCTION, module: self.cur_module(), as_data: TyAs { decl: id } };
            if self.cg_fn_owns(&fnty) {
                self.emit("static __attribute__((unused)) void %s_env_free(%s_env *const __e) { ".ptr as *const char, (&nm.b[0]) as *const char, (&nm.b[0]) as *const char);
                let mut i2: u32 = 0;
                while i2 < cl.captures.len {
                    let cid = unsafe cids[i2 as usize];
                    if (((cl.mut_caps >> (i2 as u64)) & (1 as u64)) != 0 as u64) || !self.cg_type_is_free(unsafe (*self.cur_ast()).type_of(cid)) { i2 = i2 + 1; continue; }
                    let mut fnm = Buf128 {};
                    let csp = self.cg_decl_name_span(cid);
                    self.render_ident(csp, (&mut fnm.b[0]) as *mut char, 128);
                    if self.emit_free_target(unsafe (*self.cur_ast()).type_of(cid)) {
                        self.emit("(&__e->%s); ".ptr as *const char, (&fnm.b[0]) as *const char);
                    }
                    i2 = i2 + 1;
                }
                self.emit_cstr("}\n".ptr as *const char);
            }
        }
        let mut ps = Buf1024 {};
        self.render_params(cl.params, (&mut ps.b[0]) as *mut char, 1024);
        let mut decl = Buf1320 {};
        let mut at = bappend((&mut decl.b[0]) as *mut char, 1320, 0, (&nm.b[0]) as *const char);
        at = bappend((&mut decl.b[0]) as *mut char, 1320, at, "(".ptr as *const char);
        if caps {
            at = bappend((&mut decl.b[0]) as *mut char, 1320, at, "const ".ptr as *const char);
            at = bappend((&mut decl.b[0]) as *mut char, 1320, at, (&nm.b[0]) as *const char);
            at = bappend((&mut decl.b[0]) as *mut char, 1320, at, "_env *const __env".ptr as *const char);
            if unsafe cstring::strcmp((&ps.b[0]) as *const char, "void".ptr as *const char) != 0 {
                at = bappend((&mut decl.b[0]) as *mut char, 1320, at, ", ".ptr as *const char);
                at = bappend((&mut decl.b[0]) as *mut char, 1320, at, (&ps.b[0]) as *const char);
            }
        } else {
            at = bappend((&mut decl.b[0]) as *mut char, 1320, at, (&ps.b[0]) as *const char);
        }
        bappend((&mut decl.b[0]) as *mut char, 1320, at, ")".ptr as *const char);

        let body = cl.body;
        let expr_body = cl.expr_body;
        let mut rt = TYPE_NONE;
        if expr_body { rt = unsafe (*self.cur_ast()).type_of(body); }
        self.emit_cstr("static __attribute__((unused)) ".ptr as *const char);
        let mut out = Buf1400 {};
        if expr_body {
            self.render_type_id(rt, (&decl.b[0]) as *const char, (&mut out.b[0]) as *mut char, 1400);
        } else {
            let rets = cl.returns;
            if rets.len == 1 {
                let r0 = unsafe ((*self.cur_ast()).list(rets))[0];
                let rn = unsafe (*self.cur_ast()).at_const(r0);
                let rtn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { r0; };
                self.render_type_node(rtn, (&decl.b[0]) as *const char, (&mut out.b[0]) as *mut char, 1400);
            } else {
                buf_join3((&mut out.b[0]) as *mut char, 1400, "void ".ptr as *const char, "".ptr as *const char, (&decl.b[0]) as *const char);
            }
        }
        self.emit_cstr((&out.b[0]) as *const char);
        if !with_body {
            self.emit_cstr(";\n".ptr as *const char);
            return;
        }
        unsafe self.current_ret[0] = 0 as char;
        let saved_env = self.env_clos;
        self.env_clos = if caps { id; } else { NODE_NONE; };
        if expr_body {
            let mut is_void = false;
            if rt != TYPE_NONE {
                let rty = *self.type_at(rt);
                is_void = rty.kind == TypeKind::TYPE_BUILTIN && rty.as_data.builtin == BuiltinType::BT_VOID;
            }
            self.emit_cstr(" {\n".ptr as *const char);
            self.depth = self.depth + 1;
            self.emit_indent();
            if !is_void { self.emit_cstr("return ".ptr as *const char); }
            self.emit_expr(body);
            self.emit_cstr(";\n".ptr as *const char);
            self.depth = self.depth - 1;
            self.emit_cstr("}\n\n".ptr as *const char);
        } else {
            self.emit_cstr(" ".ptr as *const char);
            self.defer_top = 0;
            self.loop_defer_base = 0;
            self.emit_block(body);
            self.emit_cstr("\n\n".ptr as *const char);
        }
        self.env_clos = saved_env;
    }
    fn emit_closures(self: &mut Self, with_body: bool) void {
        let mut i: usize = 0;
        while i < unsafe (*self.cur_ast()).nodes.len() {
            if unsafe (*self.cur_ast()).at_const(i as NodeId).kind == NodeKind::NODE_CLOSURE {
                self.emit_closure_fn(i as NodeId, with_body);
            }
            i = i + 1;
        }
    }
    fn cb_specialized_away(self: &Self, fnId: NodeId) bool {
        let fk = unsafe (*self.cur_ast()).at_const(fnId).kind;
        let fpub = unsafe (*self.cur_ast()).at_const(fnId).as_data.function.is_public;
        if fk != NodeKind::NODE_FUNCTION || fpub { return false; }
        let mut any = false;
        let mut i: i32 = 0;
        while i < self.n_cb_insts && !any {
            if self.cb_insts[i as usize].func.node == fnId && self.cb_insts[i as usize].func.module == self.cur_module() { any = true; }
            i = i + 1;
        }
        if !any { return false; }
        let mut j: i32 = 0;
        while j < self.n_cb_keep { if self.cb_keep_fns[j as usize] == fnId { return false; } j = j + 1; }
        return true;
    }
    fn collect_callbacks(self: &mut Self) void {
        self.n_cb_insts = 0;
        self.n_cb_keep = 0;
        let nn = unsafe (*self.cur_ast()).nodes.len();
        let mut i: u32 = 0;
        while (i as usize) < nn {
            let ck = unsafe (*self.cur_ast()).at_const(i).kind;
            if ck != NodeKind::NODE_CALL { i = i + 1; continue; }
            let callee_id = unsafe (*self.cur_ast()).at_const(i).as_data.call.callee;
            if unsafe (*self.cur_ast()).at_const(callee_id).kind != NodeKind::NODE_IDENTIFIER { i = i + 1; continue; }
            let fn2 = unsafe (*self.cur_ast()).resolution_def(callee_id);
            if fn2.module != self.cur_module() || fn2.node == NODE_NONE { i = i + 1; continue; }
            let fnk = unsafe (*self.cur_ast()).at_const(fn2.node).kind;
            let ff = unsafe (*self.cur_ast()).at_const(fn2.node).as_data.function;
            if fnk != NodeKind::NODE_FUNCTION || ff.generics.len != 0 || ff.body == NODE_NONE { i = i + 1; continue; }
            if !self.decl_is_toplevel(fn2.module, fn2.node) { i = i + 1; continue; }
            let mut cbidx: u32 = 0;
            let mut param: NodeId = NODE_NONE;
            let single = self.cb_single_callback_param(fn2.node, (&mut cbidx) as *mut u32, (&mut param) as *mut NodeId);
            if !single || !self.param_only_callee(param) { i = i + 1; continue; }
            let args = unsafe (*self.cur_ast()).at_const(i).as_data.call.args;
            let aids = unsafe (*self.cur_ast()).list(args);
            let mut callee = DefId { module: 0, node: NODE_NONE };
            let mut isclo = false;
            let known = if cbidx < args.len { self.cb_known_callee(unsafe aids[cbidx as usize], (&mut callee) as *mut DefId, (&mut isclo) as *mut bool); } else { false; };
            if known {
                self.cb_record(fn2, param, cbidx, callee, isclo);
            } else {
                self.cb_keep(fn2.node);
            }
            i = i + 1;
        }
    }
    fn emit_callback_specializations(self: &mut Self, with_body: bool) void {
        let mut i: i32 = 0;
        while i < self.n_cb_insts {
            let ci = self.cb_insts[i as usize];
            if ci.func.module != self.cur_module() { i = i + 1; continue; }
            self.cb_param = ci.param;
            self.cb_callee = ci.callee;
            self.cb_callee_closure = ci.callee_closure;
            let mut nm = Buf300 {};
            self.cb_spec_name(ci.func, self.cb_callee, self.cb_callee_closure, (&mut nm.b[0]) as *mut char, 300);
            self.emit_function(ci.func.node, DefId { module: 0, node: NODE_NONE }, false, with_body, (&nm.b[0]) as *const char, true);
            self.cb_param = NODE_NONE;
            i = i + 1;
        }
    }
    fn emit_dyn_typedefs(self: &mut Self) void {
        let mut i: usize = 0;
        while i < unsafe (*self.cur_ast()).type_pool.len() {
            let dy = *unsafe (*self.cur_ast()).type_at(i as TypeId);
            if dy.kind != TypeKind::TYPE_DYN { i = i + 1; continue; }
            let mut seen = false;
            let mut j: usize = 0;
            while j < i && !seen {
                let pj = *unsafe (*self.cur_ast()).type_at(j as TypeId);
                if pj.kind == TypeKind::TYPE_DYN && pj.module == dy.module && pj.as_data.decl == dy.as_data.decl { seen = true; }
                j = j + 1;
            }
            if seen { i = i + 1; continue; }
            let mut stem = Buf176 {};
            self.dyn_stem(dy.module, dy.as_data.decl, (&mut stem.b[0]) as *mut char, 176);
            let sp = (&stem.b[0]) as *const char;
            let idn_kind = unsafe (*self.mod_ast(dy.module)).at_const(dy.as_data.decl).kind;
            self.emit("#ifndef SC_DYN_%s\n#define SC_DYN_%s\n".ptr as *const char, sp, sp);
            self.emit("typedef struct %s__vt {\n    void (*__free)(void *self);\n".ptr as *const char, sp);
            if idn_kind == NodeKind::NODE_FUNCTION_TYPE {
                let ftp = unsafe (*self.mod_ast(dy.module)).at_const(dy.as_data.decl).as_data.function_type.params;
                let pid = unsafe (*self.mod_ast(dy.module)).list(ftp);
                let mut inner = Buf512 {};
                let mut at = bappend((&mut inner.b[0]) as *mut char, 512, 0, "(*call)(void *self".ptr as *const char);
                let mut p: u32 = 0;
                while p < ftp.len {
                    let src_ty = unsafe (*self.mod_ast(dy.module)).type_of(unsafe pid[p as usize]);
                    let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(dy.module)), src_ty);
                    let mut pt = Buf200 {};
                    self.render_type_id(pt_ty, "".ptr as *const char, (&mut pt.b[0]) as *mut char, 200);
                    at = bappend((&mut inner.b[0]) as *mut char, 512, at, ", ".ptr as *const char);
                    at = bappend((&mut inner.b[0]) as *mut char, 512, at, (&pt.b[0]) as *const char);
                    p = p + 1;
                }
                bappend((&mut inner.b[0]) as *mut char, 512, at, ")".ptr as *const char);
                let rt = self.cg_dynfn_ret(dy.module, dy.as_data.decl);
                let mut memb = Buf600 {};
                if rt != TYPE_NONE { self.render_type_id(rt, (&inner.b[0]) as *const char, (&mut memb.b[0]) as *mut char, 600); }
                else { buf_join3((&mut memb.b[0]) as *mut char, 600, "void ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char); }
                self.emit("    %s;\n".ptr as *const char, (&memb.b[0]) as *const char);
                self.emit("} %s__vt;\ntypedef struct %s__dyn { void *data; const %s__vt *vt; } %s__dyn;\n".ptr as *const char, sp, sp, sp, sp);
                self.emit("static inline void %s__dyn_free(%s__dyn *const d) { d->vt->__free(d->data); }\n#endif\n".ptr as *const char, sp, sp);
                i = i + 1;
                continue;
            }
            let idn_items = unsafe (*self.mod_ast(dy.module)).at_const(dy.as_data.decl).as_data.interface_def.items;
            let mids = unsafe (*self.mod_ast(dy.module)).list(idn_items);
            let mut km: u32 = 0;
            while km < idn_items.len {
                let mid = unsafe mids[km as usize];
                if !self.cg_dyn_method(dy.module, mid) { km = km + 1; continue; }
                let mname_node = unsafe (*self.mod_ast(dy.module)).at_const(mid).as_data.function.name;
                let mut mn = Buf128 {};
                render_ident_src(self.mod_src(dy.module), unsafe (*self.mod_ast(dy.module)).at_const(mname_node).as_data.name.text, (&mut mn.b[0]) as *mut char, 128);
                let mparams = unsafe (*self.mod_ast(dy.module)).at_const(mid).as_data.function.params;
                let pids = unsafe (*self.mod_ast(dy.module)).list(mparams);
                let mut inner = Buf512 {};
                let mut at = bappend((&mut inner.b[0]) as *mut char, 512, 0, "(*".ptr as *const char);
                at = bappend((&mut inner.b[0]) as *mut char, 512, at, (&mn.b[0]) as *const char);
                at = bappend((&mut inner.b[0]) as *mut char, 512, at, ")(void *self".ptr as *const char);
                let mut p: u32 = 1;
                while p < mparams.len {
                    let ptn = unsafe (*self.mod_ast(dy.module)).at_const(unsafe pids[p as usize]).as_data.parameter.ty;
                    let src_ty = unsafe (*self.mod_ast(dy.module)).type_of(ptn);
                    let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(dy.module)), src_ty);
                    let mut pt = Buf200 {};
                    self.render_type_id(pt_ty, "".ptr as *const char, (&mut pt.b[0]) as *mut char, 200);
                    at = bappend((&mut inner.b[0]) as *mut char, 512, at, ", ".ptr as *const char);
                    at = bappend((&mut inner.b[0]) as *mut char, 512, at, (&pt.b[0]) as *const char);
                    p = p + 1;
                }
                bappend((&mut inner.b[0]) as *mut char, 512, at, ")".ptr as *const char);
                let rt = self.cg_dyn_ret(dy.module, mid);
                let mut memb = Buf600 {};
                if rt != TYPE_NONE { self.render_type_id(rt, (&inner.b[0]) as *const char, (&mut memb.b[0]) as *mut char, 600); }
                else { buf_join3((&mut memb.b[0]) as *mut char, 600, "void ".ptr as *const char, "".ptr as *const char, (&inner.b[0]) as *const char); }
                self.emit("    %s;\n".ptr as *const char, (&memb.b[0]) as *const char);
                km = km + 1;
            }
            self.emit("} %s__vt;\ntypedef struct %s__dyn { void *data; const %s__vt *vt; } %s__dyn;\n".ptr as *const char, sp, sp, sp, sp);
            self.emit("static inline void %s__dyn_free(%s__dyn *const d) { d->vt->__free(d->data); }\n#endif\n".ptr as *const char, sp, sp);
            i = i + 1;
        }
    }
    fn emit_dynfn_table(self: &mut Self, src: TypeId, dy: Ty) void {
        let sy = *unsafe (*self.cur_ast()).type_at(src);
        let fd_kind = unsafe (*self.mod_ast(sy.module)).at_const(sy.as_data.decl).kind;
        let capt = self.cg_fn_is_capturing(&sy);
        let mut pair = Buf368 {};
        self.dyn_pair_stem(src, dy.module, dy.as_data.decl, (&mut pair.b[0]) as *mut char, 368);
        let pp = (&pair.b[0]) as *const char;
        let sig_params = unsafe (*self.mod_ast(dy.module)).at_const(dy.as_data.decl).as_data.function_type.params;
        let rt = self.cg_dynfn_ret(dy.module, dy.as_data.decl);
        let mut rts = Buf256 {};
        if rt != TYPE_NONE { self.render_type_id(rt, "".ptr as *const char, (&mut rts.b[0]) as *mut char, 256); }
        else { bappend((&mut rts.b[0]) as *mut char, 256, 0, "void".ptr as *const char); }
        self.emit("static __attribute__((unused)) %s %s__call(void *__self".ptr as *const char, (&rts.b[0]) as *const char, pp);
        let pid = unsafe (*self.mod_ast(dy.module)).list(sig_params);
        let mut p: u32 = 0;
        while p < sig_params.len {
            let mut an = Buf32 {};
            unsafe stdio::snprintf((&mut an.b[0]) as *mut char, 16, "_a%u".ptr as *const char, p);
            let src_ty = unsafe (*self.mod_ast(dy.module)).type_of(unsafe pid[p as usize]);
            let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(dy.module)), src_ty);
            let mut pd = Buf240 {};
            self.render_type_id(pt_ty, (&an.b[0]) as *const char, (&mut pd.b[0]) as *mut char, 240);
            self.emit(", %s".ptr as *const char, (&pd.b[0]) as *const char);
            p = p + 1;
        }
        self.emit_cstr(") { ".ptr as *const char);
        if !capt { self.emit_cstr("(void)__self; ".ptr as *const char); }
        if rt != TYPE_NONE { self.emit_cstr("return ".ptr as *const char); }
        let mut sym = Buf240 {};
        if fd_kind == NodeKind::NODE_CLOSURE { self.closure_sym_in(sy.module, sy.as_data.decl, (&mut sym.b[0]) as *mut char, 240); }
        else {
            let fname = unsafe (*self.mod_ast(sy.module)).at_const(sy.as_data.decl).as_data.function.name;
            self.render_qualified(sy.module, fname, (&mut sym.b[0]) as *mut char, 240);
        }
        self.emit_cstr((&sym.b[0]) as *const char);
        self.emit_cstr("(".ptr as *const char);
        let mut wrote = false;
        let mut envn = Buf256 {};
        if capt {
            self.render_type_id(src, "".ptr as *const char, (&mut envn.b[0]) as *mut char, 256);
            self.emit("(const %s *)__self".ptr as *const char, (&envn.b[0]) as *const char);
            wrote = true;
        }
        let mut p2: u32 = 0;
        while p2 < sig_params.len {
            if wrote || p2 != 0 { self.emit_cstr(", ".ptr as *const char); }
            self.emit("_a%u".ptr as *const char, p2);
            wrote = true;
            p2 = p2 + 1;
        }
        self.emit_cstr("); }\n".ptr as *const char);
        let mut owned = false;
        let mut jj: usize = 0;
        while jj < unsafe (*self.cur_ast()).dyn_uses.len() && !owned {
            let oju = *unsafe (*self.cur_ast()).dyn_uses.at(jj);
            if oju.src == src {
                let oy = *unsafe (*self.cur_ast()).type_at(oju.dyn_ty);
                if oy.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 { owned = true; }
            }
            jj = jj + 1;
        }
        if owned && self.package != null {
            let hit = unsafe (*self.package).prelude_lookup("Global".ptr as *const char, 6, true);
            let gname = unsafe (*self.mod_ast(hit.mid)).at_const(hit.node).as_data.aggregate.name;
            let mut gt = Buf160 {};
            self.render_qualified(hit.mid, gname, (&mut gt.b[0]) as *mut char, 160);
            let gtp = (&gt.b[0]) as *const char;
            self.emit("static void %s____free(void *__self) {\n".ptr as *const char, pp);
            if capt {
                if self.cg_fn_owns(&sy) {
                    let mut csym = Buf240 {};
                    self.closure_sym_in(sy.module, sy.as_data.decl, (&mut csym.b[0]) as *mut char, 240);
                    self.emit("    %s_env_free((%s *)__self);\n".ptr as *const char, (&csym.b[0]) as *const char, (&envn.b[0]) as *const char);
                }
                self.emit("    %s __g = %s__default_();\n    %s__dealloc(&__g, __self, sizeof(%s), _Alignof(%s));\n".ptr as *const char, gtp, gtp, gtp, (&envn.b[0]) as *const char, (&envn.b[0]) as *const char);
            } else {
                self.emit_cstr("    (void)__self;\n".ptr as *const char);
            }
            self.emit_cstr("}\n".ptr as *const char);
        }
        let mut stem = Buf176 {};
        self.dyn_stem(dy.module, dy.as_data.decl, (&mut stem.b[0]) as *mut char, 176);
        self.emit("static const %s__vt %s__vtbl __attribute__((unused)) = { ".ptr as *const char, (&stem.b[0]) as *const char, pp);
        if owned { self.emit("%s____free".ptr as *const char, pp); } else { self.emit_cstr("0".ptr as *const char); }
        self.emit(", %s__call };\n".ptr as *const char, pp);
    }
    fn emit_dyn_tables(self: &mut Self) void {
        let n = unsafe (*self.cur_ast()).dyn_uses.len();
        let mut i: usize = 0;
        while i < n {
            let dui = *unsafe (*self.cur_ast()).dyn_uses.at(i);
            if dui.src == TYPE_NONE { i = i + 1; continue; }
            let dy = *unsafe (*self.cur_ast()).type_at(dui.dyn_ty);
            let mut istem = Buf176 {};
            self.dyn_stem(dy.module, dy.as_data.decl, (&mut istem.b[0]) as *mut char, 176);
            let mut seen = false;
            let mut j: usize = 0;
            while j < i && !seen {
                let duj = *unsafe (*self.cur_ast()).dyn_uses.at(j);
                if duj.src != dui.src { j = j + 1; continue; }
                let pj = *unsafe (*self.cur_ast()).type_at(duj.dyn_ty);
                if pj.module == dy.module && pj.as_data.decl == dy.as_data.decl { seen = true; }
                else {
                    let mut jstem = Buf176 {};
                    self.dyn_stem(pj.module, pj.as_data.decl, (&mut jstem.b[0]) as *mut char, 176);
                    if unsafe cstring::strcmp((&istem.b[0]) as *const char, (&jstem.b[0]) as *const char) == 0 { seen = true; }
                }
                j = j + 1;
            }
            if seen { i = i + 1; continue; }
            let src = dui.src;
            let sy = *unsafe (*self.cur_ast()).type_at(src);
            if unsafe (*self.mod_ast(dy.module)).at_const(dy.as_data.decl).kind == NodeKind::NODE_FUNCTION_TYPE {
                self.emit_dynfn_table(src, dy);
                i = i + 1;
                continue;
            }
            let mut tm: ModuleId = 0;
            let mut td: NodeId = NODE_NONE;
            if !self.cg_dyn_target(&sy, (&mut tm) as *mut ModuleId, (&mut td) as *mut NodeId) { i = i + 1; continue; }
            let mut pair = Buf368 {};
            self.dyn_pair_stem(src, dy.module, dy.as_data.decl, (&mut pair.b[0]) as *mut char, 368);
            let pp = (&pair.b[0]) as *const char;
            let mut recv = Buf256 {};
            self.render_type_id(src, "".ptr as *const char, (&mut recv.b[0]) as *mut char, 256);
            let rvp = (&recv.b[0]) as *const char;
            let idn_items = unsafe (*self.mod_ast(dy.module)).at_const(dy.as_data.decl).as_data.interface_def.items;
            let mids = unsafe (*self.mod_ast(dy.module)).list(idn_items);
            let mut km: u32 = 0;
            while km < idn_items.len {
                let mid = unsafe mids[km as usize];
                if !self.cg_dyn_method(dy.module, mid) { km = km + 1; continue; }
                let mnamenode = unsafe (*self.mod_ast(dy.module)).at_const(mid).as_data.function.name;
                let mspan = unsafe (*self.mod_ast(dy.module)).at_const(mnamenode).as_data.name.text;
                let mut mn = Buf128 {};
                render_ident_src(self.mod_src(dy.module), mspan, (&mut mn.b[0]) as *mut char, 128);
                let rt = self.cg_dyn_ret(dy.module, mid);
                let mut rts = Buf256 {};
                if rt != TYPE_NONE { self.render_type_id(rt, "".ptr as *const char, (&mut rts.b[0]) as *mut char, 256); }
                else { bappend((&mut rts.b[0]) as *mut char, 256, 0, "void".ptr as *const char); }
                self.emit("static __attribute__((unused)) %s %s__%s(void *__self".ptr as *const char, (&rts.b[0]) as *const char, pp, (&mn.b[0]) as *const char);
                let mparams = unsafe (*self.mod_ast(dy.module)).at_const(mid).as_data.function.params;
                let pids = unsafe (*self.mod_ast(dy.module)).list(mparams);
                let mut p: u32 = 1;
                while p < mparams.len {
                    let mut an = Buf32 {};
                    unsafe stdio::snprintf((&mut an.b[0]) as *mut char, 16, "_a%u".ptr as *const char, p);
                    let ptn = unsafe (*self.mod_ast(dy.module)).at_const(unsafe pids[p as usize]).as_data.parameter.ty;
                    let src_ty = unsafe (*self.mod_ast(dy.module)).type_of(ptn);
                    let pt_ty = unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(dy.module)), src_ty);
                    let mut pd = Buf240 {};
                    self.render_type_id(pt_ty, (&an.b[0]) as *const char, (&mut pd.b[0]) as *mut char, 240);
                    self.emit(", %s".ptr as *const char, (&pd.b[0]) as *const char);
                    p = p + 1;
                }
                if rt != TYPE_NONE { self.emit_cstr(") { return ".ptr as *const char); } else { self.emit_cstr(") { ".ptr as *const char); }
                let mut cm = self.cg_find_method(tm, td, self.mod_src(dy.module), mspan);
                if cm.node == NODE_NONE { cm = DefId { module: dy.module, node: mid }; }
                self.emit_op_method(sy, tm, td, cm);
                self.emit("((%s *)__self".ptr as *const char, rvp);
                let mut p2: u32 = 1;
                while p2 < mparams.len { self.emit(", _a%u".ptr as *const char, p2); p2 = p2 + 1; }
                self.emit_cstr("); }\n".ptr as *const char);
                km = km + 1;
            }
            let mut owned = false;
            let mut ojo: usize = 0;
            while ojo < unsafe (*self.cur_ast()).dyn_uses.len() && !owned {
                let du = *unsafe (*self.cur_ast()).dyn_uses.at(ojo);
                let oy = *unsafe (*self.cur_ast()).type_at(du.dyn_ty);
                if du.src == src && oy.module == dy.module && oy.as_data.decl == dy.as_data.decl && oy.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 { owned = true; }
                ojo = ojo + 1;
            }
            if owned && self.package != null {
                let hit = unsafe (*self.package).prelude_lookup("Global".ptr as *const char, 6, true);
                let gname = unsafe (*self.mod_ast(hit.mid)).at_const(hit.node).as_data.aggregate.name;
                let mut gt = Buf160 {};
                self.render_qualified(hit.mid, gname, (&mut gt.b[0]) as *mut char, 160);
                let gtp = (&gt.b[0]) as *const char;
                self.emit("static void %s____free(void *__self) {\n".ptr as *const char, pp);
                if self.cg_type_is_free(src) {
                    self.emit_cstr("    ".ptr as *const char);
                    self.emit_free_target(src);
                    self.emit("((%s *)__self);\n".ptr as *const char, rvp);
                }
                self.emit("    %s __g = %s__default_();\n    %s__dealloc(&__g, __self, sizeof(%s), _Alignof(%s));\n}\n".ptr as *const char, gtp, gtp, gtp, rvp, rvp);
            }
            let mut stem = Buf176 {};
            self.dyn_stem(dy.module, dy.as_data.decl, (&mut stem.b[0]) as *mut char, 176);
            self.emit("static const %s__vt %s__vtbl __attribute__((unused)) = { ".ptr as *const char, (&stem.b[0]) as *const char, pp);
            if owned { self.emit("%s____free".ptr as *const char, pp); } else { self.emit_cstr("0".ptr as *const char); }
            let mut km2: u32 = 0;
            while km2 < idn_items.len {
                let mid = unsafe mids[km2 as usize];
                if !self.cg_dyn_method(dy.module, mid) { km2 = km2 + 1; continue; }
                let mnamenode = unsafe (*self.mod_ast(dy.module)).at_const(mid).as_data.function.name;
                let mut mn = Buf128 {};
                render_ident_src(self.mod_src(dy.module), unsafe (*self.mod_ast(dy.module)).at_const(mnamenode).as_data.name.text, (&mut mn.b[0]) as *mut char, 128);
                self.emit(", %s__%s".ptr as *const char, pp, (&mn.b[0]) as *const char);
                km2 = km2 + 1;
            }
            self.emit_cstr(" };\n".ptr as *const char);
            i = i + 1;
        }
        if unsafe (*self.cur_ast()).dyn_uses.len() != 0 { self.emit_cstr("\n".ptr as *const char); }
    }
    fn emit_layout_asserts(self: &mut Self) void {
        let ce = self.ceval();
        if ce == null { return; }
        let mut any = false;
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            let ng = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate.generics.len;
            if (nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM) || ng != 0 { i = i + 1; continue; }
            if nk == NodeKind::NODE_ENUM && !self.aggregate_has_payload(nid) { i = i + 1; continue; }
            let tkind = if (nk == NodeKind::NODE_ENUM) { TypeKind::TYPE_ENUM; } else { TypeKind::TYPE_STRUCT; };
            let t = unsafe (*self.cur_ast()).intern_type(Ty { kind: tkind, module: self.cur_module(), as_data: TyAs { decl: nid } });
            let lo = unsafe (*ce).layout(self.cur_module(), t);
            if !lo.ok { i = i + 1; continue; }
            let mut nm = Buf256 {};
            self.render_type_id(t, "".ptr as *const char, (&mut nm.b[0]) as *mut char, 256);
            self.emit("_Static_assert(sizeof(%s) == %llu && _Alignof(%s) == %llu, \"super-c layout model mismatch: %s\");\n".ptr as *const char, (&nm.b[0]) as *const char, lo.size, (&nm.b[0]) as *const char, lo.align, (&nm.b[0]) as *const char);
            any = true;
            i = i + 1;
        }
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            if it.module != self.cur_module() { ii = ii + 1; continue; }
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete || self.inst_mentions_fnval(&it) { ii = ii + 1; continue; }
            let t = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
            let lo = unsafe (*ce).layout(self.cur_module(), t);
            if !lo.ok { ii = ii + 1; continue; }
            let mut nm = Buf256 {};
            self.render_type_id(t, "".ptr as *const char, (&mut nm.b[0]) as *mut char, 256);
            self.emit("_Static_assert(sizeof(%s) == %llu && _Alignof(%s) == %llu, \"super-c layout model mismatch: %s\");\n".ptr as *const char, (&nm.b[0]) as *const char, lo.size, (&nm.b[0]) as *const char, lo.align, (&nm.b[0]) as *const char);
            any = true;
            ii = ii + 1;
        }
        if any { self.emit_cstr("\n".ptr as *const char); }
    }
    fn emit_toplevel_const(self: &mut Self, id: NodeId) void {
        let cd = unsafe (*self.cur_ast()).at_const(id).as_data.const_def;
        let mut nm = Buf160 {};
        self.render_qualified(self.cur_module(), cd.name, (&mut nm.b[0]) as *mut char, 160);
        let mut decl = Buf256 {};
        self.render_type_node(cd.ty, (&nm.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 256);
        if cd.is_static_mut {
            if !cd.is_public { self.emit_cstr("static ".ptr as *const char); }
            self.emit_cstr((&decl.b[0]) as *const char);
            self.emit_cstr(" = ".ptr as *const char);
            self.emit_initializer(cd.ty, cd.value);
            self.emit_cstr(";\n".ptr as *const char);
            return;
        }
        if self.ceval() != null { self.emit_cstr("__attribute__((unused)) ".ptr as *const char); }
        self.emit_cstr("static const ".ptr as *const char);
        self.emit_cstr((&decl.b[0]) as *const char);
        if cd.value != NODE_NONE {
            self.emit_cstr(" = ".ptr as *const char);
            self.emit_initializer(cd.ty, cd.value);
        }
        self.emit_cstr(";\n".ptr as *const char);
    }
    fn emit_assoc_consts(self: &mut Self, public_pass: bool) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len != 0 || ed.target_type == NODE_NONE { i = i + 1; continue; }
            let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
            if target.node == NODE_NONE { i = i + 1; continue; }
            let mids = unsafe (*self.cur_ast()).list(ed.items);
            let mut j: u32 = 0;
            while j < ed.items.len {
                let mid = unsafe mids[j as usize];
                let cnk = unsafe (*self.cur_ast()).at_const(mid).kind;
                if cnk != NodeKind::NODE_CONST { j = j + 1; continue; }
                let cd = unsafe (*self.cur_ast()).at_const(mid).as_data.const_def;
                if self.multifile && cd.is_public != public_pass { j = j + 1; continue; }
                let mut nm = Buf256 {};
                let np = (&mut nm.b[0]) as *mut char;
                let mut k = self.render_modpfx(self.cur_module(), np, 256);
                let mut bb: i32 = -1;
                if self.package != null { bb = unsafe (*self.package).builtin_of_decl(target.module, target.node); }
                if bb >= 0 {
                    k = bappend(np, 256, k, builtin_name(bb as BuiltinType));
                } else {
                    let tsp = self.name_span_in(target.module, self.cg_decl_name_node(target.module, target.node));
                    k = k + render_ident_src(self.mod_src(target.module), tsp, unsafe (np + k) as *mut char, 256 - k);
                }
                k = bappend(np, 256, k, "__".ptr as *const char);
                let csp = self.name_span(cd.name);
                self.render_ident(csp, unsafe (np + k) as *mut char, 256 - k);
                let mut decl = Buf320 {};
                self.render_type_node(cd.ty, np as *const char, (&mut decl.b[0]) as *mut char, 320);
                if self.ceval() != null { self.emit_cstr("__attribute__((unused)) ".ptr as *const char); }
                self.emit_cstr("static const ".ptr as *const char);
                self.emit_cstr((&decl.b[0]) as *const char);
                self.emit_cstr(" = ".ptr as *const char);
                self.emit_initializer(cd.ty, cd.value);
                self.emit_cstr(";\n".ptr as *const char);
                j = j + 1;
            }
            i = i + 1;
        }
    }
    fn emit_public_consts(self: &mut Self) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_CONST { i = i + 1; continue; }
            let cd = unsafe (*self.cur_ast()).at_const(nid).as_data.const_def;
            if !cd.is_public { i = i + 1; continue; }
            if cd.is_static_mut {
                let mut nm = Buf160 {};
                self.render_qualified(self.cur_module(), cd.name, (&mut nm.b[0]) as *mut char, 160);
                let mut decl = Buf256 {};
                self.render_type_node(cd.ty, (&nm.b[0]) as *const char, (&mut decl.b[0]) as *mut char, 256);
                self.emit_cstr("extern ".ptr as *const char);
                self.emit_cstr((&decl.b[0]) as *const char);
                self.emit_cstr(";\n".ptr as *const char);
            } else {
                self.emit_toplevel_const(nid);
            }
            i = i + 1;
        }
        self.emit_assoc_consts(true);
    }
    fn emit_referenced_fwd(self: &mut Self) void {
        let cur = self.cur_module();
        let np = unsafe (*self.cur_ast()).type_pool.len();
        let mut i: usize = 0;
        while i < np {
            let t = *unsafe (*self.cur_ast()).type_at(i as TypeId);
            if t.kind == TypeKind::TYPE_INSTANCE {
                let it = *unsafe (*self.cur_ast()).instance(t.as_data.inst);
                if it.module == cur || it.module as usize >= self.pkg_count() { i = i + 1; continue; }
                let mut concrete = true;
                let mut k: u8 = 0;
                while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
                if !concrete { i = i + 1; continue; }
                let idn_kind = unsafe (*self.mod_ast(it.module)).at_const(it.decl).kind;
                if idn_kind == NodeKind::NODE_STRUCT || self.aggregate_has_payload_in(it.module, it.decl) {
                    let kw = agg_kw(unsafe (*self.mod_ast(it.module)).at_const(it.decl));
                    let mut inm = Buf200 {};
                    self.inst_name(&it, (&mut inm.b[0]) as *mut char, 200);
                    self.emit("typedef %s %s %s;\n".ptr as *const char, kw, (&inm.b[0]) as *const char, (&inm.b[0]) as *const char);
                }
                i = i + 1;
                continue;
            }
            if t.module == cur || t.module as usize >= self.pkg_count() { i = i + 1; continue; }
            if self.package != null && unsafe (*self.package).builtin_of_decl(t.module, t.as_data.decl) >= 0 { i = i + 1; continue; }
            if t.kind == TypeKind::TYPE_STRUCT || (t.kind == TypeKind::TYPE_ENUM && self.aggregate_has_payload_in(t.module, t.as_data.decl)) {
                let kw = agg_kw(unsafe (*self.mod_ast(t.module)).at_const(t.as_data.decl));
                let anm = unsafe (*self.mod_ast(t.module)).at_const(t.as_data.decl).as_data.aggregate.name;
                let mut nm = Buf160 {};
                self.render_qualified(t.module, anm, (&mut nm.b[0]) as *mut char, 160);
                self.emit("typedef %s %s %s;\n".ptr as *const char, kw, (&nm.b[0]) as *const char, (&nm.b[0]) as *const char);
            } else if t.kind == TypeKind::TYPE_ENUM {
                let sa = self.cur_ast();
                let ss = self.source;
                let sl = self.len;
                let tmod = t.module;
                let tdecl = t.as_data.decl;
                self.source = self.mod_src(tmod);
                self.len = unsafe (*self.package).modules.at(tmod as usize).source_len;
                self.ast = self.mod_ast(tmod);
                self.emit_enum_full(tdecl);
                self.ast = sa;
                self.source = ss;
                self.len = sl;
            }
            i = i + 1;
        }
    }
    fn emit_referenced_includes(self: &mut Self) void {
        let nmod = self.pkg_count();
        let cur = self.cur_module();
        let want = unsafe stdlib::calloc(if nmod != 0 { nmod; } else { 1 as usize; }, 1) as *mut bool;
        if want == null { return; }
        let mut i: usize = 0;
        while i < unsafe (*self.cur_ast()).resolutions.len() {
            let d = *unsafe (*self.cur_ast()).resolutions.at(i);
            if d.node == NODE_NONE || d.module == cur || d.module as usize >= nmod { i = i + 1; continue; }
            if self.cg_decl_is_interface_member(d.module, d.node) { i = i + 1; continue; }
            if unsafe (*self.package).builtin_of_decl(d.module, d.node) >= 0 { i = i + 1; continue; }
            unsafe want[d.module as usize] = true;
            i = i + 1;
        }
        let mut ti: usize = 0;
        while ti < unsafe (*self.cur_ast()).type_pool.len() {
            let t = *unsafe (*self.cur_ast()).type_at(ti as TypeId);
            if (t.kind != TypeKind::TYPE_STRUCT && t.kind != TypeKind::TYPE_ENUM && t.kind != TypeKind::TYPE_FUNCTION) || t.module == cur || t.module as usize >= nmod { ti = ti + 1; continue; }
            if unsafe (*self.package).builtin_of_decl(t.module, t.as_data.decl) >= 0 { ti = ti + 1; continue; }
            if t.kind == TypeKind::TYPE_FUNCTION && self.cg_decl_is_interface_member(t.module, t.as_data.decl) { ti = ti + 1; continue; }
            unsafe want[t.module as usize] = true;
            ti = ti + 1;
        }
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            let mut concrete = (it.module as usize) < nmod || it.module == cur;
            let mut k: u8 = 0;
            while k < it.n && concrete { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { ii = ii + 1; continue; }
            let home = unsafe (*self.package).instance_home(unsafe (&*self.cur_ast()), &it);
            if it.module != cur && (it.module as usize) < nmod { unsafe want[it.module as usize] = true; }
            if home != cur && (home as usize) < nmod { unsafe want[home as usize] = true; }
            ii = ii + 1;
        }
        if unsafe (*self.package).core_seeded && unsafe (*self.package).core_module != cur && (unsafe (*self.package).core_module as usize) < nmod {
            let mut need_core = false;
            let mut ci: usize = 0;
            while ci < unsafe (*self.cur_ast()).instances.len() && !need_core {
                let it = *unsafe (*self.cur_ast()).instance(ci as u32);
                let mut concrete = (it.module as usize) < nmod || it.module == cur;
                let mut k: u8 = 0;
                while k < it.n && concrete { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
                let mut k2: u8 = 0;
                while k2 < it.n && concrete && !need_core { if self.type_mentions_builtin(it.args[k2 as usize]) { need_core = true; } k2 = k2 + 1; }
                ci = ci + 1;
            }
            let mut ni: i32 = 0;
            while ni < self.ninsts && !need_core {
                let mut k: u8 = 0;
                while k < self.insts[ni as usize].n && !need_core { if self.type_mentions_builtin(self.insts[ni as usize].args[k as usize]) { need_core = true; } k = k + 1; }
                ni = ni + 1;
            }
            if need_core { unsafe want[unsafe (*self.package).core_module as usize] = true; }
        }
        let mut m: usize = 0;
        while m < nmod {
            if unsafe want[m] { self.emit_modpath_include(unsafe (*self.package).modules.at(m).path as *const char); }
            m = m + 1;
        }
        unsafe stdlib::free(want as *mut void);
    }
    fn emit_header_includes(self: &mut Self) void {
        let nmod = self.pkg_count();
        let cur = self.cur_module();
        let want = unsafe stdlib::calloc(if nmod != 0 { nmod; } else { 1 as usize; }, 1) as *mut bool;
        if want == null { return; }
        let saved = self.nsubst;
        self.nsubst = 0;
        let mut pub_const_expr = false;
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if (nk == NodeKind::NODE_STRUCT || nk == NodeKind::NODE_ENUM) && unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate.generics.len == 0 {
                self.mark_aggregate_layout(nid, want, nmod);
            } else if nk == NodeKind::NODE_FUNCTION && unsafe (*self.cur_ast()).at_const(nid).as_data.function.returns.len > 1 {
                let rets = unsafe (*self.cur_ast()).at_const(nid).as_data.function.returns;
                let rids = unsafe (*self.cur_ast()).list(rets);
                let mut r: u32 = 0;
                while r < rets.len {
                    let rid = unsafe rids[r as usize];
                    let rn = unsafe (*self.cur_ast()).at_const(rid);
                    let rtn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { rid; };
                    self.mark_layout_module(unsafe (*self.cur_ast()).type_of(rtn), want, nmod);
                    r = r + 1;
                }
            } else if nk == NodeKind::NODE_CONST {
                let cd = unsafe (*self.cur_ast()).at_const(nid).as_data.const_def;
                if !cd.is_extern {
                    self.mark_layout_module(unsafe (*self.cur_ast()).type_of(cd.ty), want, nmod);
                    if cd.is_public && cd.value != NODE_NONE && unsafe (*self.cur_ast()).at_const(cd.value).kind != NodeKind::NODE_LITERAL { pub_const_expr = true; }
                }
            }
            i = i + 1;
        }
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            let mut concrete = (it.module as usize) < nmod || it.module == cur;
            let mut k: u8 = 0;
            while k < it.n && concrete { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { ii = ii + 1; continue; }
            let home = unsafe (*self.package).instance_home(unsafe (&*self.cur_ast()), &it);
            if home != cur { ii = ii + 1; continue; }
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
                if (it.module as usize) < nmod { unsafe want[it.module as usize] = true; }
                let mut k2: u8 = 0;
                while k2 < it.n { self.mark_layout_module(it.args[k2 as usize], want, nmod); k2 = k2 + 1; }
            }
            ii = ii + 1;
        }
        self.nsubst = saved;
        if pub_const_expr {
            let mut ri: usize = 0;
            while ri < unsafe (*self.cur_ast()).resolutions.len() {
                let d = *unsafe (*self.cur_ast()).resolutions.at(ri);
                if d.node != NODE_NONE && d.module != cur && (d.module as usize) < nmod && !self.cg_decl_is_interface_member(d.module, d.node) { unsafe want[d.module as usize] = true; }
                ri = ri + 1;
            }
            let mut ti: usize = 0;
            while ti < unsafe (*self.cur_ast()).type_pool.len() {
                let t = *unsafe (*self.cur_ast()).type_at(ti as TypeId);
                if (t.kind == TypeKind::TYPE_STRUCT || t.kind == TypeKind::TYPE_ENUM) && t.module != cur && (t.module as usize) < nmod && unsafe (*self.package).builtin_of_decl(t.module, t.as_data.decl) < 0 { unsafe want[t.module as usize] = true; }
                ti = ti + 1;
            }
        }
        let mut m: usize = 0;
        while m < nmod {
            if m != cur as usize && unsafe want[m] { self.emit_modpath_include(unsafe (*self.package).modules.at(m).path as *const char); }
            m = m + 1;
        }
        unsafe stdlib::free(want as *mut void);
    }
    fn emit_extern_includes(self: &mut Self) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTERN_BLOCK { i = i + 1; continue; }
            let hdr = unsafe (*self.cur_ast()).at_const(nid).as_data.extern_block.header;
            if hdr == NODE_NONE { i = i + 1; continue; }
            let hs = unsafe (*self.cur_ast()).at_const(hdr).span;
            let s = hs.start + 1;
            let e = hs.end - 1;
            if e <= s { i = i + 1; continue; }
            let mut dup = false;
            let mut j: u32 = 0;
            while j < i && !dup {
                let mid = unsafe ids[j as usize];
                if unsafe (*self.cur_ast()).at_const(mid).kind == NodeKind::NODE_EXTERN_BLOCK {
                    let mh = unsafe (*self.cur_ast()).at_const(mid).as_data.extern_block.header;
                    if mh != NODE_NONE {
                        let ms = unsafe (*self.cur_ast()).at_const(mh).span;
                        if ms.end - ms.start == hs.end - hs.start && unsafe cstring::memcmp((self.source + ms.start as usize) as *const void, (self.source + hs.start as usize) as *const void, (hs.end - hs.start) as usize) == 0 { dup = true; }
                    }
                }
                j = j + 1;
            }
            if dup { i = i + 1; continue; }
            // Resolve the header relative to the declaring module's file (realpath), then emit a
            // build-relative include when it sits under the project root, else its absolute path.
            let mut done = false;
            let cm = self.cur_module();
            if self.package != null && (cm as usize) < unsafe (*self.package).modules.len() {
                let file = unsafe (*self.package).modules.at(cm as usize).file;
                if file != null {
                    let mut rel = Buf4096 {};
                    let hp = unsafe (self.source + s as usize) as *const char;
                    let hlen = (e - s) as i32;
                    let slash = unsafe cstring::strrchr(file as *const char, '/' as i32);
                    if slash != null {
                        let dlen = ((slash as usize) - (file as usize)) as i32;
                        unsafe stdio::snprintf((&mut rel.b[0]) as *mut char, 4096, "%.*s/%.*s".ptr as *const char, dlen, file as *const char, hlen, hp);
                    } else {
                        unsafe stdio::snprintf((&mut rel.b[0]) as *mut char, 4096, "./%.*s".ptr as *const char, hlen, hp);
                    }
                    let mut absb = Buf4096 {};
                    let mut rootb = Buf4096 {};
                    let ra = unsafe shim::sc_realpath((&rel.b[0]) as *const char, (&mut absb.b[0]) as *mut char);
                    let rr = unsafe shim::sc_realpath(unsafe (*self.package).root_dir as *const char, (&mut rootb.b[0]) as *mut char);
                    if ra != null && rr != null {
                        let rl = unsafe cstring::strlen((&rootb.b[0]) as *const char);
                        self.emit_cstr("#include \"".ptr as *const char);
                        if unsafe cstring::strncmp((&absb.b[0]) as *const char, (&rootb.b[0]) as *const char, rl) == 0 && unsafe absb.b[rl] == '/' as char {
                            self.emit_rel_prefix();
                            self.emit_cstr("../".ptr as *const char);
                            self.emit_cstr(unsafe (((&absb.b[0]) as *const char) + (rl + 1)) as *const char);
                        } else {
                            self.emit_cstr((&absb.b[0]) as *const char);
                        }
                        self.emit_cstr("\"\n".ptr as *const char);
                        done = true;
                    }
                }
            }
            if !done {
                let local = unsafe self.source[s as usize] == '.' as u8 || unsafe self.source[s as usize] == '/' as u8;
                if local { self.emit_cstr("#include \"".ptr as *const char); } else { self.emit_cstr("#include <".ptr as *const char); }
                self.emit_bytes(unsafe (self.source + s as usize) as *const char, (e - s) as usize);
                if local { self.emit_cstr("\"\n".ptr as *const char); } else { self.emit_cstr(">\n".ptr as *const char); }
            }
            i = i + 1;
        }
    }
    fn emit_includes(self: &mut Self) void {
        let p = unsafe (*self.package).modules.at(self.cur_module() as usize).path as *const char;
        self.emit_modpath_include(p);
        self.emit_referenced_includes();
        self.emit_cstr("\n".ptr as *const char);
    }
    fn cg_test_type(self: &mut Self, d: DefId, is_enum: bool) TypeId {
        let tk = if (is_enum) { TypeKind::TYPE_ENUM; } else { TypeKind::TYPE_STRUCT; };
        return unsafe (*self.cur_ast()).intern_type(Ty { kind: tk, module: d.module, as_data: TyAs { decl: d.node } });
    }
    fn emit_test_wrappers(self: &mut Self) void {
        if !self.test.enabled || (self.test.ncases == 0 && self.test.genv_init == NODE_NONE) { return; }
        self.emit_cstr("\n/* --test wrappers */\n".ptr as *const char);
        let mut i: u32 = 0;
        while i < self.test.ncases {
            let tc = unsafe self.test.cases[i as usize];
            let suite = tc.suite.node != NODE_NONE;
            let fx_type = if (suite) { tc.suite; } else { self.test.fx_type; };
            let fx_is_enum = if (suite) { tc.suite_is_enum; } else { self.test.fx_is_enum; };
            let fx_init = if (suite) { tc.suite_init; } else { self.test.fx_init; };
            let fx_free = if (suite) { tc.suite_free; } else { self.test.fx_free; };
            let target = if (suite) { tc.suite; } else { DefId { module: 0, node: NODE_NONE }; };
            let mut fname = Buf240 {};
            self.function_name(tc.func, target, (&mut fname.b[0]) as *mut char, 240, true);
            self.emit("void __sc_test_w_%u_%u(void *__genv) {\n  (void)__genv;\n".ptr as *const char, self.cur_module() as u32, tc.func);
            if (tc.wants & 1) != 0 {
                let fxt = self.cg_test_type(fx_type, fx_is_enum);
                let mut decl = Buf256 {};
                self.render_type_id(fxt, "__fx".ptr as *const char, (&mut decl.b[0]) as *mut char, 256);
                let mut init = Buf240 {};
                self.function_name(fx_init, target, (&mut init.b[0]) as *mut char, 240, true);
                self.emit("  %s = %s();\n".ptr as *const char, (&decl.b[0]) as *const char, (&init.b[0]) as *const char);
            }
            self.emit("  %s(".ptr as *const char, (&fname.b[0]) as *const char);
            if (tc.wants & 1) != 0 { self.emit_cstr("&__fx".ptr as *const char); }
            if (tc.wants & 2) != 0 {
                let gt = self.cg_test_type(self.test.genv_type, self.test.genv_is_enum);
                let mut gty = Buf200 {};
                self.render_type_id(gt, "".ptr as *const char, (&mut gty.b[0]) as *mut char, 200);
                let sep = if ((tc.wants & 1) != 0) { ", ".ptr as *const char; } else { "".ptr as *const char; };
                self.emit("%s(const %s *)__genv".ptr as *const char, sep, (&gty.b[0]) as *const char);
            }
            self.emit_cstr(");\n".ptr as *const char);
            if (tc.wants & 1) != 0 && fx_free != NODE_NONE {
                let mut fre = Buf240 {};
                self.function_name(fx_free, target, (&mut fre.b[0]) as *mut char, 240, true);
                self.emit("  %s(&__fx);\n".ptr as *const char, (&fre.b[0]) as *const char);
            }
            if (tc.wants & 1) != 0 {
                let fxt = self.cg_test_type(fx_type, fx_is_enum);
                if self.cg_type_is_free(fxt) {
                    self.emit_cstr("  ".ptr as *const char);
                    self.emit_free_target(fxt);
                    self.emit_cstr("(&__fx);\n".ptr as *const char);
                }
            }
            self.emit_cstr("}\n".ptr as *const char);
            i = i + 1;
        }
        if self.test.genv_init != NODE_NONE {
            let gt = self.cg_test_type(self.test.genv_type, self.test.genv_is_enum);
            let mut gdecl = Buf256 {};
            self.render_type_id(gt, "__sc_genv".ptr as *const char, (&mut gdecl.b[0]) as *mut char, 256);
            let mut gty = Buf200 {};
            self.render_type_id(gt, "".ptr as *const char, (&mut gty.b[0]) as *mut char, 200);
            let giname = unsafe (*self.cur_ast()).at_const(self.test.genv_init).as_data.function.name;
            let mut init = Buf200 {};
            self.render_qualified(self.cur_module(), giname, (&mut init.b[0]) as *mut char, 200);
            self.emit("void *__sc_test_genv_init(void) { static %s; __sc_genv = %s(); return &__sc_genv; }\n".ptr as *const char, (&gdecl.b[0]) as *const char, (&init.b[0]) as *const char);
            self.emit_cstr("void __sc_test_genv_free(void *__p) {\n  (void)__p;\n".ptr as *const char);
            if self.test.genv_free != NODE_NONE {
                let gfname = unsafe (*self.cur_ast()).at_const(self.test.genv_free).as_data.function.name;
                let mut fre = Buf200 {};
                self.render_qualified(self.cur_module(), gfname, (&mut fre.b[0]) as *mut char, 200);
                self.emit("  %s((%s *)__p);\n".ptr as *const char, (&fre.b[0]) as *const char, (&gty.b[0]) as *const char);
            }
            if self.cg_type_is_free(gt) {
                self.emit_cstr("  ".ptr as *const char);
                self.emit_free_target(gt);
                self.emit("((%s *)__p);\n".ptr as *const char, (&gty.b[0]) as *const char);
            }
            self.emit_cstr("}\n".ptr as *const char);
        }
    }
    pub fn codegen_emit_header(self: &mut Self, out: *mut stdio::FILE) void {
        self.build_enum_index();
        let mut guard = Buf160 {};
        let np = (&mut guard.b[0]) as *mut char;
        let mut at = bappend(np, 160, 0, "SUPER_".ptr as *const char);
        let mp = unsafe (*self.package).modules.at(self.cur_module() as usize).path;
        let mut i: usize = 0;
        while unsafe mp[i] != 0 as char && at + 2 < 160 {
            if unsafe mp[i] == ':' as char && unsafe mp[i + 1] == ':' as char {
                unsafe guard.b[at] = '_' as char;
                unsafe guard.b[at + 1] = '_' as char;
                at = at + 2;
                i = i + 1;
            } else {
                unsafe guard.b[at] = unsafe mp[i];
                at = at + 1;
            }
            i = i + 1;
        }
        unsafe guard.b[at] = 0 as char;
        bappend(np, 160, at, "_H".ptr as *const char);
        let mut gi: usize = 0;
        while unsafe guard.b[gi] != 0 as char {
            let ch = unsafe guard.b[gi];
            if ch >= 'a' as char && ch <= 'z' as char { unsafe guard.b[gi] = (ch as i32 - 32) as char; }
            gi = gi + 1;
        }
        let gp = np as *const char;
        self.emit("#ifndef %s\n#define %s\n\n".ptr as *const char, gp, gp);
        self.emit_cstr("#include \"".ptr as *const char);
        self.emit_rel_prefix();
        self.emit_cstr("super_rt.h\"\n".ptr as *const char);
        self.emit_extern_includes();
        self.emit_referenced_fwd();
        self.emit_header_includes();
        self.emit_cstr("\n".ptr as *const char);
        self.phase_forward();
        self.emit_cstr("\n".ptr as *const char);
        self.phase_types();
        self.phase_ret_structs();
        self.emit_cstr("\n".ptr as *const char);
        self.phase_prototypes(PROTO_PUBLIC);
        self.emit_cstr("\n".ptr as *const char);
        self.emit_public_consts();
        self.emit_cstr("\n#endif\n".ptr as *const char);
        if self.buf_len != 0 { unsafe stdio::fwrite(self.buf as *const void, 1, self.buf_len, out); }
        self.buf_len = 0;
    }
    pub fn codegen_emit(self: &mut Self, out: *mut stdio::FILE) void {
        self.build_enum_index();
        self.collect_insts();
        self.collect_callbacks();
        if self.multifile {
            self.emit_includes();
            self.emit_layout_asserts();
            self.phase_prototypes(PROTO_PRIVATE);
            self.emit_cstr("\n".ptr as *const char);
            self.emit_dyn_tables();
            self.phase_bodies();
            self.emit_test_wrappers();
        } else {
            self.emit_cstr(super_rt_includes());
            self.emit_extern_includes();
            self.emit_cstr("\n".ptr as *const char);
            self.phase_forward();
            self.emit_cstr("\n".ptr as *const char);
            self.phase_types();
            self.phase_ret_structs();
            self.emit_cstr("\n".ptr as *const char);
            self.emit_layout_asserts();
            self.phase_prototypes(PROTO_ALL);
            self.emit_cstr("\n".ptr as *const char);
            self.emit_dyn_tables();
            self.phase_bodies();
            self.emit_test_wrappers();
        }
        let src = self.source;
        let ln = self.len;
        let mut file: *const char = null;
        if self.package != null && (self.cur_module() as usize) < self.pkg_count() { file = unsafe (*self.package).modules.at(self.cur_module() as usize).file as *const char; }
        self.errors.finalize(src, ln, file);
        if self.buf_len != 0 { unsafe stdio::fwrite(self.buf as *const void, 1, self.buf_len, out); }
    }
    fn seed_emitted_type_instances(self: &mut Self) void {
        let mut pass: i32 = 0;
        while pass < 32 {
            if !self.seed_emitted_generic_method_signature_instances() { return; }
            pass = pass + 1;
        }
    }
    fn phase_forward(self: &mut Self) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_STRUCT {
                let ag = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate;
                if ag.generics.len != 0 { i = i + 1; continue; }
                let kw = agg_kw(unsafe (*self.cur_ast()).at_const(nid));
                self.emit("typedef %s ".ptr as *const char, kw);
                self.emit_local_type_name(ag.name);
                self.emit_cstr(" ".ptr as *const char);
                self.emit_local_type_name(ag.name);
                self.emit_cstr(";\n".ptr as *const char);
            } else if nk == NodeKind::NODE_ENUM {
                let ag = unsafe (*self.cur_ast()).at_const(nid).as_data.aggregate;
                if ag.generics.len != 0 { i = i + 1; continue; }
                if !self.aggregate_has_payload(nid) {
                    self.emit_enum_full(nid);
                    i = i + 1;
                    continue;
                }
                self.emit_enum_tag_decl(nid);
                self.emit_cstr("typedef struct ".ptr as *const char);
                self.emit_local_type_name(ag.name);
                self.emit_cstr(" ".ptr as *const char);
                self.emit_local_type_name(ag.name);
                self.emit_cstr(";\n".ptr as *const char);
            } else if nk == NodeKind::NODE_TYPE_ALIAS {
                let ta = unsafe (*self.cur_ast()).at_const(nid).as_data.type_alias;
                if ta.ty != NODE_NONE && ta.generics.len == 0 && self.cg_alias_extended(self.cur_module(), nid) {
                    let mut nm = Buf160 {};
                    self.render_qualified(self.cur_module(), ta.name, (&mut nm.b[0]) as *mut char, 160);
                    let mut d = Buf256 {};
                    self.render_type_node(ta.ty, (&nm.b[0]) as *const char, (&mut d.b[0]) as *mut char, 256);
                    self.emit("typedef %s;\n".ptr as *const char, (&d.b[0]) as *const char);
                }
            }
            i = i + 1;
        }
        self.emit_aggregate_specializations(false);
        self.emit_rehomed_forwards();
    }
    fn phase_types(self: &mut Self) void {
        self.emit_dyn_typedefs();
        self.seed_emitted_type_instances();
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let state = self.cg_type_state();
        let ni = unsafe (*self.cur_ast()).instances.len();
        let cnt = if ni != 0 { ni; } else { 1 as usize; };
        self.inst_emit_state = unsafe stdlib::calloc(cnt, 1) as *mut u8;
        if self.inst_emit_state != null { self.inst_emit_n = ni; } else { self.inst_emit_n = 0; }
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            if self.type_emittable(nid) {
                if state != null { self.emit_type_dfs(nid, state); }
                else { self.emit_type_decl(nid); }
            }
            i = i + 1;
        }
        self.emit_aggregate_specializations(true);
        self.emit_rehomed_structs(true);
        self.emit_generic_macros();
        unsafe stdlib::free(self.inst_emit_state as *mut void);
        self.inst_emit_state = null;
        self.inst_emit_n = 0;
    }
    fn phase_ret_structs(self: &mut Self) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_FUNCTION {
                if unsafe (*self.cur_ast()).at_const(nid).as_data.function.generics.len == 0 {
                    self.emit_ret_struct(nid, DefId { module: 0, node: NODE_NONE });
                }
            } else if nk == NodeKind::NODE_EXTEND {
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                if ed.generics.len != 0 { i = i + 1; continue; }
                let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
                let ms = ed.items;
                let mids = unsafe (*self.cur_ast()).list(ms);
                let mut j: u32 = 0;
                while j < ms.len {
                    let mid = unsafe mids[j as usize];
                    if unsafe (*self.cur_ast()).at_const(mid).kind == NodeKind::NODE_FUNCTION { self.emit_ret_struct(mid, target); }
                    j = j + 1;
                }
            }
            i = i + 1;
        }
    }
    fn phase_prototypes(self: &mut Self, which: i32) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_FUNCTION {
                let ff = unsafe (*self.cur_ast()).at_const(nid).as_data.function;
                if ff.generics.len != 0 { i = i + 1; continue; }
                if self.cb_specialized_away(nid) || self.cg_is_format_builtin(self.cur_module(), nid) || self.cg_test_skip(nid, false) { i = i + 1; continue; }
                if want_fn(which, ff.is_public) {
                    self.emit_function(nid, DefId { module: 0, node: NODE_NONE }, false, false, null, false);
                }
            } else if nk == NodeKind::NODE_EXTEND {
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                if ed.generics.len != 0 { i = i + 1; continue; }
                let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
                let mids = unsafe (*self.cur_ast()).list(ed.items);
                let mut j: u32 = 0;
                while j < ed.items.len {
                    let mid = unsafe mids[j as usize];
                    let mk_kind = unsafe (*self.cur_ast()).at_const(mid).kind;
                    if mk_kind == NodeKind::NODE_FUNCTION {
                        let mpub = unsafe (*self.cur_ast()).at_const(mid).as_data.function.is_public;
                        if want_fn(which, mpub) && !self.cg_test_skip(mid, true) {
                            self.emit_function(mid, target, false, false, null, false);
                        }
                    }
                    j = j + 1;
                }
            }
            i = i + 1;
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
    fn phase_bodies(self: &mut Self) void {
        let items = self.program_items();
        let ids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_CONST {
                let cd = unsafe (*self.cur_ast()).at_const(nid).as_data.const_def;
                if cd.is_static_mut || !(self.multifile && cd.is_public) { self.emit_toplevel_const(nid); }
            } else if nk == NodeKind::NODE_STATIC_ASSERT {
                self.emit_static_assert(nid);
            }
            i = i + 1;
        }
        self.emit_assoc_consts(false);
        self.emit_default_methods(PROTO_ALL, true);
        self.emit_specializations(true);
        self.emit_method_specializations(PROTO_ALL, true);
        self.emit_rehomed_methods(PROTO_ALL, true);
        self.emit_local_method_insts(PROTO_ALL, true);
        self.emit_closures(true);
        self.emit_callback_specializations(true);
        let mut i2: u32 = 0;
        while i2 < items.len {
            let nid = unsafe ids[i2 as usize];
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk == NodeKind::NODE_FUNCTION {
                let ff = unsafe (*self.cur_ast()).at_const(nid).as_data.function;
                if ff.generics.len == 0 && ff.body != NODE_NONE && !self.cb_specialized_away(nid) && !self.cg_is_format_builtin(self.cur_module(), nid) && !self.cg_test_skip(nid, false) {
                    self.emit_function(nid, DefId { module: 0, node: NODE_NONE }, false, true, null, false);
                }
            } else if nk == NodeKind::NODE_EXTEND {
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                if ed.generics.len == 0 {
                    let target = unsafe (*self.cur_ast()).resolution_def(ed.target_type);
                    let mids = unsafe (*self.cur_ast()).list(ed.items);
                    let mut j: u32 = 0;
                    while j < ed.items.len {
                        let mid = unsafe mids[j as usize];
                        let mk_kind = unsafe (*self.cur_ast()).at_const(mid).kind;
                        if mk_kind == NodeKind::NODE_FUNCTION {
                            let mbody = unsafe (*self.cur_ast()).at_const(mid).as_data.function.body;
                            if mbody != NODE_NONE && !self.cg_test_skip(mid, true) {
                                self.emit_function(mid, target, false, true, null, false);
                            }
                        }
                        j = j + 1;
                    }
                }
            }
            i2 = i2 + 1;
        }
    }
}

// ---- conformance gating + instance seeding ----
extend Codegen {
    fn cg_type_satisfies(self: &mut Self, ty: TypeId, iface: DefId, depth: i32) bool {
        if ty == TYPE_NONE || depth > 8 { return true; }
        let y = *self.type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC { return true; }
        let mut tmod: ModuleId = 0;
        let mut tdecl: NodeId = NODE_NONE;
        let mut iargs = TyArgs4 {};
        let mut in_: i32 = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            tmod = y.module;
            tdecl = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            tmod = it.module;
            tdecl = it.decl;
            let mut k: u8 = 0;
            while k < it.n && in_ < 4 { unsafe iargs.t[in_ as usize] = it.args[k as usize]; in_ = in_ + 1; k = k + 1; }
        } else if y.kind == TypeKind::TYPE_BUILTIN && self.package != null {
            let bd = unsafe (*self.package).builtin_decl(y.as_data.builtin);
            if bd == NODE_NONE { return false; }
            tmod = unsafe (*self.package).core_module;
            tdecl = bd;
        } else {
            return false;
        }
        let ns = if tmod == self.cur_module() { 1; } else { 2; };
        let mut s: i32 = 0;
        while s < ns {
            let m = if s == 0 { tmod; } else { self.cur_module(); };
            let a = self.mod_ast(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            let mut i: u32 = 0;
            while i < items.len {
                let iid = unsafe ((*a).list(items))[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND || it.as_data.extend_def.interface_type == NODE_NONE || it.as_data.extend_def.target_type == NODE_NONE { i = i + 1; continue; }
                let tr = unsafe (*a).resolution_def(it.as_data.extend_def.interface_type);
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tr.module != iface.module || tr.node != iface.node || tg.module != tmod || tg.node != tdecl { i = i + 1; continue; }
                let gens = it.as_data.extend_def.generics;
                let gids = unsafe (*a).list(gens);
                let mut ok = true;
                let mut g: u32 = 0;
                while g < gens.len && (g as i32) < in_ && ok {
                    let gb = unsafe (*a).at_const(unsafe gids[g as usize]).as_data.generic_param.bounds;
                    let gbids = unsafe (*a).list(gb);
                    let mut b: u32 = 0;
                    while b < gb.len && ok {
                        let gbi = unsafe (*a).resolution_def(unsafe gbids[b as usize]);
                        if gbi.node != NODE_NONE && !self.cg_type_satisfies(unsafe iargs.t[g as usize], gbi, depth + 1) { ok = false; }
                        b = b + 1;
                    }
                    g = g + 1;
                }
                if ok { return true; }
                i = i + 1;
            }
            s = s + 1;
        }
        return false;
    }

    fn extend_interface(self: &Self, extend_id: NodeId) DefId {
        let it = unsafe (*self.cur_ast()).at_const(extend_id);
        if it.as_data.extend_def.interface_type == NODE_NONE { return DefId { module: 0, node: NODE_NONE }; }
        return unsafe (*self.cur_ast()).resolution_def(it.as_data.extend_def.interface_type);
    }

    fn cg_extend_bounds_hold(self: &mut Self, extend_id: NodeId, args: *const TypeId, n: u8) bool {
        let gens = unsafe (*self.cur_ast()).at_const(extend_id).as_data.extend_def.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        let mut g: u32 = 0;
        while g < gens.len && g < n as u32 {
            let gb = unsafe (*self.cur_ast()).at_const(unsafe gids[g as usize]).as_data.generic_param.bounds;
            let gbids = unsafe (*self.cur_ast()).list(gb);
            let mut b: u32 = 0;
            while b < gb.len {
                let gbi = unsafe (*self.cur_ast()).resolution_def(unsafe gbids[b as usize]);
                if gbi.node != NODE_NONE && !self.cg_type_satisfies(unsafe args[g as usize], gbi, 0) { return false; }
                b = b + 1;
            }
            g = g + 1;
        }
        return true;
    }
}

extend Codegen {
    fn seed_type_instances_from_type(self: &mut Self, ty0: TypeId) bool {
        if ty0 == TYPE_NONE { return false; }
        let ty = self.subst_resolve(ty0);
        let y = *self.type_at(ty);
        let mut changed = false;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut concrete = true;
            let mut i: u8 = 0;
            while i < it.n { if !self.type_is_concrete(it.args[i as usize]) { concrete = false; } i = i + 1; }
            if concrete {
                let before = unsafe (*self.cur_ast()).instances.len();
                unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
                if unsafe (*self.cur_ast()).instances.len() != before { changed = true; }
                let mut j: u8 = 0;
                while j < it.n { if self.seed_type_instances_from_type(it.args[j as usize]) { changed = true; } j = j + 1; }
            }
        } else if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_ARRAY {
            if self.seed_type_instances_from_type(y.as_data.elem) { changed = true; }
        }
        return changed;
    }
    fn seed_type_instances_from_type_node(self: &mut Self, type_node: NodeId) bool {
        if type_node == NODE_NONE { return false; }
        let ty = unsafe (*self.cur_ast()).type_of(type_node);
        return ty != TYPE_NONE && self.seed_type_instances_from_type(ty);
    }
    fn seed_type_instances_from_fn_signature(self: &mut Self, fn_id: NodeId) bool {
        let f = unsafe (*self.cur_ast()).at_const(fn_id).as_data.function;
        let mut changed = false;
        let pids = unsafe (*self.cur_ast()).list(f.params);
        let mut i: u32 = 0;
        while i < f.params.len {
            let ptn = unsafe (*self.cur_ast()).at_const(unsafe pids[i as usize]).as_data.parameter.ty;
            if self.seed_type_instances_from_type_node(ptn) { changed = true; }
            i = i + 1;
        }
        let rids = unsafe (*self.cur_ast()).list(f.returns);
        let mut r: u32 = 0;
        while r < f.returns.len {
            let rid = unsafe rids[r as usize];
            let rn = unsafe (*self.cur_ast()).at_const(rid);
            let rtn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { rid; };
            if self.seed_type_instances_from_type_node(rtn) { changed = true; }
            r = r + 1;
        }
        return changed;
    }
    fn seed_emitted_generic_method_signature_instances(self: &mut Self) bool {
        let mut changed = false;
        let mut ii: usize = 0;
        while ii < unsafe (*self.cur_ast()).instances.len() {
            let it = *unsafe (*self.cur_ast()).instance(ii as u32);
            if it.module != self.cur_module() { ii = ii + 1; continue; }
            let mut concrete = true;
            let mut k: u8 = 0;
            while k < it.n { if !self.type_is_concrete(it.args[k as usize]) { concrete = false; } k = k + 1; }
            if !concrete { ii = ii + 1; continue; }
            let items = self.program_items();
            let iids = unsafe (*self.cur_ast()).list(items);
            let mut i: u32 = 0;
            while i < items.len {
                let nid = unsafe iids[i as usize];
                let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
                let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
                if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 { i = i + 1; continue; }
                if unsafe (*self.cur_ast()).resolution(ed.target_type) != it.decl { i = i + 1; continue; }
                let itrait = self.extend_interface(nid);
                if itrait.node != NODE_NONE {
                    let itty = unsafe (*self.cur_ast()).intern_instance(it.module, it.decl, (&it.args[0]) as *const TypeId, it.n);
                    if !self.cg_type_satisfies(itty, itrait, 0) { i = i + 1; continue; }
                }
                if !self.cg_extend_bounds_hold(nid, (&it.args[0]) as *const TypeId, it.n) { i = i + 1; continue; }
                let gens = ed.generics;
                let gids = unsafe (*self.cur_ast()).list(gens);
                let saved = self.nsubst;
                self.nsubst = 0;
                let mut g: u32 = 0;
                while g < gens.len && g < it.n as u32 && self.nsubst < 16 {
                    self.subst[self.nsubst as usize].param = DefId { module: self.cur_module(), node: unsafe gids[g as usize] };
                    self.subst[self.nsubst as usize].concrete = it.args[g as usize];
                    self.nsubst = self.nsubst + 1;
                    g = g + 1;
                }
                let ms = ed.items;
                let mids = unsafe (*self.cur_ast()).list(ms);
                let mut j: u32 = 0;
                while j < ms.len {
                    let mid = unsafe mids[j as usize];
                    let mn = unsafe (*self.cur_ast()).at_const(mid);
                    if mn.kind == NodeKind::NODE_FUNCTION && mn.as_data.function.generics.len == 0 {
                        if self.seed_type_instances_from_fn_signature(mid) { changed = true; }
                    }
                    j = j + 1;
                }
                self.nsubst = saved;
                i = i + 1;
            }
            ii = ii + 1;
        }
        return changed;
    }
}

// ---- header/source #include machinery ----
extend Codegen {
    fn module_depth(self: &Self) usize {
        let p = unsafe (*self.package).modules.at(self.cur_module() as usize).path;
        let mut d: usize = 0;
        let mut i: usize = 0;
        while unsafe p[i] != 0 as char {
            if unsafe p[i] == ':' as char && unsafe p[i + 1] == ':' as char { d = d + 1; i = i + 1; }
            i = i + 1;
        }
        return d;
    }
    fn emit_rel_prefix(self: &mut Self) void {
        let d = self.module_depth();
        let mut i: usize = 0;
        while i < d { self.emit_cstr("../".ptr as *const char); i = i + 1; }
    }
    fn emit_modpath_include(self: &mut Self, path: *const char) void {
        self.emit_cstr("#include \"".ptr as *const char);
        self.emit_rel_prefix();
        let mut i: usize = 0;
        while unsafe path[i] != 0 as char {
            if unsafe path[i] == ':' as char && unsafe path[i + 1] == ':' as char {
                self.emit_cstr("/".ptr as *const char);
                i = i + 1;
            } else {
                self.emit_bytes(unsafe (path + i) as *const char, 1);
            }
            i = i + 1;
        }
        self.emit_cstr(".h\"\n".ptr as *const char);
    }
    fn type_mentions_builtin(self: &Self, t: TypeId) bool {
        if t == TYPE_NONE { return false; }
        let y = *self.type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN { return true; }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
            return self.type_mentions_builtin(y.as_data.elem);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let mut i: u8 = 0;
            while i < it.n { if self.type_mentions_builtin(it.args[i as usize]) { return true; } i = i + 1; }
            return false;
        }
        return false;
    }
    fn cg_decl_is_interface_member(self: &Self, m: ModuleId, node: NodeId) bool {
        let a = self.mod_ast(m);
        let nk = unsafe (*a).at_const(node).kind;
        if nk == NodeKind::NODE_INTERFACE { return true; }
        if nk != NodeKind::NODE_FUNCTION { return false; }
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let ids = unsafe (*a).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let it = unsafe (*a).at_const(unsafe ids[i as usize]);
            if it.kind == NodeKind::NODE_INTERFACE {
                let ms = it.as_data.interface_def.items;
                let mids = unsafe (*a).list(ms);
                let mut j: u32 = 0;
                while j < ms.len { if unsafe mids[j as usize] == node { return true; } j = j + 1; }
            }
            i = i + 1;
        }
        return false;
    }
    fn mark_layout_module(self: &Self, ft: TypeId, want: *mut bool, nmod: usize) void {
        if ft == TYPE_NONE { return; }
        let mut cft = self.subst_resolve(ft);
        let mut y = *self.type_at(cft);
        while y.kind == TypeKind::TYPE_ARRAY { cft = y.as_data.elem; y = *self.type_at(cft); }
        let cur = self.cur_module();
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let mut bb: i32 = -1;
            if self.package != null { bb = unsafe (*self.package).builtin_of_decl(y.module, y.as_data.decl); }
            if y.module != cur && (y.module as usize) < nmod && bb < 0 { unsafe want[y.module as usize] = true; }
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            let home = unsafe (*self.package).instance_home(unsafe (&*self.cur_ast()), &it);
            if home != cur && (home as usize) < nmod { unsafe want[home as usize] = true; }
        }
    }
    fn mark_aggregate_layout(self: &Self, dn_id: NodeId, want: *mut bool, nmod: usize) void {
        let ag = unsafe (*self.cur_ast()).at_const(dn_id).as_data.aggregate;
        let dk = unsafe (*self.cur_ast()).at_const(dn_id).kind;
        let ms = ag.members;
        let mids = unsafe (*self.cur_ast()).list(ms);
        let mut m: u32 = 0;
        while m < ms.len {
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
                let mut k: u32 = 0;
                while k < payload.len {
                    let pid = unsafe plids[k as usize];
                    let pfk = unsafe (*self.cur_ast()).at_const(pid).kind;
                    let tn = if (pfk == NodeKind::NODE_FIELD) { unsafe (*self.cur_ast()).at_const(pid).as_data.field.ty; } else { pid; };
                    self.mark_layout_module(unsafe (*self.cur_ast()).type_of(tn), want, nmod);
                    k = k + 1;
                }
            }
            m = m + 1;
        }
    }
}

// ---- dyn trait objects: vtables + glue ----
extend Codegen {
    fn cg_dyn_method(self: &Self, im: ModuleId, m_id: NodeId) bool {
        let mf = unsafe (*self.mod_ast(im)).at_const(m_id).as_data.function;
        let mk = unsafe (*self.mod_ast(im)).at_const(m_id).kind;
        if mk != NodeKind::NODE_FUNCTION || mf.params.len == 0 { return false; }
        let p0 = unsafe ((*self.mod_ast(im)).list(mf.params))[0];
        let p0name = unsafe (*self.mod_ast(im)).at_const(p0).as_data.parameter.name;
        return span_is(self.mod_src(im), unsafe (*self.mod_ast(im)).at_const(p0name).as_data.name.text, "self".ptr as *const char);
    }
    fn cg_dyn_ret(self: &mut Self, im: ModuleId, m_id: NodeId) TypeId {
        let rets = unsafe (*self.mod_ast(im)).at_const(m_id).as_data.function.returns;
        if rets.len != 1 { return TYPE_NONE; }
        let r0 = unsafe ((*self.mod_ast(im)).list(rets))[0];
        let rn = unsafe (*self.mod_ast(im)).at_const(r0);
        let rtn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { r0; };
        let rt = unsafe (*self.mod_ast(im)).type_of(rtn);
        if rt == TYPE_NONE { return TYPE_NONE; }
        let rty = *unsafe (*self.mod_ast(im)).type_at(rt);
        if rty.kind == TypeKind::TYPE_BUILTIN && rty.as_data.builtin == BuiltinType::BT_VOID { return TYPE_NONE; }
        return unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(im)), rt);
    }
    fn cg_dyn_target(self: &Self, sy: &Ty, tm: *mut ModuleId, td: *mut NodeId) bool {
        if sy.kind == TypeKind::TYPE_INSTANCE {
            unsafe (*tm) = unsafe (*self.cur_ast()).instance(sy.as_data.inst).module;
            unsafe (*td) = unsafe (*self.cur_ast()).instance(sy.as_data.inst).decl;
        } else if sy.kind == TypeKind::TYPE_STRUCT || sy.kind == TypeKind::TYPE_ENUM {
            unsafe (*tm) = sy.module;
            unsafe (*td) = sy.as_data.decl;
        } else if sy.kind == TypeKind::TYPE_BUILTIN && self.package != null && unsafe (*self.package).builtin_decl(sy.as_data.builtin) != NODE_NONE {
            unsafe (*tm) = unsafe (*self.package).core_module;
            unsafe (*td) = unsafe (*self.package).builtin_decl(sy.as_data.builtin);
        } else {
            return false;
        }
        return true;
    }
    fn cg_dynfn_ret(self: &mut Self, m: ModuleId, sig: NodeId) TypeId {
        let ft = unsafe (*self.mod_ast(m)).at_const(sig).as_data.function_type;
        if ft.returns.len != 1 { return TYPE_NONE; }
        let r0 = unsafe ((*self.mod_ast(m)).list(ft.returns))[0];
        let rn = unsafe (*self.mod_ast(m)).at_const(r0);
        let rtn = if (rn.kind == NodeKind::NODE_PARAMETER) { rn.as_data.parameter.ty; } else { r0; };
        let rt = unsafe (*self.mod_ast(m)).type_of(rtn);
        if rt == TYPE_NONE { return TYPE_NONE; }
        let rty = *unsafe (*self.mod_ast(m)).type_at(rt);
        if rty.kind == TypeKind::TYPE_BUILTIN && rty.as_data.builtin == BuiltinType::BT_VOID { return TYPE_NONE; }
        return unsafe (*self.cur_ast()).reintern(unsafe (&*self.mod_ast(m)), rt);
    }
}

fn cg_int_range(b: BuiltinType, mn: *mut i64, mx: *mut i64) void {
    if b == BuiltinType::BT_I8 { unsafe (*mn) = -128; unsafe (*mx) = 127; }
    else if b == BuiltinType::BT_I16 { unsafe (*mn) = -32768; unsafe (*mx) = 32767; }
    else if b == BuiltinType::BT_I32 { unsafe (*mn) = -2147483648; unsafe (*mx) = 2147483647; }
    else { unsafe (*mn) = (1 as u64 << 63) as i64; unsafe (*mx) = ((1 as u64 << 63) - 1) as i64; }
}

// ---- assert / format builtins ----
extend Codegen {
    fn cg_struct_name_is(self: &Self, y: &Ty, lit: *const char) bool {
        let mut m: ModuleId = 0;
        let mut decl: NodeId = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT { m = y.module; decl = y.as_data.decl; }
        else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.cur_ast()).instance(y.as_data.inst);
            m = it.module;
            decl = it.decl;
        } else { return false; }
        let anm = unsafe (*self.mod_ast(m)).at_const(decl).as_data.aggregate.name;
        return span_is(self.mod_src(m), unsafe (*self.mod_ast(m)).at_const(anm).as_data.name.text, lit);
    }
    fn cg_line_of(self: &Self, off: u32) u32 {
        let mut line: u32 = 1;
        let mut i: u32 = 0;
        while i < off && (i as usize) < self.len {
            if unsafe self.source[i as usize] == '\n' as u8 { line = line + 1; }
            i = i + 1;
        }
        return line;
    }
    fn emit_pct_escaped(self: &mut Self, text: *const u8, len: usize) void {
        let mut i: usize = 0;
        while i < len {
            let byte = unsafe text[i];
            if byte == '%' as u8 { self.emit_cstr("%%".ptr as *const char); }
            else if byte == '"' as u8 || byte == '\\' as u8 { self.emit("\\%c".ptr as *const char, byte as i32); }
            else if byte == '\n' as u8 { self.emit_cstr("\\n".ptr as *const char); }
            else if byte < 0x20 as u8 { self.emit("\\%03o".ptr as *const char, byte as i32); }
            else { self.emit("%c".ptr as *const char, byte as i32); }
            i = i + 1;
        }
    }
    fn cg_file(self: &Self) *const char {
        if self.package != null && (self.cur_module() as usize) < self.pkg_count() {
            let f = unsafe (*self.package).modules.at(self.cur_module() as usize).file;
            if f != null { return f as *const char; }
        }
        return "<src>".ptr as *const char;
    }
    fn cg_assert_kind(self: &Self, id: NodeId) i32 {
        if self.package == null { return 0; }
        let callee = unsafe (*self.cur_ast()).at_const(id).as_data.call.callee;
        if unsafe (*self.cur_ast()).at_const(callee).kind != NodeKind::NODE_IDENTIFIER { return 0; }
        let d = unsafe (*self.cur_ast()).resolution_def(callee);
        if d.node == NODE_NONE || d.module as usize >= self.pkg_count() || !unsafe (*self.package).modules.at(d.module as usize).prelude { return 0; }
        if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_FUNCTION { return 0; }
        let fnamenode = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.function.name;
        let fnm = unsafe (*self.mod_ast(d.module)).at_const(fnamenode).as_data.name.text;
        let s = self.mod_src(d.module);
        if span_is(s, fnm, "assert".ptr as *const char) { return 1; }
        if span_is(s, fnm, "assert_eq".ptr as *const char) { return 2; }
        if span_is(s, fnm, "assert_ne".ptr as *const char) { return 3; }
        return 0;
    }
    fn emit_assert_value_line(self: &mut Self, label: *const char, acc: *const char, y: Ty, base: TypeId) void {
        self.emit("fprintf(stderr, \"  %s ".ptr as *const char, label);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let bt = y.as_data.builtin;
            if bt == BuiltinType::BT_BOOL { self.emit("%%s\\n\", %s ? \"true\" : \"false\");\n".ptr as *const char, acc); return; }
            if bt == BuiltinType::BT_CHAR { self.emit("'%%c'\\n\", (int)%s);\n".ptr as *const char, acc); return; }
            if bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE { self.emit("%%lld\\n\", (long long)%s);\n".ptr as *const char, acc); return; }
            if bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE { self.emit("%%llu\\n\", (unsigned long long)%s);\n".ptr as *const char, acc); return; }
            if bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 { self.emit("%%g\\n\", (double)%s);\n".ptr as *const char, acc); return; }
        }
        if self.cg_struct_name_is(&y, "str".ptr as *const char) {
            self.emit("\\\"%%.*s\\\"\\n\", (int)%s.len, (const char *)%s.ptr);\n".ptr as *const char, acc, acc);
            return;
        }
        if self.cg_struct_name_is(&y, "String".ptr as *const char) {
            let mut sm = Buf200 {};
            self.render_type_id(base, "".ptr as *const char, (&mut sm.b[0]) as *mut char, 200);
            self.emit("\\\"%%.*s\\\"\\n\", (int)%s__as_str(&%s).len, (const char *)%s__as_str(&%s).ptr);\n".ptr as *const char, (&sm.b[0]) as *const char, acc, (&sm.b[0]) as *const char, acc);
            return;
        }
        self.emit_cstr("(value of a non-printable type)\\n\");\n".ptr as *const char);
    }
}

// A parsed `{...}` placeholder: `{:[fill][<^>][0][width][.prec][x|X|b]}`.
pub struct FmtSpec { pub ty: char, pub align: char, pub fill: u8, pub width: i32, pub prec: i32 }

fn bt_is_numeric(b: BuiltinType) bool { let v = b as i32; return v >= (BuiltinType::BT_I8 as i32) && v <= (BuiltinType::BT_F64 as i32); }
fn bt_is_signed_int(b: BuiltinType) bool { let v = b as i32; return v >= (BuiltinType::BT_I8 as i32) && v <= (BuiltinType::BT_ISIZE as i32); }
fn bt_is_unsigned_int(b: BuiltinType) bool { let v = b as i32; return v >= (BuiltinType::BT_U8 as i32) && v <= (BuiltinType::BT_USIZE as i32); }
fn bt_is_binfmt(b: BuiltinType) bool { let v = b as i32; return v >= (BuiltinType::BT_CHAR as i32) && v <= (BuiltinType::BT_USIZE as i32); }
fn bt_unsigned_cast(b: BuiltinType) *const char {
    if b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 || b == BuiltinType::BT_CHAR { return "uint8_t".ptr as *const char; }
    if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 { return "uint16_t".ptr as *const char; }
    if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 { return "uint32_t".ptr as *const char; }
    return "uint64_t".ptr as *const char;
}

extend Codegen {
    fn fmt_arg_core(self: &mut Self, tb: *const char, arg: NodeId, sp: &FmtSpec, y: Ty, t: TypeId) bool {
        if sp.ty == 'x' as char || sp.ty == 'X' as char {
            let ud = if (sp.ty == 'X' as char) { "true".ptr as *const char; } else { "false".ptr as *const char; };
            if y.kind != TypeKind::TYPE_BUILTIN { return false; }
            let b = y.as_data.builtin;
            if bt_is_signed_int(b) {
                self.emit("String__Global__push_hex_i64(&%s, (int64_t)(".ptr as *const char, tb);
                self.emit_expr(arg);
                self.emit("), %s);\n".ptr as *const char, ud);
                return true;
            }
            if bt_is_unsigned_int(b) || b == BuiltinType::BT_CHAR {
                self.emit("String__Global__push_hex(&%s, (uint64_t)(".ptr as *const char, tb);
                self.emit_expr(arg);
                self.emit("), %s);\n".ptr as *const char, ud);
                return true;
            }
            return false;
        }
        if sp.ty == 'b' as char {
            if y.kind != TypeKind::TYPE_BUILTIN || !bt_is_binfmt(y.as_data.builtin) { return false; }
            self.emit("String__Global__push_bin(&%s, (uint64_t)(%s)(".ptr as *const char, tb, bt_unsigned_cast(y.as_data.builtin));
            self.emit_expr(arg);
            self.emit_cstr("));\n".ptr as *const char);
            return true;
        }
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL {
                self.emit_cstr("if (".ptr as *const char);
                self.emit_expr(arg);
                self.emit(") String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)\"true\", .len = 4 });".ptr as *const char, tb);
                self.emit(" else String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)\"false\", .len = 5 });\n".ptr as *const char, tb);
                return true;
            }
            if b == BuiltinType::BT_CHAR {
                self.emit("String__Global__push_byte(&%s, (uint8_t)(".ptr as *const char, tb);
                self.emit_expr(arg);
                self.emit_cstr("));\n".ptr as *const char);
                return true;
            }
            if bt_is_signed_int(b) {
                self.emit("String__Global__push_i64(&%s, (int64_t)(".ptr as *const char, tb);
                self.emit_expr(arg);
                self.emit_cstr("));\n".ptr as *const char);
                return true;
            }
            if bt_is_unsigned_int(b) {
                self.emit("String__Global__push_u64(&%s, (uint64_t)(".ptr as *const char, tb);
                self.emit_expr(arg);
                self.emit_cstr("));\n".ptr as *const char);
                return true;
            }
            if b == BuiltinType::BT_F32 || b == BuiltinType::BT_F64 {
                if sp.prec >= 0 {
                    self.emit("String__Global__push_f64_prec(&%s, (double)(".ptr as *const char, tb);
                    self.emit_expr(arg);
                    self.emit("), %d);\n".ptr as *const char, sp.prec);
                } else {
                    self.emit("String__Global__push_f64(&%s, (double)(".ptr as *const char, tb);
                    self.emit_expr(arg);
                    self.emit_cstr("));\n".ptr as *const char);
                }
                return true;
            }
            return false;
        }
        if self.cg_struct_name_is(&y, "str".ptr as *const char) {
            self.emit("String__Global__push_str(&%s, ".ptr as *const char, tb);
            self.emit_expr(arg);
            self.emit_cstr(");\n".ptr as *const char);
            return true;
        }
        if self.cg_struct_name_is(&y, "String".ptr as *const char) {
            let mut sm = Buf200 {};
            self.render_type_id(t, "".ptr as *const char, (&mut sm.b[0]) as *mut char, 200);
            let smp = (&sm.b[0]) as *const char;
            if self.is_lvalue(arg) {
                self.emit("String__Global__push_str(&%s, %s__as_str(&(".ptr as *const char, tb, smp);
                self.emit_expr(arg);
                self.emit_cstr(")));\n".ptr as *const char);
            } else {
                let mut tmp = Buf32 {};
                self.fresh((&mut tmp.b[0]) as *mut char, 32);
                let tmpp = (&tmp.b[0]) as *const char;
                self.emit("{ %s %s = ".ptr as *const char, smp, tmpp);
                self.emit_expr(arg);
                self.emit("; String__Global__push_str(&%s, %s__as_str(&%s)); %s__free(&%s); }\n".ptr as *const char, tb, smp, tmpp, smp, tmpp);
            }
            return true;
        }
        return false;
    }
    fn emit_format_arg(self: &mut Self, f: *const char, arg: NodeId, sp: &FmtSpec) bool {
        let t = self.subst_resolve(unsafe (*self.cur_ast()).type_of(arg));
        let y = *self.type_at(t);
        if sp.prec >= 0 && !(y.kind == TypeKind::TYPE_BUILTIN && (y.as_data.builtin == BuiltinType::BT_F32 || y.as_data.builtin == BuiltinType::BT_F64)) { return false; }
        if sp.width <= 0 { return self.fmt_arg_core(f, arg, sp, y, t); }
        let numeric = y.kind == TypeKind::TYPE_BUILTIN && bt_is_numeric(y.as_data.builtin);
        let align = if (sp.align == '<' as char) { 0; } else if (sp.align == '^' as char) { 2; } else if (sp.align == '>' as char) { 1; } else if (numeric) { 1; } else { 0; };
        let fill = if (sp.fill != 0 as u8) { sp.fill; } else { ' ' as u8; };
        if self.cg_struct_name_is(&y, "str".ptr as *const char) {
            self.emit("String__Global__push_padded(&%s, ".ptr as *const char, f);
            self.emit_expr(arg);
            self.emit(", %d, %u, %d);\n".ptr as *const char, sp.width, fill as u32, align);
            return true;
        }
        let mut tmp = Buf32 {};
        self.fresh((&mut tmp.b[0]) as *mut char, 32);
        let tp = (&tmp.b[0]) as *const char;
        self.emit("{ String__Global %s = String__Global__new();\n".ptr as *const char, tp);
        if !self.fmt_arg_core(tp, arg, sp, y, t) {
            self.emit("String__Global__free(&%s); }\n".ptr as *const char, tp);
            return false;
        }
        self.emit("String__Global__push_padded(&%s, String__Global__as_str(&%s), %d, %u, %d);\n".ptr as *const char, f, tp, sp.width, fill as u32, align);
        self.emit("String__Global__free(&%s); }\n".ptr as *const char, tp);
        return true;
    }
    fn emit_fmt_cstr(self: &mut Self, a: usize, b: usize) void {
        let src = self.source;
        self.emit_cstr("\"".ptr as *const char);
        let mut i = a;
        while i < b {
            if (unsafe src[i] == '{' as u8 || unsafe src[i] == '}' as u8) && i + 1 < b && unsafe src[i + 1] == unsafe src[i] {
                self.emit("%c".ptr as *const char, unsafe src[i] as i32);
                i = i + 2;
                continue;
            }
            if unsafe src[i] == '\\' as u8 && i + 1 < b {
                let e = unsafe src[i + 1];
                if e == 'x' as u8 && i + 3 < b {
                    let v = ((hex_val(unsafe src[i + 2]) << 4) | hex_val(unsafe src[i + 3])) & 0xFF;
                    self.emit("\\%03o".ptr as *const char, v);
                    i = i + 4;
                } else if e == '0' as u8 {
                    self.emit_cstr("\\000".ptr as *const char);
                    i = i + 2;
                } else {
                    self.emit("\\%c".ptr as *const char, e as i32);
                    i = i + 2;
                }
                continue;
            }
            self.emit("%c".ptr as *const char, unsafe src[i] as i32);
            i = i + 1;
        }
        self.emit_cstr("\"".ptr as *const char);
    }
    fn emit_fmt_raw_cstr(self: &mut Self, a: usize, b: usize) void {
        let src = self.source;
        self.emit_cstr("\"".ptr as *const char);
        let mut i = a;
        while i < b {
            if (unsafe src[i] == '{' as u8 || unsafe src[i] == '}' as u8) && i + 1 < b && unsafe src[i + 1] == unsafe src[i] {
                self.emit("%c".ptr as *const char, unsafe src[i] as i32);
                i = i + 2;
                continue;
            }
            let byte = unsafe src[i];
            i = i + 1;
            if byte == '"' as u8 || byte == '\\' as u8 { self.emit("\\%c".ptr as *const char, byte as i32); }
            else if byte == '\n' as u8 { self.emit_cstr("\\n".ptr as *const char); }
            else if byte < 0x20 as u8 { self.emit("\\%03o".ptr as *const char, byte as i32); }
            else { self.emit("%c".ptr as *const char, byte as i32); }
        }
        self.emit_cstr("\"".ptr as *const char);
    }
    fn emit_fmt_seg(self: &mut Self, f: *const char, is_raw: bool, from: usize, to: usize) void {
        self.emit("String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)".ptr as *const char, f);
        if is_raw { self.emit_fmt_raw_cstr(from, to); } else { self.emit_fmt_cstr(from, to); }
        self.emit_cstr(", .len = sizeof(".ptr as *const char);
        if is_raw { self.emit_fmt_raw_cstr(from, to); } else { self.emit_fmt_cstr(from, to); }
        self.emit_cstr(") - 1 });\n".ptr as *const char);
    }
}

// ---- @emit_macro C-reuse templates ----
extend Codegen {
    fn macro_stem(self: &Self, m: ModuleId, aggregate_name: NodeId, out: *mut char, cap: usize) void {
        let n = self.render_qualified(m, aggregate_name, out, cap);
        let mut i: usize = 0;
        while i < n && i < cap {
            let ch = unsafe out[i];
            if ch >= 'a' as char && ch <= 'z' as char { unsafe out[i] = (ch as i32 - 32) as char; }
            else if !((ch >= 'A' as char && ch <= 'Z' as char) || (ch >= '0' as char && ch <= '9' as char)) { unsafe out[i] = '_' as char; }
            i = i + 1;
        }
    }
    fn macro_finish(self: &mut Self, start: usize) void {
        if self.buf_len <= start { return; }
        let mut endp = self.buf_len;
        while endp > start && unsafe self.buf[endp - 1] == '\n' as char { endp = endp - 1; }
        let nlen = endp - start;
        let tmp = unsafe stdlib::malloc(nlen) as *mut char;
        if tmp == null { diag::oom(); }
        unsafe cstring::memcpy(tmp as *mut void, (self.buf + start) as *const void, nlen);
        self.buf_len = start;
        let mut i: usize = 0;
        while i < nlen {
            let ch = unsafe tmp[i];
            if ch == '\n' as char { self.emit_bytes(" \\\n".ptr as *const char, 3); }
            else if ch == CG_PASTE { self.emit_bytes("##".ptr as *const char, 2); }
            else { self.emit_bytes(unsafe (tmp + i) as *const char, 1); }
            i = i + 1;
        }
        self.emit_bytes("\n".ptr as *const char, 1);
        unsafe stdlib::free(tmp as *mut void);
    }
    fn emit_generic_macro_methods(self: &mut Self, declId: NodeId, define: bool) void {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 { i = i + 1; continue; }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != declId { i = i + 1; continue; }
            if ed.interface_type != NODE_NONE { i = i + 1; continue; }
            let mids = unsafe (*self.cur_ast()).list(ed.items);
            let mut j: u32 = 0;
            while j < ed.items.len {
                let mid = unsafe mids[j as usize];
                let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
                let mk = unsafe (*self.cur_ast()).at_const(mid).kind;
                if mk != NodeKind::NODE_FUNCTION || mf.generics.len != 0 || mf.returns.len > 1 { j = j + 1; continue; }
                if define && mf.body == NODE_NONE { j = j + 1; continue; }
                let mut nm = Buf320 {};
                let mut at = bappend((&mut nm.b[0]) as *mut char, 320, 0, "NAME".ptr as *const char);
                unsafe nm.b[at] = CG_PASTE;
                at = at + 1;
                at = bappend((&mut nm.b[0]) as *mut char, 320, at, "__".ptr as *const char);
                let mnsp = self.name_span(mf.name);
                self.render_ident(mnsp, unsafe ((&mut nm.b[0]) as *mut char + at) as *mut char, 320 - at);
                self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, define, (&nm.b[0]) as *const char, false);
                j = j + 1;
            }
            i = i + 1;
        }
    }
    fn conformance_tag(self: &Self, extend_id: NodeId, out: *mut char, cap: usize) usize {
        let it = unsafe (*self.cur_ast()).resolution_def(unsafe (*self.cur_ast()).at_const(extend_id).as_data.extend_def.interface_type);
        let at = bappend(out, cap, 0, "as_".ptr as *const char);
        if it.node == NODE_NONE { return at; }
        let trname = unsafe (*self.mod_ast(it.module)).at_const(it.node).as_data.interface_def.name;
        let sp = unsafe (*self.mod_ast(it.module)).at_const(trname).as_data.name.text;
        let room = if (cap > at) { cap - at; } else { 0 as usize; };
        return at + render_ident_src(self.mod_src(it.module), sp, unsafe (out + at) as *mut char, room);
    }
    fn emit_generic_conformance_macro(self: &mut Self, declId: NodeId, implId: NodeId, define: bool) void {
        let dn_name = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.name;
        let mut stem = Buf160 {};
        self.macro_stem(self.cur_module(), dn_name, (&mut stem.b[0]) as *mut char, 160);
        let mut tag = Buf128 {};
        self.conformance_tag(implId, (&mut tag.b[0]) as *mut char, 128);
        let word = if (define) { "DEFINE".ptr as *const char; } else { "DECLARE".ptr as *const char; };
        self.emit("#define %s_%s_%s(".ptr as *const char, (&stem.b[0]) as *const char, (&tag.b[0]) as *const char, word);
        let gens = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        let mut i: u32 = 0;
        while i < gens.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe gids[i as usize], (&mut p.b[0]) as *mut char, 64);
            self.emit("%s, _SCM_%s, ".ptr as *const char, (&p.b[0]) as *const char, (&p.b[0]) as *const char);
            i = i + 1;
        }
        self.emit_cstr("NAME) ".ptr as *const char);
        self.macro_mode = true;
        self.macro_self = declId;
        self.macro_self_mod = self.cur_module();
        self.nsubst = 0;
        let start = self.buf_len;
        let mids = unsafe (*self.cur_ast()).list(unsafe (*self.cur_ast()).at_const(implId).as_data.extend_def.items);
        let msn = unsafe (*self.cur_ast()).at_const(implId).as_data.extend_def.items.len;
        let mut j: u32 = 0;
        while j < msn {
            let mid = unsafe mids[j as usize];
            let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
            let mk = unsafe (*self.cur_ast()).at_const(mid).kind;
            if mk != NodeKind::NODE_FUNCTION || mf.generics.len != 0 || mf.returns.len > 1 { j = j + 1; continue; }
            if define && mf.body == NODE_NONE { j = j + 1; continue; }
            let mut nm = Buf320 {};
            let mut at = bappend((&mut nm.b[0]) as *mut char, 320, 0, "NAME".ptr as *const char);
            unsafe nm.b[at] = CG_PASTE;
            at = at + 1;
            at = bappend((&mut nm.b[0]) as *mut char, 320, at, "__".ptr as *const char);
            let mnsp = self.name_span(mf.name);
            self.render_ident(mnsp, unsafe ((&mut nm.b[0]) as *mut char + at) as *mut char, 320 - at);
            self.emit_function(mid, DefId { module: 0, node: NODE_NONE }, false, define, (&nm.b[0]) as *const char, false);
            j = j + 1;
        }
        self.macro_mode = false;
        self.macro_self = NODE_NONE;
        self.macro_finish(start);
        self.emit_cstr("\n".ptr as *const char);
    }
    fn emit_generic_conformance_macros(self: &mut Self, declId: NodeId) void {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 || ed.interface_type == NODE_NONE { i = i + 1; continue; }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != declId { i = i + 1; continue; }
            self.emit_generic_conformance_macro(declId, nid, false);
            self.emit_generic_conformance_macro(declId, nid, true);
            i = i + 1;
        }
    }
    fn emit_generic_macro(self: &mut Self, declId: NodeId, define: bool) void {
        let dn_name = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.name;
        let dn_kind = unsafe (*self.cur_ast()).at_const(declId).kind;
        let mut stem = Buf160 {};
        self.macro_stem(self.cur_module(), dn_name, (&mut stem.b[0]) as *mut char, 160);
        let gens = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        let word = if (define) { "DEFINE".ptr as *const char; } else { "DECLARE".ptr as *const char; };
        self.emit("#define %s_%s(".ptr as *const char, (&stem.b[0]) as *const char, word);
        let mut i: u32 = 0;
        while i < gens.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe gids[i as usize], (&mut p.b[0]) as *mut char, 64);
            self.emit("%s, _SCM_%s, ".ptr as *const char, (&p.b[0]) as *const char, (&p.b[0]) as *const char);
            i = i + 1;
        }
        self.emit_cstr("NAME) ".ptr as *const char);
        self.macro_mode = true;
        self.macro_self = declId;
        self.macro_self_mod = self.cur_module();
        self.nsubst = 0;
        let start = self.buf_len;
        if !define {
            if dn_kind == NodeKind::NODE_STRUCT {
                let kw = agg_kw(unsafe (*self.cur_ast()).at_const(declId));
                self.emit("typedef %s NAME NAME;\n".ptr as *const char, kw);
                self.emit("%s NAME {\n".ptr as *const char, kw);
                self.depth = self.depth + 1;
                let fs = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.members;
                let fids = unsafe (*self.cur_ast()).list(fs);
                let mut jj: u32 = 0;
                while jj < fs.len {
                    let f = unsafe (*self.cur_ast()).at_const(unsafe fids[jj as usize]).as_data.field;
                    let mut fnm = Buf128 {};
                    let fnsp = self.name_span(f.name);
                    self.render_ident(fnsp, (&mut fnm.b[0]) as *mut char, 128);
                    let mut dd = Buf256 {};
                    self.render_type_node(f.ty, (&fnm.b[0]) as *const char, (&mut dd.b[0]) as *mut char, 256);
                    self.emit_indent();
                    self.emit_cstr((&dd.b[0]) as *const char);
                    self.emit_cstr(";\n".ptr as *const char);
                    jj = jj + 1;
                }
                self.depth = self.depth - 1;
                self.emit_cstr("};\n".ptr as *const char);
            } else if self.aggregate_has_payload(declId) {
                self.emit_cstr("typedef struct NAME NAME;\n".ptr as *const char);
                self.emit_cstr("struct NAME {\n".ptr as *const char);
                self.emit_enum_struct_body(declId);
                self.emit_cstr("};\n".ptr as *const char);
            } else {
                self.emit_cstr("typedef ".ptr as *const char);
                self.emit_local_type_name(dn_name);
                self.emit_cstr(" NAME;\n".ptr as *const char);
            }
        }
        self.emit_generic_macro_methods(declId, define);
        self.macro_mode = false;
        self.macro_self = NODE_NONE;
        self.macro_finish(start);
        self.emit_cstr("\n".ptr as *const char);
    }
    fn macro_method_name(self: &Self, methodId: NodeId, out: *mut char, cap: usize) void {
        let mnnode = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.name;
        let mnsp = self.name_span(mnnode);
        let mut at = bappend(out, cap, 0, "NAME".ptr as *const char);
        if at < cap { unsafe out[at] = CG_PASTE; at = at + 1; }
        at = bappend(out, cap, at, "__".ptr as *const char);
        at = at + self.render_ident(mnsp, unsafe (out + at) as *mut char, cap - at);
        at = bappend(out, cap, at, "__".ptr as *const char);
        let mg = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.generics;
        let mgids = unsafe (*self.cur_ast()).list(mg);
        let mut k: u32 = 0;
        while k < mg.len {
            if k != 0 {
                if at < cap { unsafe out[at] = CG_PASTE; at = at + 1; }
                at = bappend(out, cap, at, "__".ptr as *const char);
            }
            if at < cap { unsafe out[at] = CG_PASTE; at = at + 1; }
            at = bappend(out, cap, at, "_SCM_".ptr as *const char);
            at = at + self.render_macro_param(self.cur_module(), unsafe mgids[k as usize], unsafe (out + at) as *mut char, cap - at);
            k = k + 1;
        }
    }
    fn emit_generic_method_macro(self: &mut Self, declId: NodeId, methodId: NodeId, define: bool) void {
        let dn_name = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.name;
        let mut stem = Buf160 {};
        self.macro_stem(self.cur_module(), dn_name, (&mut stem.b[0]) as *mut char, 160);
        let mnnode = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.name;
        let mut mnm = Buf64 {};
        let mnsp = self.name_span(mnnode);
        self.render_ident(mnsp, (&mut mnm.b[0]) as *mut char, 64);
        let word = if (define) { "DEFINE".ptr as *const char; } else { "DECLARE".ptr as *const char; };
        self.emit("#define %s_%s_%s(".ptr as *const char, (&stem.b[0]) as *const char, (&mnm.b[0]) as *const char, word);
        let gens = unsafe (*self.cur_ast()).at_const(declId).as_data.aggregate.generics;
        let gids = unsafe (*self.cur_ast()).list(gens);
        let mut i: u32 = 0;
        while i < gens.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe gids[i as usize], (&mut p.b[0]) as *mut char, 64);
            self.emit("%s, _SCM_%s, ".ptr as *const char, (&p.b[0]) as *const char, (&p.b[0]) as *const char);
            i = i + 1;
        }
        self.emit_cstr("NAME".ptr as *const char);
        let mg = unsafe (*self.cur_ast()).at_const(methodId).as_data.function.generics;
        let mgids = unsafe (*self.cur_ast()).list(mg);
        let mut k: u32 = 0;
        while k < mg.len {
            let mut p = Buf64 {};
            self.render_macro_param(self.cur_module(), unsafe mgids[k as usize], (&mut p.b[0]) as *mut char, 64);
            self.emit(", %s, _SCM_%s".ptr as *const char, (&p.b[0]) as *const char, (&p.b[0]) as *const char);
            k = k + 1;
        }
        self.emit_cstr(") ".ptr as *const char);
        self.macro_mode = true;
        self.macro_self = declId;
        self.macro_self_mod = self.cur_module();
        self.nsubst = 0;
        let start = self.buf_len;
        let mut ov = Buf400 {};
        self.macro_method_name(methodId, (&mut ov.b[0]) as *mut char, 400);
        self.emit_function(methodId, DefId { module: 0, node: NODE_NONE }, false, define, (&ov.b[0]) as *const char, false);
        self.macro_mode = false;
        self.macro_self = NODE_NONE;
        self.macro_finish(start);
        self.emit_cstr("\n".ptr as *const char);
    }
    fn emit_generic_method_macros(self: &mut Self, declId: NodeId) void {
        let items = self.program_items();
        let iids = unsafe (*self.cur_ast()).list(items);
        let mut i: u32 = 0;
        while i < items.len {
            let nid = unsafe iids[i as usize];
            let ed = unsafe (*self.cur_ast()).at_const(nid).as_data.extend_def;
            let nk = unsafe (*self.cur_ast()).at_const(nid).kind;
            if nk != NodeKind::NODE_EXTEND || ed.generics.len == 0 { i = i + 1; continue; }
            if unsafe (*self.cur_ast()).resolution(ed.target_type) != declId { i = i + 1; continue; }
            let mids = unsafe (*self.cur_ast()).list(ed.items);
            let mut j: u32 = 0;
            while j < ed.items.len {
                let mid = unsafe mids[j as usize];
                let mf = unsafe (*self.cur_ast()).at_const(mid).as_data.function;
                let mk = unsafe (*self.cur_ast()).at_const(mid).kind;
                if mk == NodeKind::NODE_FUNCTION && mf.generics.len != 0 && mf.returns.len <= 1 {
                    self.emit_generic_method_macro(declId, mid, false);
                    self.emit_generic_method_macro(declId, mid, true);
                }
                j = j + 1;
            }
            i = i + 1;
        }
    }
}
