# Imports, Modules and Visibility

## Imports and Modules

```superc
import geom;                 // qualified access: geom::Point
import geom as *;            // unqualified glob
import geom as g;            // alias
```

Imports are public and C-style transitive, so there is no `pub import`. Cycles are legal. Prelude types (`String`,
`Option`, `Vector`, `Box`, `Result`, `Map`, `Set`, `str`) resolve unqualified.

`import a::b;` loads `<root>/a/b.spc`, else the directory index `<root>/a/b/b.spc`, through the import roots (the
project, its `src/`, std, `ffi/`); when neither exists and `<root>/a/b/` is a directory, the import is an implicit
index: a module that glob-imports every `.spc` file directly in the directory (in name order; subdirectories stay
modules of their own). An explicit index decides what its module exposes through its own imports. A name that two
files of an implicit index declare is "'x' is ambiguous: two files of directory module 'a::b' declare it" where it
is used, not where the directory is imported.

A glob import re-exports: `m::x` names `m`'s own item `x`, else the first `x` that a module `m` glob-imports (or one
of that module's imports) declares. The unused-import lint reports a glob import only in a module no other module imports.

An unqualified name the module does not declare is looked up in its glob imports first, then in
the prelude: a glob-imported `String` or `dot` shadows the prelude's, as a declaration does. A
glob import without an alias (`import m::qq as *;`) also makes its last segment a module
qualifier, but a type in scope of that name (declared, imported or glob-imported) wins: when
module `m::qq` declares `pub type qq = Q;`, `qq::one()` calls `Q::one`. An explicit `as` alias
always names the module.

## Visibility

| Spelling | Item visible to | Field visible to |
| --- | --- | --- |
| none | its file | its file |
| `pub(module)` | the files whose path is the declaring file's path minus its last segment, or starts with it and `::` (a directory index's whole path; a root-level file's: its package) | the same |
| `pub(package)` | the files of its package: the project (root, `src/`, `tests/`, `bench/`), std, `ffi/`, or one `vendor/<name>` | the same |
| `pub` | every file | every file |

The modifier applies to structs, unions, enums, functions, methods, constants, statics, type aliases, interfaces and
fields. A project whose `build.toml` sets `std_internals = true` sees std's `pub(package)` items (unstable
internals such as `std::platform`); without it naming one is an error whose note names the key. Enum variants and
interface members take the visibility of their declaration; a conformance (`extend T as I`) has none. A method or
associated constant is at most as visible as its type. A signature, field type, alias target or bound of an item
visible beyond its file names no type less visible than the item ("'T' is less visible than the pub item that names
it"); an associated type has its interface's visibility. A call that lowering synthesizes (format sugar, `launch`)
reaches its target whatever its level. The levels are source rules: `pub(module)`, `pub(package)` and `pub` emit the
same C.
[migration.md](migration.md) maps the levels and the std contracts to their Go, Rust, Odin and C++
names.
