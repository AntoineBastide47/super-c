# Attributes

## Attributes

| Attribute | Effect |
|-----------|--------|
| `@inline` | Suggest inlining |
| `@always_inline` | Force inlining |
| `@noinline` | Prevent inlining |
| `@cold` | Mark rarely called: under `--emit-c` C `cold`, which implies `noinline`, and the C compiler lays out the branches that call it as unlikely. The native build marks each block that calls it unlikely (laid out after the warm code, as `unlikely` does), inlines it only when it is no bigger than its call, and puts its code in a cold section (ELF `.text.unlikely`, Mach-O `__text_cold`, COFF `.text$u`) |
| `@noreturn` | Mark non-returning |
| `@align(N)` | Set alignment of a struct or a union (a header type of an `extern "C"` block too), or of a `static mut` outside an `extern "C"` block (an error on any other item): a power of two from 1 to 4096 (a page: a larger one is misaligned on some hosts and could move a task's frame past its guard page); `N` is an integer literal or a constant expression of type `u32`. An emitted struct or union definition takes `__attribute__((aligned(N)))`; a static whose `N` is above its type's own alignment takes `_Alignas(N)` on its definition and every declaration (C rejects a weaker specifier) |
| `@packed` | Pack a struct or a union, a header type of an `extern "C"` block too (an error on any other item). A reference or autoref to a field whose alignment exceeds 1 is "cannot borrow a field of a '@packed' struct" (copy it into a local first), and such a field cannot need a `free` |
| `@export("sym")` | Pin exact C symbol; a constant or `static mut` is defined also when no code names it |
| `@import("sym")` | Import exact C symbol; on an extern type, its C spelling; on a header type's field, its C member |
| `@used` | Prevent dead-code elimination: the function, constant or `static mut` is emitted also when no code names it, with C `used`. Without it (or `@export`), a function a program with `main` never reaches, or whose every call is inlined, has no C definition |
| `@unused` | Suppress unused warnings |
| `@emit_macro` | Export generic as reusable C macro |
| `@fmt.skip` | Exempt from formatter |
| `@platform(P)` | Platform gate |
| `@arch(A)` | Instruction-set gate: `x86_64`, `aarch64`, `wasm32` (see Build Constants and Platform Gating) |
| `@when(C)` | Build-condition gate over `TEST`, `LOCKDEP`, `OVERFLOW_CHECKS` (see Build Constants and Platform Gating) |
| `@target_feature([cpu::Feature::X, ..])` | The function needs CPU features (a list, or a level such as `cpu::X86_64_V3`): safe to call where the build or the caller holds them, else inside `unsafe` after a run-time check (an error on wasm32); its vector code uses them (references/simd.md) |
| `@simd_impl(simd::Op::X, [cpu::Feature::Y, ..])` | `std` only: a backend entry of vector operation `X` (references/simd.md) |
| `@value(size, align)` | An opaque `extern "C"` type is a C register type of that layout (see `super-c-ffi`) |
| `@layout(size, align)` | An opaque `extern "C"` type is a C value of that exact layout, checked in C (see `super-c-ffi`) |
| `@thread_local` | A `static mut` (an extern one too) has one object per OS thread. Every access calls a non-inlined accessor, so a coroutine that moves to another thread reads that thread's object. A constant or a `static mut` initializer cannot read one ("a thread-local has one object per thread: ...") |
| `@owned` | On a raw pointer field (`*mut T`, `*const T`; an error elsewhere): the user promises that while a reference to the struct lives, the buffer the field points to is reached only through the field. Through a `&mut` the buffer is then apart from other memory, through a `&` read-only, so loops over such buffers need no run-time overlap check. Breaking the promise is undefined behavior. The proofs read the buffer as `std::spec::seq::block(field)` (basics.md, Struct Invariants and Owned Blocks). `std` marks its containers' buffers (`Vector.ptr`, `Box.ptr`) |
| `@reads(p, bytes)` / `@writes(p, bytes)` / `@lane_access` | The memory an extern function reads or writes through pointer parameter `p` (see `super-c-ffi`) |
| `@test` / `@test_init` / `@test_free` | Test harness; `@test(should_panic, timeout = N)` takes either argument or both |
| `@blocking` | Run extern on blocking pool |
| `@tail_recurse` | Every call of the function to itself must become a jump (see Functions); a function with a body only |
| `@prove_exhaustive` | Prove the function by running it at compile time on every value of its parameters, in place of the symbolic proof (basics.md, Contracts); a function with a body only |
| `@constant_time` | The build checks the function's generated code, also when nothing calls it: no branch, memory address or variable-time operation depends on a `Secret`, and a secret leaves it only inside a `Secret`; only such a function reads a secret (basics.md, Constant-Time Code); a function with a body, not a spec function or a lemma |
| `@no_const` | Struct, union or enum whose values never exist at compile time; a function that is never a `const fn` (an error on one; `lint --const` skips it) |
| `@intrinsic("<name>")` | `std` only: a function without a body whose call is the operation the name gives: a vector operation `simd.<name>` (references/simd.md), `float.to_int_unchecked` (references/operations.md), the branch hints `hint.likely` and `hint.unlikely` (Branch Hints below), `secret.declassify` (a value unchanged that the constant-time check counts as public), `frame.return_address` (the running function's return address, null on wasm; the leak tracker's allocation sites), or `mem.volatile_load` / `mem.volatile_store` (one access the C compiler keeps, orders and never merges: `std::mem::volatile` wraps them as `read_volatile`, `write_volatile` and `zeroize`) |
| `@unsafe(safe, const)` | Unverified claims on an extern function, any order, at least one: `safe` = callable without `unsafe`, `const` = its body models it at compile time (see `super-c-ffi`) |
| `@unsafe(link_section = "s")` | Place a function with a body or a `static mut` in object-file section `s`; a `static mut` in a section is defined also when no code names it (Unsafe Placement below) |
| `@unsafe(naked)` | The function's `asm` statements are its whole machine code: no prologue or epilogue (Unsafe Placement below) |

A constant-expression attribute argument (`@align(LINE * 2)`) is an ordinary expression: names
resolve at module scope (in the `extend` scope for a member; `@reads`/`@writes` also see the
function's parameters), the argument checks against the type the attribute declares and folds at
compile time like a `const` initializer. An attribute with several arguments checks each against
its own type and arity ("attribute '@reads' takes 2 arguments"). A misspelled name, a
type mismatch or an argument that does not fold is an error at the argument. The formatter prints
the argument as an expression, and the language server completes, hovers, renames and finds names
inside it. A lone integer literal keeps the literal form and emits the same C.

`@no_const` does not pass through fields: the type author tags each type. std tags its OS and
runtime handles (`Atomic`, `Arc`, locks, channels, threads, sockets, the scheduler); value
helpers (`Duration`, `IoError`) stay untagged.

An attribute appears at most once on one declaration (item, method, field, variant, extern
item), whatever its arguments: a second `@align`, `@platform`, `@derive`, `@reflect`,
`@link`, or any other is the parse error `duplicate attribute '@NAME'`. Put several values in
one occurrence (`@derive(Format, Hash)`, `@reflect(a, b = 1)`, `@platform(linux | macos)`).

### Branch Hints

`likely(c)` and `unlikely(c)` (prelude, `std/core.spc`) return `c`, also in a constant. The `if`
or loop condition that tests the call tells the C compiler of an `--emit-c` tree which way the
branch usually goes: `if (__builtin_expect(c, 1))` or `(c, 0)`. The native build marks the rare
side unlikely: its blocks go after the warm code, the branch stays a branch (no select), the warm
code gets the registers first, and a body whose calls are all on rare sides sets its frame up only
there (shrink-wrapping). Wrap the WHOLE condition: a hint on one operand of
`||` or `&&` stays inside the lowered short circuit and the final branch has none.

```superc
for x in xs {
    if unlikely(x < lo || x == lo && x.is_sign_negative()) {
        lo = x;
    }
}
```

Use a hint where the branch is predictable and its taken side is rare: an error or slow path, a
new minimum in a scan. There it also stops the compiler from turning the branch into selects,
which chain each iteration to the previous one: Apple clang does this to the loop above without
the hint (3.06 ns per element on an M5 Pro, 0.55 with it). A wrong hint costs the mispredicted
side; leave unpredictable branches unhinted.

### Unsafe Placement

`@unsafe(...)` lists claims the compiler cannot check, in any order, each once, in one
attribute per declaration (`@unsafe(link_section = "__TEXT,__boot,regular,pure_instructions", naked)`).
A section is written only as `@unsafe(link_section = ...)`: it changes what the linker and the loader
assume about the symbol. The C definition carries `__attribute__((used, section("s")))`: `used`
keeps link-time optimization from inlining or dropping the symbol, and its section with it.

- `link_section = "s"`: on a function with a body or a `static mut`, neither in an extern block. The
  name holds letters, digits, `_`, `.` and `$`. On macOS and iOS (Mach-O) it is
  `segment,section[,type[,attributes[,stub size]]]`, segment and section 1 to 16 bytes each, `+`
  between attributes; on the other targets one name. On wasm32 only a `static mut` takes one (a data
  segment name): every function is in the code section.
- `naked`: on a function with a body outside an extern block; the C definition is
  `__attribute__((naked, noinline))`. The body holds only `asm("...");` statements without operands
  or clobbers (basic assembly, at least one), which need no `unsafe` block; the assembly reads the
  parameters where the C calling convention puts them and returns itself. Every parameter and the
  result is an integer, float, `bool`, `char` or raw pointer (one result at most, or `!`). Not generic,
  not in a generic extend, not a `const fn`, not `@inline` or `@always_inline`. A call needs no
  `unsafe`. wasm32 is an error. The native generators emit the templates alone (`Body.naked`); the
  `--emit-c` tree stops with `#error` unless its C compiler is Clang, or GCC 8 or later on x86-64
  (GCC has no naked functions on aarch64).
  The unused-parameter lint skips a naked function.

### Module-Level Assembly

`asm("...");` at module level is file-scope basic assembly: the template alone, a string or a
matchertext literal (`asm(M"(...)");`), in the module's unit ("a module-level 'asm' takes only its
template: no operands or clobbers"). Gate it with `@platform` and `@arch`. It defines symbols that
only an `extern "C"` declaration names, so a module that holds one is always emitted, also when no
Super-C item of it is used. Spell each symbol as the target's object format does (a leading `_`
on Apple targets).
