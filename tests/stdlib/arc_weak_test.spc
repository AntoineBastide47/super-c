// std::parallel::arc's Weak: downgrade and upgrade on one thread and across two tasks, the value freed
// exactly once by the last strong drop wherever it runs, upgrade failure afterwards, get_mut refused while
// a Weak made by another task lives, try_unwrap, and the block freed by the last weak drop (leak check).

import atomic;
import std::parallel::arc as *;
import std::parallel::atomics as atomics;
import std::parallel::channel as chan;
import std::parallel::runtime as rt;

static mut FREES: i64 = 0;

fn frees() i64 {
    return unsafe atomic::load_i64(&FREES, atomics::MemoryOrder::SeqCst as i32);
}

// Counts its frees in `FREES`.
struct Tracked {
    pub v: i64,
}

extend Tracked as Free {
    pub fn free(self: &mut Tracked) {
        let _ = unsafe atomic::add_i64(&mut FREES, 1, atomics::MemoryOrder::SeqCst as i32);
    }
}

@test
fn weak_follows_the_strong_count_on_one_thread() {
    let a = Arc::<Tracked>::new(Tracked { v: 3 });
    let w = a.downgrade();
    assert_eq(a.strong_count(), 1);
    assert_eq(a.weak_count(), 1);
    assert_eq(w.strong_count(), 1);
    let w2 = w.clone();
    assert_eq(a.weak_count(), 2);
    {
        let up = w2.upgrade();
        assert(up.is_some(), "the value lives");
        let b = up.unwrap();
        assert(b.ptr_eq(&a), "the same block");
        assert_eq(a.strong_count(), 2);
    }
    {
        let _last = a;
    }
    assert_eq(frees(), 1);
    assert(w.upgrade().is_none(), "no upgrade after the last strong drop");
    assert_eq(w.strong_count(), 0);
    let none = Weak::<Tracked>::new();
    assert(none.upgrade().is_none(), "Weak::new");
    assert_eq(none.strong_count(), 0);
    let none2 = none.clone();
    assert(none2.upgrade().is_none(), "a clone of Weak::new");
    assert_eq(frees(), 1);
}

@test
fn try_unwrap_and_get_mut_on_one_thread() {
    let mut a = Arc::<Tracked>::new(Tracked { v: 1 });
    a.get_mut().unwrap().v = 2;
    let b = a.clone();
    assert(a.get_mut().is_none(), "another strong handle");
    let back = a.try_unwrap();
    assert(back.is_err(), "shared: the handle comes back");
    let mut again = back.unwrap_err();
    {
        let _drop = b;
    }
    let w = again.downgrade();
    assert(again.get_mut().is_none(), "a weak handle");
    let t = again.try_unwrap();
    assert(t.is_ok(), "unique strong handle: the value comes out");
    assert(w.upgrade().is_none(), "the weak handle no longer upgrades");
    assert_eq(frees(), 0);
    let v = t.unwrap();
    assert_eq(v.v, 2);
}

@test
fn weak_upgrades_in_a_task_until_the_last_strong_drop() {
    rt::set_worker_count(2);
    let strong = Arc::<Tracked>::new(Tracked { v: 7 });
    let weak = strong.downgrade();
    let to_task = chan::Channel::<i64>::bounded(1);
    let from_task = chan::Channel::<i64>::bounded(1);
    // Every handle exists before the task starts: a channel with no live sender reads as closed.
    let go = to_task.receiver();
    let kick = to_task.sender();
    let reply = from_task.sender();
    let answers = from_task.receiver();
    let w = weak.clone();
    launch move (|| {
        // While the value lives, an upgrade sees it; the upgraded handle drops inside the arm.
        let seen = if let Some(a) = w.upgrade() {
            a.get().v;
        } else {
            -1;
        };
        let _ = reply.send(seen);
        let _ = go.recv();
        let after = if w.upgrade().is_none() {
            1;
        } else {
            0;
        };
        let _ = reply.send(after);
    });
    assert_eq(answers.recv().unwrap(), 7);
    assert_eq(frees(), 0);
    {
        let _last = strong;
    }
    assert_eq(frees(), 1);
    let _ = kick.send(0);
    assert_eq(answers.recv().unwrap(), 1);
    rt::shutdown();
    assert_eq(weak.strong_count(), 0);
    assert_eq(frees(), 1);
}

@test
fn a_weak_from_another_task_blocks_get_mut_until_dropped() {
    rt::set_worker_count(2);
    let mut a = Arc::<Tracked>::new(Tracked { v: 1 });
    // The strong handle travels through a channel, so the task owns it as a local it can drop early.
    let strongs = chan::Channel::<Arc<Tracked>>::bounded(1);
    let weaks = chan::Channel::<Weak<Tracked>>::bounded(1);
    let done = chan::Channel::<i64>::bounded(1);
    let rx = strongs.receiver();
    let give = strongs.sender();
    let tx = weaks.sender();
    let back = weaks.receiver();
    let finished = done.sender();
    let finish = done.receiver();
    launch move (|| {
        {
            let mine = rx.recv().unwrap();
            let _ = tx.send(mine.downgrade());
        }
        // The strong handle `mine` dropped before this signal.
        let _ = finished.send(0);
    });
    let _ = give.send(a.clone());
    let w = back.recv().unwrap();
    let _ = finish.recv();
    assert_eq(a.strong_count(), 1);
    assert_eq(a.weak_count(), 1);
    assert(a.get_mut().is_none(), "the task's Weak still lives");
    {
        let up = w.upgrade();
        assert(up.is_some(), "the Weak upgrades while the value lives");
        assert_eq(a.strong_count(), 2);
    }
    {
        let _gone = w;
    }
    assert_eq(a.weak_count(), 0);
    a.get_mut().unwrap().v = 9;
    rt::shutdown();
    let v = a.try_unwrap();
    assert(v.is_ok(), "unique again");
    assert_eq(frees(), 0);
    assert_eq(v.unwrap().v, 9);
}
