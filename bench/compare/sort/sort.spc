// The Super-C side of the libc++ sort comparison (sort.cpp): the same inputs, timing and report (the mean
// of the faster half of the runs, each on a fresh copy of the input).
import std::platform::clock as clock;

static mut RNG: u64 = 0;

fn next() u64 {
    unsafe {
        RNG = RNG ^ RNG << 13;
        RNG = RNG ^ RNG >> 7;
        RNG = RNG ^ RNG << 17;
        return RNG;
    }
}

fn make(kind: i32, n: usize) Vector<u64> {
    unsafe RNG = 88172645463325252;
    let mut v = Vector::<u64>::with_capacity(n);
    for i in 0..n {
        let x = switch kind {
            0 => next(),
            1 => i as u64,
            2 => (n - i) as u64,
            3 => next() % 16,
            _ => (i % 1000) as u64,
        };
        v.push(x);
    }
    return v;
}

fn run(op: i32, v: &mut Vector<u64>) {
    let n = v.len();
    switch op {
        0 => v.sort(),
        1 => v.sort_by(|a: &u64, b: &u64| b.cmp(a)),
        2 => v.sort_stable(),
        3 => v.sort_stable_by(|a: &u64, b: &u64| b.cmp(a)),
        4 => v.as_mut_slice().select_nth_unstable(n / 2),
        _ => {
            v.as_mut_slice().heapify();
            v.as_mut_slice().sort_heap();
        },
    }
}

fn lane(op: i32, kind_name: str, kind: i32, n: usize, reps: i32) {
    let names: [str; 6] = ["sort", "sort_by", "stable", "stable_by", "select", "heap"];
    let mut times = Vector::<f64>::new();
    let mut sum: u64 = 0;
    let input = make(kind, n);
    let mut v = input.clone();
    for _ in 0..reps {
        v.as_mut_slice().copy_from_slice(&input);
        let t0 = clock::monotonic_ns();
        run(op, &mut v);
        let t1 = clock::monotonic_ns();
        times.push((t1 - t0) as f64 / n as f64);
        sum = 0;
        if op == 4 {
            sum = *v.at(n / 2);
            continue;
        }
        let mut i: usize = 0;
        while i < n {
            sum = sum.wrapping_mul(31).wrapping_add(*v.at(i));
            i += n / 64 + 1;
        }
    }
    times.sort();
    let half = times.len() / 2;
    let mut fast: f64 = 0.0;
    for i in 0..half {
        fast += *times.at(i);
    }
    println("{} {} {} {} {}", unsafe names[op as usize], kind_name, n, fast / half as f64, sum);
}

fn main() i32 {
    let names: [str; 5] = ["random", "sorted", "reversed", "few16", "saw1000"];
    let sizes: [usize; 3] = [1000, 100000, 1000000];
    for n in sizes {
        let reps = if n == 1000 {
            2000
        } else if n == 100000 {
            40
        } else {
            8
        };
        for k in 0..5 {
            for op in 0..6 {
                lane(op, unsafe names[k as usize], k, n, reps);
            }
        }
    }
    return 0;
}
