# Super-C

Super-C is an experimental C-like systems programming language that compiles to C.

The project aims to provide a modern frontend for low-level programming while keeping the portability and performance model of C. Super-C is not a C dialect and does not attempt to preserve ISO C syntax exactly. It is a new language that uses C as its compilation target.

Super-C source code will be parsed by a custom compiler, checked by the frontend, lowered into portable C code, and then compiled by an existing C compiler such as Clang, GCC, or MSVC.

## Purpose

Super-C exists to explore a safer and more expressive C-like language design without abandoning the C ecosystem.

The compiler will eventually translate Super-C source files into readable C code. The generated C code can then be compiled by standard C toolchains to produce native binaries.

The intended compilation pipeline is:

```text
Super-C source
    -> lexer
    -> parser
    -> semantic analysis
    -> intermediate lowering
    -> C code generation
    -> Clang, GCC, or MSVC
    -> native binary
```

## Example Syntax

The syntax is still experimental, but Super-C is intended to look familiar to C programmers while avoiding some of C's parsing and safety problems.

Example variable declarations:

```superc
let x: int = 10;
let y = 20;
let mut count: int = 0;
```

Example function:

```superc
fn add(a: int, b: int) int {
    return a + b;
}
```

Example resource cleanup with `defer`:

```superc
fn main() i32 {
    let file = File.open("data.txt");

    defer file.close();

    // Do stuff with the file
    ...

    return 0;
}
```

Example pattern matching:

```superc
fn classify(c: u8) int {
    return match c {
        '0'..='9' => 1,
        'a'..='z' => 2,
        'A'..='Z' => 3,
        _ => 0,
    };
}
```

Example trait-style abstraction:

```superc
trait Writer {
    fn write(self: *mut Self, bytes: []u8) usize;
}

fn write_all<T: Writer>(writer: *mut T, data: []u8) {
    writer.write(data);
}
```

Example generated C shape:

```c
int add(int a, int b) {
    return a + b;
}
```

Super-C code is intended to lower into ordinary C constructs such as functions, structs, enums, unions, explicit cleanup calls, and direct function calls.

## Design Direction

Super-C is designed around a grammar that is easier to parse than C.

Declarations use explicit keywords such as `let`, `fn`, `struct`, `enum`, `trait`, and `impl`. This avoids C-style ambiguity where the parser needs semantic knowledge to know whether a statement is a declaration or an expression.

For example, Super-C prefers:

```superc
let value: int = 42;
```

instead of:

```c
int value = 42;
```

The goal is to keep the language simple to parse, simple to lower, and compatible with efficient C output.

## C Interoperability

Super-C is intended to interoperate with existing C libraries through FFI bindings.

C APIs can be exposed through raw external declarations:

```superc
extern "C" {
    type CFile;

    fn fopen(path: *const char, mode: *const char) *mut CFile;
    fn fclose(file: *mut CFile) int;
}
```

Raw bindings are expected to remain low-level and unsafe. Higher-level Super-C libraries can wrap them with safer abstractions.

Super-C should not require rewriting entire C libraries. Existing C APIs can remain in C, while Super-C provides safer wrappers where useful.

## Performance Model

Super-C is intended to compile to efficient C.

The language design avoids any extra garbage collection, heap allocation, dynamic dispatch, and runtime reflection. Most high-level features are intended to lower into explicit C code.

The generated C should be simple enough for Clang, GCC, or MSVC to optimize effectively.

## Future Features

Super-C has not been implemented yet. The following features are planned or under consideration.

### Core Language

* C-like syntax
* LL(1)-friendly grammar
* explicit declaration keywords
* local variable declarations with optional type annotations
* type inference for local variables
* mutable and immutable bindings
* structs
* enums
* tagged enum variants with payloads
* functions
* blocks and lexical scopes
* pointers and references
* slices
* explicit casts
* module-level items

### Resource Management

* RAII-style cleanup
* destructors through a `Drop` trait
* deterministic cleanup at scope exit
* `defer` statements
* move semantics
* drop analysis
* prevention of double-drops after moves

### Error Handling

* `Result<T, E>` style value-based errors
* `Option<T>` style optional values
* pattern matching over result and option types
* possible `?` operator for early error returns

### Traits and Generics

* Rust-like traits
* trait implementations
* bounded generics
* static dispatch by default
* monomorphized generic functions
* explicit dynamic dispatch as a later feature

### Pattern Matching

* `match` expressions
* exhaustive matching
* wildcard patterns
* enum variant patterns
* scalar literal patterns
* scalar range patterns such as `'0'..='9'`
* guarded match arms

### Operators

* overloading of existing operators
* trait-based operator resolution
* fixed precedence table
* possible custom two-character operators as a later feature
* no arbitrary redefinition of core syntax such as assignment, member access, or short-circuit logic

### C Backend

* C code generation
* readable generated C
* `#line` directives for diagnostics
* integration with Clang, GCC, and MSVC
* generated headers
* generated raw C bindings
* optional safe wrappers around C APIs

### Compiler Internals

* lexer
* LL(1)-style parser
* AST
* name resolution
* type checking
* ownership and move analysis
* trait resolution
* generic monomorphization
* intermediate representation
* language-level optimization before C emission
* C AST or C IR
* C code emitter

## Project Status

Super-C is currently a language design and compiler planning project.

The first milestone is to define the syntax, semantics, compiler architecture, and C lowering model. Implementation will begin after the core language specification is stable enough to support a minimal compiler frontend.
