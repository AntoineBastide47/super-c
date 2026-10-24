// Result<T, E>: success `Ok(T)` or failure `Err(E)`. A two-parameter payload-bearing generic enum,
// monomorphized per (T, E). Value-yielding methods CONSUME `self` (matching the owned value moves the
// payload out; a payload or argument a method discards is freed); read-only methods take `&self` and bind
// the payload by reference (`switch` binding modes), and a closure that only reads a payload borrows it.
// `Result<T, E>` has no `Free` extend: it derives `Free` whenever `T` or `E` is `Free`, and freeing it
// frees the live payload. Every operation is O(1) besides the closures and payload methods it calls.
//
// The constructors are `Result::ok(v)` and `Result::err(e)`, so the accessors to an `Option` are `get_ok`
// and `get_err` (Rust's `ok()` and `err()`). As for `Option`, the operations on one nested instance are
// associated functions: `Result::copied(r)`, `Result::cloned(r)`, `Result::flatten(r)`,
// `Result::transpose(r)`. Ordering puts every `Ok` before every `Err`. There is no `Default`: neither arm
// is a natural empty value.

/// A success value `Ok(T)` or a failure `Err(E)`.
pub enum Result<T, E> {
    Ok(T),
    Err(E),
}

extend<T, E> Result<T, E> {
    /// `Ok(value)`.
    pub const fn ok(value: T) Result<T, E> {
        return Result::<T, E>::Ok(value);
    }

    /// `Err(error)`.
    pub const fn err(error: E) Result<T, E> {
        return Result::<T, E>::Err(error);
    }

    /// True for `Ok`.
    pub const fn is_ok(self: &Result<T, E>) bool {
        return switch self {
            Ok(_) => true,
            Err(_) => false,
        };
    }

    /// True for `Err`.
    pub const fn is_err(self: &Result<T, E>) bool {
        return switch self {
            Ok(_) => false,
            Err(_) => true,
        };
    }

    /// The success value; panics on `Err`. Consumes `self`. A panic aborts the process with no
    /// unwinding, so the discarded payload is never cleaned up.
    pub const fn unwrap(self: Result<T, E>) T {
        return switch self {
            Ok(v) => v,
            Err(_) => panic("Result::unwrap on Err"),
        };
    }

    /// The success value; panics with `msg` on `Err`. Consumes `self`.
    pub const fn expect(self: Result<T, E>, msg: str) T {
        return switch self {
            Ok(v) => v,
            Err(_) => panic(msg),
        };
    }

    /// The error value; panics on `Ok`. Consumes `self`.
    pub const fn unwrap_err(self: Result<T, E>) E {
        return switch self {
            Ok(_) => panic("Result::unwrap_err on Ok"),
            Err(e) => e,
        };
    }

    /// The success value, or `default` on `Err`. Consumes `self`; the discarded `Err` payload is freed and
    /// the unused `default` (on the `Ok` path) is freed by auto-`Free`.
    pub const fn unwrap_or(self: Result<T, E>, default: T) T {
        return switch self {
            Ok(v) => v,
            Err(e) => {
                default;
            },
        };
    }

    /// The error value, or `default` on `Ok`. Consumes `self`; the discarded `Ok` payload is freed.
    pub const fn err_or(self: Result<T, E>, default: E) E {
        return switch self {
            Ok(v) => {
                default;
            },
            Err(e) => e,
        };
    }

    /// The success value, or `f(error)` computed lazily on the error case. Consumes `self`.
    pub const fn unwrap_or_else(self: Result<T, E>, f: fn(E) T) T {
        return switch self {
            Ok(v) => v,
            Err(e) => f(e),
        };
    }

    /// Map the success value through `f`, leaving an error untouched. Consumes `self`.
    pub const fn map<U, F: fn(T) U>(self: Result<T, E>, f: F) Result<U, E> {
        return switch self {
            Ok(v) => Result::<U, E>::Ok(f(v)),
            Err(e) => Result::<U, E>::Err(e),
        };
    }

    /// Map the error value through `f`, leaving a success untouched. Consumes `self`.
    pub const fn map_err<F, M: fn(E) F>(self: Result<T, E>, f: M) Result<T, F> {
        return switch self {
            Ok(v) => Result::<T, F>::Ok(v),
            Err(e) => Result::<T, F>::Err(f(e)),
        };
    }

    /// Chain a fallible step on the success value; `f` returns its own `Result` (flat-map). Consumes `self`.
    pub const fn and_then<U, F: fn(T) Result<U, E>>(self: Result<T, E>, f: F) Result<U, E> {
        return switch self {
            Ok(v) => f(v),
            Err(e) => Result::<U, E>::Err(e),
        };
    }

    /// `self` when it is `Ok`, otherwise `other`. Consumes both; the discarded `Err` payload is freed and
    /// the unused `other` (on the `Ok` path) is freed by auto-`Free`.
    pub const fn or(self: Result<T, E>, other: Result<T, E>) Result<T, E> {
        return switch self {
            Ok(v) => Result::<T, E>::Ok(v),
            Err(e) => {
                other;
            },
        };
    }

    /// The success value as an `Option` (`Err` becomes `None`). Consumes `self`; the discarded `Err` payload
    /// is freed.
    pub const fn get_ok(self: Result<T, E>) Option<T> {
        return switch self {
            Ok(v) => Option::<T>::Some(v),
            Err(e) => {
                Option::<T>::None;
            },
        };
    }

    /// The error value as an `Option` (`Ok` becomes `None`). Consumes `self`; the discarded `Ok` payload is
    /// freed.
    pub const fn get_err(self: Result<T, E>) Option<E> {
        return switch self {
            Ok(v) => {
                Option::<E>::None;
            },
            Err(e) => Option::<E>::Some(e),
        };
    }

    /// True for `Ok(v)` when `f(&v)` holds. `f` borrows the payload.
    pub const fn is_ok_and<F: fn(&T) bool>(self: &Result<T, E>, f: F) bool {
        return switch self {
            Ok(v) => f(v),
            Err(_) => false,
        };
    }

    /// True for `Err(e)` when `f(&e)` holds. `f` borrows the payload.
    pub const fn is_err_and<F: fn(&E) bool>(self: &Result<T, E>, f: F) bool {
        return switch self {
            Ok(_) => false,
            Err(e) => f(e),
        };
    }

    /// A borrow of either payload, as a `Result<&T, &E>`.
    pub const fn as_ref(self: &Result<T, E>) Result<&T, &E> {
        return switch self {
            Ok(v) => Result::<&T, &E>::Ok(v),
            Err(e) => Result::<&T, &E>::Err(e),
        };
    }

    /// A mutable borrow of either payload, as a `Result<&mut T, &mut E>`.
    pub const fn as_mut(self: &mut Result<T, E>) Result<&mut T, &mut E> {
        return switch self {
            Ok(v) => Result::<&mut T, &mut E>::Ok(v),
            Err(e) => Result::<&mut T, &mut E>::Err(e),
        };
    }

    /// `f(v)` for `Ok(v)`, `default` for `Err`. Consumes `self`; the discarded payload and an unused
    /// `default` are freed.
    pub const fn map_or<U, F: fn(T) U>(self: Result<T, E>, default: U, f: F) U {
        return switch self {
            Ok(v) => f(v),
            Err(e) => {
                default;
            },
        };
    }

    /// `f(v)` for `Ok(v)`, `default(e)` for `Err(e)`; exactly one of them runs. Consumes `self`.
    pub const fn map_or_else<U, D: fn(E) U, F: fn(T) U>(self: Result<T, E>, default: D, f: F) U {
        return switch self {
            Ok(v) => f(v),
            Err(e) => default(e),
        };
    }

    /// `self` when it is `Ok`, otherwise `op(error)`; `op` runs only on the error. Consumes `self`.
    pub const fn or_else<G, O: fn(E) Result<T, G>>(self: Result<T, E>, op: O) Result<T, G> {
        return switch self {
            Ok(v) => Result::<T, G>::Ok(v),
            Err(e) => op(e),
        };
    }

    /// `other` when `self` is `Ok`, otherwise `self`'s error. Consumes both; the discarded `Ok` payload
    /// and an unused `other` are freed.
    pub const fn and<U>(self: Result<T, E>, other: Result<U, E>) Result<U, E> {
        return switch self {
            Ok(v) => {
                other;
            },
            Err(e) => Result::<U, E>::Err(e),
        };
    }

    /// The error value; panics with `msg` on `Ok`. Consumes `self`.
    pub const fn expect_err(self: Result<T, E>, msg: str) E {
        return switch self {
            Ok(_) => panic(msg),
            Err(e) => e,
        };
    }

    /// Runs `f` on the success value when there is one, then returns `self`. `f` borrows the payload.
    pub fn inspect<F: fn(&T) void>(self: Result<T, E>, f: F) Result<T, E> {
        switch &self {
            Ok(v) => f(v),
            Err(_) => {},
        };
        return self;
    }

    /// Runs `f` on the error value when there is one, then returns `self`. `f` borrows the payload.
    pub fn inspect_err<F: fn(&E) void>(self: Result<T, E>, f: F) Result<T, E> {
        switch &self {
            Ok(_) => {},
            Err(e) => f(e),
        };
        return self;
    }

    /// An iterator over the success value: one `&T` for `Ok`, nothing for `Err`.
    pub const fn iter(self: &Result<T, E>) OptionIter<T> {
        return switch self {
            Ok(v) => OptionIter::<T> { item: Option::<&T>::Some(v) },
            Err(_) => OptionIter::<T> { item: Option::<&T>::None },
        };
    }

    /// The inner Result of `Ok(inner)`, and the error of `Err(e)` (`Result::flatten(r)`). An associated
    /// function: an extend cannot target the instance `Result<Result<T, E>, E>` alone.
    pub const fn flatten(r: Result<Result<T, E>, E>) Result<T, E> {
        return switch r {
            Ok(inner) => inner,
            Err(e) => Result::<T, E>::Err(e),
        };
    }

    /// `Ok(None)` turned into `None`, `Ok(Some(v))` into `Some(Ok(v))`, `Err(e)` into `Some(Err(e))`
    /// (`Result::transpose(r)`).
    pub const fn transpose(r: Result<Option<T>, E>) Option<Result<T, E>> {
        return switch r {
            Ok(o) => switch o {
                Some(v) => Option::<Result<T, E>>::Some(Result::<T, E>::Ok(v)),
                None => Option::<Result<T, E>>::None,
            },
            Err(e) => Option::<Result<T, E>>::Some(Result::<T, E>::Err(e)),
        };
    }
}

extend<T: Default, E> Result<T, E> {
    /// The success value, or `T::default()` on `Err`. Consumes `self`; the discarded error is freed.
    pub fn unwrap_or_default(self: Result<T, E>) T {
        return switch self {
            Ok(v) => v,
            Err(e) => {
                T::default();
            },
        };
    }
}

extend<T: Copy, E> Result<T, E> {
    /// `Ok(*r)` for `Ok(r)`, the error unchanged (`Result::copied(r)`).
    pub const fn copied(r: Result<&T, E>) Result<T, E> {
        return switch r {
            Ok(v) => Result::<T, E>::Ok(*v),
            Err(e) => Result::<T, E>::Err(e),
        };
    }
}

extend<T: Clone, E> Result<T, E> {
    /// `Ok(r.clone())` for `Ok(r)`, the error unchanged (`Result::cloned(r)`).
    pub const fn cloned(r: Result<&T, E>) Result<T, E> {
        return switch r {
            Ok(v) => Result::<T, E>::Ok(v.clone()),
            Err(e) => Result::<T, E>::Err(e),
        };
    }
}

// Conditional conformances: a Result is Clone/Eq/Ord/Hash exactly when both its arms are (read-only,
// ref-binding).
extend<T: Clone, E: Clone> Result<T, E> as Clone {
    pub const fn clone(self: &Result<T, E>) Result<T, E> {
        return switch self {
            Ok(v) => Result::<T, E>::Ok(v.clone()),
            Err(e) => Result::<T, E>::Err(e.clone()),
        };
    }
}

extend<T: Eq, E: Eq> Result<T, E> as Eq {
    pub const fn eq(self: &Result<T, E>, other: &Result<T, E>) bool {
        return switch self {
            Ok(a) => switch other {
                Ok(b) => *a == *b,
                Err(_) => false,
            },
            Err(a) => switch other {
                Ok(_) => false,
                Err(b) => *a == *b,
            },
        };
    }
}

extend<T: Ord, E: Ord> Result<T, E> as Ord {
    /// `Ok` orders before `Err`; two values of one arm compare their payloads.
    pub const fn cmp(self: &Result<T, E>, other: &Result<T, E>) i32 {
        return switch self {
            Ok(a) => switch other {
                Ok(b) => a.cmp(b),
                Err(_) => -1,
            },
            Err(a) => switch other {
                Ok(_) => 1,
                Err(b) => a.cmp(b),
            },
        };
    }
}

extend<T: Hash, E: Hash> Result<T, E> as Hash {
    /// An arm byte (0 `Ok`, 1 `Err`), then the payload.
    pub fn hash_into<H: Hasher>(self: &Result<T, E>, h: &mut H) {
        switch self {
            Ok(v) => {
                h.write_u8(0);
                v.hash_into(h);
            },
            Err(e) => {
                h.write_u8(1);
                e.hash_into(h);
            },
        };
    }
}

extend<T: Format, E: Format> Result<T, E> as Format {
    pub fn fmt(self: &Result<T, E>) String {
        let inner = switch self {
            Ok(v) => v.fmt(),
            Err(e) => e.fmt(),
        };
        let mut s = String::new();
        if self.is_ok() {
            s.push_str("Ok(");
        } else {
            s.push_str("Err(");
        }
        s.push_string(&inner);
        s.push_str(")");
        return s;
    }
}
