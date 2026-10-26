// The instruction tables, their assemblers and disassemblers: every row encodes sample operands, the
// word decodes to a row that encodes it back, and the disassembly assembles to the same word.
import target::a64 as a;
import target::a64tab as at;
import target::a64asm as aa;
import target::table as tgt;
import target::x64 as x;
import target::x64tab as xt;
import target::x64asm as xa;
import target::assembler as asmr;
import codegen::obj as ob;
import target::wasmtab as wt;
import target::wasmasm as wa;
import target::wasmobj as wo;
import target::intrin as intrin;
import target::a64intrin as a64i;
import target::x64intrin as x64i;
import target::wasmintrin as wasmi;
import stdlib;
import tests::cli_harness as cli;
import std::platform::fs;
import std::platform::process;
import stdio;

// Sample values for operand kind `k` of arm64 row `r` (variant `q`) at `v[i..]`.
fn a64_sample(r: at::Row, q: u32, k: u8, v: &mut at::Vals, i: usize) {
    if at::is_reg(k) {
        v[i] = (switch at::reg_pos(k) {
            0 => 1i64,
            5 => 2i64,
            10 => 4i64,
            _ => 3i64,
        });
        return;
    }
    let x = at::is64(r.q, q);
    let sc = at::ldst_scale(r.bits | at::qbits(r.q, q)) as i64;
    switch k {
        at::K::AIMM => {
            v[i] = 5;
            v[i + 1] = 1;
        },
        at::K::LIMM | at::K::LIMMV => {
            v[i] = a::logical_imm(0x0F0F0F0F0F0F0F0Fu64 & at::wmask(x), x);
        },
        at::K::MOVW => {
            v[i] = 0x1234;
            v[i + 1] = 1;
        },
        at::K::MOVZV => {
            v[i] = 0x12340000;
        },
        at::K::MOVNV => {
            v[i] = if x {
                ~0x12340000i64;
            } else {
                (~0x12340000u32) as i32;
            };
        },
        at::K::IMMR => {
            v[i] = 3;
        },
        at::K::IMMS => {
            v[i] = 9;
        },
        at::K::SHL | at::K::SHR | at::K::SIMM6 => {
            v[i] = 3;
        },
        at::K::BFX | at::K::BFIZ => {
            v[i] = 2;
            v[i + 1] = 5;
        },
        at::K::LSH | at::K::ASH => {
            v[i] = 1;
            v[i + 1] = 3;
        },
        at::K::EXT => {
            v[i] = 2;
            v[i + 1] = 2;
        },
        at::K::COND | at::K::CONDM => {
            v[i] = 1;
        },
        at::K::CONDI => {
            v[i] = 0;
        },
        at::K::NZCV => {
            v[i] = 5;
        },
        at::K::IMM5 => {
            v[i] = 7;
        },
        at::K::IMM16 | at::K::UDF16 => {
            v[i] = 0x123;
        },
        at::K::FPIMM => {
            v[i] = 0x78;
        },
        at::K::L26 | at::K::L19 | at::K::L14 => {
            v[i] = 64;
        },
        at::K::ADR => {
            v[i] = 100;
        },
        at::K::ADRP => {
            v[i] = 8192;
        },
        at::K::TBIT => {
            v[i] = 5;
        },
        at::K::MU12 => {
            v[i] = 2;
            v[i + 1] = 3 << sc;
        },
        at::K::MS9 => {
            v[i] = 2;
            v[i + 1] = -5;
        },
        at::K::MPRE9 => {
            v[i] = 2;
            v[i + 1] = -16;
        },
        at::K::MPOST9 => {
            v[i] = 2;
            v[i + 1] = 16;
        },
        at::K::MREG => {
            v[i] = 2;
            v[i + 1] = 3;
            v[i + 2] = 6;
            v[i + 3] = 1;
        },
        at::K::MP7 | at::K::MPRE7 | at::K::MPOST7 => {
            v[i] = 2;
            v[i + 1] = 32;
        },
        at::K::M0 | at::K::MZA => {
            v[i] = 2;
        },
        at::K::SYSREG => {
            v[i] = 0x5E82;
        },
        at::K::BARRIER => {
            v[i] = 11;
        },
        at::K::ISB => {
            v[i] = 15;
        },
        at::K::XLR => {
            v[i] = 5;
        },
        at::K::RNM | at::K::VNM | at::K::RTB | at::K::FELEM => {
            v[i] = 2;
        },
        at::K::PG | at::K::PGZ | at::K::PGM => {
            v[i] = 1;
        },
        at::K::PMM => {
            v[i] = 2;
        },
        at::K::PD => {
            v[i] = 3;
        },
        at::K::PND | at::K::PNGZ | at::K::PNG => {
            v[i] = 9;
        },
        at::K::ZL1 | at::K::ZL2 | at::K::ZL4 => {
            v[i] = 4;
        },
        at::K::ZAT => {
            v[i] = 1;
        },
        at::K::ZASL => {
            let e = at::fixed_q(r, q);
            v[i] = if e == 0 {
                0i64;
            } else {
                1i64;
            };
            v[i + 1] = 1;
            v[i + 2] = 1;
            v[i + 3] = 1;
        },
        at::K::ZAARR => {
            v[i] = 1;
            v[i + 1] = 3;
        },
        at::K::ZAMASK => {
            v[i] = 0x11;
        },
        at::K::PAT => {
            v[i] = 9;
        },
        at::K::MULVL => {
            v[i] = 3;
        },
        at::K::MSV => {
            v[i] = 2;
            v[i + 1] = -2 * at::group(r);
        },
        at::K::MSVR => {
            v[i] = 2;
            v[i + 1] = 3;
        },
        at::K::VLX => {
            v[i] = 1;
        },
        _ => {
            v[i] = 0;
        },
    };
}

// The sample text of every arm64 row and variant, one per line, and the words it encodes.
fn a64_samples(text: &mut String, words: &mut Vector<u32>) {
    let rows: []at::Row = at::ROWS;
    for ri in 0..rows.len() {
        let r = rows[ri];
        for q in 0..8u32 {
            if r.q == at::Q::NONE && q != 0 || r.q != at::Q::NONE && (r.qok as u32 >> q & 1) == 0 {
                continue;
            }
            let mut v = at::Vals::new();
            let mut i: usize = 0;
            for oi in 0..6u32 {
                let k = at::kind_at(r.ops, oi);
                if k == 0 {
                    break;
                }
                a64_sample(r, q, k, &mut v, i);
                i += at::slots(k) as usize;
            }
            if (r.fl & at::FL_SPMOV) != 0 {
                v[1] = 31;
            }
            let mut w: u32 = 0;
            if !at::encode(r, q, &v, &mut w) {
                eprint("row {} '{}' variant {}: the samples do not encode\n", ri, r.mn, q);
                assert(false, "every row encodes its samples");
            }
            let mut ri2: u32 = 0;
            let mut q2: u32 = 0;
            let mut v2 = at::Vals::new();
            assert(at::decode(w, &mut ri2, &mut q2, &mut v2), "the word decodes");
            let mut w2: u32 = 0;
            assert(at::encode(rows[ri2 as usize], q2, &v2, &mut w2) && w2 == w, "the decoded row encodes the word");
            let mut s = String::new();
            assert(aa::disassemble(w, &mut s), "the word disassembles");
            let mut w3: u32 = 0;
            let mut fx = aa::Fix::new();
            let mut err = String::new();
            if !aa::assemble(s.as_str(), &mut w3, &mut fx, &mut err) || w3 != w {
                eprint(
                    "row {} '{}' variant {}: 0x{} prints '{}', which assembles to 0x{} ({})\n",
                    ri,
                    r.mn,
                    q,
                    hex(w),
                    s.as_str(),
                    hex(w3),
                    err.as_str(),
                );
                assert(false, "the disassembly assembles to the word");
            }
            text.push_string(&s);
            text.push_byte(b'\n');
            words.push(w);
        }
    }
}

fn hex(w: u32) String {
    let mut s = String::new();
    s.push_hex(w, false);
    return s;
}

// ---- The C compiler's assembler as the oracle ----

fn read_bytes(path: str) Vector<u8> {
    let mut out = Vector::<u8>::new();
    let f = stdio::fopen(path, "rb");
    if f == null {
        return out;
    }
    let mut buf: [u8; 4096] = [0; 4096];
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

fn le(b: &Vector<u8>, at: usize, n: usize) u64 {
    let mut v: u64 = 0;
    for i in 0..n {
        v |= b[at + i] as u64 << (8 * i) as u64;
    }
    return v;
}

// The bytes of the code section (`__text` of a Mach-O object, `.text` of an ELF one) of object `o`.
fn text_section(o: &Vector<u8>) Vector<u8> {
    let mut out = Vector::<u8>::new();
    if o.len() < 64 {
        return out;
    }
    let mut off: usize = 0;
    let mut size: usize = 0;
    if le(o, 0, 4) == 0xFEEDFACF {
        let ncmds = le(o, 16, 4) as usize;
        let mut c: usize = 32;
        for _ in 0..ncmds {
            let cmd = le(o, c, 4);
            let csize = le(o, c + 4, 4) as usize;
            if cmd == 0x19 {
                let nsects = le(o, c + 64, 4) as usize;
                for k in 0..nsects {
                    let sct = c + 72 + k * 80;
                    if o[sct] == b'_' && o[sct + 2] == b't' && o[sct + 3] == b'e' && o[sct + 4] == b'x' && o[sct + 5] == b't' && o[sct + 6] == 0 {
                        size = le(o, sct + 40, 8) as usize;
                        off = le(o, sct + 48, 4) as usize;
                    }
                }
            }
            c += csize;
        }
    } else if le(o, 0, 4) == 0x464C457F {
        let shoff = le(o, 0x28, 8) as usize;
        let shentsize = le(o, 0x3A, 2) as usize;
        let shnum = le(o, 0x3C, 2) as usize;
        let strndx = le(o, 0x3E, 2) as usize;
        let stroff = le(o, shoff + strndx * shentsize + 0x18, 8) as usize;
        for k in 0..shnum {
            let sh = shoff + k * shentsize;
            let name = stroff + le(o, sh, 4) as usize;
            if o[name] == b'.' && o[name + 1] == b't' && o[name + 2] == b'e' && o[name + 3] == b'x' && o[name + 4] == b't' && o[name + 5] == 0 {
                off = le(o, sh + 0x18, 8) as usize;
                size = le(o, sh + 0x20, 8) as usize;
            }
        }
    } else if le(o, 0, 2) == 0x8664 {
        return coff_section(o, ".text");
    }
    for i in 0..size {
        out.push(o[off + i]);
    }
    return out;
}

// The bytes of section `name` (8 bytes at most) of COFF object `o`; empty for another format.
fn coff_section(o: &Vector<u8>, name: str) Vector<u8> {
    let mut out = Vector::<u8>::new();
    if o.len() < 20 || le(o, 0, 2) != 0x8664 {
        return out;
    }
    // The section headers follow the 20-byte file header and the optional one.
    let nsects = le(o, 2, 2) as usize;
    let hdr = 20 + le(o, 16, 2) as usize;
    for k in 0..nsects {
        let sh = hdr + k * 40;
        let mut same = true;
        for j in 0..8usize {
            let c = if j < name.len() {
                name.byte_at(j);
            } else {
                0u8;
            };
            same = same && o[sh + j] == c;
        }
        if same {
            let size = le(o, sh + 16, 4) as usize;
            let off = le(o, sh + 20, 4) as usize;
            for i in 0..size {
                out.push(o[off + i]);
            }
            return out;
        }
    }
    return out;
}

// The clang the encodings are compared with: the C compiler when it is clang, else `clang` when it runs,
// else empty. The tables take LLVM's choices among equal encodings (`xchg`'s operand order, the VEX
// operand swaps); GNU as takes others.
fn llvm_cc() String {
    if cli::cc_is_clang() {
        return String::from_str(unsafe str::from_cstr(cli::cc_name()));
    }
    let out = format("{}/clang_version_{}.txt", cli::tmp_dir().as_str(), process::pid().unwrap_or(1));
    let mut cmd = String::from_str("clang --version");
    let mut outp = out.clone();
    let ok = cli::run_with(cmd.cstr(), null, outp.cstr(), null, "") == 0;
    let _ = fs::unlink(out.as_str());
    return if ok {
        String::from_str("clang");
    } else {
        String::new();
    };
}

// Assemble `src` with clang (`llvm_cc`) and `flags`: the code section's bytes, empty when there is no
// clang or it does not assemble (its error on stderr).
fn cc_assemble(src: str, flags: str) Vector<u8> {
    let mut xdata = Vector::<u8>::new();
    return cc_assemble_xdata(src, flags, &mut xdata);
}

// `cc_assemble`, and the `.xdata` section of a COFF object into `xdata`.
fn cc_assemble_xdata(src: str, flags: str, xdata: &mut Vector<u8>) Vector<u8> {
    let cc = llvm_cc();
    if cc.len() == 0 {
        return Vector::<u8>::new();
    }
    let dir = format("{}/asm_test_{}", cli::tmp_dir().as_str(), process::pid().unwrap_or(1));
    let _ = fs::mkdir_all(dir.as_str());
    let sp = format("{}/t.s", dir.as_str());
    let op = format("{}/t.o", dir.as_str());
    let f = stdio::fopen(sp.as_str(), "wb");
    unsafe stdio::fwrite(src.ptr(), 1, src.len(), f);
    unsafe stdio::fclose(f);
    let mut cmd = format("\"{}\" -c {} \"{}\" -o \"{}\"", cc.as_str(), flags, sp.as_str(), op.as_str());
    let mut out = Vector::<u8>::new();
    if cli::run_with(cmd.cstr(), null, null, null, "") == 0 {
        let o = read_bytes(op.as_str());
        out = text_section(&o);
        *xdata = coff_section(&o, ".xdata");
    }
    let _ = fs::remove_all(dir.as_str());
    return out;
}

// Every line of `text` assembled by the C compiler gives `words`; the mismatches name their lines.
fn a64_oracle(text: &String, words: &Vector<u32>) {
    let mut src = String::from_str(".text\n");
    src.push_string(text);
    let got = cc_assemble(src.as_str(), "-march=armv9-a+sme2+sme-f64f64+aes+sha2+sha3+crc+rdm+dotprod+i8mm");
    if got.len() == 0 {
        println("skipped: no clang assembles arm64 with SME2");
        return;
    }
    assert_eq(got.len(), words.len() * 4);
    let mut lines = text.split("\n");
    let mut bad: u32 = 0;
    for i in 0..words.len() {
        let line = lines.next().unwrap_or("");
        let w = le(&got, i * 4, 4) as u32;
        if w != words[i] {
            eprint("'{}': ours 0x{}, the C compiler's 0x{}\n", line, hex(words[i]), hex(w));
            bad += 1;
        }
    }
    assert_eq(bad, 0);
}

// A program of many operation kinds: integers of every width, 128-bit and checked arithmetic, floats,
// conversions, vectors, closures, generics, switches, strings and maps, and std's modules with them.
const CORPUS: str = M"(import std::simd as simd;

struct P { pub x: i64, pub y: f64 }

fn pick(k: u32, a: i64, b: i64) i64 {
    return switch k {
        0 => a + b,
        1 => a - b,
        2 => a * b,
        3 => a / (b | 1),
        4 => a % (b | 1),
        5 => a << (b & 63),
        6 => a >> (b & 63),
        _ => a ^ b,
    };
}

fn wide(a: u64, b: u64) u128 {
    let x: u128 = a;
    return x * b + (x << 64) / (b | 1);
}

fn floats(x: f64, y: f32) f64 {
    let z = (x * 2.5 - y as f64) / (x + 1.0);
    return z.sqrt() + (x as i64) as f64 + (y as u32) as f64;
}

fn lanes(a: simd::Simd<i32, 4>, b: simd::Simd<i32, 4>) i32 {
    let c = a + b * a;
    return c[0] + c[3];
}

fn apply<F: fn(i64) i64>(f: F, v: i64) i64 {
    return f(v);
}

fn main() i32 {
    let mut v = Vector::<P>::new();
    for i in 0..20i64 {
        v.push(P { x: i, y: i as f64 * 0.5 });
    }
    let mut m = Map::<String, i64>::new();
    for i in 0..v.len() {
        m.insert(format("k{}", i), pick(i as u32 % 8, v[i].x, 7));
    }
    let k = 3i64;
    let s = apply(|x: i64| x * k + 1, 5);
    let w = wide(0xFFFF_FFFF_FFFF, 12345);
    let f = floats(2.0, 3.5);
    let l = lanes(simd::Simd::<i32, 4>::splat(2), simd::Simd::<i32, 4>::splat(3));
    let (o, ov) = 100i64.overflowing_add(s);
    println("{} {} {} {} {} {} {}", m.len(), s, (w >> 64) as u64, f, l, o, ov);
    return 0;
}
)";

// The code the arm64 generator emits for `CORPUS` and std: every word decodes to a table row, and its
// disassembly assembles back to it.
fn a64_generated() {
    let p = cli::proj_new();
    p.mkfile("main.spc", CORPUS);
    let r = p.run_raw(format("build \"{}/main.spc\"", p.dir()).as_str());
    assert(r.ok(), "the corpus builds natively");
    let mut objs = Vector::<String>::new();
    obj_files(format("{}/build/debug/raw", p.dir()).as_str(), &mut objs);
    assert(objs.len() > 5, "the build's objects");
    let mut words: u64 = 0;
    let mut bad: u32 = 0;
    for i in 0..objs.len() {
        let o = read_bytes(objs[i].as_str());
        let t = text_section(&o);
        let mut k: usize = 0;
        while k + 4 <= t.len() {
            let w = le(&t, k, 4) as u32;
            k += 4;
            words += 1;
            let mut s = String::new();
            let mut w2: u32 = 0;
            let mut fx = aa::Fix::new();
            let mut err = String::new();
            if !aa::disassemble(w, &mut s) || !aa::assemble(s.as_str(), &mut w2, &mut fx, &mut err) || w2 != w {
                if bad < 20 {
                    eprint("{}: 0x{} '{}' ({})\n", objs[i].as_str(), hex(w), s.as_str(), err.as_str());
                }
                bad += 1;
            }
        }
    }
    assert(words > 10000, "the corpus's code");
    assert_eq(bad, 0);
}

// Every `.o` under `dir`, recursively.
fn obj_files(dir: str, out: &mut Vector<String>) {
    let mut d = fs::read_dir(dir).unwrap();
    while let Some(Ok(e)) = d.next() {
        let path = format("{}/{}", dir, e.name);
        if e.kind == Option::<fs::FileKind>::Some(fs::FileKind::Dir) {
            obj_files(path.as_str(), out);
        } else if e.name.ends_with(".o") {
            out.push(path);
        }
    }
}

@test
fn a64_generated_code_round_trips() {
    if tgt::isa(tgt::host_isa()).name != "aarch64" || cli::on_wasm() {
        return;
    }
    a64_generated();
}

@test
fn a64_rows_round_trip() {
    let mut text = String::new();
    let mut words = Vector::<u32>::new();
    a64_samples(&mut text, &mut words);
    assert(words.len() > 400, "the table's rows");
    if tgt::isa(tgt::host_isa()).name == "aarch64" {
        a64_oracle(&text, &words);
    }
}

// ---- x86-64 ----

// Memory operand `j` of the samples: no displacement, 8-bit, 32-bit with a SIB base, base and index,
// RIP-relative, absolute, index without base.
fn x64_mem(j: u32) x::Mem {
    return switch j {
        0 => x::at(x::RAX, 0),
        1 => x::at(x::RBP, -8),
        2 => x::at(x::R12, 0x1000),
        3 => x::ix(x::RSP, x::R13, 3, 16),
        4 => x::Mem { base: x::RIP, index: xt::NOREG, scale: 0, disp: 0x40 },
        5 => x::at(xt::NOREG, 0x100),
        _ => x::ix(xt::NOREG, x::RCX, 2, 0),
    };
}

const X64_MEMS: u32 = 7;

// VSIB operand `j` of the samples (a vector index), false past the last.
fn x64_vsib(j: u32, m: &mut x::Mem) bool {
    *m = (switch j {
        0 => x::ix(x::RAX, 5, 2, 0),
        1 => x::ix(x::RBP, 13, 0, -8),
        2 => x::ix(x::R12, 4, 1, 0x1000),
        3 => x::ix(xt::NOREG, 3, 3, 0x100),
        _ => {
            return false;
        },
    });
    return true;
}

// The operands of sample `var` of row `r` at size `sz` into `n`: registers alone for 0, else memory
// operand `var - 1` in the row's memory position; false when the row has none. A VEX or EVEX row's
// ModRM.rm register is xmm12 (the other source or the other move takes it for a 2-byte VEX prefix);
// an EVEX row takes a mask on odd forms, zeroing on some.
fn x64_sample(r: xt::Row, sz: u8, var: u32, n: &mut xt::Ins) bool {
    n.sz = sz;
    let mut has_mem = false;
    for i in 0..4u32 {
        let k = xt::kind_at(r.ops, i);
        if k == 0 {
            break;
        }
        let alt = (var + i) % 2 == 1 || r.vx != 0 && xt::in_rm(k);
        if xt::mem_only(k) && var == 0 {
            return false;
        }
        if xt::in_rm(k) && !xt::reg_only(k) && var > 0 && !has_mem {
            has_mem = true;
            n.mem_at = i as u8;
            if xt::is_vsib(k) {
                if !x64_vsib(var - 1, &mut n.m) {
                    return false;
                }
            } else {
                n.m = x64_mem(var - 1);
            }
            continue;
        }
        switch k {
            xt::K::R | xt::K::R32 | xt::K::R64 | xt::K::O => {
                n.set_reg(
                    i,
                    if alt {
                        9u8;
                    } else if sz == 1 {
                        6u8;
                    } else {
                        2u8;
                    },
                );
            },
            xt::K::RM | xt::K::RM8 | xt::K::RM16 | xt::K::RM32 | xt::K::RM64 | xt::K::RR32 | xt::K::RR64 | xt::K::IND => {
                n.set_reg(
                    i,
                    if alt {
                        3u8;
                    } else {
                        12u8;
                    },
                );
            },
            xt::K::X | xt::K::XM | xt::K::XR | xt::K::Y | xt::K::YM | xt::K::YR | xt::K::Z | xt::K::ZM | xt::K::ZR => {
                n.set_reg(
                    i,
                    if alt {
                        12u8;
                    } else {
                        3u8;
                    },
                );
            },
            xt::K::XV | xt::K::YV | xt::K::ZV => {
                n.set_reg(i, 5);
            },
            xt::K::XI4 | xt::K::YI4 => {
                n.set_reg(i, 6);
            },
            xt::K::KR | xt::K::KRM | xt::K::KV => {
                n.set_reg(
                    i,
                    if alt {
                        6u8;
                    } else {
                        2u8;
                    },
                );
            },
            xt::K::CL => {
                n.set_reg(i, 1);
            },
            xt::K::I8 => {
                n.imm = 0x7F;
            },
            xt::K::IS8 => {
                n.imm = -5;
            },
            xt::K::IZ => {
                n.imm = if sz == 2 {
                    0x1234i64;
                } else {
                    -300i64;
                };
            },
            xt::K::I64 => {
                n.imm = 0x123456789A;
            },
            xt::K::ONE => {
                n.imm = 1;
            },
            xt::K::REL8 => {
                n.imm = 0x10;
            },
            xt::K::REL32 => {
                n.imm = 0x1000;
            },
            _ => {},
        };
    }
    if (r.vx & xt::MR) != 0 || (r.vx & xt::MK) != 0 && var % 2 == 1 {
        n.kmask = 1 + (var % 7) as u8;
        n.zero = (r.vx & xt::MZ) != 0 && n.mem_at != 0 && var % 4 == 1;
    }
    return var == 0 || has_mem;
}

// The sample text of every x86-64 row, size and operand form, one per line, and the bytes the
// assembler gives it (`ends`: each line's end in `bytes`).
fn x64_samples(text: &mut String, bytes: &mut Vector<u8>, ends: &mut Vector<u32>) {
    let rows: []xt::Row = xt::ROWS;
    let mut lines: u32 = 0;
    for ri in 0..rows.len() {
        let r = rows[ri];
        for si in 0..5u32 {
            let sz: u8 = if si == 0 {
                0u8;
            } else {
                (1u32 << si - 1) as u8;
            };
            if r.sz == 0 && sz != 0 || r.sz != 0 && (sz & r.sz) == 0 {
                continue;
            }
            for var in 0..X64_MEMS + 1 {
                for lk in 0..2u32 {
                    let mut n = xt::Ins::new(ri as u32);
                    if !x64_sample(r, sz, var, &mut n) {
                        break;
                    }
                    if (r.fl & xt::F_CC) != 0 {
                        n.cc = ((ri as u32 + var + si) % 16) as u8;
                    }
                    if lk == 1 {
                        if (r.fl & xt::F_LOCK) == 0 || var == 0 {
                            break;
                        }
                        n.lock = true;
                    }
                    if var == 6 && lk == 0 && ri % 3 == 0 {
                        n.seg = 0x65;
                    }
                    let mut b0 = Vector::<u8>::new();
                    let mut e = xt::Enc::new();
                    if !xt::encode(&n, &mut b0, &mut e) {
                        if (r.vx & xt::MV) != 0 && var == 0 {
                            break; // the next row's form
                        }
                        eprint("row {} '{}' size {} form {}: the sample does not encode\n", ri, r.mn, sz, var);
                        assert(false, "every row encodes its samples");
                    }
                    let mut d = xt::Ins::new(0);
                    let l0 = xt::decode(b0.as_slice(), 0, &mut d);
                    let mut b2 = Vector::<u8>::new();
                    if l0 as usize != b0.len() || !xt::encode(&d, &mut b2, &mut e) || b2.as_slice() != b0.as_slice() {
                        eprint(
                            "row {} '{}' size {} form {}: {} does not decode to itself\n",
                            ri,
                            r.mn,
                            sz,
                            var,
                            bhex(&b0),
                        );
                        assert(false, "every encoding decodes to itself");
                    }
                    let mut s = String::new();
                    xa::print_ins(&n, &mut s);
                    let mut b1 = Vector::<u8>::new();
                    let mut fx = xa::Fix::new();
                    let mut err = String::new();
                    if !xa::assemble(s.as_str(), xa::NOTGT, &mut b1, &mut fx, &mut err) {
                        eprint("row {} '{}': '{}' does not assemble: {}\n", ri, r.mn, s.as_str(), err.as_str());
                        assert(false, "every sample assembles");
                    }
                    // Another row may take the same operands first: the bytes differ only then.
                    let mut d1 = xt::Ins::new(0);
                    let l1 = xt::decode(b1.as_slice(), 0, &mut d1);
                    if l1 as usize != b1.len() || b1.as_slice() != b0.as_slice() && d1.row == ri as u32 {
                        eprint(
                            "row {} '{}': '{}' assembles to {}, the row gives {}\n",
                            ri,
                            r.mn,
                            s.as_str(),
                            bhex(&b1),
                            bhex(&b0),
                        );
                        assert(false, "the text assembles to the row's bytes");
                    }
                    let mut s1 = String::new();
                    xa::print_ins(&d1, &mut s1);
                    let mut b3 = Vector::<u8>::new();
                    if !xa::assemble(s1.as_str(), xa::NOTGT, &mut b3, &mut fx, &mut err) || b3.as_slice() != b1.as_slice() {
                        eprint("'{}' disassembles to '{}', which does not assemble to it\n", s.as_str(), s1.as_str());
                        assert(false, "the disassembly assembles to the bytes");
                    }
                    text.push_string(&s);
                    text.push_byte(b'\n');
                    bytes.extend_copy(&b1);
                    ends.push(bytes.len() as u32);
                    lines += 1;
                }
            }
        }
    }
    assert(lines > 1000, "the samples");
}

fn bhex(b: &Vector<u8>) String {
    let mut s = String::new();
    for i in 0..b.len() {
        if i != 0 {
            s.push_byte(b' ');
        }
        if b[i] < 16 {
            s.push_byte(b'0');
        }
        s.push_hex(b[i], false);
    }
    return s;
}

// Every line of `text` assembled by the C compiler gives its bytes; the mismatches name their lines.
fn x64_oracle(text: &String, bytes: &Vector<u8>, ends: &Vector<u32>) {
    let mut src = String::from_str(".text\n");
    src.push_string(text);
    let flags = if tgt::isa(tgt::host_isa()).name == "x86_64" {
        "";
    } else {
        "--target=x86_64-linux-gnu";
    };
    let got = cc_assemble(src.as_str(), flags);
    if got.len() == 0 {
        println("skipped: no clang assembles x86-64");
        return;
    }
    let mut lines = text.split("\n");
    let mut bad: u32 = 0;
    let mut at: usize = 0;
    let mut st: usize = 0;
    for i in 0..ends.len() {
        let line = lines.next().unwrap_or("");
        let end = ends[i] as usize;
        let n = end - st;
        let mut same = at + n <= got.len();
        for k in 0..n {
            same = same && got[at + k] == bytes[st + k];
        }
        if !same {
            let mut ours = Vector::<u8>::new();
            let mut theirs = Vector::<u8>::new();
            for k in st..end {
                ours.push(bytes[k]);
            }
            let mut d = xt::Ins::new(0);
            let l = if at < got.len() {
                xt::decode(got.as_slice(), at, &mut d) as usize;
            } else {
                0usize;
            };
            for k in at..at + if l == 0 {
                n;
            } else {
                l;
            } {
                if k < got.len() {
                    theirs.push(got[k]);
                }
            }
            eprint("'{}': ours {}, clang's {}\n", line, bhex(&ours).as_str(), bhex(&theirs).as_str());
            bad += 1;
            if bad > 40 || l == 0 {
                break;
            }
            at += l;
        } else {
            at += n;
        }
        st = end;
    }
    assert_eq(bad, 0);
    assert_eq(at, got.len());
}

// The code the x86-64 generator emits for `CORPUS` and std on `os`: every instruction decodes to a
// table row, and its disassembly assembles back to it.
fn x64_generated(os: str) {
    let p = cli::proj_new();
    p.mkfile("main.spc", CORPUS);
    // The link needs the target's C toolchain; the objects come first.
    let _ = p.run_raw(format("build --target={} --arch=x86_64 \"{}/main.spc\"", os, p.dir()).as_str());
    let mut objs = Vector::<String>::new();
    obj_files(format("{}/build/debug/raw", p.dir()).as_str(), &mut objs);
    assert(objs.len() > 5, "the build's objects");
    let mut insts: u64 = 0;
    let mut bad: u32 = 0;
    for i in 0..objs.len() {
        let o = read_bytes(objs[i].as_str());
        let t = text_section(&o);
        let mut k: usize = 0;
        while k < t.len() {
            let mut s = String::new();
            let n = xa::disassemble(t.as_slice(), k, &mut s);
            insts += 1;
            if n == 0 {
                let mut b = Vector::<u8>::new();
                let e = if k + 8 < t.len() {
                    k + 8;
                } else {
                    t.len();
                };
                for j in k..e {
                    b.push(t[j]);
                }
                eprint("{} at 0x{}: {} decodes to no row\n", objs[i].as_str(), hex(k as u32), bhex(&b).as_str());
                bad += 1;
                break;
            }
            let mut b1 = Vector::<u8>::new();
            let mut fx = xa::Fix::new();
            let mut err = String::new();
            let mut same = xa::assemble(s.as_str(), xa::NOTGT, &mut b1, &mut fx, &mut err) && b1.len() == n as usize;
            for j in 0..b1.len() {
                same = same && j < n as usize && b1[j] == t[k + j];
            }
            if !same {
                if bad < 30 || bad % 50 == 0 {
                    eprint(
                        "{} at 0x{}: '{}' assembles to {} ({})\n",
                        objs[i].as_str(),
                        hex(k as u32),
                        s.as_str(),
                        bhex(&b1).as_str(),
                        err.as_str(),
                    );
                }
                bad += 1;
            }
            k += n as usize;
        }
    }
    assert(insts > 10000, "the corpus's code");
    assert_eq(bad, 0);
}

@test
fn x64_generated_code_round_trips() {
    if cli::on_wasm() {
        return;
    }
    x64_generated("linux");
    x64_generated("windows");
}

@test
fn x64_rows_round_trip() {
    let mut text = String::new();
    let mut bytes = Vector::<u8>::new();
    let mut ends = Vector::<u32>::new();
    x64_samples(&mut text, &mut bytes, &mut ends);
    if !cli::on_wasm() {
        x64_oracle(&text, &bytes, &ends);
    }
}

// ---- Module-level assembly ----

// Assemble module-level block `text` for `isa` and `fmt` with ours and with the C compiler for `triple`,
// and compare the code: false when they differ (`what` names the block in the report).
fn module_block(what: str, text: str, isa: u8, fmt: u8, triple: str) bool {
    let mut o = ob::Obj::new();
    let mut asr = asmr::Asm::new(isa, fmt);
    if !asr.module(&mut o, text) {
        eprint("{}: ours does not assemble it: {}\n", what, asr.err.as_str());
        return false;
    }
    let ours = &o.secs[ob::S_TEXT as usize].bytes;
    if ours.len() == 0 {
        return true; // directives alone
    }
    let mut xdata = Vector::<u8>::new();
    let got = cc_assemble_xdata(text, format("--target={}", triple).as_str(), &mut xdata);
    if got.len() == 0 {
        println("skipped: no clang assembles for {}", triple);
        return true;
    }
    if fmt == asmr::FMT_COFF && o.cfi.as_slice() != xdata.as_slice() {
        eprint(
            "{} for {}: our unwind data {} differs from clang's {}\n",
            what,
            triple,
            bhex(&o.cfi).as_str(),
            bhex(&xdata).as_str(),
        );
        return false;
    }
    let mut same = ours.len() == got.len();
    let mut at: usize = 0;
    while same && at < got.len() {
        same = ours[at] == got[at];
        at += 1;
    }
    if !same {
        eprint(
            "{} for {}: ours differs from the C compiler's at byte {} ({} and {} bytes)\n",
            what,
            triple,
            at - 1,
            ours.len(),
            got.len(),
        );
    }
    return same;
}

// Every module-level assembly block of `path`, for each target its attributes name: ours assembles
// it to the C compiler's code.
fn module_blocks(path: str) u32 {
    let src = cli::read_text(path);
    let s = src.as_str();
    let mut bad: u32 = 0;
    let mut from: usize = 0;
    // Each step consumes one block.
    loop {
        let rest = s.slice(from, s.len());
        let k = rest.find("asm(M\"(");
        if k < 0 {
            break;
        }
        let st = from + k as usize + 7;
        let e = s.slice(st, s.len()).find(")\");");
        assert(e >= 0, "the block ends");
        let body = s.slice(st, st + e as usize);
        // The attributes on the lines before it.
        let head = s.slice(
            if st > 200 {
                st - 200;
            } else {
                0usize;
            },
            st,
        );
        let x64 = head.contains("@arch(x86_64)");
        let isa = if x64 {
            asmr::ISA_X64;
        } else {
            asmr::ISA_A64;
        };
        let cpu = if x64 {
            "x86_64";
        } else {
            "aarch64";
        };
        // The last `@platform` before the block: each step moves past one.
        let mut pl = head;
        loop {
            let q = pl.find("@platform(");
            if q < 0 || pl.slice(q as usize + 1, pl.len()).find("@platform(") < 0 {
                pl = pl.slice(
                    if q < 0 {
                        0usize;
                    } else {
                        q as usize;
                    },
                    pl.len(),
                );
                break;
            }
            pl = pl.slice(q as usize + 1, pl.len());
        }
        let what = format("{} block at byte {}", path, st);
        if pl.contains("macos") && !module_block(
            what.as_str(),
            body,
            isa,
            asmr::FMT_MACHO,
            if x64 {
                "x86_64-apple-macos11";
            } else {
                "arm64-apple-macos11 -march=armv9-a+sme2+sme-f64f64";
            },
        ) {
            bad += 1;
        }
        if pl.contains("linux") && !module_block(
            what.as_str(),
            body,
            isa,
            asmr::FMT_ELF,
            format(
                "{}-linux-gnu{}",
                cpu,
                if x64 {
                    "";
                } else {
                    " -march=armv9-a+sme2+sme-f64f64";
                },
            ).as_str(),
        ) {
            bad += 1;
        }
        if pl.contains("windows") && !module_block(
            what.as_str(),
            body,
            isa,
            asmr::FMT_COFF,
            format("{}-pc-windows-msvc", cpu).as_str(),
        ) {
            bad += 1;
        }
        from = st + e as usize;
    }
    return bad;
}

@test
fn module_assembly_matches_the_c_compiler() {
    if cli::on_wasm() {
        return;
    }
    assert_eq(module_blocks("ffi/sc_runtime.spc") + module_blocks("ffi/sc_sme.spc"), 0);
}

// ---- wasm ----

// The bodies of the code section of wasm object `o`: each body's instructions (past its locals) as a
// (start, end) pair in `o`; false when `o` is no wasm module.
fn wasm_bodies(o: &Vector<u8>, out: &mut Vector<(usize, usize)>) bool {
    if o.len() < 8 || le(o, 0, 4) != 0x6D736100 {
        return false;
    }
    let mut p: usize = 8;
    // Each step reads one section.
    while p < o.len() {
        let id = o[p];
        p += 1;
        let size = uleb_at(o, &mut p) as usize;
        let end = p + size;
        if id == 10 {
            let mut q = p;
            let n = uleb_at(o, &mut q);
            for _ in 0..n {
                let bsize = uleb_at(o, &mut q) as usize;
                let bend = q + bsize;
                let runs = uleb_at(o, &mut q);
                for _ in 0..runs {
                    let _ = uleb_at(o, &mut q);
                    q += 1;
                }
                out.push((q, bend));
                q = bend;
            }
        }
        p = end;
    }
    return true;
}

fn uleb_at(o: &Vector<u8>, p: &mut usize) u64 {
    let mut v: u64 = 0;
    let mut sh: u64 = 0;
    // At most 10 bytes.
    for _ in 0..10 {
        let c = o[*p];
        *p += 1;
        v |= (c & 0x7F) as u64 << sh;
        sh += 7;
        if (c & 0x80) == 0 {
            break;
        }
    }
    return v;
}

// The imports of wasm object `o`, one `module.name` per line.
fn wasm_imports(o: &Vector<u8>) String {
    let mut s = String::new();
    let mut p: usize = 8;
    while p < o.len() {
        let id = o[p];
        p += 1;
        let size = uleb_at(o, &mut p) as usize;
        let end = p + size;
        if id == 2 {
            let mut q = p;
            let n = uleb_at(o, &mut q);
            for _ in 0..n {
                for part in 0..2u32 {
                    let l = uleb_at(o, &mut q) as usize;
                    for k in 0..l {
                        s.push_byte(o[q + k]);
                    }
                    q += l;
                    s.push_byte(
                        if part == 0 {
                            b'.';
                        } else {
                            b'\n';
                        },
                    );
                }
                let kind = o[q];
                q += 1;
                if kind == 0 {
                    let _ = uleb_at(o, &mut q);
                } else if kind == 1 {
                    q += 1;
                    let fl = o[q];
                    q += 1;
                    let _ = uleb_at(o, &mut q);
                    if (fl & 1) != 0 {
                        let _ = uleb_at(o, &mut q);
                    }
                } else if kind == 2 {
                    let fl = o[q];
                    q += 1;
                    let _ = uleb_at(o, &mut q);
                    if (fl & 1) != 0 {
                        let _ = uleb_at(o, &mut q);
                    }
                } else {
                    q += 2;
                }
            }
        }
        p = end;
    }
    return s;
}

// The immediates of the sample of row `r` into `n`, and the text that names a symbol where the
// sample's text needs one (empty: the printed text).
fn wasm_sample(r: wt::Row, n: &mut wt::Ins, sym_text: &mut String) {
    sym_text.clear();
    switch r.imm {
        wt::K::BT => {
            n.a = 0x7F;
        },
        wt::K::LABEL | wt::K::LOCAL | wt::K::SEG | wt::K::SEGMEM => {
            n.a = 0;
        },
        wt::K::BRTABLE => {
            n.targets.push(0);
            n.targets.push(0);
            n.targets.push(0);
        },
        wt::K::FUNC => {
            sym_text.format_into("{} f", r.mn);
            n.wide = 1;
        },
        wt::K::GLOBAL => {
            sym_text.format_into("{} __stack_pointer", r.mn);
            n.wide = 1;
        },
        wt::K::CALLI => {
            sym_text.format_into("{} () -> ()", r.mn);
            n.wide = 3;
        },
        wt::K::MEM | wt::K::MEMLANE => {
            n.a = if r.al > 0 {
                r.al as i64 - 1;
            } else {
                0i64;
            };
            n.b = 300;
            n.lo = 1;
        },
        wt::K::I32 => {
            n.a = -123456;
        },
        wt::K::I64 => {
            n.a = -0x123456789A;
        },
        wt::K::F32 => {
            n.a = 0x40490FDB;
        },
        wt::K::F64 => {
            n.a = 0x3FB999999999999A;
        },
        wt::K::V128 => {
            n.lo = 0x0123456789ABCDEF;
            n.hi = 0xFEDCBA9876543210;
        },
        wt::K::SHUF => {
            n.lo = 0x0706050403020100;
            n.hi = 0x1F1E1D1C1B1A1918;
        },
        wt::K::LANE => {
            n.a = 1;
        },
        _ => {},
    };
}

// The sample text of every wasm row, one per line, as one function `f` of a module (the control rows
// in balanced structures inside a block), and our object of it.
fn wasm_samples(text: &mut String) u32 {
    let rows: []wt::Row = wt::ROWS;
    text.push_str(
        ".globaltype __stack_pointer, i32\n.functype f () -> ()\n.globl f\n.type f,@function\nf:\n.functype f () -> ()\n.local i32\nblock\n",
    );
    let mut lines: u32 = 0;
    for ri in 0..rows.len() {
        let r = rows[ri];
        if r.mn.starts_with("end") {
            continue;
        }
        let mut n = wt::Ins::new(ri as u32);
        let mut st = String::new();
        wasm_sample(r, &mut n, &mut st);
        let mut b0 = Vector::<u8>::new();
        let mut f = wt::Field { at: 0, wide: false };
        let mut f2 = wt::Field { at: 0, wide: false };
        if !wt::encode(&n, &mut b0, &mut f, &mut f2) {
            eprint("row {} '{}': the sample does not encode\n", ri, r.mn);
            assert(false, "every row encodes its sample");
        }
        let mut d = wt::Ins::new(0);
        let l0 = wt::decode(b0.as_slice(), 0, b0.len(), &mut d);
        let mut b2 = Vector::<u8>::new();
        if l0 as usize != b0.len() || !wt::encode(&d, &mut b2, &mut f, &mut f2) || b2.as_slice() != b0.as_slice() {
            eprint("row {} '{}': {} does not decode to itself\n", ri, r.mn, bhex(&b0).as_str());
            assert(false, "every encoding decodes to itself");
        }
        let mut s = String::new();
        wa::print_ins(&n, &mut s);
        if st.len() != 0 {
            s = st;
        }
        let mut b1 = Vector::<u8>::new();
        let mut fx = Vector::<wa::Fix>::new();
        let mut err = String::new();
        if !wa::assemble(s.as_str(), &mut b1, &mut fx, &mut err) || b1.as_slice() != b0.as_slice() {
            eprint(
                "row {} '{}': '{}' assembles to {} ({}), the row gives {}\n",
                ri,
                r.mn,
                s.as_str(),
                bhex(&b1).as_str(),
                err.as_str(),
                bhex(&b0).as_str(),
            );
            assert(false, "the text assembles to the row's bytes");
        }
        text.push_string(&s);
        text.push_byte(b'\n');
        if r.imm == wt::K::BT {
            text.push_str(
                if r.mn == "block" {
                    "end_block\n";
                } else if r.mn == "loop" {
                    "end_loop\n";
                } else {
                    "end_if\n";
                },
            );
        }
        if r.mn == "else" {
            // In an `if`: the line before is the `if`'s sample's end; open another.
            let cut = text.len() - 5;
            text.truncate(cut);
            text.push_str("if i32\nelse\nend_if\n");
        }
        lines += 1;
    }
    text.push_str("end_block\nend_function\n");
    return lines;
}

@test
fn wasm_rows_round_trip() {
    let mut text = String::new();
    assert(wasm_samples(&mut text) > 400, "the table's rows");
    let mut o = wo::WObj::new();
    let mut err = String::new();
    if !asmr::wasm_module(&mut o, text.as_str(), &mut err) {
        eprint("ours does not assemble the samples: {}\n", err.as_str());
        assert(false, "the samples assemble");
    }
    let mut ours = Vector::<u8>::new();
    wo::write(&o, &mut ours);
    let sdk = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    if sdk.len() == 0 || cli::on_wasm() {
        println("skipped: no WASI_SDK_PATH");
        return;
    }
    wasm_compare("the samples", &ours, text.as_str(), sdk.as_str());
}

// Assemble `text` with the wasi-sdk's clang and compare its function bodies and imports with object
// `ours`.
fn wasm_compare(what: str, ours: &Vector<u8>, text: str, sdk: str) {
    let dir = format("{}/asm_wasm_{}", cli::tmp_dir().as_str(), process::pid().unwrap_or(1));
    let _ = fs::mkdir_all(dir.as_str());
    let sp = format("{}/t.s", dir.as_str());
    let op = format("{}/t.o", dir.as_str());
    let f = stdio::fopen(sp.as_str(), "wb");
    unsafe stdio::fwrite(text.ptr(), 1, text.len(), f);
    unsafe stdio::fclose(f);
    let mut cmd = format(
        "\"{}/bin/clang\" --target=wasm32-wasip1 -msimd128 -mrelaxed-simd -mbulk-memory -mnontrapping-fptoint -c -Wa,--no-type-check \"{}\" -o \"{}\"",
        sdk,
        sp.as_str(),
        op.as_str(),
    );
    if cli::run_with(cmd.cstr(), null, null, null, "") != 0 {
        eprint("{}: the wasi-sdk's clang does not assemble {}\n", what, sp.as_str());
        assert(false, "the wasi-sdk's clang assembles it");
    }
    let theirs = read_bytes(op.as_str());
    let _ = fs::remove_all(dir.as_str());
    let mut ba = Vector::<(usize, usize)>::new();
    let mut bb = Vector::<(usize, usize)>::new();
    assert(wasm_bodies(ours, &mut ba) && wasm_bodies(&theirs, &mut bb), "both are wasm modules");
    assert_eq(ba.len(), bb.len());
    let mut bad: u32 = 0;
    for k in 0..ba.len() {
        let (a0, a1) = ba[k];
        let (b0, b1) = bb[k];
        let mut p = a0;
        let mut q = b0;
        // Each step compares one instruction.
        while p < a1 && q < b1 {
            let mut sa = String::new();
            let mut sb = String::new();
            let la = wa::disassemble(ours.as_slice(), p, a1, &mut sa) as usize;
            let lb = wa::disassemble(theirs.as_slice(), q, b1, &mut sb) as usize;
            let mut same = la != 0 && la == lb;
            for j in 0..la {
                same = same && ours[p + j] == theirs[q + j];
            }
            if !same {
                eprint("{}: body {}: ours '{}', the C compiler's '{}'\n", what, k, sa.as_str(), sb.as_str());
                bad += 1;
                if la == 0 || lb == 0 || bad > 30 {
                    break;
                }
            }
            p += la;
            q += lb;
        }
        if p != a1 || q != b1 {
            bad += 1;
        }
    }
    let ia = wasm_imports(ours);
    let ib = wasm_imports(&theirs);
    if ia.as_str() != ib.as_str() {
        eprint("{}: our imports\n{}the C compiler's\n{}", what, ia.as_str(), ib.as_str());
        bad += 1;
    }
    assert_eq(bad, 0);
}

// Every wasm module-level block of `path`: ours assembles it to the C compiler's code and imports.
fn wasm_blocks(path: str, sdk: str) {
    let src = cli::read_text(path);
    let s = src.as_str();
    let mut from: usize = 0;
    loop {
        let k = s.slice(from, s.len()).find("asm(M\"(");
        if k < 0 {
            break;
        }
        let st = from + k as usize + 7;
        let e = s.slice(st, s.len()).find(")\");");
        assert(e >= 0, "the block ends");
        let body = s.slice(st, st + e as usize);
        let mut o = wo::WObj::new();
        let mut err = String::new();
        if !asmr::wasm_module(&mut o, body, &mut err) {
            eprint("{}: ours does not assemble a block: {}\n", path, err.as_str());
            assert(false, "the block assembles");
        }
        let mut ours = Vector::<u8>::new();
        wo::write(&o, &mut ours);
        wasm_compare(path, &ours, body, sdk);
        from = st + e as usize;
    }
}

@test
fn wasm_module_assembly_matches_the_c_compiler() {
    let sdk = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    if sdk.len() == 0 || cli::on_wasm() {
        return;
    }
    wasm_blocks("std/rt/libc.spc", sdk.as_str());
    wasm_blocks("std/rt/libm.spc", sdk.as_str());
}

// The code the wasm generator emits for `CORPUS` and std: every instruction decodes to a table row and
// encodes back to its bytes.
@test
fn wasm_generated_code_round_trips() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("main.spc", CORPUS);
    let _ = p.run_raw(format("build --target=wasm \"{}/main.spc\"", p.dir()).as_str());
    let mut objs = Vector::<String>::new();
    obj_files(format("{}/build/debug/raw", p.dir()).as_str(), &mut objs);
    assert(objs.len() > 5, "the build's objects");
    let mut insts: u64 = 0;
    let mut bad: u32 = 0;
    for i in 0..objs.len() {
        let o = read_bytes(objs[i].as_str());
        let mut bodies = Vector::<(usize, usize)>::new();
        if !wasm_bodies(&o, &mut bodies) {
            continue;
        }
        for k in 0..bodies.len() {
            let (a0, a1) = bodies[k];
            let mut p2 = a0;
            while p2 < a1 {
                let mut n = wt::Ins::new(0);
                let l = wt::decode(o.as_slice(), p2, a1, &mut n) as usize;
                insts += 1;
                if l == 0 {
                    eprint("{} body {} at {}: 0x{} decodes to no row\n", objs[i].as_str(), k, p2 - a0, hex(o[p2]));
                    bad += 1;
                    break;
                }
                p2 += l;
            }
        }
    }
    assert(insts > 10000, "the corpus's code");
    assert_eq(bad, 0);
}

// ---- Intrinsics ----

// Every arm64 intrinsic row, its constant arguments 1, assembles to the C compiler's words.
@test
fn a64_intrinsics_match_the_c_compiler() {
    let imm: [i64; 8] = [1; 8];
    let known: [bool; 8] = [true; 8];
    let mut text = String::new();
    let mut words = Vector::<u32>::new();
    let mut bad: u32 = 0;
    let rows: [](str, str) = a64i::ROWS;
    for i in 0..rows.len() {
        let mut t = String::new();
        assert(intrin::expand(rows[i].1, imm[0..8], known[0..8], &mut t), rows[i].0);
        let mut rels = Vector::<asmr::InlRel>::new();
        let mut e = String::new();
        let n0 = words.len();
        if !asmr::Asm::inline_a64(t.as_str(), false, &mut words, &mut rels, &mut e) {
            eprint("{}: '{}': {}\n", rows[i].0, t.as_str(), e.as_str());
            bad += 1;
            words.truncate(n0);
            continue;
        }
        text.push_string(&t);
        text.push_str("\n");
    }
    assert_eq(bad, 0);
    a64_oracle(&text, &words);
}

// Every wasm intrinsic row, its constant arguments 1, as a function of its signature: ours assembles
// it to the C compiler's bytes.
@test
fn wasm_intrinsics_match_the_c_compiler() {
    let imm: [i64; 8] = [1; 8];
    let known: [bool; 8] = [true; 8];
    let rows: [](str, str) = wasmi::ROWS;
    let sigs: []str = wasmi::SIGS;
    let mut text = String::new();
    for i in 0..rows.len() {
        let mut t = String::new();
        assert(intrin::expand(rows[i].1, imm[0..8], known[0..8], &mut t), rows[i].0);
        text.format_into(
            ".functype f{} {}\n.globl f{}\n.type f{},@function\nf{}:\n.functype f{} {}\n{}\nend_function\n",
            i,
            sigs[i],
            i,
            i,
            i,
            i,
            sigs[i],
            t.as_str(),
        );
    }
    let mut o = wo::WObj::new();
    let mut err = String::new();
    if !asmr::wasm_module(&mut o, text.as_str(), &mut err) {
        eprint("ours does not assemble the intrinsics: {}\n", err.as_str());
        assert(false, "the intrinsics assemble");
    }
    let mut ours = Vector::<u8>::new();
    wo::write(&o, &mut ours);
    let sdk = stdlib::get_env("WASI_SDK_PATH").unwrap_or(String::new());
    if sdk.len() == 0 || cli::on_wasm() {
        println("skipped: no WASI_SDK_PATH");
        return;
    }
    wasm_compare("the intrinsics", &ours, text.as_str(), sdk.as_str());
}

// Every x86-64 intrinsic row, its constant arguments 1, assembles to the C compiler's bytes.
@test
fn x64_intrinsics_match_the_c_compiler() {
    let imm: [i64; 8] = [1; 8];
    let known: [bool; 8] = [true; 8];
    let mut text = String::new();
    let mut bytes = Vector::<u8>::new();
    let mut ends = Vector::<u32>::new();
    let mut bad: u32 = 0;
    let rows: [](str, str) = x64i::ROWS;
    for i in 0..rows.len() {
        let mut t = String::new();
        assert(intrin::expand(rows[i].1, imm[0..8], known[0..8], &mut t), rows[i].0);
        let mut lines = t.split("\n");
        loop {
            let line = switch lines.next() {
                Some(l) => l,
                None => {
                    break;
                },
            };
            let mut rels = Vector::<asmr::InlRel>::new();
            let mut e = String::new();
            let n0 = bytes.len();
            if !asmr::Asm::inline_x64(line, &mut bytes, &mut rels, &mut e) {
                eprint("{}: '{}': {}\n", rows[i].0, line, e.as_str());
                bad += 1;
                bytes.truncate(n0);
                continue;
            }
            text.push_str(line);
            text.push_str("\n");
            ends.push(bytes.len() as u32);
        }
    }
    assert_eq(bad, 0);
    x64_oracle(&text, &bytes, &ends);
}
