// Type-coupled standard interfaces: the ones whose method shapes mention another prelude type (String,
// Option, Result, Range, slices). They live apart from the base `interfaces` module so that the value
// types can import the base interfaces and conform to them WITHOUT a header include cycle (a type module
// importing `interfaces` must not transitively import that same type module). Interfaces have no C
// representation, so prelude types conform to THESE freely too (String as Format, the iterators, the
// Index conformances) -- the interface reference never pulls this module's header. Part of the
// auto-imported prelude, so the names resolve unqualified everywhere.

/// A human-readable rendering of the value.
pub interface Format {
    fn fmt(self: &Self) String;
}

/// A sink of bytes (files, buffers, sockets). `write` returns the number of bytes accepted.
pub interface Writer {
    fn write(self: &mut Self, bytes: []u8) usize;
}

/// A source of values produced one at a time; `next` yields `None` when exhausted.
pub interface Iterator<T> {
    fn next(self: &mut Self) Option<T>;
}

/// Fallible value conversion. `TryFrom` is the one a type implements; `TryInto` is its compiler-provided
/// mirror (`x.try_into()` -> `U::try_from(x)`), so implementing `TryFrom` gives `.try_into()` for free.
pub interface TryFrom<T> {
    fn try_from(value: T) Result<Self, i32>;
}
pub interface TryInto<T> {
    fn try_into(self: Self) Result<T, i32>;
}

/// Index operator overloading. `T` is the element yielded by `obj[i]`; `S` is the sub-view yielded by
/// `obj[lo..hi]` (`[]T` for containers, `str` for string types). `obj[i]` dispatches to `index`, and a
/// reference-returning `index` makes `obj[i]` the element PLACE itself (the compiler inserts the deref),
/// so containers hand out borrowed elements, never copies. `obj[lo..hi]` -- any range form: `lo..hi`,
/// `lo..=hi`, `lo..`, `..hi`, `..=hi` -- dispatches to `index_range` with the written bounds packed into
/// a `Range<usize>` exactly as spelled (an inclusive `..=` arrives with `r.inclusive` set); a missing
/// start is 0, and a missing end is the value's `len()`, so open-ended forms additionally require a
/// `len` method on the type.
pub interface Index<T, S> {
    fn index(self: &Self, i: usize) &T;
    fn index_range(self: &Self, r: Range<usize>) S;
}

/// The writable counterpart. `obj[i] = v` stores through the `&mut T` that `index_mut` returns (a
/// compound `obj[i] += v` reads and writes through it; a plain `=` over a `Free` element frees the
/// replaced value first, like a binding reassignment). `S` is the writable sub-view (`[]mut T`);
/// `index_range_mut` is called explicitly -- `obj[lo..hi]` always takes the read-only `index_range`.
pub interface IndexMut<T, S> {
    fn index_mut(self: &mut Self, i: usize) &mut T;
    fn index_range_mut(self: &mut Self, r: Range<usize>) S;
}
