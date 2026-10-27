// The traps of the vector code the native backends compile, spelled as the C units' lane checks spell them
// (`emit::mangle`, `LANE_CHECK_C`): the message, formatted the same way, goes to the runtime's `__sc_panic`.
// The loader adds this module to a program that names a vector (`loader::Package::load_backend`), so a
// program without vectors carries none of it. Like the runtime, it imports no module.
extern "C" "stdlib.h" {
    @import("abort")
    fn c_abort();
}

extern "C" "string.h" {
    @import("strlen")
    fn c_strlen(s: *const char) usize;
}

// The runtime's trap (`std::rt::base`), bound by C name.
extern "C" {
    @import("__sc_panic")
    fn c_panic(m: *const char);
}

// `m` through the runtime's trap; the trap does not return.
@noreturn
fn panic_with(m: *const char) {
    unsafe c_panic(m);
    unsafe c_abort();
}

// A message: its bytes, then a NUL; `len` bytes so far (at most `MSG - 1`).
const MSG: usize = 160;
struct Msg {
    pub b: [char; MSG],
    pub len: usize,
}

extend Msg {
    const fn new() Msg {
        return Msg { b: [0 as char; MSG], len: 0 };
    }

    // Append `s`, cut at the buffer's end.
    const fn add(self: &mut Self, s: str) {
        for k in 0..s.len() {
            if self.len < MSG - 1 {
                unsafe self.b[self.len] = s.byte_at(k) as char;
                self.len += 1;
            }
        }
    }

    // Append `v` in decimal.
    const fn dec(self: &mut Self, v: u64) {
        let mut d = [0u8; 20];
        let mut i: usize = 20;
        let mut x = v;
        // At most 20 digits.
        loop {
            i -= 1;
            unsafe d[i] = b'0' + (x % 10) as u8;
            x /= 10;
            if x == 0 {
                break;
            }
        }
        for k in i..20 {
            let c = unsafe d[k];
            if self.len < MSG - 1 {
                unsafe self.b[self.len] = c as char;
                self.len += 1;
            }
        }
    }

    // `self` through the runtime's trap.
    @noreturn
    fn raise(self: &mut Self) {
        unsafe self.b[self.len] = 0 as char;
        panic_with(&self.b[0]);
    }
}

// Lane index `i` of a vector of `n` lanes out of range.
@export("__sc_index_bounds")
@noreturn
@cold
fn index_bounds(i: u64, n: u64) {
    let mut m = Msg::new();
    m.add("index out of bounds: the index is ");
    m.dec(i);
    m.add(" but the length is ");
    m.dec(n);
    m.raise();
}

// A vector load or store of `w` lanes from `i` into `n` elements out of range.
@export("__sc_vec_bounds")
@noreturn
@cold
fn vec_bounds(w: u64, i: u64, n: u64) {
    let mut m = Msg::new();
    m.add("index out of bounds: ");
    m.dec(w);
    m.add(" lanes from ");
    m.dec(i);
    m.add(" but the length is ");
    m.dec(n);
    m.raise();
}

// Lane `lane` of a masked or gather access out of range: the element is `x + lane` from start `x`
// (`start`), else index `x`; the slice has `n` elements.
@export("__sc_lane_bounds")
@noreturn
@cold
fn lane_bounds(lane: u64, x: u64, n: u64, start: bool) {
    let mut m = Msg::new();
    m.add("lane ");
    m.dec(lane as u32);
    m.add(": index out of bounds: the index is ");
    m.dec(x);
    if start {
        m.add(" + ");
        m.dec(lane as u32);
    }
    m.add(" but the length is ");
    m.dec(n);
    m.raise();
}

// Lane `lane` of a vector operation fails with message `f`.
@export("__sc_lane_panic")
@noreturn
@cold
fn lane_panic(lane: u64, f: *const char) {
    let mut m = Msg::new();
    m.add("lane ");
    m.dec(lane as u32);
    m.add(": ");
    m.add(unsafe str::from_raw(f as *const u8, c_strlen(f)));
    m.raise();
}
