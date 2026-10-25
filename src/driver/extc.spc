// External C libraries: `@link` values become `-l<v>` (verbatim when starting with '-'), written with the
// runtime's own libm on POSIX to `build/<profile>/raw/__ldflags` for the final link line.
import stdio;
import ast::ast as *;
import std::platform::fs;
import module::loader as loader;
import driver::util as *;
import target::table as tgt;

/// Scan every module for `@link` and write the flags to `<gen_root>/__ldflags` (removed when none). A C
/// library comes prebuilt and reaches the link through `@link` only: no C source of the program's tree is
/// compiled. Sets `*err` on a write failure; an already-set value is never cleared.
pub(package) fn ext_c_collect(p: &mut loader::Package, err: &mut bool, target: i32) {
    let root = p.gen_root.as_str();
    let mut ld = Vector::<String>::new();
    // Libm, on every POSIX link line: the prelude's float methods (`f64::fma` and friends) are emitted into
    // every program whether or not it calls them, and glibc keeps those out of libc, so the link fails
    // without it, which macOS hides because libSystem has them. It is seeded here rather than as a
    // `@link` on the prelude's extern block because that block DECLARES the functions for every target,
    // Windows included: gating it to carry the flag would take the declarations away from Windows, whose
    // CRT provides the functions and has no libm to name. wasm links its own C library, `std::rt::libm`.
    let libm = tgt::os(target).libm;
    if libm.len() != 0 {
        ld.push(String::from_str(libm));
    }
    let n = p.modules.len();
    for m in 0..n {
        if !p.modules[m].has_ast {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let ap = p.module_ast_const(m as ModuleId);
        // Live top-level items, after `platform_filter` compacted `program.items`: a `@platform`-gated-out
        // `@link` leaves its attr in the table, so skip attrs whose owning item is gone (else every OS
        // would take every other OS's `-l` flags).
        let rootn = unsafe (*ap).root;
        let live = unsafe (*ap).at_const(rootn).as_data.program.items;
        let live_ids = unsafe (*ap).list(live);
        for ai in 0..unsafe (*ap).attrs.len() {
            let at = unsafe (*ap).attrs[ai];
            if at.kind != AttrKind::ATTR_C_LINK as u8 || at.str_span.end <= at.str_span.start {
                continue;
            }
            if at.owner != rootn {
                let mut owner_live = false;
                for li in 0..live.len {
                    if unsafe live_ids[li as usize] == at.owner {
                        owner_live = true;
                        break;
                    }
                }
                if !owner_live {
                    continue;
                }
            }
            let vl = (at.str_span.end - at.str_span.start) as i32;
            let v = unsafe (src + at.str_span.start);
            let mut flag = String::new();
            if unsafe *v != '-' as char {
                flag.push_str("-l");
            }
            flag.push_str(unsafe str::from_raw(v as *const u8, vl as usize));
            let mut dup = false;
            for k in 0..ld.len() {
                if ld[k].as_str() == flag.as_str() {
                    dup = true;
                    break;
                }
            }
            if !dup {
                ld.push(flag);
            }
        }
    }
    let mut ldpath = build_out_path(root, "__ldflags", "");
    if ld.len() != 0 {
        let f = stdio::fopen(ldpath.as_str(), "wb"); // binary: no CRLF so linker flags read back clean on Windows
        let mut ok = f != null;
        if ok {
            for k in 0..ld.len() {
                ok = unsafe stdio::fprintf(f, "%s\n".ptr() as *const char, ld[k].cstr()) >= 0 && ok;
            }
            ok = unsafe stdio::fclose(f) == 0 && ok;
        }
        if !ok {
            unsafe stdio::perror(ldpath.cstr());
            *err = true;
        }
    } else {
        let _ = fs::unlink(ldpath.as_str());
    }
}
