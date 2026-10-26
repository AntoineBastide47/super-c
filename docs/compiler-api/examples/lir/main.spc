// Build a function in the LIR text form, verify it, evaluate it, and compile it to an object for Linux x86-64:
// the steps of a tool that makes code. Prints the evaluation's result and the object's size.
import vendor::superc::src::api::lir as lir;

const ADD3: str = M"(lir ptr 8 vec 0
sym @add3 fn global
fn @add3
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  v2 = add.i32 v0, v1
  v3 = iconst.i32 3
  v4 = add.i32 v2, v3
  ret v4
)";

fn main() i32 {
    let p = switch lir::Program::parse(ADD3) {
        Ok(p) => p,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 1;
        },
    };
    if let Err(e) = p.verify() {
        eprintln("error: {}", e.message.as_str());
        return 1;
    }
    let args: [u64; 2] = [4, 5];
    let r = p.evaluate("add3", args).unwrap();
    println("add3(4, 5) = {}", r.value);
    let obj = p.object("linux", "x86_64").unwrap();
    println("object: {} bytes", obj.len());
    return 0;
}
