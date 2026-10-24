// std::mem::cell: every operation of Cell, RefCell and OnceCell with owned (`String`) values under the
// leak check, RefCell borrow conflicts (panics and `None`), guards releasing on drop and on early return,
// OnceCell's single write and its reentrancy check, and the conformances.

import std::mem::cell as *;

const LONG: str = "a heap string longer than the twenty-three inline bytes";

fn s(text: str) String {
    return String::from_str(text);
}

// --- Cell -----------------------------------------------------------------------------------------

@test
fn cell_get_set_replace() {
    let c = Cell::<i32>::new(3);
    assert_eq(c.get(), 3);
    c.set(4);
    assert_eq(c.get(), 4);
    assert_eq(c.replace(9), 4);
    assert_eq(c.get(), 9);
    assert_eq(c.into_inner(), 9);
}

@test
fn cell_of_owned_values_frees_what_it_replaces() {
    let c = Cell::<String>::new(s(LONG));
    c.set(s("second value, also longer than the inline bytes"));
    let old = c.replace(s("third"));
    assert(old.as_str() == "second value, also longer than the inline bytes", "replace returns the old value");
    let taken = c.take();
    assert(taken.as_str() == "third", "take returns the value");
    let rest = c.into_inner();
    assert(rest.is_empty(), "take leaves the default");
}

@test
fn cell_swap_exchanges_and_ignores_itself() {
    let a = Cell::<String>::new(s("left"));
    let b = Cell::<String>::new(s(LONG));
    a.swap(&b);
    assert(a.take().as_str() == LONG, "a holds b's value");
    assert(b.take().as_str() == "left", "b holds a's value");
    let n = Cell::<i32>::new(5);
    n.swap(&n);
    assert_eq(n.get(), 5);
}

@test
fn cell_get_mut_and_from_mut() {
    let mut c = Cell::<i64>::new(1);
    *c.get_mut() += 41;
    assert_eq(c.get(), 42);
    let mut x: u32 = 7;
    {
        let view = Cell::<u32>::from_mut(&mut x);
        let again = view;
        view.set(8);
        again.set(again.get() + 1);
    }
    assert_eq(x, 9u32);
}

@test
fn cell_conformances() {
    let c = Cell::<i32>::new(5);
    let d = c.clone();
    c.set(6);
    assert_eq(d.get(), 5);
    assert(c != d, "different values");
    d.set(6);
    assert(c == d, "equal values");
    let z = Cell::<i32>::default();
    assert_eq(z.get(), 0);
    let f = c.fmt();
    assert(f.as_str() == "6", "format forwards to the value");
}

// --- RefCell ---
// A guard that no `let` binds is a temporary, and a temporary lives to the end of its block: the tests
// put such borrows in inner blocks.-----------------------------------------------------------------------------------

@test
fn refcell_shared_borrows_coexist() {
    let r = RefCell::<String>::new(s(LONG));
    let a = r.borrow();
    let b = r.borrow();
    assert_eq(a.len(), LONG.len());
    assert_eq(b.len(), LONG.len());
    assert(r.try_borrow().is_some(), "a third shared borrow");
    assert(r.try_borrow_mut().is_none(), "no exclusive borrow while shared ones live");
}

@test
fn refcell_exclusive_borrow_excludes_all() {
    let r = RefCell::<String>::new(s("ab"));
    {
        let mut m = r.borrow_mut();
        m.push_str("cd");
        assert(r.try_borrow().is_none(), "no shared borrow while the exclusive one lives");
        assert(r.try_borrow_mut().is_none(), "no second exclusive borrow");
        *m = s(LONG);
    }
    let g = r.borrow();
    assert(g.as_str() == LONG, "the write through the guard stays");
}

const fn peek_len(r: &RefCell<String>, early: bool) usize {
    let g = r.borrow();
    if early {
        return 0;
    }
    return g.len();
}

fn edit_then_stop(r: &RefCell<String>, stop: bool) {
    let mut m = r.borrow_mut();
    m.push_str("!");
    if stop {
        return;
    }
    m.push_str("?");
}

@test
fn refcell_guards_release_on_drop_and_on_early_return() {
    let r = RefCell::<String>::new(s("x"));
    assert_eq(peek_len(&r, true), 0);
    assert_eq(peek_len(&r, false), 1);
    edit_then_stop(&r, true);
    edit_then_stop(&r, false);
    {
        assert(r.try_borrow_mut().is_some(), "every guard released its borrow");
    }
    let g = r.borrow();
    assert(g.as_str() == "x!!?", "both edits ran");
}

@test
fn refcell_try_borrow_returns_working_guards() {
    let r = RefCell::<i32>::new(1);
    if let Some(mut m) = r.try_borrow_mut() {
        *m = 2;
    }
    if let Some(g) = r.try_borrow() {
        assert_eq(*g, 2);
    }
    {
        assert(r.try_borrow_mut().is_some(), "the guards of the if-let arms were released");
    }
}

@test
fn refcell_replace_swap_take_into_inner() {
    let a = RefCell::<String>::new(s("one"));
    let old = a.replace(s(LONG));
    assert(old.as_str() == "one", "replace returns the old value");
    let b = RefCell::<String>::new(s("two"));
    a.swap(&b);
    {
        assert(a.borrow().as_str() == "two", "a after swap");
        assert(b.borrow().as_str() == LONG, "b after swap");
    }
    let t = b.take();
    assert(t.as_str() == LONG, "take returns the value");
    {
        assert(b.borrow().is_empty(), "take leaves the default");
    }
    let mut c = RefCell::<String>::new(s("three"));
    c.get_mut().push_str("+");
    assert(c.into_inner().as_str() == "three+", "into_inner after get_mut");
}

@test
fn refcell_replace_with_sees_the_value() {
    let r = RefCell::<Vector<i32>>::new(Vector::<i32>::new());
    {
        r.borrow_mut().push(1);
    }
    let old = r.replace_with(
        fn(v: &mut Vector<i32>) Vector<i32> {
            v.push(2);
            let mut next = Vector::<i32>::new();
            next.push(v.len() as i32);
            return next;
        },
    );
    assert_eq(old.len(), 2);
    let g = r.borrow();
    assert_eq(*g.at(0), 2);
}

@test(should_panic)
fn refcell_borrow_mut_while_borrowed_panics() {
    let r = RefCell::<i32>::new(1);
    let _g = r.borrow();
    let _m = r.borrow_mut();
}

@test(should_panic)
fn refcell_borrow_while_mutably_borrowed_panics() {
    let r = RefCell::<i32>::new(1);
    let _m = r.borrow_mut();
    let _g = r.borrow();
}

@test(should_panic)
fn refcell_replace_while_borrowed_panics() {
    let r = RefCell::<String>::new(s("a"));
    let _g = r.borrow();
    let _old = r.replace(s("b"));
}

@test(should_panic)
fn refcell_swap_with_itself_panics() {
    let r = RefCell::<i32>::new(1);
    r.swap(&r);
}

@test(should_panic)
fn refcell_replace_with_reentrant_borrow_panics() {
    let r = RefCell::<i32>::new(1);
    let rr = &r;
    let _ = r.replace_with(|v: &mut i32| *v + *rr.borrow());
}

@test
fn refcell_conformances() {
    let a = RefCell::<String>::new(s(LONG));
    let b = a.clone();
    assert(a == b, "a clone is equal");
    {
        b.borrow_mut().push_str("x");
    }
    assert(a != b, "the clone is independent");
    let d = RefCell::<i32>::default();
    {
        assert_eq(*d.borrow(), 0);
    }
    let f = RefCell::<i32>::new(12).fmt();
    assert(f.as_str() == "12", "format forwards to the value");
}

@test(should_panic)
fn refcell_clone_while_mutably_borrowed_panics() {
    let a = RefCell::<i32>::new(1);
    let _m = a.borrow_mut();
    let _b = a.clone();
}

// --- OnceCell -------------------------------------------------------------------------------------

@test
fn oncecell_set_twice_hands_the_value_back() {
    let o = OnceCell::<String>::new();
    assert(o.get().is_none(), "empty");
    assert(o.set(s(LONG)).is_ok(), "the first set");
    let again = o.set(s("second, longer than the twenty-three inline bytes"));
    assert(again.is_err(), "the second set fails");
    assert(again.unwrap_err().as_str() == "second, longer than the twenty-three inline bytes", "Err holds the value");
    assert(o.get().unwrap().as_str() == LONG, "the first value stays");
}

@test
fn oncecell_get_or_init_runs_once() {
    let o = OnceCell::<String>::new();
    let calls = Cell::<i32>::new(0);
    let cr = &calls;
    let first = o.get_or_init(
        fn() String {
            cr.set(cr.get() + 1);
            return s(LONG);
        },
    );
    assert_eq(first.len(), LONG.len());
    let second = o.get_or_init(
        fn() String {
            cr.set(cr.get() + 1);
            return s("unused");
        },
    );
    assert(second.as_str() == LONG, "the stored value");
    assert_eq(calls.get(), 1);
}

@test
fn oncecell_get_mut_take_into_inner() {
    let mut o = OnceCell::<String>::new();
    assert(o.get_mut().is_none(), "empty");
    assert(o.take().is_none(), "take of an empty cell");
    let _ = o.set(s("v"));
    o.get_mut().unwrap().push_str(LONG);
    let t = o.take().unwrap();
    assert_eq(t.len(), LONG.len() + 1);
    assert(o.get().is_none(), "take empties the cell");
    assert(o.set(s("w")).is_ok(), "an emptied cell takes a value again");
    assert(o.into_inner().unwrap().as_str() == "w", "into_inner");
    let empty = OnceCell::<String>::new();
    assert(empty.into_inner().is_none(), "into_inner of an empty cell");
}

@test(should_panic)
fn oncecell_reentrant_init_panics() {
    let o = OnceCell::<i32>::new();
    let r = &o;
    let _ = o.get_or_init(|| *r.get_or_init(|| 1) + 1);
}

@test
fn oncecell_conformances() {
    let a = OnceCell::<String>::new();
    let b = OnceCell::<String>::default();
    assert(a == b, "two empty cells");
    let _ = a.set(s(LONG));
    assert(a != b, "a full and an empty cell");
    let c = a.clone();
    assert(a == c, "a clone holds an equal value");
    let fa = a.fmt();
    let fb = b.fmt();
    assert(fb.as_str() == "OnceCell(<empty>)", "empty format");
    assert_eq(fa.len(), "OnceCell()".len() + LONG.len());
}
