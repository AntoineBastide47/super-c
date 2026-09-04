// The compiler's own verification gates, driven through a real build: SC_FACTS_CHECK (semantic
// tables frozen after typecheck), SC_LAYOUT (pool types satisfy the C layout invariants), and
// SC_CORE_IR (inlined bodies re-verify, proven bounds checks re-prove). Each must accept a valid
// program and leave a working binary; a gate that found a violation would make the build fail.
import tests::cli_harness as cli;

const PROG: str = "struct Pt { pub x: i32, pub y: i32 }\nenum Shape { Dot, Seg(i32), Box { w: i32, h: i32 } }\nextend Pt { fn sum(self: &Pt) i32 { return self.x + self.y; } }\nfn area(s: &Shape) i32 {\n    return switch s {\n        Dot => 0,\n        Seg(n) => *n,\n        Box { w, h } => *w * *h,\n    };\n}\nfn main() i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..8 { v.push(i * i); }\n    let mut t = 0;\n    for i in 0..v.len() { t += v[i]; }\n    let p = Pt { x: 3, y: 4 };\n    let s = Shape::Box { w: 2, h: 5 };\n    return t + p.sum() + area(&s) - 157;\n}\n";

fn build_with(key: str, val: str) {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PROG);
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, key, val, "build");
    assert(r.ok(), key);
}

@test
fn facts_check_gate_accepts_a_valid_build() {
    build_with("SC_FACTS_CHECK", "1");
}

@test
fn layout_gate_accepts_a_valid_build() {
    build_with("SC_LAYOUT", "1");
}

@test
fn core_ir_gate_accepts_a_valid_build() {
    build_with("SC_CORE_IR", "1");
}
