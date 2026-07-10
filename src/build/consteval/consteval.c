#include "../consteval/consteval.h"
#include "../stdlib.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../ast/ast.h"
#include "../module/loader.h"
#include "../utils/errors.h"
#include "../math.h"
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

_Static_assert(sizeof(consteval__consteval__ConstValueAs) == 8 && _Alignof(consteval__consteval__ConstValueAs) == 8, "super-c layout model mismatch: consteval__consteval__ConstValueAs");
_Static_assert(sizeof(consteval__consteval__ConstValue) == 16 && _Alignof(consteval__consteval__ConstValue) == 8, "super-c layout model mismatch: consteval__consteval__ConstValue");
_Static_assert(sizeof(consteval__consteval__CvPtr) == 8 && _Alignof(consteval__consteval__CvPtr) == 4, "super-c layout model mismatch: consteval__consteval__CvPtr");
_Static_assert(sizeof(consteval__consteval__CvFn) == 8 && _Alignof(consteval__consteval__CvFn) == 4, "super-c layout model mismatch: consteval__consteval__CvFn");
_Static_assert(sizeof(consteval__consteval__CeValAs) == 8 && _Alignof(consteval__consteval__CeValAs) == 8, "super-c layout model mismatch: consteval__consteval__CeValAs");
_Static_assert(sizeof(consteval__consteval__CeVal) == 16 && _Alignof(consteval__consteval__CeVal) == 8, "super-c layout model mismatch: consteval__consteval__CeVal");
_Static_assert(sizeof(consteval__consteval__CePending) == 8 && _Alignof(consteval__consteval__CePending) == 4, "super-c layout model mismatch: consteval__consteval__CePending");
_Static_assert(sizeof(consteval__consteval__Buf64) == 64 && _Alignof(consteval__consteval__Buf64) == 1, "super-c layout model mismatch: consteval__consteval__Buf64");
_Static_assert(sizeof(consteval__consteval__Buf24) == 24 && _Alignof(consteval__consteval__Buf24) == 1, "super-c layout model mismatch: consteval__consteval__Buf24");
_Static_assert(sizeof(consteval__consteval__Buf4096) == 4096 && _Alignof(consteval__consteval__Buf4096) == 1, "super-c layout model mismatch: consteval__consteval__Buf4096");
_Static_assert(sizeof(consteval__consteval__LayoutEnv) == 48 && _Alignof(consteval__consteval__LayoutEnv) == 8, "super-c layout model mismatch: consteval__consteval__LayoutEnv");
_Static_assert(sizeof(consteval__consteval__LayoutAcc) == 24 && _Alignof(consteval__consteval__LayoutAcc) == 8, "super-c layout model mismatch: consteval__consteval__LayoutAcc");
_Static_assert(sizeof(consteval__consteval__CeObj) == 88 && _Alignof(consteval__consteval__CeObj) == 8, "super-c layout model mismatch: consteval__consteval__CeObj");
_Static_assert(sizeof(consteval__consteval__CeRecv) == 40 && _Alignof(consteval__consteval__CeRecv) == 4, "super-c layout model mismatch: consteval__consteval__CeRecv");
_Static_assert(sizeof(consteval__consteval__CeLocal) == 8 && _Alignof(consteval__consteval__CeLocal) == 4, "super-c layout model mismatch: consteval__consteval__CeLocal");
_Static_assert(sizeof(consteval__consteval__CeFrame) == 1096 && _Alignof(consteval__consteval__CeFrame) == 8, "super-c layout model mismatch: consteval__consteval__CeFrame");
_Static_assert(sizeof(consteval__consteval__CeCallKey) == 88 && _Alignof(consteval__consteval__CeCallKey) == 8, "super-c layout model mismatch: consteval__consteval__CeCallKey");
_Static_assert(sizeof(consteval__consteval__CeCallHit) == 136 && _Alignof(consteval__consteval__CeCallHit) == 8, "super-c layout model mismatch: consteval__consteval__CeCallHit");
_Static_assert(sizeof(consteval__consteval__UFree) == 12 && _Alignof(consteval__consteval__UFree) == 4, "super-c layout model mismatch: consteval__consteval__UFree");
_Static_assert(sizeof(consteval__consteval__ConstEval) == 200 && _Alignof(consteval__consteval__ConstEval) == 8, "super-c layout model mismatch: consteval__consteval__ConstEval");
_Static_assert(sizeof(consteval__consteval__Layout) == 24 && _Alignof(consteval__consteval__Layout) == 8, "super-c layout model mismatch: consteval__consteval__Layout");
_Static_assert(sizeof(consteval__consteval__RType) == 8 && _Alignof(consteval__consteval__RType) == 4, "super-c layout model mismatch: consteval__consteval__RType");
_Static_assert(sizeof(consteval__consteval__RecvRes) == 44 && _Alignof(consteval__consteval__RecvRes) == 4, "super-c layout model mismatch: consteval__consteval__RecvRes");
_Static_assert(sizeof(consteval__consteval__ValRes) == 24 && _Alignof(consteval__consteval__ValRes) == 8, "super-c layout model mismatch: consteval__consteval__ValRes");
_Static_assert(sizeof(consteval__consteval__ObjRes) == 8 && _Alignof(consteval__consteval__ObjRes) == 4, "super-c layout model mismatch: consteval__consteval__ObjRes");
_Static_assert(sizeof(consteval__consteval__Rets) == 136 && _Alignof(consteval__consteval__Rets) == 8, "super-c layout model mismatch: consteval__consteval__Rets");
_Static_assert(sizeof(consteval__consteval__FieldIdx) == 8 && _Alignof(consteval__consteval__FieldIdx) == 4, "super-c layout model mismatch: consteval__consteval__FieldIdx");
_Static_assert(sizeof(consteval__consteval__VarPos) == 8 && _Alignof(consteval__consteval__VarPos) == 4, "super-c layout model mismatch: consteval__consteval__VarPos");
_Static_assert(sizeof(consteval__consteval__OvfRes) == 16 && _Alignof(consteval__consteval__OvfRes) == 8, "super-c layout model mismatch: consteval__consteval__OvfRes");
_Static_assert(sizeof(consteval__consteval__DblRes) == 16 && _Alignof(consteval__consteval__DblRes) == 8, "super-c layout model mismatch: consteval__consteval__DblRes");

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__cv_nil(void);
static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ce_none(void);
static __attribute__((unused)) consteval__consteval__CeRecv consteval__consteval__ce_recv_zero(void);
static __attribute__((unused)) consteval__consteval__CeFrame consteval__consteval__ce_frame_zero(void);
static __attribute__((unused)) bool consteval__consteval__bt_signed(ast__ast__BuiltinType const b);
static __attribute__((unused)) bool consteval__consteval__bt_unsigned(ast__ast__BuiltinType const b);
static __attribute__((unused)) int32_t consteval__consteval__bt_bits(ast__ast__BuiltinType const b);
static __attribute__((unused)) int64_t consteval__consteval__wrap_to(ast__ast__BuiltinType const b, int64_t const v);
static __attribute__((unused)) bool consteval__consteval__fits(ast__ast__BuiltinType const b, int64_t const v);
static __attribute__((unused)) bool consteval__consteval__ce_isfinite(double const x);
static __attribute__((unused)) consteval__consteval__OvfRes consteval__consteval__add_ovf(int64_t const a, int64_t const b);
static __attribute__((unused)) consteval__consteval__OvfRes consteval__consteval__sub_ovf(int64_t const a, int64_t const b);
static __attribute__((unused)) consteval__consteval__OvfRes consteval__consteval__mul_ovf(int64_t const a, int64_t const b);
static __attribute__((unused)) const ast__ast__Ast *consteval__consteval__ConstEval__ast_ptr(const consteval__consteval__ConstEval *const self, uint16_t const m);
static __attribute__((unused)) ast__ast__Ast *consteval__consteval__ConstEval__mut_ast_ptr(const consteval__consteval__ConstEval *const self, uint16_t const m);
static __attribute__((unused)) bool consteval__consteval__ConstEval__has_ast(const consteval__consteval__ConstEval *const self, uint16_t const m);
static __attribute__((unused)) const uint8_t *consteval__consteval__ConstEval__ce_src(const consteval__consteval__ConstEval *const self, uint16_t const m);
static __attribute__((unused)) bool consteval__consteval__ConstEval__is_prelude(const consteval__consteval__ConstEval *const self, uint16_t const m);
static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_type(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id);
static __attribute__((cold, noinline, unused)) void consteval__consteval__ConstEval__ce_trap(consteval__consteval__ConstEval *const self, str const msg);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_tick(consteval__consteval__ConstEval *const self);
static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__slot_get(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id);
static __attribute__((unused)) void consteval__consteval__ConstEval__slot_set(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id, consteval__consteval__ConstValue const v);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_spans_eq(const consteval__consteval__ConstEval *const self, uint16_t const ma, lexer__token__Span const a, uint16_t const mb, lexer__token__Span const b);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_span_is(const consteval__consteval__ConstEval *const self, uint16_t const m, lexer__token__Span const s, str const lit);
static __attribute__((unused)) lexer__token__Span consteval__consteval__ConstEval__name_text(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const name_node);
static __attribute__((unused)) uint32_t consteval__consteval__if_default_steps(uint32_t const s);
static __attribute__((unused)) uint64_t consteval__consteval__if_default_slots(uint64_t const b);
static __attribute__((unused)) ast__ast__BuiltinType consteval__consteval__type_builtin(const ast__ast__Ast *const a, uint32_t const t);
static __attribute__((unused)) uint64_t consteval__consteval__round_up(uint64_t const v, uint64_t const a);
static __attribute__((unused)) int32_t consteval__consteval__hexval(uint8_t const ch);
static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__eval_int_literal(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__eval_char_literal(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__eval_float_literal(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id);
static __attribute__((unused)) const ast__ast__Attr *consteval__consteval__ConstEval__ce_attr(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const owner, ast__ast__AttrKind const kind);
static __attribute__((unused)) bool consteval__consteval__ConstEval__acc_field(consteval__consteval__ConstEval *const self, consteval__consteval__LayoutAcc *const acc, uint16_t const m, uint32_t const ft, const consteval__consteval__LayoutEnv *const env, int32_t const depth);
static __attribute__((unused)) consteval__consteval__Layout consteval__consteval__ConstEval__aggregate_layout(consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn, const consteval__consteval__LayoutEnv *const env, int32_t const depth);
static __attribute__((unused)) consteval__consteval__Layout consteval__consteval__ConstEval__layout_of(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const t, const consteval__consteval__LayoutEnv *const env, int32_t const depth);
static __attribute__((unused)) consteval__consteval__RType consteval__consteval__ConstEval__ce_rtype(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m0, uint32_t const t0);
static __attribute__((unused)) ast__ast__BuiltinType consteval__consteval__ConstEval__ce_builtin_of(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const t);
static __attribute__((unused)) consteval__consteval__Layout consteval__consteval__ConstEval__ce_layout_f(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const t);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_teq(const consteval__consteval__ConstEval *const self, uint16_t const ma, uint32_t const ta, uint16_t const mb, uint32_t const tb);
static __attribute__((unused)) consteval__consteval__RType consteval__consteval__ConstEval__ce_strip_refptr(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m0, uint32_t const t0);
static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_subst_deep(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const t, int32_t const depth);
static __attribute__((unused)) consteval__consteval__RecvRes consteval__consteval__ConstEval__ce_recv_of(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m0, uint32_t const t0);
static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_field_count(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn);
static __attribute__((unused)) consteval__consteval__FieldIdx consteval__consteval__ConstEval__ce_field_index(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn, uint16_t const nm, lexer__token__Span const name);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_enum_tagged(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn);
static __attribute__((unused)) consteval__consteval__VarPos consteval__consteval__ConstEval__ce_variant_pos(const consteval__consteval__ConstEval *const self, uint16_t const vm, uint32_t const vd);
static __attribute__((unused)) int32_t consteval__consteval__ConstEval__ce_variant_named(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn, str const lit);
static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_pool_find_type(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn);
static __attribute__((unused)) int32_t consteval__consteval__ConstEval__ce_container_of(const consteval__consteval__ConstEval *const self, uint16_t const fm, uint32_t const fnode, uint32_t *const out);
static __attribute__((unused)) ast__ast__DefId consteval__consteval__ConstEval__ce_find_method(const consteval__consteval__ConstEval *const self, consteval__consteval__CeRecv const r, uint16_t const scope, uint16_t const nm, lexer__token__Span const name, str const lit, uint32_t *const extend_out);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_user_free(consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn);
static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__variant_value(consteval__consteval__ConstEval *const self, uint16_t const vm, uint32_t const vd);
static __attribute__((unused)) void consteval__consteval__ConstEval__ce_objs_reset(consteval__consteval__ConstEval *const self);
static __attribute__((unused)) consteval__consteval__CeObj *consteval__consteval__ConstEval__obj_ptr(const consteval__consteval__ConstEval *const self, uint32_t const id);
static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_obj_new(consteval__consteval__ConstEval *const self, uint32_t const len);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_obj_resize(consteval__consteval__ConstEval *const self, uint32_t const id, uint32_t const len);
static __attribute__((unused)) consteval__consteval__CeVal *consteval__consteval__ConstEval__ce_bind_slot(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint32_t const decl);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_bind(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint32_t const decl, consteval__consteval__CeVal const v);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_clone(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const v, int32_t const depth);
static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ce_loadp(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const p);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_storep(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const p, consteval__consteval__CeVal const v);
static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ce_temp_place(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const v);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_zero(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const t, int32_t const depth);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_int_op(consteval__consteval__ConstEval *const self, lexer__token_type__TokenType const op, consteval__consteval__CeVal const l, consteval__consteval__CeVal const r, uint16_t const tm, uint32_t const rt, ast__ast__BuiltinType const b, ast__ast__BuiltinType const ob);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__eval_str_literal(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) int32_t consteval__consteval__ce_local_find(consteval__consteval__CeFrame *const f, uint32_t const decl);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__cv_bool(uint16_t const tm, uint32_t const rt, bool const b);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ce_float_op(lexer__token_type__TokenType const op, consteval__consteval__CeVal const l, consteval__consteval__CeVal const r, uint16_t const tm, uint32_t const rt, ast__ast__BuiltinType const b);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__cv_scalar_of(consteval__consteval__ConstValue const v, uint16_t const m);
static __attribute__((unused)) ast__ast__BuiltinType consteval__consteval__ce_arith_common(ast__ast__BuiltinType const a, ast__ast__BuiltinType const b);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_range_decl(const consteval__consteval__ConstEval *const self, uint16_t *const dm, uint32_t *const dn);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_range_obj(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_in(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_rval(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_coerce(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const v, uint16_t const wm, uint32_t const wt);
static __attribute__((unused)) consteval__consteval__ObjRes consteval__consteval__ConstEval__ce_base_obj(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ev_place(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id0);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_unary(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_cast(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_binary(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) int64_t consteval__consteval__if_i64(bool const c, int64_t const a, int64_t const b);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_block(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_index(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_struct_init(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_array_lit(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_tuple(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) int32_t consteval__consteval__ConstEval__pat_match(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const pid, consteval__consteval__CeVal const v, bool const uns, uint32_t const refobj);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_match(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id, consteval__consteval__CeVal *const out);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_assign(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_expr_stmt(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id0);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_stmt(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_let(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_while(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_for(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) int32_t consteval__consteval__if_i32(bool const c, int32_t const a, int32_t const b);
static __attribute__((unused)) bool consteval__consteval__if_bool(bool const c, bool const a, bool const b);
static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__xfail(consteval__consteval__CeFrame *const f);
static __attribute__((unused)) lexer__token_type__TokenType consteval__consteval__compound_op(lexer__token_type__TokenType const op);
static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__cv_pub(consteval__consteval__CeVal const v);
static __attribute__((unused)) bool consteval__consteval__cv_is_scalar(consteval__consteval__CeVal const v);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_subst_add(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const g, uint16_t const pmod, uint32_t const param, uint16_t const am, uint32_t const at);
static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_bind_extend(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const g, uint16_t const xm, uint32_t const extnode, const consteval__consteval__CeRecv *const recv);
static __attribute__((unused)) consteval__consteval__Rets consteval__consteval__ConstEval__ce_intercept(consteval__consteval__ConstEval *const self, uint16_t const fm, uint32_t const fnode, const consteval__consteval__CeVal *const args, uint32_t const nargs, uint16_t const m, uint32_t const callId);
static __attribute__((unused)) consteval__consteval__Rets consteval__consteval__ConstEval__ce_invoke(consteval__consteval__ConstEval *const self, uint16_t const fm, uint32_t const fnode, uint32_t const extend_node, const consteval__consteval__CeRecv *const recv, const uint16_t *const monom, const uint32_t *const monot, uint8_t const nmono, const consteval__consteval__CeVal *const args, uint32_t const nargs, uint16_t const self_pm, uint32_t const self_decl, uint16_t const self_am, uint32_t const self_at);
static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ce_dispatch(consteval__consteval__ConstEval *const self, consteval__consteval__CeRecv const r, uint16_t const scope, str const lit, const consteval__consteval__CeVal *const args, uint32_t const nargs);
static __attribute__((unused)) consteval__consteval__Rets consteval__consteval__ConstEval__ce_call(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id);
static __attribute__((unused)) consteval__consteval__DblRes consteval__consteval__libm1(str const name, double const x);
static __attribute__((unused)) consteval__consteval__DblRes consteval__consteval__libm2(str const name, double const x, double const y);
static __attribute__((unused)) size_t Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__slot(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key);
static __attribute__((unused)) void Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__grow(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self);

Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__new_in(Global const alloc) {
  return (Vector__consteval__consteval__CeVal__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__consteval__consteval__CeVal__Global v = (Vector__consteval__consteval__CeVal__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((consteval__consteval__CeVal *)Global__alloc(&v.alloc, (cap * sizeof(consteval__consteval__CeVal)), _Alignof(consteval__consteval__CeVal))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__consteval__consteval__CeVal__Global__len(const Vector__consteval__consteval__CeVal__Global *const self) {
  return self->len;
}

void Vector__consteval__consteval__CeVal__Global__reserve(Vector__consteval__consteval__CeVal__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  consteval__consteval__CeVal *const p = ((consteval__consteval__CeVal *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__CeVal)), (new_cap * sizeof(consteval__consteval__CeVal)), _Alignof(consteval__consteval__CeVal)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__consteval__consteval__CeVal__Global__push(Vector__consteval__consteval__CeVal__Global *const self, consteval__consteval__CeVal const value) {
  Vector__consteval__consteval__CeVal__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__at(const Vector__consteval__consteval__CeVal__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_consteval__consteval__CeVal Vector__consteval__consteval__CeVal__Global__get(const Vector__consteval__consteval__CeVal__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_consteval__consteval__CeVal){ .tag = Option_None };
  }
  return (Option__ptr_consteval__consteval__CeVal){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__consteval__consteval__CeVal__Global__set(Vector__consteval__consteval__CeVal__Global *const self, size_t const index, consteval__consteval__CeVal const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__consteval__consteval__CeVal__Global__clear(Vector__consteval__consteval__CeVal__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__consteval__consteval__CeVal__Global__truncate(Vector__consteval__consteval__CeVal__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__as_ptr(const Vector__consteval__consteval__CeVal__Global *const self) {
  return self->ptr;
}

void Vector__consteval__consteval__CeVal__Global__swap(Vector__consteval__consteval__CeVal__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__new(void) {
  return Vector__consteval__consteval__CeVal__Global__new_in(Global__default_());
}

void Vector__consteval__consteval__CeVal__Global__free(Vector__consteval__consteval__CeVal__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__CeVal)), _Alignof(consteval__consteval__CeVal));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__default_(void) {
  return Vector__consteval__consteval__CeVal__Global__new();
}

const consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__index(const Vector__consteval__consteval__CeVal__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CeVal Vector__consteval__consteval__CeVal__Global__index_range(const Vector__consteval__consteval__CeVal__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__consteval__consteval__CeVal){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__index_mut(Vector__consteval__consteval__CeVal__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__CeVal Vector__consteval__consteval__CeVal__Global__index_range_mut(Vector__consteval__consteval__CeVal__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (SliceMut__consteval__consteval__CeVal){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__new_in(Global const alloc) {
  return (Vector__consteval__consteval__ConstValue__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__consteval__consteval__ConstValue__Global v = (Vector__consteval__consteval__ConstValue__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((consteval__consteval__ConstValue *)Global__alloc(&v.alloc, (cap * sizeof(consteval__consteval__ConstValue)), _Alignof(consteval__consteval__ConstValue))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__consteval__consteval__ConstValue__Global__len(const Vector__consteval__consteval__ConstValue__Global *const self) {
  return self->len;
}

void Vector__consteval__consteval__ConstValue__Global__reserve(Vector__consteval__consteval__ConstValue__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  consteval__consteval__ConstValue *const p = ((consteval__consteval__ConstValue *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__ConstValue)), (new_cap * sizeof(consteval__consteval__ConstValue)), _Alignof(consteval__consteval__ConstValue)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__consteval__consteval__ConstValue__Global__push(Vector__consteval__consteval__ConstValue__Global *const self, consteval__consteval__ConstValue const value) {
  Vector__consteval__consteval__ConstValue__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__at(const Vector__consteval__consteval__ConstValue__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_consteval__consteval__ConstValue Vector__consteval__consteval__ConstValue__Global__get(const Vector__consteval__consteval__ConstValue__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_consteval__consteval__ConstValue){ .tag = Option_None };
  }
  return (Option__ptr_consteval__consteval__ConstValue){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__consteval__consteval__ConstValue__Global__set(Vector__consteval__consteval__ConstValue__Global *const self, size_t const index, consteval__consteval__ConstValue const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__consteval__consteval__ConstValue__Global__clear(Vector__consteval__consteval__ConstValue__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__consteval__consteval__ConstValue__Global__truncate(Vector__consteval__consteval__ConstValue__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__as_ptr(const Vector__consteval__consteval__ConstValue__Global *const self) {
  return self->ptr;
}

void Vector__consteval__consteval__ConstValue__Global__swap(Vector__consteval__consteval__ConstValue__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__new(void) {
  return Vector__consteval__consteval__ConstValue__Global__new_in(Global__default_());
}

void Vector__consteval__consteval__ConstValue__Global__free(Vector__consteval__consteval__ConstValue__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__ConstValue)), _Alignof(consteval__consteval__ConstValue));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__default_(void) {
  return Vector__consteval__consteval__ConstValue__Global__new();
}

const consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__index(const Vector__consteval__consteval__ConstValue__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__ConstValue Vector__consteval__consteval__ConstValue__Global__index_range(const Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc2;
    if (r.inclusive) {
      __sc2 = (r.end + 1ULL);
    } else {
      __sc2 = r.end;
    }
    __sc2;
  });
  return (Slice__consteval__consteval__ConstValue){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__index_mut(Vector__consteval__consteval__ConstValue__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__ConstValue Vector__consteval__consteval__ConstValue__Global__index_range_mut(Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc3;
    if (r.inclusive) {
      __sc3 = (r.end + 1ULL);
    } else {
      __sc3 = r.end;
    }
    __sc3;
  });
  return (SliceMut__consteval__consteval__ConstValue){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__new_in(Global const alloc) {
  return (Vector__Vector__consteval__consteval__ConstValue__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__Vector__consteval__consteval__ConstValue__Global__Global v = (Vector__Vector__consteval__consteval__ConstValue__Global__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((Vector__consteval__consteval__ConstValue__Global *)Global__alloc(&v.alloc, (cap * sizeof(Vector__consteval__consteval__ConstValue__Global)), _Alignof(Vector__consteval__consteval__ConstValue__Global))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__Vector__consteval__consteval__ConstValue__Global__Global__len(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self) {
  return self->len;
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__reserve(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  Vector__consteval__consteval__ConstValue__Global *const p = ((Vector__consteval__consteval__ConstValue__Global *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__consteval__consteval__ConstValue__Global)), (new_cap * sizeof(Vector__consteval__consteval__ConstValue__Global)), _Alignof(Vector__consteval__consteval__ConstValue__Global)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__push(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, Vector__consteval__consteval__ConstValue__Global value) {
  Vector__Vector__consteval__consteval__ConstValue__Global__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__at(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_Vector__consteval__consteval__ConstValue__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__get(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_Vector__consteval__consteval__ConstValue__Global){ .tag = Option_None };
  }
  return (Option__ptr_Vector__consteval__consteval__ConstValue__Global){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__set(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const index, Vector__consteval__consteval__ConstValue__Global value) {
  Vector__consteval__consteval__ConstValue__Global__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__clear(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__consteval__consteval__ConstValue__Global__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__truncate(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      Vector__consteval__consteval__ConstValue__Global__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__as_ptr(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self) {
  return self->ptr;
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__swap(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__new(void) {
  return Vector__Vector__consteval__consteval__ConstValue__Global__Global__new_in(Global__default_());
}

void Vector__Vector__consteval__consteval__ConstValue__Global__Global__free(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    Vector__consteval__consteval__ConstValue__Global__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(Vector__consteval__consteval__ConstValue__Global)), _Alignof(Vector__consteval__consteval__ConstValue__Global));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__default_(void) {
  return Vector__Vector__consteval__consteval__ConstValue__Global__Global__new();
}

const Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__index(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__consteval__consteval__ConstValue__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_range(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc4;
    if (r.inclusive) {
      __sc4 = (r.end + 1ULL);
    } else {
      __sc4 = r.end;
    }
    __sc4;
  });
  return (Slice__Vector__consteval__consteval__ConstValue__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_mut(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__consteval__consteval__ConstValue__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_range_mut(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc5;
    if (r.inclusive) {
      __sc5 = (r.end + 1ULL);
    } else {
      __sc5 = r.end;
    }
    __sc5;
  });
  return (SliceMut__Vector__consteval__consteval__ConstValue__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__new_in(Global const alloc) {
  return (Vector__consteval__consteval__CeObj__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__consteval__consteval__CeObj__Global v = (Vector__consteval__consteval__CeObj__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((consteval__consteval__CeObj *)Global__alloc(&v.alloc, (cap * sizeof(consteval__consteval__CeObj)), _Alignof(consteval__consteval__CeObj))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__consteval__consteval__CeObj__Global__len(const Vector__consteval__consteval__CeObj__Global *const self) {
  return self->len;
}

void Vector__consteval__consteval__CeObj__Global__reserve(Vector__consteval__consteval__CeObj__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  consteval__consteval__CeObj *const p = ((consteval__consteval__CeObj *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__CeObj)), (new_cap * sizeof(consteval__consteval__CeObj)), _Alignof(consteval__consteval__CeObj)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__consteval__consteval__CeObj__Global__push(Vector__consteval__consteval__CeObj__Global *const self, consteval__consteval__CeObj value) {
  Vector__consteval__consteval__CeObj__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__at(const Vector__consteval__consteval__CeObj__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_consteval__consteval__CeObj Vector__consteval__consteval__CeObj__Global__get(const Vector__consteval__consteval__CeObj__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_consteval__consteval__CeObj){ .tag = Option_None };
  }
  return (Option__ptr_consteval__consteval__CeObj){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__consteval__consteval__CeObj__Global__set(Vector__consteval__consteval__CeObj__Global *const self, size_t const index, consteval__consteval__CeObj value) {
  consteval__consteval__CeObj__free(&self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__consteval__consteval__CeObj__Global__clear(Vector__consteval__consteval__CeObj__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    consteval__consteval__CeObj__free(&self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__consteval__consteval__CeObj__Global__truncate(Vector__consteval__consteval__CeObj__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      consteval__consteval__CeObj__free(&self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__as_ptr(const Vector__consteval__consteval__CeObj__Global *const self) {
  return self->ptr;
}

void Vector__consteval__consteval__CeObj__Global__swap(Vector__consteval__consteval__CeObj__Global *const self, size_t const i, size_t const j) {
  __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__new(void) {
  return Vector__consteval__consteval__CeObj__Global__new_in(Global__default_());
}

void Vector__consteval__consteval__CeObj__Global__free(Vector__consteval__consteval__CeObj__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    consteval__consteval__CeObj__free(&self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__CeObj)), _Alignof(consteval__consteval__CeObj));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__default_(void) {
  return Vector__consteval__consteval__CeObj__Global__new();
}

const consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__index(const Vector__consteval__consteval__CeObj__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CeObj Vector__consteval__consteval__CeObj__Global__index_range(const Vector__consteval__consteval__CeObj__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc6;
    if (r.inclusive) {
      __sc6 = (r.end + 1ULL);
    } else {
      __sc6 = r.end;
    }
    __sc6;
  });
  return (Slice__consteval__consteval__CeObj){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__index_mut(Vector__consteval__consteval__CeObj__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__CeObj Vector__consteval__consteval__CeObj__Global__index_range_mut(Vector__consteval__consteval__CeObj__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc7;
    if (r.inclusive) {
      __sc7 = (r.end + 1ULL);
    } else {
      __sc7 = r.end;
    }
    __sc7;
  });
  return (SliceMut__consteval__consteval__CeObj){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__new_in(Global const alloc) {
  return (Vector__consteval__consteval__CePending__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__consteval__consteval__CePending__Global v = (Vector__consteval__consteval__CePending__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((consteval__consteval__CePending *)Global__alloc(&v.alloc, (cap * sizeof(consteval__consteval__CePending)), _Alignof(consteval__consteval__CePending))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__consteval__consteval__CePending__Global__len(const Vector__consteval__consteval__CePending__Global *const self) {
  return self->len;
}

void Vector__consteval__consteval__CePending__Global__reserve(Vector__consteval__consteval__CePending__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  consteval__consteval__CePending *const p = ((consteval__consteval__CePending *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__CePending)), (new_cap * sizeof(consteval__consteval__CePending)), _Alignof(consteval__consteval__CePending)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__consteval__consteval__CePending__Global__push(Vector__consteval__consteval__CePending__Global *const self, consteval__consteval__CePending const value) {
  Vector__consteval__consteval__CePending__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__at(const Vector__consteval__consteval__CePending__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_consteval__consteval__CePending Vector__consteval__consteval__CePending__Global__get(const Vector__consteval__consteval__CePending__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_consteval__consteval__CePending){ .tag = Option_None };
  }
  return (Option__ptr_consteval__consteval__CePending){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__consteval__consteval__CePending__Global__set(Vector__consteval__consteval__CePending__Global *const self, size_t const index, consteval__consteval__CePending const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__consteval__consteval__CePending__Global__clear(Vector__consteval__consteval__CePending__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__consteval__consteval__CePending__Global__truncate(Vector__consteval__consteval__CePending__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__as_ptr(const Vector__consteval__consteval__CePending__Global *const self) {
  return self->ptr;
}

void Vector__consteval__consteval__CePending__Global__swap(Vector__consteval__consteval__CePending__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__new(void) {
  return Vector__consteval__consteval__CePending__Global__new_in(Global__default_());
}

void Vector__consteval__consteval__CePending__Global__free(Vector__consteval__consteval__CePending__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__CePending)), _Alignof(consteval__consteval__CePending));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__default_(void) {
  return Vector__consteval__consteval__CePending__Global__new();
}

const consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__index(const Vector__consteval__consteval__CePending__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CePending Vector__consteval__consteval__CePending__Global__index_range(const Vector__consteval__consteval__CePending__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc8;
    if (r.inclusive) {
      __sc8 = (r.end + 1ULL);
    } else {
      __sc8 = r.end;
    }
    __sc8;
  });
  return (Slice__consteval__consteval__CePending){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__index_mut(Vector__consteval__consteval__CePending__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__CePending Vector__consteval__consteval__CePending__Global__index_range_mut(Vector__consteval__consteval__CePending__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc9;
    if (r.inclusive) {
      __sc9 = (r.end + 1ULL);
    } else {
      __sc9 = r.end;
    }
    __sc9;
  });
  return (SliceMut__consteval__consteval__CePending){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__new_in(Global const alloc) {
  return (Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global){ .keys = NULL, .vals = NULL, .used = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

size_t Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__len(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self) {
  return self->len;
}

bool Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__is_empty(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self) {
  return (self->len == 0ULL);
}

static __attribute__((unused)) size_t Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__slot(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key) {
  size_t i = ({ size_t __sc10 = ((size_t)consteval__consteval__CeCallKey__hash(key)); size_t __sc11 = self->cap; if (__sc11 == 0) { __sc_panic("divide by zero"); } (__sc10 % __sc11); });
  while (self->used[i] != 0U) {
    if (consteval__consteval__CeCallKey__eq(&self->keys[i], key)) {
      return i;
    }
    (i = (i + 1ULL));
    if (i >= self->cap) {
      (i = 0ULL);
    }
  }
  return i;
}

static __attribute__((unused)) void Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__grow(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self) {
  size_t newcap = (self->cap * 2ULL);
  if (newcap < 8ULL) {
    (newcap = 8ULL);
  }
  consteval__consteval__CeCallKey *const oldkeys = self->keys;
  consteval__consteval__CeCallHit *const oldvals = self->vals;
  uint8_t *const oldused = self->used;
  const size_t oldcap = self->cap;
  (self->keys = ((consteval__consteval__CeCallKey *)Global__alloc(&self->alloc, (newcap * sizeof(consteval__consteval__CeCallKey)), _Alignof(consteval__consteval__CeCallKey))));
  (self->vals = ((consteval__consteval__CeCallHit *)Global__alloc(&self->alloc, (newcap * sizeof(consteval__consteval__CeCallHit)), _Alignof(consteval__consteval__CeCallHit))));
  (self->used = ((uint8_t *)Global__alloc(&self->alloc, newcap, 1ULL)));
  memset(((void *)self->used), 0, newcap);
  (self->cap = newcap);
  (self->len = 0ULL);
  for (size_t i = 0ULL; i < oldcap; i++) {
    if (oldused[i] == 1U) {
      const size_t j = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__slot(self, (&oldkeys[i]));
      (self->keys[j] = oldkeys[i]);
      (self->vals[j] = oldvals[i]);
      (self->used[j] = 1U);
      (self->len = (self->len + 1ULL));
    }
  }
  if (oldcap > 0ULL) {
    Global__dealloc(&self->alloc, ((void *)oldkeys), (oldcap * sizeof(consteval__consteval__CeCallKey)), _Alignof(consteval__consteval__CeCallKey));
    Global__dealloc(&self->alloc, ((void *)oldvals), (oldcap * sizeof(consteval__consteval__CeCallHit)), _Alignof(consteval__consteval__CeCallHit));
    Global__dealloc(&self->alloc, ((void *)oldused), oldcap, 1ULL);
  }
}

void Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__insert(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, consteval__consteval__CeCallKey const key, consteval__consteval__CeCallHit const value) {
  if ((self->cap == 0ULL) || (((self->len + 1ULL) * 4ULL) >= (self->cap * 3ULL))) {
    Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__grow(self);
  }
  const size_t i = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__slot(self, (&key));
  if (self->used[i] != 0U) {
    __auto_type dup = key;
    (void)(dup);
    (void)(self->vals[i]);
    (self->vals[i] = value);
    return;
  }
  (self->keys[i] = key);
  (self->vals[i] = value);
  (self->used[i] = 1U);
  (self->len = (self->len + 1ULL));
}

Option__ptr_consteval__consteval__CeCallHit Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__get(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key) {
  if (self->cap == 0ULL) {
    return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_None };
  }
  const size_t i = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_None };
  }
  return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
}

bool Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__contains_key(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key) {
  return ({ __auto_type __sc12 = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__get(self, key); Option__ptr_consteval__consteval__CeCallHit__is_some(&__sc12); });
}

Option__consteval__consteval__CeCallHit Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__remove(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key) {
  if (self->cap == 0ULL) {
    return (Option__consteval__consteval__CeCallHit){ .tag = Option_None };
  }
  const size_t i = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__slot(self, key);
  if (self->used[i] == 0U) {
    return (Option__consteval__consteval__CeCallHit){ .tag = Option_None };
  }
  const __auto_type removed = self->vals[i];
  (void)(self->keys[i]);
  (self->used[i] = 0U);
  (self->len = (self->len - 1ULL));
  size_t j = (i + 1ULL);
  if (j >= self->cap) {
    (j = 0ULL);
  }
  while (self->used[j] == 1U) {
    const __auto_type k = self->keys[j];
    const __auto_type v = self->vals[j];
    (self->used[j] = 0U);
    (self->len = (self->len - 1ULL));
    Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__insert(self, k, v);
    (j = (j + 1ULL));
    if (j >= self->cap) {
      (j = 0ULL);
    }
  }
  return (Option__consteval__consteval__CeCallHit){ .tag = Option_Some, .payload.Some = { removed } };
}

Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__new(void) {
  return Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__new_in(Global__default_());
}

void Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__free(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self) {
  for (size_t i = 0ULL; i < self->cap; i++) {
    if (self->used[i] != 0U) {
      (void)(self->keys[i]);
      (void)(self->vals[i]);
    }
  }
  Global__dealloc(&self->alloc, ((void *)self->keys), (self->cap * sizeof(consteval__consteval__CeCallKey)), _Alignof(consteval__consteval__CeCallKey));
  Global__dealloc(&self->alloc, ((void *)self->vals), (self->cap * sizeof(consteval__consteval__CeCallHit)), _Alignof(consteval__consteval__CeCallHit));
  Global__dealloc(&self->alloc, ((void *)self->used), self->cap, 1ULL);
  (self->keys = NULL);
  (self->vals = NULL);
  (self->used = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

MapKeys__consteval__consteval__CeCallKey Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__keys(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self) {
  return (MapKeys__consteval__consteval__CeCallKey){ .keys = ((const consteval__consteval__CeCallKey *)self->keys), .used = ((const uint8_t *)self->used), .idx = 0ULL, .cap = self->cap };
}

Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__new_in(Global const alloc) {
  return (Vector__consteval__consteval__UFree__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
}

Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__with_capacity_in(Global const alloc, size_t const cap) {
  Vector__consteval__consteval__UFree__Global v = (Vector__consteval__consteval__UFree__Global){ .ptr = NULL, .len = 0ULL, .cap = 0ULL, .alloc = alloc };
  if (cap > 0ULL) {
    (v.ptr = ((consteval__consteval__UFree *)Global__alloc(&v.alloc, (cap * sizeof(consteval__consteval__UFree)), _Alignof(consteval__consteval__UFree))));
    (v.cap = cap);
  }
  return v;
}

size_t Vector__consteval__consteval__UFree__Global__len(const Vector__consteval__consteval__UFree__Global *const self) {
  return self->len;
}

void Vector__consteval__consteval__UFree__Global__reserve(Vector__consteval__consteval__UFree__Global *const self, size_t const additional) {
  const size_t needed = (self->len + additional);
  if (needed <= self->cap) {
    return;
  }
  size_t new_cap = (self->cap * 2ULL);
  if (new_cap == 0ULL) {
    (new_cap = 8ULL);
  }
  if (new_cap < needed) {
    (new_cap = needed);
  }
  consteval__consteval__UFree *const p = ((consteval__consteval__UFree *)Global__realloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__UFree)), (new_cap * sizeof(consteval__consteval__UFree)), _Alignof(consteval__consteval__UFree)));
  (self->ptr = p);
  (self->cap = new_cap);
}

void Vector__consteval__consteval__UFree__Global__push(Vector__consteval__consteval__UFree__Global *const self, consteval__consteval__UFree const value) {
  Vector__consteval__consteval__UFree__Global__reserve(self, 1ULL);
  (self->ptr[self->len] = value);
  (self->len = (self->len + 1ULL));
}

const consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__at(const Vector__consteval__consteval__UFree__Global *const self, size_t const index) {
  return (&self->ptr[index]);
}

Option__ptr_consteval__consteval__UFree Vector__consteval__consteval__UFree__Global__get(const Vector__consteval__consteval__UFree__Global *const self, size_t const index) {
  if (index >= self->len) {
    return (Option__ptr_consteval__consteval__UFree){ .tag = Option_None };
  }
  return (Option__ptr_consteval__consteval__UFree){ .tag = Option_Some, .payload.Some = { (&self->ptr[index]) } };
}

void Vector__consteval__consteval__UFree__Global__set(Vector__consteval__consteval__UFree__Global *const self, size_t const index, consteval__consteval__UFree const value) {
  (void)(self->ptr[index]);
  (self->ptr[index] = value);
}

void Vector__consteval__consteval__UFree__Global__clear(Vector__consteval__consteval__UFree__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  (self->len = 0ULL);
}

void Vector__consteval__consteval__UFree__Global__truncate(Vector__consteval__consteval__UFree__Global *const self, size_t const new_len) {
  if (new_len < self->len) {
    size_t i = new_len;
    while (i < self->len) {
      (void)(self->ptr[i]);
      (i = (i + 1ULL));
    }
    (self->len = new_len);
  }
}

const consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__as_ptr(const Vector__consteval__consteval__UFree__Global *const self) {
  return self->ptr;
}

void Vector__consteval__consteval__UFree__Global__swap(Vector__consteval__consteval__UFree__Global *const self, size_t const i, size_t const j) {
  const __auto_type tmp = self->ptr[i];
  (self->ptr[i] = self->ptr[j]);
  (self->ptr[j] = tmp);
}

Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__new(void) {
  return Vector__consteval__consteval__UFree__Global__new_in(Global__default_());
}

void Vector__consteval__consteval__UFree__Global__free(Vector__consteval__consteval__UFree__Global *const self) {
  for (size_t i = 0ULL; i < self->len; i++) {
    (void)(self->ptr[i]);
  }
  Global__dealloc(&self->alloc, ((void *)self->ptr), (self->cap * sizeof(consteval__consteval__UFree)), _Alignof(consteval__consteval__UFree));
  (self->ptr = NULL);
  (self->len = 0ULL);
  (self->cap = 0ULL);
}

Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__default_(void) {
  return Vector__consteval__consteval__UFree__Global__new();
}

const consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__index(const Vector__consteval__consteval__UFree__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__UFree Vector__consteval__consteval__UFree__Global__index_range(const Vector__consteval__consteval__UFree__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc13;
    if (r.inclusive) {
      __sc13 = (r.end + 1ULL);
    } else {
      __sc13 = r.end;
    }
    __sc13;
  });
  return (Slice__consteval__consteval__UFree){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__index_mut(Vector__consteval__consteval__UFree__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__UFree Vector__consteval__consteval__UFree__Global__index_range_mut(Vector__consteval__consteval__UFree__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc14;
    if (r.inclusive) {
      __sc14 = (r.end + 1ULL);
    } else {
      __sc14 = r.end;
    }
    __sc14;
  });
  return (SliceMut__consteval__consteval__UFree){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit__some(const consteval__consteval__CeCallHit *const value) {
  return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit__none(void) {
  return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__CeCallHit__is_some(const Option__ptr_consteval__consteval__CeCallHit *const self) {
  {
    const Option__ptr_consteval__consteval__CeCallHit *const __sc15 = self;
    if ((*__sc15).tag == Option_Some) {
      return true;
    }
    else if ((*__sc15).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__CeCallHit__is_none(const Option__ptr_consteval__consteval__CeCallHit *const self) {
  {
    const Option__ptr_consteval__consteval__CeCallHit *const __sc16 = self;
    if ((*__sc16).tag == Option_Some) {
      return false;
    }
    else if ((*__sc16).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit__default_(void) {
  return Option__ptr_consteval__consteval__CeCallHit__none();
}

Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal__some(consteval__consteval__CeVal const value) {
  return (Option__consteval__consteval__CeVal){ .tag = Option_Some, .payload.Some = { value } };
}

Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal__none(void) {
  return (Option__consteval__consteval__CeVal){ .tag = Option_None };
}

bool Option__consteval__consteval__CeVal__is_some(const Option__consteval__consteval__CeVal *const self) {
  {
    const Option__consteval__consteval__CeVal *const __sc17 = self;
    if ((*__sc17).tag == Option_Some) {
      return true;
    }
    else if ((*__sc17).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__consteval__consteval__CeVal__is_none(const Option__consteval__consteval__CeVal *const self) {
  {
    const Option__consteval__consteval__CeVal *const __sc18 = self;
    if ((*__sc18).tag == Option_Some) {
      return false;
    }
    else if ((*__sc18).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal__default_(void) {
  return Option__consteval__consteval__CeVal__none();
}

Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal__some(const consteval__consteval__CeVal *const value) {
  return (Option__ptr_consteval__consteval__CeVal){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal__none(void) {
  return (Option__ptr_consteval__consteval__CeVal){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__CeVal__is_some(const Option__ptr_consteval__consteval__CeVal *const self) {
  {
    const Option__ptr_consteval__consteval__CeVal *const __sc19 = self;
    if ((*__sc19).tag == Option_Some) {
      return true;
    }
    else if ((*__sc19).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__CeVal__is_none(const Option__ptr_consteval__consteval__CeVal *const self) {
  {
    const Option__ptr_consteval__consteval__CeVal *const __sc20 = self;
    if ((*__sc20).tag == Option_Some) {
      return false;
    }
    else if ((*__sc20).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal__default_(void) {
  return Option__ptr_consteval__consteval__CeVal__none();
}

Option__ptr_consteval__consteval__CeVal VecIter__consteval__consteval__CeVal__next(VecIter__consteval__consteval__CeVal *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_consteval__consteval__CeVal__none();
  }
  const consteval__consteval__CeVal *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_consteval__consteval__CeVal__some(r);
}

size_t Slice__consteval__consteval__CeVal__len(const Slice__consteval__consteval__CeVal *const self) {
  return self->len;
}

const consteval__consteval__CeVal *Slice__consteval__consteval__CeVal__as_ptr(const Slice__consteval__consteval__CeVal *const self) {
  return self->ptr;
}

const consteval__consteval__CeVal *Slice__consteval__consteval__CeVal__index(const Slice__consteval__consteval__CeVal *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CeVal Slice__consteval__consteval__CeVal__index_range(const Slice__consteval__consteval__CeVal *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc21;
    if (r.inclusive) {
      __sc21 = (r.end + 1ULL);
    } else {
      __sc21 = r.end;
    }
    __sc21;
  });
  return (Slice__consteval__consteval__CeVal){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__consteval__consteval__CeVal__len(const SliceMut__consteval__consteval__CeVal *const self) {
  return self->len;
}

consteval__consteval__CeVal *SliceMut__consteval__consteval__CeVal__as_mut_ptr(const SliceMut__consteval__consteval__CeVal *const self) {
  return self->ptr;
}

const consteval__consteval__CeVal *SliceMut__consteval__consteval__CeVal__index(const SliceMut__consteval__consteval__CeVal *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CeVal SliceMut__consteval__consteval__CeVal__index_range(const SliceMut__consteval__consteval__CeVal *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc22;
    if (r.inclusive) {
      __sc22 = (r.end + 1ULL);
    } else {
      __sc22 = r.end;
    }
    __sc22;
  });
  return (Slice__consteval__consteval__CeVal){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__CeVal *SliceMut__consteval__consteval__CeVal__index_mut(SliceMut__consteval__consteval__CeVal *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__CeVal SliceMut__consteval__consteval__CeVal__index_range_mut(SliceMut__consteval__consteval__CeVal *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc23;
    if (r.inclusive) {
      __sc23 = (r.end + 1ULL);
    } else {
      __sc23 = r.end;
    }
    __sc23;
  });
  return (SliceMut__consteval__consteval__CeVal){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue__some(consteval__consteval__ConstValue const value) {
  return (Option__consteval__consteval__ConstValue){ .tag = Option_Some, .payload.Some = { value } };
}

Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue__none(void) {
  return (Option__consteval__consteval__ConstValue){ .tag = Option_None };
}

bool Option__consteval__consteval__ConstValue__is_some(const Option__consteval__consteval__ConstValue *const self) {
  {
    const Option__consteval__consteval__ConstValue *const __sc24 = self;
    if ((*__sc24).tag == Option_Some) {
      return true;
    }
    else if ((*__sc24).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__consteval__consteval__ConstValue__is_none(const Option__consteval__consteval__ConstValue *const self) {
  {
    const Option__consteval__consteval__ConstValue *const __sc25 = self;
    if ((*__sc25).tag == Option_Some) {
      return false;
    }
    else if ((*__sc25).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue__default_(void) {
  return Option__consteval__consteval__ConstValue__none();
}

Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue__some(const consteval__consteval__ConstValue *const value) {
  return (Option__ptr_consteval__consteval__ConstValue){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue__none(void) {
  return (Option__ptr_consteval__consteval__ConstValue){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__ConstValue__is_some(const Option__ptr_consteval__consteval__ConstValue *const self) {
  {
    const Option__ptr_consteval__consteval__ConstValue *const __sc26 = self;
    if ((*__sc26).tag == Option_Some) {
      return true;
    }
    else if ((*__sc26).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__ConstValue__is_none(const Option__ptr_consteval__consteval__ConstValue *const self) {
  {
    const Option__ptr_consteval__consteval__ConstValue *const __sc27 = self;
    if ((*__sc27).tag == Option_Some) {
      return false;
    }
    else if ((*__sc27).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue__default_(void) {
  return Option__ptr_consteval__consteval__ConstValue__none();
}

Option__ptr_consteval__consteval__ConstValue VecIter__consteval__consteval__ConstValue__next(VecIter__consteval__consteval__ConstValue *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_consteval__consteval__ConstValue__none();
  }
  const consteval__consteval__ConstValue *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_consteval__consteval__ConstValue__some(r);
}

size_t Slice__consteval__consteval__ConstValue__len(const Slice__consteval__consteval__ConstValue *const self) {
  return self->len;
}

const consteval__consteval__ConstValue *Slice__consteval__consteval__ConstValue__as_ptr(const Slice__consteval__consteval__ConstValue *const self) {
  return self->ptr;
}

const consteval__consteval__ConstValue *Slice__consteval__consteval__ConstValue__index(const Slice__consteval__consteval__ConstValue *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__ConstValue Slice__consteval__consteval__ConstValue__index_range(const Slice__consteval__consteval__ConstValue *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc28;
    if (r.inclusive) {
      __sc28 = (r.end + 1ULL);
    } else {
      __sc28 = r.end;
    }
    __sc28;
  });
  return (Slice__consteval__consteval__ConstValue){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__consteval__consteval__ConstValue__len(const SliceMut__consteval__consteval__ConstValue *const self) {
  return self->len;
}

consteval__consteval__ConstValue *SliceMut__consteval__consteval__ConstValue__as_mut_ptr(const SliceMut__consteval__consteval__ConstValue *const self) {
  return self->ptr;
}

const consteval__consteval__ConstValue *SliceMut__consteval__consteval__ConstValue__index(const SliceMut__consteval__consteval__ConstValue *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__ConstValue SliceMut__consteval__consteval__ConstValue__index_range(const SliceMut__consteval__consteval__ConstValue *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc29;
    if (r.inclusive) {
      __sc29 = (r.end + 1ULL);
    } else {
      __sc29 = r.end;
    }
    __sc29;
  });
  return (Slice__consteval__consteval__ConstValue){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__ConstValue *SliceMut__consteval__consteval__ConstValue__index_mut(SliceMut__consteval__consteval__ConstValue *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__ConstValue SliceMut__consteval__consteval__ConstValue__index_range_mut(SliceMut__consteval__consteval__ConstValue *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc30;
    if (r.inclusive) {
      __sc30 = (r.end + 1ULL);
    } else {
      __sc30 = r.end;
    }
    __sc30;
  });
  return (SliceMut__consteval__consteval__ConstValue){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global__some(Vector__consteval__consteval__ConstValue__Global value) {
  return (Option__Vector__consteval__consteval__ConstValue__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global__none(void) {
  return (Option__Vector__consteval__consteval__ConstValue__Global){ .tag = Option_None };
}

bool Option__Vector__consteval__consteval__ConstValue__Global__is_some(const Option__Vector__consteval__consteval__ConstValue__Global *const self) {
  {
    const Option__Vector__consteval__consteval__ConstValue__Global *const __sc31 = self;
    if ((*__sc31).tag == Option_Some) {
      return true;
    }
    else if ((*__sc31).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__Vector__consteval__consteval__ConstValue__Global__is_none(const Option__Vector__consteval__consteval__ConstValue__Global *const self) {
  {
    const Option__Vector__consteval__consteval__ConstValue__Global *const __sc32 = self;
    if ((*__sc32).tag == Option_Some) {
      return false;
    }
    else if ((*__sc32).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global__default_(void) {
  return Option__Vector__consteval__consteval__ConstValue__Global__none();
}

void Option__Vector__consteval__consteval__ConstValue__Global__free(Option__Vector__consteval__consteval__ConstValue__Global *const self) {
  {
    Option__Vector__consteval__consteval__ConstValue__Global *const __sc33 = self;
    if ((*__sc33).tag == Option_Some) {
      const __auto_type v = &((*__sc33).payload.Some._0);
      Vector__consteval__consteval__ConstValue__Global__free(v);
    }
    else if ((*__sc33).tag == Option_None) {
      {
      }
    }
  }
}

Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global__some(const Vector__consteval__consteval__ConstValue__Global *const value) {
  return (Option__ptr_Vector__consteval__consteval__ConstValue__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global__none(void) {
  return (Option__ptr_Vector__consteval__consteval__ConstValue__Global){ .tag = Option_None };
}

bool Option__ptr_Vector__consteval__consteval__ConstValue__Global__is_some(const Option__ptr_Vector__consteval__consteval__ConstValue__Global *const self) {
  {
    const Option__ptr_Vector__consteval__consteval__ConstValue__Global *const __sc34 = self;
    if ((*__sc34).tag == Option_Some) {
      return true;
    }
    else if ((*__sc34).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_Vector__consteval__consteval__ConstValue__Global__is_none(const Option__ptr_Vector__consteval__consteval__ConstValue__Global *const self) {
  {
    const Option__ptr_Vector__consteval__consteval__ConstValue__Global *const __sc35 = self;
    if ((*__sc35).tag == Option_Some) {
      return false;
    }
    else if ((*__sc35).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global__default_(void) {
  return Option__ptr_Vector__consteval__consteval__ConstValue__Global__none();
}

Option__ptr_Vector__consteval__consteval__ConstValue__Global VecIter__Vector__consteval__consteval__ConstValue__Global__next(VecIter__Vector__consteval__consteval__ConstValue__Global *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_Vector__consteval__consteval__ConstValue__Global__none();
  }
  const Vector__consteval__consteval__ConstValue__Global *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_Vector__consteval__consteval__ConstValue__Global__some(r);
}

size_t Slice__Vector__consteval__consteval__ConstValue__Global__len(const Slice__Vector__consteval__consteval__ConstValue__Global *const self) {
  return self->len;
}

const Vector__consteval__consteval__ConstValue__Global *Slice__Vector__consteval__consteval__ConstValue__Global__as_ptr(const Slice__Vector__consteval__consteval__ConstValue__Global *const self) {
  return self->ptr;
}

const Vector__consteval__consteval__ConstValue__Global *Slice__Vector__consteval__consteval__ConstValue__Global__index(const Slice__Vector__consteval__consteval__ConstValue__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__consteval__consteval__ConstValue__Global Slice__Vector__consteval__consteval__ConstValue__Global__index_range(const Slice__Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc36;
    if (r.inclusive) {
      __sc36 = (r.end + 1ULL);
    } else {
      __sc36 = r.end;
    }
    __sc36;
  });
  return (Slice__Vector__consteval__consteval__ConstValue__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__Vector__consteval__consteval__ConstValue__Global__len(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self) {
  return self->len;
}

Vector__consteval__consteval__ConstValue__Global *SliceMut__Vector__consteval__consteval__ConstValue__Global__as_mut_ptr(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self) {
  return self->ptr;
}

const Vector__consteval__consteval__ConstValue__Global *SliceMut__Vector__consteval__consteval__ConstValue__Global__index(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__Vector__consteval__consteval__ConstValue__Global SliceMut__Vector__consteval__consteval__ConstValue__Global__index_range(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc37;
    if (r.inclusive) {
      __sc37 = (r.end + 1ULL);
    } else {
      __sc37 = r.end;
    }
    __sc37;
  });
  return (Slice__Vector__consteval__consteval__ConstValue__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Vector__consteval__consteval__ConstValue__Global *SliceMut__Vector__consteval__consteval__ConstValue__Global__index_mut(SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__Vector__consteval__consteval__ConstValue__Global SliceMut__Vector__consteval__consteval__ConstValue__Global__index_range_mut(SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc38;
    if (r.inclusive) {
      __sc38 = (r.end + 1ULL);
    } else {
      __sc38 = r.end;
    }
    __sc38;
  });
  return (SliceMut__Vector__consteval__consteval__ConstValue__Global){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj__some(consteval__consteval__CeObj value) {
  return (Option__consteval__consteval__CeObj){ .tag = Option_Some, .payload.Some = { value } };
}

Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj__none(void) {
  return (Option__consteval__consteval__CeObj){ .tag = Option_None };
}

bool Option__consteval__consteval__CeObj__is_some(const Option__consteval__consteval__CeObj *const self) {
  {
    const Option__consteval__consteval__CeObj *const __sc39 = self;
    if ((*__sc39).tag == Option_Some) {
      return true;
    }
    else if ((*__sc39).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__consteval__consteval__CeObj__is_none(const Option__consteval__consteval__CeObj *const self) {
  {
    const Option__consteval__consteval__CeObj *const __sc40 = self;
    if ((*__sc40).tag == Option_Some) {
      return false;
    }
    else if ((*__sc40).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj__default_(void) {
  return Option__consteval__consteval__CeObj__none();
}

void Option__consteval__consteval__CeObj__free(Option__consteval__consteval__CeObj *const self) {
  {
    Option__consteval__consteval__CeObj *const __sc41 = self;
    if ((*__sc41).tag == Option_Some) {
      const __auto_type v = &((*__sc41).payload.Some._0);
      consteval__consteval__CeObj__free(v);
    }
    else if ((*__sc41).tag == Option_None) {
      {
      }
    }
  }
}

Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj__some(const consteval__consteval__CeObj *const value) {
  return (Option__ptr_consteval__consteval__CeObj){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj__none(void) {
  return (Option__ptr_consteval__consteval__CeObj){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__CeObj__is_some(const Option__ptr_consteval__consteval__CeObj *const self) {
  {
    const Option__ptr_consteval__consteval__CeObj *const __sc42 = self;
    if ((*__sc42).tag == Option_Some) {
      return true;
    }
    else if ((*__sc42).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__CeObj__is_none(const Option__ptr_consteval__consteval__CeObj *const self) {
  {
    const Option__ptr_consteval__consteval__CeObj *const __sc43 = self;
    if ((*__sc43).tag == Option_Some) {
      return false;
    }
    else if ((*__sc43).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj__default_(void) {
  return Option__ptr_consteval__consteval__CeObj__none();
}

Option__ptr_consteval__consteval__CeObj VecIter__consteval__consteval__CeObj__next(VecIter__consteval__consteval__CeObj *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_consteval__consteval__CeObj__none();
  }
  const consteval__consteval__CeObj *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_consteval__consteval__CeObj__some(r);
}

size_t Slice__consteval__consteval__CeObj__len(const Slice__consteval__consteval__CeObj *const self) {
  return self->len;
}

const consteval__consteval__CeObj *Slice__consteval__consteval__CeObj__as_ptr(const Slice__consteval__consteval__CeObj *const self) {
  return self->ptr;
}

const consteval__consteval__CeObj *Slice__consteval__consteval__CeObj__index(const Slice__consteval__consteval__CeObj *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CeObj Slice__consteval__consteval__CeObj__index_range(const Slice__consteval__consteval__CeObj *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc44;
    if (r.inclusive) {
      __sc44 = (r.end + 1ULL);
    } else {
      __sc44 = r.end;
    }
    __sc44;
  });
  return (Slice__consteval__consteval__CeObj){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__consteval__consteval__CeObj__len(const SliceMut__consteval__consteval__CeObj *const self) {
  return self->len;
}

consteval__consteval__CeObj *SliceMut__consteval__consteval__CeObj__as_mut_ptr(const SliceMut__consteval__consteval__CeObj *const self) {
  return self->ptr;
}

const consteval__consteval__CeObj *SliceMut__consteval__consteval__CeObj__index(const SliceMut__consteval__consteval__CeObj *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CeObj SliceMut__consteval__consteval__CeObj__index_range(const SliceMut__consteval__consteval__CeObj *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc45;
    if (r.inclusive) {
      __sc45 = (r.end + 1ULL);
    } else {
      __sc45 = r.end;
    }
    __sc45;
  });
  return (Slice__consteval__consteval__CeObj){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__CeObj *SliceMut__consteval__consteval__CeObj__index_mut(SliceMut__consteval__consteval__CeObj *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__CeObj SliceMut__consteval__consteval__CeObj__index_range_mut(SliceMut__consteval__consteval__CeObj *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc46;
    if (r.inclusive) {
      __sc46 = (r.end + 1ULL);
    } else {
      __sc46 = r.end;
    }
    __sc46;
  });
  return (SliceMut__consteval__consteval__CeObj){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__consteval__consteval__CePending Option__consteval__consteval__CePending__some(consteval__consteval__CePending const value) {
  return (Option__consteval__consteval__CePending){ .tag = Option_Some, .payload.Some = { value } };
}

Option__consteval__consteval__CePending Option__consteval__consteval__CePending__none(void) {
  return (Option__consteval__consteval__CePending){ .tag = Option_None };
}

bool Option__consteval__consteval__CePending__is_some(const Option__consteval__consteval__CePending *const self) {
  {
    const Option__consteval__consteval__CePending *const __sc47 = self;
    if ((*__sc47).tag == Option_Some) {
      return true;
    }
    else if ((*__sc47).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__consteval__consteval__CePending__is_none(const Option__consteval__consteval__CePending *const self) {
  {
    const Option__consteval__consteval__CePending *const __sc48 = self;
    if ((*__sc48).tag == Option_Some) {
      return false;
    }
    else if ((*__sc48).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__consteval__consteval__CePending Option__consteval__consteval__CePending__default_(void) {
  return Option__consteval__consteval__CePending__none();
}

Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending__some(const consteval__consteval__CePending *const value) {
  return (Option__ptr_consteval__consteval__CePending){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending__none(void) {
  return (Option__ptr_consteval__consteval__CePending){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__CePending__is_some(const Option__ptr_consteval__consteval__CePending *const self) {
  {
    const Option__ptr_consteval__consteval__CePending *const __sc49 = self;
    if ((*__sc49).tag == Option_Some) {
      return true;
    }
    else if ((*__sc49).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__CePending__is_none(const Option__ptr_consteval__consteval__CePending *const self) {
  {
    const Option__ptr_consteval__consteval__CePending *const __sc50 = self;
    if ((*__sc50).tag == Option_Some) {
      return false;
    }
    else if ((*__sc50).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending__default_(void) {
  return Option__ptr_consteval__consteval__CePending__none();
}

Option__ptr_consteval__consteval__CePending VecIter__consteval__consteval__CePending__next(VecIter__consteval__consteval__CePending *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_consteval__consteval__CePending__none();
  }
  const consteval__consteval__CePending *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_consteval__consteval__CePending__some(r);
}

size_t Slice__consteval__consteval__CePending__len(const Slice__consteval__consteval__CePending *const self) {
  return self->len;
}

const consteval__consteval__CePending *Slice__consteval__consteval__CePending__as_ptr(const Slice__consteval__consteval__CePending *const self) {
  return self->ptr;
}

const consteval__consteval__CePending *Slice__consteval__consteval__CePending__index(const Slice__consteval__consteval__CePending *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CePending Slice__consteval__consteval__CePending__index_range(const Slice__consteval__consteval__CePending *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc51;
    if (r.inclusive) {
      __sc51 = (r.end + 1ULL);
    } else {
      __sc51 = r.end;
    }
    __sc51;
  });
  return (Slice__consteval__consteval__CePending){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__consteval__consteval__CePending__len(const SliceMut__consteval__consteval__CePending *const self) {
  return self->len;
}

consteval__consteval__CePending *SliceMut__consteval__consteval__CePending__as_mut_ptr(const SliceMut__consteval__consteval__CePending *const self) {
  return self->ptr;
}

const consteval__consteval__CePending *SliceMut__consteval__consteval__CePending__index(const SliceMut__consteval__consteval__CePending *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__CePending SliceMut__consteval__consteval__CePending__index_range(const SliceMut__consteval__consteval__CePending *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc52;
    if (r.inclusive) {
      __sc52 = (r.end + 1ULL);
    } else {
      __sc52 = r.end;
    }
    __sc52;
  });
  return (Slice__consteval__consteval__CePending){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__CePending *SliceMut__consteval__consteval__CePending__index_mut(SliceMut__consteval__consteval__CePending *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__CePending SliceMut__consteval__consteval__CePending__index_range_mut(SliceMut__consteval__consteval__CePending *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc53;
    if (r.inclusive) {
      __sc53 = (r.end + 1ULL);
    } else {
      __sc53 = r.end;
    }
    __sc53;
  });
  return (SliceMut__consteval__consteval__CePending){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit__some(consteval__consteval__CeCallHit const value) {
  return (Option__consteval__consteval__CeCallHit){ .tag = Option_Some, .payload.Some = { value } };
}

Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit__none(void) {
  return (Option__consteval__consteval__CeCallHit){ .tag = Option_None };
}

bool Option__consteval__consteval__CeCallHit__is_some(const Option__consteval__consteval__CeCallHit *const self) {
  {
    const Option__consteval__consteval__CeCallHit *const __sc54 = self;
    if ((*__sc54).tag == Option_Some) {
      return true;
    }
    else if ((*__sc54).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__consteval__consteval__CeCallHit__is_none(const Option__consteval__consteval__CeCallHit *const self) {
  {
    const Option__consteval__consteval__CeCallHit *const __sc55 = self;
    if ((*__sc55).tag == Option_Some) {
      return false;
    }
    else if ((*__sc55).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit__default_(void) {
  return Option__consteval__consteval__CeCallHit__none();
}

Option__ptr_consteval__consteval__CeCallKey MapKeys__consteval__consteval__CeCallKey__next(MapKeys__consteval__consteval__CeCallKey *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_consteval__consteval__CeCallKey){ .tag = Option_Some, .payload.Some = { (&self->keys[i]) } };
    }
  }
  return (Option__ptr_consteval__consteval__CeCallKey){ .tag = Option_None };
}

Option__ptr_consteval__consteval__CeCallHit MapValues__consteval__consteval__CeCallHit__next(MapValues__consteval__consteval__CeCallHit *const self) {
  while (self->idx < self->cap) {
    const size_t i = self->idx;
    (self->idx = (self->idx + 1ULL));
    if (self->used[i] != 0U) {
      return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_Some, .payload.Some = { (&self->vals[i]) } };
    }
  }
  return (Option__ptr_consteval__consteval__CeCallHit){ .tag = Option_None };
}

Option__consteval__consteval__UFree Option__consteval__consteval__UFree__some(consteval__consteval__UFree const value) {
  return (Option__consteval__consteval__UFree){ .tag = Option_Some, .payload.Some = { value } };
}

Option__consteval__consteval__UFree Option__consteval__consteval__UFree__none(void) {
  return (Option__consteval__consteval__UFree){ .tag = Option_None };
}

bool Option__consteval__consteval__UFree__is_some(const Option__consteval__consteval__UFree *const self) {
  {
    const Option__consteval__consteval__UFree *const __sc56 = self;
    if ((*__sc56).tag == Option_Some) {
      return true;
    }
    else if ((*__sc56).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__consteval__consteval__UFree__is_none(const Option__consteval__consteval__UFree *const self) {
  {
    const Option__consteval__consteval__UFree *const __sc57 = self;
    if ((*__sc57).tag == Option_Some) {
      return false;
    }
    else if ((*__sc57).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__consteval__consteval__UFree Option__consteval__consteval__UFree__default_(void) {
  return Option__consteval__consteval__UFree__none();
}

Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree__some(const consteval__consteval__UFree *const value) {
  return (Option__ptr_consteval__consteval__UFree){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree__none(void) {
  return (Option__ptr_consteval__consteval__UFree){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__UFree__is_some(const Option__ptr_consteval__consteval__UFree *const self) {
  {
    const Option__ptr_consteval__consteval__UFree *const __sc58 = self;
    if ((*__sc58).tag == Option_Some) {
      return true;
    }
    else if ((*__sc58).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__UFree__is_none(const Option__ptr_consteval__consteval__UFree *const self) {
  {
    const Option__ptr_consteval__consteval__UFree *const __sc59 = self;
    if ((*__sc59).tag == Option_Some) {
      return false;
    }
    else if ((*__sc59).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree__default_(void) {
  return Option__ptr_consteval__consteval__UFree__none();
}

Option__ptr_consteval__consteval__UFree VecIter__consteval__consteval__UFree__next(VecIter__consteval__consteval__UFree *const self) {
  if (self->idx >= self->stop) {
    return Option__ptr_consteval__consteval__UFree__none();
  }
  const consteval__consteval__UFree *const r = (&self->data[self->idx]);
  (self->idx = (self->idx + 1ULL));
  return Option__ptr_consteval__consteval__UFree__some(r);
}

size_t Slice__consteval__consteval__UFree__len(const Slice__consteval__consteval__UFree *const self) {
  return self->len;
}

const consteval__consteval__UFree *Slice__consteval__consteval__UFree__as_ptr(const Slice__consteval__consteval__UFree *const self) {
  return self->ptr;
}

const consteval__consteval__UFree *Slice__consteval__consteval__UFree__index(const Slice__consteval__consteval__UFree *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__UFree Slice__consteval__consteval__UFree__index_range(const Slice__consteval__consteval__UFree *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc60;
    if (r.inclusive) {
      __sc60 = (r.end + 1ULL);
    } else {
      __sc60 = r.end;
    }
    __sc60;
  });
  return (Slice__consteval__consteval__UFree){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__consteval__consteval__UFree__len(const SliceMut__consteval__consteval__UFree *const self) {
  return self->len;
}

consteval__consteval__UFree *SliceMut__consteval__consteval__UFree__as_mut_ptr(const SliceMut__consteval__consteval__UFree *const self) {
  return self->ptr;
}

const consteval__consteval__UFree *SliceMut__consteval__consteval__UFree__index(const SliceMut__consteval__consteval__UFree *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__consteval__consteval__UFree SliceMut__consteval__consteval__UFree__index_range(const SliceMut__consteval__consteval__UFree *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc61;
    if (r.inclusive) {
      __sc61 = (r.end + 1ULL);
    } else {
      __sc61 = r.end;
    }
    __sc61;
  });
  return (Slice__consteval__consteval__UFree){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

consteval__consteval__UFree *SliceMut__consteval__consteval__UFree__index_mut(SliceMut__consteval__consteval__UFree *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__consteval__consteval__UFree SliceMut__consteval__consteval__UFree__index_range_mut(SliceMut__consteval__consteval__UFree *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc62;
    if (r.inclusive) {
      __sc62 = (r.end + 1ULL);
    } else {
      __sc62 = r.end;
    }
    __sc62;
  });
  return (SliceMut__consteval__consteval__UFree){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey__some(const consteval__consteval__CeCallKey *const value) {
  return (Option__ptr_consteval__consteval__CeCallKey){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey__none(void) {
  return (Option__ptr_consteval__consteval__CeCallKey){ .tag = Option_None };
}

bool Option__ptr_consteval__consteval__CeCallKey__is_some(const Option__ptr_consteval__consteval__CeCallKey *const self) {
  {
    const Option__ptr_consteval__consteval__CeCallKey *const __sc63 = self;
    if ((*__sc63).tag == Option_Some) {
      return true;
    }
    else if ((*__sc63).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_consteval__consteval__CeCallKey__is_none(const Option__ptr_consteval__consteval__CeCallKey *const self) {
  {
    const Option__ptr_consteval__consteval__CeCallKey *const __sc64 = self;
    if ((*__sc64).tag == Option_Some) {
      return false;
    }
    else if ((*__sc64).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey__default_(void) {
  return Option__ptr_consteval__consteval__CeCallKey__none();
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__cv_nil(void) {
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_NIL_K };
}

static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ce_none(void) {
  return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_NONE };
}

void consteval__consteval__CeObj__free(consteval__consteval__CeObj *const self) {
  Vector__consteval__consteval__CeVal__Global__free(&self->slots);
}

static __attribute__((unused)) consteval__consteval__CeRecv consteval__consteval__ce_recv_zero(void) {
  return (consteval__consteval__CeRecv){ .dn = ast__ast__NODE_NONE, .b = ast__ast__BuiltinType_BT_COUNT };
}

static __attribute__((unused)) consteval__consteval__CeFrame consteval__consteval__ce_frame_zero(void) {
  return (consteval__consteval__CeFrame){ .env = 0U };
}

uint64_t consteval__consteval__CeCallKey__hash(const consteval__consteval__CeCallKey *const self) {
  uint64_t h = 1469598103934665603ULL;
  (h = ((h ^ ((uint64_t)self->m)) * 1099511628211ULL));
  (h = ((h ^ ((uint64_t)self->fn_id)) * 1099511628211ULL));
  (h = ((h ^ ((uint64_t)self->nargs)) * 1099511628211ULL));
  for (int32_t i = 0; i < 8; i++) {
    (h = ((h ^ ((uint64_t)self->kinds[i])) * 1099511628211ULL));
    (h = ((h ^ ((uint64_t)self->bits[i])) * 1099511628211ULL));
  }
  return h;
}

bool consteval__consteval__CeCallKey__eq(const consteval__consteval__CeCallKey *const self, const consteval__consteval__CeCallKey *const other) {
  if (((self->m != other->m) || (self->fn_id != other->fn_id)) || (self->nargs != other->nargs)) {
    return false;
  }
  for (int32_t i = 0; i < 8; i++) {
    if ((self->kinds[i] != other->kinds[i]) || (self->bits[i] != other->bits[i])) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) bool consteval__consteval__bt_signed(ast__ast__BuiltinType const b) {
  return (((((b == ast__ast__BuiltinType_BT_I8) || (b == ast__ast__BuiltinType_BT_I16)) || (b == ast__ast__BuiltinType_BT_I32)) || (b == ast__ast__BuiltinType_BT_I64)) || (b == ast__ast__BuiltinType_BT_ISIZE));
}

static __attribute__((unused)) bool consteval__consteval__bt_unsigned(ast__ast__BuiltinType const b) {
  return ((((((b == ast__ast__BuiltinType_BT_U8) || (b == ast__ast__BuiltinType_BT_U16)) || (b == ast__ast__BuiltinType_BT_U32)) || (b == ast__ast__BuiltinType_BT_U64)) || (b == ast__ast__BuiltinType_BT_USIZE)) || (b == ast__ast__BuiltinType_BT_CHAR));
}

static __attribute__((unused)) int32_t consteval__consteval__bt_bits(ast__ast__BuiltinType const b) {
  if ((((b == ast__ast__BuiltinType_BT_BOOL) || (b == ast__ast__BuiltinType_BT_CHAR)) || (b == ast__ast__BuiltinType_BT_I8)) || (b == ast__ast__BuiltinType_BT_U8)) {
    return 8;
  }
  if ((b == ast__ast__BuiltinType_BT_I16) || (b == ast__ast__BuiltinType_BT_U16)) {
    return 16;
  }
  if ((b == ast__ast__BuiltinType_BT_I32) || (b == ast__ast__BuiltinType_BT_U32)) {
    return 32;
  }
  return 64;
}

static __attribute__((unused)) int64_t consteval__consteval__wrap_to(ast__ast__BuiltinType const b, int64_t const v) {
  const int32_t bits = consteval__consteval__bt_bits(b);
  if (bits == 64) {
    return v;
  }
  const uint64_t mask = (({ uint64_t __sc65 = 1ULL; int64_t __sc66 = (int64_t)(((uint64_t)bits)); if ((uint64_t)__sc66 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc65 << __sc66)); }) - 1ULL);
  uint64_t u = (((uint64_t)v) & mask);
  if (consteval__consteval__bt_signed(b) && (({ uint64_t __sc67 = u; int64_t __sc68 = (int64_t)(((uint64_t)({ int32_t __sc_r; if (__builtin_sub_overflow(bits, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))); if ((uint64_t)__sc68 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc67 >> __sc68); }) != 0ULL)) {
    (u = (u | (~mask)));
  }
  return ((int64_t)u);
}

static __attribute__((unused)) bool consteval__consteval__fits(ast__ast__BuiltinType const b, int64_t const v) {
  return (consteval__consteval__wrap_to(b, v) == v);
}

static __attribute__((unused)) bool consteval__consteval__ce_isfinite(double const x) {
  return (fabs(x) <= consteval__consteval__F64_MAX);
}

static __attribute__((unused)) consteval__consteval__OvfRes consteval__consteval__add_ovf(int64_t const a, int64_t const b) {
  const int64_t s = ((int64_t)(((uint64_t)a) + ((uint64_t)b)));
  return (consteval__consteval__OvfRes){ .ovf = (((a ^ s) & (b ^ s)) < 0), .v = s };
}

static __attribute__((unused)) consteval__consteval__OvfRes consteval__consteval__sub_ovf(int64_t const a, int64_t const b) {
  const int64_t d = ((int64_t)(((uint64_t)a) - ((uint64_t)b)));
  return (consteval__consteval__OvfRes){ .ovf = (((a ^ b) & (a ^ d)) < 0), .v = d };
}

static __attribute__((unused)) consteval__consteval__OvfRes consteval__consteval__mul_ovf(int64_t const a, int64_t const b) {
  const int64_t p = ((int64_t)(((uint64_t)a) * ((uint64_t)b)));
  bool ovf = false;
  if (a > 0) {
    if (b > 0) {
      (ovf = (a > ({ int64_t __sc69 = consteval__consteval__I64_MAX; int64_t __sc70 = b; if (__sc70 == 0) { __sc_panic("divide by zero"); } if (__sc70 == -1 && __sc69 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc69 / __sc70); })));
    } else {
      (ovf = (b < ({ int64_t __sc71 = consteval__consteval__I64_MIN; int64_t __sc72 = a; if (__sc72 == 0) { __sc_panic("divide by zero"); } if (__sc72 == -1 && __sc71 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc71 / __sc72); })));
    }
  } else if (a < 0) {
    if (b > 0) {
      (ovf = (a < ({ int64_t __sc73 = consteval__consteval__I64_MIN; int64_t __sc74 = b; if (__sc74 == 0) { __sc_panic("divide by zero"); } if (__sc74 == -1 && __sc73 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc73 / __sc74); })));
    } else {
      (ovf = ((a != 0) && (b < ({ int64_t __sc75 = consteval__consteval__I64_MAX; int64_t __sc76 = a; if (__sc76 == 0) { __sc_panic("divide by zero"); } if (__sc76 == -1 && __sc75 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc75 / __sc76); }))));
    }
  }
  return (consteval__consteval__OvfRes){ .ovf = ovf, .v = p };
}

consteval__consteval__ConstEval consteval__consteval__ConstEval__new(module__loader__Package *const pkg, uint32_t const max_steps, uint64_t const max_mem_bytes) {
  const size_t count = Vector__module__loader__Module__Global__len(&(*pkg).modules);
  consteval__consteval__ConstEval ce = (consteval__consteval__ConstEval){ .pkg = pkg, .vals = Vector__Vector__consteval__consteval__ConstValue__Global__Global__new(), .nmods = count, .depth = 0U, .nframes = 0U, .steps = 0U, .max_steps = consteval__consteval__if_default_steps(max_steps), .max_slots = consteval__consteval__if_default_slots(max_mem_bytes), .objs = Vector__consteval__consteval__CeObj__Global__new(), .live_slots = 0ULL, .trap = (str){ (const uint8_t *)"", sizeof("") - 1 }, .pending = Vector__consteval__consteval__CePending__Global__new(), .calls = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__new(), .ufree = Vector__consteval__consteval__UFree__Global__new() };
  for (size_t _ = 0ULL; _ < count; _++) {
    Vector__Vector__consteval__consteval__ConstValue__Global__Global__push(&ce.vals, Vector__consteval__consteval__ConstValue__Global__new());
  }
  return ce;
}

static __attribute__((unused)) const ast__ast__Ast *consteval__consteval__ConstEval__ast_ptr(const consteval__consteval__ConstEval *const self, uint16_t const m) {
  if ((m == (*self->pkg).override_mod) && ((*self->pkg).override_ast != NULL)) {
    return ((const ast__ast__Ast *)(*self->pkg).override_ast);
  }
  return ((const ast__ast__Ast *)(&(*({ __auto_type __sc77 = &(*self->pkg).modules; Vector__module__loader__Module__Global__index(__sc77, ((size_t)m)); })).ast));
}

static __attribute__((unused)) ast__ast__Ast *consteval__consteval__ConstEval__mut_ast_ptr(const consteval__consteval__ConstEval *const self, uint16_t const m) {
  if ((m == (*self->pkg).override_mod) && ((*self->pkg).override_ast != NULL)) {
    return (*self->pkg).override_ast;
  }
  return ((ast__ast__Ast *)(&(*({ __auto_type __sc78 = &(*self->pkg).modules; Vector__module__loader__Module__Global__index_mut(__sc78, ((size_t)m)); })).ast));
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__has_ast(const consteval__consteval__ConstEval *const self, uint16_t const m) {
  if (((size_t)m) >= self->nmods) {
    return false;
  }
  return (*({ __auto_type __sc79 = &(*self->pkg).modules; Vector__module__loader__Module__Global__index(__sc79, ((size_t)m)); })).has_ast;
}

static __attribute__((unused)) const uint8_t *consteval__consteval__ConstEval__ce_src(const consteval__consteval__ConstEval *const self, uint16_t const m) {
  return ({ __auto_type __sc80 = String__Global__as_str(&(*({ __auto_type __sc81 = &(*self->pkg).modules; Vector__module__loader__Module__Global__index(__sc81, ((size_t)m)); })).source); str__ptr(&__sc80); });
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__is_prelude(const consteval__consteval__ConstEval *const self, uint16_t const m) {
  return (*({ __auto_type __sc82 = &(*self->pkg).modules; Vector__module__loader__Module__Global__index(__sc82, ((size_t)m)); })).prelude;
}

static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_type(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  if (Vector__u32__Global__len(&(*a).types) > ((size_t)id)) {
    return ast__ast__Ast__type_of(&((*a)), id);
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((cold, noinline, unused)) void consteval__consteval__ConstEval__ce_trap(consteval__consteval__ConstEval *const self, str const msg) {
  if (str__len(&self->trap) == 0ULL) {
    (self->trap = msg);
  }
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_tick(consteval__consteval__ConstEval *const self) {
  (self->steps = (self->steps + 1U));
  if (self->steps > self->max_steps) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"const-eval step budget exceeded", sizeof("const-eval step budget exceeded") - 1 });
    return false;
  }
  return true;
}

static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__slot_get(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id) {
  if (((size_t)m) >= Vector__Vector__consteval__consteval__ConstValue__Global__Global__len(&self->vals)) {
    return consteval__consteval__ce_none();
  }
  const Vector__consteval__consteval__ConstValue__Global *const inner = Vector__Vector__consteval__consteval__ConstValue__Global__Global__at(&self->vals, ((size_t)m));
  if (((size_t)id) >= Vector__consteval__consteval__ConstValue__Global__len(inner)) {
    return consteval__consteval__ce_none();
  }
  return (*({ __auto_type __sc83 = inner; Vector__consteval__consteval__ConstValue__Global__index(__sc83, ((size_t)id)); }));
}

static __attribute__((unused)) void consteval__consteval__ConstEval__slot_set(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id, consteval__consteval__ConstValue const v) {
  if (((size_t)m) >= Vector__Vector__consteval__consteval__ConstValue__Global__Global__len(&self->vals)) {
    return;
  }
  Vector__consteval__consteval__ConstValue__Global *const inner = (&(*({ __auto_type __sc84 = &self->vals; Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_mut(__sc84, ((size_t)m)); })));
  while (Vector__consteval__consteval__ConstValue__Global__len(inner) <= ((size_t)id)) {
    Vector__consteval__consteval__ConstValue__Global__push(inner, consteval__consteval__ce_none());
  }
  Vector__consteval__consteval__ConstValue__Global__set(inner, ((size_t)id), v);
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_spans_eq(const consteval__consteval__ConstEval *const self, uint16_t const ma, lexer__token__Span const a, uint16_t const mb, lexer__token__Span const b) {
  const uint32_t la = (a.end - a.start);
  if (la != (b.end - b.start)) {
    return false;
  }
  return (memcmp((consteval__consteval__ConstEval__ce_src(self, ma) + ((size_t)a.start)), (consteval__consteval__ConstEval__ce_src(self, mb) + ((size_t)b.start)), ((size_t)la)) == 0);
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_span_is(const consteval__consteval__ConstEval *const self, uint16_t const m, lexer__token__Span const s, str const lit) {
  const size_t n = str__len(&lit);
  if (((size_t)(s.end - s.start)) != n) {
    return false;
  }
  return (memcmp((consteval__consteval__ConstEval__ce_src(self, m) + ((size_t)s.start)), str__ptr(&lit), n) == 0);
}

static __attribute__((unused)) lexer__token__Span consteval__consteval__ConstEval__name_text(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const name_node) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  return ast__ast__Ast__at_const(&((*a)), name_node)->as_data.name.text;
}

static __attribute__((unused)) uint32_t consteval__consteval__if_default_steps(uint32_t const s) {
  if (s != 0U) {
    return s;
  }
  return consteval__consteval__CE_DEFAULT_STEPS;
}

static __attribute__((unused)) uint64_t consteval__consteval__if_default_slots(uint64_t const b) {
  if (b != 0ULL) {
    const uint64_t s = ({ uint64_t __sc85 = b; uint64_t __sc86 = 16ULL; if (__sc86 == 0) { __sc_panic("divide by zero"); } (__sc85 / __sc86); });
    if (s != 0ULL) {
      return s;
    }
    return 1ULL;
  }
  return consteval__consteval__CE_DEFAULT_SLOTS;
}

static __attribute__((unused)) ast__ast__BuiltinType consteval__consteval__type_builtin(const ast__ast__Ast *const a, uint32_t const t) {
  if (t == ast__ast__TYPE_NONE) {
    return ast__ast__BuiltinType_BT_COUNT;
  }
  const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*a)), t);
  if (y->kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    return y->as_data.builtin;
  }
  return ast__ast__BuiltinType_BT_COUNT;
}

static __attribute__((unused)) uint64_t consteval__consteval__round_up(uint64_t const v, uint64_t const a) {
  if (a != 0ULL) {
    return (({ uint64_t __sc87 = ((v + a) - 1ULL); uint64_t __sc88 = a; if (__sc88 == 0) { __sc_panic("divide by zero"); } (__sc87 / __sc88); }) * a);
  }
  return v;
}

static __attribute__((unused)) int32_t consteval__consteval__hexval(uint8_t const ch) {
  if ((ch >= 48U) && (ch <= 57U)) {
    return ((int32_t)((uint8_t)((uint32_t)ch - (uint32_t)48U)));
  }
  if ((ch >= 97U) && (ch <= 102U)) {
    return ((int32_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)ch - (uint32_t)97U)) + (uint32_t)10U)));
  }
  if ((ch >= 65U) && (ch <= 70U)) {
    return ((int32_t)((uint8_t)((uint32_t)((uint8_t)((uint32_t)ch - (uint32_t)65U)) + (uint32_t)10U)));
  }
  return -1;
}

static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__eval_int_literal(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint8_t *const src = consteval__consteval__ConstEval__ce_src(self, m);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.raw;
  uint32_t endd = sp.end;
  ast__ast__ast_numeric_suffix(src, sp.start, sp.end, ((uint32_t *)(&endd)));
  uint64_t v = 0ULL;
  uint32_t i = sp.start;
  uint64_t base = 10ULL;
  if (((sp.end - sp.start) > 2U) && (src[((size_t)i)] == 48U)) {
    const uint8_t r = src[((size_t)(i + 1U))];
    if ((r == 120U) || (r == 88U)) {
      (base = 16ULL);
      (i = (i + 2U));
    } else if ((r == 98U) || (r == 66U)) {
      (base = 2ULL);
      (i = (i + 2U));
    } else if ((r == 111U) || (r == 79U)) {
      (base = 8ULL);
      (i = (i + 2U));
    }
  }
  while (i < endd) {
    const uint8_t ch = src[((size_t)i)];
    if (ch == 95U) {
      (i = (i + 1U));
      continue;
    }
    const int32_t d = consteval__consteval__hexval(ch);
    if ((d < 0) || (((uint64_t)d) >= base)) {
      return consteval__consteval__ce_none();
    }
    if (v > ({ uint64_t __sc89 = (consteval__consteval__U64_MAX - ((uint64_t)d)); uint64_t __sc90 = base; if (__sc90 == 0) { __sc_panic("divide by zero"); } (__sc89 / __sc90); })) {
      return consteval__consteval__ce_none();
    }
    (v = ((v * base) + ((uint64_t)d)));
    (i = (i + 1U));
  }
  const ast__ast__BuiltinType b = consteval__consteval__type_builtin(a, consteval__consteval__ConstEval__ce_type(self, m, id));
  const int64_t sv = ((int64_t)v);
  if ((b != ast__ast__BuiltinType_BT_COUNT) && (!consteval__consteval__fits(b, sv))) {
    return consteval__consteval__ce_none();
  }
  return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_INT, .ty = consteval__consteval__ConstEval__ce_type(self, m, id), .as_data = (consteval__consteval__ConstValueAs){ .i = sv } };
}

static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__eval_char_literal(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint8_t *const src = consteval__consteval__ConstEval__ce_src(self, m);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.raw;
  uint32_t i = (sp.start + 1U);
  if (src[((size_t)sp.start)] == 98U) {
    (i = (i + 1U));
  }
  if (i >= sp.end) {
    return consteval__consteval__ce_none();
  }
  int64_t v = 0;
  if (src[((size_t)i)] != 92U) {
    (v = ((int64_t)src[((size_t)i)]));
  } else {
    const uint8_t e = src[((size_t)(i + 1U))];
    {
      const uint8_t __sc91 = e;
      if (__sc91 == 'n') {
        {
          (v = 10);
        }
      }
      else if (__sc91 == 't') {
        {
          (v = 9);
        }
      }
      else if (__sc91 == 'r') {
        {
          (v = 13);
        }
      }
      else if (__sc91 == '0') {
        {
          (v = 0);
        }
      }
      else if (__sc91 == '\\') {
        {
          (v = 92);
        }
      }
      else if (__sc91 == '\'') {
        {
          (v = 39);
        }
      }
      else if (__sc91 == '"') {
        {
          (v = 34);
        }
      }
      else if (__sc91 == 'x') {
        {
          (v = 0);
          uint32_t k = (i + 2U);
          while (k < (sp.end - 1U)) {
            const int32_t d = consteval__consteval__hexval(src[((size_t)k)]);
            if (d < 0) {
              return consteval__consteval__ce_none();
            }
            (v = ({ int64_t __sc_r; if (__builtin_add_overflow(({ int64_t __sc_r; if (__builtin_mul_overflow(v, 16LL, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }), ((int64_t)d), &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
            (k = (k + 1U));
          }
        }
      }
      else if (1) {
        {
          return consteval__consteval__ce_none();
        }
      }
    }
  }
  return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_INT, .ty = consteval__consteval__ConstEval__ce_type(self, m, id), .as_data = (consteval__consteval__ConstValueAs){ .i = v } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__eval_float_literal(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint8_t *const src = consteval__consteval__ConstEval__ce_src(self, m);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.raw;
  consteval__consteval__Buf64 buf = (consteval__consteval__Buf64){0};
  size_t k = 0ULL;
  uint32_t i = sp.start;
  while ((i < sp.end) && ((k + 1ULL) < 64ULL)) {
    if (src[((size_t)i)] != 95U) {
      (buf.b[k] = ((char)src[((size_t)i)]));
      (k = (k + 1ULL));
    }
    (i = (i + 1U));
  }
  (buf.b[k] = 0);
  double v = strtod(((const char *)(&buf.b[0])), NULL);
  const ast__ast__BuiltinType b = consteval__consteval__type_builtin(a, consteval__consteval__ConstEval__ce_type(self, m, id));
  if (b == ast__ast__BuiltinType_BT_F32) {
    (v = ((double)((float)v)));
  } else if ((b != ast__ast__BuiltinType_BT_F64) && (b != ast__ast__BuiltinType_BT_COUNT)) {
    return consteval__consteval__cv_nil();
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FLOAT, .tm = m, .ty = consteval__consteval__ConstEval__ce_type(self, m, id), .as_data = (consteval__consteval__CeValAs){ .f = v } };
}

static __attribute__((unused)) const ast__ast__Attr *consteval__consteval__ConstEval__ce_attr(const consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const owner, ast__ast__AttrKind const kind) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  for (size_t i = 0ULL; i < Vector__ast__ast__Attr__Global__len(&(*a).attrs); i++) {
    const ast__ast__Attr *const at = Vector__ast__ast__Attr__Global__at(&(*a).attrs, i);
    if ((at->owner == owner) && (at->kind == ((uint8_t)kind))) {
      return ((const ast__ast__Attr *)at);
    }
  }
  return NULL;
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__acc_field(consteval__consteval__ConstEval *const self, consteval__consteval__LayoutAcc *const acc, uint16_t const m, uint32_t const ft, const consteval__consteval__LayoutEnv *const env, int32_t const depth) {
  const consteval__consteval__Layout fl = consteval__consteval__ConstEval__layout_of(self, m, ft, env, depth);
  if (!fl.ok) {
    return false;
  }
  uint64_t fa = fl.align;
  if ((*acc).packed) {
    (fa = 1ULL);
  }
  if ((*acc).is_union) {
    if (fl.size > (*acc).size) {
      ((*acc).size = fl.size);
    }
  } else {
    ((*acc).size = (consteval__consteval__round_up((*acc).size, fa) + fl.size));
  }
  if (fa > (*acc).align) {
    ((*acc).align = fa);
  }
  return true;
}

static __attribute__((unused)) consteval__consteval__Layout consteval__consteval__ConstEval__aggregate_layout(consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn, const consteval__consteval__LayoutEnv *const env, int32_t const depth) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, dm);
  const ast__ast__NodeKind dkind = ast__ast__Ast__at_const(&((*a)), dn)->kind;
  if (dkind == ast__ast__NodeKind_NODE_ENUM) {
    const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.members;
    bool payload = false;
    for (uint32_t i = 0U; i < ms.len; i++) {
      const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
      if (ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.payload.len > 0U) {
        (payload = true);
      }
    }
    if (!payload) {
      return (consteval__consteval__Layout){ .ok = true, .size = 4ULL, .align = 4ULL };
    }
    consteval__consteval__LayoutAcc un = (consteval__consteval__LayoutAcc){ .is_union = true };
    for (uint32_t i = 0U; i < ms.len; i++) {
      const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
      const ast__ast__NodeList pl = ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.payload;
      if (pl.len == 0U) {
        continue;
      }
      const bool struct_payload = ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.struct_payload;
      consteval__consteval__LayoutAcc vs = (consteval__consteval__LayoutAcc){0};
      for (uint32_t k = 0U; k < pl.len; k++) {
        const uint32_t pid = ast__ast__Ast__list(&((*a)), pl)[((size_t)k)];
        uint32_t tn = pid;
        if (struct_payload) {
          (tn = ast__ast__Ast__at_const(&((*a)), pid)->as_data.field.ty);
        }
        if (!consteval__consteval__ConstEval__acc_field(self, ((consteval__consteval__LayoutAcc *)(&vs)), dm, consteval__consteval__ConstEval__ce_type(self, dm, tn), env, depth)) {
          return (consteval__consteval__Layout){ .ok = false };
        }
      }
      (vs.size = consteval__consteval__round_up(vs.size, vs.align));
      if (vs.size > un.size) {
        (un.size = vs.size);
      }
      if (vs.align > un.align) {
        (un.align = vs.align);
      }
    }
    uint64_t ssize = (consteval__consteval__round_up(4ULL, un.align) + un.size);
    uint64_t salign = 4ULL;
    if (un.align > salign) {
      (salign = un.align);
    }
    return (consteval__consteval__Layout){ .ok = true, .size = consteval__consteval__round_up(ssize, salign), .align = salign };
  }
  if (dkind != ast__ast__NodeKind_NODE_STRUCT) {
    return (consteval__consteval__Layout){ .ok = false };
  }
  const bool is_union = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.is_union;
  const bool is_tuple = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.is_tuple;
  consteval__consteval__LayoutAcc acc = (consteval__consteval__LayoutAcc){ .is_union = is_union };
  (acc.packed = (consteval__consteval__ConstEval__ce_attr(self, dm, dn, ast__ast__AttrKind_ATTR_PACKED) != NULL));
  const ast__ast__NodeList fs = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.members;
  for (uint32_t i = 0U; i < fs.len; i++) {
    const uint32_t fid = ast__ast__Ast__list(&((*a)), fs)[((size_t)i)];
    const ast__ast__NodeKind fkind = ast__ast__Ast__at_const(&((*a)), fid)->kind;
    if ((!is_tuple) && (fkind != ast__ast__NodeKind_NODE_FIELD)) {
      continue;
    }
    uint32_t ftn = fid;
    if (!is_tuple) {
      (ftn = ast__ast__Ast__at_const(&((*a)), fid)->as_data.field.ty);
    }
    const uint32_t ft = consteval__consteval__ConstEval__ce_type(self, dm, ftn);
    if (ft == ast__ast__TYPE_NONE) {
      return (consteval__consteval__Layout){ .ok = false };
    }
    if (!consteval__consteval__ConstEval__acc_field(self, ((consteval__consteval__LayoutAcc *)(&acc)), dm, ft, env, depth)) {
      return (consteval__consteval__Layout){ .ok = false };
    }
  }
  const ast__ast__Attr *const al = consteval__consteval__ConstEval__ce_attr(self, dm, dn, ast__ast__AttrKind_ATTR_ALIGN);
  if ((al != NULL) && ((*al).arg != 0U)) {
    if (((uint64_t)(*al).arg) > acc.align) {
      (acc.align = ((uint64_t)(*al).arg));
    }
  }
  if (acc.align == 0ULL) {
    (acc.align = 1ULL);
  }
  return (consteval__consteval__Layout){ .ok = true, .size = consteval__consteval__round_up(acc.size, acc.align), .align = acc.align };
}

static __attribute__((unused)) consteval__consteval__Layout consteval__consteval__ConstEval__layout_of(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const t, const consteval__consteval__LayoutEnv *const env, int32_t const depth) {
  if ((depth > consteval__consteval__CE_MAX_DEPTH) || (t == ast__ast__TYPE_NONE)) {
    return (consteval__consteval__Layout){ .ok = false };
  }
  if (!consteval__consteval__ConstEval__has_ast(self, m)) {
    return (consteval__consteval__Layout){ .ok = false };
  }
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*a)), t));
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    const ast__ast__BuiltinType b = y.as_data.builtin;
    if ((((b == ast__ast__BuiltinType_BT_BOOL) || (b == ast__ast__BuiltinType_BT_CHAR)) || (b == ast__ast__BuiltinType_BT_I8)) || (b == ast__ast__BuiltinType_BT_U8)) {
      return (consteval__consteval__Layout){ .ok = true, .size = 1ULL, .align = 1ULL };
    }
    if ((b == ast__ast__BuiltinType_BT_I16) || (b == ast__ast__BuiltinType_BT_U16)) {
      return (consteval__consteval__Layout){ .ok = true, .size = 2ULL, .align = 2ULL };
    }
    if (((b == ast__ast__BuiltinType_BT_I32) || (b == ast__ast__BuiltinType_BT_U32)) || (b == ast__ast__BuiltinType_BT_F32)) {
      return (consteval__consteval__Layout){ .ok = true, .size = 4ULL, .align = 4ULL };
    }
    if (((((b == ast__ast__BuiltinType_BT_I64) || (b == ast__ast__BuiltinType_BT_U64)) || (b == ast__ast__BuiltinType_BT_ISIZE)) || (b == ast__ast__BuiltinType_BT_USIZE)) || (b == ast__ast__BuiltinType_BT_F64)) {
      return (consteval__consteval__Layout){ .ok = true, .size = 8ULL, .align = 8ULL };
    }
    if (b == ast__ast__BuiltinType_BT_C32) {
      return (consteval__consteval__Layout){ .ok = true, .size = 8ULL, .align = 4ULL };
    }
    if (b == ast__ast__BuiltinType_BT_C64) {
      return (consteval__consteval__Layout){ .ok = true, .size = 16ULL, .align = 8ULL };
    }
    return (consteval__consteval__Layout){ .ok = false };
  }
  if (((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
    return (consteval__consteval__Layout){ .ok = true, .size = 8ULL, .align = 8ULL };
  }
  if (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    if (y.as_data.arr.len == 0U) {
      return (consteval__consteval__Layout){ .ok = false };
    }
    const consteval__consteval__Layout el = consteval__consteval__ConstEval__layout_of(self, m, y.as_data.arr.elem, env, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    if (!el.ok) {
      return (consteval__consteval__Layout){ .ok = false };
    }
    return (consteval__consteval__Layout){ .ok = true, .size = (el.size * ((uint64_t)y.as_data.arr.len)), .align = el.align };
  }
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    const consteval__consteval__LayoutEnv *e = env;
    while (e != NULL) {
      for (uint8_t i = 0U; i < (*e).n; i++) {
        if (((*e).pmod == y.module) && ((*e).params[((size_t)i)] == y.as_data.decl)) {
          return consteval__consteval__ConstEval__layout_of(self, (*e).argm, (*e).args[((size_t)i)], (*e).parent, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
        }
      }
      (e = (*e).parent);
    }
    return (consteval__consteval__Layout){ .ok = false };
  }
  if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    return consteval__consteval__ConstEval__aggregate_layout(self, y.module, y.as_data.decl, NULL, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*a)), y.as_data.inst));
    if (!consteval__consteval__ConstEval__has_ast(self, it.module)) {
      return (consteval__consteval__Layout){ .ok = false };
    }
    const ast__ast__Ast *const da = consteval__consteval__ConstEval__ast_ptr(self, it.module);
    const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*da)), it.decl)->as_data.aggregate.generics;
    consteval__consteval__LayoutEnv frame = (consteval__consteval__LayoutEnv){ .parent = env, .pmod = it.module, .params = ast__ast__Ast__list(&((*da)), gens), .argm = m, .n = 0U };
    uint32_t i = 0U;
    while (((i < gens.len) && (((uint8_t)i) < it.n)) && (frame.n < 4U)) {
      (frame.args[((size_t)frame.n)] = it.args[((size_t)i)]);
      (frame.n = ((uint8_t)((uint32_t)frame.n + (uint32_t)1U)));
      (i = (i + 1U));
    }
    return consteval__consteval__ConstEval__aggregate_layout(self, it.module, it.decl, ((const consteval__consteval__LayoutEnv *)(&frame)), ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return (consteval__consteval__Layout){ .ok = false };
}

consteval__consteval__Layout consteval__consteval__ConstEval__layout(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const t) {
  return consteval__consteval__ConstEval__layout_of(self, m, t, NULL, 0);
}

static __attribute__((unused)) consteval__consteval__RType consteval__consteval__ConstEval__ce_rtype(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m0, uint32_t const t0) {
  uint16_t m = m0;
  uint32_t t = t0;
  for (int32_t _ = 0; _ < 8; _++) {
    if (t == ast__ast__TYPE_NONE) {
      return (consteval__consteval__RType){ .ok = false };
    }
    const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, m))), t);
    if (y->kind != ast__ast__TypeKind_TYPE_GENERIC) {
      return (consteval__consteval__RType){ .ok = true, .m = m, .t = t };
    }
    if (f == NULL) {
      return (consteval__consteval__RType){ .ok = false };
    }
    const uint16_t ymod = y->module;
    const uint32_t ydecl = y->as_data.decl;
    bool found = false;
    for (uint8_t i = 0U; i < (*f).ng; i++) {
      if (((*f).pmod == ymod) && ((*f).params_g[((size_t)i)] == ydecl)) {
        (m = (*f).am[((size_t)i)]);
        (t = (*f).at[((size_t)i)]);
        (found = true);
        break;
      }
    }
    if (!found) {
      return (consteval__consteval__RType){ .ok = false };
    }
  }
  return (consteval__consteval__RType){ .ok = false };
}

static __attribute__((unused)) ast__ast__BuiltinType consteval__consteval__ConstEval__ce_builtin_of(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const t) {
  const consteval__consteval__RType r = consteval__consteval__ConstEval__ce_rtype(self, f, m, t);
  if (!r.ok) {
    return ast__ast__BuiltinType_BT_COUNT;
  }
  return consteval__consteval__type_builtin(consteval__consteval__ConstEval__ast_ptr(self, r.m), r.t);
}

static __attribute__((unused)) consteval__consteval__Layout consteval__consteval__ConstEval__ce_layout_f(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const t) {
  if (f == NULL) {
    return consteval__consteval__ConstEval__layout_of(self, m, t, NULL, 0);
  }
  consteval__consteval__LayoutEnv envs[8] = { (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U }, (consteval__consteval__LayoutEnv){ .pmod = 0U } };
  const consteval__consteval__LayoutEnv *parent = NULL;
  for (uint8_t i = 0U; i < (*f).ng; i++) {
    (envs[__sc_bounds(((size_t)i), 8)] = (consteval__consteval__LayoutEnv){ .parent = parent, .pmod = (*f).pmod, .params = ((const uint32_t *)(&(*f).params_g[((size_t)i)])), .argm = (*f).am[((size_t)i)], .n = 1U });
    (envs[__sc_bounds(((size_t)i), 8)].args[0] = (*f).at[((size_t)i)]);
    (parent = ((const consteval__consteval__LayoutEnv *)(&envs[__sc_bounds(((size_t)i), 8)])));
  }
  return consteval__consteval__ConstEval__layout_of(self, m, t, parent, 0);
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_teq(const consteval__consteval__ConstEval *const self, uint16_t const ma, uint32_t const ta, uint16_t const mb, uint32_t const tb) {
  if ((ta == ast__ast__TYPE_NONE) || (tb == ast__ast__TYPE_NONE)) {
    return false;
  }
  const ast__ast__Ast *const aa = consteval__consteval__ConstEval__ast_ptr(self, ma);
  const ast__ast__Ast *const ab = consteval__consteval__ConstEval__ast_ptr(self, mb);
  const ast__ast__Ty a = (*ast__ast__Ast__type_at(&((*aa)), ta));
  const ast__ast__Ty b = (*ast__ast__Ast__type_at(&((*ab)), tb));
  if (a.kind != b.kind) {
    return false;
  }
  if (a.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    return (a.as_data.builtin == b.as_data.builtin);
  }
  if ((a.kind == ast__ast__TypeKind_TYPE_POINTER) || (a.kind == ast__ast__TypeKind_TYPE_REFERENCE)) {
    return ((a.qualifier == b.qualifier) && consteval__consteval__ConstEval__ce_teq(self, ma, a.as_data.elem, mb, b.as_data.elem));
  }
  if (a.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    return ((a.as_data.arr.len == b.as_data.arr.len) && consteval__consteval__ConstEval__ce_teq(self, ma, a.as_data.arr.elem, mb, b.as_data.arr.elem));
  }
  if ((((a.kind == ast__ast__TypeKind_TYPE_STRUCT) || (a.kind == ast__ast__TypeKind_TYPE_ENUM)) || (a.kind == ast__ast__TypeKind_TYPE_GENERIC)) || (a.kind == ast__ast__TypeKind_TYPE_OPAQUE)) {
    return ((a.module == b.module) && (a.as_data.decl == b.as_data.decl));
  }
  if (a.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance ia = (*ast__ast__Ast__instance(&((*aa)), a.as_data.inst));
    const ast__ast__TyInstance ib = (*ast__ast__Ast__instance(&((*ab)), b.as_data.inst));
    if (((ia.module != ib.module) || (ia.decl != ib.decl)) || (ia.n != ib.n)) {
      return false;
    }
    for (uint8_t i = 0U; i < ia.n; i++) {
      if (!consteval__consteval__ConstEval__ce_teq(self, ma, ia.args[((size_t)i)], mb, ib.args[((size_t)i)])) {
        return false;
      }
    }
    return true;
  }
  return false;
}

static __attribute__((unused)) consteval__consteval__RType consteval__consteval__ConstEval__ce_strip_refptr(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m0, uint32_t const t0) {
  uint16_t m = m0;
  uint32_t t = t0;
  for (int32_t _ = 0; _ < 8; _++) {
    const consteval__consteval__RType r = consteval__consteval__ConstEval__ce_rtype(self, f, m, t);
    if (!r.ok) {
      return (consteval__consteval__RType){ .ok = false };
    }
    (m = r.m);
    (t = r.t);
    const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, m))), t);
    if ((y->kind != ast__ast__TypeKind_TYPE_REFERENCE) && (y->kind != ast__ast__TypeKind_TYPE_POINTER)) {
      return (consteval__consteval__RType){ .ok = true, .m = m, .t = t };
    }
    (t = y->as_data.elem);
  }
  return (consteval__consteval__RType){ .ok = false };
}

static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_subst_deep(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const t, int32_t const depth) {
  if ((t == ast__ast__TYPE_NONE) || (depth > consteval__consteval__CE_MAX_DEPTH)) {
    return ast__ast__TYPE_NONE;
  }
  ast__ast__Ast *const am = consteval__consteval__ConstEval__mut_ast_ptr(self, m);
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*am)), t));
  if (y.kind == ast__ast__TypeKind_TYPE_GENERIC) {
    if (f == NULL) {
      return ast__ast__TYPE_NONE;
    }
    for (uint8_t i = 0U; i < (*f).ng; i++) {
      if (((*f).pmod == y.module) && ((*f).params_g[((size_t)i)] == y.as_data.decl)) {
        const uint16_t fam = (*f).am[((size_t)i)];
        const uint32_t fat = (*f).at[((size_t)i)];
        if (fam == m) {
          return fat;
        }
        return ast__ast__Ast__reintern(&((*am)), (&(*consteval__consteval__ConstEval__ast_ptr(self, fam))), fat);
      }
    }
    return ast__ast__TYPE_NONE;
  }
  if (((y.kind == ast__ast__TypeKind_TYPE_POINTER) || (y.kind == ast__ast__TypeKind_TYPE_REFERENCE)) || (y.kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    const uint32_t e = consteval__consteval__ConstEval__ce_subst_deep(self, f, m, y.as_data.elem, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    if (e == ast__ast__TYPE_NONE) {
      return ast__ast__TYPE_NONE;
    }
    if (e == y.as_data.elem) {
      return t;
    }
    ast__ast__Ty ny = y;
    if (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
      (ny.as_data.arr = (ast__ast__TyArr){ .elem = e, .len = y.as_data.arr.len });
    } else {
      (ny.as_data.elem = e);
    }
    return ast__ast__Ast__intern_type(&((*consteval__consteval__ConstEval__mut_ast_ptr(self, m))), ny);
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*am)), y.as_data.inst));
    uint32_t na[4] = { 0U, 0U, 0U, 0U };
    bool changed = false;
    for (uint8_t i = 0U; i < it.n; i++) {
      (na[__sc_bounds(((size_t)i), 4)] = consteval__consteval__ConstEval__ce_subst_deep(self, f, m, it.args[((size_t)i)], ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })));
      if (na[__sc_bounds(((size_t)i), 4)] == ast__ast__TYPE_NONE) {
        return ast__ast__TYPE_NONE;
      }
      if (na[__sc_bounds(((size_t)i), 4)] != it.args[((size_t)i)]) {
        (changed = true);
      }
    }
    if (!changed) {
      return t;
    }
    return ast__ast__Ast__intern_instance(&((*consteval__consteval__ConstEval__mut_ast_ptr(self, m))), it.module, it.decl, ((const uint32_t *)(&na[0])), it.n);
  }
  return t;
}

static __attribute__((unused)) consteval__consteval__RecvRes consteval__consteval__ConstEval__ce_recv_of(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m0, uint32_t const t0) {
  consteval__consteval__CeRecv out = consteval__consteval__ce_recv_zero();
  const consteval__consteval__RType r = consteval__consteval__ConstEval__ce_rtype(self, f, m0, t0);
  if (!r.ok) {
    return (consteval__consteval__RecvRes){ .ok = false, .r = out };
  }
  const uint16_t m = r.m;
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, m))), r.t));
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    (out.dn = ast__ast__NODE_NONE);
    (out.b = y.as_data.builtin);
    return (consteval__consteval__RecvRes){ .ok = true, .r = out };
  }
  if ((y.kind == ast__ast__TypeKind_TYPE_STRUCT) || (y.kind == ast__ast__TypeKind_TYPE_ENUM)) {
    (out.dm = y.module);
    (out.dn = y.as_data.decl);
    return (consteval__consteval__RecvRes){ .ok = true, .r = out };
  }
  if (y.kind == ast__ast__TypeKind_TYPE_INSTANCE) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*consteval__consteval__ConstEval__ast_ptr(self, m))), y.as_data.inst));
    (out.dm = it.module);
    (out.dn = it.decl);
    (out.n = it.n);
    for (uint8_t i = 0U; i < it.n; i++) {
      (out.am[((size_t)i)] = m);
      (out.at[((size_t)i)] = consteval__consteval__ConstEval__ce_subst_deep(self, f, m, it.args[((size_t)i)], 0));
      if ((out.at[((size_t)i)] == ast__ast__TYPE_NONE) || (!ast__ast__Ast__type_concrete(&((*consteval__consteval__ConstEval__ast_ptr(self, m))), out.at[((size_t)i)]))) {
        return (consteval__consteval__RecvRes){ .ok = false, .r = out };
      }
    }
    return (consteval__consteval__RecvRes){ .ok = true, .r = out };
  }
  return (consteval__consteval__RecvRes){ .ok = false, .r = out };
}

static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_field_count(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, dm);
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.members;
  uint32_t n = 0U;
  for (uint32_t i = 0U; i < ms.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), mid)->kind == ast__ast__NodeKind_NODE_FIELD) {
      (n = (n + 1U));
    }
  }
  return n;
}

static __attribute__((unused)) consteval__consteval__FieldIdx consteval__consteval__ConstEval__ce_field_index(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn, uint16_t const nm, lexer__token__Span const name) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, dm);
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.members;
  int32_t idx = 0;
  for (uint32_t i = 0U; i < ms.len; i++) {
    const uint32_t fid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), fid)->kind == ast__ast__NodeKind_NODE_FIELD) {
      const lexer__token__Span fname = consteval__consteval__ConstEval__name_text(self, dm, ast__ast__Ast__at_const(&((*a)), fid)->as_data.field.name);
      if (consteval__consteval__ConstEval__ce_spans_eq(self, dm, fname, nm, name)) {
        return (consteval__consteval__FieldIdx){ .idx = idx, .field = fid };
      }
      (idx = ({ int32_t __sc_r; if (__builtin_add_overflow(idx, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
  }
  return (consteval__consteval__FieldIdx){ .idx = -1, .field = ast__ast__NODE_NONE };
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_enum_tagged(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, dm);
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.members;
  for (uint32_t i = 0U; i < ms.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.payload.len > 0U) {
      return true;
    }
  }
  return false;
}

static __attribute__((unused)) consteval__consteval__VarPos consteval__consteval__ConstEval__ce_variant_pos(const consteval__consteval__ConstEval *const self, uint16_t const vm, uint32_t const vd) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, vm);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_ENUM) {
      const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.aggregate.members;
      for (uint32_t k = 0U; k < ms.len; k++) {
        const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)k)];
        if (mid == vd) {
          return (consteval__consteval__VarPos){ .pos = ((int32_t)k), .enum_decl = iid };
        }
      }
    }
  }
  return (consteval__consteval__VarPos){ .pos = -1, .enum_decl = ast__ast__NODE_NONE };
}

static __attribute__((unused)) int32_t consteval__consteval__ConstEval__ce_variant_named(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn, str const lit) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, dm);
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), dn)->as_data.aggregate.members;
  for (uint32_t i = 0U; i < ms.len; i++) {
    const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)i)];
    const lexer__token__Span vname = consteval__consteval__ConstEval__name_text(self, dm, ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.name);
    if (consteval__consteval__ConstEval__ce_span_is(self, dm, vname, lit)) {
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_pool_find_type(const consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, dm);
  uint32_t t = 1U;
  while (((size_t)t) < Vector__ast__ast__Ty__Global__len(&(*a).type_pool)) {
    const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*a)), t);
    if ((((y->kind == ast__ast__TypeKind_TYPE_STRUCT) || (y->kind == ast__ast__TypeKind_TYPE_ENUM)) && (y->module == dm)) && (y->as_data.decl == dn)) {
      return t;
    }
    (t = (t + 1U));
  }
  return ast__ast__TYPE_NONE;
}

static __attribute__((unused)) int32_t consteval__consteval__ConstEval__ce_container_of(const consteval__consteval__ConstEval *const self, uint16_t const fm, uint32_t const fnode, uint32_t *const out) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, fm);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    const ast__ast__NodeKind ik = ast__ast__Ast__at_const(&((*a)), iid)->kind;
    ast__ast__NodeList ms = (ast__ast__NodeList){ .start = 0U, .len = 0U };
    bool is_ext = false;
    if (ik == ast__ast__NodeKind_NODE_EXTEND) {
      (ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items);
      (is_ext = true);
    } else if (ik == ast__ast__NodeKind_NODE_INTERFACE) {
      (ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.interface_def.items);
    } else {
      continue;
    }
    for (uint32_t k = 0U; k < ms.len; k++) {
      const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)k)];
      if (mid == fnode) {
        if (out != NULL) {
          ((*out) = iid);
        }
        if (is_ext) {
          return 1;
        }
        return 2;
      }
    }
  }
  return 0;
}

static __attribute__((unused)) ast__ast__DefId consteval__consteval__ConstEval__ce_find_method(const consteval__consteval__ConstEval *const self, consteval__consteval__CeRecv const r, uint16_t const scope, uint16_t const nm, lexer__token__Span const name, str const lit, uint32_t *const extend_out) {
  uint16_t first = scope;
  if (r.dn != ast__ast__NODE_NONE) {
    (first = r.dm);
  }
  for (size_t s = 0ULL; s < (self->nmods + 2ULL); s++) {
    uint16_t mm = 0U;
    if (s == 0ULL) {
      (mm = first);
    } else if (s == 1ULL) {
      (mm = scope);
    } else if (r.dn == ast__ast__NODE_NONE) {
      (mm = ((uint16_t)(s - 2ULL)));
    } else {
      break;
    }
    if ((s == 1ULL) && (mm == first)) {
      continue;
    }
    if (!consteval__consteval__ConstEval__has_ast(self, mm)) {
      continue;
    }
    const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, mm);
    if (Vector__ast__ast__Node__Global__len(&(*a).nodes) == 0ULL) {
      continue;
    }
    const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
    for (uint32_t i = 0U; i < items.len; i++) {
      const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
      const uint32_t target = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.target_type;
      if ((ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_EXTEND) && (target != ast__ast__NODE_NONE)) {
        bool match_recv = false;
        if (r.dn != ast__ast__NODE_NONE) {
          const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), target);
          (match_recv = ((tg.module == r.dm) && (tg.node == r.dn)));
        } else {
          const uint32_t tt = consteval__consteval__ConstEval__ce_type(self, mm, target);
          if (tt != ast__ast__TYPE_NONE) {
            const ast__ast__Ty *const ty = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, mm))), tt);
            (match_recv = ((ty->kind == ast__ast__TypeKind_TYPE_BUILTIN) && (ty->as_data.builtin == r.b)));
          }
        }
        if (match_recv) {
          const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
          for (uint32_t k = 0U; k < ms.len; k++) {
            const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)k)];
            if (ast__ast__Ast__at_const(&((*a)), mid)->kind == ast__ast__NodeKind_NODE_FUNCTION) {
              const lexer__token__Span mname = consteval__consteval__ConstEval__name_text(self, mm, ast__ast__Ast__at_const(&((*a)), mid)->as_data.function.name);
              bool hit = false;
              if (str__len(&lit) != 0ULL) {
                (hit = consteval__consteval__ConstEval__ce_span_is(self, mm, mname, lit));
              } else {
                (hit = consteval__consteval__ConstEval__ce_spans_eq(self, mm, mname, nm, name));
              }
              if (hit) {
                if (extend_out != NULL) {
                  ((*extend_out) = iid);
                }
                return (ast__ast__DefId){ .module = mm, .node = mid };
              }
            }
          }
        }
      }
    }
  }
  return (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_user_free(consteval__consteval__ConstEval *const self, uint16_t const dm, uint32_t const dn) {
  for (size_t i = 0ULL; i < Vector__consteval__consteval__UFree__Global__len(&self->ufree); i++) {
    const consteval__consteval__UFree *const u = Vector__consteval__consteval__UFree__Global__at(&self->ufree, i);
    if ((u->m == dm) && (u->n == dn)) {
      return u->user;
    }
  }
  bool user = false;
  size_t mm = 0ULL;
  while ((mm < self->nmods) && (!user)) {
    if ((!consteval__consteval__ConstEval__is_prelude(self, ((uint16_t)mm))) && consteval__consteval__ConstEval__has_ast(self, ((uint16_t)mm))) {
      const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, ((uint16_t)mm));
      if (Vector__ast__ast__Node__Global__len(&(*a).nodes) != 0ULL) {
        const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
        uint32_t ii = 0U;
        while ((ii < items.len) && (!user)) {
          const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)ii)];
          const uint32_t target = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.target_type;
          if ((ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_EXTEND) && (target != ast__ast__NODE_NONE)) {
            const ast__ast__DefId tg = ast__ast__Ast__resolution_def(&((*a)), target);
            if ((tg.module == dm) && (tg.node == dn)) {
              const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.extend_def.items;
              for (uint32_t k = 0U; k < ms.len; k++) {
                const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)k)];
                if (ast__ast__Ast__at_const(&((*a)), mid)->kind == ast__ast__NodeKind_NODE_FUNCTION) {
                  const lexer__token__Span mname = consteval__consteval__ConstEval__name_text(self, ((uint16_t)mm), ast__ast__Ast__at_const(&((*a)), mid)->as_data.function.name);
                  if (consteval__consteval__ConstEval__ce_span_is(self, ((uint16_t)mm), mname, (str){ (const uint8_t *)"free", sizeof("free") - 1 })) {
                    (user = true);
                    break;
                  }
                }
              }
            }
          }
          (ii = (ii + 1U));
        }
      }
    }
    (mm = (mm + 1ULL));
  }
  Vector__consteval__consteval__UFree__Global__push(&self->ufree, (consteval__consteval__UFree){ .m = dm, .n = dn, .user = user });
  return user;
}

static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__ConstEval__variant_value(consteval__consteval__ConstEval *const self, uint16_t const vm, uint32_t const vd) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, vm);
  const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
  for (uint32_t i = 0U; i < items.len; i++) {
    const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
    if (ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_ENUM) {
      const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*a)), iid)->as_data.aggregate.members;
      int64_t next = 0;
      for (uint32_t k = 0U; k < ms.len; k++) {
        const uint32_t mid = ast__ast__Ast__list(&((*a)), ms)[((size_t)k)];
        if (ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.payload.len > 0U) {
          return consteval__consteval__ce_none();
        }
        const uint32_t vval = ast__ast__Ast__at_const(&((*a)), mid)->as_data.variant.value;
        if (vval != ast__ast__NODE_NONE) {
          const consteval__consteval__ConstValue e = consteval__consteval__ConstEval__eval(self, vm, vval);
          if (e.kind != consteval__consteval__CONST_INT) {
            return consteval__consteval__ce_none();
          }
          (next = e.as_data.i);
        }
        if (mid == vd) {
          return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_INT, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__ConstValueAs){ .i = next } };
        }
        (next = ({ int64_t __sc_r; if (__builtin_add_overflow(next, 1LL, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      }
    }
  }
  return consteval__consteval__ce_none();
}

static __attribute__((unused)) void consteval__consteval__ConstEval__ce_objs_reset(consteval__consteval__ConstEval *const self) {
  Vector__consteval__consteval__CeObj__Global__clear(&self->objs);
  (self->live_slots = 0ULL);
}

static __attribute__((unused)) consteval__consteval__CeObj *consteval__consteval__ConstEval__obj_ptr(const consteval__consteval__ConstEval *const self, uint32_t const id) {
  if ((id == 0U) || (((size_t)id) > Vector__consteval__consteval__CeObj__Global__len(&self->objs))) {
    return NULL;
  }
  return (((consteval__consteval__CeObj *)Vector__consteval__consteval__CeObj__Global__as_ptr(&self->objs)) + ((size_t)(id - 1U)));
}

static __attribute__((unused)) uint32_t consteval__consteval__ConstEval__ce_obj_new(consteval__consteval__ConstEval *const self, uint32_t const len) {
  if ((((uint32_t)Vector__consteval__consteval__CeObj__Global__len(&self->objs)) >= consteval__consteval__CE_MAX_OBJS) || ((self->live_slots + ((uint64_t)len)) > self->max_slots)) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"const-eval memory budget exceeded", sizeof("const-eval memory budget exceeded") - 1 });
    return 0U;
  }
  Vector__consteval__consteval__CeVal__Global slots = Vector__consteval__consteval__CeVal__Global__new();
  if (len != 0U) {
    Vector__consteval__consteval__CeVal__Global__reserve(&slots, ((size_t)len));
    for (uint32_t _ = 0U; _ < len; _++) {
      Vector__consteval__consteval__CeVal__Global__push(&slots, consteval__consteval__cv_nil());
    }
  }
  Vector__consteval__consteval__CeObj__Global__push(&self->objs, (consteval__consteval__CeObj){ .slots = slots });
  (self->live_slots = (self->live_slots + ((uint64_t)len)));
  return ((uint32_t)Vector__consteval__consteval__CeObj__Global__len(&self->objs));
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_obj_resize(consteval__consteval__ConstEval *const self, uint32_t const id, uint32_t const len) {
  const uint32_t cur = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, id)).slots));
  if ((len > cur) && ((self->live_slots + ((uint64_t)(len - cur))) > self->max_slots)) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"const-eval memory budget exceeded", sizeof("const-eval memory budget exceeded") - 1 });
    return false;
  }
  consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, id);
  if (len > cur) {
    uint32_t i = cur;
    while (i < len) {
      Vector__consteval__consteval__CeVal__Global__push(&(*o).slots, consteval__consteval__cv_nil());
      (i = (i + 1U));
    }
    (self->live_slots = (self->live_slots + ((uint64_t)(len - cur))));
  } else if (len < cur) {
    Vector__consteval__consteval__CeVal__Global__truncate(&(*o).slots, ((size_t)len));
  }
  return true;
}

static __attribute__((unused)) consteval__consteval__CeVal *consteval__consteval__ConstEval__ce_bind_slot(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint32_t const decl) {
  const int32_t i = consteval__consteval__ce_local_find(f, decl);
  const uint32_t envid = (*f).env;
  if (consteval__consteval__ConstEval__obj_ptr(self, envid) == NULL) {
    return NULL;
  }
  if (i >= 0) {
    const uint32_t slotidx = (*f).locals[((size_t)i)].slot;
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, envid);
    return (((consteval__consteval__CeVal *)Vector__consteval__consteval__CeVal__Global__as_ptr(&(*o).slots)) + ((size_t)slotidx));
  }
  if ((*f).n >= consteval__consteval__CE_MAX_LOCALS) {
    return NULL;
  }
  const uint32_t curlen = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, envid)).slots));
  if (!consteval__consteval__ConstEval__ce_obj_resize(self, envid, (curlen + 1U))) {
    return NULL;
  }
  const uint32_t n = (*f).n;
  ((*f).locals[((size_t)n)].decl = decl);
  ((*f).locals[((size_t)n)].slot = curlen);
  ((*f).n = (n + 1U));
  consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, envid);
  return (((consteval__consteval__CeVal *)Vector__consteval__consteval__CeVal__Global__as_ptr(&(*o).slots)) + ((size_t)curlen));
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_bind(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint32_t const decl, consteval__consteval__CeVal const v) {
  consteval__consteval__CeVal *const s = consteval__consteval__ConstEval__ce_bind_slot(self, f, decl);
  if (s == NULL) {
    return false;
  }
  const consteval__consteval__CeVal cv = consteval__consteval__ConstEval__ce_clone(self, v, 0);
  ((*s) = cv);
  return ((v.kind == consteval__consteval__CV_NIL_K) || ((*s).kind != consteval__consteval__CV_NIL_K));
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_clone(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const v, int32_t const depth) {
  if ((v.kind != consteval__consteval__CV_AGG) || (depth > consteval__consteval__CE_MAX_DEPTH)) {
    if ((v.kind == consteval__consteval__CV_AGG) && (depth > consteval__consteval__CE_MAX_DEPTH)) {
      return consteval__consteval__cv_nil();
    }
    return v;
  }
  consteval__consteval__CeObj *const srcp = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
  if ((srcp == NULL) || ((*srcp).dead != 0U)) {
    return consteval__consteval__cv_nil();
  }
  const uint32_t srclen = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*srcp).slots));
  const uint32_t id = consteval__consteval__ConstEval__ce_obj_new(self, srclen);
  if (id == 0U) {
    return consteval__consteval__cv_nil();
  }
  consteval__consteval__CeObj *const src = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
  consteval__consteval__CeObj *const dst = consteval__consteval__ConstEval__obj_ptr(self, id);
  {
    ((*dst).dead = (*src).dead);
    ((*dst).is_enum = (*src).is_enum);
    ((*dst).heap = (*src).heap);
    ((*dst).dm = (*src).dm);
    ((*dst).dn = (*src).dn);
    ((*dst).nargs = (*src).nargs);
    ((*dst).bytes = (*src).bytes);
    ((*dst).em = (*src).em);
    ((*dst).et = (*src).et);
    ((*dst).esz = (*src).esz);
    for (int32_t j = 0; j < 4; j++) {
      ((*dst).am[j] = (*src).am[j]);
      ((*dst).at[j] = (*src).at[j]);
    }
  }
  for (uint32_t i = 0U; i < srclen; i++) {
    const consteval__consteval__CeVal sv = (*({ __auto_type __sc92 = &(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots; Vector__consteval__consteval__CeVal__Global__index(__sc92, ((size_t)i)); }));
    const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, sv, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    if ((sv.kind != consteval__consteval__CV_NIL_K) && (cloned.kind == consteval__consteval__CV_NIL_K)) {
      return consteval__consteval__cv_nil();
    }
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, id)).slots, ((size_t)i), cloned);
  }
  consteval__consteval__CeVal out = v;
  (out.as_data.p.obj = id);
  return out;
}

static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ce_loadp(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const p) {
  if (p.kind != consteval__consteval__CV_PTR) {
    return (consteval__consteval__ValRes){ .ok = false };
  }
  if (p.as_data.p.obj == 0U) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"null dereference", sizeof("null dereference") - 1 });
    return (consteval__consteval__ValRes){ .ok = false };
  }
  consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, p.as_data.p.obj);
  if (o == NULL) {
    return (consteval__consteval__ValRes){ .ok = false };
  }
  if ((*o).dead != 0U) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"use after free", sizeof("use after free") - 1 });
    return (consteval__consteval__ValRes){ .ok = false };
  }
  if (((size_t)p.as_data.p.off) >= Vector__consteval__consteval__CeVal__Global__len(&(*o).slots)) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"out-of-bounds access", sizeof("out-of-bounds access") - 1 });
    return (consteval__consteval__ValRes){ .ok = false };
  }
  const consteval__consteval__CeVal out = (*({ __auto_type __sc93 = &(*o).slots; Vector__consteval__consteval__CeVal__Global__index(__sc93, ((size_t)p.as_data.p.off)); }));
  return (consteval__consteval__ValRes){ .ok = (out.kind != consteval__consteval__CV_NIL_K), .v = out };
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_storep(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const p, consteval__consteval__CeVal const v) {
  if ((p.kind != consteval__consteval__CV_PTR) || (v.kind == consteval__consteval__CV_NIL_K)) {
    return false;
  }
  if (p.as_data.p.obj == 0U) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"null dereference", sizeof("null dereference") - 1 });
    return false;
  }
  const consteval__consteval__CeVal cv = consteval__consteval__ConstEval__ce_clone(self, v, 0);
  if (cv.kind == consteval__consteval__CV_NIL_K) {
    return false;
  }
  consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, p.as_data.p.obj);
  if (o == NULL) {
    return false;
  }
  if ((*o).dead != 0U) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"use after free", sizeof("use after free") - 1 });
    return false;
  }
  if (((size_t)p.as_data.p.off) >= Vector__consteval__consteval__CeVal__Global__len(&(*o).slots)) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"out-of-bounds access", sizeof("out-of-bounds access") - 1 });
    return false;
  }
  Vector__consteval__consteval__CeVal__Global__set(&(*o).slots, ((size_t)p.as_data.p.off), cv);
  return true;
}

static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ce_temp_place(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const v) {
  const uint32_t id = consteval__consteval__ConstEval__ce_obj_new(self, 1U);
  if ((id == 0U) || (v.kind == consteval__consteval__CV_NIL_K)) {
    return (consteval__consteval__ValRes){ .ok = false };
  }
  Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, id)).slots, 0ULL, v);
  return (consteval__consteval__ValRes){ .ok = true, .v = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = id, .off = 0U } } } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_zero(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const t, int32_t const depth) {
  if ((depth > consteval__consteval__CE_MAX_DEPTH) || (t == ast__ast__TYPE_NONE)) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, m))), t));
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    const ast__ast__BuiltinType b = y.as_data.builtin;
    if (b == ast__ast__BuiltinType_BT_BOOL) {
      return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_BOOL, .tm = m, .ty = t, .as_data = (consteval__consteval__CeValAs){ .i = 0 } };
    }
    if ((b == ast__ast__BuiltinType_BT_F32) || (b == ast__ast__BuiltinType_BT_F64)) {
      return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FLOAT, .tm = m, .ty = t, .as_data = (consteval__consteval__CeValAs){ .f = 0.0 } };
    }
    if ((((b == ast__ast__BuiltinType_BT_C32) || (b == ast__ast__BuiltinType_BT_C64)) || (b == ast__ast__BuiltinType_BT_VALIST)) || (b == ast__ast__BuiltinType_BT_VOID)) {
      return consteval__consteval__cv_nil();
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = t, .as_data = (consteval__consteval__CeValAs){ .i = 0 } };
  }
  if (y.kind == ast__ast__TypeKind_TYPE_POINTER) {
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = m, .ty = t, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = 0U, .off = 0U } } };
  }
  if (y.kind == ast__ast__TypeKind_TYPE_ARRAY) {
    if (y.as_data.arr.len == 0U) {
      return consteval__consteval__cv_nil();
    }
    const uint32_t id = consteval__consteval__ConstEval__ce_obj_new(self, y.as_data.arr.len);
    if (id == 0U) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal ez = consteval__consteval__ConstEval__ce_zero(self, m, y.as_data.arr.elem, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    if (ez.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    const uint32_t alen = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, id)).slots));
    for (uint32_t i = 0U; i < alen; i++) {
      const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, ez, ({ int32_t __sc_r; if (__builtin_add_overflow(depth, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, id)).slots, ((size_t)i), cloned);
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = t, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = id, .off = 0U } } };
  }
  return consteval__consteval__cv_nil();
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_int_op(consteval__consteval__ConstEval *const self, lexer__token_type__TokenType const op, consteval__consteval__CeVal const l, consteval__consteval__CeVal const r, uint16_t const tm, uint32_t const rt, ast__ast__BuiltinType const b, ast__ast__BuiltinType const ob) {
  const bool uns = ((ob != ast__ast__BuiltinType_BT_COUNT) && consteval__consteval__bt_unsigned(ob));
  if (op == lexer__token_type__TokenType_EqualEqual) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.i == r.as_data.i));
  }
  if (op == lexer__token_type__TokenType_BangEqual) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.i != r.as_data.i));
  }
  if (op == lexer__token_type__TokenType_LessThan) {
    return consteval__consteval__cv_bool(tm, rt, consteval__consteval__if_bool(uns, (((uint64_t)l.as_data.i) < ((uint64_t)r.as_data.i)), (l.as_data.i < r.as_data.i)));
  }
  if (op == lexer__token_type__TokenType_LessThanEqual) {
    return consteval__consteval__cv_bool(tm, rt, consteval__consteval__if_bool(uns, (((uint64_t)l.as_data.i) <= ((uint64_t)r.as_data.i)), (l.as_data.i <= r.as_data.i)));
  }
  if (op == lexer__token_type__TokenType_GreaterThan) {
    return consteval__consteval__cv_bool(tm, rt, consteval__consteval__if_bool(uns, (((uint64_t)l.as_data.i) > ((uint64_t)r.as_data.i)), (l.as_data.i > r.as_data.i)));
  }
  if (op == lexer__token_type__TokenType_GreaterThanEqual) {
    return consteval__consteval__cv_bool(tm, rt, consteval__consteval__if_bool(uns, (((uint64_t)l.as_data.i) >= ((uint64_t)r.as_data.i)), (l.as_data.i >= r.as_data.i)));
  }
  int32_t bits = 64;
  if (ob != ast__ast__BuiltinType_BT_COUNT) {
    (bits = consteval__consteval__bt_bits(ob));
  }
  int64_t v = 0;
  if (uns) {
    const uint64_t ul = ((uint64_t)l.as_data.i);
    const uint64_t ur = ((uint64_t)r.as_data.i);
    uint64_t u = 0ULL;
    {
      const lexer__token_type__TokenType __sc94 = op;
      if (__sc94 == lexer__token_type__TokenType_Plus) {
        {
          (u = (ul + ur));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Minus) {
        {
          (u = (ul - ur));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Star) {
        {
          (u = (ul * ur));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Slash) {
        {
          if (ur == 0ULL) {
            consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"division by zero", sizeof("division by zero") - 1 });
            return consteval__consteval__cv_nil();
          }
          (u = ({ uint64_t __sc95 = ul; uint64_t __sc96 = ur; if (__sc96 == 0) { __sc_panic("divide by zero"); } (__sc95 / __sc96); }));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Percent) {
        {
          if (ur == 0ULL) {
            consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"division by zero", sizeof("division by zero") - 1 });
            return consteval__consteval__cv_nil();
          }
          (u = ({ uint64_t __sc97 = ul; uint64_t __sc98 = ur; if (__sc98 == 0) { __sc_panic("divide by zero"); } (__sc97 % __sc98); }));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Ampersand) {
        {
          (u = (ul & ur));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Pipe) {
        {
          (u = (ul | ur));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_Caret) {
        {
          (u = (ul ^ ur));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_LeftShift) {
        {
          if ((r.as_data.i < 0) || (r.as_data.i >= ((int64_t)bits))) {
            consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"shift out of range", sizeof("shift out of range") - 1 });
            return consteval__consteval__cv_nil();
          }
          (u = ({ uint64_t __sc99 = ul; int64_t __sc100 = (int64_t)(((uint64_t)r.as_data.i)); if ((uint64_t)__sc100 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc99 << __sc100)); }));
        }
      }
      else if (__sc94 == lexer__token_type__TokenType_RightShift) {
        {
          if ((r.as_data.i < 0) || (r.as_data.i >= ((int64_t)bits))) {
            consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"shift out of range", sizeof("shift out of range") - 1 });
            return consteval__consteval__cv_nil();
          }
          (u = ({ uint64_t __sc101 = ul; int64_t __sc102 = (int64_t)(((uint64_t)r.as_data.i)); if ((uint64_t)__sc102 >= 64) { __sc_panic("shift out of range"); } (uint64_t)(__sc101 >> __sc102); }));
        }
      }
      else if (1) {
        {
          return consteval__consteval__cv_nil();
        }
      }
    }
    (v = consteval__consteval__wrap_to(ob, ((int64_t)u)));
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = tm, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = v } };
  }
  const int64_t li = l.as_data.i;
  const int64_t ri = r.as_data.i;
  int64_t type_min = consteval__consteval__I64_MIN;
  if (bits != 64) {
    (type_min = (-((int64_t)({ uint64_t __sc103 = 1ULL; int64_t __sc104 = (int64_t)(((uint64_t)({ int32_t __sc_r; if (__builtin_sub_overflow(bits, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))); if ((uint64_t)__sc104 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc103 << __sc104)); }))));
  }
  {
    const lexer__token_type__TokenType __sc105 = op;
    if (__sc105 == lexer__token_type__TokenType_Plus) {
      {
        const consteval__consteval__OvfRes o = consteval__consteval__add_ovf(li, ri);
        if (o.ovf) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"arithmetic overflow", sizeof("arithmetic overflow") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = o.v);
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Minus) {
      {
        const consteval__consteval__OvfRes o = consteval__consteval__sub_ovf(li, ri);
        if (o.ovf) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"arithmetic overflow", sizeof("arithmetic overflow") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = o.v);
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Star) {
      {
        const consteval__consteval__OvfRes o = consteval__consteval__mul_ovf(li, ri);
        if (o.ovf) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"arithmetic overflow", sizeof("arithmetic overflow") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = o.v);
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Slash) {
      {
        if (ri == 0) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"division by zero", sizeof("division by zero") - 1 });
          return consteval__consteval__cv_nil();
        }
        if ((ri == -1) && (li == type_min)) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"arithmetic overflow", sizeof("arithmetic overflow") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = ({ int64_t __sc106 = li; int64_t __sc107 = ri; if (__sc107 == 0) { __sc_panic("divide by zero"); } if (__sc107 == -1 && __sc106 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc106 / __sc107); }));
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Percent) {
      {
        if (ri == 0) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"division by zero", sizeof("division by zero") - 1 });
          return consteval__consteval__cv_nil();
        }
        if ((ri == -1) && (li == type_min)) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"arithmetic overflow", sizeof("arithmetic overflow") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = ({ int64_t __sc108 = li; int64_t __sc109 = ri; if (__sc109 == 0) { __sc_panic("divide by zero"); } if (__sc109 == -1 && __sc108 == INT64_MIN) { __sc_panic("arithmetic overflow"); } (__sc108 % __sc109); }));
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Ampersand) {
      {
        (v = (li & ri));
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Pipe) {
      {
        (v = (li | ri));
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_Caret) {
      {
        (v = (li ^ ri));
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_LeftShift) {
      {
        if ((ri < 0) || (ri >= ((int64_t)bits))) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"shift out of range", sizeof("shift out of range") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = consteval__consteval__wrap_to(ob, ((int64_t)({ uint64_t __sc110 = ((uint64_t)li); int64_t __sc111 = (int64_t)(((uint64_t)ri)); if ((uint64_t)__sc111 >= 64) { __sc_panic("shift out of range"); } (uint64_t)((uint64_t)((uint64_t)__sc110 << __sc111)); }))));
      }
    }
    else if (__sc105 == lexer__token_type__TokenType_RightShift) {
      {
        if ((ri < 0) || (ri >= ((int64_t)bits))) {
          consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"shift out of range", sizeof("shift out of range") - 1 });
          return consteval__consteval__cv_nil();
        }
        (v = ({ int64_t __sc112 = li; int64_t __sc113 = (int64_t)(ri); if ((uint64_t)__sc113 >= 64) { __sc_panic("shift out of range"); } (int64_t)(__sc112 >> __sc113); }));
      }
    }
    else if (1) {
      {
        return consteval__consteval__cv_nil();
      }
    }
  }
  if ((b != ast__ast__BuiltinType_BT_COUNT) && (!consteval__consteval__fits(b, v))) {
    if (consteval__consteval__bt_signed(b)) {
      consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"arithmetic overflow", sizeof("arithmetic overflow") - 1 });
    }
    return consteval__consteval__cv_nil();
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = tm, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = v } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__eval_str_literal(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint8_t *const src = consteval__consteval__ConstEval__ce_src(self, m);
  const lexer__token__Span sp = ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.raw;
  const bool raw = (ast__ast__Ast__at_const(&((*a)), id)->as_data.literal.token_type == lexer__token_type__TokenType_RawStringLiteral);
  uint32_t i = sp.start;
  uint32_t hashes = 0U;
  while ((i < sp.end) && (src[((size_t)i)] != 34U)) {
    if (src[((size_t)i)] == 35U) {
      (hashes = (hashes + 1U));
    }
    (i = (i + 1U));
  }
  if (i >= sp.end) {
    return consteval__consteval__cv_nil();
  }
  (i = (i + 1U));
  uint32_t endpos = (sp.end - 1U);
  if (raw) {
    (endpos = (endpos - hashes));
  }
  consteval__consteval__Buf4096 bytes = (consteval__consteval__Buf4096){0};
  uint32_t nb = 0U;
  while (i < endpos) {
    if (nb >= 4096U) {
      return consteval__consteval__cv_nil();
    }
    uint8_t c = src[((size_t)i)];
    (i = (i + 1U));
    if (((!raw) && (c == 92U)) && (i < endpos)) {
      const uint8_t e = src[((size_t)i)];
      (i = (i + 1U));
      {
        const uint8_t __sc114 = e;
        if (__sc114 == 'n') {
          {
            (c = 10U);
          }
        }
        else if (__sc114 == 't') {
          {
            (c = 9U);
          }
        }
        else if (__sc114 == 'r') {
          {
            (c = 13U);
          }
        }
        else if (__sc114 == '0') {
          {
            (c = 0U);
          }
        }
        else if (__sc114 == '\\') {
          {
            (c = 92U);
          }
        }
        else if (__sc114 == '"') {
          {
            (c = 34U);
          }
        }
        else if (__sc114 == '\'') {
          {
            (c = 39U);
          }
        }
        else if (1) {
          {
            return consteval__consteval__cv_nil();
          }
        }
      }
    }
    (bytes.b[((size_t)nb)] = c);
    (nb = (nb + 1U));
  }
  const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, id));
  if ((!rr.ok) || (rr.r.dn == ast__ast__NODE_NONE)) {
    return consteval__consteval__cv_nil();
  }
  const uint32_t block = consteval__consteval__ConstEval__ce_obj_new(self, nb);
  if ((block == 0U) && (nb != 0U)) {
    return consteval__consteval__cv_nil();
  }
  if (nb != 0U) {
    consteval__consteval__CeObj *const bo = consteval__consteval__ConstEval__obj_ptr(self, block);
    ((*bo).heap = 1U);
    ((*bo).bytes = ((uint64_t)nb));
    ((*bo).em = 0U);
    ((*bo).et = 8U);
    ((*bo).esz = 1ULL);
    for (uint32_t k = 0U; k < nb; k++) {
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, block)).slots, ((size_t)k), (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = 8U, .as_data = (consteval__consteval__CeValAs){ .i = ((int64_t)bytes.b[((size_t)k)]) } });
    }
  }
  const uint32_t so = consteval__consteval__ConstEval__ce_obj_new(self, consteval__consteval__ConstEval__ce_field_count(self, rr.r.dm, rr.r.dn));
  if (so == 0U) {
    return consteval__consteval__cv_nil();
  }
  ((*consteval__consteval__ConstEval__obj_ptr(self, so)).dm = rr.r.dm);
  ((*consteval__consteval__ConstEval__obj_ptr(self, so)).dn = rr.r.dn);
  const ast__ast__Ast *const da = consteval__consteval__ConstEval__ast_ptr(self, rr.r.dm);
  const ast__ast__NodeList dms = ast__ast__Ast__at_const(&((*da)), rr.r.dn)->as_data.aggregate.members;
  int32_t ptr_i = -1;
  int32_t len_i = -1;
  int32_t idx = 0;
  for (uint32_t kk = 0U; kk < dms.len; kk++) {
    const uint32_t fid = ast__ast__Ast__list(&((*da)), dms)[((size_t)kk)];
    if (ast__ast__Ast__at_const(&((*da)), fid)->kind == ast__ast__NodeKind_NODE_FIELD) {
      const lexer__token__Span fn2 = consteval__consteval__ConstEval__name_text(self, rr.r.dm, ast__ast__Ast__at_const(&((*da)), fid)->as_data.field.name);
      if (consteval__consteval__ConstEval__ce_span_is(self, rr.r.dm, fn2, (str){ (const uint8_t *)"ptr", sizeof("ptr") - 1 })) {
        (ptr_i = idx);
      } else if (consteval__consteval__ConstEval__ce_span_is(self, rr.r.dm, fn2, (str){ (const uint8_t *)"len", sizeof("len") - 1 })) {
        (len_i = idx);
      }
      (idx = ({ int32_t __sc_r; if (__builtin_add_overflow(idx, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
  }
  if ((ptr_i < 0) || (len_i < 0)) {
    return consteval__consteval__cv_nil();
  }
  Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, so)).slots, ((size_t)ptr_i), (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = block, .off = 0U } } });
  Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, so)).slots, ((size_t)len_i), (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = 12U, .as_data = (consteval__consteval__CeValAs){ .i = ((int64_t)nb) } });
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = consteval__consteval__ConstEval__ce_type(self, m, id), .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = so, .off = 0U } } };
}

static __attribute__((unused)) int32_t consteval__consteval__ce_local_find(consteval__consteval__CeFrame *const f, uint32_t const decl) {
  uint32_t i = (*f).n;
  while (i > 0U) {
    (i = (i - 1U));
    if ((*f).locals[((size_t)i)].decl == decl) {
      return ((int32_t)i);
    }
  }
  return -1;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__cv_bool(uint16_t const tm, uint32_t const rt, bool const b) {
  int64_t i = 0;
  if (b) {
    (i = 1);
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_BOOL, .tm = tm, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = i } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ce_float_op(lexer__token_type__TokenType const op, consteval__consteval__CeVal const l, consteval__consteval__CeVal const r, uint16_t const tm, uint32_t const rt, ast__ast__BuiltinType const b) {
  if (op == lexer__token_type__TokenType_EqualEqual) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.f == r.as_data.f));
  }
  if (op == lexer__token_type__TokenType_BangEqual) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.f != r.as_data.f));
  }
  if (op == lexer__token_type__TokenType_LessThan) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.f < r.as_data.f));
  }
  if (op == lexer__token_type__TokenType_LessThanEqual) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.f <= r.as_data.f));
  }
  if (op == lexer__token_type__TokenType_GreaterThan) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.f > r.as_data.f));
  }
  if (op == lexer__token_type__TokenType_GreaterThanEqual) {
    return consteval__consteval__cv_bool(tm, rt, (l.as_data.f >= r.as_data.f));
  }
  double v = 0.0;
  {
    const lexer__token_type__TokenType __sc115 = op;
    if (__sc115 == lexer__token_type__TokenType_Plus) {
      {
        (v = (l.as_data.f + r.as_data.f));
      }
    }
    else if (__sc115 == lexer__token_type__TokenType_Minus) {
      {
        (v = (l.as_data.f - r.as_data.f));
      }
    }
    else if (__sc115 == lexer__token_type__TokenType_Star) {
      {
        (v = (l.as_data.f * r.as_data.f));
      }
    }
    else if (__sc115 == lexer__token_type__TokenType_Slash) {
      {
        (v = (l.as_data.f / r.as_data.f));
      }
    }
    else if (1) {
      {
        return consteval__consteval__cv_nil();
      }
    }
  }
  if (b == ast__ast__BuiltinType_BT_F32) {
    (v = ((double)((float)v)));
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FLOAT, .tm = tm, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .f = v } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__cv_scalar_of(consteval__consteval__ConstValue const v, uint16_t const m) {
  if (v.kind == consteval__consteval__CONST_INT) {
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = v.ty, .as_data = (consteval__consteval__CeValAs){ .i = v.as_data.i } };
  }
  if (v.kind == consteval__consteval__CONST_BOOL) {
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_BOOL, .tm = m, .ty = v.ty, .as_data = (consteval__consteval__CeValAs){ .i = v.as_data.i } };
  }
  return consteval__consteval__cv_nil();
}

static __attribute__((unused)) ast__ast__BuiltinType consteval__consteval__ce_arith_common(ast__ast__BuiltinType const a, ast__ast__BuiltinType const b) {
  if ((a == ast__ast__BuiltinType_BT_COUNT) || (b == ast__ast__BuiltinType_BT_COUNT)) {
    if (a == ast__ast__BuiltinType_BT_COUNT) {
      return b;
    }
    return a;
  }
  int32_t wa = consteval__consteval__bt_bits(a);
  if (wa < 32) {
    (wa = 32);
  }
  int32_t wb = consteval__consteval__bt_bits(b);
  if (wb < 32) {
    (wb = 32);
  }
  const bool ua = ((consteval__consteval__bt_bits(a) >= 32) && consteval__consteval__bt_unsigned(a));
  const bool ub = ((consteval__consteval__bt_bits(b) >= 32) && consteval__consteval__bt_unsigned(b));
  int32_t w = wb;
  if (wa > wb) {
    (w = wa);
  }
  bool u = ua;
  if (ua != ub) {
    int32_t lhs = wb;
    int32_t rhs = wa;
    if (ua) {
      (lhs = wa);
      (rhs = wb);
    }
    (u = (lhs >= rhs));
  }
  if (u) {
    if (w == 64) {
      return ast__ast__BuiltinType_BT_U64;
    }
    return ast__ast__BuiltinType_BT_U32;
  }
  if (w == 64) {
    return ast__ast__BuiltinType_BT_I64;
  }
  return ast__ast__BuiltinType_BT_I32;
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_range_decl(const consteval__consteval__ConstEval *const self, uint16_t *const dm, uint32_t *const dn) {
  uint16_t mm = 0U;
  while (((size_t)mm) < self->nmods) {
    if (consteval__consteval__ConstEval__has_ast(self, mm)) {
      const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, mm);
      if (Vector__ast__ast__Node__Global__len(&(*a).nodes) != 0ULL) {
        const ast__ast__NodeList items = ast__ast__Ast__at_const(&((*a)), (*a).root)->as_data.program.items;
        for (uint32_t i = 0U; i < items.len; i++) {
          const uint32_t iid = ast__ast__Ast__list(&((*a)), items)[((size_t)i)];
          if ((ast__ast__Ast__at_const(&((*a)), iid)->kind == ast__ast__NodeKind_NODE_STRUCT) && (!ast__ast__Ast__at_const(&((*a)), iid)->as_data.aggregate.is_union)) {
            const lexer__token__Span nm = consteval__consteval__ConstEval__name_text(self, mm, ast__ast__Ast__at_const(&((*a)), iid)->as_data.aggregate.name);
            if (consteval__consteval__ConstEval__ce_span_is(self, mm, nm, (str){ (const uint8_t *)"Range", sizeof("Range") - 1 })) {
              ((*dm) = mm);
              ((*dn) = iid);
              return true;
            }
          }
        }
      }
    }
    (mm = ((uint16_t)((uint32_t)mm + (uint32_t)1U)));
  }
  return false;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_range_obj(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t start_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.start;
  const uint32_t end_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.end;
  const bool inclusive = ast__ast__Ast__at_const(&((*a)), id)->as_data.pattern_range.inclusive;
  if ((start_n == ast__ast__NODE_NONE) || (end_n == ast__ast__NODE_NONE)) {
    return consteval__consteval__cv_nil();
  }
  uint16_t dm = 0U;
  uint32_t dn = ast__ast__NODE_NONE;
  if (!consteval__consteval__ConstEval__ce_range_decl(self, ((uint16_t *)(&dm)), ((uint32_t *)(&dn)))) {
    return consteval__consteval__cv_nil();
  }
  consteval__consteval__CeVal sv = consteval__consteval__ConstEval__ev_in(self, f, m, start_n);
  if (sv.kind == consteval__consteval__CV_NIL_K) {
    (sv = consteval__consteval__ConstEval__ev_in(self, NULL, m, start_n));
  }
  consteval__consteval__CeVal e = consteval__consteval__ConstEval__ev_in(self, f, m, end_n);
  if (e.kind == consteval__consteval__CV_NIL_K) {
    (e = consteval__consteval__ConstEval__ev_in(self, NULL, m, end_n));
  }
  if (sv.kind == consteval__consteval__CV_PTR) {
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, sv);
    if (!lr.ok) {
      return consteval__consteval__cv_nil();
    }
    (sv = lr.v);
  }
  if (e.kind == consteval__consteval__CV_PTR) {
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, e);
    if (!lr.ok) {
      return consteval__consteval__cv_nil();
    }
    (e = lr.v);
  }
  if ((sv.kind != consteval__consteval__CV_INT) || (e.kind != consteval__consteval__CV_INT)) {
    return consteval__consteval__cv_nil();
  }
  const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, consteval__consteval__ConstEval__ce_field_count(self, dm, dn));
  if (o == 0U) {
    return consteval__consteval__cv_nil();
  }
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dm = dm);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dn = dn);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).nargs = 1U);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).at[0] = 12U);
  if (Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots) < 3ULL) {
    return consteval__consteval__cv_nil();
  }
  Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, 0ULL, sv);
  Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, 1ULL, e);
  Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, 2ULL, consteval__consteval__cv_bool(0U, 1U, inclusive));
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = consteval__consteval__ConstEval__ce_type(self, m, id), .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_in(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  if (((id == ast__ast__NODE_NONE) || (!consteval__consteval__ConstEval__ce_tick(self))) || (self->depth > 32U)) {
    return consteval__consteval__cv_nil();
  }
  (self->depth = (self->depth + 1U));
  const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev(self, f, m, id);
  (self->depth = (self->depth - 1U));
  return v;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_rval(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, f, m, id);
  if (v.kind != consteval__consteval__CV_PTR) {
    return v;
  }
  uint16_t tm = m;
  uint32_t t = consteval__consteval__ConstEval__ce_type(self, m, id);
  int32_t guard = 0;
  while ((guard < 4) && (v.kind == consteval__consteval__CV_PTR)) {
    const consteval__consteval__RType r = consteval__consteval__ConstEval__ce_rtype(self, f, tm, t);
    if (!r.ok) {
      return v;
    }
    (tm = r.m);
    (t = r.t);
    const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, tm))), t);
    if (y->kind != ast__ast__TypeKind_TYPE_REFERENCE) {
      return v;
    }
    const uint32_t elem = y->as_data.elem;
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, v);
    if (!lr.ok) {
      return consteval__consteval__cv_nil();
    }
    (v = lr.v);
    (t = elem);
    (guard = ({ int32_t __sc_r; if (__builtin_add_overflow(guard, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  return v;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ce_coerce(consteval__consteval__ConstEval *const self, consteval__consteval__CeVal const v, uint16_t const wm, uint32_t const wt) {
  if (v.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__cv_nil();
  }
  if (wt == ast__ast__TYPE_NONE) {
    return v;
  }
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, wm))), wt));
  if (((y.kind == ast__ast__TypeKind_TYPE_REFERENCE) || (y.kind == ast__ast__TypeKind_TYPE_POINTER)) || (y.kind == ast__ast__TypeKind_TYPE_FUNCTION)) {
    if ((v.kind == consteval__consteval__CV_PTR) || (v.kind == consteval__consteval__CV_FN)) {
      return v;
    }
    return consteval__consteval__cv_nil();
  }
  if (v.kind == consteval__consteval__CV_PTR) {
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, v);
    if (!lr.ok) {
      return consteval__consteval__cv_nil();
    }
    return consteval__consteval__ConstEval__ce_coerce(self, lr.v, wm, wt);
  }
  if ((((y.kind == ast__ast__TypeKind_TYPE_INSTANCE) && (v.kind == consteval__consteval__CV_AGG)) && (v.ty != ast__ast__TYPE_NONE)) && (ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, v.tm))), v.ty)->kind == ast__ast__TypeKind_TYPE_ARRAY)) {
    const ast__ast__TyInstance it = (*ast__ast__Ast__instance(&((*consteval__consteval__ConstEval__ast_ptr(self, wm))), y.as_data.inst));
    const ast__ast__Ast *const da = consteval__consteval__ConstEval__ast_ptr(self, it.module);
    const lexer__token__Span dn = consteval__consteval__ConstEval__name_text(self, it.module, ast__ast__Ast__at_const(&((*da)), it.decl)->as_data.aggregate.name);
    if ((!consteval__consteval__ConstEval__ce_span_is(self, it.module, dn, (str){ (const uint8_t *)"Slice", sizeof("Slice") - 1 })) && (!consteval__consteval__ConstEval__ce_span_is(self, it.module, dn, (str){ (const uint8_t *)"SliceMut", sizeof("SliceMut") - 1 }))) {
      return consteval__consteval__cv_nil();
    }
    if (consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj) == NULL) {
      return consteval__consteval__cv_nil();
    }
    const int64_t arrlen = ((int64_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots));
    const uint32_t so = consteval__consteval__ConstEval__ce_obj_new(self, 2U);
    if (so == 0U) {
      return consteval__consteval__cv_nil();
    }
    ((*consteval__consteval__ConstEval__obj_ptr(self, so)).dm = it.module);
    ((*consteval__consteval__ConstEval__obj_ptr(self, so)).dn = it.decl);
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, so)).slots, 0ULL, (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = v.as_data.p.obj, .off = 0U } } });
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, so)).slots, 1ULL, (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = 12U, .as_data = (consteval__consteval__CeValAs){ .i = arrlen } });
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = wm, .ty = wt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = so, .off = 0U } } };
  }
  if (((y.kind == ast__ast__TypeKind_TYPE_ARRAY) && (v.kind == consteval__consteval__CV_AGG)) && (y.as_data.arr.len != 0U)) {
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
    if ((o != NULL) && (((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*o).slots)) < y.as_data.arr.len)) {
      const uint32_t from = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*o).slots));
      const consteval__consteval__RType er = consteval__consteval__ConstEval__ce_rtype(self, NULL, wm, y.as_data.arr.elem);
      if (!er.ok) {
        return consteval__consteval__cv_nil();
      }
      const consteval__consteval__CeVal z = consteval__consteval__ConstEval__ce_zero(self, er.m, er.t, 0);
      if ((z.kind == consteval__consteval__CV_NIL_K) || (!consteval__consteval__ConstEval__ce_obj_resize(self, v.as_data.p.obj, y.as_data.arr.len))) {
        return consteval__consteval__cv_nil();
      }
      const uint32_t newlen = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots));
      uint32_t i = from;
      while (i < newlen) {
        const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, z, 0);
        Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots, ((size_t)i), cloned);
        (i = (i + 1U));
      }
    }
  }
  return v;
}

static __attribute__((unused)) consteval__consteval__ObjRes consteval__consteval__ConstEval__ce_base_obj(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, f, m, id);
  int32_t guard = 0;
  while ((guard < 4) && (v.kind == consteval__consteval__CV_PTR)) {
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, v);
    if (!lr.ok) {
      return (consteval__consteval__ObjRes){ .ok = false };
    }
    (v = lr.v);
    (guard = ({ int32_t __sc_r; if (__builtin_add_overflow(guard, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if (v.kind != consteval__consteval__CV_AGG) {
    return (consteval__consteval__ObjRes){ .ok = false };
  }
  return (consteval__consteval__ObjRes){ .ok = true, .obj = v.as_data.p.obj };
}

static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ev_place(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id0) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  uint32_t id = id0;
  for (;;) {
    const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*a)), id)->kind;
    if (k == ast__ast__NodeKind_NODE_UNARY) {
      const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.op;
      if ((op == lexer__token_type__TokenType_Move) || (op == lexer__token_type__TokenType_Unsafe)) {
        (id = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.operand);
        continue;
      }
    }
    break;
  }
  const ast__ast__NodeKind n_kind = ast__ast__Ast__at_const(&((*a)), id)->kind;
  if (n_kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    if (f == NULL) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
    if (d.node == ast__ast__NODE_NONE) {
      (d = (ast__ast__DefId){ .module = m, .node = ast__ast__Ast__resolution(&((*a)), id) });
    }
    if (d.module != m) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    const int32_t i = consteval__consteval__ce_local_find(f, d.node);
    if (i < 0) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    const uint32_t slot = (*f).locals[((size_t)i)].slot;
    return (consteval__consteval__ValRes){ .ok = true, .v = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = (*f).env, .off = slot } } } };
  }
  if (n_kind == ast__ast__NodeKind_NODE_MEMBER) {
    if (ast__ast__Ast__at_const(&((*a)), id)->as_data.member.path) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    const uint32_t mem = ast__ast__Ast__at_const(&((*a)), id)->as_data.member.member;
    const uint32_t obj_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.member.object;
    const lexer__token__Span mname = consteval__consteval__ConstEval__name_text(self, m, mem);
    const consteval__consteval__ObjRes br = consteval__consteval__ConstEval__ce_base_obj(self, f, m, obj_n);
    if (!br.ok) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, br.obj);
    if ((o == NULL) || ((*o).dead != 0U)) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    const uint8_t c0 = consteval__consteval__ConstEval__ce_src(self, m)[((size_t)mname.start)];
    uint32_t idx = 0U;
    if ((c0 >= 48U) && (c0 <= 57U)) {
      (idx = ((uint32_t)((uint8_t)((uint32_t)c0 - (uint32_t)48U))));
    } else {
      if ((*o).dn == ast__ast__NODE_NONE) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      const consteval__consteval__FieldIdx fi = consteval__consteval__ConstEval__ce_field_index(self, (*o).dm, (*o).dn, m, mname);
      if (fi.idx < 0) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      (idx = ((uint32_t)fi.idx));
    }
    if (idx >= ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, br.obj)).slots))) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    return (consteval__consteval__ValRes){ .ok = true, .v = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = br.obj, .off = idx } } } };
  }
  if (n_kind == ast__ast__NodeKind_NODE_INDEX) {
    const uint32_t obj_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.index.object;
    const uint32_t index_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.index.index;
    uint16_t bm = m;
    uint32_t bt = consteval__consteval__ConstEval__ce_type(self, m, obj_n);
    for (int32_t _ = 0; _ < 4; _++) {
      const consteval__consteval__RType r = consteval__consteval__ConstEval__ce_rtype(self, f, bm, bt);
      if (!r.ok) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      (bm = r.m);
      (bt = r.t);
      const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, bm))), bt);
      if (y->kind != ast__ast__TypeKind_TYPE_REFERENCE) {
        break;
      }
      (bt = y->as_data.elem);
    }
    const ast__ast__TypeKind yk = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, bm))), bt)->kind;
    const consteval__consteval__CeVal iv = consteval__consteval__ConstEval__ev_rval(self, f, m, index_n);
    if (iv.kind != consteval__consteval__CV_INT) {
      return (consteval__consteval__ValRes){ .ok = false };
    }
    if (yk == ast__ast__TypeKind_TYPE_POINTER) {
      const consteval__consteval__CeVal p = consteval__consteval__ConstEval__ev_rval(self, f, m, obj_n);
      if (p.kind != consteval__consteval__CV_PTR) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      consteval__consteval__CeVal out = p;
      (out.as_data.p.off = (out.as_data.p.off + ((uint32_t)iv.as_data.i)));
      return (consteval__consteval__ValRes){ .ok = true, .v = out };
    }
    if (yk == ast__ast__TypeKind_TYPE_ARRAY) {
      const consteval__consteval__ObjRes br = consteval__consteval__ConstEval__ce_base_obj(self, f, m, obj_n);
      if (!br.ok) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      const uint64_t olen = ((uint64_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, br.obj)).slots));
      if ((iv.as_data.i < 0) || (((uint64_t)iv.as_data.i) >= olen)) {
        consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"out-of-bounds access", sizeof("out-of-bounds access") - 1 });
        return (consteval__consteval__ValRes){ .ok = false };
      }
      return (consteval__consteval__ValRes){ .ok = true, .v = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = br.obj, .off = ((uint32_t)iv.as_data.i) } } } };
    }
    if ((yk == ast__ast__TypeKind_TYPE_STRUCT) || (yk == ast__ast__TypeKind_TYPE_INSTANCE)) {
      const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, bm, bt);
      if (!rr.ok) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      const consteval__consteval__ValRes recvr = consteval__consteval__ConstEval__ev_place(self, f, m, obj_n);
      if (!recvr.ok) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      consteval__consteval__CeVal args[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
      (args[0] = recvr.v);
      (args[1] = iv);
      const consteval__consteval__ValRes dr = consteval__consteval__ConstEval__ce_dispatch(self, rr.r, m, (str){ (const uint8_t *)"index_mut", sizeof("index_mut") - 1 }, ((const consteval__consteval__CeVal *)(&args[0])), 2U);
      if ((!dr.ok) || (dr.v.kind != consteval__consteval__CV_PTR)) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      return (consteval__consteval__ValRes){ .ok = true, .v = dr.v };
    }
    return (consteval__consteval__ValRes){ .ok = false };
  }
  if (n_kind == ast__ast__NodeKind_NODE_UNARY) {
    const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.op;
    if (op == lexer__token_type__TokenType_Star) {
      const consteval__consteval__CeVal p = consteval__consteval__ConstEval__ev_in(self, f, m, ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.operand);
      if (p.kind != consteval__consteval__CV_PTR) {
        return (consteval__consteval__ValRes){ .ok = false };
      }
      return (consteval__consteval__ValRes){ .ok = true, .v = p };
    }
    return (consteval__consteval__ValRes){ .ok = false };
  }
  return (consteval__consteval__ValRes){ .ok = false };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  if (!consteval__consteval__ConstEval__has_ast(self, m)) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), id);
  const lexer__token_type__TokenType ntt = n->as_data.literal.token_type;
  if (((f != NULL) && (consteval__consteval__ConstEval__ce_type(self, m, id) == ast__ast__TYPE_NONE)) && (!((n->kind == ast__ast__NodeKind_NODE_LITERAL) && (ntt == lexer__token_type__TokenType_Null)))) {
    return consteval__consteval__cv_nil();
  }
  const uint8_t *const src = consteval__consteval__ConstEval__ce_src(self, m);
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  if (n->kind == ast__ast__NodeKind_NODE_LITERAL) {
    if (ntt == lexer__token_type__TokenType_IntegerLiteral) {
      return consteval__consteval__cv_scalar_of(consteval__consteval__ConstEval__eval_int_literal(self, m, id), m);
    }
    if ((ntt == lexer__token_type__TokenType_CharacterLiteral) || (ntt == lexer__token_type__TokenType_ByteCharacterLiteral)) {
      return consteval__consteval__cv_scalar_of(consteval__consteval__ConstEval__eval_char_literal(self, m, id), m);
    }
    if (ntt == lexer__token_type__TokenType_FloatLiteral) {
      return consteval__consteval__ConstEval__eval_float_literal(self, m, id);
    }
    if (ntt == lexer__token_type__TokenType_True) {
      return consteval__consteval__cv_bool(m, rt, true);
    }
    if (ntt == lexer__token_type__TokenType_False) {
      return consteval__consteval__cv_bool(m, rt, false);
    }
    if (ntt == lexer__token_type__TokenType_Null) {
      return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = 0U, .off = 0U } } };
    }
    if ((ntt == lexer__token_type__TokenType_StringLiteral) || (ntt == lexer__token_type__TokenType_RawStringLiteral)) {
      return consteval__consteval__ConstEval__eval_str_literal(self, f, m, id);
    }
    return consteval__consteval__cv_nil();
  }
  if (n->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
    ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
    if (d.node == ast__ast__NODE_NONE) {
      (d = (ast__ast__DefId){ .module = m, .node = ast__ast__Ast__resolution(&((*a)), id) });
    }
    if ((d.node == ast__ast__NODE_NONE) || (((size_t)d.module) >= self->nmods)) {
      return consteval__consteval__cv_nil();
    }
    if ((f != NULL) && (d.module == m)) {
      const int32_t i = consteval__consteval__ce_local_find(f, d.node);
      if (i >= 0) {
        const uint32_t slot = (*f).locals[((size_t)i)].slot;
        const uint32_t env = (*f).env;
        consteval__consteval__CeObj *const eo = consteval__consteval__ConstEval__obj_ptr(self, env);
        if ((eo == NULL) || (((size_t)slot) >= Vector__consteval__consteval__CeVal__Global__len(&(*eo).slots))) {
          return consteval__consteval__cv_nil();
        }
        consteval__consteval__CeVal v = (*({ __auto_type __sc116 = &(*eo).slots; Vector__consteval__consteval__CeVal__Global__index(__sc116, ((size_t)slot)); }));
        if (v.kind == consteval__consteval__CV_NIL_K) {
          return consteval__consteval__cv_nil();
        }
        if (((v.kind == consteval__consteval__CV_INT) || (v.kind == consteval__consteval__CV_BOOL)) || (v.kind == consteval__consteval__CV_FLOAT)) {
          (v.tm = m);
          (v.ty = rt);
        }
        return v;
      }
    }
    const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->kind;
    if (dk == ast__ast__NodeKind_NODE_FUNCTION) {
      return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FN, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .fnv = (consteval__consteval__CvFn){ .m = d.module, .fn_id = d.node } } };
    }
    const uint32_t dval = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->as_data.const_def.value;
    const bool is_static_mut = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->as_data.const_def.is_static_mut;
    if (((dk != ast__ast__NodeKind_NODE_CONST) || (dval == ast__ast__NODE_NONE)) || is_static_mut) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, NULL, d.module, dval);
    if (((v.kind == consteval__consteval__CV_INT) || (v.kind == consteval__consteval__CV_BOOL)) || (v.kind == consteval__consteval__CV_FLOAT)) {
      (v.tm = m);
      (v.ty = rt);
    }
    return v;
  }
  if (n->kind == ast__ast__NodeKind_NODE_MEMBER) {
    if (n->as_data.member.path) {
      ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), id);
      if (d.node == ast__ast__NODE_NONE) {
        (d = ast__ast__Ast__resolution_def(&((*a)), n->as_data.member.member));
      }
      if ((d.node == ast__ast__NODE_NONE) || (((size_t)d.module) >= self->nmods)) {
        return consteval__consteval__cv_nil();
      }
      const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->kind;
      if (dk == ast__ast__NodeKind_NODE_CONST) {
        const uint32_t dval = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->as_data.const_def.value;
        const bool is_sm = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->as_data.const_def.is_static_mut;
        if ((dval != ast__ast__NODE_NONE) && (!is_sm)) {
          consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, NULL, d.module, dval);
          if (((v.kind == consteval__consteval__CV_INT) || (v.kind == consteval__consteval__CV_BOOL)) || (v.kind == consteval__consteval__CV_FLOAT)) {
            (v.tm = m);
            (v.ty = rt);
          }
          return v;
        }
      }
      if (dk == ast__ast__NodeKind_NODE_FUNCTION) {
        return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FN, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .fnv = (consteval__consteval__CvFn){ .m = d.module, .fn_id = d.node } } };
      }
      if (dk != ast__ast__NodeKind_NODE_VARIANT) {
        return consteval__consteval__cv_nil();
      }
      const consteval__consteval__VarPos vp = consteval__consteval__ConstEval__ce_variant_pos(self, d.module, d.node);
      if (vp.pos < 0) {
        return consteval__consteval__cv_nil();
      }
      if (!consteval__consteval__ConstEval__ce_enum_tagged(self, d.module, vp.enum_decl)) {
        consteval__consteval__CeVal v = consteval__consteval__cv_scalar_of(consteval__consteval__ConstEval__variant_value(self, d.module, d.node), m);
        (v.ty = rt);
        return v;
      }
      if (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->as_data.variant.payload.len > 0U) {
        return consteval__consteval__cv_nil();
      }
      if (consteval__consteval__ConstEval__ce_user_free(self, d.module, vp.enum_decl)) {
        return consteval__consteval__cv_nil();
      }
      const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, 1U);
      if (o == 0U) {
        return consteval__consteval__cv_nil();
      }
      ((*consteval__consteval__ConstEval__obj_ptr(self, o)).is_enum = 1U);
      ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dm = d.module);
      ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dn = vp.enum_decl);
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, 0ULL, (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .i = ((int64_t)vp.pos) } });
      return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } };
    }
    const lexer__token__Span mname = consteval__consteval__ConstEval__name_text(self, m, n->as_data.member.member);
    const consteval__consteval__ObjRes br = consteval__consteval__ConstEval__ce_base_obj(self, f, m, n->as_data.member.object);
    if (!br.ok) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, br.obj);
    if ((o == NULL) || ((*o).dead != 0U)) {
      return consteval__consteval__cv_nil();
    }
    const uint8_t c0 = src[((size_t)mname.start)];
    uint32_t idx = 0U;
    if ((c0 >= 48U) && (c0 <= 57U)) {
      (idx = ((uint32_t)((uint8_t)((uint32_t)c0 - (uint32_t)48U))));
    } else {
      if ((*o).dn == ast__ast__NODE_NONE) {
        return consteval__consteval__cv_nil();
      }
      const consteval__consteval__FieldIdx fi = consteval__consteval__ConstEval__ce_field_index(self, (*o).dm, (*o).dn, m, mname);
      if (fi.idx < 0) {
        return consteval__consteval__cv_nil();
      }
      (idx = ((uint32_t)fi.idx));
    }
    consteval__consteval__CeObj *const oo = consteval__consteval__ConstEval__obj_ptr(self, br.obj);
    if (idx >= ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*oo).slots))) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal sv = (*({ __auto_type __sc117 = &(*oo).slots; Vector__consteval__consteval__CeVal__Global__index(__sc117, ((size_t)idx)); }));
    if (sv.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    return sv;
  }
  if (n->kind == ast__ast__NodeKind_NODE_UNARY) {
    return consteval__consteval__ConstEval__ev_unary(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_CAST) {
    return consteval__consteval__ConstEval__ev_cast(self, f, m, id);
  }
  if ((n->kind == ast__ast__NodeKind_NODE_SIZEOF) || (n->kind == ast__ast__NodeKind_NODE_ALIGNOF)) {
    const uint32_t ty = consteval__consteval__ConstEval__ce_type(self, m, n->as_data.single.value);
    const consteval__consteval__Layout lay = consteval__consteval__ConstEval__ce_layout_f(self, f, m, ty);
    if (!lay.ok) {
      return consteval__consteval__cv_nil();
    }
    uint64_t val = lay.align;
    if (n->kind == ast__ast__NodeKind_NODE_SIZEOF) {
      (val = lay.size);
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = ((int64_t)val) } };
  }
  if (n->kind == ast__ast__NodeKind_NODE_BINARY) {
    return consteval__consteval__ConstEval__ev_binary(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_CALL) {
    const consteval__consteval__Rets cr = consteval__consteval__ConstEval__ce_call(self, f, m, id);
    if ((!cr.ok) || (cr.n != 1U)) {
      return consteval__consteval__cv_nil();
    }
    return cr.vals[0];
  }
  if (n->kind == ast__ast__NodeKind_NODE_MATCH) {
    if (f == NULL) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeVal out = consteval__consteval__cv_nil();
    if (consteval__consteval__ConstEval__exec_match(self, f, m, id, ((consteval__consteval__CeVal *)(&out))) == consteval__consteval__Flow_Ok) {
      return out;
    }
    return consteval__consteval__cv_nil();
  }
  if (n->kind == ast__ast__NodeKind_NODE_BLOCK) {
    return consteval__consteval__ConstEval__ev_block(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_IF) {
    if (f == NULL) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal c = consteval__consteval__ConstEval__ev_rval(self, f, m, n->as_data.if_stmt.condition);
    if (c.kind != consteval__consteval__CV_BOOL) {
      return consteval__consteval__cv_nil();
    }
    uint32_t branch = n->as_data.if_stmt.else_branch;
    if (c.as_data.i != 0) {
      (branch = n->as_data.if_stmt.then_branch);
    }
    return consteval__consteval__ConstEval__ev_in(self, f, m, branch);
  }
  if (n->kind == ast__ast__NodeKind_NODE_INDEX) {
    return consteval__consteval__ConstEval__ev_index(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_STRUCT_INITIALIZER) {
    return consteval__consteval__ConstEval__ev_struct_init(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_ARRAY_LITERAL) {
    return consteval__consteval__ConstEval__ev_array_lit(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_TUPLE) {
    return consteval__consteval__ConstEval__ev_tuple(self, f, m, id);
  }
  if (n->kind == ast__ast__NodeKind_NODE_CLOSURE) {
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FN, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .fnv = (consteval__consteval__CvFn){ .m = m, .fn_id = id } } };
  }
  if (n->kind == ast__ast__NodeKind_NODE_RANGE) {
    return consteval__consteval__ConstEval__ce_range_obj(self, f, m, id);
  }
  return consteval__consteval__cv_nil();
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_unary(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), id);
  const lexer__token_type__TokenType op = n->as_data.unary.op;
  const uint32_t operand = n->as_data.unary.operand;
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  if ((op == lexer__token_type__TokenType_Move) || (op == lexer__token_type__TokenType_Unsafe)) {
    return consteval__consteval__ConstEval__ev_in(self, f, m, operand);
  }
  if (op == lexer__token_type__TokenType_Ampersand) {
    const consteval__consteval__ValRes pr = consteval__consteval__ConstEval__ev_place(self, f, m, operand);
    if (pr.ok) {
      consteval__consteval__CeVal p = pr.v;
      (p.tm = m);
      (p.ty = rt);
      return p;
    }
    const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, f, m, operand);
    if (v.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, v);
    if (!tr.ok) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeVal out = tr.v;
    (out.tm = m);
    (out.ty = rt);
    return out;
  }
  if (op == lexer__token_type__TokenType_Star) {
    const consteval__consteval__CeVal p = consteval__consteval__ConstEval__ev_in(self, f, m, operand);
    if (p.kind != consteval__consteval__CV_PTR) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, p);
    if (!lr.ok) {
      return consteval__consteval__cv_nil();
    }
    return lr.v;
  }
  if (op == lexer__token_type__TokenType_Question) {
    if (f == NULL) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_rval(self, f, m, operand);
    if (v.kind != consteval__consteval__CV_AGG) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
    if ((o == NULL) || ((*o).is_enum == 0U)) {
      return consteval__consteval__cv_nil();
    }
    const uint16_t odm = (*o).dm;
    const uint32_t odn = (*o).dn;
    int32_t okv = consteval__consteval__ConstEval__ce_variant_named(self, odm, odn, (str){ (const uint8_t *)"Some", sizeof("Some") - 1 });
    if (okv < 0) {
      (okv = consteval__consteval__ConstEval__ce_variant_named(self, odm, odn, (str){ (const uint8_t *)"Ok", sizeof("Ok") - 1 }));
    }
    if (okv < 0) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeObj *const o2 = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
    const int64_t tag = (*({ __auto_type __sc118 = &(*o2).slots; Vector__consteval__consteval__CeVal__Global__index(__sc118, 0ULL); })).as_data.i;
    if (tag == ((int64_t)okv)) {
      if ((Vector__consteval__consteval__CeVal__Global__len(&(*o2).slots) < 2ULL) || ((*({ __auto_type __sc119 = &(*o2).slots; Vector__consteval__consteval__CeVal__Global__index(__sc119, 1ULL); })).kind == consteval__consteval__CV_NIL_K)) {
        return consteval__consteval__cv_nil();
      }
      return (*({ __auto_type __sc120 = &(*o2).slots; Vector__consteval__consteval__CeVal__Global__index(__sc120, 1ULL); }));
    }
    ((*f).rets[0] = v);
    ((*f).nrets = 1U);
    ((*f).returned = 1U);
    ((*f).early = 1U);
    return consteval__consteval__cv_nil();
  }
  const consteval__consteval__CeVal o = consteval__consteval__ConstEval__ev_rval(self, f, m, operand);
  if (o.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__BuiltinType b = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, rt);
  if (op == lexer__token_type__TokenType_Minus) {
    if (o.kind == consteval__consteval__CV_FLOAT) {
      double v = (-o.as_data.f);
      if (b == ast__ast__BuiltinType_BT_F32) {
        (v = ((double)((float)v)));
      }
      return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FLOAT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .f = v } };
    }
    if ((o.kind != consteval__consteval__CV_INT) || (o.as_data.i == consteval__consteval__I64_MIN)) {
      return consteval__consteval__cv_nil();
    }
    const int64_t r = (-o.as_data.i);
    if ((b != ast__ast__BuiltinType_BT_COUNT) && (!consteval__consteval__fits(b, r))) {
      return consteval__consteval__cv_nil();
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = r } };
  }
  if (op == lexer__token_type__TokenType_Tilde) {
    if (o.kind != consteval__consteval__CV_INT) {
      return consteval__consteval__cv_nil();
    }
    ast__ast__BuiltinType bb = b;
    if (b == ast__ast__BuiltinType_BT_COUNT) {
      (bb = ast__ast__BuiltinType_BT_I64);
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = consteval__consteval__wrap_to(bb, (~o.as_data.i)) } };
  }
  if (op == lexer__token_type__TokenType_Bang) {
    if (o.kind != consteval__consteval__CV_BOOL) {
      return consteval__consteval__cv_nil();
    }
    return consteval__consteval__cv_bool(m, rt, (o.as_data.i == 0));
  }
  return consteval__consteval__cv_nil();
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_cast(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), id);
  const uint32_t expr = n->as_data.cast.expression;
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  const consteval__consteval__CeVal o = consteval__consteval__ConstEval__ev_rval(self, f, m, expr);
  if (o.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__cv_nil();
  }
  const consteval__consteval__RType r2 = consteval__consteval__ConstEval__ce_rtype(self, f, m, rt);
  if (!r2.ok) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, r2.m))), r2.t));
  if (y.kind == ast__ast__TypeKind_TYPE_POINTER) {
    if (o.kind != consteval__consteval__CV_PTR) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeVal v = o;
    (v.tm = m);
    (v.ty = rt);
    const consteval__consteval__RType er = consteval__consteval__ConstEval__ce_rtype(self, f, r2.m, y.as_data.elem);
    if (!er.ok) {
      return consteval__consteval__cv_nil();
    }
    if (consteval__consteval__type_builtin(consteval__consteval__ConstEval__ast_ptr(self, er.m), er.t) == ast__ast__BuiltinType_BT_VOID) {
      return v;
    }
    consteval__consteval__CeObj *const blk = consteval__consteval__ConstEval__obj_ptr(self, o.as_data.p.obj);
    if (blk == NULL) {
      return v;
    }
    if ((((*blk).heap != 0U) && ((*blk).et == ast__ast__TYPE_NONE)) && (o.as_data.p.off == 0U)) {
      const consteval__consteval__Layout lay = consteval__consteval__ConstEval__ce_layout_f(self, f, er.m, er.t);
      if ((!lay.ok) || (lay.size == 0ULL)) {
        return consteval__consteval__cv_nil();
      }
      const uint64_t bytes = (*blk).bytes;
      if (({ uint64_t __sc121 = bytes; uint64_t __sc122 = lay.size; if (__sc122 == 0) { __sc_panic("divide by zero"); } (__sc121 % __sc122); }) != 0ULL) {
        return consteval__consteval__cv_nil();
      }
      if (!consteval__consteval__ConstEval__ce_obj_resize(self, o.as_data.p.obj, ((uint32_t)({ uint64_t __sc123 = bytes; uint64_t __sc124 = lay.size; if (__sc124 == 0) { __sc_panic("divide by zero"); } (__sc123 / __sc124); })))) {
        return consteval__consteval__cv_nil();
      }
      consteval__consteval__CeObj *const blk2 = consteval__consteval__ConstEval__obj_ptr(self, o.as_data.p.obj);
      ((*blk2).em = er.m);
      ((*blk2).et = er.t);
      ((*blk2).esz = lay.size);
      return v;
    }
    if (((*blk).et != ast__ast__TYPE_NONE) && (!consteval__consteval__ConstEval__ce_teq(self, (*blk).em, (*blk).et, er.m, er.t))) {
      return consteval__consteval__cv_nil();
    }
    return v;
  }
  ast__ast__BuiltinType b = ast__ast__BuiltinType_BT_COUNT;
  if (y.kind == ast__ast__TypeKind_TYPE_BUILTIN) {
    (b = y.as_data.builtin);
  }
  if ((((((b == ast__ast__BuiltinType_BT_COUNT) || (b == ast__ast__BuiltinType_BT_C32)) || (b == ast__ast__BuiltinType_BT_C64)) || (b == ast__ast__BuiltinType_BT_BOOL)) || (b == ast__ast__BuiltinType_BT_VALIST)) || (b == ast__ast__BuiltinType_BT_VOID)) {
    return consteval__consteval__cv_nil();
  }
  if ((b == ast__ast__BuiltinType_BT_F32) || (b == ast__ast__BuiltinType_BT_F64)) {
    double v = 0.0;
    if (o.kind == consteval__consteval__CV_FLOAT) {
      (v = o.as_data.f);
    } else if (o.kind == consteval__consteval__CV_INT) {
      const ast__ast__BuiltinType ob = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, expr));
      if ((ob != ast__ast__BuiltinType_BT_COUNT) && consteval__consteval__bt_unsigned(ob)) {
        (v = ((double)((uint64_t)o.as_data.i)));
      } else {
        (v = ((double)o.as_data.i));
      }
    } else {
      return consteval__consteval__cv_nil();
    }
    if (b == ast__ast__BuiltinType_BT_F32) {
      (v = ((double)((float)v)));
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FLOAT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .f = v } };
  }
  if (o.kind == consteval__consteval__CV_FLOAT) {
    if (!consteval__consteval__ce_isfinite(o.as_data.f)) {
      return consteval__consteval__cv_nil();
    }
    const double t = trunc(o.as_data.f);
    if ((t < -9.3000003007293686e+18f) || (t > 1.8e19)) {
      return consteval__consteval__cv_nil();
    }
    int64_t iv = ((int64_t)t);
    if (consteval__consteval__bt_unsigned(b)) {
      (iv = ((int64_t)((uint64_t)t)));
    }
    if ((!consteval__consteval__fits(b, iv)) && (consteval__consteval__bt_bits(b) < 64)) {
      return consteval__consteval__cv_nil();
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = consteval__consteval__wrap_to(b, iv) } };
  }
  if ((o.kind == consteval__consteval__CV_BOOL) || (o.kind == consteval__consteval__CV_INT)) {
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = consteval__consteval__wrap_to(b, o.as_data.i) } };
  }
  return consteval__consteval__cv_nil();
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_binary(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__Node *const n = ast__ast__Ast__at_const(&((*a)), id);
  const lexer__token_type__TokenType op = n->as_data.binary.op;
  const uint32_t left = n->as_data.binary.left;
  const uint32_t right = n->as_data.binary.right;
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  const consteval__consteval__RType sr = consteval__consteval__ConstEval__ce_strip_refptr(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, left));
  if (sr.ok) {
    const ast__ast__TypeKind lyk = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, sr.m))), sr.t)->kind;
    if ((lyk == ast__ast__TypeKind_TYPE_STRUCT) || (lyk == ast__ast__TypeKind_TYPE_INSTANCE)) {
      str mn = (str){ (const uint8_t *)"", sizeof("") - 1 };
      if (op == lexer__token_type__TokenType_Plus) {
        (mn = (str){ (const uint8_t *)"add", sizeof("add") - 1 });
      } else if (op == lexer__token_type__TokenType_Minus) {
        (mn = (str){ (const uint8_t *)"sub", sizeof("sub") - 1 });
      } else if (op == lexer__token_type__TokenType_Star) {
        (mn = (str){ (const uint8_t *)"mul", sizeof("mul") - 1 });
      } else if (op == lexer__token_type__TokenType_Slash) {
        (mn = (str){ (const uint8_t *)"div", sizeof("div") - 1 });
      } else if (op == lexer__token_type__TokenType_Percent) {
        (mn = (str){ (const uint8_t *)"rem", sizeof("rem") - 1 });
      } else if ((op == lexer__token_type__TokenType_EqualEqual) || (op == lexer__token_type__TokenType_BangEqual)) {
        (mn = (str){ (const uint8_t *)"eq", sizeof("eq") - 1 });
      } else if ((((op == lexer__token_type__TokenType_LessThan) || (op == lexer__token_type__TokenType_LessThanEqual)) || (op == lexer__token_type__TokenType_GreaterThan)) || (op == lexer__token_type__TokenType_GreaterThanEqual)) {
        (mn = (str){ (const uint8_t *)"cmp", sizeof("cmp") - 1 });
      }
      if (str__len(&mn) != 0ULL) {
        const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, sr.m, sr.t);
        if (!rr.ok) {
          return consteval__consteval__cv_nil();
        }
        consteval__consteval__CeVal lhs = consteval__consteval__cv_nil();
        const consteval__consteval__ValRes lp = consteval__consteval__ConstEval__ev_place(self, f, m, left);
        if (lp.ok) {
          (lhs = lp.v);
        } else {
          const consteval__consteval__CeVal lv = consteval__consteval__ConstEval__ev_in(self, f, m, left);
          const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, lv);
          if ((lv.kind == consteval__consteval__CV_NIL_K) || (!tr.ok)) {
            return consteval__consteval__cv_nil();
          }
          (lhs = tr.v);
        }
        consteval__consteval__CeVal rhs = consteval__consteval__cv_nil();
        const consteval__consteval__ValRes rp = consteval__consteval__ConstEval__ev_place(self, f, m, right);
        if (rp.ok) {
          (rhs = rp.v);
        } else {
          const consteval__consteval__CeVal rv = consteval__consteval__ConstEval__ev_rval(self, f, m, right);
          const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, rv);
          if ((rv.kind == consteval__consteval__CV_NIL_K) || (!tr.ok)) {
            return consteval__consteval__cv_nil();
          }
          (rhs = tr.v);
        }
        consteval__consteval__CeVal args[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
        (args[0] = lhs);
        (args[1] = rhs);
        const consteval__consteval__ValRes dr = consteval__consteval__ConstEval__ce_dispatch(self, rr.r, m, mn, ((const consteval__consteval__CeVal *)(&args[0])), 2U);
        if (!dr.ok) {
          return consteval__consteval__cv_nil();
        }
        consteval__consteval__CeVal res = dr.v;
        if ((op == lexer__token_type__TokenType_EqualEqual) || (op == lexer__token_type__TokenType_BangEqual)) {
          if (res.kind != consteval__consteval__CV_BOOL) {
            return consteval__consteval__cv_nil();
          }
          if (op == lexer__token_type__TokenType_BangEqual) {
            (res.as_data.i = consteval__consteval__if_i64((res.as_data.i == 0), 1, 0));
          }
          (res.tm = m);
          (res.ty = rt);
          return res;
        }
        if (str__byte_at(&mn, 0ULL) == 99U) {
          if (res.kind != consteval__consteval__CV_INT) {
            return consteval__consteval__cv_nil();
          }
          const int64_t c = res.as_data.i;
          int64_t v = 0;
          if (op == lexer__token_type__TokenType_LessThan) {
            (v = consteval__consteval__if_i64((c < 0), 1, 0));
          } else if (op == lexer__token_type__TokenType_LessThanEqual) {
            (v = consteval__consteval__if_i64((c <= 0), 1, 0));
          } else if (op == lexer__token_type__TokenType_GreaterThan) {
            (v = consteval__consteval__if_i64((c > 0), 1, 0));
          } else {
            (v = consteval__consteval__if_i64((c >= 0), 1, 0));
          }
          return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_BOOL, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .i = v } };
        }
        return res;
      }
    }
  }
  const consteval__consteval__CeVal l = consteval__consteval__ConstEval__ev_rval(self, f, m, left);
  if (l.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__cv_nil();
  }
  const consteval__consteval__CeVal r = consteval__consteval__ConstEval__ev_rval(self, f, m, right);
  if (r.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__cv_nil();
  }
  if ((l.kind == consteval__consteval__CV_PTR) || (r.kind == consteval__consteval__CV_PTR)) {
    if ((op == lexer__token_type__TokenType_EqualEqual) || (op == lexer__token_type__TokenType_BangEqual)) {
      if ((l.kind != consteval__consteval__CV_PTR) || (r.kind != consteval__consteval__CV_PTR)) {
        return consteval__consteval__cv_nil();
      }
      const bool eq = ((l.as_data.p.obj == r.as_data.p.obj) && (l.as_data.p.off == r.as_data.p.off));
      bool vv = eq;
      if (op == lexer__token_type__TokenType_BangEqual) {
        (vv = (!eq));
      }
      return consteval__consteval__cv_bool(m, rt, vv);
    }
    if ((((op == lexer__token_type__TokenType_Plus) || (op == lexer__token_type__TokenType_Minus)) && (l.kind == consteval__consteval__CV_PTR)) && (r.kind == consteval__consteval__CV_INT)) {
      consteval__consteval__CeVal v = l;
      (v.tm = m);
      (v.ty = rt);
      if (op == lexer__token_type__TokenType_Plus) {
        (v.as_data.p.off = (v.as_data.p.off + ((uint32_t)r.as_data.i)));
      } else {
        (v.as_data.p.off = (v.as_data.p.off - ((uint32_t)r.as_data.i)));
      }
      return v;
    }
    if (((op == lexer__token_type__TokenType_Plus) && (r.kind == consteval__consteval__CV_PTR)) && (l.kind == consteval__consteval__CV_INT)) {
      consteval__consteval__CeVal v = r;
      (v.tm = m);
      (v.ty = rt);
      (v.as_data.p.off = (v.as_data.p.off + ((uint32_t)l.as_data.i)));
      return v;
    }
    return consteval__consteval__cv_nil();
  }
  if ((l.kind == consteval__consteval__CV_BOOL) && (r.kind == consteval__consteval__CV_BOOL)) {
    if (op == lexer__token_type__TokenType_AmpersandAmpersand) {
      return consteval__consteval__cv_bool(m, rt, ((l.as_data.i != 0) && (r.as_data.i != 0)));
    }
    if (op == lexer__token_type__TokenType_PipePipe) {
      return consteval__consteval__cv_bool(m, rt, ((l.as_data.i != 0) || (r.as_data.i != 0)));
    }
    if (op == lexer__token_type__TokenType_EqualEqual) {
      return consteval__consteval__cv_bool(m, rt, (l.as_data.i == r.as_data.i));
    }
    if (op == lexer__token_type__TokenType_BangEqual) {
      return consteval__consteval__cv_bool(m, rt, (l.as_data.i != r.as_data.i));
    }
    return consteval__consteval__cv_nil();
  }
  if ((l.kind == consteval__consteval__CV_FLOAT) && (r.kind == consteval__consteval__CV_FLOAT)) {
    return consteval__consteval__ce_float_op(op, l, r, m, rt, consteval__consteval__ConstEval__ce_builtin_of(self, f, m, rt));
  }
  if ((l.kind != consteval__consteval__CV_INT) || (r.kind != consteval__consteval__CV_INT)) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__BuiltinType rb = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, rt);
  const ast__ast__BuiltinType lb = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, left));
  ast__ast__BuiltinType ob = lb;
  if ((op != lexer__token_type__TokenType_LeftShift) && (op != lexer__token_type__TokenType_RightShift)) {
    ast__ast__BuiltinType lbc = lb;
    if (lb == ast__ast__BuiltinType_BT_COUNT) {
      (lbc = rb);
    }
    (ob = consteval__consteval__ce_arith_common(lbc, consteval__consteval__ConstEval__ce_builtin_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, right))));
  }
  return consteval__consteval__ConstEval__ce_int_op(self, op, l, r, m, rt, rb, ob);
}

static __attribute__((unused)) int64_t consteval__consteval__if_i64(bool const c, int64_t const a, int64_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_block(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__NodeList stmts = ast__ast__Ast__at_const(&((*a)), id)->as_data.block.statements;
  if ((f == NULL) || (stmts.len == 0U)) {
    return consteval__consteval__cv_nil();
  }
  const uint8_t dbase = (*f).ndefers;
  consteval__consteval__CeVal out = consteval__consteval__cv_nil();
  bool ok = true;
  uint32_t i = 0U;
  while (ok && ((i + 1U) < stmts.len)) {
    const uint32_t sid = ast__ast__Ast__list(&((*a)), stmts)[((size_t)i)];
    (ok = (consteval__consteval__ConstEval__exec_stmt(self, f, m, sid) == consteval__consteval__Flow_Ok));
    (i = (i + 1U));
  }
  if (ok) {
    const uint32_t lastid = ast__ast__Ast__list(&((*a)), stmts)[((size_t)(stmts.len - 1U))];
    const ast__ast__Node *const last = ast__ast__Ast__at_const(&((*a)), lastid);
    if ((last->kind == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) && (ast__ast__Ast__at_const(&((*a)), last->as_data.single.value)->kind != ast__ast__NodeKind_NODE_ASSIGNMENT)) {
      (out = consteval__consteval__ConstEval__ev_in(self, f, m, last->as_data.single.value));
    }
  }
  uint8_t j = (*f).ndefers;
  while (j > dbase) {
    (j = ((uint8_t)((uint32_t)j - (uint32_t)1U)));
    const uint32_t dv = (*f).defers[((size_t)j)];
    const ast__ast__NodeKind dk = ast__ast__Ast__at_const(&((*a)), dv)->kind;
    consteval__consteval__Flow ds = consteval__consteval__Flow_Ok;
    if (dk == ast__ast__NodeKind_NODE_BLOCK) {
      (ds = consteval__consteval__ConstEval__exec_stmt(self, f, m, dv));
    } else {
      (ds = consteval__consteval__ConstEval__exec_expr_stmt(self, f, m, dv));
    }
    if (ds != consteval__consteval__Flow_Ok) {
      (out = consteval__consteval__cv_nil());
    }
  }
  ((*f).ndefers = dbase);
  return out;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_index(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t obj_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.index.object;
  const uint32_t index_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.index.index;
  uint16_t bm = m;
  uint32_t bt = consteval__consteval__ConstEval__ce_type(self, m, obj_n);
  for (int32_t _ = 0; _ < 4; _++) {
    const consteval__consteval__RType r = consteval__consteval__ConstEval__ce_rtype(self, f, bm, bt);
    if (!r.ok) {
      return consteval__consteval__cv_nil();
    }
    (bm = r.m);
    (bt = r.t);
    const ast__ast__Ty *const y = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, bm))), bt);
    if (y->kind != ast__ast__TypeKind_TYPE_REFERENCE) {
      break;
    }
    (bt = y->as_data.elem);
  }
  const ast__ast__TypeKind yk = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, bm))), bt)->kind;
  if ((yk == ast__ast__TypeKind_TYPE_STRUCT) || (yk == ast__ast__TypeKind_TYPE_INSTANCE)) {
    const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, bm, bt);
    if (!rr.ok) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeVal recv = consteval__consteval__cv_nil();
    const consteval__consteval__ValRes rp = consteval__consteval__ConstEval__ev_place(self, f, m, obj_n);
    if (rp.ok) {
      (recv = rp.v);
    } else {
      const consteval__consteval__CeVal rv = consteval__consteval__ConstEval__ev_in(self, f, m, obj_n);
      const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, rv);
      if ((rv.kind == consteval__consteval__CV_NIL_K) || (!tr.ok)) {
        return consteval__consteval__cv_nil();
      }
      (recv = tr.v);
    }
    if (ast__ast__Ast__at_const(&((*a)), index_n)->kind == ast__ast__NodeKind_NODE_RANGE) {
      const consteval__consteval__CeVal iv = consteval__consteval__ConstEval__ce_range_obj(self, f, m, index_n);
      if (iv.kind != consteval__consteval__CV_AGG) {
        return consteval__consteval__cv_nil();
      }
      consteval__consteval__CeVal args[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
      (args[0] = recv);
      (args[1] = iv);
      const consteval__consteval__ValRes dr = consteval__consteval__ConstEval__ce_dispatch(self, rr.r, m, (str){ (const uint8_t *)"index_range", sizeof("index_range") - 1 }, ((const consteval__consteval__CeVal *)(&args[0])), 2U);
      if ((!dr.ok) || (dr.v.kind != consteval__consteval__CV_AGG)) {
        return consteval__consteval__cv_nil();
      }
      return dr.v;
    }
    const consteval__consteval__CeVal iv = consteval__consteval__ConstEval__ev_rval(self, f, m, index_n);
    if (iv.kind != consteval__consteval__CV_INT) {
      return consteval__consteval__cv_nil();
    }
    consteval__consteval__CeVal args[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
    (args[0] = recv);
    (args[1] = iv);
    const consteval__consteval__ValRes dr = consteval__consteval__ConstEval__ce_dispatch(self, rr.r, m, (str){ (const uint8_t *)"index", sizeof("index") - 1 }, ((const consteval__consteval__CeVal *)(&args[0])), 2U);
    if ((!dr.ok) || (dr.v.kind != consteval__consteval__CV_PTR)) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, dr.v);
    if (!lr.ok) {
      return consteval__consteval__cv_nil();
    }
    return lr.v;
  }
  const consteval__consteval__ValRes pr = consteval__consteval__ConstEval__ev_place(self, f, m, id);
  if (!pr.ok) {
    return consteval__consteval__cv_nil();
  }
  const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, pr.v);
  if (!lr.ok) {
    return consteval__consteval__cv_nil();
  }
  return lr.v;
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_struct_init(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t tn = ast__ast__Ast__at_const(&((*a)), id)->as_data.struct_initializer.ty;
  const ast__ast__NodeList fields = ast__ast__Ast__at_const(&((*a)), id)->as_data.struct_initializer.fields;
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  ast__ast__DefId vd = ast__ast__Ast__resolution_def(&((*a)), tn);
  if (vd.node == ast__ast__NODE_NONE) {
    (vd = (ast__ast__DefId){ .module = m, .node = ast__ast__Ast__resolution(&((*a)), tn) });
  }
  if (((((vd.node != ast__ast__NODE_NONE) && (((size_t)vd.module) < self->nmods)) && (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_ENUM)) && (ast__ast__Ast__at_const(&((*a)), tn)->kind == ast__ast__NodeKind_NODE_TYPE_PATH)) && (ast__ast__Ast__at_const(&((*a)), tn)->as_data.type_path.parts.len >= 2U)) {
    const ast__ast__NodeList parts = ast__ast__Ast__at_const(&((*a)), tn)->as_data.type_path.parts;
    const uint32_t last = ast__ast__Ast__list(&((*a)), parts)[((size_t)(parts.len - 1U))];
    const lexer__token__Span vn = consteval__consteval__ConstEval__name_text(self, m, last);
    const ast__ast__Ast *const ea = consteval__consteval__ConstEval__ast_ptr(self, vd.module);
    const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*ea)), vd.node)->as_data.aggregate.members;
    uint32_t hit = ast__ast__NODE_NONE;
    for (uint32_t k = 0U; k < ms.len; k++) {
      const uint32_t mid = ast__ast__Ast__list(&((*ea)), ms)[((size_t)k)];
      const lexer__token__Span vname = consteval__consteval__ConstEval__name_text(self, vd.module, ast__ast__Ast__at_const(&((*ea)), mid)->as_data.variant.name);
      if (consteval__consteval__ConstEval__ce_spans_eq(self, vd.module, vname, m, vn)) {
        (hit = mid);
        break;
      }
    }
    if (hit != ast__ast__NODE_NONE) {
      (vd.node = hit);
    }
  }
  if (((vd.node != ast__ast__NODE_NONE) && (((size_t)vd.module) < self->nmods)) && (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, vd.module))), vd.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
    const consteval__consteval__VarPos vp = consteval__consteval__ConstEval__ce_variant_pos(self, vd.module, vd.node);
    const ast__ast__NodeList payload = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, vd.module))), vd.node)->as_data.variant.payload;
    const bool struct_payload = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, vd.module))), vd.node)->as_data.variant.struct_payload;
    if (((vp.pos < 0) || (!struct_payload)) || consteval__consteval__ConstEval__ce_user_free(self, vd.module, vp.enum_decl)) {
      return consteval__consteval__cv_nil();
    }
    const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, (1U + payload.len));
    if (o == 0U) {
      return consteval__consteval__cv_nil();
    }
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).is_enum = 1U);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dm = vd.module);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dn = vp.enum_decl);
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, 0ULL, (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .i = ((int64_t)vp.pos) } });
    const ast__ast__Ast *const da = consteval__consteval__ConstEval__ast_ptr(self, vd.module);
    for (uint32_t i = 0U; i < fields.len; i++) {
      const uint32_t fid = ast__ast__Ast__list(&((*a)), fields)[((size_t)i)];
      const ast__ast__NodeKind fkind = ast__ast__Ast__at_const(&((*a)), fid)->kind;
      const uint32_t fname_node = ast__ast__Ast__at_const(&((*a)), fid)->as_data.field_initializer.name;
      if ((fkind != ast__ast__NodeKind_NODE_FIELD_INITIALIZER) || (fname_node == ast__ast__NODE_NONE)) {
        return consteval__consteval__cv_nil();
      }
      int32_t slot = -1;
      for (uint32_t j = 0U; j < payload.len; j++) {
        const uint32_t pfid = ast__ast__Ast__list(&((*da)), payload)[((size_t)j)];
        if (ast__ast__Ast__at_const(&((*da)), pfid)->kind == ast__ast__NodeKind_NODE_FIELD) {
          const lexer__token__Span pfname = consteval__consteval__ConstEval__name_text(self, vd.module, ast__ast__Ast__at_const(&((*da)), pfid)->as_data.field.name);
          if (consteval__consteval__ConstEval__ce_spans_eq(self, vd.module, pfname, m, consteval__consteval__ConstEval__name_text(self, m, fname_node))) {
            (slot = ((int32_t)j));
            break;
          }
        }
      }
      const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_rval(self, f, m, ast__ast__Ast__at_const(&((*a)), fid)->as_data.field_initializer.value);
      if ((slot < 0) || (v.kind == consteval__consteval__CV_NIL_K)) {
        return consteval__consteval__cv_nil();
      }
      const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, v, 0);
      if (cloned.kind == consteval__consteval__CV_NIL_K) {
        return consteval__consteval__cv_nil();
      }
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)({ int32_t __sc_r; if (__builtin_add_overflow(1, slot, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; })), cloned);
    }
    return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } };
  }
  const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, m, rt);
  if ((!rr.ok) || (rr.r.dn == ast__ast__NODE_NONE)) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__Ast *const da = consteval__consteval__ConstEval__ast_ptr(self, rr.r.dm);
  const ast__ast__NodeKind dkind = ast__ast__Ast__at_const(&((*da)), rr.r.dn)->kind;
  const bool is_union = ast__ast__Ast__at_const(&((*da)), rr.r.dn)->as_data.aggregate.is_union;
  if ((dkind != ast__ast__NodeKind_NODE_STRUCT) || is_union) {
    return consteval__consteval__cv_nil();
  }
  if (consteval__consteval__ConstEval__ce_user_free(self, rr.r.dm, rr.r.dn)) {
    return consteval__consteval__cv_nil();
  }
  const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, consteval__consteval__ConstEval__ce_field_count(self, rr.r.dm, rr.r.dn));
  if (o == 0U) {
    return consteval__consteval__cv_nil();
  }
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dm = rr.r.dm);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dn = rr.r.dn);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).nargs = rr.r.n);
  for (int32_t ci = 0; ci < 4; ci++) {
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).am[ci] = rr.r.am[ci]);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).at[ci] = rr.r.at[ci]);
  }
  for (uint32_t i = 0U; i < fields.len; i++) {
    const uint32_t fid = ast__ast__Ast__list(&((*a)), fields)[((size_t)i)];
    const ast__ast__NodeKind fkind = ast__ast__Ast__at_const(&((*a)), fid)->kind;
    const uint32_t fname_node = ast__ast__Ast__at_const(&((*a)), fid)->as_data.field_initializer.name;
    if ((fkind != ast__ast__NodeKind_NODE_FIELD_INITIALIZER) || (fname_node == ast__ast__NODE_NONE)) {
      return consteval__consteval__cv_nil();
    }
    const lexer__token__Span fname = consteval__consteval__ConstEval__name_text(self, m, fname_node);
    const consteval__consteval__FieldIdx fi = consteval__consteval__ConstEval__ce_field_index(self, rr.r.dm, rr.r.dn, m, fname);
    if (fi.idx < 0) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_rval(self, f, m, ast__ast__Ast__at_const(&((*a)), fid)->as_data.field_initializer.value);
    if (v.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, v, 0);
    if (cloned.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)fi.idx), cloned);
  }
  const ast__ast__NodeList ms = ast__ast__Ast__at_const(&((*da)), rr.r.dn)->as_data.aggregate.members;
  int32_t idx = 0;
  for (uint32_t k = 0U; k < ms.len; k++) {
    const uint32_t fd = ast__ast__Ast__list(&((*da)), ms)[((size_t)k)];
    if (ast__ast__Ast__at_const(&((*da)), fd)->kind == ast__ast__NodeKind_NODE_FIELD) {
      if ((*({ __auto_type __sc125 = &(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots; Vector__consteval__consteval__CeVal__Global__index(__sc125, ((size_t)idx)); })).kind == consteval__consteval__CV_NIL_K) {
        const uint32_t fval = ast__ast__Ast__at_const(&((*da)), fd)->as_data.field.value;
        if (fval == ast__ast__NODE_NONE) {
          return consteval__consteval__cv_nil();
        }
        const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, NULL, rr.r.dm, fval);
        if (v.kind == consteval__consteval__CV_NIL_K) {
          return consteval__consteval__cv_nil();
        }
        const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, v, 0);
        Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)idx), cloned);
      }
      (idx = ({ int32_t __sc_r; if (__builtin_add_overflow(idx, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_array_lit(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__NodeList elements = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_literal.elements;
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  const consteval__consteval__RType r2 = consteval__consteval__ConstEval__ce_rtype(self, f, m, rt);
  if (!r2.ok) {
    return consteval__consteval__cv_nil();
  }
  const ast__ast__Ty y = (*ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, r2.m))), r2.t));
  if (y.kind != ast__ast__TypeKind_TYPE_ARRAY) {
    return consteval__consteval__cv_nil();
  }
  const uint32_t count = elements.len;
  uint32_t len = y.as_data.arr.len;
  if (len == 0U) {
    (len = count);
    uint32_t cur = 0U;
    for (uint32_t i = 0U; i < count; i++) {
      const uint32_t el = ast__ast__Ast__list(&((*a)), elements)[((size_t)i)];
      if (ast__ast__Ast__at_const(&((*a)), el)->kind == ast__ast__NodeKind_NODE_FIELD_INITIALIZER) {
        const consteval__consteval__CeVal iv = consteval__consteval__ConstEval__ev_in(self, NULL, m, ast__ast__Ast__at_const(&((*a)), el)->as_data.field_initializer.name);
        if ((iv.kind != consteval__consteval__CV_INT) || (iv.as_data.i < 0)) {
          return consteval__consteval__cv_nil();
        }
        (cur = ((uint32_t)iv.as_data.i));
      }
      (cur = (cur + 1U));
      if (cur > len) {
        (len = cur);
      }
    }
  }
  const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, len);
  if (o == 0U) {
    return consteval__consteval__cv_nil();
  }
  if (count < len) {
    const consteval__consteval__RType er = consteval__consteval__ConstEval__ce_rtype(self, f, r2.m, y.as_data.arr.elem);
    if (!er.ok) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal z = consteval__consteval__ConstEval__ce_zero(self, er.m, er.t, 0);
    if (z.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    for (uint32_t i = 0U; i < len; i++) {
      const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, z, 0);
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)i), cloned);
    }
  }
  uint32_t cursor = 0U;
  for (uint32_t i = 0U; i < count; i++) {
    const uint32_t el = ast__ast__Ast__list(&((*a)), elements)[((size_t)i)];
    uint32_t value = el;
    if (ast__ast__Ast__at_const(&((*a)), el)->kind == ast__ast__NodeKind_NODE_FIELD_INITIALIZER) {
      const consteval__consteval__CeVal iv = consteval__consteval__ConstEval__ev_in(self, NULL, m, ast__ast__Ast__at_const(&((*a)), el)->as_data.field_initializer.name);
      if ((iv.kind != consteval__consteval__CV_INT) || (iv.as_data.i < 0)) {
        return consteval__consteval__cv_nil();
      }
      (cursor = ((uint32_t)iv.as_data.i));
      (value = ast__ast__Ast__at_const(&((*a)), el)->as_data.field_initializer.value);
    }
    if (cursor >= len) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_rval(self, f, m, value);
    if (v.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, v, 0);
    if (cloned.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)cursor), cloned);
    (cursor = (cursor + 1U));
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } };
}

static __attribute__((unused)) consteval__consteval__CeVal consteval__consteval__ConstEval__ev_tuple(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__NodeList elements = ast__ast__Ast__at_const(&((*a)), id)->as_data.array_literal.elements;
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, id);
  const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, m, rt);
  if ((!rr.ok) || (rr.r.dn == ast__ast__NODE_NONE)) {
    return consteval__consteval__cv_nil();
  }
  const uint32_t count = elements.len;
  const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, count);
  if (o == 0U) {
    return consteval__consteval__cv_nil();
  }
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dm = rr.r.dm);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dn = rr.r.dn);
  ((*consteval__consteval__ConstEval__obj_ptr(self, o)).nargs = rr.r.n);
  for (int32_t ci = 0; ci < 4; ci++) {
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).am[ci] = rr.r.am[ci]);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).at[ci] = rr.r.at[ci]);
  }
  for (uint32_t i = 0U; i < count; i++) {
    const uint32_t el = ast__ast__Ast__list(&((*a)), elements)[((size_t)i)];
    const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_rval(self, f, m, el);
    if (v.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, v, 0);
    if (cloned.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__cv_nil();
    }
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)i), cloned);
  }
  return (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } };
}

static __attribute__((unused)) int32_t consteval__consteval__ConstEval__pat_match(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const pid, consteval__consteval__CeVal const v, bool const uns, uint32_t const refobj) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__NodeKind pk = ast__ast__Ast__at_const(&((*a)), pid)->kind;
  if (pk == ast__ast__NodeKind_NODE_PATTERN_WILDCARD) {
    return 1;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_NAME) {
    const uint32_t name_node = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.name;
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), name_node);
    if (((d.node != ast__ast__NODE_NONE) && (((size_t)d.module) < self->nmods)) && (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->kind == ast__ast__NodeKind_NODE_VARIANT)) {
      if ((v.kind == consteval__consteval__CV_INT) || (v.kind == consteval__consteval__CV_BOOL)) {
        const consteval__consteval__ConstValue tv = consteval__consteval__ConstEval__variant_value(self, d.module, d.node);
        if (tv.kind == consteval__consteval__CONST_INT) {
          return consteval__consteval__if_i32((tv.as_data.i == v.as_data.i), 1, 0);
        }
        return -1;
      }
      if (v.kind == consteval__consteval__CV_AGG) {
        consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
        const consteval__consteval__VarPos vp = consteval__consteval__ConstEval__ce_variant_pos(self, d.module, d.node);
        if (((o != NULL) && ((*o).is_enum != 0U)) && (vp.pos >= 0)) {
          return consteval__consteval__if_i32(((*({ __auto_type __sc126 = &(*o).slots; Vector__consteval__consteval__CeVal__Global__index(__sc126, 0ULL); })).as_data.i == ((int64_t)vp.pos)), 1, 0);
        }
        return -1;
      }
      return -1;
    }
    if (!((f != NULL) && consteval__consteval__ConstEval__ce_bind(self, f, pid, v))) {
      return -1;
    }
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.children;
    if (children.len != 0U) {
      const uint32_t sub = ast__ast__Ast__list(&((*a)), children)[0];
      return consteval__consteval__ConstEval__pat_match(self, f, m, sub, v, uns, refobj);
    }
    return 1;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_LITERAL) {
    const consteval__consteval__CeVal lv = consteval__consteval__ConstEval__ev_in(self, NULL, m, ast__ast__Ast__at_const(&((*a)), pid)->as_data.single.value);
    if ((lv.kind != consteval__consteval__CV_INT) && (lv.kind != consteval__consteval__CV_BOOL)) {
      return -1;
    }
    return consteval__consteval__if_i32(((lv.as_data.i == v.as_data.i) && ((v.kind == consteval__consteval__CV_INT) || (v.kind == consteval__consteval__CV_BOOL))), 1, 0);
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_RANGE) {
    if (v.kind != consteval__consteval__CV_INT) {
      return -1;
    }
    const uint32_t start_n = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern_range.start;
    const uint32_t end_n = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern_range.end;
    const bool inclusive = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern_range.inclusive;
    if (start_n != ast__ast__NODE_NONE) {
      uint32_t sn = start_n;
      if (ast__ast__Ast__at_const(&((*a)), start_n)->kind == ast__ast__NodeKind_NODE_PATTERN_LITERAL) {
        (sn = ast__ast__Ast__at_const(&((*a)), start_n)->as_data.single.value);
      }
      const consteval__consteval__CeVal s = consteval__consteval__ConstEval__ev_in(self, NULL, m, sn);
      if (s.kind != consteval__consteval__CV_INT) {
        return -1;
      }
      const bool below = consteval__consteval__if_bool(uns, (((uint64_t)v.as_data.i) < ((uint64_t)s.as_data.i)), (v.as_data.i < s.as_data.i));
      if (below) {
        return 0;
      }
    }
    if (end_n != ast__ast__NODE_NONE) {
      uint32_t en = end_n;
      if (ast__ast__Ast__at_const(&((*a)), end_n)->kind == ast__ast__NodeKind_NODE_PATTERN_LITERAL) {
        (en = ast__ast__Ast__at_const(&((*a)), end_n)->as_data.single.value);
      }
      const consteval__consteval__CeVal e = consteval__consteval__ConstEval__ev_in(self, NULL, m, en);
      if (e.kind != consteval__consteval__CV_INT) {
        return -1;
      }
      bool above = false;
      if (inclusive) {
        (above = consteval__consteval__if_bool(uns, (((uint64_t)v.as_data.i) > ((uint64_t)e.as_data.i)), (v.as_data.i > e.as_data.i)));
      } else {
        (above = consteval__consteval__if_bool(uns, (((uint64_t)v.as_data.i) >= ((uint64_t)e.as_data.i)), (v.as_data.i >= e.as_data.i)));
      }
      if (above) {
        return 0;
      }
    }
    return 1;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_OR) {
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.children;
    for (uint32_t i = 0U; i < children.len; i++) {
      const uint32_t cid = ast__ast__Ast__list(&((*a)), children)[((size_t)i)];
      const int32_t r = consteval__consteval__ConstEval__pat_match(self, f, m, cid, v, uns, refobj);
      if (r != 0) {
        return r;
      }
    }
    return 0;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
    const uint32_t pname = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.name;
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.children;
    if (pname == ast__ast__NODE_NONE) {
      if (children.len == 1U) {
        return consteval__consteval__ConstEval__pat_match(self, f, m, ast__ast__Ast__list(&((*a)), children)[0], v, uns, refobj);
      }
      return -1;
    }
    if (v.kind != consteval__consteval__CV_AGG) {
      return -1;
    }
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), pname);
    if ((d.node == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_VARIANT)) {
      return -1;
    }
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
    const consteval__consteval__VarPos vp = consteval__consteval__ConstEval__ce_variant_pos(self, d.module, d.node);
    if (((o == NULL) || ((*o).is_enum == 0U)) || (vp.pos < 0)) {
      return -1;
    }
    if ((*({ __auto_type __sc127 = &(*o).slots; Vector__consteval__consteval__CeVal__Global__index(__sc127, 0ULL); })).as_data.i != ((int64_t)vp.pos)) {
      return 0;
    }
    for (uint32_t k = 0U; k < children.len; k++) {
      const uint32_t cid = ast__ast__Ast__list(&((*a)), children)[((size_t)k)];
      if ((1U + k) >= ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots))) {
        return -1;
      }
      if (((refobj != 0U) && (ast__ast__Ast__at_const(&((*a)), cid)->kind == ast__ast__NodeKind_NODE_PATTERN_NAME)) && (ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), cid)->as_data.pattern.name).node == ast__ast__NODE_NONE)) {
        const consteval__consteval__CeVal pv = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = refobj, .off = (1U + k) } } };
        if ((f == NULL) || (!consteval__consteval__ConstEval__ce_bind(self, f, cid, pv))) {
          return -1;
        }
        continue;
      }
      const consteval__consteval__CeVal sv = (*({ __auto_type __sc128 = &(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots; Vector__consteval__consteval__CeVal__Global__index(__sc128, ((size_t)(1U + k))); }));
      if (sv.kind == consteval__consteval__CV_NIL_K) {
        return -1;
      }
      const int32_t r = consteval__consteval__ConstEval__pat_match(self, f, m, cid, sv, uns, 0U);
      if (r != 1) {
        return r;
      }
    }
    return 1;
  }
  if (pk == ast__ast__NodeKind_NODE_PATTERN_STRUCT) {
    const uint32_t pname = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.name;
    if ((v.kind != consteval__consteval__CV_AGG) || (pname == ast__ast__NODE_NONE)) {
      return -1;
    }
    const ast__ast__DefId d = ast__ast__Ast__resolution_def(&((*a)), pname);
    if ((d.node == ast__ast__NODE_NONE) || (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, d.module))), d.node)->kind != ast__ast__NodeKind_NODE_VARIANT)) {
      return -1;
    }
    consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj);
    const consteval__consteval__VarPos vp = consteval__consteval__ConstEval__ce_variant_pos(self, d.module, d.node);
    if (((o == NULL) || ((*o).is_enum == 0U)) || (vp.pos < 0)) {
      return -1;
    }
    if ((*({ __auto_type __sc129 = &(*o).slots; Vector__consteval__consteval__CeVal__Global__index(__sc129, 0ULL); })).as_data.i != ((int64_t)vp.pos)) {
      return 0;
    }
    const ast__ast__Ast *const da = consteval__consteval__ConstEval__ast_ptr(self, d.module);
    const ast__ast__NodeList vpayload = ast__ast__Ast__at_const(&((*da)), d.node)->as_data.variant.payload;
    if (!ast__ast__Ast__at_const(&((*da)), d.node)->as_data.variant.struct_payload) {
      return -1;
    }
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*a)), pid)->as_data.pattern.children;
    for (uint32_t k = 0U; k < children.len; k++) {
      const uint32_t cid = ast__ast__Ast__list(&((*a)), children)[((size_t)k)];
      const uint32_t pfname = ast__ast__Ast__at_const(&((*a)), cid)->as_data.pattern.name;
      if ((ast__ast__Ast__at_const(&((*a)), cid)->kind != ast__ast__NodeKind_NODE_PATTERN_FIELD) || (pfname == ast__ast__NODE_NONE)) {
        return -1;
      }
      int32_t slot = -1;
      for (uint32_t j = 0U; j < vpayload.len; j++) {
        const uint32_t pfid = ast__ast__Ast__list(&((*da)), vpayload)[((size_t)j)];
        if (ast__ast__Ast__at_const(&((*da)), pfid)->kind == ast__ast__NodeKind_NODE_FIELD) {
          const lexer__token__Span fn2 = consteval__consteval__ConstEval__name_text(self, d.module, ast__ast__Ast__at_const(&((*da)), pfid)->as_data.field.name);
          if (consteval__consteval__ConstEval__ce_spans_eq(self, d.module, fn2, m, consteval__consteval__ConstEval__name_text(self, m, pfname))) {
            (slot = ((int32_t)j));
            break;
          }
        }
      }
      if ((slot < 0) || ((1U + ((uint32_t)slot)) >= ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots)))) {
        return -1;
      }
      const uint32_t child = ast__ast__Ast__list(&((*a)), ast__ast__Ast__at_const(&((*a)), cid)->as_data.pattern.children)[0];
      if ((refobj != 0U) && (ast__ast__Ast__at_const(&((*a)), child)->kind == ast__ast__NodeKind_NODE_IDENTIFIER)) {
        const consteval__consteval__CeVal pv = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = refobj, .off = (1U + ((uint32_t)slot)) } } };
        if ((f == NULL) || (!consteval__consteval__ConstEval__ce_bind(self, f, child, pv))) {
          return -1;
        }
        continue;
      }
      const consteval__consteval__CeVal sv = (*({ __auto_type __sc130 = &(*consteval__consteval__ConstEval__obj_ptr(self, v.as_data.p.obj)).slots; Vector__consteval__consteval__CeVal__Global__index(__sc130, ((size_t)({ int32_t __sc_r; if (__builtin_add_overflow(1, slot, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }))); }));
      if (sv.kind == consteval__consteval__CV_NIL_K) {
        return -1;
      }
      if (ast__ast__Ast__at_const(&((*a)), child)->kind == ast__ast__NodeKind_NODE_IDENTIFIER) {
        if ((f == NULL) || (!consteval__consteval__ConstEval__ce_bind(self, f, child, sv))) {
          return -1;
        }
        continue;
      }
      const int32_t r = consteval__consteval__ConstEval__pat_match(self, f, m, child, sv, uns, 0U);
      if (r != 1) {
        return r;
      }
    }
    return 1;
  }
  return -1;
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_match(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id, consteval__consteval__CeVal *const out) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t value_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.value;
  const ast__ast__NodeList arms = ast__ast__Ast__at_const(&((*a)), id)->as_data.match_expr.arms;
  consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, f, m, value_n);
  uint32_t refobj = 0U;
  int32_t guard = 0;
  while ((guard < 4) && (v.kind == consteval__consteval__CV_PTR)) {
    const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, v);
    if (!lr.ok) {
      return consteval__consteval__Flow_Bail;
    }
    (v = lr.v);
    if (v.kind == consteval__consteval__CV_AGG) {
      (refobj = v.as_data.p.obj);
    }
    (guard = ({ int32_t __sc_r; if (__builtin_add_overflow(guard, 1, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
  }
  if (v.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__xfail(f);
  }
  const ast__ast__BuiltinType sb = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, value_n));
  const bool uns = ((sb != ast__ast__BuiltinType_BT_COUNT) && consteval__consteval__bt_unsigned(sb));
  for (uint32_t i = 0U; i < arms.len; i++) {
    const uint32_t aid = ast__ast__Ast__list(&((*a)), arms)[((size_t)i)];
    const uint32_t pattern = ast__ast__Ast__at_const(&((*a)), aid)->as_data.match_arm.pattern;
    const uint32_t guard_n = ast__ast__Ast__at_const(&((*a)), aid)->as_data.match_arm.guard;
    const uint32_t body = ast__ast__Ast__at_const(&((*a)), aid)->as_data.match_arm.body;
    const int32_t hit = consteval__consteval__ConstEval__pat_match(self, f, m, pattern, v, uns, refobj);
    if (hit < 0) {
      return consteval__consteval__Flow_Bail;
    }
    if (hit == 0) {
      continue;
    }
    if (guard_n != ast__ast__NODE_NONE) {
      const consteval__consteval__CeVal g = consteval__consteval__ConstEval__ev_rval(self, f, m, guard_n);
      if (g.kind != consteval__consteval__CV_BOOL) {
        return consteval__consteval__xfail(f);
      }
      if (g.as_data.i == 0) {
        continue;
      }
    }
    if (out != NULL) {
      ((*out) = consteval__consteval__ConstEval__ev_in(self, f, m, body));
      if ((*out).kind != consteval__consteval__CV_NIL_K) {
        return consteval__consteval__Flow_Ok;
      }
      return consteval__consteval__xfail(f);
    }
    if (ast__ast__Ast__at_const(&((*a)), body)->kind == ast__ast__NodeKind_NODE_BLOCK) {
      return consteval__consteval__ConstEval__exec_stmt(self, f, m, body);
    }
    return consteval__consteval__ConstEval__exec_expr_stmt(self, f, m, body);
  }
  return consteval__consteval__Flow_Bail;
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_assign(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t left = ast__ast__Ast__at_const(&((*a)), id)->as_data.binary.left;
  const uint32_t right = ast__ast__Ast__at_const(&((*a)), id)->as_data.binary.right;
  const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*a)), id)->as_data.binary.op;
  const consteval__consteval__ValRes pr = consteval__consteval__ConstEval__ev_place(self, f, m, left);
  if (!pr.ok) {
    return consteval__consteval__xfail(f);
  }
  consteval__consteval__CeVal r = consteval__consteval__ConstEval__ev_rval(self, f, m, right);
  if (r.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__xfail(f);
  }
  if (op != lexer__token_type__TokenType_Equal) {
    const consteval__consteval__ValRes cur = consteval__consteval__ConstEval__ce_loadp(self, pr.v);
    if (!cur.ok) {
      return consteval__consteval__Flow_Bail;
    }
    const lexer__token_type__TokenType cop = consteval__consteval__compound_op(op);
    const uint32_t lt = consteval__consteval__ConstEval__ce_type(self, m, left);
    const ast__ast__BuiltinType tb = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, lt);
    if ((cur.v.kind == consteval__consteval__CV_FLOAT) && (r.kind == consteval__consteval__CV_FLOAT)) {
      (r = consteval__consteval__ce_float_op(cop, cur.v, r, m, lt, tb));
    } else if ((cur.v.kind == consteval__consteval__CV_INT) && (r.kind == consteval__consteval__CV_INT)) {
      (r = consteval__consteval__ConstEval__ce_int_op(self, cop, cur.v, r, m, lt, tb, tb));
    } else {
      return consteval__consteval__Flow_Bail;
    }
    if (r.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__Flow_Bail;
    }
  }
  if (consteval__consteval__ConstEval__ce_storep(self, pr.v, r)) {
    return consteval__consteval__Flow_Ok;
  }
  return consteval__consteval__Flow_Bail;
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_expr_stmt(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id0) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  uint32_t id = id0;
  for (;;) {
    const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*a)), id)->kind;
    if (k != ast__ast__NodeKind_NODE_UNARY) {
      break;
    }
    const lexer__token_type__TokenType op = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.op;
    if (((op != lexer__token_type__TokenType_Move) && (op != lexer__token_type__TokenType_Unsafe)) || (ast__ast__Ast__at_const(&((*a)), ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.operand)->kind == ast__ast__NodeKind_NODE_BLOCK)) {
      break;
    }
    (id = ast__ast__Ast__at_const(&((*a)), id)->as_data.unary.operand);
  }
  const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*a)), id)->kind;
  if (k == ast__ast__NodeKind_NODE_ASSIGNMENT) {
    return consteval__consteval__ConstEval__exec_assign(self, f, m, id);
  }
  if (k == ast__ast__NodeKind_NODE_MATCH) {
    return consteval__consteval__ConstEval__exec_match(self, f, m, id, NULL);
  }
  if (k == ast__ast__NodeKind_NODE_CALL) {
    const consteval__consteval__Rets cr = consteval__consteval__ConstEval__ce_call(self, f, m, id);
    if (cr.ok) {
      return consteval__consteval__Flow_Ok;
    }
    return consteval__consteval__xfail(f);
  }
  if (consteval__consteval__ConstEval__ev_in(self, f, m, id).kind != consteval__consteval__CV_NIL_K) {
    return consteval__consteval__Flow_Ok;
  }
  return consteval__consteval__xfail(f);
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_stmt(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  if (!consteval__consteval__ConstEval__ce_tick(self)) {
    return consteval__consteval__Flow_Bail;
  }
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const ast__ast__NodeKind k = ast__ast__Ast__at_const(&((*a)), id)->kind;
  {
    const ast__ast__NodeKind __sc131 = k;
    if (__sc131 == ast__ast__NodeKind_NODE_BLOCK) {
      {
        const ast__ast__NodeList stmts = ast__ast__Ast__at_const(&((*a)), id)->as_data.block.statements;
        const uint8_t dbase = (*f).ndefers;
        consteval__consteval__Flow st = consteval__consteval__Flow_Ok;
        uint32_t i = 0U;
        while ((st == consteval__consteval__Flow_Ok) && (i < stmts.len)) {
          (st = consteval__consteval__ConstEval__exec_stmt(self, f, m, ast__ast__Ast__list(&((*a)), stmts)[((size_t)i)]));
          (i = (i + 1U));
        }
        uint8_t j = (*f).ndefers;
        while (j > dbase) {
          (j = ((uint8_t)((uint32_t)j - (uint32_t)1U)));
          const uint32_t dv = (*f).defers[((size_t)j)];
          consteval__consteval__Flow ds = consteval__consteval__Flow_Ok;
          if (ast__ast__Ast__at_const(&((*a)), dv)->kind == ast__ast__NodeKind_NODE_BLOCK) {
            (ds = consteval__consteval__ConstEval__exec_stmt(self, f, m, dv));
          } else {
            (ds = consteval__consteval__ConstEval__exec_expr_stmt(self, f, m, dv));
          }
          if (ds != consteval__consteval__Flow_Ok) {
            (st = consteval__consteval__Flow_Bail);
          }
        }
        ((*f).ndefers = dbase);
        return st;
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_LET) {
      {
        return consteval__consteval__ConstEval__exec_let(self, f, m, id);
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_IF) {
      {
        const consteval__consteval__CeVal c = consteval__consteval__ConstEval__ev_rval(self, f, m, ast__ast__Ast__at_const(&((*a)), id)->as_data.if_stmt.condition);
        if (c.kind != consteval__consteval__CV_BOOL) {
          return consteval__consteval__xfail(f);
        }
        if (c.as_data.i != 0) {
          return consteval__consteval__ConstEval__exec_stmt(self, f, m, ast__ast__Ast__at_const(&((*a)), id)->as_data.if_stmt.then_branch);
        }
        const uint32_t eb = ast__ast__Ast__at_const(&((*a)), id)->as_data.if_stmt.else_branch;
        if (eb == ast__ast__NODE_NONE) {
          return consteval__consteval__Flow_Ok;
        }
        return consteval__consteval__ConstEval__exec_stmt(self, f, m, eb);
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_WHILE) {
      {
        return consteval__consteval__ConstEval__exec_while(self, f, m, id);
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_FOR) {
      {
        return consteval__consteval__ConstEval__exec_for(self, f, m, id);
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_RETURN) {
      {
        const ast__ast__NodeList values = ast__ast__Ast__at_const(&((*a)), id)->as_data.return_stmt.values;
        if (values.len > 8U) {
          return consteval__consteval__Flow_Bail;
        }
        ((*f).nrets = 0U);
        for (uint32_t i = 0U; i < values.len; i++) {
          const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, f, m, ast__ast__Ast__list(&((*a)), values)[((size_t)i)]);
          if (v.kind == consteval__consteval__CV_NIL_K) {
            return consteval__consteval__xfail(f);
          }
          const uint8_t nr = (*f).nrets;
          ((*f).rets[((size_t)nr)] = v);
          ((*f).nrets = ((uint8_t)((uint32_t)nr + (uint32_t)1U)));
        }
        ((*f).returned = 1U);
        return consteval__consteval__Flow_Return;
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_BREAK) {
      {
        const lexer__token__Span lbl = ast__ast__Ast__at_const(&((*a)), id)->as_data.flow.label;
        if ((lbl.end > lbl.start) || (ast__ast__Ast__at_const(&((*a)), id)->as_data.flow.value != ast__ast__NODE_NONE)) {
          return consteval__consteval__Flow_Bail;
        }
        return consteval__consteval__Flow_Break;
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_CONTINUE) {
      {
        const lexer__token__Span lbl = ast__ast__Ast__at_const(&((*a)), id)->as_data.flow.label;
        if (lbl.end > lbl.start) {
          return consteval__consteval__Flow_Bail;
        }
        return consteval__consteval__Flow_Continue;
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_DEFER) {
      {
        if ((*f).ndefers >= consteval__consteval__CE_MAX_DEFERS) {
          return consteval__consteval__Flow_Bail;
        }
        const uint8_t nd = (*f).ndefers;
        ((*f).defers[((size_t)nd)] = ast__ast__Ast__at_const(&((*a)), id)->as_data.single.value);
        ((*f).ndefers = ((uint8_t)((uint32_t)nd + (uint32_t)1U)));
        return consteval__consteval__Flow_Ok;
      }
    }
    else if (__sc131 == ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT) {
      {
        return consteval__consteval__ConstEval__exec_expr_stmt(self, f, m, ast__ast__Ast__at_const(&((*a)), id)->as_data.single.value);
      }
    }
    else if (1) {
      {
      }
    }
  }
  return consteval__consteval__Flow_Bail;
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_let(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t name_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.name;
  const uint32_t value_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.value;
  const uint32_t type_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.let_stmt.ty;
  const ast__ast__NodeKind nmk = ast__ast__Ast__at_const(&((*a)), name_n)->kind;
  if (nmk == ast__ast__NodeKind_NODE_PATTERN_TUPLE) {
    const ast__ast__NodeList children = ast__ast__Ast__at_const(&((*a)), name_n)->as_data.pattern.children;
    const uint32_t nbind = children.len;
    if (value_n == ast__ast__NODE_NONE) {
      return consteval__consteval__Flow_Bail;
    }
    consteval__consteval__CeVal vals[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
    uint32_t nvals = 0U;
    if (ast__ast__Ast__at_const(&((*a)), value_n)->kind == ast__ast__NodeKind_NODE_CALL) {
      const consteval__consteval__Rets cr = consteval__consteval__ConstEval__ce_call(self, f, m, value_n);
      if (!cr.ok) {
        return consteval__consteval__xfail(f);
      }
      for (uint8_t i = 0U; i < cr.n; i++) {
        (vals[__sc_bounds(((size_t)i), 8)] = cr.vals[((size_t)i)]);
      }
      (nvals = ((uint32_t)cr.n));
    }
    if (nvals <= 1U) {
      consteval__consteval__CeVal tv = consteval__consteval__cv_nil();
      if (nvals == 1U) {
        (tv = vals[0]);
      } else {
        (tv = consteval__consteval__ConstEval__ev_rval(self, f, m, value_n));
      }
      if (tv.kind != consteval__consteval__CV_AGG) {
        return consteval__consteval__xfail(f);
      }
      consteval__consteval__CeObj *const o = consteval__consteval__ConstEval__obj_ptr(self, tv.as_data.p.obj);
      if ((o == NULL) || (((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*o).slots)) < nbind)) {
        return consteval__consteval__Flow_Bail;
      }
      for (uint32_t i = 0U; i < nbind; i++) {
        (vals[__sc_bounds(((size_t)i), 8)] = (*({ __auto_type __sc132 = &(*consteval__consteval__ConstEval__obj_ptr(self, tv.as_data.p.obj)).slots; Vector__consteval__consteval__CeVal__Global__index(__sc132, ((size_t)i)); })));
      }
      (nvals = nbind);
    }
    if (nvals != nbind) {
      return consteval__consteval__Flow_Bail;
    }
    for (uint32_t i = 0U; i < nbind; i++) {
      const uint32_t cid = ast__ast__Ast__list(&((*a)), children)[((size_t)i)];
      if ((vals[__sc_bounds(((size_t)i), 8)].kind == consteval__consteval__CV_NIL_K) || (!consteval__consteval__ConstEval__ce_bind(self, f, cid, vals[__sc_bounds(((size_t)i), 8)]))) {
        return consteval__consteval__xfail(f);
      }
    }
    return consteval__consteval__Flow_Ok;
  }
  if (nmk != ast__ast__NodeKind_NODE_IDENTIFIER) {
    return consteval__consteval__Flow_Bail;
  }
  consteval__consteval__CeVal v = consteval__consteval__cv_nil();
  if (value_n != ast__ast__NODE_NONE) {
    if (type_n != ast__ast__NODE_NONE) {
      const consteval__consteval__RType wr = consteval__consteval__ConstEval__ce_rtype(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, type_n));
      if (!wr.ok) {
        return consteval__consteval__Flow_Bail;
      }
      const consteval__consteval__CeVal raw = consteval__consteval__ConstEval__ev_in(self, f, m, value_n);
      (v = consteval__consteval__ConstEval__ce_coerce(self, raw, wr.m, wr.t));
    } else {
      (v = consteval__consteval__ConstEval__ev_in(self, f, m, value_n));
    }
    if (v.kind == consteval__consteval__CV_NIL_K) {
      return consteval__consteval__xfail(f);
    }
  }
  if (consteval__consteval__ConstEval__ce_bind(self, f, id, v)) {
    return consteval__consteval__Flow_Ok;
  }
  return consteval__consteval__Flow_Bail;
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_while(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t cond = ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.condition;
  const uint32_t body = ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.body;
  bool first = ast__ast__Ast__at_const(&((*a)), id)->as_data.while_stmt.is_do;
  for (;;) {
    if ((!first) && (cond != ast__ast__NODE_NONE)) {
      const consteval__consteval__CeVal c = consteval__consteval__ConstEval__ev_rval(self, f, m, cond);
      if (c.kind != consteval__consteval__CV_BOOL) {
        return consteval__consteval__xfail(f);
      }
      if (c.as_data.i == 0) {
        return consteval__consteval__Flow_Ok;
      }
    }
    (first = false);
    const consteval__consteval__Flow st = consteval__consteval__ConstEval__exec_stmt(self, f, m, body);
    if (st == consteval__consteval__Flow_Break) {
      return consteval__consteval__Flow_Ok;
    }
    if ((st == consteval__consteval__Flow_Return) || (st == consteval__consteval__Flow_Bail)) {
      return st;
    }
    if (!consteval__consteval__ConstEval__ce_tick(self)) {
      return consteval__consteval__Flow_Bail;
    }
  }
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__ConstEval__exec_for(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  const uint32_t iter_n = ast__ast__Ast__at_const(&((*a)), id)->as_data.for_stmt.iterable;
  const uint32_t body = ast__ast__Ast__at_const(&((*a)), id)->as_data.for_stmt.body;
  if (ast__ast__Ast__at_const(&((*a)), iter_n)->kind == ast__ast__NodeKind_NODE_RANGE) {
    const uint32_t start_n = ast__ast__Ast__at_const(&((*a)), iter_n)->as_data.pattern_range.start;
    const uint32_t end_n = ast__ast__Ast__at_const(&((*a)), iter_n)->as_data.pattern_range.end;
    const bool inc = ast__ast__Ast__at_const(&((*a)), iter_n)->as_data.pattern_range.inclusive;
    if ((start_n == ast__ast__NODE_NONE) || (end_n == ast__ast__NODE_NONE)) {
      return consteval__consteval__Flow_Bail;
    }
    const consteval__consteval__CeVal s = consteval__consteval__ConstEval__ev_rval(self, f, m, start_n);
    if (s.kind != consteval__consteval__CV_INT) {
      return consteval__consteval__xfail(f);
    }
    const ast__ast__BuiltinType eb = consteval__consteval__ConstEval__ce_builtin_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, iter_n));
    const bool uns = ((eb != ast__ast__BuiltinType_BT_COUNT) && consteval__consteval__bt_unsigned(eb));
    const uint32_t et = consteval__consteval__ConstEval__ce_type(self, m, id);
    if (consteval__consteval__ConstEval__ce_bind_slot(self, f, id) == NULL) {
      return consteval__consteval__Flow_Bail;
    }
    int64_t v = s.as_data.i;
    for (;;) {
      const consteval__consteval__CeVal e = consteval__consteval__ConstEval__ev_rval(self, f, m, end_n);
      if (e.kind != consteval__consteval__CV_INT) {
        return consteval__consteval__xfail(f);
      }
      const bool last = (v == e.as_data.i);
      bool done = false;
      if (uns) {
        (done = ((((uint64_t)v) > ((uint64_t)e.as_data.i)) || ((!inc) && last)));
      } else {
        (done = ((v > e.as_data.i) || ((!inc) && last)));
      }
      if (done) {
        return consteval__consteval__Flow_Ok;
      }
      consteval__consteval__CeVal *const slot = consteval__consteval__ConstEval__ce_bind_slot(self, f, id);
      ((*slot) = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = m, .ty = et, .as_data = (consteval__consteval__CeValAs){ .i = v } });
      const consteval__consteval__Flow st = consteval__consteval__ConstEval__exec_stmt(self, f, m, body);
      if (st == consteval__consteval__Flow_Break) {
        return consteval__consteval__Flow_Ok;
      }
      if ((st == consteval__consteval__Flow_Return) || (st == consteval__consteval__Flow_Bail)) {
        return st;
      }
      if (!consteval__consteval__ConstEval__ce_tick(self)) {
        return consteval__consteval__Flow_Bail;
      }
      if (inc && last) {
        return consteval__consteval__Flow_Ok;
      }
      (v = ({ int64_t __sc_r; if (__builtin_add_overflow(v, 1LL, &__sc_r)) { __sc_panic("arithmetic overflow"); } __sc_r; }));
    }
  }
  const consteval__consteval__RType ir = consteval__consteval__ConstEval__ce_rtype(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, iter_n));
  if (!ir.ok) {
    return consteval__consteval__Flow_Bail;
  }
  if (ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, ir.m))), ir.t)->kind == ast__ast__TypeKind_TYPE_ARRAY) {
    const consteval__consteval__ObjRes br = consteval__consteval__ConstEval__ce_base_obj(self, f, m, iter_n);
    if (!br.ok) {
      return consteval__consteval__Flow_Bail;
    }
    const uint32_t len = ((uint32_t)Vector__consteval__consteval__CeVal__Global__len(&(*consteval__consteval__ConstEval__obj_ptr(self, br.obj)).slots));
    for (uint32_t i = 0U; i < len; i++) {
      const consteval__consteval__CeVal sv = (*({ __auto_type __sc133 = &(*consteval__consteval__ConstEval__obj_ptr(self, br.obj)).slots; Vector__consteval__consteval__CeVal__Global__index(__sc133, ((size_t)i)); }));
      if ((sv.kind == consteval__consteval__CV_NIL_K) || (!consteval__consteval__ConstEval__ce_bind(self, f, id, sv))) {
        return consteval__consteval__Flow_Bail;
      }
      const consteval__consteval__Flow st = consteval__consteval__ConstEval__exec_stmt(self, f, m, body);
      if (st == consteval__consteval__Flow_Break) {
        return consteval__consteval__Flow_Ok;
      }
      if ((st == consteval__consteval__Flow_Return) || (st == consteval__consteval__Flow_Bail)) {
        return st;
      }
      if (!consteval__consteval__ConstEval__ce_tick(self)) {
        return consteval__consteval__Flow_Bail;
      }
    }
    return consteval__consteval__Flow_Ok;
  }
  const consteval__consteval__CeVal iv = consteval__consteval__ConstEval__ev_in(self, f, m, iter_n);
  if (iv.kind == consteval__consteval__CV_NIL_K) {
    return consteval__consteval__xfail(f);
  }
  const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, iv);
  if (!tr.ok) {
    return consteval__consteval__Flow_Bail;
  }
  const consteval__consteval__CeVal itp = tr.v;
  const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, m, consteval__consteval__ConstEval__ce_type(self, m, iter_n));
  if ((!rr.ok) || (rr.r.dn == ast__ast__NODE_NONE)) {
    return consteval__consteval__Flow_Bail;
  }
  for (;;) {
    consteval__consteval__CeVal args[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
    (args[0] = itp);
    const consteval__consteval__ValRes dr = consteval__consteval__ConstEval__ce_dispatch(self, rr.r, m, (str){ (const uint8_t *)"next", sizeof("next") - 1 }, ((const consteval__consteval__CeVal *)(&args[0])), 1U);
    if ((!dr.ok) || (dr.v.kind != consteval__consteval__CV_AGG)) {
      return consteval__consteval__Flow_Bail;
    }
    consteval__consteval__CeObj *const oo = consteval__consteval__ConstEval__obj_ptr(self, dr.v.as_data.p.obj);
    if ((oo == NULL) || ((*oo).is_enum == 0U)) {
      return consteval__consteval__Flow_Bail;
    }
    const size_t olen = Vector__consteval__consteval__CeVal__Global__len(&(*oo).slots);
    if ((olen < 2ULL) || ((*({ __auto_type __sc134 = &(*oo).slots; Vector__consteval__consteval__CeVal__Global__index(__sc134, 1ULL); })).kind == consteval__consteval__CV_NIL_K)) {
      if (olen >= 2ULL) {
        return consteval__consteval__Flow_Bail;
      }
      return consteval__consteval__Flow_Ok;
    }
    const consteval__consteval__CeVal payload = (*({ __auto_type __sc135 = &(*oo).slots; Vector__consteval__consteval__CeVal__Global__index(__sc135, 1ULL); }));
    if (!consteval__consteval__ConstEval__ce_bind(self, f, id, payload)) {
      return consteval__consteval__Flow_Bail;
    }
    const consteval__consteval__Flow st = consteval__consteval__ConstEval__exec_stmt(self, f, m, body);
    if (st == consteval__consteval__Flow_Break) {
      return consteval__consteval__Flow_Ok;
    }
    if ((st == consteval__consteval__Flow_Return) || (st == consteval__consteval__Flow_Bail)) {
      return st;
    }
    if (!consteval__consteval__ConstEval__ce_tick(self)) {
      return consteval__consteval__Flow_Bail;
    }
  }
}

static __attribute__((unused)) int32_t consteval__consteval__if_i32(bool const c, int32_t const a, int32_t const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) bool consteval__consteval__if_bool(bool const c, bool const a, bool const b) {
  if (c) {
    return a;
  }
  return b;
}

static __attribute__((unused)) consteval__consteval__Flow consteval__consteval__xfail(consteval__consteval__CeFrame *const f) {
  if ((f != NULL) && ((*f).early != 0U)) {
    return consteval__consteval__Flow_Return;
  }
  return consteval__consteval__Flow_Bail;
}

static __attribute__((unused)) lexer__token_type__TokenType consteval__consteval__compound_op(lexer__token_type__TokenType const op) {
  if (op == lexer__token_type__TokenType_PlusEqual) {
    return lexer__token_type__TokenType_Plus;
  }
  if (op == lexer__token_type__TokenType_MinusEqual) {
    return lexer__token_type__TokenType_Minus;
  }
  if (op == lexer__token_type__TokenType_StarEqual) {
    return lexer__token_type__TokenType_Star;
  }
  if (op == lexer__token_type__TokenType_SlashEqual) {
    return lexer__token_type__TokenType_Slash;
  }
  if (op == lexer__token_type__TokenType_PercentEqual) {
    return lexer__token_type__TokenType_Percent;
  }
  if (op == lexer__token_type__TokenType_AmpersandEqual) {
    return lexer__token_type__TokenType_Ampersand;
  }
  if (op == lexer__token_type__TokenType_PipeEqual) {
    return lexer__token_type__TokenType_Pipe;
  }
  if (op == lexer__token_type__TokenType_CaretEqual) {
    return lexer__token_type__TokenType_Caret;
  }
  if (op == lexer__token_type__TokenType_LeftShiftEqual) {
    return lexer__token_type__TokenType_LeftShift;
  }
  if (op == lexer__token_type__TokenType_RightShiftEqual) {
    return lexer__token_type__TokenType_RightShift;
  }
  return lexer__token_type__TokenType_Equal;
}

static __attribute__((unused)) consteval__consteval__ConstValue consteval__consteval__cv_pub(consteval__consteval__CeVal const v) {
  if (v.kind == consteval__consteval__CV_INT) {
    return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_INT, .ty = v.ty, .as_data = (consteval__consteval__ConstValueAs){ .i = v.as_data.i } };
  }
  if (v.kind == consteval__consteval__CV_BOOL) {
    return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_BOOL, .ty = v.ty, .as_data = (consteval__consteval__ConstValueAs){ .i = v.as_data.i } };
  }
  if (v.kind == consteval__consteval__CV_FLOAT) {
    if (!consteval__consteval__ce_isfinite(v.as_data.f)) {
      return consteval__consteval__ce_none();
    }
    return (consteval__consteval__ConstValue){ .kind = consteval__consteval__CONST_FLOAT, .ty = v.ty, .as_data = (consteval__consteval__ConstValueAs){ .f = v.as_data.f } };
  }
  return consteval__consteval__ce_none();
}

static __attribute__((unused)) bool consteval__consteval__cv_is_scalar(consteval__consteval__CeVal const v) {
  return (((v.kind == consteval__consteval__CV_INT) || (v.kind == consteval__consteval__CV_BOOL)) || (v.kind == consteval__consteval__CV_FLOAT));
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_subst_add(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const g, uint16_t const pmod, uint32_t const param, uint16_t const am, uint32_t const at) {
  for (uint8_t i = 0U; i < (*g).ng; i++) {
    if (((*g).pmod == pmod) && ((*g).params_g[((size_t)i)] == param)) {
      return consteval__consteval__ConstEval__ce_teq(self, (*g).am[((size_t)i)], (*g).at[((size_t)i)], am, at);
    }
  }
  if (((*g).ng >= 8U) || (((*g).ng != 0U) && ((*g).pmod != pmod))) {
    return false;
  }
  ((*g).pmod = pmod);
  const uint8_t ng = (*g).ng;
  ((*g).params_g[((size_t)ng)] = param);
  ((*g).am[((size_t)ng)] = am);
  ((*g).at[((size_t)ng)] = at);
  ((*g).ng = ((uint8_t)((uint32_t)ng + (uint32_t)1U)));
  return true;
}

static __attribute__((unused)) bool consteval__consteval__ConstEval__ce_bind_extend(const consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const g, uint16_t const xm, uint32_t const extnode, const consteval__consteval__CeRecv *const recv) {
  const ast__ast__Ast *const xa = consteval__consteval__ConstEval__ast_ptr(self, xm);
  const ast__ast__NodeList gens = ast__ast__Ast__at_const(&((*xa)), extnode)->as_data.extend_def.generics;
  if (gens.len == 0U) {
    return true;
  }
  if ((recv == NULL) || ((*recv).dn == ast__ast__NODE_NONE)) {
    return false;
  }
  const uint32_t target = ast__ast__Ast__at_const(&((*xa)), extnode)->as_data.extend_def.target_type;
  if ((ast__ast__Ast__at_const(&((*xa)), target)->kind != ast__ast__NodeKind_NODE_TYPE_PATH) || (ast__ast__Ast__at_const(&((*xa)), target)->as_data.type_path.args.len != ((uint32_t)(*recv).n))) {
    return false;
  }
  const ast__ast__NodeList targs = ast__ast__Ast__at_const(&((*xa)), target)->as_data.type_path.args;
  for (uint8_t i = 0U; i < (*recv).n; i++) {
    const uint32_t aid = ast__ast__Ast__list(&((*xa)), targs)[((size_t)i)];
    const ast__ast__DefId ad = ast__ast__Ast__resolution_def(&((*xa)), aid);
    if (((ad.node != ast__ast__NODE_NONE) && (((size_t)ad.module) < self->nmods)) && (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, ad.module))), ad.node)->kind == ast__ast__NodeKind_NODE_GENERIC_PARAM)) {
      if (!consteval__consteval__ConstEval__ce_subst_add(self, g, ad.module, ad.node, (*recv).am[((size_t)i)], (*recv).at[((size_t)i)])) {
        return false;
      }
    } else {
      const uint32_t at2 = consteval__consteval__ConstEval__ce_type(self, xm, aid);
      if ((at2 == ast__ast__TYPE_NONE) || (!consteval__consteval__ConstEval__ce_teq(self, xm, at2, (*recv).am[((size_t)i)], (*recv).at[((size_t)i)]))) {
        return false;
      }
    }
  }
  const uint32_t *const gids = ast__ast__Ast__list(&((*xa)), gens);
  for (uint32_t j = 0U; j < gens.len; j++) {
    bool bound = false;
    for (uint8_t k = 0U; k < (*g).ng; k++) {
      if (((*g).pmod == xm) && ((*g).params_g[((size_t)k)] == gids[((size_t)j)])) {
        (bound = true);
      }
    }
    if (!bound) {
      return false;
    }
  }
  return true;
}

static __attribute__((unused)) consteval__consteval__Rets consteval__consteval__ConstEval__ce_intercept(consteval__consteval__ConstEval *const self, uint16_t const fm, uint32_t const fnode, const consteval__consteval__CeVal *const args, uint32_t const nargs, uint16_t const m, uint32_t const callId) {
  const ast__ast__Ast *const fa = consteval__consteval__ConstEval__ast_ptr(self, fm);
  const lexer__token__Span nm = consteval__consteval__ConstEval__name_text(self, fm, ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.name);
  const uint32_t rt = consteval__consteval__ConstEval__ce_type(self, m, callId);
  consteval__consteval__Rets out = (consteval__consteval__Rets){ .ok = false, .n = 0U };
  if (consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"malloc", sizeof("malloc") - 1 })) {
    if (((nargs != 1U) || (args[0].kind != consteval__consteval__CV_INT)) || (args[0].as_data.i < 0)) {
      return out;
    }
    const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, 0U);
    if (o == 0U) {
      return out;
    }
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).heap = 1U);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).bytes = ((uint64_t)args[0].as_data.i));
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).et = ast__ast__TYPE_NONE);
    (out.vals[0] = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } });
    (out.n = 1U);
    (out.ok = true);
    return out;
  }
  if (consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"realloc", sizeof("realloc") - 1 })) {
    if ((((nargs != 2U) || (args[0].kind != consteval__consteval__CV_PTR)) || (args[1].kind != consteval__consteval__CV_INT)) || (args[1].as_data.i < 0)) {
      return out;
    }
    const uint64_t nbytes = ((uint64_t)args[1].as_data.i);
    if (args[0].as_data.p.obj == 0U) {
      const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, 0U);
      if (o == 0U) {
        return out;
      }
      ((*consteval__consteval__ConstEval__obj_ptr(self, o)).heap = 1U);
      ((*consteval__consteval__ConstEval__obj_ptr(self, o)).bytes = nbytes);
      ((*consteval__consteval__ConstEval__obj_ptr(self, o)).et = ast__ast__TYPE_NONE);
      (out.vals[0] = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } });
      (out.n = 1U);
      (out.ok = true);
      return out;
    }
    consteval__consteval__CeObj *const b = consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj);
    if (((b == NULL) || ((*b).heap == 0U)) || (args[0].as_data.p.off != 0U)) {
      return out;
    }
    if ((*b).dead != 0U) {
      consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"use after free", sizeof("use after free") - 1 });
      return out;
    }
    if ((*b).et != ast__ast__TYPE_NONE) {
      const uint64_t esz = (*b).esz;
      if ((esz == 0ULL) || (({ uint64_t __sc136 = nbytes; uint64_t __sc137 = esz; if (__sc137 == 0) { __sc_panic("divide by zero"); } (__sc136 % __sc137); }) != 0ULL)) {
        return out;
      }
      if (!consteval__consteval__ConstEval__ce_obj_resize(self, args[0].as_data.p.obj, ((uint32_t)({ uint64_t __sc138 = nbytes; uint64_t __sc139 = esz; if (__sc139 == 0) { __sc_panic("divide by zero"); } (__sc138 / __sc139); })))) {
        return out;
      }
    }
    ((*consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj)).bytes = nbytes);
    (out.vals[0] = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_PTR, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = args[0].as_data.p.obj, .off = 0U } } });
    (out.n = 1U);
    (out.ok = true);
    return out;
  }
  if (consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"free", sizeof("free") - 1 })) {
    if ((nargs != 1U) || (args[0].kind != consteval__consteval__CV_PTR)) {
      return out;
    }
    if (args[0].as_data.p.obj == 0U) {
      (out.ok = true);
      return out;
    }
    consteval__consteval__CeObj *const b = consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj);
    if (((b == NULL) || ((*b).heap == 0U)) || (args[0].as_data.p.off != 0U)) {
      return out;
    }
    if ((*b).dead != 0U) {
      consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"double free", sizeof("double free") - 1 });
      return out;
    }
    ((*b).dead = 1U);
    (out.ok = true);
    return out;
  }
  if (consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"memset", sizeof("memset") - 1 })) {
    if (((((nargs != 3U) || (args[0].kind != consteval__consteval__CV_PTR)) || (args[1].kind != consteval__consteval__CV_INT)) || (args[2].kind != consteval__consteval__CV_INT)) || (args[2].as_data.i < 0)) {
      return out;
    }
    const uint64_t n = ((uint64_t)args[2].as_data.i);
    if (args[0].as_data.p.obj == 0U) {
      (out.ok = (n == 0ULL));
      return out;
    }
    consteval__consteval__CeObj *const b = consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj);
    if ((b == NULL) || ((*b).heap == 0U)) {
      return out;
    }
    if ((*b).dead != 0U) {
      consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"use after free", sizeof("use after free") - 1 });
      return out;
    }
    if (((*b).et == ast__ast__TYPE_NONE) && (args[0].as_data.p.off == 0U)) {
      const uint64_t bytes = (*b).bytes;
      if (!consteval__consteval__ConstEval__ce_obj_resize(self, args[0].as_data.p.obj, ((uint32_t)bytes))) {
        return out;
      }
      consteval__consteval__CeObj *const b2 = consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj);
      ((*b2).em = 0U);
      ((*b2).et = 8U);
      ((*b2).esz = 1ULL);
    }
    consteval__consteval__CeObj *const bb = consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj);
    const uint64_t esz = (*bb).esz;
    if ((esz == 0ULL) || (({ uint64_t __sc140 = n; uint64_t __sc141 = esz; if (__sc141 == 0) { __sc_panic("divide by zero"); } (__sc140 % __sc141); }) != 0ULL)) {
      return out;
    }
    const uint64_t count = ({ uint64_t __sc142 = n; uint64_t __sc143 = esz; if (__sc143 == 0) { __sc_panic("divide by zero"); } (__sc142 / __sc143); });
    const uint64_t off = ((uint64_t)args[0].as_data.p.off);
    if ((off + count) > ((uint64_t)Vector__consteval__consteval__CeVal__Global__len(&(*bb).slots))) {
      consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"out-of-bounds access", sizeof("out-of-bounds access") - 1 });
      return out;
    }
    consteval__consteval__CeVal fill = consteval__consteval__cv_nil();
    if (esz == 1ULL) {
      (fill = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = 8U, .as_data = (consteval__consteval__CeValAs){ .i = (args[1].as_data.i & 0xffLL) } });
    } else {
      if (args[1].as_data.i != 0) {
        return out;
      }
      (fill = consteval__consteval__ConstEval__ce_zero(self, (*bb).em, (*bb).et, 0));
      if (fill.kind == consteval__consteval__CV_NIL_K) {
        return out;
      }
    }
    for (uint64_t i = 0ULL; i < count; i++) {
      const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, fill, 0);
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, args[0].as_data.p.obj)).slots, ((size_t)(off + i)), cloned);
    }
    (out.vals[0] = args[0]);
    (out.n = 1U);
    (out.ok = true);
    return out;
  }
  if (consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"abort", sizeof("abort") - 1 })) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"abort reached at compile time", sizeof("abort reached at compile time") - 1 });
    return out;
  }
  if (consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"__sc_panic_str", sizeof("__sc_panic_str") - 1 }) || consteval__consteval__ConstEval__ce_span_is(self, fm, nm, (str){ (const uint8_t *)"__sc_panic", sizeof("__sc_panic") - 1 })) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"panic reached at compile time", sizeof("panic reached at compile time") - 1 });
    return out;
  }
  const size_t ln = ((size_t)(nm.end - nm.start));
  if (((ln >= 24ULL) || (nargs < 1U)) || (nargs > 3U)) {
    return out;
  }
  consteval__consteval__Buf24 name = (consteval__consteval__Buf24){0};
  for (size_t ci = 0ULL; ci < ln; ci++) {
    (name.b[ci] = ((char)consteval__consteval__ConstEval__ce_src(self, fm)[(((size_t)nm.start) + ci)]));
  }
  (name.b[ln] = 0);
  bool f32suf = false;
  if ((ln > 1ULL) && (name.b[(ln - 1ULL)] == 102)) {
    (f32suf = true);
    (name.b[(ln - 1ULL)] = 0);
  }
  double inv[3] = { 0.0, 0.0, 0.0 };
  for (uint32_t i = 0U; i < nargs; i++) {
    if (args[((size_t)i)].kind != consteval__consteval__CV_FLOAT) {
      return out;
    }
    (inv[__sc_bounds(((size_t)i), 3)] = args[((size_t)i)].as_data.f);
  }
  const str nv = utils__errors__cstr(((const char *)(&name.b[0])));
  double v = 0.0;
  bool ok = false;
  if (nargs == 1U) {
    const consteval__consteval__DblRes r = consteval__consteval__libm1(nv, inv[0]);
    (ok = r.ok);
    (v = r.v);
  } else if (nargs == 2U) {
    const consteval__consteval__DblRes r = consteval__consteval__libm2(nv, inv[0], inv[1]);
    (ok = r.ok);
    (v = r.v);
  } else {
    if (({ __auto_type __sc144 = nv; __auto_type __sc145 = (str){ (const uint8_t *)"fma", sizeof("fma") - 1 }; str__eq(&__sc144, &__sc145); })) {
      (v = fma(inv[0], inv[1], inv[2]));
      (ok = true);
    }
  }
  if (!ok) {
    return out;
  }
  if (f32suf) {
    (v = ((double)((float)v)));
  }
  (out.vals[0] = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_FLOAT, .tm = m, .ty = rt, .as_data = (consteval__consteval__CeValAs){ .f = v } });
  (out.n = 1U);
  (out.ok = true);
  return out;
}

static __attribute__((unused)) consteval__consteval__Rets consteval__consteval__ConstEval__ce_invoke(consteval__consteval__ConstEval *const self, uint16_t const fm, uint32_t const fnode, uint32_t const extend_node, const consteval__consteval__CeRecv *const recv, const uint16_t *const monom, const uint32_t *const monot, uint8_t const nmono, const consteval__consteval__CeVal *const args, uint32_t const nargs, uint16_t const self_pm, uint32_t const self_decl, uint16_t const self_am, uint32_t const self_at) {
  consteval__consteval__Rets out = (consteval__consteval__Rets){ .ok = false, .n = 0U };
  const ast__ast__Ast *const fa = consteval__consteval__ConstEval__ast_ptr(self, fm);
  const bool closure = (ast__ast__Ast__at_const(&((*fa)), fnode)->kind == ast__ast__NodeKind_NODE_CLOSURE);
  if ((!closure) && (ast__ast__Ast__at_const(&((*fa)), fnode)->kind != ast__ast__NodeKind_NODE_FUNCTION)) {
    return out;
  }
  ast__ast__NodeList params = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  uint32_t body = ast__ast__NODE_NONE;
  if (closure) {
    (params = ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.closure.params);
    (body = ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.closure.body);
  } else {
    (params = ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.params);
    (body = ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.body);
  }
  if ((body == ast__ast__NODE_NONE) || (params.len != nargs)) {
    return out;
  }
  if ((!closure) && ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.is_variadic) {
    return out;
  }
  if (self->nframes >= consteval__consteval__CE_MAX_FRAMES) {
    consteval__consteval__ConstEval__ce_trap(self, (str){ (const uint8_t *)"const-eval call depth exceeded", sizeof("const-eval call depth exceeded") - 1 });
    return out;
  }
  consteval__consteval__CeFrame g = consteval__consteval__ce_frame_zero();
  consteval__consteval__CeFrame *const gp = ((consteval__consteval__CeFrame *)(&g));
  if ((self_decl != ast__ast__NODE_NONE) && (!consteval__consteval__ConstEval__ce_subst_add(self, gp, self_pm, self_decl, self_am, self_at))) {
    return out;
  }
  if (extend_node != ast__ast__NODE_NONE) {
    const ast__ast__NodeList xg = ast__ast__Ast__at_const(&((*fa)), extend_node)->as_data.extend_def.generics;
    bool bound = (xg.len == 0U);
    if ((((!bound) && (recv != NULL)) && ((*recv).dn != ast__ast__NODE_NONE)) && ((*recv).n != 0U)) {
      (bound = consteval__consteval__ConstEval__ce_bind_extend(self, gp, fm, extend_node, recv));
    }
    if (!bound) {
      if (((uint32_t)nmono) < xg.len) {
        return out;
      }
      const uint32_t *const gids = ast__ast__Ast__list(&((*fa)), xg);
      for (uint32_t i = 0U; i < xg.len; i++) {
        if ((monot[((size_t)i)] == ast__ast__TYPE_NONE) || (!ast__ast__Ast__type_concrete(&((*consteval__consteval__ConstEval__ast_ptr(self, monom[((size_t)i)]))), monot[((size_t)i)]))) {
          return out;
        }
        if (!consteval__consteval__ConstEval__ce_subst_add(self, gp, fm, gids[((size_t)i)], monom[((size_t)i)], monot[((size_t)i)])) {
          return out;
        }
      }
    }
  }
  if (!closure) {
    const ast__ast__NodeList fg = ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.generics;
    if (fg.len != 0U) {
      if (((uint32_t)nmono) < fg.len) {
        return out;
      }
      const uint32_t skip = (((uint32_t)nmono) - fg.len);
      const uint32_t *const gids = ast__ast__Ast__list(&((*fa)), fg);
      for (uint32_t i = 0U; i < fg.len; i++) {
        const size_t idx = ((size_t)(skip + i));
        if ((monot[idx] == ast__ast__TYPE_NONE) || (!ast__ast__Ast__type_concrete(&((*consteval__consteval__ConstEval__ast_ptr(self, monom[idx]))), monot[idx]))) {
          return out;
        }
        if (!consteval__consteval__ConstEval__ce_subst_add(self, gp, fm, gids[((size_t)i)], monom[idx], monot[idx])) {
          return out;
        }
      }
    }
  }
  bool cacheable = (((!closure) && ((*gp).ng == 0U)) && (nargs <= 8U));
  uint32_t ai = 0U;
  while (cacheable && (ai < nargs)) {
    (cacheable = consteval__consteval__cv_is_scalar(args[((size_t)ai)]));
    (ai = (ai + 1U));
  }
  consteval__consteval__CeCallKey ck = (consteval__consteval__CeCallKey){ .m = fm, .fn_id = fnode, .nargs = ((uint8_t)nargs) };
  if (cacheable) {
    for (uint32_t i = 0U; i < nargs; i++) {
      (ck.kinds[((size_t)i)] = args[((size_t)i)].kind);
      (ck.bits[((size_t)i)] = args[((size_t)i)].as_data.i);
    }
    {
      const Option__ptr_consteval__consteval__CeCallHit __sc146 = Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__get(&self->calls, (&ck));
      if (__sc146.tag == Option_Some) {
        const consteval__consteval__CeCallHit *const hit = __sc146.payload.Some._0;
        {
          (out.n = hit->nrets);
          for (uint8_t j = 0U; j < hit->nrets; j++) {
            (out.vals[((size_t)j)] = hit->rets[((size_t)j)]);
          }
          (out.ok = true);
          return out;
        }
      }
      else if (1) {
        {
        }
      }
    }
  }
  ((*gp).env = consteval__consteval__ConstEval__ce_obj_new(self, 0U));
  if ((*gp).env == 0U) {
    return out;
  }
  const uint32_t *const pids = ast__ast__Ast__list(&((*fa)), params);
  for (uint32_t i = 0U; i < nargs; i++) {
    const uint32_t pt0 = consteval__consteval__ConstEval__ce_type(self, fm, ast__ast__Ast__at_const(&((*fa)), pids[((size_t)i)])->as_data.parameter.ty);
    consteval__consteval__CeVal v = args[((size_t)i)];
    const consteval__consteval__RType rr = consteval__consteval__ConstEval__ce_rtype(self, gp, fm, pt0);
    if (rr.ok) {
      (v = consteval__consteval__ConstEval__ce_coerce(self, v, rr.m, rr.t));
    }
    if ((v.kind == consteval__consteval__CV_NIL_K) || (!consteval__consteval__ConstEval__ce_bind(self, gp, pids[((size_t)i)], v))) {
      return out;
    }
  }
  (self->nframes = (self->nframes + 1U));
  const uint32_t saved = self->depth;
  (self->depth = 0U);
  consteval__consteval__Flow st = consteval__consteval__Flow_Ok;
  if (closure && ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.closure.expr_body) {
    const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, gp, fm, body);
    if (v.kind == consteval__consteval__CV_NIL_K) {
      (st = consteval__consteval__Flow_Bail);
    } else {
      (st = consteval__consteval__Flow_Return);
    }
    ((*gp).rets[0] = v);
    ((*gp).nrets = 1U);
    ((*gp).returned = 1U);
  } else {
    (st = consteval__consteval__ConstEval__exec_stmt(self, gp, fm, body));
  }
  (self->depth = saved);
  (self->nframes = (self->nframes - 1U));
  if (((st == consteval__consteval__Flow_Bail) || (st == consteval__consteval__Flow_Break)) || (st == consteval__consteval__Flow_Continue)) {
    return out;
  }
  uint32_t wantret = 1U;
  if (!closure) {
    (wantret = ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.returns.len);
    if (wantret == 1U) {
      const uint32_t r0 = ast__ast__Ast__list(&((*fa)), ast__ast__Ast__at_const(&((*fa)), fnode)->as_data.function.returns)[0];
      if (consteval__consteval__type_builtin(fa, consteval__consteval__ConstEval__ce_type(self, fm, r0)) == ast__ast__BuiltinType_BT_VOID) {
        (wantret = 0U);
      }
    }
  }
  if ((*gp).returned == 0U) {
    if ((wantret > 0U) && (st != consteval__consteval__Flow_Return)) {
      return out;
    }
    ((*gp).nrets = 0U);
  }
  (out.n = (*gp).nrets);
  for (uint8_t j = 0U; j < (*gp).nrets; j++) {
    (out.vals[((size_t)j)] = (*gp).rets[((size_t)j)]);
  }
  if (cacheable && (out.n <= 8U)) {
    bool pure = true;
    uint8_t k = 0U;
    while (pure && (k < out.n)) {
      (pure = consteval__consteval__cv_is_scalar(out.vals[((size_t)k)]));
      (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
    }
    if (pure && (Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__len(&self->calls) < consteval__consteval__CE_CALLS_MAX)) {
      consteval__consteval__CeCallHit hit = (consteval__consteval__CeCallHit){ .nrets = out.n };
      for (uint8_t z = 0U; z < out.n; z++) {
        (hit.rets[((size_t)z)] = out.vals[((size_t)z)]);
      }
      Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__insert(&self->calls, ck, hit);
    }
  }
  (out.ok = true);
  return out;
}

static __attribute__((unused)) consteval__consteval__ValRes consteval__consteval__ConstEval__ce_dispatch(consteval__consteval__ConstEval *const self, consteval__consteval__CeRecv const r, uint16_t const scope, str const lit, const consteval__consteval__CeVal *const args, uint32_t const nargs) {
  uint32_t extnode = ast__ast__NODE_NONE;
  const ast__ast__DefId md = consteval__consteval__ConstEval__ce_find_method(self, r, scope, 0U, lexer__token__Span__empty(), lit, ((uint32_t *)(&extnode)));
  if (md.node == ast__ast__NODE_NONE) {
    return (consteval__consteval__ValRes){ .ok = false };
  }
  const consteval__consteval__Rets inv = consteval__consteval__ConstEval__ce_invoke(self, md.module, md.node, extnode, ((const consteval__consteval__CeRecv *)(&r)), NULL, NULL, 0U, args, nargs, 0U, ast__ast__NODE_NONE, 0U, ast__ast__TYPE_NONE);
  if (!inv.ok) {
    return (consteval__consteval__ValRes){ .ok = false };
  }
  consteval__consteval__CeVal out = consteval__consteval__cv_nil();
  if (inv.n != 0U) {
    (out = inv.vals[0]);
  }
  return (consteval__consteval__ValRes){ .ok = true, .v = out };
}

static __attribute__((unused)) consteval__consteval__Rets consteval__consteval__ConstEval__ce_call(consteval__consteval__ConstEval *const self, consteval__consteval__CeFrame *const f, uint16_t const m, uint32_t const id) {
  const ast__ast__Ast *const a = consteval__consteval__ConstEval__ast_ptr(self, m);
  uint32_t callee = ast__ast__Ast__at_const(&((*a)), id)->as_data.call.callee;
  ast__ast__NodeKind ck = ast__ast__Ast__at_const(&((*a)), callee)->kind;
  if (ck == ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION) {
    (callee = ast__ast__Ast__at_const(&((*a)), callee)->as_data.specialization.expression);
    (ck = ast__ast__Ast__at_const(&((*a)), callee)->kind);
  }
  const ast__ast__NodeList call_args = ast__ast__Ast__at_const(&((*a)), id)->as_data.call.args;
  const uint32_t nargs = call_args.len;
  consteval__consteval__Rets out = (consteval__consteval__Rets){ .ok = false, .n = 0U };
  if ((nargs + 1U) > 8U) {
    return out;
  }
  ast__ast__DefId fd = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  uint32_t recv_expr = ast__ast__NODE_NONE;
  const ast__ast__DerefUse *du = NULL;
  bool have_recv_type = false;
  ast__ast__DefId recv_syn = (ast__ast__DefId){ .module = 0U, .node = ast__ast__NODE_NONE };
  uint16_t rtm = 0U;
  uint32_t rtt = ast__ast__TYPE_NONE;
  if (ck == ast__ast__NodeKind_NODE_IDENTIFIER) {
    (fd = ast__ast__Ast__resolution_def(&((*a)), callee));
    if (fd.node == ast__ast__NODE_NONE) {
      (fd = (ast__ast__DefId){ .module = m, .node = ast__ast__Ast__resolution(&((*a)), callee) });
    }
    if (((fd.node != ast__ast__NODE_NONE) && (((size_t)fd.module) < self->nmods)) && (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fd.module))), fd.node)->kind != ast__ast__NodeKind_NODE_FUNCTION)) {
      const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_rval(self, f, m, callee);
      if (v.kind != consteval__consteval__CV_FN) {
        return out;
      }
      (fd = (ast__ast__DefId){ .module = v.as_data.fnv.m, .node = v.as_data.fnv.fn_id });
    }
  } else if (ck == ast__ast__NodeKind_NODE_MEMBER) {
    (fd = ast__ast__Ast__resolution_def(&((*a)), callee));
    if (fd.node == ast__ast__NODE_NONE) {
      (fd = ast__ast__Ast__resolution_def(&((*a)), ast__ast__Ast__at_const(&((*a)), callee)->as_data.member.member));
    }
    const bool is_path = ast__ast__Ast__at_const(&((*a)), callee)->as_data.member.path;
    const uint32_t obj_n = ast__ast__Ast__at_const(&((*a)), callee)->as_data.member.object;
    if (is_path) {
      if ((obj_n != ast__ast__NODE_NONE) && (consteval__consteval__ConstEval__ce_type(self, m, obj_n) != ast__ast__TYPE_NONE)) {
        (have_recv_type = true);
        (rtm = m);
        (rtt = consteval__consteval__ConstEval__ce_type(self, m, obj_n));
      } else if (obj_n != ast__ast__NODE_NONE) {
        (recv_syn = ast__ast__Ast__resolution_def(&((*a)), obj_n));
        if (recv_syn.node == ast__ast__NODE_NONE) {
          (recv_syn = (ast__ast__DefId){ .module = m, .node = ast__ast__Ast__resolution(&((*a)), obj_n) });
        }
      }
    } else {
      (recv_expr = obj_n);
      (have_recv_type = true);
      (rtm = m);
      (rtt = consteval__consteval__ConstEval__ce_type(self, m, recv_expr));
      (du = ast__ast__Ast__deref_use_at(&((*a)), ast__ast__Ast__at_const(&((*a)), callee)->as_data.member.member));
      if (fd.node == ast__ast__NODE_NONE) {
        const lexer__token__Span mname = consteval__consteval__ConstEval__name_text(self, m, ast__ast__Ast__at_const(&((*a)), callee)->as_data.member.member);
        if ((!consteval__consteval__ConstEval__ce_span_is(self, m, mname, (str){ (const uint8_t *)"free", sizeof("free") - 1 })) || (nargs != 0U)) {
          return out;
        }
        const consteval__consteval__RType sr = consteval__consteval__ConstEval__ce_strip_refptr(self, f, rtm, rtt);
        if (!sr.ok) {
          return out;
        }
        const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, sr.m, sr.t);
        if (!rr.ok) {
          return out;
        }
        if (rr.r.dn == ast__ast__NODE_NONE) {
          (out.ok = true);
          return out;
        }
        uint32_t extnode = ast__ast__NODE_NONE;
        const ast__ast__DefId md = consteval__consteval__ConstEval__ce_find_method(self, rr.r, m, 0U, lexer__token__Span__empty(), (str){ (const uint8_t *)"free", sizeof("free") - 1 }, ((uint32_t *)(&extnode)));
        if (md.node == ast__ast__NODE_NONE) {
          (out.ok = true);
          return out;
        }
        consteval__consteval__CeVal recv = consteval__consteval__cv_nil();
        const consteval__consteval__ValRes pr = consteval__consteval__ConstEval__ev_place(self, f, m, recv_expr);
        if (pr.ok) {
          (recv = pr.v);
        } else {
          const consteval__consteval__CeVal rv = consteval__consteval__ConstEval__ev_in(self, f, m, recv_expr);
          if (rv.kind == consteval__consteval__CV_PTR) {
            (recv = rv);
          } else {
            const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, rv);
            if ((rv.kind == consteval__consteval__CV_NIL_K) || (!tr.ok)) {
              return out;
            }
            (recv = tr.v);
          }
        }
        consteval__consteval__CeVal avs[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
        (avs[0] = recv);
        return consteval__consteval__ConstEval__ce_invoke(self, md.module, md.node, extnode, ((const consteval__consteval__CeRecv *)(&rr.r)), NULL, NULL, 0U, ((const consteval__consteval__CeVal *)(&avs[0])), 1U, 0U, ast__ast__NODE_NONE, 0U, ast__ast__TYPE_NONE);
      }
    }
  } else {
    return out;
  }
  if ((fd.node == ast__ast__NODE_NONE) || (((size_t)fd.module) >= self->nmods)) {
    return out;
  }
  uint16_t fam = fd.module;
  uint32_t fnode = fd.node;
  ast__ast__NodeKind fkind = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->kind;
  if (fkind == ast__ast__NodeKind_NODE_VARIANT) {
    const consteval__consteval__VarPos vp = consteval__consteval__ConstEval__ce_variant_pos(self, fd.module, fd.node);
    if ((vp.pos < 0) || (!consteval__consteval__ConstEval__ce_enum_tagged(self, fd.module, vp.enum_decl))) {
      return out;
    }
    const ast__ast__NodeList vpayload = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fd.module))), fd.node)->as_data.variant.payload;
    if ((vpayload.len != nargs) || consteval__consteval__ConstEval__ce_user_free(self, fd.module, vp.enum_decl)) {
      return out;
    }
    const uint32_t o = consteval__consteval__ConstEval__ce_obj_new(self, (1U + nargs));
    if (o == 0U) {
      return out;
    }
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).is_enum = 1U);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dm = fd.module);
    ((*consteval__consteval__ConstEval__obj_ptr(self, o)).dn = vp.enum_decl);
    Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, 0ULL, (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_INT, .tm = 0U, .ty = ast__ast__TYPE_NONE, .as_data = (consteval__consteval__CeValAs){ .i = ((int64_t)vp.pos) } });
    for (uint32_t i = 0U; i < nargs; i++) {
      const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev_in(self, f, m, ast__ast__Ast__list(&((*a)), call_args)[((size_t)i)]);
      if (v.kind == consteval__consteval__CV_NIL_K) {
        return out;
      }
      const consteval__consteval__CeVal cloned = consteval__consteval__ConstEval__ce_clone(self, v, 0);
      if (cloned.kind == consteval__consteval__CV_NIL_K) {
        return out;
      }
      Vector__consteval__consteval__CeVal__Global__set(&(*consteval__consteval__ConstEval__obj_ptr(self, o)).slots, ((size_t)(1U + i)), cloned);
    }
    (out.vals[0] = (consteval__consteval__CeVal){ .kind = consteval__consteval__CV_AGG, .tm = m, .ty = consteval__consteval__ConstEval__ce_type(self, m, id), .as_data = (consteval__consteval__CeValAs){ .p = (consteval__consteval__CvPtr){ .obj = o, .off = 0U } } });
    (out.n = 1U);
    (out.ok = true);
    return out;
  }
  if ((fkind != ast__ast__NodeKind_NODE_FUNCTION) && (fkind != ast__ast__NodeKind_NODE_CLOSURE)) {
    return out;
  }
  consteval__consteval__CeRecv recv_id = consteval__consteval__ce_recv_zero();
  bool have_recv_id = false;
  if (have_recv_type) {
    uint32_t dt = rtt;
    if (du != NULL) {
      (dt = (*du).target);
    }
    const consteval__consteval__RType sr = consteval__consteval__ConstEval__ce_strip_refptr(self, f, rtm, dt);
    if (sr.ok) {
      const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, f, sr.m, sr.t);
      (have_recv_id = rr.ok);
      if (rr.ok) {
        (recv_id = rr.r);
      }
    }
  } else if ((recv_syn.node != ast__ast__NODE_NONE) && (((size_t)recv_syn.module) < self->nmods)) {
    const ast__ast__NodeKind odk = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, recv_syn.module))), recv_syn.node)->kind;
    if ((odk == ast__ast__NodeKind_NODE_GENERIC_PARAM) && (f != NULL)) {
      for (uint8_t i = 0U; i < (*f).ng; i++) {
        if (((*f).pmod == recv_syn.module) && ((*f).params_g[((size_t)i)] == recv_syn.node)) {
          const consteval__consteval__RecvRes rr = consteval__consteval__ConstEval__ce_recv_of(self, NULL, (*f).am[((size_t)i)], (*f).at[((size_t)i)]);
          (have_recv_id = rr.ok);
          if (rr.ok) {
            (recv_id = rr.r);
          }
          break;
        }
      }
    } else if ((odk == ast__ast__NodeKind_NODE_STRUCT) || (odk == ast__ast__NodeKind_NODE_ENUM)) {
      (recv_id = consteval__consteval__ce_recv_zero());
      (recv_id.dm = recv_syn.module);
      (recv_id.dn = recv_syn.node);
      (have_recv_id = true);
    }
  }
  uint32_t container = ast__ast__NODE_NONE;
  int32_t ckind = 0;
  if (fkind != ast__ast__NodeKind_NODE_CLOSURE) {
    (ckind = consteval__consteval__ConstEval__ce_container_of(self, fd.module, fd.node, ((uint32_t *)(&container))));
  }
  uint16_t self_pm = 0U;
  uint32_t self_decl = ast__ast__NODE_NONE;
  uint16_t self_am = 0U;
  uint32_t self_at = ast__ast__TYPE_NONE;
  if (ckind == 2) {
    if (!have_recv_id) {
      return out;
    }
    const lexer__token__Span mname = consteval__consteval__ConstEval__name_text(self, fam, ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->as_data.function.name);
    uint32_t extnode = ast__ast__NODE_NONE;
    const ast__ast__DefId md = consteval__consteval__ConstEval__ce_find_method(self, recv_id, m, fd.module, mname, (str){ (const uint8_t *)"", sizeof("") - 1 }, ((uint32_t *)(&extnode)));
    if (md.node != ast__ast__NODE_NONE) {
      (fd = md);
      (fam = fd.module);
      (fnode = fd.node);
      (fkind = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->kind);
      (container = extnode);
      (ckind = 1);
    } else if (ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->as_data.function.body != ast__ast__NODE_NONE) {
      if (recv_id.dn == ast__ast__NODE_NONE) {
        (self_at = ast__ast__Ast__builtin(recv_id.b));
      } else if (recv_id.n == 0U) {
        (self_at = consteval__consteval__ConstEval__ce_pool_find_type(self, recv_id.dm, recv_id.dn));
      } else {
        (self_at = ast__ast__TYPE_NONE);
      }
      if (self_at == ast__ast__TYPE_NONE) {
        return out;
      }
      (self_am = 0U);
      if (recv_id.dn != ast__ast__NODE_NONE) {
        (self_am = recv_id.dm);
      }
      (self_pm = fd.module);
      (self_decl = container);
      (ckind = 0);
    } else {
      return out;
    }
  }
  if ((fkind == ast__ast__NodeKind_NODE_FUNCTION) && ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->as_data.function.is_extern) {
    consteval__consteval__CeVal argv[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
    for (uint32_t i = 0U; i < nargs; i++) {
      (argv[__sc_bounds(((size_t)i), 8)] = consteval__consteval__ConstEval__ev_rval(self, f, m, ast__ast__Ast__list(&((*a)), call_args)[((size_t)i)]));
      if (argv[__sc_bounds(((size_t)i), 8)].kind == consteval__consteval__CV_NIL_K) {
        return out;
      }
    }
    return consteval__consteval__ConstEval__ce_intercept(self, fd.module, fnode, ((const consteval__consteval__CeVal *)(&argv[0])), nargs, m, id);
  }
  consteval__consteval__CeVal argv[9] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
  uint32_t na = 0U;
  ast__ast__NodeList params = (ast__ast__NodeList){ .start = 0U, .len = 0U };
  if (fkind == ast__ast__NodeKind_NODE_CLOSURE) {
    (params = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->as_data.closure.params);
  } else {
    (params = ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), fnode)->as_data.function.params);
  }
  if (recv_expr != ast__ast__NODE_NONE) {
    if (params.len != (nargs + 1U)) {
      return out;
    }
    const uint32_t p0 = ast__ast__Ast__list(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), params)[0];
    const uint32_t p0t = consteval__consteval__ConstEval__ce_type(self, fam, ast__ast__Ast__at_const(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), p0)->as_data.parameter.ty);
    const bool want_ref = ((p0t != ast__ast__TYPE_NONE) && (ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, fam))), p0t)->kind == ast__ast__TypeKind_TYPE_REFERENCE));
    if (want_ref || (du != NULL)) {
      const consteval__consteval__RType sr = consteval__consteval__ConstEval__ce_rtype(self, f, m, rtt);
      bool recv_is_ptr = false;
      if (sr.ok) {
        const ast__ast__TypeKind sk = ast__ast__Ast__type_at(&((*consteval__consteval__ConstEval__ast_ptr(self, sr.m))), sr.t)->kind;
        (recv_is_ptr = ((sk == ast__ast__TypeKind_TYPE_REFERENCE) || (sk == ast__ast__TypeKind_TYPE_POINTER)));
      }
      if (recv_is_ptr) {
        (argv[__sc_bounds(((size_t)na), 9)] = consteval__consteval__ConstEval__ev_in(self, f, m, recv_expr));
        if (argv[__sc_bounds(((size_t)na), 9)].kind != consteval__consteval__CV_PTR) {
          return out;
        }
      } else {
        const consteval__consteval__ValRes pr = consteval__consteval__ConstEval__ev_place(self, f, m, recv_expr);
        if (pr.ok) {
          (argv[__sc_bounds(((size_t)na), 9)] = pr.v);
        } else {
          const consteval__consteval__CeVal rv = consteval__consteval__ConstEval__ev_in(self, f, m, recv_expr);
          const consteval__consteval__ValRes tr = consteval__consteval__ConstEval__ce_temp_place(self, rv);
          if ((rv.kind == consteval__consteval__CV_NIL_K) || (!tr.ok)) {
            return out;
          }
          (argv[__sc_bounds(((size_t)na), 9)] = tr.v);
        }
      }
    } else {
      (argv[__sc_bounds(((size_t)na), 9)] = consteval__consteval__ConstEval__ev_rval(self, f, m, recv_expr));
      if (argv[__sc_bounds(((size_t)na), 9)].kind == consteval__consteval__CV_NIL_K) {
        return out;
      }
    }
    if (du != NULL) {
      for (uint8_t hi = 0U; hi < (*du).n; hi++) {
        const consteval__consteval__RecvRes hrr = consteval__consteval__ConstEval__ce_recv_of(self, f, m, (*du).recv[((size_t)hi)]);
        uint32_t hext = ast__ast__NODE_NONE;
        if ((!hrr.ok) || (consteval__consteval__ConstEval__ce_container_of(self, (*du).method[((size_t)hi)].module, (*du).method[((size_t)hi)].node, ((uint32_t *)(&hext))) != 1)) {
          return out;
        }
        consteval__consteval__CeVal ha[8] = { consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil(), consteval__consteval__cv_nil() };
        (ha[0] = argv[__sc_bounds(((size_t)na), 9)]);
        const consteval__consteval__Rets hinv = consteval__consteval__ConstEval__ce_invoke(self, (*du).method[((size_t)hi)].module, (*du).method[((size_t)hi)].node, hext, ((const consteval__consteval__CeRecv *)(&hrr.r)), NULL, NULL, 0U, ((const consteval__consteval__CeVal *)(&ha[0])), 1U, 0U, ast__ast__NODE_NONE, 0U, ast__ast__TYPE_NONE);
        if (((!hinv.ok) || (hinv.n != 1U)) || (hinv.vals[0].kind != consteval__consteval__CV_PTR)) {
          return out;
        }
        (argv[__sc_bounds(((size_t)na), 9)] = hinv.vals[0]);
      }
      if (!want_ref) {
        const consteval__consteval__ValRes lr = consteval__consteval__ConstEval__ce_loadp(self, argv[__sc_bounds(((size_t)na), 9)]);
        if (!lr.ok) {
          return out;
        }
        (argv[__sc_bounds(((size_t)na), 9)] = lr.v);
      }
    }
    (na = (na + 1U));
  } else if (params.len != nargs) {
    return out;
  }
  for (uint32_t i = 0U; i < nargs; i++) {
    (argv[__sc_bounds(((size_t)na), 9)] = consteval__consteval__ConstEval__ev_in(self, f, m, ast__ast__Ast__list(&((*a)), call_args)[((size_t)i)]));
    if (argv[__sc_bounds(((size_t)na), 9)].kind == consteval__consteval__CV_NIL_K) {
      return out;
    }
    (na = (na + 1U));
  }
  uint16_t monom[4] = { 0U, 0U, 0U, 0U };
  uint32_t monot[4] = { 0U, 0U, 0U, 0U };
  uint8_t nmono = 0U;
  const ast__ast__MonoUse *const mu = ast__ast__Ast__type_args(&((*a)), id);
  if (mu != NULL) {
    uint8_t k = 0U;
    while ((k < (*mu).n) && (k < 4U)) {
      (monom[__sc_bounds(((size_t)nmono), 4)] = m);
      (monot[__sc_bounds(((size_t)nmono), 4)] = consteval__consteval__ConstEval__ce_subst_deep(self, f, m, (*mu).args[((size_t)k)], 0));
      (nmono = ((uint8_t)((uint32_t)nmono + (uint32_t)1U)));
      (k = ((uint8_t)((uint32_t)k + (uint32_t)1U)));
    }
  }
  uint32_t ext_arg = ast__ast__NODE_NONE;
  if (ckind == 1) {
    (ext_arg = container);
  }
  const consteval__consteval__CeRecv *rp = NULL;
  if (have_recv_id) {
    (rp = ((const consteval__consteval__CeRecv *)(&recv_id)));
  }
  return consteval__consteval__ConstEval__ce_invoke(self, fd.module, fd.node, ext_arg, rp, ((const uint16_t *)(&monom[0])), ((const uint32_t *)(&monot[0])), nmono, ((const consteval__consteval__CeVal *)(&argv[0])), na, self_pm, self_decl, self_am, self_at);
}

consteval__consteval__ConstValue consteval__consteval__ConstEval__eval(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id) {
  if ((id == ast__ast__NODE_NONE) || (((size_t)m) >= self->nmods)) {
    return consteval__consteval__ce_none();
  }
  const consteval__consteval__ConstValue memo = consteval__consteval__ConstEval__slot_get(self, m, id);
  if (memo.kind != consteval__consteval__CONST_NONE) {
    return memo;
  }
  if (self->depth > 32U) {
    return consteval__consteval__ce_none();
  }
  const bool top = ((self->depth == 0U) && (self->nframes == 0U));
  if (top) {
    (self->steps = 0U);
    (self->trap = (str){ (const uint8_t *)"", sizeof("") - 1 });
    consteval__consteval__ConstEval__ce_objs_reset(self);
  }
  (self->depth = (self->depth + 1U));
  const consteval__consteval__CeVal v = consteval__consteval__ConstEval__ev(self, NULL, m, id);
  (self->depth = (self->depth - 1U));
  const consteval__consteval__ConstValue pub_v = consteval__consteval__cv_pub(v);
  if (top) {
    consteval__consteval__ConstEval__ce_objs_reset(self);
  }
  if (pub_v.kind != consteval__consteval__CONST_NONE) {
    consteval__consteval__ConstEval__slot_set(self, m, id, pub_v);
  }
  return pub_v;
}

str consteval__consteval__ConstEval__ce_trap_get(const consteval__consteval__ConstEval *const self) {
  return self->trap;
}

void consteval__consteval__ConstEval__defer_assert(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const cond) {
  Vector__consteval__consteval__CePending__Global__push(&self->pending, (consteval__consteval__CePending){ .m = m, .cond = cond });
}

void consteval__consteval__ConstEval__flush_asserts(consteval__consteval__ConstEval *const self, void (*const err)(void *, uint16_t, uint32_t, const char *), void *const ctx) {
  for (size_t i = 0ULL; i < Vector__consteval__consteval__CePending__Global__len(&self->pending); i++) {
    const consteval__consteval__CePending p = (*({ __auto_type __sc147 = &self->pending; Vector__consteval__consteval__CePending__Global__index(__sc147, i); }));
    const consteval__consteval__ConstValue v = consteval__consteval__ConstEval__eval(self, p.m, p.cond);
    if ((v.kind == consteval__consteval__CONST_BOOL) && (v.as_data.i == 0)) {
      err(ctx, p.m, p.cond, NULL);
    } else if ((v.kind == consteval__consteval__CONST_NONE) && (str__len(&self->trap) != 0ULL)) {
      err(ctx, p.m, p.cond, ((const char *)str__ptr(&self->trap)));
    }
  }
  Vector__consteval__consteval__CePending__Global__clear(&self->pending);
}

void consteval__consteval__ConstEval__free(consteval__consteval__ConstEval *const self) {
  Vector__Vector__consteval__consteval__ConstValue__Global__Global__free(&self->vals);
  Vector__consteval__consteval__CeObj__Global__free(&self->objs);
  Vector__consteval__consteval__CePending__Global__free(&self->pending);
  Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__free(&self->calls);
  Vector__consteval__consteval__UFree__Global__free(&self->ufree);
}

static __attribute__((unused)) consteval__consteval__DblRes consteval__consteval__libm1(str const name, double const x) {
  if (({ __auto_type __sc148 = name; __auto_type __sc149 = (str){ (const uint8_t *)"sqrt", sizeof("sqrt") - 1 }; str__eq(&__sc148, &__sc149); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = sqrt(x) };
  }
  if (({ __auto_type __sc150 = name; __auto_type __sc151 = (str){ (const uint8_t *)"cbrt", sizeof("cbrt") - 1 }; str__eq(&__sc150, &__sc151); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = cbrt(x) };
  }
  if (({ __auto_type __sc152 = name; __auto_type __sc153 = (str){ (const uint8_t *)"exp", sizeof("exp") - 1 }; str__eq(&__sc152, &__sc153); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = exp(x) };
  }
  if (({ __auto_type __sc154 = name; __auto_type __sc155 = (str){ (const uint8_t *)"exp2", sizeof("exp2") - 1 }; str__eq(&__sc154, &__sc155); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = exp2(x) };
  }
  if (({ __auto_type __sc156 = name; __auto_type __sc157 = (str){ (const uint8_t *)"expm1", sizeof("expm1") - 1 }; str__eq(&__sc156, &__sc157); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = expm1(x) };
  }
  if (({ __auto_type __sc158 = name; __auto_type __sc159 = (str){ (const uint8_t *)"log", sizeof("log") - 1 }; str__eq(&__sc158, &__sc159); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = log(x) };
  }
  if (({ __auto_type __sc160 = name; __auto_type __sc161 = (str){ (const uint8_t *)"log2", sizeof("log2") - 1 }; str__eq(&__sc160, &__sc161); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = log2(x) };
  }
  if (({ __auto_type __sc162 = name; __auto_type __sc163 = (str){ (const uint8_t *)"log10", sizeof("log10") - 1 }; str__eq(&__sc162, &__sc163); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = log10(x) };
  }
  if (({ __auto_type __sc164 = name; __auto_type __sc165 = (str){ (const uint8_t *)"log1p", sizeof("log1p") - 1 }; str__eq(&__sc164, &__sc165); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = log1p(x) };
  }
  if (({ __auto_type __sc166 = name; __auto_type __sc167 = (str){ (const uint8_t *)"sin", sizeof("sin") - 1 }; str__eq(&__sc166, &__sc167); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = sin(x) };
  }
  if (({ __auto_type __sc168 = name; __auto_type __sc169 = (str){ (const uint8_t *)"cos", sizeof("cos") - 1 }; str__eq(&__sc168, &__sc169); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = cos(x) };
  }
  if (({ __auto_type __sc170 = name; __auto_type __sc171 = (str){ (const uint8_t *)"tan", sizeof("tan") - 1 }; str__eq(&__sc170, &__sc171); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = tan(x) };
  }
  if (({ __auto_type __sc172 = name; __auto_type __sc173 = (str){ (const uint8_t *)"asin", sizeof("asin") - 1 }; str__eq(&__sc172, &__sc173); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = asin(x) };
  }
  if (({ __auto_type __sc174 = name; __auto_type __sc175 = (str){ (const uint8_t *)"acos", sizeof("acos") - 1 }; str__eq(&__sc174, &__sc175); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = acos(x) };
  }
  if (({ __auto_type __sc176 = name; __auto_type __sc177 = (str){ (const uint8_t *)"atan", sizeof("atan") - 1 }; str__eq(&__sc176, &__sc177); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = atan(x) };
  }
  if (({ __auto_type __sc178 = name; __auto_type __sc179 = (str){ (const uint8_t *)"sinh", sizeof("sinh") - 1 }; str__eq(&__sc178, &__sc179); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = sinh(x) };
  }
  if (({ __auto_type __sc180 = name; __auto_type __sc181 = (str){ (const uint8_t *)"cosh", sizeof("cosh") - 1 }; str__eq(&__sc180, &__sc181); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = cosh(x) };
  }
  if (({ __auto_type __sc182 = name; __auto_type __sc183 = (str){ (const uint8_t *)"tanh", sizeof("tanh") - 1 }; str__eq(&__sc182, &__sc183); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = tanh(x) };
  }
  if (({ __auto_type __sc184 = name; __auto_type __sc185 = (str){ (const uint8_t *)"asinh", sizeof("asinh") - 1 }; str__eq(&__sc184, &__sc185); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = asinh(x) };
  }
  if (({ __auto_type __sc186 = name; __auto_type __sc187 = (str){ (const uint8_t *)"acosh", sizeof("acosh") - 1 }; str__eq(&__sc186, &__sc187); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = acosh(x) };
  }
  if (({ __auto_type __sc188 = name; __auto_type __sc189 = (str){ (const uint8_t *)"atanh", sizeof("atanh") - 1 }; str__eq(&__sc188, &__sc189); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = atanh(x) };
  }
  if (({ __auto_type __sc190 = name; __auto_type __sc191 = (str){ (const uint8_t *)"floor", sizeof("floor") - 1 }; str__eq(&__sc190, &__sc191); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = floor(x) };
  }
  if (({ __auto_type __sc192 = name; __auto_type __sc193 = (str){ (const uint8_t *)"ceil", sizeof("ceil") - 1 }; str__eq(&__sc192, &__sc193); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = ceil(x) };
  }
  if (({ __auto_type __sc194 = name; __auto_type __sc195 = (str){ (const uint8_t *)"round", sizeof("round") - 1 }; str__eq(&__sc194, &__sc195); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = round(x) };
  }
  if (({ __auto_type __sc196 = name; __auto_type __sc197 = (str){ (const uint8_t *)"trunc", sizeof("trunc") - 1 }; str__eq(&__sc196, &__sc197); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = trunc(x) };
  }
  if (({ __auto_type __sc198 = name; __auto_type __sc199 = (str){ (const uint8_t *)"fabs", sizeof("fabs") - 1 }; str__eq(&__sc198, &__sc199); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = fabs(x) };
  }
  return (consteval__consteval__DblRes){ .ok = false, .v = 0.0 };
}

static __attribute__((unused)) consteval__consteval__DblRes consteval__consteval__libm2(str const name, double const x, double const y) {
  if (({ __auto_type __sc200 = name; __auto_type __sc201 = (str){ (const uint8_t *)"pow", sizeof("pow") - 1 }; str__eq(&__sc200, &__sc201); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = pow(x, y) };
  }
  if (({ __auto_type __sc202 = name; __auto_type __sc203 = (str){ (const uint8_t *)"hypot", sizeof("hypot") - 1 }; str__eq(&__sc202, &__sc203); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = hypot(x, y) };
  }
  if (({ __auto_type __sc204 = name; __auto_type __sc205 = (str){ (const uint8_t *)"atan2", sizeof("atan2") - 1 }; str__eq(&__sc204, &__sc205); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = atan2(x, y) };
  }
  if (({ __auto_type __sc206 = name; __auto_type __sc207 = (str){ (const uint8_t *)"fmod", sizeof("fmod") - 1 }; str__eq(&__sc206, &__sc207); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = fmod(x, y) };
  }
  if (({ __auto_type __sc208 = name; __auto_type __sc209 = (str){ (const uint8_t *)"copysign", sizeof("copysign") - 1 }; str__eq(&__sc208, &__sc209); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = copysign(x, y) };
  }
  if (({ __auto_type __sc210 = name; __auto_type __sc211 = (str){ (const uint8_t *)"fmin", sizeof("fmin") - 1 }; str__eq(&__sc210, &__sc211); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = fmin(x, y) };
  }
  if (({ __auto_type __sc212 = name; __auto_type __sc213 = (str){ (const uint8_t *)"fmax", sizeof("fmax") - 1 }; str__eq(&__sc212, &__sc213); })) {
    return (consteval__consteval__DblRes){ .ok = true, .v = fmax(x, y) };
  }
  return (consteval__consteval__DblRes){ .ok = false, .v = 0.0 };
}

