// Range<T>: the value a `lo..hi` (or inclusive `lo..=hi`) expression lowers to when used as a value
// rather than a `for` iterable, `switch` pattern, or `a[lo..hi]` slice (those are handled structurally
// and never build a Range). Plain data: bind it, pass it around, and `for x in r` counts start..end.
/// The value of `a..b` / `a..=b`.
pub struct Range<T> {
    pub start: T, // first value (inclusive)
    pub end: T, // last value: excluded for `..`, included for `..=`
    pub inclusive: bool,
}
