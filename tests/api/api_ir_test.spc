// Lowered forms for tools: the analyzed nodes of a file with their resolutions and types, one function's
// Core IR, and LIR programs a tool writes, verifies, evaluates and runs natively.
import api::ir as *;
import api::lir as *;
import lir::ir as lirc;
import api::session as ses;
import api::syntax as syn;
import api::errors as *;
import tests::cli_harness as cli;

const SRC: str = M"(struct Pair {
    pub a: String,
    pub b: i32,
}

fn take(p: Pair) i32 {
    return p.b;
}

fn main() i32 {
    let s = String::from_str("x");
    let p = Pair { a: s, b: 2 };
    let r = &p.b;
    let n = *r;
    return take(p) - n;
}
)";

struct Fx {
    pub proj: cli::Proj,
    pub main: String,
    pub s: ses::Session,
}

@test_init
fn fx() Fx {
    let proj = cli::proj_new();
    proj.mkfile("main.spc", SRC);
    let main = format("{}/main.spc", proj.dir());
    let mut s = ses::Session::open_file(&main, ses::Config::host("std")).unwrap();
    assert(s.check().is_ok(), "checks");
    let real = String::from_str(s.root_file());
    return Fx { proj: proj, main: real, s: s };
}

@test
fn hir_nodes_carry_resolutions_and_types(fx: &mut Fx) {
    let at = SRC.find("take(p)") as u32;
    let ns = hir_nodes(&fx.s, &fx.main, at, at + 7).unwrap();
    let mut call = false;
    let mut callee = false;
    for i in 0..ns.len() {
        let n = &ns[i];
        if n.kind == syn::SyntaxKind::Call {
            assert_eq(n.ty.as_str(), "i32");
            call = true;
        }
        if n.kind == syn::SyntaxKind::Identifier && n.range.start == at {
            let mut named = false;
            if let Some(k) = &n.resolves_to {
                named = k.name.as_str() == "take";
            }
            assert(named, "the callee resolves");
            callee = true;
        }
        assert(!n.lowered, "no sugar here");
    }
    assert(call && callee, "the call and its callee are listed");
}

@test
fn core_ir_shows_moves_borrows_and_drops(fx: &mut Fx) {
    let at = SRC.find("fn main") as u32 + 3;
    let f = core_function(&mut fx.s, &fx.main, at).unwrap();
    assert(f.text.len() != 0 && !f.generic, "a printed, concrete body");
    let mut named = false;
    for i in 0..f.locals.len() {
        if f.locals[i].name.as_str() == "p" {
            assert_eq(f.locals[i].ty.as_str(), "Pair");
            named = true;
        }
    }
    assert(named, "the local 'p' with its type");
    let mut take = false;
    for i in 0..f.calls.len() {
        if let Some(k) = &f.calls[i].callee {
            take = take || k.name.as_str() == "take";
        }
    }
    assert(take, "the call of 'take'");
    assert(f.moves.len() >= 1, "'s' and 'p' move");
    assert(f.borrows.len() >= 1, "'&p.b' borrows");
    assert(f.blocks.len() >= 1 && f.blocks[f.blocks.len() - 1].successors.len() <= 2, "blocks with their successors");
    let none = core_function(&mut fx.s, &fx.main, 0);
    assert(none.unwrap_err().code == Code::InvalidArgument, "no function at a struct");
}

const PROGRAM: str = M"(lir ptr 8 vec 0
sym @add3 fn global
fn @add3
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = add.i32 v0, v1
  v3 = iconst.i32 3
  v4 = add.i32 v2, v3
  ret v4
)";

@test
fn lir_programs_parse_verify_and_evaluate() {
    let p = Program::parse(PROGRAM).unwrap();
    assert(p.verify().is_ok(), "the program verifies");
    let fs = p.functions();
    assert_eq(fs.len(), 1);
    assert_eq(fs[0].as_str(), "add3");
    assert(p.function_text("add3").unwrap().as_str().find("add.i32 v0, v1") >= 0, "a function's text");
    let again = Program::parse(p.text().as_str()).unwrap();
    assert_eq(again.text().as_str(), p.text().as_str());
    let args: [u64; 2] = [4, 5];
    let e = p.evaluate("add3", args).unwrap();
    assert(!e.trapped, "the evaluation ends normally");
    assert_eq(e.value, 12);
    let bad = Program::parse("lir ptr 8 vec 0\nsym @f fn global\nfn @f\n  sig () -> i32\nb0:\n  ret v9\n");
    assert(bad.is_err() || bad.unwrap().verify().is_err(), "a use of an undefined value rejects");
}

@test
fn lir_programs_compile_and_run_natively() {
    let p = Program::parse(PROGRAM).unwrap();
    let obj = p.object("linux", "x86_64").unwrap();
    assert(obj.len() > 4 && obj[0] == 0x7F && obj[1] == b'E', "an ELF object");
    assert(p.object("wasm", "wasm32").unwrap_err().code == Code::InvalidArgument, "8-byte pointers on wasm32");
    let w = Program::parse(String::from_str(PROGRAM).replace("ptr 8", "ptr 4").as_str()).unwrap().object(
        "wasm",
        "wasm32",
    ).unwrap();
    assert(w.len() > 4 && w[0] == 0 && w[1] == b'a' && w[2] == b's' && w[3] == b'm', "a wasm object");
    let a64 = p.object("linux", "aarch64").unwrap();
    assert(a64[0] == 0x7F && a64[18] == 0xB7, "an ELF object for arm64");
    assert(p.object("windows", "aarch64").unwrap_err().code == Code::UnsupportedCapability, "no Windows arm64 backend");
    let lib = p.load().unwrap();
    let f = unsafe ((lib.symbol("add3").unwrap() as usize) as fn(i32, i32) i32);
    let r = f(4, 5);
    assert_eq(r, 12);
}

@test(timeout = 300)
fn lir_of_a_program_is_its_compiled_form() {
    let proj = cli::proj_new();
    proj.mkfile(
        "p.spc",
        "fn tripled(x: i32) i32 {\n    return x * 3;\n}\n\nfn main() i32 {\n    return tripled(4) - 12;\n}\n",
    );
    let p = of_program(format("{}/p.spc", proj.dir()).as_str(), "std").unwrap();
    assert(p.verify().is_ok(), "the program's LIR verifies");
    let fs = p.functions();
    let mut main = false;
    for i in 0..fs.len() {
        main = main || fs[i].as_str() == "__sc_user_main";
    }
    assert(main, "the program's entry is there");
    let e = p.evaluate("__sc_user_main", Vector::<u64>::new().as_slice()).unwrap();
    assert(!e.trapped && e.value == 0, "it runs to 0");
}

// A tool that builds a function with the lowering's own calls: `double(x) = x + x`.
@test
fn lir_functions_build_through_the_package() {
    let mut p = Program::new(8);
    {
        let pk = p.raw_mut();
        let sym = pk.add_symbol("double", lirc::SK_FUNC, lirc::SL_GLOBAL);
        let mut b = lirc::Body::new();
        let sigp: [u32; 1] = [lirc::T_I32 as u32];
        b.sig = b.signature(sigp, 1, false, lirc::T_I32);
        let bt: [u8; 1] = [lirc::T_I32];
        let b0 = b.add_block(bt);
        b.begin(b0);
        let x = b.param(b0, 0);
        let s = b.emit(lirc::Inst { op: lirc::O_ADD, ty: lirc::T_I32, aux: 0, a: x, b: x, c: 0 }, 0);
        let _ = b.emit(lirc::Inst { op: lirc::O_RET, ty: lirc::T_NONE, aux: 0, a: s, b: 0, c: 0 }, 0);
        assert(pk.define(sym, &b), "the symbol takes its body");
    }
    assert(p.verify().is_ok(), "the built function verifies");
    assert_eq(p.raw().syms.len(), 1);
    let mut both = Program::parse(PROGRAM).unwrap();
    assert(both.absorb(&p).is_ok(), "the programs merge");
    assert_eq(both.functions().len(), 2);
    let args: [u64; 1] = [21];
    assert_eq(both.evaluate("double", args).unwrap().value, 42);
}
