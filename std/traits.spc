// Type-coupled standard interfaces: the ones whose method shapes mention another prelude type (String,
// Option, Result, slices). They live apart from the base `interfaces` module so that the value types can
// import the base interfaces and conform to them WITHOUT a header include cycle (a type module importing
// `interfaces` must not transitively import that same type module). Conforming a prelude type to one of
// these would re-introduce the cycle, so they are declarations only here -- user types implement them
// freely. Part of the auto-imported prelude, so the names resolve unqualified everywhere.

// A human-readable rendering of the value.
pub interface Format {
    fn fmt(self: &Self) String;
}

// A sink of bytes (files, buffers, sockets). `write` returns the number of bytes accepted.
pub interface Writer {
    fn write(self: &mut Self, bytes: []u8) usize;
}

// A source of values produced one at a time; `next` yields `None` when exhausted.
pub interface Iterator<T> {
    fn next(self: &mut Self) Option<T>;
}

// Fallible value conversion. `TryFrom` is the one a type implements; `TryInto` is its compiler-provided
// mirror (`x.try_into()` -> `U::try_from(x)`), so implementing `TryFrom` gives `.try_into()` for free.
pub interface TryFrom<T> {
    fn try_from(value: T) Result<Self, i32>;
}
pub interface TryInto<T> {
    fn try_into(self: Self) Result<T, i32>;
}
