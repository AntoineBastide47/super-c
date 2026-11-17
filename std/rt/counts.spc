// The block counts of a `-fblock-counts` build (`build_system::manifest::CG_BLOCK_COUNTS`): each function
// the compiler lowers counts the executions of its Core IR blocks in a counter of its own, and the
// registry of the counters (`__sc_bc_table`, `__sc_bc_len`, `lir::lower::Lower::count_registry`) names
// them. The program's `main` hands `dump` to `atexit`. The loader adds this module to such builds only
// (`Package::rt_counts`).
import stdio;
import stdlib;
@platform(macos | ios | linux | android)
import unistd;

// One function of the registry: its symbol's name and its counter.
struct Entry {
    name: *const u8,
    len: usize,
    count: *const u64,
}

// The registry the compiler defines in the program (`Lower::count_registry`): its entries, sorted by name.
extern "C" {
    fn __sc_bc_table() *const Entry;
    fn __sc_bc_len() usize;
}

@platform(windows)
extern "C" "windows.h" {
    fn GetCurrentProcessId() u32;
}

/// Append `name<TAB>count` for each function that ran to the file that $SC_BLOCK_COUNTS names, with each
/// `%p` in it this process's id, so the processes of one run write files of their own. Nothing without the
/// variable or when the file does not open.
@export("__sc_bc_dump")
pub fn dump() {
    let v = stdlib::getenv("SC_BLOCK_COUNTS");
    if v == null {
        return;
    }
    let tmpl = unsafe str::from_cstr(v);
    let mut path = String::new();
    let mut i: usize = 0;
    while i < tmpl.len() {
        if tmpl.byte_at(i) == b'%' && i + 1 < tmpl.len() && tmpl.byte_at(i + 1) == b'p' {
            path.format_into("{}", process_id());
            i += 2;
        } else {
            path.push_byte(tmpl.byte_at(i));
            i += 1;
        }
    }
    let t = unsafe __sc_bc_table();
    let n = unsafe __sc_bc_len();
    let mut text = String::new();
    for k in 0..n {
        let e = unsafe &*(t + k);
        let c = unsafe *e.count;
        if c != 0 {
            text.push_str(unsafe str::from_raw(e.name, e.len));
            text.format_into("\t{}\n", c);
        }
    }
    let f = stdio::fopen(&path, "ab");
    if f == null {
        return;
    }
    let _ = unsafe stdio::fwrite(text.as_str().ptr(), 1, text.len(), f);
    let _ = unsafe stdio::fclose(f);
}

@platform(macos | ios | linux | android)
fn process_id() u32 {
    return unistd::getpid() as u32;
}
@platform(windows)
fn process_id() u32 {
    return unsafe GetCurrentProcessId();
}
@platform(wasm)
fn process_id() u32 {
    return 0;
}
