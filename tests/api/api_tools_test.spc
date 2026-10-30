// Compiled-in tools: a project lists analyzer and hook modules in build.toml (`[tools]`); `super-c lint` and
// `super-c build` build them with the vendored compiler into a tool compiler, which lints the project and runs
// the analyzers, or builds it and runs the hooks.
import tests::cli_harness as cli;

const LINTS: str = M"(import vendor::superc::src::api::analysis as an;
import vendor::superc::src::api::errors as er;
import vendor::superc::src::api::syntax as syn;

// Flags every comment that holds "TODO".
struct NoTodo {}

extend NoTodo as an::Analyzer {
    pub fn id(self: &Self) str {
        return "test.no-todo";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn run(self: &mut Self, pass: &mut an::Pass) Result<Unit, er::ApiError> {
        let mut hits = Vector::<syn::TextRange>::new();
        for k in pass.tree().tokens() {
            if k.kind() == syn::TokenKind::Comment && k.text().find("TODO") >= 0 {
                hits.push(k.range());
            }
        }
        for i in 0..hits.len() {
            pass.report(hits[i].start, hits[i].end, 2, "todo", "a TODO is left");
        }
        return Ok(Unit {});
    }
}

pub fn analyzers() Vector<Box<dyn an::Analyzer>> {
    let mut v = Vector::<Box<dyn an::Analyzer>>::new();
    v.push(Box::new(NoTodo {}));
    return v;
}
)";

const HOOKS: str = M"(import vendor::superc::src::api::build as bld;
import vendor::superc::src::api::errors as er;

// Writes the project's module count and warns once per build.
struct Count {}

extend Count as bld::Hook {
    pub fn id(self: &Self) str {
        return "test.count";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn before_emission(self: &mut Self, b: &bld::BuildInfo, modules: Slice<bld::ModuleInfo>, out: &mut bld::HookOutput) Result<
        Unit,
        er::ApiError
    > {
        let mut n: u8 = 0;
        for i in 0..modules.len() {
            if modules[i].path.as_str() == "main" {
                n += 1;
            }
        }
        let mut bytes = Vector::<u8>::new();
        bytes.push(b'0' + n);
        out.artifact("count.txt", bytes);
        out.warning("counted");
        return Ok(Unit {});
    }
}

pub fn hooks() Vector<Box<dyn bld::Hook>> {
    let mut v = Vector::<Box<dyn bld::Hook>>::new();
    v.push(Box::new(Count {}));
    return v;
}
)";

const APP: str = M"(// TODO: say more
fn main() i32 {
    return 0;
}
)";

@test(timeout = 900)
fn lint_runs_the_projects_analyzers() {
    if cli::on_wasm() {
        return; // the tool compiler runs as a process
    }
    let proj = cli::proj_new();
    cli::copy_tree("src", format("{}/vendor/superc/src", proj.dir()).as_str());
    assert(proj.copyfile("vendor/superc/build.toml", "build.toml"), "the manifest copies");
    proj.mkfile("tools/lints.spc", LINTS);
    proj.mkfile("src/main.spc", APP);
    proj.mkfile("tools/hooks.spc", HOOKS);
    proj.mkfile(
        "build.toml",
        "bin = \"app\"\nroot = \"src/main.spc\"\n\n[tools]\nanalyzers = [\"tools/lints.spc\"]\nhooks = [\"tools/hooks.spc\"]\n",
    );
    let r = cli::superc_env_in(proj.dir(), "SC_NONE", "", "lint");
    if r.exit != 1 {
        r.show();
    }
    assert_eq(r.exit, 1);
    assert(
        r.out_has("src/main.spc:1:1: warning: a TODO is left [test.no-todo/todo]"),
        "the analyzer's finding is printed",
    );
    proj.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let clean = cli::superc_env_in(proj.dir(), "SC_NONE", "", "lint");
    if clean.exit != 0 {
        clean.show();
    }
    assert_eq(clean.exit, 0);
    let b = cli::superc_env_in(proj.dir(), "SC_NONE", "", "build");
    if !b.ok() {
        b.show();
    }
    assert(b.ok() && b.out_has("warning: hook 'test.count': counted"), "the build runs the project's hook");
    let count = cli::read_text(format("{}/build/debug/hooks/test.count/count.txt", proj.dir()).as_str());
    assert_eq(count.as_str(), "1");
}
