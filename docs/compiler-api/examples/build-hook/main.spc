// Build the project in the current directory, with std read from the directory the first argument names,
// through the compiler's build engine, with a hook that writes the project's module list as an artifact. Prints
// the plan's artifacts, then what the build did. Exit status: 0, or 1 when the build fails.
import vendor::superc::src::api::build as bld;
import vendor::superc::src::api::errors as er;

// Writes `modules.txt`: the project's modules, one path per line.
struct ModuleList {}

extend ModuleList as bld::Hook {
    pub fn id(self: &Self) str {
        return "example.modules";
    }

    pub fn version(self: &Self) u32 {
        return 1;
    }

    pub fn before_emission(
        self: &mut Self,
        b: &bld::BuildInfo,
        modules: Slice<bld::ModuleInfo>,
        out: &mut bld::HookOutput,
    ) Result<Unit, er::ApiError> {
        let mut text = Vector::<u8>::new();
        for i in 0..modules.len() {
            if modules[i].prelude {
                continue;
            }
            let p = modules[i].path.as_str();
            for k in 0..p.len() {
                text.push(p.byte_at(k));
            }
            text.push(b'\n');
        }
        out.artifact("modules.txt", text);
        return Ok(Unit {});
    }
}

fn main(args: Vector<str>) i32 {
    if args.len() != 2 {
        eprintln("usage: build-hook <std directory>");
        return 1;
    }
    let req = bld::Request { profile: String::new(), std_dir: String::from_str(args[1]), jobs: 0 };
    let plan = bld::plan(&req).unwrap();
    for i in 0..plan.artifacts.len() {
        println("plans {}", plan.artifacts[i].as_str());
    }
    let mut hooks = Vector::<Box<dyn bld::Hook>>::new();
    hooks.push(Box::new(ModuleList {}));
    let installed = bld::install(hooks).unwrap();
    let r = bld::build(&req).unwrap();
    for i in 0..r.targets.len() {
        let t = &r.targets[i];
        println("built {}: {} units, linked {}", t.artifact.as_str(), t.units.len(), t.linked);
    }
    for i in 0..r.hook_artifacts.len() {
        println("hook artifact {}", r.hook_artifacts[i].as_str());
    }
    let _ = installed;
    if !r.ok {
        return 1;
    }
    return 0;
}
