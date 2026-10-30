// The std package checker. It reads `<std>/packages.toml` and every `.spc` file under `<std>`, and reports
// each violation of the rules that file's header states, one line each (`path:line: message`): a file whose
// package has no row, an upward tier edge, a cyclic tier edge, and platform FFI outside the exemptions.
//
//   std-packages [STD_DIR]        (STD_DIR: `std`)
//
// Exit status: 0 without a violation, 1 with one, 2 on a usage, read or manifest error.
import files as *;
import manifest as *;
import scan as *;

const NO_PKG: usize = usize::MAX;
const UNVISITED: usize = usize::MAX;

// One `.spc` file under the std directory.
struct Module {
    pub rel: String, // its path under the std directory: `parallel/io.spc`
    pub path: String, // `std::parallel::io`
    pub name: String, // its path inside its package: `io`, `math::fast`; a prelude module's file stem
    pub pkg: usize, // its package row, NO_PKG when the package has none
    pub items: Scan,
}

// An import of one std module by another.
struct Edge {
    pub from: usize,
    pub to: usize,
    pub line: u32,
}

fn main(args: Vector<str>) i32 {
    if args.len() > 2 || args.len() == 2 && args[1].starts_with("-") {
        eprintln("usage: std-packages [STD_DIR]");
        return 2;
    }
    let dir = if args.len() == 2 {
        args[1]
    } else {
        "std"
    };
    let toml_path = format("{}/packages.toml", dir);
    let toml = read_file(&toml_path);
    if toml.is_none() {
        eprintln("std-packages: cannot read {}", toml_path.as_str());
        return 2;
    }
    let mr = read_manifest(toml.unwrap().as_str());
    if mr.is_err() {
        eprintln("{}:{}", toml_path.as_str(), mr.unwrap_err().as_str());
        return 2;
    }
    let man = mr.unwrap();
    let mut rels = Vector::<String>::new();
    if !list_spc(dir, &mut rels) {
        eprintln("std-packages: cannot read the directories under {}", dir);
        return 2;
    }
    let mut mods = Vector::<Module>::new();
    for rel in rels.iter() {
        let text = read_file(format("{}/{}", dir, rel.as_str()).as_str());
        if text.is_none() {
            eprintln("std-packages: cannot read {}/{}", dir, rel.as_str());
            return 2;
        }
        mods.push(Module::new(rel.as_str(), &man, scan(text.unwrap().as_str())));
    }

    let mut diags = Vector::<String>::new();
    let mut edges = Vector::<Edge>::new();
    for m in 0..mods.len() {
        check_module(dir, &man, &mods, m, &mut edges, &mut diags);
    }
    let comp = components(mods.len(), &edges);
    for e in edges.iter() {
        let from = &mods[e.from];
        let to = &mods[e.to];
        if man.packages[from.pkg].tier < man.packages[to.pkg].tier {
            diags.push(
                format(
                    "{}/{}:{}: upward tier edge: {} (package {}, tier {}) imports {} (package {}, tier {})",
                    dir,
                    from.rel.as_str(),
                    e.line,
                    from.path.as_str(),
                    man.packages[from.pkg].name.as_str(),
                    man.packages[from.pkg].tier,
                    to.path.as_str(),
                    man.packages[to.pkg].name.as_str(),
                    man.packages[to.pkg].tier,
                ),
            );
        }
        if comp[e.from] == comp[e.to] && from.pkg != to.pkg {
            diags.push(
                format(
                    "{}/{}:{}: cyclic tier edge: {} (package {}) imports {} (package {}), which imports it back",
                    dir,
                    from.rel.as_str(),
                    e.line,
                    from.path.as_str(),
                    man.packages[from.pkg].name.as_str(),
                    to.path.as_str(),
                    man.packages[to.pkg].name.as_str(),
                ),
            );
        }
    }
    check_rows(&toml_path, &man, &mods, &mut diags);

    for d in diags.iter() {
        eprintln("{}", d.as_str());
    }
    if !diags.is_empty() {
        eprintln(
            "std-packages: {} {}",
            diags.len(),
            if diags.len() == 1 {
                "violation"
            } else {
                "violations"
            },
        );
        return 1;
    }
    println("std-packages: {} files in {} packages, no violation", mods.len(), man.packages.len());
    return 0;
}

// The violations of module `m` alone (an undeclared package, platform FFI), and its imports of std modules
// into `edges`.
fn check_module(
    dir: str,
    man: &Manifest,
    mods: &Vector<Module>,
    m: usize,
    edges: &mut Vector<Edge>,
    diags: &mut Vector<String>,
) {
    let md = &mods[m];
    let at = format("{}/{}", dir, md.rel.as_str());
    if !md.items.error.is_empty() {
        diags.push(format("{}:{}: cannot scan the file: {}", at.as_str(), md.items.error_line, md.items.error.as_str()));
    }
    if md.pkg == NO_PKG {
        diags.push(format("{}:1: undeclared package: packages.toml has no row for this file's package", at.as_str()));
        return;
    }
    let pkg = &man.packages[md.pkg];
    let exempt = has(&pkg.platform_ffi, "*") || has(&pkg.platform_ffi, &md.name);
    let mut targets = Vector::<usize>::new();
    for imp in md.items.imports.iter() {
        let path = imp.path.as_str();
        if path.starts_with("std::") {
            targets.clear();
            resolve(path.slice(5, path.len()), mods, &mut targets);
            if targets.is_empty() {
                diags.push(
                    format("{}:{}: import of {}: no file under {} has this path", at.as_str(), imp.line, path, dir),
                );
            }
            for t in targets.iter() {
                // An import of an undeclared package's module reports at that module.
                if mods[*t].pkg != NO_PKG {
                    edges.push(Edge { from: m, to: *t, line: imp.line });
                }
            }
        } else if !path.starts_with("__") {
            let module = String::from_str(path).replace("::", "/");
            if !exempt && !has(&man.ffi_modules, &module) {
                diags.push(
                    format(
                        "{}:{}: platform FFI outside std::platform: import of the ffi module '{}'",
                        at.as_str(),
                        imp.line,
                        module.as_str(),
                    ),
                );
            }
        }
    }
    if exempt {
        return;
    }
    for f in md.items.externs.iter() {
        let name = f.name.as_str();
        if !f.data && !has(&man.ffi_functions, name) && !matches_any(&pkg.c_functions, name) {
            diags.push(
                format(
                    "{}:{}: platform FFI outside std::platform: the extern \"C\" function '{}'",
                    at.as_str(),
                    f.line,
                    name,
                ),
            );
        }
    }
}

// The stale data of the rows: a package without a file, and a `platform_ffi` entry that names no module of
// its package.
fn check_rows(toml_path: str, man: &Manifest, mods: &Vector<Module>, diags: &mut Vector<String>) {
    for p in 0..man.packages.len() {
        let pkg = &man.packages[p];
        let mut files: usize = 0;
        for m in mods.iter() {
            if m.pkg == p {
                files += 1;
            }
        }
        if files == 0 {
            diags.push(format("{}:{}: package '{}' has no file", toml_path, pkg.line, pkg.name.as_str()));
        }
        for e in pkg.platform_ffi.iter() {
            let mut found = e.as_str() == "*";
            for m in mods.iter() {
                found = found || m.pkg == p && m.name.as_str() == e.as_str();
            }
            if !found {
                diags.push(
                    format(
                        "{}:{}: package '{}' exempts '{}', which is none of its modules",
                        toml_path,
                        pkg.line,
                        pkg.name.as_str(),
                        e.as_str(),
                    ),
                );
            }
        }
    }
}

// The modules `import std::<rest>` loads, as the compiler's loader resolves it: the file `<rest>.spc`, else
// the index file `<rest>/<last>.spc`, else every file directly in the directory `<rest>/`.
fn resolve(rest: str, mods: &Vector<Module>, out: &mut Vector<usize>) {
    let base = String::from_str(rest).replace("::", "/");
    let mut file = base.clone();
    file.push_str(".spc");
    let mut last: usize = 0; // the start of the last segment
    for k in 0..base.len() {
        if base.as_str().byte_at(k) == b'/' {
            last = k + 1;
        }
    }
    let mut index = base.clone();
    index.push_byte(b'/');
    index.push_str(base.as_str().slice(last, base.len()));
    index.push_str(".spc");
    for want in [file.as_str(), index.as_str()] {
        for m in 0..mods.len() {
            if mods[m].rel.as_str() == want {
                out.push(m);
                return;
            }
        }
    }
    let mut prefix = base.clone();
    prefix.push_byte(b'/');
    for m in 0..mods.len() {
        let rel = mods[m].rel.as_str();
        if rel.starts_with(&prefix) && rel.slice(prefix.len(), rel.len()).find_byte(b'/') < 0 {
            out.push(m);
        }
    }
}

// The strongly connected component of each module in the import graph (Tarjan's algorithm, iterative): two
// modules have the same number exactly when each reaches the other.
fn components(n: usize, edges: &Vector<Edge>) Vector<usize> {
    // The successors of module v are succ[first[v]..first[v + 1]].
    let mut first = Vector::<usize>::new();
    first.resize_default(n + 1);
    for e in edges.iter() {
        first[e.from + 1] += 1;
    }
    for v in 0..n {
        first[v + 1] += first[v];
    }
    let mut fill = first.clone();
    let mut succ = Vector::<usize>::new();
    succ.resize_default(edges.len());
    for e in edges.iter() {
        succ[fill[e.from]] = e.to;
        fill[e.from] += 1;
    }
    let mut index = Vector::<usize>::new();
    let mut low = Vector::<usize>::new();
    let mut comp = Vector::<usize>::new();
    let mut on_stack = Vector::<bool>::new();
    for _ in 0..n {
        index.push(UNVISITED);
        low.push(0);
        comp.push(0);
        on_stack.push(false);
    }
    let mut stack = Vector::<usize>::new(); // the modules of the components not yet complete
    let mut frames = Vector::<usize>::new(); // the depth-first path, one module per frame
    let mut next = Vector::<usize>::new(); // per frame: its next successor position
    let mut count: usize = 0;
    let mut comps: usize = 0;
    for root in 0..n {
        if index[root] != UNVISITED {
            continue;
        }
        index[root] = count;
        low[root] = count;
        count += 1;
        stack.push(root);
        on_stack[root] = true;
        frames.push(root);
        next.push(first[root]);
        // Each pass takes one successor edge or completes one module: at most n + edges.len() passes.
        while !frames.is_empty() {
            let top = frames.len() - 1;
            let v = frames[top];
            if next[top] < first[v + 1] {
                let w = succ[next[top]];
                next[top] += 1;
                if index[w] == UNVISITED {
                    index[w] = count;
                    low[w] = count;
                    count += 1;
                    stack.push(w);
                    on_stack[w] = true;
                    frames.push(w);
                    next.push(first[w]);
                } else if on_stack[w] && index[w] < low[v] {
                    low[v] = index[w];
                }
                continue;
            }
            let _ = frames.pop();
            let _ = next.pop();
            if low[v] == index[v] {
                loop {
                    let w = stack.pop().unwrap();
                    on_stack[w] = false;
                    comp[w] = comps;
                    if w == v {
                        break;
                    }
                }
                comps += 1;
            }
            if !frames.is_empty() {
                let u = frames[frames.len() - 1];
                if low[v] < low[u] {
                    low[u] = low[v];
                }
            }
        }
    }
    return comp;
}

const fn has(list: &Vector<String>, s: str) bool {
    for e in list.iter() {
        if e.as_str() == s {
            return true;
        }
    }
    return false;
}

// Whether `name` equals an entry of `list`, or starts with the text before an entry's final `*`.
const fn matches_any(list: &Vector<String>, name: str) bool {
    for e in list.iter() {
        let p = e.as_str();
        if p.ends_with("*") && name.starts_with(p.slice(0, p.len() - 1)) || p == name {
            return true;
        }
    }
    return false;
}

extend Module {
    // The module of file `rel`, with its package row and its scanned items.
    fn new(rel: str, man: &Manifest, items: Scan) Module {
        let stem = rel.slice(0, rel.len() - 4); // without `.spc`
        let slash = stem.find_byte(b'/');
        let pkg_name = if slash < 0 {
            "prelude"
        } else {
            stem.slice(0, slash as usize)
        };
        let name = if slash < 0 {
            String::from_str(stem)
        } else {
            String::from_str(stem.slice(slash as usize + 1, stem.len())).replace("/", "::")
        };
        let mut pkg = NO_PKG;
        for p in 0..man.packages.len() {
            if man.packages[p].name.as_str() == pkg_name {
                pkg = p;
            }
        }
        let mut path = String::from_str("std::");
        path.push_str(String::from_str(stem).replace("/", "::").as_str());
        return Module { rel: String::from_str(rel), path: path, name: name, pkg: pkg, items: items };
    }
}
