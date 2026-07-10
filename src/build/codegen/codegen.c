#include "../codegen/codegen.h"
#include "../stdio.h"
#include "../stdlib.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../ast/ast.h"
#include "../driver_shim.h"
#include "../module/loader.h"
#include "../utils/errors.h"
#include "../consteval/consteval.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/map.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/result.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

_Static_assert(sizeof(codegen__codegen__CgSubst) == 12 && _Alignof(codegen__codegen__CgSubst) == 4, "super-c layout model mismatch: codegen__codegen__CgSubst");
_Static_assert(sizeof(codegen__codegen__CgInst) == 28 && _Alignof(codegen__codegen__CgInst) == 4, "super-c layout model mismatch: codegen__codegen__CgInst");
_Static_assert(sizeof(codegen__codegen__CgCbInst) == 28 && _Alignof(codegen__codegen__CgCbInst) == 4, "super-c layout model mismatch: codegen__codegen__CgCbInst");
_Static_assert(sizeof(codegen__codegen__CgLoop) == 16 && _Alignof(codegen__codegen__CgLoop) == 4, "super-c layout model mismatch: codegen__codegen__CgLoop");
_Static_assert(sizeof(codegen__codegen__CgTestCase) == 28 && _Alignof(codegen__codegen__CgTestCase) == 4, "super-c layout model mismatch: codegen__codegen__CgTestCase");
_Static_assert(sizeof(codegen__codegen__CgTestInfo) == 64 && _Alignof(codegen__codegen__CgTestInfo) == 8, "super-c layout model mismatch: codegen__codegen__CgTestInfo");
_Static_assert(sizeof(codegen__codegen__Buf32) == 32 && _Alignof(codegen__codegen__Buf32) == 1, "super-c layout model mismatch: codegen__codegen__Buf32");
_Static_assert(sizeof(codegen__codegen__Buf64) == 64 && _Alignof(codegen__codegen__Buf64) == 1, "super-c layout model mismatch: codegen__codegen__Buf64");
_Static_assert(sizeof(codegen__codegen__Buf128) == 128 && _Alignof(codegen__codegen__Buf128) == 1, "super-c layout model mismatch: codegen__codegen__Buf128");
_Static_assert(sizeof(codegen__codegen__Buf160) == 160 && _Alignof(codegen__codegen__Buf160) == 1, "super-c layout model mismatch: codegen__codegen__Buf160");
_Static_assert(sizeof(codegen__codegen__Buf256) == 256 && _Alignof(codegen__codegen__Buf256) == 1, "super-c layout model mismatch: codegen__codegen__Buf256");
_Static_assert(sizeof(codegen__codegen__Buf512) == 512 && _Alignof(codegen__codegen__Buf512) == 1, "super-c layout model mismatch: codegen__codegen__Buf512");
_Static_assert(sizeof(codegen__codegen__Codegen) == 43264 && _Alignof(codegen__codegen__Codegen) == 8, "super-c layout model mismatch: codegen__codegen__Codegen");
_Static_assert(sizeof(codegen__codegen__ScopeArr) == 6 && _Alignof(codegen__codegen__ScopeArr) == 2, "super-c layout model mismatch: codegen__codegen__ScopeArr");
_Static_assert(sizeof(codegen__codegen__Bytes4) == 4 && _Alignof(codegen__codegen__Bytes4) == 1, "super-c layout model mismatch: codegen__codegen__Bytes4");
_Static_assert(sizeof(codegen__codegen__TyArgs4) == 16 && _Alignof(codegen__codegen__TyArgs4) == 4, "super-c layout model mismatch: codegen__codegen__TyArgs4");
_Static_assert(sizeof(codegen__codegen__Buf176) == 176 && _Alignof(codegen__codegen__Buf176) == 1, "super-c layout model mismatch: codegen__codegen__Buf176");
_Static_assert(sizeof(codegen__codegen__Buf200) == 200 && _Alignof(codegen__codegen__Buf200) == 1, "super-c layout model mismatch: codegen__codegen__Buf200");
_Static_assert(sizeof(codegen__codegen__Buf240) == 240 && _Alignof(codegen__codegen__Buf240) == 1, "super-c layout model mismatch: codegen__codegen__Buf240");
_Static_assert(sizeof(codegen__codegen__Buf300) == 300 && _Alignof(codegen__codegen__Buf300) == 1, "super-c layout model mismatch: codegen__codegen__Buf300");
_Static_assert(sizeof(codegen__codegen__Buf320) == 320 && _Alignof(codegen__codegen__Buf320) == 1, "super-c layout model mismatch: codegen__codegen__Buf320");
_Static_assert(sizeof(codegen__codegen__Buf368) == 368 && _Alignof(codegen__codegen__Buf368) == 1, "super-c layout model mismatch: codegen__codegen__Buf368");
_Static_assert(sizeof(codegen__codegen__Buf400) == 400 && _Alignof(codegen__codegen__Buf400) == 1, "super-c layout model mismatch: codegen__codegen__Buf400");
_Static_assert(sizeof(codegen__codegen__Buf600) == 600 && _Alignof(codegen__codegen__Buf600) == 1, "super-c layout model mismatch: codegen__codegen__Buf600");
_Static_assert(sizeof(codegen__codegen__Buf1024) == 1024 && _Alignof(codegen__codegen__Buf1024) == 1, "super-c layout model mismatch: codegen__codegen__Buf1024");
_Static_assert(sizeof(codegen__codegen__Buf1320) == 1320 && _Alignof(codegen__codegen__Buf1320) == 1, "super-c layout model mismatch: codegen__codegen__Buf1320");
_Static_assert(sizeof(codegen__codegen__Buf1400) == 1400 && _Alignof(codegen__codegen__Buf1400) == 1, "super-c layout model mismatch: codegen__codegen__Buf1400");
_Static_assert(sizeof(codegen__codegen__Buf4096) == 4096 && _Alignof(codegen__codegen__Buf4096) == 1, "super-c layout model mismatch: codegen__codegen__Buf4096");
_Static_assert(sizeof(codegen__codegen__TyArgs32) == 128 && _Alignof(codegen__codegen__TyArgs32) == 4, "super-c layout model mismatch: codegen__codegen__TyArgs32");
_Static_assert(sizeof(codegen__codegen__Ids64) == 256 && _Alignof(codegen__codegen__Ids64) == 4, "super-c layout model mismatch: codegen__codegen__Ids64");
_Static_assert(sizeof(codegen__codegen__FmtSpec) == 12 && _Alignof(codegen__codegen__FmtSpec) == 4, "super-c layout model mismatch: codegen__codegen__FmtSpec");

static __attribute__((unused)) const char *codegen__codegen__builtin_c(ast__ast__BuiltinType const b);
static __attribute__((unused)) ast__ast__Ast *codegen__codegen__Codegen__cur_ast(const codegen__codegen__Codegen *const self);
static __attribute__((unused)) ast__ast__Ast *codegen__codegen__Codegen__mod_ast(const codegen__codegen__Codegen *const self, uint16_t const m);
static __attribute__((unused)) const uint8_t *codegen__codegen__Codegen__mod_src(const codegen__codegen__Codegen *const self, uint16_t const m);
static __attribute__((unused)) size_t codegen__codegen__Codegen__pkg_count(const codegen__codegen__Codegen *const self);
static __attribute__((unused)) consteval__consteval__ConstEval *codegen__codegen__Codegen__ceval(const codegen__codegen__Codegen *const self);
static __attribute__((unused)) uint16_t codegen__codegen__Codegen__cur_module(const codegen__codegen__Codegen *const self);
static __attribute__((unused)) const ast__ast__Ty *codegen__codegen__Codegen__type_at(const codegen__codegen__Codegen *const self, uint32_t const x);
static __attribute__((unused)) void codegen__codegen__Codegen__closure_sym_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const id, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__closure_name(const codegen__codegen__Codegen *const self, uint32_t const id, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_bytes(codegen__codegen__Codegen *const self, const char *const p, size_t const n);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_cstr(codegen__codegen__Codegen *const self, const char *const text);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_octal_escape(codegen__codegen__Codegen *const self, uint32_t const b);
static __attribute__((unused)) void codegen__codegen__Codegen__emit(codegen__codegen__Codegen *const self, const char *const fmt);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_indent(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_paste(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__fresh(codegen__codegen__Codegen *const self, char *const buf, size_t const cap);
static __attribute__((unused)) lexer__token__Span codegen__codegen__Codegen__name_span(const codegen__codegen__Codegen *const self, uint32_t const name_node);
static __attribute__((unused)) lexer__token__Span codegen__codegen__Codegen__name_span_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const name_node);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_span(codegen__codegen__Codegen *const self, lexer__token__Span const s);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_ident(codegen__codegen__Codegen *const self, lexer__token__Span const s);
static __attribute__((unused)) size_t codegen__codegen__Codegen__render_ident(const codegen__codegen__Codegen *const self, lexer__token__Span const s, char *const buf, size_t const cap);
static __attribute__((unused)) size_t codegen__codegen__Codegen__render_modpfx(const codegen__codegen__Codegen *const self, uint16_t const m, char *const buf, size_t const cap);
static __attribute__((unused)) size_t codegen__codegen__Codegen__render_qualified(const codegen__codegen__Codegen *const self, uint16_t const owner, uint32_t const name_node, char *const buf, size_t const cap);
static __attribute__((unused)) size_t codegen__codegen__Codegen__render_iface_stem(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const iface, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_ident_mod(codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const name_node);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_local_type_name(codegen__codegen__Codegen *const self, uint32_t const aggregate_name);
static __attribute__((unused)) void codegen__codegen__Codegen__build_enum_index(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__mangle_type(const codegen__codegen__Codegen *const self, uint32_t const t, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__dyn_stem(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__dyn_pair_stem(const codegen__codegen__Codegen *const self, uint32_t const src, uint16_t const im, uint32_t const iface, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__spec_name(const codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, const uint32_t *const args, int32_t const n, char *const out, size_t const cap);
static __attribute__((unused)) size_t codegen__codegen__Codegen__render_macro_param(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl, char *const buf, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__macro_arg_token(const codegen__codegen__Codegen *const self, uint32_t const arg, char *const out, size_t const cap);
static __attribute__((unused)) bool codegen__codegen__Codegen__is_self_instance(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it);
static __attribute__((unused)) void codegen__codegen__Codegen__inst_name(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, char *const out, size_t const cap);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__subst_lookup(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__subst_resolve(const codegen__codegen__Codegen *const self, uint32_t const t);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_const_param_value(const codegen__codegen__Codegen *const self, uint32_t const id, int64_t *const out);
static __attribute__((unused)) int64_t codegen__codegen__Codegen__cg_const_len_subst(const codegen__codegen__Codegen *const self, uint32_t const length);
static __attribute__((unused)) bool codegen__codegen__Codegen__type_is_concrete(const codegen__codegen__Codegen *const self, uint32_t const t);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__generic_call_target(const codegen__codegen__Codegen *const self, uint32_t const callId, uint32_t *const args, int32_t *const n);
static __attribute__((unused)) void codegen__codegen__Codegen__record_inst(codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, const uint32_t *const args, int32_t const n, uint32_t const site);
static __attribute__((unused)) void codegen__codegen__Codegen__collect_insts(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__expand_nested_insts(codegen__codegen__Codegen *const self);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_alias_extended(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const aliasDecl);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_fn_is_capturing(const codegen__codegen__Codegen *const self, const ast__ast__Ty *const fy);
static __attribute__((unused)) void codegen__codegen__Codegen__render_type_node(codegen__codegen__Codegen *const self, uint32_t const tn, const char *const decl, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__render_type_id(codegen__codegen__Codegen *const self, uint32_t const t, const char *const decl, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__render_fn_ptr_id(codegen__codegen__Codegen *const self, ast__ast__Ty const fy, const char *const decl, char *const out, size_t const cap);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__enclosing_enum(const codegen__codegen__Codegen *const self, uint32_t const variant);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__enclosing_enum_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const variant);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_tag_mod(codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const enum_decl, uint32_t const variant);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_tag(codegen__codegen__Codegen *const self, uint32_t const enum_decl, uint32_t const variant);
static __attribute__((unused)) void codegen__codegen__Codegen__render_variant_name(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const variant, char *const buf, size_t const cap);
static __attribute__((unused)) bool codegen__codegen__Codegen__aggregate_has_payload_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const enum_decl);
static __attribute__((unused)) bool codegen__codegen__Codegen__aggregate_has_payload(const codegen__codegen__Codegen *const self, uint32_t const enum_decl);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__strip_ptr(const codegen__codegen__Codegen *const self, uint32_t const t0);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__strip_ref_only(const codegen__codegen__Codegen *const self, uint32_t const t0);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_ref_depth(const codegen__codegen__Codegen *const self, uint32_t const t);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_fn_owns(codegen__codegen__Codegen *const self, const ast__ast__Ty *const fy);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_slice_elem(const codegen__codegen__Codegen *const self, uint32_t const tid, uint32_t *const elem);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_range_elem(const codegen__codegen__Codegen *const self, uint32_t const tid, uint32_t *const elem);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_free_extend(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_free_extend_uncached(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_free_method(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_param_has_free_bound(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const gp);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_type_is_free(codegen__codegen__Codegen *const self, uint32_t const ty0);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_moved(const codegen__codegen__Codegen *const self, uint32_t const decl);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_cond_moved(const codegen__codegen__Codegen *const self, uint32_t const decl);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_cond_site(const codegen__codegen__Codegen *const self, uint32_t const expr);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_find_method_impl(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const uint8_t *const nsrc, lexer__token__Span const name, const char *const lit);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_find_method(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const uint8_t *const nsrc, lexer__token__Span const name);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_find_method_cstr(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const char *const lit);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_def_const_ok(const codegen__codegen__Codegen *const self, ast__ast__DefId const d);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_maybe_const(const codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__is_lvalue(const codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) uint32_t codegen__codegen__if_node(bool const c, uint32_t const a, uint32_t const b);
static __attribute__((unused)) void codegen__codegen__cg_move_flag(char *const out, size_t const cap, uint32_t const decl);
static __attribute__((unused)) const char *codegen__codegen__ref_derefs(int32_t const d0);
static __attribute__((unused)) const char *codegen__codegen__c_op(lexer__token_type__TokenType const t);
static __attribute__((unused)) const char *codegen__codegen__cg_arith_op_method(lexer__token_type__TokenType const op);
static __attribute__((unused)) int32_t codegen__codegen__hex_val(uint8_t const ch);
static __attribute__((unused)) int32_t codegen__codegen__utf8_encode(uint32_t const cp, uint8_t *const out);
static __attribute__((unused)) lexer__token__Span codegen__codegen__raw_string_content(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_number(codegen__codegen__Codegen *const self, lexer__token__Span const s, lexer__token_type__TokenType const tt, ast__ast__BuiltinType const rb);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_reescaped(codegen__codegen__Codegen *const self, lexer__token__Span const s, bool const is_char);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_raw_c_string(codegen__codegen__Codegen *const self, lexer__token__Span const content);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_format_builtin(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_assert_builtin(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__cb_known_callee(codegen__codegen__Codegen *const self, uint32_t const arg, ast__ast__DefId *const out, bool *const is_closure);
static __attribute__((unused)) void codegen__codegen__Codegen__cb_spec_name(codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, ast__ast__DefId const callee, bool const is_closure, char *const out, size_t const cap);
static __attribute__((unused)) bool codegen__codegen__Codegen__cb_single_callback_param(const codegen__codegen__Codegen *const self, uint32_t const fnNode, uint32_t *const cbidx, uint32_t *const param);
static __attribute__((unused)) bool codegen__codegen__Codegen__param_only_callee(const codegen__codegen__Codegen *const self, uint32_t const param);
static __attribute__((unused)) void codegen__codegen__Codegen__cb_record(codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, uint32_t const param, uint32_t const cbidx, ast__ast__DefId const callee, bool const is_closure);
static __attribute__((unused)) void codegen__codegen__Codegen__cb_keep(codegen__codegen__Codegen *const self, uint32_t const fn2);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_decl_name_node(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl);
static __attribute__((unused)) const char *codegen__codegen__Codegen__cg_conv_lit(const codegen__codegen__Codegen *const self, uint16_t const m, lexer__token__Span const name);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_deref_hop(codegen__codegen__Codegen *const self, uint32_t const recv, ast__ast__DefId const md);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_call_args(codegen__codegen__Codegen *const self, ast__ast__NodeList const args);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_call_path(codegen__codegen__Codegen *const self, uint32_t const id, ast__ast__Node const n, ast__ast__Node const callee);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_call_method(codegen__codegen__Codegen *const self, uint32_t const id, ast__ast__Node const n, ast__ast__Node const callee);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_call(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_struct_init(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_new(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_match_expr(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_match_stmt(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_if_expr(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_try(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_stmt(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_block(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_binding(codegen__codegen__Codegen *const self, uint32_t const t, lexer__token__Span const name, bool const is_const);
static __attribute__((unused)) void codegen__codegen__Codegen__render_binding_node(codegen__codegen__Codegen *const self, uint32_t const tn, const char *const name, bool const is_const, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_static_assert(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_tuple_let(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_return(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_loop_body_tail(codegen__codegen__Codegen *const self, uint32_t const dbase, int32_t const le);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_for_range(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_for(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_initializer(codegen__codegen__Codegen *const self, uint32_t const tn, uint32_t const val);
static __attribute__((unused)) void codegen__codegen__Codegen__render_binding_id(codegen__codegen__Codegen *const self, uint32_t const t, const char *const name, bool const is_const, char *const out, size_t const cap);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_arm_frees(codegen__codegen__Codegen *const self, uint32_t const pid, bool const do_emit);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_arm_body(codegen__codegen__Codegen *const self, uint32_t const body, int32_t const mode, const char *const result, uint32_t const pattern, bool const by_ref);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_match_core(codegen__codegen__Codegen *const self, uint32_t const id, int32_t const mode, const char *const result);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_enum_variant(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const enumDecl, const char *const lit);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_method_extend_target(const codegen__codegen__Codegen *const self, ast__ast__DefId const md);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_will_auto_free(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_register_auto_free(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_capture_init(codegen__codegen__Codegen *const self, uint32_t const clos, uint32_t const idx);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_mark_move(codegen__codegen__Codegen *const self, uint32_t const expr0, bool const cond, int32_t const pass, bool const site);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_mark_move_tail(codegen__codegen__Codegen *const self, uint32_t const e, bool const cond, int32_t const pass);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_scan_moves(codegen__codegen__Codegen *const self, uint32_t const id, bool const cond, int32_t const pass);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_arith_overload(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_cg_checked_arith(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_slice_coercion(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_dyn_coercion(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__array_length_of(codegen__codegen__Codegen *const self, uint32_t const iter);
static __attribute__((unused)) int64_t codegen__codegen__Codegen__array_literal_count(codegen__codegen__Codegen *const self, uint32_t const obj);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_int_lit(codegen__codegen__Codegen *const self, uint32_t const e, int64_t *const out);
static __attribute__((unused)) const ast__ast__Attr *codegen__codegen__Codegen__cg_attr(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const owner, ast__ast__AttrKind const kind);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_symbol_override(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const fn2, char *const out, size_t const cap);
static __attribute__((unused)) bool codegen__codegen__Codegen__decl_is_toplevel(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const node);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_env_capture(const codegen__codegen__Codegen *const self, uint32_t const decl, bool *const is_mut);
static __attribute__((unused)) lexer__token__Span codegen__codegen__Codegen__cg_decl_name_span(const codegen__codegen__Codegen *const self, uint32_t const decl);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_auto_free(codegen__codegen__Codegen *const self, uint32_t const bid);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_expr_stmt(codegen__codegen__Codegen *const self, uint32_t const v0);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_assignment(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_free_target(codegen__codegen__Codegen *const self, uint32_t const bt);
static __attribute__((unused)) bool codegen__codegen__Codegen__pat_trivial(const codegen__codegen__Codegen *const self, uint32_t const pid);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_pattern_test(codegen__codegen__Codegen *const self, uint32_t const pid, const char *const scrut);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_bind(codegen__codegen__Codegen *const self, uint32_t const pid, lexer__token__Span const name, bool const is_mut, const char *const scrut, bool const by_ref);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_pattern_binds(codegen__codegen__Codegen *const self, uint32_t const pid, const char *const scrut, bool const by_ref);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_index(codegen__codegen__Codegen *const self, uint32_t const id, bool const want_mut);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_place(codegen__codegen__Codegen *const self, uint32_t const id, bool const want_mut);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_member(codegen__codegen__Codegen *const self, uint32_t const id, bool const want_mut);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_sizeof(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_loop_expr(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_stmt_diverges(const codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_loop_push(codegen__codegen__Codegen *const self, uint32_t const node, bool const is_expr);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_loop_pop(codegen__codegen__Codegen *const self, int32_t const le);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_loop_find(const codegen__codegen__Codegen *const self, uint32_t const node);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_loop_brk_label(codegen__codegen__Codegen *const self, int32_t const le);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_defers_to(codegen__codegen__Codegen *const self, uint32_t const base);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_block_from(codegen__codegen__Codegen *const self, uint32_t const id, uint32_t const dbase);
static __attribute__((unused)) bool codegen__codegen__Codegen__emits_own_parens(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_condition(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_if(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_block_value(codegen__codegen__Codegen *const self, uint32_t const id, const char *const result);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_if_value(codegen__codegen__Codegen *const self, uint32_t const id, const char *const result);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_prefixed(codegen__codegen__Codegen *const self, uint32_t const obj, const char *const prefix);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_recv_addr(codegen__codegen__Codegen *const self, uint32_t const obj, bool const want_mut);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_slice_base(codegen__codegen__Codegen *const self, uint32_t const obj, int32_t const rd);
static __attribute__((unused)) void codegen__codegen__Codegen__render_enum_cname(codegen__codegen__Codegen *const self, ast__ast__DefId const v, uint32_t const en, uint32_t const enum_ty, char *const buf, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_variant_value(codegen__codegen__Codegen *const self, ast__ast__DefId const v, uint32_t const enum_ty);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_variant_construct(codegen__codegen__Codegen *const self, ast__ast__DefId const v, ast__ast__NodeList const args, const uint32_t *const aids, uint32_t const enum_ty);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_method_targs(codegen__codegen__Codegen *const self, uint32_t const callId, ast__ast__DefId const md);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_op_method(codegen__codegen__Codegen *const self, ast__ast__Ty const bt, uint16_t const om, uint32_t const od, ast__ast__DefId const mth);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_cmp_overload(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_ident_ref(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_array_braces(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_expr(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_literal(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) const char *codegen__codegen__sep(const char *const decl);
static __attribute__((unused)) bool codegen__codegen__not_const_prefixed(const char *const base);
static __attribute__((unused)) void codegen__codegen__buf_join3(char *const out, size_t const cap, const char *const first, const char *const second, const char *const third);
static __attribute__((unused)) const char *codegen__codegen__src_at(const uint8_t *const p, uint32_t const off);
static __attribute__((unused)) bool codegen__codegen__span_is(const uint8_t *const src, lexer__token__Span const s, const char *const lit);
static __attribute__((unused)) bool codegen__codegen__spans_eq2(const uint8_t *const sa, lexer__token__Span const a, const uint8_t *const sb, lexer__token__Span const b);
static __attribute__((unused)) const char *codegen__codegen__builtin_name(ast__ast__BuiltinType const b);
static __attribute__((unused)) int32_t codegen__codegen__builtin_of(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) size_t codegen__codegen__render_ident_src(const uint8_t *const src, lexer__token__Span const s, char *const buf, size_t const cap);
static __attribute__((unused)) size_t codegen__codegen__bappend_bytes(char *const out, size_t const cap, size_t const at, const char *const text, size_t const n);
static __attribute__((unused)) size_t codegen__codegen__bappend(char *const out, size_t const cap, size_t const at, const char *const text);
static __attribute__((unused)) bool codegen__codegen__is_c_keyword(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) const char *codegen__codegen__agg_kw(const ast__ast__Node *const n);
static __attribute__((unused)) bool codegen__codegen__want_fn(int32_t const which, bool const is_public);
static __attribute__((unused)) bool codegen__codegen__cg_span_eq(const uint8_t *const sa, lexer__token__Span const a, const uint8_t *const sb, lexer__token__Span const b);
static __attribute__((unused)) ast__ast__NodeList codegen__codegen__Codegen__program_items(const codegen__codegen__Codegen *const self);
static __attribute__((unused)) bool codegen__codegen__Codegen__type_emittable(const codegen__codegen__Codegen *const self, uint32_t const declId);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__fn_array_return(const codegen__codegen__Codegen *const self, uint32_t const fn_id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_ret_struct_named(codegen__codegen__Codegen *const self, uint32_t const fn_id, const char *const nm);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_ret_struct(codegen__codegen__Codegen *const self, uint32_t const fn_id, ast__ast__DefId const target);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_conv_count(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const char *const lit);
static __attribute__((unused)) void codegen__codegen__Codegen__cg_conv_suffix(codegen__codegen__Codegen *const self, ast__ast__DefId const target, const char *const lit, uint32_t const srcTy, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__render_params(codegen__codegen__Codegen *const self, ast__ast__NodeList const params, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__function_name(codegen__codegen__Codegen *const self, uint32_t const fn_id, ast__ast__DefId const target, char *const out, size_t const cap, bool const prefixed);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_subtree_uses(const codegen__codegen__Codegen *const self, uint32_t const id, uint32_t const param);
static __attribute__((unused)) size_t codegen__codegen__addg(char *const g, size_t const cap, size_t const gn, const char *const s);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_function(codegen__codegen__Codegen *const self, uint32_t const fn_id, ast__ast__DefId const target, bool const extern_q, bool const with_body, const char *const name_override, bool const spec_static);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_format_builtin(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const node);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_type_mentions_fnval(const codegen__codegen__Codegen *const self, uint32_t const t);
static __attribute__((unused)) bool codegen__codegen__Codegen__inst_mentions_fnval(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_test_skip(const codegen__codegen__Codegen *const self, uint32_t const fn2, bool const method);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_full(codegen__codegen__Codegen *const self, uint32_t const enum_id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_tag_decl(codegen__codegen__Codegen *const self, uint32_t const enum_id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_struct_body(codegen__codegen__Codegen *const self, uint32_t const dn_id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_type_decl(codegen__codegen__Codegen *const self, uint32_t const declId);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_struct_inst(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_inst(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_enum_shared(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__push_home_dep(const codegen__codegen__Codegen *const self, uint32_t const st0, uint32_t *const deps, int32_t *const nh);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_home_dep(codegen__codegen__Codegen *const self, uint32_t const st);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_inst_dfs(codegen__codegen__Codegen *const self, uint32_t const idx, uint8_t *const state, size_t const nstate, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_type_dfs(codegen__codegen__Codegen *const self, uint32_t const declId, uint8_t *const state);
static __attribute__((unused)) uint8_t *codegen__codegen__Codegen__cg_type_state(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_agg_spec_fallback(codegen__codegen__Codegen *const self, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_aggregate_specializations(codegen__codegen__Codegen *const self, bool const with_body);
static __attribute__((unused)) bool codegen__codegen__Codegen__inst_rehomed_here(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__rehome_subst_type(codegen__codegen__Codegen *const self, uint16_t const owner_mod, const ast__ast__TyInstance *const it, uint32_t const t);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_struct(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_struct_dfs(codegen__codegen__Codegen *const self, uint32_t const idx, uint8_t *const state, size_t const nstate, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_structs(codegen__codegen__Codegen *const self, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_forwards(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_fnval_instance_structs(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_macros(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_inst_methods(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, ast__ast__Ast *const mi_src, uint32_t const mi_inst, int32_t const which, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_method_specializations(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_methods(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_local_method_insts(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_specializations(codegen__codegen__Codegen *const self, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_default_methods(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_closure_fn(codegen__codegen__Codegen *const self, uint32_t const id, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_closures(codegen__codegen__Codegen *const self, bool const with_body);
static __attribute__((unused)) bool codegen__codegen__Codegen__cb_specialized_away(const codegen__codegen__Codegen *const self, uint32_t const fnId);
static __attribute__((unused)) void codegen__codegen__Codegen__collect_callbacks(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_callback_specializations(codegen__codegen__Codegen *const self, bool const with_body);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_dyn_typedefs(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_dynfn_table(codegen__codegen__Codegen *const self, uint32_t const src, ast__ast__Ty const dy);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_dyn_tables(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_layout_asserts(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_toplevel_const(codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_assoc_consts(codegen__codegen__Codegen *const self, bool const public_pass);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_public_consts(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_referenced_fwd(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_referenced_includes(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_header_includes(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_extern_includes(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_includes(codegen__codegen__Codegen *const self);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_test_type(codegen__codegen__Codegen *const self, ast__ast__DefId const d, bool const is_enum);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_test_wrappers(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__seed_emitted_type_instances(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__phase_forward(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__phase_types(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__phase_ret_structs(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__phase_prototypes(codegen__codegen__Codegen *const self, int32_t const which);
static __attribute__((unused)) void codegen__codegen__Codegen__phase_bodies(codegen__codegen__Codegen *const self);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_type_satisfies(codegen__codegen__Codegen *const self, uint32_t const ty, ast__ast__DefId const iface, int32_t const depth);
static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__extend_interface(const codegen__codegen__Codegen *const self, uint32_t const extend_id);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_extend_bounds_hold(codegen__codegen__Codegen *const self, uint32_t const extend_id, const uint32_t *const args, uint8_t const n);
static __attribute__((unused)) bool codegen__codegen__Codegen__seed_type_instances_from_type(codegen__codegen__Codegen *const self, uint32_t const ty0);
static __attribute__((unused)) bool codegen__codegen__Codegen__seed_type_instances_from_type_node(codegen__codegen__Codegen *const self, uint32_t const type_node);
static __attribute__((unused)) bool codegen__codegen__Codegen__seed_type_instances_from_fn_signature(codegen__codegen__Codegen *const self, uint32_t const fn_id);
static __attribute__((unused)) bool codegen__codegen__Codegen__seed_emitted_generic_method_signature_instances(codegen__codegen__Codegen *const self);
static __attribute__((unused)) size_t codegen__codegen__Codegen__module_depth(const codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_rel_prefix(codegen__codegen__Codegen *const self);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_modpath_include(codegen__codegen__Codegen *const self, str const path);
static __attribute__((unused)) bool codegen__codegen__Codegen__type_mentions_builtin(const codegen__codegen__Codegen *const self, uint32_t const t);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_decl_is_interface_member(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const node);
static __attribute__((unused)) void codegen__codegen__Codegen__mark_layout_module(const codegen__codegen__Codegen *const self, uint32_t const ft, bool *const want, size_t const nmod);
static __attribute__((unused)) void codegen__codegen__Codegen__mark_aggregate_layout(const codegen__codegen__Codegen *const self, uint32_t const dn_id, bool *const want, size_t const nmod);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_dyn_method(const codegen__codegen__Codegen *const self, uint16_t const im, uint32_t const m_id);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_dyn_ret(codegen__codegen__Codegen *const self, uint16_t const im, uint32_t const m_id);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_dyn_target(const codegen__codegen__Codegen *const self, const ast__ast__Ty *const sy, uint16_t *const tm, uint32_t *const td);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_dynfn_ret(codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const sig);
static __attribute__((unused)) void codegen__codegen__cg_int_range(ast__ast__BuiltinType const b, int64_t *const mn, int64_t *const mx);
static __attribute__((unused)) bool codegen__codegen__Codegen__cg_struct_name_is(const codegen__codegen__Codegen *const self, const ast__ast__Ty *const y, const char *const lit);
static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_line_of(const codegen__codegen__Codegen *const self, uint32_t const off);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_pct_escaped(codegen__codegen__Codegen *const self, const uint8_t *const text, size_t const len);
static __attribute__((unused)) const char *codegen__codegen__Codegen__cg_file(codegen__codegen__Codegen *const self);
static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_assert_kind(const codegen__codegen__Codegen *const self, uint32_t const id);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_assert_value_line(codegen__codegen__Codegen *const self, const char *const label, const char *const acc, ast__ast__Ty const y, uint32_t const base);
static __attribute__((unused)) bool codegen__codegen__bt_is_numeric(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool codegen__codegen__bt_is_signed_int(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool codegen__codegen__bt_is_unsigned_int(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool codegen__codegen__bt_is_binfmt(ast__ast__BuiltinType const b);
static __attribute__((unused)) const char *codegen__codegen__bt_unsigned_cast(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool codegen__codegen__Codegen__fmt_arg_core(codegen__codegen__Codegen *const self, const char *const tb, uint32_t const arg, const codegen__codegen__FmtSpec *const sp, ast__ast__Ty const y, uint32_t const t);
static __attribute__((unused)) bool codegen__codegen__Codegen__emit_format_arg(codegen__codegen__Codegen *const self, const char *const f, uint32_t const arg, const codegen__codegen__FmtSpec *const sp);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_fmt_cstr(codegen__codegen__Codegen *const self, size_t const a, size_t const b);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_fmt_raw_cstr(codegen__codegen__Codegen *const self, size_t const a, size_t const b);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_fmt_seg(codegen__codegen__Codegen *const self, const char *const f, bool const is_raw, size_t const from, size_t const to);
static __attribute__((unused)) void codegen__codegen__Codegen__macro_stem(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const aggregate_name, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__macro_finish(codegen__codegen__Codegen *const self, size_t const start);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_macro_methods(codegen__codegen__Codegen *const self, uint32_t const declId, bool const define);
static __attribute__((unused)) size_t codegen__codegen__Codegen__conformance_tag(const codegen__codegen__Codegen *const self, uint32_t const extend_id, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_conformance_macro(codegen__codegen__Codegen *const self, uint32_t const declId, uint32_t const implId, bool const define);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_conformance_macros(codegen__codegen__Codegen *const self, uint32_t const declId);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_macro(codegen__codegen__Codegen *const self, uint32_t const declId, bool const define);
static __attribute__((unused)) void codegen__codegen__Codegen__macro_method_name(const codegen__codegen__Codegen *const self, uint32_t const methodId, char *const out, size_t const cap);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_method_macro(codegen__codegen__Codegen *const self, uint32_t const declId, uint32_t const methodId, bool const define);
static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_method_macros(codegen__codegen__Codegen *const self, uint32_t const declId);

const char *codegen__codegen__super_rt_includes(void) {
  return ((const char *)({ __auto_type __sc0 = (str){ (const uint8_t *)"#if __has_include(<assert.h>)\n#include <assert.h>\n#endif\n#if __has_include(<complex.h>)\n#include <complex.h>\n#endif\n#if __has_include(<ctype.h>)\n#include <ctype.h>\n#endif\n#if __has_include(<errno.h>)\n#include <errno.h>\n#endif\n#if __has_include(<fenv.h>)\n#include <fenv.h>\n#endif\n#if __has_include(<float.h>)\n#include <float.h>\n#endif\n#if __has_include(<inttypes.h>)\n#include <inttypes.h>\n#endif\n#if __has_include(<iso646.h>)\n#include <iso646.h>\n#endif\n#if __has_include(<limits.h>)\n#include <limits.h>\n#endif\n#if __has_include(<locale.h>)\n#include <locale.h>\n#endif\n#if __has_include(<math.h>)\n#include <math.h>\n#endif\n#if __has_include(<dlfcn.h>)\n#include <dlfcn.h>\n#endif\n#if __has_include(<signal.h>)\n#include <signal.h>\n#endif\n#if __has_include(<stdalign.h>)\n#include <stdalign.h>\n#endif\n#if __has_include(<stdarg.h>)\n#include <stdarg.h>\n#endif\n#if __has_include(<stdatomic.h>)\n#include <stdatomic.h>\n#endif\n#if __has_include(<stdbit.h>)\n#include <stdbit.h>\n#endif\n#if __has_include(<stdbool.h>)\n#include <stdbool.h>\n#endif\n#if __has_include(<stdckdint.h>)\n#include <stdckdint.h>\n#endif\n#if __has_include(<stddef.h>)\n#include <stddef.h>\n#endif\n#if __has_include(<stdint.h>)\n#include <stdint.h>\n#endif\n#if __has_include(<stdio.h>)\n#include <stdio.h>\n#endif\n#if __has_include(<stdlib.h>)\n#include <stdlib.h>\n#endif\n#if __has_include(<stdnoreturn.h>)\n#include <stdnoreturn.h>\n#endif\n#if __has_include(<string.h>)\n#include <string.h>\n#endif\n#if __has_include(<tgmath.h>)\n#include <tgmath.h>\n#endif\n#if __has_include(<threads.h>)\n#include <threads.h>\n#endif\n#if __has_include(<time.h>)\n#include <time.h>\n#endif\n#if __has_include(<uchar.h>)\n#include <uchar.h>\n#endif\n#if __has_include(<wchar.h>)\n#include <wchar.h>\n#endif\n#if __has_include(<wctype.h>)\n#include <wctype.h>\n#endif\n#if defined(__GNUC__) || defined(__clang__)\n#pragma GCC diagnostic push\n#pragma GCC diagnostic ignored \"-Wunused-function\"\n#define SC_AT(T,S) \\\nstatic inline T __sc_atomic_load_##S(const T*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);} \\\nstatic inline void __sc_atomic_store_##S(T*p,T v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline T __sc_atomic_swap_##S(T*p,T v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline T __sc_atomic_add_##S(T*p,T v){return __atomic_fetch_add(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline T __sc_atomic_sub_##S(T*p,T v){return __atomic_fetch_sub(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline T __sc_atomic_and_##S(T*p,T v){return __atomic_fetch_and(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline T __sc_atomic_or_##S(T*p,T v){return __atomic_fetch_or(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline T __sc_atomic_xor_##S(T*p,T v){return __atomic_fetch_xor(p,v,__ATOMIC_SEQ_CST);} \\\nstatic inline bool __sc_atomic_cas_##S(T*p,T e,T d){return __atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}\nSC_AT(int8_t,i8) SC_AT(int16_t,i16) SC_AT(int32_t,i32) SC_AT(int64_t,i64) SC_AT(intptr_t,isize)\nSC_AT(uint8_t,u8) SC_AT(uint16_t,u16) SC_AT(uint32_t,u32) SC_AT(uint64_t,u64) SC_AT(size_t,usize)\n#undef SC_AT\nstatic inline bool __sc_atomic_load_bool(const bool*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);}\nstatic inline void __sc_atomic_store_bool(bool*p,bool v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);}\nstatic inline bool __sc_atomic_swap_bool(bool*p,bool v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);}\nstatic inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d){return __atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}\nstatic inline void __sc_atomic_fence(void){__atomic_thread_fence(__ATOMIC_SEQ_CST);}\n#pragma GCC diagnostic pop\n#endif\nstatic inline __attribute__((unused)) FILE* __sc_stdin(void){return stdin;}\nstatic inline __attribute__((unused)) FILE* __sc_stdout(void){return stdout;}\nstatic inline __attribute__((unused)) FILE* __sc_stderr(void){return stderr;}\nstatic inline __attribute__((unused)) int* __sc_errno_location(void){return &errno;}\nstatic _Noreturn __attribute__((unused)) void __sc_panic(const char *__m) {\n  fprintf(stderr, \"super-c: %s\\n\", __m); abort();\n}\nstatic _Noreturn __attribute__((unused)) void __sc_panic_str(const uint8_t *__p, size_t __n) {\n  fprintf(stderr, \"panic: %.*s\\n\", (int)__n, (const char *)__p); abort();\n}\nstatic __attribute__((unused)) inline size_t __sc_bounds(size_t __i, size_t __n) {\n  if (__i >= __n) __sc_panic(\"index out of bounds\");\n  return __i;\n}\n", 4366 }; str__ptr(&__sc0); }));
}

static __attribute__((unused)) const char *codegen__codegen__builtin_c(ast__ast__BuiltinType const b) {
  const int32_t i = ((int32_t)b);
  if (i == 0) {
    return ((const char *)({ __auto_type __sc1 = (str){ (const uint8_t *)"bool", sizeof("bool") - 1 }; str__ptr(&__sc1); }));
  }
  if (i == 1) {
    return ((const char *)({ __auto_type __sc2 = (str){ (const uint8_t *)"char", sizeof("char") - 1 }; str__ptr(&__sc2); }));
  }
  if (i == 2) {
    return ((const char *)({ __auto_type __sc3 = (str){ (const uint8_t *)"int8_t", sizeof("int8_t") - 1 }; str__ptr(&__sc3); }));
  }
  if (i == 3) {
    return ((const char *)({ __auto_type __sc4 = (str){ (const uint8_t *)"int16_t", sizeof("int16_t") - 1 }; str__ptr(&__sc4); }));
  }
  if (i == 4) {
    return ((const char *)({ __auto_type __sc5 = (str){ (const uint8_t *)"int32_t", sizeof("int32_t") - 1 }; str__ptr(&__sc5); }));
  }
  if (i == 5) {
    return ((const char *)({ __auto_type __sc6 = (str){ (const uint8_t *)"int64_t", sizeof("int64_t") - 1 }; str__ptr(&__sc6); }));
  }
  if (i == 6) {
    return ((const char *)({ __auto_type __sc7 = (str){ (const uint8_t *)"intptr_t", sizeof("intptr_t") - 1 }; str__ptr(&__sc7); }));
  }
  if (i == 7) {
    return ((const char *)({ __auto_type __sc8 = (str){ (const uint8_t *)"uint8_t", sizeof("uint8_t") - 1 }; str__ptr(&__sc8); }));
  }
  if (i == 8) {
    return ((const char *)({ __auto_type __sc9 = (str){ (const uint8_t *)"uint16_t", sizeof("uint16_t") - 1 }; str__ptr(&__sc9); }));
  }
  if (i == 9) {
    return ((const char *)({ __auto_type __sc10 = (str){ (const uint8_t *)"uint32_t", sizeof("uint32_t") - 1 }; str__ptr(&__sc10); }));
  }
  if (i == 10) {
    return ((const char *)({ __auto_type __sc11 = (str){ (const uint8_t *)"uint64_t", sizeof("uint64_t") - 1 }; str__ptr(&__sc11); }));
  }
  if (i == 11) {
    return ((const char *)({ __auto_type __sc12 = (str){ (const uint8_t *)"size_t", sizeof("size_t") - 1 }; str__ptr(&__sc12); }));
  }
  if (i == 12) {
    return ((const char *)({ __auto_type __sc13 = (str){ (const uint8_t *)"float", sizeof("float") - 1 }; str__ptr(&__sc13); }));
  }
  if (i == 13) {
    return ((const char *)({ __auto_type __sc14 = (str){ (const uint8_t *)"double", sizeof("double") - 1 }; str__ptr(&__sc14); }));
  }
  if (i == 14) {
    return ((const char *)({ __auto_type __sc15 = (str){ (const uint8_t *)"float _Complex", sizeof("float _Complex") - 1 }; str__ptr(&__sc15); }));
  }
  if (i == 15) {
    return ((const char *)({ __auto_type __sc16 = (str){ (const uint8_t *)"double _Complex", sizeof("double _Complex") - 1 }; str__ptr(&__sc16); }));
  }
  if (i == 16) {
    return ((const char *)({ __auto_type __sc17 = (str){ (const uint8_t *)"va_list", sizeof("va_list") - 1 }; str__ptr(&__sc17); }));
  }
  return ((const char *)({ __auto_type __sc18 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc18); }));
}

void codegen__codegen__Codegen__free(codegen__codegen__Codegen *const self) {
  String__Global__free(&self->buf);
  Map__u32__u32__Global__free(&self->enum_of_variant);
  Map__u64__ast__ast__DefId__Global__free(&self->free_ext_cache);
  utils__errors__Errors__free(&self->errors);
  if (self->type_state != NULL) {
    free(((void *)self->type_state));
  }
  if (self->inst_emit_state != NULL) {
    free(((void *)self->inst_emit_state));
  }
}

codegen__codegen__Codegen codegen__codegen__Codegen__new(ast__ast__Ast *const ast, str const source, module__loader__Package *const package) {
  size_t user_mods = 0ULL;
  if (package != NULL) {
    for (size_t i = 0ULL; i < Vector__module__loader__Module__Global__len(&(*package).modules); i++) {
      if (!(*({ __auto_type __sc19 = &(*package).modules; Vector__module__loader__Module__Global__index(__sc19, i); })).prelude) {
        (user_mods = (user_mods + 1ULL));
      }
    }
  }
  const bool mangle = (user_mods > 1ULL);
  const size_t cap = ((str__len(&source) * 4ULL) + 4096ULL);
  return (codegen__codegen__Codegen){ .ast = ast, .source = str__ptr(&source), .len = str__len(&source), .buf = String__Global__with_capacity(cap), .enum_of_variant = Map__u32__u32__Global__new(), .free_ext_cache = Map__u64__ast__ast__DefId__Global__new(), .package = package, .mangle = mangle, .multifile = mangle, .errors = utils__errors__Errors__new() };
}

ast__ast__Ast *codegen__codegen__Codegen__take_ast(codegen__codegen__Codegen *const self) {
  return self->ast;
}

bool codegen__codegen__Codegen__has_errors(const codegen__codegen__Codegen *const self) {
  return utils__errors__Errors__has_errors(&self->errors);
}

void codegen__codegen__Codegen__log_errors(const codegen__codegen__Codegen *const self) {
  utils__errors__Errors__log(&self->errors);
}

void codegen__codegen__Codegen__set_multifile(codegen__codegen__Codegen *const self, bool const on) {
  (self->multifile = on);
}

void codegen__codegen__Codegen__set_test_info(codegen__codegen__Codegen *const self, const codegen__codegen__CgTestInfo *const ti) {
  (self->test = (*ti));
}

static __attribute__((unused)) ast__ast__Ast *codegen__codegen__Codegen__cur_ast(const codegen__codegen__Codegen *const self) {
  return self->ast;
}

static __attribute__((unused)) ast__ast__Ast *codegen__codegen__Codegen__mod_ast(const codegen__codegen__Codegen *const self, uint16_t const m) {
  if ((self->package != NULL) && (m != (*self->ast).module)) {
    return ((ast__ast__Ast *)(&(*({ __auto_type __sc20 = &(*self->package).modules; Vector__module__loader__Module__Global__index_mut(__sc20, ((size_t)m)); })).ast));
  }
  return self->ast;
}

static __attribute__((unused)) const uint8_t *codegen__codegen__Codegen__mod_src(const codegen__codegen__Codegen *const self, uint16_t const m) {
  if ((self->package != NULL) && (m != (*self->ast).module)) {
    return ({ __auto_type __sc21 = String__Global__as_str(&(*({ __auto_type __sc22 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc22, ((size_t)m)); })).source); str__ptr(&__sc21); });
  }
  return self->source;
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__pkg_count(const codegen__codegen__Codegen *const self) {
  if (self->package == NULL) {
    return 0ULL;
  }
  return Vector__module__loader__Module__Global__len(&(*self->package).modules);
}

static __attribute__((unused)) consteval__consteval__ConstEval *codegen__codegen__Codegen__ceval(const codegen__codegen__Codegen *const self) {
  if (self->package == NULL) {
    return NULL;
  }
  return ((consteval__consteval__ConstEval *)(*self->package).ceval);
}

static __attribute__((unused)) uint16_t codegen__codegen__Codegen__cur_module(const codegen__codegen__Codegen *const self) {
  return (*self->ast).module;
}

static __attribute__((unused)) const ast__ast__Ty *codegen__codegen__Codegen__type_at(const codegen__codegen__Codegen *const self, uint32_t const x) {
  return ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), x);
}

static __attribute__((unused)) void codegen__codegen__Codegen__closure_sym_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const id, char *const out, size_t const cap) {
  size_t k = codegen__codegen__Codegen__render_modpfx(self, m, out, cap);
  (k = codegen__codegen__bappend(out, cap, k, ((const char *)({ __auto_type __sc23 = (str){ (const uint8_t *)"closure_", sizeof("closure_") - 1 }; str__ptr(&__sc23); }))));
  codegen__codegen__Buf32 idb = (codegen__codegen__Buf32){0};
  snprintf(((char *)(&idb.b[0])), 16ULL, ((const char *)({ __auto_type __sc24 = (str){ (const uint8_t *)"%u", sizeof("%u") - 1 }; str__ptr(&__sc24); })), id);
  codegen__codegen__bappend(out, cap, k, ((const char *)(&idb.b[0])));
}

static __attribute__((unused)) void codegen__codegen__Codegen__closure_name(const codegen__codegen__Codegen *const self, uint32_t const id, char *const out, size_t const cap) {
  codegen__codegen__Codegen__closure_sym_in(self, codegen__codegen__Codegen__cur_module(self), id, out, cap);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_bytes(codegen__codegen__Codegen *const self, const char *const p, size_t const n) {
  void *const tail = ((void *)String__Global__spare_mut(&self->buf, n));
  memcpy(tail, ((const void *)p), n);
  String__Global__advance_len(&self->buf, n);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_cstr(codegen__codegen__Codegen *const self, const char *const text) {
  codegen__codegen__Codegen__emit_bytes(self, text, strlen(text));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_octal_escape(codegen__codegen__Codegen *const self, uint32_t const b) {
  String__Global__push_byte(&self->buf, 92U);
  String__Global__push_byte(&self->buf, ((uint8_t)(48U + (({ uint32_t __sc25 = b; int64_t __sc26 = (int64_t)(6U); if ((uint64_t)__sc26 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc25 >> __sc26); }) & 7U))));
  String__Global__push_byte(&self->buf, ((uint8_t)(48U + (({ uint32_t __sc27 = b; int64_t __sc28 = (int64_t)(3U); if ((uint64_t)__sc28 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc27 >> __sc28); }) & 7U))));
  String__Global__push_byte(&self->buf, ((uint8_t)(48U + (b & 7U))));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit(codegen__codegen__Codegen *const self, const char *const fmt) {
  codegen__codegen__Codegen__emit_cstr(self, fmt);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_indent(codegen__codegen__Codegen *const self) {
  uint32_t n = (self->depth * 2U);
  while (n != 0U) {
    uint32_t k = n;
    if (k > 32U) {
      (k = 32U);
    }
    codegen__codegen__Codegen__emit_bytes(self, ((const char *)({ __auto_type __sc29 = (str){ (const uint8_t *)"                                ", sizeof("                                ") - 1 }; str__ptr(&__sc29); })), ((size_t)k));
    (n = (n - k));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_paste(codegen__codegen__Codegen *const self) {
  if (self->macro_mode) {
    const char p = codegen__codegen__CG_PASTE;
    codegen__codegen__Codegen__emit_bytes(self, ((const char *)(&p)), 1ULL);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__fresh(codegen__codegen__Codegen *const self, char *const buf, size_t const cap) {
  snprintf(buf, cap, ((const char *)({ __auto_type __sc30 = (str){ (const uint8_t *)"__sc%u", sizeof("__sc%u") - 1 }; str__ptr(&__sc30); })), self->tmp);
  (self->tmp = (self->tmp + 1U));
}

static __attribute__((unused)) lexer__token__Span codegen__codegen__Codegen__name_span(const codegen__codegen__Codegen *const self, uint32_t const name_node) {
  return ast__ast__Ast__at_const(&((*self->ast)), name_node)->as_data.name.text;
}

static __attribute__((unused)) lexer__token__Span codegen__codegen__Codegen__name_span_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const name_node) {
  return ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), name_node)->as_data.name.text;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_span(codegen__codegen__Codegen *const self, lexer__token__Span const s) {
  codegen__codegen__Codegen__emit_bytes(self, ((const char *)(self->source + ((size_t)s.start))), ((size_t)(s.end - s.start)));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_ident(codegen__codegen__Codegen *const self, lexer__token__Span const s) {
  codegen__codegen__Codegen__emit_span(self, s);
  if (codegen__codegen__is_c_keyword(self->source, s)) {
    codegen__codegen__Codegen__emit_bytes(self, ((const char *)({ __auto_type __sc31 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc31); })), 1ULL);
  }
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__render_ident(const codegen__codegen__Codegen *const self, lexer__token__Span const s, char *const buf, size_t const cap) {
  return codegen__codegen__render_ident_src(self->source, s, buf, cap);
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__render_modpfx(const codegen__codegen__Codegen *const self, uint16_t const m, char *const buf, size_t const cap) {
  if (cap != 0ULL) {
    (buf[0] = 0);
  }
  if (!self->mangle) {
    return 0ULL;
  }
  if ((*({ __auto_type __sc32 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc32, ((size_t)m)); })).prelude) {
    return 0ULL;
  }
  const str path = String__Global__as_str(&(*({ __auto_type __sc33 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc33, ((size_t)m)); })).path);
  const size_t n = str__len(&path);
  size_t at = 0ULL;
  size_t i = 0ULL;
  while (i < n) {
    if (((str__byte_at(&path, i) == 58U) && ((i + 1ULL) < n)) && (str__byte_at(&path, (i + 1ULL)) == 58U)) {
      (i = (i + 1ULL));
      if ((at + 2ULL) < cap) {
        (buf[at] = 95);
        (buf[(at + 1ULL)] = 95);
      }
      (at = (at + 2ULL));
    } else {
      if ((at + 1ULL) < cap) {
        (buf[at] = ((char)str__byte_at(&path, i)));
      }
      (at = (at + 1ULL));
    }
    (i = (i + 1ULL));
  }
  if ((at + 2ULL) < cap) {
    (buf[at] = 95);
    (buf[(at + 1ULL)] = 95);
  }
  (at = (at + 2ULL));
  if (at < cap) {
    (buf[at] = 0);
  }
  return at;
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__render_qualified(const codegen__codegen__Codegen *const self, uint16_t const owner, uint32_t const name_node, char *const buf, size_t const cap) {
  const size_t at = codegen__codegen__Codegen__render_modpfx(self, owner, buf, cap);
  size_t off = at;
  if (off >= cap) {
    if (cap != 0ULL) {
      (off = (cap - 1ULL));
    } else {
      (off = 0ULL);
    }
  }
  const lexer__token__Span s = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner))), name_node)->as_data.name.text;
  size_t rem = 0ULL;
  if (cap > off) {
    (rem = (cap - off));
  }
  return (at + codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, owner), s, ((char *)(buf + off)), rem));
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__render_iface_stem(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const iface, char *const out, size_t const cap) {
  return codegen__codegen__Codegen__render_qualified(self, m, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), iface)->as_data.interface_def.name, out, cap);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_ident_mod(codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const name_node) {
  codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
  codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, m), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), name_node)->as_data.name.text, ((char *)(&nm.b[0])), 160ULL);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_local_type_name(codegen__codegen__Codegen *const self, uint32_t const aggregate_name) {
  codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), aggregate_name, ((char *)(&nm.b[0])), 160ULL);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
}

static __attribute__((unused)) void codegen__codegen__Codegen__build_enum_index(codegen__codegen__Codegen *const self) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__cur_ast(self);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_ENUM) {
      const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.aggregate.members;
      for (uint32_t j = 0U; j < ms.len; j++) {
        Map__u32__u32__Global__insert(&self->enum_of_variant, ast__ast__Ast__list(&((*a)), ms)[((size_t)j)], iid);
      }
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__mangle_type(const codegen__codegen__Codegen *const self, uint32_t const t, char *const out, size_t const cap) {
  const ast__ast__Ty ty = (*codegen__codegen__Codegen__type_at(self, t));
  if (ty.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    codegen__codegen__bappend(out, cap, 0ULL, codegen__codegen__builtin_name(ty.as_data.builtin));
  } else if ((ty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ty.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    codegen__codegen__Codegen__render_qualified(self, ty.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, ty.module))), ty.as_data.decl)->as_data.aggregate.name, out, cap);
  } else if ((ty.kind == ast__ast__TypeKind_TYPE_POINTER) || (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, ty.as_data.elem, ((char *)(&e.b[0])), 176ULL);
    snprintf(out, cap, ((const char *)({ __auto_type __sc34 = (str){ (const uint8_t *)"ptr_%s", sizeof("ptr_%s") - 1 }; str__ptr(&__sc34); })), ((const char *)(&e.b[0])));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_SLICE) {
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, ty.as_data.elem, ((char *)(&e.b[0])), 176ULL);
    snprintf(out, cap, ((const char *)({ __auto_type __sc35 = (str){ (const uint8_t *)"slice_%s", sizeof("slice_%s") - 1 }; str__ptr(&__sc35); })), ((const char *)(&e.b[0])));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, ty.as_data.arr.elem, ((char *)(&e.b[0])), 176ULL);
    if (ty.as_data.arr.len != 0U) {
      snprintf(out, cap, ((const char *)({ __auto_type __sc36 = (str){ (const uint8_t *)"arr%u_%s", sizeof("arr%u_%s") - 1 }; str__ptr(&__sc36); })), ty.as_data.arr.len, ((const char *)(&e.b[0])));
    } else {
      snprintf(out, cap, ((const char *)({ __auto_type __sc37 = (str){ (const uint8_t *)"arr_%s", sizeof("arr_%s") - 1 }; str__ptr(&__sc37); })), ((const char *)(&e.b[0])));
    }
  } else if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ty.as_data.inst), out, cap);
  } else if (ty.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    const ast__ast__Node *const fd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, ty.module))), ty.as_data.decl);
    if (fd->kind == ast__ast__NodeKind_NODE_FUNCTION) {
      codegen__codegen__Codegen__render_qualified(self, ty.module, fd->as_data.function.name, out, cap);
    } else if (fd->kind == ast__ast__NodeKind_NODE_CLOSURE) {
      codegen__codegen__Codegen__closure_sym_in(self, ty.module, ty.as_data.decl, out, cap);
    } else {
      snprintf(out, cap, ((const char *)({ __auto_type __sc38 = (str){ (const uint8_t *)"fnt%u_%u", sizeof("fnt%u_%u") - 1 }; str__ptr(&__sc38); })), ((uint32_t)ty.module), ty.as_data.decl);
    }
  } else if (ty.kind == ast__ast__TypeKind_TYPE_DYN) {
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__dyn_stem(self, ty.module, ty.as_data.decl, ((char *)(&e.b[0])), 176ULL);
    const char *pfx = ((const char *)({ __auto_type __sc39 = (str){ (const uint8_t *)"dynb", sizeof("dynb") - 1 }; str__ptr(&__sc39); }));
    if (ty.qualifier == 2U) {
      (pfx = ((const char *)({ __auto_type __sc40 = (str){ (const uint8_t *)"dynm", sizeof("dynm") - 1 }; str__ptr(&__sc40); })));
    } else if (ty.qualifier == 1U) {
      (pfx = ((const char *)({ __auto_type __sc41 = (str){ (const uint8_t *)"dyn", sizeof("dyn") - 1 }; str__ptr(&__sc41); })));
    }
    snprintf(out, cap, ((const char *)({ __auto_type __sc42 = (str){ (const uint8_t *)"%s_%s", sizeof("%s_%s") - 1 }; str__ptr(&__sc42); })), pfx, ((const char *)(&e.b[0])));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_CONST) {
    snprintf(out, cap, ((const char *)({ __auto_type __sc43 = (str){ (const uint8_t *)"%lld", sizeof("%lld") - 1 }; str__ptr(&__sc43); })), ty.as_data.value);
  } else {
    codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc44 = (str){ (const uint8_t *)"v", sizeof("v") - 1 }; str__ptr(&__sc44); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__dyn_stem(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl, char *const out, size_t const cap) {
  ast__ast__Ast *const da = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__Node *const fn2 = ast__ast__Ast__at_const(&((*da)), decl);
  if (fn2->kind != ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    codegen__codegen__Codegen__render_iface_stem(self, m, decl, out, cap);
    return;
  }
  size_t at = codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc45 = (str){ (const uint8_t *)"dynfn", sizeof("dynfn") - 1 }; str__ptr(&__sc45); })));
  const ast__ast__FunctionTypeData ftp = fn2->as_data.function_type;
  for (uint32_t i = 0U; i < ftp.params.len; i++) {
    const uint32_t pid = ast__ast__Ast__list(&((*da)), ftp.params)[((size_t)i)];
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*da)), ast__ast__Ast__type_of(&((*da)), pid)), ((char *)(&e.b[0])), 176ULL);
    (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc46 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc46); }))));
    (at = codegen__codegen__bappend(out, cap, at, ((const char *)(&e.b[0]))));
  }
  if (ftp.returns.len == 1U) {
    const uint32_t r0 = ast__ast__Ast__list(&((*da)), ftp.returns)[0];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*da)), r0);
    const uint32_t tn = codegen__codegen__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0);
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*da)), ast__ast__Ast__type_of(&((*da)), tn)), ((char *)(&e.b[0])), 176ULL);
    (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc47 = (str){ (const uint8_t *)"__r_", sizeof("__r_") - 1 }; str__ptr(&__sc47); }))));
    codegen__codegen__bappend(out, cap, at, ((const char *)(&e.b[0])));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__dyn_pair_stem(const codegen__codegen__Codegen *const self, uint32_t const src, uint16_t const im, uint32_t const iface, char *const out, size_t const cap) {
  codegen__codegen__Buf256 sm = (codegen__codegen__Buf256){0};
  codegen__codegen__Buf256 stem = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__mangle_type(self, src, ((char *)(&sm.b[0])), 176ULL);
  codegen__codegen__Codegen__dyn_stem(self, im, iface, ((char *)(&stem.b[0])), 176ULL);
  snprintf(out, cap, ((const char *)({ __auto_type __sc48 = (str){ (const uint8_t *)"%s__%s", sizeof("%s__%s") - 1 }; str__ptr(&__sc48); })), ((const char *)(&sm.b[0])), ((const char *)(&stem.b[0])));
}

static __attribute__((unused)) void codegen__codegen__Codegen__spec_name(const codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, const uint32_t *const args, int32_t const n, char *const out, size_t const cap) {
  size_t at = codegen__codegen__Codegen__render_qualified(self, fn2.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, fn2.module))), fn2.node)->as_data.function.name, out, cap);
  for (int32_t i = 0; i < n; i++) {
    (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc49 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc49); }))));
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, args[((size_t)i)], ((char *)(&e.b[0])), 176ULL);
    (at = codegen__codegen__bappend(out, cap, at, ((const char *)(&e.b[0]))));
  }
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__render_macro_param(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl, char *const buf, size_t const cap) {
  const ast__ast__Node *const gp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), decl);
  return codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, m), codegen__codegen__Codegen__name_span_in(self, m, gp->as_data.generic_param.name), buf, cap);
}

static __attribute__((unused)) void codegen__codegen__Codegen__macro_arg_token(const codegen__codegen__Codegen *const self, uint32_t const arg, char *const out, size_t const cap) {
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, arg));
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const size_t at = codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc50 = (str){ (const uint8_t *)"_SCM_", sizeof("_SCM_") - 1 }; str__ptr(&__sc50); })));
    codegen__codegen__Codegen__render_macro_param(self, y.module, y.as_data.decl, ((char *)(out + at)), (cap - at));
    return;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    const char *pfx = ((const char *)({ __auto_type __sc51 = (str){ (const uint8_t *)"ptr_", sizeof("ptr_") - 1 }; str__ptr(&__sc51); }));
    if (y.kind == ast__ast__TypeKind_TYPE_SLICE) {
      (pfx = ((const char *)({ __auto_type __sc52 = (str){ (const uint8_t *)"slice_", sizeof("slice_") - 1 }; str__ptr(&__sc52); })));
    } else if (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
      (pfx = ((const char *)({ __auto_type __sc53 = (str){ (const uint8_t *)"arr_", sizeof("arr_") - 1 }; str__ptr(&__sc53); })));
    }
    size_t at = codegen__codegen__bappend(out, cap, 0ULL, pfx);
    if (at < cap) {
      (out[at] = codegen__codegen__CG_PASTE);
      (at = (at + 1ULL));
    }
    if (at < cap) {
      (out[at] = 0);
    }
    size_t rem = 0ULL;
    if (cap > at) {
      (rem = (cap - at));
    }
    codegen__codegen__Codegen__macro_arg_token(self, y.as_data.elem, ((char *)(out + at)), rem);
    return;
  }
  codegen__codegen__Codegen__mangle_type(self, arg, out, cap);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__is_self_instance(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it) {
  if (((!self->macro_mode) || (it->decl != self->macro_self)) || (it->module != self->macro_self_mod)) {
    return false;
  }
  ast__ast__Ast *const sa = codegen__codegen__Codegen__mod_ast(self, self->macro_self_mod);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*sa)), self->macro_self)->as_data.aggregate.generics;
  if (gens.len != ((uint32_t)it->n)) {
    return false;
  }
  for (uint8_t i = 0U; i < it->n; i++) {
    const uint32_t gid = ast__ast__Ast__list(&((*sa)), gens)[((size_t)i)];
    const ast__ast__Ty *const y = codegen__codegen__Codegen__type_at(self, it->args[((size_t)i)]);
    if (((y->kind != ast__ast__TypeKind_TYPE_GENERIC) || (y->as_data.decl != gid)) || (y->module != self->macro_self_mod)) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) void codegen__codegen__Codegen__inst_name(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, char *const out, size_t const cap) {
  if (codegen__codegen__Codegen__is_self_instance(self, (&(*it)))) {
    codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc54 = (str){ (const uint8_t *)"NAME", sizeof("NAME") - 1 }; str__ptr(&__sc54); })));
    return;
  }
  size_t at = codegen__codegen__Codegen__render_qualified(self, it->module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it->module))), it->decl)->as_data.aggregate.name, out, cap);
  codegen__codegen__Buf256 sentbuf = (codegen__codegen__Buf256){0};
  (sentbuf.b[0] = codegen__codegen__CG_PASTE);
  const char *const sent = ((const char *)(&sentbuf.b[0]));
  for (uint8_t i = 0U; i < it->n; i++) {
    if (self->macro_mode) {
      if (i != 0U) {
        (at = codegen__codegen__bappend(out, cap, at, sent));
      } else {
        (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc55 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc55); }))));
      }
      if (i != 0U) {
        (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc56 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc56); }))));
      } else {
        (at = codegen__codegen__bappend(out, cap, at, sent));
      }
      if (i != 0U) {
        (at = codegen__codegen__bappend(out, cap, at, sent));
      }
      codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__macro_arg_token(self, it->args[((size_t)i)], ((char *)(&e.b[0])), 176ULL);
      (at = codegen__codegen__bappend(out, cap, at, ((const char *)(&e.b[0]))));
    } else {
      (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc57 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc57); }))));
      codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__mangle_type(self, codegen__codegen__Codegen__subst_resolve(self, it->args[((size_t)i)]), ((char *)(&e.b[0])), 176ULL);
      (at = codegen__codegen__bappend(out, cap, at, ((const char *)(&e.b[0]))));
    }
  }
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__subst_lookup(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl) {
  for (int32_t i = 0; i < self->nsubst; i++) {
    if ((self->subst[((size_t)i)].param.module == m) && (self->subst[((size_t)i)].param.node == decl)) {
      return self->subst[((size_t)i)].concrete;
    }
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__subst_resolve(const codegen__codegen__Codegen *const self, uint32_t const t) {
  if (self->nsubst == 0) {
    return t;
  }
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, t));
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const uint32_t s = codegen__codegen__Codegen__subst_lookup(self, y.module, y.as_data.decl);
    if (s != ast__ast__TYPE_NONE) {
      return s;
    }
    return t;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    const uint32_t e = codegen__codegen__Codegen__subst_resolve(self, y.as_data.elem);
    if (e == y.as_data.elem) {
      return t;
    }
    ast__ast__Ty nt = y;
    (nt.as_data.elem = e);
    return ast__ast__Ast__intern_type(&((*codegen__codegen__Codegen__cur_ast(self))), nt);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance src = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    codegen__codegen__TyArgs4 na = (codegen__codegen__TyArgs4){0};
    bool changed = false;
    for (uint8_t i = 0U; i < src.n; i++) {
      (na.t[((size_t)i)] = codegen__codegen__Codegen__subst_resolve(self, src.args[((size_t)i)]));
      if (na.t[((size_t)i)] != src.args[((size_t)i)]) {
        (changed = true);
      }
    }
    if (changed) {
      return ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), src.module, src.decl, ((const uint32_t *)(&na.t[0])), src.n);
    }
    return t;
  }
  return t;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_const_param_value(const codegen__codegen__Codegen *const self, uint32_t const id, int64_t *const out) {
  if (self->nsubst == 0) {
    return false;
  }
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return false;
  }
  const uint32_t d = ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  if ((d == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), d)->kind != ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
    return false;
  }
  const uint32_t s = codegen__codegen__Codegen__subst_lookup(self, (*codegen__codegen__Codegen__cur_ast(self)).module, d);
  if ((s == ast__ast__TYPE_NONE) || (codegen__codegen__Codegen__type_at(self, s)->kind != ast__ast__TypeKind_TYPE_CONST)) {
    return false;
  }
  ((*out) = codegen__codegen__Codegen__type_at(self, s)->as_data.value);
  return true;
}

static __attribute__((unused)) int64_t codegen__codegen__Codegen__cg_const_len_subst(const codegen__codegen__Codegen *const self, uint32_t const length) {
  int64_t v = 0;
  if (codegen__codegen__Codegen__cg_const_param_value(self, length, ((int64_t *)(&v)))) {
    return v;
  }
  return -1;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__type_is_concrete(const codegen__codegen__Codegen *const self, uint32_t const t) {
  const ast__ast__Ty *const y = codegen__codegen__Codegen__type_at(self, t);
  if (y->kind == ast__ast__TypeKind_TYPE_GENERIC) {
    return false;
  }
  if ((((y->kind == ast__ast__TypeKind_TYPE_POINTER) || (y->kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y->kind == ast__ast__TypeKind_TYPE_SLICE)) || (y->kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    return codegen__codegen__Codegen__type_is_concrete(self, y->as_data.elem);
  }
  if (y->kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y->as_data.inst));
    for (uint8_t i = 0U; i < it.n; i++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)i)])) {
        return false;
      }
    }
    return true;
  }
  return true;
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__generic_call_target(const codegen__codegen__Codegen *const self, uint32_t const callId, uint32_t *const args, int32_t *const n) {
  ((*n) = 0);
  ast__ast__Ast *const a = codegen__codegen__Codegen__cur_ast(self);
  const ast__ast__Node *const call = ast__ast__Ast__at_const(&((*a)), callId);
  if (call->kind != ast__ast__NodeKind_NODE_CALL) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  const ast__ast__Node *const callee = ast__ast__Ast__at_const(&((*a)), call->as_data.call.callee);
  ast__ast__DefId fn2 = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  if (callee->kind == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
    (fn2 = ast__ast__Ast__resolution_def(&((*a)), callee->as_data.specialization.expression));
  } else {
    (fn2 = ast__ast__Ast__resolution_def(&((*a)), call->as_data.call.callee));
  }
  if (fn2.node == ast__ast__NODE_NONE) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  const ast__ast__Node *const fnnode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, fn2.module))), fn2.node);
  if ((fnnode->kind != ast__ast__NodeKind_NODE_FUNCTION) || (fnnode->as_data.function.generics.len == 0U)) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  const ast__ast__MonoUse *const mu = ast__ast__Ast__type_args(&((*a)), callId);
  if (mu == NULL) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  uint8_t i = 0U;
  while ((i < (*mu).n) && ((*n) < 4)) {
    const int32_t k = (*n);
    (args[((size_t)k)] = (*mu).args[((size_t)i)]);
    ((*n) = ({ int32_t __sc_r; if (__builtin_add_overflow(k, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    (i = ((uint8_t)((uint32_t)i + (uint32_t)1U)));
  }
  return fn2;
}

static __attribute__((unused)) void codegen__codegen__Codegen__record_inst(codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, const uint32_t *const args, int32_t const n, uint32_t const site) {
  for (int32_t i = 0; i < self->ninsts; i++) {
    if (((self->insts[((size_t)i)].func.module == fn2.module) && (self->insts[((size_t)i)].func.node == fn2.node)) && (((int32_t)self->insts[((size_t)i)].n) == n)) {
      bool same = true;
      for (int32_t j = 0; j < n; j++) {
        if (self->insts[((size_t)i)].args[((size_t)j)] != args[((size_t)j)]) {
          (same = false);
        }
      }
      if (same) {
        return;
      }
    }
  }
  if (self->ninsts >= 1024) {
    if (!self->insts_overflow) {
      (self->insts_overflow = true);
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), site)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc58 = String__Global__new();
String__Global__push_str(&__sc58, (str){ .ptr = (const uint8_t*)"codegen: too many distinct generic instantiations in one module (max ", .len = sizeof("codegen: too many distinct generic instantiations in one module (max ") - 1 });
String__Global__push_i64(&__sc58, (int64_t)(1024));
String__Global__push_str(&__sc58, (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
__sc58; }));
    }
    return;
  }
  const int32_t k = self->ninsts;
  (self->insts[((size_t)k)].func = fn2);
  (self->insts[((size_t)k)].n = ((uint8_t)n));
  for (int32_t j = 0; j < n; j++) {
    (self->insts[((size_t)k)].args[((size_t)j)] = args[((size_t)j)]);
  }
  (self->ninsts = ({ int32_t __sc_r; if (__builtin_add_overflow(k, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
}

static __attribute__((unused)) void codegen__codegen__Codegen__collect_insts(codegen__codegen__Codegen *const self) {
  (self->ninsts = 0);
  uint32_t i = 1U;
  while (((size_t)i) < Vector__ast__ast__Node__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).nodes)) {
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), i)->kind == ast__ast__NodeKind_NODE_CALL) {
      codegen__codegen__TyArgs4 args = (codegen__codegen__TyArgs4){0};
      int32_t n = 0;
      const ast__ast__DefId fn2 = codegen__codegen__Codegen__generic_call_target(self, i, ((uint32_t *)(&args.t[0])), ((int32_t *)(&n)));
      if (fn2.node != ast__ast__NODE_NONE) {
        codegen__codegen__Codegen__record_inst(self, fn2, ((const uint32_t *)(&args.t[0])), n, i);
      }
    }
    (i = (i + 1U));
  }
  codegen__codegen__Codegen__expand_nested_insts(self);
}

static __attribute__((unused)) void codegen__codegen__Codegen__expand_nested_insts(codegen__codegen__Codegen *const self) {
  for (int32_t i = 0; i < self->ninsts; i++) {
    const ast__ast__DefId fn2 = self->insts[((size_t)i)].func;
    const uint8_t fn_n = self->insts[((size_t)i)].n;
    codegen__codegen__TyArgs4 fargs = (codegen__codegen__TyArgs4){0};
    for (uint8_t k = 0U; k < fn_n; k++) {
      (fargs.t[((size_t)k)] = self->insts[((size_t)i)].args[((size_t)k)]);
    }
    const bool foreign = (fn2.module != codegen__codegen__Codegen__cur_module(self));
    if (foreign && ((self->package == NULL) || (((size_t)fn2.module) >= codegen__codegen__Codegen__pkg_count(self)))) {
      continue;
    }
    ast__ast__Ast *const home = self->ast;
    const uint8_t *const hsrc = self->source;
    const size_t hlen = self->len;
    size_t oninst = 0ULL;
    if (foreign) {
      ast__ast__Ast *const owner = codegen__codegen__Codegen__mod_ast(self, fn2.module);
      (self->source = codegen__codegen__Codegen__mod_src(self, fn2.module));
      (self->len = String__Global__len(&(*({ __auto_type __sc59 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc59, ((size_t)fn2.module)); })).source));
      (self->borrowed = true);
      (oninst = Vector__ast__ast__TyInstance__Global__len(&(*owner).instances));
      (self->ast = owner);
      for (uint8_t kk = 0U; kk < fn_n; kk++) {
        (fargs.t[((size_t)kk)] = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*home)), fargs.t[((size_t)kk)]));
      }
    }
    const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn2.node);
    const lexer__token__Span fsp = fnn->span;
    const ast__ast__NodeList gens = fnn->as_data.function.generics;
    (self->nsubst = 0);
    uint32_t g = 0U;
    while (((g < gens.len) && (g < ((uint32_t)fn_n))) && (self->nsubst < 16)) {
      const uint32_t gid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens)[((size_t)g)];
      const int32_t ns = self->nsubst;
      (self->subst[((size_t)ns)].param = (ast__ast__DefId){ .module = fn2.module, .node = gid });
      (self->subst[((size_t)ns)].concrete = fargs.t[((size_t)g)]);
      (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(ns, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      (g = (g + 1U));
    }
    uint32_t nid = 1U;
    while (((size_t)nid) < Vector__ast__ast__Node__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).nodes)) {
      const ast__ast__Node *const nn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid);
      if (((nn->kind != ast__ast__NodeKind_NODE_CALL) || (nn->span.start < fsp.start)) || (nn->span.end > fsp.end)) {
        (nid = (nid + 1U));
        continue;
      }
      codegen__codegen__TyArgs4 args = (codegen__codegen__TyArgs4){0};
      int32_t n = 0;
      const ast__ast__DefId g2 = codegen__codegen__Codegen__generic_call_target(self, nid, ((uint32_t *)(&args.t[0])), ((int32_t *)(&n)));
      if (g2.node == ast__ast__NODE_NONE) {
        (nid = (nid + 1U));
        continue;
      }
      bool concrete = true;
      for (int32_t kk = 0; kk < n; kk++) {
        (args.t[((size_t)kk)] = codegen__codegen__Codegen__subst_resolve(self, args.t[((size_t)kk)]));
        if (!codegen__codegen__Codegen__type_is_concrete(self, args.t[((size_t)kk)])) {
          (concrete = false);
        }
        if (foreign) {
          (args.t[((size_t)kk)] = ast__ast__Ast__reintern(&((*home)), (&(*codegen__codegen__Codegen__cur_ast(self))), args.t[((size_t)kk)]));
        }
      }
      if (concrete) {
        codegen__codegen__Codegen__record_inst(self, g2, ((const uint32_t *)(&args.t[0])), n, nid);
      }
      (nid = (nid + 1U));
    }
    (self->nsubst = 0);
    if (foreign) {
      Vector__ast__ast__TyInstance__Global__truncate(&(*codegen__codegen__Codegen__cur_ast(self)).instances, oninst);
      (self->borrowed = false);
      (self->ast = home);
      (self->source = hsrc);
      (self->len = hlen);
    }
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_alias_extended(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const aliasDecl) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
    if ((it->kind == ast__ast__NodeKind_NODE_EXTEND) && (it->as_data.extend_def.target_type != ast__ast__NODE_NONE)) {
      const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type);
      if ((tg.module == m) && (tg.node == aliasDecl)) {
        return true;
      }
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_fn_is_capturing(const codegen__codegen__Codegen *const self, const ast__ast__Ty *const fy) {
  if (fy->kind != ast__ast__TypeKind_TYPE_FUNCTION) {
    return false;
  }
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, fy->module))), fy->as_data.decl);
  return ((fnn->kind == ast__ast__NodeKind_NODE_CLOSURE) && (fnn->as_data.closure.captures.len != 0U));
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_type_node(codegen__codegen__Codegen *const self, uint32_t const tn, const char *const decl, char *const out, size_t const cap) {
  if (tn == ast__ast__NODE_NONE) {
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc60 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc60); })), codegen__codegen__sep(decl), decl);
    return;
  }
  ast__ast__Ast *const a = codegen__codegen__Codegen__cur_ast(self);
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*a)), tn));
  const ast__ast__NodeKind nk = n.kind;
  if ((nk == ast__ast__NodeKind_NODE_TYPE_PATH) || (nk == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), tn);
    if (d.node != ast__ast__NODE_NONE) {
      const uint32_t nt = ast__ast__Ast__type_of(&((*a)), tn);
      if (nt != ast__ast__TYPE_NONE) {
        const ast__ast__TypeKind ntk = codegen__codegen__Codegen__type_at(self, nt)->kind;
        if ((ntk == ast__ast__TypeKind_TYPE_INSTANCE) || (ntk == ast__ast__TypeKind_TYPE_DYN)) {
          codegen__codegen__Codegen__render_type_id(self, nt, decl, out, cap);
          return;
        }
      }
      int32_t bb = -1;
      if (self->package != NULL) {
        (bb = module__loader__Package__builtin_of_decl(&((*self->package)), d.module, d.node));
      }
      if (bb >= 0) {
        codegen__codegen__buf_join3(out, cap, codegen__codegen__builtin_c(((ast__ast__BuiltinType)bb)), codegen__codegen__sep(decl), decl);
        return;
      }
      const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node));
      if ((dn.kind == ast__ast__NodeKind_NODE_STRUCT) || (dn.kind == ast__ast__NodeKind_NODE_ENUM)) {
        codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_qualified(self, d.module, dn.as_data.aggregate.name, ((char *)(&nm.b[0])), 160ULL);
        codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
      } else if ((dn.kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) && (dn.as_data.type_alias.ty == ast__ast__NODE_NONE)) {
        codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
        codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, d.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), dn.as_data.type_alias.name)->as_data.name.text, ((char *)(&nm.b[0])), 160ULL);
        codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
      } else if (((dn.kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) && (dn.as_data.type_alias.generics.len == 0U)) && codegen__codegen__Codegen__cg_alias_extended(self, d.module, d.node)) {
        codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_qualified(self, d.module, dn.as_data.type_alias.name, ((char *)(&nm.b[0])), 160ULL);
        codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
      } else if ((dn.kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) && (d.module == codegen__codegen__Codegen__cur_module(self))) {
        codegen__codegen__Codegen__render_type_node(self, dn.as_data.type_alias.ty, decl, out, cap);
      } else if (dn.kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
        codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), tn), decl, out, cap);
      } else if ((dn.kind == ast__ast__NodeKind_NODE_GENERIC_PARAM) || (dn.kind == ast__ast__NodeKind_NODE_INTERFACE)) {
        const uint32_t s = codegen__codegen__Codegen__subst_lookup(self, d.module, d.node);
        if (s != ast__ast__TYPE_NONE) {
          codegen__codegen__Codegen__render_type_id(self, s, decl, out, cap);
        } else if (self->macro_mode && (dn.kind == ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
          codegen__codegen__Buf64 p = (codegen__codegen__Buf64){0};
          codegen__codegen__Codegen__render_macro_param(self, d.module, d.node, ((char *)(&p.b[0])), 64ULL);
          codegen__codegen__buf_join3(out, cap, ((const char *)(&p.b[0])), codegen__codegen__sep(decl), decl);
        } else {
          codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc61 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc61); })), codegen__codegen__sep(decl), decl);
        }
      } else {
        utils__errors__Errors__emit(&self->errors, n.span.start, (n.span.end - n.span.start), ({ String__Global __sc62 = String__Global__new();
String__Global__push_str(&__sc62, (str){ .ptr = (const uint8_t*)"codegen: opaque type is not yet supported", .len = sizeof("codegen: opaque type is not yet supported") - 1 });
__sc62; }));
        utils__errors__Errors__note(&self->errors, ({ String__Global __sc63 = String__Global__new();
String__Global__push_str(&__sc63, (str){ (const uint8_t *)"opaque extern types are supported through 'extern \"C\" { type Name; }' aliases", sizeof("opaque extern types are supported through 'extern \"C\" { type Name; }' aliases") - 1 });
__sc63; }));
        codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc64 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc64); })), codegen__codegen__sep(decl), decl);
      }
      return;
    }
    lexer__token__Span s = n.span;
    if (nk == ast__ast__NodeKind_NODE_TYPE_PATH) {
      const ast__ast__NodeList parts = n.as_data.type_path.parts;
      if (parts.len != 0U) {
        (s = codegen__codegen__Codegen__name_span(self, ast__ast__Ast__list(&((*a)), parts)[0]));
      }
    } else {
      (s = n.as_data.name.text);
    }
    const int32_t b = codegen__codegen__builtin_of(self->source, s);
    if (b >= 0) {
      codegen__codegen__buf_join3(out, cap, codegen__codegen__builtin_c(((ast__ast__BuiltinType)b)), codegen__codegen__sep(decl), decl);
    } else {
      utils__errors__Errors__emit(&self->errors, s.start, (s.end - s.start), ({ String__Global __sc65 = String__Global__new();
String__Global__push_str(&__sc65, (str){ .ptr = (const uint8_t*)"codegen: unresolved type '", .len = sizeof("codegen: unresolved type '") - 1 });
String__Global__push_str(&__sc65, utils__errors__span_str(self->source, s.start, s.end));
String__Global__push_str(&__sc65, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc65; }));
      codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc66 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc66); })), codegen__codegen__sep(decl), decl);
    }
    return;
  }
  if ((nk == ast__ast__NodeKind_NODE_POINTER_TYPE) || (nk == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
    const ast__ast__IndirectTypeData it = n.as_data.indirect_type;
    const uint32_t pt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), it.ty);
    uint32_t ptr = ast__ast__TYPE_NONE;
    if (pt != ast__ast__TYPE_NONE) {
      (ptr = codegen__codegen__Codegen__subst_resolve(self, pt));
    }
    if (ptr != ast__ast__TYPE_NONE) {
      const ast__ast__Ty ay = (*codegen__codegen__Codegen__type_at(self, ptr));
      if ((ay.kind == ast__ast__TypeKind_TYPE_ARRAY) && (ay.as_data.arr.len != 0U)) {
        codegen__codegen__Buf512 spiral = (codegen__codegen__Buf512){0};
        snprintf(((char *)(&spiral.b[0])), 480ULL, ((const char *)({ __auto_type __sc67 = (str){ (const uint8_t *)"(*%s)[%u]", sizeof("(*%s)[%u]") - 1 }; str__ptr(&__sc67); })), decl, ay.as_data.arr.len);
        bool cp = (it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_CONST);
        if (nk == ast__ast__NodeKind_NODE_REFERENCE_TYPE) {
          (cp = (it.qualifier != ast__ast__TypeQualifier_TYPE_QUAL_MUT));
        }
        codegen__codegen__Buf512 base = (codegen__codegen__Buf512){0};
        codegen__codegen__Codegen__render_type_id(self, ay.as_data.elem, ((const char *)(&spiral.b[0])), ((char *)(&base.b[0])), 512ULL);
        const char *pfx = ((const char *)({ __auto_type __sc68 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc68); }));
        if (cp && codegen__codegen__not_const_prefixed(((const char *)(&base.b[0])))) {
          (pfx = ((const char *)({ __auto_type __sc69 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc69); })));
        }
        codegen__codegen__buf_join3(out, cap, pfx, ((const char *)({ __auto_type __sc70 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc70); })), ((const char *)(&base.b[0])));
        return;
      }
    }
    codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
    codegen__codegen__buf_join3(((char *)(&inner.b[0])), 480ULL, ((const char *)({ __auto_type __sc71 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc71); })), ((const char *)({ __auto_type __sc72 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc72); })), decl);
    bool const_pointee = (it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_CONST);
    if (nk == ast__ast__NodeKind_NODE_REFERENCE_TYPE) {
      (const_pointee = (it.qualifier != ast__ast__TypeQualifier_TYPE_QUAL_MUT));
    }
    bool elem_is_ptr = false;
    if ((ptr != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, ptr)->kind == ast__ast__TypeKind_TYPE_POINTER)) {
      (elem_is_ptr = true);
    }
    if (const_pointee && elem_is_ptr) {
      codegen__codegen__Buf512 cinner = (codegen__codegen__Buf512){0};
      codegen__codegen__buf_join3(((char *)(&cinner.b[0])), 480ULL, ((const char *)({ __auto_type __sc73 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc73); })), ((const char *)({ __auto_type __sc74 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc74); })), ((const char *)(&inner.b[0])));
      codegen__codegen__Codegen__render_type_node(self, it.ty, ((const char *)(&cinner.b[0])), out, cap);
    } else if (const_pointee) {
      codegen__codegen__Buf512 base = (codegen__codegen__Buf512){0};
      codegen__codegen__Codegen__render_type_node(self, it.ty, ((const char *)(&inner.b[0])), ((char *)(&base.b[0])), 512ULL);
      const char *pfx = ((const char *)({ __auto_type __sc75 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc75); }));
      if (!codegen__codegen__not_const_prefixed(((const char *)(&base.b[0])))) {
        (pfx = ((const char *)({ __auto_type __sc76 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc76); })));
      }
      codegen__codegen__buf_join3(out, cap, pfx, ((const char *)({ __auto_type __sc77 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc77); })), ((const char *)(&base.b[0])));
    } else {
      codegen__codegen__Codegen__render_type_node(self, it.ty, ((const char *)(&inner.b[0])), out, cap);
    }
    return;
  }
  if (((nk == ast__ast__NodeKind_NODE_SLICE_TYPE) || (nk == ast__ast__NodeKind_NODE_TUPLE_TYPE)) || (nk == ast__ast__NodeKind_NODE_DYN_TYPE)) {
    codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), tn), decl, out, cap);
    return;
  }
  if (nk == ast__ast__NodeKind_NODE_ARRAY_TYPE) {
    const uint32_t att = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), tn);
    uint32_t flen = 0U;
    if ((att != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, att)->kind == ast__ast__TypeKind_TYPE_ARRAY)) {
      (flen = codegen__codegen__Codegen__type_at(self, att)->as_data.arr.len);
    }
    codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
    const int64_t clen = ({
      int64_t __sc78;
      if (flen != 0U) {
        __sc78 = -1LL;
      } else {
        __sc78 = codegen__codegen__Codegen__cg_const_len_subst(self, n.as_data.array_type.length);
      }
      __sc78;
    });
    if (flen != 0U) {
      snprintf(((char *)(&inner.b[0])), 480ULL, ((const char *)({ __auto_type __sc79 = (str){ (const uint8_t *)"%s[%u]", sizeof("%s[%u]") - 1 }; str__ptr(&__sc79); })), decl, flen);
    } else if (clen >= 0) {
      snprintf(((char *)(&inner.b[0])), 480ULL, ((const char *)({ __auto_type __sc80 = (str){ (const uint8_t *)"%s[%lld]", sizeof("%s[%lld]") - 1 }; str__ptr(&__sc80); })), decl, clen);
    } else {
      const lexer__token__Span ls = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.array_type.length)->span;
      size_t at = codegen__codegen__bappend(((char *)(&inner.b[0])), 480ULL, 0ULL, decl);
      (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 480ULL, at, ((const char *)({ __auto_type __sc81 = (str){ (const uint8_t *)"[", sizeof("[") - 1 }; str__ptr(&__sc81); }))));
      (at = codegen__codegen__bappend_bytes(((char *)(&inner.b[0])), 480ULL, at, codegen__codegen__src_at(self->source, ls.start), ((size_t)(ls.end - ls.start))));
      codegen__codegen__bappend(((char *)(&inner.b[0])), 480ULL, at, ((const char *)({ __auto_type __sc82 = (str){ (const uint8_t *)"]", sizeof("]") - 1 }; str__ptr(&__sc82); })));
    }
    codegen__codegen__Codegen__render_type_node(self, n.as_data.array_type.element, ((const char *)(&inner.b[0])), out, cap);
    return;
  }
  if (nk == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    const ast__ast__FunctionTypeData ft = n.as_data.function_type;
    codegen__codegen__Buf512 params = (codegen__codegen__Buf512){0};
    size_t k = 0ULL;
    uint32_t i = 0U;
    while ((i < ft.params.len) && (k < 480ULL)) {
      const uint32_t pid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ft.params)[((size_t)i)];
      codegen__codegen__Buf256 t = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_type_node(self, pid, ((const char *)({ __auto_type __sc83 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc83); })), ((char *)(&t.b[0])), 256ULL);
      if (i != 0U) {
        (k = codegen__codegen__bappend(((char *)(&params.b[0])), 480ULL, k, ((const char *)({ __auto_type __sc84 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc84); }))));
      }
      (k = codegen__codegen__bappend(((char *)(&params.b[0])), 480ULL, k, ((const char *)(&t.b[0]))));
      (i = (i + 1U));
    }
    codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
    size_t at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, 0ULL, ((const char *)({ __auto_type __sc85 = (str){ (const uint8_t *)"(*", sizeof("(*") - 1 }; str__ptr(&__sc85); })));
    (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, decl));
    (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc86 = (str){ (const uint8_t *)")(", sizeof(")(") - 1 }; str__ptr(&__sc86); }))));
    const char *pstr = ((const char *)({ __auto_type __sc87 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc87); }));
    if (ft.params.len != 0U) {
      (pstr = ((const char *)(&params.b[0])));
    }
    (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, pstr));
    codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc88 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc88); })));
    if (ft.returns.len == 1U) {
      const uint32_t r0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ft.returns)[0];
      const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), r0);
      const uint32_t rtn = codegen__codegen__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0);
      codegen__codegen__Codegen__render_type_node(self, rtn, ((const char *)(&inner.b[0])), out, cap);
    } else if (ft.returns.len == 0U) {
      codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc89 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc89); })), ((const char *)({ __auto_type __sc90 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc90); })), ((const char *)(&inner.b[0])));
    } else {
      utils__errors__Errors__emit(&self->errors, n.span.start, (n.span.end - n.span.start), ({ String__Global __sc91 = String__Global__new();
String__Global__push_str(&__sc91, (str){ .ptr = (const uint8_t*)"codegen: multi-return function pointer is not yet supported", .len = sizeof("codegen: multi-return function pointer is not yet supported") - 1 });
__sc91; }));
      codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc92 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc92); })), ((const char *)({ __auto_type __sc93 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc93); })), ((const char *)(&inner.b[0])));
    }
    return;
  }
  utils__errors__Errors__emit(&self->errors, n.span.start, (n.span.end - n.span.start), ({ String__Global __sc94 = String__Global__new();
String__Global__push_str(&__sc94, (str){ .ptr = (const uint8_t*)"codegen: unsupported type", .len = sizeof("codegen: unsupported type") - 1 });
__sc94; }));
  codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc95 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc95); })), codegen__codegen__sep(decl), decl);
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_type_id(codegen__codegen__Codegen *const self, uint32_t const t, const char *const decl, char *const out, size_t const cap) {
  const ast__ast__Ty ty = (*codegen__codegen__Codegen__type_at(self, t));
  if (ty.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    codegen__codegen__buf_join3(out, cap, codegen__codegen__builtin_c(ty.as_data.builtin), codegen__codegen__sep(decl), decl);
  } else if (ty.kind == ast__ast__TypeKind_TYPE_NEVER) {
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc96 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc96); })), codegen__codegen__sep(decl), decl);
  } else if ((ty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ty.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_qualified(self, ty.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, ty.module))), ty.as_data.decl)->as_data.aggregate.name, ((char *)(&nm.b[0])), 160ULL);
    codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
  } else if ((ty.kind == ast__ast__TypeKind_TYPE_POINTER) || (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    const ast__ast__Ty el = (*codegen__codegen__Codegen__type_at(self, ty.as_data.elem));
    if ((el.kind == ast__ast__TypeKind_TYPE_ARRAY) && (el.as_data.arr.len != 0U)) {
      codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
      snprintf(((char *)(&inner.b[0])), 480ULL, ((const char *)({ __auto_type __sc97 = (str){ (const uint8_t *)"(*%s)[%u]", sizeof("(*%s)[%u]") - 1 }; str__ptr(&__sc97); })), decl, el.as_data.arr.len);
      bool cp = (ty.qualifier == 1U);
      if (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE) {
        (cp = (ty.qualifier != 2U));
      }
      codegen__codegen__Buf512 base = (codegen__codegen__Buf512){0};
      codegen__codegen__Codegen__render_type_id(self, el.as_data.elem, ((const char *)(&inner.b[0])), ((char *)(&base.b[0])), 512ULL);
      const char *pfx = ((const char *)({ __auto_type __sc98 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc98); }));
      if (cp && codegen__codegen__not_const_prefixed(((const char *)(&base.b[0])))) {
        (pfx = ((const char *)({ __auto_type __sc99 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc99); })));
      }
      codegen__codegen__buf_join3(out, cap, pfx, ((const char *)({ __auto_type __sc100 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc100); })), ((const char *)(&base.b[0])));
      return;
    }
    codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
    codegen__codegen__buf_join3(((char *)(&inner.b[0])), 480ULL, ((const char *)({ __auto_type __sc101 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc101); })), ((const char *)({ __auto_type __sc102 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc102); })), decl);
    bool const_pointee = (ty.qualifier == 1U);
    if (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE) {
      (const_pointee = (ty.qualifier != 2U));
    }
    const bool elem_is_ptr = (codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ty.as_data.elem))->kind == ast__ast__TypeKind_TYPE_POINTER);
    if (const_pointee && elem_is_ptr) {
      codegen__codegen__Buf512 cinner = (codegen__codegen__Buf512){0};
      codegen__codegen__buf_join3(((char *)(&cinner.b[0])), 480ULL, ((const char *)({ __auto_type __sc103 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc103); })), ((const char *)({ __auto_type __sc104 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc104); })), ((const char *)(&inner.b[0])));
      codegen__codegen__Codegen__render_type_id(self, ty.as_data.elem, ((const char *)(&cinner.b[0])), out, cap);
    } else if (const_pointee) {
      codegen__codegen__Buf512 base = (codegen__codegen__Buf512){0};
      codegen__codegen__Codegen__render_type_id(self, ty.as_data.elem, ((const char *)(&inner.b[0])), ((char *)(&base.b[0])), 512ULL);
      const char *pfx = ((const char *)({ __auto_type __sc105 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc105); }));
      if (!codegen__codegen__not_const_prefixed(((const char *)(&base.b[0])))) {
        (pfx = ((const char *)({ __auto_type __sc106 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc106); })));
      }
      codegen__codegen__buf_join3(out, cap, pfx, ((const char *)({ __auto_type __sc107 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc107); })), ((const char *)(&base.b[0])));
    } else {
      codegen__codegen__Codegen__render_type_id(self, ty.as_data.elem, ((const char *)(&inner.b[0])), out, cap);
    }
  } else if (ty.kind == ast__ast__TypeKind_TYPE_SLICE) {
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc108 = (str){ (const uint8_t *)"SCslice", sizeof("SCslice") - 1 }; str__ptr(&__sc108); })), codegen__codegen__sep(decl), decl);
  } else if (ty.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
    if (ty.as_data.arr.len != 0U) {
      codegen__codegen__Buf32 lenb = (codegen__codegen__Buf32){0};
      snprintf(((char *)(&lenb.b[0])), 16ULL, ((const char *)({ __auto_type __sc109 = (str){ (const uint8_t *)"[%u]", sizeof("[%u]") - 1 }; str__ptr(&__sc109); })), ty.as_data.arr.len);
      codegen__codegen__buf_join3(((char *)(&inner.b[0])), 480ULL, decl, ((const char *)({ __auto_type __sc110 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc110); })), ((const char *)(&lenb.b[0])));
    } else {
      codegen__codegen__buf_join3(((char *)(&inner.b[0])), 480ULL, ((const char *)({ __auto_type __sc111 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc111); })), ((const char *)({ __auto_type __sc112 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc112); })), decl);
    }
    codegen__codegen__Codegen__render_type_id(self, ty.as_data.elem, ((const char *)(&inner.b[0])), out, cap);
  } else if (ty.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const uint32_t s = codegen__codegen__Codegen__subst_lookup(self, ty.module, ty.as_data.decl);
    if (s != ast__ast__TYPE_NONE) {
      codegen__codegen__Codegen__render_type_id(self, s, decl, out, cap);
    } else if (self->macro_mode) {
      codegen__codegen__Buf64 p = (codegen__codegen__Buf64){0};
      codegen__codegen__Codegen__render_macro_param(self, ty.module, ty.as_data.decl, ((char *)(&p.b[0])), 64ULL);
      codegen__codegen__buf_join3(out, cap, ((const char *)(&p.b[0])), codegen__codegen__sep(decl), decl);
    } else {
      codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc113 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc113); })), codegen__codegen__sep(decl), decl);
    }
  } else if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ty.as_data.inst), ((char *)(&nm.b[0])), 200ULL);
    codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
  } else if (ty.kind == ast__ast__TypeKind_TYPE_OPAQUE) {
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, ty.module))), ty.as_data.decl));
    codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, ty.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, ty.module))), dn.as_data.type_alias.name)->as_data.name.text, ((char *)(&nm.b[0])), 160ULL);
    codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
  } else if (ty.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    if (codegen__codegen__Codegen__cg_fn_is_capturing(self, (&ty))) {
      codegen__codegen__Buf256 envn = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__closure_sym_in(self, ty.module, ty.as_data.decl, ((char *)(&envn.b[0])), 240ULL);
      const size_t el2 = strlen(((const char *)(&envn.b[0])));
      codegen__codegen__bappend(((char *)(&envn.b[0])), 240ULL, el2, ((const char *)({ __auto_type __sc114 = (str){ (const uint8_t *)"_env", sizeof("_env") - 1 }; str__ptr(&__sc114); })));
      codegen__codegen__buf_join3(out, cap, ((const char *)(&envn.b[0])), codegen__codegen__sep(decl), decl);
    } else {
      codegen__codegen__Codegen__render_fn_ptr_id(self, ty, decl, out, cap);
    }
  } else if (ty.kind == ast__ast__TypeKind_TYPE_DYN) {
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__dyn_stem(self, ty.module, ty.as_data.decl, ((char *)(&nm.b[0])), 200ULL);
    const size_t dl = strlen(((const char *)(&nm.b[0])));
    codegen__codegen__bappend(((char *)(&nm.b[0])), 200ULL, dl, ((const char *)({ __auto_type __sc115 = (str){ (const uint8_t *)"__dyn", sizeof("__dyn") - 1 }; str__ptr(&__sc115); })));
    codegen__codegen__buf_join3(out, cap, ((const char *)(&nm.b[0])), codegen__codegen__sep(decl), decl);
  } else {
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc116 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc116); })), codegen__codegen__sep(decl), decl);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_fn_ptr_id(codegen__codegen__Codegen *const self, ast__ast__Ty const fy, const char *const decl, char *const out, size_t const cap) {
  ast__ast__Ast *const fa = codegen__codegen__Codegen__mod_ast(self, fy.module);
  const ast__ast__Node fnn = (*ast__ast__Ast__at_const(&((*fa)), fy.as_data.decl));
  ast__ast__NodeList ps = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  ast__ast__NodeList rs = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  uint32_t body = ast__ast__NODE_NONE;
  if (fnn.kind == ast__ast__NodeKind_NODE_FUNCTION) {
    (ps = fnn.as_data.function.params);
    (rs = fnn.as_data.function.returns);
  } else if (fnn.kind == ast__ast__NodeKind_NODE_CLOSURE) {
    (ps = fnn.as_data.closure.params);
    (rs = fnn.as_data.closure.returns);
    if (fnn.as_data.closure.expr_body) {
      (body = fnn.as_data.closure.body);
    }
  } else {
    (ps = fnn.as_data.function_type.params);
    (rs = fnn.as_data.function_type.returns);
  }
  codegen__codegen__Buf512 params = (codegen__codegen__Buf512){0};
  size_t k = 0ULL;
  uint32_t i = 0U;
  while ((i < ps.len) && (k < 480ULL)) {
    const uint32_t pid = ast__ast__Ast__list(&((*fa)), ps)[((size_t)i)];
    const ast__ast__Node *const pn = ast__ast__Ast__at_const(&((*fa)), pid);
    uint32_t tn = pid;
    if (pn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
      (tn = pn->as_data.parameter.ty);
    }
    uint32_t anchor = tn;
    if (tn == ast__ast__NODE_NONE) {
      (anchor = pid);
    }
    codegen__codegen__Buf256 tt = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*fa)), ast__ast__Ast__type_of(&((*fa)), anchor)), ((const char *)({ __auto_type __sc117 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc117); })), ((char *)(&tt.b[0])), 256ULL);
    if (i != 0U) {
      (k = codegen__codegen__bappend(((char *)(&params.b[0])), 480ULL, k, ((const char *)({ __auto_type __sc118 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc118); }))));
    }
    (k = codegen__codegen__bappend(((char *)(&params.b[0])), 480ULL, k, ((const char *)(&tt.b[0]))));
    (i = (i + 1U));
  }
  codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
  size_t at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, 0ULL, ((const char *)({ __auto_type __sc119 = (str){ (const uint8_t *)"(*", sizeof("(*") - 1 }; str__ptr(&__sc119); })));
  (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, decl));
  (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc120 = (str){ (const uint8_t *)")(", sizeof(")(") - 1 }; str__ptr(&__sc120); }))));
  const char *pstr = ((const char *)({ __auto_type __sc121 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc121); }));
  if (ps.len != 0U) {
    (pstr = ((const char *)(&params.b[0])));
  }
  (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, pstr));
  codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc122 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc122); })));
  uint32_t rt = ast__ast__TYPE_NONE;
  if (rs.len == 1U) {
    const uint32_t r0 = ast__ast__Ast__list(&((*fa)), rs)[0];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*fa)), r0);
    const uint32_t rtn = codegen__codegen__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0);
    (rt = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*fa)), ast__ast__Ast__type_of(&((*fa)), rtn)));
  } else if (body != ast__ast__NODE_NONE) {
    (rt = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*fa)), ast__ast__Ast__type_of(&((*fa)), body)));
  }
  if (rt != ast__ast__TYPE_NONE) {
    codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)(&inner.b[0])), out, cap);
  } else {
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc123 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc123); })), ((const char *)({ __auto_type __sc124 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc124); })), ((const char *)(&inner.b[0])));
  }
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__enclosing_enum(const codegen__codegen__Codegen *const self, uint32_t const variant) {
  {
    const Option__ptr_u32 __sc125 = Map__u32__u32__Global__get(&self->enum_of_variant, (&variant));
    if (__sc125.tag == Option_Some) {
      const uint32_t *const v = __sc125.payload.Some._0;
      {
        return (*v);
      }
    }
    else if (1) {
      {
      }
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__enclosing_enum_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const variant) {
  if ((m == codegen__codegen__Codegen__cur_module(self)) && (!self->borrowed)) {
    return codegen__codegen__Codegen__enclosing_enum(self, variant);
  }
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_ENUM) {
      const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.aggregate.members;
      for (uint32_t j = 0U; j < ms.len; j++) {
        if (ast__ast__Ast__list(&((*a)), ms)[((size_t)j)] == variant) {
          return iid;
        }
      }
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_tag_mod(codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const enum_decl, uint32_t const variant) {
  const uint8_t *const src = codegen__codegen__Codegen__mod_src(self, m);
  codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
  codegen__codegen__Codegen__render_modpfx(self, m, ((char *)(&pfx.b[0])), 64ULL);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
  const lexer__token__Span es = codegen__codegen__Codegen__name_span_in(self, m, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), enum_decl)->as_data.aggregate.name);
  codegen__codegen__Codegen__emit_bytes(self, codegen__codegen__src_at(src, es.start), ((size_t)(es.end - es.start)));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc126 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc126); })));
  const lexer__token__Span vs = codegen__codegen__Codegen__name_span_in(self, m, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), variant)->as_data.variant.name);
  codegen__codegen__Codegen__emit_bytes(self, codegen__codegen__src_at(src, vs.start), ((size_t)(vs.end - vs.start)));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_tag(codegen__codegen__Codegen *const self, uint32_t const enum_decl, uint32_t const variant) {
  codegen__codegen__Codegen__emit_tag_mod(self, codegen__codegen__Codegen__cur_module(self), enum_decl, variant);
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_variant_name(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const variant, char *const buf, size_t const cap) {
  codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, m), codegen__codegen__Codegen__name_span_in(self, m, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), variant)->as_data.variant.name), buf, cap);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__aggregate_has_payload_in(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const enum_decl) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__NodeList members = ast__ast__Ast__at_const(&((*a)), enum_decl)->as_data.aggregate.members;
  for (uint32_t i = 0U; i < members.len; i++) {
    if (ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__list(&((*a)), members)[((size_t)i)])->as_data.variant.payload.len > 0U) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__aggregate_has_payload(const codegen__codegen__Codegen *const self, uint32_t const enum_decl) {
  return codegen__codegen__Codegen__aggregate_has_payload_in(self, codegen__codegen__Codegen__cur_module(self), enum_decl);
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__strip_ptr(const codegen__codegen__Codegen *const self, uint32_t const t0) {
  uint32_t t = t0;
  const ast__ast__Ty *y = codegen__codegen__Codegen__type_at(self, t);
  while ((y->kind == ast__ast__TypeKind_TYPE_POINTER) || (y->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    (t = y->as_data.elem);
    (y = codegen__codegen__Codegen__type_at(self, t));
  }
  return t;
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__strip_ref_only(const codegen__codegen__Codegen *const self, uint32_t const t0) {
  uint32_t t = t0;
  const ast__ast__Ty *y = codegen__codegen__Codegen__type_at(self, t);
  while (y->kind == ast__ast__TypeKind_TYPE_REFERENCE) {
    (t = y->as_data.elem);
    (y = codegen__codegen__Codegen__type_at(self, t));
  }
  if (y->kind == ast__ast__TypeKind_TYPE_POINTER) {
    return ast__ast__TYPE_NONE;
  }
  return t;
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_ref_depth(const codegen__codegen__Codegen *const self, uint32_t const t) {
  int32_t d = 0;
  const ast__ast__Ty *y = codegen__codegen__Codegen__type_at(self, t);
  while (y->kind == ast__ast__TypeKind_TYPE_REFERENCE) {
    (d = ({ int32_t __sc_r; if (__builtin_add_overflow(d, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    (y = codegen__codegen__Codegen__type_at(self, y->as_data.elem));
  }
  return d;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_fn_owns(codegen__codegen__Codegen *const self, const ast__ast__Ty *const fy) {
  if (fy->kind != ast__ast__TypeKind_TYPE_FUNCTION) {
    return false;
  }
  ast__ast__Ast *const fa = codegen__codegen__Codegen__mod_ast(self, fy->module);
  const ast__ast__Node fnn = (*ast__ast__Ast__at_const(&((*fa)), fy->as_data.decl));
  if (fnn.kind != ast__ast__NodeKind_NODE_CLOSURE) {
    return false;
  }
  const ast__ast__NodeList caps = fnn.as_data.closure.captures;
  const uint64_t mut_caps = ((uint64_t)fnn.as_data.closure.mut_caps);
  for (uint32_t i = 0U; i < caps.len; i++) {
    const uint32_t cid = ast__ast__Ast__list(&((*fa)), caps)[((size_t)i)];
    if ((({ uint64_t __sc127 = mut_caps; int64_t __sc128 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc128 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc127 >> __sc128); }) & 1ULL) == 0ULL) {
      const uint32_t rt = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*fa)), ast__ast__Ast__type_of(&((*fa)), cid));
      if (codegen__codegen__Codegen__cg_type_is_free(self, rt)) {
        return true;
      }
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_slice_elem(const codegen__codegen__Codegen *const self, uint32_t const tid, uint32_t *const elem) {
  if (self->package == NULL) {
    return false;
  }
  const ast__ast__Ty *const ty = codegen__codegen__Codegen__type_at(self, tid);
  if (ty->kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return false;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ty->as_data.inst));
  const module__loader__LookupHit sh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Slice", sizeof("Slice") - 1 }, true);
  const module__loader__LookupHit mh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"SliceMut", sizeof("SliceMut") - 1 }, true);
  const bool is_slice = (((it.module == sh.mid) && (it.decl == sh.node)) || ((it.module == mh.mid) && (it.decl == mh.node)));
  if ((is_slice && (it.n == 1U)) && (elem != NULL)) {
    ((*elem) = it.args[0]);
  }
  return (is_slice && (it.n == 1U));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_range_elem(const codegen__codegen__Codegen *const self, uint32_t const tid, uint32_t *const elem) {
  if (self->package == NULL) {
    return false;
  }
  const ast__ast__Ty *const ty = codegen__codegen__Codegen__type_at(self, tid);
  if (ty->kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return false;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ty->as_data.inst));
  const module__loader__LookupHit rh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Range", sizeof("Range") - 1 }, true);
  const bool is_range = (((it.n == 1U) && (it.module == rh.mid)) && (it.decl == rh.node));
  if (is_range && (elem != NULL)) {
    ((*elem) = it.args[0]);
  }
  return is_range;
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_free_extend(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl) {
  const uint64_t key = (({ uint64_t __sc129 = ((uint64_t)tmod); int64_t __sc130 = (int64_t)(32ULL); if ((uint64_t)__sc130 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc129 << __sc130)); }) | ((uint64_t)tdecl));
  {
    const Option__ptr_ast__ast__DefId __sc131 = Map__u64__ast__ast__DefId__Global__get(&self->free_ext_cache, (&key));
    if (__sc131.tag == Option_Some) {
      const ast__ast__DefId *const d = __sc131.payload.Some._0;
      return (*d);
    }
    else if (__sc131.tag == Option_None) {
      return ({
        const ast__ast__DefId r = codegen__codegen__Codegen__cg_free_extend_uncached(self, tmod, tdecl);
        codegen__codegen__Codegen *const mp = ((codegen__codegen__Codegen *)((const codegen__codegen__Codegen *)self));
        {
          Map__u64__ast__ast__DefId__Global__insert(&(*mp).free_ext_cache, key, r);
        }
        r;
      });
    }
    else { __builtin_unreachable(); }
  }
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_free_extend_uncached(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl) {
  int32_t ns = 1;
  if (tmod != codegen__codegen__Codegen__cur_module(self)) {
    (ns = 2);
  }
  for (int32_t s = 0; s < ns; s++) {
    uint16_t m = tmod;
    if (s == 1) {
      (m = codegen__codegen__Codegen__cur_module(self));
    }
    ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (((it->kind == ast__ast__NodeKind_NODE_EXTEND) && (it->as_data.extend_def.interface_type != ast__ast__NODE_NONE)) && (it->as_data.extend_def.target_type != ast__ast__NODE_NONE)) {
        const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type);
        if ((tg.module == tmod) && (tg.node == tdecl)) {
          const ast__ast__DefId tr = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.interface_type);
          if (tr.node != ast__ast__NODE_NONE) {
            const ast__ast__Node *const trn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, tr.module))), tr.node);
            if ((trn->kind == ast__ast__NodeKind_NODE_INTERFACE) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, tr.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, tr.module))), trn->as_data.interface_def.name)->as_data.name.text, ((const char *)({ __auto_type __sc132 = (str){ (const uint8_t *)"Free", sizeof("Free") - 1 }; str__ptr(&__sc132); })))) {
              return (ast__ast__DefId){ .module = m, .node = iid };
            }
          }
        }
      }
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_free_method(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl) {
  const ast__ast__DefId ext = codegen__codegen__Codegen__cg_free_extend(self, tmod, tdecl);
  if (ext.node == ast__ast__NODE_NONE) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, ext.module);
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), ext.node)->as_data.extend_def.items;
  for (uint32_t j = 0U; j < ms.len; j++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)j)];
    const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
    if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, ext.module), ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text, ((const char *)({ __auto_type __sc133 = (str){ (const uint8_t *)"free", sizeof("free") - 1 }; str__ptr(&__sc133); })))) {
      return (ast__ast__DefId){ .module = ext.module, .node = mid };
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_param_has_free_bound(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const gp) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__NodeList bs = ast__ast__Ast__at_const(&((*a)), gp)->as_data.generic_param.bounds;
  for (uint32_t i = 0U; i < bs.len; i++) {
    const ast__ast__DefId bd = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__list(&((*a)), bs)[((size_t)i)]);
    if (bd.node != ast__ast__NODE_NONE) {
      const ast__ast__Node *const bn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, bd.module))), bd.node);
      if ((bn->kind == ast__ast__NodeKind_NODE_INTERFACE) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, bd.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, bd.module))), bn->as_data.interface_def.name)->as_data.name.text, ((const char *)({ __auto_type __sc134 = (str){ (const uint8_t *)"Free", sizeof("Free") - 1 }; str__ptr(&__sc134); })))) {
        return true;
      }
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_type_is_free(codegen__codegen__Codegen *const self, uint32_t const ty0) {
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ty0)));
  if (y.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    return codegen__codegen__Codegen__cg_fn_owns(self, (&y));
  }
  if (y.kind == ast__ast__TypeKind_TYPE_DYN) {
    return (y.qualifier == 0U);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_STRUCT) {
    return (codegen__codegen__Codegen__cg_free_method(self, y.module, y.as_data.decl).node != ast__ast__NODE_NONE);
  }
  if (y.kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return false;
  }
  const ast__ast__TyInstance ii = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
  const ast__ast__DefId ext = codegen__codegen__Codegen__cg_free_extend(self, ii.module, ii.decl);
  if (ext.node == ast__ast__NODE_NONE) {
    return false;
  }
  ast__ast__Ast *const ia = codegen__codegen__Codegen__mod_ast(self, ext.module);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*ia)), ext.node)->as_data.extend_def.generics;
  uint32_t i = 0U;
  while ((i < gens.len) && (((uint8_t)i) < ii.n)) {
    const uint32_t gid = ast__ast__Ast__list(&((*ia)), gens)[((size_t)i)];
    if (codegen__codegen__Codegen__cg_param_has_free_bound(self, ext.module, gid) && (!codegen__codegen__Codegen__cg_type_is_free(self, ii.args[((size_t)i)]))) {
      return false;
    }
    (i = (i + 1U));
  }
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_moved(const codegen__codegen__Codegen *const self, uint32_t const decl) {
  for (uint32_t i = 0U; i < self->nmoved; i++) {
    if (self->moved[((size_t)i)] == decl) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_cond_moved(const codegen__codegen__Codegen *const self, uint32_t const decl) {
  for (uint32_t i = 0U; i < self->ncond_moved; i++) {
    if (self->cond_moved[((size_t)i)] == decl) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_cond_site(const codegen__codegen__Codegen *const self, uint32_t const expr) {
  for (uint32_t i = 0U; i < self->ncond_sites; i++) {
    if (self->cond_sites[((size_t)i)] == expr) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_find_method_impl(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const uint8_t *const nsrc, lexer__token__Span const name, const char *const lit) {
  codegen__codegen__ScopeArr scopes = (codegen__codegen__ScopeArr){0};
  int32_t ns = 0;
  (scopes.s[0] = tmod);
  (ns = 1);
  if (codegen__codegen__Codegen__cur_module(self) != tmod) {
    (scopes.s[((size_t)ns)] = codegen__codegen__Codegen__cur_module(self));
    (ns = ({ int32_t __sc_r; if (__builtin_add_overflow(ns, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if ((self->dflt_home_set && (self->dflt_home != tmod)) && (self->dflt_home != codegen__codegen__Codegen__cur_module(self))) {
    (scopes.s[((size_t)ns)] = self->dflt_home);
    (ns = ({ int32_t __sc_r; if (__builtin_add_overflow(ns, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  for (int32_t s = 0; s < ns; s++) {
    const uint16_t m = scopes.s[((size_t)s)];
    ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if ((it->kind == ast__ast__NodeKind_NODE_EXTEND) && (it->as_data.extend_def.target_type != ast__ast__NODE_NONE)) {
        const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type);
        if ((tg.module == tmod) && (tg.node == tdecl)) {
          const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
          for (uint32_t j = 0U; j < ms.len; j++) {
            const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)j)];
            const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
            if (mn->kind == ast__ast__NodeKind_NODE_FUNCTION) {
              const lexer__token__Span mname = ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text;
              bool hit = false;
              if (lit != NULL) {
                (hit = codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, m), mname, lit));
              } else {
                (hit = codegen__codegen__spans_eq2(nsrc, name, codegen__codegen__Codegen__mod_src(self, m), mname));
              }
              if (hit) {
                return (ast__ast__DefId){ .module = m, .node = mid };
              }
            }
          }
        }
      }
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_find_method(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const uint8_t *const nsrc, lexer__token__Span const name) {
  return codegen__codegen__Codegen__cg_find_method_impl(self, tmod, tdecl, nsrc, name, NULL);
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_find_method_cstr(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const char *const lit) {
  return codegen__codegen__Codegen__cg_find_method_impl(self, tmod, tdecl, NULL, lexer__token__Span__empty(), lit);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_def_const_ok(const codegen__codegen__Codegen *const self, ast__ast__DefId const d) {
  if (d.node == ast__ast__NODE_NONE) {
    return true;
  }
  if (((size_t)d.module) >= Vector__module__loader__Module__Global__len(&(*self->package).modules)) {
    return true;
  }
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->kind;
  if ((dk == ast__ast__NodeKind_NODE_FUNCTION) || (dk == ast__ast__NodeKind_NODE_VARIANT)) {
    return true;
  }
  if (dk == ast__ast__NodeKind_NODE_CONST) {
    const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.const_def;
    return ((cd.value != ast__ast__NODE_NONE) && (!cd.is_static_mut));
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_maybe_const(const codegen__codegen__Codegen *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return true;
  }
  ast__ast__Ast *const a = codegen__codegen__Codegen__cur_ast(self);
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*a)), id));
  const ast__ast__NodeKind k = n.kind;
  if (((k == ast__ast__NodeKind_NODE_LITERAL) || (k == ast__ast__NodeKind_NODE_SIZEOF)) || (k == ast__ast__NodeKind_NODE_ALIGNOF)) {
    return true;
  }
  if (k == ast__ast__NodeKind_NODE_BINARY) {
    return (codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.binary.left) && codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.binary.right));
  }
  if (k == ast__ast__NodeKind_NODE_UNARY) {
    return codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.unary.operand);
  }
  if (k == ast__ast__NodeKind_NODE_CAST) {
    return codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.cast.expression);
  }
  if (k == ast__ast__NodeKind_NODE_INDEX) {
    return (codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.index.object) && codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.index.index));
  }
  if (k == ast__ast__NodeKind_NODE_CALL) {
    if (!codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.call.callee)) {
      return false;
    }
    const ast__ast__NodeList args = n.as_data.call.args;
    const uint32_t *const ids = ast__ast__Ast__list(&((*a)), args);
    for (uint32_t i = 0U; i < args.len; i++) {
      if (!codegen__codegen__Codegen__cg_maybe_const(self, ids[((size_t)i)])) {
        return false;
      }
    }
    return true;
  }
  if (k == ast__ast__NodeKind_NODE_IDENTIFIER) {
    ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
    if (d.node == ast__ast__NODE_NONE) {
      (d = (ast__ast__DefId){ .module = (*a).module, .node = ast__ast__Ast__resolution(&((*a)), id) });
    }
    return codegen__codegen__Codegen__cg_def_const_ok(self, d);
  }
  if (k == ast__ast__NodeKind_NODE_MEMBER) {
    if (n.as_data.member.path) {
      ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
      if (d.node == ast__ast__NODE_NONE) {
        (d = ast__ast__Ast__resolution_def(&((*a)), n.as_data.member.member));
      }
      return codegen__codegen__Codegen__cg_def_const_ok(self, d);
    }
    return codegen__codegen__Codegen__cg_maybe_const(self, n.as_data.member.object);
  }
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__is_lvalue(const codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  if ((n->kind == ast__ast__NodeKind_NODE_IDENTIFIER) || (n->kind == ast__ast__NodeKind_NODE_INDEX)) {
    return true;
  }
  if (n->kind == ast__ast__NodeKind_NODE_MEMBER) {
    return (!n->as_data.member.path);
  }
  if (n->kind == ast__ast__NodeKind_NODE_UNARY) {
    if ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe)) {
      return codegen__codegen__Codegen__is_lvalue(self, n->as_data.unary.operand);
    }
    return (n->as_data.unary.op == lexer__token_type__TokenType_Star);
  }
  return false;
}

static __attribute__((unused)) uint32_t codegen__codegen__if_node(bool const c, uint32_t const a, uint32_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) void codegen__codegen__cg_move_flag(char *const out, size_t const cap, uint32_t const decl) {
  snprintf(out, cap, ((const char *)({ __auto_type __sc135 = (str){ (const uint8_t *)"__mv%u", sizeof("__mv%u") - 1 }; str__ptr(&__sc135); })), decl);
}

static __attribute__((unused)) const char *codegen__codegen__ref_derefs(int32_t const d0) {
  int32_t d = d0;
  if (d < 1) {
    (d = 1);
  } else if (d > 7) {
    (d = 7);
  }
  return ((const char *)(((const char *)({ __auto_type __sc136 = (str){ (const uint8_t *)"*******", sizeof("*******") - 1 }; str__ptr(&__sc136); })) + ((size_t)({ int32_t __sc_r; if (__builtin_sub_overflow(8, d, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))));
}

static __attribute__((unused)) const char *codegen__codegen__c_op(lexer__token_type__TokenType const t) {
  if (t == lexer__token_type__TokenType_Plus) {
    return ((const char *)({ __auto_type __sc137 = (str){ (const uint8_t *)"+", sizeof("+") - 1 }; str__ptr(&__sc137); }));
  }
  if (t == lexer__token_type__TokenType_Minus) {
    return ((const char *)({ __auto_type __sc138 = (str){ (const uint8_t *)"-", sizeof("-") - 1 }; str__ptr(&__sc138); }));
  }
  if (t == lexer__token_type__TokenType_Star) {
    return ((const char *)({ __auto_type __sc139 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc139); }));
  }
  if (t == lexer__token_type__TokenType_Slash) {
    return ((const char *)({ __auto_type __sc140 = (str){ (const uint8_t *)"/", sizeof("/") - 1 }; str__ptr(&__sc140); }));
  }
  if (t == lexer__token_type__TokenType_Percent) {
    return ((const char *)({ __auto_type __sc141 = (str){ (const uint8_t *)"%", sizeof("%") - 1 }; str__ptr(&__sc141); }));
  }
  if (t == lexer__token_type__TokenType_Ampersand) {
    return ((const char *)({ __auto_type __sc142 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc142); }));
  }
  if (t == lexer__token_type__TokenType_Pipe) {
    return ((const char *)({ __auto_type __sc143 = (str){ (const uint8_t *)"|", sizeof("|") - 1 }; str__ptr(&__sc143); }));
  }
  if (t == lexer__token_type__TokenType_Caret) {
    return ((const char *)({ __auto_type __sc144 = (str){ (const uint8_t *)"^", sizeof("^") - 1 }; str__ptr(&__sc144); }));
  }
  if (t == lexer__token_type__TokenType_LeftShift) {
    return ((const char *)({ __auto_type __sc145 = (str){ (const uint8_t *)"<<", sizeof("<<") - 1 }; str__ptr(&__sc145); }));
  }
  if (t == lexer__token_type__TokenType_RightShift) {
    return ((const char *)({ __auto_type __sc146 = (str){ (const uint8_t *)">>", sizeof(">>") - 1 }; str__ptr(&__sc146); }));
  }
  if (t == lexer__token_type__TokenType_AmpersandAmpersand) {
    return ((const char *)({ __auto_type __sc147 = (str){ (const uint8_t *)"&&", sizeof("&&") - 1 }; str__ptr(&__sc147); }));
  }
  if (t == lexer__token_type__TokenType_PipePipe) {
    return ((const char *)({ __auto_type __sc148 = (str){ (const uint8_t *)"||", sizeof("||") - 1 }; str__ptr(&__sc148); }));
  }
  if (t == lexer__token_type__TokenType_EqualEqual) {
    return ((const char *)({ __auto_type __sc149 = (str){ (const uint8_t *)"==", sizeof("==") - 1 }; str__ptr(&__sc149); }));
  }
  if (t == lexer__token_type__TokenType_BangEqual) {
    return ((const char *)({ __auto_type __sc150 = (str){ (const uint8_t *)"!=", sizeof("!=") - 1 }; str__ptr(&__sc150); }));
  }
  if (t == lexer__token_type__TokenType_LessThan) {
    return ((const char *)({ __auto_type __sc151 = (str){ (const uint8_t *)"<", sizeof("<") - 1 }; str__ptr(&__sc151); }));
  }
  if (t == lexer__token_type__TokenType_LessThanEqual) {
    return ((const char *)({ __auto_type __sc152 = (str){ (const uint8_t *)"<=", sizeof("<=") - 1 }; str__ptr(&__sc152); }));
  }
  if (t == lexer__token_type__TokenType_GreaterThan) {
    return ((const char *)({ __auto_type __sc153 = (str){ (const uint8_t *)">", sizeof(">") - 1 }; str__ptr(&__sc153); }));
  }
  if (t == lexer__token_type__TokenType_GreaterThanEqual) {
    return ((const char *)({ __auto_type __sc154 = (str){ (const uint8_t *)">=", sizeof(">=") - 1 }; str__ptr(&__sc154); }));
  }
  if (t == lexer__token_type__TokenType_Equal) {
    return ((const char *)({ __auto_type __sc155 = (str){ (const uint8_t *)"=", sizeof("=") - 1 }; str__ptr(&__sc155); }));
  }
  if (t == lexer__token_type__TokenType_PlusEqual) {
    return ((const char *)({ __auto_type __sc156 = (str){ (const uint8_t *)"+=", sizeof("+=") - 1 }; str__ptr(&__sc156); }));
  }
  if (t == lexer__token_type__TokenType_MinusEqual) {
    return ((const char *)({ __auto_type __sc157 = (str){ (const uint8_t *)"-=", sizeof("-=") - 1 }; str__ptr(&__sc157); }));
  }
  if (t == lexer__token_type__TokenType_StarEqual) {
    return ((const char *)({ __auto_type __sc158 = (str){ (const uint8_t *)"*=", sizeof("*=") - 1 }; str__ptr(&__sc158); }));
  }
  if (t == lexer__token_type__TokenType_SlashEqual) {
    return ((const char *)({ __auto_type __sc159 = (str){ (const uint8_t *)"/=", sizeof("/=") - 1 }; str__ptr(&__sc159); }));
  }
  if (t == lexer__token_type__TokenType_PercentEqual) {
    return ((const char *)({ __auto_type __sc160 = (str){ (const uint8_t *)"%=", sizeof("%=") - 1 }; str__ptr(&__sc160); }));
  }
  if (t == lexer__token_type__TokenType_AmpersandEqual) {
    return ((const char *)({ __auto_type __sc161 = (str){ (const uint8_t *)"&=", sizeof("&=") - 1 }; str__ptr(&__sc161); }));
  }
  if (t == lexer__token_type__TokenType_PipeEqual) {
    return ((const char *)({ __auto_type __sc162 = (str){ (const uint8_t *)"|=", sizeof("|=") - 1 }; str__ptr(&__sc162); }));
  }
  if (t == lexer__token_type__TokenType_CaretEqual) {
    return ((const char *)({ __auto_type __sc163 = (str){ (const uint8_t *)"^=", sizeof("^=") - 1 }; str__ptr(&__sc163); }));
  }
  if (t == lexer__token_type__TokenType_LeftShiftEqual) {
    return ((const char *)({ __auto_type __sc164 = (str){ (const uint8_t *)"<<=", sizeof("<<=") - 1 }; str__ptr(&__sc164); }));
  }
  if (t == lexer__token_type__TokenType_RightShiftEqual) {
    return ((const char *)({ __auto_type __sc165 = (str){ (const uint8_t *)">>=", sizeof(">>=") - 1 }; str__ptr(&__sc165); }));
  }
  if (t == lexer__token_type__TokenType_Bang) {
    return ((const char *)({ __auto_type __sc166 = (str){ (const uint8_t *)"!", sizeof("!") - 1 }; str__ptr(&__sc166); }));
  }
  if (t == lexer__token_type__TokenType_Tilde) {
    return ((const char *)({ __auto_type __sc167 = (str){ (const uint8_t *)"~", sizeof("~") - 1 }; str__ptr(&__sc167); }));
  }
  return ((const char *)({ __auto_type __sc168 = (str){ (const uint8_t *)"?", sizeof("?") - 1 }; str__ptr(&__sc168); }));
}

static __attribute__((unused)) const char *codegen__codegen__cg_arith_op_method(lexer__token_type__TokenType const op) {
  if (op == lexer__token_type__TokenType_Plus) {
    return ((const char *)({ __auto_type __sc169 = (str){ (const uint8_t *)"add", sizeof("add") - 1 }; str__ptr(&__sc169); }));
  }
  if (op == lexer__token_type__TokenType_Minus) {
    return ((const char *)({ __auto_type __sc170 = (str){ (const uint8_t *)"sub", sizeof("sub") - 1 }; str__ptr(&__sc170); }));
  }
  if (op == lexer__token_type__TokenType_Star) {
    return ((const char *)({ __auto_type __sc171 = (str){ (const uint8_t *)"mul", sizeof("mul") - 1 }; str__ptr(&__sc171); }));
  }
  if (op == lexer__token_type__TokenType_Slash) {
    return ((const char *)({ __auto_type __sc172 = (str){ (const uint8_t *)"div", sizeof("div") - 1 }; str__ptr(&__sc172); }));
  }
  if (op == lexer__token_type__TokenType_Percent) {
    return ((const char *)({ __auto_type __sc173 = (str){ (const uint8_t *)"rem", sizeof("rem") - 1 }; str__ptr(&__sc173); }));
  }
  return NULL;
}

static __attribute__((unused)) int32_t codegen__codegen__hex_val(uint8_t const ch) {
  if ((ch >= 48U) && (ch <= 57U)) {
    return ((int32_t)((uint8_t)((uint32_t)ch - (uint32_t)48U)));
  }
  if ((ch >= 97U) && (ch <= 102U)) {
    return ({ int32_t __sc_r; if (__builtin_add_overflow(((int32_t)((uint8_t)((uint32_t)ch - (uint32_t)97U))), 10, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
  }
  if ((ch >= 65U) && (ch <= 70U)) {
    return ({ int32_t __sc_r; if (__builtin_add_overflow(((int32_t)((uint8_t)((uint32_t)ch - (uint32_t)65U))), 10, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
  }
  return 0;
}

static __attribute__((unused)) int32_t codegen__codegen__utf8_encode(uint32_t const cp, uint8_t *const out) {
  if (cp < 0x80U) {
    (out[0] = ((uint8_t)cp));
    return 1;
  }
  if (cp < 0x800U) {
    (out[0] = ((uint8_t)(0xC0U | ({ uint32_t __sc174 = cp; int64_t __sc175 = (int64_t)(6U); if ((uint64_t)__sc175 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc174 >> __sc175); }))));
    (out[1] = ((uint8_t)(0x80U | (cp & 0x3FU))));
    return 2;
  }
  if (cp < 0x10000U) {
    (out[0] = ((uint8_t)(0xE0U | ({ uint32_t __sc176 = cp; int64_t __sc177 = (int64_t)(12U); if ((uint64_t)__sc177 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc176 >> __sc177); }))));
    (out[1] = ((uint8_t)(0x80U | (({ uint32_t __sc178 = cp; int64_t __sc179 = (int64_t)(6U); if ((uint64_t)__sc179 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc178 >> __sc179); }) & 0x3FU))));
    (out[2] = ((uint8_t)(0x80U | (cp & 0x3FU))));
    return 3;
  }
  (out[0] = ((uint8_t)(0xF0U | ({ uint32_t __sc180 = cp; int64_t __sc181 = (int64_t)(18U); if ((uint64_t)__sc181 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc180 >> __sc181); }))));
  (out[1] = ((uint8_t)(0x80U | (({ uint32_t __sc182 = cp; int64_t __sc183 = (int64_t)(12U); if ((uint64_t)__sc183 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc182 >> __sc183); }) & 0x3FU))));
  (out[2] = ((uint8_t)(0x80U | (({ uint32_t __sc184 = cp; int64_t __sc185 = (int64_t)(6U); if ((uint64_t)__sc185 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc184 >> __sc185); }) & 0x3FU))));
  (out[3] = ((uint8_t)(0x80U | (cp & 0x3FU))));
  return 4;
}

static __attribute__((unused)) lexer__token__Span codegen__codegen__raw_string_content(const uint8_t *const src, lexer__token__Span const s) {
  uint32_t i = (s.start + 1U);
  uint32_t h = 0U;
  while (src[((size_t)i)] == 35U) {
    (i = (i + 1U));
    (h = (h + 1U));
  }
  return (lexer__token__Span){ .start = (i + 1U), .end = ((s.end - 1U) - h) };
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_number(codegen__codegen__Codegen *const self, lexer__token__Span const s, lexer__token_type__TokenType const tt, ast__ast__BuiltinType const rb) {
  uint32_t sfx = s.end;
  const ast__ast__BuiltinType sb = ast__ast__ast_numeric_suffix(self->source, s.start, s.end, ((uint32_t *)(&sfx)));
  ast__ast__BuiltinType eb = sb;
  if (sb == ast__ast__BuiltinType_BT_COUNT) {
    if (tt == lexer__token_type__TokenType_IntegerLiteral) {
      (eb = rb);
    } else {
      (eb = ast__ast__BuiltinType_BT_COUNT);
    }
  }
  codegen__codegen__Buf256 buf = (codegen__codegen__Buf256){0};
  size_t n = 0ULL;
  uint32_t i = s.start;
  while ((i < sfx) && (n < 255ULL)) {
    if (self->source[((size_t)i)] != 95U) {
      (buf.b[n] = ((char)self->source[((size_t)i)]));
      (n = (n + 1ULL));
    }
    (i = (i + 1U));
  }
  (buf.b[n] = 0);
  const char *const bufp = ((const char *)(&buf.b[0]));
  if (((tt == lexer__token_type__TokenType_IntegerLiteral) && (n >= 2ULL)) && (buf.b[0] == 48)) {
    const char k = buf.b[1];
    if ((k == 98) || (k == 66)) {
      uint64_t v = 0ULL;
      size_t j = 2ULL;
      while (j < n) {
        (v = (({ uint64_t __sc186 = v; int64_t __sc187 = (int64_t)(1ULL); if ((uint64_t)__sc187 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc186 << __sc187)); }) | ((uint64_t)((uint8_t)((uint32_t)((uint8_t)buf.b[j]) - (uint32_t)48U)))));
        (j = (j + 1ULL));
      }
      if ((v > 0x7FFFFFFFFFFFFFFFULL) && (eb == ast__ast__BuiltinType_BT_COUNT)) {
        ({ String__Global *__sc188 = &(self->buf);
String__Global__push_u64(&(*__sc188), (uint64_t)(v));
String__Global__push_str(&(*__sc188), (str){ .ptr = (const uint8_t*)"ull", .len = sizeof("ull") - 1 });
});
      } else {
        ({ String__Global *__sc189 = &(self->buf);
String__Global__push_u64(&(*__sc189), (uint64_t)(v));
});
      }
    } else if ((k == 111) || (k == 79)) {
      ({ String__Global *__sc190 = &(self->buf);
String__Global__push_str(&(*__sc190), (str){ .ptr = (const uint8_t*)"0", .len = sizeof("0") - 1 });
String__Global__push_str(&(*__sc190), utils__errors__cstr(((const char *)(bufp + 2))));
});
    } else if ((k == 120) || (k == 88)) {
      codegen__codegen__Codegen__emit_cstr(self, bufp);
    } else {
      size_t z = 0ULL;
      while (((z + 1ULL) < n) && (buf.b[z] == 48)) {
        (z = (z + 1ULL));
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(bufp + z)));
      if ((eb == ast__ast__BuiltinType_BT_COUNT) && (strtoull(((const char *)(bufp + z)), NULL, 10) > 0x7FFFFFFFFFFFFFFFULL)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc191 = (str){ (const uint8_t *)"ull", sizeof("ull") - 1 }; str__ptr(&__sc191); })));
      }
    }
  } else if (((tt == lexer__token_type__TokenType_IntegerLiteral) && (eb == ast__ast__BuiltinType_BT_COUNT)) && (strtoull(bufp, NULL, 10) > 0x7FFFFFFFFFFFFFFFULL)) {
    codegen__codegen__Codegen__emit_cstr(self, bufp);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc192 = (str){ (const uint8_t *)"ull", sizeof("ull") - 1 }; str__ptr(&__sc192); })));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, bufp);
    const bool hexf = (((n > 2ULL) && (buf.b[0] == 48)) && ((((uint8_t)buf.b[1]) | 0x20U) == 120U));
    if (((((!hexf) && ((sb == ast__ast__BuiltinType_BT_F32) || (sb == ast__ast__BuiltinType_BT_F64))) && (memchr(bufp, 46, n) == NULL)) && (memchr(bufp, 101, n) == NULL)) && (memchr(bufp, 69, n) == NULL)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc193 = (str){ (const uint8_t *)".0", sizeof(".0") - 1 }; str__ptr(&__sc193); })));
    }
  }
  if ((eb == ast__ast__BuiltinType_BT_I64) || (eb == ast__ast__BuiltinType_BT_ISIZE)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc194 = (str){ (const uint8_t *)"LL", sizeof("LL") - 1 }; str__ptr(&__sc194); })));
  } else if (((eb == ast__ast__BuiltinType_BT_U8) || (eb == ast__ast__BuiltinType_BT_U16)) || (eb == ast__ast__BuiltinType_BT_U32)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc195 = (str){ (const uint8_t *)"U", sizeof("U") - 1 }; str__ptr(&__sc195); })));
  } else if ((eb == ast__ast__BuiltinType_BT_U64) || (eb == ast__ast__BuiltinType_BT_USIZE)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc196 = (str){ (const uint8_t *)"ULL", sizeof("ULL") - 1 }; str__ptr(&__sc196); })));
  } else if (eb == ast__ast__BuiltinType_BT_F32) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc197 = (str){ (const uint8_t *)"f", sizeof("f") - 1 }; str__ptr(&__sc197); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_reescaped(codegen__codegen__Codegen *const self, lexer__token__Span const s, bool const is_char) {
  const uint8_t *const src = self->source;
  int32_t q = 34;
  if (is_char) {
    (q = 39);
  }
  String__Global__push_byte(&self->buf, ((uint8_t)q));
  size_t i = ((size_t)(s.start + 1U));
  const size_t end = ((size_t)(s.end - 1U));
  while (i < end) {
    if (src[i] != 92U) {
      if (is_char && (src[i] >= 0x80U)) {
        const uint32_t cp = (({ uint32_t __sc198 = ((uint32_t)(src[i] & 0x1FU)); int64_t __sc199 = (int64_t)(6U); if ((uint64_t)__sc199 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc198 << __sc199)); }) | ((uint32_t)(src[(i + 1ULL)] & 0x3FU)));
        codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)(cp & 0xFFU)));
        (i = (i + 2ULL));
        continue;
      }
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)src[i])));
      (i = (i + 1ULL));
      continue;
    }
    (i = (i + 1ULL));
    if (i >= end) {
      break;
    }
    const uint8_t e = src[i];
    (i = (i + 1ULL));
    if ((((((e == 110U) || (e == 114U)) || (e == 116U)) || (e == 92U)) || (e == 34U)) || (e == 39U)) {
      String__Global__push_byte(&self->buf, 92U);
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)e)));
    } else if (e == 48U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc200 = (str){ (const uint8_t *)"\\000", sizeof("\\000") - 1 }; str__ptr(&__sc200); })));
    } else if (e == 120U) {
      const uint32_t v = ((uint32_t)(({ int32_t __sc201 = codegen__codegen__hex_val(src[i]); int64_t __sc202 = (int64_t)(4); if ((uint64_t)__sc202 >= 32) { __sc_panic("shift out of range"); } (int32_t)((uint32_t)((uint32_t)__sc201 << __sc202)); }) | codegen__codegen__hex_val(src[(i + 1ULL)])));
      (i = (i + 2ULL));
      codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)(v & 0xFFU)));
    } else if (e == 117U) {
      if ((i < end) && (src[i] == 123U)) {
        (i = (i + 1ULL));
      }
      uint32_t cp = 0U;
      while ((i < end) && (src[i] != 125U)) {
        (cp = (({ uint32_t __sc203 = cp; int64_t __sc204 = (int64_t)(4U); if ((uint64_t)__sc204 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc203 << __sc204)); }) | ((uint32_t)codegen__codegen__hex_val(src[i]))));
        (i = (i + 1ULL));
      }
      if ((i < end) && (src[i] == 125U)) {
        (i = (i + 1ULL));
      }
      if (is_char) {
        codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)(cp & 0xFFU)));
      } else {
        codegen__codegen__Bytes4 b = (codegen__codegen__Bytes4){0};
        const int32_t bn = codegen__codegen__utf8_encode(cp, ((uint8_t *)(&b.b[0])));
        for (int32_t kk = 0; kk < bn; kk++) {
          codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)((uint32_t)b.b[((size_t)kk)])));
        }
      }
    } else {
      String__Global__push_byte(&self->buf, 92U);
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)e)));
    }
  }
  String__Global__push_byte(&self->buf, ((uint8_t)q));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_raw_c_string(codegen__codegen__Codegen *const self, lexer__token__Span const content) {
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc205 = (str){ (const uint8_t *)"\"", sizeof("\"") - 1 }; str__ptr(&__sc205); })));
  uint32_t i = content.start;
  while (i < content.end) {
    const uint8_t b = self->source[((size_t)i)];
    if ((b == 34U) || (b == 92U)) {
      String__Global__push_byte(&self->buf, 92U);
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)b)));
    } else if (b == 10U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc206 = (str){ (const uint8_t *)"\\n", sizeof("\\n") - 1 }; str__ptr(&__sc206); })));
    } else if (b < 0x20U) {
      codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)((uint32_t)b)));
    } else {
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)b)));
    }
    (i = (i + 1U));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc207 = (str){ (const uint8_t *)"\"", sizeof("\"") - 1 }; str__ptr(&__sc207); })));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_format_builtin(codegen__codegen__Codegen *const self, uint32_t const id) {
  if (self->package == NULL) {
    return false;
  }
  const uint32_t callee = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.call.callee;
  const ast__ast__NodeKind ck = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee)->kind;
  int32_t kind = 0;
  uint32_t dst_recv = ast__ast__NODE_NONE;
  if (ck == ast__ast__NodeKind_NODE_MEMBER) {
    const uint32_t mem = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee)->as_data.member.member;
    const lexer__token__Span memname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mem)->as_data.name.text;
    if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), memname, ((const char *)({ __auto_type __sc208 = (str){ (const uint8_t *)"format_into", sizeof("format_into") - 1 }; str__ptr(&__sc208); })))) {
      (kind = 6);
      (dst_recv = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee)->as_data.member.object);
    }
    if (kind == 0) {
      return false;
    }
  } else if (ck == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee);
    if (((d.node == ast__ast__NODE_NONE) || (((size_t)d.module) >= codegen__codegen__Codegen__pkg_count(self))) || (!(*({ __auto_type __sc209 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc209, ((size_t)d.module)); })).prelude)) {
      return false;
    }
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_FUNCTION) {
      return false;
    }
    const uint32_t fnamenode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.function.name;
    const lexer__token__Span fnm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), fnamenode)->as_data.name.text;
    const uint8_t *const dsrc = codegen__codegen__Codegen__mod_src(self, d.module);
    if (codegen__codegen__span_is(dsrc, fnm, ((const char *)({ __auto_type __sc210 = (str){ (const uint8_t *)"format", sizeof("format") - 1 }; str__ptr(&__sc210); })))) {
      (kind = 1);
    } else if (codegen__codegen__span_is(dsrc, fnm, ((const char *)({ __auto_type __sc211 = (str){ (const uint8_t *)"print", sizeof("print") - 1 }; str__ptr(&__sc211); })))) {
      (kind = 2);
    } else if (codegen__codegen__span_is(dsrc, fnm, ((const char *)({ __auto_type __sc212 = (str){ (const uint8_t *)"println", sizeof("println") - 1 }; str__ptr(&__sc212); })))) {
      (kind = 3);
    } else if (codegen__codegen__span_is(dsrc, fnm, ((const char *)({ __auto_type __sc213 = (str){ (const uint8_t *)"eprint", sizeof("eprint") - 1 }; str__ptr(&__sc213); })))) {
      (kind = 4);
    } else if (codegen__codegen__span_is(dsrc, fnm, ((const char *)({ __auto_type __sc214 = (str){ (const uint8_t *)"eprintln", sizeof("eprintln") - 1 }; str__ptr(&__sc214); })))) {
      (kind = 5);
    }
    if (kind == 0) {
      return false;
    }
  } else {
    return false;
  }
  const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.call.args;
  const uint32_t *const aids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args);
  uint32_t const ti = 0U;
  bool is_raw = false;
  bool ok_lit = false;
  if (args.len > ti) {
    const uint32_t a0 = aids[((size_t)ti)];
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), a0)->kind == ast__ast__NodeKind_NODE_LITERAL) {
      const lexer__token_type__TokenType tt = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), a0)->as_data.literal.token_type;
      (is_raw = (tt == lexer__token_type__TokenType_RawStringLiteral));
      (ok_lit = ((tt == lexer__token_type__TokenType_StringLiteral) || is_raw));
    }
  }
  if (!ok_lit) {
    const lexer__token__Span sspan = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->span;
    utils__errors__Errors__emit(&self->errors, sspan.start, (sspan.end - sspan.start), ({ String__Global __sc215 = String__Global__new();
String__Global__push_str(&__sc215, (str){ (const uint8_t *)"codegen: format string must be a string literal", sizeof("codegen: format string must be a string literal") - 1 });
__sc215; }));
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc216 = String__Global__new();
String__Global__push_str(&__sc216, (str){ .ptr = (const uint8_t*)"format strings are parsed at compile time so placeholders can be checked", .len = sizeof("format strings are parsed at compile time so placeholders can be checked") - 1 });
__sc216; }));
    return true;
  }
  codegen__codegen__Buf32 ff = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&ff.b[0])), 32ULL);
  codegen__codegen__Buf64 fpb = (codegen__codegen__Buf64){0};
  const char *fp = ((const char *)(&ff.b[0]));
  if (kind == 6) {
    ({ String__Global *__sc217 = &(self->buf);
String__Global__push_str(&(*__sc217), (str){ .ptr = (const uint8_t*)"({ String__Global *", .len = sizeof("({ String__Global *") - 1 });
String__Global__push_str(&(*__sc217), utils__errors__cstr(((const char *)(&ff.b[0]))));
String__Global__push_str(&(*__sc217), (str){ .ptr = (const uint8_t*)" = &(", .len = sizeof(" = &(") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, dst_recv);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc218 = (str){ (const uint8_t *)");\n", sizeof(");\n") - 1 }; str__ptr(&__sc218); })));
    snprintf(((char *)(&fpb.b[0])), 64ULL, ((const char *)({ __auto_type __sc219 = (str){ (const uint8_t *)"(*%s)", sizeof("(*%s)") - 1 }; str__ptr(&__sc219); })), ((const char *)(&ff.b[0])));
    (fp = ((const char *)(&fpb.b[0])));
  } else {
    ({ String__Global *__sc220 = &(self->buf);
String__Global__push_str(&(*__sc220), (str){ .ptr = (const uint8_t*)"({ String__Global ", .len = sizeof("({ String__Global ") - 1 });
String__Global__push_str(&(*__sc220), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc220), (str){ .ptr = (const uint8_t*)" = String__Global__new();\n", .len = sizeof(" = String__Global__new();\n") - 1 });
});
  }
  const uint32_t a0 = aids[((size_t)ti)];
  const lexer__token__Span raw = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), a0)->as_data.literal.raw;
  const uint8_t *const src = self->source;
  const lexer__token__Span content = ({
    lexer__token__Span __sc221;
    if (is_raw) {
      __sc221 = codegen__codegen__raw_string_content(src, raw);
    } else {
      __sc221 = (lexer__token__Span){ .start = (raw.start + 1U), .end = (raw.end - 1U) };
    }
    __sc221;
  });
  size_t i = ((size_t)content.start);
  const size_t endc = ((size_t)content.end);
  size_t seg = i;
  uint32_t ai = (ti + 1U);
  while (i < endc) {
    if ((((src[i] == 123U) || (src[i] == 125U)) && ((i + 1ULL) < endc)) && (src[(i + 1ULL)] == src[i])) {
      (i = (i + 2ULL));
      continue;
    }
    if (src[i] == 123U) {
      codegen__codegen__FmtSpec sp = (codegen__codegen__FmtSpec){ .ty = 0, .align = 0, .fill = 0U, .width = 0, .prec = -1 };
      size_t j = (i + 1ULL);
      if ((j < endc) && (src[j] == 58U)) {
        (j = (j + 1ULL));
        if ((((j + 1ULL) < endc) && (((src[(j + 1ULL)] == 60U) || (src[(j + 1ULL)] == 62U)) || (src[(j + 1ULL)] == 94U))) && (src[j] != 125U)) {
          (sp.fill = src[j]);
          (sp.align = ((char)src[(j + 1ULL)]));
          (j = (j + 2ULL));
        } else if ((j < endc) && (((src[j] == 60U) || (src[j] == 62U)) || (src[j] == 94U))) {
          (sp.align = ((char)src[j]));
          (j = (j + 1ULL));
        }
        if (((j < endc) && (src[j] == 48U)) && (sp.fill == 0U)) {
          (sp.fill = 48U);
          (j = (j + 1ULL));
        }
        while (((j < endc) && (src[j] >= 48U)) && (src[j] <= 57U)) {
          (sp.width = ({ int32_t __sc_r; if (__builtin_add_overflow(({ int32_t __sc_r; if (__builtin_mul_overflow(sp.width, 10, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)src[j]), 48, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
          (j = (j + 1ULL));
        }
        if ((j < endc) && (src[j] == 46U)) {
          (j = (j + 1ULL));
          (sp.prec = 0);
          while (((j < endc) && (src[j] >= 48U)) && (src[j] <= 57U)) {
            (sp.prec = ({ int32_t __sc_r; if (__builtin_add_overflow(({ int32_t __sc_r; if (__builtin_mul_overflow(sp.prec, 10, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)src[j]), 48, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
            (j = (j + 1ULL));
          }
        }
        if ((j < endc) && (((src[j] == 120U) || (src[j] == 88U)) || (src[j] == 98U))) {
          (sp.ty = ((char)src[j]));
          (j = (j + 1ULL));
        }
      }
      if ((j < endc) && (src[j] == 125U)) {
        if (i > seg) {
          codegen__codegen__Codegen__emit_fmt_seg(self, fp, is_raw, seg, i);
        }
        if (ai >= args.len) {
          const lexer__token__Span sspan = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->span;
          utils__errors__Errors__emit(&self->errors, sspan.start, (sspan.end - sspan.start), ({ String__Global __sc222 = String__Global__new();
String__Global__push_str(&__sc222, (str){ (const uint8_t *)"codegen: more `{}` placeholders than arguments", sizeof("codegen: more `{}` placeholders than arguments") - 1 });
__sc222; }));
          utils__errors__Errors__note(&self->errors, ({ String__Global __sc223 = String__Global__new();
String__Global__push_str(&__sc223, (str){ (const uint8_t *)"add an argument for each placeholder or escape literal braces as '{{' and '}}'", sizeof("add an argument for each placeholder or escape literal braces as '{{' and '}}'") - 1 });
__sc223; }));
          ({ String__Global *__sc224 = &(self->buf);
String__Global__push_str(&(*__sc224), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc224), (str){ .ptr = (const uint8_t*)"; })", .len = sizeof("; })") - 1 });
});
          return true;
        }
        const uint32_t argid = aids[((size_t)ai)];
        if (!codegen__codegen__Codegen__emit_format_arg(self, fp, argid, (&sp))) {
          const lexer__token__Span aspan = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), argid)->span;
          const char *const msg = ({
            const char *__sc225;
            if (sp.ty != 0) {
              __sc225 = ((const char *)({ __auto_type __sc226 = (str){ (const uint8_t *)"codegen: `{:x}`/`{:X}`/`{:b}` formats require an integer argument", sizeof("codegen: `{:x}`/`{:X}`/`{:b}` formats require an integer argument") - 1 }; str__ptr(&__sc226); }));
            } else if (sp.prec >= 0) {
              __sc225 = ((const char *)({ __auto_type __sc227 = (str){ (const uint8_t *)"codegen: `{:.N}` precision requires a float argument", sizeof("codegen: `{:.N}` precision requires a float argument") - 1 }; str__ptr(&__sc227); }));
            } else {
              __sc225 = ((const char *)({ __auto_type __sc228 = (str){ (const uint8_t *)"codegen: argument is not directly formattable (call its .fmt())", sizeof("codegen: argument is not directly formattable (call its .fmt())") - 1 }; str__ptr(&__sc228); }));
            }
            __sc225;
          });
          utils__errors__Errors__emit(&self->errors, aspan.start, (aspan.end - aspan.start), ({ String__Global __sc229 = String__Global__new();
String__Global__push_str(&__sc229, utils__errors__cstr(msg));
__sc229; }));
          if ((sp.ty == 0) && (sp.prec < 0)) {
            utils__errors__Errors__note(&self->errors, ({ String__Global __sc230 = String__Global__new();
String__Global__push_str(&__sc230, (str){ .ptr = (const uint8_t*)"implement Format for this type or pass a value that already formats directly", .len = sizeof("implement Format for this type or pass a value that already formats directly") - 1 });
__sc230; }));
          }
        }
        (ai = (ai + 1U));
        (i = (j + 1ULL));
        (seg = i);
        continue;
      }
    }
    (i = (i + 1ULL));
  }
  if (endc > seg) {
    codegen__codegen__Codegen__emit_fmt_seg(self, fp, is_raw, seg, endc);
  }
  if (ai < args.len) {
    const lexer__token__Span sspan = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->span;
    utils__errors__Errors__emit(&self->errors, sspan.start, (sspan.end - sspan.start), ({ String__Global __sc231 = String__Global__new();
String__Global__push_str(&__sc231, (str){ (const uint8_t *)"codegen: more arguments than `{}` placeholders", sizeof("codegen: more arguments than `{}` placeholders") - 1 });
__sc231; }));
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc232 = String__Global__new();
String__Global__push_str(&__sc232, (str){ (const uint8_t *)"remove the extra argument or add a matching '{}' placeholder", sizeof("remove the extra argument or add a matching '{}' placeholder") - 1 });
__sc232; }));
  }
  if ((kind == 3) || (kind == 5)) {
    ({ String__Global *__sc233 = &(self->buf);
String__Global__push_str(&(*__sc233), (str){ .ptr = (const uint8_t*)"String__Global__push_byte(&", .len = sizeof("String__Global__push_byte(&") - 1 });
String__Global__push_str(&(*__sc233), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc233), (str){ .ptr = (const uint8_t*)", 10);\n", .len = sizeof(", 10);\n") - 1 });
});
  }
  if (kind == 6) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc234 = (str){ (const uint8_t *)"})", sizeof("})") - 1 }; str__ptr(&__sc234); })));
  } else if (kind == 1) {
    ({ String__Global *__sc235 = &(self->buf);
String__Global__push_str(&(*__sc235), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc235), (str){ .ptr = (const uint8_t*)"; })", .len = sizeof("; })") - 1 });
});
  } else if (kind >= 4) {
    ({ String__Global *__sc236 = &(self->buf);
String__Global__push_str(&(*__sc236), (str){ .ptr = (const uint8_t*)"String__Global__eprint(&", .len = sizeof("String__Global__eprint(&") - 1 });
String__Global__push_str(&(*__sc236), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc236), (str){ .ptr = (const uint8_t*)"); String__Global__free(&", .len = sizeof("); String__Global__free(&") - 1 });
String__Global__push_str(&(*__sc236), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc236), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
  } else {
    ({ String__Global *__sc237 = &(self->buf);
String__Global__push_str(&(*__sc237), (str){ .ptr = (const uint8_t*)"String__Global__print(&", .len = sizeof("String__Global__print(&") - 1 });
String__Global__push_str(&(*__sc237), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc237), (str){ .ptr = (const uint8_t*)"); String__Global__free(&", .len = sizeof("); String__Global__free(&") - 1 });
String__Global__push_str(&(*__sc237), utils__errors__cstr(fp));
String__Global__push_str(&(*__sc237), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
  }
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_assert_builtin(codegen__codegen__Codegen *const self, uint32_t const id) {
  const int32_t kind = codegen__codegen__Codegen__cg_assert_kind(self, id);
  if (kind == 0) {
    return false;
  }
  const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.call.args;
  const uint32_t *const aids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args);
  const lexer__token__Span sspan = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->span;
  const uint32_t line = codegen__codegen__Codegen__cg_line_of(self, sspan.start);
  const char *const file = codegen__codegen__Codegen__cg_file(self);
  if (kind == 1) {
    const uint32_t a0 = aids[0ULL];
    const lexer__token__Span cs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), a0)->span;
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc238 = (str){ (const uint8_t *)"({ if (!(", sizeof("({ if (!(") - 1 }; str__ptr(&__sc238); })));
    codegen__codegen__Codegen__emit_expr(self, a0);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc239 = (str){ (const uint8_t *)")) { ", sizeof(")) { ") - 1 }; str__ptr(&__sc239); })));
    if (args.len == 2U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc240 = (str){ (const uint8_t *)"const str __scm = ", sizeof("const str __scm = ") - 1 }; str__ptr(&__sc240); })));
      codegen__codegen__Codegen__emit_expr(self, aids[1ULL]);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc241 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc241); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc242 = (str){ (const uint8_t *)"fprintf(stderr, \"assertion failed: `", sizeof("fprintf(stderr, \"assertion failed: `") - 1 }; str__ptr(&__sc242); })));
    codegen__codegen__Codegen__emit_pct_escaped(self, (self->source + ((size_t)cs.start)), ((size_t)(cs.end - cs.start)));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc243 = (str){ (const uint8_t *)"`", sizeof("`") - 1 }; str__ptr(&__sc243); })));
    if (args.len == 2U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc244 = (str){ (const uint8_t *)": %.*s", sizeof(": %.*s") - 1 }; str__ptr(&__sc244); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc245 = (str){ (const uint8_t *)"\\n  at ", sizeof("\\n  at ") - 1 }; str__ptr(&__sc245); })));
    codegen__codegen__Codegen__emit_pct_escaped(self, ((const uint8_t *)file), strlen(file));
    ({ String__Global *__sc246 = &(self->buf);
String__Global__push_str(&(*__sc246), (str){ .ptr = (const uint8_t*)":", .len = sizeof(":") - 1 });
String__Global__push_u64(&(*__sc246), (uint64_t)(line));
String__Global__push_str(&(*__sc246), (str){ .ptr = (const uint8_t*)"\\n\"", .len = sizeof("\\n\"") - 1 });
});
    if (args.len == 2U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc247 = (str){ (const uint8_t *)", (int)__scm.len, (const char *)__scm.ptr", sizeof(", (int)__scm.len, (const char *)__scm.ptr") - 1 }; str__ptr(&__sc247); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc248 = (str){ (const uint8_t *)"); abort(); } })", sizeof("); abort(); } })") - 1 }; str__ptr(&__sc248); })));
    return true;
  }
  const uint32_t a0 = aids[0ULL];
  const uint32_t a1 = aids[1ULL];
  const lexer__token__Span ls = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), a0)->span;
  const lexer__token__Span rs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), a1)->span;
  const uint32_t lt = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), a0));
  const int32_t depth = codegen__codegen__Codegen__cg_ref_depth(self, lt);
  const uint32_t base = codegen__codegen__Codegen__strip_ptr(self, lt);
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, base));
  codegen__codegen__Buf32 lb = (codegen__codegen__Buf32){0};
  codegen__codegen__Buf32 rb = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&lb.b[0])), 32ULL);
  codegen__codegen__Codegen__fresh(self, ((char *)(&rb.b[0])), 32ULL);
  const char *const lp = ((const char *)(&lb.b[0]));
  const char *const rp = ((const char *)(&rb.b[0]));
  codegen__codegen__Buf64 lacc = (codegen__codegen__Buf64){0};
  codegen__codegen__Buf64 racc = (codegen__codegen__Buf64){0};
  if (depth != 0) {
    snprintf(((char *)(&lacc.b[0])), 48ULL, ((const char *)({ __auto_type __sc249 = (str){ (const uint8_t *)"(*%s)", sizeof("(*%s)") - 1 }; str__ptr(&__sc249); })), lp);
    snprintf(((char *)(&racc.b[0])), 48ULL, ((const char *)({ __auto_type __sc250 = (str){ (const uint8_t *)"(*%s)", sizeof("(*%s)") - 1 }; str__ptr(&__sc250); })), rp);
  } else {
    snprintf(((char *)(&lacc.b[0])), 48ULL, ((const char *)({ __auto_type __sc251 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc251); })), lp);
    snprintf(((char *)(&racc.b[0])), 48ULL, ((const char *)({ __auto_type __sc252 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc252); })), rp);
  }
  const char *const laccp = ((const char *)(&lacc.b[0]));
  const char *const raccp = ((const char *)(&racc.b[0]));
  codegen__codegen__Buf256 ldecl = (codegen__codegen__Buf256){0};
  codegen__codegen__Buf256 rdecl = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__render_type_id(self, lt, lp, ((char *)(&ldecl.b[0])), 256ULL);
  codegen__codegen__Codegen__render_type_id(self, lt, rp, ((char *)(&rdecl.b[0])), 256ULL);
  ({ String__Global *__sc253 = &(self->buf);
String__Global__push_str(&(*__sc253), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc253), utils__errors__cstr(((const char *)(&ldecl.b[0]))));
String__Global__push_str(&(*__sc253), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, a0);
  ({ String__Global *__sc254 = &(self->buf);
String__Global__push_str(&(*__sc254), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc254), utils__errors__cstr(((const char *)(&rdecl.b[0]))));
String__Global__push_str(&(*__sc254), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, a1);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc255 = (str){ (const uint8_t *)"; if (", sizeof("; if (") - 1 }; str__ptr(&__sc255); })));
  if (kind == 2) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc256 = (str){ (const uint8_t *)"!(", sizeof("!(") - 1 }; str__ptr(&__sc256); })));
  }
  if (codegen__codegen__Codegen__cg_struct_name_is(self, (&y), ((const char *)({ __auto_type __sc257 = (str){ (const uint8_t *)"str", sizeof("str") - 1 }; str__ptr(&__sc257); })))) {
    ({ String__Global *__sc258 = &(self->buf);
String__Global__push_str(&(*__sc258), utils__errors__cstr(laccp));
String__Global__push_str(&(*__sc258), (str){ .ptr = (const uint8_t*)".len == ", .len = sizeof(".len == ") - 1 });
String__Global__push_str(&(*__sc258), utils__errors__cstr(raccp));
String__Global__push_str(&(*__sc258), (str){ .ptr = (const uint8_t*)".len && (", .len = sizeof(".len && (") - 1 });
String__Global__push_str(&(*__sc258), utils__errors__cstr(laccp));
String__Global__push_str(&(*__sc258), (str){ .ptr = (const uint8_t*)".len == 0 || memcmp(", .len = sizeof(".len == 0 || memcmp(") - 1 });
String__Global__push_str(&(*__sc258), utils__errors__cstr(laccp));
String__Global__push_str(&(*__sc258), (str){ .ptr = (const uint8_t*)".ptr, ", .len = sizeof(".ptr, ") - 1 });
String__Global__push_str(&(*__sc258), utils__errors__cstr(raccp));
String__Global__push_str(&(*__sc258), (str){ .ptr = (const uint8_t*)".ptr, ", .len = sizeof(".ptr, ") - 1 });
String__Global__push_str(&(*__sc258), utils__errors__cstr(laccp));
String__Global__push_str(&(*__sc258), (str){ .ptr = (const uint8_t*)".len) == 0)", .len = sizeof(".len) == 0)") - 1 });
});
  } else if (((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_INSTANCE)) || ((y.kind == ast__ast__TypeKind_TYPE_ENUM) && codegen__codegen__Codegen__aggregate_has_payload_in(self, y.module, y.as_data.decl))) {
    uint16_t om = y.module;
    uint32_t od = y.as_data.decl;
    if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
      (om = it.module);
      (od = it.decl);
    }
    const ast__ast__DefId eq = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc259 = (str){ (const uint8_t *)"eq", sizeof("eq") - 1 }; str__ptr(&__sc259); })));
    codegen__codegen__Codegen__emit_op_method(self, y, om, od, eq);
    ({ String__Global *__sc260 = &(self->buf);
String__Global__push_str(&(*__sc260), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc260), utils__errors__cstr(laccp));
String__Global__push_str(&(*__sc260), (str){ .ptr = (const uint8_t*)", &", .len = sizeof(", &") - 1 });
String__Global__push_str(&(*__sc260), utils__errors__cstr(raccp));
String__Global__push_str(&(*__sc260), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
  } else {
    ({ String__Global *__sc261 = &(self->buf);
String__Global__push_str(&(*__sc261), utils__errors__cstr(laccp));
String__Global__push_str(&(*__sc261), (str){ .ptr = (const uint8_t*)" == ", .len = sizeof(" == ") - 1 });
String__Global__push_str(&(*__sc261), utils__errors__cstr(raccp));
});
  }
  if (kind == 2) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc262 = (str){ (const uint8_t *)")) {\n", sizeof(")) {\n") - 1 }; str__ptr(&__sc262); })));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc263 = (str){ (const uint8_t *)") {\n", sizeof(") {\n") - 1 }; str__ptr(&__sc263); })));
  }
  (self->depth = (self->depth + 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc264 = (str){ (const uint8_t *)"fprintf(stderr, \"assertion failed: `", sizeof("fprintf(stderr, \"assertion failed: `") - 1 }; str__ptr(&__sc264); })));
  codegen__codegen__Codegen__emit_pct_escaped(self, (self->source + ((size_t)ls.start)), ((size_t)(ls.end - ls.start)));
  if (kind == 2) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc265 = (str){ (const uint8_t *)" == ", sizeof(" == ") - 1 }; str__ptr(&__sc265); })));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc266 = (str){ (const uint8_t *)" != ", sizeof(" != ") - 1 }; str__ptr(&__sc266); })));
  }
  codegen__codegen__Codegen__emit_pct_escaped(self, (self->source + ((size_t)rs.start)), ((size_t)(rs.end - rs.start)));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc267 = (str){ (const uint8_t *)"`\\n\");\n", sizeof("`\\n\");\n") - 1 }; str__ptr(&__sc267); })));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_assert_value_line(self, ((const char *)({ __auto_type __sc268 = (str){ (const uint8_t *)"left: ", sizeof("left: ") - 1 }; str__ptr(&__sc268); })), laccp, y, base);
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_assert_value_line(self, ((const char *)({ __auto_type __sc269 = (str){ (const uint8_t *)"right:", sizeof("right:") - 1 }; str__ptr(&__sc269); })), raccp, y, base);
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc270 = (str){ (const uint8_t *)"fprintf(stderr, \"  at ", sizeof("fprintf(stderr, \"  at ") - 1 }; str__ptr(&__sc270); })));
  codegen__codegen__Codegen__emit_pct_escaped(self, ((const uint8_t *)file), strlen(file));
  ({ String__Global *__sc271 = &(self->buf);
String__Global__push_str(&(*__sc271), (str){ .ptr = (const uint8_t*)":", .len = sizeof(":") - 1 });
String__Global__push_u64(&(*__sc271), (uint64_t)(line));
String__Global__push_str(&(*__sc271), (str){ .ptr = (const uint8_t*)"\\n\");\n", .len = sizeof("\\n\");\n") - 1 });
});
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc272 = (str){ (const uint8_t *)"abort();\n", sizeof("abort();\n") - 1 }; str__ptr(&__sc272); })));
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc273 = (str){ (const uint8_t *)"}", sizeof("}") - 1 }; str__ptr(&__sc273); })));
  for (int32_t i = 0; i < 2; i++) {
    const uint32_t ai = ({
      uint32_t __sc274;
      if (i == 0) {
        __sc274 = a0;
      } else {
        __sc274 = a1;
      }
      __sc274;
    });
    if (((!codegen__codegen__Codegen__is_lvalue(self, ai)) && (depth == 0)) && codegen__codegen__Codegen__cg_type_is_free(self, base)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc275 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc275); })));
      codegen__codegen__Codegen__emit_free_target(self, base);
      const char *const nmp = ({
        const char *__sc276;
        if (i == 0) {
          __sc276 = lp;
        } else {
          __sc276 = rp;
        }
        __sc276;
      });
      ({ String__Global *__sc277 = &(self->buf);
String__Global__push_str(&(*__sc277), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc277), utils__errors__cstr(nmp));
String__Global__push_str(&(*__sc277), (str){ .ptr = (const uint8_t*)");", .len = sizeof(");") - 1 });
});
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc278 = (str){ (const uint8_t *)" })", sizeof(" })") - 1 }; str__ptr(&__sc278); })));
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cb_known_callee(codegen__codegen__Codegen *const self, uint32_t const arg, ast__ast__DefId *const out, bool *const is_closure) {
  const ast__ast__NodeKind ak = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), arg)->kind;
  if (ak == ast__ast__NodeKind_NODE_CLOSURE) {
    ((*out) = (ast__ast__DefId){ .module = codegen__codegen__Codegen__cur_module(self), .node = arg });
    ((*is_closure) = true);
    return true;
  }
  if (ak == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), arg);
    if (d.node != ast__ast__NODE_NONE) {
      const ast__ast__NodeKind dnk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->kind;
      const uint32_t dbody = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.function.body;
      if ((dnk == ast__ast__NodeKind_NODE_FUNCTION) && (dbody != ast__ast__NODE_NONE)) {
        ((*out) = d);
        ((*is_closure) = false);
        return true;
      }
    }
  }
  return false;
}

static __attribute__((unused)) void codegen__codegen__Codegen__cb_spec_name(codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, ast__ast__DefId const callee, bool const is_closure, char *const out, size_t const cap) {
  codegen__codegen__Codegen__function_name(self, fn2.node, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, out, cap, true);
  const size_t at0 = strlen(out);
  const size_t at = codegen__codegen__bappend(out, cap, at0, ((const char *)({ __auto_type __sc279 = (str){ (const uint8_t *)"__cb_", sizeof("__cb_") - 1 }; str__ptr(&__sc279); })));
  codegen__codegen__Buf200 sym = (codegen__codegen__Buf200){0};
  if (is_closure) {
    codegen__codegen__Codegen__closure_name(self, callee.node, ((char *)(&sym.b[0])), 200ULL);
  } else {
    const uint32_t cn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, callee.module))), callee.node)->as_data.function.name;
    codegen__codegen__Codegen__render_qualified(self, callee.module, cn, ((char *)(&sym.b[0])), 200ULL);
  }
  codegen__codegen__bappend(out, cap, at, ((const char *)(&sym.b[0])));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cb_single_callback_param(const codegen__codegen__Codegen *const self, uint32_t const fnNode, uint32_t *const cbidx, uint32_t *const param) {
  const ast__ast__NodeList ps = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fnNode)->as_data.function.params;
  const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ps);
  int32_t found = -1;
  for (uint32_t i = 0U; i < ps.len; i++) {
    const uint32_t tn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pids[((size_t)i)])->as_data.parameter.ty;
    if ((tn != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), tn)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE)) {
      if (found >= 0) {
        return false;
      }
      (found = ((int32_t)i));
    }
  }
  if (found < 0) {
    return false;
  }
  ((*cbidx) = ((uint32_t)found));
  ((*param) = pids[((size_t)found)]);
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__param_only_callee(const codegen__codegen__Codegen *const self, uint32_t const param) {
  uint32_t uses = 0U;
  uint32_t callees = 0U;
  const size_t nn = Vector__ast__ast__Node__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).nodes);
  uint32_t i = 0U;
  while (((size_t)i) < nn) {
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), i)->kind;
    if (nk == ast__ast__NodeKind_NODE_IDENTIFIER) {
      const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), i);
      if ((d.module == codegen__codegen__Codegen__cur_module(self)) && (d.node == param)) {
        (uses = (uses + 1U));
      }
    } else if (nk == ast__ast__NodeKind_NODE_CALL) {
      const uint32_t ce = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), i)->as_data.call.callee;
      if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ce)->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
        const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ce);
        if ((d.module == codegen__codegen__Codegen__cur_module(self)) && (d.node == param)) {
          (callees = (callees + 1U));
        }
      }
    }
    (i = (i + 1U));
  }
  return (uses == callees);
}

static __attribute__((unused)) void codegen__codegen__Codegen__cb_record(codegen__codegen__Codegen *const self, ast__ast__DefId const fn2, uint32_t const param, uint32_t const cbidx, ast__ast__DefId const callee, bool const is_closure) {
  for (int32_t i = 0; i < self->n_cb_insts; i++) {
    const codegen__codegen__CgCbInst ci = self->cb_insts[((size_t)i)];
    if (((((ci.func.node == fn2.node) && (ci.func.module == fn2.module)) && (ci.callee.node == callee.node)) && (ci.callee.module == callee.module)) && (ci.callee_closure == is_closure)) {
      return;
    }
  }
  if (self->n_cb_insts >= 256) {
    return;
  }
  (self->cb_insts[((size_t)self->n_cb_insts)].func = fn2);
  (self->cb_insts[((size_t)self->n_cb_insts)].param = param);
  (self->cb_insts[((size_t)self->n_cb_insts)].cbidx = cbidx);
  (self->cb_insts[((size_t)self->n_cb_insts)].callee = callee);
  (self->cb_insts[((size_t)self->n_cb_insts)].callee_closure = is_closure);
  (self->n_cb_insts = ({ int32_t __sc_r; if (__builtin_add_overflow(self->n_cb_insts, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
}

static __attribute__((unused)) void codegen__codegen__Codegen__cb_keep(codegen__codegen__Codegen *const self, uint32_t const fn2) {
  for (int32_t i = 0; i < self->n_cb_keep; i++) {
    if (self->cb_keep_fns[((size_t)i)] == fn2) {
      return;
    }
  }
  if (self->n_cb_keep < 128) {
    (self->cb_keep_fns[((size_t)self->n_cb_keep)] = fn2);
    (self->n_cb_keep = ({ int32_t __sc_r; if (__builtin_add_overflow(self->n_cb_keep, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_decl_name_node(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const decl) {
  const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), decl);
  if (dn->kind == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
    return dn->as_data.type_alias.name;
  }
  return dn->as_data.aggregate.name;
}

static __attribute__((unused)) const char *codegen__codegen__Codegen__cg_conv_lit(const codegen__codegen__Codegen *const self, uint16_t const m, lexer__token__Span const name) {
  if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, m), name, ((const char *)({ __auto_type __sc280 = (str){ (const uint8_t *)"from", sizeof("from") - 1 }; str__ptr(&__sc280); })))) {
    return ((const char *)({ __auto_type __sc281 = (str){ (const uint8_t *)"from", sizeof("from") - 1 }; str__ptr(&__sc281); }));
  }
  if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, m), name, ((const char *)({ __auto_type __sc282 = (str){ (const uint8_t *)"try_from", sizeof("try_from") - 1 }; str__ptr(&__sc282); })))) {
    return ((const char *)({ __auto_type __sc283 = (str){ (const uint8_t *)"try_from", sizeof("try_from") - 1 }; str__ptr(&__sc283); }));
  }
  return NULL;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_deref_hop(codegen__codegen__Codegen *const self, uint32_t const recv, ast__ast__DefId const md) {
  const ast__ast__Ty b = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, recv)));
  if (b.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), b.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc284 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc284); })));
  } else if ((b.kind == ast__ast__TypeKind_TYPE_STRUCT) || (b.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, md.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_ident_mod(self, b.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, b.module))), b.as_data.decl)->as_data.aggregate.name);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc285 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc285); })));
  }
  codegen__codegen__Codegen__emit_ident_mod(self, md.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.name);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc286 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc286); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_call_args(codegen__codegen__Codegen *const self, ast__ast__NodeList const args) {
  for (uint32_t i = 0U; i < args.len; i++) {
    if (i != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc287 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc287); })));
    }
    codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_call_path(codegen__codegen__Codegen *const self, uint32_t const id, ast__ast__Node const n, ast__ast__Node const callee) {
  const ast__ast__NodeList args = n.as_data.call.args;
  const uint32_t member = callee.as_data.member.member;
  const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), member);
  if (md.node == ast__ast__NODE_NONE) {
    return false;
  }
  const ast__ast__NodeKind mdk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->kind;
  if (mdk == ast__ast__NodeKind_NODE_VARIANT) {
    codegen__codegen__Codegen__emit_variant_construct(self, md, args, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args), ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
    return true;
  }
  if (mdk != ast__ast__NodeKind_NODE_FUNCTION) {
    return false;
  }
  codegen__codegen__Buf256 ov = (codegen__codegen__Buf256){0};
  const bool ovr = codegen__codegen__Codegen__cg_symbol_override(self, md.module, md.node, ((char *)(&ov.b[0])), 160ULL);
  if (ovr || ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.is_extern) {
    if (ovr) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&ov.b[0])));
    } else {
      codegen__codegen__Codegen__emit_ident_mod(self, md.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.name);
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc288 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc288); })));
    codegen__codegen__Codegen__emit_call_args(self, args);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc289 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc289); })));
    return true;
  }
  const uint32_t base_t = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), callee.as_data.member.object);
  const ast__ast__DefId td = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee.as_data.member.object);
  ast__ast__DefId emd = md;
  uint32_t param_tgt = ast__ast__TYPE_NONE;
  if ((td.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, td.module))), td.node)->kind == ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
    const uint32_t r = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__intern_type(&((*codegen__codegen__Codegen__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_GENERIC, .module = td.module, .as_data = (ast__ast__TyAs){ .decl = td.node } }));
    if (codegen__codegen__Codegen__type_is_concrete(self, r)) {
      (param_tgt = r);
    }
  } else if ((td.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, td.module))), td.node)->kind == ast__ast__NodeKind_NODE_INTERFACE)) {
    const uint32_t r = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
    if (codegen__codegen__Codegen__type_is_concrete(self, r)) {
      (param_tgt = r);
    }
  }
  if ((base_t != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, base_t)->kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
    codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), codegen__codegen__Codegen__type_at(self, base_t)->as_data.inst), ((char *)(&inm.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc290 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc290); })));
  } else if (((param_tgt != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, param_tgt)->kind == ast__ast__TypeKind_TYPE_BUILTIN)) && (self->package != NULL)) {
    const ast__ast__BuiltinType bt = codegen__codegen__Codegen__type_at(self, param_tgt)->as_data.builtin;
    const uint32_t bd = module__loader__Package__builtin_decl(&((*self->package)), bt);
    if (bd != ast__ast__NODE_NONE) {
      const ast__ast__DefId cm = codegen__codegen__Codegen__cg_find_method(self, (*self->package).core_module, bd, self->source, codegen__codegen__Codegen__name_span(self, member));
      if (cm.node != ast__ast__NODE_NONE) {
        (emd = cm);
      }
    }
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, emd.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, codegen__codegen__builtin_name(bt));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc291 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc291); })));
  } else if (param_tgt != ast__ast__TYPE_NONE) {
    const ast__ast__Ty rb = (*codegen__codegen__Codegen__type_at(self, param_tgt));
    uint16_t omod = 0U;
    uint32_t odecl = ast__ast__NODE_NONE;
    if (rb.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), rb.as_data.inst));
      (omod = it.module);
      (odecl = it.decl);
    } else {
      (omod = rb.module);
      (odecl = rb.as_data.decl);
    }
    const ast__ast__DefId cm = codegen__codegen__Codegen__cg_find_method(self, omod, odecl, self->source, codegen__codegen__Codegen__name_span(self, member));
    if (cm.node != ast__ast__NODE_NONE) {
      (emd = cm);
    }
    if (rb.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), rb.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
      codegen__codegen__Codegen__emit_paste(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc292 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc292); })));
    } else if ((rb.kind == ast__ast__TypeKind_TYPE_STRUCT) || (rb.kind == ast__ast__TypeKind_TYPE_ENUM)) {
      codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
      codegen__codegen__Codegen__render_modpfx(self, emd.module, ((char *)(&pfx.b[0])), 64ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
      codegen__codegen__Codegen__emit_ident_mod(self, omod, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, omod))), odecl)->as_data.aggregate.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc293 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc293); })));
    }
  } else if ((self->macro_mode && (td.node != ast__ast__NODE_NONE)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, td.module))), td.node)->kind == ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
    codegen__codegen__Buf64 pp = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc294 = (str){ (const uint8_t *)"_SCM_", sizeof("_SCM_") - 1 }; str__ptr(&__sc294); })));
    codegen__codegen__Codegen__render_macro_param(self, td.module, td.node, ((char *)(&pp.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pp.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc295 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc295); })));
  } else {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, md.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    if (td.node != ast__ast__NODE_NONE) {
      int32_t bb = -1;
      if (self->package != NULL) {
        (bb = module__loader__Package__builtin_of_decl(&((*self->package)), td.module, td.node));
      }
      if (bb >= 0) {
        codegen__codegen__Codegen__emit_cstr(self, codegen__codegen__builtin_name(((ast__ast__BuiltinType)bb)));
      } else {
        codegen__codegen__Codegen__emit_ident_mod(self, td.module, codegen__codegen__Codegen__cg_decl_name_node(self, td.module, td.node));
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc296 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc296); })));
    }
  }
  codegen__codegen__Codegen__emit_ident_mod(self, emd.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, emd.module))), emd.node)->as_data.function.name);
  if ((td.node != ast__ast__NODE_NONE) && (args.len != 0U)) {
    codegen__codegen__Buf256 sfx = (codegen__codegen__Buf256){0};
    const uint32_t a0t = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[0]);
    codegen__codegen__Codegen__cg_conv_suffix(self, td, codegen__codegen__Codegen__cg_conv_lit(self, codegen__codegen__Codegen__cur_module(self), codegen__codegen__Codegen__name_span(self, member)), a0t, ((char *)(&sfx.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&sfx.b[0])));
  }
  codegen__codegen__Codegen__emit_method_targs(self, id, emd);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc297 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc297); })));
  codegen__codegen__Codegen__emit_call_args(self, args);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc298 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc298); })));
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_call_method(codegen__codegen__Codegen *const self, uint32_t const id, ast__ast__Node const n, ast__ast__Node const callee) {
  const ast__ast__NodeList args = n.as_data.call.args;
  const uint32_t member = callee.as_data.member.member;
  const uint32_t obj = callee.as_data.member.object;
  ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), member);
  if ((md.node == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->kind != ast__ast__NodeKind_NODE_FUNCTION)) {
    return false;
  }
  const lexer__token__Span memn = codegen__codegen__Codegen__name_span(self, member);
  const lexer__token__Span mdn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.name)->as_data.name.text;
  const bool conv = ((codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), memn, ((const char *)({ __auto_type __sc299 = (str){ (const uint8_t *)"into", sizeof("into") - 1 }; str__ptr(&__sc299); }))) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, md.module), mdn, ((const char *)({ __auto_type __sc300 = (str){ (const uint8_t *)"from", sizeof("from") - 1 }; str__ptr(&__sc300); })))) || (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), memn, ((const char *)({ __auto_type __sc301 = (str){ (const uint8_t *)"try_into", sizeof("try_into") - 1 }; str__ptr(&__sc301); }))) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, md.module), mdn, ((const char *)({ __auto_type __sc302 = (str){ (const uint8_t *)"try_from", sizeof("try_from") - 1 }; str__ptr(&__sc302); })))));
  if (conv) {
    uint32_t tgt = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
    if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, md.module), mdn, ((const char *)({ __auto_type __sc303 = (str){ (const uint8_t *)"try_from", sizeof("try_from") - 1 }; str__ptr(&__sc303); }))) && (codegen__codegen__Codegen__type_at(self, tgt)->kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
      (tgt = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), codegen__codegen__Codegen__type_at(self, tgt)->as_data.inst)->args[0]));
    }
    const ast__ast__Ty tb = (*codegen__codegen__Codegen__type_at(self, tgt));
    ast__ast__DefId ct = (ast__ast__DefId){ .module = tb.module, .node = tb.as_data.decl };
    if (tb.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), tb.as_data.inst));
      (ct = (ast__ast__DefId){ .module = it.module, .node = it.decl });
      codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), tb.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
      codegen__codegen__Codegen__emit_paste(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc304 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc304); })));
    } else {
      codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
      codegen__codegen__Codegen__render_modpfx(self, md.module, ((char *)(&pfx.b[0])), 64ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
      codegen__codegen__Codegen__emit_ident_mod(self, tb.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, tb.module))), tb.as_data.decl)->as_data.aggregate.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc305 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc305); })));
    }
    codegen__codegen__Codegen__emit_ident_mod(self, md.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.name);
    codegen__codegen__Buf256 sfx = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__cg_conv_suffix(self, ct, codegen__codegen__Codegen__cg_conv_lit(self, md.module, mdn), ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), obj), ((char *)(&sfx.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&sfx.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc306 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc306); })));
    codegen__codegen__Codegen__emit_expr(self, obj);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc307 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc307); })));
    return true;
  }
  const uint32_t obj_t = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), obj);
  const uint32_t pointee = codegen__codegen__Codegen__strip_ptr(self, obj_t);
  const ast__ast__DerefUse *const du = ast__ast__Ast__deref_use_at(&((*codegen__codegen__Codegen__cur_ast(self))), member);
  if (codegen__codegen__Codegen__type_at(self, pointee)->kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const ast__ast__Ty rb = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, pointee)));
    if ((rb.kind == ast__ast__TypeKind_TYPE_STRUCT) || (rb.kind == ast__ast__TypeKind_TYPE_ENUM)) {
      const ast__ast__DefId cm = codegen__codegen__Codegen__cg_find_method(self, rb.module, rb.as_data.decl, codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), codegen__codegen__Codegen__name_span(self, member));
      if (cm.node != ast__ast__NODE_NONE) {
        (md = cm);
      }
    } else if ((rb.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) {
      const uint32_t bd = module__loader__Package__builtin_decl(&((*self->package)), rb.as_data.builtin);
      if (bd != ast__ast__NODE_NONE) {
        const ast__ast__DefId cm = codegen__codegen__Codegen__cg_find_method(self, (*self->package).core_module, bd, codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), codegen__codegen__Codegen__name_span(self, member));
        if (cm.node != ast__ast__NODE_NONE) {
          (md = cm);
        }
      }
    }
  }
  const uint32_t dt = codegen__codegen__Codegen__subst_resolve(self, pointee);
  if (codegen__codegen__Codegen__type_at(self, dt)->kind == ast__ast__TypeKind_TYPE_DYN) {
    codegen__codegen__Buf128 mn = (codegen__codegen__Buf128){0};
    codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, md.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.name)->as_data.name.text, ((char *)(&mn.b[0])), 128ULL);
    const ast__ast__TypeKind ok = codegen__codegen__Codegen__type_at(self, obj_t)->kind;
    const bool obj_ind = ((ok == ast__ast__TypeKind_TYPE_POINTER) || (ok == ast__ast__TypeKind_TYPE_REFERENCE));
    const bool simple = ((!obj_ind) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), obj)->kind == ast__ast__NodeKind_NODE_IDENTIFIER));
    codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
    if (simple) {
      codegen__codegen__Codegen__emit_expr(self, obj);
      ({ String__Global *__sc308 = &(self->buf);
String__Global__push_str(&(*__sc308), (str){ .ptr = (const uint8_t*)".vt->", .len = sizeof(".vt->") - 1 });
String__Global__push_str(&(*__sc308), utils__errors__cstr(((const char *)(&mn.b[0]))));
String__Global__push_str(&(*__sc308), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, obj);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc309 = (str){ (const uint8_t *)".data", sizeof(".data") - 1 }; str__ptr(&__sc309); })));
    } else {
      codegen__codegen__Buf256 dtn = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_type_id(self, dt, ((const char *)({ __auto_type __sc310 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc310); })), ((char *)(&dtn.b[0])), 240ULL);
      codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
      ({ String__Global *__sc311 = &(self->buf);
String__Global__push_str(&(*__sc311), (str){ .ptr = (const uint8_t*)"({ const ", .len = sizeof("({ const ") - 1 });
String__Global__push_str(&(*__sc311), utils__errors__cstr(((const char *)(&dtn.b[0]))));
String__Global__push_str(&(*__sc311), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc311), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc311), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
      if (obj_ind) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc312 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc312); })));
      }
      codegen__codegen__Codegen__emit_expr(self, obj);
      ({ String__Global *__sc313 = &(self->buf);
String__Global__push_str(&(*__sc313), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc313), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc313), (str){ .ptr = (const uint8_t*)".vt->", .len = sizeof(".vt->") - 1 });
String__Global__push_str(&(*__sc313), utils__errors__cstr(((const char *)(&mn.b[0]))));
String__Global__push_str(&(*__sc313), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc313), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc313), (str){ .ptr = (const uint8_t*)".data", .len = sizeof(".data") - 1 });
});
    }
    for (uint32_t i = 0U; i < args.len; i++) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc314 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc314); })));
      codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc315 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc315); })));
    if (!simple) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc316 = (str){ (const uint8_t *)"; })", sizeof("; })") - 1 }; str__ptr(&__sc316); })));
    }
    return true;
  }
  ast__ast__Ast *const ma = codegen__codegen__Codegen__mod_ast(self, md.module);
  uint32_t basety = pointee;
  if (du != NULL) {
    (basety = (*du).target);
  }
  const ast__ast__Ty base = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, basety)));
  const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*ma)), md.node)->as_data.function.params;
  uint32_t self_type = ast__ast__NODE_NONE;
  if (params.len != 0U) {
    (self_type = ast__ast__Ast__at_const(&((*ma)), ast__ast__Ast__list(&((*ma)), params)[0])->as_data.parameter.ty);
  }
  ast__ast__NodeKind sk = ast__ast__NodeKind_NODE_NONE_KIND;
  if (self_type != ast__ast__NODE_NONE) {
    (sk = ast__ast__Ast__at_const(&((*ma)), self_type)->kind);
  }
  const bool self_ptr = ((sk == ast__ast__NodeKind_NODE_POINTER_TYPE) || (sk == ast__ast__NodeKind_NODE_REFERENCE_TYPE));
  bool self_is_mut = false;
  if (self_ptr && (self_type != ast__ast__NODE_NONE)) {
    (self_is_mut = (ast__ast__Ast__at_const(&((*ma)), self_type)->as_data.indirect_type.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT));
  }
  const bool obj_ptr = ((codegen__codegen__Codegen__type_at(self, obj_t)->kind == ast__ast__TypeKind_TYPE_POINTER) || (codegen__codegen__Codegen__type_at(self, obj_t)->kind == ast__ast__TypeKind_TYPE_REFERENCE));
  const bool materialize = (((self_ptr || (du != NULL)) && (!obj_ptr)) && (!codegen__codegen__Codegen__is_lvalue(self, obj)));
  const uint32_t crt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  bool void_ret = (crt == ast__ast__TYPE_NONE);
  bool ref_ret = false;
  if (crt != ast__ast__TYPE_NONE) {
    const ast__ast__TypeKind crk = codegen__codegen__Codegen__type_at(self, crt)->kind;
    (void_ret = ((crk == ast__ast__TypeKind_TYPE_BUILTIN) && (codegen__codegen__Codegen__type_at(self, crt)->as_data.builtin == ast__ast__BuiltinType_BT_VOID)));
    (ref_ret = ((crk == ast__ast__TypeKind_TYPE_POINTER) || (crk == ast__ast__TypeKind_TYPE_REFERENCE)));
  }
  const bool free_tmp = ((materialize && (!ref_ret)) && codegen__codegen__Codegen__cg_type_is_free(self, obj_t));
  codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
  codegen__codegen__Buf32 tres = (codegen__codegen__Buf32){0};
  if (materialize) {
    codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
    ({ String__Global *__sc317 = &(self->buf);
String__Global__push_str(&(*__sc317), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc317), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc317), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, obj);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc318 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc318); })));
    if (free_tmp && (!void_ret)) {
      codegen__codegen__Codegen__fresh(self, ((char *)(&tres.b[0])), 32ULL);
      ({ String__Global *__sc319 = &(self->buf);
String__Global__push_str(&(*__sc319), (str){ .ptr = (const uint8_t*)"__auto_type ", .len = sizeof("__auto_type ") - 1 });
String__Global__push_str(&(*__sc319), utils__errors__cstr(((const char *)(&tres.b[0]))));
String__Global__push_str(&(*__sc319), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    }
  }
  const ast__ast__DefId xt = codegen__codegen__Codegen__cg_method_extend_target(self, md);
  ast__ast__NodeKind xtk = ast__ast__NodeKind_NODE_NONE_KIND;
  if (xt.node != ast__ast__NODE_NONE) {
    (xtk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, xt.module))), xt.node)->kind);
  }
  if ((xt.node != ast__ast__NODE_NONE) && (xtk == ast__ast__NodeKind_NODE_TYPE_ALIAS)) {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, md.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_ident_mod(self, xt.module, codegen__codegen__Codegen__cg_decl_name_node(self, xt.module, xt.node));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc320 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc320); })));
  } else if (self->macro_mode && (base.kind == ast__ast__TypeKind_TYPE_GENERIC)) {
    codegen__codegen__Buf64 pp = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc321 = (str){ (const uint8_t *)"_SCM_", sizeof("_SCM_") - 1 }; str__ptr(&__sc321); })));
    codegen__codegen__Codegen__render_macro_param(self, base.module, base.as_data.decl, ((char *)(&pp.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pp.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc322 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc322); })));
  } else if (base.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), base.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc323 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc323); })));
  } else if ((base.kind == ast__ast__TypeKind_TYPE_STRUCT) || (base.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, md.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_ident_mod(self, base.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, base.module))), base.as_data.decl)->as_data.aggregate.name);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc324 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc324); })));
  } else if (base.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, md.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, codegen__codegen__builtin_name(base.as_data.builtin));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc325 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc325); })));
  } else {
    utils__errors__Errors__emit(&self->errors, n.span.start, (n.span.end - n.span.start), ({ String__Global __sc326 = String__Global__new();
String__Global__push_str(&__sc326, (str){ .ptr = (const uint8_t*)"codegen: method receiver is not a struct or enum", .len = sizeof("codegen: method receiver is not a struct or enum") - 1 });
__sc326; }));
  }
  codegen__codegen__Codegen__emit_ident_mod(self, md.module, ast__ast__Ast__at_const(&((*ma)), md.node)->as_data.function.name);
  codegen__codegen__Codegen__emit_method_targs(self, id, md);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc327 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc327); })));
  bool wrote = false;
  if ((params.len > 0U) && (du != NULL)) {
    if (!self_ptr) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc328 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc328); })));
    }
    uint8_t i = (*du).n;
    while (i > 0U) {
      (i = ((uint8_t)((uint32_t)i - (uint32_t)1U)));
      codegen__codegen__Codegen__emit_deref_hop(self, (*du).recv[((size_t)i)], (*du).method[((size_t)i)]);
    }
    if (materialize) {
      ({ String__Global *__sc329 = &(self->buf);
String__Global__push_str(&(*__sc329), (str){ .ptr = (const uint8_t*)"&", .len = sizeof("&") - 1 });
String__Global__push_str(&(*__sc329), utils__errors__cstr(((const char *)(&tmp.b[0]))));
});
    } else if (!obj_ptr) {
      codegen__codegen__Codegen__emit_prefixed(self, obj, ((const char *)({ __auto_type __sc330 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc330); })));
    } else {
      codegen__codegen__Codegen__emit_expr(self, obj);
    }
    for (uint8_t j = 0U; j < (*du).n; j++) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc331 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc331); })));
    }
    (wrote = true);
  } else if (params.len > 0U) {
    if (materialize) {
      ({ String__Global *__sc332 = &(self->buf);
String__Global__push_str(&(*__sc332), (str){ .ptr = (const uint8_t*)"&", .len = sizeof("&") - 1 });
String__Global__push_str(&(*__sc332), utils__errors__cstr(((const char *)(&tmp.b[0]))));
});
    } else if (self_ptr && (!obj_ptr)) {
      codegen__codegen__Codegen__emit_recv_addr(self, obj, self_is_mut);
    } else if ((!self_ptr) && obj_ptr) {
      codegen__codegen__Codegen__emit_prefixed(self, obj, ((const char *)({ __auto_type __sc333 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc333); })));
    } else {
      codegen__codegen__Codegen__emit_expr(self, obj);
    }
    (wrote = true);
  }
  for (uint32_t i = 0U; i < args.len; i++) {
    if (wrote || (i != 0U)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc334 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc334); })));
    }
    codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc335 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc335); })));
  if (materialize) {
    if (free_tmp) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc336 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc336); })));
      codegen__codegen__Codegen__emit_free_target(self, obj_t);
      ({ String__Global *__sc337 = &(self->buf);
String__Global__push_str(&(*__sc337), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc337), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc337), (str){ .ptr = (const uint8_t*)");", .len = sizeof(");") - 1 });
});
      if (!void_ret) {
        ({ String__Global *__sc338 = &(self->buf);
String__Global__push_str(&(*__sc338), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc338), utils__errors__cstr(((const char *)(&tres.b[0]))));
String__Global__push_str(&(*__sc338), (str){ .ptr = (const uint8_t*)";", .len = sizeof(";") - 1 });
});
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc339 = (str){ (const uint8_t *)" })", sizeof(" })") - 1 }; str__ptr(&__sc339); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc340 = (str){ (const uint8_t *)"; })", sizeof("; })") - 1 }; str__ptr(&__sc340); })));
    }
  }
  return true;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_call(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const uint32_t callee_id = n.as_data.call.callee;
  const ast__ast__Node callee = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id));
  const ast__ast__NodeList args = n.as_data.call.args;
  if (codegen__codegen__Codegen__emit_format_builtin(self, id)) {
    return;
  }
  if (codegen__codegen__Codegen__emit_assert_builtin(self, id)) {
    return;
  }
  if (((((callee.kind == ast__ast__NodeKind_NODE_MEMBER) && (!callee.as_data.member.path)) && (args.len == 0U)) && (ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee.as_data.member.member).node == ast__ast__NODE_NONE)) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee.as_data.member.member)->as_data.name.text, ((const char *)({ __auto_type __sc341 = (str){ (const uint8_t *)"free", sizeof("free") - 1 }; str__ptr(&__sc341); })))) {
    const uint32_t recv = callee.as_data.member.object;
    const ast__ast__Ty raw = (*codegen__codegen__Codegen__type_at(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), recv)));
    const bool isref = ((raw.kind == ast__ast__TypeKind_TYPE_POINTER) || (raw.kind == ast__ast__TypeKind_TYPE_REFERENCE));
    const ast__ast__Ty rt = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, codegen__codegen__Codegen__strip_ptr(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), recv)))));
    if ((rt.kind == ast__ast__TypeKind_TYPE_DYN) && (rt.qualifier == 0U)) {
      codegen__codegen__Buf256 stem = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__dyn_stem(self, rt.module, rt.as_data.decl, ((char *)(&stem.b[0])), 176ULL);
      ({ String__Global *__sc342 = &(self->buf);
String__Global__push_str(&(*__sc342), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc342), (str){ .ptr = (const uint8_t*)"__dyn_free", .len = sizeof("__dyn_free") - 1 });
});
      if (isref) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc343 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc343); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc344 = (str){ (const uint8_t *)"(&", sizeof("(&") - 1 }; str__ptr(&__sc344); })));
      }
      codegen__codegen__Codegen__emit_expr(self, recv);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc345 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc345); })));
      return;
    }
    uint16_t om = 0U;
    uint32_t od = ast__ast__NODE_NONE;
    if (rt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), rt.as_data.inst));
      (om = it.module);
      (od = it.decl);
    } else if (rt.kind == ast__ast__TypeKind_TYPE_STRUCT) {
      (om = rt.module);
      (od = rt.as_data.decl);
    }
    ast__ast__DefId fm = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (od != ast__ast__NODE_NONE) {
      (fm = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc346 = (str){ (const uint8_t *)"free", sizeof("free") - 1 }; str__ptr(&__sc346); }))));
    }
    if (fm.node != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_op_method(self, rt, om, od, fm);
      if (isref) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc347 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc347); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc348 = (str){ (const uint8_t *)"(&", sizeof("(&") - 1 }; str__ptr(&__sc348); })));
      }
      codegen__codegen__Codegen__emit_expr(self, recv);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc349 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc349); })));
    } else if (self->macro_mode && (rt.kind == ast__ast__TypeKind_TYPE_GENERIC)) {
      codegen__codegen__Buf64 pp = (codegen__codegen__Buf64){0};
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc350 = (str){ (const uint8_t *)"_SCM_", sizeof("_SCM_") - 1 }; str__ptr(&__sc350); })));
      codegen__codegen__Codegen__render_macro_param(self, rt.module, rt.as_data.decl, ((char *)(&pp.b[0])), 64ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pp.b[0])));
      codegen__codegen__Codegen__emit_paste(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc351 = (str){ (const uint8_t *)"__free", sizeof("__free") - 1 }; str__ptr(&__sc351); })));
      if (isref) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc352 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc352); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc353 = (str){ (const uint8_t *)"(&", sizeof("(&") - 1 }; str__ptr(&__sc353); })));
      }
      codegen__codegen__Codegen__emit_expr(self, recv);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc354 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc354); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc355 = (str){ (const uint8_t *)"(void)(", sizeof("(void)(") - 1 }; str__ptr(&__sc355); })));
      codegen__codegen__Codegen__emit_expr(self, recv);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc356 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc356); })));
    }
    return;
  }
  if (callee.kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id);
    if (d.node != ast__ast__NODE_NONE) {
      const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node);
      if ((dn->kind == ast__ast__NodeKind_NODE_STRUCT) && dn->as_data.aggregate.is_tuple) {
        codegen__codegen__Buf256 tn = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_id(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id)), ((const char *)({ __auto_type __sc357 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc357); })), ((char *)(&tn.b[0])), 200ULL);
        ({ String__Global *__sc358 = &(self->buf);
String__Global__push_str(&(*__sc358), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc358), utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&(*__sc358), (str){ .ptr = (const uint8_t*)"){ ", .len = sizeof("){ ") - 1 });
});
        for (uint32_t i = 0U; i < args.len; i++) {
          if (i != 0U) {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc359 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc359); })));
          }
          ({ String__Global *__sc360 = &(self->buf);
String__Global__push_str(&(*__sc360), (str){ .ptr = (const uint8_t*)"._", .len = sizeof("._") - 1 });
String__Global__push_u64(&(*__sc360), (uint64_t)(i));
String__Global__push_str(&(*__sc360), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
          codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
        }
        if (args.len != 0U) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc361 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc361); })));
        } else {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc362 = (str){ (const uint8_t *)"0 }", sizeof("0 }") - 1 }; str__ptr(&__sc362); })));
        }
        return;
      }
    }
  }
  if ((self->cb_param != ast__ast__NODE_NONE) && (callee.kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id);
    if ((d.module == codegen__codegen__Codegen__cur_module(self)) && (d.node == self->cb_param)) {
      codegen__codegen__Buf256 sym = (codegen__codegen__Buf256){0};
      if (self->cb_callee_closure) {
        codegen__codegen__Codegen__closure_name(self, self->cb_callee.node, ((char *)(&sym.b[0])), 200ULL);
      } else {
        codegen__codegen__Codegen__render_qualified(self, self->cb_callee.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, self->cb_callee.module))), self->cb_callee.node)->as_data.function.name, ((char *)(&sym.b[0])), 200ULL);
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&sym.b[0])));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc363 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc363); })));
      codegen__codegen__Codegen__emit_call_args(self, args);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc364 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc364); })));
      return;
    }
  }
  if (callee.kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId fn2 = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id);
    for (int32_t k = 0; k < self->n_cb_insts; k++) {
      if ((self->cb_insts[((size_t)k)].func.node == fn2.node) && (self->cb_insts[((size_t)k)].func.module == fn2.module)) {
        const uint32_t cbidx = self->cb_insts[((size_t)k)].cbidx;
        ast__ast__DefId ac = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
        bool acclo = false;
        bool known = false;
        if (cbidx < args.len) {
          (known = codegen__codegen__Codegen__cb_known_callee(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)cbidx)], ((ast__ast__DefId *)(&ac)), ((bool *)(&acclo))));
        }
        if ((known && (ac.node == self->cb_insts[((size_t)k)].callee.node)) && (ac.module == self->cb_insts[((size_t)k)].callee.module)) {
          codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
          codegen__codegen__Codegen__cb_spec_name(self, fn2, ac, acclo, ((char *)(&nm.b[0])), 260ULL);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc365 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc365); })));
          bool wrote = false;
          for (uint32_t i = 0U; i < args.len; i++) {
            if (i != cbidx) {
              if (wrote) {
                codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc366 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc366); })));
              }
              codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
              (wrote = true);
            }
          }
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc367 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc367); })));
          return;
        }
      }
    }
  }
  const uint32_t ct0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id);
  if (ct0 != ast__ast__TYPE_NONE) {
    const ast__ast__Ty cty = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ct0)));
    if (cty.kind == ast__ast__TypeKind_TYPE_DYN) {
      const bool simple = (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id)->kind == ast__ast__NodeKind_NODE_IDENTIFIER);
      codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
      if (simple) {
        codegen__codegen__Codegen__emit_expr(self, callee_id);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc368 = (str){ (const uint8_t *)".vt->call(", sizeof(".vt->call(") - 1 }; str__ptr(&__sc368); })));
        codegen__codegen__Codegen__emit_expr(self, callee_id);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc369 = (str){ (const uint8_t *)".data", sizeof(".data") - 1 }; str__ptr(&__sc369); })));
      } else {
        codegen__codegen__Buf256 dtn = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_id(self, codegen__codegen__Codegen__subst_resolve(self, ct0), ((const char *)({ __auto_type __sc370 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc370); })), ((char *)(&dtn.b[0])), 240ULL);
        codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
        ({ String__Global *__sc371 = &(self->buf);
String__Global__push_str(&(*__sc371), (str){ .ptr = (const uint8_t*)"({ const ", .len = sizeof("({ const ") - 1 });
String__Global__push_str(&(*__sc371), utils__errors__cstr(((const char *)(&dtn.b[0]))));
String__Global__push_str(&(*__sc371), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc371), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc371), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, callee_id);
        ({ String__Global *__sc372 = &(self->buf);
String__Global__push_str(&(*__sc372), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc372), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc372), (str){ .ptr = (const uint8_t*)".vt->call(", .len = sizeof(".vt->call(") - 1 });
String__Global__push_str(&(*__sc372), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc372), (str){ .ptr = (const uint8_t*)".data", .len = sizeof(".data") - 1 });
});
      }
      for (uint32_t i = 0U; i < args.len; i++) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc373 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc373); })));
        codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc374 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc374); })));
      if (!simple) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc375 = (str){ (const uint8_t *)"; })", sizeof("; })") - 1 }; str__ptr(&__sc375); })));
      }
      return;
    }
    if ((cty.kind == ast__ast__TypeKind_TYPE_FUNCTION) && codegen__codegen__Codegen__cg_fn_is_capturing(self, (&cty))) {
      codegen__codegen__Buf256 sym = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__closure_sym_in(self, cty.module, cty.as_data.decl, ((char *)(&sym.b[0])), 200ULL);
      ({ String__Global *__sc376 = &(self->buf);
String__Global__push_str(&(*__sc376), utils__errors__cstr(((const char *)(&sym.b[0]))));
String__Global__push_str(&(*__sc376), (str){ .ptr = (const uint8_t*)"(&(", .len = sizeof("(&(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, callee_id);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc377 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc377); })));
      for (uint32_t i = 0U; i < args.len; i++) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc378 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc378); })));
        codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args)[((size_t)i)]);
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc379 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc379); })));
      return;
    }
  }
  codegen__codegen__TyArgs4 ga = (codegen__codegen__TyArgs4){0};
  int32_t gn = 0;
  const ast__ast__DefId g = codegen__codegen__Codegen__generic_call_target(self, id, ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
  if (g.node != ast__ast__NODE_NONE) {
    for (int32_t k = 0; k < gn; k++) {
      (ga.t[((size_t)k)] = codegen__codegen__Codegen__subst_resolve(self, ga.t[((size_t)k)]));
    }
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__spec_name(self, g, ((const uint32_t *)(&ga.t[0])), gn, ((char *)(&nm.b[0])), 256ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc380 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc380); })));
    codegen__codegen__Codegen__emit_call_args(self, args);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc381 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc381); })));
    return;
  }
  if ((callee.kind == ast__ast__NodeKind_NODE_MEMBER) && callee.as_data.member.path) {
    if (codegen__codegen__Codegen__emit_call_path(self, id, n, callee)) {
      return;
    }
  }
  if ((callee.kind == ast__ast__NodeKind_NODE_MEMBER) && (!callee.as_data.member.path)) {
    if (codegen__codegen__Codegen__emit_call_method(self, id, n, callee)) {
      return;
    }
  }
  codegen__codegen__Codegen__emit_expr(self, callee_id);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc382 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc382); })));
  codegen__codegen__Codegen__emit_call_args(self, args);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc383 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc383); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_struct_init(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__StructInitializerData si = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.struct_initializer;
  codegen__codegen__Buf256 t = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__render_type_node(self, si.ty, ((const char *)({ __auto_type __sc384 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc384); })), ((char *)(&t.b[0])), 256ULL);
  const ast__ast__NodeList fields = si.fields;
  const uint32_t stn = si.ty;
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), stn)->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
    const ast__ast__NodeList parts = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), stn)->as_data.type_path.parts;
    if (parts.len >= 2U) {
      const ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), parts)[((size_t)(parts.len - 1U))]);
      if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
        const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, vd.module, vd.node);
        codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
        codegen__codegen__Codegen__render_variant_name(self, vd.module, vd.node, ((char *)(&vn.b[0])), 128ULL);
        ({ String__Global *__sc385 = &(self->buf);
String__Global__push_str(&(*__sc385), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc385), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc385), (str){ .ptr = (const uint8_t*)"){ .tag = ", .len = sizeof("){ .tag = ") - 1 });
});
        if (en != ast__ast__NODE_NONE) {
          codegen__codegen__Codegen__emit_tag_mod(self, vd.module, en, vd.node);
        } else {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc386 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc386); })));
        }
        ({ String__Global *__sc387 = &(self->buf);
String__Global__push_str(&(*__sc387), (str){ .ptr = (const uint8_t*)", .payload.", .len = sizeof(", .payload.") - 1 });
String__Global__push_str(&(*__sc387), utils__errors__cstr(((const char *)(&vn.b[0]))));
String__Global__push_str(&(*__sc387), (str){ .ptr = (const uint8_t*)" = {", .len = sizeof(" = {") - 1 });
});
        for (uint32_t i = 0U; i < fields.len; i++) {
          const ast__ast__FieldInitializerData fi = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), fields)[((size_t)i)])->as_data.field_initializer;
          if (i != 0U) {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc388 = (str){ (const uint8_t *)", .", sizeof(", .") - 1 }; str__ptr(&__sc388); })));
          } else {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc389 = (str){ (const uint8_t *)" .", sizeof(" .") - 1 }; str__ptr(&__sc389); })));
          }
          codegen__codegen__Codegen__emit_ident(self, codegen__codegen__Codegen__name_span(self, fi.name));
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc390 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc390); })));
          if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fi.value)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
            codegen__codegen__Codegen__emit_array_braces(self, fi.value);
          } else {
            codegen__codegen__Codegen__emit_expr(self, fi.value);
          }
        }
        if (fields.len != 0U) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc391 = (str){ (const uint8_t *)" } }", sizeof(" } }") - 1 }; str__ptr(&__sc391); })));
        } else {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc392 = (str){ (const uint8_t *)"0 } }", sizeof("0 } }") - 1 }; str__ptr(&__sc392); })));
        }
        return;
      }
    }
  }
  if (fields.len == 0U) {
    bool zero_fields = false;
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), stn);
    if (d.node != ast__ast__NODE_NONE) {
      const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node);
      (zero_fields = ((dn->kind == ast__ast__NodeKind_NODE_STRUCT) && (dn->as_data.aggregate.members.len == 0U)));
    }
    if (zero_fields) {
      ({ String__Global *__sc393 = &(self->buf);
String__Global__push_str(&(*__sc393), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc393), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc393), (str){ .ptr = (const uint8_t*)"){}", .len = sizeof("){}") - 1 });
});
    } else {
      ({ String__Global *__sc394 = &(self->buf);
String__Global__push_str(&(*__sc394), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc394), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc394), (str){ .ptr = (const uint8_t*)"){0}", .len = sizeof("){0}") - 1 });
});
    }
    return;
  }
  bool arr_copy = false;
  uint32_t i = 0U;
  while (i < fields.len) {
    const uint32_t fv = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), fields)[((size_t)i)])->as_data.field_initializer.value;
    const uint32_t fvt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fv);
    if (((ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fv)->kind != ast__ast__NodeKind_NODE_ARRAY_LITERAL) && (fvt != ast__ast__TYPE_NONE)) && (codegen__codegen__Codegen__type_at(self, fvt)->kind == ast__ast__TypeKind_TYPE_ARRAY)) {
      (arr_copy = true);
    }
    (i = (i + 1U));
  }
  codegen__codegen__Buf32 st = (codegen__codegen__Buf32){0};
  if (arr_copy) {
    codegen__codegen__Codegen__fresh(self, ((char *)(&st.b[0])), 32ULL);
    ({ String__Global *__sc395 = &(self->buf);
String__Global__push_str(&(*__sc395), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc395), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc395), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc395), utils__errors__cstr(((const char *)(&st.b[0]))));
String__Global__push_str(&(*__sc395), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  }
  ({ String__Global *__sc396 = &(self->buf);
String__Global__push_str(&(*__sc396), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc396), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc396), (str){ .ptr = (const uint8_t*)"){ ", .len = sizeof("){ ") - 1 });
});
  (i = 0U);
  while (i < fields.len) {
    const ast__ast__FieldInitializerData fi = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), fields)[((size_t)i)])->as_data.field_initializer;
    if (i != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc397 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc397); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc398 = (str){ (const uint8_t *)".", sizeof(".") - 1 }; str__ptr(&__sc398); })));
    codegen__codegen__Codegen__emit_ident(self, codegen__codegen__Codegen__name_span(self, fi.name));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc399 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc399); })));
    const uint32_t fvt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fi.value);
    const bool arr_field = (((ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fi.value)->kind != ast__ast__NodeKind_NODE_ARRAY_LITERAL) && (fvt != ast__ast__TYPE_NONE)) && (codegen__codegen__Codegen__type_at(self, fvt)->kind == ast__ast__TypeKind_TYPE_ARRAY));
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fi.value)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
      codegen__codegen__Codegen__emit_array_braces(self, fi.value);
    } else if (arr_field) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc400 = (str){ (const uint8_t *)"{0}", sizeof("{0}") - 1 }; str__ptr(&__sc400); })));
    } else {
      codegen__codegen__Codegen__emit_expr(self, fi.value);
    }
    (i = (i + 1U));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc401 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc401); })));
  if (!arr_copy) {
    return;
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc402 = (str){ (const uint8_t *)";", sizeof(";") - 1 }; str__ptr(&__sc402); })));
  (i = 0U);
  while (i < fields.len) {
    const ast__ast__FieldInitializerData fi = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), fields)[((size_t)i)])->as_data.field_initializer;
    const uint32_t fvt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fi.value);
    if (((ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fi.value)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) || (fvt == ast__ast__TYPE_NONE)) || (codegen__codegen__Codegen__type_at(self, fvt)->kind != ast__ast__TypeKind_TYPE_ARRAY)) {
      (i = (i + 1U));
      continue;
    }
    ({ String__Global *__sc403 = &(self->buf);
String__Global__push_str(&(*__sc403), (str){ .ptr = (const uint8_t*)" memcpy(&", .len = sizeof(" memcpy(&") - 1 });
String__Global__push_str(&(*__sc403), utils__errors__cstr(((const char *)(&st.b[0]))));
String__Global__push_str(&(*__sc403), (str){ .ptr = (const uint8_t*)".", .len = sizeof(".") - 1 });
});
    codegen__codegen__Codegen__emit_ident(self, codegen__codegen__Codegen__name_span(self, fi.name));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc404 = (str){ (const uint8_t *)", &(", sizeof(", &(") - 1 }; str__ptr(&__sc404); })));
    codegen__codegen__Codegen__emit_expr(self, fi.value);
    ({ String__Global *__sc405 = &(self->buf);
String__Global__push_str(&(*__sc405), (str){ .ptr = (const uint8_t*)"), sizeof ", .len = sizeof("), sizeof ") - 1 });
String__Global__push_str(&(*__sc405), utils__errors__cstr(((const char *)(&st.b[0]))));
String__Global__push_str(&(*__sc405), (str){ .ptr = (const uint8_t*)".", .len = sizeof(".") - 1 });
});
    codegen__codegen__Codegen__emit_ident(self, codegen__codegen__Codegen__name_span(self, fi.name));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc406 = (str){ (const uint8_t *)");", sizeof(");") - 1 }; str__ptr(&__sc406); })));
    (i = (i + 1U));
  }
  ({ String__Global *__sc407 = &(self->buf);
String__Global__push_str(&(*__sc407), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc407), utils__errors__cstr(((const char *)(&st.b[0]))));
String__Global__push_str(&(*__sc407), (str){ .ptr = (const uint8_t*)"; })", .len = sizeof("; })") - 1 });
});
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_new(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__NewData ne = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.new_expr;
  codegen__codegen__Buf256 t = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__render_type_node(self, ne.ty, ((const char *)({ __auto_type __sc408 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc408); })), ((char *)(&t.b[0])), 256ULL);
  if (ne.initializer == ast__ast__NODE_NONE) {
    ({ String__Global *__sc409 = &(self->buf);
String__Global__push_str(&(*__sc409), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc409), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc409), (str){ .ptr = (const uint8_t*)"*)malloc(sizeof(", .len = sizeof("*)malloc(sizeof(") - 1 });
String__Global__push_str(&(*__sc409), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc409), (str){ .ptr = (const uint8_t*)")))", .len = sizeof(")))") - 1 });
});
    return;
  }
  codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
  ({ String__Global *__sc410 = &(self->buf);
String__Global__push_str(&(*__sc410), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc410), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc410), (str){ .ptr = (const uint8_t*)" *", .len = sizeof(" *") - 1 });
String__Global__push_str(&(*__sc410), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc410), (str){ .ptr = (const uint8_t*)" = malloc(sizeof(", .len = sizeof(" = malloc(sizeof(") - 1 });
String__Global__push_str(&(*__sc410), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc410), (str){ .ptr = (const uint8_t*)")); *", .len = sizeof(")); *") - 1 });
String__Global__push_str(&(*__sc410), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc410), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, ne.initializer);
  ({ String__Global *__sc411 = &(self->buf);
String__Global__push_str(&(*__sc411), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc411), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc411), (str){ .ptr = (const uint8_t*)"; })", .len = sizeof("; })") - 1 });
});
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_match_expr(codegen__codegen__Codegen *const self, uint32_t const id) {
  const uint32_t rt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  codegen__codegen__Buf32 res = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&res.b[0])), 32ULL);
  codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
  if (rt != ast__ast__TYPE_NONE) {
    codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)(&res.b[0])), ((char *)(&decl.b[0])), 256ULL);
  } else {
    codegen__codegen__buf_join3(((char *)(&decl.b[0])), 256ULL, ((const char *)({ __auto_type __sc412 = (str){ (const uint8_t *)"int ", sizeof("int ") - 1 }; str__ptr(&__sc412); })), ((const char *)({ __auto_type __sc413 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc413); })), ((const char *)(&res.b[0])));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc414 = (str){ (const uint8_t *)"({\n", sizeof("({\n") - 1 }; str__ptr(&__sc414); })));
  (self->depth = (self->depth + 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc415 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc415); })));
  codegen__codegen__Codegen__emit_match_core(self, id, 1, ((const char *)(&res.b[0])));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&res.b[0])));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc416 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc416); })));
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc417 = (str){ (const uint8_t *)"})", sizeof("})") - 1 }; str__ptr(&__sc417); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_match_stmt(codegen__codegen__Codegen *const self, uint32_t const id) {
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc418 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc418); })));
  (self->depth = (self->depth + 1U));
  codegen__codegen__Codegen__emit_match_core(self, id, 0, NULL);
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc419 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc419); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_if_expr(codegen__codegen__Codegen *const self, uint32_t const id) {
  const uint32_t rt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  codegen__codegen__Buf32 res = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&res.b[0])), 32ULL);
  codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
  if (rt != ast__ast__TYPE_NONE) {
    codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)(&res.b[0])), ((char *)(&decl.b[0])), 256ULL);
  } else {
    codegen__codegen__buf_join3(((char *)(&decl.b[0])), 256ULL, ((const char *)({ __auto_type __sc420 = (str){ (const uint8_t *)"int ", sizeof("int ") - 1 }; str__ptr(&__sc420); })), ((const char *)({ __auto_type __sc421 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc421); })), ((const char *)(&res.b[0])));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc422 = (str){ (const uint8_t *)"({\n", sizeof("({\n") - 1 }; str__ptr(&__sc422); })));
  (self->depth = (self->depth + 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc423 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc423); })));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_if_value(self, id, ((const char *)(&res.b[0])));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc424 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc424); })));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&res.b[0])));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc425 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc425); })));
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc426 = (str){ (const uint8_t *)"})", sizeof("})") - 1 }; str__ptr(&__sc426); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_try(codegen__codegen__Codegen *const self, uint32_t const id) {
  const uint32_t operand = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.unary.operand;
  const ast__ast__Ty bt = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, codegen__codegen__Codegen__strip_ptr(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), operand)))));
  if (bt.kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Codegen__emit_expr(self, operand);
    return;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst));
  const uint16_t om = it.module;
  const uint32_t od = it.decl;
  const uint32_t noneV = codegen__codegen__Codegen__cg_enum_variant(self, om, od, ((const char *)({ __auto_type __sc427 = (str){ (const uint8_t *)"None", sizeof("None") - 1 }; str__ptr(&__sc427); })));
  const bool is_option = (noneV != ast__ast__NODE_NONE);
  uint32_t failV = noneV;
  if (!is_option) {
    (failV = codegen__codegen__Codegen__cg_enum_variant(self, om, od, ((const char *)({ __auto_type __sc428 = (str){ (const uint8_t *)"Err", sizeof("Err") - 1 }; str__ptr(&__sc428); }))));
  }
  const char *okName2 = ((const char *)({ __auto_type __sc429 = (str){ (const uint8_t *)"Ok", sizeof("Ok") - 1 }; str__ptr(&__sc429); }));
  if (is_option) {
    (okName2 = ((const char *)({ __auto_type __sc430 = (str){ (const uint8_t *)"Some", sizeof("Some") - 1 }; str__ptr(&__sc430); })));
  }
  const uint32_t okV = codegen__codegen__Codegen__cg_enum_variant(self, om, od, okName2);
  codegen__codegen__Buf128 okName = (codegen__codegen__Buf128){0};
  codegen__codegen__Buf128 failName = (codegen__codegen__Buf128){0};
  codegen__codegen__Codegen__render_variant_name(self, om, okV, ((char *)(&okName.b[0])), 128ULL);
  codegen__codegen__Codegen__render_variant_name(self, om, failV, ((char *)(&failName.b[0])), 128ULL);
  codegen__codegen__Buf256 rtn = (codegen__codegen__Buf256){0};
  (rtn.b[0] = 0);
  if (self->current_fn_ret_node != ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__render_type_node(self, self->current_fn_ret_node, ((const char *)({ __auto_type __sc431 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc431); })), ((char *)(&rtn.b[0])), 200ULL);
  }
  codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
  ({ String__Global *__sc432 = &(self->buf);
String__Global__push_str(&(*__sc432), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc432), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc432), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, operand);
  ({ String__Global *__sc433 = &(self->buf);
String__Global__push_str(&(*__sc433), (str){ .ptr = (const uint8_t*)"; if (", .len = sizeof("; if (") - 1 });
String__Global__push_str(&(*__sc433), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc433), (str){ .ptr = (const uint8_t*)".tag == ", .len = sizeof(".tag == ") - 1 });
});
  codegen__codegen__Codegen__emit_tag_mod(self, om, od, failV);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc434 = (str){ (const uint8_t *)") {\n", sizeof(") {\n") - 1 }; str__ptr(&__sc434); })));
  (self->depth = (self->depth + 1U));
  codegen__codegen__Codegen__emit_defers_to(self, 0U);
  codegen__codegen__Codegen__emit_indent(self);
  ({ String__Global *__sc435 = &(self->buf);
String__Global__push_str(&(*__sc435), (str){ .ptr = (const uint8_t*)"return (", .len = sizeof("return (") - 1 });
String__Global__push_str(&(*__sc435), utils__errors__cstr(((const char *)(&rtn.b[0]))));
String__Global__push_str(&(*__sc435), (str){ .ptr = (const uint8_t*)"){ .tag = ", .len = sizeof("){ .tag = ") - 1 });
});
  codegen__codegen__Codegen__emit_tag_mod(self, om, od, failV);
  if (!is_option) {
    const ast__ast__DefId conv = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), id);
    ast__ast__DefId tg = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (conv.node != ast__ast__NODE_NONE) {
      (tg = codegen__codegen__Codegen__cg_method_extend_target(self, conv));
    }
    ({ String__Global *__sc436 = &(self->buf);
String__Global__push_str(&(*__sc436), (str){ .ptr = (const uint8_t*)", .payload.", .len = sizeof(", .payload.") - 1 });
String__Global__push_str(&(*__sc436), utils__errors__cstr(((const char *)(&failName.b[0]))));
String__Global__push_str(&(*__sc436), (str){ .ptr = (const uint8_t*)"._0 = ", .len = sizeof("._0 = ") - 1 });
});
    if (tg.node != ast__ast__NODE_NONE) {
      codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
      codegen__codegen__Codegen__render_modpfx(self, conv.module, ((char *)(&pfx.b[0])), 64ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
      codegen__codegen__Codegen__emit_ident_mod(self, tg.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, tg.module))), tg.node)->as_data.aggregate.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc437 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc437); })));
      codegen__codegen__Codegen__emit_ident_mod(self, conv.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, conv.module))), conv.node)->as_data.function.name);
      codegen__codegen__Buf256 sfx = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__cg_conv_suffix(self, tg, ((const char *)({ __auto_type __sc438 = (str){ (const uint8_t *)"from", sizeof("from") - 1 }; str__ptr(&__sc438); })), codegen__codegen__Codegen__subst_resolve(self, it.args[1]), ((char *)(&sfx.b[0])), 200ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&sfx.b[0])));
      ({ String__Global *__sc439 = &(self->buf);
String__Global__push_str(&(*__sc439), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc439), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc439), (str){ .ptr = (const uint8_t*)".payload.", .len = sizeof(".payload.") - 1 });
String__Global__push_str(&(*__sc439), utils__errors__cstr(((const char *)(&failName.b[0]))));
String__Global__push_str(&(*__sc439), (str){ .ptr = (const uint8_t*)"._0)", .len = sizeof("._0)") - 1 });
});
    } else {
      ({ String__Global *__sc440 = &(self->buf);
String__Global__push_str(&(*__sc440), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc440), (str){ .ptr = (const uint8_t*)".payload.", .len = sizeof(".payload.") - 1 });
String__Global__push_str(&(*__sc440), utils__errors__cstr(((const char *)(&failName.b[0]))));
String__Global__push_str(&(*__sc440), (str){ .ptr = (const uint8_t*)"._0", .len = sizeof("._0") - 1 });
});
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc441 = (str){ (const uint8_t *)" };\n", sizeof(" };\n") - 1 }; str__ptr(&__sc441); })));
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  ({ String__Global *__sc442 = &(self->buf);
String__Global__push_str(&(*__sc442), (str){ .ptr = (const uint8_t*)"} ", .len = sizeof("} ") - 1 });
String__Global__push_str(&(*__sc442), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc442), (str){ .ptr = (const uint8_t*)".payload.", .len = sizeof(".payload.") - 1 });
String__Global__push_str(&(*__sc442), utils__errors__cstr(((const char *)(&okName.b[0]))));
String__Global__push_str(&(*__sc442), (str){ .ptr = (const uint8_t*)"._0; })", .len = sizeof("._0; })") - 1 });
});
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_stmt(codegen__codegen__Codegen *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const ast__ast__NodeKind nk = n.kind;
  {
    const ast__ast__NodeKind __sc443 = nk;
    if (__sc443 == ast__ast__NodeKind_NODE_STATIC_ASSERT) {
      {
        codegen__codegen__Codegen__emit_static_assert(self, id);
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        codegen__codegen__Codegen__emit_block(self, id);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc444 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc444); })));
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_LET) {
      {
        const uint32_t nameN = n.as_data.let_stmt.name;
        const ast__ast__NodeKind nameK = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nameN)->kind;
        if ((nameK == ast__ast__NodeKind_NODE_IDENTIFIER) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nameN)->as_data.name.text, ((const char *)({ __auto_type __sc445 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc445); })))) {
          const uint32_t dvt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.let_stmt.value);
          if ((dvt != ast__ast__TYPE_NONE) && codegen__codegen__Codegen__cg_type_is_free(self, dvt)) {
            codegen__codegen__Codegen__emit_expr_stmt(self, n.as_data.let_stmt.value);
          } else {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc446 = (str){ (const uint8_t *)"(void)(", sizeof("(void)(") - 1 }; str__ptr(&__sc446); })));
            codegen__codegen__Codegen__emit_expr(self, n.as_data.let_stmt.value);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc447 = (str){ (const uint8_t *)");\n", sizeof(");\n") - 1 }; str__ptr(&__sc447); })));
          }
          return;
        }
        if (nameK == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
          codegen__codegen__Codegen__emit_tuple_let(self, id);
          const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nameN)->as_data.pattern.children;
          for (uint32_t i = 0U; i < children.len; i++) {
            const uint32_t eid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), children)[((size_t)i)];
            if (((!codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), eid))) || codegen__codegen__Codegen__cg_is_moved(self, eid)) || codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), codegen__codegen__Codegen__name_span(self, eid), ((const char *)({ __auto_type __sc448 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc448); })))) {
              continue;
            }
            if (codegen__codegen__Codegen__cg_is_cond_moved(self, eid)) {
              codegen__codegen__Buf32 fl = (codegen__codegen__Buf32){0};
              codegen__codegen__cg_move_flag(((char *)(&fl.b[0])), 32ULL, eid);
              codegen__codegen__Codegen__emit_indent(self);
              ({ String__Global *__sc449 = &(self->buf);
String__Global__push_str(&(*__sc449), (str){ .ptr = (const uint8_t*)"bool ", .len = sizeof("bool ") - 1 });
String__Global__push_str(&(*__sc449), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc449), (str){ .ptr = (const uint8_t*)" = false;\n", .len = sizeof(" = false;\n") - 1 });
});
            }
            codegen__codegen__Codegen__cg_register_auto_free(self, eid);
          }
          return;
        }
        const bool autofree = codegen__codegen__Codegen__cg_will_auto_free(self, id);
        const bool is_const = ((!n.as_data.let_stmt.is_mutable) && (!codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id))));
        const uint32_t lbt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
        const uint32_t lval = n.as_data.let_stmt.value;
        if ((((lval != ast__ast__NODE_NONE) && (lbt != ast__ast__TYPE_NONE)) && (codegen__codegen__Codegen__type_at(self, lbt)->kind == ast__ast__TypeKind_TYPE_ARRAY)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lval)->kind != ast__ast__NodeKind_NODE_ARRAY_LITERAL)) {
          uint32_t arrtn = n.as_data.let_stmt.ty;
          if ((arrtn == ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lval)->kind == ast__ast__NodeKind_NODE_CALL)) {
            const ast__ast__DefId fd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lval)->as_data.call.callee);
            if (((fd.node != ast__ast__NODE_NONE) && (fd.module == codegen__codegen__Codegen__cur_module(self))) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, fd.module))), fd.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
              (arrtn = codegen__codegen__Codegen__fn_array_return(self, fd.node));
            }
          }
          if (arrtn != ast__ast__NODE_NONE) {
            codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
            codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, nameN), ((char *)(&nm.b[0])), 128ULL);
            codegen__codegen__Buf512 decl = (codegen__codegen__Buf512){0};
            codegen__codegen__Codegen__render_binding_node(self, arrtn, ((const char *)(&nm.b[0])), false, ((char *)(&decl.b[0])), 300ULL);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
            ({ String__Global *__sc450 = &(self->buf);
String__Global__push_str(&(*__sc450), (str){ .ptr = (const uint8_t*)"; memcpy(", .len = sizeof("; memcpy(") - 1 });
String__Global__push_str(&(*__sc450), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc450), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
            codegen__codegen__Codegen__emit_expr(self, lval);
            ({ String__Global *__sc451 = &(self->buf);
String__Global__push_str(&(*__sc451), (str){ .ptr = (const uint8_t*)", sizeof(", .len = sizeof(", sizeof(") - 1 });
String__Global__push_str(&(*__sc451), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc451), (str){ .ptr = (const uint8_t*)"));\n", .len = sizeof("));\n") - 1 });
});
            return;
          }
        }
        if (n.as_data.let_stmt.ty != ast__ast__NODE_NONE) {
          codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
          codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, nameN), ((char *)(&nm.b[0])), 128ULL);
          codegen__codegen__Buf512 decl = (codegen__codegen__Buf512){0};
          codegen__codegen__Codegen__render_binding_node(self, n.as_data.let_stmt.ty, ((const char *)(&nm.b[0])), is_const, ((char *)(&decl.b[0])), 300ULL);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
        } else {
          codegen__codegen__Codegen__emit_binding(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id), codegen__codegen__Codegen__name_span(self, nameN), is_const);
        }
        if (n.as_data.let_stmt.value != ast__ast__NODE_NONE) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc452 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc452); })));
          codegen__codegen__Codegen__emit_initializer(self, n.as_data.let_stmt.ty, n.as_data.let_stmt.value);
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc453 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc453); })));
        if (autofree && codegen__codegen__Codegen__cg_is_cond_moved(self, id)) {
          codegen__codegen__Buf32 fl = (codegen__codegen__Buf32){0};
          codegen__codegen__cg_move_flag(((char *)(&fl.b[0])), 32ULL, id);
          codegen__codegen__Codegen__emit_indent(self);
          ({ String__Global *__sc454 = &(self->buf);
String__Global__push_str(&(*__sc454), (str){ .ptr = (const uint8_t*)"bool ", .len = sizeof("bool ") - 1 });
String__Global__push_str(&(*__sc454), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc454), (str){ .ptr = (const uint8_t*)" = false;\n", .len = sizeof(" = false;\n") - 1 });
});
        }
        if (autofree) {
          codegen__codegen__Codegen__cg_register_auto_free(self, id);
        }
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_CONST) {
      {
        codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
        codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, n.as_data.const_def.name), ((char *)(&nm.b[0])), 128ULL);
        codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_node(self, n.as_data.const_def.ty, ((const char *)(&nm.b[0])), ((char *)(&decl.b[0])), 256ULL);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc455 = (str){ (const uint8_t *)"static const ", sizeof("static const ") - 1 }; str__ptr(&__sc455); })));
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
        if (n.as_data.const_def.value != ast__ast__NODE_NONE) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc456 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc456); })));
          const bool sc = self->const_ctx;
          (self->const_ctx = true);
          codegen__codegen__Codegen__emit_initializer(self, n.as_data.const_def.ty, n.as_data.const_def.value);
          (self->const_ctx = sc);
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc457 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc457); })));
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_RETURN) {
      {
        codegen__codegen__Codegen__emit_return(self, id);
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_IF) {
      {
        codegen__codegen__Codegen__emit_if(self, id);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc458 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc458); })));
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_WHILE) {
      {
        const uint32_t saved_ldb = self->loop_defer_base;
        (self->loop_defer_base = self->defer_top);
        const int32_t le = codegen__codegen__Codegen__cg_loop_push(self, id, false);
        if (n.as_data.while_stmt.is_do) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc459 = (str){ (const uint8_t *)"do ", sizeof("do ") - 1 }; str__ptr(&__sc459); })));
          (self->pending_cnt = ((uint32_t)({ int32_t __sc_r; if (__builtin_add_overflow(le, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
          codegen__codegen__Codegen__emit_block(self, n.as_data.while_stmt.body);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc460 = (str){ (const uint8_t *)" while ", sizeof(" while ") - 1 }; str__ptr(&__sc460); })));
          codegen__codegen__Codegen__emit_condition(self, n.as_data.while_stmt.condition);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc461 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc461); })));
        } else {
          if (n.as_data.while_stmt.condition == ast__ast__NODE_NONE) {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc462 = (str){ (const uint8_t *)"for (;;) ", sizeof("for (;;) ") - 1 }; str__ptr(&__sc462); })));
          } else {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc463 = (str){ (const uint8_t *)"while ", sizeof("while ") - 1 }; str__ptr(&__sc463); })));
            codegen__codegen__Codegen__emit_condition(self, n.as_data.while_stmt.condition);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc464 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc464); })));
          }
          (self->pending_cnt = ((uint32_t)({ int32_t __sc_r; if (__builtin_add_overflow(le, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
          codegen__codegen__Codegen__emit_block(self, n.as_data.while_stmt.body);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc465 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc465); })));
        }
        codegen__codegen__Codegen__cg_loop_brk_label(self, le);
        codegen__codegen__Codegen__cg_loop_pop(self, le);
        (self->loop_defer_base = saved_ldb);
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_FOR) {
      {
        const uint32_t saved_ldb = self->loop_defer_base;
        (self->loop_defer_base = self->defer_top);
        const int32_t le = codegen__codegen__Codegen__cg_loop_push(self, id, false);
        codegen__codegen__Codegen__emit_for(self, id);
        codegen__codegen__Codegen__cg_loop_brk_label(self, le);
        codegen__codegen__Codegen__cg_loop_pop(self, le);
        (self->loop_defer_base = saved_ldb);
      }
    }
    else if ((__sc443 == ast__ast__NodeKind_NODE_BREAK) || (__sc443 == ast__ast__NodeKind_NODE_CONTINUE)) {
      {
        const bool is_brk = (nk == ast__ast__NodeKind_NODE_BREAK);
        const int32_t le = codegen__codegen__Codegen__cg_loop_find(self, ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), id));
        const bool top = ((le < 0) || (((uint32_t)le) == (self->nloops - 1U)));
        uint32_t dbase = self->loop_defer_base;
        if (le >= 0) {
          (dbase = self->loop_stack[((size_t)le)].defer_base);
        }
        uint32_t value = ast__ast__NODE_NONE;
        if (is_brk) {
          (value = n.as_data.flow.value);
        }
        const char *kw = ((const char *)({ __auto_type __sc466 = (str){ (const uint8_t *)"continue", sizeof("continue") - 1 }; str__ptr(&__sc466); }));
        if (is_brk) {
          (kw = ((const char *)({ __auto_type __sc467 = (str){ (const uint8_t *)"break", sizeof("break") - 1 }; str__ptr(&__sc467); })));
        }
        if (top && (value == ast__ast__NODE_NONE)) {
          if (self->defer_top > dbase) {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc468 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc468); })));
            (self->depth = (self->depth + 1U));
            codegen__codegen__Codegen__emit_defers_to(self, dbase);
            codegen__codegen__Codegen__emit_indent(self);
            ({ String__Global *__sc469 = &(self->buf);
String__Global__push_str(&(*__sc469), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc469), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
            (self->depth = (self->depth - 1U));
            codegen__codegen__Codegen__emit_indent(self);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc470 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc470); })));
          } else {
            ({ String__Global *__sc471 = &(self->buf);
String__Global__push_str(&(*__sc471), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc471), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
          }
          return;
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc472 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc472); })));
        (self->depth = (self->depth + 1U));
        if (((value != ast__ast__NODE_NONE) && (le >= 0)) && self->loop_stack[((size_t)le)].is_expr) {
          codegen__codegen__Codegen__emit_indent(self);
          ({ String__Global *__sc473 = &(self->buf);
String__Global__push_str(&(*__sc473), (str){ .ptr = (const uint8_t*)"__lv", .len = sizeof("__lv") - 1 });
String__Global__push_u64(&(*__sc473), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc473), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
          codegen__codegen__Codegen__emit_expr(self, value);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc474 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc474); })));
        }
        codegen__codegen__Codegen__emit_defers_to(self, dbase);
        codegen__codegen__Codegen__emit_indent(self);
        if (top) {
          ({ String__Global *__sc475 = &(self->buf);
String__Global__push_str(&(*__sc475), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc475), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
        } else if (is_brk) {
          (self->loop_stack[((size_t)le)].used_brk = true);
          ({ String__Global *__sc476 = &(self->buf);
String__Global__push_str(&(*__sc476), (str){ .ptr = (const uint8_t*)"goto __brk", .len = sizeof("goto __brk") - 1 });
String__Global__push_u64(&(*__sc476), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc476), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
        } else {
          (self->loop_stack[((size_t)le)].used_cnt = true);
          ({ String__Global *__sc477 = &(self->buf);
String__Global__push_str(&(*__sc477), (str){ .ptr = (const uint8_t*)"goto __cnt", .len = sizeof("goto __cnt") - 1 });
String__Global__push_u64(&(*__sc477), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc477), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
        }
        (self->depth = (self->depth - 1U));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc478 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc478); })));
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_DEFER) {
      {
        if (self->defer_top >= 256U) {
          utils__errors__Errors__emit(&self->errors, n.span.start, (n.span.end - n.span.start), ({ String__Global __sc479 = String__Global__new();
String__Global__push_str(&__sc479, (str){ .ptr = (const uint8_t*)"codegen: too many nested 'defer' statements", .len = sizeof("codegen: too many nested 'defer' statements") - 1 });
__sc479; }));
        } else {
          const uint32_t t = self->defer_top;
          (self->defer_kind[((size_t)t)] = 0U);
          (self->defer_stack[((size_t)t)] = n.as_data.single.value);
          (self->defer_top = (t + 1U));
        }
      }
    }
    else if (__sc443 == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) {
      {
        codegen__codegen__Codegen__emit_expr_stmt(self, n.as_data.single.value);
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_block(codegen__codegen__Codegen *const self, uint32_t const id) {
  codegen__codegen__Codegen__emit_block_from(self, id, self->defer_top);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_binding(codegen__codegen__Codegen *const self, uint32_t const t, lexer__token__Span const name, bool const is_const) {
  codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
  codegen__codegen__Codegen__render_ident(self, name, ((char *)(&nm.b[0])), 128ULL);
  const ast__ast__TypeKind k = codegen__codegen__Codegen__type_at(self, t)->kind;
  if ((k == ast__ast__TypeKind_TYPE_GENERIC) || (k == ast__ast__TypeKind_TYPE_ERROR)) {
    if (is_const) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc480 = (str){ (const uint8_t *)"const __auto_type ", sizeof("const __auto_type ") - 1 }; str__ptr(&__sc480); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc481 = (str){ (const uint8_t *)"__auto_type ", sizeof("__auto_type ") - 1 }; str__ptr(&__sc481); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
    return;
  }
  if (is_const && ((k == ast__ast__TypeKind_TYPE_POINTER) || (k == ast__ast__TypeKind_TYPE_REFERENCE))) {
    codegen__codegen__Buf256 cn = (codegen__codegen__Buf256){0};
    codegen__codegen__buf_join3(((char *)(&cn.b[0])), 200ULL, ((const char *)({ __auto_type __sc482 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc482); })), ((const char *)({ __auto_type __sc483 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc483); })), ((const char *)(&nm.b[0])));
    codegen__codegen__Buf512 decl = (codegen__codegen__Buf512){0};
    codegen__codegen__Codegen__render_type_id(self, t, ((const char *)(&cn.b[0])), ((char *)(&decl.b[0])), 512ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  } else {
    codegen__codegen__Buf512 decl = (codegen__codegen__Buf512){0};
    codegen__codegen__Codegen__render_type_id(self, t, ((const char *)(&nm.b[0])), ((char *)(&decl.b[0])), 512ULL);
    if (is_const) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc484 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc484); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_binding_node(codegen__codegen__Codegen *const self, uint32_t const tn, const char *const name, bool const is_const, char *const out, size_t const cap) {
  if (is_const) {
    codegen__codegen__Buf256 cn = (codegen__codegen__Buf256){0};
    codegen__codegen__buf_join3(((char *)(&cn.b[0])), 200ULL, ((const char *)({ __auto_type __sc485 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc485); })), ((const char *)({ __auto_type __sc486 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc486); })), name);
    codegen__codegen__Codegen__render_type_node(self, tn, ((const char *)(&cn.b[0])), out, cap);
  } else {
    codegen__codegen__Codegen__render_type_node(self, tn, name, out, cap);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_static_assert(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary;
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc487 = (str){ (const uint8_t *)"_Static_assert(", sizeof("_Static_assert(") - 1 }; str__ptr(&__sc487); })));
  const bool sc = self->const_ctx;
  (self->const_ctx = true);
  codegen__codegen__Codegen__emit_expr(self, bd.left);
  (self->const_ctx = sc);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc488 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc488); })));
  if (bd.right != ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__emit_reescaped(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), bd.right)->as_data.literal.raw, false);
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc489 = (str){ (const uint8_t *)"\"static assertion failed\"", sizeof("\"static assertion failed\"") - 1 }; str__ptr(&__sc489); })));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc490 = (str){ (const uint8_t *)");\n", sizeof(");\n") - 1 }; str__ptr(&__sc490); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_tuple_let(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
  const ast__ast__NodeList pnm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.let_stmt.name)->as_data.pattern.children;
  bool freed_discard = false;
  uint32_t i = 0U;
  while (i < pnm.len) {
    const uint32_t pid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), pnm)[((size_t)i)];
    if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), codegen__codegen__Codegen__name_span(self, pid), ((const char *)({ __auto_type __sc491 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc491); }))) && codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), pid))) {
      (freed_discard = true);
    }
    (i = (i + 1U));
  }
  const char *cq = ((const char *)({ __auto_type __sc492 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc492); }));
  if (freed_discard) {
    (cq = ((const char *)({ __auto_type __sc493 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc493); })));
  }
  ({ String__Global *__sc494 = &(self->buf);
String__Global__push_str(&(*__sc494), utils__errors__cstr(cq));
String__Global__push_str(&(*__sc494), (str){ .ptr = (const uint8_t*)"__auto_type ", .len = sizeof("__auto_type ") - 1 });
String__Global__push_str(&(*__sc494), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc494), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, n.as_data.let_stmt.value);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc495 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc495); })));
  const ast__ast__NodeList names = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.let_stmt.name)->as_data.pattern.children;
  (i = 0U);
  while (i < names.len) {
    const uint32_t nid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), names)[((size_t)i)];
    codegen__codegen__Buf128 bn = (codegen__codegen__Buf128){0};
    codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, nid), ((char *)(&bn.b[0])), 128ULL);
    if ((bn.b[0] == 95) && (bn.b[1] == 0)) {
      if (codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), nid))) {
        codegen__codegen__Codegen__emit_indent(self);
        if (codegen__codegen__Codegen__emit_free_target(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), nid))) {
          ({ String__Global *__sc496 = &(self->buf);
String__Global__push_str(&(*__sc496), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc496), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc496), (str){ .ptr = (const uint8_t*)"._", .len = sizeof("._") - 1 });
String__Global__push_u64(&(*__sc496), (uint64_t)(i));
String__Global__push_str(&(*__sc496), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
        } else {
          ({ String__Global *__sc497 = &(self->buf);
String__Global__push_str(&(*__sc497), (str){ .ptr = (const uint8_t*)"(void)", .len = sizeof("(void)") - 1 });
String__Global__push_str(&(*__sc497), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc497), (str){ .ptr = (const uint8_t*)"._", .len = sizeof("._") - 1 });
String__Global__push_u64(&(*__sc497), (uint64_t)(i));
});
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc498 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc498); })));
      }
      (i = (i + 1U));
      continue;
    }
    codegen__codegen__Codegen__emit_indent(self);
    const bool element_const = ((!n.as_data.let_stmt.is_mutable) && (!codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), nid))));
    const char *ecq = ((const char *)({ __auto_type __sc499 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc499); }));
    if (element_const) {
      (ecq = ((const char *)({ __auto_type __sc500 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc500); })));
    }
    ({ String__Global *__sc501 = &(self->buf);
String__Global__push_str(&(*__sc501), utils__errors__cstr(ecq));
String__Global__push_str(&(*__sc501), (str){ .ptr = (const uint8_t*)"__auto_type ", .len = sizeof("__auto_type ") - 1 });
String__Global__push_str(&(*__sc501), utils__errors__cstr(((const char *)(&bn.b[0]))));
String__Global__push_str(&(*__sc501), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc501), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc501), (str){ .ptr = (const uint8_t*)"._", .len = sizeof("._") - 1 });
String__Global__push_u64(&(*__sc501), (uint64_t)(i));
String__Global__push_str(&(*__sc501), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    (i = (i + 1U));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_return(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__NodeList vals = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.return_stmt.values;
  const bool has_ret = (self->current_ret[0] != 0);
  const char *const crp = ((const char *)(&self->current_ret[0]));
  if (self->defer_top > 0U) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc502 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc502); })));
    (self->depth = (self->depth + 1U));
    if (vals.len == 0U) {
      codegen__codegen__Codegen__emit_defers_to(self, 0U);
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc503 = (str){ (const uint8_t *)"return;\n", sizeof("return;\n") - 1 }; str__ptr(&__sc503); })));
    } else {
      codegen__codegen__Buf32 rv = (codegen__codegen__Buf32){0};
      codegen__codegen__Codegen__fresh(self, ((char *)(&rv.b[0])), 32ULL);
      codegen__codegen__Codegen__emit_indent(self);
      if (has_ret) {
        ({ String__Global *__sc504 = &(self->buf);
String__Global__push_str(&(*__sc504), utils__errors__cstr(crp));
String__Global__push_str(&(*__sc504), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc504), utils__errors__cstr(((const char *)(&rv.b[0]))));
String__Global__push_str(&(*__sc504), (str){ .ptr = (const uint8_t*)" = (", .len = sizeof(" = (") - 1 });
String__Global__push_str(&(*__sc504), utils__errors__cstr(crp));
String__Global__push_str(&(*__sc504), (str){ .ptr = (const uint8_t*)"){ ", .len = sizeof("){ ") - 1 });
});
        const uint32_t v0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), vals)[0];
        if ((vals.len == 1U) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v0)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL)) {
          codegen__codegen__Codegen__emit_array_braces(self, v0);
        } else {
          uint32_t i = 0U;
          while (i < vals.len) {
            if (i != 0U) {
              codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc505 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc505); })));
            }
            codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), vals)[((size_t)i)]);
            (i = (i + 1U));
          }
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc506 = (str){ (const uint8_t *)" };\n", sizeof(" };\n") - 1 }; str__ptr(&__sc506); })));
      } else {
        const uint32_t v0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), vals)[0];
        const uint32_t rvt0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), v0);
        if ((rvt0 != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, rvt0)->kind == ast__ast__TypeKind_TYPE_NEVER)) {
          codegen__codegen__Codegen__emit_expr(self, v0);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc507 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc507); })));
          (self->depth = (self->depth - 1U));
          codegen__codegen__Codegen__emit_indent(self);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc508 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc508); })));
          return;
        }
        ({ String__Global *__sc509 = &(self->buf);
String__Global__push_str(&(*__sc509), (str){ .ptr = (const uint8_t*)"__auto_type ", .len = sizeof("__auto_type ") - 1 });
String__Global__push_str(&(*__sc509), utils__errors__cstr(((const char *)(&rv.b[0]))));
String__Global__push_str(&(*__sc509), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, v0);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc510 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc510); })));
      }
      codegen__codegen__Codegen__emit_defers_to(self, 0U);
      codegen__codegen__Codegen__emit_indent(self);
      ({ String__Global *__sc511 = &(self->buf);
String__Global__push_str(&(*__sc511), (str){ .ptr = (const uint8_t*)"return ", .len = sizeof("return ") - 1 });
String__Global__push_str(&(*__sc511), utils__errors__cstr(((const char *)(&rv.b[0]))));
String__Global__push_str(&(*__sc511), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    }
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc512 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc512); })));
    return;
  }
  if (vals.len == 0U) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc513 = (str){ (const uint8_t *)"return;\n", sizeof("return;\n") - 1 }; str__ptr(&__sc513); })));
    return;
  }
  if (vals.len == 1U) {
    const uint32_t v0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), vals)[0];
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v0)->kind == ast__ast__NodeKind_NODE_MATCH) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc514 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc514); })));
      (self->depth = (self->depth + 1U));
      codegen__codegen__Codegen__emit_match_core(self, v0, 2, NULL);
      (self->depth = (self->depth - 1U));
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc515 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc515); })));
      return;
    }
    if (has_ret) {
      ({ String__Global *__sc516 = &(self->buf);
String__Global__push_str(&(*__sc516), (str){ .ptr = (const uint8_t*)"return (", .len = sizeof("return (") - 1 });
String__Global__push_str(&(*__sc516), utils__errors__cstr(crp));
String__Global__push_str(&(*__sc516), (str){ .ptr = (const uint8_t*)"){ ", .len = sizeof("){ ") - 1 });
});
      if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v0)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
        codegen__codegen__Codegen__emit_array_braces(self, v0);
      } else {
        codegen__codegen__Codegen__emit_expr(self, v0);
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc517 = (str){ (const uint8_t *)" };\n", sizeof(" };\n") - 1 }; str__ptr(&__sc517); })));
      return;
    }
    const uint32_t rvt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), v0);
    if ((rvt != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, rvt)->kind == ast__ast__TypeKind_TYPE_NEVER)) {
      codegen__codegen__Codegen__emit_expr(self, v0);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc518 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc518); })));
      return;
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc519 = (str){ (const uint8_t *)"return ", sizeof("return ") - 1 }; str__ptr(&__sc519); })));
    codegen__codegen__Codegen__emit_expr(self, v0);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc520 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc520); })));
    return;
  }
  ({ String__Global *__sc521 = &(self->buf);
String__Global__push_str(&(*__sc521), (str){ .ptr = (const uint8_t*)"return (", .len = sizeof("return (") - 1 });
String__Global__push_str(&(*__sc521), utils__errors__cstr(crp));
String__Global__push_str(&(*__sc521), (str){ .ptr = (const uint8_t*)"){ ", .len = sizeof("){ ") - 1 });
});
  for (uint32_t i = 0U; i < vals.len; i++) {
    if (i != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc522 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc522); })));
    }
    codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), vals)[((size_t)i)]);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc523 = (str){ (const uint8_t *)" };\n", sizeof(" };\n") - 1 }; str__ptr(&__sc523); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_loop_body_tail(codegen__codegen__Codegen *const self, uint32_t const dbase, int32_t const le) {
  codegen__codegen__Codegen__emit_defers_to(self, dbase);
  (self->defer_top = dbase);
  if ((le >= 0) && self->loop_stack[((size_t)le)].used_cnt) {
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc524 = &(self->buf);
String__Global__push_str(&(*__sc524), (str){ .ptr = (const uint8_t*)"__cnt", .len = sizeof("__cnt") - 1 });
String__Global__push_u64(&(*__sc524), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc524), (str){ .ptr = (const uint8_t*)":;\n", .len = sizeof(":;\n") - 1 });
});
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_for_range(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__ForData fs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.for_stmt;
  const ast__ast__PatternRangeData r = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable)->as_data.pattern_range;
  const uint32_t lo = r.start;
  const uint32_t hi = r.end;
  const lexer__token__Span name = codegen__codegen__Codegen__name_span(self, fs.binding);
  codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
  codegen__codegen__Codegen__render_ident(self, name, ((char *)(&nm.b[0])), 128ULL);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc525 = (str){ (const uint8_t *)"for (", sizeof("for (") - 1 }; str__ptr(&__sc525); })));
  codegen__codegen__Codegen__emit_binding(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable), name, false);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc526 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc526); })));
  if (lo != ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__emit_expr(self, lo);
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc527 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc527); })));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc528 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc528); })));
  if (hi != ast__ast__NODE_NONE) {
    const char *cmp = ((const char *)({ __auto_type __sc529 = (str){ (const uint8_t *)"<", sizeof("<") - 1 }; str__ptr(&__sc529); }));
    if (r.inclusive) {
      (cmp = ((const char *)({ __auto_type __sc530 = (str){ (const uint8_t *)"<=", sizeof("<=") - 1 }; str__ptr(&__sc530); })));
    }
    ({ String__Global *__sc531 = &(self->buf);
String__Global__push_str(&(*__sc531), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc531), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc531), utils__errors__cstr(cmp));
String__Global__push_str(&(*__sc531), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, hi);
  }
  ({ String__Global *__sc532 = &(self->buf);
String__Global__push_str(&(*__sc532), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc532), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc532), (str){ .ptr = (const uint8_t*)"++) ", .len = sizeof("++) ") - 1 });
});
  (self->pending_cnt = ((uint32_t)({ int32_t __sc_r; if (__builtin_add_overflow(codegen__codegen__Codegen__cg_loop_find(self, id), 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
  codegen__codegen__Codegen__emit_block(self, fs.body);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc533 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc533); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_for(codegen__codegen__Codegen *const self, uint32_t const id) {
  const int32_t le = codegen__codegen__Codegen__cg_loop_find(self, id);
  const ast__ast__ForData fs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.for_stmt;
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable)->kind == ast__ast__NodeKind_NODE_RANGE) {
    codegen__codegen__Codegen__emit_for_range(self, id);
    return;
  }
  const ast__ast__Ty ity = (*codegen__codegen__Codegen__type_at(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable)));
  const uint32_t body = fs.body;
  const ast__ast__NodeList stmts = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), body)->as_data.block.statements;
  codegen__codegen__Buf32 idx = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&idx.b[0])), 32ULL);
  if (ity.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    const uint32_t len = codegen__codegen__Codegen__array_length_of(self, fs.iterable);
    ({ String__Global *__sc534 = &(self->buf);
String__Global__push_str(&(*__sc534), (str){ .ptr = (const uint8_t*)"for (size_t ", .len = sizeof("for (size_t ") - 1 });
String__Global__push_str(&(*__sc534), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc534), (str){ .ptr = (const uint8_t*)" = 0; ", .len = sizeof(" = 0; ") - 1 });
String__Global__push_str(&(*__sc534), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc534), (str){ .ptr = (const uint8_t*)" < ", .len = sizeof(" < ") - 1 });
});
    if (len != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_expr(self, len);
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc535 = (str){ (const uint8_t *)"sizeof(", sizeof("sizeof(") - 1 }; str__ptr(&__sc535); })));
      codegen__codegen__Codegen__emit_expr(self, fs.iterable);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc536 = (str){ (const uint8_t *)")/sizeof((", sizeof(")/sizeof((") - 1 }; str__ptr(&__sc536); })));
      codegen__codegen__Codegen__emit_expr(self, fs.iterable);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc537 = (str){ (const uint8_t *)")[0])", sizeof(")[0])") - 1 }; str__ptr(&__sc537); })));
    }
    ({ String__Global *__sc538 = &(self->buf);
String__Global__push_str(&(*__sc538), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc538), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc538), (str){ .ptr = (const uint8_t*)"++) {\n", .len = sizeof("++) {\n") - 1 });
});
    (self->depth = (self->depth + 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_binding(self, ity.as_data.arr.elem, codegen__codegen__Codegen__name_span(self, fs.binding), true);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc539 = (str){ (const uint8_t *)" = (", sizeof(" = (") - 1 }; str__ptr(&__sc539); })));
    codegen__codegen__Codegen__emit_expr(self, fs.iterable);
    ({ String__Global *__sc540 = &(self->buf);
String__Global__push_str(&(*__sc540), (str){ .ptr = (const uint8_t*)")[", .len = sizeof(")[") - 1 });
String__Global__push_str(&(*__sc540), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc540), (str){ .ptr = (const uint8_t*)"];\n", .len = sizeof("];\n") - 1 });
});
    const uint32_t dbase = self->defer_top;
    for (uint32_t i = 0U; i < stmts.len; i++) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_stmt(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)]);
    }
    codegen__codegen__Codegen__cg_loop_body_tail(self, dbase, le);
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc541 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc541); })));
    return;
  }
  uint32_t selem = ast__ast__TYPE_NONE;
  if (codegen__codegen__Codegen__cg_slice_elem(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable), ((uint32_t *)(&selem)))) {
    codegen__codegen__Buf32 s = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&s.b[0])), 32ULL);
    codegen__codegen__Buf256 styp = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable), ((const char *)(&s.b[0])), ((char *)(&styp.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc542 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc542); })));
    (self->depth = (self->depth + 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&styp.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc543 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc543); })));
    codegen__codegen__Codegen__emit_expr(self, fs.iterable);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc544 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc544); })));
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc545 = &(self->buf);
String__Global__push_str(&(*__sc545), (str){ .ptr = (const uint8_t*)"for (size_t ", .len = sizeof("for (size_t ") - 1 });
String__Global__push_str(&(*__sc545), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc545), (str){ .ptr = (const uint8_t*)" = 0; ", .len = sizeof(" = 0; ") - 1 });
String__Global__push_str(&(*__sc545), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc545), (str){ .ptr = (const uint8_t*)" < ", .len = sizeof(" < ") - 1 });
String__Global__push_str(&(*__sc545), utils__errors__cstr(((const char *)(&s.b[0]))));
String__Global__push_str(&(*__sc545), (str){ .ptr = (const uint8_t*)".len; ", .len = sizeof(".len; ") - 1 });
String__Global__push_str(&(*__sc545), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc545), (str){ .ptr = (const uint8_t*)"++) {\n", .len = sizeof("++) {\n") - 1 });
});
    (self->depth = (self->depth + 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_binding(self, selem, codegen__codegen__Codegen__name_span(self, fs.binding), true);
    ({ String__Global *__sc546 = &(self->buf);
String__Global__push_str(&(*__sc546), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc546), utils__errors__cstr(((const char *)(&s.b[0]))));
String__Global__push_str(&(*__sc546), (str){ .ptr = (const uint8_t*)".ptr[", .len = sizeof(".ptr[") - 1 });
String__Global__push_str(&(*__sc546), utils__errors__cstr(((const char *)(&idx.b[0]))));
String__Global__push_str(&(*__sc546), (str){ .ptr = (const uint8_t*)"];\n", .len = sizeof("];\n") - 1 });
});
    const uint32_t dbase = self->defer_top;
    for (uint32_t i = 0U; i < stmts.len; i++) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_stmt(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)]);
    }
    codegen__codegen__Codegen__cg_loop_body_tail(self, dbase, le);
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc547 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc547); })));
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc548 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc548); })));
    return;
  }
  uint32_t relem = ast__ast__TYPE_NONE;
  if (codegen__codegen__Codegen__cg_range_elem(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable), ((uint32_t *)(&relem)))) {
    codegen__codegen__Buf32 rr = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&rr.b[0])), 32ULL);
    codegen__codegen__Buf256 styp = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable), ((const char *)(&rr.b[0])), ((char *)(&styp.b[0])), 200ULL);
    codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
    codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, fs.binding), ((char *)(&nm.b[0])), 128ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc549 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc549); })));
    (self->depth = (self->depth + 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&styp.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc550 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc550); })));
    codegen__codegen__Codegen__emit_expr(self, fs.iterable);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc551 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc551); })));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc552 = (str){ (const uint8_t *)"for (", sizeof("for (") - 1 }; str__ptr(&__sc552); })));
    codegen__codegen__Codegen__emit_binding(self, relem, codegen__codegen__Codegen__name_span(self, fs.binding), false);
    ({ String__Global *__sc553 = &(self->buf);
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&rr.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)".start; ", .len = sizeof(".start; ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&rr.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)".inclusive ? ", .len = sizeof(".inclusive ? ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)" <= ", .len = sizeof(" <= ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&rr.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)".end : ", .len = sizeof(".end : ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)" < ", .len = sizeof(" < ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&rr.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)".end; ", .len = sizeof(".end; ") - 1 });
String__Global__push_str(&(*__sc553), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc553), (str){ .ptr = (const uint8_t*)"++) {\n", .len = sizeof("++) {\n") - 1 });
});
    (self->depth = (self->depth + 1U));
    const uint32_t dbase = self->defer_top;
    for (uint32_t i = 0U; i < stmts.len; i++) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_stmt(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)]);
    }
    codegen__codegen__Codegen__cg_loop_body_tail(self, dbase, le);
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc554 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc554); })));
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc555 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc555); })));
    return;
  }
  const ast__ast__Ty bt = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fs.iterable))));
  uint16_t om = 0U;
  uint32_t od = ast__ast__NODE_NONE;
  if (bt.kind == ast__ast__TypeKind_TYPE_STRUCT) {
    (om = bt.module);
    (od = bt.as_data.decl);
  } else if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance ii = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst));
    (om = ii.module);
    (od = ii.decl);
  }
  ast__ast__DefId nx = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  if (od != ast__ast__NODE_NONE) {
    (nx = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc556 = (str){ (const uint8_t *)"next", sizeof("next") - 1 }; str__ptr(&__sc556); }))));
  }
  if (nx.node != ast__ast__NODE_NONE) {
    ast__ast__Ast *const na = codegen__codegen__Codegen__mod_ast(self, nx.module);
    const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*na)), nx.node)->as_data.function.returns;
    const uint32_t r0 = ast__ast__Ast__list(&((*na)), rets)[0];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*na)), r0);
    const ast__ast__DefId opt = ast__ast__Ast__resolution_def(&((*na)), codegen__codegen__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0));
    const uint32_t elem = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
    if ((opt.node != ast__ast__NODE_NONE) && (elem != ast__ast__TYPE_NONE)) {
      ast__ast__Ast *const oa = codegen__codegen__Codegen__mod_ast(self, opt.module);
      const ast__ast__NodeList mem = ast__ast__Ast__at_const(&((*oa)), opt.node)->as_data.aggregate.members;
      uint32_t some = ast__ast__NODE_NONE;
      uint32_t none2 = ast__ast__NODE_NONE;
      uint32_t i = 0U;
      while (i < mem.len) {
        const uint32_t vid = ast__ast__Ast__list(&((*oa)), mem)[((size_t)i)];
        const ast__ast__Node *const v = ast__ast__Ast__at_const(&((*oa)), vid);
        if (v->kind == ast__ast__NodeKind_NODE_VARIANT) {
          const lexer__token__Span vs = ast__ast__Ast__at_const(&((*oa)), v->as_data.variant.name)->as_data.name.text;
          if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, opt.module), vs, ((const char *)({ __auto_type __sc557 = (str){ (const uint8_t *)"Some", sizeof("Some") - 1 }; str__ptr(&__sc557); })))) {
            (some = vid);
          } else if (codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, opt.module), vs, ((const char *)({ __auto_type __sc558 = (str){ (const uint8_t *)"None", sizeof("None") - 1 }; str__ptr(&__sc558); })))) {
            (none2 = vid);
          }
        }
        (i = (i + 1U));
      }
      if ((some != ast__ast__NODE_NONE) && (none2 != ast__ast__NODE_NONE)) {
        const uint32_t optTy = ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), opt.module, opt.node, ((const uint32_t *)(&elem)), 1U);
        codegen__codegen__Buf32 itn = (codegen__codegen__Buf32){0};
        codegen__codegen__Buf32 ov = (codegen__codegen__Buf32){0};
        codegen__codegen__Codegen__fresh(self, ((char *)(&itn.b[0])), 32ULL);
        codegen__codegen__Codegen__fresh(self, ((char *)(&ov.b[0])), 32ULL);
        codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
        codegen__codegen__Codegen__render_variant_name(self, opt.module, some, ((char *)(&vn.b[0])), 128ULL);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc559 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc559); })));
        (self->depth = (self->depth + 1U));
        codegen__codegen__Codegen__emit_indent(self);
        ({ String__Global *__sc560 = &(self->buf);
String__Global__push_str(&(*__sc560), (str){ .ptr = (const uint8_t*)"__auto_type ", .len = sizeof("__auto_type ") - 1 });
String__Global__push_str(&(*__sc560), utils__errors__cstr(((const char *)(&itn.b[0]))));
String__Global__push_str(&(*__sc560), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, fs.iterable);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc561 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc561); })));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc562 = (str){ (const uint8_t *)"for (;;) {\n", sizeof("for (;;) {\n") - 1 }; str__ptr(&__sc562); })));
        (self->depth = (self->depth + 1U));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Buf256 odecl = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_id(self, optTy, ((const char *)(&ov.b[0])), ((char *)(&odecl.b[0])), 256ULL);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&odecl.b[0])));
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc563 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc563); })));
        if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
          codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
          codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
          codegen__codegen__Codegen__emit_paste(self);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc564 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc564); })));
        } else {
          codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
          codegen__codegen__Codegen__render_modpfx(self, nx.module, ((char *)(&pfx.b[0])), 64ULL);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
          codegen__codegen__Codegen__emit_ident_mod(self, om, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, om))), od)->as_data.aggregate.name);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc565 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc565); })));
        }
        codegen__codegen__Codegen__emit_ident_mod(self, nx.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, nx.module))), nx.node)->as_data.function.name);
        ({ String__Global *__sc566 = &(self->buf);
String__Global__push_str(&(*__sc566), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc566), utils__errors__cstr(((const char *)(&itn.b[0]))));
String__Global__push_str(&(*__sc566), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
        codegen__codegen__Codegen__emit_indent(self);
        ({ String__Global *__sc567 = &(self->buf);
String__Global__push_str(&(*__sc567), (str){ .ptr = (const uint8_t*)"if (", .len = sizeof("if (") - 1 });
String__Global__push_str(&(*__sc567), utils__errors__cstr(((const char *)(&ov.b[0]))));
String__Global__push_str(&(*__sc567), (str){ .ptr = (const uint8_t*)".tag == ", .len = sizeof(".tag == ") - 1 });
});
        codegen__codegen__Codegen__emit_tag_mod(self, opt.module, opt.node, none2);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc568 = (str){ (const uint8_t *)") break;\n", sizeof(") break;\n") - 1 }; str__ptr(&__sc568); })));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_binding(self, elem, codegen__codegen__Codegen__name_span(self, fs.binding), true);
        ({ String__Global *__sc569 = &(self->buf);
String__Global__push_str(&(*__sc569), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc569), utils__errors__cstr(((const char *)(&ov.b[0]))));
String__Global__push_str(&(*__sc569), (str){ .ptr = (const uint8_t*)".payload.", .len = sizeof(".payload.") - 1 });
String__Global__push_str(&(*__sc569), utils__errors__cstr(((const char *)(&vn.b[0]))));
String__Global__push_str(&(*__sc569), (str){ .ptr = (const uint8_t*)"._0;\n", .len = sizeof("._0;\n") - 1 });
});
        const uint32_t dbase = self->defer_top;
        (i = 0U);
        while (i < stmts.len) {
          codegen__codegen__Codegen__emit_indent(self);
          codegen__codegen__Codegen__emit_stmt(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)]);
          (i = (i + 1U));
        }
        codegen__codegen__Codegen__cg_loop_body_tail(self, dbase, le);
        (self->depth = (self->depth - 1U));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc570 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc570); })));
        (self->depth = (self->depth - 1U));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc571 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc571); })));
        return;
      }
    }
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->span;
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc572 = String__Global__new();
String__Global__push_str(&__sc572, (str){ .ptr = (const uint8_t*)"codegen: cannot iterate over a non-array/slice value", .len = sizeof("codegen: cannot iterate over a non-array/slice value") - 1 });
__sc572; }));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_initializer(codegen__codegen__Codegen *const self, uint32_t const tn, uint32_t const val) {
  if (((ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), val)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) && (tn != ast__ast__NODE_NONE)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), tn)->kind == ast__ast__NodeKind_NODE_ARRAY_TYPE)) {
    codegen__codegen__Codegen__emit_array_braces(self, val);
  } else {
    codegen__codegen__Codegen__emit_expr(self, val);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_binding_id(codegen__codegen__Codegen *const self, uint32_t const t, const char *const name, bool const is_const, char *const out, size_t const cap) {
  const ast__ast__TypeKind k = codegen__codegen__Codegen__type_at(self, t)->kind;
  if (is_const && ((k == ast__ast__TypeKind_TYPE_POINTER) || (k == ast__ast__TypeKind_TYPE_REFERENCE))) {
    codegen__codegen__Buf256 cn = (codegen__codegen__Buf256){0};
    codegen__codegen__buf_join3(((char *)(&cn.b[0])), 200ULL, ((const char *)({ __auto_type __sc573 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc573); })), ((const char *)({ __auto_type __sc574 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc574); })), name);
    codegen__codegen__Codegen__render_type_id(self, t, ((const char *)(&cn.b[0])), out, cap);
  } else if (is_const) {
    codegen__codegen__Buf512 body = (codegen__codegen__Buf512){0};
    codegen__codegen__Codegen__render_type_id(self, t, name, ((char *)(&body.b[0])), 512ULL);
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc575 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc575); })), ((const char *)({ __auto_type __sc576 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc576); })), ((const char *)(&body.b[0])));
  } else {
    codegen__codegen__Codegen__render_type_id(self, t, name, out, cap);
  }
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_arm_frees(codegen__codegen__Codegen *const self, uint32_t const pid, bool const do_emit) {
  const ast__ast__Node p = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid));
  const ast__ast__NodeKind pk = p.kind;
  if ((pk == ast__ast__NodeKind_NODE_PATTERN_NAME) || (pk == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    lexer__token__Span nm = p.as_data.name.text;
    if (pk == ast__ast__NodeKind_NODE_PATTERN_NAME) {
      (nm = codegen__codegen__Codegen__name_span(self, p.as_data.pattern.name));
      const ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name);
      if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
        return 0;
      }
    }
    const uint32_t t = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), pid);
    if (((!codegen__codegen__Codegen__cg_type_is_free(self, t)) || codegen__codegen__Codegen__cg_is_moved(self, pid)) || codegen__codegen__Codegen__cg_is_cond_moved(self, pid)) {
      return 0;
    }
    if (do_emit) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_free_target(self, t);
      codegen__codegen__Buf128 b = (codegen__codegen__Buf128){0};
      codegen__codegen__Codegen__render_ident(self, nm, ((char *)(&b.b[0])), 128ULL);
      ({ String__Global *__sc577 = &(self->buf);
String__Global__push_str(&(*__sc577), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc577), utils__errors__cstr(((const char *)(&b.b[0]))));
String__Global__push_str(&(*__sc577), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
    }
    return 1;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
    const ast__ast__NodeList ch = p.as_data.pattern.children;
    int32_t nn = 0;
    for (uint32_t i = 0U; i < ch.len; i++) {
      (nn = ({ int32_t __sc_r; if (__builtin_add_overflow(nn, codegen__codegen__Codegen__cg_arm_frees(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[((size_t)i)], do_emit), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
    return nn;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_STRUCT) {
    const ast__ast__NodeList ch = p.as_data.pattern.children;
    int32_t nn = 0;
    for (uint32_t i = 0U; i < ch.len; i++) {
      const ast__ast__NodeList sub = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[((size_t)i)])->as_data.pattern.children;
      if (sub.len != 0U) {
        (nn = ({ int32_t __sc_r; if (__builtin_add_overflow(nn, codegen__codegen__Codegen__cg_arm_frees(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), sub)[0], do_emit), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
    }
    return nn;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList alts = p.as_data.pattern.children;
    if (alts.len != 0U) {
      return codegen__codegen__Codegen__cg_arm_frees(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), alts)[0], do_emit);
    }
    return 0;
  }
  return 0;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_arm_body(codegen__codegen__Codegen *const self, uint32_t const body, int32_t const mode, const char *const result, uint32_t const pattern, bool const by_ref) {
  const uint32_t bt0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), body);
  if ((bt0 != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, bt0)->kind == ast__ast__TypeKind_TYPE_NEVER)) {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_expr(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc578 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc578); })));
    return;
  }
  int32_t frees = 0;
  if (!by_ref) {
    (frees = codegen__codegen__Codegen__cg_arm_frees(self, pattern, false));
  }
  if (mode == 2) {
    codegen__codegen__Codegen__emit_indent(self);
    if (frees == 0) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc579 = (str){ (const uint8_t *)"return ", sizeof("return ") - 1 }; str__ptr(&__sc579); })));
      codegen__codegen__Codegen__emit_expr(self, body);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc580 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc580); })));
      return;
    }
    const uint32_t rt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), body);
    bool voidret = (rt == ast__ast__TYPE_NONE);
    if (rt != ast__ast__TYPE_NONE) {
      (voidret = ((codegen__codegen__Codegen__type_at(self, rt)->kind == ast__ast__TypeKind_TYPE_BUILTIN) && (codegen__codegen__Codegen__type_at(self, rt)->as_data.builtin == ast__ast__BuiltinType_BT_VOID)));
    }
    codegen__codegen__Buf32 r = (codegen__codegen__Buf32){0};
    if (voidret) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc581 = (str){ (const uint8_t *)"{ ", sizeof("{ ") - 1 }; str__ptr(&__sc581); })));
      codegen__codegen__Codegen__emit_expr(self, body);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc582 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc582); })));
    } else {
      codegen__codegen__Codegen__fresh(self, ((char *)(&r.b[0])), 32ULL);
      ({ String__Global *__sc583 = &(self->buf);
String__Global__push_str(&(*__sc583), (str){ .ptr = (const uint8_t*)"{ __auto_type ", .len = sizeof("{ __auto_type ") - 1 });
String__Global__push_str(&(*__sc583), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc583), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, body);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc584 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc584); })));
    }
    codegen__codegen__Codegen__cg_arm_frees(self, pattern, true);
    codegen__codegen__Codegen__emit_indent(self);
    if (voidret) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc585 = (str){ (const uint8_t *)"return; }\n", sizeof("return; }\n") - 1 }; str__ptr(&__sc585); })));
    } else {
      ({ String__Global *__sc586 = &(self->buf);
String__Global__push_str(&(*__sc586), (str){ .ptr = (const uint8_t*)"return ", .len = sizeof("return ") - 1 });
String__Global__push_str(&(*__sc586), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc586), (str){ .ptr = (const uint8_t*)"; }\n", .len = sizeof("; }\n") - 1 });
});
    }
    return;
  }
  if (mode == 1) {
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc587 = &(self->buf);
String__Global__push_str(&(*__sc587), utils__errors__cstr(result));
String__Global__push_str(&(*__sc587), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc588 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc588); })));
  } else if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), body)->kind == ast__ast__NodeKind_NODE_BLOCK) {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_block(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc589 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc589); })));
  } else if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), body)->kind == ast__ast__NodeKind_NODE_MATCH) {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_match_stmt(self, body);
  } else if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), body)->kind == ast__ast__NodeKind_NODE_IF) {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_if(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc590 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc590); })));
  } else {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_expr(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc591 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc591); })));
  }
  if (frees != 0) {
    codegen__codegen__Codegen__cg_arm_frees(self, pattern, true);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_match_core(codegen__codegen__Codegen *const self, uint32_t const id, int32_t const mode, const char *const result) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  codegen__codegen__Buf32 scrut = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&scrut.b[0])), 32ULL);
  const uint32_t outer = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.match_expr.value);
  uint32_t derefs = 0U;
  uint32_t base = outer;
  const ast__ast__Ty *y = codegen__codegen__Codegen__type_at(self, base);
  while ((y->kind == ast__ast__TypeKind_TYPE_POINTER) || (y->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    (base = y->as_data.elem);
    (derefs = (derefs + 1U));
    (y = codegen__codegen__Codegen__type_at(self, base));
  }
  const bool by_ref = (derefs > 0U);
  bool mut_ref = false;
  if (by_ref) {
    (mut_ref = (codegen__codegen__Codegen__type_at(self, outer)->qualifier == 2U));
  }
  const ast__ast__TypeKind bk = codegen__codegen__Codegen__type_at(self, base)->kind;
  codegen__codegen__Buf64 access = (codegen__codegen__Buf64){0};
  codegen__codegen__Codegen__emit_indent(self);
  if (by_ref) {
    codegen__codegen__Buf256 aggr = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, base, ((const char *)({ __auto_type __sc592 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc592); })), ((char *)(&aggr.b[0])), 256ULL);
    const char *cq = ((const char *)({ __auto_type __sc593 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc593); }));
    if (mut_ref) {
      (cq = ((const char *)({ __auto_type __sc594 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc594); })));
    }
    ({ String__Global *__sc595 = &(self->buf);
String__Global__push_str(&(*__sc595), utils__errors__cstr(cq));
String__Global__push_str(&(*__sc595), utils__errors__cstr(((const char *)(&aggr.b[0]))));
String__Global__push_str(&(*__sc595), (str){ .ptr = (const uint8_t*)" *const ", .len = sizeof(" *const ") - 1 });
String__Global__push_str(&(*__sc595), utils__errors__cstr(((const char *)(&scrut.b[0]))));
String__Global__push_str(&(*__sc595), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    uint32_t i = 0U;
    while ((i + 1U) < derefs) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc596 = (str){ (const uint8_t *)"(*", sizeof("(*") - 1 }; str__ptr(&__sc596); })));
      (i = (i + 1U));
    }
    codegen__codegen__Codegen__emit_expr(self, n.as_data.match_expr.value);
    (i = 0U);
    while ((i + 1U) < derefs) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc597 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc597); })));
      (i = (i + 1U));
    }
    snprintf(((char *)(&access.b[0])), 40ULL, ((const char *)({ __auto_type __sc598 = (str){ (const uint8_t *)"(*%s)", sizeof("(*%s)") - 1 }; str__ptr(&__sc598); })), ((const char *)(&scrut.b[0])));
  } else if (((bk == ast__ast__TypeKind_TYPE_ERROR) || (bk == ast__ast__TypeKind_TYPE_FUNCTION)) || (bk == ast__ast__TypeKind_TYPE_GENERIC)) {
    ({ String__Global *__sc599 = &(self->buf);
String__Global__push_str(&(*__sc599), (str){ .ptr = (const uint8_t*)"const __auto_type ", .len = sizeof("const __auto_type ") - 1 });
String__Global__push_str(&(*__sc599), utils__errors__cstr(((const char *)(&scrut.b[0]))));
String__Global__push_str(&(*__sc599), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, n.as_data.match_expr.value);
    snprintf(((char *)(&access.b[0])), 40ULL, ((const char *)({ __auto_type __sc600 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc600); })), ((const char *)(&scrut.b[0])));
  } else {
    codegen__codegen__Buf512 d = (codegen__codegen__Buf512){0};
    codegen__codegen__Codegen__render_binding_id(self, base, ((const char *)(&scrut.b[0])), true, ((char *)(&d.b[0])), 300ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&d.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc601 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc601); })));
    codegen__codegen__Codegen__emit_expr(self, n.as_data.match_expr.value);
    snprintf(((char *)(&access.b[0])), 40ULL, ((const char *)({ __auto_type __sc602 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc602); })), ((const char *)(&scrut.b[0])));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc603 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc603); })));
  const char *const accp = ((const char *)(&access.b[0]));
  const ast__ast__NodeList arms = n.as_data.match_expr.arms;
  bool has_guard = false;
  uint32_t i = 0U;
  while (i < arms.len) {
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), arms)[((size_t)i)])->as_data.match_arm.guard != ast__ast__NODE_NONE) {
      (has_guard = true);
    }
    (i = (i + 1U));
  }
  if (!has_guard) {
    (i = 0U);
    while (i < arms.len) {
      const ast__ast__MatchArmData arm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), arms)[((size_t)i)])->as_data.match_arm;
      codegen__codegen__Codegen__emit_indent(self);
      if (i != 0U) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc604 = (str){ (const uint8_t *)"else if (", sizeof("else if (") - 1 }; str__ptr(&__sc604); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc605 = (str){ (const uint8_t *)"if (", sizeof("if (") - 1 }; str__ptr(&__sc605); })));
      }
      codegen__codegen__Codegen__emit_pattern_test(self, arm.pattern, accp);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc606 = (str){ (const uint8_t *)") {\n", sizeof(") {\n") - 1 }; str__ptr(&__sc606); })));
      (self->depth = (self->depth + 1U));
      codegen__codegen__Codegen__emit_pattern_binds(self, arm.pattern, accp, by_ref);
      codegen__codegen__Codegen__emit_arm_body(self, arm.body, mode, result, arm.pattern, by_ref);
      (self->depth = (self->depth - 1U));
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc607 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc607); })));
      (i = (i + 1U));
    }
    if ((mode != 0) && (arms.len > 0U)) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc608 = (str){ (const uint8_t *)"else { __builtin_unreachable(); }\n", sizeof("else { __builtin_unreachable(); }\n") - 1 }; str__ptr(&__sc608); })));
    }
    return;
  }
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc609 = (str){ (const uint8_t *)"do {\n", sizeof("do {\n") - 1 }; str__ptr(&__sc609); })));
  (self->depth = (self->depth + 1U));
  (i = 0U);
  while (i < arms.len) {
    const ast__ast__MatchArmData arm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), arms)[((size_t)i)])->as_data.match_arm;
    const uint32_t guard = arm.guard;
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc610 = (str){ (const uint8_t *)"if (", sizeof("if (") - 1 }; str__ptr(&__sc610); })));
    codegen__codegen__Codegen__emit_pattern_test(self, arm.pattern, accp);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc611 = (str){ (const uint8_t *)") {\n", sizeof(") {\n") - 1 }; str__ptr(&__sc611); })));
    (self->depth = (self->depth + 1U));
    codegen__codegen__Codegen__emit_pattern_binds(self, arm.pattern, accp, by_ref);
    if (guard != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc612 = (str){ (const uint8_t *)"if (", sizeof("if (") - 1 }; str__ptr(&__sc612); })));
      codegen__codegen__Codegen__emit_condition(self, guard);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc613 = (str){ (const uint8_t *)") {\n", sizeof(") {\n") - 1 }; str__ptr(&__sc613); })));
      (self->depth = (self->depth + 1U));
    }
    codegen__codegen__Codegen__emit_arm_body(self, arm.body, mode, result, arm.pattern, by_ref);
    if (mode != 2) {
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc614 = (str){ (const uint8_t *)"break;\n", sizeof("break;\n") - 1 }; str__ptr(&__sc614); })));
    }
    if (guard != ast__ast__NODE_NONE) {
      (self->depth = (self->depth - 1U));
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc615 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc615); })));
    }
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc616 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc616); })));
    (i = (i + 1U));
  }
  if (mode != 0) {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc617 = (str){ (const uint8_t *)"__builtin_unreachable();\n", sizeof("__builtin_unreachable();\n") - 1 }; str__ptr(&__sc617); })));
  }
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc618 = (str){ (const uint8_t *)"} while (0);\n", sizeof("} while (0);\n") - 1 }; str__ptr(&__sc618); })));
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_enum_variant(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const enumDecl, const char *const lit) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__Node *const e = ast__ast__Ast__at_const(&((*a)), enumDecl);
  if (e->kind != ast__ast__NodeKind_NODE_ENUM) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__NodeList ms = e->as_data.aggregate.members;
  for (uint32_t i = 0U; i < ms.len; i++) {
    const uint32_t vid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
    const ast__ast__Node *const v = ast__ast__Ast__at_const(&((*a)), vid);
    if ((v->kind == ast__ast__NodeKind_NODE_VARIANT) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, m), ast__ast__Ast__at_const(&((*a)), v->as_data.variant.name)->as_data.name.text, lit)) {
      return vid;
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__cg_method_extend_target(const codegen__codegen__Codegen *const self, ast__ast__DefId const md) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, md.module);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
    if (it->kind == ast__ast__NodeKind_NODE_EXTEND) {
      const ast__ast__NodeList ms = it->as_data.extend_def.items;
      for (uint32_t j = 0U; j < ms.len; j++) {
        if (ast__ast__Ast__list(&((*a)), ms)[((size_t)j)] == md.node) {
          return ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type);
        }
      }
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_will_auto_free(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  if ((n->kind == ast__ast__NodeKind_NODE_LET) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.let_stmt.name)->kind == ast__ast__NodeKind_NODE_PATTERN_TUPLE)) {
    return false;
  }
  if (codegen__codegen__Codegen__cg_is_moved(self, id)) {
    return false;
  }
  return codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_register_auto_free(codegen__codegen__Codegen *const self, uint32_t const id) {
  if (self->defer_top >= 256U) {
    return;
  }
  const uint32_t t = self->defer_top;
  (self->defer_stack[((size_t)t)] = id);
  (self->defer_kind[((size_t)t)] = 1U);
  (self->defer_top = (t + 1U));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_capture_init(codegen__codegen__Codegen *const self, uint32_t const clos, uint32_t const idx) {
  const ast__ast__NodeList caps = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), clos)->as_data.closure.captures;
  const uint64_t mut_caps = ((uint64_t)ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), clos)->as_data.closure.mut_caps);
  const uint32_t decl = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), caps)[((size_t)idx)];
  const bool want_ptr = ((({ uint64_t __sc619 = mut_caps; int64_t __sc620 = (int64_t)(((uint64_t)idx)); if ((uint64_t)__sc620 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc619 >> __sc620); }) & 1ULL) != 0ULL);
  codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
  const lexer__token__Span csp = codegen__codegen__Codegen__cg_decl_name_span(self, decl);
  codegen__codegen__Codegen__render_ident(self, csp, ((char *)(&nm.b[0])), 128ULL);
  ({ String__Global *__sc621 = &(self->buf);
String__Global__push_str(&(*__sc621), (str){ .ptr = (const uint8_t*)".", .len = sizeof(".") - 1 });
String__Global__push_str(&(*__sc621), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc621), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  bool outer_mut = false;
  const int32_t oi = codegen__codegen__Codegen__cg_env_capture(self, decl, ((bool *)(&outer_mut)));
  if (want_ptr) {
    if ((oi >= 0) && outer_mut) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc622 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc622); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc623 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc623); })));
    }
  } else if ((oi >= 0) && outer_mut) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc624 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc624); })));
  }
  if (oi >= 0) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc625 = (str){ (const uint8_t *)"__env->", sizeof("__env->") - 1 }; str__ptr(&__sc625); })));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_mark_move(codegen__codegen__Codegen *const self, uint32_t const expr0, bool const cond, int32_t const pass, bool const site) {
  if (expr0 == ast__ast__NODE_NONE) {
    return;
  }
  uint32_t expr = expr0;
  bool go = true;
  while (go) {
    const ast__ast__Node *const me = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), expr);
    if ((me->kind == ast__ast__NodeKind_NODE_UNARY) && ((me->as_data.unary.op == lexer__token_type__TokenType_Move) || (me->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (expr = me->as_data.unary.operand);
    } else {
      (go = false);
    }
  }
  const ast__ast__NodeKind mek = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), expr)->kind;
  if (mek == ast__ast__NodeKind_NODE_MEMBER) {
    const bool is_path = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), expr)->as_data.member.path;
    const uint32_t obj = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), expr)->as_data.member.object;
    if ((!is_path) && codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), expr))) {
      codegen__codegen__Codegen__cg_mark_move(self, obj, cond, pass, false);
      return;
    }
  }
  if (mek != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), expr);
  if ((d.module != codegen__codegen__Codegen__cur_module(self)) || (d.node == ast__ast__NODE_NONE)) {
    return;
  }
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), d.node)->kind;
  bool tuple_elem = false;
  if (dk == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const uint32_t letid = ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), d.node);
    if ((letid != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), letid)->kind == ast__ast__NodeKind_NODE_LET)) {
      const uint32_t lname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), letid)->as_data.let_stmt.name;
      if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lname)->kind == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
        (tuple_elem = true);
      }
    }
  }
  if ((((dk != ast__ast__NodeKind_NODE_LET) && (dk != ast__ast__NodeKind_NODE_PARAMETER)) && (dk != ast__ast__NodeKind_NODE_PATTERN_NAME)) && (!tuple_elem)) {
    return;
  }
  if (!codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), expr))) {
    return;
  }
  if (pass == 0) {
    if (((!cond) || (dk == ast__ast__NodeKind_NODE_PATTERN_NAME)) && (self->nmoved < 512U)) {
      (self->moved[((size_t)self->nmoved)] = d.node);
      (self->nmoved = (self->nmoved + 1U));
    }
    return;
  }
  if (dk == ast__ast__NodeKind_NODE_PATTERN_NAME) {
    return;
  }
  if ((!cond) || codegen__codegen__Codegen__cg_is_moved(self, d.node)) {
    return;
  }
  if ((!codegen__codegen__Codegen__cg_is_cond_moved(self, d.node)) && (self->ncond_moved < 256U)) {
    (self->cond_moved[((size_t)self->ncond_moved)] = d.node);
    (self->ncond_moved = (self->ncond_moved + 1U));
  }
  if (site && (self->ncond_sites < 256U)) {
    (self->cond_sites[((size_t)self->ncond_sites)] = expr);
    (self->ncond_sites = (self->ncond_sites + 1U));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_mark_move_tail(codegen__codegen__Codegen *const self, uint32_t const e, bool const cond, int32_t const pass) {
  if (e == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), e)->kind;
  if (nk == ast__ast__NodeKind_NODE_MATCH) {
    const ast__ast__NodeList arms = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), e)->as_data.match_expr.arms;
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), arms);
    for (uint32_t i = 0U; i < arms.len; i++) {
      const uint32_t body = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ids[((size_t)i)])->as_data.match_arm.body;
      codegen__codegen__Codegen__cg_mark_move_tail(self, body, true, pass);
    }
  } else if (nk == ast__ast__NodeKind_NODE_IF) {
    const uint32_t tb = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), e)->as_data.if_stmt.then_branch;
    const uint32_t eb = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), e)->as_data.if_stmt.else_branch;
    codegen__codegen__Codegen__cg_mark_move_tail(self, tb, true, pass);
    codegen__codegen__Codegen__cg_mark_move_tail(self, eb, true, pass);
  } else if (nk == ast__ast__NodeKind_NODE_BLOCK) {
    const ast__ast__NodeList ss = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), e)->as_data.block.statements;
    if (ss.len != 0U) {
      const uint32_t lastid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ss)[((size_t)(ss.len - 1U))];
      const ast__ast__NodeKind lastk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lastid)->kind;
      if (lastk == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) {
        const uint32_t lv = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lastid)->as_data.single.value;
        if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lv)->kind != ast__ast__NodeKind_NODE_ASSIGNMENT) {
          codegen__codegen__Codegen__cg_mark_move_tail(self, lv, cond, pass);
        }
      }
    }
  } else {
    codegen__codegen__Codegen__cg_mark_move(self, e, cond, pass, true);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_scan_moves(codegen__codegen__Codegen *const self, uint32_t const id, bool const cond, int32_t const pass) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->kind;
  if (nk == ast__ast__NodeKind_NODE_BLOCK) {
    const ast__ast__NodeList ss = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.block.statements;
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ss);
    for (uint32_t i = 0U; i < ss.len; i++) {
      codegen__codegen__Codegen__cg_scan_moves(self, ids[((size_t)i)], cond, pass);
    }
  } else if (nk == ast__ast__NodeKind_NODE_LET) {
    const uint32_t v = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.let_stmt.value;
    codegen__codegen__Codegen__cg_mark_move_tail(self, v, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, v, cond, pass);
  } else if (nk == ast__ast__NodeKind_NODE_RETURN) {
    const ast__ast__NodeList vs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.return_stmt.values;
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), vs);
    for (uint32_t i = 0U; i < vs.len; i++) {
      const uint32_t vid = ids[((size_t)i)];
      codegen__codegen__Codegen__cg_mark_move_tail(self, vid, cond, pass);
      codegen__codegen__Codegen__cg_scan_moves(self, vid, cond, pass);
    }
  } else if (nk == ast__ast__NodeKind_NODE_ASSIGNMENT) {
    const uint32_t l = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary.left;
    const uint32_t r = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary.right;
    codegen__codegen__Codegen__cg_mark_move_tail(self, r, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, l, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, r, cond, pass);
  } else if (nk == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
    const ast__ast__NodeList fs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.struct_initializer.fields;
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), fs);
    for (uint32_t i = 0U; i < fs.len; i++) {
      const uint32_t v = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ids[((size_t)i)])->as_data.field_initializer.value;
      codegen__codegen__Codegen__cg_mark_move_tail(self, v, cond, pass);
      codegen__codegen__Codegen__cg_scan_moves(self, v, cond, pass);
    }
  } else if (nk == ast__ast__NodeKind_NODE_IF) {
    const uint32_t cnd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.if_stmt.condition;
    const uint32_t tb = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.if_stmt.then_branch;
    const uint32_t eb = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.if_stmt.else_branch;
    codegen__codegen__Codegen__cg_scan_moves(self, cnd, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, tb, true, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, eb, true, pass);
  } else if (nk == ast__ast__NodeKind_NODE_WHILE) {
    const uint32_t cnd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.while_stmt.condition;
    const uint32_t b = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.while_stmt.body;
    codegen__codegen__Codegen__cg_scan_moves(self, cnd, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, b, true, pass);
  } else if (nk == ast__ast__NodeKind_NODE_FOR) {
    const uint32_t it = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.for_stmt.iterable;
    const uint32_t b = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.for_stmt.body;
    codegen__codegen__Codegen__cg_scan_moves(self, it, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, b, true, pass);
  } else if (nk == ast__ast__NodeKind_NODE_MATCH) {
    const uint32_t val = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.match_expr.value;
    codegen__codegen__Codegen__cg_mark_move(self, val, cond, pass, true);
    codegen__codegen__Codegen__cg_scan_moves(self, val, cond, pass);
    const ast__ast__NodeList arms = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.match_expr.arms;
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), arms);
    for (uint32_t i = 0U; i < arms.len; i++) {
      const uint32_t body = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ids[((size_t)i)])->as_data.match_arm.body;
      codegen__codegen__Codegen__cg_scan_moves(self, body, true, pass);
    }
  } else if ((nk == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) || (nk == ast__ast__NodeKind_NODE_DEFER)) {
    codegen__codegen__Codegen__cg_scan_moves(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.single.value, cond, pass);
  } else if (nk == ast__ast__NodeKind_NODE_CALL) {
    const uint32_t callee_id = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.call.callee;
    codegen__codegen__Codegen__cg_scan_moves(self, callee_id, cond, pass);
    const ast__ast__NodeKind ck = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id)->kind;
    if (ck == ast__ast__NodeKind_NODE_MEMBER) {
      const bool cpath = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id)->as_data.member.path;
      const uint32_t cmember = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id)->as_data.member.member;
      const uint32_t cobj = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id)->as_data.member.object;
      if ((!cpath) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), cmember)->as_data.name.text, ((const char *)({ __auto_type __sc626 = (str){ (const uint8_t *)"free", sizeof("free") - 1 }; str__ptr(&__sc626); })))) {
        const ast__ast__TypeKind rk = ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), cobj))->kind;
        if ((rk != ast__ast__TypeKind_TYPE_POINTER) && (rk != ast__ast__TypeKind_TYPE_REFERENCE)) {
          codegen__codegen__Codegen__cg_mark_move(self, cobj, cond, pass, false);
        }
      } else if (!cpath) {
        const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), cmember);
        if (md.node != ast__ast__NODE_NONE) {
          const ast__ast__NodeKind mnk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->kind;
          const ast__ast__NodeList mparams = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node)->as_data.function.params;
          if ((mnk == ast__ast__NodeKind_NODE_FUNCTION) && (mparams.len > 0U)) {
            const uint32_t p0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), mparams)[0];
            const uint32_t pt = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), p0)->as_data.parameter.ty;
            const ast__ast__NodeKind ptk = ({
              ast__ast__NodeKind __sc627;
              if (pt != ast__ast__NODE_NONE) {
                __sc627 = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), pt)->kind;
              } else {
                __sc627 = ast__ast__NodeKind_NODE_NONE_KIND;
              }
              __sc627;
            });
            if ((ptk != ast__ast__NodeKind_NODE_POINTER_TYPE) && (ptk != ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
              codegen__codegen__Codegen__cg_mark_move(self, cobj, cond, pass, true);
            }
          }
        }
      }
    }
    const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.call.args;
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args);
    for (uint32_t i = 0U; i < args.len; i++) {
      const uint32_t aid = ids[((size_t)i)];
      codegen__codegen__Codegen__cg_mark_move(self, aid, cond, pass, true);
      codegen__codegen__Codegen__cg_scan_moves(self, aid, cond, pass);
    }
  } else if (nk == ast__ast__NodeKind_NODE_CLOSURE) {
    const ast__ast__NodeList caps = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.closure.captures;
    const uint64_t mut_caps = ((uint64_t)ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.closure.mut_caps);
    const uint32_t *const cids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), caps);
    bool site_pushed = false;
    for (uint32_t i = 0U; i < caps.len; i++) {
      const uint32_t decl = cids[((size_t)i)];
      if (((({ uint64_t __sc628 = mut_caps; int64_t __sc629 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc629 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc628 >> __sc629); }) & 1ULL) != 0ULL) || (!codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), decl)))) {
        continue;
      }
      const bool patb = (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), decl)->kind == ast__ast__NodeKind_NODE_PATTERN_NAME);
      if (pass == 0) {
        if (((!cond) || patb) && (self->nmoved < 512U)) {
          (self->moved[((size_t)self->nmoved)] = decl);
          (self->nmoved = (self->nmoved + 1U));
        }
        continue;
      }
      if ((patb || (!cond)) || codegen__codegen__Codegen__cg_is_moved(self, decl)) {
        continue;
      }
      if ((!codegen__codegen__Codegen__cg_is_cond_moved(self, decl)) && (self->ncond_moved < 256U)) {
        (self->cond_moved[((size_t)self->ncond_moved)] = decl);
        (self->ncond_moved = (self->ncond_moved + 1U));
      }
      if ((!site_pushed) && (self->ncond_sites < 256U)) {
        (self->cond_sites[((size_t)self->ncond_sites)] = id);
        (self->ncond_sites = (self->ncond_sites + 1U));
        (site_pushed = true);
      }
    }
  } else if (nk == ast__ast__NodeKind_NODE_BINARY) {
    const uint32_t l = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary.left;
    const uint32_t r = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary.right;
    const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary.op;
    codegen__codegen__Codegen__cg_scan_moves(self, l, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, r, ((cond || (op == lexer__token_type__TokenType_AmpersandAmpersand)) || (op == lexer__token_type__TokenType_PipePipe)), pass);
  } else if (nk == ast__ast__NodeKind_NODE_UNARY) {
    codegen__codegen__Codegen__cg_scan_moves(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.unary.operand, cond, pass);
  } else if (nk == ast__ast__NodeKind_NODE_MEMBER) {
    codegen__codegen__Codegen__cg_scan_moves(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.member.object, cond, pass);
  } else if (nk == ast__ast__NodeKind_NODE_INDEX) {
    const uint32_t o = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.index.object;
    const uint32_t ix = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.index.index;
    codegen__codegen__Codegen__cg_scan_moves(self, o, cond, pass);
    codegen__codegen__Codegen__cg_scan_moves(self, ix, cond, pass);
  } else if (nk == ast__ast__NodeKind_NODE_CAST) {
    codegen__codegen__Codegen__cg_scan_moves(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.cast.expression, cond, pass);
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_arith_overload(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary;
  const char *const m = codegen__codegen__cg_arith_op_method(bd.op);
  if (m == NULL) {
    return false;
  }
  const uint32_t lt0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.left);
  if (lt0 == ast__ast__TYPE_NONE) {
    return false;
  }
  const uint32_t lt = codegen__codegen__Codegen__strip_ref_only(self, codegen__codegen__Codegen__subst_resolve(self, lt0));
  if (lt == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty bt = (*codegen__codegen__Codegen__type_at(self, lt));
  if ((bt.kind != ast__ast__TypeKind_TYPE_STRUCT) && (bt.kind != ast__ast__TypeKind_TYPE_INSTANCE)) {
    return false;
  }
  uint16_t om = 0U;
  uint32_t od = ast__ast__NODE_NONE;
  if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst));
    (om = it.module);
    (od = it.decl);
  } else {
    (om = bt.module);
    (od = bt.as_data.decl);
  }
  const ast__ast__DefId mth = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, m);
  if (mth.node == ast__ast__NODE_NONE) {
    return false;
  }
  const uint32_t rt0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.right);
  const int32_t dl = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.left)));
  int32_t dr = 0;
  if (rt0 != ast__ast__TYPE_NONE) {
    (dr = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, rt0)));
  }
  codegen__codegen__Buf32 l = (codegen__codegen__Buf32){0};
  codegen__codegen__Buf32 r = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&l.b[0])), 32ULL);
  codegen__codegen__Codegen__fresh(self, ((char *)(&r.b[0])), 32ULL);
  ({ String__Global *__sc630 = &(self->buf);
String__Global__push_str(&(*__sc630), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc630), utils__errors__cstr(((const char *)(&l.b[0]))));
String__Global__push_str(&(*__sc630), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, bd.left);
  ({ String__Global *__sc631 = &(self->buf);
String__Global__push_str(&(*__sc631), (str){ .ptr = (const uint8_t*)"; __auto_type ", .len = sizeof("; __auto_type ") - 1 });
String__Global__push_str(&(*__sc631), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc631), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, bd.right);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc632 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc632); })));
  codegen__codegen__Codegen__emit_op_method(self, bt, om, od, mth);
  const char *lp = ((const char *)({ __auto_type __sc633 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc633); }));
  if (dl != 0) {
    (lp = codegen__codegen__ref_derefs(dl));
  }
  const char *rp = ((const char *)({ __auto_type __sc634 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc634); }));
  if (dr != 0) {
    (rp = codegen__codegen__ref_derefs(dr));
  }
  ({ String__Global *__sc635 = &(self->buf);
String__Global__push_str(&(*__sc635), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc635), utils__errors__cstr(lp));
String__Global__push_str(&(*__sc635), utils__errors__cstr(((const char *)(&l.b[0]))));
String__Global__push_str(&(*__sc635), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc635), utils__errors__cstr(rp));
String__Global__push_str(&(*__sc635), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc635), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_cg_checked_arith(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary;
  const lexer__token_type__TokenType op = bd.op;
  const bool add = (op == lexer__token_type__TokenType_Plus);
  const bool sub = (op == lexer__token_type__TokenType_Minus);
  const bool mul = (op == lexer__token_type__TokenType_Star);
  const bool dv = (op == lexer__token_type__TokenType_Slash);
  const bool rm = (op == lexer__token_type__TokenType_Percent);
  const bool shl = (op == lexer__token_type__TokenType_LeftShift);
  const bool shr = (op == lexer__token_type__TokenType_RightShift);
  if (!((((((add || sub) || mul) || dv) || rm) || shl) || shr)) {
    return false;
  }
  const uint32_t rt = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  if (rt == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty ry = (*codegen__codegen__Codegen__type_at(self, rt));
  if (ry.kind != ast__ast__TypeKind_TYPE_BUILTIN) {
    return false;
  }
  const ast__ast__BuiltinType b = ry.as_data.builtin;
  const bool sgn = (((((b == ast__ast__BuiltinType_BT_I8) || (b == ast__ast__BuiltinType_BT_I16)) || (b == ast__ast__BuiltinType_BT_I32)) || (b == ast__ast__BuiltinType_BT_I64)) || (b == ast__ast__BuiltinType_BT_ISIZE));
  const bool uns = (((((b == ast__ast__BuiltinType_BT_U8) || (b == ast__ast__BuiltinType_BT_U16)) || (b == ast__ast__BuiltinType_BT_U32)) || (b == ast__ast__BuiltinType_BT_U64)) || (b == ast__ast__BuiltinType_BT_USIZE));
  if ((!sgn) && (!uns)) {
    return false;
  }
  const uint32_t lnode = bd.left;
  const uint32_t rnode = bd.right;
  const ast__ast__Ty lt = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), lnode))));
  const ast__ast__Ty rtt = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), rnode))));
  if ((lt.kind != ast__ast__TypeKind_TYPE_BUILTIN) || (rtt.kind != ast__ast__TypeKind_TYPE_BUILTIN)) {
    return false;
  }
  int32_t const bits = ({
    int32_t __sc636;
    if ((b == ast__ast__BuiltinType_BT_I8) || (b == ast__ast__BuiltinType_BT_U8)) {
      __sc636 = 8;
    } else if ((b == ast__ast__BuiltinType_BT_I16) || (b == ast__ast__BuiltinType_BT_U16)) {
      __sc636 = 16;
    } else if ((b == ast__ast__BuiltinType_BT_I32) || (b == ast__ast__BuiltinType_BT_U32)) {
      __sc636 = 32;
    } else {
      __sc636 = 64;
    }
    __sc636;
  });
  int64_t lv = 0;
  int64_t rv = 0;
  const bool ll = codegen__codegen__Codegen__cg_int_lit(self, lnode, ((int64_t *)(&lv)));
  const bool rl = codegen__codegen__Codegen__cg_int_lit(self, rnode, ((int64_t *)(&rv)));
  if (ll && rl) {
    const char *bad = NULL;
    if ((dv || rm) && (rv == 0)) {
      (bad = ((const char *)({ __auto_type __sc637 = (str){ (const uint8_t *)"constant division by zero", sizeof("constant division by zero") - 1 }; str__ptr(&__sc637); })));
    } else if (shl || shr) {
      if ((rv < 0) || (rv >= ((int64_t)bits))) {
        (bad = ((const char *)({ __auto_type __sc638 = (str){ (const uint8_t *)"constant shift out of range", sizeof("constant shift out of range") - 1 }; str__ptr(&__sc638); })));
      }
    } else if (((sgn && (dv || rm)) && (rv == -1)) && (lv == (-9223372036854775807ll - 1))) {
      (bad = ((const char *)({ __auto_type __sc639 = (str){ (const uint8_t *)"constant arithmetic overflow", sizeof("constant arithmetic overflow") - 1 }; str__ptr(&__sc639); })));
    } else if (sgn) {
      bool ov = false;
      int64_t res = 0;
      if (add) {
        const uint64_t u = (((uint64_t)lv) + ((uint64_t)rv));
        (res = ((int64_t)u));
        if (((lv ^ res) & (rv ^ res)) < 0) {
          (ov = true);
        }
      } else if (sub) {
        const uint64_t u = (((uint64_t)lv) - ((uint64_t)rv));
        (res = ((int64_t)u));
        if (((lv ^ rv) & (lv ^ res)) < 0) {
          (ov = true);
        }
      } else if (mul) {
        const uint64_t u = (((uint64_t)lv) * ((uint64_t)rv));
        (res = ((int64_t)u));
      } else if (dv) {
        (res = ({ int64_t __sc640 = lv; int64_t __sc641 = rv; if (__sc641 == 0) { __sc_panic("divide by zero"); } if (__sc641 == -1 && __sc640 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc640 / __sc641); }));
      } else {
        (res = ({ int64_t __sc642 = lv; int64_t __sc643 = rv; if (__sc643 == 0) { __sc_panic("divide by zero"); } if (__sc643 == -1 && __sc642 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc642 % __sc643); }));
      }
      int64_t mn = 0;
      int64_t mx = 0;
      codegen__codegen__cg_int_range(b, ((int64_t *)(&mn)), ((int64_t *)(&mx)));
      if ((ov || (res < mn)) || (res > mx)) {
        (bad = ((const char *)({ __auto_type __sc644 = (str){ (const uint8_t *)"constant arithmetic overflow", sizeof("constant arithmetic overflow") - 1 }; str__ptr(&__sc644); })));
      }
    }
    if (bad != NULL) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc645 = String__Global__new();
String__Global__push_str(&__sc645, utils__errors__cstr(bad));
__sc645; }));
    }
  }
  if (self->const_ctx) {
    return false;
  }
  codegen__codegen__Buf64 rts = (codegen__codegen__Buf64){0};
  codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)({ __auto_type __sc646 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc646); })), ((char *)(&rts.b[0])), 64ULL);
  const char *const rtsp = ((const char *)(&rts.b[0]));
  if (sgn && ((add || sub) || mul)) {
    const char *const bn = ({
      const char *__sc647;
      if (add) {
        __sc647 = ((const char *)({ __auto_type __sc648 = (str){ (const uint8_t *)"add", sizeof("add") - 1 }; str__ptr(&__sc648); }));
      } else if (sub) {
        __sc647 = ((const char *)({ __auto_type __sc649 = (str){ (const uint8_t *)"sub", sizeof("sub") - 1 }; str__ptr(&__sc649); }));
      } else {
        __sc647 = ((const char *)({ __auto_type __sc650 = (str){ (const uint8_t *)"mul", sizeof("mul") - 1 }; str__ptr(&__sc650); }));
      }
      __sc647;
    });
    ({ String__Global *__sc651 = &(self->buf);
String__Global__push_str(&(*__sc651), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc651), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc651), (str){ .ptr = (const uint8_t*)" __sc_r; if (__builtin_", .len = sizeof(" __sc_r; if (__builtin_") - 1 });
String__Global__push_str(&(*__sc651), utils__errors__cstr(bn));
String__Global__push_str(&(*__sc651), (str){ .ptr = (const uint8_t*)"_overflow(", .len = sizeof("_overflow(") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, lnode);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc652 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc652); })));
    codegen__codegen__Codegen__emit_expr(self, rnode);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc653 = (str){ (const uint8_t *)", &__sc_r)) { __sc_panic(\"arithmetic overflow\"); } __sc_r; })", sizeof(", &__sc_r)) { __sc_panic(\"arithmetic overflow\"); } __sc_r; })") - 1 }; str__ptr(&__sc653); })));
    return true;
  }
  if ((uns && ((add || sub) || mul)) && (bits < 32)) {
    const char *const opc = ({
      const char *__sc654;
      if (add) {
        __sc654 = ((const char *)({ __auto_type __sc655 = (str){ (const uint8_t *)"+", sizeof("+") - 1 }; str__ptr(&__sc655); }));
      } else if (sub) {
        __sc654 = ((const char *)({ __auto_type __sc656 = (str){ (const uint8_t *)"-", sizeof("-") - 1 }; str__ptr(&__sc656); }));
      } else {
        __sc654 = ((const char *)({ __auto_type __sc657 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc657); }));
      }
      __sc654;
    });
    ({ String__Global *__sc658 = &(self->buf);
String__Global__push_str(&(*__sc658), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc658), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc658), (str){ .ptr = (const uint8_t*)")((uint32_t)", .len = sizeof(")((uint32_t)") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, lnode);
    ({ String__Global *__sc659 = &(self->buf);
String__Global__push_str(&(*__sc659), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc659), utils__errors__cstr(opc));
String__Global__push_str(&(*__sc659), (str){ .ptr = (const uint8_t*)" (uint32_t)", .len = sizeof(" (uint32_t)") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, rnode);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc660 = (str){ (const uint8_t *)"))", sizeof("))") - 1 }; str__ptr(&__sc660); })));
    return true;
  }
  if (shl || shr) {
    const char *const uts = ({
      const char *__sc661;
      if (bits == 8) {
        __sc661 = ((const char *)({ __auto_type __sc662 = (str){ (const uint8_t *)"uint8_t", sizeof("uint8_t") - 1 }; str__ptr(&__sc662); }));
      } else if (bits == 16) {
        __sc661 = ((const char *)({ __auto_type __sc663 = (str){ (const uint8_t *)"uint16_t", sizeof("uint16_t") - 1 }; str__ptr(&__sc663); }));
      } else if (bits == 32) {
        __sc661 = ((const char *)({ __auto_type __sc664 = (str){ (const uint8_t *)"uint32_t", sizeof("uint32_t") - 1 }; str__ptr(&__sc664); }));
      } else {
        __sc661 = ((const char *)({ __auto_type __sc665 = (str){ (const uint8_t *)"uint64_t", sizeof("uint64_t") - 1 }; str__ptr(&__sc665); }));
      }
      __sc661;
    });
    codegen__codegen__Buf32 a = (codegen__codegen__Buf32){0};
    codegen__codegen__Buf32 s = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&a.b[0])), 32ULL);
    codegen__codegen__Codegen__fresh(self, ((char *)(&s.b[0])), 32ULL);
    const char *const ap = ((const char *)(&a.b[0]));
    const char *const sp2 = ((const char *)(&s.b[0]));
    ({ String__Global *__sc666 = &(self->buf);
String__Global__push_str(&(*__sc666), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc666), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc666), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc666), utils__errors__cstr(ap));
String__Global__push_str(&(*__sc666), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, lnode);
    ({ String__Global *__sc667 = &(self->buf);
String__Global__push_str(&(*__sc667), (str){ .ptr = (const uint8_t*)"; int64_t ", .len = sizeof("; int64_t ") - 1 });
String__Global__push_str(&(*__sc667), utils__errors__cstr(sp2));
String__Global__push_str(&(*__sc667), (str){ .ptr = (const uint8_t*)" = (int64_t)(", .len = sizeof(" = (int64_t)(") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, rnode);
    ({ String__Global *__sc668 = &(self->buf);
String__Global__push_str(&(*__sc668), (str){ .ptr = (const uint8_t*)"); if ((uint64_t)", .len = sizeof("); if ((uint64_t)") - 1 });
String__Global__push_str(&(*__sc668), utils__errors__cstr(sp2));
String__Global__push_str(&(*__sc668), (str){ .ptr = (const uint8_t*)" >= ", .len = sizeof(" >= ") - 1 });
String__Global__push_i64(&(*__sc668), (int64_t)(bits));
String__Global__push_str(&(*__sc668), (str){ .ptr = (const uint8_t*)") { __sc_panic(\"shift out of range\"); } ", .len = sizeof(") { __sc_panic(\"shift out of range\"); } ") - 1 });
});
    if (shl) {
      ({ String__Global *__sc669 = &(self->buf);
String__Global__push_str(&(*__sc669), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc669), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc669), (str){ .ptr = (const uint8_t*)")((", .len = sizeof(")((") - 1 });
String__Global__push_str(&(*__sc669), utils__errors__cstr(uts));
String__Global__push_str(&(*__sc669), (str){ .ptr = (const uint8_t*)")((", .len = sizeof(")((") - 1 });
String__Global__push_str(&(*__sc669), utils__errors__cstr(uts));
String__Global__push_str(&(*__sc669), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
String__Global__push_str(&(*__sc669), utils__errors__cstr(ap));
String__Global__push_str(&(*__sc669), (str){ .ptr = (const uint8_t*)" << ", .len = sizeof(" << ") - 1 });
String__Global__push_str(&(*__sc669), utils__errors__cstr(sp2));
String__Global__push_str(&(*__sc669), (str){ .ptr = (const uint8_t*)")); })", .len = sizeof(")); })") - 1 });
});
    } else {
      ({ String__Global *__sc670 = &(self->buf);
String__Global__push_str(&(*__sc670), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc670), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc670), (str){ .ptr = (const uint8_t*)")(", .len = sizeof(")(") - 1 });
String__Global__push_str(&(*__sc670), utils__errors__cstr(ap));
String__Global__push_str(&(*__sc670), (str){ .ptr = (const uint8_t*)" >> ", .len = sizeof(" >> ") - 1 });
String__Global__push_str(&(*__sc670), utils__errors__cstr(sp2));
String__Global__push_str(&(*__sc670), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
    }
    return true;
  }
  if (dv || rm) {
    codegen__codegen__Buf32 a = (codegen__codegen__Buf32){0};
    codegen__codegen__Buf32 d = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&a.b[0])), 32ULL);
    codegen__codegen__Codegen__fresh(self, ((char *)(&d.b[0])), 32ULL);
    const char *const ap = ((const char *)(&a.b[0]));
    const char *const dp = ((const char *)(&d.b[0]));
    ({ String__Global *__sc671 = &(self->buf);
String__Global__push_str(&(*__sc671), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc671), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc671), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc671), utils__errors__cstr(ap));
String__Global__push_str(&(*__sc671), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, lnode);
    ({ String__Global *__sc672 = &(self->buf);
String__Global__push_str(&(*__sc672), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc672), utils__errors__cstr(rtsp));
String__Global__push_str(&(*__sc672), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc672), utils__errors__cstr(dp));
String__Global__push_str(&(*__sc672), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, rnode);
    ({ String__Global *__sc673 = &(self->buf);
String__Global__push_str(&(*__sc673), (str){ .ptr = (const uint8_t*)"; if (", .len = sizeof("; if (") - 1 });
String__Global__push_str(&(*__sc673), utils__errors__cstr(dp));
String__Global__push_str(&(*__sc673), (str){ .ptr = (const uint8_t*)" == 0) { __sc_panic(\"divide by zero\"); } ", .len = sizeof(" == 0) { __sc_panic(\"divide by zero\"); } ") - 1 });
});
    if (sgn) {
      const char *const mn = ({
        const char *__sc674;
        if (bits == 8) {
          __sc674 = ((const char *)({ __auto_type __sc675 = (str){ (const uint8_t *)"INT8_MIN", sizeof("INT8_MIN") - 1 }; str__ptr(&__sc675); }));
        } else if (bits == 16) {
          __sc674 = ((const char *)({ __auto_type __sc676 = (str){ (const uint8_t *)"INT16_MIN", sizeof("INT16_MIN") - 1 }; str__ptr(&__sc676); }));
        } else if (bits == 32) {
          __sc674 = ((const char *)({ __auto_type __sc677 = (str){ (const uint8_t *)"INT32_MIN", sizeof("INT32_MIN") - 1 }; str__ptr(&__sc677); }));
        } else {
          __sc674 = ((const char *)({ __auto_type __sc678 = (str){ (const uint8_t *)"INT64_MIN", sizeof("INT64_MIN") - 1 }; str__ptr(&__sc678); }));
        }
        __sc674;
      });
      ({ String__Global *__sc679 = &(self->buf);
String__Global__push_str(&(*__sc679), (str){ .ptr = (const uint8_t*)"if (", .len = sizeof("if (") - 1 });
String__Global__push_str(&(*__sc679), utils__errors__cstr(dp));
String__Global__push_str(&(*__sc679), (str){ .ptr = (const uint8_t*)" == -1 && ", .len = sizeof(" == -1 && ") - 1 });
String__Global__push_str(&(*__sc679), utils__errors__cstr(ap));
String__Global__push_str(&(*__sc679), (str){ .ptr = (const uint8_t*)" == ", .len = sizeof(" == ") - 1 });
String__Global__push_str(&(*__sc679), utils__errors__cstr(mn));
String__Global__push_str(&(*__sc679), (str){ .ptr = (const uint8_t*)") { __sc_panic(\"arithmetic overflow\"); } ", .len = sizeof(") { __sc_panic(\"arithmetic overflow\"); } ") - 1 });
});
    }
    const char *const opc = ({
      const char *__sc680;
      if (dv) {
        __sc680 = ((const char *)({ __auto_type __sc681 = (str){ (const uint8_t *)"/", sizeof("/") - 1 }; str__ptr(&__sc681); }));
      } else {
        __sc680 = ((const char *)({ __auto_type __sc682 = (str){ (const uint8_t *)"%", sizeof("%") - 1 }; str__ptr(&__sc682); }));
      }
      __sc680;
    });
    ({ String__Global *__sc683 = &(self->buf);
String__Global__push_str(&(*__sc683), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc683), utils__errors__cstr(ap));
String__Global__push_str(&(*__sc683), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc683), utils__errors__cstr(opc));
String__Global__push_str(&(*__sc683), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc683), utils__errors__cstr(dp));
String__Global__push_str(&(*__sc683), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
    return true;
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_slice_coercion(codegen__codegen__Codegen *const self, uint32_t const id) {
  uint32_t selem = ast__ast__TYPE_NONE;
  const uint32_t st = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  if (!codegen__codegen__Codegen__cg_slice_elem(self, st, ((uint32_t *)(&selem)))) {
    return false;
  }
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const bool is_lit = (n.kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL);
  uint32_t lenN = ast__ast__NODE_NONE;
  if (!is_lit) {
    (lenN = codegen__codegen__Codegen__array_length_of(self, id));
  }
  if ((!is_lit) && (lenN == ast__ast__NODE_NONE)) {
    return false;
  }
  codegen__codegen__Buf256 styp = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__render_type_id(self, st, ((const char *)({ __auto_type __sc684 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc684); })), ((char *)(&styp.b[0])), 200ULL);
  ({ String__Global *__sc685 = &(self->buf);
String__Global__push_str(&(*__sc685), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc685), utils__errors__cstr(((const char *)(&styp.b[0]))));
String__Global__push_str(&(*__sc685), (str){ .ptr = (const uint8_t*)"){ .ptr = ", .len = sizeof("){ .ptr = ") - 1 });
});
  if (is_lit) {
    codegen__codegen__Buf256 et = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, selem, ((const char *)({ __auto_type __sc686 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc686); })), ((char *)(&et.b[0])), 256ULL);
    ({ String__Global *__sc687 = &(self->buf);
String__Global__push_str(&(*__sc687), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc687), utils__errors__cstr(((const char *)(&et.b[0]))));
String__Global__push_str(&(*__sc687), (str){ .ptr = (const uint8_t*)"[", .len = sizeof("[") - 1 });
String__Global__push_u64(&(*__sc687), (uint64_t)(n.as_data.array_literal.elements.len));
String__Global__push_str(&(*__sc687), (str){ .ptr = (const uint8_t*)"])", .len = sizeof("])") - 1 });
});
    codegen__codegen__Codegen__emit_array_braces(self, id);
    ({ String__Global *__sc688 = &(self->buf);
String__Global__push_str(&(*__sc688), (str){ .ptr = (const uint8_t*)", .len = ", .len = sizeof(", .len = ") - 1 });
String__Global__push_u64(&(*__sc688), (uint64_t)(n.as_data.array_literal.elements.len));
String__Global__push_str(&(*__sc688), (str){ .ptr = (const uint8_t*)" }", .len = sizeof(" }") - 1 });
});
    return true;
  }
  (self->slice_raw = id);
  codegen__codegen__Codegen__emit_expr(self, id);
  (self->slice_raw = ast__ast__NODE_NONE);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc689 = (str){ (const uint8_t *)", .len = ", sizeof(", .len = ") - 1 }; str__ptr(&__sc689); })));
  codegen__codegen__Codegen__emit_expr(self, lenN);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc690 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc690); })));
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_dyn_coercion(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__DynUse *const du = ast__ast__Ast__dyn_use_at(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  if (du == NULL) {
    return false;
  }
  const uint32_t src = (*du).src;
  const uint32_t dynTy = (*du).dyn_ty;
  if (src == ast__ast__TYPE_NONE) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc691 = (str){ (const uint8_t *)"(*(", sizeof("(*(") - 1 }; str__ptr(&__sc691); })));
    (self->dyn_raw = id);
    codegen__codegen__Codegen__emit_expr(self, id);
    (self->dyn_raw = ast__ast__NODE_NONE);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc692 = (str){ (const uint8_t *)"))", sizeof("))") - 1 }; str__ptr(&__sc692); })));
    return true;
  }
  const ast__ast__Ty dy = (*codegen__codegen__Codegen__type_at(self, dynTy));
  codegen__codegen__Buf256 dt = (codegen__codegen__Buf256){0};
  codegen__codegen__Buf512 pair = (codegen__codegen__Buf512){0};
  codegen__codegen__Codegen__render_type_id(self, dynTy, ((const char *)({ __auto_type __sc693 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc693); })), ((char *)(&dt.b[0])), 240ULL);
  codegen__codegen__Codegen__dyn_pair_stem(self, src, dy.module, dy.as_data.decl, ((char *)(&pair.b[0])), 368ULL);
  const ast__ast__Ty nat = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id))));
  if (nat.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    if (!codegen__codegen__Codegen__cg_fn_is_capturing(self, (&nat))) {
      ({ String__Global *__sc694 = &(self->buf);
String__Global__push_str(&(*__sc694), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc694), utils__errors__cstr(((const char *)(&dt.b[0]))));
String__Global__push_str(&(*__sc694), (str){ .ptr = (const uint8_t*)"){ .data = 0, .vt = &", .len = sizeof("){ .data = 0, .vt = &") - 1 });
String__Global__push_str(&(*__sc694), utils__errors__cstr(((const char *)(&pair.b[0]))));
String__Global__push_str(&(*__sc694), (str){ .ptr = (const uint8_t*)"__vtbl })", .len = sizeof("__vtbl })") - 1 });
});
      return true;
    }
    codegen__codegen__Buf256 envn = (codegen__codegen__Buf256){0};
    codegen__codegen__Buf256 gt = (codegen__codegen__Buf256){0};
    codegen__codegen__Buf32 vtmp = (codegen__codegen__Buf32){0};
    codegen__codegen__Buf32 gtmp = (codegen__codegen__Buf32){0};
    codegen__codegen__Buf32 ptmp = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__render_type_id(self, src, ((const char *)({ __auto_type __sc695 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc695); })), ((char *)(&envn.b[0])), 256ULL);
    const module__loader__LookupHit gh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Global", sizeof("Global") - 1 }, true);
    codegen__codegen__Codegen__render_qualified(self, gh.mid, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, gh.mid))), gh.node)->as_data.aggregate.name, ((char *)(&gt.b[0])), 160ULL);
    codegen__codegen__Codegen__fresh(self, ((char *)(&vtmp.b[0])), 32ULL);
    codegen__codegen__Codegen__fresh(self, ((char *)(&gtmp.b[0])), 32ULL);
    codegen__codegen__Codegen__fresh(self, ((char *)(&ptmp.b[0])), 32ULL);
    ({ String__Global *__sc696 = &(self->buf);
String__Global__push_str(&(*__sc696), (str){ .ptr = (const uint8_t*)"({ ", .len = sizeof("({ ") - 1 });
String__Global__push_str(&(*__sc696), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc696), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc696), utils__errors__cstr(((const char *)(&vtmp.b[0]))));
String__Global__push_str(&(*__sc696), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    (self->dyn_raw = id);
    codegen__codegen__Codegen__emit_expr(self, id);
    (self->dyn_raw = ast__ast__NODE_NONE);
    ({ String__Global *__sc697 = &(self->buf);
String__Global__push_str(&(*__sc697), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
String__Global__push_str(&(*__sc697), utils__errors__cstr(((const char *)(&gt.b[0]))));
String__Global__push_str(&(*__sc697), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc697), utils__errors__cstr(((const char *)(&gtmp.b[0]))));
String__Global__push_str(&(*__sc697), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc697), utils__errors__cstr(((const char *)(&gt.b[0]))));
String__Global__push_str(&(*__sc697), (str){ .ptr = (const uint8_t*)"__default_(); ", .len = sizeof("__default_(); ") - 1 });
});
    ({ String__Global *__sc698 = &(self->buf);
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)" *", .len = sizeof(" *") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&ptmp.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)" = (", .len = sizeof(" = (") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)" *)", .len = sizeof(" *)") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&gt.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)"__alloc(&", .len = sizeof("__alloc(&") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&gtmp.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)", sizeof(", .len = sizeof(", sizeof(") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)"), _Alignof(", .len = sizeof("), _Alignof(") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)")); *", .len = sizeof(")); *") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&ptmp.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc698), utils__errors__cstr(((const char *)(&vtmp.b[0]))));
String__Global__push_str(&(*__sc698), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
});
    ({ String__Global *__sc699 = &(self->buf);
String__Global__push_str(&(*__sc699), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc699), utils__errors__cstr(((const char *)(&dt.b[0]))));
String__Global__push_str(&(*__sc699), (str){ .ptr = (const uint8_t*)"){ .data = ", .len = sizeof("){ .data = ") - 1 });
String__Global__push_str(&(*__sc699), utils__errors__cstr(((const char *)(&ptmp.b[0]))));
String__Global__push_str(&(*__sc699), (str){ .ptr = (const uint8_t*)", .vt = &", .len = sizeof(", .vt = &") - 1 });
String__Global__push_str(&(*__sc699), utils__errors__cstr(((const char *)(&pair.b[0]))));
String__Global__push_str(&(*__sc699), (str){ .ptr = (const uint8_t*)"__vtbl }); })", .len = sizeof("__vtbl }); })") - 1 });
});
    return true;
  }
  const bool box_src = (nat.kind == ast__ast__TypeKind_TYPE_INSTANCE);
  ({ String__Global *__sc700 = &(self->buf);
String__Global__push_str(&(*__sc700), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc700), utils__errors__cstr(((const char *)(&dt.b[0]))));
String__Global__push_str(&(*__sc700), (str){ .ptr = (const uint8_t*)"){ .data = (void *)(", .len = sizeof("){ .data = (void *)(") - 1 });
});
  (self->dyn_raw = id);
  codegen__codegen__Codegen__emit_expr(self, id);
  (self->dyn_raw = ast__ast__NODE_NONE);
  const char *tail = ((const char *)({ __auto_type __sc701 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc701); }));
  if (box_src) {
    (tail = ((const char *)({ __auto_type __sc702 = (str){ (const uint8_t *)").ptr", sizeof(").ptr") - 1 }; str__ptr(&__sc702); })));
  }
  ({ String__Global *__sc703 = &(self->buf);
String__Global__push_str(&(*__sc703), utils__errors__cstr(tail));
String__Global__push_str(&(*__sc703), (str){ .ptr = (const uint8_t*)", .vt = &", .len = sizeof(", .vt = &") - 1 });
String__Global__push_str(&(*__sc703), utils__errors__cstr(((const char *)(&pair.b[0]))));
String__Global__push_str(&(*__sc703), (str){ .ptr = (const uint8_t*)"__vtbl })", .len = sizeof("__vtbl })") - 1 });
});
  return true;
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__array_length_of(codegen__codegen__Codegen *const self, uint32_t const iter) {
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), iter)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return ast__ast__NODE_NONE;
  }
  const uint32_t d = ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), iter);
  if (d == ast__ast__NODE_NONE) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), d));
  uint32_t tn = ast__ast__NODE_NONE;
  if (dn.kind == ast__ast__NodeKind_NODE_PARAMETER) {
    (tn = dn.as_data.parameter.ty);
  } else if (dn.kind == ast__ast__NodeKind_NODE_LET) {
    (tn = dn.as_data.let_stmt.ty);
  } else if (dn.kind == ast__ast__NodeKind_NODE_FIELD) {
    (tn = dn.as_data.field.ty);
  }
  if ((tn != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), tn)->kind == ast__ast__NodeKind_NODE_ARRAY_TYPE)) {
    return ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), tn)->as_data.array_type.length;
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) int64_t codegen__codegen__Codegen__array_literal_count(codegen__codegen__Codegen *const self, uint32_t const obj) {
  const ast__ast__Node o = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), obj));
  if (o.kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
    return ((int64_t)o.as_data.array_literal.elements.len);
  }
  if (o.kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return -1;
  }
  const uint32_t d = ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), obj);
  if (d == ast__ast__NODE_NONE) {
    return -1;
  }
  const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), d));
  uint32_t v = ast__ast__NODE_NONE;
  if (dn.kind == ast__ast__NodeKind_NODE_LET) {
    (v = dn.as_data.let_stmt.value);
  }
  if ((v != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL)) {
    return ((int64_t)ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v)->as_data.array_literal.elements.len);
  }
  return -1;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_int_lit(codegen__codegen__Codegen *const self, uint32_t const e, int64_t *const out) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), e));
  if ((n.kind != ast__ast__NodeKind_NODE_LITERAL) || (n.as_data.literal.token_type != lexer__token_type__TokenType_IntegerLiteral)) {
    return false;
  }
  const lexer__token__Span raw = n.as_data.literal.raw;
  codegen__codegen__Buf32 buf = (codegen__codegen__Buf32){0};
  size_t k = 0ULL;
  uint32_t i = raw.start;
  while ((i < raw.end) && ((k + 1ULL) < 32ULL)) {
    const uint8_t ch = self->source[((size_t)i)];
    if (ch == 95U) {
      (i = (i + 1U));
      continue;
    }
    if (((k == 0ULL) && (ch == 48U)) && ((i + 1U) < raw.end)) {
      (buf.b[k] = ((char)ch));
      (k = (k + 1ULL));
      (i = (i + 1U));
      continue;
    }
    const bool hexish = ((((((((((ch >= 48U) && (ch <= 57U)) || ((ch >= 97U) && (ch <= 102U))) || ((ch >= 65U) && (ch <= 70U))) || (ch == 120U)) || (ch == 88U)) || (ch == 98U)) || (ch == 66U)) || (ch == 111U)) || (ch == 79U));
    if (!hexish) {
      break;
    }
    (buf.b[k] = ((char)ch));
    (k = (k + 1ULL));
    (i = (i + 1U));
  }
  (buf.b[k] = 0);
  if (k == 0ULL) {
    return false;
  }
  char *endp = NULL;
  const int64_t v = strtoll(((const char *)(&buf.b[0])), ((char **)(&endp)), 0);
  if (endp == ((char *)(&buf.b[0]))) {
    return false;
  }
  ((*out) = v);
  return true;
}

static __attribute__((unused)) const ast__ast__Attr *codegen__codegen__Codegen__cg_attr(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const owner, ast__ast__AttrKind const kind) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  for (size_t i = 0ULL; i < Vector__ast__ast__Attr__Global__len(&(*a).attrs); i++) {
    const ast__ast__Attr *const at = Vector__ast__ast__Attr__Global__at(&(*a).attrs, i);
    if ((at->owner == owner) && (at->kind == ((uint8_t)kind))) {
      return ((const ast__ast__Attr *)at);
    }
  }
  return NULL;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_symbol_override(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const fn2, char *const out, size_t const cap) {
  const ast__ast__Attr *a = codegen__codegen__Codegen__cg_attr(self, m, fn2, ast__ast__AttrKind_ATTR_EXPORT);
  if (a == NULL) {
    (a = codegen__codegen__Codegen__cg_attr(self, m, fn2, ast__ast__AttrKind_ATTR_IMPORT));
  }
  if ((a == NULL) || (cap == 0ULL)) {
    return false;
  }
  const lexer__token__Span sp = (*a).str_span;
  size_t nn = ((size_t)(sp.end - sp.start));
  if (nn >= cap) {
    (nn = (cap - 1ULL));
  }
  memcpy(((void *)out), codegen__codegen__src_at(codegen__codegen__Codegen__mod_src(self, m), sp.start), nn);
  (out[nn] = 0);
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__decl_is_toplevel(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const node) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    if (ast__ast__Ast__list(&((*a)), items)[((size_t)i)] == node) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_env_capture(const codegen__codegen__Codegen *const self, uint32_t const decl, bool *const is_mut) {
  if ((self->env_clos == ast__ast__NODE_NONE) || (decl == ast__ast__NODE_NONE)) {
    return -1;
  }
  const ast__ast__NodeList caps = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), self->env_clos)->as_data.closure.captures;
  const uint64_t mut_caps = ((uint64_t)ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), self->env_clos)->as_data.closure.mut_caps);
  const uint32_t *const cids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), caps);
  for (uint32_t i = 0U; i < caps.len; i++) {
    if (cids[((size_t)i)] == decl) {
      ((*is_mut) = ((({ uint64_t __sc704 = mut_caps; int64_t __sc705 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc705 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc704 >> __sc705); }) & 1ULL) != 0ULL));
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) lexer__token__Span codegen__codegen__Codegen__cg_decl_name_span(const codegen__codegen__Codegen *const self, uint32_t const decl) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), decl);
  if (n->kind == ast__ast__NodeKind_NODE_LET) {
    return codegen__codegen__Codegen__name_span(self, n->as_data.let_stmt.name);
  }
  if (n->kind == ast__ast__NodeKind_NODE_PARAMETER) {
    return codegen__codegen__Codegen__name_span(self, n->as_data.parameter.name);
  }
  return (lexer__token__Span){ .start = 0U, .end = 0U };
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_auto_free(codegen__codegen__Codegen *const self, uint32_t const bid) {
  const uint32_t bt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bid);
  if (!codegen__codegen__Codegen__cg_type_is_free(self, bt)) {
    return;
  }
  if (codegen__codegen__Codegen__cg_is_cond_moved(self, bid)) {
    codegen__codegen__Buf32 fl = (codegen__codegen__Buf32){0};
    codegen__codegen__cg_move_flag(((char *)(&fl.b[0])), 32ULL, bid);
    ({ String__Global *__sc706 = &(self->buf);
String__Global__push_str(&(*__sc706), (str){ .ptr = (const uint8_t*)"if (!", .len = sizeof("if (!") - 1 });
String__Global__push_str(&(*__sc706), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc706), (str){ .ptr = (const uint8_t*)") ", .len = sizeof(") ") - 1 });
});
  }
  codegen__codegen__Codegen__emit_free_target(self, bt);
  const ast__ast__Node ln = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), bid));
  uint32_t nameNode = ln.as_data.let_stmt.name;
  if (ln.kind == ast__ast__NodeKind_NODE_PARAMETER) {
    (nameNode = ln.as_data.parameter.name);
  } else if (ln.kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    (nameNode = bid);
  }
  codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
  codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, nameNode), ((char *)(&nm.b[0])), 128ULL);
  ({ String__Global *__sc707 = &(self->buf);
String__Global__push_str(&(*__sc707), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc707), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc707), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_expr_stmt(codegen__codegen__Codegen *const self, uint32_t const v0) {
  uint32_t v = v0;
  ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v));
  while ((n.kind == ast__ast__NodeKind_NODE_UNARY) && ((n.as_data.unary.op == lexer__token_type__TokenType_Move) || (n.as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
    (v = n.as_data.unary.operand);
    (n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), v)));
  }
  if ((((codegen__codegen__Codegen__ceval(self) != NULL) && (n.kind == ast__ast__NodeKind_NODE_CALL)) && codegen__codegen__Codegen__cg_maybe_const(self, v)) && (consteval__consteval__ConstEval__eval(&((*codegen__codegen__Codegen__ceval(self))), codegen__codegen__Codegen__cur_module(self), v).kind != consteval__consteval__CONST_NONE)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc708 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc708); })));
    return;
  }
  if (n.kind == ast__ast__NodeKind_NODE_BLOCK) {
    codegen__codegen__Codegen__emit_block(self, v);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc709 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc709); })));
    return;
  }
  if (n.kind == ast__ast__NodeKind_NODE_IF) {
    codegen__codegen__Codegen__emit_if(self, v);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc710 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc710); })));
    return;
  }
  if (n.kind == ast__ast__NodeKind_NODE_MATCH) {
    codegen__codegen__Codegen__emit_match_stmt(self, v);
    return;
  }
  const uint32_t vt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), v);
  if (((((vt != ast__ast__TYPE_NONE) && (!self->no_temp_free)) && (n.kind != ast__ast__NodeKind_NODE_ASSIGNMENT)) && (!codegen__codegen__Codegen__is_lvalue(self, v))) && codegen__codegen__Codegen__cg_type_is_free(self, vt)) {
    codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
    ({ String__Global *__sc711 = &(self->buf);
String__Global__push_str(&(*__sc711), (str){ .ptr = (const uint8_t*)"{ __auto_type ", .len = sizeof("{ __auto_type ") - 1 });
String__Global__push_str(&(*__sc711), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc711), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, v);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc712 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc712); })));
    codegen__codegen__Codegen__emit_free_target(self, vt);
    ({ String__Global *__sc713 = &(self->buf);
String__Global__push_str(&(*__sc713), (str){ .ptr = (const uint8_t*)"(&", .len = sizeof("(&") - 1 });
String__Global__push_str(&(*__sc713), utils__errors__cstr(((const char *)(&tmp.b[0]))));
String__Global__push_str(&(*__sc713), (str){ .ptr = (const uint8_t*)"); }\n", .len = sizeof("); }\n") - 1 });
});
    return;
  }
  codegen__codegen__Codegen__emit_expr(self, v);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc714 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc714); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_assignment(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary;
  const uint32_t lt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.left);
  uint32_t ltr = ast__ast__TYPE_NONE;
  if (lt != ast__ast__TYPE_NONE) {
    (ltr = codegen__codegen__Codegen__subst_resolve(self, lt));
  }
  if (((bd.op == lexer__token_type__TokenType_Equal) && (ltr != ast__ast__TYPE_NONE)) && (codegen__codegen__Codegen__type_at(self, ltr)->kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc715 = (str){ (const uint8_t *)"memcpy(", sizeof("memcpy(") - 1 }; str__ptr(&__sc715); })));
    codegen__codegen__Codegen__emit_expr(self, bd.left);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc716 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc716); })));
    codegen__codegen__Codegen__emit_expr(self, bd.right);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc717 = (str){ (const uint8_t *)", sizeof(", sizeof(", sizeof(") - 1 }; str__ptr(&__sc717); })));
    codegen__codegen__Codegen__emit_expr(self, bd.left);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc718 = (str){ (const uint8_t *)"))", sizeof("))") - 1 }; str__ptr(&__sc718); })));
    return;
  }
  uint32_t lhsId = bd.left;
  ast__ast__Node lhs = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lhsId));
  while ((lhs.kind == ast__ast__NodeKind_NODE_UNARY) && ((lhs.as_data.unary.op == lexer__token_type__TokenType_Move) || (lhs.as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
    (lhsId = lhs.as_data.unary.operand);
    (lhs = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lhsId)));
  }
  ast__ast__DefId ld = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  if (lhs.kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    (ld = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), lhsId));
  }
  if (((((bd.op == lexer__token_type__TokenType_Equal) && (lhs.kind == ast__ast__NodeKind_NODE_IDENTIFIER)) && codegen__codegen__Codegen__cg_type_is_free(self, lt)) && (ld.node != ast__ast__NODE_NONE)) && (!codegen__codegen__Codegen__cg_is_moved(self, ld.node))) {
    codegen__codegen__Buf32 r = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&r.b[0])), 32ULL);
    ({ String__Global *__sc719 = &(self->buf);
String__Global__push_str(&(*__sc719), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc719), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc719), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, bd.right);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc720 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc720); })));
    codegen__codegen__Codegen__emit_free_target(self, lt);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc721 = (str){ (const uint8_t *)"(&", sizeof("(&") - 1 }; str__ptr(&__sc721); })));
    codegen__codegen__Codegen__emit_expr(self, bd.left);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc722 = (str){ (const uint8_t *)"); (", sizeof("); (") - 1 }; str__ptr(&__sc722); })));
    codegen__codegen__Codegen__emit_expr(self, bd.left);
    ({ String__Global *__sc723 = &(self->buf);
String__Global__push_str(&(*__sc723), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc723), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc723), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
    return;
  }
  if ((lhs.kind == ast__ast__NodeKind_NODE_INDEX) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lhs.as_data.index.index)->kind != ast__ast__NodeKind_NODE_RANGE)) {
    const uint32_t iot = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), lhs.as_data.index.object);
    uint32_t riot = ast__ast__TYPE_NONE;
    if (iot != ast__ast__TYPE_NONE) {
      (riot = codegen__codegen__Codegen__strip_ref_only(self, codegen__codegen__Codegen__subst_resolve(self, iot)));
    }
    int32_t ird = 0;
    if (iot != ast__ast__TYPE_NONE) {
      (ird = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, iot)));
    }
    ast__ast__TypeKind ibk = ast__ast__TypeKind_TYPE_ERROR;
    if (riot != ast__ast__TYPE_NONE) {
      (ibk = codegen__codegen__Codegen__type_at(self, riot)->kind);
    }
    if (((riot != ast__ast__TYPE_NONE) && ((ibk == ast__ast__TypeKind_TYPE_STRUCT) || (ibk == ast__ast__TypeKind_TYPE_INSTANCE))) && (!codegen__codegen__Codegen__cg_slice_elem(self, riot, NULL))) {
      const ast__ast__Ty ibt = (*codegen__codegen__Codegen__type_at(self, riot));
      uint16_t om = 0U;
      uint32_t od = ast__ast__NODE_NONE;
      if (ibt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
        const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ibt.as_data.inst));
        (om = it.module);
        (od = it.decl);
      } else {
        (om = ibt.module);
        (od = ibt.as_data.decl);
      }
      const ast__ast__DefId mth = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc724 = (str){ (const uint8_t *)"index_mut", sizeof("index_mut") - 1 }; str__ptr(&__sc724); })));
      if (mth.node != ast__ast__NODE_NONE) {
        const char *refp = ((const char *)({ __auto_type __sc725 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc725); }));
        if (ird != 0) {
          (refp = codegen__codegen__ref_derefs(ird));
        }
        if (((bd.op == lexer__token_type__TokenType_Equal) && (lt != ast__ast__TYPE_NONE)) && codegen__codegen__Codegen__cg_type_is_free(self, lt)) {
          codegen__codegen__Buf32 r = (codegen__codegen__Buf32){0};
          codegen__codegen__Buf32 p = (codegen__codegen__Buf32){0};
          codegen__codegen__Codegen__fresh(self, ((char *)(&r.b[0])), 32ULL);
          codegen__codegen__Codegen__fresh(self, ((char *)(&p.b[0])), 32ULL);
          ({ String__Global *__sc726 = &(self->buf);
String__Global__push_str(&(*__sc726), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc726), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc726), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
          codegen__codegen__Codegen__emit_expr(self, bd.right);
          ({ String__Global *__sc727 = &(self->buf);
String__Global__push_str(&(*__sc727), (str){ .ptr = (const uint8_t*)"; __auto_type ", .len = sizeof("; __auto_type ") - 1 });
String__Global__push_str(&(*__sc727), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc727), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
          codegen__codegen__Codegen__emit_op_method(self, ibt, om, od, mth);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc728 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc728); })));
          codegen__codegen__Codegen__emit_prefixed(self, lhs.as_data.index.object, refp);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc729 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc729); })));
          codegen__codegen__Codegen__emit_expr(self, lhs.as_data.index.index);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc730 = (str){ (const uint8_t *)"); ", sizeof("); ") - 1 }; str__ptr(&__sc730); })));
          codegen__codegen__Codegen__emit_free_target(self, lt);
          ({ String__Global *__sc731 = &(self->buf);
String__Global__push_str(&(*__sc731), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc731), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc731), (str){ .ptr = (const uint8_t*)"); (*", .len = sizeof("); (*") - 1 });
String__Global__push_str(&(*__sc731), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc731), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc731), utils__errors__cstr(((const char *)(&r.b[0]))));
String__Global__push_str(&(*__sc731), (str){ .ptr = (const uint8_t*)"); })", .len = sizeof("); })") - 1 });
});
        } else {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc732 = (str){ (const uint8_t *)"(*", sizeof("(*") - 1 }; str__ptr(&__sc732); })));
          codegen__codegen__Codegen__emit_op_method(self, ibt, om, od, mth);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc733 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc733); })));
          codegen__codegen__Codegen__emit_prefixed(self, lhs.as_data.index.object, refp);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc734 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc734); })));
          codegen__codegen__Codegen__emit_expr(self, lhs.as_data.index.index);
          ({ String__Global *__sc735 = &(self->buf);
String__Global__push_str(&(*__sc735), (str){ .ptr = (const uint8_t*)") ", .len = sizeof(") ") - 1 });
String__Global__push_str(&(*__sc735), utils__errors__cstr(codegen__codegen__c_op(bd.op)));
String__Global__push_str(&(*__sc735), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
          codegen__codegen__Codegen__emit_expr(self, bd.right);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc736 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc736); })));
        }
        return;
      }
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc737 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc737); })));
  codegen__codegen__Codegen__emit_place(self, bd.left, true);
  ({ String__Global *__sc738 = &(self->buf);
String__Global__push_str(&(*__sc738), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc738), utils__errors__cstr(codegen__codegen__c_op(bd.op)));
String__Global__push_str(&(*__sc738), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, bd.right);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc739 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc739); })));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_free_target(codegen__codegen__Codegen *const self, uint32_t const bt) {
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, bt)));
  if (y.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    if (!codegen__codegen__Codegen__cg_fn_owns(self, (&y))) {
      return false;
    }
    codegen__codegen__Buf256 sym = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__closure_sym_in(self, y.module, y.as_data.decl, ((char *)(&sym.b[0])), 220ULL);
    ({ String__Global *__sc740 = &(self->buf);
String__Global__push_str(&(*__sc740), utils__errors__cstr(((const char *)(&sym.b[0]))));
String__Global__push_str(&(*__sc740), (str){ .ptr = (const uint8_t*)"_env_free", .len = sizeof("_env_free") - 1 });
});
    return true;
  }
  if (y.kind == ast__ast__TypeKind_TYPE_DYN) {
    if (y.qualifier != 0U) {
      return false;
    }
    codegen__codegen__Buf256 stem = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__dyn_stem(self, y.module, y.as_data.decl, ((char *)(&stem.b[0])), 176ULL);
    ({ String__Global *__sc741 = &(self->buf);
String__Global__push_str(&(*__sc741), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc741), (str){ .ptr = (const uint8_t*)"__dyn_free", .len = sizeof("__dyn_free") - 1 });
});
    return true;
  }
  uint16_t om = 0U;
  uint32_t od = ast__ast__NODE_NONE;
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance ii = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    (om = ii.module);
    (od = ii.decl);
  } else if (y.kind == ast__ast__TypeKind_TYPE_STRUCT) {
    (om = y.module);
    (od = y.as_data.decl);
  } else {
    return false;
  }
  const ast__ast__DefId dm = codegen__codegen__Codegen__cg_free_method(self, om, od);
  if (dm.node == ast__ast__NODE_NONE) {
    return false;
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc742 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc742); })));
  } else {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, dm.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_ident_mod(self, om, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, om))), od)->as_data.aggregate.name);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc743 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc743); })));
  }
  codegen__codegen__Codegen__emit_ident_mod(self, dm.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dm.module))), dm.node)->as_data.function.name);
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__pat_trivial(const codegen__codegen__Codegen *const self, uint32_t const pid) {
  const ast__ast__Node *const p = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid);
  if (p->kind == ast__ast__NodeKind_NODE_PATTERN_NAME) {
    return (p->as_data.pattern.children.len == 0U);
  }
  return ((p->kind == ast__ast__NodeKind_NODE_PATTERN_WILDCARD) || (p->kind == ast__ast__NodeKind_NODE_IDENTIFIER));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_pattern_test(codegen__codegen__Codegen *const self, uint32_t const pid, const char *const scrut) {
  const ast__ast__Node p = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid));
  const ast__ast__NodeKind pk = p.kind;
  if (pk == ast__ast__NodeKind_NODE_PATTERN_NAME) {
    const ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name);
    if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, vd.module, vd.node);
      const bool payload = ((en != ast__ast__NODE_NONE) && codegen__codegen__Codegen__aggregate_has_payload_in(self, vd.module, en));
      if (payload) {
        ({ String__Global *__sc744 = &(self->buf);
String__Global__push_str(&(*__sc744), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc744), (str){ .ptr = (const uint8_t*)".tag == ", .len = sizeof(".tag == ") - 1 });
});
      } else {
        ({ String__Global *__sc745 = &(self->buf);
String__Global__push_str(&(*__sc745), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc745), (str){ .ptr = (const uint8_t*)" == ", .len = sizeof(" == ") - 1 });
});
      }
      if (en != ast__ast__NODE_NONE) {
        codegen__codegen__Codegen__emit_tag_mod(self, vd.module, en, vd.node);
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc746 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc746); })));
      }
    } else if (p.as_data.pattern.children.len != 0U) {
      codegen__codegen__Codegen__emit_pattern_test(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.children)[0], scrut);
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc747 = (str){ (const uint8_t *)"1", sizeof("1") - 1 }; str__ptr(&__sc747); })));
    }
  } else if ((pk == ast__ast__NodeKind_NODE_PATTERN_WILDCARD) || (pk == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc748 = (str){ (const uint8_t *)"1", sizeof("1") - 1 }; str__ptr(&__sc748); })));
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_LITERAL) {
    ({ String__Global *__sc749 = &(self->buf);
String__Global__push_str(&(*__sc749), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc749), (str){ .ptr = (const uint8_t*)" == ", .len = sizeof(" == ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, p.as_data.single.value);
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_RANGE) {
    const uint32_t lo = p.as_data.pattern_range.start;
    const uint32_t hi = p.as_data.pattern_range.end;
    if (lo != ast__ast__NODE_NONE) {
      const ast__ast__Node *const lon = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), lo);
      ({ String__Global *__sc750 = &(self->buf);
String__Global__push_str(&(*__sc750), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc750), (str){ .ptr = (const uint8_t*)" >= ", .len = sizeof(" >= ") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, codegen__codegen__if_node((lon->kind == ast__ast__NodeKind_NODE_PATTERN_LITERAL), lon->as_data.single.value, lo));
    }
    if (hi != ast__ast__NODE_NONE) {
      const ast__ast__Node *const hin = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), hi);
      const char *andp = ((const char *)({ __auto_type __sc751 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc751); }));
      if (lo != ast__ast__NODE_NONE) {
        (andp = ((const char *)({ __auto_type __sc752 = (str){ (const uint8_t *)" && ", sizeof(" && ") - 1 }; str__ptr(&__sc752); })));
      }
      const char *cmp = ((const char *)({ __auto_type __sc753 = (str){ (const uint8_t *)"<", sizeof("<") - 1 }; str__ptr(&__sc753); }));
      if (p.as_data.pattern_range.inclusive) {
        (cmp = ((const char *)({ __auto_type __sc754 = (str){ (const uint8_t *)"<=", sizeof("<=") - 1 }; str__ptr(&__sc754); })));
      }
      ({ String__Global *__sc755 = &(self->buf);
String__Global__push_str(&(*__sc755), utils__errors__cstr(andp));
String__Global__push_str(&(*__sc755), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc755), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc755), utils__errors__cstr(cmp));
String__Global__push_str(&(*__sc755), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, codegen__codegen__if_node((hin->kind == ast__ast__NodeKind_NODE_PATTERN_LITERAL), hin->as_data.single.value, hi));
    }
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
    ast__ast__DefId vd = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (p.as_data.pattern.name != ast__ast__NODE_NONE) {
      (vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name));
    }
    const ast__ast__NodeList ch = p.as_data.pattern.children;
    if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, vd.module, vd.node);
      const bool payload = ((en != ast__ast__NODE_NONE) && codegen__codegen__Codegen__aggregate_has_payload_in(self, vd.module, en));
      if (payload) {
        ({ String__Global *__sc756 = &(self->buf);
String__Global__push_str(&(*__sc756), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc756), (str){ .ptr = (const uint8_t*)".tag == ", .len = sizeof(".tag == ") - 1 });
});
      } else {
        ({ String__Global *__sc757 = &(self->buf);
String__Global__push_str(&(*__sc757), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc757), (str){ .ptr = (const uint8_t*)" == ", .len = sizeof(" == ") - 1 });
});
      }
      if (en != ast__ast__NODE_NONE) {
        codegen__codegen__Codegen__emit_tag_mod(self, vd.module, en, vd.node);
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc758 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc758); })));
      }
      codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
      codegen__codegen__Codegen__render_variant_name(self, vd.module, vd.node, ((char *)(&vn.b[0])), 128ULL);
      for (uint32_t i = 0U; i < ch.len; i++) {
        const uint32_t cid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[((size_t)i)];
        if (!codegen__codegen__Codegen__pat_trivial(self, cid)) {
          codegen__codegen__Buf256 sub = (codegen__codegen__Buf256){0};
          snprintf(((char *)(&sub.b[0])), 256ULL, ((const char *)({ __auto_type __sc759 = (str){ (const uint8_t *)"%s.payload.%s._%u", sizeof("%s.payload.%s._%u") - 1 }; str__ptr(&__sc759); })), scrut, ((const char *)(&vn.b[0])), i);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc760 = (str){ (const uint8_t *)" && ", sizeof(" && ") - 1 }; str__ptr(&__sc760); })));
          codegen__codegen__Codegen__emit_pattern_test(self, cid, ((const char *)(&sub.b[0])));
        }
      }
    } else if (ch.len == 1U) {
      codegen__codegen__Codegen__emit_pattern_test(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[0], scrut);
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc761 = (str){ (const uint8_t *)"1", sizeof("1") - 1 }; str__ptr(&__sc761); })));
    }
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_STRUCT) {
    ast__ast__DefId vd = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (p.as_data.pattern.name != ast__ast__NODE_NONE) {
      (vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name));
    }
    const bool is_variant = ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT));
    const ast__ast__NodeList ch = p.as_data.pattern.children;
    codegen__codegen__Buf512 prefix = (codegen__codegen__Buf512){0};
    bool wrote = false;
    if (is_variant) {
      const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, vd.module, vd.node);
      const bool payload = ((en != ast__ast__NODE_NONE) && codegen__codegen__Codegen__aggregate_has_payload_in(self, vd.module, en));
      if (payload) {
        ({ String__Global *__sc762 = &(self->buf);
String__Global__push_str(&(*__sc762), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc762), (str){ .ptr = (const uint8_t*)".tag == ", .len = sizeof(".tag == ") - 1 });
});
      } else {
        ({ String__Global *__sc763 = &(self->buf);
String__Global__push_str(&(*__sc763), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc763), (str){ .ptr = (const uint8_t*)" == ", .len = sizeof(" == ") - 1 });
});
      }
      if (en != ast__ast__NODE_NONE) {
        codegen__codegen__Codegen__emit_tag_mod(self, vd.module, en, vd.node);
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc764 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc764); })));
      }
      (wrote = true);
      codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
      codegen__codegen__Codegen__render_variant_name(self, vd.module, vd.node, ((char *)(&vn.b[0])), 128ULL);
      snprintf(((char *)(&prefix.b[0])), 300ULL, ((const char *)({ __auto_type __sc765 = (str){ (const uint8_t *)"%s.payload.%s", sizeof("%s.payload.%s") - 1 }; str__ptr(&__sc765); })), scrut, ((const char *)(&vn.b[0])));
    } else {
      snprintf(((char *)(&prefix.b[0])), 300ULL, ((const char *)({ __auto_type __sc766 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc766); })), scrut);
    }
    for (uint32_t i = 0U; i < ch.len; i++) {
      const uint32_t fid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[((size_t)i)];
      const ast__ast__Node *const f = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fid);
      const ast__ast__NodeList sub = f->as_data.pattern.children;
      uint32_t subpat = ast__ast__NODE_NONE;
      if (sub.len != 0U) {
        (subpat = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), sub)[0]);
      }
      if ((subpat != ast__ast__NODE_NONE) && (!codegen__codegen__Codegen__pat_trivial(self, subpat))) {
        codegen__codegen__Buf128 m = (codegen__codegen__Buf128){0};
        codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, f->as_data.pattern.name), ((char *)(&m.b[0])), 128ULL);
        codegen__codegen__Buf512 acc = (codegen__codegen__Buf512){0};
        snprintf(((char *)(&acc.b[0])), 440ULL, ((const char *)({ __auto_type __sc767 = (str){ (const uint8_t *)"%s.%s", sizeof("%s.%s") - 1 }; str__ptr(&__sc767); })), ((const char *)(&prefix.b[0])), ((const char *)(&m.b[0])));
        if (wrote) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc768 = (str){ (const uint8_t *)" && ", sizeof(" && ") - 1 }; str__ptr(&__sc768); })));
        }
        codegen__codegen__Codegen__emit_pattern_test(self, subpat, ((const char *)(&acc.b[0])));
        (wrote = true);
      }
    }
    if (!wrote) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc769 = (str){ (const uint8_t *)"1", sizeof("1") - 1 }; str__ptr(&__sc769); })));
    }
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList alts = p.as_data.pattern.children;
    if (alts.len == 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc770 = (str){ (const uint8_t *)"1", sizeof("1") - 1 }; str__ptr(&__sc770); })));
      return;
    }
    for (uint32_t i = 0U; i < alts.len; i++) {
      if (i != 0U) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc771 = (str){ (const uint8_t *)" || (", sizeof(" || (") - 1 }; str__ptr(&__sc771); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc772 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc772); })));
      }
      codegen__codegen__Codegen__emit_pattern_test(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), alts)[((size_t)i)], scrut);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc773 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc773); })));
    }
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc774 = (str){ (const uint8_t *)"1", sizeof("1") - 1 }; str__ptr(&__sc774); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_bind(codegen__codegen__Codegen *const self, uint32_t const pid, lexer__token__Span const name, bool const is_mut, const char *const scrut, bool const by_ref) {
  codegen__codegen__Codegen__emit_indent(self);
  if (by_ref) {
    codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
    codegen__codegen__Codegen__render_ident(self, name, ((char *)(&nm.b[0])), 128ULL);
    const char *cq = ((const char *)({ __auto_type __sc775 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc775); }));
    if (is_mut) {
      (cq = ((const char *)({ __auto_type __sc776 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc776); })));
    }
    ({ String__Global *__sc777 = &(self->buf);
String__Global__push_str(&(*__sc777), utils__errors__cstr(cq));
String__Global__push_str(&(*__sc777), (str){ .ptr = (const uint8_t*)"__auto_type ", .len = sizeof("__auto_type ") - 1 });
String__Global__push_str(&(*__sc777), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc777), (str){ .ptr = (const uint8_t*)" = &(", .len = sizeof(" = &(") - 1 });
String__Global__push_str(&(*__sc777), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc777), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
  } else {
    const uint32_t pt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), pid);
    codegen__codegen__Codegen__emit_binding(self, pt, name, ((!is_mut) && (!codegen__codegen__Codegen__cg_type_is_free(self, pt))));
    ({ String__Global *__sc778 = &(self->buf);
String__Global__push_str(&(*__sc778), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc778), utils__errors__cstr(scrut));
String__Global__push_str(&(*__sc778), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_pattern_binds(codegen__codegen__Codegen *const self, uint32_t const pid, const char *const scrut, bool const by_ref) {
  const ast__ast__Node p = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid));
  const ast__ast__NodeKind pk = p.kind;
  if (pk == ast__ast__NodeKind_NODE_PATTERN_NAME) {
    const ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name);
    if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      return;
    }
    const bool is_mut = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name)->as_data.name.is_mutable;
    codegen__codegen__Codegen__emit_bind(self, pid, codegen__codegen__Codegen__name_span(self, p.as_data.pattern.name), is_mut, scrut, by_ref);
    if (p.as_data.pattern.children.len != 0U) {
      codegen__codegen__Codegen__emit_pattern_binds(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.children)[0], scrut, by_ref);
    }
  } else if (pk == ast__ast__NodeKind_NODE_IDENTIFIER) {
    codegen__codegen__Codegen__emit_bind(self, pid, p.as_data.name.text, p.as_data.name.is_mutable, scrut, by_ref);
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
    ast__ast__DefId vd = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (p.as_data.pattern.name != ast__ast__NODE_NONE) {
      (vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name));
    }
    const ast__ast__NodeList ch = p.as_data.pattern.children;
    codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
    (vn.b[0] = 0);
    if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      codegen__codegen__Codegen__render_variant_name(self, vd.module, vd.node, ((char *)(&vn.b[0])), 128ULL);
    }
    for (uint32_t i = 0U; i < ch.len; i++) {
      codegen__codegen__Buf256 sub = (codegen__codegen__Buf256){0};
      if (vn.b[0] != 0) {
        snprintf(((char *)(&sub.b[0])), 256ULL, ((const char *)({ __auto_type __sc779 = (str){ (const uint8_t *)"%s.payload.%s._%u", sizeof("%s.payload.%s._%u") - 1 }; str__ptr(&__sc779); })), scrut, ((const char *)(&vn.b[0])), i);
      } else {
        snprintf(((char *)(&sub.b[0])), 256ULL, ((const char *)({ __auto_type __sc780 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc780); })), scrut);
      }
      codegen__codegen__Codegen__emit_pattern_binds(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[((size_t)i)], ((const char *)(&sub.b[0])), by_ref);
    }
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_STRUCT) {
    ast__ast__DefId vd = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (p.as_data.pattern.name != ast__ast__NODE_NONE) {
      (vd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), p.as_data.pattern.name));
    }
    codegen__codegen__Buf512 prefix = (codegen__codegen__Buf512){0};
    if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
      codegen__codegen__Codegen__render_variant_name(self, vd.module, vd.node, ((char *)(&vn.b[0])), 128ULL);
      snprintf(((char *)(&prefix.b[0])), 300ULL, ((const char *)({ __auto_type __sc781 = (str){ (const uint8_t *)"%s.payload.%s", sizeof("%s.payload.%s") - 1 }; str__ptr(&__sc781); })), scrut, ((const char *)(&vn.b[0])));
    } else {
      snprintf(((char *)(&prefix.b[0])), 300ULL, ((const char *)({ __auto_type __sc782 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc782); })), scrut);
    }
    const ast__ast__NodeList ch = p.as_data.pattern.children;
    for (uint32_t i = 0U; i < ch.len; i++) {
      const uint32_t fid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ch)[((size_t)i)];
      const ast__ast__Node *const f = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fid);
      codegen__codegen__Buf128 m = (codegen__codegen__Buf128){0};
      codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, f->as_data.pattern.name), ((char *)(&m.b[0])), 128ULL);
      codegen__codegen__Buf512 acc = (codegen__codegen__Buf512){0};
      snprintf(((char *)(&acc.b[0])), 440ULL, ((const char *)({ __auto_type __sc783 = (str){ (const uint8_t *)"%s.%s", sizeof("%s.%s") - 1 }; str__ptr(&__sc783); })), ((const char *)(&prefix.b[0])), ((const char *)(&m.b[0])));
      const ast__ast__NodeList sub = f->as_data.pattern.children;
      if (sub.len != 0U) {
        codegen__codegen__Codegen__emit_pattern_binds(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), sub)[0], ((const char *)(&acc.b[0])), by_ref);
      }
    }
  } else if (pk == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList alts = p.as_data.pattern.children;
    if (alts.len != 0U) {
      codegen__codegen__Codegen__emit_pattern_binds(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), alts)[0], scrut, by_ref);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_index(codegen__codegen__Codegen *const self, uint32_t const id, bool const want_mut) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const uint32_t obj = n.as_data.index.object;
  const uint32_t idxNode = n.as_data.index.index;
  const ast__ast__Node idxn = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), idxNode));
  if (idxn.kind == ast__ast__NodeKind_NODE_RANGE) {
    const uint32_t lo = idxn.as_data.pattern_range.start;
    const uint32_t hi = idxn.as_data.pattern_range.end;
    const bool incl = idxn.as_data.pattern_range.inclusive;
    const uint32_t oty0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), obj);
    uint32_t roty = ast__ast__TYPE_NONE;
    if (oty0 != ast__ast__TYPE_NONE) {
      (roty = codegen__codegen__Codegen__strip_ref_only(self, codegen__codegen__Codegen__subst_resolve(self, oty0)));
    }
    int32_t refd = 0;
    if (oty0 != ast__ast__TYPE_NONE) {
      (refd = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, oty0)));
    }
    if ((self->package != NULL) && (!codegen__codegen__Codegen__cg_slice_elem(self, roty, NULL))) {
      ast__ast__TypeKind btk = ast__ast__TypeKind_TYPE_ERROR;
      if (roty != ast__ast__TYPE_NONE) {
        (btk = codegen__codegen__Codegen__type_at(self, roty)->kind);
      }
      if ((roty != ast__ast__TYPE_NONE) && ((btk == ast__ast__TypeKind_TYPE_STRUCT) || (btk == ast__ast__TypeKind_TYPE_INSTANCE))) {
        const ast__ast__Ty bt = (*codegen__codegen__Codegen__type_at(self, roty));
        uint16_t om = 0U;
        uint32_t od = ast__ast__NODE_NONE;
        if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
          const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst));
          (om = it.module);
          (od = it.decl);
        } else {
          (om = bt.module);
          (od = bt.as_data.decl);
        }
        const ast__ast__DefId mth = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc784 = (str){ (const uint8_t *)"index_range", sizeof("index_range") - 1 }; str__ptr(&__sc784); })));
        if (mth.node != ast__ast__NODE_NONE) {
          const module__loader__LookupHit rh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Range", sizeof("Range") - 1 }, true);
          const uint32_t usz = 12U;
          const uint32_t rangeTy = ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), rh.mid, rh.node, ((const uint32_t *)(&usz)), 1U);
          codegen__codegen__Buf256 rn = (codegen__codegen__Buf256){0};
          codegen__codegen__Codegen__render_type_id(self, rangeTy, ((const char *)({ __auto_type __sc785 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc785); })), ((char *)(&rn.b[0])), 200ULL);
          codegen__codegen__Buf32 o = (codegen__codegen__Buf32){0};
          codegen__codegen__Codegen__fresh(self, ((char *)(&o.b[0])), 32ULL);
          if (refd > 0) {
            ({ String__Global *__sc786 = &(self->buf);
String__Global__push_str(&(*__sc786), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc786), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc786), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
            codegen__codegen__Codegen__emit_prefixed(self, obj, codegen__codegen__ref_derefs(refd));
          } else if (codegen__codegen__Codegen__is_lvalue(self, obj)) {
            ({ String__Global *__sc787 = &(self->buf);
String__Global__push_str(&(*__sc787), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc787), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc787), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
            codegen__codegen__Codegen__emit_prefixed(self, obj, ((const char *)({ __auto_type __sc788 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc788); })));
          } else {
            codegen__codegen__Buf32 v = (codegen__codegen__Buf32){0};
            codegen__codegen__Codegen__fresh(self, ((char *)(&v.b[0])), 32ULL);
            ({ String__Global *__sc789 = &(self->buf);
String__Global__push_str(&(*__sc789), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc789), utils__errors__cstr(((const char *)(&v.b[0]))));
String__Global__push_str(&(*__sc789), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
            codegen__codegen__Codegen__emit_expr(self, obj);
            ({ String__Global *__sc790 = &(self->buf);
String__Global__push_str(&(*__sc790), (str){ .ptr = (const uint8_t*)"; __auto_type ", .len = sizeof("; __auto_type ") - 1 });
String__Global__push_str(&(*__sc790), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc790), (str){ .ptr = (const uint8_t*)" = &", .len = sizeof(" = &") - 1 });
String__Global__push_str(&(*__sc790), utils__errors__cstr(((const char *)(&v.b[0]))));
});
          }
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc791 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc791); })));
          codegen__codegen__Codegen__emit_op_method(self, bt, om, od, mth);
          ({ String__Global *__sc792 = &(self->buf);
String__Global__push_str(&(*__sc792), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc792), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc792), (str){ .ptr = (const uint8_t*)", (", .len = sizeof(", (") - 1 });
String__Global__push_str(&(*__sc792), utils__errors__cstr(((const char *)(&rn.b[0]))));
String__Global__push_str(&(*__sc792), (str){ .ptr = (const uint8_t*)"){ .start = ", .len = sizeof("){ .start = ") - 1 });
});
          if (lo != ast__ast__NODE_NONE) {
            codegen__codegen__Codegen__emit_expr(self, lo);
          } else {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc793 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc793); })));
          }
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc794 = (str){ (const uint8_t *)", .end = ", sizeof(", .end = ") - 1 }; str__ptr(&__sc794); })));
          if (hi != ast__ast__NODE_NONE) {
            codegen__codegen__Codegen__emit_expr(self, hi);
          } else {
            const ast__ast__DefId lm = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc795 = (str){ (const uint8_t *)"len", sizeof("len") - 1 }; str__ptr(&__sc795); })));
            if (lm.node != ast__ast__NODE_NONE) {
              codegen__codegen__Codegen__emit_op_method(self, bt, om, od, lm);
              ({ String__Global *__sc796 = &(self->buf);
String__Global__push_str(&(*__sc796), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc796), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc796), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
            } else {
              codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc797 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc797); })));
            }
          }
          const char *incls = ((const char *)({ __auto_type __sc798 = (str){ (const uint8_t *)"false", sizeof("false") - 1 }; str__ptr(&__sc798); }));
          if (incl) {
            (incls = ((const char *)({ __auto_type __sc799 = (str){ (const uint8_t *)"true", sizeof("true") - 1 }; str__ptr(&__sc799); })));
          }
          ({ String__Global *__sc800 = &(self->buf);
String__Global__push_str(&(*__sc800), (str){ .ptr = (const uint8_t*)", .inclusive = ", .len = sizeof(", .inclusive = ") - 1 });
String__Global__push_str(&(*__sc800), utils__errors__cstr(incls));
String__Global__push_str(&(*__sc800), (str){ .ptr = (const uint8_t*)" }); })", .len = sizeof(" }); })") - 1 });
});
          return;
        }
      }
    }
    codegen__codegen__Buf256 styp = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id), ((const char *)({ __auto_type __sc801 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc801); })), ((char *)(&styp.b[0])), 200ULL);
    const bool isslice = codegen__codegen__Codegen__cg_slice_elem(self, roty, NULL);
    uint32_t arrlen = ast__ast__NODE_NONE;
    if (!isslice) {
      (arrlen = codegen__codegen__Codegen__array_length_of(self, obj));
    }
    codegen__codegen__Buf32 b = (codegen__codegen__Buf32){0};
    codegen__codegen__Codegen__fresh(self, ((char *)(&b.b[0])), 32ULL);
    ({ String__Global *__sc802 = &(self->buf);
String__Global__push_str(&(*__sc802), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc802), utils__errors__cstr(((const char *)(&b.b[0]))));
String__Global__push_str(&(*__sc802), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
    if (refd > 0) {
      codegen__codegen__Codegen__emit_prefixed(self, obj, codegen__codegen__ref_derefs(({ int32_t __sc_r; if (__builtin_add_overflow(refd, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
    } else {
      codegen__codegen__Codegen__emit_expr(self, obj);
    }
    const char *sfx = ((const char *)({ __auto_type __sc803 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc803); }));
    if (isslice) {
      (sfx = ((const char *)({ __auto_type __sc804 = (str){ (const uint8_t *)".ptr", sizeof(".ptr") - 1 }; str__ptr(&__sc804); })));
    }
    ({ String__Global *__sc805 = &(self->buf);
String__Global__push_str(&(*__sc805), (str){ .ptr = (const uint8_t*)"; (", .len = sizeof("; (") - 1 });
String__Global__push_str(&(*__sc805), utils__errors__cstr(((const char *)(&styp.b[0]))));
String__Global__push_str(&(*__sc805), (str){ .ptr = (const uint8_t*)"){ .ptr = ", .len = sizeof("){ .ptr = ") - 1 });
String__Global__push_str(&(*__sc805), utils__errors__cstr(((const char *)(&b.b[0]))));
String__Global__push_str(&(*__sc805), utils__errors__cstr(sfx));
String__Global__push_str(&(*__sc805), (str){ .ptr = (const uint8_t*)" + ", .len = sizeof(" + ") - 1 });
});
    if (lo != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc806 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc806); })));
      codegen__codegen__Codegen__emit_expr(self, lo);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc807 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc807); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc808 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc808); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc809 = (str){ (const uint8_t *)", .len = ", sizeof(", .len = ") - 1 }; str__ptr(&__sc809); })));
    if (hi != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc810 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc810); })));
      codegen__codegen__Codegen__emit_expr(self, hi);
      if (incl) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc811 = (str){ (const uint8_t *)") + 1", sizeof(") + 1") - 1 }; str__ptr(&__sc811); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc812 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc812); })));
      }
    } else if (isslice) {
      ({ String__Global *__sc813 = &(self->buf);
String__Global__push_str(&(*__sc813), utils__errors__cstr(((const char *)(&b.b[0]))));
String__Global__push_str(&(*__sc813), (str){ .ptr = (const uint8_t*)".len", .len = sizeof(".len") - 1 });
});
    } else if (arrlen != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_expr(self, arrlen);
    } else {
      const int64_t cnt = codegen__codegen__Codegen__array_literal_count(self, obj);
      if (cnt >= 0) {
        ({ String__Global *__sc814 = &(self->buf);
String__Global__push_i64(&(*__sc814), (int64_t)(cnt));
});
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc815 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc815); })));
      }
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc816 = (str){ (const uint8_t *)" - ", sizeof(" - ") - 1 }; str__ptr(&__sc816); })));
    if (lo != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc817 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc817); })));
      codegen__codegen__Codegen__emit_expr(self, lo);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc818 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc818); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc819 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc819); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc820 = (str){ (const uint8_t *)" }; })", sizeof(" }; })") - 1 }; str__ptr(&__sc820); })));
    return;
  }
  const uint32_t ot = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), obj);
  uint32_t rot = ast__ast__TYPE_NONE;
  if (ot != ast__ast__TYPE_NONE) {
    (rot = codegen__codegen__Codegen__strip_ref_only(self, codegen__codegen__Codegen__subst_resolve(self, ot)));
  }
  int32_t rd = 0;
  if (ot != ast__ast__TYPE_NONE) {
    (rd = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, ot)));
  }
  ast__ast__TypeKind btk = ast__ast__TypeKind_TYPE_ERROR;
  if (rot != ast__ast__TYPE_NONE) {
    (btk = codegen__codegen__Codegen__type_at(self, rot)->kind);
  }
  if (((rot != ast__ast__TYPE_NONE) && ((btk == ast__ast__TypeKind_TYPE_STRUCT) || (btk == ast__ast__TypeKind_TYPE_INSTANCE))) && (!codegen__codegen__Codegen__cg_slice_elem(self, rot, NULL))) {
    const ast__ast__Ty bt = (*codegen__codegen__Codegen__type_at(self, rot));
    uint16_t om = 0U;
    uint32_t od = ast__ast__NODE_NONE;
    if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst));
      (om = it.module);
      (od = it.decl);
    } else {
      (om = bt.module);
      (od = bt.as_data.decl);
    }
    const char *mname = ((const char *)({ __auto_type __sc821 = (str){ (const uint8_t *)"index", sizeof("index") - 1 }; str__ptr(&__sc821); }));
    if (want_mut) {
      (mname = ((const char *)({ __auto_type __sc822 = (str){ (const uint8_t *)"index_mut", sizeof("index_mut") - 1 }; str__ptr(&__sc822); })));
    }
    ast__ast__DefId mth = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, mname);
    if ((mth.node == ast__ast__NODE_NONE) && want_mut) {
      (mth = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, ((const char *)({ __auto_type __sc823 = (str){ (const uint8_t *)"index", sizeof("index") - 1 }; str__ptr(&__sc823); }))));
    }
    if (mth.node != ast__ast__NODE_NONE) {
      ast__ast__Ast *const mam = codegen__codegen__Codegen__mod_ast(self, mth.module);
      const ast__ast__NodeList mrets = ast__ast__Ast__at_const(&((*mam)), mth.node)->as_data.function.returns;
      bool retref = false;
      if (mrets.len == 1U) {
        const uint32_t mr0 = ast__ast__Ast__list(&((*mam)), mrets)[0];
        const ast__ast__Node *const mrn = ast__ast__Ast__at_const(&((*mam)), mr0);
        const uint32_t mtn = codegen__codegen__if_node((mrn->kind == ast__ast__NodeKind_NODE_PARAMETER), mrn->as_data.parameter.ty, mr0);
        (retref = ((mtn != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*mam)), mtn)->kind == ast__ast__NodeKind_NODE_REFERENCE_TYPE)));
      }
      codegen__codegen__Buf32 o = (codegen__codegen__Buf32){0};
      codegen__codegen__Codegen__fresh(self, ((char *)(&o.b[0])), 32ULL);
      if (retref) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc824 = (str){ (const uint8_t *)"(*", sizeof("(*") - 1 }; str__ptr(&__sc824); })));
      }
      if (rd > 0) {
        ({ String__Global *__sc825 = &(self->buf);
String__Global__push_str(&(*__sc825), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc825), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc825), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
        codegen__codegen__Codegen__emit_prefixed(self, obj, codegen__codegen__ref_derefs(rd));
      } else if (codegen__codegen__Codegen__is_lvalue(self, obj)) {
        ({ String__Global *__sc826 = &(self->buf);
String__Global__push_str(&(*__sc826), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc826), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc826), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
        codegen__codegen__Codegen__emit_prefixed(self, obj, ((const char *)({ __auto_type __sc827 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc827); })));
      } else {
        codegen__codegen__Buf32 v = (codegen__codegen__Buf32){0};
        codegen__codegen__Codegen__fresh(self, ((char *)(&v.b[0])), 32ULL);
        ({ String__Global *__sc828 = &(self->buf);
String__Global__push_str(&(*__sc828), (str){ .ptr = (const uint8_t*)"({ __auto_type ", .len = sizeof("({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc828), utils__errors__cstr(((const char *)(&v.b[0]))));
String__Global__push_str(&(*__sc828), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, obj);
        ({ String__Global *__sc829 = &(self->buf);
String__Global__push_str(&(*__sc829), (str){ .ptr = (const uint8_t*)"; __auto_type ", .len = sizeof("; __auto_type ") - 1 });
String__Global__push_str(&(*__sc829), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc829), (str){ .ptr = (const uint8_t*)" = &", .len = sizeof(" = &") - 1 });
String__Global__push_str(&(*__sc829), utils__errors__cstr(((const char *)(&v.b[0]))));
});
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc830 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc830); })));
      codegen__codegen__Codegen__emit_op_method(self, bt, om, od, mth);
      ({ String__Global *__sc831 = &(self->buf);
String__Global__push_str(&(*__sc831), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc831), utils__errors__cstr(((const char *)(&o.b[0]))));
String__Global__push_str(&(*__sc831), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, idxNode);
      if (retref) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc832 = (str){ (const uint8_t *)"); }))", sizeof("); }))") - 1 }; str__ptr(&__sc832); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc833 = (str){ (const uint8_t *)"); })", sizeof("); })") - 1 }; str__ptr(&__sc833); })));
      }
      return;
    }
  }
  const uint32_t bty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), obj);
  uint32_t rbty = ast__ast__TYPE_NONE;
  if (bty != ast__ast__TYPE_NONE) {
    (rbty = codegen__codegen__Codegen__strip_ref_only(self, codegen__codegen__Codegen__subst_resolve(self, bty)));
  }
  int32_t rd2 = 0;
  if (bty != ast__ast__TYPE_NONE) {
    (rd2 = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, bty)));
  }
  if (codegen__codegen__Codegen__cg_slice_elem(self, rbty, NULL)) {
    codegen__codegen__Codegen__emit_slice_base(self, obj, rd2);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc834 = (str){ (const uint8_t *)".ptr[__sc_bounds(", sizeof(".ptr[__sc_bounds(") - 1 }; str__ptr(&__sc834); })));
    codegen__codegen__Codegen__emit_expr(self, idxNode);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc835 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc835); })));
    codegen__codegen__Codegen__emit_slice_base(self, obj, rd2);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc836 = (str){ (const uint8_t *)".len)]", sizeof(".len)]") - 1 }; str__ptr(&__sc836); })));
    return;
  }
  const ast__ast__Ty oty = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), obj))));
  uint32_t lenN = ast__ast__NODE_NONE;
  if (oty.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    (lenN = codegen__codegen__Codegen__array_length_of(self, obj));
  }
  int64_t licnt = -1;
  if ((oty.kind == ast__ast__TypeKind_TYPE_ARRAY) && (lenN == ast__ast__NODE_NONE)) {
    (licnt = codegen__codegen__Codegen__array_literal_count(self, obj));
  }
  if ((lenN != ast__ast__NODE_NONE) || (licnt >= 0)) {
    int64_t iv = 0;
    int64_t nv = licnt;
    bool nconst = (licnt >= 0);
    if (lenN != ast__ast__NODE_NONE) {
      (nconst = codegen__codegen__Codegen__cg_int_lit(self, lenN, ((int64_t *)(&nv))));
    }
    if (codegen__codegen__Codegen__cg_int_lit(self, idxNode, ((int64_t *)(&iv))) && nconst) {
      if ((iv < 0) || (iv >= nv)) {
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), idxNode)->span;
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc837 = String__Global__new();
String__Global__push_str(&__sc837, (str){ .ptr = (const uint8_t*)"index ", .len = sizeof("index ") - 1 });
String__Global__push_i64(&__sc837, (int64_t)(iv));
String__Global__push_str(&__sc837, (str){ .ptr = (const uint8_t*)" is out of bounds for an array of length ", .len = sizeof(" is out of bounds for an array of length ") - 1 });
String__Global__push_i64(&__sc837, (int64_t)(nv));
__sc837; }));
      }
      codegen__codegen__Codegen__emit_expr(self, obj);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc838 = (str){ (const uint8_t *)"[", sizeof("[") - 1 }; str__ptr(&__sc838); })));
      codegen__codegen__Codegen__emit_expr(self, idxNode);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc839 = (str){ (const uint8_t *)"]", sizeof("]") - 1 }; str__ptr(&__sc839); })));
      return;
    }
    codegen__codegen__Codegen__emit_expr(self, obj);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc840 = (str){ (const uint8_t *)"[__sc_bounds(", sizeof("[__sc_bounds(") - 1 }; str__ptr(&__sc840); })));
    codegen__codegen__Codegen__emit_expr(self, idxNode);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc841 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc841); })));
    if (lenN != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_expr(self, lenN);
    } else {
      ({ String__Global *__sc842 = &(self->buf);
String__Global__push_i64(&(*__sc842), (int64_t)(licnt));
});
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc843 = (str){ (const uint8_t *)")]", sizeof(")]") - 1 }; str__ptr(&__sc843); })));
    return;
  }
  codegen__codegen__Codegen__emit_expr(self, obj);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc844 = (str){ (const uint8_t *)"[", sizeof("[") - 1 }; str__ptr(&__sc844); })));
  codegen__codegen__Codegen__emit_expr(self, idxNode);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc845 = (str){ (const uint8_t *)"]", sizeof("]") - 1 }; str__ptr(&__sc845); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_place(codegen__codegen__Codegen *const self, uint32_t const id, bool const want_mut) {
  const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->kind;
  if (k == ast__ast__NodeKind_NODE_MEMBER) {
    codegen__codegen__Codegen__emit_member(self, id, want_mut);
  } else if ((want_mut && (k == ast__ast__NodeKind_NODE_INDEX)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.index.index)->kind != ast__ast__NodeKind_NODE_RANGE)) {
    codegen__codegen__Codegen__emit_index(self, id, true);
  } else {
    codegen__codegen__Codegen__emit_expr(self, id);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_member(codegen__codegen__Codegen *const self, uint32_t const id, bool const want_mut) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  if (n.as_data.member.path) {
    ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), id);
    if (d.node == ast__ast__NODE_NONE) {
      (d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.member.member));
    }
    ast__ast__NodeKind dk = ast__ast__NodeKind_NODE_NONE_KIND;
    if (d.node != ast__ast__NODE_NONE) {
      (dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->kind);
    }
    if (((d.node != ast__ast__NODE_NONE) && (dk == ast__ast__NodeKind_NODE_CONST)) && ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.const_def.is_extern) {
      codegen__codegen__Buf256 ov = (codegen__codegen__Buf256){0};
      if (codegen__codegen__Codegen__cg_symbol_override(self, d.module, d.node, ((char *)(&ov.b[0])), 160ULL)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&ov.b[0])));
      } else {
        codegen__codegen__Codegen__emit_ident_mod(self, d.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.const_def.name);
      }
    } else if (((d.node != ast__ast__NODE_NONE) && (dk == ast__ast__NodeKind_NODE_CONST)) && codegen__codegen__Codegen__decl_is_toplevel(self, d.module, d.node)) {
      codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_qualified(self, d.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.const_def.name, ((char *)(&nm.b[0])), 160ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
    } else if ((d.node != ast__ast__NODE_NONE) && (dk == ast__ast__NodeKind_NODE_FUNCTION)) {
      codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_qualified(self, d.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.function.name, ((char *)(&nm.b[0])), 160ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
    } else if ((d.node != ast__ast__NODE_NONE) && (dk == ast__ast__NodeKind_NODE_CONST)) {
      ast__ast__Ast *const da = codegen__codegen__Codegen__mod_ast(self, d.module);
      const ast__ast__NodeList ditems = ast__ast__Ast__at_const(&((*da)), (*da).root)->as_data.program.items;
      ast__ast__DefId target = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
      uint32_t di = 0U;
      while ((di < ditems.len) && (target.node == ast__ast__NODE_NONE)) {
        const uint32_t did = ast__ast__Ast__list(&((*da)), ditems)[((size_t)di)];
        const ast__ast__Node *const de = ast__ast__Ast__at_const(&((*da)), did);
        if (de->kind == ast__ast__NodeKind_NODE_EXTEND) {
          const ast__ast__NodeList dmis = de->as_data.extend_def.items;
          for (uint32_t dj = 0U; dj < dmis.len; dj++) {
            if (ast__ast__Ast__list(&((*da)), dmis)[((size_t)dj)] == d.node) {
              (target = ast__ast__Ast__resolution_def(&((*da)), de->as_data.extend_def.target_type));
            }
          }
        }
        (di = (di + 1U));
      }
      codegen__codegen__Buf512 nm = (codegen__codegen__Buf512){0};
      size_t k = codegen__codegen__Codegen__render_modpfx(self, d.module, ((char *)(&nm.b[0])), 256ULL);
      int32_t bb = -1;
      if ((self->package != NULL) && (target.node != ast__ast__NODE_NONE)) {
        (bb = module__loader__Package__builtin_of_decl(&((*self->package)), target.module, target.node));
      }
      if (bb >= 0) {
        (k = codegen__codegen__bappend(((char *)(&nm.b[0])), 256ULL, k, codegen__codegen__builtin_name(((ast__ast__BuiltinType)bb))));
      } else if (target.node != ast__ast__NODE_NONE) {
        (k = (k + codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, target.module), codegen__codegen__Codegen__name_span_in(self, target.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, target.module))), target.node)->as_data.aggregate.name), (((char *)(&nm.b[0])) + k), (256ULL - k))));
      }
      (k = codegen__codegen__bappend(((char *)(&nm.b[0])), 256ULL, k, ((const char *)({ __auto_type __sc846 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc846); }))));
      codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, d.module), ast__ast__Ast__at_const(&((*da)), ast__ast__Ast__at_const(&((*da)), d.node)->as_data.const_def.name)->as_data.name.text, (((char *)(&nm.b[0])) + k), (256ULL - k));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
    } else {
      codegen__codegen__Codegen__emit_variant_value(self, d, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
    }
    return;
  }
  const ast__ast__Ty ot = (*codegen__codegen__Codegen__type_at(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.member.object)));
  const bool ptr = ((ot.kind == ast__ast__TypeKind_TYPE_POINTER) || (ot.kind == ast__ast__TypeKind_TYPE_REFERENCE));
  codegen__codegen__Codegen__emit_place(self, n.as_data.member.object, want_mut);
  if (ptr) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc847 = (str){ (const uint8_t *)"->", sizeof("->") - 1 }; str__ptr(&__sc847); })));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc848 = (str){ (const uint8_t *)".", sizeof(".") - 1 }; str__ptr(&__sc848); })));
  }
  const lexer__token__Span msp = codegen__codegen__Codegen__name_span(self, n.as_data.member.member);
  if ((self->source[((size_t)msp.start)] >= 48U) && (self->source[((size_t)msp.start)] <= 57U)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc849 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc849); })));
  }
  codegen__codegen__Codegen__emit_ident(self, msp);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_sizeof(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const uint32_t vnode = n.as_data.single.value;
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), vnode);
  ast__ast__NodeKind dk = ast__ast__NodeKind_NODE_NONE_KIND;
  if (d.node != ast__ast__NODE_NONE) {
    (dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->kind);
  }
  codegen__codegen__Buf256 ty = (codegen__codegen__Buf256){0};
  if ((d.node != ast__ast__NODE_NONE) && ((((((dk == ast__ast__NodeKind_NODE_LET) || (dk == ast__ast__NodeKind_NODE_PARAMETER)) || (dk == ast__ast__NodeKind_NODE_FOR)) || (dk == ast__ast__NodeKind_NODE_IDENTIFIER)) || (dk == ast__ast__NodeKind_NODE_PATTERN_NAME)) || (dk == ast__ast__NodeKind_NODE_CONST))) {
    if (n.kind == ast__ast__NodeKind_NODE_ALIGNOF) {
      uint32_t vt = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), vnode));
      const ast__ast__Ty *y = codegen__codegen__Codegen__type_at(self, vt);
      while (y->kind == ast__ast__TypeKind_TYPE_ARRAY) {
        (vt = y->as_data.arr.elem);
        (y = codegen__codegen__Codegen__type_at(self, vt));
      }
      codegen__codegen__Codegen__render_type_id(self, vt, ((const char *)({ __auto_type __sc850 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc850); })), ((char *)(&ty.b[0])), 256ULL);
    } else if ((dk == ast__ast__NodeKind_NODE_CONST) && ((!self->mangle) || codegen__codegen__Codegen__decl_is_toplevel(self, d.module, d.node))) {
      codegen__codegen__Codegen__render_qualified(self, d.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.const_def.name, ((char *)(&ty.b[0])), 256ULL);
    } else {
      codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__cg_decl_name_span(self, d.node), ((char *)(&ty.b[0])), 256ULL);
    }
  } else {
    codegen__codegen__Codegen__render_type_node(self, vnode, ((const char *)({ __auto_type __sc851 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc851); })), ((char *)(&ty.b[0])), 256ULL);
  }
  if (n.kind == ast__ast__NodeKind_NODE_ALIGNOF) {
    ({ String__Global *__sc852 = &(self->buf);
String__Global__push_str(&(*__sc852), (str){ .ptr = (const uint8_t*)"_Alignof(", .len = sizeof("_Alignof(") - 1 });
String__Global__push_str(&(*__sc852), utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&(*__sc852), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
  } else {
    ({ String__Global *__sc853 = &(self->buf);
String__Global__push_str(&(*__sc853), (str){ .ptr = (const uint8_t*)"sizeof(", .len = sizeof("sizeof(") - 1 });
String__Global__push_str(&(*__sc853), utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&(*__sc853), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_loop_expr(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const uint32_t saved_ldb = self->loop_defer_base;
  (self->loop_defer_base = self->defer_top);
  const int32_t le = codegen__codegen__Codegen__cg_loop_push(self, id, true);
  const uint32_t ty = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  bool has_val = false;
  if (ty != ast__ast__TYPE_NONE) {
    const ast__ast__TypeKind yk = codegen__codegen__Codegen__type_at(self, ty)->kind;
    (has_val = ((yk != ast__ast__TypeKind_TYPE_NEVER) && (!((yk == ast__ast__TypeKind_TYPE_BUILTIN) && (codegen__codegen__Codegen__type_at(self, ty)->as_data.builtin == ast__ast__BuiltinType_BT_VOID)))));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc854 = (str){ (const uint8_t *)"({ ", sizeof("({ ") - 1 }; str__ptr(&__sc854); })));
  if (has_val && (le >= 0)) {
    codegen__codegen__Buf32 vn = (codegen__codegen__Buf32){0};
    snprintf(((char *)(&vn.b[0])), 32ULL, ((const char *)({ __auto_type __sc855 = (str){ (const uint8_t *)"__lv%u", sizeof("__lv%u") - 1 }; str__ptr(&__sc855); })), self->loop_stack[((size_t)le)].seq);
    codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, ty, ((const char *)(&vn.b[0])), ((char *)(&decl.b[0])), 256ULL);
    ({ String__Global *__sc856 = &(self->buf);
String__Global__push_str(&(*__sc856), utils__errors__cstr(((const char *)(&decl.b[0]))));
String__Global__push_str(&(*__sc856), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc857 = (str){ (const uint8_t *)"for (;;) ", sizeof("for (;;) ") - 1 }; str__ptr(&__sc857); })));
  (self->pending_cnt = ((uint32_t)({ int32_t __sc_r; if (__builtin_add_overflow(le, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
  codegen__codegen__Codegen__emit_block(self, n.as_data.while_stmt.body);
  if ((le >= 0) && self->loop_stack[((size_t)le)].used_brk) {
    ({ String__Global *__sc858 = &(self->buf);
String__Global__push_str(&(*__sc858), (str){ .ptr = (const uint8_t*)" __brk", .len = sizeof(" __brk") - 1 });
String__Global__push_u64(&(*__sc858), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc858), (str){ .ptr = (const uint8_t*)":;", .len = sizeof(":;") - 1 });
});
  }
  if (has_val && (le >= 0)) {
    ({ String__Global *__sc859 = &(self->buf);
String__Global__push_str(&(*__sc859), (str){ .ptr = (const uint8_t*)" __lv", .len = sizeof(" __lv") - 1 });
String__Global__push_u64(&(*__sc859), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc859), (str){ .ptr = (const uint8_t*)"; })", .len = sizeof("; })") - 1 });
});
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc860 = (str){ (const uint8_t *)" })", sizeof(" })") - 1 }; str__ptr(&__sc860); })));
  }
  codegen__codegen__Codegen__cg_loop_pop(self, le);
  (self->loop_defer_base = saved_ldb);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_stmt_diverges(const codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  if (((n->kind == ast__ast__NodeKind_NODE_RETURN) || (n->kind == ast__ast__NodeKind_NODE_BREAK)) || (n->kind == ast__ast__NodeKind_NODE_CONTINUE)) {
    return true;
  }
  if (n->kind == ast__ast__NodeKind_NODE_BLOCK) {
    const ast__ast__NodeList s = n->as_data.block.statements;
    return ((s.len > 0U) && codegen__codegen__Codegen__cg_stmt_diverges(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), s)[((size_t)(s.len - 1U))]));
  }
  if (n->kind == ast__ast__NodeKind_NODE_IF) {
    return (((n->as_data.if_stmt.else_branch != ast__ast__NODE_NONE) && codegen__codegen__Codegen__cg_stmt_diverges(self, n->as_data.if_stmt.then_branch)) && codegen__codegen__Codegen__cg_stmt_diverges(self, n->as_data.if_stmt.else_branch));
  }
  return false;
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_loop_push(codegen__codegen__Codegen *const self, uint32_t const node, bool const is_expr) {
  if (self->nloops >= 32U) {
    return -1;
  }
  const uint32_t k = self->nloops;
  (self->loop_stack[((size_t)k)] = (codegen__codegen__CgLoop){ .node = node, .defer_base = self->defer_top, .seq = self->label_seq, .used_brk = false, .used_cnt = false, .is_expr = is_expr });
  (self->label_seq = (self->label_seq + 1U));
  (self->nloops = (k + 1U));
  return ((int32_t)k);
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_loop_pop(codegen__codegen__Codegen *const self, int32_t const le) {
  if (le >= 0) {
    (self->nloops = ((uint32_t)le));
  }
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_loop_find(const codegen__codegen__Codegen *const self, uint32_t const node) {
  uint32_t i = self->nloops;
  while (i > 0U) {
    if (self->loop_stack[((size_t)(i - 1U))].node == node) {
      return ((int32_t)(i - 1U));
    }
    (i = (i - 1U));
  }
  return -1;
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_loop_brk_label(codegen__codegen__Codegen *const self, int32_t const le) {
  if ((le >= 0) && self->loop_stack[((size_t)le)].used_brk) {
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc861 = &(self->buf);
String__Global__push_str(&(*__sc861), (str){ .ptr = (const uint8_t*)"__brk", .len = sizeof("__brk") - 1 });
String__Global__push_u64(&(*__sc861), (uint64_t)(self->loop_stack[((size_t)le)].seq));
String__Global__push_str(&(*__sc861), (str){ .ptr = (const uint8_t*)":;\n", .len = sizeof(":;\n") - 1 });
});
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_defers_to(codegen__codegen__Codegen *const self, uint32_t const base) {
  uint32_t i = self->defer_top;
  while (i > base) {
    (i = (i - 1U));
    codegen__codegen__Codegen__emit_indent(self);
    if (self->defer_kind[((size_t)i)] == 1U) {
      codegen__codegen__Codegen__emit_auto_free(self, self->defer_stack[((size_t)i)]);
    } else {
      codegen__codegen__Codegen__emit_expr_stmt(self, self->defer_stack[((size_t)i)]);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_block_from(codegen__codegen__Codegen *const self, uint32_t const id, uint32_t const dbase) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const uint32_t cnt_hook = self->pending_cnt;
  (self->pending_cnt = 0U);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc862 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc862); })));
  (self->depth = (self->depth + 1U));
  uint32_t i = 0U;
  while (i < self->nparam_flags) {
    codegen__codegen__Buf32 fl = (codegen__codegen__Buf32){0};
    codegen__codegen__cg_move_flag(((char *)(&fl.b[0])), 32ULL, self->param_flags[((size_t)i)]);
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc863 = &(self->buf);
String__Global__push_str(&(*__sc863), (str){ .ptr = (const uint8_t*)"bool ", .len = sizeof("bool ") - 1 });
String__Global__push_str(&(*__sc863), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc863), (str){ .ptr = (const uint8_t*)" = false;\n", .len = sizeof(" = false;\n") - 1 });
});
    (i = (i + 1U));
  }
  (self->nparam_flags = 0U);
  (i = 0U);
  while (i < self->nunused_params) {
    codegen__codegen__Buf128 pn = (codegen__codegen__Buf128){0};
    codegen__codegen__Codegen__render_ident(self, codegen__codegen__Codegen__name_span(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), self->unused_params[((size_t)i)])->as_data.parameter.name), ((char *)(&pn.b[0])), 128ULL);
    if ((pn.b[0] == 95) && (pn.b[1] == 0)) {
      snprintf(((char *)(&pn.b[0])), 128ULL, ((const char *)({ __auto_type __sc864 = (str){ (const uint8_t *)"__sc_u%u", sizeof("__sc_u%u") - 1 }; str__ptr(&__sc864); })), self->unused_params[((size_t)i)]);
    }
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc865 = &(self->buf);
String__Global__push_str(&(*__sc865), (str){ .ptr = (const uint8_t*)"(void)", .len = sizeof("(void)") - 1 });
String__Global__push_str(&(*__sc865), utils__errors__cstr(((const char *)(&pn.b[0]))));
String__Global__push_str(&(*__sc865), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    (i = (i + 1U));
  }
  (self->nunused_params = 0U);
  const ast__ast__NodeList stmts = n.as_data.block.statements;
  (i = 0U);
  while (i < stmts.len) {
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_stmt(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)]);
    (i = (i + 1U));
  }
  bool diverges = false;
  if (stmts.len > 0U) {
    (diverges = codegen__codegen__Codegen__cg_stmt_diverges(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)(stmts.len - 1U))]));
  }
  if (!diverges) {
    codegen__codegen__Codegen__emit_defers_to(self, dbase);
  }
  (self->defer_top = dbase);
  if ((cnt_hook != 0U) && self->loop_stack[((size_t)(cnt_hook - 1U))].used_cnt) {
    codegen__codegen__Codegen__emit_indent(self);
    ({ String__Global *__sc866 = &(self->buf);
String__Global__push_str(&(*__sc866), (str){ .ptr = (const uint8_t*)"__cnt", .len = sizeof("__cnt") - 1 });
String__Global__push_u64(&(*__sc866), (uint64_t)(self->loop_stack[((size_t)(cnt_hook - 1U))].seq));
String__Global__push_str(&(*__sc866), (str){ .ptr = (const uint8_t*)":;\n", .len = sizeof(":;\n") - 1 });
});
  }
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc867 = (str){ (const uint8_t *)"}", sizeof("}") - 1 }; str__ptr(&__sc867); })));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emits_own_parens(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  if (((codegen__codegen__Codegen__ceval(self) != NULL) && codegen__codegen__Codegen__cg_maybe_const(self, id)) && (consteval__consteval__ConstEval__eval(&((*codegen__codegen__Codegen__ceval(self))), codegen__codegen__Codegen__cur_module(self), id).kind != consteval__consteval__CONST_NONE)) {
    return false;
  }
  if ((n.kind == ast__ast__NodeKind_NODE_BINARY) || (n.kind == ast__ast__NodeKind_NODE_CAST)) {
    return true;
  }
  if (n.kind == ast__ast__NodeKind_NODE_UNARY) {
    if ((n.as_data.unary.op != lexer__token_type__TokenType_Move) && (n.as_data.unary.op != lexer__token_type__TokenType_Unsafe)) {
      return true;
    }
    return codegen__codegen__Codegen__emits_own_parens(self, n.as_data.unary.operand);
  }
  if (n.kind == ast__ast__NodeKind_NODE_NEW) {
    return (n.as_data.new_expr.initializer == ast__ast__NODE_NONE);
  }
  return false;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_condition(codegen__codegen__Codegen *const self, uint32_t const id) {
  if (codegen__codegen__Codegen__emits_own_parens(self, id)) {
    codegen__codegen__Codegen__emit_expr(self, id);
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc868 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc868); })));
    codegen__codegen__Codegen__emit_expr(self, id);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc869 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc869); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_if(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__IfData ifd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.if_stmt;
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc870 = (str){ (const uint8_t *)"if ", sizeof("if ") - 1 }; str__ptr(&__sc870); })));
  codegen__codegen__Codegen__emit_condition(self, ifd.condition);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc871 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc871); })));
  codegen__codegen__Codegen__emit_block(self, ifd.then_branch);
  if (ifd.else_branch != ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc872 = (str){ (const uint8_t *)" else ", sizeof(" else ") - 1 }; str__ptr(&__sc872); })));
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ifd.else_branch)->kind == ast__ast__NodeKind_NODE_IF) {
      codegen__codegen__Codegen__emit_if(self, ifd.else_branch);
    } else {
      codegen__codegen__Codegen__emit_block(self, ifd.else_branch);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_block_value(codegen__codegen__Codegen *const self, uint32_t const id, const char *const result) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc873 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc873); })));
  (self->depth = (self->depth + 1U));
  const uint32_t dbase = self->defer_top;
  const ast__ast__NodeList stmts = n.as_data.block.statements;
  for (uint32_t i = 0U; i < stmts.len; i++) {
    const uint32_t sid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)];
    const ast__ast__Node s = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), sid));
    codegen__codegen__Codegen__emit_indent(self);
    if (((i + 1U) == stmts.len) && (s.kind == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT)) {
      const uint32_t vt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), s.as_data.single.value);
      if ((vt == ast__ast__TYPE_NONE) || (codegen__codegen__Codegen__type_at(self, vt)->kind != ast__ast__TypeKind_TYPE_NEVER)) {
        ({ String__Global *__sc874 = &(self->buf);
String__Global__push_str(&(*__sc874), utils__errors__cstr(result));
String__Global__push_str(&(*__sc874), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
      }
      codegen__codegen__Codegen__emit_expr(self, s.as_data.single.value);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc875 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc875); })));
    } else {
      codegen__codegen__Codegen__emit_stmt(self, sid);
    }
  }
  codegen__codegen__Codegen__emit_defers_to(self, dbase);
  (self->defer_top = dbase);
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc876 = (str){ (const uint8_t *)"}", sizeof("}") - 1 }; str__ptr(&__sc876); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_if_value(codegen__codegen__Codegen *const self, uint32_t const id, const char *const result) {
  const ast__ast__IfData ifd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.if_stmt;
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc877 = (str){ (const uint8_t *)"if ", sizeof("if ") - 1 }; str__ptr(&__sc877); })));
  codegen__codegen__Codegen__emit_condition(self, ifd.condition);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc878 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc878); })));
  codegen__codegen__Codegen__emit_block_value(self, ifd.then_branch, result);
  if (ifd.else_branch != ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc879 = (str){ (const uint8_t *)" else ", sizeof(" else ") - 1 }; str__ptr(&__sc879); })));
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ifd.else_branch)->kind == ast__ast__NodeKind_NODE_IF) {
      codegen__codegen__Codegen__emit_if_value(self, ifd.else_branch, result);
    } else {
      codegen__codegen__Codegen__emit_block_value(self, ifd.else_branch, result);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_prefixed(codegen__codegen__Codegen *const self, uint32_t const obj, const char *const prefix) {
  const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), obj)->kind;
  const bool primary = ((((k == ast__ast__NodeKind_NODE_IDENTIFIER) || (k == ast__ast__NodeKind_NODE_MEMBER)) || (k == ast__ast__NodeKind_NODE_INDEX)) || (k == ast__ast__NodeKind_NODE_CALL));
  codegen__codegen__Codegen__emit_cstr(self, prefix);
  if (primary) {
    codegen__codegen__Codegen__emit_expr(self, obj);
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc880 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc880); })));
    codegen__codegen__Codegen__emit_expr(self, obj);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc881 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc881); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_recv_addr(codegen__codegen__Codegen *const self, uint32_t const obj, bool const want_mut) {
  if (want_mut) {
    const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), obj)->kind;
    const bool idx_ok = ((k == ast__ast__NodeKind_NODE_INDEX) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), obj)->as_data.index.index)->kind != ast__ast__NodeKind_NODE_RANGE));
    if (idx_ok || (k == ast__ast__NodeKind_NODE_MEMBER)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc882 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc882); })));
      codegen__codegen__Codegen__emit_place(self, obj, true);
      return;
    }
  }
  codegen__codegen__Codegen__emit_prefixed(self, obj, ((const char *)({ __auto_type __sc883 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc883); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_slice_base(codegen__codegen__Codegen *const self, uint32_t const obj, int32_t const rd) {
  if (rd == 0) {
    codegen__codegen__Codegen__emit_expr(self, obj);
    return;
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc884 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc884); })));
  codegen__codegen__Codegen__emit_prefixed(self, obj, codegen__codegen__ref_derefs(({ int32_t __sc_r; if (__builtin_add_overflow(rd, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc885 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc885); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_enum_cname(codegen__codegen__Codegen *const self, ast__ast__DefId const v, uint32_t const en, uint32_t const enum_ty, char *const buf, size_t const cap) {
  if ((enum_ty != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, enum_ty)->kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), codegen__codegen__Codegen__type_at(self, enum_ty)->as_data.inst), buf, cap);
  } else {
    codegen__codegen__Codegen__render_qualified(self, v.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, v.module))), en)->as_data.aggregate.name, buf, cap);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_variant_value(codegen__codegen__Codegen *const self, ast__ast__DefId const v, uint32_t const enum_ty) {
  const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, v.module, v.node);
  if (en == ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc886 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc886); })));
    return;
  }
  if (!codegen__codegen__Codegen__aggregate_has_payload_in(self, v.module, en)) {
    codegen__codegen__Codegen__emit_tag_mod(self, v.module, en, v.node);
    return;
  }
  codegen__codegen__Buf256 enm = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__render_enum_cname(self, v, en, enum_ty, ((char *)(&enm.b[0])), 200ULL);
  ({ String__Global *__sc887 = &(self->buf);
String__Global__push_str(&(*__sc887), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc887), utils__errors__cstr(((const char *)(&enm.b[0]))));
String__Global__push_str(&(*__sc887), (str){ .ptr = (const uint8_t*)"){ .tag = ", .len = sizeof("){ .tag = ") - 1 });
});
  codegen__codegen__Codegen__emit_tag_mod(self, v.module, en, v.node);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc888 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc888); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_variant_construct(codegen__codegen__Codegen *const self, ast__ast__DefId const v, ast__ast__NodeList const args, const uint32_t *const aids, uint32_t const enum_ty) {
  const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, v.module, v.node);
  if ((en == ast__ast__NODE_NONE) || (!codegen__codegen__Codegen__aggregate_has_payload_in(self, v.module, en))) {
    codegen__codegen__Codegen__emit_variant_value(self, v, enum_ty);
    return;
  }
  codegen__codegen__Buf256 enm = (codegen__codegen__Buf256){0};
  codegen__codegen__Buf128 vn = (codegen__codegen__Buf128){0};
  codegen__codegen__Codegen__render_enum_cname(self, v, en, enum_ty, ((char *)(&enm.b[0])), 200ULL);
  codegen__codegen__Codegen__render_variant_name(self, v.module, v.node, ((char *)(&vn.b[0])), 128ULL);
  ({ String__Global *__sc889 = &(self->buf);
String__Global__push_str(&(*__sc889), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc889), utils__errors__cstr(((const char *)(&enm.b[0]))));
String__Global__push_str(&(*__sc889), (str){ .ptr = (const uint8_t*)"){ .tag = ", .len = sizeof("){ .tag = ") - 1 });
});
  codegen__codegen__Codegen__emit_tag_mod(self, v.module, en, v.node);
  if (args.len != 0U) {
    ({ String__Global *__sc890 = &(self->buf);
String__Global__push_str(&(*__sc890), (str){ .ptr = (const uint8_t*)", .payload.", .len = sizeof(", .payload.") - 1 });
String__Global__push_str(&(*__sc890), utils__errors__cstr(((const char *)(&vn.b[0]))));
String__Global__push_str(&(*__sc890), (str){ .ptr = (const uint8_t*)" = { ", .len = sizeof(" = { ") - 1 });
});
    for (uint32_t i = 0U; i < args.len; i++) {
      if (i != 0U) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc891 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc891); })));
      }
      codegen__codegen__Codegen__emit_expr(self, aids[((size_t)i)]);
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc892 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc892); })));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc893 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc893); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_method_targs(codegen__codegen__Codegen *const self, uint32_t const callId, ast__ast__DefId const md) {
  const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, md.module))), md.node);
  if ((mn->kind != ast__ast__NodeKind_NODE_FUNCTION) || (mn->as_data.function.generics.len == 0U)) {
    return;
  }
  const ast__ast__MonoUse *const mu = ast__ast__Ast__type_args(&((*codegen__codegen__Codegen__cur_ast(self))), callId);
  uint8_t i = 0U;
  while ((mu != NULL) && (i < (*mu).n)) {
    codegen__codegen__Buf256 e = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__mangle_type(self, codegen__codegen__Codegen__subst_resolve(self, (*mu).args[((size_t)i)]), ((char *)(&e.b[0])), 176ULL);
    ({ String__Global *__sc894 = &(self->buf);
String__Global__push_str(&(*__sc894), (str){ .ptr = (const uint8_t*)"__", .len = sizeof("__") - 1 });
String__Global__push_str(&(*__sc894), utils__errors__cstr(((const char *)(&e.b[0]))));
});
    (i = ((uint8_t)((uint32_t)i + (uint32_t)1U)));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_op_method(codegen__codegen__Codegen *const self, ast__ast__Ty const bt, uint16_t const om, uint32_t const od, ast__ast__DefId const mth) {
  if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    codegen__codegen__Buf256 inm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__inst_name(self, ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst), ((char *)(&inm.b[0])), 200ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&inm.b[0])));
    codegen__codegen__Codegen__emit_paste(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc895 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc895); })));
  } else {
    codegen__codegen__Buf64 pfx = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_modpfx(self, mth.module, ((char *)(&pfx.b[0])), 64ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&pfx.b[0])));
    codegen__codegen__Codegen__emit_ident_mod(self, om, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, om))), od)->as_data.aggregate.name);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc896 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc896); })));
  }
  codegen__codegen__Codegen__emit_ident_mod(self, mth.module, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, mth.module))), mth.node)->as_data.function.name);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_cmp_overload(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.binary;
  const lexer__token_type__TokenType op = bd.op;
  if ((((((op != lexer__token_type__TokenType_EqualEqual) && (op != lexer__token_type__TokenType_BangEqual)) && (op != lexer__token_type__TokenType_LessThan)) && (op != lexer__token_type__TokenType_LessThanEqual)) && (op != lexer__token_type__TokenType_GreaterThan)) && (op != lexer__token_type__TokenType_GreaterThanEqual)) {
    return false;
  }
  const uint32_t lt0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.left);
  if (lt0 == ast__ast__TYPE_NONE) {
    return false;
  }
  const uint32_t lt = codegen__codegen__Codegen__strip_ref_only(self, codegen__codegen__Codegen__subst_resolve(self, lt0));
  if (lt == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty bt = (*codegen__codegen__Codegen__type_at(self, lt));
  if ((bt.kind != ast__ast__TypeKind_TYPE_STRUCT) && (bt.kind != ast__ast__TypeKind_TYPE_INSTANCE)) {
    return false;
  }
  uint16_t om = 0U;
  uint32_t od = ast__ast__NODE_NONE;
  if (bt.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), bt.as_data.inst));
    (om = it.module);
    (od = it.decl);
  } else {
    (om = bt.module);
    (od = bt.as_data.decl);
  }
  const bool ord = ((op != lexer__token_type__TokenType_EqualEqual) && (op != lexer__token_type__TokenType_BangEqual));
  const char *mm = ((const char *)({ __auto_type __sc897 = (str){ (const uint8_t *)"eq", sizeof("eq") - 1 }; str__ptr(&__sc897); }));
  if (ord) {
    (mm = ((const char *)({ __auto_type __sc898 = (str){ (const uint8_t *)"cmp", sizeof("cmp") - 1 }; str__ptr(&__sc898); })));
  }
  const ast__ast__DefId m = codegen__codegen__Codegen__cg_find_method_cstr(self, om, od, mm);
  if (m.node == ast__ast__NODE_NONE) {
    return false;
  }
  const uint32_t rt0 = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.right);
  const int32_t dl = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.left)));
  int32_t dr = 0;
  if (rt0 != ast__ast__TYPE_NONE) {
    (dr = codegen__codegen__Codegen__cg_ref_depth(self, codegen__codegen__Codegen__subst_resolve(self, rt0)));
  }
  codegen__codegen__Buf32 lb = (codegen__codegen__Buf32){0};
  codegen__codegen__Buf32 rb = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&lb.b[0])), 32ULL);
  codegen__codegen__Codegen__fresh(self, ((char *)(&rb.b[0])), 32ULL);
  ({ String__Global *__sc899 = &(self->buf);
String__Global__push_str(&(*__sc899), (str){ .ptr = (const uint8_t*)"(({ __auto_type ", .len = sizeof("(({ __auto_type ") - 1 });
String__Global__push_str(&(*__sc899), utils__errors__cstr(((const char *)(&lb.b[0]))));
String__Global__push_str(&(*__sc899), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, bd.left);
  ({ String__Global *__sc900 = &(self->buf);
String__Global__push_str(&(*__sc900), (str){ .ptr = (const uint8_t*)"; __auto_type ", .len = sizeof("; __auto_type ") - 1 });
String__Global__push_str(&(*__sc900), utils__errors__cstr(((const char *)(&rb.b[0]))));
String__Global__push_str(&(*__sc900), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
  codegen__codegen__Codegen__emit_expr(self, bd.right);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc901 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc901); })));
  if (op == lexer__token_type__TokenType_BangEqual) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc902 = (str){ (const uint8_t *)"!", sizeof("!") - 1 }; str__ptr(&__sc902); })));
  }
  if (ord) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc903 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc903); })));
  }
  codegen__codegen__Codegen__emit_op_method(self, bt, om, od, m);
  const char *lp = ((const char *)({ __auto_type __sc904 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc904); }));
  if (dl != 0) {
    (lp = codegen__codegen__ref_derefs(dl));
  }
  const char *rp = ((const char *)({ __auto_type __sc905 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc905); }));
  if (dr != 0) {
    (rp = codegen__codegen__ref_derefs(dr));
  }
  ({ String__Global *__sc906 = &(self->buf);
String__Global__push_str(&(*__sc906), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc906), utils__errors__cstr(lp));
String__Global__push_str(&(*__sc906), utils__errors__cstr(((const char *)(&lb.b[0]))));
String__Global__push_str(&(*__sc906), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc906), utils__errors__cstr(rp));
String__Global__push_str(&(*__sc906), utils__errors__cstr(((const char *)(&rb.b[0]))));
String__Global__push_str(&(*__sc906), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
  if (ord) {
    ({ String__Global *__sc907 = &(self->buf);
String__Global__push_str(&(*__sc907), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc907), utils__errors__cstr(codegen__codegen__c_op(op)));
String__Global__push_str(&(*__sc907), (str){ .ptr = (const uint8_t*)" 0)", .len = sizeof(" 0)") - 1 });
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc908 = (str){ (const uint8_t *)"; }))", sizeof("; }))") - 1 }; str__ptr(&__sc908); })));
  return true;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_ident_ref(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  const lexer__token__Span nt = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.name.text;
  if ((d.node != ast__ast__NODE_NONE) && (d.module == codegen__codegen__Codegen__cur_module(self))) {
    bool is_mut = false;
    if (codegen__codegen__Codegen__cg_env_capture(self, d.node, ((bool *)(&is_mut))) >= 0) {
      if (is_mut) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc909 = (str){ (const uint8_t *)"(*__env->", sizeof("(*__env->") - 1 }; str__ptr(&__sc909); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc910 = (str){ (const uint8_t *)"__env->", sizeof("__env->") - 1 }; str__ptr(&__sc910); })));
      }
      codegen__codegen__Codegen__emit_ident(self, nt);
      if (is_mut) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc911 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc911); })));
      }
      return;
    }
  }
  if (d.node != ast__ast__NODE_NONE) {
    ast__ast__Ast *const da = codegen__codegen__Codegen__mod_ast(self, d.module);
    const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*da)), d.node));
    if (dn.kind == ast__ast__NodeKind_NODE_VARIANT) {
      const uint32_t en = codegen__codegen__Codegen__enclosing_enum_in(self, d.module, d.node);
      if (en != ast__ast__NODE_NONE) {
        codegen__codegen__Codegen__emit_tag_mod(self, d.module, en, d.node);
        return;
      }
    }
    if (dn.kind == ast__ast__NodeKind_NODE_FUNCTION) {
      codegen__codegen__Buf256 ov = (codegen__codegen__Buf256){0};
      if (codegen__codegen__Codegen__cg_symbol_override(self, d.module, d.node, ((char *)(&ov.b[0])), 160ULL)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&ov.b[0])));
        return;
      }
    }
    if (((dn.kind == ast__ast__NodeKind_NODE_FUNCTION) && (dn.as_data.function.body != ast__ast__NODE_NONE)) && (!codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, d.module), ast__ast__Ast__at_const(&((*da)), dn.as_data.function.name)->as_data.name.text, ((const char *)({ __auto_type __sc912 = (str){ (const uint8_t *)"main", sizeof("main") - 1 }; str__ptr(&__sc912); }))))) {
      codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_qualified(self, d.module, dn.as_data.function.name, ((char *)(&nm.b[0])), 160ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
      return;
    }
    if ((dn.kind == ast__ast__NodeKind_NODE_CONST) && dn.as_data.const_def.is_extern) {
      codegen__codegen__Buf256 ov = (codegen__codegen__Buf256){0};
      if (codegen__codegen__Codegen__cg_symbol_override(self, d.module, d.node, ((char *)(&ov.b[0])), 160ULL)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&ov.b[0])));
      } else {
        codegen__codegen__Codegen__emit_ident_mod(self, d.module, dn.as_data.const_def.name);
      }
      return;
    }
    if ((dn.kind == ast__ast__NodeKind_NODE_CONST) && ((!self->mangle) || codegen__codegen__Codegen__decl_is_toplevel(self, d.module, d.node))) {
      codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_qualified(self, d.module, dn.as_data.const_def.name, ((char *)(&nm.b[0])), 160ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
      return;
    }
  }
  codegen__codegen__Codegen__emit_ident(self, nt);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_array_braces(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__NodeList elements = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.array_literal.elements;
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc913 = (str){ (const uint8_t *)"{ ", sizeof("{ ") - 1 }; str__ptr(&__sc913); })));
  for (uint32_t i = 0U; i < elements.len; i++) {
    if (i != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc914 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc914); })));
    }
    const uint32_t eid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), elements)[((size_t)i)];
    const ast__ast__Node *const el = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), eid);
    if (el->kind == ast__ast__NodeKind_NODE_FIELD_INITIALIZER) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc915 = (str){ (const uint8_t *)"[", sizeof("[") - 1 }; str__ptr(&__sc915); })));
      const uint32_t nameNode = el->as_data.field_initializer.name;
      const uint32_t valNode = el->as_data.field_initializer.value;
      bool folded = false;
      if (codegen__codegen__Codegen__ceval(self) != NULL) {
        const consteval__consteval__ConstValue iv = consteval__consteval__ConstEval__eval(&((*codegen__codegen__Codegen__ceval(self))), codegen__codegen__Codegen__cur_module(self), nameNode);
        if (iv.kind == consteval__consteval__CONST_INT) {
          ({ String__Global *__sc916 = &(self->buf);
String__Global__push_i64(&(*__sc916), (int64_t)(iv.as_data.i));
});
          (folded = true);
        }
      }
      if (!folded) {
        codegen__codegen__Codegen__emit_expr(self, nameNode);
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc917 = (str){ (const uint8_t *)"] = ", sizeof("] = ") - 1 }; str__ptr(&__sc917); })));
      if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), valNode)->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
        codegen__codegen__Codegen__emit_array_braces(self, valNode);
      } else {
        codegen__codegen__Codegen__emit_expr(self, valNode);
      }
    } else if (el->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
      codegen__codegen__Codegen__emit_array_braces(self, eid);
    } else {
      codegen__codegen__Codegen__emit_expr(self, eid);
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc918 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc918); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_expr(codegen__codegen__Codegen *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  if ((id != self->slice_raw) && codegen__codegen__Codegen__emit_slice_coercion(self, id)) {
    return;
  }
  if ((id != self->dyn_raw) && codegen__codegen__Codegen__emit_dyn_coercion(self, id)) {
    return;
  }
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const ast__ast__NodeKind nk = n.kind;
  if (((codegen__codegen__Codegen__ceval(self) != NULL) && ((((((nk == ast__ast__NodeKind_NODE_BINARY) || (nk == ast__ast__NodeKind_NODE_UNARY)) || (nk == ast__ast__NodeKind_NODE_CAST)) || (nk == ast__ast__NodeKind_NODE_CALL)) || (nk == ast__ast__NodeKind_NODE_SIZEOF)) || (nk == ast__ast__NodeKind_NODE_ALIGNOF))) && codegen__codegen__Codegen__cg_maybe_const(self, id)) {
    const consteval__consteval__ConstValue v = consteval__consteval__ConstEval__eval(&((*codegen__codegen__Codegen__ceval(self))), codegen__codegen__Codegen__cur_module(self), id);
    if (v.kind == consteval__consteval__CONST_BOOL) {
      if (v.as_data.i != 0) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc919 = (str){ (const uint8_t *)"true", sizeof("true") - 1 }; str__ptr(&__sc919); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc920 = (str){ (const uint8_t *)"false", sizeof("false") - 1 }; str__ptr(&__sc920); })));
      }
      return;
    }
    if (v.kind == consteval__consteval__CONST_INT) {
      ast__ast__BuiltinType vb = ast__ast__BuiltinType_BT_COUNT;
      if ((v.ty != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, v.ty)->kind == ast__ast__TypeKind_TYPE_BUILTIN)) {
        (vb = codegen__codegen__Codegen__type_at(self, v.ty)->as_data.builtin);
      }
      const bool uns = (((((vb == ast__ast__BuiltinType_BT_U8) || (vb == ast__ast__BuiltinType_BT_U16)) || (vb == ast__ast__BuiltinType_BT_U32)) || (vb == ast__ast__BuiltinType_BT_U64)) || (vb == ast__ast__BuiltinType_BT_USIZE));
      if (uns) {
        if ((vb == ast__ast__BuiltinType_BT_U64) || (vb == ast__ast__BuiltinType_BT_USIZE)) {
          ({ String__Global *__sc921 = &(self->buf);
String__Global__push_u64(&(*__sc921), (uint64_t)(((uint64_t)v.as_data.i)));
String__Global__push_str(&(*__sc921), (str){ .ptr = (const uint8_t*)"ULL", .len = sizeof("ULL") - 1 });
});
        } else {
          ({ String__Global *__sc922 = &(self->buf);
String__Global__push_u64(&(*__sc922), (uint64_t)(((uint64_t)v.as_data.i)));
String__Global__push_str(&(*__sc922), (str){ .ptr = (const uint8_t*)"U", .len = sizeof("U") - 1 });
});
        }
      } else if (v.as_data.i == (-9223372036854775807ll - 1)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc923 = (str){ (const uint8_t *)"(-9223372036854775807ll - 1)", sizeof("(-9223372036854775807ll - 1)") - 1 }; str__ptr(&__sc923); })));
      } else if ((vb == ast__ast__BuiltinType_BT_I64) || (vb == ast__ast__BuiltinType_BT_ISIZE)) {
        ({ String__Global *__sc924 = &(self->buf);
String__Global__push_i64(&(*__sc924), (int64_t)(v.as_data.i));
String__Global__push_str(&(*__sc924), (str){ .ptr = (const uint8_t*)"LL", .len = sizeof("LL") - 1 });
});
      } else if ((v.as_data.i > 0x7FFFFFFFLL) || (v.as_data.i < -2147483648LL)) {
        ({ String__Global *__sc925 = &(self->buf);
String__Global__push_i64(&(*__sc925), (int64_t)(v.as_data.i));
String__Global__push_str(&(*__sc925), (str){ .ptr = (const uint8_t*)"ll", .len = sizeof("ll") - 1 });
});
      } else {
        ({ String__Global *__sc926 = &(self->buf);
String__Global__push_i64(&(*__sc926), (int64_t)(v.as_data.i));
});
      }
      return;
    }
    if (v.kind == consteval__consteval__CONST_FLOAT) {
      bool f32t = false;
      if (((v.ty != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, v.ty)->kind == ast__ast__TypeKind_TYPE_BUILTIN)) && (codegen__codegen__Codegen__type_at(self, v.ty)->as_data.builtin == ast__ast__BuiltinType_BT_F32)) {
        (f32t = true);
      }
      codegen__codegen__Buf64 fb = (codegen__codegen__Buf64){0};
      snprintf(((char *)(&fb.b[0])), 48ULL, ((const char *)({ __auto_type __sc927 = (str){ (const uint8_t *)"%.17g", sizeof("%.17g") - 1 }; str__ptr(&__sc927); })), v.as_data.f);
      const size_t fl = strlen(((const char *)(&fb.b[0])));
      const bool has = (((memchr((&fb.b[0]), 46, fl) != NULL) || (memchr((&fb.b[0]), 101, fl) != NULL)) || (memchr((&fb.b[0]), 69, fl) != NULL));
      if (!has) {
        codegen__codegen__bappend(((char *)(&fb.b[0])), 48ULL, fl, ((const char *)({ __auto_type __sc928 = (str){ (const uint8_t *)".0", sizeof(".0") - 1 }; str__ptr(&__sc928); })));
      }
      if (f32t) {
        ({ String__Global *__sc929 = &(self->buf);
String__Global__push_str(&(*__sc929), utils__errors__cstr(((const char *)(&fb.b[0]))));
String__Global__push_str(&(*__sc929), (str){ .ptr = (const uint8_t*)"f", .len = sizeof("f") - 1 });
});
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&fb.b[0])));
      }
      return;
    }
  }
  {
    const ast__ast__NodeKind __sc930 = nk;
    if (__sc930 == ast__ast__NodeKind_NODE_LITERAL) {
      {
        codegen__codegen__Codegen__emit_literal(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_IDENTIFIER) {
      {
        int64_t cv = 0;
        if (codegen__codegen__Codegen__cg_const_param_value(self, id, ((int64_t *)(&cv)))) {
          ({ String__Global *__sc931 = &(self->buf);
String__Global__push_i64(&(*__sc931), (int64_t)(cv));
});
        } else if (codegen__codegen__Codegen__cg_is_cond_site(self, id)) {
          codegen__codegen__Buf32 fl = (codegen__codegen__Buf32){0};
          codegen__codegen__cg_move_flag(((char *)(&fl.b[0])), 32ULL, ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), id).node);
          ({ String__Global *__sc932 = &(self->buf);
String__Global__push_str(&(*__sc932), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc932), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc932), (str){ .ptr = (const uint8_t*)" = true, ", .len = sizeof(" = true, ") - 1 });
});
          codegen__codegen__Codegen__emit_ident_ref(self, id);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc933 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc933); })));
        } else {
          codegen__codegen__Codegen__emit_ident_ref(self, id);
        }
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_UNARY) {
      {
        const lexer__token_type__TokenType op = n.as_data.unary.op;
        const uint32_t operand = n.as_data.unary.operand;
        if (op == lexer__token_type__TokenType_Question) {
          codegen__codegen__Codegen__emit_try(self, id);
        } else if ((op == lexer__token_type__TokenType_Move) || (op == lexer__token_type__TokenType_Unsafe)) {
          codegen__codegen__Codegen__emit_expr(self, operand);
        } else if (((op == lexer__token_type__TokenType_Ampersand) && (!codegen__codegen__Codegen__is_lvalue(self, operand))) && (codegen__codegen__Codegen__type_at(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), operand))->kind == ast__ast__TypeKind_TYPE_BUILTIN)) {
          codegen__codegen__Buf256 ty = (codegen__codegen__Buf256){0};
          codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), operand), ((const char *)({ __auto_type __sc934 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc934); })), ((char *)(&ty.b[0])), 128ULL);
          ({ String__Global *__sc935 = &(self->buf);
String__Global__push_str(&(*__sc935), (str){ .ptr = (const uint8_t*)"(&(", .len = sizeof("(&(") - 1 });
String__Global__push_str(&(*__sc935), utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&(*__sc935), (str){ .ptr = (const uint8_t*)"){", .len = sizeof("){") - 1 });
});
          codegen__codegen__Codegen__emit_expr(self, operand);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc936 = (str){ (const uint8_t *)"})", sizeof("})") - 1 }; str__ptr(&__sc936); })));
        } else {
          const bool addr_mut = ((op == lexer__token_type__TokenType_Ampersand) && (n.as_data.unary.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT));
          ({ String__Global *__sc937 = &(self->buf);
String__Global__push_str(&(*__sc937), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc937), utils__errors__cstr(codegen__codegen__c_op(op)));
});
          codegen__codegen__Codegen__emit_place(self, operand, addr_mut);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc938 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc938); })));
        }
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_BINARY) {
      {
        if (codegen__codegen__Codegen__emit_cmp_overload(self, id)) {
          return;
        }
        if (codegen__codegen__Codegen__emit_arith_overload(self, id)) {
          return;
        }
        const ast__ast__BinaryData bd = n.as_data.binary;
        if (bd.op == lexer__token_type__TokenType_Percent) {
          const ast__ast__Ty *const lt = codegen__codegen__Codegen__type_at(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), bd.left));
          if ((lt->kind == ast__ast__TypeKind_TYPE_BUILTIN) && ((lt->as_data.builtin == ast__ast__BuiltinType_BT_F32) || (lt->as_data.builtin == ast__ast__BuiltinType_BT_F64))) {
            const char *fn2 = ((const char *)({ __auto_type __sc939 = (str){ (const uint8_t *)"fmod", sizeof("fmod") - 1 }; str__ptr(&__sc939); }));
            if (lt->as_data.builtin == ast__ast__BuiltinType_BT_F32) {
              (fn2 = ((const char *)({ __auto_type __sc940 = (str){ (const uint8_t *)"fmodf", sizeof("fmodf") - 1 }; str__ptr(&__sc940); })));
            }
            ({ String__Global *__sc941 = &(self->buf);
String__Global__push_str(&(*__sc941), utils__errors__cstr(fn2));
String__Global__push_str(&(*__sc941), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
});
            codegen__codegen__Codegen__emit_expr(self, bd.left);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc942 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc942); })));
            codegen__codegen__Codegen__emit_expr(self, bd.right);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc943 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc943); })));
            return;
          }
        }
        if (codegen__codegen__Codegen__emit_cg_checked_arith(self, id)) {
          return;
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc944 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc944); })));
        codegen__codegen__Codegen__emit_expr(self, bd.left);
        ({ String__Global *__sc945 = &(self->buf);
String__Global__push_str(&(*__sc945), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc945), utils__errors__cstr(codegen__codegen__c_op(bd.op)));
String__Global__push_str(&(*__sc945), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, bd.right);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc946 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc946); })));
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_ASSIGNMENT) {
      {
        codegen__codegen__Codegen__emit_assignment(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_CALL) {
      {
        const uint32_t ct = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
        const bool arr_ret = ((ct != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, ct)->kind == ast__ast__TypeKind_TYPE_ARRAY));
        const ast__ast__Node *const cn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), n.as_data.call.callee);
        codegen__codegen__Buf32 freeflag = (codegen__codegen__Buf32){0};
        (freeflag.b[0] = 0);
        if (((((cn->kind == ast__ast__NodeKind_NODE_MEMBER) && (!cn->as_data.member.path)) && (cn->as_data.member.object != ast__ast__NODE_NONE)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), cn->as_data.member.object)->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, codegen__codegen__Codegen__cur_module(self)), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), cn->as_data.member.member)->as_data.name.text, ((const char *)({ __auto_type __sc947 = (str){ (const uint8_t *)"free", sizeof("free") - 1 }; str__ptr(&__sc947); })))) {
          const ast__ast__DefId rd = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), cn->as_data.member.object);
          if ((rd.module == codegen__codegen__Codegen__cur_module(self)) && codegen__codegen__Codegen__cg_is_cond_moved(self, rd.node)) {
            codegen__codegen__cg_move_flag(((char *)(&freeflag.b[0])), 32ULL, rd.node);
            ({ String__Global *__sc948 = &(self->buf);
String__Global__push_str(&(*__sc948), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc948), utils__errors__cstr(((const char *)(&freeflag.b[0]))));
String__Global__push_str(&(*__sc948), (str){ .ptr = (const uint8_t*)" = true, ", .len = sizeof(" = true, ") - 1 });
});
          }
        }
        if (arr_ret) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc949 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc949); })));
        }
        codegen__codegen__Codegen__emit_call(self, id);
        if (arr_ret) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc950 = (str){ (const uint8_t *)")._", sizeof(")._") - 1 }; str__ptr(&__sc950); })));
        }
        if (freeflag.b[0] != 0) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc951 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc951); })));
        }
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_CLOSURE) {
      {
        codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__closure_name(self, id, ((char *)(&nm.b[0])), 200ULL);
        if (n.as_data.closure.captures.len != 0U) {
          bool wrapped = false;
          if (codegen__codegen__Codegen__cg_is_cond_site(self, id)) {
            const ast__ast__NodeList caps = n.as_data.closure.captures;
            for (uint32_t i = 0U; i < caps.len; i++) {
              const uint32_t cid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), caps)[((size_t)i)];
              if (((({ uint64_t __sc952 = ((uint64_t)n.as_data.closure.mut_caps); int64_t __sc953 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc953 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc952 >> __sc953); }) & 1ULL) != 0ULL) || (!codegen__codegen__Codegen__cg_is_cond_moved(self, cid))) {
                continue;
              }
              codegen__codegen__Buf32 fl = (codegen__codegen__Buf32){0};
              codegen__codegen__cg_move_flag(((char *)(&fl.b[0])), 32ULL, cid);
              if (wrapped) {
                ({ String__Global *__sc954 = &(self->buf);
String__Global__push_str(&(*__sc954), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc954), (str){ .ptr = (const uint8_t*)" = true, ", .len = sizeof(" = true, ") - 1 });
});
              } else {
                ({ String__Global *__sc955 = &(self->buf);
String__Global__push_str(&(*__sc955), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc955), utils__errors__cstr(((const char *)(&fl.b[0]))));
String__Global__push_str(&(*__sc955), (str){ .ptr = (const uint8_t*)" = true, ", .len = sizeof(" = true, ") - 1 });
});
              }
              (wrapped = true);
            }
          }
          ({ String__Global *__sc956 = &(self->buf);
String__Global__push_str(&(*__sc956), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc956), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc956), (str){ .ptr = (const uint8_t*)"_env){ ", .len = sizeof("_env){ ") - 1 });
});
          const ast__ast__NodeList caps = n.as_data.closure.captures;
          for (uint32_t i = 0U; i < caps.len; i++) {
            if (i != 0U) {
              codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc957 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc957); })));
            }
            codegen__codegen__Codegen__emit_capture_init(self, id, i);
          }
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc958 = (str){ (const uint8_t *)" })", sizeof(" })") - 1 }; str__ptr(&__sc958); })));
          if (wrapped) {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc959 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc959); })));
          }
        } else {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&nm.b[0])));
        }
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_TUPLE) {
      {
        codegen__codegen__Buf256 styp = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id), ((const char *)({ __auto_type __sc960 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc960); })), ((char *)(&styp.b[0])), 200ULL);
        ({ String__Global *__sc961 = &(self->buf);
String__Global__push_str(&(*__sc961), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc961), utils__errors__cstr(((const char *)(&styp.b[0]))));
String__Global__push_str(&(*__sc961), (str){ .ptr = (const uint8_t*)"){ ", .len = sizeof("){ ") - 1 });
});
        const ast__ast__NodeList elems = n.as_data.array_literal.elements;
        for (uint32_t i = 0U; i < elems.len; i++) {
          if (i != 0U) {
            ({ String__Global *__sc962 = &(self->buf);
String__Global__push_str(&(*__sc962), (str){ .ptr = (const uint8_t*)", ._", .len = sizeof(", ._") - 1 });
String__Global__push_u64(&(*__sc962), (uint64_t)(i));
String__Global__push_str(&(*__sc962), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
          } else {
            ({ String__Global *__sc963 = &(self->buf);
String__Global__push_str(&(*__sc963), (str){ .ptr = (const uint8_t*)"._", .len = sizeof("._") - 1 });
String__Global__push_u64(&(*__sc963), (uint64_t)(i));
String__Global__push_str(&(*__sc963), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
          }
          codegen__codegen__Codegen__emit_expr(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), elems)[((size_t)i)]);
        }
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc964 = (str){ (const uint8_t *)" }", sizeof(" }") - 1 }; str__ptr(&__sc964); })));
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_RANGE) {
      {
        codegen__codegen__Buf256 styp = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_id(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id), ((const char *)({ __auto_type __sc965 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc965); })), ((char *)(&styp.b[0])), 200ULL);
        ({ String__Global *__sc966 = &(self->buf);
String__Global__push_str(&(*__sc966), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc966), utils__errors__cstr(((const char *)(&styp.b[0]))));
String__Global__push_str(&(*__sc966), (str){ .ptr = (const uint8_t*)"){ .start = ", .len = sizeof("){ .start = ") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, n.as_data.pattern_range.start);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc967 = (str){ (const uint8_t *)", .end = ", sizeof(", .end = ") - 1 }; str__ptr(&__sc967); })));
        codegen__codegen__Codegen__emit_expr(self, n.as_data.pattern_range.end);
        const char *incl = ((const char *)({ __auto_type __sc968 = (str){ (const uint8_t *)"false", sizeof("false") - 1 }; str__ptr(&__sc968); }));
        if (n.as_data.pattern_range.inclusive) {
          (incl = ((const char *)({ __auto_type __sc969 = (str){ (const uint8_t *)"true", sizeof("true") - 1 }; str__ptr(&__sc969); })));
        }
        ({ String__Global *__sc970 = &(self->buf);
String__Global__push_str(&(*__sc970), (str){ .ptr = (const uint8_t*)", .inclusive = ", .len = sizeof(", .inclusive = ") - 1 });
String__Global__push_str(&(*__sc970), utils__errors__cstr(incl));
String__Global__push_str(&(*__sc970), (str){ .ptr = (const uint8_t*)" }", .len = sizeof(" }") - 1 });
});
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_INDEX) {
      {
        codegen__codegen__Codegen__emit_index(self, id, false);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_MEMBER) {
      {
        codegen__codegen__Codegen__emit_member(self, id, false);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_CAST) {
      {
        codegen__codegen__Buf256 t = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_node(self, n.as_data.cast.ty, ((const char *)({ __auto_type __sc971 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc971); })), ((char *)(&t.b[0])), 256ULL);
        ({ String__Global *__sc972 = &(self->buf);
String__Global__push_str(&(*__sc972), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc972), utils__errors__cstr(((const char *)(&t.b[0]))));
String__Global__push_str(&(*__sc972), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, n.as_data.cast.expression);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc973 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc973); })));
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
      {
        codegen__codegen__Codegen__emit_expr(self, n.as_data.specialization.expression);
      }
    }
    else if ((__sc930 == ast__ast__NodeKind_NODE_SIZEOF) || (__sc930 == ast__ast__NodeKind_NODE_ALIGNOF)) {
      {
        codegen__codegen__Codegen__emit_sizeof(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_VA_EXPR) {
      {
        const ast__ast__VaOpData vo = n.as_data.va_op;
        if (vo.op == ast__ast__VA_ARG) {
          codegen__codegen__Buf256 ty = (codegen__codegen__Buf256){0};
          codegen__codegen__Codegen__render_type_node(self, vo.extra, ((const char *)({ __auto_type __sc974 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc974); })), ((char *)(&ty.b[0])), 256ULL);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc975 = (str){ (const uint8_t *)"va_arg(", sizeof("va_arg(") - 1 }; str__ptr(&__sc975); })));
          codegen__codegen__Codegen__emit_expr(self, vo.ap);
          ({ String__Global *__sc976 = &(self->buf);
String__Global__push_str(&(*__sc976), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc976), utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&(*__sc976), (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
});
        } else if (vo.op == ast__ast__VA_START) {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc977 = (str){ (const uint8_t *)"va_start(", sizeof("va_start(") - 1 }; str__ptr(&__sc977); })));
          codegen__codegen__Codegen__emit_expr(self, vo.ap);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc978 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc978); })));
          codegen__codegen__Codegen__emit_expr(self, vo.extra);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc979 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc979); })));
        } else {
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc980 = (str){ (const uint8_t *)"va_end(", sizeof("va_end(") - 1 }; str__ptr(&__sc980); })));
          codegen__codegen__Codegen__emit_expr(self, vo.ap);
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc981 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc981); })));
        }
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
      {
        codegen__codegen__Codegen__emit_struct_init(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_NEW) {
      {
        codegen__codegen__Codegen__emit_new(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
      {
        const uint32_t at = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
        codegen__codegen__Buf256 et = (codegen__codegen__Buf256){0};
        if (at != ast__ast__TYPE_NONE) {
          const uint32_t ae = codegen__codegen__Codegen__type_at(self, at)->as_data.elem;
          codegen__codegen__Codegen__render_type_id(self, ae, ((const char *)({ __auto_type __sc982 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc982); })), ((char *)(&et.b[0])), 256ULL);
        } else {
          snprintf(((char *)(&et.b[0])), 256ULL, ((const char *)({ __auto_type __sc983 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc983); })), ((const char *)({ __auto_type __sc984 = (str){ (const uint8_t *)"int", sizeof("int") - 1 }; str__ptr(&__sc984); })));
        }
        ({ String__Global *__sc985 = &(self->buf);
String__Global__push_str(&(*__sc985), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc985), utils__errors__cstr(((const char *)(&et.b[0]))));
String__Global__push_str(&(*__sc985), (str){ .ptr = (const uint8_t*)"[", .len = sizeof("[") - 1 });
String__Global__push_u64(&(*__sc985), (uint64_t)(n.as_data.array_literal.elements.len));
String__Global__push_str(&(*__sc985), (str){ .ptr = (const uint8_t*)"])", .len = sizeof("])") - 1 });
});
        codegen__codegen__Codegen__emit_array_braces(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_MATCH) {
      {
        codegen__codegen__Codegen__emit_match_expr(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_IF) {
      {
        codegen__codegen__Codegen__emit_if_expr(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_WHILE) {
      {
        codegen__codegen__Codegen__emit_loop_expr(self, id);
      }
    }
    else if (__sc930 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc986 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc986); })));
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc987 = (str){ (const uint8_t *)"{\n", sizeof("{\n") - 1 }; str__ptr(&__sc987); })));
        (self->depth = (self->depth + 1U));
        const ast__ast__NodeList stmts = n.as_data.block.statements;
        const bool saved = self->no_temp_free;
        for (uint32_t i = 0U; i < stmts.len; i++) {
          (self->no_temp_free = ((i + 1U) == stmts.len));
          codegen__codegen__Codegen__emit_indent(self);
          codegen__codegen__Codegen__emit_stmt(self, ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), stmts)[((size_t)i)]);
        }
        (self->no_temp_free = saved);
        (self->depth = (self->depth - 1U));
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc988 = (str){ (const uint8_t *)"})", sizeof("})") - 1 }; str__ptr(&__sc988); })));
      }
    }
    else if (1) {
      {
        utils__errors__Errors__emit(&self->errors, n.span.start, (n.span.end - n.span.start), ({ String__Global __sc989 = String__Global__new();
String__Global__push_str(&__sc989, (str){ .ptr = (const uint8_t*)"codegen: unsupported expression", .len = sizeof("codegen: unsupported expression") - 1 });
__sc989; }));
      }
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_literal(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__Node n = (*ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id));
  const lexer__token__Span s = n.as_data.literal.raw;
  const lexer__token_type__TokenType tt = n.as_data.literal.token_type;
  if (tt == lexer__token_type__TokenType_True) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc990 = (str){ (const uint8_t *)"true", sizeof("true") - 1 }; str__ptr(&__sc990); })));
  } else if (tt == lexer__token_type__TokenType_False) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc991 = (str){ (const uint8_t *)"false", sizeof("false") - 1 }; str__ptr(&__sc991); })));
  } else if (tt == lexer__token_type__TokenType_Null) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc992 = (str){ (const uint8_t *)"NULL", sizeof("NULL") - 1 }; str__ptr(&__sc992); })));
  } else if (tt == lexer__token_type__TokenType_CharacterLiteral) {
    codegen__codegen__Codegen__emit_reescaped(self, s, true);
  } else if (tt == lexer__token_type__TokenType_StringLiteral) {
    const uint32_t tid = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
    bool isptr = false;
    if ((tid != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, tid)->kind == ast__ast__TypeKind_TYPE_POINTER)) {
      (isptr = true);
    }
    if (isptr) {
      const ast__ast__Ty pe = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__type_at(self, tid)->as_data.elem));
      if ((pe.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (pe.as_data.builtin == ast__ast__BuiltinType_BT_U8)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc993 = (str){ (const uint8_t *)"(const uint8_t *)", sizeof("(const uint8_t *)") - 1 }; str__ptr(&__sc993); })));
      }
      codegen__codegen__Codegen__emit_reescaped(self, s, false);
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc994 = (str){ (const uint8_t *)"(str){ (const uint8_t *)", sizeof("(str){ (const uint8_t *)") - 1 }; str__ptr(&__sc994); })));
      codegen__codegen__Codegen__emit_reescaped(self, s, false);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc995 = (str){ (const uint8_t *)", sizeof(", sizeof(", sizeof(") - 1 }; str__ptr(&__sc995); })));
      codegen__codegen__Codegen__emit_reescaped(self, s, false);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc996 = (str){ (const uint8_t *)") - 1 }", sizeof(") - 1 }") - 1 }; str__ptr(&__sc996); })));
    }
  } else if (tt == lexer__token_type__TokenType_ByteStringLiteral) {
    codegen__codegen__Buf256 sn = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id)), ((const char *)({ __auto_type __sc997 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc997); })), ((char *)(&sn.b[0])), 200ULL);
    const lexer__token__Span bc = (lexer__token__Span){ .start = (s.start + 1U), .end = s.end };
    ({ String__Global *__sc998 = &(self->buf);
String__Global__push_str(&(*__sc998), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
String__Global__push_str(&(*__sc998), utils__errors__cstr(((const char *)(&sn.b[0]))));
String__Global__push_str(&(*__sc998), (str){ .ptr = (const uint8_t*)"){ .ptr = (const uint8_t *)", .len = sizeof("){ .ptr = (const uint8_t *)") - 1 });
});
    codegen__codegen__Codegen__emit_reescaped(self, bc, false);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc999 = (str){ (const uint8_t *)", .len = sizeof(", sizeof(", .len = sizeof(") - 1 }; str__ptr(&__sc999); })));
    codegen__codegen__Codegen__emit_reescaped(self, bc, false);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1000 = (str){ (const uint8_t *)") - 1 }", sizeof(") - 1 }") - 1 }; str__ptr(&__sc1000); })));
  } else if (tt == lexer__token_type__TokenType_ByteCharacterLiteral) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1001 = (str){ (const uint8_t *)"(uint8_t)", sizeof("(uint8_t)") - 1 }; str__ptr(&__sc1001); })));
    if ((s.end > s.start) && (self->source[((size_t)s.start)] == 98U)) {
      codegen__codegen__Codegen__emit_bytes(self, codegen__codegen__src_at(self->source, (s.start + 1U)), ((size_t)((int32_t)((s.end - s.start) - 1U))));
    } else {
      codegen__codegen__Codegen__emit_span(self, s);
    }
  } else if (tt == lexer__token_type__TokenType_RawStringLiteral) {
    const lexer__token__Span rc = codegen__codegen__raw_string_content(self->source, s);
    const uint32_t tid = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id);
    bool isptr = false;
    if ((tid != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, tid)->kind == ast__ast__TypeKind_TYPE_POINTER)) {
      (isptr = true);
    }
    if (isptr) {
      const ast__ast__Ty pe = (*codegen__codegen__Codegen__type_at(self, codegen__codegen__Codegen__type_at(self, tid)->as_data.elem));
      if ((pe.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (pe.as_data.builtin == ast__ast__BuiltinType_BT_U8)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1002 = (str){ (const uint8_t *)"(const uint8_t *)", sizeof("(const uint8_t *)") - 1 }; str__ptr(&__sc1002); })));
      }
      codegen__codegen__Codegen__emit_raw_c_string(self, rc);
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1003 = (str){ (const uint8_t *)"(str){ (const uint8_t *)", sizeof("(str){ (const uint8_t *)") - 1 }; str__ptr(&__sc1003); })));
      codegen__codegen__Codegen__emit_raw_c_string(self, rc);
      ({ String__Global *__sc1004 = &(self->buf);
String__Global__push_str(&(*__sc1004), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_u64(&(*__sc1004), (uint64_t)((rc.end - rc.start)));
String__Global__push_str(&(*__sc1004), (str){ .ptr = (const uint8_t*)" }", .len = sizeof(" }") - 1 });
});
    }
  } else {
    const uint32_t lt = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), id));
    ast__ast__BuiltinType b = ast__ast__BuiltinType_BT_COUNT;
    if ((lt != ast__ast__TYPE_NONE) && (codegen__codegen__Codegen__type_at(self, lt)->kind == ast__ast__TypeKind_TYPE_BUILTIN)) {
      (b = codegen__codegen__Codegen__type_at(self, lt)->as_data.builtin);
    }
    codegen__codegen__Codegen__emit_number(self, s, tt, b);
  }
}

static __attribute__((unused)) const char *codegen__codegen__sep(const char *const decl) {
  if (decl[0] != 0) {
    return ((const char *)({ __auto_type __sc1005 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1005); }));
  }
  return ((const char *)({ __auto_type __sc1006 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1006); }));
}

static __attribute__((unused)) bool codegen__codegen__not_const_prefixed(const char *const base) {
  return (strncmp(base, ((const char *)({ __auto_type __sc1007 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc1007); })), 6ULL) != 0);
}

static __attribute__((unused)) void codegen__codegen__buf_join3(char *const out, size_t const cap, const char *const first, const char *const second, const char *const third) {
  if (cap != 0ULL) {
    (out[0] = 0);
  }
  size_t at = codegen__codegen__bappend(out, cap, 0ULL, first);
  (at = codegen__codegen__bappend(out, cap, at, second));
  codegen__codegen__bappend(out, cap, at, third);
}

static __attribute__((unused)) const char *codegen__codegen__src_at(const uint8_t *const p, uint32_t const off) {
  return ((const char *)(p + ((size_t)off)));
}

static __attribute__((unused)) bool codegen__codegen__span_is(const uint8_t *const src, lexer__token__Span const s, const char *const lit) {
  const size_t n = strlen(lit);
  if (((size_t)(s.end - s.start)) != n) {
    return false;
  }
  return (memcmp((src + ((size_t)s.start)), lit, n) == 0);
}

static __attribute__((unused)) bool codegen__codegen__spans_eq2(const uint8_t *const sa, lexer__token__Span const a, const uint8_t *const sb, lexer__token__Span const b) {
  const uint32_t la = (a.end - a.start);
  if (la != (b.end - b.start)) {
    return false;
  }
  return (memcmp((sa + ((size_t)a.start)), (sb + ((size_t)b.start)), ((size_t)la)) == 0);
}

static __attribute__((unused)) const char *codegen__codegen__builtin_name(ast__ast__BuiltinType const b) {
  if (b == ast__ast__BuiltinType_BT_BOOL) {
    return ((const char *)({ __auto_type __sc1008 = (str){ (const uint8_t *)"bool", sizeof("bool") - 1 }; str__ptr(&__sc1008); }));
  }
  if (b == ast__ast__BuiltinType_BT_CHAR) {
    return ((const char *)({ __auto_type __sc1009 = (str){ (const uint8_t *)"char", sizeof("char") - 1 }; str__ptr(&__sc1009); }));
  }
  if (b == ast__ast__BuiltinType_BT_I8) {
    return ((const char *)({ __auto_type __sc1010 = (str){ (const uint8_t *)"i8", sizeof("i8") - 1 }; str__ptr(&__sc1010); }));
  }
  if (b == ast__ast__BuiltinType_BT_I16) {
    return ((const char *)({ __auto_type __sc1011 = (str){ (const uint8_t *)"i16", sizeof("i16") - 1 }; str__ptr(&__sc1011); }));
  }
  if (b == ast__ast__BuiltinType_BT_I32) {
    return ((const char *)({ __auto_type __sc1012 = (str){ (const uint8_t *)"i32", sizeof("i32") - 1 }; str__ptr(&__sc1012); }));
  }
  if (b == ast__ast__BuiltinType_BT_I64) {
    return ((const char *)({ __auto_type __sc1013 = (str){ (const uint8_t *)"i64", sizeof("i64") - 1 }; str__ptr(&__sc1013); }));
  }
  if (b == ast__ast__BuiltinType_BT_ISIZE) {
    return ((const char *)({ __auto_type __sc1014 = (str){ (const uint8_t *)"isize", sizeof("isize") - 1 }; str__ptr(&__sc1014); }));
  }
  if (b == ast__ast__BuiltinType_BT_U8) {
    return ((const char *)({ __auto_type __sc1015 = (str){ (const uint8_t *)"u8", sizeof("u8") - 1 }; str__ptr(&__sc1015); }));
  }
  if (b == ast__ast__BuiltinType_BT_U16) {
    return ((const char *)({ __auto_type __sc1016 = (str){ (const uint8_t *)"u16", sizeof("u16") - 1 }; str__ptr(&__sc1016); }));
  }
  if (b == ast__ast__BuiltinType_BT_U32) {
    return ((const char *)({ __auto_type __sc1017 = (str){ (const uint8_t *)"u32", sizeof("u32") - 1 }; str__ptr(&__sc1017); }));
  }
  if (b == ast__ast__BuiltinType_BT_U64) {
    return ((const char *)({ __auto_type __sc1018 = (str){ (const uint8_t *)"u64", sizeof("u64") - 1 }; str__ptr(&__sc1018); }));
  }
  if (b == ast__ast__BuiltinType_BT_USIZE) {
    return ((const char *)({ __auto_type __sc1019 = (str){ (const uint8_t *)"usize", sizeof("usize") - 1 }; str__ptr(&__sc1019); }));
  }
  if (b == ast__ast__BuiltinType_BT_F32) {
    return ((const char *)({ __auto_type __sc1020 = (str){ (const uint8_t *)"f32", sizeof("f32") - 1 }; str__ptr(&__sc1020); }));
  }
  if (b == ast__ast__BuiltinType_BT_F64) {
    return ((const char *)({ __auto_type __sc1021 = (str){ (const uint8_t *)"f64", sizeof("f64") - 1 }; str__ptr(&__sc1021); }));
  }
  if (b == ast__ast__BuiltinType_BT_C32) {
    return ((const char *)({ __auto_type __sc1022 = (str){ (const uint8_t *)"c32", sizeof("c32") - 1 }; str__ptr(&__sc1022); }));
  }
  if (b == ast__ast__BuiltinType_BT_C64) {
    return ((const char *)({ __auto_type __sc1023 = (str){ (const uint8_t *)"c64", sizeof("c64") - 1 }; str__ptr(&__sc1023); }));
  }
  if (b == ast__ast__BuiltinType_BT_VALIST) {
    return ((const char *)({ __auto_type __sc1024 = (str){ (const uint8_t *)"va_list", sizeof("va_list") - 1 }; str__ptr(&__sc1024); }));
  }
  return ((const char *)({ __auto_type __sc1025 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1025); }));
}

static __attribute__((unused)) int32_t codegen__codegen__builtin_of(const uint8_t *const src, lexer__token__Span const s) {
  for (int32_t i = 0; i < 18; i++) {
    if (codegen__codegen__span_is(src, s, codegen__codegen__builtin_name(((ast__ast__BuiltinType)i)))) {
      return i;
    }
  }
  return -1;
}

static __attribute__((unused)) size_t codegen__codegen__render_ident_src(const uint8_t *const src, lexer__token__Span const s, char *const buf, size_t const cap) {
  const size_t source_len = ((size_t)(s.end - s.start));
  const bool suffix = codegen__codegen__is_c_keyword(src, s);
  size_t full = source_len;
  if (suffix) {
    (full = (full + 1ULL));
  }
  if (cap != 0ULL) {
    size_t copied = source_len;
    if (copied > (cap - 1ULL)) {
      (copied = (cap - 1ULL));
    }
    memcpy(((void *)buf), (src + ((size_t)s.start)), copied);
    size_t written = copied;
    if (suffix && ((written + 1ULL) < cap)) {
      (buf[written] = 95);
      (written = (written + 1ULL));
    }
    (buf[written] = 0);
  }
  return full;
}

static __attribute__((unused)) size_t codegen__codegen__bappend_bytes(char *const out, size_t const cap, size_t const at, const char *const text, size_t const n) {
  if (at < cap) {
    const size_t room = ((cap - at) - 1ULL);
    size_t copied = n;
    if (copied > room) {
      (copied = room);
    }
    memcpy(((void *)(out + at)), text, copied);
    (out[(at + copied)] = 0);
  }
  return (at + n);
}

static __attribute__((unused)) size_t codegen__codegen__bappend(char *const out, size_t const cap, size_t const at, const char *const text) {
  return codegen__codegen__bappend_bytes(out, cap, at, text, strlen(text));
}

static __attribute__((unused)) bool codegen__codegen__is_c_keyword(const uint8_t *const src, lexer__token__Span const s) {
  const size_t n = ((size_t)(s.end - s.start));
  if (n == 0ULL) {
    return false;
  }
  const uint8_t c0 = src[((size_t)s.start)];
  if (c0 == 78U) {
    return codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1026 = (str){ (const uint8_t *)"NULL", sizeof("NULL") - 1 }; str__ptr(&__sc1026); })));
  }
  if (c0 == 95U) {
    return ((((((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1027 = (str){ (const uint8_t *)"_Bool", sizeof("_Bool") - 1 }; str__ptr(&__sc1027); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1028 = (str){ (const uint8_t *)"_Complex", sizeof("_Complex") - 1 }; str__ptr(&__sc1028); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1029 = (str){ (const uint8_t *)"_Atomic", sizeof("_Atomic") - 1 }; str__ptr(&__sc1029); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1030 = (str){ (const uint8_t *)"_Noreturn", sizeof("_Noreturn") - 1 }; str__ptr(&__sc1030); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1031 = (str){ (const uint8_t *)"_Generic", sizeof("_Generic") - 1 }; str__ptr(&__sc1031); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1032 = (str){ (const uint8_t *)"_Static_assert", sizeof("_Static_assert") - 1 }; str__ptr(&__sc1032); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1033 = (str){ (const uint8_t *)"_Thread_local", sizeof("_Thread_local") - 1 }; str__ptr(&__sc1033); }))));
  }
  if (c0 == 97U) {
    return codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1034 = (str){ (const uint8_t *)"auto", sizeof("auto") - 1 }; str__ptr(&__sc1034); })));
  }
  if (c0 == 98U) {
    return (codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1035 = (str){ (const uint8_t *)"break", sizeof("break") - 1 }; str__ptr(&__sc1035); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1036 = (str){ (const uint8_t *)"bool", sizeof("bool") - 1 }; str__ptr(&__sc1036); }))));
  }
  if (c0 == 99U) {
    return (((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1037 = (str){ (const uint8_t *)"case", sizeof("case") - 1 }; str__ptr(&__sc1037); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1038 = (str){ (const uint8_t *)"char", sizeof("char") - 1 }; str__ptr(&__sc1038); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1039 = (str){ (const uint8_t *)"const", sizeof("const") - 1 }; str__ptr(&__sc1039); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1040 = (str){ (const uint8_t *)"continue", sizeof("continue") - 1 }; str__ptr(&__sc1040); }))));
  }
  if (c0 == 100U) {
    return ((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1041 = (str){ (const uint8_t *)"default", sizeof("default") - 1 }; str__ptr(&__sc1041); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1042 = (str){ (const uint8_t *)"do", sizeof("do") - 1 }; str__ptr(&__sc1042); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1043 = (str){ (const uint8_t *)"double", sizeof("double") - 1 }; str__ptr(&__sc1043); }))));
  }
  if (c0 == 101U) {
    return ((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1044 = (str){ (const uint8_t *)"else", sizeof("else") - 1 }; str__ptr(&__sc1044); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1045 = (str){ (const uint8_t *)"enum", sizeof("enum") - 1 }; str__ptr(&__sc1045); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1046 = (str){ (const uint8_t *)"extern", sizeof("extern") - 1 }; str__ptr(&__sc1046); }))));
  }
  if (c0 == 102U) {
    return ((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1047 = (str){ (const uint8_t *)"float", sizeof("float") - 1 }; str__ptr(&__sc1047); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1048 = (str){ (const uint8_t *)"for", sizeof("for") - 1 }; str__ptr(&__sc1048); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1049 = (str){ (const uint8_t *)"false", sizeof("false") - 1 }; str__ptr(&__sc1049); }))));
  }
  if (c0 == 103U) {
    return codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1050 = (str){ (const uint8_t *)"goto", sizeof("goto") - 1 }; str__ptr(&__sc1050); })));
  }
  if (c0 == 105U) {
    return ((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1051 = (str){ (const uint8_t *)"if", sizeof("if") - 1 }; str__ptr(&__sc1051); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1052 = (str){ (const uint8_t *)"inline", sizeof("inline") - 1 }; str__ptr(&__sc1052); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1053 = (str){ (const uint8_t *)"int", sizeof("int") - 1 }; str__ptr(&__sc1053); }))));
  }
  if (c0 == 108U) {
    return codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1054 = (str){ (const uint8_t *)"long", sizeof("long") - 1 }; str__ptr(&__sc1054); })));
  }
  if (c0 == 114U) {
    return ((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1055 = (str){ (const uint8_t *)"register", sizeof("register") - 1 }; str__ptr(&__sc1055); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1056 = (str){ (const uint8_t *)"restrict", sizeof("restrict") - 1 }; str__ptr(&__sc1056); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1057 = (str){ (const uint8_t *)"return", sizeof("return") - 1 }; str__ptr(&__sc1057); }))));
  }
  if (c0 == 115U) {
    return (((((codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1058 = (str){ (const uint8_t *)"short", sizeof("short") - 1 }; str__ptr(&__sc1058); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1059 = (str){ (const uint8_t *)"signed", sizeof("signed") - 1 }; str__ptr(&__sc1059); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1060 = (str){ (const uint8_t *)"sizeof", sizeof("sizeof") - 1 }; str__ptr(&__sc1060); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1061 = (str){ (const uint8_t *)"static", sizeof("static") - 1 }; str__ptr(&__sc1061); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1062 = (str){ (const uint8_t *)"struct", sizeof("struct") - 1 }; str__ptr(&__sc1062); })))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1063 = (str){ (const uint8_t *)"switch", sizeof("switch") - 1 }; str__ptr(&__sc1063); }))));
  }
  if (c0 == 116U) {
    return (codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1064 = (str){ (const uint8_t *)"typedef", sizeof("typedef") - 1 }; str__ptr(&__sc1064); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1065 = (str){ (const uint8_t *)"true", sizeof("true") - 1 }; str__ptr(&__sc1065); }))));
  }
  if (c0 == 117U) {
    return (codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1066 = (str){ (const uint8_t *)"union", sizeof("union") - 1 }; str__ptr(&__sc1066); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1067 = (str){ (const uint8_t *)"unsigned", sizeof("unsigned") - 1 }; str__ptr(&__sc1067); }))));
  }
  if (c0 == 118U) {
    return (codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1068 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1068); }))) || codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1069 = (str){ (const uint8_t *)"volatile", sizeof("volatile") - 1 }; str__ptr(&__sc1069); }))));
  }
  if (c0 == 119U) {
    return codegen__codegen__span_is(src, s, ((const char *)({ __auto_type __sc1070 = (str){ (const uint8_t *)"while", sizeof("while") - 1 }; str__ptr(&__sc1070); })));
  }
  return false;
}

static __attribute__((unused)) const char *codegen__codegen__agg_kw(const ast__ast__Node *const n) {
  if ((n->kind == ast__ast__NodeKind_NODE_STRUCT) && n->as_data.aggregate.is_union) {
    return ((const char *)({ __auto_type __sc1071 = (str){ (const uint8_t *)"union", sizeof("union") - 1 }; str__ptr(&__sc1071); }));
  }
  return ((const char *)({ __auto_type __sc1072 = (str){ (const uint8_t *)"struct", sizeof("struct") - 1 }; str__ptr(&__sc1072); }));
}

static __attribute__((unused)) bool codegen__codegen__want_fn(int32_t const which, bool const is_public) {
  return ((which == codegen__codegen__PROTO_ALL) || ((which == codegen__codegen__PROTO_PUBLIC) == is_public));
}

static __attribute__((unused)) bool codegen__codegen__cg_span_eq(const uint8_t *const sa, lexer__token__Span const a, const uint8_t *const sb, lexer__token__Span const b) {
  const size_t la = ((size_t)(a.end - a.start));
  if (la != ((size_t)(b.end - b.start))) {
    return false;
  }
  return (memcmp((sa + ((size_t)a.start)), (sb + ((size_t)b.start)), la) == 0);
}

static __attribute__((unused)) ast__ast__NodeList codegen__codegen__Codegen__program_items(const codegen__codegen__Codegen *const self) {
  return ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), (*codegen__codegen__Codegen__cur_ast(self)).root)->as_data.program.items;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__type_emittable(const codegen__codegen__Codegen *const self, uint32_t const declId) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId);
  if ((n->kind == ast__ast__NodeKind_NODE_STRUCT) && (n->as_data.aggregate.generics.len == 0U)) {
    return true;
  }
  if (((n->kind == ast__ast__NodeKind_NODE_ENUM) && (n->as_data.aggregate.generics.len == 0U)) && codegen__codegen__Codegen__aggregate_has_payload(self, declId)) {
    return true;
  }
  return false;
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__fn_array_return(const codegen__codegen__Codegen *const self, uint32_t const fn_id) {
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function.returns;
  if (rets.len != 1U) {
    return ast__ast__NODE_NONE;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), rets)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), r0);
  const uint32_t tn = ({
    uint32_t __sc1073;
    if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
      __sc1073 = rn->as_data.parameter.ty;
    } else {
      __sc1073 = r0;
    }
    __sc1073;
  });
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), tn)->kind == ast__ast__NodeKind_NODE_ARRAY_TYPE) {
    return tn;
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_ret_struct_named(codegen__codegen__Codegen *const self, uint32_t const fn_id, const char *const nm) {
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function.returns;
  const uint32_t arr = codegen__codegen__Codegen__fn_array_return(self, fn_id);
  if (arr != ast__ast__NODE_NONE) {
    codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_node(self, arr, ((const char *)({ __auto_type __sc1074 = (str){ (const uint8_t *)"_", sizeof("_") - 1 }; str__ptr(&__sc1074); })), ((char *)(&d.b[0])), 256ULL);
    ({ String__Global *__sc1075 = &(self->buf);
String__Global__push_str(&(*__sc1075), (str){ .ptr = (const uint8_t*)"typedef struct { ", .len = sizeof("typedef struct { ") - 1 });
String__Global__push_str(&(*__sc1075), utils__errors__cstr(((const char *)(&d.b[0]))));
String__Global__push_str(&(*__sc1075), (str){ .ptr = (const uint8_t*)"; } ", .len = sizeof("; } ") - 1 });
String__Global__push_str(&(*__sc1075), utils__errors__cstr(nm));
String__Global__push_str(&(*__sc1075), (str){ .ptr = (const uint8_t*)"_ret;\n", .len = sizeof("_ret;\n") - 1 });
});
    return;
  }
  if (rets.len <= 1U) {
    return;
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1076 = (str){ (const uint8_t *)"typedef struct { ", sizeof("typedef struct { ") - 1 }; str__ptr(&__sc1076); })));
  for (uint32_t i = 0U; i < rets.len; i++) {
    const uint32_t rid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), rets)[((size_t)i)];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), rid);
    const uint32_t tn = ({
      uint32_t __sc1077;
      if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
        __sc1077 = rn->as_data.parameter.ty;
      } else {
        __sc1077 = rid;
      }
      __sc1077;
    });
    codegen__codegen__Buf32 fld = (codegen__codegen__Buf32){0};
    snprintf(((char *)(&fld.b[0])), 16ULL, ((const char *)({ __auto_type __sc1078 = (str){ (const uint8_t *)"_%u", sizeof("_%u") - 1 }; str__ptr(&__sc1078); })), i);
    codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_node(self, tn, ((const char *)(&fld.b[0])), ((char *)(&d.b[0])), 256ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&d.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1079 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc1079); })));
  }
  ({ String__Global *__sc1080 = &(self->buf);
String__Global__push_str(&(*__sc1080), (str){ .ptr = (const uint8_t*)"} ", .len = sizeof("} ") - 1 });
String__Global__push_str(&(*__sc1080), utils__errors__cstr(nm));
String__Global__push_str(&(*__sc1080), (str){ .ptr = (const uint8_t*)"_ret;\n", .len = sizeof("_ret;\n") - 1 });
});
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_ret_struct(codegen__codegen__Codegen *const self, uint32_t const fn_id, ast__ast__DefId const target) {
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function.returns;
  if ((rets.len <= 1U) && (codegen__codegen__Codegen__fn_array_return(self, fn_id) == ast__ast__NODE_NONE)) {
    return;
  }
  codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__function_name(self, fn_id, target, ((char *)(&nm.b[0])), 256ULL, true);
  codegen__codegen__Codegen__emit_ret_struct_named(self, fn_id, ((const char *)(&nm.b[0])));
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_conv_count(const codegen__codegen__Codegen *const self, uint16_t const tmod, uint32_t const tdecl, const char *const lit) {
  int32_t n = 0;
  const uint16_t cur = codegen__codegen__Codegen__cur_module(self);
  const int32_t ns = ({
    int32_t __sc1081;
    if (tmod == cur) {
      __sc1081 = 1;
    } else {
      __sc1081 = 2;
    }
    __sc1081;
  });
  for (int32_t s = 0; s < ns; s++) {
    const uint16_t m = ({
      uint16_t __sc1082;
      if (s == 0) {
        __sc1082 = tmod;
      } else {
        __sc1082 = cur;
      }
      __sc1082;
    });
    ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if ((it->kind != ast__ast__NodeKind_NODE_EXTEND) || (it->as_data.extend_def.target_type == ast__ast__NODE_NONE)) {
        continue;
      }
      const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type);
      if ((tg.module != tmod) || (tg.node != tdecl)) {
        continue;
      }
      const ast__ast__NodeList ms = it->as_data.extend_def.items;
      for (uint32_t j = 0U; j < ms.len; j++) {
        const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)j)];
        const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
        if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, m), ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text, lit)) {
          (n = ({ int32_t __sc_r; if (__builtin_add_overflow(n, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        }
      }
    }
  }
  return n;
}

static __attribute__((unused)) void codegen__codegen__Codegen__cg_conv_suffix(codegen__codegen__Codegen *const self, ast__ast__DefId const target, const char *const lit, uint32_t const srcTy, char *const out, size_t const cap) {
  if (cap != 0ULL) {
    (out[0] = 0);
  }
  if ((((target.node == ast__ast__NODE_NONE) || (srcTy == ast__ast__TYPE_NONE)) || (lit == NULL)) || (codegen__codegen__Codegen__cg_conv_count(self, target.module, target.node, lit) < 2)) {
    return;
  }
  const size_t at = codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc1083 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1083); })));
  codegen__codegen__Buf176 e = (codegen__codegen__Buf176){0};
  codegen__codegen__Codegen__mangle_type(self, codegen__codegen__Codegen__subst_resolve(self, srcTy), ((char *)(&e.b[0])), 176ULL);
  codegen__codegen__bappend(out, cap, at, ((const char *)(&e.b[0])));
}

static __attribute__((unused)) void codegen__codegen__Codegen__render_params(codegen__codegen__Codegen *const self, ast__ast__NodeList const params, char *const out, size_t const cap) {
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), params);
  size_t k = 0ULL;
  (out[0] = 0);
  bool any = false;
  uint32_t i = 0U;
  while ((i < params.len) && (k < cap)) {
    const uint32_t pid = ids[((size_t)i)];
    if (pid == self->cb_param) {
      (i = (i + 1U));
      continue;
    }
    const ast__ast__ParameterData p = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid)->as_data.parameter;
    codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
    codegen__codegen__Codegen__render_ident(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), p.name)->as_data.name.text, ((char *)(&nm.b[0])), 128ULL);
    if ((nm.b[0] == 95) && (nm.b[1] == 0)) {
      snprintf(((char *)(&nm.b[0])), 128ULL, ((const char *)({ __auto_type __sc1084 = (str){ (const uint8_t *)"__sc_u%u", sizeof("__sc_u%u") - 1 }; str__ptr(&__sc1084); })), pid);
    }
    const uint32_t pty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), pid);
    const bool pconst = ((!p.is_mutable) && (!codegen__codegen__Codegen__cg_type_is_free(self, pty)));
    codegen__codegen__Buf300 d = (codegen__codegen__Buf300){0};
    if (p.ty == ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__render_type_id(self, codegen__codegen__Codegen__subst_resolve(self, pty), ((const char *)(&nm.b[0])), ((char *)(&d.b[0])), 300ULL);
    } else {
      codegen__codegen__Codegen__render_binding_node(self, p.ty, ((const char *)(&nm.b[0])), pconst, ((char *)(&d.b[0])), 300ULL);
    }
    if (any) {
      (k = codegen__codegen__bappend(out, cap, k, ((const char *)({ __auto_type __sc1085 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1085); }))));
    }
    (k = codegen__codegen__bappend(out, cap, k, ((const char *)(&d.b[0]))));
    (any = true);
    (i = (i + 1U));
  }
  if (!any) {
    codegen__codegen__buf_join3(out, cap, ((const char *)({ __auto_type __sc1086 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1086); })), ((const char *)({ __auto_type __sc1087 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1087); })), ((const char *)({ __auto_type __sc1088 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1088); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__function_name(codegen__codegen__Codegen *const self, uint32_t const fn_id, ast__ast__DefId const target, char *const out, size_t const cap, bool const prefixed) {
  if (codegen__codegen__Codegen__cg_symbol_override(self, codegen__codegen__Codegen__cur_module(self), fn_id, out, cap)) {
    return;
  }
  const lexer__token__Span fname = codegen__codegen__Codegen__name_span(self, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function.name);
  const bool is_main = ((target.node == ast__ast__NODE_NONE) && codegen__codegen__span_is(self->source, fname, ((const char *)({ __auto_type __sc1089 = (str){ (const uint8_t *)"main", sizeof("main") - 1 }; str__ptr(&__sc1089); }))));
  size_t k = 0ULL;
  if (prefixed && (!is_main)) {
    (k = codegen__codegen__Codegen__render_modpfx(self, codegen__codegen__Codegen__cur_module(self), out, cap));
  }
  if (k >= cap) {
    if (cap != 0ULL) {
      (k = (cap - 1ULL));
    } else {
      (k = 0ULL);
    }
  }
  if (target.node != ast__ast__NODE_NONE) {
    int32_t bb = -1;
    if (self->package != NULL) {
      (bb = module__loader__Package__builtin_of_decl(&((*self->package)), target.module, target.node));
    }
    if (bb >= 0) {
      (k = codegen__codegen__bappend(out, cap, k, codegen__codegen__builtin_name(((ast__ast__BuiltinType)bb))));
    } else {
      const lexer__token__Span ts = codegen__codegen__Codegen__name_span_in(self, target.module, codegen__codegen__Codegen__cg_decl_name_node(self, target.module, target.node));
      (k = (k + codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, target.module), ts, ((char *)(out + k)), (cap - k))));
    }
    if ((k + 2ULL) < cap) {
      (out[k] = 95);
      (out[(k + 1ULL)] = 95);
      (k = (k + 2ULL));
    }
  }
  (k = (k + codegen__codegen__Codegen__render_ident(self, fname, ((char *)(out + k)), (cap - k))));
  const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function.params;
  const char *const lit = codegen__codegen__Codegen__cg_conv_lit(self, codegen__codegen__Codegen__cur_module(self), fname);
  if (((lit != NULL) && (target.node != ast__ast__NODE_NONE)) && (params.len != 0U)) {
    const uint32_t p0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), params)[0];
    const uint32_t p0ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), p0)->as_data.parameter.ty);
    codegen__codegen__Codegen__cg_conv_suffix(self, target, lit, p0ty, ((char *)(out + k)), (cap - k));
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_subtree_uses(const codegen__codegen__Codegen *const self, uint32_t const id, uint32_t const param) {
  if (id == ast__ast__NODE_NONE) {
    return false;
  }
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id);
  const ast__ast__NodeKind k = n->kind;
  if (k == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), id);
    return ((d.module == codegen__codegen__Codegen__cur_module(self)) && (d.node == param));
  }
  if (k == ast__ast__NodeKind_NODE_BLOCK) {
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.block.statements);
    for (uint32_t i = 0U; i < n->as_data.block.statements.len; i++) {
      if (codegen__codegen__Codegen__cg_subtree_uses(self, ids[((size_t)i)], param)) {
        return true;
      }
    }
    return false;
  }
  if (k == ast__ast__NodeKind_NODE_LET) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.let_stmt.value, param);
  }
  if (k == ast__ast__NodeKind_NODE_RETURN) {
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.return_stmt.values);
    for (uint32_t i = 0U; i < n->as_data.return_stmt.values.len; i++) {
      if (codegen__codegen__Codegen__cg_subtree_uses(self, ids[((size_t)i)], param)) {
        return true;
      }
    }
    return false;
  }
  if ((k == ast__ast__NodeKind_NODE_DEFER) || (k == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT)) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.single.value, param);
  }
  if (k == ast__ast__NodeKind_NODE_IF) {
    return ((codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.if_stmt.condition, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.if_stmt.then_branch, param)) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.if_stmt.else_branch, param));
  }
  if (k == ast__ast__NodeKind_NODE_WHILE) {
    return (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.while_stmt.condition, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.while_stmt.body, param));
  }
  if (k == ast__ast__NodeKind_NODE_FOR) {
    return (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.for_stmt.iterable, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.for_stmt.body, param));
  }
  if (k == ast__ast__NodeKind_NODE_MATCH) {
    if (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.match_expr.value, param)) {
      return true;
    }
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.match_expr.arms);
    for (uint32_t i = 0U; i < n->as_data.match_expr.arms.len; i++) {
      const ast__ast__Node *const arm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ids[((size_t)i)]);
      if (codegen__codegen__Codegen__cg_subtree_uses(self, arm->as_data.match_arm.guard, param) || codegen__codegen__Codegen__cg_subtree_uses(self, arm->as_data.match_arm.body, param)) {
        return true;
      }
    }
    return false;
  }
  if ((k == ast__ast__NodeKind_NODE_ASSIGNMENT) || (k == ast__ast__NodeKind_NODE_BINARY)) {
    return (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.binary.left, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.binary.right, param));
  }
  if (k == ast__ast__NodeKind_NODE_UNARY) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.unary.operand, param);
  }
  if (k == ast__ast__NodeKind_NODE_CALL) {
    if (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.call.callee, param)) {
      return true;
    }
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.call.args);
    for (uint32_t i = 0U; i < n->as_data.call.args.len; i++) {
      if (codegen__codegen__Codegen__cg_subtree_uses(self, ids[((size_t)i)], param)) {
        return true;
      }
    }
    return false;
  }
  if (k == ast__ast__NodeKind_NODE_INDEX) {
    return (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.index.object, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.index.index, param));
  }
  if (k == ast__ast__NodeKind_NODE_MEMBER) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.member.object, param);
  }
  if (k == ast__ast__NodeKind_NODE_CAST) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.cast.expression, param);
  }
  if (k == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.specialization.expression, param);
  }
  if (k == ast__ast__NodeKind_NODE_NEW) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.new_expr.initializer, param);
  }
  if (k == ast__ast__NodeKind_NODE_VA_EXPR) {
    return (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.va_op.ap, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.va_op.extra, param));
  }
  if (k == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.array_literal.elements);
    for (uint32_t i = 0U; i < n->as_data.array_literal.elements.len; i++) {
      if (codegen__codegen__Codegen__cg_subtree_uses(self, ids[((size_t)i)], param)) {
        return true;
      }
    }
    return false;
  }
  if (k == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
    const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), n->as_data.struct_initializer.fields);
    for (uint32_t i = 0U; i < n->as_data.struct_initializer.fields.len; i++) {
      const uint32_t fv = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ids[((size_t)i)])->as_data.field_initializer.value;
      if (codegen__codegen__Codegen__cg_subtree_uses(self, fv, param)) {
        return true;
      }
    }
    return false;
  }
  if (k == ast__ast__NodeKind_NODE_CLOSURE) {
    return codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.closure.body, param);
  }
  if (k == ast__ast__NodeKind_NODE_RANGE) {
    return (codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.pattern_range.start, param) || codegen__codegen__Codegen__cg_subtree_uses(self, n->as_data.pattern_range.end, param));
  }
  return false;
}

static __attribute__((unused)) size_t codegen__codegen__addg(char *const g, size_t const cap, size_t const gn, const char *const s) {
  size_t at = gn;
  if (at != 0ULL) {
    (at = codegen__codegen__bappend(g, cap, at, ((const char *)({ __auto_type __sc1090 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1090); }))));
  }
  return codegen__codegen__bappend(g, cap, at, s);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_function(codegen__codegen__Codegen *const self, uint32_t const fn_id, ast__ast__DefId const target, bool const extern_q, bool const with_body, const char *const name_override, bool const spec_static) {
  const ast__ast__FunctionData f = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function;
  codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
  if (name_override != NULL) {
    codegen__codegen__bappend(((char *)(&nm.b[0])), 256ULL, 0ULL, name_override);
  } else {
    codegen__codegen__Codegen__function_name(self, fn_id, target, ((char *)(&nm.b[0])), 256ULL, (!extern_q));
  }
  const bool is_main = (((target.node == ast__ast__NODE_NONE) && (name_override == NULL)) && codegen__codegen__span_is(self->source, codegen__codegen__Codegen__name_span(self, f.name), ((const char *)({ __auto_type __sc1091 = (str){ (const uint8_t *)"main", sizeof("main") - 1 }; str__ptr(&__sc1091); }))));
  const bool exported = (codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), fn_id, ast__ast__AttrKind_ATTR_EXPORT) != NULL);
  const bool is_static = ({
    bool __sc1092;
    if (name_override != NULL) {
      __sc1092 = spec_static;
    } else {
      __sc1092 = ((((self->multifile && (!extern_q)) && (!is_main)) && (!exported)) && (!f.is_public));
    }
    __sc1092;
  });
  codegen__codegen__Buf1024 ps = (codegen__codegen__Buf1024){0};
  codegen__codegen__Codegen__render_params(self, f.params, ((char *)(&ps.b[0])), 1024ULL);
  if (f.is_variadic && (strcmp(((const char *)(&ps.b[0])), ((const char *)({ __auto_type __sc1093 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1093); }))) != 0)) {
    const size_t psl = strlen(((const char *)(&ps.b[0])));
    codegen__codegen__bappend(((char *)(&ps.b[0])), 1024ULL, psl, ((const char *)({ __auto_type __sc1094 = (str){ (const uint8_t *)", ...", sizeof(", ...") - 1 }; str__ptr(&__sc1094); })));
  }
  codegen__codegen__Buf1320 decl = (codegen__codegen__Buf1320){0};
  size_t at = 0ULL;
  (decl.b[0] = 0);
  if (extern_q) {
    (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1095 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc1095); }))));
  }
  (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)(&nm.b[0]))));
  if (extern_q) {
    (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1096 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc1096); }))));
  }
  (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1097 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc1097); }))));
  (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)(&ps.b[0]))));
  codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1098 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc1098); })));
  if (extern_q) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1099 = (str){ (const uint8_t *)"extern ", sizeof("extern ") - 1 }; str__ptr(&__sc1099); })));
  }
  if (is_static) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1100 = (str){ (const uint8_t *)"static ", sizeof("static ") - 1 }; str__ptr(&__sc1100); })));
  }
  const uint16_t fmod = codegen__codegen__Codegen__cur_module(self);
  if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_NORETURN) != NULL) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1101 = (str){ (const uint8_t *)"_Noreturn ", sizeof("_Noreturn ") - 1 }; str__ptr(&__sc1101); })));
  }
  if ((codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_INLINE) != NULL) || (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_ALWAYS_INLINE) != NULL)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1102 = (str){ (const uint8_t *)"inline ", sizeof("inline ") - 1 }; str__ptr(&__sc1102); })));
  }
  codegen__codegen__Buf256 g = (codegen__codegen__Buf256){0};
  (g.b[0] = 0);
  size_t gn = 0ULL;
  if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_ALWAYS_INLINE) != NULL) {
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1103 = (str){ (const uint8_t *)"always_inline", sizeof("always_inline") - 1 }; str__ptr(&__sc1103); }))));
  }
  if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_NOINLINE) != NULL) {
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1104 = (str){ (const uint8_t *)"noinline", sizeof("noinline") - 1 }; str__ptr(&__sc1104); }))));
  }
  if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_COLD) != NULL) {
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1105 = (str){ (const uint8_t *)"cold", sizeof("cold") - 1 }; str__ptr(&__sc1105); }))));
    if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_NOINLINE) == NULL) {
      (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1106 = (str){ (const uint8_t *)"noinline", sizeof("noinline") - 1 }; str__ptr(&__sc1106); }))));
    }
  }
  if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_USED) != NULL) {
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1107 = (str){ (const uint8_t *)"used", sizeof("used") - 1 }; str__ptr(&__sc1107); }))));
  }
  if (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_UNUSED) != NULL) {
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1108 = (str){ (const uint8_t *)"unused", sizeof("unused") - 1 }; str__ptr(&__sc1108); }))));
  }
  if (is_static && (codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_USED) == NULL)) {
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)({ __auto_type __sc1109 = (str){ (const uint8_t *)"unused", sizeof("unused") - 1 }; str__ptr(&__sc1109); }))));
  }
  const ast__ast__Attr *const sec = codegen__codegen__Codegen__cg_attr(self, fmod, fn_id, ast__ast__AttrKind_ATTR_SECTION);
  if (sec != NULL) {
    const lexer__token__Span sp = (*sec).str_span;
    size_t nl = ((size_t)(sp.end - sp.start));
    if (nl >= 128ULL) {
      (nl = 127ULL);
    }
    codegen__codegen__Buf128 nm2 = (codegen__codegen__Buf128){0};
    memcpy(((void *)(&nm2.b[0])), (codegen__codegen__Codegen__mod_src(self, fmod) + ((size_t)sp.start)), nl);
    (nm2.b[nl] = 0);
    codegen__codegen__Buf160 sb = (codegen__codegen__Buf160){0};
    snprintf(((char *)(&sb.b[0])), 160ULL, ((const char *)({ __auto_type __sc1110 = (str){ (const uint8_t *)"section(\"%s\")", sizeof("section(\"%s\")") - 1 }; str__ptr(&__sc1110); })), ((const char *)(&nm2.b[0])));
    (gn = codegen__codegen__addg(((char *)(&g.b[0])), 256ULL, gn, ((const char *)(&sb.b[0]))));
  }
  if (gn != 0ULL) {
    ({ String__Global *__sc1111 = &(self->buf);
String__Global__push_str(&(*__sc1111), (str){ .ptr = (const uint8_t*)"__attribute__((", .len = sizeof("__attribute__((") - 1 });
String__Global__push_str(&(*__sc1111), utils__errors__cstr(((const char *)(&g.b[0]))));
String__Global__push_str(&(*__sc1111), (str){ .ptr = (const uint8_t*)")) ", .len = sizeof(")) ") - 1 });
});
  }
  const ast__ast__NodeList rets = f.returns;
  (self->current_ret[0] = 0);
  (self->current_fn_ret_node = ast__ast__NODE_NONE);
  if (((target.node == ast__ast__NODE_NONE) && (!extern_q)) && codegen__codegen__span_is(self->source, codegen__codegen__Codegen__name_span(self, f.name), ((const char *)({ __auto_type __sc1112 = (str){ (const uint8_t *)"main", sizeof("main") - 1 }; str__ptr(&__sc1112); })))) {
    ({ String__Global *__sc1113 = &(self->buf);
String__Global__push_str(&(*__sc1113), (str){ .ptr = (const uint8_t*)"int ", .len = sizeof("int ") - 1 });
String__Global__push_str(&(*__sc1113), utils__errors__cstr(((const char *)(&decl.b[0]))));
});
  } else if (rets.len > 1U) {
    codegen__codegen__buf_join3(((char *)(&self->current_ret[0])), 128ULL, ((const char *)(&nm.b[0])), ((const char *)({ __auto_type __sc1114 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1114); })), ((const char *)({ __auto_type __sc1115 = (str){ (const uint8_t *)"_ret", sizeof("_ret") - 1 }; str__ptr(&__sc1115); })));
    const char *const cr = ((const char *)(&self->current_ret[0]));
    codegen__codegen__Codegen__emit_cstr(self, cr);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1116 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1116); })));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  } else if (codegen__codegen__Codegen__fn_array_return(self, fn_id) != ast__ast__NODE_NONE) {
    codegen__codegen__buf_join3(((char *)(&self->current_ret[0])), 128ULL, ((const char *)(&nm.b[0])), ((const char *)({ __auto_type __sc1117 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1117); })), ((const char *)({ __auto_type __sc1118 = (str){ (const uint8_t *)"_ret", sizeof("_ret") - 1 }; str__ptr(&__sc1118); })));
    const char *const cr = ((const char *)(&self->current_ret[0]));
    codegen__codegen__Codegen__emit_cstr(self, cr);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1119 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1119); })));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  } else if (rets.len == 1U) {
    const uint32_t r0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), rets)[0];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), r0);
    (self->current_fn_ret_node = ({
      uint32_t __sc1120;
      if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
        __sc1120 = rn->as_data.parameter.ty;
      } else {
        __sc1120 = r0;
      }
      __sc1120;
    }));
    codegen__codegen__Buf1400 out = (codegen__codegen__Buf1400){0};
    codegen__codegen__Codegen__render_type_node(self, self->current_fn_ret_node, ((const char *)(&decl.b[0])), ((char *)(&out.b[0])), 1400ULL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&out.b[0])));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1121 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc1121); })));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  }
  if (with_body && (f.body != ast__ast__NODE_NONE)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1122 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1122); })));
    (self->defer_top = 0U);
    (self->loop_defer_base = 0U);
    (self->nmoved = 0U);
    (self->ncond_moved = 0U);
    (self->ncond_sites = 0U);
    codegen__codegen__Codegen__cg_scan_moves(self, f.body, false, 0);
    codegen__codegen__Codegen__cg_scan_moves(self, f.body, false, 1);
    const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), f.params);
    (self->nparam_flags = 0U);
    (self->nunused_params = 0U);
    for (uint32_t i = 0U; i < f.params.len; i++) {
      const uint32_t pid = pids[((size_t)i)];
      if (codegen__codegen__Codegen__cg_will_auto_free(self, pid)) {
        codegen__codegen__Codegen__cg_register_auto_free(self, pid);
        if (codegen__codegen__Codegen__cg_is_cond_moved(self, pid) && (self->nparam_flags < 32U)) {
          (self->param_flags[((size_t)self->nparam_flags)] = pid);
          (self->nparam_flags = (self->nparam_flags + 1U));
        }
      } else if ((!codegen__codegen__Codegen__cg_subtree_uses(self, f.body, pid)) && (self->nunused_params < 32U)) {
        (self->unused_params[((size_t)self->nunused_params)] = pid);
        (self->nunused_params = (self->nunused_params + 1U));
      }
    }
    codegen__codegen__Codegen__emit_block_from(self, f.body, 0U);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1123 = (str){ (const uint8_t *)"\n\n", sizeof("\n\n") - 1 }; str__ptr(&__sc1123); })));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1124 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1124); })));
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_is_format_builtin(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const node) {
  if (((self->package == NULL) || (((size_t)m) >= codegen__codegen__Codegen__pkg_count(self))) || (!(*({ __auto_type __sc1125 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1125, ((size_t)m)); })).prelude)) {
    return false;
  }
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  if (ast__ast__Ast__at_const(&((*a)), node)->kind != ast__ast__NodeKind_NODE_FUNCTION) {
    return false;
  }
  const lexer__token__Span fnm = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), node)->as_data.function.name)->as_data.name.text;
  const uint8_t *const s = codegen__codegen__Codegen__mod_src(self, m);
  return ((((((((codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1126 = (str){ (const uint8_t *)"format", sizeof("format") - 1 }; str__ptr(&__sc1126); }))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1127 = (str){ (const uint8_t *)"format_into", sizeof("format_into") - 1 }; str__ptr(&__sc1127); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1128 = (str){ (const uint8_t *)"print", sizeof("print") - 1 }; str__ptr(&__sc1128); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1129 = (str){ (const uint8_t *)"println", sizeof("println") - 1 }; str__ptr(&__sc1129); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1130 = (str){ (const uint8_t *)"eprint", sizeof("eprint") - 1 }; str__ptr(&__sc1130); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1131 = (str){ (const uint8_t *)"eprintln", sizeof("eprintln") - 1 }; str__ptr(&__sc1131); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1132 = (str){ (const uint8_t *)"assert", sizeof("assert") - 1 }; str__ptr(&__sc1132); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1133 = (str){ (const uint8_t *)"assert_eq", sizeof("assert_eq") - 1 }; str__ptr(&__sc1133); })))) || codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1134 = (str){ (const uint8_t *)"assert_ne", sizeof("assert_ne") - 1 }; str__ptr(&__sc1134); }))));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_type_mentions_fnval(const codegen__codegen__Codegen *const self, uint32_t const t) {
  if (t == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, t));
  if (y.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    return true;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    return codegen__codegen__Codegen__cg_type_mentions_fnval(self, y.as_data.elem);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    for (uint8_t i = 0U; i < it.n; i++) {
      if (codegen__codegen__Codegen__cg_type_mentions_fnval(self, it.args[((size_t)i)])) {
        return true;
      }
    }
    return false;
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__inst_mentions_fnval(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it) {
  for (uint8_t i = 0U; i < it->n; i++) {
    if (codegen__codegen__Codegen__cg_type_mentions_fnval(self, it->args[((size_t)i)])) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_test_skip(const codegen__codegen__Codegen *const self, uint32_t const fn2, bool const method) {
  if (self->test.enabled) {
    const ast__ast__Node *const f = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn2);
    return (((!method) && (f->kind == ast__ast__NodeKind_NODE_FUNCTION)) && codegen__codegen__span_is(self->source, ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), f->as_data.function.name)->as_data.name.text, ((const char *)({ __auto_type __sc1135 = (str){ (const uint8_t *)"main", sizeof("main") - 1 }; str__ptr(&__sc1135); }))));
  }
  return (((codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), fn2, ast__ast__AttrKind_ATTR_TEST) != NULL) || (codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), fn2, ast__ast__AttrKind_ATTR_TEST_INIT) != NULL)) || (codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), fn2, ast__ast__AttrKind_ATTR_TEST_FREE) != NULL));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_full(codegen__codegen__Codegen *const self, uint32_t const enum_id) {
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), enum_id)->as_data.aggregate;
  codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), ag.name, ((char *)(&nm.b[0])), 160ULL);
  ({ String__Global *__sc1136 = &(self->buf);
String__Global__push_str(&(*__sc1136), (str){ .ptr = (const uint8_t*)"#ifndef SUPER_ENUM_", .len = sizeof("#ifndef SUPER_ENUM_") - 1 });
String__Global__push_str(&(*__sc1136), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1136), (str){ .ptr = (const uint8_t*)"\n#define SUPER_ENUM_", .len = sizeof("\n#define SUPER_ENUM_") - 1 });
String__Global__push_str(&(*__sc1136), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1136), (str){ .ptr = (const uint8_t*)"\n", .len = sizeof("\n") - 1 });
});
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1137 = (str){ (const uint8_t *)"typedef enum { ", sizeof("typedef enum { ") - 1 }; str__ptr(&__sc1137); })));
  const ast__ast__NodeList ms = ag.members;
  for (uint32_t j = 0U; j < ms.len; j++) {
    if (j != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1138 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1138); })));
    }
    const uint32_t mid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms)[((size_t)j)];
    codegen__codegen__Codegen__emit_tag(self, enum_id, mid);
    const uint32_t disc = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.variant.value;
    if (disc != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1139 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc1139); })));
      const bool sc = self->const_ctx;
      (self->const_ctx = true);
      codegen__codegen__Codegen__emit_expr(self, disc);
      (self->const_ctx = sc);
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1140 = (str){ (const uint8_t *)" } ", sizeof(" } ") - 1 }; str__ptr(&__sc1140); })));
  codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1141 = (str){ (const uint8_t *)";\n#endif\n", sizeof(";\n#endif\n") - 1 }; str__ptr(&__sc1141); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_tag_decl(codegen__codegen__Codegen *const self, uint32_t const enum_id) {
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), enum_id)->as_data.aggregate;
  codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), ag.name, ((char *)(&nm.b[0])), 160ULL);
  ({ String__Global *__sc1142 = &(self->buf);
String__Global__push_str(&(*__sc1142), (str){ .ptr = (const uint8_t*)"#ifndef SUPER_ENUMTAG_", .len = sizeof("#ifndef SUPER_ENUMTAG_") - 1 });
String__Global__push_str(&(*__sc1142), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1142), (str){ .ptr = (const uint8_t*)"\n#define SUPER_ENUMTAG_", .len = sizeof("\n#define SUPER_ENUMTAG_") - 1 });
String__Global__push_str(&(*__sc1142), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1142), (str){ .ptr = (const uint8_t*)"\n", .len = sizeof("\n") - 1 });
});
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1143 = (str){ (const uint8_t *)"typedef enum { ", sizeof("typedef enum { ") - 1 }; str__ptr(&__sc1143); })));
  const ast__ast__NodeList ms = ag.members;
  for (uint32_t j = 0U; j < ms.len; j++) {
    if (j != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1144 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1144); })));
    }
    const uint32_t mid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms)[((size_t)j)];
    codegen__codegen__Codegen__emit_tag(self, enum_id, mid);
    const uint32_t disc = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.variant.value;
    if (disc != ast__ast__NODE_NONE) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1145 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc1145); })));
      const bool sc = self->const_ctx;
      (self->const_ctx = true);
      codegen__codegen__Codegen__emit_expr(self, disc);
      (self->const_ctx = sc);
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1146 = (str){ (const uint8_t *)" } ", sizeof(" } ") - 1 }; str__ptr(&__sc1146); })));
  codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1147 = (str){ (const uint8_t *)"Tag;\n#endif\n", sizeof("Tag;\n#endif\n") - 1 }; str__ptr(&__sc1147); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_struct_body(codegen__codegen__Codegen *const self, uint32_t const dn_id) {
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), dn_id)->as_data.aggregate;
  (self->depth = (self->depth + 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1148 = (str){ (const uint8_t *)"Tag tag;\n", sizeof("Tag tag;\n") - 1 }; str__ptr(&__sc1148); })));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1149 = (str){ (const uint8_t *)"union {\n", sizeof("union {\n") - 1 }; str__ptr(&__sc1149); })));
  (self->depth = (self->depth + 1U));
  const ast__ast__NodeList ms = ag.members;
  for (uint32_t j = 0U; j < ms.len; j++) {
    const uint32_t mid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms)[((size_t)j)];
    const ast__ast__VariantData v = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.variant;
    const ast__ast__NodeList payload = v.payload;
    if (payload.len == 0U) {
      continue;
    }
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1150 = (str){ (const uint8_t *)"struct { ", sizeof("struct { ") - 1 }; str__ptr(&__sc1150); })));
    for (uint32_t k = 0U; k < payload.len; k++) {
      const uint32_t pid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), payload)[((size_t)k)];
      const ast__ast__Node *const pe = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid);
      codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
      if (v.struct_payload) {
        codegen__codegen__Buf128 m = (codegen__codegen__Buf128){0};
        const lexer__token__Span msp = codegen__codegen__Codegen__name_span(self, pe->as_data.field.name);
        codegen__codegen__Codegen__render_ident(self, msp, ((char *)(&m.b[0])), 128ULL);
        codegen__codegen__Codegen__render_type_node(self, pe->as_data.field.ty, ((const char *)(&m.b[0])), ((char *)(&d.b[0])), 256ULL);
      } else {
        codegen__codegen__Buf32 fld = (codegen__codegen__Buf32){0};
        snprintf(((char *)(&fld.b[0])), 24ULL, ((const char *)({ __auto_type __sc1151 = (str){ (const uint8_t *)"_%u", sizeof("_%u") - 1 }; str__ptr(&__sc1151); })), k);
        codegen__codegen__Codegen__render_type_node(self, pid, ((const char *)(&fld.b[0])), ((char *)(&d.b[0])), 256ULL);
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&d.b[0])));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1152 = (str){ (const uint8_t *)"; ", sizeof("; ") - 1 }; str__ptr(&__sc1152); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1153 = (str){ (const uint8_t *)"} ", sizeof("} ") - 1 }; str__ptr(&__sc1153); })));
    const lexer__token__Span vsp = codegen__codegen__Codegen__name_span(self, v.name);
    codegen__codegen__Codegen__emit_span(self, vsp);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1154 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1154); })));
  }
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_indent(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1155 = (str){ (const uint8_t *)"} payload;\n", sizeof("} payload;\n") - 1 }; str__ptr(&__sc1155); })));
  (self->depth = (self->depth - 1U));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_type_decl(codegen__codegen__Codegen *const self, uint32_t const declId) {
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate;
  const ast__ast__NodeKind kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->kind;
  const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId));
  ({ String__Global *__sc1156 = &(self->buf);
String__Global__push_str(&(*__sc1156), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1156), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
  const ast__ast__Attr *const pk = codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), declId, ast__ast__AttrKind_ATTR_PACKED);
  const ast__ast__Attr *const al = codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), declId, ast__ast__AttrKind_ATTR_ALIGN);
  if ((pk != NULL) || (al != NULL)) {
    codegen__codegen__Buf64 g = (codegen__codegen__Buf64){0};
    (g.b[0] = 0);
    size_t gn = 0ULL;
    if (pk != NULL) {
      (gn = codegen__codegen__bappend(((char *)(&g.b[0])), 64ULL, gn, ((const char *)({ __auto_type __sc1157 = (str){ (const uint8_t *)"packed", sizeof("packed") - 1 }; str__ptr(&__sc1157); }))));
    }
    if (al != NULL) {
      if (gn != 0ULL) {
        (gn = codegen__codegen__bappend(((char *)(&g.b[0])), 64ULL, gn, ((const char *)({ __auto_type __sc1158 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1158); }))));
      }
      codegen__codegen__Buf32 a = (codegen__codegen__Buf32){0};
      snprintf(((char *)(&a.b[0])), 32ULL, ((const char *)({ __auto_type __sc1159 = (str){ (const uint8_t *)"aligned(%u)", sizeof("aligned(%u)") - 1 }; str__ptr(&__sc1159); })), (*al).arg);
      codegen__codegen__bappend(((char *)(&g.b[0])), 64ULL, gn, ((const char *)(&a.b[0])));
    }
    ({ String__Global *__sc1160 = &(self->buf);
String__Global__push_str(&(*__sc1160), (str){ .ptr = (const uint8_t*)"__attribute__((", .len = sizeof("__attribute__((") - 1 });
String__Global__push_str(&(*__sc1160), utils__errors__cstr(((const char *)(&g.b[0]))));
String__Global__push_str(&(*__sc1160), (str){ .ptr = (const uint8_t*)")) ", .len = sizeof(")) ") - 1 });
});
  }
  codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1161 = (str){ (const uint8_t *)" {\n", sizeof(" {\n") - 1 }; str__ptr(&__sc1161); })));
  if (kind == ast__ast__NodeKind_NODE_ENUM) {
    codegen__codegen__Codegen__emit_enum_struct_body(self, declId);
  } else if (ag.is_tuple) {
    (self->depth = (self->depth + 1U));
    for (uint32_t j = 0U; j < ag.members.len; j++) {
      const uint32_t ftn = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.members)[((size_t)j)];
      codegen__codegen__Buf32 nm = (codegen__codegen__Buf32){0};
      snprintf(((char *)(&nm.b[0])), 16ULL, ((const char *)({ __auto_type __sc1162 = (str){ (const uint8_t *)"_%u", sizeof("_%u") - 1 }; str__ptr(&__sc1162); })), j);
      codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_type_node(self, ftn, ((const char *)(&nm.b[0])), ((char *)(&d.b[0])), 256ULL);
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&d.b[0])));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1163 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1163); })));
    }
    (self->depth = (self->depth - 1U));
  } else {
    (self->depth = (self->depth + 1U));
    for (uint32_t j = 0U; j < ag.members.len; j++) {
      const uint32_t fid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.members)[((size_t)j)];
      const ast__ast__FieldData fld = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fid)->as_data.field;
      codegen__codegen__Buf128 nm = (codegen__codegen__Buf128){0};
      const lexer__token__Span fnsp = codegen__codegen__Codegen__name_span(self, fld.name);
      codegen__codegen__Codegen__render_ident(self, fnsp, ((char *)(&nm.b[0])), 128ULL);
      codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_type_node(self, fld.ty, ((const char *)(&nm.b[0])), ((char *)(&d.b[0])), 256ULL);
      codegen__codegen__Codegen__emit_indent(self);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&d.b[0])));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1164 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1164); })));
    }
    (self->depth = (self->depth - 1U));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1165 = (str){ (const uint8_t *)"};\n", sizeof("};\n") - 1 }; str__ptr(&__sc1165); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_struct_inst(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, bool const with_body) {
  const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it->decl));
  codegen__codegen__Buf200 nm = (codegen__codegen__Buf200){0};
  codegen__codegen__Codegen__inst_name(self, it, ((char *)(&nm.b[0])), 200ULL);
  if (!with_body) {
    ({ String__Global *__sc1166 = &(self->buf);
String__Global__push_str(&(*__sc1166), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1166), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1166), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1166), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1166), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1166), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1166), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    return;
  }
  if (codegen__codegen__Codegen__inst_mentions_fnval(self, it) != self->fnval_pass) {
    return;
  }
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it->decl)->as_data.aggregate;
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.generics);
  (self->nsubst = 0);
  uint32_t i = 0U;
  while (((i < ag.generics.len) && (i < ((uint32_t)it->n))) && (self->nsubst < 16)) {
    (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = it->module, .node = gids[((size_t)i)] });
    (self->subst[((size_t)self->nsubst)].concrete = it->args[((size_t)i)]);
    (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    (i = (i + 1U));
  }
  ({ String__Global *__sc1167 = &(self->buf);
String__Global__push_str(&(*__sc1167), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1167), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1167), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1167), (str){ .ptr = (const uint8_t*)" {\n", .len = sizeof(" {\n") - 1 });
});
  (self->depth = (self->depth + 1U));
  for (uint32_t j = 0U; j < ag.members.len; j++) {
    const uint32_t fid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.members)[((size_t)j)];
    const ast__ast__FieldData fld = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fid)->as_data.field;
    codegen__codegen__Buf128 fnm = (codegen__codegen__Buf128){0};
    const lexer__token__Span fnsp = codegen__codegen__Codegen__name_span(self, fld.name);
    codegen__codegen__Codegen__render_ident(self, fnsp, ((char *)(&fnm.b[0])), 128ULL);
    codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_node(self, fld.ty, ((const char *)(&fnm.b[0])), ((char *)(&d.b[0])), 256ULL);
    codegen__codegen__Codegen__emit_indent(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&d.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1168 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1168); })));
  }
  (self->depth = (self->depth - 1U));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1169 = (str){ (const uint8_t *)"};\n", sizeof("};\n") - 1 }; str__ptr(&__sc1169); })));
  (self->nsubst = 0);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_enum_inst(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, bool const with_body) {
  codegen__codegen__Buf200 nm = (codegen__codegen__Buf200){0};
  codegen__codegen__Codegen__inst_name(self, it, ((char *)(&nm.b[0])), 200ULL);
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it->decl)->as_data.aggregate;
  if (!codegen__codegen__Codegen__aggregate_has_payload(self, it->decl)) {
    if (with_body) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1170 = (str){ (const uint8_t *)"typedef ", sizeof("typedef ") - 1 }; str__ptr(&__sc1170); })));
      codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
      ({ String__Global *__sc1171 = &(self->buf);
String__Global__push_str(&(*__sc1171), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1171), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1171), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    }
    return;
  }
  if (!with_body) {
    ({ String__Global *__sc1172 = &(self->buf);
String__Global__push_str(&(*__sc1172), (str){ .ptr = (const uint8_t*)"typedef struct ", .len = sizeof("typedef struct ") - 1 });
String__Global__push_str(&(*__sc1172), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1172), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1172), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1172), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    return;
  }
  if (codegen__codegen__Codegen__inst_mentions_fnval(self, it) != self->fnval_pass) {
    return;
  }
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.generics);
  (self->nsubst = 0);
  uint32_t i = 0U;
  while (((i < ag.generics.len) && (i < ((uint32_t)it->n))) && (self->nsubst < 16)) {
    (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = it->module, .node = gids[((size_t)i)] });
    (self->subst[((size_t)self->nsubst)].concrete = it->args[((size_t)i)]);
    (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    (i = (i + 1U));
  }
  ({ String__Global *__sc1173 = &(self->buf);
String__Global__push_str(&(*__sc1173), (str){ .ptr = (const uint8_t*)"struct ", .len = sizeof("struct ") - 1 });
String__Global__push_str(&(*__sc1173), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1173), (str){ .ptr = (const uint8_t*)" {\n", .len = sizeof(" {\n") - 1 });
});
  codegen__codegen__Codegen__emit_enum_struct_body(self, it->decl);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1174 = (str){ (const uint8_t *)"};\n", sizeof("};\n") - 1 }; str__ptr(&__sc1174); })));
  (self->nsubst = 0);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_enum_shared(codegen__codegen__Codegen *const self) {
  codegen__codegen__Ids64 seen = (codegen__codegen__Ids64){0};
  int32_t ns = 0;
  for (size_t i = 0ULL; i < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); i++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)));
    if (it.module != codegen__codegen__Codegen__cur_module(self)) {
      continue;
    }
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it.decl)->kind != ast__ast__NodeKind_NODE_ENUM) {
      continue;
    }
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      continue;
    }
    bool dup = false;
    for (int32_t s = 0; s < ns; s++) {
      if (seen.b[((size_t)s)] == it.decl) {
        (dup = true);
      }
    }
    if (dup) {
      continue;
    }
    if (ns < 64) {
      (seen.b[((size_t)ns)] = it.decl);
      (ns = ({ int32_t __sc_r; if (__builtin_add_overflow(ns, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
    if (codegen__codegen__Codegen__aggregate_has_payload(self, it.decl)) {
      codegen__codegen__Codegen__emit_enum_tag_decl(self, it.decl);
    } else {
      codegen__codegen__Codegen__emit_enum_full(self, it.decl);
    }
  }
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t ii = 0U; ii < items.len; ii++) {
    const uint32_t did = ids[((size_t)ii)];
    const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), did);
    if (((dn->kind != ast__ast__NodeKind_NODE_ENUM) || (dn->as_data.aggregate.generics.len == 0U)) || (!dn->as_data.aggregate.is_public)) {
      continue;
    }
    bool dup = false;
    for (int32_t s = 0; s < ns; s++) {
      if (seen.b[((size_t)s)] == did) {
        (dup = true);
      }
    }
    if (dup) {
      continue;
    }
    if (ns < 64) {
      (seen.b[((size_t)ns)] = did);
      (ns = ({ int32_t __sc_r; if (__builtin_add_overflow(ns, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
    if (codegen__codegen__Codegen__aggregate_has_payload(self, did)) {
      codegen__codegen__Codegen__emit_enum_tag_decl(self, did);
    } else {
      codegen__codegen__Codegen__emit_enum_full(self, did);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__push_home_dep(const codegen__codegen__Codegen *const self, uint32_t const st0, uint32_t *const deps, int32_t *const nh) {
  if (((*nh) >= 32) || (st0 == ast__ast__TYPE_NONE)) {
    return;
  }
  uint32_t st = st0;
  ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, st));
  while (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    (st = y.as_data.elem);
    (y = (*codegen__codegen__Codegen__type_at(self, st)));
  }
  if (((y.kind != ast__ast__TypeKind_TYPE_STRUCT) && (y.kind != ast__ast__TypeKind_TYPE_ENUM)) && (y.kind != ast__ast__TypeKind_TYPE_INSTANCE)) {
    return;
  }
  for (int32_t i = 0; i < (*nh); i++) {
    if (deps[((size_t)i)] == st) {
      return;
    }
  }
  const int32_t cur = (*nh);
  (deps[((size_t)cur)] = st);
  ((*nh) = ({ int32_t __sc_r; if (__builtin_add_overflow(cur, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_home_dep(codegen__codegen__Codegen *const self, uint32_t const st) {
  if (st == ast__ast__TYPE_NONE) {
    return;
  }
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, st));
  if ((((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) && (y.module == codegen__codegen__Codegen__cur_module(self))) && (self->type_state != NULL)) {
    if (codegen__codegen__Codegen__type_emittable(self, y.as_data.decl)) {
      uint8_t *const ts = self->type_state;
      codegen__codegen__Codegen__emit_type_dfs(self, y.as_data.decl, ts);
    }
  } else if ((y.kind == ast__ast__TypeKind_TYPE_INSTANCE) && (self->inst_emit_state != NULL)) {
    uint8_t *const ies = self->inst_emit_state;
    const size_t ien = self->inst_emit_n;
    codegen__codegen__Codegen__emit_inst_dfs(self, y.as_data.inst, ies, ien, true);
    codegen__codegen__Codegen__emit_rehomed_struct_dfs(self, y.as_data.inst, ies, ien, true);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_inst_dfs(codegen__codegen__Codegen *const self, uint32_t const idx, uint8_t *const state, size_t const nstate, bool const with_body) {
  if ((((size_t)idx) >= nstate) || (state[((size_t)idx)] != 0U)) {
    return;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), idx));
  bool concrete = true;
  for (uint8_t k = 0U; k < it.n; k++) {
    if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
      (concrete = false);
    }
  }
  if ((it.module != codegen__codegen__Codegen__cur_module(self)) || (!concrete)) {
    return;
  }
  (state[((size_t)idx)] = 1U);
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it.decl)->as_data.aggregate;
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it.decl)->kind;
  codegen__codegen__TyArgs32 deps = (codegen__codegen__TyArgs32){0};
  int32_t nh = 0;
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.generics);
  const int32_t saved = self->nsubst;
  (self->nsubst = 0);
  uint32_t g = 0U;
  while (((g < ag.generics.len) && (g < ((uint32_t)it.n))) && (self->nsubst < 16)) {
    (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = it.module, .node = gids[((size_t)g)] });
    (self->subst[((size_t)self->nsubst)].concrete = it.args[((size_t)g)]);
    (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    (g = (g + 1U));
  }
  const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.members);
  for (uint32_t m = 0U; m < ag.members.len; m++) {
    const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mids[((size_t)m)]);
    if ((dk == ast__ast__NodeKind_NODE_STRUCT) && (mn->kind == ast__ast__NodeKind_NODE_FIELD)) {
      const uint32_t ft = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), mn->as_data.field.ty));
      codegen__codegen__Codegen__push_home_dep(self, ft, ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
    } else if ((dk == ast__ast__NodeKind_NODE_ENUM) && (mn->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), mn->as_data.variant.payload);
      for (uint32_t kk = 0U; kk < mn->as_data.variant.payload.len; kk++) {
        const ast__ast__Node *const pf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pids[((size_t)kk)]);
        const uint32_t ptn = ({
          uint32_t __sc1175;
          if (pf->kind == ast__ast__NodeKind_NODE_FIELD) {
            __sc1175 = pf->as_data.field.ty;
          } else {
            __sc1175 = pids[((size_t)kk)];
          }
          __sc1175;
        });
        const uint32_t ft = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), ptn));
        codegen__codegen__Codegen__push_home_dep(self, ft, ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
      }
    }
  }
  (self->nsubst = saved);
  for (int32_t d = 0; d < nh; d++) {
    codegen__codegen__Codegen__emit_home_dep(self, deps.t[((size_t)d)]);
  }
  if (dk == ast__ast__NodeKind_NODE_STRUCT) {
    codegen__codegen__Codegen__emit_struct_inst(self, (&it), with_body);
  } else if (dk == ast__ast__NodeKind_NODE_ENUM) {
    codegen__codegen__Codegen__emit_enum_inst(self, (&it), with_body);
  }
  (state[((size_t)idx)] = 2U);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_type_dfs(codegen__codegen__Codegen *const self, uint32_t const declId, uint8_t *const state) {
  if (state[((size_t)declId)] != 0U) {
    return;
  }
  (state[((size_t)declId)] = 1U);
  const ast__ast__NodeKind n_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->kind;
  const ast__ast__NodeList members = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.members;
  const bool is_tuple = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.is_tuple;
  codegen__codegen__TyArgs32 deps = (codegen__codegen__TyArgs32){0};
  int32_t nh = 0;
  const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), members);
  for (uint32_t i = 0U; i < members.len; i++) {
    const ast__ast__Node *const m = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mids[((size_t)i)]);
    if ((n_kind == ast__ast__NodeKind_NODE_STRUCT) && is_tuple) {
      codegen__codegen__Codegen__push_home_dep(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), mids[((size_t)i)]), ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
    } else if ((n_kind == ast__ast__NodeKind_NODE_STRUCT) && (m->kind == ast__ast__NodeKind_NODE_FIELD)) {
      codegen__codegen__Codegen__push_home_dep(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), m->as_data.field.ty), ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
    } else if ((n_kind == ast__ast__NodeKind_NODE_ENUM) && (m->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      const uint32_t *const plids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), m->as_data.variant.payload);
      for (uint32_t kk = 0U; kk < m->as_data.variant.payload.len; kk++) {
        const ast__ast__Node *const pf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), plids[((size_t)kk)]);
        const uint32_t ptn = ({
          uint32_t __sc1176;
          if (pf->kind == ast__ast__NodeKind_NODE_FIELD) {
            __sc1176 = pf->as_data.field.ty;
          } else {
            __sc1176 = plids[((size_t)kk)];
          }
          __sc1176;
        });
        codegen__codegen__Codegen__push_home_dep(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), ptn), ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
      }
    }
  }
  for (int32_t d = 0; d < nh; d++) {
    codegen__codegen__Codegen__emit_home_dep(self, deps.t[((size_t)d)]);
  }
  codegen__codegen__Codegen__emit_type_decl(self, declId);
  (state[((size_t)declId)] = 2U);
}

static __attribute__((unused)) uint8_t *codegen__codegen__Codegen__cg_type_state(codegen__codegen__Codegen *const self) {
  if (self->type_state == NULL) {
    (self->type_state = ((uint8_t *)calloc(Vector__ast__ast__Node__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).nodes), 1ULL)));
  }
  return self->type_state;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_agg_spec_fallback(codegen__codegen__Codegen *const self, bool const with_body) {
  for (size_t i = 0ULL; i < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); i++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)));
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if ((it.module != codegen__codegen__Codegen__cur_module(self)) || (!concrete)) {
      continue;
    }
    const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it.decl)->kind;
    if (dk == ast__ast__NodeKind_NODE_STRUCT) {
      codegen__codegen__Codegen__emit_struct_inst(self, (&it), with_body);
    } else if (dk == ast__ast__NodeKind_NODE_ENUM) {
      codegen__codegen__Codegen__emit_enum_inst(self, (&it), with_body);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_aggregate_specializations(codegen__codegen__Codegen *const self, bool const with_body) {
  if (!with_body) {
    codegen__codegen__Codegen__emit_generic_enum_shared(self);
  }
  const size_t n = Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances);
  if (with_body) {
    uint8_t *const state = self->inst_emit_state;
    const size_t nstate = self->inst_emit_n;
    if (state == NULL) {
      codegen__codegen__Codegen__emit_agg_spec_fallback(self, with_body);
      return;
    }
    size_t i = 0ULL;
    while ((i < n) && (i < nstate)) {
      codegen__codegen__Codegen__emit_inst_dfs(self, ((uint32_t)i), state, nstate, with_body);
      (i = (i + 1ULL));
    }
  } else {
    const size_t cnt = ({
      size_t __sc1177;
      if (n != 0ULL) {
        __sc1177 = n;
      } else {
        __sc1177 = 1ULL;
      }
      __sc1177;
    });
    uint8_t *const state = ((uint8_t *)calloc(cnt, 1ULL));
    if (state == NULL) {
      codegen__codegen__Codegen__emit_agg_spec_fallback(self, with_body);
      return;
    }
    for (size_t i = 0ULL; i < n; i++) {
      codegen__codegen__Codegen__emit_inst_dfs(self, ((uint32_t)i), state, n, with_body);
    }
    free(((void *)state));
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__inst_rehomed_here(const codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it) {
  if ((self->package == NULL) || (it->module == codegen__codegen__Codegen__cur_module(self))) {
    return false;
  }
  for (uint8_t k = 0U; k < it->n; k++) {
    if (!codegen__codegen__Codegen__type_is_concrete(self, it->args[((size_t)k)])) {
      return false;
    }
  }
  return (module__loader__Package__instance_home(&((*self->package)), (&(*codegen__codegen__Codegen__cur_ast(self))), it) == codegen__codegen__Codegen__cur_module(self));
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__rehome_subst_type(codegen__codegen__Codegen *const self, uint16_t const owner_mod, const ast__ast__TyInstance *const it, uint32_t const t) {
  if (t == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Ty ty = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), t));
  if (ty.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), it->decl)->as_data.aggregate.generics;
    const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), gens);
    uint32_t i = 0U;
    while ((i < gens.len) && (i < ((uint32_t)it->n))) {
      if ((ty.module == it->module) && (ty.as_data.decl == gids[((size_t)i)])) {
        return it->args[((size_t)i)];
      }
      (i = (i + 1U));
    }
    return ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, owner_mod))), t);
  }
  if ((((ty.kind == ast__ast__TypeKind_TYPE_POINTER) || (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (ty.kind == ast__ast__TypeKind_TYPE_SLICE)) || (ty.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    const uint32_t e = codegen__codegen__Codegen__rehome_subst_type(self, owner_mod, it, ty.as_data.elem);
    ast__ast__Ty nt = ty;
    (nt.as_data.elem = e);
    return ast__ast__Ast__intern_type(&((*codegen__codegen__Codegen__cur_ast(self))), nt);
  }
  if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance inst = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), ty.as_data.inst));
    codegen__codegen__TyArgs4 na = (codegen__codegen__TyArgs4){0};
    const uint8_t nn = ({
      uint8_t __sc1178;
      if (inst.n < 4U) {
        __sc1178 = inst.n;
      } else {
        __sc1178 = 4U;
      }
      __sc1178;
    });
    for (uint8_t i = 0U; i < nn; i++) {
      (na.t[((size_t)i)] = codegen__codegen__Codegen__rehome_subst_type(self, owner_mod, it, inst.args[((size_t)i)]));
    }
    return ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), inst.module, inst.decl, ((const uint32_t *)(&na.t[0])), nn);
  }
  return ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, owner_mod))), t);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_struct(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, bool const with_body) {
  ast__ast__Ast *const home = codegen__codegen__Codegen__cur_ast(self);
  const uint8_t *const hsrc = self->source;
  const size_t hlen = self->len;
  ast__ast__Ast *const owner = codegen__codegen__Codegen__mod_ast(self, it->module);
  const uint8_t *const osrc = codegen__codegen__Codegen__mod_src(self, it->module);
  const size_t oninst = Vector__ast__ast__TyInstance__Global__len(&(*owner).instances);
  ast__ast__TyInstance oit = (*it);
  for (uint8_t k = 0U; k < it->n; k++) {
    (oit.args[((size_t)k)] = ast__ast__Ast__reintern(&((*owner)), (&(*home)), it->args[((size_t)k)]));
  }
  (self->source = osrc);
  (self->len = String__Global__len(&(*({ __auto_type __sc1179 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1179, ((size_t)it->module)); })).source));
  (self->borrowed = true);
  (self->ast = codegen__codegen__Codegen__mod_ast(self, it->module));
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), oit.decl)->kind;
  if (dk == ast__ast__NodeKind_NODE_STRUCT) {
    codegen__codegen__Codegen__emit_struct_inst(self, (&oit), with_body);
  } else if (dk == ast__ast__NodeKind_NODE_ENUM) {
    codegen__codegen__Codegen__emit_enum_inst(self, (&oit), with_body);
  }
  Vector__ast__ast__TyInstance__Global__truncate(&(*codegen__codegen__Codegen__cur_ast(self)).instances, oninst);
  (self->borrowed = false);
  (self->ast = home);
  (self->source = hsrc);
  (self->len = hlen);
  (self->nsubst = 0);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_struct_dfs(codegen__codegen__Codegen *const self, uint32_t const idx, uint8_t *const state, size_t const nstate, bool const with_body) {
  if ((((size_t)idx) >= nstate) || (state[((size_t)idx)] != 0U)) {
    return;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), idx));
  if (!codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
    (state[((size_t)idx)] = 2U);
    return;
  }
  (state[((size_t)idx)] = 1U);
  const uint16_t owner_mod = it.module;
  const ast__ast__NodeKind dn_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), it.decl)->kind;
  const ast__ast__NodeList members = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), it.decl)->as_data.aggregate.members;
  codegen__codegen__TyArgs32 deps = (codegen__codegen__TyArgs32){0};
  int32_t nh = 0;
  const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), members);
  for (uint32_t m = 0U; m < members.len; m++) {
    const uint32_t mid = mids[((size_t)m)];
    const ast__ast__NodeKind mnk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), mid)->kind;
    if ((dn_kind == ast__ast__NodeKind_NODE_STRUCT) && (mnk == ast__ast__NodeKind_NODE_FIELD)) {
      const uint32_t fty = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), mid)->as_data.field.ty;
      const uint32_t fnode_ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), fty);
      const uint32_t ft = codegen__codegen__Codegen__rehome_subst_type(self, owner_mod, (&it), fnode_ty);
      codegen__codegen__Codegen__push_home_dep(self, ft, ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
    } else if ((dn_kind == ast__ast__NodeKind_NODE_ENUM) && (mnk == ast__ast__NodeKind_NODE_VARIANT)) {
      const ast__ast__NodeList payload = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), mid)->as_data.variant.payload;
      const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), payload);
      for (uint32_t kk = 0U; kk < payload.len; kk++) {
        const uint32_t pid = pids[((size_t)kk)];
        const ast__ast__NodeKind pfk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), pid)->kind;
        const uint32_t tn = ({
          uint32_t __sc1180;
          if (pfk == ast__ast__NodeKind_NODE_FIELD) {
            __sc1180 = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), pid)->as_data.field.ty;
          } else {
            __sc1180 = pid;
          }
          __sc1180;
        });
        const uint32_t fnode_ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, owner_mod))), tn);
        const uint32_t ft = codegen__codegen__Codegen__rehome_subst_type(self, owner_mod, (&it), fnode_ty);
        codegen__codegen__Codegen__push_home_dep(self, ft, ((uint32_t *)(&deps.t[0])), ((int32_t *)(&nh)));
      }
    }
  }
  for (int32_t d = 0; d < nh; d++) {
    codegen__codegen__Codegen__emit_home_dep(self, deps.t[((size_t)d)]);
  }
  codegen__codegen__Codegen__emit_rehomed_struct(self, (&it), with_body);
  (state[((size_t)idx)] = 2U);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_structs(codegen__codegen__Codegen *const self, bool const with_body) {
  if (self->package == NULL) {
    return;
  }
  const size_t n = Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances);
  if (with_body) {
    uint8_t *const state = self->inst_emit_state;
    const size_t nstate = self->inst_emit_n;
    if (state == NULL) {
      for (size_t ii = 0ULL; ii < n; ii++) {
        const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
        if (codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
          codegen__codegen__Codegen__emit_rehomed_struct(self, (&it), with_body);
        }
      }
      return;
    }
    size_t ii = 0ULL;
    while ((ii < n) && (ii < nstate)) {
      codegen__codegen__Codegen__emit_rehomed_struct_dfs(self, ((uint32_t)ii), state, nstate, with_body);
      (ii = (ii + 1ULL));
    }
  } else {
    const size_t cnt = ({
      size_t __sc1181;
      if (n != 0ULL) {
        __sc1181 = n;
      } else {
        __sc1181 = 1ULL;
      }
      __sc1181;
    });
    uint8_t *const state = ((uint8_t *)calloc(cnt, 1ULL));
    if (state == NULL) {
      for (size_t ii = 0ULL; ii < n; ii++) {
        const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
        if (codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
          codegen__codegen__Codegen__emit_rehomed_struct(self, (&it), with_body);
        }
      }
      return;
    }
    for (size_t ii = 0ULL; ii < n; ii++) {
      codegen__codegen__Codegen__emit_rehomed_struct_dfs(self, ((uint32_t)ii), state, n, with_body);
    }
    free(((void *)state));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_forwards(codegen__codegen__Codegen *const self) {
  if (self->package == NULL) {
    return;
  }
  for (size_t i = 0ULL; i < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); i++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)));
    if (!codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
      continue;
    }
    const ast__ast__NodeKind dn_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), it.decl)->kind;
    codegen__codegen__Buf200 inm = (codegen__codegen__Buf200){0};
    codegen__codegen__Codegen__inst_name(self, (&it), ((char *)(&inm.b[0])), 200ULL);
    if ((dn_kind == ast__ast__NodeKind_NODE_STRUCT) || codegen__codegen__Codegen__aggregate_has_payload_in(self, it.module, it.decl)) {
      const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), it.decl));
      ({ String__Global *__sc1182 = &(self->buf);
String__Global__push_str(&(*__sc1182), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1182), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1182), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1182), utils__errors__cstr(((const char *)(&inm.b[0]))));
String__Global__push_str(&(*__sc1182), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1182), utils__errors__cstr(((const char *)(&inm.b[0]))));
String__Global__push_str(&(*__sc1182), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    } else {
      const uint32_t anm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), it.decl)->as_data.aggregate.name;
      codegen__codegen__Buf160 en = (codegen__codegen__Buf160){0};
      codegen__codegen__Codegen__render_qualified(self, it.module, anm, ((char *)(&en.b[0])), 160ULL);
      ({ String__Global *__sc1183 = &(self->buf);
String__Global__push_str(&(*__sc1183), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1183), utils__errors__cstr(((const char *)(&en.b[0]))));
String__Global__push_str(&(*__sc1183), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1183), utils__errors__cstr(((const char *)(&inm.b[0]))));
String__Global__push_str(&(*__sc1183), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_fnval_instance_structs(codegen__codegen__Codegen *const self) {
  const size_t n = Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances);
  const size_t cnt = ({
    size_t __sc1184;
    if (n != 0ULL) {
      __sc1184 = n;
    } else {
      __sc1184 = 1ULL;
    }
    __sc1184;
  });
  uint8_t *const state = ((uint8_t *)calloc(cnt, 1ULL));
  (self->fnval_pass = true);
  if (state != NULL) {
    (self->inst_emit_state = state);
    (self->inst_emit_n = n);
    for (size_t i = 0ULL; i < n; i++) {
      codegen__codegen__Codegen__emit_inst_dfs(self, ((uint32_t)i), state, n, true);
      codegen__codegen__Codegen__emit_rehomed_struct_dfs(self, ((uint32_t)i), state, n, true);
    }
    (self->inst_emit_state = NULL);
    (self->inst_emit_n = 0ULL);
    free(((void *)state));
  } else {
    for (size_t i = 0ULL; i < n; i++) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)));
      bool concrete = true;
      for (uint8_t k = 0U; k < it.n; k++) {
        if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
          (concrete = false);
        }
      }
      if (!concrete) {
        continue;
      }
      if (it.module == codegen__codegen__Codegen__cur_module(self)) {
        const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it.decl)->kind;
        if (dk == ast__ast__NodeKind_NODE_STRUCT) {
          codegen__codegen__Codegen__emit_struct_inst(self, (&it), true);
        } else if (dk == ast__ast__NodeKind_NODE_ENUM) {
          codegen__codegen__Codegen__emit_enum_inst(self, (&it), true);
        }
      } else if (codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
        codegen__codegen__Codegen__emit_rehomed_struct(self, (&it), true);
      }
    }
  }
  (self->fnval_pass = false);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_macros(codegen__codegen__Codegen *const self) {
  if (self->package == NULL) {
    return;
  }
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    const uint32_t ng = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.aggregate.generics.len;
    if (((nk != ast__ast__NodeKind_NODE_STRUCT) && (nk != ast__ast__NodeKind_NODE_ENUM)) || (ng == 0U)) {
      continue;
    }
    if (codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), nid, ast__ast__AttrKind_ATTR_EMIT_MACRO) == NULL) {
      continue;
    }
    if (nk == ast__ast__NodeKind_NODE_ENUM) {
      if (codegen__codegen__Codegen__aggregate_has_payload(self, nid)) {
        codegen__codegen__Codegen__emit_enum_tag_decl(self, nid);
      } else {
        codegen__codegen__Codegen__emit_enum_full(self, nid);
      }
    }
    codegen__codegen__Codegen__emit_generic_macro(self, nid, false);
    codegen__codegen__Codegen__emit_generic_macro(self, nid, true);
    codegen__codegen__Codegen__emit_generic_method_macros(self, nid);
    codegen__codegen__Codegen__emit_generic_conformance_macros(self, nid);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_inst_methods(codegen__codegen__Codegen *const self, const ast__ast__TyInstance *const it, ast__ast__Ast *const mi_src, uint32_t const mi_inst, int32_t const which, bool const with_body) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const iids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  codegen__codegen__Buf200 inm = (codegen__codegen__Buf200){0};
  codegen__codegen__Codegen__inst_name(self, it, ((char *)(&inm.b[0])), 200ULL);
  const bool ifnv = codegen__codegen__Codegen__inst_mentions_fnval(self, it);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = iids[((size_t)i)];
    const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if ((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.generics.len == 0U)) {
      continue;
    }
    if (ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type) != it->decl) {
      continue;
    }
    const ast__ast__DefId itrait = codegen__codegen__Codegen__extend_interface(self, nid);
    if (itrait.node != ast__ast__NODE_NONE) {
      const uint32_t itty = ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), it->module, it->decl, ((const uint32_t *)(&it->args[0])), it->n);
      if (!codegen__codegen__Codegen__cg_type_satisfies(self, itty, itrait, 0)) {
        continue;
      }
    }
    if (!codegen__codegen__Codegen__cg_extend_bounds_hold(self, nid, ((const uint32_t *)(&it->args[0])), it->n)) {
      continue;
    }
    const ast__ast__NodeList gens = ed.generics;
    const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
    const ast__ast__NodeList ms = ed.items;
    const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms);
    for (uint32_t j = 0U; j < ms.len; j++) {
      const uint32_t mid = mids[((size_t)j)];
      const ast__ast__FunctionData mf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.function;
      const ast__ast__NodeKind mk_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
      if (mk_kind != ast__ast__NodeKind_NODE_FUNCTION) {
        continue;
      }
      bool skip = false;
      if (with_body) {
        (skip = (mf.body == ast__ast__NODE_NONE));
      } else {
        (skip = ((mf.generics.len == 0U) && (!codegen__codegen__want_fn(which, ((!ifnv) && mf.is_public)))));
      }
      if (skip) {
        continue;
      }
      (self->nsubst = 0);
      uint32_t g = 0U;
      while (((g < gens.len) && (g < ((uint32_t)it->n))) && (self->nsubst < 16)) {
        (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = codegen__codegen__Codegen__cur_module(self), .node = gids[((size_t)g)] });
        (self->subst[((size_t)self->nsubst)].concrete = it->args[((size_t)g)]);
        (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (g = (g + 1U));
      }
      codegen__codegen__Buf320 nm = (codegen__codegen__Buf320){0};
      size_t at = codegen__codegen__bappend(((char *)(&nm.b[0])), 320ULL, 0ULL, ((const char *)(&inm.b[0])));
      (at = codegen__codegen__bappend(((char *)(&nm.b[0])), 320ULL, at, ((const char *)({ __auto_type __sc1185 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1185); }))));
      const lexer__token__Span mnsp = codegen__codegen__Codegen__name_span(self, mf.name);
      codegen__codegen__Codegen__render_ident(self, mnsp, ((char *)(((char *)(&nm.b[0])) + at)), (320ULL - at));
      const bool stat = (self->multifile && (ifnv || (!mf.is_public)));
      if (self->minst_only && (mf.generics.len == 0U)) {
        (self->nsubst = 0);
        continue;
      }
      if (mf.generics.len == 0U) {
        const ast__ast__DefId mdef = (ast__ast__DefId){ .module = codegen__codegen__Codegen__cur_module(self), .node = mid };
        if (((self->multifile && (itrait.node == ast__ast__NODE_NONE)) && (codegen__codegen__Codegen__cg_attr(self, codegen__codegen__Codegen__cur_module(self), it->decl, ast__ast__AttrKind_ATTR_EMIT_MACRO) == NULL)) && (!module__loader__Package__method_used_get(&((*self->package)), mdef))) {
          (self->nsubst = 0);
          continue;
        }
        if (!with_body) {
          codegen__codegen__Codegen__emit_ret_struct_named(self, mid, ((const char *)(&nm.b[0])));
        }
        codegen__codegen__Codegen__emit_function(self, mid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, with_body, ((const char *)(&nm.b[0])), stat);
        (self->nsubst = 0);
        continue;
      }
      const int32_t nimpl = self->nsubst;
      const ast__ast__NodeList mg = mf.generics;
      const uint32_t *const mgids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), mg);
      for (size_t mk = 0ULL; mk < Vector__ast__ast__MethodInst__Global__len(&(*mi_src).method_insts); mk++) {
        const ast__ast__MethodInst minst = (*({ __auto_type __sc1186 = &(*mi_src).method_insts; Vector__ast__ast__MethodInst__Global__index(__sc1186, mk); }));
        if ((minst.method != mid) || (minst.instance != mi_inst)) {
          continue;
        }
        (self->nsubst = nimpl);
        bool fnval = ifnv;
        uint32_t mgi = 0U;
        while (((mgi < mg.len) && (mgi < ((uint32_t)minst.n))) && (self->nsubst < 16)) {
          const uint32_t ta = ({
            uint32_t __sc1187;
            if (mi_src == codegen__codegen__Codegen__cur_ast(self)) {
              __sc1187 = minst.targs[((size_t)mgi)];
            } else {
              __sc1187 = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*mi_src)), minst.targs[((size_t)mgi)]);
            }
            __sc1187;
          });
          (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = codegen__codegen__Codegen__cur_module(self), .node = mgids[((size_t)mgi)] });
          (self->subst[((size_t)self->nsubst)].concrete = ta);
          if (codegen__codegen__Codegen__cg_type_mentions_fnval(self, ta)) {
            (fnval = true);
          }
          (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
          (mgi = (mgi + 1U));
        }
        bool wf = false;
        if (fnval) {
          (wf = (which != codegen__codegen__PROTO_PUBLIC));
        } else {
          (wf = codegen__codegen__want_fn(which, mf.is_public));
        }
        if ((!with_body) && (!wf)) {
          continue;
        }
        codegen__codegen__Buf400 snm = (codegen__codegen__Buf400){0};
        size_t a2 = codegen__codegen__bappend(((char *)(&snm.b[0])), 400ULL, 0ULL, ((const char *)(&nm.b[0])));
        for (uint8_t gg = 0U; gg < minst.n; gg++) {
          (a2 = codegen__codegen__bappend(((char *)(&snm.b[0])), 400ULL, a2, ((const char *)({ __auto_type __sc1188 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1188); }))));
          const uint32_t tg = ({
            uint32_t __sc1189;
            if (mi_src == codegen__codegen__Codegen__cur_ast(self)) {
              __sc1189 = minst.targs[((size_t)gg)];
            } else {
              __sc1189 = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*mi_src)), minst.targs[((size_t)gg)]);
            }
            __sc1189;
          });
          codegen__codegen__Buf176 e = (codegen__codegen__Buf176){0};
          codegen__codegen__Codegen__mangle_type(self, tg, ((char *)(&e.b[0])), 176ULL);
          (a2 = codegen__codegen__bappend(((char *)(&snm.b[0])), 400ULL, a2, ((const char *)(&e.b[0]))));
        }
        if (!with_body) {
          codegen__codegen__Codegen__emit_ret_struct_named(self, mid, ((const char *)(&snm.b[0])));
        }
        codegen__codegen__Codegen__emit_function(self, mid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, with_body, ((const char *)(&snm.b[0])), (stat || fnval));
      }
      (self->nsubst = 0);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_method_specializations(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body) {
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
    if (it.module != codegen__codegen__Codegen__cur_module(self)) {
      continue;
    }
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      continue;
    }
    const uint32_t itTy = ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), it.module, it.decl, ((const uint32_t *)(&it.args[0])), it.n);
    ast__ast__Ast *const src = codegen__codegen__Codegen__cur_ast(self);
    codegen__codegen__Codegen__emit_inst_methods(self, (&it), src, itTy, which, with_body);
    (self->nsubst = 0);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_rehomed_methods(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body) {
  if (self->package == NULL) {
    return;
  }
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    ast__ast__Ast *const home = codegen__codegen__Codegen__cur_ast(self);
    const uint16_t home_mod = (*home).module;
    const uint8_t *const hsrc = self->source;
    const size_t hlen = self->len;
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*home)), ((uint32_t)ii)));
    if (!codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
      continue;
    }
    const uint32_t itTy = ast__ast__Ast__intern_instance(&((*home)), it.module, it.decl, ((const uint32_t *)(&it.args[0])), it.n);
    ast__ast__Ast *const owner = codegen__codegen__Codegen__mod_ast(self, it.module);
    const uint8_t *const osrc = codegen__codegen__Codegen__mod_src(self, it.module);
    const size_t oninst = Vector__ast__ast__TyInstance__Global__len(&(*owner).instances);
    ast__ast__TyInstance oit = it;
    for (uint8_t k = 0U; k < it.n; k++) {
      (oit.args[((size_t)k)] = ast__ast__Ast__reintern(&((*owner)), (&(*home)), it.args[((size_t)k)]));
    }
    (self->source = osrc);
    (self->len = String__Global__len(&(*({ __auto_type __sc1190 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1190, ((size_t)it.module)); })).source));
    (self->borrowed = true);
    (self->ast = codegen__codegen__Codegen__mod_ast(self, it.module));
    codegen__codegen__Codegen__emit_inst_methods(self, (&oit), codegen__codegen__Codegen__mod_ast(self, home_mod), itTy, which, with_body);
    Vector__ast__ast__TyInstance__Global__truncate(&(*codegen__codegen__Codegen__cur_ast(self)).instances, oninst);
    (self->borrowed = false);
    (self->ast = home);
    (self->source = hsrc);
    (self->len = hlen);
    (self->nsubst = 0);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_local_method_insts(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body) {
  if ((self->package == NULL) || ((!with_body) && (which == codegen__codegen__PROTO_PUBLIC))) {
    return;
  }
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    ast__ast__Ast *const home = codegen__codegen__Codegen__cur_ast(self);
    const uint16_t home_mod = (*home).module;
    const uint8_t *const hsrc = self->source;
    const size_t hlen = self->len;
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*home)), ((uint32_t)ii)));
    if (((it.module == home_mod) || (((size_t)it.module) >= codegen__codegen__Codegen__pkg_count(self))) || codegen__codegen__Codegen__inst_rehomed_here(self, (&it))) {
      continue;
    }
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      continue;
    }
    const uint32_t itTy = ast__ast__Ast__intern_instance(&((*home)), it.module, it.decl, ((const uint32_t *)(&it.args[0])), it.n);
    bool any = false;
    size_t mk = 0ULL;
    while ((mk < Vector__ast__ast__MethodInst__Global__len(&(*home).method_insts)) && (!any)) {
      if ((*({ __auto_type __sc1191 = &(*home).method_insts; Vector__ast__ast__MethodInst__Global__index(__sc1191, mk); })).instance == itTy) {
        (any = true);
      }
      (mk = (mk + 1ULL));
    }
    if (!any) {
      continue;
    }
    ast__ast__Ast *const owner = codegen__codegen__Codegen__mod_ast(self, it.module);
    const uint8_t *const osrc = codegen__codegen__Codegen__mod_src(self, it.module);
    const size_t oninst = Vector__ast__ast__TyInstance__Global__len(&(*owner).instances);
    ast__ast__TyInstance oit = it;
    for (uint8_t k2 = 0U; k2 < it.n; k2++) {
      (oit.args[((size_t)k2)] = ast__ast__Ast__reintern(&((*owner)), (&(*home)), it.args[((size_t)k2)]));
    }
    (self->source = osrc);
    (self->len = String__Global__len(&(*({ __auto_type __sc1192 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1192, ((size_t)it.module)); })).source));
    (self->borrowed = true);
    (self->minst_only = true);
    (self->ast = codegen__codegen__Codegen__mod_ast(self, it.module));
    codegen__codegen__Codegen__emit_inst_methods(self, (&oit), codegen__codegen__Codegen__mod_ast(self, home_mod), itTy, which, with_body);
    (self->minst_only = false);
    Vector__ast__ast__TyInstance__Global__truncate(&(*codegen__codegen__Codegen__cur_ast(self)).instances, oninst);
    (self->borrowed = false);
    (self->ast = home);
    (self->source = hsrc);
    (self->len = hlen);
    (self->nsubst = 0);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_specializations(codegen__codegen__Codegen *const self, bool const with_body) {
  for (int32_t i = 0; i < self->ninsts; i++) {
    const codegen__codegen__CgInst inst = self->insts[((size_t)i)];
    const ast__ast__DefId fn2 = inst.func;
    bool concrete = true;
    for (uint8_t k = 0U; k < inst.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, inst.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      continue;
    }
    if (fn2.module == codegen__codegen__Codegen__cur_module(self)) {
      const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn2.node)->as_data.function.generics;
      const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
      (self->nsubst = 0);
      uint32_t g = 0U;
      while (((g < gens.len) && (g < ((uint32_t)inst.n))) && (self->nsubst < 16)) {
        (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = fn2.module, .node = gids[((size_t)g)] });
        (self->subst[((size_t)self->nsubst)].concrete = inst.args[((size_t)g)]);
        (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (g = (g + 1U));
      }
      codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__spec_name(self, fn2, ((const uint32_t *)(&inst.args[0])), ((int32_t)inst.n), ((char *)(&nm.b[0])), 256ULL);
      if (!with_body) {
        codegen__codegen__Codegen__emit_ret_struct_named(self, fn2.node, ((const char *)(&nm.b[0])));
      }
      codegen__codegen__Codegen__emit_function(self, fn2.node, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, with_body, ((const char *)(&nm.b[0])), true);
      (self->nsubst = 0);
      continue;
    }
    if ((self->package == NULL) || (((size_t)fn2.module) >= codegen__codegen__Codegen__pkg_count(self))) {
      continue;
    }
    ast__ast__Ast *const home = codegen__codegen__Codegen__cur_ast(self);
    const uint8_t *const hsrc = self->source;
    const size_t hlen = self->len;
    ast__ast__Ast *const owner = codegen__codegen__Codegen__mod_ast(self, fn2.module);
    const uint8_t *const osrc = codegen__codegen__Codegen__mod_src(self, fn2.module);
    const size_t oninst = Vector__ast__ast__TyInstance__Global__len(&(*owner).instances);
    codegen__codegen__TyArgs4 oargs = (codegen__codegen__TyArgs4){0};
    for (uint8_t k2 = 0U; k2 < inst.n; k2++) {
      (oargs.t[((size_t)k2)] = ast__ast__Ast__reintern(&((*owner)), (&(*home)), inst.args[((size_t)k2)]));
    }
    (self->ast = owner);
    (self->source = osrc);
    (self->len = String__Global__len(&(*({ __auto_type __sc1193 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1193, ((size_t)fn2.module)); })).source));
    (self->borrowed = true);
    const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn2.node)->as_data.function.generics;
    const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
    (self->nsubst = 0);
    uint32_t g = 0U;
    while (((g < gens.len) && (g < ((uint32_t)inst.n))) && (self->nsubst < 16)) {
      (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = fn2.module, .node = gids[((size_t)g)] });
      (self->subst[((size_t)self->nsubst)].concrete = oargs.t[((size_t)g)]);
      (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      (g = (g + 1U));
    }
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__spec_name(self, fn2, ((const uint32_t *)(&oargs.t[0])), ((int32_t)inst.n), ((char *)(&nm.b[0])), 256ULL);
    if (!with_body) {
      codegen__codegen__Codegen__emit_ret_struct_named(self, fn2.node, ((const char *)(&nm.b[0])));
    }
    codegen__codegen__Codegen__emit_function(self, fn2.node, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, with_body, ((const char *)(&nm.b[0])), true);
    (self->nsubst = 0);
    Vector__ast__ast__TyInstance__Global__truncate(&(*codegen__codegen__Codegen__cur_ast(self)).instances, oninst);
    (self->borrowed = false);
    (self->ast = home);
    (self->source = hsrc);
    (self->len = hlen);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_default_methods(codegen__codegen__Codegen *const self, int32_t const which, bool const with_body) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if ((((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.interface_type == ast__ast__NODE_NONE)) || (ed.target_type == ast__ast__NODE_NONE)) || (ed.generics.len != 0U)) {
      continue;
    }
    const ast__ast__DefId iface = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ed.interface_type);
    const ast__ast__DefId target = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type);
    if ((iface.node == ast__ast__NODE_NONE) || (target.node == ast__ast__NODE_NONE)) {
      continue;
    }
    const bool foreign = (iface.module != codegen__codegen__Codegen__cur_module(self));
    if (foreign && ((self->package == NULL) || (((size_t)iface.module) >= codegen__codegen__Codegen__pkg_count(self)))) {
      continue;
    }
    int32_t bb = -1;
    if (self->package != NULL) {
      (bb = module__loader__Package__builtin_of_decl(&((*self->package)), target.module, target.node));
    }
    const bool tkind_is_enum = (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, target.module))), target.node)->kind == ast__ast__NodeKind_NODE_ENUM);
    ast__ast__Ast *const ia = codegen__codegen__Codegen__mod_ast(self, iface.module);
    ast__ast__Ty tyv = (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_STRUCT, .module = target.module, .as_data = (ast__ast__TyAs){ .decl = target.node } };
    if (bb >= 0) {
      (tyv = (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_BUILTIN, .as_data = (ast__ast__TyAs){ .builtin = ((ast__ast__BuiltinType)bb) } });
    } else if (tkind_is_enum) {
      (tyv = (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_ENUM, .module = target.module, .as_data = (ast__ast__TyAs){ .decl = target.node } });
    }
    const uint32_t tty = ast__ast__Ast__intern_type(&((*ia)), tyv);
    const ast__ast__NodeList req = ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def.items;
    const uint32_t *const rids = ast__ast__Ast__list(&((*ia)), req);
    const ast__ast__NodeList have = ed.items;
    const uint32_t *const hids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), have);
    const bool vis = (ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def.is_public && (target.module == codegen__codegen__Codegen__cur_module(self)));
    for (uint32_t r = 0U; r < req.len; r++) {
      const uint32_t rid = rids[((size_t)r)];
      const ast__ast__Node *const rm = ast__ast__Ast__at_const(&((*ia)), rid);
      if (((rm->kind != ast__ast__NodeKind_NODE_FUNCTION) || (rm->as_data.function.body == ast__ast__NODE_NONE)) || (rm->as_data.function.generics.len != 0U)) {
        continue;
      }
      if ((!with_body) && (!codegen__codegen__want_fn(which, vis))) {
        continue;
      }
      const lexer__token__Span rmn = ast__ast__Ast__at_const(&((*ia)), rm->as_data.function.name)->as_data.name.text;
      bool overridden = false;
      uint32_t h = 0U;
      while ((h < have.len) && (!overridden)) {
        const ast__ast__Node *const hm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), hids[((size_t)h)]);
        if (hm->kind == ast__ast__NodeKind_NODE_FUNCTION) {
          const lexer__token__Span hmn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), hm->as_data.function.name)->as_data.name.text;
          if (codegen__codegen__cg_span_eq(self->source, hmn, codegen__codegen__Codegen__mod_src(self, iface.module), rmn)) {
            (overridden = true);
          }
        }
        (h = (h + 1U));
      }
      if (overridden) {
        continue;
      }
      ast__ast__Ast *const home = codegen__codegen__Codegen__cur_ast(self);
      const uint8_t *const hsrc = self->source;
      const size_t hlen = self->len;
      size_t oninst = 0ULL;
      if (foreign) {
        (self->source = codegen__codegen__Codegen__mod_src(self, iface.module));
        (self->len = String__Global__len(&(*({ __auto_type __sc1194 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1194, ((size_t)iface.module)); })).source));
        (self->ast = codegen__codegen__Codegen__mod_ast(self, iface.module));
        (self->borrowed = true);
        (self->dflt_home = (*home).module);
        (self->dflt_home_set = true);
        (oninst = Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances));
      }
      (self->nsubst = 1);
      (self->subst[0].param = iface);
      (self->subst[0].concrete = tty);
      if (!with_body) {
        codegen__codegen__Codegen__emit_ret_struct(self, rid, target);
      }
      codegen__codegen__Buf256 dnm = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__function_name(self, rid, target, ((char *)(&dnm.b[0])), 256ULL, true);
      const bool stat = (self->multifile && (!vis));
      codegen__codegen__Codegen__emit_function(self, rid, target, false, with_body, ((const char *)(&dnm.b[0])), stat);
      (self->nsubst = 0);
      if (foreign) {
        Vector__ast__ast__TyInstance__Global__truncate(&(*codegen__codegen__Codegen__cur_ast(self)).instances, oninst);
        (self->borrowed = false);
        (self->dflt_home_set = false);
        (self->ast = home);
        (self->source = hsrc);
        (self->len = hlen);
      }
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_closure_fn(codegen__codegen__Codegen *const self, uint32_t const id, bool const with_body) {
  const ast__ast__ClosureData cl = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.closure;
  const bool caps = (cl.captures.len != 0U);
  codegen__codegen__Buf200 nm = (codegen__codegen__Buf200){0};
  codegen__codegen__Codegen__closure_name(self, id, ((char *)(&nm.b[0])), 200ULL);
  if (caps && (!with_body)) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1195 = (str){ (const uint8_t *)"typedef struct { ", sizeof("typedef struct { ") - 1 }; str__ptr(&__sc1195); })));
    const uint32_t *const cids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), cl.captures);
    for (uint32_t i = 0U; i < cl.captures.len; i++) {
      const uint32_t cid = cids[((size_t)i)];
      codegen__codegen__Buf128 fnm = (codegen__codegen__Buf128){0};
      const lexer__token__Span csp = codegen__codegen__Codegen__cg_decl_name_span(self, cid);
      codegen__codegen__Codegen__render_ident(self, csp, ((char *)(&fnm.b[0])), 128ULL);
      uint32_t ft = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), cid);
      if ((({ uint64_t __sc1196 = ((uint64_t)cl.mut_caps); int64_t __sc1197 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc1197 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc1196 >> __sc1197); }) & 1ULL) != 0ULL) {
        (ft = ast__ast__Ast__intern_type(&((*codegen__codegen__Codegen__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_POINTER, .qualifier = 2U, .as_data = (ast__ast__TyAs){ .elem = ft } }));
      }
      codegen__codegen__Buf300 d = (codegen__codegen__Buf300){0};
      codegen__codegen__Codegen__render_type_id(self, ft, ((const char *)(&fnm.b[0])), ((char *)(&d.b[0])), 300ULL);
      ({ String__Global *__sc1198 = &(self->buf);
String__Global__push_str(&(*__sc1198), utils__errors__cstr(((const char *)(&d.b[0]))));
String__Global__push_str(&(*__sc1198), (str){ .ptr = (const uint8_t*)"; ", .len = sizeof("; ") - 1 });
});
    }
    ({ String__Global *__sc1199 = &(self->buf);
String__Global__push_str(&(*__sc1199), (str){ .ptr = (const uint8_t*)"} ", .len = sizeof("} ") - 1 });
String__Global__push_str(&(*__sc1199), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1199), (str){ .ptr = (const uint8_t*)"_env;\n", .len = sizeof("_env;\n") - 1 });
});
    const ast__ast__Ty fnty = (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_FUNCTION, .module = codegen__codegen__Codegen__cur_module(self), .as_data = (ast__ast__TyAs){ .decl = id } };
    if (codegen__codegen__Codegen__cg_fn_owns(self, (&fnty))) {
      ({ String__Global *__sc1200 = &(self->buf);
String__Global__push_str(&(*__sc1200), (str){ .ptr = (const uint8_t*)"static __attribute__((unused)) void ", .len = sizeof("static __attribute__((unused)) void ") - 1 });
String__Global__push_str(&(*__sc1200), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1200), (str){ .ptr = (const uint8_t*)"_env_free(", .len = sizeof("_env_free(") - 1 });
String__Global__push_str(&(*__sc1200), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1200), (str){ .ptr = (const uint8_t*)"_env *const __e) { ", .len = sizeof("_env *const __e) { ") - 1 });
});
      for (uint32_t i2 = 0U; i2 < cl.captures.len; i2++) {
        const uint32_t cid = cids[((size_t)i2)];
        if (((({ uint64_t __sc1201 = ((uint64_t)cl.mut_caps); int64_t __sc1202 = (int64_t)(((uint64_t)i2)); if ((uint64_t)__sc1202 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc1201 >> __sc1202); }) & 1ULL) != 0ULL) || (!codegen__codegen__Codegen__cg_type_is_free(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), cid)))) {
          continue;
        }
        codegen__codegen__Buf128 fnm = (codegen__codegen__Buf128){0};
        const lexer__token__Span csp = codegen__codegen__Codegen__cg_decl_name_span(self, cid);
        codegen__codegen__Codegen__render_ident(self, csp, ((char *)(&fnm.b[0])), 128ULL);
        if (codegen__codegen__Codegen__emit_free_target(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), cid))) {
          ({ String__Global *__sc1203 = &(self->buf);
String__Global__push_str(&(*__sc1203), (str){ .ptr = (const uint8_t*)"(&__e->", .len = sizeof("(&__e->") - 1 });
String__Global__push_str(&(*__sc1203), utils__errors__cstr(((const char *)(&fnm.b[0]))));
String__Global__push_str(&(*__sc1203), (str){ .ptr = (const uint8_t*)"); ", .len = sizeof("); ") - 1 });
});
        }
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1204 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc1204); })));
    }
  }
  codegen__codegen__Buf1024 ps = (codegen__codegen__Buf1024){0};
  codegen__codegen__Codegen__render_params(self, cl.params, ((char *)(&ps.b[0])), 1024ULL);
  codegen__codegen__Buf1320 decl = (codegen__codegen__Buf1320){0};
  size_t at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, 0ULL, ((const char *)(&nm.b[0])));
  (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1205 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc1205); }))));
  if (caps) {
    (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1206 = (str){ (const uint8_t *)"const ", sizeof("const ") - 1 }; str__ptr(&__sc1206); }))));
    (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)(&nm.b[0]))));
    (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1207 = (str){ (const uint8_t *)"_env *const __env", sizeof("_env *const __env") - 1 }; str__ptr(&__sc1207); }))));
    if (strcmp(((const char *)(&ps.b[0])), ((const char *)({ __auto_type __sc1208 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1208); }))) != 0) {
      (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1209 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1209); }))));
      (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)(&ps.b[0]))));
    }
  } else {
    (at = codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)(&ps.b[0]))));
  }
  codegen__codegen__bappend(((char *)(&decl.b[0])), 1320ULL, at, ((const char *)({ __auto_type __sc1210 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc1210); })));
  const uint32_t body = cl.body;
  const bool expr_body = cl.expr_body;
  uint32_t rt = ast__ast__TYPE_NONE;
  if (expr_body) {
    (rt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), body));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1211 = (str){ (const uint8_t *)"static __attribute__((unused)) ", sizeof("static __attribute__((unused)) ") - 1 }; str__ptr(&__sc1211); })));
  codegen__codegen__Buf1400 out = (codegen__codegen__Buf1400){0};
  if (expr_body) {
    codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)(&decl.b[0])), ((char *)(&out.b[0])), 1400ULL);
  } else {
    const ast__ast__NodeList rets = cl.returns;
    if (rets.len == 1U) {
      const uint32_t r0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), rets)[0];
      const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), r0);
      const uint32_t rtn = ({
        uint32_t __sc1212;
        if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
          __sc1212 = rn->as_data.parameter.ty;
        } else {
          __sc1212 = r0;
        }
        __sc1212;
      });
      codegen__codegen__Codegen__render_type_node(self, rtn, ((const char *)(&decl.b[0])), ((char *)(&out.b[0])), 1400ULL);
    } else {
      codegen__codegen__buf_join3(((char *)(&out.b[0])), 1400ULL, ((const char *)({ __auto_type __sc1213 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc1213); })), ((const char *)({ __auto_type __sc1214 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1214); })), ((const char *)(&decl.b[0])));
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&out.b[0])));
  if (!with_body) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1215 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1215); })));
    return;
  }
  (self->current_ret[0] = 0);
  const uint32_t saved_env = self->env_clos;
  (self->env_clos = ({
    uint32_t __sc1216;
    if (caps) {
      __sc1216 = id;
    } else {
      __sc1216 = ast__ast__NODE_NONE;
    }
    __sc1216;
  }));
  if (expr_body) {
    bool is_void = false;
    if (rt != ast__ast__TYPE_NONE) {
      const ast__ast__Ty rty = (*codegen__codegen__Codegen__type_at(self, rt));
      (is_void = ((rty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (rty.as_data.builtin == ast__ast__BuiltinType_BT_VOID)));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1217 = (str){ (const uint8_t *)" {\n", sizeof(" {\n") - 1 }; str__ptr(&__sc1217); })));
    (self->depth = (self->depth + 1U));
    codegen__codegen__Codegen__emit_indent(self);
    if (!is_void) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1218 = (str){ (const uint8_t *)"return ", sizeof("return ") - 1 }; str__ptr(&__sc1218); })));
    }
    codegen__codegen__Codegen__emit_expr(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1219 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1219); })));
    (self->depth = (self->depth - 1U));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1220 = (str){ (const uint8_t *)"}\n\n", sizeof("}\n\n") - 1 }; str__ptr(&__sc1220); })));
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1221 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1221); })));
    (self->defer_top = 0U);
    (self->loop_defer_base = 0U);
    codegen__codegen__Codegen__emit_block(self, body);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1222 = (str){ (const uint8_t *)"\n\n", sizeof("\n\n") - 1 }; str__ptr(&__sc1222); })));
  }
  (self->env_clos = saved_env);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_closures(codegen__codegen__Codegen *const self, bool const with_body) {
  for (size_t i = 0ULL; i < Vector__ast__ast__Node__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).nodes); i++) {
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i))->kind == ast__ast__NodeKind_NODE_CLOSURE) {
      if (ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)) == ast__ast__TYPE_NONE) {
        continue;
      }
      codegen__codegen__Codegen__emit_closure_fn(self, ((uint32_t)i), with_body);
    }
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cb_specialized_away(const codegen__codegen__Codegen *const self, uint32_t const fnId) {
  const ast__ast__NodeKind fk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fnId)->kind;
  const bool fpub = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fnId)->as_data.function.is_public;
  if ((fk != ast__ast__NodeKind_NODE_FUNCTION) || fpub) {
    return false;
  }
  bool any = false;
  int32_t i = 0;
  while ((i < self->n_cb_insts) && (!any)) {
    if ((self->cb_insts[((size_t)i)].func.node == fnId) && (self->cb_insts[((size_t)i)].func.module == codegen__codegen__Codegen__cur_module(self))) {
      (any = true);
    }
    (i = ({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if (!any) {
    return false;
  }
  for (int32_t j = 0; j < self->n_cb_keep; j++) {
    if (self->cb_keep_fns[((size_t)j)] == fnId) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) void codegen__codegen__Codegen__collect_callbacks(codegen__codegen__Codegen *const self) {
  (self->n_cb_insts = 0);
  (self->n_cb_keep = 0);
  const size_t nn = Vector__ast__ast__Node__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).nodes);
  uint32_t i = 0U;
  while (((size_t)i) < nn) {
    const ast__ast__NodeKind ck = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), i)->kind;
    if (ck != ast__ast__NodeKind_NODE_CALL) {
      (i = (i + 1U));
      continue;
    }
    const uint32_t callee_id = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), i)->as_data.call.callee;
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
      (i = (i + 1U));
      continue;
    }
    const ast__ast__DefId fn2 = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee_id);
    if ((fn2.module != codegen__codegen__Codegen__cur_module(self)) || (fn2.node == ast__ast__NODE_NONE)) {
      (i = (i + 1U));
      continue;
    }
    const ast__ast__NodeKind fnk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn2.node)->kind;
    const ast__ast__FunctionData ff = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn2.node)->as_data.function;
    if (((fnk != ast__ast__NodeKind_NODE_FUNCTION) || (ff.generics.len != 0U)) || (ff.body == ast__ast__NODE_NONE)) {
      (i = (i + 1U));
      continue;
    }
    if (!codegen__codegen__Codegen__decl_is_toplevel(self, fn2.module, fn2.node)) {
      (i = (i + 1U));
      continue;
    }
    uint32_t cbidx = 0U;
    uint32_t param = ast__ast__NODE_NONE;
    const bool single = codegen__codegen__Codegen__cb_single_callback_param(self, fn2.node, ((uint32_t *)(&cbidx)), ((uint32_t *)(&param)));
    if ((!single) || (!codegen__codegen__Codegen__param_only_callee(self, param))) {
      (i = (i + 1U));
      continue;
    }
    const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), i)->as_data.call.args;
    const uint32_t *const aids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), args);
    ast__ast__DefId callee = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    bool isclo = false;
    const bool known = ({
      bool __sc1223;
      if (cbidx < args.len) {
        __sc1223 = codegen__codegen__Codegen__cb_known_callee(self, aids[((size_t)cbidx)], ((ast__ast__DefId *)(&callee)), ((bool *)(&isclo)));
      } else {
        __sc1223 = false;
      }
      __sc1223;
    });
    if (known) {
      codegen__codegen__Codegen__cb_record(self, fn2, param, cbidx, callee, isclo);
    } else {
      codegen__codegen__Codegen__cb_keep(self, fn2.node);
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_callback_specializations(codegen__codegen__Codegen *const self, bool const with_body) {
  for (int32_t i = 0; i < self->n_cb_insts; i++) {
    const codegen__codegen__CgCbInst ci = self->cb_insts[((size_t)i)];
    if (ci.func.module != codegen__codegen__Codegen__cur_module(self)) {
      continue;
    }
    (self->cb_param = ci.param);
    (self->cb_callee = ci.callee);
    (self->cb_callee_closure = ci.callee_closure);
    codegen__codegen__Buf300 nm = (codegen__codegen__Buf300){0};
    codegen__codegen__Codegen__cb_spec_name(self, ci.func, self->cb_callee, self->cb_callee_closure, ((char *)(&nm.b[0])), 300ULL);
    codegen__codegen__Codegen__emit_function(self, ci.func.node, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, with_body, ((const char *)(&nm.b[0])), true);
    (self->cb_param = ast__ast__NODE_NONE);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_dyn_typedefs(codegen__codegen__Codegen *const self) {
  for (size_t i = 0ULL; i < Vector__ast__ast__Ty__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).type_pool); i++) {
    const ast__ast__Ty dy = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)));
    if (dy.kind != ast__ast__TypeKind_TYPE_DYN) {
      continue;
    }
    bool seen = false;
    size_t j = 0ULL;
    while ((j < i) && (!seen)) {
      const ast__ast__Ty pj = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)j)));
      if (((pj.kind == ast__ast__TypeKind_TYPE_DYN) && (pj.module == dy.module)) && (pj.as_data.decl == dy.as_data.decl)) {
        (seen = true);
      }
      (j = (j + 1ULL));
    }
    if (seen) {
      continue;
    }
    codegen__codegen__Buf176 stem = (codegen__codegen__Buf176){0};
    codegen__codegen__Codegen__dyn_stem(self, dy.module, dy.as_data.decl, ((char *)(&stem.b[0])), 176ULL);
    const char *const sp = ((const char *)(&stem.b[0]));
    const ast__ast__NodeKind idn_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), dy.as_data.decl)->kind;
    ({ String__Global *__sc1224 = &(self->buf);
String__Global__push_str(&(*__sc1224), (str){ .ptr = (const uint8_t*)"#ifndef SC_DYN_", .len = sizeof("#ifndef SC_DYN_") - 1 });
String__Global__push_str(&(*__sc1224), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1224), (str){ .ptr = (const uint8_t*)"\n#define SC_DYN_", .len = sizeof("\n#define SC_DYN_") - 1 });
String__Global__push_str(&(*__sc1224), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1224), (str){ .ptr = (const uint8_t*)"\n", .len = sizeof("\n") - 1 });
});
    ({ String__Global *__sc1225 = &(self->buf);
String__Global__push_str(&(*__sc1225), (str){ .ptr = (const uint8_t*)"typedef struct ", .len = sizeof("typedef struct ") - 1 });
String__Global__push_str(&(*__sc1225), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1225), (str){ .ptr = (const uint8_t*)"__vt {\n    void (*__free)(void *self);\n", .len = sizeof("__vt {\n    void (*__free)(void *self);\n") - 1 });
});
    if (idn_kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
      const ast__ast__NodeList ftp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), dy.as_data.decl)->as_data.function_type.params;
      const uint32_t *const pid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), ftp);
      codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
      size_t at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, 0ULL, ((const char *)({ __auto_type __sc1226 = (str){ (const uint8_t *)"(*call)(void *self", sizeof("(*call)(void *self") - 1 }; str__ptr(&__sc1226); })));
      for (uint32_t p = 0U; p < ftp.len; p++) {
        const uint32_t src_ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), pid[((size_t)p)]);
        const uint32_t pt_ty = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, dy.module))), src_ty);
        codegen__codegen__Buf200 pt = (codegen__codegen__Buf200){0};
        codegen__codegen__Codegen__render_type_id(self, pt_ty, ((const char *)({ __auto_type __sc1227 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1227); })), ((char *)(&pt.b[0])), 200ULL);
        (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc1228 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1228); }))));
        (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)(&pt.b[0]))));
      }
      codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc1229 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc1229); })));
      const uint32_t rt = codegen__codegen__Codegen__cg_dynfn_ret(self, dy.module, dy.as_data.decl);
      codegen__codegen__Buf600 memb = (codegen__codegen__Buf600){0};
      if (rt != ast__ast__TYPE_NONE) {
        codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)(&inner.b[0])), ((char *)(&memb.b[0])), 600ULL);
      } else {
        codegen__codegen__buf_join3(((char *)(&memb.b[0])), 600ULL, ((const char *)({ __auto_type __sc1230 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc1230); })), ((const char *)({ __auto_type __sc1231 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1231); })), ((const char *)(&inner.b[0])));
      }
      ({ String__Global *__sc1232 = &(self->buf);
String__Global__push_str(&(*__sc1232), (str){ .ptr = (const uint8_t*)"    ", .len = sizeof("    ") - 1 });
String__Global__push_str(&(*__sc1232), utils__errors__cstr(((const char *)(&memb.b[0]))));
String__Global__push_str(&(*__sc1232), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
      ({ String__Global *__sc1233 = &(self->buf);
String__Global__push_str(&(*__sc1233), (str){ .ptr = (const uint8_t*)"} ", .len = sizeof("} ") - 1 });
String__Global__push_str(&(*__sc1233), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1233), (str){ .ptr = (const uint8_t*)"__vt;\ntypedef struct ", .len = sizeof("__vt;\ntypedef struct ") - 1 });
String__Global__push_str(&(*__sc1233), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1233), (str){ .ptr = (const uint8_t*)"__dyn { void *data; const ", .len = sizeof("__dyn { void *data; const ") - 1 });
String__Global__push_str(&(*__sc1233), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1233), (str){ .ptr = (const uint8_t*)"__vt *vt; } ", .len = sizeof("__vt *vt; } ") - 1 });
String__Global__push_str(&(*__sc1233), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1233), (str){ .ptr = (const uint8_t*)"__dyn;\n", .len = sizeof("__dyn;\n") - 1 });
});
      ({ String__Global *__sc1234 = &(self->buf);
String__Global__push_str(&(*__sc1234), (str){ .ptr = (const uint8_t*)"static inline void ", .len = sizeof("static inline void ") - 1 });
String__Global__push_str(&(*__sc1234), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1234), (str){ .ptr = (const uint8_t*)"__dyn_free(", .len = sizeof("__dyn_free(") - 1 });
String__Global__push_str(&(*__sc1234), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1234), (str){ .ptr = (const uint8_t*)"__dyn *const d) { d->vt->__free(d->data); }\n#endif\n", .len = sizeof("__dyn *const d) { d->vt->__free(d->data); }\n#endif\n") - 1 });
});
      continue;
    }
    const ast__ast__NodeList idn_items = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), dy.as_data.decl)->as_data.interface_def.items;
    const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), idn_items);
    for (uint32_t km = 0U; km < idn_items.len; km++) {
      const uint32_t mid = mids[((size_t)km)];
      if (!codegen__codegen__Codegen__cg_dyn_method(self, dy.module, mid)) {
        continue;
      }
      const uint32_t mname_node = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mid)->as_data.function.name;
      codegen__codegen__Buf128 mn = (codegen__codegen__Buf128){0};
      codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, dy.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mname_node)->as_data.name.text, ((char *)(&mn.b[0])), 128ULL);
      const ast__ast__NodeList mparams = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mid)->as_data.function.params;
      const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mparams);
      codegen__codegen__Buf512 inner = (codegen__codegen__Buf512){0};
      size_t at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, 0ULL, ((const char *)({ __auto_type __sc1235 = (str){ (const uint8_t *)"(*", sizeof("(*") - 1 }; str__ptr(&__sc1235); })));
      (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)(&mn.b[0]))));
      (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc1236 = (str){ (const uint8_t *)")(void *self", sizeof(")(void *self") - 1 }; str__ptr(&__sc1236); }))));
      uint32_t p = 1U;
      while (p < mparams.len) {
        const uint32_t ptn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), pids[((size_t)p)])->as_data.parameter.ty;
        const uint32_t src_ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), ptn);
        const uint32_t pt_ty = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, dy.module))), src_ty);
        codegen__codegen__Buf200 pt = (codegen__codegen__Buf200){0};
        codegen__codegen__Codegen__render_type_id(self, pt_ty, ((const char *)({ __auto_type __sc1237 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1237); })), ((char *)(&pt.b[0])), 200ULL);
        (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc1238 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1238); }))));
        (at = codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)(&pt.b[0]))));
        (p = (p + 1U));
      }
      codegen__codegen__bappend(((char *)(&inner.b[0])), 512ULL, at, ((const char *)({ __auto_type __sc1239 = (str){ (const uint8_t *)")", sizeof(")") - 1 }; str__ptr(&__sc1239); })));
      const uint32_t rt = codegen__codegen__Codegen__cg_dyn_ret(self, dy.module, mid);
      codegen__codegen__Buf600 memb = (codegen__codegen__Buf600){0};
      if (rt != ast__ast__TYPE_NONE) {
        codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)(&inner.b[0])), ((char *)(&memb.b[0])), 600ULL);
      } else {
        codegen__codegen__buf_join3(((char *)(&memb.b[0])), 600ULL, ((const char *)({ __auto_type __sc1240 = (str){ (const uint8_t *)"void ", sizeof("void ") - 1 }; str__ptr(&__sc1240); })), ((const char *)({ __auto_type __sc1241 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1241); })), ((const char *)(&inner.b[0])));
      }
      ({ String__Global *__sc1242 = &(self->buf);
String__Global__push_str(&(*__sc1242), (str){ .ptr = (const uint8_t*)"    ", .len = sizeof("    ") - 1 });
String__Global__push_str(&(*__sc1242), utils__errors__cstr(((const char *)(&memb.b[0]))));
String__Global__push_str(&(*__sc1242), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    }
    ({ String__Global *__sc1243 = &(self->buf);
String__Global__push_str(&(*__sc1243), (str){ .ptr = (const uint8_t*)"} ", .len = sizeof("} ") - 1 });
String__Global__push_str(&(*__sc1243), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1243), (str){ .ptr = (const uint8_t*)"__vt;\ntypedef struct ", .len = sizeof("__vt;\ntypedef struct ") - 1 });
String__Global__push_str(&(*__sc1243), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1243), (str){ .ptr = (const uint8_t*)"__dyn { void *data; const ", .len = sizeof("__dyn { void *data; const ") - 1 });
String__Global__push_str(&(*__sc1243), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1243), (str){ .ptr = (const uint8_t*)"__vt *vt; } ", .len = sizeof("__vt *vt; } ") - 1 });
String__Global__push_str(&(*__sc1243), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1243), (str){ .ptr = (const uint8_t*)"__dyn;\n", .len = sizeof("__dyn;\n") - 1 });
});
    ({ String__Global *__sc1244 = &(self->buf);
String__Global__push_str(&(*__sc1244), (str){ .ptr = (const uint8_t*)"static inline void ", .len = sizeof("static inline void ") - 1 });
String__Global__push_str(&(*__sc1244), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1244), (str){ .ptr = (const uint8_t*)"__dyn_free(", .len = sizeof("__dyn_free(") - 1 });
String__Global__push_str(&(*__sc1244), utils__errors__cstr(sp));
String__Global__push_str(&(*__sc1244), (str){ .ptr = (const uint8_t*)"__dyn *const d) { d->vt->__free(d->data); }\n#endif\n", .len = sizeof("__dyn *const d) { d->vt->__free(d->data); }\n#endif\n") - 1 });
});
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_dynfn_table(codegen__codegen__Codegen *const self, uint32_t const src, ast__ast__Ty const dy) {
  const ast__ast__Ty sy = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), src));
  const ast__ast__NodeKind fd_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, sy.module))), sy.as_data.decl)->kind;
  const bool capt = codegen__codegen__Codegen__cg_fn_is_capturing(self, (&sy));
  codegen__codegen__Buf368 pair = (codegen__codegen__Buf368){0};
  codegen__codegen__Codegen__dyn_pair_stem(self, src, dy.module, dy.as_data.decl, ((char *)(&pair.b[0])), 368ULL);
  const char *const pp = ((const char *)(&pair.b[0]));
  const ast__ast__NodeList sig_params = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), dy.as_data.decl)->as_data.function_type.params;
  const uint32_t rt = codegen__codegen__Codegen__cg_dynfn_ret(self, dy.module, dy.as_data.decl);
  codegen__codegen__Buf256 rts = (codegen__codegen__Buf256){0};
  if (rt != ast__ast__TYPE_NONE) {
    codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)({ __auto_type __sc1245 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1245); })), ((char *)(&rts.b[0])), 256ULL);
  } else {
    codegen__codegen__bappend(((char *)(&rts.b[0])), 256ULL, 0ULL, ((const char *)({ __auto_type __sc1246 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1246); })));
  }
  ({ String__Global *__sc1247 = &(self->buf);
String__Global__push_str(&(*__sc1247), (str){ .ptr = (const uint8_t*)"static __attribute__((unused)) ", .len = sizeof("static __attribute__((unused)) ") - 1 });
String__Global__push_str(&(*__sc1247), utils__errors__cstr(((const char *)(&rts.b[0]))));
String__Global__push_str(&(*__sc1247), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1247), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1247), (str){ .ptr = (const uint8_t*)"__call(void *__self", .len = sizeof("__call(void *__self") - 1 });
});
  const uint32_t *const pid = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), sig_params);
  for (uint32_t p = 0U; p < sig_params.len; p++) {
    codegen__codegen__Buf32 an = (codegen__codegen__Buf32){0};
    snprintf(((char *)(&an.b[0])), 16ULL, ((const char *)({ __auto_type __sc1248 = (str){ (const uint8_t *)"_a%u", sizeof("_a%u") - 1 }; str__ptr(&__sc1248); })), p);
    const uint32_t src_ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), pid[((size_t)p)]);
    const uint32_t pt_ty = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, dy.module))), src_ty);
    codegen__codegen__Buf240 pd = (codegen__codegen__Buf240){0};
    codegen__codegen__Codegen__render_type_id(self, pt_ty, ((const char *)(&an.b[0])), ((char *)(&pd.b[0])), 240ULL);
    ({ String__Global *__sc1249 = &(self->buf);
String__Global__push_str(&(*__sc1249), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1249), utils__errors__cstr(((const char *)(&pd.b[0]))));
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1250 = (str){ (const uint8_t *)") { ", sizeof(") { ") - 1 }; str__ptr(&__sc1250); })));
  if (!capt) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1251 = (str){ (const uint8_t *)"(void)__self; ", sizeof("(void)__self; ") - 1 }; str__ptr(&__sc1251); })));
  }
  if (rt != ast__ast__TYPE_NONE) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1252 = (str){ (const uint8_t *)"return ", sizeof("return ") - 1 }; str__ptr(&__sc1252); })));
  }
  codegen__codegen__Buf240 sym = (codegen__codegen__Buf240){0};
  if (fd_kind == ast__ast__NodeKind_NODE_CLOSURE) {
    codegen__codegen__Codegen__closure_sym_in(self, sy.module, sy.as_data.decl, ((char *)(&sym.b[0])), 240ULL);
  } else {
    const uint32_t fname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, sy.module))), sy.as_data.decl)->as_data.function.name;
    codegen__codegen__Codegen__render_qualified(self, sy.module, fname, ((char *)(&sym.b[0])), 240ULL);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&sym.b[0])));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1253 = (str){ (const uint8_t *)"(", sizeof("(") - 1 }; str__ptr(&__sc1253); })));
  bool wrote = false;
  codegen__codegen__Buf256 envn = (codegen__codegen__Buf256){0};
  if (capt) {
    codegen__codegen__Codegen__render_type_id(self, src, ((const char *)({ __auto_type __sc1254 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1254); })), ((char *)(&envn.b[0])), 256ULL);
    ({ String__Global *__sc1255 = &(self->buf);
String__Global__push_str(&(*__sc1255), (str){ .ptr = (const uint8_t*)"(const ", .len = sizeof("(const ") - 1 });
String__Global__push_str(&(*__sc1255), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc1255), (str){ .ptr = (const uint8_t*)" *)__self", .len = sizeof(" *)__self") - 1 });
});
    (wrote = true);
  }
  for (uint32_t p2 = 0U; p2 < sig_params.len; p2++) {
    if (wrote || (p2 != 0U)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1256 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1256); })));
    }
    ({ String__Global *__sc1257 = &(self->buf);
String__Global__push_str(&(*__sc1257), (str){ .ptr = (const uint8_t*)"_a", .len = sizeof("_a") - 1 });
String__Global__push_u64(&(*__sc1257), (uint64_t)(p2));
});
    (wrote = true);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1258 = (str){ (const uint8_t *)"); }\n", sizeof("); }\n") - 1 }; str__ptr(&__sc1258); })));
  bool owned = false;
  size_t jj = 0ULL;
  while ((jj < Vector__ast__ast__DynUse__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses)) && (!owned)) {
    const ast__ast__DynUse oju = (*({ __auto_type __sc1259 = &(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses; Vector__ast__ast__DynUse__Global__index(__sc1259, jj); }));
    if (oju.src == src) {
      const ast__ast__Ty oy = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), oju.dyn_ty));
      if (oy.qualifier == 0U) {
        (owned = true);
      }
    }
    (jj = (jj + 1ULL));
  }
  if (owned && (self->package != NULL)) {
    const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Global", sizeof("Global") - 1 }, true);
    const uint32_t gname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, hit.mid))), hit.node)->as_data.aggregate.name;
    codegen__codegen__Buf160 gt = (codegen__codegen__Buf160){0};
    codegen__codegen__Codegen__render_qualified(self, hit.mid, gname, ((char *)(&gt.b[0])), 160ULL);
    const char *const gtp = ((const char *)(&gt.b[0]));
    ({ String__Global *__sc1260 = &(self->buf);
String__Global__push_str(&(*__sc1260), (str){ .ptr = (const uint8_t*)"static void ", .len = sizeof("static void ") - 1 });
String__Global__push_str(&(*__sc1260), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1260), (str){ .ptr = (const uint8_t*)"____free(void *__self) {\n", .len = sizeof("____free(void *__self) {\n") - 1 });
});
    if (capt) {
      if (codegen__codegen__Codegen__cg_fn_owns(self, (&sy))) {
        codegen__codegen__Buf240 csym = (codegen__codegen__Buf240){0};
        codegen__codegen__Codegen__closure_sym_in(self, sy.module, sy.as_data.decl, ((char *)(&csym.b[0])), 240ULL);
        ({ String__Global *__sc1261 = &(self->buf);
String__Global__push_str(&(*__sc1261), (str){ .ptr = (const uint8_t*)"    ", .len = sizeof("    ") - 1 });
String__Global__push_str(&(*__sc1261), utils__errors__cstr(((const char *)(&csym.b[0]))));
String__Global__push_str(&(*__sc1261), (str){ .ptr = (const uint8_t*)"_env_free((", .len = sizeof("_env_free((") - 1 });
String__Global__push_str(&(*__sc1261), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc1261), (str){ .ptr = (const uint8_t*)" *)__self);\n", .len = sizeof(" *)__self);\n") - 1 });
});
      }
      ({ String__Global *__sc1262 = &(self->buf);
String__Global__push_str(&(*__sc1262), (str){ .ptr = (const uint8_t*)"    ", .len = sizeof("    ") - 1 });
String__Global__push_str(&(*__sc1262), utils__errors__cstr(gtp));
String__Global__push_str(&(*__sc1262), (str){ .ptr = (const uint8_t*)" __g = ", .len = sizeof(" __g = ") - 1 });
String__Global__push_str(&(*__sc1262), utils__errors__cstr(gtp));
String__Global__push_str(&(*__sc1262), (str){ .ptr = (const uint8_t*)"__default_();\n    ", .len = sizeof("__default_();\n    ") - 1 });
String__Global__push_str(&(*__sc1262), utils__errors__cstr(gtp));
String__Global__push_str(&(*__sc1262), (str){ .ptr = (const uint8_t*)"__dealloc(&__g, __self, sizeof(", .len = sizeof("__dealloc(&__g, __self, sizeof(") - 1 });
String__Global__push_str(&(*__sc1262), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc1262), (str){ .ptr = (const uint8_t*)"), _Alignof(", .len = sizeof("), _Alignof(") - 1 });
String__Global__push_str(&(*__sc1262), utils__errors__cstr(((const char *)(&envn.b[0]))));
String__Global__push_str(&(*__sc1262), (str){ .ptr = (const uint8_t*)"));\n", .len = sizeof("));\n") - 1 });
});
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1263 = (str){ (const uint8_t *)"    (void)__self;\n", sizeof("    (void)__self;\n") - 1 }; str__ptr(&__sc1263); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1264 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc1264); })));
  }
  codegen__codegen__Buf176 stem = (codegen__codegen__Buf176){0};
  codegen__codegen__Codegen__dyn_stem(self, dy.module, dy.as_data.decl, ((char *)(&stem.b[0])), 176ULL);
  ({ String__Global *__sc1265 = &(self->buf);
String__Global__push_str(&(*__sc1265), (str){ .ptr = (const uint8_t*)"static const ", .len = sizeof("static const ") - 1 });
String__Global__push_str(&(*__sc1265), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc1265), (str){ .ptr = (const uint8_t*)"__vt ", .len = sizeof("__vt ") - 1 });
String__Global__push_str(&(*__sc1265), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1265), (str){ .ptr = (const uint8_t*)"__vtbl __attribute__((unused)) = { ", .len = sizeof("__vtbl __attribute__((unused)) = { ") - 1 });
});
  if (owned) {
    ({ String__Global *__sc1266 = &(self->buf);
String__Global__push_str(&(*__sc1266), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1266), (str){ .ptr = (const uint8_t*)"____free", .len = sizeof("____free") - 1 });
});
  } else {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1267 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc1267); })));
  }
  ({ String__Global *__sc1268 = &(self->buf);
String__Global__push_str(&(*__sc1268), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1268), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1268), (str){ .ptr = (const uint8_t*)"__call };\n", .len = sizeof("__call };\n") - 1 });
});
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_dyn_tables(codegen__codegen__Codegen *const self) {
  const size_t n = Vector__ast__ast__DynUse__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses);
  for (size_t i = 0ULL; i < n; i++) {
    const ast__ast__DynUse dui = (*({ __auto_type __sc1269 = &(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses; Vector__ast__ast__DynUse__Global__index(__sc1269, i); }));
    if (dui.src == ast__ast__TYPE_NONE) {
      continue;
    }
    const ast__ast__Ty dy = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), dui.dyn_ty));
    codegen__codegen__Buf176 istem = (codegen__codegen__Buf176){0};
    codegen__codegen__Codegen__dyn_stem(self, dy.module, dy.as_data.decl, ((char *)(&istem.b[0])), 176ULL);
    bool seen = false;
    size_t j = 0ULL;
    while ((j < i) && (!seen)) {
      const ast__ast__DynUse duj = (*({ __auto_type __sc1270 = &(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses; Vector__ast__ast__DynUse__Global__index(__sc1270, j); }));
      if (duj.src != dui.src) {
        (j = (j + 1ULL));
        continue;
      }
      const ast__ast__Ty pj = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), duj.dyn_ty));
      if ((pj.module == dy.module) && (pj.as_data.decl == dy.as_data.decl)) {
        (seen = true);
      } else {
        codegen__codegen__Buf176 jstem = (codegen__codegen__Buf176){0};
        codegen__codegen__Codegen__dyn_stem(self, pj.module, pj.as_data.decl, ((char *)(&jstem.b[0])), 176ULL);
        if (strcmp(((const char *)(&istem.b[0])), ((const char *)(&jstem.b[0]))) == 0) {
          (seen = true);
        }
      }
      (j = (j + 1ULL));
    }
    if (seen) {
      continue;
    }
    const uint32_t src = dui.src;
    const ast__ast__Ty sy = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), src));
    if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), dy.as_data.decl)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
      codegen__codegen__Codegen__emit_dynfn_table(self, src, dy);
      continue;
    }
    uint16_t tm = 0U;
    uint32_t td = ast__ast__NODE_NONE;
    if (!codegen__codegen__Codegen__cg_dyn_target(self, (&sy), ((uint16_t *)(&tm)), ((uint32_t *)(&td)))) {
      continue;
    }
    codegen__codegen__Buf368 pair = (codegen__codegen__Buf368){0};
    codegen__codegen__Codegen__dyn_pair_stem(self, src, dy.module, dy.as_data.decl, ((char *)(&pair.b[0])), 368ULL);
    const char *const pp = ((const char *)(&pair.b[0]));
    codegen__codegen__Buf256 recv = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, src, ((const char *)({ __auto_type __sc1271 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1271); })), ((char *)(&recv.b[0])), 256ULL);
    const char *const rvp = ((const char *)(&recv.b[0]));
    const ast__ast__NodeList idn_items = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), dy.as_data.decl)->as_data.interface_def.items;
    const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), idn_items);
    for (uint32_t km = 0U; km < idn_items.len; km++) {
      const uint32_t mid = mids[((size_t)km)];
      if (!codegen__codegen__Codegen__cg_dyn_method(self, dy.module, mid)) {
        continue;
      }
      const uint32_t mnamenode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mid)->as_data.function.name;
      const lexer__token__Span mspan = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mnamenode)->as_data.name.text;
      codegen__codegen__Buf128 mn = (codegen__codegen__Buf128){0};
      codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, dy.module), mspan, ((char *)(&mn.b[0])), 128ULL);
      const uint32_t rt = codegen__codegen__Codegen__cg_dyn_ret(self, dy.module, mid);
      codegen__codegen__Buf256 rts = (codegen__codegen__Buf256){0};
      if (rt != ast__ast__TYPE_NONE) {
        codegen__codegen__Codegen__render_type_id(self, rt, ((const char *)({ __auto_type __sc1272 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1272); })), ((char *)(&rts.b[0])), 256ULL);
      } else {
        codegen__codegen__bappend(((char *)(&rts.b[0])), 256ULL, 0ULL, ((const char *)({ __auto_type __sc1273 = (str){ (const uint8_t *)"void", sizeof("void") - 1 }; str__ptr(&__sc1273); })));
      }
      ({ String__Global *__sc1274 = &(self->buf);
String__Global__push_str(&(*__sc1274), (str){ .ptr = (const uint8_t*)"static __attribute__((unused)) ", .len = sizeof("static __attribute__((unused)) ") - 1 });
String__Global__push_str(&(*__sc1274), utils__errors__cstr(((const char *)(&rts.b[0]))));
String__Global__push_str(&(*__sc1274), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1274), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1274), (str){ .ptr = (const uint8_t*)"__", .len = sizeof("__") - 1 });
String__Global__push_str(&(*__sc1274), utils__errors__cstr(((const char *)(&mn.b[0]))));
String__Global__push_str(&(*__sc1274), (str){ .ptr = (const uint8_t*)"(void *__self", .len = sizeof("(void *__self") - 1 });
});
      const ast__ast__NodeList mparams = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mid)->as_data.function.params;
      const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mparams);
      uint32_t p = 1U;
      while (p < mparams.len) {
        codegen__codegen__Buf32 an = (codegen__codegen__Buf32){0};
        snprintf(((char *)(&an.b[0])), 16ULL, ((const char *)({ __auto_type __sc1275 = (str){ (const uint8_t *)"_a%u", sizeof("_a%u") - 1 }; str__ptr(&__sc1275); })), p);
        const uint32_t ptn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), pids[((size_t)p)])->as_data.parameter.ty;
        const uint32_t src_ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), ptn);
        const uint32_t pt_ty = ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, dy.module))), src_ty);
        codegen__codegen__Buf240 pd = (codegen__codegen__Buf240){0};
        codegen__codegen__Codegen__render_type_id(self, pt_ty, ((const char *)(&an.b[0])), ((char *)(&pd.b[0])), 240ULL);
        ({ String__Global *__sc1276 = &(self->buf);
String__Global__push_str(&(*__sc1276), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1276), utils__errors__cstr(((const char *)(&pd.b[0]))));
});
        (p = (p + 1U));
      }
      if (rt != ast__ast__TYPE_NONE) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1277 = (str){ (const uint8_t *)") { return ", sizeof(") { return ") - 1 }; str__ptr(&__sc1277); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1278 = (str){ (const uint8_t *)") { ", sizeof(") { ") - 1 }; str__ptr(&__sc1278); })));
      }
      ast__ast__DefId cm = codegen__codegen__Codegen__cg_find_method(self, tm, td, codegen__codegen__Codegen__mod_src(self, dy.module), mspan);
      if (cm.node == ast__ast__NODE_NONE) {
        (cm = (ast__ast__DefId){ .module = dy.module, .node = mid });
      }
      codegen__codegen__Codegen__emit_op_method(self, sy, tm, td, cm);
      ({ String__Global *__sc1279 = &(self->buf);
String__Global__push_str(&(*__sc1279), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc1279), utils__errors__cstr(rvp));
String__Global__push_str(&(*__sc1279), (str){ .ptr = (const uint8_t*)" *)__self", .len = sizeof(" *)__self") - 1 });
});
      uint32_t p2 = 1U;
      while (p2 < mparams.len) {
        ({ String__Global *__sc1280 = &(self->buf);
String__Global__push_str(&(*__sc1280), (str){ .ptr = (const uint8_t*)", _a", .len = sizeof(", _a") - 1 });
String__Global__push_u64(&(*__sc1280), (uint64_t)(p2));
});
        (p2 = (p2 + 1U));
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1281 = (str){ (const uint8_t *)"); }\n", sizeof("); }\n") - 1 }; str__ptr(&__sc1281); })));
    }
    bool owned = false;
    size_t ojo = 0ULL;
    while ((ojo < Vector__ast__ast__DynUse__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses)) && (!owned)) {
      const ast__ast__DynUse du = (*({ __auto_type __sc1282 = &(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses; Vector__ast__ast__DynUse__Global__index(__sc1282, ojo); }));
      const ast__ast__Ty oy = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), du.dyn_ty));
      if ((((du.src == src) && (oy.module == dy.module)) && (oy.as_data.decl == dy.as_data.decl)) && (oy.qualifier == 0U)) {
        (owned = true);
      }
      (ojo = (ojo + 1ULL));
    }
    if (owned && (self->package != NULL)) {
      const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Global", sizeof("Global") - 1 }, true);
      const uint32_t gname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, hit.mid))), hit.node)->as_data.aggregate.name;
      codegen__codegen__Buf160 gt = (codegen__codegen__Buf160){0};
      codegen__codegen__Codegen__render_qualified(self, hit.mid, gname, ((char *)(&gt.b[0])), 160ULL);
      const char *const gtp = ((const char *)(&gt.b[0]));
      ({ String__Global *__sc1283 = &(self->buf);
String__Global__push_str(&(*__sc1283), (str){ .ptr = (const uint8_t*)"static void ", .len = sizeof("static void ") - 1 });
String__Global__push_str(&(*__sc1283), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1283), (str){ .ptr = (const uint8_t*)"____free(void *__self) {\n", .len = sizeof("____free(void *__self) {\n") - 1 });
});
      if (codegen__codegen__Codegen__cg_type_is_free(self, src)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1284 = (str){ (const uint8_t *)"    ", sizeof("    ") - 1 }; str__ptr(&__sc1284); })));
        codegen__codegen__Codegen__emit_free_target(self, src);
        ({ String__Global *__sc1285 = &(self->buf);
String__Global__push_str(&(*__sc1285), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc1285), utils__errors__cstr(rvp));
String__Global__push_str(&(*__sc1285), (str){ .ptr = (const uint8_t*)" *)__self);\n", .len = sizeof(" *)__self);\n") - 1 });
});
      }
      ({ String__Global *__sc1286 = &(self->buf);
String__Global__push_str(&(*__sc1286), (str){ .ptr = (const uint8_t*)"    ", .len = sizeof("    ") - 1 });
String__Global__push_str(&(*__sc1286), utils__errors__cstr(gtp));
String__Global__push_str(&(*__sc1286), (str){ .ptr = (const uint8_t*)" __g = ", .len = sizeof(" __g = ") - 1 });
String__Global__push_str(&(*__sc1286), utils__errors__cstr(gtp));
String__Global__push_str(&(*__sc1286), (str){ .ptr = (const uint8_t*)"__default_();\n    ", .len = sizeof("__default_();\n    ") - 1 });
String__Global__push_str(&(*__sc1286), utils__errors__cstr(gtp));
String__Global__push_str(&(*__sc1286), (str){ .ptr = (const uint8_t*)"__dealloc(&__g, __self, sizeof(", .len = sizeof("__dealloc(&__g, __self, sizeof(") - 1 });
String__Global__push_str(&(*__sc1286), utils__errors__cstr(rvp));
String__Global__push_str(&(*__sc1286), (str){ .ptr = (const uint8_t*)"), _Alignof(", .len = sizeof("), _Alignof(") - 1 });
String__Global__push_str(&(*__sc1286), utils__errors__cstr(rvp));
String__Global__push_str(&(*__sc1286), (str){ .ptr = (const uint8_t*)"));\n}\n", .len = sizeof("));\n}\n") - 1 });
});
    }
    codegen__codegen__Buf176 stem = (codegen__codegen__Buf176){0};
    codegen__codegen__Codegen__dyn_stem(self, dy.module, dy.as_data.decl, ((char *)(&stem.b[0])), 176ULL);
    ({ String__Global *__sc1287 = &(self->buf);
String__Global__push_str(&(*__sc1287), (str){ .ptr = (const uint8_t*)"static const ", .len = sizeof("static const ") - 1 });
String__Global__push_str(&(*__sc1287), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc1287), (str){ .ptr = (const uint8_t*)"__vt ", .len = sizeof("__vt ") - 1 });
String__Global__push_str(&(*__sc1287), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1287), (str){ .ptr = (const uint8_t*)"__vtbl __attribute__((unused)) = { ", .len = sizeof("__vtbl __attribute__((unused)) = { ") - 1 });
});
    if (owned) {
      ({ String__Global *__sc1288 = &(self->buf);
String__Global__push_str(&(*__sc1288), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1288), (str){ .ptr = (const uint8_t*)"____free", .len = sizeof("____free") - 1 });
});
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1289 = (str){ (const uint8_t *)"0", sizeof("0") - 1 }; str__ptr(&__sc1289); })));
    }
    for (uint32_t km2 = 0U; km2 < idn_items.len; km2++) {
      const uint32_t mid = mids[((size_t)km2)];
      if (!codegen__codegen__Codegen__cg_dyn_method(self, dy.module, mid)) {
        continue;
      }
      const uint32_t mnamenode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mid)->as_data.function.name;
      codegen__codegen__Buf128 mn = (codegen__codegen__Buf128){0};
      codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, dy.module), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, dy.module))), mnamenode)->as_data.name.text, ((char *)(&mn.b[0])), 128ULL);
      ({ String__Global *__sc1290 = &(self->buf);
String__Global__push_str(&(*__sc1290), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1290), utils__errors__cstr(pp));
String__Global__push_str(&(*__sc1290), (str){ .ptr = (const uint8_t*)"__", .len = sizeof("__") - 1 });
String__Global__push_str(&(*__sc1290), utils__errors__cstr(((const char *)(&mn.b[0]))));
});
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1291 = (str){ (const uint8_t *)" };\n", sizeof(" };\n") - 1 }; str__ptr(&__sc1291); })));
  }
  if (Vector__ast__ast__DynUse__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).dyn_uses) != 0ULL) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1292 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1292); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_layout_asserts(codegen__codegen__Codegen *const self) {
  consteval__consteval__ConstEval *const ce = codegen__codegen__Codegen__ceval(self);
  if (ce == NULL) {
    return;
  }
  bool any = false;
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    const uint32_t ng = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.aggregate.generics.len;
    if (((nk != ast__ast__NodeKind_NODE_STRUCT) && (nk != ast__ast__NodeKind_NODE_ENUM)) || (ng != 0U)) {
      continue;
    }
    if ((nk == ast__ast__NodeKind_NODE_ENUM) && (!codegen__codegen__Codegen__aggregate_has_payload(self, nid))) {
      continue;
    }
    const ast__ast__TypeKind tkind = ({
      ast__ast__TypeKind __sc1293;
      if (nk == ast__ast__NodeKind_NODE_ENUM) {
        __sc1293 = ast__ast__TypeKind_TYPE_ENUM;
      } else {
        __sc1293 = ast__ast__TypeKind_TYPE_STRUCT;
      }
      __sc1293;
    });
    const uint32_t t = ast__ast__Ast__intern_type(&((*codegen__codegen__Codegen__cur_ast(self))), (ast__ast__Ty){ .kind = tkind, .module = codegen__codegen__Codegen__cur_module(self), .as_data = (ast__ast__TyAs){ .decl = nid } });
    const consteval__consteval__Layout lo = consteval__consteval__ConstEval__layout(&((*ce)), codegen__codegen__Codegen__cur_module(self), t);
    if (!lo.ok) {
      continue;
    }
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, t, ((const char *)({ __auto_type __sc1294 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1294); })), ((char *)(&nm.b[0])), 256ULL);
    ({ String__Global *__sc1295 = &(self->buf);
String__Global__push_str(&(*__sc1295), (str){ .ptr = (const uint8_t*)"_Static_assert(sizeof(", .len = sizeof("_Static_assert(sizeof(") - 1 });
String__Global__push_str(&(*__sc1295), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1295), (str){ .ptr = (const uint8_t*)") == ", .len = sizeof(") == ") - 1 });
String__Global__push_u64(&(*__sc1295), (uint64_t)(lo.size));
String__Global__push_str(&(*__sc1295), (str){ .ptr = (const uint8_t*)" && _Alignof(", .len = sizeof(" && _Alignof(") - 1 });
String__Global__push_str(&(*__sc1295), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1295), (str){ .ptr = (const uint8_t*)") == ", .len = sizeof(") == ") - 1 });
String__Global__push_u64(&(*__sc1295), (uint64_t)(lo.align));
String__Global__push_str(&(*__sc1295), (str){ .ptr = (const uint8_t*)", \"super-c layout model mismatch: ", .len = sizeof(", \"super-c layout model mismatch: ") - 1 });
String__Global__push_str(&(*__sc1295), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1295), (str){ .ptr = (const uint8_t*)"\");\n", .len = sizeof("\");\n") - 1 });
});
    (any = true);
  }
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
    if (it.module != codegen__codegen__Codegen__cur_module(self)) {
      continue;
    }
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if ((!concrete) || codegen__codegen__Codegen__inst_mentions_fnval(self, (&it))) {
      continue;
    }
    const uint32_t t = ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), it.module, it.decl, ((const uint32_t *)(&it.args[0])), it.n);
    const consteval__consteval__Layout lo = consteval__consteval__ConstEval__layout(&((*ce)), codegen__codegen__Codegen__cur_module(self), t);
    if (!lo.ok) {
      continue;
    }
    codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, t, ((const char *)({ __auto_type __sc1296 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1296); })), ((char *)(&nm.b[0])), 256ULL);
    ({ String__Global *__sc1297 = &(self->buf);
String__Global__push_str(&(*__sc1297), (str){ .ptr = (const uint8_t*)"_Static_assert(sizeof(", .len = sizeof("_Static_assert(sizeof(") - 1 });
String__Global__push_str(&(*__sc1297), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1297), (str){ .ptr = (const uint8_t*)") == ", .len = sizeof(") == ") - 1 });
String__Global__push_u64(&(*__sc1297), (uint64_t)(lo.size));
String__Global__push_str(&(*__sc1297), (str){ .ptr = (const uint8_t*)" && _Alignof(", .len = sizeof(" && _Alignof(") - 1 });
String__Global__push_str(&(*__sc1297), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1297), (str){ .ptr = (const uint8_t*)") == ", .len = sizeof(") == ") - 1 });
String__Global__push_u64(&(*__sc1297), (uint64_t)(lo.align));
String__Global__push_str(&(*__sc1297), (str){ .ptr = (const uint8_t*)", \"super-c layout model mismatch: ", .len = sizeof(", \"super-c layout model mismatch: ") - 1 });
String__Global__push_str(&(*__sc1297), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1297), (str){ .ptr = (const uint8_t*)"\");\n", .len = sizeof("\");\n") - 1 });
});
    (any = true);
  }
  if (any) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1298 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1298); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_toplevel_const(codegen__codegen__Codegen *const self, uint32_t const id) {
  const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.const_def;
  codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), cd.name, ((char *)(&nm.b[0])), 160ULL);
  codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
  codegen__codegen__Codegen__render_type_node(self, cd.ty, ((const char *)(&nm.b[0])), ((char *)(&decl.b[0])), 256ULL);
  if (cd.is_static_mut) {
    if (!cd.is_public) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1299 = (str){ (const uint8_t *)"static ", sizeof("static ") - 1 }; str__ptr(&__sc1299); })));
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1300 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc1300); })));
    codegen__codegen__Codegen__emit_initializer(self, cd.ty, cd.value);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1301 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1301); })));
    return;
  }
  if (codegen__codegen__Codegen__ceval(self) != NULL) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1302 = (str){ (const uint8_t *)"__attribute__((unused)) ", sizeof("__attribute__((unused)) ") - 1 }; str__ptr(&__sc1302); })));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1303 = (str){ (const uint8_t *)"static const ", sizeof("static const ") - 1 }; str__ptr(&__sc1303); })));
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
  if (cd.value != ast__ast__NODE_NONE) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1304 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc1304); })));
    codegen__codegen__Codegen__emit_initializer(self, cd.ty, cd.value);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1305 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1305); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_assoc_consts(codegen__codegen__Codegen *const self, bool const public_pass) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.generics.len != 0U)) || (ed.target_type == ast__ast__NODE_NONE)) {
      continue;
    }
    const ast__ast__DefId target = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type);
    if (target.node == ast__ast__NODE_NONE) {
      continue;
    }
    const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ed.items);
    for (uint32_t j = 0U; j < ed.items.len; j++) {
      const uint32_t mid = mids[((size_t)j)];
      const ast__ast__NodeKind cnk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
      if (cnk != ast__ast__NodeKind_NODE_CONST) {
        continue;
      }
      const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.const_def;
      if (self->multifile && (cd.is_public != public_pass)) {
        continue;
      }
      codegen__codegen__Buf256 nm = (codegen__codegen__Buf256){0};
      char *const np = ((char *)(&nm.b[0]));
      size_t k = codegen__codegen__Codegen__render_modpfx(self, codegen__codegen__Codegen__cur_module(self), np, 256ULL);
      int32_t bb = -1;
      if (self->package != NULL) {
        (bb = module__loader__Package__builtin_of_decl(&((*self->package)), target.module, target.node));
      }
      if (bb >= 0) {
        (k = codegen__codegen__bappend(np, 256ULL, k, codegen__codegen__builtin_name(((ast__ast__BuiltinType)bb))));
      } else {
        const lexer__token__Span tsp = codegen__codegen__Codegen__name_span_in(self, target.module, codegen__codegen__Codegen__cg_decl_name_node(self, target.module, target.node));
        (k = (k + codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, target.module), tsp, ((char *)(np + k)), (256ULL - k))));
      }
      (k = codegen__codegen__bappend(np, 256ULL, k, ((const char *)({ __auto_type __sc1306 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1306); }))));
      const lexer__token__Span csp = codegen__codegen__Codegen__name_span(self, cd.name);
      codegen__codegen__Codegen__render_ident(self, csp, ((char *)(np + k)), (256ULL - k));
      codegen__codegen__Buf320 decl = (codegen__codegen__Buf320){0};
      codegen__codegen__Codegen__render_type_node(self, cd.ty, ((const char *)np), ((char *)(&decl.b[0])), 320ULL);
      if (codegen__codegen__Codegen__ceval(self) != NULL) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1307 = (str){ (const uint8_t *)"__attribute__((unused)) ", sizeof("__attribute__((unused)) ") - 1 }; str__ptr(&__sc1307); })));
      }
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1308 = (str){ (const uint8_t *)"static const ", sizeof("static const ") - 1 }; str__ptr(&__sc1308); })));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1309 = (str){ (const uint8_t *)" = ", sizeof(" = ") - 1 }; str__ptr(&__sc1309); })));
      codegen__codegen__Codegen__emit_initializer(self, cd.ty, cd.value);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1310 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1310); })));
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_public_consts(codegen__codegen__Codegen *const self) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk != ast__ast__NodeKind_NODE_CONST) {
      continue;
    }
    const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.const_def;
    if (!cd.is_public) {
      continue;
    }
    if (cd.is_static_mut) {
      codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
      codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), cd.name, ((char *)(&nm.b[0])), 160ULL);
      codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_type_node(self, cd.ty, ((const char *)(&nm.b[0])), ((char *)(&decl.b[0])), 256ULL);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1311 = (str){ (const uint8_t *)"extern ", sizeof("extern ") - 1 }; str__ptr(&__sc1311); })));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&decl.b[0])));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1312 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1312); })));
    } else {
      codegen__codegen__Codegen__emit_toplevel_const(self, nid);
    }
  }
  codegen__codegen__Codegen__emit_assoc_consts(self, true);
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_referenced_fwd(codegen__codegen__Codegen *const self) {
  const uint16_t cur = codegen__codegen__Codegen__cur_module(self);
  const size_t np = Vector__ast__ast__Ty__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).type_pool);
  for (size_t i = 0ULL; i < np; i++) {
    const ast__ast__Ty t = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)i)));
    if (t.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), t.as_data.inst));
      if ((it.module == cur) || (((size_t)it.module) >= codegen__codegen__Codegen__pkg_count(self))) {
        continue;
      }
      bool concrete = true;
      for (uint8_t k = 0U; k < it.n; k++) {
        if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
          (concrete = false);
        }
      }
      if (!concrete) {
        continue;
      }
      const ast__ast__NodeKind idn_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), it.decl)->kind;
      if ((idn_kind == ast__ast__NodeKind_NODE_STRUCT) || codegen__codegen__Codegen__aggregate_has_payload_in(self, it.module, it.decl)) {
        const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), it.decl));
        codegen__codegen__Buf200 inm = (codegen__codegen__Buf200){0};
        codegen__codegen__Codegen__inst_name(self, (&it), ((char *)(&inm.b[0])), 200ULL);
        ({ String__Global *__sc1313 = &(self->buf);
String__Global__push_str(&(*__sc1313), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1313), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1313), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1313), utils__errors__cstr(((const char *)(&inm.b[0]))));
String__Global__push_str(&(*__sc1313), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1313), utils__errors__cstr(((const char *)(&inm.b[0]))));
String__Global__push_str(&(*__sc1313), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
      }
      continue;
    }
    if ((t.module == cur) || (((size_t)t.module) >= codegen__codegen__Codegen__pkg_count(self))) {
      continue;
    }
    if ((self->package != NULL) && (module__loader__Package__builtin_of_decl(&((*self->package)), t.module, t.as_data.decl) >= 0)) {
      continue;
    }
    if ((t.kind == ast__ast__TypeKind_TYPE_STRUCT) || ((t.kind == ast__ast__TypeKind_TYPE_ENUM) && codegen__codegen__Codegen__aggregate_has_payload_in(self, t.module, t.as_data.decl))) {
      const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, t.module))), t.as_data.decl));
      const uint32_t anm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, t.module))), t.as_data.decl)->as_data.aggregate.name;
      codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
      codegen__codegen__Codegen__render_qualified(self, t.module, anm, ((char *)(&nm.b[0])), 160ULL);
      ({ String__Global *__sc1314 = &(self->buf);
String__Global__push_str(&(*__sc1314), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1314), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1314), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1314), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1314), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1314), utils__errors__cstr(((const char *)(&nm.b[0]))));
String__Global__push_str(&(*__sc1314), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
    } else if (t.kind == ast__ast__TypeKind_TYPE_ENUM) {
      ast__ast__Ast *const sa = codegen__codegen__Codegen__cur_ast(self);
      const uint8_t *const ss = self->source;
      const size_t sl = self->len;
      const uint16_t tmod = t.module;
      const uint32_t tdecl = t.as_data.decl;
      (self->source = codegen__codegen__Codegen__mod_src(self, tmod));
      (self->len = String__Global__len(&(*({ __auto_type __sc1315 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1315, ((size_t)tmod)); })).source));
      (self->ast = codegen__codegen__Codegen__mod_ast(self, tmod));
      codegen__codegen__Codegen__emit_enum_full(self, tdecl);
      (self->ast = sa);
      (self->source = ss);
      (self->len = sl);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_referenced_includes(codegen__codegen__Codegen *const self) {
  const size_t nmod = codegen__codegen__Codegen__pkg_count(self);
  const uint16_t cur = codegen__codegen__Codegen__cur_module(self);
  bool *const want = ((bool *)calloc(({
    size_t __sc1316;
    if (nmod != 0ULL) {
      __sc1316 = nmod;
    } else {
      __sc1316 = 1ULL;
    }
    __sc1316;
  }), 1ULL));
  if (want == NULL) {
    return;
  }
  for (size_t i = 0ULL; i < Vector__ast__ast__DefId__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).resolutions); i++) {
    const ast__ast__DefId d = (*({ __auto_type __sc1317 = &(*codegen__codegen__Codegen__cur_ast(self)).resolutions; Vector__ast__ast__DefId__Global__index(__sc1317, i); }));
    if (((d.node == ast__ast__NODE_NONE) || (d.module == cur)) || (((size_t)d.module) >= nmod)) {
      continue;
    }
    if (codegen__codegen__Codegen__cg_decl_is_interface_member(self, d.module, d.node)) {
      continue;
    }
    if (module__loader__Package__builtin_of_decl(&((*self->package)), d.module, d.node) >= 0) {
      continue;
    }
    (want[((size_t)d.module)] = true);
  }
  for (size_t ti = 0ULL; ti < Vector__ast__ast__Ty__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).type_pool); ti++) {
    const ast__ast__Ty t = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ti)));
    if (((((t.kind != ast__ast__TypeKind_TYPE_STRUCT) && (t.kind != ast__ast__TypeKind_TYPE_ENUM)) && (t.kind != ast__ast__TypeKind_TYPE_FUNCTION)) || (t.module == cur)) || (((size_t)t.module) >= nmod)) {
      continue;
    }
    if (module__loader__Package__builtin_of_decl(&((*self->package)), t.module, t.as_data.decl) >= 0) {
      continue;
    }
    if ((t.kind == ast__ast__TypeKind_TYPE_FUNCTION) && codegen__codegen__Codegen__cg_decl_is_interface_member(self, t.module, t.as_data.decl)) {
      continue;
    }
    (want[((size_t)t.module)] = true);
  }
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
    bool concrete = ((((size_t)it.module) < nmod) || (it.module == cur));
    uint8_t k = 0U;
    while ((k < it.n) && concrete) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
      (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
    }
    if (!concrete) {
      continue;
    }
    const uint16_t home = module__loader__Package__instance_home(&((*self->package)), (&(*codegen__codegen__Codegen__cur_ast(self))), (&it));
    if ((it.module != cur) && (((size_t)it.module) < nmod)) {
      (want[((size_t)it.module)] = true);
    }
    if ((home != cur) && (((size_t)home) < nmod)) {
      (want[((size_t)home)] = true);
    }
  }
  if (((*self->package).core_seeded && ((*self->package).core_module != cur)) && (((size_t)(*self->package).core_module) < nmod)) {
    bool need_core = false;
    size_t ci = 0ULL;
    while ((ci < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances)) && (!need_core)) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ci)));
      bool concrete = ((((size_t)it.module) < nmod) || (it.module == cur));
      uint8_t k = 0U;
      while ((k < it.n) && concrete) {
        if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
          (concrete = false);
        }
        (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
      }
      uint8_t k2 = 0U;
      while (((k2 < it.n) && concrete) && (!need_core)) {
        if (codegen__codegen__Codegen__type_mentions_builtin(self, it.args[((size_t)k2)])) {
          (need_core = true);
        }
        (k2 = ((uint8_t)((uint32_t)k2 + (uint32_t)1U)));
      }
      (ci = (ci + 1ULL));
    }
    int32_t ni = 0;
    while ((ni < self->ninsts) && (!need_core)) {
      uint8_t k = 0U;
      while ((k < self->insts[((size_t)ni)].n) && (!need_core)) {
        if (codegen__codegen__Codegen__type_mentions_builtin(self, self->insts[((size_t)ni)].args[((size_t)k)])) {
          (need_core = true);
        }
        (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
      }
      (ni = ({ int32_t __sc_r; if (__builtin_add_overflow(ni, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
    if (need_core) {
      (want[((size_t)(*self->package).core_module)] = true);
    }
  }
  for (size_t m = 0ULL; m < nmod; m++) {
    if (want[m]) {
      codegen__codegen__Codegen__emit_modpath_include(self, String__Global__as_str(&(*({ __auto_type __sc1318 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1318, m); })).path));
    }
  }
  free(((void *)want));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_header_includes(codegen__codegen__Codegen *const self) {
  const size_t nmod = codegen__codegen__Codegen__pkg_count(self);
  const uint16_t cur = codegen__codegen__Codegen__cur_module(self);
  bool *const want = ((bool *)calloc(({
    size_t __sc1319;
    if (nmod != 0ULL) {
      __sc1319 = nmod;
    } else {
      __sc1319 = 1ULL;
    }
    __sc1319;
  }), 1ULL));
  if (want == NULL) {
    return;
  }
  const int32_t saved = self->nsubst;
  (self->nsubst = 0);
  bool pub_const_expr = false;
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (((nk == ast__ast__NodeKind_NODE_STRUCT) || (nk == ast__ast__NodeKind_NODE_ENUM)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.aggregate.generics.len == 0U)) {
      codegen__codegen__Codegen__mark_aggregate_layout(self, nid, want, nmod);
    } else if ((nk == ast__ast__NodeKind_NODE_FUNCTION) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.function.returns.len > 1U)) {
      const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.function.returns;
      const uint32_t *const rids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), rets);
      for (uint32_t r = 0U; r < rets.len; r++) {
        const uint32_t rid = rids[((size_t)r)];
        const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), rid);
        const uint32_t rtn = ({
          uint32_t __sc1320;
          if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
            __sc1320 = rn->as_data.parameter.ty;
          } else {
            __sc1320 = rid;
          }
          __sc1320;
        });
        codegen__codegen__Codegen__mark_layout_module(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), rtn), want, nmod);
      }
    } else if (nk == ast__ast__NodeKind_NODE_CONST) {
      const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.const_def;
      if (!cd.is_extern) {
        codegen__codegen__Codegen__mark_layout_module(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), cd.ty), want, nmod);
        if ((cd.is_public && (cd.value != ast__ast__NODE_NONE)) && (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), cd.value)->kind != ast__ast__NodeKind_NODE_LITERAL)) {
          (pub_const_expr = true);
        }
      }
    }
  }
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
    bool concrete = ((((size_t)it.module) < nmod) || (it.module == cur));
    uint8_t k = 0U;
    while ((k < it.n) && concrete) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
      (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
    }
    if (!concrete) {
      continue;
    }
    const uint16_t home = module__loader__Package__instance_home(&((*self->package)), (&(*codegen__codegen__Codegen__cur_ast(self))), (&it));
    if (home != cur) {
      continue;
    }
    if (it.module == cur) {
      const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), it.decl)->as_data.aggregate;
      const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ag.generics);
      (self->nsubst = 0);
      uint32_t g = 0U;
      while (((g < ag.generics.len) && (g < ((uint32_t)it.n))) && (self->nsubst < 16)) {
        (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = it.module, .node = gids[((size_t)g)] });
        (self->subst[((size_t)self->nsubst)].concrete = it.args[((size_t)g)]);
        (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (g = (g + 1U));
      }
      codegen__codegen__Codegen__mark_aggregate_layout(self, it.decl, want, nmod);
      (self->nsubst = 0);
    } else {
      if (((size_t)it.module) < nmod) {
        (want[((size_t)it.module)] = true);
      }
      for (uint8_t k2 = 0U; k2 < it.n; k2++) {
        codegen__codegen__Codegen__mark_layout_module(self, it.args[((size_t)k2)], want, nmod);
      }
    }
  }
  (self->nsubst = saved);
  if (pub_const_expr) {
    for (size_t ri = 0ULL; ri < Vector__ast__ast__DefId__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).resolutions); ri++) {
      const ast__ast__DefId d = (*({ __auto_type __sc1321 = &(*codegen__codegen__Codegen__cur_ast(self)).resolutions; Vector__ast__ast__DefId__Global__index(__sc1321, ri); }));
      if ((((d.node != ast__ast__NODE_NONE) && (d.module != cur)) && (((size_t)d.module) < nmod)) && (!codegen__codegen__Codegen__cg_decl_is_interface_member(self, d.module, d.node))) {
        (want[((size_t)d.module)] = true);
      }
    }
    for (size_t ti = 0ULL; ti < Vector__ast__ast__Ty__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).type_pool); ti++) {
      const ast__ast__Ty t = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ti)));
      if (((((t.kind == ast__ast__TypeKind_TYPE_STRUCT) || (t.kind == ast__ast__TypeKind_TYPE_ENUM)) && (t.module != cur)) && (((size_t)t.module) < nmod)) && (module__loader__Package__builtin_of_decl(&((*self->package)), t.module, t.as_data.decl) < 0)) {
        (want[((size_t)t.module)] = true);
      }
    }
  }
  for (size_t m = 0ULL; m < nmod; m++) {
    if ((m != ((size_t)cur)) && want[m]) {
      codegen__codegen__Codegen__emit_modpath_include(self, String__Global__as_str(&(*({ __auto_type __sc1322 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1322, m); })).path));
    }
  }
  free(((void *)want));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_extern_includes(codegen__codegen__Codegen *const self) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  uint32_t i = 0U;
  while (i < items.len) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk != ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
      (i = (i + 1U));
      continue;
    }
    const uint32_t hdr = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extern_block.header;
    if (hdr == ast__ast__NODE_NONE) {
      (i = (i + 1U));
      continue;
    }
    const lexer__token__Span hs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), hdr)->span;
    const uint32_t s = (hs.start + 1U);
    const uint32_t e = (hs.end - 1U);
    if (e <= s) {
      (i = (i + 1U));
      continue;
    }
    bool dup = false;
    uint32_t j = 0U;
    while ((j < i) && (!dup)) {
      const uint32_t mid = ids[((size_t)j)];
      if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
        const uint32_t mh = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.extern_block.header;
        if (mh != ast__ast__NODE_NONE) {
          const lexer__token__Span ms = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mh)->span;
          if (((ms.end - ms.start) == (hs.end - hs.start)) && (memcmp((self->source + ((size_t)ms.start)), (self->source + ((size_t)hs.start)), ((size_t)(hs.end - hs.start))) == 0)) {
            (dup = true);
          }
        }
      }
      (j = (j + 1U));
    }
    if (dup) {
      (i = (i + 1U));
      continue;
    }
    bool done = false;
    const uint16_t cm = codegen__codegen__Codegen__cur_module(self);
    if ((self->package != NULL) && (((size_t)cm) < Vector__module__loader__Module__Global__len(&(*self->package).modules))) {
      if (String__Global__len(&(*({ __auto_type __sc1323 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1323, ((size_t)cm)); })).file) != 0ULL) {
        const char *const file = String__Global__cstr(&(*({ __auto_type __sc1324 = &(*self->package).modules; Vector__module__loader__Module__Global__index_mut(__sc1324, ((size_t)cm)); })).file);
        codegen__codegen__Buf4096 rel = (codegen__codegen__Buf4096){0};
        const char *const hp = ((const char *)(self->source + ((size_t)s)));
        const int32_t hlen = ((int32_t)(e - s));
        char *const slash = strrchr(file, 47);
        if (slash != NULL) {
          const int32_t dlen = ((int32_t)(((size_t)slash) - ((size_t)file)));
          snprintf(((char *)(&rel.b[0])), 4096ULL, ((const char *)({ __auto_type __sc1325 = (str){ (const uint8_t *)"%.*s/%.*s", sizeof("%.*s/%.*s") - 1 }; str__ptr(&__sc1325); })), dlen, file, hlen, hp);
        } else {
          snprintf(((char *)(&rel.b[0])), 4096ULL, ((const char *)({ __auto_type __sc1326 = (str){ (const uint8_t *)"./%.*s", sizeof("./%.*s") - 1 }; str__ptr(&__sc1326); })), hlen, hp);
        }
        codegen__codegen__Buf4096 absb = (codegen__codegen__Buf4096){0};
        codegen__codegen__Buf4096 rootb = (codegen__codegen__Buf4096){0};
        char *const ra = sc_realpath(((const char *)(&rel.b[0])), ((char *)(&absb.b[0])));
        char *const rr = sc_realpath(String__Global__cstr(&(*self->package).root_dir), ((char *)(&rootb.b[0])));
        if ((ra != NULL) && (rr != NULL)) {
          const size_t rl = strlen(((const char *)(&rootb.b[0])));
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1327 = (str){ (const uint8_t *)"#include \"", sizeof("#include \"") - 1 }; str__ptr(&__sc1327); })));
          if ((strncmp(((const char *)(&absb.b[0])), ((const char *)(&rootb.b[0])), rl) == 0) && (absb.b[rl] == 47)) {
            codegen__codegen__Codegen__emit_rel_prefix(self);
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1328 = (str){ (const uint8_t *)"../", sizeof("../") - 1 }; str__ptr(&__sc1328); })));
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)(((const char *)(&absb.b[0])) + (rl + 1ULL))));
          } else {
            codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&absb.b[0])));
          }
          codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1329 = (str){ (const uint8_t *)"\"\n", sizeof("\"\n") - 1 }; str__ptr(&__sc1329); })));
          (done = true);
        }
      }
    }
    if (!done) {
      const bool local = ((self->source[((size_t)s)] == 46U) || (self->source[((size_t)s)] == 47U));
      if (local) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1330 = (str){ (const uint8_t *)"#include \"", sizeof("#include \"") - 1 }; str__ptr(&__sc1330); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1331 = (str){ (const uint8_t *)"#include <", sizeof("#include <") - 1 }; str__ptr(&__sc1331); })));
      }
      codegen__codegen__Codegen__emit_bytes(self, ((const char *)(self->source + ((size_t)s))), ((size_t)(e - s)));
      if (local) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1332 = (str){ (const uint8_t *)"\"\n", sizeof("\"\n") - 1 }; str__ptr(&__sc1332); })));
      } else {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1333 = (str){ (const uint8_t *)">\n", sizeof(">\n") - 1 }; str__ptr(&__sc1333); })));
      }
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_includes(codegen__codegen__Codegen *const self) {
  const str p = String__Global__as_str(&(*({ __auto_type __sc1334 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1334, ((size_t)codegen__codegen__Codegen__cur_module(self))); })).path);
  codegen__codegen__Codegen__emit_modpath_include(self, p);
  codegen__codegen__Codegen__emit_referenced_includes(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1335 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1335); })));
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_test_type(codegen__codegen__Codegen *const self, ast__ast__DefId const d, bool const is_enum) {
  const ast__ast__TypeKind tk = ({
    ast__ast__TypeKind __sc1336;
    if (is_enum) {
      __sc1336 = ast__ast__TypeKind_TYPE_ENUM;
    } else {
      __sc1336 = ast__ast__TypeKind_TYPE_STRUCT;
    }
    __sc1336;
  });
  return ast__ast__Ast__intern_type(&((*codegen__codegen__Codegen__cur_ast(self))), (ast__ast__Ty){ .kind = tk, .module = d.module, .as_data = (ast__ast__TyAs){ .decl = d.node } });
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_test_wrappers(codegen__codegen__Codegen *const self) {
  if ((!self->test.enabled) || ((self->test.ncases == 0U) && (self->test.genv_init == ast__ast__NODE_NONE))) {
    return;
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1337 = (str){ (const uint8_t *)"\n/* --test wrappers */\n", sizeof("\n/* --test wrappers */\n") - 1 }; str__ptr(&__sc1337); })));
  for (uint32_t i = 0U; i < self->test.ncases; i++) {
    const codegen__codegen__CgTestCase tc = self->test.cases[((size_t)i)];
    const bool suite = (tc.suite.node != ast__ast__NODE_NONE);
    const ast__ast__DefId fx_type = ({
      ast__ast__DefId __sc1338;
      if (suite) {
        __sc1338 = tc.suite;
      } else {
        __sc1338 = self->test.fx_type;
      }
      __sc1338;
    });
    const bool fx_is_enum = ({
      bool __sc1339;
      if (suite) {
        __sc1339 = tc.suite_is_enum;
      } else {
        __sc1339 = self->test.fx_is_enum;
      }
      __sc1339;
    });
    const uint32_t fx_init = ({
      uint32_t __sc1340;
      if (suite) {
        __sc1340 = tc.suite_init;
      } else {
        __sc1340 = self->test.fx_init;
      }
      __sc1340;
    });
    const uint32_t fx_free = ({
      uint32_t __sc1341;
      if (suite) {
        __sc1341 = tc.suite_free;
      } else {
        __sc1341 = self->test.fx_free;
      }
      __sc1341;
    });
    const ast__ast__DefId target = ({
      ast__ast__DefId __sc1342;
      if (suite) {
        __sc1342 = tc.suite;
      } else {
        __sc1342 = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
      }
      __sc1342;
    });
    codegen__codegen__Buf240 fname = (codegen__codegen__Buf240){0};
    codegen__codegen__Codegen__function_name(self, tc.func, target, ((char *)(&fname.b[0])), 240ULL, true);
    ({ String__Global *__sc1343 = &(self->buf);
String__Global__push_str(&(*__sc1343), (str){ .ptr = (const uint8_t*)"void __sc_test_w_", .len = sizeof("void __sc_test_w_") - 1 });
String__Global__push_u64(&(*__sc1343), (uint64_t)(((uint32_t)codegen__codegen__Codegen__cur_module(self))));
String__Global__push_str(&(*__sc1343), (str){ .ptr = (const uint8_t*)"_", .len = sizeof("_") - 1 });
String__Global__push_u64(&(*__sc1343), (uint64_t)(tc.func));
String__Global__push_str(&(*__sc1343), (str){ .ptr = (const uint8_t*)"(void *__genv) {\n  (void)__genv;\n", .len = sizeof("(void *__genv) {\n  (void)__genv;\n") - 1 });
});
    if ((tc.wants & 1U) != 0U) {
      const uint32_t fxt = codegen__codegen__Codegen__cg_test_type(self, fx_type, fx_is_enum);
      codegen__codegen__Buf256 decl = (codegen__codegen__Buf256){0};
      codegen__codegen__Codegen__render_type_id(self, fxt, ((const char *)({ __auto_type __sc1344 = (str){ (const uint8_t *)"__fx", sizeof("__fx") - 1 }; str__ptr(&__sc1344); })), ((char *)(&decl.b[0])), 256ULL);
      codegen__codegen__Buf240 init = (codegen__codegen__Buf240){0};
      codegen__codegen__Codegen__function_name(self, fx_init, target, ((char *)(&init.b[0])), 240ULL, true);
      ({ String__Global *__sc1345 = &(self->buf);
String__Global__push_str(&(*__sc1345), (str){ .ptr = (const uint8_t*)"  ", .len = sizeof("  ") - 1 });
String__Global__push_str(&(*__sc1345), utils__errors__cstr(((const char *)(&decl.b[0]))));
String__Global__push_str(&(*__sc1345), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
String__Global__push_str(&(*__sc1345), utils__errors__cstr(((const char *)(&init.b[0]))));
String__Global__push_str(&(*__sc1345), (str){ .ptr = (const uint8_t*)"();\n", .len = sizeof("();\n") - 1 });
});
    }
    ({ String__Global *__sc1346 = &(self->buf);
String__Global__push_str(&(*__sc1346), (str){ .ptr = (const uint8_t*)"  ", .len = sizeof("  ") - 1 });
String__Global__push_str(&(*__sc1346), utils__errors__cstr(((const char *)(&fname.b[0]))));
String__Global__push_str(&(*__sc1346), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
});
    if ((tc.wants & 1U) != 0U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1347 = (str){ (const uint8_t *)"&__fx", sizeof("&__fx") - 1 }; str__ptr(&__sc1347); })));
    }
    if ((tc.wants & 2U) != 0U) {
      const uint32_t gt = codegen__codegen__Codegen__cg_test_type(self, self->test.genv_type, self->test.genv_is_enum);
      codegen__codegen__Buf200 gty = (codegen__codegen__Buf200){0};
      codegen__codegen__Codegen__render_type_id(self, gt, ((const char *)({ __auto_type __sc1348 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1348); })), ((char *)(&gty.b[0])), 200ULL);
      const char *const sep = ({
        const char *__sc1349;
        if ((tc.wants & 1U) != 0U) {
          __sc1349 = ((const char *)({ __auto_type __sc1350 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc1350); }));
        } else {
          __sc1349 = ((const char *)({ __auto_type __sc1351 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1351); }));
        }
        __sc1349;
      });
      ({ String__Global *__sc1352 = &(self->buf);
String__Global__push_str(&(*__sc1352), utils__errors__cstr(sep));
String__Global__push_str(&(*__sc1352), (str){ .ptr = (const uint8_t*)"(const ", .len = sizeof("(const ") - 1 });
String__Global__push_str(&(*__sc1352), utils__errors__cstr(((const char *)(&gty.b[0]))));
String__Global__push_str(&(*__sc1352), (str){ .ptr = (const uint8_t*)" *)__genv", .len = sizeof(" *)__genv") - 1 });
});
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1353 = (str){ (const uint8_t *)");\n", sizeof(");\n") - 1 }; str__ptr(&__sc1353); })));
    if (((tc.wants & 1U) != 0U) && (fx_free != ast__ast__NODE_NONE)) {
      codegen__codegen__Buf240 fre = (codegen__codegen__Buf240){0};
      codegen__codegen__Codegen__function_name(self, fx_free, target, ((char *)(&fre.b[0])), 240ULL, true);
      ({ String__Global *__sc1354 = &(self->buf);
String__Global__push_str(&(*__sc1354), (str){ .ptr = (const uint8_t*)"  ", .len = sizeof("  ") - 1 });
String__Global__push_str(&(*__sc1354), utils__errors__cstr(((const char *)(&fre.b[0]))));
String__Global__push_str(&(*__sc1354), (str){ .ptr = (const uint8_t*)"(&__fx);\n", .len = sizeof("(&__fx);\n") - 1 });
});
    }
    if ((tc.wants & 1U) != 0U) {
      const uint32_t fxt = codegen__codegen__Codegen__cg_test_type(self, fx_type, fx_is_enum);
      if (codegen__codegen__Codegen__cg_type_is_free(self, fxt)) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1355 = (str){ (const uint8_t *)"  ", sizeof("  ") - 1 }; str__ptr(&__sc1355); })));
        codegen__codegen__Codegen__emit_free_target(self, fxt);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1356 = (str){ (const uint8_t *)"(&__fx);\n", sizeof("(&__fx);\n") - 1 }; str__ptr(&__sc1356); })));
      }
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1357 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc1357); })));
  }
  if (self->test.genv_init != ast__ast__NODE_NONE) {
    const uint32_t gt = codegen__codegen__Codegen__cg_test_type(self, self->test.genv_type, self->test.genv_is_enum);
    codegen__codegen__Buf256 gdecl = (codegen__codegen__Buf256){0};
    codegen__codegen__Codegen__render_type_id(self, gt, ((const char *)({ __auto_type __sc1358 = (str){ (const uint8_t *)"__sc_genv", sizeof("__sc_genv") - 1 }; str__ptr(&__sc1358); })), ((char *)(&gdecl.b[0])), 256ULL);
    codegen__codegen__Buf200 gty = (codegen__codegen__Buf200){0};
    codegen__codegen__Codegen__render_type_id(self, gt, ((const char *)({ __auto_type __sc1359 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1359); })), ((char *)(&gty.b[0])), 200ULL);
    const uint32_t giname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), self->test.genv_init)->as_data.function.name;
    codegen__codegen__Buf200 init = (codegen__codegen__Buf200){0};
    codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), giname, ((char *)(&init.b[0])), 200ULL);
    ({ String__Global *__sc1360 = &(self->buf);
String__Global__push_str(&(*__sc1360), (str){ .ptr = (const uint8_t*)"void *__sc_test_genv_init(void) { static ", .len = sizeof("void *__sc_test_genv_init(void) { static ") - 1 });
String__Global__push_str(&(*__sc1360), utils__errors__cstr(((const char *)(&gdecl.b[0]))));
String__Global__push_str(&(*__sc1360), (str){ .ptr = (const uint8_t*)"; __sc_genv = ", .len = sizeof("; __sc_genv = ") - 1 });
String__Global__push_str(&(*__sc1360), utils__errors__cstr(((const char *)(&init.b[0]))));
String__Global__push_str(&(*__sc1360), (str){ .ptr = (const uint8_t*)"(); return &__sc_genv; }\n", .len = sizeof("(); return &__sc_genv; }\n") - 1 });
});
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1361 = (str){ (const uint8_t *)"void __sc_test_genv_free(void *__p) {\n  (void)__p;\n", sizeof("void __sc_test_genv_free(void *__p) {\n  (void)__p;\n") - 1 }; str__ptr(&__sc1361); })));
    if (self->test.genv_free != ast__ast__NODE_NONE) {
      const uint32_t gfname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), self->test.genv_free)->as_data.function.name;
      codegen__codegen__Buf200 fre = (codegen__codegen__Buf200){0};
      codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), gfname, ((char *)(&fre.b[0])), 200ULL);
      ({ String__Global *__sc1362 = &(self->buf);
String__Global__push_str(&(*__sc1362), (str){ .ptr = (const uint8_t*)"  ", .len = sizeof("  ") - 1 });
String__Global__push_str(&(*__sc1362), utils__errors__cstr(((const char *)(&fre.b[0]))));
String__Global__push_str(&(*__sc1362), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc1362), utils__errors__cstr(((const char *)(&gty.b[0]))));
String__Global__push_str(&(*__sc1362), (str){ .ptr = (const uint8_t*)" *)__p);\n", .len = sizeof(" *)__p);\n") - 1 });
});
    }
    if (codegen__codegen__Codegen__cg_type_is_free(self, gt)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1363 = (str){ (const uint8_t *)"  ", sizeof("  ") - 1 }; str__ptr(&__sc1363); })));
      codegen__codegen__Codegen__emit_free_target(self, gt);
      ({ String__Global *__sc1364 = &(self->buf);
String__Global__push_str(&(*__sc1364), (str){ .ptr = (const uint8_t*)"((", .len = sizeof("((") - 1 });
String__Global__push_str(&(*__sc1364), utils__errors__cstr(((const char *)(&gty.b[0]))));
String__Global__push_str(&(*__sc1364), (str){ .ptr = (const uint8_t*)" *)__p);\n", .len = sizeof(" *)__p);\n") - 1 });
});
    }
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1365 = (str){ (const uint8_t *)"}\n", sizeof("}\n") - 1 }; str__ptr(&__sc1365); })));
  }
}

void codegen__codegen__Codegen__codegen_emit_header(codegen__codegen__Codegen *const self, FILE *const out) {
  codegen__codegen__Codegen__build_enum_index(self);
  codegen__codegen__Buf160 guard = (codegen__codegen__Buf160){0};
  char *const np = ((char *)(&guard.b[0]));
  size_t at = codegen__codegen__bappend(np, 160ULL, 0ULL, ((const char *)({ __auto_type __sc1366 = (str){ (const uint8_t *)"SUPER_", sizeof("SUPER_") - 1 }; str__ptr(&__sc1366); })));
  const str mp = String__Global__as_str(&(*({ __auto_type __sc1367 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1367, ((size_t)codegen__codegen__Codegen__cur_module(self))); })).path);
  const size_t n = str__len(&mp);
  size_t i = 0ULL;
  while ((i < n) && ((at + 2ULL) < 160ULL)) {
    if (((str__byte_at(&mp, i) == 58U) && ((i + 1ULL) < n)) && (str__byte_at(&mp, (i + 1ULL)) == 58U)) {
      (guard.b[at] = 95);
      (guard.b[(at + 1ULL)] = 95);
      (at = (at + 2ULL));
      (i = (i + 1ULL));
    } else {
      (guard.b[at] = ((char)str__byte_at(&mp, i)));
      (at = (at + 1ULL));
    }
    (i = (i + 1ULL));
  }
  (guard.b[at] = 0);
  codegen__codegen__bappend(np, 160ULL, at, ((const char *)({ __auto_type __sc1368 = (str){ (const uint8_t *)"_H", sizeof("_H") - 1 }; str__ptr(&__sc1368); })));
  size_t gi = 0ULL;
  while (guard.b[gi] != 0) {
    const char ch = guard.b[gi];
    if ((ch >= 97) && (ch <= 122)) {
      (guard.b[gi] = ((char)({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)ch), 32, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
    }
    (gi = (gi + 1ULL));
  }
  const char *const gp = ((const char *)np);
  ({ String__Global *__sc1369 = &(self->buf);
String__Global__push_str(&(*__sc1369), (str){ .ptr = (const uint8_t*)"#ifndef ", .len = sizeof("#ifndef ") - 1 });
String__Global__push_str(&(*__sc1369), utils__errors__cstr(gp));
String__Global__push_str(&(*__sc1369), (str){ .ptr = (const uint8_t*)"\n#define ", .len = sizeof("\n#define ") - 1 });
String__Global__push_str(&(*__sc1369), utils__errors__cstr(gp));
String__Global__push_str(&(*__sc1369), (str){ .ptr = (const uint8_t*)"\n\n", .len = sizeof("\n\n") - 1 });
});
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1370 = (str){ (const uint8_t *)"#include \"", sizeof("#include \"") - 1 }; str__ptr(&__sc1370); })));
  codegen__codegen__Codegen__emit_rel_prefix(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1371 = (str){ (const uint8_t *)"super_rt.h\"\n", sizeof("super_rt.h\"\n") - 1 }; str__ptr(&__sc1371); })));
  codegen__codegen__Codegen__emit_extern_includes(self);
  codegen__codegen__Codegen__emit_referenced_fwd(self);
  codegen__codegen__Codegen__emit_header_includes(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1372 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1372); })));
  codegen__codegen__Codegen__phase_forward(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1373 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1373); })));
  codegen__codegen__Codegen__phase_types(self);
  codegen__codegen__Codegen__phase_ret_structs(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1374 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1374); })));
  codegen__codegen__Codegen__phase_prototypes(self, codegen__codegen__PROTO_PUBLIC);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1375 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1375); })));
  codegen__codegen__Codegen__emit_public_consts(self);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1376 = (str){ (const uint8_t *)"\n#endif\n", sizeof("\n#endif\n") - 1 }; str__ptr(&__sc1376); })));
  if (String__Global__len(&self->buf) != 0ULL) {
    fwrite(((const void *)String__Global__as_ptr(&self->buf)), 1ULL, String__Global__len(&self->buf), out);
  }
  String__Global__clear(&self->buf);
}

void codegen__codegen__Codegen__codegen_emit(codegen__codegen__Codegen *const self, FILE *const out) {
  codegen__codegen__Codegen__build_enum_index(self);
  codegen__codegen__Codegen__collect_insts(self);
  codegen__codegen__Codegen__collect_callbacks(self);
  if (self->multifile) {
    codegen__codegen__Codegen__emit_includes(self);
    codegen__codegen__Codegen__emit_layout_asserts(self);
    codegen__codegen__Codegen__phase_prototypes(self, codegen__codegen__PROTO_PRIVATE);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1377 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1377); })));
    codegen__codegen__Codegen__emit_dyn_tables(self);
    codegen__codegen__Codegen__phase_bodies(self);
    codegen__codegen__Codegen__emit_test_wrappers(self);
  } else {
    codegen__codegen__Codegen__emit_cstr(self, codegen__codegen__super_rt_includes());
    codegen__codegen__Codegen__emit_extern_includes(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1378 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1378); })));
    codegen__codegen__Codegen__phase_forward(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1379 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1379); })));
    codegen__codegen__Codegen__phase_types(self);
    codegen__codegen__Codegen__phase_ret_structs(self);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1380 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1380); })));
    codegen__codegen__Codegen__emit_layout_asserts(self);
    codegen__codegen__Codegen__phase_prototypes(self, codegen__codegen__PROTO_ALL);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1381 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1381); })));
    codegen__codegen__Codegen__emit_dyn_tables(self);
    codegen__codegen__Codegen__phase_bodies(self);
    codegen__codegen__Codegen__emit_test_wrappers(self);
  }
  const uint8_t *const src = self->source;
  const size_t ln = self->len;
  const char *file = NULL;
  if ((self->package != NULL) && (((size_t)codegen__codegen__Codegen__cur_module(self)) < codegen__codegen__Codegen__pkg_count(self))) {
    (file = String__Global__cstr(&(*({ __auto_type __sc1382 = &(*self->package).modules; Vector__module__loader__Module__Global__index_mut(__sc1382, ((size_t)codegen__codegen__Codegen__cur_module(self))); })).file));
  }
  utils__errors__Errors__finalize(&self->errors, src, ln, file);
  if (String__Global__len(&self->buf) != 0ULL) {
    fwrite(((const void *)String__Global__as_ptr(&self->buf)), 1ULL, String__Global__len(&self->buf), out);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__seed_emitted_type_instances(codegen__codegen__Codegen *const self) {
  for (int32_t pass = 0; pass < 32; pass++) {
    if (!codegen__codegen__Codegen__seed_emitted_generic_method_signature_instances(self)) {
      return;
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__phase_forward(codegen__codegen__Codegen *const self) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk == ast__ast__NodeKind_NODE_STRUCT) {
      const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.aggregate;
      if (ag.generics.len != 0U) {
        continue;
      }
      const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid));
      ({ String__Global *__sc1383 = &(self->buf);
String__Global__push_str(&(*__sc1383), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1383), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1383), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
      codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1384 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1384); })));
      codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1385 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1385); })));
    } else if (nk == ast__ast__NodeKind_NODE_ENUM) {
      const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.aggregate;
      if (ag.generics.len != 0U) {
        continue;
      }
      if (!codegen__codegen__Codegen__aggregate_has_payload(self, nid)) {
        codegen__codegen__Codegen__emit_enum_full(self, nid);
        continue;
      }
      codegen__codegen__Codegen__emit_enum_tag_decl(self, nid);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1386 = (str){ (const uint8_t *)"typedef struct ", sizeof("typedef struct ") - 1 }; str__ptr(&__sc1386); })));
      codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1387 = (str){ (const uint8_t *)" ", sizeof(" ") - 1 }; str__ptr(&__sc1387); })));
      codegen__codegen__Codegen__emit_local_type_name(self, ag.name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1388 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1388); })));
    } else if (nk == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
      const ast__ast__TypeAliasData ta = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.type_alias;
      if (((ta.ty != ast__ast__NODE_NONE) && (ta.generics.len == 0U)) && codegen__codegen__Codegen__cg_alias_extended(self, codegen__codegen__Codegen__cur_module(self), nid)) {
        codegen__codegen__Buf160 nm = (codegen__codegen__Buf160){0};
        codegen__codegen__Codegen__render_qualified(self, codegen__codegen__Codegen__cur_module(self), ta.name, ((char *)(&nm.b[0])), 160ULL);
        codegen__codegen__Buf256 d = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_node(self, ta.ty, ((const char *)(&nm.b[0])), ((char *)(&d.b[0])), 256ULL);
        ({ String__Global *__sc1389 = &(self->buf);
String__Global__push_str(&(*__sc1389), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1389), utils__errors__cstr(((const char *)(&d.b[0]))));
String__Global__push_str(&(*__sc1389), (str){ .ptr = (const uint8_t*)";\n", .len = sizeof(";\n") - 1 });
});
      }
    }
  }
  codegen__codegen__Codegen__emit_aggregate_specializations(self, false);
  codegen__codegen__Codegen__emit_rehomed_forwards(self);
}

static __attribute__((unused)) void codegen__codegen__Codegen__phase_types(codegen__codegen__Codegen *const self) {
  codegen__codegen__Codegen__emit_dyn_typedefs(self);
  codegen__codegen__Codegen__seed_emitted_type_instances(self);
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  uint8_t *const state = codegen__codegen__Codegen__cg_type_state(self);
  const size_t ni = Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances);
  const size_t cnt = ({
    size_t __sc1390;
    if (ni != 0ULL) {
      __sc1390 = ni;
    } else {
      __sc1390 = 1ULL;
    }
    __sc1390;
  });
  (self->inst_emit_state = ((uint8_t *)calloc(cnt, 1ULL)));
  if (self->inst_emit_state != NULL) {
    (self->inst_emit_n = ni);
  } else {
    (self->inst_emit_n = 0ULL);
  }
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    if (codegen__codegen__Codegen__type_emittable(self, nid)) {
      if (state != NULL) {
        codegen__codegen__Codegen__emit_type_dfs(self, nid, state);
      } else {
        codegen__codegen__Codegen__emit_type_decl(self, nid);
      }
    }
  }
  codegen__codegen__Codegen__emit_aggregate_specializations(self, true);
  codegen__codegen__Codegen__emit_rehomed_structs(self, true);
  codegen__codegen__Codegen__emit_generic_macros(self);
  free(((void *)self->inst_emit_state));
  (self->inst_emit_state = NULL);
  (self->inst_emit_n = 0ULL);
}

static __attribute__((unused)) void codegen__codegen__Codegen__phase_ret_structs(codegen__codegen__Codegen *const self) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk == ast__ast__NodeKind_NODE_FUNCTION) {
      if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.function.generics.len == 0U) {
        codegen__codegen__Codegen__emit_ret_struct(self, nid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE });
      }
    } else if (nk == ast__ast__NodeKind_NODE_EXTEND) {
      const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
      if (ed.generics.len != 0U) {
        continue;
      }
      const ast__ast__DefId target = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type);
      const ast__ast__NodeList ms = ed.items;
      const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms);
      for (uint32_t j = 0U; j < ms.len; j++) {
        const uint32_t mid = mids[((size_t)j)];
        if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind == ast__ast__NodeKind_NODE_FUNCTION) {
          codegen__codegen__Codegen__emit_ret_struct(self, mid, target);
        }
      }
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__phase_prototypes(codegen__codegen__Codegen *const self, int32_t const which) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk == ast__ast__NodeKind_NODE_FUNCTION) {
      const ast__ast__FunctionData ff = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.function;
      if (ff.generics.len != 0U) {
        continue;
      }
      if ((codegen__codegen__Codegen__cb_specialized_away(self, nid) || codegen__codegen__Codegen__cg_is_format_builtin(self, codegen__codegen__Codegen__cur_module(self), nid)) || codegen__codegen__Codegen__cg_test_skip(self, nid, false)) {
        continue;
      }
      if (codegen__codegen__want_fn(which, ff.is_public)) {
        codegen__codegen__Codegen__emit_function(self, nid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, false, NULL, false);
      }
    } else if (nk == ast__ast__NodeKind_NODE_EXTEND) {
      const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
      if (ed.generics.len != 0U) {
        continue;
      }
      const ast__ast__DefId target = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type);
      const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ed.items);
      for (uint32_t j = 0U; j < ed.items.len; j++) {
        const uint32_t mid = mids[((size_t)j)];
        const ast__ast__NodeKind mk_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
        if (mk_kind == ast__ast__NodeKind_NODE_FUNCTION) {
          const bool mpub = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.function.is_public;
          if (codegen__codegen__want_fn(which, mpub) && (!codegen__codegen__Codegen__cg_test_skip(self, mid, true))) {
            codegen__codegen__Codegen__emit_function(self, mid, target, false, false, NULL, false);
          }
        }
      }
    }
  }
  if (which != codegen__codegen__PROTO_PUBLIC) {
    codegen__codegen__Codegen__emit_closures(self, false);
    codegen__codegen__Codegen__emit_fnval_instance_structs(self);
    codegen__codegen__Codegen__emit_specializations(self, false);
    codegen__codegen__Codegen__emit_callback_specializations(self, false);
  }
  codegen__codegen__Codegen__emit_method_specializations(self, which, false);
  codegen__codegen__Codegen__emit_rehomed_methods(self, which, false);
  codegen__codegen__Codegen__emit_local_method_insts(self, which, false);
  codegen__codegen__Codegen__emit_default_methods(self, which, false);
}

static __attribute__((unused)) void codegen__codegen__Codegen__phase_bodies(codegen__codegen__Codegen *const self) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const ids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = ids[((size_t)i)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk == ast__ast__NodeKind_NODE_CONST) {
      const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.const_def;
      if (cd.is_static_mut || (!(self->multifile && cd.is_public))) {
        codegen__codegen__Codegen__emit_toplevel_const(self, nid);
      }
    } else if (nk == ast__ast__NodeKind_NODE_STATIC_ASSERT) {
      codegen__codegen__Codegen__emit_static_assert(self, nid);
    }
  }
  codegen__codegen__Codegen__emit_assoc_consts(self, false);
  codegen__codegen__Codegen__emit_default_methods(self, codegen__codegen__PROTO_ALL, true);
  codegen__codegen__Codegen__emit_specializations(self, true);
  codegen__codegen__Codegen__emit_method_specializations(self, codegen__codegen__PROTO_ALL, true);
  codegen__codegen__Codegen__emit_rehomed_methods(self, codegen__codegen__PROTO_ALL, true);
  codegen__codegen__Codegen__emit_local_method_insts(self, codegen__codegen__PROTO_ALL, true);
  codegen__codegen__Codegen__emit_closures(self, true);
  codegen__codegen__Codegen__emit_callback_specializations(self, true);
  for (uint32_t i2 = 0U; i2 < items.len; i2++) {
    const uint32_t nid = ids[((size_t)i2)];
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (nk == ast__ast__NodeKind_NODE_FUNCTION) {
      const ast__ast__FunctionData ff = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.function;
      if (((((ff.generics.len == 0U) && (ff.body != ast__ast__NODE_NONE)) && (!codegen__codegen__Codegen__cb_specialized_away(self, nid))) && (!codegen__codegen__Codegen__cg_is_format_builtin(self, codegen__codegen__Codegen__cur_module(self), nid))) && (!codegen__codegen__Codegen__cg_test_skip(self, nid, false))) {
        codegen__codegen__Codegen__emit_function(self, nid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, true, NULL, false);
      }
    } else if (nk == ast__ast__NodeKind_NODE_EXTEND) {
      const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
      if (ed.generics.len == 0U) {
        const ast__ast__DefId target = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type);
        const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ed.items);
        for (uint32_t j = 0U; j < ed.items.len; j++) {
          const uint32_t mid = mids[((size_t)j)];
          const ast__ast__NodeKind mk_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
          if (mk_kind == ast__ast__NodeKind_NODE_FUNCTION) {
            const uint32_t mbody = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.function.body;
            if ((mbody != ast__ast__NODE_NONE) && (!codegen__codegen__Codegen__cg_test_skip(self, mid, true))) {
              codegen__codegen__Codegen__emit_function(self, mid, target, false, true, NULL, false);
            }
          }
        }
      }
    }
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_type_satisfies(codegen__codegen__Codegen *const self, uint32_t const ty, ast__ast__DefId const iface, int32_t const depth) {
  if ((ty == ast__ast__TYPE_NONE) || (depth > 8)) {
    return true;
  }
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, ty));
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    return true;
  }
  uint16_t tmod = 0U;
  uint32_t tdecl = ast__ast__NODE_NONE;
  codegen__codegen__TyArgs4 iargs = (codegen__codegen__TyArgs4){0};
  int32_t in_ = 0;
  if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    (tmod = y.module);
    (tdecl = y.as_data.decl);
  } else if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    (tmod = it.module);
    (tdecl = it.decl);
    uint8_t k = 0U;
    while ((k < it.n) && (in_ < 4)) {
      (iargs.t[((size_t)in_)] = it.args[((size_t)k)]);
      (in_ = ({ int32_t __sc_r; if (__builtin_add_overflow(in_, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
    }
  } else if ((y.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) {
    const uint32_t bd = module__loader__Package__builtin_decl(&((*self->package)), y.as_data.builtin);
    if (bd == ast__ast__NODE_NONE) {
      return false;
    }
    (tmod = (*self->package).core_module);
    (tdecl = bd);
  } else {
    return false;
  }
  const int32_t ns = ({
    int32_t __sc1391;
    if (tmod == codegen__codegen__Codegen__cur_module(self)) {
      __sc1391 = 1;
    } else {
      __sc1391 = 2;
    }
    __sc1391;
  });
  for (int32_t s = 0; s < ns; s++) {
    const uint16_t m = ({
      uint16_t __sc1392;
      if (s == 0) {
        __sc1392 = tmod;
      } else {
        __sc1392 = codegen__codegen__Codegen__cur_module(self);
      }
      __sc1392;
    });
    ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (((it->kind != ast__ast__NodeKind_NODE_EXTEND) || (it->as_data.extend_def.interface_type == ast__ast__NODE_NONE)) || (it->as_data.extend_def.target_type == ast__ast__NODE_NONE)) {
        continue;
      }
      const ast__ast__DefId tr = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.interface_type);
      const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type);
      if ((((tr.module != iface.module) || (tr.node != iface.node)) || (tg.module != tmod)) || (tg.node != tdecl)) {
        continue;
      }
      const ast__ast__NodeList gens = it->as_data.extend_def.generics;
      const uint32_t *const gids = ast__ast__Ast__list(&((*a)), gens);
      bool ok = true;
      uint32_t g = 0U;
      while (((g < gens.len) && (((int32_t)g) < in_)) && ok) {
        const ast__ast__NodeList gb = ast__ast__Ast__at_const(&((*a)), gids[((size_t)g)])->as_data.generic_param.bounds;
        const uint32_t *const gbids = ast__ast__Ast__list(&((*a)), gb);
        uint32_t b = 0U;
        while ((b < gb.len) && ok) {
          const ast__ast__DefId gbi = ast__ast__Ast__resolution_def(&((*a)), gbids[((size_t)b)]);
          if ((gbi.node != ast__ast__NODE_NONE) && (!codegen__codegen__Codegen__cg_type_satisfies(self, iargs.t[((size_t)g)], gbi, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })))) {
            (ok = false);
          }
          (b = (b + 1U));
        }
        (g = (g + 1U));
      }
      if (ok) {
        return true;
      }
    }
  }
  return false;
}

static __attribute__((unused)) ast__ast__DefId codegen__codegen__Codegen__extend_interface(const codegen__codegen__Codegen *const self, uint32_t const extend_id) {
  const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), extend_id);
  if (it->as_data.extend_def.interface_type == ast__ast__NODE_NONE) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  return ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), it->as_data.extend_def.interface_type);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_extend_bounds_hold(codegen__codegen__Codegen *const self, uint32_t const extend_id, const uint32_t *const args, uint8_t const n) {
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), extend_id)->as_data.extend_def.generics;
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
  uint32_t g = 0U;
  while ((g < gens.len) && (g < ((uint32_t)n))) {
    const ast__ast__NodeList gb = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), gids[((size_t)g)])->as_data.generic_param.bounds;
    const uint32_t *const gbids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gb);
    for (uint32_t b = 0U; b < gb.len; b++) {
      const ast__ast__DefId gbi = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), gbids[((size_t)b)]);
      if ((gbi.node != ast__ast__NODE_NONE) && (!codegen__codegen__Codegen__cg_type_satisfies(self, args[((size_t)g)], gbi, 0))) {
        return false;
      }
    }
    (g = (g + 1U));
  }
  return true;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__seed_type_instances_from_type(codegen__codegen__Codegen *const self, uint32_t const ty0) {
  if (ty0 == ast__ast__TYPE_NONE) {
    return false;
  }
  const uint32_t ty = codegen__codegen__Codegen__subst_resolve(self, ty0);
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, ty));
  bool changed = false;
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    bool concrete = true;
    for (uint8_t i = 0U; i < it.n; i++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)i)])) {
        (concrete = false);
      }
    }
    if (concrete) {
      const size_t before = Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances);
      ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), it.module, it.decl, ((const uint32_t *)(&it.args[0])), it.n);
      if (Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances) != before) {
        (changed = true);
      }
      for (uint8_t j = 0U; j < it.n; j++) {
        if (codegen__codegen__Codegen__seed_type_instances_from_type(self, it.args[((size_t)j)])) {
          (changed = true);
        }
      }
    }
  } else if (((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    if (codegen__codegen__Codegen__seed_type_instances_from_type(self, y.as_data.elem)) {
      (changed = true);
    }
  }
  return changed;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__seed_type_instances_from_type_node(codegen__codegen__Codegen *const self, uint32_t const type_node) {
  if (type_node == ast__ast__NODE_NONE) {
    return false;
  }
  const uint32_t ty = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), type_node);
  return ((ty != ast__ast__TYPE_NONE) && codegen__codegen__Codegen__seed_type_instances_from_type(self, ty));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__seed_type_instances_from_fn_signature(codegen__codegen__Codegen *const self, uint32_t const fn_id) {
  const ast__ast__FunctionData f = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fn_id)->as_data.function;
  bool changed = false;
  const uint32_t *const pids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), f.params);
  for (uint32_t i = 0U; i < f.params.len; i++) {
    const uint32_t ptn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pids[((size_t)i)])->as_data.parameter.ty;
    if (codegen__codegen__Codegen__seed_type_instances_from_type_node(self, ptn)) {
      (changed = true);
    }
  }
  const uint32_t *const rids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), f.returns);
  for (uint32_t r = 0U; r < f.returns.len; r++) {
    const uint32_t rid = rids[((size_t)r)];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), rid);
    const uint32_t rtn = ({
      uint32_t __sc1393;
      if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
        __sc1393 = rn->as_data.parameter.ty;
      } else {
        __sc1393 = rid;
      }
      __sc1393;
    });
    if (codegen__codegen__Codegen__seed_type_instances_from_type_node(self, rtn)) {
      (changed = true);
    }
  }
  return changed;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__seed_emitted_generic_method_signature_instances(codegen__codegen__Codegen *const self) {
  bool changed = false;
  for (size_t ii = 0ULL; ii < Vector__ast__ast__TyInstance__Global__len(&(*codegen__codegen__Codegen__cur_ast(self)).instances); ii++) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), ((uint32_t)ii)));
    if (it.module != codegen__codegen__Codegen__cur_module(self)) {
      continue;
    }
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!codegen__codegen__Codegen__type_is_concrete(self, it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      continue;
    }
    const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
    const uint32_t *const iids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t nid = iids[((size_t)i)];
      const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
      const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
      if ((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.generics.len == 0U)) {
        continue;
      }
      if (ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type) != it.decl) {
        continue;
      }
      const ast__ast__DefId itrait = codegen__codegen__Codegen__extend_interface(self, nid);
      if (itrait.node != ast__ast__NODE_NONE) {
        const uint32_t itty = ast__ast__Ast__intern_instance(&((*codegen__codegen__Codegen__cur_ast(self))), it.module, it.decl, ((const uint32_t *)(&it.args[0])), it.n);
        if (!codegen__codegen__Codegen__cg_type_satisfies(self, itty, itrait, 0)) {
          continue;
        }
      }
      if (!codegen__codegen__Codegen__cg_extend_bounds_hold(self, nid, ((const uint32_t *)(&it.args[0])), it.n)) {
        continue;
      }
      const ast__ast__NodeList gens = ed.generics;
      const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
      const int32_t saved = self->nsubst;
      (self->nsubst = 0);
      uint32_t g = 0U;
      while (((g < gens.len) && (g < ((uint32_t)it.n))) && (self->nsubst < 16)) {
        (self->subst[((size_t)self->nsubst)].param = (ast__ast__DefId){ .module = codegen__codegen__Codegen__cur_module(self), .node = gids[((size_t)g)] });
        (self->subst[((size_t)self->nsubst)].concrete = it.args[((size_t)g)]);
        (self->nsubst = ({ int32_t __sc_r; if (__builtin_add_overflow(self->nsubst, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (g = (g + 1U));
      }
      const ast__ast__NodeList ms = ed.items;
      const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms);
      for (uint32_t j = 0U; j < ms.len; j++) {
        const uint32_t mid = mids[((size_t)j)];
        const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid);
        if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && (mn->as_data.function.generics.len == 0U)) {
          if (codegen__codegen__Codegen__seed_type_instances_from_fn_signature(self, mid)) {
            (changed = true);
          }
        }
      }
      (self->nsubst = saved);
    }
  }
  return changed;
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__module_depth(const codegen__codegen__Codegen *const self) {
  const str p = String__Global__as_str(&(*({ __auto_type __sc1394 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1394, ((size_t)codegen__codegen__Codegen__cur_module(self))); })).path);
  const size_t n = str__len(&p);
  size_t d = 0ULL;
  size_t i = 0ULL;
  while (i < n) {
    if (((str__byte_at(&p, i) == 58U) && ((i + 1ULL) < n)) && (str__byte_at(&p, (i + 1ULL)) == 58U)) {
      (d = (d + 1ULL));
      (i = (i + 1ULL));
    }
    (i = (i + 1ULL));
  }
  return d;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_rel_prefix(codegen__codegen__Codegen *const self) {
  const size_t d = codegen__codegen__Codegen__module_depth(self);
  for (size_t i = 0ULL; i < d; i++) {
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1395 = (str){ (const uint8_t *)"../", sizeof("../") - 1 }; str__ptr(&__sc1395); })));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_modpath_include(codegen__codegen__Codegen *const self, str const path) {
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1396 = (str){ (const uint8_t *)"#include \"", sizeof("#include \"") - 1 }; str__ptr(&__sc1396); })));
  codegen__codegen__Codegen__emit_rel_prefix(self);
  const size_t n = str__len(&path);
  size_t i = 0ULL;
  while (i < n) {
    if (((str__byte_at(&path, i) == 58U) && ((i + 1ULL) < n)) && (str__byte_at(&path, (i + 1ULL)) == 58U)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1397 = (str){ (const uint8_t *)"/", sizeof("/") - 1 }; str__ptr(&__sc1397); })));
      (i = (i + 1ULL));
    } else {
      codegen__codegen__Codegen__emit_bytes(self, ((const char *)(str__ptr(&path) + i)), 1ULL);
    }
    (i = (i + 1ULL));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1398 = (str){ (const uint8_t *)".h\"\n", sizeof(".h\"\n") - 1 }; str__ptr(&__sc1398); })));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__type_mentions_builtin(const codegen__codegen__Codegen *const self, uint32_t const t) {
  if (t == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, t));
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    return true;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    return codegen__codegen__Codegen__type_mentions_builtin(self, y.as_data.elem);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    for (uint8_t i = 0U; i < it.n; i++) {
      if (codegen__codegen__Codegen__type_mentions_builtin(self, it.args[((size_t)i)])) {
        return true;
      }
    }
    return false;
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_decl_is_interface_member(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const node) {
  ast__ast__Ast *const a = codegen__codegen__Codegen__mod_ast(self, m);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), node)->kind;
  if (nk == ast__ast__NodeKind_NODE_INTERFACE) {
    return true;
  }
  if (nk != ast__ast__NodeKind_NODE_FUNCTION) {
    return false;
  }
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  const uint32_t *const ids = ast__ast__Ast__list(&((*a)), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), ids[((size_t)i)]);
    if (it->kind == ast__ast__NodeKind_NODE_INTERFACE) {
      const ast__ast__NodeList ms = it->as_data.interface_def.items;
      const uint32_t *const mids = ast__ast__Ast__list(&((*a)), ms);
      for (uint32_t j = 0U; j < ms.len; j++) {
        if (mids[((size_t)j)] == node) {
          return true;
        }
      }
    }
  }
  return false;
}

static __attribute__((unused)) void codegen__codegen__Codegen__mark_layout_module(const codegen__codegen__Codegen *const self, uint32_t const ft, bool *const want, size_t const nmod) {
  if (ft == ast__ast__TYPE_NONE) {
    return;
  }
  uint32_t cft = codegen__codegen__Codegen__subst_resolve(self, ft);
  ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, cft));
  while (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    (cft = y.as_data.elem);
    (y = (*codegen__codegen__Codegen__type_at(self, cft)));
  }
  const uint16_t cur = codegen__codegen__Codegen__cur_module(self);
  if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    int32_t bb = -1;
    if (self->package != NULL) {
      (bb = module__loader__Package__builtin_of_decl(&((*self->package)), y.module, y.as_data.decl));
    }
    if (((y.module != cur) && (((size_t)y.module) < nmod)) && (bb < 0)) {
      (want[((size_t)y.module)] = true);
    }
  } else if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y.as_data.inst));
    const uint16_t home = module__loader__Package__instance_home(&((*self->package)), (&(*codegen__codegen__Codegen__cur_ast(self))), (&it));
    if ((home != cur) && (((size_t)home) < nmod)) {
      (want[((size_t)home)] = true);
    }
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__mark_aggregate_layout(const codegen__codegen__Codegen *const self, uint32_t const dn_id, bool *const want, size_t const nmod) {
  const ast__ast__AggregateData ag = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), dn_id)->as_data.aggregate;
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), dn_id)->kind;
  const ast__ast__NodeList ms = ag.members;
  const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ms);
  for (uint32_t m = 0U; m < ms.len; m++) {
    const uint32_t mid = mids[((size_t)m)];
    const ast__ast__NodeKind mnk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
    if ((dk == ast__ast__NodeKind_NODE_STRUCT) && ag.is_tuple) {
      codegen__codegen__Codegen__mark_layout_module(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), mid), want, nmod);
    } else if ((dk == ast__ast__NodeKind_NODE_STRUCT) && (mnk == ast__ast__NodeKind_NODE_FIELD)) {
      const uint32_t fty = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.field.ty;
      codegen__codegen__Codegen__mark_layout_module(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), fty), want, nmod);
    } else if ((dk == ast__ast__NodeKind_NODE_ENUM) && (mnk == ast__ast__NodeKind_NODE_VARIANT)) {
      const ast__ast__NodeList payload = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.variant.payload;
      const uint32_t *const plids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), payload);
      for (uint32_t k = 0U; k < payload.len; k++) {
        const uint32_t pid = plids[((size_t)k)];
        const ast__ast__NodeKind pfk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid)->kind;
        const uint32_t tn = ({
          uint32_t __sc1399;
          if (pfk == ast__ast__NodeKind_NODE_FIELD) {
            __sc1399 = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), pid)->as_data.field.ty;
          } else {
            __sc1399 = pid;
          }
          __sc1399;
        });
        codegen__codegen__Codegen__mark_layout_module(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), tn), want, nmod);
      }
    }
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_dyn_method(const codegen__codegen__Codegen *const self, uint16_t const im, uint32_t const m_id) {
  const ast__ast__FunctionData mf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, im))), m_id)->as_data.function;
  const ast__ast__NodeKind mk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, im))), m_id)->kind;
  if ((mk != ast__ast__NodeKind_NODE_FUNCTION) || (mf.params.len == 0U)) {
    return false;
  }
  const uint32_t p0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, im))), mf.params)[0];
  const uint32_t p0name = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, im))), p0)->as_data.parameter.name;
  return codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, im), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, im))), p0name)->as_data.name.text, ((const char *)({ __auto_type __sc1400 = (str){ (const uint8_t *)"self", sizeof("self") - 1 }; str__ptr(&__sc1400); })));
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_dyn_ret(codegen__codegen__Codegen *const self, uint16_t const im, uint32_t const m_id) {
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, im))), m_id)->as_data.function.returns;
  if (rets.len != 1U) {
    return ast__ast__TYPE_NONE;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, im))), rets)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, im))), r0);
  const uint32_t rtn = ({
    uint32_t __sc1401;
    if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
      __sc1401 = rn->as_data.parameter.ty;
    } else {
      __sc1401 = r0;
    }
    __sc1401;
  });
  const uint32_t rt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, im))), rtn);
  if (rt == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Ty rty = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__mod_ast(self, im))), rt));
  if ((rty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (rty.as_data.builtin == ast__ast__BuiltinType_BT_VOID)) {
    return ast__ast__TYPE_NONE;
  }
  return ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, im))), rt);
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_dyn_target(const codegen__codegen__Codegen *const self, const ast__ast__Ty *const sy, uint16_t *const tm, uint32_t *const td) {
  if (sy->kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    ((*tm) = ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), sy->as_data.inst)->module);
    ((*td) = ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), sy->as_data.inst)->decl);
  } else if ((sy->kind == ast__ast__TypeKind_TYPE_STRUCT) || (sy->kind == ast__ast__TypeKind_TYPE_ENUM)) {
    ((*tm) = sy->module);
    ((*td) = sy->as_data.decl);
  } else if (((sy->kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) && (module__loader__Package__builtin_decl(&((*self->package)), sy->as_data.builtin) != ast__ast__NODE_NONE)) {
    ((*tm) = (*self->package).core_module);
    ((*td) = module__loader__Package__builtin_decl(&((*self->package)), sy->as_data.builtin));
  } else {
    return false;
  }
  return true;
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_dynfn_ret(codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const sig) {
  const ast__ast__FunctionTypeData ft = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), sig)->as_data.function_type;
  if (ft.returns.len != 1U) {
    return ast__ast__TYPE_NONE;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*codegen__codegen__Codegen__mod_ast(self, m))), ft.returns)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), r0);
  const uint32_t rtn = ({
    uint32_t __sc1402;
    if (rn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
      __sc1402 = rn->as_data.parameter.ty;
    } else {
      __sc1402 = r0;
    }
    __sc1402;
  });
  const uint32_t rt = ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__mod_ast(self, m))), rtn);
  if (rt == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Ty rty = (*ast__ast__Ast__type_at(&((*codegen__codegen__Codegen__mod_ast(self, m))), rt));
  if ((rty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (rty.as_data.builtin == ast__ast__BuiltinType_BT_VOID)) {
    return ast__ast__TYPE_NONE;
  }
  return ast__ast__Ast__reintern(&((*codegen__codegen__Codegen__cur_ast(self))), (&(*codegen__codegen__Codegen__mod_ast(self, m))), rt);
}

static __attribute__((unused)) void codegen__codegen__cg_int_range(ast__ast__BuiltinType const b, int64_t *const mn, int64_t *const mx) {
  if (b == ast__ast__BuiltinType_BT_I8) {
    ((*mn) = -128);
    ((*mx) = 127);
  } else if (b == ast__ast__BuiltinType_BT_I16) {
    ((*mn) = -32768);
    ((*mx) = 32767);
  } else if (b == ast__ast__BuiltinType_BT_I32) {
    ((*mn) = (-2147483648));
    ((*mx) = 2147483647);
  } else {
    ((*mn) = (-9223372036854775807ll - 1));
    ((*mx) = 9223372036854775807LL);
  }
}

static __attribute__((unused)) bool codegen__codegen__Codegen__cg_struct_name_is(const codegen__codegen__Codegen *const self, const ast__ast__Ty *const y, const char *const lit) {
  uint16_t m = 0U;
  uint32_t decl = ast__ast__NODE_NONE;
  if (y->kind == ast__ast__TypeKind_TYPE_STRUCT) {
    (m = y->module);
    (decl = y->as_data.decl);
  } else if (y->kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*codegen__codegen__Codegen__cur_ast(self))), y->as_data.inst));
    (m = it.module);
    (decl = it.decl);
  } else {
    return false;
  }
  const uint32_t anm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), decl)->as_data.aggregate.name;
  return codegen__codegen__span_is(codegen__codegen__Codegen__mod_src(self, m), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, m))), anm)->as_data.name.text, lit);
}

static __attribute__((unused)) uint32_t codegen__codegen__Codegen__cg_line_of(const codegen__codegen__Codegen *const self, uint32_t const off) {
  uint32_t line = 1U;
  uint32_t i = 0U;
  while ((i < off) && (((size_t)i) < self->len)) {
    if (self->source[((size_t)i)] == 10U) {
      (line = (line + 1U));
    }
    (i = (i + 1U));
  }
  return line;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_pct_escaped(codegen__codegen__Codegen *const self, const uint8_t *const text, size_t const len) {
  for (size_t i = 0ULL; i < len; i++) {
    const uint8_t byte = text[i];
    if (byte == 37U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1403 = (str){ (const uint8_t *)"%%", sizeof("%%") - 1 }; str__ptr(&__sc1403); })));
    } else if ((byte == 34U) || (byte == 92U)) {
      String__Global__push_byte(&self->buf, 92U);
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)byte)));
    } else if (byte == 10U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1404 = (str){ (const uint8_t *)"\\n", sizeof("\\n") - 1 }; str__ptr(&__sc1404); })));
    } else if (byte < 32U) {
      codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)((int32_t)byte)));
    } else {
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)byte)));
    }
  }
}

static __attribute__((unused)) const char *codegen__codegen__Codegen__cg_file(codegen__codegen__Codegen *const self) {
  if ((self->package != NULL) && (((size_t)codegen__codegen__Codegen__cur_module(self)) < codegen__codegen__Codegen__pkg_count(self))) {
    if (String__Global__len(&(*({ __auto_type __sc1405 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1405, ((size_t)codegen__codegen__Codegen__cur_module(self))); })).file) != 0ULL) {
      return String__Global__cstr(&(*({ __auto_type __sc1406 = &(*self->package).modules; Vector__module__loader__Module__Global__index_mut(__sc1406, ((size_t)codegen__codegen__Codegen__cur_module(self))); })).file);
    }
  }
  return ((const char *)({ __auto_type __sc1407 = (str){ (const uint8_t *)"<src>", sizeof("<src>") - 1 }; str__ptr(&__sc1407); }));
}

static __attribute__((unused)) int32_t codegen__codegen__Codegen__cg_assert_kind(const codegen__codegen__Codegen *const self, uint32_t const id) {
  if (self->package == NULL) {
    return 0;
  }
  const uint32_t callee = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), id)->as_data.call.callee;
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), callee)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return 0;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), callee);
  if (((d.node == ast__ast__NODE_NONE) || (((size_t)d.module) >= codegen__codegen__Codegen__pkg_count(self))) || (!(*({ __auto_type __sc1408 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc1408, ((size_t)d.module)); })).prelude)) {
    return 0;
  }
  if (ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_FUNCTION) {
    return 0;
  }
  const uint32_t fnamenode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), d.node)->as_data.function.name;
  const lexer__token__Span fnm = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, d.module))), fnamenode)->as_data.name.text;
  const uint8_t *const s = codegen__codegen__Codegen__mod_src(self, d.module);
  if (codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1409 = (str){ (const uint8_t *)"assert", sizeof("assert") - 1 }; str__ptr(&__sc1409); })))) {
    return 1;
  }
  if (codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1410 = (str){ (const uint8_t *)"assert_eq", sizeof("assert_eq") - 1 }; str__ptr(&__sc1410); })))) {
    return 2;
  }
  if (codegen__codegen__span_is(s, fnm, ((const char *)({ __auto_type __sc1411 = (str){ (const uint8_t *)"assert_ne", sizeof("assert_ne") - 1 }; str__ptr(&__sc1411); })))) {
    return 3;
  }
  return 0;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_assert_value_line(codegen__codegen__Codegen *const self, const char *const label, const char *const acc, ast__ast__Ty const y, uint32_t const base) {
  ({ String__Global *__sc1412 = &(self->buf);
String__Global__push_str(&(*__sc1412), (str){ .ptr = (const uint8_t*)"fprintf(stderr, \"  ", .len = sizeof("fprintf(stderr, \"  ") - 1 });
String__Global__push_str(&(*__sc1412), utils__errors__cstr(label));
String__Global__push_str(&(*__sc1412), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
});
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    const ast__ast__BuiltinType bt = y.as_data.builtin;
    if (bt == ast__ast__BuiltinType_BT_BOOL) {
      ({ String__Global *__sc1413 = &(self->buf);
String__Global__push_str(&(*__sc1413), (str){ .ptr = (const uint8_t*)"%s\\n\", ", .len = sizeof("%s\\n\", ") - 1 });
String__Global__push_str(&(*__sc1413), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1413), (str){ .ptr = (const uint8_t*)" ? \"true\" : \"false\");\n", .len = sizeof(" ? \"true\" : \"false\");\n") - 1 });
});
      return;
    }
    if (bt == ast__ast__BuiltinType_BT_CHAR) {
      ({ String__Global *__sc1414 = &(self->buf);
String__Global__push_str(&(*__sc1414), (str){ .ptr = (const uint8_t*)"'%c'\\n\", (int)", .len = sizeof("'%c'\\n\", (int)") - 1 });
String__Global__push_str(&(*__sc1414), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1414), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      return;
    }
    if (((((bt == ast__ast__BuiltinType_BT_I8) || (bt == ast__ast__BuiltinType_BT_I16)) || (bt == ast__ast__BuiltinType_BT_I32)) || (bt == ast__ast__BuiltinType_BT_I64)) || (bt == ast__ast__BuiltinType_BT_ISIZE)) {
      ({ String__Global *__sc1415 = &(self->buf);
String__Global__push_str(&(*__sc1415), (str){ .ptr = (const uint8_t*)"%lld\\n\", (long long)", .len = sizeof("%lld\\n\", (long long)") - 1 });
String__Global__push_str(&(*__sc1415), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1415), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      return;
    }
    if (((((bt == ast__ast__BuiltinType_BT_U8) || (bt == ast__ast__BuiltinType_BT_U16)) || (bt == ast__ast__BuiltinType_BT_U32)) || (bt == ast__ast__BuiltinType_BT_U64)) || (bt == ast__ast__BuiltinType_BT_USIZE)) {
      ({ String__Global *__sc1416 = &(self->buf);
String__Global__push_str(&(*__sc1416), (str){ .ptr = (const uint8_t*)"%llu\\n\", (unsigned long long)", .len = sizeof("%llu\\n\", (unsigned long long)") - 1 });
String__Global__push_str(&(*__sc1416), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1416), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      return;
    }
    if ((bt == ast__ast__BuiltinType_BT_F32) || (bt == ast__ast__BuiltinType_BT_F64)) {
      ({ String__Global *__sc1417 = &(self->buf);
String__Global__push_str(&(*__sc1417), (str){ .ptr = (const uint8_t*)"%g\\n\", (double)", .len = sizeof("%g\\n\", (double)") - 1 });
String__Global__push_str(&(*__sc1417), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1417), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      return;
    }
  }
  if (codegen__codegen__Codegen__cg_struct_name_is(self, (&y), ((const char *)({ __auto_type __sc1418 = (str){ (const uint8_t *)"str", sizeof("str") - 1 }; str__ptr(&__sc1418); })))) {
    ({ String__Global *__sc1419 = &(self->buf);
String__Global__push_str(&(*__sc1419), (str){ .ptr = (const uint8_t*)"\\\"%.*s\\\"\\n\", (int)", .len = sizeof("\\\"%.*s\\\"\\n\", (int)") - 1 });
String__Global__push_str(&(*__sc1419), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1419), (str){ .ptr = (const uint8_t*)".len, (const char *)", .len = sizeof(".len, (const char *)") - 1 });
String__Global__push_str(&(*__sc1419), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1419), (str){ .ptr = (const uint8_t*)".ptr);\n", .len = sizeof(".ptr);\n") - 1 });
});
    return;
  }
  if (codegen__codegen__Codegen__cg_struct_name_is(self, (&y), ((const char *)({ __auto_type __sc1420 = (str){ (const uint8_t *)"String", sizeof("String") - 1 }; str__ptr(&__sc1420); })))) {
    codegen__codegen__Buf200 sm = (codegen__codegen__Buf200){0};
    codegen__codegen__Codegen__render_type_id(self, base, ((const char *)({ __auto_type __sc1421 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1421); })), ((char *)(&sm.b[0])), 200ULL);
    ({ String__Global *__sc1422 = &(self->buf);
String__Global__push_str(&(*__sc1422), (str){ .ptr = (const uint8_t*)"\\\"%.*s\\\"\\n\", (int)", .len = sizeof("\\\"%.*s\\\"\\n\", (int)") - 1 });
String__Global__push_str(&(*__sc1422), utils__errors__cstr(((const char *)(&sm.b[0]))));
String__Global__push_str(&(*__sc1422), (str){ .ptr = (const uint8_t*)"__as_str(&", .len = sizeof("__as_str(&") - 1 });
String__Global__push_str(&(*__sc1422), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1422), (str){ .ptr = (const uint8_t*)").len, (const char *)", .len = sizeof(").len, (const char *)") - 1 });
String__Global__push_str(&(*__sc1422), utils__errors__cstr(((const char *)(&sm.b[0]))));
String__Global__push_str(&(*__sc1422), (str){ .ptr = (const uint8_t*)"__as_str(&", .len = sizeof("__as_str(&") - 1 });
String__Global__push_str(&(*__sc1422), utils__errors__cstr(acc));
String__Global__push_str(&(*__sc1422), (str){ .ptr = (const uint8_t*)").ptr);\n", .len = sizeof(").ptr);\n") - 1 });
});
    return;
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1423 = (str){ (const uint8_t *)"(value of a non-printable type)\\n\");\n", sizeof("(value of a non-printable type)\\n\");\n") - 1 }; str__ptr(&__sc1423); })));
}

static __attribute__((unused)) bool codegen__codegen__bt_is_numeric(ast__ast__BuiltinType const b) {
  const int32_t v = ((int32_t)b);
  return ((v >= 2) && (v <= 13));
}

static __attribute__((unused)) bool codegen__codegen__bt_is_signed_int(ast__ast__BuiltinType const b) {
  const int32_t v = ((int32_t)b);
  return ((v >= 2) && (v <= 6));
}

static __attribute__((unused)) bool codegen__codegen__bt_is_unsigned_int(ast__ast__BuiltinType const b) {
  const int32_t v = ((int32_t)b);
  return ((v >= 7) && (v <= 11));
}

static __attribute__((unused)) bool codegen__codegen__bt_is_binfmt(ast__ast__BuiltinType const b) {
  const int32_t v = ((int32_t)b);
  return ((v >= 1) && (v <= 11));
}

static __attribute__((unused)) const char *codegen__codegen__bt_unsigned_cast(ast__ast__BuiltinType const b) {
  if (((b == ast__ast__BuiltinType_BT_I8) || (b == ast__ast__BuiltinType_BT_U8)) || (b == ast__ast__BuiltinType_BT_CHAR)) {
    return ((const char *)({ __auto_type __sc1424 = (str){ (const uint8_t *)"uint8_t", sizeof("uint8_t") - 1 }; str__ptr(&__sc1424); }));
  }
  if ((b == ast__ast__BuiltinType_BT_I16) || (b == ast__ast__BuiltinType_BT_U16)) {
    return ((const char *)({ __auto_type __sc1425 = (str){ (const uint8_t *)"uint16_t", sizeof("uint16_t") - 1 }; str__ptr(&__sc1425); }));
  }
  if ((b == ast__ast__BuiltinType_BT_I32) || (b == ast__ast__BuiltinType_BT_U32)) {
    return ((const char *)({ __auto_type __sc1426 = (str){ (const uint8_t *)"uint32_t", sizeof("uint32_t") - 1 }; str__ptr(&__sc1426); }));
  }
  return ((const char *)({ __auto_type __sc1427 = (str){ (const uint8_t *)"uint64_t", sizeof("uint64_t") - 1 }; str__ptr(&__sc1427); }));
}

static __attribute__((unused)) bool codegen__codegen__Codegen__fmt_arg_core(codegen__codegen__Codegen *const self, const char *const tb, uint32_t const arg, const codegen__codegen__FmtSpec *const sp, ast__ast__Ty const y, uint32_t const t) {
  if ((sp->ty == 120) || (sp->ty == 88)) {
    const char *const ud = ({
      const char *__sc1428;
      if (sp->ty == 88) {
        __sc1428 = ((const char *)({ __auto_type __sc1429 = (str){ (const uint8_t *)"true", sizeof("true") - 1 }; str__ptr(&__sc1429); }));
      } else {
        __sc1428 = ((const char *)({ __auto_type __sc1430 = (str){ (const uint8_t *)"false", sizeof("false") - 1 }; str__ptr(&__sc1430); }));
      }
      __sc1428;
    });
    if (y.kind != ast__ast__TypeKind_TYPE_BUILTIN) {
      return false;
    }
    const ast__ast__BuiltinType b = y.as_data.builtin;
    if (codegen__codegen__bt_is_signed_int(b)) {
      ({ String__Global *__sc1431 = &(self->buf);
String__Global__push_str(&(*__sc1431), (str){ .ptr = (const uint8_t*)"String__Global__push_hex_i64(&", .len = sizeof("String__Global__push_hex_i64(&") - 1 });
String__Global__push_str(&(*__sc1431), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1431), (str){ .ptr = (const uint8_t*)", (int64_t)(", .len = sizeof(", (int64_t)(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      ({ String__Global *__sc1432 = &(self->buf);
String__Global__push_str(&(*__sc1432), (str){ .ptr = (const uint8_t*)"), ", .len = sizeof("), ") - 1 });
String__Global__push_str(&(*__sc1432), utils__errors__cstr(ud));
String__Global__push_str(&(*__sc1432), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      return true;
    }
    if (codegen__codegen__bt_is_unsigned_int(b) || (b == ast__ast__BuiltinType_BT_CHAR)) {
      ({ String__Global *__sc1433 = &(self->buf);
String__Global__push_str(&(*__sc1433), (str){ .ptr = (const uint8_t*)"String__Global__push_hex(&", .len = sizeof("String__Global__push_hex(&") - 1 });
String__Global__push_str(&(*__sc1433), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1433), (str){ .ptr = (const uint8_t*)", (uint64_t)(", .len = sizeof(", (uint64_t)(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      ({ String__Global *__sc1434 = &(self->buf);
String__Global__push_str(&(*__sc1434), (str){ .ptr = (const uint8_t*)"), ", .len = sizeof("), ") - 1 });
String__Global__push_str(&(*__sc1434), utils__errors__cstr(ud));
String__Global__push_str(&(*__sc1434), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      return true;
    }
    return false;
  }
  if (sp->ty == 98) {
    if ((y.kind != ast__ast__TypeKind_TYPE_BUILTIN) || (!codegen__codegen__bt_is_binfmt(y.as_data.builtin))) {
      return false;
    }
    ({ String__Global *__sc1435 = &(self->buf);
String__Global__push_str(&(*__sc1435), (str){ .ptr = (const uint8_t*)"String__Global__push_bin(&", .len = sizeof("String__Global__push_bin(&") - 1 });
String__Global__push_str(&(*__sc1435), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1435), (str){ .ptr = (const uint8_t*)", (uint64_t)(", .len = sizeof(", (uint64_t)(") - 1 });
String__Global__push_str(&(*__sc1435), utils__errors__cstr(codegen__codegen__bt_unsigned_cast(y.as_data.builtin)));
String__Global__push_str(&(*__sc1435), (str){ .ptr = (const uint8_t*)")(", .len = sizeof(")(") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, arg);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1436 = (str){ (const uint8_t *)"));\n", sizeof("));\n") - 1 }; str__ptr(&__sc1436); })));
    return true;
  }
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    const ast__ast__BuiltinType b = y.as_data.builtin;
    if (b == ast__ast__BuiltinType_BT_BOOL) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1437 = (str){ (const uint8_t *)"if (", sizeof("if (") - 1 }; str__ptr(&__sc1437); })));
      codegen__codegen__Codegen__emit_expr(self, arg);
      ({ String__Global *__sc1438 = &(self->buf);
String__Global__push_str(&(*__sc1438), (str){ .ptr = (const uint8_t*)") String__Global__push_str(&", .len = sizeof(") String__Global__push_str(&") - 1 });
String__Global__push_str(&(*__sc1438), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1438), (str){ .ptr = (const uint8_t*)", (str){ .ptr = (const uint8_t*)\"true\", .len = 4 });", .len = sizeof(", (str){ .ptr = (const uint8_t*)\"true\", .len = 4 });") - 1 });
});
      ({ String__Global *__sc1439 = &(self->buf);
String__Global__push_str(&(*__sc1439), (str){ .ptr = (const uint8_t*)" else String__Global__push_str(&", .len = sizeof(" else String__Global__push_str(&") - 1 });
String__Global__push_str(&(*__sc1439), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1439), (str){ .ptr = (const uint8_t*)", (str){ .ptr = (const uint8_t*)\"false\", .len = 5 });\n", .len = sizeof(", (str){ .ptr = (const uint8_t*)\"false\", .len = 5 });\n") - 1 });
});
      return true;
    }
    if (b == ast__ast__BuiltinType_BT_CHAR) {
      ({ String__Global *__sc1440 = &(self->buf);
String__Global__push_str(&(*__sc1440), (str){ .ptr = (const uint8_t*)"String__Global__push_byte(&", .len = sizeof("String__Global__push_byte(&") - 1 });
String__Global__push_str(&(*__sc1440), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1440), (str){ .ptr = (const uint8_t*)", (uint8_t)(", .len = sizeof(", (uint8_t)(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1441 = (str){ (const uint8_t *)"));\n", sizeof("));\n") - 1 }; str__ptr(&__sc1441); })));
      return true;
    }
    if (codegen__codegen__bt_is_signed_int(b)) {
      ({ String__Global *__sc1442 = &(self->buf);
String__Global__push_str(&(*__sc1442), (str){ .ptr = (const uint8_t*)"String__Global__push_i64(&", .len = sizeof("String__Global__push_i64(&") - 1 });
String__Global__push_str(&(*__sc1442), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1442), (str){ .ptr = (const uint8_t*)", (int64_t)(", .len = sizeof(", (int64_t)(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1443 = (str){ (const uint8_t *)"));\n", sizeof("));\n") - 1 }; str__ptr(&__sc1443); })));
      return true;
    }
    if (codegen__codegen__bt_is_unsigned_int(b)) {
      ({ String__Global *__sc1444 = &(self->buf);
String__Global__push_str(&(*__sc1444), (str){ .ptr = (const uint8_t*)"String__Global__push_u64(&", .len = sizeof("String__Global__push_u64(&") - 1 });
String__Global__push_str(&(*__sc1444), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1444), (str){ .ptr = (const uint8_t*)", (uint64_t)(", .len = sizeof(", (uint64_t)(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1445 = (str){ (const uint8_t *)"));\n", sizeof("));\n") - 1 }; str__ptr(&__sc1445); })));
      return true;
    }
    if ((b == ast__ast__BuiltinType_BT_F32) || (b == ast__ast__BuiltinType_BT_F64)) {
      if (sp->prec >= 0) {
        ({ String__Global *__sc1446 = &(self->buf);
String__Global__push_str(&(*__sc1446), (str){ .ptr = (const uint8_t*)"String__Global__push_f64_prec(&", .len = sizeof("String__Global__push_f64_prec(&") - 1 });
String__Global__push_str(&(*__sc1446), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1446), (str){ .ptr = (const uint8_t*)", (double)(", .len = sizeof(", (double)(") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, arg);
        ({ String__Global *__sc1447 = &(self->buf);
String__Global__push_str(&(*__sc1447), (str){ .ptr = (const uint8_t*)"), ", .len = sizeof("), ") - 1 });
String__Global__push_i64(&(*__sc1447), (int64_t)(sp->prec));
String__Global__push_str(&(*__sc1447), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
      } else {
        ({ String__Global *__sc1448 = &(self->buf);
String__Global__push_str(&(*__sc1448), (str){ .ptr = (const uint8_t*)"String__Global__push_f64(&", .len = sizeof("String__Global__push_f64(&") - 1 });
String__Global__push_str(&(*__sc1448), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1448), (str){ .ptr = (const uint8_t*)", (double)(", .len = sizeof(", (double)(") - 1 });
});
        codegen__codegen__Codegen__emit_expr(self, arg);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1449 = (str){ (const uint8_t *)"));\n", sizeof("));\n") - 1 }; str__ptr(&__sc1449); })));
      }
      return true;
    }
    return false;
  }
  if (codegen__codegen__Codegen__cg_struct_name_is(self, (&y), ((const char *)({ __auto_type __sc1450 = (str){ (const uint8_t *)"str", sizeof("str") - 1 }; str__ptr(&__sc1450); })))) {
    ({ String__Global *__sc1451 = &(self->buf);
String__Global__push_str(&(*__sc1451), (str){ .ptr = (const uint8_t*)"String__Global__push_str(&", .len = sizeof("String__Global__push_str(&") - 1 });
String__Global__push_str(&(*__sc1451), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1451), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, arg);
    codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1452 = (str){ (const uint8_t *)");\n", sizeof(");\n") - 1 }; str__ptr(&__sc1452); })));
    return true;
  }
  if (codegen__codegen__Codegen__cg_struct_name_is(self, (&y), ((const char *)({ __auto_type __sc1453 = (str){ (const uint8_t *)"String", sizeof("String") - 1 }; str__ptr(&__sc1453); })))) {
    codegen__codegen__Buf200 sm = (codegen__codegen__Buf200){0};
    codegen__codegen__Codegen__render_type_id(self, t, ((const char *)({ __auto_type __sc1454 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc1454); })), ((char *)(&sm.b[0])), 200ULL);
    const char *const smp = ((const char *)(&sm.b[0]));
    if (codegen__codegen__Codegen__is_lvalue(self, arg)) {
      ({ String__Global *__sc1455 = &(self->buf);
String__Global__push_str(&(*__sc1455), (str){ .ptr = (const uint8_t*)"String__Global__push_str(&", .len = sizeof("String__Global__push_str(&") - 1 });
String__Global__push_str(&(*__sc1455), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1455), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1455), utils__errors__cstr(smp));
String__Global__push_str(&(*__sc1455), (str){ .ptr = (const uint8_t*)"__as_str(&(", .len = sizeof("__as_str(&(") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1456 = (str){ (const uint8_t *)")));\n", sizeof(")));\n") - 1 }; str__ptr(&__sc1456); })));
    } else {
      codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
      codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
      const char *const tmpp = ((const char *)(&tmp.b[0]));
      ({ String__Global *__sc1457 = &(self->buf);
String__Global__push_str(&(*__sc1457), (str){ .ptr = (const uint8_t*)"{ ", .len = sizeof("{ ") - 1 });
String__Global__push_str(&(*__sc1457), utils__errors__cstr(smp));
String__Global__push_str(&(*__sc1457), (str){ .ptr = (const uint8_t*)" ", .len = sizeof(" ") - 1 });
String__Global__push_str(&(*__sc1457), utils__errors__cstr(tmpp));
String__Global__push_str(&(*__sc1457), (str){ .ptr = (const uint8_t*)" = ", .len = sizeof(" = ") - 1 });
});
      codegen__codegen__Codegen__emit_expr(self, arg);
      ({ String__Global *__sc1458 = &(self->buf);
String__Global__push_str(&(*__sc1458), (str){ .ptr = (const uint8_t*)"; String__Global__push_str(&", .len = sizeof("; String__Global__push_str(&") - 1 });
String__Global__push_str(&(*__sc1458), utils__errors__cstr(tb));
String__Global__push_str(&(*__sc1458), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1458), utils__errors__cstr(smp));
String__Global__push_str(&(*__sc1458), (str){ .ptr = (const uint8_t*)"__as_str(&", .len = sizeof("__as_str(&") - 1 });
String__Global__push_str(&(*__sc1458), utils__errors__cstr(tmpp));
String__Global__push_str(&(*__sc1458), (str){ .ptr = (const uint8_t*)")); ", .len = sizeof(")); ") - 1 });
String__Global__push_str(&(*__sc1458), utils__errors__cstr(smp));
String__Global__push_str(&(*__sc1458), (str){ .ptr = (const uint8_t*)"__free(&", .len = sizeof("__free(&") - 1 });
String__Global__push_str(&(*__sc1458), utils__errors__cstr(tmpp));
String__Global__push_str(&(*__sc1458), (str){ .ptr = (const uint8_t*)"); }\n", .len = sizeof("); }\n") - 1 });
});
    }
    return true;
  }
  return false;
}

static __attribute__((unused)) bool codegen__codegen__Codegen__emit_format_arg(codegen__codegen__Codegen *const self, const char *const f, uint32_t const arg, const codegen__codegen__FmtSpec *const sp) {
  const uint32_t t = codegen__codegen__Codegen__subst_resolve(self, ast__ast__Ast__type_of(&((*codegen__codegen__Codegen__cur_ast(self))), arg));
  const ast__ast__Ty y = (*codegen__codegen__Codegen__type_at(self, t));
  if ((sp->prec >= 0) && (!((y.kind == ast__ast__TypeKind_TYPE_BUILTIN) && ((y.as_data.builtin == ast__ast__BuiltinType_BT_F32) || (y.as_data.builtin == ast__ast__BuiltinType_BT_F64))))) {
    return false;
  }
  if (sp->width <= 0) {
    return codegen__codegen__Codegen__fmt_arg_core(self, f, arg, sp, y, t);
  }
  const bool numeric = ((y.kind == ast__ast__TypeKind_TYPE_BUILTIN) && codegen__codegen__bt_is_numeric(y.as_data.builtin));
  const int32_t align = ({
    int32_t __sc1459;
    if (sp->align == 60) {
      __sc1459 = 0;
    } else if (sp->align == 94) {
      __sc1459 = 2;
    } else if (sp->align == 62) {
      __sc1459 = 1;
    } else if (numeric) {
      __sc1459 = 1;
    } else {
      __sc1459 = 0;
    }
    __sc1459;
  });
  const uint8_t fill = ({
    uint8_t __sc1460;
    if (sp->fill != 0U) {
      __sc1460 = sp->fill;
    } else {
      __sc1460 = 32U;
    }
    __sc1460;
  });
  if (codegen__codegen__Codegen__cg_struct_name_is(self, (&y), ((const char *)({ __auto_type __sc1461 = (str){ (const uint8_t *)"str", sizeof("str") - 1 }; str__ptr(&__sc1461); })))) {
    ({ String__Global *__sc1462 = &(self->buf);
String__Global__push_str(&(*__sc1462), (str){ .ptr = (const uint8_t*)"String__Global__push_padded(&", .len = sizeof("String__Global__push_padded(&") - 1 });
String__Global__push_str(&(*__sc1462), utils__errors__cstr(f));
String__Global__push_str(&(*__sc1462), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
    codegen__codegen__Codegen__emit_expr(self, arg);
    ({ String__Global *__sc1463 = &(self->buf);
String__Global__push_str(&(*__sc1463), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_i64(&(*__sc1463), (int64_t)(sp->width));
String__Global__push_str(&(*__sc1463), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_u64(&(*__sc1463), (uint64_t)(((uint32_t)fill)));
String__Global__push_str(&(*__sc1463), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_i64(&(*__sc1463), (int64_t)(align));
String__Global__push_str(&(*__sc1463), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
    return true;
  }
  codegen__codegen__Buf32 tmp = (codegen__codegen__Buf32){0};
  codegen__codegen__Codegen__fresh(self, ((char *)(&tmp.b[0])), 32ULL);
  const char *const tp = ((const char *)(&tmp.b[0]));
  ({ String__Global *__sc1464 = &(self->buf);
String__Global__push_str(&(*__sc1464), (str){ .ptr = (const uint8_t*)"{ String__Global ", .len = sizeof("{ String__Global ") - 1 });
String__Global__push_str(&(*__sc1464), utils__errors__cstr(tp));
String__Global__push_str(&(*__sc1464), (str){ .ptr = (const uint8_t*)" = String__Global__new();\n", .len = sizeof(" = String__Global__new();\n") - 1 });
});
  if (!codegen__codegen__Codegen__fmt_arg_core(self, tp, arg, sp, y, t)) {
    ({ String__Global *__sc1465 = &(self->buf);
String__Global__push_str(&(*__sc1465), (str){ .ptr = (const uint8_t*)"String__Global__free(&", .len = sizeof("String__Global__free(&") - 1 });
String__Global__push_str(&(*__sc1465), utils__errors__cstr(tp));
String__Global__push_str(&(*__sc1465), (str){ .ptr = (const uint8_t*)"); }\n", .len = sizeof("); }\n") - 1 });
});
    return false;
  }
  ({ String__Global *__sc1466 = &(self->buf);
String__Global__push_str(&(*__sc1466), (str){ .ptr = (const uint8_t*)"String__Global__push_padded(&", .len = sizeof("String__Global__push_padded(&") - 1 });
String__Global__push_str(&(*__sc1466), utils__errors__cstr(f));
String__Global__push_str(&(*__sc1466), (str){ .ptr = (const uint8_t*)", String__Global__as_str(&", .len = sizeof(", String__Global__as_str(&") - 1 });
String__Global__push_str(&(*__sc1466), utils__errors__cstr(tp));
String__Global__push_str(&(*__sc1466), (str){ .ptr = (const uint8_t*)"), ", .len = sizeof("), ") - 1 });
String__Global__push_i64(&(*__sc1466), (int64_t)(sp->width));
String__Global__push_str(&(*__sc1466), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_u64(&(*__sc1466), (uint64_t)(((uint32_t)fill)));
String__Global__push_str(&(*__sc1466), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_i64(&(*__sc1466), (int64_t)(align));
String__Global__push_str(&(*__sc1466), (str){ .ptr = (const uint8_t*)");\n", .len = sizeof(");\n") - 1 });
});
  ({ String__Global *__sc1467 = &(self->buf);
String__Global__push_str(&(*__sc1467), (str){ .ptr = (const uint8_t*)"String__Global__free(&", .len = sizeof("String__Global__free(&") - 1 });
String__Global__push_str(&(*__sc1467), utils__errors__cstr(tp));
String__Global__push_str(&(*__sc1467), (str){ .ptr = (const uint8_t*)"); }\n", .len = sizeof("); }\n") - 1 });
});
  return true;
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_fmt_cstr(codegen__codegen__Codegen *const self, size_t const a, size_t const b) {
  const uint8_t *const src = self->source;
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1468 = (str){ (const uint8_t *)"\"", sizeof("\"") - 1 }; str__ptr(&__sc1468); })));
  size_t i = a;
  while (i < b) {
    if ((((src[i] == 123U) || (src[i] == 125U)) && ((i + 1ULL) < b)) && (src[(i + 1ULL)] == src[i])) {
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)src[i])));
      (i = (i + 2ULL));
      continue;
    }
    if ((src[i] == 92U) && ((i + 1ULL) < b)) {
      const uint8_t e = src[(i + 1ULL)];
      if ((e == 120U) && ((i + 3ULL) < b)) {
        const int32_t v = ((({ int32_t __sc1469 = codegen__codegen__hex_val(src[(i + 2ULL)]); int64_t __sc1470 = (int64_t)(4); if ((uint64_t)__sc1470 >= 32) { __sc_panic("shift out of range"); } (int32_t)((uint32_t)((uint32_t)__sc1469 << __sc1470)); }) | codegen__codegen__hex_val(src[(i + 3ULL)])) & 0xFF);
        codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)v));
        (i = (i + 4ULL));
      } else if (e == 48U) {
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1471 = (str){ (const uint8_t *)"\\000", sizeof("\\000") - 1 }; str__ptr(&__sc1471); })));
        (i = (i + 2ULL));
      } else {
        String__Global__push_byte(&self->buf, 92U);
        String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)e)));
        (i = (i + 2ULL));
      }
      continue;
    }
    String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)src[i])));
    (i = (i + 1ULL));
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1472 = (str){ (const uint8_t *)"\"", sizeof("\"") - 1 }; str__ptr(&__sc1472); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_fmt_raw_cstr(codegen__codegen__Codegen *const self, size_t const a, size_t const b) {
  const uint8_t *const src = self->source;
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1473 = (str){ (const uint8_t *)"\"", sizeof("\"") - 1 }; str__ptr(&__sc1473); })));
  size_t i = a;
  while (i < b) {
    if ((((src[i] == 123U) || (src[i] == 125U)) && ((i + 1ULL) < b)) && (src[(i + 1ULL)] == src[i])) {
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)src[i])));
      (i = (i + 2ULL));
      continue;
    }
    const uint8_t byte = src[i];
    (i = (i + 1ULL));
    if ((byte == 34U) || (byte == 92U)) {
      String__Global__push_byte(&self->buf, 92U);
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)byte)));
    } else if (byte == 10U) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1474 = (str){ (const uint8_t *)"\\n", sizeof("\\n") - 1 }; str__ptr(&__sc1474); })));
    } else if (byte < 32U) {
      codegen__codegen__Codegen__emit_octal_escape(self, ((uint32_t)((int32_t)byte)));
    } else {
      String__Global__push_byte(&self->buf, ((uint8_t)((int32_t)byte)));
    }
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1475 = (str){ (const uint8_t *)"\"", sizeof("\"") - 1 }; str__ptr(&__sc1475); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_fmt_seg(codegen__codegen__Codegen *const self, const char *const f, bool const is_raw, size_t const from, size_t const to) {
  ({ String__Global *__sc1476 = &(self->buf);
String__Global__push_str(&(*__sc1476), (str){ .ptr = (const uint8_t*)"String__Global__push_str(&", .len = sizeof("String__Global__push_str(&") - 1 });
String__Global__push_str(&(*__sc1476), utils__errors__cstr(f));
String__Global__push_str(&(*__sc1476), (str){ .ptr = (const uint8_t*)", (str){ .ptr = (const uint8_t*)", .len = sizeof(", (str){ .ptr = (const uint8_t*)") - 1 });
});
  if (is_raw) {
    codegen__codegen__Codegen__emit_fmt_raw_cstr(self, from, to);
  } else {
    codegen__codegen__Codegen__emit_fmt_cstr(self, from, to);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1477 = (str){ (const uint8_t *)", .len = sizeof(", sizeof(", .len = sizeof(") - 1 }; str__ptr(&__sc1477); })));
  if (is_raw) {
    codegen__codegen__Codegen__emit_fmt_raw_cstr(self, from, to);
  } else {
    codegen__codegen__Codegen__emit_fmt_cstr(self, from, to);
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1478 = (str){ (const uint8_t *)") - 1 });\n", sizeof(") - 1 });\n") - 1 }; str__ptr(&__sc1478); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__macro_stem(const codegen__codegen__Codegen *const self, uint16_t const m, uint32_t const aggregate_name, char *const out, size_t const cap) {
  const size_t n = codegen__codegen__Codegen__render_qualified(self, m, aggregate_name, out, cap);
  size_t i = 0ULL;
  while ((i < n) && (i < cap)) {
    const char ch = out[i];
    if ((ch >= 97) && (ch <= 122)) {
      (out[i] = ((char)({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)ch), 32, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
    } else if (!(((ch >= 65) && (ch <= 90)) || ((ch >= 48) && (ch <= 57)))) {
      (out[i] = 95);
    }
    (i = (i + 1ULL));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__macro_finish(codegen__codegen__Codegen *const self, size_t const start) {
  if (String__Global__len(&self->buf) <= start) {
    return;
  }
  size_t endp = String__Global__len(&self->buf);
  while ((endp > start) && (String__Global__as_ptr(&self->buf)[(endp - 1ULL)] == 10U)) {
    (endp = (endp - 1ULL));
  }
  const size_t nlen = (endp - start);
  char *const tmp = ((char *)malloc(nlen));
  if (tmp == NULL) {
    utils__errors__oom();
  }
  memcpy(((void *)tmp), ((const void *)(String__Global__as_ptr(&self->buf) + start)), nlen);
  String__Global__truncate(&self->buf, start);
  for (size_t i = 0ULL; i < nlen; i++) {
    const char ch = tmp[i];
    if (ch == 10) {
      codegen__codegen__Codegen__emit_bytes(self, ((const char *)({ __auto_type __sc1479 = (str){ (const uint8_t *)" \\\n", sizeof(" \\\n") - 1 }; str__ptr(&__sc1479); })), 3ULL);
    } else if (ch == codegen__codegen__CG_PASTE) {
      codegen__codegen__Codegen__emit_bytes(self, ((const char *)({ __auto_type __sc1480 = (str){ (const uint8_t *)"##", sizeof("##") - 1 }; str__ptr(&__sc1480); })), 2ULL);
    } else {
      codegen__codegen__Codegen__emit_bytes(self, ((const char *)(tmp + i)), 1ULL);
    }
  }
  codegen__codegen__Codegen__emit_bytes(self, ((const char *)({ __auto_type __sc1481 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1481); })), 1ULL);
  free(((void *)tmp));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_macro_methods(codegen__codegen__Codegen *const self, uint32_t const declId, bool const define) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const iids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = iids[((size_t)i)];
    const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if ((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.generics.len == 0U)) {
      continue;
    }
    if (ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type) != declId) {
      continue;
    }
    if (ed.interface_type != ast__ast__NODE_NONE) {
      continue;
    }
    const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ed.items);
    for (uint32_t j = 0U; j < ed.items.len; j++) {
      const uint32_t mid = mids[((size_t)j)];
      const ast__ast__FunctionData mf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.function;
      const ast__ast__NodeKind mk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
      if (((mk != ast__ast__NodeKind_NODE_FUNCTION) || (mf.generics.len != 0U)) || (mf.returns.len > 1U)) {
        continue;
      }
      if (define && (mf.body == ast__ast__NODE_NONE)) {
        continue;
      }
      codegen__codegen__Buf320 nm = (codegen__codegen__Buf320){0};
      size_t at = codegen__codegen__bappend(((char *)(&nm.b[0])), 320ULL, 0ULL, ((const char *)({ __auto_type __sc1482 = (str){ (const uint8_t *)"NAME", sizeof("NAME") - 1 }; str__ptr(&__sc1482); })));
      (nm.b[at] = codegen__codegen__CG_PASTE);
      (at = (at + 1ULL));
      (at = codegen__codegen__bappend(((char *)(&nm.b[0])), 320ULL, at, ((const char *)({ __auto_type __sc1483 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1483); }))));
      const lexer__token__Span mnsp = codegen__codegen__Codegen__name_span(self, mf.name);
      codegen__codegen__Codegen__render_ident(self, mnsp, ((char *)(((char *)(&nm.b[0])) + at)), (320ULL - at));
      codegen__codegen__Codegen__emit_function(self, mid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, define, ((const char *)(&nm.b[0])), false);
    }
  }
}

static __attribute__((unused)) size_t codegen__codegen__Codegen__conformance_tag(const codegen__codegen__Codegen *const self, uint32_t const extend_id, char *const out, size_t const cap) {
  const ast__ast__DefId it = ast__ast__Ast__resolution_def(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), extend_id)->as_data.extend_def.interface_type);
  const size_t at = codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc1484 = (str){ (const uint8_t *)"as_", sizeof("as_") - 1 }; str__ptr(&__sc1484); })));
  if (it.node == ast__ast__NODE_NONE) {
    return at;
  }
  const uint32_t trname = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), it.node)->as_data.interface_def.name;
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__mod_ast(self, it.module))), trname)->as_data.name.text;
  const size_t room = ({
    size_t __sc1485;
    if (cap > at) {
      __sc1485 = (cap - at);
    } else {
      __sc1485 = 0ULL;
    }
    __sc1485;
  });
  return (at + codegen__codegen__render_ident_src(codegen__codegen__Codegen__mod_src(self, it.module), sp, ((char *)(out + at)), room));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_conformance_macro(codegen__codegen__Codegen *const self, uint32_t const declId, uint32_t const implId, bool const define) {
  const uint32_t dn_name = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.name;
  codegen__codegen__Buf160 stem = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__macro_stem(self, codegen__codegen__Codegen__cur_module(self), dn_name, ((char *)(&stem.b[0])), 160ULL);
  codegen__codegen__Buf128 tag = (codegen__codegen__Buf128){0};
  codegen__codegen__Codegen__conformance_tag(self, implId, ((char *)(&tag.b[0])), 128ULL);
  const char *const word = ({
    const char *__sc1486;
    if (define) {
      __sc1486 = ((const char *)({ __auto_type __sc1487 = (str){ (const uint8_t *)"DEFINE", sizeof("DEFINE") - 1 }; str__ptr(&__sc1487); }));
    } else {
      __sc1486 = ((const char *)({ __auto_type __sc1488 = (str){ (const uint8_t *)"DECLARE", sizeof("DECLARE") - 1 }; str__ptr(&__sc1488); }));
    }
    __sc1486;
  });
  ({ String__Global *__sc1489 = &(self->buf);
String__Global__push_str(&(*__sc1489), (str){ .ptr = (const uint8_t*)"#define ", .len = sizeof("#define ") - 1 });
String__Global__push_str(&(*__sc1489), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc1489), (str){ .ptr = (const uint8_t*)"_", .len = sizeof("_") - 1 });
String__Global__push_str(&(*__sc1489), utils__errors__cstr(((const char *)(&tag.b[0]))));
String__Global__push_str(&(*__sc1489), (str){ .ptr = (const uint8_t*)"_", .len = sizeof("_") - 1 });
String__Global__push_str(&(*__sc1489), utils__errors__cstr(word));
String__Global__push_str(&(*__sc1489), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
});
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.generics;
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
  for (uint32_t i = 0U; i < gens.len; i++) {
    codegen__codegen__Buf64 p = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_macro_param(self, codegen__codegen__Codegen__cur_module(self), gids[((size_t)i)], ((char *)(&p.b[0])), 64ULL);
    ({ String__Global *__sc1490 = &(self->buf);
String__Global__push_str(&(*__sc1490), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1490), (str){ .ptr = (const uint8_t*)", _SCM_", .len = sizeof(", _SCM_") - 1 });
String__Global__push_str(&(*__sc1490), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1490), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1491 = (str){ (const uint8_t *)"NAME) ", sizeof("NAME) ") - 1 }; str__ptr(&__sc1491); })));
  (self->macro_mode = true);
  (self->macro_self = declId);
  (self->macro_self_mod = codegen__codegen__Codegen__cur_module(self));
  (self->nsubst = 0);
  const size_t start = String__Global__len(&self->buf);
  const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), implId)->as_data.extend_def.items);
  const uint32_t msn = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), implId)->as_data.extend_def.items.len;
  for (uint32_t j = 0U; j < msn; j++) {
    const uint32_t mid = mids[((size_t)j)];
    const ast__ast__FunctionData mf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.function;
    const ast__ast__NodeKind mk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
    if (((mk != ast__ast__NodeKind_NODE_FUNCTION) || (mf.generics.len != 0U)) || (mf.returns.len > 1U)) {
      continue;
    }
    if (define && (mf.body == ast__ast__NODE_NONE)) {
      continue;
    }
    codegen__codegen__Buf320 nm = (codegen__codegen__Buf320){0};
    size_t at = codegen__codegen__bappend(((char *)(&nm.b[0])), 320ULL, 0ULL, ((const char *)({ __auto_type __sc1492 = (str){ (const uint8_t *)"NAME", sizeof("NAME") - 1 }; str__ptr(&__sc1492); })));
    (nm.b[at] = codegen__codegen__CG_PASTE);
    (at = (at + 1ULL));
    (at = codegen__codegen__bappend(((char *)(&nm.b[0])), 320ULL, at, ((const char *)({ __auto_type __sc1493 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1493); }))));
    const lexer__token__Span mnsp = codegen__codegen__Codegen__name_span(self, mf.name);
    codegen__codegen__Codegen__render_ident(self, mnsp, ((char *)(((char *)(&nm.b[0])) + at)), (320ULL - at));
    codegen__codegen__Codegen__emit_function(self, mid, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, define, ((const char *)(&nm.b[0])), false);
  }
  (self->macro_mode = false);
  (self->macro_self = ast__ast__NODE_NONE);
  codegen__codegen__Codegen__macro_finish(self, start);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1494 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1494); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_conformance_macros(codegen__codegen__Codegen *const self, uint32_t const declId) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const iids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = iids[((size_t)i)];
    const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if (((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.generics.len == 0U)) || (ed.interface_type == ast__ast__NODE_NONE)) {
      continue;
    }
    if (ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type) != declId) {
      continue;
    }
    codegen__codegen__Codegen__emit_generic_conformance_macro(self, declId, nid, false);
    codegen__codegen__Codegen__emit_generic_conformance_macro(self, declId, nid, true);
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_macro(codegen__codegen__Codegen *const self, uint32_t const declId, bool const define) {
  const uint32_t dn_name = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.name;
  const ast__ast__NodeKind dn_kind = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->kind;
  codegen__codegen__Buf160 stem = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__macro_stem(self, codegen__codegen__Codegen__cur_module(self), dn_name, ((char *)(&stem.b[0])), 160ULL);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.generics;
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
  const char *const word = ({
    const char *__sc1495;
    if (define) {
      __sc1495 = ((const char *)({ __auto_type __sc1496 = (str){ (const uint8_t *)"DEFINE", sizeof("DEFINE") - 1 }; str__ptr(&__sc1496); }));
    } else {
      __sc1495 = ((const char *)({ __auto_type __sc1497 = (str){ (const uint8_t *)"DECLARE", sizeof("DECLARE") - 1 }; str__ptr(&__sc1497); }));
    }
    __sc1495;
  });
  ({ String__Global *__sc1498 = &(self->buf);
String__Global__push_str(&(*__sc1498), (str){ .ptr = (const uint8_t*)"#define ", .len = sizeof("#define ") - 1 });
String__Global__push_str(&(*__sc1498), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc1498), (str){ .ptr = (const uint8_t*)"_", .len = sizeof("_") - 1 });
String__Global__push_str(&(*__sc1498), utils__errors__cstr(word));
String__Global__push_str(&(*__sc1498), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
});
  for (uint32_t i = 0U; i < gens.len; i++) {
    codegen__codegen__Buf64 p = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_macro_param(self, codegen__codegen__Codegen__cur_module(self), gids[((size_t)i)], ((char *)(&p.b[0])), 64ULL);
    ({ String__Global *__sc1499 = &(self->buf);
String__Global__push_str(&(*__sc1499), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1499), (str){ .ptr = (const uint8_t*)", _SCM_", .len = sizeof(", _SCM_") - 1 });
String__Global__push_str(&(*__sc1499), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1499), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1500 = (str){ (const uint8_t *)"NAME) ", sizeof("NAME) ") - 1 }; str__ptr(&__sc1500); })));
  (self->macro_mode = true);
  (self->macro_self = declId);
  (self->macro_self_mod = codegen__codegen__Codegen__cur_module(self));
  (self->nsubst = 0);
  const size_t start = String__Global__len(&self->buf);
  if (!define) {
    if (dn_kind == ast__ast__NodeKind_NODE_STRUCT) {
      const char *const kw = codegen__codegen__agg_kw(ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId));
      ({ String__Global *__sc1501 = &(self->buf);
String__Global__push_str(&(*__sc1501), (str){ .ptr = (const uint8_t*)"typedef ", .len = sizeof("typedef ") - 1 });
String__Global__push_str(&(*__sc1501), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1501), (str){ .ptr = (const uint8_t*)" NAME NAME;\n", .len = sizeof(" NAME NAME;\n") - 1 });
});
      ({ String__Global *__sc1502 = &(self->buf);
String__Global__push_str(&(*__sc1502), utils__errors__cstr(kw));
String__Global__push_str(&(*__sc1502), (str){ .ptr = (const uint8_t*)" NAME {\n", .len = sizeof(" NAME {\n") - 1 });
});
      (self->depth = (self->depth + 1U));
      const ast__ast__NodeList fs = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.members;
      const uint32_t *const fids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), fs);
      for (uint32_t jj = 0U; jj < fs.len; jj++) {
        const ast__ast__FieldData f = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), fids[((size_t)jj)])->as_data.field;
        codegen__codegen__Buf128 fnm = (codegen__codegen__Buf128){0};
        const lexer__token__Span fnsp = codegen__codegen__Codegen__name_span(self, f.name);
        codegen__codegen__Codegen__render_ident(self, fnsp, ((char *)(&fnm.b[0])), 128ULL);
        codegen__codegen__Buf256 dd = (codegen__codegen__Buf256){0};
        codegen__codegen__Codegen__render_type_node(self, f.ty, ((const char *)(&fnm.b[0])), ((char *)(&dd.b[0])), 256ULL);
        codegen__codegen__Codegen__emit_indent(self);
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)(&dd.b[0])));
        codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1503 = (str){ (const uint8_t *)";\n", sizeof(";\n") - 1 }; str__ptr(&__sc1503); })));
      }
      (self->depth = (self->depth - 1U));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1504 = (str){ (const uint8_t *)"};\n", sizeof("};\n") - 1 }; str__ptr(&__sc1504); })));
    } else if (codegen__codegen__Codegen__aggregate_has_payload(self, declId)) {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1505 = (str){ (const uint8_t *)"typedef struct NAME NAME;\n", sizeof("typedef struct NAME NAME;\n") - 1 }; str__ptr(&__sc1505); })));
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1506 = (str){ (const uint8_t *)"struct NAME {\n", sizeof("struct NAME {\n") - 1 }; str__ptr(&__sc1506); })));
      codegen__codegen__Codegen__emit_enum_struct_body(self, declId);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1507 = (str){ (const uint8_t *)"};\n", sizeof("};\n") - 1 }; str__ptr(&__sc1507); })));
    } else {
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1508 = (str){ (const uint8_t *)"typedef ", sizeof("typedef ") - 1 }; str__ptr(&__sc1508); })));
      codegen__codegen__Codegen__emit_local_type_name(self, dn_name);
      codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1509 = (str){ (const uint8_t *)" NAME;\n", sizeof(" NAME;\n") - 1 }; str__ptr(&__sc1509); })));
    }
  }
  codegen__codegen__Codegen__emit_generic_macro_methods(self, declId, define);
  (self->macro_mode = false);
  (self->macro_self = ast__ast__NODE_NONE);
  codegen__codegen__Codegen__macro_finish(self, start);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1510 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1510); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__macro_method_name(const codegen__codegen__Codegen *const self, uint32_t const methodId, char *const out, size_t const cap) {
  const uint32_t mnnode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), methodId)->as_data.function.name;
  const lexer__token__Span mnsp = codegen__codegen__Codegen__name_span(self, mnnode);
  size_t at = codegen__codegen__bappend(out, cap, 0ULL, ((const char *)({ __auto_type __sc1511 = (str){ (const uint8_t *)"NAME", sizeof("NAME") - 1 }; str__ptr(&__sc1511); })));
  if (at < cap) {
    (out[at] = codegen__codegen__CG_PASTE);
    (at = (at + 1ULL));
  }
  (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc1512 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1512); }))));
  (at = (at + codegen__codegen__Codegen__render_ident(self, mnsp, ((char *)(out + at)), (cap - at))));
  (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc1513 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1513); }))));
  const ast__ast__NodeList mg = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), methodId)->as_data.function.generics;
  const uint32_t *const mgids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), mg);
  for (uint32_t k = 0U; k < mg.len; k++) {
    if (k != 0U) {
      if (at < cap) {
        (out[at] = codegen__codegen__CG_PASTE);
        (at = (at + 1ULL));
      }
      (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc1514 = (str){ (const uint8_t *)"__", sizeof("__") - 1 }; str__ptr(&__sc1514); }))));
    }
    if (at < cap) {
      (out[at] = codegen__codegen__CG_PASTE);
      (at = (at + 1ULL));
    }
    (at = codegen__codegen__bappend(out, cap, at, ((const char *)({ __auto_type __sc1515 = (str){ (const uint8_t *)"_SCM_", sizeof("_SCM_") - 1 }; str__ptr(&__sc1515); }))));
    (at = (at + codegen__codegen__Codegen__render_macro_param(self, codegen__codegen__Codegen__cur_module(self), mgids[((size_t)k)], ((char *)(out + at)), (cap - at))));
  }
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_method_macro(codegen__codegen__Codegen *const self, uint32_t const declId, uint32_t const methodId, bool const define) {
  const uint32_t dn_name = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.name;
  codegen__codegen__Buf160 stem = (codegen__codegen__Buf160){0};
  codegen__codegen__Codegen__macro_stem(self, codegen__codegen__Codegen__cur_module(self), dn_name, ((char *)(&stem.b[0])), 160ULL);
  const uint32_t mnnode = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), methodId)->as_data.function.name;
  codegen__codegen__Buf64 mnm = (codegen__codegen__Buf64){0};
  const lexer__token__Span mnsp = codegen__codegen__Codegen__name_span(self, mnnode);
  codegen__codegen__Codegen__render_ident(self, mnsp, ((char *)(&mnm.b[0])), 64ULL);
  const char *const word = ({
    const char *__sc1516;
    if (define) {
      __sc1516 = ((const char *)({ __auto_type __sc1517 = (str){ (const uint8_t *)"DEFINE", sizeof("DEFINE") - 1 }; str__ptr(&__sc1517); }));
    } else {
      __sc1516 = ((const char *)({ __auto_type __sc1518 = (str){ (const uint8_t *)"DECLARE", sizeof("DECLARE") - 1 }; str__ptr(&__sc1518); }));
    }
    __sc1516;
  });
  ({ String__Global *__sc1519 = &(self->buf);
String__Global__push_str(&(*__sc1519), (str){ .ptr = (const uint8_t*)"#define ", .len = sizeof("#define ") - 1 });
String__Global__push_str(&(*__sc1519), utils__errors__cstr(((const char *)(&stem.b[0]))));
String__Global__push_str(&(*__sc1519), (str){ .ptr = (const uint8_t*)"_", .len = sizeof("_") - 1 });
String__Global__push_str(&(*__sc1519), utils__errors__cstr(((const char *)(&mnm.b[0]))));
String__Global__push_str(&(*__sc1519), (str){ .ptr = (const uint8_t*)"_", .len = sizeof("_") - 1 });
String__Global__push_str(&(*__sc1519), utils__errors__cstr(word));
String__Global__push_str(&(*__sc1519), (str){ .ptr = (const uint8_t*)"(", .len = sizeof("(") - 1 });
});
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), declId)->as_data.aggregate.generics;
  const uint32_t *const gids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), gens);
  for (uint32_t i = 0U; i < gens.len; i++) {
    codegen__codegen__Buf64 p = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_macro_param(self, codegen__codegen__Codegen__cur_module(self), gids[((size_t)i)], ((char *)(&p.b[0])), 64ULL);
    ({ String__Global *__sc1520 = &(self->buf);
String__Global__push_str(&(*__sc1520), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1520), (str){ .ptr = (const uint8_t*)", _SCM_", .len = sizeof(", _SCM_") - 1 });
String__Global__push_str(&(*__sc1520), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1520), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1521 = (str){ (const uint8_t *)"NAME", sizeof("NAME") - 1 }; str__ptr(&__sc1521); })));
  const ast__ast__NodeList mg = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), methodId)->as_data.function.generics;
  const uint32_t *const mgids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), mg);
  for (uint32_t k = 0U; k < mg.len; k++) {
    codegen__codegen__Buf64 p = (codegen__codegen__Buf64){0};
    codegen__codegen__Codegen__render_macro_param(self, codegen__codegen__Codegen__cur_module(self), mgids[((size_t)k)], ((char *)(&p.b[0])), 64ULL);
    ({ String__Global *__sc1522 = &(self->buf);
String__Global__push_str(&(*__sc1522), (str){ .ptr = (const uint8_t*)", ", .len = sizeof(", ") - 1 });
String__Global__push_str(&(*__sc1522), utils__errors__cstr(((const char *)(&p.b[0]))));
String__Global__push_str(&(*__sc1522), (str){ .ptr = (const uint8_t*)", _SCM_", .len = sizeof(", _SCM_") - 1 });
String__Global__push_str(&(*__sc1522), utils__errors__cstr(((const char *)(&p.b[0]))));
});
  }
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1523 = (str){ (const uint8_t *)") ", sizeof(") ") - 1 }; str__ptr(&__sc1523); })));
  (self->macro_mode = true);
  (self->macro_self = declId);
  (self->macro_self_mod = codegen__codegen__Codegen__cur_module(self));
  (self->nsubst = 0);
  const size_t start = String__Global__len(&self->buf);
  codegen__codegen__Buf400 ov = (codegen__codegen__Buf400){0};
  codegen__codegen__Codegen__macro_method_name(self, methodId, ((char *)(&ov.b[0])), 400ULL);
  codegen__codegen__Codegen__emit_function(self, methodId, (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE }, false, define, ((const char *)(&ov.b[0])), false);
  (self->macro_mode = false);
  (self->macro_self = ast__ast__NODE_NONE);
  codegen__codegen__Codegen__macro_finish(self, start);
  codegen__codegen__Codegen__emit_cstr(self, ((const char *)({ __auto_type __sc1524 = (str){ (const uint8_t *)"\n", sizeof("\n") - 1 }; str__ptr(&__sc1524); })));
}

static __attribute__((unused)) void codegen__codegen__Codegen__emit_generic_method_macros(codegen__codegen__Codegen *const self, uint32_t const declId) {
  const ast__ast__NodeList items = codegen__codegen__Codegen__program_items(self);
  const uint32_t *const iids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), items);
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t nid = iids[((size_t)i)];
    const ast__ast__ExtendData ed = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->as_data.extend_def;
    const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), nid)->kind;
    if ((nk != ast__ast__NodeKind_NODE_EXTEND) || (ed.generics.len == 0U)) {
      continue;
    }
    if (ast__ast__Ast__resolution(&((*codegen__codegen__Codegen__cur_ast(self))), ed.target_type) != declId) {
      continue;
    }
    const uint32_t *const mids = ast__ast__Ast__list(&((*codegen__codegen__Codegen__cur_ast(self))), ed.items);
    for (uint32_t j = 0U; j < ed.items.len; j++) {
      const uint32_t mid = mids[((size_t)j)];
      const ast__ast__FunctionData mf = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->as_data.function;
      const ast__ast__NodeKind mk = ast__ast__Ast__at_const(&((*codegen__codegen__Codegen__cur_ast(self))), mid)->kind;
      if (((mk == ast__ast__NodeKind_NODE_FUNCTION) && (mf.generics.len != 0U)) && (mf.returns.len <= 1U)) {
        codegen__codegen__Codegen__emit_generic_method_macro(self, declId, mid, false);
        codegen__codegen__Codegen__emit_generic_method_macro(self, declId, mid, true);
      }
    }
  }
}

