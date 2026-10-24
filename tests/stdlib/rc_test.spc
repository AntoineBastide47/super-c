// std::mem::rc: destruction order observed through values whose `free` records into a shared log, weak
// upgrade failure after the last strong drop and during the value's own `free`, a parent and child
// cycle broken by `Weak` under the leak check, `try_unwrap`, `into_inner`, `get_mut`, clone-on-write
// `make_mut`, a stateful counting allocator, and the forwarding conformances.

import std::mem::cell as *;
import std::mem::rc as *;

struct Counts {
    pub allocs: usize,
    pub frees: usize,
    pub live: usize,
}

// Forwards to `Global` and counts through a pointer, so every handle's copy counts into one place.
@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe {
            (*self.c).allocs += 1;
            (*self.c).live += size;
        }
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }
    pub unsafe fn realloc(self: &mut Counting, p: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        unsafe {
            if p == null {
                (*self.c).allocs += 1;
            }
            (*self.c).live = (*self.c).live - old_size + new_size;
        }
        let mut g = Global {};
        return unsafe g.realloc(p, old_size, new_size, align);
    }
    pub unsafe fn dealloc(self: &mut Counting, p: *mut void, size: usize, align: usize) {
        unsafe {
            (*self.c).frees += 1;
            (*self.c).live -= size;
        }
        let mut g = Global {};
        unsafe g.dealloc(p, size, align);
    }
}

// Records its id into the log when it is freed.
struct Probe<'a> {
    pub id: i32,
    pub log: &'a RefCell<Vector<i32>>,
}

extend<'a> Probe<'a> as Free {
    pub fn free(self: &mut Probe<'a>) {
        let mut g = self.log.borrow_mut();
        g.push(self.id);
    }
}

// Counts its clones.
struct Counted<'a> {
    pub v: i32,
    pub clones: &'a Cell<i32>,
}

extend<'a> Counted<'a> as Clone {
    pub fn clone(self: &Counted<'a>) Counted<'a> {
        self.clones.set(self.clones.get() + 1);
        return Counted { v: self.v, clones: self.clones };
    }
}

fn logged(log: &RefCell<Vector<i32>>) Vector<i32> {
    let g = log.borrow();
    return g.clone();
}

fn new_log() RefCell<Vector<i32>> {
    return RefCell::<Vector<i32>>::new(Vector::<i32>::new());
}

@test
fn value_drops_with_the_last_strong_handle_and_block_with_the_last_weak() {
    let log = new_log();
    let mut counts = Counts { allocs: 0, frees: 0, live: 0 };
    let mut w = Weak::<Probe, Counting>::new_in(Counting { c: &mut counts });
    {
        let a = Rc::<Probe, Counting>::new_in(Counting { c: &mut counts }, Probe { id: 1, log: &log });
        w = a.downgrade();
        let b = a.clone();
        assert_eq(a.strong_count(), 2);
        assert_eq(b.weak_count(), 1);
        {
            let _c = b.clone();
        }
        assert_eq(logged(&log).len(), 0);
        assert_eq(counts.allocs, 1);
    }
    let after = logged(&log);
    assert_eq(after.len(), 1);
    assert_eq(*after.at(0), 1);
    assert(w.upgrade().is_none(), "no upgrade after the last strong drop");
    assert_eq(w.strong_count(), 0);
    assert_eq(w.weak_count(), 0);
    assert_eq(counts.frees, 0);
    {
        let _gone = w;
    }
    assert_eq(counts.frees, 1);
    assert_eq(counts.live, 0);
}

@test
fn drop_order_follows_the_last_strong_handle() {
    let log = new_log();
    {
        let one = Rc::<Probe>::new(Probe { id: 1, log: &log });
        let two = Rc::<Probe>::new(Probe { id: 2, log: &log });
        let keep_one = one.clone();
        {
            let _a = one;
            let _b = two;
        }
        let first = logged(&log);
        assert_eq(first.len(), 1);
        assert_eq(*first.at(0), 2);
        assert_eq(keep_one.get().id, 1);
    }
    let l = logged(&log);
    assert_eq(l.len(), 2);
    assert_eq(*l.at(1), 1);
}

// Holds a `Weak` to its own block; its `free` records whether that `Weak` still upgrades. A `free` that
// names an owning field frees it itself.
struct SelfRef<'a> {
    pub me: RefCell<Weak<SelfRef<'a>>>,
    pub upgraded_in_free: &'a Cell<i32>,
}

extend<'a> SelfRef<'a> as Free {
    pub fn free(self: &mut SelfRef<'a>) {
        {
            let w = self.me.borrow();
            if w.upgrade().is_some() {
                self.upgraded_in_free.set(1);
            } else {
                self.upgraded_in_free.set(2);
            }
        }
        self.me.free();
    }
}

@test
fn weak_never_upgrades_while_the_value_is_freed() {
    let seen = Cell::<i32>::new(0);
    {
        let rc = Rc::<SelfRef>::new(
            SelfRef { me: RefCell::<Weak<SelfRef>>::new(Weak::<SelfRef>::new()), upgraded_in_free: &seen },
        );
        let w = rc.downgrade();
        let _old = rc.get().me.replace(w);
        assert_eq(rc.weak_count(), 1);
    }
    assert_eq(seen.get(), 2);
}

struct Parent<'a> {
    pub name: i32,
    pub children: RefCell<Vector<Rc<Child<'a>>>>,
    pub log: &'a RefCell<Vector<i32>>,
}

struct Child<'a> {
    pub name: i32,
    pub parent: RefCell<Weak<Parent<'a>>>,
    pub log: &'a RefCell<Vector<i32>>,
}

extend<'a> Parent<'a> as Free {
    pub fn free(self: &mut Parent<'a>) {
        let mut g = self.log.borrow_mut();
        g.push(self.name);
    }
}

extend<'a> Child<'a> as Free {
    pub fn free(self: &mut Child<'a>) {
        let mut g = self.log.borrow_mut();
        g.push(self.name);
    }
}

@test
fn a_parent_child_cycle_through_weak_frees_everything() {
    let log = new_log();
    let mut kept = Option::<Rc<Child>>::None;
    {
        let parent = Rc::<Parent>::new(
            Parent { name: 0, children: RefCell::<Vector<Rc<Child>>>::new(Vector::<Rc<Child>>::new()), log: &log },
        );
        for i in 1..4 {
            let c = Rc::<Child>::new(
                Child { name: i, parent: RefCell::<Weak<Parent>>::new(Weak::<Parent>::new()), log: &log },
            );
            let _none = c.get().parent.replace(parent.downgrade());
            let mut kids = parent.get().children.borrow_mut();
            kids.push(c);
        }
        assert_eq(parent.weak_count(), 3);
        {
            let kids = parent.get().children.borrow();
            kept = Option::<Rc<Child>>::Some(kids.at(1).clone());
        }
        {
            let kids = parent.get().children.borrow();
            let up = kids.at(0).get().parent.borrow().upgrade();
            assert(up.is_some(), "the child reaches its live parent");
            let p = up.unwrap();
            assert_eq(p.get().name, 0);
        }
    }
    // The parent went first; its vector released children 1 and 3, and child 2 lives on.
    let child_handle = kept.unwrap();
    let l = logged(&log);
    assert_eq(l.len(), 3);
    assert_eq(*l.at(0), 0);
    assert_eq(*l.at(1), 1);
    assert_eq(*l.at(2), 3);
    {
        let w = child_handle.get().parent.borrow();
        assert(w.upgrade().is_none(), "the parent is gone");
    }
    assert_eq(child_handle.strong_count(), 1);
}

@test
fn try_unwrap_takes_a_unique_value() {
    let log = new_log();
    let a = Rc::<Probe>::new(Probe { id: 5, log: &log });
    let b = a.clone();
    let back = a.try_unwrap();
    assert(back.is_err(), "shared: the handle comes back");
    let a2 = back.unwrap_err();
    assert_eq(a2.strong_count(), 2);
    {
        let _drop = b;
    }
    let w = a2.downgrade();
    let v = a2.try_unwrap();
    assert(v.is_ok(), "unique: the value comes out");
    assert(w.upgrade().is_none(), "the weak handle no longer upgrades");
    assert_eq(logged(&log).len(), 0);
    let p = v.unwrap();
    assert_eq(p.id, 5);
}

@test
fn into_inner_returns_only_the_last_value() {
    let a = Rc::<String>::new(String::from_str("a heap string longer than twenty-three bytes"));
    let b = a.clone();
    assert(a.into_inner().is_none(), "another strong handle remains");
    assert_eq(b.strong_count(), 1);
    let s = b.into_inner();
    assert(s.unwrap().as_str() == "a heap string longer than twenty-three bytes", "the last handle");
}

@test
fn get_mut_needs_a_unique_handle() {
    let mut a = Rc::<i32>::new(1);
    *a.get_mut().unwrap() = 2;
    assert_eq(*a.get(), 2);
    {
        let _b = a.clone();
        assert(a.get_mut().is_none(), "another strong handle");
    }
    {
        let _w = a.downgrade();
        assert(a.get_mut().is_none(), "a weak handle");
    }
    assert(a.get_mut().is_some(), "unique again");
}

@test
fn make_mut_clones_only_when_shared() {
    let clones = Cell::<i32>::new(0);
    let mut counts = Counts { allocs: 0, frees: 0, live: 0 };
    {
        let mut a = Rc::<Counted, Counting>::new_in(Counting { c: &mut counts }, Counted { v: 1, clones: &clones });
        a.make_mut().v = 2;
        assert_eq(clones.get(), 0);
        let b = a.clone();
        a.make_mut().v = 3;
        assert_eq(clones.get(), 1);
        assert(!a.ptr_eq(&b), "the write went to a new block");
        assert_eq(b.get().v, 2);
        assert_eq(a.get().v, 3);
        assert_eq(a.strong_count(), 1);
        assert_eq(b.strong_count(), 1);
        a.make_mut().v = 4;
        assert_eq(clones.get(), 1);
        assert_eq(counts.allocs, 2);
        // Only weak handles share: the value moves without a clone and they stop upgrading.
        let w = a.downgrade();
        a.make_mut().v = 5;
        assert_eq(clones.get(), 1);
        assert(w.upgrade().is_none(), "the weak handle is detached");
        assert_eq(a.weak_count(), 0);
        assert_eq(a.get().v, 5);
        assert_eq(counts.allocs, 3);
    }
    assert_eq(counts.frees, 3);
    assert_eq(counts.live, 0);
}

@test
fn weak_new_allocates_nothing() {
    let mut counts = Counts { allocs: 0, frees: 0, live: 0 };
    let w = Weak::<String, Counting>::new_in(Counting { c: &mut counts });
    assert(w.upgrade().is_none(), "Weak::new upgrades to nothing");
    assert_eq(w.strong_count(), 0);
    assert_eq(w.weak_count(), 0);
    let w2 = w.clone();
    assert(w2.upgrade().is_none(), "its clone neither");
    let d = Weak::<i32>::new();
    assert(d.upgrade().is_none(), "the default allocator form");
    assert_eq(counts.allocs, 0);
}

@test
fn weak_clone_and_counts() {
    let a = Rc::<i32>::new(7);
    let w = a.downgrade();
    let w2 = w.clone();
    assert_eq(a.weak_count(), 2);
    assert_eq(w2.weak_count(), 2);
    assert_eq(w.strong_count(), 1);
    {
        let up = w2.upgrade().unwrap();
        assert_eq(*up.get(), 7);
        assert_eq(a.strong_count(), 2);
        assert(up.ptr_eq(&a), "an upgrade points at the same block");
    }
    assert_eq(a.strong_count(), 1);
}

@test
fn conformances_forward_to_the_value() {
    let a = Rc::<String>::new(String::from_str("abc"));
    let b = Rc::<String>::new(String::from_str("abc"));
    let c = Rc::<String>::new(String::from_str("abd"));
    assert(a == b, "equal values in different blocks");
    assert(!a.ptr_eq(&b), "different blocks");
    assert(a != c, "different values");
    assert(a.cmp(&c) < 0, "ordered by value");
    let plain = String::from_str("abc");
    assert_eq(hash(&a), hash(&plain));
    let f = a.fmt();
    assert(f.as_str() == "abc", "format forwards");
    assert_eq(a.len(), 3);
    let d = Rc::<i32>::default();
    assert_eq(*d.get(), 0);
}

// A derived `Clone` and `Default` build over an all-zero seed and assign each field, which frees the
// zeroed handle first.
@derive(Clone, Default)
struct Holder {
    pub r: Rc<i32>,
}

@test
fn derived_clone_and_default_of_a_struct_with_an_rc() {
    let h = Holder { r: Rc::<i32>::new(3) };
    let k = h.clone();
    assert(k.r.ptr_eq(&h.r), "a derived clone shares the block");
    assert_eq(h.r.strong_count(), 2);
    let d = Holder::default();
    assert_eq(*d.r.get(), 0);
}
