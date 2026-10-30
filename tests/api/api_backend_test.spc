// Experimental custom backends: the version gate, target support, the program verified before a backend
// sees it, artifact names checked and sorted, determinism, and the native code generators behind the same
// interface.
import api::errors as *;
import api::lir as *;
import api::backend as be;

const PROGRAM: str = M"(lir ptr 8 vec 0
sym @add3 fn global
fn @add3
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = add.i32 v0, v1
  v3 = iconst.i32 3
  v4 = add.i32 v2, v3
  ret v4
)";

// A backend that writes the program's text and its function list, under names it is given.
struct TextBackend {
    pub version: u32,
    pub names: Vector<String>,
}

extend TextBackend as be::Backend {
    pub fn api_version(self: &Self) u32 {
        return self.version;
    }

    pub fn supports(self: &Self, os: str, _isa: str) bool {
        return os != "ios";
    }

    pub fn emit(self: &mut Self, prog: &Program, os: str, isa: str, out: &mut Vector<be::Artifact>) Result<
        Unit,
        ApiError
    > {
        for i in 0..self.names.len() {
            let mut b = Vector::<u8>::new();
            let t = if i == 0 {
                format("{} {}\n{}", os, isa, prog.text().as_str())
            } else {
                format("{}\n", prog.functions().len())
            };
            b.extend_from_slice(unsafe Slice::<u8> { ptr: t.as_ptr(), len: t.len() });
            out.push(be::Artifact { name: self.names[i].clone(), bytes: b });
        }
        return Ok(Unit {});
    }
}

fn text_backend(names: Slice<str>) TextBackend {
    let mut b = TextBackend { version: be::BACKEND_API, names: Vector::<String>::new() };
    for i in 0..names.len() {
        b.names.push(String::from_str(names[i]));
    }
    return b;
}

@test
fn a_custom_backend_makes_sorted_deterministic_artifacts() {
    let p = Program::parse(PROGRAM).unwrap();
    let mut b = text_backend(["z.txt", "a.lir"]);
    let first = be::run(&mut b, &p, "linux", "aarch64").unwrap();
    assert_eq(first.len(), 2usize);
    assert_eq(first[0].name.as_str(), "a.lir");
    assert_eq(first[1].name.as_str(), "z.txt");
    let again = be::run(&mut b, &p, "linux", "aarch64").unwrap();
    for i in 0..2usize {
        assert(first[i].bytes.as_slice() == again[i].bytes.as_slice(), "the same bytes every run");
    }
}

@test
fn the_backend_gate_rejects_what_it_must() {
    let p = Program::parse(PROGRAM).unwrap();
    let mut old = text_backend(["a"]);
    old.version = be::BACKEND_API + 1;
    assert(
        be::run(&mut old, &p, "linux", "x86_64").unwrap_err().code == Code::VersionMismatch,
        "another interface version",
    );
    let mut b = text_backend(["a"]);
    assert(
        be::run(&mut b, &p, "ios", "aarch64").unwrap_err().code == Code::UnsupportedCapability,
        "an unsupported target",
    );
    for bad in ["", "..", "dir/a", "dir\\a"] {
        let mut nb = text_backend([bad]);
        assert(
            be::run(&mut nb, &p, "linux", "x86_64").unwrap_err().code == Code::VerificationFailed,
            "a bad artifact name",
        );
    }
    let mut dup = text_backend(["a", "a"]);
    assert(be::run(&mut dup, &p, "linux", "x86_64").unwrap_err().code == Code::VerificationFailed, "a repeated name");
    // A program that does not verify never reaches the backend.
    let mut broken = Program::parse(PROGRAM).unwrap();
    broken.raw_mut().bodies[0].blocks.clear();
    assert(
        be::run(&mut b, &broken, "linux", "x86_64").unwrap_err().code == Code::VerificationFailed,
        "an unverified program",
    );
}

@test
fn the_native_code_generators_are_a_backend() {
    let p = Program::parse(PROGRAM).unwrap();
    let mut n = be::NativeBackend {};
    assert(n.supports("wasm", "wasm32") && !n.supports("windows", "aarch64"), "the native targets");
    let elf = be::run(&mut n, &p, "linux", "x86_64").unwrap();
    assert_eq(elf[0].name.as_str(), "program.o");
    assert(elf[0].bytes.len() > 4 && elf[0].bytes[0] == 0x7F && elf[0].bytes[1] == b'E', "an ELF object");
    assert(elf[0].bytes.as_slice() == p.object("linux", "x86_64").unwrap().as_slice(), "the object of the program");
    let coff = be::run(&mut n, &p, "windows", "x86_64").unwrap();
    assert(coff[0].bytes[0] == 0x64 && coff[0].bytes[1] == 0x86, "a COFF object for x86-64");
    let elf64 = be::run(&mut n, &p, "linux", "aarch64").unwrap();
    assert(elf64[0].bytes[0] == 0x7F && elf64[0].bytes[18] == 0xB7, "an ELF object for arm64");
    let macho = be::run(&mut n, &p, "macos", "aarch64").unwrap();
    assert(macho[0].bytes[0] == 0xCF && macho[0].bytes[1] == 0xFA, "a Mach-O object");
    let p4 = Program::parse(String::from_str(PROGRAM).replace("ptr 8", "ptr 4").as_str()).unwrap();
    let wasm = be::run(&mut n, &p4, "wasm", "wasm32").unwrap();
    assert(wasm[0].bytes[0] == 0 && wasm[0].bytes[1] == b'a', "a wasm object");
    assert(be::run(&mut n, &p, "wasm", "wasm32").unwrap_err().code == Code::InvalidArgument, "8-byte pointers");
}
