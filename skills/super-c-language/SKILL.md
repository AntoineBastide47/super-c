---
name: super-c-language
description: "Covers the Super-C language syntax, semantics, and style conventions: types, ownership, generics, closures, interfaces, FFI, testing, const-eval, and the canonical formatting and naming rules. Use when writing, reviewing, or explaining Super-C source files (.spc)."
allowed-tools: Bash Read
---

# Super-C Language

## Agent checklist

- Preserve binding mutability, ownership, and borrow rules.
- Check syntax and semantics in the type references before adding patterns.
- Use `@platform` for target selection and keep generated C portable.
- Format changed `.spc` files with `super-c fmt`.

Super-C is a statically-typed systems language that compiles to native code, and to readable
C11 with `--emit-c`. It pairs a modern frontend (RAII, borrow checking, generics, closures,
compile-time evaluation, coroutines) with C's portability and performance model.

Source files use the `.spc` extension. The canonical formatter is `super-c fmt` (Wadler,
width 120, 4-space indent). Treat its output as authoritative.

## Rust Habits and the Super-C Form

Super-C takes ideas from Rust but is not compatible with it and never will be. The compiler
does not accept Rust syntax and its diagnostics never mention it. Write the Super-C form from
the start:

| Rust habit | Super-C form |
|------------|--------------|
| `fn f(x: i32) -> i32` | `fn f(x: i32) i32` |
| `fn f() -> (A, B)`, `return (a, b)` | `fn f() (A, B)`, `return a, b;`, `let (a, b) = f();` |
| `trait Shape { .. }` | `interface Shape { .. }` |
| `impl Shape for Circle { .. }` | `extend Circle as Shape { .. }` (not `extend Circle: Shape`) |
| `impl Circle { .. }` | `extend Circle { .. }` |
| `#[derive(Clone, Eq)]`, an empty `impl I for T {}` | `@derive(Clone, Eq)` on the declaration; never an empty `extend T as I {}` |
| `#[test]`, `#[inline]` | `@test`, `@inline` |
| `match x { .. }` | `switch x { .. }`, as a statement or a value |
| `[4]i32` | `[i32; 4]` |
| `&[T]`, `&mut [T]` | `[]T`, `[]mut T` |
| `a.len()`, `a.as_slice()` on `[T; N]` | the length is `N`; pass `a` where a `[]T` is expected: `sum(a)` |
| `v.as_slice()` on a `Vector` | `&v` converts to `[]T` at a call: `sum(&v)` |
| `for x in xs.iter() { .. *x .. }` | `for x in xs { .. x .. }`: each element by value |
| `&str`, `s.as_bytes()` | `str` (a view, passed by value), `s.byte_at(i)`, `s.bytes()` |
| `String::from("x")` | `String::from_str("x")` |
| `Vec<T>`, `vec![..]` | `Vector<T>`, `Vector::<T>::new()` and `push` (no macros) |
| `println!("{}", x)` | `println("{}", x)` |
| `use a::b;`, `mod m;` | `import a::b;`, `import a::b as c;`, `import a as *;`; a file is a module |
| `static X: T = v;` | `const X: T = v;`; `static mut X: T = v;` for a mutable global, accessed in `unsafe` |
| `let y = x as i64;` for a lossless widening | `let y: i64 = x;`: the lint rejects the unnecessary cast |
| `let h = thread::spawn(..)` | `launch || { .. };`, a statement that gives no handle |

## Quick Reference

See [types.md](references/types.md) for the full type system reference (scalars, structs,
enums, pattern types, generics, closures, trait objects, slices, arrays, tuples, pointers, references).

See [operations.md](references/operations.md) for the normative result of every scalar,
conversion, float, pointer, atomic and control operation (wraps, traps, defined value, or
undefined), identical at compile time and at run time.

See [style.md](references/style.md) for naming conventions, file organization, comment
rules, and the formatting contract.

See [inference.md](references/inference.md) for the local type-inference rules: literal
defaults, safe-conversion ranks, branch joins, generic-argument evidence, const generic
solving, closures, and overload ambiguity.

See [simd.md](references/simd.md) for the vector and mask types `Simd<T, N>` and `Mask<N>`:
their rules, layout, lane access, mask operations and diagnostics, and for CPU features,
`@target_feature`, the `@simd_impl` backend files, run-time detection and `detect::dispatch`, and
the architecture modules `std::simd::x86`, `std::simd::aarch64` and `std::simd::wasm`.

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [basics.md](references/basics.md): bindings and mutability, functions, contracts, ghost code and specifications (`forall`, `old`, `Seq`), constant-time code (`Secret`, `@constant_time`), structs and methods, enums and pattern matching.
- [ownership.md](references/ownership.md): ownership and RAII, references and borrowing, unsafe.
- [generics.md](references/generics.md): generics, closures, interfaces and @derive.
- [modules.md](references/modules.md): import forms, module paths, visibility.
- [slices-and-arrays.md](references/slices-and-arrays.md): []T views and [T; N] arrays.
- [compile-time.md](references/compile-time.md): const evaluation, build constants, @platform and @when.
- [attributes.md](references/attributes.md): the attribute table, branch hints, unsafe placement, module-level assembly.
- [std-and-interop.md](references/std-and-interop.md): short forms of C FFI, tests, concurrency, and the standard library.
- [migration.md](references/migration.md): the Super-C name of each common contract, by its names in other languages.
