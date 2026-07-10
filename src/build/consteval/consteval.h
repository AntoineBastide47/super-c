#ifndef SUPER_CONSTEVAL__CONSTEVAL_H
#define SUPER_CONSTEVAL__CONSTEVAL_H

#include "../super_rt.h"
typedef struct Global Global;
typedef struct Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global;
#ifndef SUPER_ENUM_ast__ast__BuiltinType
#define SUPER_ENUM_ast__ast__BuiltinType
typedef enum { ast__ast__BuiltinType_BT_BOOL, ast__ast__BuiltinType_BT_CHAR, ast__ast__BuiltinType_BT_I8, ast__ast__BuiltinType_BT_I16, ast__ast__BuiltinType_BT_I32, ast__ast__BuiltinType_BT_I64, ast__ast__BuiltinType_BT_ISIZE, ast__ast__BuiltinType_BT_U8, ast__ast__BuiltinType_BT_U16, ast__ast__BuiltinType_BT_U32, ast__ast__BuiltinType_BT_U64, ast__ast__BuiltinType_BT_USIZE, ast__ast__BuiltinType_BT_F32, ast__ast__BuiltinType_BT_F64, ast__ast__BuiltinType_BT_C32, ast__ast__BuiltinType_BT_C64, ast__ast__BuiltinType_BT_VALIST, ast__ast__BuiltinType_BT_VOID, ast__ast__BuiltinType_BT_COUNT } ast__ast__BuiltinType;
#endif
typedef struct module__loader__Package module__loader__Package;
typedef struct Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global;
typedef struct Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global;
typedef struct Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global;
typedef struct str str;
typedef struct Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global;
typedef struct Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global;
typedef struct Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global;
typedef struct module__loader__Module module__loader__Module;
typedef struct Vector__module__loader__Module__Global Vector__module__loader__Module__Global;
typedef struct ast__ast__Ast ast__ast__Ast;
typedef struct String__Global String__Global;
typedef struct Vector__u32__Global Vector__u32__Global;
typedef struct lexer__token__Span lexer__token__Span;
typedef struct ast__ast__Node ast__ast__Node;
typedef union ast__ast__NodeAs ast__ast__NodeAs;
typedef struct ast__ast__NameData ast__ast__NameData;
typedef struct ast__ast__Ty ast__ast__Ty;
#ifndef SUPER_ENUM_ast__ast__TypeKind
#define SUPER_ENUM_ast__ast__TypeKind
typedef enum { ast__ast__TypeKind_TYPE_ERROR, ast__ast__TypeKind_TYPE_BUILTIN, ast__ast__TypeKind_TYPE_POINTER, ast__ast__TypeKind_TYPE_REFERENCE, ast__ast__TypeKind_TYPE_SLICE, ast__ast__TypeKind_TYPE_ARRAY, ast__ast__TypeKind_TYPE_FUNCTION, ast__ast__TypeKind_TYPE_STRUCT, ast__ast__TypeKind_TYPE_ENUM, ast__ast__TypeKind_TYPE_GENERIC, ast__ast__TypeKind_TYPE_INSTANCE, ast__ast__TypeKind_TYPE_OPAQUE, ast__ast__TypeKind_TYPE_DYN, ast__ast__TypeKind_TYPE_NEVER, ast__ast__TypeKind_TYPE_CONST } ast__ast__TypeKind;
#endif
typedef union ast__ast__TyAs ast__ast__TyAs;
typedef struct ast__ast__LiteralData ast__ast__LiteralData;
#ifndef SUPER_ENUM_ast__ast__AttrKind
#define SUPER_ENUM_ast__ast__AttrKind
typedef enum { ast__ast__AttrKind_ATTR_INLINE, ast__ast__AttrKind_ATTR_ALWAYS_INLINE, ast__ast__AttrKind_ATTR_NOINLINE, ast__ast__AttrKind_ATTR_NORETURN, ast__ast__AttrKind_ATTR_ALIGN, ast__ast__AttrKind_ATTR_PACKED, ast__ast__AttrKind_ATTR_EXPORT, ast__ast__AttrKind_ATTR_IMPORT, ast__ast__AttrKind_ATTR_SECTION, ast__ast__AttrKind_ATTR_USED, ast__ast__AttrKind_ATTR_UNUSED, ast__ast__AttrKind_ATTR_EMIT_MACRO, ast__ast__AttrKind_ATTR_TEST, ast__ast__AttrKind_ATTR_TEST_INIT, ast__ast__AttrKind_ATTR_TEST_FREE, ast__ast__AttrKind_ATTR_C_SOURCE, ast__ast__AttrKind_ATTR_C_LINK, ast__ast__AttrKind_ATTR_COLD, ast__ast__AttrKind_ATTR_PLATFORM } ast__ast__AttrKind;
#endif
typedef struct ast__ast__Attr ast__ast__Attr;
typedef struct Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global;
#ifndef SUPER_ENUM_ast__ast__NodeKind
#define SUPER_ENUM_ast__ast__NodeKind
typedef enum { ast__ast__NodeKind_NODE_NONE_KIND, ast__ast__NodeKind_NODE_PROGRAM, ast__ast__NodeKind_NODE_IDENTIFIER, ast__ast__NodeKind_NODE_LITERAL, ast__ast__NodeKind_NODE_FUNCTION, ast__ast__NodeKind_NODE_PARAMETER, ast__ast__NodeKind_NODE_STRUCT, ast__ast__NodeKind_NODE_FIELD, ast__ast__NodeKind_NODE_ENUM, ast__ast__NodeKind_NODE_VARIANT, ast__ast__NodeKind_NODE_INTERFACE, ast__ast__NodeKind_NODE_EXTEND, ast__ast__NodeKind_NODE_TYPE_ALIAS, ast__ast__NodeKind_NODE_CONST, ast__ast__NodeKind_NODE_STATIC_ASSERT, ast__ast__NodeKind_NODE_EXTERN_BLOCK, ast__ast__NodeKind_NODE_IMPORT, ast__ast__NodeKind_NODE_GENERIC_PARAM, ast__ast__NodeKind_NODE_WHERE_PREDICATE, ast__ast__NodeKind_NODE_TYPE_PATH, ast__ast__NodeKind_NODE_POINTER_TYPE, ast__ast__NodeKind_NODE_REFERENCE_TYPE, ast__ast__NodeKind_NODE_SLICE_TYPE, ast__ast__NodeKind_NODE_ARRAY_TYPE, ast__ast__NodeKind_NODE_FUNCTION_TYPE, ast__ast__NodeKind_NODE_DYN_TYPE, ast__ast__NodeKind_NODE_BLOCK, ast__ast__NodeKind_NODE_LET, ast__ast__NodeKind_NODE_RETURN, ast__ast__NodeKind_NODE_BREAK, ast__ast__NodeKind_NODE_CONTINUE, ast__ast__NodeKind_NODE_DEFER, ast__ast__NodeKind_NODE_IF, ast__ast__NodeKind_NODE_WHILE, ast__ast__NodeKind_NODE_FOR, ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, ast__ast__NodeKind_NODE_UNARY, ast__ast__NodeKind_NODE_BINARY, ast__ast__NodeKind_NODE_ASSIGNMENT, ast__ast__NodeKind_NODE_CALL, ast__ast__NodeKind_NODE_CLOSURE, ast__ast__NodeKind_NODE_INDEX, ast__ast__NodeKind_NODE_MEMBER, ast__ast__NodeKind_NODE_CAST, ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION, ast__ast__NodeKind_NODE_MATCH, ast__ast__NodeKind_NODE_MATCH_ARM, ast__ast__NodeKind_NODE_NEW, ast__ast__NodeKind_NODE_SIZEOF, ast__ast__NodeKind_NODE_ALIGNOF, ast__ast__NodeKind_NODE_VA_EXPR, ast__ast__NodeKind_NODE_ARRAY_LITERAL, ast__ast__NodeKind_NODE_STRUCT_INITIALIZER, ast__ast__NodeKind_NODE_FIELD_INITIALIZER, ast__ast__NodeKind_NODE_PATTERN_WILDCARD, ast__ast__NodeKind_NODE_PATTERN_LITERAL, ast__ast__NodeKind_NODE_PATTERN_NAME, ast__ast__NodeKind_NODE_PATTERN_TUPLE, ast__ast__NodeKind_NODE_PATTERN_STRUCT, ast__ast__NodeKind_NODE_PATTERN_FIELD, ast__ast__NodeKind_NODE_PATTERN_RANGE, ast__ast__NodeKind_NODE_PATTERN_OR, ast__ast__NodeKind_NODE_RANGE, ast__ast__NodeKind_NODE_TUPLE, ast__ast__NodeKind_NODE_TUPLE_TYPE, ast__ast__NodeKind_NODE_KIND_COUNT } ast__ast__NodeKind;
#endif
typedef struct ast__ast__AggregateData ast__ast__AggregateData;
typedef struct ast__ast__NodeList ast__ast__NodeList;
typedef struct ast__ast__VariantData ast__ast__VariantData;
typedef struct ast__ast__FieldData ast__ast__FieldData;
typedef struct ast__ast__TyArr ast__ast__TyArr;
typedef struct ast__ast__TyInstance ast__ast__TyInstance;
typedef struct ast__ast__ProgramData ast__ast__ProgramData;
typedef struct Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global;
typedef struct ast__ast__ExtendData ast__ast__ExtendData;
typedef struct ast__ast__InterfaceData ast__ast__InterfaceData;
typedef struct Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global;
typedef struct ast__ast__DefId ast__ast__DefId;
typedef struct ast__ast__FunctionData ast__ast__FunctionData;
#ifndef SUPER_ENUM_lexer__token_type__TokenType
#define SUPER_ENUM_lexer__token_type__TokenType
typedef enum { lexer__token_type__TokenType_Identifier, lexer__token_type__TokenType_Label, lexer__token_type__TokenType_As, lexer__token_type__TokenType_Import, lexer__token_type__TokenType_Break, lexer__token_type__TokenType_Case, lexer__token_type__TokenType_Const, lexer__token_type__TokenType_Continue, lexer__token_type__TokenType_Defer, lexer__token_type__TokenType_Do, lexer__token_type__TokenType_Dyn, lexer__token_type__TokenType_Else, lexer__token_type__TokenType_Enum, lexer__token_type__TokenType_Extern, lexer__token_type__TokenType_False, lexer__token_type__TokenType_Fn, lexer__token_type__TokenType_For, lexer__token_type__TokenType_If, lexer__token_type__TokenType_Extend, lexer__token_type__TokenType_In, lexer__token_type__TokenType_Let, lexer__token_type__TokenType_Loop, lexer__token_type__TokenType_Switch, lexer__token_type__TokenType_Move, lexer__token_type__TokenType_Mut, lexer__token_type__TokenType_New, lexer__token_type__TokenType_Null, lexer__token_type__TokenType_Pub, lexer__token_type__TokenType_Sizeof, lexer__token_type__TokenType_Alignof, lexer__token_type__TokenType_Return, lexer__token_type__TokenType_SelfLower, lexer__token_type__TokenType_SelfUpper, lexer__token_type__TokenType_Struct, lexer__token_type__TokenType_Interface, lexer__token_type__TokenType_True, lexer__token_type__TokenType_Type, lexer__token_type__TokenType_Union, lexer__token_type__TokenType_Unsafe, lexer__token_type__TokenType_Where, lexer__token_type__TokenType_While, lexer__token_type__TokenType_IntegerLiteral, lexer__token_type__TokenType_FloatLiteral, lexer__token_type__TokenType_CharacterLiteral, lexer__token_type__TokenType_ByteCharacterLiteral, lexer__token_type__TokenType_StringLiteral, lexer__token_type__TokenType_RawStringLiteral, lexer__token_type__TokenType_ByteStringLiteral, lexer__token_type__TokenType_LeftBrace, lexer__token_type__TokenType_RightBrace, lexer__token_type__TokenType_LeftParen, lexer__token_type__TokenType_RightParen, lexer__token_type__TokenType_LeftBracket, lexer__token_type__TokenType_RightBracket, lexer__token_type__TokenType_Comma, lexer__token_type__TokenType_Semicolon, lexer__token_type__TokenType_Colon, lexer__token_type__TokenType_Dot, lexer__token_type__TokenType_At, lexer__token_type__TokenType_Plus, lexer__token_type__TokenType_Minus, lexer__token_type__TokenType_Star, lexer__token_type__TokenType_Slash, lexer__token_type__TokenType_Percent, lexer__token_type__TokenType_Tilde, lexer__token_type__TokenType_Bang, lexer__token_type__TokenType_Question, lexer__token_type__TokenType_EqualEqual, lexer__token_type__TokenType_BangEqual, lexer__token_type__TokenType_LessThan, lexer__token_type__TokenType_LessThanEqual, lexer__token_type__TokenType_GreaterThan, lexer__token_type__TokenType_GreaterThanEqual, lexer__token_type__TokenType_Ampersand, lexer__token_type__TokenType_Pipe, lexer__token_type__TokenType_Caret, lexer__token_type__TokenType_AmpersandAmpersand, lexer__token_type__TokenType_PipePipe, lexer__token_type__TokenType_LeftShift, lexer__token_type__TokenType_RightShift, lexer__token_type__TokenType_Equal, lexer__token_type__TokenType_PlusEqual, lexer__token_type__TokenType_MinusEqual, lexer__token_type__TokenType_StarEqual, lexer__token_type__TokenType_SlashEqual, lexer__token_type__TokenType_PercentEqual, lexer__token_type__TokenType_AmpersandEqual, lexer__token_type__TokenType_PipeEqual, lexer__token_type__TokenType_CaretEqual, lexer__token_type__TokenType_LeftShiftEqual, lexer__token_type__TokenType_RightShiftEqual, lexer__token_type__TokenType_Range, lexer__token_type__TokenType_RangeInclusive, lexer__token_type__TokenType_Ellipsis, lexer__token_type__TokenType_PathSeparator, lexer__token_type__TokenType_Arrow, lexer__token_type__TokenType_FatArrow, lexer__token_type__TokenType_Eof } lexer__token_type__TokenType;
#endif
typedef struct ast__ast__PatternRangeData ast__ast__PatternRangeData;
typedef struct ast__ast__UnaryData ast__ast__UnaryData;
typedef struct ast__ast__MemberData ast__ast__MemberData;
typedef struct ast__ast__IndexData ast__ast__IndexData;
typedef struct ast__ast__ConstData ast__ast__ConstData;
typedef struct ast__ast__SingleData ast__ast__SingleData;
typedef struct ast__ast__IfData ast__ast__IfData;
typedef struct ast__ast__CastData ast__ast__CastData;
typedef struct ast__ast__BinaryData ast__ast__BinaryData;
typedef struct ast__ast__BlockData ast__ast__BlockData;
typedef struct ast__ast__StructInitializerData ast__ast__StructInitializerData;
typedef struct ast__ast__TypePathData ast__ast__TypePathData;
typedef struct ast__ast__FieldInitializerData ast__ast__FieldInitializerData;
typedef struct ast__ast__ArrayLiteralData ast__ast__ArrayLiteralData;
typedef struct ast__ast__PatternData ast__ast__PatternData;
typedef struct ast__ast__MatchData ast__ast__MatchData;
typedef struct ast__ast__MatchArmData ast__ast__MatchArmData;
typedef struct ast__ast__ReturnData ast__ast__ReturnData;
typedef struct ast__ast__FlowData ast__ast__FlowData;
typedef struct ast__ast__LetData ast__ast__LetData;
typedef struct ast__ast__WhileData ast__ast__WhileData;
typedef struct ast__ast__ForData ast__ast__ForData;
typedef struct ast__ast__ClosureData ast__ast__ClosureData;
typedef struct Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit;
typedef struct ast__ast__ParameterData ast__ast__ParameterData;
typedef struct ast__ast__CallData ast__ast__CallData;
typedef struct ast__ast__SpecializationData ast__ast__SpecializationData;
typedef struct ast__ast__DerefUse ast__ast__DerefUse;
typedef struct ast__ast__MonoUse ast__ast__MonoUse;
typedef struct Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal;
typedef struct Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal;
typedef struct Option__usize Option__usize;
typedef struct Result__usize__usize Result__usize__usize;
typedef struct VecIter__consteval__consteval__CeVal VecIter__consteval__consteval__CeVal;
typedef struct Range__usize Range__usize;
typedef struct Slice__consteval__consteval__CeVal Slice__consteval__consteval__CeVal;
typedef struct SliceMut__consteval__consteval__CeVal SliceMut__consteval__consteval__CeVal;
typedef struct Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue;
typedef struct Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue;
typedef struct VecIter__consteval__consteval__ConstValue VecIter__consteval__consteval__ConstValue;
typedef struct Slice__consteval__consteval__ConstValue Slice__consteval__consteval__ConstValue;
typedef struct SliceMut__consteval__consteval__ConstValue SliceMut__consteval__consteval__ConstValue;
typedef struct Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global;
typedef struct Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global;
typedef struct VecIter__Vector__consteval__consteval__ConstValue__Global VecIter__Vector__consteval__consteval__ConstValue__Global;
typedef struct Slice__Vector__consteval__consteval__ConstValue__Global Slice__Vector__consteval__consteval__ConstValue__Global;
typedef struct SliceMut__Vector__consteval__consteval__ConstValue__Global SliceMut__Vector__consteval__consteval__ConstValue__Global;
typedef struct Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj;
typedef struct Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj;
typedef struct VecIter__consteval__consteval__CeObj VecIter__consteval__consteval__CeObj;
typedef struct Slice__consteval__consteval__CeObj Slice__consteval__consteval__CeObj;
typedef struct SliceMut__consteval__consteval__CeObj SliceMut__consteval__consteval__CeObj;
typedef struct Option__consteval__consteval__CePending Option__consteval__consteval__CePending;
typedef struct Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending;
typedef struct VecIter__consteval__consteval__CePending VecIter__consteval__consteval__CePending;
typedef struct Slice__consteval__consteval__CePending Slice__consteval__consteval__CePending;
typedef struct SliceMut__consteval__consteval__CePending SliceMut__consteval__consteval__CePending;
typedef struct Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit;
typedef struct MapKeys__consteval__consteval__CeCallKey MapKeys__consteval__consteval__CeCallKey;
typedef struct MapValues__consteval__consteval__CeCallHit MapValues__consteval__consteval__CeCallHit;
typedef struct Option__consteval__consteval__UFree Option__consteval__consteval__UFree;
typedef struct Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree;
typedef struct VecIter__consteval__consteval__UFree VecIter__consteval__consteval__UFree;
typedef struct Slice__consteval__consteval__UFree Slice__consteval__consteval__UFree;
typedef struct SliceMut__consteval__consteval__UFree SliceMut__consteval__consteval__UFree;
typedef struct Option__module__loader__Module Option__module__loader__Module;
typedef struct Option__ptr_module__loader__Module Option__ptr_module__loader__Module;
typedef struct VecIter__module__loader__Module VecIter__module__loader__Module;
typedef struct Slice__module__loader__Module Slice__module__loader__Module;
typedef struct SliceMut__module__loader__Module SliceMut__module__loader__Module;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Option__u32 Option__u32;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct VecIter__u32 VecIter__u32;
typedef struct Slice__u32 Slice__u32;
typedef struct SliceMut__u32 SliceMut__u32;
typedef struct Option__ast__ast__Attr Option__ast__ast__Attr;
typedef struct Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr;
typedef struct VecIter__ast__ast__Attr VecIter__ast__ast__Attr;
typedef struct Slice__ast__ast__Attr Slice__ast__ast__Attr;
typedef struct SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr;
typedef struct Option__ast__ast__Ty Option__ast__ast__Ty;
typedef struct Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty;
typedef struct VecIter__ast__ast__Ty VecIter__ast__ast__Ty;
typedef struct Slice__ast__ast__Ty Slice__ast__ast__Ty;
typedef struct SliceMut__ast__ast__Ty SliceMut__ast__ast__Ty;
typedef struct Option__ast__ast__Node Option__ast__ast__Node;
typedef struct Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node;
typedef struct VecIter__ast__ast__Node VecIter__ast__ast__Node;
typedef struct Slice__ast__ast__Node Slice__ast__ast__Node;
typedef struct SliceMut__ast__ast__Node SliceMut__ast__ast__Node;
typedef struct Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey;
typedef struct Option__ptr_u8 Option__ptr_u8;
#include "../stdlib.h"
#include "../string.h"
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../ast/ast.h"
#include "../module/loader.h"
#include "../utils/errors.h"
#include "../math.h"
#include "../__std/interfaces.h"
#include "../__std/map.h"
#include "../__std/option.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"
#include "../__std/vector.h"

#ifndef SUPER_ENUM_consteval__consteval__Flow
#define SUPER_ENUM_consteval__consteval__Flow
typedef enum { consteval__consteval__Flow_Ok, consteval__consteval__Flow_Return, consteval__consteval__Flow_Break, consteval__consteval__Flow_Continue, consteval__consteval__Flow_Bail } consteval__consteval__Flow;
#endif
typedef union consteval__consteval__ConstValueAs consteval__consteval__ConstValueAs;
typedef struct consteval__consteval__ConstValue consteval__consteval__ConstValue;
typedef struct consteval__consteval__CvPtr consteval__consteval__CvPtr;
typedef struct consteval__consteval__CvFn consteval__consteval__CvFn;
typedef union consteval__consteval__CeValAs consteval__consteval__CeValAs;
typedef struct consteval__consteval__CeVal consteval__consteval__CeVal;
typedef struct consteval__consteval__CePending consteval__consteval__CePending;
typedef struct consteval__consteval__Buf64 consteval__consteval__Buf64;
typedef struct consteval__consteval__Buf24 consteval__consteval__Buf24;
typedef struct consteval__consteval__Buf4096 consteval__consteval__Buf4096;
typedef struct consteval__consteval__LayoutEnv consteval__consteval__LayoutEnv;
typedef struct consteval__consteval__LayoutAcc consteval__consteval__LayoutAcc;
typedef struct consteval__consteval__CeObj consteval__consteval__CeObj;
typedef struct consteval__consteval__CeRecv consteval__consteval__CeRecv;
typedef struct consteval__consteval__CeLocal consteval__consteval__CeLocal;
typedef struct consteval__consteval__CeFrame consteval__consteval__CeFrame;
typedef struct consteval__consteval__CeCallKey consteval__consteval__CeCallKey;
typedef struct consteval__consteval__CeCallHit consteval__consteval__CeCallHit;
typedef struct consteval__consteval__UFree consteval__consteval__UFree;
typedef struct consteval__consteval__ConstEval consteval__consteval__ConstEval;
typedef struct consteval__consteval__Layout consteval__consteval__Layout;
typedef struct consteval__consteval__RType consteval__consteval__RType;
typedef struct consteval__consteval__RecvRes consteval__consteval__RecvRes;
typedef struct consteval__consteval__ValRes consteval__consteval__ValRes;
typedef struct consteval__consteval__ObjRes consteval__consteval__ObjRes;
typedef struct consteval__consteval__Rets consteval__consteval__Rets;
typedef struct consteval__consteval__FieldIdx consteval__consteval__FieldIdx;
typedef struct consteval__consteval__VarPos consteval__consteval__VarPos;
typedef struct consteval__consteval__OvfRes consteval__consteval__OvfRes;
typedef struct consteval__consteval__DblRes consteval__consteval__DblRes;
typedef struct Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global;
typedef struct Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global;
typedef struct Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global;
typedef struct Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global;
typedef struct Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global;
typedef struct Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global;
typedef struct Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global;
typedef struct Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit;
typedef struct Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal;
typedef struct Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal;
typedef struct VecIter__consteval__consteval__CeVal VecIter__consteval__consteval__CeVal;
typedef struct Slice__consteval__consteval__CeVal Slice__consteval__consteval__CeVal;
typedef struct SliceMut__consteval__consteval__CeVal SliceMut__consteval__consteval__CeVal;
typedef struct Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue;
typedef struct Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue;
typedef struct VecIter__consteval__consteval__ConstValue VecIter__consteval__consteval__ConstValue;
typedef struct Slice__consteval__consteval__ConstValue Slice__consteval__consteval__ConstValue;
typedef struct SliceMut__consteval__consteval__ConstValue SliceMut__consteval__consteval__ConstValue;
typedef struct Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global;
typedef struct Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global;
typedef struct VecIter__Vector__consteval__consteval__ConstValue__Global VecIter__Vector__consteval__consteval__ConstValue__Global;
typedef struct Slice__Vector__consteval__consteval__ConstValue__Global Slice__Vector__consteval__consteval__ConstValue__Global;
typedef struct SliceMut__Vector__consteval__consteval__ConstValue__Global SliceMut__Vector__consteval__consteval__ConstValue__Global;
typedef struct Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj;
typedef struct Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj;
typedef struct VecIter__consteval__consteval__CeObj VecIter__consteval__consteval__CeObj;
typedef struct Slice__consteval__consteval__CeObj Slice__consteval__consteval__CeObj;
typedef struct SliceMut__consteval__consteval__CeObj SliceMut__consteval__consteval__CeObj;
typedef struct Option__consteval__consteval__CePending Option__consteval__consteval__CePending;
typedef struct Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending;
typedef struct VecIter__consteval__consteval__CePending VecIter__consteval__consteval__CePending;
typedef struct Slice__consteval__consteval__CePending Slice__consteval__consteval__CePending;
typedef struct SliceMut__consteval__consteval__CePending SliceMut__consteval__consteval__CePending;
typedef struct Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit;
typedef struct MapKeys__consteval__consteval__CeCallKey MapKeys__consteval__consteval__CeCallKey;
typedef struct MapValues__consteval__consteval__CeCallHit MapValues__consteval__consteval__CeCallHit;
typedef struct Option__consteval__consteval__UFree Option__consteval__consteval__UFree;
typedef struct Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree;
typedef struct VecIter__consteval__consteval__UFree VecIter__consteval__consteval__UFree;
typedef struct Slice__consteval__consteval__UFree Slice__consteval__consteval__UFree;
typedef struct SliceMut__consteval__consteval__UFree SliceMut__consteval__consteval__UFree;
typedef struct Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey;

union consteval__consteval__ConstValueAs {
  int64_t i;
  double f;
};
struct consteval__consteval__ConstValue {
  uint8_t kind;
  uint32_t ty;
  consteval__consteval__ConstValueAs as_data;
};
struct consteval__consteval__CvPtr {
  uint32_t obj;
  uint32_t off;
};
struct consteval__consteval__CvFn {
  uint16_t m;
  uint32_t fn_id;
};
union consteval__consteval__CeValAs {
  int64_t i;
  double f;
  consteval__consteval__CvPtr p;
  consteval__consteval__CvFn fnv;
};
struct consteval__consteval__CeVal {
  uint8_t kind;
  uint16_t tm;
  uint32_t ty;
  consteval__consteval__CeValAs as_data;
};
struct consteval__consteval__CePending {
  uint16_t m;
  uint32_t cond;
};
struct consteval__consteval__Buf64 {
  char b[64];
};
struct consteval__consteval__Buf24 {
  char b[24];
};
struct consteval__consteval__Buf4096 {
  uint8_t b[4096];
};
struct consteval__consteval__LayoutEnv {
  const consteval__consteval__LayoutEnv *parent;
  uint16_t pmod;
  const uint32_t *params;
  uint16_t argm;
  uint32_t args[4];
  uint8_t n;
};
struct consteval__consteval__LayoutAcc {
  uint64_t size;
  uint64_t align;
  bool packed;
  bool is_union;
};
struct Vector__consteval__consteval__CeVal__Global {
  consteval__consteval__CeVal *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct consteval__consteval__CeObj {
  Vector__consteval__consteval__CeVal__Global slots;
  uint8_t dead;
  uint8_t is_enum;
  uint8_t heap;
  uint16_t dm;
  uint32_t dn;
  uint8_t nargs;
  uint16_t am[4];
  uint32_t at[4];
  uint64_t bytes;
  uint16_t em;
  uint32_t et;
  uint64_t esz;
};
struct consteval__consteval__CeRecv {
  uint16_t dm;
  uint32_t dn;
  ast__ast__BuiltinType b;
  uint8_t n;
  uint16_t am[4];
  uint32_t at[4];
};
struct consteval__consteval__CeLocal {
  uint32_t decl;
  uint32_t slot;
};
struct consteval__consteval__CeFrame {
  uint32_t env;
  consteval__consteval__CeLocal locals[96];
  uint32_t n;
  consteval__consteval__CeVal rets[8];
  uint8_t nrets;
  uint8_t returned;
  uint8_t early;
  uint16_t pmod;
  uint32_t params_g[8];
  uint16_t am[8];
  uint32_t at[8];
  uint8_t ng;
  uint32_t defers[24];
  uint8_t ndefers;
};
struct consteval__consteval__CeCallKey {
  uint16_t m;
  uint32_t fn_id;
  uint8_t nargs;
  uint8_t kinds[8];
  int64_t bits[8];
};
struct consteval__consteval__CeCallHit {
  uint8_t nrets;
  consteval__consteval__CeVal rets[8];
};
struct consteval__consteval__UFree {
  uint16_t m;
  uint32_t n;
  bool user;
};
struct Vector__Vector__consteval__consteval__ConstValue__Global__Global {
  Vector__consteval__consteval__ConstValue__Global *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__consteval__consteval__CeObj__Global {
  consteval__consteval__CeObj *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__consteval__consteval__CePending__Global {
  consteval__consteval__CePending *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global {
  consteval__consteval__CeCallKey *keys;
  consteval__consteval__CeCallHit *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__consteval__consteval__UFree__Global {
  consteval__consteval__UFree *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct consteval__consteval__ConstEval {
  module__loader__Package *pkg;
  Vector__Vector__consteval__consteval__ConstValue__Global__Global vals;
  size_t nmods;
  uint32_t depth;
  uint32_t nframes;
  uint32_t steps;
  uint32_t max_steps;
  uint64_t max_slots;
  Vector__consteval__consteval__CeObj__Global objs;
  uint64_t live_slots;
  str trap;
  Vector__consteval__consteval__CePending__Global pending;
  Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global calls;
  Vector__consteval__consteval__UFree__Global ufree;
};
struct consteval__consteval__Layout {
  bool ok;
  uint64_t size;
  uint64_t align;
};
struct consteval__consteval__RType {
  bool ok;
  uint16_t m;
  uint32_t t;
};
struct consteval__consteval__RecvRes {
  bool ok;
  consteval__consteval__CeRecv r;
};
struct consteval__consteval__ValRes {
  bool ok;
  consteval__consteval__CeVal v;
};
struct consteval__consteval__ObjRes {
  bool ok;
  uint32_t obj;
};
struct consteval__consteval__Rets {
  bool ok;
  uint8_t n;
  consteval__consteval__CeVal vals[8];
};
struct consteval__consteval__FieldIdx {
  int32_t idx;
  uint32_t field;
};
struct consteval__consteval__VarPos {
  int32_t pos;
  uint32_t enum_decl;
};
struct consteval__consteval__OvfRes {
  bool ovf;
  int64_t v;
};
struct consteval__consteval__DblRes {
  bool ok;
  double v;
};
struct Vector__consteval__consteval__ConstValue__Global {
  consteval__consteval__ConstValue *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Option__ptr_consteval__consteval__CeCallHit {
  OptionTag tag;
  union {
    struct { const consteval__consteval__CeCallHit *_0; } Some;
  } payload;
};
struct Option__consteval__consteval__CeVal {
  OptionTag tag;
  union {
    struct { consteval__consteval__CeVal _0; } Some;
  } payload;
};
struct Option__ptr_consteval__consteval__CeVal {
  OptionTag tag;
  union {
    struct { const consteval__consteval__CeVal *_0; } Some;
  } payload;
};
struct VecIter__consteval__consteval__CeVal {
  const consteval__consteval__CeVal *data;
  size_t idx;
  size_t stop;
};
struct Slice__consteval__consteval__CeVal {
  const consteval__consteval__CeVal *ptr;
  size_t len;
};
struct SliceMut__consteval__consteval__CeVal {
  consteval__consteval__CeVal *ptr;
  size_t len;
};
struct Option__consteval__consteval__ConstValue {
  OptionTag tag;
  union {
    struct { consteval__consteval__ConstValue _0; } Some;
  } payload;
};
struct Option__ptr_consteval__consteval__ConstValue {
  OptionTag tag;
  union {
    struct { const consteval__consteval__ConstValue *_0; } Some;
  } payload;
};
struct VecIter__consteval__consteval__ConstValue {
  const consteval__consteval__ConstValue *data;
  size_t idx;
  size_t stop;
};
struct Slice__consteval__consteval__ConstValue {
  const consteval__consteval__ConstValue *ptr;
  size_t len;
};
struct SliceMut__consteval__consteval__ConstValue {
  consteval__consteval__ConstValue *ptr;
  size_t len;
};
struct Option__Vector__consteval__consteval__ConstValue__Global {
  OptionTag tag;
  union {
    struct { Vector__consteval__consteval__ConstValue__Global _0; } Some;
  } payload;
};
struct Option__ptr_Vector__consteval__consteval__ConstValue__Global {
  OptionTag tag;
  union {
    struct { const Vector__consteval__consteval__ConstValue__Global *_0; } Some;
  } payload;
};
struct VecIter__Vector__consteval__consteval__ConstValue__Global {
  const Vector__consteval__consteval__ConstValue__Global *data;
  size_t idx;
  size_t stop;
};
struct Slice__Vector__consteval__consteval__ConstValue__Global {
  const Vector__consteval__consteval__ConstValue__Global *ptr;
  size_t len;
};
struct SliceMut__Vector__consteval__consteval__ConstValue__Global {
  Vector__consteval__consteval__ConstValue__Global *ptr;
  size_t len;
};
struct Option__consteval__consteval__CeObj {
  OptionTag tag;
  union {
    struct { consteval__consteval__CeObj _0; } Some;
  } payload;
};
struct Option__ptr_consteval__consteval__CeObj {
  OptionTag tag;
  union {
    struct { const consteval__consteval__CeObj *_0; } Some;
  } payload;
};
struct VecIter__consteval__consteval__CeObj {
  const consteval__consteval__CeObj *data;
  size_t idx;
  size_t stop;
};
struct Slice__consteval__consteval__CeObj {
  const consteval__consteval__CeObj *ptr;
  size_t len;
};
struct SliceMut__consteval__consteval__CeObj {
  consteval__consteval__CeObj *ptr;
  size_t len;
};
struct Option__consteval__consteval__CePending {
  OptionTag tag;
  union {
    struct { consteval__consteval__CePending _0; } Some;
  } payload;
};
struct Option__ptr_consteval__consteval__CePending {
  OptionTag tag;
  union {
    struct { const consteval__consteval__CePending *_0; } Some;
  } payload;
};
struct VecIter__consteval__consteval__CePending {
  const consteval__consteval__CePending *data;
  size_t idx;
  size_t stop;
};
struct Slice__consteval__consteval__CePending {
  const consteval__consteval__CePending *ptr;
  size_t len;
};
struct SliceMut__consteval__consteval__CePending {
  consteval__consteval__CePending *ptr;
  size_t len;
};
struct Option__consteval__consteval__CeCallHit {
  OptionTag tag;
  union {
    struct { consteval__consteval__CeCallHit _0; } Some;
  } payload;
};
struct MapKeys__consteval__consteval__CeCallKey {
  const consteval__consteval__CeCallKey *keys;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct MapValues__consteval__consteval__CeCallHit {
  const consteval__consteval__CeCallHit *vals;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct Option__consteval__consteval__UFree {
  OptionTag tag;
  union {
    struct { consteval__consteval__UFree _0; } Some;
  } payload;
};
struct Option__ptr_consteval__consteval__UFree {
  OptionTag tag;
  union {
    struct { const consteval__consteval__UFree *_0; } Some;
  } payload;
};
struct VecIter__consteval__consteval__UFree {
  const consteval__consteval__UFree *data;
  size_t idx;
  size_t stop;
};
struct Slice__consteval__consteval__UFree {
  const consteval__consteval__UFree *ptr;
  size_t len;
};
struct SliceMut__consteval__consteval__UFree {
  consteval__consteval__UFree *ptr;
  size_t len;
};
struct Option__ptr_consteval__consteval__CeCallKey {
  OptionTag tag;
  union {
    struct { const consteval__consteval__CeCallKey *_0; } Some;
  } payload;
};

void consteval__consteval__CeObj__free(consteval__consteval__CeObj *const self);
uint64_t consteval__consteval__CeCallKey__hash(const consteval__consteval__CeCallKey *const self);
bool consteval__consteval__CeCallKey__eq(const consteval__consteval__CeCallKey *const self, const consteval__consteval__CeCallKey *const other);
consteval__consteval__ConstEval consteval__consteval__ConstEval__new(module__loader__Package *const pkg, uint32_t const max_steps, uint64_t const max_mem_bytes);
consteval__consteval__Layout consteval__consteval__ConstEval__layout(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const t);
consteval__consteval__ConstValue consteval__consteval__ConstEval__eval(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const id);
str consteval__consteval__ConstEval__ce_trap_get(const consteval__consteval__ConstEval *const self);
void consteval__consteval__ConstEval__defer_assert(consteval__consteval__ConstEval *const self, uint16_t const m, uint32_t const cond);
void consteval__consteval__ConstEval__flush_asserts(consteval__consteval__ConstEval *const self, void (*const err)(void *, uint16_t, uint32_t, const char *), void *const ctx);
void consteval__consteval__ConstEval__free(consteval__consteval__ConstEval *const self);
Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__new_in(Global const alloc);
Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__consteval__consteval__CeVal__Global__len(const Vector__consteval__consteval__CeVal__Global *const self);
void Vector__consteval__consteval__CeVal__Global__reserve(Vector__consteval__consteval__CeVal__Global *const self, size_t const additional);
void Vector__consteval__consteval__CeVal__Global__push(Vector__consteval__consteval__CeVal__Global *const self, consteval__consteval__CeVal const value);
const consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__at(const Vector__consteval__consteval__CeVal__Global *const self, size_t const index);
Option__ptr_consteval__consteval__CeVal Vector__consteval__consteval__CeVal__Global__get(const Vector__consteval__consteval__CeVal__Global *const self, size_t const index);
void Vector__consteval__consteval__CeVal__Global__set(Vector__consteval__consteval__CeVal__Global *const self, size_t const index, consteval__consteval__CeVal const value);
void Vector__consteval__consteval__CeVal__Global__clear(Vector__consteval__consteval__CeVal__Global *const self);
void Vector__consteval__consteval__CeVal__Global__truncate(Vector__consteval__consteval__CeVal__Global *const self, size_t const new_len);
const consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__as_ptr(const Vector__consteval__consteval__CeVal__Global *const self);
void Vector__consteval__consteval__CeVal__Global__swap(Vector__consteval__consteval__CeVal__Global *const self, size_t const i, size_t const j);
Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__new(void);
void Vector__consteval__consteval__CeVal__Global__free(Vector__consteval__consteval__CeVal__Global *const self);
Vector__consteval__consteval__CeVal__Global Vector__consteval__consteval__CeVal__Global__default_(void);
const consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__index(const Vector__consteval__consteval__CeVal__Global *const self, size_t const i);
Slice__consteval__consteval__CeVal Vector__consteval__consteval__CeVal__Global__index_range(const Vector__consteval__consteval__CeVal__Global *const self, Range__usize const r);
consteval__consteval__CeVal *Vector__consteval__consteval__CeVal__Global__index_mut(Vector__consteval__consteval__CeVal__Global *const self, size_t const i);
SliceMut__consteval__consteval__CeVal Vector__consteval__consteval__CeVal__Global__index_range_mut(Vector__consteval__consteval__CeVal__Global *const self, Range__usize const r);
Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__new_in(Global const alloc);
Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__consteval__consteval__ConstValue__Global__len(const Vector__consteval__consteval__ConstValue__Global *const self);
void Vector__consteval__consteval__ConstValue__Global__reserve(Vector__consteval__consteval__ConstValue__Global *const self, size_t const additional);
void Vector__consteval__consteval__ConstValue__Global__push(Vector__consteval__consteval__ConstValue__Global *const self, consteval__consteval__ConstValue const value);
const consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__at(const Vector__consteval__consteval__ConstValue__Global *const self, size_t const index);
Option__ptr_consteval__consteval__ConstValue Vector__consteval__consteval__ConstValue__Global__get(const Vector__consteval__consteval__ConstValue__Global *const self, size_t const index);
void Vector__consteval__consteval__ConstValue__Global__set(Vector__consteval__consteval__ConstValue__Global *const self, size_t const index, consteval__consteval__ConstValue const value);
void Vector__consteval__consteval__ConstValue__Global__clear(Vector__consteval__consteval__ConstValue__Global *const self);
void Vector__consteval__consteval__ConstValue__Global__truncate(Vector__consteval__consteval__ConstValue__Global *const self, size_t const new_len);
const consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__as_ptr(const Vector__consteval__consteval__ConstValue__Global *const self);
void Vector__consteval__consteval__ConstValue__Global__swap(Vector__consteval__consteval__ConstValue__Global *const self, size_t const i, size_t const j);
Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__new(void);
void Vector__consteval__consteval__ConstValue__Global__free(Vector__consteval__consteval__ConstValue__Global *const self);
Vector__consteval__consteval__ConstValue__Global Vector__consteval__consteval__ConstValue__Global__default_(void);
const consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__index(const Vector__consteval__consteval__ConstValue__Global *const self, size_t const i);
Slice__consteval__consteval__ConstValue Vector__consteval__consteval__ConstValue__Global__index_range(const Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r);
consteval__consteval__ConstValue *Vector__consteval__consteval__ConstValue__Global__index_mut(Vector__consteval__consteval__ConstValue__Global *const self, size_t const i);
SliceMut__consteval__consteval__ConstValue Vector__consteval__consteval__ConstValue__Global__index_range_mut(Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r);
Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__new_in(Global const alloc);
Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__Vector__consteval__consteval__ConstValue__Global__Global__len(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__reserve(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const additional);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__push(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, Vector__consteval__consteval__ConstValue__Global value);
const Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__at(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const index);
Option__ptr_Vector__consteval__consteval__ConstValue__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__get(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const index);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__set(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const index, Vector__consteval__consteval__ConstValue__Global value);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__clear(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__truncate(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const new_len);
const Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__as_ptr(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__swap(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const i, size_t const j);
Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__new(void);
void Vector__Vector__consteval__consteval__ConstValue__Global__Global__free(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self);
Vector__Vector__consteval__consteval__ConstValue__Global__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__default_(void);
const Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__index(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const i);
Slice__Vector__consteval__consteval__ConstValue__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_range(const Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, Range__usize const r);
Vector__consteval__consteval__ConstValue__Global *Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_mut(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, size_t const i);
SliceMut__Vector__consteval__consteval__ConstValue__Global Vector__Vector__consteval__consteval__ConstValue__Global__Global__index_range_mut(Vector__Vector__consteval__consteval__ConstValue__Global__Global *const self, Range__usize const r);
Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__new_in(Global const alloc);
Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__consteval__consteval__CeObj__Global__len(const Vector__consteval__consteval__CeObj__Global *const self);
void Vector__consteval__consteval__CeObj__Global__reserve(Vector__consteval__consteval__CeObj__Global *const self, size_t const additional);
void Vector__consteval__consteval__CeObj__Global__push(Vector__consteval__consteval__CeObj__Global *const self, consteval__consteval__CeObj value);
const consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__at(const Vector__consteval__consteval__CeObj__Global *const self, size_t const index);
Option__ptr_consteval__consteval__CeObj Vector__consteval__consteval__CeObj__Global__get(const Vector__consteval__consteval__CeObj__Global *const self, size_t const index);
void Vector__consteval__consteval__CeObj__Global__set(Vector__consteval__consteval__CeObj__Global *const self, size_t const index, consteval__consteval__CeObj value);
void Vector__consteval__consteval__CeObj__Global__clear(Vector__consteval__consteval__CeObj__Global *const self);
void Vector__consteval__consteval__CeObj__Global__truncate(Vector__consteval__consteval__CeObj__Global *const self, size_t const new_len);
const consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__as_ptr(const Vector__consteval__consteval__CeObj__Global *const self);
void Vector__consteval__consteval__CeObj__Global__swap(Vector__consteval__consteval__CeObj__Global *const self, size_t const i, size_t const j);
Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__new(void);
void Vector__consteval__consteval__CeObj__Global__free(Vector__consteval__consteval__CeObj__Global *const self);
Vector__consteval__consteval__CeObj__Global Vector__consteval__consteval__CeObj__Global__default_(void);
const consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__index(const Vector__consteval__consteval__CeObj__Global *const self, size_t const i);
Slice__consteval__consteval__CeObj Vector__consteval__consteval__CeObj__Global__index_range(const Vector__consteval__consteval__CeObj__Global *const self, Range__usize const r);
consteval__consteval__CeObj *Vector__consteval__consteval__CeObj__Global__index_mut(Vector__consteval__consteval__CeObj__Global *const self, size_t const i);
SliceMut__consteval__consteval__CeObj Vector__consteval__consteval__CeObj__Global__index_range_mut(Vector__consteval__consteval__CeObj__Global *const self, Range__usize const r);
Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__new_in(Global const alloc);
Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__consteval__consteval__CePending__Global__len(const Vector__consteval__consteval__CePending__Global *const self);
void Vector__consteval__consteval__CePending__Global__reserve(Vector__consteval__consteval__CePending__Global *const self, size_t const additional);
void Vector__consteval__consteval__CePending__Global__push(Vector__consteval__consteval__CePending__Global *const self, consteval__consteval__CePending const value);
const consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__at(const Vector__consteval__consteval__CePending__Global *const self, size_t const index);
Option__ptr_consteval__consteval__CePending Vector__consteval__consteval__CePending__Global__get(const Vector__consteval__consteval__CePending__Global *const self, size_t const index);
void Vector__consteval__consteval__CePending__Global__set(Vector__consteval__consteval__CePending__Global *const self, size_t const index, consteval__consteval__CePending const value);
void Vector__consteval__consteval__CePending__Global__clear(Vector__consteval__consteval__CePending__Global *const self);
void Vector__consteval__consteval__CePending__Global__truncate(Vector__consteval__consteval__CePending__Global *const self, size_t const new_len);
const consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__as_ptr(const Vector__consteval__consteval__CePending__Global *const self);
void Vector__consteval__consteval__CePending__Global__swap(Vector__consteval__consteval__CePending__Global *const self, size_t const i, size_t const j);
Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__new(void);
void Vector__consteval__consteval__CePending__Global__free(Vector__consteval__consteval__CePending__Global *const self);
Vector__consteval__consteval__CePending__Global Vector__consteval__consteval__CePending__Global__default_(void);
const consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__index(const Vector__consteval__consteval__CePending__Global *const self, size_t const i);
Slice__consteval__consteval__CePending Vector__consteval__consteval__CePending__Global__index_range(const Vector__consteval__consteval__CePending__Global *const self, Range__usize const r);
consteval__consteval__CePending *Vector__consteval__consteval__CePending__Global__index_mut(Vector__consteval__consteval__CePending__Global *const self, size_t const i);
SliceMut__consteval__consteval__CePending Vector__consteval__consteval__CePending__Global__index_range_mut(Vector__consteval__consteval__CePending__Global *const self, Range__usize const r);
Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__new_in(Global const alloc);
size_t Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__len(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self);
bool Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__is_empty(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self);
void Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__insert(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, consteval__consteval__CeCallKey const key, consteval__consteval__CeCallHit const value);
Option__ptr_consteval__consteval__CeCallHit Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__get(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key);
bool Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__contains_key(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key);
Option__consteval__consteval__CeCallHit Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__remove(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self, const consteval__consteval__CeCallKey *const key);
Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__new(void);
void Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__free(Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self);
MapKeys__consteval__consteval__CeCallKey Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global__keys(const Map__consteval__consteval__CeCallKey__consteval__consteval__CeCallHit__Global *const self);
Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__new_in(Global const alloc);
Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__consteval__consteval__UFree__Global__len(const Vector__consteval__consteval__UFree__Global *const self);
void Vector__consteval__consteval__UFree__Global__reserve(Vector__consteval__consteval__UFree__Global *const self, size_t const additional);
void Vector__consteval__consteval__UFree__Global__push(Vector__consteval__consteval__UFree__Global *const self, consteval__consteval__UFree const value);
const consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__at(const Vector__consteval__consteval__UFree__Global *const self, size_t const index);
Option__ptr_consteval__consteval__UFree Vector__consteval__consteval__UFree__Global__get(const Vector__consteval__consteval__UFree__Global *const self, size_t const index);
void Vector__consteval__consteval__UFree__Global__set(Vector__consteval__consteval__UFree__Global *const self, size_t const index, consteval__consteval__UFree const value);
void Vector__consteval__consteval__UFree__Global__clear(Vector__consteval__consteval__UFree__Global *const self);
void Vector__consteval__consteval__UFree__Global__truncate(Vector__consteval__consteval__UFree__Global *const self, size_t const new_len);
const consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__as_ptr(const Vector__consteval__consteval__UFree__Global *const self);
void Vector__consteval__consteval__UFree__Global__swap(Vector__consteval__consteval__UFree__Global *const self, size_t const i, size_t const j);
Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__new(void);
void Vector__consteval__consteval__UFree__Global__free(Vector__consteval__consteval__UFree__Global *const self);
Vector__consteval__consteval__UFree__Global Vector__consteval__consteval__UFree__Global__default_(void);
const consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__index(const Vector__consteval__consteval__UFree__Global *const self, size_t const i);
Slice__consteval__consteval__UFree Vector__consteval__consteval__UFree__Global__index_range(const Vector__consteval__consteval__UFree__Global *const self, Range__usize const r);
consteval__consteval__UFree *Vector__consteval__consteval__UFree__Global__index_mut(Vector__consteval__consteval__UFree__Global *const self, size_t const i);
SliceMut__consteval__consteval__UFree Vector__consteval__consteval__UFree__Global__index_range_mut(Vector__consteval__consteval__UFree__Global *const self, Range__usize const r);
Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit__some(const consteval__consteval__CeCallHit *const value);
Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit__none(void);
bool Option__ptr_consteval__consteval__CeCallHit__is_some(const Option__ptr_consteval__consteval__CeCallHit *const self);
bool Option__ptr_consteval__consteval__CeCallHit__is_none(const Option__ptr_consteval__consteval__CeCallHit *const self);
Option__ptr_consteval__consteval__CeCallHit Option__ptr_consteval__consteval__CeCallHit__default_(void);
Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal__some(consteval__consteval__CeVal const value);
Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal__none(void);
bool Option__consteval__consteval__CeVal__is_some(const Option__consteval__consteval__CeVal *const self);
bool Option__consteval__consteval__CeVal__is_none(const Option__consteval__consteval__CeVal *const self);
Option__consteval__consteval__CeVal Option__consteval__consteval__CeVal__default_(void);
Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal__some(const consteval__consteval__CeVal *const value);
Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal__none(void);
bool Option__ptr_consteval__consteval__CeVal__is_some(const Option__ptr_consteval__consteval__CeVal *const self);
bool Option__ptr_consteval__consteval__CeVal__is_none(const Option__ptr_consteval__consteval__CeVal *const self);
Option__ptr_consteval__consteval__CeVal Option__ptr_consteval__consteval__CeVal__default_(void);
Option__ptr_consteval__consteval__CeVal VecIter__consteval__consteval__CeVal__next(VecIter__consteval__consteval__CeVal *const self);
size_t Slice__consteval__consteval__CeVal__len(const Slice__consteval__consteval__CeVal *const self);
const consteval__consteval__CeVal *Slice__consteval__consteval__CeVal__as_ptr(const Slice__consteval__consteval__CeVal *const self);
const consteval__consteval__CeVal *Slice__consteval__consteval__CeVal__index(const Slice__consteval__consteval__CeVal *const self, size_t const i);
Slice__consteval__consteval__CeVal Slice__consteval__consteval__CeVal__index_range(const Slice__consteval__consteval__CeVal *const self, Range__usize const r);
size_t SliceMut__consteval__consteval__CeVal__len(const SliceMut__consteval__consteval__CeVal *const self);
consteval__consteval__CeVal *SliceMut__consteval__consteval__CeVal__as_mut_ptr(const SliceMut__consteval__consteval__CeVal *const self);
const consteval__consteval__CeVal *SliceMut__consteval__consteval__CeVal__index(const SliceMut__consteval__consteval__CeVal *const self, size_t const i);
Slice__consteval__consteval__CeVal SliceMut__consteval__consteval__CeVal__index_range(const SliceMut__consteval__consteval__CeVal *const self, Range__usize const r);
consteval__consteval__CeVal *SliceMut__consteval__consteval__CeVal__index_mut(SliceMut__consteval__consteval__CeVal *const self, size_t const i);
SliceMut__consteval__consteval__CeVal SliceMut__consteval__consteval__CeVal__index_range_mut(SliceMut__consteval__consteval__CeVal *const self, Range__usize const r);
Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue__some(consteval__consteval__ConstValue const value);
Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue__none(void);
bool Option__consteval__consteval__ConstValue__is_some(const Option__consteval__consteval__ConstValue *const self);
bool Option__consteval__consteval__ConstValue__is_none(const Option__consteval__consteval__ConstValue *const self);
Option__consteval__consteval__ConstValue Option__consteval__consteval__ConstValue__default_(void);
Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue__some(const consteval__consteval__ConstValue *const value);
Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue__none(void);
bool Option__ptr_consteval__consteval__ConstValue__is_some(const Option__ptr_consteval__consteval__ConstValue *const self);
bool Option__ptr_consteval__consteval__ConstValue__is_none(const Option__ptr_consteval__consteval__ConstValue *const self);
Option__ptr_consteval__consteval__ConstValue Option__ptr_consteval__consteval__ConstValue__default_(void);
Option__ptr_consteval__consteval__ConstValue VecIter__consteval__consteval__ConstValue__next(VecIter__consteval__consteval__ConstValue *const self);
size_t Slice__consteval__consteval__ConstValue__len(const Slice__consteval__consteval__ConstValue *const self);
const consteval__consteval__ConstValue *Slice__consteval__consteval__ConstValue__as_ptr(const Slice__consteval__consteval__ConstValue *const self);
const consteval__consteval__ConstValue *Slice__consteval__consteval__ConstValue__index(const Slice__consteval__consteval__ConstValue *const self, size_t const i);
Slice__consteval__consteval__ConstValue Slice__consteval__consteval__ConstValue__index_range(const Slice__consteval__consteval__ConstValue *const self, Range__usize const r);
size_t SliceMut__consteval__consteval__ConstValue__len(const SliceMut__consteval__consteval__ConstValue *const self);
consteval__consteval__ConstValue *SliceMut__consteval__consteval__ConstValue__as_mut_ptr(const SliceMut__consteval__consteval__ConstValue *const self);
const consteval__consteval__ConstValue *SliceMut__consteval__consteval__ConstValue__index(const SliceMut__consteval__consteval__ConstValue *const self, size_t const i);
Slice__consteval__consteval__ConstValue SliceMut__consteval__consteval__ConstValue__index_range(const SliceMut__consteval__consteval__ConstValue *const self, Range__usize const r);
consteval__consteval__ConstValue *SliceMut__consteval__consteval__ConstValue__index_mut(SliceMut__consteval__consteval__ConstValue *const self, size_t const i);
SliceMut__consteval__consteval__ConstValue SliceMut__consteval__consteval__ConstValue__index_range_mut(SliceMut__consteval__consteval__ConstValue *const self, Range__usize const r);
Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global__some(Vector__consteval__consteval__ConstValue__Global value);
Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global__none(void);
bool Option__Vector__consteval__consteval__ConstValue__Global__is_some(const Option__Vector__consteval__consteval__ConstValue__Global *const self);
bool Option__Vector__consteval__consteval__ConstValue__Global__is_none(const Option__Vector__consteval__consteval__ConstValue__Global *const self);
Option__Vector__consteval__consteval__ConstValue__Global Option__Vector__consteval__consteval__ConstValue__Global__default_(void);
void Option__Vector__consteval__consteval__ConstValue__Global__free(Option__Vector__consteval__consteval__ConstValue__Global *const self);
Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global__some(const Vector__consteval__consteval__ConstValue__Global *const value);
Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global__none(void);
bool Option__ptr_Vector__consteval__consteval__ConstValue__Global__is_some(const Option__ptr_Vector__consteval__consteval__ConstValue__Global *const self);
bool Option__ptr_Vector__consteval__consteval__ConstValue__Global__is_none(const Option__ptr_Vector__consteval__consteval__ConstValue__Global *const self);
Option__ptr_Vector__consteval__consteval__ConstValue__Global Option__ptr_Vector__consteval__consteval__ConstValue__Global__default_(void);
Option__ptr_Vector__consteval__consteval__ConstValue__Global VecIter__Vector__consteval__consteval__ConstValue__Global__next(VecIter__Vector__consteval__consteval__ConstValue__Global *const self);
size_t Slice__Vector__consteval__consteval__ConstValue__Global__len(const Slice__Vector__consteval__consteval__ConstValue__Global *const self);
const Vector__consteval__consteval__ConstValue__Global *Slice__Vector__consteval__consteval__ConstValue__Global__as_ptr(const Slice__Vector__consteval__consteval__ConstValue__Global *const self);
const Vector__consteval__consteval__ConstValue__Global *Slice__Vector__consteval__consteval__ConstValue__Global__index(const Slice__Vector__consteval__consteval__ConstValue__Global *const self, size_t const i);
Slice__Vector__consteval__consteval__ConstValue__Global Slice__Vector__consteval__consteval__ConstValue__Global__index_range(const Slice__Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r);
size_t SliceMut__Vector__consteval__consteval__ConstValue__Global__len(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self);
Vector__consteval__consteval__ConstValue__Global *SliceMut__Vector__consteval__consteval__ConstValue__Global__as_mut_ptr(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self);
const Vector__consteval__consteval__ConstValue__Global *SliceMut__Vector__consteval__consteval__ConstValue__Global__index(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, size_t const i);
Slice__Vector__consteval__consteval__ConstValue__Global SliceMut__Vector__consteval__consteval__ConstValue__Global__index_range(const SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r);
Vector__consteval__consteval__ConstValue__Global *SliceMut__Vector__consteval__consteval__ConstValue__Global__index_mut(SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, size_t const i);
SliceMut__Vector__consteval__consteval__ConstValue__Global SliceMut__Vector__consteval__consteval__ConstValue__Global__index_range_mut(SliceMut__Vector__consteval__consteval__ConstValue__Global *const self, Range__usize const r);
Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj__some(consteval__consteval__CeObj value);
Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj__none(void);
bool Option__consteval__consteval__CeObj__is_some(const Option__consteval__consteval__CeObj *const self);
bool Option__consteval__consteval__CeObj__is_none(const Option__consteval__consteval__CeObj *const self);
Option__consteval__consteval__CeObj Option__consteval__consteval__CeObj__default_(void);
void Option__consteval__consteval__CeObj__free(Option__consteval__consteval__CeObj *const self);
Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj__some(const consteval__consteval__CeObj *const value);
Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj__none(void);
bool Option__ptr_consteval__consteval__CeObj__is_some(const Option__ptr_consteval__consteval__CeObj *const self);
bool Option__ptr_consteval__consteval__CeObj__is_none(const Option__ptr_consteval__consteval__CeObj *const self);
Option__ptr_consteval__consteval__CeObj Option__ptr_consteval__consteval__CeObj__default_(void);
Option__ptr_consteval__consteval__CeObj VecIter__consteval__consteval__CeObj__next(VecIter__consteval__consteval__CeObj *const self);
size_t Slice__consteval__consteval__CeObj__len(const Slice__consteval__consteval__CeObj *const self);
const consteval__consteval__CeObj *Slice__consteval__consteval__CeObj__as_ptr(const Slice__consteval__consteval__CeObj *const self);
const consteval__consteval__CeObj *Slice__consteval__consteval__CeObj__index(const Slice__consteval__consteval__CeObj *const self, size_t const i);
Slice__consteval__consteval__CeObj Slice__consteval__consteval__CeObj__index_range(const Slice__consteval__consteval__CeObj *const self, Range__usize const r);
size_t SliceMut__consteval__consteval__CeObj__len(const SliceMut__consteval__consteval__CeObj *const self);
consteval__consteval__CeObj *SliceMut__consteval__consteval__CeObj__as_mut_ptr(const SliceMut__consteval__consteval__CeObj *const self);
const consteval__consteval__CeObj *SliceMut__consteval__consteval__CeObj__index(const SliceMut__consteval__consteval__CeObj *const self, size_t const i);
Slice__consteval__consteval__CeObj SliceMut__consteval__consteval__CeObj__index_range(const SliceMut__consteval__consteval__CeObj *const self, Range__usize const r);
consteval__consteval__CeObj *SliceMut__consteval__consteval__CeObj__index_mut(SliceMut__consteval__consteval__CeObj *const self, size_t const i);
SliceMut__consteval__consteval__CeObj SliceMut__consteval__consteval__CeObj__index_range_mut(SliceMut__consteval__consteval__CeObj *const self, Range__usize const r);
Option__consteval__consteval__CePending Option__consteval__consteval__CePending__some(consteval__consteval__CePending const value);
Option__consteval__consteval__CePending Option__consteval__consteval__CePending__none(void);
bool Option__consteval__consteval__CePending__is_some(const Option__consteval__consteval__CePending *const self);
bool Option__consteval__consteval__CePending__is_none(const Option__consteval__consteval__CePending *const self);
Option__consteval__consteval__CePending Option__consteval__consteval__CePending__default_(void);
Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending__some(const consteval__consteval__CePending *const value);
Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending__none(void);
bool Option__ptr_consteval__consteval__CePending__is_some(const Option__ptr_consteval__consteval__CePending *const self);
bool Option__ptr_consteval__consteval__CePending__is_none(const Option__ptr_consteval__consteval__CePending *const self);
Option__ptr_consteval__consteval__CePending Option__ptr_consteval__consteval__CePending__default_(void);
Option__ptr_consteval__consteval__CePending VecIter__consteval__consteval__CePending__next(VecIter__consteval__consteval__CePending *const self);
size_t Slice__consteval__consteval__CePending__len(const Slice__consteval__consteval__CePending *const self);
const consteval__consteval__CePending *Slice__consteval__consteval__CePending__as_ptr(const Slice__consteval__consteval__CePending *const self);
const consteval__consteval__CePending *Slice__consteval__consteval__CePending__index(const Slice__consteval__consteval__CePending *const self, size_t const i);
Slice__consteval__consteval__CePending Slice__consteval__consteval__CePending__index_range(const Slice__consteval__consteval__CePending *const self, Range__usize const r);
size_t SliceMut__consteval__consteval__CePending__len(const SliceMut__consteval__consteval__CePending *const self);
consteval__consteval__CePending *SliceMut__consteval__consteval__CePending__as_mut_ptr(const SliceMut__consteval__consteval__CePending *const self);
const consteval__consteval__CePending *SliceMut__consteval__consteval__CePending__index(const SliceMut__consteval__consteval__CePending *const self, size_t const i);
Slice__consteval__consteval__CePending SliceMut__consteval__consteval__CePending__index_range(const SliceMut__consteval__consteval__CePending *const self, Range__usize const r);
consteval__consteval__CePending *SliceMut__consteval__consteval__CePending__index_mut(SliceMut__consteval__consteval__CePending *const self, size_t const i);
SliceMut__consteval__consteval__CePending SliceMut__consteval__consteval__CePending__index_range_mut(SliceMut__consteval__consteval__CePending *const self, Range__usize const r);
Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit__some(consteval__consteval__CeCallHit const value);
Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit__none(void);
bool Option__consteval__consteval__CeCallHit__is_some(const Option__consteval__consteval__CeCallHit *const self);
bool Option__consteval__consteval__CeCallHit__is_none(const Option__consteval__consteval__CeCallHit *const self);
Option__consteval__consteval__CeCallHit Option__consteval__consteval__CeCallHit__default_(void);
Option__ptr_consteval__consteval__CeCallKey MapKeys__consteval__consteval__CeCallKey__next(MapKeys__consteval__consteval__CeCallKey *const self);
Option__ptr_consteval__consteval__CeCallHit MapValues__consteval__consteval__CeCallHit__next(MapValues__consteval__consteval__CeCallHit *const self);
Option__consteval__consteval__UFree Option__consteval__consteval__UFree__some(consteval__consteval__UFree const value);
Option__consteval__consteval__UFree Option__consteval__consteval__UFree__none(void);
bool Option__consteval__consteval__UFree__is_some(const Option__consteval__consteval__UFree *const self);
bool Option__consteval__consteval__UFree__is_none(const Option__consteval__consteval__UFree *const self);
Option__consteval__consteval__UFree Option__consteval__consteval__UFree__default_(void);
Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree__some(const consteval__consteval__UFree *const value);
Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree__none(void);
bool Option__ptr_consteval__consteval__UFree__is_some(const Option__ptr_consteval__consteval__UFree *const self);
bool Option__ptr_consteval__consteval__UFree__is_none(const Option__ptr_consteval__consteval__UFree *const self);
Option__ptr_consteval__consteval__UFree Option__ptr_consteval__consteval__UFree__default_(void);
Option__ptr_consteval__consteval__UFree VecIter__consteval__consteval__UFree__next(VecIter__consteval__consteval__UFree *const self);
size_t Slice__consteval__consteval__UFree__len(const Slice__consteval__consteval__UFree *const self);
const consteval__consteval__UFree *Slice__consteval__consteval__UFree__as_ptr(const Slice__consteval__consteval__UFree *const self);
const consteval__consteval__UFree *Slice__consteval__consteval__UFree__index(const Slice__consteval__consteval__UFree *const self, size_t const i);
Slice__consteval__consteval__UFree Slice__consteval__consteval__UFree__index_range(const Slice__consteval__consteval__UFree *const self, Range__usize const r);
size_t SliceMut__consteval__consteval__UFree__len(const SliceMut__consteval__consteval__UFree *const self);
consteval__consteval__UFree *SliceMut__consteval__consteval__UFree__as_mut_ptr(const SliceMut__consteval__consteval__UFree *const self);
const consteval__consteval__UFree *SliceMut__consteval__consteval__UFree__index(const SliceMut__consteval__consteval__UFree *const self, size_t const i);
Slice__consteval__consteval__UFree SliceMut__consteval__consteval__UFree__index_range(const SliceMut__consteval__consteval__UFree *const self, Range__usize const r);
consteval__consteval__UFree *SliceMut__consteval__consteval__UFree__index_mut(SliceMut__consteval__consteval__UFree *const self, size_t const i);
SliceMut__consteval__consteval__UFree SliceMut__consteval__consteval__UFree__index_range_mut(SliceMut__consteval__consteval__UFree *const self, Range__usize const r);
Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey__some(const consteval__consteval__CeCallKey *const value);
Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey__none(void);
bool Option__ptr_consteval__consteval__CeCallKey__is_some(const Option__ptr_consteval__consteval__CeCallKey *const self);
bool Option__ptr_consteval__consteval__CeCallKey__is_none(const Option__ptr_consteval__consteval__CeCallKey *const self);
Option__ptr_consteval__consteval__CeCallKey Option__ptr_consteval__consteval__CeCallKey__default_(void);

__attribute__((unused)) static const int32_t consteval__consteval__CE_MAX_DEPTH = 32;
__attribute__((unused)) static const uint32_t consteval__consteval__CE_DEFAULT_STEPS = 2097152U;
__attribute__((unused)) static const uint64_t consteval__consteval__CE_DEFAULT_SLOTS = 4194304ULL;
__attribute__((unused)) static const uint32_t consteval__consteval__CE_MAX_FRAMES = 48U;
__attribute__((unused)) static const uint32_t consteval__consteval__CE_MAX_LOCALS = 96U;
__attribute__((unused)) static const uint8_t consteval__consteval__CE_MAX_DEFERS = 24U;
__attribute__((unused)) static const uint32_t consteval__consteval__CE_MAX_OBJS = 65536U;
__attribute__((unused)) static const size_t consteval__consteval__CE_CALLS_MAX = 65536ULL;
__attribute__((unused)) static const uint8_t consteval__consteval__CONST_NONE = 0U;
__attribute__((unused)) static const uint8_t consteval__consteval__CONST_INT = 1U;
__attribute__((unused)) static const uint8_t consteval__consteval__CONST_BOOL = 2U;
__attribute__((unused)) static const uint8_t consteval__consteval__CONST_FLOAT = 3U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_NIL_K = 0U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_INT = 1U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_BOOL = 2U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_FLOAT = 3U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_PTR = 4U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_AGG = 5U;
__attribute__((unused)) static const uint8_t consteval__consteval__CV_FN = 6U;
__attribute__((unused)) static const int64_t consteval__consteval__I64_MIN = (-9223372036854775807ll - 1);
__attribute__((unused)) static const int64_t consteval__consteval__I64_MAX = 9223372036854775807LL;
__attribute__((unused)) static const uint64_t consteval__consteval__U64_MAX = 0xFFFFFFFFFFFFFFFFULL;
__attribute__((unused)) static const double consteval__consteval__F64_MAX = 1.7976931348623157e308;

#endif
