// Driver-shared helpers for the emit/test/ext_c stages: output paths + mkdir/open under <gen_root>, the
// keep-list orphan pruner, the runtime-header writer, raw package-Ast accessors, format_source (the
// canonical-formatting core behind `super-c fmt` and LSP formatting), and the cross-toolchain selection
// both link paths share.
import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import driver::rt_c as rtc;
import utils::errors as diag;

/// A 4096-byte path scratch buffer; `PathBuf {}` partial init zero-fills the array.
pub type PathBuf = Array<char, 4096>;
pub type Buf64 = Array<char, 64>;
pub type Buf128 = Array<char, 128>;

// ---------------------------------------------------------------------------------------------------------
// Raw-pointer accessors into a package module's held Ast (public fields, so no loader plumbing needed).
// ---------------------------------------------------------------------------------------------------------
pub const fn mod_ast_c(p: &loader::Package, m: ModuleId) *const Ast {
    return &p.modules[m as usize].ast;
}

// ---------------------------------------------------------------------------------------------------------
// The keep-list: every build output written this run (owns the heap paths; stale files not here are pruned).
// ---------------------------------------------------------------------------------------------------------
// A `Vector<String>` (owns each heap path; RAII-freed). `keep.push(path)` moves the String in.

// ---------------------------------------------------------------------------------------------------------
// Output paths + directories.
// ---------------------------------------------------------------------------------------------------------

/// Lex (trivia kept for the comment count), parse and canonically format `src` into `out` at `width`
/// columns -- the shared core of `super-c fmt` and LSP textDocument/formatting. 0 = ok (`out` filled);
/// 1 = lex/parse error (diagnostics printed against `path`); 2 = the dropped-comment safety check
/// tripped. `out` must not be used unless 0.
pub fn format_source(src: &String, path: str, width: i32, out: &mut String) bool {
    // Reject sources that do not parse -- never rewrite something the compiler cannot read.
    // Lexed with trivia so the doc pipeline can count comments; the parser gets a filtered stream.
    let mut vsrc = src.clone();
    let mut lx = lex::Lexer::new(&mut vsrc, path);
    lx.keep_trivia = true;
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        return false;
    }
    let toks = lx.take_tokens();
    let mut ncomments: usize = 0;
    let mut sig = Vector::<tok::Token>::new();
    for i in 0..toks.len() {
        let t = *toks.at(i);
        let k = t.kind();
        if k == ltt::TokenType::LineComment || k == ltt::TokenType::BlockComment || k == ltt::TokenType::DocLineComment || k == ltt::TokenType::DocBlockComment {
            ncomments = ncomments + 1;
        } else {
            sig.push(t);
        }
    }
    let mut ps = par::Parser::new(sig, vsrc.as_str(), path);
    // The formatter prints `@derive` as attribute text and reprints the source items 1:1, so the
    // synthesized extends must not exist in its AST.
    ps.expand_derive = false;
    ps.build_ast();
    if ps.has_errors() {
        ps.errors.log();
        return false;
    }
    let ast = ps.take_ast();
    let emitted = fbld::format_program(&ast, src.as_str(), width, out);
    if emitted != ncomments {
        eprintln(
            "fmt: internal error: {} of {} comments would be dropped in '{}'; refusing",
            ncomments - emitted,
            ncomments,
            path,
        );
        return false;
    }
    return true;
}

/// "<gen_dir>/<mod path, '::' -> '/'><ext>" (heap-allocated; caller owns).
pub fn build_out_path(gen_dir: str, mod_path: str, ext: str) String {
    let mut out = String::from_str(gen_dir);
    out.push_byte(b'/');
    let n = mod_path.len();
    let mut i: usize = 0;
    while i < n {
        if mod_path.byte_at(i) == b':' && i + 1 < n && mod_path.byte_at(i + 1) == b':' {
            out.push_byte(b'/');
            i = i + 2;
        } else {
            out.push_byte(mod_path.byte_at(i));
            i = i + 1;
        }
    }
    out.push_str(ext);
    return out;
}

pub fn is_dir(path: str) bool {
    let mut p = String::from_str(path);
    return unsafe shim::sc_stat_isdir(p.cstr()) == 1;
}

// Whitespace-split `s` into argv entries: FLAG strings keep their historic shell-splitting contract
// ("-framework Cocoa" is two arguments); paths the engine controls are pushed as single entries and
// never split, which is what lets spaces, quotes and non-ASCII bytes pass through.
pub fn split_args(out: &mut Vector<String>, s: str) {
    let mut a: usize = 0;
    for i in 0..s.len() + 1 {
        let ws = i == s.len() || s[i] == b' ' || s[i] == b'\t';
        if ws {
            if i > a {
                out.push(String::from_str(s.slice(a, i)));
            }
            a = i + 1;
        }
    }
}

// spawn_args + wait, output inherited (or captured when `log` is non-null): exit code, -1 on failure.
pub fn exec_args(args: &mut Vector<String>, log: *const char) i32 {
    let mut ptrs = Vector::<usize>::with_capacity(args.len() + 1);
    for i in 0..args.len() {
        ptrs.push(args[i].cstr() as usize);
    }
    ptrs.push(0);
    return unsafe shim::sc_exec_argv(ptrs.as_ptr() as *const *const char, log);
}

/// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
pub fn mkdir_p(path: str) {
    let n = path.len();
    if n == 0 || n >= 4096 {
        return;
    }
    let mut buf = Array::<char, 4096>::new();
    buf.copy_from(path.ptr(), n);
    buf[n] = 0 as char;
    let base = (&buf[0]) as *const char; // read-only C string view; the buffer is edited in place below
    for i in 1..n {
        if buf[i] == '/' as char {
            buf[i] = 0 as char;
            let _ = unsafe shim::sc_mkdir(base);
            buf[i] = '/' as char;
        }
    }
    let _ = unsafe shim::sc_mkdir(base);
}

/// Open `path` for writing, creating any missing parent directories first.
pub fn open_out(path: str) *mut stdio::FILE {
    let p = path.ptr();
    let n = path.len();
    let mut slash: usize = n;
    for i in 0..n {
        if unsafe p[i] == b'/' {
            slash = i;
        }
    }
    if slash < n {
        mkdir_p(str::from_raw(p, slash));
    }
    return stdio::fopen(path, "wb");
}

/// Recursively delete every .c/.h under `dir` that is NOT in the keep-list (the files this run wrote), then
/// drop any directory left empty. The compiler overwrites build/ in place but must also remove outputs the
/// program no longer produces (a removed module/instance/@test-runner/@c.source wrapper) -- a stale TU would
/// otherwise linger and break `cc build/**/*.c`. Path comparison is exact ("<dir>/<name>", like build_out_path).
pub fn prune_orphans(dir: *const char, keep: &Vector<String>) {
    let d = unsafe shim::sc_opendir(dir);
    if d == null {
        return;
    }
    loop {
        let e = unsafe shim::sc_readdir(d);
        if e == null {
            break;
        }
        let name = unsafe shim::sc_dirent_name(e);
        if unsafe cstring::strcmp(name, ".".ptr() as *const char) == 0 || unsafe cstring::strcmp(
            name,
            "..".ptr() as *const char,
        ) == 0 {
            continue;
        }

        let mut pb = PathBuf {};
        let np = unsafe stdio::snprintf(&mut pb[0], 4096, "%s/%s".ptr() as *const char, dir, name);
        if np < 0 || np as usize >= 4096 {
            continue;
        }
        let path = (&pb[0]) as *const char;
        if unsafe shim::sc_stat_isdir(path) != 0 {
            prune_orphans(path, keep);
            let _ = unsafe shim::sc_rmdir(path); // no-op unless the recursion just emptied it
            continue;
        }
        let l = unsafe cstring::strlen(name); // only generated .c/.h translation units are ours to prune
        if !(l >= 2 && unsafe name[l - 2] == '.' as char && (unsafe name[l - 1] == 'c' as char || unsafe name[l - 1] == 'h' as char)) {
            continue;
        }
        let mut kept = false;
        let mut i: usize = 0;
        while i < keep.len() && !kept {
            if keep[i].as_str() == str::from_cstr(path) {
                kept = true;
            }
            i = i + 1;
        }
        if !kept {
            let _ = unsafe shim::sc_unlink(path);
        }
    }
    let _ = unsafe shim::sc_closedir(d);
}

/// The runtime header shared by every generated module (the C standard library includes plus the
/// leak-tracker interposition), and the tracker's implementation TU the engine compiles alongside.
pub fn write_super_rt(gen_dir: str) {
    let path = build_out_path(gen_dir, "super_rt", ".h");
    let f = open_out(path.as_str());
    if f != null {
        unsafe stdio::fputs("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n".ptr() as *const char, f);
        unsafe stdio::fputs(rtc::super_rt_includes(), f);
        unsafe stdio::fputs("#endif\n".ptr() as *const char, f);
        unsafe stdio::fclose(f);
    }
    let cpath = build_out_path(gen_dir, "super_rt", ".c");
    let cf = open_out(cpath.as_str());
    if cf != null {
        unsafe stdio::fputs(rtc::super_rt_source(), cf);
        unsafe stdio::fclose(cf);
    }
}

// ---------------------------------------------------------------------------------------------------------
// cross toolchains
// ---------------------------------------------------------------------------------------------------------
// Shared by BOTH link paths -- the build.toml engine and the single-file `super-c build foo.spc` -- because
// a target that reaches only one of them mis-builds silently: the front end gates items on the target while
// the C compiler still builds for the host.

/// The SDK a `--target=` needs, as an index into the helpers below: 1 iOS, 2 Android, 3 wasm, 0 none
/// (windows/macos/linux compile with the ordinary `cc`).
pub const fn target_sdk(target: i32) i32 {
    if target == 3 {
        return 3;
    }
    if target == 4 {
        return 1;
    }
    if target == 5 {
        return 2;
    }
    return 0;
}

/// The cross compiler for `sdk`, found through the SDK's own environment variable so no path is baked
/// into the compiler. Empty when the toolchain is not installed -- the caller then falls back and the
/// C compiler reports what is missing.
pub fn sdk_cc(sdk: i32, out: &mut String) {
    if sdk == 1 {
        // iOS: clang from the active Xcode, selected by `xcrun` so the SDK path comes from the toolchain
        out.push_str("xcrun --sdk iphoneos clang");
        return;
    }
    if sdk == 2 {
        // Android: the NDK's prebuilt clang. $ANDROID_NDK_HOME (or $ANDROID_NDK_ROOT) locates it.
        let mut ndk = stdlib::getenv("ANDROID_NDK_HOME");
        if ndk == null || unsafe *ndk == 0 as char {
            ndk = stdlib::getenv("ANDROID_NDK_ROOT");
        }
        if ndk == null || unsafe *ndk == 0 as char {
            return;
        }
        out.push_str(str::from_cstr(ndk));
        out.push_str("/toolchains/llvm/prebuilt/");
        out.push_str(ndk_host_tag());
        out.push_str("/bin/clang");
        return;
    }
    if sdk == 3 {
        // WebAssembly: the wasi-sdk's clang when present (it brings wasi-libc), else a plain clang,
        // which can only build freestanding code.
        let w = stdlib::getenv("WASI_SDK_PATH");
        if w != null && unsafe *w != 0 as char {
            out.push_str(str::from_cstr(w));
            out.push_str("/bin/clang");
            return;
        }
        out.push_str("clang");
    }
}

// The NDK lays its prebuilt toolchains out per build host.
const fn ndk_host_tag() str<'static> {
    if unsafe shim::sc_host_platform() == 0 {
        return "windows-x86_64";
    }
    if unsafe shim::sc_host_platform() == 1 {
        return "darwin-x86_64"; // the NDK ships one universal darwin toolchain under this name
    }
    return "linux-x86_64";
}

/// Flags every translation unit needs for a cross target: the triple, and for wasm the wasi sysroot's
/// own defaults. Nothing here overrides the manifest -- these come first, manifest flags after.
pub fn push_sdk_flags(cmd: &mut String, sdk: i32, arch: i32) {
    if sdk == 1 {
        // The triple carries the deployment floor: without a version clang assumes an iOS old enough to
        // lack thread-local storage, which the runtime's preemption tick needs.
        cmd.push_str(" -target ");
        if arch == 0 {
            cmd.push_str("x86_64-apple-ios13.0-simulator");
        } else {
            cmd.push_str("arm64-apple-ios13.0");
        }
        return;
    }
    if sdk == 2 {
        // The NDK's clang takes the API level in the triple; 24 is the oldest still widely supported.
        cmd.push_str(" -target ");
        if arch == 0 {
            cmd.push_str("x86_64-linux-android24");
        } else {
            cmd.push_str("aarch64-linux-android24");
        }
        return;
    }
    if sdk == 3 {
        // A wasi sysroot supplies the libc the emitted C needs. $WASI_SDK_PATH names a full wasi-sdk
        // (its sysroot sits under share/wasi-sysroot); $WASI_SYSROOT names a bare one. With neither,
        // only freestanding code can build -- there is no libc to include.
        let sdkp = stdlib::getenv("WASI_SDK_PATH");
        if sdkp != null && unsafe *sdkp != 0 as char {
            cmd.push_str(" -D_WASI_EMULATED_SIGNAL");
            cmd.push_str(" -target wasm32-wasi --sysroot \"");
            cmd.push_str(str::from_cstr(sdkp));
            cmd.push_str("/share/wasi-sysroot\"");
            return;
        }
        let sr = stdlib::getenv("WASI_SYSROOT");
        if sr != null && unsafe *sr != 0 as char {
            cmd.push_str(" -D_WASI_EMULATED_SIGNAL");
            cmd.push_str(" -target wasm32-wasi --sysroot \"");
            cmd.push_str(str::from_cstr(sr));
            cmd.push_str("\"");
            return;
        }
        cmd.push_str(" -target wasm32 -nostdlib");
    }
}

/// Libraries a cross target needs at LINK time only. wasi keeps signals behind an opt-in emulation
/// library; the runtime's panic path installs a handler, so the build asks for it.
pub fn push_sdk_libs(cmd: &mut String, sdk: i32) {
    if sdk == 3 {
        let sdkp = stdlib::getenv("WASI_SDK_PATH");
        let sr = stdlib::getenv("WASI_SYSROOT");
        if sdkp != null && unsafe *sdkp != 0 as char || sr != null && unsafe *sr != 0 as char {
            cmd.push_str(" -lwasi-emulated-signal");
        }
    }
}
