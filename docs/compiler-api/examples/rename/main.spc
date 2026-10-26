// Rename the declaration named at byte offset `offset` of file `file` to `new name` everywhere the analysis
// sees it, and print each edit as `file:start-end: text`. The files stay as they are. Exit status: 0, or 1 when
// the rename is refused.
import vendor::superc::src::api::session as *;
import vendor::superc::src::api::semantic as sem;

fn main(args: Vector<str>) i32 {
    if args.len() != 5 {
        eprintln("usage: rename <file> <offset> <new name> <std directory>");
        return 1;
    }
    let off = switch args[2].parse_i64() {
        Some(v) => v as u32,
        None => {
            eprintln("error: the offset is not a number");
            return 1;
        },
    };
    let mut s = Session::open_file(args[1], Config::host(args[4])).unwrap();
    if let Err(e) = s.check() {
        eprintln("error: {}", e.message.as_str());
        return 1;
    }
    let edit = switch sem::rename(&mut s, args[1], off, args[3]) {
        Ok(w) => w,
        Err(e) => {
            eprintln("error: {}", e.message.as_str());
            return 1;
        },
    };
    for i in 0..edit.edits.len() {
        let t = &edit.edits[i];
        println("{}:{}-{}: {}", t.file.as_str(), t.start, t.end, t.text.as_str());
    }
    return 0;
}
