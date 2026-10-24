// Interior mutability for one thread (Rust's `core::cell`): `Cell<T>` replaces a whole value, `RefCell<T>`
// lends checked borrows, `OnceCell<T>` is written once. Each changes its value through a shared `&`, on
// `UnsafeCell` (std/core.spc).
//
// Soundness under the borrow rules:
// - `Cell` never hands out a reference into its value through `&self`: `get` copies it out, `set`,
//   `replace`, `swap` and `take` move whole values in and out. No borrow of the interior can be live
//   while it changes. `get_mut` and `from_mut` need a `&mut`, which already excludes every other access.
// - `RefCell` counts its borrows at run time: `borrow` returns a `Ref` guard and `borrow_mut` a `RefMut`
//   guard, and every reference into the value is tied to a guard by its signature, so it cannot outlive
//   the guard. Dropping a guard releases its borrow, on every exit path. A `borrow_mut` while any guard
//   lives, or a `borrow` while a `RefMut` lives, panics; `try_borrow` and `try_borrow_mut` return `None`
//   instead. A forgotten guard keeps the cell borrowed: later conflicting borrows panic, nothing is unsound.
//   A guard that no `let` binds (`r.borrow().len()`) is a temporary and lives to the end of its block, as
//   every temporary does; put the use in an inner block to end the borrow earlier.
// - `OnceCell` hands out `&T` only once it holds a value, and through `&self` it never changes a value it
//   holds: `set` fails and `get_or_init` returns the stored value. `take` needs `&mut self`.
//
// Thread safety: none of the three is `Sync`, because an `UnsafeCell` field makes a type structurally
// non-`Sync`; each is `Send` when `T` is. A `Ref` or `RefMut` holds a `&RefCell`, so it is neither `Send`
// nor `Sync`. Use `std::parallel::sync` to share across threads.
//
// Cost: every operation is O(1) apart from what `T`'s own `free`, `clone` or the given closure costs, and
// none allocates. A `Cell<T>` and a `OnceCell<T>` have no other storage than the value (`OnceCell` adds
// the `Option` tag); a `RefCell<T>` adds one `isize` borrow count, and a guard is one pointer.
// Import with `import std::mem::cell;`.

/// A mutable value behind a shared reference, moved in and out whole. `get` needs `T: Copy`.
pub struct Cell<T> {
    value: UnsafeCell<T>,
}

/// A mutable value with borrows checked at run time: any number of `Ref` guards, or one `RefMut` guard.
pub struct RefCell<T> {
    // 0: free; n > 0: n `Ref` guards live; -1: one `RefMut` guard lives.
    state: Cell<isize>,
    value: UnsafeCell<T>,
}

/// A shared borrow of a `RefCell`'s value. Reads through `Deref`; dropping it releases the borrow.
pub struct Ref<'a, T> {
    cell: &'a RefCell<T>,
}

/// The exclusive borrow of a `RefCell`'s value. Reads and writes through `Deref` and `DerefMut`; dropping
/// it releases the borrow.
pub struct RefMut<'a, T> {
    cell: &'a RefCell<T>,
}

/// A cell written at most once through a shared reference; then it hands out shared borrows of its value.
pub struct OnceCell<T> {
    value: UnsafeCell<Option<T>>,
}

extend<T> Cell<T> {
    /// A cell holding `value`.
    pub const fn new(value: T) Cell<T> {
        return Cell::<T> { value: UnsafeCell::<T>::new(value) };
    }

    /// Store `value` and free the previous value. The previous value is freed after the store, so its
    /// `free` sees the cell holding `value`.
    pub const fn set(self: &Cell<T>, value: T) {
        let _old = self.replace(value);
    }

    /// Store `value` and return the previous value.
    pub const fn replace(self: &Cell<T>, value: T) T {
        let p = self.value.get();
        let old = unsafe *p;
        unsafe *p = value;
        return old;
    }

    /// Exchange the values of two cells. No effect when both are the same cell.
    pub const fn swap(self: &Cell<T>, other: &Cell<T>) {
        let a = self.value.get();
        let b = other.value.get();
        if a == b {
            return;
        }
        unsafe {
            let t = *a;
            *a = *b;
            *b = t;
        }
    }

    /// The value, consuming the cell.
    pub const fn into_inner(self: Cell<T>) T {
        // A bitwise move out; the emptied cell is abandoned so its drop never runs.
        let v = unsafe *self.value.get();
        forget(self);
        return v;
    }

    /// A mutable borrow of the value. The `&mut self` excludes every other access, so nothing is checked.
    pub const fn get_mut(self: &mut Cell<T>) &mut T {
        return &mut unsafe *self.value.get();
    }

    /// The `T` behind `r` seen as a `Cell<T>`, for as long as `r`'s borrow. Sound: a `Cell<T>` has the
    /// layout of `T`, and the `&mut` borrow excludes every other access while the `&Cell<T>` lives.
    pub const fn from_mut<'a>(r: &'a mut T) &'a Cell<T> {
        static_assert(sizeof(Cell<T>) == sizeof(T) && alignof(Cell<T>) == alignof(T), "Cell<T> has the layout of T");
        return unsafe &*((r as *mut T) as *const Cell<T>);
    }
}

extend<T: Copy> Cell<T> {
    /// A copy of the value.
    pub const fn get(self: &Cell<T>) T {
        return unsafe *self.value.get();
    }
}

extend<T: Default> Cell<T> {
    /// The value, leaving `T::default()` in its place.
    pub fn take(self: &Cell<T>) T {
        return self.replace(T::default());
    }
}

extend<T> RefCell<T> {
    /// A cell holding `value`, not borrowed.
    pub const fn new(value: T) RefCell<T> {
        return RefCell::<T> { state: Cell::<isize>::new(0), value: UnsafeCell::<T>::new(value) };
    }

    /// A shared borrow of the value. Panics: the value is mutably borrowed.
    pub const fn borrow(self: &RefCell<T>) Ref<T> {
        return switch self.try_borrow() {
            Some(r) => r,
            None => panic("RefCell: already mutably borrowed"),
        };
    }

    /// A shared borrow of the value, or `None` when it is mutably borrowed.
    pub const fn try_borrow(self: &RefCell<T>) Option<Ref<T>> {
        // `wrapping_add`: at `isize::MAX` shared borrows the count wraps negative and the borrow fails,
        // instead of overflowing into the exclusive state.
        let n = self.state.get().wrapping_add(1);
        if n <= 0 {
            return Option::<Ref<T>>::None;
        }
        self.state.set(n);
        return Option::<Ref<T>>::Some(Ref::<T>::hold(self));
    }

    /// The exclusive borrow of the value. Panics: the value is borrowed.
    pub const fn borrow_mut(self: &RefCell<T>) RefMut<T> {
        return switch self.try_borrow_mut() {
            Some(r) => r,
            None => panic("RefCell: already borrowed"),
        };
    }

    /// The exclusive borrow of the value, or `None` when it is borrowed.
    pub const fn try_borrow_mut(self: &RefCell<T>) Option<RefMut<T>> {
        if self.state.get() != 0 {
            return Option::<RefMut<T>>::None;
        }
        self.state.set(-1);
        return Option::<RefMut<T>>::Some(RefMut::<T>::hold(self));
    }

    /// Store `value` and return the previous value. Panics: the value is borrowed.
    pub const fn replace(self: &RefCell<T>, value: T) T {
        let mut g = self.borrow_mut();
        return replace(g.deref_mut(), value);
    }

    /// Store `f(&mut value)` and return the previous value. The cell stays mutably borrowed while `f`
    /// runs, so `f` cannot borrow it. Panics: the value is borrowed.
    pub fn replace_with<F: fn move(&mut T) T>(self: &RefCell<T>, f: F) T {
        let mut g = self.borrow_mut();
        let next = f(g.deref_mut());
        return replace(g.deref_mut(), next);
    }

    /// Exchange the values of two cells. Panics: either value is borrowed, or both are the same cell.
    pub const fn swap(self: &RefCell<T>, other: &RefCell<T>) {
        // The two guards prove that nothing else reaches either value, and that the cells differ.
        let _a = self.borrow_mut();
        let _b = other.borrow_mut();
        let a = self.value.get();
        let b = other.value.get();
        unsafe {
            let t = *a;
            *a = *b;
            *b = t;
        }
    }

    /// The value, consuming the cell.
    pub const fn into_inner(self: RefCell<T>) T {
        // A bitwise move out; the emptied cell is abandoned so its drop never runs.
        let v = unsafe *self.value.get();
        forget(self);
        return v;
    }

    /// A mutable borrow of the value. The `&mut self` excludes every guard, so nothing is checked.
    pub const fn get_mut(self: &mut RefCell<T>) &mut T {
        return &mut unsafe *self.value.get();
    }

    // The guards' access to the cell: the value, and the release of their borrow.
    const fn value_ptr(self: &RefCell<T>) *mut T {
        return self.value.get();
    }

    const fn release_shared(self: &RefCell<T>) {
        self.state.set(self.state.get() - 1);
    }

    const fn release_exclusive(self: &RefCell<T>) {
        self.state.set(0);
    }
}

extend<T: Default> RefCell<T> {
    /// The value, leaving `T::default()` in its place. Panics: the value is borrowed.
    pub fn take(self: &RefCell<T>) T {
        return self.replace(T::default());
    }
}

extend<T> OnceCell<T> {
    /// An empty cell.
    pub const fn new() OnceCell<T> {
        return OnceCell::<T> { value: UnsafeCell::<Option<T>>::new(Option::<T>::None) };
    }

    /// A shared borrow of the value, or `None` while the cell is empty.
    pub const fn get(self: &OnceCell<T>) Option<&T> {
        return switch unsafe &*self.value.get() {
            Some(v) => Option::<&T>::Some(v),
            None => Option::<&T>::None,
        };
    }

    /// A mutable borrow of the value, or `None` while the cell is empty.
    pub const fn get_mut(self: &mut OnceCell<T>) Option<&mut T> {
        return switch &mut unsafe *self.value.get() {
            Some(v) => Option::<&mut T>::Some(v),
            None => Option::<&mut T>::None,
        };
    }

    /// Store `value` when the cell is empty; else hand `value` back as `Err`.
    pub const fn set(self: &OnceCell<T>, value: T) Result<Unit, T> {
        if self.get().is_some() {
            return Result::<Unit, T>::Err(value);
        }
        unsafe *self.value.get() = Option::<T>::Some(value);
        return Result::<Unit, T>::Ok(Unit {});
    }

    /// The value, storing `f()` first when the cell is empty. Panics: `f` itself initializes the cell.
    pub fn get_or_init<F: fn move() T>(self: &OnceCell<T>, f: F) &T {
        if self.get().is_none() {
            // No borrow of the interior is live while `f` runs, so a reentrant `get` or `set` sees an
            // empty cell; a reentrant initialization is caught after `f` returns.
            let v = f();
            if self.get().is_some() {
                panic("OnceCell: reentrant initialization");
            }
            unsafe *self.value.get() = Option::<T>::Some(v);
        }
        return self.get().unwrap();
    }

    /// The value, leaving the cell empty.
    pub const fn take(self: &mut OnceCell<T>) Option<T> {
        return (unsafe *self.value.get()).take();
    }

    /// The value, consuming the cell.
    pub const fn into_inner(self: OnceCell<T>) Option<T> {
        // A bitwise move out; the emptied cell is abandoned so its drop never runs.
        let v = unsafe *self.value.get();
        forget(self);
        return v;
    }
}

// Only `RefCell` constructs a guard, after it has counted the borrow.
extend<T> Ref<T> {
    const fn hold(cell: &RefCell<T>) Ref<T> {
        return Ref::<T> { cell: cell };
    }
}

extend<T> RefMut<T> {
    const fn hold(cell: &RefCell<T>) RefMut<T> {
        return RefMut::<T> { cell: cell };
    }
}

extend<T> Ref<T> as Deref<T> {
    pub fn deref(self: &Ref<T>) &T {
        return unsafe &*self.cell.value_ptr();
    }
}

extend<T> Ref<T> as Free {
    pub fn free(self: &mut Ref<T>) {
        self.cell.release_shared();
    }
}

extend<T> RefMut<T> as Deref<T> {
    pub fn deref(self: &RefMut<T>) &T {
        return unsafe &*self.cell.value_ptr();
    }
}

extend<T> RefMut<T> as DerefMut<T> {
    pub fn deref_mut(self: &mut RefMut<T>) &mut T {
        return &mut unsafe *self.cell.value_ptr();
    }
}

extend<T> RefMut<T> as Free {
    pub fn free(self: &mut RefMut<T>) {
        self.cell.release_exclusive();
    }
}

extend<T: Copy> Cell<T> as Clone {
    pub fn clone(self: &Cell<T>) Cell<T> {
        return Cell::<T>::new(self.get());
    }
}

extend<T: Default> Cell<T> as Default {
    pub fn default() Cell<T> {
        return Cell::<T>::new(T::default());
    }
}

extend<T: Copy + Eq> Cell<T> as Eq {
    pub fn eq(self: &Cell<T>, other: &Cell<T>) bool {
        return self.get() == other.get();
    }
}

extend<T: Copy + Format> Cell<T> as Format {
    pub fn fmt(self: &Cell<T>) String {
        return self.get().fmt();
    }
}

// The conformances below borrow the value: each panics when the cell is mutably borrowed.
extend<T: Clone> RefCell<T> as Clone {
    pub fn clone(self: &RefCell<T>) RefCell<T> {
        let r = self.borrow();
        return RefCell::<T>::new(r.deref().clone());
    }
}

extend<T: Default> RefCell<T> as Default {
    pub fn default() RefCell<T> {
        return RefCell::<T>::new(T::default());
    }
}

extend<T: Eq> RefCell<T> as Eq {
    pub fn eq(self: &RefCell<T>, other: &RefCell<T>) bool {
        let a = self.borrow();
        let b = other.borrow();
        return a.deref().eq(b.deref());
    }
}

extend<T: Format> RefCell<T> as Format {
    pub fn fmt(self: &RefCell<T>) String {
        let r = self.borrow();
        return r.deref().fmt();
    }
}

extend<T: Clone> OnceCell<T> as Clone {
    pub fn clone(self: &OnceCell<T>) OnceCell<T> {
        let c = OnceCell::<T>::new();
        if let Some(v) = self.get() {
            let _ = c.set(v.clone());
        }
        return c;
    }
}

extend<T> OnceCell<T> as Default {
    pub fn default() OnceCell<T> {
        return OnceCell::<T>::new();
    }
}

extend<T: Eq> OnceCell<T> as Eq {
    pub fn eq(self: &OnceCell<T>, other: &OnceCell<T>) bool {
        let a = self.get();
        let b = other.get();
        if a.is_none() || b.is_none() {
            return a.is_none() && b.is_none();
        }
        return a.unwrap().eq(b.unwrap());
    }
}

extend<T: Format> OnceCell<T> as Format {
    /// `OnceCell(value)`, or `OnceCell(<empty>)`.
    pub fn fmt(self: &OnceCell<T>) String {
        let mut s = String::from_str("OnceCell(");
        if let Some(v) = self.get() {
            let vs = v.fmt();
            s.push_string(&vs);
        } else {
            s.push_str("<empty>");
        }
        s.push_str(")");
        return s;
    }
}
