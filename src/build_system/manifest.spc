// build.toml schema: maps parsed TOML items onto the Build manifest, applies defaults (built-in
// debug/dev/release/bench profiles), and validates. Unknown sections/keys are hard errors so typos
// never silently no-op.
import build_system::toml as toml;
import module::loader as loader;
import utils::errors as diag;

pub struct Profile {
    pub name: str,
    pub cflags: Vector<String>,
    pub ldflags: Vector<String>,
    pub strip: bool,
}

extend Profile as Free {
    pub fn free(self: &mut Self) {
        self.cflags.free();
        self.ldflags.free();
    }
}

pub struct Command {
    pub name: str,
    pub run: Vector<String>,
    pub needs_build: bool,
    pub env_k: Vector<String>,
    pub env_v: Vector<String>,
}

extend Command as Free {
    pub fn free(self: &mut Self) {
        self.run.free();
        self.env_k.free();
        self.env_v.free();
    }
}

pub struct Manifest {
    pub toml: Vector<toml::TomlItem>,
    pub bin: String,
    pub root: String,
    pub out_dir: String,
    pub cc: String,
    pub cstd: String,
    pub cflags: Vector<String>,
    pub ldflags: Vector<String>,
    pub ldlibs: Vector<String>,
    pub jobs: u32,
    pub default_profile: String,
    pub profiles: Vector<Profile>,
    pub commands: Vector<Command>,
}

extend Manifest as Free {
    pub fn free(self: &mut Self) {
        self.toml.free();
        self.bin.free();
        self.root.free();
        self.out_dir.free();
        self.cc.free();
        self.cstd.free();
        self.cflags.free();
        self.ldflags.free();
        self.ldlibs.free();
        self.default_profile.free();
        self.profiles.free();
        self.commands.free();
    }
}

extend Manifest {
    fn new() Self {
        return Manifest {
            toml: Vector::<toml::TomlItem>::new(),
            bin: String::new(),
            root: String::new(),
            out_dir: String::new(),
            cc: String::new(),
            cstd: String::new(),
            cflags: Vector::<String>::new(),
            ldflags: Vector::<String>::new(),
            ldlibs: Vector::<String>::new(),
            jobs: 0,
            default_profile: String::new(),
            profiles: Vector::<Profile>::new(),
            commands: Vector::<Command>::new(),
        };
    }

    pub fn profile_index(self: &Self, name: str) i64 {
        for i in 0..self.profiles.len() {
            if self.profiles.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }

    pub fn command_index(self: &Self, name: str) i64 {
        for i in 0..self.commands.len() {
            if self.commands.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }
}

extend Profile {
    fn new(name: str) Self {
        return Profile { name: name, cflags: Vector::<String>::new(), ldflags: Vector::<String>::new(), strip: false };
    }
}

fn push_flags(dst: &mut Vector<String>, flags: str) {
    // split a flag string on spaces so built-in profiles can be written as one literal
    let mut i: usize = 0;
    let n = flags.len();
    while i < n {
        while i < n && flags[i] == b' ' {
            i = i + 1;
        }
        let s = i;
        while i < n && flags[i] != b' ' {
            i = i + 1;
        }
        if i > s {
            dst.push(String::from_str(flags.slice(s, i)));
        }
    }
}

// The Makefile's profiles, available out of the box; a [profile.NAME] section with the same name
// starts from empty flags instead (full override, no merging surprises).
fn add_builtin_profiles(m: &mut Manifest) {
    if m.profile_index("debug") < 0 {
        let mut p = Profile::new("debug");
        push_flags(&mut p.cflags, "-g -O0 -fno-omit-frame-pointer");
        m.profiles.push(p);
    }
    if m.profile_index("dev") < 0 {
        let mut p = Profile::new("dev");
        push_flags(
            &mut p.cflags,
            "-g -O1 -fsanitize=address -fsanitize=undefined -fsanitize-recover=address -fsanitize-address-use-after-scope -fno-omit-frame-pointer",
        );
        push_flags(&mut p.ldflags, "-fsanitize=address -fsanitize=undefined");
        m.profiles.push(p);
    }
    if m.profile_index("release") < 0 {
        let mut p = Profile::new("release");
        push_flags(
            &mut p.cflags,
            "-O3 -DNDEBUG -finline-functions -fomit-frame-pointer -ffunction-sections -fdata-sections -flto=auto -fPIE",
        );
        push_flags(&mut p.ldflags, "-flto=auto -Wl,-O2");
        p.strip = true;
        m.profiles.push(p);
    }
    if m.profile_index("bench") < 0 {
        let mut p = Profile::new("bench");
        push_flags(&mut p.cflags, "-O2 -g -fno-omit-frame-pointer");
        m.profiles.push(p);
    }
}

fn take_arr(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut Vector<String>) {
    if it.val.kind != toml::TV_ARR {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects an array of strings", it.key.as_str()));
        return;
    }
    for i in 0..it.val.arr.len() {
        dst.push(it.val.arr.at(i).clone());
    }
}

fn set_str(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut String) {
    if it.val.kind != toml::TV_STR {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects a string", it.key.as_str()));
        return;
    }
    *dst = it.val.s.clone();
}

fn set_bool(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut bool) {
    if it.val.kind != toml::TV_BOOL {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects true or false", it.key.as_str()));
        return;
    }
    *dst = it.val.b;
}

// Load and validate <path>. Prints its own diagnostics; None on any error.
pub fn load(path: str) Option<Manifest> {
    let src_opt = loader::read_file(path);
    if src_opt.is_none() {
        eprintln("build: cannot read '{}'", path);
        return Option::<Manifest>::None;
    }

    let mut src = src_opt.unwrap();
    let items_opt = toml::parse(src.as_str(), path);
    if items_opt.is_none() {
        return Option::<Manifest>::None;
    }

    let mut m = Manifest::new();
    let mut items = items_opt.unwrap();
    let mut errs = diag::Errors::new();
    for x in 0..items.len() {
        let it = items.at(x);
        let sec = it.section.as_str();
        let key = it.key.as_str();
        if sec == "" {
            if key == "bin" {
                set_str(it, &mut errs, &mut m.bin);
            } else if key == "root" {
                set_str(it, &mut errs, &mut m.root);
            } else if key == "out-dir" {
                set_str(it, &mut errs, &mut m.out_dir);
            } else if key == "cc" {
                set_str(it, &mut errs, &mut m.cc);
            } else if key == "cstd" {
                set_str(it, &mut errs, &mut m.cstd);
            } else if key == "cflags" {
                take_arr(it, &mut errs, &mut m.cflags);
            } else if key == "ldflags" {
                take_arr(it, &mut errs, &mut m.ldflags);
            } else if key == "ldlibs" {
                take_arr(it, &mut errs, &mut m.ldlibs);
            } else if key == "jobs" {
                if it.val.kind != toml::TV_INT || it.val.i < 0 {
                    errs.emit(it.at, 4, format("'jobs' expects a non-negative integer"));
                } else {
                    m.jobs = it.val.i as u32;
                }
            } else if key == "default-profile" {
                set_str(it, &mut errs, &mut m.default_profile);
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown key '{}'", key));
            }
        } else if sec.starts_with("profile.") && sec.len() > 8 {
            let name = sec.slice(8, sec.len());
            let mut pi = m.profile_index(name);
            if pi < 0 {
                m.profiles.push(Profile::new(name));
                pi = m.profiles.len() as i64 - 1;
            }
            let p = &mut m.profiles[pi as usize];
            if key == "cflags" {
                take_arr(it, &mut errs, &mut p.cflags);
            } else if key == "ldflags" {
                take_arr(it, &mut errs, &mut p.ldflags);
            } else if key == "strip" {
                set_bool(it, &mut errs, &mut p.strip);
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown profile key '{}'", key));
            }
        } else if sec.starts_with("command.") && sec.len() > 8 {
            let name = sec.slice(8, sec.len());
            let mut ci = m.command_index(name);
            if ci < 0 {
                m.commands.push(
                    Command {
                        name: name,
                        run: Vector::<String>::new(),
                        needs_build: false,
                        env_k: Vector::<String>::new(),
                        env_v: Vector::<String>::new(),
                    },
                );
                ci = m.commands.len() as i64 - 1;
            }
            let c = &mut m.commands[ci as usize];
            if key == "run" {
                take_arr(it, &mut errs, &mut c.run);
            } else if key == "needs-build" {
                set_bool(it, &mut errs, &mut c.needs_build);
            } else if key == "env" {
                if it.val.kind != toml::TV_TBL {
                    errs.emit(it.at, 3, format("'env' expects an inline table of strings"));
                } else {
                    for e in 0..it.val.tbl.len() {
                        c.env_k.push(it.val.tbl.at(e).k.clone());
                        c.env_v.push(it.val.tbl.at(e).v.clone());
                    }
                }
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown command key '{}'", key));
            }
        } else {
            errs.emit(it.at, key.len() as u32, format("unknown section '{}'", sec));
        }
    }
    // the name views above point into the items' section Strings: the Manifest takes ownership
    m.toml = items;
    // defaults + validation
    if m.out_dir.len() == 0 {
        m.out_dir.push_str("build");
    }
    if m.cstd.len() == 0 {
        m.cstd.push_str("-std=c11 -D_POSIX_C_SOURCE=200809L");
    }
    if m.default_profile.len() == 0 {
        m.default_profile.push_str("dev");
    }
    add_builtin_profiles(&mut m);
    if m.bin.len() == 0 {
        errs.emit(0, 1, format("missing required key 'bin'"));
    }
    if m.root.len() == 0 {
        errs.emit(0, 1, format("missing required key 'root'"));
    }
    if m.profile_index(m.default_profile.as_str()) < 0 {
        errs.emit(0, 1, format("default-profile '{}' is not defined", m.default_profile.as_str()));
    }
    let bad = errs.has_errors();
    if bad {
        errs.finalize(src.as_str(), path);
        errs.log();
    }
    if bad {
        return Option::<Manifest>::None;
    }
    return Option::<Manifest>::Some(m);
}
