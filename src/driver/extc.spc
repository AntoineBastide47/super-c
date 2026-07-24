// External C sources/libs: turns every @c.source (and implicit extern-block backing-header .c sibling)
// into a build/ wrapper TU on the emit keep-list, and writes the deduped @c.link flags to build/__ldflags
// for the final link line.
import stdio;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
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
import driver::util as *;

// ---------------------------------------------------------------------------------------------------------
// External C sources/libs: `@c.source`/`@c.link` attrs + implicit backing-header `.c` siblings. Each resolved
// source becomes a wrapper TU `build/__ext<N>_<stem>.c` (one absolute #include; the file stays in place so its
// own relative includes keep resolving), deduped by resolved path. `@c.link` values become `-l<v>` (verbatim
// when starting with '-'), written to `build/__ldflags`.
// ---------------------------------------------------------------------------------------------------------

// "<dir of file>/<v[0..vl]>" (or "<v>") into `out` (a 4096-byte buffer).
fn ext_rel(file: *const char, v: *const char, vl: i32, out: *mut char) {
    let mut slash: *mut char = null;
    if file != null {
        slash = unsafe cstring::strrchr(file, '/');
    }
    if slash != null {
        let dlen = (slash as usize - file as usize) as i32;
        unsafe stdio::snprintf(out, 4096, "%.*s/%.*s".ptr() as *const char, dlen, file, vl, v);
    } else {
        unsafe stdio::snprintf(out, 4096, "%.*s".ptr() as *const char, vl, v);
    }
}

// Wrap one RESOLVED external C source path `rsl` into a build/ TU (deduped across explicit + implicit adds).
fn ext_c_wrap(
    root: str,
    keep: &mut Vector<String>,
    seen: &mut Vector<String>,
    nsrc: *mut u32,
    rsl: *const char,
    err: *mut bool,
) {
    for k in 0..seen.len() {
        if seen[k].as_str() == str::from_cstr(rsl) {
            return;
        }
    }
    seen.push(String::from_cstr(rsl));
    let mut basep = (unsafe cstring::strrchr(rsl, '/')) as *const char;
    if basep != null {
        basep = unsafe (basep + 1);
    } else {
        basep = rsl;
    }
    let mut stem = Buf64 {};
    let mut sl: usize = 0;
    let mut sp = basep;
    while unsafe *sp != 0 as char && unsafe *sp != '.' as char && sl < 63 {
        let c = unsafe *sp;
        let good = c >= 'a' as char && c <= 'z' as char || c >= 'A' as char && c <= 'Z' as char || c >= '0' as char && c <= '9' as char;
        stem[sl] = if good {
            c;
        } else {
            '_' as char;
        };
        sl = sl + 1;
        sp = unsafe (sp + 1);
    }
    stem[sl] = 0 as char;
    let mut nm = Buf128 {};
    let idx = unsafe *nsrc;
    unsafe *nsrc = idx + 1;
    unsafe stdio::snprintf(&mut nm[0], 128, "__ext%u_%s".ptr() as *const char, idx, &stem[0]);
    let mut path = build_out_path(root, str::from_cstr(&nm[0]), ".c");
    let f = open_out(path.as_str());
    if f == null {
        unsafe stdio::perror(path.cstr());
        unsafe *err = true;
        return;
    }
    unsafe stdio::fprintf(
        f,
        "/* external C source pulled into the build -- generated, do not edit */\n#include \"%s\"\n".ptr() as *const char,
        rsl,
    );
    unsafe stdio::fclose(f);
    keep.push(path);
}

/// Scan every module for @c.source/@c.link and implicit backing-header `.c` siblings: wrapper TUs are
/// written under gen_root and pushed onto `keep`; link flags go to build/__ldflags (removed when none).
/// Sets `*err` on an unresolvable source or a write failure; already-set values are never cleared.
pub fn ext_c_collect(p: &mut loader::Package, keep: &mut Vector<String>, err: *mut bool) {
    let root = p.gen_root.as_str();
    let mut ld = Vector::<String>::new();
    let mut seen = Vector::<String>::new();
    let mut nsrc: u32 = 0;
    let n = p.modules.len();
    for m in 0..n {
        if !p.modules[m].has_ast {
            continue;
        }
        let file = p.modules[m].file.cstr();
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let ap = mod_ast_c(p, m as ModuleId);
        for ai in 0..unsafe (*ap).attrs.len() {
            let at = unsafe (*ap).attrs[ai];
            let is_src = at.kind == AttrKind::ATTR_C_SOURCE as u8;
            let is_link = at.kind == AttrKind::ATTR_C_LINK as u8;
            if !is_src && !is_link || at.str_span.end <= at.str_span.start {
                continue;
            }
            let vl = (at.str_span.end - at.str_span.start) as i32;
            let v = unsafe (src + at.str_span.start);
            if is_link {
                let mut flag = Buf128 {};
                if unsafe *v == '-' as char {
                    unsafe stdio::snprintf(&mut flag[0], 128, "%.*s".ptr() as *const char, vl, v);
                } else {
                    unsafe stdio::snprintf(&mut flag[0], 128, "-l%.*s".ptr() as *const char, vl, v);
                }
                let mut dup = false;
                for k in 0..ld.len() {
                    if ld[k].as_str() == str::from_cstr(&flag[0]) {
                        dup = true;
                        break;
                    }
                }
                if !dup {
                    ld.push(String::from_cstr(&flag[0]));
                }
                continue;
            }
            let mut rel = PathBuf {};
            let mut rsl = PathBuf {};
            ext_rel(file, v, vl, &mut rel[0]);
            if unsafe shim::sc_realpath(&rel[0], &mut rsl[0]) == null {
                unsafe stdio::snprintf(&mut rel[0], 4096, "%.*s".ptr() as *const char, vl, v);
                if unsafe shim::sc_realpath(&rel[0], &mut rsl[0]) == null {
                    unsafe stdio::fprintf(
                        stdio::stderr(),
                        "error: cannot find C source '%.*s'\n".ptr() as *const char,
                        vl,
                        v,
                    );
                    unsafe *err = true;
                    continue;
                }
            }
            ext_c_wrap(root, keep, &mut seen, &mut nsrc, &rsl[0], err);
        }
        // Implicit sources: a backing header that resolves next to this module with a same-stem `.c` sibling.
        let items = unsafe (*ap).at_const((*ap).root).as_data.program.items;
        let ids = unsafe (*ap).list(items);
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let nk = unsafe (*ap).at_const(nid).kind;
            let hdr = if nk == NodeKind::NODE_EXTERN_BLOCK {
                unsafe (*ap).at_const(nid).as_data.extern_block.header;
            } else {
                NODE_NONE;
            };
            if hdr == NODE_NONE {
                continue;
            }
            let hs = unsafe (*ap).at_const(hdr).span;
            let hl = (hs.end - hs.start) as i32 - 2;
            if hl <= 2 {
                continue;
            }
            let hv = unsafe (src + (hs.start + 1));
            let mut rel = PathBuf {};
            let mut habs = PathBuf {};
            ext_rel(file, hv, hl, &mut rel[0]);
            if unsafe shim::sc_realpath(&rel[0], &mut habs[0]) == null {
                continue;
            }
            let dot = unsafe cstring::strrchr(&rel[0], '.');
            if dot == null {
                continue;
            }
            let dotoff = dot as usize - (&rel[0]) as usize;
            if dotoff + 2 >= 4096 {
                continue;
            }
            {
                rel[dotoff] = '.' as char;
                rel[dotoff + 1] = 'c' as char;
                rel[dotoff + 2] = 0 as char;
            }
            let mut cabs = PathBuf {};
            if unsafe shim::sc_realpath(&rel[0], &mut cabs[0]) != null {
                ext_c_wrap(root, keep, &mut seen, &mut nsrc, &cabs[0], err);
            }
        }
    }
    let mut ldpath = build_out_path(root, "__ldflags", "");
    if ld.len() != 0 {
        let f = stdio::fopen(ldpath.as_str(), "wb"); // binary: no CRLF so linker flags read back clean on Windows
        if f != null {
            for k in 0..ld.len() {
                unsafe stdio::fprintf(f, "%s\n".ptr() as *const char, ld[k].cstr());
            }
            unsafe stdio::fclose(f);
        }
    } else {
        let _ = unsafe shim::sc_unlink(ldpath.cstr());
    }
}
