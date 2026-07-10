#ifndef SUPER_AST__AST_H
#define SUPER_AST__AST_H

#include "../super_rt.h"
typedef struct lexer__token__Span lexer__token__Span;
#ifndef SUPER_ENUM_lexer__token_type__TokenType
#define SUPER_ENUM_lexer__token_type__TokenType
typedef enum { lexer__token_type__TokenType_Identifier, lexer__token_type__TokenType_Label, lexer__token_type__TokenType_As, lexer__token_type__TokenType_Import, lexer__token_type__TokenType_Break, lexer__token_type__TokenType_Case, lexer__token_type__TokenType_Const, lexer__token_type__TokenType_Continue, lexer__token_type__TokenType_Defer, lexer__token_type__TokenType_Do, lexer__token_type__TokenType_Dyn, lexer__token_type__TokenType_Else, lexer__token_type__TokenType_Enum, lexer__token_type__TokenType_Extern, lexer__token_type__TokenType_False, lexer__token_type__TokenType_Fn, lexer__token_type__TokenType_For, lexer__token_type__TokenType_If, lexer__token_type__TokenType_Extend, lexer__token_type__TokenType_In, lexer__token_type__TokenType_Let, lexer__token_type__TokenType_Loop, lexer__token_type__TokenType_Switch, lexer__token_type__TokenType_Move, lexer__token_type__TokenType_Mut, lexer__token_type__TokenType_New, lexer__token_type__TokenType_Null, lexer__token_type__TokenType_Pub, lexer__token_type__TokenType_Sizeof, lexer__token_type__TokenType_Alignof, lexer__token_type__TokenType_Return, lexer__token_type__TokenType_SelfLower, lexer__token_type__TokenType_SelfUpper, lexer__token_type__TokenType_Struct, lexer__token_type__TokenType_Interface, lexer__token_type__TokenType_True, lexer__token_type__TokenType_Type, lexer__token_type__TokenType_Union, lexer__token_type__TokenType_Unsafe, lexer__token_type__TokenType_Where, lexer__token_type__TokenType_While, lexer__token_type__TokenType_IntegerLiteral, lexer__token_type__TokenType_FloatLiteral, lexer__token_type__TokenType_CharacterLiteral, lexer__token_type__TokenType_ByteCharacterLiteral, lexer__token_type__TokenType_StringLiteral, lexer__token_type__TokenType_RawStringLiteral, lexer__token_type__TokenType_ByteStringLiteral, lexer__token_type__TokenType_LeftBrace, lexer__token_type__TokenType_RightBrace, lexer__token_type__TokenType_LeftParen, lexer__token_type__TokenType_RightParen, lexer__token_type__TokenType_LeftBracket, lexer__token_type__TokenType_RightBracket, lexer__token_type__TokenType_Comma, lexer__token_type__TokenType_Semicolon, lexer__token_type__TokenType_Colon, lexer__token_type__TokenType_Dot, lexer__token_type__TokenType_At, lexer__token_type__TokenType_Plus, lexer__token_type__TokenType_Minus, lexer__token_type__TokenType_Star, lexer__token_type__TokenType_Slash, lexer__token_type__TokenType_Percent, lexer__token_type__TokenType_Tilde, lexer__token_type__TokenType_Bang, lexer__token_type__TokenType_Question, lexer__token_type__TokenType_EqualEqual, lexer__token_type__TokenType_BangEqual, lexer__token_type__TokenType_LessThan, lexer__token_type__TokenType_LessThanEqual, lexer__token_type__TokenType_GreaterThan, lexer__token_type__TokenType_GreaterThanEqual, lexer__token_type__TokenType_Ampersand, lexer__token_type__TokenType_Pipe, lexer__token_type__TokenType_Caret, lexer__token_type__TokenType_AmpersandAmpersand, lexer__token_type__TokenType_PipePipe, lexer__token_type__TokenType_LeftShift, lexer__token_type__TokenType_RightShift, lexer__token_type__TokenType_Equal, lexer__token_type__TokenType_PlusEqual, lexer__token_type__TokenType_MinusEqual, lexer__token_type__TokenType_StarEqual, lexer__token_type__TokenType_SlashEqual, lexer__token_type__TokenType_PercentEqual, lexer__token_type__TokenType_AmpersandEqual, lexer__token_type__TokenType_PipeEqual, lexer__token_type__TokenType_CaretEqual, lexer__token_type__TokenType_LeftShiftEqual, lexer__token_type__TokenType_RightShiftEqual, lexer__token_type__TokenType_Range, lexer__token_type__TokenType_RangeInclusive, lexer__token_type__TokenType_Ellipsis, lexer__token_type__TokenType_PathSeparator, lexer__token_type__TokenType_Arrow, lexer__token_type__TokenType_FatArrow, lexer__token_type__TokenType_Eof } lexer__token_type__TokenType;
#endif
typedef struct Global Global;
typedef struct Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global;
typedef struct Vector__u32__Global Vector__u32__Global;
typedef struct Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global;
typedef struct Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global;
typedef struct Map__ast__ast__Ty__u32__Global Map__ast__ast__Ty__u32__Global;
typedef struct Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global;
typedef struct Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global;
typedef struct Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global;
typedef struct Map__ast__ast__TyInstance__u32__Global Map__ast__ast__TyInstance__u32__Global;
typedef struct Map__ast__ast__MethodInst__u32__Global Map__ast__ast__MethodInst__u32__Global;
typedef struct Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global;
typedef struct Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global;
typedef struct Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct str str;
typedef struct Option__ast__ast__Node Option__ast__ast__Node;
typedef struct Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node;
typedef struct Option__usize Option__usize;
typedef struct Result__usize__usize Result__usize__usize;
typedef struct VecIter__ast__ast__Node VecIter__ast__ast__Node;
typedef struct Range__usize Range__usize;
typedef struct Slice__ast__ast__Node Slice__ast__ast__Node;
typedef struct SliceMut__ast__ast__Node SliceMut__ast__ast__Node;
typedef struct String__Global String__Global;
typedef struct Option__u32 Option__u32;
typedef struct VecIter__u32 VecIter__u32;
typedef struct Slice__u32 Slice__u32;
typedef struct SliceMut__u32 SliceMut__u32;
typedef struct Option__ast__ast__DefId Option__ast__ast__DefId;
typedef struct Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId;
typedef struct VecIter__ast__ast__DefId VecIter__ast__ast__DefId;
typedef struct Slice__ast__ast__DefId Slice__ast__ast__DefId;
typedef struct SliceMut__ast__ast__DefId SliceMut__ast__ast__DefId;
typedef struct Option__ast__ast__Ty Option__ast__ast__Ty;
typedef struct Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty;
typedef struct VecIter__ast__ast__Ty VecIter__ast__ast__Ty;
typedef struct Slice__ast__ast__Ty Slice__ast__ast__Ty;
typedef struct SliceMut__ast__ast__Ty SliceMut__ast__ast__Ty;
typedef struct MapKeys__ast__ast__Ty MapKeys__ast__ast__Ty;
typedef struct MapValues__u32 MapValues__u32;
typedef struct Option__ast__ast__MonoUse Option__ast__ast__MonoUse;
typedef struct Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse;
typedef struct VecIter__ast__ast__MonoUse VecIter__ast__ast__MonoUse;
typedef struct Slice__ast__ast__MonoUse Slice__ast__ast__MonoUse;
typedef struct SliceMut__ast__ast__MonoUse SliceMut__ast__ast__MonoUse;
typedef struct Option__ast__ast__TyInstance Option__ast__ast__TyInstance;
typedef struct Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance;
typedef struct VecIter__ast__ast__TyInstance VecIter__ast__ast__TyInstance;
typedef struct Slice__ast__ast__TyInstance Slice__ast__ast__TyInstance;
typedef struct SliceMut__ast__ast__TyInstance SliceMut__ast__ast__TyInstance;
typedef struct Option__ast__ast__MethodInst Option__ast__ast__MethodInst;
typedef struct Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst;
typedef struct VecIter__ast__ast__MethodInst VecIter__ast__ast__MethodInst;
typedef struct Slice__ast__ast__MethodInst Slice__ast__ast__MethodInst;
typedef struct SliceMut__ast__ast__MethodInst SliceMut__ast__ast__MethodInst;
typedef struct MapKeys__ast__ast__TyInstance MapKeys__ast__ast__TyInstance;
typedef struct MapKeys__ast__ast__MethodInst MapKeys__ast__ast__MethodInst;
typedef struct Option__ast__ast__DynUse Option__ast__ast__DynUse;
typedef struct Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse;
typedef struct VecIter__ast__ast__DynUse VecIter__ast__ast__DynUse;
typedef struct Slice__ast__ast__DynUse Slice__ast__ast__DynUse;
typedef struct SliceMut__ast__ast__DynUse SliceMut__ast__ast__DynUse;
typedef struct Option__ast__ast__DerefUse Option__ast__ast__DerefUse;
typedef struct Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse;
typedef struct VecIter__ast__ast__DerefUse VecIter__ast__ast__DerefUse;
typedef struct Slice__ast__ast__DerefUse Slice__ast__ast__DerefUse;
typedef struct SliceMut__ast__ast__DerefUse SliceMut__ast__ast__DerefUse;
typedef struct Option__ast__ast__Attr Option__ast__ast__Attr;
typedef struct Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr;
typedef struct VecIter__ast__ast__Attr VecIter__ast__ast__Attr;
typedef struct Slice__ast__ast__Attr Slice__ast__ast__Attr;
typedef struct SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Option__ptr_u8 Option__ptr_u8;
typedef struct Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global;
typedef struct MapKeys__u64 MapKeys__u64;
typedef struct MapValues__ast__ast__DefId MapValues__ast__ast__DefId;
#include "../lexer/token.h"
#include "../lexer/token_type.h"
#include "../__std/interfaces.h"
#include "../__std/map.h"
#include "../__std/option.h"
#include "../__std/slice.h"
#include "../__std/vector.h"

typedef struct ast__ast__NodeList ast__ast__NodeList;
typedef struct ast__ast__DefId ast__ast__DefId;
#ifndef SUPER_ENUM_ast__ast__AttrKind
#define SUPER_ENUM_ast__ast__AttrKind
typedef enum { ast__ast__AttrKind_ATTR_INLINE, ast__ast__AttrKind_ATTR_ALWAYS_INLINE, ast__ast__AttrKind_ATTR_NOINLINE, ast__ast__AttrKind_ATTR_NORETURN, ast__ast__AttrKind_ATTR_ALIGN, ast__ast__AttrKind_ATTR_PACKED, ast__ast__AttrKind_ATTR_EXPORT, ast__ast__AttrKind_ATTR_IMPORT, ast__ast__AttrKind_ATTR_SECTION, ast__ast__AttrKind_ATTR_USED, ast__ast__AttrKind_ATTR_UNUSED, ast__ast__AttrKind_ATTR_EMIT_MACRO, ast__ast__AttrKind_ATTR_TEST, ast__ast__AttrKind_ATTR_TEST_INIT, ast__ast__AttrKind_ATTR_TEST_FREE, ast__ast__AttrKind_ATTR_C_SOURCE, ast__ast__AttrKind_ATTR_C_LINK, ast__ast__AttrKind_ATTR_COLD, ast__ast__AttrKind_ATTR_PLATFORM } ast__ast__AttrKind;
#endif
typedef struct ast__ast__Attr ast__ast__Attr;
#ifndef SUPER_ENUM_ast__ast__TypeQualifier
#define SUPER_ENUM_ast__ast__TypeQualifier
typedef enum { ast__ast__TypeQualifier_TYPE_QUAL_NONE, ast__ast__TypeQualifier_TYPE_QUAL_CONST, ast__ast__TypeQualifier_TYPE_QUAL_MUT } ast__ast__TypeQualifier;
#endif
#ifndef SUPER_ENUM_ast__ast__NodeKind
#define SUPER_ENUM_ast__ast__NodeKind
typedef enum { ast__ast__NodeKind_NODE_NONE_KIND, ast__ast__NodeKind_NODE_PROGRAM, ast__ast__NodeKind_NODE_IDENTIFIER, ast__ast__NodeKind_NODE_LITERAL, ast__ast__NodeKind_NODE_FUNCTION, ast__ast__NodeKind_NODE_PARAMETER, ast__ast__NodeKind_NODE_STRUCT, ast__ast__NodeKind_NODE_FIELD, ast__ast__NodeKind_NODE_ENUM, ast__ast__NodeKind_NODE_VARIANT, ast__ast__NodeKind_NODE_INTERFACE, ast__ast__NodeKind_NODE_EXTEND, ast__ast__NodeKind_NODE_TYPE_ALIAS, ast__ast__NodeKind_NODE_CONST, ast__ast__NodeKind_NODE_STATIC_ASSERT, ast__ast__NodeKind_NODE_EXTERN_BLOCK, ast__ast__NodeKind_NODE_IMPORT, ast__ast__NodeKind_NODE_GENERIC_PARAM, ast__ast__NodeKind_NODE_WHERE_PREDICATE, ast__ast__NodeKind_NODE_TYPE_PATH, ast__ast__NodeKind_NODE_POINTER_TYPE, ast__ast__NodeKind_NODE_REFERENCE_TYPE, ast__ast__NodeKind_NODE_SLICE_TYPE, ast__ast__NodeKind_NODE_ARRAY_TYPE, ast__ast__NodeKind_NODE_FUNCTION_TYPE, ast__ast__NodeKind_NODE_DYN_TYPE, ast__ast__NodeKind_NODE_BLOCK, ast__ast__NodeKind_NODE_LET, ast__ast__NodeKind_NODE_RETURN, ast__ast__NodeKind_NODE_BREAK, ast__ast__NodeKind_NODE_CONTINUE, ast__ast__NodeKind_NODE_DEFER, ast__ast__NodeKind_NODE_IF, ast__ast__NodeKind_NODE_WHILE, ast__ast__NodeKind_NODE_FOR, ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, ast__ast__NodeKind_NODE_UNARY, ast__ast__NodeKind_NODE_BINARY, ast__ast__NodeKind_NODE_ASSIGNMENT, ast__ast__NodeKind_NODE_CALL, ast__ast__NodeKind_NODE_CLOSURE, ast__ast__NodeKind_NODE_INDEX, ast__ast__NodeKind_NODE_MEMBER, ast__ast__NodeKind_NODE_CAST, ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION, ast__ast__NodeKind_NODE_MATCH, ast__ast__NodeKind_NODE_MATCH_ARM, ast__ast__NodeKind_NODE_NEW, ast__ast__NodeKind_NODE_SIZEOF, ast__ast__NodeKind_NODE_ALIGNOF, ast__ast__NodeKind_NODE_VA_EXPR, ast__ast__NodeKind_NODE_ARRAY_LITERAL, ast__ast__NodeKind_NODE_STRUCT_INITIALIZER, ast__ast__NodeKind_NODE_FIELD_INITIALIZER, ast__ast__NodeKind_NODE_PATTERN_WILDCARD, ast__ast__NodeKind_NODE_PATTERN_LITERAL, ast__ast__NodeKind_NODE_PATTERN_NAME, ast__ast__NodeKind_NODE_PATTERN_TUPLE, ast__ast__NodeKind_NODE_PATTERN_STRUCT, ast__ast__NodeKind_NODE_PATTERN_FIELD, ast__ast__NodeKind_NODE_PATTERN_RANGE, ast__ast__NodeKind_NODE_PATTERN_OR, ast__ast__NodeKind_NODE_RANGE, ast__ast__NodeKind_NODE_TUPLE, ast__ast__NodeKind_NODE_TUPLE_TYPE, ast__ast__NodeKind_NODE_KIND_COUNT } ast__ast__NodeKind;
#endif
typedef struct ast__ast__ProgramData ast__ast__ProgramData;
typedef struct ast__ast__NameData ast__ast__NameData;
typedef struct ast__ast__LiteralData ast__ast__LiteralData;
typedef struct ast__ast__FunctionData ast__ast__FunctionData;
typedef struct ast__ast__ParameterData ast__ast__ParameterData;
typedef struct ast__ast__AggregateData ast__ast__AggregateData;
typedef struct ast__ast__FieldData ast__ast__FieldData;
typedef struct ast__ast__VariantData ast__ast__VariantData;
typedef struct ast__ast__InterfaceData ast__ast__InterfaceData;
typedef struct ast__ast__ExtendData ast__ast__ExtendData;
typedef struct ast__ast__TypeAliasData ast__ast__TypeAliasData;
typedef struct ast__ast__ConstData ast__ast__ConstData;
typedef struct ast__ast__ExternBlockData ast__ast__ExternBlockData;
typedef struct ast__ast__ImportData ast__ast__ImportData;
typedef struct ast__ast__GenericParamData ast__ast__GenericParamData;
typedef struct ast__ast__WherePredicateData ast__ast__WherePredicateData;
typedef struct ast__ast__TypePathData ast__ast__TypePathData;
typedef struct ast__ast__IndirectTypeData ast__ast__IndirectTypeData;
typedef struct ast__ast__ArrayTypeData ast__ast__ArrayTypeData;
typedef struct ast__ast__FunctionTypeData ast__ast__FunctionTypeData;
typedef struct ast__ast__BlockData ast__ast__BlockData;
typedef struct ast__ast__LetData ast__ast__LetData;
typedef struct ast__ast__SingleData ast__ast__SingleData;
typedef struct ast__ast__VaOpData ast__ast__VaOpData;
typedef struct ast__ast__ReturnData ast__ast__ReturnData;
typedef struct ast__ast__IfData ast__ast__IfData;
typedef struct ast__ast__WhileData ast__ast__WhileData;
typedef struct ast__ast__ForData ast__ast__ForData;
typedef struct ast__ast__FlowData ast__ast__FlowData;
typedef struct ast__ast__UnaryData ast__ast__UnaryData;
typedef struct ast__ast__BinaryData ast__ast__BinaryData;
typedef struct ast__ast__CallData ast__ast__CallData;
typedef struct ast__ast__ClosureData ast__ast__ClosureData;
typedef struct ast__ast__IndexData ast__ast__IndexData;
typedef struct ast__ast__MemberData ast__ast__MemberData;
typedef struct ast__ast__CastData ast__ast__CastData;
typedef struct ast__ast__SpecializationData ast__ast__SpecializationData;
typedef struct ast__ast__MatchData ast__ast__MatchData;
typedef struct ast__ast__MatchArmData ast__ast__MatchArmData;
typedef struct ast__ast__NewData ast__ast__NewData;
typedef struct ast__ast__ArrayLiteralData ast__ast__ArrayLiteralData;
typedef struct ast__ast__StructInitializerData ast__ast__StructInitializerData;
typedef struct ast__ast__FieldInitializerData ast__ast__FieldInitializerData;
typedef struct ast__ast__PatternData ast__ast__PatternData;
typedef struct ast__ast__PatternRangeData ast__ast__PatternRangeData;
typedef union ast__ast__NodeAs ast__ast__NodeAs;
typedef struct ast__ast__Node ast__ast__Node;
#ifndef SUPER_ENUM_ast__ast__BuiltinType
#define SUPER_ENUM_ast__ast__BuiltinType
typedef enum { ast__ast__BuiltinType_BT_BOOL, ast__ast__BuiltinType_BT_CHAR, ast__ast__BuiltinType_BT_I8, ast__ast__BuiltinType_BT_I16, ast__ast__BuiltinType_BT_I32, ast__ast__BuiltinType_BT_I64, ast__ast__BuiltinType_BT_ISIZE, ast__ast__BuiltinType_BT_U8, ast__ast__BuiltinType_BT_U16, ast__ast__BuiltinType_BT_U32, ast__ast__BuiltinType_BT_U64, ast__ast__BuiltinType_BT_USIZE, ast__ast__BuiltinType_BT_F32, ast__ast__BuiltinType_BT_F64, ast__ast__BuiltinType_BT_C32, ast__ast__BuiltinType_BT_C64, ast__ast__BuiltinType_BT_VALIST, ast__ast__BuiltinType_BT_VOID, ast__ast__BuiltinType_BT_COUNT } ast__ast__BuiltinType;
#endif
#ifndef SUPER_ENUM_ast__ast__TypeKind
#define SUPER_ENUM_ast__ast__TypeKind
typedef enum { ast__ast__TypeKind_TYPE_ERROR, ast__ast__TypeKind_TYPE_BUILTIN, ast__ast__TypeKind_TYPE_POINTER, ast__ast__TypeKind_TYPE_REFERENCE, ast__ast__TypeKind_TYPE_SLICE, ast__ast__TypeKind_TYPE_ARRAY, ast__ast__TypeKind_TYPE_FUNCTION, ast__ast__TypeKind_TYPE_STRUCT, ast__ast__TypeKind_TYPE_ENUM, ast__ast__TypeKind_TYPE_GENERIC, ast__ast__TypeKind_TYPE_INSTANCE, ast__ast__TypeKind_TYPE_OPAQUE, ast__ast__TypeKind_TYPE_DYN, ast__ast__TypeKind_TYPE_NEVER, ast__ast__TypeKind_TYPE_CONST } ast__ast__TypeKind;
#endif
typedef struct ast__ast__TyArr ast__ast__TyArr;
typedef union ast__ast__TyAs ast__ast__TyAs;
typedef struct ast__ast__Ty ast__ast__Ty;
typedef struct ast__ast__TyInstance ast__ast__TyInstance;
typedef struct ast__ast__MonoUse ast__ast__MonoUse;
typedef struct ast__ast__DynUse ast__ast__DynUse;
typedef struct ast__ast__DerefUse ast__ast__DerefUse;
typedef struct ast__ast__MethodInst ast__ast__MethodInst;
typedef struct ast__ast__Ast ast__ast__Ast;
typedef struct Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global;
typedef struct Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global;
typedef struct Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global;
typedef struct Map__ast__ast__Ty__u32__Global Map__ast__ast__Ty__u32__Global;
typedef struct Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global;
typedef struct Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global;
typedef struct Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global;
typedef struct Map__ast__ast__TyInstance__u32__Global Map__ast__ast__TyInstance__u32__Global;
typedef struct Map__ast__ast__MethodInst__u32__Global Map__ast__ast__MethodInst__u32__Global;
typedef struct Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global;
typedef struct Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global;
typedef struct Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global;
typedef struct Option__ast__ast__Node Option__ast__ast__Node;
typedef struct Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node;
typedef struct VecIter__ast__ast__Node VecIter__ast__ast__Node;
typedef struct Slice__ast__ast__Node Slice__ast__ast__Node;
typedef struct SliceMut__ast__ast__Node SliceMut__ast__ast__Node;
typedef struct Option__ast__ast__DefId Option__ast__ast__DefId;
typedef struct Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId;
typedef struct VecIter__ast__ast__DefId VecIter__ast__ast__DefId;
typedef struct Slice__ast__ast__DefId Slice__ast__ast__DefId;
typedef struct SliceMut__ast__ast__DefId SliceMut__ast__ast__DefId;
typedef struct Option__ast__ast__Ty Option__ast__ast__Ty;
typedef struct Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty;
typedef struct VecIter__ast__ast__Ty VecIter__ast__ast__Ty;
typedef struct Slice__ast__ast__Ty Slice__ast__ast__Ty;
typedef struct SliceMut__ast__ast__Ty SliceMut__ast__ast__Ty;
typedef struct MapKeys__ast__ast__Ty MapKeys__ast__ast__Ty;
typedef struct Option__ast__ast__MonoUse Option__ast__ast__MonoUse;
typedef struct Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse;
typedef struct VecIter__ast__ast__MonoUse VecIter__ast__ast__MonoUse;
typedef struct Slice__ast__ast__MonoUse Slice__ast__ast__MonoUse;
typedef struct SliceMut__ast__ast__MonoUse SliceMut__ast__ast__MonoUse;
typedef struct Option__ast__ast__TyInstance Option__ast__ast__TyInstance;
typedef struct Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance;
typedef struct VecIter__ast__ast__TyInstance VecIter__ast__ast__TyInstance;
typedef struct Slice__ast__ast__TyInstance Slice__ast__ast__TyInstance;
typedef struct SliceMut__ast__ast__TyInstance SliceMut__ast__ast__TyInstance;
typedef struct Option__ast__ast__MethodInst Option__ast__ast__MethodInst;
typedef struct Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst;
typedef struct VecIter__ast__ast__MethodInst VecIter__ast__ast__MethodInst;
typedef struct Slice__ast__ast__MethodInst Slice__ast__ast__MethodInst;
typedef struct SliceMut__ast__ast__MethodInst SliceMut__ast__ast__MethodInst;
typedef struct MapKeys__ast__ast__TyInstance MapKeys__ast__ast__TyInstance;
typedef struct MapKeys__ast__ast__MethodInst MapKeys__ast__ast__MethodInst;
typedef struct Option__ast__ast__DynUse Option__ast__ast__DynUse;
typedef struct Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse;
typedef struct VecIter__ast__ast__DynUse VecIter__ast__ast__DynUse;
typedef struct Slice__ast__ast__DynUse Slice__ast__ast__DynUse;
typedef struct SliceMut__ast__ast__DynUse SliceMut__ast__ast__DynUse;
typedef struct Option__ast__ast__DerefUse Option__ast__ast__DerefUse;
typedef struct Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse;
typedef struct VecIter__ast__ast__DerefUse VecIter__ast__ast__DerefUse;
typedef struct Slice__ast__ast__DerefUse Slice__ast__ast__DerefUse;
typedef struct SliceMut__ast__ast__DerefUse SliceMut__ast__ast__DerefUse;
typedef struct Option__ast__ast__Attr Option__ast__ast__Attr;
typedef struct Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr;
typedef struct VecIter__ast__ast__Attr VecIter__ast__ast__Attr;
typedef struct Slice__ast__ast__Attr Slice__ast__ast__Attr;
typedef struct SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr;
typedef struct Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global;
typedef struct MapValues__ast__ast__DefId MapValues__ast__ast__DefId;

struct ast__ast__NodeList {
  uint32_t start;
  uint32_t len;
};
struct ast__ast__DefId {
  uint16_t module;
  uint32_t node;
};
struct ast__ast__Attr {
  uint32_t owner;
  uint8_t kind;
  uint32_t arg;
  lexer__token__Span str_span;
};
struct ast__ast__ProgramData {
  ast__ast__NodeList items;
};
struct ast__ast__NameData {
  lexer__token__Span text;
  bool is_mutable;
};
struct ast__ast__LiteralData {
  lexer__token__Span raw;
  lexer__token_type__TokenType token_type;
};
struct ast__ast__FunctionData {
  uint32_t name;
  ast__ast__NodeList generics;
  ast__ast__NodeList params;
  ast__ast__NodeList returns;
  ast__ast__NodeList where_clause;
  uint32_t body;
  bool is_public;
  bool is_extern;
  bool is_variadic;
};
struct ast__ast__ParameterData {
  uint32_t name;
  uint32_t ty;
  bool is_mutable;
};
struct ast__ast__AggregateData {
  uint32_t name;
  ast__ast__NodeList generics;
  ast__ast__NodeList members;
  bool is_public;
  bool is_union;
  bool is_tuple;
};
struct ast__ast__FieldData {
  uint32_t name;
  uint32_t ty;
  uint32_t value;
  bool is_public;
};
struct ast__ast__VariantData {
  uint32_t name;
  ast__ast__NodeList payload;
  bool struct_payload;
  uint32_t value;
};
struct ast__ast__InterfaceData {
  uint32_t name;
  ast__ast__NodeList generics;
  ast__ast__NodeList bounds;
  ast__ast__NodeList items;
  bool is_public;
};
struct ast__ast__ExtendData {
  ast__ast__NodeList generics;
  uint32_t interface_type;
  uint32_t target_type;
  ast__ast__NodeList items;
};
struct ast__ast__TypeAliasData {
  uint32_t name;
  ast__ast__NodeList generics;
  uint32_t ty;
  bool is_public;
};
struct ast__ast__ConstData {
  uint32_t name;
  uint32_t ty;
  uint32_t value;
  bool is_public;
  bool is_extern;
  bool is_static_mut;
};
struct ast__ast__ExternBlockData {
  uint32_t abi;
  uint32_t header;
  ast__ast__NodeList items;
};
struct ast__ast__ImportData {
  ast__ast__NodeList path;
  uint32_t alias;
  bool glob;
};
struct ast__ast__GenericParamData {
  uint32_t name;
  ast__ast__NodeList bounds;
  uint32_t default_type;
  bool is_const;
  uint32_t const_type;
};
struct ast__ast__WherePredicateData {
  uint32_t ty;
  ast__ast__NodeList bounds;
};
struct ast__ast__TypePathData {
  ast__ast__NodeList parts;
  ast__ast__NodeList args;
};
struct ast__ast__IndirectTypeData {
  uint32_t ty;
  ast__ast__TypeQualifier qualifier;
};
struct ast__ast__ArrayTypeData {
  uint32_t element;
  uint32_t length;
};
struct ast__ast__FunctionTypeData {
  ast__ast__NodeList params;
  ast__ast__NodeList returns;
  bool is_move;
};
struct ast__ast__BlockData {
  ast__ast__NodeList statements;
};
struct ast__ast__LetData {
  uint32_t name;
  uint32_t ty;
  uint32_t value;
  bool is_mutable;
};
struct ast__ast__SingleData {
  uint32_t value;
};
struct ast__ast__VaOpData {
  uint8_t op;
  uint32_t ap;
  uint32_t extra;
};
struct ast__ast__ReturnData {
  ast__ast__NodeList values;
};
struct ast__ast__IfData {
  uint32_t condition;
  uint32_t then_branch;
  uint32_t else_branch;
};
struct ast__ast__WhileData {
  uint32_t condition;
  uint32_t body;
  bool is_do;
  lexer__token__Span label;
};
struct ast__ast__ForData {
  uint32_t binding;
  uint32_t iterable;
  uint32_t body;
  lexer__token__Span label;
};
struct ast__ast__FlowData {
  uint32_t value;
  lexer__token__Span label;
};
struct ast__ast__UnaryData {
  lexer__token_type__TokenType op;
  uint32_t operand;
  ast__ast__TypeQualifier qualifier;
};
struct ast__ast__BinaryData {
  lexer__token_type__TokenType op;
  uint32_t left;
  uint32_t right;
};
struct ast__ast__CallData {
  uint32_t callee;
  ast__ast__NodeList args;
};
struct ast__ast__ClosureData {
  ast__ast__NodeList params;
  ast__ast__NodeList returns;
  uint32_t body;
  bool expr_body;
  ast__ast__NodeList captures;
  uint32_t mut_caps;
};
struct ast__ast__IndexData {
  uint32_t object;
  uint32_t index;
};
struct ast__ast__MemberData {
  uint32_t object;
  uint32_t member;
  bool pointer;
  bool path;
};
struct ast__ast__CastData {
  uint32_t expression;
  uint32_t ty;
};
struct ast__ast__SpecializationData {
  uint32_t expression;
  ast__ast__NodeList types;
};
struct ast__ast__MatchData {
  uint32_t value;
  ast__ast__NodeList arms;
};
struct ast__ast__MatchArmData {
  uint32_t pattern;
  uint32_t guard;
  uint32_t body;
};
struct ast__ast__NewData {
  uint32_t ty;
  uint32_t initializer;
};
struct ast__ast__ArrayLiteralData {
  ast__ast__NodeList elements;
};
struct ast__ast__StructInitializerData {
  uint32_t ty;
  ast__ast__NodeList fields;
};
struct ast__ast__FieldInitializerData {
  uint32_t name;
  uint32_t value;
};
struct ast__ast__PatternData {
  uint32_t name;
  ast__ast__NodeList children;
};
struct ast__ast__PatternRangeData {
  uint32_t start;
  uint32_t end;
  bool inclusive;
};
union ast__ast__NodeAs {
  ast__ast__ProgramData program;
  ast__ast__NameData name;
  ast__ast__LiteralData literal;
  ast__ast__FunctionData function;
  ast__ast__ParameterData parameter;
  ast__ast__AggregateData aggregate;
  ast__ast__FieldData field;
  ast__ast__VariantData variant;
  ast__ast__InterfaceData interface_def;
  ast__ast__ExtendData extend_def;
  ast__ast__TypeAliasData type_alias;
  ast__ast__ConstData const_def;
  ast__ast__ExternBlockData extern_block;
  ast__ast__ImportData import_decl;
  ast__ast__GenericParamData generic_param;
  ast__ast__WherePredicateData where_predicate;
  ast__ast__TypePathData type_path;
  ast__ast__IndirectTypeData indirect_type;
  ast__ast__ArrayTypeData array_type;
  ast__ast__FunctionTypeData function_type;
  ast__ast__BlockData block;
  ast__ast__LetData let_stmt;
  ast__ast__SingleData single;
  ast__ast__VaOpData va_op;
  ast__ast__ReturnData return_stmt;
  ast__ast__IfData if_stmt;
  ast__ast__WhileData while_stmt;
  ast__ast__ForData for_stmt;
  ast__ast__FlowData flow;
  ast__ast__UnaryData unary;
  ast__ast__BinaryData binary;
  ast__ast__CallData call;
  ast__ast__ClosureData closure;
  ast__ast__IndexData index;
  ast__ast__MemberData member;
  ast__ast__CastData cast;
  ast__ast__SpecializationData specialization;
  ast__ast__MatchData match_expr;
  ast__ast__MatchArmData match_arm;
  ast__ast__NewData new_expr;
  ast__ast__ArrayLiteralData array_literal;
  ast__ast__StructInitializerData struct_initializer;
  ast__ast__FieldInitializerData field_initializer;
  ast__ast__PatternData pattern;
  ast__ast__PatternRangeData pattern_range;
};
struct ast__ast__Node {
  ast__ast__NodeKind kind;
  lexer__token__Span span;
  ast__ast__NodeAs as_data;
};
struct ast__ast__TyArr {
  uint32_t elem;
  uint32_t len;
};
union ast__ast__TyAs {
  ast__ast__BuiltinType builtin;
  uint32_t elem;
  uint32_t decl;
  uint32_t inst;
  ast__ast__TyArr arr;
  int64_t value;
};
struct ast__ast__Ty {
  ast__ast__TypeKind kind;
  uint8_t qualifier;
  uint16_t module;
  ast__ast__TyAs as_data;
};
struct ast__ast__TyInstance {
  uint16_t module;
  uint32_t decl;
  uint8_t n;
  uint32_t args[4];
};
struct ast__ast__MonoUse {
  uint32_t node;
  uint8_t n;
  uint32_t args[4];
};
struct ast__ast__DynUse {
  uint32_t node;
  uint32_t src;
  uint32_t dyn_ty;
};
struct ast__ast__DerefUse {
  uint32_t node;
  uint32_t target;
  uint8_t n;
  uint32_t recv[8];
  ast__ast__DefId method[8];
};
struct ast__ast__MethodInst {
  uint32_t instance;
  uint32_t method;
  uint8_t n;
  uint32_t targs[4];
};
struct Vector__ast__ast__Node__Global {
  ast__ast__Node *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__DefId__Global {
  ast__ast__DefId *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__Ty__Global {
  ast__ast__Ty *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Map__ast__ast__Ty__u32__Global {
  ast__ast__Ty *keys;
  uint32_t *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__MonoUse__Global {
  ast__ast__MonoUse *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__TyInstance__Global {
  ast__ast__TyInstance *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__MethodInst__Global {
  ast__ast__MethodInst *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Map__ast__ast__TyInstance__u32__Global {
  ast__ast__TyInstance *keys;
  uint32_t *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Map__ast__ast__MethodInst__u32__Global {
  ast__ast__MethodInst *keys;
  uint32_t *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__DynUse__Global {
  ast__ast__DynUse *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__DerefUse__Global {
  ast__ast__DerefUse *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__ast__ast__Attr__Global {
  ast__ast__Attr *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct ast__ast__Ast {
  Vector__ast__ast__Node__Global nodes;
  Vector__u32__Global children;
  Vector__u32__Global scratch;
  Vector__ast__ast__DefId__Global resolutions;
  Vector__ast__ast__Ty__Global type_pool;
  Map__ast__ast__Ty__u32__Global type_index;
  Vector__u32__Global types;
  Vector__ast__ast__MonoUse__Global mono;
  Vector__u32__Global mono_at;
  Vector__ast__ast__TyInstance__Global instances;
  Vector__ast__ast__MethodInst__Global method_insts;
  Map__ast__ast__TyInstance__u32__Global instance_index;
  Map__ast__ast__MethodInst__u32__Global method_inst_index;
  Vector__ast__ast__DynUse__Global dyn_uses;
  Vector__u32__Global dyn_at;
  Vector__ast__ast__DerefUse__Global deref_uses;
  Vector__u32__Global deref_at;
  Vector__ast__ast__Attr__Global attrs;
  uint32_t root;
  uint16_t module;
};
struct Option__ast__ast__Node {
  OptionTag tag;
  union {
    struct { ast__ast__Node _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__Node {
  OptionTag tag;
  union {
    struct { const ast__ast__Node *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__Node {
  const ast__ast__Node *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__Node {
  const ast__ast__Node *ptr;
  size_t len;
};
struct SliceMut__ast__ast__Node {
  ast__ast__Node *ptr;
  size_t len;
};
struct Option__ast__ast__DefId {
  OptionTag tag;
  union {
    struct { ast__ast__DefId _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__DefId {
  OptionTag tag;
  union {
    struct { const ast__ast__DefId *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__DefId {
  const ast__ast__DefId *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__DefId {
  const ast__ast__DefId *ptr;
  size_t len;
};
struct SliceMut__ast__ast__DefId {
  ast__ast__DefId *ptr;
  size_t len;
};
struct Option__ast__ast__Ty {
  OptionTag tag;
  union {
    struct { ast__ast__Ty _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__Ty {
  OptionTag tag;
  union {
    struct { const ast__ast__Ty *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__Ty {
  const ast__ast__Ty *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__Ty {
  const ast__ast__Ty *ptr;
  size_t len;
};
struct SliceMut__ast__ast__Ty {
  ast__ast__Ty *ptr;
  size_t len;
};
struct MapKeys__ast__ast__Ty {
  const ast__ast__Ty *keys;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct Option__ast__ast__MonoUse {
  OptionTag tag;
  union {
    struct { ast__ast__MonoUse _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__MonoUse {
  OptionTag tag;
  union {
    struct { const ast__ast__MonoUse *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__MonoUse {
  const ast__ast__MonoUse *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__MonoUse {
  const ast__ast__MonoUse *ptr;
  size_t len;
};
struct SliceMut__ast__ast__MonoUse {
  ast__ast__MonoUse *ptr;
  size_t len;
};
struct Option__ast__ast__TyInstance {
  OptionTag tag;
  union {
    struct { ast__ast__TyInstance _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__TyInstance {
  OptionTag tag;
  union {
    struct { const ast__ast__TyInstance *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__TyInstance {
  const ast__ast__TyInstance *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__TyInstance {
  const ast__ast__TyInstance *ptr;
  size_t len;
};
struct SliceMut__ast__ast__TyInstance {
  ast__ast__TyInstance *ptr;
  size_t len;
};
struct Option__ast__ast__MethodInst {
  OptionTag tag;
  union {
    struct { ast__ast__MethodInst _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__MethodInst {
  OptionTag tag;
  union {
    struct { const ast__ast__MethodInst *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__MethodInst {
  const ast__ast__MethodInst *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__MethodInst {
  const ast__ast__MethodInst *ptr;
  size_t len;
};
struct SliceMut__ast__ast__MethodInst {
  ast__ast__MethodInst *ptr;
  size_t len;
};
struct MapKeys__ast__ast__TyInstance {
  const ast__ast__TyInstance *keys;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct MapKeys__ast__ast__MethodInst {
  const ast__ast__MethodInst *keys;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};
struct Option__ast__ast__DynUse {
  OptionTag tag;
  union {
    struct { ast__ast__DynUse _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__DynUse {
  OptionTag tag;
  union {
    struct { const ast__ast__DynUse *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__DynUse {
  const ast__ast__DynUse *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__DynUse {
  const ast__ast__DynUse *ptr;
  size_t len;
};
struct SliceMut__ast__ast__DynUse {
  ast__ast__DynUse *ptr;
  size_t len;
};
struct Option__ast__ast__DerefUse {
  OptionTag tag;
  union {
    struct { ast__ast__DerefUse _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__DerefUse {
  OptionTag tag;
  union {
    struct { const ast__ast__DerefUse *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__DerefUse {
  const ast__ast__DerefUse *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__DerefUse {
  const ast__ast__DerefUse *ptr;
  size_t len;
};
struct SliceMut__ast__ast__DerefUse {
  ast__ast__DerefUse *ptr;
  size_t len;
};
struct Option__ast__ast__Attr {
  OptionTag tag;
  union {
    struct { ast__ast__Attr _0; } Some;
  } payload;
};
struct Option__ptr_ast__ast__Attr {
  OptionTag tag;
  union {
    struct { const ast__ast__Attr *_0; } Some;
  } payload;
};
struct VecIter__ast__ast__Attr {
  const ast__ast__Attr *data;
  size_t idx;
  size_t stop;
};
struct Slice__ast__ast__Attr {
  const ast__ast__Attr *ptr;
  size_t len;
};
struct SliceMut__ast__ast__Attr {
  ast__ast__Attr *ptr;
  size_t len;
};
struct Map__u64__ast__ast__DefId__Global {
  uint64_t *keys;
  ast__ast__DefId *vals;
  uint8_t *used;
  size_t len;
  size_t cap;
  Global alloc;
};
struct MapValues__ast__ast__DefId {
  const ast__ast__DefId *vals;
  const uint8_t *used;
  size_t idx;
  size_t cap;
};

uint64_t ast__ast__Ty__hash(const ast__ast__Ty *const self);
bool ast__ast__Ty__eq(const ast__ast__Ty *const self, const ast__ast__Ty *const other);
uint64_t ast__ast__TyInstance__hash(const ast__ast__TyInstance *const self);
bool ast__ast__TyInstance__eq(const ast__ast__TyInstance *const self, const ast__ast__TyInstance *const other);
uint64_t ast__ast__MethodInst__hash(const ast__ast__MethodInst *const self);
bool ast__ast__MethodInst__eq(const ast__ast__MethodInst *const self, const ast__ast__MethodInst *const other);
ast__ast__Ast ast__ast__Ast__new(size_t const token_count);
uint32_t ast__ast__Ast__add(ast__ast__Ast *const self, ast__ast__Node const node);
uint32_t ast__ast__Ast__mark(const ast__ast__Ast *const self);
void ast__ast__Ast__push(ast__ast__Ast *const self, uint32_t const id);
ast__ast__NodeList ast__ast__Ast__commit(ast__ast__Ast *const self, uint32_t const mark);
void ast__ast__Ast__init_resolutions(ast__ast__Ast *const self);
void ast__ast__Ast__init_types(ast__ast__Ast *const self);
uint32_t ast__ast__Ast__intern_type(ast__ast__Ast *const self, ast__ast__Ty const t);
uint32_t ast__ast__Ast__intern_instance(ast__ast__Ast *const self, uint16_t const module, uint32_t const decl, const uint32_t *const args, uint8_t const n);
const ast__ast__TyInstance *ast__ast__Ast__instance(const ast__ast__Ast *const self, uint32_t const index);
uint32_t ast__ast__Ast__const_value(ast__ast__Ast *const self, int64_t const v);
bool ast__ast__Ast__add_method_inst(ast__ast__Ast *const self, uint32_t const instance, uint32_t const method, const uint32_t *const targs, uint8_t const n);
void ast__ast__Ast__add_attr(ast__ast__Ast *const self, ast__ast__Attr const attr);
bool ast__ast__Ast__type_concrete(const ast__ast__Ast *const self, uint32_t const t);
uint32_t ast__ast__Ast__reintern(ast__ast__Ast *const self, const ast__ast__Ast *const src, uint32_t const t);
void ast__ast__Ast__set_type_args(ast__ast__Ast *const self, uint32_t const node, const uint32_t *const args, uint8_t const n);
const ast__ast__MonoUse *ast__ast__Ast__type_args(const ast__ast__Ast *const self, uint32_t const node);
void ast__ast__Ast__add_dyn_use(ast__ast__Ast *const self, uint32_t const node, uint32_t const src, uint32_t const dyn_ty);
const ast__ast__DynUse *ast__ast__Ast__dyn_use_at(const ast__ast__Ast *const self, uint32_t const node);
void ast__ast__Ast__add_deref_use(ast__ast__Ast *const self, const ast__ast__DerefUse *const du);
const ast__ast__DerefUse *ast__ast__Ast__deref_use_at(const ast__ast__Ast *const self, uint32_t const node);
ast__ast__Node *ast__ast__Ast__at(ast__ast__Ast *const self, uint32_t const id);
const ast__ast__Node *ast__ast__Ast__at_const(const ast__ast__Ast *const self, uint32_t const id);
const uint32_t *ast__ast__Ast__list(const ast__ast__Ast *const self, ast__ast__NodeList const list);
void ast__ast__Ast__set_resolution(ast__ast__Ast *const self, uint32_t const ref_id, uint32_t const decl);
uint32_t ast__ast__Ast__resolution(const ast__ast__Ast *const self, uint32_t const ref_id);
ast__ast__DefId ast__ast__Ast__resolution_def(const ast__ast__Ast *const self, uint32_t const ref_id);
void ast__ast__Ast__set_resolution_def(ast__ast__Ast *const self, uint32_t const ref_id, ast__ast__DefId const decl);
uint32_t ast__ast__Ast__builtin(ast__ast__BuiltinType const b);
void ast__ast__Ast__set_type(ast__ast__Ast *const self, uint32_t const n, uint32_t const t);
uint32_t ast__ast__Ast__type_of(const ast__ast__Ast *const self, uint32_t const n);
const ast__ast__Ty *ast__ast__Ast__type_at(const ast__ast__Ast *const self, uint32_t const t);
void ast__ast__Ast__free(ast__ast__Ast *const self);
ast__ast__BuiltinType ast__ast__ast_numeric_suffix(const uint8_t *const src, uint32_t const start, uint32_t const end, uint32_t *const sfx_start);
Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__new_in(Global const alloc);
Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__Node__Global__len(const Vector__ast__ast__Node__Global *const self);
void Vector__ast__ast__Node__Global__reserve(Vector__ast__ast__Node__Global *const self, size_t const additional);
void Vector__ast__ast__Node__Global__push(Vector__ast__ast__Node__Global *const self, ast__ast__Node const value);
const ast__ast__Node *Vector__ast__ast__Node__Global__at(const Vector__ast__ast__Node__Global *const self, size_t const index);
Option__ptr_ast__ast__Node Vector__ast__ast__Node__Global__get(const Vector__ast__ast__Node__Global *const self, size_t const index);
void Vector__ast__ast__Node__Global__set(Vector__ast__ast__Node__Global *const self, size_t const index, ast__ast__Node const value);
void Vector__ast__ast__Node__Global__clear(Vector__ast__ast__Node__Global *const self);
void Vector__ast__ast__Node__Global__truncate(Vector__ast__ast__Node__Global *const self, size_t const new_len);
const ast__ast__Node *Vector__ast__ast__Node__Global__as_ptr(const Vector__ast__ast__Node__Global *const self);
void Vector__ast__ast__Node__Global__swap(Vector__ast__ast__Node__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__new(void);
void Vector__ast__ast__Node__Global__free(Vector__ast__ast__Node__Global *const self);
Vector__ast__ast__Node__Global Vector__ast__ast__Node__Global__default_(void);
const ast__ast__Node *Vector__ast__ast__Node__Global__index(const Vector__ast__ast__Node__Global *const self, size_t const i);
Slice__ast__ast__Node Vector__ast__ast__Node__Global__index_range(const Vector__ast__ast__Node__Global *const self, Range__usize const r);
ast__ast__Node *Vector__ast__ast__Node__Global__index_mut(Vector__ast__ast__Node__Global *const self, size_t const i);
SliceMut__ast__ast__Node Vector__ast__ast__Node__Global__index_range_mut(Vector__ast__ast__Node__Global *const self, Range__usize const r);
Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__new_in(Global const alloc);
Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__DefId__Global__len(const Vector__ast__ast__DefId__Global *const self);
void Vector__ast__ast__DefId__Global__reserve(Vector__ast__ast__DefId__Global *const self, size_t const additional);
void Vector__ast__ast__DefId__Global__push(Vector__ast__ast__DefId__Global *const self, ast__ast__DefId const value);
const ast__ast__DefId *Vector__ast__ast__DefId__Global__at(const Vector__ast__ast__DefId__Global *const self, size_t const index);
Option__ptr_ast__ast__DefId Vector__ast__ast__DefId__Global__get(const Vector__ast__ast__DefId__Global *const self, size_t const index);
void Vector__ast__ast__DefId__Global__set(Vector__ast__ast__DefId__Global *const self, size_t const index, ast__ast__DefId const value);
void Vector__ast__ast__DefId__Global__clear(Vector__ast__ast__DefId__Global *const self);
void Vector__ast__ast__DefId__Global__truncate(Vector__ast__ast__DefId__Global *const self, size_t const new_len);
const ast__ast__DefId *Vector__ast__ast__DefId__Global__as_ptr(const Vector__ast__ast__DefId__Global *const self);
void Vector__ast__ast__DefId__Global__swap(Vector__ast__ast__DefId__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__new(void);
void Vector__ast__ast__DefId__Global__free(Vector__ast__ast__DefId__Global *const self);
Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global__default_(void);
const ast__ast__DefId *Vector__ast__ast__DefId__Global__index(const Vector__ast__ast__DefId__Global *const self, size_t const i);
Slice__ast__ast__DefId Vector__ast__ast__DefId__Global__index_range(const Vector__ast__ast__DefId__Global *const self, Range__usize const r);
ast__ast__DefId *Vector__ast__ast__DefId__Global__index_mut(Vector__ast__ast__DefId__Global *const self, size_t const i);
SliceMut__ast__ast__DefId Vector__ast__ast__DefId__Global__index_range_mut(Vector__ast__ast__DefId__Global *const self, Range__usize const r);
Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__new_in(Global const alloc);
Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__Ty__Global__len(const Vector__ast__ast__Ty__Global *const self);
void Vector__ast__ast__Ty__Global__reserve(Vector__ast__ast__Ty__Global *const self, size_t const additional);
void Vector__ast__ast__Ty__Global__push(Vector__ast__ast__Ty__Global *const self, ast__ast__Ty const value);
const ast__ast__Ty *Vector__ast__ast__Ty__Global__at(const Vector__ast__ast__Ty__Global *const self, size_t const index);
Option__ptr_ast__ast__Ty Vector__ast__ast__Ty__Global__get(const Vector__ast__ast__Ty__Global *const self, size_t const index);
void Vector__ast__ast__Ty__Global__set(Vector__ast__ast__Ty__Global *const self, size_t const index, ast__ast__Ty const value);
void Vector__ast__ast__Ty__Global__clear(Vector__ast__ast__Ty__Global *const self);
void Vector__ast__ast__Ty__Global__truncate(Vector__ast__ast__Ty__Global *const self, size_t const new_len);
const ast__ast__Ty *Vector__ast__ast__Ty__Global__as_ptr(const Vector__ast__ast__Ty__Global *const self);
void Vector__ast__ast__Ty__Global__swap(Vector__ast__ast__Ty__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__new(void);
void Vector__ast__ast__Ty__Global__free(Vector__ast__ast__Ty__Global *const self);
Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global__default_(void);
const ast__ast__Ty *Vector__ast__ast__Ty__Global__index(const Vector__ast__ast__Ty__Global *const self, size_t const i);
Slice__ast__ast__Ty Vector__ast__ast__Ty__Global__index_range(const Vector__ast__ast__Ty__Global *const self, Range__usize const r);
ast__ast__Ty *Vector__ast__ast__Ty__Global__index_mut(Vector__ast__ast__Ty__Global *const self, size_t const i);
SliceMut__ast__ast__Ty Vector__ast__ast__Ty__Global__index_range_mut(Vector__ast__ast__Ty__Global *const self, Range__usize const r);
bool Vector__ast__ast__Ty__Global__eq(const Vector__ast__ast__Ty__Global *const self, const Vector__ast__ast__Ty__Global *const other);
uint64_t Vector__ast__ast__Ty__Global__hash(const Vector__ast__ast__Ty__Global *const self);
Map__ast__ast__Ty__u32__Global Map__ast__ast__Ty__u32__Global__new_in(Global const alloc);
size_t Map__ast__ast__Ty__u32__Global__len(const Map__ast__ast__Ty__u32__Global *const self);
bool Map__ast__ast__Ty__u32__Global__is_empty(const Map__ast__ast__Ty__u32__Global *const self);
void Map__ast__ast__Ty__u32__Global__insert(Map__ast__ast__Ty__u32__Global *const self, ast__ast__Ty const key, uint32_t const value);
Option__ptr_u32 Map__ast__ast__Ty__u32__Global__get(const Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key);
bool Map__ast__ast__Ty__u32__Global__contains_key(const Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key);
Option__u32 Map__ast__ast__Ty__u32__Global__remove(Map__ast__ast__Ty__u32__Global *const self, const ast__ast__Ty *const key);
Map__ast__ast__Ty__u32__Global Map__ast__ast__Ty__u32__Global__new(void);
void Map__ast__ast__Ty__u32__Global__free(Map__ast__ast__Ty__u32__Global *const self);
MapKeys__ast__ast__Ty Map__ast__ast__Ty__u32__Global__keys(const Map__ast__ast__Ty__u32__Global *const self);
Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__new_in(Global const alloc);
Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__MonoUse__Global__len(const Vector__ast__ast__MonoUse__Global *const self);
void Vector__ast__ast__MonoUse__Global__reserve(Vector__ast__ast__MonoUse__Global *const self, size_t const additional);
void Vector__ast__ast__MonoUse__Global__push(Vector__ast__ast__MonoUse__Global *const self, ast__ast__MonoUse const value);
const ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__at(const Vector__ast__ast__MonoUse__Global *const self, size_t const index);
Option__ptr_ast__ast__MonoUse Vector__ast__ast__MonoUse__Global__get(const Vector__ast__ast__MonoUse__Global *const self, size_t const index);
void Vector__ast__ast__MonoUse__Global__set(Vector__ast__ast__MonoUse__Global *const self, size_t const index, ast__ast__MonoUse const value);
void Vector__ast__ast__MonoUse__Global__clear(Vector__ast__ast__MonoUse__Global *const self);
void Vector__ast__ast__MonoUse__Global__truncate(Vector__ast__ast__MonoUse__Global *const self, size_t const new_len);
const ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__as_ptr(const Vector__ast__ast__MonoUse__Global *const self);
void Vector__ast__ast__MonoUse__Global__swap(Vector__ast__ast__MonoUse__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__new(void);
void Vector__ast__ast__MonoUse__Global__free(Vector__ast__ast__MonoUse__Global *const self);
Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global__default_(void);
const ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__index(const Vector__ast__ast__MonoUse__Global *const self, size_t const i);
Slice__ast__ast__MonoUse Vector__ast__ast__MonoUse__Global__index_range(const Vector__ast__ast__MonoUse__Global *const self, Range__usize const r);
ast__ast__MonoUse *Vector__ast__ast__MonoUse__Global__index_mut(Vector__ast__ast__MonoUse__Global *const self, size_t const i);
SliceMut__ast__ast__MonoUse Vector__ast__ast__MonoUse__Global__index_range_mut(Vector__ast__ast__MonoUse__Global *const self, Range__usize const r);
Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__new_in(Global const alloc);
Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__TyInstance__Global__len(const Vector__ast__ast__TyInstance__Global *const self);
void Vector__ast__ast__TyInstance__Global__reserve(Vector__ast__ast__TyInstance__Global *const self, size_t const additional);
void Vector__ast__ast__TyInstance__Global__push(Vector__ast__ast__TyInstance__Global *const self, ast__ast__TyInstance const value);
const ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__at(const Vector__ast__ast__TyInstance__Global *const self, size_t const index);
Option__ptr_ast__ast__TyInstance Vector__ast__ast__TyInstance__Global__get(const Vector__ast__ast__TyInstance__Global *const self, size_t const index);
void Vector__ast__ast__TyInstance__Global__set(Vector__ast__ast__TyInstance__Global *const self, size_t const index, ast__ast__TyInstance const value);
void Vector__ast__ast__TyInstance__Global__clear(Vector__ast__ast__TyInstance__Global *const self);
void Vector__ast__ast__TyInstance__Global__truncate(Vector__ast__ast__TyInstance__Global *const self, size_t const new_len);
const ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__as_ptr(const Vector__ast__ast__TyInstance__Global *const self);
void Vector__ast__ast__TyInstance__Global__swap(Vector__ast__ast__TyInstance__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__new(void);
void Vector__ast__ast__TyInstance__Global__free(Vector__ast__ast__TyInstance__Global *const self);
Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global__default_(void);
const ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__index(const Vector__ast__ast__TyInstance__Global *const self, size_t const i);
Slice__ast__ast__TyInstance Vector__ast__ast__TyInstance__Global__index_range(const Vector__ast__ast__TyInstance__Global *const self, Range__usize const r);
ast__ast__TyInstance *Vector__ast__ast__TyInstance__Global__index_mut(Vector__ast__ast__TyInstance__Global *const self, size_t const i);
SliceMut__ast__ast__TyInstance Vector__ast__ast__TyInstance__Global__index_range_mut(Vector__ast__ast__TyInstance__Global *const self, Range__usize const r);
bool Vector__ast__ast__TyInstance__Global__eq(const Vector__ast__ast__TyInstance__Global *const self, const Vector__ast__ast__TyInstance__Global *const other);
uint64_t Vector__ast__ast__TyInstance__Global__hash(const Vector__ast__ast__TyInstance__Global *const self);
Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__new_in(Global const alloc);
Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__MethodInst__Global__len(const Vector__ast__ast__MethodInst__Global *const self);
void Vector__ast__ast__MethodInst__Global__reserve(Vector__ast__ast__MethodInst__Global *const self, size_t const additional);
void Vector__ast__ast__MethodInst__Global__push(Vector__ast__ast__MethodInst__Global *const self, ast__ast__MethodInst const value);
const ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__at(const Vector__ast__ast__MethodInst__Global *const self, size_t const index);
Option__ptr_ast__ast__MethodInst Vector__ast__ast__MethodInst__Global__get(const Vector__ast__ast__MethodInst__Global *const self, size_t const index);
void Vector__ast__ast__MethodInst__Global__set(Vector__ast__ast__MethodInst__Global *const self, size_t const index, ast__ast__MethodInst const value);
void Vector__ast__ast__MethodInst__Global__clear(Vector__ast__ast__MethodInst__Global *const self);
void Vector__ast__ast__MethodInst__Global__truncate(Vector__ast__ast__MethodInst__Global *const self, size_t const new_len);
const ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__as_ptr(const Vector__ast__ast__MethodInst__Global *const self);
void Vector__ast__ast__MethodInst__Global__swap(Vector__ast__ast__MethodInst__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__new(void);
void Vector__ast__ast__MethodInst__Global__free(Vector__ast__ast__MethodInst__Global *const self);
Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global__default_(void);
const ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__index(const Vector__ast__ast__MethodInst__Global *const self, size_t const i);
Slice__ast__ast__MethodInst Vector__ast__ast__MethodInst__Global__index_range(const Vector__ast__ast__MethodInst__Global *const self, Range__usize const r);
ast__ast__MethodInst *Vector__ast__ast__MethodInst__Global__index_mut(Vector__ast__ast__MethodInst__Global *const self, size_t const i);
SliceMut__ast__ast__MethodInst Vector__ast__ast__MethodInst__Global__index_range_mut(Vector__ast__ast__MethodInst__Global *const self, Range__usize const r);
bool Vector__ast__ast__MethodInst__Global__eq(const Vector__ast__ast__MethodInst__Global *const self, const Vector__ast__ast__MethodInst__Global *const other);
uint64_t Vector__ast__ast__MethodInst__Global__hash(const Vector__ast__ast__MethodInst__Global *const self);
Map__ast__ast__TyInstance__u32__Global Map__ast__ast__TyInstance__u32__Global__new_in(Global const alloc);
size_t Map__ast__ast__TyInstance__u32__Global__len(const Map__ast__ast__TyInstance__u32__Global *const self);
bool Map__ast__ast__TyInstance__u32__Global__is_empty(const Map__ast__ast__TyInstance__u32__Global *const self);
void Map__ast__ast__TyInstance__u32__Global__insert(Map__ast__ast__TyInstance__u32__Global *const self, ast__ast__TyInstance const key, uint32_t const value);
Option__ptr_u32 Map__ast__ast__TyInstance__u32__Global__get(const Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key);
bool Map__ast__ast__TyInstance__u32__Global__contains_key(const Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key);
Option__u32 Map__ast__ast__TyInstance__u32__Global__remove(Map__ast__ast__TyInstance__u32__Global *const self, const ast__ast__TyInstance *const key);
Map__ast__ast__TyInstance__u32__Global Map__ast__ast__TyInstance__u32__Global__new(void);
void Map__ast__ast__TyInstance__u32__Global__free(Map__ast__ast__TyInstance__u32__Global *const self);
MapKeys__ast__ast__TyInstance Map__ast__ast__TyInstance__u32__Global__keys(const Map__ast__ast__TyInstance__u32__Global *const self);
Map__ast__ast__MethodInst__u32__Global Map__ast__ast__MethodInst__u32__Global__new_in(Global const alloc);
size_t Map__ast__ast__MethodInst__u32__Global__len(const Map__ast__ast__MethodInst__u32__Global *const self);
bool Map__ast__ast__MethodInst__u32__Global__is_empty(const Map__ast__ast__MethodInst__u32__Global *const self);
void Map__ast__ast__MethodInst__u32__Global__insert(Map__ast__ast__MethodInst__u32__Global *const self, ast__ast__MethodInst const key, uint32_t const value);
Option__ptr_u32 Map__ast__ast__MethodInst__u32__Global__get(const Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key);
bool Map__ast__ast__MethodInst__u32__Global__contains_key(const Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key);
Option__u32 Map__ast__ast__MethodInst__u32__Global__remove(Map__ast__ast__MethodInst__u32__Global *const self, const ast__ast__MethodInst *const key);
Map__ast__ast__MethodInst__u32__Global Map__ast__ast__MethodInst__u32__Global__new(void);
void Map__ast__ast__MethodInst__u32__Global__free(Map__ast__ast__MethodInst__u32__Global *const self);
MapKeys__ast__ast__MethodInst Map__ast__ast__MethodInst__u32__Global__keys(const Map__ast__ast__MethodInst__u32__Global *const self);
Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__new_in(Global const alloc);
Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__DynUse__Global__len(const Vector__ast__ast__DynUse__Global *const self);
void Vector__ast__ast__DynUse__Global__reserve(Vector__ast__ast__DynUse__Global *const self, size_t const additional);
void Vector__ast__ast__DynUse__Global__push(Vector__ast__ast__DynUse__Global *const self, ast__ast__DynUse const value);
const ast__ast__DynUse *Vector__ast__ast__DynUse__Global__at(const Vector__ast__ast__DynUse__Global *const self, size_t const index);
Option__ptr_ast__ast__DynUse Vector__ast__ast__DynUse__Global__get(const Vector__ast__ast__DynUse__Global *const self, size_t const index);
void Vector__ast__ast__DynUse__Global__set(Vector__ast__ast__DynUse__Global *const self, size_t const index, ast__ast__DynUse const value);
void Vector__ast__ast__DynUse__Global__clear(Vector__ast__ast__DynUse__Global *const self);
void Vector__ast__ast__DynUse__Global__truncate(Vector__ast__ast__DynUse__Global *const self, size_t const new_len);
const ast__ast__DynUse *Vector__ast__ast__DynUse__Global__as_ptr(const Vector__ast__ast__DynUse__Global *const self);
void Vector__ast__ast__DynUse__Global__swap(Vector__ast__ast__DynUse__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__new(void);
void Vector__ast__ast__DynUse__Global__free(Vector__ast__ast__DynUse__Global *const self);
Vector__ast__ast__DynUse__Global Vector__ast__ast__DynUse__Global__default_(void);
const ast__ast__DynUse *Vector__ast__ast__DynUse__Global__index(const Vector__ast__ast__DynUse__Global *const self, size_t const i);
Slice__ast__ast__DynUse Vector__ast__ast__DynUse__Global__index_range(const Vector__ast__ast__DynUse__Global *const self, Range__usize const r);
ast__ast__DynUse *Vector__ast__ast__DynUse__Global__index_mut(Vector__ast__ast__DynUse__Global *const self, size_t const i);
SliceMut__ast__ast__DynUse Vector__ast__ast__DynUse__Global__index_range_mut(Vector__ast__ast__DynUse__Global *const self, Range__usize const r);
Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__new_in(Global const alloc);
Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__DerefUse__Global__len(const Vector__ast__ast__DerefUse__Global *const self);
void Vector__ast__ast__DerefUse__Global__reserve(Vector__ast__ast__DerefUse__Global *const self, size_t const additional);
void Vector__ast__ast__DerefUse__Global__push(Vector__ast__ast__DerefUse__Global *const self, ast__ast__DerefUse const value);
const ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__at(const Vector__ast__ast__DerefUse__Global *const self, size_t const index);
Option__ptr_ast__ast__DerefUse Vector__ast__ast__DerefUse__Global__get(const Vector__ast__ast__DerefUse__Global *const self, size_t const index);
void Vector__ast__ast__DerefUse__Global__set(Vector__ast__ast__DerefUse__Global *const self, size_t const index, ast__ast__DerefUse const value);
void Vector__ast__ast__DerefUse__Global__clear(Vector__ast__ast__DerefUse__Global *const self);
void Vector__ast__ast__DerefUse__Global__truncate(Vector__ast__ast__DerefUse__Global *const self, size_t const new_len);
const ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__as_ptr(const Vector__ast__ast__DerefUse__Global *const self);
void Vector__ast__ast__DerefUse__Global__swap(Vector__ast__ast__DerefUse__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__new(void);
void Vector__ast__ast__DerefUse__Global__free(Vector__ast__ast__DerefUse__Global *const self);
Vector__ast__ast__DerefUse__Global Vector__ast__ast__DerefUse__Global__default_(void);
const ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__index(const Vector__ast__ast__DerefUse__Global *const self, size_t const i);
Slice__ast__ast__DerefUse Vector__ast__ast__DerefUse__Global__index_range(const Vector__ast__ast__DerefUse__Global *const self, Range__usize const r);
ast__ast__DerefUse *Vector__ast__ast__DerefUse__Global__index_mut(Vector__ast__ast__DerefUse__Global *const self, size_t const i);
SliceMut__ast__ast__DerefUse Vector__ast__ast__DerefUse__Global__index_range_mut(Vector__ast__ast__DerefUse__Global *const self, Range__usize const r);
Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__new_in(Global const alloc);
Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__ast__ast__Attr__Global__len(const Vector__ast__ast__Attr__Global *const self);
void Vector__ast__ast__Attr__Global__reserve(Vector__ast__ast__Attr__Global *const self, size_t const additional);
void Vector__ast__ast__Attr__Global__push(Vector__ast__ast__Attr__Global *const self, ast__ast__Attr const value);
const ast__ast__Attr *Vector__ast__ast__Attr__Global__at(const Vector__ast__ast__Attr__Global *const self, size_t const index);
Option__ptr_ast__ast__Attr Vector__ast__ast__Attr__Global__get(const Vector__ast__ast__Attr__Global *const self, size_t const index);
void Vector__ast__ast__Attr__Global__set(Vector__ast__ast__Attr__Global *const self, size_t const index, ast__ast__Attr const value);
void Vector__ast__ast__Attr__Global__clear(Vector__ast__ast__Attr__Global *const self);
void Vector__ast__ast__Attr__Global__truncate(Vector__ast__ast__Attr__Global *const self, size_t const new_len);
const ast__ast__Attr *Vector__ast__ast__Attr__Global__as_ptr(const Vector__ast__ast__Attr__Global *const self);
void Vector__ast__ast__Attr__Global__swap(Vector__ast__ast__Attr__Global *const self, size_t const i, size_t const j);
Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__new(void);
void Vector__ast__ast__Attr__Global__free(Vector__ast__ast__Attr__Global *const self);
Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global__default_(void);
const ast__ast__Attr *Vector__ast__ast__Attr__Global__index(const Vector__ast__ast__Attr__Global *const self, size_t const i);
Slice__ast__ast__Attr Vector__ast__ast__Attr__Global__index_range(const Vector__ast__ast__Attr__Global *const self, Range__usize const r);
ast__ast__Attr *Vector__ast__ast__Attr__Global__index_mut(Vector__ast__ast__Attr__Global *const self, size_t const i);
SliceMut__ast__ast__Attr Vector__ast__ast__Attr__Global__index_range_mut(Vector__ast__ast__Attr__Global *const self, Range__usize const r);
Option__ast__ast__Node Option__ast__ast__Node__some(ast__ast__Node const value);
Option__ast__ast__Node Option__ast__ast__Node__none(void);
bool Option__ast__ast__Node__is_some(const Option__ast__ast__Node *const self);
bool Option__ast__ast__Node__is_none(const Option__ast__ast__Node *const self);
Option__ast__ast__Node Option__ast__ast__Node__default_(void);
Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node__some(const ast__ast__Node *const value);
Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node__none(void);
bool Option__ptr_ast__ast__Node__is_some(const Option__ptr_ast__ast__Node *const self);
bool Option__ptr_ast__ast__Node__is_none(const Option__ptr_ast__ast__Node *const self);
Option__ptr_ast__ast__Node Option__ptr_ast__ast__Node__default_(void);
Option__ptr_ast__ast__Node VecIter__ast__ast__Node__next(VecIter__ast__ast__Node *const self);
size_t Slice__ast__ast__Node__len(const Slice__ast__ast__Node *const self);
const ast__ast__Node *Slice__ast__ast__Node__as_ptr(const Slice__ast__ast__Node *const self);
const ast__ast__Node *Slice__ast__ast__Node__index(const Slice__ast__ast__Node *const self, size_t const i);
Slice__ast__ast__Node Slice__ast__ast__Node__index_range(const Slice__ast__ast__Node *const self, Range__usize const r);
size_t SliceMut__ast__ast__Node__len(const SliceMut__ast__ast__Node *const self);
ast__ast__Node *SliceMut__ast__ast__Node__as_mut_ptr(const SliceMut__ast__ast__Node *const self);
const ast__ast__Node *SliceMut__ast__ast__Node__index(const SliceMut__ast__ast__Node *const self, size_t const i);
Slice__ast__ast__Node SliceMut__ast__ast__Node__index_range(const SliceMut__ast__ast__Node *const self, Range__usize const r);
ast__ast__Node *SliceMut__ast__ast__Node__index_mut(SliceMut__ast__ast__Node *const self, size_t const i);
SliceMut__ast__ast__Node SliceMut__ast__ast__Node__index_range_mut(SliceMut__ast__ast__Node *const self, Range__usize const r);
Option__ast__ast__DefId Option__ast__ast__DefId__some(ast__ast__DefId const value);
Option__ast__ast__DefId Option__ast__ast__DefId__none(void);
bool Option__ast__ast__DefId__is_some(const Option__ast__ast__DefId *const self);
bool Option__ast__ast__DefId__is_none(const Option__ast__ast__DefId *const self);
Option__ast__ast__DefId Option__ast__ast__DefId__default_(void);
Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId__some(const ast__ast__DefId *const value);
Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId__none(void);
bool Option__ptr_ast__ast__DefId__is_some(const Option__ptr_ast__ast__DefId *const self);
bool Option__ptr_ast__ast__DefId__is_none(const Option__ptr_ast__ast__DefId *const self);
Option__ptr_ast__ast__DefId Option__ptr_ast__ast__DefId__default_(void);
Option__ptr_ast__ast__DefId VecIter__ast__ast__DefId__next(VecIter__ast__ast__DefId *const self);
size_t Slice__ast__ast__DefId__len(const Slice__ast__ast__DefId *const self);
const ast__ast__DefId *Slice__ast__ast__DefId__as_ptr(const Slice__ast__ast__DefId *const self);
const ast__ast__DefId *Slice__ast__ast__DefId__index(const Slice__ast__ast__DefId *const self, size_t const i);
Slice__ast__ast__DefId Slice__ast__ast__DefId__index_range(const Slice__ast__ast__DefId *const self, Range__usize const r);
size_t SliceMut__ast__ast__DefId__len(const SliceMut__ast__ast__DefId *const self);
ast__ast__DefId *SliceMut__ast__ast__DefId__as_mut_ptr(const SliceMut__ast__ast__DefId *const self);
const ast__ast__DefId *SliceMut__ast__ast__DefId__index(const SliceMut__ast__ast__DefId *const self, size_t const i);
Slice__ast__ast__DefId SliceMut__ast__ast__DefId__index_range(const SliceMut__ast__ast__DefId *const self, Range__usize const r);
ast__ast__DefId *SliceMut__ast__ast__DefId__index_mut(SliceMut__ast__ast__DefId *const self, size_t const i);
SliceMut__ast__ast__DefId SliceMut__ast__ast__DefId__index_range_mut(SliceMut__ast__ast__DefId *const self, Range__usize const r);
Option__ast__ast__Ty Option__ast__ast__Ty__some(ast__ast__Ty const value);
Option__ast__ast__Ty Option__ast__ast__Ty__none(void);
bool Option__ast__ast__Ty__is_some(const Option__ast__ast__Ty *const self);
bool Option__ast__ast__Ty__is_none(const Option__ast__ast__Ty *const self);
Option__ast__ast__Ty Option__ast__ast__Ty__default_(void);
bool Option__ast__ast__Ty__eq(const Option__ast__ast__Ty *const self, const Option__ast__ast__Ty *const other);
uint64_t Option__ast__ast__Ty__hash(const Option__ast__ast__Ty *const self);
Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty__some(const ast__ast__Ty *const value);
Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty__none(void);
bool Option__ptr_ast__ast__Ty__is_some(const Option__ptr_ast__ast__Ty *const self);
bool Option__ptr_ast__ast__Ty__is_none(const Option__ptr_ast__ast__Ty *const self);
Option__ptr_ast__ast__Ty Option__ptr_ast__ast__Ty__default_(void);
Option__ptr_ast__ast__Ty VecIter__ast__ast__Ty__next(VecIter__ast__ast__Ty *const self);
size_t Slice__ast__ast__Ty__len(const Slice__ast__ast__Ty *const self);
const ast__ast__Ty *Slice__ast__ast__Ty__as_ptr(const Slice__ast__ast__Ty *const self);
const ast__ast__Ty *Slice__ast__ast__Ty__index(const Slice__ast__ast__Ty *const self, size_t const i);
Slice__ast__ast__Ty Slice__ast__ast__Ty__index_range(const Slice__ast__ast__Ty *const self, Range__usize const r);
size_t SliceMut__ast__ast__Ty__len(const SliceMut__ast__ast__Ty *const self);
ast__ast__Ty *SliceMut__ast__ast__Ty__as_mut_ptr(const SliceMut__ast__ast__Ty *const self);
const ast__ast__Ty *SliceMut__ast__ast__Ty__index(const SliceMut__ast__ast__Ty *const self, size_t const i);
Slice__ast__ast__Ty SliceMut__ast__ast__Ty__index_range(const SliceMut__ast__ast__Ty *const self, Range__usize const r);
ast__ast__Ty *SliceMut__ast__ast__Ty__index_mut(SliceMut__ast__ast__Ty *const self, size_t const i);
SliceMut__ast__ast__Ty SliceMut__ast__ast__Ty__index_range_mut(SliceMut__ast__ast__Ty *const self, Range__usize const r);
Option__ptr_ast__ast__Ty MapKeys__ast__ast__Ty__next(MapKeys__ast__ast__Ty *const self);
Option__ast__ast__MonoUse Option__ast__ast__MonoUse__some(ast__ast__MonoUse const value);
Option__ast__ast__MonoUse Option__ast__ast__MonoUse__none(void);
bool Option__ast__ast__MonoUse__is_some(const Option__ast__ast__MonoUse *const self);
bool Option__ast__ast__MonoUse__is_none(const Option__ast__ast__MonoUse *const self);
Option__ast__ast__MonoUse Option__ast__ast__MonoUse__default_(void);
Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse__some(const ast__ast__MonoUse *const value);
Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse__none(void);
bool Option__ptr_ast__ast__MonoUse__is_some(const Option__ptr_ast__ast__MonoUse *const self);
bool Option__ptr_ast__ast__MonoUse__is_none(const Option__ptr_ast__ast__MonoUse *const self);
Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse__default_(void);
Option__ptr_ast__ast__MonoUse VecIter__ast__ast__MonoUse__next(VecIter__ast__ast__MonoUse *const self);
size_t Slice__ast__ast__MonoUse__len(const Slice__ast__ast__MonoUse *const self);
const ast__ast__MonoUse *Slice__ast__ast__MonoUse__as_ptr(const Slice__ast__ast__MonoUse *const self);
const ast__ast__MonoUse *Slice__ast__ast__MonoUse__index(const Slice__ast__ast__MonoUse *const self, size_t const i);
Slice__ast__ast__MonoUse Slice__ast__ast__MonoUse__index_range(const Slice__ast__ast__MonoUse *const self, Range__usize const r);
size_t SliceMut__ast__ast__MonoUse__len(const SliceMut__ast__ast__MonoUse *const self);
ast__ast__MonoUse *SliceMut__ast__ast__MonoUse__as_mut_ptr(const SliceMut__ast__ast__MonoUse *const self);
const ast__ast__MonoUse *SliceMut__ast__ast__MonoUse__index(const SliceMut__ast__ast__MonoUse *const self, size_t const i);
Slice__ast__ast__MonoUse SliceMut__ast__ast__MonoUse__index_range(const SliceMut__ast__ast__MonoUse *const self, Range__usize const r);
ast__ast__MonoUse *SliceMut__ast__ast__MonoUse__index_mut(SliceMut__ast__ast__MonoUse *const self, size_t const i);
SliceMut__ast__ast__MonoUse SliceMut__ast__ast__MonoUse__index_range_mut(SliceMut__ast__ast__MonoUse *const self, Range__usize const r);
Option__ast__ast__TyInstance Option__ast__ast__TyInstance__some(ast__ast__TyInstance const value);
Option__ast__ast__TyInstance Option__ast__ast__TyInstance__none(void);
bool Option__ast__ast__TyInstance__is_some(const Option__ast__ast__TyInstance *const self);
bool Option__ast__ast__TyInstance__is_none(const Option__ast__ast__TyInstance *const self);
Option__ast__ast__TyInstance Option__ast__ast__TyInstance__default_(void);
bool Option__ast__ast__TyInstance__eq(const Option__ast__ast__TyInstance *const self, const Option__ast__ast__TyInstance *const other);
uint64_t Option__ast__ast__TyInstance__hash(const Option__ast__ast__TyInstance *const self);
Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance__some(const ast__ast__TyInstance *const value);
Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance__none(void);
bool Option__ptr_ast__ast__TyInstance__is_some(const Option__ptr_ast__ast__TyInstance *const self);
bool Option__ptr_ast__ast__TyInstance__is_none(const Option__ptr_ast__ast__TyInstance *const self);
Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance__default_(void);
Option__ptr_ast__ast__TyInstance VecIter__ast__ast__TyInstance__next(VecIter__ast__ast__TyInstance *const self);
size_t Slice__ast__ast__TyInstance__len(const Slice__ast__ast__TyInstance *const self);
const ast__ast__TyInstance *Slice__ast__ast__TyInstance__as_ptr(const Slice__ast__ast__TyInstance *const self);
const ast__ast__TyInstance *Slice__ast__ast__TyInstance__index(const Slice__ast__ast__TyInstance *const self, size_t const i);
Slice__ast__ast__TyInstance Slice__ast__ast__TyInstance__index_range(const Slice__ast__ast__TyInstance *const self, Range__usize const r);
size_t SliceMut__ast__ast__TyInstance__len(const SliceMut__ast__ast__TyInstance *const self);
ast__ast__TyInstance *SliceMut__ast__ast__TyInstance__as_mut_ptr(const SliceMut__ast__ast__TyInstance *const self);
const ast__ast__TyInstance *SliceMut__ast__ast__TyInstance__index(const SliceMut__ast__ast__TyInstance *const self, size_t const i);
Slice__ast__ast__TyInstance SliceMut__ast__ast__TyInstance__index_range(const SliceMut__ast__ast__TyInstance *const self, Range__usize const r);
ast__ast__TyInstance *SliceMut__ast__ast__TyInstance__index_mut(SliceMut__ast__ast__TyInstance *const self, size_t const i);
SliceMut__ast__ast__TyInstance SliceMut__ast__ast__TyInstance__index_range_mut(SliceMut__ast__ast__TyInstance *const self, Range__usize const r);
Option__ast__ast__MethodInst Option__ast__ast__MethodInst__some(ast__ast__MethodInst const value);
Option__ast__ast__MethodInst Option__ast__ast__MethodInst__none(void);
bool Option__ast__ast__MethodInst__is_some(const Option__ast__ast__MethodInst *const self);
bool Option__ast__ast__MethodInst__is_none(const Option__ast__ast__MethodInst *const self);
Option__ast__ast__MethodInst Option__ast__ast__MethodInst__default_(void);
bool Option__ast__ast__MethodInst__eq(const Option__ast__ast__MethodInst *const self, const Option__ast__ast__MethodInst *const other);
uint64_t Option__ast__ast__MethodInst__hash(const Option__ast__ast__MethodInst *const self);
Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst__some(const ast__ast__MethodInst *const value);
Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst__none(void);
bool Option__ptr_ast__ast__MethodInst__is_some(const Option__ptr_ast__ast__MethodInst *const self);
bool Option__ptr_ast__ast__MethodInst__is_none(const Option__ptr_ast__ast__MethodInst *const self);
Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst__default_(void);
Option__ptr_ast__ast__MethodInst VecIter__ast__ast__MethodInst__next(VecIter__ast__ast__MethodInst *const self);
size_t Slice__ast__ast__MethodInst__len(const Slice__ast__ast__MethodInst *const self);
const ast__ast__MethodInst *Slice__ast__ast__MethodInst__as_ptr(const Slice__ast__ast__MethodInst *const self);
const ast__ast__MethodInst *Slice__ast__ast__MethodInst__index(const Slice__ast__ast__MethodInst *const self, size_t const i);
Slice__ast__ast__MethodInst Slice__ast__ast__MethodInst__index_range(const Slice__ast__ast__MethodInst *const self, Range__usize const r);
size_t SliceMut__ast__ast__MethodInst__len(const SliceMut__ast__ast__MethodInst *const self);
ast__ast__MethodInst *SliceMut__ast__ast__MethodInst__as_mut_ptr(const SliceMut__ast__ast__MethodInst *const self);
const ast__ast__MethodInst *SliceMut__ast__ast__MethodInst__index(const SliceMut__ast__ast__MethodInst *const self, size_t const i);
Slice__ast__ast__MethodInst SliceMut__ast__ast__MethodInst__index_range(const SliceMut__ast__ast__MethodInst *const self, Range__usize const r);
ast__ast__MethodInst *SliceMut__ast__ast__MethodInst__index_mut(SliceMut__ast__ast__MethodInst *const self, size_t const i);
SliceMut__ast__ast__MethodInst SliceMut__ast__ast__MethodInst__index_range_mut(SliceMut__ast__ast__MethodInst *const self, Range__usize const r);
Option__ptr_ast__ast__TyInstance MapKeys__ast__ast__TyInstance__next(MapKeys__ast__ast__TyInstance *const self);
Option__ptr_ast__ast__MethodInst MapKeys__ast__ast__MethodInst__next(MapKeys__ast__ast__MethodInst *const self);
Option__ast__ast__DynUse Option__ast__ast__DynUse__some(ast__ast__DynUse const value);
Option__ast__ast__DynUse Option__ast__ast__DynUse__none(void);
bool Option__ast__ast__DynUse__is_some(const Option__ast__ast__DynUse *const self);
bool Option__ast__ast__DynUse__is_none(const Option__ast__ast__DynUse *const self);
Option__ast__ast__DynUse Option__ast__ast__DynUse__default_(void);
Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse__some(const ast__ast__DynUse *const value);
Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse__none(void);
bool Option__ptr_ast__ast__DynUse__is_some(const Option__ptr_ast__ast__DynUse *const self);
bool Option__ptr_ast__ast__DynUse__is_none(const Option__ptr_ast__ast__DynUse *const self);
Option__ptr_ast__ast__DynUse Option__ptr_ast__ast__DynUse__default_(void);
Option__ptr_ast__ast__DynUse VecIter__ast__ast__DynUse__next(VecIter__ast__ast__DynUse *const self);
size_t Slice__ast__ast__DynUse__len(const Slice__ast__ast__DynUse *const self);
const ast__ast__DynUse *Slice__ast__ast__DynUse__as_ptr(const Slice__ast__ast__DynUse *const self);
const ast__ast__DynUse *Slice__ast__ast__DynUse__index(const Slice__ast__ast__DynUse *const self, size_t const i);
Slice__ast__ast__DynUse Slice__ast__ast__DynUse__index_range(const Slice__ast__ast__DynUse *const self, Range__usize const r);
size_t SliceMut__ast__ast__DynUse__len(const SliceMut__ast__ast__DynUse *const self);
ast__ast__DynUse *SliceMut__ast__ast__DynUse__as_mut_ptr(const SliceMut__ast__ast__DynUse *const self);
const ast__ast__DynUse *SliceMut__ast__ast__DynUse__index(const SliceMut__ast__ast__DynUse *const self, size_t const i);
Slice__ast__ast__DynUse SliceMut__ast__ast__DynUse__index_range(const SliceMut__ast__ast__DynUse *const self, Range__usize const r);
ast__ast__DynUse *SliceMut__ast__ast__DynUse__index_mut(SliceMut__ast__ast__DynUse *const self, size_t const i);
SliceMut__ast__ast__DynUse SliceMut__ast__ast__DynUse__index_range_mut(SliceMut__ast__ast__DynUse *const self, Range__usize const r);
Option__ast__ast__DerefUse Option__ast__ast__DerefUse__some(ast__ast__DerefUse const value);
Option__ast__ast__DerefUse Option__ast__ast__DerefUse__none(void);
bool Option__ast__ast__DerefUse__is_some(const Option__ast__ast__DerefUse *const self);
bool Option__ast__ast__DerefUse__is_none(const Option__ast__ast__DerefUse *const self);
Option__ast__ast__DerefUse Option__ast__ast__DerefUse__default_(void);
Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse__some(const ast__ast__DerefUse *const value);
Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse__none(void);
bool Option__ptr_ast__ast__DerefUse__is_some(const Option__ptr_ast__ast__DerefUse *const self);
bool Option__ptr_ast__ast__DerefUse__is_none(const Option__ptr_ast__ast__DerefUse *const self);
Option__ptr_ast__ast__DerefUse Option__ptr_ast__ast__DerefUse__default_(void);
Option__ptr_ast__ast__DerefUse VecIter__ast__ast__DerefUse__next(VecIter__ast__ast__DerefUse *const self);
size_t Slice__ast__ast__DerefUse__len(const Slice__ast__ast__DerefUse *const self);
const ast__ast__DerefUse *Slice__ast__ast__DerefUse__as_ptr(const Slice__ast__ast__DerefUse *const self);
const ast__ast__DerefUse *Slice__ast__ast__DerefUse__index(const Slice__ast__ast__DerefUse *const self, size_t const i);
Slice__ast__ast__DerefUse Slice__ast__ast__DerefUse__index_range(const Slice__ast__ast__DerefUse *const self, Range__usize const r);
size_t SliceMut__ast__ast__DerefUse__len(const SliceMut__ast__ast__DerefUse *const self);
ast__ast__DerefUse *SliceMut__ast__ast__DerefUse__as_mut_ptr(const SliceMut__ast__ast__DerefUse *const self);
const ast__ast__DerefUse *SliceMut__ast__ast__DerefUse__index(const SliceMut__ast__ast__DerefUse *const self, size_t const i);
Slice__ast__ast__DerefUse SliceMut__ast__ast__DerefUse__index_range(const SliceMut__ast__ast__DerefUse *const self, Range__usize const r);
ast__ast__DerefUse *SliceMut__ast__ast__DerefUse__index_mut(SliceMut__ast__ast__DerefUse *const self, size_t const i);
SliceMut__ast__ast__DerefUse SliceMut__ast__ast__DerefUse__index_range_mut(SliceMut__ast__ast__DerefUse *const self, Range__usize const r);
Option__ast__ast__Attr Option__ast__ast__Attr__some(ast__ast__Attr const value);
Option__ast__ast__Attr Option__ast__ast__Attr__none(void);
bool Option__ast__ast__Attr__is_some(const Option__ast__ast__Attr *const self);
bool Option__ast__ast__Attr__is_none(const Option__ast__ast__Attr *const self);
Option__ast__ast__Attr Option__ast__ast__Attr__default_(void);
Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr__some(const ast__ast__Attr *const value);
Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr__none(void);
bool Option__ptr_ast__ast__Attr__is_some(const Option__ptr_ast__ast__Attr *const self);
bool Option__ptr_ast__ast__Attr__is_none(const Option__ptr_ast__ast__Attr *const self);
Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr__default_(void);
Option__ptr_ast__ast__Attr VecIter__ast__ast__Attr__next(VecIter__ast__ast__Attr *const self);
size_t Slice__ast__ast__Attr__len(const Slice__ast__ast__Attr *const self);
const ast__ast__Attr *Slice__ast__ast__Attr__as_ptr(const Slice__ast__ast__Attr *const self);
const ast__ast__Attr *Slice__ast__ast__Attr__index(const Slice__ast__ast__Attr *const self, size_t const i);
Slice__ast__ast__Attr Slice__ast__ast__Attr__index_range(const Slice__ast__ast__Attr *const self, Range__usize const r);
size_t SliceMut__ast__ast__Attr__len(const SliceMut__ast__ast__Attr *const self);
ast__ast__Attr *SliceMut__ast__ast__Attr__as_mut_ptr(const SliceMut__ast__ast__Attr *const self);
const ast__ast__Attr *SliceMut__ast__ast__Attr__index(const SliceMut__ast__ast__Attr *const self, size_t const i);
Slice__ast__ast__Attr SliceMut__ast__ast__Attr__index_range(const SliceMut__ast__ast__Attr *const self, Range__usize const r);
ast__ast__Attr *SliceMut__ast__ast__Attr__index_mut(SliceMut__ast__ast__Attr *const self, size_t const i);
SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr__index_range_mut(SliceMut__ast__ast__Attr *const self, Range__usize const r);
Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global__new_in(Global const alloc);
size_t Map__u64__ast__ast__DefId__Global__len(const Map__u64__ast__ast__DefId__Global *const self);
bool Map__u64__ast__ast__DefId__Global__is_empty(const Map__u64__ast__ast__DefId__Global *const self);
void Map__u64__ast__ast__DefId__Global__insert(Map__u64__ast__ast__DefId__Global *const self, uint64_t const key, ast__ast__DefId const value);
Option__ptr_ast__ast__DefId Map__u64__ast__ast__DefId__Global__get(const Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key);
bool Map__u64__ast__ast__DefId__Global__contains_key(const Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key);
Option__ast__ast__DefId Map__u64__ast__ast__DefId__Global__remove(Map__u64__ast__ast__DefId__Global *const self, const uint64_t *const key);
Map__u64__ast__ast__DefId__Global Map__u64__ast__ast__DefId__Global__new(void);
void Map__u64__ast__ast__DefId__Global__free(Map__u64__ast__ast__DefId__Global *const self);
MapKeys__u64 Map__u64__ast__ast__DefId__Global__keys(const Map__u64__ast__ast__DefId__Global *const self);
Option__ptr_ast__ast__DefId MapValues__ast__ast__DefId__next(MapValues__ast__ast__DefId *const self);

__attribute__((unused)) static const uint32_t ast__ast__NODE_NONE = 0U;
__attribute__((unused)) static const uint8_t ast__ast__VA_START = 0U;
__attribute__((unused)) static const uint8_t ast__ast__VA_ARG = 1U;
__attribute__((unused)) static const uint8_t ast__ast__VA_END = 2U;
__attribute__((unused)) static const uint32_t ast__ast__TYPE_NONE = 0U;

#endif
