#ifndef SUPER_MAIN_H
#define SUPER_MAIN_H

#include "super_rt.h"
typedef struct module__loader__Package module__loader__Package;
typedef struct ast__ast__Ast ast__ast__Ast;
typedef struct module__loader__Module module__loader__Module;
typedef struct Global Global;
typedef struct Vector__module__loader__Module__Global Vector__module__loader__Module__Global;
typedef struct str str;
typedef struct String__Global String__Global;
typedef struct Vector__String__Global__Global Vector__String__Global__Global;
typedef struct ast__ast__Ty ast__ast__Ty;
#ifndef SUPER_ENUM_ast__ast__TypeKind
#define SUPER_ENUM_ast__ast__TypeKind
typedef enum { ast__ast__TypeKind_TYPE_ERROR, ast__ast__TypeKind_TYPE_BUILTIN, ast__ast__TypeKind_TYPE_POINTER, ast__ast__TypeKind_TYPE_REFERENCE, ast__ast__TypeKind_TYPE_SLICE, ast__ast__TypeKind_TYPE_ARRAY, ast__ast__TypeKind_TYPE_FUNCTION, ast__ast__TypeKind_TYPE_STRUCT, ast__ast__TypeKind_TYPE_ENUM, ast__ast__TypeKind_TYPE_GENERIC, ast__ast__TypeKind_TYPE_INSTANCE, ast__ast__TypeKind_TYPE_OPAQUE, ast__ast__TypeKind_TYPE_DYN, ast__ast__TypeKind_TYPE_NEVER, ast__ast__TypeKind_TYPE_CONST } ast__ast__TypeKind;
#endif
typedef union ast__ast__TyAs ast__ast__TyAs;
typedef struct ast__ast__TyInstance ast__ast__TyInstance;
typedef struct ast__ast__DefId ast__ast__DefId;
typedef struct Vector__ast__ast__DefId__Global Vector__ast__ast__DefId__Global;
typedef struct Vector__ast__ast__Ty__Global Vector__ast__ast__Ty__Global;
typedef struct Vector__ast__ast__TyInstance__Global Vector__ast__ast__TyInstance__Global;
typedef struct ast__ast__MonoUse ast__ast__MonoUse;
typedef struct Vector__ast__ast__MonoUse__Global Vector__ast__ast__MonoUse__Global;
typedef struct ast__ast__MethodInst ast__ast__MethodInst;
typedef struct Vector__ast__ast__MethodInst__Global Vector__ast__ast__MethodInst__Global;
typedef struct resolver__resolver__Resolver resolver__resolver__Resolver;
typedef struct typechecker__typechecker__TypeChecker typechecker__typechecker__TypeChecker;
typedef struct ast__ast__Node ast__ast__Node;
typedef struct lexer__token__Span lexer__token__Span;
typedef struct utils__errors__Errors utils__errors__Errors;
typedef struct ast__ast__Attr ast__ast__Attr;
typedef struct Vector__ast__ast__Attr__Global Vector__ast__ast__Attr__Global;
#ifndef SUPER_ENUM_ast__ast__AttrKind
#define SUPER_ENUM_ast__ast__AttrKind
typedef enum { ast__ast__AttrKind_ATTR_INLINE, ast__ast__AttrKind_ATTR_ALWAYS_INLINE, ast__ast__AttrKind_ATTR_NOINLINE, ast__ast__AttrKind_ATTR_NORETURN, ast__ast__AttrKind_ATTR_ALIGN, ast__ast__AttrKind_ATTR_PACKED, ast__ast__AttrKind_ATTR_EXPORT, ast__ast__AttrKind_ATTR_IMPORT, ast__ast__AttrKind_ATTR_SECTION, ast__ast__AttrKind_ATTR_USED, ast__ast__AttrKind_ATTR_UNUSED, ast__ast__AttrKind_ATTR_EMIT_MACRO, ast__ast__AttrKind_ATTR_TEST, ast__ast__AttrKind_ATTR_TEST_INIT, ast__ast__AttrKind_ATTR_TEST_FREE, ast__ast__AttrKind_ATTR_C_SOURCE, ast__ast__AttrKind_ATTR_C_LINK, ast__ast__AttrKind_ATTR_COLD, ast__ast__AttrKind_ATTR_PLATFORM } ast__ast__AttrKind;
#endif
typedef union ast__ast__NodeAs ast__ast__NodeAs;
typedef struct ast__ast__ProgramData ast__ast__ProgramData;
typedef struct ast__ast__NodeList ast__ast__NodeList;
#ifndef SUPER_ENUM_ast__ast__NodeKind
#define SUPER_ENUM_ast__ast__NodeKind
typedef enum { ast__ast__NodeKind_NODE_NONE_KIND, ast__ast__NodeKind_NODE_PROGRAM, ast__ast__NodeKind_NODE_IDENTIFIER, ast__ast__NodeKind_NODE_LITERAL, ast__ast__NodeKind_NODE_FUNCTION, ast__ast__NodeKind_NODE_PARAMETER, ast__ast__NodeKind_NODE_STRUCT, ast__ast__NodeKind_NODE_FIELD, ast__ast__NodeKind_NODE_ENUM, ast__ast__NodeKind_NODE_VARIANT, ast__ast__NodeKind_NODE_INTERFACE, ast__ast__NodeKind_NODE_EXTEND, ast__ast__NodeKind_NODE_TYPE_ALIAS, ast__ast__NodeKind_NODE_CONST, ast__ast__NodeKind_NODE_STATIC_ASSERT, ast__ast__NodeKind_NODE_EXTERN_BLOCK, ast__ast__NodeKind_NODE_IMPORT, ast__ast__NodeKind_NODE_GENERIC_PARAM, ast__ast__NodeKind_NODE_WHERE_PREDICATE, ast__ast__NodeKind_NODE_TYPE_PATH, ast__ast__NodeKind_NODE_POINTER_TYPE, ast__ast__NodeKind_NODE_REFERENCE_TYPE, ast__ast__NodeKind_NODE_SLICE_TYPE, ast__ast__NodeKind_NODE_ARRAY_TYPE, ast__ast__NodeKind_NODE_FUNCTION_TYPE, ast__ast__NodeKind_NODE_DYN_TYPE, ast__ast__NodeKind_NODE_BLOCK, ast__ast__NodeKind_NODE_LET, ast__ast__NodeKind_NODE_RETURN, ast__ast__NodeKind_NODE_BREAK, ast__ast__NodeKind_NODE_CONTINUE, ast__ast__NodeKind_NODE_DEFER, ast__ast__NodeKind_NODE_IF, ast__ast__NodeKind_NODE_WHILE, ast__ast__NodeKind_NODE_FOR, ast__ast__NodeKind_NODE_EXPRESSION_STATEMENT, ast__ast__NodeKind_NODE_UNARY, ast__ast__NodeKind_NODE_BINARY, ast__ast__NodeKind_NODE_ASSIGNMENT, ast__ast__NodeKind_NODE_CALL, ast__ast__NodeKind_NODE_CLOSURE, ast__ast__NodeKind_NODE_INDEX, ast__ast__NodeKind_NODE_MEMBER, ast__ast__NodeKind_NODE_CAST, ast__ast__NodeKind_NODE_GENERIC_SPECIALIZATION, ast__ast__NodeKind_NODE_MATCH, ast__ast__NodeKind_NODE_MATCH_ARM, ast__ast__NodeKind_NODE_NEW, ast__ast__NodeKind_NODE_SIZEOF, ast__ast__NodeKind_NODE_ALIGNOF, ast__ast__NodeKind_NODE_VA_EXPR, ast__ast__NodeKind_NODE_ARRAY_LITERAL, ast__ast__NodeKind_NODE_STRUCT_INITIALIZER, ast__ast__NodeKind_NODE_FIELD_INITIALIZER, ast__ast__NodeKind_NODE_PATTERN_WILDCARD, ast__ast__NodeKind_NODE_PATTERN_LITERAL, ast__ast__NodeKind_NODE_PATTERN_NAME, ast__ast__NodeKind_NODE_PATTERN_TUPLE, ast__ast__NodeKind_NODE_PATTERN_STRUCT, ast__ast__NodeKind_NODE_PATTERN_FIELD, ast__ast__NodeKind_NODE_PATTERN_RANGE, ast__ast__NodeKind_NODE_PATTERN_OR, ast__ast__NodeKind_NODE_RANGE, ast__ast__NodeKind_NODE_TUPLE, ast__ast__NodeKind_NODE_TUPLE_TYPE, ast__ast__NodeKind_NODE_KIND_COUNT } ast__ast__NodeKind;
#endif
typedef struct ast__ast__ExternBlockData ast__ast__ExternBlockData;
typedef struct Vector__main__TestCase__Global Vector__main__TestCase__Global;
typedef struct Vector__u32__Global Vector__u32__Global;
typedef struct Vector__bool__Global Vector__bool__Global;
typedef struct Vector__main__TestSuite__Global Vector__main__TestSuite__Global;
typedef struct ast__ast__AggregateData ast__ast__AggregateData;
typedef struct ast__ast__FunctionData ast__ast__FunctionData;
typedef struct ast__ast__ParameterData ast__ast__ParameterData;
typedef struct ast__ast__NameData ast__ast__NameData;
typedef struct ast__ast__IndirectTypeData ast__ast__IndirectTypeData;
#ifndef SUPER_ENUM_ast__ast__TypeQualifier
#define SUPER_ENUM_ast__ast__TypeQualifier
typedef enum { ast__ast__TypeQualifier_TYPE_QUAL_NONE, ast__ast__TypeQualifier_TYPE_QUAL_CONST, ast__ast__TypeQualifier_TYPE_QUAL_MUT } ast__ast__TypeQualifier;
#endif
typedef struct ast__ast__ExtendData ast__ast__ExtendData;
typedef struct Option__String__Global Option__String__Global;
typedef struct Option Option;
typedef struct codegen__codegen__CgTestCase codegen__codegen__CgTestCase;
typedef struct consteval__consteval__ConstEval consteval__consteval__ConstEval;
typedef struct codegen__codegen__Codegen codegen__codegen__Codegen;
typedef struct codegen__codegen__CgTestInfo codegen__codegen__CgTestInfo;
typedef struct Vector__str__Global Vector__str__Global;
typedef struct Option__module__loader__Module Option__module__loader__Module;
typedef struct Option__ptr_module__loader__Module Option__ptr_module__loader__Module;
typedef struct Option__usize Option__usize;
typedef struct Result__usize__usize Result__usize__usize;
typedef struct VecIter__module__loader__Module VecIter__module__loader__Module;
typedef struct Range__usize Range__usize;
typedef struct Slice__module__loader__Module Slice__module__loader__Module;
typedef struct SliceMut__module__loader__Module SliceMut__module__loader__Module;
typedef struct Bytes Bytes;
typedef struct Chars Chars;
typedef struct Split Split;
typedef struct Lines Lines;
typedef struct Slice__u8 Slice__u8;
typedef struct Option__ptr_String__Global Option__ptr_String__Global;
typedef struct VecIter__String__Global VecIter__String__Global;
typedef struct Slice__String__Global Slice__String__Global;
typedef struct SliceMut__String__Global SliceMut__String__Global;
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
typedef struct Option__ast__ast__TyInstance Option__ast__ast__TyInstance;
typedef struct Option__ptr_ast__ast__TyInstance Option__ptr_ast__ast__TyInstance;
typedef struct VecIter__ast__ast__TyInstance VecIter__ast__ast__TyInstance;
typedef struct Slice__ast__ast__TyInstance Slice__ast__ast__TyInstance;
typedef struct SliceMut__ast__ast__TyInstance SliceMut__ast__ast__TyInstance;
typedef struct Option__ast__ast__MonoUse Option__ast__ast__MonoUse;
typedef struct Option__ptr_ast__ast__MonoUse Option__ptr_ast__ast__MonoUse;
typedef struct VecIter__ast__ast__MonoUse VecIter__ast__ast__MonoUse;
typedef struct Slice__ast__ast__MonoUse Slice__ast__ast__MonoUse;
typedef struct SliceMut__ast__ast__MonoUse SliceMut__ast__ast__MonoUse;
typedef struct Option__ast__ast__MethodInst Option__ast__ast__MethodInst;
typedef struct Option__ptr_ast__ast__MethodInst Option__ptr_ast__ast__MethodInst;
typedef struct VecIter__ast__ast__MethodInst VecIter__ast__ast__MethodInst;
typedef struct Slice__ast__ast__MethodInst Slice__ast__ast__MethodInst;
typedef struct SliceMut__ast__ast__MethodInst SliceMut__ast__ast__MethodInst;
typedef struct Option__ast__ast__Attr Option__ast__ast__Attr;
typedef struct Option__ptr_ast__ast__Attr Option__ptr_ast__ast__Attr;
typedef struct VecIter__ast__ast__Attr VecIter__ast__ast__Attr;
typedef struct Slice__ast__ast__Attr Slice__ast__ast__Attr;
typedef struct SliceMut__ast__ast__Attr SliceMut__ast__ast__Attr;
typedef struct Option__main__TestCase Option__main__TestCase;
typedef struct Option__ptr_main__TestCase Option__ptr_main__TestCase;
typedef struct VecIter__main__TestCase VecIter__main__TestCase;
typedef struct Slice__main__TestCase Slice__main__TestCase;
typedef struct SliceMut__main__TestCase SliceMut__main__TestCase;
typedef struct Option__u32 Option__u32;
typedef struct Option__ptr_u32 Option__ptr_u32;
typedef struct VecIter__u32 VecIter__u32;
typedef struct Slice__u32 Slice__u32;
typedef struct SliceMut__u32 SliceMut__u32;
typedef struct Option__bool Option__bool;
typedef struct Option__ptr_bool Option__ptr_bool;
typedef struct VecIter__bool VecIter__bool;
typedef struct Slice__bool Slice__bool;
typedef struct SliceMut__bool SliceMut__bool;
typedef struct Option__main__TestSuite Option__main__TestSuite;
typedef struct Option__ptr_main__TestSuite Option__ptr_main__TestSuite;
typedef struct VecIter__main__TestSuite VecIter__main__TestSuite;
typedef struct Slice__main__TestSuite Slice__main__TestSuite;
typedef struct SliceMut__main__TestSuite SliceMut__main__TestSuite;
typedef struct Option__str Option__str;
typedef struct Option__ptr_str Option__ptr_str;
typedef struct VecIter__str VecIter__str;
typedef struct Slice__str Slice__str;
typedef struct SliceMut__str SliceMut__str;
typedef struct Option__ptr_u8 Option__ptr_u8;
#include "ast/ast.h"
#include "codegen/codegen.h"
#include "__std/interfaces.h"
#include "__std/option.h"
#include "__std/slice.h"
#include "__std/vector.h"

typedef struct main__TestOpts main__TestOpts;
typedef struct main__PathBuf main__PathBuf;
typedef struct main__Buf64 main__Buf64;
typedef struct main__Buf128 main__Buf128;
typedef struct main__TestCase main__TestCase;
typedef struct main__TestSuite main__TestSuite;
typedef struct main__TestPlan main__TestPlan;
typedef struct main__TCases main__TCases;
typedef struct Vector__main__TestCase__Global Vector__main__TestCase__Global;
typedef struct Vector__main__TestSuite__Global Vector__main__TestSuite__Global;
typedef struct Option__main__TestCase Option__main__TestCase;
typedef struct Option__ptr_main__TestCase Option__ptr_main__TestCase;
typedef struct VecIter__main__TestCase VecIter__main__TestCase;
typedef struct Slice__main__TestCase Slice__main__TestCase;
typedef struct SliceMut__main__TestCase SliceMut__main__TestCase;
typedef struct Option__main__TestSuite Option__main__TestSuite;
typedef struct Option__ptr_main__TestSuite Option__ptr_main__TestSuite;
typedef struct VecIter__main__TestSuite VecIter__main__TestSuite;
typedef struct Slice__main__TestSuite Slice__main__TestSuite;
typedef struct SliceMut__main__TestSuite SliceMut__main__TestSuite;

struct main__TestOpts {
  bool enabled;
  int32_t jobs;
  bool no_fork;
  const char *filter;
};
struct main__PathBuf {
  char b[4096];
};
struct main__Buf64 {
  char b[64];
};
struct main__Buf128 {
  char b[128];
};
struct main__TestCase {
  uint16_t mod;
  uint32_t func;
  bool should_panic;
  uint8_t wants;
  ast__ast__DefId suite;
  bool suite_is_enum;
  uint32_t suite_init;
  uint32_t suite_free;
};
struct main__TestSuite {
  uint16_t mod;
  ast__ast__DefId ty;
  bool is_enum;
  uint32_t init;
  uint32_t fre;
};
struct Vector__main__TestCase__Global {
  main__TestCase *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct Vector__main__TestSuite__Global {
  main__TestSuite *ptr;
  size_t len;
  size_t cap;
  Global alloc;
};
struct main__TestPlan {
  Vector__main__TestCase__Global cases;
  Vector__u32__Global fx_init;
  Vector__u32__Global fx_free;
  Vector__ast__ast__DefId__Global fx_type;
  Vector__bool__Global fx_is_enum;
  Vector__main__TestSuite__Global suites;
  uint16_t genv_mod;
  uint32_t genv_init;
  uint32_t genv_free;
  ast__ast__DefId genv_type;
  bool genv_is_enum;
  bool ok;
};
struct main__TCases {
  codegen__codegen__CgTestCase c[512];
};
struct Option__main__TestCase {
  OptionTag tag;
  union {
    struct { main__TestCase _0; } Some;
  } payload;
};
struct Option__ptr_main__TestCase {
  OptionTag tag;
  union {
    struct { const main__TestCase *_0; } Some;
  } payload;
};
struct VecIter__main__TestCase {
  const main__TestCase *data;
  size_t idx;
  size_t stop;
};
struct Slice__main__TestCase {
  const main__TestCase *ptr;
  size_t len;
};
struct SliceMut__main__TestCase {
  main__TestCase *ptr;
  size_t len;
};
struct Option__main__TestSuite {
  OptionTag tag;
  union {
    struct { main__TestSuite _0; } Some;
  } payload;
};
struct Option__ptr_main__TestSuite {
  OptionTag tag;
  union {
    struct { const main__TestSuite *_0; } Some;
  } payload;
};
struct VecIter__main__TestSuite {
  const main__TestSuite *data;
  size_t idx;
  size_t stop;
};
struct Slice__main__TestSuite {
  const main__TestSuite *ptr;
  size_t len;
};
struct SliceMut__main__TestSuite {
  main__TestSuite *ptr;
  size_t len;
};

void main__TestPlan__free(main__TestPlan *const self);
Vector__main__TestCase__Global Vector__main__TestCase__Global__new_in(Global const alloc);
Vector__main__TestCase__Global Vector__main__TestCase__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__main__TestCase__Global__len(const Vector__main__TestCase__Global *const self);
void Vector__main__TestCase__Global__reserve(Vector__main__TestCase__Global *const self, size_t const additional);
void Vector__main__TestCase__Global__push(Vector__main__TestCase__Global *const self, main__TestCase const value);
const main__TestCase *Vector__main__TestCase__Global__at(const Vector__main__TestCase__Global *const self, size_t const index);
Option__ptr_main__TestCase Vector__main__TestCase__Global__get(const Vector__main__TestCase__Global *const self, size_t const index);
void Vector__main__TestCase__Global__set(Vector__main__TestCase__Global *const self, size_t const index, main__TestCase const value);
void Vector__main__TestCase__Global__clear(Vector__main__TestCase__Global *const self);
void Vector__main__TestCase__Global__truncate(Vector__main__TestCase__Global *const self, size_t const new_len);
const main__TestCase *Vector__main__TestCase__Global__as_ptr(const Vector__main__TestCase__Global *const self);
void Vector__main__TestCase__Global__swap(Vector__main__TestCase__Global *const self, size_t const i, size_t const j);
Vector__main__TestCase__Global Vector__main__TestCase__Global__new(void);
void Vector__main__TestCase__Global__free(Vector__main__TestCase__Global *const self);
Vector__main__TestCase__Global Vector__main__TestCase__Global__default_(void);
const main__TestCase *Vector__main__TestCase__Global__index(const Vector__main__TestCase__Global *const self, size_t const i);
Slice__main__TestCase Vector__main__TestCase__Global__index_range(const Vector__main__TestCase__Global *const self, Range__usize const r);
main__TestCase *Vector__main__TestCase__Global__index_mut(Vector__main__TestCase__Global *const self, size_t const i);
SliceMut__main__TestCase Vector__main__TestCase__Global__index_range_mut(Vector__main__TestCase__Global *const self, Range__usize const r);
Vector__main__TestSuite__Global Vector__main__TestSuite__Global__new_in(Global const alloc);
Vector__main__TestSuite__Global Vector__main__TestSuite__Global__with_capacity_in(Global const alloc, size_t const cap);
size_t Vector__main__TestSuite__Global__len(const Vector__main__TestSuite__Global *const self);
void Vector__main__TestSuite__Global__reserve(Vector__main__TestSuite__Global *const self, size_t const additional);
void Vector__main__TestSuite__Global__push(Vector__main__TestSuite__Global *const self, main__TestSuite const value);
const main__TestSuite *Vector__main__TestSuite__Global__at(const Vector__main__TestSuite__Global *const self, size_t const index);
Option__ptr_main__TestSuite Vector__main__TestSuite__Global__get(const Vector__main__TestSuite__Global *const self, size_t const index);
void Vector__main__TestSuite__Global__set(Vector__main__TestSuite__Global *const self, size_t const index, main__TestSuite const value);
void Vector__main__TestSuite__Global__clear(Vector__main__TestSuite__Global *const self);
void Vector__main__TestSuite__Global__truncate(Vector__main__TestSuite__Global *const self, size_t const new_len);
const main__TestSuite *Vector__main__TestSuite__Global__as_ptr(const Vector__main__TestSuite__Global *const self);
void Vector__main__TestSuite__Global__swap(Vector__main__TestSuite__Global *const self, size_t const i, size_t const j);
Vector__main__TestSuite__Global Vector__main__TestSuite__Global__new(void);
void Vector__main__TestSuite__Global__free(Vector__main__TestSuite__Global *const self);
Vector__main__TestSuite__Global Vector__main__TestSuite__Global__default_(void);
const main__TestSuite *Vector__main__TestSuite__Global__index(const Vector__main__TestSuite__Global *const self, size_t const i);
Slice__main__TestSuite Vector__main__TestSuite__Global__index_range(const Vector__main__TestSuite__Global *const self, Range__usize const r);
main__TestSuite *Vector__main__TestSuite__Global__index_mut(Vector__main__TestSuite__Global *const self, size_t const i);
SliceMut__main__TestSuite Vector__main__TestSuite__Global__index_range_mut(Vector__main__TestSuite__Global *const self, Range__usize const r);
Option__main__TestCase Option__main__TestCase__some(main__TestCase const value);
Option__main__TestCase Option__main__TestCase__none(void);
bool Option__main__TestCase__is_some(const Option__main__TestCase *const self);
bool Option__main__TestCase__is_none(const Option__main__TestCase *const self);
Option__main__TestCase Option__main__TestCase__default_(void);
Option__ptr_main__TestCase Option__ptr_main__TestCase__some(const main__TestCase *const value);
Option__ptr_main__TestCase Option__ptr_main__TestCase__none(void);
bool Option__ptr_main__TestCase__is_some(const Option__ptr_main__TestCase *const self);
bool Option__ptr_main__TestCase__is_none(const Option__ptr_main__TestCase *const self);
Option__ptr_main__TestCase Option__ptr_main__TestCase__default_(void);
Option__ptr_main__TestCase VecIter__main__TestCase__next(VecIter__main__TestCase *const self);
size_t Slice__main__TestCase__len(const Slice__main__TestCase *const self);
const main__TestCase *Slice__main__TestCase__as_ptr(const Slice__main__TestCase *const self);
const main__TestCase *Slice__main__TestCase__index(const Slice__main__TestCase *const self, size_t const i);
Slice__main__TestCase Slice__main__TestCase__index_range(const Slice__main__TestCase *const self, Range__usize const r);
size_t SliceMut__main__TestCase__len(const SliceMut__main__TestCase *const self);
main__TestCase *SliceMut__main__TestCase__as_mut_ptr(const SliceMut__main__TestCase *const self);
const main__TestCase *SliceMut__main__TestCase__index(const SliceMut__main__TestCase *const self, size_t const i);
Slice__main__TestCase SliceMut__main__TestCase__index_range(const SliceMut__main__TestCase *const self, Range__usize const r);
main__TestCase *SliceMut__main__TestCase__index_mut(SliceMut__main__TestCase *const self, size_t const i);
SliceMut__main__TestCase SliceMut__main__TestCase__index_range_mut(SliceMut__main__TestCase *const self, Range__usize const r);
Option__main__TestSuite Option__main__TestSuite__some(main__TestSuite const value);
Option__main__TestSuite Option__main__TestSuite__none(void);
bool Option__main__TestSuite__is_some(const Option__main__TestSuite *const self);
bool Option__main__TestSuite__is_none(const Option__main__TestSuite *const self);
Option__main__TestSuite Option__main__TestSuite__default_(void);
Option__ptr_main__TestSuite Option__ptr_main__TestSuite__some(const main__TestSuite *const value);
Option__ptr_main__TestSuite Option__ptr_main__TestSuite__none(void);
bool Option__ptr_main__TestSuite__is_some(const Option__ptr_main__TestSuite *const self);
bool Option__ptr_main__TestSuite__is_none(const Option__ptr_main__TestSuite *const self);
Option__ptr_main__TestSuite Option__ptr_main__TestSuite__default_(void);
Option__ptr_main__TestSuite VecIter__main__TestSuite__next(VecIter__main__TestSuite *const self);
size_t Slice__main__TestSuite__len(const Slice__main__TestSuite *const self);
const main__TestSuite *Slice__main__TestSuite__as_ptr(const Slice__main__TestSuite *const self);
const main__TestSuite *Slice__main__TestSuite__index(const Slice__main__TestSuite *const self, size_t const i);
Slice__main__TestSuite Slice__main__TestSuite__index_range(const Slice__main__TestSuite *const self, Range__usize const r);
size_t SliceMut__main__TestSuite__len(const SliceMut__main__TestSuite *const self);
main__TestSuite *SliceMut__main__TestSuite__as_mut_ptr(const SliceMut__main__TestSuite *const self);
const main__TestSuite *SliceMut__main__TestSuite__index(const SliceMut__main__TestSuite *const self, size_t const i);
Slice__main__TestSuite SliceMut__main__TestSuite__index_range(const SliceMut__main__TestSuite *const self, Range__usize const r);
main__TestSuite *SliceMut__main__TestSuite__index_mut(SliceMut__main__TestSuite *const self, size_t const i);
SliceMut__main__TestSuite SliceMut__main__TestSuite__index_range_mut(SliceMut__main__TestSuite *const self, Range__usize const r);


#endif
