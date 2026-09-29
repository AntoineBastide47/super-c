// The build-setting enums. The compiler defines the constants `PLATFORM: Platform`, `ARCH: Arch` and
// `ENDIAN: Endian` from its flags; the variant order is the bit order of `@platform` and `@arch`.

/// An operating system target: the names `@platform(...)` accepts.
pub enum Platform {
    Windows,
    MacOS,
    Linux,
    Wasm,
    IOS,
    Android,
}

/// An instruction set: the names `@arch(...)` accepts.
pub enum Arch {
    X86_64,
    AArch64,
    Wasm32,
}

/// The byte order of the target.
pub enum Endian {
    Little,
    Big,
}
