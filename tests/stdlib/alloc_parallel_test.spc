// std::parallel::pool: SyncPool shared by two tasks, with owning containers under the leak check; the
// handle's Send and Sync conformance; release and the statistics behind the lock.
import std::parallel::pool;
import std::parallel::data as parallel;
import std::parallel::runtime as rt;
import std::parallel::arc;
import std::parallel::sync;

const fn shared<X: Send + Sync>(_x: X) bool {
    return true;
}

@test
fn handle_is_send_and_sync() {
    let p = pool::SyncPool::<Global>::new();
    assert(shared(p.allocator()), "SyncPoolAlloc crosses tasks");
}

@test
fn two_tasks_share_one_pool() {
    let p = pool::SyncPool::<Global>::new();
    let h = p.allocator();
    parallel::range(
        0..2,
        |i: usize| {
            let mut v = Vector::<String<pool::SyncPoolAlloc<Global>>, pool::SyncPoolAlloc<Global>>::new_in(h);
            let mut m = Map::<usize, usize, pool::SyncPoolAlloc<Global>>::new_in(h);
            for k in 0usize..500 {
                let mut s = String::<pool::SyncPoolAlloc<Global>>::from_str_in(
                    h,
                    "a pooled string past the inline buffer ",
                );
                s.push_str(k.fmt().as_str());
                v.push(s);
                m.insert(k, k + i);
            }
            for k in 0usize..500 {
                assert(v.at(k).ends_with(k.fmt().as_str()), "each string keeps its bytes");
                assert_eq(*m.get(&k).unwrap(), k + i);
            }
        },
    );
    assert(p.bytes_reserved() > 0, "the tasks took pooled memory");
    assert_eq(p.bytes_unpooled(), 0);
    rt::shutdown();
}

// Two launched tasks allocate, free and grow blocks through one pool.
@test
fn two_launched_tasks_share_one_pool() {
    let p = arc::Arc::<pool::SyncPool<Global>>::new(pool::SyncPool::<Global>::new());
    let wg = sync::WaitGroup::new();
    wg.add(2);
    for t in 0..2 {
        let mine = p.clone();
        let w = wg.clone();
        launch || {
            defer w.done();
            // The containers drop in this block, before `done` signals the wait.
            {
                let h = mine.get().allocator();
                let mut v = Vector::<u64, pool::SyncPoolAlloc<Global>>::new_in(h);
                let mut m = Map::<u64, String<pool::SyncPoolAlloc<Global>>, pool::SyncPoolAlloc<Global>>::new_in(h);
                for k in 0u64..2000 {
                    v.push(k * 2 + t as u64);
                    m.insert(k, String::<pool::SyncPoolAlloc<Global>>::from_str_in(h, "a string owned by a pooled map"));
                    if k % 3 == 0 {
                        let _ = m.remove(&k);
                    }
                }
                let mut ok = v.len() == 2000;
                for k in 0usize..2000 {
                    ok = ok && *v.at(k) == k as u64 * 2 + t as u64;
                }
                assert(ok, "each task reads back its own values");
            }
        };
    }
    wg.wait();
    assert_eq(p.get().bytes_unpooled(), 0);
    rt::shutdown();
}

@test
fn release_returns_every_chunk() {
    let mut p = pool::SyncPool::<Global>::new();
    {
        let mut h = p.allocator();
        let a = unsafe h.alloc(64, 8);
        unsafe h.dealloc(a, 64, 8);
        assert(unsafe h.alloc(64, 8) == a, "a freed block comes back");
        let big = unsafe h.alloc(10000, 8);
        assert_eq(p.bytes_unpooled(), 10000);
        let grown = unsafe h.realloc(big, 10000, 20000, 8);
        assert_eq(p.bytes_unpooled(), 20000);
        unsafe h.dealloc(grown, 20000, 8);
    }
    assert(p.bytes_reserved() > 0, "the pool holds chunks");
    p.release();
    assert_eq(p.bytes_reserved(), 0);
    assert_eq(p.bytes_unpooled(), 0);
}
