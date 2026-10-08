// The backend entries against the lane loops (tests/gen/simd_entry.spc): std/simd/backend/wasm.spc on
// the vector conformance lane (`SC_SIMD_LANE=wasm`), std/simd/backend/aarch64.spc on an aarch64 host;
// every entry, in eight parts that run in parallel.
import tests::gen::simd_entry as se;
import tests::harness as h;
import tests::cli_harness as cli;
import driver_shim as shim;

// The backend file the differential builds use: the wasm one in the conformance lane, the aarch64 one
// on an aarch64 host, none elsewhere.
fn backend() str<'static> {
    if h::simd_lane() {
        return "std/simd/backend/wasm.spc";
    }
    if unsafe shim::sc_host_arch() == 1 {
        return "std/simd/backend/aarch64.spc";
    }
    return "";
}

fn part(k: usize) {
    if backend().len() == 0 {
        return;
    }
    let text = cli::read_text(backend());
    let n = se::entries(text.as_str()).len();
    assert(n > 200, "the backend file parses");
    let r = se::check(text.as_str(), n * k / 8, n * (k + 1) / 8, 4);
    if r.len() != 0 {
        eprintln("{}", r.as_str());
    }
    assert(r.len() == 0, "an entry differs from its lane loop");
}

// Each part builds and runs a program per few entries: on a 3-core CI runner a part takes up to 100 s.
@test(timeout = 300)
fn entries_first_eighth() {
    part(0);
}

@test(timeout = 300)
fn entries_second_eighth() {
    part(1);
}

@test(timeout = 300)
fn entries_third_eighth() {
    part(2);
}

@test(timeout = 300)
fn entries_fourth_eighth() {
    part(3);
}

@test(timeout = 300)
fn entries_fifth_eighth() {
    part(4);
}

@test(timeout = 300)
fn entries_sixth_eighth() {
    part(5);
}

@test(timeout = 300)
fn entries_seventh_eighth() {
    part(6);
}

@test(timeout = 300)
fn entries_eighth_eighth() {
    part(7);
}

@test
fn memory_and_mask_test_entries() {
    if backend().len() == 0 {
        return;
    }
    let r = se::check_memory(cli::read_text(backend()).as_str());
    if r.len() != 0 {
        eprintln("{}", r.as_str());
    }
    assert(r.len() == 0, "a load, store or mask test differs from its lane loop");
}

// The parser of the entry model reads each entry's operation and shapes.
@test
fn entry_shapes_parse() {
    let es = se::entries(
        "@arch(wasm32)\n@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])\nfn cast_f64x2_i32x2(a: f64x2) Simd<i32, 2> {\n@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])\nfn store_i8x16(p: *mut i8, v: i8x16) {\n@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Simd128])\nfn lanes_to_mask_u8x16(m: u8x16) mask16 {\n",
    );
    assert(es.len() == 3, "three entries");
    let c = es.at(0);
    assert(
        c.name.as_str() == "cast_f64x2_i32x2" && c.op.as_str() == "Cast" && c.t == 9 && c.n == 2 && c.u == 2 && c.m == 2,
        "a cast",
    );
    let s = es.at(1);
    assert(s.op.as_str() == "Store" && s.t == 0 && s.n == 16 && s.u == 255, "a store: its vector parameter");
    let l = es.at(2);
    assert(l.t == 4 && l.n == 16 && l.u == 255, "a mask result");
}
