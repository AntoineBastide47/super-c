// The C toolchain probe table: what the C compiler and linker accept under a build's target and flags.
// Each probe compiles, links or assembles a short C snippet as an argv child of the compiler driver (no
// shell) with the build's own compile flags; exit codes, output files and assembly text decide, never
// version text. The results of one profile directory live in one record, `<pdir>/.probes`: its header
// holds a hash of the inputs (compiler path and mtime, target, arch, compile and link flags) and the
// compiler version line, then one line per measured probe. A probe runs only when a build needs its
// result and the record does not hold it, beside the compiler version probe (`Probes::start`).
import driver_shim as shim;
import module::loader as loader;
import driver::util as *;
import build_system::objcache as *;
import ast::parser as par;

/// The result of a probe that does not apply to the target or the instruction set.
pub const NOT_APPLICABLE: str<'static> = "not applicable";

// The most spellings one probe tries.
const MAX_FORMS: usize = 3;

/// One probe of the table. Every field is a literal: the release compiler that bootstraps this source
/// cannot materialize a table entry that needs evaluation and holds an empty string (fixed in
/// `Interp::str_materialize`; typed fields can replace the strings once a release carries the fix).
pub struct Probe {
    pub id: str<'static>,
    /// "compile" (`-c` to an object), "link" (compile and link with the build's link flags), "asm" (`-S`
    /// to assembly text) or "lto" (the engine's ThinLTO procedure, `CcStream::lto_probe`).
    pub step: str<'static>,
    /// What the result says: "accept" ("accepted" or "rejected"), "form" (the first spelling of `forms`
    /// the compiler accepts, else "rejected"), "cas16" (`cas16_kind`, else "rejected") or "lto" ("thin
    /// <linker cache form>" or "auto: <reason>").
    pub kind: str<'static>,
    pub flags: str<'static>, // extra compiler flags, whitespace-split
    pub forms: str<'static>, // the spellings in preference order, '|'-separated, each in place of `@` in `src`
    pub src: str<'static>,
    pub archs: str<'static>, // the instruction sets it applies to (`ARCH_NAMES`), space-separated; empty: all
    pub targets: str<'static>, // the platforms it applies to (`PLATFORM_NAMES`); empty: all
}

// The probe table. A probe's index is its bit in a `need` mask.
const PROBES: [Probe; 16] = [
    Probe {
        id: "add-overflow",
        step: "compile",
        kind: "accept",
        flags: "",
        forms: "",
        src: "int f(int a, int b, long long *m) {\n    int s;\n    unsigned u;\n    return __builtin_add_overflow(a, b, &s) | __builtin_sub_overflow(a, b, &u) | __builtin_mul_overflow(a, b, m);\n}\n",
        archs: "",
        targets: "",
    },
    Probe {
        id: "fp-contract-off",
        step: "compile",
        kind: "accept",
        flags: "-ffp-contract=off",
        forms: "",
        src: "double f(double a, double b, double c) {\n    return a * b + c;\n}\n",
        archs: "",
        targets: "",
    },
    // Clang ignores an unknown `target` feature, so the function calls an intrinsic that fails to inline
    // unless the spelling really enables the feature.
    Probe {
        id: "target-attr-x86_64",
        step: "compile",
        kind: "form",
        flags: "",
        forms: "avx2|arch=haswell",
        src: "#include <immintrin.h>\n__attribute__((target(\"@\"))) __m256i f(__m256i a, __m256i b) {\n    return _mm256_add_epi32(a, b);\n}\n",
        archs: "x86_64",
        targets: "",
    },
    Probe {
        id: "target-attr-aarch64",
        step: "compile",
        kind: "form",
        flags: "",
        forms: "+i8mm|arch=armv8.6-a|i8mm",
        src: "#include <arm_neon.h>\n__attribute__((target(\"@\"))) int32x4_t f(int32x4_t a, int8x16_t b, int8x16_t c) {\n    return vmmlaq_s32(a, b, c);\n}\n",
        archs: "aarch64",
        targets: "",
    },
    Probe {
        id: "march-x86-64-v2",
        step: "compile",
        kind: "accept",
        flags: "-march=x86-64-v2",
        forms: "",
        src: "int f(int x) {\n    return x + 1;\n}\n",
        archs: "x86_64",
        targets: "",
    },
    Probe {
        id: "march-x86-64-v3",
        step: "compile",
        kind: "accept",
        flags: "-march=x86-64-v3",
        forms: "",
        src: "int f(int x) {\n    return x + 1;\n}\n",
        archs: "x86_64",
        targets: "",
    },
    Probe {
        id: "march-x86-64-v4",
        step: "compile",
        kind: "accept",
        flags: "-march=x86-64-v4",
        forms: "",
        src: "int f(int x) {\n    return x + 1;\n}\n",
        archs: "x86_64",
        targets: "",
    },
    Probe {
        id: "wasm-simd128",
        step: "compile",
        kind: "accept",
        flags: "-msimd128",
        forms: "",
        src: "#include <wasm_simd128.h>\nv128_t f(v128_t a, v128_t b) {\n    return wasm_i32x4_add(a, b);\n}\n",
        archs: "wasm32",
        targets: "",
    },
    Probe {
        id: "wasm-relaxed-simd",
        step: "compile",
        kind: "accept",
        flags: "-msimd128 -mrelaxed-simd",
        forms: "",
        src: "#include <wasm_simd128.h>\nv128_t f(v128_t a, v128_t b, v128_t m) {\n    return wasm_i32x4_relaxed_laneselect(a, b, m);\n}\n",
        archs: "wasm32",
        targets: "",
    },
    // GCC sends this to libatomic even with `-mcx16`, and libatomic can fall back to a lock.
    Probe {
        id: "cas16",
        step: "asm",
        kind: "cas16",
        flags: "",
        forms: "",
        src: "unsigned __int128 probe_cas(unsigned __int128 *p, unsigned __int128 e, unsigned __int128 d) {\n    __atomic_compare_exchange_n(p, &e, d, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);\n    return e;\n}\n",
        archs: "",
        targets: "",
    },
    Probe {
        id: "thread-local",
        step: "compile",
        kind: "accept",
        flags: "",
        forms: "",
        src: "_Thread_local int t;\nint f(void) {\n    return t;\n}\n",
        archs: "",
        targets: "",
    },
    Probe {
        id: "cpuid-count",
        step: "compile",
        kind: "accept",
        flags: "",
        forms: "",
        src: "#include <cpuid.h>\nint f(unsigned *r) {\n    return __get_cpuid_count(7, 0, &r[0], &r[1], &r[2], &r[3]);\n}\n",
        archs: "x86_64",
        targets: "",
    },
    Probe {
        id: "getauxval",
        step: "link",
        kind: "accept",
        flags: "",
        forms: "",
        src: "#include <sys/auxv.h>\nint main(void) {\n    return getauxval(AT_HWCAP) == 0;\n}\n",
        archs: "aarch64",
        targets: "linux android",
    },
    Probe {
        id: "at-hwcap2",
        step: "compile",
        kind: "accept",
        flags: "",
        forms: "AT_HWCAP2",
        src: "#include <sys/auxv.h>\nunsigned long f(void) {\n    return getauxval(@);\n}\n",
        archs: "aarch64",
        targets: "linux android",
    },
    Probe {
        id: "at-hwcap3",
        step: "compile",
        kind: "accept",
        flags: "",
        forms: "AT_HWCAP3",
        src: "#include <sys/auxv.h>\nunsigned long f(void) {\n    return getauxval(@);\n}\n",
        archs: "aarch64",
        targets: "linux android",
    },
    Probe { id: "thin-lto", step: "lto", kind: "lto", flags: "", forms: "", src: "", archs: "", targets: "" },
];

/// The probe table.
pub const fn table() Slice<'static, Probe> {
    return PROBES;
}

/// The ThinLTO probe's index.
pub const LTO: usize = 15;

/// The `need` mask of every probe.
pub const ALL: u64 = (1u64 << 16) - 1;

// Field `idx` of `s` split at byte `sep`; the last field runs to the end, and a missing one is empty.
fn nth(s: str, sep: u8, idx: usize) str {
    let mut a: usize = 0;
    let mut k: usize = 0;
    for i in 0..s.len() + 1 {
        if i == s.len() || s[i] == sep {
            if k == idx {
                return s.slice(a, i);
            }
            k += 1;
            a = i + 1;
        }
    }
    return s.slice(0, 0);
}

// Name list `names` (space-separated) is empty or holds `name`.
fn names_hold(names: str, name: str) bool {
    if names.len() == 0 {
        return true;
    }
    for k in 0..names.len() {
        let w = nth(names, b' ', k);
        if w.len() == 0 {
            return false;
        }
        if w == name {
            return true;
        }
    }
    return false;
}

// The spellings probe `pr` tries: one for a probe without forms.
fn form_count(pr: &Probe) usize {
    let mut n: usize = 1;
    for i in 0..pr.forms.len() {
        if pr.forms[i] == b'|' {
            n += 1;
        }
    }
    return n;
}

// An instruction mnemonic as the assembler text spells one: after a tab or a space.
fn has_insn(s: str, name: str) bool {
    let mut t = String::from_str("\t");
    t.push_str(name);
    let mut sp = String::from_str(" ");
    sp.push_str(name);
    return s.contains(t.as_str()) || s.contains(sp.as_str());
}

/// The 16-byte compare-exchange in assembly `s`: a lock-free instruction inline (x86-64 `cmpxchg16b`,
/// AArch64 LSE `casp*` or an `ldxp`/`stxp` loop), a call to libgcc's lock-free outline atomics
/// (`__aarch64_cas16_*`), or a call to libatomic, which may take a lock.
pub fn cas16_kind(s: str) str<'static> {
    let llsc = (has_insn(s, "ldxp") || has_insn(s, "ldaxp")) && (has_insn(s, "stxp") || has_insn(s, "stlxp"));
    if has_insn(s, "cmpxchg16b") || has_insn(s, "casp") || llsc {
        return "inline";
    }
    if s.contains("__aarch64_cas16") {
        return "outline call";
    }
    if s.contains("__atomic_compare_exchange") || s.contains("__sync_val_compare_and_swap") {
        return "library call";
    }
    return "unknown";
}

/// The probe results of one profile directory: the record's, and the ones this process measured.
pub struct Probes {
    pub path: String, // <pdir>/.probes
    pub dir: String, // <pdir>/.probe: the sources, outputs and logs of the running probes
    pub key: String, // hex hash of the record's inputs other than the compiler version
    pub ver: String, // the compiler version line the results belong to
    pub res: Vector<String>, // per probe; empty = not measured
    pub aux: Vector<String>, // per probe: what else must hold for the result (the ThinLTO linker line)
    pub pids: Vector<i64>, // per probe and spelling: the running child, -1 = none
    pub running: Vector<bool>, // per probe: its children were started
    pub argv: Vector<String>, // the compiler driver words, then the compile flags
    pub ldflags: String, // the link flags of a "link" probe
    pub need: u64, // the probes the build needs, one bit per table index
    pub dirty: bool, // the record must be written
    pub used: String, // `id=result;` per result the build used: part of every C command fingerprint
}

extend Probes {
    /// Read the record of `pdir` and start the needed probes (`need` bits, the "lto" step excepted) it does not
    /// hold. `key` holds the inputs other than the compiler version; `argv` the compiler driver words and
    /// the compile flags (no `-c`); `ldflags` the link flags. The compiler version is not known yet, so
    /// `settle` checks the record against it.
    pub fn start(pdir: str, key: str, argv: Vector<String>, ldflags: str, target: i32, arch: i32, need: u64) Probes {
        let mut p = Probes {
            path: loader::join2(pdir, ".probes"),
            dir: loader::join2(pdir, ".probe"),
            key: String::new(),
            ver: String::new(),
            res: Vector::<String>::with_capacity(table().len()),
            aux: Vector::<String>::with_capacity(table().len()),
            pids: Vector::<i64>::with_capacity(table().len() * MAX_FORMS),
            running: Vector::<bool>::with_capacity(table().len()),
            argv: argv,
            ldflags: String::from_str(ldflags),
            need: need,
            dirty: false,
            used: String::new(),
        };
        hex64(fnv_cont(FNV_BASIS, key), &mut p.key);
        for i in 0..table().len() {
            let pr = &table()[i];
            let applies = names_hold(pr.archs, par::axis_names(true)[arch as usize]) && names_hold(
                pr.targets,
                par::axis_names(false)[target as usize],
            );
            p.res.push(
                if applies {
                    String::new();
                } else {
                    String::from_str(NOT_APPLICABLE);
                },
            );
            p.aux.push(String::new());
            p.running.push(false);
            for _ in 0..MAX_FORMS {
                p.pids.push(-1);
            }
        }
        let old = loader::read_file(p.path.as_str());
        if !old.is_none() {
            let ob = old.unwrap();
            let s = ob.as_str();
            let head = nth(s, b'\n', 0);
            if nth(head, b'\t', 0) == "sc-probes 1" && nth(head, b'\t', 1) == p.key.as_str() {
                p.ver.push_str(nth(head, b'\t', 2));
                let mut a: usize = head.len() + 1;
                while a < s.len() {
                    let line = nth(s.slice(a, s.len()), b'\n', 0);
                    a += line.len() + 1;
                    for i in 0..table().len() {
                        if nth(line, b'\t', 0) == table()[i].id && p.res.at(i).as_str() != NOT_APPLICABLE {
                            p.res[i] = String::from_str(nth(line, b'\t', 1));
                            let at = table()[i].id.len() + 1 + p.res.at(i).len() + 1;
                            if at < line.len() {
                                p.aux[i] = String::from_str(line.slice(at, line.len()));
                            }
                        }
                    }
                }
            }
        }
        p.spawn();
        return p;
    }

    // Start every needed probe with no result that is not running yet: one child per spelling, all at once.
    fn spawn(self: &mut Self) {
        for i in 0..table().len() {
            let pr = &table()[i];
            if (self.need >> i as u64 & 1) == 0 || self.res.at(i).len() != 0 || self.running[i] || pr.step == "lto" {
                continue;
            }
            mkdir_p(self.dir.as_str());
            self.running[i] = true;
            for k in 0..form_count(pr) {
                let form = nth(pr.forms, b'|', k);
                let mut text = String::new();
                for c in 0..pr.src.len() {
                    if pr.src[c] == b'@' {
                        text.push_str(form);
                    } else {
                        text.push_byte(pr.src[c]);
                    }
                }
                let stem = loader::join2(self.dir.as_str(), format("{}.{}", i, k).as_str());
                let mut src = stem.clone();
                src.push_str(".c");
                if !write_file(src.as_str(), text.as_str()) {
                    continue; // no child: this spelling counts as rejected
                }
                let mut args = clone_args(&self.argv);
                split_args(&mut args, pr.flags);
                if pr.step == "compile" {
                    push_arg(&mut args, "-c");
                } else if pr.step == "asm" {
                    // A `-flto` in the flags would write compiler IR in place of assembly.
                    push_arg(&mut args, "-fno-lto");
                    push_arg(&mut args, "-S");
                }
                args.push(src);
                push_arg(&mut args, "-o");
                args.push(out_path(&stem, pr.step));
                if pr.step == "link" {
                    split_args(&mut args, self.ldflags.as_str());
                }
                let mut log = stem.clone();
                log.push_str(".log");
                self.pids[i * MAX_FORMS + k] = spawn_args(&mut args, log.cstr());
            }
        }
    }

    /// Settle the needed results once the compiler version `ver` is known: a record of another compiler
    /// version holds no result, so its results go and those probes run now; then collect every running
    /// probe. Afterwards each needed probe but the "lto" step has a result.
    pub fn settle(self: &mut Self, ver: &String) {
        if self.ver.as_str() != ver.as_str() {
            for i in 0..table().len() {
                if self.res.at(i).len() != 0 && self.res.at(i).as_str() != NOT_APPLICABLE && !self.running[i] {
                    self.res[i] = String::new();
                    self.aux[i] = String::new();
                    self.dirty = true;
                }
            }
            self.ver = ver.clone();
            self.spawn();
        }
        let mut ran = false;
        for i in 0..table().len() {
            if !self.running[i] {
                continue;
            }
            ran = true;
            self.running[i] = false;
            let pr = &table()[i];
            let mut first: isize = -1; // the first spelling that compiled
            for k in 0..form_count(pr) {
                let pid = self.pids[i * MAX_FORMS + k];
                self.pids[i * MAX_FORMS + k] = -1;
                let mut code: i32 = 1;
                if pid < 0 || unsafe shim::sc_waitpid(pid, &mut code) != 0 {
                    code = 1;
                }
                let stem = loader::join2(self.dir.as_str(), format("{}.{}", i, k).as_str());
                let mut out = out_path(&stem, pr.step);
                if code == 0 && unsafe shim::sc_mtime(out.cstr()) != 0 && first < 0 {
                    first = k as isize;
                }
            }
            let mut r = String::new();
            if first < 0 {
                r.push_str("rejected");
            } else if pr.kind == "form" {
                r.push_str(nth(pr.forms, b'|', first as usize));
            } else if pr.kind == "cas16" {
                let stem = loader::join2(self.dir.as_str(), format("{}.0", i).as_str());
                let text = loader::read_file(out_path(&stem, pr.step).as_str());
                r.push_str(
                    if text.is_none() {
                        "unknown";
                    } else {
                        cas16_kind(text.unwrap().as_str());
                    },
                );
            } else {
                r.push_str("accepted");
            }
            self.res[i] = r;
            self.dirty = true;
        }
        if ran {
            let mut d = self.dir.clone();
            let _ = unsafe shim::sc_rm_rf(d.cstr());
        }
    }

    /// Reap the running probes unused and remove their files: the error path of a build.
    pub fn abandon(self: &mut Self) {
        let mut ran = false;
        for i in 0..self.pids.len() {
            if self.pids[i] >= 0 {
                let mut code: i32 = 0;
                let _ = unsafe shim::sc_waitpid(self.pids[i], &mut code);
                self.pids[i] = -1;
                ran = true;
            }
        }
        if ran {
            let mut d = self.dir.clone();
            let _ = unsafe shim::sc_rm_rf(d.cstr());
        }
    }

    /// Record `res` (and `aux`, what else must hold for it) as probe `i`'s result.
    pub fn set(self: &mut Self, i: usize, res: str, aux: str) {
        self.res[i] = String::from_str(res);
        self.aux[i] = String::from_str(aux);
        self.dirty = true;
    }

    /// The build uses probe `i`'s result: it joins `used`.
    pub fn mark_used(self: &mut Self, i: usize) {
        self.used.push_str(table()[i].id);
        self.used.push_byte(b'=');
        self.used.push_string(self.res.at(i));
        self.used.push_byte(b';');
    }

    /// Write the record when a result changed. A failed write only makes a later build probe again.
    pub fn save(self: &Self) {
        if !self.dirty {
            return;
        }
        let mut rec = String::from_str("sc-probes 1\t");
        rec.push_string(&self.key);
        rec.push_byte(b'\t');
        rec.push_string(&self.ver);
        rec.push_byte(b'\n');
        for i in 0..table().len() {
            if self.res.at(i).len() == 0 {
                continue;
            }
            rec.push_str(table()[i].id);
            rec.push_byte(b'\t');
            rec.push_string(self.res.at(i));
            if self.aux.at(i).len() != 0 {
                rec.push_byte(b'\t');
                rec.push_string(self.aux.at(i));
            }
            rec.push_byte(b'\n');
        }
        let _ = write_file_atomic(self.path.as_str(), rec.as_str());
    }
}

// The output file of a probe step for source stem `stem`.
fn out_path(stem: &String, step: str) String {
    let mut out = stem.clone();
    out.push_str(
        if step == "asm" {
            ".s";
        } else if step == "link" {
            ".out";
        } else {
            ".o";
        },
    );
    return out;
}
