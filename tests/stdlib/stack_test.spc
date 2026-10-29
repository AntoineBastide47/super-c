// std::alloc::Stack: containers on the task-local stack allocator. Checked: blocks reclaimed when freed in
// reverse order and when freed out of order, the top block grown in place, alignment, owning elements,
// pages given back after a large temporary, one region per coroutine across parks and moves between
// workers, data-parallel jobs and plain threads, each region released when its task or thread ends, and
// that a `Stack` container is not `Send`.
import sc_runtime;
import std::alloc;
import std::parallel::data as parallel;
import std::parallel::runtime as rt;
import std::parallel::sync;
import std::parallel::thread;
import std::testing::bench_sys as sys;
import tests::cli_harness as cli;

// Take ownership of `v`; it is freed on return.
fn release<T>(_v: T) {}

@test
fn zero_sized() {
    assert_eq(sizeof(alloc::Stack), 0);
    assert_eq(sizeof(Vector<u64, alloc::Stack>), sizeof(Vector<u64>));
}

@test
fn blocks_freed_in_reverse_order_are_reclaimed() {
    let u0 = alloc::Stack::used();
    {
        let mut a = Vector::<u64, alloc::Stack>::new();
        for i in 0u64..10000 {
            a.push(i);
        }
        let mut sum: u64 = 0;
        for i in 0..a.len() {
            sum += a[i];
        }
        assert_eq(sum, 9999 * 10000 / 2);
        assert(alloc::Stack::used() >= u0 + 10000 * 8, "the vector takes its bytes from the region");
    }
    assert_eq(alloc::Stack::used(), u0);
}

@test
fn the_top_block_grows_in_place() {
    let u0 = alloc::Stack::used();
    {
        let mut v = Vector::<u32, alloc::Stack>::new();
        v.push(1);
        let p = v.as_ptr();
        for i in 0u32..100000 {
            v.push(i);
        }
        assert(v.as_ptr() == p, "the top block grows without moving");
        assert_eq(v[100000], 99999u32);
    }
    assert_eq(alloc::Stack::used(), u0);
}

@test
fn blocks_freed_out_of_order_are_reclaimed_from_the_top() {
    let u0 = alloc::Stack::used();
    let mut a = Vector::<u8, alloc::Stack>::new();
    a.push(1);
    let ua = alloc::Stack::used();
    let mut b = Vector::<u8, alloc::Stack>::new();
    b.push(2);
    let mut c = Vector::<u8, alloc::Stack>::new();
    c.push(3);
    // `b` is under `c`: it is only marked.
    release(b);
    assert(alloc::Stack::used() > ua, "a block under the top is not reclaimed");
    // Freeing `c` takes `b` with it.
    release(c);
    assert_eq(alloc::Stack::used(), ua);
    // `a` grows past its block while `d` is on top: it moves, and its old block is reclaimed with `d`.
    let mut d = Vector::<u8, alloc::Stack>::new();
    d.push(4);
    for i in 0u8..200 {
        a.push(i);
    }
    assert_eq(a[0], 1u8);
    assert_eq(a[200], 199u8);
    release(d);
    release(a);
    assert_eq(alloc::Stack::used(), u0);
}

@test
fn blocks_are_aligned() {
    let mut s = alloc::Stack::new();
    let aligns: []usize = [1, 2, 8, 16, 64, 4096];
    let mut ps = Vector::<*mut void>::new();
    for i in 0..aligns.len() {
        let p = unsafe s.alloc(3, aligns[i]);
        assert_eq(p as usize % aligns[i], 0);
        ps.push(p);
    }
    for i in 0..ps.len() {
        unsafe s.dealloc(ps[ps.len() - 1 - i], 3, aligns[ps.len() - 1 - i]);
    }
}

@test
fn owning_elements() {
    let u0 = alloc::Stack::used();
    {
        let mut v = Vector::<String<alloc::Stack>, alloc::Stack>::new();
        let mut m = Map::<u64, String<alloc::Stack>, alloc::Stack>::new();
        for k in 0u64..1000 {
            let mut s = String::<alloc::Stack>::from_str("a string past the inline buffer, number ");
            s.push_str(k.fmt().as_str());
            v.push(s);
            m.insert(k, String::<alloc::Stack>::from_str("an owned map value past the inline buffer"));
            if k % 3 == 0 {
                let _ = m.remove(&k);
            }
        }
        for k in 0u64..1000 {
            assert(v[k as usize].ends_with(k.fmt().as_str()), "each string keeps its bytes");
            assert(m.get(&k).is_some() == (k % 3 != 0), "the map keeps what was not removed");
        }
    }
    assert_eq(alloc::Stack::used(), u0);
}

@test
fn large_temporaries_come_and_go() {
    let u0 = alloc::Stack::used();
    for round in 0u64..8 {
        let mut full: i64 = 0;
        {
            let mut v = Vector::<u64, alloc::Stack>::new();
            for i in 0u64..1 << 22 {
                v.push(i ^ round);
            }
            assert_eq(v[12345], 12345 ^ round);
            full = unsafe sys::sc_bs_rss_now();
        }
        // The 32 MiB vector is gone, and so are its pages.
        let after = unsafe sys::sc_bs_rss_now();
        assert(full < 0 || full - after > 16 * 1048576, "the region gives its pages back");
    }
    assert_eq(alloc::Stack::used(), u0);
}

// Each task fills its own vectors across parks, so the tasks run interleaved and move between workers. Each
// task's region is released when its body returns: once the pool is down, none is left.
@test
fn one_region_per_task() {
    let live = sc_runtime::sc_rt_stk_live();
    let wg = sync::WaitGroup::new();
    wg.add(8);
    for t in 0u64..8 {
        let w = wg.clone();
        launch || {
            defer w.done();
            assert_eq(alloc::Stack::used(), 0);
            {
                let mut a = Vector::<u64, alloc::Stack>::new();
                let mut b = Vector::<u64, alloc::Stack>::new();
                for i in 0u64..2000 {
                    a.push(i * 8 + t);
                    if i % 100 == 0 {
                        rt::yield_now();
                    }
                    b.push(i);
                }
                for i in 0u64..2000 {
                    assert_eq(a[i as usize], i * 8 + t);
                    assert_eq(b[i as usize], i);
                }
            }
            assert_eq(alloc::Stack::used(), 0);
        };
    }
    wg.wait();
    rt::shutdown();
    assert_eq(sc_runtime::sc_rt_stk_live(), live);
}

// Jobs use their worker thread's region, released when the pool's workers exit; a plain thread's region
// is released when the thread exits, before `join` returns.
@test
fn jobs_and_threads() {
    let live = sc_runtime::sc_rt_stk_live();
    parallel::range(
        0..64,
        |i: usize| {
            let mut v = Vector::<usize, alloc::Stack>::new();
            for k in 0usize..1000 {
                v.push(k + i);
            }
            assert_eq(v[999], 999 + i);
        },
    );
    rt::shutdown();
    assert_eq(sc_runtime::sc_rt_stk_live(), live);
    let th = thread::spawn(
        || {
            let mut v = Vector::<u32, alloc::Stack>::new();
            for k in 0u32..1000 {
                v.push(k);
            }
            return (v[999] as u64, sc_runtime::sc_rt_stk_live());
        },
    );
    let (last, inside) = th.join();
    assert_eq(last, 999u64);
    assert_eq(inside, live + 1);
    assert_eq(sc_runtime::sc_rt_stk_live(), live);
}

// The main thread's region lives as long as the process.
@test
fn the_main_threads_region_stays() {
    let mut v = Vector::<u8, alloc::Stack>::new();
    v.push(1);
    let live = sc_runtime::sc_rt_stk_live();
    assert(live >= 1, "the region exists");
    release(v);
    assert_eq(sc_runtime::sc_rt_stk_live(), live);
}

@test
fn a_stack_container_stays_in_its_task() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        "import std::alloc;\nfn send<T: Send>(_x: T) {}\nfn main() i32 {\n    let v = Vector::<u8, alloc::Stack>::new();\n    send(v);\n    return 0;\n}\n",
    );
    let r = p.run_raw(format("build --no-lint \"{}/main.spc\" -o \"{}/bin\"", p.dir(), p.dir()).as_str());
    assert(!r.ok() && r.out_has("does not satisfy bound 'Send'"), "a Stack vector is not Send");
}
