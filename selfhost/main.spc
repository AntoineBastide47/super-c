// The self-hosted super-c driver: parse args, load the package, run the global phases
// (resolve all -> type-check all -> flush deferred static_asserts -> propagate instances -> emit all),
// writing a `<root>/build/` tree (super_rt.h + one .c/.h per module). Ports src/main.c.
import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import ast::ast as *;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import consteval::consteval as ce;
import codegen::codegen as cg;
import utils::errors as diag;

// --test options (mirrors src/main.c TestOpts).
pub struct TestOpts {
    pub enabled: bool,
    pub jobs: i32,
    pub no_fork: bool,
    pub filter: *const char,
}

// A 4096-byte path scratch buffer; the omitted array field zero-fills on partial init.
struct PathBuf { pub b: [char; 4096] }
struct Buf64 { pub b: [char; 64] }
struct Buf128 { pub b: [char; 128] }

// ---------------------------------------------------------------------------------------------------------
// Raw-pointer accessors into a package module's held Ast (public fields, so no loader plumbing needed).
// ---------------------------------------------------------------------------------------------------------
fn mod_ast_c(p: &loader::Package, m: ModuleId) *const Ast { return (&p.modules[m as usize].ast) as *const Ast; }
fn mod_ast_m(p: &mut loader::Package, m: ModuleId) *mut Ast {
    return (&mut p.modules[m as usize].ast) as *mut Ast;
}

// ---------------------------------------------------------------------------------------------------------
// The keep-list: every build output written this run (owns the heap paths; stale files not here are pruned).
// ---------------------------------------------------------------------------------------------------------
// A `Vector<String>` (owns each heap path; RAII-freed). `keep.push(path)` moves the String in.

// ---------------------------------------------------------------------------------------------------------
// Output paths + directories.
// ---------------------------------------------------------------------------------------------------------

// "<root>/build/<mod path, '::' -> '/'><ext>" (heap-allocated; caller owns). Generated includes are relative.
fn build_out_path(root_dir: *const char, mod_path: *const char, ext: *const char) String {
    let mut out = String::from_cstr(root_dir);
    out.push_str("/build/");
    let mut s = mod_path;
    while (unsafe *s) != (0 as char) {
        if (unsafe *s) == (':' as char) && (unsafe *(s + 1)) == (':' as char) {
            out.push_byte('/' as u8);
            s = unsafe (s + 2);
        } else {
            out.push_byte((unsafe *s) as u8);
            s = unsafe (s + 1);
        }
    }
    out.push_str(str::from_cstr(ext));
    return out;
}

// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
fn mkdir_p(path: str) void {
    let n = path.len();
    if n == 0 || n >= 4096 { return; }
    let mut buf = PathBuf { };
    unsafe cstring::memcpy((&mut buf.b[0]) as *mut void, path.ptr() as *const void, n);
    unsafe buf.b[n] = 0 as char;
    let base = (&mut buf.b[0]) as *mut char;
    let mut i: usize = 1;
    while i < n {
        if (unsafe base[i]) == ('/' as char) {
            unsafe base[i] = 0 as char;
            let _ = unsafe shim::sc_mkdir(base);
            unsafe base[i] = '/' as char;
        }
        i = i + 1;
    }
    let _ = unsafe shim::sc_mkdir(base);
}

// Open `path` for writing, creating any missing parent directories first.
fn open_out(path: str) *mut stdio::FILE {
    let p = path.ptr();
    let n = path.len();
    let mut slash: usize = n;
    let mut i: usize = 0;
    while i < n { if (unsafe p[i]) == ('/' as u8) { slash = i; } i = i + 1; }
    if slash < n { mkdir_p(str::from_raw(p, slash)); }
    return stdio::fopen(path, "w");
}

// Recursively delete every .c/.h under `dir` that is NOT in the keep-list (the files this run wrote), then
// drop any directory left empty. The compiler overwrites build/ in place but must also remove outputs the
// program no longer produces (a removed module/instance/@test-runner/@c.source wrapper) -- a stale TU would
// otherwise linger and break `cc build/**/*.c`. Path comparison is exact ("<dir>/<name>", like build_out_path).
fn prune_orphans(dir: *const char, keep: &Vector<String>) void {
    let d = unsafe shim::sc_opendir(dir);
    if d == null { return; }
    loop {
        let e = unsafe shim::sc_readdir(d);
        if e == null { break; }
        let name = unsafe shim::sc_dirent_name(e);
        if unsafe cstring::strcmp(name, ".".ptr() as *const char) == 0 || unsafe cstring::strcmp(name, "..".ptr() as *const char) == 0 { continue; }
        let mut pb = PathBuf { };
        let np = unsafe stdio::snprintf((&mut pb.b[0]) as *mut char, 4096, "%s/%s".ptr() as *const char, dir, name);
        if np < 0 || (np as usize) >= 4096 { continue; }
        let path = (&pb.b[0]) as *const char;
        if unsafe shim::sc_stat_isdir(path) != 0 {
            prune_orphans(path, &*keep);
            let _ = unsafe shim::sc_rmdir(path); // no-op unless the recursion just emptied it
            continue;
        }
        let l = unsafe cstring::strlen(name); // only generated .c/.h translation units are ours to prune
        if !(l >= 2 && (unsafe name[l - 2]) == ('.' as char) && ((unsafe name[l - 1]) == ('c' as char) || (unsafe name[l - 1]) == ('h' as char))) { continue; }
        let mut kept = false;
        let mut i: usize = 0;
        while i < keep.len() && !kept {
            if keep[i].as_str() == str::from_cstr(path) { kept = true; }
            i = i + 1;
        }
        if !kept { let _ = unsafe shim::sc_unlink(path); }
    }
    let _ = unsafe shim::sc_closedir(d);
}

// The runtime header shared by every generated module: the C standard library includes.
fn write_super_rt(root_dir: *const char) void {
    let path = build_out_path(root_dir, "super_rt".ptr() as *const char, ".h".ptr() as *const char);
    let f = open_out(path.as_str());
    if f != null {
        unsafe stdio::fputs("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n".ptr() as *const char, f);
        unsafe stdio::fputs(cg::super_rt_includes(), f);
        unsafe stdio::fputs("#endif\n".ptr() as *const char, f);
        unsafe stdio::fclose(f);
    }
}

// ---------------------------------------------------------------------------------------------------------
// Dead-module pruning of the emit set: a live module reaches its own decls + everything it references.
// ---------------------------------------------------------------------------------------------------------
fn mark_live(live: *mut bool, n: usize, m: ModuleId) bool {
    if (m as usize) >= n || (unsafe live[m as usize]) { return false; }
    unsafe live[m as usize] = true;
    return true;
}

fn ast_type_mentions_builtin(p: &loader::Package, am: ModuleId, t: TypeId) bool {
    if t == TYPE_NONE { return false; }
    let y = unsafe *(mod_ast_c(&*p, am)).type_at(t);
    if y.kind == TypeKind::TYPE_BUILTIN { return true; }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE ||
       y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return ast_type_mentions_builtin(&*p, am, y.as_data.elem);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = unsafe *(mod_ast_c(&*p, am)).instance(y.as_data.inst);
        for i in 0..it.n {
            if ast_type_mentions_builtin(&*p, am, it.args[i as usize]) { return true; }
        }
        return false;
    }
    return false;
}

fn mark_type_modules(p: &loader::Package, am: ModuleId, t: TypeId, live: *mut bool) bool {
    if t == TYPE_NONE { return false; }
    let y = unsafe *(mod_ast_c(&*p, am)).type_at(t);
    let mut changed = false;
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE ||
       y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        if mark_type_modules(&*p, am, y.as_data.elem, live) { changed = true; }
    } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_FUNCTION {
        if p.builtin_of_decl(y.module, y.as_data.decl) < 0 {
            if mark_live(live, p.modules.len(), y.module) { changed = true; }
        }
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        let it = unsafe *(mod_ast_c(&*p, am)).instance(y.as_data.inst);
        let np = p.modules.len();
        if (it.module as usize) < np { if mark_live(live, np, it.module) { changed = true; } }
        let home = p.instance_home_mid(am, &it);
        if (home as usize) < np { if mark_live(live, np, home) { changed = true; } }
        for i in 0..it.n {
            if mark_type_modules(&*p, am, it.args[i as usize], live) { changed = true; }
            if p.core_seeded && ast_type_mentions_builtin(&*p, am, it.args[i as usize]) {
                if mark_live(live, np, p.core_module) { changed = true; }
            }
        }
    }
    return changed;
}

fn compute_emit_live(p: &loader::Package) *mut bool {
    let n = p.modules.len();
    let sz = if n != 0 { n; } else { 1 as usize; };
    let live = unsafe stdlib::calloc(sz, 1) as *mut bool;
    if live == null { return null; }
    for i in 0..n {
        if !p.modules[i].prelude { unsafe live[i] = true; }
    }
    let mut changed = true;
    while changed {
        changed = false;
        for m in 0..n {
            if !(unsafe live[m]) || !p.modules[m].has_ast { continue; }
            let a = mod_ast_c(&*p, m as ModuleId);
            let nr = unsafe (*a).resolutions.len();
            for r in 0..nr {
                let d = unsafe (*a).resolutions[r];
                if d.node != NODE_NONE && (d.module as usize) < n && (d.module as usize) != m &&
                   p.builtin_of_decl(d.module, d.node) < 0 {
                    if mark_live(live, n, d.module) { changed = true; }
                }
            }
            let nt = unsafe (*a).type_pool.len();
            for ti in 0..nt {
                if mark_type_modules(&*p, m as ModuleId, ti as TypeId, live) { changed = true; }
            }
            let ni = unsafe (*a).instances.len();
            for ii in 0..ni {
                let it = unsafe *(*a).instance(ii as u32);
                if (it.module as usize) < n { if mark_live(live, n, it.module) { changed = true; } }
                let home = p.instance_home_mid(m as ModuleId, &it);
                if (home as usize) < n { if mark_live(live, n, home) { changed = true; } }
                for k in 0..it.n {
                    if mark_type_modules(&*p, m as ModuleId, it.args[k as usize], live) { changed = true; }
                    if p.core_seeded && ast_type_mentions_builtin(&*p, m as ModuleId, it.args[k as usize]) {
                        if mark_live(live, n, p.core_module) { changed = true; }
                    }
                }
            }
            let nmo = unsafe (*a).mono.len();
            for moi in 0..nmo {
                let mu = unsafe (*a).mono[moi];
                for k in 0..mu.n {
                    if mark_type_modules(&*p, m as ModuleId, mu.args[k as usize], live) { changed = true; }
                    if p.core_seeded && ast_type_mentions_builtin(&*p, m as ModuleId, mu.args[k as usize]) {
                        if mark_live(live, n, p.core_module) { changed = true; }
                    }
                }
            }
            let nmi = unsafe (*a).method_insts.len();
            for xi in 0..nmi {
                let miu = unsafe (*a).method_insts[xi];
                if mark_type_modules(&*p, m as ModuleId, miu.instance, live) { changed = true; }
                for k in 0..miu.n {
                    if mark_type_modules(&*p, m as ModuleId, miu.targs[k as usize], live) { changed = true; }
                    if p.core_seeded && ast_type_mentions_builtin(&*p, m as ModuleId, miu.targs[k as usize]) {
                        if mark_live(live, n, p.core_module) { changed = true; }
                    }
                }
            }
        }
    }
    return live;
}

// ---------------------------------------------------------------------------------------------------------
// Pipeline stages over one module (move the Ast out of its slot, run, and restore it).
// ---------------------------------------------------------------------------------------------------------
fn resolve_module(p: &mut loader::Package, i: usize) bool {
    let pkg = (&*p) as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut r = resolver::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = (&mut r.ast) as *mut Ast;
    r.resolve();
    p.override_mod = 0xFFFF as ModuleId;
    p.override_ast = null;
    let had = r.has_errors();
    if had { r.log_errors(); }
    let back = r.take_ast();
    r.free();
    p.modules[i].ast = back;
    return !had;
}

fn typecheck_module(p: &mut loader::Package, i: usize) bool {
    let pkg = (&mut *p) as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = (&mut t.ast) as *mut Ast;
    t.check();
    p.override_mod = 0xFFFF as ModuleId;
    p.override_ast = null;
    let had = t.has_errors();
    if had { t.log_errors(); }
    let back = t.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// A deferred static_assert that failed once the whole package was typed: render it against the owning module.
fn flush_assert_err(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) void {
    let p = ctx as *mut loader::Package;
    let sp = unsafe (*p).modules[m as usize].ast.at_const(cond).span;
    let src = unsafe (*p).modules[m as usize].source.as_str().ptr();
    let len = unsafe (*p).modules[m as usize].source.len();
    let file = unsafe (*p).modules[m as usize].file;
    let mut errs = diag::Errors::new();
    if msg != null {
        errs.emit(sp.start, sp.end - sp.start, format("static assertion cannot be evaluated: {}", diag::cstr(msg)));
    } else {
        errs.emit(sp.start, sp.end - sp.start, format("static assertion failed"));
    }
    errs.finalize(src, len, file);
    errs.log();
    errs.free();
    unsafe (*p).ok = false;
}

// ---------------------------------------------------------------------------------------------------------
// External C sources/libs: `@c.source`/`@c.link` attrs + implicit backing-header `.c` siblings. Each resolved
// source becomes a wrapper TU `build/__ext<N>_<stem>.c` (one absolute #include; the file stays in place so its
// own relative includes keep resolving), deduped by resolved path. `@c.link` values become `-l<v>` (verbatim
// when starting with '-'), written to `build/__ldflags`.
// ---------------------------------------------------------------------------------------------------------

// "<dir of file>/<v[0..vl]>" (or "<v>") into `out` (a 4096-byte buffer).
fn ext_rel(file: *const char, v: *const char, vl: i32, out: *mut char) void {
    let mut slash: *mut char = null;
    if file != null { slash = unsafe cstring::strrchr(file, '/' as i32); }
    if slash != null {
        let dlen = ((slash as usize) - (file as usize)) as i32;
        unsafe stdio::snprintf(out, 4096, "%.*s/%.*s".ptr() as *const char, dlen, file, vl, v);
    } else {
        unsafe stdio::snprintf(out, 4096, "%.*s".ptr() as *const char, vl, v);
    }
}

// Wrap one RESOLVED external C source path `rsl` into a build/ TU (deduped across explicit + implicit adds).
fn ext_c_wrap(root: *const char, keep: &mut Vector<String>, seen: &mut Vector<String>, nsrc: *mut u32,
              rsl: *const char, err: *mut bool) void {
    for k in 0..seen.len() { if seen[k].as_str() == str::from_cstr(rsl) { return; } }
    seen.push(String::from_cstr(rsl));
    let mut basep = unsafe cstring::strrchr(rsl, '/' as i32) as *const char;
    if basep != null { basep = unsafe (basep + 1); } else { basep = rsl; }
    let mut stem = Buf64 {};
    let mut sl: usize = 0;
    let mut sp = basep;
    while (unsafe *sp) != (0 as char) && (unsafe *sp) != ('.' as char) && sl < 63 {
        let c = unsafe *sp;
        let good = (c >= ('a' as char) && c <= ('z' as char)) || (c >= ('A' as char) && c <= ('Z' as char)) || (c >= ('0' as char) && c <= ('9' as char));
        unsafe stem.b[sl] = if good { c; } else { '_' as char; };
        sl = sl + 1;
        sp = unsafe (sp + 1);
    }
    unsafe stem.b[sl] = 0 as char;
    let mut nm = Buf128 {};
    let idx = unsafe *nsrc;
    unsafe *nsrc = idx + 1;
    unsafe stdio::snprintf((&mut nm.b[0]) as *mut char, 128, "__ext%u_%s".ptr() as *const char, idx, (&stem.b[0]) as *const char);
    let mut path = build_out_path(root, (&nm.b[0]) as *const char, ".c".ptr() as *const char);
    let f = open_out(path.as_str());
    if f == null {
        unsafe stdio::perror(path.cstr());
        unsafe *err = true;
        return;
    }
    unsafe stdio::fprintf(f, "/* external C source pulled into the build -- generated, do not edit */\n#include \"%s\"\n".ptr() as *const char, rsl);
    unsafe stdio::fclose(f);
    keep.push(path);
}

fn ext_c_collect(p: &mut loader::Package, keep: &mut Vector<String>, err: *mut bool) void {
    let root = p.root_dir;
    let mut ld = Vector::<String>::new();
    let mut seen = Vector::<String>::new();
    let mut nsrc: u32 = 0;
    let n = p.modules.len();
    for m in 0..n {
        if !p.modules[m].has_ast { continue; }
        let file = p.modules[m].file;
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let ap = mod_ast_c(&*p, m as ModuleId);
        for ai in 0..unsafe (*ap).attrs.len() {
            let at = unsafe (*ap).attrs[ai];
            let is_src = at.kind == AttrKind::ATTR_C_SOURCE as u8;
            let is_link = at.kind == AttrKind::ATTR_C_LINK as u8;
            if (!is_src && !is_link) || at.str_span.end <= at.str_span.start { continue; }
            let vl = (at.str_span.end - at.str_span.start) as i32;
            let v = unsafe (src + at.str_span.start as usize) as *const char;
            if is_link {
                let mut flag = Buf128 {};
                if (unsafe *v) == ('-' as char) { unsafe stdio::snprintf((&mut flag.b[0]) as *mut char, 128, "%.*s".ptr() as *const char, vl, v); }
                else { unsafe stdio::snprintf((&mut flag.b[0]) as *mut char, 128, "-l%.*s".ptr() as *const char, vl, v); }
                let mut dup = false;
                for k in 0..ld.len() { if ld[k].as_str() == str::from_cstr((&flag.b[0]) as *const char) { dup = true; break; } }
                if !dup { ld.push(String::from_cstr((&flag.b[0]) as *const char)); }
                continue;
            }
            let mut rel = PathBuf {};
            let mut rsl = PathBuf {};
            ext_rel(file, v, vl, (&mut rel.b[0]) as *mut char);
            if unsafe shim::sc_realpath((&rel.b[0]) as *const char, (&mut rsl.b[0]) as *mut char) == null {
                unsafe stdio::snprintf((&mut rel.b[0]) as *mut char, 4096, "%.*s".ptr() as *const char, vl, v);
                if unsafe shim::sc_realpath((&rel.b[0]) as *const char, (&mut rsl.b[0]) as *mut char) == null {
                    unsafe stdio::fprintf(stdio::stderr(), "error: cannot find C source '%.*s'\n".ptr() as *const char, vl, v);
                    unsafe *err = true;
                    continue;
                }
            }
            ext_c_wrap(root, &mut *keep, &mut seen, (&mut nsrc) as *mut u32, (&rsl.b[0]) as *const char, err);
        }
        // Implicit sources: a backing header that resolves next to this module with a same-stem `.c` sibling.
        let items = unsafe (*ap).at_const((*ap).root).as_data.program.items;
        let ids = unsafe (*ap).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*ap).at_const(nid).kind;
            let hdr = if nk == NodeKind::NODE_EXTERN_BLOCK { unsafe (*ap).at_const(nid).as_data.extern_block.header; } else { NODE_NONE; };
            if hdr == NODE_NONE { continue; }
            let hs = unsafe (*ap).at_const(hdr).span;
            let hl = (hs.end - hs.start) as i32 - 2;
            if hl <= 2 { continue; }
            let hv = unsafe (src + (hs.start + 1) as usize) as *const char;
            let mut rel = PathBuf {};
            let mut habs = PathBuf {};
            ext_rel(file, hv, hl, (&mut rel.b[0]) as *mut char);
            if unsafe shim::sc_realpath((&rel.b[0]) as *const char, (&mut habs.b[0]) as *mut char) == null { continue; }
            let dot = unsafe cstring::strrchr((&rel.b[0]) as *const char, '.' as i32);
            if dot == null { continue; }
            let dotoff = (dot as usize) - ((&rel.b[0]) as *const char as usize);
            if dotoff + 2 >= 4096 { continue; }
            unsafe { rel.b[dotoff] = '.' as char; rel.b[dotoff + 1] = 'c' as char; rel.b[dotoff + 2] = 0 as char; }
            let mut cabs = PathBuf {};
            if unsafe shim::sc_realpath((&rel.b[0]) as *const char, (&mut cabs.b[0]) as *mut char) != null {
                ext_c_wrap(root, &mut *keep, &mut seen, (&mut nsrc) as *mut u32, (&cabs.b[0]) as *const char, err);
            }
        }
    }
    let mut ldpath = build_out_path(root, "__ldflags".ptr() as *const char, "".ptr() as *const char);
    if ld.len() != 0 {
        let f = stdio::fopen(ldpath.as_str(), "w");
        if f != null {
            for k in 0..ld.len() { unsafe stdio::fprintf(f, "%s\n".ptr() as *const char, ld[k].cstr()); }
            unsafe stdio::fclose(f);
        }
    } else {
        let _ = unsafe shim::sc_unlink(ldpath.cstr());
    }
}

// ---------------------------------------------------------------------------------------------------------
// --test mode: collect every @test/@test_init/@test_free into a runnable plan, then synthesize + build a
// fork-per-test runner. Ports src/main.c's test-plan machinery.
// ---------------------------------------------------------------------------------------------------------
struct TestCase { pub mod: ModuleId, pub func: NodeId, pub should_panic: bool, pub wants: u8, pub suite: DefId, pub suite_is_enum: bool, pub suite_init: NodeId, pub suite_free: NodeId }
struct TestSuite { pub mod: ModuleId, pub ty: DefId, pub is_enum: bool, pub init: NodeId, pub fre: NodeId }
struct TestPlan {
    pub cases: Vector<TestCase>,
    pub fx_init: Vector<NodeId>, pub fx_free: Vector<NodeId>, pub fx_type: Vector<DefId>, pub fx_is_enum: Vector<bool>,
    pub suites: Vector<TestSuite>,
    pub genv_mod: ModuleId, pub genv_init: NodeId, pub genv_free: NodeId, pub genv_type: DefId, pub genv_is_enum: bool, pub ok: bool,
}
extend TestPlan {
    fn new(count: usize) TestPlan {
        let mut pl = TestPlan {
            cases: Vector::<TestCase>::new(),
            fx_init: Vector::<NodeId>::new(), fx_free: Vector::<NodeId>::new(),
            fx_type: Vector::<DefId>::new(), fx_is_enum: Vector::<bool>::new(),
            suites: Vector::<TestSuite>::new(),
            genv_mod: 0, genv_init: NODE_NONE, genv_free: NODE_NONE,
            genv_type: DefId { module: 0, node: NODE_NONE }, genv_is_enum: false, ok: true,
        };
        let m = if count != 0 { count; } else { 1 as usize; };
        for i in 0..m {
            pl.fx_init.push(NODE_NONE); pl.fx_free.push(NODE_NONE);
            pl.fx_type.push(DefId { module: 0, node: NODE_NONE }); pl.fx_is_enum.push(false);
        }
        return pl;
    }
}
extend TestPlan as Free {
    pub fn free(self: &mut Self) void {
        self.cases.free(); self.fx_init.free(); self.fx_free.free();
        self.fx_type.free(); self.fx_is_enum.free(); self.suites.free();
    }
}

// A test-plan validation error, rendered with the compiler's usual source excerpt.
fn test_err(p: &mut loader::Package, m: ModuleId, sp: tok::Span, msg: *const char) void {
    let src = p.modules[m as usize].source.as_str().ptr();
    let len = p.modules[m as usize].source.len();
    let file = p.modules[m as usize].file;
    let mut errs = diag::Errors::new();
    errs.emit(sp.start, sp.end - sp.start, String::from_cstr(msg));
    errs.finalize(src, len, file);
    errs.log();
    errs.free();
    p.ok = false;
}

// The plain struct/enum decl a type NODE names, or {0, NODE_NONE} (fixtures must be nominal + non-generic).
fn test_type_decl(p: &loader::Package, am: ModuleId, tnode: NodeId, is_enum: *mut bool) DefId {
    let none = DefId { module: 0, node: NODE_NONE };
    if tnode == NODE_NONE { return none; }
    let a = mod_ast_c(&*p, am);
    let tk = unsafe (*a).at_const(tnode).kind;
    if tk != NodeKind::NODE_TYPE_PATH && tk != NodeKind::NODE_IDENTIFIER { return none; }
    let d = unsafe (*a).resolution_def(tnode);
    if d.node == NODE_NONE || (d.module as usize) >= p.modules.len() { return none; }
    let da = mod_ast_c(&*p, d.module);
    let dk = unsafe (*da).at_const(d.node).kind;
    let gen = unsafe (*da).at_const(d.node).as_data.aggregate.generics;
    if (dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM) || gen.len != 0 { return none; }
    unsafe *is_enum = dk == NodeKind::NODE_ENUM;
    return d;
}

// A function's single return type node (unwrapping a named return), or NODE_NONE.
fn test_fn_ret_node(p: &loader::Package, am: ModuleId, fnode: NodeId) NodeId {
    let a = mod_ast_c(&*p, am);
    let rets = unsafe (*a).at_const(fnode).as_data.function.returns;
    if rets.len != 1 { return NODE_NONE; }
    let r0 = unsafe ((*a).list(rets))[0];
    let rn = unsafe (*a).at_const(r0);
    if rn.kind == NodeKind::NODE_PARAMETER { return rn.as_data.parameter.ty; }
    return r0;
}

fn test_fn_returns_nothing(p: &loader::Package, am: ModuleId, src: *const char, fnode: NodeId) bool {
    let a = mod_ast_c(&*p, am);
    let rets = unsafe (*a).at_const(fnode).as_data.function.returns;
    if rets.len == 0 { return true; }
    let rn = test_fn_ret_node(&*p, am, fnode);
    if rn == NODE_NONE { return false; }
    let n = unsafe (*a).at_const(rn);
    if n.kind != NodeKind::NODE_IDENTIFIER { return false; }
    let t = n.as_data.name.text;
    if (t.end - t.start) != 4 { return false; }
    return unsafe cstring::memcmp((src + t.start as usize), "void".ptr(), 4) == 0;
}

// Classify one @test parameter: 1 = fixture/receiver, 2 = global env, 0 with an error emitted.
fn test_param_bit(p: &mut loader::Package, m: ModuleId, pnode: NodeId, fx: DefId, genv: DefId) u8 {
    let a = mod_ast_c(&*p, m);
    let sp = unsafe (*a).at_const(pnode).span;
    let tnode = unsafe (*a).at_const(pnode).as_data.parameter.ty;
    let tk = if tnode != NODE_NONE { unsafe (*a).at_const(tnode).kind; } else { NodeKind::NODE_NONE_KIND; };
    if tnode == NODE_NONE || tk != NodeKind::NODE_REFERENCE_TYPE {
        test_err(&mut *p, m, sp, "a '@test' parameter must be a reference to the module fixture or the global env".ptr() as *const char);
        return 0;
    }
    let it = unsafe (*a).at_const(tnode).as_data.indirect_type;
    let mut is_enum = false;
    let d = test_type_decl(&*p, m, it.ty, (&mut is_enum) as *mut bool);
    if fx.node != NODE_NONE && d.module == fx.module && d.node == fx.node { return 1; }
    if genv.node != NODE_NONE && d.module == genv.module && d.node == genv.node {
        if it.qualifier == TypeQualifier::TYPE_QUAL_MUT {
            test_err(&mut *p, m, sp, "the global test env is shared: take it as '&', not '&mut'".ptr() as *const char);
            return 0;
        }
        return 2;
    }
    test_err(&mut *p, m, sp, "this parameter matches neither the module's '@test_init' fixture nor the global env".ptr() as *const char);
    return 0;
}

// The inherent, non-generic extend whose items contain `fnode`, or NODE_NONE. `*bad` is set when it IS a
// method but of a conformance/generic extend (not suite-able).
fn test_owner_extend(p: &loader::Package, am: ModuleId, fnode: NodeId, bad: *mut bool) NodeId {
    let a = mod_ast_c(&*p, am);
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    let ids = unsafe (*a).list(items);
    for i in 0..items.len {
        let iid = unsafe ids[i as usize];
        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ed = unsafe (*a).at_const(iid).as_data.extend_def;
            let mids = unsafe (*a).list(ed.items);
            for j in 0..ed.items.len {
                if (unsafe mids[j as usize]) == fnode {
                    unsafe *bad = ed.interface_type != NODE_NONE || ed.generics.len != 0;
                    return iid;
                }
            }
        }
    }
    return NODE_NONE;
}

// Index of the (module, type) suite in plan.suites, creating it when `create`; -1 when absent / no-create.
fn plan_suite_of(plan: &mut TestPlan, m: ModuleId, ty: DefId, is_enum: bool, create: bool) i32 {
    for i in 0..plan.suites.len() {
        let s = plan.suites.at(i);
        if s.mod == m && s.ty.module == ty.module && s.ty.node == ty.node { return i as i32; }
    }
    if !create { return -1; }
    plan.suites.push(TestSuite { mod: m, ty: ty, is_enum: is_enum, init: NODE_NONE, fre: NODE_NONE });
    return (plan.suites.len() - 1) as i32;
}

// Collect + validate every @test/@test_init/@test_free in the package into a runnable plan.
fn test_plan_build(p: &mut loader::Package, plan: &mut TestPlan) void {
    let n = p.modules.len();
    // Pass 1: fixture producers/teardowns (module, suite, and global).
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude { continue; }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*(mod_ast_c(&*p, m as ModuleId))).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*(mod_ast_c(&*p, m as ModuleId))).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_INIT as u8 && at.kind != AttrKind::ATTR_TEST_FREE as u8 { continue; }
            let sp = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).span;
            let mut bad_ext = false;
            let ext = test_owner_extend(&*p, m as ModuleId, at.owner, (&mut bad_ext) as *mut bool);
            if ext != NODE_NONE && bad_ext {
                test_err(&mut *p, m as ModuleId, sp, "test attributes are only allowed on methods of a non-generic inherent 'extend'".ptr() as *const char);
                continue;
            }
            let mut target = DefId { module: 0, node: NODE_NONE };
            let mut target_is_enum = false;
            if ext != NODE_NONE {
                if at.arg != 0 {
                    test_err(&mut *p, m as ModuleId, sp, "'(global)' is not allowed on a method; declare the global pair at top level".ptr() as *const char);
                    continue;
                }
                let tt = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(ext).as_data.extend_def.target_type;
                target = test_type_decl(&*p, m as ModuleId, tt, (&mut target_is_enum) as *mut bool);
                if target.node == NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "a test suite's extend target must be a plain (non-generic) struct or enum".ptr() as *const char);
                    continue;
                }
            }
            if at.kind == AttrKind::ATTR_TEST_INIT as u8 {
                let plen = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).as_data.function.params.len;
                if plen != 0 {
                    test_err(&mut *p, m as ModuleId, sp, "'@test_init' takes no parameters".ptr() as *const char);
                    continue;
                }
                let mut is_enum = false;
                let ret = test_fn_ret_node(&*p, m as ModuleId, at.owner);
                let d = test_type_decl(&*p, m as ModuleId, ret, (&mut is_enum) as *mut bool);
                if d.node == NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "'@test_init' must return a plain (non-generic) struct or enum fixture".ptr() as *const char);
                    continue;
                }
                if ext != NODE_NONE {
                    if d.module != target.module || d.node != target.node {
                        test_err(&mut *p, m as ModuleId, sp, "a suite '@test_init' method must return the extended type itself".ptr() as *const char);
                        continue;
                    }
                    let si = plan_suite_of(&mut *plan, m as ModuleId, target, target_is_enum, true);
                    if plan.suites[si as usize].init != NODE_NONE {
                        test_err(&mut *p, m as ModuleId, sp, "duplicate suite '@test_init' (one per type per module)".ptr() as *const char);
                        continue;
                    }
                    plan.suites[si as usize].init = at.owner;
                } else if at.arg != 0 {
                    if plan.genv_init != NODE_NONE {
                        test_err(&mut *p, m as ModuleId, sp, "duplicate '@test_init(global)' (one per test tree)".ptr() as *const char);
                        continue;
                    }
                    plan.genv_mod = m as ModuleId; plan.genv_init = at.owner; plan.genv_type = d; plan.genv_is_enum = is_enum;
                } else {
                    if (plan.fx_init[m]) != NODE_NONE {
                        test_err(&mut *p, m as ModuleId, sp, "duplicate '@test_init' (one per module)".ptr() as *const char);
                        continue;
                    }
                    plan.fx_init[m] = at.owner;
                    plan.fx_type[m] = d;
                    plan.fx_is_enum[m] = is_enum;
                }
            } else {
                if ext == NODE_NONE { continue; }
                let mut ok = false;
                let params = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).as_data.function.params;
                if params.len == 1 && test_fn_returns_nothing(&*p, m as ModuleId, src, at.owner) {
                    let p0 = unsafe ((*(mod_ast_c(&*p, m as ModuleId))).list(params))[0];
                    let pty = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(p0).as_data.parameter.ty;
                    let ptk = if pty != NODE_NONE { unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(pty).kind; } else { NodeKind::NODE_NONE_KIND; };
                    if pty != NODE_NONE && ptk == NodeKind::NODE_REFERENCE_TYPE {
                        let it = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(pty).as_data.indirect_type;
                        let mut ie = false;
                        let d = test_type_decl(&*p, m as ModuleId, it.ty, (&mut ie) as *mut bool);
                        ok = it.qualifier == TypeQualifier::TYPE_QUAL_MUT && d.module == target.module && d.node == target.node;
                    }
                }
                if !ok {
                    test_err(&mut *p, m as ModuleId, sp, "a suite '@test_free' must be 'fn(self: &mut <the extended type>)' returning nothing".ptr() as *const char);
                    continue;
                }
                let si = plan_suite_of(&mut *plan, m as ModuleId, target, target_is_enum, true);
                if plan.suites[si as usize].fre != NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "duplicate suite '@test_free'".ptr() as *const char);
                    continue;
                }
                plan.suites[si as usize].fre = at.owner;
            }
        }
    }
    // Top-level @test_free, after every init is known.
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude { continue; }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*(mod_ast_c(&*p, m as ModuleId))).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*(mod_ast_c(&*p, m as ModuleId))).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_FREE as u8 { continue; }
            let mut be = false;
            if test_owner_extend(&*p, m as ModuleId, at.owner, (&mut be) as *mut bool) != NODE_NONE { continue; }
            let sp = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).span;
            let global = at.arg != 0;
            let want = if global { plan.genv_type; } else { plan.fx_type[m]; };
            let has_init = if global { plan.genv_init; } else { plan.fx_init[m]; };
            if has_init == NODE_NONE || (global && plan.genv_mod != m as ModuleId) {
                test_err(&mut *p, m as ModuleId, sp, if global { "'@test_free(global)' has no matching '@test_init(global)' in this module".ptr() as *const char; } else { "'@test_free' has no matching '@test_init' in this module".ptr() as *const char; });
                continue;
            }
            let mut ok = false;
            let params = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).as_data.function.params;
            if params.len == 1 && test_fn_returns_nothing(&*p, m as ModuleId, src, at.owner) {
                let p0 = unsafe ((*(mod_ast_c(&*p, m as ModuleId))).list(params))[0];
                let pty = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(p0).as_data.parameter.ty;
                let ptk = if pty != NODE_NONE { unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(pty).kind; } else { NodeKind::NODE_NONE_KIND; };
                if pty != NODE_NONE && ptk == NodeKind::NODE_REFERENCE_TYPE {
                    let it = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(pty).as_data.indirect_type;
                    let mut ie = false;
                    let d = test_type_decl(&*p, m as ModuleId, it.ty, (&mut ie) as *mut bool);
                    ok = it.qualifier == TypeQualifier::TYPE_QUAL_MUT && d.module == want.module && d.node == want.node;
                }
            }
            if !ok {
                test_err(&mut *p, m as ModuleId, sp, if global { "'@test_free(global)' must be 'fn(&mut <fixture>)' returning nothing".ptr() as *const char; } else { "'@test_free' must be 'fn(&mut <fixture>)' returning nothing".ptr() as *const char; });
                continue;
            }
            if global {
                if plan.genv_free != NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "duplicate '@test_free(global)'".ptr() as *const char);
                    continue;
                }
                plan.genv_free = at.owner;
            } else {
                if (plan.fx_free[m]) != NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "duplicate '@test_free' (one per module)".ptr() as *const char);
                    continue;
                }
                plan.fx_free[m] = at.owner;
            }
        }
    }
    // A suite teardown without a producer is an error.
    for si in 0..plan.suites.len() {
        let s = plan.suites[si];
        if s.init == NODE_NONE && s.fre != NODE_NONE {
            let sp = unsafe (*(mod_ast_c(&*p, s.mod))).at_const(s.fre).span;
            test_err(&mut *p, s.mod, sp, "a suite '@test_free' has no matching '@test_init' method on this type in this module".ptr() as *const char);
        }
    }
    // Pass 2: the tests themselves.
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude { continue; }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*(mod_ast_c(&*p, m as ModuleId))).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*(mod_ast_c(&*p, m as ModuleId))).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST as u8 { continue; }
            let sp = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).span;
            let mut bad_ext = false;
            let ext = test_owner_extend(&*p, m as ModuleId, at.owner, (&mut bad_ext) as *mut bool);
            if ext != NODE_NONE && bad_ext {
                test_err(&mut *p, m as ModuleId, sp, "test attributes are only allowed on methods of a non-generic inherent 'extend'".ptr() as *const char);
                continue;
            }
            let mut suite = DefId { module: 0, node: NODE_NONE };
            let mut suite_is_enum = false;
            if ext != NODE_NONE {
                let tt = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(ext).as_data.extend_def.target_type;
                suite = test_type_decl(&*p, m as ModuleId, tt, (&mut suite_is_enum) as *mut bool);
                if suite.node == NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "a test suite's extend target must be a plain (non-generic) struct or enum".ptr() as *const char);
                    continue;
                }
            }
            if !test_fn_returns_nothing(&*p, m as ModuleId, src, at.owner) {
                test_err(&mut *p, m as ModuleId, sp, "a '@test' function returns nothing".ptr() as *const char);
                continue;
            }
            let nmnode = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).as_data.function.name;
            let nmsp = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(nmnode).as_data.name.text;
            if ext == NODE_NONE && (nmsp.end - nmsp.start) == 4 && unsafe cstring::memcmp((src + nmsp.start as usize), "main".ptr(), 4) == 0 {
                test_err(&mut *p, m as ModuleId, sp, "'main' cannot be a '@test' (it is replaced by the test runner)".ptr() as *const char);
                continue;
            }
            let params = unsafe (*(mod_ast_c(&*p, m as ModuleId))).at_const(at.owner).as_data.function.params;
            if params.len > 2 {
                test_err(&mut *p, m as ModuleId, sp, "a '@test' function takes at most the fixture (or 'self') and the global env".ptr() as *const char);
                continue;
            }
            let fx = if ext != NODE_NONE { suite; } else { plan.fx_type[m]; };
            let genv_ty = if plan.genv_init != NODE_NONE { plan.genv_type; } else { DefId { module: 0, node: NODE_NONE }; };
            let mut wants: u8 = 0;
            let mut bad = false;
            let mut k: u32 = 0;
            while k < params.len && !bad {
                let pid = unsafe ((*(mod_ast_c(&*p, m as ModuleId))).list(params))[k as usize];
                let bit = test_param_bit(&mut *p, m as ModuleId, pid, fx, genv_ty);
                if bit == 0 { bad = true; }
                else if (wants & bit) != 0 {
                    test_err(&mut *p, m as ModuleId, sp, "duplicate '@test' parameter kind".ptr() as *const char);
                    bad = true;
                } else if bit == 1 && (wants & 2) != 0 {
                    test_err(&mut *p, m as ModuleId, sp, "the fixture ('self') parameter must come before the global env".ptr() as *const char);
                    bad = true;
                }
                wants = wants | bit;
                k = k + 1;
            }
            if bad { continue; }
            let mut suite_init = NODE_NONE;
            let mut suite_free = NODE_NONE;
            if ext != NODE_NONE && (wants & 1) != 0 {
                let si2 = plan_suite_of(&mut *plan, m as ModuleId, suite, suite_is_enum, false);
                if si2 < 0 || plan.suites[si2 as usize].init == NODE_NONE {
                    test_err(&mut *p, m as ModuleId, sp, "no '@test_init' method on this type in this module produces the receiver".ptr() as *const char);
                    continue;
                }
                suite_init = plan.suites[si2 as usize].init;
                suite_free = plan.suites[si2 as usize].fre;
            }
            let case_suite = if ext != NODE_NONE && (wants & 1) != 0 { suite; } else { DefId { module: 0, node: NODE_NONE }; };
            plan.cases.push(TestCase { mod: m as ModuleId, func: at.owner, should_panic: at.arg != 0, wants: wants, suite: case_suite, suite_is_enum: suite_is_enum, suite_init: suite_init, suite_free: suite_free });
        }
    }
    let pok = p.ok;
    plan.ok = plan.ok && pok;
}

// The fixed part of the generated test runner: option parsing, fork-per-test isolation with a waitpid job
// pool, an in-process fallback (--no-fork), substring selection, per-test reporting, and the exit code.
fn test_runner_main() *const char {
    return r#"static int sc_match(const char *name, const char *filter) {
  return !filter || strstr(name, filter) != NULL;
}
int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0); /* forked children must not inherit (and re-flush) buffered lines */
  int jobs = 0, no_fork = 0;
  const char *filter = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--jobs=", 7)) jobs = atoi(argv[i] + 7);
    else if (!strcmp(argv[i], "--no-fork")) no_fork = 1;
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
  }
  if (jobs < 1) { long n = sysconf(_SC_NPROCESSORS_ONLN); jobs = n > 0 ? (int)n : 1; }
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nsel = 0;
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter)) sel[nsel++] = i;
  printf("running %d test%s\n", nsel, nsel == 1 ? "" : "s");
  void *genv = NULL;
  if (nsel > 0) genv = sc_genv_init();
  int passed = 0, failed = 0, skipped = 0;
  if (no_fork) {
    for (int k = 0; k < nsel; k++) {
      const int i = sel[k];
      if (SC_TESTS[i].should_panic) {
        printf("test %s ... skipped (should_panic needs fork)\n", SC_TESTS[i].name);
        skipped++;
        continue;
      }
      SC_TESTS[i].fn(genv);
      printf("test %s ... ok\n", SC_TESTS[i].name);
      passed++;
    }
  } else {
    pid_t pid_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    int active = 0, next = 0;
    while (next < nsel || active > 0) {
      while (active < jobs && next < nsel) {
        const pid_t pid = fork();
        if (pid == 0) { SC_TESTS[sel[next]].fn(genv); _exit(0); }
        if (pid < 0) { perror("fork"); return 101; }
        pid_of[next++] = pid;
        active++;
      }
      int st = 0;
      const pid_t done = wait(&st);
      if (done < 0) break;
      active--;
      int ti = -1;
      for (int k = 0; k < next; k++)
        if (pid_of[k] == done) { ti = sel[k]; pid_of[k] = -1; break; }
      if (ti < 0) continue;
      const int crashed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
      if (crashed == SC_TESTS[ti].should_panic) {
        printf("test %s ... ok%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (panicked as expected)" : "");
        passed++;
      } else {
        printf("test %s ... FAILED%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (expected a panic)" : "");
        failed++;
      }
      fflush(stdout);
    }
  }
  if (genv) sc_genv_free(genv);
  if (skipped)
    printf("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped);
  else
    printf("\n%d passed, %d failed\n", passed, failed);
  return failed > 100 ? 100 : failed;
}
"#.ptr() as *const char;
}

// Write build/__test_main.c: extern wrapper prototypes, the test table (display names `module::fn` or
// `module::Type::method`), the global-env hooks (stubs when absent), and the fixed runner. Returns the
// path (ownership to the caller / keep-list), or null.
fn write_test_main(p: &mut loader::Package, plan: &TestPlan) Option<String> {
    let mut path = build_out_path(p.root_dir, "__test_main".ptr() as *const char, ".c".ptr() as *const char);
    let f = open_out(path.as_str());
    if f == null { unsafe stdio::perror(path.cstr()); return Option::<String>::None; }
    unsafe stdio::fputs("/* generated by super-c --test */\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n#include <sys/wait.h>\n\n".ptr() as *const char, f);
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        unsafe stdio::fprintf(f, "extern void __sc_test_w_%u_%u(void *);\n".ptr() as *const char, tc.mod as u32, tc.func);
    }
    unsafe stdio::fputs("\ntypedef void (*sc_test_fn)(void *);\nstatic const struct { const char *name; sc_test_fn fn; int should_panic; } SC_TESTS[] = {\n".ptr() as *const char, f);
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        let a = mod_ast_c(&*p, tc.mod);
        let nmnode = unsafe (*a).at_const(tc.func).as_data.function.name;
        let nm = unsafe (*a).at_const(nmnode).as_data.name.text;
        let modpath = p.modules[tc.mod as usize].path;
        let msrc = p.modules[tc.mod as usize].source.as_str().ptr() as *const char;
        unsafe stdio::fprintf(f, "  { \"%s::".ptr() as *const char, modpath);
        if tc.suite.node != NODE_NONE {
            let sa = mod_ast_c(&*p, tc.suite.module);
            let snmn = unsafe (*sa).at_const(tc.suite.node).as_data.aggregate.name;
            let snm = unsafe (*sa).at_const(snmn).as_data.name.text;
            let ssrc = p.modules[tc.suite.module as usize].source.as_str().ptr() as *const char;
            unsafe stdio::fprintf(f, "%.*s::".ptr() as *const char, (snm.end - snm.start) as i32, unsafe (ssrc + snm.start as usize));
        }
        let spflag = if tc.should_panic { 1 as i32; } else { 0 as i32; };
        unsafe stdio::fprintf(f, "%.*s\", __sc_test_w_%u_%u, %d },\n".ptr() as *const char, (nm.end - nm.start) as i32, unsafe (msrc + nm.start as usize), tc.mod as u32, tc.func, spflag);
    }
    unsafe stdio::fprintf(f, "};\nenum { SC_NTESTS = %zu };\n\n".ptr() as *const char, plan.cases.len());
    if plan.genv_init != NODE_NONE {
        unsafe stdio::fputs("extern void *__sc_test_genv_init(void);\nextern void __sc_test_genv_free(void *);\nstatic void *sc_genv_init(void) { return __sc_test_genv_init(); }\nstatic void sc_genv_free(void *p) { __sc_test_genv_free(p); }\n\n".ptr() as *const char, f);
    } else {
        unsafe stdio::fputs("static void *sc_genv_init(void) { return NULL; }\nstatic void sc_genv_free(void *p) { (void)p; }\n\n".ptr() as *const char, f);
    }
    unsafe stdio::fputs(test_runner_main(), f);
    unsafe stdio::fclose(f);
    return Option::<String>::Some(path);
}


// Compile the emitted build tree with $CC. When `out_bin` is set (the `build` subcommand) the program is
// linked to that path and we return; otherwise it links `<root>/build/__tests` and runs it as the test
// runner, forwarding `topts`' options.
fn test_build_and_run(p: &loader::Package, topts: *const TestOpts, keep: &Vector<String>, out_bin: *const char) i32 {
    let mut cc = stdlib::getenv("CC");
    if cc == null || (unsafe *cc) == (0 as char) { cc = "cc".ptr() as *const char; }
    let root = p.root_dir;
    let mut cmd = String::new();
    cmd.push_str(str::from_cstr(cc));
    if out_bin != null {
        cmd.push_str(" -std=c11 -o '");
        cmd.push_str(str::from_cstr(out_bin));
        cmd.push_str("'");
    } else {
        cmd.push_str(" -std=c11 -o '");
        cmd.push_str(str::from_cstr(root));
        cmd.push_str("/build/__tests'");
    }
    for i in 0..keep.len() {
        let cf = keep[i].as_str();
        if cf.len() > 2 && cf.ends_with(".c") {
            cmd.push_str(" '");
            cmd.push_str(cf);
            cmd.push_str("'");
        }
    }
    // @c.link flags (one per line in build/__ldflags)
    let ldpath = build_out_path(root, "__ldflags".ptr() as *const char, "".ptr() as *const char);
    let lf = stdio::fopen(ldpath.as_str(), "rb");
    if lf != null {
        let mut line = PathBuf {};
        while unsafe stdio::fgets((&mut line.b[0]) as *mut char, 4096, lf) != null {
            let ll = unsafe cstring::strlen((&line.b[0]) as *const char);
            if ll > 0 && unsafe line.b[ll - 1] == ('\n' as char) { unsafe line.b[ll - 1] = 0 as char; }
            if unsafe line.b[0] != (0 as char) { cmd.push_str(" "); cmd.push_str(str::from_cstr((&line.b[0]) as *const char)); }
        }
        unsafe stdio::fclose(lf);
    }
    let brc = stdlib::system(cmd.as_str());
    if brc != 0 {
        let mut what = "test build".ptr() as *const char;
        if out_bin != null { what = "build".ptr() as *const char; }
        unsafe stdio::fprintf(stdio::stderr(), "super-c: %s failed (%s)\n".ptr() as *const char, what, cc);
        return 1;
    }
    if out_bin != null { return 0; } // the `build` subcommand: linked the program, nothing to run
    let mut run = String::new();
    run.push_str("'");
    run.push_str(str::from_cstr(root));
    run.push_str("/build/__tests'");
    if unsafe (*topts).jobs > 0 {
        let mut jb = Buf64 {};
        unsafe stdio::snprintf((&mut jb.b[0]) as *mut char, 64, " --jobs=%d".ptr() as *const char, unsafe (*topts).jobs);
        run.push_str(str::from_cstr((&jb.b[0]) as *const char));
    }
    if unsafe (*topts).no_fork { run.push_str(" --no-fork"); }
    if unsafe (*topts).filter != null {
        run.push_str(" '--filter=");
        run.push_str(str::from_cstr(unsafe (*topts).filter));
        run.push_str("'");
    }
    let rrc = stdlib::system(run.as_str());
    if rrc < 0 { return 1; }
    if unsafe shim::sc_wifexited(rrc) != 0 { return unsafe shim::sc_wexitstatus(rrc); }
    return 1;
}

// One module's test-plan slice, kept alive across codegen_emit (CgTestInfo holds a pointer into it).
struct TCases { pub c: [cg::CgTestCase; 512] }

// ---------------------------------------------------------------------------------------------------------
// Global-phase compilation of a loaded package into a `<root>/build/` tree.
// ---------------------------------------------------------------------------------------------------------
fn run_package(p: &mut loader::Package, topts: *const TestOpts, out_bin: *const char) i32 {
    let n = p.modules.len();
    for i in 0..n {
        let ok = resolve_module(&mut *p, i);
        p.ok = ok && p.ok;
    }
    if !p.ok { return 1; }
    for i in 0..n {
        let ok = typecheck_module(&mut *p, i);
        p.ok = ok && p.ok;
    }
    if !p.ok { return 1; }
    // static_asserts undecidable in module order re-evaluate now that every module is fully typed.
    let ceptr = p.ceval as *mut ce::ConstEval;
    if ceptr != null {
        let pv = (&mut *p) as *mut loader::Package;
        unsafe (*ceptr).flush_asserts(flush_assert_err, pv as *mut void);
    }
    if !p.ok { return 1; }
    loader::package_propagate_instances(&mut *p);

    let testing = topts != null && unsafe (*topts).enabled;
    let mut plan = TestPlan::new(n);
    if testing {
        test_plan_build(&mut *p, &mut plan);
        if !plan.ok { return 1; }
    }

    write_super_rt(p.root_dir);
    let root = p.root_dir;
    let mut keep = Vector::<String>::new();
    keep.push(build_out_path(root, "super_rt".ptr() as *const char, ".h".ptr() as *const char));
    let mut err = false;
    // `@c.source` wrapper TUs land in keep[]; `@c.link` flags feed build/__ldflags for the link line.
    ext_c_collect(&mut *p, &mut keep, (&mut err) as *mut bool);
    let live = compute_emit_live(&*p);
    let osz = if n != 0 { n; } else { 1 as usize; };
    let order = unsafe stdlib::malloc(osz * 2) as *mut ModuleId;
    if order == null {
        if live != null { unsafe stdlib::free(live as *mut void); }
        return 1;
    }
    loader::package_emit_order(&*p, order);
    for oi in 0..n {
        let mi = unsafe order[oi];
        if live != null && !(unsafe live[mi as usize]) { continue; }
        let m_ast = mod_ast_m(&mut *p, mi);
        let src = p.modules[mi as usize].source.as_str().ptr() as *const char;
        let slen = p.modules[mi as usize].source.len();
        let mpath = p.modules[mi as usize].path;
        let pkg = (&mut *p) as *mut loader::Package;
        let mut c = cg::Codegen::new(m_ast, str::from_raw(src as *const u8, slen), pkg);
        c.set_multifile(true);
        let mut tcases = TCases {};  // must outlive codegen_emit (CgTestInfo keeps a pointer into it)
        if testing {
            let mut nt: u32 = 0;
            let mut tk: usize = 0;
            while tk < plan.cases.len() && nt < 512 {
                let tc = plan.cases[tk];
                if tc.mod == mi {
                    tcases.c[nt as usize] = cg::CgTestCase { func: tc.func, wants: tc.wants, suite: tc.suite, suite_is_enum: tc.suite_is_enum, suite_init: tc.suite_init, suite_free: tc.suite_free };
                    nt = nt + 1;
                }
                tk = tk + 1;
            }
            let gi = if plan.genv_mod == mi { plan.genv_init; } else { NODE_NONE; };
            let gf = if plan.genv_mod == mi { plan.genv_free; } else { NODE_NONE; };
            let ti = cg::CgTestInfo {
                enabled: true, cases: (&tcases.c[0]) as *const cg::CgTestCase, ncases: nt,
                fx_init: plan.fx_init[mi as usize], fx_free: plan.fx_free[mi as usize],
                fx_type: plan.fx_type[mi as usize], fx_is_enum: plan.fx_is_enum[mi as usize],
                genv_init: gi, genv_free: gf, genv_type: plan.genv_type, genv_is_enum: plan.genv_is_enum,
            };
            c.set_test_info((&ti) as *const cg::CgTestInfo);
        }
        let hpath = build_out_path(root, mpath, ".h".ptr() as *const char);
        let hout = open_out(hpath.as_str());
        if hout != null { c.codegen_emit_header(hout); unsafe stdio::fclose(hout); }
        keep.push(hpath);
        let mut opath = build_out_path(root, mpath, ".c".ptr() as *const char);
        let out = open_out(opath.as_str());
        if out == null {
            unsafe stdio::perror(opath.cstr());
            err = true;
        } else {
            c.codegen_emit(out);
            unsafe stdio::fclose(out);
            if c.has_errors() { c.log_errors(); err = true; }
        }
        keep.push(opath);
    }
    unsafe stdlib::free(order as *mut void);
    if live != null { unsafe stdlib::free(live as *mut void); }
    // Drop outputs from a previous build that this program no longer emits, so the tree matches the current
    // sources. Skip on a keep-list OOM -- never risk deleting a live output.
    let mut broot = PathBuf { };
    let bn = unsafe stdio::snprintf((&mut broot.b[0]) as *mut char, 4096, "%s/build".ptr() as *const char, root);
    if bn > 0 && (bn as usize) < 4096 { prune_orphans((&broot.b[0]) as *const char, &keep); }
    let mut rc: i32 = if err { 1; } else { 0 as i32; };
    if out_bin != null {
        if !err { rc = test_build_and_run(&*p, null as *const TestOpts, &keep, out_bin); }
    } else if testing && !err {
        if plan.cases.len() == 0 {
            unsafe stdio::fputs("super-c: no '@test' functions found\n".ptr() as *const char, stdio::stderr());
            rc = 1;
        } else {
            switch write_test_main(&mut *p, &plan) {
                Some(runner) => { keep.push(runner); rc = test_build_and_run(&*p, topts, &keep, null as *const char); },
                None => { rc = 1; },
            };
        }
    }
    return rc;
}

fn run_file(path: *const char, std_dir: *const char, ce_steps: u32, ce_mem: u64, topts: *const TestOpts, out_bin: *const char) i32 {
    let mut p = loader::package_load(path, std_dir);
    let mut rc: i32 = 1;
    if p.ok {
        let pkg = (&mut p) as *mut loader::Package;
        let mut ceval = ce::ConstEval::new(pkg, ce_steps, ce_mem);
        p.ceval = (&mut ceval) as *mut void;
        rc = run_package(&mut p, topts, out_bin);
        ceval.free();
    }
    p.free();
    return rc;
}

// "1024", "64K", "16M", "1G" -> bytes; 0 on malformed input.
fn parse_size(s: *const char) u64 {
    let mut endp: *mut char = null;
    let v = unsafe stdlib::strtoul(s, (&mut endp) as *mut void, 10);
    if (endp as usize) == (s as usize) || v == 0 { return 0; }
    let mut mul: u64 = 1;
    let mut e = endp;
    let c = unsafe *endp;
    if c == ('K' as char) || c == ('k' as char) { mul = 1024; e = unsafe (endp + 1); }
    else if c == ('M' as char) || c == ('m' as char) { mul = (1024 * 1024) as u64; e = unsafe (endp + 1); }
    else if c == ('G' as char) || c == ('g' as char) { mul = (1024 * 1024 * 1024) as u64; e = unsafe (endp + 1); }
    if (unsafe *e) == (0 as char) { return v * mul; }
    return 0;
}

// The std/ directory next to the running binary ("<exe dir>/std"), so the prelude is found regardless of cwd.
fn exe_std_dir(argv0: *const char) *mut char {
    let mut buf = PathBuf { };
    let mut path = argv0;
    if unsafe shim::sc_exe_path((&mut buf.b[0]) as *mut char, 4096) == 0 { path = (&buf.b[0]) as *const char; }
    let slash = unsafe cstring::strrchr(path, '/' as i32);
    let dirlen = if slash != null { (slash as usize) - (path as usize); } else { 1 as usize; };
    let out = unsafe stdlib::malloc(dirlen + 5) as *mut char;
    if out == null { return null; }
    if slash != null { unsafe cstring::memcpy(out as *mut void, path, dirlen); }
    else { unsafe out[0] = '.' as char; }
    unsafe cstring::memcpy((out + dirlen) as *mut void, "/std".ptr(), 4);
    unsafe out[dirlen + 4] = 0 as char;
    return out;
}

fn main() i32 {
    let argc = unsafe shim::sc_argc();
    let argv = unsafe shim::sc_argv();
    let mut ce_steps: u32 = 0;
    let mut ce_mem: u64 = 0;
    let mut file: *const char = null;
    let mut out_bin: *const char = null; // set by the `build` subcommand (via -o, or defaulted)
    let mut build_mode = false;
    let mut topts = TestOpts { enabled: false, jobs: 0, no_fork: false, filter: null };
    let mut bad = false;
    let mut i: i32 = 1;
    while i < argc {
        let arg = unsafe argv[i as usize] as *const char;
        if !build_mode && file == null && unsafe cstring::strcmp(arg, "build".ptr() as *const char) == 0 {
            build_mode = true; // `super-c build <root.spc> [-o out]`: emit + link a program
        } else if unsafe cstring::strcmp(arg, "-o".ptr() as *const char) == 0 {
            if i + 1 < argc { i = i + 1; out_bin = unsafe argv[i as usize] as *const char; }
            else { bad = true; }
        } else if unsafe cstring::strncmp(arg, "--const-eval-steps=".ptr() as *const char, 19) == 0 {
            let v = parse_size(unsafe (arg + 19));
            if v == 0 || v > 4294967295u64 { bad = true; }
            else { ce_steps = v as u32; }
        } else if unsafe cstring::strncmp(arg, "--const-eval-memory=".ptr() as *const char, 20) == 0 {
            ce_mem = parse_size(unsafe (arg + 20));
            if ce_mem == 0 { bad = true; }
        } else if unsafe cstring::strcmp(arg, "--test".ptr() as *const char) == 0 {
            topts.enabled = true;
        } else if unsafe cstring::strncmp(arg, "--test-jobs=".ptr() as *const char, 12) == 0 {
            topts.jobs = unsafe stdlib::atoi(arg + 12);
            if topts.jobs < 1 { bad = true; }
        } else if unsafe cstring::strcmp(arg, "--test-no-fork".ptr() as *const char) == 0 {
            topts.no_fork = true;
        } else if unsafe cstring::strncmp(arg, "--test-filter=".ptr() as *const char, 14) == 0 {
            topts.filter = unsafe (arg + 14);
        } else if (unsafe arg[0]) == ('-' as char) && (unsafe arg[1]) == ('-' as char) {
            bad = true;
        } else if file == null {
            file = arg;
        } else {
            file = "".ptr() as *const char;
        }
        i = i + 1;
    }
    if !topts.enabled && (topts.jobs != 0 || topts.no_fork || topts.filter != null) { bad = true; }
    if out_bin != null && !build_mode { bad = true; }   // -o is only meaningful for `build`
    if build_mode && topts.enabled { bad = true; }      // `build` and `--test` are mutually exclusive
    if build_mode && out_bin == null { out_bin = "a.out".ptr() as *const char; } // cc-style default
    if bad || file == null || (unsafe *file) == (0 as char) {
        unsafe stdio::fputs(
            "Usage: super-c [--const-eval-steps=N] [--const-eval-memory=BYTES[K|M|G]]\n       [--test [--test-jobs=N] [--test-no-fork] [--test-filter=S]] <path/to/script>\n       super-c build [-o <out>] <path/to/script>\n".ptr() as *const char,
            stdio::stderr());
        return 1;
    }
    let arg0: *const char = if argc > 0 { unsafe argv[0] as *const char; } else { "super-c".ptr() as *const char; };
    let std_dir = exe_std_dir(arg0);
    let rc = run_file(file, std_dir as *const char, ce_steps, ce_mem, (&topts) as *const TestOpts, out_bin);
    if std_dir != null { unsafe stdlib::free(std_dir as *mut void); }
    return rc;
}
