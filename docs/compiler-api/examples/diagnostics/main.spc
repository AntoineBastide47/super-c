// Check the project in the directory the first argument names, with std read from the directory the second
// names, and print each diagnostic as `file:start-end: severity [code]: message`. Exit status: 0 without
// errors, 1 with errors, 2 when the project does not check.
import vendor::superc::src::api::session as *;

fn main(args: Vector<str>) i32 {
    if args.len() != 3 {
        eprintln("usage: diagnostics <project directory> <std directory>");
        return 2;
    }
    let mut s = switch Session::open_project(args[1], Config::host(args[2])) {
        Ok(s) => s,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 2;
        },
    };
    if let Err(e) = s.check() {
        eprintln("error: {}", e.message.as_str());
        return 2;
    }
    let mut errors: u32 = 0;
    let mut ds = s.diagnostics().unwrap();
    while let Some(d) = ds.next() {
        let sev = if d.severity() == SEV_ERROR {
            "error";
        } else {
            "warning";
        };
        println("{}:{}-{}: {} [{}]: {}", d.file(), d.start(), d.end(), sev, d.code_name(), d.message());
        if d.severity() == SEV_ERROR {
            errors += 1;
        }
    }
    if errors != 0 {
        return 1;
    }
    return 0;
}
