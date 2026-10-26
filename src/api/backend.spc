// Experimental custom backends (`backend.artifacts.experimental.v1`): a backend consumes the frozen LIR of a
// program and returns named artifacts. The program is complete and verified before a backend sees it, and
// a backend gets it shared: it cannot change the program, resolution or type checking. A backend must
// implement exactly this compiler's interface version. The native code generators are a backend of the same
// interface (`NativeBackend`). An in-process backend shares the compiler's address space.
import api::errors as *;
import api::lir as lir;
import target::native as native;
import target::table as tgt;

/// The backend interface version this compiler runs; a backend that implements another is rejected.
pub const BACKEND_API: u32 = 1;

/// One output of a backend: a file name, relative to the output directory and without directories, and its
/// bytes.
pub struct Artifact {
    pub name: String,
    pub bytes: Vector<u8>,
}

/// A code generator over LIR.
pub interface Backend {
    /// The interface version it implements: `BACKEND_API` of the compiler it was written for.
    fn api_version(self: &Self) u32;
    /// Whether it generates code for operating system `os` and instruction set `isa` (`target::table`
    /// names: `macos`, `linux`, `windows`, ...; `aarch64`, `x86_64`, ...).
    fn supports(self: &Self, os: str, isa: str) bool;
    /// Push the artifacts of `prog` for `os` and `isa` into `out`.
    fn emit(self: &mut Self, prog: &lir::Program, os: str, isa: str, out: &mut Vector<Artifact>) Result<Unit, ApiError>;
}

/// The compiler's native code generators: one object file `program.o`, Mach-O, ELF or COFF.
pub struct NativeBackend {}

extend NativeBackend as Backend {
    pub fn api_version(self: &Self) u32 {
        return BACKEND_API;
    }

    pub fn supports(self: &Self, os: str, isa: str) bool {
        let o = tgt::axis_index(os, false);
        let i = tgt::axis_index(isa, true);
        return o >= 0 && i >= 0 && native::supported(o, i);
    }

    pub fn emit(self: &mut Self, prog: &lir::Program, os: str, isa: str, out: &mut Vector<Artifact>) Result<
        Unit,
        ApiError
    > {
        let bytes = prog.object(os, isa)?;
        out.push(Artifact { name: String::from_str("program.o"), bytes: bytes });
        return Result::<Unit, ApiError>::Ok(Unit {});
    }
}

/// The artifacts backend `b` makes of `prog` for `os` and `isa`, sorted by name. `VersionMismatch` for a
/// backend of another interface version; `UnsupportedCapability` for a target it does not support;
/// `VerificationFailed` when `prog` does not verify, or for an artifact name that is empty, holds a
/// directory, or repeats.
pub fn run(b: &mut dyn Backend, prog: &lir::Program, os: str, isa: str) Result<Vector<Artifact>, ApiError> {
    if b.api_version() != BACKEND_API {
        return Result::<Vector<Artifact>, ApiError>::Err(
            ApiError::new(
                Code::VersionMismatch,
                format("the backend implements interface {}, the compiler runs {}", b.api_version(), BACKEND_API).as_str(),
            ),
        );
    }
    if !b.supports(os, isa) {
        return Result::<Vector<Artifact>, ApiError>::Err(
            ApiError::new(
                Code::UnsupportedCapability,
                format("the backend does not generate code for {} {}", os, isa).as_str(),
            ),
        );
    }
    prog.verify()?;
    let mut out = Vector::<Artifact>::new();
    b.emit(prog, os, isa, &mut out)?;
    sort_artifacts(&mut out)?;
    return Result::<Vector<Artifact>, ApiError>::Ok(out);
}

/// Sort `out` by name; `VerificationFailed` for a name that is empty, holds a directory, or repeats.
pub fn sort_artifacts(out: &mut Vector<Artifact>) Result<Unit, ApiError> {
    out.sort_by(
        |x: &Artifact, y: &Artifact| {
            let yn = y.name.as_str();
            return x.name.as_str().cmp(&yn);
        },
    );
    for i in 0..out.len() {
        let n = out[i].name.as_str();
        if n.len() == 0 || n == "." || n == ".." || n.find("/") >= 0 || n.find("\\") >= 0 || i > 0 && out[i - 1].name.as_str() == n {
            return Result::<Unit, ApiError>::Err(
                ApiError::new(Code::VerificationFailed, format("an artifact is named '{}'", n).as_str()),
            );
        }
    }
    return Result::<Unit, ApiError>::Ok(Unit {});
}
