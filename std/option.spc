// Option<T>: an optional value; `Some(T)` or `None`. A payload-bearing generic enum, monomorphized
// per element type. Methods that yield the contained value CONSUME `self` (Rust's by-value `Option`):
// matching an owned value moves the payload out, so the source is not double-freed; a payload or argument a
// method discards is freed. Read-only methods take `&self` and bind the payload by reference (`switch`
// binding modes); a closure that only reads the payload borrows it (`&T`). `Option<T>` is auto-`Free`
// exactly when `T` is (conditional conformance): freeing a `Some(t)` deep-frees its payload. Every
// operation is O(1) besides the closures and payload methods it calls, and allocates nothing.
//
// An extend cannot target one nested instance (`Option<&T>`, `Option<Option<T>>`), so the operations on
// those are associated functions that take the Option as an argument: `Option::copied(o)`,
// `Option::cloned(o)`, `Option::flatten(o)`, `Option::unzip(o)`, `Option::transpose(o)`. Ordering puts
// `None` before every `Some`.

/// An optional value: `Some(T)` or `None`.
pub enum Option<T> {
    Some(T),
    None,
}

/// The iterator of `Option::iter` and `Result::iter`: zero or one borrowed payload, exact size,
/// double-ended.
pub struct OptionIter<'a, T> {
    pub(package) item: Option<&'a T>,
}

extend<T> Option<T> {
    /// `Some(value)`.
    pub const fn some(value: T) Option<T> {
        return Option::<T>::Some(value);
    }

    /// `None`.
    pub const fn none() Option<T> {
        return Option::<T>::None;
    }

    /// True for `Some`.
    pub const fn is_some(self: &Option<T>) bool {
        return switch self {
            Some(_) => true,
            None => false,
        };
    }

    /// True for `None`.
    pub const fn is_none(self: &Option<T>) bool {
        return switch self {
            Some(_) => false,
            None => true,
        };
    }

    /// The contained value; panics on `None`. Consumes `self`.
    pub const fn unwrap(self: Option<T>) T {
        return switch self {
            Some(v) => v,
            None => panic("Option::unwrap on None"),
        };
    }

    /// The contained value; panics with `msg` on `None`. Consumes `self`.
    pub const fn expect(self: Option<T>, msg: str) T {
        return switch self {
            Some(v) => v,
            None => panic(msg),
        };
    }

    /// The contained value, or `default` when empty. Consumes `self` (matching the owned value moves the
    /// payload out); the unused alternative is freed by scope-exit auto-`Free`.
    pub const fn unwrap_or(self: Option<T>, default: T) T {
        return switch self {
            Some(v) => v,
            None => default,
        };
    }

    /// The contained value, or `f()` computed lazily when empty. Consumes `self`.
    pub const fn unwrap_or_else(self: Option<T>, f: fn() T) T {
        return switch self {
            Some(v) => v,
            None => f(),
        };
    }

    /// Replace the value in place (returns the previous Option). The old payload travels out in `old`.
    pub const fn replace(self: &mut Option<T>, value: T) Option<T> {
        return replace(self, Option::<T>::Some(value));
    }

    /// Take the value out in place, leaving `None` behind (returns the previous Option).
    pub const fn take(self: &mut Option<T>) Option<T> {
        return replace(self, Option::<T>::None);
    }

    /// Map the contained value through `f`, producing `Option<U>` (`None` stays `None`). Consumes `self`.
    pub const fn map<U, F: fn(T) U>(self: Option<T>, f: F) Option<U> {
        return switch self {
            Some(v) => Option::<U>::Some(f(v)),
            None => Option::<U>::None,
        };
    }

    /// Map the contained value, or return `default` when empty. Consumes `self`; frees the unused `default`
    /// on the `Some` path (a no-op for non-`Free` types).
    pub const fn map_or<U, F: fn(T) U>(self: Option<T>, default: U, f: F) U {
        return switch self {
            Some(v) => f(v),
            None => default,
        };
    }

    /// Chain a fallible step: `f` itself returns an `Option<U>` (flat-map / "bind"). Consumes `self`.
    pub const fn and_then<U, F: fn(T) Option<U>>(self: Option<T>, f: F) Option<U> {
        return switch self {
            Some(v) => f(v),
            None => Option::<U>::None,
        };
    }

    /// Keep the value only when `pred` holds, else `None`. Consumes `self`; `pred` BORROWS the payload
    /// (`&T`) through the `&self` match, before `self` is moved. On rejection `self` is freed by
    /// scope-exit auto-`Free`.
    pub const fn filter<F: fn(&T) bool>(self: Option<T>, pred: F) Option<T> {
        let keep = switch &self {
            Some(v) => pred(v),
            None => false,
        };
        if keep {
            return self;
        }
        return Option::<T>::None;
    }

    /// `self` when it holds a value, otherwise `other`. Consumes both; the unused alternative is freed by
    /// scope-exit auto-`Free`.
    pub const fn or(self: Option<T>, other: Option<T>) Option<T> {
        return switch self {
            Some(v) => Option::<T>::Some(v),
            None => other,
        };
    }

    /// `None` when `self` is empty, otherwise `other`. Consumes both: on `Some` the discarded `self` payload
    /// is freed and `other` is returned; on `None` the unused `other` param is freed by auto-`Free`.
    pub const fn and<U>(self: Option<T>, other: Option<U>) Option<U> {
        return switch self {
            Some(v) => {
                other;
            },
            None => Option::<U>::None,
        };
    }

    /// True for `Some(v)` when `f(&v)` holds. `f` borrows the payload.
    pub const fn is_some_and<F: fn(&T) bool>(self: &Option<T>, f: F) bool {
        return switch self {
            Some(v) => f(v),
            None => false,
        };
    }

    /// True for `None`, and for `Some(v)` when `f(&v)` holds. `f` borrows the payload.
    pub const fn is_none_or<F: fn(&T) bool>(self: &Option<T>, f: F) bool {
        return switch self {
            Some(v) => f(v),
            None => true,
        };
    }

    /// A borrow of the payload, as an `Option<&T>`.
    pub const fn as_ref(self: &Option<T>) Option<&T> {
        return switch self {
            Some(v) => Option::<&T>::Some(v),
            None => Option::<&T>::None,
        };
    }

    /// A mutable borrow of the payload, as an `Option<&mut T>`.
    pub const fn as_mut(self: &mut Option<T>) Option<&mut T> {
        return switch self {
            Some(v) => Option::<&mut T>::Some(v),
            None => Option::<&mut T>::None,
        };
    }

    /// `Ok(v)` for `Some(v)`, `Err(err)` for `None`. Consumes both; the unused `err` is freed.
    pub const fn ok_or<E>(self: Option<T>, err: E) Result<T, E> {
        return switch self {
            Some(v) => Result::<T, E>::Ok(v),
            None => Result::<T, E>::Err(err),
        };
    }

    /// `Ok(v)` for `Some(v)`, `Err(f())` for `None`; `f` runs only when empty. Consumes `self`.
    pub const fn ok_or_else<E, F: fn() E>(self: Option<T>, f: F) Result<T, E> {
        return switch self {
            Some(v) => Result::<T, E>::Ok(v),
            None => Result::<T, E>::Err(f()),
        };
    }

    /// `f(v)` for `Some(v)`, `default()` for `None`; exactly one of them runs. Consumes `self`.
    pub const fn map_or_else<U, D: fn() U, F: fn(T) U>(self: Option<T>, default: D, f: F) U {
        return switch self {
            Some(v) => f(v),
            None => default(),
        };
    }

    /// `self` when it holds a value, otherwise `f()`; `f` runs only when empty. Consumes `self`.
    pub const fn or_else<F: fn() Option<T>>(self: Option<T>, f: F) Option<T> {
        return switch self {
            Some(v) => Option::<T>::Some(v),
            None => f(),
        };
    }

    /// The one value when exactly one of `self` and `other` holds a value, else `None`. Consumes both;
    /// a discarded payload is freed.
    pub const fn xor(self: Option<T>, other: Option<T>) Option<T> {
        return switch self {
            Some(v) => switch other {
                Some(_) => Option::<T>::None,
                None => Option::<T>::Some(v),
            },
            None => other,
        };
    }

    /// `Some((a, b))` when both hold a value, else `None`. Consumes both; a discarded payload is freed.
    pub const fn zip<U>(self: Option<T>, other: Option<U>) Option<(T, U)> {
        return switch self {
            Some(a) => switch other {
                Some(b) => Option::<(T, U)>::Some((a, b)),
                None => Option::<(T, U)>::None,
            },
            None => Option::<(T, U)>::None,
        };
    }

    /// Splits `Some((a, b))` into `Some(a), Some(b)`, and `None` into two `None`s. An associated function
    /// (`Option::unzip(o)`): an extend cannot target the instance `Option<(T, B)>` alone.
    pub const fn unzip<B>(o: Option<(T, B)>) (Option<T>, Option<B>) {
        switch o {
            Some((a, b)) => {
                return Option::<T>::Some(a), Option::<B>::Some(b);
            },
            None => {
                return Option::<T>::None, Option::<B>::None;
            },
        };
    }

    /// The inner Option of `Some(inner)`, and `None` for `None` (`Option::flatten(o)`).
    pub const fn flatten(o: Option<Option<T>>) Option<T> {
        return switch o {
            Some(inner) => inner,
            None => Option::<T>::None,
        };
    }

    /// `Some(v)` turned into `Ok(Some(v))`, `Some(Err(e))` into `Err(e)`, `None` into `Ok(None)`
    /// (`Option::transpose(o)`).
    pub const fn transpose<E>(o: Option<Result<T, E>>) Result<Option<T>, E> {
        return switch o {
            Some(r) => switch r {
                Ok(v) => Result::<Option<T>, E>::Ok(Option::<T>::Some(v)),
                Err(e) => Result::<Option<T>, E>::Err(e),
            },
            None => Result::<Option<T>, E>::Ok(Option::<T>::None),
        };
    }

    /// The payload, after storing `value` when empty; the unused `value` is freed.
    pub const fn get_or_insert(self: &mut Option<T>, value: T) &mut T {
        if self.is_none() {
            *self = Option::<T>::Some(value);
        }
        return self.payload_mut();
    }

    /// The payload, after storing `f()` when empty; `f` runs only when empty.
    pub fn get_or_insert_with<F: fn() T>(self: &mut Option<T>, f: F) &mut T {
        if self.is_none() {
            *self = Option::<T>::Some(f());
        }
        return self.payload_mut();
    }

    /// Stores `value`, freeing the old payload, and returns a borrow of the new one.
    pub const fn insert(self: &mut Option<T>, value: T) &mut T {
        *self = Option::<T>::Some(value);
        return self.payload_mut();
    }

    /// Takes the value out, leaving `None`, when `pred` holds for it; else leaves `self` as it is and
    /// returns `None`. `pred` borrows the payload.
    pub fn take_if<P: fn(&T) bool>(self: &mut Option<T>, pred: P) Option<T> {
        let hit = switch self {
            Some(v) => pred(v),
            None => false,
        };
        if hit {
            return self.take();
        }
        return Option::<T>::None;
    }

    /// Runs `f` on the payload when there is one, then returns `self`. `f` borrows the payload.
    pub fn inspect<F: fn(&T) void>(self: Option<T>, f: F) Option<T> {
        switch &self {
            Some(v) => f(v),
            None => {},
        };
        return self;
    }

    /// An iterator over the payload: one `&T` for `Some`, nothing for `None`.
    pub const fn iter(self: &Option<T>) OptionIter<T> {
        return switch self {
            Some(v) => OptionIter::<T> { item: Option::<&T>::Some(v) },
            None => OptionIter::<T> { item: Option::<&T>::None },
        };
    }

    // The payload of an Option the caller just filled.
    const fn payload_mut(self: &mut Option<T>) &mut T {
        return switch self {
            Some(v) => v,
            None => panic("Option: no value"),
        };
    }
}

extend<T: Default> Option<T> {
    /// The contained value, or `T::default()` when empty. Consumes `self`.
    pub fn unwrap_or_default(self: Option<T>) T {
        return switch self {
            Some(v) => v,
            None => T::default(),
        };
    }
}

extend<T: Copy> Option<T> {
    /// `Some(*r)` for `Some(r)` (`Option::copied(o)`).
    pub const fn copied(o: Option<&T>) Option<T> {
        return switch o {
            Some(r) => Option::<T>::Some(*r),
            None => Option::<T>::None,
        };
    }
}

extend<T: Clone> Option<T> {
    /// `Some(r.clone())` for `Some(r)` (`Option::cloned(o)`).
    pub const fn cloned(o: Option<&T>) Option<T> {
        return switch o {
            Some(r) => Option::<T>::Some(r.clone()),
            None => Option::<T>::None,
        };
    }
}

// The default Option is the empty one.
extend<T> Option<T> as Default {
    pub const fn default() Option<T> {
        return Option::<T>::none();
    }
}

// Auto-`Free` exactly when the payload is: freeing a `Some(t)` deep-frees `t` in place (the `&mut self`
// match binds the payload by reference).
extend<T: Free> Option<T> as Free {
    pub fn free(self: &mut Option<T>) {
        switch self {
            Some(v) => v.free(),
            None => {},
        };
    }
}

// Conditional conformances: an Option is Clone/Eq/Ord/Hash exactly when its payload is. Each binds the payload
// by reference (`&self` match) and dispatches to the payload's own bound method.
extend<T: Clone> Option<T> as Clone {
    pub const fn clone(self: &Option<T>) Option<T> {
        return switch self {
            Some(v) => Option::<T>::Some(v.clone()),
            None => Option::<T>::None,
        };
    }
}

extend<T: Eq> Option<T> as Eq {
    pub const fn eq(self: &Option<T>, other: &Option<T>) bool {
        return switch self {
            Some(a) => switch other {
                Some(b) => *a == *b,
                None => false,
            },
            None => other.is_none(),
        };
    }
}

extend<T: Ord> Option<T> as Ord {
    /// `None` orders before every `Some`; two `Some`s compare their payloads.
    pub const fn cmp(self: &Option<T>, other: &Option<T>) i32 {
        return switch self {
            Some(a) => switch other {
                Some(b) => a.cmp(b),
                None => 1,
            },
            None => switch other {
                Some(_) => -1,
                None => 0,
            },
        };
    }
}

extend<T: Hash> Option<T> as Hash {
    /// A presence byte, then the payload.
    pub fn hash_into<H: Hasher>(self: &Option<T>, h: &mut H) {
        switch self {
            Some(v) => {
                h.write_u8(1);
                v.hash_into(h);
            },
            None => h.write_u8(0),
        };
    }
}

extend<T: Format> Option<T> as Format {
    pub fn fmt(self: &Option<T>) String {
        if self.is_none() {
            return String::from_str("None");
        }
        let inner = switch self {
            // Some: bind and format the payload (None arm is unreachable here).
            Some(v) => v.fmt(),
            None => String::new(),
        };
        let mut s = String::from_str("Some(");
        s.push_string(&inner);
        s.push_str(")");
        return s;
    }
}

extend<T> OptionIter<T> as Iterator<&T> {
    pub const fn next(self: &mut OptionIter<T>) Option<&T> {
        return self.item.take();
    }

    pub const fn size_hint(self: &OptionIter<T>) (usize, Option<usize>) {
        let n: usize = if self.item.is_some() {
            1;
        } else {
            0;
        };
        return n, Option::<usize>::Some(n);
    }
}

extend<T> OptionIter<T> as DoubleEndedIterator<&T> {
    pub const fn next_back(self: &mut OptionIter<T>) Option<&T> {
        return self.item.take();
    }
}
