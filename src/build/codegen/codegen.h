#ifndef SUPER_CODEGEN__CODEGEN_H
#define SUPER_CODEGEN__CODEGEN_H

#include "../super_rt.h"
typedef struct str str;
#ifndef SUPER_ENUM_ast__ast__BuiltinType
#define SUPER_ENUM_ast__ast__BuiltinType
typedef enum { ast__ast__BuiltinType_BT_BOOL, ast__ast__BuiltinType_BT_CHAR, ast__ast__BuiltinType_BT_I8, ast__ast__BuiltinType_BT_I16, ast__ast__BuiltinType_BT_I32, ast__ast__BuiltinType_BT_I64, ast__ast__BuiltinType_BT_ISIZE, ast__ast__BuiltinType_BT_U8, ast__ast__BuiltinType_BT_U16, ast__ast__BuiltinType_BT_U32, ast__ast__BuiltinType_BT_U64, ast__ast__BuiltinType_BT_USIZE, ast__ast__BuiltinType_BT_F32, ast__ast__BuiltinType_BT_F64, ast__ast__BuiltinType_BT_C32, ast__ast__BuiltinType_BT_C64, ast__ast__BuiltinType_BT_VALIST, ast__ast__BuiltinType_BT_VOID, ast__ast__BuiltinType_BT_COUNT } ast__ast__BuiltinType;
#endif
typedef struct ast__ast__DefId ast__ast__DefId;
typedef struct ast__ast__Ast ast__ast__Ast;
typedef struct Global Global;
typedef struct String__Global String__Global;
typedef struct Map__u32__u32__Global Map__u32__u32__Global;
typedef struct Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global;
typedef struct module__loader__Package module__loader__Package;
typedef struct utils__errors__Errors utils__errors__Errors;
typedef struct Vector__String__Global__Global Vector__String__Global__Global;
typedef struct Vector__u32__Global Vector__u32__Global;
typedef struct module__loader__Module module__loader__Module;
typedef struct Vector__module__loader__Module__Global Vector__module__loader__Module__Global;
typedef struct consteval__consteval__ConstEval consteval__consteval__ConstEval;
typedef struct ast__ast__Ty ast__ast__Ty;
typedef struct lexer__token__Span lexer__token__Span;
typedef struct ast__ast__Node ast__ast__Node;
typedef union ast__ast__NodeAs ast__ast__NodeAs;
typedef struct ast__ast__NameData ast__ast__NameData;
typedef struct ast__ast__InterfaceData ast__ast__InterfaceData;
typedef struct ast__ast__ProgramData ast__ast__ProgramData;
typedef struct ast__ast__NodeList ast__ast__NodeList;
#ifndef SUPER_ENUM_ast__ast__NodeKind
#define SUPER_ENUM_ast__ast__NodeKind
typedef enum { ast__ast__NodeKind_NODE_NONE_KIND, ast__ast__NodeKind_NODE_PROGRAM, ast__ast__NodeKind_NODE_IDENTIFIER, ast__ast__NodeKind_NODE_LITERAL, ast__ast__NodeKind_NODE_FUNCTION, ast__ast__NodeKind_NODE_PARAMETER, ast__ast__NodeKind_NODE_STRUCT, ast__ast__NodeKind_NODE_FIELD, ast__ast__NodeKind_NODE_ENUM, ast__ast__NodeKind_NODE_VARIANT, ast__ast__NodeKind_NODE_INTERFACE, ast__ast__NodeKind_NODE_EXTEND, ast__ast__NodeKind_NODE_TYPE_ALIAS, ast__ast__NodeKind_NODE_CONST, ast__ast__NodeKind_NODE_STATIC_ASSERT, ast__ast__NodeKind_NODE_EXTERN_BLOCK, ast__ast__NodeKind_NODE_IMPORT, ast__ast__NodeKind_NODE_GENERIC_PARAM, ast__ast__NodeKind_NODE_WHERE_PREDICATE, ast__ast__NodeKind_NODE_TYPE_PATH, ast__ast__NodeKind_NODE_POINTER_TYPE, ast__ast__NodeKind_NODE_REFERENCE_TYPE, ast__ast__NodeKind_NODE_SLICE_TYPE, ast__ast__NodeKind_NODE_ARRAY_TYPE, ast__ast__NodeKind_NODE_FUNCTION_TYPE, ast__ast__NodeKind_NODE_DYN_TYPE, ast__ast__NodeKind_NODE_BLOCK, ast__ast__NodeKind_NODE_LET, ast__ast__NodeKind_NODE_RETURN, ast__ast__NodeKind_NODE_BREAK, ast__ast__NodeKind_NODE_CONTINUE, ast__ast__NodeKind_NODE_DEFER, ast__ast__NodeKind_NODE_IF, ast__ast__NodeKind_NODE_WHILE, ast__ast__NodeKind_NODE_FOR, ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, ast__ast__NodeKind_NODE_UNARY, ast__ast__NodeKind_NODE_BINARY, ast__ast__NodeKind_NODE_ASSIGNMENT, ast__ast__NodeKind_NODE_CALL, ast__ast__NodeKind_NODE_CLOSURE, ast__ast__NodeKind_NODE_INDEX, ast__ast__NodeKind_NODE_MEMBER, ast__ast__NodeKind_NODE_CAST, ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION, ast__ast__NodeKind_NODE_MATCH, ast__ast__NodeKind_NODE_MATCH_ARM, ast__ast__NodeKind_NODE_NEW, ast__ast__NodeKind_NODE_SIZEOF, ast__ast__NodeKind_NODE_ALIGNOF, ast__ast__NodeKind_NODE_VA_EXPR, ast__ast__NodeKind_NODE_ARRAY_LITERAL, ast__ast__NodeKind_NODE_STRUCT_INITIALIZER, ast__ast__NodeKind_NODE_FIELD_INITIALIZER, ast__ast__NodeKind_NODE_PATTERN_WILDCARD, ast__ast__NodeKind_NODE_PATTERN_LITERAL, ast__ast__NodeKind_NODE_PATTERN_NAME, ast__ast__NodeKind_NODE_PATTERN_TUPLE, ast__ast__NodeKind_NODE_PATTERN_STRUCT, ast__ast__NodeKind_NODE_PATTERN_FIELD, ast__ast__NodeKind_NODE_PATTERN_RANGE, ast__ast__NodeKind_NODE_PATTERN_OR, ast__ast__NodeKind_NODE_RANGE, ast__ast__NodeKind_NODE_TUPLE, ast__ast__NodeKind_NODE_TUPLE_TYPE, ast__ast__NodeKind_NODE_KIND_COUNT } ast__ast__NodeKind;
#endif
typedef struct ast__ast__AggregateData ast__ast__AggregateData;
#ifndef SUPER_ENUM_ast__ast__TypeKind
#define SUPER_ENUM_ast__ast__TypeKind
typedef enum { ast__ast__TypeKind_TYPE_ERROR, ast__ast__TypeKind_TYPE_BUILTIN, ast__ast__TypeKind_TYPE_POINTER, ast__ast__TypeKind_TYPE_REFERENCE, ast__ast__TypeKind_TYPE_SLICE, ast__ast__TypeKind_TYPE_ARRAY, ast__ast__TypeKind_TYPE_FUNCTION, ast__ast__TypeKind_TYPE_STRUCT, ast__ast__TypeKind_TYPE_ENUM, ast__ast__TypeKind_TYPE_GENERIC, ast__ast__TypeKind_TYPE_INSTANCE, ast__ast__TypeKind_TYPE_OPAQUE, ast__ast__TypeKind_TYPE_DYN, ast__ast__TypeKind_TYPE_NEVER, ast__ast__TypeKind_TYPE_CONST } ast__ast__TypeKind;
#endif
typedef union ast__ast__TyAs ast__ast__TyAs;
typedef struct ast__ast__TyArr ast__ast__TyArr;
typedef struct ast__ast__TyInstance ast__ast__TyInstance;
typedef struct ast__ast__FunctionData ast__ast__FunctionData;
#ifndef SUPER_ENUM_ast__ast__TypeQualifier
#define SUPER_ENUM_ast__ast__TypeQualifier
typedef enum { ast__ast__TypeQualifier_TYPE_QUAL_NONE, ast__ast__TypeQualifier_TYPE_QUAL_CONST, ast__ast__TypeQualifier_TYPE_QUAL_MUT } ast__ast__TypeQualifier;
#endif
typedef struct ast__ast__FunctionTypeData ast__ast__FunctionTypeData;
typedef struct ast__ast__ParameterData ast__ast__ParameterData;
typedef struct ast__ast__GenericParamData ast__ast__GenericParamData;
typedef struct ast__ast__CallData ast__ast__CallData;
typedef struct ast__ast__SpecializationData ast__ast__SpecializationData;
typedef struct ast__ast__MonoUse ast__ast__MonoUse;
typedef struct Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global;
typedef struct Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global;
typedef struct ast__ast__ExtendData ast__ast__ExtendData;
typedef struct ast__ast__ClosureData ast__ast__ClosureData;
typedef struct ast__ast__TypeAliasData ast__ast__TypeAliasData;
typedef struct ast__ast__TypePathData ast__ast__TypePathData;
typedef struct ast__ast__IndirectTypeData ast__ast__IndirectTypeData;
typedef struct ast__ast__ArrayTypeData ast__ast__ArrayTypeData;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct ast__ast__VariantData ast__ast__VariantData;
typedef struct module__loader__LookupHit module__loader__LookupHit;
typedef struct Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId;
typedef struct ast__ast__ConstData ast__ast__ConstData;
typedef struct ast__ast__BinaryData ast__ast__BinaryData;
typedef struct ast__ast__UnaryData ast__ast__UnaryData;
typedef struct ast__ast__CastData ast__ast__CastData;
typedef struct ast__ast__IndexData ast__ast__IndexData;
typedef struct ast__ast__MemberData ast__ast__MemberData;
#ifndef SUPER_ENUM_lexer__token_type__TokenType
#define SUPER_ENUM_lexer__token_type__TokenType
typedef enum { lexer__token_type__TokenType_Identifier, lexer__token_type__TokenType_Label, lexer__token_type__TokenType_As, lexer__token_type__TokenType_Import, lexer__token_type__TokenType_Break, lexer__token_type__TokenType_Case, lexer__token_type__TokenType_Const, lexer__token_type__TokenType_Continue, lexer__token_type__TokenType_Defer, lexer__token_type__TokenType_Do, lexer__token_type__TokenType_Dyn, lexer__token_type__TokenType_Else, lexer__token_type__TokenType_Enum, lexer__token_type__TokenType_Extern, lexer__token_type__TokenType_False, lexer__token_type__TokenType_Fn, lexer__token_type__TokenType_For, lexer__token_type__TokenType_If, lexer__token_type__TokenType_Extend, lexer__token_type__TokenType_In, lexer__token_type__TokenType_Let, lexer__token_type__TokenType_Loop, lexer__token_type__TokenType_Switch, lexer__token_type__TokenType_Move, lexer__token_type__TokenType_Mut, lexer__token_type__TokenType_New, lexer__token_type__TokenType_Null, lexer__token_type__TokenType_Pub, lexer__token_type__TokenType_Sizeof, lexer__token_type__TokenType_Alignof, lexer__token_type__TokenType_Return, lexer__token_type__TokenType_SelfLower, lexer__token_type__TokenType_SelfUpper, lexer__token_type__TokenType_Struct, lexer__token_type__TokenType_Interface, lexer__token_type__TokenType_True, lexer__token_type__TokenType_Type, lexer__token_type__TokenType_Union, lexer__token_type__TokenType_Unsafe, lexer__token_type__TokenType_Where, lexer__token_type__TokenType_While, lexer__token_type__TokenType_IntegerLiteral, lexer__token_type__TokenType_FloatLiteral, lexer__token_type__TokenType_CharacterLiteral, lexer__token_type__TokenType_ByteCharacterLiteral, lexer__token_type__TokenType_StringLiteral, lexer__token_type__TokenType_RawStringLiteral, lexer__token_type__TokenType_ByteStringLiteral, lexer__token_type__TokenType_LeftBrace, lexer__token_type__TokenType_RightBrace, lexer__token_type__TokenType_LeftParen, lexer__token_type__TokenType_RightParen, lexer__token_type__TokenType_LeftBracket, lexer__token_type__TokenType_RightBracket, lexer__token_type__TokenType_Comma, lexer__token_type__TokenType_Semicolon, lexer__token_type__TokenType_Colon, lexer__token_type__TokenType_Dot, lexer__token_type__TokenType_At, lexer__token_type__TokenType_Plus, lexer__token_type__TokenType_Minus, lexer__token_type__TokenType_Star, lexer__token_type__TokenType_Slash, lexer__token_type__TokenType_Percent, lexer__token_type__TokenType_Tilde, lexer__token_type__TokenType_Bang, lexer__token_type__TokenType_Question, lexer__token_type__TokenType_EqualEqual, lexer__token_type__TokenType_BangEqual, lexer__token_type__TokenType_LessThan, lexer__token_type__TokenType_LessThanEqual, lexer__token_type__TokenType_GreaterThan, lexer__token_type__TokenType_GreaterThanEqual, lexer__token_type__TokenType_Ampersand, lexer__token_type__TokenType_Pipe, lexer__token_type__TokenType_Caret, lexer__token_type__TokenType_AmpersandAmpersand, lexer__token_type__TokenType_PipePipe, lexer__token_type__TokenType_LeftShift, lexer__token_type__TokenType_RightShift, lexer__token_type__TokenType_Equal, lexer__token_type__TokenType_PlusEqual, lexer__token_type__TokenType_MinusEqual, lexer__token_type__TokenType_StarEqual, lexer__token_type__TokenType_SlashEqual, lexer__token_type__TokenType_PercentEqual, lexer__token_type__TokenType_AmpersandEqual, lexer__token_type__TokenType_PipeEqual, lexer__token_type__TokenType_CaretEqual, lexer__token_type__TokenType_LeftShiftEqual, lexer__token_type__TokenType_RightShiftEqual, lexer__token_type__TokenType_Range, lexer__token_type__TokenType_RangeInclusive, lexer__token_type__TokenType_Ellipsis, lexer__token_type__TokenType_PathSeparator, lexer__token_type__TokenType_Arrow, lexer__token_type__TokenType_FatArrow, lexer__token_type__TokenType_Eof } lexer__token_type__TokenType;
#endif
typedef struct ast__ast__LiteralData ast__ast__LiteralData;
typedef struct ast__ast__DerefUse ast__ast__DerefUse;
typedef struct ast__ast__StructInitializerData ast__ast__StructInitializerData;
typedef struct ast__ast__FieldInitializerData ast__ast__FieldInitializerData;
typedef struct ast__ast__NewData ast__ast__NewData;
typedef struct ast__ast__LetData ast__ast__LetData;
typedef struct ast__ast__PatternData ast__ast__PatternData;
typedef struct ast__ast__WhileData ast__ast__WhileData;
typedef struct ast__ast__FlowData ast__ast__FlowData;
typedef struct ast__ast__SingleData ast__ast__SingleData;
typedef struct ast__ast__ReturnData ast__ast__ReturnData;
typedef struct ast__ast__ForData ast__ast__ForData;
typedef struct ast__ast__PatternRangeData ast__ast__PatternRangeData;
typedef struct ast__ast__BlockData ast__ast__BlockData;
typedef struct ast__ast__MatchData ast__ast__MatchData;
typedef struct ast__ast__MatchArmData ast__ast__MatchArmData;
typedef struct ast__ast__IfData ast__ast__IfData;
typedef struct ast__ast__ArrayLiteralData ast__ast__ArrayLiteralData;
typedef struct ast__ast__DynUse ast__ast__DynUse;
typedef struct ast__ast__FieldData ast__ast__FieldData;
#ifndef SUPER_ENUM_ast__ast__AttrKind
#define SUPER_ENUM_ast__ast__AttrKind
typedef enum { ast__ast__AttrKind_ATTR_INLINE, ast__ast__AttrKind_ATTR_ALWAYS_INLINE, ast__ast__AttrKind_ATTR_NOINLINE, ast__ast__AttrKind_ATTR_NORETURN, ast__ast__AttrKind_ATTR_ALIGN, ast__ast__AttrKind_ATTR_PACKED, ast__ast__AttrKind_ATTR_EXPORT, ast__ast__AttrKind_ATTR_IMPORT, ast__ast__AttrKind_ATTR_SECTION, ast__ast__AttrKind_ATTR_USED, ast__ast__AttrKind_ATTR_UNUSED, ast__ast__AttrKind_ATTR_EMIT_MACRO, ast__ast__AttrKind_ATTR_TEST, ast__ast__AttrKind_ATTR_TEST_INIT, ast__ast__AttrKind_ATTR_TEST_FREE, ast__ast__AttrKind_ATTR_C_SOURCE, ast__ast__AttrKind_ATTR_C_LINK, ast__ast__AttrKind_ATTR_COLD, ast__ast__AttrKind_ATTR_PLATFORM } ast__ast__AttrKind;
#endif
typedef struct ast__ast__Attr ast__ast__Attr;
typedef struct Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global;
typedef struct consteval__consteval__ConstValue consteval__consteval__ConstValue;
typedef union consteval__consteval__ConstValueAs consteval__consteval__ConstValueAs;
typedef struct ast__ast__VaOpData ast__ast__VaOpData;
typedef struct ast__ast__MethodInst ast__ast__MethodInst;
typedef struct Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global;
typedef struct Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global;
typedef struct Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global;
typedef struct consteval__consteval__Layout consteval__consteval__Layout;
typedef struct Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global;
typedef struct ast__ast__ExternBlockData ast__ast__ExternBlockData;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Range__usize Range__usize;
typedef struct Option__u32 Option__u32;
typedef struct MapKeys__u32 MapKeys__u32;
typedef struct MapValues__u32 MapValues__u32;
typedef struct Option__ast__ast__DefId Option__ast__ast__DefId;
typedef struct MapKeys__u64 MapKeys__u64;
typedef struct MapValues__ast__ast__DefId MapValues__ast__ast__DefId;
typedef struct Option__String__Global Option__String__Global;
typedef struct Option__ptr_String__Global Option__ptr_String__Global;
typedef struct Option__usize Option__usize;
typedef struct Result__usize__usize Result__usize__usize;
typedef struct VecIter__String__Global VecIter__String__Global;
typedef struct Slice__String__Global Slice__String__Global;
typedef struct SliceMut__String__Global SliceMut__String__Global;
typedef struct VecIter__u32 VecIter__u32;
typedef struct Slice__u32 Slice__u32;
typedef struct SliceMut__u32 SliceMut__u32;
typedef struct Option__module__loader__Module Option__module__loader__Module;
typedef struct Option__ptr_module__loader__Module Option__ptr_module__loader__Module;
typedef struct VecIter__module__loader__Module VecIter__module__loader__Module;
typedef struct Slice__module__loader__Module Slice__module__loader__Module;
typedef struct SliceMut__module__loader__Module SliceMut__module__loader__Module;
typedef struct Option__ast__ast__Node Option__ast__ast__Node;
typedef struct Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node;
typedef struct VecIter__ast__ast__Node VecIter__ast__ast__Node;
typedef struct Slice__ast__ast__Node Slice__ast__ast__Node;
typedef struct SliceMut__ast__ast__Node SliceMut__ast__ast__Node;
typedef struct Option__ast__ast__TyInstance Option__ast__ast__TyInstance;
typedef struct Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance;
typedef struct VecIter__ast__ast__TyInstance VecIter__ast__ast__TyInstance;
typedef struct Slice__ast__ast__TyInstance Slice__ast__ast__TyInstance;
typedef struct SliceMut__ast__ast__TyInstance SliceMut__ast__ast__TyInstance;
typedef struct Option__ast__ast__Attr Option__ast__ast__Attr;
typedef struct Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr;
typedef struct VecIter__ast__ast__Attr VecIter__ast__ast__Attr;
typedef struct Slice__ast__ast__Attr Slice__ast__ast__Attr;
typedef struct SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr;
typedef struct Option__ast__ast__MethodInst Option__ast__ast__MethodInst;
typedef struct Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst;
typedef struct VecIter__ast__ast__MethodInst VecIter__ast__ast__MethodInst;
typedef struct Slice__ast__ast__MethodInst Slice__ast__ast__MethodInst;
typedef struct SliceMut__ast__ast__MethodInst SliceMut__ast__ast__MethodInst;
typedef struct Option__ast__ast__Ty Option__ast__ast__Ty;
typedef struct Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty;
typedef struct VecIter__ast__ast__Ty VecIter__ast__ast__Ty;
typedef struct Slice__ast__ast__Ty Slice__ast__ast__Ty;
typedef struct SliceMut__ast__ast__Ty SliceMut__ast__ast__Ty;
typedef struct Option__ast__ast__DynUse Option__ast__ast__DynUse;
typedef struct Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse;
typedef struct VecIter__ast__ast__DynUse VecIter__ast__ast__DynUse;
typedef struct Slice__ast__ast__DynUse Slice__ast__ast__DynUse;
typedef struct SliceMut__ast__ast__DynUse SliceMut__ast__ast__DynUse;
typedef struct VecIter__ast__ast__DefId VecIter__ast__ast__DefId;
typedef struct Slice__ast__ast__DefId Slice__ast__ast__DefId;
typedef struct SliceMut__ast__ast__DefId SliceMut__ast__ast__DefId;
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Option__ptr_u64 Option__ptr_u64;
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
#include "../__std/interfaces.h"
#include "../__std/map.h"
#include "../__std/option.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

typedef struct codegen__codegen__CgSubst codegen__codegen__CgSubst;
typedef struct codegen__codegen__CgInst codegen__codegen__CgInst;
typedef struct codegen__codegen__CgCbInst codegen__codegen__CgCbInst;
typedef struct codegen__codegen__CgLoop codegen__codegen__CgLoop;
typedef struct codegen__codegen__CgTestCase codegen__codegen__CgTestCase;
typedef struct codegen__codegen__CgTestInfo codegen__codegen__CgTestInfo;
typedef struct codegen__codegen__Buf32 codegen__codegen__Buf32;
typedef struct codegen__codegen__Buf64 codegen__codegen__Buf64;
typedef struct codegen__codegen__Buf128 codegen__codegen__Buf128;
typedef struct codegen__codegen__Buf160 codegen__codegen__Buf160;
typedef struct codegen__codegen__Buf256 codegen__codegen__Buf256;
typedef struct codegen__codegen__Buf512 codegen__codegen__Buf512;
typedef struct codegen__codegen__Codegen codegen__codegen__Codegen;
typedef struct codegen__codegen__ScopeArr codegen__codegen__ScopeArr;
typedef struct codegen__codegen__Bytes4 codegen__codegen__Bytes4;
typedef struct codegen__codegen__TyArgs4 codegen__codegen__TyArgs4;
typedef struct codegen__codegen__Buf176 codegen__codegen__Buf176;
typedef struct codegen__codegen__Buf200 codegen__codegen__Buf200;
typedef struct codegen__codegen__Buf240 codegen__codegen__Buf240;
typedef struct codegen__codegen__Buf300 codegen__codegen__Buf300;
typedef struct codegen__codegen__Buf320 codegen__codegen__Buf320;
typedef struct codegen__codegen__Buf368 codegen__codegen__Buf368;
typedef struct codegen__codegen__Buf400 codegen__codegen__Buf400;
typedef struct codegen__codegen__Buf600 codegen__codegen__Buf600;
typedef struct codegen__codegen__Buf1024 codegen__codegen__Buf1024;
typedef struct codegen__codegen__Buf1320 codegen__codegen__Buf1320;
typedef struct codegen__codegen__Buf1400 codegen__codegen__Buf1400;
typedef struct codegen__codegen__Buf4096 codegen__codegen__Buf4096;
typedef struct codegen__codegen__TyArgs32 codegen__codegen__TyArgs32;
typedef struct codegen__codegen__Ids64 codegen__codegen__Ids64;
typedef struct codegen__codegen__FmtSpec codegen__codegen__FmtSpec;

struct codegen__codegen__CgSubst {
  ast__ast__DefId param;
  uint32_t concrete;
};
struct codegen__codegen__CgInst {
  ast__ast__DefId func;
  uint8_t n;
  uint32_t args[4];
};
struct codegen__codegen__CgCbInst {
  ast__ast__DefId func;
  uint32_t param;
  uint32_t cbidx;
  ast__ast__DefId callee;
  bool callee_closure;
};
struct codegen__codegen__CgLoop {
  uint32_t node;
  uint32_t defer_base;
  uint32_t seq;
  bool used_brk;
  bool used_cnt;
  bool is_expr;
};
struct codegen__codegen__CgTestCase {
  uint32_t func;
  uint8_t wants;
  ast__ast__DefId suite;
  bool suite_is_enum;
  uint32_t suite_init;
  uint32_t suite_free;
};
struct codegen__codegen__CgTestInfo {
  bool enabled;
  const codegen__codegen__CgTestCase *cases;
  uint32_t ncases;
  uint32_t fx_init;
  uint32_t fx_free;
  ast__ast__DefId fx_type;
  bool fx_is_enum;
  uint32_t genv_init;
  uint32_t genv_free;
  ast__ast__DefId genv_type;
  bool genv_is_enum;
};
struct codegen__codegen__Buf32 {
  char b[32];
};
struct codegen__codegen__Buf64 {
  char b[64];
};
struct codegen__codegen__Buf128 {
  char b[128];
};
struct codegen__codegen__Buf160 {
  char b[160];
};
struct codegen__codegen__Buf256 {
  char b[256];
};
struct codegen__codegen__Buf512 {
  char b[512];
};
struct codegen__codegen__Codegen {
  ast__ast__Ast *ast;
  const uint8_t *source;
  size_t len;
  String__Global buf;
  Map__u32__u32__Global enum_of_variant;
  Map__u64__ast__ast__DefId__Global free_ext_cache;
  uint32_t depth;
  uint32_t tmp;
  char current_ret[128];
  uint32_t current_fn_ret_node;
  module__loader__Package *package;
  bool mangle;
  bool multifile;
  bool const_ctx;
  codegen__codegen__CgSubst subst[16];
  int32_t nsubst;
  codegen__codegen__CgInst insts[1024];
  int32_t ninsts;
  bool insts_overflow;
  codegen__codegen__CgCbInst cb_insts[256];
  int32_t n_cb_insts;
  uint32_t cb_keep_fns[128];
  int32_t n_cb_keep;
  uint32_t cb_param;
  ast__ast__DefId cb_callee;
  bool cb_callee_closure;
  bool macro_mode;
  uint32_t macro_self;
  uint16_t macro_self_mod;
  bool borrowed;
  uint16_t dflt_home;
  bool dflt_home_set;
  bool fnval_pass;
  uint32_t slice_raw;
  uint32_t dyn_raw;
  uint32_t env_clos;
  bool minst_only;
  uint32_t defer_stack[256];
  uint8_t defer_kind[256];
  uint32_t defer_top;
  uint32_t loop_defer_base;
  codegen__codegen__CgLoop loop_stack[32];
  uint32_t nloops;
  uint32_t label_seq;
  uint32_t pending_cnt;
  codegen__codegen__CgTestInfo test;
  uint32_t moved[512];
  uint32_t nmoved;
  uint32_t cond_moved[256];
  uint32_t ncond_moved;
  uint32_t cond_sites[256];
  uint32_t ncond_sites;
  uint32_t param_flags[32];
  uint32_t nparam_flags;
  uint32_t unused_params[32];
  uint32_t nunused_params;
  bool no_temp_free;
  uint8_t *type_state;
  uint8_t *inst_emit_state;
  size_t inst_emit_n;
  utils__errors__Errors errors;
};
struct codegen__codegen__ScopeArr {
  uint16_t s[3];
};
struct codegen__codegen__Bytes4 {
  uint8_t b[4];
};
struct codegen__codegen__TyArgs4 {
  uint32_t t[4];
};
struct codegen__codegen__Buf176 {
  char b[176];
};
struct codegen__codegen__Buf200 {
  char b[200];
};
struct codegen__codegen__Buf240 {
  char b[240];
};
struct codegen__codegen__Buf300 {
  char b[300];
};
struct codegen__codegen__Buf320 {
  char b[320];
};
struct codegen__codegen__Buf368 {
  char b[368];
};
struct codegen__codegen__Buf400 {
  char b[400];
};
struct codegen__codegen__Buf600 {
  char b[600];
};
struct codegen__codegen__Buf1024 {
  char b[1024];
};
struct codegen__codegen__Buf1320 {
  char b[1320];
};
struct codegen__codegen__Buf1400 {
  char b[1400];
};
struct codegen__codegen__Buf4096 {
  char b[4096];
};
struct codegen__codegen__TyArgs32 {
  uint32_t t[32];
};
struct codegen__codegen__Ids64 {
  uint32_t b[64];
};
struct codegen__codegen__FmtSpec {
  char ty;
  char align;
  uint8_t fill;
  int32_t width;
  int32_t prec;
};

const char *codegen__codegen__super_rt_includes(void);
void codegen__codegen__Codegen__free(codegen__codegen__Codegen *const self);
codegen__codegen__Codegen codegen__codegen__Codegen__new(ast__ast__Ast *const ast, str const source, module__loader__Package *const package);
ast__ast__Ast *codegen__codegen__Codegen__take_ast(codegen__codegen__Codegen *const self);
bool codegen__codegen__Codegen__has_errors(const codegen__codegen__Codegen *const self);
void codegen__codegen__Codegen__log_errors(const codegen__codegen__Codegen *const self);
void codegen__codegen__Codegen__set_multifile(codegen__codegen__Codegen *const self, bool const on);
void codegen__codegen__Codegen__set_test_info(codegen__codegen__Codegen *const self, const codegen__codegen__CgTestInfo *const ti);
void codegen__codegen__Codegen__codegen_emit_header(codegen__codegen__Codegen *const self, FILE *const out);
void codegen__codegen__Codegen__codegen_emit(codegen__codegen__Codegen *const self, FILE *const out);

__attribute__((unused)) static const int32_t codegen__codegen__PROTO_ALL = 0;
__attribute__((unused)) static const int32_t codegen__codegen__PROTO_PUBLIC = 1;
__attribute__((unused)) static const int32_t codegen__codegen__PROTO_PRIVATE = 2;
__attribute__((unused)) static const char codegen__codegen__CG_PASTE = 1;

#endif
