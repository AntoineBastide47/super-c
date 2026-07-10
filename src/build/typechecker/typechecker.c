#include "../typechecker/typechecker.h"
#include "../stdio.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../ast/ast.h"
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

_Static_assert(sizeof(typechecker__typechecker__Buf96) == 96 && _Alignof(typechecker__typechecker__Buf96) == 1, "super-c layout model mismatch: typechecker__typechecker__Buf96");
_Static_assert(sizeof(typechecker__typechecker__Buf512) == 512 && _Alignof(typechecker__typechecker__Buf512) == 1, "super-c layout model mismatch: typechecker__typechecker__Buf512");
_Static_assert(sizeof(typechecker__typechecker__Defs4) == 32 && _Alignof(typechecker__typechecker__Defs4) == 4, "super-c layout model mismatch: typechecker__typechecker__Defs4");
_Static_assert(sizeof(typechecker__typechecker__Tys4) == 16 && _Alignof(typechecker__typechecker__Tys4) == 4, "super-c layout model mismatch: typechecker__typechecker__Tys4");
_Static_assert(sizeof(typechecker__typechecker__Defs8) == 64 && _Alignof(typechecker__typechecker__Defs8) == 4, "super-c layout model mismatch: typechecker__typechecker__Defs8");
_Static_assert(sizeof(typechecker__typechecker__Tys8) == 32 && _Alignof(typechecker__typechecker__Tys8) == 4, "super-c layout model mismatch: typechecker__typechecker__Tys8");
_Static_assert(sizeof(typechecker__typechecker__BoundArr8) == 224 && _Alignof(typechecker__typechecker__BoundArr8) == 4, "super-c layout model mismatch: typechecker__typechecker__BoundArr8");
_Static_assert(sizeof(typechecker__typechecker__Names14) == 112 && _Alignof(typechecker__typechecker__Names14) == 8, "super-c layout model mismatch: typechecker__typechecker__Names14");
_Static_assert(sizeof(typechecker__typechecker__Steps16) == 384 && _Alignof(typechecker__typechecker__Steps16) == 8, "super-c layout model mismatch: typechecker__typechecker__Steps16");
_Static_assert(sizeof(typechecker__typechecker__Keep256) == 256 && _Alignof(typechecker__typechecker__Keep256) == 1, "super-c layout model mismatch: typechecker__typechecker__Keep256");
_Static_assert(sizeof(typechecker__typechecker__Cover4) == 32 && _Alignof(typechecker__typechecker__Cover4) == 8, "super-c layout model mismatch: typechecker__typechecker__Cover4");
_Static_assert(sizeof(typechecker__typechecker__Buf128) == 128 && _Alignof(typechecker__typechecker__Buf128) == 1, "super-c layout model mismatch: typechecker__typechecker__Buf128");
_Static_assert(sizeof(typechecker__typechecker__NodeArr16) == 64 && _Alignof(typechecker__typechecker__NodeArr16) == 4, "super-c layout model mismatch: typechecker__typechecker__NodeArr16");
_Static_assert(sizeof(typechecker__typechecker__Borrow) == 20 && _Alignof(typechecker__typechecker__Borrow) == 4, "super-c layout model mismatch: typechecker__typechecker__Borrow");
_Static_assert(sizeof(typechecker__typechecker__PStep) == 24 && _Alignof(typechecker__typechecker__PStep) == 8, "super-c layout model mismatch: typechecker__typechecker__PStep");
_Static_assert(sizeof(typechecker__typechecker__BoundIface) == 28 && _Alignof(typechecker__typechecker__BoundIface) == 4, "super-c layout model mismatch: typechecker__typechecker__BoundIface");
_Static_assert(sizeof(typechecker__typechecker__LoopEntry) == 20 && _Alignof(typechecker__typechecker__LoopEntry) == 4, "super-c layout model mismatch: typechecker__typechecker__LoopEntry");
_Static_assert(sizeof(typechecker__typechecker__ClosScope) == 4 && _Alignof(typechecker__typechecker__ClosScope) == 4, "super-c layout model mismatch: typechecker__typechecker__ClosScope");
_Static_assert(sizeof(typechecker__typechecker__FlowState) == 2832 && _Alignof(typechecker__typechecker__FlowState) == 4, "super-c layout model mismatch: typechecker__typechecker__FlowState");
_Static_assert(sizeof(typechecker__typechecker__TypeChecker) == 14840 && _Alignof(typechecker__typechecker__TypeChecker) == 8, "super-c layout model mismatch: typechecker__typechecker__TypeChecker");
_Static_assert(sizeof(typechecker__typechecker__FnSig) == 24 && _Alignof(typechecker__typechecker__FnSig) == 4, "super-c layout model mismatch: typechecker__typechecker__FnSig");
_Static_assert(sizeof(typechecker__typechecker__SliceKind) == 8 && _Alignof(typechecker__typechecker__SliceKind) == 4, "super-c layout model mismatch: typechecker__typechecker__SliceKind");
_Static_assert(sizeof(typechecker__typechecker__BoxOf) == 12 && _Alignof(typechecker__typechecker__BoxOf) == 4, "super-c layout model mismatch: typechecker__typechecker__BoxOf");
_Static_assert(sizeof(typechecker__typechecker__RecvSubst) == 52 && _Alignof(typechecker__typechecker__RecvSubst) == 4, "super-c layout model mismatch: typechecker__typechecker__RecvSubst");

static __attribute__((unused)) void typechecker__typechecker__bt_widens_helper(void);
static __attribute__((unused)) bool typechecker__typechecker__span_is(const uint8_t *const src, lexer__token__Span const s, str const lit);
static __attribute__((unused)) bool typechecker__typechecker__spans_eq2(const uint8_t *const sa, lexer__token__Span const a, const uint8_t *const sb, lexer__token__Span const b);
static __attribute__((unused)) str typechecker__typechecker__builtin_name(ast__ast__BuiltinType const b);
static __attribute__((unused)) int32_t typechecker__typechecker__builtin_of(const uint8_t *const src, lexer__token__Span const s);
static __attribute__((unused)) bool typechecker__typechecker__bt_is_int(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool typechecker__typechecker__bt_is_float(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool typechecker__typechecker__bt_is_complex(ast__ast__BuiltinType const b);
static __attribute__((unused)) uint64_t typechecker__typechecker__bt_int_max(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool typechecker__typechecker__tc_lit_in_range(ast__ast__BuiltinType const b, uint64_t const mag, bool const neg);
static __attribute__((unused)) bool typechecker__typechecker__bt_widens(ast__ast__BuiltinType const from, ast__ast__BuiltinType const to);
static __attribute__((unused)) uint32_t typechecker__typechecker__hex_digit(uint8_t const c);
static __attribute__((unused)) ast__ast__Ast *typechecker__typechecker__TypeChecker__cur_ast(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) uint16_t typechecker__typechecker__TypeChecker__cur_module(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__has_pkg(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) ast__ast__Ast *typechecker__typechecker__TypeChecker__mod_ast(const typechecker__typechecker__TypeChecker *const self, uint16_t const m);
static __attribute__((unused)) const uint8_t *typechecker__typechecker__TypeChecker__mod_src(const typechecker__typechecker__TypeChecker *const self, uint16_t const m);
static __attribute__((unused)) size_t typechecker__typechecker__TypeChecker__pkg_count(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) consteval__consteval__ConstEval *typechecker__typechecker__TypeChecker__ceval(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) lexer__token__Span typechecker__typechecker__TypeChecker__name_span(const typechecker__typechecker__TypeChecker *const self, uint32_t const name_node);
static __attribute__((unused)) const ast__ast__Ty *typechecker__typechecker__TypeChecker__type_at(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__at_not_fn(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_bool(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_int(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_numeric(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_void_type(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) ast__ast__BuiltinType typechecker__typechecker__TypeChecker__bt_of(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_plain_enum(const typechecker__typechecker__TypeChecker *const self, uint32_t const x);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__strip(const typechecker__typechecker__TypeChecker *const self, uint32_t const x0);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_ref(typechecker__typechecker__TypeChecker *const self, uint32_t const elem, bool const mut2);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tc_loop_push(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const label, uint32_t const node, bool const value_loop);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_loop_pop(typechecker__typechecker__TypeChecker *const self, int32_t const le, lexer__token__Span const sp);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tc_find_loop(const typechecker__typechecker__TypeChecker *const self, lexer__token__Span const label);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_is_test_fn(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const fnode);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_in_test_fn(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_check_test_ref(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const d, lexer__token__Span const sp);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_literal_pinned(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_integer_literal_node(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) typechecker__typechecker__BoxOf typechecker__typechecker__TypeChecker__tc_literal_u64(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__lit_mag(const typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint64_t *const out);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__char_literal_cp(const typechecker__typechecker__TypeChecker *const self, lexer__token__Span const s);
static __attribute__((cold, noinline, unused)) void typechecker__typechecker__TypeChecker__err_unsafe(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const sp, str const what);
static __attribute__((unused)) const ast__ast__Attr *typechecker__typechecker__TypeChecker__tc_attr(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const owner, ast__ast__AttrKind const kind);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__peel_wrappers(const typechecker__typechecker__TypeChecker *const self, uint32_t const id0);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__through_raw_pointer(const typechecker__typechecker__TypeChecker *const self, uint32_t const ty0);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__render_type(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, char *const buf, size_t const cap);
static __attribute__((cold, noinline, unused)) void typechecker__typechecker__TypeChecker__err_mismatch(typechecker__typechecker__TypeChecker *const self, uint32_t const node, uint32_t const expected);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__fn_sig(typechecker__typechecker__TypeChecker *const self, uint32_t const fid, uint32_t *const params, int32_t const cap, uint32_t *const ret);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__receiver_type_eq(const typechecker__typechecker__TypeChecker *const self, uint32_t const a, uint32_t const b);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__generic_fn_bound(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_is_capturing(const typechecker__typechecker__TypeChecker *const self, uint32_t const fid);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tc_capture_index(const typechecker__typechecker__TypeChecker *const self, uint32_t const clos, uint32_t const decl);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_owns(typechecker__typechecker__TypeChecker *const self, uint32_t const fid);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_mark_capture_mut(typechecker__typechecker__TypeChecker *const self, uint32_t const expr0);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__ret_eq(const typechecker__typechecker__TypeChecker *const self, uint32_t const a, uint32_t const b);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_compatible(typechecker__typechecker__TypeChecker *const self, uint32_t const exid, uint32_t const acid);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dynfn_sig_ok(typechecker__typechecker__TypeChecker *const self, uint32_t const exid, uint32_t const acid);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_dyn_fn_sig(typechecker__typechecker__TypeChecker *const self, const ast__ast__Ty *const ty);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_dyn_same(typechecker__typechecker__TypeChecker *const self, const ast__ast__Ty *const a, const ast__ast__Ty *const b);
static __attribute__((unused)) uint32_t typechecker__typechecker__if_node(bool const c, uint32_t const a, uint32_t const b);
static __attribute__((unused)) uint32_t typechecker__typechecker__if_ty(bool const c, uint32_t const a, uint32_t const b);
static __attribute__((unused)) const char *typechecker__typechecker__src_at(const uint8_t *const p, uint32_t const off);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__aggregate_of(const typechecker__typechecker__TypeChecker *const self, uint32_t const ty, uint16_t *const mod_out, uint32_t *const decl_out, ast__ast__DefId *const params, uint32_t *const args, int32_t *const n_out);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__subst_type(typechecker__typechecker__TypeChecker *const self, uint32_t const ty, const ast__ast__DefId *const params, const uint32_t *const args, int32_t const n);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__unify_infer(typechecker__typechecker__TypeChecker *const self, uint32_t const param_ty, uint32_t const arg_ty, const ast__ast__DefId *const params, uint32_t *const bound, int32_t const n);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__named_type_of(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__agg_has_default_at(const typechecker__typechecker__TypeChecker *const self, uint16_t const dmod, uint32_t const dn, uint32_t const from);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__apply_default_args(typechecker__typechecker__TypeChecker *const self, uint16_t const dmod, uint32_t const dn, uint32_t *const ta, uint8_t *const tn);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_str_type(typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_slice_type(typechecker__typechecker__TypeChecker *const self, uint32_t const elem, bool const mut2);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_range_type(typechecker__typechecker__TypeChecker *const self, uint32_t const elem);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_tuple_type(typechecker__typechecker__TypeChecker *const self, const uint32_t *const args, uint32_t const n);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__prelude_instance_args(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, str const name, uint32_t *const out, int32_t const maxn);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tuple_args_of(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, uint32_t *const out, int32_t const maxn);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__range_instance_elem(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__slice_kind(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, uint32_t *const elem);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_box_of(const typechecker__typechecker__TypeChecker *const self, const ast__ast__Ty *const y, uint32_t *const inner, bool *const global_alloc);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__decl_type_in(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__decl_type(typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__type_of_type_node(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_const_arg(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const aid);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__ce_array_len(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const lenNode);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__lower_type_in(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__resolve_type(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_intern_dynfn(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const sig, ast__ast__TypeQualifier const qual);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__resolve_dyn_node(typechecker__typechecker__TypeChecker *const self, uint32_t const id, ast__ast__TypeQualifier const qual);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dyn_method(const typechecker__typechecker__TypeChecker *const self, uint16_t const imod, uint32_t const mnode);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_mentions_self(const typechecker__typechecker__TypeChecker *const self, uint16_t const imod, uint32_t const tn, ast__ast__DefId const iface);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dyn_compatible(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const iface, lexer__token__Span const at);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__ext_scopes(typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) uint16_t typechecker__typechecker__TypeChecker__ext_scope_at(const typechecker__typechecker__TypeChecker *const self, int32_t const i);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__ensure_ext_items(typechecker__typechecker__TypeChecker *const self, uint16_t const mm);
static __attribute__((unused)) size_t typechecker__typechecker__TypeChecker__ext_items_len(const typechecker__typechecker__TypeChecker *const self, uint16_t const mm);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__ext_items_at(const typechecker__typechecker__TypeChecker *const self, uint16_t const mm, size_t const i);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__tc_peel_target(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const tg);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_member(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_member_cstr(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, str const name);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__enclosing_extend(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const method);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__enclosing_trait(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const method);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_method_impl(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name, str const lit);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_method(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_method_cstr(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, str const lit);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_assoc_const(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_extend_as(typechecker__typechecker__TypeChecker *const self, uint16_t const tmod, uint32_t const tdecl, ast__ast__DefId const iface, uint16_t *const imod);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_interface_method(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const iface, lexer__token__Span const name, int32_t const depth);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_default_method(typechecker__typechecker__TypeChecker *const self, uint16_t const tmod, uint32_t const tdecl, lexer__token__Span const name);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__add_bound_ifaces_full(typechecker__typechecker__TypeChecker *const self, uint16_t const m, ast__ast__NodeList const bounds, typechecker__typechecker__BoundIface *const out, int32_t *const n, int32_t const cap);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__collect_param_bounds_full(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, typechecker__typechecker__BoundIface *const out, int32_t const cap);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__trait_contains_method(const typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const iface, ast__ast__DefId const method, int32_t const depth);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__bound_method_subst(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, ast__ast__DefId const method, ast__ast__DefId *const outp, uint32_t *const outa, int32_t const cap);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_bound_method(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, lexer__token__Span const name, ast__ast__DefId *const iface);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__interface_declares_cstr(const typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const iface, str const m, int32_t const depth);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_param_bound_provides(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, str const m);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__type_satisfies(typechecker__typechecker__TypeChecker *const self, uint32_t const ty, ast__ast__DefId const iface, int32_t const depth);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_free_iface(const typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const tr);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_param_has_free_bound(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const gp);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_type_is_free(typechecker__typechecker__TypeChecker *const self, uint32_t const ty);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__method_extend_bounds_hold(typechecker__typechecker__TypeChecker *const self, uint32_t const target, ast__ast__DefId const md);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__err_method_extend_bounds(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const at, uint32_t const target, ast__ast__DefId const md);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__mark_format_helpers(typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__resolve_conversion(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const name, uint32_t const want);
static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__tc_find_from_for(typechecker__typechecker__TypeChecker *const self, uint32_t const target, uint32_t const src);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dyn_coerce(typechecker__typechecker__TypeChecker *const self, uint32_t const node, uint32_t const src, uint32_t const dyn_ty);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__compatible(typechecker__typechecker__TypeChecker *const self, uint32_t const expected, uint32_t const node);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__return_list_is_explicit_void(typechecker__typechecker__TypeChecker *const self, ast__ast__NodeList const rets);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__range_type(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const start, uint32_t const end);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_path_static_mut(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_assignable(typechecker__typechecker__TypeChecker *const self, uint32_t const node_in);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_place(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__receiver_mutable(typechecker__typechecker__TypeChecker *const self, uint32_t const recv);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_binding_depth(const typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_record_binding_depth(typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_capture_move_guard(typechecker__typechecker__TypeChecker *const self, uint32_t const expr0);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_moved(const typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_mark_move(typechecker__typechecker__TypeChecker *const self, uint32_t const expr0);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_is_uninit(const typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_add_uninit(typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_init(typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_unmark_move(typechecker__typechecker__TypeChecker *const self, uint32_t const decl);
static __attribute__((unused)) typechecker__typechecker__FlowState typechecker__typechecker__TypeChecker__tc_flow_save(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_flow_set(typechecker__typechecker__TypeChecker *const self, const typechecker__typechecker__FlowState *const s);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_same(const typechecker__typechecker__TypeChecker *const self, typechecker__typechecker__Borrow const a, typechecker__typechecker__Borrow const b);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_flow_collect(const typechecker__typechecker__TypeChecker *const self, typechecker__typechecker__FlowState *const acc);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_flow_overflow(typechecker__typechecker__TypeChecker *const self, uint32_t const at);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_stmt_returns(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_scope_enter(typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_scope_exit(typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__place_index_const(const typechecker__typechecker__TypeChecker *const self, uint32_t const idx, int64_t *const out);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_type_is_union(const typechecker__typechecker__TypeChecker *const self, uint32_t const ty);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__place_decompose(typechecker__typechecker__TypeChecker *const self, uint32_t const place0, typechecker__typechecker__PStep *const steps, int32_t *const nsteps, int32_t const cap);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__borrow_place_root(typechecker__typechecker__TypeChecker *const self, uint32_t const place);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__places_overlap(typechecker__typechecker__TypeChecker *const self, uint32_t const aN, uint32_t const bN);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__place_through_binding(const typechecker__typechecker__TypeChecker *const self, uint32_t const place0);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__borrow_mark(const typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_release_to(typechecker__typechecker__TypeChecker *const self, uint32_t const mark);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_tombstone_at(typechecker__typechecker__TypeChecker *const self, uint32_t const i);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_dead_after(typechecker__typechecker__TypeChecker *const self, typechecker__typechecker__Borrow const b, uint32_t const after);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_report_conflict(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint8_t const kind, uint32_t const origin);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_push(typechecker__typechecker__TypeChecker *const self, uint32_t const root, uint8_t const kind, uint32_t const place, uint32_t const origin);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_create(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint8_t const kind, uint32_t const origin);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_conflicting_read(typechecker__typechecker__TypeChecker *const self, uint32_t const place);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_conflicting_write(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint32_t const after);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_transfer_ref(typechecker__typechecker__TypeChecker *const self, uint32_t const init, uint32_t const binding);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tuple_binds_reference(const typechecker__typechecker__TypeChecker *const self, uint32_t const name);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_nll_drop(typechecker__typechecker__TypeChecker *const self, uint32_t const block_id, const uint32_t *const ids, uint32_t const si);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__place_escape(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint32_t const depth);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__borrow_escape_of_binding(typechecker__typechecker__TypeChecker *const self, uint32_t const binding, uint32_t const depth);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__addr_escape_at(typechecker__typechecker__TypeChecker *const self, uint32_t const e0, uint32_t const depth);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__addr_escape(typechecker__typechecker__TypeChecker *const self, uint32_t const e);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_extend_item_named(const typechecker__typechecker__TypeChecker *const self, uint32_t const extnode, lexer__token__Span const name, uint16_t const nmod);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__extend_method_signature_matches(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const req, uint32_t const have, const ast__ast__DefId *const subp, const uint32_t *const suba, int32_t const nsub);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_interface_requirements(typechecker__typechecker__TypeChecker *const self, uint32_t const extnode, ast__ast__DefId const iface, uint32_t const self_ty, const ast__ast__DefId *const subp, const uint32_t *const suba, int32_t const nsub, int32_t const depth);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_extend_conformance(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__method_recv_subst(typechecker__typechecker__TypeChecker *const self, uint32_t const recv, ast__ast__DefId const md, ast__ast__DefId *const rsubp, uint32_t *const rsuba);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_method_ret(typechecker__typechecker__TypeChecker *const self, uint32_t const recv, ast__ast__DefId const md);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_method_param(typechecker__typechecker__TypeChecker *const self, uint32_t const recv, ast__ast__DefId const md, int32_t const idx);
static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__method_self_kind(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const md);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__operand_fits_param(typechecker__typechecker__TypeChecker *const self, uint32_t const pt, uint32_t const operand);
static __attribute__((unused)) str typechecker__typechecker__arith_method_name(lexer__token_type__TokenType const op);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_unary(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__binary_numeric(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const l, uint32_t const ln, uint32_t const r, uint32_t const rn, bool const require_int);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_ptr_arith(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const l, uint32_t const r, bool *const handled);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__check_arith_overload(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const l, uint32_t *const out);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_binary(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_variant_call(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint16_t const vmod, uint32_t const variant, uint32_t const enum_ty);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_is_iface_assoc_call(const typechecker__typechecker__TypeChecker *const self, uint32_t const e);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_param_expected(typechecker__typechecker__TypeChecker *const self, uint32_t const callee, uint32_t const callee_node, uint32_t const argi);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__iter_elem_type(typechecker__typechecker__TypeChecker *const self, uint32_t const it);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_check_assert(typechecker__typechecker__TypeChecker *const self, uint32_t const id, int32_t const kind);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__infer_from_bounds(typechecker__typechecker__TypeChecker *const self, uint16_t const fmod, uint32_t const fdecl, const uint32_t *const gids, const ast__ast__DefId *const gparams, uint32_t *const bound, int32_t const g);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_compatible_subst(typechecker__typechecker__TypeChecker *const self, uint32_t const exid, uint32_t const acid, const ast__ast__DefId *const gp, const uint32_t *const ga, int32_t const gn, const ast__ast__DefId *const rp, const uint32_t *const ra, int32_t const rn);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_field_visibility(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const field, uint32_t const owner, lexer__token__Span const at);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_call(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const want);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_call_receiver(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const callee_id, uint16_t const fmod, ast__ast__NodeList const params, ast__ast__NodeList const returns);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_call_finish(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const callee, uint32_t const callee_id, uint16_t const fmod, uint32_t const fdecl, bool const named, bool const clos, ast__ast__NodeList const params, ast__ast__NodeList const returns, ast__ast__NodeList const args, uint32_t const skip, uint32_t const want, bool const fmt_builtin);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_generic_bounds(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint16_t const fmod, uint32_t const fdecl, ast__ast__NodeList const gens, const ast__ast__DefId *const gparams, const uint32_t *const gargs, int32_t const gn, const ast__ast__DefId *const rsubp, const uint32_t *const rsuba, int32_t const nrsub);
static __attribute__((unused)) uint8_t typechecker__typechecker__if_u8(bool const c, uint8_t const a, uint8_t const b);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_member(typechecker__typechecker__TypeChecker *const self, uint32_t const id, bool const prefer_method);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_path_member(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const expected);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_struct_init(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_if_stmt(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__pattern_irrefutable(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__pattern_covered_variant(const typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__match_arm_coverage(const typechecker__typechecker__TypeChecker *const self, uint32_t const pid, uint16_t const emod, bool const has_ea, ast__ast__NodeList const variants, uint64_t *const covered, bool *const catchall, bool *const tcov, bool *const fcov);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_match_exhaustive(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const scrut);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_assignment(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_closure(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const cwant);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_index(typechecker__typechecker__TypeChecker *const self, uint32_t const id, bool const addr_ctx, bool const place_use);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_match_expr(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_expr(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_literal(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_array_literal(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_block_value(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_if_value(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_tuple_value(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const expected);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_loop_body(typechecker__typechecker__TypeChecker *const self, uint32_t const body);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_tuple_let(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_return(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_static_assert(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_stmt(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_pattern(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const expected, int32_t const bind_ref);
static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_embeds_by_value(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const d, uint16_t const tm, uint32_t const td, int32_t const depth);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_item(typechecker__typechecker__TypeChecker *const self, uint32_t const id);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_associated(typechecker__typechecker__TypeChecker *const self, ast__ast__NodeList const items);
static __attribute__((unused)) void typechecker__typechecker__TypeChecker__close_instances(typechecker__typechecker__TypeChecker *const self);
static __attribute__((unused)) bool typechecker__typechecker__if_bool(bool const c, bool const a, bool const b);
static __attribute__((unused)) uint32_t typechecker__typechecker__if_u32(bool const c, uint32_t const a, uint32_t const b);
static __attribute__((unused)) ast__ast__NodeList typechecker__typechecker__if_nl(bool const c, ast__ast__NodeList const a, ast__ast__NodeList const b);

static __attribute__((unused)) void typechecker__typechecker__bt_widens_helper(void) {
}

static __attribute__((unused)) bool typechecker__typechecker__span_is(const uint8_t *const src, lexer__token__Span const s, str const lit) {
  const size_t n = str__len(&lit);
  if (((size_t)(s.end - s.start)) != n) {
    return false;
  }
  return (memcmp((src + ((size_t)s.start)), str__ptr(&lit), n) == 0);
}

static __attribute__((unused)) bool typechecker__typechecker__spans_eq2(const uint8_t *const sa, lexer__token__Span const a, const uint8_t *const sb, lexer__token__Span const b) {
  const uint32_t la = (a.end - a.start);
  if (la != (b.end - b.start)) {
    return false;
  }
  return (memcmp((sa + ((size_t)a.start)), (sb + ((size_t)b.start)), ((size_t)la)) == 0);
}

static __attribute__((unused)) str typechecker__typechecker__builtin_name(ast__ast__BuiltinType const b) {
  if (b == ast__ast__BuiltinType_BT_BOOL) {
    return (str){ (const uint8_t *)"bool", sizeof("bool") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_CHAR) {
    return (str){ (const uint8_t *)"char", sizeof("char") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_I8) {
    return (str){ (const uint8_t *)"i8", sizeof("i8") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_I16) {
    return (str){ (const uint8_t *)"i16", sizeof("i16") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_I32) {
    return (str){ (const uint8_t *)"i32", sizeof("i32") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_I64) {
    return (str){ (const uint8_t *)"i64", sizeof("i64") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_ISIZE) {
    return (str){ (const uint8_t *)"isize", sizeof("isize") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_U8) {
    return (str){ (const uint8_t *)"u8", sizeof("u8") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_U16) {
    return (str){ (const uint8_t *)"u16", sizeof("u16") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_U32) {
    return (str){ (const uint8_t *)"u32", sizeof("u32") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_U64) {
    return (str){ (const uint8_t *)"u64", sizeof("u64") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_USIZE) {
    return (str){ (const uint8_t *)"usize", sizeof("usize") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_F32) {
    return (str){ (const uint8_t *)"f32", sizeof("f32") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_F64) {
    return (str){ (const uint8_t *)"f64", sizeof("f64") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_C32) {
    return (str){ (const uint8_t *)"c32", sizeof("c32") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_C64) {
    return (str){ (const uint8_t *)"c64", sizeof("c64") - 1 };
  }
  if (b == ast__ast__BuiltinType_BT_VALIST) {
    return (str){ (const uint8_t *)"va_list", sizeof("va_list") - 1 };
  }
  return (str){ (const uint8_t *)"void", sizeof("void") - 1 };
}

static __attribute__((unused)) int32_t typechecker__typechecker__builtin_of(const uint8_t *const src, lexer__token__Span const s) {
  for (int32_t i = 0; i < 18; i++) {
    if (typechecker__typechecker__span_is(src, s, typechecker__typechecker__builtin_name(((ast__ast__BuiltinType)i)))) {
      return i;
    }
  }
  return -1;
}

static __attribute__((unused)) bool typechecker__typechecker__bt_is_int(ast__ast__BuiltinType const b) {
  return ((((uint8_t)b) >= 2U) && (((uint8_t)b) <= 11U));
}

static __attribute__((unused)) bool typechecker__typechecker__bt_is_float(ast__ast__BuiltinType const b) {
  return ((b == ast__ast__BuiltinType_BT_F32) || (b == ast__ast__BuiltinType_BT_F64));
}

static __attribute__((unused)) bool typechecker__typechecker__bt_is_complex(ast__ast__BuiltinType const b) {
  return ((b == ast__ast__BuiltinType_BT_C32) || (b == ast__ast__BuiltinType_BT_C64));
}

static __attribute__((unused)) uint64_t typechecker__typechecker__bt_int_max(ast__ast__BuiltinType const b) {
  if (b == ast__ast__BuiltinType_BT_I8) {
    return 127ULL;
  }
  if (b == ast__ast__BuiltinType_BT_I16) {
    return 32767ULL;
  }
  if (b == ast__ast__BuiltinType_BT_I32) {
    return 2147483647ULL;
  }
  if ((b == ast__ast__BuiltinType_BT_I64) || (b == ast__ast__BuiltinType_BT_ISIZE)) {
    return 9223372036854775807ULL;
  }
  if (b == ast__ast__BuiltinType_BT_U8) {
    return 255ULL;
  }
  if (b == ast__ast__BuiltinType_BT_U16) {
    return 65535ULL;
  }
  if (b == ast__ast__BuiltinType_BT_U32) {
    return 4294967295ULL;
  }
  return 0ULL;
}

static __attribute__((unused)) bool typechecker__typechecker__tc_lit_in_range(ast__ast__BuiltinType const b, uint64_t const mag, bool const neg) {
  const uint64_t mx = typechecker__typechecker__bt_int_max(b);
  if (neg) {
    const bool sgn = (((((b == ast__ast__BuiltinType_BT_I8) || (b == ast__ast__BuiltinType_BT_I16)) || (b == ast__ast__BuiltinType_BT_I32)) || (b == ast__ast__BuiltinType_BT_I64)) || (b == ast__ast__BuiltinType_BT_ISIZE));
    return (sgn && ((mx == 0ULL) || (mag <= (mx + 1ULL))));
  }
  return ((mx == 0ULL) || (mag <= mx));
}

static __attribute__((unused)) bool typechecker__typechecker__bt_widens(ast__ast__BuiltinType const from, ast__ast__BuiltinType const to) {
  if ((from == ast__ast__BuiltinType_BT_F32) && (to == ast__ast__BuiltinType_BT_F64)) {
    return true;
  }
  const bool fs = ((((uint8_t)from) >= 2U) && (((uint8_t)from) <= 5U));
  const bool fu = ((((uint8_t)from) >= 7U) && (((uint8_t)from) <= 10U));
  const bool ts = ((((uint8_t)to) >= 2U) && (((uint8_t)to) <= 5U));
  const bool tu = ((((uint8_t)to) >= 7U) && (((uint8_t)to) <= 10U));
  if ((!(fs || fu)) || (!(ts || tu))) {
    return false;
  }
  int32_t fw = ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)from), 7, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
  if (fs) {
    (fw = ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)from), 2, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  int32_t tw = ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)to), 7, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
  if (ts) {
    (tw = ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)to), 2, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if (fu) {
    return (tw > fw);
  }
  return (ts && (tw > fw));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__hex_digit(uint8_t const c) {
  if (c <= 57U) {
    return ((uint32_t)((uint8_t)((uint32_t)c - (uint32_t)48U)));
  }
  return ((uint32_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)(c | 0x20U) - (uint32_t)97U)) + (uint32_t)10U)));
}

typechecker__typechecker__TypeChecker typechecker__typechecker__TypeChecker__new(ast__ast__Ast ast, str const source, module__loader__Package *const package) {
  return (typechecker__typechecker__TypeChecker){ .ast = ast, .source = str__ptr(&source), .len = str__len(&source), .current_returns = (ast__ast__NodeList){ .start = 0U, .len = 0U }, .current_self = ast__ast__NODE_NONE, .current_extend = ast__ast__NODE_NONE, .current_fn = ast__ast__NODE_NONE, .nclos = 0U, .package = package, .alias_depth = 0U, .ext_scope = Vector__u16__Global__new(), .n_ext_scope = -1, .ext_items = Vector__Vector__u32__Global__Global__new(), .ext_items_built = Vector__bool__Global__new(), .expected = ast__ast__TYPE_NONE, .nmoved = 0U, .nuninit = 0U, .nfreed = 0U, .nborrows = 0U, .scope_depth = 0U, .loop_depth = 0U, .binding_depth = Map__u32__u32__Global__new(), .ndefers = 0U, .in_loop_recheck = false, .place_use = false, .addr_ctx = false, .mret_call = ast__ast__NODE_NONE, .mret_n = 0U, .mret_total = 0U, .unsafe_depth = 0U, .nloops = 0U, .loop_floor = 0U, .errors = utils__errors__Errors__new() };
}

ast__ast__Ast typechecker__typechecker__TypeChecker__take_ast(typechecker__typechecker__TypeChecker *const self) {
  ast__ast__Ast out = self->ast;
  (self->ast = ast__ast__Ast__new(0ULL));
  return out;
}

static __attribute__((unused)) ast__ast__Ast *typechecker__typechecker__TypeChecker__cur_ast(const typechecker__typechecker__TypeChecker *const self) {
  return ((ast__ast__Ast *)(&self->ast));
}

static __attribute__((unused)) uint16_t typechecker__typechecker__TypeChecker__cur_module(const typechecker__typechecker__TypeChecker *const self) {
  return self->ast.module;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__has_pkg(const typechecker__typechecker__TypeChecker *const self) {
  return (self->package != NULL);
}

static __attribute__((unused)) ast__ast__Ast *typechecker__typechecker__TypeChecker__mod_ast(const typechecker__typechecker__TypeChecker *const self, uint16_t const m) {
  if ((self->package != NULL) && (m != self->ast.module)) {
    return ((ast__ast__Ast *)(&(*({ __auto_type __sc0 = &(*self->package).modules; Vector__module__loader__Module__Global__index_mut(__sc0, ((size_t)m)); })).ast));
  }
  return ((ast__ast__Ast *)(&self->ast));
}

static __attribute__((unused)) const uint8_t *typechecker__typechecker__TypeChecker__mod_src(const typechecker__typechecker__TypeChecker *const self, uint16_t const m) {
  if ((self->package != NULL) && (m != self->ast.module)) {
    return ({ __auto_type __sc1 = String__Global__as_str(&(*({ __auto_type __sc2 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc2, ((size_t)m)); })).source); str__ptr(&__sc1); });
  }
  return self->source;
}

static __attribute__((unused)) size_t typechecker__typechecker__TypeChecker__pkg_count(const typechecker__typechecker__TypeChecker *const self) {
  if (self->package == NULL) {
    return 0ULL;
  }
  return Vector__module__loader__Module__Global__len(&(*self->package).modules);
}

static __attribute__((unused)) consteval__consteval__ConstEval *typechecker__typechecker__TypeChecker__ceval(const typechecker__typechecker__TypeChecker *const self) {
  if (self->package == NULL) {
    return NULL;
  }
  return ((consteval__consteval__ConstEval *)(*self->package).ceval);
}

static __attribute__((unused)) lexer__token__Span typechecker__typechecker__TypeChecker__name_span(const typechecker__typechecker__TypeChecker *const self, uint32_t const name_node) {
  return ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), name_node)->as_data.name.text;
}

static __attribute__((unused)) const ast__ast__Ty *typechecker__typechecker__TypeChecker__type_at(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  return ast__ast__Ast__type_at(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), x);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__at_not_fn(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  return (typechecker__typechecker__TypeChecker__type_at(self, x)->kind != ast__ast__TypeKind_TYPE_FUNCTION);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_bool(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  const ast__ast__Ty *const y = typechecker__typechecker__TypeChecker__type_at(self, x);
  return ((y->kind == ast__ast__TypeKind_TYPE_BUILTIN) && (y->as_data.builtin == ast__ast__BuiltinType_BT_BOOL));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_int(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  const ast__ast__Ty *const y = typechecker__typechecker__TypeChecker__type_at(self, x);
  return ((y->kind == ast__ast__TypeKind_TYPE_BUILTIN) && typechecker__typechecker__bt_is_int(y->as_data.builtin));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_numeric(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  const ast__ast__Ty *const y = typechecker__typechecker__TypeChecker__type_at(self, x);
  return ((y->kind == ast__ast__TypeKind_TYPE_BUILTIN) && ((typechecker__typechecker__bt_is_int(y->as_data.builtin) || typechecker__typechecker__bt_is_float(y->as_data.builtin)) || typechecker__typechecker__bt_is_complex(y->as_data.builtin)));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_void_type(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  const ast__ast__Ty *const y = typechecker__typechecker__TypeChecker__type_at(self, x);
  return ((y->kind == ast__ast__TypeKind_TYPE_BUILTIN) && (y->as_data.builtin == ast__ast__BuiltinType_BT_VOID));
}

static __attribute__((unused)) ast__ast__BuiltinType typechecker__typechecker__TypeChecker__bt_of(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  const ast__ast__Ty *const y = typechecker__typechecker__TypeChecker__type_at(self, x);
  if (y->kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    return y->as_data.builtin;
  }
  return ast__ast__BuiltinType_BT_COUNT;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_plain_enum(const typechecker__typechecker__TypeChecker *const self, uint32_t const x) {
  const ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, x));
  if (y.kind != ast__ast__TypeKind_TYPE_ENUM) {
    return false;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, y.module);
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), y.as_data.decl)->as_data.aggregate.members;
  for (uint32_t i = 0U; i < ms.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.payload.len > 0U) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__strip(const typechecker__typechecker__TypeChecker *const self, uint32_t const x0) {
  uint32_t x = x0;
  const ast__ast__Ty *y = typechecker__typechecker__TypeChecker__type_at(self, x);
  while ((y->kind == ast__ast__TypeKind_TYPE_POINTER) || (y->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    (x = y->as_data.elem);
    (y = typechecker__typechecker__TypeChecker__type_at(self, x));
  }
  return x;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_ref(typechecker__typechecker__TypeChecker *const self, uint32_t const elem, bool const mut2) {
  ast__ast__TypeQualifier q = ast__ast__TypeQualifier_TYPE_QUAL_NONE;
  if (mut2) {
    (q = ast__ast__TypeQualifier_TYPE_QUAL_MUT);
  }
  return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_REFERENCE, .qualifier = ((uint8_t)q), .as_data = (ast__ast__TyAs){ .elem = elem } });
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tc_loop_push(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const label, uint32_t const node, bool const value_loop) {
  if (self->nloops >= 32U) {
    return -1;
  }
  const uint32_t n = self->nloops;
  (self->loop_stack[((size_t)n)] = (typechecker__typechecker__LoopEntry){ .label = label, .node = node, .break_ty = ast__ast__TYPE_NONE, .value_loop = value_loop, .saw_value = false, .saw_bare = false });
  (self->nloops = (n + 1U));
  return ((int32_t)n);
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_loop_pop(typechecker__typechecker__TypeChecker *const self, int32_t const le, lexer__token__Span const sp) {
  if (le < 0) {
    return;
  }
  if (self->loop_stack[((size_t)le)].saw_value && self->loop_stack[((size_t)le)].saw_bare) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc3 = String__Global__new();
String__Global__push_str(&__sc3, (str){ .ptr = (const uint8_t*)"every 'break' in a value-yielding 'loop' must carry a value", .len = sizeof("every 'break' in a value-yielding 'loop' must carry a value") - 1 });
__sc3; }));
  }
  (self->nloops = ((uint32_t)le));
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tc_find_loop(const typechecker__typechecker__TypeChecker *const self, lexer__token__Span const label) {
  uint32_t i = self->nloops;
  while (i > self->loop_floor) {
    (i = (i - 1U));
    if (label.end == label.start) {
      return ((int32_t)i);
    }
    const lexer__token__Span ls = self->loop_stack[((size_t)i)].label;
    if (((ls.end - ls.start) == (label.end - label.start)) && (memcmp((self->source + ((size_t)ls.start)), (self->source + ((size_t)label.start)), ((size_t)(ls.end - ls.start))) == 0)) {
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_is_test_fn(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const fnode) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  for (size_t i = 0ULL; i < Vector__ast__ast__Attr__Global__len(&(*a).attrs); i++) {
    const ast__ast__Attr *const at = Vector__ast__ast__Attr__Global__at(&(*a).attrs, i);
    if ((at->owner == fnode) && (((at->kind == 12U) || (at->kind == 13U)) || (at->kind == 14U))) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_in_test_fn(const typechecker__typechecker__TypeChecker *const self) {
  return ((self->current_fn != ast__ast__NODE_NONE) && typechecker__typechecker__TypeChecker__tc_is_test_fn(self, self->ast.module, self->current_fn));
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_check_test_ref(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const d, lexer__token__Span const sp) {
  if (((d.node == ast__ast__NODE_NONE) || (!typechecker__typechecker__TypeChecker__tc_is_test_fn(self, d.module, d.node))) || typechecker__typechecker__TypeChecker__tc_in_test_fn(self)) {
    return;
  }
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc4 = String__Global__new();
String__Global__push_str(&__sc4, (str){ .ptr = (const uint8_t*)"a '@test' function can only be called from other test functions", .len = sizeof("a '@test' function can only be called from other test functions") - 1 });
__sc4; }));
  utils__errors__Errors__note(&self->errors, ({ String__Global __sc5 = String__Global__new();
String__Global__push_str(&__sc5, (str){ .ptr = (const uint8_t*)"test functions are not compiled outside 'super-c --test'; move shared logic into a plain function", .len = sizeof("test functions are not compiled outside 'super-c --test'; move shared logic into a plain function") - 1 });
__sc5; }));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_literal_pinned(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  if (n->kind != ast__ast__NodeKind_NODE_LITERAL) {
    return false;
  }
  const lexer__token_type__TokenType tt = n->as_data.literal.token_type;
  if ((tt != lexer__token_type__TokenType_IntegerLiteral) && (tt != lexer__token_type__TokenType_FloatLiteral)) {
    return false;
  }
  return (ast__ast__ast_numeric_suffix(self->source, n->as_data.literal.raw.start, n->as_data.literal.raw.end, NULL) != ast__ast__BuiltinType_BT_COUNT);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_integer_literal_node(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return false;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t nid = id;
  const ast__ast__Node *const n0 = ast__ast__Ast__at_const(&((*a)), nid);
  if ((n0->kind == ast__ast__NodeKind_NODE_UNARY) && (n0->as_data.unary.op == lexer__token_type__TokenType_Minus)) {
    (nid = n0->as_data.unary.operand);
  }
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), nid);
  return ((n->kind == ast__ast__NodeKind_NODE_LITERAL) && (n->as_data.literal.token_type == lexer__token_type__TokenType_IntegerLiteral));
}

static __attribute__((unused)) typechecker__typechecker__BoxOf typechecker__typechecker__TypeChecker__tc_literal_u64(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  (void)self;
  (void)id;
  return (typechecker__typechecker__BoxOf){ .ok = false, .inner = 0U, .global_alloc = false };
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__lit_mag(const typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint64_t *const out) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  const lexer__token__Span lr = n->as_data.literal.raw;
  uint32_t endd = lr.end;
  ast__ast__ast_numeric_suffix(self->source, lr.start, lr.end, ((uint32_t *)(&endd)));
  const uint8_t *p = (self->source + ((size_t)lr.start));
  size_t len = ((size_t)(endd - lr.start));
  uint64_t base = 10ULL;
  if ((len >= 2ULL) && (p[0] == 48U)) {
    const uint8_t c1 = (p[1] | 0x20U);
    if (c1 == 120U) {
      (base = 16ULL);
      (p = (p + 2));
      (len = (len - 2ULL));
    } else if (c1 == 98U) {
      (base = 2ULL);
      (p = (p + 2));
      (len = (len - 2ULL));
    } else if (c1 == 111U) {
      (base = 8ULL);
      (p = (p + 2));
      (len = (len - 2ULL));
    }
  }
  uint64_t acc = 0ULL;
  for (size_t i = 0ULL; i < len; i++) {
    const uint8_t ch = p[i];
    if (ch == 95U) {
      continue;
    }
    uint64_t d = 0ULL;
    if (ch <= 57U) {
      (d = ((uint64_t)((uint8_t)((uint32_t)ch - (uint32_t)48U))));
    } else {
      (d = ((uint64_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)(ch | 0x20U) - (uint32_t)97U)) + (uint32_t)10U))));
    }
    if ((d >= base) || (acc > ({ uint64_t __sc6 = (0xFFFFFFFFFFFFFFFFULL - d); uint64_t __sc7 = base; if (__sc7 == 0) { __sc_panic("divide by zero"); } (__sc6 / __sc7); }))) {
      return false;
    }
    (acc = ((acc * base) + d));
  }
  ((*out) = acc);
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__char_literal_cp(const typechecker__typechecker__TypeChecker *const self, lexer__token__Span const s) {
  const uint8_t *const src = self->source;
  size_t i = ((size_t)(s.start + 1U));
  if (i >= ((size_t)s.end)) {
    return 0U;
  }
  if (src[i] != 92U) {
    const uint8_t b = src[i];
    if (b < 0x80U) {
      return ((uint32_t)b);
    }
    if (b <= 0xDFU) {
      return (({ uint32_t __sc8 = ((uint32_t)(b & 0x1FU)); int64_t __sc9 = (int64_t)(6U); if ((uint64_t)__sc9 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc8 << __sc9)); }) | ((uint32_t)(src[(i + 1ULL)] & 0x3FU)));
    }
    if (b <= 0xEFU) {
      return ((({ uint32_t __sc10 = ((uint32_t)(b & 0x0FU)); int64_t __sc11 = (int64_t)(12U); if ((uint64_t)__sc11 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc10 << __sc11)); }) | ({ uint32_t __sc12 = ((uint32_t)(src[(i + 1ULL)] & 0x3FU)); int64_t __sc13 = (int64_t)(6U); if ((uint64_t)__sc13 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc12 << __sc13)); })) | ((uint32_t)(src[(i + 2ULL)] & 0x3FU)));
    }
    return (((({ uint32_t __sc14 = ((uint32_t)(b & 0x07U)); int64_t __sc15 = (int64_t)(18U); if ((uint64_t)__sc15 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc14 << __sc15)); }) | ({ uint32_t __sc16 = ((uint32_t)(src[(i + 1ULL)] & 0x3FU)); int64_t __sc17 = (int64_t)(12U); if ((uint64_t)__sc17 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc16 << __sc17)); })) | ({ uint32_t __sc18 = ((uint32_t)(src[(i + 2ULL)] & 0x3FU)); int64_t __sc19 = (int64_t)(6U); if ((uint64_t)__sc19 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc18 << __sc19)); })) | ((uint32_t)(src[(i + 3ULL)] & 0x3FU)));
  }
  (i = (i + 1ULL));
  const uint8_t e = src[i];
  (i = (i + 1ULL));
  if (e == 120U) {
    return (({ uint32_t __sc20 = typechecker__typechecker__hex_digit(src[i]); int64_t __sc21 = (int64_t)(4U); if ((uint64_t)__sc21 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc20 << __sc21)); }) | typechecker__typechecker__hex_digit(src[(i + 1ULL)]));
  }
  if (e == 117U) {
    if ((i < ((size_t)s.end)) && (src[i] == 123U)) {
      (i = (i + 1ULL));
    }
    uint32_t cp = 0U;
    while ((i < ((size_t)s.end)) && (src[i] != 125U)) {
      (cp = (({ uint32_t __sc22 = cp; int64_t __sc23 = (int64_t)(4U); if ((uint64_t)__sc23 >= 32) { __sc_panic("shift out of range"); } (uint32_t)((uint32_t)((uint32_t)__sc22 << __sc23)); }) | typechecker__typechecker__hex_digit(src[i])));
      (i = (i + 1ULL));
    }
    return cp;
  }
  return 0U;
}

static __attribute__((cold, noinline, unused)) void typechecker__typechecker__TypeChecker__err_unsafe(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const sp, str const what) {
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc24 = String__Global__new();
String__Global__push_str(&__sc24, what);
String__Global__push_str(&__sc24, (str){ .ptr = (const uint8_t*)" requires an 'unsafe' block", .len = sizeof(" requires an 'unsafe' block") - 1 });
__sc24; }));
  utils__errors__Errors__note(&self->errors, ({ String__Global __sc25 = String__Global__new();
String__Global__push_str(&__sc25, (str){ (const uint8_t *)"wrap the operation in 'unsafe { ... }' or prefix the expression with 'unsafe'", sizeof("wrap the operation in 'unsafe { ... }' or prefix the expression with 'unsafe'") - 1 });
__sc25; }));
}

static __attribute__((unused)) const ast__ast__Attr *typechecker__typechecker__TypeChecker__tc_attr(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const owner, ast__ast__AttrKind const kind) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  for (size_t i = 0ULL; i < Vector__ast__ast__Attr__Global__len(&(*a).attrs); i++) {
    const ast__ast__Attr *const at = Vector__ast__ast__Attr__Global__at(&(*a).attrs, i);
    if ((at->owner == owner) && (at->kind == ((uint8_t)kind))) {
      return ((const ast__ast__Attr *)at);
    }
  }
  return NULL;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__peel_wrappers(const typechecker__typechecker__TypeChecker *const self, uint32_t const id0) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t id = id0;
  for (;;) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), id);
    if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (id = n->as_data.unary.operand);
    } else {
      break;
    }
  }
  return id;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__through_raw_pointer(const typechecker__typechecker__TypeChecker *const self, uint32_t const ty0) {
  uint32_t ty = ty0;
  const ast__ast__Ty *y = typechecker__typechecker__TypeChecker__type_at(self, ty);
  while ((y->kind == ast__ast__TypeKind_TYPE_REFERENCE) || (y->kind == ast__ast__TypeKind_TYPE_POINTER)) {
    if (y->kind == ast__ast__TypeKind_TYPE_POINTER) {
      return true;
    }
    (ty = y->as_data.elem);
    (y = typechecker__typechecker__TypeChecker__type_at(self, ty));
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__render_type(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, char *const buf, size_t const cap) {
  const ast__ast__Ty ty = (*typechecker__typechecker__TypeChecker__type_at(self, tid));
  if (ty.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    snprintf(buf, cap, ((const char *)({ __auto_type __sc26 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc26); })), ((const char *)({ __auto_type __sc27 = typechecker__typechecker__builtin_name(ty.as_data.builtin); str__ptr(&__sc27); })));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_NEVER) {
    snprintf(buf, cap, ((const char *)({ __auto_type __sc28 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc28); })), ((const char *)({ __auto_type __sc29 = (str){ (const uint8_t *)"never", sizeof("never") - 1 }; str__ptr(&__sc29); })));
  } else if ((ty.kind == ast__ast__TypeKind_TYPE_POINTER) || (ty.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    typechecker__typechecker__Buf96 inb = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, ty.as_data.elem, ((char *)(&inb.b[0])), 96ULL);
    const char *pfx = ((const char *)({ __auto_type __sc30 = (str){ (const uint8_t *)"&", sizeof("&") - 1 }; str__ptr(&__sc30); }));
    if (ty.kind == ast__ast__TypeKind_TYPE_POINTER) {
      (pfx = ((const char *)({ __auto_type __sc31 = (str){ (const uint8_t *)"*", sizeof("*") - 1 }; str__ptr(&__sc31); })));
    }
    const char *mq = ((const char *)({ __auto_type __sc32 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc32); }));
    if (ty.qualifier == 2U) {
      (mq = ((const char *)({ __auto_type __sc33 = (str){ (const uint8_t *)"mut ", sizeof("mut ") - 1 }; str__ptr(&__sc33); })));
    }
    snprintf(buf, cap, ((const char *)({ __auto_type __sc34 = (str){ (const uint8_t *)"%s%s%s", sizeof("%s%s%s") - 1 }; str__ptr(&__sc34); })), pfx, mq, ((const char *)(&inb.b[0])));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_SLICE) {
    typechecker__typechecker__Buf96 inb = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, ty.as_data.elem, ((char *)(&inb.b[0])), 96ULL);
    snprintf(buf, cap, ((const char *)({ __auto_type __sc35 = (str){ (const uint8_t *)"[]%s", sizeof("[]%s") - 1 }; str__ptr(&__sc35); })), ((const char *)(&inb.b[0])));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    typechecker__typechecker__Buf96 inb = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, ty.as_data.arr.elem, ((char *)(&inb.b[0])), 96ULL);
    snprintf(buf, cap, ((const char *)({ __auto_type __sc36 = (str){ (const uint8_t *)"[%s]", sizeof("[%s]") - 1 }; str__ptr(&__sc36); })), ((const char *)(&inb.b[0])));
  } else if (((ty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ty.kind == ast__ast__TypeKind_TYPE_ENUM)) || (ty.kind == ast__ast__TypeKind_TYPE_GENERIC)) {
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, ty.module);
    const ast__ast__Node *const d = ast__ast__Ast__at_const(&((*a)), ty.as_data.decl);
    uint32_t nm = d->as_data.aggregate.name;
    if (d->kind == ast__ast__NodeKind_NODE_GENERIC_PARAM) {
      (nm = d->as_data.generic_param.name);
    }
    const lexer__token__Span s = ast__ast__Ast__at_const(&((*a)), nm)->as_data.name.text;
    snprintf(buf, cap, ((const char *)({ __auto_type __sc37 = (str){ (const uint8_t *)"%.*s", sizeof("%.*s") - 1 }; str__ptr(&__sc37); })), ((int32_t)(s.end - s.start)), typechecker__typechecker__src_at(typechecker__typechecker__TypeChecker__mod_src(self, ty.module), s.start));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_OPAQUE) {
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, ty.module);
    const lexer__token__Span s = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), ty.as_data.decl)->as_data.type_alias.name)->as_data.name.text;
    snprintf(buf, cap, ((const char *)({ __auto_type __sc38 = (str){ (const uint8_t *)"%.*s", sizeof("%.*s") - 1 }; str__ptr(&__sc38); })), ((int32_t)(s.end - s.start)), typechecker__typechecker__src_at(typechecker__typechecker__TypeChecker__mod_src(self, ty.module), s.start));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ty.as_data.inst));
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, it.module);
    const lexer__token__Span s = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), it.decl)->as_data.aggregate.name)->as_data.name.text;
    const int32_t at0 = snprintf(buf, cap, ((const char *)({ __auto_type __sc39 = (str){ (const uint8_t *)"%.*s<", sizeof("%.*s<") - 1 }; str__ptr(&__sc39); })), ((int32_t)(s.end - s.start)), typechecker__typechecker__src_at(typechecker__typechecker__TypeChecker__mod_src(self, it.module), s.start));
    size_t at = ((size_t)at0);
    uint8_t i = 0U;
    while ((i < it.n) && (at < cap)) {
      typechecker__typechecker__Buf96 argb = (typechecker__typechecker__Buf96){0};
      typechecker__typechecker__TypeChecker__render_type(self, it.args[((size_t)i)], ((char *)(&argb.b[0])), 64ULL);
      const char *sep = ((const char *)({ __auto_type __sc40 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc40); }));
      if (i != 0U) {
        (sep = ((const char *)({ __auto_type __sc41 = (str){ (const uint8_t *)", ", sizeof(", ") - 1 }; str__ptr(&__sc41); })));
      }
      size_t room = 0ULL;
      if (cap > at) {
        (room = (cap - at));
      }
      const int32_t w = snprintf(((char *)(buf + at)), room, ((const char *)({ __auto_type __sc42 = (str){ (const uint8_t *)"%s%s", sizeof("%s%s") - 1 }; str__ptr(&__sc42); })), sep, ((const char *)(&argb.b[0])));
      (at = (at + ((size_t)w)));
      (i = ((uint8_t)((uint32_t)i + (uint32_t)1U)));
    }
    if (at < cap) {
      snprintf(((char *)(buf + at)), (cap - at), ((const char *)({ __auto_type __sc43 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc43); })), ((const char *)({ __auto_type __sc44 = (str){ (const uint8_t *)">", sizeof(">") - 1 }; str__ptr(&__sc44); })));
    }
  } else if (ty.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    snprintf(buf, cap, ((const char *)({ __auto_type __sc45 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc45); })), ((const char *)({ __auto_type __sc46 = (str){ (const uint8_t *)"fn", sizeof("fn") - 1 }; str__ptr(&__sc46); })));
  } else if (ty.kind == ast__ast__TypeKind_TYPE_DYN) {
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, ty.module);
    const char *pfx = ((const char *)({ __auto_type __sc47 = (str){ (const uint8_t *)"Box<dyn ", sizeof("Box<dyn ") - 1 }; str__ptr(&__sc47); }));
    if (ty.qualifier == 2U) {
      (pfx = ((const char *)({ __auto_type __sc48 = (str){ (const uint8_t *)"&mut dyn ", sizeof("&mut dyn ") - 1 }; str__ptr(&__sc48); })));
    } else if (ty.qualifier == 1U) {
      (pfx = ((const char *)({ __auto_type __sc49 = (str){ (const uint8_t *)"&dyn ", sizeof("&dyn ") - 1 }; str__ptr(&__sc49); })));
    }
    const char *sfx = ((const char *)({ __auto_type __sc50 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc50); }));
    if (ty.qualifier == 0U) {
      (sfx = ((const char *)({ __auto_type __sc51 = (str){ (const uint8_t *)">", sizeof(">") - 1 }; str__ptr(&__sc51); })));
    }
    if (ast__ast__Ast__at_const(&((*a)), ty.as_data.decl)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
      snprintf(buf, cap, ((const char *)({ __auto_type __sc52 = (str){ (const uint8_t *)"%sfn(..) ..%s", sizeof("%sfn(..) ..%s") - 1 }; str__ptr(&__sc52); })), pfx, sfx);
    } else {
      const lexer__token__Span s = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), ty.as_data.decl)->as_data.interface_def.name)->as_data.name.text;
      snprintf(buf, cap, ((const char *)({ __auto_type __sc53 = (str){ (const uint8_t *)"%s%.*s%s", sizeof("%s%.*s%s") - 1 }; str__ptr(&__sc53); })), pfx, ((int32_t)(s.end - s.start)), typechecker__typechecker__src_at(typechecker__typechecker__TypeChecker__mod_src(self, ty.module), s.start), sfx);
    }
  } else {
    snprintf(buf, cap, ((const char *)({ __auto_type __sc54 = (str){ (const uint8_t *)"%s", sizeof("%s") - 1 }; str__ptr(&__sc54); })), ((const char *)({ __auto_type __sc55 = (str){ (const uint8_t *)"?", sizeof("?") - 1 }; str__ptr(&__sc55); })));
  }
}

static __attribute__((cold, noinline, unused)) void typechecker__typechecker__TypeChecker__err_mismatch(typechecker__typechecker__TypeChecker *const self, uint32_t const node, uint32_t const expected) {
  typechecker__typechecker__Buf96 e = (typechecker__typechecker__Buf96){0};
  typechecker__typechecker__Buf96 f = (typechecker__typechecker__Buf96){0};
  typechecker__typechecker__TypeChecker__render_type(self, expected, ((char *)(&e.b[0])), 96ULL);
  typechecker__typechecker__TypeChecker__render_type(self, ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node), ((char *)(&f.b[0])), 96ULL);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node)->span;
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc56 = String__Global__new();
String__Global__push_str(&__sc56, (str){ .ptr = (const uint8_t*)"mismatched types: expected '", .len = sizeof("mismatched types: expected '") - 1 });
String__Global__push_str(&__sc56, utils__errors__cstr(((const char *)(&e.b[0]))));
String__Global__push_str(&__sc56, (str){ .ptr = (const uint8_t*)"', found '", .len = sizeof("', found '") - 1 });
String__Global__push_str(&__sc56, utils__errors__cstr(((const char *)(&f.b[0]))));
String__Global__push_str(&__sc56, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc56; }));
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__fn_sig(typechecker__typechecker__TypeChecker *const self, uint32_t const fid, uint32_t *const params, int32_t const cap, uint32_t *const ret) {
  const ast__ast__Ty fty = (*typechecker__typechecker__TypeChecker__type_at(self, fid));
  const uint16_t m = fty.module;
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeKind fk = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->kind;
  ast__ast__NodeList ps = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  ast__ast__NodeList rs = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  if (fk == ast__ast__NodeKind_NODE_FUNCTION) {
    (ps = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.function.params);
    (rs = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.function.returns);
  } else if (fk == ast__ast__NodeKind_NODE_CLOSURE) {
    (ps = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.closure.params);
    (rs = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.closure.returns);
  } else {
    (ps = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.function_type.params);
    (rs = ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.function_type.returns);
  }
  uint32_t i = 0U;
  while ((i < ps.len) && (((int32_t)i) < cap)) {
    const uint32_t pid = ast__ast__Ast__list(&((*fa)), ps)[((size_t)i)];
    const ast__ast__Node *const p = ast__ast__Ast__at_const(&((*fa)), pid);
    if ((p->kind == ast__ast__NodeKind_NODE_PARAMETER) && (p->as_data.parameter.ty == ast__ast__NODE_NONE)) {
      const uint32_t pty = ast__ast__Ast__type_of(&((*fa)), pid);
      (params[((size_t)i)] = pty);
    } else {
      const uint32_t tn = typechecker__typechecker__if_node((p->kind == ast__ast__NodeKind_NODE_PARAMETER), p->as_data.parameter.ty, pid);
      (params[((size_t)i)] = typechecker__typechecker__TypeChecker__lower_type_in(self, m, tn));
    }
    (i = (i + 1U));
  }
  if ((fk == ast__ast__NodeKind_NODE_CLOSURE) && ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.closure.expr_body) {
    const uint32_t rty = ast__ast__Ast__type_of(&((*fa)), ast__ast__Ast__at_const(&((*fa)), fty.as_data.decl)->as_data.closure.body);
    ((*ret) = rty);
  } else if (rs.len == 1U) {
    const uint32_t r0 = ast__ast__Ast__list(&((*fa)), rs)[0];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*fa)), r0);
    const uint32_t tn = typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0);
    ((*ret) = typechecker__typechecker__TypeChecker__lower_type_in(self, m, tn));
  } else {
    ((*ret) = ast__ast__TYPE_NONE);
  }
  return ((int32_t)ps.len);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__receiver_type_eq(const typechecker__typechecker__TypeChecker *const self, uint32_t const a, uint32_t const b) {
  if (a == b) {
    return true;
  }
  const ast__ast__Ty *const at = typechecker__typechecker__TypeChecker__type_at(self, a);
  const ast__ast__Ty *const bt = typechecker__typechecker__TypeChecker__type_at(self, b);
  const bool ap = ((at->kind == ast__ast__TypeKind_TYPE_POINTER) || (at->kind == ast__ast__TypeKind_TYPE_REFERENCE));
  const bool bp = ((bt->kind == ast__ast__TypeKind_TYPE_POINTER) || (bt->kind == ast__ast__TypeKind_TYPE_REFERENCE));
  return (((ap && bp) && (at->qualifier == bt->qualifier)) && (at->as_data.elem == bt->as_data.elem));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__generic_fn_bound(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__Node *const gp = ast__ast__Ast__at_const(&((*a)), decl);
  if (gp->kind != ast__ast__NodeKind_NODE_GENERIC_PARAM) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__NodeList bounds = gp->as_data.generic_param.bounds;
  for (uint32_t i = 0U; i < bounds.len; i++) {
    const uint32_t bid = ast__ast__Ast__list(&((*a)), bounds)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), bid)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
      return bid;
    }
  }
  if ((self->current_fn != ast__ast__NODE_NONE) && ((self->package == NULL) || (m == self->ast.module))) {
    const ast__ast__NodeList wc = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), self->current_fn)->as_data.function.where_clause;
    for (uint32_t w = 0U; w < wc.len; w++) {
      const uint32_t wid = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wc)[((size_t)w)];
      const ast__ast__WherePredicateData wp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wid)->as_data.where_predicate;
      if (ast__ast__Ast__resolution(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wp.ty) == decl) {
        for (uint32_t b = 0U; b < wp.bounds.len; b++) {
          const uint32_t wbid = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wp.bounds)[((size_t)b)];
          if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wbid)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
            return wbid;
          }
        }
      }
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_is_capturing(const typechecker__typechecker__TypeChecker *const self, uint32_t const fid) {
  const ast__ast__Ty *const fy = typechecker__typechecker__TypeChecker__type_at(self, fid);
  if (fy->kind != ast__ast__TypeKind_TYPE_FUNCTION) {
    return false;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, fy->module);
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*a)), fy->as_data.decl);
  return ((fnn->kind == ast__ast__NodeKind_NODE_CLOSURE) && (fnn->as_data.closure.captures.len != 0U));
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tc_capture_index(const typechecker__typechecker__TypeChecker *const self, uint32_t const clos, uint32_t const decl) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList caps = ast__ast__Ast__at_const(&((*a)), clos)->as_data.closure.captures;
  for (uint32_t i = 0U; i < caps.len; i++) {
    const uint32_t cid = ast__ast__Ast__list(&((*a)), caps)[((size_t)i)];
    if (cid == decl) {
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_owns(typechecker__typechecker__TypeChecker *const self, uint32_t const fid) {
  const ast__ast__Ty fy = (*typechecker__typechecker__TypeChecker__type_at(self, fid));
  if (fy.kind != ast__ast__TypeKind_TYPE_FUNCTION) {
    return false;
  }
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, fy.module);
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*fa)), fy.as_data.decl);
  if (fnn->kind != ast__ast__NodeKind_NODE_CLOSURE) {
    return false;
  }
  const ast__ast__NodeList caps = fnn->as_data.closure.captures;
  const uint64_t mut_caps = ((uint64_t)fnn->as_data.closure.mut_caps);
  for (uint32_t i = 0U; i < caps.len; i++) {
    const uint32_t cid = ast__ast__Ast__list(&((*fa)), caps)[((size_t)i)];
    if ((({ uint64_t __sc57 = mut_caps; int64_t __sc58 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc58 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc57 >> __sc58); }) & 1ULL) == 0ULL) {
      const uint32_t rt = ast__ast__Ast__reintern(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (&(*fa)), ast__ast__Ast__type_of(&((*fa)), cid));
      if (typechecker__typechecker__TypeChecker__tc_type_is_free(self, rt)) {
        return true;
      }
    }
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_mark_capture_mut(typechecker__typechecker__TypeChecker *const self, uint32_t const expr0) {
  if (self->nclos == 0U) {
    return;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t expr = expr0;
  for (;;) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), expr);
    if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (expr = n->as_data.unary.operand);
    } else if ((n->kind == ast__ast__NodeKind_NODE_MEMBER) && (!n->as_data.member.path)) {
      (expr = n->as_data.member.object);
    } else if (n->kind == ast__ast__NodeKind_NODE_INDEX) {
      (expr = n->as_data.index.object);
    } else {
      break;
    }
  }
  if (ast__ast__Ast__at_const(&((*a)), expr)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), expr);
  if ((d.module != self->ast.module) || (d.node == ast__ast__NODE_NONE)) {
    return;
  }
  for (uint32_t f = 0U; f < self->nclos; f++) {
    const int32_t idx = typechecker__typechecker__TypeChecker__tc_capture_index(self, self->clos_stack[((size_t)f)], d.node);
    if (idx >= 0) {
      const uint32_t cs = self->clos_stack[((size_t)f)];
      const uint64_t old = ((uint64_t)ast__ast__Ast__at(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), cs)->as_data.closure.mut_caps);
      (ast__ast__Ast__at(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), cs)->as_data.closure.mut_caps = ((uint32_t)(old | ({ uint64_t __sc59 = 1ULL; int64_t __sc60 = (int64_t)(((uint64_t)idx)); if ((uint64_t)__sc60 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc59 << __sc60)); }))));
    }
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__ret_eq(const typechecker__typechecker__TypeChecker *const self, uint32_t const a, uint32_t const b) {
  (void)self;
  if (a == b) {
    return true;
  }
  const uint32_t v = 18U;
  return (((a == ast__ast__TYPE_NONE) || (a == v)) && ((b == ast__ast__TYPE_NONE) || (b == v)));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_compatible(typechecker__typechecker__TypeChecker *const self, uint32_t const exid, uint32_t const acid) {
  if ((exid != acid) && typechecker__typechecker__TypeChecker__fn_is_capturing(self, acid)) {
    return false;
  }
  typechecker__typechecker__Tys4 ep = (typechecker__typechecker__Tys4){0};
  typechecker__typechecker__Tys4 ap = (typechecker__typechecker__Tys4){0};
  uint32_t er = ast__ast__TYPE_NONE;
  uint32_t ar = ast__ast__TYPE_NONE;
  const int32_t en = typechecker__typechecker__TypeChecker__fn_sig(self, exid, ((uint32_t *)(&ep.t[0])), 4, ((uint32_t *)(&er)));
  const int32_t an = typechecker__typechecker__TypeChecker__fn_sig(self, acid, ((uint32_t *)(&ap.t[0])), 4, ((uint32_t *)(&ar)));
  if (((en != an) || (en > 4)) || (!typechecker__typechecker__TypeChecker__ret_eq(self, er, ar))) {
    return false;
  }
  for (int32_t i = 0; i < en; i++) {
    if (ep.t[((size_t)i)] != ap.t[((size_t)i)]) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dynfn_sig_ok(typechecker__typechecker__TypeChecker *const self, uint32_t const exid, uint32_t const acid) {
  typechecker__typechecker__Tys4 ep = (typechecker__typechecker__Tys4){0};
  typechecker__typechecker__Tys4 ap = (typechecker__typechecker__Tys4){0};
  uint32_t er = ast__ast__TYPE_NONE;
  uint32_t ar = ast__ast__TYPE_NONE;
  const int32_t en = typechecker__typechecker__TypeChecker__fn_sig(self, exid, ((uint32_t *)(&ep.t[0])), 4, ((uint32_t *)(&er)));
  const int32_t an = typechecker__typechecker__TypeChecker__fn_sig(self, acid, ((uint32_t *)(&ap.t[0])), 4, ((uint32_t *)(&ar)));
  if (((en != an) || (en > 4)) || (!typechecker__typechecker__TypeChecker__ret_eq(self, er, ar))) {
    return false;
  }
  for (int32_t i = 0; i < en; i++) {
    if (ep.t[((size_t)i)] != ap.t[((size_t)i)]) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_dyn_fn_sig(typechecker__typechecker__TypeChecker *const self, const ast__ast__Ty *const ty) {
  if (ty->kind != ast__ast__TypeKind_TYPE_DYN) {
    return ast__ast__TYPE_NONE;
  }
  if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ty->module))), ty->as_data.decl)->kind != ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    return ast__ast__TYPE_NONE;
  }
  return typechecker__typechecker__TypeChecker__lower_type_in(self, ty->module, ty->as_data.decl);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_dyn_same(typechecker__typechecker__TypeChecker *const self, const ast__ast__Ty *const a, const ast__ast__Ty *const b) {
  const uint32_t as2 = typechecker__typechecker__TypeChecker__tc_dyn_fn_sig(self, (&(*a)));
  const uint32_t bs = typechecker__typechecker__TypeChecker__tc_dyn_fn_sig(self, (&(*b)));
  if ((as2 != ast__ast__TYPE_NONE) != (bs != ast__ast__TYPE_NONE)) {
    return false;
  }
  if (as2 != ast__ast__TYPE_NONE) {
    return ((as2 == bs) || typechecker__typechecker__TypeChecker__fn_compatible(self, as2, bs));
  }
  return ((a->module == b->module) && (a->as_data.decl == b->as_data.decl));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__if_node(bool const c, uint32_t const a, uint32_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__if_ty(bool const c, uint32_t const a, uint32_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) const char *typechecker__typechecker__src_at(const uint8_t *const p, uint32_t const off) {
  return ((const char *)(p + ((size_t)off)));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__aggregate_of(const typechecker__typechecker__TypeChecker *const self, uint32_t const ty, uint16_t *const mod_out, uint32_t *const decl_out, ast__ast__DefId *const params, uint32_t *const args, int32_t *const n_out) {
  ((*n_out) = 0);
  const ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, ty));
  if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    ((*mod_out) = y.module);
    ((*decl_out) = y.as_data.decl);
    return true;
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), y.as_data.inst));
    ((*mod_out) = it.module);
    ((*decl_out) = it.decl);
    ast__ast__Ast *const da = typechecker__typechecker__TypeChecker__mod_ast(self, it.module);
    const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*da)), it.decl)->as_data.aggregate.generics;
    int32_t nn = 0;
    uint32_t i = 0U;
    while (((i < gens.len) && (((uint8_t)i) < it.n)) && (nn < 4)) {
      const uint32_t gid = ast__ast__Ast__list(&((*da)), gens)[((size_t)i)];
      (params[((size_t)nn)] = (ast__ast__DefId){ .module = it.module, .node = gid });
      (args[((size_t)nn)] = it.args[((size_t)i)]);
      (nn = ({ int32_t __sc_r; if (__builtin_add_overflow(nn, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      (i = (i + 1U));
    }
    ((*n_out) = nn);
    return true;
  }
  return false;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__subst_type(typechecker__typechecker__TypeChecker *const self, uint32_t const ty, const ast__ast__DefId *const params, const uint32_t *const args, int32_t const n) {
  if ((ty == ast__ast__TYPE_NONE) || (n == 0)) {
    return ty;
  }
  const ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, ty));
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    for (int32_t i = 0; i < n; i++) {
      if ((params[((size_t)i)].module == y.module) && (params[((size_t)i)].node == y.as_data.decl)) {
        return args[((size_t)i)];
      }
    }
    return ty;
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_SLICE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    const uint32_t e = typechecker__typechecker__TypeChecker__subst_type(self, y.as_data.elem, params, args, n);
    if (e == y.as_data.elem) {
      return ty;
    }
    ast__ast__Ty nt = y;
    (nt.as_data.elem = e);
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nt);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance src = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), y.as_data.inst));
    typechecker__typechecker__Tys4 na = (typechecker__typechecker__Tys4){0};
    bool changed = false;
    for (uint8_t i = 0U; i < src.n; i++) {
      (na.t[((size_t)i)] = typechecker__typechecker__TypeChecker__subst_type(self, src.args[((size_t)i)], params, args, n));
      if (na.t[((size_t)i)] != src.args[((size_t)i)]) {
        (changed = true);
      }
    }
    if (changed) {
      return ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), src.module, src.decl, ((const uint32_t *)(&na.t[0])), src.n);
    }
    return ty;
  }
  return ty;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__unify_infer(typechecker__typechecker__TypeChecker *const self, uint32_t const param_ty, uint32_t const arg_ty, const ast__ast__DefId *const params, uint32_t *const bound, int32_t const n) {
  if ((param_ty == ast__ast__TYPE_NONE) || (arg_ty == ast__ast__TYPE_NONE)) {
    return;
  }
  const ast__ast__Ty p = (*typechecker__typechecker__TypeChecker__type_at(self, param_ty));
  if (p.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    for (int32_t i = 0; i < n; i++) {
      if ((params[((size_t)i)].module == p.module) && (params[((size_t)i)].node == p.as_data.decl)) {
        if (bound[((size_t)i)] == ast__ast__TYPE_NONE) {
          (bound[((size_t)i)] = arg_ty);
        }
        return;
      }
    }
    return;
  }
  const ast__ast__Ty aT = (*typechecker__typechecker__TypeChecker__type_at(self, arg_ty));
  if ((aT.kind == p.kind) && ((((p.kind == ast__ast__TypeKind_TYPE_POINTER) || (p.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (p.kind == ast__ast__TypeKind_TYPE_SLICE)) || (p.kind == ast__ast__TypeKind_TYPE_ARRAY))) {
    typechecker__typechecker__TypeChecker__unify_infer(self, p.as_data.elem, aT.as_data.elem, params, bound, n);
  } else if ((p.kind == ast__ast__TypeKind_TYPE_INSTANCE) && (aT.kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
    const ast__ast__TyInstance pi = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), p.as_data.inst));
    const ast__ast__TyInstance ai = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), aT.as_data.inst));
    if (((pi.decl == ai.decl) && (pi.module == ai.module)) && (pi.n == ai.n)) {
      for (uint8_t i = 0U; i < pi.n; i++) {
        typechecker__typechecker__TypeChecker__unify_infer(self, pi.args[((size_t)i)], ai.args[((size_t)i)], params, bound, n);
      }
    }
  } else if ((p.kind == ast__ast__TypeKind_TYPE_FUNCTION) && (aT.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
    typechecker__typechecker__Tys4 pp = (typechecker__typechecker__Tys4){0};
    typechecker__typechecker__Tys4 ap = (typechecker__typechecker__Tys4){0};
    uint32_t pr = ast__ast__TYPE_NONE;
    uint32_t ar = ast__ast__TYPE_NONE;
    const int32_t pn = typechecker__typechecker__TypeChecker__fn_sig(self, param_ty, ((uint32_t *)(&pp.t[0])), 4, ((uint32_t *)(&pr)));
    const int32_t an = typechecker__typechecker__TypeChecker__fn_sig(self, arg_ty, ((uint32_t *)(&ap.t[0])), 4, ((uint32_t *)(&ar)));
    if ((pn == an) && (pn <= 4)) {
      for (int32_t i = 0; i < pn; i++) {
        typechecker__typechecker__TypeChecker__unify_infer(self, pp.t[((size_t)i)], ap.t[((size_t)i)], params, bound, n);
      }
      typechecker__typechecker__TypeChecker__unify_infer(self, pr, ar, params, bound, n);
    }
  }
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__named_type_of(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*a)), decl)->kind;
  if (dk == ast__ast__NodeKind_NODE_STRUCT) {
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_STRUCT, .module = m, .as_data = (ast__ast__TyAs){ .decl = decl } });
  }
  if (dk == ast__ast__NodeKind_NODE_ENUM) {
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_ENUM, .module = m, .as_data = (ast__ast__TyAs){ .decl = decl } });
  }
  if (dk == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
    const uint32_t aliased_node = ast__ast__Ast__at_const(&((*a)), decl)->as_data.type_alias.ty;
    if (aliased_node == ast__ast__NODE_NONE) {
      return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_OPAQUE, .module = m, .as_data = (ast__ast__TyAs){ .decl = decl } });
    }
    if (self->alias_depth >= typechecker__typechecker__TYPE_ALIAS_MAX_DEPTH) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), decl)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc61 = String__Global__new();
String__Global__push_str(&__sc61, (str){ .ptr = (const uint8_t*)"type alias is cyclic", .len = sizeof("type alias is cyclic") - 1 });
__sc61; }));
      return typechecker__typechecker__TYPE_ERROR;
    }
    (self->alias_depth = (self->alias_depth + 1U));
    const uint32_t aliased = typechecker__typechecker__TypeChecker__lower_type_in(self, m, aliased_node);
    (self->alias_depth = (self->alias_depth - 1U));
    return aliased;
  }
  if ((dk == ast__ast__NodeKind_NODE_GENERIC_PARAM) || (dk == ast__ast__NodeKind_NODE_INTERFACE)) {
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_GENERIC, .module = m, .as_data = (ast__ast__TyAs){ .decl = decl } });
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__agg_has_default_at(const typechecker__typechecker__TypeChecker *const self, uint16_t const dmod, uint32_t const dn, uint32_t const from) {
  ast__ast__Ast *const da = typechecker__typechecker__TypeChecker__mod_ast(self, dmod);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*da)), dn)->as_data.aggregate.generics;
  if (from >= gens.len) {
    return false;
  }
  const uint32_t gid = ast__ast__Ast__list(&((*da)), gens)[((size_t)from)];
  return (ast__ast__Ast__at_const(&((*da)), gid)->as_data.generic_param.default_type != ast__ast__NODE_NONE);
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__apply_default_args(typechecker__typechecker__TypeChecker *const self, uint16_t const dmod, uint32_t const dn, uint32_t *const ta, uint8_t *const tn) {
  ast__ast__Ast *const da = typechecker__typechecker__TypeChecker__mod_ast(self, dmod);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*da)), dn)->as_data.aggregate.generics;
  if ((*tn) >= ((uint8_t)gens.len)) {
    return;
  }
  uint32_t i = ((uint32_t)(*tn));
  while ((i < gens.len) && ((*tn) < 4U)) {
    const uint32_t gid = ast__ast__Ast__list(&((*da)), gens)[((size_t)i)];
    const uint32_t dft = ast__ast__Ast__at_const(&((*da)), gid)->as_data.generic_param.default_type;
    if (dft == ast__ast__NODE_NONE) {
      break;
    }
    uint32_t d = typechecker__typechecker__TypeChecker__lower_type_in(self, dmod, dft);
    if ((*tn) > 0U) {
      typechecker__typechecker__Defs4 prm = (typechecker__typechecker__Defs4){0};
      for (uint8_t j = 0U; j < (*tn); j++) {
        const uint32_t gj = ast__ast__Ast__list(&((*da)), gens)[((size_t)j)];
        (prm.d[((size_t)j)] = (ast__ast__DefId){ .module = dmod, .node = gj });
      }
      (d = typechecker__typechecker__TypeChecker__subst_type(self, d, ((const ast__ast__DefId *)(&prm.d[0])), ((const uint32_t *)ta), ((int32_t)(*tn))));
    }
    const uint8_t k = (*tn);
    (ta[((size_t)k)] = d);
    ((*tn) = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
    (i = (i + 1U));
  }
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_str_type(typechecker__typechecker__TypeChecker *const self) {
  if (self->package == NULL) {
    return typechecker__typechecker__TYPE_ERROR;
  }
  const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"str", sizeof("str") - 1 }, true);
  if (hit.node != ast__ast__NODE_NONE) {
    return typechecker__typechecker__TypeChecker__named_type_of(self, hit.mid, hit.node);
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_slice_type(typechecker__typechecker__TypeChecker *const self, uint32_t const elem, bool const mut2) {
  if (self->package == NULL) {
    return typechecker__typechecker__TYPE_ERROR;
  }
  module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Slice", sizeof("Slice") - 1 }, true);
  if (mut2) {
    (hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"SliceMut", sizeof("SliceMut") - 1 }, true));
  }
  if (hit.node != ast__ast__NODE_NONE) {
    return ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hit.mid, hit.node, ((const uint32_t *)(&elem)), 1U);
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_range_type(typechecker__typechecker__TypeChecker *const self, uint32_t const elem) {
  if (self->package == NULL) {
    return typechecker__typechecker__TYPE_ERROR;
  }
  const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Range", sizeof("Range") - 1 }, true);
  if (hit.node != ast__ast__NODE_NONE) {
    return ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hit.mid, hit.node, ((const uint32_t *)(&elem)), 1U);
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__prelude_tuple_type(typechecker__typechecker__TypeChecker *const self, const uint32_t *const args, uint32_t const n) {
  if (((self->package == NULL) || (n < 2U)) || (n > 4U)) {
    return typechecker__typechecker__TYPE_ERROR;
  }
  const char *nm = ((const char *)({ __auto_type __sc62 = (str){ (const uint8_t *)"Tuple2", sizeof("Tuple2") - 1 }; str__ptr(&__sc62); }));
  if (n == 3U) {
    (nm = ((const char *)({ __auto_type __sc63 = (str){ (const uint8_t *)"Tuple3", sizeof("Tuple3") - 1 }; str__ptr(&__sc63); })));
  } else if (n == 4U) {
    (nm = ((const char *)({ __auto_type __sc64 = (str){ (const uint8_t *)"Tuple4", sizeof("Tuple4") - 1 }; str__ptr(&__sc64); })));
  }
  const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), str__from_raw(((const uint8_t *)nm), 6ULL), true);
  if (hit.node != ast__ast__NODE_NONE) {
    return ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hit.mid, hit.node, args, ((uint8_t)n));
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__prelude_instance_args(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, str const name, uint32_t *const out, int32_t const maxn) {
  if ((self->package == NULL) || (tid == ast__ast__TYPE_NONE)) {
    return -1;
  }
  const ast__ast__Ty *const ty = typechecker__typechecker__TypeChecker__type_at(self, tid);
  if (ty->kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return -1;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ty->as_data.inst));
  const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), name, true);
  if (((hit.node == ast__ast__NODE_NONE) || (it.module != hit.mid)) || (it.decl != hit.node)) {
    return -1;
  }
  int32_t i = 0;
  while ((i < ((int32_t)it.n)) && (i < maxn)) {
    (out[((size_t)i)] = it.args[((size_t)i)]);
    (i = ({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return ((int32_t)it.n);
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__tuple_args_of(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, uint32_t *const out, int32_t const maxn) {
  const int32_t n2 = typechecker__typechecker__TypeChecker__prelude_instance_args(self, tid, (str){ (const uint8_t *)"Tuple2", sizeof("Tuple2") - 1 }, out, maxn);
  if (n2 >= 0) {
    return n2;
  }
  const int32_t n3 = typechecker__typechecker__TypeChecker__prelude_instance_args(self, tid, (str){ (const uint8_t *)"Tuple3", sizeof("Tuple3") - 1 }, out, maxn);
  if (n3 >= 0) {
    return n3;
  }
  return typechecker__typechecker__TypeChecker__prelude_instance_args(self, tid, (str){ (const uint8_t *)"Tuple4", sizeof("Tuple4") - 1 }, out, maxn);
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__range_instance_elem(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid) {
  if (self->package == NULL) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Ty *const ty = typechecker__typechecker__TypeChecker__type_at(self, tid);
  if (ty->kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ty->as_data.inst));
  const module__loader__LookupHit hit = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Range", sizeof("Range") - 1 }, true);
  if (((it.n == 1U) && (it.module == hit.mid)) && (it.decl == hit.node)) {
    return it.args[0];
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__slice_kind(const typechecker__typechecker__TypeChecker *const self, uint32_t const tid, uint32_t *const elem) {
  if (self->package == NULL) {
    return 0;
  }
  const ast__ast__Ty *const ty = typechecker__typechecker__TypeChecker__type_at(self, tid);
  if (ty->kind != ast__ast__TypeKind_TYPE_INSTANCE) {
    return 0;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ty->as_data.inst));
  if (it.n != 1U) {
    return 0;
  }
  const module__loader__LookupHit sh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Slice", sizeof("Slice") - 1 }, true);
  const module__loader__LookupHit mh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"SliceMut", sizeof("SliceMut") - 1 }, true);
  int32_t kind = 0;
  if ((it.module == sh.mid) && (it.decl == sh.node)) {
    (kind = 1);
  } else if ((it.module == mh.mid) && (it.decl == mh.node)) {
    (kind = 2);
  }
  if ((kind != 0) && (elem != NULL)) {
    ((*elem) = it.args[0]);
  }
  return kind;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_box_of(const typechecker__typechecker__TypeChecker *const self, const ast__ast__Ty *const y, uint32_t *const inner, bool *const global_alloc) {
  if ((y->kind != ast__ast__TypeKind_TYPE_INSTANCE) || (self->package == NULL)) {
    return false;
  }
  const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), y->as_data.inst));
  const module__loader__LookupHit bh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Box", sizeof("Box") - 1 }, true);
  if (((it.module != bh.mid) || (it.decl != bh.node)) || (it.n < 1U)) {
    return false;
  }
  ((*inner) = it.args[0]);
  const module__loader__LookupHit gh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Global", sizeof("Global") - 1 }, true);
  bool ga = false;
  if (it.n >= 2U) {
    const ast__ast__Ty *const ay = typechecker__typechecker__TypeChecker__type_at(self, it.args[1]);
    (ga = (((ay->kind == ast__ast__TypeKind_TYPE_STRUCT) && (ay->module == gh.mid)) && (ay->as_data.decl == gh.node)));
  }
  ((*global_alloc) = ga);
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__decl_type_in(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl) {
  if (decl == ast__ast__NODE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const bool local = ((self->package == NULL) || (m == self->ast.module));
  if (local) {
    const uint32_t cached = ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), decl);
    if (cached != ast__ast__TYPE_NONE) {
      return cached;
    }
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*a)), decl)->kind;
  uint32_t result = ast__ast__TYPE_NONE;
  if (dk == ast__ast__NodeKind_NODE_PARAMETER) {
    (result = typechecker__typechecker__TypeChecker__lower_type_in(self, m, ast__ast__Ast__at_const(&((*a)), decl)->as_data.parameter.ty));
  } else if (dk == ast__ast__NodeKind_NODE_FIELD) {
    (result = typechecker__typechecker__TypeChecker__lower_type_in(self, m, ast__ast__Ast__at_const(&((*a)), decl)->as_data.field.ty));
  } else if (dk == ast__ast__NodeKind_NODE_CONST) {
    (result = typechecker__typechecker__TypeChecker__lower_type_in(self, m, ast__ast__Ast__at_const(&((*a)), decl)->as_data.const_def.ty));
  } else if (dk == ast__ast__NodeKind_NODE_LET) {
    (result = typechecker__typechecker__TypeChecker__lower_type_in(self, m, ast__ast__Ast__at_const(&((*a)), decl)->as_data.let_stmt.ty));
  } else if (dk == ast__ast__NodeKind_NODE_FUNCTION) {
    (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_FUNCTION, .module = m, .as_data = (ast__ast__TyAs){ .decl = decl } }));
  } else if (dk == ast__ast__NodeKind_NODE_GENERIC_PARAM) {
    const ast__ast__GenericParamData gp = ast__ast__Ast__at_const(&((*a)), decl)->as_data.generic_param;
    if (gp.is_const) {
      (result = typechecker__typechecker__TypeChecker__lower_type_in(self, m, gp.const_type));
    } else {
      (result = typechecker__typechecker__TypeChecker__named_type_of(self, m, decl));
    }
  } else if ((dk == ast__ast__NodeKind_NODE_STRUCT) || (dk == ast__ast__NodeKind_NODE_ENUM)) {
    (result = typechecker__typechecker__TypeChecker__named_type_of(self, m, decl));
  }
  if (local) {
    ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), decl, result);
  }
  return result;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__decl_type(typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  return typechecker__typechecker__TypeChecker__decl_type_in(self, self->ast.module, decl);
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__type_of_type_node(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return typechecker__typechecker__TypeChecker__resolve_type(self, id);
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  if (d.node != ast__ast__NODE_NONE) {
    return typechecker__typechecker__TypeChecker__named_type_of(self, d.module, d.node);
  }
  const int32_t b = typechecker__typechecker__builtin_of(self->source, typechecker__typechecker__TypeChecker__name_span(self, id));
  if (b >= 0) {
    return ast__ast__Ast__builtin(((ast__ast__BuiltinType)b));
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_const_arg(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const aid) {
  consteval__consteval__ConstEval *const ceptr = typechecker__typechecker__TypeChecker__ceval(self);
  if (ceptr != NULL) {
    const consteval__consteval__ConstValue lv = consteval__consteval__ConstEval__eval(&((*ceptr)), m, aid);
    if (lv.kind == consteval__consteval__CONST_INT) {
      return ast__ast__Ast__const_value(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), lv.as_data.i);
    }
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, m))), aid)->span;
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc65 = String__Global__new();
String__Global__push_str(&__sc65, (str){ .ptr = (const uint8_t*)"const generic argument must be a constant integer", .len = sizeof("const generic argument must be a constant integer") - 1 });
__sc65; }));
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__ce_array_len(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const lenNode) {
  consteval__consteval__ConstEval *const ceptr = typechecker__typechecker__TypeChecker__ceval(self);
  if (ceptr == NULL) {
    return 0U;
  }
  const consteval__consteval__ConstValue lv = consteval__consteval__ConstEval__eval(&((*ceptr)), m, lenNode);
  if (((lv.kind == consteval__consteval__CONST_INT) && (lv.as_data.i > 0)) && (lv.as_data.i <= 0xFFFFFFFFLL)) {
    return ((uint32_t)lv.as_data.i);
  }
  return 0U;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__lower_type_in(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const id) {
  if ((self->package == NULL) || (m == self->ast.module)) {
    return typechecker__typechecker__TypeChecker__resolve_type(self, id);
  }
  if (id == ast__ast__NODE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), id)->kind;
  if (nk == ast__ast__NodeKind_NODE_TYPE_PATH) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
    const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*a)), id)->as_data.type_path.args;
    if (d.node != ast__ast__NODE_NONE) {
      const int32_t bb = module__loader__Package__builtin_of_decl(&((*self->package)), d.module, d.node);
      if (bb >= 0) {
        return ast__ast__Ast__builtin(((ast__ast__BuiltinType)bb));
      }
      const ast__ast__NodeKind dnk = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind;
      if ((args.len == 1U) && (self->package != NULL)) {
        const uint32_t a0 = ast__ast__Ast__list(&((*a)), args)[0];
        const ast__ast__Node *const an = ast__ast__Ast__at_const(&((*a)), a0);
        if ((an->kind == ast__ast__NodeKind_NODE_DYN_TYPE) && (an->as_data.indirect_type.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_NONE)) {
          const module__loader__LookupHit bh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Box", sizeof("Box") - 1 }, true);
          if ((d.module == bh.mid) && (d.node == bh.node)) {
            return typechecker__typechecker__TypeChecker__lower_type_in(self, m, a0);
          }
        }
      }
      if ((((dnk == ast__ast__NodeKind_NODE_STRUCT) || (dnk == ast__ast__NodeKind_NODE_ENUM)) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->as_data.aggregate.generics.len > 0U)) && ((args.len > 0U) || typechecker__typechecker__TypeChecker__agg_has_default_at(self, d.module, d.node, args.len))) {
        typechecker__typechecker__Tys4 ta = (typechecker__typechecker__Tys4){0};
        uint8_t tn = 0U;
        uint32_t i = 0U;
        while ((i < args.len) && (tn < 4U)) {
          const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)i)];
          if (ast__ast__Ast__at_const(&((*a)), aid)->kind == ast__ast__NodeKind_NODE_LITERAL) {
            (ta.t[((size_t)tn)] = typechecker__typechecker__TypeChecker__tc_const_arg(self, m, aid));
            (tn = ((uint8_t)((uint32_t)tn + (uint32_t)1U)));
            (i = (i + 1U));
            continue;
          }
          (ta.t[((size_t)tn)] = typechecker__typechecker__TypeChecker__lower_type_in(self, m, aid));
          if (((ta.t[((size_t)tn)] != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ta.t[((size_t)tn)])->kind == ast__ast__TypeKind_TYPE_ARRAY)) && (typechecker__typechecker__TypeChecker__type_at(self, ta.t[((size_t)tn)])->as_data.arr.len == 0U)) {
            const lexer__token__Span asp = ast__ast__Ast__at_const(&((*a)), aid)->span;
            utils__errors__Errors__emit(&self->errors, asp.start, (asp.end - asp.start), ({ String__Global __sc66 = String__Global__new();
String__Global__push_str(&__sc66, (str){ .ptr = (const uint8_t*)"a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct", .len = sizeof("a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct") - 1 });
__sc66; }));
            (ta.t[((size_t)tn)] = ast__ast__TYPE_NONE);
          }
          (tn = ((uint8_t)((uint32_t)tn + (uint32_t)1U)));
          (i = (i + 1U));
        }
        typechecker__typechecker__TypeChecker__apply_default_args(self, d.module, d.node, ((uint32_t *)(&ta.t[0])), ((uint8_t *)(&tn)));
        return ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), d.module, d.node, ((const uint32_t *)(&ta.t[0])), tn);
      }
      return typechecker__typechecker__TypeChecker__named_type_of(self, d.module, d.node);
    }
    const ast__ast__NodeList parts = ast__ast__Ast__at_const(&((*a)), id)->as_data.type_path.parts;
    int32_t b = -1;
    if (parts.len != 0U) {
      const uint32_t p0 = ast__ast__Ast__list(&((*a)), parts)[0];
      (b = typechecker__typechecker__builtin_of(typechecker__typechecker__TypeChecker__mod_src(self, m), ast__ast__Ast__at_const(&((*a)), p0)->as_data.name.text));
    }
    if (b >= 0) {
      return ast__ast__Ast__builtin(((ast__ast__BuiltinType)b));
    }
    return typechecker__typechecker__TYPE_ERROR;
  }
  if (nk == ast__ast__NodeKind_NODE_SLICE_TYPE) {
    const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type;
    return typechecker__typechecker__TypeChecker__prelude_slice_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, m, it.ty), (it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT));
  }
  if (nk == ast__ast__NodeKind_NODE_TUPLE_TYPE) {
    const ast__ast__NodeList elems = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_literal.elements;
    if (elems.len > 4U) {
      return typechecker__typechecker__TYPE_ERROR;
    }
    typechecker__typechecker__Tys4 targs = (typechecker__typechecker__Tys4){0};
    for (uint32_t i = 0U; i < elems.len; i++) {
      (targs.t[((size_t)i)] = typechecker__typechecker__TypeChecker__lower_type_in(self, m, ast__ast__Ast__list(&((*a)), elems)[((size_t)i)]));
    }
    return typechecker__typechecker__TypeChecker__prelude_tuple_type(self, ((const uint32_t *)(&targs.t[0])), elems.len);
  }
  if ((nk == ast__ast__NodeKind_NODE_POINTER_TYPE) || (nk == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
    const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type;
    ast__ast__TypeKind k = ast__ast__TypeKind_TYPE_REFERENCE;
    if (nk == ast__ast__NodeKind_NODE_POINTER_TYPE) {
      (k = ast__ast__TypeKind_TYPE_POINTER);
    }
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = k, .qualifier = ((uint8_t)it.qualifier), .as_data = (ast__ast__TyAs){ .elem = typechecker__typechecker__TypeChecker__lower_type_in(self, m, it.ty) } });
  }
  if (nk == ast__ast__NodeKind_NODE_ARRAY_TYPE) {
    const ast__ast__ArrayTypeData at = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_type;
    const uint32_t alen = typechecker__typechecker__TypeChecker__ce_array_len(self, m, at.length);
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_ARRAY, .as_data = (ast__ast__TyAs){ .arr = (ast__ast__TyArr){ .elem = typechecker__typechecker__TypeChecker__lower_type_in(self, m, at.element), .len = alen } } });
  }
  if (nk == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_FUNCTION, .module = m, .as_data = (ast__ast__TyAs){ .decl = id } });
  }
  if (nk == ast__ast__NodeKind_NODE_DYN_TYPE) {
    const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type;
    const uint32_t inner = it.ty;
    if (ast__ast__Ast__at_const(&((*a)), inner)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
      return typechecker__typechecker__TypeChecker__tc_intern_dynfn(self, m, inner, it.qualifier);
    }
    ast__ast__DefId d = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    if (ast__ast__Ast__at_const(&((*a)), inner)->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
      (d = ast__ast__Ast__resolution_def(&((*a)), inner));
    }
    if ((d.node == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_INTERFACE)) {
      return typechecker__typechecker__TYPE_ERROR;
    }
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_DYN, .qualifier = ((uint8_t)it.qualifier), .module = d.module, .as_data = (ast__ast__TyAs){ .decl = d.node } });
  }
  return typechecker__typechecker__TYPE_ERROR;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__resolve_type(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const uint32_t cached = ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  if (cached != ast__ast__TYPE_NONE) {
    return cached;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), id)->kind;
  uint32_t result = typechecker__typechecker__TYPE_ERROR;
  {
    const ast__ast__NodeKind __sc67 = nk;
    if (__sc67 == ast__ast__NodeKind_NODE_TYPE_PATH) {
      {
        const ast__ast__NodeList parts = ast__ast__Ast__at_const(&((*a)), id)->as_data.type_path.parts;
        const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*a)), id)->as_data.type_path.args;
        uint32_t i = 0U;
        while ((i < args.len) && (self->package != NULL)) {
          const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)i)];
          const ast__ast__Node *const an = ast__ast__Ast__at_const(&((*a)), aid);
          if ((an->kind != ast__ast__NodeKind_NODE_DYN_TYPE) || (an->as_data.indirect_type.qualifier != ast__ast__TypeQualifier_TYPE_QUAL_NONE)) {
            (i = (i + 1U));
            continue;
          }
          const module__loader__LookupHit bh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"Box", sizeof("Box") - 1 }, true);
          const ast__ast__DefId hd = ast__ast__Ast__resolution_def(&((*a)), id);
          if (((args.len == 1U) && (hd.module == bh.mid)) && (hd.node == bh.node)) {
            (result = typechecker__typechecker__TypeChecker__resolve_dyn_node(self, ast__ast__Ast__list(&((*a)), args)[0], ast__ast__TypeQualifier_TYPE_QUAL_NONE));
          } else {
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc68 = String__Global__new();
String__Global__push_str(&__sc68, (str){ .ptr = (const uint8_t*)"a bare 'dyn' type can only be the generic argument of 'Box'", .len = sizeof("a bare 'dyn' type can only be the generic argument of 'Box'") - 1 });
__sc68; }));
          }
          ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, result);
          return result;
        }
        (i = 0U);
        while (i < args.len) {
          typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*a)), args)[((size_t)i)]);
          (i = (i + 1U));
        }
        const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
        if (d.node != ast__ast__NODE_NONE) {
          int32_t bb = -1;
          if (self->package != NULL) {
            (bb = module__loader__Package__builtin_of_decl(&((*self->package)), d.module, d.node));
          }
          if (bb >= 0) {
            (result = ast__ast__Ast__builtin(((ast__ast__BuiltinType)bb)));
          } else {
            const ast__ast__NodeKind dnk = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind;
            const bool generic_agg = (((dnk == ast__ast__NodeKind_NODE_STRUCT) || (dnk == ast__ast__NodeKind_NODE_ENUM)) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->as_data.aggregate.generics.len > 0U));
            if ((((generic_agg && (args.len == 0U)) && (self->current_extend != ast__ast__NODE_NONE)) && (d.module == self->ast.module)) && (d.node == self->current_self)) {
              const uint32_t target = ast__ast__Ast__at_const(&((*a)), self->current_extend)->as_data.extend_def.target_type;
              if (target != id) {
                (result = typechecker__typechecker__TypeChecker__resolve_type(self, target));
              } else {
                (result = typechecker__typechecker__TypeChecker__named_type_of(self, d.module, d.node));
              }
            } else if (generic_agg && ((args.len > 0U) || typechecker__typechecker__TypeChecker__agg_has_default_at(self, d.module, d.node, args.len))) {
              typechecker__typechecker__Tys4 ta = (typechecker__typechecker__Tys4){0};
              uint8_t tn = 0U;
              uint32_t j = 0U;
              while ((j < args.len) && (tn < 4U)) {
                const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)j)];
                if (ast__ast__Ast__at_const(&((*a)), aid)->kind == ast__ast__NodeKind_NODE_LITERAL) {
                  (ta.t[((size_t)tn)] = typechecker__typechecker__TypeChecker__tc_const_arg(self, self->ast.module, aid));
                } else {
                  (ta.t[((size_t)tn)] = typechecker__typechecker__TypeChecker__resolve_type(self, aid));
                  if (((ta.t[((size_t)tn)] != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ta.t[((size_t)tn)])->kind == ast__ast__TypeKind_TYPE_ARRAY)) && (typechecker__typechecker__TypeChecker__type_at(self, ta.t[((size_t)tn)])->as_data.arr.len == 0U)) {
                    const lexer__token__Span asp = ast__ast__Ast__at_const(&((*a)), aid)->span;
                    utils__errors__Errors__emit(&self->errors, asp.start, (asp.end - asp.start), ({ String__Global __sc69 = String__Global__new();
String__Global__push_str(&__sc69, (str){ .ptr = (const uint8_t*)"a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct", .len = sizeof("a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct") - 1 });
__sc69; }));
                    (ta.t[((size_t)tn)] = ast__ast__TYPE_NONE);
                  }
                }
                (tn = ((uint8_t)((uint32_t)tn + (uint32_t)1U)));
                (j = (j + 1U));
              }
              typechecker__typechecker__TypeChecker__apply_default_args(self, d.module, d.node, ((uint32_t *)(&ta.t[0])), ((uint8_t *)(&tn)));
              (result = ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), d.module, d.node, ((const uint32_t *)(&ta.t[0])), tn));
            } else {
              (result = typechecker__typechecker__TypeChecker__named_type_of(self, d.module, d.node));
              if (((dnk == ast__ast__NodeKind_NODE_INTERFACE) && (parts.len != 0U)) && (!typechecker__typechecker__span_is(self->source, typechecker__typechecker__TypeChecker__name_span(self, ast__ast__Ast__list(&((*a)), parts)[0]), (str){ (const uint8_t *)"Self", sizeof("Self") - 1 }))) {
                const lexer__token__Span isp = typechecker__typechecker__TypeChecker__name_span(self, ast__ast__Ast__list(&((*a)), parts)[0]);
                utils__errors__Errors__emit(&self->errors, isp.start, (isp.end - isp.start), ({ String__Global __sc70 = String__Global__new();
String__Global__push_str(&__sc70, (str){ .ptr = (const uint8_t*)"an interface is not a type; use '&dyn ", .len = sizeof("an interface is not a type; use '&dyn ") - 1 });
String__Global__push_str(&__sc70, utils__errors__span_str(self->source, isp.start, isp.end));
String__Global__push_str(&__sc70, (str){ .ptr = (const uint8_t*)"', 'Box<dyn ", .len = sizeof("', 'Box<dyn ") - 1 });
String__Global__push_str(&__sc70, utils__errors__span_str(self->source, isp.start, isp.end));
String__Global__push_str(&__sc70, (str){ .ptr = (const uint8_t*)">', or a generic bound", .len = sizeof(">', or a generic bound") - 1 });
__sc70; }));
              }
              if (d.module == self->ast.module) {
                for (uint32_t k = 1U; k < parts.len; k++) {
                  const uint32_t pid = ast__ast__Ast__list(&((*a)), parts)[((size_t)k)];
                  const uint32_t member = typechecker__typechecker__TypeChecker__find_member(self, d.module, d.node, typechecker__typechecker__TypeChecker__name_span(self, pid));
                  if (member != ast__ast__NODE_NONE) {
                    ast__ast__Ast__set_resolution(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), pid, member);
                  }
                }
              }
            }
          }
        } else if (parts.len > 0U) {
          const int32_t b = typechecker__typechecker__builtin_of(self->source, typechecker__typechecker__TypeChecker__name_span(self, ast__ast__Ast__list(&((*a)), parts)[0]));
          if (b >= 0) {
            (result = ast__ast__Ast__builtin(((ast__ast__BuiltinType)b)));
          } else {
            (result = typechecker__typechecker__TYPE_ERROR);
          }
        }
      }
    }
    else if (__sc67 == ast__ast__NodeKind_NODE_SLICE_TYPE) {
      {
        const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type;
        (result = typechecker__typechecker__TypeChecker__prelude_slice_type(self, typechecker__typechecker__TypeChecker__resolve_type(self, it.ty), (it.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT)));
      }
    }
    else if (__sc67 == ast__ast__NodeKind_NODE_TUPLE_TYPE) {
      {
        const ast__ast__NodeList elems = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_literal.elements;
        if (elems.len > 4U) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc71 = String__Global__new();
String__Global__push_str(&__sc71, (str){ .ptr = (const uint8_t*)"tuple arity is limited to 4 elements", .len = sizeof("tuple arity is limited to 4 elements") - 1 });
__sc71; }));
        } else {
          typechecker__typechecker__Tys4 targs = (typechecker__typechecker__Tys4){0};
          for (uint32_t i = 0U; i < elems.len; i++) {
            (targs.t[((size_t)i)] = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*a)), elems)[((size_t)i)]));
          }
          (result = typechecker__typechecker__TypeChecker__prelude_tuple_type(self, ((const uint32_t *)(&targs.t[0])), elems.len));
        }
      }
    }
    else if ((__sc67 == ast__ast__NodeKind_NODE_POINTER_TYPE) || (__sc67 == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
      {
        const ast__ast__IndirectTypeData it = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type;
        ast__ast__TypeKind k = ast__ast__TypeKind_TYPE_REFERENCE;
        if (nk == ast__ast__NodeKind_NODE_POINTER_TYPE) {
          (k = ast__ast__TypeKind_TYPE_POINTER);
        }
        (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = k, .qualifier = ((uint8_t)it.qualifier), .as_data = (ast__ast__TyAs){ .elem = typechecker__typechecker__TypeChecker__resolve_type(self, it.ty) } }));
      }
    }
    else if (__sc67 == ast__ast__NodeKind_NODE_ARRAY_TYPE) {
      {
        const ast__ast__ArrayTypeData at = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_type;
        typechecker__typechecker__TypeChecker__check_expr(self, at.length);
        const uint32_t alen = typechecker__typechecker__TypeChecker__ce_array_len(self, self->ast.module, at.length);
        (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_ARRAY, .as_data = (ast__ast__TyAs){ .arr = (ast__ast__TyArr){ .elem = typechecker__typechecker__TypeChecker__resolve_type(self, at.element), .len = alen } } }));
      }
    }
    else if (__sc67 == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
      {
        (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_FUNCTION, .module = self->ast.module, .as_data = (ast__ast__TyAs){ .decl = id } }));
      }
    }
    else if (__sc67 == ast__ast__NodeKind_NODE_DYN_TYPE) {
      {
        const ast__ast__TypeQualifier q = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type.qualifier;
        if (q == ast__ast__TypeQualifier_TYPE_QUAL_NONE) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc72 = String__Global__new();
String__Global__push_str(&__sc72, (str){ .ptr = (const uint8_t*)"a 'dyn' type must be '&dyn I', '&mut dyn I', or 'Box<dyn I>'", .len = sizeof("a 'dyn' type must be '&dyn I', '&mut dyn I', or 'Box<dyn I>'") - 1 });
__sc72; }));
        } else {
          (result = typechecker__typechecker__TypeChecker__resolve_dyn_node(self, id, q));
        }
      }
    }
    else if (1) {
      {
      }
    }
  }
  ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, result);
  return result;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_intern_dynfn(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const sig, ast__ast__TypeQualifier const qual) {
  const uint32_t mysig = typechecker__typechecker__TypeChecker__lower_type_in(self, m, sig);
  uint32_t i = 1U;
  while (((size_t)i) < Vector__ast__ast__Ty__Global__len(&(*typechecker__typechecker__TypeChecker__cur_ast(self)).type_pool)) {
    const ast__ast__Ty e = (*typechecker__typechecker__TypeChecker__type_at(self, i));
    if ((e.kind == ast__ast__TypeKind_TYPE_DYN) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, e.module))), e.as_data.decl)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE)) {
      const uint32_t esig = typechecker__typechecker__TypeChecker__lower_type_in(self, e.module, e.as_data.decl);
      if ((esig == mysig) || typechecker__typechecker__TypeChecker__fn_compatible(self, esig, mysig)) {
        return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_DYN, .qualifier = ((uint8_t)qual), .module = e.module, .as_data = (ast__ast__TyAs){ .decl = e.as_data.decl } });
      }
    }
    (i = (i + 1U));
  }
  return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_DYN, .qualifier = ((uint8_t)qual), .module = m, .as_data = (ast__ast__TyAs){ .decl = sig } });
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__resolve_dyn_node(typechecker__typechecker__TypeChecker *const self, uint32_t const id, ast__ast__TypeQualifier const qual) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t inner = ast__ast__Ast__at_const(&((*a)), id)->as_data.indirect_type.ty;
  uint32_t result = typechecker__typechecker__TYPE_ERROR;
  if (ast__ast__Ast__at_const(&((*a)), inner)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    bool concrete = (qual != ast__ast__TypeQualifier_TYPE_QUAL_MUT);
    if (!concrete) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc73 = String__Global__new();
String__Global__push_str(&__sc73, (str){ .ptr = (const uint8_t*)"a 'dyn fn' is always called through a shared view; write '&dyn fn(..) ..'", .len = sizeof("a 'dyn fn' is always called through a shared view; write '&dyn fn(..) ..'") - 1 });
__sc73; }));
    }
    const ast__ast__FunctionTypeData ftp = ast__ast__Ast__at_const(&((*a)), inner)->as_data.function_type;
    uint32_t i = 0U;
    while (concrete && (i < ftp.params.len)) {
      (concrete = (typechecker__typechecker__TypeChecker__type_at(self, typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*a)), ftp.params)[((size_t)i)]))->kind != ast__ast__TypeKind_TYPE_GENERIC));
      (i = (i + 1U));
    }
    (i = 0U);
    while (concrete && (i < ftp.returns.len)) {
      const uint32_t rid = ast__ast__Ast__list(&((*a)), ftp.returns)[((size_t)i)];
      const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*a)), rid);
      const uint32_t tn = typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, rid);
      (concrete = (typechecker__typechecker__TypeChecker__type_at(self, typechecker__typechecker__TypeChecker__resolve_type(self, tn))->kind != ast__ast__TypeKind_TYPE_GENERIC));
      (i = (i + 1U));
    }
    if (concrete) {
      (result = typechecker__typechecker__TypeChecker__tc_intern_dynfn(self, self->ast.module, inner, qual));
    } else if (qual != ast__ast__TypeQualifier_TYPE_QUAL_MUT) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc74 = String__Global__new();
String__Global__push_str(&__sc74, (str){ .ptr = (const uint8_t*)"a 'dyn fn' signature cannot name a generic parameter", .len = sizeof("a 'dyn fn' signature cannot name a generic parameter") - 1 });
__sc74; }));
    }
    ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, result);
    return result;
  }
  ast__ast__DefId d = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  if (ast__ast__Ast__at_const(&((*a)), inner)->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
    (d = ast__ast__Ast__resolution_def(&((*a)), inner));
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  if ((d.node == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_INTERFACE)) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc75 = String__Global__new();
String__Global__push_str(&__sc75, (str){ .ptr = (const uint8_t*)"'dyn' requires an interface", .len = sizeof("'dyn' requires an interface") - 1 });
__sc75; }));
  } else if (typechecker__typechecker__TypeChecker__dyn_compatible(self, d, sp)) {
    (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_DYN, .qualifier = ((uint8_t)qual), .module = d.module, .as_data = (ast__ast__TyAs){ .decl = d.node } }));
  }
  ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, result);
  return result;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dyn_method(const typechecker__typechecker__TypeChecker *const self, uint16_t const imod, uint32_t const mnode) {
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, imod);
  const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*ia)), mnode);
  if ((mn->kind != ast__ast__NodeKind_NODE_FUNCTION) || (mn->as_data.function.params.len == 0U)) {
    return false;
  }
  const uint32_t p0 = ast__ast__Ast__list(&((*ia)), mn->as_data.function.params)[0];
  const lexer__token__Span pnm = ast__ast__Ast__at_const(&((*ia)), ast__ast__Ast__at_const(&((*ia)), p0)->as_data.parameter.name)->as_data.name.text;
  return typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, imod), pnm, (str){ (const uint8_t *)"self", sizeof("self") - 1 });
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_mentions_self(const typechecker__typechecker__TypeChecker *const self, uint16_t const imod, uint32_t const tn, ast__ast__DefId const iface) {
  if (tn == ast__ast__NODE_NONE) {
    return false;
  }
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, imod);
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*ia)), tn);
  if (n->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*ia)), tn);
    if ((d.module == iface.module) && (d.node == iface.node)) {
      return true;
    }
    const ast__ast__NodeList args = n->as_data.type_path.args;
    for (uint32_t i = 0U; i < args.len; i++) {
      if (typechecker__typechecker__TypeChecker__tc_mentions_self(self, imod, ast__ast__Ast__list(&((*ia)), args)[((size_t)i)], iface)) {
        return true;
      }
    }
    return false;
  }
  if ((((n->kind == ast__ast__NodeKind_NODE_POINTER_TYPE) || (n->kind == ast__ast__NodeKind_NODE_REFERENCE_TYPE)) || (n->kind == ast__ast__NodeKind_NODE_SLICE_TYPE)) || (n->kind == ast__ast__NodeKind_NODE_DYN_TYPE)) {
    return typechecker__typechecker__TypeChecker__tc_mentions_self(self, imod, n->as_data.indirect_type.ty, iface);
  }
  if (n->kind == ast__ast__NodeKind_NODE_ARRAY_TYPE) {
    return typechecker__typechecker__TypeChecker__tc_mentions_self(self, imod, n->as_data.array_type.element, iface);
  }
  if (n->kind == ast__ast__NodeKind_NODE_TUPLE_TYPE) {
    const ast__ast__NodeList elems = n->as_data.array_literal.elements;
    for (uint32_t i = 0U; i < elems.len; i++) {
      if (typechecker__typechecker__TypeChecker__tc_mentions_self(self, imod, ast__ast__Ast__list(&((*ia)), elems)[((size_t)i)], iface)) {
        return true;
      }
    }
    return false;
  }
  if (n->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
    const ast__ast__FunctionTypeData ft = n->as_data.function_type;
    for (uint32_t i = 0U; i < ft.params.len; i++) {
      if (typechecker__typechecker__TypeChecker__tc_mentions_self(self, imod, ast__ast__Ast__list(&((*ia)), ft.params)[((size_t)i)], iface)) {
        return true;
      }
    }
    for (uint32_t i = 0U; i < ft.returns.len; i++) {
      if (typechecker__typechecker__TypeChecker__tc_mentions_self(self, imod, ast__ast__Ast__list(&((*ia)), ft.returns)[((size_t)i)], iface)) {
        return true;
      }
    }
    return false;
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dyn_compatible(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const iface, lexer__token__Span const at) {
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, iface.module);
  const uint8_t *const isrc = typechecker__typechecker__TypeChecker__mod_src(self, iface.module);
  const ast__ast__InterfaceData idn = ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def;
  str why = (str){ (const uint8_t *)"", sizeof("") - 1 };
  lexer__token__Span mn = (lexer__token__Span){ .start = 0U, .end = 0U };
  if (idn.generics.len != 0U) {
    (why = (str){ (const uint8_t *)"the interface has generic parameters", sizeof("the interface has generic parameters") - 1 });
  } else if (idn.bounds.len != 0U) {
    (why = (str){ (const uint8_t *)"the interface has superinterfaces", sizeof("the interface has superinterfaces") - 1 });
  }
  uint32_t i = 0U;
  while ((str__len(&why) == 0ULL) && (i < idn.items.len)) {
    const uint32_t mid = ast__ast__Ast__list(&((*ia)), idn.items)[((size_t)i)];
    if (typechecker__typechecker__TypeChecker__dyn_method(self, iface.module, mid)) {
      const ast__ast__FunctionData m = ast__ast__Ast__at_const(&((*ia)), mid)->as_data.function;
      (mn = ast__ast__Ast__at_const(&((*ia)), m.name)->as_data.name.text);
      const uint32_t p0 = ast__ast__Ast__list(&((*ia)), m.params)[0];
      const uint32_t st = ast__ast__Ast__at_const(&((*ia)), p0)->as_data.parameter.ty;
      ast__ast__NodeKind sk = ast__ast__NodeKind_NODE_NONE_KIND;
      if (st != ast__ast__NODE_NONE) {
        (sk = ast__ast__Ast__at_const(&((*ia)), st)->kind);
      }
      if (m.generics.len != 0U) {
        (why = (str){ (const uint8_t *)"a method has its own generic parameters", sizeof("a method has its own generic parameters") - 1 });
      } else if ((sk != ast__ast__NodeKind_NODE_REFERENCE_TYPE) && (sk != ast__ast__NodeKind_NODE_POINTER_TYPE)) {
        (why = (str){ (const uint8_t *)"a method takes 'Self' by value", sizeof("a method takes 'Self' by value") - 1 });
      } else if (m.returns.len > 1U) {
        (why = (str){ (const uint8_t *)"a method has multiple return values", sizeof("a method has multiple return values") - 1 });
      }
      uint32_t p = 1U;
      while ((str__len(&why) == 0ULL) && (p < m.params.len)) {
        const uint32_t pid = ast__ast__Ast__list(&((*ia)), m.params)[((size_t)p)];
        if (typechecker__typechecker__TypeChecker__tc_mentions_self(self, iface.module, ast__ast__Ast__at_const(&((*ia)), pid)->as_data.parameter.ty, iface)) {
          (why = (str){ (const uint8_t *)"a method mentions 'Self' outside the receiver", sizeof("a method mentions 'Self' outside the receiver") - 1 });
        }
        (p = (p + 1U));
      }
      uint32_t r = 0U;
      while ((str__len(&why) == 0ULL) && (r < m.returns.len)) {
        const uint32_t rid = ast__ast__Ast__list(&((*ia)), m.returns)[((size_t)r)];
        const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*ia)), rid);
        const uint32_t tn = typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, rid);
        if (typechecker__typechecker__TypeChecker__tc_mentions_self(self, iface.module, tn, iface)) {
          (why = (str){ (const uint8_t *)"a method mentions 'Self' outside the receiver", sizeof("a method mentions 'Self' outside the receiver") - 1 });
        }
        (r = (r + 1U));
      }
    }
    (i = (i + 1U));
  }
  if (str__len(&why) == 0ULL) {
    return true;
  }
  const lexer__token__Span inm = ast__ast__Ast__at_const(&((*ia)), idn.name)->as_data.name.text;
  utils__errors__Errors__emit(&self->errors, at.start, (at.end - at.start), ({ String__Global __sc76 = String__Global__new();
String__Global__push_str(&__sc76, (str){ .ptr = (const uint8_t*)"interface '", .len = sizeof("interface '") - 1 });
String__Global__push_str(&__sc76, utils__errors__span_str(isrc, inm.start, inm.end));
String__Global__push_str(&__sc76, (str){ .ptr = (const uint8_t*)"' is not dyn-compatible: ", .len = sizeof("' is not dyn-compatible: ") - 1 });
String__Global__push_str(&__sc76, why);
__sc76; }));
  if (mn.end > mn.start) {
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc77 = String__Global__new();
String__Global__push_str(&__sc77, (str){ .ptr = (const uint8_t*)"offending method: '", .len = sizeof("offending method: '") - 1 });
String__Global__push_str(&__sc77, utils__errors__span_str(isrc, mn.start, mn.end));
String__Global__push_str(&__sc77, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc77; }));
  }
  return false;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__ext_scopes(typechecker__typechecker__TypeChecker *const self) {
  if (self->n_ext_scope < 0) {
    Vector__u16__Global__clear(&self->ext_scope);
    Vector__u16__Global__push(&self->ext_scope, self->ast.module);
    if (self->package != NULL) {
      Vector__u16__Global closure = module__loader__Package__import_closure(&((*self->package)), self->ast.module);
      for (size_t i = 0ULL; i < Vector__u16__Global__len(&closure); i++) {
        Vector__u16__Global__push(&self->ext_scope, (*({ __auto_type __sc78 = &closure; Vector__u16__Global__index(__sc78, i); })));
      }
      Vector__u16__Global__free(&closure);
    }
    (self->n_ext_scope = ((int32_t)Vector__u16__Global__len(&self->ext_scope)));
  }
  return self->n_ext_scope;
}

static __attribute__((unused)) uint16_t typechecker__typechecker__TypeChecker__ext_scope_at(const typechecker__typechecker__TypeChecker *const self, int32_t const i) {
  return (*({ __auto_type __sc79 = &self->ext_scope; Vector__u16__Global__index(__sc79, ((size_t)i)); }));
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__ensure_ext_items(typechecker__typechecker__TypeChecker *const self, uint16_t const mm) {
  const size_t idx = ((size_t)mm);
  while (Vector__Vector__u32__Global__Global__len(&self->ext_items) <= idx) {
    Vector__Vector__u32__Global__Global__push(&self->ext_items, Vector__u32__Global__new());
  }
  while (Vector__bool__Global__len(&self->ext_items_built) <= idx) {
    Vector__bool__Global__push(&self->ext_items_built, false);
  }
  if ((*({ __auto_type __sc80 = &self->ext_items_built; Vector__bool__Global__index(__sc80, idx); }))) {
    return;
  }
  (*Vector__bool__Global__index_mut(&self->ext_items_built, idx) = true);
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, mm);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_EXTEND) {
      Vector__u32__Global__push(&(*({ __auto_type __sc81 = &self->ext_items; Vector__Vector__u32__Global__Global__index_mut(__sc81, idx); })), iid);
    }
  }
}

static __attribute__((unused)) size_t typechecker__typechecker__TypeChecker__ext_items_len(const typechecker__typechecker__TypeChecker *const self, uint16_t const mm) {
  return Vector__u32__Global__len(&(*({ __auto_type __sc82 = &self->ext_items; Vector__Vector__u32__Global__Global__index(__sc82, ((size_t)mm)); })));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__ext_items_at(const typechecker__typechecker__TypeChecker *const self, uint16_t const mm, size_t const i) {
  return (*({ __auto_type __sc83 = &(*({ __auto_type __sc84 = &self->ext_items; Vector__Vector__u32__Global__Global__index(__sc84, ((size_t)mm)); })); Vector__u32__Global__index(__sc83, i); }));
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__tc_peel_target(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const tg) {
  if (tg.node == ast__ast__NODE_NONE) {
    return tg;
  }
  const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, tg.module))), tg.node));
  if (((dn.kind != ast__ast__NodeKind_NODE_TYPE_ALIAS) || (dn.as_data.type_alias.ty == ast__ast__NODE_NONE)) || (dn.as_data.type_alias.generics.len != 0U)) {
    return tg;
  }
  const ast__ast__Ty ty = (*typechecker__typechecker__TypeChecker__type_at(self, typechecker__typechecker__TypeChecker__named_type_of(self, tg.module, tg.node)));
  if (ty.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    uint32_t bd = ast__ast__NODE_NONE;
    if (self->package != NULL) {
      (bd = module__loader__Package__builtin_decl(&((*self->package)), ty.as_data.builtin));
    }
    if (bd != ast__ast__NODE_NONE) {
      return (ast__ast__DefId){ .module = (*self->package).core_module, .node = bd };
    }
    return tg;
  }
  if ((ty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ty.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    return (ast__ast__DefId){ .module = ty.module, .node = ty.as_data.decl };
  }
  if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ty.as_data.inst));
    return (ast__ast__DefId){ .module = it.module, .node = it.decl };
  }
  return tg;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_member(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const uint8_t *const src = typechecker__typechecker__TypeChecker__mod_src(self, m);
  const ast__ast__Node *const d = ast__ast__Ast__at_const(&((*a)), decl);
  if ((d->kind != ast__ast__NodeKind_NODE_STRUCT) && (d->kind != ast__ast__NodeKind_NODE_ENUM)) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__NodeList members = d->as_data.aggregate.members;
  for (uint32_t i = 0U; i < members.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), members)[((size_t)i)];
    const ast__ast__Node *const mem = ast__ast__Ast__at_const(&((*a)), mid);
    const uint32_t mname = typechecker__typechecker__if_node((mem->kind == ast__ast__NodeKind_NODE_FIELD), mem->as_data.field.name, mem->as_data.variant.name);
    if (typechecker__typechecker__spans_eq2(self->source, name, src, ast__ast__Ast__at_const(&((*a)), mname)->as_data.name.text)) {
      return mid;
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_member_cstr(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, str const name) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const uint8_t *const src = typechecker__typechecker__TypeChecker__mod_src(self, m);
  const ast__ast__Node *const d = ast__ast__Ast__at_const(&((*a)), decl);
  if ((d->kind != ast__ast__NodeKind_NODE_STRUCT) && (d->kind != ast__ast__NodeKind_NODE_ENUM)) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__NodeList members = d->as_data.aggregate.members;
  const size_t nl = str__len(&name);
  for (uint32_t i = 0U; i < members.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), members)[((size_t)i)];
    const ast__ast__Node *const mem = ast__ast__Ast__at_const(&((*a)), mid);
    const uint32_t mname = typechecker__typechecker__if_node((mem->kind == ast__ast__NodeKind_NODE_FIELD), mem->as_data.field.name, mem->as_data.variant.name);
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), mname)->as_data.name.text;
    if ((((size_t)(sp.end - sp.start)) == nl) && (memcmp((src + ((size_t)sp.start)), str__ptr(&name), nl) == 0)) {
      return mid;
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__enclosing_extend(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const method) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_EXTEND) {
      const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
      for (uint32_t j = 0U; j < ms.len; j++) {
        if (ast__ast__Ast__list(&((*a)), ms)[((size_t)j)] == method) {
          return iid;
        }
      }
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__enclosing_trait(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const method) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_INTERFACE) {
      const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.interface_def.items;
      for (uint32_t j = 0U; j < ms.len; j++) {
        if (ast__ast__Ast__list(&((*a)), ms)[((size_t)j)] == method) {
          return iid;
        }
      }
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_method_impl(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name, str const lit) {
  const int32_t ni = typechecker__typechecker__TypeChecker__ext_scopes(self);
  int32_t s = -1;
  while (s < ni) {
    uint16_t mm = m;
    if (s >= 0) {
      (mm = typechecker__typechecker__TypeChecker__ext_scope_at(self, s));
    }
    if ((s >= 0) && (mm == m)) {
      (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      continue;
    }
    typechecker__typechecker__TypeChecker__ensure_ext_items(self, mm);
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, mm);
    const size_t ne = typechecker__typechecker__TypeChecker__ext_items_len(self, mm);
    for (size_t i = 0ULL; i < ne; i++) {
      const uint32_t iid = typechecker__typechecker__TypeChecker__ext_items_at(self, mm, i);
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (it->as_data.extend_def.target_type != ast__ast__NODE_NONE) {
        const ast__ast__DefId tg = typechecker__typechecker__TypeChecker__tc_peel_target(self, ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type));
        if ((tg.module == m) && (tg.node == decl)) {
          const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
          for (uint32_t j = 0U; j < ms.len; j++) {
            const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)j)];
            const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
            if (mn->kind == ast__ast__NodeKind_NODE_FUNCTION) {
              const lexer__token__Span mname = ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text;
              bool hit = false;
              if (str__len(&lit) != 0ULL) {
                (hit = typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, mm), mname, lit));
              } else {
                (hit = typechecker__typechecker__spans_eq2(self->source, name, typechecker__typechecker__TypeChecker__mod_src(self, mm), mname));
              }
              if (hit) {
                module__loader__Package__mark_method_used(&((*self->package)), (ast__ast__DefId){ .module = mm, .node = mid });
                return (ast__ast__DefId){ .module = mm, .node = mid };
              }
            }
          }
        }
      }
    }
    (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_method(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name) {
  return typechecker__typechecker__TypeChecker__find_method_impl(self, m, decl, name, (str){ (const uint8_t *)"", sizeof("") - 1 });
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_method_cstr(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, str const lit) {
  return typechecker__typechecker__TypeChecker__find_method_impl(self, m, decl, lexer__token__Span__empty(), lit);
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_assoc_const(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const decl, lexer__token__Span const name) {
  const int32_t ni = typechecker__typechecker__TypeChecker__ext_scopes(self);
  int32_t s = -1;
  while (s < ni) {
    uint16_t sm = m;
    if (s >= 0) {
      (sm = typechecker__typechecker__TypeChecker__ext_scope_at(self, s));
    }
    if ((s >= 0) && (sm == m)) {
      (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      continue;
    }
    typechecker__typechecker__TypeChecker__ensure_ext_items(self, sm);
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, sm);
    const size_t ne = typechecker__typechecker__TypeChecker__ext_items_len(self, sm);
    for (size_t i = 0ULL; i < ne; i++) {
      const uint32_t iid = typechecker__typechecker__TypeChecker__ext_items_at(self, sm, i);
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (it->as_data.extend_def.generics.len == 0U) {
        const ast__ast__DefId tg = typechecker__typechecker__TypeChecker__tc_peel_target(self, ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type));
        if ((tg.module == m) && (tg.node == decl)) {
          const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
          for (uint32_t j = 0U; j < ms.len; j++) {
            const uint32_t cid = ast__ast__Ast__list(&((*a)), ms)[((size_t)j)];
            const ast__ast__Node *const cn = ast__ast__Ast__at_const(&((*a)), cid);
            if ((cn->kind == ast__ast__NodeKind_NODE_CONST) && (!((sm != self->ast.module) && (!cn->as_data.const_def.is_public)))) {
              if (typechecker__typechecker__spans_eq2(self->source, name, typechecker__typechecker__TypeChecker__mod_src(self, sm), ast__ast__Ast__at_const(&((*a)), cn->as_data.const_def.name)->as_data.name.text)) {
                return (ast__ast__DefId){ .module = sm, .node = cid };
              }
            }
          }
        }
      }
    }
    (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_extend_as(typechecker__typechecker__TypeChecker *const self, uint16_t const tmod, uint32_t const tdecl, ast__ast__DefId const iface, uint16_t *const imod) {
  const int32_t ni = typechecker__typechecker__TypeChecker__ext_scopes(self);
  int32_t s = -1;
  while (s < ni) {
    uint16_t m = tmod;
    if (s >= 0) {
      (m = typechecker__typechecker__TypeChecker__ext_scope_at(self, s));
    }
    if ((s >= 0) && (m == tmod)) {
      (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      continue;
    }
    typechecker__typechecker__TypeChecker__ensure_ext_items(self, m);
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
    const size_t ne = typechecker__typechecker__TypeChecker__ext_items_len(self, m);
    for (size_t i = 0ULL; i < ne; i++) {
      const uint32_t iid = typechecker__typechecker__TypeChecker__ext_items_at(self, m, i);
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if ((it->as_data.extend_def.interface_type != ast__ast__NODE_NONE) && (it->as_data.extend_def.target_type != ast__ast__NODE_NONE)) {
        const ast__ast__DefId tr = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.interface_type);
        const ast__ast__DefId tg = typechecker__typechecker__TypeChecker__tc_peel_target(self, ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type));
        if ((((tr.module == iface.module) && (tr.node == iface.node)) && (tg.module == tmod)) && (tg.node == tdecl)) {
          ((*imod) = m);
          return iid;
        }
      }
    }
    (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_interface_method(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const iface, lexer__token__Span const name, int32_t const depth) {
  if (depth > 8) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__Node *const tn = ast__ast__Ast__at_const(&((*a)), iface);
  if (tn->kind != ast__ast__NodeKind_NODE_INTERFACE) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  const ast__ast__NodeList items = tn->as_data.interface_def.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
    if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && typechecker__typechecker__spans_eq2(self->source, name, typechecker__typechecker__TypeChecker__mod_src(self, m), ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text)) {
      return (ast__ast__DefId){ .module = m, .node = mid };
    }
  }
  const ast__ast__NodeList bounds = tn->as_data.interface_def.bounds;
  for (uint32_t i = 0U; i < bounds.len; i++) {
    const uint32_t bid = ast__ast__Ast__list(&((*a)), bounds)[((size_t)i)];
    const ast__ast__DefId sb = ast__ast__Ast__resolution_def(&((*a)), bid);
    if (sb.node != ast__ast__NODE_NONE) {
      const ast__ast__DefId r = typechecker__typechecker__TypeChecker__find_interface_method(self, sb.module, sb.node, name, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      if (r.node != ast__ast__NODE_NONE) {
        return r;
      }
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_default_method(typechecker__typechecker__TypeChecker *const self, uint16_t const tmod, uint32_t const tdecl, lexer__token__Span const name) {
  const int32_t ni = typechecker__typechecker__TypeChecker__ext_scopes(self);
  int32_t s = -1;
  while (s < ni) {
    uint16_t m = tmod;
    if (s >= 0) {
      (m = typechecker__typechecker__TypeChecker__ext_scope_at(self, s));
    }
    if ((s >= 0) && (m == tmod)) {
      (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      continue;
    }
    typechecker__typechecker__TypeChecker__ensure_ext_items(self, m);
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
    const size_t ne = typechecker__typechecker__TypeChecker__ext_items_len(self, m);
    for (size_t i = 0ULL; i < ne; i++) {
      const uint32_t iid = typechecker__typechecker__TypeChecker__ext_items_at(self, m, i);
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (it->as_data.extend_def.interface_type != ast__ast__NODE_NONE) {
        const ast__ast__DefId tg = typechecker__typechecker__TypeChecker__tc_peel_target(self, ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type));
        if ((tg.module == tmod) && (tg.node == tdecl)) {
          const ast__ast__DefId iff = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.interface_type);
          if (iff.node != ast__ast__NODE_NONE) {
            const ast__ast__DefId mth = typechecker__typechecker__TypeChecker__find_interface_method(self, iff.module, iff.node, name, 0);
            if ((mth.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, mth.module))), mth.node)->as_data.function.body != ast__ast__NODE_NONE)) {
              return mth;
            }
          }
        }
      }
    }
    (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__add_bound_ifaces_full(typechecker__typechecker__TypeChecker *const self, uint16_t const m, ast__ast__NodeList const bounds, typechecker__typechecker__BoundIface *const out, int32_t *const n, int32_t const cap) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  uint32_t i = 0U;
  while ((i < bounds.len) && ((*n) < cap)) {
    const uint32_t bid = ast__ast__Ast__list(&((*a)), bounds)[((size_t)i)];
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), bid);
    if (d.node != ast__ast__NODE_NONE) {
      typechecker__typechecker__BoundIface b = (typechecker__typechecker__BoundIface){ .iface = d, .n = 0U };
      if (ast__ast__Ast__at_const(&((*a)), bid)->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
        const ast__ast__NodeList aids = ast__ast__Ast__at_const(&((*a)), bid)->as_data.type_path.args;
        uint32_t k = 0U;
        while ((k < aids.len) && (b.n < 4U)) {
          (b.args[((size_t)b.n)] = typechecker__typechecker__TypeChecker__lower_type_in(self, m, ast__ast__Ast__list(&((*a)), aids)[((size_t)k)]));
          (b.n = ((uint8_t)((uint32_t)b.n + (uint32_t)1U)));
          (k = (k + 1U));
        }
      }
      const int32_t idx = (*n);
      (out[((size_t)idx)] = b);
      ((*n) = ({ int32_t __sc_r; if (__builtin_add_overflow(idx, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__collect_param_bounds_full(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, typechecker__typechecker__BoundIface *const out, int32_t const cap) {
  int32_t n = 0;
  ast__ast__Ast *const pa = typechecker__typechecker__TypeChecker__mod_ast(self, pmod);
  typechecker__typechecker__TypeChecker__add_bound_ifaces_full(self, pmod, ast__ast__Ast__at_const(&((*pa)), pdecl)->as_data.generic_param.bounds, out, ((int32_t *)(&n)), cap);
  if ((pmod == self->ast.module) && (self->current_fn != ast__ast__NODE_NONE)) {
    const ast__ast__NodeList wc = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), self->current_fn)->as_data.function.where_clause;
    for (uint32_t w = 0U; w < wc.len; w++) {
      const uint32_t wid = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wc)[((size_t)w)];
      const ast__ast__WherePredicateData wp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wid)->as_data.where_predicate;
      if (ast__ast__Ast__resolution(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), wp.ty) == pdecl) {
        typechecker__typechecker__TypeChecker__add_bound_ifaces_full(self, self->ast.module, wp.bounds, out, ((int32_t *)(&n)), cap);
      }
    }
  }
  return n;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__trait_contains_method(const typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const iface, ast__ast__DefId const method, int32_t const depth) {
  if ((iface.node == ast__ast__NODE_NONE) || (depth > 8)) {
    return false;
  }
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, iface.module);
  const ast__ast__Node *const idn = ast__ast__Ast__at_const(&((*ia)), iface.node);
  if (idn->kind != ast__ast__NodeKind_NODE_INTERFACE) {
    return false;
  }
  const ast__ast__NodeList items = idn->as_data.interface_def.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    if ((iface.module == method.module) && (ast__ast__Ast__list(&((*ia)), items)[((size_t)i)] == method.node)) {
      return true;
    }
  }
  const ast__ast__NodeList bounds = idn->as_data.interface_def.bounds;
  for (uint32_t i = 0U; i < bounds.len; i++) {
    if (typechecker__typechecker__TypeChecker__trait_contains_method(self, ast__ast__Ast__resolution_def(&((*ia)), ast__ast__Ast__list(&((*ia)), bounds)[((size_t)i)]), method, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__bound_method_subst(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, ast__ast__DefId const method, ast__ast__DefId *const outp, uint32_t *const outa, int32_t const cap) {
  typechecker__typechecker__BoundArr8 ifaces = (typechecker__typechecker__BoundArr8){0};
  const int32_t ni = typechecker__typechecker__TypeChecker__collect_param_bounds_full(self, pmod, pdecl, ((typechecker__typechecker__BoundIface *)(&ifaces.b[0])), 8);
  for (int32_t i = 0; i < ni; i++) {
    if (typechecker__typechecker__TypeChecker__trait_contains_method(self, ifaces.b[((size_t)i)].iface, method, 0)) {
      ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, ifaces.b[((size_t)i)].iface.module);
      const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*ia)), ifaces.b[((size_t)i)].iface.node)->as_data.interface_def.generics;
      int32_t n = 0;
      uint32_t g = 0U;
      while (((g < gens.len) && (((uint8_t)g) < ifaces.b[((size_t)i)].n)) && (n < cap)) {
        const uint32_t gid = ast__ast__Ast__list(&((*ia)), gens)[((size_t)g)];
        (outp[((size_t)n)] = (ast__ast__DefId){ .module = ifaces.b[((size_t)i)].iface.module, .node = gid });
        (outa[((size_t)n)] = ifaces.b[((size_t)i)].args[((size_t)g)]);
        (n = ({ int32_t __sc_r; if (__builtin_add_overflow(n, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (g = (g + 1U));
      }
      return n;
    }
  }
  return 0;
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__find_bound_method(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, lexer__token__Span const name, ast__ast__DefId *const iface) {
  typechecker__typechecker__BoundArr8 ifaces = (typechecker__typechecker__BoundArr8){0};
  const int32_t ni = typechecker__typechecker__TypeChecker__collect_param_bounds_full(self, pmod, pdecl, ((typechecker__typechecker__BoundIface *)(&ifaces.b[0])), 8);
  for (int32_t b = 0; b < ni; b++) {
    const ast__ast__DefId id = ifaces.b[((size_t)b)].iface;
    const ast__ast__DefId m = typechecker__typechecker__TypeChecker__find_interface_method(self, id.module, id.node, name, 0);
    if (m.node != ast__ast__NODE_NONE) {
      if (iface != NULL) {
        ((*iface) = id);
      }
      return m;
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__interface_declares_cstr(const typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const iface, str const m, int32_t const depth) {
  if ((depth > 8) || (iface.node == ast__ast__NODE_NONE)) {
    return false;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, iface.module);
  const ast__ast__Node *const idn = ast__ast__Ast__at_const(&((*a)), iface.node);
  if (idn->kind != ast__ast__NodeKind_NODE_INTERFACE) {
    return false;
  }
  const ast__ast__NodeList items = idn->as_data.interface_def.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
    if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, iface.module), ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text, m)) {
      return true;
    }
  }
  const ast__ast__NodeList bounds = idn->as_data.interface_def.bounds;
  for (uint32_t i = 0U; i < bounds.len; i++) {
    if (typechecker__typechecker__TypeChecker__interface_declares_cstr(self, ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__list(&((*a)), bounds)[((size_t)i)]), m, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_param_bound_provides(typechecker__typechecker__TypeChecker *const self, uint16_t const pmod, uint32_t const pdecl, str const m) {
  typechecker__typechecker__BoundArr8 ifaces = (typechecker__typechecker__BoundArr8){0};
  const int32_t ni = typechecker__typechecker__TypeChecker__collect_param_bounds_full(self, pmod, pdecl, ((typechecker__typechecker__BoundIface *)(&ifaces.b[0])), 8);
  for (int32_t b = 0; b < ni; b++) {
    if (typechecker__typechecker__TypeChecker__interface_declares_cstr(self, ifaces.b[((size_t)b)].iface, m, 0)) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__type_satisfies(typechecker__typechecker__TypeChecker *const self, uint32_t const ty, ast__ast__DefId const iface, int32_t const depth) {
  if (((ty == ast__ast__TYPE_NONE) || (ty == typechecker__typechecker__TYPE_ERROR)) || (depth > typechecker__typechecker__BOUND_MAX_DEPTH)) {
    return true;
  }
  const ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, ty));
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    return true;
  }
  if (y.kind == ast__ast__TypeKind_TYPE_DYN) {
    return ((y.module == iface.module) && (y.as_data.decl == iface.node));
  }
  uint16_t tmod = 0U;
  uint32_t tdecl = ast__ast__NODE_NONE;
  typechecker__typechecker__Tys4 iargs = (typechecker__typechecker__Tys4){0};
  int32_t in2 = 0;
  if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    (tmod = y.module);
    (tdecl = y.as_data.decl);
  } else if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance inst = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), y.as_data.inst));
    (tmod = inst.module);
    (tdecl = inst.decl);
    uint8_t k = 0U;
    while ((k < inst.n) && (in2 < 4)) {
      (iargs.t[((size_t)in2)] = inst.args[((size_t)k)]);
      (in2 = ({ int32_t __sc_r; if (__builtin_add_overflow(in2, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
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
  uint16_t imod = 0U;
  const uint32_t extnode = typechecker__typechecker__TypeChecker__find_extend_as(self, tmod, tdecl, iface, ((uint16_t *)(&imod)));
  if (extnode == ast__ast__NODE_NONE) {
    return false;
  }
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, imod);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*ia)), extnode)->as_data.extend_def.generics;
  uint32_t g = 0U;
  while ((g < gens.len) && (((int32_t)g) < in2)) {
    const uint32_t gid = ast__ast__Ast__list(&((*ia)), gens)[((size_t)g)];
    const ast__ast__NodeList gb = ast__ast__Ast__at_const(&((*ia)), gid)->as_data.generic_param.bounds;
    for (uint32_t b = 0U; b < gb.len; b++) {
      const ast__ast__DefId gbi = ast__ast__Ast__resolution_def(&((*ia)), ast__ast__Ast__list(&((*ia)), gb)[((size_t)b)]);
      if ((gbi.node != ast__ast__NODE_NONE) && (!typechecker__typechecker__TypeChecker__type_satisfies(self, iargs.t[((size_t)g)], gbi, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })))) {
        return false;
      }
    }
    (g = (g + 1U));
  }
  return true;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_free_iface(const typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const tr) {
  if (tr.node == ast__ast__NODE_NONE) {
    return false;
  }
  const ast__ast__Node *const trn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, tr.module))), tr.node);
  return ((trn->kind == ast__ast__NodeKind_NODE_INTERFACE) && typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, tr.module), ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, tr.module))), trn->as_data.interface_def.name)->as_data.name.text, (str){ (const uint8_t *)"Free", sizeof("Free") - 1 }));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_param_has_free_bound(const typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const gp) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__NodeList bs = ast__ast__Ast__at_const(&((*a)), gp)->as_data.generic_param.bounds;
  for (uint32_t i = 0U; i < bs.len; i++) {
    const ast__ast__DefId bd = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__list(&((*a)), bs)[((size_t)i)]);
    if (typechecker__typechecker__TypeChecker__is_free_iface(self, bd)) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_type_is_free(typechecker__typechecker__TypeChecker *const self, uint32_t const ty) {
  if (ty == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty y0 = (*typechecker__typechecker__TypeChecker__type_at(self, ty));
  if (y0.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
    return typechecker__typechecker__TypeChecker__fn_owns(self, ty);
  }
  if (y0.kind == ast__ast__TypeKind_TYPE_DYN) {
    return (y0.qualifier == 0U);
  }
  if (y0.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const uint32_t fb = typechecker__typechecker__TypeChecker__generic_fn_bound(self, y0.module, y0.as_data.decl);
    if (fb != ast__ast__NODE_NONE) {
      return ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, y0.module))), fb)->as_data.function_type.is_move;
    }
  }
  uint16_t om = 0U;
  uint32_t od = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (!typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, ty), ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    return false;
  }
  const int32_t ni = typechecker__typechecker__TypeChecker__ext_scopes(self);
  int32_t s = -1;
  while (s < ni) {
    uint16_t m = om;
    if (s >= 0) {
      (m = typechecker__typechecker__TypeChecker__ext_scope_at(self, s));
    }
    if ((s >= 0) && (m == om)) {
      (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      continue;
    }
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (((it->kind == ast__ast__NodeKind_NODE_EXTEND) && (it->as_data.extend_def.interface_type != ast__ast__NODE_NONE)) && (it->as_data.extend_def.target_type != ast__ast__NODE_NONE)) {
        const ast__ast__DefId tg = typechecker__typechecker__TypeChecker__tc_peel_target(self, ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type));
        if ((tg.module == om) && (tg.node == od)) {
          const ast__ast__DefId tr = ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.interface_type);
          if (typechecker__typechecker__TypeChecker__is_free_iface(self, tr)) {
            const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.generics;
            uint32_t k = 0U;
            while ((k < gens.len) && (((int32_t)k) < gn)) {
              const uint32_t gid = ast__ast__Ast__list(&((*a)), gens)[((size_t)k)];
              if (typechecker__typechecker__TypeChecker__tc_param_has_free_bound(self, m, gid) && (!typechecker__typechecker__TypeChecker__tc_type_is_free(self, ga.t[((size_t)k)]))) {
                return false;
              }
              (k = (k + 1U));
            }
            return true;
          }
        }
      }
    }
    (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__method_extend_bounds_hold(typechecker__typechecker__TypeChecker *const self, uint32_t const target, ast__ast__DefId const md) {
  if ((target == ast__ast__TYPE_NONE) || (md.node == ast__ast__NODE_NONE)) {
    return true;
  }
  const uint32_t extnode = typechecker__typechecker__TypeChecker__enclosing_extend(self, md.module, md.node);
  if (extnode == ast__ast__NODE_NONE) {
    return true;
  }
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*ia)), extnode)->as_data.extend_def.generics;
  if (gens.len == 0U) {
    return true;
  }
  uint16_t tm = 0U;
  uint32_t td = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (!typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, target), ((uint16_t *)(&tm)), ((uint32_t *)(&td)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    return true;
  }
  for (uint32_t g = 0U; g < gens.len; g++) {
    if (((int32_t)g) >= gn) {
      return false;
    }
    const uint32_t gid = ast__ast__Ast__list(&((*ia)), gens)[((size_t)g)];
    const ast__ast__NodeList gb = ast__ast__Ast__at_const(&((*ia)), gid)->as_data.generic_param.bounds;
    for (uint32_t b = 0U; b < gb.len; b++) {
      const ast__ast__DefId bi = ast__ast__Ast__resolution_def(&((*ia)), ast__ast__Ast__list(&((*ia)), gb)[((size_t)b)]);
      if ((bi.node != ast__ast__NODE_NONE) && (!typechecker__typechecker__TypeChecker__type_satisfies(self, ga.t[((size_t)g)], bi, 0))) {
        return false;
      }
    }
  }
  return true;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__err_method_extend_bounds(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const at, uint32_t const target, ast__ast__DefId const md) {
  typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
  typechecker__typechecker__TypeChecker__render_type(self, typechecker__typechecker__TypeChecker__strip(self, target), ((char *)(&ty.b[0])), 96ULL);
  ast__ast__Ast *const ma = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
  const lexer__token__Span mn = ast__ast__Ast__at_const(&((*ma)), ast__ast__Ast__at_const(&((*ma)), md.node)->as_data.function.name)->as_data.name.text;
  utils__errors__Errors__emit(&self->errors, at.start, (at.end - at.start), ({ String__Global __sc85 = String__Global__new();
String__Global__push_str(&__sc85, (str){ .ptr = (const uint8_t*)"cannot call '", .len = sizeof("cannot call '") - 1 });
String__Global__push_str(&__sc85, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc85, (str){ .ptr = (const uint8_t*)"::", .len = sizeof("::") - 1 });
String__Global__push_str(&__sc85, utils__errors__span_str(typechecker__typechecker__TypeChecker__mod_src(self, md.module), mn.start, mn.end));
String__Global__push_str(&__sc85, (str){ .ptr = (const uint8_t*)"': unsatisfied interface bounds", .len = sizeof("': unsatisfied interface bounds") - 1 });
__sc85; }));
  utils__errors__Errors__note(&self->errors, ({ String__Global __sc86 = String__Global__new();
String__Global__push_str(&__sc86, (str){ .ptr = (const uint8_t*)"these bounds come from the extend block that defines the method", .len = sizeof("these bounds come from the extend block that defines the method") - 1 });
__sc86; }));
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__mark_format_helpers(typechecker__typechecker__TypeChecker *const self) {
  if (self->package == NULL) {
    return;
  }
  const module__loader__LookupHit sh = module__loader__Package__prelude_lookup(&((*self->package)), (str){ (const uint8_t *)"String", sizeof("String") - 1 }, true);
  if (sh.node == ast__ast__NODE_NONE) {
    return;
  }
  typechecker__typechecker__Names14 names = (typechecker__typechecker__Names14){0};
  (names.n[0] = ((const char *)({ __auto_type __sc87 = (str){ (const uint8_t *)"new", sizeof("new") - 1 }; str__ptr(&__sc87); })));
  (names.n[1] = ((const char *)({ __auto_type __sc88 = (str){ (const uint8_t *)"print", sizeof("print") - 1 }; str__ptr(&__sc88); })));
  (names.n[2] = ((const char *)({ __auto_type __sc89 = (str){ (const uint8_t *)"eprint", sizeof("eprint") - 1 }; str__ptr(&__sc89); })));
  (names.n[3] = ((const char *)({ __auto_type __sc90 = (str){ (const uint8_t *)"push_i64", sizeof("push_i64") - 1 }; str__ptr(&__sc90); })));
  (names.n[4] = ((const char *)({ __auto_type __sc91 = (str){ (const uint8_t *)"push_u64", sizeof("push_u64") - 1 }; str__ptr(&__sc91); })));
  (names.n[5] = ((const char *)({ __auto_type __sc92 = (str){ (const uint8_t *)"push_f64", sizeof("push_f64") - 1 }; str__ptr(&__sc92); })));
  (names.n[6] = ((const char *)({ __auto_type __sc93 = (str){ (const uint8_t *)"push_hex_i64", sizeof("push_hex_i64") - 1 }; str__ptr(&__sc93); })));
  (names.n[7] = ((const char *)({ __auto_type __sc94 = (str){ (const uint8_t *)"push_hex", sizeof("push_hex") - 1 }; str__ptr(&__sc94); })));
  (names.n[8] = ((const char *)({ __auto_type __sc95 = (str){ (const uint8_t *)"push_byte", sizeof("push_byte") - 1 }; str__ptr(&__sc95); })));
  (names.n[9] = ((const char *)({ __auto_type __sc96 = (str){ (const uint8_t *)"push_str", sizeof("push_str") - 1 }; str__ptr(&__sc96); })));
  (names.n[10] = ((const char *)({ __auto_type __sc97 = (str){ (const uint8_t *)"as_str", sizeof("as_str") - 1 }; str__ptr(&__sc97); })));
  (names.n[11] = ((const char *)({ __auto_type __sc98 = (str){ (const uint8_t *)"push_bin", sizeof("push_bin") - 1 }; str__ptr(&__sc98); })));
  (names.n[12] = ((const char *)({ __auto_type __sc99 = (str){ (const uint8_t *)"push_f64_prec", sizeof("push_f64_prec") - 1 }; str__ptr(&__sc99); })));
  (names.n[13] = ((const char *)({ __auto_type __sc100 = (str){ (const uint8_t *)"push_padded", sizeof("push_padded") - 1 }; str__ptr(&__sc100); })));
  for (int32_t i = 0; i < 14; i++) {
    typechecker__typechecker__TypeChecker__find_method_cstr(self, sh.mid, sh.node, utils__errors__cstr(names.n[i]));
  }
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__resolve_conversion(typechecker__typechecker__TypeChecker *const self, lexer__token__Span const name, uint32_t const want) {
  const bool is_into = typechecker__typechecker__span_is(self->source, name, (str){ (const uint8_t *)"into", sizeof("into") - 1 });
  const bool is_try = typechecker__typechecker__span_is(self->source, name, (str){ (const uint8_t *)"try_into", sizeof("try_into") - 1 });
  if (((!is_into) && (!is_try)) || (want == ast__ast__TYPE_NONE)) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  uint16_t m = 0U;
  uint32_t decl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (!typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, want), ((uint16_t *)(&m)), ((uint32_t *)(&decl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  if (is_try) {
    if (gn < 1) {
      return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    }
    if (!typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, ga.t[0]), ((uint16_t *)(&m)), ((uint32_t *)(&decl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
      return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    }
  }
  str lit = (str){ (const uint8_t *)"from", sizeof("from") - 1 };
  if (is_try) {
    (lit = (str){ (const uint8_t *)"try_from", sizeof("try_from") - 1 });
  }
  return typechecker__typechecker__TypeChecker__find_method_cstr(self, m, decl, lit);
}

static __attribute__((unused)) ast__ast__DefId typechecker__typechecker__TypeChecker__tc_find_from_for(typechecker__typechecker__TypeChecker *const self, uint32_t const target, uint32_t const src) {
  const ast__ast__Ty ty = (*typechecker__typechecker__TypeChecker__type_at(self, typechecker__typechecker__TypeChecker__strip(self, target)));
  if ((ty.kind != ast__ast__TypeKind_TYPE_STRUCT) && (ty.kind != ast__ast__TypeKind_TYPE_ENUM)) {
    return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  }
  const uint16_t m = ty.module;
  const uint32_t decl = ty.as_data.decl;
  const int32_t ni = typechecker__typechecker__TypeChecker__ext_scopes(self);
  int32_t s = -1;
  while (s < ni) {
    uint16_t mm = m;
    if (s >= 0) {
      (mm = typechecker__typechecker__TypeChecker__ext_scope_at(self, s));
    }
    if ((s >= 0) && (mm == m)) {
      (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      continue;
    }
    ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, mm);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const ast__ast__Node *const it = ast__ast__Ast__at_const(&((*a)), iid);
      if (((it->kind == ast__ast__NodeKind_NODE_EXTEND) && (it->as_data.extend_def.target_type != ast__ast__NODE_NONE)) && (it->as_data.extend_def.generics.len == 0U)) {
        const ast__ast__DefId tg = typechecker__typechecker__TypeChecker__tc_peel_target(self, ast__ast__Ast__resolution_def(&((*a)), it->as_data.extend_def.target_type));
        if ((tg.module == m) && (tg.node == decl)) {
          const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
          for (uint32_t j = 0U; j < ms.len; j++) {
            const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)j)];
            const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*a)), mid);
            if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, mm), ast__ast__Ast__at_const(&((*a)), mn->as_data.function.name)->as_data.name.text, (str){ (const uint8_t *)"from", sizeof("from") - 1 })) {
              const ast__ast__NodeList ps = mn->as_data.function.params;
              if ((ps.len == 1U) && (typechecker__typechecker__TypeChecker__decl_type_in(self, mm, ast__ast__Ast__list(&((*a)), ps)[0]) == src)) {
                module__loader__Package__mark_method_used(&((*self->package)), (ast__ast__DefId){ .module = mm, .node = mid });
                return (ast__ast__DefId){ .module = mm, .node = mid };
              }
            }
          }
        }
      }
    }
    (s = ({ int32_t __sc_r; if (__builtin_add_overflow(s, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__dyn_coerce(typechecker__typechecker__TypeChecker *const self, uint32_t const node, uint32_t const src, uint32_t const dyn_ty) {
  const ast__ast__Ty dy = (*typechecker__typechecker__TypeChecker__type_at(self, dyn_ty));
  const ast__ast__DefId iface = (ast__ast__DefId){ .module = dy.module, .node = dy.as_data.decl };
  const ast__ast__Ty sy = (*typechecker__typechecker__TypeChecker__type_at(self, src));
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node)->span;
  if (sy.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc101 = String__Global__new();
String__Global__push_str(&__sc101, (str){ .ptr = (const uint8_t*)"cannot erase a generic type parameter to 'dyn'", .len = sizeof("cannot erase a generic type parameter to 'dyn'") - 1 });
__sc101; }));
    return true;
  }
  if (!typechecker__typechecker__TypeChecker__type_satisfies(self, src, iface, 0)) {
    return false;
  }
  uint16_t tmod = 0U;
  uint32_t tdecl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (!typechecker__typechecker__TypeChecker__aggregate_of(self, src, ((uint16_t *)(&tmod)), ((uint32_t *)(&tdecl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    if (((sy.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) && (module__loader__Package__builtin_decl(&((*self->package)), sy.as_data.builtin) != ast__ast__NODE_NONE)) {
      (tmod = (*self->package).core_module);
      (tdecl = module__loader__Package__builtin_decl(&((*self->package)), sy.as_data.builtin));
    } else {
      return false;
    }
  }
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, iface.module);
  const uint8_t *const isrc = typechecker__typechecker__TypeChecker__mod_src(self, iface.module);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*ia)), items)[((size_t)i)];
    if (typechecker__typechecker__TypeChecker__dyn_method(self, iface.module, mid)) {
      const lexer__token__Span mn = ast__ast__Ast__at_const(&((*ia)), ast__ast__Ast__at_const(&((*ia)), mid)->as_data.function.name)->as_data.name.text;
      typechecker__typechecker__Buf96 nmb = (typechecker__typechecker__Buf96){0};
      snprintf(((char *)(&nmb.b[0])), 96ULL, ((const char *)({ __auto_type __sc102 = (str){ (const uint8_t *)"%.*s", sizeof("%.*s") - 1 }; str__ptr(&__sc102); })), ((int32_t)(mn.end - mn.start)), typechecker__typechecker__src_at(isrc, mn.start));
      if (typechecker__typechecker__TypeChecker__find_method_cstr(self, tmod, tdecl, utils__errors__cstr(((const char *)(&nmb.b[0])))).node != ast__ast__NODE_NONE) {
        continue;
      }
      uint16_t emod = 0U;
      if ((ast__ast__Ast__at_const(&((*ia)), mid)->as_data.function.body != ast__ast__NODE_NONE) && (typechecker__typechecker__TypeChecker__find_extend_as(self, tmod, tdecl, iface, ((uint16_t *)(&emod))) != ast__ast__NODE_NONE)) {
        continue;
      }
      typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
      typechecker__typechecker__TypeChecker__render_type(self, src, ((char *)(&tn.b[0])), 96ULL);
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc103 = String__Global__new();
String__Global__push_str(&__sc103, (str){ .ptr = (const uint8_t*)"cannot erase '", .len = sizeof("cannot erase '") - 1 });
String__Global__push_str(&__sc103, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc103, (str){ .ptr = (const uint8_t*)"' to 'dyn': method '", .len = sizeof("' to 'dyn': method '") - 1 });
String__Global__push_str(&__sc103, utils__errors__cstr(((const char *)(&nmb.b[0]))));
String__Global__push_str(&__sc103, (str){ .ptr = (const uint8_t*)"' has no emittable implementation", .len = sizeof("' has no emittable implementation") - 1 });
__sc103; }));
      utils__errors__Errors__note(&self->errors, ({ String__Global __sc104 = String__Global__new();
String__Global__push_str(&__sc104, (str){ .ptr = (const uint8_t*)"implement the method in an 'extend .. as ..' block or give it a default body", .len = sizeof("implement the method in an 'extend .. as ..' block or give it a default body") - 1 });
__sc104; }));
      return true;
    }
  }
  ast__ast__Ast__add_dyn_use(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, src, dyn_ty);
  return true;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__compatible(typechecker__typechecker__TypeChecker *const self, uint32_t const expected, uint32_t const node) {
  const uint32_t actual = ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node);
  if (((expected == ast__ast__TYPE_NONE) || (actual == ast__ast__TYPE_NONE)) || (expected == actual)) {
    return true;
  }
  const ast__ast__Ty ex = (*typechecker__typechecker__TypeChecker__type_at(self, expected));
  const ast__ast__Ty ac = (*typechecker__typechecker__TypeChecker__type_at(self, actual));
  if (ac.kind == ast__ast__TypeKind_TYPE_NEVER) {
    return true;
  }
  ast__ast__Ty acp = ac;
  if ((ac.kind == ast__ast__TypeKind_TYPE_REFERENCE) && (ex.kind == ast__ast__TypeKind_TYPE_POINTER)) {
    (acp.kind = ast__ast__TypeKind_TYPE_POINTER);
    if (acp.qualifier != 2U) {
      (acp.qualifier = 1U);
    }
  }
  if (((((ex.kind == ast__ast__TypeKind_TYPE_REFERENCE) && (ac.kind == ast__ast__TypeKind_TYPE_REFERENCE)) && (ex.as_data.elem == ac.as_data.elem)) && (ex.qualifier != 2U)) && (ac.qualifier == 2U)) {
    return true;
  }
  if ((((ex.kind == ast__ast__TypeKind_TYPE_POINTER) && (acp.kind == ast__ast__TypeKind_TYPE_POINTER)) && ((ex.as_data.elem == acp.as_data.elem) || (ex.as_data.elem == 18U))) && ((ex.qualifier == 1U) || (acp.qualifier != 1U))) {
    return true;
  }
  if ((ex.kind == ast__ast__TypeKind_TYPE_FUNCTION) && (ac.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
    return typechecker__typechecker__TypeChecker__fn_compatible(self, expected, actual);
  }
  if ((ex.kind == ast__ast__TypeKind_TYPE_ARRAY) && (ac.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    if (((ex.as_data.arr.len != 0U) && (ac.as_data.arr.len != 0U)) && (ex.as_data.arr.len != ac.as_data.arr.len)) {
      return false;
    }
    if (ex.as_data.arr.elem == ac.as_data.arr.elem) {
      return true;
    }
    const ast__ast__TypeKind ee = typechecker__typechecker__TypeChecker__type_at(self, ex.as_data.arr.elem)->kind;
    const ast__ast__TypeKind ae = typechecker__typechecker__TypeChecker__type_at(self, ac.as_data.arr.elem)->kind;
    return (((ee == ast__ast__TypeKind_TYPE_FUNCTION) && (ae == ast__ast__TypeKind_TYPE_FUNCTION)) && typechecker__typechecker__TypeChecker__fn_compatible(self, ex.as_data.arr.elem, ac.as_data.arr.elem));
  }
  if (ac.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    uint32_t selem = ast__ast__TYPE_NONE;
    const int32_t sk = typechecker__typechecker__TypeChecker__slice_kind(self, expected, ((uint32_t *)(&selem)));
    if (((sk != 0) && (selem == ac.as_data.arr.elem)) && ((sk == 1) || typechecker__typechecker__TypeChecker__is_assignable(self, node))) {
      ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, expected);
      return true;
    }
  }
  if (ex.kind == ast__ast__TypeKind_TYPE_DYN) {
    const uint32_t exsig = typechecker__typechecker__TypeChecker__tc_dyn_fn_sig(self, (&ex));
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node)->span;
    if (ac.kind == ast__ast__TypeKind_TYPE_DYN) {
      return (typechecker__typechecker__TypeChecker__tc_dyn_same(self, (&ex), (&ac)) && ((ex.qualifier == ac.qualifier) || ((ex.qualifier == 1U) && (ac.qualifier == 2U))));
    }
    if ((ex.qualifier != 0U) && (ac.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
      const ast__ast__Ty rel = (*typechecker__typechecker__TypeChecker__type_at(self, ac.as_data.elem));
      if (rel.kind == ast__ast__TypeKind_TYPE_DYN) {
        if ((rel.qualifier != 0U) || (!typechecker__typechecker__TypeChecker__tc_dyn_same(self, (&ex), (&rel)))) {
          return false;
        }
        ast__ast__Ast__add_dyn_use(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, ast__ast__TYPE_NONE, expected);
        return true;
      }
      if (exsig != ast__ast__TYPE_NONE) {
        if ((rel.kind != ast__ast__TypeKind_TYPE_FUNCTION) || (!typechecker__typechecker__TypeChecker__dynfn_sig_ok(self, exsig, ac.as_data.elem))) {
          return false;
        }
        ast__ast__Ast__add_dyn_use(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, ac.as_data.elem, expected);
        return true;
      }
      if ((ex.qualifier == 2U) && (ac.qualifier != 2U)) {
        return false;
      }
      return typechecker__typechecker__TypeChecker__dyn_coerce(self, node, ac.as_data.elem, expected);
    }
    if ((exsig != ast__ast__TYPE_NONE) && (ac.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
      if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ac.module))), ac.as_data.decl)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc105 = String__Global__new();
String__Global__push_str(&__sc105, (str){ .ptr = (const uint8_t*)"a runtime 'fn(..)' pointer cannot erase to 'dyn fn'; wrap it in a closure", .len = sizeof("a runtime 'fn(..)' pointer cannot erase to 'dyn fn'; wrap it in a closure") - 1 });
__sc105; }));
        return true;
      }
      if (!typechecker__typechecker__TypeChecker__dynfn_sig_ok(self, exsig, actual)) {
        return false;
      }
      if ((ex.qualifier != 0U) && typechecker__typechecker__TypeChecker__fn_is_capturing(self, actual)) {
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc106 = String__Global__new();
String__Global__push_str(&__sc106, (str){ .ptr = (const uint8_t*)"a capturing closure must be borrowed to view it as '&dyn fn': write '&f'", .len = sizeof("a capturing closure must be borrowed to view it as '&dyn fn': write '&f'") - 1 });
__sc106; }));
        return true;
      }
      ast__ast__Ast__add_dyn_use(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, actual, expected);
      return true;
    }
    if (((ex.qualifier == 0U) && (ac.kind == ast__ast__TypeKind_TYPE_INSTANCE)) && (exsig == ast__ast__TYPE_NONE)) {
      uint32_t inner = ast__ast__TYPE_NONE;
      bool galloc = false;
      if (typechecker__typechecker__TypeChecker__tc_box_of(self, (&ac), ((uint32_t *)(&inner)), ((bool *)(&galloc)))) {
        if (!galloc) {
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc107 = String__Global__new();
String__Global__push_str(&__sc107, (str){ .ptr = (const uint8_t*)"only a default-allocated 'Box<T>' can be erased to 'Box<dyn I>'", .len = sizeof("only a default-allocated 'Box<T>' can be erased to 'Box<dyn I>'") - 1 });
__sc107; }));
          return true;
        }
        return typechecker__typechecker__TypeChecker__dyn_coerce(self, node, inner, expected);
      }
    }
    return false;
  }
  if (((ex.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (ac.kind == ast__ast__TypeKind_TYPE_BUILTIN)) && typechecker__typechecker__bt_widens(ac.as_data.builtin, ex.as_data.builtin)) {
    return true;
  }
  uint32_t vid = node;
  const ast__ast__Node *const v0 = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node);
  if ((v0->kind == ast__ast__NodeKind_NODE_UNARY) && (v0->as_data.unary.op == lexer__token_type__TokenType_Minus)) {
    (vid = v0->as_data.unary.operand);
  }
  const ast__ast__Node *const v = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), vid);
  if (v->kind != ast__ast__NodeKind_NODE_LITERAL) {
    return false;
  }
  const ast__ast__Ty et = (*typechecker__typechecker__TypeChecker__type_at(self, expected));
  const lexer__token_type__TokenType tt = v->as_data.literal.token_type;
  if (tt == lexer__token_type__TokenType_IntegerLiteral) {
    if (typechecker__typechecker__TypeChecker__tc_literal_pinned(self, vid)) {
      return false;
    }
    if ((et.kind != ast__ast__TypeKind_TYPE_BUILTIN) || (!((typechecker__typechecker__bt_is_int(et.as_data.builtin) || typechecker__typechecker__bt_is_float(et.as_data.builtin)) || typechecker__typechecker__bt_is_complex(et.as_data.builtin)))) {
      return false;
    }
    if (typechecker__typechecker__bt_is_int(et.as_data.builtin)) {
      uint64_t mag = 0ULL;
      const bool neg = (vid != node);
      const bool got = typechecker__typechecker__TypeChecker__lit_mag(self, vid, ((uint64_t *)(&mag)));
      if (got && (!typechecker__typechecker__tc_lit_in_range(et.as_data.builtin, mag, neg))) {
        typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, expected, ((char *)(&tn.b[0])), 96ULL);
        const lexer__token__Span vsp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node)->span;
        utils__errors__Errors__emit(&self->errors, vsp.start, (vsp.end - vsp.start), ({ String__Global __sc108 = String__Global__new();
String__Global__push_str(&__sc108, (str){ .ptr = (const uint8_t*)"integer literal is out of range for '", .len = sizeof("integer literal is out of range for '") - 1 });
String__Global__push_str(&__sc108, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc108, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc108; }));
        return true;
      }
      if (!neg) {
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, expected);
      }
    }
    return true;
  }
  if (tt == lexer__token_type__TokenType_CharacterLiteral) {
    return ((et.kind == ast__ast__TypeKind_TYPE_BUILTIN) && typechecker__typechecker__bt_is_int(et.as_data.builtin));
  }
  if (tt == lexer__token_type__TokenType_FloatLiteral) {
    if (typechecker__typechecker__TypeChecker__tc_literal_pinned(self, vid)) {
      return false;
    }
    return ((et.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (typechecker__typechecker__bt_is_float(et.as_data.builtin) || typechecker__typechecker__bt_is_complex(et.as_data.builtin)));
  }
  if ((tt == lexer__token_type__TokenType_StringLiteral) || (tt == lexer__token_type__TokenType_RawStringLiteral)) {
    if ((et.kind != ast__ast__TypeKind_TYPE_POINTER) || (et.qualifier != 1U)) {
      return false;
    }
    const ast__ast__Ty *const pe = typechecker__typechecker__TypeChecker__type_at(self, et.as_data.elem);
    if ((pe->kind != ast__ast__TypeKind_TYPE_BUILTIN) || ((pe->as_data.builtin != ast__ast__BuiltinType_BT_CHAR) && (pe->as_data.builtin != ast__ast__BuiltinType_BT_U8))) {
      return false;
    }
    ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node, expected);
    return true;
  }
  if (tt == lexer__token_type__TokenType_Null) {
    return ((et.kind == ast__ast__TypeKind_TYPE_POINTER) || (et.kind == ast__ast__TypeKind_TYPE_REFERENCE));
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__return_list_is_explicit_void(typechecker__typechecker__TypeChecker *const self, ast__ast__NodeList const rets) {
  if (rets.len != 1U) {
    return false;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), rets)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), r0);
  const uint32_t tn = typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0);
  return typechecker__typechecker__TypeChecker__is_void_type(self, typechecker__typechecker__TypeChecker__resolve_type(self, tn));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__range_type(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const start, uint32_t const end) {
  const ast__ast__PatternRangeData n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.pattern_range;
  const bool has_start = (n.start != ast__ast__NODE_NONE);
  const bool has_end = (n.end != ast__ast__NODE_NONE);
  const bool start_ok = (((!has_start) || (start == ast__ast__TYPE_NONE)) || typechecker__typechecker__TypeChecker__is_int(self, start));
  const bool end_ok = (((!has_end) || (end == ast__ast__TYPE_NONE)) || typechecker__typechecker__TypeChecker__is_int(self, end));
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
  if ((!start_ok) || (!end_ok)) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc109 = String__Global__new();
String__Global__push_str(&__sc109, (str){ .ptr = (const uint8_t*)"range bounds must be integers", .len = sizeof("range bounds must be integers") - 1 });
__sc109; }));
    return ast__ast__TYPE_NONE;
  }
  if (!has_start) {
    return end;
  }
  if (!has_end) {
    return start;
  }
  if (start == ast__ast__TYPE_NONE) {
    return end;
  }
  if ((end == ast__ast__TYPE_NONE) || (start == end)) {
    return start;
  }
  if (typechecker__typechecker__TypeChecker__is_integer_literal_node(self, n.start) && typechecker__typechecker__TypeChecker__compatible(self, end, n.start)) {
    return end;
  }
  if (typechecker__typechecker__TypeChecker__is_integer_literal_node(self, n.end) && typechecker__typechecker__TypeChecker__compatible(self, start, n.end)) {
    return start;
  }
  typechecker__typechecker__TypeChecker__err_mismatch(self, n.end, start);
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_path_static_mut(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  if (d.node == ast__ast__NODE_NONE) {
    (d = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), n->as_data.member.member));
  }
  if (d.node == ast__ast__NODE_NONE) {
    return false;
  }
  const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node);
  return ((dn->kind == ast__ast__NodeKind_NODE_CONST) && dn->as_data.const_def.is_static_mut);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_assignable(typechecker__typechecker__TypeChecker *const self, uint32_t const node_in) {
  const uint32_t node = typechecker__typechecker__TypeChecker__peel_wrappers(self, node_in);
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), node)->kind;
  if (nk == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId dd = ast__ast__Ast__resolution_def(&((*a)), node);
    if ((dd.node != ast__ast__NODE_NONE) && (dd.module != self->ast.module)) {
      const ast__ast__Node *const fdn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, dd.module))), dd.node);
      return ((fdn->kind == ast__ast__NodeKind_NODE_CONST) && fdn->as_data.const_def.is_static_mut);
    }
    const uint32_t d = ast__ast__Ast__resolution(&((*a)), node);
    if (d == ast__ast__NODE_NONE) {
      return false;
    }
    const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*a)), d);
    if (dn->kind == ast__ast__NodeKind_NODE_CONST) {
      return dn->as_data.const_def.is_static_mut;
    }
    if (dn->kind == ast__ast__NodeKind_NODE_LET) {
      return dn->as_data.let_stmt.is_mutable;
    }
    if (dn->kind == ast__ast__NodeKind_NODE_PARAMETER) {
      return dn->as_data.parameter.is_mutable;
    }
    if (dn->kind == ast__ast__NodeKind_NODE_PATTERN_NAME) {
      return ast__ast__Ast__at_const(&((*a)), dn->as_data.pattern.name)->as_data.name.is_mutable;
    }
    if (dn->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
      const uint32_t letn = ast__ast__Ast__resolution(&((*a)), d);
      return (((letn != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*a)), letn)->kind == ast__ast__NodeKind_NODE_LET)) && ast__ast__Ast__at_const(&((*a)), letn)->as_data.let_stmt.is_mutable);
    }
    return false;
  }
  if (nk == ast__ast__NodeKind_NODE_UNARY) {
    if (ast__ast__Ast__at_const(&((*a)), node)->as_data.unary.op != lexer__token_type__TokenType_Star) {
      return false;
    }
    const ast__ast__Ty *const ot = typechecker__typechecker__TypeChecker__type_at(self, ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__at_const(&((*a)), node)->as_data.unary.operand));
    return (((ot->kind == ast__ast__TypeKind_TYPE_POINTER) || (ot->kind == ast__ast__TypeKind_TYPE_REFERENCE)) && (ot->qualifier == 2U));
  }
  if ((nk == ast__ast__NodeKind_NODE_INDEX) || (nk == ast__ast__NodeKind_NODE_MEMBER)) {
    if ((nk == ast__ast__NodeKind_NODE_MEMBER) && ast__ast__Ast__at_const(&((*a)), node)->as_data.member.path) {
      return typechecker__typechecker__TypeChecker__tc_path_static_mut(self, node);
    }
    const uint32_t obj = typechecker__typechecker__if_node((nk == ast__ast__NodeKind_NODE_INDEX), ast__ast__Ast__at_const(&((*a)), node)->as_data.index.object, ast__ast__Ast__at_const(&((*a)), node)->as_data.member.object);
    uint32_t oty = ast__ast__Ast__type_of(&((*a)), obj);
    bool via_ref = false;
    bool ref_mut = false;
    if (nk == ast__ast__NodeKind_NODE_INDEX) {
      ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, oty));
      while (y.kind == ast__ast__TypeKind_TYPE_REFERENCE) {
        (via_ref = true);
        (ref_mut = (y.qualifier == 2U));
        (oty = y.as_data.elem);
        (y = (*typechecker__typechecker__TypeChecker__type_at(self, oty)));
      }
    }
    int32_t sk = 0;
    if (nk == ast__ast__NodeKind_NODE_INDEX) {
      (sk = typechecker__typechecker__TypeChecker__slice_kind(self, oty, NULL));
    }
    if (sk != 0) {
      return (sk == 2);
    }
    const ast__ast__Ty ot = (*typechecker__typechecker__TypeChecker__type_at(self, oty));
    if ((nk == ast__ast__NodeKind_NODE_INDEX) && ((ot.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ot.kind == ast__ast__TypeKind_TYPE_INSTANCE))) {
      uint16_t om = 0U;
      uint32_t od = ast__ast__NODE_NONE;
      typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
      int32_t gn = 0;
      if (!typechecker__typechecker__TypeChecker__aggregate_of(self, oty, ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
        return false;
      }
      const ast__ast__DefId im = typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"index_mut", sizeof("index_mut") - 1 });
      if (im.node == ast__ast__NODE_NONE) {
        return false;
      }
      ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, im.module);
      const ast__ast__NodeList irs = ast__ast__Ast__at_const(&((*ia)), im.node)->as_data.function.returns;
      if (irs.len != 1U) {
        return false;
      }
      const uint32_t ir0 = ast__ast__Ast__list(&((*ia)), irs)[0];
      const ast__ast__Node *const irn = ast__ast__Ast__at_const(&((*ia)), ir0);
      const uint32_t itn = typechecker__typechecker__if_node((irn->kind == ast__ast__NodeKind_NODE_PARAMETER), irn->as_data.parameter.ty, ir0);
      if ((itn == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*ia)), itn)->kind != ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
        return false;
      }
      if (via_ref) {
        return ref_mut;
      }
      return typechecker__typechecker__TypeChecker__is_assignable(self, obj);
    }
    if ((ot.kind == ast__ast__TypeKind_TYPE_POINTER) || (ot.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
      return (ot.qualifier == 2U);
    }
    return typechecker__typechecker__TypeChecker__is_assignable(self, obj);
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_place(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  const uint32_t node = typechecker__typechecker__TypeChecker__peel_wrappers(self, id);
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), node);
  if ((n->kind == ast__ast__NodeKind_NODE_IDENTIFIER) || (n->kind == ast__ast__NodeKind_NODE_INDEX)) {
    return true;
  }
  if (n->kind == ast__ast__NodeKind_NODE_MEMBER) {
    return ((!n->as_data.member.path) || typechecker__typechecker__TypeChecker__tc_path_static_mut(self, node));
  }
  if (n->kind == ast__ast__NodeKind_NODE_UNARY) {
    return (n->as_data.unary.op == lexer__token_type__TokenType_Star);
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__receiver_mutable(typechecker__typechecker__TypeChecker *const self, uint32_t const recv) {
  const uint32_t rt = ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), recv);
  if (rt != ast__ast__TYPE_NONE) {
    const ast__ast__Ty *const rty = typechecker__typechecker__TypeChecker__type_at(self, rt);
    if ((rty->kind == ast__ast__TypeKind_TYPE_POINTER) || (rty->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
      return (rty->qualifier == 2U);
    }
  }
  if (typechecker__typechecker__TypeChecker__is_place(self, recv)) {
    return typechecker__typechecker__TypeChecker__is_assignable(self, recv);
  }
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_binding_depth(const typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  if ((decl == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), decl)->kind == ast__ast__NodeKind_NODE_PARAMETER)) {
    return 0U;
  }
  {
    const Option__ptr_u32 __sc110 = Map__u32__u32__Global__get(&self->binding_depth, (&decl));
    if (__sc110.tag == Option_Some) {
      const uint32_t *const v = __sc110.payload.Some._0;
      {
        return (*v);
      }
    }
    else if (1) {
      {
      }
    }
  }
  return 0U;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_record_binding_depth(typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  if (decl != ast__ast__NODE_NONE) {
    Map__u32__u32__Global__insert(&self->binding_depth, decl, self->scope_depth);
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_capture_move_guard(typechecker__typechecker__TypeChecker *const self, uint32_t const expr0) {
  if (self->nclos == 0U) {
    return false;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t expr = expr0;
  for (;;) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), expr);
    if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (expr = n->as_data.unary.operand);
    } else {
      break;
    }
  }
  if (ast__ast__Ast__at_const(&((*a)), expr)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return false;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), expr);
  if ((((d.module != self->ast.module) || (d.node == ast__ast__NODE_NONE)) || (typechecker__typechecker__TypeChecker__tc_capture_index(self, self->clos_stack[((size_t)(self->nclos - 1U))], d.node) < 0)) || (!typechecker__typechecker__TypeChecker__tc_type_is_free(self, ast__ast__Ast__type_of(&((*a)), expr)))) {
    return false;
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), expr)->span;
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc111 = String__Global__new();
String__Global__push_str(&__sc111, (str){ .ptr = (const uint8_t*)"cannot move a captured value out of a closure (the closure's env owns it)", .len = sizeof("cannot move a captured value out of a closure (the closure's env owns it)") - 1 });
__sc111; }));
  return true;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__is_moved(const typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  for (uint32_t i = 0U; i < self->nmoved; i++) {
    if (self->moved[((size_t)i)] == decl) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_mark_move(typechecker__typechecker__TypeChecker *const self, uint32_t const expr0) {
  if (expr0 == ast__ast__NODE_NONE) {
    return;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t expr = expr0;
  for (;;) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), expr);
    if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (expr = n->as_data.unary.operand);
    } else {
      break;
    }
  }
  if (ast__ast__Ast__at_const(&((*a)), expr)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), expr);
  if ((d.module != self->ast.module) || (d.node == ast__ast__NODE_NONE)) {
    return;
  }
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*a)), d.node)->kind;
  if (((dk != ast__ast__NodeKind_NODE_LET) && (dk != ast__ast__NodeKind_NODE_PARAMETER)) || (!typechecker__typechecker__TypeChecker__tc_type_is_free(self, ast__ast__Ast__type_of(&((*a)), expr)))) {
    return;
  }
  if (typechecker__typechecker__TypeChecker__tc_capture_move_guard(self, expr)) {
    return;
  }
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    if ((self->borrows[((size_t)i)].root == d.node) && (self->borrows[((size_t)i)].kind == typechecker__typechecker__BORROW_SHARED)) {
      if (typechecker__typechecker__TypeChecker__borrow_dead_after(self, self->borrows[((size_t)i)], expr)) {
        typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, i);
      } else {
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), expr)->span;
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc112 = String__Global__new();
String__Global__push_str(&__sc112, (str){ .ptr = (const uint8_t*)"cannot move this value while it is borrowed", .len = sizeof("cannot move this value while it is borrowed") - 1 });
__sc112; }));
        break;
      }
    }
  }
  if (typechecker__typechecker__TypeChecker__is_moved(self, d.node)) {
    return;
  }
  if (self->nmoved < 1024U) {
    const uint32_t k = self->nmoved;
    (self->moved[((size_t)k)] = d.node);
    (self->nmoved = (k + 1U));
  } else {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), expr)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc113 = String__Global__new();
String__Global__push_str(&__sc113, (str){ .ptr = (const uint8_t*)"too many moved values in one function (move-analysis limit)", .len = sizeof("too many moved values in one function (move-analysis limit)") - 1 });
__sc113; }));
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_is_uninit(const typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  for (uint32_t i = 0U; i < self->nuninit; i++) {
    if (self->uninit[((size_t)i)] == decl) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_add_uninit(typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  if (typechecker__typechecker__TypeChecker__tc_is_uninit(self, decl)) {
    return;
  }
  if (self->nuninit < 256U) {
    const uint32_t k = self->nuninit;
    (self->uninit[((size_t)k)] = decl);
    (self->nuninit = (k + 1U));
  } else {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), decl)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc114 = String__Global__new();
String__Global__push_str(&__sc114, (str){ .ptr = (const uint8_t*)"too many uninitialized bindings in one function (definite-init analysis limit)", .len = sizeof("too many uninitialized bindings in one function (definite-init analysis limit)") - 1 });
__sc114; }));
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_init(typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  uint32_t i = 0U;
  while (i < self->nuninit) {
    if (self->uninit[((size_t)i)] == decl) {
      (self->nuninit = (self->nuninit - 1U));
      (self->uninit[((size_t)i)] = self->uninit[((size_t)self->nuninit)]);
      return;
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_unmark_move(typechecker__typechecker__TypeChecker *const self, uint32_t const decl) {
  uint32_t i = 0U;
  while (i < self->nmoved) {
    if (self->moved[((size_t)i)] == decl) {
      (self->nmoved = (self->nmoved - 1U));
      (self->moved[((size_t)i)] = self->moved[((size_t)self->nmoved)]);
      break;
    }
    (i = (i + 1U));
  }
  (i = 0U);
  while (i < self->nfreed) {
    if (self->freed[((size_t)i)] == decl) {
      (self->nfreed = (self->nfreed - 1U));
      (self->freed[((size_t)i)] = self->freed[((size_t)self->nfreed)]);
      break;
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) typechecker__typechecker__FlowState typechecker__typechecker__TypeChecker__tc_flow_save(const typechecker__typechecker__TypeChecker *const self) {
  typechecker__typechecker__FlowState s = (typechecker__typechecker__FlowState){0};
  (s.nmoved = self->nmoved);
  for (uint32_t i = 0U; i < self->nmoved; i++) {
    (s.moved[((size_t)i)] = self->moved[((size_t)i)]);
  }
  (s.nuninit = self->nuninit);
  for (uint32_t i = 0U; i < self->nuninit; i++) {
    (s.uninit[((size_t)i)] = self->uninit[((size_t)i)]);
  }
  (s.nfreed = self->nfreed);
  for (uint32_t i = 0U; i < self->nfreed; i++) {
    (s.freed[((size_t)i)] = self->freed[((size_t)i)]);
  }
  (s.nborrows = self->nborrows);
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    (s.borrows[((size_t)i)] = self->borrows[((size_t)i)]);
  }
  return s;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_flow_set(typechecker__typechecker__TypeChecker *const self, const typechecker__typechecker__FlowState *const s) {
  (self->nmoved = s->nmoved);
  for (uint32_t i = 0U; i < s->nmoved; i++) {
    (self->moved[((size_t)i)] = s->moved[((size_t)i)]);
  }
  (self->nuninit = s->nuninit);
  for (uint32_t i = 0U; i < s->nuninit; i++) {
    (self->uninit[((size_t)i)] = s->uninit[((size_t)i)]);
  }
  (self->nfreed = s->nfreed);
  for (uint32_t i = 0U; i < s->nfreed; i++) {
    (self->freed[((size_t)i)] = s->freed[((size_t)i)]);
  }
  (self->nborrows = s->nborrows);
  for (uint32_t i = 0U; i < s->nborrows; i++) {
    (self->borrows[((size_t)i)] = s->borrows[((size_t)i)]);
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_same(const typechecker__typechecker__TypeChecker *const self, typechecker__typechecker__Borrow const a, typechecker__typechecker__Borrow const b) {
  (void)self;
  return ((((a.root == b.root) && (a.kind == b.kind)) && (a.region == b.region)) && (a.origin == b.origin));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_flow_collect(const typechecker__typechecker__TypeChecker *const self, typechecker__typechecker__FlowState *const acc) {
  bool overflow = false;
  for (uint32_t i = 0U; i < self->nmoved; i++) {
    bool seen = false;
    for (uint32_t j = 0U; j < (*acc).nmoved; j++) {
      if ((*acc).moved[((size_t)j)] == self->moved[((size_t)i)]) {
        (seen = true);
      }
    }
    if (!seen) {
      if ((*acc).nmoved < 256U) {
        const uint32_t k = (*acc).nmoved;
        ((*acc).moved[((size_t)k)] = self->moved[((size_t)i)]);
        ((*acc).nmoved = (k + 1U));
      } else {
        (overflow = true);
      }
    }
  }
  for (uint32_t i = 0U; i < self->nuninit; i++) {
    bool seen = false;
    for (uint32_t j = 0U; j < (*acc).nuninit; j++) {
      if ((*acc).uninit[((size_t)j)] == self->uninit[((size_t)i)]) {
        (seen = true);
      }
    }
    if (!seen) {
      if ((*acc).nuninit < 64U) {
        const uint32_t k = (*acc).nuninit;
        ((*acc).uninit[((size_t)k)] = self->uninit[((size_t)i)]);
        ((*acc).nuninit = (k + 1U));
      } else {
        (overflow = true);
      }
    }
  }
  for (uint32_t i = 0U; i < self->nfreed; i++) {
    bool seen = false;
    for (uint32_t j = 0U; j < (*acc).nfreed; j++) {
      if ((*acc).freed[((size_t)j)] == self->freed[((size_t)i)]) {
        (seen = true);
      }
    }
    if (!seen) {
      if ((*acc).nfreed < 64U) {
        const uint32_t k = (*acc).nfreed;
        ((*acc).freed[((size_t)k)] = self->freed[((size_t)i)]);
        ((*acc).nfreed = (k + 1U));
      } else {
        (overflow = true);
      }
    }
  }
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    bool seen = false;
    for (uint32_t j = 0U; j < (*acc).nborrows; j++) {
      if (typechecker__typechecker__TypeChecker__borrow_same(self, (*acc).borrows[((size_t)j)], self->borrows[((size_t)i)])) {
        (seen = true);
      }
    }
    if (!seen) {
      if ((*acc).nborrows < 64U) {
        const uint32_t k = (*acc).nborrows;
        ((*acc).borrows[((size_t)k)] = self->borrows[((size_t)i)]);
        ((*acc).nborrows = (k + 1U));
      } else {
        (overflow = true);
      }
    }
  }
  return overflow;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_flow_overflow(typechecker__typechecker__TypeChecker *const self, uint32_t const at) {
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), at)->span;
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc115 = String__Global__new();
String__Global__push_str(&__sc115, (str){ .ptr = (const uint8_t*)"too many flow facts to merge across branches in one function (analysis limit)", .len = sizeof("too many flow facts to merge across branches in one function (analysis limit)") - 1 });
__sc115; }));
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_stmt_returns(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return false;
  }
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id);
  if (n->kind == ast__ast__NodeKind_NODE_RETURN) {
    return true;
  }
  if (n->kind == ast__ast__NodeKind_NODE_BLOCK) {
    const ast__ast__NodeList ss = n->as_data.block.statements;
    return ((ss.len != 0U) && typechecker__typechecker__TypeChecker__tc_stmt_returns(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ss)[((size_t)(ss.len - 1U))]));
  }
  if (n->kind == ast__ast__NodeKind_NODE_IF) {
    return (((n->as_data.if_stmt.else_branch != ast__ast__NODE_NONE) && typechecker__typechecker__TypeChecker__tc_stmt_returns(self, n->as_data.if_stmt.then_branch)) && typechecker__typechecker__TypeChecker__tc_stmt_returns(self, n->as_data.if_stmt.else_branch));
  }
  if (n->kind == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) {
    const uint32_t ty = ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), n->as_data.single.value);
    return ((ty != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ty)->kind == ast__ast__TypeKind_TYPE_NEVER));
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_scope_enter(typechecker__typechecker__TypeChecker *const self) {
  (self->scope_depth = (self->scope_depth + 1U));
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__tc_scope_exit(typechecker__typechecker__TypeChecker *const self) {
  const uint32_t d = self->scope_depth;
  uint32_t w = 0U;
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    const typechecker__typechecker__Borrow b = self->borrows[((size_t)i)];
    if (((uint32_t)b.region) >= d) {
      continue;
    }
    if (((b.binding != ast__ast__NODE_NONE) && (b.root != ast__ast__NODE_NONE)) && (typechecker__typechecker__TypeChecker__tc_binding_depth(self, b.root) >= d)) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), b.origin)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc116 = String__Global__new();
String__Global__push_str(&__sc116, (str){ .ptr = (const uint8_t*)"borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored", .len = sizeof("borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored") - 1 });
__sc116; }));
      continue;
    }
    (self->borrows[((size_t)w)] = self->borrows[((size_t)i)]);
    (w = (w + 1U));
  }
  (self->nborrows = w);
  if (self->scope_depth != 0U) {
    (self->scope_depth = (self->scope_depth - 1U));
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__place_index_const(const typechecker__typechecker__TypeChecker *const self, uint32_t const idx, int64_t *const out) {
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), idx);
  if ((n->kind != ast__ast__NodeKind_NODE_LITERAL) || (n->as_data.literal.token_type != lexer__token_type__TokenType_IntegerLiteral)) {
    return false;
  }
  const lexer__token__Span lr = n->as_data.literal.raw;
  const uint8_t *p = (self->source + ((size_t)lr.start));
  size_t len = ((size_t)(lr.end - lr.start));
  uint64_t base = 10ULL;
  if ((len >= 2ULL) && (p[0] == 48U)) {
    const uint8_t c1 = (p[1] | 0x20U);
    if (c1 == 120U) {
      (base = 16ULL);
      (p = (p + 2));
      (len = (len - 2ULL));
    } else if (c1 == 98U) {
      (base = 2ULL);
      (p = (p + 2));
      (len = (len - 2ULL));
    } else if (c1 == 111U) {
      (base = 8ULL);
      (p = (p + 2));
      (len = (len - 2ULL));
    }
  }
  uint64_t acc = 0ULL;
  for (size_t i = 0ULL; i < len; i++) {
    const uint8_t ch = p[i];
    if (ch == 95U) {
      continue;
    }
    uint64_t d = 0ULL;
    if (ch <= 57U) {
      (d = ((uint64_t)((uint8_t)((uint32_t)ch - (uint32_t)48U))));
    } else {
      (d = ((uint64_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)(ch | 0x20U) - (uint32_t)97U)) + (uint32_t)10U))));
    }
    if ((d >= base) || (acc > ({ uint64_t __sc117 = ((uint64_t)({ int64_t __sc_r; if (__builtin_sub_overflow(0x7FFFFFFFFFFFFFFFLL, ((int64_t)d), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })); uint64_t __sc118 = base; if (__sc118 == 0) { __sc_panic("divide by zero"); } (__sc117 / __sc118); }))) {
      return false;
    }
    (acc = ((acc * base) + d));
  }
  ((*out) = ((int64_t)acc));
  return true;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_type_is_union(const typechecker__typechecker__TypeChecker *const self, uint32_t const ty) {
  uint16_t m = 0U;
  uint32_t d = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if ((ty == ast__ast__TYPE_NONE) || (!typechecker__typechecker__TypeChecker__aggregate_of(self, ty, ((uint16_t *)(&m)), ((uint32_t *)(&d)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn))))) {
    return false;
  }
  const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, m))), d);
  return ((dn->kind == ast__ast__NodeKind_NODE_STRUCT) && dn->as_data.aggregate.is_union);
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__place_decompose(typechecker__typechecker__TypeChecker *const self, uint32_t const place0, typechecker__typechecker__PStep *const steps, int32_t *const nsteps, int32_t const cap) {
  ((*nsteps) = 0);
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t place = place0;
  for (;;) {
    const ast__ast__Node *const pn = ast__ast__Ast__at_const(&((*a)), place);
    if ((pn->kind == ast__ast__NodeKind_NODE_UNARY) && ((pn->as_data.unary.op == lexer__token_type__TokenType_Move) || (pn->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (place = pn->as_data.unary.operand);
      continue;
    }
    if ((pn->kind == ast__ast__NodeKind_NODE_UNARY) && (pn->as_data.unary.op == lexer__token_type__TokenType_Star)) {
      const uint32_t op = pn->as_data.unary.operand;
      const uint32_t ot = ast__ast__Ast__type_of(&((*a)), op);
      if ((ot == ast__ast__TYPE_NONE) || (typechecker__typechecker__TypeChecker__type_at(self, ot)->kind != ast__ast__TypeKind_TYPE_REFERENCE)) {
        return ast__ast__NODE_NONE;
      }
      if ((*nsteps) < cap) {
        const int32_t k = (*nsteps);
        (steps[((size_t)k)] = (typechecker__typechecker__PStep){ .kind = typechecker__typechecker__PS_DEREF });
        ((*nsteps) = ({ int32_t __sc_r; if (__builtin_add_overflow(k, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
      (place = op);
      continue;
    }
    uint32_t base = ast__ast__NODE_NONE;
    typechecker__typechecker__PStep step = (typechecker__typechecker__PStep){ .kind = typechecker__typechecker__PS_FIELD };
    if ((pn->kind == ast__ast__NodeKind_NODE_MEMBER) && (!pn->as_data.member.path)) {
      (base = pn->as_data.member.object);
      (step.kind = typechecker__typechecker__PS_FIELD);
      (step.name = typechecker__typechecker__TypeChecker__name_span(self, pn->as_data.member.member));
    } else if (pn->kind == ast__ast__NodeKind_NODE_INDEX) {
      (base = pn->as_data.index.object);
      (step.kind = typechecker__typechecker__PS_INDEX);
      int64_t v = 0;
      if (typechecker__typechecker__TypeChecker__place_index_const(self, pn->as_data.index.index, ((int64_t *)(&v)))) {
        (step.index_const = true);
        (step.index_val = v);
      }
    } else {
      break;
    }
    const uint32_t bt = ast__ast__Ast__type_of(&((*a)), base);
    if (bt == ast__ast__TYPE_NONE) {
      return ast__ast__NODE_NONE;
    }
    const ast__ast__Ty btk = (*typechecker__typechecker__TypeChecker__type_at(self, bt));
    uint32_t union_ty = bt;
    if (btk.kind == ast__ast__TypeKind_TYPE_REFERENCE) {
      (union_ty = btk.as_data.elem);
    }
    const bool base_union = ((pn->kind == ast__ast__NodeKind_NODE_MEMBER) && typechecker__typechecker__TypeChecker__tc_type_is_union(self, union_ty));
    if (base_union) {
      ((*nsteps) = 0);
    }
    if (btk.kind == ast__ast__TypeKind_TYPE_REFERENCE) {
      if (pn->kind == ast__ast__NodeKind_NODE_INDEX) {
        return ast__ast__NODE_NONE;
      }
      if ((!base_union) && ((*nsteps) < cap)) {
        const int32_t k = (*nsteps);
        (steps[((size_t)k)] = step);
        ((*nsteps) = ({ int32_t __sc_r; if (__builtin_add_overflow(k, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
      if ((*nsteps) < cap) {
        const int32_t k = (*nsteps);
        (steps[((size_t)k)] = (typechecker__typechecker__PStep){ .kind = typechecker__typechecker__PS_DEREF });
        ((*nsteps) = ({ int32_t __sc_r; if (__builtin_add_overflow(k, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
      (place = base);
      continue;
    }
    if (btk.kind == ast__ast__TypeKind_TYPE_POINTER) {
      return ast__ast__NODE_NONE;
    }
    if ((pn->kind == ast__ast__NodeKind_NODE_INDEX) && (btk.kind != ast__ast__TypeKind_TYPE_ARRAY)) {
      return ast__ast__NODE_NONE;
    }
    if ((!base_union) && ((*nsteps) < cap)) {
      const int32_t k = (*nsteps);
      (steps[((size_t)k)] = step);
      ((*nsteps) = ({ int32_t __sc_r; if (__builtin_add_overflow(k, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
    (place = base);
  }
  if (ast__ast__Ast__at_const(&((*a)), place)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), place);
  if ((d.node == ast__ast__NODE_NONE) || (d.module != self->ast.module)) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*a)), d.node)->kind;
  if (((((dk == ast__ast__NodeKind_NODE_PARAMETER) || (dk == ast__ast__NodeKind_NODE_LET)) || (dk == ast__ast__NodeKind_NODE_PATTERN_NAME)) || (dk == ast__ast__NodeKind_NODE_IDENTIFIER)) || (dk == ast__ast__NodeKind_NODE_FOR)) {
    return d.node;
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__borrow_place_root(typechecker__typechecker__TypeChecker *const self, uint32_t const place) {
  typechecker__typechecker__Steps16 steps = (typechecker__typechecker__Steps16){0};
  int32_t n = 0;
  return typechecker__typechecker__TypeChecker__place_decompose(self, place, ((typechecker__typechecker__PStep *)(&steps.s[0])), ((int32_t *)(&n)), typechecker__typechecker__PLACE_MAX_STEPS);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__places_overlap(typechecker__typechecker__TypeChecker *const self, uint32_t const aN, uint32_t const bN) {
  typechecker__typechecker__Steps16 sa = (typechecker__typechecker__Steps16){0};
  typechecker__typechecker__Steps16 sb = (typechecker__typechecker__Steps16){0};
  int32_t na = 0;
  int32_t nb = 0;
  const uint32_t ra = typechecker__typechecker__TypeChecker__place_decompose(self, aN, ((typechecker__typechecker__PStep *)(&sa.s[0])), ((int32_t *)(&na)), typechecker__typechecker__PLACE_MAX_STEPS);
  const uint32_t rb = typechecker__typechecker__TypeChecker__place_decompose(self, bN, ((typechecker__typechecker__PStep *)(&sb.s[0])), ((int32_t *)(&nb)), typechecker__typechecker__PLACE_MAX_STEPS);
  if (((ra == ast__ast__NODE_NONE) || (rb == ast__ast__NODE_NONE)) || (ra != rb)) {
    return false;
  }
  int32_t common = na;
  if (nb < na) {
    (common = nb);
  }
  for (int32_t i = 0; i < common; i++) {
    const typechecker__typechecker__PStep pa = sa.s[((size_t)({ int32_t __sc_r; if (__builtin_sub_overflow(({ int32_t __sc_r; if (__builtin_sub_overflow(na, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), i, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))];
    const typechecker__typechecker__PStep pb = sb.s[((size_t)({ int32_t __sc_r; if (__builtin_sub_overflow(({ int32_t __sc_r; if (__builtin_sub_overflow(nb, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), i, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))];
    if (pa.kind != pb.kind) {
      return true;
    }
    if (pa.kind == typechecker__typechecker__PS_FIELD) {
      const uint32_t la = (pa.name.end - pa.name.start);
      const uint32_t lb = (pb.name.end - pb.name.start);
      if ((la != lb) || (memcmp((self->source + ((size_t)pa.name.start)), (self->source + ((size_t)pb.name.start)), ((size_t)la)) != 0)) {
        return false;
      }
    } else if ((((pa.kind == typechecker__typechecker__PS_INDEX) && pa.index_const) && pb.index_const) && (pa.index_val != pb.index_val)) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__place_through_binding(const typechecker__typechecker__TypeChecker *const self, uint32_t const place0) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t place = place0;
  for (;;) {
    const ast__ast__Node *const pn = ast__ast__Ast__at_const(&((*a)), place);
    uint32_t base = ast__ast__NODE_NONE;
    if ((pn->kind == ast__ast__NodeKind_NODE_UNARY) && (pn->as_data.unary.op == lexer__token_type__TokenType_Star)) {
      (base = pn->as_data.unary.operand);
    } else if ((pn->kind == ast__ast__NodeKind_NODE_MEMBER) && (!pn->as_data.member.path)) {
      (base = pn->as_data.member.object);
    } else if (pn->kind == ast__ast__NodeKind_NODE_INDEX) {
      (base = pn->as_data.index.object);
    } else {
      return ast__ast__NODE_NONE;
    }
    const uint32_t bt = ast__ast__Ast__type_of(&((*a)), base);
    bool is_ref = false;
    if ((bt != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, bt)->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
      (is_ref = true);
    }
    if (((pn->kind == ast__ast__NodeKind_NODE_UNARY) || is_ref) && (ast__ast__Ast__at_const(&((*a)), base)->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
      const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), base);
      if ((d.node != ast__ast__NODE_NONE) && (d.module == self->ast.module)) {
        return d.node;
      }
      return ast__ast__NODE_NONE;
    }
    (place = base);
  }
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__borrow_mark(const typechecker__typechecker__TypeChecker *const self) {
  return self->nborrows;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_release_to(typechecker__typechecker__TypeChecker *const self, uint32_t const mark) {
  if (self->nborrows <= mark) {
    return;
  }
  uint32_t w = mark;
  uint32_t i = mark;
  while (i < self->nborrows) {
    if (self->borrows[((size_t)i)].binding != ast__ast__NODE_NONE) {
      (self->borrows[((size_t)w)] = self->borrows[((size_t)i)]);
      (w = (w + 1U));
    }
    (i = (i + 1U));
  }
  (self->nborrows = w);
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_tombstone_at(typechecker__typechecker__TypeChecker *const self, uint32_t const i) {
  (self->borrows[((size_t)i)].root = ast__ast__NODE_NONE);
  (self->borrows[((size_t)i)].binding = ast__ast__NODE_NONE);
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_dead_after(typechecker__typechecker__TypeChecker *const self, typechecker__typechecker__Borrow const b, uint32_t const after) {
  if ((b.binding == ast__ast__NODE_NONE) || (self->loop_depth != 0U)) {
    return false;
  }
  const ast__ast__Node *const bn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), b.binding);
  if ((bn->kind == ast__ast__NodeKind_NODE_LET) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), bn->as_data.let_stmt.name)->kind == ast__ast__NodeKind_NODE_PATTERN_TUPLE)) {
    return false;
  }
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    if ((self->borrows[((size_t)i)].binding != b.binding) && (typechecker__typechecker__TypeChecker__place_through_binding(self, self->borrows[((size_t)i)].place) == b.binding)) {
      return false;
    }
  }
  const size_t n = Vector__ast__ast__Node__Global__len(&(*typechecker__typechecker__TypeChecker__cur_ast(self)).nodes);
  uint32_t nid = (after + 1U);
  while (((size_t)nid) < n) {
    const ast__ast__DefId rd = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nid);
    if ((rd.node == b.binding) && (rd.module == self->ast.module)) {
      return false;
    }
    (nid = (nid + 1U));
  }
  return true;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_report_conflict(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint8_t const kind, uint32_t const origin) {
  const uint32_t root = typechecker__typechecker__TypeChecker__borrow_place_root(self, place);
  if (root == ast__ast__NODE_NONE) {
    return false;
  }
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    const typechecker__typechecker__Borrow b = self->borrows[((size_t)i)];
    if (((b.root != root) || ((kind == typechecker__typechecker__BORROW_SHARED) && (b.kind == typechecker__typechecker__BORROW_SHARED))) || (!typechecker__typechecker__TypeChecker__places_overlap(self, place, b.place))) {
      continue;
    }
    if (typechecker__typechecker__TypeChecker__borrow_dead_after(self, b, origin)) {
      typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, i);
      continue;
    }
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), origin)->span;
    const char *k1 = ((const char *)({ __auto_type __sc119 = (str){ (const uint8_t *)"immutable", sizeof("immutable") - 1 }; str__ptr(&__sc119); }));
    if (kind == typechecker__typechecker__BORROW_MUT) {
      (k1 = ((const char *)({ __auto_type __sc120 = (str){ (const uint8_t *)"mutable", sizeof("mutable") - 1 }; str__ptr(&__sc120); })));
    }
    const char *k2 = ((const char *)({ __auto_type __sc121 = (str){ (const uint8_t *)"immutable", sizeof("immutable") - 1 }; str__ptr(&__sc121); }));
    if (b.kind == typechecker__typechecker__BORROW_MUT) {
      (k2 = ((const char *)({ __auto_type __sc122 = (str){ (const uint8_t *)"mutable", sizeof("mutable") - 1 }; str__ptr(&__sc122); })));
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc123 = String__Global__new();
String__Global__push_str(&__sc123, (str){ .ptr = (const uint8_t*)"cannot borrow this value as ", .len = sizeof("cannot borrow this value as ") - 1 });
String__Global__push_str(&__sc123, utils__errors__cstr(k1));
String__Global__push_str(&__sc123, (str){ .ptr = (const uint8_t*)" while it is already borrowed as ", .len = sizeof(" while it is already borrowed as ") - 1 });
String__Global__push_str(&__sc123, utils__errors__cstr(k2));
__sc123; }));
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc124 = String__Global__new();
String__Global__push_str(&__sc124, (str){ .ptr = (const uint8_t*)"a value may have many '&' borrows or a single '&mut', not both; the earlier borrow must end first", .len = sizeof("a value may have many '&' borrows or a single '&mut', not both; the earlier borrow must end first") - 1 });
__sc124; }));
    return true;
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_push(typechecker__typechecker__TypeChecker *const self, uint32_t const root, uint8_t const kind, uint32_t const place, uint32_t const origin) {
  if (self->nborrows < 256U) {
    const uint32_t k = self->nborrows;
    (self->borrows[((size_t)k)] = (typechecker__typechecker__Borrow){ .root = root, .place = place, .kind = kind, .region = ((uint16_t)self->scope_depth), .origin = origin, .binding = ast__ast__NODE_NONE });
    (self->nborrows = (k + 1U));
  } else {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), origin)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, 1U, ({ String__Global __sc125 = String__Global__new();
String__Global__push_str(&__sc125, (str){ .ptr = (const uint8_t*)"too many simultaneous borrows in one function (borrow-checker limit)", .len = sizeof("too many simultaneous borrows in one function (borrow-checker limit)") - 1 });
__sc125; }));
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_create(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint8_t const kind, uint32_t const origin) {
  const uint32_t root = typechecker__typechecker__TypeChecker__borrow_place_root(self, place);
  if (root == ast__ast__NODE_NONE) {
    return;
  }
  if (!typechecker__typechecker__TypeChecker__borrow_report_conflict(self, place, kind, origin)) {
    typechecker__typechecker__TypeChecker__borrow_push(self, root, kind, place, origin);
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_conflicting_read(typechecker__typechecker__TypeChecker *const self, uint32_t const place) {
  const uint32_t root = typechecker__typechecker__TypeChecker__borrow_place_root(self, place);
  if (root == ast__ast__NODE_NONE) {
    return false;
  }
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    const typechecker__typechecker__Borrow b = self->borrows[((size_t)i)];
    if (((b.root != root) || (b.kind != typechecker__typechecker__BORROW_MUT)) || (!typechecker__typechecker__TypeChecker__places_overlap(self, place, b.place))) {
      continue;
    }
    if (typechecker__typechecker__TypeChecker__borrow_dead_after(self, b, place)) {
      typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, i);
      continue;
    }
    return true;
  }
  return false;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__borrow_conflicting_write(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint32_t const after) {
  const uint32_t root = typechecker__typechecker__TypeChecker__borrow_place_root(self, place);
  if (root == ast__ast__NODE_NONE) {
    return false;
  }
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    const typechecker__typechecker__Borrow b = self->borrows[((size_t)i)];
    if ((((b.root != root) || (b.kind != typechecker__typechecker__BORROW_SHARED)) || (b.binding == ast__ast__NODE_NONE)) || (!typechecker__typechecker__TypeChecker__places_overlap(self, place, b.place))) {
      continue;
    }
    if (typechecker__typechecker__TypeChecker__borrow_dead_after(self, b, after)) {
      typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, i);
      continue;
    }
    return true;
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_transfer_ref(typechecker__typechecker__TypeChecker *const self, uint32_t const init, uint32_t const binding) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t e = init;
  for (;;) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), e);
    if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (e = n->as_data.unary.operand);
    } else {
      break;
    }
  }
  if (ast__ast__Ast__at_const(&((*a)), e)->kind != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return;
  }
  const ast__ast__DefId rd = ast__ast__Ast__resolution_def(&((*a)), e);
  if ((rd.node == ast__ast__NODE_NONE) || (rd.module != self->ast.module)) {
    return;
  }
  const uint32_t n0 = self->nborrows;
  const uint16_t region = ((uint16_t)typechecker__typechecker__TypeChecker__tc_binding_depth(self, binding));
  bool moved = false;
  for (uint32_t i = 0U; i < n0; i++) {
    if (self->borrows[((size_t)i)].binding == rd.node) {
      if (self->borrows[((size_t)i)].kind == typechecker__typechecker__BORROW_MUT) {
        (self->borrows[((size_t)i)].binding = binding);
        (self->borrows[((size_t)i)].region = region);
        (moved = true);
      } else if (self->nborrows < 256U) {
        const uint32_t k = self->nborrows;
        (self->borrows[((size_t)k)] = self->borrows[((size_t)i)]);
        (self->borrows[((size_t)k)].region = region);
        (self->borrows[((size_t)k)].binding = binding);
        (self->nborrows = (k + 1U));
      }
    }
  }
  if ((moved && (!typechecker__typechecker__TypeChecker__is_moved(self, rd.node))) && (self->nmoved < 1024U)) {
    const uint32_t k = self->nmoved;
    (self->moved[((size_t)k)] = rd.node);
    (self->nmoved = (k + 1U));
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tuple_binds_reference(const typechecker__typechecker__TypeChecker *const self, uint32_t const name) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList names = ast__ast__Ast__at_const(&((*a)), name)->as_data.pattern.children;
  for (uint32_t i = 0U; i < names.len; i++) {
    const uint32_t nid = ast__ast__Ast__list(&((*a)), names)[((size_t)i)];
    const uint32_t et = ast__ast__Ast__type_of(&((*a)), nid);
    if ((et != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, et)->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__borrow_nll_drop(typechecker__typechecker__TypeChecker *const self, uint32_t const block_id, const uint32_t *const ids, uint32_t const si) {
  typechecker__typechecker__Keep256 keep = (typechecker__typechecker__Keep256){0};
  for (uint32_t k = 0U; k < self->nborrows; k++) {
    (keep.k[((size_t)k)] = true);
    const typechecker__typechecker__Borrow b = self->borrows[((size_t)k)];
    if ((b.binding != ast__ast__NODE_NONE) && (b.region == ((uint16_t)self->scope_depth))) {
      const ast__ast__Node *const bn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), b.binding);
      const bool tuple = ((bn->kind == ast__ast__NodeKind_NODE_LET) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), bn->as_data.let_stmt.name)->kind == ast__ast__NodeKind_NODE_PATTERN_TUPLE));
      if (!tuple) {
        (keep.k[((size_t)k)] = false);
        uint32_t nid = (ids[((size_t)si)] + 1U);
        while ((nid < block_id) && (!keep.k[((size_t)k)])) {
          const ast__ast__DefId rd = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nid);
          (keep.k[((size_t)k)] = ((rd.node == b.binding) && (rd.module == self->ast.module)));
          (nid = (nid + 1U));
        }
      }
    }
  }
  int32_t kk = ({ int32_t __sc_r; if (__builtin_sub_overflow(((int32_t)self->nborrows), 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; });
  while (kk >= 0) {
    if (keep.k[((size_t)kk)]) {
      const uint32_t thru = typechecker__typechecker__TypeChecker__place_through_binding(self, self->borrows[((size_t)kk)].place);
      if (thru != ast__ast__NODE_NONE) {
        for (uint32_t j = 0U; j < self->nborrows; j++) {
          if (self->borrows[((size_t)j)].binding == thru) {
            (keep.k[((size_t)j)] = true);
          }
        }
      }
    }
    (kk = ({ int32_t __sc_r; if (__builtin_sub_overflow(kk, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  uint32_t w = 0U;
  for (uint32_t k = 0U; k < self->nborrows; k++) {
    if (keep.k[((size_t)k)]) {
      (self->borrows[((size_t)w)] = self->borrows[((size_t)k)]);
      (w = (w + 1U));
    }
  }
  (self->nborrows = w);
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__place_escape(typechecker__typechecker__TypeChecker *const self, uint32_t const place, uint32_t const depth) {
  typechecker__typechecker__Steps16 steps = (typechecker__typechecker__Steps16){0};
  int32_t ns = 0;
  const uint32_t root = typechecker__typechecker__TypeChecker__place_decompose(self, place, ((typechecker__typechecker__PStep *)(&steps.s[0])), ((int32_t *)(&ns)), typechecker__typechecker__PLACE_MAX_STEPS);
  if (root == ast__ast__NODE_NONE) {
    return 0;
  }
  bool thru = false;
  for (int32_t i = 0; i < ns; i++) {
    if (steps.s[((size_t)i)].kind == typechecker__typechecker__PS_DEREF) {
      (thru = true);
    }
  }
  if (thru) {
    if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), root)->kind == ast__ast__NodeKind_NODE_PARAMETER) {
      return 0;
    }
    return typechecker__typechecker__TypeChecker__borrow_escape_of_binding(self, root, (depth + 1U));
  }
  if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), root)->kind == ast__ast__NodeKind_NODE_PARAMETER) {
    return 2;
  }
  return 1;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__borrow_escape_of_binding(typechecker__typechecker__TypeChecker *const self, uint32_t const binding, uint32_t const depth) {
  if (depth > 8U) {
    return 0;
  }
  int32_t esc = 0;
  for (uint32_t i = 0U; i < self->nborrows; i++) {
    if (self->borrows[((size_t)i)].binding == binding) {
      const int32_t e = typechecker__typechecker__TypeChecker__place_escape(self, self->borrows[((size_t)i)].place, depth);
      if (e == 1) {
        return 1;
      }
      if (e != 0) {
        (esc = e);
      }
    }
  }
  return esc;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__addr_escape_at(typechecker__typechecker__TypeChecker *const self, uint32_t const e0, uint32_t const depth) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  uint32_t e = e0;
  for (;;) {
    const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), e);
    if (n->kind == ast__ast__NodeKind_NODE_CAST) {
      (e = n->as_data.cast.expression);
    } else if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && ((n->as_data.unary.op == lexer__token_type__TokenType_Move) || (n->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
      (e = n->as_data.unary.operand);
    } else {
      break;
    }
  }
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), e);
  if ((n->kind == ast__ast__NodeKind_NODE_UNARY) && (n->as_data.unary.op == lexer__token_type__TokenType_Ampersand)) {
    return typechecker__typechecker__TypeChecker__place_escape(self, n->as_data.unary.operand, depth);
  }
  if ((n->kind == ast__ast__NodeKind_NODE_IDENTIFIER) && (depth < typechecker__typechecker__BORROW_ESCAPE_MAX_DEPTH)) {
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), e);
    if ((d.module == self->ast.module) && (d.node != ast__ast__NODE_NONE)) {
      const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*a)), d.node);
      const uint32_t dt = ast__ast__Ast__type_of(&((*a)), d.node);
      if ((dt != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, dt)->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
        return typechecker__typechecker__TypeChecker__borrow_escape_of_binding(self, d.node, depth);
      }
      if ((dn->kind == ast__ast__NodeKind_NODE_LET) && (dn->as_data.let_stmt.value != ast__ast__NODE_NONE)) {
        return typechecker__typechecker__TypeChecker__addr_escape_at(self, dn->as_data.let_stmt.value, (depth + 1U));
      }
    }
  }
  return 0;
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__addr_escape(typechecker__typechecker__TypeChecker *const self, uint32_t const e) {
  return typechecker__typechecker__TypeChecker__addr_escape_at(self, e, 0U);
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__find_extend_item_named(const typechecker__typechecker__TypeChecker *const self, uint32_t const extnode, lexer__token__Span const name, uint16_t const nmod) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList have = ast__ast__Ast__at_const(&((*a)), extnode)->as_data.extend_def.items;
  for (uint32_t j = 0U; j < have.len; j++) {
    const uint32_t hid = ast__ast__Ast__list(&((*a)), have)[((size_t)j)];
    const ast__ast__Node *const hm = ast__ast__Ast__at_const(&((*a)), hid);
    if ((hm->kind == ast__ast__NodeKind_NODE_FUNCTION) && typechecker__typechecker__spans_eq2(typechecker__typechecker__TypeChecker__mod_src(self, nmod), name, self->source, ast__ast__Ast__at_const(&((*a)), hm->as_data.function.name)->as_data.name.text)) {
      return hid;
    }
  }
  return ast__ast__NODE_NONE;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__extend_method_signature_matches(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const req, uint32_t const have, const ast__ast__DefId *const subp, const uint32_t *const suba, int32_t const nsub) {
  ast__ast__Ast *const ra = typechecker__typechecker__TypeChecker__mod_ast(self, req.module);
  const ast__ast__FunctionData rf = ast__ast__Ast__at_const(&((*ra)), req.node)->as_data.function;
  const ast__ast__FunctionData hf = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), have)->as_data.function;
  if (rf.params.len != hf.params.len) {
    return false;
  }
  for (uint32_t i = 0U; i < rf.params.len; i++) {
    const uint32_t rp = ast__ast__Ast__list(&((*ra)), rf.params)[((size_t)i)];
    const uint32_t hp = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hf.params)[((size_t)i)];
    uint32_t rt = typechecker__typechecker__TypeChecker__lower_type_in(self, req.module, ast__ast__Ast__at_const(&((*ra)), rp)->as_data.parameter.ty);
    (rt = typechecker__typechecker__TypeChecker__subst_type(self, rt, subp, suba, nsub));
    const uint32_t ht = typechecker__typechecker__TypeChecker__lower_type_in(self, self->ast.module, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hp)->as_data.parameter.ty);
    if ((rt != ht) && ((i != 0U) || (!typechecker__typechecker__TypeChecker__receiver_type_eq(self, rt, ht)))) {
      return false;
    }
  }
  if (rf.returns.len != hf.returns.len) {
    if ((rf.returns.len > 1U) || (hf.returns.len > 1U)) {
      return false;
    }
    uint32_t rt = ast__ast__TYPE_NONE;
    uint32_t ht = ast__ast__TYPE_NONE;
    if (rf.returns.len == 1U) {
      const uint32_t rr = ast__ast__Ast__list(&((*ra)), rf.returns)[0];
      const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*ra)), rr);
      (rt = typechecker__typechecker__TypeChecker__lower_type_in(self, req.module, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, rr)));
      (rt = typechecker__typechecker__TypeChecker__subst_type(self, rt, subp, suba, nsub));
    }
    if (hf.returns.len == 1U) {
      const uint32_t hr = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hf.returns)[0];
      const ast__ast__Node *const hn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hr);
      (ht = typechecker__typechecker__TypeChecker__lower_type_in(self, self->ast.module, typechecker__typechecker__if_node((hn->kind == ast__ast__NodeKind_NODE_PARAMETER), hn->as_data.parameter.ty, hr)));
    }
    return typechecker__typechecker__TypeChecker__ret_eq(self, rt, ht);
  }
  for (uint32_t k = 0U; k < rf.returns.len; k++) {
    const uint32_t rr = ast__ast__Ast__list(&((*ra)), rf.returns)[((size_t)k)];
    const uint32_t hr = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hf.returns)[((size_t)k)];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*ra)), rr);
    const ast__ast__Node *const hn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hr);
    uint32_t rt = typechecker__typechecker__TypeChecker__lower_type_in(self, req.module, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, rr));
    (rt = typechecker__typechecker__TypeChecker__subst_type(self, rt, subp, suba, nsub));
    const uint32_t ht = typechecker__typechecker__TypeChecker__lower_type_in(self, self->ast.module, typechecker__typechecker__if_node((hn->kind == ast__ast__NodeKind_NODE_PARAMETER), hn->as_data.parameter.ty, hr));
    if (!typechecker__typechecker__TypeChecker__ret_eq(self, rt, ht)) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_interface_requirements(typechecker__typechecker__TypeChecker *const self, uint32_t const extnode, ast__ast__DefId const iface, uint32_t const self_ty, const ast__ast__DefId *const subp, const uint32_t *const suba, int32_t const nsub, int32_t const depth) {
  if ((iface.node == ast__ast__NODE_NONE) || (depth > 8)) {
    return;
  }
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, iface.module);
  if (ast__ast__Ast__at_const(&((*ia)), iface.node)->kind != ast__ast__NodeKind_NODE_INTERFACE) {
    return;
  }
  const ast__ast__NodeList req = ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def.items;
  for (uint32_t i = 0U; i < req.len; i++) {
    const uint32_t rid = ast__ast__Ast__list(&((*ia)), req)[((size_t)i)];
    const ast__ast__Node *const rm = ast__ast__Ast__at_const(&((*ia)), rid);
    if ((rm->kind == ast__ast__NodeKind_NODE_FUNCTION) && (rm->as_data.function.body == ast__ast__NODE_NONE)) {
      const lexer__token__Span rn = ast__ast__Ast__at_const(&((*ia)), rm->as_data.function.name)->as_data.name.text;
      const uint32_t hm = typechecker__typechecker__TypeChecker__find_extend_item_named(self, extnode, rn, iface.module);
      const ast__ast__DefId reqdef = (ast__ast__DefId){ .module = iface.module, .node = rid };
      if (hm == ast__ast__NODE_NONE) {
        const lexer__token__Span at = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), extnode)->as_data.extend_def.interface_type)->span;
        utils__errors__Errors__emit(&self->errors, at.start, (at.end - at.start), ({ String__Global __sc126 = String__Global__new();
String__Global__push_str(&__sc126, (str){ .ptr = (const uint8_t*)"missing method '", .len = sizeof("missing method '") - 1 });
String__Global__push_str(&__sc126, utils__errors__span_str(typechecker__typechecker__TypeChecker__mod_src(self, iface.module), rn.start, rn.end));
String__Global__push_str(&__sc126, (str){ .ptr = (const uint8_t*)"' required by this interface", .len = sizeof("' required by this interface") - 1 });
__sc126; }));
      } else if (!typechecker__typechecker__TypeChecker__extend_method_signature_matches(self, reqdef, hm, subp, suba, nsub)) {
        const lexer__token__Span at = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), hm)->span;
        utils__errors__Errors__emit(&self->errors, at.start, (at.end - at.start), ({ String__Global __sc127 = String__Global__new();
String__Global__push_str(&__sc127, (str){ .ptr = (const uint8_t*)"method '", .len = sizeof("method '") - 1 });
String__Global__push_str(&__sc127, utils__errors__span_str(typechecker__typechecker__TypeChecker__mod_src(self, iface.module), rn.start, rn.end));
String__Global__push_str(&__sc127, (str){ .ptr = (const uint8_t*)"' does not match interface signature", .len = sizeof("' does not match interface signature") - 1 });
__sc127; }));
      }
    }
  }
  const ast__ast__NodeList bounds = ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def.bounds;
  for (uint32_t i = 0U; i < bounds.len; i++) {
    const ast__ast__DefId sb = ast__ast__Ast__resolution_def(&((*ia)), ast__ast__Ast__list(&((*ia)), bounds)[((size_t)i)]);
    if ((sb.node != ast__ast__NODE_NONE) && (!typechecker__typechecker__TypeChecker__type_satisfies(self, self_ty, sb, 0))) {
      const lexer__token__Span at = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), extnode)->as_data.extend_def.interface_type)->span;
      utils__errors__Errors__emit(&self->errors, at.start, (at.end - at.start), ({ String__Global __sc128 = String__Global__new();
String__Global__push_str(&__sc128, (str){ .ptr = (const uint8_t*)"type does not satisfy required superinterface", .len = sizeof("type does not satisfy required superinterface") - 1 });
__sc128; }));
    }
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_extend_conformance(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  const ast__ast__DefId iface = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.extend_def.interface_type);
  if (iface.node == ast__ast__NODE_NONE) {
    return;
  }
  const uint32_t target = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.extend_def.target_type;
  const uint32_t self_ty = typechecker__typechecker__TypeChecker__resolve_type(self, target);
  typechecker__typechecker__Defs8 subp = (typechecker__typechecker__Defs8){0};
  typechecker__typechecker__Tys8 suba = (typechecker__typechecker__Tys8){0};
  int32_t nsub = 0;
  (subp.d[0] = (ast__ast__DefId){ .module = iface.module, .node = iface.node });
  (suba.t[0] = self_ty);
  (nsub = 1);
  ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, iface.module);
  const uint32_t itype = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.extend_def.interface_type;
  if ((ast__ast__Ast__at_const(&((*ia)), iface.node)->kind == ast__ast__NodeKind_NODE_INTERFACE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), itype)->kind == ast__ast__NodeKind_NODE_TYPE_PATH)) {
    const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*ia)), iface.node)->as_data.interface_def.generics;
    const ast__ast__NodeList targs = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), itype)->as_data.type_path.args;
    uint32_t i = 0U;
    while (((i < gens.len) && (i < targs.len)) && (nsub < 8)) {
      const uint32_t gid = ast__ast__Ast__list(&((*ia)), gens)[((size_t)i)];
      (subp.d[((size_t)nsub)] = (ast__ast__DefId){ .module = iface.module, .node = gid });
      (suba.t[((size_t)nsub)] = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), targs)[((size_t)i)]));
      (nsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nsub, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      (i = (i + 1U));
    }
  }
  typechecker__typechecker__TypeChecker__check_interface_requirements(self, id, iface, self_ty, ((const ast__ast__DefId *)(&subp.d[0])), ((const uint32_t *)(&suba.t[0])), nsub, 0);
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__method_recv_subst(typechecker__typechecker__TypeChecker *const self, uint32_t const recv, ast__ast__DefId const md, ast__ast__DefId *const rsubp, uint32_t *const rsuba) {
  int32_t nrsub = 0;
  uint16_t rmod = 0U;
  uint32_t rdecl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t sn = 0;
  const bool agok = typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, recv), ((uint16_t *)(&rmod)), ((uint32_t *)(&rdecl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&sn)));
  if (agok && (sn > 0)) {
    const uint32_t extnode = typechecker__typechecker__TypeChecker__enclosing_extend(self, md.module, md.node);
    if (extnode != ast__ast__NODE_NONE) {
      ast__ast__Ast *const ma = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
      const ast__ast__NodeList ig = ast__ast__Ast__at_const(&((*ma)), extnode)->as_data.extend_def.generics;
      int32_t g = ((int32_t)ig.len);
      if (sn < g) {
        (g = sn);
      }
      int32_t i = 0;
      while ((i < g) && (nrsub < 4)) {
        const uint32_t gid = ast__ast__Ast__list(&((*ma)), ig)[((size_t)i)];
        (rsubp[((size_t)nrsub)] = (ast__ast__DefId){ .module = md.module, .node = gid });
        (rsuba[((size_t)nrsub)] = ga.t[((size_t)i)]);
        (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (i = ({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
    }
  }
  return nrsub;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_method_ret(typechecker__typechecker__TypeChecker *const self, uint32_t const recv, ast__ast__DefId const md) {
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*fa)), md.node);
  if ((fnn->kind != ast__ast__NodeKind_NODE_FUNCTION) || (fnn->as_data.function.returns.len != 1U)) {
    return ast__ast__TYPE_NONE;
  }
  typechecker__typechecker__Defs4 rsubp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 rsuba = (typechecker__typechecker__Tys4){0};
  const int32_t nrsub = typechecker__typechecker__TypeChecker__method_recv_subst(self, recv, md, ((ast__ast__DefId *)(&rsubp.d[0])), ((uint32_t *)(&rsuba.t[0])));
  const uint32_t r0 = ast__ast__Ast__list(&((*fa)), fnn->as_data.function.returns)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*fa)), r0);
  const uint32_t ret = typechecker__typechecker__TypeChecker__lower_type_in(self, md.module, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0));
  return typechecker__typechecker__TypeChecker__subst_type(self, ret, ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub);
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_method_param(typechecker__typechecker__TypeChecker *const self, uint32_t const recv, ast__ast__DefId const md, int32_t const idx) {
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*fa)), md.node);
  if ((fnn->kind != ast__ast__NodeKind_NODE_FUNCTION) || (((int32_t)fnn->as_data.function.params.len) <= idx)) {
    return ast__ast__TYPE_NONE;
  }
  typechecker__typechecker__Defs4 rsubp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 rsuba = (typechecker__typechecker__Tys4){0};
  const int32_t nrsub = typechecker__typechecker__TypeChecker__method_recv_subst(self, recv, md, ((ast__ast__DefId *)(&rsubp.d[0])), ((uint32_t *)(&rsuba.t[0])));
  const uint32_t p = ast__ast__Ast__list(&((*fa)), fnn->as_data.function.params)[((size_t)idx)];
  const ast__ast__Node *const pn = ast__ast__Ast__at_const(&((*fa)), p);
  const uint32_t pt = typechecker__typechecker__TypeChecker__lower_type_in(self, md.module, typechecker__typechecker__if_node((pn->kind == ast__ast__NodeKind_NODE_PARAMETER), pn->as_data.parameter.ty, p));
  return typechecker__typechecker__TypeChecker__subst_type(self, pt, ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub);
}

static __attribute__((unused)) int32_t typechecker__typechecker__TypeChecker__method_self_kind(typechecker__typechecker__TypeChecker *const self, ast__ast__DefId const md) {
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*fa)), md.node);
  if ((fnn->kind != ast__ast__NodeKind_NODE_FUNCTION) || (fnn->as_data.function.params.len == 0U)) {
    return 0;
  }
  const uint32_t pt = typechecker__typechecker__TypeChecker__decl_type_in(self, md.module, ast__ast__Ast__list(&((*fa)), fnn->as_data.function.params)[0]);
  const ast__ast__Ty *const y = typechecker__typechecker__TypeChecker__type_at(self, pt);
  if ((y->kind != ast__ast__TypeKind_TYPE_REFERENCE) && (y->kind != ast__ast__TypeKind_TYPE_POINTER)) {
    return 0;
  }
  if (y->qualifier == 2U) {
    return 2;
  }
  return 1;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__operand_fits_param(typechecker__typechecker__TypeChecker *const self, uint32_t const pt, uint32_t const operand) {
  if ((pt == ast__ast__TYPE_NONE) || typechecker__typechecker__TypeChecker__compatible(self, pt, operand)) {
    return true;
  }
  const ast__ast__Ty p = (*typechecker__typechecker__TypeChecker__type_at(self, pt));
  return ((p.kind == ast__ast__TypeKind_TYPE_REFERENCE) && typechecker__typechecker__TypeChecker__compatible(self, p.as_data.elem, operand));
}

static __attribute__((unused)) str typechecker__typechecker__arith_method_name(lexer__token_type__TokenType const op) {
  if (op == lexer__token_type__TokenType_Plus) {
    return (str){ (const uint8_t *)"add", sizeof("add") - 1 };
  }
  if (op == lexer__token_type__TokenType_Minus) {
    return (str){ (const uint8_t *)"sub", sizeof("sub") - 1 };
  }
  if (op == lexer__token_type__TokenType_Star) {
    return (str){ (const uint8_t *)"mul", sizeof("mul") - 1 };
  }
  if (op == lexer__token_type__TokenType_Slash) {
    return (str){ (const uint8_t *)"div", sizeof("div") - 1 };
  }
  if (op == lexer__token_type__TokenType_Percent) {
    return (str){ (const uint8_t *)"rem", sizeof("rem") - 1 };
  }
  return (str){ (const uint8_t *)"", sizeof("") - 1 };
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_unary(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.op;
  const uint32_t operand = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.operand;
  const ast__ast__TypeQualifier qual = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.qualifier;
  if (op == lexer__token_type__TokenType_Ampersand) {
    (self->addr_ctx = true);
  }
  if (op == lexer__token_type__TokenType_Unsafe) {
    (self->unsafe_depth = (self->unsafe_depth + 1U));
  }
  const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
  const uint32_t opnd = typechecker__typechecker__TypeChecker__check_expr(self, operand);
  if (op == lexer__token_type__TokenType_Unsafe) {
    (self->unsafe_depth = (self->unsafe_depth - 1U));
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  if (op == lexer__token_type__TokenType_Minus) {
    if ((opnd != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_numeric(self, opnd))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc129 = String__Global__new();
String__Global__push_str(&__sc129, (str){ .ptr = (const uint8_t*)"unary '-' requires a numeric operand", .len = sizeof("unary '-' requires a numeric operand") - 1 });
__sc129; }));
    }
    return opnd;
  }
  if (op == lexer__token_type__TokenType_Bang) {
    if ((opnd != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, opnd))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc130 = String__Global__new();
String__Global__push_str(&__sc130, (str){ .ptr = (const uint8_t*)"unary '!' requires a 'bool' operand", .len = sizeof("unary '!' requires a 'bool' operand") - 1 });
__sc130; }));
    }
    return 1U;
  }
  if (op == lexer__token_type__TokenType_Tilde) {
    if ((opnd != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_int(self, opnd))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc131 = String__Global__new();
String__Global__push_str(&__sc131, (str){ .ptr = (const uint8_t*)"unary '~' requires an integer operand", .len = sizeof("unary '~' requires an integer operand") - 1 });
__sc131; }));
    }
    return opnd;
  }
  if (op == lexer__token_type__TokenType_Star) {
    if (opnd == ast__ast__TYPE_NONE) {
      return ast__ast__TYPE_NONE;
    }
    const ast__ast__Ty ot = (*typechecker__typechecker__TypeChecker__type_at(self, opnd));
    if ((ot.kind == ast__ast__TypeKind_TYPE_POINTER) || (ot.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
      if ((ot.kind == ast__ast__TypeKind_TYPE_POINTER) && (self->unsafe_depth == 0U)) {
        typechecker__typechecker__TypeChecker__err_unsafe(self, sp, (str){ (const uint8_t *)"dereferencing a raw pointer", sizeof("dereferencing a raw pointer") - 1 });
      }
      if (!typechecker__typechecker__TypeChecker__is_place(self, operand)) {
        uint32_t i = bm;
        while (i < self->nborrows) {
          if ((self->borrows[((size_t)i)].binding == ast__ast__NODE_NONE) && (self->borrows[((size_t)i)].kind == typechecker__typechecker__BORROW_SHARED)) {
            typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, i);
          }
          (i = (i + 1U));
        }
      }
      return ot.as_data.elem;
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc132 = String__Global__new();
String__Global__push_str(&__sc132, (str){ .ptr = (const uint8_t*)"cannot dereference a non-pointer", .len = sizeof("cannot dereference a non-pointer") - 1 });
__sc132; }));
    return ast__ast__TYPE_NONE;
  }
  if (op == lexer__token_type__TokenType_Ampersand) {
    const bool mut2 = (qual == ast__ast__TypeQualifier_TYPE_QUAL_MUT);
    if ((mut2 && typechecker__typechecker__TypeChecker__is_place(self, operand)) && (!typechecker__typechecker__TypeChecker__is_assignable(self, operand))) {
      const lexer__token__Span osp = ast__ast__Ast__at_const(&((*a)), operand)->span;
      utils__errors__Errors__emit(&self->errors, osp.start, (osp.end - osp.start), ({ String__Global __sc133 = String__Global__new();
String__Global__push_str(&__sc133, (str){ .ptr = (const uint8_t*)"cannot take '&mut' of an immutable binding (bind it with 'mut')", .len = sizeof("cannot take '&mut' of an immutable binding (bind it with 'mut')") - 1 });
__sc133; }));
    }
    if (mut2) {
      typechecker__typechecker__TypeChecker__tc_mark_capture_mut(self, operand);
    }
    uint32_t opw = operand;
    for (;;) {
      const ast__ast__Node *const onn = ast__ast__Ast__at_const(&((*a)), opw);
      if ((onn->kind == ast__ast__NodeKind_NODE_UNARY) && ((onn->as_data.unary.op == lexer__token_type__TokenType_Move) || (onn->as_data.unary.op == lexer__token_type__TokenType_Unsafe))) {
        (opw = onn->as_data.unary.operand);
      } else {
        break;
      }
    }
    const ast__ast__NodeKind onk = ast__ast__Ast__at_const(&((*a)), opw)->kind;
    if (mut2 && (onk == ast__ast__NodeKind_NODE_IDENTIFIER)) {
      const ast__ast__DefId od = ast__ast__Ast__resolution_def(&((*a)), opw);
      if ((od.module == self->ast.module) && (od.node != ast__ast__NODE_NONE)) {
        typechecker__typechecker__TypeChecker__tc_init(self, od.node);
      }
    }
    if ((((!typechecker__typechecker__TypeChecker__is_place(self, opw)) && (opnd != ast__ast__TYPE_NONE)) && (typechecker__typechecker__TypeChecker__type_at(self, opnd)->kind != ast__ast__TypeKind_TYPE_BUILTIN)) && (((((((onk == ast__ast__NodeKind_NODE_CALL) || (onk == ast__ast__NodeKind_NODE_IF)) || (onk == ast__ast__NodeKind_NODE_MATCH)) || (onk == ast__ast__NodeKind_NODE_BLOCK)) || (onk == ast__ast__NodeKind_NODE_BINARY)) || (onk == ast__ast__NodeKind_NODE_ASSIGNMENT)) || (onk == ast__ast__NodeKind_NODE_CAST))) {
      const lexer__token__Span osp = ast__ast__Ast__at_const(&((*a)), opw)->span;
      utils__errors__Errors__emit(&self->errors, osp.start, (osp.end - osp.start), ({ String__Global __sc134 = String__Global__new();
String__Global__push_str(&__sc134, (str){ .ptr = (const uint8_t*)"cannot take the address of a temporary value; bind it to a 'let' first", .len = sizeof("cannot take the address of a temporary value; bind it to a 'let' first") - 1 });
__sc134; }));
    }
    uint8_t bk = typechecker__typechecker__BORROW_SHARED;
    if (mut2) {
      (bk = typechecker__typechecker__BORROW_MUT);
    }
    typechecker__typechecker__TypeChecker__borrow_create(self, operand, bk, id);
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_REFERENCE, .qualifier = ((uint8_t)qual), .as_data = (ast__ast__TyAs){ .elem = opnd } });
  }
  if (op == lexer__token_type__TokenType_Question) {
    if (opnd == ast__ast__TYPE_NONE) {
      return ast__ast__TYPE_NONE;
    }
    const uint32_t os = typechecker__typechecker__TypeChecker__strip(self, opnd);
    typechecker__typechecker__Tys4 oa = (typechecker__typechecker__Tys4){0};
    typechecker__typechecker__Tys4 fa = (typechecker__typechecker__Tys4){0};
    const int32_t nopt = typechecker__typechecker__TypeChecker__prelude_instance_args(self, os, (str){ (const uint8_t *)"Option", sizeof("Option") - 1 }, ((uint32_t *)(&oa.t[0])), 2);
    int32_t nres = -1;
    if (nopt < 0) {
      (nres = typechecker__typechecker__TypeChecker__prelude_instance_args(self, os, (str){ (const uint8_t *)"Result", sizeof("Result") - 1 }, ((uint32_t *)(&oa.t[0])), 2));
    }
    if ((nopt < 0) && (nres < 0)) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc135 = String__Global__new();
String__Global__push_str(&__sc135, (str){ .ptr = (const uint8_t*)"'?' requires an Option or Result operand", .len = sizeof("'?' requires an Option or Result operand") - 1 });
__sc135; }));
      utils__errors__Errors__note(&self->errors, ({ String__Global __sc136 = String__Global__new();
String__Global__push_str(&__sc136, (str){ .ptr = (const uint8_t*)"the operand must be an Option<T> or Result<T, E> value", .len = sizeof("the operand must be an Option<T> or Result<T, E> value") - 1 });
__sc136; }));
      return ast__ast__TYPE_NONE;
    }
    uint32_t fnret = ast__ast__TYPE_NONE;
    if (self->current_returns.len == 1U) {
      const uint32_t r0 = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), self->current_returns)[0];
      const ast__ast__Node *const rnn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), r0);
      (fnret = typechecker__typechecker__TypeChecker__resolve_type(self, typechecker__typechecker__if_node((rnn->kind == ast__ast__NodeKind_NODE_PARAMETER), rnn->as_data.parameter.ty, r0)));
    }
    uint32_t frs = ast__ast__TYPE_NONE;
    if (fnret != ast__ast__TYPE_NONE) {
      (frs = typechecker__typechecker__TypeChecker__strip(self, fnret));
    }
    if (nopt >= 0) {
      if (typechecker__typechecker__TypeChecker__prelude_instance_args(self, frs, (str){ (const uint8_t *)"Option", sizeof("Option") - 1 }, ((uint32_t *)(&fa.t[0])), 2) < 0) {
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc137 = String__Global__new();
String__Global__push_str(&__sc137, (str){ .ptr = (const uint8_t*)"'?' on an Option requires the function to return an Option", .len = sizeof("'?' on an Option requires the function to return an Option") - 1 });
__sc137; }));
        utils__errors__Errors__note(&self->errors, ({ String__Global __sc138 = String__Global__new();
String__Global__push_str(&__sc138, (str){ .ptr = (const uint8_t*)"change the function return type or handle None explicitly", .len = sizeof("change the function return type or handle None explicitly") - 1 });
__sc138; }));
      }
      return oa.t[0];
    }
    if (typechecker__typechecker__TypeChecker__prelude_instance_args(self, frs, (str){ (const uint8_t *)"Result", sizeof("Result") - 1 }, ((uint32_t *)(&fa.t[0])), 2) < 0) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc139 = String__Global__new();
String__Global__push_str(&__sc139, (str){ .ptr = (const uint8_t*)"'?' on a Result requires the function to return a Result", .len = sizeof("'?' on a Result requires the function to return a Result") - 1 });
__sc139; }));
      utils__errors__Errors__note(&self->errors, ({ String__Global __sc140 = String__Global__new();
String__Global__push_str(&__sc140, (str){ .ptr = (const uint8_t*)"the function must return Result<_, E> with the same error type", .len = sizeof("the function must return Result<_, E> with the same error type") - 1 });
__sc140; }));
    } else if (oa.t[1] != fa.t[1]) {
      const ast__ast__DefId conv = typechecker__typechecker__TypeChecker__tc_find_from_for(self, fa.t[1], oa.t[1]);
      if (conv.node != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, conv);
      } else {
        typechecker__typechecker__Buf96 a1 = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__Buf96 a2 = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, oa.t[1], ((char *)(&a1.b[0])), 96ULL);
        typechecker__typechecker__TypeChecker__render_type(self, fa.t[1], ((char *)(&a2.b[0])), 96ULL);
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc141 = String__Global__new();
String__Global__push_str(&__sc141, (str){ .ptr = (const uint8_t*)"'?' error type '", .len = sizeof("'?' error type '") - 1 });
String__Global__push_str(&__sc141, utils__errors__cstr(((const char *)(&a1.b[0]))));
String__Global__push_str(&__sc141, (str){ .ptr = (const uint8_t*)"' does not match the function's error type '", .len = sizeof("' does not match the function's error type '") - 1 });
String__Global__push_str(&__sc141, utils__errors__cstr(((const char *)(&a2.b[0]))));
String__Global__push_str(&__sc141, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc141; }));
      }
    }
    return oa.t[0];
  }
  return opnd;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__binary_numeric(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const l, uint32_t const ln, uint32_t const r, uint32_t const rn, bool const require_int) {
  if ((l == ast__ast__TYPE_NONE) || (r == ast__ast__TYPE_NONE)) {
    return ast__ast__TYPE_NONE;
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
  bool ok = (typechecker__typechecker__TypeChecker__is_numeric(self, l) && typechecker__typechecker__TypeChecker__is_numeric(self, r));
  if (require_int) {
    (ok = (typechecker__typechecker__TypeChecker__is_int(self, l) && typechecker__typechecker__TypeChecker__is_int(self, r)));
  }
  if (!ok) {
    const char *w = ((const char *)({ __auto_type __sc142 = (str){ (const uint8_t *)"numeric", sizeof("numeric") - 1 }; str__ptr(&__sc142); }));
    if (require_int) {
      (w = ((const char *)({ __auto_type __sc143 = (str){ (const uint8_t *)"integer", sizeof("integer") - 1 }; str__ptr(&__sc143); })));
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc144 = String__Global__new();
String__Global__push_str(&__sc144, (str){ .ptr = (const uint8_t*)"operator requires ", .len = sizeof("operator requires ") - 1 });
String__Global__push_str(&__sc144, utils__errors__cstr(w));
String__Global__push_str(&__sc144, (str){ .ptr = (const uint8_t*)" operands", .len = sizeof(" operands") - 1 });
__sc144; }));
    return ast__ast__TYPE_NONE;
  }
  if (l == r) {
    return l;
  }
  if ((ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ln)->kind == ast__ast__NodeKind_NODE_LITERAL) && (!typechecker__typechecker__TypeChecker__tc_literal_pinned(self, ln))) {
    if (typechecker__typechecker__TypeChecker__is_int(self, r)) {
      uint64_t mag = 0ULL;
      const bool got = typechecker__typechecker__TypeChecker__lit_mag(self, ln, ((uint64_t *)(&mag)));
      const ast__ast__BuiltinType rb = typechecker__typechecker__TypeChecker__type_at(self, r)->as_data.builtin;
      if (got && (!typechecker__typechecker__tc_lit_in_range(rb, mag, false))) {
        typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, r, ((char *)(&tn.b[0])), 96ULL);
        const lexer__token__Span lsp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ln)->span;
        utils__errors__Errors__emit(&self->errors, lsp.start, (lsp.end - lsp.start), ({ String__Global __sc145 = String__Global__new();
String__Global__push_str(&__sc145, (str){ .ptr = (const uint8_t*)"integer literal is out of range for '", .len = sizeof("integer literal is out of range for '") - 1 });
String__Global__push_str(&__sc145, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc145, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc145; }));
      } else {
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ln, r);
      }
    }
    return r;
  }
  if ((ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), rn)->kind == ast__ast__NodeKind_NODE_LITERAL) && (!typechecker__typechecker__TypeChecker__tc_literal_pinned(self, rn))) {
    if (typechecker__typechecker__TypeChecker__is_int(self, l)) {
      uint64_t mag = 0ULL;
      const bool got = typechecker__typechecker__TypeChecker__lit_mag(self, rn, ((uint64_t *)(&mag)));
      const ast__ast__BuiltinType lb = typechecker__typechecker__TypeChecker__type_at(self, l)->as_data.builtin;
      if (got && (!typechecker__typechecker__tc_lit_in_range(lb, mag, false))) {
        typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, l, ((char *)(&tn.b[0])), 96ULL);
        const lexer__token__Span rsp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), rn)->span;
        utils__errors__Errors__emit(&self->errors, rsp.start, (rsp.end - rsp.start), ({ String__Global __sc146 = String__Global__new();
String__Global__push_str(&__sc146, (str){ .ptr = (const uint8_t*)"integer literal is out of range for '", .len = sizeof("integer literal is out of range for '") - 1 });
String__Global__push_str(&__sc146, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc146, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc146; }));
      } else {
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), rn, l);
      }
    }
    return l;
  }
  if (typechecker__typechecker__bt_widens(typechecker__typechecker__TypeChecker__bt_of(self, l), typechecker__typechecker__TypeChecker__bt_of(self, r))) {
    return r;
  }
  if (typechecker__typechecker__bt_widens(typechecker__typechecker__TypeChecker__bt_of(self, r), typechecker__typechecker__TypeChecker__bt_of(self, l))) {
    return l;
  }
  typechecker__typechecker__TypeChecker__err_mismatch(self, rn, l);
  return l;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_ptr_arith(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const l, uint32_t const r, bool *const handled) {
  ((*handled) = false);
  if ((l == ast__ast__TYPE_NONE) || (r == ast__ast__TYPE_NONE)) {
    return ast__ast__TYPE_NONE;
  }
  const bool lp = (typechecker__typechecker__TypeChecker__type_at(self, l)->kind == ast__ast__TypeKind_TYPE_POINTER);
  const bool rp = (typechecker__typechecker__TypeChecker__type_at(self, r)->kind == ast__ast__TypeKind_TYPE_POINTER);
  if ((!lp) && (!rp)) {
    return ast__ast__TYPE_NONE;
  }
  ((*handled) = true);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
  if (self->unsafe_depth == 0U) {
    typechecker__typechecker__TypeChecker__err_unsafe(self, sp, (str){ (const uint8_t *)"raw pointer arithmetic", sizeof("raw pointer arithmetic") - 1 });
  }
  const bool minus = (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.binary.op == lexer__token_type__TokenType_Minus);
  if (lp && rp) {
    if (minus && (l == r)) {
      return 7U;
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc147 = String__Global__new();
String__Global__push_str(&__sc147, (str){ .ptr = (const uint8_t*)"invalid pointer arithmetic", .len = sizeof("invalid pointer arithmetic") - 1 });
__sc147; }));
    return ast__ast__TYPE_NONE;
  }
  if (lp && typechecker__typechecker__TypeChecker__is_int(self, r)) {
    return l;
  }
  if ((rp && (!minus)) && typechecker__typechecker__TypeChecker__is_int(self, l)) {
    return r;
  }
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc148 = String__Global__new();
String__Global__push_str(&__sc148, (str){ .ptr = (const uint8_t*)"pointer arithmetic requires an integer offset", .len = sizeof("pointer arithmetic requires an integer offset") - 1 });
__sc148; }));
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__check_arith_overload(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const l, uint32_t *const out) {
  const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.binary.op;
  const str m = typechecker__typechecker__arith_method_name(op);
  if (str__len(&m) == 0ULL) {
    return false;
  }
  uint32_t ls = l;
  while ((ls != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    (ls = typechecker__typechecker__TypeChecker__type_at(self, ls)->as_data.elem);
  }
  if ((ls != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_POINTER)) {
    return false;
  }
  if (ls == ast__ast__TYPE_NONE) {
    return false;
  }
  const ast__ast__Ty lt = (*typechecker__typechecker__TypeChecker__type_at(self, ls));
  const uint32_t right = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.binary.right;
  if (lt.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    if (!typechecker__typechecker__TypeChecker__tc_param_bound_provides(self, lt.module, lt.as_data.decl, m)) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
      typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
      typechecker__typechecker__TypeChecker__render_type(self, ls, ((char *)(&ty.b[0])), 96ULL);
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc149 = String__Global__new();
String__Global__push_str(&__sc149, (str){ .ptr = (const uint8_t*)"type parameter '", .len = sizeof("type parameter '") - 1 });
String__Global__push_str(&__sc149, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc149, (str){ .ptr = (const uint8_t*)"' has no '", .len = sizeof("' has no '") - 1 });
String__Global__push_str(&__sc149, m);
String__Global__push_str(&__sc149, (str){ .ptr = (const uint8_t*)"' method for this operator (add a bound that provides it)", .len = sizeof("' method for this operator (add a bound that provides it)") - 1 });
__sc149; }));
      ((*out) = ast__ast__TYPE_NONE);
    }
    return true;
  }
  if ((lt.kind != ast__ast__TypeKind_TYPE_STRUCT) && (lt.kind != ast__ast__TypeKind_TYPE_INSTANCE)) {
    return false;
  }
  uint16_t om = 0U;
  uint32_t od = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  ((*out) = ls);
  if (typechecker__typechecker__TypeChecker__aggregate_of(self, ls, ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    const ast__ast__DefId md = typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, m);
    if (md.node == ast__ast__NODE_NONE) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
      typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
      typechecker__typechecker__TypeChecker__render_type(self, ls, ((char *)(&ty.b[0])), 96ULL);
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc150 = String__Global__new();
String__Global__push_str(&__sc150, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc150, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc150, (str){ .ptr = (const uint8_t*)"' has no '", .len = sizeof("' has no '") - 1 });
String__Global__push_str(&__sc150, m);
String__Global__push_str(&__sc150, (str){ .ptr = (const uint8_t*)"' method for this operator", .len = sizeof("' method for this operator") - 1 });
__sc150; }));
      ((*out) = ast__ast__TYPE_NONE);
    } else {
      if (!typechecker__typechecker__TypeChecker__method_extend_bounds_hold(self, ls, md)) {
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
        typechecker__typechecker__TypeChecker__err_method_extend_bounds(self, sp, ls, md);
        ((*out) = ast__ast__TYPE_NONE);
        return true;
      }
      const uint32_t p1 = typechecker__typechecker__TypeChecker__tc_method_param(self, ls, md, 1);
      if (!typechecker__typechecker__TypeChecker__operand_fits_param(self, p1, right)) {
        typechecker__typechecker__TypeChecker__err_mismatch(self, right, p1);
      }
      const uint32_t ret = typechecker__typechecker__TypeChecker__tc_method_ret(self, ls, md);
      if (ret != ast__ast__TYPE_NONE) {
        ((*out) = ret);
      }
    }
  }
  return true;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_binary(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*a)), id)->as_data.binary;
  const uint32_t ln = bd.left;
  const uint32_t rn = bd.right;
  const lexer__token_type__TokenType op = bd.op;
  const uint32_t l = typechecker__typechecker__TypeChecker__check_expr(self, ln);
  const uint32_t r = typechecker__typechecker__TypeChecker__check_expr(self, rn);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  if ((op == lexer__token_type__TokenType_Plus) || (op == lexer__token_type__TokenType_Minus)) {
    uint32_t ov = ast__ast__TYPE_NONE;
    if (typechecker__typechecker__TypeChecker__check_arith_overload(self, id, l, ((uint32_t *)(&ov)))) {
      return ov;
    }
    bool handled = false;
    const uint32_t pt = typechecker__typechecker__TypeChecker__check_ptr_arith(self, id, l, r, ((bool *)(&handled)));
    if (handled) {
      return pt;
    }
    return typechecker__typechecker__TypeChecker__binary_numeric(self, id, l, ln, r, rn, false);
  }
  if (((op == lexer__token_type__TokenType_Star) || (op == lexer__token_type__TokenType_Slash)) || (op == lexer__token_type__TokenType_Percent)) {
    uint32_t ov = ast__ast__TYPE_NONE;
    if (typechecker__typechecker__TypeChecker__check_arith_overload(self, id, l, ((uint32_t *)(&ov)))) {
      return ov;
    }
    return typechecker__typechecker__TypeChecker__binary_numeric(self, id, l, ln, r, rn, false);
  }
  if (((((op == lexer__token_type__TokenType_Ampersand) || (op == lexer__token_type__TokenType_Pipe)) || (op == lexer__token_type__TokenType_Caret)) || (op == lexer__token_type__TokenType_LeftShift)) || (op == lexer__token_type__TokenType_RightShift)) {
    return typechecker__typechecker__TypeChecker__binary_numeric(self, id, l, ln, r, rn, true);
  }
  if ((op == lexer__token_type__TokenType_AmpersandAmpersand) || (op == lexer__token_type__TokenType_PipePipe)) {
    if (((l != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, l))) || ((r != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, r)))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc151 = String__Global__new();
String__Global__push_str(&__sc151, (str){ .ptr = (const uint8_t*)"logical operator requires 'bool' operands", .len = sizeof("logical operator requires 'bool' operands") - 1 });
__sc151; }));
    }
    return 1U;
  }
  const bool ord = ((((op == lexer__token_type__TokenType_LessThan) || (op == lexer__token_type__TokenType_LessThanEqual)) || (op == lexer__token_type__TokenType_GreaterThan)) || (op == lexer__token_type__TokenType_GreaterThanEqual));
  uint32_t ls = l;
  while ((ls != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    (ls = typechecker__typechecker__TypeChecker__type_at(self, ls)->as_data.elem);
  }
  if ((ls != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_POINTER)) {
    if (((((l != ast__ast__TYPE_NONE) && (r != ast__ast__TYPE_NONE)) && (l != r)) && (!typechecker__typechecker__TypeChecker__compatible(self, l, rn))) && (!typechecker__typechecker__TypeChecker__compatible(self, r, ln))) {
      typechecker__typechecker__TypeChecker__err_mismatch(self, rn, l);
    }
    return 1U;
  }
  if ((ls != ast__ast__TYPE_NONE) && ((typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_STRUCT) || (typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_INSTANCE))) {
    uint16_t om = 0U;
    uint32_t od = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    if (typechecker__typechecker__TypeChecker__aggregate_of(self, ls, ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
      str mm = (str){ (const uint8_t *)"eq", sizeof("eq") - 1 };
      if (ord) {
        (mm = (str){ (const uint8_t *)"cmp", sizeof("cmp") - 1 });
      }
      const ast__ast__DefId md = typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, mm);
      if (md.node == ast__ast__NODE_NONE) {
        typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, ls, ((char *)(&ty.b[0])), 96ULL);
        const char *iface = ((const char *)({ __auto_type __sc152 = (str){ (const uint8_t *)"Eq", sizeof("Eq") - 1 }; str__ptr(&__sc152); }));
        if (ord) {
          (iface = ((const char *)({ __auto_type __sc153 = (str){ (const uint8_t *)"Ord", sizeof("Ord") - 1 }; str__ptr(&__sc153); })));
        }
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc154 = String__Global__new();
String__Global__push_str(&__sc154, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc154, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc154, (str){ .ptr = (const uint8_t*)"' has no '", .len = sizeof("' has no '") - 1 });
String__Global__push_str(&__sc154, mm);
String__Global__push_str(&__sc154, (str){ .ptr = (const uint8_t*)"' method for this operator (implement ", .len = sizeof("' method for this operator (implement ") - 1 });
String__Global__push_str(&__sc154, utils__errors__cstr(iface));
String__Global__push_str(&__sc154, (str){ .ptr = (const uint8_t*)")", .len = sizeof(")") - 1 });
__sc154; }));
        utils__errors__Errors__note(&self->errors, ({ String__Global __sc155 = String__Global__new();
String__Global__push_str(&__sc155, (str){ .ptr = (const uint8_t*)"operator overloads are resolved through interface-style methods", .len = sizeof("operator overloads are resolved through interface-style methods") - 1 });
__sc155; }));
      } else if (!typechecker__typechecker__TypeChecker__method_extend_bounds_hold(self, ls, md)) {
        typechecker__typechecker__TypeChecker__err_method_extend_bounds(self, sp, ls, md);
      } else {
        const uint32_t p1 = typechecker__typechecker__TypeChecker__tc_method_param(self, ls, md, 1);
        if (!typechecker__typechecker__TypeChecker__operand_fits_param(self, p1, rn)) {
          typechecker__typechecker__TypeChecker__err_mismatch(self, rn, p1);
        }
      }
    }
    return 1U;
  }
  if ((ls != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, ls)->kind == ast__ast__TypeKind_TYPE_GENERIC)) {
    const ast__ast__Ty gy = (*typechecker__typechecker__TypeChecker__type_at(self, ls));
    str mm = (str){ (const uint8_t *)"eq", sizeof("eq") - 1 };
    if (ord) {
      (mm = (str){ (const uint8_t *)"cmp", sizeof("cmp") - 1 });
    }
    if (!typechecker__typechecker__TypeChecker__tc_param_bound_provides(self, gy.module, gy.as_data.decl, mm)) {
      const char *iface = ((const char *)({ __auto_type __sc156 = (str){ (const uint8_t *)"Eq", sizeof("Eq") - 1 }; str__ptr(&__sc156); }));
      if (ord) {
        (iface = ((const char *)({ __auto_type __sc157 = (str){ (const uint8_t *)"Ord", sizeof("Ord") - 1 }; str__ptr(&__sc157); })));
      }
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc158 = String__Global__new();
String__Global__push_str(&__sc158, (str){ .ptr = (const uint8_t*)"type parameter has no '", .len = sizeof("type parameter has no '") - 1 });
String__Global__push_str(&__sc158, mm);
String__Global__push_str(&__sc158, (str){ .ptr = (const uint8_t*)"' method for this operator (add a `", .len = sizeof("' method for this operator (add a `") - 1 });
String__Global__push_str(&__sc158, utils__errors__cstr(iface));
String__Global__push_str(&__sc158, (str){ .ptr = (const uint8_t*)"` bound)", .len = sizeof("` bound)") - 1 });
__sc158; }));
    }
    return 1U;
  }
  if (((((l != ast__ast__TYPE_NONE) && (r != ast__ast__TYPE_NONE)) && (l != r)) && (!typechecker__typechecker__TypeChecker__compatible(self, l, rn))) && (!typechecker__typechecker__TypeChecker__compatible(self, r, ln))) {
    typechecker__typechecker__TypeChecker__err_mismatch(self, rn, l);
  }
  return 1U;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_variant_call(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint16_t const vmod, uint32_t const variant, uint32_t const enum_ty) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*a)), id)->as_data.call.args;
  for (uint32_t i = 0U; i < args.len; i++) {
    typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[((size_t)i)]);
  }
  ast__ast__Ast *const va = typechecker__typechecker__TypeChecker__mod_ast(self, vmod);
  const ast__ast__NodeList payload = ast__ast__Ast__at_const(&((*va)), variant)->as_data.variant.payload;
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  uint16_t amod = 0U;
  uint32_t adecl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  const bool inst = typechecker__typechecker__TypeChecker__aggregate_of(self, enum_ty, ((uint16_t *)(&amod)), ((uint32_t *)(&adecl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
  if (args.len != payload.len) {
    const char *s2 = ((const char *)({ __auto_type __sc159 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc159); }));
    if (payload.len == 1U) {
      (s2 = ((const char *)({ __auto_type __sc160 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc160); })));
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc161 = String__Global__new();
String__Global__push_str(&__sc161, (str){ .ptr = (const uint8_t*)"variant expects ", .len = sizeof("variant expects ") - 1 });
String__Global__push_u64(&__sc161, (uint64_t)(payload.len));
String__Global__push_str(&__sc161, (str){ .ptr = (const uint8_t*)" argument", .len = sizeof(" argument") - 1 });
String__Global__push_str(&__sc161, utils__errors__cstr(s2));
String__Global__push_str(&__sc161, (str){ .ptr = (const uint8_t*)", found ", .len = sizeof(", found ") - 1 });
String__Global__push_u64(&__sc161, (uint64_t)(args.len));
__sc161; }));
  } else {
    for (uint32_t k = 0U; k < args.len; k++) {
      const uint32_t pid = ast__ast__Ast__list(&((*va)), payload)[((size_t)k)];
      const ast__ast__Node *const pe = ast__ast__Ast__at_const(&((*va)), pid);
      const uint32_t raw = typechecker__typechecker__TypeChecker__lower_type_in(self, vmod, typechecker__typechecker__if_node((pe->kind == ast__ast__NodeKind_NODE_FIELD), pe->as_data.field.ty, pid));
      uint32_t pt = raw;
      if (inst) {
        (pt = typechecker__typechecker__TypeChecker__subst_type(self, raw, ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn));
      }
      const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)k)];
      if (!typechecker__typechecker__TypeChecker__compatible(self, pt, aid)) {
        typechecker__typechecker__TypeChecker__err_mismatch(self, aid, pt);
      }
    }
  }
  return enum_ty;
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_is_iface_assoc_call(const typechecker__typechecker__TypeChecker *const self, uint32_t const e) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__Node *const en = ast__ast__Ast__at_const(&((*a)), e);
  if (en->kind != ast__ast__NodeKind_NODE_CALL) {
    return false;
  }
  const ast__ast__Node *const cn = ast__ast__Ast__at_const(&((*a)), en->as_data.call.callee);
  if ((cn->kind != ast__ast__NodeKind_NODE_MEMBER) || (!cn->as_data.member.path)) {
    return false;
  }
  const ast__ast__DefId ob = ast__ast__Ast__resolution_def(&((*a)), cn->as_data.member.object);
  return (((ob.node != ast__ast__NODE_NONE) && ((ob.module == self->ast.module) || ((self->package != NULL) && (((size_t)ob.module) < typechecker__typechecker__TypeChecker__pkg_count(self))))) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ob.module))), ob.node)->kind == ast__ast__NodeKind_NODE_INTERFACE));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_param_expected(typechecker__typechecker__TypeChecker *const self, uint32_t const callee, uint32_t const callee_node, uint32_t const argi) {
  if (callee == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Ty ct = (*typechecker__typechecker__TypeChecker__type_at(self, callee));
  if (ct.kind != ast__ast__TypeKind_TYPE_FUNCTION) {
    return ast__ast__TYPE_NONE;
  }
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, ct.module);
  const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*fa)), ct.as_data.decl);
  if (fnn->kind != ast__ast__NodeKind_NODE_FUNCTION) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__Node *const cnn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), callee_node);
  uint32_t skip = 0U;
  if (((cnn->kind == ast__ast__NodeKind_NODE_MEMBER) && (!cnn->as_data.member.path)) && (fnn->as_data.function.params.len > 0U)) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), cnn->as_data.member.member);
    if ((md.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
      (skip = 1U);
    }
  }
  if ((argi + skip) >= fnn->as_data.function.params.len) {
    return ast__ast__TYPE_NONE;
  }
  uint32_t pt = typechecker__typechecker__TypeChecker__decl_type_in(self, ct.module, ast__ast__Ast__list(&((*fa)), fnn->as_data.function.params)[((size_t)(argi + skip))]);
  if ((pt != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, pt)->kind == ast__ast__TypeKind_TYPE_GENERIC)) {
    const ast__ast__Ty g = (*typechecker__typechecker__TypeChecker__type_at(self, pt));
    const uint32_t fb = typechecker__typechecker__TypeChecker__generic_fn_bound(self, g.module, g.as_data.decl);
    if (fb != ast__ast__NODE_NONE) {
      (pt = typechecker__typechecker__TypeChecker__lower_type_in(self, ct.module, fb));
    }
  }
  if (((pt != ast__ast__TYPE_NONE) && (!ast__ast__Ast__type_concrete(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), pt))) && (skip != 0U)) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), cnn->as_data.member.member);
    uint32_t extnode = ast__ast__NODE_NONE;
    if (md.node != ast__ast__NODE_NONE) {
      (extnode = typechecker__typechecker__TypeChecker__enclosing_extend(self, md.module, md.node));
    }
    uint16_t rm = 0U;
    uint32_t rd = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    const bool agok = ((extnode != ast__ast__NODE_NONE) && typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), cnn->as_data.member.object)), ((uint16_t *)(&rm)), ((uint32_t *)(&rd)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn))));
    if (agok && (gn > 0)) {
      ast__ast__Ast *const ma = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
      const ast__ast__NodeList ig = ast__ast__Ast__at_const(&((*ma)), extnode)->as_data.extend_def.generics;
      typechecker__typechecker__Defs4 sp2 = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 sa = (typechecker__typechecker__Tys4){0};
      int32_t ns = 0;
      uint32_t i = 0U;
      while (((i < ig.len) && (((int32_t)i) < gn)) && (ns < 4)) {
        const uint32_t gid = ast__ast__Ast__list(&((*ma)), ig)[((size_t)i)];
        (sp2.d[((size_t)ns)] = (ast__ast__DefId){ .module = md.module, .node = gid });
        (sa.t[((size_t)ns)] = ga.t[((size_t)i)]);
        (ns = ({ int32_t __sc_r; if (__builtin_add_overflow(ns, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (i = (i + 1U));
      }
      (pt = typechecker__typechecker__TypeChecker__subst_type(self, pt, ((const ast__ast__DefId *)(&sp2.d[0])), ((const uint32_t *)(&sa.t[0])), ns));
    }
  }
  if ((pt != ast__ast__TYPE_NONE) && ast__ast__Ast__type_concrete(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), pt)) {
    return pt;
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__iter_elem_type(typechecker__typechecker__TypeChecker *const self, uint32_t const it) {
  uint16_t im = 0U;
  uint32_t idl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (!typechecker__typechecker__TypeChecker__aggregate_of(self, it, ((uint16_t *)(&im)), ((uint32_t *)(&idl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    return ast__ast__TYPE_NONE;
  }
  const ast__ast__DefId nx = typechecker__typechecker__TypeChecker__find_method_cstr(self, im, idl, (str){ (const uint8_t *)"next", sizeof("next") - 1 });
  if (nx.node == ast__ast__NODE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  ast__ast__Ast *const na = typechecker__typechecker__TypeChecker__mod_ast(self, nx.module);
  const ast__ast__NodeList rets = ast__ast__Ast__at_const(&((*na)), nx.node)->as_data.function.returns;
  if (rets.len != 1U) {
    return ast__ast__TYPE_NONE;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*na)), rets)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*na)), r0);
  uint32_t ret = typechecker__typechecker__TypeChecker__lower_type_in(self, nx.module, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0));
  const uint32_t extnode = typechecker__typechecker__TypeChecker__enclosing_extend(self, nx.module, nx.node);
  if ((extnode != ast__ast__NODE_NONE) && (gn > 0)) {
    const ast__ast__NodeList ig = ast__ast__Ast__at_const(&((*na)), extnode)->as_data.extend_def.generics;
    typechecker__typechecker__Defs4 ip = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ia = (typechecker__typechecker__Tys4){0};
    int32_t in2 = 0;
    uint32_t i = 0U;
    while (((i < ig.len) && (((int32_t)i) < gn)) && (in2 < 4)) {
      const uint32_t gid = ast__ast__Ast__list(&((*na)), ig)[((size_t)i)];
      (ip.d[((size_t)in2)] = (ast__ast__DefId){ .module = nx.module, .node = gid });
      (ia.t[((size_t)in2)] = ga.t[((size_t)i)]);
      (in2 = ({ int32_t __sc_r; if (__builtin_add_overflow(in2, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      (i = (i + 1U));
    }
    (ret = typechecker__typechecker__TypeChecker__subst_type(self, ret, ((const ast__ast__DefId *)(&ip.d[0])), ((const uint32_t *)(&ia.t[0])), in2));
  }
  const ast__ast__Ty *const rt = typechecker__typechecker__TypeChecker__type_at(self, ret);
  if (rt->kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance oi = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), rt->as_data.inst));
    if (oi.n >= 1U) {
      return oi.args[0];
    }
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__tc_check_assert(typechecker__typechecker__TypeChecker *const self, uint32_t const id, int32_t const kind) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*a)), id)->as_data.call.args;
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  if (kind == 1) {
    if ((args.len < 1U) || (args.len > 2U)) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc162 = String__Global__new();
String__Global__push_str(&__sc162, (str){ .ptr = (const uint8_t*)"'assert' takes a condition and an optional str message", .len = sizeof("'assert' takes a condition and an optional str message") - 1 });
__sc162; }));
      for (uint32_t i = 0U; i < args.len; i++) {
        typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[((size_t)i)]);
      }
      return 18U;
    }
    const uint32_t ct = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[0]);
    if ((ct != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, ct))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc163 = String__Global__new();
String__Global__push_str(&__sc163, (str){ .ptr = (const uint8_t*)"'assert' condition must be 'bool'", .len = sizeof("'assert' condition must be 'bool'") - 1 });
__sc163; }));
    }
    if (args.len == 2U) {
      const uint32_t mt = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[1]);
      if ((mt != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__strip(self, mt) != typechecker__typechecker__TypeChecker__prelude_str_type(self))) {
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc164 = String__Global__new();
String__Global__push_str(&__sc164, (str){ .ptr = (const uint8_t*)"'assert' message must be a 'str'", .len = sizeof("'assert' message must be a 'str'") - 1 });
__sc164; }));
      }
    }
    return 18U;
  }
  const char *nm = ((const char *)({ __auto_type __sc165 = (str){ (const uint8_t *)"assert_eq", sizeof("assert_eq") - 1 }; str__ptr(&__sc165); }));
  if (kind == 3) {
    (nm = ((const char *)({ __auto_type __sc166 = (str){ (const uint8_t *)"assert_ne", sizeof("assert_ne") - 1 }; str__ptr(&__sc166); })));
  }
  if (args.len != 2U) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc167 = String__Global__new();
String__Global__push_str(&__sc167, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc167, utils__errors__cstr(nm));
String__Global__push_str(&__sc167, (str){ .ptr = (const uint8_t*)"' takes exactly two arguments", .len = sizeof("' takes exactly two arguments") - 1 });
__sc167; }));
    for (uint32_t i = 0U; i < args.len; i++) {
      typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[((size_t)i)]);
    }
    return 18U;
  }
  const uint32_t lt = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[0]);
  (self->expected = lt);
  const uint32_t rt = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__list(&((*a)), args)[1]);
  if ((lt == ast__ast__TYPE_NONE) || (rt == ast__ast__TYPE_NONE)) {
    return 18U;
  }
  if (((lt != rt) && (!typechecker__typechecker__TypeChecker__compatible(self, lt, ast__ast__Ast__list(&((*a)), args)[1]))) && (!typechecker__typechecker__TypeChecker__compatible(self, rt, ast__ast__Ast__list(&((*a)), args)[0]))) {
    typechecker__typechecker__TypeChecker__err_mismatch(self, ast__ast__Ast__list(&((*a)), args)[1], lt);
  }
  const uint32_t base = typechecker__typechecker__TypeChecker__strip(self, lt);
  const ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, base));
  bool comparable = (((y.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (y.as_data.builtin != ast__ast__BuiltinType_BT_VOID)) && (y.as_data.builtin != ast__ast__BuiltinType_BT_VALIST));
  if (base == typechecker__typechecker__TypeChecker__prelude_str_type(self)) {
    (comparable = true);
  }
  if ((!comparable) && (((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_INSTANCE)) || (y.kind == ast__ast__TypeKind_TYPE_ENUM))) {
    uint16_t om = 0U;
    uint32_t od = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    if (typechecker__typechecker__TypeChecker__aggregate_of(self, base, ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
      (comparable = (typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"eq", sizeof("eq") - 1 }).node != ast__ast__NODE_NONE));
      if ((!comparable) && typechecker__typechecker__TypeChecker__is_plain_enum(self, base)) {
        (comparable = true);
      }
      if (comparable) {
        typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"as_str", sizeof("as_str") - 1 });
      }
    }
  }
  if (!comparable) {
    typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, lt, ((char *)(&ty.b[0])), 96ULL);
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc168 = String__Global__new();
String__Global__push_str(&__sc168, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc168, utils__errors__cstr(nm));
String__Global__push_str(&__sc168, (str){ .ptr = (const uint8_t*)"' cannot compare values of type '", .len = sizeof("' cannot compare values of type '") - 1 });
String__Global__push_str(&__sc168, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc168, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc168; }));
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc169 = String__Global__new();
String__Global__push_str(&__sc169, (str){ .ptr = (const uint8_t*)"implement 'Eq' (an 'eq' method) for the type, or compare a field/element instead", .len = sizeof("implement 'Eq' (an 'eq' method) for the type, or compare a field/element instead") - 1 });
__sc169; }));
  }
  return 18U;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__infer_from_bounds(typechecker__typechecker__TypeChecker *const self, uint16_t const fmod, uint32_t const fdecl, const uint32_t *const gids, const ast__ast__DefId *const gparams, uint32_t *const bound, int32_t const g) {
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, fmod);
  for (int32_t pass = 0; pass < 2; pass++) {
    for (int32_t i = 0; i < g; i++) {
      if (bound[((size_t)i)] != ast__ast__TYPE_NONE) {
        typechecker__typechecker__BoundArr8 bs = (typechecker__typechecker__BoundArr8){0};
        int32_t nb = 0;
        typechecker__typechecker__TypeChecker__add_bound_ifaces_full(self, fmod, ast__ast__Ast__at_const(&((*fa)), gids[((size_t)i)])->as_data.generic_param.bounds, ((typechecker__typechecker__BoundIface *)(&bs.b[0])), ((int32_t *)(&nb)), 8);
        const ast__ast__NodeList wc = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.where_clause;
        for (uint32_t w = 0U; w < wc.len; w++) {
          const uint32_t wid = ast__ast__Ast__list(&((*fa)), wc)[((size_t)w)];
          const ast__ast__WherePredicateData wp = ast__ast__Ast__at_const(&((*fa)), wid)->as_data.where_predicate;
          if (ast__ast__Ast__resolution(&((*fa)), wp.ty) == gids[((size_t)i)]) {
            typechecker__typechecker__TypeChecker__add_bound_ifaces_full(self, fmod, wp.bounds, ((typechecker__typechecker__BoundIface *)(&bs.b[0])), ((int32_t *)(&nb)), 8);
          }
        }
        for (int32_t b = 0; b < nb; b++) {
          if (bs.b[((size_t)b)].n != 0U) {
            uint16_t tm = 0U;
            uint32_t td = ast__ast__NODE_NONE;
            typechecker__typechecker__Defs4 sp = (typechecker__typechecker__Defs4){0};
            typechecker__typechecker__Tys4 sa = (typechecker__typechecker__Tys4){0};
            int32_t sn = 0;
            if (typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, bound[((size_t)i)]), ((uint16_t *)(&tm)), ((uint32_t *)(&td)), ((ast__ast__DefId *)(&sp.d[0])), ((uint32_t *)(&sa.t[0])), ((int32_t *)(&sn)))) {
              uint16_t imod = 0U;
              const uint32_t extn = typechecker__typechecker__TypeChecker__find_extend_as(self, tm, td, bs.b[((size_t)b)].iface, ((uint16_t *)(&imod)));
              if (extn != ast__ast__NODE_NONE) {
                ast__ast__Ast *const ia = typechecker__typechecker__TypeChecker__mod_ast(self, imod);
                const ast__ast__NodeList egids = ast__ast__Ast__at_const(&((*ia)), extn)->as_data.extend_def.generics;
                typechecker__typechecker__Defs4 egp = (typechecker__typechecker__Defs4){0};
                typechecker__typechecker__Tys4 ega = (typechecker__typechecker__Tys4){0};
                int32_t egn = 0;
                uint32_t k = 0U;
                while (((k < egids.len) && (((int32_t)k) < sn)) && (egn < 4)) {
                  const uint32_t xg = ast__ast__Ast__list(&((*ia)), egids)[((size_t)k)];
                  (egp.d[((size_t)egn)] = (ast__ast__DefId){ .module = imod, .node = xg });
                  (ega.t[((size_t)egn)] = sa.t[((size_t)k)]);
                  (egn = ({ int32_t __sc_r; if (__builtin_add_overflow(egn, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
                  (k = (k + 1U));
                }
                const ast__ast__Node *const itf = ast__ast__Ast__at_const(&((*ia)), ast__ast__Ast__at_const(&((*ia)), extn)->as_data.extend_def.interface_type);
                if (itf->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
                  const ast__ast__NodeList iargs = itf->as_data.type_path.args;
                  uint32_t kk = 0U;
                  while ((kk < iargs.len) && (kk < ((uint32_t)bs.b[((size_t)b)].n))) {
                    const uint32_t lowered = typechecker__typechecker__TypeChecker__lower_type_in(self, imod, ast__ast__Ast__list(&((*ia)), iargs)[((size_t)kk)]);
                    const uint32_t subst = typechecker__typechecker__TypeChecker__subst_type(self, lowered, ((const ast__ast__DefId *)(&egp.d[0])), ((const uint32_t *)(&ega.t[0])), egn);
                    typechecker__typechecker__TypeChecker__unify_infer(self, bs.b[((size_t)b)].args[((size_t)kk)], subst, gparams, bound, g);
                    (kk = (kk + 1U));
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__fn_compatible_subst(typechecker__typechecker__TypeChecker *const self, uint32_t const exid, uint32_t const acid, const ast__ast__DefId *const gp, const uint32_t *const ga, int32_t const gn, const ast__ast__DefId *const rp, const uint32_t *const ra, int32_t const rn) {
  if ((exid != acid) && typechecker__typechecker__TypeChecker__fn_owns(self, acid)) {
    const ast__ast__Ty exy = (*typechecker__typechecker__TypeChecker__type_at(self, exid));
    const ast__ast__Node *const exn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, exy.module))), exy.as_data.decl);
    if ((exn->kind != ast__ast__NodeKind_NODE_FUNCTION_TYPE) || (!exn->as_data.function_type.is_move)) {
      return false;
    }
  }
  typechecker__typechecker__Tys4 ep = (typechecker__typechecker__Tys4){0};
  typechecker__typechecker__Tys4 ap = (typechecker__typechecker__Tys4){0};
  uint32_t er = ast__ast__TYPE_NONE;
  uint32_t ar = ast__ast__TYPE_NONE;
  const int32_t en = typechecker__typechecker__TypeChecker__fn_sig(self, exid, ((uint32_t *)(&ep.t[0])), 4, ((uint32_t *)(&er)));
  const int32_t an = typechecker__typechecker__TypeChecker__fn_sig(self, acid, ((uint32_t *)(&ap.t[0])), 4, ((uint32_t *)(&ar)));
  if ((en != an) || (en > 4)) {
    return false;
  }
  const uint32_t er2 = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__subst_type(self, er, gp, ga, gn), rp, ra, rn);
  if (!typechecker__typechecker__TypeChecker__ret_eq(self, er2, ar)) {
    return false;
  }
  for (int32_t i = 0; i < en; i++) {
    const uint32_t ep2 = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__subst_type(self, ep.t[((size_t)i)], gp, ga, gn), rp, ra, rn);
    if (ep2 != ap.t[((size_t)i)]) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_field_visibility(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const field, uint32_t const owner, lexer__token__Span const at) {
  const ast__ast__Node *const f = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, m))), field);
  const bool inside_owner = (((self->package == NULL) || (m == self->ast.module)) && (owner == self->current_self));
  if (((f->kind == ast__ast__NodeKind_NODE_FIELD) && (!f->as_data.field.is_public)) && (!inside_owner)) {
    utils__errors__Errors__emit(&self->errors, at.start, (at.end - at.start), ({ String__Global __sc170 = String__Global__new();
String__Global__push_str(&__sc170, (str){ .ptr = (const uint8_t*)"field '", .len = sizeof("field '") - 1 });
String__Global__push_str(&__sc170, utils__errors__span_str(self->source, at.start, at.end));
String__Global__push_str(&__sc170, (str){ .ptr = (const uint8_t*)"' is private", .len = sizeof("' is private") - 1 });
__sc170; }));
  }
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_call(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const want) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t callee_id = ast__ast__Ast__at_const(&((*a)), id)->as_data.call.callee;
  const ast__ast__NodeKind pck = ast__ast__Ast__at_const(&((*a)), callee_id)->kind;
  uint32_t callee = ast__ast__TYPE_NONE;
  if (((pck == ast__ast__NodeKind_NODE_MEMBER) && (!ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.path)) && (ast__ast__Ast__at_const(&((*a)), id)->as_data.call.args.len == 0U)) {
    const uint32_t mem = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member;
    if (typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, self->ast.module), ast__ast__Ast__at_const(&((*a)), mem)->as_data.name.text, (str){ (const uint8_t *)"free", sizeof("free") - 1 })) {
      const uint32_t obj = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object;
      const uint32_t rt = typechecker__typechecker__TypeChecker__check_expr(self, obj);
      const lexer__token__Span fname = typechecker__typechecker__TypeChecker__name_span(self, mem);
      bool resolvable = false;
      if (rt != ast__ast__TYPE_NONE) {
        const ast__ast__Ty rty = (*typechecker__typechecker__TypeChecker__type_at(self, typechecker__typechecker__TypeChecker__strip(self, rt)));
        if ((rty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (rty.kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
          uint16_t om = 0U;
          uint32_t od = ast__ast__NODE_NONE;
          typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
          typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
          int32_t gn = 0;
          if (typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, rt), ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
            (resolvable = (typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"free", sizeof("free") - 1 }).node != ast__ast__NODE_NONE));
          }
        } else if (rty.kind == ast__ast__TypeKind_TYPE_GENERIC) {
          ast__ast__DefId iface = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
          (resolvable = (typechecker__typechecker__TypeChecker__find_bound_method(self, rty.module, rty.as_data.decl, fname, ((ast__ast__DefId *)(&iface))).node != ast__ast__NODE_NONE));
        } else if ((rty.kind == ast__ast__TypeKind_TYPE_DYN) && (rty.qualifier == 0U)) {
          typechecker__typechecker__TypeChecker__tc_mark_move(self, obj);
          return 18U;
        }
      }
      if (!resolvable) {
        return 18U;
      }
    }
  }
  if ((pck == ast__ast__NodeKind_NODE_MEMBER) && ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.path) {
    (self->expected = want);
    (callee = typechecker__typechecker__TypeChecker__check_expr(self, callee_id));
    const ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      return typechecker__typechecker__TypeChecker__check_variant_call(self, id, vd.module, vd.node, callee);
    }
  } else if (pck == ast__ast__NodeKind_NODE_MEMBER) {
    (self->expected = want);
    (callee = typechecker__typechecker__TypeChecker__check_member(self, callee_id, true));
    const ast__ast__DefId fd = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    if (((fd.node != ast__ast__NODE_NONE) && ((fd.module == self->ast.module) || ((self->package != NULL) && (((size_t)fd.module) < typechecker__typechecker__TypeChecker__pkg_count(self))))) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, fd.module))), fd.node)->kind == ast__ast__NodeKind_NODE_FIELD)) {
      ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), callee_id, callee);
    }
  } else {
    (callee = typechecker__typechecker__TypeChecker__check_expr(self, callee_id));
  }
  if (pck == ast__ast__NodeKind_NODE_MEMBER) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    const bool addressable = ((md.module == self->ast.module) || ((self->package != NULL) && (((size_t)md.module) < typechecker__typechecker__TypeChecker__pkg_count(self))));
    if (((md.node != ast__ast__NODE_NONE) && addressable) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
      typechecker__typechecker__TypeChecker__tc_check_test_ref(self, md, ast__ast__Ast__at_const(&((*a)), id)->span);
    }
  }
  if ((pck == ast__ast__NodeKind_NODE_IDENTIFIER) && (self->package != NULL)) {
    const ast__ast__DefId ad = ast__ast__Ast__resolution_def(&((*a)), callee_id);
    if ((((ad.node != ast__ast__NODE_NONE) && (((size_t)ad.module) < typechecker__typechecker__TypeChecker__pkg_count(self))) && (*({ __auto_type __sc171 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc171, ((size_t)ad.module)); })).prelude) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ad.module))), ad.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
      const lexer__token__Span anm = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ad.module))), ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ad.module))), ad.node)->as_data.function.name)->as_data.name.text;
      int32_t akind = 0;
      if (typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, ad.module), anm, (str){ (const uint8_t *)"assert", sizeof("assert") - 1 })) {
        (akind = 1);
      } else if (typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, ad.module), anm, (str){ (const uint8_t *)"assert_eq", sizeof("assert_eq") - 1 })) {
        (akind = 2);
      } else if (typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, ad.module), anm, (str){ (const uint8_t *)"assert_ne", sizeof("assert_ne") - 1 })) {
        (akind = 3);
      }
      if (akind != 0) {
        return typechecker__typechecker__TypeChecker__tc_check_assert(self, id, akind);
      }
    }
  }
  const ast__ast__NodeList args = ast__ast__Ast__at_const(&((*a)), id)->as_data.call.args;
  for (uint32_t i = 0U; i < args.len; i++) {
    const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)i)];
    if (typechecker__typechecker__TypeChecker__tc_is_iface_assoc_call(self, aid) || (ast__ast__Ast__at_const(&((*a)), aid)->kind == ast__ast__NodeKind_NODE_CLOSURE)) {
      (self->expected = typechecker__typechecker__TypeChecker__tc_param_expected(self, callee, callee_id, i));
    }
    typechecker__typechecker__TypeChecker__check_expr(self, aid);
    typechecker__typechecker__TypeChecker__tc_mark_move(self, aid);
  }
  if (callee == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  ast__ast__Ty ct = (*typechecker__typechecker__TypeChecker__type_at(self, callee));
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  if (ct.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const uint32_t fb = typechecker__typechecker__TypeChecker__generic_fn_bound(self, ct.module, ct.as_data.decl);
    if (fb != ast__ast__NODE_NONE) {
      (callee = typechecker__typechecker__TypeChecker__lower_type_in(self, ct.module, fb));
      (ct = (*typechecker__typechecker__TypeChecker__type_at(self, callee)));
    }
  }
  if (ct.kind == ast__ast__TypeKind_TYPE_DYN) {
    const uint32_t ds = typechecker__typechecker__TypeChecker__tc_dyn_fn_sig(self, (&ct));
    if (ds != ast__ast__TYPE_NONE) {
      (callee = ds);
      (ct = (*typechecker__typechecker__TypeChecker__type_at(self, callee)));
    }
  }
  if (ct.kind == ast__ast__TypeKind_TYPE_STRUCT) {
    const ast__ast__Node *const sd = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ct.module))), ct.as_data.decl);
    if ((sd->kind == ast__ast__NodeKind_NODE_STRUCT) && sd->as_data.aggregate.is_tuple) {
      const uint16_t sm = ct.module;
      const uint32_t sdecl = ct.as_data.decl;
      const ast__ast__NodeList members = sd->as_data.aggregate.members;
      if (args.len != members.len) {
        const char *s2 = ((const char *)({ __auto_type __sc172 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc172); }));
        if (members.len == 1U) {
          (s2 = ((const char *)({ __auto_type __sc173 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc173); })));
        }
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc174 = String__Global__new();
String__Global__push_str(&__sc174, (str){ .ptr = (const uint8_t*)"tuple struct takes ", .len = sizeof("tuple struct takes ") - 1 });
String__Global__push_u64(&__sc174, (uint64_t)(members.len));
String__Global__push_str(&__sc174, (str){ .ptr = (const uint8_t*)" element", .len = sizeof(" element") - 1 });
String__Global__push_str(&__sc174, utils__errors__cstr(s2));
String__Global__push_str(&__sc174, (str){ .ptr = (const uint8_t*)", got ", .len = sizeof(", got ") - 1 });
String__Global__push_u64(&__sc174, (uint64_t)(args.len));
__sc174; }));
        return ast__ast__TYPE_NONE;
      }
      for (uint32_t k = 0U; k < args.len; k++) {
        const uint32_t et = typechecker__typechecker__TypeChecker__lower_type_in(self, sm, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__mod_ast(self, sm))), members)[((size_t)k)]);
        const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)k)];
        if (!typechecker__typechecker__TypeChecker__compatible(self, et, aid)) {
          typechecker__typechecker__TypeChecker__err_mismatch(self, aid, et);
        }
      }
      return typechecker__typechecker__TypeChecker__named_type_of(self, sm, sdecl);
    }
  }
  if (ct.kind != ast__ast__TypeKind_TYPE_FUNCTION) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc175 = String__Global__new();
String__Global__push_str(&__sc175, (str){ .ptr = (const uint8_t*)"called value is not a function", .len = sizeof("called value is not a function") - 1 });
__sc175; }));
    return ast__ast__TYPE_NONE;
  }
  const uint16_t fmod = ct.module;
  const uint32_t fdecl = ct.as_data.decl;
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, fmod);
  const ast__ast__NodeKind fk = ast__ast__Ast__at_const(&((*fa)), fdecl)->kind;
  const bool named = (fk == ast__ast__NodeKind_NODE_FUNCTION);
  if ((named && ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.is_extern) && (self->unsafe_depth == 0U)) {
    typechecker__typechecker__TypeChecker__err_unsafe(self, sp, (str){ (const uint8_t *)"calling an extern \"C\" function", sizeof("calling an extern \"C\" function") - 1 });
  }
  const bool clos = (fk == ast__ast__NodeKind_NODE_CLOSURE);
  ast__ast__NodeList params = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  ast__ast__NodeList returns = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  if (named) {
    (params = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.params);
    (returns = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.returns);
  } else if (clos) {
    (params = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.closure.params);
    (returns = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.closure.returns);
  } else {
    (params = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function_type.params);
    (returns = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function_type.returns);
  }
  bool fmt_builtin = false;
  if (((named && (self->package != NULL)) && (((size_t)fmod) < typechecker__typechecker__TypeChecker__pkg_count(self))) && (*({ __auto_type __sc176 = &(*self->package).modules; Vector__module__loader__Module__Global__index(__sc176, ((size_t)fmod)); })).prelude) {
    const lexer__token__Span fnm = ast__ast__Ast__at_const(&((*fa)), ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.name)->as_data.name.text;
    (fmt_builtin = (((((typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, fmod), fnm, (str){ (const uint8_t *)"format", sizeof("format") - 1 }) || typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, fmod), fnm, (str){ (const uint8_t *)"format_into", sizeof("format_into") - 1 })) || typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, fmod), fnm, (str){ (const uint8_t *)"print", sizeof("print") - 1 })) || typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, fmod), fnm, (str){ (const uint8_t *)"println", sizeof("println") - 1 })) || typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, fmod), fnm, (str){ (const uint8_t *)"eprint", sizeof("eprint") - 1 })) || typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, fmod), fnm, (str){ (const uint8_t *)"eprintln", sizeof("eprintln") - 1 })));
    if (fmt_builtin) {
      typechecker__typechecker__TypeChecker__mark_format_helpers(self);
    }
  }
  uint32_t skip = 0U;
  const bool cn_path = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.path;
  if (((named && (pck == ast__ast__NodeKind_NODE_MEMBER)) && (!cn_path)) && (params.len > 0U)) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    if ((md.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
      (skip = 1U);
    }
  }
  if (((pck == ast__ast__NodeKind_NODE_MEMBER) && (skip == 1U)) && (ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object != ast__ast__NODE_NONE)) {
    typechecker__typechecker__TypeChecker__check_call_receiver(self, id, callee_id, fmod, params, returns);
  }
  const uint32_t ret = typechecker__typechecker__TypeChecker__check_call_finish(self, id, callee, callee_id, fmod, fdecl, named, clos, params, returns, args, skip, want, fmt_builtin);
  return ret;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_call_receiver(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const callee_id, uint16_t const fmod, ast__ast__NodeList const params, ast__ast__NodeList const returns) {
  (void)id;
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t mem = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member;
  const uint32_t recv = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object;
  const bool is_free = typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, self->ast.module), ast__ast__Ast__at_const(&((*a)), mem)->as_data.name.text, (str){ (const uint8_t *)"free", sizeof("free") - 1 });
  if (is_free) {
    const ast__ast__Ty rty = (*typechecker__typechecker__TypeChecker__type_at(self, ast__ast__Ast__type_of(&((*a)), recv)));
    uint32_t thru = ast__ast__NODE_NONE;
    if ((rty.kind == ast__ast__TypeKind_TYPE_REFERENCE) && (ast__ast__Ast__at_const(&((*a)), recv)->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
      const ast__ast__DefId rd = ast__ast__Ast__resolution_def(&((*a)), recv);
      if (rd.module == self->ast.module) {
        (thru = rd.node);
      }
    } else if (rty.kind != ast__ast__TypeKind_TYPE_POINTER) {
      (thru = typechecker__typechecker__TypeChecker__place_through_binding(self, recv));
    }
    bool through_owner = false;
    uint32_t i = 0U;
    while (((thru != ast__ast__NODE_NONE) && (i < self->nborrows)) && (!through_owner)) {
      const typechecker__typechecker__Borrow b = self->borrows[((size_t)i)];
      if ((b.binding == thru) && (b.root != ast__ast__NODE_NONE)) {
        const ast__ast__NodeKind rk = ast__ast__Ast__at_const(&((*a)), b.root)->kind;
        if ((((rk == ast__ast__NodeKind_NODE_LET) || (rk == ast__ast__NodeKind_NODE_PATTERN_NAME)) || (rk == ast__ast__NodeKind_NODE_IDENTIFIER)) || (rk == ast__ast__NodeKind_NODE_FOR)) {
          const lexer__token__Span rsp = ast__ast__Ast__at_const(&((*a)), recv)->span;
          utils__errors__Errors__emit(&self->errors, rsp.start, (rsp.end - rsp.start), ({ String__Global __sc177 = String__Global__new();
String__Global__push_str(&__sc177, (str){ .ptr = (const uint8_t*)"cannot free a borrowed value: its owning binding frees it again at scope exit", .len = sizeof("cannot free a borrowed value: its owning binding frees it again at scope exit") - 1 });
__sc177; }));
          (through_owner = true);
        }
      }
      (i = (i + 1U));
    }
    if ((((!through_owner) && (rty.kind != ast__ast__TypeKind_TYPE_POINTER)) && (rty.kind != ast__ast__TypeKind_TYPE_REFERENCE)) && typechecker__typechecker__TypeChecker__tc_type_is_free(self, ast__ast__Ast__type_of(&((*a)), recv))) {
      typechecker__typechecker__TypeChecker__tc_mark_move(self, recv);
      if (ast__ast__Ast__at_const(&((*a)), recv)->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
        const ast__ast__DefId rd = ast__ast__Ast__resolution_def(&((*a)), recv);
        if ((rd.module == self->ast.module) && (rd.node != ast__ast__NODE_NONE)) {
          if (self->nfreed < 256U) {
            const uint32_t k = self->nfreed;
            (self->freed[((size_t)k)] = rd.node);
            (self->nfreed = (k + 1U));
          }
        }
      }
    }
    return;
  }
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, fmod);
  const uint32_t p0 = ast__ast__Ast__list(&((*fa)), params)[0];
  const uint32_t pt = ast__ast__Ast__at_const(&((*fa)), p0)->as_data.parameter.ty;
  ast__ast__NodeKind ptk = ast__ast__NodeKind_NODE_NONE_KIND;
  if (pt != ast__ast__NODE_NONE) {
    (ptk = ast__ast__Ast__at_const(&((*fa)), pt)->kind);
  }
  if ((ptk != ast__ast__NodeKind_NODE_POINTER_TYPE) && (ptk != ast__ast__NodeKind_NODE_REFERENCE_TYPE)) {
    if (ast__ast__Ast__deref_use_at(&((*a)), mem) != NULL) {
      typechecker__typechecker__TypeChecker__borrow_report_conflict(self, recv, typechecker__typechecker__BORROW_SHARED, recv);
    } else {
      typechecker__typechecker__TypeChecker__tc_mark_move(self, recv);
    }
  } else {
    uint8_t bk = typechecker__typechecker__BORROW_SHARED;
    if (ast__ast__Ast__at_const(&((*fa)), pt)->as_data.indirect_type.qualifier == ast__ast__TypeQualifier_TYPE_QUAL_MUT) {
      (bk = typechecker__typechecker__BORROW_MUT);
    }
    bool ret_ref = false;
    if (returns.len == 1U) {
      const uint32_t rr0 = ast__ast__Ast__list(&((*fa)), returns)[0];
      const ast__ast__Node *const rrn = ast__ast__Ast__at_const(&((*fa)), rr0);
      const uint32_t rtn = typechecker__typechecker__if_node((rrn->kind == ast__ast__NodeKind_NODE_PARAMETER), rrn->as_data.parameter.ty, rr0);
      (ret_ref = ((rtn != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*fa)), rtn)->kind == ast__ast__NodeKind_NODE_REFERENCE_TYPE)));
    }
    if (ret_ref) {
      typechecker__typechecker__TypeChecker__borrow_create(self, recv, bk, recv);
    } else {
      typechecker__typechecker__TypeChecker__borrow_report_conflict(self, recv, bk, recv);
    }
  }
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_call_finish(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const callee, uint32_t const callee_id, uint16_t const fmod, uint32_t const fdecl, bool const named, bool const clos, ast__ast__NodeList const params, ast__ast__NodeList const returns, ast__ast__NodeList const args, uint32_t const skip, uint32_t const want, bool const fmt_builtin) {
  (void)callee;
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, fmod);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  const ast__ast__NodeKind cn_kind = ast__ast__Ast__at_const(&((*a)), callee_id)->kind;
  const bool cn_path = ((cn_kind == ast__ast__NodeKind_NODE_MEMBER) && ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.path);
  const ast__ast__DerefUse *cdu = NULL;
  if ((cn_kind == ast__ast__NodeKind_NODE_MEMBER) && (!cn_path)) {
    (cdu = ast__ast__Ast__deref_use_at(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member));
  }
  typechecker__typechecker__Defs4 rsubp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 rsuba = (typechecker__typechecker__Tys4){0};
  int32_t nrsub = 0;
  if (cn_kind == ast__ast__NodeKind_NODE_MEMBER) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    uint32_t recvbase = typechecker__typechecker__TypeChecker__strip(self, ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object));
    if (cdu != NULL) {
      (recvbase = (*cdu).target);
    }
    uint16_t rmod = 0U;
    uint32_t rdecl = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t sn = 0;
    const bool mdfn = ((md.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->kind == ast__ast__NodeKind_NODE_FUNCTION));
    const bool agok = (mdfn && typechecker__typechecker__TypeChecker__aggregate_of(self, recvbase, ((uint16_t *)(&rmod)), ((uint32_t *)(&rdecl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&sn))));
    if (agok && (sn > 0)) {
      const uint32_t extnode = typechecker__typechecker__TypeChecker__enclosing_extend(self, md.module, md.node);
      if (extnode != ast__ast__NODE_NONE) {
        ast__ast__Ast *const ma = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
        const ast__ast__NodeList ig = ast__ast__Ast__at_const(&((*ma)), extnode)->as_data.extend_def.generics;
        int32_t g = ((int32_t)ig.len);
        if (sn < g) {
          (g = sn);
        }
        int32_t i = 0;
        while ((i < g) && (nrsub < 4)) {
          const uint32_t gid = ast__ast__Ast__list(&((*ma)), ig)[((size_t)i)];
          (rsubp.d[((size_t)nrsub)] = (ast__ast__DefId){ .module = md.module, .node = gid });
          (rsuba.t[((size_t)nrsub)] = ga.t[((size_t)i)]);
          (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
          (i = ({ int32_t __sc_r; if (__builtin_add_overflow(i, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        }
      }
    }
  }
  if (((cn_kind == ast__ast__NodeKind_NODE_MEMBER) && (!cn_path)) && (nrsub < 4)) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    uint32_t tr = ast__ast__NODE_NONE;
    if (md.node != ast__ast__NODE_NONE) {
      (tr = typechecker__typechecker__TypeChecker__enclosing_trait(self, md.module, md.node));
    }
    if (tr != ast__ast__NODE_NONE) {
      uint32_t target = typechecker__typechecker__TypeChecker__strip(self, ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object));
      if (cdu != NULL) {
        (target = (*cdu).target);
      }
      (rsubp.d[((size_t)nrsub)] = (ast__ast__DefId){ .module = md.module, .node = tr });
      (rsuba.t[((size_t)nrsub)] = target);
      (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      const ast__ast__Ty ro = (*typechecker__typechecker__TypeChecker__type_at(self, target));
      if ((ro.kind == ast__ast__TypeKind_TYPE_GENERIC) && (nrsub < 4)) {
        (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, typechecker__typechecker__TypeChecker__bound_method_subst(self, ro.module, ro.as_data.decl, md, (((ast__ast__DefId *)(&rsubp.d[0])) + ((size_t)nrsub)), (((uint32_t *)(&rsuba.t[0])) + ((size_t)nrsub)), ({ int32_t __sc_r; if (__builtin_sub_overflow(4, nrsub, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
    }
  }
  if (((cn_kind == ast__ast__NodeKind_NODE_MEMBER) && cn_path) && (nrsub < 4)) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    uint32_t tr = ast__ast__NODE_NONE;
    if (md.node != ast__ast__NODE_NONE) {
      (tr = typechecker__typechecker__TypeChecker__enclosing_trait(self, md.module, md.node));
    }
    const ast__ast__DefId ob = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object);
    ast__ast__NodeKind ob_kind = ast__ast__NodeKind_NODE_NONE_KIND;
    if (ob.node != ast__ast__NODE_NONE) {
      (ob_kind = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ob.module))), ob.node)->kind);
    }
    if (((tr != ast__ast__NODE_NONE) && (ob.node != ast__ast__NODE_NONE)) && (ob_kind == ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
      (rsubp.d[((size_t)nrsub)] = (ast__ast__DefId){ .module = md.module, .node = tr });
      (rsuba.t[((size_t)nrsub)] = typechecker__typechecker__TypeChecker__named_type_of(self, ob.module, ob.node));
      (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      if (nrsub < 4) {
        (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, typechecker__typechecker__TypeChecker__bound_method_subst(self, ob.module, ob.node, md, (((ast__ast__DefId *)(&rsubp.d[0])) + ((size_t)nrsub)), (((uint32_t *)(&rsuba.t[0])) + ((size_t)nrsub)), ({ int32_t __sc_r; if (__builtin_sub_overflow(4, nrsub, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
    }
    if (((ob.node != ast__ast__NODE_NONE) && (md.node != ast__ast__NODE_NONE)) && (ob_kind == ast__ast__NodeKind_NODE_INTERFACE)) {
      uint16_t em = 0U;
      uint32_t ed = ast__ast__NODE_NONE;
      typechecker__typechecker__Defs4 egp2 = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 ega2 = (typechecker__typechecker__Tys4){0};
      int32_t egn2 = 0;
      bool agg = false;
      if (want != ast__ast__TYPE_NONE) {
        const uint32_t sw = typechecker__typechecker__TypeChecker__strip(self, want);
        (agg = typechecker__typechecker__TypeChecker__aggregate_of(self, sw, ((uint16_t *)(&em)), ((uint32_t *)(&ed)), ((ast__ast__DefId *)(&egp2.d[0])), ((uint32_t *)(&ega2.t[0])), ((int32_t *)(&egn2))));
      }
      if (agg && (egn2 > 0)) {
        const uint32_t ext = typechecker__typechecker__TypeChecker__enclosing_extend(self, md.module, md.node);
        if (ext != ast__ast__NODE_NONE) {
          ast__ast__Ast *const ma = typechecker__typechecker__TypeChecker__mod_ast(self, md.module);
          const ast__ast__NodeList ig = ast__ast__Ast__at_const(&((*ma)), ext)->as_data.extend_def.generics;
          const uint32_t *const gids = ast__ast__Ast__list(&((*ma)), ig);
          uint32_t i = 0U;
          while (((i < ig.len) && (((int32_t)i) < egn2)) && (nrsub < 4)) {
            (rsubp.d[((size_t)nrsub)] = (ast__ast__DefId){ .module = md.module, .node = gids[((size_t)i)] });
            (rsuba.t[((size_t)nrsub)] = ega2.t[((size_t)i)]);
            (nrsub = ({ int32_t __sc_r; if (__builtin_add_overflow(nrsub, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
            (i = (i + 1U));
          }
        }
      }
    }
  }
  if (cn_kind == ast__ast__NodeKind_NODE_MEMBER) {
    const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member);
    if ((md.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
      uint32_t mt = ast__ast__TYPE_NONE;
      if (!cn_path) {
        if (cdu != NULL) {
          (mt = (*cdu).target);
        } else {
          (mt = typechecker__typechecker__TypeChecker__strip(self, ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object)));
        }
      } else {
        const ast__ast__DefId ob = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object);
        if (((ob.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ob.module))), ob.node)->kind == ast__ast__NodeKind_NODE_INTERFACE)) && (want != ast__ast__TYPE_NONE)) {
          (mt = typechecker__typechecker__TypeChecker__strip(self, want));
        } else {
          (mt = typechecker__typechecker__TypeChecker__strip(self, ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object)));
        }
      }
      if ((mt != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__method_extend_bounds_hold(self, mt, md))) {
        typechecker__typechecker__TypeChecker__err_method_extend_bounds(self, sp, mt, md);
        return ast__ast__TYPE_NONE;
      }
    }
  }
  typechecker__typechecker__Defs8 gparams = (typechecker__typechecker__Defs8){0};
  typechecker__typechecker__Tys8 gargs = (typechecker__typechecker__Tys8){0};
  int32_t gn = 0;
  if (named && (ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.generics.len != 0U)) {
    const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.generics;
    int32_t g = ((int32_t)gens.len);
    if (g > 8) {
      (g = 8);
    }
    for (int32_t ii = 0; ii < g; ii++) {
      (gparams.d[((size_t)ii)] = (ast__ast__DefId){ .module = fmod, .node = ast__ast__Ast__list(&((*fa)), gens)[((size_t)ii)] });
      (gargs.t[((size_t)ii)] = ast__ast__TYPE_NONE);
    }
    typechecker__typechecker__Tys8 bound = (typechecker__typechecker__Tys8){0};
    int32_t nexplicit = 0;
    if (cn_kind == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
      const ast__ast__NodeList tas = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.specialization.types;
      uint32_t i = 0U;
      while ((i < tas.len) && (nexplicit < g)) {
        (bound.t[((size_t)nexplicit)] = ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__list(&((*a)), tas)[((size_t)i)]));
        (nexplicit = ({ int32_t __sc_r; if (__builtin_add_overflow(nexplicit, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        (i = (i + 1U));
      }
    }
    if ((nexplicit < g) && (args.len == (params.len - skip))) {
      for (uint32_t i = 0U; i < args.len; i++) {
        const uint32_t pid = ast__ast__Ast__list(&((*fa)), params)[((size_t)(i + skip))];
        typechecker__typechecker__TypeChecker__unify_infer(self, typechecker__typechecker__TypeChecker__decl_type_in(self, fmod, pid), ast__ast__Ast__type_of(&((*a)), ast__ast__Ast__list(&((*a)), args)[((size_t)i)]), ((const ast__ast__DefId *)(&gparams.d[0])), ((uint32_t *)(&bound.t[0])), g);
      }
      for (int32_t k = 0; k < g; k++) {
        if ((bound.t[((size_t)k)] != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, bound.t[((size_t)k)])->kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
          const uint32_t fb = typechecker__typechecker__TypeChecker__generic_fn_bound(self, fmod, ast__ast__Ast__list(&((*fa)), gens)[((size_t)k)]);
          if (fb != ast__ast__NODE_NONE) {
            typechecker__typechecker__TypeChecker__unify_infer(self, typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, fb), bound.t[((size_t)k)], ((const ast__ast__DefId *)(&gparams.d[0])), ((uint32_t *)(&bound.t[0])), g);
          }
        }
      }
      typechecker__typechecker__TypeChecker__infer_from_bounds(self, fmod, fdecl, ast__ast__Ast__list(&((*fa)), gens), ((const ast__ast__DefId *)(&gparams.d[0])), ((uint32_t *)(&bound.t[0])), g);
      (nexplicit = g);
    }
    for (int32_t i = 0; i < nexplicit; i++) {
      (gargs.t[((size_t)i)] = bound.t[((size_t)i)]);
    }
    (gn = nexplicit);
    if (gn == g) {
      ast__ast__Ast__set_type_args(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, ((const uint32_t *)(&gargs.t[0])), ((uint8_t)gn));
      typechecker__typechecker__TypeChecker__check_generic_bounds(self, id, fmod, fdecl, gens, ((const ast__ast__DefId *)(&gparams.d[0])), ((const uint32_t *)(&gargs.t[0])), gn, ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub);
    }
  }
  const bool variadic = (named && ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.is_variadic);
  const uint32_t expected = (params.len - skip);
  const bool bad = typechecker__typechecker__if_bool(variadic, (args.len < expected), (args.len != expected));
  if (bad) {
    const char *s2 = ((const char *)({ __auto_type __sc178 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc178); }));
    if (expected == 1U) {
      (s2 = ((const char *)({ __auto_type __sc179 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc179); })));
    }
    if (variadic) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc180 = String__Global__new();
String__Global__push_str(&__sc180, (str){ .ptr = (const uint8_t*)"expected at least ", .len = sizeof("expected at least ") - 1 });
String__Global__push_u64(&__sc180, (uint64_t)(expected));
String__Global__push_str(&__sc180, (str){ .ptr = (const uint8_t*)" argument", .len = sizeof(" argument") - 1 });
String__Global__push_str(&__sc180, utils__errors__cstr(s2));
String__Global__push_str(&__sc180, (str){ .ptr = (const uint8_t*)", found ", .len = sizeof(", found ") - 1 });
String__Global__push_u64(&__sc180, (uint64_t)(args.len));
__sc180; }));
    } else {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc181 = String__Global__new();
String__Global__push_str(&__sc181, (str){ .ptr = (const uint8_t*)"expected ", .len = sizeof("expected ") - 1 });
String__Global__push_u64(&__sc181, (uint64_t)(expected));
String__Global__push_str(&__sc181, (str){ .ptr = (const uint8_t*)" argument", .len = sizeof(" argument") - 1 });
String__Global__push_str(&__sc181, utils__errors__cstr(s2));
String__Global__push_str(&__sc181, (str){ .ptr = (const uint8_t*)", found ", .len = sizeof(", found ") - 1 });
String__Global__push_u64(&__sc181, (uint64_t)(args.len));
__sc181; }));
    }
  } else {
    for (uint32_t i = 0U; i < expected; i++) {
      const uint32_t pid = ast__ast__Ast__list(&((*fa)), params)[((size_t)(i + skip))];
      const uint32_t raw = typechecker__typechecker__if_ty(named, typechecker__typechecker__TypeChecker__decl_type_in(self, fmod, pid), typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, pid));
      const uint32_t pt = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__subst_type(self, raw, ((const ast__ast__DefId *)(&gparams.d[0])), ((const uint32_t *)(&gargs.t[0])), gn), ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub);
      const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)i)];
      if (typechecker__typechecker__TypeChecker__type_at(self, pt)->kind == ast__ast__TypeKind_TYPE_FUNCTION) {
        const uint32_t at = ast__ast__Ast__type_of(&((*a)), aid);
        if (((pt != at) && (at != ast__ast__TYPE_NONE)) && typechecker__typechecker__TypeChecker__fn_is_capturing(self, at)) {
          const lexer__token__Span asp = ast__ast__Ast__at_const(&((*a)), aid)->span;
          utils__errors__Errors__emit(&self->errors, asp.start, (asp.end - asp.start), ({ String__Global __sc182 = String__Global__new();
String__Global__push_str(&__sc182, (str){ .ptr = (const uint8_t*)"a capturing closure cannot be passed as a bare 'fn' pointer", .len = sizeof("a capturing closure cannot be passed as a bare 'fn' pointer") - 1 });
__sc182; }));
        } else if (((at == ast__ast__TYPE_NONE) || typechecker__typechecker__TypeChecker__at_not_fn(self, at)) || (!typechecker__typechecker__TypeChecker__fn_compatible_subst(self, pt, at, ((const ast__ast__DefId *)(&gparams.d[0])), ((const uint32_t *)(&gargs.t[0])), gn, ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub))) {
          typechecker__typechecker__TypeChecker__err_mismatch(self, aid, pt);
        }
      } else if (!typechecker__typechecker__TypeChecker__compatible(self, pt, aid)) {
        typechecker__typechecker__TypeChecker__err_mismatch(self, aid, pt);
      }
    }
  }
  if ((variadic && (!fmt_builtin)) && (args.len >= expected)) {
    const uint32_t cstr = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_POINTER, .qualifier = 1U, .as_data = (ast__ast__TyAs){ .elem = 2U } });
    uint32_t i = expected;
    while (i < args.len) {
      const uint32_t aid = ast__ast__Ast__list(&((*a)), args)[((size_t)i)];
      const ast__ast__Node *const an = ast__ast__Ast__at_const(&((*a)), aid);
      if ((an->kind == ast__ast__NodeKind_NODE_LITERAL) && ((an->as_data.literal.token_type == lexer__token_type__TokenType_StringLiteral) || (an->as_data.literal.token_type == lexer__token_type__TokenType_RawStringLiteral))) {
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), aid, cstr);
      }
      (i = (i + 1U));
    }
  }
  if (((skip == 1U) && (cn_kind == ast__ast__NodeKind_NODE_MEMBER)) && (params.len > 0U)) {
    const ast__ast__Ty selfp = (*typechecker__typechecker__TypeChecker__type_at(self, typechecker__typechecker__TypeChecker__decl_type_in(self, fmod, ast__ast__Ast__list(&((*fa)), params)[0])));
    if (((selfp.kind == ast__ast__TypeKind_TYPE_REFERENCE) || (selfp.kind == ast__ast__TypeKind_TYPE_POINTER)) && (selfp.qualifier == 2U)) {
      const uint32_t recv = ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.object;
      const ast__ast__Ty rvt = (*typechecker__typechecker__TypeChecker__type_at(self, ast__ast__Ast__type_of(&((*a)), recv)));
      if (rvt.kind == ast__ast__TypeKind_TYPE_DYN) {
        if (rvt.qualifier == 1U) {
          const lexer__token__Span rsp = ast__ast__Ast__at_const(&((*a)), recv)->span;
          utils__errors__Errors__emit(&self->errors, rsp.start, (rsp.end - rsp.start), ({ String__Global __sc183 = String__Global__new();
String__Global__push_str(&__sc183, (str){ .ptr = (const uint8_t*)"cannot call a '&mut self' method through '&dyn' (use '&mut dyn')", .len = sizeof("cannot call a '&mut self' method through '&dyn' (use '&mut dyn')") - 1 });
__sc183; }));
        } else if ((rvt.qualifier == 0U) && (!typechecker__typechecker__TypeChecker__receiver_mutable(self, recv))) {
          const lexer__token__Span rsp = ast__ast__Ast__at_const(&((*a)), recv)->span;
          utils__errors__Errors__emit(&self->errors, rsp.start, (rsp.end - rsp.start), ({ String__Global __sc184 = String__Global__new();
String__Global__push_str(&__sc184, (str){ .ptr = (const uint8_t*)"cannot call a '&mut self' method on an immutable binding (bind it with 'mut')", .len = sizeof("cannot call a '&mut self' method on an immutable binding (bind it with 'mut')") - 1 });
__sc184; }));
        }
      } else {
        const bool consuming_free = (((rvt.kind != ast__ast__TypeKind_TYPE_REFERENCE) && (rvt.kind != ast__ast__TypeKind_TYPE_POINTER)) && typechecker__typechecker__span_is(typechecker__typechecker__TypeChecker__mod_src(self, self->ast.module), ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), callee_id)->as_data.member.member)->as_data.name.text, (str){ (const uint8_t *)"free", sizeof("free") - 1 }));
        if (!consuming_free) {
          typechecker__typechecker__TypeChecker__tc_mark_capture_mut(self, recv);
          if (!typechecker__typechecker__TypeChecker__receiver_mutable(self, recv)) {
            const lexer__token__Span rsp = ast__ast__Ast__at_const(&((*a)), recv)->span;
            utils__errors__Errors__emit(&self->errors, rsp.start, (rsp.end - rsp.start), ({ String__Global __sc185 = String__Global__new();
String__Global__push_str(&__sc185, (str){ .ptr = (const uint8_t*)"cannot call a '&mut self' method on an immutable binding (bind it with 'mut')", .len = sizeof("cannot call a '&mut self' method on an immutable binding (bind it with 'mut')") - 1 });
__sc185; }));
          }
        }
      }
    }
  }
  if (clos && ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.closure.expr_body) {
    return ast__ast__Ast__type_of(&((*fa)), ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.closure.body);
  }
  if (named && (typechecker__typechecker__TypeChecker__tc_attr(self, fmod, fdecl, ast__ast__AttrKind_ATTR_NORETURN) != NULL)) {
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_NEVER });
  }
  if (returns.len != 1U) {
    if (returns.len > 1U) {
      (self->mret_n = typechecker__typechecker__if_u8((returns.len < 8U), ((uint8_t)returns.len), 8U));
      (self->mret_total = returns.len);
      for (uint8_t i = 0U; i < self->mret_n; i++) {
        const uint32_t mrid = ast__ast__Ast__list(&((*fa)), returns)[((size_t)i)];
        const ast__ast__Node *const mrn = ast__ast__Ast__at_const(&((*fa)), mrid);
        const uint32_t mrt = typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, typechecker__typechecker__if_node((mrn->kind == ast__ast__NodeKind_NODE_PARAMETER), mrn->as_data.parameter.ty, mrid));
        (self->mret_types[((size_t)i)] = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__subst_type(self, mrt, ((const ast__ast__DefId *)(&gparams.d[0])), ((const uint32_t *)(&gargs.t[0])), gn), ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub));
      }
      (self->mret_call = id);
    }
    return ast__ast__TYPE_NONE;
  }
  const uint32_t r0 = ast__ast__Ast__list(&((*fa)), returns)[0];
  const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*fa)), r0);
  const uint32_t ret = typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0));
  return typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__subst_type(self, ret, ((const ast__ast__DefId *)(&gparams.d[0])), ((const uint32_t *)(&gargs.t[0])), gn), ((const ast__ast__DefId *)(&rsubp.d[0])), ((const uint32_t *)(&rsuba.t[0])), nrsub);
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_generic_bounds(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint16_t const fmod, uint32_t const fdecl, ast__ast__NodeList const gens, const ast__ast__DefId *const gparams, const uint32_t *const gargs, int32_t const gn, const ast__ast__DefId *const rsubp, const uint32_t *const rsuba, int32_t const nrsub) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  ast__ast__Ast *const fa = typechecker__typechecker__TypeChecker__mod_ast(self, fmod);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
  for (int32_t i = 0; i < gn; i++) {
    const uint32_t gid = ast__ast__Ast__list(&((*fa)), gens)[((size_t)i)];
    const ast__ast__NodeList pb = ast__ast__Ast__at_const(&((*fa)), gid)->as_data.generic_param.bounds;
    for (uint32_t b = 0U; b < pb.len; b++) {
      const uint32_t bid = ast__ast__Ast__list(&((*fa)), pb)[((size_t)b)];
      if (ast__ast__Ast__at_const(&((*fa)), bid)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
        const uint32_t bt = typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, bid);
        const uint32_t garg = gargs[((size_t)i)];
        if (garg != ast__ast__TYPE_NONE) {
          const ast__ast__Ty gy = (*typechecker__typechecker__TypeChecker__type_at(self, garg));
          if ((gy.kind != ast__ast__TypeKind_TYPE_GENERIC) && ((gy.kind != ast__ast__TypeKind_TYPE_FUNCTION) || (!typechecker__typechecker__TypeChecker__fn_compatible_subst(self, bt, garg, gparams, gargs, gn, rsubp, rsuba, nrsub)))) {
            typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
            typechecker__typechecker__TypeChecker__render_type(self, garg, ((char *)(&tn.b[0])), 96ULL);
            const lexer__token__Span bsp = ast__ast__Ast__at_const(&((*fa)), bid)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc186 = String__Global__new();
String__Global__push_str(&__sc186, (str){ .ptr = (const uint8_t*)"type '", .len = sizeof("type '") - 1 });
String__Global__push_str(&__sc186, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc186, (str){ .ptr = (const uint8_t*)"' does not satisfy bound '", .len = sizeof("' does not satisfy bound '") - 1 });
String__Global__push_str(&__sc186, utils__errors__span_str(typechecker__typechecker__TypeChecker__mod_src(self, fmod), bsp.start, bsp.end));
String__Global__push_str(&__sc186, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc186; }));
          }
        }
      } else {
        const ast__ast__DefId bi = ast__ast__Ast__resolution_def(&((*fa)), bid);
        if ((bi.node != ast__ast__NODE_NONE) && (!typechecker__typechecker__TypeChecker__type_satisfies(self, gargs[((size_t)i)], bi, 0))) {
          typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, gargs[((size_t)i)], ((char *)(&tn.b[0])), 96ULL);
          const lexer__token__Span bsp = ast__ast__Ast__at_const(&((*fa)), bid)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc187 = String__Global__new();
String__Global__push_str(&__sc187, (str){ .ptr = (const uint8_t*)"type '", .len = sizeof("type '") - 1 });
String__Global__push_str(&__sc187, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc187, (str){ .ptr = (const uint8_t*)"' does not satisfy bound '", .len = sizeof("' does not satisfy bound '") - 1 });
String__Global__push_str(&__sc187, utils__errors__span_str(typechecker__typechecker__TypeChecker__mod_src(self, fmod), bsp.start, bsp.end));
String__Global__push_str(&__sc187, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc187; }));
        }
      }
    }
  }
  const ast__ast__NodeList wc = ast__ast__Ast__at_const(&((*fa)), fdecl)->as_data.function.where_clause;
  for (uint32_t w = 0U; w < wc.len; w++) {
    const ast__ast__WherePredicateData wp = ast__ast__Ast__at_const(&((*fa)), ast__ast__Ast__list(&((*fa)), wc)[((size_t)w)])->as_data.where_predicate;
    const uint32_t wt = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, wp.ty), gparams, gargs, gn);
    for (uint32_t b = 0U; b < wp.bounds.len; b++) {
      const uint32_t wbid = ast__ast__Ast__list(&((*fa)), wp.bounds)[((size_t)b)];
      if (ast__ast__Ast__at_const(&((*fa)), wbid)->kind == ast__ast__NodeKind_NODE_FUNCTION_TYPE) {
        const uint32_t bt = typechecker__typechecker__TypeChecker__lower_type_in(self, fmod, wbid);
        if (wt != ast__ast__TYPE_NONE) {
          const ast__ast__Ty wy = (*typechecker__typechecker__TypeChecker__type_at(self, wt));
          if ((wy.kind != ast__ast__TypeKind_TYPE_GENERIC) && ((wy.kind != ast__ast__TypeKind_TYPE_FUNCTION) || (!typechecker__typechecker__TypeChecker__fn_compatible_subst(self, bt, wt, gparams, gargs, gn, rsubp, rsuba, nrsub)))) {
            typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
            typechecker__typechecker__TypeChecker__render_type(self, wt, ((char *)(&tn.b[0])), 96ULL);
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc188 = String__Global__new();
String__Global__push_str(&__sc188, (str){ .ptr = (const uint8_t*)"type '", .len = sizeof("type '") - 1 });
String__Global__push_str(&__sc188, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc188, (str){ .ptr = (const uint8_t*)"' does not satisfy a where-clause bound", .len = sizeof("' does not satisfy a where-clause bound") - 1 });
__sc188; }));
          }
        }
      } else {
        const ast__ast__DefId bi = ast__ast__Ast__resolution_def(&((*fa)), wbid);
        if ((bi.node != ast__ast__NODE_NONE) && (!typechecker__typechecker__TypeChecker__type_satisfies(self, wt, bi, 0))) {
          typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, wt, ((char *)(&tn.b[0])), 96ULL);
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc189 = String__Global__new();
String__Global__push_str(&__sc189, (str){ .ptr = (const uint8_t*)"type '", .len = sizeof("type '") - 1 });
String__Global__push_str(&__sc189, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc189, (str){ .ptr = (const uint8_t*)"' does not satisfy a where-clause bound", .len = sizeof("' does not satisfy a where-clause bound") - 1 });
__sc189; }));
        }
      }
    }
  }
}

static __attribute__((unused)) uint8_t typechecker__typechecker__if_u8(bool const c, uint8_t const a, uint8_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_member(typechecker__typechecker__TypeChecker *const self, uint32_t const id, bool const prefer_method) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t want = self->expected;
  (self->expected = ast__ast__TYPE_NONE);
  const uint32_t obj_node = ast__ast__Ast__at_const(&((*a)), id)->as_data.member.object;
  const uint32_t obj = typechecker__typechecker__TypeChecker__check_expr(self, obj_node);
  if (obj == ast__ast__TYPE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  const uint32_t mname = ast__ast__Ast__at_const(&((*a)), id)->as_data.member.member;
  const lexer__token__Span name = typechecker__typechecker__TypeChecker__name_span(self, mname);
  const uint32_t base = typechecker__typechecker__TypeChecker__strip(self, obj);
  uint16_t bmod = 0U;
  uint32_t bdecl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (typechecker__typechecker__TypeChecker__aggregate_of(self, base, ((uint16_t *)(&bmod)), ((uint32_t *)(&bdecl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    ast__ast__DefId mhit = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    uint32_t fhit = ast__ast__NODE_NONE;
    bool digits = ((name.end > name.start) && ((name.end - name.start) <= 2U));
    uint32_t di = name.start;
    while ((di < name.end) && digits) {
      if ((self->source[((size_t)di)] < 48U) || (self->source[((size_t)di)] > 57U)) {
        (digits = false);
      }
      (di = (di + 1U));
    }
    if (digits) {
      const ast__ast__Node *const bd0 = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), bdecl);
      if ((bd0->kind == ast__ast__NodeKind_NODE_STRUCT) && bd0->as_data.aggregate.is_tuple) {
        uint32_t idx = 0U;
        uint32_t k = name.start;
        while (k < name.end) {
          (idx = ((idx * 10U) + ((uint32_t)((uint8_t)((uint32_t)self->source[((size_t)k)] - (uint32_t)48U)))));
          (k = (k + 1U));
        }
        if (idx >= bd0->as_data.aggregate.members.len) {
          utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc190 = String__Global__new();
String__Global__push_str(&__sc190, (str){ .ptr = (const uint8_t*)"tuple struct has no element ", .len = sizeof("tuple struct has no element ") - 1 });
String__Global__push_u64(&__sc190, (uint64_t)(idx));
__sc190; }));
          return ast__ast__TYPE_NONE;
        }
        const uint32_t tnode = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), bd0->as_data.aggregate.members)[((size_t)idx)];
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, (ast__ast__DefId){ .module = bmod, .node = tnode });
        return typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, bmod, tnode), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn);
      }
      typechecker__typechecker__Buf96 fld = (typechecker__typechecker__Buf96){0};
      snprintf(((char *)(&fld.b[0])), 8ULL, ((const char *)({ __auto_type __sc191 = (str){ (const uint8_t *)"_%.*s", sizeof("_%.*s") - 1 }; str__ptr(&__sc191); })), ((int32_t)(name.end - name.start)), typechecker__typechecker__src_at(self->source, name.start));
      (fhit = typechecker__typechecker__TypeChecker__find_member_cstr(self, bmod, bdecl, utils__errors__cstr(((const char *)(&fld.b[0])))));
    }
    if ((fhit == ast__ast__NODE_NONE) && prefer_method) {
      (mhit = typechecker__typechecker__TypeChecker__find_method(self, bmod, bdecl, name));
      if (mhit.node == ast__ast__NODE_NONE) {
        (fhit = typechecker__typechecker__TypeChecker__find_member(self, bmod, bdecl, name));
      }
    } else if (fhit == ast__ast__NODE_NONE) {
      (fhit = typechecker__typechecker__TypeChecker__find_member(self, bmod, bdecl, name));
      if (fhit == ast__ast__NODE_NONE) {
        (mhit = typechecker__typechecker__TypeChecker__find_method(self, bmod, bdecl, name));
      }
    }
    if (mhit.node != ast__ast__NODE_NONE) {
      ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, mhit);
      return typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, mhit.module, mhit.node), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn);
    }
    if (fhit != ast__ast__NODE_NONE) {
      ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, (ast__ast__DefId){ .module = bmod, .node = fhit });
      if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), fhit)->kind == ast__ast__NodeKind_NODE_FIELD) {
        typechecker__typechecker__TypeChecker__check_field_visibility(self, bmod, fhit, bdecl, name);
        if ((self->unsafe_depth == 0U) && typechecker__typechecker__TypeChecker__through_raw_pointer(self, obj)) {
          typechecker__typechecker__TypeChecker__err_unsafe(self, ast__ast__Ast__at_const(&((*a)), id)->span, (str){ (const uint8_t *)"accessing a field through a raw pointer", sizeof("accessing a field through a raw pointer") - 1 });
        }
      }
      return typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, bmod, fhit), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn);
    }
    if (prefer_method) {
      const ast__ast__DefId dm = typechecker__typechecker__TypeChecker__find_default_method(self, bmod, bdecl, name);
      if (dm.node != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, dm);
        return typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, dm.module, dm.node), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn);
      }
    }
  }
  const ast__ast__Ty bty = (*typechecker__typechecker__TypeChecker__type_at(self, base));
  if ((bty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) {
    const uint32_t bd = module__loader__Package__builtin_decl(&((*self->package)), bty.as_data.builtin);
    if (bd != ast__ast__NODE_NONE) {
      ast__ast__DefId mhit = typechecker__typechecker__TypeChecker__find_method(self, (*self->package).core_module, bd, name);
      if (mhit.node == ast__ast__NODE_NONE) {
        (mhit = typechecker__typechecker__TypeChecker__find_default_method(self, (*self->package).core_module, bd, name));
      }
      if (mhit.node != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, mhit);
        return typechecker__typechecker__TypeChecker__decl_type_in(self, mhit.module, mhit.node);
      }
    }
  }
  const ast__ast__Ty bt2 = (*typechecker__typechecker__TypeChecker__type_at(self, base));
  if ((bt2.kind == ast__ast__TypeKind_TYPE_GENERIC) || (bt2.kind == ast__ast__TypeKind_TYPE_DYN)) {
    const ast__ast__Node *const gd = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bt2.module))), bt2.as_data.decl);
    if (gd->kind == ast__ast__NodeKind_NODE_INTERFACE) {
      const ast__ast__DefId m = typechecker__typechecker__TypeChecker__find_interface_method(self, bt2.module, bt2.as_data.decl, name, 0);
      if (m.node != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, m);
        return typechecker__typechecker__TypeChecker__decl_type_in(self, m.module, m.node);
      }
    } else {
      ast__ast__DefId iface = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
      const ast__ast__DefId m = typechecker__typechecker__TypeChecker__find_bound_method(self, bt2.module, bt2.as_data.decl, name, ((ast__ast__DefId *)(&iface)));
      if (m.node != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, m);
        return typechecker__typechecker__TypeChecker__decl_type_in(self, m.module, m.node);
      }
    }
  }
  if (prefer_method) {
    const ast__ast__DefId conv = typechecker__typechecker__TypeChecker__resolve_conversion(self, name, want);
    if (conv.node != ast__ast__NODE_NONE) {
      ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, conv);
      return typechecker__typechecker__TypeChecker__decl_type_in(self, conv.module, conv.node);
    }
  }
  bool deref_capped = false;
  if (prefer_method) {
    ast__ast__DerefUse du = (ast__ast__DerefUse){ .node = mname, .n = 0U };
    uint32_t cur = base;
    typechecker__typechecker__Tys8 seen = (typechecker__typechecker__Tys8){0};
    (seen.t[0] = base);
    int32_t nseen = 1;
    for (;;) {
      if (du.n >= 8U) {
        break;
      }
      uint16_t cm = 0U;
      uint32_t cd = ast__ast__NODE_NONE;
      typechecker__typechecker__Defs4 cgp = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 cga = (typechecker__typechecker__Tys4){0};
      int32_t cgn = 0;
      if (!typechecker__typechecker__TypeChecker__aggregate_of(self, cur, ((uint16_t *)(&cm)), ((uint32_t *)(&cd)), ((ast__ast__DefId *)(&cgp.d[0])), ((uint32_t *)(&cga.t[0])), ((int32_t *)(&cgn)))) {
        break;
      }
      const ast__ast__DefId dm = typechecker__typechecker__TypeChecker__find_method_cstr(self, cm, cd, (str){ (const uint8_t *)"deref", sizeof("deref") - 1 });
      if (dm.node == ast__ast__NODE_NONE) {
        break;
      }
      const uint32_t dret = typechecker__typechecker__TypeChecker__tc_method_ret(self, cur, dm);
      if (dret == ast__ast__TYPE_NONE) {
        break;
      }
      const ast__ast__Ty dry = (*typechecker__typechecker__TypeChecker__type_at(self, dret));
      if ((dry.kind != ast__ast__TypeKind_TYPE_REFERENCE) && (dry.kind != ast__ast__TypeKind_TYPE_POINTER)) {
        break;
      }
      const uint32_t target = dry.as_data.elem;
      bool cyc = false;
      for (int32_t z = 0; z < nseen; z++) {
        if (seen.t[((size_t)z)] == target) {
          (cyc = true);
        }
      }
      if (cyc) {
        utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc192 = String__Global__new();
String__Global__push_str(&__sc192, (str){ .ptr = (const uint8_t*)"cyclic deref chain while resolving '", .len = sizeof("cyclic deref chain while resolving '") - 1 });
String__Global__push_str(&__sc192, utils__errors__span_str(self->source, name.start, name.end));
String__Global__push_str(&__sc192, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc192; }));
        return ast__ast__TYPE_NONE;
      }
      (du.recv[((size_t)du.n)] = cur);
      (du.method[((size_t)du.n)] = dm);
      (du.n = ((uint8_t)((uint32_t)du.n + (uint32_t)1U)));
      (seen.t[((size_t)nseen)] = target);
      (nseen = ({ int32_t __sc_r; if (__builtin_add_overflow(nseen, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      uint16_t tm = 0U;
      uint32_t td = ast__ast__NODE_NONE;
      typechecker__typechecker__Defs4 tgp = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 tga = (typechecker__typechecker__Tys4){0};
      int32_t tgn = 0;
      ast__ast__DefId mhit = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
      const ast__ast__Ty tty = (*typechecker__typechecker__TypeChecker__type_at(self, target));
      if (typechecker__typechecker__TypeChecker__aggregate_of(self, target, ((uint16_t *)(&tm)), ((uint32_t *)(&td)), ((ast__ast__DefId *)(&tgp.d[0])), ((uint32_t *)(&tga.t[0])), ((int32_t *)(&tgn)))) {
        (mhit = typechecker__typechecker__TypeChecker__find_method(self, tm, td, name));
        if (mhit.node == ast__ast__NODE_NONE) {
          (mhit = typechecker__typechecker__TypeChecker__find_default_method(self, tm, td, name));
        }
      } else if ((tty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) {
        const uint32_t bd = module__loader__Package__builtin_decl(&((*self->package)), tty.as_data.builtin);
        if (bd != ast__ast__NODE_NONE) {
          (mhit = typechecker__typechecker__TypeChecker__find_method(self, (*self->package).core_module, bd, name));
          if (mhit.node == ast__ast__NODE_NONE) {
            (mhit = typechecker__typechecker__TypeChecker__find_default_method(self, (*self->package).core_module, bd, name));
          }
        }
      }
      if (mhit.node != ast__ast__NODE_NONE) {
        const int32_t sk = typechecker__typechecker__TypeChecker__method_self_kind(self, mhit);
        if ((sk == 0) && (tty.kind != ast__ast__TypeKind_TYPE_BUILTIN)) {
          utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc193 = String__Global__new();
String__Global__push_str(&__sc193, (str){ .ptr = (const uint8_t*)"cannot call a by-value 'self' method through auto-deref", .len = sizeof("cannot call a by-value 'self' method through auto-deref") - 1 });
__sc193; }));
          return ast__ast__TYPE_NONE;
        }
        if (sk == 2) {
          for (uint8_t hi = 0U; hi < du.n; hi++) {
            uint16_t hm = 0U;
            uint32_t hd = ast__ast__NODE_NONE;
            typechecker__typechecker__Defs4 hgp = (typechecker__typechecker__Defs4){0};
            typechecker__typechecker__Tys4 hga = (typechecker__typechecker__Tys4){0};
            int32_t hgn = 0;
            typechecker__typechecker__TypeChecker__aggregate_of(self, du.recv[((size_t)hi)], ((uint16_t *)(&hm)), ((uint32_t *)(&hd)), ((ast__ast__DefId *)(&hgp.d[0])), ((uint32_t *)(&hga.t[0])), ((int32_t *)(&hgn)));
            const ast__ast__DefId dmm = typechecker__typechecker__TypeChecker__find_method_cstr(self, hm, hd, (str){ (const uint8_t *)"deref_mut", sizeof("deref_mut") - 1 });
            if (dmm.node == ast__ast__NODE_NONE) {
              typechecker__typechecker__Buf96 tn = (typechecker__typechecker__Buf96){0};
              typechecker__typechecker__TypeChecker__render_type(self, du.recv[((size_t)hi)], ((char *)(&tn.b[0])), 96ULL);
              utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc194 = String__Global__new();
String__Global__push_str(&__sc194, (str){ .ptr = (const uint8_t*)"cannot call a '&mut self' method through '", .len = sizeof("cannot call a '&mut self' method through '") - 1 });
String__Global__push_str(&__sc194, utils__errors__cstr(((const char *)(&tn.b[0]))));
String__Global__push_str(&__sc194, (str){ .ptr = (const uint8_t*)"': it has 'deref' but no 'deref_mut'", .len = sizeof("': it has 'deref' but no 'deref_mut'") - 1 });
__sc194; }));
              return ast__ast__TYPE_NONE;
            }
            (du.method[((size_t)hi)] = dmm);
          }
        }
        (du.target = target);
        ast__ast__Ast__add_deref_use(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (&du));
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mname, mhit);
        return typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, mhit.module, mhit.node), ((const ast__ast__DefId *)(&tgp.d[0])), ((const uint32_t *)(&tga.t[0])), tgn);
      }
      (cur = target);
    }
    (deref_capped = (du.n == 8U));
  }
  typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
  typechecker__typechecker__TypeChecker__render_type(self, base, ((char *)(&ty.b[0])), 96ULL);
  utils__errors__Errors__emit(&self->errors, name.start, (name.end - name.start), ({ String__Global __sc195 = String__Global__new();
String__Global__push_str(&__sc195, (str){ .ptr = (const uint8_t*)"no field or method '", .len = sizeof("no field or method '") - 1 });
String__Global__push_str(&__sc195, utils__errors__span_str(self->source, name.start, name.end));
String__Global__push_str(&__sc195, (str){ .ptr = (const uint8_t*)"' on '", .len = sizeof("' on '") - 1 });
String__Global__push_str(&__sc195, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc195, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc195; }));
  if (deref_capped) {
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc196 = String__Global__new();
String__Global__push_str(&__sc196, (str){ .ptr = (const uint8_t*)"auto-deref stopped after its maximum of 8 hops", .len = sizeof("auto-deref stopped after its maximum of 8 hops") - 1 });
__sc196; }));
  } else {
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc197 = String__Global__new();
String__Global__push_str(&__sc197, (str){ .ptr = (const uint8_t*)"fields are accessed as 'value.name'; methods must be declared in an 'extend' block or provided by a bound", .len = sizeof("fields are accessed as 'value.name'; methods must be declared in an 'extend' block or provided by a bound") - 1 });
__sc197; }));
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_path_member(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const expected) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__DefId direct = ast__ast__Ast__resolution_def(&((*a)), id);
  const uint32_t mem = ast__ast__Ast__at_const(&((*a)), id)->as_data.member.member;
  if (direct.node != ast__ast__NODE_NONE) {
    if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, direct.module))), direct.node)->kind == ast__ast__NodeKind_NODE_FUNCTION) {
      ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mem, direct);
      return typechecker__typechecker__TypeChecker__decl_type_in(self, direct.module, direct.node);
    }
    return typechecker__typechecker__TypeChecker__named_type_of(self, direct.module, direct.node);
  }
  const uint32_t obj = ast__ast__Ast__at_const(&((*a)), id)->as_data.member.object;
  const ast__ast__NodeKind on_kind = ast__ast__Ast__at_const(&((*a)), obj)->kind;
  uint16_t bmod = 0U;
  uint32_t bdecl = ast__ast__NODE_NONE;
  uint32_t inst_ty = ast__ast__TYPE_NONE;
  if (on_kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    const ast__ast__DefId b = ast__ast__Ast__resolution_def(&((*a)), obj);
    (bmod = b.module);
    (bdecl = b.node);
    if ((bdecl == ast__ast__NODE_NONE) && (self->package != NULL)) {
      const int32_t bb = typechecker__typechecker__builtin_of(self->source, ast__ast__Ast__at_const(&((*a)), obj)->span);
      uint32_t bnd = ast__ast__NODE_NONE;
      if (bb >= 0) {
        (bnd = module__loader__Package__builtin_decl(&((*self->package)), ((ast__ast__BuiltinType)bb)));
      }
      if (bnd != ast__ast__NODE_NONE) {
        (bmod = (*self->package).core_module);
        (bdecl = bnd);
      }
    }
    if ((bdecl != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), bdecl)->kind == ast__ast__NodeKind_NODE_TYPE_ALIAS)) {
      const uint32_t at = typechecker__typechecker__TypeChecker__named_type_of(self, bmod, bdecl);
      if ((at != ast__ast__TYPE_NONE) && (at != typechecker__typechecker__TYPE_ERROR)) {
        const ast__ast__Ty aty = (*typechecker__typechecker__TypeChecker__type_at(self, at));
        if ((aty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) {
          (bmod = (*self->package).core_module);
          (bdecl = module__loader__Package__builtin_decl(&((*self->package)), aty.as_data.builtin));
        } else if ((aty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (aty.kind == ast__ast__TypeKind_TYPE_ENUM)) {
          (bmod = aty.module);
          (bdecl = aty.as_data.decl);
        } else if (aty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
          const ast__ast__TyInstance ai = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), aty.as_data.inst));
          (bmod = ai.module);
          (bdecl = ai.decl);
          (inst_ty = at);
          ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), obj, at);
        }
      }
    }
    if (bdecl != ast__ast__NODE_NONE) {
      const ast__ast__Node *const bdn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), bdecl);
      if ((((bdn->kind == ast__ast__NodeKind_NODE_STRUCT) || (bdn->kind == ast__ast__NodeKind_NODE_ENUM)) && (bdn->as_data.aggregate.generics.len > 0U)) && typechecker__typechecker__TypeChecker__agg_has_default_at(self, bmod, bdecl, 0U)) {
        typechecker__typechecker__Tys4 ta = (typechecker__typechecker__Tys4){0};
        uint8_t tn = 0U;
        typechecker__typechecker__TypeChecker__apply_default_args(self, bmod, bdecl, ((uint32_t *)(&ta.t[0])), ((uint8_t *)(&tn)));
        if (tn == ((uint8_t)bdn->as_data.aggregate.generics.len)) {
          (inst_ty = ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), bmod, bdecl, ((const uint32_t *)(&ta.t[0])), tn));
          ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), obj, inst_ty);
        }
      }
    }
  } else {
    const uint32_t bt = typechecker__typechecker__TypeChecker__check_expr(self, obj);
    const ast__ast__Ty ty = (*typechecker__typechecker__TypeChecker__type_at(self, bt));
    if (ty.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
      const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ty.as_data.inst));
      (bmod = it.module);
      (bdecl = it.decl);
      (inst_ty = bt);
    } else if ((ty.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (self->package != NULL)) {
      (bmod = (*self->package).core_module);
      (bdecl = module__loader__Package__builtin_decl(&((*self->package)), ty.as_data.builtin));
    } else {
      (bmod = ty.module);
      (bdecl = typechecker__typechecker__if_node(((bt != ast__ast__TYPE_NONE) && ((ty.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ty.kind == ast__ast__TypeKind_TYPE_ENUM))), ty.as_data.decl, ast__ast__NODE_NONE));
    }
  }
  const lexer__token__Span mname = typechecker__typechecker__TypeChecker__name_span(self, mem);
  ast__ast__NodeKind bd_kind = ast__ast__NodeKind_NODE_NONE_KIND;
  if (bdecl != ast__ast__NODE_NONE) {
    (bd_kind = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), bdecl)->kind);
  }
  if ((bdecl != ast__ast__NODE_NONE) && (bd_kind == ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
    ast__ast__DefId iface = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
    const ast__ast__DefId m = typechecker__typechecker__TypeChecker__find_bound_method(self, bmod, bdecl, mname, ((ast__ast__DefId *)(&iface)));
    if (m.node != ast__ast__NODE_NONE) {
      ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mem, m);
      return typechecker__typechecker__TypeChecker__decl_type_in(self, m.module, m.node);
    }
  }
  if (((bdecl != ast__ast__NODE_NONE) && (bd_kind == ast__ast__NodeKind_NODE_INTERFACE)) && (expected != ast__ast__TYPE_NONE)) {
    uint16_t emod = 0U;
    uint32_t edecl = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 egp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ega = (typechecker__typechecker__Tys4){0};
    int32_t egn = 0;
    if (typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, expected), ((uint16_t *)(&emod)), ((uint32_t *)(&edecl)), ((ast__ast__DefId *)(&egp.d[0])), ((uint32_t *)(&ega.t[0])), ((int32_t *)(&egn)))) {
      const ast__ast__DefId m = typechecker__typechecker__TypeChecker__find_method(self, emod, edecl, mname);
      if (m.node != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mem, m);
        return typechecker__typechecker__TypeChecker__decl_type_in(self, m.module, m.node);
      }
    }
  }
  if ((bdecl == ast__ast__NODE_NONE) || ((bd_kind != ast__ast__NodeKind_NODE_STRUCT) && (bd_kind != ast__ast__NodeKind_NODE_ENUM))) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    if ((bdecl != ast__ast__NODE_NONE) && (bd_kind == ast__ast__NodeKind_NODE_INTERFACE)) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc198 = String__Global__new();
String__Global__push_str(&__sc198, (str){ .ptr = (const uint8_t*)"cannot infer the implementing type for this interface call", .len = sizeof("cannot infer the implementing type for this interface call") - 1 });
__sc198; }));
    } else {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc199 = String__Global__new();
String__Global__push_str(&__sc199, (str){ .ptr = (const uint8_t*)"'::' base must be a struct or enum type", .len = sizeof("'::' base must be a struct or enum type") - 1 });
__sc199; }));
    }
    return ast__ast__TYPE_NONE;
  }
  if (bd_kind == ast__ast__NodeKind_NODE_ENUM) {
    const uint32_t variant = typechecker__typechecker__TypeChecker__find_member(self, bmod, bdecl, mname);
    if ((variant != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), variant)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mem, (ast__ast__DefId){ .module = bmod, .node = variant });
      return typechecker__typechecker__if_ty((inst_ty != ast__ast__TYPE_NONE), inst_ty, typechecker__typechecker__TypeChecker__named_type_of(self, bmod, bdecl));
    }
  }
  const ast__ast__DefId method = typechecker__typechecker__TypeChecker__find_method(self, bmod, bdecl, mname);
  if (method.node != ast__ast__NODE_NONE) {
    ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mem, method);
    return typechecker__typechecker__TypeChecker__decl_type_in(self, method.module, method.node);
  }
  const ast__ast__DefId ac = typechecker__typechecker__TypeChecker__find_assoc_const(self, bmod, bdecl, mname);
  if (ac.node != ast__ast__NODE_NONE) {
    ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mem, ac);
    return typechecker__typechecker__TypeChecker__decl_type_in(self, ac.module, ac.node);
  }
  const char *kindw = ((const char *)({ __auto_type __sc200 = (str){ (const uint8_t *)"associated method or constant", sizeof("associated method or constant") - 1 }; str__ptr(&__sc200); }));
  if (bd_kind == ast__ast__NodeKind_NODE_ENUM) {
    (kindw = ((const char *)({ __auto_type __sc201 = (str){ (const uint8_t *)"variant, method, or constant", sizeof("variant, method, or constant") - 1 }; str__ptr(&__sc201); })));
  }
  utils__errors__Errors__emit(&self->errors, mname.start, (mname.end - mname.start), ({ String__Global __sc202 = String__Global__new();
String__Global__push_str(&__sc202, (str){ .ptr = (const uint8_t*)"no ", .len = sizeof("no ") - 1 });
String__Global__push_str(&__sc202, utils__errors__cstr(kindw));
String__Global__push_str(&__sc202, (str){ .ptr = (const uint8_t*)" '", .len = sizeof(" '") - 1 });
String__Global__push_str(&__sc202, utils__errors__span_str(self->source, mname.start, mname.end));
String__Global__push_str(&__sc202, (str){ .ptr = (const uint8_t*)"' on this type", .len = sizeof("' on this type") - 1 });
__sc202; }));
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_struct_init(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t stn = ast__ast__Ast__at_const(&((*a)), id)->as_data.struct_initializer.ty;
  const uint32_t sty = typechecker__typechecker__TypeChecker__type_of_type_node(self, stn);
  uint16_t smod = 0U;
  uint32_t decl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  if (!typechecker__typechecker__TypeChecker__aggregate_of(self, sty, ((uint16_t *)(&smod)), ((uint32_t *)(&decl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
    (decl = ast__ast__NODE_NONE);
  }
  uint32_t variant = ast__ast__NODE_NONE;
  uint16_t vmod = smod;
  if (ast__ast__Ast__at_const(&((*a)), stn)->kind == ast__ast__NodeKind_NODE_TYPE_PATH) {
    const ast__ast__NodeList parts = ast__ast__Ast__at_const(&((*a)), stn)->as_data.type_path.parts;
    if (parts.len >= 2U) {
      const ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__list(&((*a)), parts)[((size_t)(parts.len - 1U))]);
      if ((vd.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
        (variant = vd.node);
        (vmod = vd.module);
      }
    }
  }
  const ast__ast__NodeList fields = ast__ast__Ast__at_const(&((*a)), id)->as_data.struct_initializer.fields;
  for (uint32_t i = 0U; i < fields.len; i++) {
    const uint32_t fid = ast__ast__Ast__list(&((*a)), fields)[((size_t)i)];
    const uint32_t fnn = ast__ast__Ast__at_const(&((*a)), fid)->as_data.field_initializer.name;
    const uint32_t fval = ast__ast__Ast__at_const(&((*a)), fid)->as_data.field_initializer.value;
    const lexer__token__Span fname = typechecker__typechecker__TypeChecker__name_span(self, fnn);
    if (((variant == ast__ast__NODE_NONE) && (decl != ast__ast__NODE_NONE)) && typechecker__typechecker__TypeChecker__tc_is_iface_assoc_call(self, fval)) {
      const uint32_t field = typechecker__typechecker__TypeChecker__find_member(self, smod, decl, fname);
      const uint32_t ft = typechecker__typechecker__if_ty((field != ast__ast__NODE_NONE), typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, smod, field), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn), ast__ast__TYPE_NONE);
      if ((ft != ast__ast__TYPE_NONE) && ast__ast__Ast__type_concrete(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ft)) {
        (self->expected = ft);
      }
    }
    typechecker__typechecker__TypeChecker__check_expr(self, fval);
    typechecker__typechecker__TypeChecker__tc_mark_move(self, fval);
    if (variant != ast__ast__NODE_NONE) {
      ast__ast__Ast *const va = typechecker__typechecker__TypeChecker__mod_ast(self, vmod);
      const ast__ast__NodeList vpl = ast__ast__Ast__at_const(&((*va)), variant)->as_data.variant.payload;
      uint32_t field = ast__ast__NODE_NONE;
      for (uint32_t j = 0U; j < vpl.len; j++) {
        const uint32_t pfid = ast__ast__Ast__list(&((*va)), vpl)[((size_t)j)];
        const ast__ast__Node *const pf = ast__ast__Ast__at_const(&((*va)), pfid);
        if ((pf->kind == ast__ast__NodeKind_NODE_FIELD) && typechecker__typechecker__spans_eq2(self->source, fname, typechecker__typechecker__TypeChecker__mod_src(self, vmod), ast__ast__Ast__at_const(&((*va)), pf->as_data.field.name)->as_data.name.text)) {
          (field = pfid);
          break;
        }
      }
      if (field == ast__ast__NODE_NONE) {
        typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, sty, ((char *)(&ty.b[0])), 96ULL);
        utils__errors__Errors__emit(&self->errors, fname.start, (fname.end - fname.start), ({ String__Global __sc203 = String__Global__new();
String__Global__push_str(&__sc203, (str){ .ptr = (const uint8_t*)"no field '", .len = sizeof("no field '") - 1 });
String__Global__push_str(&__sc203, utils__errors__span_str(self->source, fname.start, fname.end));
String__Global__push_str(&__sc203, (str){ .ptr = (const uint8_t*)"' on '", .len = sizeof("' on '") - 1 });
String__Global__push_str(&__sc203, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc203, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc203; }));
      } else {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), fnn, (ast__ast__DefId){ .module = vmod, .node = field });
        const uint32_t ft = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, vmod, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, vmod))), field)->as_data.field.ty), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn);
        if (!typechecker__typechecker__TypeChecker__compatible(self, ft, fval)) {
          typechecker__typechecker__TypeChecker__err_mismatch(self, fval, ft);
        }
      }
      continue;
    }
    if (decl == ast__ast__NODE_NONE) {
      continue;
    }
    const uint32_t field = typechecker__typechecker__TypeChecker__find_member(self, smod, decl, fname);
    if (field == ast__ast__NODE_NONE) {
      typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
      typechecker__typechecker__TypeChecker__render_type(self, sty, ((char *)(&ty.b[0])), 96ULL);
      utils__errors__Errors__emit(&self->errors, fname.start, (fname.end - fname.start), ({ String__Global __sc204 = String__Global__new();
String__Global__push_str(&__sc204, (str){ .ptr = (const uint8_t*)"no field '", .len = sizeof("no field '") - 1 });
String__Global__push_str(&__sc204, utils__errors__span_str(self->source, fname.start, fname.end));
String__Global__push_str(&__sc204, (str){ .ptr = (const uint8_t*)"' on '", .len = sizeof("' on '") - 1 });
String__Global__push_str(&__sc204, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc204, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc204; }));
      continue;
    }
    ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), fnn, (ast__ast__DefId){ .module = smod, .node = field });
    typechecker__typechecker__TypeChecker__check_field_visibility(self, smod, field, decl, fname);
    const uint32_t ft = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, smod, field), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn);
    if (!typechecker__typechecker__TypeChecker__compatible(self, ft, fval)) {
      typechecker__typechecker__TypeChecker__err_mismatch(self, fval, ft);
    }
  }
  return sty;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_if_stmt(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__IfData ifd = ast__ast__Ast__at_const(&((*a)), id)->as_data.if_stmt;
  const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
  const uint32_t c = typechecker__typechecker__TypeChecker__check_expr(self, ifd.condition);
  if ((c != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, c))) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), ifd.condition)->span;
    typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, c, ((char *)(&ty.b[0])), 96ULL);
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc205 = String__Global__new();
String__Global__push_str(&__sc205, (str){ .ptr = (const uint8_t*)"if condition must be 'bool', found '", .len = sizeof("if condition must be 'bool', found '") - 1 });
String__Global__push_str(&__sc205, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc205, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc205; }));
  }
  typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
  const typechecker__typechecker__FlowState pre = typechecker__typechecker__TypeChecker__tc_flow_save(self);
  typechecker__typechecker__TypeChecker__check_stmt(self, ifd.then_branch);
  typechecker__typechecker__FlowState acc = (typechecker__typechecker__FlowState){0};
  bool ovf = false;
  if (!typechecker__typechecker__TypeChecker__tc_stmt_returns(self, ifd.then_branch)) {
    if (typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)))) {
      (ovf = true);
    }
  }
  typechecker__typechecker__TypeChecker__tc_flow_set(self, (&pre));
  typechecker__typechecker__TypeChecker__check_stmt(self, ifd.else_branch);
  if (!typechecker__typechecker__TypeChecker__tc_stmt_returns(self, ifd.else_branch)) {
    if (typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)))) {
      (ovf = true);
    }
  }
  typechecker__typechecker__TypeChecker__tc_flow_set(self, (&acc));
  if (ovf) {
    typechecker__typechecker__TypeChecker__tc_flow_overflow(self, ifd.condition);
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__pattern_irrefutable(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return true;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__Node *const p = ast__ast__Ast__at_const(&((*a)), id);
  if ((p->kind == ast__ast__NodeKind_NODE_PATTERN_WILDCARD) || (p->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    return true;
  }
  if (((p->kind == ast__ast__NodeKind_NODE_PATTERN_NAME) || (p->kind == ast__ast__NodeKind_NODE_PATTERN_TUPLE)) || (p->kind == ast__ast__NodeKind_NODE_PATTERN_STRUCT)) {
    const uint32_t nameId = p->as_data.pattern.name;
    if (nameId != ast__ast__NODE_NONE) {
      const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), nameId);
      if ((d.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
        return false;
      }
    }
    if (p->kind == ast__ast__NodeKind_NODE_PATTERN_NAME) {
      return true;
    }
    const ast__ast__NodeList children = p->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      if (!typechecker__typechecker__TypeChecker__pattern_irrefutable(self, ast__ast__Ast__list(&((*a)), children)[((size_t)i)])) {
        return false;
      }
    }
    return true;
  }
  if (p->kind == ast__ast__NodeKind_NODE_PATTERN_FIELD) {
    const ast__ast__NodeList children = p->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      if (!typechecker__typechecker__TypeChecker__pattern_irrefutable(self, ast__ast__Ast__list(&((*a)), children)[((size_t)i)])) {
        return false;
      }
    }
    return true;
  }
  if (p->kind == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList children = p->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      if (typechecker__typechecker__TypeChecker__pattern_irrefutable(self, ast__ast__Ast__list(&((*a)), children)[((size_t)i)])) {
        return true;
      }
    }
    return false;
  }
  return false;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__pattern_covered_variant(const typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__Node *const p = ast__ast__Ast__at_const(&((*a)), id);
  if (((p->kind != ast__ast__NodeKind_NODE_PATTERN_NAME) && (p->kind != ast__ast__NodeKind_NODE_PATTERN_TUPLE)) && (p->kind != ast__ast__NodeKind_NODE_PATTERN_STRUCT)) {
    return ast__ast__NODE_NONE;
  }
  const uint32_t nameId = p->as_data.pattern.name;
  if (nameId == ast__ast__NODE_NONE) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), nameId);
  if ((d.node == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_VARIANT)) {
    return ast__ast__NODE_NONE;
  }
  const ast__ast__NodeList children = p->as_data.pattern.children;
  for (uint32_t i = 0U; i < children.len; i++) {
    if (!typechecker__typechecker__TypeChecker__pattern_irrefutable(self, ast__ast__Ast__list(&((*a)), children)[((size_t)i)])) {
      return ast__ast__NODE_NONE;
    }
  }
  return d.node;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__match_arm_coverage(const typechecker__typechecker__TypeChecker *const self, uint32_t const pid, uint16_t const emod, bool const has_ea, ast__ast__NodeList const variants, uint64_t *const covered, bool *const catchall, bool *const tcov, bool *const fcov) {
  if (pid == ast__ast__NODE_NONE) {
    return;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__Node *const p = ast__ast__Ast__at_const(&((*a)), pid);
  if (p->kind == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList children = p->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      typechecker__typechecker__TypeChecker__match_arm_coverage(self, ast__ast__Ast__list(&((*a)), children)[((size_t)i)], emod, has_ea, variants, covered, catchall, tcov, fcov);
    }
    return;
  }
  if (typechecker__typechecker__TypeChecker__pattern_irrefutable(self, pid)) {
    ((*catchall) = true);
    return;
  }
  if (p->kind == ast__ast__NodeKind_NODE_PATTERN_LITERAL) {
    const ast__ast__Node *const v = ast__ast__Ast__at_const(&((*a)), p->as_data.single.value);
    if ((v->kind == ast__ast__NodeKind_NODE_LITERAL) && (v->as_data.literal.token_type == lexer__token_type__TokenType_True)) {
      ((*tcov) = true);
    } else if ((v->kind == ast__ast__NodeKind_NODE_LITERAL) && (v->as_data.literal.token_type == lexer__token_type__TokenType_False)) {
      ((*fcov) = true);
    }
    return;
  }
  const uint32_t var = typechecker__typechecker__TypeChecker__pattern_covered_variant(self, pid);
  if ((var == ast__ast__NODE_NONE) || (!has_ea)) {
    return;
  }
  ast__ast__Ast *const ea = typechecker__typechecker__TypeChecker__mod_ast(self, emod);
  uint32_t i = 0U;
  while ((i < variants.len) && (i < typechecker__typechecker__MATCH_MAX_VARIANTS)) {
    if (ast__ast__Ast__list(&((*ea)), variants)[((size_t)i)] == var) {
      const size_t idx = ((size_t)({ uint32_t __sc206 = i; int64_t __sc207 = (int64_t)(6U); if ((uint64_t)__sc207 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc206 >> __sc207); }));
      const uint64_t cur = covered[idx];
      (covered[idx] = (cur | ({ uint64_t __sc208 = 1ULL; int64_t __sc209 = (int64_t)(((uint64_t)(i & 63U))); if ((uint64_t)__sc209 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc208 << __sc209)); })));
      return;
    }
    (i = (i + 1U));
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_match_exhaustive(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const scrut) {
  if (scrut == ast__ast__TYPE_NONE) {
    return;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t base = typechecker__typechecker__TypeChecker__strip(self, scrut);
  uint16_t emod = 0U;
  uint32_t edecl = ast__ast__NODE_NONE;
  typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
  typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
  int32_t gn = 0;
  const bool agok = typechecker__typechecker__TypeChecker__aggregate_of(self, base, ((uint16_t *)(&emod)), ((uint32_t *)(&edecl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
  const bool is_enum = (agok && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, emod))), edecl)->kind == ast__ast__NodeKind_NODE_ENUM));
  ast__ast__NodeList variants = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  if (is_enum) {
    (variants = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, emod))), edecl)->as_data.aggregate.members);
  }
  typechecker__typechecker__Cover4 covered = (typechecker__typechecker__Cover4){0};
  bool catchall = false;
  bool tcov = false;
  bool fcov = false;
  const ast__ast__NodeList arms = ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.arms;
  for (uint32_t i = 0U; i < arms.len; i++) {
    const ast__ast__Node *const arm = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__list(&((*a)), arms)[((size_t)i)]);
    if (arm->as_data.match_arm.guard == ast__ast__NODE_NONE) {
      typechecker__typechecker__TypeChecker__match_arm_coverage(self, arm->as_data.match_arm.pattern, emod, is_enum, variants, ((uint64_t *)(&covered.c[0])), ((bool *)(&catchall)), ((bool *)(&tcov)), ((bool *)(&fcov)));
    }
  }
  if (catchall) {
    return;
  }
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.value)->span;
  if (is_enum && (variants.len <= typechecker__typechecker__MATCH_MAX_VARIANTS)) {
    uint32_t nmiss = 0U;
    for (uint32_t k = 0U; k < variants.len; k++) {
      if ((covered.c[((size_t)({ uint32_t __sc210 = k; int64_t __sc211 = (int64_t)(6U); if ((uint64_t)__sc211 >= 32) { __sc_panic("shift out of range"); } (uint32_t)(__sc210 >> __sc211); }))] & ({ uint64_t __sc212 = 1ULL; int64_t __sc213 = (int64_t)(((uint64_t)(k & 63U))); if ((uint64_t)__sc213 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc212 << __sc213)); })) == 0ULL) {
        (nmiss = (nmiss + 1U));
      }
    }
    if (nmiss == 0U) {
      return;
    }
    const char *s2 = ((const char *)({ __auto_type __sc214 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc214); }));
    if (nmiss == 1U) {
      (s2 = ((const char *)({ __auto_type __sc215 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc215); })));
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc216 = String__Global__new();
String__Global__push_str(&__sc216, (str){ .ptr = (const uint8_t*)"switch is not exhaustive: missing ", .len = sizeof("switch is not exhaustive: missing ") - 1 });
String__Global__push_u64(&__sc216, (uint64_t)(nmiss));
String__Global__push_str(&__sc216, (str){ .ptr = (const uint8_t*)" variant", .len = sizeof(" variant") - 1 });
String__Global__push_str(&__sc216, utils__errors__cstr(s2));
__sc216; }));
    utils__errors__Errors__note(&self->errors, ({ String__Global __sc217 = String__Global__new();
String__Global__push_str(&__sc217, (str){ .ptr = (const uint8_t*)"match every variant or add a '_' arm", .len = sizeof("match every variant or add a '_' arm") - 1 });
__sc217; }));
    return;
  }
  if (((base == 1U) && tcov) && fcov) {
    return;
  }
  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc218 = String__Global__new();
String__Global__push_str(&__sc218, (str){ .ptr = (const uint8_t*)"switch is not exhaustive", .len = sizeof("switch is not exhaustive") - 1 });
__sc218; }));
  utils__errors__Errors__note(&self->errors, ({ String__Global __sc219 = String__Global__new();
String__Global__push_str(&__sc219, (str){ .ptr = (const uint8_t*)"add a '_' arm to cover the remaining values", .len = sizeof("add a '_' arm to cover the remaining values") - 1 });
__sc219; }));
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_assignment(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__BinaryData bd = ast__ast__Ast__at_const(&((*a)), id)->as_data.binary;
  const bool plain = (bd.op == lexer__token_type__TokenType_Equal);
  ast__ast__DefId ld = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  if (plain && (ast__ast__Ast__at_const(&((*a)), bd.left)->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
    (ld = ast__ast__Ast__resolution_def(&((*a)), bd.left));
  }
  const bool lhs_local = ((ld.node != ast__ast__NODE_NONE) && (ld.module == self->ast.module));
  if (lhs_local) {
    typechecker__typechecker__TypeChecker__tc_init(self, ld.node);
    typechecker__typechecker__TypeChecker__tc_unmark_move(self, ld.node);
  }
  const uint32_t lt = typechecker__typechecker__if_ty(lhs_local, typechecker__typechecker__TypeChecker__decl_type_in(self, ld.module, ld.node), ast__ast__TYPE_NONE);
  const bool ref_rebind = ((lt != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, lt)->kind == ast__ast__TypeKind_TYPE_REFERENCE));
  if (ref_rebind) {
    for (uint32_t i = 0U; i < self->nborrows; i++) {
      if (self->borrows[((size_t)i)].binding == ld.node) {
        typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, i);
      }
    }
  }
  const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
  const uint32_t l = typechecker__typechecker__TypeChecker__check_expr(self, bd.left);
  typechecker__typechecker__TypeChecker__tc_mark_capture_mut(self, bd.left);
  (self->expected = l);
  typechecker__typechecker__TypeChecker__check_expr(self, bd.right);
  typechecker__typechecker__TypeChecker__tc_mark_move(self, bd.right);
  if (ref_rebind) {
    if (self->nborrows > bm) {
      const uint16_t region = ((uint16_t)typechecker__typechecker__TypeChecker__tc_binding_depth(self, ld.node));
      uint32_t k = bm;
      while (k < self->nborrows) {
        (self->borrows[((size_t)k)].binding = ld.node);
        (self->borrows[((size_t)k)].region = region);
        (k = (k + 1U));
      }
    } else {
      typechecker__typechecker__TypeChecker__borrow_transfer_ref(self, bd.right, ld.node);
    }
  }
  if (!typechecker__typechecker__TypeChecker__is_assignable(self, bd.left)) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), bd.left)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc220 = String__Global__new();
String__Global__push_str(&__sc220, (str){ .ptr = (const uint8_t*)"cannot assign to this expression", .len = sizeof("cannot assign to this expression") - 1 });
__sc220; }));
  } else if (typechecker__typechecker__TypeChecker__borrow_conflicting_write(self, bd.left, id)) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), bd.left)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc221 = String__Global__new();
String__Global__push_str(&__sc221, (str){ .ptr = (const uint8_t*)"cannot assign to this value while it is borrowed", .len = sizeof("cannot assign to this value while it is borrowed") - 1 });
__sc221; }));
  } else if (!typechecker__typechecker__TypeChecker__compatible(self, l, bd.right)) {
    typechecker__typechecker__TypeChecker__err_mismatch(self, bd.right, l);
  }
  return l;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_closure(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const cwant) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.params;
  typechecker__typechecker__Tys8 sigp = (typechecker__typechecker__Tys8){0};
  uint32_t sigr = ast__ast__TYPE_NONE;
  int32_t sn = -1;
  for (uint32_t i = 0U; i < params.len; i++) {
    const uint32_t pid = ast__ast__Ast__list(&((*a)), params)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), pid)->as_data.parameter.ty != ast__ast__NODE_NONE) {
      continue;
    }
    if (sn < 0) {
      if ((cwant != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, cwant)->kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
        (sn = typechecker__typechecker__TypeChecker__fn_sig(self, cwant, ((uint32_t *)(&sigp.t[0])), 8, ((uint32_t *)(&sigr))));
      } else {
        (sn = 0);
      }
    }
    if ((((int32_t)i) < sn) && (sigp.t[((size_t)i)] != ast__ast__TYPE_NONE)) {
      ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), pid, sigp.t[((size_t)i)]);
    } else {
      const lexer__token__Span psp = ast__ast__Ast__at_const(&((*a)), pid)->span;
      utils__errors__Errors__emit(&self->errors, psp.start, (psp.end - psp.start), ({ String__Global __sc222 = String__Global__new();
String__Global__push_str(&__sc222, (str){ .ptr = (const uint8_t*)"closure parameter needs a type annotation (no expected function type supplies one)", .len = sizeof("closure parameter needs a type annotation (no expected function type supplies one)") - 1 });
__sc222; }));
      utils__errors__Errors__note(&self->errors, ({ String__Global __sc223 = String__Global__new();
String__Global__push_str(&__sc223, (str){ .ptr = (const uint8_t*)"annotate it (`|x: i32| ..`) or bind the closure where a 'fn' type is expected", .len = sizeof("annotate it (`|x: i32| ..`) or bind the closure where a 'fn' type is expected") - 1 });
__sc223; }));
    }
  }
  for (uint32_t i = 0U; i < params.len; i++) {
    typechecker__typechecker__TypeChecker__decl_type(self, ast__ast__Ast__list(&((*a)), params)[((size_t)i)]);
  }
  if (self->nclos >= 8U) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc224 = String__Global__new();
String__Global__push_str(&__sc224, (str){ .ptr = (const uint8_t*)"closures nested too deeply (max 8)", .len = sizeof("closures nested too deeply (max 8)") - 1 });
__sc224; }));
    return ast__ast__TYPE_NONE;
  }
  const uint32_t cn = self->nclos;
  (self->clos_stack[((size_t)cn)] = id);
  (self->nclos = (cn + 1U));
  const uint32_t saved_lf = self->loop_floor;
  (self->loop_floor = self->nloops);
  if (ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.expr_body) {
    typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.body);
    typechecker__typechecker__TypeChecker__tc_capture_move_guard(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.body);
  } else {
    const ast__ast__NodeList saved = self->current_returns;
    (self->current_returns = ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.returns);
    typechecker__typechecker__TypeChecker__check_stmt(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.body);
    (self->current_returns = saved);
  }
  (self->loop_floor = saved_lf);
  (self->nclos = (self->nclos - 1U));
  const ast__ast__NodeList caps = ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.captures;
  const uint64_t mut_caps = ((uint64_t)ast__ast__Ast__at_const(&((*a)), id)->as_data.closure.mut_caps);
  for (uint32_t i = 0U; i < caps.len; i++) {
    const uint32_t cid = ast__ast__Ast__list(&((*a)), caps)[((size_t)i)];
    const uint32_t cty = typechecker__typechecker__TypeChecker__decl_type(self, cid);
    const bool is_mut = ((({ uint64_t __sc225 = mut_caps; int64_t __sc226 = (int64_t)(((uint64_t)i)); if ((uint64_t)__sc226 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc225 >> __sc226); }) & 1ULL) != 0ULL);
    if (((cty != ast__ast__TYPE_NONE) && (!is_mut)) && (typechecker__typechecker__TypeChecker__type_at(self, cty)->kind == ast__ast__TypeKind_TYPE_ARRAY)) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc227 = String__Global__new();
String__Global__push_str(&__sc227, (str){ .ptr = (const uint8_t*)"closure cannot capture a fixed-size array by copy; capture a slice instead", .len = sizeof("closure cannot capture a fixed-size array by copy; capture a slice instead") - 1 });
__sc227; }));
      continue;
    }
    if (((cty == ast__ast__TYPE_NONE) || is_mut) || (!typechecker__typechecker__TypeChecker__tc_type_is_free(self, cty))) {
      continue;
    }
    if (typechecker__typechecker__TypeChecker__is_moved(self, cid)) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc228 = String__Global__new();
String__Global__push_str(&__sc228, (str){ .ptr = (const uint8_t*)"closure captures a moved value (use of moved value)", .len = sizeof("closure captures a moved value (use of moved value)") - 1 });
__sc228; }));
    }
    for (uint32_t f = 0U; f < self->nclos; f++) {
      if (typechecker__typechecker__TypeChecker__tc_capture_index(self, self->clos_stack[((size_t)f)], cid) >= 0) {
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc229 = String__Global__new();
String__Global__push_str(&__sc229, (str){ .ptr = (const uint8_t*)"cannot take ownership of a value also captured by an enclosing closure", .len = sizeof("cannot take ownership of a value also captured by an enclosing closure") - 1 });
__sc229; }));
        break;
      }
    }
    for (uint32_t b = 0U; b < self->nborrows; b++) {
      if (self->borrows[((size_t)b)].root == cid) {
        if (typechecker__typechecker__TypeChecker__borrow_dead_after(self, self->borrows[((size_t)b)], id)) {
          typechecker__typechecker__TypeChecker__borrow_tombstone_at(self, b);
        } else {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc230 = String__Global__new();
String__Global__push_str(&__sc230, (str){ .ptr = (const uint8_t*)"cannot capture this value while it is borrowed", .len = sizeof("cannot capture this value while it is borrowed") - 1 });
__sc230; }));
          break;
        }
      }
    }
    if (self->nmoved < 1024U) {
      const uint32_t k = self->nmoved;
      (self->moved[((size_t)k)] = cid);
      (self->nmoved = (k + 1U));
    }
  }
  return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_FUNCTION, .module = self->ast.module, .as_data = (ast__ast__TyAs){ .decl = id } });
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_index(typechecker__typechecker__TypeChecker *const self, uint32_t const id, bool const addr_ctx, bool const place_use) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t obj_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.index.object;
  const uint32_t index_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.index.index;
  (self->addr_ctx = addr_ctx);
  (self->place_use = (!addr_ctx));
  uint32_t obj = typechecker__typechecker__TypeChecker__check_expr(self, obj_n);
  if (((!addr_ctx) && (!place_use)) && typechecker__typechecker__TypeChecker__borrow_conflicting_read(self, id)) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc231 = String__Global__new();
String__Global__push_str(&__sc231, (str){ .ptr = (const uint8_t*)"cannot use this value while it is mutably borrowed", .len = sizeof("cannot use this value while it is mutably borrowed") - 1 });
__sc231; }));
  }
  if (typechecker__typechecker__TypeChecker__type_at(self, obj)->kind == ast__ast__TypeKind_TYPE_REFERENCE) {
    uint32_t p = obj;
    ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, p));
    while (y.kind == ast__ast__TypeKind_TYPE_REFERENCE) {
      (p = y.as_data.elem);
      (y = (*typechecker__typechecker__TypeChecker__type_at(self, p)));
    }
    if (y.kind != ast__ast__TypeKind_TYPE_ARRAY) {
      (obj = p);
    }
  }
  const ast__ast__Ty ot = (*typechecker__typechecker__TypeChecker__type_at(self, obj));
  const ast__ast__NodeKind idxn_kind = ast__ast__Ast__at_const(&((*a)), index_n)->kind;
  if (idxn_kind == ast__ast__NodeKind_NODE_RANGE) {
    uint32_t elem = ast__ast__TYPE_NONE;
    uint32_t selem = ast__ast__TYPE_NONE;
    uint32_t user_result = ast__ast__TYPE_NONE;
    if ((ot.kind == ast__ast__TypeKind_TYPE_ARRAY) || (ot.kind == ast__ast__TypeKind_TYPE_POINTER)) {
      if ((ot.kind == ast__ast__TypeKind_TYPE_POINTER) && (self->unsafe_depth == 0U)) {
        typechecker__typechecker__TypeChecker__err_unsafe(self, ast__ast__Ast__at_const(&((*a)), obj_n)->span, (str){ (const uint8_t *)"slicing a raw pointer", sizeof("slicing a raw pointer") - 1 });
      }
      (elem = ot.as_data.elem);
    } else if (typechecker__typechecker__TypeChecker__slice_kind(self, obj, ((uint32_t *)(&selem))) != 0) {
      (elem = selem);
    } else if ((ot.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ot.kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
      uint16_t om = 0U;
      uint32_t od = ast__ast__NODE_NONE;
      typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
      int32_t gn = 0;
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), obj_n)->span;
      if (typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, obj), ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
        const ast__ast__DefId md = typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"index_range", sizeof("index_range") - 1 });
        if (md.node == ast__ast__NODE_NONE) {
          typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, typechecker__typechecker__TypeChecker__strip(self, obj), ((char *)(&ty.b[0])), 96ULL);
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc232 = String__Global__new();
String__Global__push_str(&__sc232, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc232, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc232, (str){ .ptr = (const uint8_t*)"' has no 'index_range' method for '[..]'", .len = sizeof("' has no 'index_range' method for '[..]'") - 1 });
__sc232; }));
        } else if (!typechecker__typechecker__TypeChecker__method_extend_bounds_hold(self, typechecker__typechecker__TypeChecker__strip(self, obj), md)) {
          typechecker__typechecker__TypeChecker__err_method_extend_bounds(self, sp, typechecker__typechecker__TypeChecker__strip(self, obj), md);
        } else {
          if ((ast__ast__Ast__at_const(&((*a)), index_n)->as_data.pattern_range.end == ast__ast__NODE_NONE) && (typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"len", sizeof("len") - 1 }).node == ast__ast__NODE_NONE)) {
            typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
            typechecker__typechecker__TypeChecker__render_type(self, typechecker__typechecker__TypeChecker__strip(self, obj), ((char *)(&ty.b[0])), 96ULL);
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc233 = String__Global__new();
String__Global__push_str(&__sc233, (str){ .ptr = (const uint8_t*)"an open-ended range index needs a 'len' method on '", .len = sizeof("an open-ended range index needs a 'len' method on '") - 1 });
String__Global__push_str(&__sc233, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc233, (str){ .ptr = (const uint8_t*)"' to supply the end", .len = sizeof("' to supply the end") - 1 });
__sc233; }));
          }
          typechecker__typechecker__TypeChecker__prelude_range_type(self, 12U);
          (user_result = typechecker__typechecker__TypeChecker__tc_method_ret(self, typechecker__typechecker__TypeChecker__strip(self, obj), md));
        }
      }
    } else if (obj != ast__ast__TYPE_NONE) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), obj_n)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc234 = String__Global__new();
String__Global__push_str(&__sc234, (str){ .ptr = (const uint8_t*)"cannot slice this expression", .len = sizeof("cannot slice this expression") - 1 });
__sc234; }));
    }
    const uint32_t bstart = ast__ast__Ast__at_const(&((*a)), index_n)->as_data.pattern_range.start;
    const uint32_t bend = ast__ast__Ast__at_const(&((*a)), index_n)->as_data.pattern_range.end;
    if (bstart != ast__ast__NODE_NONE) {
      const uint32_t bt = typechecker__typechecker__TypeChecker__check_expr(self, bstart);
      if (((bt != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_int(self, bt))) && (ast__ast__Ast__at_const(&((*a)), bstart)->kind != ast__ast__NodeKind_NODE_LITERAL)) {
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), bstart)->span;
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc235 = String__Global__new();
String__Global__push_str(&__sc235, (str){ .ptr = (const uint8_t*)"range bound must be an integer", .len = sizeof("range bound must be an integer") - 1 });
__sc235; }));
      }
    }
    if (bend != ast__ast__NODE_NONE) {
      const uint32_t bt = typechecker__typechecker__TypeChecker__check_expr(self, bend);
      if (((bt != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_int(self, bt))) && (ast__ast__Ast__at_const(&((*a)), bend)->kind != ast__ast__NodeKind_NODE_LITERAL)) {
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), bend)->span;
        utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc236 = String__Global__new();
String__Global__push_str(&__sc236, (str){ .ptr = (const uint8_t*)"range bound must be an integer", .len = sizeof("range bound must be an integer") - 1 });
__sc236; }));
      }
    }
    if (user_result != ast__ast__TYPE_NONE) {
      return user_result;
    }
    if (elem != ast__ast__TYPE_NONE) {
      return typechecker__typechecker__TypeChecker__prelude_slice_type(self, elem, false);
    }
    return ast__ast__TYPE_NONE;
  }
  const uint32_t idx = typechecker__typechecker__TypeChecker__check_expr(self, index_n);
  bool overloaded = false;
  uint32_t result = ast__ast__TYPE_NONE;
  if (obj != ast__ast__TYPE_NONE) {
    uint32_t selem = ast__ast__TYPE_NONE;
    if ((ot.kind == ast__ast__TypeKind_TYPE_ARRAY) || (ot.kind == ast__ast__TypeKind_TYPE_POINTER)) {
      if ((ot.kind == ast__ast__TypeKind_TYPE_POINTER) && (self->unsafe_depth == 0U)) {
        typechecker__typechecker__TypeChecker__err_unsafe(self, ast__ast__Ast__at_const(&((*a)), obj_n)->span, (str){ (const uint8_t *)"indexing a raw pointer", sizeof("indexing a raw pointer") - 1 });
      }
      (result = ot.as_data.elem);
    } else if (typechecker__typechecker__TypeChecker__slice_kind(self, obj, ((uint32_t *)(&selem))) != 0) {
      (result = selem);
    } else if ((ot.kind == ast__ast__TypeKind_TYPE_STRUCT) || (ot.kind == ast__ast__TypeKind_TYPE_INSTANCE)) {
      (overloaded = true);
      uint16_t om = 0U;
      uint32_t od = ast__ast__NODE_NONE;
      typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
      typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
      int32_t gn = 0;
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), obj_n)->span;
      if (typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, obj), ((uint16_t *)(&om)), ((uint32_t *)(&od)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)))) {
        const ast__ast__DefId md = typechecker__typechecker__TypeChecker__find_method_cstr(self, om, od, (str){ (const uint8_t *)"index", sizeof("index") - 1 });
        if (md.node == ast__ast__NODE_NONE) {
          typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, typechecker__typechecker__TypeChecker__strip(self, obj), ((char *)(&ty.b[0])), 96ULL);
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc237 = String__Global__new();
String__Global__push_str(&__sc237, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc237, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc237, (str){ .ptr = (const uint8_t*)"' has no 'index' method for '[]'", .len = sizeof("' has no 'index' method for '[]'") - 1 });
__sc237; }));
        } else if (!typechecker__typechecker__TypeChecker__method_extend_bounds_hold(self, typechecker__typechecker__TypeChecker__strip(self, obj), md)) {
          typechecker__typechecker__TypeChecker__err_method_extend_bounds(self, sp, typechecker__typechecker__TypeChecker__strip(self, obj), md);
          (result = ast__ast__TYPE_NONE);
        } else {
          const uint32_t p1 = typechecker__typechecker__TypeChecker__tc_method_param(self, typechecker__typechecker__TypeChecker__strip(self, obj), md, 1);
          if (!typechecker__typechecker__TypeChecker__operand_fits_param(self, p1, index_n)) {
            typechecker__typechecker__TypeChecker__err_mismatch(self, index_n, p1);
          }
          (result = typechecker__typechecker__TypeChecker__tc_method_ret(self, typechecker__typechecker__TypeChecker__strip(self, obj), md));
          if ((result != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, result)->kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
            (result = typechecker__typechecker__TypeChecker__type_at(self, result)->as_data.elem);
          }
        }
      }
    } else {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), obj_n)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc238 = String__Global__new();
String__Global__push_str(&__sc238, (str){ .ptr = (const uint8_t*)"cannot index this expression", .len = sizeof("cannot index this expression") - 1 });
__sc238; }));
    }
  }
  if ((((!overloaded) && (idx != ast__ast__TYPE_NONE)) && (!typechecker__typechecker__TypeChecker__is_int(self, idx))) && (ast__ast__Ast__at_const(&((*a)), index_n)->kind != ast__ast__NodeKind_NODE_LITERAL)) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), index_n)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc239 = String__Global__new();
String__Global__push_str(&__sc239, (str){ .ptr = (const uint8_t*)"index must be an integer", .len = sizeof("index must be an integer") - 1 });
__sc239; }));
  }
  return result;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_match_expr(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
  const uint32_t scrut = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.value);
  const ast__ast__Ty sy = (*typechecker__typechecker__TypeChecker__type_at(self, scrut));
  int32_t bind_ref = 0;
  if ((sy.kind == ast__ast__TypeKind_TYPE_REFERENCE) || (sy.kind == ast__ast__TypeKind_TYPE_POINTER)) {
    if (sy.qualifier == 2U) {
      (bind_ref = 2);
    } else {
      (bind_ref = 1);
    }
  }
  if (bind_ref == 0) {
    typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
    typechecker__typechecker__TypeChecker__tc_mark_move(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.value);
  }
  const ast__ast__NodeList arms = ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.arms;
  bool first = true;
  bool ovf = false;
  const typechecker__typechecker__FlowState mpre = typechecker__typechecker__TypeChecker__tc_flow_save(self);
  typechecker__typechecker__FlowState acc = (typechecker__typechecker__FlowState){0};
  uint32_t result = ast__ast__TYPE_NONE;
  for (uint32_t i = 0U; i < arms.len; i++) {
    const uint32_t aid = ast__ast__Ast__list(&((*a)), arms)[((size_t)i)];
    const ast__ast__MatchArmData arm = ast__ast__Ast__at_const(&((*a)), aid)->as_data.match_arm;
    typechecker__typechecker__TypeChecker__tc_flow_set(self, (&mpre));
    typechecker__typechecker__TypeChecker__check_pattern(self, arm.pattern, scrut, bind_ref);
    const uint32_t g = typechecker__typechecker__TypeChecker__check_expr(self, arm.guard);
    if (((arm.guard != ast__ast__NODE_NONE) && (g != ast__ast__TYPE_NONE)) && (!typechecker__typechecker__TypeChecker__is_bool(self, g))) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), arm.guard)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc240 = String__Global__new();
String__Global__push_str(&__sc240, (str){ .ptr = (const uint8_t*)"match guard must be 'bool'", .len = sizeof("match guard must be 'bool'") - 1 });
__sc240; }));
    }
    const uint32_t body = typechecker__typechecker__TypeChecker__check_expr(self, arm.body);
    if (typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)))) {
      (ovf = true);
    }
    const bool body_never = ((body != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, body)->kind == ast__ast__TypeKind_TYPE_NEVER));
    if (first) {
      (result = body);
      (first = false);
    } else if ((result != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, result)->kind == ast__ast__TypeKind_TYPE_NEVER)) {
      (result = body);
    } else if ((((!body_never) && (result != body)) && (body != ast__ast__TYPE_NONE)) && (result != ast__ast__TYPE_NONE)) {
      typechecker__typechecker__TypeChecker__err_mismatch(self, arm.body, result);
      (result = ast__ast__TYPE_NONE);
    }
  }
  if (arms.len != 0U) {
    typechecker__typechecker__TypeChecker__tc_flow_set(self, (&acc));
  }
  if (ovf) {
    typechecker__typechecker__TypeChecker__tc_flow_overflow(self, id);
  }
  typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
  typechecker__typechecker__TypeChecker__check_match_exhaustive(self, id, scrut);
  return result;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_expr(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return ast__ast__TYPE_NONE;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), id)->kind;
  const uint32_t expected = self->expected;
  (self->expected = ast__ast__TYPE_NONE);
  const bool addr_ctx = self->addr_ctx;
  (self->addr_ctx = false);
  const bool place_use = self->place_use;
  (self->place_use = false);
  uint32_t result = ast__ast__TYPE_NONE;
  {
    const ast__ast__NodeKind __sc241 = nk;
    if (__sc241 == ast__ast__NodeKind_NODE_LITERAL) {
      {
        (result = typechecker__typechecker__TypeChecker__check_literal(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_IDENTIFIER) {
      {
        const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
        (result = typechecker__typechecker__TypeChecker__decl_type_in(self, d.module, d.node));
        if ((d.node != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
          typechecker__typechecker__TypeChecker__tc_check_test_ref(self, d, ast__ast__Ast__at_const(&((*a)), id)->span);
        }
        if ((d.module == self->ast.module) && (d.node != ast__ast__NODE_NONE)) {
          if (typechecker__typechecker__TypeChecker__is_moved(self, d.node)) {
            bool freed = false;
            for (uint32_t k = 0U; k < self->nfreed; k++) {
              if (self->freed[((size_t)k)] == d.node) {
                (freed = true);
              }
            }
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
            const char *msg = ((const char *)({ __auto_type __sc242 = (str){ (const uint8_t *)"use of moved value", sizeof("use of moved value") - 1 }; str__ptr(&__sc242); }));
            if (freed) {
              (msg = ((const char *)({ __auto_type __sc243 = (str){ (const uint8_t *)"use after free", sizeof("use after free") - 1 }; str__ptr(&__sc243); })));
            }
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc244 = String__Global__new();
String__Global__push_str(&__sc244, utils__errors__cstr(msg));
__sc244; }));
          }
          if ((!addr_ctx) && typechecker__typechecker__TypeChecker__tc_is_uninit(self, d.node)) {
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc245 = String__Global__new();
String__Global__push_str(&__sc245, (str){ .ptr = (const uint8_t*)"use of possibly uninitialized value", .len = sizeof("use of possibly uninitialized value") - 1 });
__sc245; }));
          }
          if (((!addr_ctx) && (!place_use)) && typechecker__typechecker__TypeChecker__borrow_conflicting_read(self, id)) {
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc246 = String__Global__new();
String__Global__push_str(&__sc246, (str){ .ptr = (const uint8_t*)"cannot use this value while it is mutably borrowed", .len = sizeof("cannot use this value while it is mutably borrowed") - 1 });
__sc246; }));
          }
        }
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_UNARY) {
      {
        (result = typechecker__typechecker__TypeChecker__check_unary(self, id));
        if ((((ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.op == lexer__token_type__TokenType_Star) && (!addr_ctx)) && (!place_use)) && typechecker__typechecker__TypeChecker__borrow_conflicting_read(self, id)) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc247 = String__Global__new();
String__Global__push_str(&__sc247, (str){ .ptr = (const uint8_t*)"cannot use this value while it is mutably borrowed", .len = sizeof("cannot use this value while it is mutably borrowed") - 1 });
__sc247; }));
        }
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_BINARY) {
      {
        (result = typechecker__typechecker__TypeChecker__check_binary(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_ASSIGNMENT) {
      {
        (result = typechecker__typechecker__TypeChecker__check_assignment(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_CALL) {
      {
        (result = typechecker__typechecker__TypeChecker__check_call(self, id, expected));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_CLOSURE) {
      {
        (result = typechecker__typechecker__TypeChecker__check_closure(self, id, expected));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_INDEX) {
      {
        (result = typechecker__typechecker__TypeChecker__check_index(self, id, addr_ctx, place_use));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_MEMBER) {
      {
        const bool value_read = ((!ast__ast__Ast__at_const(&((*a)), id)->as_data.member.path) && (!addr_ctx));
        (self->addr_ctx = addr_ctx);
        (self->place_use = value_read);
        if (ast__ast__Ast__at_const(&((*a)), id)->as_data.member.path) {
          (result = typechecker__typechecker__TypeChecker__check_path_member(self, id, expected));
        } else {
          (self->expected = expected);
          (result = typechecker__typechecker__TypeChecker__check_member(self, id, false));
        }
        if ((value_read && (!place_use)) && typechecker__typechecker__TypeChecker__borrow_conflicting_read(self, id)) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc248 = String__Global__new();
String__Global__push_str(&__sc248, (str){ .ptr = (const uint8_t*)"cannot use this value while it is mutably borrowed", .len = sizeof("cannot use this value while it is mutably borrowed") - 1 });
__sc248; }));
        }
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_CAST) {
      {
        const uint32_t src = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.cast.expression);
        const uint32_t dst = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.cast.ty);
        if (((src != ast__ast__TYPE_NONE) && (dst != ast__ast__TYPE_NONE)) && (src != dst)) {
          const ast__ast__TypeKind sk = typechecker__typechecker__TypeChecker__type_at(self, src)->kind;
          const ast__ast__TypeKind dk = typechecker__typechecker__TypeChecker__type_at(self, dst)->kind;
          const bool aggregate = ((((((sk == ast__ast__TypeKind_TYPE_STRUCT) || (sk == ast__ast__TypeKind_TYPE_ENUM)) || (sk == ast__ast__TypeKind_TYPE_FUNCTION)) || (dk == ast__ast__TypeKind_TYPE_STRUCT)) || (dk == ast__ast__TypeKind_TYPE_ENUM)) || (dk == ast__ast__TypeKind_TYPE_FUNCTION));
          const bool enum_int = ((typechecker__typechecker__TypeChecker__is_plain_enum(self, src) && typechecker__typechecker__TypeChecker__is_int(self, dst)) || (typechecker__typechecker__TypeChecker__is_plain_enum(self, dst) && typechecker__typechecker__TypeChecker__is_int(self, src)));
          const bool complex_lossy = ((((sk == ast__ast__TypeKind_TYPE_BUILTIN) && typechecker__typechecker__bt_is_complex(typechecker__typechecker__TypeChecker__type_at(self, src)->as_data.builtin)) && (dk == ast__ast__TypeKind_TYPE_BUILTIN)) && (!typechecker__typechecker__bt_is_complex(typechecker__typechecker__TypeChecker__type_at(self, dst)->as_data.builtin)));
          if ((aggregate && (!enum_int)) || complex_lossy) {
            typechecker__typechecker__Buf96 s = (typechecker__typechecker__Buf96){0};
            typechecker__typechecker__Buf96 d = (typechecker__typechecker__Buf96){0};
            typechecker__typechecker__TypeChecker__render_type(self, src, ((char *)(&s.b[0])), 96ULL);
            typechecker__typechecker__TypeChecker__render_type(self, dst, ((char *)(&d.b[0])), 96ULL);
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc249 = String__Global__new();
String__Global__push_str(&__sc249, (str){ .ptr = (const uint8_t*)"invalid cast from '", .len = sizeof("invalid cast from '") - 1 });
String__Global__push_str(&__sc249, utils__errors__cstr(((const char *)(&s.b[0]))));
String__Global__push_str(&__sc249, (str){ .ptr = (const uint8_t*)"' to '", .len = sizeof("' to '") - 1 });
String__Global__push_str(&__sc249, utils__errors__cstr(((const char *)(&d.b[0]))));
String__Global__push_str(&__sc249, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc249; }));
          }
        }
        (result = dst);
      }
    }
    else if ((__sc241 == ast__ast__NodeKind_NODE_SIZEOF) || (__sc241 == ast__ast__NodeKind_NODE_ALIGNOF)) {
      {
        const uint32_t v = ast__ast__Ast__at_const(&((*a)), id)->as_data.single.value;
        const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), v);
        ast__ast__NodeKind dk = ast__ast__NodeKind_NODE_NONE_KIND;
        if ((d.node != ast__ast__NODE_NONE) && (d.module == self->ast.module)) {
          (dk = ast__ast__Ast__at_const(&((*a)), d.node)->kind);
        }
        if ((((((dk == ast__ast__NodeKind_NODE_LET) || (dk == ast__ast__NodeKind_NODE_PARAMETER)) || (dk == ast__ast__NodeKind_NODE_FOR)) || (dk == ast__ast__NodeKind_NODE_IDENTIFIER)) || (dk == ast__ast__NodeKind_NODE_PATTERN_NAME)) || (dk == ast__ast__NodeKind_NODE_CONST)) {
          const uint32_t vt = ast__ast__Ast__type_of(&((*a)), d.node);
          if (vt == ast__ast__TYPE_NONE) {
            const lexer__token__Span vsp = ast__ast__Ast__at_const(&((*a)), v)->span;
            utils__errors__Errors__emit(&self->errors, vsp.start, (vsp.end - vsp.start), ({ String__Global __sc250 = String__Global__new();
String__Global__push_str(&__sc250, (str){ .ptr = (const uint8_t*)"cannot take the size of this value here", .len = sizeof("cannot take the size of this value here") - 1 });
__sc250; }));
          }
          ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), v, vt);
        } else {
          typechecker__typechecker__TypeChecker__resolve_type(self, v);
        }
        (result = 12U);
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_VA_EXPR) {
      {
        const ast__ast__VaOpData vo = ast__ast__Ast__at_const(&((*a)), id)->as_data.va_op;
        if ((vo.op == ast__ast__VA_START) && (ast__ast__Ast__at_const(&((*a)), vo.ap)->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
          const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), vo.ap);
          if ((d.module == self->ast.module) && (d.node != ast__ast__NODE_NONE)) {
            typechecker__typechecker__TypeChecker__tc_init(self, d.node);
          }
        }
        const uint32_t apt = typechecker__typechecker__TypeChecker__check_expr(self, vo.ap);
        if (apt != ast__ast__TYPE_NONE) {
          const ast__ast__Ty ay = (*typechecker__typechecker__TypeChecker__type_at(self, apt));
          if (!((ay.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (ay.as_data.builtin == ast__ast__BuiltinType_BT_VALIST))) {
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), vo.ap)->span;
            typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
            typechecker__typechecker__TypeChecker__render_type(self, apt, ((char *)(&ty.b[0])), 96ULL);
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc251 = String__Global__new();
String__Global__push_str(&__sc251, (str){ .ptr = (const uint8_t*)"expected a 'va_list', found '", .len = sizeof("expected a 'va_list', found '") - 1 });
String__Global__push_str(&__sc251, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc251, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc251; }));
          }
        }
        if (vo.op == ast__ast__VA_ARG) {
          (result = typechecker__typechecker__TypeChecker__resolve_type(self, vo.extra));
        } else {
          if (vo.op == ast__ast__VA_START) {
            typechecker__typechecker__TypeChecker__check_expr(self, vo.extra);
          }
          (result = 18U);
        }
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
      {
        const uint32_t inner = ast__ast__Ast__at_const(&((*a)), id)->as_data.specialization.expression;
        const ast__ast__NodeList types = ast__ast__Ast__at_const(&((*a)), id)->as_data.specialization.types;
        for (uint32_t i = 0U; i < types.len; i++) {
          typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*a)), types)[((size_t)i)]);
        }
        const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), inner);
        bool is_agg = false;
        if (d.node != ast__ast__NODE_NONE) {
          const ast__ast__Node *const dn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, d.module))), d.node);
          (is_agg = ((((dn->kind == ast__ast__NodeKind_NODE_ENUM) || (dn->kind == ast__ast__NodeKind_NODE_STRUCT)) && (dn->as_data.aggregate.generics.len > 0U)) && (types.len > 0U)));
        }
        if (is_agg) {
          typechecker__typechecker__Tys4 ta = (typechecker__typechecker__Tys4){0};
          uint8_t tn = 0U;
          uint32_t j = 0U;
          while ((j < types.len) && (tn < 4U)) {
            (ta.t[((size_t)tn)] = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*a)), types)[((size_t)j)]));
            (tn = ((uint8_t)((uint32_t)tn + (uint32_t)1U)));
            (j = (j + 1U));
          }
          typechecker__typechecker__TypeChecker__apply_default_args(self, d.module, d.node, ((uint32_t *)(&ta.t[0])), ((uint8_t *)(&tn)));
          (result = ast__ast__Ast__intern_instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), d.module, d.node, ((const uint32_t *)(&ta.t[0])), tn));
        } else {
          (result = typechecker__typechecker__TypeChecker__check_expr(self, inner));
        }
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_MATCH) {
      {
        (result = typechecker__typechecker__TypeChecker__check_match_expr(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_NEW) {
      {
        const uint32_t declared = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.new_expr.ty);
        uint32_t inner = declared;
        const uint32_t init = ast__ast__Ast__at_const(&((*a)), id)->as_data.new_expr.initializer;
        if (init != ast__ast__NODE_NONE) {
          const uint32_t it = typechecker__typechecker__TypeChecker__check_expr(self, init);
          if (ast__ast__Ast__at_const(&((*a)), init)->kind == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
            (inner = it);
          } else if (!typechecker__typechecker__TypeChecker__compatible(self, declared, init)) {
            typechecker__typechecker__TypeChecker__err_mismatch(self, init, declared);
          }
        }
        (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_POINTER, .qualifier = 2U, .as_data = (ast__ast__TyAs){ .elem = inner } }));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
      {
        (result = typechecker__typechecker__TypeChecker__check_array_literal(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
      {
        (result = typechecker__typechecker__TypeChecker__check_struct_init(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        (result = typechecker__typechecker__TypeChecker__check_block_value(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_WHILE) {
      {
        (self->loop_depth = (self->loop_depth + 1U));
        const int32_t le = typechecker__typechecker__TypeChecker__tc_loop_push(self, (lexer__token__Span){ .start = 0U, .end = 0U }, id, true);
        typechecker__typechecker__TypeChecker__check_loop_body(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.body);
        if (le >= 0) {
          (result = self->loop_stack[((size_t)le)].break_ty);
          typechecker__typechecker__TypeChecker__tc_loop_pop(self, le, ast__ast__Ast__at_const(&((*a)), id)->span);
        }
        if (result == ast__ast__TYPE_NONE) {
          (result = ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_NEVER }));
        }
        (self->loop_depth = (self->loop_depth - 1U));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_IF) {
      {
        (result = typechecker__typechecker__TypeChecker__check_if_value(self, id));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_TUPLE) {
      {
        (result = typechecker__typechecker__TypeChecker__check_tuple_value(self, id, expected));
      }
    }
    else if (__sc241 == ast__ast__NodeKind_NODE_RANGE) {
      {
        const uint32_t s = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.start);
        const uint32_t e = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.end);
        const uint32_t elem = typechecker__typechecker__TypeChecker__range_type(self, id, s, e);
        if ((ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.start == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.end == ast__ast__NODE_NONE)) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc252 = String__Global__new();
String__Global__push_str(&__sc252, (str){ .ptr = (const uint8_t*)"a range value needs both a start and an end", .len = sizeof("a range value needs both a start and an end") - 1 });
__sc252; }));
        } else {
          (result = typechecker__typechecker__if_ty((elem != ast__ast__TYPE_NONE), typechecker__typechecker__TypeChecker__prelude_range_type(self, elem), ast__ast__TYPE_NONE));
        }
      }
    }
    else if (1) {
      {
      }
    }
  }
  ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, result);
  return result;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_literal(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const lexer__token_type__TokenType tt = ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.token_type;
  const lexer__token__Span lr = ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.raw;
  if (tt == lexer__token_type__TokenType_IntegerLiteral) {
    uint32_t sfx = lr.end;
    const ast__ast__BuiltinType sb = ast__ast__ast_numeric_suffix(self->source, lr.start, lr.end, ((uint32_t *)(&sfx)));
    uint32_t result = 5U;
    if (sb != ast__ast__BuiltinType_BT_COUNT) {
      (result = ast__ast__Ast__builtin(sb));
    }
    const uint8_t *p = (self->source + ((size_t)lr.start));
    size_t len = ((size_t)(sfx - lr.start));
    uint64_t base = 10ULL;
    if ((len >= 2ULL) && (p[0] == 48U)) {
      const uint8_t c1 = (p[1] | 0x20U);
      if (c1 == 120U) {
        (base = 16ULL);
        (p = (p + 2));
        (len = (len - 2ULL));
      } else if (c1 == 98U) {
        (base = 2ULL);
        (p = (p + 2));
        (len = (len - 2ULL));
      } else if (c1 == 111U) {
        (base = 8ULL);
        (p = (p + 2));
        (len = (len - 2ULL));
      }
    }
    uint64_t acc = 0ULL;
    bool overflow = false;
    size_t i = 0ULL;
    while ((i < len) && (!overflow)) {
      const uint8_t ch = p[i];
      if (ch == 95U) {
        (i = (i + 1ULL));
        continue;
      }
      uint64_t d = 0ULL;
      if (ch <= 57U) {
        (d = ((uint64_t)((uint8_t)((uint32_t)ch - (uint32_t)48U))));
      } else {
        (d = ((uint64_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)(ch | 0x20U) - (uint32_t)97U)) + (uint32_t)10U))));
      }
      if (acc > ({ uint64_t __sc253 = (0xFFFFFFFFFFFFFFFFULL - d); uint64_t __sc254 = base; if (__sc254 == 0) { __sc_panic("divide by zero"); } (__sc253 / __sc254); })) {
        (overflow = true);
      } else {
        (acc = ((acc * base) + d));
      }
      (i = (i + 1ULL));
    }
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    if (overflow) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc255 = String__Global__new();
String__Global__push_str(&__sc255, (str){ .ptr = (const uint8_t*)"integer literal is too large to fit in a 64-bit integer", .len = sizeof("integer literal is too large to fit in a 64-bit integer") - 1 });
__sc255; }));
    } else if (((sb != ast__ast__BuiltinType_BT_COUNT) && (typechecker__typechecker__bt_int_max(sb) != 0ULL)) && (acc > typechecker__typechecker__bt_int_max(sb))) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc256 = String__Global__new();
String__Global__push_str(&__sc256, (str){ .ptr = (const uint8_t*)"integer literal does not fit in its suffixed type", .len = sizeof("integer literal does not fit in its suffixed type") - 1 });
__sc256; }));
    }
    return result;
  }
  if (tt == lexer__token_type__TokenType_FloatLiteral) {
    const ast__ast__BuiltinType sb = ast__ast__ast_numeric_suffix(self->source, lr.start, lr.end, NULL);
    if (sb == ast__ast__BuiltinType_BT_F64) {
      return 14U;
    }
    return 13U;
  }
  if (tt == lexer__token_type__TokenType_CharacterLiteral) {
    if (typechecker__typechecker__TypeChecker__char_literal_cp(self, lr) > 0xFFU) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc257 = String__Global__new();
String__Global__push_str(&__sc257, (str){ .ptr = (const uint8_t*)"character literal does not fit in 'char' (one byte); use a string or an integer", .len = sizeof("character literal does not fit in 'char' (one byte); use a string or an integer") - 1 });
__sc257; }));
    }
    return 2U;
  }
  if (tt == lexer__token_type__TokenType_ByteCharacterLiteral) {
    return 8U;
  }
  if ((tt == lexer__token_type__TokenType_True) || (tt == lexer__token_type__TokenType_False)) {
    return 1U;
  }
  if ((tt == lexer__token_type__TokenType_StringLiteral) || (tt == lexer__token_type__TokenType_RawStringLiteral)) {
    return typechecker__typechecker__TypeChecker__prelude_str_type(self);
  }
  if (tt == lexer__token_type__TokenType_ByteStringLiteral) {
    return typechecker__typechecker__TypeChecker__prelude_slice_type(self, 8U, false);
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_array_literal(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList elements = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_literal.elements;
  if (elements.len == 0U) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc258 = String__Global__new();
String__Global__push_str(&__sc258, (str){ .ptr = (const uint8_t*)"cannot infer the element type of an empty array literal", .len = sizeof("cannot infer the element type of an empty array literal") - 1 });
__sc258; }));
    return ast__ast__TYPE_NONE;
  }
  uint32_t elem = ast__ast__TYPE_NONE;
  for (uint32_t i = 0U; i < elements.len; i++) {
    const uint32_t eid = ast__ast__Ast__list(&((*a)), elements)[((size_t)i)];
    const ast__ast__Node *const el = ast__ast__Ast__at_const(&((*a)), eid);
    uint32_t et = ast__ast__TYPE_NONE;
    if (el->kind == ast__ast__NodeKind_NODE_FIELD_INITIALIZER) {
      const uint32_t it = typechecker__typechecker__TypeChecker__check_expr(self, el->as_data.field_initializer.name);
      if (it != ast__ast__TYPE_NONE) {
        const ast__ast__Ty iy = (*typechecker__typechecker__TypeChecker__type_at(self, it));
        if (!((iy.kind == ast__ast__TypeKind_TYPE_BUILTIN) && (typechecker__typechecker__bt_is_int(iy.as_data.builtin) || (iy.as_data.builtin == ast__ast__BuiltinType_BT_CHAR)))) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), el->as_data.field_initializer.name)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc259 = String__Global__new();
String__Global__push_str(&__sc259, (str){ .ptr = (const uint8_t*)"array designator index must be an integer", .len = sizeof("array designator index must be an integer") - 1 });
__sc259; }));
        } else {
          consteval__consteval__ConstEval *const ceptr = typechecker__typechecker__TypeChecker__ceval(self);
          if ((ceptr != NULL) && (consteval__consteval__ConstEval__eval(&((*ceptr)), self->ast.module, el->as_data.field_initializer.name).kind == consteval__consteval__CONST_NONE)) {
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), el->as_data.field_initializer.name)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc260 = String__Global__new();
String__Global__push_str(&__sc260, (str){ .ptr = (const uint8_t*)"array designator index must be a constant expression", .len = sizeof("array designator index must be a constant expression") - 1 });
__sc260; }));
          }
        }
      }
      (et = typechecker__typechecker__TypeChecker__check_expr(self, el->as_data.field_initializer.value));
    } else {
      (et = typechecker__typechecker__TypeChecker__check_expr(self, eid));
    }
    if (i == 0U) {
      (elem = et);
    } else if (((et != elem) && (et != ast__ast__TYPE_NONE)) && (elem != ast__ast__TYPE_NONE)) {
      const ast__ast__TypeKind e0 = typechecker__typechecker__TypeChecker__type_at(self, elem)->kind;
      const ast__ast__TypeKind ei = typechecker__typechecker__TypeChecker__type_at(self, et)->kind;
      if (!(((e0 == ast__ast__TypeKind_TYPE_FUNCTION) && (ei == ast__ast__TypeKind_TYPE_FUNCTION)) && typechecker__typechecker__TypeChecker__fn_compatible(self, elem, et))) {
        typechecker__typechecker__TypeChecker__err_mismatch(self, eid, elem);
        (elem = ast__ast__TYPE_NONE);
      }
    }
  }
  if (elem != ast__ast__TYPE_NONE) {
    return ast__ast__Ast__intern_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (ast__ast__Ty){ .kind = ast__ast__TypeKind_TYPE_ARRAY, .as_data = (ast__ast__TyAs){ .arr = (ast__ast__TyArr){ .elem = elem, .len = 0U } } });
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_block_value(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList stmts = ast__ast__Ast__at_const(&((*a)), id)->as_data.block.statements;
  typechecker__typechecker__TypeChecker__tc_scope_enter(self);
  for (uint32_t i = 0U; i < stmts.len; i++) {
    const uint32_t sid = ast__ast__Ast__list(&((*a)), stmts)[((size_t)i)];
    typechecker__typechecker__TypeChecker__check_stmt(self, sid);
    typechecker__typechecker__TypeChecker__borrow_nll_drop(self, id, ast__ast__Ast__list(&((*a)), stmts), i);
  }
  while ((self->ndefers != 0U) && (self->defer_depth[((size_t)(self->ndefers - 1U))] == self->scope_depth)) {
    (self->ndefers = (self->ndefers - 1U));
    const uint32_t dv = self->defer_stack[((size_t)self->ndefers)];
    const uint32_t dbm = typechecker__typechecker__TypeChecker__borrow_mark(self);
    typechecker__typechecker__TypeChecker__check_expr(self, dv);
    typechecker__typechecker__TypeChecker__borrow_release_to(self, dbm);
  }
  typechecker__typechecker__TypeChecker__tc_scope_exit(self);
  if (stmts.len > 0U) {
    const uint32_t lastid = ast__ast__Ast__list(&((*a)), stmts)[((size_t)(stmts.len - 1U))];
    const ast__ast__Node *const last = ast__ast__Ast__at_const(&((*a)), lastid);
    const uint32_t lv = typechecker__typechecker__if_node((last->kind == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT), last->as_data.single.value, ast__ast__NODE_NONE);
    if ((lv != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*a)), lv)->kind != ast__ast__NodeKind_NODE_ASSIGNMENT)) {
      return ast__ast__Ast__type_of(&((*a)), lv);
    }
    return 18U;
  }
  return 18U;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_if_value(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__IfData ifd = ast__ast__Ast__at_const(&((*a)), id)->as_data.if_stmt;
  const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
  const uint32_t c = typechecker__typechecker__TypeChecker__check_expr(self, ifd.condition);
  if ((c != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, c))) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), ifd.condition)->span;
    typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, c, ((char *)(&ty.b[0])), 96ULL);
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc261 = String__Global__new();
String__Global__push_str(&__sc261, (str){ .ptr = (const uint8_t*)"if condition must be 'bool', found '", .len = sizeof("if condition must be 'bool', found '") - 1 });
String__Global__push_str(&__sc261, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc261, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc261; }));
  }
  typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
  const typechecker__typechecker__FlowState ifpre = typechecker__typechecker__TypeChecker__tc_flow_save(self);
  const uint32_t then_ty = typechecker__typechecker__TypeChecker__check_expr(self, ifd.then_branch);
  if (ifd.else_branch == ast__ast__NODE_NONE) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc262 = String__Global__new();
String__Global__push_str(&__sc262, (str){ .ptr = (const uint8_t*)"an 'if' used as a value must have an 'else' branch", .len = sizeof("an 'if' used as a value must have an 'else' branch") - 1 });
__sc262; }));
    return ast__ast__TYPE_NONE;
  }
  typechecker__typechecker__FlowState acc = (typechecker__typechecker__FlowState){0};
  bool ovf = typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)));
  typechecker__typechecker__TypeChecker__tc_flow_set(self, (&ifpre));
  const uint32_t else_ty = typechecker__typechecker__TypeChecker__check_expr(self, ifd.else_branch);
  if (typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)))) {
    (ovf = true);
  }
  typechecker__typechecker__TypeChecker__tc_flow_set(self, (&acc));
  if (ovf) {
    typechecker__typechecker__TypeChecker__tc_flow_overflow(self, id);
  }
  const bool then_never = ((then_ty != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, then_ty)->kind == ast__ast__TypeKind_TYPE_NEVER));
  const bool else_never = ((else_ty != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, else_ty)->kind == ast__ast__TypeKind_TYPE_NEVER));
  if (then_never || else_never) {
    return typechecker__typechecker__if_ty(then_never, else_ty, then_ty);
  }
  if (((then_ty != else_ty) && (then_ty != ast__ast__TYPE_NONE)) && (else_ty != ast__ast__TYPE_NONE)) {
    typechecker__typechecker__TypeChecker__err_mismatch(self, ifd.else_branch, then_ty);
    return ast__ast__TYPE_NONE;
  }
  return then_ty;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__TypeChecker__check_tuple_value(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const expected) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList elems = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_literal.elements;
  if (elems.len > 4U) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc263 = String__Global__new();
String__Global__push_str(&__sc263, (str){ .ptr = (const uint8_t*)"tuple arity is limited to 4 elements", .len = sizeof("tuple arity is limited to 4 elements") - 1 });
__sc263; }));
    return ast__ast__TYPE_NONE;
  }
  typechecker__typechecker__Tys4 wargs = (typechecker__typechecker__Tys4){0};
  int32_t wn = -1;
  if (expected != ast__ast__TYPE_NONE) {
    (wn = typechecker__typechecker__TypeChecker__tuple_args_of(self, typechecker__typechecker__TypeChecker__strip(self, expected), ((uint32_t *)(&wargs.t[0])), 4));
  }
  typechecker__typechecker__Tys4 targs = (typechecker__typechecker__Tys4){0};
  for (uint32_t i = 0U; i < elems.len; i++) {
    const uint32_t eid = ast__ast__Ast__list(&((*a)), elems)[((size_t)i)];
    const uint32_t et = typechecker__typechecker__TypeChecker__check_expr(self, eid);
    (targs.t[((size_t)i)] = et);
    if (((((int32_t)i) < wn) && (et != wargs.t[((size_t)i)])) && typechecker__typechecker__TypeChecker__compatible(self, wargs.t[((size_t)i)], eid)) {
      (targs.t[((size_t)i)] = wargs.t[((size_t)i)]);
      ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), eid, wargs.t[((size_t)i)]);
    }
    typechecker__typechecker__TypeChecker__tc_mark_move(self, eid);
  }
  return typechecker__typechecker__TypeChecker__prelude_tuple_type(self, ((const uint32_t *)(&targs.t[0])), elems.len);
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_loop_body(typechecker__typechecker__TypeChecker *const self, uint32_t const body) {
  const uint32_t nm0 = self->nmoved;
  const uint32_t nb0 = self->nborrows;
  typechecker__typechecker__TypeChecker__check_stmt(self, body);
  if (((self->nmoved > nm0) || (self->nborrows > nb0)) && (!self->in_loop_recheck)) {
    (self->in_loop_recheck = true);
    typechecker__typechecker__TypeChecker__check_stmt(self, body);
    (self->in_loop_recheck = false);
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_tuple_let(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t value = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.value;
  const uint32_t nm = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.name;
  const ast__ast__NodeList names = ast__ast__Ast__at_const(&((*a)), nm)->as_data.pattern.children;
  (self->mret_call = ast__ast__NODE_NONE);
  typechecker__typechecker__TypeChecker__check_expr(self, value);
  const bool stashed = ((value != ast__ast__NODE_NONE) && (self->mret_call == value));
  typechecker__typechecker__Tys4 targs = (typechecker__typechecker__Tys4){0};
  int32_t tn = -1;
  if ((!stashed) && (value != ast__ast__NODE_NONE)) {
    (tn = typechecker__typechecker__TypeChecker__tuple_args_of(self, typechecker__typechecker__TypeChecker__strip(self, ast__ast__Ast__type_of(&((*a)), value)), ((uint32_t *)(&targs.t[0])), 4));
    if (tn >= 0) {
      typechecker__typechecker__TypeChecker__tc_mark_move(self, value);
    }
  }
  ast__ast__NodeList returns = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  bool ok = false;
  if ((value != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*a)), value)->kind == ast__ast__NodeKind_NODE_CALL)) {
    const uint32_t calleeId = ast__ast__Ast__at_const(&((*a)), value)->as_data.call.callee;
    const uint32_t callee = ast__ast__Ast__type_of(&((*a)), calleeId);
    if (callee != ast__ast__TYPE_NONE) {
      const ast__ast__Ty ct = (*typechecker__typechecker__TypeChecker__type_at(self, callee));
      if (ct.kind == ast__ast__TypeKind_TYPE_FUNCTION) {
        const ast__ast__Node *const fnn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, ct.module))), ct.as_data.decl);
        (returns = typechecker__typechecker__if_nl((fnn->kind == ast__ast__NodeKind_NODE_FUNCTION), fnn->as_data.function.returns, fnn->as_data.function_type.returns));
        (ok = true);
      }
    } else {
      const ast__ast__Node *const cn = ast__ast__Ast__at_const(&((*a)), calleeId);
      if (cn->kind == ast__ast__NodeKind_NODE_MEMBER) {
        const ast__ast__DefId md = ast__ast__Ast__resolution_def(&((*a)), cn->as_data.member.member);
        if (((md.node != ast__ast__NODE_NONE) && (md.module == self->ast.module)) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->kind == ast__ast__NodeKind_NODE_FUNCTION)) {
          (returns = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, md.module))), md.node)->as_data.function.returns);
          (ok = true);
        }
      }
    }
  }
  if (((!ok) && (!stashed)) && (tn < 0)) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc264 = String__Global__new();
String__Global__push_str(&__sc264, (str){ .ptr = (const uint8_t*)"a tuple binding requires a multi-value function call or a tuple value", .len = sizeof("a tuple binding requires a multi-value function call or a tuple value") - 1 });
__sc264; }));
    return;
  }
  const uint32_t nret = typechecker__typechecker__if_u32(stashed, self->mret_total, typechecker__typechecker__if_u32((tn >= 0), ((uint32_t)tn), returns.len));
  if (names.len != nret) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    const char *s1 = ((const char *)({ __auto_type __sc265 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc265); }));
    if (names.len == 1U) {
      (s1 = ((const char *)({ __auto_type __sc266 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc266); })));
    }
    const char *s2 = ((const char *)({ __auto_type __sc267 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc267); }));
    if (nret == 1U) {
      (s2 = ((const char *)({ __auto_type __sc268 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc268); })));
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc269 = String__Global__new();
String__Global__push_str(&__sc269, (str){ .ptr = (const uint8_t*)"expected ", .len = sizeof("expected ") - 1 });
String__Global__push_u64(&__sc269, (uint64_t)(names.len));
String__Global__push_str(&__sc269, (str){ .ptr = (const uint8_t*)" binding", .len = sizeof(" binding") - 1 });
String__Global__push_str(&__sc269, utils__errors__cstr(s1));
String__Global__push_str(&__sc269, (str){ .ptr = (const uint8_t*)", the call returns ", .len = sizeof(", the call returns ") - 1 });
String__Global__push_u64(&__sc269, (uint64_t)(nret));
String__Global__push_str(&__sc269, (str){ .ptr = (const uint8_t*)" value", .len = sizeof(" value") - 1 });
String__Global__push_str(&__sc269, utils__errors__cstr(s2));
__sc269; }));
  }
  for (uint32_t i = 0U; i < names.len; i++) {
    uint32_t et = ast__ast__TYPE_NONE;
    if (stashed && (i < ((uint32_t)self->mret_n))) {
      (et = self->mret_types[((size_t)i)]);
    } else if (tn >= 0) {
      (et = typechecker__typechecker__if_ty((i < ((uint32_t)tn)), targs.t[((size_t)i)], ast__ast__TYPE_NONE));
    } else if (i < returns.len) {
      const uint32_t r0 = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), returns)[((size_t)i)];
      const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), r0);
      (et = typechecker__typechecker__TypeChecker__resolve_type(self, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0)));
    }
    ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), names)[((size_t)i)], et);
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_return(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeList values = ast__ast__Ast__at_const(&((*a)), id)->as_data.return_stmt.values;
  const ast__ast__NodeList rets = self->current_returns;
  const bool returns_void = typechecker__typechecker__TypeChecker__return_list_is_explicit_void(self, rets);
  if (((values.len == 1U) && (!returns_void)) && (rets.len == 1U)) {
    const uint32_t r0 = ast__ast__Ast__list(&((*a)), rets)[0];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*a)), r0);
    (self->expected = typechecker__typechecker__TypeChecker__resolve_type(self, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0)));
  }
  for (uint32_t i = 0U; i < values.len; i++) {
    const uint32_t vid = ast__ast__Ast__list(&((*a)), values)[((size_t)i)];
    typechecker__typechecker__TypeChecker__check_expr(self, vid);
    typechecker__typechecker__TypeChecker__tc_capture_move_guard(self, vid);
  }
  for (uint32_t i = 0U; i < values.len; i++) {
    const uint32_t vid = ast__ast__Ast__list(&((*a)), values)[((size_t)i)];
    const int32_t esc = typechecker__typechecker__TypeChecker__addr_escape(self, vid);
    if (esc != 0) {
      const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), vid)->span;
      const char *w = ((const char *)({ __auto_type __sc270 = (str){ (const uint8_t *)"local variable", sizeof("local variable") - 1 }; str__ptr(&__sc270); }));
      if (esc == 2) {
        (w = ((const char *)({ __auto_type __sc271 = (str){ (const uint8_t *)"function parameter", sizeof("function parameter") - 1 }; str__ptr(&__sc271); })));
      }
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc272 = String__Global__new();
String__Global__push_str(&__sc272, (str){ .ptr = (const uint8_t*)"returning a pointer/reference to a ", .len = sizeof("returning a pointer/reference to a ") - 1 });
String__Global__push_str(&__sc272, utils__errors__cstr(w));
String__Global__push_str(&__sc272, (str){ .ptr = (const uint8_t*)", which does not outlive the call", .len = sizeof(", which does not outlive the call") - 1 });
__sc272; }));
    }
  }
  const uint32_t expected = typechecker__typechecker__if_u32(returns_void, 0U, rets.len);
  if (values.len != expected) {
    const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
    const char *s2 = ((const char *)({ __auto_type __sc273 = (str){ (const uint8_t *)"s", sizeof("s") - 1 }; str__ptr(&__sc273); }));
    if (expected == 1U) {
      (s2 = ((const char *)({ __auto_type __sc274 = (str){ (const uint8_t *)"", sizeof("") - 1 }; str__ptr(&__sc274); })));
    }
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc275 = String__Global__new();
String__Global__push_str(&__sc275, (str){ .ptr = (const uint8_t*)"expected ", .len = sizeof("expected ") - 1 });
String__Global__push_u64(&__sc275, (uint64_t)(expected));
String__Global__push_str(&__sc275, (str){ .ptr = (const uint8_t*)" return value", .len = sizeof(" return value") - 1 });
String__Global__push_str(&__sc275, utils__errors__cstr(s2));
String__Global__push_str(&__sc275, (str){ .ptr = (const uint8_t*)", found ", .len = sizeof(", found ") - 1 });
String__Global__push_u64(&__sc275, (uint64_t)(values.len));
__sc275; }));
    return;
  }
  if (returns_void) {
    return;
  }
  for (uint32_t i = 0U; i < values.len; i++) {
    const uint32_t vid = ast__ast__Ast__list(&((*a)), values)[((size_t)i)];
    const uint32_t r0 = ast__ast__Ast__list(&((*a)), rets)[((size_t)i)];
    const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*a)), r0);
    const uint32_t rt = typechecker__typechecker__TypeChecker__resolve_type(self, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0));
    if (!typechecker__typechecker__TypeChecker__compatible(self, rt, vid)) {
      typechecker__typechecker__TypeChecker__err_mismatch(self, vid, rt);
    }
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_static_assert(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const uint32_t left = ast__ast__Ast__at_const(&((*a)), id)->as_data.binary.left;
  const uint32_t c = typechecker__typechecker__TypeChecker__check_expr(self, left);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), left)->span;
  if ((c != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, c))) {
    typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
    typechecker__typechecker__TypeChecker__render_type(self, c, ((char *)(&ty.b[0])), 96ULL);
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc276 = String__Global__new();
String__Global__push_str(&__sc276, (str){ .ptr = (const uint8_t*)"static_assert condition must be 'bool', found '", .len = sizeof("static_assert condition must be 'bool', found '") - 1 });
String__Global__push_str(&__sc276, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc276, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc276; }));
    return;
  }
  consteval__consteval__ConstEval *const ceptr = typechecker__typechecker__TypeChecker__ceval(self);
  if (ceptr == NULL) {
    return;
  }
  const consteval__consteval__ConstValue v = consteval__consteval__ConstEval__eval(&((*ceptr)), self->ast.module, left);
  if ((v.kind == consteval__consteval__CONST_BOOL) && (v.as_data.i == 0)) {
    utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc277 = String__Global__new();
String__Global__push_str(&__sc277, (str){ .ptr = (const uint8_t*)"static assertion failed", .len = sizeof("static assertion failed") - 1 });
__sc277; }));
  } else if (v.kind == consteval__consteval__CONST_NONE) {
    const str trap = consteval__consteval__ConstEval__ce_trap_get(&((*ceptr)));
    if (str__len(&trap) != 0ULL) {
      utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc278 = String__Global__new();
String__Global__push_str(&__sc278, (str){ .ptr = (const uint8_t*)"static assertion cannot be evaluated: ", .len = sizeof("static assertion cannot be evaluated: ") - 1 });
String__Global__push_str(&__sc278, trap);
__sc278; }));
    } else {
      consteval__consteval__ConstEval__defer_assert(&((*ceptr)), self->ast.module, left);
    }
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_stmt(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), id)->kind;
  {
    const ast__ast__NodeKind __sc279 = nk;
    if (__sc279 == ast__ast__NodeKind_NODE_STATIC_ASSERT) {
      {
        typechecker__typechecker__TypeChecker__check_static_assert(self, id);
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        const ast__ast__NodeList stmts = ast__ast__Ast__at_const(&((*a)), id)->as_data.block.statements;
        typechecker__typechecker__TypeChecker__tc_scope_enter(self);
        for (uint32_t i = 0U; i < stmts.len; i++) {
          typechecker__typechecker__TypeChecker__check_stmt(self, ast__ast__Ast__list(&((*a)), stmts)[((size_t)i)]);
          typechecker__typechecker__TypeChecker__borrow_nll_drop(self, id, ast__ast__Ast__list(&((*a)), stmts), i);
        }
        while ((self->ndefers != 0U) && (self->defer_depth[((size_t)(self->ndefers - 1U))] == self->scope_depth)) {
          (self->ndefers = (self->ndefers - 1U));
          const uint32_t dv = self->defer_stack[((size_t)self->ndefers)];
          const uint32_t dbm = typechecker__typechecker__TypeChecker__borrow_mark(self);
          typechecker__typechecker__TypeChecker__check_expr(self, dv);
          typechecker__typechecker__TypeChecker__borrow_release_to(self, dbm);
        }
        typechecker__typechecker__TypeChecker__tc_scope_exit(self);
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_LET) {
      {
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        const uint32_t nm = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.name;
        if (ast__ast__Ast__at_const(&((*a)), nm)->kind == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
          typechecker__typechecker__TypeChecker__check_tuple_let(self, id);
          const ast__ast__NodeList eids = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nm)->as_data.pattern.children;
          for (uint32_t k = 0U; k < eids.len; k++) {
            typechecker__typechecker__TypeChecker__tc_record_binding_depth(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), eids)[((size_t)k)]);
          }
          typechecker__typechecker__TypeChecker__tc_record_binding_depth(self, id);
          if (typechecker__typechecker__TypeChecker__tuple_binds_reference(self, nm) && (self->nborrows > bm)) {
            for (uint32_t j = bm; j < self->nborrows; j++) {
              (self->borrows[((size_t)j)].binding = id);
              (self->borrows[((size_t)j)].region = ((uint16_t)self->scope_depth));
            }
          } else {
            typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
          }
          return;
        }
        typechecker__typechecker__TypeChecker__tc_record_binding_depth(self, id);
        const uint32_t tyn = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.ty;
        const uint32_t value = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.value;
        const bool annotated = (tyn != ast__ast__NODE_NONE);
        const bool valued = (value != ast__ast__NODE_NONE);
        const uint32_t declared = typechecker__typechecker__if_ty(annotated, typechecker__typechecker__TypeChecker__resolve_type(self, tyn), ast__ast__TYPE_NONE);
        if (valued) {
          (self->expected = declared);
          typechecker__typechecker__TypeChecker__check_expr(self, value);
          typechecker__typechecker__TypeChecker__tc_mark_move(self, value);
          typechecker__typechecker__TypeChecker__tc_unmark_move(self, id);
        }
        uint32_t binding = ast__ast__TYPE_NONE;
        if (annotated) {
          if (valued && (!typechecker__typechecker__TypeChecker__compatible(self, declared, value))) {
            typechecker__typechecker__TypeChecker__err_mismatch(self, value, declared);
          }
          (binding = declared);
        } else if (valued) {
          (binding = ast__ast__Ast__type_of(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), value));
        } else {
          const lexer__token__Span sp = typechecker__typechecker__TypeChecker__name_span(self, nm);
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc280 = String__Global__new();
String__Global__push_str(&__sc280, (str){ .ptr = (const uint8_t*)"cannot infer type of '", .len = sizeof("cannot infer type of '") - 1 });
String__Global__push_str(&__sc280, utils__errors__span_str(self->source, sp.start, sp.end));
String__Global__push_str(&__sc280, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc280; }));
        }
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, binding);
        if (annotated && (!valued)) {
          if (typechecker__typechecker__TypeChecker__tc_type_is_free(self, binding)) {
            const lexer__token__Span sp = typechecker__typechecker__TypeChecker__name_span(self, nm);
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc281 = String__Global__new();
String__Global__push_str(&__sc281, (str){ .ptr = (const uint8_t*)"a Free-typed binding must be initialized when declared (it is freed at scope exit)", .len = sizeof("a Free-typed binding must be initialized when declared (it is freed at scope exit)") - 1 });
__sc281; }));
          } else {
            typechecker__typechecker__TypeChecker__tc_add_uninit(self, id);
          }
        }
        const bool binding_is_ref = ((binding != ast__ast__TYPE_NONE) && (typechecker__typechecker__TypeChecker__type_at(self, binding)->kind == ast__ast__TypeKind_TYPE_REFERENCE));
        if (binding_is_ref && (self->nborrows > bm)) {
          for (uint32_t k = bm; k < self->nborrows; k++) {
            (self->borrows[((size_t)k)].binding = id);
            (self->borrows[((size_t)k)].region = ((uint16_t)self->scope_depth));
          }
        } else {
          typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
          if (binding_is_ref && valued) {
            typechecker__typechecker__TypeChecker__borrow_transfer_ref(self, value, id);
          }
        }
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_CONST) {
      {
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        const uint32_t declared = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.const_def.ty);
        const uint32_t value = ast__ast__Ast__at_const(&((*a)), id)->as_data.const_def.value;
        if (value != ast__ast__NODE_NONE) {
          typechecker__typechecker__TypeChecker__check_expr(self, value);
          if (!typechecker__typechecker__TypeChecker__compatible(self, declared, value)) {
            typechecker__typechecker__TypeChecker__err_mismatch(self, value, declared);
          }
        }
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, declared);
        typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_RETURN) {
      {
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        typechecker__typechecker__TypeChecker__check_return(self, id);
        typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_DEFER) {
      {
        const typechecker__typechecker__FlowState pre = typechecker__typechecker__TypeChecker__tc_flow_save(self);
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        const uint32_t dv = ast__ast__Ast__at_const(&((*a)), id)->as_data.single.value;
        typechecker__typechecker__TypeChecker__check_expr(self, dv);
        typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
        typechecker__typechecker__TypeChecker__tc_flow_set(self, (&pre));
        if (self->ndefers < 256U) {
          const uint32_t k = self->ndefers;
          (self->defer_stack[((size_t)k)] = dv);
          (self->defer_depth[((size_t)k)] = self->scope_depth);
          (self->ndefers = (k + 1U));
        } else {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc282 = String__Global__new();
String__Global__push_str(&__sc282, (str){ .ptr = (const uint8_t*)"too many pending 'defer' statements in one function (analysis limit)", .len = sizeof("too many pending 'defer' statements in one function (analysis limit)") - 1 });
__sc282; }));
        }
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_IF) {
      {
        typechecker__typechecker__TypeChecker__check_if_stmt(self, id);
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_WHILE) {
      {
        (self->loop_depth = (self->loop_depth + 1U));
        const int32_t le = typechecker__typechecker__TypeChecker__tc_loop_push(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.label, id, false);
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        const uint32_t c = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.condition);
        if ((c != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_bool(self, c))) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.condition)->span;
          typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, c, ((char *)(&ty.b[0])), 96ULL);
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc283 = String__Global__new();
String__Global__push_str(&__sc283, (str){ .ptr = (const uint8_t*)"while condition must be 'bool', found '", .len = sizeof("while condition must be 'bool', found '") - 1 });
String__Global__push_str(&__sc283, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc283, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc283; }));
        }
        typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
        const uint32_t body = ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.body;
        if (ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.is_do || (ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.condition == ast__ast__NODE_NONE)) {
          typechecker__typechecker__TypeChecker__check_loop_body(self, body);
        } else {
          const typechecker__typechecker__FlowState pre = typechecker__typechecker__TypeChecker__tc_flow_save(self);
          typechecker__typechecker__TypeChecker__check_loop_body(self, body);
          typechecker__typechecker__FlowState acc = (typechecker__typechecker__FlowState){0};
          bool ovf = typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)));
          typechecker__typechecker__TypeChecker__tc_flow_set(self, (&pre));
          if (typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)))) {
            (ovf = true);
          }
          typechecker__typechecker__TypeChecker__tc_flow_set(self, (&acc));
          if (ovf) {
            typechecker__typechecker__TypeChecker__tc_flow_overflow(self, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.while_stmt.condition);
          }
        }
        if (le >= 0) {
          typechecker__typechecker__TypeChecker__tc_loop_pop(self, le, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span);
        }
        (self->loop_depth = (self->loop_depth - 1U));
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_FOR) {
      {
        (self->loop_depth = (self->loop_depth + 1U));
        const int32_t le = typechecker__typechecker__TypeChecker__tc_loop_push(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.for_stmt.label, id, false);
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        const uint32_t iter = ast__ast__Ast__at_const(&((*a)), id)->as_data.for_stmt.iterable;
        uint32_t elem = ast__ast__TYPE_NONE;
        if (ast__ast__Ast__at_const(&((*a)), iter)->kind == ast__ast__NodeKind_NODE_RANGE) {
          const uint32_t s = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), iter)->as_data.pattern_range.start);
          const uint32_t e = typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), iter)->as_data.pattern_range.end);
          (elem = typechecker__typechecker__TypeChecker__range_type(self, iter, s, e));
          ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), iter, elem);
        } else {
          const uint32_t it = typechecker__typechecker__TypeChecker__check_expr(self, iter);
          const ast__ast__Ty ity = (*typechecker__typechecker__TypeChecker__type_at(self, it));
          uint32_t selem = ast__ast__TYPE_NONE;
          if (ity.kind == ast__ast__TypeKind_TYPE_ARRAY) {
            (elem = ity.as_data.elem);
          } else if (typechecker__typechecker__TypeChecker__slice_kind(self, it, ((uint32_t *)(&selem))) != 0) {
            (elem = selem);
          } else {
            (elem = typechecker__typechecker__TypeChecker__range_instance_elem(self, it));
          }
          if ((elem == ast__ast__TYPE_NONE) && (it != ast__ast__TYPE_NONE)) {
            (elem = typechecker__typechecker__TypeChecker__iter_elem_type(self, it));
          }
          if ((elem == ast__ast__TYPE_NONE) && (it != ast__ast__TYPE_NONE)) {
            const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), iter)->span;
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc284 = String__Global__new();
String__Global__push_str(&__sc284, (str){ .ptr = (const uint8_t*)"cannot iterate over this value (need an array, slice, range, or an Iterator)", .len = sizeof("cannot iterate over this value (need an array, slice, range, or an Iterator)") - 1 });
__sc284; }));
          }
        }
        ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, elem);
        if (id != ast__ast__NODE_NONE) {
          Map__u32__u32__Global__insert(&self->binding_depth, id, (self->scope_depth + 1U));
        }
        typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
        const typechecker__typechecker__FlowState pre = typechecker__typechecker__TypeChecker__tc_flow_save(self);
        typechecker__typechecker__TypeChecker__check_loop_body(self, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.for_stmt.body);
        typechecker__typechecker__FlowState acc = (typechecker__typechecker__FlowState){0};
        bool ovf = typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)));
        typechecker__typechecker__TypeChecker__tc_flow_set(self, (&pre));
        if (typechecker__typechecker__TypeChecker__tc_flow_collect(self, ((typechecker__typechecker__FlowState *)(&acc)))) {
          (ovf = true);
        }
        typechecker__typechecker__TypeChecker__tc_flow_set(self, (&acc));
        if (ovf) {
          typechecker__typechecker__TypeChecker__tc_flow_overflow(self, iter);
        }
        if (le >= 0) {
          typechecker__typechecker__TypeChecker__tc_loop_pop(self, le, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span);
        }
        (self->loop_depth = (self->loop_depth - 1U));
      }
    }
    else if (__sc279 == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) {
      {
        const uint32_t bm = typechecker__typechecker__TypeChecker__borrow_mark(self);
        typechecker__typechecker__TypeChecker__check_expr(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.single.value);
        typechecker__typechecker__TypeChecker__borrow_release_to(self, bm);
      }
    }
    else if ((__sc279 == ast__ast__NodeKind_NODE_BREAK) || (__sc279 == ast__ast__NodeKind_NODE_CONTINUE)) {
      {
        const lexer__token__Span lb = ast__ast__Ast__at_const(&((*a)), id)->as_data.flow.label;
        const int32_t le = typechecker__typechecker__TypeChecker__tc_find_loop(self, lb);
        if (le < 0) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->span;
          if (lb.end > lb.start) {
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc285 = String__Global__new();
String__Global__push_str(&__sc285, (str){ .ptr = (const uint8_t*)"no enclosing loop is labeled ", .len = sizeof("no enclosing loop is labeled ") - 1 });
String__Global__push_str(&__sc285, utils__errors__span_str(self->source, lb.start, lb.end));
__sc285; }));
          } else {
            const char *w = ((const char *)({ __auto_type __sc286 = (str){ (const uint8_t *)"continue", sizeof("continue") - 1 }; str__ptr(&__sc286); }));
            if (nk == ast__ast__NodeKind_NODE_BREAK) {
              (w = ((const char *)({ __auto_type __sc287 = (str){ (const uint8_t *)"break", sizeof("break") - 1 }; str__ptr(&__sc287); })));
            }
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc288 = String__Global__new();
String__Global__push_str(&__sc288, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
String__Global__push_str(&__sc288, utils__errors__cstr(w));
String__Global__push_str(&__sc288, (str){ .ptr = (const uint8_t*)"' outside of a loop", .len = sizeof("' outside of a loop") - 1 });
__sc288; }));
          }
          const uint32_t fv = ast__ast__Ast__at_const(&((*a)), id)->as_data.flow.value;
          if (fv != ast__ast__NODE_NONE) {
            typechecker__typechecker__TypeChecker__check_expr(self, fv);
          }
          return;
        }
        ast__ast__Ast__set_resolution(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, self->loop_stack[((size_t)le)].node);
        if (nk != ast__ast__NodeKind_NODE_BREAK) {
          return;
        }
        const uint32_t fv = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.flow.value;
        if (fv == ast__ast__NODE_NONE) {
          (self->loop_stack[((size_t)le)].saw_bare = true);
          return;
        }
        (self->expected = self->loop_stack[((size_t)le)].break_ty);
        const uint32_t vt = typechecker__typechecker__TypeChecker__check_expr(self, fv);
        const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
        if (!self->loop_stack[((size_t)le)].value_loop) {
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc289 = String__Global__new();
String__Global__push_str(&__sc289, (str){ .ptr = (const uint8_t*)"'break' can only carry a value inside a 'loop' expression", .len = sizeof("'break' can only carry a value inside a 'loop' expression") - 1 });
__sc289; }));
        } else if (self->loop_stack[((size_t)le)].break_ty == ast__ast__TYPE_NONE) {
          (self->loop_stack[((size_t)le)].break_ty = vt);
        } else if (!typechecker__typechecker__TypeChecker__compatible(self, self->loop_stack[((size_t)le)].break_ty, fv)) {
          typechecker__typechecker__TypeChecker__err_mismatch(self, fv, self->loop_stack[((size_t)le)].break_ty);
        }
        (self->loop_stack[((size_t)le)].saw_value = true);
        typechecker__typechecker__TypeChecker__tc_mark_move(self, fv);
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_pattern(typechecker__typechecker__TypeChecker *const self, uint32_t const id, uint32_t const expected, int32_t const bind_ref) {
  if (id == ast__ast__NODE_NONE) {
    return;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), id)->kind;
  if (nk == ast__ast__NodeKind_NODE_IDENTIFIER) {
    ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, typechecker__typechecker__if_ty((bind_ref != 0), typechecker__typechecker__TypeChecker__tc_ref(self, expected, (bind_ref == 2)), expected));
    typechecker__typechecker__TypeChecker__tc_record_binding_depth(self, id);
  } else if (nk == ast__ast__NodeKind_NODE_PATTERN_NAME) {
    const uint32_t nameId = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern.name;
    uint16_t bmod = 0U;
    uint32_t decl = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    const bool agok = typechecker__typechecker__TypeChecker__aggregate_of(self, typechecker__typechecker__TypeChecker__strip(self, expected), ((uint16_t *)(&bmod)), ((uint32_t *)(&decl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
    if (agok && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), decl)->kind == ast__ast__NodeKind_NODE_ENUM)) {
      const uint32_t v = typechecker__typechecker__TypeChecker__find_member(self, bmod, decl, typechecker__typechecker__TypeChecker__name_span(self, nameId));
      if (((v != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), v)->kind == ast__ast__NodeKind_NODE_VARIANT)) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), v)->as_data.variant.payload.len == 0U)) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nameId, (ast__ast__DefId){ .module = bmod, .node = v });
        return;
      }
    }
    ast__ast__Ast__set_type(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id, typechecker__typechecker__if_ty((bind_ref != 0), typechecker__typechecker__TypeChecker__tc_ref(self, expected, (bind_ref == 2)), expected));
    typechecker__typechecker__TypeChecker__tc_record_binding_depth(self, id);
    const ast__ast__NodeList subs = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.pattern.children;
    for (uint32_t i = 0U; i < subs.len; i++) {
      typechecker__typechecker__TypeChecker__check_pattern(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), subs)[((size_t)i)], expected, bind_ref);
    }
  } else if (nk == ast__ast__NodeKind_NODE_PATTERN_STRUCT) {
    const uint32_t base = typechecker__typechecker__TypeChecker__strip(self, expected);
    const uint32_t nameId = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern.name;
    uint16_t bmod = 0U;
    uint32_t decl = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    const bool agg = typechecker__typechecker__TypeChecker__aggregate_of(self, base, ((uint16_t *)(&bmod)), ((uint32_t *)(&decl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
    uint32_t variant = ast__ast__NODE_NONE;
    if ((agg && (nameId != ast__ast__NODE_NONE)) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), decl)->kind == ast__ast__NodeKind_NODE_ENUM)) {
      const uint32_t v = typechecker__typechecker__TypeChecker__find_member(self, bmod, decl, typechecker__typechecker__TypeChecker__name_span(self, nameId));
      if ((v != ast__ast__NODE_NONE) && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), v)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
        (variant = v);
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nameId, (ast__ast__DefId){ .module = bmod, .node = variant });
      }
    }
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.pattern.children;
    if (variant != ast__ast__NODE_NONE) {
      ast__ast__Ast *const va = typechecker__typechecker__TypeChecker__mod_ast(self, bmod);
      const ast__ast__NodeList vpl = ast__ast__Ast__at_const(&((*va)), variant)->as_data.variant.payload;
      for (uint32_t i = 0U; i < children.len; i++) {
        const uint32_t fid = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), children)[((size_t)i)];
        const uint32_t fldName = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), fid)->as_data.pattern.name;
        const lexer__token__Span fn2 = typechecker__typechecker__TypeChecker__name_span(self, fldName);
        uint32_t ft = ast__ast__TYPE_NONE;
        uint32_t matchId = ast__ast__NODE_NONE;
        for (uint32_t j = 0U; j < vpl.len; j++) {
          const uint32_t pfid = ast__ast__Ast__list(&((*va)), vpl)[((size_t)j)];
          const ast__ast__Node *const pf = ast__ast__Ast__at_const(&((*va)), pfid);
          if ((pf->kind == ast__ast__NodeKind_NODE_FIELD) && typechecker__typechecker__spans_eq2(self->source, fn2, typechecker__typechecker__TypeChecker__mod_src(self, bmod), ast__ast__Ast__at_const(&((*va)), pf->as_data.field.name)->as_data.name.text)) {
            (matchId = pfid);
            (ft = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, bmod, pf->as_data.field.ty), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn));
            break;
          }
        }
        if (matchId != ast__ast__NODE_NONE) {
          ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), fldName, (ast__ast__DefId){ .module = bmod, .node = matchId });
        } else {
          typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, base, ((char *)(&ty.b[0])), 96ULL);
          utils__errors__Errors__emit(&self->errors, fn2.start, (fn2.end - fn2.start), ({ String__Global __sc290 = String__Global__new();
String__Global__push_str(&__sc290, (str){ .ptr = (const uint8_t*)"no field '", .len = sizeof("no field '") - 1 });
String__Global__push_str(&__sc290, utils__errors__span_str(self->source, fn2.start, fn2.end));
String__Global__push_str(&__sc290, (str){ .ptr = (const uint8_t*)"' on '", .len = sizeof("' on '") - 1 });
String__Global__push_str(&__sc290, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc290, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc290; }));
        }
        const ast__ast__NodeList fc = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), fid)->as_data.pattern.children;
        for (uint32_t k = 0U; k < fc.len; k++) {
          typechecker__typechecker__TypeChecker__check_pattern(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), fc)[((size_t)k)], ft, bind_ref);
        }
      }
    } else {
      if (agg && (nameId != ast__ast__NODE_NONE)) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nameId, (ast__ast__DefId){ .module = bmod, .node = decl });
      }
      for (uint32_t i = 0U; i < children.len; i++) {
        typechecker__typechecker__TypeChecker__check_pattern(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), children)[((size_t)i)], base, bind_ref);
      }
    }
  } else if (nk == ast__ast__NodeKind_NODE_PATTERN_FIELD) {
    const uint32_t base = typechecker__typechecker__TypeChecker__strip(self, expected);
    const uint32_t nameId = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern.name;
    uint16_t bmod = 0U;
    uint32_t decl = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    const bool agg = typechecker__typechecker__TypeChecker__aggregate_of(self, base, ((uint16_t *)(&bmod)), ((uint32_t *)(&decl)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
    uint32_t field_type = ast__ast__TYPE_NONE;
    if (agg && (nameId != ast__ast__NODE_NONE)) {
      const lexer__token__Span fname = typechecker__typechecker__TypeChecker__name_span(self, nameId);
      const uint32_t field = typechecker__typechecker__TypeChecker__find_member(self, bmod, decl, fname);
      if (field != ast__ast__NODE_NONE) {
        ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nameId, (ast__ast__DefId){ .module = bmod, .node = field });
        (field_type = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__decl_type_in(self, bmod, field), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn));
      } else {
        typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, base, ((char *)(&ty.b[0])), 96ULL);
        utils__errors__Errors__emit(&self->errors, fname.start, (fname.end - fname.start), ({ String__Global __sc291 = String__Global__new();
String__Global__push_str(&__sc291, (str){ .ptr = (const uint8_t*)"no field '", .len = sizeof("no field '") - 1 });
String__Global__push_str(&__sc291, utils__errors__span_str(self->source, fname.start, fname.end));
String__Global__push_str(&__sc291, (str){ .ptr = (const uint8_t*)"' on '", .len = sizeof("' on '") - 1 });
String__Global__push_str(&__sc291, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc291, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc291; }));
      }
    }
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      typechecker__typechecker__TypeChecker__check_pattern(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), children)[((size_t)i)], field_type, bind_ref);
    }
  } else if (nk == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
    const uint32_t base = typechecker__typechecker__TypeChecker__strip(self, expected);
    const uint32_t nameId = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern.name;
    uint16_t bmod = self->ast.module;
    uint32_t decl0 = ast__ast__NODE_NONE;
    typechecker__typechecker__Defs4 gp = (typechecker__typechecker__Defs4){0};
    typechecker__typechecker__Tys4 ga = (typechecker__typechecker__Tys4){0};
    int32_t gn = 0;
    const bool agok = typechecker__typechecker__TypeChecker__aggregate_of(self, base, ((uint16_t *)(&bmod)), ((uint32_t *)(&decl0)), ((ast__ast__DefId *)(&gp.d[0])), ((uint32_t *)(&ga.t[0])), ((int32_t *)(&gn)));
    const bool agg = (agok && (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__mod_ast(self, bmod))), decl0)->kind == ast__ast__NodeKind_NODE_ENUM));
    const uint32_t decl = typechecker__typechecker__if_node(agg, decl0, ast__ast__NODE_NONE);
    uint32_t variant = ast__ast__NODE_NONE;
    if (nameId != ast__ast__NODE_NONE) {
      const lexer__token__Span vname = typechecker__typechecker__TypeChecker__name_span(self, nameId);
      if (decl == ast__ast__NODE_NONE) {
        typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
        typechecker__typechecker__TypeChecker__render_type(self, base, ((char *)(&ty.b[0])), 96ULL);
        utils__errors__Errors__emit(&self->errors, vname.start, (vname.end - vname.start), ({ String__Global __sc292 = String__Global__new();
String__Global__push_str(&__sc292, (str){ .ptr = (const uint8_t*)"pattern '", .len = sizeof("pattern '") - 1 });
String__Global__push_str(&__sc292, utils__errors__span_str(self->source, vname.start, vname.end));
String__Global__push_str(&__sc292, (str){ .ptr = (const uint8_t*)"(..)' expects an enum, but the value has type '", .len = sizeof("(..)' expects an enum, but the value has type '") - 1 });
String__Global__push_str(&__sc292, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc292, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc292; }));
      } else {
        (variant = typechecker__typechecker__TypeChecker__find_member(self, bmod, decl, vname));
        if (variant != ast__ast__NODE_NONE) {
          ast__ast__Ast__set_resolution_def(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), nameId, (ast__ast__DefId){ .module = bmod, .node = variant });
        } else {
          typechecker__typechecker__Buf96 ty = (typechecker__typechecker__Buf96){0};
          typechecker__typechecker__TypeChecker__render_type(self, base, ((char *)(&ty.b[0])), 96ULL);
          utils__errors__Errors__emit(&self->errors, vname.start, (vname.end - vname.start), ({ String__Global __sc293 = String__Global__new();
String__Global__push_str(&__sc293, (str){ .ptr = (const uint8_t*)"no variant '", .len = sizeof("no variant '") - 1 });
String__Global__push_str(&__sc293, utils__errors__span_str(self->source, vname.start, vname.end));
String__Global__push_str(&__sc293, (str){ .ptr = (const uint8_t*)"' on '", .len = sizeof("' on '") - 1 });
String__Global__push_str(&__sc293, utils__errors__cstr(((const char *)(&ty.b[0]))));
String__Global__push_str(&__sc293, (str){ .ptr = (const uint8_t*)"'", .len = sizeof("'") - 1 });
__sc293; }));
        }
      }
    }
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.pattern.children;
    ast__ast__NodeList payload = (ast__ast__NodeList){ .start = 0U, .len = 0U };
    ast__ast__Ast *va = a;
    if (variant != ast__ast__NODE_NONE) {
      (va = typechecker__typechecker__TypeChecker__mod_ast(self, bmod));
      (payload = ast__ast__Ast__at_const(&((*va)), variant)->as_data.variant.payload);
    }
    for (uint32_t i = 0U; i < children.len; i++) {
      uint32_t pt = ast__ast__TYPE_NONE;
      if (i < payload.len) {
        const uint32_t plid = ast__ast__Ast__list(&((*va)), payload)[((size_t)i)];
        const ast__ast__Node *const pe = ast__ast__Ast__at_const(&((*va)), plid);
        (pt = typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, bmod, typechecker__typechecker__if_node((pe->kind == ast__ast__NodeKind_NODE_FIELD), pe->as_data.field.ty, plid)), ((const ast__ast__DefId *)(&gp.d[0])), ((const uint32_t *)(&ga.t[0])), gn));
      }
      typechecker__typechecker__TypeChecker__check_pattern(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), children)[((size_t)i)], pt, bind_ref);
    }
  } else if (nk == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      typechecker__typechecker__TypeChecker__check_pattern(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), children)[((size_t)i)], expected, bind_ref);
    }
  }
}

static __attribute__((unused)) bool typechecker__typechecker__TypeChecker__tc_embeds_by_value(typechecker__typechecker__TypeChecker *const self, uint16_t const m, uint32_t const d, uint16_t const tm, uint32_t const td, int32_t const depth) {
  if (depth > 16) {
    return false;
  }
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__mod_ast(self, m);
  const ast__ast__Node dn = (*ast__ast__Ast__at_const(&((*a)), d));
  if (((dn.kind != ast__ast__NodeKind_NODE_STRUCT) && (dn.kind != ast__ast__NodeKind_NODE_ENUM)) || (dn.as_data.aggregate.generics.len != 0U)) {
    return false;
  }
  const ast__ast__NodeList members = dn.as_data.aggregate.members;
  for (uint32_t i = 0U; i < members.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), members)[((size_t)i)];
    const ast__ast__Node mn = (*ast__ast__Ast__at_const(&((*a)), mid));
    typechecker__typechecker__NodeArr16 tns = (typechecker__typechecker__NodeArr16){0};
    uint32_t ntn = 0U;
    if (dn.as_data.aggregate.is_tuple) {
      (tns.n[0] = mid);
      (ntn = 1U);
    } else if (mn.kind == ast__ast__NodeKind_NODE_FIELD) {
      (tns.n[0] = mn.as_data.field.ty);
      (ntn = 1U);
    } else if (mn.kind == ast__ast__NodeKind_NODE_VARIANT) {
      const ast__ast__NodeList pl = mn.as_data.variant.payload;
      uint32_t j = 0U;
      while ((j < pl.len) && (ntn < 16U)) {
        const uint32_t plid = ast__ast__Ast__list(&((*a)), pl)[((size_t)j)];
        const ast__ast__Node *const pe = ast__ast__Ast__at_const(&((*a)), plid);
        (tns.n[((size_t)ntn)] = typechecker__typechecker__if_node((pe->kind == ast__ast__NodeKind_NODE_FIELD), pe->as_data.field.ty, plid));
        (ntn = (ntn + 1U));
        (j = (j + 1U));
      }
    }
    for (uint32_t j = 0U; j < ntn; j++) {
      uint32_t ft = typechecker__typechecker__TypeChecker__lower_type_in(self, m, tns.n[((size_t)j)]);
      ast__ast__Ty y = (*typechecker__typechecker__TypeChecker__type_at(self, ft));
      while (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
        (ft = y.as_data.elem);
        (y = (*typechecker__typechecker__TypeChecker__type_at(self, ft)));
      }
      if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
        if (((y.module == tm) && (y.as_data.decl == td)) || typechecker__typechecker__TypeChecker__tc_embeds_by_value(self, y.module, y.as_data.decl, tm, td, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))) {
          return true;
        }
      }
    }
  }
  return false;
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_item(typechecker__typechecker__TypeChecker *const self, uint32_t const id) {
  ast__ast__Ast *const a = typechecker__typechecker__TypeChecker__cur_ast(self);
  const ast__ast__NodeKind nk = ast__ast__Ast__at_const(&((*a)), id)->kind;
  {
    const ast__ast__NodeKind __sc294 = nk;
    if (__sc294 == ast__ast__NodeKind_NODE_STATIC_ASSERT) {
      {
        typechecker__typechecker__TypeChecker__check_static_assert(self, id);
      }
    }
    else if (__sc294 == ast__ast__NodeKind_NODE_FUNCTION) {
      {
        const ast__ast__NodeList params = ast__ast__Ast__at_const(&((*a)), id)->as_data.function.params;
        for (uint32_t i = 0U; i < params.len; i++) {
          typechecker__typechecker__TypeChecker__decl_type(self, ast__ast__Ast__list(&((*a)), params)[((size_t)i)]);
        }
        const ast__ast__FunctionData fnd = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.function;
        if ((fnd.is_variadic && (!fnd.is_extern)) && (params.len == 0U)) {
          const lexer__token__Span sp = typechecker__typechecker__TypeChecker__name_span(self, fnd.name);
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc295 = String__Global__new();
String__Global__push_str(&__sc295, (str){ .ptr = (const uint8_t*)"a variadic function needs at least one fixed parameter before '...'", .len = sizeof("a variadic function needs at least one fixed parameter before '...'") - 1 });
__sc295; }));
        }
        if (typechecker__typechecker__span_is(self->source, typechecker__typechecker__TypeChecker__name_span(self, fnd.name), (str){ (const uint8_t *)"main", sizeof("main") - 1 })) {
          const ast__ast__NodeList rets = fnd.returns;
          uint32_t rt = ast__ast__TYPE_NONE;
          if (rets.len == 1U) {
            const uint32_t r0 = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), rets)[0];
            const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), r0);
            (rt = typechecker__typechecker__TypeChecker__resolve_type(self, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0)));
          }
          if (((params.len != 0U) || (rets.len != 1U)) || (rt != 5U)) {
            const lexer__token__Span sp = typechecker__typechecker__TypeChecker__name_span(self, fnd.name);
            utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc296 = String__Global__new();
String__Global__push_str(&__sc296, (str){ .ptr = (const uint8_t*)"'main' must be declared 'fn main() i32'", .len = sizeof("'main' must be declared 'fn main() i32'") - 1 });
__sc296; }));
          }
        }
        const ast__ast__NodeList saved = self->current_returns;
        const uint32_t savedfn = self->current_fn;
        (self->current_returns = fnd.returns);
        (self->current_fn = id);
        (self->nmoved = 0U);
        (self->nuninit = 0U);
        (self->nfreed = 0U);
        (self->nborrows = 0U);
        (self->scope_depth = 0U);
        (self->loop_depth = 0U);
        (self->ndefers = 0U);
        if (fnd.body != ast__ast__NODE_NONE) {
          typechecker__typechecker__TypeChecker__check_stmt(self, fnd.body);
        }
        (self->nmoved = 0U);
        (self->nuninit = 0U);
        (self->nfreed = 0U);
        (self->nborrows = 0U);
        (self->scope_depth = 0U);
        (self->loop_depth = 0U);
        (self->ndefers = 0U);
        (self->current_returns = saved);
        (self->current_fn = savedfn);
      }
    }
    else if ((__sc294 == ast__ast__NodeKind_NODE_STRUCT) || (__sc294 == ast__ast__NodeKind_NODE_ENUM)) {
      {
        const ast__ast__AggregateData agg = ast__ast__Ast__at_const(&((*a)), id)->as_data.aggregate;
        const ast__ast__NodeList members = agg.members;
        if (agg.is_tuple) {
          for (uint32_t i = 0U; i < members.len; i++) {
            typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), members)[((size_t)i)]);
          }
        } else {
          for (uint32_t i = 0U; i < members.len; i++) {
            const uint32_t mid = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), members)[((size_t)i)];
            const ast__ast__Node mn = (*ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mid));
            if (mn.kind == ast__ast__NodeKind_NODE_FIELD) {
              typechecker__typechecker__TypeChecker__resolve_type(self, mn.as_data.field.ty);
            } else {
              if (mn.as_data.variant.value != ast__ast__NODE_NONE) {
                const uint32_t vt = typechecker__typechecker__TypeChecker__check_expr(self, mn.as_data.variant.value);
                if ((vt != ast__ast__TYPE_NONE) && (!typechecker__typechecker__TypeChecker__is_int(self, vt))) {
                  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), mn.as_data.variant.value)->span;
                  utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc297 = String__Global__new();
String__Global__push_str(&__sc297, (str){ .ptr = (const uint8_t*)"enum discriminant must be an integer", .len = sizeof("enum discriminant must be an integer") - 1 });
__sc297; }));
                }
              }
              const ast__ast__NodeList payload = mn.as_data.variant.payload;
              for (uint32_t j = 0U; j < payload.len; j++) {
                const uint32_t plid = ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), payload)[((size_t)j)];
                const ast__ast__Node *const pe = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), plid);
                typechecker__typechecker__TypeChecker__resolve_type(self, typechecker__typechecker__if_node((pe->kind == ast__ast__NodeKind_NODE_FIELD), pe->as_data.field.ty, plid));
              }
            }
          }
        }
        if ((agg.generics.len == 0U) && typechecker__typechecker__TypeChecker__tc_embeds_by_value(self, self->ast.module, id, self->ast.module, id, 0)) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc298 = String__Global__new();
String__Global__push_str(&__sc298, (str){ .ptr = (const uint8_t*)"this type embeds itself by value, so it would have infinite size", .len = sizeof("this type embeds itself by value, so it would have infinite size") - 1 });
__sc298; }));
          utils__errors__Errors__note(&self->errors, ({ String__Global __sc299 = String__Global__new();
String__Global__push_str(&__sc299, (str){ .ptr = (const uint8_t*)"break the cycle with a pointer ('*mut T'), a reference, or 'Box<T>'", .len = sizeof("break the cycle with a pointer ('*mut T'), a reference, or 'Box<T>'") - 1 });
__sc299; }));
        }
      }
    }
    else if (__sc294 == ast__ast__NodeKind_NODE_INTERFACE) {
      {
        typechecker__typechecker__TypeChecker__check_associated(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.interface_def.items);
      }
    }
    else if (__sc294 == ast__ast__NodeKind_NODE_EXTEND) {
      {
        const uint32_t saved = self->current_self;
        const uint32_t saved_impl = self->current_extend;
        (self->current_self = ast__ast__Ast__resolution(&((*a)), ast__ast__Ast__at_const(&((*a)), id)->as_data.extend_def.target_type));
        (self->current_extend = id);
        if (ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.extend_def.interface_type != ast__ast__NODE_NONE) {
          typechecker__typechecker__TypeChecker__check_extend_conformance(self, id);
        }
        typechecker__typechecker__TypeChecker__check_associated(self, ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.extend_def.items);
        (self->current_self = saved);
        (self->current_extend = saved_impl);
      }
    }
    else if (__sc294 == ast__ast__NodeKind_NODE_CONST) {
      {
        const uint32_t declared = typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.const_def.ty);
        const ast__ast__ConstData cd = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->as_data.const_def;
        if (cd.value != ast__ast__NODE_NONE) {
          typechecker__typechecker__TypeChecker__check_expr(self, cd.value);
          if (!typechecker__typechecker__TypeChecker__compatible(self, declared, cd.value)) {
            typechecker__typechecker__TypeChecker__err_mismatch(self, cd.value, declared);
          }
        }
        if (cd.is_static_mut && typechecker__typechecker__TypeChecker__tc_type_is_free(self, declared)) {
          const lexer__token__Span sp = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), id)->span;
          utils__errors__Errors__emit(&self->errors, sp.start, (sp.end - sp.start), ({ String__Global __sc300 = String__Global__new();
String__Global__push_str(&__sc300, (str){ .ptr = (const uint8_t*)"a 'static mut' cannot hold an owning (Free) type", .len = sizeof("a 'static mut' cannot hold an owning (Free) type") - 1 });
__sc300; }));
          utils__errors__Errors__note(&self->errors, ({ String__Global __sc301 = String__Global__new();
String__Global__push_str(&__sc301, (str){ .ptr = (const uint8_t*)"no scope ever frees a global; store a scalar/view or manage the value locally", .len = sizeof("no scope ever frees a global; store a scalar/view or manage the value locally") - 1 });
__sc301; }));
        }
      }
    }
    else if (__sc294 == ast__ast__NodeKind_NODE_TYPE_ALIAS) {
      {
        (void)(typechecker__typechecker__TypeChecker__resolve_type(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.type_alias.ty));
      }
    }
    else if (__sc294 == ast__ast__NodeKind_NODE_EXTERN_BLOCK) {
      {
        typechecker__typechecker__TypeChecker__check_associated(self, ast__ast__Ast__at_const(&((*a)), id)->as_data.extern_block.items);
      }
    }
    else if (1) {
      {
      }
    }
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__check_associated(typechecker__typechecker__TypeChecker *const self, ast__ast__NodeList const items) {
  for (uint32_t i = 0U; i < items.len; i++) {
    typechecker__typechecker__TypeChecker__check_item(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), items)[((size_t)i)]);
  }
}

static __attribute__((unused)) void typechecker__typechecker__TypeChecker__close_instances(typechecker__typechecker__TypeChecker *const self) {
  size_t ii = 0ULL;
  while (ii < Vector__ast__ast__TyInstance__Global__len(&(*typechecker__typechecker__TypeChecker__cur_ast(self)).instances)) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), ((uint32_t)ii)));
    bool concrete = true;
    for (uint8_t k = 0U; k < it.n; k++) {
      if (!ast__ast__Ast__type_concrete(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), it.args[((size_t)k)])) {
        (concrete = false);
      }
    }
    if (!concrete) {
      (ii = (ii + 1ULL));
      continue;
    }
    ast__ast__Ast *const ma = typechecker__typechecker__TypeChecker__mod_ast(self, it.module);
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*ma)), (*ma).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*ma)), items)[((size_t)i)];
      const ast__ast__Node *const itn = ast__ast__Ast__at_const(&((*ma)), iid);
      if (((itn->kind == ast__ast__NodeKind_NODE_EXTEND) && (itn->as_data.extend_def.generics.len != 0U)) && (ast__ast__Ast__resolution(&((*ma)), itn->as_data.extend_def.target_type) == it.decl)) {
        const ast__ast__NodeList gens = itn->as_data.extend_def.generics;
        typechecker__typechecker__Defs4 ip = (typechecker__typechecker__Defs4){0};
        typechecker__typechecker__Tys4 ia = (typechecker__typechecker__Tys4){0};
        int32_t ipn = 0;
        uint32_t g = 0U;
        while (((g < gens.len) && (((uint8_t)g) < it.n)) && (ipn < 4)) {
          (ip.d[((size_t)ipn)] = (ast__ast__DefId){ .module = it.module, .node = ast__ast__Ast__list(&((*ma)), gens)[((size_t)g)] });
          (ia.t[((size_t)ipn)] = it.args[((size_t)g)]);
          (ipn = ({ int32_t __sc_r; if (__builtin_add_overflow(ipn, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
          (g = (g + 1U));
        }
        const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*ma)), iid)->as_data.extend_def.items;
        for (uint32_t j = 0U; j < ms.len; j++) {
          const uint32_t mid = ast__ast__Ast__list(&((*ma)), ms)[((size_t)j)];
          const ast__ast__Node *const mn = ast__ast__Ast__at_const(&((*ma)), mid);
          if ((mn->kind == ast__ast__NodeKind_NODE_FUNCTION) && (mn->as_data.function.generics.len == 0U)) {
            const ast__ast__NodeList ps = mn->as_data.function.params;
            for (uint32_t p = 0U; p < ps.len; p++) {
              const uint32_t pid = ast__ast__Ast__list(&((*ma)), ps)[((size_t)p)];
              typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, it.module, ast__ast__Ast__at_const(&((*ma)), pid)->as_data.parameter.ty), ((const ast__ast__DefId *)(&ip.d[0])), ((const uint32_t *)(&ia.t[0])), ipn);
            }
            const ast__ast__NodeList rs = mn->as_data.function.returns;
            if (rs.len == 1U) {
              const uint32_t r0 = ast__ast__Ast__list(&((*ma)), rs)[0];
              const ast__ast__Node *const rn = ast__ast__Ast__at_const(&((*ma)), r0);
              typechecker__typechecker__TypeChecker__subst_type(self, typechecker__typechecker__TypeChecker__lower_type_in(self, it.module, typechecker__typechecker__if_node((rn->kind == ast__ast__NodeKind_NODE_PARAMETER), rn->as_data.parameter.ty, r0)), ((const ast__ast__DefId *)(&ip.d[0])), ((const uint32_t *)(&ia.t[0])), ipn);
            }
          }
        }
      }
    }
    (ii = (ii + 1ULL));
  }
}

void typechecker__typechecker__TypeChecker__check(typechecker__typechecker__TypeChecker *const self) {
  ast__ast__Ast__init_types(&((*typechecker__typechecker__TypeChecker__cur_ast(self))));
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), (*typechecker__typechecker__TypeChecker__cur_ast(self)).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    typechecker__typechecker__TypeChecker__check_item(self, ast__ast__Ast__list(&((*typechecker__typechecker__TypeChecker__cur_ast(self))), items)[((size_t)i)]);
  }
  typechecker__typechecker__TypeChecker__close_instances(self);
  const char *file = NULL;
  if ((self->package != NULL) && (((size_t)self->ast.module) < typechecker__typechecker__TypeChecker__pkg_count(self))) {
    (file = String__Global__cstr(&(*({ __auto_type __sc302 = &(*self->package).modules; Vector__module__loader__Module__Global__index_mut(__sc302, ((size_t)self->ast.module)); })).file));
  }
  utils__errors__Errors__finalize(&self->errors, self->source, self->len, file);
}

bool typechecker__typechecker__TypeChecker__has_errors(const typechecker__typechecker__TypeChecker *const self) {
  return utils__errors__Errors__has_errors(&self->errors);
}

void typechecker__typechecker__TypeChecker__log_errors(const typechecker__typechecker__TypeChecker *const self) {
  utils__errors__Errors__log(&self->errors);
}

void typechecker__typechecker__TypeChecker__free(typechecker__typechecker__TypeChecker *const self) {
  Vector__u16__Global__free(&self->ext_scope);
  Vector__Vector__u32__Global__Global__free(&self->ext_items);
  Vector__bool__Global__free(&self->ext_items_built);
  Map__u32__u32__Global__free(&self->binding_depth);
  utils__errors__Errors__free(&self->errors);
  ast__ast__Ast__free(&self->ast);
}

static __attribute__((unused)) bool typechecker__typechecker__if_bool(bool const c, bool const a, bool const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) uint32_t typechecker__typechecker__if_u32(bool const c, uint32_t const a, uint32_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) ast__ast__NodeList typechecker__typechecker__if_nl(bool const c, ast__ast__NodeList const a, ast__ast__NodeList const b) {
  if (c) {
    return a;
  }
  return b;
}

