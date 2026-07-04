#ifndef MODULE_LOADER_H
#define MODULE_LOADER_H

#include "ast/ast.h"

// One loaded module: its `::`-joined module path (the mangling/lookup key), the file it came from, its
// source text and parsed Ast. ModuleId is the module's index in Package.modules.
typedef struct Module {
    char *path;       // "std::string"; the root module is its file stem
    char *file;       // filesystem path the source was read from
    char *source;     // NUL-terminated file contents (owned)
    size_t source_len;
    Ast *ast;         // parsed AST (NULL if the file failed to lex/parse)
    bool loading;     // on the DFS stack -- used to detect import cycles
    bool prelude;     // part of the auto-imported std prelude (its public decls resolve unqualified)
} Module;

// The whole compilation: the root module plus every module reachable through `import`. Modules are
// kept as separate Asts; cross-module references are DefId{module, node} into this array.
struct ConstEval; // src/consteval: compile-time evaluation; NULL only in library/test use

typedef struct Package {
    struct ConstEval *ceval; // owned by main (created after load, freed before package_free)
    Module *modules;
    size_t count, cap;
    char *root_dir;   // source root: the directory of the root file; imports resolve relative to it
    char *std_root;   // second import search root (parent of std/): `import std::x;` -> <std_root>/std/x.spc
    bool ok;          // false if any read/parse/cycle error was reported during loading
    // Builtins as nominal types: a synthetic decl per builtin is injected into the `core` prelude module so
    // `extend i32 { .. }` / `extend i32 as Hash { .. }` resolve and dispatch like any other type. `core_seeded`
    // gates it (false when no core module is present, e.g. parser-only / no-prelude builds).
    ModuleId core_module;
    bool core_seeded;
    NodeId builtin_decls[BT_COUNT];
    // Demand-driven method emission: a per-module bit (indexed by the method's node id) set for every
    // method referenced anywhere during type-checking, for O(1) mark/query. An INHERENT method of a
    // non-`@emit_macro` generic type whose bit is unset is dead and is not emitted; conformance methods
    // (operators / RAII / bound dispatch) and `@emit_macro` types emit fully.
    bool **method_used;       // method_used[module][node] -- ragged, grown on demand
    size_t *method_used_cap;  // allocated length of each module's bit array
    size_t method_used_mods;  // number of module slots in the two arrays above
} Package;

// Load `root_file` and, transitively, every module it imports, then append the std prelude found under
// `std_dir` (NULL skips it). Diagnostics are printed as encountered. Returns a Package (check `->ok`);
// free with package_free.
Package *package_load(const char *root_file, const char *std_dir);

// A package holding only the std prelude modules under `std_dir` -- for the REPL / tests, which compile
// a single in-memory source against the prelude (the user Ast is kept standalone with module == count).
Package *package_prelude_only(const char *std_dir);
void package_free(Package **p);

// Find a module by its `::`-joined path; returns its ModuleId, or -1 if absent.
int package_find(const Package *p, const char *path, size_t path_len);

// Find a *public* top-level declaration named `name` in module `mid`: a struct/enum when `want_type`,
// otherwise a function. Returns the decl's NodeId within module `mid`'s Ast, or NODE_NONE.
NodeId package_lookup(const Package *p, ModuleId mid, const char *name, size_t name_len, bool want_type);

// Record / test a method DefId as referenced, for demand-driven instance-method emission. The type-checker
// marks every method it resolves; codegen omits inherent methods of non-`@emit_macro` types never marked.
// `package_method_used` returns true when `p` is NULL (the single-file path emits every method).
void package_mark_method_used(Package *p, DefId d);
bool package_method_used(const Package *p, DefId d);

// Like package_lookup but across every prelude module; sets *out_mid to the owning module on a hit.
NodeId package_prelude_lookup(const Package *p, const char *name, size_t name_len, bool want_type, ModuleId *out_mid);

// package_lookup extended over `mid`'s transitive imports (imports are public, C-style): searches `mid`
// itself, then every module it imports breadth-first in declaration order. First hit wins; sets *out_mid.
NodeId package_glob_lookup(const Package *p, ModuleId mid, const char *name, size_t name_len, bool want_type,
                           ModuleId *out_mid);

// Move every concrete cross-module generic instantiation into its template module's instance table, so
// the owning module emits the specialization (struct + methods) in its header/.c and users just include
// it -- mirroring non-generic cross-module types. Run after typechecking, before codegen. `standalone` is
// the REPL/test user Ast that lives outside `modules` (NULL for the build-tree path). Iterates to a
// fixpoint so nested instances (Vec<Box<i32>>) reach every owner.
void package_propagate_instances(Package *p, Ast *standalone);

// The module a concrete generic instance must be emitted in: the module of its first user (non-prelude)
// type argument held by value, else the generic's own module (it->module). `a` owns `it`'s arg TypeIds.
// Codegen emits an instance whose home is the current module (re-homed ones via the generic's macros).
ModuleId package_instance_home(const Package *p, const Ast *a, const TyInstance *it);

// Fill `order` (length p->count) with module ids in dependency-first order: every module a module
// references is emitted before it. Codegen materializes a re-homed generic instance in the user module
// that owns its type by sourcing the generic's template from the owner module; emitting the owner first
// keeps that transient cross-pool work from being observed by the owner's own pass. Imports form a DAG
// (cycles are rejected at load); any residual cycle falls back to id order for the remainder.
void package_emit_order(const Package *p, ModuleId *order);

// The synthetic decl node anchoring builtin `b` in the core module, or NODE_NONE if builtins were not seeded.
NodeId package_builtin_decl(const Package *p, BuiltinType b);
// If (module, node) names a builtin's synthetic core decl, its BuiltinType; else -1.
int package_builtin_of_decl(const Package *p, ModuleId module, NodeId node);

#endif // MODULE_LOADER_H
