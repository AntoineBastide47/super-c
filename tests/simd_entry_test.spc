// The backend entries of std/simd/backend/wasm.spc against the lane loops (tests/gen/simd_entry.spc),
// on the vector conformance lane (`SC_SIMD_LANE=wasm`): every entry, in four parts that run in
// parallel.
import tests::gen::simd_entry as se;
import tests::harness as h;
import tests::cli_harness as cli;

const BACKEND: str = "std/simd/backend/wasm.spc";

fn part(k: usize) {
    if !h::simd_lane() {
        return;
    }
    let text = cli::read_text(BACKEND);
    let n = se::entries(text.as_str()).len();
    assert(n > 200, "the backend file parses");
    let r = se::check(text.as_str(), n * k / 4, n * (k + 1) / 4, 4);
    if r.len() != 0 {
        eprintln("{}", r.as_str());
    }
    assert(r.len() == 0, "an entry differs from its lane loop");
}

@test
fn entries_first_quarter() {
    part(0);
}

@test
fn entries_second_quarter() {
    part(1);
}

@test
fn entries_third_quarter() {
    part(2);
}

@test
fn entries_fourth_quarter() {
    part(3);
}

@test
fn memory_and_mask_test_entries() {
    if !h::simd_lane() {
        return;
    }
    let r = se::check_memory(cli::read_text(BACKEND).as_str());
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
