# Compile-Time Evaluation and Platform Gating

## Compile-Time Evaluation

Always on, in constant contexts: `const` and `static` initializers (local constants too),
array lengths, const generic arguments, `static_assert`, enum discriminants, `type_info` and
`type_info::<T>().qualified_name` (`T` spelled with its trailing defaulted arguments dropped:
`Vector<i32>`; read alone it folds to a string constant and builds no descriptor). `panic_parts(head,
tail)` panics with `head` then `tail` without allocating, so a message can name a type
(`panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds")`).
A failed evaluation there is an error, and a local constant's initializer cannot read a
variable. A constant context can call any function. Outside one, a `const fn` call whose
arguments are constant (literals, constants, `sizeof`, operators, aggregates and `const fn`
calls over them) runs at compile time and its value replaces it, when the value is an integer,
`bool`, `char`, float, `str`, bare enum, or a struct, tuple struct or array of them (at most
256 scalars). A call whose evaluation fails runs at run time, without an error; every other
call runs at run time. `const fn` adds a declaration check that rejects a function certain to
fail at compile time.

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }
const N: usize = table_size(8);

static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

- A `const` of an owning (`Free`) type lives in static storage. Moving out of it is "cannot
  move a value out of a 'const' binding"; borrow it instead (`K.v.len()`).
- Every task shares a `const`: one holding an `UnsafeCell` must be `Sync` ("a constant of type
  '..' holds an 'UnsafeCell' but is not 'Sync'").
- A constant whose type embeds a stateful allocator is "a constant cannot use the stateful
  allocator '...'". A `static mut` cannot hold an owning type (raw pointers and references are
  allowed).
- A union reads at compile time through the member last written, or through another scalar member
  of its width (`f64_bits`); any other member read does not fold. So a `String` folds only up to its
  inline bytes (23 on a 64-bit target).
- Allocation is valid at compile time. A `@no_const` type (see Attributes) is not: a `const fn`
  whose signature names one, or that fails on every path (it constructs one), is an error at
  its declaration ("function 'f' is declared 'const fn' but ..."). A `const fn` that fails only
  on some paths (a branch, a loop, recursion) is accepted.
- A header type (a `struct` or `union` of an `extern "C"` block) lists every member, so its size,
  alignment, offsets and `type_info` are compile-time values like a Super-C struct's; the build
  checks them against the header (`super-c-ffi`). A constant of an extern block with a value folds
  like any constant.
- A `const fn` cannot call an extern function or a variadic one ("... but calls a variadic
  function"). `assert`, `assert_eq` and `assert_ne` are variadic (`std/test.spc`), so a function
  that checks an invariant with `assert` is a plain `fn`.
- A `static_assert` in a non-generic body must fold, as a top-level one must ("static
  assertion cannot be evaluated: the condition does not fold to a constant").
- A `static_assert` in the body of a generic function (one with its own generic parameters,
  or a method of an extend with parameters) holds per instance:
  `static_assert(T::is_signed(), "only signed types")` fails the build at
  `only_signed(3u32)`, with a note that names the bindings. The check runs for each concrete
  call the type check records, once every module is typed, and for every other instance the
  build uses, also one reached only through another generic body. Each failure is reported
  once.

## Build Constants and Platform Gating

```superc
@platform(macos)
fn platform_init() { /* macOS-specific */ }

@platform(windows)
fn platform_init() { /* Windows-specific */ }

fn page_size() usize {
    if PLATFORM == Platform::Windows {
        return win_page_size(); // a @platform(windows) item: the call is removed on other platforms
    } else if ARCH == Arch::AArch64 {
        return 16384;
    }
    return 4096;
}
```

No `#ifdef` in Super-C. Use `@platform(windows|macos|linux|wasm|ios|android)` and
`@arch(x86_64|aarch64|wasm32)` on items and on the members of an `extend` or an `extern` block
(an interface member takes no attribute); `|` inside the attribute is a union, `!x` the
complement. An item with both `@platform` and `@arch` compiles only where both hold, and a gate
that fails removes the item or member before name resolution.
`--target=` and `--arch=` select the target.

`@when(C)` gates an item, a member or an import on the boolean build constants the same way:
`C` names `TEST`, `LOCKDEP` and `OVERFLOW_CHECKS` with `!`, `&&`, `||` and parentheses
(`@when(LOCKDEP && !TEST)`); any other name or form is "'@when' takes a condition over TEST, LOCKDEP
and OVERFLOW_CHECKS ...". It combines with `@platform` and `@arch`: the item exists only where every
gate holds. Use it where a definition must not exist at all in some builds; inside a body,
`if LOCKDEP { .. }` is enough.

The prelude defines the build settings as constants usable in any expression:

| Constant | Type | Value |
|----------|------|-------|
| `PLATFORM` | `Platform` (`Windows`, `MacOS`, `Linux`, `Wasm`, `IOS`, `Android`) | `--target` (default: the host) |
| `ARCH` | `Arch` (`X86_64`, `AArch64`, `Wasm32`) | `--arch` (default: the host's; `--target=wasm`, `ios` and `android` set theirs) |
| `TEST` | `bool` | true in a test build (`super-c test`, `super-c test <file>`) |
| `POINTER_WIDTH` | `u32` | 64; 32 on `wasm32` |
| `ENDIAN` | `Endian` (`Little`, `Big`) | `Little` on every supported target |
| `PROFILE` | `str<'static>` | the build profile name (`debug` when none is named) |
| `LOCKDEP` | `bool` | the profile sets `lockdep = true` (lock-order checking) |
| `OVERFLOW_CHECKS` | `bool` | false when the profile wraps integer overflow (`overflow-checks`, else `opt-level` 2 and up) |

The compiler generates their module (`__std::build`) from the build's settings; std declares only
the enums (`std/target.spc`). The eight names are reserved: an item or binding with one of
them is an error, and so is a type, item, binding or generic parameter named `Platform`,
`Arch` or `Endian` outside `std/target.spc` (the filter reads `Platform::X` as std's
variant before name resolution). ARCH and POINTER_WIDTH are absent when the host
instruction set is unknown and no `--arch` names one.

The platform filter decides a condition over PLATFORM, ARCH, POINTER_WIDTH, ENDIAN and the
bool constants alone before name resolution: a bare bool constant (`TEST`, `LOCKDEP`), `!`, `&&`, `||`, parentheses, and `==`
or `!=` against `Platform::X` / `Arch::X` / `Endian::X`, `true` / `false`, or a decimal
integer. Such an `if` / `else if` / `else` chain (statement or value) becomes its taken
block (with its own scope), and a `switch PLATFORM { Windows => .., _ => .. }` (or over
ARCH or ENDIAN; arms of bare variant names, `|` and `_`, no guard) becomes its taken arm.
The removed code is parsed but never resolved or checked, like a gated-out item: it may
call items of another platform. A variant name these forms spell that does not exist
(`Platform::Macos`) is an error, in removed code too. A condition that mixes the
constants with anything else is an ordinary constant expression: both branches are
checked, and the dead one is not emitted when the condition folds.

A user `const bool` gate (`if STATS { .. }`) trips the constant-condition lint ("condition is
always false"); gate through a `pub const fn` instead (`sched_stats_on()` in
std/parallel/runtime.spc).

PROFILE is an ordinary constant: both branches of `if PROFILE == "release"` are checked,
and only the taken one is emitted (`switch PROFILE` over string literals too). A string
literal compared with PROFILE must name a built-in profile or a `[profile.*]` of the
package (a single-file build knows the built-ins only). The constant-condition and
unreachable lints never fire on these conditions. Removed code may hold the only use of a
name, so the lints that count uses treat every identifier its text spells as used, by
name: a binding, item, field, variant or import that removed code names is not reported
unused (nor a `mut` binding not mutable, nor a store dead), in any module for items,
fields and variants; a glob import of a module with removed code is kept. An `unsafe` that
holds removed code is not reported unnecessary, and a statement that is or holds a decided
site does not make the next one unreachable. Everything else is linted as usual. The name
match is textual: a removed use of `x` also covers an unrelated `x`. The LSP loads and
filters with the configured `--target` and does not analyze removed code (no hover or
navigation inside it); hover on a constant shows its value.
