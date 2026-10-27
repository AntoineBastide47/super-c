// Debug information and unwind data of native objects: every target's line tables verify and name the
// source lines, the code and data sections are the same bytes with and without debug information (as
// GCC's `-fcompare-debug` checks), a debugger steps and backtraces a native program, and the unwinder
// restores the callee-saved registers of the frames above native ones.
import target::native as nat;
import target::table as tgt;
import tests::cli_harness as cli;
import std::platform::fs;
import stdio;
import stdlib;

// Native frames that keep values in callee-saved registers across their calls: `mid` calls `leaf` on
// line 21, `leaf` calls `getpid` on line 10. `mid(4)` is 9.
const DEEP: str<'static> = M"(extern "C" {
    fn getpid() i32;
}

@noinline
fn leaf(k: i64) i64 {
    let mut s: i64 = 0;
    let mut a: f64 = 0.5;
    for i in 0..k {
        s = s + (unsafe getpid()) as i64 * 0 + i;
        a = a * 1.5;
    }
    return s + a as i64;
}

@noinline
fn mid(n: i64) i64 {
    let mut s: i64 = 0;
    let mut a: f64 = 1.5;
    for i in 0..n {
        s = s + leaf(i);
        a = a * 1.25;
    }
    return s + a as i64;
}

fn main() i32 {
    return (mid(4) - 9) as i32;
}
)";

// A profile without debug information, unoptimized as the debug one: the native backend compiles both.
const MANIFEST: str<'static> = "bin = \"app\"\nroot = \"main.spc\"\n\n[profile.nog]\nopt-level = 0\n";

// The output of `exe args` run from `dir`, empty when it fails to run.
fn tool(dir: str, exe: str, args: str) String {
    let r = cli::exe_env_in(exe, dir, "SC_TOOL", "1", args);
    if r.out == null {
        return String::new();
    }
    return String::from_str(unsafe str::from_cstr(r.out));
}

// An llvm-dwarfdump: on the path, beside clang (`-print-prog-name`), the wasi-sdk's, or Xcode's; empty
// without one.
fn dwarfdump(dir: str) String {
    if tool(dir, "llvm-dwarfdump", "--version").contains("LLVM") {
        return String::from_str("llvm-dwarfdump");
    }
    let beside = tool(dir, "clang", "-print-prog-name=llvm-dwarfdump");
    let path = beside.as_str().trim();
    if path.starts_with("/") && fs::stat(path).is_ok() {
        return String::from_str(path);
    }
    let sdk = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    let w = format("{}/bin/llvm-dwarfdump", sdk.as_str());
    if sdk.len() != 0 && fs::stat(w.as_str()).is_ok() {
        return w;
    }
    if PLATFORM == Platform::macOS {
        let x = tool(dir, "xcrun", "--find llvm-dwarfdump");
        if x.as_str().trim().starts_with("/") {
            return String::from_str(x.as_str().trim());
        }
    }
    return String::new();
}

const fn le(b: &Vector<u8>, at: usize, n: usize) u64 {
    let mut v: u64 = 0;
    for i in 0..n {
        v |= b[at + i] as u64 << (8 * i) as u64;
    }
    return v;
}

// The bytes the image takes from object `o`: each section's name and contents but the debug ones
// (Mach-O's `__DWARF` segment, ELF's unallocated sections, COFF's discardable ones, wasm's custom
// sections), in file order.
fn image_bytes(o: &Vector<u8>) Vector<u8> {
    let mut out = Vector::<u8>::new();
    if o.len() < 64 {
        return out;
    }
    if le(o, 0, 4) == 0xFEEDFACF {
        let mut c: usize = 32;
        for _ in 0..le(o, 16, 4) {
            if le(o, c, 4) == 0x19 {
                for k in 0..le(o, c + 64, 4) as usize {
                    let sct = c + 72 + k * 80;
                    let ty = le(o, sct + 64, 4) & 0xFF;
                    if o[sct + 18] == b'D' && o[sct + 19] == b'W' && o[sct + 20] == b'A' || ty == 1 || ty == 0x12 {
                        continue;
                    }
                    put_section(&mut out, o, sct, 16, le(o, sct + 48, 4) as usize, le(o, sct + 40, 8) as usize);
                }
            }
            c += le(o, c + 4, 4) as usize;
        }
    } else if le(o, 0, 4) == 0x464C457F {
        let shoff = le(o, 0x28, 8) as usize;
        let shentsize = le(o, 0x3A, 2) as usize;
        let stroff = le(o, shoff + le(o, 0x3E, 2) as usize * shentsize + 0x18, 8) as usize;
        for k in 0..le(o, 0x3C, 2) as usize {
            let sh = shoff + k * shentsize;
            // SHF_ALLOC, and not SHT_NOBITS.
            if (le(o, sh + 8, 8) & 2) == 0 || le(o, sh + 4, 4) == 8 {
                continue;
            }
            put_section(
                &mut out,
                o,
                stroff + le(o, sh, 4) as usize,
                16,
                le(o, sh + 0x18, 8) as usize,
                le(o, sh + 0x20, 8) as usize,
            );
        }
    } else if le(o, 0, 2) == 0x8664 {
        let hdr = 20 + le(o, 16, 2) as usize;
        for k in 0..le(o, 2, 2) as usize {
            let sh = hdr + k * 40;
            if (le(o, sh + 36, 4) & 0x02000000) != 0 {
                continue;
            }
            put_section(&mut out, o, sh, 8, le(o, sh + 20, 4) as usize, le(o, sh + 16, 4) as usize);
        }
    } else if le(o, 0, 4) == 0x6D736100 {
        let mut at: usize = 8;
        // Each step passes one section.
        while at < o.len() {
            let id = o[at];
            let mut size: usize = 0;
            let mut sh: usize = 0;
            at += 1;
            while (o[at] & 0x80) != 0 {
                size |= (o[at] & 0x7F) as usize << sh;
                sh += 7;
                at += 1;
            }
            size |= o[at] as usize << sh;
            at += 1;
            if id != 0 {
                out.push(id);
                for j in at..at + size {
                    out.push(o[j]);
                }
            }
            at += size;
        }
    }
    return out;
}

// Append the name at `name` (up to `nlen` bytes, NUL-ended) and the `size` bytes at `off` of `o`.
fn put_section(out: &mut Vector<u8>, o: &Vector<u8>, name: usize, nlen: usize, off: usize, size: usize) {
    for j in 0..nlen {
        if o[name + j] == 0 {
            break;
        }
        out.push(o[name + j]);
    }
    out.push(0);
    for j in off..off + size {
        out.push(o[j]);
    }
}

// The native objects under `dir`, by path below it.
fn objects(dir: str, rel: str, out: &mut Vector<String>) {
    if let Ok(mut d) = fs::read_dir(dir) {
        while let Some(Ok(e)) = d.next() {
            let path = format("{}/{}", dir, e.name);
            let r = format("{}/{}", rel, e.name);
            if e.kind == Option::<fs::FileKind>::Some(fs::FileKind::Dir) {
                objects(path.as_str(), r.as_str(), out);
            } else if e.name.ends_with(".o") {
                out.push(r);
            }
        }
    }
}

fn read_bytes(path: str) Vector<u8> {
    let mut out = Vector::<u8>::new();
    let f = stdio::fopen(path, "rb");
    if f == null {
        return out;
    }
    let mut buf: [u8; 4096] = [0; 4096];
    // Each step reads up to 4 KiB until a short read.
    loop {
        let n = unsafe stdio::fread((&mut buf[0]) as *mut u8, 1, 4096, f);
        for i in 0..n {
            out.push(unsafe buf[i]);
        }
        if n < 4096 {
            break;
        }
    }
    unsafe stdio::fclose(f);
    return out;
}

// Whether the line table `dump` (llvm-dwarfdump's `--debug-line`) has a row for line `line` of `file`
// (its only file).
fn has_row(dump: &String, line: u32) bool {
    // A row reads `0x<address> <line> <column> ...`, the fields space-padded.
    let want = format("{}", line);
    for l in dump.as_str().lines() {
        if !l.starts_with("0x") {
            continue;
        }
        let sp = l.find_byte(b' ');
        if sp > 0 && l.slice(sp as usize, l.len()).trim_start().starts_with(format("{} ", want.as_str()).as_str()) {
            return true;
        }
    }
    return false;
}

// Every native target's objects for `DEEP` with debug information verify, have rows for the lines of
// both calls, and hold the same code and data as without it: the host's linked, the others' objects
// (their links need toolchains this host may lack).
@test
fn line_tables_verify_and_leave_the_code_unchanged() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) || cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", MANIFEST);
    p.mkfile("main.spc", DEEP);
    let dd = dwarfdump(p.dir());
    let targets: []str = [
        "",
        "--target=linux --arch=x86_64",
        "--target=linux --arch=aarch64",
        "--target=windows --arch=x86_64",
        "--target=wasm",
    ];
    for t in 0..targets.len() {
        let a = format("build {} --out-dir=d{}", targets[t], t);
        let b = format("build {} --profile=nog --out-dir=n{}", targets[t], t);
        let ra = cli::superc_in(p.dir(), a.as_str());
        let rb = cli::superc_in(p.dir(), b.as_str());
        if t == 0 {
            assert(ra.ok() && rb.ok(), "the host builds both profiles");
        } else if ra.out_has("no sysroot found") {
            continue; // the runner has not the target's C headers, which the header facts need
        }
        let mut objs = Vector::<String>::new();
        objects(format("{}/d{}/debug/raw", p.dir(), t).as_str(), "", &mut objs);
        assert(objs.len() > 1, "the debug build writes native objects");
        // The registry's sentinels are zero-filled: some object has bytes.
        let mut any = false;
        for k in 0..objs.len() {
            let with = read_bytes(format("{}/d{}/debug/raw{}", p.dir(), t, objs.at(k).as_str()).as_str());
            let without = read_bytes(format("{}/n{}/nog/raw{}", p.dir(), t, objs.at(k).as_str()).as_str());
            assert(with.len() >= without.len(), "debug information takes nothing away");
            let iw = image_bytes(&with);
            any = any || iw.len() != 0;
            assert(iw.as_slice() == image_bytes(&without).as_slice(), "the code and data are the same bytes");
        }
        assert(any, "the objects' sections read");
        if dd.len() == 0 {
            continue;
        }
        let main = format("d{}/debug/raw/main.o", t);
        let ow = read_bytes(format("{}/{}", p.dir(), main.as_str()).as_str());
        let on = read_bytes(format("{}/n{}/nog/raw/main.o", p.dir(), t).as_str());
        assert(ow.len() > on.len(), "debug information adds sections to main's object");
        let v = tool(p.dir(), dd.as_str(), format("--verify {}", main.as_str()).as_str());
        assert(v.contains("No errors."), "the debug information verifies");
        let lt = tool(p.dir(), dd.as_str(), format("--debug-line {}", main.as_str()).as_str());
        assert(has_row(&lt, 10) && has_row(&lt, 21), "the line table has rows for the calls");
    }
}

// A debugger stops in a native function by its name and backtraces through the native frames to their
// lines: gdb where it runs a program (Linux), lldb where it may (macOS, with developer mode).
@test
fn a_debugger_backtraces_native_frames() {
    if !nat::supported(tgt::host_os(), tgt::host_isa()) || cli::on_wasm() || PLATFORM == Platform::Windows {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", MANIFEST);
    p.mkfile("main.spc", DEEP);
    assert(cli::superc_in(p.dir(), "build").ok(), "the program builds");
    let bin = format("{}/build/debug/app", p.dir());
    let out = if PLATFORM == Platform::macOS {
        tool(
            p.dir(),
            "lldb",
            format("--batch -o \"breakpoint set --name leaf\" -o run -o bt {}", bin.as_str()).as_str(),
        );
    } else {
        tool(p.dir(), "gdb", format("-batch -ex \"break leaf\" -ex run -ex bt {}", bin.as_str()).as_str());
    };
    // gdb names a stop `Breakpoint 1, leaf (...)`, lldb `stop reason = breakpoint`: without one no debugger
    // ran the program.
    if !out.contains("Breakpoint 1, ") && !out.contains("stop reason = breakpoint") {
        println("skipped: no debugger runs a program here");
        return;
    }
    assert(out.contains("leaf") && out.contains("main.spc:"), "the stop names leaf and its line");
    assert(out.contains("mid") && out.contains("main.spc:21"), "the backtrace names mid's call");
    assert(out.contains("__sc_user_main") && out.contains("main.spc:28"), "and main's");
}

// The C driver of `unwinding_restores_callee_saved_registers`: `driver` holds known values in the
// callee-saved registers across a call of Super-C `sc_entry`, whose frames call `probe`, which unwinds
// to `driver`'s frame and reads them there (macOS: libunwind's cursor, whose backtrace callback reads no
// restored register; elsewhere the unwinder's backtrace).
const DRIVER: str<'static> = M"(#include <stdint.h>
#if defined(__APPLE__)
#include <libunwind.h>
#else
#include <unwind.h>
#endif

long sc_entry(long n);

static long status = 1;

long driver(long n);
void driver_end(void);

// Whether `ip` is in `driver`, which unoptimized compilers lay out before `driver_end`, in source order.
static int in_driver(uintptr_t ip) {
    return ip > (uintptr_t)&driver && ip < (uintptr_t)&driver_end;
}

#if defined(__aarch64__)
#define NREGS 10
static const int REGS[NREGS] = {19, 20, 21, 22, 23, 24, 25, 26, 27, 28};
#else
#define NREGS 5
static const int REGS[NREGS] = {3, 12, 13, 14, 15};
#endif

#if defined(__APPLE__)
// libunwind's cursor: each frame up from here, until `driver`'s.
long probe(void) {
    unw_context_t uc;
    unw_cursor_t cur;
    unw_getcontext(&uc);
    unw_init_local(&cur, &uc);
    for (int d = 0; d < 64 && unw_step(&cur) > 0; d++) {
        unw_word_t ip = 0;
        unw_get_reg(&cur, UNW_REG_IP, &ip);
        if (!in_driver(ip)) continue;
        status = 0;
        for (int k = 0; k < NREGS; k++) {
            unw_word_t v = 0;
            unw_get_reg(&cur, UNW_AARCH64_X19 + k, &v);
            if (v != (unw_word_t)(0x5C00 + k)) status = 10 + k;
        }
        break;
    }
    return 0;
}
#else
static _Unwind_Reason_Code walk(struct _Unwind_Context *c, void *arg) {
    (void)arg;
    if (!in_driver(_Unwind_GetIP(c))) return _URC_NO_REASON;
    status = 0;
    for (int k = 0; k < NREGS; k++)
        if (_Unwind_GetGR(c, REGS[k]) != (uintptr_t)(0x5C00 + k)) status = 10 + k;
    return _URC_END_OF_STACK;
}

// The unwinder's backtrace: each frame up from here, until `driver`'s.
long probe(void) {
    _Unwind_Backtrace(walk, 0);
    return 0;
}
#endif

// Unoptimized, the compiler keeps no value of its own in a callee-saved register: what the first
// statement sets there stays to the call, and the last one reads what the call left.
long driver(long n) {
    long kept;
#if defined(__aarch64__)
    __asm__ volatile(
        "mov x19, #0x5C00\n mov x20, #0x5C01\n mov x21, #0x5C02\n mov x22, #0x5C03\n mov x23, #0x5C04\n"
        "mov x24, #0x5C05\n mov x25, #0x5C06\n mov x26, #0x5C07\n mov x27, #0x5C08\n mov x28, #0x5C09\n"
        ::: "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28");
    long v = sc_entry(n);
    __asm__ volatile("mov x9, #0x5C00\n cmp x19, x9\n cset %0, eq\n" : "=r"(kept) :: "x9", "cc");
#else
    __asm__ volatile(
        "movq $0x5C00, %%rbx\n movq $0x5C01, %%r12\n movq $0x5C02, %%r13\n movq $0x5C03, %%r14\n"
        "movq $0x5C04, %%r15\n" ::: "rbx", "r12", "r13", "r14", "r15");
    long v = sc_entry(n);
    __asm__ volatile("xorl %%eax, %%eax\n cmpq $0x5C00, %%rbx\n sete %%al\n movq %%rax, %0\n" : "=r"(kept) :: "rax", "cc");
#endif
    return status * 100 + (kept ? 0 : 50) + v - 9;
}

void driver_end(void) {
}
)";

@test
fn unwinding_restores_callee_saved_registers() {
    if !cli::has_cc() {
        return; // the C compiler builds it
    }
    if !nat::supported(tgt::host_os(), tgt::host_isa()) || cli::on_wasm() || PLATFORM == Platform::Windows {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("drv.c", DRIVER);
    assert(p.c_lib("drv", "drv.c"), "the C driver builds");
    // The driver calls the unwinder, which glibc's targets have in the C compiler's runtime.
    let rt = p.cc_runtime(p.dir());
    p.mkfile(
        "main.spc",
        format(
            M"(@link("-L{} -ldrv{}")
extern "C" {{
    fn probe() i64;
    fn driver(n: i64) i64;
}}

@noinline
fn leaf(k: i64) i64 {{
    let mut s: i64 = 0;
    let mut a: f64 = 0.5;
    for i in 0..k {{
        s = s + i + (unsafe probe());
        a = a * 1.5;
    }}
    return s + a as i64;
}}

@noinline
fn mid(n: i64) i64 {{
    let mut s: i64 = 0;
    let mut a: f64 = 1.5;
    for i in 0..n {{
        s = s + leaf(i);
        a = a * 1.25;
    }}
    return s + a as i64;
}}

@export("sc_entry")
pub fn entry(n: i64) i64 {{
    return mid(n);
}}

fn main() i32 {{
    return (unsafe driver(4)) as i32;
}}
)",
            p.dir(),
            rt.as_str(),
        ).as_str(),
    );
    let r = cli::superc_in(p.dir(), "build");
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "the program builds");
    let run = cli::exe_env_in(format("{}/build/debug/app", p.dir()).as_str(), p.dir(), "SC_T", "1", "");
    assert_eq(run.exit, 0);
}
