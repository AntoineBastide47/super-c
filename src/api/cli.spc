// The compiler's command line for a tool compiler (`[tools]` in build.toml): `run` is what `super-c` runs,
// with the project's analyzers after its own lint.
import main as m;

/// The analyzers of a tool compiler: run with the std directory once the compiler's own lint passed; their
/// exit status (0: no findings).
pub type LintTools = fn(str) i32;

/// Run the compiler with command line `args` (`args[0]`: the program), `tools` after `super-c lint`; its exit
/// status.
pub fn run(args: Vector<str>, tools: Option<LintTools>) i32 {
    return m::run(args, tools);
}
