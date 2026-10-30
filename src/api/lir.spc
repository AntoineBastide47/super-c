// LIR for tools: the machine-level IR every native backend starts from, as a program a tool reads, builds,
// checks, evaluates, compiles to an object and loads. The text form (`text`, `parse`) is the exchange form
// and the simplest way to build code: a tool writes functions as text, parses them, verifies them, and runs
// them. The schema follows the compiler version: a program's text from one version may not parse in another.
import api::errors as *;
import lir::ir as lir;
import lir::parse as lparse;
import lir::print as lprint;
import lir::verify as lverify;
import lir::eval as leval;
import target::native as native;
import target::table as tgt;
import module::loader as loader;
import driver::script as script;
import driver::test as dtest;
import ir::cpu_features as cf;
import std::platform::fs;
import std::platform::dylib;
import std::platform::process;
import link::link as lk;
import build_system::manifest as bman;

/// A LIR program: its symbols, data and function bodies.
pub struct Program {
    p: lir::Package,
}

/// How an evaluation ended: normally with the function's result word, or with a trap (a panic, an
/// out-of-bounds or freed access, a budget) and its message.
pub struct Evaluation {
    pub value: u64,
    pub trapped: bool,
    pub message: String,
}

extend Program {
    /// An empty program for a data model with `ptr_bytes`-byte pointers (8 on 64-bit targets).
    pub fn new(ptr_bytes: u32) Program {
        return Program { p: lir::Package::new(ptr_bytes) };
    }

    /// The program the LIR text form `text` spells; `ParseFailed` with the parser's message when it spells
    /// none.
    pub fn parse(text: str) Result<Program, ApiError> {
        let mut err = String::new();
        return switch lparse::parse(text, &mut err) {
            Some(p) => Ok(Program { p: p }),
            None => Err(ApiError::new(Code::ParseFailed, &err)),
        };
    }

    /// The program in the LIR text form.
    pub fn text(self: &Self) String {
        let mut out = String::new();
        lprint::print_package(&self.p, &mut out);
        return out;
    }

    /// The names of the functions the program defines, in symbol order.
    pub fn functions(self: &Self) Vector<String> {
        let mut out = Vector::<String>::new();
        for i in 0..self.p.syms.len() {
            let y = self.p.syms[i];
            if y.kind == lir::SK_FUNC && y.def != lir::NONE {
                out.push(String::from_str(self.p.spell(y.name)));
            }
        }
        return out;
    }

    /// The text form of function `name`, or None when the program defines no such function.
    pub fn function_text(self: &Self, name: str) Option<String> {
        let s = self.p.find_symbol(name);
        if s == lir::NONE || self.p.syms[s as usize].kind != lir::SK_FUNC || self.p.syms[s as usize].def == lir::NONE {
            return None;
        }
        let mut out = String::new();
        lprint::print_body(&self.p, name, &self.p.bodies[self.p.syms[s as usize].def as usize], &mut out);
        return Some(out);
    }

    /// Check every function body: SSA form, types, block parameters, and every call against its callee's
    /// signature. `VerificationFailed` with the verifier's message for the first body that breaks a rule.
    pub fn verify(self: &Self) Result<Unit, ApiError> {
        let mut v = lverify::Verifier::new();
        for i in 0..self.p.syms.len() {
            let y = self.p.syms[i];
            if y.kind != lir::SK_FUNC || y.def == lir::NONE {
                continue;
            }
            let name = self.p.spell(y.name);
            let b = &self.p.bodies[y.def as usize];
            if !v.check(&self.p, name, b) || !v.check_calls(&self.p, name, b) {
                return Err(ApiError::new(Code::VerificationFailed, &v.err));
            }
        }
        return Ok(Unit {});
    }

    /// Move every symbol, data definition and body of `other` into this program; a name both define keeps
    /// this program's definition. `InvalidArgument` when the data models differ.
    pub fn absorb(self: &mut Self, other: &Program) Result<Unit, ApiError> {
        if !self.p.absorb(&other.p) {
            return Err(ApiError::new(Code::InvalidArgument, "the programs have different pointer sizes"));
        }
        return Ok(Unit {});
    }

    // The program of package `p`, which it takes; `take_package` gives it back and leaves the program empty.
    pub(package) fn of_package(p: lir::Package) Program {
        return Program { p: p };
    }

    pub(package) fn take_package(self: &mut Self) lir::Package {
        let pb = self.p.ptr_bytes;
        return replace(&mut self.p, lir::Package::new(pb));
    }

    // The package itself, to read.
    pub(package) fn raw(self: &Self) &lir::Package {
        return &self.p;
    }

    // The package itself, to build in with the calls the lowering makes (`lir::ir::Package::add_symbol`,
    // `Body::new`, `define`); `verify` afterwards.
    pub(package) fn raw_mut(self: &mut Self) &mut lir::Package {
        return &mut self.p;
    }

    /// Run function `name` from the program's initial memory with one word per argument, under the
    /// evaluator's budgets (steps, memory, call depth). A call of an extern function the evaluator does not
    /// model traps. `InvalidArgument` when the program defines no function `name`.
    pub fn evaluate(self: &Self, name: str, args: Slice<u64>) Result<Evaluation, ApiError> {
        let s = self.p.find_symbol(name);
        if s == lir::NONE || self.p.syms[s as usize].def == lir::NONE {
            return Err(ApiError::new(Code::InvalidArgument, "the program defines no such function"));
        }
        let mut e = leval::Eval::new(&self.p);
        let o = e.run(s, args);
        let mut msg = String::new();
        if o.kind != leval::EV_OK {
            leval::outcome_text(&self.p, &o, &mut msg);
        }
        return Ok(Evaluation { value: o.value, trapped: o.kind != leval::EV_OK, message: msg });
    }

    /// The object file of every function and data definition for operating system `os` (`macos`, `linux`,
    /// `windows`, `wasm`) and instruction set `isa` (`aarch64`, `x86_64`, `wasm32`): Mach-O, ELF, COFF or a
    /// relocatable wasm module. `UnsupportedCapability` for a target without a native backend;
    /// `InvalidArgument` when the program's pointer size is not the target's; `VerificationFailed` with the
    /// backend's reason for a body it does not compile.
    pub fn object(self: &Self, os: str, isa: str) Result<Vector<u8>, ApiError> {
        let o = tgt::axis_index(os, false);
        let i = tgt::axis_index(isa, true);
        if o < 0 || i < 0 || !native::supported(o, i) {
            return Err(ApiError::new(Code::UnsupportedCapability, "no native backend compiles for this target"));
        }
        if self.p.ptr_bytes != tgt::isa(i).ptr_bytes as u32 {
            return Err(ApiError::new(Code::InvalidArgument, "the program's pointer size is not the target's"));
        }
        return self.object_for(o, i);
    }

    fn object_for(self: &Self, os: i32, isa: i32) Result<Vector<u8>, ApiError> {
        let mut funcs = Vector::<u32>::new();
        let mut datas = Vector::<u32>::new();
        for k in 0..self.p.syms.len() {
            let y = self.p.syms[k];
            if y.def == lir::NONE {
                continue;
            }
            if y.kind == lir::SK_FUNC {
                funcs.push(k as u32);
            } else {
                datas.push(k as u32);
            }
        }
        let mut out = Vector::<u8>::new();
        let mut err = String::new();
        if !native::object(&self.p, os, isa, &funcs, &datas, "", &mut out, &mut err) {
            return Err(ApiError::new(Code::VerificationFailed, &err));
        }
        return Ok(out);
    }

    /// Compile the program for the host, link it into a shared library with the compiler's own linker and load
    /// it into this process; its global functions are then callable through `Library::symbol`. An extern
    /// function the program calls resolves against the system's C library.
    pub fn load(self: &Self) Result<Library, ApiError> {
        let obj = self.object_for(tgt::host_os(), tgt::host_isa())?;
        let base = switch fs::temp_dir() {
            Ok(t) => t,
            Err(e) => {
                return Err(ApiError::io(e, ""));
            },
        };
        // One directory per load: the process id and a counter name it.
        unsafe LOADS = unsafe LOADS + 1;
        let dir = format("{}/superc_lir_{}_{}", base.as_str(), process::pid().unwrap_or(0), unsafe LOADS);
        let _ = fs::remove_all(&dir);
        if let Err(e) = fs::mkdir_all(&dir) {
            return Err(ApiError::io(e, &dir));
        }
        let op = format("{}/program.o", dir.as_str());
        let lib = format("{}/{}", dir.as_str(), shared_name());
        if let Err(e) = write_bytes(&op, &obj) {
            let _ = fs::remove_all(&dir);
            return Err(ApiError::io(e, &op));
        }
        let mut args = Vector::<String>::new();
        args.push(String::from_str("-shared"));
        args.push(String::from_str("-o"));
        args.push(lib.clone());
        args.push(op);
        let mut why = String::new();
        if lk::link_args(tgt::host_os(), tgt::host_isa(), &args, false, 1, &mut why) != lk::LINKED {
            let _ = fs::remove_all(&dir);
            return Err(
                ApiError::new(Code::VerificationFailed, format("the program does not link: {}", why.as_str()).as_str()),
            );
        }
        return switch unsafe dylib::open(&lib) {
            Ok(l) => Ok(Library { lib: Some(l), dir: dir }),
            Err(e) => {
                let _ = fs::remove_all(&dir);
                Err(ApiError::io(e, &lib))
            },
        };
    }
}

/// The LIR of program `path` (a script: one file and its imports), std read from `std_dir`: the program the
/// compiler builds for the host, every function and data definition the program reaches, lowered and checked
/// as `SC_LIR=1` lowers them. The emitted C goes to a scratch directory the call removes. `SemanticFailed` when
/// the program does not compile.
pub fn of_program(path: str, std_dir: str) Result<Program, ApiError> {
    let base = switch fs::temp_dir() {
        Ok(t) => t,
        Err(e) => {
            return Err(ApiError::io(e, ""));
        },
    };
    unsafe LOADS = unsafe LOADS + 1;
    let out_dir = format("{}/superc_lirp_{}_{}", base.as_str(), process::pid().unwrap_or(0), unsafe LOADS);
    let mut text = String::new();
    let topts = dtest::TestOpts {};
    let os = tgt::host_os();
    let isa = tgt::host_isa();
    let rc = script::run_script(
        path,
        std_dir,
        0,
        0,
        &topts,
        "",
        os,
        isa,
        cf::close(tgt::baseline(os, isa)),
        0,
        "",
        false,
        false,
        1,
        &out_dir,
        "",
        "debug",
        bman::OPT_NONE,
        0,
        0,
        &mut text,
    );
    let _ = fs::remove_all(&out_dir);
    if rc != 0 || text.len() == 0 {
        return Err(ApiError::at(Code::SemanticFailed, "the program does not compile", path, 0, 0));
    }
    return Program::parse(&text);
}

// Write `bytes` to a new file `path`.
fn write_bytes(path: str, bytes: Slice<u8>) Result<Unit, IoError> {
    let mut f = fs::open(path, fs::OpenOptions { write: true, create: true, truncate: true, mode: 0o644 })?;
    f.write_all(bytes)?;
    return f.close();
}

// Loads made by this process, for the directory names.
static mut LOADS: u64 = 0;

// The host's file name of a shared library.
fn shared_name() str<'static> {
    return switch PLATFORM {
        Windows => "program.dll",
        MacOS | IOS => "program.dylib",
        _ => "program.so",
    };
}

/// A loaded program. Dropping it unloads it and removes its files: every function pointer taken from it
/// dangles after.
pub struct Library {
    lib: Option<dylib::Library>,
    dir: String,
}

extend Library {
    /// The address of global symbol `name`: a function to cast to its signature's `fn` type, or data.
    pub unsafe fn symbol(self: &Self, name: str) Result<*mut void, ApiError> {
        return switch &self.lib {
            Some(l) => switch unsafe l.symbol(name) {
                Ok(a) => Ok(a),
                Err(e) => Err(ApiError::io(e, name)),
            },
            None => Err(ApiError::new(Code::Internal, "the library is not loaded")),
        };
    }
}

extend Library as Free {
    pub fn free(self: &mut Self) {
        if let Some(l) = replace(&mut self.lib, Option::<dylib::Library>::None) {
            let _ = unsafe l.close();
        }
        let _ = fs::remove_all(&self.dir);
        self.dir.free();
    }
}
