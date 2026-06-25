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
typedef struct Package {
    Module *modules;
    size_t count, cap;
    char *root_dir;   // source root: the directory of the root file; imports resolve relative to it
    char *std_root;   // second import search root (parent of std/): `import std::x;` -> <std_root>/std/x.spc
    bool ok;          // false if any read/parse/cycle error was reported during loading
    // Generics with a concrete instance re-homed into a user module (Option<Bar>): the owner emits their
    // DECLARE/DEFINE macros so the home can materialize the instance. Filled by propagation; a DefId per
    // generic decl. Used to gate macro emission in single-TU output (the multi-file tree emits all pub ones).
    DefId *macro_generics;
    size_t n_macro_generics, cap_macro_generics;
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

// Like package_lookup but across every prelude module; sets *out_mid to the owning module on a hit.
NodeId package_prelude_lookup(const Package *p, const char *name, size_t name_len, bool want_type, ModuleId *out_mid);

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

// True if generic `decl` (owned by module `module`) has an instance re-homed into a user module, so its
// DECLARE/DEFINE macros must be emitted even in single-TU output. (Recorded by package_propagate_instances.)
bool package_generic_needs_macro(const Package *p, ModuleId module, NodeId decl);

#endif // MODULE_LOADER_H
