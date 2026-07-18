// Self-hosted port of tests/raii_gen_test.c -- an auto-generating deep-RAII stress suite. It synthesizes
// programs over deeply nested owning types (chains of Option / Result / Box wrapping a leaf Free type `Tr`,
// plus Vector aggregates) and exercises every ownership operation the move analysis must get right:
// scope-exit free, move-into-call, conditional move, binding reassignment, container deep-free, and nested
// switch in all three modes (move-out, borrow-peek, free-elaboration of a bound-but-not-moved payload).
//
// Soundness oracle: `Tr::free` does `putchar(self.id)`, so each tracker prints its unique id byte exactly
// when it is freed. The one RAII invariant -- every value freed EXACTLY once -- becomes: the MULTISET of
// bytes printed == the multiset of ids constructed (a missing byte is a leak, a doubled byte a double-free).
// Each batch is built + run through `super-c build` (via h::compile_and_run) and must exit 0 with a
// matching free multiset. (The C suite additionally links under ASan; `super-c build` uses plain cc, so the
// multiset check -- not ASan -- is what catches leaks / double-frees here.)
//
// FULL depth, matching tests/raii_gen_test.c (MAX_SWITCH_DEPTH=6, MAX_GENERAL_DEPTH=5): OR switch chains
// through depth 6 and ORB general chains through depth 5 -- hundreds of scenarios per op. Scenarios batch
// into programs (ID_CAP ids each) and the ops fork-parallelize across @tests; within a fork the batches
// build+run serially (no OpenMP fan-out), so raii_gen is the slow part of the run -- the cost of exhaustive
// RAII coverage. (The C suite additionally runs under ASan; here the free-multiset check catches the bugs.)
import tests::harness as h;
import stdio;
import stdlib;
import string as cstring;

// Ops the matrix exercises (mirrors the C enum).
const OP_FREE: i32 = 0; // scope-exit auto-free of a deeply nested owner
const OP_CALL: i32 = 1; // move the whole nested value by value into a consumer that frees it
const OP_COND_T: i32 = 2; // conditional move, true path (moves into the consumer)
const OP_COND_F: i32 = 3; // conditional move, false path (leaves it to free at scope exit)
const OP_REASSIGN: i32 = 4; // reassigning a Free binding frees the old value
const OP_VECTOR: i32 = 5; // a Vector of nested owners deep-frees every element
const OP_VPOP: i32 = 6; // pop moves one element out; both it and the remainder free once
const OP_SW_MOVE: i32 = 7; // nested switch moves the leaf Tr out; it frees at scope exit
const OP_SW_FREE: i32 = 8; // nested switch binds-but-doesn't-move the leaf -> free elaboration at the arm
const OP_SW_PEEK: i32 = 9; // nested borrow-peek; the scrutinee stays owned and frees at scope exit

const ID_CAP: i32 = 60; // ids map to bytes 48.. ; keep them printable (48+59 = 107 < 127)
const PROG_CAP: i32 = 524288; // 512 KiB per-batch program buffer

// TR_PRE: exit/putchar bindings + the leaf tracker whose `free` prints its id byte.
const TR_PRE: str = "extern \"C\" { fn exit(code: i32) void; fn putchar(c: i32) i32; }\nstruct Tr { pub id: i32 }\nextend Tr as Free { fn free(self: &mut Tr) { unsafe putchar(self.id); } }\n";

// Bounded scratch buffers (`{}` zero-fills; Super-C has no `[v; N]` repeat literal).
struct Buf16 {
    pub b: [char; 16],
}
struct Buf64 {
    pub b: [char; 64],
}
struct Buf256 {
    pub b: [char; 256],
}
struct Buf1024 {
    pub b: [char; 1024],
}
struct Buf2048 {
    pub b: [char; 2048],
}
struct Buf8192 {
    pub b: [char; 8192],
}
struct Hist {
    pub c: [i32; 256],
}

// Bounded append into `b` at offset `at` (cap-limited); returns the new end offset. Always NUL-terminates.
fn ap(b: *mut char, at: i32, cap: i32, s: *const char) i32 {
    let mut n = (unsafe cstring::strlen(s)) as i32;
    if at + n >= cap {
        n = cap - 1 - at;
    }
    if n < 0 {
        n = 0;
    }
    unsafe cstring::memcpy(b + at as usize, s, n as usize);
    let end = at + n;
    unsafe b[end as usize] = 0 as char;
    return end;
}

fn id_need(op: i32) i32 {
    if op == OP_REASSIGN || op == OP_VPOP {
        return 2;
    }
    if op == OP_VECTOR {
        return 3;
    }
    return 1;
}

// The Super-C TYPE for shape[p..], e.g. "OR" -> "Option<Result<Tr, i32>>".
fn ty(b: *mut char, at: i32, cap: i32, sh: *const char, p: i32) i32 {
    let c = unsafe sh[p as usize];
    if c == 0 as char {
        return ap(b, at, cap, "Tr".ptr() as *const char);
    }
    if c == 'O' {
        let mut a = ap(b, at, cap, "Option<".ptr() as *const char);
        a = ty(b, a, cap, sh, p + 1);
        return ap(b, a, cap, ">".ptr() as *const char);
    }
    if c == 'R' {
        let mut a = ap(b, at, cap, "Result<".ptr() as *const char);
        a = ty(b, a, cap, sh, p + 1);
        return ap(b, a, cap, ", i32>".ptr() as *const char);
    }
    let mut a = ap(b, at, cap, "Box<".ptr() as *const char);
    a = ty(b, a, cap, sh, p + 1);
    return ap(b, a, cap, ">".ptr() as *const char);
}

// A Super-C EXPRESSION building shape[p..] wrapping a single `Tr { id }`.
fn bld(b: *mut char, at: i32, cap: i32, sh: *const char, p: i32, id: i32) i32 {
    let c = unsafe sh[p as usize];
    if c == 0 as char {
        let mut t = Buf1024 {};
        unsafe stdio::snprintf(&mut t.b[0], 1024, "Tr { id: %d }".ptr() as *const char, id);
        return ap(b, at, cap, &t.b[0]);
    }
    let mut inner = Buf1024 {};
    let _ = ty(&mut inner.b[0], 0, 1024, sh, p + 1);
    let innerp = (&inner.b[0]) as *const char;
    let mut hdr = Buf1024 {};
    if c == 'O' {
        unsafe stdio::snprintf(&mut hdr.b[0], 1024, "Option::<%s>::Some(".ptr() as *const char, innerp);
    } else if c == 'R' {
        unsafe stdio::snprintf(&mut hdr.b[0], 1024, "Result::<%s, i32>::Ok(".ptr() as *const char, innerp);
    } else {
        unsafe stdio::snprintf(&mut hdr.b[0], 1024, "Box::<%s>::new(".ptr() as *const char, innerp);
    }
    let mut a = ap(b, at, cap, &hdr.b[0]);
    a = bld(b, a, cap, sh, p + 1, id);
    return ap(b, a, cap, ")".ptr() as *const char);
}

// A nested switch over an O/R chain. mode 0: move the leaf Tr out (yields Tr); 1: read the leaf id without
// moving it (the Tr frees at the arm, yields i32); 2: borrow-peek through `&` (yields i32, scrutinee owned).
// Dead None/Err arms are never taken but must type-check, so they yield a throwaway.
fn sw(b: *mut char, at: i32, cap: i32, sh: *const char, p: i32, var: *const char, mode: i32, top: i32) i32 {
    let c = unsafe sh[p as usize];
    if c == 0 as char {
        if mode == 0 {
            return ap(b, at, cap, var);
        }
        let mut t = Buf1024 {};
        unsafe stdio::snprintf(&mut t.b[0], 1024, "%s.id".ptr() as *const char, var);
        return ap(b, at, cap, &t.b[0]);
    }
    let mut nv = Buf64 {};
    unsafe stdio::snprintf(&mut nv.b[0], 64, "%s_%d".ptr() as *const char, var, p);
    let nvp = (&nv.b[0]) as *const char;
    let pfx = if mode == 2 && top != 0 {
        "&".ptr() as *const char;
    } else {
        "".ptr() as *const char;
    };
    let dead = if mode == 0 {
        "Tr { id: 0 }".ptr() as *const char;
    } else {
        "0".ptr() as *const char;
    };
    let mut hdr = Buf256 {};
    if c == 'O' {
        unsafe stdio::snprintf(&mut hdr.b[0], 256, "switch %s%s { Some(%s) => ".ptr() as *const char, pfx, var, nvp);
    } else {
        unsafe stdio::snprintf(&mut hdr.b[0], 256, "switch %s%s { Ok(%s) => ".ptr() as *const char, pfx, var, nvp);
    }
    let mut a = ap(b, at, cap, &hdr.b[0]);
    a = sw(b, a, cap, sh, p + 1, nvp, mode, 0);
    let mut tail = Buf256 {};
    if c == 'O' {
        unsafe stdio::snprintf(&mut tail.b[0], 256, ", None => %s, }".ptr() as *const char, dead);
    } else {
        unsafe stdio::snprintf(&mut tail.b[0], 256, ", Err(_) => %s, }".ptr() as *const char, dead);
    }
    return ap(b, a, cap, &tail.b[0]);
}

// True if the two NUL-terminated byte strings are equal as MULTISETS (order-independent free-trace check).
fn multiset_eq(a: *const char, b: *const char) bool {
    if a == null || b == null {
        return false;
    }
    let mut ca = Hist {};
    let mut cb = Hist {};
    let mut i: usize = 0;
    loop {
        let ch = unsafe a[i];
        if ch == 0 as char {
            break;
        }
        let k = (ch as u8) as usize;
        unsafe ca.c[k] = unsafe ca.c[k] + 1;
        i = i + 1;
    }
    i = 0;
    loop {
        let ch = unsafe b[i];
        if ch == 0 as char {
            break;
        }
        let k = (ch as u8) as usize;
        unsafe cb.c[k] = unsafe cb.c[k] + 1;
        i = i + 1;
    }
    for j in 0..256 {
        if unsafe ca.c[j] != unsafe cb.c[j] {
            return false;
        }
    }
    return true;
}

// A batch accumulator: scenario functions append into `prog`, their call lines into `calls`, and their
// constructed id bytes into `exp`. When the id budget fills, `flush` assembles + builds + runs the batch.
struct Gen {
    pub prog: *mut char,
    pub at: i32,
    pub calls: [char; 16384],
    pub cat: i32,
    pub exp: [char; 256],
    pub eat: i32,
    pub idc: i32,
    pub sc: i32,
    pub nbatch: i32,
}

fn new_gen() Gen {
    let p = (unsafe stdlib::malloc(PROG_CAP as usize)) as *mut char;
    let mut g = Gen { prog: p, at: 0, cat: 0, eat: 0, idc: 0, sc: 0, nbatch: 0 };
    g.at = ap(g.prog, 0, PROG_CAP, TR_PRE.ptr() as *const char);
    return g;
}

extend Gen {
    // Record one id byte into the expected-free multiset.
    fn push_id(self: &mut Gen, id: i32) {
        unsafe self.exp[self.eat as usize] = id as char;
        self.eat = self.eat + 1;
        unsafe self.exp[self.eat as usize] = 0 as char;
    }

    // Emit one scenario for shape `sh` and operation `op`; flush first if the id budget would overflow.
    fn scenario(self: &mut Gen, sh: *const char, op: i32) {
        if self.idc + id_need(op) > ID_CAP {
            self.flush();
        }
        let mut tb = Buf1024 {};
        let _ = ty(&mut tb.b[0], 0, 1024, sh, 0);
        let tp = (&tb.b[0]) as *const char;
        let id0 = 48 + self.idc;
        self.idc = self.idc + 1;
        let mut id1 = 0;
        let mut id2 = 0;
        self.push_id(id0);
        if id_need(op) >= 2 {
            id1 = 48 + self.idc;
            self.idc = self.idc + 1;
            self.push_id(id1);
        }
        if id_need(op) >= 3 {
            id2 = 48 + self.idc;
            self.idc = self.idc + 1;
            self.push_id(id2);
        }

        let mut e0 = Buf2048 {};
        let _ = bld(&mut e0.b[0], 0, 2048, sh, 0, id0);
        let e0p = (&e0.b[0]) as *const char;
        let sc = self.sc;
        let mut fb = Buf8192 {};
        let fbp = (&fb.b[0]) as *const char;
        let mut cb = Buf256 {};
        let progp = self.prog;

        if op == OP_FREE {
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let v = %s; return 0; }\n".ptr() as *const char,
                sc,
                e0p,
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_CALL {
            unsafe stdio::snprintf(&mut fb.b[0], 8192, "fn c%d(v: %s) i32 { return 0; }\n".ptr() as *const char, sc, tp);
            self.at = ap(progp, self.at, PROG_CAP, fbp);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { return c%d(%s); }\n".ptr() as *const char,
                sc,
                sc,
                e0p,
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_COND_T || op == OP_COND_F {
            unsafe stdio::snprintf(&mut fb.b[0], 8192, "fn c%d(v: %s) i32 { return 0; }\n".ptr() as *const char, sc, tp);
            self.at = ap(progp, self.at, PROG_CAP, fbp);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d(flag: bool) i32 { let mut acc = 0; let v = %s; if flag { acc = c%d(v); } return acc; }\n".ptr() as *const char,
                sc,
                e0p,
                sc,
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_REASSIGN {
            let mut e1 = Buf2048 {};
            let _ = bld(&mut e1.b[0], 0, 2048, sh, 0, id1);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let mut v = %s; v = %s; return 0; }\n".ptr() as *const char,
                sc,
                e0p,
                &e1.b[0],
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_VECTOR {
            let mut e1 = Buf2048 {};
            let mut e2 = Buf2048 {};
            let _ = bld(&mut e1.b[0], 0, 2048, sh, 0, id1);
            let _ = bld(&mut e2.b[0], 0, 2048, sh, 0, id2);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let mut vec = Vector::<%s>::new(); vec.push(%s); vec.push(%s); vec.push(%s); return 0; }\n".ptr() as *const char,
                sc,
                tp,
                e0p,
                &e1.b[0],
                &e2.b[0],
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_VPOP {
            let mut e1 = Buf2048 {};
            let _ = bld(&mut e1.b[0], 0, 2048, sh, 0, id1);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let mut vec = Vector::<%s>::new(); vec.push(%s); vec.push(%s); let popped = vec.pop(); return 0; }\n".ptr() as *const char,
                sc,
                tp,
                e0p,
                &e1.b[0],
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_SW_MOVE {
            let mut s_ = Buf8192 {};
            let _ = sw(&mut s_.b[0], 0, 8192, sh, 0, "v".ptr() as *const char, 0, 1);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let v = %s; let t = %s; return t.id; }\n".ptr() as *const char,
                sc,
                e0p,
                &s_.b[0],
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_SW_FREE {
            let mut s_ = Buf8192 {};
            let _ = sw(&mut s_.b[0], 0, 8192, sh, 0, "v".ptr() as *const char, 1, 1);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let v = %s; return %s; }\n".ptr() as *const char,
                sc,
                e0p,
                &s_.b[0],
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        } else if op == OP_SW_PEEK {
            let mut s_ = Buf8192 {};
            let _ = sw(&mut s_.b[0], 0, 8192, sh, 0, "v".ptr() as *const char, 2, 1);
            unsafe stdio::snprintf(
                &mut fb.b[0],
                8192,
                "fn sc%d() i32 { let v = %s; let r = %s; return r; }\n".ptr() as *const char,
                sc,
                e0p,
                &s_.b[0],
            );
            self.at = ap(progp, self.at, PROG_CAP, fbp);
        }

        unsafe stdio::snprintf(&mut cb.b[0], 256, "  acc = acc + sc%d(%s);\n".ptr() as *const char, sc, callarg(op));
        self.cat = ap(&mut self.calls[0], self.cat, 16384, &cb.b[0]);
        self.sc = self.sc + 1;
    }

    // Assemble the accumulated scenarios into one program, build + run it, and assert exit 0 with a matching
    // free multiset. Then reset for the next batch.
    fn flush(self: &mut Gen) {
        if self.sc == 0 {
            return;
        }
        self.at = ap(self.prog, self.at, PROG_CAP, "fn main() i32 { let mut acc = 0;\n".ptr() as *const char);
        self.at = ap(self.prog, self.at, PROG_CAP, &self.calls[0]);
        self.at = ap(
            self.prog,
            self.at,
            PROG_CAP,
            "  if acc == 2147483647 { unsafe putchar(33); }\n  unsafe exit(0); }\n".ptr() as *const char,
        );
        let src = str::from_raw(self.prog as *const u8, self.at as usize);
        let mut r = h::compile_and_run(src);
        assert(r.built, "raii-gen: batch failed to build");
        assert_eq(r.exit, 0);
        assert(multiset_eq(r.out, &self.exp[0]), "raii-gen: free multiset mismatch (leak or double-free)");
        self.at = ap(self.prog, 0, PROG_CAP, TR_PRE.ptr() as *const char);
        self.cat = 0;
        self.calls[0] = 0 as char;
        self.eat = 0;
        self.exp[0] = 0 as char;
        self.idc = 0;
        self.sc = 0;
        self.nbatch = self.nbatch + 1;
    }

    fn finish(self: &mut Gen) {
        self.flush();
        if self.prog != null {
            unsafe stdlib::free(self.prog);
            self.prog = null;
        }
    }
}

// The argument list a scenario call takes: COND variants pass a bool flag; everything else is nullary.
fn callarg(op: i32) *const char {
    if op == OP_COND_T {
        return "true".ptr() as *const char;
    }
    if op == OP_COND_F {
        return "false".ptr() as *const char;
    }
    return "".ptr() as *const char;
}

// Enumerate every shape over `alphabet` up to `max_depth` (length >= 1), emitting `op` for each.
fn enum_shapes(g: &mut Gen, sh: *mut char, at: i32, max_depth: i32, alphabet: *const char, op: i32) {
    if at > 0 {
        unsafe sh[at as usize] = 0 as char;
        g.scenario(sh, op);
    }
    if at == max_depth {
        return;
    }
    let alen = (unsafe cstring::strlen(alphabet)) as i32;
    for i in 0..alen {
        unsafe sh[at as usize] = unsafe alphabet[i as usize];
        enum_shapes(g, sh, at + 1, max_depth, alphabet, op);
    }
}

// Run every OR-switch shape (through depth 6, matching tests/raii_gen_test.c's MAX_SWITCH_DEPTH) per mode.
fn run_switch(op: i32) {
    let mut g = new_gen();
    let mut sh = Buf16 {};
    enum_shapes(&mut g, &mut sh.b[0], 0, 6, "OR".ptr() as *const char, op);
    g.finish();
}

// Run every ORB general shape (through depth 5, matching tests/raii_gen_test.c's MAX_GENERAL_DEPTH) per op.
fn run_general(op: i32) {
    let mut g = new_gen();
    let mut sh = Buf16 {};
    enum_shapes(&mut g, &mut sh.b[0], 0, 5, "ORB".ptr() as *const char, op);
    g.finish();
}

@test
fn switch_move() {
    run_switch(OP_SW_MOVE);
}
@test
fn switch_free() {
    run_switch(OP_SW_FREE);
}
@test
fn switch_peek() {
    run_switch(OP_SW_PEEK);
}
@test
fn general_free() {
    run_general(OP_FREE);
}
@test
fn general_call() {
    run_general(OP_CALL);
}
@test
fn general_cond() {
    run_general(OP_COND_T);
    run_general(OP_COND_F);
}
@test
fn general_reassign() {
    run_general(OP_REASSIGN);
}
@test
fn general_vector() {
    run_general(OP_VECTOR);
    run_general(OP_VPOP);
}
