# Slices and Arrays

## Slices and Arrays

```superc
fn sum(xs: []i32) i32 {       // []T is a (ptr, len) view
    let mut t = 0;
    for x in xs { t = t + x; }
    return t;
}

let a: [i32; 4] = [10, 20, 30, 40];
```

`[]T` / `[]mut T` lower to prelude `Slice<T>` / `SliceMut<T>`; `[]'a T` / `[]'a mut T` name
the lifetime (`Slice<'a, T>` / `SliceMut<'a, T>`), which binds right after `[]` and before
`mut`, as after `&`. `[]mut T` follows Rust's `&mut [T]`: it is not `Copy`, it moves, reborrows
and conflicts as a `&mut` does (see Unsafe), and building a view from raw parts or writing its
`ptr` or `len` needs `unsafe`. A by-value `[]mut T` parameter reaches C as a `restrict` element
pointer and a length (`types.md`). The compiler's own sources (`src/`, `std/`, `ffi/`) spell the named form
`Slice<'a, T>` until a release parses the sugar. Arrays coerce to slices; the view borrows the
array like `&a` (`&mut a` for `[]mut`) and never moves it: the array must outlive the view and
cannot be written, moved or viewed mutably while the view is live. A `[]mut T` coerces to `[]T` (a
generic `[]T` parameter infers `T` from it); the `[]T` borrows the `[]mut T` shared, and a `[]mut T`
passed to a call is a mutable use of it, as a `&mut` argument is. `&mut x[a..b]` on an array, a
`[]mut T` or a container with `index_range_mut` is a `[]mut T`, and `&x[a..b]` a `[]T`. A literal coerced to a slice
(`let s: []u8 = [x, y];`, `f([x, y])`) builds its array in a temporary that lives to the end of
its block, so its view cannot leave the block or be returned. An `if` or `switch` arm whose value
borrows a temporary of the arm (an array viewed as a slice, `&S { .. }`) keeps the temporary to
the end of the block around the whole expression, as if the value stood in place of the
expression: `f(if c { [x] } else { [y, z] })` is valid. A local declared in the arm dies with the
arm, so its view or reference cannot be the arm's value. An `if` or `switch` argument converts
each arm to the parameter's type, as a `let`'s annotation does.

A call or method argument `&x` passes as the view the prelude view interface of `x`'s type gives:
`str` through `AsStr` (`String`), `[]T` through `AsSlice<T>` and, from `&mut x`, `[]mut T` through
`AsSliceMut<T>` (`Vector`, `Array`, `StaticVector`). A user container gets the coercion by
conforming. The view borrows `x` as `x.as_str()` does, a `[]T` parameter infers `T` through the
conformance, and the coercion ranks with the array-to-slice one in overload selection. A `let`'s
annotation, an operand and a `return` keep the explicit method, and an argument `x` without `&`
stays an error whose note names the borrow (passing `x` would move it). An argument `x.as_str()`
(`as_slice`, `as_mut_slice`) on a place is a lint warning with a fix to `&x` (`&mut x`).
`[T; N]` is a distinct type and a value: assignment, an argument, a struct field, a variant payload, a tuple
element, a closure capture and a return copy it. An array literal has its own length; against
an expected `[T; n]` it must have exactly `n` elements (a designated literal may have fewer and
zero-fills the rest), and a nested literal is checked against the element type at every level.
Without an expected type, the first element's type is the one the later elements are checked
against, as an annotation would give it (`[(1u8, 2u8), (3, 4)]`, `[Some(1u8), Some(2)]`), except
by a nested array literal of another length, which reports "array literal element has length 3,
but the first element has length 2". A
repeat `[e; n]` evaluates `e` once and copies the value into every element (`[f(); 4]` calls `f`
once). A
nested literal without an annotation takes its inner length from its elements
(`[[1, 2], [3, 4]]` is `[[i32; 2]; 2]`), and its elements must agree on that length. A symbolic
length (`[T; N]`, `[T; N * 2]` in the generic that declares `N`) is a type of its own: it equals
only the same length, never a count, and an instance folds it at every nesting level
(`G<3>.g` is `[[i32; 3]; 2]` for `g: [[i32; N]; 2]`). `[T; 0]` is a real length, and a zero-length
array is zero-sized like any ZST: it has no storage in C, keeps its element's alignment in an
enclosing struct, and a pointer to one moves by 0 bytes. A zero-length array of an owning element
moves like its element and frees nothing. An array has no `==` or ordering ("does not implement
`Eq`; compare elements"): C would compare addresses.
