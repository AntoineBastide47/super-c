# Operation Semantics

This table is normative. Every scalar, pointer, atomic, and control operation has one of these
results:

| Result | Meaning |
|--------|---------|
| wraps | The result is the exact value modulo 2^N of the result type. |
| traps | The program prints a message and aborts, in every profile. |
| checked trap | Traps in a profile with overflow checks; wraps in a profile without them. |
| defined | A defined value, given in the row. |
| undefined | The program has no defined behavior. A checking mode can report it; the compiler does not. |

Compile-time evaluation (CTFE) and the compiled program give the same value or the same trap for
every operation in this file. Where the program traps, a constant evaluation is a compile error
("arithmetic overflow", "division by zero", "shift out of range"). The emitted C has no C undefined
behavior for an integer, float, or pointer-comparison operation.

An integer operation that traps on every execution is an error at the operation, in every body
(a closure and a generic body included) and every initializer: an operation over closed operands
(literals, constants, builtin limits, enum variants, `sizeof`, but no call and no build constant)
that traps, a division or remainder by a closed zero, and a shift by a closed count out of range,
whatever the other operand ("this operation is undefined behavior when executed: division by
zero"). In a `const` or `static mut` initializer the message names the item ("static 'S' cannot be
evaluated at compile time: arithmetic overflow"), used or not, and a static_assert, an enum
discriminant or an array length keeps its own message; a trap reached through a call is reported at
the item's name. A generic body is checked once, over the operations whose operands do not depend
on a type parameter, with the note that every instantiation traps. A test function, a branch a
closed condition makes dead (`if false`, `if sizeof(usize) == 4`, the right operand of
`Z != 0 && 10 / Z > 1` with `Z` zero), and code the platform filter removed are not checked; a
branch under `PROFILE` is.

## Profiles

`dev`, `debug`, `test`, and `race` check overflow; `release`, `bench`, and `pgogen` wrap. A
custom profile checks at `opt-level` 0 or 1 (or no `opt-level`) and wraps at 2, 3, `"s"`, and
`"z"`; `overflow-checks = true/false` overrides that (super-c-binary, "Built-in profiles").

## Integers

The rules apply to every built-in integer (`i8` to `i64`, `isize`, `u8` to `u64`, `usize`) at its
own width, and to std's `Int<N>` and `UInt<N>` where the row says so. `usize` and `isize` have the
target's pointer width (32 bits on wasm32), in compile-time evaluation too.

| Operation | Result |
|-----------|--------|
| `+ - *`, compound forms (`+=`), a loop step, `pow()` and `+ - *` of `Int<N>`/`UInt<N>` | checked trap: "attempt to add with overflow", "attempt to subtract with overflow", "attempt to multiply with overflow" |
| unary `-` of a signed MIN, `abs()` of MIN (also `Int<N>`) | checked trap: "attempt to negate with overflow" |
| unary `-` of an unsigned type | compile error ("cannot apply unary operator '-' to type 'u32'"), `-0` too |
| `/` and `%` by zero | traps: "attempt to divide by zero", "attempt to calculate the remainder with a divisor of zero" |
| signed `MIN / -1`, `MIN % -1` | traps: "attempt to divide with overflow", "attempt to calculate the remainder with overflow" (also `Int<N>`) |
| `<<`, `>>` by a negative count or by the width or more | traps: "attempt to shift left with overflow", "attempt to shift right with overflow" |
| signed `<<` in range | defined: shifts the two's complement bits; bits shifted out are lost (`-1 << 1` is -2) |
| signed `>>` in range | defined: arithmetic shift |
| bitwise `& \| ^ ~` | defined |
| comparison | defined |
| mixed widths (`u8 + u64`, `u32 + i64`) | the checker widens the operand; the operation computes at the result type |
| shift | computes at the left operand's type |

### Explicit overflow methods

Every built-in integer has these methods. They never trap and give the same result in every
profile. They are plain std source (`std/core.spc`) over the `sc_w*64` and `sc_mulo_*64` helpers
of `std/bits.h` and evaluate at compile time, also inside a `const fn`.

| Methods | Result |
|---------|--------|
| `wrapping_add/sub/mul(rhs)`, `wrapping_neg()` | wraps (`u8::MAX.wrapping_add(1)` is 0, `i8::MIN.wrapping_neg()` is MIN) |
| `wrapping_shl/shr(n: u32)` | the count modulo the width (`1u8.wrapping_shl(9)` is 2); `shr` is arithmetic on signed types |
| `overflowing_add/sub/mul(rhs)` | the wrapped value and whether it overflowed: `let (r, o) = a.overflowing_add(b);` |
| `checked_add/sub/mul/div/rem(rhs)`, `checked_neg()`, `checked_shl/shr(n: u32)` | `Option`: `None` on overflow, a zero divisor, MIN / -1, a count of the width or more, or an unsigned negation of a nonzero value |
| `saturating_add/sub/mul(rhs)` | clamped to `MIN` or `MAX` |

Use them for every intentional wraparound: hashes, random number generators, checksums, and two's
complement bit tricks (`x & x.wrapping_neg()`).

`trailing_zeros()`, `leading_zeros()`, and `count_ones()` return `usize`; a zero input gives the bit
width, and a signed value counts its two's complement pattern.

## Conversions

| Conversion | Result |
|------------|--------|
| integer to integer `as` | wraps to the target width (sign-extends a signed source, zero-extends an unsigned one, then truncates) |
| float to integer `as` | defined: truncates toward zero and saturates; a value past either end is that end; NaN is 0 (`1e20 as i32` is 2147483647) |
| integer to float `as` | defined: round to nearest, ties to even |
| float to float `as` | defined: round to nearest, ties to even |
| `char` | 1 byte, unsigned (0 to 255) on every target |
| an enum or tagged-union value whose discriminant is not declared | undefined |
| a `bool` whose byte is not 0 or 1 | undefined |

## Floating point

| Rule | Decision |
|------|----------|
| format | IEEE 754 binary32 (`f32`) and binary64 (`f64`) |
| rounding | round to nearest, ties to even |
| literal | rounds once from its decimal or hex text to its type (the context's type, `f32` without one); never through the other width |
| contraction | none: `a * b + c` rounds twice; every C compile passes `-ffp-contract=off`; only an explicit `fma` fuses |
| `%` | the C `fmod` remainder: the sign of the dividend (`-7.5 % 2.0` is -1.5) |
| NaN payload of an arithmetic result | not specified |
| `==`, `<` operators | IEEE: NaN is unordered, `-0.0 == 0.0` |
| `Eq`, `Ord`, `Hash` | the IEEE 754 total order (`total_cmp`): NaN equals itself, `-0.0` differs from `0.0` |

## Pointers

| Rule | Decision |
|------|----------|
| creation outside `[base, one-past]` of an object | undefined |
| one-past pointer | can be made, compared, and subtracted; not dereferenced |
| subtraction | both pointers in one object, the distance an exact multiple of `sizeof(T)`; a zero-sized `T` traps ("pointer distance on a zero-sized element type") |
| ordered comparison (`< <= > >=`) | defined: compares addresses, across objects too (emitted as a `uintptr_t` comparison) |
| equality | defined: compares addresses |
| exposure and round trips | `p as usize` exposes the object; `n as *T` is valid for access only inside an exposed live object; a round trip in one data flow keeps the object ([Rust `with_exposed_provenance`](https://doc.rust-lang.org/std/ptr/fn.with_exposed_provenance.html)) |
| zero-sized types | `p + n` is `p`; a zero-byte access touches nothing |
| dereference | the pointer is non-null, aligned, and addresses `sizeof(T)` bytes of one live object with the access permission; otherwise undefined |

## Atomics

Memory-order codes: `Relaxed` 0, `Acquire` 1, `Release` 2, `AcqRel` 3, `SeqCst` 4.

| Operation | Valid orders |
|-----------|--------------|
| load, compare-exchange failure | `Relaxed`, `Acquire`, `SeqCst` |
| store | `Relaxed`, `Release`, `SeqCst` |
| read-modify-write, compare-exchange success, fence | all five |

An order that the operation cannot take traps ("invalid memory order"). A compare-exchange
failure order stronger than its success order strengthens the success order. A constant valid
order costs nothing at run time.

## Control

| Rule | Decision |
|------|----------|
| control reaches a point the compiler marks unreachable | traps (`abort()`) |
| a `switch` on a value that is not a declared discriminant | undefined |

## Calls, allocation, and values

| Rule | Decision |
|------|----------|
| an indirect call through a value of the wrong signature | undefined |
| a call through an invalid dispatch table | undefined |
| a variadic argument of the wrong kind | undefined |
| an invalid alignment value | undefined |
| an invalid allocator size or alignment | undefined |
| `new T` when the allocator returns null | traps: "out of memory" |
| element count times element size overflows in `Vector` or `String` | traps ("Vector: capacity overflow", "String: capacity overflow") |
| a program's own `n * sizeof(T)` | follows the integer rules above |

## Traps and exit status

A runtime trap prints `super-c: <message>`; a `panic` prints `panic: <message>`. Inside a task,
`[task <id>] ` precedes the message. Then the process calls `abort()`. `SC_LEAK_CHECK=fatal` exits
with status 23 after a leak report (super-c-testing).
