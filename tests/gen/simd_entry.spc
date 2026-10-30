// Entry model: for every `@simd_impl` entry of a backend file, cases of the vector model
// (tests/gen/vector.spc) over the entry's operation, lane type and lane count, and over the most lanes
// (a split plan), with that model's boundary inputs; and one program of the loads, stores and mask
// tests the model has no operation for. The oracle builds each program twice, planned and with the
// planner forced to lane loops (SC_SIMD_SCALAR=1), and requires the same value or trap per case, and
// a call of every entry in the planned C, which a second pair of builds writes (`--emit-c`).
import target::table as tgt;
import tests::gen::driver as gen;
import tests::gen::vector as vec;
import tests::harness as h;
import tests::cli_harness as cli;
import driver_shim as shim;
import std::platform::fs;
import ir::cpu_features as cf;
import stdlib;

/// One entry: its function name, operation (the `simd::Op` variant), the lane types and counts of its
/// first parameter and its result (lane type 255: a mask or a scalar), and its features, closed under
/// `implies` (the backend table's order).
pub(package) struct Entry {
    pub(package) name: String,
    pub(package) op: String,
    pub(package) t: u8,
    pub(package) n: u64,
    pub(package) u: u8,
    pub(package) m: u64,
    pub(package) fs: cf::CpuFeatureSet,
}

// The model's lane type of name `s` (i8 0 .. i64 3, u8 4 .. u64 7, f32 8, f64 9), or 255.
const fn lane_of(s: str) u8 {
    let names: []str = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"];
    for i in 0..names.len() {
        if names[i] == s {
            return i as u8;
        }
    }
    return 255;
}

// The lane type and count of type text `s`: `f32x4`, `Simd<i32, 2>`, a scalar lane type as one lane;
// 255 for any other type.
const fn shape_of(s: str, t: &mut u8, n: &mut u64) {
    let ty = s.trim();
    let simd = ty.starts_with("Simd<");
    let x = ty.find(pick(simd, ",", "x"));
    *t = lane_of(ty);
    *n = pick(*t == 255, 0u64, 1);
    if x > 0 && !ty.starts_with("mask") {
        *t = lane_of(ty.slice(pick(simd, 5usize, 0), x as usize));
        *n = ty.slice(x as usize + 1, ty.len() - pick(simd, 1usize, 0)).trim().parse_u64().unwrap_or(0);
    }
}

/// The entries of backend file `text`, in order.
pub(package) fn entries(text: str) Vector<Entry> {
    let mut v = Vector::<Entry>::new();
    let mut op = String::new();
    let mut fs = cf::CpuFeatureSet { w: [0, 0] };
    for line in text.lines() {
        if line.starts_with("@simd_impl(simd::Op::") {
            let rest = line.slice(21, line.len());
            op = String::from_str(rest.slice(0, rest.find(",") as usize));
            fs = cf::CpuFeatureSet { w: [0, 0] };
            let mut at = line.find("cpu::Feature::");
            while at >= 0 {
                let tail = line.slice(at as usize + 14, line.len());
                let mut e: usize = 0;
                while e < tail.len() && (tail.byte_at(e) >= b'0' && tail.byte_at(e) <= b'9' || tail.byte_at(e) >= b'A' && tail.byte_at(
                    e,
                ) <= b'Z' || tail.byte_at(e) >= b'a' && tail.byte_at(e) <= b'z') {
                    e += 1;
                }
                let v = cf::find_variant(tail.slice(0, e));
                assert(v >= 0, tail.slice(0, e));
                fs = cf::with(fs, v as usize);
                at = pick(tail.find("cpu::Feature::") < 0, -1, at + 14 + tail.find("cpu::Feature::"));
            }
            fs = cf::close(fs);
            continue;
        }
        if op.len() == 0 || !line.starts_with("fn ") {
            continue;
        }
        let open = line.find("(") as usize;
        let close = line.find(") ") as usize;
        let mut e = Entry {
            name: String::from_str(line.slice(3, open)),
            op: op.clone(),
            t: 255,
            n: 0,
            u: 255,
            m: 0,
            fs: fs,
        };
        // The first vector parameter names the lanes: parameters split at `, ` outside `<..>`.
        let params = line.slice(open + 1, close);
        let mut depth: u32 = 0;
        let mut a: usize = 0;
        let mut last = params;
        for i in 0..params.len() + 1 {
            let ch = if i < params.len() {
                params.byte_at(i)
            } else {
                b','
            };
            depth = if ch == b'<' {
                depth + 1
            } else if ch == b'>' {
                depth - 1
            } else {
                depth
            };
            if ch != b',' || depth != 0 {
                continue;
            }
            let prm = params.slice(a, i);
            a = i + 1;
            last = prm.slice(prm.find(":") as usize + 1, prm.len());
            if e.t == 255 {
                shape_of(prm.slice(prm.find(":") as usize + 1, prm.len()), &mut e.t, &mut e.n);
            }
        }
        let ret = line.slice(close + 1, line.len() - 1).trim();
        shape_of(ret, &mut e.u, &mut e.m);
        // A gather's or scatter's index lanes are the first vector; its elements are the last.
        if op.as_str() == "Gather" || op.as_str() == "Scatter" {
            e.u = e.t;
            e.m = e.n;
            shape_of(last, &mut e.t, &mut e.n);
        }
        v.push(e);
        op.clear();
    }
    return v;
}

// The vector model's operation named `name`, or 255.
const fn model_op(name: str) u8 {
    let vops: []vec::VOp = vec::VOPS;
    for i in 0..vops.len() {
        if vops[i].name == name {
            return i as u8;
        }
    }
    // XOPS end the operation numbering.
    let xops: []vec::XOp = vec::XOPS;
    for i in 0..xops.len() {
        if xops[i].name == name {
            return (vec::OPS_N as usize - xops.len() + i) as u8;
        }
    }
    return 255;
}

// `CamelCase` as `snake_case`.
fn snake(s: str) String {
    let mut out = String::new();
    for i in 0..s.len() {
        let c = s.byte_at(i);
        if c >= b'A' && c <= b'Z' {
            if i != 0 {
                out.push_byte(b'_');
            }
            out.push_byte(c + 32);
        } else {
            out.push_byte(c);
        }
    }
    return out;
}

// The vector model operations that reach entry `e`'s operation; empty for one the model lacks.
fn model_ops(e: &Entry) Vector<String> {
    let mut v = Vector::<String>::new();
    let op = e.op.as_str();
    let float = e.t >= 8;
    let cmp: [str; 6] = ["CmpEqLanes", "CmpNeLanes", "CmpLtLanes", "CmpLeLanes", "CmpGtLanes", "CmpGeLanes"];
    let mask: [str; 6] = ["equal", "not_equal", "less_than", "less_equal", "greater_than", "greater_equal"];
    for i in 0usize..6 {
        // the comparison into mask bits (`CmpEq`): the mask, or its `count`
        if op == unsafe cmp[i].slice(0, cmp[i].len() - 5) {
            v.push(String::from_str(unsafe mask[i]));
            if i == 2 {
                v.push(String::from_str("count_compare"));
            }
            return v;
        }
        if op == unsafe cmp[i] {
            v.push(String::from_str(unsafe mask[i]));
            // the comparison feeds a choice: the lane form, no mask in between; or `count`, or a choice
            // of narrower lanes
            if i == 2 {
                v.push(String::from_str("mask_choose"));
                v.push(String::from_str("count_compare"));
                v.push(String::from_str("choose_narrower"));
            }
            return v;
        }
    }
    if op == "ChooseLanes" || op == "Choose" {
        v.push(String::from_str("mask_choose"));
        v.push(String::from_str("choose"));
    } else if op == "LanesToMask" {
        v.push(String::from_str("equal"));
    } else if op == "MaskToLanes" {
        v.push(String::from_str("choose"));
    } else if op == "Abs" && float {
        v.push(String::from_str("abs_float"));
    } else if (op == "Min" || op == "Max") && float {
        let mut nm = snake(op);
        nm.push_str("_num");
        v.push(nm);
    } else if op.starts_with("Overflow") {
        // The trap check of the operator and `checked_*`.
        let base = snake(op.slice(8, op.len()));
        v.push(format("checked_{}", base.as_str()));
        v.push(base);
    } else if op == "LoadMasked" {
        v.push(String::from_str("load_masked"));
        v.push(String::from_str("load_or"));
    } else if op != "AnyLanes" && op != "AllLanes" && op != "Load" && op != "Store" {
        v.push(snake(op));
    }
    return v;
}

/// The vector model cases of the entries of `es` at the indexes `ks`: for each entry and each model
/// operation that reaches it, `per` cases at its lane count and `per` at the most lanes, drawn from
/// seeds fixed by the entry's index, and a choice, compress, expand or masked access over at most four
/// lanes under every mask.
pub(package) fn cases(es: &Vector<Entry>, ks: []usize, per: u64) Vector<vec::VCase> {
    let mut cs = Vector::<vec::VCase>::new();
    for k in ks {
        let e = es.at(k);
        let ops = model_ops(e);
        // A choice, or an operation on a mask, has the result's lane type and count.
        let res = e.t == 255 || e.op.as_str() == "ChooseLanes";
        let t = if res {
            e.u
        } else {
            e.t
        };
        let n = if res {
            e.m
        } else {
            e.n
        };
        for j in 0..ops.len() {
            let name = ops.at(j).as_str();
            let op = model_op(name);
            assert(op != 255, name);
            // a conversion's target is the result's lane type; an index vector is u8
            let u: i32 = if name == "choose_narrower" {
                -1 // any narrower integer lanes
            } else if name == "gather" || name == "scatter" {
                e.u // the entry's index lanes, which may be its element type
            } else if vec::converts(op) && e.u != t {
                e.u
            } else if vec::converts(op) {
                4
            } else {
                -1
            };
            let mut rng = gen::Rng::new(k as u64 * 7919 + j as u64 + 1);
            let most = vec::max_lanes(t);
            for i in 0usize..2 {
                let ln = pick(i == 0, n, most);
                if i == 1 && n == most {
                    continue; // the entry's count is the most: one set of cases
                }
                let mut got: u64 = 0;
                // A case whose lanes do not suit the entry is drawn again: 64 draws at most.
                for _ in 0..64 {
                    let mut c = vec::VCase {};
                    if got == per || !vec::op_ok(op, t, ln) || !vec::draw_case(&mut rng, op, t, ln, u, &mut c) {
                        continue;
                    }
                    if ln == n && (name == "swizzle" || name == "shuffle") && c.m != n || name == "swizzle_or_zero" && ln == n && c.m != e.m {
                        continue;
                    }
                    cs.push(c);
                    got += 1;
                }
                // Every mask of a choice, compress, expand or masked access over at most four lanes.
                let masked = name == "choose" || name == "compress" || name == "expand" || name == "load_masked";
                if ln <= 4 && (masked || name == "store_masked") {
                    for pat in 0u64..1u64 << ln {
                        let mut c = vec::VCase {};
                        if vec::draw_case(&mut rng, op, t, ln, u, &mut c) {
                            c.s.clear();
                            c.s.push_u64(pat);
                            cs.push(c);
                        }
                    }
                }
            }
        }
    }
    return cs;
}

// The program of the operations the vector model lacks (loads, stores, `any` and `all` of a
// comparison) over 128, 256 and 512 bits of each lane type and 64 bits of each but the 64-bit ones,
// with inputs chosen at run time.
fn memory_program() String {
    let names: []str = [
        "i8",
        "i16",
        "i32",
        "i64",
        "u8",
        "u16",
        "u32",
        "u64",
        "f32",
        "f64",
        "i8",
        "i16",
        "i32",
        "u8",
        "u16",
        "u32",
        "f32",
        "i8",
        "i16",
        "i32",
        "i64",
        "u8",
        "u16",
        "u32",
        "u64",
        "f32",
        "f64",
        "i8",
        "i16",
        "i32",
        "i64",
        "u8",
        "u16",
        "u32",
        "u64",
        "f32",
        "f64",
    ];
    let lanes: []usize = [
        16,
        8,
        4,
        2,
        16,
        8,
        4,
        2,
        4,
        2,
        8,
        4,
        2,
        8,
        4,
        2,
        2,
        32,
        16,
        8,
        4,
        32,
        16,
        8,
        4,
        8,
        4,
        64,
        32,
        16,
        8,
        64,
        32,
        16,
        8,
        16,
        8,
    ];
    // One function per vector: a body small enough for the inliner's budget, so each `any` and `all`
    // reaches its test.
    let mut s = String::from_str("import std::simd;\n");
    for i in 0..names.len() {
        let t = names[i];
        let n = lanes[i];
        s.format_into("fn b{}(k: usize) {{\n", i);
        s.format_into(
            "    let mut a{} = [0 as {}; {}];\n    for j in 0..{}usize {{\n        unsafe a{}[j] = ((j * 37 + k) % 11) as {};\n    }}\n",
            i,
            t,
            2 * n,
            2 * n,
            i,
            t,
        );
        s.format_into("    let x{} = simd::load::<{}, {}>(a{}, k - 1);\n", i, t, n, i);
        s.format_into("    let y{} = simd::load::<{}, {}>(a{}, k);\n", i, t, n, i);
        s.format_into("    simd::store(a{}, {} - k, x{} + y{});\n", i, n, i, i);
        s.format_into(
            "    println(\"{} {{}} {{}} {{}} {{}}\", x{}.less_than(y{}).any(), x{}.less_than(y{}).all(), x{}.equal(x{}).all(), x{}.greater_than(x{}).any());\n",
            t,
            i,
            i,
            i,
            i,
            i,
            i,
            i,
            i,
        );
        s.format_into(
            "    for j in 0..{}usize {{\n        print(\"{{}} \", unsafe a{}[j]);\n    }}\n    println(\"\");\n",
            2 * n,
            i,
        );
        s.push_str("}\n");
    }
    s.push_str("fn main(args: Vector<str>) i32 {\n");
    for i in 0..names.len() {
        s.format_into("    b{}(args.len());\n", i);
    }
    s.push_str("    return 0;\n}\n");
    return s;
}

const fn pick<T>(c: bool, a: T, b: T) T {
    if c {
        return a;
    }
    return b;
}

// The text of every C file of the build directory `dir`.
fn c_text(dir: str) String {
    let mut all = String::new();
    let opened = fs::read_dir(dir);
    if opened.is_err() {
        return all;
    }
    let mut d = opened.unwrap();
    while let Some(Ok(e)) = d.next() {
        let nm = e.name;
        if nm.ends_with(".c") || nm.ends_with(".h") {
            let mut p = String::from_str(dir);
            p.format_into("/{}", nm);
            all.push_str(cli::read_text(&p).as_str());
        }
    }
    return all;
}

// The emitted C of build `b` (profile `prof`): every file of its tree and of the type headers.
fn emitted_c(b: &h::DiffBuild, prof: str) String {
    let root = b.proj.dir();
    let mut d = String::new();
    d.format_into("{}/build/{}/raw", root, prof);
    let mut s = c_text(&d);
    d.push_str("/__sc_t");
    s.push_str(c_text(&d).as_str());
    return s;
}

// Whether a called entry of `es` has entry `k`'s operation and shapes and other features: the build
// picks that one (with more features: the build has them; with fewer: it lacks `k`'s), and a build of
// the other feature set calls `k`.
fn shadowed(es: &Vector<Entry>, k: usize, seen: &String) bool {
    let e = es.at(k);
    for j in 0..es.len() {
        let o = es.at(j);
        if o.op.equals(&e.op) && o.t == e.t && o.n == e.n && o.u == e.u && o.m == e.m && (o.fs.w[0] != e.fs.w[0] || o.fs.w[1] != e.fs.w[1]) && calls(
            seen,
            o,
        ) {
            return true;
        }
    }
    return false;
}

// Whether entry `e` is a lane-mask form (`CmpEqLanes` .. `CmpGeLanes`, `ChooseLanes`, `LanesToMask`,
// `MaskToLanes`, `AnyLanes`, `AllLanes`) of lanes the C works on through an entry that gives or takes
// the mask itself (AVX-512's mask registers): the build composes lane masks only without one, so a run
// without it calls `e`.
fn mask_form_instead(es: &Vector<Entry>, e: &Entry, seen: &String) bool {
    let op = e.op.as_str();
    let cmp = op.starts_with("Cmp") && op.ends_with("Lanes");
    for j in 0..es.len() {
        let o = es.at(j);
        let oo = o.op.as_str();
        let mask_cmp = oo.starts_with("Cmp") && !oo.ends_with("Lanes");
        // the lanes of the comparison, whatever their type: the width and the count
        let same_width = mask_cmp && e.t != 255 && o.n == e.n && vec::lane_bytes(o.t) == vec::lane_bytes(e.t);
        let hit = if cmp {
            oo == op.slice(0, op.len() - 5) && o.t == e.t && o.n == e.n
        } else if op == "ChooseLanes" {
            oo == "Choose" && o.u == e.u && o.m == e.m
        } else if op == "MaskToLanes" {
            oo == "Choose" && o.m == e.m && vec::lane_bytes(o.u) == vec::lane_bytes(e.u)
        } else {
            (op == "LanesToMask" || op == "AnyLanes" || op == "AllLanes") && same_width
        };
        if hit && calls(seen, o) {
            return true;
        }
    }
    return false;
}

/// The features of the differential builds: the host's baseline and, when `with_more`,
/// `SC_SIMD_FEATURES`, closed. An entry beyond them is not required to be called (another run of the
/// lane checks it).
pub(package) fn run_features(with_more: bool) cf::CpuFeatureSet {
    let t = unsafe shim::sc_host_platform();
    let a = unsafe shim::sc_host_arch();
    let mut s = tgt::baseline(t, a);
    let mut err = String::new();
    let more = stdlib::getenv("SC_SIMD_FEATURES");
    if with_more && more != null {
        assert(cf::apply(unsafe str::from_cstr(more), t, a, true, &mut s, &mut err), err.as_str());
    }
    if h::simd_lane() {
        s = cf::with(s, cf::F_SIMD128);
    }
    return cf::close(s);
}

// Whether the run prefers 512-bit vectors on AVX-512 (`SC_SIMD_WIDTH=512`).
fn wide() bool {
    return stdlib::env_is("SC_SIMD_WIDTH", "512");
}

/// Whether the differential builds of features `run` must call entry `e`: the features hold its own,
/// and an AVX-512 entry wider than the preferred width (512 bits when `wide`, else 256) splits.
const fn required(e: &Entry, run: cf::CpuFeatureSet, wide: bool) bool {
    if !cf::contains(run, e.fs) {
        return false;
    }
    if wide || !cf::has(e.fs, cf::F_AVX512F) {
        return true;
    }
    // An entry without a vector parameter (a load) has no operand lanes: its result's count.
    let mut bytes: u64 = 0;
    if e.t != 255 {
        bytes = e.n * vec::lane_bytes(e.t);
    }
    if e.op.as_str() == "Gather" || e.op.as_str() == "Scatter" {
        bytes = (e.n * 8).min(64);
    } else if e.u != 255 && e.m * vec::lane_bytes(e.u) > bytes {
        bytes = e.m * vec::lane_bytes(e.u);
    }
    return bytes <= 32;
}

// Whether text `c` calls entry `e`.
fn calls(c: &String, e: &Entry) bool {
    let mut call = String::new();
    call.format_into("__{}(", e.name.as_str());
    return c.contains(&call);
}

/// The oracle over part `k` of `parts` of the entries of backend file `text` the run's features reach
/// (`required`; an entry beyond them would only compare lane loops with lane loops) and no run with
/// fewer features reaches (the run without `SC_SIMD_FEATURES`, and at 512 bits the 256-bit run),
/// with a model operation (`per` cases per entry, operation and lane count, programs of at most 256
/// cases): empty when the planned and the lane-loop builds agree on every case and the planned C
/// calls every entry, else each difference.
pub(package) fn check(text: str, k: usize, parts: usize, per: u64) String {
    let mut r = String::new();
    let es = entries(text);
    let run = run_features(true);
    let base = run_features(false);
    let more = !cf::contains(base, run);
    let w = wide();
    let mut sel = Vector::<usize>::new();
    for i in 0..es.len() {
        let e = es.at(i);
        let before = more && required(e, base, false) || w && required(e, run, false);
        if model_ops(e).len() != 0 && required(e, run, w) && !before {
            sel.push(i);
        }
    }
    // Dealt in turn (entry i to part i mod parts), not in contiguous runs: the backend file groups
    // related entries, so a run of costly ones would make one part far longer than the others.
    let mut ks = Vector::<usize>::new();
    for i in 0..sel.len() {
        if i % parts == k {
            ks.push(sel[i]);
        }
    }
    let cs = cases(&es, ks.index_range(0..ks.len()), per);
    let mut seen = String::new();
    let mut i: usize = 0;
    while i < cs.len() {
        let mut part = Vector::<vec::VCase>::new();
        let mut omit = Vector::<bool>::new();
        while part.len() < 256 && i < cs.len() {
            part.push(cs.at(i).clone());
            omit.push(true);
            i += 1;
        }
        let n = part.len();
        let src = vec::program(&part, &omit);
        let a = h::diff_build(&src, []);
        let b = h::diff_build(&src, ["SC_SIMD_SCALAR=1"]);
        let ac = h::diff_build(&src, ["--emit-c"]);
        let bc = h::diff_build(&src, ["--emit-c", "SC_SIMD_SCALAR=1"]);
        if !a.built || !b.built || !ac.built || !bc.built {
            r.format_into(
                "the program does not build:\n{}{}{}{}",
                a.diag.as_str(),
                b.diag.as_str(),
                ac.diag.as_str(),
                bc.diag.as_str(),
            );
            return r;
        }
        let mut va = Vector::<String>::new();
        let mut vb = Vector::<String>::new();
        for _ in 0..n {
            va.push(String::new());
            vb.push(String::new());
        }
        vec::run_all(&a, n, "v", &mut va);
        vec::run_all(&b, n, "v", &mut vb);
        for k in 0..n {
            if !va.at(k).equals(vb.at(k)) {
                r.format_into(
                    "case {}: {} on {} lanes\n  planned:    {}  lane loops: {}",
                    k,
                    vec::op_name(part.at(k)),
                    part.at(k).n,
                    va.at(k).as_str(),
                    vb.at(k).as_str(),
                );
            }
        }
        seen.push_str(emitted_c(&ac, "debug").as_str());
        if emitted_c(&bc, "debug").contains("__sc_si_") {
            r.push_str("a lane-loop build calls an entry\n");
        }
    }
    for k in ks.index_range(0..ks.len()) {
        if !calls(&seen, es.at(k)) && !shadowed(&es, k, &seen) && !mask_form_instead(&es, es.at(k), &seen) {
            r.format_into("no call of entry '{}' ({})\n", es.at(k).name.as_str(), es.at(k).op.as_str());
        }
    }
    return r;
}

/// The oracle over the entries of `text` without a model operation (loads, stores, `any`, `all`):
/// one program, the same output planned and with lane loops, and a call of each entry.
pub(package) fn check_memory(text: str) String {
    let src = memory_program();
    let m = h::diff_build(&src, []);
    let s = h::diff_build(&src, ["SC_SIMD_SCALAR=1"]);
    let mc = h::diff_build(&src, ["--emit-c"]);
    let mut r = if m.built && s.built && mc.built {
        h::same_runs(&m, &s, ["", "x"])
    } else {
        format("the program does not build:\n{}{}{}", m.diag.as_str(), s.diag.as_str(), mc.diag.as_str())
    };
    let c = emitted_c(&mc, "debug");
    let es = entries(text);
    let run = run_features(true);
    for k in 0..es.len() {
        if model_ops(es.at(k)).len() == 0 && required(es.at(k), run, wide()) && !calls(&c, es.at(k)) && !mask_form_instead(
            &es,
            es.at(k),
            &c,
        ) {
            r.format_into("no call of entry '{}' ({})\n", es.at(k).name.as_str(), es.at(k).op.as_str());
        }
    }
    return r;
}
