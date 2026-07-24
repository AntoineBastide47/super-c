// Driver-shared helpers for the emit/test/ext_c stages: output paths + mkdir/open under <gen_root>, the
// keep-list orphan pruner, the runtime-header writer, raw package-Ast accessors, and format_source (the
// canonical-formatting core behind `super-c fmt` and LSP formatting).
import stdio;
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
import consteval::consteval as ce;
import codegen::codegen as cg;
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
pub const fn mod_ast_m(p: &mut loader::Package, m: ModuleId) *mut Ast {
    return &mut p.modules[m as usize].ast;
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
pub fn format_source(src: &String, path: str, width: i32, out: &mut String) i32 {
    // Reject sources that do not parse -- never rewrite something the compiler cannot read.
    // Lexed with trivia so the doc pipeline can count comments; the parser gets a filtered stream.
    let mut vsrc = src.clone();
    let mut lx = lex::Lexer::new(&mut vsrc, path);
    lx.keep_trivia = true;
    lx.scan_tokens();
    if lx.has_errors() {
        lx.log_errors();
        return 1;
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
    ps.build_ast();
    if ps.has_errors() {
        ps.errors.log();
        return 1;
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
        return 2;
    }
    return 0;
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

/// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
pub fn mkdir_p(path: str) {
    let n = path.len();
    if n == 0 || n >= 4096 {
        return;
    }
    let mut buf = Array::<char, 4096>::new();
    buf.copy_from(path.ptr(), n);
    buf[n] = 0 as char;
    let base = (&buf[0]) as *mut char;
    for i in 1..n {
        if unsafe base[i] == '/' as char {
            unsafe base[i] = 0 as char;
            let _ = unsafe shim::sc_mkdir(base);
            unsafe base[i] = '/' as char;
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
        unsafe stdio::fputs(cg::super_rt_includes(), f);
        unsafe stdio::fputs("#endif\n".ptr() as *const char, f);
        unsafe stdio::fclose(f);
    }
    let cpath = build_out_path(gen_dir, "super_rt", ".c");
    let cf = open_out(cpath.as_str());
    if cf != null {
        unsafe stdio::fputs(cg::super_rt_source(), cf);
        unsafe stdio::fclose(cf);
    }
}
