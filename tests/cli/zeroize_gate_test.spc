// The zeroization gate: at the release profile a buffer that is dead after `std::mem::volatile::zeroize`
// still has its bytes cleared. The emitted C keeps the volatile stores, and the machine code of the
// function that holds them (the zeroize routine, or `main` once it is inlined) keeps zero stores.
import tests::cli_harness as cli;
import driver_shim as shim;

const DEAD_KEY: str = M"(import std::mem::volatile as vol;
fn main(args: Vector<str>) i32 {
    let mut key: [u8; 40] = [0; 40];
    let mut s: u32 = 0;
    unsafe {
        for i in 0usize..40 {
            key[i] = (args.len() + i + 1) as u8;
        }
        for i in 0usize..40 {
            s += key[i];
        }
    }
    vol::zeroize(key);
    return (s % 7) as i32;
}
)";

// Whether disassembly line `l` stores zero to memory: an aarch64 store of the zero register, or an
// x86 move of an immediate zero to a memory operand.
const fn zero_store(l: str) bool {
    let arm = l.find("\tst") >= 0 && (l.find("\txzr,") >= 0 || l.find("\twzr,") >= 0 || l.find(" xzr,") >= 0 || l.find(
        " wzr,",
    ) >= 0);
    let x86 = l.find("mov") >= 0 && (l.find("$0x0,") >= 0 || l.find("$0,") >= 0) && l.find("(%") >= 0;
    return arm || x86;
}

// The symbol a disassembly line opens (otool's `_name:`, objdump's `0000.. <name>:`), or "".
const fn label_of(l: str) str {
    if !l.ends_with(":") || l.len() < 2 {
        return "";
    }
    let lt = l.find("<");
    if lt >= 0 && l.ends_with(">:") {
        return l.slice(lt as usize + 1, l.len() - 2);
    }
    let b0 = l.byte_at(0);
    if b0 == b' ' || b0 == b'\t' || b0 >= b'0' && b0 <= b'9' {
        return "";
    }
    return l.slice(0, l.len() - 1);
}

// The zero stores in the functions of disassembly `text` whose name holds `main` or `zeroize`. A line
// ends at "\n" or "\r\n": a Windows disassembler writes its output in text mode.
const fn zero_stores_in_scope(text: str) u32 {
    let mut n: u32 = 0;
    let mut inside = false;
    let mut at: usize = 0;
    while at < text.len() {
        let rest = text.slice(at, text.len());
        let e = rest.find("\n");
        let mut line = if e < 0 {
            rest;
        } else {
            rest.slice(0, e as usize);
        };
        at += line.len() + 1;
        if line.ends_with("\r") {
            line = line.slice(0, line.len() - 1);
        }
        let lab = label_of(line);
        if lab.len() != 0 {
            inside = lab.find("main") >= 0 || lab.find("zeroize") >= 0;
        } else if inside && zero_store(line) {
            n += 1;
        }
    }
    return n;
}

@test
fn zeroize_of_a_dead_buffer_survives_release() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", DEAD_KEY);
    // The release profile with its symbols: the disassembly must name the functions it scopes to.
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n\n[profile.release]\nstrip = false\n");
    let root = p.dir();
    let r = cli::superc_in(root, "build --profile=release");
    r.show();
    assert(r.ok(), "the program builds at the release profile");
    assert_eq(p.run_bin(), 6);
    // The C backend's emission keeps the volatile stores too.
    if cli::has_cc() {
        let _c = cli::set_env("SC_NATIVE", "0");
        let rc = cli::superc_in(root, "build --profile=release --out-dir=cbuild -o cbuild/cbin");
        assert(rc.ok(), "the program builds through C at the release profile");
        let c = cli::read_text(format("{}/cbuild/release/raw/std/mem/volatile.c", root).as_str());
        assert(c.as_str().contains("(*(uint8_t volatile *)("), "the emitted C keeps the volatile byte stores");
        assert(c.as_str().contains("(*(size_t volatile *)("), "the emitted C keeps the volatile word stores");
    }
    let bin = format("{}/bin{}", root, unsafe str::from_cstr(cli::binext()));
    let mut cmd = if unsafe shim::sc_host_platform() == 1 {
        format("otool -tv \"{}\"", bin.as_str());
    } else {
        format("objdump -d \"{}\"", bin.as_str());
    };
    let mut outp = format("{}/.dis", root);
    if cli::run_with(cmd.cstr(), null, outp.cstr(), null, "") != 0 {
        eprintln("skipped the object-code half: `{}` failed (no disassembler on this host)", cmd.as_str());
        return;
    }
    let dis = cli::read_text(outp.as_str());
    let n = zero_stores_in_scope(dis.as_str());
    if n == 0 {
        eprintln("`{}` printed:\n{}", cmd.as_str(), dis.as_str().slice(0, dis.len().min(4000)));
    }
    assert(n >= 1, "the object code keeps the stores of the dead buffer");
}
