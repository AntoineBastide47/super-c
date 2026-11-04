---
name: super-c-ffi
description: "Covers C interop in Super-C: extern blocks, header bindings, opaque types, variadics, prebuilt C libraries and @link, the ffi/ convention, str vs NUL-terminated strings, unsafe discipline at FFI boundaries, and the bindgen tool. Use when writing C bindings, integrating external libraries, or debugging FFI issues."
allowed-tools: Bash Read
---

# Super-C C FFI

## Agent checklist

- Confirm the C symbol, header, ownership, and string termination contract.
- Keep every extern call inside an explicit `unsafe` boundary, except a call of a function whose `@unsafe(...)` lists `safe`.
- Check whether a link flag is already declared.
- Validate opaque types against a real included C declaration.
- Pass a struct C reads through a pointer in the `extern "C"` call itself, or give it a fixed order (Field Order).

Super-C interoperates with C through `extern "C"` blocks. Bindings map directly to C
symbols with no wrapper or mangling.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Passing `str` to C `%s` | Use `%.*s` with `.len()` + `.ptr()` (`str` has no `.cstr()`) |
| Missing `unsafe` on extern call | Add `unsafe` prefix or block |
| Repeating `@link` in every importing module | Declare it once on the binding module |
| Using `void` for opaque types | Use `type X;` (with its defining header): renders as the real C name |
| Assuming `String::ptr()` is NUL-terminated | It is not. Use `String::cstr()` |
| Passing a `str`'s `.ptr()` to a C path parameter | Use `.cstr()`, or `std::platform::path::native` inside std; a heap string whose allocation equals its length has no NUL after it, so failures depend on the length |
| Inventing an opaque type name (`type CFile;`) | The name must be a real C type a header defines |
| Mirroring a C struct as a Super-C `struct` | Declare it in the header's extern block: a header type uses the C layout and checks its fields |
| Passing a Super-C struct to C through a `*void` variable or a Super-C wrapper | The compiler reorders its fields: pass it in the `extern "C"` call itself, declare it as a header type, or tag it `@ordered` (Field Order) |
| A typedef'd header type declared as `struct pthread_attr_t {}` | That spells `struct pthread_attr_t`: add `@import("pthread_attr_t")` |
| `@import` before the extern block | Put it on the `fn` inside the block |

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [bindings.md](references/bindings.md): basic bindings, header bindings, C libraries, link flags.
- [types.md](references/types.md): opaque types, @layout, @value, header types, field order, header constants, C integer widths, macro objects, thread-locals, pointers to arrays.
- [functions.md](references/functions.md): memory annotations, variadics, str and C strings, symbol pinning, unsafe discipline, @unsafe(safe, const).
- [conventions.md](references/conventions.md): the ffi/ convention, attribute summary, bindgen, atomics and memory-order codes, platform C pitfalls.
